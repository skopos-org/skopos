defmodule Skopos.Targets.LinuxSSHTest do
  use Skopos.DataCase, async: false

  alias Skopos.{Accounts, Providers, Targets}
  alias Skopos.Providers.Target
  alias Skopos.Targets.Profiles.Linux.SSH, as: LinuxSSH
  alias Skopos.Targets.TargetRequest.Request
  alias Skopos.Targets.ResourceScope

  @password "correct horse battery staple"
  @definition String.duplicate("a", 64)
  @capabilities [
    "observe.identity",
    "observe.processes",
    "observe.service",
    "observe.journal",
    "effect.service",
    "request.ssh.effect"
  ]

  setup_all do
    directory =
      Path.join(System.tmp_dir!(), "skopos-linux-ssh-test-#{System.unique_integer([:positive])}")

    File.mkdir_p!(directory)
    host_key = :public_key.generate_key({:rsa, 2_048, 65_537})
    private_key = :public_key.pem_entry_encode(:RSAPrivateKey, host_key)
    host_key_path = Path.join(directory, "ssh_host_rsa_key")
    File.write!(host_key_path, :public_key.pem_encode([private_key]))
    File.chmod!(host_key_path, 0o600)
    {:ok, commands} = Agent.start_link(fn -> [] end)

    {:ok, daemon} =
      :ssh.daemon(0,
        system_dir: String.to_charlist(directory),
        user_passwords: [{~c"tester", ~c"secret"}],
        auth_methods: ~c"password",
        exec: {:direct, executor(commands)}
      )

    {:ok, info} = :ssh.daemon_info(daemon)
    endpoint = "ssh://127.0.0.1:#{Keyword.fetch!(info, :port)}"

    fingerprint =
      host_key
      |> :ssh_file.extract_public_key()
      |> then(&:ssh.hostkey_fingerprint(:sha256, &1))
      |> to_string()

    on_exit(fn ->
      :ssh.stop_daemon(daemon)
      File.rm_rf!(directory)
    end)

    %{endpoint: endpoint, fingerprint: fingerprint, commands: commands}
  end

  setup context do
    Agent.update(context.commands, fn _commands -> [] end)

    admin = Accounts.bootstrap!("linux-ssh-admin@example.com", @password, @password)

    operator =
      Accounts.create_user!("linux-ssh-operator@example.com", @password, :operator, actor: admin)

    provider =
      Providers.create_provider!(
        "linux-ssh",
        :target,
        "linux-ssh",
        configuration(context),
        credentials(),
        actor: admin
      )
      |> then(&Providers.enable_provider!(&1, &1.revision, actor: admin))

    target = Targets.create_target!("linux-01", "host", "linux", %{}, nil, actor: admin)

    method =
      Targets.create_access_method!(
        target.id,
        provider.id,
        "linux-ssh",
        "ssh",
        context.endpoint,
        provider.revision,
        100,
        @capabilities,
        actor: admin
      )
      |> then(&Targets.check_access_method!(&1.id, &1.revision, %{}, actor: admin))

    Agent.update(context.commands, fn _commands -> [] end)

    Map.merge(context, %{
      admin: admin,
      operator: operator,
      provider: provider,
      target: target,
      method: method
    })
  end

  @tag profile_context_fault: true
  test "Linux named operations preserve initial context faults without sending commands",
       context do
    for {kind, capability, operation, selectors, parameters, expected, dispatch} <- [
          {:observation, "observe.identity", "linux.identity.inspect", %{}, %{}, %{},
           &Targets.dispatch_target_observation/3},
          {:effect, "effect.service", "linux.service.restart", %{"unit" => "api.service"},
           %{"expected_definition_sha256" => @definition}, %{},
           &Targets.dispatch_target_effect/3},
          {:verification, "observe.service", "linux.service.inspect", %{"unit" => "api.service"},
           %{}, %{"active_state" => "active"}, &Targets.dispatch_target_verification/3}
        ] do
      clearance =
        target_request(context, kind, capability, operation, selectors, parameters, expected)
        |> Targets.clear_target_request!(actor: context.operator)

      callback = fn ->
        {:error, cause} =
          Skopos.Repo.query("SELECT linux_initial_context_unavailable", [], mode: :savepoint)

        raise cause
      end

      assert {:error, error} =
               dispatch.(clearance, %{cancelled?: callback},
                 actor: context.operator,
                 authorize?: false
               )

      assert %Target.BeforeSendError{cause: cause} = Target.BeforeSendError.unwrap(error)
      assert Exception.message(cause) =~ "linux_initial_context_unavailable"
      assert commands(context) == []
    end
  end

  test "service operations lock the exact unit while shell Method effects lock the Target",
       context do
    assert ResourceScope.key(
             context.method,
             "effect.service",
             "linux.service.restart",
             %{"unit" => "api.service"}
           ) == "service:api.service"

    assert ResourceScope.key(
             context.method,
             "request.ssh.effect",
             "request.ssh.effect",
             %{"unit" => "api.service"}
           ) == "target"
  end

  test "public capabilities and observations accept bounded unknown Linux workloads", context do
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

    assert observations
           |> Enum.reject(&(&1.capability == "request.ssh.observe"))
           |> Enum.map(& &1.operation) == [
             "linux.identity.inspect",
             "linux.process.list",
             "linux.service.list",
             "linux.service.inspect",
             "linux.journal.read"
           ]

    tools = Map.new(observations, &{&1.operation, &1})
    service_tool = tools["linux.service.inspect"]

    assert Map.has_key?(service_tool.output_schema["properties"], "active_state")
    assert Map.has_key?(service_tool.output_schema["properties"], "sub_state")

    assert service_tool.verification_schema["properties"] == %{
             "active_state" => %{
               "type" => "string",
               "enum" => ["active"],
               "description" => "The canonical successful postcondition for linux.service.restart"
             }
           }

    assert service_tool.verification_schema["required"] == ["active_state"]
    assert_schema_accepts!(service_tool.verification_schema, %{"active_state" => "active"})

    assert_schema_rejects!(service_tool.verification_schema, %{
      "active_state" => "active",
      "sub_state" => "active"
    })

    assert_schema_rejects!(service_tool.verification_schema, %{"active_state" => "inactive"})

    [effect | _method_effects] = effects

    assert effects
           |> Enum.reject(&String.starts_with?(&1.operation, "sftp."))
           |> Enum.map(& &1.operation) == [
             "linux.service.restart",
             "command.execute",
             "shell.execute",
             "subsystem.session"
           ]

    assert effect.evidence_requirements == [
             %Target.EvidenceRequirement{
               parameter: "expected_definition_sha256",
               fact: "definition_sha256",
               observation: "linux.service.inspect"
             }
           ]

    assert get_in(effect.input_schema, [
             "properties",
             "parameters",
             "properties",
             "expected_definition_sha256",
             "description"
           ]) =~ "never infer or invent"

    identity = observe!(context, "observe.identity", "linux.identity.inspect", %{}, %{})
    assert_schema_accepts!(tools["linux.identity.inspect"].output_schema, identity.facts)
    assert identity.facts["kernel"] == "Linux 6.8.0 x86_64"
    assert identity.facts["machine_id"] == "machine-01"

    processes = observe!(context, "observe.processes", "linux.process.list", %{}, %{"limit" => 2})
    assert_schema_accepts!(tools["linux.process.list"].output_schema, processes.facts)
    assert Enum.map(processes.facts["processes"], & &1["command"]) == ["beam.smp", "sshd"]

    services =
      observe!(context, "observe.service", "linux.service.list", %{}, %{"limit" => 2})

    assert_schema_accepts!(tools["linux.service.list"].output_schema, services.facts)

    assert services.facts == %{
             "services" => [
               %{"unit" => "cron.service", "unit_file_state" => "enabled"},
               %{"unit" => "skopos-metrics.service", "unit_file_state" => "enabled"}
             ],
             "offset" => 0,
             "next_offset" => 2,
             "has_more" => true
           }

    assert_schema_rejects!(tools["linux.service.list"].input_schema, %{
      "selectors" => %{},
      "parameters" => %{"limit" => 201}
    })

    unit = "discovered@42.service"

    service =
      observe!(context, "observe.service", "linux.service.inspect", %{"unit" => unit}, %{})

    assert_schema_accepts!(service_tool.output_schema, service.facts)
    assert service.facts["unit"] == unit
    assert service.facts["active_state"] == "active"
    assert service.facts["definition_sha256"] == @definition

    journal =
      observe!(context, "observe.journal", "linux.journal.read", %{"unit" => unit}, %{
        "lines" => 2
      })

    assert_schema_accepts!(tools["linux.journal.read"].output_schema, journal.facts)
    assert journal.facts == %{"unit" => unit, "entries" => ["entry one", "entry two"]}
  end

  test "restart binds the observed definition and fresh verification reads current state",
       context do
    unit = "discovered@42.service"

    effect =
      target_request(
        context,
        :effect,
        "effect.service",
        "linux.service.restart",
        %{"unit" => unit},
        %{
          "expected_definition_sha256" => @definition
        }
      )

    clearance = Targets.clear_target_request!(effect, actor: context.operator)

    assert %Target.EffectResult{status: :applied} =
             Targets.dispatch_target_effect!(clearance, %{},
               actor: context.operator,
               authorize?: false
             )

    [command] = commands(context)
    assert command =~ "actual="
    assert command =~ @definition
    assert command =~ "systemctl restart --"
    assert command =~ unit

    verification =
      target_request(
        context,
        :verification,
        "observe.service",
        "linux.service.inspect",
        %{"unit" => unit},
        %{},
        %{"active_state" => "active"}
      )

    verification_clearance =
      Targets.clear_target_request!(verification, actor: context.operator)

    assert %Target.Verification{status: :verified, facts: facts} =
             Targets.dispatch_target_verification!(verification_clearance, %{},
               actor: context.operator
             )

    assert facts["definition_sha256"] == @definition

    not_verified = %{verification | selectors: %{"unit" => "inactive.service"}}
    not_verified_clearance = Targets.clear_target_request!(not_verified, actor: context.operator)

    assert %Target.Verification{status: :not_verified} =
             Targets.dispatch_target_verification!(not_verified_clearance, %{},
               actor: context.operator
             )
  end

  test "configured privilege preserves shell variables and quoted compound commands", context do
    effect =
      target_request(
        context,
        :effect,
        "request.ssh.effect",
        "command.execute",
        %{},
        %{"command" => "V=\"skopos-shell-semantics 'quoted'\"; printf '%s' \"$V\""}
      )

    effect_clearance = Targets.clear_target_request!(effect, actor: context.operator)

    assert %Target.EffectResult{status: :applied, details: details} =
             Targets.dispatch_target_effect!(effect_clearance, %{},
               actor: context.operator,
               authorize?: false
             )

    assert details["stdout"] == %{
             "encoding" => "utf-8",
             "value" => "skopos-shell-semantics 'quoted'"
           }
  end

  test "raw SSH command cannot be cleared as an observation", context do
    request =
      target_request(
        context,
        :observation,
        "request.ssh.effect",
        "command.execute",
        %{},
        %{"command" => "curl http://127.0.0.1:18080/metrics"}
      )

    assert {:error, error} = Targets.clear_target_request(request, actor: context.operator)
    assert Exception.message(error) =~ "kind does not match Method classification"
    assert commands(context) == []
  end

  test "a full-size accepted script retains literal quotes under configured privilege", context do
    prefix = "V=\"skopos-shell-semantics "
    suffix = "\"; printf '%s' \"$V\""
    quotes = String.duplicate("'", 4_096 - byte_size(prefix) - byte_size(suffix))

    request =
      target_request(context, :effect, "request.ssh.effect", "command.execute", %{}, %{
        "command" => prefix <> quotes <> suffix
      })

    clearance = Targets.clear_target_request!(request, actor: context.operator)

    assert %Target.EffectResult{status: :applied, details: details} =
             Targets.dispatch_target_effect!(clearance, %{},
               actor: context.operator,
               authorize?: false
             )

    assert details["stdout"] == %{
             "encoding" => "utf-8",
             "value" => "skopos-shell-semantics " <> quotes
           }
  end

  test "unlisted shell command is an effect and cannot borrow another Target's Method", context do
    request =
      target_request(
        context,
        :effect,
        "request.ssh.effect",
        "command.execute",
        %{},
        %{"command" => "service nginx status"}
      )

    assert %Skopos.Targets.TargetRequest.Clearance{kind: :effect} =
             Targets.clear_target_request!(request, actor: context.operator)

    other = Targets.create_target!("other-host", "host", "linux", %{}, nil, actor: context.admin)

    borrowed = %{request | target_id: other.id, target_revision: other.revision}

    assert {:error, _error} = Targets.clear_target_request(borrowed, actor: context.operator)
    assert commands(context) == []
  end

  test "arbitrary Method effect remains unchanged when privilege is none", context do
    configuration = Map.put(configuration(context), "privilege", "none")
    assert {:ok, state} = LinuxSSH.build(configuration, credentials())

    request = %{
      capability: "request.ssh.effect",
      operation: "command.execute",
      selectors: %{},
      parameters: %{"command" => "uname -a"},
      connection: %{endpoint: context.endpoint}
    }

    assert {:ok, %Target.EffectResult{status: :applied}} = LinuxSSH.effect(state, request, %{})
    assert commands(context) == ["uname -a"]
  end

  test "invalid unit stops locally and post-dispatch timeout stays unknown", context do
    invalid =
      target_request(
        context,
        :effect,
        "effect.service",
        "linux.service.restart",
        %{"unit" => "../../etc/shadow"},
        %{"expected_definition_sha256" => @definition}
      )

    assert {:error, _error} =
             Targets.clear_target_request(invalid, actor: context.operator)

    assert commands(context) == []

    slow =
      target_request(
        context,
        :effect,
        "effect.service",
        "linux.service.restart",
        %{"unit" => "slow.service"},
        %{"expected_definition_sha256" => @definition}
      )

    slow_clearance = Targets.clear_target_request!(slow, actor: context.operator)

    assert %Target.EffectResult{status: :unknown} =
             Targets.dispatch_target_effect!(slow_clearance, %{},
               actor: context.operator,
               authorize?: false
             )
  end

  defp observe!(context, capability, operation, selectors, parameters) do
    request = target_request(context, :observation, capability, operation, selectors, parameters)
    clearance = Targets.clear_target_request!(request, actor: context.operator)
    Targets.dispatch_target_observation!(clearance, %{}, actor: context.operator)
  end

  defp target_request(
         context,
         kind,
         capability,
         operation,
         selectors,
         parameters,
         expected \\ %{}
       ) do
    struct!(Request,
      kind: kind,
      authority_mode: :full_access,
      target_id: context.target.id,
      target_revision: context.target.revision,
      access_method_id: context.method.id,
      access_method_revision: context.method.revision,
      capability: capability,
      operation: operation,
      selectors: selectors,
      parameters: parameters,
      operation_id:
        if(kind in [:effect, :verification], do: "operation-#{System.unique_integer()}"),
      idempotency_key: if(kind == :effect, do: "idempotency-#{System.unique_integer()}"),
      expected: expected
    )
  end

  defp configuration(context) do
    %{
      "host_key_fingerprints" => %{context.endpoint => context.fingerprint},
      "connect_timeout_ms" => 2_000,
      "operation_timeout_ms" => 500,
      "max_output_bytes" => 32_768,
      "privilege" => "sudo"
    }
  end

  defp credentials do
    %{"username" => "tester", "auth_method" => "password", "password" => "secret"}
  end

  defp commands(context), do: Agent.get(context.commands, &Enum.reverse/1)

  defp assert_schema_accepts!(schema, facts) do
    assert {:ok, root} = JSV.build(schema, warnings: :silent)
    assert {:ok, _validated} = JSV.validate(facts, root, cast: false)
  end

  defp assert_schema_rejects!(schema, facts) do
    assert {:ok, root} = JSV.build(schema, warnings: :silent)
    assert {:error, _error} = JSV.validate(facts, root, cast: false)
  end

  defp executor(commands) do
    fn command ->
      command = to_string(command)
      Agent.update(commands, &[command | &1])

      cond do
        String.contains?(command, "skopos-shell-semantics") ->
          # The SSH peer runs a real shell. This forwarding substitute exercises
          # script semantics without requiring privileged host access.
          forwarding = "sudo() { [ \"$1\" = -n ] && shift; [ \"$1\" = -- ] && shift; \"$@\"; }; "

          {output, status} =
            System.cmd("sh", ["-c", forwarding <> command], stderr_to_stdout: true)

          if status == 0, do: {:ok, output}, else: {:error, output}

        command in ["uname -a", "sudo -n uname -a"] ->
          {:ok, "Linux fixture\n"}

        command == "printf 'Kernel='; uname -srm; printf 'MachineId='; cat /etc/machine-id" ->
          {:ok, "Kernel=Linux 6.8.0 x86_64\nMachineId=machine-01\n"}

        String.starts_with?(command, "ps -eo") ->
          {:ok, "101 1 S beam.smp\n202 1 S sshd\n"}

        String.contains?(command, "systemctl list-unit-files") ->
          {:ok,
           "cron.service enabled enabled\n" <>
             "skopos-metrics.service enabled enabled\n" <>
             "sshd.service enabled enabled\n"}

        String.contains?(command, "journalctl") ->
          {:ok, "entry one\nentry two\n"}

        String.contains?(command, "systemctl restart") and
            String.contains?(command, "slow.service") ->
          Process.sleep(1_000)
          {:ok, ""}

        String.contains?(command, "systemctl restart") ->
          {:ok, ""}

        String.contains?(command, "systemctl show") and
            String.contains?(command, "inactive.service") ->
          {:ok,
           "Id=inactive.service\nLoadState=loaded\nActiveState=inactive\nSubState=dead\nUnitFileState=enabled\nFragmentPath=/etc/systemd/system/inactive.service\nDropInPaths=\nNeedDaemonReload=no\nExecMainPID=0\nDefinitionSHA256=#{@definition}\n"}

        String.contains?(command, "systemctl show") ->
          unit =
            if String.contains?(command, "discovered@42.service"),
              do: "discovered@42.service",
              else: "unknown.service"

          {:ok,
           "Id=#{unit}\nLoadState=loaded\nActiveState=active\nSubState=running\nUnitFileState=enabled\nFragmentPath=/etc/systemd/system/#{unit}\nDropInPaths=\nNeedDaemonReload=no\nExecMainPID=101\nDefinitionSHA256=#{@definition}\n"}

        true ->
          {:error, "unsupported command"}
      end
    end
  end
end
