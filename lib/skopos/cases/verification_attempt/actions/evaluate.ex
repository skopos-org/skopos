defmodule Skopos.Cases.VerificationAttempt.Actions.Evaluate do
  use Ash.Resource.Actions.Implementation

  alias Skopos.Cases
  alias Skopos.Cases.{Case, CaseEvent, ResolutionRun, Turn}
  alias Skopos.Cases.ResolutionRun.BudgetResult

  @terminal [:verified, :not_verified, :unknown]

  @impl true
  def run(input, _opts, _context) do
    with {:ok, attempt} <- Cases.get_verification_attempt(input.arguments.id, authorize?: false),
         true <- attempt.status in @terminal || {:error, "Verification is not complete"},
         {:ok, evidence} <- verification_evidence(attempt),
         {:ok, incident} <- Cases.get_case(attempt.case_id, authorize?: false),
         {:ok, run} <- Cases.get_resolution_run(attempt.resolution_run_id, authorize?: false),
         :ok <- valid_context(attempt, evidence, incident, run) do
      Ash.transact([Case, ResolutionRun, Turn, CaseEvent], fn ->
        with {:ok, %BudgetResult{} = result} <- start_turn(attempt, evidence, incident) do
          case result do
            %{status: status, value: turn} when status in [:charged, :duplicate] ->
              with {:ok, _case} <- set_pending(attempt, evidence, turn), do: turn

            %{status: :exhausted} ->
              {:error, "Resolver turn budget exhausted after verification"}
          end
        end
      end)
    end
  end

  defp verification_evidence(attempt) do
    Cases.evidence_by_idempotency(
      attempt.case_id,
      "verification:outcome:#{attempt.id}",
      authorize?: false
    )
  end

  defp valid_context(attempt, evidence, incident, run) do
    pending = incident.pending_intent

    valid_pending =
      match?(
        %{
          "action" => "evaluate_verification",
          "verification_attempt_id" => id,
          "verification_evidence_id" => evidence_id
        }
        when id == attempt.id and evidence_id == evidence.id,
        pending
      ) or
        match?(
          %{"action" => "resolve_turn", "verification_attempt_id" => id}
          when id == attempt.id,
          pending
        )

    if incident.status == :running and not incident.cancel_requested and run.active and
         run.status == :running and run.generation == attempt.case_generation and valid_pending,
       do: :ok,
       else: {:error, "Case is not ready for post-verification evaluation"}
  end

  defp start_turn(attempt, evidence, incident) do
    Cases.start_turn(
      incident.id,
      attempt.resolution_run_id,
      "verification-assessment:#{attempt.id}",
      %{
        "objective" => "Assess recovery from fresh Target verification",
        "operation_id" => attempt.operation_id,
        "verification_attempt_id" => attempt.id,
        "verification_evidence_id" => evidence.id,
        "verification_status" => to_string(attempt.status),
        "source_recovery_required" => incident.trigger_kind == :signal
      },
      %{
        "action" => "review_post_verification_limit",
        "verification_attempt_id" => attempt.id
      },
      "Increase the Resolver turn limit or assess recovery manually",
      authorize?: false
    )
  end

  defp set_pending(attempt, evidence, turn) do
    with {:ok, incident} <- Cases.get_case(attempt.case_id, authorize?: false),
         {:ok, updated} <-
           Cases.handoff_case_verification(
             incident,
             incident.revision,
             attempt.id,
             evidence.id,
             :resolve_turn,
             turn.id,
             authorize?: false
           ) do
      {:ok, updated}
    end
  end
end
