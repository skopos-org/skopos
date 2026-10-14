defmodule Skopos.Cases.Operation.Actions.ClaimDispatch do
  use Ash.Resource.Actions.Implementation
  import Ash.Expr
  require Ash.Query

  alias Skopos.{Accounts, Cases, Targets}
  alias Skopos.Targets.TargetRequest.{Request, RequestError}

  alias Skopos.Cases.{Case, CaseEvent, Evidence, Operation, Proposal, ResolutionRun, Turn}
  alias Skopos.Cases.ResolutionRun.Budget, as: Budget

  alias Skopos.Cases.Case.AdmissionLock, as: CaseAdmissionLock
  alias Skopos.Cases.Case.ConditionContext, as: ConditionContext
  alias Skopos.Cases.Case.InvocationContext

  alias Skopos.Cases.Operation.Claim, as: OperationClaim

  @terminal [:applied, :failed, :partial, :unknown]

  @impl true
  def run(input, _opts, _context) do
    with {:ok, source} <- Cases.get_operation(input.arguments.id, authorize?: false) do
      Ash.transact([Case, ResolutionRun, Operation, Turn, CaseEvent], fn ->
        with :ok <- CaseAdmissionLock.acquire(),
             {:ok, incident} <- lock(Case, source.case_id),
             {:ok, run} <- lock(ResolutionRun, source.resolution_run_id),
             {:ok, operation} <- lock(Operation, source.id) do
          claim(operation, incident, run)
        end
      end)
    end
  end

  defp claim(%{status: :queued} = operation, incident, run) do
    cond do
      incident.status != :running or incident.cancel_requested or not run.active or
        run.status != :running or run.generation != operation.case_generation ->
        terminal_no_send(
          operation,
          "cancelled_before_dispatch",
          "Case stopped before the Target request was dispatched"
        )

      DateTime.compare(DateTime.utc_now(), run.deadline_at) != :lt ->
        terminal_no_send(
          operation,
          "run_deadline_elapsed",
          "ResolutionRun deadline elapsed before the Target request was dispatched"
        )

      true ->
        with {:ok, proposal} <- lock(Proposal, operation.proposal_id),
             {:ok, current?} <- ConditionContext.current?(incident, proposal.source_turn_id),
             {:ok, affected_current?} <-
               ConditionContext.affected_current?(
                 incident,
                 proposal.request_kind,
                 proposal.affected_conditions,
                 proposal.evidence_ids,
                 proposal,
                 operation.id
               ) do
          if current? and affected_current? do
            with {:ok, conflict} <- effect_conflict(operation, proposal) do
              claim_after_conflict(operation, incident, run, conflict)
            end
          else
            stop_stale_dispatch(operation, incident, run)
          end
        end
    end
  end

  defp claim(%{status: :dispatching} = operation, _incident, _run) do
    with {:ok, terminal} <-
           complete(operation, :unknown, "dispatch_interrupted", %{
             "message" => "Dispatch ownership was lost after the durable send marker"
           }) do
      %OperationClaim{state: :terminal, operation: terminal}
    end
  end

  defp claim(%{status: status} = operation, _incident, _run) when status in @terminal,
    do: %OperationClaim{state: :terminal, operation: operation}

  defp terminal_no_send(operation, category, message) do
    with {:ok, terminal} <- no_send(operation, category, %{"message" => message}) do
      %OperationClaim{state: :terminal, operation: terminal}
    end
  end

  defp claim_after_conflict(operation, incident, run, :clear) do
    if DateTime.compare(DateTime.utc_now(), operation.not_before) == :lt do
      %OperationClaim{state: :deferred, operation: operation}
    else
      claim_authorized(operation, incident, run)
    end
  end

  defp claim_after_conflict(operation, _incident, _run, {:busy, _prior}),
    do: %OperationClaim{state: :deferred, operation: operation}

  defp claim_after_conflict(operation, incident, run, {:changed, prior}) do
    stop_stale_dispatch(operation, incident, run, "target_effect_changed", %{
      "message" => "A prior Target effect requires a new observation before another effect",
      "prior_operation_id" => prior.id
    })
  end

  defp claim_after_conflict(operation, incident, run, {:unknown, prior}) do
    key = Budget.key("operation:unknown-prior-effect", operation.id)

    with {:ok, terminal} <-
           no_send(operation, "prior_effect_unknown", %{
             "message" => "A prior Target effect has an unknown result",
             "prior_operation_id" => prior.id
           }),
         {:ok, _attention} <-
           Cases.require_case_attention(
             incident.id,
             incident.revision,
             run.id,
             run.revision,
             key,
             "A prior Target effect has an unknown result",
             %{"action" => "review_target_effect", "prior_operation_id" => prior.id},
             "Observe the Target before approving another effect",
             authorize?: false
           ) do
      %OperationClaim{state: :terminal, operation: terminal}
    end
  end

  defp claim_authorized(operation, incident, run) do
    with {:ok, actor} <- current_actor(operation),
         {:ok, clearance} <- Targets.clear_target_request(request(operation), actor: actor),
         :ok <- exact_clearance(clearance, operation),
         {:ok, conditions} <- ConditionContext.current_conditions(incident) do
      with {:ok, claimed} <-
             Cases.mark_operation_dispatching(
               operation,
               operation.revision,
               %{dispatch_started_at: DateTime.utc_now()},
               authorize?: false
             ) do
        context =
          InvocationContext.project(
            incident,
            run,
            {:operation, claimed.id, claimed.revision, claimed.status},
            conditions,
            nil,
            [clearance]
          )

        %OperationClaim{
          state: :claimed,
          operation: claimed,
          actor: actor,
          clearance: clearance,
          invocation_context: context
        }
      end
    else
      {:error, error} = failure ->
        if RequestError.expected?(error) do
          terminal_no_send(
            operation,
            "authorization_invalidated",
            "Operation authorization changed before dispatch"
          )
        else
          failure
        end
    end
  end

  defp current_actor(operation) do
    case Accounts.get_user(operation.actor_id, authorize?: false) do
      {:ok, %{role: role, role_version: version} = actor}
      when role in [:admin, :operator] and version == operation.actor_role_version ->
        {:ok, actor}

      {:ok, _changed} ->
        {:error,
         RequestError.exception(
           category: :forbidden,
           message: "Operation actor authority changed"
         )}

      {:error, _error} = error ->
        error
    end
  end

  defp request(operation) do
    %Request{
      kind: operation.request_kind,
      authority_mode: operation.authority_mode,
      target_id: operation.target_id,
      target_revision: operation.target_revision,
      access_method_id: operation.access_method_id,
      access_method_revision: operation.access_method_revision,
      capability: operation.capability,
      operation: operation.operation,
      selectors: operation.selectors,
      parameters: operation.parameters,
      operation_id: operation.id,
      idempotency_key: operation.idempotency_key,
      max_attempts: 1
    }
  end

  defp exact_clearance(clearance, operation) do
    if clearance.provider_id == operation.provider_id and
         clearance.provider_revision == operation.provider_revision and
         Base.encode16(clearance.digest, case: :lower) == operation.authorization_digest,
       do: :ok,
       else:
         {:error,
          RequestError.exception(
            category: :clearance_mismatch,
            message: "Operation clearance changed"
          )}
  end

  defp effect_conflict(%{request_kind: :observation}, _proposal), do: {:ok, :clear}

  defp effect_conflict(%{purpose: :investigation} = operation, _proposal) do
    case conflicting_effect(operation, [:dispatching]) do
      {:ok, nil} -> {:ok, :clear}
      {:ok, active} -> {:ok, {:busy, active}}
      {:error, _error} = error -> error
    end
  end

  defp effect_conflict(operation, proposal) do
    with {:ok, active} <- conflicting_effect(operation, [:dispatching]),
         {:ok, prior} <- conflicting_effect(operation, [:applied, :partial, :failed, :unknown]) do
      cond do
        active -> {:ok, {:busy, active}}
        is_nil(prior) -> {:ok, :clear}
        fresh_observation?(proposal, operation, prior) -> {:ok, :clear}
        prior.status == :unknown -> {:ok, {:unknown, prior}}
        true -> {:ok, {:changed, prior}}
      end
    end
  end

  defp conflicting_effect(operation, statuses) do
    target = operation.target_id
    scope = operation.resource_scope

    query =
      Operation
      |> Ash.Query.for_read(:read)
      |> Ash.Query.filter(
        expr(
          target_id == ^target and request_kind == :effect and
            status in ^statuses and
            (status != :failed or not is_nil(dispatch_started_at))
        )
      )

    query =
      if scope == "target" do
        query
      else
        Ash.Query.filter(
          query,
          expr(resource_scope in ^["target", scope])
        )
      end

    query
    |> Ash.Query.sort(
      completed_at: :desc_nils_last,
      dispatch_started_at: :desc_nils_last,
      id: :desc
    )
    |> Ash.Query.limit(1)
    |> Ash.read_one(authorize?: false)
  end

  defp fresh_observation?(proposal, operation, prior) do
    Enum.any?(proposal.evidence_ids, fn id ->
      case Cases.get_evidence(id, authorize?: false) do
        {:ok,
         %Evidence{
           case_id: case_id,
           kind: "observation",
           source: "operation",
           source_ref: source_ref,
           observed_at: observed_at,
           content: %{"status" => "applied", "target_id" => target_id}
         }}
        when case_id == operation.case_id and target_id == operation.target_id ->
          source_observation_current?(source_ref, observed_at, operation, prior)

        _other ->
          false
      end
    end)
  end

  defp source_observation_current?(source_ref, observed_at, operation, prior) do
    case Cases.get_operation(source_ref, authorize?: false) do
      {:ok,
       %{
         purpose: :investigation,
         status: :applied,
         target_id: target_id,
         target_revision: target_revision,
         case_id: case_id,
         resolution_run_id: run_id,
         resource_scope: scope,
         completed_at: completed_at
       }}
      when target_id == operation.target_id and case_id == operation.case_id ->
        current =
          if source_ref == prior.id do
            run_id == operation.resolution_run_id and
              target_revision == operation.target_revision and
              DateTime.compare(observed_at, completed_at) == :eq
          else
            DateTime.compare(observed_at, prior.completed_at) == :gt and
              DateTime.compare(completed_at, prior.completed_at) == :gt
          end

        current and
          (scope == "target" or
             (scope == operation.resource_scope and scope == prior.resource_scope))

      _other ->
        false
    end
  end

  defp stop_stale_dispatch(operation, incident, run) do
    stop_stale_dispatch(operation, incident, run, "source_context_changed", %{
      "message" => "Signal Conditions changed before Target dispatch"
    })
  end

  defp stop_stale_dispatch(operation, incident, run, category, details) do
    with {:ok, terminal} <-
           no_send(operation, category, details),
         {:ok, started} <-
           Cases.start_turn(
             incident.id,
             run.id,
             Budget.key("operation:context-changed", operation.id),
             %{
               "objective" => "Reassess the Target before another request",
               "source_operation_id" => operation.id
             },
             %{"action" => "continue_resolution", "source_operation_id" => operation.id},
             "Review Resolver limits",
             authorize?: false
           ),
         {:ok, _pending} <- pending_after_context_change(started, operation.id) do
      %OperationClaim{state: :terminal, operation: terminal}
    end
  end

  defp pending_after_context_change(%{status: :exhausted}, _operation_id),
    do: {:ok, :needs_attention}

  defp pending_after_context_change(%{status: status, case: incident, value: turn}, operation_id)
       when status in [:charged, :duplicate] do
    Cases.handoff_case_operation(
      incident,
      incident.revision,
      operation_id,
      :stale_dispatch,
      turn.id,
      nil,
      nil,
      authorize?: false
    )
  end

  defp complete(operation, status, category, details) do
    Cases.record_operation_outcome(
      operation,
      operation.revision,
      %{
        status: status,
        outcome_category: category,
        result_details: details,
        completed_at: DateTime.utc_now()
      },
      authorize?: false
    )
  end

  defp no_send(operation, category, details) do
    Cases.record_operation_no_send(
      operation,
      operation.revision,
      %{
        outcome_category: category,
        result_details: details,
        completed_at: DateTime.utc_now()
      },
      authorize?: false
    )
  end

  defp lock(resource, id) do
    resource
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(id: id)
    |> Ash.Query.lock(:for_update)
    |> Ash.read_one(authorize?: false)
    |> case do
      {:ok, nil} -> {:error, "Operation dispatch input is unavailable"}
      result -> result
    end
  end
end
