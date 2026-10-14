defmodule Skopos.Cases.VerificationAttempt.Delivery do
  @moduledoc false

  alias Skopos.{Cases, Targets}
  alias Skopos.Cases.VerificationAttempt
  alias Skopos.Cases.VerificationAttempt.Claim, as: VerificationClaim
  alias Skopos.Providers.Target, as: ProviderTarget

  @terminal [:verified, :not_verified, :unknown]

  def run(attempt_id, opts \\ []) do
    case Cases.claim_verification_dispatch(attempt_id, authorize?: false) do
      {:ok, %VerificationClaim{state: :claimed} = claim} ->
        dispatch(claim, opts)

      {:ok, %VerificationClaim{state: :terminal, attempt: attempt}} ->
        handoff(attempt)

      {:error, error} ->
        {:error, error}
    end
  end

  defp dispatch(
         %VerificationClaim{
           attempt: attempt,
           actor: actor,
           clearance: clearance,
           invocation_context: context
         },
         opts
       ) do
    invocation =
      Map.put(
        Keyword.get(opts, :target_invocation, %{}),
        :result_reference_reader,
        fn reference ->
          Cases.read_operation_result_reference(reference, attempt.case_id, clearance,
            actor: actor
          )
        end
      )

    result =
      Skopos.Cases.Case.InvocationContext.with_invocation(context, invocation, fn supplied ->
        Targets.dispatch_target_verification(clearance, supplied, actor: actor, authorize?: false)
      end)

    outcome =
      case result do
        {:ok, %ProviderTarget.Verification{} = result} ->
          normalize(result)

        {:error, error} ->
          case ProviderTarget.BeforeSendError.unwrap(error) do
            nil ->
              outcome = unknown("verification_error", "Fresh verification result is unknown")

              if ProviderTarget.Error.context_failure?(error) do
                outcome =
                  case ProviderTarget.Error.context_progress(error) do
                    nil -> outcome
                    progress -> %{outcome | facts: Map.put(outcome.facts, "progress", progress)}
                  end

                Map.put(outcome, :context_failure, error)
              else
                outcome
              end

            unsent ->
              {:error, unsent}
          end
      end

    case outcome do
      {:error, %ProviderTarget.BeforeSendError{} = error} -> unsent(attempt, error)
      outcome -> persist_and_handoff(attempt, outcome)
    end
  end

  defp unsent(attempt, error) do
    if ProviderTarget.BeforeSendError.retryable?(error) do
      case Cases.retry_unsent_verification(attempt, attempt.revision, error, authorize?: false) do
        {:ok, _queued} -> {:error, error.cause}
        {:error, save_error} -> {:error, Ash.Error.to_error_class([error.cause, save_error])}
      end
    else
      now = DateTime.utc_now()

      case Cases.record_verification_no_send(
             attempt,
             attempt.revision,
             %{
               before_send_failure: error,
               outcome_category: "input_unavailable",
               facts: %{},
               provider_evidence: %{
                 "items" => [%{"message" => "Verification input is unavailable"}]
               },
               observed_at: now,
               completed_at: now
             },
             authorize?: false
           ) do
        {:ok, terminal} -> handoff(terminal)
        {:error, save_error} -> {:error, Ash.Error.to_error_class([error.cause, save_error])}
      end
    end
  end

  defp persist_and_handoff(attempt, %{context_failure: cause} = outcome) do
    case persist_and_handoff(attempt, Map.delete(outcome, :context_failure)) do
      :ok -> {:error, cause}
      {:error, error} -> {:error, Ash.Error.to_error_class([cause, error])}
      other -> other
    end
  end

  defp persist_and_handoff(attempt, outcome) do
    with {:ok, terminal} <-
           Cases.record_verification_outcome(
             attempt,
             attempt.revision,
             %{
               status: outcome.status,
               outcome_category: outcome.category,
               facts: outcome.facts,
               provider_evidence: %{"items" => outcome.evidence},
               observed_at: outcome.observed_at,
               completed_at: DateTime.utc_now()
             },
             authorize?: false
           ) do
      handoff(terminal)
    end
  end

  defp normalize(%ProviderTarget.Verification{} = result) do
    %{
      status: result.status,
      category: "target_#{result.status}",
      facts: result.facts,
      evidence: result.evidence,
      observed_at: result.observed_at
    }
  end

  defp unknown(category, message) do
    %{
      status: :unknown,
      category: category,
      facts: %{},
      evidence: [%{"message" => message}],
      observed_at: DateTime.utc_now()
    }
  end

  defp handoff(%VerificationAttempt{status: status} = attempt) when status in @terminal do
    case Cases.get_case(attempt.case_id, authorize?: false) do
      {:ok, %{status: :running, cancel_requested: false}} -> handoff_running(attempt)
      {:ok, _stopped} -> :ok
      {:error, error} -> {:error, error}
    end
  end

  defp handoff(_attempt), do: {:error, "VerificationAttempt has no terminal outcome"}

  defp handoff_running(attempt) do
    with {:ok, evidence} <-
           Cases.append_evidence(
             attempt.case_id,
             attempt.resolution_run_id,
             nil,
             "verification:outcome:#{attempt.id}",
             "target_verification",
             "verification",
             attempt.id,
             %{"target_id" => attempt.target_id},
             attempt.observed_at,
             authorize?: false
           ),
         {:ok, incident} <- Cases.get_case(attempt.case_id, authorize?: false) do
      continue_handoff(attempt, evidence, incident)
    end
  end

  defp continue_handoff(attempt, evidence, incident) do
    result =
      case incident.pending_intent do
        %{
          "action" => action,
          "verification_attempt_id" => id,
          "verification_evidence_id" => evidence_id
        }
        when action in ["evaluate_verification", "await_source_recovery"] and
               id == attempt.id and evidence_id == evidence.id ->
          :ok

        _other ->
          case Cases.handoff_case_verification(
                 incident,
                 incident.revision,
                 attempt.id,
                 evidence.id,
                 :evaluate,
                 nil,
                 authorize?: false
               ) do
            {:ok, _case} -> :ok
            {:error, _error} = error -> error
          end
      end

    case result do
      :ok ->
        case Cases.continue_case_after_verification(attempt.case_id, attempt.id,
               authorize?: false
             ) do
          {:ok, true} -> :ok
          {:error, _reason} = error -> error
        end

      {:error, _error} = conflict ->
        case Cases.turn_by_idempotency(
               attempt.resolution_run_id,
               "verification-assessment:#{attempt.id}",
               authorize?: false,
               not_found_error?: false
             ) do
          {:ok, %Skopos.Cases.Turn{}} -> :ok
          _missing -> conflict
        end
    end
  end
end
