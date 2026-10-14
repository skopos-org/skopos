defmodule Skopos.Accounts.OIDC.Provider.Available do
  use Ash.Resource.Actions.Implementation

  alias Skopos.Accounts.OIDC.Provider, as: OIDCProvider

  @impl true
  def run(_input, _opts, _context) do
    case Ash.read_one(OIDCProvider, action: :current, authorize?: false) do
      {:ok, %OIDCProvider{enabled: true}} -> {:ok, true}
      {:ok, _provider} -> {:ok, false}
      {:error, _error} -> {:ok, false}
    end
  end
end
