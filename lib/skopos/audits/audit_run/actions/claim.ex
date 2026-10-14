defmodule Skopos.Audits.AuditRun.Actions.Claim do
  use Ash.Resource.Actions.Implementation
  require Ash.Query

  alias Skopos.{Audits, Cases}
  alias Skopos.Audits.{AuditRun, AuditSchedule}
  alias Skopos.Targets.Target

  @terminal [:case_opened, :skipped, :cancelled, :failed]

  @impl true
  def run(input, _opts, _context) do
    Ash.transact([AuditRun, AuditSchedule, Target], fn ->
      with {:ok, run} <- lock(AuditRun, input.arguments.id, "Audit Run is unavailable"),
           {:ok, schedule} <-
             lock(AuditSchedule, run.audit_schedule_id, "Audit schedule is unavailable") do
        claim(run, schedule)
      end
    end)
  end

  defp claim(%{status: status} = run, schedule) when status in @terminal,
    do: %AuditRun.ClaimResult{state: :terminal, run: run, schedule: schedule}

  defp claim(%{status: :running} = run, schedule) do
    with {:ok, existing} <- existing_case(run) do
      if existing do
        claimed(run, schedule)
      else
        claim_startable(run, schedule)
      end
    end
  end

  defp claim(%{status: :queued} = run, schedule), do: claim_startable(run, schedule)

  defp claim_startable(run, %{active: false} = schedule) do
    terminal(run, schedule, :cancelled, "Audit schedule was deactivated before Case creation")
  end

  defp claim_startable(run, schedule) do
    with {:ok, target} <- load_target(run.target_id) do
      if target.active and target.revision == run.target_revision do
        case run.status do
          :queued ->
            with {:ok, running} <-
                   Audits.mark_audit_run_running(
                     run,
                     run.revision,
                     %{started_at: DateTime.utc_now()},
                     authorize?: false
                   ) do
              claimed(running, schedule)
            end

          :running ->
            claimed(run, schedule)
        end
      else
        terminal(run, schedule, :skipped, "Target changed before Audit Case creation")
      end
    else
      {:error, _error} -> terminal(run, schedule, :skipped, "Target is unavailable")
    end
  end

  defp claimed(run, schedule),
    do: %AuditRun.ClaimResult{state: :claimed, run: run, schedule: schedule}

  defp terminal(run, schedule, status, reason) do
    with {:ok, terminal} <-
           Audits.record_audit_run_outcome(
             run,
             run.revision,
             %{status: status, reason: reason, completed_at: DateTime.utc_now()},
             authorize?: false
           ) do
      %AuditRun.ClaimResult{state: :terminal, run: terminal, schedule: schedule}
    end
  end

  defp existing_case(run) do
    Cases.case_by_trigger(:audit, "audit-schedule", "audit-run:#{run.id}",
      authorize?: false,
      not_found_error?: false
    )
  end

  defp load_target(nil), do: {:error, "Audit Run has no Target"}

  defp load_target(id) do
    Target
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(id: id)
    |> Ash.Query.lock(:for_update)
    |> Ash.read_one(authorize?: false)
    |> case do
      {:ok, nil} -> {:error, "Target is unavailable"}
      result -> result
    end
  end

  defp lock(resource, id, message) do
    resource
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(id: id)
    |> Ash.Query.lock(:for_update)
    |> Ash.read_one(authorize?: false)
    |> case do
      {:ok, nil} -> {:error, message}
      result -> result
    end
  end
end
