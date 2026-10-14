defmodule SkoposCLI.CLITest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO
  import Plug.Conn

  alias SkoposCLI.{CLI, Config}

  setup do
    root = Path.join(System.tmp_dir!(), "skopos-cli-#{System.unique_integer([:positive])}")
    config_path = Path.join(root, "config.json")
    on_exit(fn -> File.rm_rf(root) end)
    %{config_path: config_path, stub: {__MODULE__, make_ref()}}
  end

  test "prints fixed-English help" do
    assert capture_io(fn -> assert CLI.run([]) == 0 end) =~ "Output is fixed-English JSON"
  end

  test "prints the product version" do
    assert capture_io(fn -> assert CLI.run(["--version"]) == 0 end) ==
             "skopos 0.1.1\n"
  end

  test "rejects an unknown command" do
    assert capture_io(:stderr, fn -> assert CLI.run(["unknown"]) == 2 end) ==
             "Unknown or incomplete command. Run skopos --help for usage.\n"
  end

  test "browser login stores a private session without printing its token", context do
    browser_login = fn client, timeout, open_browser, listen ->
      assert client.server == "https://skopos.example"
      assert timeout == 42_000
      assert is_function(open_browser, 1)
      assert is_function(listen, 2)

      {:ok, "browser-product-session", %{"id" => "account-1", "role" => "admin"}}
    end

    output =
      capture_io(fn ->
        assert CLI.run(
                 ["auth", "login", "--server", "https://skopos.example", "--timeout", "42"],
                 runtime(context) ++ [browser_login: browser_login]
               ) == 0
      end)

    refute output =~ "browser-product-session"
    assert output =~ "account-1"

    assert {:ok,
            %{
              "server" => "https://skopos.example",
              "token" => "browser-product-session"
            }} =
             Config.load(context.config_path)

    assert %{mode: 0o100600} = File.stat!(context.config_path)
    assert %{mode: 0o40700} = File.stat!(Path.dirname(context.config_path))

    shown = capture_io(fn -> assert CLI.run(["config", "show"], runtime(context)) == 0 end)
    assert shown =~ ~s("authenticated": true)
    refute shown =~ "session-token"
  end

  test "changing the server clears its session without changing an existing parent mode",
       context do
    parent = Path.dirname(context.config_path)
    File.mkdir_p!(parent)
    File.chmod!(parent, 0o755)
    save_session(context)

    capture_io(fn ->
      assert CLI.run(
               ["config", "set-server", "https://replacement.example"],
               runtime(context)
             ) == 0
    end)

    assert {:ok, %{"server" => "https://replacement.example"}} =
             Config.load(context.config_path)

    assert %{mode: 0o40755} = File.stat!(parent)
  end

  test "wraps resource input and sends bearer authentication", context do
    save_session(context)

    Req.Test.stub(context.stub, fn conn ->
      assert conn.method == "POST"
      assert conn.request_path == "/api/v1/targets"
      assert get_req_header(conn, "authorization") == ["Bearer saved-token"]
      {:ok, encoded, conn} = read_body(conn)

      assert Jason.decode!(encoded) == %{
               "target" => %{
                 "name" => "edge-1",
                 "kind" => "network_device",
                 "type_id" => "cisco_ios_xe"
               }
             }

      conn
      |> put_status(201)
      |> Req.Test.json(%{data: %{id: "target-1", revision: 1}})
    end)

    input = ~s({"name":"edge-1","kind":"network_device","type_id":"cisco_ios_xe"})

    output =
      capture_io(input, fn ->
        assert CLI.run(["target", "create", "--input", "-"], runtime(context)) == 0
      end)

    assert output =~ ~s("outcome": "succeeded")
    assert output =~ "target-1"
  end

  test "creates an Access Method with its Provider profile method", context do
    save_session(context)

    Req.Test.stub(context.stub, fn conn ->
      assert conn.method == "POST"
      assert conn.request_path == "/api/v1/access-methods"
      assert get_req_header(conn, "authorization") == ["Bearer saved-token"]
      {:ok, encoded, conn} = read_body(conn)

      assert Jason.decode!(encoded) == %{
               "access_method" => %{
                 "target_id" => "target-1",
                 "provider_id" => "provider-1",
                 "name" => "Redfish",
                 "method" => "redfish",
                 "endpoint" => "https://bmc.example.test/redfish/v1",
                 "provider_revision" => 1,
                 "capabilities" => ["observe.power"]
               }
             }

      conn
      |> put_status(201)
      |> Req.Test.json(%{data: %{id: "method-1", revision: 1}})
    end)

    input =
      Jason.encode!(%{
        name: "Redfish",
        target_id: "target-1",
        provider_id: "provider-1",
        method: "redfish",
        endpoint: "https://bmc.example.test/redfish/v1",
        provider_revision: 1,
        capabilities: ["observe.power"]
      })

    output =
      capture_io(input, fn ->
        assert CLI.run(["access-method", "create", "--input", "-"], runtime(context)) == 0
      end)

    assert output =~ "method-1"
  end

  test "configures AI usage through the connection API", context do
    save_session(context)

    Req.Test.stub(context.stub, fn conn ->
      assert conn.method == "PUT"
      assert conn.request_path == "/api/v1/providers/ai-1/ai-usage"
      {:ok, encoded, conn} = read_body(conn)

      assert Jason.decode!(encoded) == %{
               "usage" => %{
                 "scope" => "all",
                 "priority" => 10,
                 "expected_resolver_revision" => 2,
                 "expected_reviewer_revision" => 1
               }
             }

      send_resp(conn, 204, "")
    end)

    input =
      ~s({"scope":"all","priority":10,"expected_resolver_revision":2,"expected_reviewer_revision":1})

    output =
      capture_io(input, fn ->
        assert CLI.run(["provider", "usage", "ai-1", "--input", "-"], runtime(context)) == 0
      end)

    assert output =~ ~s("outcome": "succeeded")

    for action <- ["create", "update"] do
      assert capture_io(:stderr, fn ->
               assert CLI.run(["ai-role", action, "ai-1"], runtime(context)) == 2
             end) =~ "Unknown or incomplete command"
    end
  end

  test "lists AI services through the same authenticated catalog as Web", context do
    save_session(context)

    Req.Test.stub(context.stub, fn conn ->
      assert conn.method == "GET"
      assert conn.request_path == "/api/v1/ai-services"
      assert get_req_header(conn, "authorization") == ["Bearer saved-token"]
      Req.Test.json(conn, %{data: [%{id: "ollama", name: "Ollama", auth: "none"}]})
    end)

    output =
      capture_io(fn ->
        assert CLI.run(["provider", "services"], runtime(context)) == 0
      end)

    assert output =~ ~s("id": "ollama")
  end

  test "lists Target types through the authenticated catalog", context do
    save_session(context)

    Req.Test.stub(context.stub, fn conn ->
      assert conn.method == "GET"
      assert conn.request_path == "/api/v1/target-types"
      assert get_req_header(conn, "authorization") == ["Bearer saved-token"]

      Req.Test.json(conn, %{
        data: %{
          categories: [%{id: "network-device", label: "Network device"}],
          types: [%{id: "custom-network-device", category_id: "network-device"}]
        }
      })
    end)

    output = capture_io(fn -> assert CLI.run(["target-type", "list"], runtime(context)) == 0 end)
    assert output =~ ~s("custom-network-device")
    assert output =~ ~s("network-device")
  end

  test "passes pagination without changing the shared API contract", context do
    save_session(context)

    Req.Test.stub(context.stub, fn conn ->
      assert conn.method == "GET"
      assert conn.request_path == "/api/v1/cases"
      assert URI.decode_query(conn.query_string) == %{"after" => "cursor-value", "limit" => "7"}
      Req.Test.json(conn, %{data: [], page: %{next: nil}})
    end)

    output =
      capture_io(fn ->
        assert CLI.run(
                 ["case", "list", "--limit", "7", "--after", "cursor-value"],
                 runtime(context)
               ) == 0
      end)

    assert output =~ ~s("outcome": "succeeded")
  end

  test "Case invocation history preserves unavailable tokens through authenticated public paging",
       context do
    save_session(context)

    Req.Test.stub(context.stub, fn conn ->
      assert conn.method == "GET"
      assert conn.request_path == "/api/v1/cases/case-1/ai-invocations"
      assert get_req_header(conn, "authorization") == ["Bearer saved-token"]
      assert URI.decode_query(conn.query_string) == %{"after" => "cursor-value", "limit" => "7"}

      Req.Test.json(conn, %{
        data: [
          %{
            usage_status: "unknown",
            input_tokens: nil,
            output_tokens: nil,
            reserved_units: 65_536
          },
          %{
            status: "queued",
            usage_status: "not_dispatched",
            dispatch_confirmed: false,
            dispatch_started_at: nil,
            input_tokens: nil,
            output_tokens: nil
          }
        ],
        page: %{next: nil}
      })
    end)

    output =
      capture_io(fn ->
        assert CLI.run(
                 ["case", "ai-invocations", "case-1", "--limit", "7", "--after", "cursor-value"],
                 runtime(context)
               ) == 0
      end)
      |> Jason.decode!()

    assert [
             %{
               "usage_status" => "unknown",
               "input_tokens" => nil,
               "output_tokens" => nil,
               "reserved_units" => 65_536
             },
             %{
               "status" => "queued",
               "usage_status" => "not_dispatched",
               "dispatch_confirmed" => false,
               "dispatch_started_at" => nil,
               "input_tokens" => nil,
               "output_tokens" => nil
             }
           ] = output["data"]
  end

  test "Case show preserves reported usage and unknown budget bounds without client accounting",
       context do
    save_session(context)

    Req.Test.stub(context.stub, fn conn ->
      assert conn.method == "GET"
      assert conn.request_path == "/api/v1/cases/case-1"
      assert get_req_header(conn, "authorization") == ["Bearer saved-token"]

      Req.Test.json(conn, %{
        data: %{
          case: %{status: "resolved"},
          ai_usage: %{
            reported_total_tokens: 26,
            budget_charged_units: 65_562,
            unknown_invocations: 1,
            unknown_reserved_units: 65_536,
            complete: false
          }
        }
      })
    end)

    output =
      capture_io(fn ->
        assert CLI.run(["case", "show", "case-1"], runtime(context)) == 0
      end)
      |> Jason.decode!()

    assert %{
             "reported_total_tokens" => 26,
             "budget_charged_units" => 65_562,
             "unknown_invocations" => 1,
             "unknown_reserved_units" => 65_536,
             "complete" => false
           } =
             output["data"]["ai_usage"]
  end

  test "Case cancel and resume commands send transition requests to the public API", context do
    save_session(context)

    Req.Test.stub(context.stub, fn conn ->
      assert conn.method == "POST"
      assert get_req_header(conn, "authorization") == ["Bearer saved-token"]
      {:ok, encoded, conn} = read_body(conn)

      case conn.request_path do
        "/api/v1/cases/case-1/cancel" ->
          assert Jason.decode!(encoded) == %{"case" => %{"expected_revision" => 2}}
          Req.Test.json(conn, %{data: %{id: "case-1", status: "cancelled"}})

        "/api/v1/cases/case-1/resume" ->
          assert Jason.decode!(encoded) == %{"case" => %{"expected_case_revision" => 3}}
          Req.Test.json(conn, %{data: %{id: "case-1", status: "running"}})
      end
    end)

    cancelled =
      capture_io(~s({"expected_revision":2}), fn ->
        assert CLI.run(["case", "cancel", "case-1", "--input", "-"], runtime(context)) == 16
      end)

    resumed =
      capture_io(~s({"expected_case_revision":3}), fn ->
        assert CLI.run(["case", "resume", "case-1", "--input", "-"], runtime(context)) == 0
      end)

    assert cancelled =~ ~s("outcome": "cancel_requested")
    assert resumed =~ ~s("outcome": "succeeded")
  end

  test "reads a Case Report as text and requests a UTC period summary", context do
    save_session(context)

    Req.Test.stub(context.stub, fn conn ->
      assert conn.method == "GET"
      assert get_req_header(conn, "authorization") == ["Bearer saved-token"]

      case conn.request_path do
        "/api/v1/reports/report-1" ->
          Req.Test.json(conn, %{data: %{document: %{text: "Case result\nNot established"}}})

        "/api/v1/reports/operations-summary" ->
          assert URI.decode_query(conn.query_string) == %{
                   "from" => "2026-09-01T00:00:00Z",
                   "to" => "2026-10-01T00:00:00Z",
                   "target_id" => "target-1"
                 }

          Req.Test.json(conn, %{data: %{case_count: 2, audit_count: 1}})
      end
    end)

    report_text =
      capture_io(fn -> assert CLI.run(["report", "read", "report-1"], runtime(context)) == 0 end)

    assert report_text == "Case result\nNot established\n"

    summary =
      capture_io(fn ->
        assert CLI.run(
                 [
                   "report",
                   "summary",
                   "--from",
                   "2026-09-01T00:00:00Z",
                   "--to",
                   "2026-10-01T00:00:00Z",
                   "--target-id",
                   "target-1"
                 ],
                 runtime(context)
               ) == 0
      end)

    assert summary =~ ~s("case_count": 2)
    assert summary =~ ~s("audit_count": 1)
  end

  test "a new process resumes a case by id using read-only polling", context do
    save_session(context)
    {:ok, counter} = Agent.start_link(fn -> 0 end)

    Req.Test.stub(context.stub, fn conn ->
      assert conn.method == "GET"
      assert conn.request_path == "/api/v1/cases/case-1"
      attempt = Agent.get_and_update(counter, fn value -> {value, value + 1} end)

      if attempt == 0 do
        Req.Test.json(conn, case_snapshot("running", [%{"status" => "running"}], []))
      else
        Req.Test.json(conn, case_snapshot("resolved", [%{"status" => "completed"}], []))
      end
    end)

    output =
      capture_io(fn ->
        assert CLI.run(
                 ["case", "wait", "case-1", "--interval", "50", "--timeout", "2"],
                 runtime(context)
               ) == 0
      end)

    assert output =~ ~s("outcome": "resolved")
    assert Agent.get(counter, & &1) == 2
  end

  test "case polling distinguishes accepted, approval, attention and cancellation", context do
    save_session(context)

    scenarios = [
      {"accepted", case_snapshot("running", [], []), 10},
      {"approval_required",
       case_snapshot("running", [%{"status" => "running"}], [], false, "decision_required"), 11},
      {"resolving",
       case_snapshot("running", [%{"status" => "running"}], [%{"status" => "awaiting_human"}]),
       10},
      {"needs_attention", case_snapshot("needs_attention", [], []), 12},
      {"cancel_requested", case_snapshot("running", [], [], true), 16}
    ]

    Enum.each(scenarios, fn {expected, response, exit_code} ->
      Req.Test.stub(context.stub, fn conn -> Req.Test.json(conn, response) end)

      output =
        capture_io(fn ->
          assert CLI.run(["case", "wait", "case-1", "--timeout", "0"], runtime(context)) ==
                   exit_code
        end)

      assert output =~ ~s("outcome": "#{expected}")
    end)
  end

  test "operation polling distinguishes active and terminal outcomes", context do
    save_session(context)

    for {status, expected, exit_code} <- [
          {"queued", "accepted", 10},
          {"dispatching", "resolving", 10},
          {"applied", "resolved", 0},
          {"failed", "failed", 13},
          {"partial", "partial", 14},
          {"unknown", "unknown", 15}
        ] do
      Req.Test.stub(context.stub, fn conn ->
        assert conn.method == "GET"
        Req.Test.json(conn, %{data: %{id: "operation-1", status: status}})
      end)

      output =
        capture_io(fn ->
          assert CLI.run(
                   ["operation", "wait", "operation-1", "--timeout", "0"],
                   runtime(context)
                 ) == exit_code
        end)

      assert output =~ ~s("outcome": "#{expected}")
    end
  end

  test "an accepted notification delivery is a completed typed result", context do
    save_session(context)

    Req.Test.stub(context.stub, fn conn ->
      Req.Test.json(conn, %{data: %{id: "delivery-1", status: "accepted"}})
    end)

    output =
      capture_io(fn ->
        assert CLI.run(
                 ["delivery", "wait", "delivery-1", "--timeout", "2"],
                 runtime(context)
               ) == 10
      end)

    assert output =~ ~s("outcome": "accepted")
  end

  test "logout revokes the server session and removes only the local token", context do
    save_session(context)

    Req.Test.stub(context.stub, fn conn ->
      assert conn.method == "DELETE"
      assert get_req_header(conn, "authorization") == ["Bearer saved-token"]
      send_resp(conn, 204, "")
    end)

    capture_io(fn -> assert CLI.run(["auth", "logout"], runtime(context)) == 0 end)
    assert {:ok, %{"server" => "https://skopos.example"}} = Config.load(context.config_path)
  end

  test "Audit deactivation retains original identity on HTTP and transport errors without replay",
       context do
    save_session(context)
    owner = self()
    id = "20000000-0000-4000-8000-000000000074"
    input = Jason.encode!(%{"expected_revision" => 7})

    for {status, expected_exit, outcome} <- [
          {409, 4, "failed"},
          {403, 4, "failed"},
          {503, 15, "unknown"},
          {:transport, 5, "unknown"}
        ] do
      Req.Test.stub(context.stub, fn conn ->
        send(owner, {:deactivation_send, conn.method, conn.request_path})

        if status == :transport do
          Req.Test.transport_error(conn, :timeout)
        else
          conn
          |> put_resp_content_type("application/json")
          |> send_resp(status, Jason.encode!(%{"error" => %{"message" => "Controlled failure"}}))
        end
      end)

      result =
        capture_io(:stderr, fn ->
          capture_io([input: input], fn ->
            assert CLI.run(["audit", "deactivate", id, "--input", "-"], runtime(context)) ==
                     expected_exit
          end)
        end)
        |> Jason.decode!()

      assert %{"outcome" => ^outcome, "audit_schedule_id" => ^id, "expected_revision" => 7} =
               result

      assert_receive {:deactivation_send, "POST", path}
      assert path == "/api/v1/audit-schedules/#{id}/deactivate"
      refute_receive {:deactivation_send, _, _}, 0
    end
  end

  test "returns typed authentication and transport failures", context do
    save_session(context)

    Req.Test.stub(context.stub, fn conn ->
      conn
      |> put_status(401)
      |> Req.Test.json(%{error: %{code: "invalid_session", message: "Session is invalid"}})
    end)

    authentication_error =
      capture_io(:stderr, fn ->
        assert CLI.run(["auth", "status"], runtime(context)) == 3
      end)

    assert authentication_error =~ "invalid_session"

    Req.Test.stub(context.stub, fn conn -> Req.Test.transport_error(conn, :timeout) end)

    transport_error =
      capture_io(:stderr, fn ->
        assert CLI.run(["auth", "status"], runtime(context)) == 5
      end)

    assert transport_error =~ "transport_error"
    assert transport_error =~ ~s("outcome":"unknown")
  end

  defp runtime(context) do
    [config_path: context.config_path, request_options: [plug: {Req.Test, context.stub}]]
  end

  defp save_session(context) do
    :ok =
      Config.save(
        %{"server" => "https://skopos.example", "token" => "saved-token"},
        context.config_path
      )
  end

  defp case_snapshot(
         status,
         runs,
         proposals,
         cancel_requested \\ false,
         operator_action \\ "none"
       ) do
    %{
      data: %{
        case: %{
          id: "case-1",
          status: status,
          cancel_requested: cancel_requested,
          operator_action: operator_action
        },
        resolution_runs: runs,
        proposals: proposals,
        operations: [],
        verification_attempts: []
      }
    }
  end
end
