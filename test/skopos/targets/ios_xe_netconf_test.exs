defmodule Skopos.Targets.IOSXENETCONFTest do
  use Skopos.DataCase, async: false

  alias Skopos.{Accounts, Providers, Targets}
  alias Skopos.Providers.Target
  alias Skopos.Targets.Adapters.NETCONF, as: GenericNETCONF
  alias Skopos.Targets.TargetRequest.Request
  alias Skopos.Targets.Profiles.IOSXE.NETCONF, as: NETCONF
  alias Skopos.Transports.SSH

  @password "correct horse battery staple"
  @capabilities ["observe.system", "observe.interface", "effect.interface"]

  defmodule Peer do
    @behaviour :ssh_server_channel

    @delimiter "]]>]]>"
    @server_hello """
    <hello xmlns="urn:ietf:params:xml:ns:netconf:base:1.0"><capabilities><capability>urn:ietf:params:netconf:base:1.0</capability><capability>urn:ietf:params:netconf:base:1.1</capability><capability>urn:ietf:params:netconf:capability:notification:1.0</capability></capabilities><session-id>1</session-id></hello>
    """

    @impl true
    def init([agent]),
      do:
        {:ok,
         %{
           agent: agent,
           session_id: System.unique_integer([:positive]),
           connection: nil,
           channel: nil,
           phase: :hello,
           input: ""
         }}

    @impl true
    def handle_msg({:ssh_channel_up, channel, connection}, state),
      do: {:ok, %{state | connection: connection, channel: channel}}

    def handle_msg(_message, state), do: {:ok, state}

    @impl true
    def handle_ssh_msg({:ssh_cm, connection, {:data, channel, _stream, data}}, state) do
      consume(%{state | connection: connection, channel: channel, input: state.input <> data})
    end

    def handle_ssh_msg({:ssh_cm, _connection, {:eof, channel}}, state),
      do: {:stop, channel, state}

    def handle_ssh_msg(_message, state), do: {:ok, state}

    @impl true
    def terminate(_reason, state) do
      if observer = Agent.get(state.agent, & &1.observer),
        do: send(observer, {:netconf_closed, state.session_id})

      :ok
    end

    defp consume(%{phase: :hello} = state) do
      case :binary.match(state.input, @delimiter) do
        {position, length} ->
          rest =
            binary_part(
              state.input,
              position + length,
              byte_size(state.input) - position - length
            )

          hello =
            if Agent.get(
                 state.agent,
                 &(&1.mode == :no_notification_capability or dynamic_mode?(&1.mode))
               ) do
              String.replace(
                @server_hello,
                "<capability>urn:ietf:params:netconf:capability:notification:1.0</capability>",
                ""
              )
            else
              @server_hello
            end

          :ok = :ssh_connection.send(state.connection, state.channel, hello <> @delimiter)
          consume(%{state | phase: :rpc, input: rest})

        :nomatch ->
          {:ok, state}
      end
    end

    defp consume(%{phase: :rpc} = state) do
      case chunk(state.input) do
        {:ok, rpc, rest} ->
          {reply, delay_ms} = response(state.agent, state.session_id, rpc)
          Process.sleep(delay_ms)

          mode = Agent.get(state.agent, & &1.mode)

          if dynamic_mode?(mode) and
               (String.contains?(rpc, "<modify-subscription") or
                  String.contains?(rpc, "<delete-subscription")) do
            :ok =
              :ssh_connection.send(
                state.connection,
                state.channel,
                frame(dynamic_notification("before-reply"))
              )
          end

          if mode == :dynamic_close_before_followup_reply and
               String.contains?(rpc, "<modify-subscription") do
            :ssh_connection.close(state.connection, state.channel)
          else
            :ok = :ssh_connection.send(state.connection, state.channel, frame(reply))
          end

          if dynamic_mode?(mode) and String.contains?(rpc, "<establish-subscription") do
            :ok =
              :ssh_connection.send(
                state.connection,
                state.channel,
                frame(dynamic_notification("established"))
              )
          end

          if String.contains?(rpc, "<create-subscription") do
            events =
              case mode do
                :drop_after_first_notification -> ["link-down"]
                :no_notification_events -> []
                _other -> ["link-down", "link-up"]
              end

            for event <- events do
              notification =
                case mode do
                  :malformed_notification ->
                    "<notification xmlns=\"urn:ietf:params:xml:ns:netconf:notification:1.0\"><#{event} xmlns=\"urn:vendor:events\"/></notification>"

                  :malformed_notification_time ->
                    "<notification xmlns=\"urn:ietf:params:xml:ns:netconf:notification:1.0\"><eventTime>invalid</eventTime><#{event} xmlns=\"urn:vendor:events\"/></notification>"

                  _other ->
                    "<notification xmlns=\"urn:ietf:params:xml:ns:netconf:notification:1.0\"><eventTime>2026-09-29T00:00:00Z</eventTime><#{event} xmlns=\"urn:vendor:events\"/></notification>"
                end

              payload =
                if mode == :truncated_notification,
                  do: binary_part(frame(notification), 0, 20),
                  else: frame(notification)

              if :ssh_connection.send(state.connection, state.channel, payload) == :ok,
                do:
                  Agent.update(
                    state.agent,
                    &%{&1 | notifications_sent: &1.notifications_sent + 1}
                  )

              if mode == :hold_after_first_notification and event == "link-down",
                do: Process.sleep(1_000)
            end

            if mode == :drop_after_first_notification,
              do: :ssh_connection.close(state.connection, state.channel)
          end

          consume(%{state | input: rest})

        :more ->
          {:ok, state}
      end
    end

    defp chunk("\n#" <> framed) do
      case :binary.match(framed, "\n") do
        {position, 1} ->
          length_text = binary_part(framed, 0, position)
          payload = binary_part(framed, position + 1, byte_size(framed) - position - 1)

          case Integer.parse(length_text) do
            {length, ""} when length > 0 and byte_size(payload) >= length + 4 ->
              rpc = binary_part(payload, 0, length)
              "\n##\n" <> rest = binary_part(payload, length, byte_size(payload) - length)
              {:ok, rpc, rest}

            _other ->
              :more
          end

        :nomatch ->
          :more
      end
    end

    defp chunk(_input), do: :more
    defp frame(xml), do: "\n##{byte_size(xml)}\n#{xml}\n##\n"

    defp dynamic_notification(event) do
      "<notification xmlns=\"urn:ietf:params:xml:ns:netconf:notification:1.0\"><eventTime>2026-09-29T00:00:00Z</eventTime><#{event} xmlns=\"urn:vendor:events\"/></notification>"
    end

    defp dynamic_mode?(mode),
      do:
        mode in [
          :dynamic_subscription,
          :dynamic_wrong_followup_id,
          :dynamic_close_before_followup_reply,
          :dynamic_rpc_error
        ]

    defp response(agent, session_id, rpc) do
      {result, observer} =
        Agent.get_and_update(agent, fn state ->
          state = %{state | rpcs: [rpc | state.rpcs], sessions: [session_id | state.sessions]}
          {reply, delay_ms, state} = rpc_response(rpc, state)

          reply =
            case Regex.run(~r/message-id="([^"]+)"/, rpc) do
              [_, message_id] when message_id != "skopos-1" ->
                String.replace(reply, "message-id=\"skopos-1\"", "message-id=\"#{message_id}\"")

              _other ->
                reply
            end

          reply =
            if state.mode == :dynamic_wrong_followup_id and
                 String.contains?(rpc, "<modify-subscription") do
              Regex.replace(~r/message-id="[^"]+"/, reply, "message-id=\"wrong\"")
            else
              reply
            end

          {{{reply, delay_ms}, state.observer}, state}
        end)

      if observer, do: send(observer, {:netconf_rpc, session_id})
      result
    end

    defp rpc_response(rpc, state) do
      cond do
        state.mode == :malformed ->
          {"not xml", 0, %{state | mode: :normal}}

        state.mode == :wrong_message_id ->
          {system_reply("wrong"), 0, %{state | mode: :normal}}

        state.mode == :wrong_second_message_id and String.contains?(rpc, "<edit-config>") ->
          {system_reply("wrong"), 0, %{state | mode: :normal}}

        state.mode == :slow_subscription_ack and String.contains?(rpc, "<create-subscription") ->
          {system_reply("skopos-1"), 250, state}

        dynamic_mode?(state.mode) and String.contains?(rpc, "<establish-subscription") ->
          {"<rpc-reply xmlns=\"urn:ietf:params:xml:ns:netconf:base:1.0\" message-id=\"skopos-1\"><id xmlns=\"urn:ietf:params:xml:ns:yang:ietf-subscribed-notifications\">22</id></rpc-reply>",
           0, state}

        state.mode == :dynamic_rpc_error and String.contains?(rpc, "<modify-subscription") ->
          {"<rpc-reply xmlns=\"urn:ietf:params:xml:ns:netconf:base:1.0\" message-id=\"skopos-1\"><rpc-error><error-tag>operation-failed</error-tag><error-info><vendor-detail xmlns=\"urn:vendor:errors\">needs-reload</vendor-detail></error-info></rpc-error></rpc-reply>",
           0, state}

        dynamic_mode?(state.mode) and
          (String.contains?(rpc, "<modify-subscription") or
             String.contains?(rpc, "<delete-subscription")) and
            not String.contains?(rpc, "<id>22</id>") ->
          {"<rpc-reply xmlns=\"urn:ietf:params:xml:ns:netconf:base:1.0\" message-id=\"skopos-1\"><rpc-error><error-tag>invalid-value</error-tag></rpc-error></rpc-reply>",
           0, state}

        String.contains?(rpc, "<edit-config>") ->
          edit_response(rpc, state)

        String.contains?(rpc, "<native") ->
          {system_reply("skopos-1"), 0, state}

        String.contains?(rpc, "<interfaces") ->
          {interface_reply(state), 0, state}

        true ->
          {"<rpc-reply xmlns=\"urn:ietf:params:xml:ns:netconf:base:1.0\" message-id=\"skopos-1\"><ok/></rpc-reply>",
           0, state}
      end
    end

    defp edit_response(_rpc, %{mode: :rpc_error} = state) do
      reply =
        "<rpc-reply xmlns=\"urn:ietf:params:xml:ns:netconf:base:1.0\" message-id=\"skopos-1\"><rpc-error><error-type>application</error-type><error-tag>operation-failed</error-tag><error-info><vendor-detail xmlns=\"urn:vendor:errors\">needs-reload</vendor-detail></error-info></rpc-error></rpc-reply>"

      {reply, 0, %{state | mode: :normal, edit_received?: true}}
    end

    defp edit_response(_rpc, %{mode: :prefixed_rpc_error} = state) do
      reply =
        "<nc:rpc-reply xmlns:nc=\"urn:ietf:params:xml:ns:netconf:base:1.0\" message-id=\"skopos-1\"><nc:rpc-error><nc:error-tag>operation-failed</nc:error-tag></nc:rpc-error></nc:rpc-reply>"

      {reply, 0, %{state | mode: :normal, edit_received?: true}}
    end

    defp edit_response(rpc, state) do
      interface =
        cond do
          match = Regex.run(~r/<description>(.*?)<\/description>/s, rpc) ->
            Map.put(state.interface, :description, match |> Enum.at(1) |> unescape())

          String.contains?(rpc, "<enabled>false</enabled>") ->
            Map.put(state.interface, :enabled, false)

          String.contains?(rpc, "<enabled>true</enabled>") ->
            Map.put(state.interface, :enabled, true)
        end

      reply =
        "<rpc-reply xmlns=\"urn:ietf:params:xml:ns:netconf:base:1.0\" message-id=\"skopos-1\"><ok/></rpc-reply>"

      {reply, state.delay_edit_ms, %{state | interface: interface, edit_received?: true}}
    end

    defp system_reply(message_id) do
      """
      <rpc-reply xmlns="urn:ietf:params:xml:ns:netconf:base:1.0" message-id="#{message_id}"><data><native xmlns="http://cisco.com/ns/yang/Cisco-IOS-XE-native"><hostname>router-one</hostname><version>17.15.01</version></native></data></rpc-reply>
      """
    end

    defp interface_reply(%{mode: :missing_interface}) do
      "<rpc-reply xmlns=\"urn:ietf:params:xml:ns:netconf:base:1.0\" message-id=\"skopos-1\"><data><interfaces xmlns=\"urn:ietf:params:xml:ns:yang:ietf-interfaces\"></interfaces><interfaces-state xmlns=\"urn:ietf:params:xml:ns:yang:ietf-interfaces\"></interfaces-state></data></rpc-reply>"
    end

    defp interface_reply(%{interface: interface}) do
      admin = if interface.enabled, do: "up", else: "down"

      """
      <rpc-reply xmlns="urn:ietf:params:xml:ns:netconf:base:1.0" message-id="skopos-1"><data><interfaces xmlns="urn:ietf:params:xml:ns:yang:ietf-interfaces"><interface><name>Loopback100</name><description>#{escape(interface.description)}</description><enabled>#{interface.enabled}</enabled></interface></interfaces><interfaces-state xmlns="urn:ietf:params:xml:ns:yang:ietf-interfaces"><interface><name>Loopback100</name><admin-status>#{admin}</admin-status><oper-status>#{admin}</oper-status><statistics><in-errors>2</in-errors><out-errors>3</out-errors></statistics></interface></interfaces-state></data></rpc-reply>
      """
    end

    defp escape(value), do: String.replace(value, "&", "&amp;")
    defp unescape(value), do: String.replace(value, "&amp;", "&")
  end

  setup_all do
    directory =
      Path.join(
        System.tmp_dir!(),
        "skopos-ios-xe-netconf-test-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(directory)
    host_key = :public_key.generate_key({:rsa, 2_048, 65_537})
    private_key = :public_key.pem_entry_encode(:RSAPrivateKey, host_key)
    host_key_path = Path.join(directory, "ssh_host_rsa_key")
    File.write!(host_key_path, :public_key.pem_encode([private_key]))
    File.chmod!(host_key_path, 0o600)
    {:ok, agent} = Agent.start_link(fn -> initial_peer_state() end)

    {:ok, daemon} =
      :ssh.daemon(0,
        system_dir: String.to_charlist(directory),
        user_passwords: [{~c"tester", ~c"secret"}],
        auth_methods: ~c"password",
        ssh_cli: :no_cli,
        subsystems: [{~c"netconf", {Peer, [agent]}}]
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
    Agent.update(context.agent, fn _state -> initial_peer_state() end)
    admin = Accounts.bootstrap!("iosxe-netconf-admin@example.com", @password, @password)

    operator =
      Accounts.create_user!("iosxe-netconf-operator@example.com", @password, :operator,
        actor: admin
      )

    provider =
      Providers.create_provider!(
        "ios-xe-netconf",
        :target,
        "ios-xe-netconf",
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
        "NETCONF",
        "netconf",
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

  @tag netconf_fresh_send: true
  test "NETCONF checks fresh facts before a later RPC while retaining the completed reply",
       context do
    context = generic_netconf_context(context)
    before = length(rpcs(context))

    input =
      request(context, :effect, "request.netconf.effect", "rpc.sequence", %{}, %{
        "rpcs" => [
          "<lock><target><running/></target></lock>",
          "<unlock><target><running/></target></unlock>"
        ]
      })

    clearance = Targets.clear_target_request!(input, actor: context.operator)

    before_send? = fn ->
      if length(rpcs(context)) > before do
        {:error, cause} =
          Skopos.Repo.query("SELECT netconf_followup_context_unavailable", [], mode: :savepoint)

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

    assert Exception.message(error) =~ "netconf_followup_context_unavailable"
    assert Target.Error.context_failure?(error)
    assert is_nil(Target.BeforeSendError.unwrap(error))
    assert %{"completed" => 1, "replies" => [reply]} = Target.Error.context_progress(error)
    assert reply =~ "<ok/>"
    assert length(rpcs(context)) == before + 1
  end

  @tag netconf_context_fault: true
  test "NETCONF sequence retains completed replies and original context failure", context do
    context = generic_netconf_context(context)
    Agent.update(context.agent, &%{&1 | delay_edit_ms: 1_000})

    input =
      request(context, :effect, "request.netconf.effect", "rpc.sequence", %{}, %{
        "rpcs" => [
          "<lock><target><running/></target></lock>",
          "<edit-config><target><running/></target><config><interfaces><interface><name>Loopback100</name><description>changed</description></interface></interfaces></config></edit-config>"
        ]
      })

    clearance = Targets.clear_target_request!(input, actor: context.operator)

    callback = fn ->
      if Agent.get(context.agent, & &1.edit_received?) do
        {:error, cause} =
          Skopos.Repo.query("SELECT netconf_context_unavailable", [], mode: :savepoint)

        raise cause
      end

      false
    end

    assert {:error, error} =
             Targets.dispatch_target_effect(clearance, %{cancelled?: callback},
               actor: context.operator,
               authorize?: false
             )

    assert Exception.message(error) =~ "netconf_context_unavailable"
    assert Target.Error.context_failure?(error)
    assert %{"completed" => 1, "replies" => [reply]} = Target.Error.context_progress(error)
    assert reply =~ "<ok/>"
    assert length(rpcs(context)) == 2
  end

  @tag netconf_context_fault: true
  test "NETCONF subscription retains received notifications and original context failure",
       context do
    context = generic_netconf_context(context)
    Agent.update(context.agent, &%{&1 | mode: :hold_after_first_notification})

    input =
      request(context, :effect, "request.netconf.effect", "rpc.subscribe", %{}, %{
        "body" =>
          "<create-subscription xmlns=\"urn:ietf:params:xml:ns:netconf:notification:1.0\"/>",
        "max_events" => 2,
        "wait_ms" => 200
      })

    clearance = Targets.clear_target_request!(input, actor: context.operator)

    callback = fn ->
      if Agent.get(context.agent, &(&1.notifications_sent > 0)) do
        Process.sleep(20)

        {:error, cause} =
          Skopos.Repo.query("SELECT netconf_subscription_context_unavailable", [],
            mode: :savepoint
          )

        raise cause
      end

      false
    end

    assert {:error, error} =
             Targets.dispatch_target_effect(clearance, %{cancelled?: callback},
               actor: context.operator,
               authorize?: false
             )

    assert Exception.message(error) =~ "netconf_subscription_context_unavailable"
    assert %{"received" => 1, "events" => [event]} = Target.Error.context_progress(error)
    assert event =~ "link-down"
    assert length(rpcs(context)) == 1
  end

  @tag netconf_context_fault: true
  test "IOS XE NETCONF preserves initial context faults through all named ports", context do
    for {kind, capability, operation, selectors, parameters, expected, dispatch} <- [
          {:observation, "observe.system", "ios_xe.system.inspect", %{}, %{}, %{},
           &Targets.dispatch_target_observation/3},
          {:effect, "effect.interface", "ios_xe.interface.description.set",
           %{"interface" => "Loopback100"},
           %{"description" => "changed", "expected_description" => "initial"}, %{},
           &Targets.dispatch_target_effect/3},
          {:verification, "observe.interface", "ios_xe.interface.inspect",
           %{"interface" => "Loopback100"}, %{}, %{"description" => "initial"},
           &Targets.dispatch_target_verification/3}
        ] do
      clearance =
        request(context, kind, capability, operation, selectors, parameters, expected)
        |> Targets.clear_target_request!(actor: context.operator)

      callback = fn ->
        {:error, cause} =
          Skopos.Repo.query("SELECT netconf_initial_context_unavailable", [], mode: :savepoint)

        raise cause
      end

      assert {:error, error} =
               dispatch.(clearance, %{cancelled?: callback},
                 actor: context.operator,
                 authorize?: false
               )

      assert %Target.BeforeSendError{cause: cause} = Target.BeforeSendError.unwrap(error)
      assert Exception.message(cause) =~ "netconf_initial_context_unavailable"
      assert rpcs(context) == []
    end
  end

  test "NETCONF keeps the protocol-sized default and explicit output bounds" do
    assert {:ok, %SSH.Config{max_output_bytes: 60_000}} =
             NETCONF.build(configuration_for("ssh://ios-xe.example:830"), credentials())

    assert {:ok, %SSH.Config{max_output_bytes: 40_000}} =
             NETCONF.build(
               Map.put(configuration_for("ssh://ios-xe.example:830"), "max_output_bytes", 40_000),
               credentials()
             )
  end

  test "only NETCONF-base get RPCs can be classified as observations" do
    request = fn body, capability, operation ->
      %Target.MethodRequest{
        provider_revision: 1,
        connection: %Target.Connection{endpoint: "ssh://router.example:830"},
        capability: capability,
        operation: operation,
        selectors: %{},
        parameters: %{"body" => body}
      }
    end

    assert {:ok, %Target.RequestClassification{kind: :observation}} =
             Target.classify_request(
               NETCONF,
               nil,
               request.("<get/>", "request.netconf.observe", "rpc.observe")
             )

    assert {:ok, :observation} =
             Skopos.Transports.NETCONF.classify_body(
               "<get-config><source><running/></source></get-config>"
             )

    for body <- [
          "<get xmlns=\"urn:vendor:actions\"/>",
          "<vendor:get xmlns:vendor=\"urn:vendor:actions\"/>"
        ] do
      assert {:ok, %Target.RequestClassification{kind: :effect}} =
               Target.classify_request(
                 NETCONF,
                 nil,
                 request.(body, "request.netconf.observe", "rpc.observe")
               )

      assert {:ok, %Target.RequestClassification{kind: :effect}} =
               Target.classify_request(
                 NETCONF,
                 nil,
                 request.(body, "request.netconf.effect", "rpc.execute")
               )
    end
  end

  test "Custom network device uses generic NETCONF through Provider and TargetRequest", context do
    context = generic_netconf_context(context)
    assert {:ok, _operations} = GenericNETCONF.capabilities(nil, %{})

    read =
      request(
        context,
        :observation,
        "request.netconf.observe",
        "rpc.observe",
        %{},
        %{"body" => "<get><filter><native/></filter></get>"}
      )

    assert {:ok, %Target.Observation{facts: %{"reply" => reply}}} =
             read
             |> Targets.clear_target_request!(actor: context.operator)
             |> then(&Targets.dispatch_target_observation(&1, %{}, actor: context.operator))

    assert String.contains?(reply, "router-one")

    effect =
      request(
        context,
        :effect,
        "request.netconf.effect",
        "rpc.execute",
        %{},
        %{"body" => "<vendor:refresh xmlns:vendor=\"urn:vendor:ops\"/>"}
      )

    assert %Target.EffectResult{status: :applied} =
             effect
             |> Targets.clear_target_request!(actor: context.operator)
             |> Targets.dispatch_target_effect!(%{}, actor: context.operator, authorize?: false)

    sequence = %{
      effect
      | operation: "rpc.sequence",
        parameters: %{
          "rpcs" => [
            "<lock><target><running/></target></lock>",
            "<edit-config><target><running/></target><config><interfaces><interface><name>Loopback100</name><description>in session</description></interface></interfaces></config></edit-config>",
            "<commit/>"
          ]
        }
    }

    assert %Target.EffectResult{status: :applied, details: %{"completed" => 3}} =
             sequence
             |> Targets.clear_target_request!(actor: context.operator)
             |> Targets.dispatch_target_effect!(%{}, actor: context.operator, authorize?: false)

    assert context.agent
           |> Agent.get(&Enum.take(&1.sessions, 3))
           |> Enum.uniq()
           |> length() == 1

    subscription =
      %{
        effect
        | operation: "rpc.subscribe",
          parameters: %{
            "body" =>
              "<create-subscription xmlns=\"urn:ietf:params:xml:ns:netconf:notification:1.0\"/>",
            "max_events" => 2,
            "wait_ms" => 200
          }
      }

    assert {:error, _error} =
             Targets.clear_target_request(
               %{subscription | parameters: Map.put(subscription.parameters, "body", "<get/>")},
               actor: context.operator
             )

    assert %Target.EffectResult{
             status: :applied,
             details: %{"events" => [first_event, second_event], "received" => 2}
           } =
             run_subscription!(context, subscription)

    assert String.contains?(first_event, "link-down")
    assert String.contains?(second_event, "link-up")

    Agent.update(context.agent, &%{&1 | mode: :no_notification_events})

    assert %Target.EffectResult{
             status: :applied,
             details: %{"events" => [], "received" => 0, "completion" => "window"}
           } =
             run_subscription!(context, subscription)

    Agent.update(context.agent, &%{&1 | mode: :truncated_notification})

    assert %Target.EffectResult{status: :unknown, details: %{"received" => 0}} =
             run_subscription!(context, subscription)

    Agent.update(context.agent, &%{&1 | mode: :slow_subscription_ack})

    assert %Target.EffectResult{status: :unknown} =
             run_subscription!(context, subscription, %{"wait_ms" => 350})

    before_unsupported = length(rpcs(context))
    Agent.update(context.agent, &%{&1 | mode: :no_notification_capability})

    assert {:error, _error} =
             subscription
             |> Targets.clear_target_request!(actor: context.operator)
             |> then(
               &Targets.dispatch_target_effect(&1, %{},
                 actor: context.operator,
                 authorize?: false
               )
             )

    assert length(rpcs(context)) == before_unsupported

    Agent.update(context.agent, &%{&1 | mode: :malformed_notification})

    assert %Target.EffectResult{status: :unknown, details: %{"received" => 0}} =
             run_subscription!(context, subscription)

    Agent.update(context.agent, &%{&1 | mode: :malformed_notification_time})

    assert %Target.EffectResult{status: :unknown, details: %{"received" => 0}} =
             run_subscription!(context, subscription)

    Agent.update(context.agent, &%{&1 | mode: :drop_after_first_notification})

    assert %Target.EffectResult{status: :unknown, details: %{"received" => 1}} =
             run_subscription!(context, subscription)

    sent_before_cancel = Agent.get(context.agent, & &1.notifications_sent)
    rpc_before_cancel = length(rpcs(context))
    Agent.update(context.agent, &%{&1 | mode: :hold_after_first_notification})

    assert %Target.EffectResult{status: :unknown} =
             run_subscription!(
               context,
               subscription,
               %{},
               %{
                 cancelled?: fn ->
                   Agent.get(context.agent, &(&1.notifications_sent > sent_before_cancel))
                 end
               }
             )

    assert length(rpcs(context)) == rpc_before_cancel + 1

    Agent.update(context.agent, &%{&1 | mode: :normal})

    Agent.update(context.agent, &%{&1 | mode: :rpc_error})

    assert %Target.EffectResult{
             status: :partial,
             details: %{"completed" => 1, "error" => sequence_error}
           } =
             %{
               sequence
               | operation_id: Ecto.UUID.generate(),
                 idempotency_key: Ecto.UUID.generate()
             }
             |> Targets.clear_target_request!(actor: context.operator)
             |> Targets.dispatch_target_effect!(%{}, actor: context.operator, authorize?: false)

    assert String.contains?(sequence_error, "<vendor-detail")
    assert String.contains?(sequence_error, "needs-reload")

    Agent.update(context.agent, &%{&1 | mode: :wrong_second_message_id})

    assert %Target.EffectResult{status: :unknown, details: %{"completed" => 1}} =
             %{
               sequence
               | operation_id: Ecto.UUID.generate(),
                 idempotency_key: Ecto.UUID.generate()
             }
             |> Targets.clear_target_request!(actor: context.operator)
             |> Targets.dispatch_target_effect!(%{}, actor: context.operator, authorize?: false)

    before_reject = length(rpcs(context))

    assert {:error, _error} =
             %{sequence | parameters: %{"rpcs" => ["<lock/>", "<get>"]}}
             |> Targets.clear_target_request(actor: context.operator)

    for body <- [
          "<get xmlns=\"urn:vendor:ops\"/>",
          "<get/><edit-config/>",
          "<get>",
          "<edit-config/>"
        ] do
      rejected = %{read | parameters: %{"body" => body}}
      assert {:error, _error} = Targets.clear_target_request(rejected, actor: context.operator)
    end

    assert length(rpcs(context)) == before_reject

    Agent.update(context.agent, &%{&1 | mode: :wrong_message_id})

    assert {:error, _error} =
             read
             |> Targets.clear_target_request!(actor: context.operator)
             |> then(&Targets.dispatch_target_observation(&1, %{}, actor: context.operator))

    edit = %{
      effect
      | parameters: %{
          "body" =>
            "<edit-config><target><running/></target><config><interfaces><interface><name>Loopback100</name><description>generic edit</description></interface></interfaces></config></edit-config>"
        }
    }

    Agent.update(context.agent, &%{&1 | mode: :rpc_error})

    assert %Target.EffectResult{status: :failed, details: %{"error" => single_error}} =
             edit
             |> Targets.clear_target_request!(actor: context.operator)
             |> Targets.dispatch_target_effect!(%{}, actor: context.operator, authorize?: false)

    assert String.contains?(single_error, "<vendor-detail")
    assert String.contains?(single_error, "needs-reload")

    Agent.update(context.agent, &%{&1 | mode: :prefixed_rpc_error})

    assert %Target.EffectResult{status: :failed, details: %{"error" => prefixed_error}} =
             edit
             |> Targets.clear_target_request!(actor: context.operator)
             |> Targets.dispatch_target_effect!(%{}, actor: context.operator, authorize?: false)

    assert String.contains?(prefixed_error, "<nc:error-tag>operation-failed</nc:error-tag>")

    Agent.update(context.agent, &%{&1 | mode: :wrong_message_id})

    assert %Target.EffectResult{status: :unknown} =
             edit
             |> Targets.clear_target_request!(actor: context.operator)
             |> Targets.dispatch_target_effect!(%{}, actor: context.operator, authorize?: false)

    Agent.update(context.agent, &%{&1 | delay_edit_ms: 1_000})

    assert %Target.EffectResult{status: :unknown, details: %{"completed" => 1}} =
             %{
               sequence
               | operation_id: Ecto.UUID.generate(),
                 idempotency_key: Ecto.UUID.generate()
             }
             |> Targets.clear_target_request!(actor: context.operator)
             |> Targets.dispatch_target_effect!(%{}, actor: context.operator, authorize?: false)

    Agent.update(context.agent, &%{&1 | edit_received?: false})

    assert %Target.EffectResult{status: :unknown, details: %{"completed" => 1}} =
             %{
               sequence
               | operation_id: Ecto.UUID.generate(),
                 idempotency_key: Ecto.UUID.generate()
             }
             |> Targets.clear_target_request!(actor: context.operator)
             |> Targets.dispatch_target_effect!(
               %{cancelled?: fn -> Agent.get(context.agent, & &1.edit_received?) end},
               actor: context.operator,
               authorize?: false
             )

    Agent.update(context.agent, &%{&1 | delay_edit_ms: 1_000})

    assert %Target.EffectResult{status: :unknown} =
             edit
             |> Targets.clear_target_request!(actor: context.operator)
             |> Targets.dispatch_target_effect!(%{}, actor: context.operator, authorize?: false)
  end

  test "dynamic NETCONF subscription interleaves notifications with same-session RPC replies",
       context do
    # The 300 ms notification window must fit after SSH and subscription setup.
    # These tests exercise follow-up replies, not the setup timeout boundary.
    context = context |> Map.put(:netconf_timeout, 2_000) |> generic_netconf_context()
    Agent.update(context.agent, &%{&1 | mode: :dynamic_subscription})

    subscription =
      dynamic_subscription_request(context, [
        "<modify-subscription xmlns=\"urn:ietf:params:xml:ns:yang:ietf-subscribed-notifications\"><id>${subscription_id}</id><stream>NETCONF</stream></modify-subscription>",
        "<delete-subscription xmlns=\"urn:ietf:params:xml:ns:yang:ietf-subscribed-notifications\"><id>${subscription_id}</id></delete-subscription>"
      ])

    assert %Target.EffectResult{
             status: :applied,
             details: %{
               "subscription_id" => "22",
               "events" => [first, second, third],
               "received" => 3,
               "completed" => 2,
               "replies" => [_, _]
             }
           } = run_subscription!(context, subscription)

    assert String.contains?(first, "established")
    assert String.contains?(second, "before-reply")
    assert String.contains?(third, "before-reply")

    assert context.agent
           |> Agent.get(&Enum.take(&1.sessions, 3))
           |> Enum.uniq()
           |> length() == 1
  end

  test "dynamic NETCONF subscription does not accept a mismatched follow-up reply", context do
    context = context |> Map.put(:netconf_timeout, 2_000) |> generic_netconf_context()
    Agent.update(context.agent, &%{&1 | mode: :dynamic_wrong_followup_id})

    subscription =
      dynamic_subscription_request(context, [
        "<modify-subscription xmlns=\"urn:ietf:params:xml:ns:yang:ietf-subscribed-notifications\"><id>${subscription_id}</id></modify-subscription>"
      ])

    assert %Target.EffectResult{
             status: :unknown,
             details: %{"subscription_id" => "22", "received" => 2, "completed" => 0}
           } = run_subscription!(context, subscription)
  end

  test "dynamic NETCONF subscription retains events on interrupted follow-up", context do
    context = context |> Map.put(:netconf_timeout, 2_000) |> generic_netconf_context()
    Agent.update(context.agent, &%{&1 | mode: :dynamic_close_before_followup_reply})

    subscription =
      dynamic_subscription_request(context, [
        "<modify-subscription xmlns=\"urn:ietf:params:xml:ns:yang:ietf-subscribed-notifications\"><id>${subscription_id}</id></modify-subscription>"
      ])

    assert %Target.EffectResult{
             status: :unknown,
             details: %{"subscription_id" => "22", "received" => 2, "completed" => 0}
           } = run_subscription!(context, subscription)
  end

  test "dynamic NETCONF subscription preserves follow-up rpc-error details", context do
    context = context |> Map.put(:netconf_timeout, 2_000) |> generic_netconf_context()
    Agent.update(context.agent, &%{&1 | mode: :dynamic_rpc_error})

    subscription =
      dynamic_subscription_request(context, [
        "<modify-subscription xmlns=\"urn:ietf:params:xml:ns:yang:ietf-subscribed-notifications\"><id>${subscription_id}</id></modify-subscription>"
      ])

    assert %Target.EffectResult{
             status: :unknown,
             details: %{
               "subscription_id" => "22",
               "received" => 2,
               "completed" => 0,
               "error" => error_reply
             }
           } = run_subscription!(context, subscription)

    assert String.contains?(error_reply, "<vendor-detail")
    assert String.contains?(error_reply, "needs-reload")
  end

  test "stopping a NETCONF subscription caller closes its session without replay", context do
    context = context |> Map.put(:netconf_timeout, 2_000) |> generic_netconf_context()
    observer = self()
    Agent.update(context.agent, &%{&1 | mode: :no_notification_events, observer: observer})

    subscription =
      request(
        context,
        :effect,
        "request.netconf.effect",
        "rpc.subscribe",
        %{},
        %{
          "body" =>
            "<create-subscription xmlns=\"urn:ietf:params:xml:ns:netconf:notification:1.0\"/>",
          "max_events" => 1,
          "wait_ms" => 1_000
        }
      )

    {caller, monitor} =
      spawn_monitor(fn ->
        subscription
        |> Targets.clear_target_request!(actor: context.operator)
        |> Targets.dispatch_target_effect!(%{}, actor: context.operator, authorize?: false)
      end)

    assert_receive {:netconf_rpc, session_id}, 1_500
    refute_receive {:netconf_closed, ^session_id}, 0
    Process.exit(caller, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^caller, :killed}, 1_000
    assert_receive {:netconf_closed, ^session_id}, 1_000
    refute_receive {:netconf_rpc, _session}, 100
    assert length(rpcs(context)) == 1
  end

  test "public NETCONF route constructs RPCs, observes, applies and freshly verifies", context do
    assert %Target.Capabilities{} =
             Providers.target_capabilities!(
               context.provider.id,
               %Target.CapabilitiesRequest{
                 provider_revision: context.provider.revision,
                 connection: %Target.Connection{endpoint: context.endpoint}
               },
               %{},
               actor: context.admin
             )

    system = observe!(context, "observe.system", "ios_xe.system.inspect", %{})
    assert system.facts == %{"hostname" => "router-one", "version" => "17.15.01"}

    interface =
      observe!(context, "observe.interface", "ios_xe.interface.inspect", %{
        "interface" => "Loopback100"
      })

    assert interface.facts["description"] == "initial"
    assert interface.facts["input_errors"] == 2

    assert %Target.EffectResult{status: :applied} =
             effect!(context, "ios_xe.interface.description.set", %{
               "description" => "ops & core",
               "expected_description" => "initial"
             })

    assert %Target.Verification{status: :verified, facts: %{"description" => "ops & core"}} =
             verify!(context, %{"description" => "ops & core"})

    assert %Target.EffectResult{status: :applied} =
             effect!(context, "ios_xe.interface.admin_state.set", %{
               "enabled" => false,
               "expected_enabled" => true
             })

    assert %Target.Verification{status: :verified, facts: %{"enabled" => false}} =
             verify!(context, %{"enabled" => false})

    rpcs = rpcs(context)
    assert Enum.any?(rpcs, &String.contains?(&1, "<native xmlns="))
    assert Enum.any?(rpcs, &String.contains?(&1, "<description>ops &amp; core</description>"))
    assert Enum.any?(rpcs, &String.contains?(&1, "<enabled>false</enabled>"))

    assert Enum.any?(
             rpcs,
             &String.contains?(&1, "<error-option>rollback-on-error</error-option>")
           )

    assert Enum.all?(rpcs, &String.contains?(&1, "message-id=\"skopos-1\""))
  end

  test "NETCONF route rejects stale state, rpc-errors and malformed replies", context do
    assert %Target.EffectResult{status: :failed, details: %{"category" => "stale"}} =
             effect!(context, "ios_xe.interface.description.set", %{
               "description" => "changed",
               "expected_description" => "outdated"
             })

    refute Enum.any?(rpcs(context), &String.contains?(&1, "<edit-config>"))
    Agent.update(context.agent, &%{&1 | mode: :rpc_error})

    assert %Target.EffectResult{status: :failed, details: %{"category" => "rejected"}} =
             effect!(context, "ios_xe.interface.admin_state.set", %{
               "enabled" => false,
               "expected_enabled" => true
             })

    for mode <- [:wrong_message_id, :malformed, :missing_interface] do
      Agent.update(context.agent, &%{&1 | mode: mode})

      {capability, operation, selectors} =
        if mode == :missing_interface do
          {"observe.interface", "ios_xe.interface.inspect", %{"interface" => "Loopback100"}}
        else
          {"observe.system", "ios_xe.system.inspect", %{}}
        end

      clearance =
        request(context, :observation, capability, operation, selectors, %{})
        |> Targets.clear_target_request!(actor: context.operator)

      assert {:error, _error} =
               Targets.dispatch_target_observation(clearance, %{}, actor: context.operator)
    end
  end

  test "NETCONF route preserves post-dispatch cancellation and connection failures", context do
    Agent.update(context.agent, &%{&1 | delay_edit_ms: 1_000})

    clearance =
      request(
        context,
        :effect,
        "effect.interface",
        "ios_xe.interface.description.set",
        %{"interface" => "Loopback100"},
        %{"description" => "changed", "expected_description" => "initial"}
      )
      |> Targets.clear_target_request!(actor: context.operator)

    assert %Target.EffectResult{status: :unknown} =
             Targets.dispatch_target_effect!(
               clearance,
               %{cancelled?: fn -> Agent.get(context.agent, & &1.edit_received?) end},
               actor: context.operator,
               authorize?: false
             )

    unreachable =
      Providers.create_provider!(
        "unreachable-ios-xe-netconf",
        :target,
        "ios-xe-netconf",
        configuration_for("ssh://127.0.0.1:1"),
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

  defp initial_peer_state do
    %{
      rpcs: [],
      sessions: [],
      notifications_sent: 0,
      observer: nil,
      mode: :normal,
      delay_edit_ms: 0,
      edit_received?: false,
      interface: %{description: "initial", enabled: true}
    }
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

  defp run_subscription!(context, subscription, parameters \\ %{}, invocation \\ %{}) do
    %{
      subscription
      | parameters: Map.merge(subscription.parameters, parameters),
        operation_id: Ecto.UUID.generate(),
        idempotency_key: Ecto.UUID.generate()
    }
    |> Targets.clear_target_request!(actor: context.operator)
    |> Targets.dispatch_target_effect!(invocation, actor: context.operator, authorize?: false)
  end

  defp dynamic_subscription_request(context, rpcs) do
    request(
      context,
      :effect,
      "request.netconf.effect",
      "rpc.subscribe",
      %{},
      %{
        "body" =>
          "<establish-subscription xmlns=\"urn:ietf:params:xml:ns:yang:ietf-subscribed-notifications\"><stream>NETCONF</stream></establish-subscription>",
        "rpcs" => rpcs,
        "max_events" => 3,
        "wait_ms" => 300
      }
    )
  end

  defp generic_netconf_context(context) do
    provider =
      Providers.create_provider!(
        "generic-netconf",
        :target,
        "netconf",
        Map.put(
          configuration(context),
          "operation_timeout_ms",
          Map.get(context, :netconf_timeout, 500)
        ),
        credentials(),
        actor: context.admin
      )
      |> then(&Providers.enable_provider!(&1, &1.revision, actor: context.admin))

    target =
      Targets.create_target!(
        "generic switch",
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
        "NETCONF",
        "netconf",
        context.endpoint,
        provider.revision,
        100,
        ["request.netconf.observe", "request.netconf.effect"],
        actor: context.admin
      )
      |> then(&Targets.check_access_method!(&1.id, &1.revision, %{}, actor: context.admin))

    Map.merge(context, %{provider: provider, target: target, method: method})
  end

  defp configuration(context), do: configuration_for(context.endpoint, context.fingerprint)

  defp configuration_for(
         endpoint,
         fingerprint \\ "SHA256:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
       ) do
    %{
      "host_key_fingerprints" => %{endpoint => fingerprint},
      "connect_timeout_ms" => 2_000,
      "operation_timeout_ms" => 500
    }
  end

  defp credentials do
    %{"username" => "tester", "auth_method" => "password", "password" => "secret"}
  end

  defp rpcs(context), do: Agent.get(context.agent, &Enum.reverse(&1.rpcs))
end
