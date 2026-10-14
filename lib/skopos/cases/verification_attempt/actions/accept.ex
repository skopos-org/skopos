defmodule Skopos.Cases.VerificationAttempt.Actions.Accept do
  use Ash.Resource.Actions.Implementation
  require Ash.Query

  alias Skopos.{Accounts, Cases, Targets}
  alias Skopos.Cases.{Operation, Proposal, VerificationAttempt}
  alias Skopos.Cases.ResolutionRun.Budget, as: Budget
  alias Skopos.Targets.TargetRequest.{Request, Clearance}

  @verifiable [:applied, :failed, :partial, :unknown]

  @impl true
  def run(input, _opts, _context) do
    with {:ok, operation} <- Cases.get_operation(input.arguments.operation_id, authorize?: false),
         {:ok, existing} <- existing(operation.id) do
      if existing, do: {:ok, existing}, else: consume(operation)
    end
  end

  defp consume(operation) do
    case Budget.consume(
           case_id: operation.case_id,
           resolution_run_id: operation.resolution_run_id,
           kind: :target_request,
           amount: 1,
           ledger_key: Budget.key("operation:verification", operation.id),
           actor: nil,
           event_type: "verification_budget_charged",
           event_data: %{"operation_id" => operation.id},
           pending_intent: %{
             "action" => "review_verification_limit",
             "operation_id" => operation.id
           },
           required_human_input:
             "Increase the Target request limit or verify the Operation manually",
           operation: fn incident, run -> accept_locked(operation.id, incident, run) end,
           duplicate: fn _incident, _run -> required_existing(operation.id) end
         ) do
      {:ok, %{status: status, value: %VerificationAttempt{} = attempt}}
      when status in [:charged, :duplicate] ->
        {:ok, attempt}

      {:ok, %{status: :exhausted}} ->
        {:error, "Target verification budget exhausted"}

      other ->
        other
    end
  end

  defp accept_locked(operation_id, incident, run) do
    with {:ok, operation} <- lock(Operation, operation_id),
         :ok <- valid_context(operation, incident, run),
         {:ok, _evidence} <- operation_evidence(operation),
         {:ok, proposal} <- lock(Proposal, operation.proposal_id),
         :ok <- valid_proposal(proposal, operation),
         {:ok, actor} <- current_actor(operation),
         {:ok, request} <- request(operation, proposal),
         {:ok, %Clearance{} = clearance} <-
           Targets.clear_target_request(request, actor: actor),
         :ok <- exact_provider(clearance, proposal.verification_tool),
         {:ok, attempt} <- create(operation, proposal, actor, clearance),
         {:ok, job} <- enqueue(attempt.id),
         true <- is_integer(job.id) || {:error, "Fresh verification job was not persisted"} do
      {:ok, attempt}
    end
  end

  defp valid_context(operation, incident, run) do
    expected_pending = %{
      "action" => "verify_operation",
      "operation_id" => operation.id,
      "proposal_id" => operation.proposal_id
    }

    if operation.purpose == :remediation and operation.status in @verifiable and
         incident.status == :running and
         not incident.cancel_requested and incident.pending_intent == expected_pending and
         run.active and run.status == :running and run.generation == operation.case_generation and
         run.authority_mode == operation.authority_mode,
       do: :ok,
       else: {:error, "Operation is not ready for verification"}
  end

  defp operation_evidence(operation) do
    Cases.evidence_by_idempotency(
      operation.case_id,
      "operation:outcome:#{operation.id}",
      authorize?: false
    )
  end

  defp valid_proposal(proposal, operation) do
    tool = proposal.verification_tool
    intent = proposal.verification_intent

    if proposal.id == operation.proposal_id and proposal.case_id == operation.case_id and
         proposal.resolution_run_id == operation.resolution_run_id and
         tool["target_id"] == operation.target_id and intent["tool_id"] == tool["id"] and
         is_map(intent["selectors"]) and is_map(intent["parameters"]) and
         is_map(intent["expected_result"]),
       do: :ok,
       else: {:error, "Proposal verification input does not match the Operation"}
  end

  defp current_actor(operation) do
    case Accounts.get_user(operation.actor_id, authorize?: false) do
      {:ok, %{role: role, role_version: version} = actor}
      when role in [:admin, :operator] and version == operation.actor_role_version ->
        {:ok, actor}

      _unavailable ->
        {:error, "Operation actor authority changed"}
    end
  end

  defp request(operation, proposal) do
    tool = proposal.verification_tool
    intent = proposal.verification_intent

    try do
      {:ok,
       %Request{
         kind: :verification,
         authority_mode: operation.authority_mode,
         target_id: tool["target_id"],
         target_revision: tool["target_revision"],
         access_method_id: tool["access_method_id"],
         access_method_revision: tool["access_method_revision"],
         capability: tool["capability"],
         operation: tool["operation"],
         selectors: intent["selectors"],
         parameters: intent["parameters"],
         operation_id: operation.id,
         reference: operation.reference,
         expected: intent["expected_result"],
         max_attempts: 1
       }}
    rescue
      _error -> {:error, "Proposal verification request is malformed"}
    end
  end

  defp exact_provider(clearance, tool) do
    if clearance.provider_id == tool["provider_id"] and
         clearance.provider_revision == tool["provider_revision"],
       do: :ok,
       else: {:error, "Verification Provider changed"}
  end

  defp create(operation, proposal, actor, clearance) do
    tool = proposal.verification_tool
    intent = proposal.verification_intent

    Cases.create_verification_attempt_record(
      %{
        case_id: operation.case_id,
        resolution_run_id: operation.resolution_run_id,
        operation_id: operation.id,
        proposal_id: proposal.id,
        actor_id: actor.id,
        target_id: clearance.target_id,
        access_method_id: clearance.access_method_id,
        provider_id: clearance.provider_id,
        status: :queued,
        case_generation: operation.case_generation,
        authority_mode: operation.authority_mode,
        actor_role_version: actor.role_version,
        target_revision: clearance.target_revision,
        access_method_revision: clearance.access_method_revision,
        provider_revision: clearance.provider_revision,
        tool_id: tool["id"],
        capability: clearance.capability,
        operation: clearance.operation,
        selectors: intent["selectors"],
        parameters: intent["parameters"],
        expected: intent["expected_result"],
        operation_reference: operation.reference,
        authorization_digest: Base.encode16(clearance.digest, case: :lower),
        accepted_at: DateTime.utc_now(),
        revision: 1
      },
      authorize?: false
    )
  end

  defp enqueue(id) do
    id
    |> then(&Skopos.Cases.VerificationAttempt.Worker.new(%{"verification_attempt_id" => &1}))
    |> Oban.insert()
  end

  defp required_existing(operation_id) do
    case existing(operation_id) do
      {:ok, %VerificationAttempt{} = attempt} -> {:ok, attempt}
      _missing -> {:error, "Verification budget ledger exists without its attempt"}
    end
  end

  defp existing(operation_id) do
    Cases.verification_attempt_by_operation(operation_id,
      authorize?: false,
      not_found_error?: false
    )
  end

  defp lock(resource, id) do
    resource
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(id: id)
    |> Ash.Query.lock(:for_update)
    |> Ash.read_one(authorize?: false)
    |> case do
      {:ok, nil} -> {:error, "Verification input is unavailable"}
      result -> result
    end
  end
end
