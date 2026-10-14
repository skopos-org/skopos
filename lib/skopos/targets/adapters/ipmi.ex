defmodule Skopos.Targets.Adapters.IPMI do
  @moduledoc false

  @behaviour Skopos.Providers.Adapter
  @behaviour Skopos.Providers.Target

  alias Skopos.Providers.Target
  alias Skopos.Targets.PowerControl
  alias Skopos.Transports.IPMI

  @max_data_bytes 2048
  # Hex doubles retained output; leave room for the receipt within the shared 64 KiB result.
  @max_console_output_bytes 30_000
  @method_effect "request.ipmi.effect"
  @context_error_classes [
    Ash.Error.Unknown,
    Ash.Error.Invalid,
    Ash.Error.Forbidden,
    Ash.Error.Framework
  ]

  defmodule State do
    @moduledoc false
    @enforce_keys [:user, :password, :timeout, :privilege, :cipher]
    @derive {Inspect, except: [:password]}
    defstruct @enforce_keys ++ [:endpoint, :host, :port]
  end

  @impl Skopos.Providers.Adapter
  def type, do: "ipmi"

  @impl Skopos.Providers.Adapter
  def kind, do: :target

  @impl Skopos.Providers.Target
  def access_method_profile do
    %Target.AccessMethodProfile{
      method: "ipmi",
      capabilities: [@method_effect | Target.capability_names(PowerControl.capabilities())]
    }
  end

  @impl Skopos.Providers.Adapter
  def build(configuration, credentials) when is_map(configuration) and is_map(credentials) do
    with true <-
           Enum.all?(
             Map.keys(configuration),
             &(&1 in ~w(timeout_ms privilege_level cipher_suite))
           ),
         true <- Enum.sort(Map.keys(credentials)) == ["password", "username"],
         {:ok, user} <- secret(credentials["username"], 16),
         {:ok, password} <- secret(credentials["password"], 20),
         privilege when is_integer(privilege) and privilege in 1..5 <-
           Map.get(configuration, "privilege_level", 4),
         cipher when cipher == "auto" or (is_integer(cipher) and cipher in 0..17) <-
           Map.get(configuration, "cipher_suite", "auto"),
         timeout when is_integer(timeout) and timeout in 100..30_000 <-
           Map.get(configuration, "timeout_ms", 3_000) do
      {:ok,
       %State{
         user: user,
         password: password,
         timeout: timeout,
         privilege: privilege,
         cipher: if(cipher == "auto", do: 255, else: cipher)
       }}
    else
      _ -> {:error, :invalid_configuration}
    end
  end

  def build(_configuration, _credentials), do: {:error, :invalid_configuration}

  @impl Skopos.Providers.Adapter
  def check(%State{} = state, %{"endpoint" => endpoint}) do
    with {:ok, state} <- bind_connection(state, %Target.Connection{endpoint: endpoint}),
         {:ok, 0, device} <- command(state, 0x06, 0x01, [], %{}),
         true <- length(device) >= 11 do
      :ok
    else
      {:error, :authentication, message} ->
        {:error, :authentication, message}

      {:error, category, message} when category in [:local_capacity, :native_unavailable] ->
        {:error, :provider_failure, message}

      _ ->
        {:error, :unreachable, "IPMI BMC check failed"}
    end
  end

  def check(_state, _input),
    do: {:error, :invalid_configuration, "IPMI check requires a Method endpoint"}

  @impl Skopos.Providers.Target
  def bind_connection(%State{} = state, %Target.Connection{endpoint: value}) do
    case endpoint(value) do
      {:ok, endpoint, host, port} -> {:ok, %{state | endpoint: endpoint, host: host, port: port}}
      _ -> {:error, :failed, "IPMI Method endpoint is invalid"}
    end
  end

  @impl Skopos.Providers.Target
  def capabilities(state, invocation) do
    with :ok <- not_cancelled(invocation),
         {:ok, power} <- power_capabilities(state, invocation) do
      effects = Enum.reject(power.effects, &(&1.operation == "bmc.power.cycle"))

      {:ok,
       %Target.Capabilities{
         observations: power.observations,
         effects: effects ++ [method_effect_operation(), console_operation()]
       }}
    end
  end

  defp power_capabilities(state, invocation) do
    case read_power(state, invocation) do
      {:ok, _power} ->
        {:ok, PowerControl.capabilities()}

      {:error, category, message}
      when category in [:local_capacity, :native_unavailable, :cancelled] ->
        read_error(category, message)

      {:error, _cause} = error ->
        error

      _ ->
        {:ok, %Target.Capabilities{observations: [], effects: []}}
    end
  end

  @impl Skopos.Providers.Target
  def classify_request(%State{} = state, request) do
    case request.capability do
      @method_effect ->
        classify_ipmi(method_request(state, request), :effect)

      "observe.power" ->
        if PowerControl.inspect_request?(request) and
             request.connection.endpoint == state.endpoint,
           do: {:ok, :observation},
           else: {:error, :failed, "IPMI power observation is invalid"}

      "effect.power" ->
        with true <- request.operation != "bmc.power.cycle",
             true <- request.connection.endpoint == state.endpoint,
             {:ok, _intent} <- PowerControl.effect_request(request) do
          {:ok, :effect}
        else
          _ -> {:error, :failed, "IPMI power effect is invalid"}
        end

      _other ->
        {:error, :failed, "IPMI request is invalid"}
    end
  end

  defp classify_ipmi({:ok, _command, _include_response}, kind), do: {:ok, kind}
  defp classify_ipmi(_invalid, _kind), do: {:error, :failed, "IPMI request is invalid"}

  @impl Skopos.Providers.Target
  def observe(%State{} = state, request, invocation) do
    with true <- PowerControl.inspect_request?(request),
         true <- request.connection.endpoint == state.endpoint,
         :ok <- not_cancelled(invocation),
         {:ok, power} <- read_power(state, invocation) do
      {:ok, PowerControl.observation(power, state.endpoint, "ipmi")}
    else
      false -> {:error, :failed, "IPMI observation request is invalid"}
      {:error, category, message} -> read_error(category, message)
      {:error, _cause} = error -> error
    end
  end

  @impl Skopos.Providers.Target
  def effect(%State{}, %{operation: "bmc.power.cycle"}, _invocation),
    do: {:error, :failed, "IPMI power cycle support cannot be verified for this BMC"}

  def effect(%State{} = state, %{capability: @method_effect} = request, invocation),
    do: method_effect(state, request, invocation)

  def effect(%State{} = state, request, invocation) do
    with true <- request.connection.endpoint == state.endpoint,
         {:ok, intent} <- PowerControl.effect_request(request),
         :ok <- not_cancelled(invocation),
         {:ok, observed} <- read_power(state, invocation),
         :ok <- PowerControl.expected_state(intent.expected, observed),
         :ok <- not_cancelled(invocation) do
      data =
        case intent.operation do
          "bmc.power.off" -> [0]
          "bmc.power.on" -> [1]
          "bmc.power.reset" -> [3]
        end

      case command(state, 0x00, 0x02, data, invocation) do
        {:ok, 0, _response} ->
          {:ok,
           %Target.EffectResult{
             status: :applied,
             reference: intent.operation,
             details: %{"command" => intent.operation, "pre_power_state" => observed}
           }}

        {:ok, _completion, _response} ->
          {:error, :failed, "IPMI BMC rejected chassis control"}

        {:error, :outcome_unknown, _message} ->
          unknown_effect(intent.operation, "IPMI chassis control response was lost")

        {:error, :cancelled, _message} = error ->
          error

        {:error, category, message} when category in [:local_capacity, :native_unavailable] ->
          local_failure(intent.operation, category, message)

        {:error, _category, message} ->
          {:error, :failed, message}

        {:error, %Target.BeforeSendError{}} = error ->
          error

        {:error, %type{}} = error
        when type in @context_error_classes ->
          error
      end
    else
      false ->
        {:error, :failed, "IPMI endpoint does not match checked Provider"}

      {:error, :cancelled, _message} = error ->
        error

      {:error, category, message} when category in [:local_capacity, :native_unavailable] ->
        local_failure(request.operation, category, message)

      {:error, _category, message} ->
        {:error, :failed, message}

      {:error, _cause} = error ->
        error
    end
  end

  @impl Skopos.Providers.Target
  def verify(%State{} = state, request, invocation) do
    with true <- request.connection.endpoint == state.endpoint,
         true <- PowerControl.inspect_request?(request),
         :ok <- not_cancelled(invocation),
         {:ok, power} <- read_power(state, invocation) do
      verification = PowerControl.verification(power, state.endpoint, "ipmi", request.expected)

      verification =
        if request.reference in ["bmc.power.cycle", "bmc.power.reset"],
          do: %{verification | status: :unknown},
          else: verification

      {:ok, verification}
    else
      false -> {:error, :failed, "IPMI verification request is invalid"}
      {:error, category, message} -> read_error(category, message)
      {:error, _cause} = error -> error
    end
  end

  defp method_effect(state, %{operation: "console.exchange"} = request, invocation) do
    with {:ok, {:sol, exchange}, include_response?} <- method_request(state, request) do
      console_effect(state, request, exchange, include_response?, invocation)
    end
  end

  defp method_effect(state, request, invocation) do
    with {:ok, command, include_response?} <- method_request(state, request),
         :ok <- not_cancelled(invocation) do
      case command(state, command, invocation) do
        {:ok, completion, response} ->
          details =
            command
            |> Map.delete(:data)
            |> Map.new(fn {key, value} -> {Atom.to_string(key), value} end)
            |> Map.put("completion_code", completion)

          details =
            if include_response? do
              maybe_response(details, response)
            else
              Map.put(details, "response_redacted", true)
            end

          {:ok,
           %Target.EffectResult{
             status: if(completion == 0, do: :applied, else: :failed),
             reference: request.operation,
             details: details
           }}

        {:error, :cancelled, _message} = error ->
          error

        {:error, :outcome_unknown, _message} ->
          unknown_effect(request.operation, "IPMI command response was lost after dispatch")

        {:error, %Target.BeforeSendError{}} = error ->
          error

        {:error, %type{}} = error
        when type in @context_error_classes ->
          error

        {:error, category, message} when category in [:local_capacity, :native_unavailable] ->
          local_failure(request.operation, category, message)

        {:error, _category, message} ->
          {:error, :failed, message}
      end
    else
      {:error, :cancelled, _message} = error -> error
      {:error, _category, message} -> {:error, :failed, message}
      {:error, _cause} = error -> error
    end
  end

  defp method_effect_operation do
    %Target.Operation{
      capability: @method_effect,
      operation: "command.execute",
      description:
        "Send one exact IPMI command after authority review; opaque responses are redacted unless explicitly requested",
      input_schema: %{
        "type" => "object",
        "properties" => %{
          "selectors" => %{"type" => "object", "additionalProperties" => false},
          "parameters" => %{
            "type" => "object",
            "properties" => %{
              "netfn" => %{"type" => "integer", "minimum" => 0, "maximum" => 62},
              "command" => %{"type" => "integer", "minimum" => 0, "maximum" => 255},
              "lun" => %{"type" => "integer", "minimum" => 0, "maximum" => 3},
              "target_address" => %{"type" => "integer", "minimum" => 0, "maximum" => 255},
              "target_channel" => %{"type" => "integer", "minimum" => 0, "maximum" => 15},
              "transit_address" => %{"type" => "integer", "minimum" => 0, "maximum" => 255},
              "transit_channel" => %{"type" => "integer", "minimum" => 0, "maximum" => 15},
              "data_hex" => %{"type" => "string", "maxLength" => @max_data_bytes * 2},
              "include_response" => %{"type" => "boolean"}
            },
            "required" => ["netfn", "command"],
            "additionalProperties" => false
          }
        },
        "required" => ["selectors", "parameters"],
        "additionalProperties" => false
      }
    }
  end

  defp method_request(state, %{operation: "console.exchange"} = request) do
    parameters = request.parameters

    with true <- request.connection.endpoint == state.endpoint and request.selectors == %{},
         true <-
           Enum.all?(
             Map.keys(parameters),
             &(&1 in ~w(input_hex instance activation_flags generate_break read_ms max_output_bytes include_response))
           ),
         {:ok, input} <-
           request_data(
             Map.new(Map.take(parameters, ["input_hex"]), fn {_, value} -> {"data_hex", value} end)
           ),
         instance when is_integer(instance) and instance in 1..15 <-
           Map.get(parameters, "instance", 1),
         flags when is_integer(flags) and flags in 0..255 <-
           Map.get(parameters, "activation_flags", 0xC6),
         break? when is_boolean(break?) <- Map.get(parameters, "generate_break", false),
         read_ms when is_integer(read_ms) and read_ms >= 0 and read_ms < state.timeout <-
           Map.get(parameters, "read_ms", 0),
         limit when is_integer(limit) and limit in 1..@max_console_output_bytes <-
           Map.get(parameters, "max_output_bytes", @max_console_output_bytes),
         include? when is_boolean(include?) <- Map.get(parameters, "include_response", false) do
      {:ok,
       {:sol,
        %{
          input: input,
          instance: instance,
          flags: flags,
          generate_break: break?,
          read_ms: read_ms,
          max_output_bytes: limit
        }}, include?}
    else
      _ -> {:error, :failed, "IPMI SOL exchange is invalid"}
    end
  end

  defp method_request(state, request) do
    parameters = request.parameters

    with true <- request.operation == "command.execute",
         true <- request.connection.endpoint == state.endpoint,
         true <- request.selectors == %{},
         %{"netfn" => netfn, "command" => opcode} <- parameters,
         true <-
           Enum.all?(
             Map.keys(parameters),
             &(&1 in ~w(netfn command data_hex include_response lun target_address target_channel transit_address transit_channel))
           ),
         true <- is_integer(netfn) and netfn in 0..62 and rem(netfn, 2) == 0,
         true <- is_integer(opcode) and opcode in 0..255,
         include_response? when is_boolean(include_response?) <-
           Map.get(parameters, "include_response", false),
         {:ok, data} <- request_data(Map.take(parameters, ["data_hex"])),
         {:ok, routing} <- routing(parameters) do
      {:ok, Map.merge(routing, %{netfn: netfn, command: opcode, data: data}), include_response?}
    else
      _ -> {:error, :failed, "IPMI command request is invalid"}
    end
  end

  defp console_operation do
    %Target.Operation{
      capability: @method_effect,
      operation: "console.exchange",
      description:
        "Exchange exact SOL console bytes when the BMC supports SOL, then close the session",
      input_schema: %{
        "type" => "object",
        "properties" => %{
          "selectors" => %{"type" => "object", "additionalProperties" => false},
          "parameters" => %{
            "type" => "object",
            "properties" => %{
              "input_hex" => %{"type" => "string", "maxLength" => @max_data_bytes * 2},
              "instance" => %{"type" => "integer", "minimum" => 1, "maximum" => 15},
              "activation_flags" => %{"type" => "integer", "minimum" => 0, "maximum" => 255},
              "generate_break" => %{"type" => "boolean"},
              "read_ms" => %{"type" => "integer", "minimum" => 0, "maximum" => 29_999},
              "max_output_bytes" => %{
                "type" => "integer",
                "minimum" => 1,
                "maximum" => @max_console_output_bytes
              },
              "include_response" => %{"type" => "boolean"}
            },
            "additionalProperties" => false
          }
        },
        "required" => ["selectors", "parameters"],
        "additionalProperties" => false
      }
    }
  end

  defp console_effect(state, request, exchange, include_response?, invocation) do
    started = System.monotonic_time(:millisecond)

    with :ok <- not_cancelled(invocation),
         {:ok, address} <- resolve_address(state.host, state.port, state.timeout),
         remaining = state.timeout - (System.monotonic_time(:millisecond) - started),
         true <- remaining > 0 do
      case IPMI.exchange_console(
             address,
             session(state),
             remaining,
             exchange,
             invocation
           ) do
        {:ok, result} ->
          {output, details} = Map.pop(result, :output)
          details = Map.new(details, fn {key, value} -> {Atom.to_string(key), value} end)
          {status, details} = Map.pop(details, "status")

          details =
            if include_response? do
              bytes =
                output
                |> :erlang.list_to_binary()
                |> Skopos.Providers.Redactor.message(%{"password" => state.password})

              size = min(byte_size(bytes), exchange.max_output_bytes)

              details
              |> Map.put("output_hex", Base.encode16(binary_part(bytes, 0, size), case: :lower))
              |> Map.update!("output_truncated", &(&1 or byte_size(bytes) > size))
            else
              Map.put(details, "response_redacted", true)
            end

          {:ok,
           %Target.EffectResult{status: status, reference: request.operation, details: details}}

        {:error, "cancelled"} ->
          {:error, :cancelled, "IPMI SOL exchange was cancelled before dispatch"}

        {:error, "authentication"} ->
          {:error, :failed, "IPMI authentication failed"}

        {:error, %Target.BeforeSendError{}} = error ->
          error

        {:error, %type{}} = error
        when type in @context_error_classes ->
          error

        {:error, category} when category in ["local_capacity", "native_unavailable"] ->
          {:error, kind, message} = local_error(category)
          local_failure(request.operation, kind, message)

        _ ->
          {:error, :failed, "IPMI SOL connection failed before dispatch"}
      end
    else
      false -> {:error, :failed, "IPMI SOL connection deadline expired"}
      {:error, _, _} = error -> error
      {:error, _cause} = error -> error
    end
  end

  defp routing(parameters) do
    command = %{
      lun: Map.get(parameters, "lun", 0),
      target_address: Map.get(parameters, "target_address", 0x20),
      target_channel: Map.get(parameters, "target_channel", 0),
      transit_address: Map.get(parameters, "transit_address", 0),
      transit_channel: Map.get(parameters, "transit_channel", 0)
    }

    if Enum.all?(command, fn {key, value} ->
         max =
           case key do
             :lun -> 3
             key when key in [:target_channel, :transit_channel] -> 15
             _address -> 255
           end

         is_integer(value) and value in 0..max
       end),
       do: {:ok, command},
       else: {:error, :invalid_routing}
  end

  defp unknown_effect(reference, reason) do
    {:ok,
     %Target.EffectResult{
       status: :unknown,
       reference: reference,
       details: %{"reason" => reason}
     }}
  end

  defp local_error("local_capacity"),
    do: {:error, :local_capacity, "IPMI local execution wait expired before dispatch"}

  defp local_error("native_unavailable"),
    do:
      {:error, :native_unavailable, "IPMI local native transport is unavailable before dispatch"}

  defp local_failure(reference, category, message) do
    {:ok,
     %Target.EffectResult{
       status: :failed,
       reference: reference,
       details: %{
         "provider_category" => Atom.to_string(category),
         "dispatched" => false,
         "reason" => message
       }
     }}
  end

  defp request_data(%{} = parameters) when map_size(parameters) == 0, do: {:ok, []}

  defp request_data(%{"data_hex" => hex} = parameters)
       when map_size(parameters) == 1 and is_binary(hex) and
              byte_size(hex) <= @max_data_bytes * 2 do
    case Base.decode16(hex, case: :mixed) do
      {:ok, data} -> {:ok, :binary.bin_to_list(data)}
      :error -> {:error, :invalid_data}
    end
  end

  defp request_data(_parameters), do: {:error, :invalid_data}

  defp maybe_response(details, response),
    do:
      Map.put(
        details,
        "data_hex",
        response |> :erlang.list_to_binary() |> Base.encode16(case: :lower)
      )

  defp read_power(state, invocation) do
    case command(state, 0x00, 0x01, [], invocation) do
      {:ok, 0, [status | _rest]} -> {:ok, if(Bitwise.band(status, 1) == 1, do: "on", else: "off")}
      {:ok, 0, _response} -> {:error, :failed, "IPMI BMC returned no power state"}
      {:ok, _completion, _response} -> {:error, :failed, "IPMI BMC rejected chassis status"}
      {:error, _category, _message} = error -> error
      {:error, _cause} = error -> error
    end
  end

  defp command(state, netfn, opcode, data, invocation) do
    {:ok, routing} = routing(%{})
    command(state, Map.merge(routing, %{netfn: netfn, command: opcode, data: data}), invocation)
  end

  defp command(state, request, invocation) do
    started = System.monotonic_time(:millisecond)

    with :ok <- not_cancelled(invocation),
         {:ok, address} <- resolve_address(state.host, state.port, state.timeout),
         remaining = state.timeout - (System.monotonic_time(:millisecond) - started),
         true <- remaining > 0 do
      method_command(state, address, request, remaining, invocation)
    else
      false -> {:error, :unreachable, "IPMI connection deadline expired"}
      {:error, _, _} = error -> error
      {:error, _cause} = error -> error
    end
  end

  defp method_command(state, address, request, timeout, invocation) do
    case IPMI.exchange_command(
           address,
           session(state),
           timeout,
           request,
           invocation
         ) do
      {:ok, {completion, response}}
      when is_integer(completion) and completion in 0..255 and is_list(response) and
             length(response) <= 4096 ->
        {:ok, completion, response}

      {:error, "authentication"} ->
        {:error, :authentication, "IPMI authentication failed"}

      {:error, "cancelled"} ->
        {:error, :cancelled, "IPMI command was cancelled before dispatch"}

      {:error, "outcome_unknown"} ->
        {:error, :outcome_unknown, "IPMI command response was lost"}

      {:error, "unsupported"} ->
        {:error, :failed, "IPMI BMC transport is unsupported"}

      {:error, "invalid_request"} ->
        {:error, :failed, "IPMI command is invalid"}

      {:error, category} when category in ["local_capacity", "native_unavailable"] ->
        local_error(category)

      {:error, %Target.BeforeSendError{}} = error ->
        error

      {:error, %type{}} = error
      when type in @context_error_classes ->
        error

      _ ->
        {:error, :unreachable, "IPMI BMC is unreachable"}
    end
  end

  defp resolve_address(host, port, timeout) do
    case :inet.parse_address(String.to_charlist(host)) do
      {:ok, ip} ->
        {:ok, socket_address(ip, port)}

      {:error, _reason} ->
        started = System.monotonic_time(:millisecond)

        case :inet.getaddr(String.to_charlist(host), :inet, timeout) do
          {:ok, ip} ->
            {:ok, socket_address(ip, port)}

          {:error, _reason} ->
            remaining = timeout - (System.monotonic_time(:millisecond) - started)
            resolve_ipv6(host, port, remaining)
        end
    end
  end

  defp resolve_ipv6(_host, _port, timeout) when timeout <= 0,
    do: {:error, :unreachable, "IPMI BMC address could not be resolved"}

  defp resolve_ipv6(host, port, timeout) do
    case :inet.getaddr(String.to_charlist(host), :inet6, timeout) do
      {:ok, ip} -> {:ok, socket_address(ip, port)}
      {:error, _reason} -> {:error, :unreachable, "IPMI BMC address could not be resolved"}
    end
  end

  defp socket_address(ip, port) when tuple_size(ip) == 4,
    do: "#{:inet.ntoa(ip)}:#{port}"

  defp socket_address(ip, port) when tuple_size(ip) == 8,
    do: "[#{:inet.ntoa(ip)}]:#{port}"

  defp endpoint(value) when is_binary(value) and byte_size(value) <= 255 do
    case URI.parse(value) do
      %URI{
        scheme: "ipmi",
        host: host,
        port: port,
        path: path,
        userinfo: nil,
        query: nil,
        fragment: nil
      }
      when is_binary(host) and host != "" and path in [nil, ""] and
             (is_nil(port) or port in 1..65_535) ->
        {:ok, value, host, port || 623}

      _ ->
        {:error, :invalid_endpoint}
    end
  end

  defp endpoint(_value), do: {:error, :invalid_endpoint}

  defp session(state),
    do: %{
      username: state.user,
      password: state.password,
      privilege_level: state.privilege,
      cipher_suite: state.cipher
    }

  defp secret(value, limit)
       when is_binary(value) and byte_size(value) >= 1 and byte_size(value) <= limit do
    if String.contains?(value, <<0>>), do: {:error, :invalid_secret}, else: {:ok, value}
  end

  defp secret(_value, _limit), do: {:error, :invalid_secret}

  defp not_cancelled(invocation) do
    callback = Map.get(invocation, :before_send?, Map.get(invocation, :cancelled?))

    if is_function(callback, 0) and callback.(),
      do: {:error, :cancelled, "IPMI request was cancelled"},
      else: :ok
  rescue
    cause -> {:error, Target.BeforeSendError.exception(cause: cause)}
  catch
    kind, reason -> {:error, Target.BeforeSendError.exception(cause: {kind, reason})}
  end

  defp read_error(:unreachable, message), do: {:error, :retryable, message}
  defp read_error(:local_capacity, message), do: {:error, :retryable, message}
  defp read_error(:native_unavailable, message), do: {:error, :failed, message}
  defp read_error(:outcome_unknown, message), do: {:error, :timeout, message}
  defp read_error(:cancelled, message), do: {:error, :cancelled, message}
  defp read_error(_category, message), do: {:error, :failed, message}
end
