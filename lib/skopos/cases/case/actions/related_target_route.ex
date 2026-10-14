defmodule Skopos.Cases.Case.Actions.RelatedTargetRoute do
  use Ash.Resource.Actions.Implementation

  alias Skopos.{Accounts, Cases, Targets}
  alias Skopos.Cases.{Case, CaseEvent, Evidence, ResolutionRun, Turn}
  alias Skopos.Cases.ResolutionRun.Budget, as: Budget
  alias Skopos.Cases.Evidence.Citation, as: EvidenceCitation
  alias Skopos.Cases.Turn.TraversalBoundary, as: TraversalBoundary

  defmodule Error do
    use Splode.Error, class: :invalid, fields: [:category, :message]

    @impl true
    def message(error), do: error.message
  end

  @impl true
  def run(input, _opts, _context) do
    with {:ok, turn} <- Cases.get_turn(input.arguments.turn_id, authorize?: false),
         {:ok, intent} <- traversal_intent(turn),
         {:ok, incident} <- Cases.get_case(turn.case_id, authorize?: false),
         {:ok, run} <- Cases.get_resolution_run(turn.resolution_run_id, authorize?: false),
         {:ok, existing} <- existing_failure(incident.id, turn.id) do
      if existing do
        continue_after_failure(turn, existing, incident, run)
      else
        traverse(turn, intent, incident, run)
      end
    end
  end

  defp traverse(turn, intent, incident, run) do
    result =
      Budget.consume(
        case_id: incident.id,
        resolution_run_id: run.id,
        kind: :related_target,
        amount: 1,
        ledger_key: traversal_key(turn),
        actor: nil,
        event_type: "related_target_traversed",
        event_data: traversal_event_data(turn, intent),
        pending_intent: %{"action" => "route_related_target", "source_turn_id" => turn.id},
        required_human_input: "Review the related Target limit or continue the Case manually",
        operation: fn locked_case, locked_run ->
          select_related_target(turn, locked_case, locked_run, intent)
        end,
        duplicate: fn current_case, _current_run -> {:ok, current_case} end
      )

    case result do
      {:ok, %{status: :exhausted} = exhausted} ->
        {:ok, exhausted}

      {:ok, %{status: status, case: selected_case, run: charged_run}}
      when status in [:charged, :duplicate] ->
        start_next_turn(turn, selected_case, charged_run, intent)

      {:error, error} ->
        if unexpected_failure?(error),
          do: {:error, error},
          else: persist_failure(turn, intent, incident, run, traversal_error(error))
    end
  end

  defp select_related_target(turn, incident, run, intent) do
    with {:ok, target} <- traversal_context(turn, incident, run, intent),
         {:ok, updated} <-
           Cases.record_case_selected_target(
             incident,
             incident.revision,
             target.id,
             target.revision,
             authorize?: false
           ) do
      {:ok, updated}
    end
  end

  defp traversal_context(turn, incident, run, intent) do
    relationship_snapshot = intent["relationship"]

    with :ok <- running_context(incident, run),
         :ok <- no_immediate_reverse(turn, intent),
         :ok <- cited_evidence(intent["evidence_ids"], incident, run),
         {:ok, relationship} <- current_relationship(relationship_snapshot),
         :ok <- exact_relationship(relationship, relationship_snapshot),
         :ok <- current_endpoint(incident, relationship_snapshot),
         :ok <- next_endpoint(intent, relationship_snapshot, incident),
         {:ok, actor} <- current_actor(incident),
         {:ok, target} <- authorized_target(intent, actor),
         :ok <- available_access_method(target) do
      {:ok, target}
    end
  end

  defp running_context(%{status: :running, cancel_requested: false}, %{
         status: :running,
         active: true
       }),
       do: :ok

  defp running_context(%{cancel_requested: true}, _run),
    do: traversal_failure(:cancelled, "Case cancellation was requested")

  defp running_context(_incident, _run),
    do: traversal_failure(:stale_context, "Case resolution is not running")

  defp no_immediate_reverse(turn, %{"relationship_id" => relationship_id}) do
    if TraversalBoundary.immediate_reverse?(relationship_id, turn.intent),
      do:
        traversal_failure(
          :stale_context,
          "Reassess the selected Target before returning through the same relationship"
        ),
      else: :ok
  end

  defp cited_evidence(ids, incident, run) when is_list(ids) and ids != [] do
    if length(ids) == MapSet.size(MapSet.new(ids)) do
      Enum.reduce_while(ids, :ok, fn id, :ok ->
        case Cases.get_evidence(id, authorize?: false) do
          {:ok, evidence} ->
            case EvidenceCitation.validate(evidence, incident, run) do
              :ok -> {:cont, :ok}
              {:error, _error} = error -> {:halt, error}
            end

          {:error, error} ->
            {:halt,
             traversal_rejection(error, :invalid_evidence, "Cited Evidence is unavailable")}
        end
      end)
    else
      traversal_failure(:invalid_evidence, "Cited Evidence contains duplicates")
    end
  end

  defp cited_evidence(_ids, _incident, _run),
    do: traversal_failure(:invalid_evidence, "Cited Evidence is invalid")

  defp current_relationship(%{"id" => id, "revision" => revision}) do
    case Targets.load_relationship_for_traversal(id, revision, authorize?: false) do
      {:ok, relationship} ->
        {:ok, relationship}

      {:error, error} ->
        traversal_rejection(
          error,
          :stale_relationship,
          "Target relationship is unavailable or changed"
        )
    end
  end

  defp current_relationship(_snapshot),
    do: traversal_failure(:stale_relationship, "Target relationship snapshot is invalid")

  defp exact_relationship(relationship, snapshot) do
    if relationship.source_target_id == snapshot["source_target_id"] and
         relationship.destination_target_id == snapshot["destination_target_id"] and
         relationship.kind == snapshot["kind"] do
      :ok
    else
      traversal_failure(:stale_relationship, "Target relationship changed after selection")
    end
  end

  defp current_endpoint(incident, snapshot) do
    revisions = %{
      snapshot["source_target_id"] => snapshot["source_target_revision"],
      snapshot["destination_target_id"] => snapshot["destination_target_revision"]
    }

    if incident.selected_target_id in Map.keys(revisions) and
         revisions[incident.selected_target_id] == incident.selected_target_revision do
      :ok
    else
      traversal_failure(
        :stale_context,
        "Case selected Target changed after relationship selection"
      )
    end
  end

  defp next_endpoint(intent, snapshot, incident) do
    next_target_id = intent["next_target_id"]

    expected_revision =
      cond do
        snapshot["source_target_id"] == next_target_id ->
          snapshot["source_target_revision"]

        snapshot["destination_target_id"] == next_target_id ->
          snapshot["destination_target_revision"]

        true ->
          nil
      end

    if next_target_id != nil and next_target_id != incident.selected_target_id and
         expected_revision == intent["next_target_revision"] do
      :ok
    else
      traversal_failure(
        :stale_context,
        "Related Target selection does not match the relationship"
      )
    end
  end

  defp current_actor(%{current_owner_id: owner_id}) when is_binary(owner_id) do
    case Accounts.get_user(owner_id, authorize?: false) do
      {:ok, %{role: role} = actor} when role in [:admin, :operator] ->
        {:ok, actor}

      {:error, error} ->
        traversal_rejection(error, :denied, "Case owner cannot authorize related Target access")

      {:ok, _unavailable} ->
        traversal_failure(:denied, "Case owner cannot authorize related Target access")
    end
  end

  defp current_actor(_incident),
    do: traversal_failure(:denied, "Case has no related Target access owner")

  defp authorized_target(intent, actor) do
    expected_revision = intent["next_target_revision"]

    case Targets.get_target(intent["next_target_id"], actor: actor) do
      {:ok, %{active: true, revision: revision} = target} ->
        if revision == expected_revision,
          do: {:ok, target},
          else: traversal_failure(:stale_context, "Related Target changed after selection")

      {:ok, %{active: false}} ->
        traversal_failure(:unavailable, "Related Target is inactive")

      {:error, error} ->
        traversal_rejection(error, :denied, "Case owner is not authorized for the related Target")
    end
  end

  defp available_access_method(target) do
    case Targets.available_access_methods_for_target(target.id, authorize?: false) do
      {:ok, [_method | _rest]} ->
        :ok

      {:ok, []} ->
        traversal_failure(:unavailable, "Related Target has no available Access Method")

      {:error, error} ->
        traversal_rejection(error, :unavailable, "Related Target Access Methods are unavailable")
    end
  end

  defp start_next_turn(turn, incident, run, intent) do
    start_turn_with_pending(
      turn,
      incident,
      run,
      %{
        "objective" => "Continue resolution on the selected related Target",
        "source" => "target_relationship",
        "source_turn_id" => turn.id,
        "relationship_id" => intent["relationship_id"],
        "relationship_revision" => intent["relationship_revision"],
        "selected_target_id" => intent["next_target_id"],
        "evidence_ids" => intent["evidence_ids"],
        "reason" => intent["reason"]
      }
    )
  end

  defp persist_failure(turn, intent, incident, run, {category, message}) do
    spec = failure_spec(intent, category, message)

    Ash.transact([Case, ResolutionRun, Turn, Evidence, CaseEvent], fn ->
      with {:ok, evidence} <- append_failure(turn, spec),
           {:ok, next_turn} <-
             start_turn_with_pending(
               turn,
               incident,
               run,
               %{
                 "objective" => "Continue resolution after a related Target was rejected",
                 "source" => "target_relationship",
                 "source_turn_id" => turn.id,
                 "relationship_id" => intent["relationship_id"],
                 "evidence_id" => evidence.id
               }
             ) do
        next_turn
      end
    end)
  end

  defp continue_after_failure(turn, evidence, incident, run) do
    start_turn_with_pending(turn, incident, run, %{
      "objective" => "Continue resolution after a related Target was rejected",
      "source" => "target_relationship",
      "source_turn_id" => turn.id,
      "relationship_id" => evidence.content["relationship_id"],
      "evidence_id" => evidence.id
    })
  end

  defp start_turn_with_pending(source_turn, incident, run, turn_intent) do
    Ash.transact([Case, ResolutionRun, Turn, CaseEvent], fn ->
      with {:ok, result} <-
             Cases.start_turn(
               incident.id,
               run.id,
               route_key(source_turn, "next-turn"),
               turn_intent,
               %{"action" => "continue_resolution", "source_turn_id" => source_turn.id},
               "Review Resolver limits or continue the Case manually",
               authorize?: false
             ),
           {:ok, result} <- set_pending_turn(result, source_turn.id) do
        result
      end
    end)
  end

  defp set_pending_turn(%{status: :exhausted} = result, _source_turn_id), do: {:ok, result}

  defp set_pending_turn(
         %{status: status, case: incident, value: next_turn} = result,
         source_turn_id
       )
       when status in [:charged, :duplicate] do
    pending = %{
      "action" => "resolve_turn",
      "turn_id" => next_turn.id,
      "source_turn_id" => source_turn_id
    }

    if incident.pending_intent == pending do
      {:ok, result}
    else
      with {:ok, _updated} <-
             Cases.record_case_pending_intent(
               incident,
               incident.revision,
               pending,
               authorize?: false
             ) do
        {:ok, result}
      end
    end
  end

  defp append_failure(turn, spec) do
    Cases.append_evidence(
      turn.case_id,
      turn.resolution_run_id,
      turn.id,
      failure_key(turn),
      "relationship_traversal_error",
      "target_relationship",
      turn.id,
      spec,
      DateTime.utc_now(),
      authorize?: false
    )
  end

  defp existing_failure(case_id, turn_id) do
    Cases.evidence_by_idempotency(case_id, failure_key(turn_id),
      authorize?: false,
      not_found_error?: false
    )
  end

  defp failure_key(%{id: id}), do: failure_key(id)
  defp failure_key(turn_id), do: Budget.key("resolver-route:related-target:failure", turn_id)

  defp failure_spec(intent, category, message) do
    %{
      "status" => "rejected",
      "category" => to_string(category),
      "message" => message,
      "relationship_id" => intent["relationship_id"],
      "relationship_revision" => intent["relationship_revision"],
      "next_target_id" => intent["next_target_id"],
      "next_target_revision" => intent["next_target_revision"]
    }
  end

  defp traversal_event_data(turn, intent) do
    %{
      "source_turn_id" => turn.id,
      "relationship_id" => intent["relationship_id"],
      "relationship_revision" => intent["relationship_revision"],
      "source_target_id" => intent["relationship"]["source_target_id"],
      "source_target_revision" => intent["relationship"]["source_target_revision"],
      "destination_target_id" => intent["relationship"]["destination_target_id"],
      "destination_target_revision" => intent["relationship"]["destination_target_revision"],
      "next_target_id" => intent["next_target_id"],
      "next_target_revision" => intent["next_target_revision"],
      "evidence_ids" => intent["evidence_ids"],
      "reason" => intent["reason"]
    }
  end

  defp traversal_intent(%{
         status: :completed,
         result: %{"outcome" => "decision", "intent" => %{"type" => "target_traversal"} = intent}
       }) do
    required = [
      "relationship_id",
      "relationship_revision",
      "next_target_id",
      "next_target_revision",
      "evidence_ids",
      "reason",
      "relationship"
    ]

    if Enum.all?(required, &Map.has_key?(intent, &1)),
      do: {:ok, intent},
      else: traversal_failure(:invalid_intent, "Target traversal decision is incomplete")
  end

  defp traversal_intent(_turn),
    do:
      traversal_failure(
        :invalid_intent,
        "Completed Turn does not contain a Target traversal decision"
      )

  defp traversal_error(%Error{category: category, message: message}), do: {category, message}

  defp traversal_error(%{errors: errors}) when is_list(errors) do
    Enum.find_value(errors, &find_traversal_error/1) ||
      {:unavailable, "Related Target traversal could not be accepted"}
  end

  defp traversal_error(_error),
    do: {:unavailable, "Related Target traversal could not be accepted"}

  defp find_traversal_error(%Error{} = error), do: traversal_error(error)

  defp find_traversal_error(%{errors: errors}) when is_list(errors),
    do: Enum.find_value(errors, &find_traversal_error/1)

  defp find_traversal_error(_error), do: nil

  defp traversal_failure(category, message),
    do: {:error, Error.exception(category: category, message: message)}

  defp traversal_rejection(error, category, message) do
    if unexpected_failure?(error),
      do: {:error, error},
      else: traversal_failure(category, message)
  end

  defp unexpected_failure?(%Ash.Error.Unknown{}), do: true
  defp unexpected_failure?(%Ash.Error.Framework{}), do: true

  defp unexpected_failure?(%{errors: errors}) when is_list(errors),
    do: Enum.any?(errors, &unexpected_failure?/1)

  defp unexpected_failure?(%{class: class}) when class in [:unknown, :framework], do: true
  defp unexpected_failure?(_error), do: false

  defp traversal_key(turn), do: Budget.key("resolver-route:related-target", turn.id)
  defp route_key(turn, kind), do: "resolver-route:#{turn.id}:related-target:#{kind}"
end
