defmodule Skopos.Accounts.OIDC.Request.Actions.Flow do
  use Ash.Resource.Actions.Implementation

  require Ash.Query

  alias Skopos.Accounts
  alias Skopos.Accounts.OIDC.Request, as: OIDCRequest
  alias Skopos.Accounts.User

  @request_lifetime_seconds 600

  @impl true
  def run(%{action: %{name: :request_link}}, _opts, %{actor: %User{} = actor}) do
    with true <- Accounts.oidc_available?(),
         start_token <- OIDCRequest.random_secret(),
         {:ok, request} <-
           create(:create_link, %{
             user_id: actor.id,
             start_token_digest: OIDCRequest.digest(start_token),
             expires_at: expires_at()
           }) do
      {:ok, %{request: request, start_token: start_token}}
    else
      false -> {:error, :oidc_unavailable}
      error -> error
    end
  end

  def run(%{action: %{name: :request_cli_login}, arguments: arguments}, _opts, _context) do
    with :ok <- validate_loopback_redirect(arguments.redirect_uri),
         {:ok, verifier_digest} <- decode_challenge(arguments.code_challenge),
         start_token <- OIDCRequest.random_secret(),
         {:ok, request} <-
           create(:create_cli_login, %{
             start_token_digest: OIDCRequest.digest(start_token),
             verifier_digest: verifier_digest,
             redirect_uri: arguments.redirect_uri,
             expires_at: expires_at()
           }) do
      {:ok, %{request: request, start_token: start_token}}
    end
  end

  def run(
        %{action: %{name: :approve_cli_login}, arguments: arguments},
        _opts,
        %{actor: %User{} = actor}
      ) do
    code = OIDCRequest.random_secret()

    Ash.transact(OIDCRequest, fn ->
      with {:ok, %OIDCRequest{purpose: :cli_login} = request} <- locked(arguments.id),
           {:ok, started} <-
             update(request, :start, %{
               expected_revision: request.revision,
               start_token: arguments.start_token
             }),
           {:ok, completed} <-
             update(started, :complete, %{
               expected_revision: started.revision,
               user_id: actor.id,
               code_digest: OIDCRequest.digest(code)
             }) do
        %{request: completed, code: code, user: actor}
      else
        {:ok, _request} -> {:error, "CLI login request is invalid"}
        error -> error
      end
    end)
  end

  def run(
        %{action: %{name: :deny_cli_login}, arguments: arguments},
        _opts,
        %{actor: %User{}}
      ) do
    Ash.transact(OIDCRequest, fn ->
      with {:ok, %OIDCRequest{purpose: :cli_login} = request} <- locked(arguments.id),
           {:ok, started} <-
             update(request, :start, %{
               expected_revision: request.revision,
               start_token: arguments.start_token
             }) do
        started
      else
        {:ok, _request} -> {:error, "CLI login request is invalid"}
        error -> error
      end
    end)
  end

  def run(%{action: %{name: :exchange_cli_login}, arguments: arguments}, _opts, _context) do
    Ash.transact([OIDCRequest, User], fn ->
      with {:ok, %OIDCRequest{purpose: :cli_login} = request} <- locked(arguments.id),
           {:ok, consumed} <-
             update(request, :consume, %{
               expected_revision: request.revision,
               code: arguments.code,
               verifier: arguments.verifier
             }),
           {:ok, %User{} = user} <- Ash.get(User, consumed.user_id, authorize?: false),
           {:ok, token, _claims} <- AshAuthentication.Jwt.token_for_user(user, %{}) do
        %{token: token, user: user}
      else
        {:ok, _request} -> {:error, "CLI login request is invalid"}
        error -> error
      end
    end)
  end

  def run(_input, _opts, _context), do: {:error, "OIDC request action is unavailable"}

  defp create(action, attributes) do
    OIDCRequest
    |> Ash.Changeset.for_create(action, attributes, authorize?: false)
    |> Ash.create(domain: Accounts, authorize?: false)
  end

  defp update(request, action, arguments) do
    request
    |> Ash.Changeset.for_update(action, arguments, authorize?: false)
    |> Ash.update(domain: Accounts, authorize?: false)
  end

  defp locked(id) do
    OIDCRequest
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(id: id)
    |> Ash.Query.lock(:for_update)
    |> Ash.read_one(authorize?: false)
  end

  defp expires_at do
    DateTime.utc_now()
    |> DateTime.add(@request_lifetime_seconds, :second)
    |> DateTime.truncate(:microsecond)
  end

  defp decode_challenge(value) when is_binary(value) do
    case Base.url_decode64(value, padding: false) do
      {:ok, digest} when byte_size(digest) == 32 -> {:ok, digest}
      _other -> {:error, :invalid_challenge}
    end
  end

  defp decode_challenge(_value), do: {:error, :invalid_challenge}

  defp validate_loopback_redirect(value) when is_binary(value) do
    uri = URI.parse(value)

    if uri.scheme == "http" and uri.host in ["127.0.0.1", "localhost", "::1"] and
         is_integer(uri.port) and uri.port > 0 and uri.path == "/callback" and
         is_nil(uri.userinfo) and is_nil(uri.query) and is_nil(uri.fragment) do
      :ok
    else
      {:error, :invalid_redirect}
    end
  end

  defp validate_loopback_redirect(_value), do: {:error, :invalid_redirect}
end
