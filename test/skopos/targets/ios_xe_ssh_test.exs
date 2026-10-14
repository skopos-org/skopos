defmodule Skopos.Targets.IOSXESSHTest do
  use Skopos.DataCase, async: false

  alias Skopos.{Accounts, Providers, Targets}
  alias Skopos.Providers.Target
  alias Skopos.Targets.TargetRequest.Request
  alias Skopos.Targets.Profiles.IOSXE.SSH, as: IOSXESSH

  @password "correct horse battery staple"
  @capabilities [
    "observe.system",
    "observe.interface",
    "effect.interface",
    "request.cli.observe",
    "request.cli.effect"
  ]

  test "CLI redirection and embedded commands cannot enter the observation path" do
    request = fn command, capability, operation ->
      %Target.MethodRequest{
        provider_revision: 1,
        connection: %Target.Connection{endpoint: "ssh://router.example"},
        capability: capability,
        operation: operation,
        selectors: %{},
        parameters: %{"commands" => [command]}
      }
    end

    for command <- [
          "show version | redirect flash:report.txt",
          "show version\nconfigure terminal"
        ] do
      assert {:error, :failed, _reason} =
               Target.classify_request(
                 IOSXESSH,
                 nil,
                 request.(command, "request.cli.observe", "cli.observe")
               )
    end

    assert {:ok, %Target.RequestClassification{kind: :effect}} =
             Target.classify_request(
               IOSXESSH,
               nil,
               request.(
                 "show version | redirect flash:report.txt",
                 "request.cli.effect",
                 "cli.execute"
               )
             )
  end

  defmodule CLI do
    @behaviour :ssh_server_channel

    @impl true
    def init([agent]), do: {:ok, %{agent: agent, connection: nil, channel: nil, input: ""}}

    @impl true
    def handle_msg({:ssh_channel_up, channel, connection}, state),
      do: {:ok, %{state | connection: connection, channel: channel}}

    def handle_msg(_message, state), do: {:ok, state}

    @impl true
    def handle_ssh_msg(
          {:ssh_cm, connection, {:pty, channel, want_reply, _pty}},
          state
        ) do
      :ssh_connection.reply_request(connection, want_reply, :success, channel)
      {:ok, %{state | connection: connection, channel: channel}}
    end

    def handle_ssh_msg(
          {:ssh_cm, connection, {:shell, channel, want_reply}},
          state
        ) do
      :ssh_connection.reply_request(connection, want_reply, :success, channel)
      {:ok, %{state | connection: connection, channel: channel}}
    end

    def handle_ssh_msg(
          {:ssh_cm, connection, {:data, channel, _stream, data}},
          state
        ) do
      input = state.input <> data

      if String.ends_with?(input, "exit\n") do
        {output, delay_ms} = response(state.agent, input)
        Process.sleep(delay_ms)
        :ssh_connection.send(connection, channel, output)
        :ssh_connection.send_eof(connection, channel)
        :ssh_connection.exit_status(connection, channel, 0)
        {:stop, channel, %{state | input: input}}
      else
        {:ok, %{state | input: input}}
      end
    end

    def handle_ssh_msg({:ssh_cm, _connection, {:eof, channel}}, state),
      do: {:stop, channel, state}

    def handle_ssh_msg(_message, state), do: {:ok, state}

    @impl true
    def terminate(_reason, _state), do: :ok

    defp response(agent, script) do
      Agent.get_and_update(agent, fn state ->
        state = %{state | scripts: [script | state.scripts]}

        {output, state} =
          cond do
            String.contains?(script, "show version") ->
              {"hostname router-one\r\nCisco IOS XE Software, Version 17.15.01\r\n", state}

            String.contains?(script, "configure terminal") ->
              configure_response(script, state)

            String.contains?(script, "show interfaces") ->
              {interface_response(state), state}
          end

        {{output, state.delay_ms}, state}
      end)
    end

    defp configure_response(_script, %{reject_effect?: true} = state) do
      {"% Invalid input detected at '^' marker.\r\n", %{state | reject_effect?: false}}
    end

    defp configure_response(script, state) do
      interface = state.interface

      interface =
        cond do
          match = Regex.run(~r/^description (.+)$/m, script) ->
            Map.put(interface, :description, Enum.at(match, 1))

          String.contains?(script, "\nno shutdown\n") ->
            Map.put(interface, :enabled, true)

          String.contains?(script, "\nshutdown\n") ->
            Map.put(interface, :enabled, false)
        end

      {"router-one(config-if)#\r\n", %{state | interface: interface}}
    end

    defp interface_response(%{invalid_interface?: true}), do: "interface data unavailable\r\n"

    defp interface_response(%{interface: interface}) do
      admin = if interface.enabled, do: "up", else: "administratively down"
      operational = if interface.enabled, do: "up", else: "down"

      """
      interface Loopback100\r
       description #{interface.description}\r
      !\r
      Loopback100 is #{admin}, line protocol is #{operational}\r
        Description: #{interface.description}\r
           2 input errors, 0 CRC, 0 frame, 0 overrun, 0 ignored\r
           3 output errors, 0 collisions, 1 interface resets\r
      """
    end
  end

  setup_all do
    directory =
      Path.join(
        System.tmp_dir!(),
        "skopos-ios-xe-ssh-test-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(directory)
    host_key = :public_key.generate_key({:rsa, 2_048, 65_537})
    private_key = :public_key.pem_entry_encode(:RSAPrivateKey, host_key)
    host_key_path = Path.join(directory, "ssh_host_rsa_key")
    File.write!(host_key_path, :public_key.pem_encode([private_key]))
    File.chmod!(host_key_path, 0o600)

    {:ok, agent} =
      Agent.start_link(fn ->
        %{
          scripts: [],
          delay_ms: 0,
          reject_effect?: false,
          invalid_interface?: false,
          interface: %{description: "initial", enabled: true}
        }
      end)

    {:ok, daemon} =
      :ssh.daemon(0,
        system_dir: String.to_charlist(directory),
        user_passwords: [{~c"tester", ~c"secret"}],
        auth_methods: ~c"password",
        ssh_cli: {CLI, [agent]}
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

    %{endpoint: endpoint, fingerprint: fingerprint, agent: agent}
  end

  setup context do
    Agent.update(context.agent, fn _state ->
      %{
        scripts: [],
        delay_ms: 0,
        reject_effect?: false,
        invalid_interface?: false,
        interface: %{description: "initial", enabled: true}
      }
    end)

    admin = Accounts.bootstrap!("iosxe-ssh-admin@example.com", @password, @password)

    operator =
      Accounts.create_user!("iosxe-ssh-operator@example.com", @password, :operator, actor: admin)

    provider =
      Providers.create_provider!(
        "ios-xe-ssh",
        :target,
        "ios-xe-ssh",
        configuration(context),
        credentials(),
        actor: admin
      )
      |> then(&Providers.enable_provider!(&1, &1.revision, actor: admin))

    target =
      Targets.create_target!("router-one", "network_device", "cisco_ios_xe", %{}, nil,
        actor: admin
      )

    method =
      Targets.create_access_method!(
        target.id,
        provider.id,
        "SSH CLI",
        "ssh_cli",
        context.endpoint,
        provider.revision,
        100,
        @capabilities,
        actor: admin
      )
      |> then(&Targets.check_access_method!(&1.id, &1.revision, %{}, actor: admin))

    Map.merge(context, %{
      admin: admin,
      operator: operator,
      provider: provider,
      target: target,
      method: method
    })
  end

  test "Custom network device runs an exact generic SSH shell request", context do
    provider =
      Providers.create_provider!(
        "generic-ssh",
        :target,
        "ssh",
        configuration(context),
        credentials(),
        actor: context.admin
      )
      |> then(&Providers.enable_provider!(&1, &1.revision, actor: context.admin))

    target =
      Targets.create_target!(
        "unknown-router",
        "network_device",
        "custom-network-device",
        %{},
        nil,
        actor: context.admin
      )

    method =
      Targets.create_access_method!(
        target.id,
        provider.id,
        "SSH",
        "ssh",
        context.endpoint,
        provider.revision,
        100,
        ["request.ssh.effect"],
        actor: context.admin
      )
      |> then(&Targets.check_access_method!(&1.id, &1.revision, %{}, actor: context.admin))

    generic = %{context | target: target, method: method}

    shell =
      request(
        generic,
        :effect,
        "request.ssh.effect",
        "shell.execute",
        %{},
        %{"script" => "show version\nexit\n"}
      )

    assert %Target.EffectResult{
             status: :applied,
             details: %{"output" => %{"encoding" => "utf-8", "value" => output}}
           } =
             shell
             |> Targets.clear_target_request!(actor: context.operator)
             |> Targets.dispatch_target_effect!(%{}, actor: context.operator, authorize?: false)

    assert String.contains?(output, "Cisco IOS XE Software")

    assert %Target.EffectResult{status: :applied} =
             request(
               generic,
               :effect,
               "request.ssh.effect",
               "shell.execute",
               %{},
               %{"script" => "configure terminal\ninterface Loopback100\nshutdown\nexit\n"}
             )
             |> Targets.clear_target_request!(actor: context.operator)
             |> Targets.dispatch_target_effect!(%{}, actor: context.operator, authorize?: false)

    assert scripts(context) == [
             "show version\nexit\n",
             "configure terminal\ninterface Loopback100\nshutdown\nexit\n"
           ]

    Agent.update(context.agent, &%{&1 | delay_ms: 1_000})
    scripts_before_dispatch = length(scripts(context))

    assert %Target.EffectResult{
             status: :unknown,
             details: %{"error" => "SSH operation was cancelled"}
           } =
             request(
               generic,
               :effect,
               "request.ssh.effect",
               "shell.execute",
               %{},
               %{"script" => "show version\nexit\n"}
             )
             |> Targets.clear_target_request!(actor: context.operator)
             |> Targets.dispatch_target_effect!(
               %{cancelled?: fn -> length(scripts(context)) > scripts_before_dispatch end},
               actor: context.operator,
               authorize?: false
             )

    assert length(scripts(context)) == 3

    assert %Target.EffectResult{status: :unknown} =
             request(
               generic,
               :effect,
               "request.ssh.effect",
               "shell.execute",
               %{},
               %{"script" => "show version\nexit\n"}
             )
             |> Targets.clear_target_request!(actor: context.operator)
             |> Targets.dispatch_target_effect!(%{}, actor: context.operator, authorize?: false)

    assert length(scripts(context)) == 4
  end

  test "generic SSH shell returns unknown after exceeding its output limit", context do
    provider =
      Providers.create_provider!(
        "limited-generic-ssh",
        :target,
        "ssh",
        Map.put(configuration(context), "max_output_bytes", 8),
        credentials(),
        actor: context.admin
      )
      |> then(&Providers.enable_provider!(&1, &1.revision, actor: context.admin))

    target =
      Targets.create_target!(
        "limited-router",
        "network_device",
        "custom-network-device",
        %{},
        nil,
        actor: context.admin
      )

    method =
      Targets.create_access_method!(
        target.id,
        provider.id,
        "SSH",
        "ssh",
        context.endpoint,
        provider.revision,
        100,
        ["request.ssh.effect"],
        actor: context.admin
      )
      |> then(&Targets.check_access_method!(&1.id, &1.revision, %{}, actor: context.admin))

    assert %Target.EffectResult{status: :unknown} =
             request(
               %{context | target: target, method: method},
               :effect,
               "request.ssh.effect",
               "shell.execute",
               %{},
               %{"script" => "show version\nexit\n"}
             )
             |> Targets.clear_target_request!(actor: context.operator)
             |> Targets.dispatch_target_effect!(%{}, actor: context.operator, authorize?: false)

    assert length(scripts(context)) == 1
  end

  test "public SSH route constructs CLI commands, observes, applies and freshly verifies",
       context do
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
           |> Enum.map(& &1.operation) ==
             [
               "ios_xe.system.inspect",
               "ios_xe.interface.inspect",
               "cli.observe"
             ]

    assert effects
           |> Enum.reject(&String.starts_with?(&1.operation, "sftp."))
           |> Enum.map(& &1.operation) ==
             [
               "ios_xe.interface.description.set",
               "ios_xe.interface.admin_state.set",
               "cli.execute",
               "command.execute",
               "shell.execute",
               "subsystem.session"
             ]

    assert {:error, _denied} =
             request(
               context,
               :observation,
               "request.cli.observe",
               "cli.observe",
               %{},
               %{"commands" => ["configure terminal"]}
             )
             |> Targets.clear_target_request(actor: context.operator)

    assert %Target.Observation{facts: %{"output" => method_output}} =
             request(
               context,
               :observation,
               "request.cli.observe",
               "cli.observe",
               %{},
               %{"commands" => ["show version"]}
             )
             |> Targets.clear_target_request!(actor: context.operator)
             |> Targets.dispatch_target_observation!(%{}, actor: context.operator)

    assert method_output =~ "Cisco IOS XE Software, Version 17.15.01"

    system = observe!(context, "observe.system", "ios_xe.system.inspect", %{})
    assert system.facts == %{"hostname" => "router-one", "version" => "17.15.01"}

    interface =
      observe!(context, "observe.interface", "ios_xe.interface.inspect", %{
        "interface" => "Loopback100"
      })

    assert interface.facts == %{
             "name" => "Loopback100",
             "description" => "initial",
             "enabled" => true,
             "admin_status" => "up",
             "oper_status" => "up",
             "input_errors" => 2,
             "output_errors" => 3
           }

    assert %Target.EffectResult{status: :applied} =
             effect!(context, "ios_xe.interface.description.set", %{
               "description" => "changed",
               "expected_description" => "initial"
             })

    assert %Target.Verification{status: :verified, facts: %{"description" => "changed"}} =
             verify!(context, %{"description" => "changed"})

    assert %Target.EffectResult{status: :applied} =
             effect!(context, "ios_xe.interface.admin_state.set", %{
               "enabled" => false,
               "expected_enabled" => true
             })

    assert %Target.Verification{status: :verified, facts: %{"enabled" => false}} =
             verify!(context, %{"enabled" => false})

    scripts = scripts(context)
    assert Enum.any?(scripts, &String.contains?(&1, "show version | include"))
    assert Enum.any?(scripts, &String.contains?(&1, "description changed"))
    assert Enum.any?(scripts, &String.contains?(&1, "\nshutdown\n"))
    assert Enum.all?(scripts, &String.starts_with?(&1, "terminal length 0\nterminal width 511\n"))
  end

  for {adapter, kind, type, protocol} <- [
        {"linux-ssh", "host", "linux", "ssh"},
        {"ios-xe-ssh", "network_device", "cisco_ios_xe", "ssh_cli"}
      ] do
    @tag adapter: adapter, kind: kind, type: type, protocol: protocol
    test "#{adapter} retains generic SSH exec and shell in the same checked Method", context do
      provider =
        Providers.create_provider!(
          "shared-" <> context.adapter,
          :target,
          context.adapter,
          configuration(context),
          credentials(),
          actor: context.admin
        )
        |> then(&Providers.enable_provider!(&1, &1.revision, actor: context.admin))

      target =
        Targets.create_target!(context.adapter, context.kind, context.type, %{}, nil,
          actor: context.admin
        )

      method =
        Targets.create_access_method!(
          target.id,
          provider.id,
          "shared SSH",
          context.protocol,
          context.endpoint,
          provider.revision,
          100,
          ["request.ssh.effect"],
          actor: context.admin
        )
        |> then(&Targets.check_access_method!(&1.id, &1.revision, %{}, actor: context.admin))

      assert method.check_status == :passed
      assert Enum.any?(method.operation_catalog.effects, &(&1.operation == "command.execute"))
      assert Enum.any?(method.operation_catalog.effects, &(&1.operation == "shell.execute"))
      context = %{context | provider: provider, target: target, method: method}
      script = "show version\nexit\n"

      assert {:error, _} =
               request(context, :observation, "request.ssh.effect", "shell.execute", %{}, %{
                 "script" => script
               })
               |> Targets.clear_target_request(actor: context.operator)

      clearance =
        request(context, :effect, "request.ssh.effect", "shell.execute", %{}, %{
          "script" => script
        })
        |> Targets.clear_target_request!(actor: context.operator)

      result =
        Targets.dispatch_target_effect!(clearance, %{},
          actor: context.operator,
          authorize?: false
        )

      assert result.status == :applied
      assert result.details["output"]["value"] =~ "Cisco IOS XE Software"
      assert scripts(context) == [script]

      exec =
        request(context, :effect, "request.ssh.effect", "command.execute", %{}, %{
          "command" => "show version"
        })
        |> Targets.clear_target_request!(actor: context.operator)

      assert {:error, _} =
               Targets.dispatch_target_effect(exec, %{cancelled?: fn -> true end},
                 actor: context.operator,
                 authorize?: false
               )

      assert scripts(context) == [script]

      Agent.update(context.agent, &%{&1 | delay_ms: 1000})

      uncertain =
        request(context, :effect, "request.ssh.effect", "shell.execute", %{}, %{
          "script" => script
        })
        |> Targets.clear_target_request!(actor: context.operator)

      unknown =
        Targets.dispatch_target_effect!(uncertain, %{},
          actor: context.operator,
          authorize?: false
        )

      assert unknown.status == :unknown
      assert scripts(context) == [script, script]
    end
  end

  test "SSH route rejects stale state, IOS errors and invalid replies without applying",
       context do
    assert %Target.EffectResult{
             status: :failed,
             details: %{"category" => "stale", "field" => "description", "observed" => "initial"}
           } =
             effect!(context, "ios_xe.interface.description.set", %{
               "description" => "changed",
               "expected_description" => "outdated"
             })

    refute Enum.any?(scripts(context), &String.contains?(&1, "configure terminal"))

    Agent.update(context.agent, &%{&1 | reject_effect?: true})

    assert %Target.EffectResult{status: :failed, details: %{"category" => "rejected"}} =
             effect!(context, "ios_xe.interface.admin_state.set", %{
               "enabled" => false,
               "expected_enabled" => true
             })

    Agent.update(context.agent, &%{&1 | invalid_interface?: true})

    request =
      request(
        context,
        :observation,
        "observe.interface",
        "ios_xe.interface.inspect",
        %{"interface" => "Loopback100"},
        %{}
      )

    clearance = Targets.clear_target_request!(request, actor: context.operator)

    assert {:error, _error} =
             Targets.dispatch_target_observation(clearance, %{}, actor: context.operator)
  end

  @tag profile_context_fault: true
  test "IOS XE SSH keeps original in-flight context faults across all three ports", context do
    Agent.update(context.agent, &%{&1 | delay_ms: 1_000})

    for {kind, capability, operation, selectors, parameters, dispatch} <- [
          {:observation, "observe.system", "ios_xe.system.inspect", %{}, %{},
           &Targets.dispatch_target_observation/3},
          {:effect, "request.cli.effect", "cli.execute", %{}, %{"commands" => ["show version"]},
           &Targets.dispatch_target_effect/3},
          {:verification, "request.cli.observe", "cli.observe", %{},
           %{"commands" => ["show version"]}, &Targets.dispatch_target_verification/3}
        ] do
      Agent.update(context.agent, &%{&1 | scripts: []})

      clearance =
        request(context, kind, capability, operation, selectors, parameters)
        |> Targets.clear_target_request!(actor: context.operator)

      callback = fn ->
        if scripts(context) != [] do
          {:error, cause} =
            Skopos.Repo.query("SELECT iosxe_ssh_context_unavailable", [], mode: :savepoint)

          raise cause
        end

        false
      end

      assert {:error, error} =
               dispatch.(clearance, %{cancelled?: callback},
                 actor: context.operator,
                 authorize?: false
               )

      assert Exception.message(error) =~ "iosxe_ssh_context_unavailable"
      assert Target.Error.context_failure?(error)
      assert length(scripts(context)) == 1
    end
  end

  test "SSH route preserves post-dispatch cancellation and connection failures", context do
    Agent.update(context.agent, &%{&1 | delay_ms: 1_000})
    scripts_before_dispatch = length(scripts(context))

    effect =
      request(
        context,
        :effect,
        "effect.interface",
        "ios_xe.interface.description.set",
        %{"interface" => "Loopback100"},
        %{"description" => "changed", "expected_description" => "initial"}
      )

    clearance = Targets.clear_target_request!(effect, actor: context.operator)

    assert %Target.EffectResult{
             status: :unknown,
             details: %{"error" => "SSH operation was cancelled"}
           } =
             Targets.dispatch_target_effect!(
               clearance,
               %{cancelled?: fn -> length(scripts(context)) > scripts_before_dispatch end},
               actor: context.operator,
               authorize?: false
             )

    assert length(scripts(context)) == scripts_before_dispatch + 1

    unreachable =
      Providers.create_provider!(
        "unreachable-ios-xe-ssh",
        :target,
        "ios-xe-ssh",
        %{
          "host_key_fingerprints" => %{
            "ssh://127.0.0.1:1" => context.fingerprint
          },
          "connect_timeout_ms" => 100,
          "operation_timeout_ms" => 100
        },
        credentials(),
        actor: context.admin
      )

    failed =
      Skopos.TargetConnectionFixture.check_connection(
        unreachable,
        "ssh://127.0.0.1:1",
        context.admin
      )

    assert {:error, _} = failed
  end

  defp observe!(context, capability, operation, selectors) do
    request(context, :observation, capability, operation, selectors, %{})
    |> Targets.clear_target_request!(actor: context.operator)
    |> Targets.dispatch_target_observation!(%{}, actor: context.operator)
  end

  defp effect!(context, operation, parameters) do
    request(
      context,
      :effect,
      "effect.interface",
      operation,
      %{"interface" => "Loopback100"},
      parameters
    )
    |> Targets.clear_target_request!(actor: context.operator)
    |> Targets.dispatch_target_effect!(%{}, actor: context.operator, authorize?: false)
  end

  defp verify!(context, expected) do
    request(
      context,
      :verification,
      "observe.interface",
      "ios_xe.interface.inspect",
      %{"interface" => "Loopback100"},
      %{},
      expected
    )
    |> Targets.clear_target_request!(actor: context.operator)
    |> Targets.dispatch_target_verification!(%{}, actor: context.operator)
  end

  defp request(context, kind, capability, operation, selectors, parameters, expected \\ %{}) do
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
      operation_id: if(kind in [:effect, :verification], do: Ecto.UUID.generate()),
      idempotency_key: if(kind == :effect, do: Ecto.UUID.generate()),
      expected: expected
    )
  end

  defp configuration(context) do
    %{
      "host_key_fingerprints" => %{context.endpoint => context.fingerprint},
      "connect_timeout_ms" => 2_000,
      "operation_timeout_ms" => 500,
      "max_output_bytes" => 32_768
    }
  end

  defp credentials do
    %{"username" => "tester", "auth_method" => "password", "password" => "secret"}
  end

  defp scripts(context), do: Agent.get(context.agent, &Enum.reverse(&1.scripts))
end
