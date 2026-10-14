defmodule Skopos.Targets.IPMIRequestTest do
  use ExUnit.Case, async: true

  alias Skopos.Providers.Target
  alias Skopos.Targets.Adapters.IPMI

  @endpoint "ipmi://127.0.0.1:623"

  test "IPMI connection options preserve SDK password, privilege and cipher choices" do
    credentials = %{"username" => "fixture", "password" => "12345678901234567890"}

    for adapter <- [
          IPMI,
          Skopos.Targets.Profiles.HPEILO.IPMI,
          Skopos.Targets.Profiles.DellIDRAC.IPMI
        ],
        privilege <- 1..5,
        cipher <- ["auto" | Enum.to_list(0..17)] do
      assert {:ok, _state} =
               adapter.build(
                 %{"privilege_level" => privilege, "cipher_suite" => cipher},
                 credentials
               )
    end

    for configuration <- [
          %{"privilege_level" => 0},
          %{"privilege_level" => 6},
          %{"privilege_level" => "2"},
          %{"cipher_suite" => 18},
          %{"cipher_suite" => 255},
          %{"cipher_suite" => "3"}
        ] do
      assert {:error, :invalid_configuration} = IPMI.build(configuration, credentials)
    end

    for credentials <- [
          %{credentials | "username" => String.duplicate("a", 17)},
          %{credentials | "password" => String.duplicate("a", 21)},
          %{credentials | "username" => "fi\0xture"},
          %{credentials | "password" => "fi\0xture"}
        ] do
      assert {:error, :invalid_configuration} = IPMI.build(%{}, credentials)
    end
  end

  test "native IPMI rejects malformed credentials and session options before sending" do
    alias Skopos.Transports.IPMI, as: Transport
    {:ok, socket} = :gen_udp.open(0, [:binary, active: false, ip: {127, 0, 0, 1}])
    on_exit(fn -> :gen_udp.close(socket) end)
    {:ok, port} = :inet.port(socket)
    session = %{username: "fixture", password: "fixture", privilege_level: 2, cipher_suite: 3}

    command = %{
      netfn: 6,
      command: 1,
      data: [],
      lun: 0,
      target_address: 32,
      target_channel: 0,
      transit_address: 0,
      transit_channel: 0
    }

    console = %{
      instance: 1,
      flags: 0xC6,
      generate_break: false,
      input: [],
      read_ms: 0,
      max_output_bytes: 64
    }

    for invalid <- [
          %{session | username: String.duplicate("a", 17)},
          %{session | password: String.duplicate("a", 21)},
          %{session | password: "fi\0xture"},
          %{session | privilege_level: 0},
          %{session | cipher_suite: 18}
        ] do
      assert {:error, "invalid_request"} =
               Transport.exchange_command("127.0.0.1:#{port}", invalid, 100, command, %{})

      assert {:error, "invalid_request"} =
               Transport.exchange_console("127.0.0.1:#{port}", invalid, 100, console, %{})
    end

    assert {:error, :timeout} = :gen_udp.recv(socket, 0, 20)
  end

  @tag ipmi_sol: true
  test "SOL exchange uses the existing exact IPMI effect authority for all profiles" do
    for adapter <- [
          IPMI,
          Skopos.Targets.Profiles.HPEILO.IPMI,
          Skopos.Targets.Profiles.DellIDRAC.IPMI
        ] do
      {:ok, state} = adapter.build(%{}, %{"username" => "fixture", "password" => "fixture"})
      {:ok, state} = adapter.bind_connection(state, %Target.Connection{endpoint: @endpoint})

      effect = %{
        request(%{"input_hex" => "0d", "read_ms" => 100, "max_output_bytes" => 30_000})
        | operation: "console.exchange"
      }

      exact =
        struct!(
          Target.MethodRequest,
          Map.take(Map.from_struct(effect), [
            :provider_revision,
            :connection,
            :capability,
            :operation,
            :selectors,
            :parameters
          ])
        )

      assert {:ok, %Target.RequestClassification{kind: :effect}} =
               Target.classify_request(adapter, state, exact)

      assert {:error, :cancelled, _} =
               adapter.effect(state, effect, %{cancelled?: fn -> true end})

      for invalid <- [
            Map.put(effect.parameters, "instance", 0),
            Map.put(effect.parameters, "input_hex", "F"),
            Map.put(effect.parameters, "activation_flags", 256),
            Map.put(effect.parameters, "read_ms", 30_000),
            Map.put(effect.parameters, "max_output_bytes", 30_001),
            Map.put(effect.parameters, "generate_break", "true"),
            Map.put(effect.parameters, "netfn", 6)
          ] do
        assert {:error, :failed, _} =
                 Target.classify_request(adapter, state, %{exact | parameters: invalid})
      end
    end
  end

  @tag ipmi_deadline: true
  test "IPMI authentication context failure retains its cause and releases the next request" do
    for {action, type, capability, operation, parameters} <- [
          {&IPMI.effect/3, Target.EffectRequest, "request.ipmi.effect", "command.execute",
           %{"netfn" => 6, "command" => 1}},
          {&IPMI.effect/3, Target.EffectRequest, "request.ipmi.effect", "console.exchange",
           %{"input_hex" => "0d"}},
          {&IPMI.observe/3, Target.ObservationRequest, "observe.power", "bmc.power.inspect", %{}},
          {&IPMI.verify/3, Target.VerificationRequest, "observe.power", "bmc.power.inspect", %{}},
          {fn state, _request, invocation -> IPMI.capabilities(state, invocation) end,
           Target.ObservationRequest, "observe.power", "bmc.power.inspect", %{}}
        ] do
      {:ok, socket} = :gen_udp.open(0, [:binary, active: false, ip: {127, 0, 0, 1}])
      on_exit(fn -> :gen_udp.close(socket) end)
      {:ok, port} = :inet.port(socket)

      {:ok, state} =
        IPMI.build(%{"timeout_ms" => 3000}, %{"username" => "fixture", "password" => "fixture"})

      {:ok, state} =
        IPMI.bind_connection(state, %Target.Connection{endpoint: "ipmi://127.0.0.1:#{port}"})

      failure = :atomics.new(1, [])
      cause = RuntimeError.exception("IPMI invocation context read failed")

      input =
        request(parameters)
        |> Map.from_struct()
        |> Map.take(Map.keys(struct(type)))
        |> Map.put(:connection, %Target.Connection{endpoint: state.endpoint})
        |> Map.put(:capability, capability)
        |> Map.put(:operation, operation)
        |> then(&struct!(type, &1))

      parent = self()

      waiting =
        Task.async(fn ->
          result =
            try do
              action.(state, input, %{
                cancelled?: fn ->
                  if :atomics.get(failure, 1) == 1, do: raise(cause), else: false
                end
              })
            rescue
              error -> {:error, error}
            end

          send(parent, {:ipmi_context_result, self(), result})

          receive do
            :release -> result
          after
            5000 -> result
          end
        end)

      on_exit(fn -> if Process.alive?(waiting.pid), do: Process.exit(waiting.pid, :kill) end)

      assert {:ok, {_address, _port, _handshake}} = :gen_udp.recv(socket, 0, 1000)
      :atomics.put(failure, 1, 1)
      caller = waiting.pid
      assert_receive {:ipmi_context_result, ^caller, {:error, error}}, 1000
      assert %Target.BeforeSendError{cause: ^cause} = Target.BeforeSendError.unwrap(error)
      assert Target.BeforeSendError.retryable?(error)

      assert {:error, :unreachable, _} =
               IPMI.check(%{state | timeout: 100}, %{"endpoint" => state.endpoint})

      assert {:ok, {_address, _port, _next_handshake}} = :gen_udp.recv(socket, 0, 100)
      send(caller, :release)
      assert {:error, ^error} = Task.await(waiting, 1000)
    end
  end

  @tag ipmi_deadline: true
  test "IPMI context failure before exchange sends no authentication request" do
    {:ok, socket} = :gen_udp.open(0, [:binary, active: false, ip: {127, 0, 0, 1}])
    on_exit(fn -> :gen_udp.close(socket) end)
    {:ok, port} = :inet.port(socket)
    {:ok, state} = IPMI.build(%{}, %{"username" => "fixture", "password" => "fixture"})

    {:ok, state} =
      IPMI.bind_connection(state, %Target.Connection{endpoint: "ipmi://127.0.0.1:#{port}"})

    input = %{
      request(%{"netfn" => 6, "command" => 1})
      | connection: %Target.Connection{endpoint: state.endpoint}
    }

    cause = RuntimeError.exception("IPMI pre-exchange context read failed")

    for {callback, expected_cause} <- [
          {fn -> raise cause end, cause},
          {fn -> throw(:unavailable_context) end, {:throw, :unavailable_context}}
        ] do
      assert {:error, %Target.BeforeSendError{cause: ^expected_cause}} =
               IPMI.effect(state, input, %{cancelled?: callback})

      assert {:error, :timeout} = :gen_udp.recv(socket, 0, 20)
    end
  end

  @tag ipmi_native_before_send: true
  test "IPMI rechecks current facts before native authentication independently of waiting" do
    {:ok, socket} = :gen_udp.open(0, [:binary, active: false, ip: {127, 0, 0, 1}])
    on_exit(fn -> :gen_udp.close(socket) end)
    {:ok, port} = :inet.port(socket)

    {:ok, state} =
      IPMI.build(%{"timeout_ms" => 100}, %{"username" => "fixture", "password" => "fixture"})

    {:ok, state} =
      IPMI.bind_connection(state, %Target.Connection{endpoint: "ipmi://127.0.0.1:#{port}"})

    owner = self()

    cause =
      Ash.Error.Invalid.exception(
        errors: [RuntimeError.exception("IPMI native context unavailable")]
      )

    for operation <- ["command.execute", "console.exchange"] do
      input =
        if operation == "command.execute",
          do: request(%{"netfn" => 6, "command" => 1}),
          else: %{request(%{"input_hex" => "0d"}) | operation: operation}

      input = %{input | connection: %Target.Connection{endpoint: state.endpoint}}

      before_send? = fn ->
        if self() != owner, do: raise(cause), else: false
      end

      assert {:error, error} =
               IPMI.effect(state, input, %{
                 before_send?: before_send?,
                 cancelled?: fn -> false end
               })

      assert %Target.BeforeSendError{cause: ^cause} = Target.BeforeSendError.unwrap(error)
      assert {:error, :timeout} = :gen_udp.recv(socket, 0, 20)
    end
  end

  @tag ipmi_deadline: true
  test "IPMI authentication cancellation stops the request and permits the next request" do
    for {operation, parameters} <- [
          {"console.exchange", %{"input_hex" => "0d"}},
          {"command.execute", %{"netfn" => 6, "command" => 1}}
        ] do
      {:ok, socket} = :gen_udp.open(0, [:binary, active: false, ip: {127, 0, 0, 1}])
      on_exit(fn -> :gen_udp.close(socket) end)
      {:ok, port} = :inet.port(socket)
      credentials = %{"username" => "fixture", "password" => "fixture"}
      {:ok, state} = IPMI.build(%{"timeout_ms" => 3000}, credentials)

      {:ok, state} =
        IPMI.bind_connection(state, %Target.Connection{endpoint: "ipmi://127.0.0.1:#{port}"})

      cancellation = :atomics.new(1, [])

      effect = %{
        request(parameters)
        | connection: %Target.Connection{endpoint: state.endpoint},
          operation: operation
      }

      waiting =
        Task.async(fn ->
          IPMI.effect(state, effect, %{cancelled?: fn -> :atomics.get(cancellation, 1) == 1 end})
        end)

      assert {:ok, {_address, _port, _handshake}} = :gen_udp.recv(socket, 0, 1000)
      started = System.monotonic_time(:millisecond)
      :atomics.put(cancellation, 1, 1)
      assert {:error, :cancelled, _} = Task.await(waiting, 1000)
      assert System.monotonic_time(:millisecond) - started < 500
      assert {:error, :timeout} = :gen_udp.recv(socket, 0, 20)

      assert {:error, :unreachable, _} =
               IPMI.check(%{state | timeout: 100}, %{"endpoint" => state.endpoint})

      assert {:ok, {_address, _port, _next_handshake}} = :gen_udp.recv(socket, 0, 100)
    end
  end

  @tag ipmi_deadline: true
  test "IPMI caller termination stops authentication and permits the next request" do
    for {operation, parameters} <- [
          {"console.exchange", %{"input_hex" => "0d"}},
          {"command.execute", %{"netfn" => 6, "command" => 1}}
        ] do
      {:ok, socket} = :gen_udp.open(0, [:binary, active: false, ip: {127, 0, 0, 1}])
      on_exit(fn -> :gen_udp.close(socket) end)
      {:ok, port} = :inet.port(socket)

      {:ok, state} =
        IPMI.build(%{"timeout_ms" => 3000}, %{"username" => "fixture", "password" => "fixture"})

      {:ok, state} =
        IPMI.bind_connection(state, %Target.Connection{endpoint: "ipmi://127.0.0.1:#{port}"})

      effect = %{
        request(parameters)
        | connection: %Target.Connection{endpoint: state.endpoint},
          operation: operation
      }

      {caller, monitor} = spawn_monitor(fn -> IPMI.effect(state, effect, %{}) end)
      assert {:ok, {_address, _port, _handshake}} = :gen_udp.recv(socket, 0, 1000)
      Process.exit(caller, :kill)
      assert_receive {:DOWN, ^monitor, :process, ^caller, :killed}

      assert {:error, :unreachable, _} =
               IPMI.check(%{state | timeout: 200}, %{"endpoint" => state.endpoint})

      assert {:ok, {_address, _port, _next_handshake}} = :gen_udp.recv(socket, 0, 100)
      assert {:error, :timeout} = :gen_udp.recv(socket, 0, 20)
    end
  end

  @tag ipmi_deadline: true
  test "IPMI local wait expiry does not report the other BMC as unreachable or send later" do
    {:ok, socket} = :gen_udp.open(0, [:binary, active: false, ip: {127, 0, 0, 1}])
    on_exit(fn -> :gen_udp.close(socket) end)
    {:ok, port} = :inet.port(socket)
    {:ok, other_socket} = :gen_udp.open(0, [:binary, active: false, ip: {127, 0, 0, 1}])
    on_exit(fn -> :gen_udp.close(other_socket) end)
    {:ok, other_port} = :inet.port(other_socket)
    credentials = %{"username" => "fixture", "password" => "fixture"}
    {:ok, slow} = IPMI.build(%{"timeout_ms" => 1000}, credentials)
    {:ok, short} = IPMI.build(%{"timeout_ms" => 100}, credentials)
    endpoint = %{"endpoint" => "ipmi://127.0.0.1:#{port}"}
    waiting = Task.async(fn -> IPMI.check(slow, endpoint) end)
    assert {:ok, {_address, _port, _handshake}} = :gen_udp.recv(socket, 0, 500)
    started = System.monotonic_time(:millisecond)

    assert {:error, :provider_failure, "IPMI local execution wait expired before dispatch"} =
             IPMI.check(short, %{"endpoint" => "ipmi://127.0.0.1:#{other_port}"})

    assert System.monotonic_time(:millisecond) - started < 500
    assert {:error, :timeout} = :gen_udp.recv(other_socket, 0, 20)
    assert {:error, :unreachable, _} = Task.await(waiting, 2000)
    assert {:error, :timeout} = :gen_udp.recv(other_socket, 0, 20)
  end

  @tag ipmi_deadline: true
  test "IPMI queued command and console failures retain no-dispatch facts and allow cancellation" do
    {:ok, socket} = :gen_udp.open(0, [:binary, active: false, ip: {127, 0, 0, 1}])
    on_exit(fn -> :gen_udp.close(socket) end)
    {:ok, port} = :inet.port(socket)
    {:ok, other_socket} = :gen_udp.open(0, [:binary, active: false, ip: {127, 0, 0, 1}])
    on_exit(fn -> :gen_udp.close(other_socket) end)
    {:ok, other_port} = :inet.port(other_socket)
    credentials = %{"username" => "fixture", "password" => "fixture"}
    {:ok, state} = IPMI.build(%{"timeout_ms" => 3000}, credentials)

    {:ok, state} =
      IPMI.bind_connection(state, %Target.Connection{endpoint: "ipmi://127.0.0.1:#{other_port}"})

    holder_cancel = :atomics.new(1, [])

    holder_request = %{
      request(%{"netfn" => 6, "command" => 1})
      | connection: %Target.Connection{endpoint: "ipmi://127.0.0.1:#{port}"}
    }

    {:ok, holder_state} = IPMI.bind_connection(state, holder_request.connection)

    holder =
      Task.async(fn ->
        IPMI.effect(holder_state, holder_request, %{
          cancelled?: fn -> :atomics.get(holder_cancel, 1) == 1 end
        })
      end)

    assert {:ok, {_address, _port, _handshake}} = :gen_udp.recv(socket, 0, 1000)

    for {operation, parameters} <- [
          {"command.execute", %{"netfn" => 6, "command" => 1}},
          {"console.exchange", %{"input_hex" => "0d"}}
        ] do
      effect = %{
        request(parameters)
        | connection: %Target.Connection{endpoint: state.endpoint},
          operation: operation
      }

      assert {:ok, %Target.EffectResult{status: :failed, details: details}} =
               IPMI.effect(%{state | timeout: 100}, effect, %{})

      assert details["provider_category"] == "local_capacity"
      assert details["dispatched"] == false

      cancellation = :atomics.new(1, [])

      queued =
        Task.async(fn ->
          IPMI.effect(state, effect, %{cancelled?: fn -> :atomics.get(cancellation, 1) == 1 end})
        end)

      assert Task.yield(queued, 30) == nil
      :atomics.put(cancellation, 1, 1)
      assert {:error, :cancelled, _} = Task.await(queued, 500)
    end

    assert {:error, :retryable, "IPMI local execution wait expired before dispatch"} =
             IPMI.capabilities(%{state | timeout: 100}, %{})

    assert {:error, :timeout} = :gen_udp.recv(other_socket, 0, 20)
    :atomics.put(holder_cancel, 1, 1)
    assert {:error, :cancelled, _} = Task.await(holder, 500)
    assert {:error, :timeout} = :gen_udp.recv(other_socket, 0, 20)
  end

  @tag ipmi_deadline: true
  test "IPMI connection checks finish within the configured deadline when the peer stays silent" do
    {:ok, socket} = :gen_udp.open(0, [:binary, active: false, ip: {127, 0, 0, 1}])
    on_exit(fn -> :gen_udp.close(socket) end)
    {:ok, port} = :inet.port(socket)

    {:ok, state} =
      IPMI.build(%{"timeout_ms" => 100}, %{"username" => "fixture", "password" => "fixture"})

    started = System.monotonic_time(:millisecond)

    assert {:error, :unreachable, _} =
             IPMI.check(state, %{"endpoint" => "ipmi://127.0.0.1:#{port}"})

    assert System.monotonic_time(:millisecond) - started < 500
    assert {:ok, {_address, _port, _handshake}} = :gen_udp.recv(socket, 0, 100)
    assert {:error, :timeout} = :gen_udp.recv(socket, 0, 20)
  end

  @tag ipmi_addressing: true
  test "IPMI Methods accept exact LUN and bridge addressing without changing effect authority" do
    for adapter <- [
          IPMI,
          Skopos.Targets.Profiles.HPEILO.IPMI,
          Skopos.Targets.Profiles.DellIDRAC.IPMI
        ] do
      {:ok, state} = adapter.build(%{}, %{"username" => "fixture", "password" => "fixture"})
      {:ok, state} = adapter.bind_connection(state, %Target.Connection{endpoint: @endpoint})

      parameters = %{
        "netfn" => 6,
        "command" => 1,
        "lun" => 1,
        "target_address" => 0x30,
        "target_channel" => 0,
        "transit_address" => 0x20,
        "transit_channel" => 1
      }

      effect = request(parameters)

      exact =
        struct!(
          Target.MethodRequest,
          Map.take(
            Map.from_struct(effect),
            [:provider_revision, :connection, :capability, :operation, :selectors, :parameters]
          )
        )

      assert {:ok, %Target.RequestClassification{kind: :effect}} =
               Target.classify_request(adapter, state, exact)

      assert {:error, :cancelled, _} =
               adapter.effect(state, effect, %{cancelled?: fn -> true end})

      for invalid <- [
            Map.put(parameters, "lun", 4),
            Map.put(parameters, "target_address", 256),
            Map.put(parameters, "target_channel", 16),
            Map.put(parameters, "transit_address", -1),
            Map.put(parameters, "transit_channel", "1")
          ] do
        assert {:error, :failed, _} =
                 Target.classify_request(adapter, state, %{exact | parameters: invalid})
      end
    end
  end

  test "classify exact IPMI requests without assuming an arbitrary command is read-only" do
    raw = %Target.MethodRequest{
      provider_revision: 1,
      connection: %Target.Connection{endpoint: @endpoint},
      capability: "request.ipmi.effect",
      operation: "command.execute",
      selectors: %{},
      parameters: %{"netfn" => 6, "command" => 1}
    }

    power = %{raw | capability: "observe.power", operation: "bmc.power.inspect", parameters: %{}}

    for adapter <- [
          IPMI,
          Skopos.Targets.Profiles.HPEILO.IPMI,
          Skopos.Targets.Profiles.DellIDRAC.IPMI
        ] do
      {:ok, state} = adapter.build(%{}, %{"username" => "fixture", "password" => "fixture"})
      {:ok, state} = adapter.bind_connection(state, %Target.Connection{endpoint: @endpoint})

      assert {:ok, %Target.RequestClassification{kind: :effect}} =
               Target.classify_request(adapter, state, raw)

      assert {:ok, %Target.RequestClassification{kind: :observation}} =
               Target.classify_request(adapter, state, power)

      for invalid <- [
            %{raw | connection: %Target.Connection{endpoint: "ipmi://other.example:623"}},
            %{raw | parameters: %{"netfn" => 7, "command" => 1}},
            %{raw | parameters: %{"netfn" => 6, "command" => 1, "data_hex" => "F"}},
            %{raw | capability: "request.ipmi.observe"}
          ] do
        assert {:error, :failed, _} = Target.classify_request(adapter, state, invalid)
      end
    end
  end

  test "IPMI advertises one arbitrary command as an effect and validates it before dispatch" do
    {:ok, state} =
      IPMI.build(%{}, %{"username" => "fixture", "password" => "fixture"})

    {:ok, state} = IPMI.bind_connection(state, %Target.Connection{endpoint: @endpoint})

    assert {:ok, %Target.Capabilities{observations: observations, effects: effects}} =
             IPMI.capabilities(state, %{})

    assert Enum.any?(effects, fn operation ->
             operation.capability == "request.ipmi.effect" and
               operation.operation == "command.execute"
           end)

    refute Enum.any?(observations, &(&1.capability == "request.ipmi.observe"))
    assert "request.ipmi.effect" in IPMI.access_method_profile().capabilities

    request = request(%{"netfn" => 6, "command" => 1, "data_hex" => ""})
    cancelled = %{cancelled?: fn -> true end}

    assert {:error, :cancelled, _} = IPMI.effect(state, request, cancelled)

    for parameters <- [
          %{"netfn" => 7, "command" => 1},
          %{"netfn" => 6, "command" => 256},
          %{"netfn" => 6, "command" => 1, "data_hex" => "F"},
          %{"netfn" => 6, "command" => 1, "data_hex" => String.duplicate("AA", 2049)},
          %{"netfn" => 6, "command" => 1, "unexpected" => true}
        ] do
      assert {:error, :failed, _} = IPMI.effect(state, request(parameters), cancelled)
    end

    assert {:error, :failed, _} =
             IPMI.observe(
               state,
               %Target.ObservationRequest{
                 provider_revision: 1,
                 target_id: "fixture",
                 target_revision: 1,
                 access_method_id: "fixture",
                 access_method_revision: 1,
                 connection: %Target.Connection{endpoint: @endpoint},
                 capability: "request.ipmi.observe",
                 operation: "command.observe",
                 authorization_digest: "fixture",
                 parameters: %{"netfn" => 6, "command" => 1}
               },
               cancelled
             )
  end

  defp request(parameters) do
    %Target.EffectRequest{
      provider_revision: 1,
      target_id: "fixture",
      target_revision: 1,
      access_method_id: "fixture",
      access_method_revision: 1,
      connection: %Target.Connection{endpoint: @endpoint},
      capability: "request.ipmi.effect",
      operation: "command.execute",
      authorization_digest: "fixture",
      operation_id: "fixture",
      idempotency_key: "fixture",
      parameters: parameters
    }
  end
end
