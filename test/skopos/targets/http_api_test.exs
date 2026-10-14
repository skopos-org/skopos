defmodule Skopos.Targets.HTTPAPITest do
  use Skopos.DataCase, async: false

  alias Skopos.{Accounts, Providers, Targets}
  alias Skopos.Providers.Target
  alias Skopos.Targets.Adapters.HTTP
  alias Skopos.Targets.TargetRequest.{RequestError, Request}

  defmodule Stub do
    import Plug.Conn

    def init(agent), do: agent

    def call(conn, agent) do
      Agent.update(agent, fn state ->
        Map.update(state, :requests, [{conn.method, conn.request_path}], fn requests ->
          [{conn.method, conn.request_path} | requests]
        end)
      end)

      credential = Agent.get(agent, &Map.get(&1, :credential, "fixture-token"))

      if get_req_header(conn, "authorization") == ["Bearer " <> credential] and
           Agent.get(agent, &Map.get(&1, :authorized, true)) do
        route(conn, agent)
      else
        send_resp(conn, 401, "")
      end
    end

    defp route(conn, agent) do
      case {conn.method, conn.request_path} do
        {"GET", "/api/status"} ->
          status = Agent.get(agent, &Map.get(&1, :status, "ready"))
          conn |> put_resp_header("etag", ~s("rev-1")) |> send_resp(200, status)

        {"GET", "/api/status-race"} ->
          Process.sleep(60)
          send_resp(conn, 200, "ready")

        {"HEAD", "/api/status"} ->
          send_resp(conn, 200, "")

        {"POST", "/api/action"} ->
          {:ok, body, conn} = read_body(conn)
          etag = get_req_header(conn, "if-match")
          Agent.update(agent, &Map.update!(&1, :writes, fn writes -> [{body, etag} | writes] end))
          conn |> put_resp_header("location", "/api/jobs/1") |> send_resp(202, "pending")

        {"POST", "/api/action-idle"} ->
          {:ok, body, conn} = read_body(conn)
          Agent.update(agent, &Map.update!(&1, :writes, fn writes -> [body | writes] end))
          send(Agent.get(agent, & &1.observer), {:idle_peer, self()})

          receive do
            :finish_idle -> send_resp(conn, 200, "")
          after
            2_000 -> send_resp(conn, 200, "")
          end

        {"POST", "/api/action-race"} ->
          {:ok, body, conn} = read_body(conn)
          Agent.update(agent, &Map.update!(&1, :writes, fn writes -> [body | writes] end))
          Process.sleep(60)
          send_resp(conn, 200, "")

        {"POST", "/api/drop"} ->
          Agent.update(agent, &Map.update!(&1, :writes, fn writes -> ["drop" | writes] end))
          Process.exit(self(), :kill)

        {"GET", "/api/large"} ->
          send_resp(conn, 200, String.duplicate("x", 30_000))

        {"GET", "/api/binary"} ->
          digest = Agent.get(agent, &Map.get(&1, :content_digest))
          conn = if digest, do: put_resp_header(conn, "content-digest", digest), else: conn

          conn
          |> put_resp_content_type("application/octet-stream")
          |> send_resp(200, <<255, 0, 1, 2, 255>>)

        {"PUT", "/api/binary"} ->
          {:ok, body, conn} = read_body(conn)
          Agent.update(agent, &Map.update!(&1, :writes, fn writes -> [body | writes] end))
          conn |> put_resp_content_type("application/octet-stream") |> send_resp(200, body)

        {method, "/api/native"} when method in ["PROPFIND", "OPS!V2"] ->
          {:ok, body, conn} = read_body(conn)
          request = %{method: method, body: body, headers: conn.req_headers}
          Agent.update(agent, &Map.update!(&1, :writes, fn writes -> [request | writes] end))
          conn |> put_resp_content_type("application/octet-stream") |> send_resp(200, body)

        {"OPS!V2", "/api/native-drop"} ->
          Agent.update(
            agent,
            &Map.update!(&1, :writes, fn writes -> ["native-drop" | writes] end)
          )

          Process.exit(self(), :kill)

        {"GET", "/api/chunked"} ->
          conn = send_chunked(conn, 200)
          {:ok, conn} = chunk(conn, <<255, 0>>)
          {:ok, conn} = chunk(conn, <<1, 2, 255>>)
          conn

        {"GET", "/api/interrupted"} ->
          conn = send_chunked(conn, 200)
          {:ok, _conn} = chunk(conn, <<255, 0>>)
          Process.sleep(80)
          Process.exit(self(), :kill)

        {"GET", "/api/cancelled"} ->
          conn = send_chunked(conn, 200)
          Agent.update(agent, &Map.put(&1, :cancelled, true))
          {:ok, conn} = chunk(conn, <<255, 0, 1, 2, 255>>)
          conn

        {"GET", "/api/idle"} ->
          conn = send_chunked(conn, 200)
          {:ok, conn} = chunk(conn, <<255, 0>>)
          Agent.update(agent, &Map.update(&1, :idle_calls, 1, fn count -> count + 1 end))
          send(Agent.get(agent, & &1.observer), {:idle_peer, self()})

          receive do
            :finish_idle -> conn
          after
            2_000 -> conn
          end

        {"GET", "/api/headers-idle"} ->
          Agent.update(agent, &Map.update(&1, :idle_calls, 1, fn count -> count + 1 end))
          send(Agent.get(agent, & &1.observer), {:idle_peer, self()})

          receive do
            :finish_idle -> send_resp(conn, 200, "")
          after
            2_000 -> send_resp(conn, 200, "")
          end

        {"GET", "/api/zero-events"} ->
          conn = conn |> put_resp_content_type("text/event-stream") |> send_chunked(200)

          receive do
            :finish_idle -> conn
          after
            2_000 -> conn
          end

        {"POST", "/api/continuous"} ->
          {:ok, body, conn} = read_body(conn)
          Agent.update(agent, &Map.update!(&1, :writes, fn writes -> [body | writes] end))
          conn = send_chunked(conn, 200)

          {conn, count} =
            Enum.reduce_while(1..40, {conn, 0}, fn _, {conn, count} ->
              Process.sleep(20)

              case chunk(conn, <<0>>) do
                {:ok, conn} -> {:cont, {conn, count + 1}}
                {:error, _} -> {:halt, {conn, count}}
              end
            end)

          send(Agent.get(agent, & &1.observer), {:continuous_end, count})
          conn

        {"GET", "/api/encoded"} ->
          conn
          |> put_resp_header("content-encoding", "gzip")
          |> send_resp(200, :zlib.gzip(<<255, 0, 1, 2, 255>>))

        _ ->
          send_resp(conn, 404, "missing")
      end
    end
  end

  setup tags do
    credential = if(tags[:normalized_native], do: "@", else: "fixture-token")
    observer = self()

    agent =
      start_supervised!(
        {Agent, fn -> %{writes: [], observer: observer, credential: credential} end}
      )

    server =
      start_supervised!({Bandit, plug: {Stub, agent}, scheme: :http, port: 0, startup_log: false})

    {:ok, {_address, port}} = ThousandIsland.listener_info(server)
    endpoint = "http://127.0.0.1:#{port}"

    admin =
      Accounts.bootstrap!(
        "http-api-method-admin@example.invalid",
        "test-only-password",
        "test-only-password"
      )

    operator =
      Accounts.create_user!(
        "http-api-method-operator@example.invalid",
        "test-only-password",
        :operator,
        actor: admin
      )

    provider =
      Providers.create_provider!(
        "http-api-method",
        :target,
        "http-api",
        %{},
        %{"bearer_token" => credential},
        actor: admin
      )
      |> then(&Providers.enable_provider!(&1, &1.revision, actor: admin))

    target =
      Targets.create_target!(
        "unknown-router",
        "network_device",
        "custom-network-device",
        %{},
        nil,
        actor: admin
      )

    method =
      Targets.create_access_method!(
        target.id,
        provider.id,
        "HTTP API",
        "http",
        endpoint,
        provider.revision,
        100,
        ["request.http.observe", "request.http.effect"],
        actor: admin
      )
      |> then(&Targets.check_access_method!(&1.id, &1.revision, %{}, actor: admin))

    {:ok, state} = HTTP.build(%{}, %{"bearer_token" => credential})
    {:ok, state} = HTTP.bind_connection(state, %Target.Connection{endpoint: endpoint})

    %{
      admin: admin,
      operator: operator,
      provider: provider,
      target: target,
      method: method,
      endpoint: endpoint,
      state: state,
      agent: agent
    }
  end

  @tag target_callback_read_fault: true
  test "pre-send context read faults retain their cause without calling the HTTP Method",
       context do
    read = read_request(context, "GET", "/api/status")
    write = write_request(context, "POST", "/api/action", "{}")

    verify = %Target.VerificationRequest{
      provider_revision: 1,
      target_id: context.target.id,
      target_revision: context.target.revision,
      access_method_id: context.method.id,
      access_method_revision: context.method.revision,
      connection: %Target.Connection{endpoint: context.endpoint},
      capability: "request.http.observe",
      operation: "request.observe",
      authorization_digest: "fixture",
      operation_id: "fixture",
      parameters: %{"method" => "GET", "path" => "/api/status"}
    }

    before_requests = Agent.get(context.agent, & &1.requests)

    cancelled? = fn ->
      {:error, error} =
        Skopos.Repo.query("SELECT target_invocation_context_unavailable", [], mode: :savepoint)

      raise error
    end

    for {action, request} <- [
          {&Providers.target_observe/4, read},
          {&Providers.target_effect/4, write},
          {&Providers.target_verify/4, verify}
        ] do
      assert {:error, error} =
               action.(context.provider.id, request, %{cancelled?: cancelled?},
                 actor: context.operator,
                 authorize?: false
               )

      assert %Target.BeforeSendError{cause: %Postgrex.Error{} = cause} =
               unsent = Target.BeforeSendError.unwrap(error)

      assert Exception.message(cause) =~ "target_invocation_context_unavailable"
      assert Target.BeforeSendError.retryable?(unsent)
      assert Agent.get(context.agent, & &1.requests) == before_requests
    end

    assert {:ok, %Target.Observation{facts: %{"status" => 200}}} =
             Providers.target_observe(context.provider.id, read, %{},
               actor: context.operator,
               authorize?: false
             )

    assert length(Agent.get(context.agent, & &1.requests)) == length(before_requests) + 1
  end

  @tag inflight_target_read_fault: true
  test "a read fault after HTTP dispatch retains its cause without sending the request again",
       context do
    read = read_request(context, "GET", "/api/headers-idle")
    write = write_request(context, "POST", "/api/action-idle", "{}")

    verify = %Target.VerificationRequest{
      provider_revision: 1,
      target_id: context.target.id,
      target_revision: context.target.revision,
      access_method_id: context.method.id,
      access_method_revision: context.method.revision,
      connection: %Target.Connection{endpoint: context.endpoint},
      capability: "request.http.observe",
      operation: "request.observe",
      authorization_digest: "fixture",
      operation_id: "fixture",
      parameters: %{"method" => "GET", "path" => "/api/headers-idle"}
    }

    for {action, request} <- [
          {&Providers.target_observe/4, read},
          {&Providers.target_effect/4, write},
          {&Providers.target_verify/4, verify}
        ] do
      before_requests = Agent.get(context.agent, & &1.requests)

      cancelled? = fn ->
        if Agent.get(context.agent, & &1.requests) == before_requests do
          false
        else
          {:error, error} =
            Skopos.Repo.query("SELECT inflight_target_context_unavailable", [], mode: :savepoint)

          raise error
        end
      end

      assert {:error, error} =
               action.(context.provider.id, request, %{cancelled?: cancelled?},
                 actor: context.operator,
                 authorize?: false
               )

      assert Exception.message(error) =~ "inflight_target_context_unavailable"
      assert is_nil(Target.BeforeSendError.unwrap(error))
      assert length(Agent.get(context.agent, & &1.requests)) == length(before_requests) + 1
      assert_receive {:idle_peer, peer}
      send(peer, :finish_idle)
    end

    assert Agent.get(context.agent, & &1.writes) == ["{}"]
  end

  @tag inflight_target_read_fault: true
  test "received HTTP facts survive cancellation and a context fault during a slow check",
       context do
    read = read_request(context, "GET", "/api/status-race")
    write = write_request(context, "POST", "/api/action-race", "{}")

    verify = %Target.VerificationRequest{
      provider_revision: 1,
      target_id: context.target.id,
      target_revision: context.target.revision,
      access_method_id: context.method.id,
      access_method_revision: context.method.revision,
      connection: %Target.Connection{endpoint: context.endpoint},
      capability: "request.http.observe",
      operation: "request.observe",
      authorization_digest: "fixture",
      operation_id: "fixture",
      expected: %{"status" => 200},
      parameters: %{"method" => "GET", "path" => "/api/status-race"}
    }

    for stop <- [:cancel, :read_fault],
        {action, request, expected_status} <- [
          {&Providers.target_observe/4, read, nil},
          {&Providers.target_effect/4, write, :applied},
          {&Providers.target_verify/4, verify, :verified}
        ] do
      before_requests = Agent.get(context.agent, & &1.requests)

      cancelled? = fn ->
        if Agent.get(context.agent, & &1.requests) == before_requests do
          false
        else
          Process.sleep(500)

          case stop do
            :cancel ->
              true

            :read_fault ->
              {:error, error} =
                Skopos.Repo.query("SELECT inflight_target_context_unavailable", [],
                  mode: :savepoint
                )

              raise error
          end
        end
      end

      assert {:ok, result} =
               action.(context.provider.id, request, %{cancelled?: cancelled?},
                 actor: context.operator,
                 authorize?: false
               )

      if expected_status do
        assert result.status == expected_status
      else
        assert result.facts["status"] == 200
        assert result.facts["body"] == "ready"
      end

      assert length(Agent.get(context.agent, & &1.requests)) == length(before_requests) + 1
    end

    assert Agent.get(context.agent, & &1.writes) == ["{}", "{}"]
  end

  test "a registered Method check records connection facts separately from operator grants",
       context do
    checked =
      Targets.check_access_method!(context.method.id, context.method.revision, %{},
        actor: context.admin
      )

    assert checked.check_status == :passed
    assert checked.checked_target_revision == context.target.revision
    assert checked.checked_connection_revision == checked.connection_revision
    assert checked.capabilities == ["request.http.observe", "request.http.effect"]
    assert checked.observed_capabilities == ["request.http.observe", "request.http.effect"]
    reread = Targets.get_access_method!(checked.id, actor: context.admin)
    assert reread.checked_at == checked.checked_at
    assert reread.check_status == :passed
    assert reread.operation_catalog == checked.operation_catalog

    assert %Target.Operation{operation: "request.observe"} =
             hd(reread.operation_catalog.observations)
  end

  test "Method grants and display edits preserve a check but an endpoint edit invalidates it",
       context do
    checked =
      Targets.check_access_method!(context.method.id, context.method.revision, %{},
        actor: context.admin
      )

    edited =
      Targets.update_access_method!(
        checked,
        checked.revision,
        %{name: "renamed", priority: 20, capabilities: []},
        actor: context.admin
      )

    assert edited.check_status == :passed
    assert edited.checked_at == checked.checked_at
    assert edited.observed_capabilities == ["request.http.observe", "request.http.effect"]
    assert edited.capabilities == []

    changed =
      Targets.update_access_method!(edited, edited.revision, %{endpoint: context.endpoint <> "/"},
        actor: context.admin
      )

    assert is_nil(changed.check_status)
    assert changed.observed_capabilities == []
    assert is_nil(changed.operation_catalog)
  end

  test "a failed Method recheck clears earlier connection facts without disabling shared credentials",
       context do
    checked =
      Targets.check_access_method!(context.method.id, context.method.revision, %{},
        actor: context.admin
      )

    Agent.update(context.agent, &Map.put(&1, :authorized, false))
    failed = Targets.check_access_method!(checked.id, checked.revision, %{}, actor: context.admin)
    assert failed.check_status == :failed
    assert failed.observed_capabilities == []
    assert is_nil(failed.operation_catalog)
    assert Providers.get_provider!(context.provider.id, actor: context.admin).enabled

    request = %Request{
      kind: :effect,
      authority_mode: :auto,
      target_id: context.target.id,
      target_revision: context.target.revision,
      access_method_id: failed.id,
      access_method_revision: failed.revision,
      capability: "request.http.effect",
      operation: "request.effect",
      parameters: %{"method" => "POST", "path" => "/api/action", "body" => "{}"}
    }

    assert {:error, _} = Targets.clear_target_request(request, actor: context.operator)
    assert Agent.get(context.agent, & &1.writes) == []

    assert {:error, %Ash.Error.Forbidden{}} =
             Targets.check_access_method(context.method.id, failed.revision, %{},
               actor: context.operator
             )
  end

  test "two registered Methods share credentials but reach their own HTTP endpoints", context do
    second_agent =
      start_supervised!(%{
        id: :second_http_state,
        start: {Agent, :start_link, [fn -> %{writes: [], status: "second-device"} end]}
      })

    second_server =
      start_supervised!(%{
        id: :second_http_server,
        start:
          {Bandit, :start_link,
           [[plug: {Stub, second_agent}, scheme: :http, port: 0, startup_log: false]]}
      })

    {:ok, {_address, port}} = ThousandIsland.listener_info(second_server)
    second_endpoint = "http://127.0.0.1:#{port}"

    provider =
      Providers.create_provider!(
        "shared-http-credentials",
        :target,
        "http-api",
        %{},
        %{"bearer_token" => "fixture-token"},
        actor: context.admin
      )
      |> then(&Providers.enable_provider!(&1, &1.revision, actor: context.admin))

    refute Map.has_key?(provider.configuration, "endpoint")

    for {name, endpoint, body} <- [
          {"first", context.endpoint, "ready"},
          {"second", second_endpoint, "second-device"},
          {"root-alias", context.endpoint <> "/", "ready"}
        ] do
      method =
        Targets.create_access_method!(
          context.target.id,
          provider.id,
          name,
          "http",
          endpoint,
          provider.revision,
          100,
          ["request.http.observe"],
          actor: context.admin
        )
        |> then(&Targets.check_access_method!(&1.id, &1.revision, %{}, actor: context.admin))

      request = %Request{
        kind: :observation,
        authority_mode: :readonly,
        target_id: context.target.id,
        target_revision: context.target.revision,
        access_method_id: method.id,
        access_method_revision: method.revision,
        capability: "request.http.observe",
        operation: "request.observe",
        selectors: %{},
        parameters: %{"method" => "GET", "path" => "/api/status"}
      }

      observation =
        request
        |> Targets.clear_target_request!(actor: context.operator)
        |> Targets.dispatch_target_observation!(%{}, actor: context.operator, authorize?: false)

      assert observation.facts["body"] == body
      assert observation.facts["url"] == String.trim_trailing(endpoint, "/") <> "/api/status"
    end
  end

  test "an unlisted device uses the same HTTP Method for reads and effects", context do
    assert %Target.Capabilities{observations: observations, effects: effects} =
             Providers.target_capabilities!(
               context.provider.id,
               %Target.CapabilitiesRequest{
                 provider_revision: context.provider.revision,
                 connection: %Target.Connection{endpoint: context.endpoint}
               },
               %{},
               actor: context.admin
             )

    assert Enum.any?(observations, &(&1.capability == "request.http.observe"))
    assert Enum.any?(effects, &(&1.capability == "request.http.effect"))

    assert {:ok, observation} =
             HTTP.observe(context.state, read_request(context, "GET", "/api/status"), %{})

    assert observation.facts["status"] == 200
    assert observation.facts["body"] == "ready"

    assert {:ok, head} =
             HTTP.observe(context.state, read_request(context, "HEAD", "/api/status"), %{})

    assert head.facts["status"] == 200

    request = write_request(context, "POST", "/api/action", "{\"apply\":true}")

    request = %{
      request
      | parameters: Map.put(request.parameters, "headers", %{"if-match" => ~s("rev-1")})
    }

    assert {:ok, %{status: :unknown, details: details}} = HTTP.effect(context.state, request, %{})
    assert details["status"] == 202
    assert details["response_redacted"] == true
    assert Agent.get(context.agent, & &1.writes) == [{"{\"apply\":true}", [~s("rev-1")]}]

    verify = %Target.VerificationRequest{
      provider_revision: 1,
      target_id: context.target.id,
      target_revision: context.target.revision,
      access_method_id: context.method.id,
      access_method_revision: context.method.revision,
      connection: %Target.Connection{endpoint: context.endpoint},
      capability: "request.http.observe",
      operation: "request.observe",
      authorization_digest: "fixture",
      operation_id: "fixture",
      parameters: %{"method" => "GET", "path" => "/api/status"},
      expected: %{"status" => 200}
    }

    assert {:ok, %{status: :verified}} = HTTP.verify(context.state, verify, %{})
  end

  test "a checked native HTTP verb and standard headers preserve exact file bytes", context do
    file =
      Targets.begin_artifact!(
        context.target.id,
        "native.bin",
        "application/octet-stream",
        5,
        "b55f1659c0645fd1cee6dfa8b3af06795e9da7e48cb65c2b999f896c9f539dbd",
        "native-input",
        actor: context.operator
      )

    Targets.append_artifact_chunk!(file.id, 0, <<255, 0, 1, 2, 255>>, actor: context.operator)
    Targets.complete_artifact!(file.id, actor: context.operator)
    reference = Targets.artifact_reference!(file.id, context.target.id, actor: context.operator)
    headers = %{"Depth" => "1", "Prefer" => "return=minimal", "X-Resource-Key" => "public-id"}

    parameters = %{
      "headers" => headers,
      "body_file" => "input",
      "files" => %{"input" => reference}
    }

    clearance = cleared_http(context, "PROPFIND", "/api/native", parameters)

    result =
      Targets.dispatch_target_effect!(clearance, %{}, actor: context.operator, authorize?: false)

    assert result.status == :applied
    assert read_file(context, result.details["file"]) == <<255, 0, 1, 2, 255>>

    assert [%{method: "PROPFIND", body: <<255, 0, 1, 2, 255>>, headers: sent}] =
             Agent.get(context.agent, & &1.writes)

    assert {"depth", "1"} in sent
    assert {"prefer", "return=minimal"} in sent
    assert {"x-resource-key", "public-id"} in sent
    assert {"authorization", "Bearer fixture-token"} in sent
    schema = hd(context.method.operation_catalog.effects).input_schema

    assert {:ok, _} =
             JSV.validate(
               %{"selectors" => %{}, "parameters" => clearance.parameters},
               JSV.build!(schema)
             )
  end

  test "an extension verb retains its spelling and follows effect authority even without a body",
       context do
    request = %Request{
      kind: :effect,
      authority_mode: :full_access,
      target_id: context.target.id,
      target_revision: context.target.revision,
      access_method_id: context.method.id,
      access_method_revision: context.method.revision,
      capability: "request.http.effect",
      operation: "request.execute",
      operation_id: "native-empty-body",
      idempotency_key: "native-empty-body-1",
      parameters: %{"method" => "OPS!V2", "path" => "/api/native"}
    }

    readonly = %{request | authority_mode: :readonly}

    observation = %{
      readonly
      | kind: :observation,
        capability: "request.http.observe",
        operation: "request.observe"
    }

    readonly_clearance = Targets.clear_target_request!(readonly, actor: context.operator)

    assert {:error, _} =
             Targets.dispatch_target_effect(readonly_clearance, %{},
               actor: context.operator,
               authorize?: false
             )

    assert {:error, _} = Targets.clear_target_request(observation, actor: context.operator)
    assert Agent.get(context.agent, & &1.writes) == []

    clearance = Targets.clear_target_request!(request, actor: context.operator)

    result =
      Targets.dispatch_target_effect!(clearance, %{}, actor: context.operator, authorize?: false)

    assert result.status == :applied
    assert [%{method: "OPS!V2", body: ""}] = Agent.get(context.agent, & &1.writes)

    unknown = cleared_http(context, "OPS!V2", "/api/native-drop")

    assert %{status: :unknown} =
             Targets.dispatch_target_effect!(unknown, %{},
               actor: context.operator,
               authorize?: false
             )

    assert ["native-drop", _completed] = Agent.get(context.agent, & &1.writes)
  end

  test "native headers cannot override connection credentials or HTTP framing", context do
    for headers <- [
          %{"HOST" => "other.invalid"},
          %{"Content-Length" => "999"},
          %{"Transfer-Encoding" => "chunked"},
          %{"Authorization" => "Bearer other"},
          %{"Proxy-Authorization" => "Basic other"},
          %{"Cookie" => "session=other"},
          %{"Depth" => "1\r\nHost: other.invalid"},
          %{"Bad Header" => "1"},
          %{"Depth" => "1", "depth" => "2"}
        ] do
      assert {:error, _} =
               %Request{
                 kind: :effect,
                 authority_mode: :full_access,
                 target_id: context.target.id,
                 target_revision: context.target.revision,
                 access_method_id: context.method.id,
                 access_method_revision: context.method.revision,
                 capability: "request.http.effect",
                 operation: "request.execute",
                 operation_id: "native-header-denial",
                 idempotency_key: "native-header-denial-1",
                 parameters: %{
                   "method" => "PROPFIND",
                   "path" => "/api/native",
                   "headers" => headers
                 }
               }
               |> Targets.clear_target_request(actor: context.operator)
    end

    assert Agent.get(context.agent, & &1.writes) == []
  end

  test "HTTP request validation confines origin, credentials, body and response", context do
    assert {:error, :failed, _} =
             HTTP.bind_connection(context.state, %Target.Connection{
               endpoint: context.endpoint <> "/api/status"
             })

    for path <- [
          "http://other.example/api/status",
          "//other.example/api/status",
          "/api/../status",
          "/api/%2fsecret"
        ] do
      assert {:error, :failed, _} =
               HTTP.observe(context.state, read_request(context, "GET", path), %{})
    end

    assert {:error, :failed, _} =
             HTTP.observe(context.state, read_request(context, "POST", "/api/status"), %{})

    assert {:error, :failed, _} =
             HTTP.effect(context.state, write_request(context, "GET", "/api/action", ""), %{})

    too_large = write_request(context, "POST", "/api/action", String.duplicate("x", 70_000))
    assert {:error, :failed, _} = HTTP.effect(context.state, too_large, %{})

    smuggled = %{
      write_request(context, "POST", "/api/action", "{}")
      | parameters: %{
          "method" => "POST",
          "path" => "/api/action",
          "body" => "{}",
          "headers" => %{"authorization" => "Bearer attacker"}
        }
    }

    assert {:error, :failed, _} = HTTP.effect(context.state, smuggled, %{})

    assert {:ok, large} =
             HTTP.observe(context.state, read_request(context, "GET", "/api/large"), %{})

    assert large.facts["body_truncated"] == true
    assert byte_size(large.facts["body"]) == 8_192
    assert Agent.get(context.agent, & &1.writes) == []
  end

  test "a write cannot enter the observation path at clearance or direct Provider dispatch",
       context do
    parameters = %{"method" => "POST", "path" => "/api/action", "body" => "{}"}

    proposal = %Request{
      kind: :observation,
      authority_mode: :auto,
      target_id: context.target.id,
      target_revision: context.target.revision,
      access_method_id: context.method.id,
      access_method_revision: context.method.revision,
      capability: "request.http.observe",
      operation: "request.observe",
      parameters: parameters
    }

    assert {:error, clearance_error} =
             Targets.clear_target_request(proposal, actor: context.operator)

    assert Enum.any?(clearance_error.errors, &match?(%RequestError{category: :denied}, &1))

    dispatch_request = %{read_request(context, "POST", "/api/action") | parameters: parameters}

    assert {:error, dispatch_error} =
             Providers.target_observe(context.provider.id, dispatch_request, %{},
               actor: context.operator,
               authorize?: false
             )

    assert Enum.any?(dispatch_error.errors, &match?(%Target.Error{category: :failed}, &1))
    assert Agent.get(context.agent, & &1.writes) == []
  end

  @tag normalized_native: true
  test "registered HTTP observation and verification retain the complete normalized native response",
       context do
    Agent.update(context.agent, &Map.put(&1, :status, String.duplicate("@", 8_192)))

    request = %Request{
      kind: :observation,
      authority_mode: :readonly,
      target_id: context.target.id,
      target_revision: context.target.revision,
      access_method_id: context.method.id,
      access_method_revision: context.method.revision,
      capability: "request.http.observe",
      operation: "request.observe",
      parameters: %{"method" => "GET", "path" => "/api/status"}
    }

    observation =
      request
      |> Targets.clear_target_request!(actor: context.operator)
      |> Targets.dispatch_target_observation!(%{}, actor: context.operator, authorize?: false)

    assert observation.facts["body"] == String.duplicate("[REDACTED]", 8_192)
    assert observation.facts["body_truncated"] == false
    assert byte_size(Jason.encode!(observation.facts)) > 65_536

    verification =
      Providers.target_verify!(
        context.provider.id,
        %Target.VerificationRequest{
          provider_revision: context.provider.revision,
          target_id: context.target.id,
          target_revision: context.target.revision,
          access_method_id: context.method.id,
          access_method_revision: context.method.revision,
          connection: %Target.Connection{endpoint: context.endpoint},
          capability: "request.http.observe",
          operation: "request.observe",
          authorization_digest: "fixture",
          operation_id: "fixture",
          parameters: request.parameters,
          expected: %{"status" => 200}
        },
        %{},
        actor: context.operator,
        authorize?: false
      )

    assert verification.status == :verified
    assert verification.facts["body"] == observation.facts["body"]

    assert Enum.count(Agent.get(context.agent, & &1.requests), &(&1 == {"GET", "/api/status"})) ==
             2
  end

  test "a lost HTTP effect response stays unknown and is not replayed", context do
    assert {:ok, %{status: :unknown}} =
             HTTP.effect(context.state, write_request(context, "POST", "/api/drop", "{}"), %{})

    assert Agent.get(context.agent, & &1.writes) == ["drop"]
  end

  test "a checked HTTP Method publishes a complete binary response as an immutable file",
       context do
    request = %Request{
      kind: :observation,
      authority_mode: :readonly,
      target_id: context.target.id,
      target_revision: context.target.revision,
      access_method_id: context.method.id,
      access_method_revision: context.method.revision,
      capability: "request.http.observe",
      operation: "request.observe",
      parameters: %{
        "method" => "GET",
        "path" => "/api/binary",
        "response_file" => %{"name" => "result.bin", "media_type" => "application/octet-stream"}
      }
    }

    result =
      request
      |> Targets.clear_target_request!(actor: context.operator)
      |> Targets.dispatch_target_observation!(%{}, actor: context.operator, authorize?: false)

    file = result.facts["file"]
    assert file["target_id"] == context.target.id
    assert file["name"] == "result.bin"
    assert file["size_bytes"] == 5
    assert file["sha256"] == "b55f1659c0645fd1cee6dfa8b3af06795e9da7e48cb65c2b999f896c9f539dbd"

    assert Targets.read_bound_artifact_chunk!(file, 0, actor: context.operator) ==
             <<255, 0, 1, 2, 255>>

    assert result.facts["body"] == ""
    refute result.facts["body_truncated"]
  end

  test "a checked HTTP effect sends the exact staged bytes and saves its binary reply", context do
    upload =
      Targets.begin_artifact!(
        context.target.id,
        "input.bin",
        "application/octet-stream",
        5,
        "b55f1659c0645fd1cee6dfa8b3af06795e9da7e48cb65c2b999f896c9f539dbd",
        "http-upload",
        actor: context.operator
      )

    Targets.append_artifact_chunk!(upload.id, 0, <<255, 0>>, actor: context.operator)
    Targets.append_artifact_chunk!(upload.id, 2, <<1, 2, 255>>, actor: context.operator)
    Targets.complete_artifact!(upload.id, actor: context.operator)
    file = Targets.artifact_reference!(upload.id, context.target.id, actor: context.operator)

    request = %Request{
      kind: :effect,
      authority_mode: :full_access,
      target_id: context.target.id,
      target_revision: context.target.revision,
      access_method_id: context.method.id,
      access_method_revision: context.method.revision,
      capability: "request.http.effect",
      operation: "request.execute",
      operation_id: "http-binary-effect",
      idempotency_key: "http-binary-effect-1",
      parameters: %{
        "method" => "PUT",
        "path" => "/api/binary",
        "body_file" => "payload",
        "files" => %{"payload" => file},
        "response_file" => %{"name" => "reply.bin", "media_type" => "application/octet-stream"}
      }
    }

    clearance = Targets.clear_target_request!(request, actor: context.operator)

    result =
      clearance
      |> Targets.dispatch_target_effect!(%{}, actor: context.operator, authorize?: false)

    assert result.status == :applied
    assert Agent.get(context.agent, & &1.writes) == [<<255, 0, 1, 2, 255>>]
    reply = result.details["file"]
    assert reply["id"] != file["id"]
    assert reply["sha256"] == "b55f1659c0645fd1cee6dfa8b3af06795e9da7e48cb65c2b999f896c9f539dbd"

    assert Targets.read_bound_artifact_chunk!(reply, 0, actor: context.operator) ==
             <<255, 0, 1, 2, 255>>

    operation = hd(context.method.operation_catalog.effects)
    schema = JSV.build!(operation.input_schema)

    assert {:ok, _} =
             JSV.validate(%{"selectors" => %{}, "parameters" => request.parameters}, schema)

    for parameters <- [
          Map.put(request.parameters, "body", "replacement"),
          Map.put(request.parameters, "body_file", "missing"),
          Map.put(request.parameters, "path", "https://other.invalid/api/binary")
        ] do
      assert {:error, _} =
               Targets.clear_target_request(%{request | parameters: parameters},
                 actor: context.operator
               )
    end

    Targets.revoke_artifact!(file["id"], actor: context.operator)

    assert {:error, _} =
             Targets.dispatch_target_effect(clearance, %{},
               actor: context.operator,
               authorize?: false
             )

    assert Agent.get(context.agent, & &1.writes) == [<<255, 0, 1, 2, 255>>]
  end

  @tag http_input_fault: true
  test "HTTP file reader faults distinguish local preparation from a started stream", context do
    upload =
      Targets.begin_artifact!(
        context.target.id,
        "reader.bin",
        "application/octet-stream",
        3,
        Base.encode16(:crypto.hash(:sha256, <<1, 2, 3>>), case: :lower),
        "reader-fault",
        actor: context.operator
      )

    Targets.append_artifact_chunk!(upload.id, 0, <<1, 2, 3>>, actor: context.operator)
    Targets.complete_artifact!(upload.id, actor: context.operator)
    reference = Targets.artifact_reference!(upload.id, context.target.id, actor: context.operator)
    request = write_request(context, "PUT", "/api/binary", nil)

    request = %{
      request
      | files: %{"payload" => reference},
        parameters: %{"method" => "PUT", "path" => "/api/binary", "body_file" => "payload"}
    }

    for phase <- [:initial, :stream], mode <- [:return, :raise, :throw] do
      before_requests = Agent.get(context.agent, & &1.requests)

      reader = fn "payload", offset ->
        if phase == :stream and offset == 0 do
          {:ok, <<1, 2>>}
        else
          if mode == :throw, do: throw(:http_input_context_throw)

          {:error, cause} =
            Skopos.Repo.query("SELECT http_input_context_unavailable", [], mode: :savepoint)

          if mode == :raise, do: raise(cause), else: {:error, cause}
        end
      end

      assert {:error, error} =
               Providers.target_effect(
                 context.method.provider_id,
                 request,
                 %{file_reader: reader},
                 actor: context.operator,
                 authorize?: false
               )

      expected_message =
        if mode == :throw, do: "http_input_context_throw", else: "http_input_context_unavailable"

      if phase == :initial do
        assert %Target.BeforeSendError{cause: cause} = Target.BeforeSendError.unwrap(error)
        assert Exception.message(cause) =~ expected_message
        assert Agent.get(context.agent, & &1.requests) == before_requests
      else
        assert Exception.message(error) =~ expected_message
        assert Target.Error.context_failure?(error)
        assert is_nil(Target.BeforeSendError.unwrap(error))

        assert Target.Error.context_progress(error) == %{
                 "input_file_id" => reference["id"],
                 "input_bytes_supplied" => 2
               }
      end
    end

    assert Agent.get(context.agent, & &1.writes) == []
  end

  @tag http_collector_fault: true
  test "a file collector context fault retains received status and pending bytes", context do
    owner = self()

    for mode <- [:raise, :throw] do
      before_writes = Agent.get(context.agent, &length(&1.writes))

      callback = fn ->
        if self() != owner and Agent.get(context.agent, &length(&1.writes)) > before_writes do
          send(owner, :http_collector_context_checked)
          if mode == :throw, do: throw(:http_collector_context_throw)

          {:error, cause} =
            Skopos.Repo.query("SELECT http_collector_context_unavailable", [], mode: :savepoint)

          raise cause
        end

        false
      end

      assert {:error, error} =
               cleared_http(context, "PUT", "/api/binary", %{
                 "body" => "plain-body",
                 "capture" => %{"duration_ms" => 500, "max_bytes" => 3}
               })
               |> Targets.dispatch_target_effect(%{cancelled?: callback},
                 actor: context.operator,
                 authorize?: false
               )

      expected_message =
        if mode == :throw,
          do: "http_collector_context_throw",
          else: "http_collector_context_unavailable"

      assert Exception.message(error) =~ expected_message
      assert Target.Error.context_failure?(error)
      assert is_nil(Target.BeforeSendError.unwrap(error))

      assert %{
               "http_status" => 200,
               "receiving_file_id" => id,
               "received_bytes" => 0,
               "pending_chunk_bytes" => 3
             } = Target.Error.context_progress(error)

      receipt = Targets.get_artifact!(id, actor: context.operator)
      assert receipt.status == :receiving
      assert receipt.received_bytes == 0
      assert Agent.get(context.agent, &length(&1.writes)) == before_writes + 1
      assert_receive :http_collector_context_checked
    end
  end

  test "a response that contradicts its content digest is not published", context do
    Agent.update(
      context.agent,
      &Map.put(&1, :content_digest, "sha-256=:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=:")
    )

    request = cleared_http(context, "GET", "/api/binary")

    assert {:error, _} =
             Targets.dispatch_target_observation(request, %{},
               actor: context.operator,
               authorize?: false
             )

    [receipt] = Targets.page_artifacts!(context.target.id, actor: context.operator).results
    assert receipt.status == :receiving
    assert is_nil(receipt.sha256)

    assert {:error, _} =
             Targets.artifact_reference(receipt.id, context.target.id, actor: context.operator)
  end

  test "a matching Content-Digest publishes the exact binary content",
       context do
    Agent.update(
      context.agent,
      &Map.put(&1, :content_digest, "sha-256=:tV8WWcBkX9HO5t+os68GeV6dp+SMtlwrmZ+JbJ9Tnb0=:")
    )

    result =
      cleared_http(context, "GET", "/api/binary")
      |> Targets.dispatch_target_observation!(%{}, actor: context.operator, authorize?: false)

    assert result.facts["file"]["sha256"] ==
             "b55f1659c0645fd1cee6dfa8b3af06795e9da7e48cb65c2b999f896c9f539dbd"
  end

  test "encoded response files retain the wire content and identify its encoding", context do
    result =
      cleared_http(context, "GET", "/api/encoded")
      |> Targets.dispatch_target_observation!(%{}, actor: context.operator, authorize?: false)

    bytes = read_file(context, result.facts["file"])
    assert result.facts["content_encoding"] == "gzip"
    assert bytes != <<255, 0, 1, 2, 255>>
    assert :zlib.gunzip(bytes) == <<255, 0, 1, 2, 255>>
    assert result.facts["file"]["size_bytes"] == byte_size(bytes)
  end

  test "an explicit byte sample preserves an exact binary prefix and its completion reason",
       context do
    result =
      cleared_http(context, "GET", "/api/binary", %{
        "capture" => %{"duration_ms" => 250, "max_bytes" => 3}
      })
      |> Targets.dispatch_target_observation!(%{}, actor: context.operator, authorize?: false)

    file = result.facts["file"]
    assert read_file(context, file) == <<255, 0, 1>>
    assert result.facts["body_truncated"]
    metadata = Targets.get_artifact!(file["id"], actor: context.operator)
    assert Map.get(metadata, :completion_reason) == :byte_limit
    assert result.facts["completion_reason"] == "byte_limit"
  end

  test "capture limits require a response file and cannot change after clearance", context do
    clearance =
      cleared_http(context, "GET", "/api/binary", %{
        "capture" => %{"duration_ms" => 500, "max_bytes" => 3}
      })

    for parameters <- [
          put_in(clearance.parameters, ["capture", "max_bytes"], 5),
          put_in(clearance.parameters, ["capture", "duration_ms"], 1_000)
        ] do
      assert {:error, _} =
               Targets.dispatch_target_observation(%{clearance | parameters: parameters}, %{},
                 actor: context.operator,
                 authorize?: false
               )
    end

    for parameters <- [
          Map.delete(clearance.parameters, "response_file"),
          put_in(clearance.parameters, ["capture", "max_bytes"], 0),
          put_in(clearance.parameters, ["capture", "duration_ms"], 0),
          put_in(clearance.parameters, ["capture", "duration_ms"], 30_001),
          put_in(clearance.parameters, ["capture", "extra"], true)
        ] do
      request = %Request{
        kind: :observation,
        authority_mode: :readonly,
        target_id: context.target.id,
        target_revision: context.target.revision,
        access_method_id: context.method.id,
        access_method_revision: context.method.revision,
        capability: "request.http.observe",
        operation: "request.observe",
        parameters: parameters
      }

      assert {:error, _} = Targets.clear_target_request(request, actor: context.operator)
    end

    assert Targets.page_artifacts!(context.target.id, actor: context.operator).results == []
  end

  test "an explicit duration sample stops a silent response and publishes only its received bytes",
       context do
    started = System.monotonic_time(:millisecond)

    result =
      cleared_http(context, "GET", "/api/idle", %{
        "capture" => %{"duration_ms" => 100, "max_bytes" => 100}
      })
      |> Targets.dispatch_target_observation!(%{}, actor: context.operator, authorize?: false)

    assert System.monotonic_time(:millisecond) - started < 500
    assert read_file(context, result.facts["file"]) == <<255, 0>>
    metadata = Targets.get_artifact!(result.facts["file"]["id"], actor: context.operator)
    assert Map.get(metadata, :completion_reason) == :duration_limit
    assert result.facts["completion_reason"] == "duration_limit"
  end

  test "a zero-event sample requires received headers and never publishes a missing response",
       context do
    result =
      cleared_http(context, "GET", "/api/zero-events", %{
        "capture" => %{"duration_ms" => 100, "max_bytes" => 100}
      })
      |> Targets.dispatch_target_observation!(%{}, actor: context.operator, authorize?: false)

    assert result.facts["status"] == 200
    assert read_file(context, result.facts["file"]) == ""
    assert result.facts["completion_reason"] == "duration_limit"

    assert {:error, _} =
             cleared_http(context, "GET", "/api/headers-idle", %{
               "capture" => %{"duration_ms" => 100, "max_bytes" => 100}
             })
             |> Targets.dispatch_target_observation(%{},
               actor: context.operator,
               authorize?: false
             )

    assert [%{status: :receiving, received_bytes: 0, sha256: nil} = incomplete | _] =
             Targets.page_artifacts!(context.target.id, actor: context.operator).results

    assert {:error, _} =
             Targets.artifact_reference(incomplete.id, context.target.id, actor: context.operator)
  end

  test "a sampled effect reply stays unknown and an early transport loss stays unpublished",
       context do
    effect =
      cleared_http(context, "PUT", "/api/binary", %{
        "body" => "whole-body",
        "capture" => %{"duration_ms" => 250, "max_bytes" => 3}
      })
      |> Targets.dispatch_target_effect!(%{}, actor: context.operator, authorize?: false)

    assert effect.status == :unknown
    assert effect.details["completion_reason"] == "byte_limit"
    assert read_file(context, effect.details["file"]) == "who"
    assert Agent.get(context.agent, & &1.writes) == ["whole-body"]

    assert {:error, _} =
             cleared_http(context, "GET", "/api/interrupted", %{
               "capture" => %{"duration_ms" => 250, "max_bytes" => 100}
             })
             |> Targets.dispatch_target_observation(%{},
               actor: context.operator,
               authorize?: false
             )

    assert [%{status: :receiving, received_bytes: 2, completion_reason: nil} = incomplete | _] =
             Targets.page_artifacts!(context.target.id, actor: context.operator).results

    assert {:error, _} =
             Targets.artifact_reference(incomplete.id, context.target.id, actor: context.operator)
  end

  test "a capture that reaches EOF validates the whole response digest", context do
    capture = %{"capture" => %{"duration_ms" => 500, "max_bytes" => 100}}

    result =
      cleared_http(context, "GET", "/api/binary", capture)
      |> Targets.dispatch_target_observation!(%{}, actor: context.operator, authorize?: false)

    assert read_file(context, result.facts["file"]) == <<255, 0, 1, 2, 255>>
    assert result.facts["completion_reason"] == "eof"
    refute result.facts["body_truncated"]

    Agent.update(
      context.agent,
      &Map.put(&1, :content_digest, "sha-256=:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=:")
    )

    assert {:error, _} =
             cleared_http(context, "GET", "/api/binary", capture)
             |> Targets.dispatch_target_observation(%{},
               actor: context.operator,
               authorize?: false
             )

    assert [%{status: :receiving, completion_reason: nil} = incomplete | _] =
             Targets.page_artifacts!(context.target.id, actor: context.operator).results

    assert {:error, _} =
             Targets.artifact_reference(incomplete.id, context.target.id, actor: context.operator)
  end

  test "clean chunked EOF publishes exact bytes and HEAD publishes an empty file", context do
    for {verb, path, size, hash} <- [
          {"GET", "/api/chunked", 5,
           "b55f1659c0645fd1cee6dfa8b3af06795e9da7e48cb65c2b999f896c9f539dbd"},
          {"HEAD", "/api/status", 0,
           "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"}
        ] do
      result =
        cleared_http(context, verb, path)
        |> Targets.dispatch_target_observation!(%{}, actor: context.operator, authorize?: false)

      assert result.facts["file"]["size_bytes"] == size
      assert result.facts["file"]["sha256"] == hash
    end
  end

  test "a file result receives the full response rather than the preview limit", context do
    result =
      cleared_http(context, "GET", "/api/large")
      |> Targets.dispatch_target_observation!(%{}, actor: context.operator, authorize?: false)

    assert result.facts["file"]["size_bytes"] == 30_000
    assert read_file(context, result.facts["file"]) == String.duplicate("x", 30_000)

    assert {:ok, _} =
             JSV.validate(
               result.facts,
               JSV.build!(hd(context.method.operation_catalog.observations).output_schema)
             )
  end

  test "overflow cannot publish bounded-looking truncated bytes", context do
    previous = Application.get_env(:skopos, :artifact_limits)
    Application.put_env(:skopos, :artifact_limits, %{chunk_bytes: 3, max_size_bytes: 4})
    on_exit(fn -> restore_limits(previous) end)

    assert {:error, _} =
             cleared_http(context, "GET", "/api/binary")
             |> Targets.dispatch_target_observation(%{},
               actor: context.operator,
               authorize?: false
             )

    [receipt] = Targets.page_artifacts!(context.target.id, actor: context.operator).results
    assert receipt.status == :receiving
    assert receipt.received_bytes <= 4
    assert is_nil(receipt.sha256)

    assert {:error, _} =
             Targets.artifact_reference(receipt.id, context.target.id, actor: context.operator)
  end

  test "an interrupted response cannot become a file or be joined to a later response", context do
    assert {:error, _} =
             cleared_http(context, "GET", "/api/interrupted")
             |> Targets.dispatch_target_observation(%{},
               actor: context.operator,
               authorize?: false
             )

    [partial] = Targets.page_artifacts!(context.target.id, actor: context.operator).results
    assert partial.status == :receiving
    assert partial.received_bytes == 2

    assert {:error, _} =
             Targets.artifact_reference(partial.id, context.target.id, actor: context.operator)

    result =
      cleared_http(context, "GET", "/api/binary")
      |> Targets.dispatch_target_observation!(%{}, actor: context.operator, authorize?: false)

    assert result.facts["file"]["id"] != partial.id
    assert read_file(context, result.facts["file"]) == <<255, 0, 1, 2, 255>>
    assert Targets.get_artifact!(partial.id, actor: context.operator).status == :receiving
  end

  test "a silent response cancels without waiting for the idle timeout or publishing its prefix",
       context do
    clearance =
      cleared_http(context, "GET", "/api/idle", %{
        "capture" => %{"duration_ms" => 1_000, "max_bytes" => 100}
      })

    invocation = %{
      cancelled?: fn -> Agent.get(context.agent, &Map.get(&1, :cancelled, false)) end
    }

    task =
      Task.async(fn ->
        Targets.dispatch_target_observation(clearance, invocation,
          actor: context.operator,
          authorize?: false
        )
      end)

    try do
      assert_receive {:idle_peer, peer}, 1_000

      receipt =
        Enum.reduce_while(1..100, nil, fn _, _ ->
          case Targets.page_artifacts!(context.target.id, actor: context.operator).results do
            [%{received_bytes: 2} = file] ->
              {:halt, file}

            _ ->
              Process.sleep(10)
              {:cont, nil}
          end
        end)

      assert receipt.status == :receiving
      Agent.update(context.agent, &Map.put(&1, :cancelled, true))
      assert {:ok, {:error, _}} = Task.yield(task, 400)
      send(peer, :finish_idle)
      assert Targets.get_artifact!(receipt.id, actor: context.operator).status == :receiving
      assert Targets.get_artifact!(receipt.id, actor: context.operator).completion_reason == nil

      assert {:error, _} =
               Targets.artifact_reference(receipt.id, context.target.id, actor: context.operator)

      assert Agent.get(context.agent, & &1.idle_calls) == 1
    after
      Task.shutdown(task, :brutal_kill)
    end
  end

  test "cancellation while awaiting headers leaves an empty receipt and permits a later request",
       context do
    clearance = cleared_http(context, "GET", "/api/headers-idle")

    invocation = %{
      cancelled?: fn -> Agent.get(context.agent, &Map.get(&1, :cancelled, false)) end
    }

    task =
      Task.async(fn ->
        Targets.dispatch_target_observation(clearance, invocation,
          actor: context.operator,
          authorize?: false
        )
      end)

    try do
      assert_receive {:idle_peer, peer}, 1_000
      Agent.update(context.agent, &Map.put(&1, :cancelled, true))
      assert {:ok, {:error, _}} = Task.yield(task, 400)
      send(peer, :finish_idle)

      assert [%{status: :receiving, received_bytes: 0} = receipt] =
               Targets.page_artifacts!(context.target.id, actor: context.operator).results

      assert {:error, _} =
               Targets.artifact_reference(receipt.id, context.target.id, actor: context.operator)

      result =
        cleared_http(context, "GET", "/api/status")
        |> Targets.dispatch_target_observation!(%{}, actor: context.operator, authorize?: false)

      assert read_file(context, result.facts["file"]) == "ready"
      assert Agent.get(context.agent, & &1.idle_calls) == 1
    after
      Task.shutdown(task, :brutal_kill)
    end
  end

  test "continuous data cannot extend the whole HTTP deadline or publish an effect reply",
       context do
    provider =
      Providers.create_provider!(
        "finite HTTP",
        :target,
        "http-api",
        %{"timeout_ms" => 250},
        %{"bearer_token" => "fixture-token"},
        actor: context.admin
      )
      |> then(&Providers.enable_provider!(&1, &1.revision, actor: context.admin))

    method =
      Targets.create_access_method!(
        context.target.id,
        provider.id,
        "finite HTTP",
        "http",
        context.endpoint,
        provider.revision,
        100,
        ["request.http.observe", "request.http.effect"],
        actor: context.admin
      )
      |> then(&Targets.check_access_method!(&1.id, &1.revision, %{}, actor: context.admin))

    context = %{context | method: method, provider: provider}
    clearance = cleared_http(context, "POST", "/api/continuous", %{"body" => "{}"})

    result =
      Targets.dispatch_target_effect!(clearance, %{}, actor: context.operator, authorize?: false)

    assert result.status == :unknown
    assert result.details["reason"] =~ "time limit"
    refute Map.has_key?(result.details, "file")

    assert [%{status: :receiving} = receipt] =
             Targets.page_artifacts!(context.target.id, actor: context.operator).results

    assert receipt.received_bytes > 0 and receipt.received_bytes < 40
    assert receipt.request_id == "http-transfer"

    assert {:error, _} =
             Targets.artifact_reference(receipt.id, context.target.id, actor: context.operator)

    assert_receive {:continuous_end, count}, 1_000
    assert count < 40
    assert Agent.get(context.agent, & &1.writes) == ["{}"]

    assert Targets.get_artifact!(receipt.id, actor: context.operator).received_bytes ==
             receipt.received_bytes
  end

  test "a non-final chunked coding preserves the close-delimited body and the next response",
       context do
    {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
    {:ok, {_address, port}} = :inet.sockname(listener)
    body = "5\r\nLEGIT\r\n0\r\n\r\nHTTP/1.1 200 OK\r\nContent-Length: 8\r\n\r\nSMUGGLED"

    peer =
      Task.async(fn ->
        for _ <- 1..3 do
          {:ok, socket} = :gen_tcp.accept(listener, 2_000)
          {:ok, request} = :gen_tcp.recv(socket, 0, 2_000)

          response =
            if String.starts_with?(request, "GET /coding "),
              do: [
                "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked, gzip\r\nConnection: close\r\n\r\n",
                body
              ],
              else: "HTTP/1.1 200 OK\r\nContent-Length: 4\r\nConnection: close\r\n\r\nREAL"

          :ok = :gen_tcp.send(socket, response)
          :gen_tcp.close(socket)
        end
      end)

    try do
      method =
        Targets.create_access_method!(
          context.target.id,
          context.provider.id,
          "HTTP response boundaries",
          "http",
          "http://127.0.0.1:#{port}",
          context.provider.revision,
          100,
          ["request.http.observe", "request.http.effect"],
          actor: context.admin
        )
        |> then(&Targets.check_access_method!(&1.id, &1.revision, %{}, actor: context.admin))

      context = %{context | method: method}

      result =
        cleared_http(context, "GET", "/coding")
        |> Targets.dispatch_target_observation!(%{}, actor: context.operator, authorize?: false)

      assert read_file(context, result.facts["file"]) == body

      subsequent =
        cleared_http(context, "GET", "/real")
        |> Targets.dispatch_target_observation!(%{}, actor: context.operator, authorize?: false)

      assert read_file(context, subsequent.facts["file"]) == "REAL"
      Task.await(peer, 2_000)
    after
      Task.shutdown(peer, :brutal_kill)
      :gen_tcp.close(listener)
    end
  end

  test "chunked response trailers validate the completed file digest", context do
    {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
    {:ok, {_address, port}} = :inet.sockname(listener)

    peer =
      Task.async(fn ->
        for _ <- 1..3 do
          {:ok, socket} = :gen_tcp.accept(listener, 2_000)
          {:ok, request} = :gen_tcp.recv(socket, 0, 2_000)

          digest =
            if String.starts_with?(request, "GET /bad "),
              do: "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=",
              else: "LPJNul+wow4m6DsqxbninhsWHlwfp0JecwQzYpOLmCQ="

          :ok =
            :gen_tcp.send(socket, [
              "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n",
              "Trailer: Content-Digest\r\n\r\n5\r\nhello\r\n0\r\n",
              "Content-Digest: sha-256=:",
              digest,
              ":\r\n\r\n"
            ])

          :gen_tcp.close(socket)
        end
      end)

    try do
      method =
        Targets.create_access_method!(
          context.target.id,
          context.provider.id,
          "HTTP trailers",
          "http",
          "http://127.0.0.1:#{port}",
          context.provider.revision,
          100,
          ["request.http.observe", "request.http.effect"],
          actor: context.admin
        )
        |> then(&Targets.check_access_method!(&1.id, &1.revision, %{}, actor: context.admin))

      context = %{context | method: method}

      result =
        cleared_http(context, "GET", "/valid")
        |> Targets.dispatch_target_observation!(%{}, actor: context.operator, authorize?: false)

      assert read_file(context, result.facts["file"]) == "hello"

      assert {:error, _} =
               cleared_http(context, "GET", "/bad")
               |> Targets.dispatch_target_observation(%{},
                 actor: context.operator,
                 authorize?: false
               )

      assert [%{status: :receiving, received_bytes: 5} = partial | _] =
               Targets.page_artifacts!(context.target.id, actor: context.operator).results

      assert {:error, _} =
               Targets.artifact_reference(partial.id, context.target.id, actor: context.operator)

      Task.await(peer, 2_000)
    after
      Task.shutdown(peer, :brutal_kill)
      :gen_tcp.close(listener)
    end
  end

  test "cancellation during the response prevents publication", context do
    invocation = %{
      cancelled?: fn -> Agent.get(context.agent, &Map.get(&1, :cancelled, false)) end
    }

    assert {:error, _} =
             cleared_http(context, "GET", "/api/cancelled")
             |> Targets.dispatch_target_observation(invocation,
               actor: context.operator,
               authorize?: false
             )

    [receipt] = Targets.page_artifacts!(context.target.id, actor: context.operator).results
    assert receipt.status == :receiving

    assert {:error, _} =
             Targets.artifact_reference(receipt.id, context.target.id, actor: context.operator)
  end

  test "a lost effect reply retains an unusable receipt and is not replayed", context do
    result =
      cleared_http(context, "POST", "/api/drop", %{"body" => "{}"})
      |> Targets.dispatch_target_effect!(%{}, actor: context.operator, authorize?: false)

    assert result.status == :unknown
    refute Map.has_key?(result.details, "file")
    assert Agent.get(context.agent, & &1.writes) == ["drop"]
    [receipt] = Targets.page_artifacts!(context.target.id, actor: context.operator).results
    assert receipt.status == :receiving
    assert result.details["reason"] =~ receipt.id
  end

  for phase <- [:begin, :append, :later_append, :complete] do
    @tag file_publication_fault: true, http_file_fault_phase: phase
    test "HTTP #{phase} file failure retains cause and known transfer facts",
         context do
      phase = context.http_file_fault_phase

      if phase == :later_append do
        previous_limits = Application.get_env(:skopos, :artifact_limits)

        Application.put_env(
          :skopos,
          :artifact_limits,
          Map.put(previous_limits || %{}, :chunk_bytes, 2)
        )

        on_exit(fn -> restore_limits(previous_limits) end)
      end

      condition =
        case phase do
          :begin -> "TRUE"
          :append -> "NEW.received_bytes <> OLD.received_bytes"
          :later_append -> "NEW.received_bytes > 2"
          :complete -> "NEW.status = 'ready'"
        end

      event = if phase == :begin, do: "INSERT", else: "UPDATE"
      # A real PostgreSQL failure at the publication boundary; assertions use public actions.
      Skopos.Repo.query!("""
      CREATE FUNCTION pg_temp.reject_http_file_ready() RETURNS trigger LANGUAGE plpgsql AS $$
      BEGIN
        IF #{condition} THEN RAISE EXCEPTION 'injected file publication failure'; END IF;
        RETURN NEW;
      END $$;
      """)

      Skopos.Repo.query!(
        "CREATE TRIGGER reject_http_file_ready BEFORE #{event} ON artifacts FOR EACH ROW EXECUTE FUNCTION pg_temp.reject_http_file_ready()"
      )

      assert {:error, error} =
               cleared_http(context, "PUT", "/api/binary", %{
                 "body" => "plain-body",
                 "capture" => %{"duration_ms" => 500, "max_bytes" => 3}
               })
               |> Targets.dispatch_target_effect(%{}, actor: context.operator, authorize?: false)

      if phase == :begin do
        assert %Target.BeforeSendError{cause: cause} = Target.BeforeSendError.unwrap(error)
        assert Exception.message(cause) =~ "injected file publication failure"
        assert Agent.get(context.agent, & &1.writes) == []

        assert Agent.get(context.agent, & &1.requests)
               |> Enum.count(&(&1 == {"PUT", "/api/binary"})) == 0
      else
        assert Exception.message(error) =~ "injected file publication failure"
        assert Agent.get(context.agent, & &1.writes) == ["plain-body"]
        [receipt] = Targets.page_artifacts!(context.target.id, actor: context.operator).results
        assert receipt.status == :receiving

        received =
          case phase do
            :append -> 0
            :later_append -> 2
            :complete -> 3
          end

        assert receipt.received_bytes == received
        assert receipt.completion_reason == nil

        expected = %{
          "http_status" => 200,
          "receiving_file_id" => receipt.id,
          "received_bytes" => received
        }

        expected =
          if phase == :append, do: Map.put(expected, "pending_chunk_bytes", 3), else: expected

        expected =
          if phase == :later_append,
            do: Map.put(expected, "pending_chunk_bytes", 1),
            else: expected

        assert Target.Error.context_progress(error) == expected

        assert {:error, _} =
                 Targets.artifact_reference(receipt.id, context.target.id,
                   actor: context.operator
                 )
      end
    end
  end

  defp read_file(context, file) do
    size = file["size_bytes"]

    Stream.unfold(0, fn
      ^size ->
        nil

      offset ->
        bytes = Targets.read_bound_artifact_chunk!(file, offset, actor: context.operator)
        {bytes, offset + byte_size(bytes)}
    end)
    |> Enum.to_list()
    |> IO.iodata_to_binary()
  end

  defp restore_limits(nil), do: Application.delete_env(:skopos, :artifact_limits)
  defp restore_limits(value), do: Application.put_env(:skopos, :artifact_limits, value)

  defp cleared_http(context, verb, path, options \\ %{}) do
    kind = if verb in ["GET", "HEAD"], do: :observation, else: :effect

    %Request{
      kind: kind,
      authority_mode: :full_access,
      target_id: context.target.id,
      target_revision: context.target.revision,
      access_method_id: context.method.id,
      access_method_revision: context.method.revision,
      capability: if(kind == :effect, do: "request.http.effect", else: "request.http.observe"),
      operation: if(kind == :effect, do: "request.execute", else: "request.observe"),
      operation_id: "http-transfer",
      idempotency_key: "http-transfer-1",
      parameters:
        Map.merge(
          %{
            "method" => verb,
            "path" => path,
            "response_file" => %{
              "name" => "response.bin",
              "media_type" => "application/octet-stream"
            }
          },
          options
        )
    }
    |> Targets.clear_target_request!(actor: context.operator)
  end

  defp read_request(context, method, path) do
    %Target.ObservationRequest{
      provider_revision: 1,
      target_id: context.target.id,
      target_revision: context.target.revision,
      access_method_id: context.method.id,
      access_method_revision: context.method.revision,
      connection: %Target.Connection{endpoint: context.endpoint},
      capability: "request.http.observe",
      operation: "request.observe",
      authorization_digest: "fixture",
      parameters: %{"method" => method, "path" => path}
    }
  end

  defp write_request(context, method, path, body) do
    %Target.EffectRequest{
      provider_revision: 1,
      target_id: context.target.id,
      target_revision: context.target.revision,
      access_method_id: context.method.id,
      access_method_revision: context.method.revision,
      connection: %Target.Connection{endpoint: context.endpoint},
      capability: "request.http.effect",
      operation: "request.execute",
      authorization_digest: "fixture",
      operation_id: "fixture",
      idempotency_key: "fixture",
      parameters: %{"method" => method, "path" => path, "body" => body}
    }
  end
end
