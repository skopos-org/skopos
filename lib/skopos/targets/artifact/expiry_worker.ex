defmodule Skopos.Targets.Artifact.ExpiryWorker do
  @moduledoc false

  use Oban.Worker, queue: :operations, max_attempts: 10

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"id" => id}}) do
    case Skopos.Targets.expire_artifact(id, authorize?: false) do
      {:ok, %{status: status}} when status in [:expired, :revoked] ->
        :ok

      {:ok, artifact} ->
        {:snooze, max(1, DateTime.diff(artifact.expires_at, DateTime.utc_now(), :second))}

      {:error, error} ->
        {:error, error}
    end
  end
end
