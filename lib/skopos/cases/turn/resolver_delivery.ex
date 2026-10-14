defmodule Skopos.Cases.Turn.ResolverDelivery do
  @moduledoc false

  require Ash.Query

  alias Skopos.{Cases, Providers}

  alias Skopos.Cases.{AIInvocation, Case, CaseEvent, ResolutionRun, Turn}
  alias Skopos.Cases.Turn.ResolverProjection, as: ResolverProjection
  alias Skopos.Cases.ResolutionRun.Budget, as: Budget

  alias Skopos.Cases.Case.AdmissionLock, as: CaseAdmissionLock
  alias Skopos.Cases.Case.ConditionContext, as: ConditionContext
  alias Skopos.Cases.Case.InvocationContext

  alias Skopos.Cases.AIInvocation.Claim, as: AIInvocationClaim
  alias Skopos.Cases.ResolutionRun.BudgetResult

  alias Skopos.Providers.AI

  @max_result_bytes Turn.max_result_bytes()

  @spec run(String.t(), keyword()) ::
          :ok | {:cancel, String.t()} | {:snooze, pos_integer()} | {:error, term()}
  def run(turn_id, opts \\ []) do
    with {:ok, turn} <- Cases.get_turn(turn_id, authorize?: false),
         {:ok, incident} <- Cases.get_case(turn.case_id, authorize?: false) do
      cond do
        incident.cancel_requested or incident.status != :running ->
          with {:ok, :ok} <-
                 Cases.settle_stopped_ai_invocations(
                   turn.case_id,
                   turn.resolution_run_id,
                   :resolver,
                   turn.id,
                   nil,
                   authorize?: false
                 ) do
            if incident.cancel_requested,
              do: {:cancel, "Case resolution was cancelled"},
              else: :ok
          end

        turn.status == :completed ->
          continue_saved_result(turn)

        true ->
          deliver(turn, opts)
      end
    end
  end

  defp deliver(turn, opts) do
    with {:ok, selection} <- assigned_selection(turn),
         {:ok, selection} <- current_selection(selection),
         {:ok, request, context} <- ResolverProjection.build(turn.id, selection) do
      resolve(turn, selection, request, context, opts)
    else
      {:error, error} -> handle_admission_failure(turn, error)
    end
  end

  defp handle_admission_failure(turn, error) do
    if match?(%AI.Error{category: :unavailable}, AI.Error.unwrap(error)) do
      Ash.transact([AIInvocation, Case, ResolutionRun, Turn, CaseEvent], fn ->
        with :ok <- CaseAdmissionLock.acquire(),
             {:ok, invocations} <-
               Cases.list_ai_invocations(
                 query: [
                   filter: [
                     case_id: turn.case_id,
                     resolution_run_id: turn.resolution_run_id,
                     turn_id: turn.id,
                     role: :resolver,
                     status: [in: [:dispatching, :unknown]]
                   ],
                   sort: [dispatch_started_at: :asc],
                   limit: 1
                 ],
                 authorize?: false
               ) do
          case invocations do
            [%{status: :dispatching} = invocation] ->
              with {:ok, unknown} <-
                     record_invocation(invocation, :unknown,
                       category: "response_unknown",
                       failure_code: "response_unknown"
                     ),
                   do: handle_interruption(turn, unknown)

            [unknown] ->
              handle_interruption(turn, unknown)

            [] ->
              handle_failure(turn, error)
          end
        end
      end)
      |> case do
        {:ok, result} -> result
        {:error, _cause} = failure -> failure
      end
    else
      handle_failure(turn, error)
    end
  end

  defp resolve(turn, selection, request, context, opts) do
    case claim_invocation(turn, selection, request, context) do
      {:ok, %AIInvocationClaim{state: :claimed} = claim} ->
        dispatch(turn, selection, request, claim, opts)

      {:ok, %AIInvocationClaim{state: :interrupted, invocation: invocation}} ->
        handle_interruption(turn, invocation)

      {:ok, %AIInvocationClaim{state: :terminal}} ->
        with {:ok, current} <- Cases.get_turn(turn.id, authorize?: false) do
          if current.status == :completed,
            do: continue_saved_result(current),
            else: {:error, "AI invocation is already terminal"}
        end

      {:error, error} ->
        case Cases.invocation_context_current(context, authorize?: false) do
          {:ok, true} -> handle_failure(turn, error)
          {:ok, false} -> retry_changed_context(turn)
          {:error, cause} -> {:error, Ash.Error.to_error_class([error, cause])}
        end
    end
  end

  defp dispatch(turn, selection, request, claim, opts) do
    outcome =
      InvocationContext.with_invocation(
        claim.invocation_context,
        Keyword.get(opts, :ai_invocation, %{}),
        fn invocation ->
          Providers.ai_resolve(selection.provider_id, request, invocation, authorize?: false)
        end
      )

    case outcome do
      {:ok, decision} ->
        accept_decision(turn, selection, request, claim.invocation, decision)

      {:error, error} ->
        if AIInvocation.retryable_unsent?(error) do
          case Cases.retry_unsent_ai_invocation(
                 claim.invocation,
                 claim.invocation.revision,
                 error,
                 authorize?: false
               ) do
            {:ok, _queued} -> {:error, error}
            {:error, save_error} -> {:error, Ash.Error.to_error_class([error, save_error])}
          end
        else
          handle_dispatch_failure(turn, error, claim)
        end
    end
  end

  defp handle_dispatch_failure(turn, error, claim) do
    if match?(%AI.Error{category: :cancelled}, AI.Error.unwrap(error)) do
      case Cases.invocation_context_current(claim.invocation_context, authorize?: false) do
        {:ok, false} ->
          Ash.transact([AIInvocation, Case, ResolutionRun, Turn, CaseEvent], fn ->
            with :ok <- CaseAdmissionLock.acquire(),
                 {:ok, _settled} <-
                   settle_failed_usage(turn, claim.invocation, "context_changed", error) do
              retry_changed_context(turn)
            end
          end)
          |> case do
            {:ok, result} -> result
            {:error, _cause} = failed -> failed
          end

        {:ok, true} ->
          handle_failure(turn, error, claim.invocation)

        {:error, cause} ->
          {:error, Ash.Error.to_error_class([error, cause])}
      end
    else
      handle_failure(turn, error, claim.invocation)
    end
  end

  defp accept_decision(turn, selection, request, invocation, decision) do
    with {:ok, result} <- result(decision, selection, request),
         :ok <- valid_result_size(result) do
      case accept(turn, invocation, decision, result, request) do
        {:ok, _accepted} ->
          with {:ok, current} <- Cases.get_turn(turn.id, authorize?: false) do
            continue_saved_result(current)
          end

        {:error, :context_changed} ->
          with {:ok, _charged} <-
                 settle_unused_result(turn, invocation, decision, "context_changed") do
            retry_changed_context(turn)
          end

        {:error, error} ->
          handle_failure(turn, error, invocation)
      end
    else
      {:error, error} -> handle_failure(turn, error, invocation)
    end
  end

  defp claim_invocation(turn, selection, request, context) do
    with {:ok, incident} <- Cases.get_case(turn.case_id, authorize?: false),
         {:ok, true} <- resolver_context_matches(incident, request) do
      Cases.claim_ai_invocation(
        :resolver,
        turn.case_id,
        context.case_revision,
        turn.resolution_run_id,
        turn.id,
        turn.revision,
        nil,
        nil,
        selection.provider_id,
        selection.assignment_id,
        selection.provider_revision,
        selection.assignment_revision,
        selection.source,
        AIInvocation.request_digest(request),
        nil,
        %{
          invocation_context: context,
          request_size_bytes: AI.resolver_disclosure_size(request)
        },
        authorize?: false
      )
    else
      {:ok, false} -> {:error, :context_changed}
      error -> error
    end
  end

  defp assigned_selection(turn) do
    key = assignment_key(turn.id)

    case Cases.case_event_by_idempotency(turn.case_id, key,
           authorize?: false,
           not_found_error?: false
         ) do
      {:ok, %CaseEvent{} = event} ->
        selection_from_event(event, turn)

      {:ok, nil} ->
        create_assignment(turn, key)

      {:error, error} ->
        {:error, error}
    end
  end

  defp create_assignment(turn, key) do
    with {:ok, %AI.Selection{role: :resolver} = selection} <-
           Providers.select_resolver_ai(authorize?: false),
         {:ok, _event} <- create_assignment_event(turn, key, selection) do
      {:ok, selection}
    else
      {:error, _error} = error ->
        case Cases.case_event_by_idempotency(turn.case_id, key,
               authorize?: false,
               not_found_error?: false
             ) do
          {:ok, %CaseEvent{} = event} -> selection_from_event(event, turn)
          _missing -> error
        end
    end
  end

  defp create_assignment_event(turn, key, selection) do
    Cases.create_case_event_record(
      %{
        case_id: turn.case_id,
        resolution_run_id: turn.resolution_run_id,
        event_type: "resolver_assigned",
        idempotency_key: key,
        data: %{
          "turn_id" => turn.id,
          "provider_id" => selection.provider_id,
          "provider_revision" => selection.provider_revision,
          "assignment_id" => selection.assignment_id,
          "assignment_revision" => selection.assignment_revision,
          "source" => to_string(selection.source)
        }
      },
      authorize?: false
    )
  end

  defp selection_from_event(
         %CaseEvent{
           resolution_run_id: run_id,
           data: %{
             "turn_id" => turn_id,
             "provider_id" => provider_id,
             "provider_revision" => provider_revision,
             "assignment_id" => assignment_id,
             "assignment_revision" => assignment_revision,
             "source" => "assignment"
           }
         },
         turn
       )
       when run_id == turn.resolution_run_id and turn_id == turn.id and is_binary(provider_id) and
              is_integer(provider_revision) and provider_revision > 0 and is_binary(assignment_id) and
              is_integer(assignment_revision) and assignment_revision > 0 do
    {:ok,
     %AI.Selection{
       role: :resolver,
       provider_id: provider_id,
       provider_revision: provider_revision,
       source: :assignment,
       assignment_id: assignment_id,
       assignment_revision: assignment_revision
     }}
  end

  defp selection_from_event(_event, _turn),
    do: {:error, ai_error(:invalid_input, "Persisted Resolver assignment is invalid")}

  defp current_selection(selection) do
    with {:ok, assignment} <-
           Providers.load_current_ai_usage_role_assignment(
             selection.assignment_id,
             :resolver,
             selection.assignment_revision,
             selection.provider_revision,
             authorize?: false
           ),
         true <-
           assignment.provider_id == selection.provider_id ||
             {:error, ai_error(:unavailable, "Resolver AI assignment changed")} do
      {:ok, selection}
    else
      {:error, %AI.Error{} = error} ->
        {:error, error}

      {:error, error} = failure ->
        if AI.Error.context_failure?(error) or AI.Error.unwrap(error),
          do: failure,
          else: {:error, ai_error(:unavailable, "Resolver AI is unavailable")}
    end
  end

  defp resolver_context_matches(incident, request) do
    if case_context_matches?(incident, request) do
      case ConditionContext.current_conditions(incident) do
        {:ok, conditions} ->
          same_conditions? =
            conditions ==
              Enum.map(
                request.conditions,
                &%{
                  &1
                  | recovery_status: nil,
                    recovery_evidence_ids: [],
                    failed_observation_ids: []
                }
              ) and
              ConditionContext.projected_alert_state(incident, conditions) ==
                request.alert_state

          if same_conditions? do
            case ConditionContext.current_condition_context(incident) do
              {:ok, {assessed, _proof_ids}} -> {:ok, assessed == request.conditions}
              {:error, _cause} = error -> error
            end
          else
            {:ok, same_conditions?}
          end

        {:error, _cause} = error ->
          error
      end
    else
      {:ok, false}
    end
  end

  defp case_context_matches?(incident, request) do
    incident.status == :running and not incident.cancel_requested and
      incident.selected_target_id == request.selected_target_id and
      incident.selected_target_revision == request.selected_target_revision
  end

  defp retry_changed_context(turn) do
    with {:ok, cancelled?} <- case_cancelled?(turn.case_id) do
      cond do
        cancelled? -> {:cancel, "Case resolution was cancelled"}
        turn_completed?(turn.id) -> :ok
        true -> supersede_changed_context(turn)
      end
    end
  end

  defp supersede_changed_context(turn) do
    intent = %{"action" => "continue_resolution", "source_turn_id" => turn.id}

    Ash.transact([Case, ResolutionRun, Turn, CaseEvent], fn ->
      with :ok <- CaseAdmissionLock.acquire(),
           {:ok, current} <- Cases.get_turn(turn.id, authorize?: false),
           true <- current.status == :started || {:error, "Resolver Turn is already finalized"},
           {:ok, _completed} <-
             Cases.complete_turn(
               current.id,
               current.revision,
               %{"outcome" => "context_changed"},
               :none,
               intent,
               "Continue resolution with current Conditions",
               authorize?: false
             ),
           {:ok, successor} <-
             Cases.start_turn(
               turn.case_id,
               turn.resolution_run_id,
               "resolver:context-changed:#{turn.id}",
               %{
                 "objective" => "Reassess the Case with current Conditions",
                 "source_turn_id" => turn.id
               },
               intent,
               "Review Resolver limits",
               authorize?: false
             ),
           {:ok, _pending} <- set_retry_pending(successor, turn.id) do
        :ok
      end
    end)
    |> case do
      {:ok, :ok} -> :ok
      {:error, error} -> if(turn_completed?(turn.id), do: :ok, else: {:error, error})
    end
  end

  defp case_cancelled?(case_id) do
    case Cases.get_case(case_id, authorize?: false) do
      {:ok, %{cancel_requested: true}} -> {:ok, true}
      {:ok, %{status: status}} when status != :running -> {:ok, true}
      {:ok, _incident} -> {:ok, false}
      {:error, _error} = error -> error
    end
  end

  defp accept(turn, invocation, decision, result, request) do
    usage_units = decision.usage.input_tokens + decision.usage.output_tokens
    progress_kind = progress_kind(decision.intent, request)

    Ash.transact([AIInvocation, Case, ResolutionRun, Turn, CaseEvent], fn ->
      with :ok <- CaseAdmissionLock.acquire(),
           {:ok, incident} <- lock_case(turn.case_id),
           true <- case_context_matches?(incident, request) || :context_changed,
           {:ok, usage_result} <-
             charge_usage(turn, usage_units, "resolver-result:#{invocation.id}"),
           true <-
             usage_result.status in [:charged, :duplicate] ||
               {:error, "AI usage limit exhausted"},
           {:ok, completion} <-
             Cases.complete_turn(
               turn.id,
               turn.revision,
               result,
               progress_kind,
               %{"action" => "route_resolver_decision", "turn_id" => turn.id},
               "Review the Resolver decision",
               authorize?: false
             ),
           {:ok, _invocation} <-
             record_invocation(invocation, :completed,
               usage: decision.usage,
               result_digest: digest(result)
             ) do
        completion
      end
    end)
    |> accepted_or_existing(turn, invocation, decision)
  end

  defp lock_case(case_id) do
    Case
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(id: case_id)
    |> Ash.Query.lock(:for_update)
    |> Ash.read_one(authorize?: false)
    |> case do
      {:ok, nil} -> {:error, "Case is unavailable"}
      result -> result
    end
  end

  defp charge_usage(turn, 0, _idempotency_key) do
    with {:ok, incident} <- Cases.get_case(turn.case_id, authorize?: false),
         {:ok, run} <- Cases.get_resolution_run(turn.resolution_run_id, authorize?: false) do
      {:ok, %BudgetResult{status: :charged, case: incident, run: run, value: run}}
    end
  end

  defp charge_usage(turn, usage_units, idempotency_key) do
    Cases.charge_resolution_run(
      turn.case_id,
      turn.resolution_run_id,
      :ai_usage,
      usage_units,
      idempotency_key,
      %{"action" => "review_ai_usage", "turn_id" => turn.id},
      "Increase the AI usage limit or review the Case",
      authorize?: false
    )
  end

  defp enqueue_route(turn_id) do
    %{"turn_id" => turn_id}
    |> Skopos.Cases.Case.DecisionRouteWorker.new()
    |> Oban.insert()
  end

  defp continue_saved_result(%{status: :completed, result: %{"outcome" => "decision"}} = turn) do
    with {:ok, job} <- enqueue_route(turn.id),
         true <- is_integer(job.id) || {:error, "Resolver decision route job was not persisted"} do
      :ok
    end
  end

  defp continue_saved_result(_turn), do: :ok

  defp accepted_or_existing({:ok, result}, _turn, _invocation, _decision), do: {:ok, result}

  defp accepted_or_existing({:error, error}, turn, invocation, decision) do
    case Cases.get_turn(turn.id, authorize?: false) do
      {:ok, %{status: :completed} = completed} ->
        case settle_unused_result(turn, invocation, decision, "superseded") do
          {:ok, _invocation} -> {:ok, completed}
          {:error, settle_error} -> {:error, settle_error}
        end

      _unfinished ->
        {:error, error}
    end
  end

  defp result(decision, selection, request) do
    with {:ok, intent} <- intent(decision.intent, request) do
      {:ok,
       %{
         "outcome" => "decision",
         "intent" => intent,
         "usage" => %{
           "input_tokens" => decision.usage.input_tokens,
           "output_tokens" => decision.usage.output_tokens
         },
         "condition_revisions" => ConditionContext.condition_revisions(request.conditions),
         "condition_groups" =>
           AI.normalize_condition_groups(
             decision.condition_groups,
             request.conditions,
             request.evidence ++ request.observation_results
           ),
         "condition_assessments" => decision.condition_assessments,
         "resolver" => %{
           "provider_id" => selection.provider_id,
           "provider_revision" => selection.provider_revision,
           "assignment_id" => selection.assignment_id,
           "assignment_revision" => selection.assignment_revision
         }
       }}
    end
  end

  defp intent(%AI.Proposal{} = value, request) do
    with {:ok, request_tool} <- proposal_tool(request, value.tool_id) do
      snapshot = value |> typed_intent() |> Map.put("tool", tool_snapshot(request_tool))

      case value.verification_intent do
        %AI.VerificationIntent{tool_id: tool_id} ->
          with {:ok, verification_tool} <- verification_tool(request, tool_id) do
            {:ok, Map.put(snapshot, "verification_tool", tool_snapshot(verification_tool))}
          end

        nil ->
          {:ok, Map.put(snapshot, "verification_tool", %{})}
      end
    end
  end

  defp intent(%AI.TargetTraversal{} = value, request) do
    with {:ok, relationship} <- relationship(request, value.relationship_id) do
      {:ok,
       value
       |> typed_intent()
       |> Map.put("relationship", relationship_snapshot(relationship))}
    end
  end

  defp intent(%_{} = value, _request), do: {:ok, typed_intent(value)}

  defp typed_intent(%module{} = value),
    do:
      value
      |> json_value()
      |> Map.put("type", module |> Module.split() |> List.last() |> Macro.underscore())

  defp observation_tool(request, tool_id) do
    case Enum.find(request.observation_tools, &(&1.id == tool_id)) do
      %AI.ObservationTool{} = tool ->
        {:ok, tool}

      _missing ->
        {:error, ai_error(:invalid_output, "AI observation tool snapshot is unavailable")}
    end
  end

  defp proposal_tool(request, tool_id) do
    case Enum.find(request.proposal_tools, &(&1.id == tool_id)) do
      %AI.ProposalTool{} = tool ->
        {:ok, tool}

      _missing ->
        {:error, ai_error(:invalid_output, "AI Proposal tool snapshot is unavailable")}
    end
  end

  defp verification_tool(request, tool_id) do
    observation_tool(request, tool_id)
  end

  defp relationship(request, relationship_id) do
    case Enum.find(request.target_relations, &(&1.id == relationship_id)) do
      %AI.TargetRelation{} = relationship ->
        {:ok, relationship}

      _missing ->
        {:error, ai_error(:invalid_output, "AI Target relationship snapshot is unavailable")}
    end
  end

  defp relationship_snapshot(relationship) do
    %{
      "id" => relationship.id,
      "revision" => relationship.revision,
      "source_target_id" => relationship.source_target.id,
      "source_target_revision" => relationship.source_target.revision,
      "destination_target_id" => relationship.destination_target.id,
      "destination_target_revision" => relationship.destination_target.revision,
      "kind" => relationship.kind
    }
  end

  defp tool_snapshot(%AI.ProposalTool{} = tool) do
    tool
    |> common_tool_snapshot()
    |> Map.put("request_kind", to_string(tool.request_kind))
  end

  defp tool_snapshot(tool), do: common_tool_snapshot(tool)

  defp common_tool_snapshot(tool) do
    %{
      "id" => tool.id,
      "target_id" => tool.target_id,
      "target_revision" => tool.target_revision,
      "access_method_id" => tool.access_method_id,
      "access_method_revision" => tool.access_method_revision,
      "provider_id" => tool.provider_id,
      "provider_revision" => tool.provider_revision,
      "capability" => tool.capability,
      "operation" => tool.operation
    }
  end

  defp json_value(%_{} = value), do: value |> Map.from_struct() |> json_value()

  defp json_value(value) when is_map(value),
    do: Map.new(value, fn {key, nested} -> {to_string(key), json_value(nested)} end)

  defp json_value(value) when is_list(value), do: Enum.map(value, &json_value/1)
  defp json_value(value) when value in [true, false, nil], do: value
  defp json_value(value) when is_atom(value), do: to_string(value)
  defp json_value(value), do: value

  defp progress_kind(%AI.Proposal{purpose: :investigation}, _request),
    do: :observation_pending

  defp progress_kind(%AI.FileRead{}, _request), do: :observation_pending

  defp progress_kind(%AI.Proposal{}, _request), do: :proposal
  defp progress_kind(%AI.RecoveryConclusion{}, _request), do: :source_change
  defp progress_kind(%AI.Handoff{}, _request), do: :human_input

  defp progress_kind(%AI.TargetSelection{target_id: id, target_revision: revision}, request)
       when id == request.selected_target_id and revision == request.selected_target_revision,
       do: :none

  defp progress_kind(_intent, _request), do: :hypothesis

  defp valid_result_size(result) do
    case Jason.encode(result) do
      {:ok, encoded} when byte_size(encoded) <= @max_result_bytes -> :ok
      _invalid -> {:error, ai_error(:invalid_output, "AI Resolver result is too large")}
    end
  end

  defp handle_interruption(turn, invocation) do
    reason = "Resolver response was lost after dispatch; retrying autonomously"
    intent = %{"action" => "continue_resolution", "source_turn_id" => turn.id}

    Ash.transact([AIInvocation, Case, ResolutionRun, Turn, CaseEvent], fn ->
      with {:ok, usage_result} <-
             charge_usage(
               turn,
               invocation.reserved_units,
               "resolver-unknown:#{invocation.id}"
             ),
           {:ok, result} <- retry_interrupted(turn, invocation, usage_result, intent, reason) do
        result
      end
    end)
    |> case do
      {:ok, _incident} -> :ok
      {:error, error} -> if(turn_completed?(turn.id), do: :ok, else: {:error, error})
    end
  end

  defp retry_interrupted(_turn, _invocation, %{status: :exhausted} = result, _intent, _reason),
    do: {:ok, result}

  defp retry_interrupted(turn, invocation, %{status: status}, intent, reason)
       when status in [:charged, :duplicate] do
    with {:ok, completed} <-
           Cases.complete_turn(
             turn.id,
             turn.revision,
             %{
               "outcome" => "delivery_unknown",
               "category" => "response_unknown",
               "message" => reason,
               "reserved_usage_units" => invocation.reserved_units
             },
             :none,
             intent,
             "Continue autonomous resolution after the lost Resolver response",
             authorize?: false
           ),
         {:ok, next_turn} <-
           Cases.start_turn(
             turn.case_id,
             turn.resolution_run_id,
             "resolver:response-unknown:#{invocation.id}",
             %{
               "objective" => "Continue resolution after a lost Resolver response",
               "source" => "resolver_delivery_interruption",
               "source_turn_id" => turn.id,
               "ai_invocation_id" => invocation.id
             },
             intent,
             "Continue autonomous resolution after the lost Resolver response",
             authorize?: false
           ),
         {:ok, next_turn} <- set_retry_pending(next_turn, turn.id) do
      {:ok, %{completed: completed, next_turn: next_turn}}
    end
  end

  defp handle_failure(turn, error, invocation \\ nil) do
    if is_nil(invocation) and AI.Error.context_failure?(error) do
      {:error, error}
    else
      with {:ok, cancelled?} <- case_cancelled?(turn.case_id) do
        cond do
          cancelled? ->
            {:cancel, "Case resolution was cancelled"}

          turn_completed?(turn.id) ->
            :ok

          true ->
            {category, message} = failure(error)
            rejection_code = rejection_code(error)

            case persist_failure(
                   turn,
                   invocation,
                   error,
                   category,
                   message,
                   rejection_code
                 ) do
              {:ok, _incident} ->
                if AI.Error.context_failure?(error), do: {:error, error}, else: :ok

              {:error, persistence_error} ->
                if AI.Error.context_failure?(error) do
                  {:error, Ash.Error.to_error_class([error, persistence_error])}
                else
                  if turn_completed?(turn.id), do: :ok, else: {:error, persistence_error}
                end
            end
        end
      end
    end
  end

  defp persist_failure(
         turn,
         invocation,
         error,
         category,
         message,
         rejection_code
       ) do
    cond do
      category == "invalid_output" ->
        persist_invalid_decision_failure(
          turn,
          invocation,
          error,
          category,
          message,
          rejection_code
        )

      retryable_failure?(category) ->
        persist_retryable_failure(turn, invocation, error, category, message, rejection_code)

      true ->
        persist_attention_failure(turn, invocation, error, category, message, rejection_code)
    end
  end

  defp persist_invalid_decision_failure(
         turn,
         invocation,
         error,
         category,
         message,
         rejection_code
       ) do
    if retryable_invalid_decision_failure?(turn, rejection_code, error),
      do: persist_retryable_failure(turn, invocation, error, category, message, rejection_code),
      else: persist_attention_failure(turn, invocation, error, category, message, rejection_code)
  end

  defp retryable_invalid_decision_failure?(turn, rejection_code, error) do
    rejection_code in [
      "schema_validation",
      "missing_structured_object",
      "json_decode",
      "truncated"
    ] and
      turn.intent["source"] != "resolver_delivery_failure" and
      match?(%AI.Usage{}, AIInvocation.failure_accounting(error, 0).usage)
  end

  defp persist_retryable_failure(turn, invocation, error, category, message, rejection_code) do
    intent = %{"action" => "continue_resolution", "source_turn_id" => turn.id}

    Ash.transact([AIInvocation, Case, ResolutionRun, Turn, CaseEvent], fn ->
      with {:ok, incident} <- lock_case(turn.case_id),
           true <-
             (incident.status == :running and not incident.cancel_requested) ||
               {:error, "Case resolution is not running"},
           {:ok, _completed} <-
             Cases.complete_turn(
               turn.id,
               turn.revision,
               %{
                 "outcome" => "delivery_failed",
                 "category" => category,
                 "rejection_code" => rejection_code,
                 "message" => String.slice(message, 0, 1_000)
               },
               :delivery_retry,
               intent,
               "Review Resolver limits or continue the Case manually",
               authorize?: false
             ),
           {:ok, _invocation} <- record_failure(turn, invocation, category, error) do
        Cases.route_resolver_failure(
          turn.id,
          category,
          rejection_code,
          rejection_path(error),
          authorize?: false
        )
      end
    end)
  end

  defp retryable_failure?(category),
    do: category in ["timeout", "unreachable", "rate_limited", "failed"]

  defp set_retry_pending(%{status: :exhausted} = result, _source_turn_id), do: {:ok, result}

  defp set_retry_pending(
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
             Cases.queue_case_resolver_turn(
               incident,
               incident.revision,
               source_turn_id,
               next_turn.id,
               authorize?: false
             ) do
        {:ok, result}
      end
    end
  end

  defp persist_attention_failure(turn, invocation, error, category, message, rejection_code) do
    reason =
      if rejection_code == "truncated",
        do: "Resolver output reached the configured token limit",
        else: String.slice("Resolver delivery #{category}: #{message}", 0, 500)

    required_input =
      if rejection_code == "truncated",
        do: "Increase this AI connection's max output tokens, then resume the Case",
        else: "Review the Resolver delivery failure"

    intent = %{"action" => "retry_resolver", "turn_id" => turn.id}

    Ash.transact([AIInvocation, Case, ResolutionRun, Turn, CaseEvent], fn ->
      with {:ok, _completed} <-
             Cases.complete_turn(
               turn.id,
               turn.revision,
               %{
                 "outcome" => "delivery_failed",
                 "category" => category,
                 "rejection_code" => rejection_code,
                 "message" => String.slice(message, 0, 1_000)
               },
               :human_input,
               intent,
               required_input,
               authorize?: false
             ),
           {:ok, _invocation} <- record_failure(turn, invocation, category, error),
           {:ok, current_case} <- Cases.get_case(turn.case_id, authorize?: false),
           {:ok, current_run} <-
             Cases.get_resolution_run(turn.resolution_run_id, authorize?: false),
           {:ok, incident} <-
             if(current_case.status == :needs_attention,
               do: {:ok, current_case},
               else:
                 Cases.require_case_attention(
                   turn.case_id,
                   current_case.revision,
                   turn.resolution_run_id,
                   current_run.revision,
                   "resolver-failure:#{turn.id}",
                   reason,
                   intent,
                   required_input,
                   authorize?: false
                 )
             ) do
        incident
      end
    end)
  end

  defp settle_unused_result(turn, invocation, decision, category) do
    amount = decision.usage.input_tokens + decision.usage.output_tokens

    Ash.transact([AIInvocation, Case, ResolutionRun, CaseEvent], fn ->
      with {:ok, charged} <-
             charge_usage(turn, amount, "resolver-result:#{invocation.id}"),
           true <-
             charged.status in [:charged, :duplicate] ||
               {:error, "AI usage limit exhausted"},
           {:ok, invocation} <-
             record_invocation(invocation, :completed,
               usage: decision.usage,
               category: category,
               result_digest: digest(decision)
             ) do
        invocation
      end
    end)
  end

  defp record_failure(_turn, nil, _category, _error), do: {:ok, nil}

  defp record_failure(turn, invocation, category, error),
    do: settle_failed_usage(turn, invocation, category, error)

  defp settle_failed_usage(turn, invocation, category, error) do
    accounting = AIInvocation.failure_accounting(error, invocation.reserved_units)
    usage = accounting.usage

    key =
      if usage, do: "resolver-result:#{invocation.id}", else: "resolver-unknown:#{invocation.id}"

    with {:ok, _charged} <- charge_usage(turn, accounting.amount, key),
         {:ok, recorded} <-
           record_invocation(invocation, :failed,
             usage: usage,
             dispatched?: accounting.dispatched?,
             category: category,
             failure_code: rejection_code(error),
             rejection_path: rejection_path(error)
           ) do
      {:ok, recorded}
    end
  end

  defp record_invocation(invocation, status, attrs) do
    usage = Keyword.get(attrs, :usage)

    Cases.record_ai_invocation_outcome(
      invocation,
      invocation.revision,
      %{
        status: status,
        usage: usage,
        dispatched?: Keyword.get(attrs, :dispatched?),
        category: Keyword.get(attrs, :category),
        failure_code: Keyword.get(attrs, :failure_code),
        rejection_path: Keyword.get(attrs, :rejection_path),
        result_digest: Keyword.get(attrs, :result_digest),
        completed_at: DateTime.utc_now()
      },
      authorize?: false
    )
  end

  defp digest(value) do
    value
    |> :erlang.term_to_binary([:deterministic])
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp failure(error) do
    case AI.Error.unwrap(error) do
      %AI.Error{category: category} -> {to_string(category), public_failure(category)}
      _error -> {"failed", "Resolver delivery failed"}
    end
  end

  defp public_failure(:authentication), do: "Resolver authentication failed"
  defp public_failure(:unreachable), do: "Resolver AI is unreachable"
  defp public_failure(:timeout), do: "Resolver AI timed out"
  defp public_failure(:rate_limited), do: "Resolver AI rate limit was exceeded"
  defp public_failure(:cancelled), do: "Resolver decision was cancelled"
  defp public_failure(:invalid_input), do: "Resolver input is invalid"
  defp public_failure(:invalid_output), do: "Resolver output is invalid"
  defp public_failure(:unavailable), do: "Resolver AI is unavailable"
  defp public_failure(_category), do: "Resolver delivery failed"

  defp rejection_code(error) do
    case AI.Error.unwrap(error) do
      %AI.Error{category: :invalid_output, failure_code: code} when is_binary(code) -> code
      %AI.Error{category: :invalid_output} -> "invalid_output"
      _error -> nil
    end
  end

  defp rejection_path(error), do: AIInvocation.rejection_path(error)

  defp turn_completed?(turn_id) do
    match?({:ok, %{status: :completed}}, Cases.get_turn(turn_id, authorize?: false))
  end

  defp assignment_key(turn_id), do: Budget.key("turn:resolver_assignment", turn_id)
  defp ai_error(category, message), do: AI.Error.exception(category: category, message: message)
end
