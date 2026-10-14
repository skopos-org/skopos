defmodule Skopos.Cases.Case.Changes.VerificationHandoff do
  use Ash.Resource.Change

  alias Skopos.Cases

  @impl true
  def change(changeset, _opts, _context) do
    incident = changeset.data
    attempt_id = arg(changeset, :verification_attempt_id)
    evidence_id = arg(changeset, :verification_evidence_id)

    with {:ok, attempt} <- Cases.get_verification_attempt(attempt_id, authorize?: false),
         {:ok, evidence} <- Cases.get_evidence(evidence_id, authorize?: false),
         true <-
           attempt.case_id == incident.id and
             attempt.status in [:verified, :not_verified, :unknown],
         true <-
           evidence.case_id == incident.id and
             evidence.resolution_run_id == attempt.resolution_run_id and
             evidence.kind == "target_verification" and
             evidence.source == "verification" and evidence.source_ref == attempt.id,
         {:ok, pending} <- pending(changeset, incident.pending_intent, attempt, evidence) do
      changeset
      |> Ash.Changeset.change_attribute(:pending_intent, pending)
      |> Ash.Changeset.change_attribute(:stop_reason, nil)
      |> Ash.Changeset.change_attribute(:required_human_input, nil)
    else
      _invalid ->
        Ash.Changeset.add_error(changeset,
          field: :verification_attempt_id,
          message: "Verification handoff is not current for this Case"
        )
    end
  end

  defp pending(changeset, current, attempt, evidence) do
    case arg(changeset, :kind) do
      :evaluate -> evaluation_pending(current, attempt, evidence)
      :resolve_turn -> turn_pending(changeset, current, attempt, evidence)
    end
  end

  defp evaluation_pending(
         %{"action" => "verify_operation", "operation_id" => id},
         attempt,
         evidence
       )
       when id == attempt.operation_id do
    {:ok,
     %{
       "action" => "evaluate_verification",
       "verification_attempt_id" => attempt.id,
       "verification_evidence_id" => evidence.id,
       "operation_id" => attempt.operation_id
     }}
  end

  defp evaluation_pending(
         %{
           "action" => "evaluate_verification",
           "verification_attempt_id" => id,
           "verification_evidence_id" => evidence_id
         },
         attempt,
         evidence
       )
       when id == attempt.id and evidence_id == evidence.id do
    evaluation_pending(
      %{"action" => "verify_operation", "operation_id" => attempt.operation_id},
      attempt,
      evidence
    )
  end

  defp evaluation_pending(_current, _attempt, _evidence), do: {:error, :pending_conflict}

  defp turn_pending(changeset, current, attempt, evidence) do
    with true <- ready_to_resolve?(current, attempt, evidence, arg(changeset, :next_turn_id)),
         {:ok, turn} <- Cases.get_turn(arg(changeset, :next_turn_id), authorize?: false),
         true <-
           turn.case_id == attempt.case_id and
             turn.resolution_run_id == attempt.resolution_run_id and
             turn.intent["verification_attempt_id"] == attempt.id and
             turn.intent["verification_evidence_id"] == evidence.id do
      {:ok,
       %{
         "action" => "resolve_turn",
         "turn_id" => turn.id,
         "operation_id" => attempt.operation_id,
         "verification_attempt_id" => attempt.id,
         "verification_evidence_id" => evidence.id
       }}
    else
      _invalid -> {:error, :invalid_turn_handoff}
    end
  end

  defp ready_to_resolve?(
         %{
           "action" => "evaluate_verification",
           "verification_attempt_id" => id,
           "verification_evidence_id" => evidence_id
         },
         attempt,
         evidence,
         _next_turn_id
       ),
       do: id == attempt.id and evidence_id == evidence.id

  defp ready_to_resolve?(
         %{
           "action" => "resolve_turn",
           "turn_id" => current_turn_id,
           "verification_attempt_id" => id,
           "verification_evidence_id" => evidence_id
         },
         attempt,
         evidence,
         next_turn_id
       ),
       do: id == attempt.id and evidence_id == evidence.id and current_turn_id == next_turn_id

  defp ready_to_resolve?(_current, _attempt, _evidence, _next_turn_id), do: false

  defp arg(changeset, key), do: Ash.Changeset.get_argument(changeset, key)
end
