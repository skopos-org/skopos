defmodule Skopos.Cases.VerificationAttempt.Actions.ClaimDispatch do
  use Ash.Resource.Actions.Implementation
  require Ash.Query

  alias Skopos.{Accounts, Cases, Targets}
  alias Skopos.Targets.TargetRequest.{Request, RequestError}
  alias Skopos.Cases.{Case, ResolutionRun, VerificationAttempt}
  alias Skopos.Cases.VerificationAttempt.Claim, as: VerificationClaim
  alias Skopos.Cases.Case.{AdmissionLock, ConditionContext, InvocationContext}

  @terminal [:verified, :not_verified, :unknown]

  @impl true
  def run(input, _opts, _context) do
    with {:ok, source} <- Cases.get_verification_attempt(input.arguments.id, authorize?: false) do
      Ash.transact([Case, ResolutionRun, VerificationAttempt], fn ->
        with :ok <- AdmissionLock.acquire(),
             {:ok, incident} <- lock(Case, source.case_id),
             {:ok, run} <- lock(ResolutionRun, source.resolution_run_id),
             {:ok, attempt} <- lock(VerificationAttempt, source.id) do
          claim(attempt, incident, run)
        end
      end)
    end
  end

  defp claim(%{status: :queued} = attempt, incident, run) do
    if incident.status == :running and not incident.cancel_requested and run.active and
         run.status == :running and run.generation == attempt.case_generation do
      claim_authorized(attempt, incident, run)
    else
      terminal_no_send(attempt, "cancelled_before_verification", %{
        "message" => "Case stopped before fresh verification was dispatched"
      })
    end
  end

  defp claim(%{status: :dispatching} = attempt, _incident, _run) do
    now = DateTime.utc_now()

    with {:ok, terminal} <-
           Cases.record_verification_outcome(
             attempt,
             attempt.revision,
             %{
               status: :unknown,
               outcome_category: "verification_interrupted",
               facts: %{},
               provider_evidence: %{
                 "message" => "Verification ownership was lost after the dispatch marker"
               },
               observed_at: now,
               completed_at: now
             },
             authorize?: false
           ) do
      %VerificationClaim{state: :terminal, attempt: terminal}
    end
  end

  defp claim(%{status: status} = attempt, _incident, _run) when status in @terminal,
    do: %VerificationClaim{state: :terminal, attempt: attempt}

  defp claim_authorized(attempt, incident, run) do
    with {:ok, actor} <- current_actor(attempt),
         {:ok, clearance} <- Targets.clear_target_request(request(attempt), actor: actor),
         :ok <- exact_clearance(clearance, attempt),
         {:ok, conditions} <- ConditionContext.current_conditions(incident) do
      with {:ok, claimed} <-
             Cases.mark_verification_dispatching(
               attempt,
               attempt.revision,
               %{dispatch_started_at: DateTime.utc_now()},
               authorize?: false
             ) do
        context =
          InvocationContext.project(
            incident,
            run,
            {:verification, claimed.id, claimed.revision, claimed.status},
            conditions,
            nil,
            [clearance]
          )

        %VerificationClaim{
          state: :claimed,
          attempt: claimed,
          actor: actor,
          clearance: clearance,
          invocation_context: context
        }
      end
    else
      {:error, error} = failure ->
        if RequestError.expected?(error) do
          terminal_no_send(attempt, "authorization_invalidated", %{
            "items" => [
              %{"message" => "Verification authorization changed before Target dispatch"}
            ]
          })
        else
          failure
        end
    end
  end

  defp terminal_no_send(attempt, category, evidence) do
    now = DateTime.utc_now()

    with {:ok, terminal} <-
           Cases.record_verification_no_send(
             attempt,
             attempt.revision,
             %{
               outcome_category: category,
               facts: %{},
               provider_evidence: evidence,
               observed_at: now,
               completed_at: now
             },
             authorize?: false
           ) do
      %VerificationClaim{state: :terminal, attempt: terminal}
    end
  end

  defp current_actor(attempt) do
    case Accounts.get_user(attempt.actor_id, authorize?: false) do
      {:ok, %{role: role, role_version: version} = actor}
      when role in [:admin, :operator] and version == attempt.actor_role_version ->
        {:ok, actor}

      {:ok, _changed} ->
        {:error,
         RequestError.exception(
           category: :forbidden,
           message: "Verification actor authority changed"
         )}

      {:error, _error} = error ->
        error
    end
  end

  defp request(attempt) do
    %Request{
      kind: :verification,
      authority_mode: attempt.authority_mode,
      target_id: attempt.target_id,
      target_revision: attempt.target_revision,
      access_method_id: attempt.access_method_id,
      access_method_revision: attempt.access_method_revision,
      capability: attempt.capability,
      operation: attempt.operation,
      selectors: attempt.selectors,
      parameters: attempt.parameters,
      operation_id: attempt.operation_id,
      reference: attempt.operation_reference,
      expected: attempt.expected,
      max_attempts: 1
    }
  end

  defp exact_clearance(clearance, attempt) do
    if clearance.provider_id == attempt.provider_id and
         clearance.provider_revision == attempt.provider_revision and
         Base.encode16(clearance.digest, case: :lower) == attempt.authorization_digest,
       do: :ok,
       else:
         {:error,
          RequestError.exception(
            category: :clearance_mismatch,
            message: "Verification clearance changed"
          )}
  end

  defp lock(resource, id) do
    resource
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(id: id)
    |> Ash.Query.lock(:for_update)
    |> Ash.read_one(authorize?: false)
    |> case do
      {:ok, nil} -> {:error, "Verification dispatch input is unavailable"}
      result -> result
    end
  end
end
