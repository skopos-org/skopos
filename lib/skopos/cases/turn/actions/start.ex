defmodule Skopos.Cases.Turn.Actions.Start do
  use Ash.Resource.Actions.Implementation

  alias Skopos.Cases
  alias Skopos.Cases.ResolutionRun.Budget, as: Budget

  @impl true
  def run(input, _opts, context) do
    arguments = input.arguments
    ledger_key = Budget.key("turn:start", arguments.idempotency_key)

    Budget.consume(
      case_id: arguments.case_id,
      resolution_run_id: arguments.resolution_run_id,
      kind: :turn,
      amount: 1,
      ledger_key: ledger_key,
      pending_intent: arguments.pending_intent,
      required_human_input: arguments.required_human_input,
      actor: context.actor,
      event_type: "turn_started",
      event_data: %{"turn_key" => arguments.idempotency_key},
      operation: fn incident, updated_run ->
        with {:ok, turn} <-
               Cases.create_turn_record(
                 %{
                   case_id: incident.id,
                   resolution_run_id: updated_run.id,
                   ordinal: updated_run.turn_count,
                   idempotency_key: arguments.idempotency_key,
                   status: :started,
                   intent: arguments.intent,
                   result: %{},
                   started_at: DateTime.utc_now()
                 },
                 authorize?: false
               ),
             {:ok, job} <- enqueue(turn.id),
             true <-
               is_integer(job.id) ||
                 {:error,
                  Ash.Error.Unknown.UnknownError.exception(
                    error: "Resolver job was not persisted"
                  )} do
          {:ok, turn}
        end
      end,
      duplicate: fn _incident, run ->
        with {:ok, turn} <-
               Cases.turn_by_idempotency(run.id, arguments.idempotency_key, authorize?: false),
             true <-
               turn.intent == arguments.intent ||
                 invalid("Turn idempotency key was already used with a different intent") do
          {:ok, turn}
        end
      end
    )
  end

  defp enqueue(turn_id) do
    %{"turn_id" => turn_id}
    |> Skopos.Cases.Turn.ResolverWorker.new()
    |> Oban.insert()
  end

  defp invalid(message),
    do: {:error, Ash.Error.Changes.InvalidChanges.exception(message: message)}
end
