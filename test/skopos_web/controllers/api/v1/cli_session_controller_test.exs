defmodule SkoposWeb.API.V1.CLISessionControllerTest do
  use SkoposWeb.ConnCase, async: false

  import OpenApiSpex.TestAssertions

  alias Skopos.Accounts.OIDC.Request, as: OIDCRequest

  @password "correct horse battery staple"

  test "a local Web account explicitly approves one PKCE-protected CLI session" do
    previous_public_url = Application.fetch_env!(:skopos, :public_url)
    Application.put_env(:skopos, :public_url, "https://skopos.example:8443")
    on_exit(fn -> Application.put_env(:skopos, :public_url, previous_public_url) end)

    token = bootstrap_and_sign_in!()
    verifier = OIDCRequest.random_secret()
    challenge = verifier |> OIDCRequest.digest() |> Base.url_encode64(padding: false)

    invalid = create_request("https://attacker.example/callback", challenge)
    assert %{"error" => %{"code" => "bad_request"}} = json_response(invalid, 400)

    created = create_request("http://127.0.0.1:54321/callback", challenge)

    assert get_resp_header(created, "cache-control") == ["no-store"]

    %{"data" => %{"id" => id, "authorization_url" => authorization_url}} =
      json_response(created, 201)

    assert_operation_response(created)

    authorization_uri = URI.parse(authorization_url)
    assert authorization_uri.scheme == "https"
    assert authorization_uri.host == "skopos.example"
    assert authorization_uri.port == 8443
    assert authorization_uri.path == "/cli-login/#{id}"
    assert %{"token" => start_token} = URI.decode_query(authorization_uri.fragment)

    unauthenticated = approve(id, start_token, nil)
    assert %{"error" => %{"code" => "unauthenticated"}} = json_response(unauthenticated, 401)

    wrong_token = approve(id, "wrong-token", token)
    assert %{"error" => %{"code" => "invalid_credentials"}} = json_response(wrong_token, 401)

    approved = approve(id, start_token, token)
    assert get_resp_header(approved, "cache-control") == ["no-store"]

    %{"data" => %{"redirect_uri" => redirect_uri, "account" => %{"id" => user_id}}} =
      json_response(approved, 200)

    assert_operation_response(approved)

    callback = URI.parse(redirect_uri)
    assert callback.scheme == "http"
    assert callback.host == "127.0.0.1"
    assert callback.port == 54_321
    assert callback.path == "/callback"
    assert %{"request_id" => ^id, "code" => code} = URI.decode_query(callback.query)

    exchanged = exchange(id, code, verifier)
    assert get_resp_header(exchanged, "cache-control") == ["no-store"]

    assert %{"data" => %{"token" => session_token, "account" => %{"id" => ^user_id}}} =
             json_response(exchanged, 201)

    assert_operation_response(exchanged)

    assert %{"data" => %{"account" => %{"id" => ^user_id}}} =
             get_json("/api/v1/session", session_token) |> json_response(200)

    assert %{"error" => %{"code" => "invalid_credentials"}} =
             exchange(id, code, verifier) |> json_response(401)
  end

  test "denial returns only to the validated loopback and permanently rejects approval" do
    token = bootstrap_and_sign_in!()
    verifier = OIDCRequest.random_secret()
    challenge = verifier |> OIDCRequest.digest() |> Base.url_encode64(padding: false)

    %{"data" => %{"id" => id, "authorization_url" => authorization_url}} =
      create_request("http://localhost:54322/callback", challenge) |> json_response(201)

    %{"token" => start_token} = URI.parse(authorization_url).fragment |> URI.decode_query()

    denied =
      post_json(
        "/api/v1/cli/session-requests/#{id}/deny",
        %{"request" => %{"start_token" => start_token}},
        token
      )

    assert %{"data" => %{"redirect_uri" => redirect_uri}} = json_response(denied, 200)
    callback = URI.parse(redirect_uri)
    assert callback.host == "localhost"

    assert %{"request_id" => ^id, "error" => "access_denied"} =
             URI.decode_query(callback.query)

    assert %{"error" => %{"code" => "invalid_credentials"}} =
             approve(id, start_token, token) |> json_response(401)
  end

  defp create_request(redirect_uri, challenge) do
    post_json("/api/v1/cli/session-requests", %{
      "request" => %{"redirect_uri" => redirect_uri, "code_challenge" => challenge}
    })
  end

  defp approve(id, start_token, token) do
    post_json(
      "/api/v1/cli/session-requests/#{id}/approve",
      %{"request" => %{"start_token" => start_token}},
      token
    )
  end

  defp exchange(id, code, verifier) do
    post_json("/api/v1/cli/session-requests/#{id}/exchange", %{
      "request" => %{"code" => code, "verifier" => verifier}
    })
  end

  defp bootstrap_and_sign_in! do
    post_json("/api/v1/accounts/bootstrap", %{
      "account" => %{
        "email" => "cli-browser-admin@example.com",
        "password" => @password,
        "password_confirmation" => @password
      }
    })
    |> json_response(201)

    post_json("/api/v1/sessions", %{
      "session" => %{"email" => "cli-browser-admin@example.com", "password" => @password}
    })
    |> json_response(201)
    |> get_in(["data", "token"])
  end

  defp get_json(path, token), do: request(:get, path, nil, token)
  defp post_json(path, body, token \\ nil), do: request(:post, path, body, token)

  defp request(method, path, body, token) do
    build_json_conn(body)
    |> maybe_authorize(token)
    |> dispatch_request(method, path, body)
  end

  defp dispatch_request(conn, :get, path, _body), do: get(conn, path)
  defp dispatch_request(conn, :post, path, body), do: post(conn, path, body)
  defp maybe_authorize(conn, nil), do: conn
  defp maybe_authorize(conn, token), do: put_req_header(conn, "authorization", "Bearer " <> token)
end
