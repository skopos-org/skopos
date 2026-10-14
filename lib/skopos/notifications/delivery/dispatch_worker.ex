defmodule Skopos.Notifications.Delivery.DispatchWorker do
  @moduledoc false

  use Oban.Worker,
    queue: :notifications,
    max_attempts: 3,
    unique: [period: :infinity, fields: [:worker, :queue, :args], states: :all]

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"delivery_id" => delivery_id}}) when is_binary(delivery_id) do
    case Skopos.Notifications.Delivery.Dispatch.run(delivery_id) do
      {:ok, _delivery} -> :ok
      {:error, error} -> {:error, error}
    end
  end

  def perform(_job), do: {:cancel, "Notification Delivery job arguments are invalid"}
end
