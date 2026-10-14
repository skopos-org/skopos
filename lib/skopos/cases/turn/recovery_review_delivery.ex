defmodule Skopos.Cases.Turn.RecoveryReviewDelivery do
  @moduledoc false

  alias Skopos.{Cases, Providers}

  alias Skopos.Cases.{AIInvocation, Case, CaseEvent, ResolutionRun, Turn}
  alias Skopos.Cases.Turn.RecoveryReviewFingerprint, as: RecoveryReviewFingerprint

  alias Skopos.Cases.ResolutionRun.Budget, as: Budget

  alias Skopos.Cases.Case.AdmissionLock, as: CaseAdmissionLock

  alias Skopos.Cases.AIInvocation.Claim, as: AIInvocationClaim
  alias Skopos.Cases.ResolutionRun.BudgetResult

  alias Skopos.Providers.AI

  def run(turn_id, opts \\ []) do
    with {:ok, turn} <- Cases.get_turn(turn_id, authorize?: false),
         {:ok, event} <- result_event(turn) do
      if event do
        apply_result(turn, event)
      else
        with {:ok, incident} <- Cases.get_case(turn.case_id, authorize?: false) do
          cond do
            incident.status != :running or incident.cancel_requested ->
              with {:ok, :ok} <-
                     Cases.settle_stopped_ai_invocations(
                       turn.case_id,
                       turn.resolution_run_id,
                       :reviewer,
                       turn.id,
                       nil,
                       authorize?: false
                     ),
                   do: :ok

            incident.pending_intent == %{"action" => "review_recovery", "turn_id" => turn.id} ->
              deliver(turn, opts)

            true ->
              :ok
          end
        end
      end
    end
  end

  defp deliver(turn, opts) do
    with {:ok, selection} <- selection(turn),
         {:ok, selection} <- current_selection(selection),
         {:ok, retry_context} <- retry_context(turn),
         {:ok, request, context} <-
           Skopos.Cases.Turn.RecoveryReviewProjection.build(
             turn.id,
             selection,
             retry_context
           ),
         {:ok, %AIInvocationClaim{} = claim} <-
           claim(turn, context, selection, request, delivery_attempt(opts)) do
      dispatch(turn, selection, request, claim, opts)
    else
      {:error, error} = failure ->
        if AI.Error.context_failure?(error),
          do: failure,
          else: reconcile_admission_failure(turn, error)
    end
  end

  defp reconcile_admission_failure(turn, error) do
    with {:ok, invocations} <-
           Cases.list_ai_invocations(
             query: [
               filter: [
                 case_id: turn.case_id,
                 resolution_run_id: turn.resolution_run_id,
                 turn_id: turn.id,
                 role: :reviewer,
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
                 Cases.record_ai_invocation_outcome(
                   invocation,
                   invocation.revision,
                   %{
                     status: :unknown,
                     category: "response_unknown",
                     failure_code: "response_unknown",
                     completed_at: DateTime.utc_now()
                   },
                   authorize?: false
                 ),
               do: settle_interruption(turn, unknown)

        [unknown] ->
          settle_interruption(turn, unknown)

        [] ->
          attention(turn, "Recovery Reviewer is unavailable", error)
      end
    end
  end

  defp current_selection(%AI.Selection{source: :assignment} = selection) do
    case Providers.load_current_ai_usage_role_assignment(
           selection.assignment_id,
           :reviewer,
           selection.assignment_revision,
           selection.provider_revision,
           authorize?: false,
           not_found_error?: false
         ) do
      {:ok, %{provider_id: provider_id}} when provider_id == selection.provider_id ->
        {:ok, selection}

      {:ok, _changed} ->
        {:error, "Recovery Reviewer assignment changed"}

      {:error, error} = failure ->
        if AI.Error.context_failure?(error) or AI.Error.unwrap(error),
          do: failure,
          else: {:error, "Recovery Reviewer assignment is unavailable"}
    end
  end

  defp current_selection(_selection), do: {:error, "Recovery Reviewer assignment is invalid"}

  defp selection(turn) do
    key = Budget.key("recovery-review:assignment", turn.id)

    case Cases.case_event_by_idempotency(turn.case_id, key,
           authorize?: false,
           not_found_error?: false
         ) do
      {:ok, %CaseEvent{} = event} ->
        persisted_selection(turn, event)

      {:ok, nil} ->
        with {:ok, %AI.Selection{role: :reviewer, source: :assignment} = selection} <-
               Providers.select_reviewer_ai([], authorize?: false),
             {:ok, _event} <-
               Cases.create_case_event_record(
                 %{
                   case_id: turn.case_id,
                   resolution_run_id: turn.resolution_run_id,
                   event_type: "recovery_reviewer_assigned",
                   idempotency_key: key,
                   data: %{
                     "turn_id" => turn.id,
                     "provider_id" => selection.provider_id,
                     "provider_revision" => selection.provider_revision,
                     "assignment_id" => selection.assignment_id,
                     "assignment_revision" => selection.assignment_revision
                   }
                 },
                 authorize?: false
               ) do
          {:ok, selection}
        end

      error ->
        error
    end
  end

  defp persisted_selection(turn, event) do
    data = event.data

    if event.event_type == "recovery_reviewer_assigned" and
         event.resolution_run_id == turn.resolution_run_id and data["turn_id"] == turn.id and
         is_binary(data["provider_id"]) and is_integer(data["provider_revision"]) and
         is_binary(data["assignment_id"]) and is_integer(data["assignment_revision"]) do
      {:ok,
       %AI.Selection{
         role: :reviewer,
         source: :assignment,
         provider_id: data["provider_id"],
         provider_revision: data["provider_revision"],
         assignment_id: data["assignment_id"],
         assignment_revision: data["assignment_revision"]
       }}
    else
      {:error, "Recovery Reviewer assignment is invalid"}
    end
  end

  defp claim(turn, context, selection, request, attempt) do
    digest =
      AIInvocation.request_digest(
        {request, attempt, selection.provider_id, selection.assignment_id}
      )

    Cases.claim_ai_invocation(
      :reviewer,
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
      digest,
      attempt,
      %{invocation_context: context, request_size_bytes: AI.input_size(request)},
      authorize?: false
    )
  end

  defp dispatch(turn, selection, request, %AIInvocationClaim{state: :claimed} = claim, opts) do
    outcome =
      Skopos.Cases.Case.InvocationContext.with_invocation(
        claim.invocation_context,
        Keyword.get(opts, :ai_invocation, %{}),
        fn invocation ->
          Providers.ai_review_recovery(selection.provider_id, request, invocation,
            authorize?: false
          )
        end
      )

    case outcome do
      {:ok, %AI.ReviewDecision{} = decision} ->
        settle(turn, selection, request, claim.invocation, decision)

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
          settle_dispatch_failure(turn, claim, error, opts)
        end
    end
  end

  defp dispatch(
         turn,
         _selection,
         _request,
         %AIInvocationClaim{state: :interrupted} = claim,
         _opts
       ) do
    settle_interruption(turn, claim.invocation)
  end

  defp dispatch(turn, _selection, _request, %AIInvocationClaim{state: :terminal}, _opts) do
    with {:ok, event} <- result_event(turn) do
      if event,
        do: apply_result(turn, event),
        else: attention(turn, "Recovery Reviewer failed", "Invocation is terminal")
    end
  end

  defp settle_interruption(turn, invocation) do
    Ash.transact([Case, ResolutionRun, Turn, CaseEvent], fn ->
      with :ok <- CaseAdmissionLock.acquire(),
           {:ok, _charged} <- charge(turn, invocation.reserved_units, "unknown:#{invocation.id}"),
           :ok <- reconsider_recovery(turn, "Recovery Reviewer response was lost", "interrupted"),
           do: :ok
    end)
    |> case do
      {:ok, result} -> result
      {:error, _cause} = failure -> failure
    end
  end

  defp settle(turn, selection, request, invocation, decision) do
    usage = decision.usage
    amount = usage.input_tokens + usage.output_tokens

    data = %{
      "source_turn_id" => turn.id,
      "result_digest" => turn.result_digest,
      "evidence_ids" => request.conclusion.evidence_ids,
      "condition_claims" => request.conclusion.condition_claims,
      "desired_outcome_claims" => request.conclusion.desired_outcome_claims,
      "desired_outcome_assessment" => decision.desired_outcome_assessment,
      "review_fingerprint" => RecoveryReviewFingerprint.reviewed(request),
      "verdict" => to_string(decision.verdict),
      "reason" => decision.reason,
      "ai_invocation_id" => invocation.id,
      "invocation_key" => invocation.idempotency_key,
      "provider_id" => selection.provider_id,
      "assignment_id" => selection.assignment_id
    }

    result =
      Ash.transact([AIInvocation, Case, ResolutionRun, Turn, CaseEvent], fn ->
        with :ok <- CaseAdmissionLock.acquire(),
             {:ok, charged} <- charge(turn, amount, "result:#{invocation.id}"),
             {:ok, _recorded} <-
               Cases.record_ai_invocation_outcome(
                 invocation,
                 invocation.revision,
                 %{
                   status: :completed,
                   usage: usage,
                   result_digest: AIInvocation.request_digest(data),
                   completed_at: DateTime.utc_now()
                 },
                 authorize?: false
               ) do
          cond do
            match?(%BudgetResult{status: :exhausted}, charged) ->
              {:outcome, :budget_exhausted}

            true ->
              Cases.create_case_event_record(
                %{
                  case_id: turn.case_id,
                  resolution_run_id: turn.resolution_run_id,
                  event_type: "recovery_review_decided",
                  idempotency_key: result_key(turn),
                  data: data
                },
                authorize?: false
              )
          end
        end
      end)

    case result do
      {:ok, {:ok, event}} ->
        apply_result(turn, event)

      {:ok, {:outcome, :budget_exhausted}} ->
        :ok

      {:error, _error} = error ->
        error
    end
  end

  defp settle_dispatch_failure(turn, claim, error, opts) do
    if match?(%AI.Error{category: :cancelled}, AI.Error.unwrap(error)) do
      case Cases.invocation_context_current(claim.invocation_context, authorize?: false) do
        {:ok, false} -> settle_failure(turn, claim.invocation, error, opts, "context_changed")
        {:ok, true} -> settle_failure(turn, claim.invocation, error, opts)
        {:error, cause} -> {:error, Ash.Error.to_error_class([error, cause])}
      end
    else
      settle_failure(turn, claim.invocation, error, opts)
    end
  end

  defp settle_failure(turn, invocation, error, opts, changed_category \\ nil) do
    accounting = AIInvocation.failure_accounting(error, invocation.reserved_units)
    ai_error = accounting.ai_error
    usage = accounting.usage

    category =
      changed_category ||
        if(match?(%AI.Error{}, ai_error), do: to_string(ai_error.category), else: "failed")

    code = if match?(%AI.Error{}, ai_error), do: ai_error.failure_code

    with {:ok, _result} <-
           Ash.transact([AIInvocation, Case, ResolutionRun, CaseEvent, Turn], fn ->
             with :ok <- CaseAdmissionLock.acquire(),
                  {:ok, _charged} <- charge(turn, accounting.amount, "failure:#{invocation.id}"),
                  {:ok, recorded} <-
                    Cases.record_ai_invocation_outcome(
                      invocation,
                      invocation.revision,
                      %{
                        status: :failed,
                        usage: usage,
                        dispatched?: accounting.dispatched?,
                        category: category,
                        failure_code: code,
                        rejection_path: AIInvocation.rejection_path(ai_error),
                        completed_at: DateTime.utc_now()
                      },
                      authorize?: false
                    ) do
               if category == "context_changed" do
                 with :ok <-
                        reconsider_recovery(
                          turn,
                          "Recovery inputs changed during review",
                          "context_changed"
                        ),
                      do: recorded
               else
                 recorded
               end
             end
           end) do
      cond do
        AI.Error.context_failure?(error) ->
          {:error, error}

        category == "context_changed" ->
          :ok

        category == "invalid_output" and delivery_attempt(opts) < 2 and
            delivery_attempt(opts) < max_delivery_attempts(opts) ->
          {:error, "Recovery Reviewer output was invalid on attempt #{delivery_attempt(opts)}"}

        true ->
          attention(turn, "Recovery Reviewer failed", category)
      end
    else
      {:error, save_error} -> {:error, Ash.Error.to_error_class([error, save_error])}
    end
  end

  defp retry_context(turn) do
    case Cases.list_ai_invocations(
           query: [
             filter: [
               turn_id: turn.id,
               role: :reviewer,
               status: :failed,
               category: "invalid_output"
             ]
           ],
           authorize?: false
         ) do
      {:ok, []} ->
        {:ok, nil}

      {:ok, failures} ->
        {:ok, AIInvocation.retry_context(failures)}

      {:error, _error} = error ->
        error
    end
  end

  defp delivery_attempt(opts), do: max(Keyword.get(opts, :delivery_attempt, 1), 1)
  defp max_delivery_attempts(opts), do: max(Keyword.get(opts, :max_delivery_attempts, 1), 1)

  defp charge(_turn, 0, _key), do: {:ok, :no_usage}

  defp charge(turn, amount, key) do
    Cases.charge_resolution_run(
      turn.case_id,
      turn.resolution_run_id,
      :ai_usage,
      amount,
      Budget.key("recovery-review:usage", key),
      %{"action" => "review_ai_usage", "turn_id" => turn.id},
      "Review the Case and AI usage limit",
      authorize?: false
    )
  end

  defp apply_result(turn, event) do
    with {:ok, incident} <- Cases.get_case(turn.case_id, authorize?: false) do
      cond do
        incident.status == :resolved ->
          apply_current_result(turn, event)

        incident.status != :running ->
          :ok

        true ->
          with {:ok, current?} <-
                 Skopos.Cases.Case.ConditionContext.current?(incident, turn.id) do
            if current? do
              apply_current_result(turn, event)
            else
              case Cases.route_resolver_decision(turn.id, authorize?: false) do
                {:ok, _routed} -> :ok
                {:error, _error} = error -> error
              end
            end
          end
      end
    end
  end

  defp apply_current_result(turn, %CaseEvent{data: %{"verdict" => "approved"}}) do
    case Cases.route_downstream_decision(turn.id, authorize?: false) do
      {:ok, _resolved} ->
        :ok

      {:error, error} = failure ->
        cond do
          AI.Error.context_failure?(error) ->
            failure

          is_struct(error, Ash.Error.Invalid) or is_struct(error, Ash.Error.Forbidden) ->
            attention(turn, "Recovery Review could not be applied", error)

          true ->
            failure
        end
    end
  end

  defp apply_current_result(turn, %CaseEvent{data: %{"verdict" => "rejected", "reason" => reason}}) do
    with {:ok, incident} <- Cases.get_case(turn.case_id, authorize?: false),
         {:ok, selection} <- selection(turn),
         {:ok, _selection} <- current_selection(selection) do
      if incident.status == :running and
           incident.pending_intent == %{"action" => "review_recovery", "turn_id" => turn.id} do
        reconsider_recovery(turn, reason, "rejected")
      else
        :ok
      end
    else
      {:error, error} = failure ->
        if AI.Error.context_failure?(error),
          do: failure,
          else: attention(turn, "Recovery Review context changed", error)
    end
  end

  defp apply_current_result(turn, %CaseEvent{
         data: %{"verdict" => "needs_human", "reason" => reason}
       }),
       do: attention(turn, "Recovery requires operator input", reason)

  defp apply_current_result(turn, _event),
    do: attention(turn, "Recovery Review is invalid", "No valid Reviewer verdict")

  defp reconsider_recovery(turn, reason, origin) do
    with {:ok, current} <- Cases.get_case(turn.case_id, authorize?: false),
         true <-
           current.status == :running and not current.cancel_requested and
             current.pending_intent == %{"action" => "review_recovery", "turn_id" => turn.id},
         {:ok, result} <-
           Cases.start_turn(
             turn.case_id,
             turn.resolution_run_id,
             "recovery-review-#{origin}:#{turn.id}",
             %{
               "source" => "recovery_review_#{origin}",
               "source_turn_id" => turn.id,
               "review_reason" => reason,
               "objective" => "Reassess recovery using evidence relevant to each symptom"
             },
             %{"action" => "review_recovery", "turn_id" => turn.id},
             "Review the Case if the AI investigation limit is exhausted",
             authorize?: false
           ) do
      case result do
        %{status: status, value: next_turn} when status in [:charged, :duplicate] ->
          with {:ok, incident} <- Cases.get_case(turn.case_id, authorize?: false) do
            if incident.status == :running and
                 incident.pending_intent ==
                   %{"action" => "review_recovery", "turn_id" => turn.id} do
              case Cases.queue_case_resolver_turn(
                     incident,
                     incident.revision,
                     turn.id,
                     next_turn.id,
                     authorize?: false
                   ) do
                {:ok, _updated} -> :ok
                {:error, _error} = error -> error
              end
            else
              :ok
            end
          end

        %{status: :exhausted} ->
          :ok
      end
    else
      false -> :ok
      {:error, _cause} = failure -> failure
    end
  end

  defp attention(turn, reason, detail) do
    with {:ok, incident} <- Cases.get_case(turn.case_id, authorize?: false),
         {:ok, run} <- Cases.get_resolution_run(turn.resolution_run_id, authorize?: false) do
      if incident.status == :running and run.active and run.status == :running do
        pending = %{"action" => "review_recovery", "turn_id" => turn.id}

        case Cases.require_case_attention(
               incident.id,
               incident.revision,
               run.id,
               run.revision,
               Budget.key("recovery-review:attention", turn.id),
               reason,
               pending,
               String.slice(inspect(detail), 0, 1_000),
               authorize?: false
             ) do
          {:ok, _updated} -> :ok
          {:error, _error} = error -> error
        end
      else
        :ok
      end
    end
  end

  defp result_event(turn),
    do:
      Cases.case_event_by_idempotency(turn.case_id, result_key(turn),
        authorize?: false,
        not_found_error?: false
      )

  defp result_key(turn), do: Budget.key("recovery-review:result", turn.id)
end
