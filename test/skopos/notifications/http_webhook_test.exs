defmodule Skopos.Notifications.HTTPWebhookTest do
  use Skopos.DataCase, async: false

  import Plug.Conn

  alias Skopos.{Accounts, Providers}
  alias Skopos.Providers.Notification

  @password "correct horse battery staple"
  @secret "notification-signing-secret-32-bytes-minimum"

  defmodule Stub do
    import Plug.Conn

    @secret "notification-signing-secret-32-bytes-minimum"

    def init(agent), do: agent

    def call(conn, agent) do
      {:ok, body, conn} = read_body(conn)
      valid? = valid_signature?(conn, body)

      Agent.update(agent, fn state ->
        request = %{
          method: conn.method,
          body: body,
          idempotency_key: List.first(get_req_header(conn, "idempotency-key")),
          signature_valid?: valid?
        }

        %{state | requests: [request | state.requests]}
      end)

      if valid?, do: route(conn, body), else: send_resp(conn, 401, "")
    end

    defp route(%{method: "HEAD"} = conn, _body), do: send_resp(conn, 204, "")

    defp route(%{method: "POST"} = conn, body) do
      case get_in(Jason.decode!(body), ["payload", "mode"]) do
        "accepted" ->
          conn
          |> put_resp_header("location", "https://receiver.example/deliveries/accepted-1")
          |> json(202, %{"status" => "queued"})

        "delivered" ->
          send_resp(conn, 204, "")

        "rejected" ->
          json(conn, 422, %{"error" => @secret})

        "unavailable" ->
          json(conn, 503, %{"error" => "temporary"})

        "timeout" ->
          Process.sleep(300)
          send_resp(conn, 204, "")
      end
    end

    defp valid_signature?(conn, body) do
      with [timestamp] <- get_req_header(conn, "x-skopos-timestamp"),
           ["v1=" <> signature] <- get_req_header(conn, "x-skopos-signature"),
           {seconds, ""} <- Integer.parse(timestamp),
           true <- abs(System.system_time(:second) - seconds) <= 5 do
        expected =
          :crypto.mac(:hmac, :sha256, @secret, timestamp <> "." <> body)
          |> Base.encode16(case: :lower)

        Plug.Crypto.secure_compare(signature, expected)
      else
        _error -> false
      end
    end

    defp json(conn, status, value) do
      conn
      |> put_resp_content_type("application/json")
      |> send_resp(status, Jason.encode!(value))
    end
  end

  setup do
    agent = start_supervised!({Agent, fn -> %{requests: []} end})

    server =
      start_supervised!(
        {Bandit,
         plug: {Stub, agent},
         scheme: :https,
         port: 0,
         certfile: Path.expand("test/support/certs/kubernetes_fixture.pem"),
         keyfile: Path.expand("test/support/certs/kubernetes_fixture_key.pem"),
         startup_log: false}
      )

    {:ok, {_address, port}} = ThousandIsland.listener_info(server)
    admin = Accounts.bootstrap!("notification-webhook-admin@example.com", @password, @password)

    provider =
      Providers.create_provider!(
        "HTTP webhook",
        :notification,
        "http-webhook",
        %{
          "url" => "https://127.0.0.1:#{port}/hook",
          "ca_certificate" => File.read!("test/support/certs/kubernetes_fixture_ca.pem"),
          "request_timeout_ms" => 100
        },
        %{"signing_secret" => @secret},
        actor: admin
      )

    checked = Providers.check_provider!(provider.id, provider.revision, %{}, actor: admin)
    assert checked.check_status == :passed
    provider = Providers.enable_provider!(checked, checked.revision, actor: admin)

    %{admin: admin, provider: provider, agent: agent}
  end

  test "the public route signs one request and preserves remote outcome certainty", context do
    accepted = deliver(context, "accepted")
    assert accepted.status == :accepted
    assert accepted.reference == "https://receiver.example/deliveries/accepted-1"
    assert accepted.details == %{"http_status" => 202, "response" => %{"status" => "queued"}}

    delivered = deliver(context, "delivered")
    assert delivered.status == :delivered
    assert delivered.details == %{"http_status" => 204}

    rejected = deliver(context, "rejected")
    assert rejected.status == :failed

    assert rejected.details == %{
             "http_status" => 422,
             "response" => %{"error" => "[REDACTED]"}
           }

    unavailable = deliver(context, "unavailable")
    assert unavailable.status == :unknown
    assert unavailable.details["http_status"] == 503

    timed_out = deliver(context, "timeout")
    assert timed_out.status == :unknown
    assert timed_out.details == %{error: "Webhook notification outcome is unknown"}

    requests = context.agent |> Agent.get(& &1.requests) |> Enum.reverse()
    assert [%{method: "HEAD", signature_valid?: true} | deliveries] = requests
    assert length(deliveries) == 5
    assert Enum.all?(deliveries, &(&1.method == "POST" and &1.signature_valid?))

    assert Enum.map(deliveries, & &1.idempotency_key) == [
             "delivery-accepted",
             "delivery-delivered",
             "delivery-rejected",
             "delivery-unavailable",
             "delivery-timeout"
           ]

    envelope = deliveries |> hd() |> Map.fetch!(:body) |> Jason.decode!()
    assert envelope["idempotency_key"] == "delivery-accepted"
    assert envelope["report"] == %{"id" => "report-1", "revision" => 3}
    assert envelope["destination"] == %{"id" => "destination-1", "revision" => 2}
    assert envelope["payload"] == %{"mode" => "accepted"}
    refute inspect([accepted, delivered, rejected, unavailable, timed_out]) =~ @secret
  end

  defp deliver(context, mode) do
    request = %Notification.Request{
      provider_revision: context.provider.revision,
      report_id: "report-1",
      report_revision: 3,
      destination_id: "destination-1",
      destination_revision: 2,
      idempotency_key: "delivery-#{mode}",
      payload: %{"mode" => mode}
    }

    Providers.notification_deliver!(context.provider.id, request, %{}, actor: context.admin)
  end
end
