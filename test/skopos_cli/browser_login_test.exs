defmodule SkoposCLI.BrowserLoginTest do
  use ExUnit.Case, async: true

  import Plug.Conn

  alias SkoposCLI.{BrowserLogin, Client}

  test "opens Web approval and exchanges the matching loopback PKCE callback once" do
    stub = {__MODULE__, make_ref()}
    {:ok, state} = Agent.start_link(fn -> %{} end)

    Req.Test.stub(stub, fn conn ->
      {:ok, encoded, conn} = read_body(conn)
      body = Jason.decode!(encoded)

      case conn.request_path do
        "/api/v1/cli/session-requests" ->
          %{
            "request" => %{
              "redirect_uri" => redirect_uri,
              "code_challenge" => challenge
            }
          } = body

          Agent.update(state, &Map.put(&1, :challenge, challenge))

          Req.Test.json(conn, %{
            data: %{
              id: "request-1",
              authorization_url: "https://skopos.example/cli-login/request-1#token=start"
            }
          })
          |> tap(fn _conn -> Agent.update(state, &Map.put(&1, :redirect_uri, redirect_uri)) end)

        "/api/v1/cli/session-requests/request-1/exchange" ->
          %{"request" => %{"code" => "approval-code", "verifier" => verifier}} = body

          assert :sha256 |> :crypto.hash(verifier) |> Base.url_encode64(padding: false) ==
                   Agent.get(state, & &1.challenge)

          Req.Test.json(conn, %{
            data: %{
              token: "product-session",
              account: %{id: "account-1", role: "admin"}
            }
          })
      end
    end)

    {:ok, client} =
      Client.new("https://skopos.example", nil, plug: {Req.Test, stub})

    open_browser = fn authorization_url ->
      assert authorization_url ==
               "https://skopos.example/cli-login/request-1#token=start"

      redirect_uri = Agent.get(state, & &1.redirect_uri)
      callback = URI.parse(redirect_uri)
      parent = self()

      spawn_link(fn ->
        {:ok, socket} =
          :gen_tcp.connect(
            {127, 0, 0, 1},
            callback.port,
            [:binary, active: false],
            2_000
          )

        :ok =
          :gen_tcp.send(
            socket,
            "GET /callback?request_id=request-1&code=approval-code HTTP/1.1\r\n" <>
              "Host: 127.0.0.1\r\nConnection: close\r\n\r\n"
          )

        {:ok, response} = :gen_tcp.recv(socket, 0, 2_000)
        :gen_tcp.close(socket)
        send(parent, {:callback_response, response})
      end)

      :ok
    end

    assert {:ok, "product-session", %{"id" => "account-1", "role" => "admin"}} =
             BrowserLogin.run(client, 2_000, open_browser, &:gen_tcp.listen/2)

    assert_receive {:callback_response, response}, 2_000
    assert response =~ "HTTP/1.1 200 OK"
    refute response =~ "product-session"
  end
end
