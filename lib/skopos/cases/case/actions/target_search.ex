defmodule Skopos.Cases.Case.Actions.TargetSearch do
  use Ash.Resource.Actions.Implementation

  alias Skopos.{Cases, Targets}
  alias Skopos.Cases.ResolutionRun.Budget, as: Budget
  alias Skopos.Targets.SearchResult

  @impl true
  def run(input, _opts, context) do
    arguments = input.arguments
    query = String.trim(arguments.query)
    evidence_key = Budget.key("evidence:target_search", arguments.idempotency_key)

    Budget.consume(
      case_id: arguments.id,
      resolution_run_id: arguments.resolution_run_id,
      kind: :target_request,
      amount: 1,
      ledger_key: Budget.key("case:target_search", arguments.idempotency_key),
      pending_intent: arguments.pending_intent,
      required_human_input: arguments.required_human_input,
      actor: context.actor,
      event_type: "target_search_completed",
      event_data: %{
        "query" => query,
        "max_results" => arguments.max_results,
        "request_digest" => request_digest(query, arguments.max_results)
      },
      operation: fn incident, run ->
        with {:ok, %SearchResult{} = result} <-
               Targets.search_targets(query, arguments.max_results, authorize?: false),
             {:ok, evidence} <-
               Cases.create_evidence_record(
                 %{
                   case_id: incident.id,
                   resolution_run_id: run.id,
                   idempotency_key: evidence_key,
                   kind: "target_candidates",
                   source: "target_catalog",
                   source_ref: query,
                   content: %{
                     "query" => query,
                     "max_results" => arguments.max_results,
                     "targets" => Enum.map(result.targets, &candidate/1)
                   },
                   observed_at: DateTime.utc_now()
                 },
                 authorize?: false
               ) do
          {:ok, evidence}
        end
      end,
      duplicate: fn incident, _run ->
        Cases.evidence_by_idempotency(incident.id, evidence_key, authorize?: false)
      end
    )
  end

  defp candidate(target) do
    %{
      "id" => target.id,
      "revision" => target.revision,
      "name" => target.name,
      "kind" => target.kind,
      "type_id" => target.type_id,
      "facts" => target.facts
    }
  end

  defp request_digest(query, max_results) do
    :crypto.hash(:sha256, :erlang.term_to_binary({query, max_results}, [:deterministic]))
    |> Base.encode16(case: :lower)
  end
end
