defmodule Skopos.Audits.AuditRun.Dispatch do
  @moduledoc false

  alias Skopos.{Audits, Cases}
  alias Skopos.Audits.AuditRun

  def run(id, opts \\ []) do
    final_attempt? = Keyword.get(opts, :final_attempt?, false)

    case Audits.claim_audit_run(id, authorize?: false) do
      {:ok, %AuditRun.ClaimResult{state: :terminal, run: run}} ->
        {:ok, run}

      {:ok, %AuditRun.ClaimResult{state: :claimed, run: run, schedule: schedule}} ->
        case open_case(run, schedule) do
          {:ok, incident} -> complete(run, incident)
          {:error, _error, incident} when final_attempt? -> fail(run, incident)
          {:error, _error} when final_attempt? -> fail(run, nil)
          {:error, error, _incident} -> {:error, error}
          {:error, _error} = error -> error
        end

      {:error, _error} = error ->
        error
    end
  end

  defp open_case(run, schedule) do
    case Cases.open_case(
           :audit,
           "audit-schedule",
           "audit-run:#{run.id}",
           "Scheduled audit: #{schedule.name}",
           :info,
           %{
             "desired_outcome" => schedule.objective,
             "audit_schedule_id" => schedule.id,
             "audit_run_id" => run.id,
             "scheduled_for" => DateTime.to_iso8601(run.scheduled_for)
           },
           run.target_id,
           schedule.report_language,
           authorize?: false
         ) do
      {:ok, incident} -> start_resolution(run, schedule, incident)
      {:error, _error} = error -> error
    end
  end

  defp start_resolution(run, schedule, incident) do
    with {:ok, resolution_run} <-
           Cases.active_resolution_run(incident.id, authorize?: false),
         {:ok, result} <-
           Cases.start_turn(
             incident.id,
             resolution_run.id,
             "audit-run:#{run.id}:initial",
             %{
               "objective" => schedule.objective,
               "audit_schedule_id" => schedule.id,
               "audit_run_id" => run.id
             },
             %{"action" => "continue"},
             "Review Resolver limits",
             authorize?: false
           ),
         true <- result.status in [:charged, :duplicate, :exhausted] do
      {:ok, incident}
    else
      false -> {:error, "Audit Resolver Turn was not accepted", incident}
      {:error, error} -> {:error, error, incident}
    end
  end

  defp complete(run, incident) do
    Audits.record_audit_run_outcome(
      run,
      run.revision,
      %{
        status: :case_opened,
        case_id: incident.id,
        case_revision: incident.revision,
        completed_at: DateTime.utc_now()
      },
      authorize?: false
    )
  end

  defp fail(run, incident) do
    Audits.record_audit_run_outcome(
      run,
      run.revision,
      failure_attributes(incident),
      authorize?: false
    )
  end

  defp failure_attributes(nil) do
    %{
      status: :failed,
      reason: "Audit Case could not be started after retries",
      completed_at: DateTime.utc_now()
    }
  end

  defp failure_attributes(incident) do
    failure_attributes(nil)
    |> Map.merge(%{case_id: incident.id, case_revision: incident.revision})
  end
end
