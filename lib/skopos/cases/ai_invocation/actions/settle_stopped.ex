defmodule Skopos.Cases.AIInvocation.Actions.SettleStopped do
  use Ash.Resource.Actions.Implementation
  require Ash.Query

  alias Skopos.Cases
  alias Skopos.Cases.{AIInvocation, Case, CaseEvent, ResolutionRun}
  alias Skopos.Cases.ResolutionRun.Budget

  @impl true
  def run(input, _opts, _context) do
    args = input.arguments

    Ash.transact([Case, ResolutionRun, AIInvocation, CaseEvent], fn ->
      with {:ok, incident} <- lock(Case, args.case_id),
           {:ok, run} <- lock(ResolutionRun, args.resolution_run_id),
           true <- run.case_id == incident.id || invalid("ResolutionRun belongs to another Case"),
           true <-
             (incident.cancel_requested or incident.status != :running or not run.active or
                run.status != :running) || invalid("Case resolution is still running"),
           true <-
             is_nil(args.turn_id) != is_nil(args.proposal_id) ||
               invalid("One AI invocation subject is required"),
           {:ok, invocations} <- pending(args) do
        Enum.reduce_while(invocations, :ok, fn invocation, :ok ->
          case settle(invocation) do
            :ok -> {:cont, :ok}
            {:error, _cause} = error -> {:halt, error}
          end
        end)
      end
    end)
  end

  defp pending(args) do
    query =
      AIInvocation
      |> Ash.Query.for_read(:read)
      |> Ash.Query.filter(
        case_id: args.case_id,
        resolution_run_id: args.resolution_run_id,
        role: args.role,
        status: [in: [:dispatching, :unknown]]
      )

    query =
      if args.turn_id,
        do: Ash.Query.filter(query, turn_id: args.turn_id),
        else: Ash.Query.filter(query, proposal_id: args.proposal_id)

    query
    |> Ash.Query.sort(id: :asc)
    |> Ash.Query.lock(:for_update)
    |> Ash.read(authorize?: false)
  end

  defp settle(invocation) do
    with {:ok, _charged} <-
           Cases.charge_resolution_run(
             invocation.case_id,
             invocation.resolution_run_id,
             :ai_usage,
             invocation.reserved_units,
             interruption_key(invocation),
             %{"action" => "reserve_unknown_ai_usage", "ai_invocation_id" => invocation.id},
             "Review the unknown AI usage",
             authorize?: false
           ),
         {:ok, _recorded} <- record_unknown(invocation) do
      :ok
    end
  end

  defp record_unknown(%{status: :unknown} = invocation), do: {:ok, invocation}

  defp record_unknown(invocation) do
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
    )
  end

  defp interruption_key(%{role: :resolver, id: id}), do: "resolver-unknown:#{id}"

  defp interruption_key(%{proposal_id: id} = invocation) when not is_nil(id),
    do: "review-unknown:#{invocation.id}"

  defp interruption_key(invocation),
    do: Budget.key("recovery-review:usage", "unknown:#{invocation.id}")

  defp lock(resource, id) do
    resource
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(id: id)
    |> Ash.Query.lock(:for_update)
    |> Ash.read_one(authorize?: false)
    |> case do
      {:ok, nil} -> invalid("AI invocation context is unavailable")
      result -> result
    end
  end

  defp invalid(message),
    do: {:error, Ash.Error.Changes.InvalidChanges.exception(message: message)}
end
