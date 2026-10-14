defmodule Skopos.Targets.KubernetesSessionTest do
  use Skopos.DataCase, async: false

  alias Skopos.{Accounts, Providers, Targets}
  alias Skopos.Targets.TargetRequest.Request

  @namespace "bounded-namespace"
  @capabilities ["request.kubernetes.observe", "request.kubernetes.effect"]

  defmodule Socket do
    @behaviour WebSock
    def init(agent), do: {:push, {:ping, "native-ping"}, agent}

    def handle_in({bytes, opcode: opcode}, agent) do
      Agent.update(agent, &Map.update!(&1, :frames, fn frames -> frames ++ [{opcode, bytes}] end))

      case bytes do
        <<0, "finish">> ->
          {:stop, :normal, 1_000, {opcode, bytes}, agent}

        <<0, "drop">> ->
          Process.exit(self(), :kill)

        <<0, "status">> ->
          {:push, [{opcode, bytes}, {:binary, <<3, "native-exit-status">>}], agent}

        <<0, "delayed">> ->
          Process.sleep(60)
          {:push, {opcode, bytes}, agent}

        _ ->
          {:push, {opcode, bytes}, agent}
      end
    end

    def handle_info(_, agent), do: {:ok, agent}

    def handle_control({_bytes, opcode: :pong}, agent) do
      Agent.update(agent, &Map.put(&1, :pong_received, true))
      {:ok, agent}
    end

    def handle_control(_, agent), do: {:ok, agent}
    def terminate(reason, agent), do: Agent.update(agent, &Map.put(&1, :closed, reason))
  end

  defmodule Peer do
    import Plug.Conn
    def init(agent), do: agent

    def call(conn, agent) do
      if get_req_header(conn, "authorization") == ["Bearer static-test-token"] do
        case conn.request_path do
          "/api" ->
            conn
            |> put_resp_content_type("application/json")
            |> send_resp(200, ~s({"kind":"APIVersions","versions":["v1"]}))

          _ ->
            Agent.update(
              agent,
              &Map.update!(&1, :requests, fn requests ->
                requests ++
                  [
                    %{
                      path: conn.request_path,
                      query: conn.query_string,
                      protocols: get_req_header(conn, "sec-websocket-protocol")
                    }
                  ]
              end)
            )

            conn
            |> put_resp_header("sec-websocket-protocol", Agent.get(agent, & &1.protocol))
            |> WebSockAdapter.upgrade(Socket, agent, [])
            |> halt()
        end
      else
        send_resp(conn, 401, "unauthorized")
      end
    end
  end

  setup tags do
    agent =
      start_supervised!(
        {Agent,
         fn ->
           %{requests: [], frames: [], closed: nil, pong_received: false, protocol: "test.raw.v1"}
         end}
      )

    scheme = Map.get(tags, :scheme, :https)
    options = [plug: {Peer, agent}, scheme: scheme, port: 0, startup_log: false]

    options =
      if scheme == :https,
        do:
          options ++
            [
              certfile: Path.expand("test/support/certs/kubernetes_fixture.pem"),
              keyfile: Path.expand("test/support/certs/kubernetes_fixture_key.pem")
            ],
        else: options

    server = start_supervised!({Bandit, options})

    {:ok, {_, port}} = ThousandIsland.listener_info(server)
    endpoint = "#{scheme}://127.0.0.1:#{port}"
    password = "correct horse battery staple"
    admin = Accounts.bootstrap!("kube-session-admin@example.com", password, password)

    operator =
      Accounts.create_user!("kube-session-operator@example.com", password, :operator,
        actor: admin
      )

    certificate = File.read!("test/support/certs/kubernetes_fixture_ca.pem") |> Base.encode64()

    kubeconfig = """
    apiVersion: v1
    kind: Config
    clusters:
      - name: target
        cluster:
          server: #{endpoint}
          certificate-authority-data: #{certificate}
    users:
      - name: operator
        user:
          token: static-test-token
    contexts:
      - name: target
        context:
          cluster: target
          user: operator
    current-context: target
    """

    provider =
      Providers.create_provider!(
        "session-api",
        :target,
        "kubernetes-api",
        %{"namespace" => @namespace, "request_timeout_ms" => 1_000},
        %{"kubeconfig" => kubeconfig},
        actor: admin
      )

    assert {:ok, _} = Skopos.TargetConnectionFixture.check_connection(provider, endpoint, admin)

    target =
      Targets.create_target!("session-cluster", "cluster", "kubernetes", %{}, nil, actor: admin)

    method =
      Targets.create_access_method!(
        target.id,
        provider.id,
        "session-api",
        "api",
        endpoint,
        provider.revision,
        100,
        @capabilities,
        actor: admin
      )
      |> then(&Targets.check_access_method!(&1.id, &1.revision, %{}, actor: admin))

    %{agent: agent, operator: operator, admin: admin, method: method, target: target}
  end

  test "checked Method exchanges exact non-Pod API frames and repeated query values", context do
    bytes = <<0, 255, 0, 128, 3, 4>>

    request =
      request(context, %{
        "path" => "/apis/example.com/v1/namespaces/#{@namespace}/streams/one/connect",
        "query" => %{"argument" => ["first", "second argument"], "stdin" => "true"},
        "protocols" => ["test.raw.v1"],
        "steps" => [
          %{"op" => "send", "opcode" => "binary", "data" => Base.encode64(bytes)},
          %{"op" => "receive", "count" => 1},
          %{"op" => "send", "opcode" => "text", "data" => Base.encode64("resize")},
          %{"op" => "receive", "count" => 1},
          %{"op" => "close"}
        ]
      })

    clearance = Targets.clear_target_request!(request, actor: context.operator)

    operation =
      Enum.find(context.method.operation_catalog.effects, &(&1.operation == "websocket.session"))

    assert {:ok, schema} = JSV.build(operation.input_schema, warnings: :silent)

    assert {:ok, _} =
             JSV.validate(%{"selectors" => %{}, "parameters" => request.parameters}, schema,
               cast: false
             )

    result =
      Targets.dispatch_target_effect!(clearance, %{}, actor: context.operator, authorize?: false)

    assert result.status == :applied, inspect(result)
    assert result.details["protocol"] == "test.raw.v1"
    assert result.details["completion_reason"] == "sequence_complete"

    assert [%{"opcode" => "binary", "data" => encoded}] =
             result.details["steps"] |> Enum.at(1) |> Map.fetch!("frames")

    assert Base.decode64!(encoded) == bytes

    assert [%{"opcode" => "text", "data" => text}] =
             result.details["steps"] |> Enum.at(3) |> Map.fetch!("frames")

    assert Base.decode64!(text) == "resize"
    peer = Agent.get(context.agent, & &1)
    assert peer.frames == [{:binary, bytes}, {:text, "resize"}]
    assert [remote] = peer.requests
    assert remote.path == request.parameters["path"]

    assert URI.query_decoder(remote.query) |> Enum.filter(&(elem(&1, 0) == "argument")) == [
             {"argument", "first"},
             {"argument", "second argument"}
           ]

    assert remote.protocols == ["test.raw.v1"]
  end

  @tag websocket_context_fault: true
  test "initial WebSocket context faults keep the original cause without an upgrade", context do
    input =
      request(context, %{
        "path" => "/api/v1/namespaces/#{@namespace}/pods/one/exec",
        "protocols" => ["test.raw.v1"],
        "steps" => [%{"op" => "close"}]
      })

    clearance = Targets.clear_target_request!(input, actor: context.operator)

    for {message, callback} <- [
          {"websocket_initial_context_unavailable",
           fn ->
             {:error, cause} =
               Skopos.Repo.query("SELECT websocket_initial_context_unavailable", [],
                 mode: :savepoint
               )

             raise cause
           end},
          {"websocket_context_throw", fn -> throw(:websocket_context_throw) end}
        ] do
      assert {:error, error} =
               Targets.dispatch_target_effect(clearance, %{cancelled?: callback},
                 actor: context.operator,
                 authorize?: false
               )

      assert %Skopos.Providers.Target.BeforeSendError{cause: cause} =
               Skopos.Providers.Target.BeforeSendError.unwrap(error)

      assert Exception.message(cause) =~ message
      assert Agent.get(context.agent, & &1.requests) == []
    end
  end

  @tag websocket_fresh_send: true
  test "a later WebSocket send checks fresh context and preserves the preceding native reply",
       context do
    input =
      request(context, %{
        "path" => "/apis/example.com/v1/namespaces/#{@namespace}/streams/one/connect",
        "protocols" => ["test.raw.v1"],
        "steps" => [
          %{"op" => "send", "opcode" => "binary", "data" => Base.encode64(<<0, "first">>)},
          %{
            "op" => "receive",
            "count" => 1,
            "response_file" => %{
              "name" => "first-reply.bin",
              "media_type" => "application/octet-stream"
            }
          },
          %{"op" => "send", "opcode" => "binary", "data" => Base.encode64(<<0, "second">>)},
          %{"op" => "close"}
        ]
      })

    clearance = Targets.clear_target_request!(input, actor: context.operator)

    before_send? = fn ->
      receipts = Targets.page_artifacts!(context.target.id, actor: context.operator).results

      if Enum.any?(receipts, &(&1.name == "first-reply.bin" and &1.status == :ready)) do
        {:error, cause} =
          Skopos.Repo.query("SELECT websocket_followup_context_unavailable", [], mode: :savepoint)

        raise cause
      end

      false
    end

    assert {:error, error} =
             Targets.dispatch_target_effect(
               clearance,
               %{before_send?: before_send?, cancelled?: fn -> false end},
               actor: context.operator,
               authorize?: false
             )

    assert Exception.message(error) =~ "websocket_followup_context_unavailable"
    assert Skopos.Providers.Target.Error.context_failure?(error)
    assert is_nil(Skopos.Providers.Target.BeforeSendError.unwrap(error))

    assert %{"bytes_sent" => 6, "bytes_received" => 6, "steps" => [sent, received]} =
             Skopos.Providers.Target.Error.context_progress(error)

    assert sent["op"] == "send"
    assert received["frames"] == [%{"opcode" => "binary", "offset" => 0, "size_bytes" => 6}]
    assert read_file(received["file"], context.operator) == <<0, "first">>
    assert Agent.get(context.agent, & &1.frames) == [{:binary, <<0, "first">>}]
  end

  for mode <- [:postgres, :missing_record] do
    @tag websocket_context_fault: true
    test "WebSocket retains a native reply during #{mode} context failure", context do
      input =
        request(context, %{
          "path" => "/apis/example.com/v1/namespaces/#{@namespace}/streams/one/connect",
          "protocols" => ["test.raw.v1"],
          "steps" => [
            %{"op" => "send", "opcode" => "binary", "data" => Base.encode64(<<0, "delayed">>)},
            %{"op" => "receive", "count" => 2},
            %{"op" => "close"}
          ]
        })

      clearance = Targets.clear_target_request!(input, actor: context.operator)
      owner = self()

      callback = fn ->
        if Agent.get(context.agent, &(&1.frames != [] and &1.pong_received)) do
          send(owner, :websocket_reply_stop_check)
          Process.sleep(120)

          {:error, cause} =
            case unquote(mode) do
              :postgres ->
                Skopos.Repo.query("SELECT websocket_reply_context_unavailable", [],
                  mode: :savepoint
                )

              :missing_record ->
                Targets.get_target("00000000-0000-0000-0000-000000000000",
                  actor: context.operator
                )
            end

          raise cause
        end

        false
      end

      assert {:error, error} =
               Targets.dispatch_target_effect(clearance, %{cancelled?: callback},
                 actor: context.operator,
                 authorize?: false
               )

      case unquote(mode) do
        :postgres ->
          assert Exception.message(error) =~ "websocket_reply_context_unavailable"

        :missing_record ->
          assert %Ash.Error.Invalid{} = error
          assert Exception.message(error) =~ "record not found"
      end

      assert Skopos.Providers.Target.Error.context_failure?(error)
      assert is_nil(Skopos.Providers.Target.BeforeSendError.unwrap(error))

      assert %{"bytes_sent" => 8, "bytes_received" => 8, "current_step" => %{"frames" => [frame]}} =
               Skopos.Providers.Target.Error.context_progress(error)

      assert frame == %{"opcode" => "binary", "data" => Base.encode64(<<0, "delayed">>)}
      assert_receive :websocket_reply_stop_check
      assert Agent.get(context.agent, & &1.frames) == [{:binary, <<0, "delayed">>}]
    end
  end

  test "peer cannot choose a subprotocol outside the reviewed request", context do
    Agent.update(context.agent, &Map.put(&1, :protocol, "unrequested.protocol"))

    request =
      request(context, %{
        "path" => "/api/v1/namespaces/#{@namespace}/pods/one/exec",
        "protocols" => ["test.raw.v1"],
        "steps" => [
          %{"op" => "send", "opcode" => "binary", "data" => Base.encode64(<<0, 42>>)},
          %{"op" => "close"}
        ]
      })

    clearance = Targets.clear_target_request!(request, actor: context.operator)

    result =
      Targets.dispatch_target_effect!(clearance, %{}, actor: context.operator, authorize?: false)

    assert result.status == :unknown
    assert result.details["completion_reason"] == "upgrade_rejected"
    assert Agent.get(context.agent, & &1.frames) == []
  end

  test "remote close retains preceding frames and completes the bounded session", context do
    request =
      request(context, %{
        "path" => "/api/v1/namespaces/#{@namespace}/pods/one/attach",
        "protocols" => ["test.raw.v1"],
        "steps" => [
          %{"op" => "send", "opcode" => "binary", "data" => Base.encode64(<<0, "finish">>)},
          %{"op" => "receive", "until_close" => true, "max_frames" => 4},
          %{"op" => "close"}
        ]
      })

    clearance = Targets.clear_target_request!(request, actor: context.operator)

    result =
      Targets.dispatch_target_effect!(clearance, %{}, actor: context.operator, authorize?: false)

    assert result.status == :applied, inspect(result)

    assert Enum.at(result.details["steps"], 1)["frames"] == [
             %{"opcode" => "binary", "data" => Base.encode64(<<0, "finish">>)}
           ]

    assert Enum.at(result.details["steps"], 2)["code"] == 1_000
  end

  test "authorized files stream as prefixed binary frames and retain output boundaries",
       context do
    bytes = :binary.copy(<<255, 0, 128, 1>>, 10_000)
    hash = :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)

    upload =
      Targets.begin_artifact!(
        context.target.id,
        "source.bin",
        "application/octet-stream",
        byte_size(bytes),
        hash,
        "session-upload",
        actor: context.operator
      )

    Targets.append_artifact_chunk!(upload.id, 0, binary_part(bytes, 0, 20_000),
      actor: context.operator
    )

    Targets.append_artifact_chunk!(upload.id, 20_000, binary_part(bytes, 20_000, 20_000),
      actor: context.operator
    )

    Targets.complete_artifact!(upload.id, actor: context.operator)
    source = Targets.artifact_reference!(upload.id, context.target.id, actor: context.operator)

    request =
      request(context, %{
        "path" => "/api/v1/namespaces/#{@namespace}/pods/one/exec",
        "protocols" => ["test.raw.v1"],
        "max_bytes" => 50_000,
        "files" => %{"input" => source},
        "steps" => [
          %{"op" => "send", "body_file" => "input", "prefix" => Base.encode64(<<0>>)},
          %{
            "op" => "receive",
            "count" => 2,
            "response_file" => %{
              "name" => "raw-output.bin",
              "media_type" => "application/octet-stream"
            }
          },
          %{"op" => "close"}
        ]
      })

    clearance = Targets.clear_target_request!(request, actor: context.operator)

    result =
      Targets.dispatch_target_effect!(clearance, %{}, actor: context.operator, authorize?: false)

    assert result.status == :applied, inspect(result)
    received = Enum.at(result.details["steps"], 1)

    assert received["frames"] == [
             %{"opcode" => "binary", "offset" => 0, "size_bytes" => 20_001},
             %{"opcode" => "binary", "offset" => 20_001, "size_bytes" => 20_001}
           ]

    file = received["file"]
    assert file["target_id"] == context.target.id
    assert file["size_bytes"] == 40_002
    captured = read_file(file, context.operator)

    assert captured ==
             <<0>> <> binary_part(bytes, 0, 20_000) <> <<0>> <> binary_part(bytes, 20_000, 20_000)

    assert file["sha256"] == :crypto.hash(:sha256, captured) |> Base.encode16(case: :lower)
    assert result.details["bytes_sent"] == 40_002
    assert result.details["bytes_received"] == 40_002
    assert byte_size(Jason.encode!(result.details)) < 65_536
  end

  test "timeout retains an incomplete receive and never replays the effect", context do
    request =
      request(context, %{
        "path" => "/api/v1/namespaces/#{@namespace}/pods/one/exec",
        "protocols" => ["test.raw.v1"],
        "steps" => [
          %{"op" => "send", "opcode" => "binary", "data" => Base.encode64(<<0, "one">>)},
          %{"op" => "receive", "count" => 2},
          %{"op" => "close"}
        ]
      })

    clearance = Targets.clear_target_request!(request, actor: context.operator)

    result =
      Targets.dispatch_target_effect!(clearance, %{}, actor: context.operator, authorize?: false)

    assert result.status == :unknown
    assert result.details["completion_reason"] == "duration_limit"
    assert result.details["bytes_sent"] == 4
    assert result.details["bytes_received"] == 4

    assert result.details["current_step"]["frames"] == [
             %{"opcode" => "binary", "data" => Base.encode64(<<0, "one">>)}
           ]

    assert Agent.get(context.agent, & &1.frames) == [{:binary, <<0, "one">>}]
  end

  test "readonly, downgraded, ungranted and stale requests stop before upgrade", context do
    valid =
      request(context, %{
        "path" => "/api/v1/namespaces/#{@namespace}/pods/one/exec",
        "protocols" => ["test.raw.v1"],
        "steps" => [%{"op" => "close"}]
      })

    assert {:error, _} =
             Targets.clear_target_request(%{valid | kind: :observation}, actor: context.operator)

    readonly =
      Targets.clear_target_request!(%{valid | authority_mode: :readonly}, actor: context.operator)

    assert {:error, _} =
             Targets.dispatch_target_effect(readonly, %{},
               actor: context.operator,
               authorize?: false
             )

    current = Targets.clear_target_request!(valid, actor: context.operator)

    method =
      Targets.update_access_method!(
        context.method,
        context.method.revision,
        %{capabilities: ["request.kubernetes.observe"]},
        actor: context.admin
      )

    assert {:error, _} =
             Targets.dispatch_target_effect(current, %{},
               actor: context.operator,
               authorize?: false
             )

    method = Targets.check_access_method!(method.id, method.revision, %{}, actor: context.admin)

    assert {:error, _} =
             Targets.clear_target_request(%{valid | access_method_revision: method.revision},
               actor: context.operator
             )

    assert Agent.get(context.agent, & &1.requests) == []
  end

  test "noncanonical paths and unbounded or malformed frame plans stop before upgrade", context do
    base = %{
      "path" => "/api/v1/namespaces/#{@namespace}/pods/one/exec",
      "protocols" => ["test.raw.v1"],
      "steps" => [%{"op" => "close"}]
    }

    invalid = [
      Map.put(base, "path", "https://unregistered.invalid/api/v1/pods/one/exec"),
      Map.put(base, "path", "/api/v1/namespaces/another/pods/one/exec"),
      Map.put(base, "path", "/api/v1/namespaces/#{@namespace}/pods/../exec"),
      Map.put(base, "path", "/api/v1/namespaces/#{@namespace}/pods/%2e%2e/exec"),
      Map.put(base, "path", base["path"] <> "?command=unexpected"),
      Map.put(base, "protocols", ["bad\r\nprotocol"]),
      Map.put(base, "query", %{"command" => ["good", 7]}),
      Map.put(base, "steps", [
        %{"op" => "send", "opcode" => "binary", "data" => "invalid!"},
        %{"op" => "close"}
      ]),
      Map.put(base, "steps", [
        %{"op" => "send", "opcode" => "text", "data" => Base.encode64(<<255>>)},
        %{"op" => "close"}
      ]),
      Map.put(base, "steps", [%{"op" => "send", "opcode" => "binary", "data" => ""}]),
      Map.put(
        base,
        "steps",
        List.duplicate(%{"op" => "receive", "count" => 64}, 5) ++ [%{"op" => "close"}]
      )
    ]

    for parameters <- invalid do
      assert {:error, _} =
               Targets.clear_target_request(request(context, parameters), actor: context.operator)
    end

    assert Agent.get(context.agent, & &1.requests) == []
  end

  for phase <- [:begin, :append, :complete] do
    @tag websocket_file_fault: true
    test "WebSocket #{phase} receipt failure retains its cause and dispatch facts", context do
      # Native database fault fixture; the operation and receipt are inspected through actions.
      condition =
        case unquote(phase) do
          :begin -> "TRUE"
          :append -> "NEW.received_bytes <> OLD.received_bytes"
          :complete -> "NEW.status = 'ready'"
        end

      event = if unquote(phase) == :begin, do: "INSERT", else: "UPDATE"

      Skopos.Repo.query!("""
      CREATE FUNCTION pg_temp.reject_session_progress() RETURNS trigger LANGUAGE plpgsql AS $$
      BEGIN
        IF #{condition} THEN
          RAISE EXCEPTION 'injected WebSocket receipt progress failure';
        END IF;
        RETURN NEW;
      END;
      $$;
      """)

      Skopos.Repo.query!(
        "CREATE TRIGGER reject_session_progress BEFORE #{event} ON artifacts FOR EACH ROW EXECUTE FUNCTION pg_temp.reject_session_progress()"
      )

      try do
        request =
          request(context, %{
            "path" => "/api/v1/namespaces/#{@namespace}/pods/one/exec",
            "protocols" => ["test.raw.v1"],
            "steps" => [
              %{"op" => "send", "opcode" => "binary", "data" => Base.encode64(<<0, "once">>)},
              %{
                "op" => "receive",
                "count" => 1,
                "response_file" => %{
                  "name" => "failed.bin",
                  "media_type" => "application/octet-stream"
                }
              },
              %{"op" => "close"}
            ]
          })

        clearance = Targets.clear_target_request!(request, actor: context.operator)

        assert {:error, error} =
                 Targets.dispatch_target_effect(clearance, %{},
                   actor: context.operator,
                   authorize?: false
                 )

        if unquote(phase) == :begin do
          assert %Skopos.Providers.Target.BeforeSendError{} =
                   before_send = Skopos.Providers.Target.BeforeSendError.unwrap(error)

          assert Exception.message(before_send.cause) =~
                   "injected WebSocket receipt progress failure"

          assert Skopos.Providers.Target.BeforeSendError.retryable?(before_send)
          assert Agent.get(context.agent, & &1.requests) == []
          assert Agent.get(context.agent, & &1.frames) == []
        else
          assert Exception.message(error) =~ "injected WebSocket receipt progress failure"
          progress = Skopos.Providers.Target.Error.context_progress(error)
          assert progress["bytes_sent"] == 5
          assert progress["bytes_received"] == 5

          receipt =
            Targets.get_artifact!(progress["current_step"]["receiving_file_id"],
              actor: context.operator
            )

          assert receipt.status == :receiving
          assert receipt.received_bytes == if(unquote(phase) == :complete, do: 5, else: 0)

          assert {:error, _} =
                   Targets.artifact_reference(receipt.id, context.target.id,
                     actor: context.operator
                   )

          assert Agent.get(context.agent, & &1.frames) == [{:binary, <<0, "once">>}]
        end
      after
        Skopos.Repo.query!("DROP TRIGGER reject_session_progress ON artifacts")
      end
    end
  end

  test "cancellation before and after remote send cannot become success", context do
    request =
      request(context, %{
        "path" => "/api/v1/namespaces/#{@namespace}/pods/one/exec",
        "protocols" => ["test.raw.v1"],
        "steps" => [
          %{"op" => "send", "opcode" => "binary", "data" => Base.encode64(<<0, "one">>)},
          %{"op" => "receive", "count" => 1},
          %{"op" => "close"}
        ]
      })

    clearance = Targets.clear_target_request!(request, actor: context.operator)

    assert {:error, _} =
             Targets.dispatch_target_effect(clearance, %{cancelled?: fn -> true end},
               actor: context.operator,
               authorize?: false
             )

    assert Agent.get(context.agent, & &1.requests) == []
    cancelled = fn -> Agent.get(context.agent, &(&1.frames != [])) end

    result =
      Targets.dispatch_target_effect!(clearance, %{cancelled?: cancelled},
        actor: context.operator,
        authorize?: false
      )

    assert result.status == :unknown
    assert result.details["completion_reason"] == "cancelled"
    assert result.details["bytes_sent"] == 4
    assert Agent.get(context.agent, & &1.frames) == [{:binary, <<0, "one">>}]
  end

  @tag capture_log: true
  test "lost native connection after send remains unknown and is not replayed", context do
    request =
      request(context, %{
        "path" => "/api/v1/namespaces/#{@namespace}/pods/one/exec",
        "protocols" => ["test.raw.v1"],
        "steps" => [
          %{"op" => "send", "opcode" => "binary", "data" => Base.encode64(<<0, "drop">>)},
          %{"op" => "receive", "count" => 1},
          %{"op" => "close"}
        ]
      })

    clearance = Targets.clear_target_request!(request, actor: context.operator)

    result =
      Targets.dispatch_target_effect!(clearance, %{}, actor: context.operator, authorize?: false)

    assert result.status == :unknown
    assert result.details["completion_reason"] == "disconnected"
    assert result.details["bytes_sent"] == 5
    assert Agent.get(context.agent, & &1.frames) == [{:binary, <<0, "drop">>}]
    assert length(Agent.get(context.agent, & &1.requests)) == 1
  end

  test "a frame arriving after the requested receive remains available at close", context do
    request =
      request(context, %{
        "path" => "/api/v1/namespaces/#{@namespace}/pods/one/exec",
        "protocols" => ["test.raw.v1"],
        "steps" => [
          %{"op" => "send", "opcode" => "binary", "data" => Base.encode64(<<0, "status">>)},
          %{"op" => "receive", "count" => 1},
          %{"op" => "close"}
        ]
      })

    clearance = Targets.clear_target_request!(request, actor: context.operator)

    result =
      Targets.dispatch_target_effect!(clearance, %{}, actor: context.operator, authorize?: false)

    assert [%{"opcode" => "binary", "data" => status}] = result.details["buffered_frames"]
    assert Base.decode64!(status) == <<3, "native-exit-status">>
  end

  @tag scheme: :http
  test "session honors the explicitly registered HTTP API endpoint", context do
    request =
      request(context, %{
        "path" => "/api/v1/namespaces/#{@namespace}/pods/one/exec",
        "protocols" => ["test.raw.v1"],
        "steps" => [
          %{"op" => "send", "opcode" => "binary", "data" => Base.encode64(<<0, "http">>)},
          %{"op" => "receive", "count" => 1},
          %{"op" => "close"}
        ]
      })

    clearance = Targets.clear_target_request!(request, actor: context.operator)

    result =
      Targets.dispatch_target_effect!(clearance, %{}, actor: context.operator, authorize?: false)

    assert result.status == :applied, inspect(result)
    assert result.details["http_status"] == 101
    assert Agent.get(context.agent, & &1.frames) == [{:binary, <<0, "http">>}]
  end

  defp read_file(file, actor) do
    file
    |> Skopos.Providers.Target.FileWriter.stream(
      &(Targets.read_bound_artifact_chunk!(file, &1, actor: actor)
        |> then(fn bytes -> {:ok, bytes} end))
    )
    |> Enum.to_list()
    |> IO.iodata_to_binary()
  end

  defp request(context, parameters) do
    struct!(Request,
      kind: :effect,
      authority_mode: :full_access,
      target_id: context.target.id,
      target_revision: context.target.revision,
      access_method_id: context.method.id,
      access_method_revision: context.method.revision,
      capability: "request.kubernetes.effect",
      operation: "websocket.session",
      selectors: %{},
      parameters: parameters,
      operation_id: "session-#{System.unique_integer()}",
      idempotency_key: "session-key-#{System.unique_integer()}"
    )
  end
end
