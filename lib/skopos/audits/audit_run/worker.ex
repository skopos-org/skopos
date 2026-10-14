defmodule Skopos.Audits.AuditRun.Worker do
  @moduledoc false

  use Oban.Worker,
    queue: :audits,
    max_attempts: 3,
    unique: [period: :infinity, fields: [:worker, :queue, :args], states: :all]

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"audit_run_id" => id}} = job) when is_binary(id) do
    case Skopos.Audits.AuditRun.Dispatch.run(id, final_attempt?: job.attempt >= job.max_attempts) do
      {:ok, _run} ->
        :ok

      {:error, _error} when job.attempt >= job.max_attempts ->
        {:snooze, retry_delay(job)}

      {:error, error} ->
        {:error, error}
    end
  end

  def perform(_job), do: {:cancel, "Audit Run job arguments are invalid"}

  defp retry_delay(%Oban.Job{meta: meta}) do
    count = Map.get(meta || %{}, "snoozed", 0)
    min(30 * Integer.pow(2, min(count, 7)), 3600)
  end
end
