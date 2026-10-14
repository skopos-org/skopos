defmodule Skopos.Cases.Turn.Actions.Complete do
  use Ash.Resource.Actions.Implementation

  alias Skopos.Cases
  alias Skopos.Cases.ResolutionRun.Budget, as: Budget

  @impl true
  def run(input, _opts, context) do
    arguments = input.arguments

    with {:ok, turn} <- Cases.get_turn(arguments.id, authorize?: false),
         digest <- result_digest(arguments.result, arguments.progress_kind),
         :ok <- validate_retry(turn, arguments.expected_revision, digest) do
      if turn.status == :completed do
        duplicate_result(turn)
      else
        complete(turn, arguments, digest, context.actor)
      end
    end
  end

  defp duplicate_result(turn) do
    with {:ok, incident} <- Cases.get_case(turn.case_id, authorize?: false),
         {:ok, run} <- Cases.get_resolution_run(turn.resolution_run_id, authorize?: false) do
      {:ok,
       %Skopos.Cases.ResolutionRun.BudgetResult{
         status: :duplicate,
         case: incident,
         run: run,
         value: turn
       }}
    end
  end

  defp complete(turn, arguments, digest, actor) do
    kind =
      case arguments.progress_kind do
        kind when kind in [:none, :hypothesis] -> :no_progress
        kind when kind in [:observation_pending, :delivery_retry] -> :pending_result
        _other -> :progress
      end

    ledger_key = Budget.key("turn:complete", "#{turn.id}:#{digest}")

    Budget.consume(
      case_id: turn.case_id,
      resolution_run_id: turn.resolution_run_id,
      kind: kind,
      amount: 1,
      ledger_key: ledger_key,
      pending_intent: arguments.pending_intent,
      required_human_input: arguments.required_human_input,
      actor: actor,
      event_type: "turn_completed",
      event_data: %{
        "turn_id" => turn.id,
        "result_digest" => digest,
        "progress_kind" => to_string(arguments.progress_kind)
      },
      operation: fn _incident, _updated_run ->
        Cases.complete_turn_record(
          turn,
          arguments.expected_revision,
          %{
            result: arguments.result,
            result_digest: digest,
            progress_kind: arguments.progress_kind,
            completed_at: DateTime.utc_now()
          },
          authorize?: false
        )
      end,
      duplicate: fn _incident, _run ->
        Cases.get_turn(turn.id, authorize?: false)
      end
    )
  end

  defp validate_retry(%{status: :started, revision: revision}, revision, _digest), do: :ok

  defp validate_retry(%{status: :started}, _revision, _digest),
    do: invalid("Turn revision changed")

  defp validate_retry(%{status: :completed, result_digest: digest}, _revision, digest), do: :ok

  defp validate_retry(%{status: :completed}, _revision, _digest),
    do: invalid("Turn was already completed with a different result")

  defp result_digest(result, progress_kind) do
    Jason.encode!(%{"progress_kind" => progress_kind, "result" => result})
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp invalid(message),
    do: {:error, Ash.Error.Changes.InvalidChanges.exception(message: message)}
end
