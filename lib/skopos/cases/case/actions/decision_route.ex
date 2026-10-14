defmodule Skopos.Cases.Case.Actions.DecisionRoute do
  @moduledoc false
  use Ash.Resource.Actions.Implementation
  require Ash.Query

  alias Skopos.Cases

  alias Skopos.Cases.{Case, CaseEvent, ResolutionRun, Turn}
  alias Skopos.Cases.ResolutionRun.Budget, as: Budget
  alias Skopos.Cases.Case.AdmissionLock, as: CaseAdmissionLock
  alias Skopos.Cases.Case.ConditionContext, as: ConditionContext

  @impl true
  def run(input, _opts, _context) do
    turn_id = input.arguments.turn_id

    result =
      case route(turn_id) do
        {:ok, _result} ->
          :ok

        {:error, error} ->
          cond do
            unexpected_failure?(error) -> {:error, error}
            file_route?(turn_id) -> {:error, error}
            rejected_target_selection?(turn_id, error) -> reconsider_target_selection(turn_id)
            true -> require_attention(turn_id, error)
          end
      end

    case result do
      :ok -> {:ok, %{status: :completed}}
      {:cancel, reason} -> {:ok, %{status: :cancelled, reason: reason}}
      {:error, _error} = error -> error
    end
  end

  defp route(turn_id) do
    with {:ok, turn} <- Cases.get_turn(turn_id, authorize?: false),
         {:ok, type} <- decision_type(turn) do
      case type do
        "case_split" -> route_split_turn(turn)
        "file_read" -> route_file_turn(turn)
        _other -> route_locked(turn_id)
      end
    end
  end

  defp file_route?(turn_id) do
    case Cases.get_turn(turn_id, authorize?: false) do
      {:ok, turn} -> decision_type(turn) == {:ok, "file_read"}
      _unavailable -> false
    end
  end

  defp unexpected_failure?(%Ash.Error.Unknown{}), do: true
  defp unexpected_failure?(%Ash.Error.Framework{}), do: true

  defp unexpected_failure?(%{errors: errors}) when is_list(errors),
    do: Enum.any?(errors, &unexpected_failure?/1)

  defp unexpected_failure?(%{class: class}) when class in [:unknown, :framework], do: true
  defp unexpected_failure?(_error), do: false

  defp route_file_turn(turn) do
    with {:ok, superseded?} <- superseded_by_split?(turn) do
      if superseded? do
        {:ok, :superseded}
      else
        with {:ok, incident} <- Cases.get_case(turn.case_id, authorize?: false),
             {:ok, current?} <- current_conditions?(incident, turn) do
          cond do
            incident.status != :running or incident.cancel_requested ->
              {:ok, :superseded}

            current? ->
              with {:ok, evidence} <- Cases.capture_file_read(turn.id, authorize?: false) do
                locked_continuation(turn, fn current_turn ->
                  with {:ok, incident} <- Cases.get_case(current_turn.case_id, authorize?: false),
                       {:ok, current?} <- current_conditions?(incident, current_turn) do
                    if current? do
                      continue_with_turn(
                        current_turn,
                        "file-read",
                        "Continue investigation with the current file-read result",
                        %{"file_read_evidence_id" => evidence.id},
                        "Review Resolver limits"
                      )
                    else
                      supersede_stale_route(current_turn)
                    end
                  end
                end)
              end

            true ->
              locked_continuation(turn, &supersede_stale_route/1)
          end
        end
      end
    end
  end

  defp route_locked(turn_id) do
    Ash.transact([Case, ResolutionRun, Turn, CaseEvent], fn ->
      with :ok <- CaseAdmissionLock.acquire(),
           {:ok, turn} <- Cases.get_turn(turn_id, authorize?: false),
           {:ok, incident} <- Cases.get_case(turn.case_id, authorize?: false) do
        with {:ok, superseded?} <- superseded_by_split?(turn) do
          if superseded? do
            {:ok, :superseded}
          else
            with {:ok, type} <- decision_type(turn) do
              case current_conditions?(incident, turn) do
                {:ok, true} ->
                  dispatch(type, turn.id)

                {:ok, false} ->
                  supersede_stale_route(turn)

                {:error, _error} = error ->
                  error
              end
            end
          end
        end
      end
    end)
    |> transaction_result()
  end

  defp route_split_turn(turn) do
    with {:ok, superseded?} <- superseded_by_split?(turn) do
      if superseded? do
        {:ok, :superseded}
      else
        with {:ok, incident} <- Cases.get_case(turn.case_id, authorize?: false) do
          case current_conditions?(incident, turn) do
            {:ok, true} -> route_case_split(incident, turn)
            {:ok, false} -> locked_continuation(turn, &supersede_stale_route/1)
            {:error, _error} = error -> error
          end
        end
      end
    end
  end

  defp locked_continuation(turn, continuation) do
    Ash.transact([Case, ResolutionRun, Turn, CaseEvent], fn ->
      with :ok <- CaseAdmissionLock.acquire() do
        continuation.(turn)
      end
    end)
    |> transaction_result()
  end

  defp transaction_result(result) do
    case result do
      {:ok, {:ok, _result} = result} -> result
      {:ok, {:error, _error} = error} -> error
      other -> other
    end
  end

  defp superseded_by_split?(turn) do
    CaseEvent
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(case_id == ^turn.case_id and event_type == "case_conditions_split_out")
    |> Ash.Query.sort(inserted_at: :desc, id: :desc)
    |> Ash.Query.limit(1)
    |> Ash.read_one(authorize?: false)
    |> case do
      {:ok, nil} ->
        {:ok, false}

      {:ok, event} ->
        {:ok,
         event.resolution_run_id == turn.resolution_run_id and
           is_integer(event.data["turn_ordinal_boundary"]) and
           turn.ordinal <= event.data["turn_ordinal_boundary"]}

      {:error, _error} = error ->
        error
    end
  end

  defp current_conditions?(%{trigger_kind: :signal} = incident, turn) do
    with {:ok, current} <- ConditionContext.current_condition_revisions(incident) do
      {:ok, current == turn.result["condition_revisions"]}
    end
  end

  defp current_conditions?(_incident, _turn), do: {:ok, true}

  defp route_case_split(%{trigger_kind: :signal} = incident, turn) do
    intent = turn.result["intent"]

    case Cases.split_case_from_resolver(
           incident.id,
           incident.revision,
           intent["condition_ids"],
           turn.result["condition_revisions"],
           intent["reason"],
           turn.id,
           authorize?: false
         ) do
      {:ok, _child} ->
        {:ok, :split}

      {:error, error} ->
        if not unexpected_failure?(error) and rejected_split?(error),
          do: locked_continuation(turn, &continue_after_rejected_split/1),
          else: {:error, error}
    end
  end

  defp route_case_split(_incident, _turn),
    do:
      {:error,
       Ash.Error.Changes.InvalidChanges.exception(message: "Only Signal Cases can be split")}

  defp rejected_split?(%Ash.Error.Invalid{errors: errors}),
    do: Enum.any?(errors, &rejected_split?/1)

  defp rejected_split?(%Ash.Error.Changes.InvalidAttribute{field: :source_turn_id}), do: true
  defp rejected_split?(_error), do: false

  defp continue_after_rejected_split(turn) do
    continue_with_turn(
      turn,
      "split-rejected",
      "Continue one Case after unsupported split; observe both scopes before separating",
      %{"source" => "resolver_split_rejected"},
      "Continue investigation with current Target observations"
    )
  end

  defp rejected_target_selection?(turn_id, error) do
    if candidate_citation_rejected?(error) do
      case Cases.get_turn(turn_id, authorize?: false) do
        {:ok, turn} -> decision_type(turn) == {:ok, "target_selection"}
        _unavailable -> false
      end
    else
      false
    end
  end

  defp candidate_citation_rejected?(%Ash.Error.Invalid{errors: errors}),
    do: Enum.any?(errors, &candidate_citation_rejected?/1)

  defp candidate_citation_rejected?(
         %Skopos.Cases.Case.Actions.TargetSelection.CandidateNotOffered{}
       ),
       do: true

  defp candidate_citation_rejected?(_error), do: false

  defp reconsider_target_selection(turn_id) do
    with {:ok, turn} <- Cases.get_turn(turn_id, authorize?: false) do
      case locked_continuation(turn, &continue_after_rejected_target_selection/1) do
        {:ok, _result} ->
          :ok

        {:error, error} ->
          if unexpected_failure?(error),
            do: {:error, error},
            else: require_attention(turn_id, error)
      end
    end
  end

  defp continue_after_rejected_target_selection(turn) do
    continue_with_turn(
      turn,
      "target-selection-rejected",
      "Select a current Target with supporting candidate evidence",
      %{
        "source" => "resolver_target_selection_rejected",
        "rejection_code" => "candidate_citation_changed"
      },
      "Review Resolver limits"
    )
  end

  defp supersede_stale_route(turn) do
    continue_with_turn(
      turn,
      "route-context-changed",
      "Reassess the Case with current Conditions",
      %{},
      "Review Resolver limits"
    )
  end

  defp continue_with_turn(turn, key, objective, context, required_human_input) do
    intent = %{"action" => "continue_resolution", "source_turn_id" => turn.id}

    with {:ok, started} <-
           Cases.start_turn(
             turn.case_id,
             turn.resolution_run_id,
             "resolver:#{key}:#{turn.id}",
             Map.merge(context, %{"objective" => objective, "source_turn_id" => turn.id}),
             intent,
             required_human_input,
             authorize?: false
           ),
         {:ok, _pending} <- set_retry_pending(started, turn.id) do
      {:ok, started}
    end
  end

  defp set_retry_pending(%{status: :exhausted} = result, _source_turn_id),
    do: {:ok, result}

  defp set_retry_pending(
         %{status: :duplicate, value: %{status: :completed}} = result,
         _source_id
       ),
       do: {:ok, result}

  defp set_retry_pending(%{status: status, case: incident, value: next_turn} = result, source_id)
       when status in [:charged, :duplicate] do
    pending = %{
      "action" => "resolve_turn",
      "turn_id" => next_turn.id,
      "source_turn_id" => source_id
    }

    if incident.pending_intent == pending do
      {:ok, result}
    else
      Cases.queue_case_resolver_turn(
        incident,
        incident.revision,
        source_id,
        next_turn.id,
        authorize?: false
      )
    end
  end

  defp dispatch(type, turn_id) when type in ["target_search", "target_selection"],
    do: Cases.route_target_discovery(turn_id, authorize?: false)

  defp dispatch("target_traversal", turn_id),
    do: Cases.route_related_target(turn_id, authorize?: false)

  defp dispatch(type, turn_id)
       when type in ["proposal", "recovery_conclusion", "handoff"],
       do: Cases.route_downstream_decision(turn_id, authorize?: false)

  defp decision_type(%{
         status: :completed,
         result: %{"outcome" => "decision", "intent" => %{"type" => type}}
       })
       when type in [
              "target_search",
              "target_selection",
              "target_traversal",
              "proposal",
              "file_read",
              "case_split",
              "recovery_conclusion",
              "handoff"
            ],
       do: {:ok, type}

  defp decision_type(_turn),
    do:
      {:error,
       Ash.Error.Changes.InvalidChanges.exception(message: "Resolver decision is malformed")}

  defp require_attention(turn_id, route_error) do
    with {:ok, turn} <- Cases.get_turn(turn_id, authorize?: false),
         {:ok, incident} <- Cases.get_case(turn.case_id, authorize?: false),
         {:ok, run} <- Cases.get_resolution_run(turn.resolution_run_id, authorize?: false) do
      if incident.status == :running and run.active and run.status == :running do
        pending = pending_intent(incident.pending_intent, turn.id)

        case Cases.require_case_attention(
               incident.id,
               incident.revision,
               run.id,
               run.revision,
               Budget.key("resolver-route:failure", turn.id),
               "Resolver decision routing failed",
               pending,
               "Review the persisted Resolver decision and resume the Case",
               authorize?: false
             ) do
          {:ok, _updated} -> :ok
          {:error, attention_error} -> {:error, attention_error}
        end
      else
        route_failure(route_error, incident)
      end
    end
  end

  defp pending_intent(current, turn_id) when map_size(current) == 0,
    do: %{"action" => "review_resolver_route", "source_turn_id" => turn_id}

  defp pending_intent(current, _turn_id), do: current

  defp route_failure(_error, %{status: :needs_attention}), do: :ok
  defp route_failure(_error, %{status: :cancelled}), do: {:cancel, "Case was cancelled"}
  defp route_failure(error, _incident), do: {:error, error}
end
