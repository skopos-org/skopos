defmodule Skopos.Cases.Case.RecoveryRecheckWorker do
  @moduledoc false

  use Oban.Worker,
    queue: :resolver,
    max_attempts: 30,
    unique: [
      period: 60,
      fields: [:worker, :queue, :args],
      states: [:available, :scheduled, :executing]
    ]

  alias Skopos.Cases

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"case_id" => case_id}}) when is_binary(case_id) do
    case Cases.recheck_signal_conditions(case_id, authorize?: false) do
      {:ok, %{status: :busy}} -> {:snooze, 5}
      {:ok, %{status: status}} when status in [:started, :skipped] -> :ok
      {:error, _reason} = error -> error
    end
  end

  def perform(_job), do: {:cancel, "Signal recovery recheck arguments are invalid"}
end
