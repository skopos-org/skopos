defmodule Skopos.Accounts.OIDC.Provider.Configure do
  use Ash.Resource.Actions.Implementation

  alias Skopos.Accounts.UserIdentity
  alias Skopos.Accounts.OIDC.Provider, as: OIDCProvider

  @impl true
  def run(input, _options, context) do
    with {:ok, issuer} <- normalize_issuer(input.arguments.issuer),
         {:ok, client_id} <- nonempty(input.arguments.client_id, :client_id),
         {:ok, client_secret} <- nonempty(input.arguments.client_secret, :client_secret),
         {:ok, id_token_alg} <- signing_algorithm(input.arguments.id_token_alg),
         {:ok, current} <- current_provider(),
         :ok <- permit_identity_change(current, issuer, client_id) do
      attributes = %{
        issuer: issuer,
        client_id: client_id,
        client_secret: client_secret,
        id_token_alg: id_token_alg,
        enabled: input.arguments.enabled
      }

      persist(current, attributes, context)
    end
  end

  defp current_provider do
    case Ash.read_one(OIDCProvider, action: :current, authorize?: false) do
      {:ok, provider} -> {:ok, provider}
      {:error, error} -> {:error, error}
    end
  end

  defp persist(nil, attributes, context) do
    OIDCProvider
    |> Ash.Changeset.for_create(:create_configuration, attributes,
      actor: context.actor,
      authorize?: false
    )
    |> Ash.create(domain: Skopos.Accounts, authorize?: false)
  end

  defp persist(provider, attributes, context) do
    provider
    |> Ash.Changeset.for_update(
      :update_configuration,
      Map.put(attributes, :expected_revision, provider.revision),
      actor: context.actor,
      authorize?: false
    )
    |> Ash.update(domain: Skopos.Accounts, authorize?: false)
  end

  defp permit_identity_change(nil, _issuer, _client_id), do: :ok

  defp permit_identity_change(provider, issuer, client_id) do
    if provider.issuer == issuer and provider.client_id == client_id do
      :ok
    else
      case Ash.count(UserIdentity, authorize?: false) do
        {:ok, 0} ->
          :ok

        {:ok, _count} ->
          {:error, "issuer and client_id cannot change after an identity is linked"}

        {:error, error} ->
          {:error, error}
      end
    end
  end

  defp normalize_issuer(value) do
    value = String.trim(value)
    uri = URI.parse(value)

    cond do
      uri.userinfo || uri.query || uri.fragment ->
        {:error, "issuer must not include credentials, query, or fragment"}

      uri.scheme == "https" and is_binary(uri.host) and uri.host != "" ->
        {:ok, value}

      true ->
        {:error, "issuer must be HTTPS"}
    end
  end

  defp nonempty(value, field) do
    case String.trim(value) do
      "" -> {:error, "#{field} must not be empty"}
      value -> {:ok, value}
    end
  end

  defp signing_algorithm(value) do
    with {:ok, value} <- nonempty(value, :id_token_alg),
         true <- value in Attesto.SigningAlg.allowed() do
      {:ok, value}
    else
      _invalid -> {:error, "id_token_alg is not supported"}
    end
  end
end
