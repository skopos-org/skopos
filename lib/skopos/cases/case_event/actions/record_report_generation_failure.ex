defmodule Skopos.Cases.CaseEvent.Actions.RecordReportGenerationFailure do
  use Ash.Resource.Actions.Implementation
  require Ash.Query

  alias Skopos.Cases
  alias Skopos.Cases.{Case, CaseEvent}

  @impl true
  def run(input, _opts, _context) do
    %{case_id: case_id, case_revision: revision} = input.arguments
    key = "report-generation-failed:#{revision}"

    Ash.transact([Case, CaseEvent], fn ->
      with {:ok, %Case{}} <- lock_case(case_id),
           {:ok, existing} <-
             Cases.case_event_by_idempotency(case_id, key,
               authorize?: false,
               not_found_error?: false
             ) do
        existing || create_event(case_id, revision, key)
      end
    end)
  end

  defp lock_case(id) do
    Case
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(id: id)
    |> Ash.Query.lock(:for_update)
    |> Ash.read_one(authorize?: false)
    |> case do
      {:ok, nil} -> {:error, "Case is unavailable for Report failure recording"}
      result -> result
    end
  end

  defp create_event(case_id, revision, key) do
    case Cases.create_case_event_record(
           %{
             case_id: case_id,
             event_type: "report_generation_failed",
             idempotency_key: key,
             data: %{
               "case_revision" => revision,
               "required_action" => "Retry Report generation"
             }
           },
           authorize?: false
         ) do
      {:ok, event} -> event
      {:error, _error} = failed -> failed
    end
  end
end
