defmodule Skopos.Reports.Report.GenerationWorker do
  @moduledoc false

  use Oban.Worker,
    queue: :resolver,
    max_attempts: 3,
    unique: [period: :infinity, fields: [:worker, :queue, :args], states: :all]

  alias Skopos.Cases
  alias Skopos.Reports

  @impl Oban.Worker
  def perform(
        %Oban.Job{
          args: %{"case_id" => case_id, "case_revision" => case_revision},
          meta: %{"snoozed" => count}
        } = job
      )
      when is_binary(case_id) and is_integer(case_revision) and case_revision > 0 and
             is_integer(count) and count > 0 do
    record_failure(job, case_id, case_revision, nil)
  end

  @impl Oban.Worker
  def perform(
        %Oban.Job{
          args: %{"case_id" => case_id, "case_revision" => case_revision},
          attempt: attempt,
          max_attempts: max_attempts
        } = job
      )
      when is_binary(case_id) and is_integer(case_revision) and case_revision > 0 do
    result =
      with {:ok, setting} <- Reports.current_setting(authorize?: false) do
        if setting.automatic_case_reports_enabled do
          Reports.generate_report(case_id, case_revision, authorize?: false)
        else
          {:ok, :disabled}
        end
      end

    case result do
      {:ok, _report_or_disabled} ->
        :ok

      {:error, error} when attempt >= max_attempts ->
        record_failure(job, case_id, case_revision, error)

      {:error, error} ->
        {:error, error}
    end
  end

  def perform(_job), do: {:cancel, "Report generation job arguments are invalid"}

  defp record_failure(job, case_id, case_revision, report_error) do
    case Cases.record_report_generation_failure(case_id, case_revision, authorize?: false) do
      {:ok, _event} when is_nil(report_error) -> :ok
      {:ok, _event} -> {:error, report_error}
      {:error, _event_error} -> {:snooze, failure_retry_delay(job)}
    end
  end

  defp failure_retry_delay(%Oban.Job{meta: meta}) do
    count = Map.get(meta || %{}, "snoozed", 0)
    min(30 * Integer.pow(2, min(count, 7)), 3600)
  end
end
