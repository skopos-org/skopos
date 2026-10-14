defmodule Skopos.Targets.Profiles.IOSXE.SSH do
  @moduledoc false

  @behaviour Skopos.Providers.Adapter
  @behaviour Skopos.Providers.Target

  alias Skopos.Providers.Target
  alias Skopos.Targets.Profiles.IOSXE
  alias Skopos.Transports.SSH, as: Transport
  alias Skopos.Targets.Adapters.SSH, as: SSHMethod

  @method_observation "request.cli.observe"
  @method_effect "request.cli.effect"
  @ssh_capabilities SSHMethod.access_method_profile().capabilities

  @impl Skopos.Providers.Adapter
  def type, do: "ios-xe-ssh"

  @impl Skopos.Providers.Adapter
  def kind, do: :target

  @impl Skopos.Providers.Target
  def access_method_profile do
    profile = IOSXE.access_method_profile("ssh_cli", @method_observation, @method_effect)
    %{profile | capabilities: Enum.uniq(profile.capabilities ++ @ssh_capabilities)}
  end

  @impl Skopos.Providers.Adapter
  def build(configuration, credentials), do: Transport.build(configuration, credentials)

  @impl Skopos.Providers.Adapter
  def check(%Transport.Config{} = state, %{"endpoint" => endpoint}) do
    case Transport.check(state, endpoint) do
      :ok -> :ok
      {:error, :authentication, message} -> {:error, :authentication, message}
      {:error, :host_key, message} -> {:error, :authentication, message}
      {:error, _category, message} -> {:error, :unreachable, message}
    end
  end

  def check(_state, _input),
    do: {:error, :invalid_configuration, "IOS XE SSH check requires an endpoint"}

  @impl Skopos.Providers.Target
  defdelegate bind_connection(state, connection), to: Skopos.Targets.Adapters.SSH

  @impl Skopos.Providers.Target
  def capabilities(state, invocation) do
    capabilities = IOSXE.capabilities()
    {:ok, shared} = SSHMethod.capabilities(state, invocation)

    {:ok,
     %{
       capabilities
       | observations: capabilities.observations ++ [method_observation()] ++ shared.observations,
         effects: capabilities.effects ++ [method_effect()] ++ shared.effects
     }}
  end

  @impl Skopos.Providers.Target
  def observe(state, %{capability: capability} = request, invocation)
      when capability in @ssh_capabilities,
      do: SSHMethod.observe(state, request, invocation)

  def observe(
        %Transport.Config{} = state,
        %{capability: @method_observation} = request,
        invocation
      ) do
    with {:ok, commands} <- method_commands(request, "cli.observe"),
         true <- Enum.all?(commands, &ssh_readonly_command?/1),
         {:ok, output} <-
           run_shell(state, request.connection.endpoint, script(commands), invocation) do
      IOSXE.observation(%{"output" => output}, [evidence(output)])
    else
      false ->
        {:error, :failed, "CLI request is not provably non-mutating; submit it as an effect"}

      {:error, category, message} ->
        IOSXE.read_error(category, message)

      {:error, _cause} = error ->
        error
    end
  end

  def observe(%Transport.Config{} = state, request, invocation) do
    with {:ok, operation} <- IOSXE.observation_request(request),
         {:ok, facts, output} <-
           observe_operation(
             state,
             request.connection.endpoint,
             operation,
             invocation
           ) do
      IOSXE.observation(facts, [evidence(output)])
    else
      {:error, category, message} -> IOSXE.read_error(category, message)
      {:error, _cause} = error -> error
    end
  end

  @impl Skopos.Providers.Target
  def classify_request(state, %{capability: capability} = request)
      when capability in @ssh_capabilities,
      do: SSHMethod.classify_request(state, request)

  def classify_request(_state, request) do
    case request.capability do
      @method_observation ->
        case method_commands(request, "cli.observe") do
          {:ok, commands} ->
            if Enum.all?(commands, &ssh_readonly_command?/1),
              do: {:ok, :observation},
              else: {:error, :failed, "CLI observation is unsafe"}

          _invalid ->
            {:error, :failed, "CLI request is invalid"}
        end

      @method_effect ->
        classify_ios_xe(method_commands(request, "cli.execute"), :effect)

      "effect.interface" ->
        classify_ios_xe(IOSXE.effect_request(request), :effect)

      _other ->
        classify_ios_xe(IOSXE.observation_request(request), :observation)
    end
  end

  defp classify_ios_xe({:ok, _operation}, kind), do: {:ok, kind}
  defp classify_ios_xe(_invalid, _kind), do: {:error, :failed, "CLI request is invalid"}

  @impl Skopos.Providers.Target
  def effect(state, %{capability: capability} = request, invocation)
      when capability in @ssh_capabilities,
      do: SSHMethod.effect(state, request, invocation)

  def effect(%Transport.Config{} = state, %{capability: @method_effect} = request, invocation) do
    with {:ok, commands} <- method_commands(request, "cli.execute"),
         {:ok, output} <-
           run_shell(state, request.connection.endpoint, script(commands), invocation),
         :ok <- ssh_command_accepted?(output) do
      IOSXE.applied(%{"output" => output})
    else
      {:error, category, message} -> IOSXE.effect_error(category, message)
      {:error, _cause} = error -> error
    end
  end

  def effect(%Transport.Config{} = state, request, invocation) do
    with {:ok, operation} <- IOSXE.effect_request(request) do
      apply_operation(
        state,
        request.connection.endpoint,
        operation,
        invocation
      )
    else
      {:error, category, message} -> IOSXE.effect_error(category, message)
    end
  end

  @impl Skopos.Providers.Target
  def verify(state, %{capability: capability} = request, invocation)
      when capability in @ssh_capabilities,
      do: SSHMethod.verify(state, request, invocation)

  def verify(
        %Transport.Config{} = state,
        %{capability: @method_observation} = request,
        invocation
      ) do
    with {:ok, commands} <- method_commands(request, "cli.observe"),
         true <- Enum.all?(commands, &ssh_readonly_command?/1),
         {:ok, output} <-
           run_shell(state, request.connection.endpoint, script(commands), invocation) do
      IOSXE.verification(%{"output" => output}, request.expected, [evidence(output)])
    else
      false -> {:error, :failed, "CLI verification must be non-mutating"}
      {:error, category, message} -> IOSXE.read_error(category, message)
      {:error, _cause} = error -> error
    end
  end

  def verify(%Transport.Config{} = state, request, invocation) do
    with {:ok, name, expected} <- IOSXE.verification_request(request),
         {:ok, facts, output} <-
           observe_operation(
             state,
             request.connection.endpoint,
             {:interface, name},
             invocation
           ) do
      IOSXE.verification(facts, expected, [evidence(output)])
    else
      {:error, category, message} -> IOSXE.read_error(category, message)
      {:error, _cause} = error -> error
    end
  end

  defp observe_operation(state, endpoint, :system, invocation) do
    with {:ok, output} <-
           run_shell(state, endpoint, script(ssh_system_commands()), invocation),
         {:ok, facts} <- ssh_system_facts(output) do
      {:ok, facts, output}
    end
  end

  defp observe_operation(state, endpoint, {:interface, name}, invocation) do
    with {:ok, output} <-
           run_shell(state, endpoint, script(ssh_interface_commands(name)), invocation),
         {:ok, facts} <- ssh_interface_facts(name, output) do
      {:ok, facts, output}
    end
  end

  defp apply_operation(state, endpoint, {:description, name, expected, desired}, invocation) do
    with {:ok, facts, _output} <-
           observe_operation(state, endpoint, {:interface, name}, invocation),
         :ok <- IOSXE.match_expected(facts["description"], expected, "description"),
         {:ok, output} <-
           run_shell(
             state,
             endpoint,
             script(ssh_description_commands(name, desired)),
             invocation
           ),
         :ok <- ssh_command_accepted?(output) do
      IOSXE.applied(%{
        "interface" => name,
        "description" => desired,
        "evidence" => evidence(output)
      })
    else
      {:stale, observed, field} -> IOSXE.stale(field, observed)
      {:error, category, message} -> IOSXE.effect_error(category, message)
      {:error, _cause} = error -> error
    end
  end

  defp apply_operation(state, endpoint, {:admin_state, name, expected, desired}, invocation) do
    with {:ok, facts, _output} <-
           observe_operation(state, endpoint, {:interface, name}, invocation),
         :ok <- IOSXE.match_expected(facts["enabled"], expected, "enabled"),
         {:ok, output} <-
           run_shell(
             state,
             endpoint,
             script(ssh_admin_state_commands(name, desired)),
             invocation
           ),
         :ok <- ssh_command_accepted?(output) do
      IOSXE.applied(%{"interface" => name, "enabled" => desired, "evidence" => evidence(output)})
    else
      {:stale, observed, field} -> IOSXE.stale(field, observed)
      {:error, category, message} -> IOSXE.effect_error(category, message)
      {:error, _cause} = error -> error
    end
  end

  defp run_shell(state, endpoint, script, invocation) do
    case Transport.shell(state, endpoint, script, invocation) do
      {:ok, %Transport.ShellResult{output: output}} -> {:ok, normalize(output)}
      {:error, category, message} -> {:error, category, message}
      {:error, _cause} = error -> error
    end
  end

  defp method_commands(request, operation) do
    expected_capability =
      if(operation == "cli.observe", do: @method_observation, else: @method_effect)

    case request do
      %{
        capability: ^expected_capability,
        operation: ^operation,
        selectors: selectors,
        parameters: %{"commands" => commands}
      }
      when selectors == %{} and is_list(commands) and length(commands) in 1..50 ->
        if Enum.all?(commands, &single_line_command?/1),
          do: {:ok, commands},
          else: {:error, :failed, "IOS XE CLI commands are invalid"}

      _request ->
        {:error, :failed, "IOS XE CLI request is invalid"}
    end
  end

  defp method_observation do
    output = %{
      "type" => "object",
      "properties" => %{"output" => %{"type" => "string", "maxLength" => 65_536}},
      "required" => ["output"],
      "additionalProperties" => false
    }

    %Target.Operation{
      capability: @method_observation,
      operation: "cli.observe",
      description: "Run exact IOS XE show commands and return raw output",
      input_schema: method_schema(),
      output_schema: output,
      verification_schema: Map.put(output, "minProperties", 1)
    }
  end

  defp method_effect do
    %Target.Operation{
      capability: @method_effect,
      operation: "cli.execute",
      description: "Run exact IOS XE CLI commands after authority review",
      input_schema: method_schema()
    }
  end

  defp method_schema do
    %{
      "type" => "object",
      "properties" => %{
        "selectors" => %{"type" => "object", "maxProperties" => 0},
        "parameters" => %{
          "type" => "object",
          "properties" => %{
            "commands" => %{
              "type" => "array",
              "minItems" => 1,
              "maxItems" => 50,
              "items" => %{"type" => "string", "minLength" => 1, "maxLength" => 1_024}
            }
          },
          "required" => ["commands"],
          "additionalProperties" => false
        }
      },
      "required" => ["selectors", "parameters"],
      "additionalProperties" => false
    }
  end

  defp script(commands),
    do:
      Enum.join(["terminal length 0", "terminal width 511" | commands] ++ ["exit"], "\n") <> "\n"

  defp normalize(output) do
    output
    |> String.replace("\r", "")
    |> String.replace(~r/\e\[[0-9;?]*[ -\/]*[@-~]/, "")
  end

  defp evidence(output), do: %{"transport" => "ssh-cli", "output" => output}

  # IOS XE CLI vocabulary and response interpretation belong to this Method.
  defp ssh_system_commands do
    [
      "show running-config | include ^hostname",
      "show version | include Cisco IOS XE Software, Version"
    ]
  end

  defp ssh_interface_commands(name) do
    [
      "show running-config interface #{name}",
      "show interfaces #{name} | include line protocol|Description|input errors|output errors"
    ]
  end

  defp ssh_description_commands(name, desired),
    do: ["configure terminal", "interface #{name}", "description #{desired}", "end"]

  defp ssh_admin_state_commands(name, desired),
    do: [
      "configure terminal",
      "interface #{name}",
      if(desired, do: "no shutdown", else: "shutdown"),
      "end"
    ]

  defp ssh_system_facts(output) do
    with [hostname] <- ssh_capture(output, ~r/^hostname\s+(\S+)\s*$/m),
         [version] <- ssh_capture(output, ~r/^Cisco IOS XE Software, Version[ \t]+([^\r\n]+)/m) do
      {:ok, %{"hostname" => hostname, "version" => String.trim(version)}}
    else
      _output -> {:error, :failed, "IOS XE SSH system response is invalid"}
    end
  end

  defp ssh_interface_facts(name, output) do
    line =
      Regex.run(
        ~r/^#{Regex.escape(name)} is (administratively down|up|down), line protocol is (up|down)/m,
        output,
        capture: :all_but_first
      )

    case line do
      [admin, operational] ->
        description =
          case ssh_capture(output, ~r/^\s*Description:\s*(.*?)\s*$/m) do
            [value] -> value
            [] -> ssh_running_description(name, output)
          end

        {:ok,
         %{
           "name" => name,
           "description" => description,
           "enabled" => admin != "administratively down",
           "admin_status" => if(admin == "administratively down", do: "down", else: admin),
           "oper_status" => operational,
           "input_errors" => ssh_error_count(output, "input"),
           "output_errors" => ssh_error_count(output, "output")
         }}

      _line ->
        {:error, :not_found, "IOS XE interface was not found"}
    end
  end

  defp ssh_command_accepted?(output) do
    if Regex.match?(
         ~r/% (Invalid input|Incomplete command|Ambiguous command|Command rejected)/i,
         output
       ),
       do: {:error, :rejected, "IOS XE SSH command was rejected"},
       else: :ok
  end

  defp ssh_readonly_command?(command) do
    command = command |> String.trim() |> String.downcase()

    (String.starts_with?(command, "show ") or command == "show") and
      not String.contains?(command, ["|", ";", ">", "<"]) and
      command |> String.to_charlist() |> Enum.all?(&(&1 in 32..126))
  end

  defp single_line_command?(command) when is_binary(command),
    do:
      byte_size(command) in 1..1_024 and
        not String.contains?(command, ["\r", "\n", <<0>>, <<27>>])

  defp single_line_command?(_command), do: false

  defp ssh_running_description(name, output) do
    pattern =
      ~r/^interface #{Regex.escape(name)}\s*$\n(?:^[ !].*$\n)*?^ description\s+(.+?)\s*$/m

    case ssh_capture(output, pattern) do
      [description] -> description
      [] -> nil
    end
  end

  defp ssh_error_count(output, direction) do
    case ssh_capture(output, ~r/^\s*([0-9,]+) #{direction} errors,/m) do
      [value] -> value |> String.replace(",", "") |> String.to_integer()
      [] -> nil
    end
  end

  defp ssh_capture(output, pattern) do
    case Regex.run(pattern, output, capture: :all_but_first) do
      nil -> []
      values -> values
    end
  end
end
