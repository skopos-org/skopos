defmodule Skopos.Audits.AuditSchedule.Actions.Wake do
  use Ash.Resource.Actions.Implementation
  require Ash.Query

  alias Skopos.Audits
  alias Skopos.Audits.{AuditRun, AuditSchedule}
  alias Skopos.Audits.AuditSchedule.Scheduling
  alias Skopos.Targets.{ManagementBoundary, Target}

  @impl true
  def run(input, _opts, _context) do
    arguments = input.arguments

    Ash.transact([AuditSchedule, AuditRun, ManagementBoundary, Target], fn ->
      with {:ok, schedule} <- lock_schedule(arguments.id),
           {:ok, existing} <- existing_runs(schedule.id, arguments.scheduled_for) do
        wake(schedule, existing, arguments)
      end
    end)
  end

  defp wake(schedule, [_ | _], _arguments), do: schedule

  defp wake(schedule, [], arguments) do
    if due?(schedule, arguments) do
      with {:ok, specs} <- run_specs(schedule),
           {:ok, _runs} <- create_runs(schedule, arguments.scheduled_for, specs),
           {:ok, next_run_at} <- next_run(schedule, arguments.scheduled_for),
           {:ok, advanced} <-
             Audits.advance_audit_schedule_record(
               schedule,
               schedule.revision,
               %{next_run_at: next_run_at},
               authorize?: false
             ),
           {:ok, _job} <- enqueue_next(advanced) do
        advanced
      end
    else
      schedule
    end
  end

  defp due?(schedule, arguments) do
    schedule.active and schedule.revision == arguments.expected_revision and
      DateTime.compare(schedule.next_run_at, arguments.scheduled_for) == :eq
  end

  defp lock_schedule(id) do
    AuditSchedule
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(id: id)
    |> Ash.Query.lock(:for_update)
    |> Ash.read_one(authorize?: false)
    |> case do
      {:ok, nil} -> {:error, "Audit schedule is unavailable"}
      result -> result
    end
  end

  defp existing_runs(schedule_id, scheduled_for) do
    Audits.audit_runs_for_occurrence(schedule_id, scheduled_for, authorize?: false)
  end

  defp run_specs(%{target_ids: [_ | _] = target_ids}) do
    Target
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(id in ^target_ids)
    |> Ash.Query.sort(id: :asc)
    |> Ash.read(authorize?: false)
    |> case do
      {:ok, targets} ->
        by_id = Map.new(targets, &{&1.id, &1})

        {:ok,
         Enum.map(target_ids, fn id ->
           case Map.get(by_id, id) do
             %{active: true} = target -> target_spec(target)
             %{} = target -> skipped_target_spec(target, "Target is inactive")
             nil -> missing_target_spec(id)
           end
         end)}

      {:error, _error} = error ->
        error
    end
  end

  defp run_specs(%{management_boundary_id: boundary_id}) do
    with {:ok, boundary} <- load_boundary(boundary_id) do
      if boundary.active do
        boundary_specs(boundary)
      else
        {:ok, [scope_spec(boundary.id, "Management boundary is inactive")]}
      end
    end
  end

  defp load_boundary(id) do
    ManagementBoundary
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(id: id)
    |> Ash.read_one(authorize?: false)
    |> case do
      {:ok, nil} -> {:error, "Management boundary is unavailable"}
      result -> result
    end
  end

  defp boundary_specs(boundary) do
    Target
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(management_boundary_id == ^boundary.id and active == true)
    |> Ash.Query.sort(id: :asc)
    |> Ash.read(authorize?: false)
    |> case do
      {:ok, []} ->
        {:ok, [scope_spec(boundary.id, "Management boundary has no active Targets")]}

      {:ok, targets} ->
        {:ok, Enum.map(targets, &target_spec/1)}

      {:error, _error} = error ->
        error
    end
  end

  defp target_spec(target) do
    %{
      target_key: "target:#{target.id}",
      target_id: target.id,
      target_revision: target.revision,
      status: :queued,
      reason: nil
    }
  end

  defp skipped_target_spec(target, reason) do
    target
    |> target_spec()
    |> Map.merge(%{status: :skipped, reason: reason})
  end

  defp missing_target_spec(id) do
    %{
      target_key: "target:#{id}",
      target_id: nil,
      target_revision: nil,
      status: :skipped,
      reason: "Target is unavailable"
    }
  end

  defp scope_spec(boundary_id, reason) do
    %{
      target_key: "scope:#{boundary_id}",
      target_id: nil,
      target_revision: nil,
      status: :skipped,
      reason: reason
    }
  end

  defp create_runs(schedule, scheduled_for, specs) do
    now = DateTime.utc_now()

    Enum.reduce_while(specs, {:ok, []}, fn spec, {:ok, runs} ->
      attrs =
        spec
        |> Map.merge(%{
          audit_schedule_id: schedule.id,
          schedule_revision: schedule.revision,
          scheduled_for: scheduled_for,
          completed_at: if(spec.status == :skipped, do: now)
        })

      with {:ok, run} <- Audits.create_audit_run_record(attrs, authorize?: false),
           {:ok, _job} <- maybe_enqueue_run(run) do
        {:cont, {:ok, [run | runs]}}
      else
        {:error, _error} = error -> {:halt, error}
      end
    end)
  end

  defp maybe_enqueue_run(%{status: :queued} = run) do
    run.id
    |> then(&Skopos.Audits.AuditRun.Worker.new(%{"audit_run_id" => &1}))
    |> Oban.insert()
  end

  defp maybe_enqueue_run(_run), do: {:ok, :not_enqueued}

  defp next_run(schedule, scheduled_for) do
    now = DateTime.utc_now()
    after_time = if DateTime.compare(now, scheduled_for) == :lt, do: scheduled_for, else: now
    Scheduling.next_run(schedule.cron_expression, schedule.timezone, after_time)
  end

  defp enqueue_next(schedule) do
    schedule
    |> Skopos.Audits.AuditSchedule.WakeWorker.job()
    |> Oban.insert()
  end
end
