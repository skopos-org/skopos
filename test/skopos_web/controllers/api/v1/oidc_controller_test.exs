defmodule SkoposWeb.API.V1.OIDCControllerTest do
  use SkoposWeb.ConnCase, async: false

  import OpenApiSpex.TestAssertions

  alias Skopos.Accounts
  alias Skopos.Accounts.UserIdentity

  @issuer "https://identity.example.test/realms/skopos"
  @stub __MODULE__.Provider
  @password "correct horse battery staple"

  setup do
    Req.Test.set_req_test_to_shared()
    previous = Application.get_env(:skopos, Skopos.Accounts.OIDC.Client)

    Application.put_env(:skopos, Skopos.Accounts.OIDC.Client,
      req_options: [plug: {Req.Test, @stub}]
    )

    key =
      {:rsa, 2048}
      |> JOSE.JWK.generate_key()
      |> JOSE.JWK.merge(%{"alg" => "RS256", "kid" => "browser-test", "use" => "sig"})

    {_, public_key} = key |> JOSE.JWK.to_public() |> JOSE.JWK.to_map()
    {:ok, response} = Agent.start_link(fn -> nil end)

    Req.Test.stub(@stub, fn conn ->
      case conn.request_path do
        "/realms/skopos/.well-known/openid-configuration" ->
          Req.Test.json(conn, %{
            "issuer" => @issuer,
            "authorization_endpoint" => @issuer <> "/authorize",
            "token_endpoint" => @issuer <> "/token",
            "jwks_uri" => @issuer <> "/jwks",
            "response_types_supported" => ["code"],
            "subject_types_supported" => ["public"],
            "id_token_signing_alg_values_supported" => ["RS256"],
            "code_challenge_methods_supported" => ["S256"]
          })

        "/realms/skopos/jwks" ->
          Req.Test.json(conn, %{"keys" => [public_key]})

        "/realms/skopos/token" ->
          Req.Test.json(conn, Agent.get(response, & &1))
      end
    end)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:skopos, Skopos.Accounts.OIDC.Client, previous),
        else: Application.delete_env(:skopos, Skopos.Accounts.OIDC.Client)

      Req.Test.set_req_test_to_private()
    end)

    %{key: key, response: response}
  end

  test "admin configures optional OIDC without exposing its secret" do
    token = bootstrap_and_sign_in!()

    provider = get_json("/api/v1/oidc/provider", token)

    assert %{
             "data" => %{
               "enabled" => false,
               "callback_uri" => "http://localhost:4000/auth/user/oidc/callback"
             }
           } = json_response(provider, 200)

    assert_operation_response(provider)

    configured =
      put_json(
        "/api/v1/oidc/provider",
        %{
          "oidc_provider" => %{
            "issuer" => "https://identity.example.test/realms/skopos",
            "client_id" => "skopos",
            "client_secret" => "do-not-return",
            "id_token_alg" => "PS256",
            "enabled" => true
          }
        },
        token
      )

    assert %{
             "data" => %{
               "issuer" => "https://identity.example.test/realms/skopos",
               "client_id" => "skopos",
               "id_token_alg" => "PS256",
               "enabled" => true
             }
           } = json_response(configured, 200)

    assert_operation_response(configured)

    refute configured.resp_body =~ "do-not-return"

    status = get_json("/api/v1/oidc")

    assert %{
             "data" => %{
               "enabled" => true,
               "authorization_url" => authorization_url,
               "callback_uri" => callback_uri
             }
           } = json_response(status, 200)

    assert_operation_response(status)

    assert authorization_url == "http://localhost:4000/auth/user/oidc"
    assert callback_uri == "http://localhost:4000/auth/user/oidc/callback"
  end

  test "a disabled provider cannot be reached through the direct browser route" do
    token = bootstrap_and_sign_in!()
    configure_oidc!(token, false)

    assert %{
             "data" => %{"enabled" => false, "authorization_url" => nil}
           } = get_json("/api/v1/oidc") |> json_response(200)

    response = get(build_conn(), "/auth/user/oidc")
    assert html_response(response, 200) =~ "skopos:oidc-error"
  end

  test "the browser route completes AttestoClient OIDC and returns a local session", context do
    previous_public_url = Application.fetch_env!(:skopos, :public_url)
    Application.put_env(:skopos, :public_url, "https://skopos.example:8443")
    on_exit(fn -> Application.put_env(:skopos, :public_url, previous_public_url) end)

    admin =
      Accounts.bootstrap!(
        "oidc-browser-admin@example.com",
        @password,
        @password,
        authorize?: true
      )

    Accounts.configure_oidc!(
      %{
        issuer: @issuer,
        client_id: "skopos",
        client_secret: "secret",
        id_token_alg: "RS256",
        enabled: true
      },
      actor: admin
    )

    assert %{
             "data" => %{
               "authorization_url" => "https://skopos.example:8443/auth/user/oidc",
               "callback_uri" => "https://skopos.example:8443/auth/user/oidc/callback"
             }
           } = get_json("/api/v1/oidc") |> json_response(200)

    Ash.create!(
      UserIdentity,
      %{strategy: "oidc", uid: "browser-subject", user_id: admin.id},
      action: :link,
      authorize?: false
    )

    started = get(build_conn(), "/auth/user/oidc")
    assert redirected_to(started, 302) =~ @issuer <> "/authorize?"

    query =
      started
      |> redirected_to(302)
      |> URI.parse()
      |> Map.fetch!(:query)
      |> URI.decode_query()

    assert query["redirect_uri"] ==
             "https://skopos.example:8443/auth/user/oidc/callback"

    Agent.update(context.response, fn _current ->
      %{
        "access_token" => "browser-access-token",
        "token_type" => "Bearer",
        "expires_in" => 300,
        "id_token" => id_token(context.key, query["nonce"], "browser-subject")
      }
    end)

    callback =
      started
      |> recycle()
      |> get(
        "/auth/user/oidc/callback?" <>
          URI.encode_query(%{"state" => query["state"], "code" => "code"})
      )

    body = html_response(callback, 200)
    assert body =~ "skopos:oidc-session"
    refute body =~ "skopos:oidc-error"
  end

  defp configure_oidc!(token, enabled) do
    put_json(
      "/api/v1/oidc/provider",
      %{
        "oidc_provider" => %{
          "issuer" => "https://identity.example.test/realms/skopos",
          "client_id" => "skopos",
          "client_secret" => "secret",
          "enabled" => enabled
        }
      },
      token
    )
    |> json_response(200)
  end

  defp id_token(key, nonce, subject) do
    now = System.system_time(:second)

    claims = %{
      "iss" => @issuer,
      "sub" => subject,
      "aud" => "skopos",
      "exp" => now + 300,
      "iat" => now,
      "nonce" => nonce
    }

    {_, token} =
      key
      |> JOSE.JWT.sign(%{"alg" => "RS256", "kid" => "browser-test", "typ" => "JWT"}, claims)
      |> JOSE.JWS.compact()

    token
  end

  defp bootstrap_and_sign_in! do
    post_json("/api/v1/accounts/bootstrap", %{
      "account" => %{
        "email" => "oidc-api-admin@example.com",
        "password" => @password,
        "password_confirmation" => @password
      }
    })
    |> json_response(201)

    post_json("/api/v1/sessions", %{
      "session" => %{"email" => "oidc-api-admin@example.com", "password" => @password}
    })
    |> json_response(201)
    |> get_in(["data", "token"])
  end

  defp get_json(path, token \\ nil), do: request(:get, path, nil, token)
  defp post_json(path, body, token \\ nil), do: request(:post, path, body, token)
  defp put_json(path, body, token), do: request(:put, path, body, token)

  defp request(method, path, body, token) do
    build_json_conn(body)
    |> maybe_authorize(token)
    |> dispatch_request(method, path, body)
  end

  defp dispatch_request(conn, :get, path, _body), do: get(conn, path)
  defp dispatch_request(conn, :post, path, body), do: post(conn, path, body)
  defp dispatch_request(conn, :put, path, body), do: put(conn, path, body)
  defp maybe_authorize(conn, nil), do: conn
  defp maybe_authorize(conn, token), do: put_req_header(conn, "authorization", "Bearer " <> token)
end
