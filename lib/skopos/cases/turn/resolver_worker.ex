defmodule Skopos.Cases.Turn.ResolverWorker do
  @moduledoc false

  use Oban.Worker,
    queue: :resolver,
    max_attempts: 3,
    unique: [period: :infinity, fields: [:worker, :queue, :args], states: :all]

  alias Skopos.Cases.Turn.ResolverDelivery, as: ResolverDelivery

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"turn_id" => turn_id}}) when is_binary(turn_id) do
    ResolverDelivery.run(turn_id)
  end

  def perform(_job), do: {:cancel, "Resolver job arguments are invalid"}
end
