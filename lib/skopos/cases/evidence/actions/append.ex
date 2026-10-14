defmodule Skopos.Cases.Evidence.Actions.Append do
  use Ash.Resource.Actions.Implementation

  require Ash.Query

  alias Skopos.Cases
  alias Skopos.Cases.{Case, CaseEvent, Evidence, ResolutionRun}

  @impl true
  def run(input, _opts, context) do
    arguments = input.arguments
    ledger_key = ledger_key(arguments.idempotency_key)

    Ash.transact([Case, ResolutionRun, Evidence, CaseEvent], fn ->
      with {:ok, incident} <- lock_case(arguments.case_id),
           {:ok, run} <- lock_run(arguments.resolution_run_id, incident.id),
           {:ok, event} <- existing_event(incident.id, ledger_key) do
        if event do
          with {:ok, evidence} <- existing_evidence(incident.id, arguments.idempotency_key),
               :ok <- validate_replay(evidence, arguments) do
            evidence
          end
        else
          with :ok <- ensure_running(incident, run),
               :ok <- validate_turn(arguments.turn_id, incident.id, run.id) do
            append(arguments, incident, run, ledger_key, context.actor)
          end
        end
      end
    end)
  end

  defp append(arguments, incident, run, ledger_key, actor) do
    with {:ok, evidence} <-
           Cases.create_evidence_record(
             %{
               case_id: incident.id,
               resolution_run_id: run.id,
               turn_id: arguments.turn_id,
               idempotency_key: arguments.idempotency_key,
               kind: arguments.kind,
               source: arguments.source,
               source_ref: arguments.source_ref,
               content: arguments.content,
               observed_at: arguments.observed_at
             },
             authorize?: false
           ),
         {:ok, _event} <-
           Cases.create_case_event_record(
             %{
               case_id: incident.id,
               resolution_run_id: run.id,
               actor_id: actor && actor.id,
               event_type: "evidence_added",
               idempotency_key: ledger_key,
               data: %{
                 "evidence_id" => evidence.id,
                 "turn_id" => evidence.turn_id,
                 "kind" => evidence.kind,
                 "source" => evidence.source,
                 "source_ref" => evidence.source_ref
               }
             },
             authorize?: false
           ) do
      evidence
    end
  end

  defp lock_case(id) do
    Case
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(id: id)
    |> Ash.Query.lock(:for_update)
    |> Ash.read_one(authorize?: false)
    |> required("Case is unavailable")
  end

  defp lock_run(id, case_id) do
    ResolutionRun
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(id: id, case_id: case_id, active: true)
    |> Ash.Query.lock(:for_update)
    |> Ash.read_one(authorize?: false)
    |> required("Active ResolutionRun is unavailable")
  end

  defp required({:ok, nil}, message), do: {:error, message}
  defp required(result, _message), do: result

  defp ensure_running(%{cancel_requested: true}, _run),
    do: {:error, "Case cancellation was requested"}

  defp ensure_running(%{status: :running}, %{status: :running}), do: :ok
  defp ensure_running(_incident, _run), do: {:error, "Case resolution is not running"}

  defp validate_turn(nil, _case_id, _run_id), do: :ok

  defp validate_turn(id, case_id, run_id) do
    case Cases.get_turn(id, authorize?: false) do
      {:ok, %{case_id: ^case_id, resolution_run_id: ^run_id}} -> :ok
      {:ok, _turn} -> {:error, "Turn belongs to another Case or ResolutionRun"}
      {:error, _error} -> {:error, "Turn is unavailable"}
    end
  end

  defp existing_event(case_id, key) do
    Cases.case_event_by_idempotency(case_id, key,
      authorize?: false,
      not_found_error?: false
    )
  end

  defp existing_evidence(case_id, key) do
    Cases.evidence_by_idempotency(case_id, key, authorize?: false)
  end

  defp validate_replay(evidence, arguments) do
    fields = [
      :resolution_run_id,
      :turn_id,
      :kind,
      :source,
      :source_ref,
      :observed_at
    ]

    if Map.take(evidence, fields) == Map.take(arguments, fields) and
         evidence.stored_content == arguments.content do
      :ok
    else
      {:error, "Evidence idempotency key was already used with different content"}
    end
  end

  defp ledger_key(raw_key) do
    digest = :crypto.hash(:sha256, raw_key) |> Base.encode16(case: :lower)
    "evidence:append:#{digest}"
  end
end
