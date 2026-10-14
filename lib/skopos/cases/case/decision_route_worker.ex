defmodule Skopos.Cases.Case.DecisionRouteWorker do
  @moduledoc false

  use Oban.Worker,
    queue: :resolver,
    max_attempts: 3,
    unique: [period: :infinity, fields: [:worker, :queue, :args], states: :all]

  alias Skopos.Cases

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"turn_id" => turn_id}}) when is_binary(turn_id) do
    case Cases.route_resolver_decision(turn_id, authorize?: false) do
      {:ok, %{status: :completed}} -> :ok
      {:ok, %{status: :cancelled, reason: reason}} -> {:cancel, reason}
      {:error, _error} = error -> error
    end
  end

  def perform(_job), do: {:cancel, "Resolver decision route arguments are invalid"}
end
