defmodule Skopos.Targets.RESTCONFTest do
  use Skopos.DataCase, async: false
  alias Skopos.{Accounts, Providers, Targets}
  alias Skopos.Providers.Target
  alias Skopos.Targets.TargetRequest.Request

  defmodule Stub do
    import Plug.Conn
    def init(agent), do: agent

    def call(conn, agent) do
      {:ok, body, conn} = read_body(conn)

      Agent.update(
        agent,
        &Map.update!(&1, :requests, fn requests ->
          [
            %{
              method: conn.method,
              path: conn.request_path,
              query: conn.query_string,
              body: body,
              accept: get_req_header(conn, "accept"),
              last_event_id: get_req_header(conn, "last-event-id"),
              if_match: get_req_header(conn, "if-match"),
              content_type: get_req_header(conn, "content-type")
            }
            | requests
          ]
        end)
      )

      authenticated? =
        match?(%{ssl_cert: certificate} when is_binary(certificate), get_peer_data(conn)) or
          get_req_header(conn, "authorization") in [
            ["Basic " <> Base.encode64("tester:secret")],
            ["Bearer static-test-token"]
          ]

      if authenticated?,
        do: route(conn, agent, body),
        else: send_resp(conn, 401, "")
    end

    defp route(%{request_path: "/.well-known/host-meta"} = conn, agent, _body) do
      Process.sleep(Agent.get(agent, & &1.discovery_delay))

      conn
      |> put_resp_content_type("application/xrd+xml")
      |> send_resp(200, Agent.get(agent, & &1.discovery))
    end

    defp route(%{request_path: "/custom/api"} = conn, _agent, _body),
      do: json(conn, %{"ietf-restconf:restconf" => %{}})

    defp route(%{request_path: "/custom/api/data/acme:idle"} = conn, _agent, _body) do
      Process.sleep(300)
      json(conn, %{"acme:status" => "ready"})
    end

    defp route(%{request_path: "/custom/api/data/acme:binary"} = conn, _agent, body) do
      bytes = if conn.method == "GET", do: <<255, 0, 1, 2, 255>>, else: body

      conn
      |> put_resp_header("content-type", "application/octet-stream")
      |> put_resp_header("etag", ~s("binary-v1"))
      |> send_resp(200, bytes)
    end

    defp route(%{method: "GET", request_path: "/streams/NETCONF"} = conn, agent, _body) do
      conn = conn |> put_resp_header("content-type", "text/event-stream") |> send_chunked(200)
      bytes = Agent.get(agent, & &1.stream_body)
      first = min(7, byte_size(bytes))
      {:ok, conn} = chunk(conn, binary_part(bytes, 0, first))
      {:ok, conn} = chunk(conn, binary_part(bytes, first, byte_size(bytes) - first))
      Process.sleep(Agent.get(agent, &Map.get(&1, :stream_delay, 1_000)))
      if Agent.get(agent, &Map.get(&1, :stream_drop, false)), do: Process.exit(self(), :kill)
      conn
    end

    defp route(
           %{method: method, request_path: "/custom/api/data/example:settings"} = conn,
           agent,
           _body
         )
         when method in ["GET", "HEAD"] do
      settings = Agent.get(agent, & &1.settings)

      conn
      |> put_resp_content_type(settings.content_type)
      |> send_resp(200, settings.body)
    end

    defp route(
           %{method: method, request_path: "/custom/api/data/example:settings"} = conn,
           agent,
           body
         )
         when method in ["POST", "PUT", "PATCH", "DELETE"] do
      content_type = hd(get_req_header(conn, "content-type"))
      Agent.update(agent, &%{&1 | settings: %{content_type: content_type, body: body}})
      Process.sleep(Agent.get(agent, & &1.effect_delay))
      send_resp(conn, 204, "")
    end

    defp route(conn, _agent, _body), do: send_resp(conn, 404, "")

    defp json(conn, value),
      do:
        conn
        |> put_resp_content_type("application/yang-data+json")
        |> send_resp(200, Jason.encode!(value))
  end

  setup tags do
    agent =
      start_supervised!(
        {Agent,
         fn ->
           %{
             requests: [],
             discovery_delay: 0,
             effect_delay: 0,
             discovery:
               ~s(<XRD xmlns="http://docs.oasis-open.org/ns/xri/xrd-1.0"><Link rel="restconf" href="/custom/api"/></XRD>),
             settings: %{
               content_type: "application/yang-data+json",
               body: Jason.encode!(%{"example:settings" => %{"name" => "original"}})
             }
           }
         end}
      )

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

    {:ok, {_, port}} = ThousandIsland.listener_info(server)
    endpoint = "https://127.0.0.1:#{port}"

    admin =
      Accounts.bootstrap!(
        "restconf-admin@example.invalid",
        "test-only-password",
        "test-only-password"
      )

    adapter = Map.get(tags, :adapter_type, "restconf")

    provider =
      Providers.create_provider!(
        "RESTCONF",
        :target,
        adapter,
        %{
          "ca_certificate" => File.read!("test/support/certs/kubernetes_fixture_ca.pem"),
          "request_timeout_ms" => 500
        },
        %{"username" => "tester", "password" => "secret"},
        actor: admin
      )

    checked =
      Skopos.TargetConnectionFixture.check_connection(provider, endpoint, admin)

    assert {:ok, _catalog} = checked

    target =
      Targets.create_target!(
        "restconf-device",
        "network_device",
        if(adapter == "ios-xe-restconf", do: "cisco_ios_xe", else: "custom-network-device"),
        %{},
        nil,
        actor: admin
      )

    method =
      Targets.create_access_method!(
        target.id,
        provider.id,
        "RESTCONF",
        "restconf",
        endpoint,
        provider.revision,
        100,
        ["request.restconf.observe", "request.restconf.effect"],
        actor: admin
      )
      |> then(&Targets.check_access_method!(&1.id, &1.revision, %{}, actor: admin))

    %{
      admin: admin,
      provider: provider,
      agent: agent,
      endpoint: endpoint,
      target: target,
      method: method
    }
  end

  for adapter <- ["restconf", "ios-xe-restconf"] do
    @tag adapter_type: adapter, protocol_context_fault: true
    test "#{adapter} retains a context read fault after one native request", context do
      for {action, type, capability, operation, method} <- [
            {&Providers.target_observe/4, Target.ObservationRequest, "request.restconf.observe",
             "request.observe", "GET"},
            {&Providers.target_effect/4, Target.EffectRequest, "request.restconf.effect",
             "request.execute", "PATCH"},
            {&Providers.target_verify/4, Target.VerificationRequest, "request.restconf.observe",
             "request.observe", "GET"}
          ] do
        resource_requests = fn ->
          Agent.get(context.agent, fn state ->
            Enum.count(state.requests, &(&1.path == "/custom/api/data/acme:idle"))
          end)
        end

        before_requests = resource_requests.()

        input =
          request(context, type, capability, operation, %{
            "method" => method,
            "path" => "/data/acme:idle"
          })

        cancelled? = fn ->
          if resource_requests.() != before_requests do
            {:error, cause} =
              Skopos.Repo.query("SELECT restconf_context_unavailable", [], mode: :savepoint)

            raise cause
          else
            false
          end
        end

        assert {:error, error} =
                 action.(context.provider.id, input, %{cancelled?: cancelled?},
                   actor: context.admin,
                   authorize?: false
                 )

        assert Exception.message(error) =~ "restconf_context_unavailable"
        assert Target.Error.context_failure?(error)
        assert is_nil(Target.BeforeSendError.unwrap(error))

        assert resource_requests.() == before_requests + 1
      end
    end

    @tag adapter_type: adapter, protocol_context_fault: true
    test "#{adapter} retains context read failures during root discovery", context do
      Agent.update(context.agent, &%{&1 | discovery_delay: 300})
      before_requests = Agent.get(context.agent, &length(&1.requests))

      input =
        request(context, Target.EffectRequest, "request.restconf.effect", "request.execute", %{
          "method" => "PATCH",
          "path" => "/data/acme:idle",
          "body" => "{}"
        })

      callback = fn ->
        if Agent.get(context.agent, &length(&1.requests)) > before_requests do
          {:error, cause} =
            Skopos.Repo.query("SELECT restconf_discovery_context_unavailable", [],
              mode: :savepoint
            )

          raise cause
        end

        false
      end

      assert {:error, error} =
               Providers.target_effect(context.provider.id, input, %{cancelled?: callback},
                 actor: context.admin,
                 authorize?: false
               )

      assert Exception.message(error) =~ "restconf_discovery_context_unavailable"
      assert Target.Error.context_failure?(error)

      assert [wire] =
               Agent.get(
                 context.agent,
                 &Enum.take(&1.requests, length(&1.requests) - before_requests)
               )

      assert wire.path == "/.well-known/host-meta"
      assert wire.method == "GET"
    end

    @tag adapter_type: adapter
    test "checked #{adapter} preserves arbitrary binary files and media", context do
      parameters = %{
        "method" => "GET",
        "path" => "/data/acme:binary",
        "accept" => "application/octet-stream",
        "response_file" => %{"name" => "restconf.bin", "media_type" => "application/octet-stream"}
      }

      request = %Request{
        kind: :observation,
        authority_mode: :readonly,
        target_id: context.target.id,
        target_revision: context.target.revision,
        access_method_id: context.method.id,
        access_method_revision: context.method.revision,
        capability: "request.restconf.observe",
        operation: "request.observe",
        operation_id: "restconf-binary",
        parameters: parameters
      }

      result =
        request
        |> Targets.clear_target_request!(actor: context.admin)
        |> Targets.dispatch_target_observation!(%{}, actor: context.admin)

      assert result.facts["body"] == ""
      assert result.facts["content_type"] == "application/octet-stream"
      file = result.facts["file"]
      assert file["size_bytes"] == 5

      assert Targets.read_bound_artifact_chunk!(file, 0, actor: context.admin) ==
               <<255, 0, 1, 2, 255>>

      assert Targets.get_artifact!(file["id"], actor: context.admin).request_id ==
               "restconf-binary"

      assert result.facts["completion_reason"] == "eof"
      assert result.facts["etag"] == ~s("binary-v1")

      effect = %{
        request
        | kind: :effect,
          authority_mode: :full_access,
          capability: "request.restconf.effect",
          operation: "request.execute",
          operation_id: "restconf-file-write",
          idempotency_key: "restconf-file-write",
          parameters: %{
            "method" => "PUT",
            "path" => "/data/acme:binary",
            "body_file" => "payload",
            "files" => %{"payload" => file},
            "content_type" => "application/octet-stream",
            "headers" => %{"If-Match" => ~s("binary-v1")},
            "response_file" => %{
              "name" => "restconf-reply.bin",
              "media_type" => "application/octet-stream"
            }
          }
      }

      sent =
        effect
        |> Targets.clear_target_request!(actor: context.admin)
        |> Targets.dispatch_target_effect!(%{}, actor: context.admin, authorize?: false)

      assert sent.status == :applied

      assert Targets.read_bound_artifact_chunk!(sent.details["file"], 0, actor: context.admin) ==
               <<255, 0, 1, 2, 255>>

      assert [
               %{
                 body: <<255, 0, 1, 2, 255>>,
                 content_type: ["application/octet-stream"],
                 if_match: [~s("binary-v1")]
               }
             ] =
               Agent.get(
                 context.agent,
                 &Enum.filter(&1.requests, fn request -> request.method == "PUT" end)
               )
    end
  end

  for adapter <- ["restconf", "ios-xe-restconf"] do
    @tag adapter_type: adapter
    test "#{adapter} advertised notification URIs capture exact SSE with explicit continuation facts",
         context do
      bytes =
        ": heartbeat\r\n\r\nid: opaque-7\r\ndata: <notification><vendor/></notification>\r\n\r\n" <>
          "id: opaque-9\ndata: {\"ietf-restconf:notification\":\ndata: {\"vendor:event\":{}}}\n\n"

      Agent.update(context.agent, &Map.put(&1, :stream_body, bytes))

      parameters = %{
        "method" => "GET",
        "uri" => context.endpoint <> "/streams/NETCONF",
        "query" => %{"start-time" => "2026-10-01T00:00:00Z"},
        "accept" => "text/event-stream",
        "last_event_id" => "opaque-4",
        "capture" => %{"duration_ms" => 100, "max_bytes" => 4_096},
        "response_file" => %{"name" => "notifications.sse", "media_type" => "text/event-stream"}
      }

      request = %Request{
        kind: :observation,
        authority_mode: :readonly,
        target_id: context.target.id,
        target_revision: context.target.revision,
        access_method_id: context.method.id,
        access_method_revision: context.method.revision,
        capability: "request.restconf.observe",
        operation: "request.observe",
        operation_id: "restconf-stream",
        parameters: parameters
      }

      before = Agent.get(context.agent, &length(&1.requests))

      result =
        request
        |> Targets.clear_target_request!(actor: context.admin)
        |> Targets.dispatch_target_observation!(%{}, actor: context.admin)

      assert result.facts["completion_reason"] == "duration_limit"

      assert result.facts["notifications"] == %{
               "event_count" => 2,
               "last_notification_id" => "opaque-9",
               "partial_event" => false,
               "error" => nil
             }

      received =
        Target.FileWriter.stream(result.facts["file"], fn offset ->
          Targets.read_bound_artifact_chunk(result.facts["file"], offset, actor: context.admin)
        end)
        |> Enum.to_list()
        |> IO.iodata_to_binary()

      assert received == bytes

      assert [wire] =
               Agent.get(context.agent, &Enum.take(&1.requests, length(&1.requests) - before))

      assert wire.path == "/streams/NETCONF"
      assert URI.decode_query(wire.query) == %{"start-time" => "2026-10-01T00:00:00Z"}
      assert wire.last_event_id == ["opaque-4"]
      assert wire.accept == ["text/event-stream"]
    end
  end

  test "OPTIONS is observational and an arbitrary protocol verb remains an exact effect",
       context do
    for {kind, verb, body} <- [
          {:observation, "OPTIONS", nil},
          {:effect, "APPLY!V2", "native-payload"}
        ] do
      request = %Request{
        kind: kind,
        authority_mode: :full_access,
        target_id: context.target.id,
        target_revision: context.target.revision,
        access_method_id: context.method.id,
        access_method_revision: context.method.revision,
        capability: "request.restconf.#{if(kind == :effect, do: "effect", else: "observe")}",
        operation: if(kind == :effect, do: "request.execute", else: "request.observe"),
        operation_id: "restconf-#{verb}",
        idempotency_key: "restconf-#{verb}",
        parameters: %{
          "method" => verb,
          "path" => "/data/acme:binary",
          "body" => body,
          "content_type" => "application/vnd.acme+opaque",
          "response_file" => %{
            "name" => "native-reply",
            "media_type" => "application/octet-stream"
          }
        }
      }

      clearance = Targets.clear_target_request!(request, actor: context.admin)

      if kind == :effect do
        result =
          Targets.dispatch_target_effect!(clearance, %{}, actor: context.admin, authorize?: false)

        assert result.status == :applied

        assert Targets.read_bound_artifact_chunk!(result.details["file"], 0, actor: context.admin) ==
                 "native-payload"
      else
        result = Targets.dispatch_target_observation!(clearance, %{}, actor: context.admin)
        assert result.facts["file"]["size_bytes"] == 0
      end

      assert Enum.any?(
               Agent.get(context.agent, & &1.requests),
               &(&1.method == verb and &1.content_type == ["application/vnd.acme+opaque"])
             )
    end
  end

  test "a partial notification remains raw and does not advance its supplied ID", context do
    first = "id: one\ndata: original\n\n"
    Agent.update(context.agent, &Map.put(&1, :stream_body, first <> "id: two\ndata: later\n\n"))

    parameters =
      stream_parameters(context) |> put_in(["capture", "max_bytes"], byte_size(first) + 8)

    result =
      native_request(context, :observation, parameters)
      |> Targets.clear_target_request!(actor: context.admin)
      |> Targets.dispatch_target_observation!(%{}, actor: context.admin)

    assert result.facts["completion_reason"] == "byte_limit"

    assert result.facts["notifications"] == %{
             "event_count" => 1,
             "last_notification_id" => "one",
             "partial_event" => true,
             "error" => nil
           }

    received =
      Target.FileWriter.stream(result.facts["file"], fn offset ->
        Targets.read_bound_artifact_chunk(result.facts["file"], offset, actor: context.admin)
      end)
      |> Enum.to_list()
      |> IO.iodata_to_binary()

    assert received == first <> "id: two\n"
  end

  test "invalid notification destinations and limits are rejected without wire or file effects",
       context do
    parameters = stream_parameters(context)
    before = Agent.get(context.agent, &length(&1.requests))

    for invalid <- [
          parameters |> Map.put("uri", "https://other.invalid/streams/NETCONF"),
          parameters |> Map.put("uri", context.endpoint <> "/streams/NETCONF#fragment"),
          parameters |> Map.put("path", "/data/example:settings"),
          parameters |> Map.delete("capture"),
          parameters
          |> Map.delete("capture")
          |> Map.put("accept", "Text/Event-Stream; charset=utf-8"),
          parameters |> Map.delete("response_file"),
          parameters |> put_in(["capture", "duration_ms"], 501),
          parameters |> put_in(["capture", "max_bytes"], 0),
          parameters |> Map.put("last_event_id", "one\r\nAuthorization: x"),
          parameters |> Map.put("headers", %{"Host" => "other.invalid"}),
          parameters |> Map.put("headers", %{"x-test" => "one\r\nx: two"}),
          parameters |> Map.put("headers", %{"x-test" => "one", "X-Test" => "two"}),
          parameters |> Map.put("method", "GET\r\n")
        ] do
      assert {:error, _} =
               Targets.clear_target_request(native_request(context, :observation, invalid),
                 actor: context.admin
               )
    end

    assert Agent.get(context.agent, &length(&1.requests)) == before
    assert Targets.page_artifacts!(context.target.id, actor: context.admin).results == []
  end

  test "cancelled and dropped notifications cannot publish a completed sample", context do
    Agent.update(context.agent, &Map.put(&1, :stream_body, "id: one\ndata: original\n\n"))

    clearance =
      native_request(context, :observation, stream_parameters(context))
      |> Targets.clear_target_request!(actor: context.admin)

    cancelled = fn ->
      Agent.get(
        context.agent,
        &Enum.any?(&1.requests, fn request -> request.path == "/streams/NETCONF" end)
      )
    end

    assert {:error, _} =
             Targets.dispatch_target_observation(clearance, %{cancelled?: cancelled},
               actor: context.admin
             )

    Agent.update(context.agent, &Map.merge(&1, %{stream_drop: true, stream_delay: 30}))
    assert {:error, _} = Targets.dispatch_target_observation(clearance, %{}, actor: context.admin)
    receipts = Targets.page_artifacts!(context.target.id, actor: context.admin).results
    assert length(receipts) == 2

    for receipt <- receipts do
      assert receipt.status == :receiving
      assert receipt.completion_reason == nil

      assert {:error, _} =
               Targets.artifact_reference(receipt.id, context.target.id, actor: context.admin)
    end

    assert Agent.get(
             context.agent,
             &Enum.count(&1.requests, fn request -> request.path == "/streams/NETCONF" end)
           ) == 2
  end

  test "notification summary limits preserve raw data without inventing an ID", context do
    for {bytes, reason} <- [
          {"data: " <> String.duplicate("x", 1_048_577) <> "\n\n", "summary_limit"},
          {"data: " <> <<255>> <> "\n\n", "invalid_utf8"}
        ] do
      Agent.update(context.agent, &Map.put(&1, :stream_body, bytes))

      parameters =
        stream_parameters(context)
        |> put_in(["capture", "max_bytes"], 2_097_152)
        |> put_in(["capture", "duration_ms"], 500)

      result =
        native_request(context, :observation, parameters)
        |> Targets.clear_target_request!(actor: context.admin)
        |> Targets.dispatch_target_observation!(%{}, actor: context.admin)

      assert result.facts["file"]["size_bytes"] == byte_size(bytes)

      assert result.facts["notifications"] == %{
               "event_count" => 0,
               "last_notification_id" => nil,
               "partial_event" => true,
               "error" => %{"reason" => reason}
             }
    end
  end

  test "checked generic RESTCONF follows the discovered service root", context do
    read = %Target.ObservationRequest{
      provider_revision: context.provider.revision,
      target_id: Ecto.UUID.generate(),
      target_revision: 1,
      access_method_id: Ecto.UUID.generate(),
      access_method_revision: 1,
      connection: %Target.Connection{endpoint: context.endpoint},
      capability: "request.restconf.observe",
      operation: "request.observe",
      authorization_digest: "fixture",
      parameters: %{"method" => "GET", "path" => "/data/example:settings"}
    }

    observation =
      Providers.target_observe!(context.provider.id, read, %{},
        actor: context.admin,
        authorize?: false
      )

    assert observation.facts["http_status"] == 200

    assert Jason.decode!(observation.facts["body"]) == %{
             "example:settings" => %{"name" => "original"}
           }

    assert Enum.any?(
             Agent.get(context.agent, & &1.requests),
             &(&1.path == "/custom/api/data/example:settings")
           )
  end

  test "Bearer credentials reach the checked RESTCONF endpoint", context do
    provider =
      Providers.update_provider!(
        context.provider,
        context.provider.revision,
        %{credentials: %{"bearer_token" => "static-test-token"}},
        actor: context.admin
      )

    checked =
      Skopos.TargetConnectionFixture.check_connection(provider, context.endpoint, context.admin)

    assert {:ok, _catalog} = checked

    provider =
      Providers.update_provider!(
        provider,
        provider.revision,
        %{credentials: %{"bearer_token" => "wrong-token"}},
        actor: context.admin
      )

    checked =
      Skopos.TargetConnectionFixture.check_connection(provider, context.endpoint, context.admin)

    assert {:error, _} = checked

    assert Enum.any?(
             elem(checked, 1).errors,
             &match?(%Target.Error{category: :authentication}, &1)
           )
  end

  test "connections at one origin cannot reuse another configuration's TLS trust", context do
    untrusted =
      Providers.create_provider!(
        "RESTCONF different trust",
        :target,
        "restconf",
        %{
          "ca_certificate" => File.read!("test/support/certs/restconf_client_ca.pem"),
          "request_timeout_ms" => 500
        },
        %{"username" => "tester", "password" => "secret"},
        actor: context.admin
      )

    assert {:error, _} =
             Skopos.TargetConnectionFixture.check_connection(
               untrusted,
               context.endpoint,
               context.admin
             )

    read =
      request(
        context,
        Target.ObservationRequest,
        "request.restconf.observe",
        "request.observe",
        %{
          "method" => "GET",
          "path" => "/data/example:settings"
        }
      )

    assert %Target.Observation{facts: %{"http_status" => 200}} =
             Providers.target_observe!(context.provider.id, read, %{},
               actor: context.admin,
               authorize?: false
             )
  end

  test "an XML effect is sent once and verified with an independent exact read", context do
    xml = ~s(<settings xmlns="urn:example"><name>changed</name></settings>)

    parameters = %{
      "method" => "PATCH",
      "path" => "/data/example:settings",
      "body" => xml,
      "content_type" => "application/yang-data+xml",
      "accept" => "application/yang-data+xml"
    }

    effect =
      request(
        context,
        Target.EffectRequest,
        "request.restconf.effect",
        "request.execute",
        parameters
      )

    assert %Target.EffectResult{status: :applied} =
             Providers.target_effect!(context.provider.id, effect, %{},
               actor: context.admin,
               authorize?: false
             )

    read =
      request(
        context,
        Target.VerificationRequest,
        "request.restconf.observe",
        "request.observe",
        %{
          "method" => "GET",
          "path" => "/data/example:settings",
          "query" => %{"content" => "config"},
          "accept" => "application/yang-data+xml"
        }
      )

    read = %{read | expected: %{"http_status" => 200, "body" => xml}}

    assert %Target.Verification{status: :verified, facts: %{"body" => ^xml}} =
             Providers.target_verify!(context.provider.id, read, %{},
               actor: context.admin,
               authorize?: false
             )

    requests = Agent.get(context.agent, & &1.requests)

    assert [%{body: ^xml, content_type: ["application/yang-data+xml"]}] =
             Enum.filter(requests, &(&1.method == "PATCH"))

    assert Enum.any?(
             requests,
             &(&1.method == "GET" and &1.query == "content=config" and
                 &1.accept == ["application/yang-data+xml"])
           )
  end

  test "client certificate credentials perform a verified mutual TLS handshake", context do
    server =
      start_supervised!(
        {Bandit,
         plug: {Stub, context.agent},
         scheme: :https,
         port: 0,
         certfile: Path.expand("test/support/certs/kubernetes_fixture.pem"),
         keyfile: Path.expand("test/support/certs/kubernetes_fixture_key.pem"),
         thousand_island_options: [
           transport_options: [
             cacertfile: Path.expand("test/support/certs/restconf_client_ca.pem"),
             verify: :verify_peer,
             fail_if_no_peer_cert: true
           ]
         ],
         startup_log: false},
        id: :mutual_tls
      )

    {:ok, {_, port}} = ThousandIsland.listener_info(server)
    endpoint = "https://127.0.0.1:#{port}"

    provider =
      Providers.create_provider!(
        "RESTCONF mutual TLS",
        :target,
        "restconf",
        %{
          "ca_certificate" => File.read!("test/support/certs/kubernetes_fixture_ca.pem"),
          "request_timeout_ms" => 1000
        },
        %{
          "client_certificate" => File.read!("test/support/certs/restconf_client.pem"),
          "client_private_key" => File.read!("test/support/certs/restconf_client_key.pem")
        },
        actor: context.admin
      )

    checked =
      Skopos.TargetConnectionFixture.check_connection(provider, endpoint, context.admin)

    assert {:ok, _catalog} = checked

    baseline =
      Skopos.TargetConnectionFixture.check_connection(context.provider, endpoint, context.admin)

    assert {:error, _} = baseline
  end

  test "classification rejects malformed or escaping paths and disguised effects without I/O",
       context do
    before = Agent.get(context.agent, &length(&1.requests))

    for parameters <- [
          %{"method" => "GET", "path" => "/data/%zz"},
          %{"method" => "GET", "path" => "/data/%2e%2e/other"},
          %{"method" => "GET", "path" => "/data/%252e%252e/other"},
          %{"method" => "GET", "path" => "https://other.invalid/data"},
          %{"method" => "GET", "path" => "//other.invalid/data"},
          %{"method" => "GET", "path" => "/data?a=1"},
          %{"method" => "POST", "path" => "/data/example:settings"},
          %{"method" => "GET", "path" => "/data/example:settings", "body" => "hidden"},
          %{
            "method" => "GET",
            "path" => "/data/example:settings",
            "headers" => %{"authorization" => "hidden"}
          }
        ] do
      input = %Target.MethodRequest{
        provider_revision: context.provider.revision,
        connection: %Target.Connection{endpoint: context.endpoint},
        capability: "request.restconf.observe",
        operation: "request.observe",
        selectors: %{},
        parameters: parameters
      }

      assert {:error, _} =
               Providers.target_classify(context.provider.id, input, %{},
                 actor: context.admin,
                 authorize?: false
               )
    end

    assert Agent.get(context.agent, &length(&1.requests)) == before
  end

  test "a lost effect response remains unknown, is not replayed, and can be observed afresh",
       context do
    Agent.update(context.agent, &%{&1 | effect_delay: 1_000})
    body = ~s({"example:settings":{"name":"changed-before-reply"}})

    effect =
      request(context, Target.EffectRequest, "request.restconf.effect", "request.execute", %{
        "method" => "PATCH",
        "path" => "/data/example:settings",
        "body" => body
      })

    assert %Target.EffectResult{status: :unknown} =
             Providers.target_effect!(context.provider.id, effect, %{},
               actor: context.admin,
               authorize?: false
             )

    assert length(
             Agent.get(context.agent, &Enum.filter(&1.requests, fn r -> r.method == "PATCH" end))
           ) == 1

    read =
      request(
        context,
        Target.VerificationRequest,
        "request.restconf.observe",
        "request.observe",
        %{"method" => "GET", "path" => "/data/example:settings"}
      )

    assert %Target.Verification{status: :verified} =
             Providers.target_verify!(
               context.provider.id,
               %{read | expected: %{"body" => body}},
               %{},
               actor: context.admin,
               authorize?: false
             )
  end

  test "root discovery and the effect share one request deadline", context do
    Agent.update(context.agent, &%{&1 | discovery_delay: 200, effect_delay: 400})
    body = ~s({"example:settings":{"name":"accepted-before-deadline"}})

    effect =
      request(context, Target.EffectRequest, "request.restconf.effect", "request.execute", %{
        "method" => "PATCH",
        "path" => "/data/example:settings",
        "body" => body
      })

    assert %Target.EffectResult{status: :unknown} =
             Providers.target_effect!(context.provider.id, effect, %{},
               actor: context.admin,
               authorize?: false
             )

    assert length(
             Agent.get(context.agent, &Enum.filter(&1.requests, fn r -> r.method == "PATCH" end))
           ) == 1

    Agent.update(context.agent, &%{&1 | discovery_delay: 0})

    read =
      request(
        context,
        Target.ObservationRequest,
        "request.restconf.observe",
        "request.observe",
        %{
          "method" => "GET",
          "path" => "/data/example:settings"
        }
      )

    assert %Target.Observation{facts: %{"body" => ^body}} =
             Providers.target_observe!(context.provider.id, read, %{},
               actor: context.admin,
               authorize?: false
             )
  end

  test "cancellation before dispatch sends nothing and cancellation after acceptance is unknown",
       context do
    effect =
      request(context, Target.EffectRequest, "request.restconf.effect", "request.execute", %{
        "method" => "PATCH",
        "path" => "/data/example:settings",
        "body" => "changed"
      })

    before = Agent.get(context.agent, &length(&1.requests))

    assert {:error, _} =
             Providers.target_effect(context.provider.id, effect, %{cancelled?: fn -> true end},
               actor: context.admin,
               authorize?: false
             )

    assert Agent.get(context.agent, &length(&1.requests)) == before
    Agent.update(context.agent, &%{&1 | effect_delay: 1_000})

    cancelled? = fn ->
      Agent.get(context.agent, &Enum.any?(&1.requests, fn r -> r.method == "PATCH" end))
    end

    assert %Target.EffectResult{status: :unknown} =
             Providers.target_effect!(context.provider.id, effect, %{cancelled?: cancelled?},
               actor: context.admin,
               authorize?: false
             )

    assert length(
             Agent.get(context.agent, &Enum.filter(&1.requests, fn r -> r.method == "PATCH" end))
           ) == 1
  end

  test "root discovery rejection or expiry stops before sending an effect", context do
    effect =
      request(context, Target.EffectRequest, "request.restconf.effect", "request.execute", %{
        "method" => "PATCH",
        "path" => "/data/example:settings",
        "body" => "changed"
      })

    for links <- [
          ~s(<Link rel="restconf" href="https://other.invalid/api"/>),
          ~s(<Link rel="restconf" href="/custom/api"/><Link rel="restconf" href="/second/api"/>)
        ] do
      Agent.update(
        context.agent,
        &%{
          &1
          | discovery: ~s(<XRD xmlns="http://docs.oasis-open.org/ns/xri/xrd-1.0">#{links}</XRD>)
        }
      )

      assert {:error, _} =
               Providers.target_effect(context.provider.id, effect, %{},
                 actor: context.admin,
                 authorize?: false
               )
    end

    Agent.update(context.agent, &%{&1 | discovery_delay: 1_000})

    assert {:error, _} =
             Providers.target_effect(context.provider.id, effect, %{},
               actor: context.admin,
               authorize?: false
             )

    refute Agent.get(context.agent, &Enum.any?(&1.requests, fn r -> r.method == "PATCH" end))
  end

  test "a configured root skips discovery and a HEAD read has an empty raw body", context do
    provider =
      Providers.update_provider!(
        context.provider,
        context.provider.revision,
        %{configuration: Map.put(context.provider.configuration, "api_root", "/custom/api")},
        actor: context.admin
      )

    Agent.update(context.agent, &%{&1 | discovery: "not XML", requests: []})

    checked =
      Skopos.TargetConnectionFixture.check_connection(provider, context.endpoint, context.admin)

    assert {:ok, _catalog} = checked

    context = %{context | provider: provider}

    read =
      request(
        context,
        Target.ObservationRequest,
        "request.restconf.observe",
        "request.observe",
        %{"method" => "HEAD", "path" => "/data/example:settings"}
      )

    assert %Target.Observation{facts: %{"http_status" => 200, "body" => ""}} =
             Providers.target_observe!(provider.id, read, %{},
               actor: context.admin,
               authorize?: false
             )

    refute Agent.get(
             context.agent,
             &Enum.any?(&1.requests, fn r -> r.path == "/.well-known/host-meta" end)
           )
  end

  test "an oversized response fails without returning a truncated successful observation",
       context do
    Agent.update(
      context.agent,
      &%{
        &1
        | settings: %{
            content_type: "application/yang-data+xml",
            body: String.duplicate("x", 65_537)
          }
      }
    )

    provider =
      Providers.update_provider!(
        context.provider,
        context.provider.revision,
        %{configuration: Map.put(context.provider.configuration, "max_body_bytes", 1_024)},
        actor: context.admin
      )

    checked =
      Skopos.TargetConnectionFixture.check_connection(provider, context.endpoint, context.admin)

    assert {:ok, _catalog} = checked

    context = %{context | provider: provider}

    read =
      request(
        context,
        Target.ObservationRequest,
        "request.restconf.observe",
        "request.observe",
        %{"method" => "GET", "path" => "/data/example:settings"}
      )

    assert {:error, _} =
             Providers.target_observe(provider.id, read, %{},
               actor: context.admin,
               authorize?: false
             )
  end

  for mode <- [:raise, :throw] do
    @tag completed_notification_read_fault: true, notification_read_fault_mode: mode
    test "completed notifications retain their file and the #{mode} read fault", context do
      bytes = "id: opaque-9\ndata: notification\n\n"
      Agent.update(context.agent, &Map.put(&1, :stream_body, bytes))

      clearance =
        native_request(context, :observation, stream_parameters(context))
        |> Targets.clear_target_request!(actor: context.admin)

      callback = fn ->
        receipts = Targets.page_artifacts!(context.target.id, actor: context.admin).results

        if Enum.any?(receipts, &(&1.status == :ready)) do
          if context.notification_read_fault_mode == :throw,
            do: throw(:notification_file_context_throw)

          {:error, cause} =
            Skopos.Repo.query("SELECT notification_file_context_unavailable", [],
              mode: :savepoint
            )

          raise cause
        end

        false
      end

      count = fn ->
        Agent.get(
          context.agent,
          &Enum.count(&1.requests, fn request -> request.path == "/streams/NETCONF" end)
        )
      end

      before = count.()

      assert {:error, error} =
               Targets.dispatch_target_observation(clearance, %{cancelled?: callback},
                 actor: context.admin
               )

      message =
        if context.notification_read_fault_mode == :throw,
          do: "notification_file_context_throw",
          else: "notification_file_context_unavailable"

      assert Exception.message(error) =~ message
      assert Target.Error.context_failure?(error)
      assert is_nil(Target.BeforeSendError.unwrap(error))

      assert %{"http_status" => 200, "file" => file, "completion_reason" => "duration_limit"} =
               Target.Error.context_progress(error)

      assert file["size_bytes"] == byte_size(bytes)

      received =
        Target.FileWriter.stream(file, fn offset ->
          Targets.read_bound_artifact_chunk(file, offset, actor: context.admin)
        end)
        |> Enum.to_list()
        |> IO.iodata_to_binary()

      assert received == bytes
      assert count.() == before + 1
    end
  end

  defp stream_parameters(context),
    do: %{
      "method" => "GET",
      "uri" => context.endpoint <> "/streams/NETCONF",
      "accept" => "text/event-stream",
      "capture" => %{"duration_ms" => 100, "max_bytes" => 4_096},
      "response_file" => %{"name" => "notifications.sse", "media_type" => "text/event-stream"}
    }

  defp native_request(context, kind, parameters),
    do: %Request{
      kind: kind,
      authority_mode: if(kind == :effect, do: :full_access, else: :readonly),
      target_id: context.target.id,
      target_revision: context.target.revision,
      access_method_id: context.method.id,
      access_method_revision: context.method.revision,
      capability:
        if(kind == :effect, do: "request.restconf.effect", else: "request.restconf.observe"),
      operation: if(kind == :effect, do: "request.execute", else: "request.observe"),
      operation_id: Ecto.UUID.generate(),
      idempotency_key: Ecto.UUID.generate(),
      parameters: parameters
    }

  defp request(context, module, capability, operation, parameters) do
    attributes = %{
      provider_revision: context.provider.revision,
      target_id: Ecto.UUID.generate(),
      target_revision: 1,
      access_method_id: Ecto.UUID.generate(),
      access_method_revision: 1,
      connection: %Target.Connection{endpoint: context.endpoint},
      capability: capability,
      operation: operation,
      authorization_digest: "fixture",
      parameters: parameters
    }

    attributes =
      if module in [Target.EffectRequest, Target.VerificationRequest],
        do: Map.put(attributes, :operation_id, Ecto.UUID.generate()),
        else: attributes

    attributes =
      if module == Target.EffectRequest,
        do: Map.put(attributes, :idempotency_key, Ecto.UUID.generate()),
        else: attributes

    struct!(module, attributes)
  end
end
