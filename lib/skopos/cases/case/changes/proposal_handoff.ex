defmodule Skopos.Cases.Case.Changes.ProposalHandoff do
  use Ash.Resource.Change

  alias Skopos.Cases

  @impl true
  def change(changeset, _opts, _context) do
    incident = changeset.data
    proposal_id = arg(changeset, :proposal_id)

    with {:ok, proposal} <- Cases.get_proposal(proposal_id, authorize?: false),
         true <- proposal.case_id == incident.id,
         {:ok, run} <- Cases.get_resolution_run(proposal.resolution_run_id, authorize?: false),
         true <-
           run.case_id == incident.id and run.active and run.status == :running and
             run.generation == proposal.case_generation,
         true <- available?(incident.pending_intent, proposal, arg(changeset, :kind)),
         {:ok, pending} <- pending(changeset, proposal) do
      changeset
      |> Ash.Changeset.change_attribute(:pending_intent, pending)
      |> Ash.Changeset.change_attribute(:stop_reason, nil)
      |> Ash.Changeset.change_attribute(:required_human_input, nil)
    else
      _invalid ->
        Ash.Changeset.add_error(changeset,
          field: :proposal_id,
          message: "Proposal handoff is not current for this Case"
        )
    end
  end

  defp available?(%{"proposal_id" => id}, %{id: id}, _kind), do: true
  defp available?(_current, _proposal, :clear), do: false
  defp available?(current, _proposal, _kind) when map_size(current) == 0, do: true
  defp available?(_current, _proposal, _kind), do: false

  defp pending(changeset, proposal) do
    reference_id = arg(changeset, :reference_id)

    case {arg(changeset, :kind), proposal.status} do
      {:review, :reviewing} when is_nil(reference_id) ->
        {:ok,
         %{
           "action" => "review_proposal",
           "proposal_id" => proposal.id,
           "proposal_digest" => proposal.proposal_digest
         }}

      {:human, :awaiting_human} ->
        human_pending(proposal, reference_id)

      {:dispatch, :authorized} when is_binary(reference_id) ->
        dispatch_pending(proposal, reference_id)

      {:continue, status}
      when status in [:blocked, :rejected, :invalidated] and
             is_binary(reference_id) ->
        continue_pending(proposal, reference_id)

      {:clear, :invalidated} when is_nil(reference_id) ->
        {:ok, %{}}

      _invalid ->
        {:error, :invalid_proposal_transition}
    end
  end

  defp human_pending(proposal, nil) do
    {:ok,
     %{
       "action" => "decide_proposal",
       "proposal_id" => proposal.id,
       "proposal_digest" => proposal.proposal_digest
     }}
  end

  defp human_pending(proposal, decision_id) do
    with {:ok, decision} <- Cases.review_decision_by_proposal(proposal.id, authorize?: false),
         true <- decision.id == decision_id and decision.verdict == :needs_human do
      {:ok,
       %{
         "action" => "decide_proposal",
         "proposal_id" => proposal.id,
         "proposal_digest" => proposal.proposal_digest,
         "review_decision_id" => decision.id,
         "review_reason" => decision.reason
       }}
    else
      _invalid -> {:error, :invalid_review_decision}
    end
  end

  defp dispatch_pending(proposal, approval_id) do
    with {:ok, approval} <- Cases.approval_by_proposal(proposal.id, authorize?: false),
         true <- approval.id == approval_id and approval.decision == :approved do
      {:ok,
       %{
         "action" => "dispatch_operation",
         "proposal_id" => proposal.id,
         "approval_id" => approval.id,
         "operation_id" => proposal.reserved_operation_id
       }}
    else
      _invalid -> {:error, :invalid_approval}
    end
  end

  defp continue_pending(proposal, turn_id) do
    with {:ok, turn} <- Cases.get_turn(turn_id, authorize?: false),
         true <-
           turn.case_id == proposal.case_id and
             turn.resolution_run_id == proposal.resolution_run_id,
         {field, pending} <- continuation(proposal, turn),
         true <- turn.intent[field] == proposal.id do
      {:ok, pending}
    else
      _invalid -> {:error, :invalid_continuation}
    end
  end

  defp continuation(%{status: :blocked} = proposal, turn) do
    {"blocked_proposal_id",
     %{
       "action" => "resolve_turn",
       "turn_id" => turn.id,
       "proposal_id" => proposal.id,
       "blocked_proposal_id" => proposal.id
     }}
  end

  defp continuation(%{status: :rejected} = proposal, turn) do
    {"rejected_proposal_id",
     %{
       "action" => "resolve_turn",
       "turn_id" => turn.id,
       "proposal_id" => proposal.id,
       "rejected_proposal_id" => proposal.id
     }}
  end

  defp continuation(%{status: :invalidated} = proposal, turn) do
    {"source_proposal_id",
     %{"action" => "resolve_turn", "turn_id" => turn.id, "source_proposal_id" => proposal.id}}
  end

  defp arg(changeset, key), do: Ash.Changeset.get_argument(changeset, key)
end
