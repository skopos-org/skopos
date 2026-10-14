defmodule Skopos.Cases.Case.Changes.OperationHandoff do
  use Ash.Resource.Change

  alias Skopos.Cases

  @impl true
  def change(changeset, _opts, _context) do
    incident = changeset.data
    operation_id = Ash.Changeset.get_argument(changeset, :operation_id)

    with {:ok, operation} <- Cases.get_operation(operation_id, authorize?: false),
         true <-
           operation.case_id == incident.id and
             operation.status in [:applied, :failed, :partial, :unknown],
         :ok <- available_pending(incident.pending_intent, operation_id, arg(changeset, :kind)),
         {:ok, pending} <- pending(changeset, operation) do
      changeset
      |> Ash.Changeset.change_attribute(:pending_intent, pending)
      |> Ash.Changeset.change_attribute(:stop_reason, nil)
      |> Ash.Changeset.change_attribute(:required_human_input, nil)
    else
      _invalid ->
        Ash.Changeset.add_error(changeset,
          field: :operation_id,
          message: "Operation handoff is not current for this Case"
        )
    end
  end

  defp pending(changeset, operation) do
    cond do
      arg(changeset, :kind) == :verification and operation.purpose == :remediation ->
        {:ok,
         %{
           "action" => "verify_operation",
           "operation_id" => operation.id,
           "proposal_id" => operation.proposal_id
         }}

      arg(changeset, :kind) == :resolver ->
        result_pending(changeset, operation)

      true ->
        stale_pending(changeset, operation)
    end
  end

  defp result_pending(changeset, operation) do
    with {:ok, proposal} <- Cases.get_proposal(operation.proposal_id, authorize?: false),
         true <-
           (operation.status == :failed and is_nil(operation.dispatch_started_at)) or
             operation.purpose == :investigation or
             (proposal.verification_intent == %{} and proposal.verification_tool == %{}),
         {:ok, source} <- Cases.get_turn(arg(changeset, :source_turn_id), authorize?: false),
         true <- source.id == proposal.source_turn_id,
         {:ok, evidence} <- Cases.get_evidence(arg(changeset, :evidence_id), authorize?: false),
         true <-
           source.case_id == operation.case_id and
             source.resolution_run_id == operation.resolution_run_id,
         true <-
           evidence.case_id == operation.case_id and evidence.source == "operation" and
             evidence.source_ref == operation.id,
         :ok <- next_turn_current?(changeset, operation) do
      {:ok,
       %{
         "action" => "resolve_turn",
         "turn_id" => arg(changeset, :next_turn_id),
         "source_turn_id" => source.id,
         "operation_id" => operation.id,
         "evidence_id" => evidence.id
       }}
    else
      _invalid -> {:error, :invalid_result_handoff}
    end
  end

  defp stale_pending(changeset, operation) do
    if arg(changeset, :kind) == :stale_dispatch and
         operation.outcome_category in [
           "source_context_changed",
           "target_effect_changed",
           "authorization_invalidated"
         ] do
      with :ok <- next_turn_current?(changeset, operation) do
        {:ok,
         %{
           "action" => "resolve_turn",
           "turn_id" => arg(changeset, :next_turn_id),
           "source_operation_id" => operation.id
         }}
      end
    else
      {:error, :invalid_stale_handoff}
    end
  end

  defp next_turn_current?(changeset, operation) do
    with {:ok, next_turn} <- Cases.get_turn(arg(changeset, :next_turn_id), authorize?: false),
         true <-
           next_turn.case_id == operation.case_id and
             next_turn.resolution_run_id == operation.resolution_run_id do
      :ok
    else
      _invalid -> {:error, :invalid_next_turn}
    end
  end

  defp available_pending(
         %{"operation_id" => operation_id, "action" => action},
         operation_id,
         :verification
       )
       when action in ["verify_operation", "dispatch_operation"],
       do: :ok

  defp available_pending(
         %{"operation_id" => operation_id, "action" => action},
         operation_id,
         :resolver
       )
       when action in ["dispatch_operation", "resolve_turn"],
       do: :ok

  defp available_pending(
         %{"operation_id" => operation_id, "action" => "dispatch_operation"},
         operation_id,
         :stale_dispatch
       ),
       do: :ok

  defp available_pending(pending, _operation_id, _kind) when map_size(pending) == 0, do: :ok
  defp available_pending(_pending, _operation_id, _kind), do: {:error, :pending_conflict}

  defp arg(changeset, key), do: Ash.Changeset.get_argument(changeset, key)
end
