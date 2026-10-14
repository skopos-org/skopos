defmodule Skopos.Audits.AuditSchedule.Actions.Create do
  use Ash.Resource.Actions.Implementation
  require Ash.Query

  alias Skopos.Audits
  alias Skopos.Audits.AuditSchedule
  alias Skopos.Audits.AuditSchedule.Scheduling
  alias Skopos.Cases.Case.Symptom, as: CaseSymptom
  alias Skopos.Targets.{ManagementBoundary, Target}

  @impl true
  def run(input, _opts, _context) do
    arguments = normalize(input.arguments)
    now = DateTime.utc_now()

    result =
      with :ok <- validate_desired_outcome(arguments),
           :ok <- validate_scope(arguments),
           {:ok, next_run_at} <-
             Scheduling.next_run(arguments.cron_expression, arguments.timezone, now) do
        Ash.transact([AuditSchedule, ManagementBoundary, Target], fn ->
          with :ok <- validate_scope_records(arguments),
               {:ok, schedule} <- create_record(arguments, next_run_at),
               {:ok, _job} <- enqueue(schedule) do
            schedule
          end
        end)
      end

    case result do
      {:error, message} when is_binary(message) ->
        {:error, Ash.Error.Changes.InvalidAttribute.exception(field: :schedule, message: message)}

      other ->
        other
    end
  end

  defp normalize(arguments) do
    %{arguments | target_ids: arguments.target_ids |> Enum.uniq() |> Enum.sort()}
  end

  defp validate_desired_outcome(arguments) do
    if CaseSymptom.valid_desired_outcome?(arguments.objective),
      do: :ok,
      else:
        {:error,
         Ash.Error.Changes.InvalidAttribute.exception(
           field: :desired_outcome,
           message: "Audit schedule requires a desired_outcome"
         )}
  end

  defp validate_scope(%{target_ids: [_ | _], management_boundary_id: nil}), do: :ok
  defp validate_scope(%{target_ids: [], management_boundary_id: id}) when is_binary(id), do: :ok

  defp validate_scope(_arguments),
    do: {:error, "Select Target IDs or one management boundary"}

  defp validate_scope_records(%{target_ids: [_ | _] = ids}) do
    Target
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(id in ^ids)
    |> Ash.read(authorize?: false)
    |> case do
      {:ok, targets} when length(targets) == length(ids) ->
        if Enum.all?(targets, & &1.active),
          do: :ok,
          else: invalid_scope("Audit Target is inactive")

      {:ok, _targets} ->
        invalid_scope("Audit Target is unavailable")

      {:error, _error} = error ->
        error
    end
  end

  defp validate_scope_records(%{management_boundary_id: id}) do
    ManagementBoundary
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(id: id)
    |> Ash.Query.lock(:for_update)
    |> Ash.read_one(authorize?: false)
    |> case do
      {:ok, %{active: true}} -> :ok
      {:ok, nil} -> invalid_scope("Management boundary is unavailable")
      {:ok, _boundary} -> invalid_scope("Management boundary is inactive")
      {:error, _error} = error -> error
    end
  end

  defp invalid_scope(message) do
    {:error, Ash.Error.Changes.InvalidAttribute.exception(field: :schedule, message: message)}
  end

  defp create_record(arguments, next_run_at) do
    Audits.create_audit_schedule_record(
      %{
        registration_id: arguments.registration_id,
        name: arguments.name,
        objective: arguments.objective,
        timezone: arguments.timezone,
        cron_expression: arguments.cron_expression,
        report_language: arguments.report_language,
        target_ids: arguments.target_ids,
        management_boundary_id: arguments.management_boundary_id,
        active: true,
        next_run_at: next_run_at
      },
      authorize?: false
    )
  end

  defp enqueue(schedule) do
    result =
      schedule
      |> Skopos.Audits.AuditSchedule.WakeWorker.job()
      |> Oban.insert(retry: false, on_exhausted: :log)

    case result do
      {:ok, %Oban.Job{id: id} = job} when is_integer(id) -> {:ok, job}
      {:ok, _unsaved_job} -> {:error, :audit_wake_job_not_saved}
      {:error, _error} = error -> error
    end
  end
end
