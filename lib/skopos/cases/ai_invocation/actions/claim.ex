defmodule Skopos.Cases.AIInvocation.Actions.Claim do
  use Ash.Resource.Actions.Implementation
  require Ash.Query

  alias Skopos.Cases
  alias Skopos.Providers.AI

  alias Skopos.Cases.{
    AIInvocation,
    Case,
    Proposal,
    ResolutionRun,
    Turn
  }

  alias Skopos.Cases.AIInvocation.Claim, as: AIInvocationClaim
  alias Skopos.Cases.Case.AdmissionLock

  @impl true
  def run(input, _opts, _context) do
    arguments = input.arguments

    Ash.transact([AIInvocation, Case, Proposal, ResolutionRun, Turn], fn ->
      with :ok <- AdmissionLock.acquire(),
           {:ok, incident} <- lock(Case, arguments.case_id),
           {:ok, run} <- lock(ResolutionRun, arguments.resolution_run_id),
           :ok <- current_context(arguments, incident, run),
           {:ok, existing} <- invocation(arguments) do
        claim(existing, arguments, run)
      end
    end)
  end

  defp claim(nil, arguments, run) do
    remaining = run.max_ai_usage_units - run.ai_usage_units

    if remaining > 0 do
      attrs = %{
        role: arguments.role,
        case_id: arguments.case_id,
        resolution_run_id: arguments.resolution_run_id,
        turn_id: arguments.turn_id,
        proposal_id: arguments.proposal_id,
        provider_id: arguments.provider_id,
        assignment_id: arguments.assignment_id,
        idempotency_key: idempotency_key(arguments),
        request_digest: arguments.request_digest,
        provider_revision: arguments.provider_revision,
        assignment_revision: arguments.assignment_revision,
        selection_source: arguments.selection_source,
        reserved_units: reservation_units(arguments, remaining),
        dispatch_started_at: DateTime.utc_now()
      }

      with {:ok, invocation} <- Cases.create_ai_invocation_record(attrs, authorize?: false) do
        %AIInvocationClaim{
          state: :claimed,
          invocation: invocation,
          invocation_context: arguments.invocation_context
        }
      end
    else
      {:error, "AI usage limit exhausted"}
    end
  end

  defp claim(%{status: :queued} = invocation, arguments, run) do
    selection = [:provider_id, :provider_revision, :assignment_id, :assignment_revision]
    remaining = run.max_ai_usage_units - run.ai_usage_units

    with true <-
           Enum.all?(selection, &(Map.fetch!(invocation, &1) == Map.fetch!(arguments, &1))) ||
             {:error, "Queued AI assignment changed"},
         true <- remaining > 0 || {:error, "AI usage limit exhausted"},
         {:ok, invocation} <-
           Cases.begin_ai_invocation_dispatch(
             invocation,
             invocation.revision,
             arguments.request_digest,
             reservation_units(arguments, remaining),
             authorize?: false
           ) do
      %AIInvocationClaim{
        state: :claimed,
        invocation: invocation,
        invocation_context: arguments.invocation_context
      }
    end
  end

  defp claim(%{status: :dispatching} = invocation, _arguments, _run) do
    with {:ok, invocation} <-
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
           ) do
      %AIInvocationClaim{state: :interrupted, invocation: invocation}
    end
  end

  defp claim(%{status: :unknown} = invocation, _arguments, _run),
    do: %AIInvocationClaim{state: :interrupted, invocation: invocation}

  defp claim(invocation, _arguments, _run),
    do: %AIInvocationClaim{state: :terminal, invocation: invocation}

  # Capacity-based allowance when usage is missing, not a token or billing bound.
  defp reservation_units(arguments, remaining),
    do: min(remaining, arguments.request_size_bytes + AI.max_output_bytes())

  defp current_context(arguments, incident, run) do
    with true <-
           (incident.revision == arguments.expected_case_revision and
              incident.status == :running and not incident.cancel_requested) ||
             {:error, "Case AI context changed"},
         true <-
           (run.case_id == incident.id and run.active and run.status == :running) ||
             {:error, "ResolutionRun AI context changed"},
         :ok <- subject_context(arguments, incident.id, run.id),
         :ok <- bound_context(arguments),
         {:ok, true} <-
           Cases.invocation_context_current(arguments.invocation_context,
             authorize?: false
           ) do
      :ok
    else
      {:ok, false} -> {:error, "Case AI context changed"}
      other -> other
    end
  end

  defp bound_context(arguments) do
    context = arguments.invocation_context

    subject =
      if arguments.proposal_id,
        do: {:proposal, arguments.proposal_id, arguments.expected_proposal_revision, :reviewing},
        else:
          {:turn, arguments.turn_id, arguments.expected_turn_revision,
           if(arguments.role == :resolver, do: :started, else: :completed)}

    selection = context.selection

    if context.case_id == arguments.case_id and
         context.case_revision == arguments.expected_case_revision and
         context.resolution_run_id == arguments.resolution_run_id and
         context.subject == subject and not is_nil(selection) and
         selection.role == arguments.role and selection.source == arguments.selection_source and
         selection.provider_id == arguments.provider_id and
         selection.provider_revision == arguments.provider_revision and
         selection.assignment_id == arguments.assignment_id and
         selection.assignment_revision == arguments.assignment_revision,
       do: :ok,
       else: {:error, "AI invocation context is not bound to its subject and assignment"}
  end

  defp subject_context(%{role: :resolver} = arguments, case_id, run_id)
       when is_binary(arguments.turn_id) and is_nil(arguments.proposal_id) and
              is_integer(arguments.expected_turn_revision) do
    with {:ok, turn} <- lock(Turn, arguments.turn_id),
         true <-
           (turn.case_id == case_id and turn.resolution_run_id == run_id and
              turn.status == :started and turn.revision == arguments.expected_turn_revision) ||
             {:error, "Resolver Turn AI context changed"} do
      :ok
    end
  end

  defp subject_context(%{role: :reviewer} = arguments, case_id, run_id)
       when is_binary(arguments.proposal_id) and is_nil(arguments.turn_id) and
              is_integer(arguments.expected_proposal_revision) do
    with {:ok, proposal} <- lock(Proposal, arguments.proposal_id),
         true <-
           (proposal.case_id == case_id and proposal.resolution_run_id == run_id and
              proposal.status == :reviewing and
              proposal.revision == arguments.expected_proposal_revision) ||
             {:error, "Reviewer Proposal AI context changed"} do
      :ok
    end
  end

  defp subject_context(%{role: :reviewer} = arguments, case_id, run_id)
       when is_binary(arguments.turn_id) and is_nil(arguments.proposal_id) and
              is_integer(arguments.expected_turn_revision) do
    with {:ok, turn} <- lock(Turn, arguments.turn_id),
         true <-
           (turn.case_id == case_id and turn.resolution_run_id == run_id and
              turn.status == :completed and turn.revision == arguments.expected_turn_revision and
              get_in(turn.result, ["intent", "type"]) == "recovery_conclusion") ||
             {:error, "Recovery Reviewer Turn context changed"} do
      :ok
    end
  end

  defp subject_context(_arguments, _case_id, _run_id),
    do: {:error, "AI invocation subject is invalid"}

  defp invocation(arguments) do
    with {:ok, exact} <-
           AIInvocation
           |> Ash.Query.for_read(:by_idempotency, %{
             idempotency_key: idempotency_key(arguments)
           })
           |> Ash.Query.lock(:for_update)
           |> Ash.read_one(authorize?: false) do
      case exact do
        nil -> unresolved_invocation(arguments)
        invocation -> {:ok, invocation}
      end
    end
  end

  defp unresolved_invocation(%{role: :resolver, turn_id: turn_id}) do
    AIInvocation
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(
      turn_id == ^turn_id and role == :resolver and status in [:queued, :dispatching]
    )
    |> unresolved_invocation()
  end

  defp unresolved_invocation(%{role: :reviewer, turn_id: turn_id, proposal_id: nil})
       when is_binary(turn_id) do
    AIInvocation
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(
      turn_id == ^turn_id and role == :reviewer and status in [:queued, :dispatching]
    )
    |> unresolved_invocation()
  end

  defp unresolved_invocation(%{role: :reviewer, proposal_id: proposal_id})
       when is_binary(proposal_id) do
    AIInvocation
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(proposal_id == ^proposal_id and status in [:queued, :dispatching])
    |> unresolved_invocation()
  end

  defp unresolved_invocation(query) do
    query
    |> Ash.Query.sort(dispatch_started_at: :asc)
    |> Ash.Query.limit(1)
    |> Ash.Query.lock(:for_update)
    |> Ash.read_one(authorize?: false)
  end

  defp idempotency_key(%{role: :reviewer, proposal_id: proposal_id, delivery_attempt: attempt})
       when is_binary(proposal_id) and is_integer(attempt),
       do: "reviewer:#{proposal_id}:attempt:#{attempt}"

  defp idempotency_key(%{
         role: :reviewer,
         turn_id: turn_id,
         proposal_id: nil,
         delivery_attempt: attempt
       })
       when is_binary(turn_id) and is_integer(attempt),
       do: "recovery-reviewer:#{turn_id}:attempt:#{attempt}"

  defp idempotency_key(arguments) do
    subject_id = arguments.turn_id || arguments.proposal_id
    "#{arguments.role}:#{subject_id}:#{arguments.request_digest}"
  end

  defp lock(resource, id) do
    resource
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(id: id)
    |> Ash.Query.lock(:for_update)
    |> Ash.read_one(authorize?: false)
    |> case do
      {:ok, nil} -> {:error, "AI invocation context is unavailable"}
      result -> result
    end
  end
end
