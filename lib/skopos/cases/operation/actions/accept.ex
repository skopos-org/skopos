defmodule Skopos.Cases.Operation.Actions.Accept do
  use Ash.Resource.Actions.Implementation
  require Ash.Query

  alias Skopos.{Accounts, Cases, Targets}
  alias Skopos.Cases.{Operation, Proposal}
  alias Skopos.Cases.ResolutionRun.Budget, as: Budget
  alias Skopos.Cases.Case.ConditionContext, as: ConditionContext
  alias Skopos.Targets.TargetRequest.{Clearance, RequestError}

  @impl true
  def run(input, _opts, _context) do
    with {:ok, proposal} <- Cases.get_proposal(input.arguments.proposal_id, authorize?: false),
         {:ok, existing} <- existing(proposal.id) do
      if existing, do: {:ok, existing}, else: consume(proposal)
    end
  end

  defp consume(proposal) do
    case Budget.consume(
           case_id: proposal.case_id,
           admission_lock?: true,
           resolution_run_id: proposal.resolution_run_id,
           kind: budget_kind(proposal.request_kind),
           amount: 1,
           ledger_key: Budget.key("proposal:#{proposal.request_kind}", proposal.id),
           actor: nil,
           event_type: "#{proposal.request_kind}_budget_charged",
           event_data: %{"proposal_id" => proposal.id},
           pending_intent: %{
             "action" => "review_#{proposal.request_kind}_limit",
             "proposal_id" => proposal.id
           },
           required_human_input:
             "Increase the Target request limit or handle the Proposal manually",
           operation: fn incident, run -> accept_locked(proposal.id, incident, run) end,
           duplicate: fn _incident, _run -> required_existing(proposal.id) end
         ) do
      {:ok, %{status: status, value: %Operation{} = operation}}
      when status in [:charged, :duplicate] ->
        {:ok, operation}

      {:ok, %{status: :exhausted}} ->
        invalid_input("Target request budget exhausted")

      {:error, error} ->
        if RequestError.expected?(error) and condition_context_changed?(error) do
          with {:ok, _invalidated} <-
                 Cases.supersede_proposal_context(proposal.id, authorize?: false) do
            invalid_input("Proposal Conditions changed before Operation acceptance")
          end
        else
          {:error, error}
        end

      other ->
        other
    end
  end

  defp accept_locked(proposal_id, incident, run) do
    with {:ok, proposal} <- lock(Proposal, proposal_id),
         :ok <- valid_context(proposal, incident, run),
         {:ok, approval} <- Cases.approval_by_proposal(proposal.id, authorize?: false),
         :ok <- valid_approval(approval, proposal),
         {:ok, actor} <- current_actor(approval),
         {:ok, %Clearance{} = clearance} <-
           Targets.clear_target_request(Proposal.target_request(proposal), actor: actor),
         :ok <- exact_provider(clearance, proposal),
         {:ok, operation} <- create(proposal, approval, actor, clearance),
         {:ok, job} <- enqueue(operation),
         true <-
           is_integer(job.id) ||
             {:error,
              Ash.Error.Unknown.UnknownError.exception(
                error: "Operation dispatch job was not persisted"
              )} do
      {:ok, operation}
    end
  end

  defp valid_context(proposal, incident, run) do
    with true <-
           (proposal.status == :authorized and incident.status == :running and
              not incident.cancel_requested and run.active and run.status == :running and
              run.generation == proposal.case_generation and
              proposal.authority_mode == incident.authority_mode and
              proposal.authority_mode == run.authority_mode and
              DateTime.compare(DateTime.utc_now(), proposal.expires_at) == :lt and
              DateTime.compare(not_before(proposal), proposal.expires_at) == :lt and
              DateTime.compare(not_before(proposal), run.deadline_at) == :lt) ||
             invalid_input("Authorized Proposal is stale"),
         {:ok, true} <- ConditionContext.current?(incident, proposal.source_turn_id),
         {:ok, true} <-
           ConditionContext.affected_current?(
             incident,
             proposal.request_kind,
             proposal.affected_conditions,
             proposal.evidence_ids,
             proposal
           ) do
      :ok
    else
      {:ok, false} ->
        {:error,
         Ash.Error.Changes.StaleRecord.exception(
           resource: Proposal,
           field: :condition_revisions
         )}

      other ->
        other
    end
  end

  defp condition_context_changed?(%Ash.Error.Changes.StaleRecord{field: :condition_revisions}),
    do: true

  defp condition_context_changed?(%{errors: errors}) when is_list(errors),
    do: Enum.any?(errors, &condition_context_changed?/1)

  defp condition_context_changed?(_error), do: false

  defp valid_approval(approval, proposal) do
    if approval.decision == :approved and approval.proposal_digest == proposal.proposal_digest and
         approval.proposal_revision + 1 == proposal.revision and
         approval.case_generation == proposal.case_generation,
       do: :ok,
       else: invalid_input("Approval does not authorize the current Proposal")
  end

  defp current_actor(approval) do
    case Accounts.get_user(approval.actor_id, authorize?: false) do
      {:ok, %{role: role, role_version: version} = actor}
      when role in [:admin, :operator] and version == approval.actor_role_version ->
        {:ok, actor}

      {:ok, _changed} ->
        invalid_input("Approval actor authority changed")

      {:error, _error} = error ->
        error
    end
  end

  defp exact_provider(clearance, proposal) do
    if clearance.provider_id == proposal.provider_id and
         clearance.provider_revision == proposal.provider_revision,
       do: :ok,
       else: invalid_input("Target Provider changed after approval")
  end

  defp invalid_input(message) do
    {:error, Ash.Error.Action.InvalidArgument.exception(field: :proposal_id, message: message)}
  end

  defp create(proposal, approval, actor, clearance) do
    Cases.create_operation_record(
      %{
        id: proposal.reserved_operation_id,
        case_id: proposal.case_id,
        resolution_run_id: proposal.resolution_run_id,
        proposal_id: proposal.id,
        approval_id: approval.id,
        actor_id: actor.id,
        target_id: proposal.target_id,
        access_method_id: proposal.access_method_id,
        provider_id: proposal.provider_id,
        case_generation: proposal.case_generation,
        authority_mode: proposal.authority_mode,
        proposal_revision: proposal.revision,
        approval_proposal_revision: approval.proposal_revision,
        actor_role_version: actor.role_version,
        target_revision: proposal.target_revision,
        access_method_revision: proposal.access_method_revision,
        provider_revision: proposal.provider_revision,
        request_kind: proposal.request_kind,
        purpose: proposal.purpose,
        capability: proposal.capability,
        operation: proposal.operation,
        selectors: proposal.selectors,
        parameters: proposal.parameters,
        idempotency_key: proposal.operation_idempotency_key,
        authorization_digest: Base.encode16(clearance.digest, case: :lower),
        accepted_at: DateTime.utc_now(),
        not_before: not_before(proposal)
      },
      authorize?: false
    )
  end

  defp not_before(proposal),
    do: DateTime.add(proposal.inserted_at, proposal.delay_seconds, :second)

  defp enqueue(operation) do
    %{"operation_id" => operation.id}
    |> Skopos.Cases.Operation.Worker.new(scheduled_at: operation.not_before)
    |> Oban.insert()
  end

  defp required_existing(proposal_id) do
    case existing(proposal_id) do
      {:ok, %Operation{} = operation} ->
        {:ok, operation}

      {:ok, nil} ->
        {:error,
         Ash.Error.Unknown.UnknownError.exception(
           error: "Effect budget ledger exists without its Operation"
         )}

      {:error, _error} = error ->
        error
    end
  end

  defp existing(proposal_id) do
    Cases.operation_by_proposal(proposal_id,
      authorize?: false,
      not_found_error?: false
    )
  end

  defp budget_kind(:observation), do: :target_request
  defp budget_kind(:effect), do: :effect

  defp lock(resource, id) do
    resource
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(id: id)
    |> Ash.Query.lock(:for_update)
    |> Ash.read_one(authorize?: false)
    |> case do
      {:ok, nil} -> invalid_input("Operation input is unavailable")
      result -> result
    end
  end
end
