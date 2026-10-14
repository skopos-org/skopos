defmodule SkoposCLI.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    Supervisor.start_link(
      [{Task, fn -> System.halt(SkoposCLI.CLI.run(Burrito.Util.Args.argv())) end}],
      strategy: :one_for_one,
      name: SkoposCLI.Supervisor
    )
  end
end
