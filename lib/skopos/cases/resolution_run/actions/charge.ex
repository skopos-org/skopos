defmodule Skopos.Cases.ResolutionRun.Actions.Charge do
  use Ash.Resource.Actions.Implementation

  alias Skopos.Cases.ResolutionRun.Budget, as: Budget

  @impl true
  def run(input, _opts, context) do
    arguments = input.arguments
    ledger_key = Budget.key("budget:#{arguments.kind}", arguments.idempotency_key)

    Budget.consume(
      case_id: arguments.case_id,
      resolution_run_id: arguments.resolution_run_id,
      kind: arguments.kind,
      amount: arguments.amount,
      ledger_key: ledger_key,
      pending_intent: arguments.pending_intent,
      required_human_input: arguments.required_human_input,
      actor: context.actor,
      event_type: "budget_charged",
      event_data: %{"request_key" => arguments.idempotency_key},
      operation: fn _incident, updated_run -> {:ok, updated_run} end,
      duplicate: fn _incident, current_run -> {:ok, current_run} end
    )
  end
end
