defmodule Skopos.Application do
  # See https://elixir.hexdocs.pm/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = server_children()

    # See https://elixir.hexdocs.pm/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Skopos.Supervisor]
    Supervisor.start_link(children, opts)
  end

  defp server_children do
    [
      SkoposWeb.Telemetry,
      Skopos.Repo,
      {Oban, Application.fetch_env!(:skopos, Oban)},
      Skopos.Vault,
      {Finch, name: Skopos.Transports.HTTP},
      Skopos.Accounts.OIDC.Client.child_spec(),
      {DNSCluster, query: Application.get_env(:skopos, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: Skopos.PubSub},
      SkoposWeb.Endpoint
    ]
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    SkoposWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
