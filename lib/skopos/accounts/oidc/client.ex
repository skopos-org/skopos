defmodule Skopos.Accounts.OIDC.Client do
  @moduledoc false

  alias AttestoClient.AuthorizationCode
  alias AttestoClient.AuthorizationTransaction.Store.ETS

  @transaction_store Skopos.OIDCTransactions

  def child_spec do
    {ETS, name: @transaction_store, max_entries: 10_000}
  end

  def start(
        %{issuer: issuer, client_id: client_id, id_token_alg: id_token_alg},
        browser_binding,
        callback_uri
      )
      when is_binary(browser_binding) and is_binary(callback_uri) do
    AuthorizationCode.start(store(),
      issuer: issuer,
      client_id: client_id,
      browser_binding: browser_binding,
      redirect_uri: callback_uri,
      scopes: ["openid", "profile", "email"],
      id_token_alg: id_token_alg,
      req_options: req_options()
    )
  end

  def callback(%{client_secret: client_secret}, params, browser_binding)
      when is_map(params) and is_binary(browser_binding) do
    AuthorizationCode.callback(store(), params,
      browser_binding: browser_binding,
      client_auth: {:client_secret_basic, client_secret},
      req_options: req_options()
    )
  end

  defp store, do: {ETS, @transaction_store}

  defp req_options do
    Application.get_env(:skopos, __MODULE__, [])
    |> Keyword.get(:req_options, [])
  end
end
