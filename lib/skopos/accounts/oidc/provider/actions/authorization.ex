defmodule Skopos.Accounts.OIDC.Provider.Actions.Authorization do
  use Ash.Resource.Actions.Implementation

  require Ash.Query

  alias Skopos.Accounts
  alias Skopos.Accounts.{User, UserIdentity}
  alias Skopos.Accounts.OIDC.Client
  alias Skopos.Accounts.OIDC.Provider, as: OIDCProvider
  alias Skopos.Accounts.OIDC.Request, as: OIDCRequest

  @strategy "oidc"

  @impl true
  def run(%{action: %{name: :begin_authorization}, arguments: arguments}, _opts, _context) do
    with {:ok, provider} <- current_provider(arguments.provider_revision),
         :ok <- validate_link_request(arguments.request_id, arguments.start_token),
         browser_binding <- OIDCRequest.random_secret(),
         {:ok, started} <- Client.start(provider, browser_binding, arguments.callback_uri),
         {:ok, request_id} <-
           begin_link_request(arguments.request_id, arguments.start_token, browser_binding) do
      {:ok,
       %{
         url: started.url,
         browser_binding: browser_binding,
         provider_revision: provider.revision,
         expires_in: started.expires_in,
         request_id: request_id
       }}
    end
  end

  def run(%{action: %{name: :complete_authorization}, arguments: arguments}, _opts, _context) do
    with {:ok, provider} <- current_provider(arguments.provider_revision),
         {:ok, completed} <-
           Client.callback(provider, arguments.params, arguments.browser_binding),
         {:ok, subject} <- subject(completed.id_token_claims),
         {:ok, user, linked?} <-
           resolve_user(subject, arguments.request_id, arguments.browser_binding),
         {:ok, token, _claims} <- AshAuthentication.Jwt.token_for_user(user, %{}) do
      {:ok, %{session: %{token: token, user: user}, linked?: linked?}}
    end
  end

  def run(_input, _opts, _context), do: {:error, "OIDC authorization is unavailable"}

  defp current_provider(expected_revision) do
    query =
      OIDCProvider
      |> Ash.Query.for_read(:current)
      |> Ash.Query.load(:client_secret)

    with {:ok, %OIDCProvider{enabled: true} = provider} <-
           Ash.read_one(query, domain: Accounts, authorize?: false),
         true <- is_nil(expected_revision) or provider.revision == expected_revision do
      {:ok, provider}
    else
      _error -> {:error, :oidc_unavailable}
    end
  end

  defp validate_link_request(nil, nil), do: :ok

  defp validate_link_request(id, token) when is_binary(id) and is_binary(token) do
    with {:ok, %OIDCRequest{purpose: :link} = request} <- fetch_request(id),
         true <- link_startable?(request, token) do
      :ok
    else
      _error -> {:error, :invalid_link_request}
    end
  end

  defp validate_link_request(_id, _token), do: {:error, :invalid_link_request}

  defp begin_link_request(nil, nil, _browser_binding), do: {:ok, nil}

  defp begin_link_request(id, token, browser_binding) do
    Ash.transact(OIDCRequest, fn ->
      with {:ok, %OIDCRequest{purpose: :link} = request} <- locked_request(id),
           true <- link_startable?(request, token),
           {:ok, _started} <-
             update_request(request, :start, %{
               expected_revision: request.revision,
               start_token: token,
               browser_binding_digest: OIDCRequest.digest(browser_binding)
             }) do
        id
      else
        _error -> {:error, :invalid_link_request}
      end
    end)
  end

  defp resolve_user(subject, nil, _browser_binding) do
    with {:ok, %UserIdentity{} = identity} <- identity_by_subject(subject),
         {:ok, %User{} = user} <- Ash.get(User, identity.user_id, authorize?: false) do
      {:ok, user, false}
    else
      _error -> {:error, :unknown_oidc_identity}
    end
  end

  defp resolve_user(subject, request_id, browser_binding)
       when is_binary(request_id) and is_binary(browser_binding) do
    case Ash.transact([OIDCRequest, UserIdentity, User], fn ->
           with {:ok, %OIDCRequest{purpose: :link} = request} <- locked_request(request_id),
                true <- active_link?(request, browser_binding),
                {:ok, identity} <- create_identity(request.user_id, subject),
                true <- identity.user_id == request.user_id,
                {:ok, _completed} <-
                  update_request(request, :complete, %{
                    expected_revision: request.revision,
                    user_id: request.user_id,
                    code_digest: nil
                  }),
                {:ok, %User{} = user} <- Ash.get(User, request.user_id, authorize?: false) do
             user
           else
             _error -> {:error, :invalid_link_request}
           end
         end) do
      {:ok, %User{} = user} -> {:ok, user, true}
      {:error, error} -> {:error, error}
    end
  end

  defp resolve_user(_subject, _request_id, _browser_binding),
    do: {:error, :invalid_link_request}

  defp create_identity(user_id, subject) do
    UserIdentity
    |> Ash.Changeset.for_create(
      :link,
      %{strategy: @strategy, uid: subject, user_id: user_id},
      authorize?: false
    )
    |> Ash.create(domain: Accounts, authorize?: false)
  end

  defp identity_by_subject(subject) do
    UserIdentity
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(strategy == @strategy and uid == ^subject)
    |> Ash.read_one(domain: Accounts, authorize?: false)
  end

  defp subject(%{"sub" => subject}) when is_binary(subject) and subject != "", do: {:ok, subject}
  defp subject(_claims), do: {:error, :invalid_subject}

  defp fetch_request(id) do
    OIDCRequest
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(id == ^id)
    |> Ash.read_one(domain: Accounts, authorize?: false)
  end

  defp locked_request(id) do
    OIDCRequest
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(id == ^id)
    |> Ash.Query.lock(:for_update)
    |> Ash.read_one(domain: Accounts, authorize?: false)
  end

  defp update_request(request, action, arguments) do
    request
    |> Ash.Changeset.for_update(action, arguments, authorize?: false)
    |> Ash.update(domain: Accounts, authorize?: false)
  end

  defp link_startable?(request, token) do
    is_nil(request.started_at) and is_nil(request.completed_at) and
      DateTime.compare(request.expires_at, DateTime.utc_now()) == :gt and
      OIDCRequest.digest_matches?(request.start_token_digest, token)
  end

  defp active_link?(request, browser_binding) do
    request.started_at && is_nil(request.completed_at) &&
      DateTime.compare(request.expires_at, DateTime.utc_now()) == :gt &&
      OIDCRequest.digest_matches?(request.browser_binding_digest, browser_binding)
  end
end
