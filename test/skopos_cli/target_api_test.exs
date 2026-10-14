defmodule SkoposCLI.TargetAPITest do
  use SkoposWeb.ConnCase, async: false

  import ExUnit.CaptureIO
  import ExUnit.CaptureLog

  alias Skopos.{Accounts, Providers, Targets}
  alias SkoposCLI.{CLI, Config}

  @password "correct horse battery staple"

  setup do
    admin =
      Accounts.bootstrap!("target-cli-admin@example.com", @password, @password, authorize?: true)

    token =
      build_json_conn(%{})
      |> post("/api/v1/sessions", %{
        "session" => %{"email" => to_string(admin.email), "password" => @password}
      })
      |> json_response(201)
      |> get_in(["data", "token"])

    root =
      Path.join(System.tmp_dir!(), "skopos-target-cli-#{System.unique_integer([:positive])}")

    config_path = Path.join(root, "config.json")
    :ok = Config.save(%{"server" => "https://skopos.example", "token" => token}, config_path)
    on_exit(fn -> File.rm_rf(root) end)

    stub = {__MODULE__, make_ref()}
    Req.Test.stub(stub, &SkoposWeb.Endpoint.call(&1, SkoposWeb.Endpoint.init([])))

    %{
      admin: admin,
      stub: stub,
      runtime: [config_path: config_path, request_options: [plug: {Req.Test, stub}]]
    }
  end

  for supplied_id <- [nil, "10000000-0000-4000-8000-000000000054"] do
    @tag provider_registration: true
    @tag supplied_id: supplied_id
    test "CLI retains the original Provider registration identity after a lost acknowledgement (#{inspect(supplied_id)})",
         context do
      owner = self()

      Req.Test.stub(context.stub, fn conn ->
        response = SkoposWeb.Endpoint.call(conn, SkoposWeb.Endpoint.init([]))

        if conn.method == "POST" and conn.request_path == "/api/v1/providers" do
          assert response.status == 201
          %{"data" => %{"id" => id}} = Jason.decode!(response.resp_body)
          send(owner, {:registered, id})

          %{
            response
            | status: 503,
              resp_body: Jason.encode!(%{error: %{message: "Registration response lost"}})
          }
        else
          send(owner, {:read, conn.method, conn.request_path})
          response
        end
      end)

      input = %{
        name: "CLI destination",
        kind: "notification",
        adapter_type: "fixture-notification",
        configuration: %{destination: "reachable"},
        credentials: %{token: "private-cli-registration"}
      }

      input =
        if context.supplied_id,
          do: Map.put(input, :registration_id, context.supplied_id),
          else: input

      error =
        capture_io(Jason.encode!(input), fn ->
          stderr =
            capture_io(:stderr, fn ->
              assert CLI.run(["provider", "create", "--input", "-"], context.runtime) == 15
            end)

          send(owner, {:error_output, stderr})
        end)

      assert error == ""
      assert_receive {:registered, id}
      if context.supplied_id, do: assert(id == context.supplied_id)
      assert_receive {:error_output, stderr}

      assert [
               %{"event" => "registration_prepared", "registration_id" => ^id},
               %{"registration_id" => ^id, "http_status" => 503, "outcome" => "unknown"}
             ] = stderr |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!/1)

      refute stderr =~ "private-cli-registration"

      assert %{"id" => ^id, "name" => "CLI destination", "revision" => 1} =
               cli_data!(context, ["provider", "show", id])

      assert_receive {:read, "GET", path}
      assert path == "/api/v1/providers/#{id}"
      refute_receive {:registered, _}, 20
    end
  end

  test "CLI checks a registered Method through the authenticated remote API contract", context do
    provider =
      Providers.create_provider!(
        "check fixture",
        :target,
        "fixture-target",
        %{"endpoint" => "reachable"},
        %{"token" => "private-cli-token"},
        actor: context.admin
      )
      |> then(&Providers.enable_provider!(&1, &1.revision, actor: context.admin))

    target =
      Targets.create_target!("check-host", "host", "custom-os", %{}, nil, actor: context.admin)

    method =
      Targets.create_access_method!(
        target.id,
        provider.id,
        "check-method",
        "ssh",
        "ssh://192.0.2.1:22",
        provider.revision,
        100,
        [],
        actor: context.admin
      )

    output =
      capture_io(Jason.encode!(%{expected_revision: method.revision}), fn ->
        assert CLI.run(["access-method", "check", method.id, "--input", "-"], context.runtime) ==
                 0
      end)

    %{"data" => checked} = Jason.decode!(output)
    assert checked["check"]["current"]
    assert checked["check"]["status"] == "passed"
    assert "observe.command" in checked["check"]["observed_capabilities"]
    assert "effect.command" in checked["check"]["observed_capabilities"]
    assert checked["capabilities"] == []
    refute output =~ "private-cli-token"

    granted =
      cli_data!(context, ["access-method", "update", checked["id"]], %{
        expected_revision: checked["revision"],
        capabilities: ["observe.command"]
      })

    assert granted["check"] == checked["check"]
    assert granted["capabilities"] == ["observe.command"]

    changed =
      cli_data!(context, ["access-method", "update", granted["id"]], %{
        expected_revision: granted["revision"],
        endpoint: "ssh://192.0.2.2:22"
      })

    assert changed["endpoint"] == "ssh://192.0.2.2:22"
    assert changed["capabilities"] == ["observe.command"]
    assert changed["check"]["current"] == false
    assert changed["check"]["observed_capabilities"] == []

    listed = cli_data!(context, ["access-method", "list"])
    assert Enum.find(listed, &(&1["id"] == changed["id"])) == changed
  end

  @tag method_ids: true
  test "CLI selects referenced inactive Methods before paging and combines Target filters",
       context do
    provider =
      Providers.create_provider!(
        "Method identity fixture",
        :target,
        "fixture-target",
        %{"endpoint" => "reachable"},
        %{"token" => "fixture"},
        actor: context.admin
      )
      |> then(&Providers.enable_provider!(&1, &1.revision, actor: context.admin))

    target =
      Targets.create_target!("Method host", "host", "custom-os", %{}, nil, actor: context.admin)

    first =
      Targets.create_access_method!(
        target.id,
        provider.id,
        "preferred",
        "ssh",
        "ssh://192.0.2.1:22",
        provider.revision,
        1,
        [],
        actor: context.admin
      )

    last =
      Targets.create_access_method!(
        target.id,
        provider.id,
        "historical",
        "ssh",
        "ssh://192.0.2.2:22",
        provider.revision,
        500,
        [],
        actor: context.admin
      )

    Targets.deactivate_access_method!(last, last.revision, actor: context.admin)

    args = ["access-method", "list", "--ids", last.id, "--limit", "1"]
    assert [%{"id" => id, "active" => false, "name" => "historical"}] = cli_data!(context, args)
    assert id == last.id
    refute id == first.id
    assert [] == cli_data!(context, args ++ ["--active"])
    assert [%{"id" => ^id}] = cli_data!(context, args ++ ["--target-id", target.id])
    assert [] == cli_data!(context, args ++ ["--target-id", Ecto.UUID.generate()])
  end

  test "CLI registers every published Method and reads failed checks through the authenticated API",
       context do
    catalog =
      capture_io(fn -> assert CLI.run(["target-type", "list"], context.runtime) == 0 end)
      |> Jason.decode!()
      |> Map.fetch!("data")

    assert Enum.any?(
             catalog["methods"],
             &(&1["adapter_type"] == "hpe-ilo-ipmi" and &1["protocol"] == "ipmi")
           )

    assert Enum.any?(
             catalog["types"],
             &(&1["id"] == "custom-bmc" and &1["access_method_types"] == ["redfish", "ipmi"])
           )

    # Real adapters contact refused local TCP/UDP ports. This proves the CLI
    # registration/error contract, not successful vendor/OEM connectivity.
    {:ok, listener} = :gen_tcp.listen(0, active: false)
    {:ok, tcp_port} = :inet.port(listener)
    :ok = :gen_tcp.close(listener)
    {:ok, socket} = :gen_udp.open(0, active: false)
    {:ok, udp_port} = :inet.port(socket)
    :ok = :gen_udp.close(socket)

    for descriptor <- catalog["methods"] do
      adapter_type = descriptor["adapter_type"]
      method_name = descriptor["protocol"]

      endpoint =
        case method_name do
          protocol when protocol in ["ssh", "netconf"] -> "ssh://127.0.0.1:#{tcp_port}"
          "ipmi" -> "ipmi://127.0.0.1:#{udp_port}"
          _ -> "https://127.0.0.1:#{tcp_port}"
        end

      {configuration, credentials} = Skopos.TargetConnectionFixture.input(adapter_type, endpoint)

      configuration =
        case method_name do
          protocol when protocol in ["ssh", "netconf"] ->
            Map.merge(configuration, %{"connect_timeout_ms" => 100, "operation_timeout_ms" => 100})

          "restconf" ->
            Map.merge(configuration, %{"connect_timeout_ms" => 100, "request_timeout_ms" => 100})

          "kubernetes" ->
            configuration

          _ ->
            Map.put(configuration, "timeout_ms", 100)
        end

      type = Enum.find(catalog["types"], &(adapter_type in &1["access_method_types"]))

      target =
        cli_data!(context, ["target", "create"], %{
          name: "CLI #{adapter_type}",
          kind: type["kind"],
          type_id: type["id"],
          facts: %{}
        })

      provider =
        cli_data!(context, ["provider", "create"], %{
          name: "CLI #{adapter_type}",
          kind: "target",
          adapter_type: adapter_type,
          configuration: configuration,
          credentials: credentials
        })

      provider =
        cli_data!(context, ["provider", "enable", provider["id"]], %{
          expected_revision: provider["revision"]
        })

      binding_method = provider["access_method_profile"]["method"]

      method_input =
        Jason.encode!(%{
          "target_id" => target["id"],
          "provider_id" => provider["id"],
          "name" => method_name,
          "method" => binding_method,
          "endpoint" => endpoint,
          "provider_revision" => provider["revision"],
          "priority" => 100,
          "capabilities" => []
        })

      method =
        capture_io(method_input, fn ->
          assert CLI.run(["access-method", "create", "--input", "-"], context.runtime) == 0
        end)
        |> Jason.decode!()
        |> get_in(["data"])

      assert method["target_id"] == target["id"]
      assert method["provider_id"] == provider["id"]
      assert method["endpoint"] == endpoint
      assert method["method"] == binding_method

      output =
        capture_io(Jason.encode!(%{expected_revision: method["revision"]}), fn ->
          assert CLI.run(
                   ["access-method", "check", method["id"], "--input", "-"],
                   context.runtime
                 ) == 13
        end)

      assert %{"outcome" => "failed", "data" => checked} = Jason.decode!(output)
      assert checked["endpoint"] == endpoint
      assert checked["check"]["status"] == "failed"
      assert checked["check"]["current"] == false
      assert checked["check"]["observed_capabilities"] == []
      assert checked["capabilities"] == []

      reread = cli_data!(context, ["access-method", "list"])
      assert Enum.find(reread, &(&1["id"] == checked["id"])) == checked
    end
  end

  test "CLI reports a persisted failed Method check as a failure", context do
    provider =
      Providers.create_provider!(
        "rejected credentials",
        :target,
        "fixture-target",
        %{"endpoint" => "authentication"},
        %{"token" => "private-cli-token"},
        actor: context.admin
      )
      |> then(&Providers.enable_provider!(&1, &1.revision, actor: context.admin))

    target =
      Targets.create_target!("unknown-host", "host", "custom-os", %{}, nil, actor: context.admin)

    method =
      Targets.create_access_method!(
        target.id,
        provider.id,
        "rejected",
        "ssh",
        "ssh://192.0.2.1:22",
        provider.revision,
        100,
        ["observe.command"],
        actor: context.admin
      )

    output =
      capture_io(Jason.encode!(%{expected_revision: method.revision}), fn ->
        assert CLI.run(["access-method", "check", method.id, "--input", "-"], context.runtime) ==
                 13
      end)

    assert %{
             "outcome" => "failed",
             "data" => %{
               "check" => %{
                 "current" => false,
                 "status" => "failed",
                 "observed_capabilities" => []
               }
             }
           } = Jason.decode!(output)

    refute output =~ "private-cli-token"
  end

  test "a lost check acknowledgement is not retried and a new CLI invocation reads the durable result",
       context do
    provider =
      cli_data!(context, ["provider", "create"], %{
        name: "lost response fixture",
        kind: "target",
        adapter_type: "fixture-target",
        configuration: %{endpoint: "reachable"},
        credentials: %{token: "private-cli-token"}
      })

    provider =
      cli_data!(context, ["provider", "enable", provider["id"]], %{
        expected_revision: provider["revision"]
      })

    target =
      cli_data!(context, ["target", "create"], %{
        name: "unknown-host",
        kind: "host",
        type_id: "custom-os",
        facts: %{}
      })

    method =
      cli_data!(context, ["access-method", "create"], %{
        target_id: target["id"],
        provider_id: provider["id"],
        provider_revision: provider["revision"],
        name: "lost response",
        method: "ssh",
        endpoint: "ssh://192.0.2.1:22",
        capabilities: []
      })

    attempts = start_supervised!({Agent, fn -> 0 end})

    Req.Test.stub(context.stub, fn conn ->
      response = SkoposWeb.Endpoint.call(conn, SkoposWeb.Endpoint.init([]))

      if conn.request_path == "/api/v1/access-methods/#{method["id"]}/check" do
        assert response.status == 200
        Agent.update(attempts, &(&1 + 1))
        Req.Test.transport_error(response, :timeout)
      else
        response
      end
    end)

    error =
      capture_io(:stderr, fn ->
        capture_io(Jason.encode!(%{expected_revision: method["revision"]}), fn ->
          assert CLI.run(
                   ["access-method", "check", method["id"], "--input", "-"],
                   context.runtime
                 ) == 5
        end)
      end)

    assert %{"outcome" => "unknown", "error" => %{"code" => "transport_error"}} =
             Jason.decode!(error)

    assert Agent.get(attempts, & &1) == 1

    reread =
      cli_data!(context, ["access-method", "list"]) |> Enum.find(&(&1["id"] == method["id"]))

    assert reread["check"]["current"]
    assert reread["check"]["status"] == "passed"
    assert reread["capabilities"] == []
    refute error =~ "private-cli-token"
  end

  @tag target_scope_cli: true
  test "CLI scopes management lists and keeps their cursor and inactive selection", context do
    provider =
      Providers.create_provider!(
        "scope",
        :target,
        "fixture-target",
        %{"endpoint" => "reachable"},
        %{"token" => "scope-fixture-token"},
        actor: context.admin
      )
      |> then(&Providers.enable_provider!(&1, &1.revision, actor: context.admin))

    selected =
      Targets.create_target!("scope-host", "host", "custom-os", %{}, nil, actor: context.admin)

    other =
      Targets.create_target!("scope-peer", "host", "custom-os", %{}, nil, actor: context.admin)

    unrelated =
      Targets.create_target!("scope-unrelated", "host", "custom-os", %{}, nil,
        actor: context.admin
      )

    for {target, label} <- [
          {other, "unrelated"},
          {selected, "inactive"},
          {selected, "first"},
          {selected, "second"}
        ] do
      method =
        Targets.create_access_method!(
          target.id,
          provider.id,
          label,
          "ssh",
          "ssh://192.0.2.1:22",
          provider.revision,
          if(label == "second", do: 0, else: 100),
          [],
          actor: context.admin
        )

      identity =
        Targets.create_external_identity!(target.id, "inventory", "hostname", label,
          actor: context.admin
        )

      {source, destination} =
        case label do
          "unrelated" -> {other, unrelated}
          "second" -> {other, selected}
          _ -> {selected, other}
        end

      relation =
        Targets.create_relationship!(source.id, destination.id, label, %{}, nil,
          actor: context.admin
        )

      if label == "inactive" do
        Targets.deactivate_access_method!(method, method.revision, actor: context.admin)
        Targets.deactivate_external_identity!(identity, identity.revision, actor: context.admin)
        Targets.deactivate_relationship!(relation, relation.revision, actor: context.admin)
      end
    end

    for {resource, label_key, first_name, second_name} <- [
          {"access-method", "name", "second", "first"},
          {"identity", "value", "first", "second"},
          {"relationship", "kind", "first", "second"}
        ] do
      args = [resource, "list", "--target-id", selected.id, "--active", "--limit", "1"]
      first = capture_io(fn -> assert CLI.run(args, context.runtime) == 0 end) |> Jason.decode!()
      assert [%{^label_key => ^first_name}] = first["data"]
      assert first["page"]["next"]

      tail =
        capture_io(fn ->
          assert CLI.run(args ++ ["--after", first["page"]["next"]], context.runtime) == 0
        end)
        |> Jason.decode!()

      assert [%{^label_key => ^second_name}] = tail["data"]
      assert tail["page"]["next"] == nil

      assert [%{^label_key => "inactive", "revision" => 2}] =
               cli_data!(context, [resource, "list", "--target-id", selected.id, "--no-active"])
    end
  end

  @tag target_scope_fault: true
  test "scoped public reads preserve storage faults instead of reporting an empty collection",
       context do
    selected =
      Targets.create_target!("fault-host", "host", "custom-os", %{}, nil, actor: context.admin)

    for {resource, path, table, action} <- [
          {"access-method", "/access-methods", "access_methods", &Targets.page_access_methods/2},
          {"identity", "/external-identities", "external_identities",
           &Targets.page_external_identities/2},
          {"relationship", "/target-relationships", "relationships",
           &Targets.page_relationships/2}
        ] do
      Skopos.Repo.query!("ALTER TABLE #{table} RENAME COLUMN revision TO unavailable_revision")

      try do
        assert {:error, %Ash.Error.Unknown{} = cause} =
                 action.(%{target_id: selected.id, active: true},
                   actor: context.admin,
                   page: [limit: 1]
                 )

        assert Exception.message(cause) =~ "does not exist"

        capture_log(fn ->
          response =
            SkoposCLI.Client.request(client!(context), :get, path, nil,
              target_id: selected.id,
              active: true
            )

          assert {:error, :http, 500, %{"error" => %{"code" => "internal_error"}}} = response

          error =
            capture_io(:stderr, fn ->
              assert CLI.run(
                       [resource, "list", "--target-id", selected.id, "--active"],
                       context.runtime
                     ) == 4
            end)

          assert Jason.decode!(error)["error"]["code"] == "internal_error"
        end)
      after
        Skopos.Repo.query!("ALTER TABLE #{table} RENAME COLUMN unavailable_revision TO revision")
      end

      assert cli_data!(context, [resource, "list", "--target-id", selected.id, "--active"]) == []
    end
  end

  @tag references_cli: true
  @tag target_summaries_cli: true
  test "CLI pages searchable management metadata and reads current summaries by ID", context do
    first = Targets.create_target!("Host A", "host", "custom-os", %{}, nil, actor: context.admin)

    selected =
      Targets.create_target!("Host Z", "host", "custom-os", %{"private" => "not metadata"}, nil,
        actor: context.admin
      )

    selected =
      Targets.update_target!(selected, 1, %{operating_instructions: "Preserve boot disk"},
        actor: context.admin
      )

    inactive =
      Targets.create_target!("Host inactive", "host", "custom-os", %{}, nil, actor: context.admin)

    inactive = Targets.deactivate_target!(inactive, 1, actor: context.admin)

    listed =
      capture_io(fn ->
        assert CLI.run(
                 ["target", "summaries", "--active", "--query", "HOST", "--limit", "1"],
                 context.runtime
               ) == 0
      end)
      |> Jason.decode!()

    assert [%{"id" => first_id, "method_count" => 0, "has_operating_instructions" => false}] =
             listed["data"]

    assert first_id == first.id
    assert listed["page"]["next"]

    tail =
      capture_io(fn ->
        assert CLI.run(
                 [
                   "target",
                   "summaries",
                   "--active",
                   "--query",
                   "HOST",
                   "--limit",
                   "1",
                   "--after",
                   listed["page"]["next"]
                 ],
                 context.runtime
               ) == 0
      end)
      |> Jason.decode!()

    assert [%{"id" => selected_id, "revision" => 2, "has_operating_instructions" => true}] =
             tail["data"]

    assert selected_id == selected.id
    assert tail["page"]["next"] == nil

    assert [%{"id" => selected_id}] =
             cli_data!(context, ["target", "summaries", "--ids", selected.id])

    assert selected_id == selected.id

    assert [%{"id" => inactive_id, "active" => false, "revision" => 2}] =
             cli_data!(context, ["target", "summaries", "--no-active", "--ids", inactive.id])

    assert inactive_id == inactive.id
    refute Jason.encode!(tail) =~ "private"
  end

  @tag references_cli: true
  test "CLI reads current references by ID and pages eligible choices before retaining detail",
       context do
    selected =
      Targets.create_target!(
        "Reference host",
        "host",
        "custom-os",
        %{"blob" => String.duplicate("x", 65_000)},
        nil,
        actor: context.admin
      )

    peer =
      Targets.create_target!("Reference peer", "host", "custom-os", %{}, nil,
        actor: context.admin
      )

    disabled =
      Providers.create_provider!(
        "Disabled SSH",
        :target,
        "ssh",
        %{"blob" => String.duplicate("x", 65_525)},
        %{"password" => "fixture-private"},
        actor: context.admin
      )

    provider =
      Providers.create_provider!(
        "Enabled HTTP",
        :target,
        "http-api",
        %{},
        %{"bearer_token" => "fixture-private"},
        actor: context.admin
      )
      |> then(&Providers.enable_provider!(&1, &1.revision, actor: context.admin))

    refs =
      cli_data!(context, ["provider", "references", "--ids", "#{provider.id},#{disabled.id}"])

    assert Enum.map(refs, & &1["id"]) == [disabled.id, provider.id]
    assert Enum.all?(refs, &(not Map.has_key?(&1, "configuration")))

    assert [
             %{
               "id" => provider_id,
               "revision" => 1,
               "access_method_profile" => %{"method" => "http"}
             }
           ] =
             cli_data!(context, [
               "provider",
               "references",
               "--kind",
               "target",
               "--enabled",
               "--adapter-types",
               "http-api,ssh"
             ])

    assert provider_id == provider.id

    assert [%{"id" => disabled_id}] =
             cli_data!(context, [
               "provider",
               "references",
               "--kind",
               "target",
               "--no-enabled",
               "--adapter-types",
               "ssh"
             ])

    assert disabled_id == disabled.id
    args = ["target", "references", "--active", "--limit", "1"]
    first = capture_io(fn -> assert CLI.run(args, context.runtime) == 0 end) |> Jason.decode!()
    assert [%{"id" => selected_id}] = first["data"]
    assert selected_id == selected.id
    refute Map.has_key?(hd(first["data"]), "facts")

    tail =
      capture_io(fn ->
        assert CLI.run(args ++ ["--after", first["page"]["next"]], context.runtime) == 0
      end)
      |> Jason.decode!()

    assert [%{"id" => peer_id}] = tail["data"]
    assert peer_id == peer.id
    assert tail["page"]["next"] == nil

    assert [%{"id" => ^peer_id}] =
             cli_data!(context, [
               "target",
               "references",
               "--ids",
               "#{peer.id},#{selected.id}",
               "--exclude-id",
               selected.id
             ])
  end

  @tag inventory_row_summaries_cli: true
  test "CLI pages scoped preview display metadata and preserves storage failures", context do
    csv =
      "external_id,identity_kind,name,kind,type_id,facts_json\nasset-1,custom-os,Host 1,host,custom-os,{}\nasset-2,custom-os,Host 2,host,custom-os,{}\n"

    preview = Targets.preview_manual_inventory!("display-source", csv, actor: context.admin)

    other =
      Targets.preview_manual_inventory!(
        "another-source",
        "external_id,identity_kind,name,kind,type_id,facts_json\nother,custom-os,Other,host,custom-os,{}\n",
        actor: context.admin
      )

    args = ["inventory", "row-summaries", preview.id, "--limit", "1"]
    first = capture_io(fn -> assert CLI.run(args, context.runtime) == 0 end) |> Jason.decode!()
    assert [%{"position" => 1, "identity_value" => "asset-1"}] = first["data"]

    assert [%{"position" => 2, "identity_value" => "asset-2"}] =
             cli_data!(context, args ++ ["--after", first["page"]["next"]])

    assert [%{"identity_value" => "other"}] =
             cli_data!(context, ["inventory", "row-summaries", other.id])

    expected = cli_data!(context, ["inventory", "row-summaries", preview.id])

    for {column, required?} <- [
          {"candidate", false},
          {"provenance", false},
          {"identity_value", true},
          {"errors", true},
          {"position", true}
        ] do
      Skopos.Repo.query!(
        "ALTER TABLE inventory_import_rows RENAME COLUMN #{column} TO unavailable_display_column"
      )

      try do
        if required? do
          assert {:error, %Ash.Error.Unknown{} = cause} =
                   Targets.page_inventory_import_row_summaries(preview.id,
                     actor: context.admin,
                     page: [limit: 1]
                   )

          assert Exception.message(cause) =~ "does not exist"

          capture_log(fn ->
            error = capture_io(:stderr, fn -> assert CLI.run(args, context.runtime) == 4 end)
            assert Jason.decode!(error)["error"]["code"] == "internal_error"
          end)
        else
          assert cli_data!(context, ["inventory", "row-summaries", preview.id]) == expected

          assert {:error, %Ash.Error.Unknown{}} =
                   Targets.page_inventory_import_rows(preview.id,
                     actor: context.admin,
                     page: [limit: 1]
                   )
        end
      after
        Skopos.Repo.query!(
          "ALTER TABLE inventory_import_rows RENAME COLUMN unavailable_display_column TO #{column}"
        )
      end
    end
  end

  @tag provider_summaries_cli: true
  test "CLI pages current Provider management checks without retaining configuration", context do
    disabled =
      Providers.create_provider!(
        "Unchecked inventory",
        :inventory,
        "fixture-inventory",
        %{"source" => "reachable"},
        %{"token" => "private"},
        actor: context.admin
      )

    inventory =
      Providers.create_provider!(
        "Checked inventory",
        :inventory,
        "fixture-inventory",
        %{"source" => "reachable"},
        %{"token" => "private"},
        actor: context.admin
      )
      |> then(&Providers.check_provider!(&1.id, &1.revision, %{}, actor: context.admin))
      |> then(&Providers.enable_provider!(&1, &1.revision, actor: context.admin))

    id = inventory.id

    assert [%{"id" => ^id, "check" => %{"status" => "passed", "checked_revision" => 1}}] =
             cli_data!(context, [
               "provider",
               "summaries",
               "--kinds",
               "inventory",
               "--eligible",
               "--limit",
               "1"
             ])

    disabled_id = disabled.id

    assert [%{"id" => ^disabled_id}] =
             cli_data!(context, ["provider", "summaries", "--ids", disabled_id, "--no-eligible"])

    expected = cli_data!(context, ["provider", "summaries", "--ids", id])
    refute Jason.encode!(expected) =~ "private"

    for {column, required?} <- [
          {"configuration", false},
          {"encrypted_credentials", false},
          {"check_status", true},
          {"checked_revision", true},
          {"name", true}
        ] do
      Skopos.Repo.query!(
        "ALTER TABLE providers RENAME COLUMN #{column} TO unavailable_management_column"
      )

      try do
        if required? do
          assert {:error, %Ash.Error.Unknown{} = cause} =
                   Providers.page_provider_summaries(%{ids: [id]},
                     actor: context.admin,
                     page: [limit: 1]
                   )

          assert Exception.message(cause) =~ "does not exist"

          capture_log(fn ->
            error =
              capture_io(:stderr, fn ->
                assert CLI.run(["provider", "summaries", "--ids", id], context.runtime) == 4
              end)

            assert Jason.decode!(error)["error"]["code"] == "internal_error"
          end)
        else
          assert cli_data!(context, ["provider", "summaries", "--ids", id]) == expected

          assert {:error, %Ash.Error.Unknown{}} =
                   Providers.get_active_provider(id, actor: context.admin)
        end
      after
        Skopos.Repo.query!(
          "ALTER TABLE providers RENAME COLUMN unavailable_management_column TO #{column}"
        )
      end
    end
  end

  @tag reference_fault: true
  test "reference reads omit unused storage and preserve required metadata faults", context do
    provider =
      Providers.create_provider!(
        "Reference fault",
        :target,
        "fixture-target",
        %{"blob" => String.duplicate("x", 65_525)},
        %{"token" => "fixture-private"},
        actor: context.admin
      )

    target =
      Targets.create_target!(
        "Reference fault",
        "host",
        "custom-os",
        %{"blob" => String.duplicate("x", 65_000)},
        nil,
        actor: context.admin
      )

    for {resource, table, id, page, get, column} <- [
          {"provider", "providers", provider.id, &Providers.page_provider_references/2,
           &Providers.get_active_provider/2, "configuration"},
          {"provider", "providers", provider.id, &Providers.page_provider_references/2,
           &Providers.get_active_provider/2, "encrypted_credentials"},
          {"target", "targets", target.id, &Targets.page_target_references/2,
           &Targets.get_target/2, "facts"},
          {"target", "targets", target.id, &Targets.page_target_references/2,
           &Targets.get_target/2, "operating_instructions"},
          {"provider", "providers", provider.id, &Providers.page_provider_references/2,
           &Providers.get_active_provider/2, "name"},
          {"target", "targets", target.id, &Targets.page_target_references/2,
           &Targets.get_target/2, "name"}
        ] do
      Skopos.Repo.query!(
        "ALTER TABLE #{table} RENAME COLUMN #{column} TO unavailable_reference_column"
      )

      try do
        if column == "name" do
          assert {:error, %Ash.Error.Unknown{} = cause} =
                   page.(%{ids: [id]}, actor: context.admin, page: [limit: 100])

          assert Exception.message(cause) =~ "does not exist"

          capture_log(fn ->
            assert {:error, :http, 500, %{"error" => %{"code" => "internal_error"}}} =
                     SkoposCLI.Client.request(
                       client!(context),
                       :get,
                       "/#{table}/references",
                       nil,
                       ids: id
                     )

            error =
              capture_io(:stderr, fn ->
                assert CLI.run([resource, "references", "--ids", id], context.runtime) == 4
              end)

            assert Jason.decode!(error)["error"]["code"] == "internal_error"
          end)
        else
          assert {:ok, %Ash.Page.Keyset{results: [%{id: ^id}]}} =
                   page.(%{ids: [id]}, actor: context.admin, page: [limit: 100])

          assert [%{"id" => ^id}] = cli_data!(context, [resource, "references", "--ids", id])
          # Public detail keeps the complete record contract and reports the real failure.
          assert {:error, %Ash.Error.Unknown{} = cause} = get.(id, actor: context.admin)
          assert Exception.message(cause) =~ "does not exist"

          capture_log(fn ->
            assert {:error, :http, 500, %{"error" => %{"code" => "internal_error"}}} =
                     SkoposCLI.Client.request(client!(context), :get, "/#{table}/#{id}")
          end)
        end
      after
        Skopos.Repo.query!(
          "ALTER TABLE #{table} RENAME COLUMN unavailable_reference_column TO #{column}"
        )
      end

      assert [%{"id" => ^id}] = cli_data!(context, [resource, "references", "--ids", id])
    end
  end

  @tag target_summaries_cli: true
  test "management summaries omit detail storage and preserve count or endpoint read failures",
       context do
    provider =
      Providers.create_provider!(
        "Summary connection",
        :target,
        "fixture-target",
        %{"endpoint" => "reachable"},
        %{"token" => "fixture-private"},
        actor: context.admin
      )
      |> then(&Providers.enable_provider!(&1, &1.revision, actor: context.admin))

    target =
      Targets.create_target!("Summary host", "host", "custom-os", %{"private" => "detail"}, nil,
        actor: context.admin
      )

    peer =
      Targets.create_target!("Summary peer", "host", "custom-os", %{}, nil, actor: context.admin)

    method =
      Targets.create_access_method!(
        target.id,
        provider.id,
        "SSH",
        "ssh",
        "ssh://192.0.2.10:22",
        provider.revision,
        100,
        [],
        actor: context.admin
      )

    Targets.create_relationship!(target.id, peer.id, "connected_to", %{}, nil,
      actor: context.admin
    )

    id = target.id
    method_id = method.id
    args = ["target", "summaries", "--ids", id]
    expected = cli_data!(context, args)

    assert [
             %{
               "method_count" => 1,
               "relationship_count" => 1,
               "methods" => [%{"id" => ^method_id}]
             }
           ] = expected

    for {table, column, required?} <- [
          {"targets", "facts", false},
          {"targets", "search_text", false},
          {"access_methods", "operation_catalog", false},
          {"access_methods", "check_attempt_id", false},
          {"relationships", "facts", false},
          {"providers", "configuration", false},
          {"providers", "encrypted_credentials", false},
          {"targets", "name", true},
          {"targets", "operating_instructions", true},
          {"access_methods", "endpoint", true},
          {"access_methods", "active", true},
          {"relationships", "active", true}
        ] do
      Skopos.Repo.query!(
        "ALTER TABLE #{table} RENAME COLUMN #{column} TO unavailable_summary_column"
      )

      try do
        if required? do
          assert {:error, %Ash.Error.Unknown{} = cause} =
                   Targets.page_target_summaries(%{ids: [id]},
                     actor: context.admin,
                     page: [limit: 100]
                   )

          assert Exception.message(cause) =~ "does not exist"

          capture_log(fn ->
            assert {:error, :http, 500, %{"error" => %{"code" => "internal_error"}}} =
                     SkoposCLI.Client.request(client!(context), :get, "/targets/summaries", nil,
                       ids: id
                     )

            error = capture_io(:stderr, fn -> assert CLI.run(args, context.runtime) == 4 end)
            assert Jason.decode!(error)["error"]["code"] == "internal_error"
          end)
        else
          assert {:ok, %Ash.Page.Keyset{results: [%{id: ^id, access_methods: [method]} = row]}} =
                   Targets.page_target_summaries(%{ids: [id]},
                     actor: context.admin,
                     page: [limit: 100]
                   )

          assert row.method_count == 1
          assert row.relationship_count == 1
          refute Ash.Resource.selected?(row, :facts)
          refute Ash.Resource.selected?(row, :operating_instructions)
          refute Ash.Resource.selected?(method, :operation_catalog)
          refute Ash.Resource.selected?(method, :check_attempt_id)
          assert cli_data!(context, args) == expected
        end
      after
        Skopos.Repo.query!(
          "ALTER TABLE #{table} RENAME COLUMN unavailable_summary_column TO #{column}"
        )
      end

      assert cli_data!(context, args) == expected
    end
  end

  defp client!(context) do
    {:ok, config} = Config.load(context.runtime[:config_path])

    {:ok, client} =
      SkoposCLI.Client.new(config["server"], config["token"], context.runtime[:request_options])

    client
  end

  defp cli_data!(context, args, input \\ nil) do
    output =
      if input do
        capture_io(Jason.encode!(input), fn ->
          assert CLI.run(args ++ ["--input", "-"], context.runtime) == 0
        end)
      else
        capture_io(fn -> assert CLI.run(args, context.runtime) == 0 end)
      end

    output |> Jason.decode!() |> Map.fetch!("data")
  end
end
