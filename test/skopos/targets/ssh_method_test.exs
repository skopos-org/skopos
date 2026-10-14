defmodule Skopos.Targets.SSHMethodTest do
  use Skopos.DataCase, async: false

  alias Skopos.{Accounts, Providers, Targets}
  alias Skopos.Providers.Target
  alias Skopos.Targets.Adapters.SSH
  alias Skopos.Targets.TargetRequest.{RequestError, Request}
  alias Skopos.Transports.SSH, as: Transport

  @password "correct horse battery staple"

  defmodule SubsystemPeer do
    @behaviour :ssh_server_channel
    @impl true
    def init([agent]), do: {:ok, %{agent: agent, session: make_ref()}}
    @impl true
    def handle_msg({:ssh_channel_up, channel, connection}, state),
      do: {:ok, Map.merge(state, %{channel: channel, connection: connection})}

    def handle_msg(_, state), do: {:ok, state}
    @impl true
    def handle_ssh_msg({:ssh_cm, connection, {:data, channel, _, bytes}}, state) do
      Agent.update(state.agent, &[{state.session, bytes} | &1])
      :ssh_connection.adjust_window(connection, channel, byte_size(bytes))

      case bytes do
        <<0, 255>> ->
          :ssh_connection.send(connection, channel, "first|leftover")

        "second" ->
          :ssh_connection.send(connection, channel, <<255, 0>>)

        "streams" ->
          :ssh_connection.send(connection, channel, 1, "warning")
          :ssh_connection.send(connection, channel, 0, "reply")

        "silent" ->
          :ok

        "disconnect" ->
          :ssh_connection.close(connection, channel)

        "oversize" ->
          :ssh_connection.send(connection, channel, String.duplicate("x", 100))

        "split-delimiter" ->
          :ssh_connection.send(connection, channel, "prefix|")
          Process.sleep(20)
          :ssh_connection.send(connection, channel, "~tail")

        "native-failure" ->
          :ssh_connection.exit_status(connection, channel, 7)
          :ssh_connection.send(connection, channel, "failed")

        _ ->
          :ssh_connection.send(connection, channel, bytes)
      end

      {:ok, state}
    end

    def handle_ssh_msg({:ssh_cm, connection, {:eof, channel}}, state) do
      :ssh_connection.send(connection, channel, "done")
      :ssh_connection.send_eof(connection, channel)
      {:ok, state}
    end

    def handle_ssh_msg(_, state), do: {:ok, state}
    @impl true
    def terminate(_, _), do: :ok
  end

  setup_all do
    directory =
      Path.join(
        System.tmp_dir!(),
        "skopos-ssh-test-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(directory)

    host_key = :public_key.generate_key({:rsa, 2_048, 65_537})
    write_private_key!(Path.join(directory, "ssh_host_rsa_key"), host_key)

    client_key = :public_key.generate_key({:rsa, 2_048, 65_537})
    client_pem = encode_private_key(client_key)
    client_public = :ssh_file.extract_public_key(client_key)

    File.write!(
      Path.join(directory, "authorized_keys"),
      :ssh_file.encode([{client_public, []}], :auth_keys)
    )

    {:ok, commands} = Agent.start_link(fn -> [] end)
    {:ok, subsystem_calls} = Agent.start_link(fn -> [] end)

    {:ok, daemon} =
      :ssh.daemon(0,
        system_dir: String.to_charlist(directory),
        user_dir: String.to_charlist(directory),
        user_passwords: [{~c"tester", ~c"secret"}],
        auth_methods: ~c"publickey,password",
        subsystems: [
          {~c"test-subsystem", {SubsystemPeer, [subsystem_calls]}},
          :ssh_sftpd.subsystem_spec(root: String.to_charlist(directory))
        ],
        exec: {:direct, command_executor(commands)}
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

    %{
      endpoint: endpoint,
      fingerprint: fingerprint,
      client_pem: client_pem,
      commands: commands,
      subsystem_calls: subsystem_calls
    }
  end

  setup context do
    Agent.update(context.commands, fn _commands -> [] end)
    Agent.update(context.subsystem_calls, fn _calls -> [] end)
    :ok
  end

  test "transport supports pinned password and in-memory public-key authentication", context do
    assert {:ok, password} = Transport.build(configuration(context), password_credentials())
    assert :ok = Transport.check(password, context.endpoint)

    assert {:ok, %Transport.Result{} = result} =
             Transport.exec(password, context.endpoint, "success")

    assert result.stdout == "ran:success"
    assert result.stderr == ""
    assert result.exit_status == 0

    assert {:ok, public_key} =
             Transport.build(configuration(context), public_key_credentials(context.client_pem))

    assert {:ok, %Transport.Result{stdout: "ran:key", exit_status: 0}} =
             Transport.exec(public_key, context.endpoint, "key")

    assert {:ok, %Transport.Result{stderr: stderr, exit_status: status}} =
             Transport.exec(password, context.endpoint, "stderr")

    assert stderr =~ "failed"
    assert status != 0
  end

  test "transport keeps host, auth, limit, timeout and cancellation failures typed", context do
    wrong_host =
      configuration(context, %{
        "host_key_fingerprints" => %{
          context.endpoint => "SHA256:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
        }
      })

    assert {:ok, wrong_host} = Transport.build(wrong_host, password_credentials())
    assert {:error, :host_key, _message} = Transport.check(wrong_host, context.endpoint)

    assert {:ok, wrong_password} =
             Transport.build(configuration(context), password_credentials("wrong"))

    assert {:error, :authentication, _message} =
             Transport.check(wrong_password, context.endpoint)

    assert {:ok, limited} =
             Transport.build(
               configuration(context, %{"max_output_bytes" => 8}),
               password_credentials()
             )

    assert {:error, :output_limit_after_dispatch, _message} =
             Transport.exec(limited, context.endpoint, "large")

    assert {:ok, timed} =
             Transport.build(
               configuration(context, %{"operation_timeout_ms" => 500}),
               password_credentials()
             )

    assert {:error, :timeout_after_dispatch, _message} =
             Transport.exec(timed, context.endpoint, "slow")

    assert {:error, %Target.BeforeSendError{cause: %Target.Error{category: :cancelled}} = unsent} =
             Transport.exec(password_config(context), context.endpoint, "success", %{
               cancelled?: fn -> true end
             })

    refute Target.BeforeSendError.retryable?(unsent)

    cancel_at = System.monotonic_time(:millisecond) + 500

    assert {:error, :cancelled_after_dispatch, _message} =
             Transport.exec(password_config(context), context.endpoint, "slow", %{
               cancelled?: fn ->
                 System.monotonic_time(:millisecond) >= cancel_at
               end
             })
  end

  test "legacy algorithms require an explicit bounded allowlist", context do
    legacy_configuration =
      configuration(context, %{
        "legacy_algorithms" => [
          "ssh-rsa",
          "diffie-hellman-group-exchange-sha1",
          "diffie-hellman-group14-sha1"
        ]
      })

    assert {:ok, legacy} = Transport.build(legacy_configuration, password_credentials())
    assert :ok = Transport.check(legacy, context.endpoint)

    assert {:error, :invalid_configuration} =
             Transport.build(
               configuration(context, %{"legacy_algorithms" => ["diffie-hellman-group1-sha1"]}),
               password_credentials()
             )
  end

  test "unexpected subsystem worker failure before dispatch remains a failure", context do
    assert {:error, :failed, "SSH transport failed"} =
             Transport.subsystem(
               password_config(context),
               context.endpoint,
               "sftp",
               fn _channel ->
                 raise "channel consumer failed before dispatch"
               end
             )

    assert commands(context) == []
  end

  test "an SSH effect with a lost response has an unknown outcome", context do
    assert {:ok, state} =
             Transport.build(
               configuration(context, %{"operation_timeout_ms" => 500}),
               password_credentials()
             )

    request = %{
      capability: "request.ssh.effect",
      operation: "command.execute",
      selectors: %{},
      parameters: %{"command" => "slow"},
      connection: %Target.Connection{endpoint: context.endpoint}
    }

    assert {:ok, %Target.EffectResult{status: :unknown}} = SSH.effect(state, request, %{})
    assert commands(context) == ["slow"]
  end

  test "public custom target exchanges exact binary subsystem steps on one connection", context do
    {admin, exact} =
      subsystem_request(context, [
        %{"op" => "send", "data" => "AP8="},
        %{"op" => "receive", "until" => %{"delimiter" => "fA=="}},
        %{"op" => "receive", "until" => %{"bytes" => 8}},
        %{"op" => "send", "data" => "c2Vjb25k"},
        %{"op" => "receive", "until" => %{"bytes" => 2}},
        %{"op" => "send_eof"},
        %{"op" => "receive", "until" => %{"eof" => true}},
        %{"op" => "close"}
      ])

    clearance = Targets.clear_target_request!(exact, actor: admin)

    assert %Target.EffectResult{status: :applied, details: details} =
             Targets.dispatch_target_effect!(clearance, %{}, actor: admin, authorize?: false)

    assert details["completion_reason"] == "sequence_complete"

    assert Enum.map(Enum.filter(details["steps"], &(&1["op"] == "receive")), & &1["data"]) ==
             ["Zmlyc3R8", "bGVmdG92ZXI=", "/wA=", "ZG9uZQ=="]

    assert details["bytes_sent"] == 8
    assert details["bytes_received"] == 20
    calls = Agent.get(context.subsystem_calls, &Enum.reverse/1)
    assert [{session, <<0, 255>>}, {session, "second"}] = calls
  end

  for {name, settings} <- [
        {"generic", %{}},
        {"Linux", %{provider_type: "linux-ssh", target_kind: "host", target_type: "linux"}}
      ] do
    @tag ssh_fresh_send: true, ssh_fresh_settings: settings
    test "registered #{name} SSH retains a native pre-send fault independently of waiting",
         context do
      owner = self()

      {admin, input} =
        subsystem_request(Map.merge(context, context.ssh_fresh_settings), [%{"op" => "close"}])

      input = %{input | operation: "command.execute", parameters: %{"command" => "never-sent"}}
      clearance = Targets.clear_target_request!(input, actor: admin)

      before_send? = fn ->
        if self() != owner do
          {:error, cause} =
            Skopos.Repo.query("SELECT ssh_native_send_unavailable", [], mode: :savepoint)

          raise cause
        end

        false
      end

      assert {:error, error} =
               Targets.dispatch_target_effect(
                 clearance,
                 %{before_send?: before_send?, cancelled?: fn -> false end},
                 actor: admin,
                 authorize?: false
               )

      assert %Target.BeforeSendError{cause: cause} = Target.BeforeSendError.unwrap(error)
      assert Exception.message(cause) =~ "ssh_native_send_unavailable"
      assert commands(context) == []
    end
  end

  @tag ssh_context_fault: true
  test "Linux SSH profile retains original context failure on an arbitrary command", context do
    {admin, input} =
      subsystem_request(
        Map.merge(context, %{
          provider_type: "linux-ssh",
          target_kind: "host",
          target_type: "linux"
        }),
        [%{"op" => "close"}]
      )

    input = %{input | operation: "command.execute", parameters: %{"command" => "slow"}}
    clearance = Targets.clear_target_request!(input, actor: admin)

    callback = fn ->
      if "slow" in commands(context) do
        {:error, cause} =
          Skopos.Repo.query("SELECT linux_context_unavailable", [], mode: :savepoint)

        raise cause
      end

      false
    end

    assert {:error, error} =
             Targets.dispatch_target_effect(clearance, %{cancelled?: callback},
               actor: admin,
               authorize?: false
             )

    assert Exception.message(error) =~ "linux_context_unavailable"
    assert Target.Error.context_failure?(error)
    assert commands(context) == ["slow"]
  end

  @tag ssh_context_fault: true
  test "registered SSH Method keeps a completed reply when a concurrent stop check fails",
       context do
    {admin, input} = subsystem_request(context, [%{"op" => "close"}])
    input = %{input | operation: "command.execute", parameters: %{"command" => "ready-reply"}}
    clearance = Targets.clear_target_request!(input, actor: admin)
    owner = self()

    callback = fn ->
      if "ready-reply" in commands(context) do
        send(owner, :ssh_reply_stop_check)
        Process.sleep(500)

        {:error, cause} =
          Skopos.Repo.query("SELECT ssh_reply_context_unavailable", [], mode: :savepoint)

        raise cause
      end

      false
    end

    assert {:ok, %Target.EffectResult{status: :applied, details: details}} =
             Targets.dispatch_target_effect(clearance, %{cancelled?: callback},
               actor: admin,
               authorize?: false
             )

    assert details["stdout"] == %{"encoding" => "utf-8", "value" => "completed"}
    assert details["exit_status"] == 0
    assert commands(context) == ["ready-reply"]
    assert_receive :ssh_reply_stop_check
  end

  @tag ssh_context_fault: true
  test "registered SSH Method retains a failed initial stop check without sending a command",
       context do
    {admin, input} = subsystem_request(context, [%{"op" => "close"}])
    input = %{input | operation: "command.execute", parameters: %{"command" => "never-sent"}}
    clearance = Targets.clear_target_request!(input, actor: admin)

    callback = fn ->
      {:error, cause} =
        Skopos.Repo.query("SELECT ssh_initial_context_unavailable", [], mode: :savepoint)

      raise cause
    end

    assert {:error, error} =
             Targets.dispatch_target_effect(clearance, %{cancelled?: callback},
               actor: admin,
               authorize?: false
             )

    assert %Target.BeforeSendError{cause: cause} = Target.BeforeSendError.unwrap(error)
    assert Exception.message(cause) =~ "ssh_initial_context_unavailable"
    assert commands(context) == []
    assert Agent.get(context.subsystem_calls, & &1) == []
  end

  for {name, step} <- [
        {"send", %{"op" => "send", "data" => Base.encode64("second")}},
        {"send_eof", %{"op" => "send_eof"}},
        {"close", %{"op" => "close"}}
      ] do
    @tag ssh_fresh_send: true, ssh_fresh_step: step
    test "a later subsystem #{name} checks fresh facts and retains completed native steps",
         context do
      steps = [
        %{"op" => "send", "data" => Base.encode64(<<0, 255>>)},
        %{"op" => "receive", "until" => %{"bytes" => 5}},
        context.ssh_fresh_step
      ]

      steps =
        if context.ssh_fresh_step["op"] == "close", do: steps, else: steps ++ [%{"op" => "close"}]

      {admin, input} = subsystem_request(context, steps)
      clearance = Targets.clear_target_request!(input, actor: admin)

      before_send? = fn ->
        if Agent.get(context.subsystem_calls, &(&1 != [])) do
          {:error, cause} =
            Skopos.Repo.query("SELECT ssh_followup_context_unavailable", [], mode: :savepoint)

          raise cause
        end

        false
      end

      assert {:error, error} =
               Targets.dispatch_target_effect(
                 clearance,
                 %{before_send?: before_send?, cancelled?: fn -> false end},
                 actor: admin,
                 authorize?: false
               )

      assert Exception.message(error) =~ "ssh_followup_context_unavailable"
      assert Target.Error.context_failure?(error)
      assert is_nil(Target.BeforeSendError.unwrap(error))

      assert %{
               "bytes_sent" => 2,
               "bytes_received" => 14,
               "steps" => [sent, received],
               "buffered" => %{"0" => buffered}
             } =
               Target.Error.context_progress(error)

      assert sent["op"] == "send"
      assert Base.decode64!(received["data"]) == "first"
      assert Base.decode64!(buffered) == "|leftover"

      assert Agent.get(context.subsystem_calls, &Enum.map(&1, fn {_, bytes} -> bytes end)) == [
               <<0, 255>>
             ]
    end
  end

  @tag ssh_context_fault: true
  test "registered SSH Method retains context failure and completed subsystem steps", context do
    steps = [
      %{"op" => "send", "data" => Base.encode64(<<0, 255>>)},
      %{"op" => "receive", "until" => %{"bytes" => 5}},
      %{"op" => "send", "data" => Base.encode64("silent")},
      %{"op" => "receive", "until" => %{"bytes" => 10}},
      %{"op" => "close"}
    ]

    {admin, input} = subsystem_request(context, steps)
    clearance = Targets.clear_target_request!(input, actor: admin)

    callback = fn ->
      if Agent.get(
           context.subsystem_calls,
           &Enum.any?(&1, fn {_, bytes} -> bytes == "silent" end)
         ) do
        {:error, cause} =
          Skopos.Repo.query("SELECT ssh_context_unavailable", [], mode: :savepoint)

        raise cause
      end

      false
    end

    assert {:error, error} =
             Targets.dispatch_target_effect(clearance, %{cancelled?: callback},
               actor: admin,
               authorize?: false
             )

    assert Exception.message(error) =~ "ssh_context_unavailable"
    assert Target.Error.context_failure?(error)
    assert is_nil(Target.BeforeSendError.unwrap(error))
    assert %{"bytes_sent" => 8, "steps" => completed} = Target.Error.context_progress(error)

    assert [%{"op" => "send"}, %{"op" => "receive", "data" => data}, %{"op" => "send"}] =
             completed

    assert Base.decode64!(data) == "first"

    assert Agent.get(context.subsystem_calls, &Enum.reverse/1) |> Enum.map(&elem(&1, 1)) == [
             <<0, 255>>,
             "silent"
           ]
  end

  test "subsystem keeps stderr and ordinary data as separate selected byte streams", context do
    {admin, exact} =
      subsystem_request(context, [
        %{"op" => "send", "data" => "c3RyZWFtcw=="},
        %{"op" => "receive", "until" => %{"bytes" => 5}, "stream" => 0},
        %{"op" => "receive", "until" => %{"bytes" => 7}, "stream" => 1},
        %{"op" => "close"}
      ])

    clearance = Targets.clear_target_request!(exact, actor: admin)

    assert %Target.EffectResult{status: :applied, details: details} =
             Targets.dispatch_target_effect!(clearance, %{}, actor: admin, authorize?: false)

    assert Enum.map(
             Enum.filter(details["steps"], &(&1["op"] == "receive")),
             &{&1["stream"], &1["data"]}
           ) ==
             [{0, "cmVwbHk="}, {1, "d2FybmluZw=="}]
  end

  for {name, payload} <- [
        {"timeout", "silent"},
        {"disconnect", "disconnect"},
        {"output limit", "oversize"},
        {"cancellation", "silent"}
      ] do
    test "subsystem #{name} after dispatch preserves completed steps and unknown outcome",
         context do
      payload = unquote(payload)

      {admin, exact} =
        subsystem_request(
          context,
          [
            %{"op" => "send", "data" => "cGluZw=="},
            %{"op" => "receive", "until" => %{"bytes" => 4}},
            %{"op" => "send", "data" => Base.encode64(payload)},
            %{"op" => "receive", "until" => %{"bytes" => 1}},
            %{"op" => "close"}
          ],
          %{"operation_timeout_ms" => 500, "max_output_bytes" => 8}
        )

      invocation =
        if unquote(name) == "cancellation",
          do: %{
            cancelled?: fn ->
              Agent.get(
                context.subsystem_calls,
                &Enum.any?(&1, fn {_, bytes} -> bytes == payload end)
              )
            end
          },
          else: %{}

      clearance = Targets.clear_target_request!(exact, actor: admin)

      assert %Target.EffectResult{status: :unknown, details: details} =
               Targets.dispatch_target_effect!(clearance, invocation,
                 actor: admin,
                 authorize?: false
               )

      assert details["completion_reason"] == "sequence_interrupted"
      assert Enum.map(details["steps"], & &1["op"]) == ["send", "receive", "send"]
      assert details["steps"] |> Enum.at(1) |> Map.fetch!("data") == "cGluZw=="
      assert details["current_step"] == %{"index" => 3, "op" => "receive"}

      assert Agent.get(
               context.subsystem_calls,
               &Enum.count(&1, fn {_, bytes} -> bytes == payload end)
             ) == 1
    end
  end

  test "subsystem cumulative output bound applies across separate successful receives", context do
    {admin, exact} =
      subsystem_request(
        context,
        [
          %{"op" => "send", "data" => "cGluZw=="},
          %{"op" => "receive", "until" => %{"bytes" => 4}},
          %{"op" => "send", "data" => "cG9uZw=="},
          %{"op" => "receive", "until" => %{"bytes" => 4}},
          %{"op" => "send", "data" => "IQ=="},
          %{"op" => "receive", "until" => %{"bytes" => 1}},
          %{"op" => "close"}
        ],
        %{"max_output_bytes" => 8}
      )

    clearance = Targets.clear_target_request!(exact, actor: admin)

    assert %Target.EffectResult{status: :unknown, details: details} =
             Targets.dispatch_target_effect!(clearance, %{}, actor: admin, authorize?: false)

    assert details["bytes_received"] == 8
    assert details["current_step"]["index"] == 5
  end

  test "public subsystem streams larger binary payloads through existing authorized file ports",
       context do
    {admin, exact} =
      subsystem_request(context, [
        %{"op" => "send", "body_file" => "payload"},
        %{
          "op" => "receive",
          "until" => %{"bytes" => 100_000},
          "response_file" => %{"name" => "reply.bin", "media_type" => "application/octet-stream"}
        },
        %{"op" => "send_eof"},
        %{"op" => "receive", "until" => %{"eof" => true}},
        %{"op" => "close"}
      ])

    bytes = :binary.copy(<<0, 255, 1, 128, 10>>, 20_000)

    file =
      Targets.begin_artifact!(
        exact.target_id,
        "input.bin",
        "application/octet-stream",
        100_000,
        Base.encode16(:crypto.hash(:sha256, bytes), case: :lower),
        Ecto.UUID.generate(),
        actor: admin
      )

    Targets.append_artifact_chunk!(file.id, 0, bytes, actor: admin)
    Targets.complete_artifact!(file.id, actor: admin)
    reference = Targets.artifact_reference!(file.id, exact.target_id, actor: admin)

    exact = %{
      exact
      | parameters:
          Map.merge(exact.parameters, %{
            "files" => %{"payload" => reference},
            "max_bytes" => 120_000
          })
    }

    clearance = Targets.clear_target_request!(exact, actor: admin)

    assert %Target.EffectResult{status: :applied, details: details} =
             Targets.dispatch_target_effect!(clearance, %{}, actor: admin, authorize?: false)

    received = Enum.at(details["steps"], 1)["file"]
    assert received["size_bytes"] == 100_000
    assert received["sha256"] == reference["sha256"]

    assert read_file(received, admin) == bytes
    assert details["bytes_sent"] == 100_000
    assert details["bytes_received"] == 100_004
    assert Enum.at(details["steps"], 3)["data"] == "ZG9uZQ=="
    assert byte_size(Jason.encode!(details)) < 4_096
    calls = Agent.get(context.subsystem_calls, &length/1)
    clearance = Targets.clear_target_request!(exact, actor: admin)
    Targets.revoke_artifact!(file.id, actor: admin)

    assert {:error, _} =
             Targets.dispatch_target_effect(clearance, %{}, actor: admin, authorize?: false)

    assert Agent.get(context.subsystem_calls, &length/1) == calls
  end

  test "subsystem file receives retain a delimiter split across native packets", context do
    {admin, exact} =
      subsystem_request(context, [
        %{"op" => "send", "data" => "c3BsaXQtZGVsaW1pdGVy"},
        %{
          "op" => "receive",
          "until" => %{"delimiter" => "fH4="},
          "response_file" => %{"name" => "framed.bin", "media_type" => "application/octet-stream"}
        },
        %{"op" => "receive", "until" => %{"bytes" => 4}},
        %{"op" => "close"}
      ])

    clearance = Targets.clear_target_request!(exact, actor: admin)

    assert %Target.EffectResult{status: :applied, details: details} =
             Targets.dispatch_target_effect!(clearance, %{}, actor: admin, authorize?: false)

    file = Enum.at(details["steps"], 1)["file"]
    assert read_file(file, admin) == "prefix|~"
    assert Targets.get_artifact!(file["id"], actor: admin).completion_reason == :byte_limit
    assert Enum.at(details["steps"], 2)["data"] == "dGFpbA=="
  end

  for phase <- [:begin, :append] do
    @tag ssh_file_port_fault: true, subsystem_file_fault_phase: phase
    test "subsystem #{phase} storage faults retain their original cause", context do
      phase = context.subsystem_file_fault_phase
      condition = if phase == :begin, do: "TRUE", else: "NEW.received_bytes <> OLD.received_bytes"
      event = if phase == :begin, do: "INSERT", else: "UPDATE"

      Skopos.Repo.query!("""
      CREATE FUNCTION pg_temp.reject_subsystem_file_port() RETURNS trigger LANGUAGE plpgsql AS $$
      BEGIN
        IF #{condition} THEN RAISE EXCEPTION 'subsystem file port unavailable'; END IF;
        RETURN NEW;
      END $$;
      """)

      Skopos.Repo.query!(
        "CREATE TRIGGER reject_subsystem_file_port BEFORE #{event} ON artifacts FOR EACH ROW EXECUTE FUNCTION pg_temp.reject_subsystem_file_port()"
      )

      {admin, exact} =
        subsystem_request(context, [
          %{"op" => "send", "data" => "cGluZw=="},
          %{
            "op" => "receive",
            "until" => %{"bytes" => 4},
            "response_file" => %{
              "name" => "reply-fault.bin",
              "media_type" => "application/octet-stream"
            }
          },
          %{"op" => "close"}
        ])

      clearance = Targets.clear_target_request!(exact, actor: admin)

      assert {:error, error} =
               Targets.dispatch_target_effect(clearance, %{}, actor: admin, authorize?: false)

      if phase == :begin do
        assert %Target.BeforeSendError{cause: cause} = Target.BeforeSendError.unwrap(error)
        assert Exception.message(cause) =~ "subsystem file port unavailable"
        assert Agent.get(context.subsystem_calls, &length/1) == 0
      else
        assert Exception.message(error) =~ "subsystem file port unavailable"
        assert Target.Error.context_failure?(error)

        assert %{
                 "receiving_file_id" => id,
                 "received_bytes" => 0,
                 "pending_chunk_bytes" => 4,
                 "steps" => [%{"bytes_sent" => 4}]
               } = Target.Error.context_progress(error)

        assert Targets.get_artifact!(id, actor: admin).status == :receiving
        assert Agent.get(context.subsystem_calls, &length/1) == 1
      end
    end
  end

  @tag ssh_file_port_fault: true
  test "subsystem receipt publication failure retains progress without success or replay",
       context do
    Skopos.Repo.query!("""
    CREATE FUNCTION pg_temp.reject_subsystem_completion() RETURNS trigger LANGUAGE plpgsql AS $$
    BEGIN
      IF NEW.status = 'ready' AND NEW.request_id = 'subsystem-save-failure' THEN
        RAISE EXCEPTION 'test subsystem receipt publication unavailable';
      END IF;
      RETURN NEW;
    END
    $$
    """)

    Skopos.Repo.query!("""
    CREATE TRIGGER reject_subsystem_completion BEFORE UPDATE ON artifacts
    FOR EACH ROW EXECUTE FUNCTION pg_temp.reject_subsystem_completion()
    """)

    {admin, exact} =
      subsystem_request(context, [
        %{"op" => "send", "data" => "cGluZw=="},
        %{
          "op" => "receive",
          "until" => %{"bytes" => 4},
          "response_file" => %{
            "name" => "unpublished.bin",
            "media_type" => "application/octet-stream"
          }
        },
        %{"op" => "close"}
      ])

    exact = %{exact | operation_id: "subsystem-save-failure"}
    clearance = Targets.clear_target_request!(exact, actor: admin)

    assert {:error, error} =
             Targets.dispatch_target_effect(clearance, %{}, actor: admin, authorize?: false)

    assert Exception.message(error) =~ "test subsystem receipt publication unavailable"
    assert Target.Error.context_failure?(error)
    details = Target.Error.context_progress(error)

    assert details["current_step"]["size_bytes"] == 4
    [receipt] = Targets.page_artifacts!(exact.target_id, actor: admin).results
    assert receipt.status == :receiving
    assert receipt.received_bytes == 4
    assert details["receiving_file_id"] == receipt.id
    assert details["received_bytes"] == 4
    assert {:error, _} = Targets.artifact_reference(receipt.id, exact.target_id, actor: admin)
    assert Agent.get(context.subsystem_calls, &length/1) == 1
    Skopos.Repo.query!("DROP TRIGGER reject_subsystem_completion ON artifacts")
  end

  for phase <- [:initial, :stream] do
    @tag ssh_file_port_fault: true, subsystem_reader_fault_phase: phase
    test "public subsystem input reader #{phase} faults retain cause and confirmed sends",
         context do
      {admin, exact} =
        subsystem_request(context, [
          %{"op" => "send", "body_file" => "payload"},
          %{"op" => "close"}
        ])

      file =
        Targets.begin_artifact!(
          exact.target_id,
          "input.bin",
          "application/octet-stream",
          3,
          Base.encode16(:crypto.hash(:sha256, "abc"), case: :lower),
          "reader-fault",
          actor: admin
        )

      Targets.append_artifact_chunk!(file.id, 0, "abc", actor: admin)
      Targets.complete_artifact!(file.id, actor: admin)
      reference = Targets.artifact_reference!(file.id, exact.target_id, actor: admin)
      method = Targets.get_access_method!(exact.access_method_id, actor: admin)

      request = %Target.EffectRequest{
        provider_revision: method.provider_revision,
        target_id: exact.target_id,
        target_revision: exact.target_revision,
        access_method_id: method.id,
        access_method_revision: method.revision,
        connection: %Target.Connection{endpoint: context.endpoint},
        capability: exact.capability,
        operation: exact.operation,
        authorization_digest: "fixture",
        operation_id: Ecto.UUID.generate(),
        idempotency_key: Ecto.UUID.generate(),
        files: %{"payload" => reference},
        parameters: exact.parameters
      }

      reader = fn "payload", offset ->
        if context.subsystem_reader_fault_phase == :stream and offset == 0 do
          {:ok, "ab"}
        else
          {:error, cause} =
            Skopos.Repo.query("SELECT subsystem_reader_context_unavailable", [], mode: :savepoint)

          {:error, Target.Error.context_failure(cause)}
        end
      end

      assert {:error, error} =
               Providers.target_effect(method.provider_id, request, %{file_reader: reader},
                 actor: admin,
                 authorize?: false
               )

      if context.subsystem_reader_fault_phase == :initial do
        assert %Target.BeforeSendError{cause: cause} = Target.BeforeSendError.unwrap(error)
        assert Exception.message(cause) =~ "subsystem_reader_context_unavailable"
        assert Agent.get(context.subsystem_calls, &length/1) == 0
      else
        assert Exception.message(error) =~ "subsystem_reader_context_unavailable"
        assert Target.Error.context_failure?(error)
        assert %{"input_file_id" => id, "bytes_sent" => 2} = Target.Error.context_progress(error)
        assert id == file.id
        assert Agent.get(context.subsystem_calls, &length/1) == 1
      end
    end
  end

  test "subsystem invalid sequences and current authority checks dispatch no payload", context do
    {admin, exact} =
      subsystem_request(context, [%{"op" => "send", "data" => "cGluZw=="}, %{"op" => "close"}])

    for steps <- [
          [%{"op" => "send", "data" => "invalid*"}, %{"op" => "close"}],
          [%{"op" => "send_eof"}, %{"op" => "send", "data" => "cGluZw=="}, %{"op" => "close"}],
          [%{"op" => "close"}, %{"op" => "receive", "until" => %{"bytes" => 1}}],
          [%{"op" => "send", "data" => "cGluZw=="}],
          [%{"op" => "receive", "until" => %{"delimiter" => ""}}, %{"op" => "close"}]
        ] do
      assert {:error, _} =
               Targets.clear_target_request(
                 %{exact | parameters: Map.put(exact.parameters, "steps", steps)},
                 actor: admin
               )
    end

    clearance = Targets.clear_target_request!(%{exact | authority_mode: :readonly}, actor: admin)

    assert {:error, error} =
             Targets.dispatch_target_effect(clearance, %{}, actor: admin, authorize?: false)

    assert request_error(error).category == :forbidden
    clearance = Targets.clear_target_request!(exact, actor: admin)
    method = Targets.get_access_method!(exact.access_method_id, actor: admin)
    Targets.update_access_method!(method, method.revision, %{priority: 90}, actor: admin)

    assert {:error, error} =
             Targets.dispatch_target_effect(clearance, %{}, actor: admin, authorize?: false)

    assert request_error(error).category == :stale_context
    assert Agent.get(context.subsystem_calls, & &1) == []
  end

  test "interrupted subsystem file receive remains unpublished with its exact partial count",
       context do
    {admin, exact} =
      subsystem_request(
        context,
        [
          %{"op" => "send", "data" => "cGFydGlhbA=="},
          %{
            "op" => "receive",
            "until" => %{"bytes" => 20},
            "response_file" => %{
              "name" => "partial.bin",
              "media_type" => "application/octet-stream"
            }
          },
          %{"op" => "close"}
        ],
        %{"operation_timeout_ms" => 500}
      )

    clearance = Targets.clear_target_request!(exact, actor: admin)

    assert %Target.EffectResult{status: :unknown, details: details} =
             Targets.dispatch_target_effect!(clearance, %{}, actor: admin, authorize?: false)

    assert details["current_step"]["size_bytes"] == 7
    [receipt] = Targets.page_artifacts!(exact.target_id, actor: admin).results
    assert receipt.received_bytes == 7
    assert receipt.status == :receiving
    assert {:error, _} = Targets.artifact_reference(receipt.id, exact.target_id, actor: admin)
    assert Agent.get(context.subsystem_calls, &length/1) == 1
  end

  test "unavailable subsystem is rejected without transmitting requested payload", context do
    {admin, exact} =
      subsystem_request(context, [%{"op" => "send", "data" => "cGluZw=="}, %{"op" => "close"}])

    exact = %{exact | parameters: Map.put(exact.parameters, "subsystem", "not-supported-by-peer")}
    clearance = Targets.clear_target_request!(exact, actor: admin)

    assert {:error, _} =
             Targets.dispatch_target_effect(clearance, %{}, actor: admin, authorize?: false)

    assert Agent.get(context.subsystem_calls, & &1) == []
  end

  test "subsystem preserves a native nonzero exit status instead of reporting success", context do
    {admin, exact} =
      subsystem_request(context, [
        %{"op" => "send", "data" => "bmF0aXZlLWZhaWx1cmU="},
        %{"op" => "receive", "until" => %{"bytes" => 6}},
        %{"op" => "close"}
      ])

    clearance = Targets.clear_target_request!(exact, actor: admin)

    assert %Target.EffectResult{status: :failed, details: details} =
             Targets.dispatch_target_effect!(clearance, %{}, actor: admin, authorize?: false)

    assert details["exit_status"] == 7
    assert Enum.at(details["steps"], 1)["data"] == "ZmFpbGVk"
  end

  for {type, provider, kind} <- [
        {"linux", "linux-ssh", "host"},
        {"cisco_ios_xe", "ios-xe-ssh", "network_device"}
      ] do
    @tag target_type: type,
         provider_type: provider,
         target_kind: kind,
         target_method: if(provider == "ios-xe-ssh", do: "ssh_cli", else: "ssh")
    test "#{type} profile retains the same generic subsystem exchange", context do
      {admin, exact} =
        subsystem_request(context, [
          %{"op" => "send", "data" => "AP8="},
          %{"op" => "receive", "until" => %{"bytes" => 14}},
          %{"op" => "close"}
        ])

      clearance = Targets.clear_target_request!(exact, actor: admin)

      assert %Target.EffectResult{status: :applied, details: details} =
               Targets.dispatch_target_effect!(clearance, %{}, actor: admin, authorize?: false)

      assert Enum.at(details["steps"], 1)["data"] == "Zmlyc3R8bGVmdG92ZXI="
      assert [{_, <<0, 255>>}] = Agent.get(context.subsystem_calls, & &1)
    end
  end

  test "subsystem rejects a changed Target and a viewer before payload dispatch", context do
    {admin, exact} =
      subsystem_request(context, [%{"op" => "send", "data" => "cGluZw=="}, %{"op" => "close"}])

    viewer =
      Accounts.create_user!("subsystem-viewer@example.com", @password, :viewer, actor: admin)

    assert {:error, _} = Targets.clear_target_request(exact, actor: viewer)
    clearance = Targets.clear_target_request!(exact, actor: admin)
    target = Targets.get_target!(exact.target_id, actor: admin)

    Targets.update_target!(target, target.revision, %{name: "changed-subsystem-device"},
      actor: admin
    )

    assert {:error, error} =
             Targets.dispatch_target_effect(clearance, %{}, actor: admin, authorize?: false)

    assert request_error(error).category == :stale_context
    assert Agent.get(context.subsystem_calls, & &1) == []
  end

  test "SSH adapter exposes arbitrary commands only as reviewed effects",
       context do
    admin = Accounts.bootstrap!("ssh-admin@example.com", @password, @password)

    operator =
      Accounts.create_user!("ssh-operator@example.com", @password, :operator, actor: admin)

    provider =
      Providers.create_provider!(
        "ssh",
        :target,
        "ssh",
        configuration(context),
        password_credentials(),
        actor: admin
      )
      |> then(&Providers.enable_provider!(&1, &1.revision, actor: admin))

    assert %Target.Capabilities{
             observations: [file_reader | _metadata],
             effects: [tool, shell, subsystem, file_writer | _filesystem]
           } =
             Providers.target_capabilities!(
               provider.id,
               %Target.CapabilitiesRequest{
                 provider_revision: provider.revision,
                 connection: %Target.Connection{endpoint: context.endpoint}
               },
               %{},
               actor: admin
             )

    assert tool.capability == "request.ssh.effect"
    assert tool.operation == "command.execute"
    assert shell.capability == "request.ssh.effect"
    assert shell.operation == "shell.execute"
    assert subsystem.operation == "subsystem.session"
    assert file_reader.capability == "request.ssh.observe"
    assert file_reader.operation == "sftp.read_file"
    assert file_writer.capability == "request.ssh.effect"
    assert file_writer.operation == "sftp.write_file"

    target =
      Targets.create_target!("future-router", "network_device", "custom-network-device", %{}, nil,
        actor: admin
      )

    method =
      Targets.create_access_method!(
        target.id,
        provider.id,
        "registered-ssh",
        "ssh",
        context.endpoint,
        provider.revision,
        100,
        ["request.ssh.effect"],
        actor: admin
      )
      |> then(&Targets.check_access_method!(&1.id, &1.revision, %{}, actor: admin))

    for command <- ["uname -a", "systemctl restart sshd.service", "uname -a; touch /tmp/unsafe"] do
      assert {:error, denied} =
               Targets.clear_target_request(
                 request(target, method, :observation, :auto, command),
                 actor: operator
               )

      assert request_error(denied).category == :denied
    end

    assert commands(context) == []

    readonly_clearance =
      Targets.clear_target_request!(
        request(target, method, :effect, :readonly, "never-readonly"),
        actor: operator
      )

    assert {:error, readonly_error} =
             Targets.dispatch_target_effect(readonly_clearance, %{},
               actor: operator,
               authorize?: false
             )

    assert request_error(readonly_error).category == :forbidden

    stale_clearance =
      Targets.clear_target_request!(
        request(target, method, :effect, :full_access, "never-stale"),
        actor: operator
      )

    method = Targets.update_access_method!(method, method.revision, %{priority: 90}, actor: admin)

    assert {:error, stale_error} =
             Targets.dispatch_target_effect(stale_clearance, %{},
               actor: operator,
               authorize?: false
             )

    assert request_error(stale_error).category == :stale_context
    assert commands(context) == []

    effect_clearance =
      Targets.clear_target_request!(
        request(target, method, :effect, :full_access, "apply"),
        actor: operator
      )

    assert %Target.EffectResult{status: :applied, details: details} =
             Targets.dispatch_target_effect!(effect_clearance, %{},
               actor: operator,
               authorize?: false
             )

    assert details["stdout"] == %{"encoding" => "utf-8", "value" => "ran:apply"}
    assert commands(context) == ["apply"]

    for command <- ["sysctl kern.ostype", "show chassis alarms", "configure terminal"] do
      clearance =
        Targets.clear_target_request!(
          request(target, method, :effect, :full_access, command),
          actor: operator
        )

      assert %Target.EffectResult{status: :applied} =
               Targets.dispatch_target_effect!(clearance, %{},
                 actor: operator,
                 authorize?: false
               )
    end

    assert commands(context) ==
             ["apply", "sysctl kern.ostype", "show chassis alarms", "configure terminal"]

    assert {:error, _} =
             Targets.clear_target_request(
               request(target, method, :verification, :full_access, "uname -a"),
               actor: operator
             )

    assert commands(context) ==
             ["apply", "sysctl kern.ostype", "show chassis alarms", "configure terminal"]
  end

  defp configuration(context, overrides \\ %{}) do
    Map.merge(
      %{
        "host_key_fingerprints" => %{context.endpoint => context.fingerprint},
        "connect_timeout_ms" => 2_000,
        "operation_timeout_ms" => 2_000,
        "max_output_bytes" => 32_768
      },
      overrides
    )
  end

  defp read_file(file, actor) do
    Stream.unfold(0, fn offset ->
      if offset == file["size_bytes"] do
        nil
      else
        chunk = Targets.read_bound_artifact_chunk!(file, offset, actor: actor)
        {chunk, offset + byte_size(chunk)}
      end
    end)
    |> Enum.to_list()
    |> IO.iodata_to_binary()
  end

  defp subsystem_request(context, steps, config \\ %{}) do
    admin = Accounts.bootstrap!("subsystem-admin@example.com", @password, @password)

    provider =
      Providers.create_provider!(
        "ssh",
        :target,
        Map.get(context, :provider_type, "ssh"),
        configuration(context, config),
        password_credentials(),
        actor: admin
      )
      |> then(&Providers.enable_provider!(&1, &1.revision, actor: admin))

    target =
      Targets.create_target!(
        "subsystem-device",
        Map.get(context, :target_kind, "network_device"),
        Map.get(context, :target_type, "custom-network-device"),
        %{},
        nil,
        actor: admin
      )

    method =
      Targets.create_access_method!(
        target.id,
        provider.id,
        "ssh",
        Map.get(context, :target_method, "ssh"),
        context.endpoint,
        provider.revision,
        100,
        ["request.ssh.effect"],
        actor: admin
      )
      |> then(&Targets.check_access_method!(&1.id, &1.revision, %{}, actor: admin))

    exact =
      request(target, method, :effect, :full_access, "unused")
      |> Map.put(:operation, "subsystem.session")
      |> Map.put(:parameters, %{"subsystem" => "test-subsystem", "steps" => steps})

    {admin, exact}
  end

  defp password_config(context) do
    {:ok, config} = Transport.build(configuration(context), password_credentials())
    config
  end

  defp password_credentials(password \\ "secret") do
    %{"username" => "tester", "auth_method" => "password", "password" => password}
  end

  defp public_key_credentials(key) do
    %{"username" => "tester", "auth_method" => "public_key", "private_key" => key}
  end

  defp request(target, method, kind, mode, command) do
    struct!(Request,
      kind: kind,
      authority_mode: mode,
      target_id: target.id,
      target_revision: target.revision,
      access_method_id: method.id,
      access_method_revision: method.revision,
      capability: "request.ssh.effect",
      operation: "command.execute",
      selectors: %{},
      parameters: %{"command" => command},
      operation_id: if(kind in [:effect, :verification], do: "operation-#{command}"),
      idempotency_key: if(kind == :effect, do: "idempotency-#{command}")
    )
  end

  defp commands(context), do: Agent.get(context.commands, &Enum.reverse/1)

  defp command_executor(commands) do
    fn command ->
      command = to_string(command)
      Agent.update(commands, &[command | &1])

      case command do
        "stderr" ->
          {:error, "failed"}

        "large" ->
          {:ok, String.duplicate("x", 100)}

        "slow" ->
          Process.sleep(1_000)
          {:ok, "done"}

        "ready-reply" ->
          Process.sleep(60)
          {:ok, "completed"}

        value ->
          {:ok, "ran:#{value}"}
      end
    end
  end

  defp write_private_key!(path, key) do
    File.write!(path, encode_private_key(key))
    File.chmod!(path, 0o600)
  end

  defp encode_private_key(key) do
    :public_key.pem_encode([:public_key.pem_entry_encode(:RSAPrivateKey, key)])
  end

  defp request_error(%{errors: errors}) do
    Enum.find_value(errors, fn
      %RequestError{} = error -> error
      nested when is_map(nested) -> request_error(nested)
      _other -> nil
    end)
  end

  defp request_error(_error), do: nil
end
