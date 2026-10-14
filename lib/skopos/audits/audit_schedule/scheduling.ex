defmodule Skopos.Audits.AuditSchedule.Scheduling do
  @moduledoc false

  alias Crontab.CronExpression
  alias Crontab.CronExpression.Parser
  alias Crontab.Scheduler

  @spec next_run(String.t(), String.t(), DateTime.t()) ::
          {:ok, DateTime.t()} | {:error, String.t()}
  def next_run(expression, timezone, %DateTime{} = after_utc) do
    with {:ok, cron} <- parse(expression),
         {:ok, local_after} <- shift_zone(after_utc, timezone),
         {:ok, local_next} <- next_date(cron, local_after),
         {:ok, utc_next} <- shift_zone(local_next, "Etc/UTC") do
      {:ok, utc_next}
    end
  end

  defp parse(expression) do
    case Parser.parse(expression, false, [:prior]) do
      {:ok, %CronExpression{reboot: true}} ->
        {:error, "Audit schedules do not support @reboot"}

      {:ok, %CronExpression{} = cron} ->
        {:ok, cron}

      {:error, _error} ->
        {:error, "Cron expression is invalid"}
    end
  end

  defp shift_zone(datetime, timezone) do
    case DateTime.shift_zone(datetime, timezone) do
      {:ok, shifted} -> {:ok, shifted}
      {:error, _reason} -> {:error, "Timezone is invalid"}
    end
  end

  defp next_date(cron, local_after) do
    case Scheduler.get_next_run_date(cron, local_after) do
      {:ok, next} ->
        if DateTime.compare(next, local_after) == :gt do
          {:ok, next}
        else
          Scheduler.get_next_run_date(cron, DateTime.add(local_after, 1, :second))
        end

      {:error, _error} ->
        {:error, "Cron expression has no next run time"}
    end
  rescue
    _error -> {:error, "Cron expression has no next run time"}
  end
end
