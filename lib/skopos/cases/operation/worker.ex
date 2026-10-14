defmodule Skopos.Cases.Operation.Worker do
  @moduledoc false

  use Oban.Worker,
    queue: :operations,
    max_attempts: 3,
    unique: [period: :infinity, fields: [:worker, :queue, :args], states: :all]

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"operation_id" => operation_id}}) when is_binary(operation_id),
    do: Skopos.Cases.Operation.Delivery.run(operation_id)

  def perform(_job), do: {:cancel, "Operation job arguments are invalid"}
end
