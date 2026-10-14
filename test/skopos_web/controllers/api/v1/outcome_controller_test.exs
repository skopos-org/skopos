defmodule SkoposWeb.API.V1.OutcomeControllerTest do
  use SkoposWeb.ConnCase, async: false

  import OpenApiSpex.TestAssertions
  import ExUnit.CaptureIO
  import ExUnit.CaptureLog

  alias Skopos.{Accounts, Audits, Cases, Notifications, Providers, Reports, Signals, Targets}
  alias Skopos.Notifications.Delivery.Dispatch
  alias Skopos.Providers.Notification
  alias Skopos.Providers.Signal

  @password "correct horse battery staple"

  setup do
    admin =
      Accounts.bootstrap!("outcome-api-admin@example.com", @password, @password, authorize?: true)

    operator =
      Accounts.create_user!("outcome-api-operator@example.com", @password, :operator,
        actor: admin
      )

    viewer =
      Accounts.create_user!("outcome-api-viewer@example.com", @password, :viewer, actor: admin)

    %{
      admin: admin,
      operator: operator,
      viewer: viewer,
      admin_token: token!(admin.email),
      operator_token: token!(operator.email),
      viewer_token: token!(viewer.email)
    }
  end

  @tag audit_registration: true
  test "caller identity locates the exact Audit schedule without permitting an overwrite",
       context do
    boundary =
      Targets.create_management_boundary!("registered-audit-boundary", "datacenter", %{},
        actor: context.admin
      )

    id = "20000000-0000-4000-8000-000000000051"

    input = %{"audit_schedule" => audit_registration(boundary.id, id)}

    created = post_json("/api/v1/audit-schedules", input, context.admin_token)
    assert %{"data" => %{"id" => ^id, "revision" => 1}} = json_response(created, 201)
    assert_operation_response(created)

    for token <- [context.admin_token, context.operator_token, context.viewer_token] do
      selected = get_json("/api/v1/audit-schedules/#{id}", token)

      assert %{"data" => %{"id" => ^id, "name" => "Original audit"}} =
               json_response(selected, 200)

      assert_operation_response(selected)
    end

    conflicting = put_in(input, ["audit_schedule", "name"], "Different audit")

    assert %{"error" => %{"code" => "conflict"}} =
             post_json("/api/v1/audit-schedules", conflicting, context.admin_token)
             |> json_response(409)

    assert %{"data" => %{"name" => "Original audit", "revision" => 1}} =
             get_json("/api/v1/audit-schedules/#{id}", context.admin_token) |> json_response(200)
  end

  @tag audit_registration: true
  test "Audit registration requires a valid original identity and current creation authority",
       context do
    boundary =
      Targets.create_management_boundary!("unregistered-audit-boundary", "datacenter", %{},
        actor: context.admin
      )

    id = "20000000-0000-4000-8000-000000000052"
    input = audit_registration(boundary.id, id)

    for {invalid, status} <- [
          {Map.delete(input, "registration_id"), 400},
          {%{input | "registration_id" => "not-a-uuid"}, 422},
          {%{input | "registration_id" => nil}, 422}
        ] do
      assert %{"error" => _} =
               post_json(
                 "/api/v1/audit-schedules",
                 %{"audit_schedule" => invalid},
                 context.admin_token
               )
               |> json_response(status)
    end

    for token <- [context.operator_token, context.viewer_token] do
      assert %{"error" => %{"code" => "forbidden"}} =
               post_json("/api/v1/audit-schedules", %{"audit_schedule" => input}, token)
               |> json_response(403)
    end

    assert %{"error" => %{"code" => "not_found"}} =
             get_json("/api/v1/audit-schedules/#{id}", context.admin_token) |> json_response(404)
  end

  @tag audit_registration: true
  test "Audit creation rejects inactive and unavailable scope without saving the chosen identity",
       context do
    boundary =
      Targets.create_management_boundary!("inactive-audit-boundary", "datacenter", %{},
        actor: context.admin
      )

    target =
      Targets.create_target!("inactive-audit-target", "host", "linux", %{}, nil,
        actor: context.admin
      )

    Targets.deactivate_target!(target, target.revision, actor: context.admin)
    Targets.deactivate_management_boundary!(boundary, boundary.revision, actor: context.admin)

    for {target_ids, boundary_id, message} <- [
          {[target.id], nil, "Audit Target is inactive"},
          {[Ash.UUID.generate()], nil, "Audit Target is unavailable"},
          {[], boundary.id, "Management boundary is inactive"},
          {[], Ash.UUID.generate(), "Management boundary is unavailable"}
        ] do
      id = Ash.UUID.generate()

      input =
        audit_registration(boundary_id, id)
        |> Map.put("target_ids", target_ids)

      assert {:error, %Ash.Error.Invalid{} = domain_error} =
               Audits.schedule_audit(
                 id,
                 input["name"],
                 input["desired_outcome"],
                 input["timezone"],
                 input["cron_expression"],
                 input["report_language"],
                 target_ids,
                 boundary_id,
                 actor: context.admin
               )

      assert Exception.message(domain_error) =~ message

      rejected =
        post_json("/api/v1/audit-schedules", %{"audit_schedule" => input}, context.admin_token)

      assert %{
               "error" => %{
                 "code" => "validation_failed",
                 "details" => %{"fields" => ["schedule"]}
               }
             } =
               json_response(rejected, 422)

      assert_operation_response(rejected)

      assert %{"error" => %{"code" => "not_found"}} =
               get_json("/api/v1/audit-schedules/#{id}", context.admin_token)
               |> json_response(404)
    end
  end

  @tag audit_registration: true
  test "Audit scope storage failure remains an internal error rather than an absent scope",
       context do
    boundary =
      Targets.create_management_boundary!("scope-storage-boundary", "datacenter", %{},
        actor: context.admin
      )

    target =
      Targets.create_target!("scope-storage-target", "host", "linux", %{}, nil,
        actor: context.admin
      )

    for {table, target_ids, boundary_id} <- [
          {"targets", [target.id], nil},
          {"management_boundaries", [], boundary.id}
        ] do
      id = Ash.UUID.generate()

      input =
        audit_registration(boundary_id, id)
        |> Map.put("target_ids", target_ids)

      Skopos.Repo.query!("ALTER TABLE #{table} RENAME COLUMN active TO unavailable_active")

      try do
        capture_log(fn ->
          assert %{"error" => %{"code" => "internal_error"}} =
                   post_json(
                     "/api/v1/audit-schedules",
                     %{"audit_schedule" => input},
                     context.admin_token
                   )
                   |> json_response(500)
        end)
      after
        Skopos.Repo.query!("ALTER TABLE #{table} RENAME COLUMN unavailable_active TO active")
      end

      assert %{"error" => %{"code" => "not_found"}} =
               get_json("/api/v1/audit-schedules/#{id}", context.admin_token)
               |> json_response(404)
    end
  end

  @tag audit_registration: true
  test "Audit schedule and wake job storage failures cannot leave an accepted schedule",
       context do
    boundary =
      Targets.create_management_boundary!("failed-audit-boundary", "datacenter", %{},
        actor: context.admin
      )

    Skopos.Repo.query!("""
    CREATE FUNCTION pg_temp.reject_audit_registration() RETURNS trigger LANGUAGE plpgsql AS $$
    BEGIN RAISE EXCEPTION 'audit registration storage unavailable'; END;
    $$
    """)

    for table <- ["audit_schedules", "oban_jobs"] do
      id = Ash.UUID.generate()
      input = %{"audit_schedule" => audit_registration(boundary.id, id)}

      Skopos.Repo.query!(
        "CREATE TRIGGER reject_audit_registration BEFORE INSERT ON #{table} FOR EACH ROW EXECUTE FUNCTION pg_temp.reject_audit_registration()"
      )

      try do
        capture_log(fn ->
          assert %{"error" => %{"code" => "internal_error"}} =
                   post_json("/api/v1/audit-schedules", input, context.admin_token)
                   |> json_response(500)
        end)
      after
        Skopos.Repo.query!("DROP TRIGGER IF EXISTS reject_audit_registration ON #{table}")
      end

      assert %{"error" => %{"code" => "not_found"}} =
               get_json("/api/v1/audit-schedules/#{id}", context.admin_token)
               |> json_response(404)
    end
  end

  @tag audit_registration: true
  test "Audit registration rejects a wake job acknowledgement without a saved job", context do
    boundary =
      Targets.create_management_boundary!("missing-job-audit-boundary", "datacenter", %{},
        actor: context.admin
      )

    id = "20000000-0000-4000-8000-000000000054"
    input = %{"audit_schedule" => audit_registration(boundary.id, id)}

    Skopos.Repo.query!("""
    CREATE FUNCTION pg_temp.omit_audit_wake_job() RETURNS trigger LANGUAGE plpgsql AS $$
    BEGIN RETURN NULL; END;
    $$
    """)

    Skopos.Repo.query!(
      "CREATE TRIGGER omit_audit_wake_job BEFORE INSERT ON oban_jobs FOR EACH ROW EXECUTE FUNCTION pg_temp.omit_audit_wake_job()"
    )

    try do
      assert %{"error" => %{"code" => "internal_error"}} =
               post_json("/api/v1/audit-schedules", input, context.admin_token)
               |> json_response(500)
    after
      Skopos.Repo.query!("DROP TRIGGER omit_audit_wake_job ON oban_jobs")
    end

    assert %{"error" => %{"code" => "not_found"}} =
             get_json("/api/v1/audit-schedules/#{id}", context.admin_token) |> json_response(404)
  end

  @tag audit_registration: true
  test "CLI retains chosen and generated Audit identities after commit response loss without replay",
       context do
    boundary =
      Targets.create_management_boundary!("lost-audit-boundary", "datacenter", %{},
        actor: context.admin
      )

    root =
      Path.join(System.tmp_dir!(), "audit-registration-cli-#{System.unique_integer([:positive])}")

    config_path = Path.join(root, "config.json")

    :ok =
      SkoposCLI.Config.save(
        %{"server" => "https://skopos.example", "token" => context.admin_token},
        config_path
      )

    on_exit(fn -> File.rm_rf(root) end)
    owner = self()
    stub = {__MODULE__, make_ref()}

    Req.Test.stub(stub, fn conn ->
      send(owner, {:audit_request, conn.method})
      result = SkoposWeb.Endpoint.call(conn, SkoposWeb.Endpoint.init([]))

      if conn.method == "POST" do
        assert result.status == 201
        send(owner, {:accepted_audit, Jason.decode!(result.resp_body)["data"]["id"]})

        %{
          result
          | status: 503,
            resp_body:
              Jason.encode!(%{
                "error" => %{"code" => "response_lost", "message" => "Response lost after commit"}
              })
        }
      else
        result
      end
    end)

    runtime = [config_path: config_path, request_options: [plug: {Req.Test, stub}]]
    chosen_id = "20000000-0000-4000-8000-000000000053"

    for id <- [chosen_id, nil] do
      input =
        audit_registration(boundary.id, id)
        |> Map.put("name", if(id, do: "Original audit", else: "Generated audit"))

      input = if id, do: input, else: Map.delete(input, "registration_id")

      lost =
        capture_io(:stderr, fn ->
          capture_io([input: Jason.encode!(input)], fn ->
            assert SkoposCLI.CLI.run(["audit", "schedule", "--input", "-"], runtime) == 15
          end)
        end)
        |> String.split("\n", trim: true)
        |> Enum.map(&Jason.decode!/1)

      [prepared, lost] = lost
      assert prepared["event"] == "registration_prepared"

      assert %{"outcome" => "unknown", "registration_id" => retained_id} = lost
      assert prepared["registration_id"] == retained_id
      if id, do: assert(retained_id == chosen_id)
      assert_receive {:accepted_audit, ^retained_id}
      assert_receive {:audit_request, "POST"}

      recovered =
        capture_io(fn ->
          assert SkoposCLI.CLI.run(["audit", "show", retained_id], runtime) == 0
        end)
        |> Jason.decode!()

      assert %{"data" => %{"id" => ^retained_id, "revision" => 1}} = recovered
      assert recovered["data"]["name"] == input["name"]
      assert_receive {:audit_request, "GET"}
      refute_receive {:audit_request, "POST"}, 0
    end
  end

  @tag registration_process: true
  test "a killed CLI retains its generated registration identity before the committed acknowledgement",
       context do
    boundary =
      Targets.create_management_boundary!("process-receipt", "datacenter", %{},
        actor: context.admin
      )

    owner = self()

    plug = fn conn, _opts ->
      send(owner, {:registration_request, conn.method})

      conn =
        Plug.Conn.register_before_send(conn, fn result ->
          if conn.method == "POST" and result.status == 201 do
            id = Jason.decode!(result.resp_body)["data"]["id"]
            send(owner, {:registration_committed, id, self()})
            receive do: (:release_ack -> :ok)
          end

          result
        end)

      SkoposWeb.Endpoint.call(conn, SkoposWeb.Endpoint.init([]))
    end

    server =
      start_supervised!({Bandit, plug: plug, ip: {127, 0, 0, 1}, port: 0, startup_log: false})

    {:ok, {_address, port}} = ThousandIsland.listener_info(server)

    root =
      Path.join(System.tmp_dir!(), "cli-process-receipt-#{System.unique_integer([:positive])}")

    config_path = Path.join(root, "config.json")

    :ok =
      SkoposCLI.Config.save(
        %{"server" => "http://127.0.0.1:#{port}", "token" => context.admin_token},
        config_path
      )

    on_exit(fn -> File.rm_rf(root) end)
    executable = System.find_executable("elixir")

    # The packaged client excludes server dependencies. A child with the test
    # application's code paths would hide accidental Ash/Ecto calls in the CLI.
    assert {_output, 0} =
             System.cmd("mix", ["compile", "--warnings-as-errors"],
               env: [{"MIX_ENV", "cli"}, {"ERL_FLAGS", "+S 2:2"}],
               stderr_to_stdout: true
             )

    paths = Path.wildcard("_build/cli/lib/*/ebin") |> Enum.flat_map(&["-pa", Path.expand(&1)])

    script =
      "Application.ensure_all_started(:req); [config | args] = System.argv(); System.halt(SkoposCLI.CLI.run(args, config_path: config))"

    for {command, input, read_command} <- [
          {["provider", "create"],
           %{
             "name" => "Process provider",
             "kind" => "notification",
             "adapter_type" => "fixture-notification",
             "configuration" => %{"destination" => "reachable"},
             "credentials" => %{"token" => "private-process-secret"}
           }, ["provider", "show"]},
          {["audit", "schedule"],
           Map.delete(audit_registration(boundary.id, nil), "registration_id"), ["audit", "show"]}
        ] do
      input_path = Path.join(root, "input.json")
      File.write!(input_path, Jason.encode!(input))
      args = paths ++ ["-e", script, "--", config_path] ++ command ++ ["--input", input_path]

      child =
        Port.open({:spawn_executable, executable}, [
          :binary,
          :exit_status,
          :stderr_to_stdout,
          args: args,
          env: [{~c"ERL_FLAGS", ~c"+S 2:2"}]
        ])

      {:os_pid, child_pid} = Port.info(child, :os_pid)

      on_exit(fn ->
        if Port.info(child),
          do: System.cmd("kill", ["-KILL", to_string(child_pid)], stderr_to_stdout: true)
      end)

      assert_receive {^child, {:data, prepared}}, 10_000

      assert %{"event" => "registration_prepared", "registration_id" => id} =
               Jason.decode!(prepared)

      refute prepared =~ "private-process-secret"
      assert_receive {:registration_committed, ^id, handler}, 5_000
      assert_receive {:registration_request, "POST"}
      assert System.cmd("kill", ["-KILL", to_string(child_pid)]) == {"", 0}
      assert_receive {^child, {:exit_status, _status}}, 5_000
      send(handler, :release_ack)

      {output, 0} =
        System.cmd(executable, paths ++ ["-e", script, "--", config_path] ++ read_command ++ [id],
          env: [{"ERL_FLAGS", "+S 2:2"}]
        )

      assert %{"data" => %{"id" => ^id, "revision" => 1}} = Jason.decode!(output)
      assert_receive {:registration_request, "GET"}

      broken_output_script =
        String.replace(
          script,
          "System.halt(",
          "Process.unregister(:standard_error); System.halt("
        )

      assert {"", 4} =
               System.cmd(
                 executable,
                 paths ++
                   ["-e", broken_output_script, "--", config_path] ++
                   command ++ ["--input", input_path],
                 env: [{"ERL_FLAGS", "+S 2:2"}]
               )

      refute_receive {:registration_request, "POST"}, 0
      refute_receive {:registration_committed, _, _}, 0
    end
  end

  @tag audit_deactivation: true
  test "Audit deactivation authorization, revision and storage faults cannot fabricate an inactive result",
       context do
    boundary =
      Targets.create_management_boundary!("deactivation-fault-boundary", "datacenter", %{},
        actor: context.admin
      )

    id = "20000000-0000-4000-8000-000000000073"

    post_data!(
      "/api/v1/audit-schedules",
      %{"audit_schedule" => audit_registration(boundary.id, id)},
      context.admin_token
    )

    path = "/api/v1/audit-schedules/#{id}/deactivate"
    input = %{"audit_schedule" => %{"expected_revision" => 1}}

    for token <- [context.operator_token, context.viewer_token] do
      assert %{"error" => %{"code" => "forbidden"}} =
               post_json(path, input, token) |> json_response(403)
    end

    assert %{"error" => %{"code" => "conflict"}} =
             post_json(
               path,
               %{"audit_schedule" => %{"expected_revision" => 2}},
               context.admin_token
             )
             |> json_response(409)

    Skopos.Repo.query!("""
    CREATE FUNCTION pg_temp.reject_audit_deactivation() RETURNS trigger LANGUAGE plpgsql AS $$
    BEGIN RAISE EXCEPTION 'audit deactivation storage unavailable'; END;
    $$
    """)

    Skopos.Repo.query!(
      "CREATE TRIGGER reject_audit_deactivation BEFORE UPDATE ON audit_schedules FOR EACH ROW EXECUTE FUNCTION pg_temp.reject_audit_deactivation()"
    )

    try do
      capture_log(fn ->
        assert %{"error" => %{"code" => "internal_error"}} =
                 post_json(path, input, context.admin_token) |> json_response(500)
      end)
    after
      Skopos.Repo.query!("DROP TRIGGER reject_audit_deactivation ON audit_schedules")
    end

    for token <- [context.admin_token, context.operator_token, context.viewer_token] do
      current = get_json("/api/v1/audit-schedules/#{id}", token)

      assert %{"data" => %{"id" => ^id, "active" => true, "revision" => 1}} =
               json_response(current, 200)

      assert_operation_response(current)
    end
  end

  @tag audit_deactivation: true
  test "actual CLI confirms the original inactive Audit after commit response loss without replay",
       context do
    boundary =
      Targets.create_management_boundary!("deactivation-lost-boundary", "datacenter", %{},
        actor: context.admin
      )

    id = "20000000-0000-4000-8000-000000000074"

    post_data!(
      "/api/v1/audit-schedules",
      %{"audit_schedule" => audit_registration(boundary.id, id)},
      context.admin_token
    )

    root =
      Path.join(System.tmp_dir!(), "audit-deactivation-#{System.unique_integer([:positive])}")

    config_path = Path.join(root, "config.json")

    :ok =
      SkoposCLI.Config.save(
        %{"server" => "https://skopos.example", "token" => context.admin_token},
        config_path
      )

    on_exit(fn -> File.rm_rf(root) end)
    owner = self()
    stub = {__MODULE__, make_ref()}

    Req.Test.stub(stub, fn conn ->
      send(owner, {:audit_deactivation_request, conn.method, conn.request_path})
      result = SkoposWeb.Endpoint.call(conn, SkoposWeb.Endpoint.init([]))

      if conn.method == "POST" do
        assert result.status == 200

        assert %{"data" => %{"id" => ^id, "active" => false, "revision" => 2}} =
                 Jason.decode!(result.resp_body)

        %{
          result
          | status: 503,
            resp_body:
              Jason.encode!(%{
                "error" => %{"code" => "response_lost", "message" => "Response lost after commit"}
              })
        }
      else
        result
      end
    end)

    runtime = [config_path: config_path, request_options: [plug: {Req.Test, stub}]]
    input = Jason.encode!(%{"expected_revision" => 1})

    lost =
      capture_io(:stderr, fn ->
        capture_io([input: input], fn ->
          assert SkoposCLI.CLI.run(["audit", "deactivate", id, "--input", "-"], runtime) == 15
        end)
      end)
      |> Jason.decode!()

    assert %{"outcome" => "unknown", "audit_schedule_id" => ^id, "expected_revision" => 1} = lost
    assert_receive {:audit_deactivation_request, "POST", path}
    assert path == "/api/v1/audit-schedules/#{id}/deactivate"

    recovered =
      capture_io(fn ->
        assert SkoposCLI.CLI.run(["audit", "show", id], runtime) == 0
      end)
      |> Jason.decode!()

    assert %{"data" => %{"id" => ^id, "active" => false, "revision" => 2}} = recovered
    assert_receive {:audit_deactivation_request, "GET", read_path}
    assert read_path == "/api/v1/audit-schedules/#{id}"
    refute_receive {:audit_deactivation_request, "POST", _}, 0
  end

  @tag audit_summaries: true
  test "Audit metadata cursors reach schedule and run 51 while selected scope and diagnostics stay on exact reads",
       context do
    boundary =
      Targets.create_management_boundary!(
        "audit-summary-boundary",
        "datacenter",
        %{"private" => "boundary-facts"},
        actor: context.admin
      )

    target =
      Targets.create_target!("audit-summary-target", "host", "linux", %{}, nil,
        actor: context.admin
      )

    schedules =
      for n <- 1..51 do
        post_data!(
          "/api/v1/audit-schedules",
          %{
            "audit_schedule" => %{
              "registration_id" => Ash.UUID.generate(),
              "name" => "Audit summary #{n}",
              "desired_outcome" => "Boundary health is normal",
              "timezone" => "Etc/UTC",
              "cron_expression" => "0 * * * *",
              "report_language" => "en",
              "management_boundary_id" => if(n == 1, do: nil, else: boundary.id),
              "target_ids" => if(n == 1, do: [target.id], else: [])
            }
          },
          context.admin_token
        )
      end

    schedule = List.last(schedules)

    runs =
      for n <- 1..51 do
        Audits.create_audit_run_record!(
          %{
            audit_schedule_id: schedule["id"],
            schedule_revision: 1,
            target_key: "fixture-target-#{n}",
            scheduled_for: DateTime.add(~U[2026-10-05 01:00:00Z], n),
            status: if(n == 51, do: :queued, else: :failed),
            reason: if(n == 51, do: nil, else: "Selected diagnosis #{n}"),
            completed_at: if(n == 51, do: nil, else: ~U[2026-10-05 02:00:00Z])
          },
          authorize?: false
        )
      end

    first = get_json("/api/v1/audit-schedules/summaries", context.viewer_token)
    first_page = json_response(first, 200)
    assert_operation_response(first)
    assert length(first_page["data"]) == 50
    assert hd(first_page["data"])["id"] == schedule["id"]

    for row <- first_page["data"] do
      refute Map.has_key?(row, "desired_outcome")
      refute Map.has_key?(row, "target_ids")
      assert row["management_boundary_id"] == boundary.id
    end

    tail =
      get_json(
        "/api/v1/audit-schedules/summaries?after=#{URI.encode_www_form(first_page["page"]["next"])}",
        context.viewer_token
      )

    assert %{"data" => [%{"id" => tail_id}], "page" => %{"next" => nil}} =
             json_response(tail, 200)

    assert tail_id == hd(schedules)["id"]
    assert_operation_response(tail)
    selected = get_data!("/api/v1/audit-schedules/#{tail_id}", context.viewer_token)
    assert selected["desired_outcome"] == "Boundary health is normal"
    assert selected["target_ids"] == [target.id]

    first_runs = get_json("/api/v1/audit-runs/summaries", context.viewer_token)
    run_page = json_response(first_runs, 200)
    assert_operation_response(first_runs)
    assert length(run_page["data"]) == 50
    assert hd(run_page["data"])["id"] == List.last(runs).id

    for row <- run_page["data"] do
      refute Map.has_key?(row, "reason")
      assert row["status"] == if(row["id"] == List.last(runs).id, do: "queued", else: "failed")
      assert row["audit_schedule_id"] == schedule["id"]
    end

    run_tail =
      get_json(
        "/api/v1/audit-runs/summaries?after=#{URI.encode_www_form(run_page["page"]["next"])}",
        context.viewer_token
      )

    assert %{"data" => [%{"id" => run_tail_id}], "page" => %{"next" => nil}} =
             json_response(run_tail, 200)

    assert run_tail_id == hd(runs).id

    assert get_data!("/api/v1/audit-runs/#{run_tail_id}", context.viewer_token)["reason"] ==
             "Selected diagnosis 1"

    incident =
      Cases.open_case!(
        :manual,
        "fixture",
        "audit-summary-case",
        "Audit follow-up",
        :warning,
        %{"desired_outcome" => "Infrastructure health is normal"},
        nil,
        :en,
        actor: context.operator
      )

    linked_run = List.last(runs)

    Audits.record_audit_run_outcome!(
      linked_run,
      1,
      %{
        status: :case_opened,
        case_id: incident.id,
        case_revision: incident.revision,
        completed_at: ~U[2026-10-05 02:00:00Z]
      },
      authorize?: false
    )

    for token <- [context.admin_token, context.operator_token, context.viewer_token] do
      assert [%{"case_id" => case_id, "case_revision" => 1, "status" => "case_opened"}] =
               get_data!("/api/v1/audit-runs/summaries?ids=#{linked_run.id}", token)

      assert case_id == incident.id
    end

    root =
      Path.join(System.tmp_dir!(), "audit-metadata-cli-#{System.unique_integer([:positive])}")

    config_path = Path.join(root, "config.json")

    :ok =
      SkoposCLI.Config.save(
        %{"server" => "https://skopos.example", "token" => context.viewer_token},
        config_path
      )

    on_exit(fn -> File.rm_rf(root) end)
    stub = {__MODULE__, make_ref()}
    Req.Test.stub(stub, &SkoposWeb.Endpoint.call(&1, SkoposWeb.Endpoint.init([])))
    runtime = [config_path: config_path, request_options: [plug: {Req.Test, stub}]]

    shown =
      capture_io(fn ->
        assert SkoposCLI.CLI.run(
                 ["audit", "summaries", "--after", first_page["page"]["next"]],
                 runtime
               ) == 0
      end)
      |> Jason.decode!()

    assert [%{"id" => ^tail_id, "name" => "Audit summary 1"}] = shown["data"]
    refute Map.has_key?(hd(shown["data"]), "target_ids")

    linked =
      capture_io(fn ->
        assert SkoposCLI.CLI.run(["audit-run", "summaries", "--ids", linked_run.id], runtime) ==
                 0
      end)
      |> Jason.decode!()

    assert [%{"id" => linked_id, "case_id" => case_id}] = linked["data"]
    assert linked_id == linked_run.id
    assert case_id == incident.id

    for {command, id} <- [
          {"audit", hd(schedules)["id"]},
          {"audit-run", hd(runs).id}
        ] do
      selected_page =
        capture_io(fn ->
          assert SkoposCLI.CLI.run([command, "summaries", "--ids", id], runtime) == 0
        end)
        |> Jason.decode!()

      assert [%{"id" => selected_id}] = selected_page["data"]
      assert selected_id == id
    end

    for {table, columns, path} <- [
          {"audit_schedules", ["objective", "target_ids"], "/api/v1/audit-schedules/summaries"},
          {"audit_runs", ["reason"], "/api/v1/audit-runs/summaries"}
        ] do
      for column <- columns,
          do:
            Skopos.Repo.query!(
              "ALTER TABLE #{table} RENAME COLUMN #{column} TO unavailable_#{column}"
            )

      try do
        response = get_json(path, context.viewer_token)
        assert length(json_response(response, 200)["data"]) == 50
      after
        for column <- columns,
            do:
              Skopos.Repo.query!(
                "ALTER TABLE #{table} RENAME COLUMN unavailable_#{column} TO #{column}"
              )
      end
    end
  end

  @tag audit_summaries: true
  test "known boundary summaries are scoped and filtered before pagination without loading facts",
       context do
    boundaries =
      for n <- 1..51 do
        Targets.create_management_boundary!(
          "Known audit boundary #{n}",
          "datacenter",
          %{"private" => "scope-facts"},
          actor: context.admin
        )
      end

    first = hd(boundaries)
    last = List.last(boundaries)
    Targets.deactivate_management_boundary!(first, 1, actor: context.admin)
    ids = "#{first.id},#{last.id}"

    for token <- [context.viewer_token, context.operator_token, context.admin_token] do
      selected = get_data!("/api/v1/management-boundaries?ids=#{ids}&active=true&limit=1", token)
      assert [%{"id" => selected_id}] = selected
      assert selected_id == last.id
      refute Map.has_key?(hd(selected), "facts")

      assert get_data!("/api/v1/management-boundaries?ids=#{first.id}&active=false", token)
             |> hd()
             |> Map.fetch!("id") == first.id
    end

    assert get_data!(
             "/api/v1/management-boundaries?ids=#{Ash.UUID.generate()}",
             context.viewer_token
           ) == []

    root =
      Path.join(System.tmp_dir!(), "audit-boundary-cli-#{System.unique_integer([:positive])}")

    config_path = Path.join(root, "config.json")

    :ok =
      SkoposCLI.Config.save(
        %{"server" => "https://skopos.example", "token" => context.viewer_token},
        config_path
      )

    on_exit(fn -> File.rm_rf(root) end)
    stub = {__MODULE__, make_ref()}
    Req.Test.stub(stub, &SkoposWeb.Endpoint.call(&1, SkoposWeb.Endpoint.init([])))

    shown =
      capture_io(fn ->
        assert SkoposCLI.CLI.run(["boundary", "list", "--ids", ids, "--active", "--limit", "1"],
                 config_path: config_path,
                 request_options: [plug: {Req.Test, stub}]
               ) == 0
      end)
      |> Jason.decode!()

    assert [%{"id" => selected_id, "name" => "Known audit boundary 51"}] = shown["data"]
    assert selected_id == last.id

    Skopos.Repo.query!(
      "ALTER TABLE management_boundaries RENAME COLUMN facts TO unavailable_facts"
    )

    try do
      assert [%{"id" => selected_id}] =
               get_data!("/api/v1/management-boundaries?ids=#{last.id}", context.viewer_token)

      assert selected_id == last.id
    after
      Skopos.Repo.query!(
        "ALTER TABLE management_boundaries RENAME COLUMN unavailable_facts TO facts"
      )
    end
  end

  @tag audit_summaries: true
  test "Audit summary bounds and required storage faults remain truthful under public authorization",
       context do
    for path <- [
          "/api/v1/audit-schedules/summaries",
          "/api/v1/audit-runs/summaries",
          "/api/v1/management-boundaries"
        ] do
      assert %{"error" => %{"code" => "unauthenticated"}} =
               get_json(path, nil) |> json_response(401)

      for invalid <- [
            "ids=",
            "ids=bad",
            "ids=" <> Enum.map_join(1..101, ",", fn _ -> Ash.UUID.generate() end),
            "limit=101",
            "after="
          ] do
        assert %{"error" => %{}} =
                 get_json(path <> "?" <> invalid, context.viewer_token) |> json_response(422)
      end
    end

    for {table, column, path} <- [
          {"audit_schedules", "name", "/api/v1/audit-schedules/summaries"},
          {"audit_runs", "status", "/api/v1/audit-runs/summaries"},
          {"management_boundaries", "name", "/api/v1/management-boundaries"}
        ] do
      Skopos.Repo.query!("ALTER TABLE #{table} RENAME COLUMN #{column} TO unavailable_#{column}")

      try do
        capture_log(fn ->
          assert %{"error" => %{"code" => "internal_error"}} =
                   get_json(path, context.viewer_token) |> json_response(500)
        end)
      after
        Skopos.Repo.query!(
          "ALTER TABLE #{table} RENAME COLUMN unavailable_#{column} TO #{column}"
        )
      end
    end
  end

  @tag report_receipt: true
  test "an exact Case revision recovers a generated Report beyond the snapshot window without its body",
       context do
    incident =
      post_data!(
        "/api/v1/cases",
        %{
          "case" => %{
            "trigger_kind" => "manual",
            "source" => "api",
            "source_ref" => "report-receipt",
            "title" => "Report receipt",
            "severity" => "warning",
            "initial_context" => %{"desired_outcome" => "Host responds"}
          }
        },
        context.operator_token
      )

    cancelled =
      post_json(
        "/api/v1/cases/#{incident["id"]}/cancel",
        %{"case" => %{"expected_revision" => 1}},
        context.operator_token
      )
      |> json_response(200)

    report =
      post_data!(
        "/api/v1/cases/#{incident["id"]}/reports",
        %{"report" => %{"expected_case_revision" => cancelled["data"]["revision"]}},
        context.operator_token
      )

    large_content = %{"padding" => String.duplicate("x", 10_000_000)}

    large =
      Reports.create_report_record!(
        %{
          case_id: incident["id"],
          case_revision: 1,
          language: :en,
          outcome: :cancelled,
          content: large_content,
          content_digest:
            :crypto.hash(:sha256, Jason.encode!(large_content)) |> Base.encode16(case: :lower),
          generated_at: DateTime.utc_now()
        },
        authorize?: false
      )

    for revision <- 3..102 do
      Reports.create_report_record!(
        %{
          case_id: incident["id"],
          case_revision: revision,
          language: :en,
          outcome: :cancelled,
          content: %{},
          content_digest: :crypto.hash(:sha256, "{}") |> Base.encode16(case: :lower),
          generated_at: DateTime.add(DateTime.utc_now(), revision)
        },
        authorize?: false
      )
    end

    response = get_json("/api/v1/cases/#{incident["id"]}/reports/2", context.viewer_token)

    assert %{"data" => %{"id" => id, "case_revision" => 2, "revision" => 1} = summary} =
             json_response(response, 200)

    assert id == report["id"]
    assert_operation_response(response)

    assert Enum.sort(Map.keys(summary)) ==
             Enum.sort(
               ~w(id case_id case_revision language outcome content_digest generated_at revision operation_count verification_count)
             )

    assert byte_size(response.resp_body) < 2_000
    snapshot = get_data!("/api/v1/cases/#{incident["id"]}", context.viewer_token)
    assert length(snapshot["reports"]) == 100
    refute Enum.any?(snapshot["reports"], &(&1["id"] in [id, large.id]))
    large_response = get_json("/api/v1/cases/#{incident["id"]}/reports/1", context.admin_token)

    assert %{"data" => %{"case_revision" => 1, "id" => large_id}} =
             json_response(large_response, 200)

    assert large_id == large.id
    assert byte_size(large_response.resp_body) < 2_000
    assert_operation_response(large_response)
    missing = get_json("/api/v1/cases/#{incident["id"]}/reports/103", context.viewer_token)
    assert %{"error" => %{"code" => "not_found"}} = json_response(missing, 404)
    assert_operation_response(missing)
  end

  @tag report_receipt: true
  test "CLI confirms a committed Report after its generation response is lost using only an exact revision GET",
       context do
    incident =
      post_data!(
        "/api/v1/cases",
        %{
          "case" => %{
            "trigger_kind" => "manual",
            "source" => "api",
            "source_ref" => "report-lost-response",
            "title" => "Report lost response",
            "severity" => "warning",
            "initial_context" => %{"desired_outcome" => "Host responds"}
          }
        },
        context.operator_token
      )

    post_json(
      "/api/v1/cases/#{incident["id"]}/cancel",
      %{"case" => %{"expected_revision" => 1}},
      context.operator_token
    )
    |> json_response(200)

    root =
      Path.join(System.tmp_dir!(), "report-receipt-cli-#{System.unique_integer([:positive])}")

    config_path = Path.join(root, "config.json")

    :ok =
      SkoposCLI.Config.save(
        %{"server" => "https://skopos.example", "token" => context.operator_token},
        config_path
      )

    on_exit(fn -> File.rm_rf(root) end)
    owner = self()
    stub = {__MODULE__, make_ref()}

    Req.Test.stub(stub, fn conn ->
      send(owner, {:receipt_request, conn.method, conn.request_path})
      result = SkoposWeb.Endpoint.call(conn, SkoposWeb.Endpoint.init([]))

      if conn.method == "POST" do
        assert result.status == 201
        report = Jason.decode!(result.resp_body)["data"]
        send(owner, {:committed_report, report["id"]})

        %{
          result
          | status: 503,
            resp_body:
              Jason.encode!(%{
                "error" => %{"code" => "response_lost", "message" => "Response lost after commit"}
              })
        }
      else
        result
      end
    end)

    runtime = [config_path: config_path, request_options: [plug: {Req.Test, stub}]]

    capture_io(:stderr, fn ->
      capture_io([input: Jason.encode!(%{"expected_case_revision" => 2})], fn ->
        assert SkoposCLI.CLI.run(["report", "generate", incident["id"], "--input", "-"], runtime) ==
                 4
      end)
    end)

    assert_receive {:committed_report, report_id}
    assert_receive {:receipt_request, "POST", _}

    output =
      capture_io(fn ->
        assert SkoposCLI.CLI.run(["report", "revision", incident["id"], "2"], runtime) == 0
      end)
      |> Jason.decode!()

    assert %{"id" => ^report_id, "case_revision" => 2, "revision" => 1} = output["data"]
    refute Map.has_key?(output["data"], "content")
    assert_receive {:receipt_request, "GET", path}
    assert path == "/api/v1/cases/#{incident["id"]}/reports/2"
    refute_receive {:receipt_request, "POST", _}, 0
  end

  @tag report_receipt: true
  test "exact Report receipt reads distinguish missing, invalid, unauthorized and database failures",
       context do
    case_id = Ecto.UUID.generate()
    path = "/api/v1/cases/#{case_id}/reports/1"

    for token <- [context.admin_token, context.operator_token, context.viewer_token] do
      missing = get_json(path, token)
      assert %{"error" => %{"code" => "not_found"}} = json_response(missing, 404)
      assert_operation_response(missing)
    end

    assert get_json(path, nil).status == 401

    for revision <- ["0", "-1", "bad", "9223372036854775808"] do
      invalid = get_json("/api/v1/cases/#{case_id}/reports/#{revision}", context.viewer_token)
      assert %{"error" => %{"code" => "validation_failed"}} = json_response(invalid, 422)
      assert_operation_response(invalid)
    end

    assert get_json("/api/v1/cases/not-a-uuid/reports/1", context.viewer_token).status == 422
    Skopos.Repo.query!("ALTER TABLE reports RENAME COLUMN content TO unavailable_content")

    try do
      capture_log(fn ->
        failed = get_json(path, context.viewer_token)
        assert %{"error" => %{"code" => "internal_error"}} = json_response(failed, 500)
        assert_operation_response(failed)
      end)
    after
      Skopos.Repo.query!("ALTER TABLE reports RENAME COLUMN unavailable_content TO content")
    end

    assert get_json(path, context.viewer_token).status == 404
  end

  @tag delivery_summary: true
  @tag delivery_receipt: true
  test "Report delivery badges and history remain complete when one Report has more than a page of deliveries",
       context do
    [older_report, busy_report, missing_report] =
      for name <- ~w(older busy missing) do
        incident =
          post_data!(
            "/api/v1/cases",
            %{
              "case" => %{
                "trigger_kind" => "manual",
                "source" => "api",
                "source_ref" => "delivery-summary-#{name}",
                "title" => "Delivery summary #{name}",
                "severity" => "warning",
                "initial_context" => %{"desired_outcome" => "Host responds"}
              }
            },
            context.operator_token
          )

        cancelled =
          post_json(
            "/api/v1/cases/#{incident["id"]}/cancel",
            %{"case" => %{"expected_revision" => 1}},
            context.operator_token
          )
          |> json_response(200)

        post_data!(
          "/api/v1/cases/#{incident["id"]}/reports",
          %{"report" => %{"expected_case_revision" => cancelled["data"]["revision"]}},
          context.operator_token
        )
      end

    provider =
      Providers.create_provider!(
        "delivery-summary-provider",
        :notification,
        "fixture-notification",
        %{"destination" => "summary-webhook"},
        %{"token" => "summary-fixture-token"},
        actor: context.admin
      )
      |> then(&Providers.check_provider!(&1.id, 1, %{}, actor: context.admin))
      |> then(&Providers.enable_provider!(&1, 1, actor: context.admin))

    deliveries =
      for {report, index} <- [{older_report, 0} | for(index <- 1..51, do: {busy_report, index})] do
        post_json(
          "/api/v1/deliveries",
          %{
            "delivery" => %{
              "report_id" => report["id"],
              "report_revision" => report["revision"],
              "provider_id" => provider.id,
              "provider_revision" => provider.revision,
              "idempotency_key" => "delivery-summary-#{index}"
            }
          },
          context.operator_token
        )
        |> json_response(202)
        |> Map.fetch!("data")
      end

    oldest = hd(deliveries)
    latest = List.last(deliveries)

    original =
      get_json(
        "/api/v1/deliveries/receipt?idempotency_key=delivery-summary-0",
        context.viewer_token
      )

    assert %{
             "data" =>
               %{"id" => original_id, "status" => "queued", "revision" => 1} = original_summary
           } = json_response(original, 200)

    assert original_id == oldest["id"]
    assert original_summary["report_id"] == older_report["id"]
    refute Map.has_key?(original_summary, "details")
    refute Map.has_key?(original_summary, "idempotency_key")
    assert_operation_response(original)
    report_ids = Enum.map_join([older_report, busy_report, missing_report], ",", & &1["id"])
    path = "/api/v1/deliveries/latest?report_ids=" <> report_ids
    response = get_json(path, context.viewer_token)
    records = json_response(response, 200)["data"]
    assert_operation_response(response)
    assert length(records) == 2
    assert Enum.sort(Enum.map(records, & &1["id"])) == Enum.sort([oldest["id"], latest["id"]])
    assert Enum.find(records, &(&1["report_id"] == older_report["id"]))["attempt_count"] == 1
    assert Enum.find(records, &(&1["report_id"] == busy_report["id"]))["attempt_count"] == 51

    assert Enum.all?(
             records,
             &(Enum.sort(Map.keys(&1)) ==
                 Enum.sort(
                   ~w(id report_id report_revision provider_id provider_revision destination_id destination_revision status reference enqueued_at dispatch_started_at completed_at revision attempt_count)
                 ))
           )

    assert {:ok, dispatched} =
             Dispatch.run(latest["id"], %{
               test_pid: self(),
               respond: fn ->
                 {:ok,
                  %Notification.Result{
                    status: :delivered,
                    reference: "summary-receipt",
                    details: %{"message" => String.duplicate("x", 30_000)}
                  }}
               end
             })

    assert dispatched.status == :delivered

    assert_receive {:delivery, _state,
                    %Notification.Request{idempotency_key: "delivery-summary-51"}}

    changed = get_data!(path, context.operator_token)

    assert %{"status" => "delivered", "revision" => 3, "reference" => "summary-receipt"} =
             Enum.find(changed, &(&1["id"] == latest["id"]))

    full = get_data!("/api/v1/deliveries/#{latest["id"]}", context.viewer_token)
    assert byte_size(full["details"]["message"]) == 30_000

    history_path = "/api/v1/deliveries/summaries?report_ids=#{busy_report["id"]}"
    history = get_json(history_path, context.viewer_token)
    first_page = json_response(history, 200)
    assert_operation_response(history)
    assert length(first_page["data"]) == 50
    assert hd(first_page["data"])["id"] == latest["id"]
    assert byte_size(history.resp_body) < 30_000

    assert Enum.all?(
             first_page["data"],
             &(&1["report_id"] == busy_report["id"] and not Map.has_key?(&1, "details"))
           )

    next =
      get_json(
        history_path <> "&after=" <> URI.encode_www_form(first_page["page"]["next"]),
        context.viewer_token
      )

    assert %{"data" => [%{"id" => tail_id}], "page" => %{"next" => nil}} =
             json_response(next, 200)

    assert tail_id == Enum.at(deliveries, 1)["id"]
    assert_operation_response(next)

    assert get_data!(
             "/api/v1/deliveries/latest?report_ids=#{missing_report["id"]}",
             context.admin_token
           ) == []

    root =
      Path.join(System.tmp_dir!(), "delivery-summary-cli-#{System.unique_integer([:positive])}")

    config_path = Path.join(root, "config.json")

    :ok =
      SkoposCLI.Config.save(
        %{"server" => "https://skopos.example", "token" => context.viewer_token},
        config_path
      )

    on_exit(fn -> File.rm_rf(root) end)
    stub = {__MODULE__, make_ref()}
    Req.Test.stub(stub, &SkoposWeb.Endpoint.call(&1, SkoposWeb.Endpoint.init([])))
    runtime = [config_path: config_path, request_options: [plug: {Req.Test, stub}]]

    cli_latest =
      capture_io(fn ->
        assert SkoposCLI.CLI.run(["delivery", "latest", "--report-ids", report_ids], runtime) ==
                 0
      end)
      |> Jason.decode!()

    assert cli_latest["data"] == changed

    Skopos.Repo.query!("ALTER TABLE deliveries RENAME COLUMN details TO unavailable_details")

    try do
      assert get_data!(path, context.viewer_token) == changed
    after
      Skopos.Repo.query!("ALTER TABLE deliveries RENAME COLUMN unavailable_details TO details")
    end

    cli_history =
      capture_io(fn ->
        assert SkoposCLI.CLI.run(
                 [
                   "delivery",
                   "summaries",
                   "--report-ids",
                   busy_report["id"],
                   "--after",
                   first_page["page"]["next"]
                 ],
                 runtime
               ) == 0
      end)
      |> Jason.decode!()

    assert cli_history["outcome"] == "succeeded"
    assert Map.take(cli_history, ["data", "page"]) == json_response(next, 200)

    receipt_cli =
      capture_io(fn ->
        assert SkoposCLI.CLI.run(
                 ["delivery", "receipt", "--idempotency-key", "delivery-summary-0"],
                 runtime
               ) == 0
      end)
      |> Jason.decode!()

    assert receipt_cli["data"] == original_summary

    :ok =
      SkoposCLI.Config.save(
        %{"server" => "https://skopos.example", "token" => context.operator_token},
        config_path
      )

    owner = self()

    Req.Test.stub(stub, fn conn ->
      send(owner, {:enqueue_request, conn.method})
      result = SkoposWeb.Endpoint.call(conn, SkoposWeb.Endpoint.init([]))

      if conn.method == "POST" do
        assert result.status == 202
        send(owner, {:accepted_delivery, Jason.decode!(result.resp_body)["data"]["id"]})

        %{
          result
          | status: 503,
            resp_body:
              Jason.encode!(%{
                "error" => %{
                  "code" => "response_lost",
                  "message" => "Response lost after enqueue"
                }
              })
        }
      else
        result
      end
    end)

    input = %{
      "report_id" => older_report["id"],
      "report_revision" => older_report["revision"],
      "provider_id" => provider.id,
      "provider_revision" => provider.revision,
      "idempotency_key" => "delivery-lost-response"
    }

    capture_io(:stderr, fn ->
      capture_io([input: Jason.encode!(input)], fn ->
        assert SkoposCLI.CLI.run(["delivery", "create", "--input", "-"], runtime) == 4
      end)
    end)

    assert_receive {:accepted_delivery, accepted_id}
    assert_receive {:enqueue_request, "POST"}

    recovered =
      capture_io(fn ->
        assert SkoposCLI.CLI.run(
                 ["delivery", "receipt", "--idempotency-key", "delivery-lost-response"],
                 runtime
               ) == 0
      end)
      |> Jason.decode!()

    assert %{"id" => ^accepted_id, "status" => "queued", "revision" => 1} = recovered["data"]
    assert_receive {:enqueue_request, "GET"}
    refute_receive {:enqueue_request, "POST"}, 0

    invocation = %{
      test_pid: self(),
      respond: fn ->
        {:ok, %Notification.Result{status: :delivered, reference: "delivered-once", details: %{}}}
      end
    }

    assert {:ok, %Skopos.Notifications.Delivery{status: :delivered, revision: 3}} =
             Dispatch.run(accepted_id, invocation)

    assert_receive {:delivery, _state,
                    %Notification.Request{idempotency_key: "delivery-lost-response"}}

    assert {:ok, %Skopos.Notifications.Delivery{status: :delivered, revision: 3}} =
             Dispatch.run(accepted_id, invocation)

    refute_receive {:delivery, _, _}, 0

    assert %{"status" => "delivered", "revision" => 3} =
             get_data!(
               "/api/v1/deliveries/receipt?idempotency_key=delivery-lost-response",
               context.viewer_token
             )

    first_busy = Enum.at(deliveries, 1)

    Skopos.Repo.query!(
      "UPDATE deliveries SET enqueued_at = (SELECT enqueued_at FROM deliveries WHERE id = $1) WHERE id = $2",
      [Ecto.UUID.dump!(latest["id"]), Ecto.UUID.dump!(first_busy["id"])]
    )

    expected_tie_id = Enum.max([first_busy["id"], latest["id"]])

    assert [%{"id" => ^expected_tie_id}] =
             get_data!(
               "/api/v1/deliveries/latest?report_ids=#{busy_report["id"]}",
               context.viewer_token
             )

    unicode_key = String.duplicate("😀", 1_024)

    unicode_delivery =
      post_json(
        "/api/v1/deliveries",
        %{"delivery" => %{input | "idempotency_key" => unicode_key}},
        context.operator_token
      )
      |> json_response(202)
      |> Map.fetch!("data")

    server =
      start_supervised!(
        {Bandit,
         SkoposWeb.Endpoint.config(:http)
         |> Keyword.merge(plug: SkoposWeb.Endpoint, port: 0, startup_log: false)}
      )

    {:ok, {_address, port}} = ThousandIsland.listener_info(server)

    :ok =
      SkoposCLI.Config.save(
        %{"server" => "http://127.0.0.1:#{port}", "token" => context.viewer_token},
        config_path
      )

    unicode_receipt =
      capture_io(fn ->
        assert SkoposCLI.CLI.run(
                 ["delivery", "receipt", "--idempotency-key", unicode_key],
                 %{config_path: config_path}
               ) == 0
      end)
      |> Jason.decode!()

    assert unicode_receipt["data"]["id"] == unicode_delivery["id"]
    refute Map.has_key?(unicode_receipt["data"], "idempotency_key")
  end

  @tag delivery_summary: true
  test "Delivery summaries reject unbounded reference reads and expose storage faults", context do
    ids = for(_ <- 1..100, do: Ecto.UUID.generate()) |> Enum.join(",")
    latest = "/api/v1/deliveries/latest"
    summaries = "/api/v1/deliveries/summaries"
    assert get_data!(latest <> "?report_ids=" <> ids, context.viewer_token) == []
    assert get_data!(summaries <> "?report_ids=" <> ids, context.operator_token) == []
    assert get_data!(summaries, context.admin_token) == []
    missing = get_json(latest, context.admin_token)
    assert %{"error" => %{"code" => "bad_request"}} = json_response(missing, 400)
    assert_operation_response(missing)

    for path <- [latest, summaries] do
      assert get_json(path, nil).status == 401

      for invalid <- ["", "not-a-uuid", Ecto.UUID.generate() <> "," <> ids] do
        failed = get_json(path <> "?report_ids=" <> invalid, context.viewer_token)
        assert %{"error" => %{"code" => "validation_failed"}} = json_response(failed, 422)
        assert_operation_response(failed)
      end
    end

    Skopos.Repo.query!("ALTER TABLE deliveries RENAME COLUMN details TO unavailable_details")

    try do
      assert get_data!(latest <> "?report_ids=" <> ids, context.viewer_token) == []
      assert get_data!(summaries, context.viewer_token) == []
    after
      Skopos.Repo.query!("ALTER TABLE deliveries RENAME COLUMN unavailable_details TO details")
    end

    Skopos.Repo.query!("ALTER TABLE deliveries RENAME COLUMN status TO unavailable_status")

    try do
      capture_log(fn ->
        for path <- [latest <> "?report_ids=" <> ids, summaries] do
          failed = get_json(path, context.viewer_token)
          assert %{"error" => %{"code" => "internal_error"}} = json_response(failed, 500)
          refute Map.has_key?(json_response(failed, 500), "data")
        end
      end)
    after
      Skopos.Repo.query!("ALTER TABLE deliveries RENAME COLUMN unavailable_status TO status")
    end

    assert get_data!(latest <> "?report_ids=" <> ids, context.viewer_token) == []
    assert get_data!(summaries, context.viewer_token) == []
  end

  @tag delivery_receipt: true
  test "Delivery receipt reads enforce the original key bound and preserve missing and storage errors",
       context do
    path = "/api/v1/deliveries/receipt"
    key = String.duplicate("x", 1_024)

    for token <- [context.admin_token, context.operator_token, context.viewer_token] do
      missing = get_json(path <> "?idempotency_key=" <> key, token)
      assert %{"error" => %{"code" => "not_found"}} = json_response(missing, 404)
      assert_operation_response(missing)
    end

    assert get_json(path <> "?idempotency_key=" <> key, nil).status == 401
    absent = get_json(path, context.viewer_token)
    assert %{"error" => %{"code" => "bad_request"}} = json_response(absent, 400)
    assert_operation_response(absent)

    for invalid <- ["", String.duplicate("x", 1_025)] do
      failed = get_json(path <> "?idempotency_key=" <> invalid, context.viewer_token)
      assert %{"error" => %{"code" => "validation_failed"}} = json_response(failed, 422)
      assert_operation_response(failed)
    end

    Skopos.Repo.query!("ALTER TABLE deliveries RENAME COLUMN details TO unavailable_details")

    try do
      assert get_json(path <> "?idempotency_key=" <> key, context.viewer_token).status == 404
    after
      Skopos.Repo.query!("ALTER TABLE deliveries RENAME COLUMN unavailable_details TO details")
    end

    Skopos.Repo.query!("ALTER TABLE deliveries RENAME COLUMN status TO unavailable_status")

    try do
      capture_log(fn ->
        failed = get_json(path <> "?idempotency_key=" <> key, context.viewer_token)
        assert %{"error" => %{"code" => "internal_error"}} = json_response(failed, 500)
        refute failed.resp_body =~ key
        assert_operation_response(failed)
      end)
    after
      Skopos.Repo.query!("ALTER TABLE deliveries RENAME COLUMN unavailable_status TO status")
    end

    assert get_json(path <> "?idempotency_key=" <> key, context.viewer_token).status == 404
  end

  @tag report_identity: true
  test "Report identity filters reject excess IDs and preserve authenticated missing results",
       context do
    path = "/api/v1/reports"
    ids = for(_ <- 1..100, do: Ecto.UUID.generate()) |> Enum.join(",")

    for token <- [context.admin_token, context.operator_token, context.viewer_token] do
      response = get_json(path <> "?ids=" <> ids, token)
      assert %{"data" => [], "page" => %{"next" => nil}} = json_response(response, 200)
      assert_operation_response(response)
    end

    assert get_json(path <> "?ids=" <> ids, nil).status == 401

    for invalid <- ["", "not-a-uuid", Ecto.UUID.generate() <> "," <> ids] do
      response = get_json(path <> "?ids=" <> invalid, context.viewer_token)
      assert %{"error" => %{"code" => "validation_failed"}} = json_response(response, 422)
      assert_operation_response(response)
    end
  end

  @tag report_page_capacity: true
  test "maximum immutable Report bodies remain exact while the public index contains only metadata",
       context do
    incident =
      Cases.open_case!(
        :manual,
        "fixture",
        "report-capacity",
        "Report capacity",
        :warning,
        %{"desired_outcome" => "Inspect retained results"},
        nil,
        :en,
        actor: context.operator
      )

    content = %{
      "outcome_label" => "Resolved",
      "case" => %{
        "id" => incident.id,
        "title" => incident.title,
        "severity" => "warning",
        "source" => "fixture",
        "source_ref" => "report-capacity",
        "inserted_at" => DateTime.to_iso8601(incident.inserted_at),
        "updated_at" => DateTime.to_iso8601(incident.updated_at)
      },
      "padding" => "",
      "operations" =>
        for(_ <- 1..3, do: %{"id" => Ecto.UUID.generate(), "purpose" => "investigation"}),
      "verifications" =>
        for(_ <- 1..2, do: %{"id" => Ecto.UUID.generate(), "status" => "verified"})
    }

    padding = String.duplicate("x", 10_485_760 - byte_size(Jason.encode!(content)))
    content = Map.put(content, "padding", padding)
    assert byte_size(Jason.encode!(content)) == 10_485_760
    digest = :crypto.hash(:sha256, Jason.encode!(content)) |> Base.encode16(case: :lower)

    report_ids =
      for revision <- 1..51 do
        Reports.create_report_record!(
          %{
            case_id: incident.id,
            case_revision: revision,
            language: :en,
            outcome: :resolved,
            content: content,
            content_digest: digest,
            generated_at: DateTime.add(incident.inserted_at, revision)
          },
          authorize?: false
        ).id
      end

    page = Reports.page_reports!(actor: context.viewer)
    assert length(page.results) == 50

    assert Enum.all?(
             page.results,
             &match?(%Ash.NotLoaded{type: :attribute, field: :content}, &1.content)
           )

    response = get_json("/api/v1/reports", context.viewer_token)
    assert_operation_response(response)
    assert byte_size(response.resp_body) < 32_000
    first_page = json_response(response, 200)
    assert length(first_page["data"]) == 50

    for summary <- first_page["data"] do
      refute Map.has_key?(summary, "content")
      refute Map.has_key?(summary, "document")
      assert summary["operation_count"] == 3
      assert summary["verification_count"] == 2
    end

    cursor = first_page["page"]["next"]
    tail = get_json("/api/v1/reports?after=" <> URI.encode_www_form(cursor), context.viewer_token)
    assert_operation_response(tail)
    tail_page = json_response(tail, 200)
    assert tail_page["page"]["next"] == nil

    assert Enum.sort(Enum.map(first_page["data"] ++ tail_page["data"], & &1["id"])) ==
             Enum.sort(report_ids)

    oldest_id = hd(report_ids)
    refute Enum.any?(first_page["data"], &(&1["id"] == oldest_id))
    selected = get_json("/api/v1/reports?ids=#{oldest_id}&limit=1", context.viewer_token)

    assert %{
             "data" => [%{"id" => ^oldest_id, "case_revision" => 1, "revision" => 1} = summary],
             "page" => %{"next" => nil}
           } = json_response(selected, 200)

    assert_operation_response(selected)
    assert summary["case_id"] == incident.id
    refute Map.has_key?(summary, "content")
    refute Map.has_key?(summary, "document")

    full = get_json("/api/v1/reports/#{hd(report_ids)}", context.viewer_token)
    assert_operation_response(full)
    assert json_response(full, 200)["data"]["content"]["padding"] == padding

    root = Path.join(System.tmp_dir!(), "report-cli-#{System.unique_integer([:positive])}")
    config_path = Path.join(root, "config.json")

    :ok =
      SkoposCLI.Config.save(
        %{"server" => "https://skopos.example", "token" => context.viewer_token},
        config_path
      )

    on_exit(fn -> File.rm_rf(root) end)
    stub = {__MODULE__, make_ref()}
    Req.Test.stub(stub, &SkoposWeb.Endpoint.call(&1, SkoposWeb.Endpoint.init([])))
    runtime = [config_path: config_path, request_options: [plug: {Req.Test, stub}]]

    listed =
      capture_io(fn ->
        assert SkoposCLI.CLI.run(["report", "list"], runtime) == 0
      end)

    assert byte_size(listed) < 32_000
    assert Jason.decode!(listed)["data"] == first_page["data"]

    listed_tail =
      capture_io(fn ->
        assert SkoposCLI.CLI.run(["report", "list", "--after", cursor], runtime) == 0
      end)

    assert Jason.decode!(listed_tail)["data"] == tail_page["data"]

    selected_cli =
      capture_io(fn ->
        assert SkoposCLI.CLI.run(["report", "list", "--ids", oldest_id, "--limit", "1"], runtime) ==
                 0
      end)
      |> Jason.decode!()

    assert selected_cli["data"] == [summary]
    assert selected_cli["page"]["next"] == nil

    shown =
      capture_io(fn ->
        assert SkoposCLI.CLI.run(["report", "show", hd(report_ids)], runtime) == 0
      end)

    assert Jason.decode!(shown)["data"]["content"]["padding"] == padding

    Skopos.Repo.query!("ALTER TABLE reports RENAME COLUMN content TO unavailable_content")

    try do
      assert {:error, %Ash.Error.Unknown{} = cause} = Reports.page_reports(actor: context.viewer)
      assert Exception.message(cause) =~ "does not exist"

      for path <- [
            "/api/v1/reports",
            "/api/v1/reports?ids=#{oldest_id}&limit=1",
            "/api/v1/reports/#{hd(report_ids)}"
          ] do
        failed = get_json(path, context.viewer_token)
        assert json_response(failed, 500)["error"]["code"] == "internal_error"
        assert_operation_response(failed)
      end

      for command <- [["report", "list"], ["report", "show", hd(report_ids)]] do
        failed =
          capture_io(:stderr, fn ->
            assert SkoposCLI.CLI.run(command, runtime) == 4
          end)

        assert %{"http_status" => 500, "error" => %{"code" => "internal_error"}} =
                 Jason.decode!(failed)
      end
    after
      Skopos.Repo.query!("ALTER TABLE reports RENAME COLUMN unavailable_content TO content")
    end

    assert length(Reports.page_reports!(actor: context.viewer).results) == 50
  end

  @tag report_setting_recovery: true
  test "Report setting storage failure preserves the revision and a lost accepted response is readable without another update",
       context do
    path = "/api/v1/report-setting"
    original = get_data!(path, context.admin_token)

    body = %{
      "report_setting" => %{
        "expected_revision" => original["revision"],
        "automatic_case_reports_enabled" => false
      }
    }

    Skopos.Repo.query!("""
    CREATE FUNCTION pg_temp.reject_report_setting() RETURNS trigger LANGUAGE plpgsql AS $$
    BEGIN RAISE EXCEPTION 'report setting storage unavailable'; END;
    $$
    """)

    Skopos.Repo.query!(
      "CREATE TRIGGER reject_report_setting BEFORE UPDATE ON report_settings FOR EACH ROW EXECUTE FUNCTION pg_temp.reject_report_setting()"
    )

    try do
      capture_log(fn ->
        failed = request(:put, path, body, context.admin_token)
        assert %{"error" => %{"code" => "internal_error"}} = json_response(failed, 500)
      end)
    after
      Skopos.Repo.query!("DROP TRIGGER reject_report_setting ON report_settings")
    end

    assert get_data!(path, context.admin_token) == original

    owner = self()
    stub = {__MODULE__, make_ref()}

    Req.Test.stub(stub, fn conn ->
      send(owner, {:setting_request, conn.method})
      result = SkoposWeb.Endpoint.call(conn, SkoposWeb.Endpoint.init([]))

      if conn.method == "PUT" do
        assert result.status == 200

        %{
          result
          | status: 503,
            resp_body:
              Jason.encode!(%{
                "error" => %{"code" => "response_lost", "message" => "Response lost after commit"}
              })
        }
      else
        result
      end
    end)

    connection =
      Req.new(
        base_url: "https://skopos.example",
        headers: [{"authorization", "Bearer #{context.admin_token}"}],
        plug: {Req.Test, stub},
        retry: false
      )

    assert {:ok, %{status: 503}} = Req.put(connection, url: path, json: body)
    assert_receive {:setting_request, "PUT"}
    assert {:ok, %{status: 200, body: %{"data" => recovered}}} = Req.get(connection, url: path)
    assert recovered["id"] == original["id"]
    assert recovered["revision"] == original["revision"] + 1
    assert recovered["automatic_case_reports_enabled"] == false
    assert recovered["changed_by_id"] == context.admin.id
    assert_receive {:setting_request, "GET"}
    refute_receive {:setting_request, "PUT"}, 0
  end

  test "Report setting is readable but only an Admin can change it", context do
    path = "/api/v1/report-setting"
    shown = get_json(path, context.viewer_token)

    assert %{"data" => %{"automatic_case_reports_enabled" => true, "revision" => revision}} =
             json_response(shown, 200)

    assert_operation_response(shown)

    body = %{
      "report_setting" => %{
        "expected_revision" => revision,
        "automatic_case_reports_enabled" => false
      }
    }

    forbidden = request(:put, path, body, context.operator_token)
    assert %{"error" => %{"code" => "forbidden"}} = json_response(forbidden, 403)

    viewer_forbidden = request(:put, path, body, context.viewer_token)
    assert %{"error" => %{"code" => "forbidden"}} = json_response(viewer_forbidden, 403)

    updated = request(:put, path, body, context.admin_token)

    assert %{
             "data" => %{
               "automatic_case_reports_enabled" => false,
               "revision" => next_revision,
               "changed_by_id" => changed_by_id
             }
           } = json_response(updated, 200)

    assert next_revision == revision + 1
    assert changed_by_id == context.admin.id
    assert_operation_response(updated)
    assert get_data!(path, context.viewer_token)["automatic_case_reports_enabled"] == false

    incident =
      Cases.open_case!(
        :manual,
        "test",
        "manual-report-with-automatic-off",
        "Manual report while automatic generation is off",
        :warning,
        %{"desired_outcome" => "Target responds as expected"},
        nil,
        :en,
        actor: context.operator
      )

    resolved =
      Cases.record_case_resolution!(incident, incident.revision, DateTime.utc_now(),
        authorize?: false
      )

    manual =
      post_json(
        "/api/v1/cases/#{resolved.id}/reports",
        %{"report" => %{"expected_case_revision" => resolved.revision}},
        context.operator_token
      )

    assert %{"data" => %{"case_id" => case_id}} = json_response(manual, 201)
    assert case_id == resolved.id

    stale = request(:put, path, body, context.admin_token)
    assert %{"error" => %{"code" => "conflict"}} = json_response(stale, 409)
  end

  test "Signal receipt status is cursor-readable without Provider credentials", context do
    provider =
      Providers.create_provider!(
        "receipt-signal-provider",
        :signal,
        "fixture-signal",
        %{"source" => "zabbix"},
        %{"secret" => "receipt-provider-secret"},
        actor: context.admin
      )
      |> then(&Providers.check_provider!(&1.id, 1, %{}, actor: context.admin))
      |> then(&Providers.enable_provider!(&1, 1, actor: context.admin))

    target = Targets.create_target!("10601", "host", "linux", %{}, nil, actor: context.admin)

    Targets.create_external_identity!(target.id, "zabbix", "hostname", "10601",
      actor: context.admin
    )

    now = DateTime.utc_now()
    receipt_id = "zabbix-event-9001"

    receipt =
      Signals.ingest_signal!(
        provider.id,
        provider.revision,
        %Signal.Envelope{body: receipt_id, headers: %{}, received_at: now},
        %{
          authenticate: fn adapter, _envelope ->
            {:ok, %Signal.AuthenticatedReceipt{receipt_id: receipt_id, source: adapter.source}}
          end,
          normalize: fn _adapter, _envelope, _receipt ->
            {:ok,
             [
               %Signal.Event{
                 receipt_id: receipt_id,
                 event_key: receipt_id,
                 state: :firing,
                 source_sequence: "9001",
                 occurred_at: now,
                 target_ref: %{kind: :hostname, value: "10601"},
                 attributes: %{"private" => "raw-event-detail"},
                 metadata: %{"private" => "raw-event-metadata"}
               }
             ]}
          end
        }
      )

    [signal_event] = Signals.list_signal_events!(actor: context.admin)
    incident = Cases.get_case!(signal_event.case_id, actor: context.admin)

    list = get_json("/api/v1/signal-receipts?limit=1", context.viewer_token)

    assert %{
             "data" => [
               %{
                 "id" => id,
                 "receipt_id" => "zabbix-event-9001",
                 "event_count" => 1
               }
             ],
             "page" => %{"next" => nil}
           } = json_response(list, 200)

    assert_operation_response(list)

    assert id == receipt.id
    refute list.resp_body =~ "metadata"
    refute list.resp_body =~ "normalized_digest"
    refute list.resp_body =~ "receipt-provider-secret"

    shown = get_json("/api/v1/signal-receipts/#{id}", context.operator_token)
    assert %{"data" => %{"id" => ^id}} = json_response(shown, 200)
    assert_operation_response(shown)

    event_response =
      get_json("/api/v1/signal-receipts/#{id}/events", context.viewer_token)

    assert %{
             "data" => [
               %{
                 "id" => event_id,
                 "signal_receipt_id" => ^id,
                 "event_key" => "zabbix-event-9001",
                 "state" => "firing",
                 "case_id" => case_id,
                 "target_ref" => %{"kind" => "hostname", "value" => "10601"}
               }
             ],
             "page" => %{"next" => nil}
           } = json_response(event_response, 200)

    assert_operation_response(event_response)

    assert event_id == signal_event.id
    assert case_id == incident.id
    refute event_response.resp_body =~ "raw-event-detail"
    refute event_response.resp_body =~ "raw-event-metadata"
  end

  test "Audit schedule API exposes queued, running, opened and skipped outcomes", context do
    boundary =
      Targets.create_management_boundary!("outcome-audit-dc", "datacenter", %{},
        actor: context.admin
      )

    target =
      Targets.create_target!("outcome-audit-linux", "host", "linux", %{}, boundary.id,
        actor: context.admin
      )

    schedule =
      post_data!(
        "/api/v1/audit-schedules",
        %{
          "audit_schedule" => %{
            "registration_id" => Ash.UUID.generate(),
            "name" => "hourly-storage-audit",
            "desired_outcome" => "Storage health is normal",
            "timezone" => "Etc/UTC",
            "cron_expression" => "0 * * * *",
            "report_language" => "en",
            "target_ids" => [target.id]
          }
        },
        context.admin_token
      )

    assert schedule["desired_outcome"] == "Storage health is normal"

    schedules = get_json("/api/v1/audit-schedules", context.viewer_token)
    assert %{"data" => [%{"id" => schedule_id}]} = json_response(schedules, 200)
    assert schedule_id == schedule["id"]
    assert_operation_response(schedules)

    shown_schedule = get_json("/api/v1/audit-schedules/#{schedule["id"]}", context.viewer_token)

    assert %{"data" => %{"id" => ^schedule_id, "desired_outcome" => "Storage health is normal"}} =
             json_response(shown_schedule, 200)

    assert_operation_response(shown_schedule)

    persisted = Audits.get_audit_schedule!(schedule["id"], actor: context.admin)

    Audits.wake_audit_schedule!(
      persisted.id,
      persisted.revision,
      persisted.next_run_at,
      authorize?: false
    )

    [queued] =
      Audits.audit_runs_for_occurrence!(persisted.id, persisted.next_run_at, authorize?: false)

    assert get_data!("/api/v1/audit-runs/#{queued.id}", context.viewer_token)["status"] ==
             "queued"

    Audits.claim_audit_run!(queued.id, authorize?: false)

    assert get_data!("/api/v1/audit-runs/#{queued.id}", context.viewer_token)["status"] ==
             "running"

    assert :ok =
             Skopos.Audits.AuditRun.Worker.perform(%Oban.Job{
               args: %{"audit_run_id" => queued.id}
             })

    opened = get_data!("/api/v1/audit-runs/#{queued.id}", context.viewer_token)
    assert opened["status"] == "case_opened"

    assert get_data!("/api/v1/cases/#{opened["case_id"]}", context.viewer_token)["case"]["id"] ==
             opened["case_id"]

    empty_boundary =
      Targets.create_management_boundary!("outcome-empty-dc", "datacenter", %{},
        actor: context.admin
      )

    empty_schedule =
      Audits.schedule_audit!(
        Ash.UUID.generate(),
        "empty-scope-audit",
        "Inspect empty scope",
        "Etc/UTC",
        "0 * * * *",
        :ja,
        [],
        empty_boundary.id,
        actor: context.admin
      )

    Audits.wake_audit_schedule!(
      empty_schedule.id,
      empty_schedule.revision,
      empty_schedule.next_run_at,
      authorize?: false
    )

    runs = get_data!("/api/v1/audit-runs", context.viewer_token)
    assert Enum.any?(runs, &(&1["status"] == "case_opened" and &1["id"] == queued.id))
    assert Enum.any?(runs, &(&1["status"] == "skipped"))

    current = Audits.get_audit_schedule!(persisted.id, actor: context.admin)

    stale =
      post_json(
        "/api/v1/audit-schedules/#{current.id}/deactivate",
        %{"audit_schedule" => %{"expected_revision" => 1}},
        context.admin_token
      )

    assert %{"error" => %{"code" => "conflict"}} = json_response(stale, 409)

    deactivated =
      post_json(
        "/api/v1/audit-schedules/#{current.id}/deactivate",
        %{"audit_schedule" => %{"expected_revision" => current.revision}},
        context.admin_token
      )

    assert %{"data" => %{"active" => false}} = json_response(deactivated, 200)
    assert_operation_response(deactivated)

    invalid =
      post_json(
        "/api/v1/audit-schedules",
        %{
          "audit_schedule" => %{
            "registration_id" => Ash.UUID.generate(),
            "name" => "invalid-audit",
            "desired_outcome" => "Storage health is normal",
            "timezone" => "invalid/timezone",
            "cron_expression" => "not cron",
            "report_language" => "en",
            "target_ids" => [target.id]
          }
        },
        context.admin_token
      )

    assert %{"error" => %{"code" => "validation_failed"}} = json_response(invalid, 422)
  end

  test "immutable Report delivery is idempotent and explicit retry keeps the Report", context do
    incident =
      Cases.open_case!(
        :manual,
        "api",
        "outcome-report",
        "Resolved service incident",
        :warning,
        %{"summary" => "service recovered", "desired_outcome" => "Target responds as expected"},
        nil,
        :en,
        actor: context.operator
      )

    terminal =
      Cases.record_case_resolution!(incident, incident.revision, DateTime.utc_now(),
        authorize?: false
      )

    report_response =
      post_json(
        "/api/v1/cases/#{terminal.id}/reports",
        %{"report" => %{"expected_case_revision" => terminal.revision}},
        context.operator_token
      )

    assert %{
             "data" => %{
               "id" => report_id,
               "case_revision" => case_revision,
               "outcome" => "resolved",
               "revision" => report_revision,
               "content_digest" => digest
             }
           } = json_response(report_response, 201)

    assert_operation_response(report_response)

    assert byte_size(digest) == 64
    assert case_revision == terminal.revision

    reports = get_json("/api/v1/reports", context.viewer_token)
    assert %{"data" => [%{"id" => listed_report_id}]} = json_response(reports, 200)
    assert listed_report_id == report_id
    assert_operation_response(reports)

    shown_report = get_json("/api/v1/reports/#{report_id}", context.viewer_token)
    assert_operation_response(shown_report)

    assert %{
             "data" => %{
               "document" => %{
                 "title" => "Resolved service incident",
                 "conditions" => [],
                 "cited_evidence" => [],
                 "text" => text
               }
             }
           } = json_response(shown_report, 200)

    assert text =~ "Resolved service incident"
    assert text =~ "Not established"

    duplicate_report =
      post_json(
        "/api/v1/cases/#{terminal.id}/reports",
        %{"report" => %{"expected_case_revision" => terminal.revision}},
        context.operator_token
      )

    assert json_response(duplicate_report, 201)["data"]["id"] == report_id

    stale_report =
      post_json(
        "/api/v1/cases/#{terminal.id}/reports",
        %{"report" => %{"expected_case_revision" => terminal.revision + 1}},
        context.operator_token
      )

    assert %{"error" => %{"code" => "conflict"}} = json_response(stale_report, 409)

    provider =
      Providers.create_provider!(
        "outcome-notification-provider",
        :notification,
        "fixture-notification",
        %{"destination" => "test-webhook"},
        %{"token" => "delivery-provider-secret"},
        actor: context.admin
      )
      |> then(&Providers.check_provider!(&1.id, 1, %{}, actor: context.admin))
      |> then(&Providers.enable_provider!(&1, 1, actor: context.admin))

    delivery_body = %{
      "delivery" => %{
        "report_id" => report_id,
        "report_revision" => report_revision,
        "provider_id" => provider.id,
        "provider_revision" => provider.revision,
        "idempotency_key" => "report-delivery-1"
      }
    }

    delivery_response = post_json("/api/v1/deliveries", delivery_body, context.operator_token)

    assert %{"data" => %{"id" => delivery_id, "status" => "queued"}} =
             json_response(delivery_response, 202)

    assert_operation_response(delivery_response)

    duplicate_delivery = post_json("/api/v1/deliveries", delivery_body, context.operator_token)
    assert json_response(duplicate_delivery, 202)["data"]["id"] == delivery_id

    assert {:ok, failed} =
             Dispatch.run(delivery_id, %{
               test_pid: self(),
               respond: fn ->
                 {:ok,
                  %Notification.Result{
                    status: :failed,
                    reference: "remote-failure",
                    details: %{"message" => "destination unavailable"}
                  }}
               end
             })

    assert failed.status == :failed
    assert_receive {:delivery, %{token: "delivery-provider-secret"}, _request}

    stored = get_json("/api/v1/deliveries/#{delivery_id}", context.viewer_token)

    assert %{"data" => %{"status" => "failed", "reference" => "remote-failure"}} =
             json_response(stored, 200)

    assert_operation_response(stored)

    refute stored.resp_body =~ "delivery-provider-secret"
    refute stored.resp_body =~ "idempotency_key"

    retry_body = put_in(delivery_body, ["delivery", "idempotency_key"], "report-delivery-2")
    retry = post_json("/api/v1/deliveries", retry_body, context.operator_token)

    assert %{"data" => %{"id" => retry_id, "status" => "queued"}} =
             json_response(retry, 202)

    assert_operation_response(retry)

    refute retry_id == delivery_id

    deliveries = get_json("/api/v1/deliveries", context.viewer_token)
    assert %{"data" => delivery_records} = json_response(deliveries, 200)
    assert Enum.sort(Enum.map(delivery_records, & &1["id"])) == Enum.sort([delivery_id, retry_id])
    assert_operation_response(deliveries)

    assert get_data!("/api/v1/reports/#{report_id}", context.viewer_token)["content_digest"] ==
             digest

    viewer_forbidden = post_json("/api/v1/deliveries", retry_body, context.viewer_token)
    assert %{"error" => %{"code" => "forbidden"}} = json_response(viewer_forbidden, 403)

    assert length(Notifications.list_deliveries!(actor: context.admin)) == 2
  end

  test "period Report API uses the same scoped Ash summary for viewers", context do
    incident =
      Cases.open_case!(
        :manual,
        "api",
        "period-api",
        "Period API Case",
        :warning,
        %{"desired_outcome" => "Target responds as expected"},
        nil,
        :en,
        actor: context.operator
      )

    from = incident.inserted_at |> DateTime.add(-60) |> DateTime.to_iso8601()
    to = incident.inserted_at |> DateTime.add(60) |> DateTime.to_iso8601()
    path = "/api/v1/reports/operations-summary?" <> URI.encode_query(%{from: from, to: to})
    response = get_json(path, context.viewer_token)

    assert_operation_response(response)

    assert %{"data" => %{"case_count" => 1, "audit_count" => 0, "cases" => [source]}} =
             json_response(response, 200)

    assert source["id"] == incident.id

    invalid = get_json("/api/v1/reports/operations-summary?from=bad&to=bad", context.viewer_token)
    assert %{"error" => %{"code" => "validation_failed"}} = json_response(invalid, 422)

    too_long =
      get_json(
        "/api/v1/reports/operations-summary?from=2025-01-01T00%3A00%3A00Z&to=2026-09-01T00%3A00%3A00Z",
        context.viewer_token
      )

    assert %{"error" => %{"code" => "validation_failed"}} = json_response(too_long, 422)
  end

  defp audit_registration(boundary_id, id) do
    %{
      "registration_id" => id,
      "name" => "Original audit",
      "desired_outcome" => "Storage health is normal",
      "timezone" => "Etc/UTC",
      "cron_expression" => "0 * * * *",
      "report_language" => "en",
      "management_boundary_id" => boundary_id,
      "target_ids" => []
    }
  end

  defp post_data!(path, body, token) do
    response = post_json(path, body, token)
    assert_operation_response(response)
    response |> json_response(201) |> Map.fetch!("data")
  end

  defp get_data!(path, token) do
    response = get_json(path, token)
    assert_operation_response(response)
    response |> json_response(200) |> Map.fetch!("data")
  end

  defp token!(email) do
    request(
      :post,
      "/api/v1/sessions",
      %{"session" => %{"email" => to_string(email), "password" => @password}},
      nil
    )
    |> json_response(201)
    |> get_in(["data", "token"])
  end

  defp get_json(path, token), do: request(:get, path, nil, token)
  defp post_json(path, body, token), do: request(:post, path, body, token)

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
