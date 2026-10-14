defmodule Skopos.Targets.Profiles.Linux.SSH do
  @moduledoc false
  @behaviour Skopos.Providers.Adapter
  @behaviour Skopos.Providers.Target
  alias Skopos.Providers.Target
  alias Skopos.Transports.SSH, as: Transport
  alias Skopos.Targets.Adapters.SSH, as: SSHMethod
  alias Skopos.Targets.ResourceScope

  @ssh_capabilities SSHMethod.access_method_profile().capabilities

  @identity {"observe.identity", "linux.identity.inspect"}
  @processes {"observe.processes", "linux.process.list"}
  @service {"observe.service", "linux.service.inspect"}
  @service_list {"observe.service", "linux.service.list"}
  @journal {"observe.journal", "linux.journal.read"}
  @restart {"effect.service", "linux.service.restart"}
  @unit_pattern ~r/^[A-Za-z0-9_.@:-]+\.service$/
  @digest_pattern ~r/^[a-f0-9]{64}$/
  @service_state_pattern ~r/^[a-z0-9_-]{1,64}$/
  @max_service_page 200
  @service_fields %{
    "Id" => "unit",
    "LoadState" => "load_state",
    "ActiveState" => "active_state",
    "SubState" => "sub_state",
    "UnitFileState" => "unit_file_state",
    "FragmentPath" => "fragment_path",
    "DropInPaths" => "drop_in_paths",
    "NeedDaemonReload" => "need_daemon_reload",
    "ExecMainPID" => "main_pid",
    "DefinitionSHA256" => "definition_sha256"
  }

  defmodule State do
    @moduledoc false
    @enforce_keys [:transport, :privilege]
    defstruct @enforce_keys
  end

  @impl Skopos.Providers.Adapter
  def type, do: "linux-ssh"

  @impl Skopos.Providers.Adapter
  def kind, do: :target

  @impl Skopos.Providers.Target
  def access_method_profile do
    %Target.AccessMethodProfile{
      method: "ssh",
      capabilities:
        Enum.uniq(
          Enum.map(
            [@identity, @processes, @service, @service_list, @journal, @restart],
            &elem(&1, 0)
          ) ++
            @ssh_capabilities
        )
    }
  end

  @impl Skopos.Providers.Target
  def resource_scope(operation, capability, selectors)
      when operation in ["linux.service.restart", "linux.service.inspect"] and
             capability in ["effect.service", "observe.service"] and is_map(selectors) do
    case selectors do
      %{"unit" => unit} when map_size(selectors) == 1 -> ResourceScope.service(unit)
      _other -> "target"
    end
  end

  def resource_scope(_operation, _capability, _selectors), do: "target"

  @impl Skopos.Providers.Adapter
  def build(configuration, credentials) when is_map(configuration) do
    {privilege, transport_configuration} = Map.pop(configuration, "privilege", "none")

    with true <- privilege in ["none", "sudo"],
         {:ok, transport} <- Transport.build(transport_configuration, credentials) do
      {:ok, %State{transport: transport, privilege: privilege}}
    else
      _error -> {:error, :invalid_configuration}
    end
  end

  def build(_configuration, _credentials), do: {:error, :invalid_configuration}

  @impl Skopos.Providers.Target
  def bind_connection(%State{transport: transport} = state, connection) do
    with {:ok, _transport} <- SSHMethod.bind_connection(transport, connection), do: {:ok, state}
  end

  @impl Skopos.Providers.Adapter
  def check(%State{transport: transport}, %{"endpoint" => endpoint}) do
    case Transport.check(transport, endpoint) do
      :ok -> :ok
      {:error, :authentication, message} -> {:error, :authentication, message}
      {:error, :host_key, message} -> {:error, :authentication, message}
      {:error, _category, message} -> {:error, :unreachable, message}
    end
  end

  def check(_state, _input),
    do: {:error, :invalid_configuration, "Linux SSH check requires an endpoint"}

  @impl Skopos.Providers.Target
  def capabilities(%State{} = state, invocation) do
    with {:ok, shared} <- SSHMethod.capabilities(state.transport, invocation),
         do: catalog(state.privilege, shared)
  end

  @impl Skopos.Providers.Target
  def observe(%State{} = state, %{capability: capability} = request, invocation)
      when capability in @ssh_capabilities,
      do: SSHMethod.observe(state.transport, request, invocation)

  @impl Skopos.Providers.Target
  def observe(%State{} = state, request, invocation) do
    with {:ok, command, decoder} <- observation_command(state.privilege, request),
         {:ok, result} <- execute(state, request, command, invocation),
         {:ok, facts} <- decode_observation(decoder, result) do
      {:ok,
       %Target.Observation{
         facts: facts,
         observed_at: DateTime.utc_now(),
         evidence: [evidence(result)]
       }}
    else
      {:error, category, message} -> read_error(category, message)
      {:error, _cause} = error -> error
    end
  end

  @impl Skopos.Providers.Target
  def classify_request(%State{} = state, %{capability: capability} = request)
      when capability in @ssh_capabilities,
      do: SSHMethod.classify_request(state.transport, request)

  def classify_request(%State{} = state, request) do
    case request.capability do
      "effect.service" ->
        classify_effect(restart_command(state.privilege, request))

      _other ->
        case observation_command(state.privilege, request) do
          {:ok, _command, _decoder} -> {:ok, :observation}
          {:error, _category, _message} -> {:error, :failed, "Linux request is invalid"}
        end
    end
  end

  defp classify_effect({:ok, _command}), do: {:ok, :effect}

  defp classify_effect({:error, _category, _message}),
    do: {:error, :failed, "Linux request is invalid"}

  @impl Skopos.Providers.Target
  def effect(%State{} = state, %{capability: capability} = request, invocation)
      when capability in @ssh_capabilities do
    with {:ok, :effect} <- SSHMethod.classify_request(state.transport, request) do
      if request.operation == "command.execute" do
        with {:ok, command} <- SSHMethod.effect_command(request, capability) do
          state
          |> execute_raw(request, privileged(state.privilege, command), invocation)
          |> effect_result()
        end
      else
        SSHMethod.effect(state.transport, request, invocation)
      end
    else
      _invalid -> {:error, :failed, "Linux SSH effect request is invalid"}
    end
  end

  def effect(%State{} = state, request, invocation) do
    with {:ok, command} <- restart_command(state.privilege, request),
         result <- execute_raw(state, request, command, invocation) do
      effect_result(result, true)
    else
      {:error, category, message} -> read_error(category, message)
    end
  end

  @impl Skopos.Providers.Target
  def verify(%State{} = state, %{capability: capability} = request, invocation)
      when capability in @ssh_capabilities,
      do: SSHMethod.verify(state.transport, request, invocation)

  def verify(%State{} = state, request, invocation) do
    with {:ok, command, :service} <- observation_command(state.privilege, request),
         {:ok, expected} <- verification_expected(request.expected),
         {:ok, result} <- execute(state, request, command, invocation),
         {:ok, facts} <- decode_observation(:service, result) do
      {:ok,
       %Target.Verification{
         status: expected_status(facts, expected),
         observed_at: DateTime.utc_now(),
         facts: facts,
         evidence: [evidence(result)]
       }}
    else
      {:error, category, message} -> read_error(category, message)
      {:error, _cause} = error -> error
      _error -> {:error, :failed, "Linux verification request is invalid"}
    end
  end

  defp execute(state, request, command, invocation) do
    case execute_raw(state, request, command, invocation) do
      {:ok, %Transport.Result{exit_status: 0} = result} ->
        {:ok, result}

      {:ok, %Transport.Result{exit_status: status}} ->
        {:error, :failed, "Linux observation exited with status #{status}"}

      {:error, category, message} ->
        {:error, category, message}

      {:error, _cause} = error ->
        error
    end
  end

  defp execute_raw(state, request, command, invocation) do
    Transport.exec(
      state.transport,
      request.connection.endpoint,
      command,
      invocation
    )
  end

  defp effect_result(result, definition_guard? \\ false)

  defp effect_result({:ok, %Transport.Result{exit_status: 0} = result}, _definition_guard?) do
    {:ok, %Target.EffectResult{status: :applied, details: evidence(result)}}
  end

  defp effect_result({:ok, %Transport.Result{exit_status: 65} = result}, true) do
    {:ok,
     %Target.EffectResult{
       status: :failed,
       details: Map.put(evidence(result), "category", "stale_definition")
     }}
  end

  defp effect_result({:ok, %Transport.Result{} = result}, _definition_guard?) do
    {:ok, %Target.EffectResult{status: :failed, details: evidence(result)}}
  end

  defp effect_result({:error, category, message}, _definition_guard?)
       when category in [
              :timeout_after_dispatch,
              :cancelled_after_dispatch,
              :disconnected_after_dispatch,
              :output_limit_after_dispatch
            ],
       do: {:ok, %Target.EffectResult{status: :unknown, details: %{"error" => message}}}

  defp effect_result({:error, :cancelled, message}, _definition_guard?),
    do: {:error, :cancelled, message}

  defp effect_result({:error, _category, message}, _definition_guard?),
    do: {:error, :failed, message}

  defp effect_result({:error, _cause} = error, _definition_guard?), do: error

  defp read_error(:cancelled, message), do: {:error, :cancelled, message}

  defp read_error(category, message) when category in [:timeout, :timeout_after_dispatch],
    do: {:error, :timeout, message}

  defp read_error(category, message)
       when category in [:unreachable, :disconnected, :disconnected_after_dispatch],
       do: {:error, :retryable, message}

  defp read_error(_category, message), do: {:error, :failed, message}

  defp evidence(result) do
    %{
      "stdout" => encode(result.stdout),
      "stderr" => encode(result.stderr),
      "exit_status" => result.exit_status
    }
  end

  defp encode(value) do
    if String.valid?(value),
      do: %{"encoding" => "utf-8", "value" => value},
      else: %{"encoding" => "base64", "value" => Base.encode64(value)}
  end

  defp catalog(privilege, shared) do
    {:ok,
     %Target.Capabilities{
       observations:
         shared.observations ++
           [
             operation(
               @identity,
               "Inspect fixed Linux kernel and machine identity",
               empty_schema(),
               identity_output_schema()
             ),
             operation(
               @processes,
               "List a bounded set of Linux processes",
               process_schema(),
               processes_output_schema()
             ),
             operation(
               @service_list,
               "Discover exact installed systemd service unit names by page. Use this before service inspection when a unit is unknown; monitoring job and instance names are not unit names. Then inspect the discovered unit to learn its live state.",
               service_list_schema(),
               service_list_output_schema()
             ),
             operation(
               @service,
               "Inspect a known installed systemd service unit and its definition. Requires an exact unit name; if only monitoring labels are known, discover units with linux.service.list first.",
               unit_schema(),
               service_output_schema(),
               service_verification_schema()
             ),
             operation(
               @journal,
               "Read bounded recent journal entries for one systemd service",
               journal_schema(),
               journal_output_schema()
             )
           ],
       effects:
         [
           %{
             operation(
               @restart,
               "Restart one systemd service using the exact definition_sha256 from a supplied " <>
                 "linux.service.inspect observation; inspect the service first when unavailable",
               restart_schema()
             )
             | evidence_requirements: [
                 %Target.EvidenceRequirement{
                   parameter: "expected_definition_sha256",
                   fact: "definition_sha256",
                   observation: "linux.service.inspect"
                 }
               ]
           }
         ] ++
           Enum.map(shared.effects, fn operation ->
             if operation.operation == "command.execute",
               do: describe_privilege(operation, privilege),
               else: operation
           end)
     }}
  end

  defp expected_status(_facts, expected) when expected == %{}, do: :unknown

  defp expected_status(facts, expected) when is_map(expected) do
    if Enum.all?(expected, fn {key, value} -> facts[key] == value end),
      do: :verified,
      else: :not_verified
  end

  defp observation_command(privilege, request) do
    case {request.capability, request.operation, request.selectors, request.parameters} do
      {capability, operation, selectors, parameters}
      when {capability, operation} == @identity and selectors == %{} and parameters == %{} ->
        {:ok, "printf 'Kernel='; uname -srm; printf 'MachineId='; cat /etc/machine-id", :identity}

      {capability, operation, selectors, %{"limit" => limit}}
      when {capability, operation} == @processes and selectors == %{} and
             is_integer(limit) and limit in 1..100 ->
        {:ok, "ps -eo pid=,ppid=,stat=,comm= --sort=-pcpu | head -n #{limit}", :processes}

      {capability, operation, %{"unit" => unit}, parameters}
      when {capability, operation} == @service and parameters == %{} ->
        if valid_unit?(unit),
          do: {:ok, service_command(unit), :service},
          else: invalid_request()

      {capability, operation, selectors, parameters}
      when {capability, operation} == @service_list and selectors == %{} ->
        case service_page(parameters) do
          {:ok, offset, limit} ->
            {:ok, service_list_command(offset, limit), {:service_list, offset, limit}}

          error ->
            error
        end

      {capability, operation, %{"unit" => unit}, %{"lines" => lines}}
      when {capability, operation} == @journal and is_integer(lines) and lines in 1..200 ->
        if valid_unit?(unit),
          do: {:ok, journal_command(privilege, unit, lines), {:journal, unit}},
          else: invalid_request()

      _request ->
        invalid_request()
    end
  end

  defp restart_command(privilege, request) do
    case {request.capability, request.operation, request.selectors, request.parameters} do
      {capability, operation, %{"unit" => unit}, %{"expected_definition_sha256" => expected}}
      when {capability, operation} == @restart ->
        if valid_unit?(unit) and is_binary(expected) and Regex.match?(@digest_pattern, expected),
          do: {:ok, restart_command(privilege, unit, expected)},
          else: invalid_request()

      _request ->
        invalid_request()
    end
  end

  defp service_command(unit) do
    quoted = shell_quote(unit)

    "definition=\"$(systemctl cat -- #{quoted})\" || exit $?; " <>
      "systemctl show --no-pager " <>
      "--property=Id,LoadState,ActiveState,SubState,UnitFileState,FragmentPath,DropInPaths,NeedDaemonReload,ExecMainPID " <>
      "-- #{quoted} || exit $?; " <>
      "printf 'DefinitionSHA256='; printf '%s' \"$definition\" | sha256sum | cut -d' ' -f1"
  end

  defp service_list_command(offset, limit) do
    first = offset + 1
    last = offset + limit + 1

    "units=\"$(systemctl list-unit-files --type=service --no-legend --no-pager --plain)\" || exit $?; " <>
      "printf '%s\\n' \"$units\" | sed -n '#{first},#{last}p'"
  end

  defp service_page(parameters) when is_map(parameters) do
    if Map.keys(parameters) -- ["offset", "limit"] == [] do
      offset = Map.get(parameters, "offset", 0)
      limit = Map.get(parameters, "limit", @max_service_page)

      if is_integer(offset) and offset in 0..10_000 and is_integer(limit) and
           limit in 1..@max_service_page,
         do: {:ok, offset, limit},
         else: invalid_request()
    else
      invalid_request()
    end
  end

  defp service_page(_parameters), do: invalid_request()

  defp journal_command(privilege, unit, lines) do
    command =
      "journalctl --unit=#{shell_quote(unit)} --lines=#{lines} --no-pager --output=short-iso"

    privileged(privilege, command)
  end

  defp restart_command(privilege, unit, expected) do
    quoted = shell_quote(unit)

    "definition=\"$(systemctl cat -- #{quoted})\" || exit $?; " <>
      "actual=\"$(printf '%s' \"$definition\" | sha256sum | cut -d' ' -f1)\"; " <>
      "if [ \"$actual\" != '#{expected}' ]; then printf 'service definition changed\\n' >&2; exit 65; fi; " <>
      privileged(privilege, "systemctl restart -- #{quoted}")
  end

  defp decode_observation(:identity, result) do
    facts = parse_pairs(result.stdout)

    case facts do
      %{"Kernel" => kernel, "MachineId" => machine_id}
      when byte_size(kernel) > 0 and byte_size(machine_id) > 0 ->
        {:ok, %{"kernel" => kernel, "machine_id" => machine_id}}

      _facts ->
        {:error, :failed, "Linux identity response is invalid"}
    end
  end

  defp decode_observation(:processes, result) do
    processes =
      result.stdout
      |> String.split("\n", trim: true)
      |> Enum.map(&String.split(&1, ~r/\s+/, parts: 4, trim: true))

    if Enum.all?(processes, &(length(&1) == 4)) do
      {:ok,
       %{
         "processes" =>
           Enum.map(processes, fn [pid, parent_pid, state, command] ->
             %{
               "pid" => integer(pid),
               "parent_pid" => integer(parent_pid),
               "state" => state,
               "command" => command
             }
           end)
       }}
    else
      {:error, :failed, "Linux process response is invalid"}
    end
  end

  defp decode_observation(:service, result) do
    facts =
      result.stdout
      |> parse_pairs()
      |> Map.new(fn {key, value} -> {Map.get(@service_fields, key, key), value} end)

    if Enum.all?(
         ~w(unit load_state active_state sub_state definition_sha256),
         &nonempty?(facts[&1])
       ) and
         Regex.match?(@digest_pattern, facts["definition_sha256"]) do
      {:ok, facts}
    else
      {:error, :failed, "Linux service response is invalid"}
    end
  end

  defp decode_observation({:service_list, offset, limit}, result) do
    lines = String.split(result.stdout, "\n", trim: true)

    if length(lines) > limit + 1 do
      {:error, :failed, "Linux service list exceeded the requested page bound"}
    else
      lines
      |> Enum.take(limit)
      |> Enum.reduce_while({:ok, []}, fn line, {:ok, services} ->
        case String.split(line, ~r/\s+/, trim: true) do
          [unit, state | _rest]
          when is_binary(unit) and is_binary(state) ->
            if valid_unit?(unit) and Regex.match?(@service_state_pattern, state),
              do: {:cont, {:ok, [%{"unit" => unit, "unit_file_state" => state} | services]}},
              else: {:halt, {:error, :failed, "Linux service list response is invalid"}}

          _line ->
            {:halt, {:error, :failed, "Linux service list response is invalid"}}
        end
      end)
      |> case do
        {:ok, services} ->
          services = Enum.reverse(services)

          {:ok,
           %{
             "services" => services,
             "offset" => offset,
             "next_offset" => offset + length(services),
             "has_more" => length(lines) > limit
           }}

        error ->
          error
      end
    end
  end

  defp decode_observation({:journal, unit}, result) do
    {:ok, %{"unit" => unit, "entries" => String.split(result.stdout, "\n", trim: true)}}
  end

  defp verification_expected(expected) when is_map(expected) do
    if expected == %{"active_state" => "active"},
      do: {:ok, expected},
      else: {:error, :failed, "Linux verification expectation is invalid"}
  end

  defp verification_expected(_expected),
    do: {:error, :failed, "Linux verification expectation is invalid"}

  defp operation(
         {capability, operation},
         description,
         schema,
         output_schema \\ nil,
         verification_schema \\ nil
       ) do
    %Target.Operation{
      capability: capability,
      operation: operation,
      description: description,
      input_schema: schema,
      output_schema: output_schema,
      verification_schema: verification_schema
    }
  end

  defp identity_output_schema do
    facts_schema(%{
      "kernel" => fact_string(1_024, 1),
      "machine_id" => fact_string(255, 1)
    })
  end

  defp processes_output_schema do
    facts_schema(%{
      "processes" => %{
        "type" => "array",
        "maxItems" => 100,
        "items" =>
          facts_schema(%{
            "pid" => %{"type" => "integer"},
            "parent_pid" => %{"type" => "integer"},
            "state" => fact_string(64, 1),
            "command" => fact_string(1_024, 1)
          })
      }
    })
  end

  defp service_output_schema do
    @service_fields
    |> Map.values()
    |> Map.new(&{&1, fact_string(1_024)})
    |> facts_schema()
  end

  defp service_list_output_schema do
    facts_schema(%{
      "services" => %{
        "type" => "array",
        "maxItems" => @max_service_page,
        "items" =>
          object_schema(
            %{
              "unit" => unit_property(),
              "unit_file_state" => fact_string(64, 1)
            },
            ["unit", "unit_file_state"]
          )
      },
      "offset" => %{"type" => "integer", "minimum" => 0},
      "next_offset" => %{"type" => "integer", "minimum" => 0},
      "has_more" => %{"type" => "boolean"}
    })
  end

  defp service_verification_schema do
    %{
      "type" => "object",
      "properties" => %{
        "active_state" => %{
          "type" => "string",
          "enum" => ["active"],
          "description" => "The canonical successful postcondition for linux.service.restart"
        }
      },
      "required" => ["active_state"],
      "additionalProperties" => false
    }
  end

  defp journal_output_schema do
    facts_schema(%{
      "unit" => fact_string(255, 1),
      "entries" => %{
        "type" => "array",
        "maxItems" => 200,
        "items" => fact_string(8_192, 1)
      }
    })
  end

  defp facts_schema(properties),
    do: %{
      "type" => "object",
      "properties" => properties,
      "additionalProperties" => false
    }

  defp fact_string(maximum, minimum \\ 0),
    do: %{"type" => "string", "minLength" => minimum, "maxLength" => maximum}

  defp empty_schema, do: request_schema(%{}, [], %{}, [])

  defp process_schema do
    request_schema(
      %{},
      [],
      %{"limit" => %{"type" => "integer", "minimum" => 1, "maximum" => 100}},
      ["limit"]
    )
  end

  defp unit_schema do
    request_schema(%{"unit" => unit_property()}, ["unit"], %{}, [])
  end

  defp service_list_schema do
    request_schema(
      %{},
      [],
      %{
        "offset" => %{"type" => "integer", "minimum" => 0, "maximum" => 10_000},
        "limit" => %{"type" => "integer", "minimum" => 1, "maximum" => @max_service_page}
      },
      []
    )
  end

  defp journal_schema do
    request_schema(
      %{"unit" => unit_property()},
      ["unit"],
      %{"lines" => %{"type" => "integer", "minimum" => 1, "maximum" => 200}},
      ["lines"]
    )
  end

  defp restart_schema do
    request_schema(
      %{"unit" => unit_property()},
      ["unit"],
      %{
        "expected_definition_sha256" => %{
          "type" => "string",
          "pattern" => "^[a-f0-9]{64}$",
          "description" =>
            "Copy the exact definition_sha256 from cited linux.service.inspect observation " <>
              "Evidence; never infer or invent this value"
        }
      },
      ["expected_definition_sha256"]
    )
  end

  defp request_schema(
         selector_properties,
         selector_required,
         parameter_properties,
         parameter_required
       ) do
    %{
      "type" => "object",
      "properties" => %{
        "selectors" => object_schema(selector_properties, selector_required),
        "parameters" => object_schema(parameter_properties, parameter_required)
      },
      "required" => ["selectors", "parameters"],
      "additionalProperties" => false
    }
  end

  defp object_schema(properties, required) do
    %{
      "type" => "object",
      "properties" => properties,
      "required" => required,
      "additionalProperties" => false
    }
  end

  defp unit_property do
    %{
      "type" => "string",
      "minLength" => 9,
      "maxLength" => 255,
      "pattern" => "^[A-Za-z0-9_.@:-]+\\.service$"
    }
  end

  defp parse_pairs(value) do
    value
    |> String.split("\n", trim: true)
    |> Map.new(fn line ->
      case String.split(line, "=", parts: 2) do
        [key, item] -> {key, String.trim(item)}
        [key] -> {key, ""}
      end
    end)
  end

  defp integer(value) do
    case Integer.parse(value) do
      {parsed, ""} -> parsed
      _error -> value
    end
  end

  defp describe_privilege(operation, "sudo") do
    %{
      operation
      | description:
          operation.description <>
            "; the Access Method runs the entire script in a configured non-interactive sudo shell, so do not add sudo"
    }
  end

  defp describe_privilege(operation, "none"), do: operation

  defp privileged("sudo", command), do: "sudo -n -- sh -c " <> shell_quote(command)
  defp privileged("none", command), do: command

  defp valid_unit?(value),
    do: is_binary(value) and byte_size(value) <= 255 and Regex.match?(@unit_pattern, value)

  defp shell_quote(value), do: "'" <> String.replace(value, "'", "'\"'\"'") <> "'"
  defp nonempty?(value), do: is_binary(value) and byte_size(value) > 0

  defp invalid_request, do: {:error, :failed, "Linux SSH request is invalid"}
end
