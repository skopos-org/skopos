defmodule Skopos.Audits.AuditSchedule.WakeWorker do
  @moduledoc false

  use Oban.Worker,
    queue: :audits,
    max_attempts: 5,
    unique: [period: :infinity, fields: [:worker, :queue, :args], states: :all]

  alias Skopos.Audits
  alias Skopos.Audits.AuditSchedule

  def job(%AuditSchedule{} = schedule) do
    new(
      %{
        "audit_schedule_id" => schedule.id,
        "schedule_revision" => schedule.revision,
        "scheduled_for" => DateTime.to_iso8601(schedule.next_run_at)
      },
      scheduled_at: schedule.next_run_at
    )
  end

  @impl Oban.Worker
  def perform(%Oban.Job{
        args: %{
          "audit_schedule_id" => id,
          "schedule_revision" => revision,
          "scheduled_for" => scheduled_for
        }
      })
      when is_binary(id) and is_integer(revision) and is_binary(scheduled_for) do
    with {:ok, datetime} <- parse_time(scheduled_for),
         {:ok, _schedule} <-
           Audits.wake_audit_schedule(id, revision, datetime, authorize?: false) do
      :ok
    else
      {:error, :invalid_time} -> {:cancel, "Audit wake time is invalid"}
      {:error, error} -> {:error, error}
    end
  end

  def perform(_job), do: {:cancel, "Audit wake job arguments are invalid"}

  defp parse_time(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, 0} -> {:ok, datetime}
      _invalid -> {:error, :invalid_time}
    end
  end
end
