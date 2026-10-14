defmodule Skopos.Targets.Adapters.SSH do
  @moduledoc false

  @behaviour Skopos.Providers.Adapter
  @behaviour Skopos.Providers.Target

  alias Skopos.Providers.Target
  alias Skopos.Transports.SSH, as: Transport
  alias Skopos.Targets.Adapters.SSH.SFTP
  alias Skopos.Targets.Adapters.SSH.Subsystem

  @effect_capability "request.ssh.effect"

  @impl Skopos.Providers.Adapter
  def type, do: "ssh"

  @impl Skopos.Providers.Adapter
  def kind, do: :target

  @impl Skopos.Providers.Target
  def access_method_profile do
    %Target.AccessMethodProfile{
      method: "ssh",
      capabilities: ["request.ssh.observe", @effect_capability]
    }
  end

  @impl Skopos.Providers.Adapter
  def build(configuration, credentials), do: Transport.build(configuration, credentials)

  @impl Skopos.Providers.Target
  def bind_connection(state, %Target.Connection{endpoint: endpoint}) do
    with :ok <- Transport.validate_endpoint(state, endpoint), do: {:ok, state}
  end

  @impl Skopos.Providers.Adapter
  def check(state, %{"endpoint" => endpoint}) do
    case Transport.check(state, endpoint) do
      :ok -> :ok
      {:error, :authentication, message} -> {:error, :authentication, message}
      {:error, :host_key, message} -> {:error, :authentication, message}
      {:error, _category, message} -> {:error, :unreachable, message}
    end
  end

  def check(_state, _input),
    do: {:error, :invalid_configuration, "SSH check requires an endpoint"}

  @impl Skopos.Providers.Target
  def capabilities(_state, _invocation) do
    files = SFTP.capabilities()

    {:ok,
     %Target.Capabilities{
       observations: files.observations,
       effects:
         [
           effect_operation(@effect_capability, "SSH"),
           shell_operation(@effect_capability),
           Subsystem.effect()
         ] ++ files.effects
     }}
  end

  @impl Skopos.Providers.Target
  def classify_request(_state, %{operation: "sftp." <> _name} = request) do
    with {:ok, operation} <- SFTP.operation(request),
         do:
           {:ok,
            if(operation.kind in [:read, :metadata_read, :directory],
              do: :observation,
              else: :effect
            )}
  end

  def classify_request(_state, request) do
    validation =
      case request.operation do
        "shell.execute" -> shell_script(request, @effect_capability)
        "subsystem.session" -> Subsystem.compile(request)
        _other -> effect_command(request, @effect_capability)
      end

    with {:ok, _command} <- validation do
      {:ok, :effect}
    else
      _ -> {:error, :failed, "SSH command request is invalid"}
    end
  end

  @impl Skopos.Providers.Target
  def observe(state, %{operation: "sftp." <> _name} = request, invocation) do
    with {:ok, %{kind: kind} = operation}
         when kind in [:read, :metadata_read, :directory] <-
           SFTP.operation(request),
         {:ok, facts} <- Transport.sftp(state, request.connection.endpoint, operation, invocation) do
      {:ok,
       %Target.Observation{
         facts: facts,
         observed_at: DateTime.utc_now(),
         evidence: [sftp_evidence(operation)]
       }}
    else
      {:error, category, _message} = error when category in [:cancelled, :failed] -> error
      {:error, _category, message} -> {:error, :failed, message}
      {:error, _cause} = error -> error
      _ -> {:error, :failed, "SFTP observation failed"}
    end
  end

  def observe(_state, _request, _invocation),
    do: {:error, :failed, "Raw SSH commands require effect authority"}

  defp sftp_evidence(%{path: path}), do: %{"source" => "sftp", "path" => path}

  @impl Skopos.Providers.Target
  def effect(state, %{operation: "sftp." <> _name} = request, invocation) do
    with {:ok, %{kind: kind} = operation} when kind in [:write, :metadata_write] <-
           SFTP.operation(request) do
      case Transport.sftp(state, request.connection.endpoint, operation, invocation) do
        {:ok, details} ->
          {:ok, %Target.EffectResult{status: :applied, details: details}}

        error ->
          effect_result(error)
      end
    else
      _invalid -> {:error, :failed, "SFTP effect request is invalid"}
    end
  end

  def effect(state, %{operation: "shell.execute"} = request, invocation) do
    with {:ok, script} <- shell_script(request, @effect_capability),
         result <-
           Transport.shell(state, request.connection.endpoint, script, invocation) do
      effect_result(result)
    end
  end

  def effect(state, %{operation: "subsystem.session"} = request, invocation) do
    with {:ok, operation} <- Subsystem.compile(request) do
      case Transport.subsystem_session(state, request.connection.endpoint, operation, invocation) do
        {:ok, details} ->
          {:ok,
           %Target.EffectResult{
             status: if(details["exit_status"] in [nil, 0], do: :applied, else: :failed),
             details: details
           }}

        {:error, _category, message, progress} ->
          {:ok,
           %Target.EffectResult{
             status: :unknown,
             details:
               Map.merge(progress, %{
                 "error" => message,
                 "completion_reason" => "sequence_interrupted"
               })
           }}

        error ->
          effect_result(error)
      end
    end
  end

  def effect(state, request, invocation) do
    with {:ok, command} <- effect_command(request, @effect_capability),
         result <-
           Transport.exec(state, request.connection.endpoint, command, invocation) do
      effect_result(result)
    end
  end

  @impl Skopos.Providers.Target
  def verify(state, %{operation: "sftp." <> _name} = request, invocation) do
    with {:ok, observation} <- observe(state, request, invocation),
         do:
           {:ok,
            %Target.Verification{
              status:
                if(request.operation == "sftp.read_file",
                  do: SFTP.expected_status(observation.facts["file"], request.expected),
                  else: :unknown
                ),
              observed_at: observation.observed_at,
              facts: observation.facts,
              evidence: observation.evidence
            }}
  end

  def verify(_state, _request, _invocation),
    do: {:error, :failed, "Raw SSH commands cannot verify an effect"}

  defp effect_result({:ok, %Transport.ShellResult{} = result}) do
    {:ok, %Target.EffectResult{status: :applied, details: shell_facts(result)}}
  end

  defp effect_result({:ok, %Transport.Result{} = result}) do
    {:ok,
     %Target.EffectResult{
       status: if(result.exit_status == 0, do: :applied, else: :failed),
       details: facts(result)
     }}
  end

  defp effect_result({:error, category, message})
       when category in [
              :timeout_after_dispatch,
              :cancelled_after_dispatch,
              :disconnected_after_dispatch,
              :output_limit_after_dispatch
            ],
       do: {:ok, %Target.EffectResult{status: :unknown, details: %{"error" => message}}}

  defp effect_result({:error, :cancelled, message}), do: {:error, :cancelled, message}
  defp effect_result({:error, _category, message}), do: {:error, :failed, message}
  defp effect_result({:error, _cause} = error), do: error

  # Shared SSH request contract used by product profiles in addition to this
  # generic Method. Profiles may add operations, but reuse the same raw request.
  def effect_operation(capability, description) do
    %Target.Operation{
      capability: capability,
      operation: "command.execute",
      description: "Run one exact #{description} command after authority review",
      input_schema: request_schema("command")
    }
  end

  def shell_operation(capability) do
    %Target.Operation{
      capability: capability,
      operation: "shell.execute",
      description: "Send one exact interactive SSH shell script after authority review",
      input_schema: request_schema("script")
    }
  end

  def effect_command(request, capability),
    do: command(request, capability, "command.execute", "command")

  def shell_script(request, capability),
    do: command(request, capability, "shell.execute", "script")

  def facts(result) do
    %{
      "stdout" => encode(result.stdout),
      "stderr" => encode(result.stderr),
      "exit_status" => result.exit_status
    }
  end

  def shell_facts(result), do: %{"output" => encode(result.output)}

  defp command(request, capability, operation, field) do
    case request do
      %{
        capability: ^capability,
        operation: ^operation,
        selectors: selectors,
        parameters: %{^field => value} = parameters
      }
      when selectors == %{} and map_size(parameters) == 1 and is_binary(value) and
             byte_size(value) in 1..4_096 ->
        {:ok, value}

      _request ->
        {:error, :failed, "SSH request is invalid"}
    end
  end

  defp request_schema(field) do
    %{
      "type" => "object",
      "properties" => %{
        "selectors" => %{"type" => "object", "maxProperties" => 0},
        "parameters" => %{
          "type" => "object",
          "properties" => %{
            field => %{"type" => "string", "minLength" => 1, "maxLength" => 4_096}
          },
          "required" => [field],
          "additionalProperties" => false
        }
      },
      "required" => ["selectors", "parameters"],
      "additionalProperties" => false
    }
  end

  defp encode(value) do
    if String.valid?(value),
      do: %{"encoding" => "utf-8", "value" => value},
      else: %{"encoding" => "base64", "value" => Base.encode64(value)}
  end
end
