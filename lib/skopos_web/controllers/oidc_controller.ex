defmodule SkoposWeb.OIDCController do
  use SkoposWeb, :controller

  alias Skopos.Accounts
  alias Skopos.Accounts.OIDC.Request, as: OIDCRequest
  alias SkoposWeb.API.V1.AccountJSON
  alias SkoposWeb.PublicURL

  @binding_key :skopos_oidc_browser_binding
  @provider_revision_key :skopos_oidc_provider_revision
  @request_id_key :skopos_oidc_request_id

  def start(conn, _params) do
    begin_authorization(conn, nil, nil)
  end

  def start_link(conn, %{"id" => id, "token" => token}) do
    begin_authorization(conn, id, token)
  end

  def start_link(conn, _params), do: browser_error(conn)

  def callback(conn, params) do
    with browser_binding when is_binary(browser_binding) <- get_session(conn, @binding_key),
         provider_revision when is_integer(provider_revision) <-
           get_session(conn, @provider_revision_key),
         {:ok, %{session: session, linked?: linked?}} <-
           Accounts.complete_oidc_authorization(
             params,
             browser_binding,
             provider_revision,
             get_session(conn, @request_id_key)
           ) do
      type = if linked?, do: "skopos:oidc-linked", else: "skopos:oidc-session"

      conn
      |> clear_authorization_session()
      |> browser_result(%{
        type: type,
        token: session.token,
        account: AccountJSON.data(session.user)
      })
    else
      _error -> browser_error(conn)
    end
  end

  defp begin_authorization(conn, request_id, start_token) do
    with {:ok, authorization} when is_map(authorization) <-
           Accounts.begin_oidc_authorization(
             request_id,
             start_token,
             nil,
             PublicURL.oidc_callback_uri()
           ) do
      conn
      |> protect_response()
      |> configure_session(renew: true)
      |> put_session(@binding_key, authorization.browser_binding)
      |> put_session(@provider_revision_key, authorization.provider_revision)
      |> maybe_put_request_id(authorization.request_id)
      |> redirect(external: authorization.url)
    else
      _error -> browser_error(conn)
    end
  end

  defp maybe_put_request_id(conn, nil), do: delete_session(conn, @request_id_key)
  defp maybe_put_request_id(conn, request_id), do: put_session(conn, @request_id_key, request_id)

  defp browser_error(conn) do
    conn
    |> clear_authorization_session()
    |> browser_result(%{type: "skopos:oidc-error"})
  end

  defp clear_authorization_session(conn) do
    conn
    |> delete_session(@binding_key)
    |> delete_session(@provider_revision_key)
    |> delete_session(@request_id_key)
  end

  defp browser_result(conn, payload) do
    nonce = OIDCRequest.random_secret(18)
    encoded = Jason.encode!(payload, escape: :html_safe)

    html = """
    <!doctype html><meta charset="utf-8"><title>Skopos</title>
    <script nonce="#{nonce}">
      if (window.opener) window.opener.postMessage(#{encoded}, window.location.origin);
      window.close();
    </script>
    """

    conn
    |> protect_response()
    |> put_resp_content_type("text/html")
    |> put_resp_header(
      "content-security-policy",
      "default-src 'none'; script-src 'nonce-#{nonce}'"
    )
    |> send_resp(:ok, html)
  end

  defp protect_response(conn) do
    conn
    |> put_resp_header("cache-control", "no-store")
    |> put_resp_header("referrer-policy", "no-referrer")
  end
end
