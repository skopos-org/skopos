defmodule Skopos.Cases.Operation.Actions.AccountObservationProgress do
  use Ash.Resource.Actions.Implementation

  alias Skopos.Cases

  alias Skopos.Cases.{CaseEvent, Operation, ResolutionRun}
  alias Skopos.Cases.ResolutionRun.Budget, as: Budget
  alias Skopos.Cases.Case.AdmissionLock, as: CaseAdmissionLock

  alias Skopos.Cases.ResolutionRun.BudgetResult

  @terminal [:applied, :failed, :partial, :unknown]
  @history_limit 1_001

  @impl true
  def run(input, _opts, _context) do
    Ash.transact([Operation, CaseEvent, ResolutionRun], fn ->
      with :ok <- CaseAdmissionLock.acquire(),
           {:ok, operation} <- Cases.get_operation(input.arguments.id, authorize?: false),
           :ok <- terminal_observation(operation),
           key <- Budget.key("observation:progress", operation.id),
           {:ok, event} <-
             Cases.case_event_by_idempotency(operation.case_id, key,
               authorize?: false,
               not_found_error?: false
             ) do
        if event, do: replay(operation, event), else: account(operation, key)
      end
    end)
  end

  defp terminal_observation(%Operation{purpose: :investigation, status: status})
       when status in @terminal,
       do: :ok

  defp terminal_observation(_operation), do: {:error, "Observation outcome is not terminal"}

  defp replay(operation, event) do
    with true <-
           (event.event_type in ["observation_progress", "limit_exhausted"] and
              event.resolution_run_id == operation.resolution_run_id and
              event.data["operation_id"] == operation.id) ||
             {:error, "Observation progress ledger does not match the Operation"},
         {:ok, incident} <- Cases.get_case(operation.case_id, authorize?: false),
         {:ok, run} <-
           Cases.get_resolution_run(operation.resolution_run_id, authorize?: false) do
      status = if event.event_type == "limit_exhausted", do: :exhausted, else: :duplicate
      %BudgetResult{status: status, case: incident, run: run, value: operation}
    end
  end

  defp account(operation, key) do
    with {:ok, proposal} <- Cases.get_proposal(operation.proposal_id, authorize?: false),
         {:ok, turn} <- Cases.get_turn(proposal.source_turn_id, authorize?: false),
         {:ok, run} <- Cases.get_resolution_run(operation.resolution_run_id, authorize?: false),
         {:ok, history} <-
           Cases.observation_progress_history(
             operation.case_id,
             operation.resolution_run_id,
             authorize?: false
           ),
         true <-
           length(history) < @history_limit ||
             {:error, "Observation progress history exceeds the Target request limit"} do
      input_fingerprint =
        fingerprint({
          operation.target_id,
          operation.target_revision,
          operation.access_method_id,
          operation.access_method_revision,
          operation.provider_id,
          operation.provider_revision,
          operation.capability,
          operation.operation,
          operation.selectors,
          operation.parameters,
          turn.result["condition_revisions"]
        })

      scope_fingerprint =
        fingerprint({
          operation.target_id,
          operation.target_revision,
          operation.capability,
          operation.operation,
          operation.selectors,
          operation.parameters,
          turn.result["condition_revisions"]
        })

      state_fingerprint =
        fingerprint(operation.result_details["state_facts"] || operation.result_details["facts"])

      identical_count =
        Enum.count(history, fn event ->
          event.data["status"] == "applied" and
            event.data["scope_fingerprint"] == scope_fingerprint and
            event.data["state_fingerprint"] == state_fingerprint
        end)

      same_input_count =
        Enum.count(history, fn event ->
          event.data["input_fingerprint"] == input_fingerprint
        end)

      novelty? = operation.status == :applied and identical_count == 0

      kind =
        cond do
          operation.status == :applied and identical_count >= run.max_no_progress_turns ->
            :repeated_observation

          novelty? ->
            :progress

          operation.status == :failed and same_input_count == 0 ->
            :pending_result

          true ->
            :no_progress
        end

      Budget.consume(
        case_id: operation.case_id,
        resolution_run_id: operation.resolution_run_id,
        kind: kind,
        amount: 1,
        ledger_key: key,
        actor: nil,
        event_type: "observation_progress",
        event_data: %{
          "operation_id" => operation.id,
          "status" => to_string(operation.status),
          "outcome_category" => operation.outcome_category,
          "input_fingerprint" => input_fingerprint,
          "scope_fingerprint" => scope_fingerprint,
          "state_fingerprint" => state_fingerprint,
          "prior_identical_count" => identical_count,
          "prior_same_input_count" => same_input_count
        },
        pending_intent: %{
          "action" => "review_observation_progress",
          "operation_id" => operation.id
        },
        required_human_input: "Review repeated or failed Target observations before resuming",
        operation: fn _incident, _run -> {:ok, operation} end,
        duplicate: fn _incident, _run -> {:ok, operation} end
      )
      |> case do
        {:ok, %BudgetResult{} = result} -> result
        {:error, _error} = error -> error
      end
    end
  end

  defp fingerprint(value) do
    :crypto.hash(:sha256, :erlang.term_to_binary(value, [:deterministic]))
    |> Base.encode16(case: :lower)
  end
end
