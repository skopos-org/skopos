defmodule Skopos.Targets.Adapters.Redfish do
  @moduledoc false

  @behaviour Skopos.Providers.Adapter
  @behaviour Skopos.Providers.Target

  alias Skopos.Providers.Target
  alias Skopos.Targets.PowerControl
  alias Skopos.Targets.Adapters.RedfishURI
  alias Skopos.Transports.HTTPS

  @reset_types %{
    "bmc.power.on" => "On",
    "bmc.power.off" => "ForceOff",
    "bmc.power.cycle" => "PowerCycle",
    "bmc.power.reset" => "ForceRestart"
  }
  @api_read_methods %{"GET" => :get, "HEAD" => :head}
  @api_write_methods %{"POST" => :post, "PATCH" => :patch, "PUT" => :put, "DELETE" => :delete}
  @method_read "request.redfish.observe"
  @method_effect "request.redfish.effect"
  @sensitive_names ~w(password passphrase secret token credential authorization apikey privatekey community)
  @max_collection_pages 8

  defmodule State do
    @moduledoc false
    @enforce_keys [:system_path, :expected_uuid, :auth, :cacerts, :timeout]
    defstruct @enforce_keys ++ [:endpoint]
  end

  @impl Skopos.Providers.Adapter
  def type, do: "redfish"

  @impl Skopos.Providers.Adapter
  def kind, do: :target

  @impl Skopos.Providers.Target
  def access_method_profile do
    %Target.AccessMethodProfile{
      method: "redfish",
      capabilities: [
        @method_read,
        @method_effect | Target.capability_names(PowerControl.capabilities())
      ]
    }
  end

  @impl Skopos.Providers.Adapter
  def build(configuration, credentials) when is_map(configuration) and is_map(credentials) do
    allowed = ~w(system_path expected_uuid ca_certificate timeout_ms)

    with true <- Enum.all?(Map.keys(configuration), &(&1 in allowed)),
         true <- Enum.sort(Map.keys(credentials)) == ["password", "username"],
         {:ok, system_path, expected_uuid} <- system_identity(configuration),
         {:ok, username} <- required_string(credentials["username"], 255),
         false <- String.contains?(username, ":"),
         {:ok, password} <- required_string(credentials["password"], 4_096),
         {:ok, certificates} <- HTTPS.parse_ca_certificate(configuration["ca_certificate"]),
         timeout when is_integer(timeout) and timeout in 100..60_000 <-
           Map.get(configuration, "timeout_ms", 10_000) do
      {:ok,
       %State{
         system_path: system_path,
         expected_uuid: expected_uuid,
         auth: {:basic, username <> ":" <> password},
         cacerts: certificates,
         timeout: timeout
       }}
    else
      _ -> {:error, :invalid_configuration}
    end
  end

  def build(_configuration, _credentials), do: {:error, :invalid_configuration}

  @impl Skopos.Providers.Adapter
  def check(%State{} = state, %{"endpoint" => endpoint}) do
    with {:ok, state} <- bind_connection(state, %Target.Connection{endpoint: endpoint}) do
      case service_root(state) do
        {:ok, _root} -> :ok
        {:error, :authentication, message} -> {:error, :authentication, message}
        {:error, _category, message} -> {:error, :unreachable, message}
      end
    else
      _ -> {:error, :invalid_configuration, "Redfish Method endpoint is invalid"}
    end
  end

  def check(_state, _input),
    do: {:error, :invalid_configuration, "Redfish check requires a Method endpoint"}

  @impl Skopos.Providers.Target
  def bind_connection(%State{} = state, %Target.Connection{endpoint: value}) do
    case endpoint(value) do
      {:ok, endpoint} -> {:ok, %{state | endpoint: endpoint}}
      _ -> {:error, :failed, "Redfish Method endpoint is invalid"}
    end
  end

  @impl Skopos.Providers.Target
  def capabilities(state, invocation) do
    with {:ok, power} <- power_capabilities(state, invocation) do
      {:ok,
       %Target.Capabilities{
         observations: power.observations ++ [method_read_operation(), task_read_operation()],
         effects: power.effects ++ [method_effect_operation()]
       }}
    end
  end

  defp power_capabilities(state, invocation) do
    with {:ok, system} <- system(state, invocation),
         {:ok, _power} <- power_state(system) do
      capabilities = PowerControl.capabilities()

      case reset_action(state, system, invocation) do
        {:ok, _target, allowed} ->
          effects = Enum.filter(capabilities.effects, &(@reset_types[&1.operation] in allowed))
          {:ok, %{capabilities | effects: effects}}

        {:error, _} = error ->
          error

        {:error, :cancelled, _} = error ->
          error

        _ ->
          {:ok, %{capabilities | effects: []}}
      end
    else
      {:error, _} = error -> error
      {:error, :cancelled, _} = error -> error
      _ -> {:ok, %Target.Capabilities{observations: [], effects: []}}
    end
  end

  @impl Skopos.Providers.Target
  def classify_request(%State{} = state, request) do
    case request.capability do
      @method_read ->
        classify_redfish(method_read_request(state, request), :observation)

      @method_effect ->
        classify_redfish(method_write_request(state, request), :effect)

      "observe.power" ->
        if PowerControl.inspect_request?(request) and
             request.connection.endpoint == state.endpoint,
           do: {:ok, :observation},
           else: {:error, :failed, "Redfish power observation is invalid"}

      "effect.power" ->
        with true <- request.connection.endpoint == state.endpoint,
             {:ok, _intent} <- PowerControl.effect_request(request) do
          {:ok, :effect}
        else
          _ -> {:error, :failed, "Redfish power effect is invalid"}
        end

      _other ->
        {:error, :failed, "Redfish request is invalid"}
    end
  end

  defp classify_redfish({:ok, _first, _second, _transfer}, kind), do: {:ok, kind}

  defp classify_redfish({:ok, _first, _second, _third, _fourth, _fifth, _transfer}, kind),
    do: {:ok, kind}

  defp classify_redfish(_invalid, _kind), do: {:error, :failed, "Redfish request is invalid"}

  @impl Skopos.Providers.Target
  def observe(
        %State{} = state,
        %{capability: @method_read, operation: "task.observe"} = request,
        invocation
      ),
      do: task_observe(state, request, invocation)

  def observe(%State{} = state, %{capability: @method_read} = request, invocation),
    do: method_observe(state, request, invocation)

  def observe(%State{} = state, request, invocation) do
    with true <- PowerControl.inspect_request?(request),
         true <- request.connection.endpoint == state.endpoint,
         :ok <- not_cancelled(invocation),
         {:ok, system} <- system(state, invocation),
         {:ok, power} <- power_state(system) do
      {:ok, PowerControl.observation(power, state.expected_uuid, "redfish")}
    else
      false -> {:error, :failed, "Redfish observation request is invalid"}
      {:error, _} = error -> error
      {:error, category, message} -> read_error(category, message)
    end
  end

  @impl Skopos.Providers.Target
  def effect(%State{} = state, %{capability: @method_effect} = request, invocation),
    do: method_effect(state, request, invocation)

  def effect(%State{} = state, request, invocation) do
    with true <- request.connection.endpoint == state.endpoint,
         {:ok, intent} <- PowerControl.effect_request(request),
         :ok <- not_cancelled(invocation),
         {:ok, system} <- system(state, invocation),
         {:ok, observed} <- power_state(system),
         :ok <- PowerControl.expected_state(intent.expected, observed),
         {:ok, action_path, allowed} <- reset_action(state, system, invocation),
         reset_type when is_binary(reset_type) <- @reset_types[intent.operation],
         true <- reset_type in allowed,
         :ok <- not_cancelled(invocation) do
      case request(state, :post, action_path, %{"ResetType" => reset_type}, [], %{}, invocation) do
        {:ok, status, _headers, _body} when status in [200, 201, 204] ->
          {:ok,
           %Target.EffectResult{
             status: :applied,
             reference: intent.operation,
             details: %{"reset_type" => reset_type, "pre_power_state" => observed}
           }}

        {:ok, 202, headers, _body} ->
          protected = response_task_reference(state, headers)

          {:ok,
           %Target.EffectResult{
             status: :unknown,
             reference: intent.operation,
             protected_reference: protected,
             details:
               %{"reason" => "Redfish task was accepted but is not complete"}
               |> maybe_retry_after(protected)
           }}

        {:error, category, message} when category in [:transport, :cancelled] ->
          {:ok,
           %Target.EffectResult{
             status: :unknown,
             reference: intent.operation,
             details: %{
               "reason" =>
                 if(category == :cancelled,
                   do: message,
                   else: "Redfish reset response was lost after dispatch"
                 )
             }
           }}

        {:error, _category, message} ->
          {:error, :failed, message}

        {:error, %{errors: errors} = cause} when is_list(errors) ->
          {:error,
           Target.Error.context_failure(cause, %{
             "reset_type" => reset_type,
             "pre_power_state" => observed
           })}

        {:error, _} = error ->
          error

        _ ->
          {:error, :failed, "Redfish reset was rejected"}
      end
    else
      false -> {:error, :failed, "Redfish reset request or allowed value is invalid"}
      {:error, _} = error -> error
      {:error, :cancelled, _} = error -> error
      {:error, _category, message} -> {:error, :failed, message}
      _ -> {:error, :failed, "Redfish reset type is unavailable"}
    end
  end

  @impl Skopos.Providers.Target
  def verify(%State{} = state, %{capability: @method_read} = request, invocation) do
    with {:ok, observation} <- observe(state, request, invocation) do
      status =
        cond do
          request.expected == %{} ->
            :unknown

          Enum.all?(request.expected, fn {key, value} ->
            Map.fetch(observation.facts, key) == {:ok, value}
          end) ->
            :verified

          true ->
            :not_verified
        end

      {:ok,
       %Target.Verification{
         status: status,
         facts: observation.facts,
         observed_at: observation.observed_at,
         evidence: observation.evidence
       }}
    end
  end

  def verify(%State{} = state, request, invocation) do
    with true <- request.connection.endpoint == state.endpoint,
         true <- PowerControl.inspect_request?(request),
         :ok <- not_cancelled(invocation),
         {:ok, system} <- system(state, invocation),
         {:ok, power} <- power_state(system) do
      verification =
        PowerControl.verification(power, state.expected_uuid, "redfish", request.expected)

      verification =
        if request.reference in ["bmc.power.cycle", "bmc.power.reset"],
          do: %{verification | status: :unknown},
          else: verification

      {:ok, verification}
    else
      false -> {:error, :failed, "Redfish verification request is invalid"}
      {:error, _} = error -> error
      {:error, category, message} -> read_error(category, message)
    end
  end

  defp method_observe(state, request, invocation) do
    with {:ok, method, destination, transfer} <- method_read_request(state, request),
         {:ok, path, protected} <- resolve_destination(state, destination, invocation),
         :ok <- not_cancelled(invocation),
         {:ok, status, body, pages, headers} <-
           read_api_resource(state, method, path, transfer, invocation) do
      evidence =
        %{
          "source" => "redfish",
          "method" => String.upcase(to_string(method)),
          "http_status" => status,
          "pages" => pages
        }
        |> destination_evidence(destination)
        |> maybe_etag(if(pages == 1, do: response_etag(headers), else: nil))

      {:ok,
       %Target.Observation{
         facts:
           method_response_details(status, body, true)
           |> redact_task_reference(protected)
           |> Map.put_new("response", %{}),
         observed_at: DateTime.utc_now(),
         evidence: [evidence]
       }}
    else
      {:error, %Target.BeforeSendError{}} = error -> error
      {:error, %{errors: errors}} = error when is_list(errors) -> error
      {:error, category, message} -> read_error(category, message)
    end
  end

  defp method_read_operation do
    output = %{
      "type" => "object",
      "properties" => %{
        "http_status" => %{"type" => "integer"},
        "response" => %{"type" => "object"},
        "file" => Target.FileReference.schema(),
        "content_type" => %{"type" => "string"},
        "content_encoding" => %{"type" => "string"}
      },
      "required" => ["http_status", "response"],
      "additionalProperties" => false
    }

    %Target.Operation{
      capability: @method_read,
      operation: "request.observe",
      description:
        "Read one exact standard or OEM Redfish resource by relative URI or saved result_reference UUID",
      input_schema: method_schema(["GET", "HEAD"]),
      output_schema: output,
      verification_schema: output
    }
  end

  defp method_effect_operation do
    %Target.Operation{
      capability: @method_effect,
      operation: "request.execute",
      description:
        "Send one exact standard or OEM Redfish write by relative URI or saved result_reference UUID after authority review",
      input_schema: method_schema(Map.keys(@api_write_methods), true)
    }
  end

  defp task_read_operation do
    output = %{
      "type" => "object",
      "properties" => %{
        "http_status" => %{"type" => "integer"},
        "task_outcome" => %{"type" => "string"},
        "task_state" => %{"type" => "string"},
        "task_status" => %{"type" => "string"},
        "percent_complete" => %{"type" => "integer"},
        "retry_after_seconds" => %{"type" => "integer"}
      },
      "required" => ["http_status", "task_outcome"],
      "additionalProperties" => false
    }

    %Target.Operation{
      capability: @method_read,
      operation: "task.observe",
      description:
        "Read a saved remote task using its result_reference UUID. Reports operation progress, not desired-outcome recovery; never resends the write or exposes the monitor URI.",
      input_schema: %{
        "type" => "object",
        "properties" => %{
          "selectors" => %{
            "type" => "object",
            "properties" => %{},
            "additionalProperties" => false
          },
          "parameters" => %{
            "type" => "object",
            "properties" => %{"result_reference" => %{"type" => "string", "format" => "uuid"}},
            "required" => ["result_reference"],
            "additionalProperties" => false
          }
        },
        "required" => ["selectors", "parameters"],
        "additionalProperties" => false
      },
      output_schema: output
    }
  end

  defp method_schema(methods, write? \\ false) do
    selector_properties =
      if write?, do: %{"if_match" => %{"type" => "string", "maxLength" => 256}}, else: %{}

    parameter_properties = %{
      "method" => %{"type" => "string", "enum" => methods},
      "uri" => %{"type" => "string", "minLength" => 11, "maxLength" => 2_048},
      "result_reference" => %{"type" => "string", "format" => "uuid"},
      "accept" => %{"type" => "string", "maxLength" => 256},
      "response_file" => Target.FileWriter.options_schema()
    }

    parameter_properties =
      if write? do
        Map.merge(parameter_properties, %{
          "body" => %{"type" => "object"},
          "include_response" => %{"type" => "boolean"},
          "body_file" => %{"type" => "string", "minLength" => 1, "maxLength" => 120},
          "files" => Target.FileReference.set_schema(),
          "content_type" => %{"type" => "string", "maxLength" => 256}
        })
      else
        parameter_properties
      end

    %{
      "type" => "object",
      "properties" => %{
        "selectors" => %{
          "type" => "object",
          "properties" => selector_properties,
          "additionalProperties" => false
        },
        "parameters" => %{
          "type" => "object",
          "properties" => parameter_properties,
          "required" => ["method"],
          "oneOf" => [%{"required" => ["uri"]}, %{"required" => ["result_reference"]}],
          "additionalProperties" => false
        }
      },
      "required" => ["selectors", "parameters"],
      "additionalProperties" => false
    }
  end

  defp method_read_request(state, %{operation: "task.observe"} = request) do
    with true <- request.connection.endpoint == state.endpoint,
         true <- request.selectors == %{},
         %{"result_reference" => reference} when map_size(request.parameters) == 1 <-
           request.parameters,
         {:ok, _} <- Ecto.UUID.cast(reference) do
      {:ok, :get, {:reference, reference}, %{}}
    else
      _ -> {:error, :failed, "Redfish task observation request is invalid"}
    end
  end

  defp method_read_request(state, request) do
    with true <- request.operation == "request.observe",
         true <- request.connection.endpoint == state.endpoint,
         true <- request.selectors == %{},
         %{"method" => method} = parameters <- request.parameters,
         true <-
           Enum.all?(
             Map.keys(parameters),
             &(&1 in ~w(method uri result_reference accept response_file))
           ),
         {:ok, transfer} <- transfer_options(parameters),
         {:ok, verb} <- Map.fetch(@api_read_methods, method),
         {:ok, destination} <- method_destination(parameters) do
      {:ok, verb, destination, transfer}
    else
      _ -> {:error, :failed, "Redfish read request is invalid"}
    end
  end

  defp method_destination(parameters) do
    case Map.take(parameters, ["uri", "result_reference"]) do
      %{"uri" => uri} = destination when map_size(destination) == 1 ->
        RedfishURI.relative(uri)

      %{"result_reference" => reference} = destination when map_size(destination) == 1 ->
        case Ecto.UUID.cast(reference) do
          {:ok, _} -> {:ok, {:reference, reference}}
          _ -> {:error, :failed, "Redfish result reference is invalid"}
        end

      _ ->
        {:error, :failed, "Redfish request requires exactly one destination"}
    end
  end

  defp resolve_destination(state, {:reference, reference_id}, invocation) do
    with reader when is_function(reader, 1) <- invocation[:result_reference_reader],
         {:ok, %{"kind" => "redfish_task_monitor", "uri" => uri}} <- reader.(reference_id),
         {:ok, path} <- RedfishURI.monitor(state.endpoint, uri) do
      {:ok, path, %{"location" => [uri]}}
    else
      {:error, :invalid_resource_uri} -> unavailable_reference()
      {:error, error} -> {:error, Target.BeforeSendError.exception(cause: error)}
      _ -> unavailable_reference()
    end
  rescue
    error -> {:error, Target.BeforeSendError.exception(cause: error)}
  end

  defp resolve_destination(_state, uri, _invocation) when is_binary(uri), do: {:ok, uri, nil}

  defp unavailable_reference do
    {:error,
     Target.BeforeSendError.exception(
       cause:
         Ash.Error.Action.InvalidArgument.exception(
           field: :result_reference,
           message: "Redfish result reference is unavailable"
         )
     )}
  end

  defp destination_evidence(evidence, {:reference, id}),
    do: Map.put(evidence, "result_reference", id)

  defp destination_evidence(evidence, uri), do: Map.put(evidence, "uri", uri)

  defp task_observe(state, request, invocation) do
    with {:ok, :get, {:reference, reference_id} = destination, _transfer} <-
           method_read_request(state, request),
         {:ok, path, _protected} <- resolve_destination(state, destination, invocation),
         :ok <- not_cancelled(invocation),
         {:ok, status, headers, body} <-
           request(state, :get, path, nil, [], %{"task_monitor" => true}, invocation) do
      facts = %{"http_status" => status, "task_outcome" => task_outcome(status, body)}

      facts =
        facts
        |> task_fact(
          "task_state",
          body["TaskState"],
          ~w(New Starting Running Suspended Interrupted Pending Stopping Completed Killed Exception Service)
        )
        |> task_fact("task_status", body["TaskStatus"], ~w(OK Warning Critical))

      facts =
        case body["PercentComplete"] do
          value when is_integer(value) and value in 0..100 ->
            Map.put(facts, "percent_complete", value)

          _ ->
            facts
        end

      facts =
        case retry_after(headers) do
          nil -> facts
          seconds -> Map.put(facts, "retry_after_seconds", seconds)
        end

      {:ok,
       %Target.Observation{
         facts: facts,
         observed_at: DateTime.utc_now(),
         evidence: [
           %{"source" => "redfish", "result_reference" => reference_id, "http_status" => status}
         ]
       }}
    else
      {:error, %Target.BeforeSendError{}} = error -> error
      {:error, %{errors: errors}} = error when is_list(errors) -> error
      _ -> {:error, :failed, "Redfish task progress is unavailable"}
    end
  end

  defp task_outcome(status, _body) when status in [404, 410], do: "unavailable"
  defp task_outcome(status, _body) when status in [401, 403] or status in 300..399, do: "unknown"
  defp task_outcome(status, _body) when status >= 400, do: "failed"
  defp task_outcome(202, _body), do: "running"

  defp task_outcome(_status, %{"TaskState" => state}) when state in ["Exception", "Killed"],
    do: "failed"

  defp task_outcome(_status, %{"TaskState" => state})
       when state in ~w(New Starting Running Suspended Interrupted Pending Stopping Service),
       do: "running"

  defp task_outcome(_status, %{"TaskState" => state}) when state != "Completed", do: "unknown"

  defp task_outcome(status, _body) when status in 200..299, do: "completed"
  defp task_outcome(_status, _body), do: "unknown"

  defp task_fact(facts, key, value, allowed),
    do: if(value in allowed, do: Map.put(facts, key, value), else: facts)

  defp method_effect(state, target_request, invocation) do
    with {:ok, method, destination, body, headers, include_response?, transfer} <-
           method_write_request(state, target_request),
         {:ok, path, protected} <- resolve_destination(state, destination, invocation),
         :ok <- not_cancelled(invocation) do
      result = request(state, method, path, body, headers, transfer, invocation)

      effect_response(state, result, target_request.operation, fn status, reply ->
        method_response_details(status, reply, include_response?)
        |> redact_task_reference(protected)
      end)
    else
      {:error, %Target.BeforeSendError{}} = error -> error
      {:error, %{errors: errors}} = error when is_list(errors) -> error
      {:error, :cancelled, _message} = error -> error
      {:error, _category, message} -> {:error, :failed, message}
    end
  end

  defp method_write_request(state, request) do
    parameters = request.parameters

    with true <- request.operation == "request.execute",
         true <- request.connection.endpoint == state.endpoint,
         %{"method" => method} <- parameters,
         true <-
           Enum.all?(
             Map.keys(parameters),
             &(&1 in ~w(method uri result_reference body body_file content_type accept response_file include_response))
           ),
         {:ok, transfer} <- transfer_options(parameters),
         {:ok, verb} <- Map.fetch(@api_write_methods, method),
         {:ok, destination} <- method_destination(parameters),
         {:ok, headers} <- if_match_headers(request.selectors),
         include_response? when is_boolean(include_response?) <-
           Map.get(parameters, "include_response", false),
         {:ok, body} <- method_body(verb, parameters, Map.get(request, :files, %{})) do
      {:ok, verb, destination, body, headers, include_response?, transfer}
    else
      _ -> {:error, :failed, "Redfish write request is invalid"}
    end
  end

  defp method_body(_verb, %{"body_file" => label} = parameters, files) do
    with false <- Map.has_key?(parameters, "body"),
         true <- is_binary(label),
         {:ok, reference} <- Map.fetch(files, label),
         true <- Target.FileReference.valid?(reference) do
      {:ok, {:file, label, reference}}
    else
      _ -> {:error, :failed, "Redfish input file is invalid"}
    end
  end

  defp method_body(verb, parameters, _files) do
    body = Map.get(parameters, "body")

    if (verb == :delete or is_map(body)) and (is_nil(body) or is_map(body)) do
      case Jason.encode(body) do
        {:ok, encoded} when byte_size(encoded) <= 65_536 -> {:ok, body}
        _ -> {:error, :failed, "Redfish request body exceeds its limit"}
      end
    else
      {:error, :failed, "Redfish request body is invalid"}
    end
  rescue
    _ -> {:error, :failed, "Redfish request body is invalid"}
  end

  defp transfer_options(parameters) do
    with true <- Target.FileWriter.valid_options?(parameters["response_file"]),
         true <-
           Enum.all?(["accept", "content_type"], fn key ->
             value = Map.get(parameters, key, "application/json")

             is_binary(value) and byte_size(value) in 1..256 and
               String.contains?(value, "/") and Regex.match?(~r/\A[\x20-\x7e]+\z/, value)
           end) do
      {:ok, Map.take(parameters, ~w(accept content_type response_file))}
    else
      _ -> {:error, :failed, "Redfish transfer options are invalid"}
    end
  end

  defp method_response_details(status, {:file, file, media, encoding}, _include_response?),
    do: %{
      "http_status" => status,
      "response" => %{},
      "file" => file,
      "content_type" => media,
      "content_encoding" => encoding
    }

  defp method_response_details(status, reply, _include_response?) when map_size(reply) == 0,
    do: %{"http_status" => status}

  defp method_response_details(status, reply, true),
    do: %{"http_status" => status, "response" => sanitize_response(reply)}

  defp method_response_details(status, _reply, false),
    do: %{"http_status" => status, "response_redacted" => true}

  defp effect_response(state, {:ok, status, headers, reply}, reference, details)
       when status in [200, 201, 202, 204] do
    outcome = if status == 202, do: :unknown, else: :applied
    protected = if(status == 202, do: response_task_reference(state, headers))

    visible =
      details.(status, reply)
      |> redact_task_reference(if(status == 202, do: headers))
      |> maybe_retry_after(protected)

    {:ok,
     %Target.EffectResult{
       status: outcome,
       reference: reference,
       details: visible,
       protected_reference: protected
     }}
  end

  defp effect_response(_state, {:ok, status, _headers, _reply}, reference, _details) do
    {:ok,
     %Target.EffectResult{
       status: :unknown,
       reference: reference,
       details: %{"http_status" => status, "reason" => "Redfish write outcome is unclear"}
     }}
  end

  defp effect_response(_state, {:error, category, message}, reference, _details)
       when category in [:transport, :cancelled] do
    {:ok,
     %Target.EffectResult{
       status: :unknown,
       reference: reference,
       details: %{"reason" => message}
     }}
  end

  defp effect_response(_state, {:error, %{errors: errors}} = error, _reference, _details)
       when is_list(errors),
       do: error

  defp effect_response(_state, {:error, %Target.BeforeSendError{}} = error, _reference, _details),
    do: error

  defp effect_response(_state, {:error, _category, message}, _reference, _details),
    do: {:error, :failed, message}

  defp redact_task_reference(details, headers) when is_map(headers) do
    values =
      Enum.flat_map(
        Req.Response.get_header(%Req.Response{headers: headers}, "location"),
        fn uri ->
          parsed = URI.parse(uri)

          query_values =
            if parsed.query, do: URI.decode_query(parsed.query) |> Map.values(), else: []

          [uri, parsed.path, parsed.query | query_values]
        end
      )

    Skopos.Providers.Redactor.value(details, %{"secret" => values})
  rescue
    _ -> %{"http_status" => 202, "response_redacted" => true}
  end

  defp redact_task_reference(details, _reference), do: details

  defp maybe_retry_after(details, %{"retry_after_seconds" => seconds}),
    do: Map.put(details, "retry_after_seconds", seconds)

  defp maybe_retry_after(details, _reference), do: details

  defp read_api_resource(state, method, path, transfer, invocation) do
    case request(state, method, path, nil, [], transfer, invocation) do
      {:ok, status, headers, {:file, _, _, _} = body} when status in [200, 204] ->
        {:ok, status, body, 1, headers}

      {:ok, status, headers, body} when status in [200, 204] ->
        with {:ok, combined, pages} <-
               collect_pages(state, method, path, body, 1, MapSet.new([path]), invocation) do
          {:ok, status, combined, pages, headers}
        end

      {:ok, _status, _headers, _body} ->
        {:error, :failed, "Redfish read is incomplete"}

      {:error, _category, _message} = error ->
        error

      {:error, %{errors: errors}} = error when is_list(errors) ->
        error

      {:error, %Target.BeforeSendError{}} = error ->
        error
    end
  end

  defp collect_pages(_state, :head, _path, body, pages, _seen, _invocation),
    do: {:ok, body, pages}

  defp collect_pages(state, :get, path, body, pages, seen, invocation) do
    next = body["Members@odata.nextLink"] || body["@odata.nextLink"]

    case next do
      nil ->
        {:ok, body, pages}

      link when is_binary(link) and pages < @max_collection_pages ->
        with :ok <- not_cancelled(invocation),
             {:ok, next_path} <- RedfishURI.from_link(state.endpoint, link, path),
             false <- MapSet.member?(seen, next_path),
             {:ok, 200, _headers, next_body} <-
               request(state, :get, next_path, nil, [], %{}, invocation),
             first when is_list(first) <- body["Members"],
             following when is_list(following) <- next_body["Members"],
             merged <-
               body
               |> Map.put("Members", first ++ following)
               |> Map.put("Members@odata.nextLink", next_body["Members@odata.nextLink"])
               |> Map.put("@odata.nextLink", next_body["@odata.nextLink"]),
             true <- bounded_response?(merged) do
          collect_pages(
            state,
            :get,
            next_path,
            merged,
            pages + 1,
            MapSet.put(seen, next_path),
            invocation
          )
        else
          {:error, _category, _message} = error -> error
          {:error, %{errors: errors}} = error when is_list(errors) -> error
          {:error, %Target.BeforeSendError{}} = error -> error
          _ -> {:error, :failed, "Redfish collection pagination is invalid"}
        end

      _ ->
        {:error, :failed, "Redfish collection pagination limit was reached"}
    end
  end

  defp bounded_response?(body) do
    case Jason.encode(body) do
      {:ok, encoded} -> byte_size(encoded) <= 65_536
      _ -> false
    end
  end

  defp response_etag(headers) do
    case Req.Response.get_header(%Req.Response{headers: headers}, "etag") do
      [etag] when is_binary(etag) ->
        if valid_etag?(etag), do: etag, else: nil

      _ ->
        nil
    end
  end

  defp maybe_etag(evidence, etag) when is_binary(etag), do: Map.put(evidence, "etag", etag)
  defp maybe_etag(evidence, _etag), do: evidence

  defp if_match_headers(%{} = selectors) when map_size(selectors) == 0, do: {:ok, []}

  defp if_match_headers(%{"if_match" => etag} = selectors) when map_size(selectors) == 1 do
    if valid_etag?(etag) and not String.starts_with?(etag, "W/"),
      do: {:ok, [{"if-match", etag}]},
      else: {:error, :failed, "Redfish If-Match value is invalid"}
  end

  defp if_match_headers(_selectors),
    do: {:error, :failed, "Redfish If-Match selector is invalid"}

  defp valid_etag?(etag) when is_binary(etag) and byte_size(etag) in 1..256,
    do: etag == "*" or Regex.match?(~r/\A(?:W\/)?"[\x21\x23-\x7E]*"\z/, etag)

  defp valid_etag?(_etag), do: false

  defp response_task_reference(state, headers) do
    response = %Req.Response{headers: headers}

    with [location] <- Req.Response.get_header(response, "location"),
         {:ok, uri} <- RedfishURI.monitor(state.endpoint, location) do
      reference = %{"kind" => "redfish_task_monitor", "uri" => uri}

      case retry_after(headers) do
        nil -> reference
        seconds -> Map.put(reference, "retry_after_seconds", seconds)
      end
    else
      _ -> nil
    end
  end

  defp retry_after(headers) do
    # Req's installed implementation returns milliseconds for both delay and HTTP-date forms.
    case Req.Response.get_retry_after(%Req.Response{headers: headers}) do
      value when is_integer(value) and value >= 0 -> div(value + 999, 1_000)
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp sanitize_response(value), do: sanitize_response(value, 0)

  defp sanitize_response(value, depth) when is_map(value) and depth < 16 do
    Map.new(value, fn {key, item} ->
      safe = if sensitive_name?(key), do: "[REDACTED]", else: sanitize_response(item, depth + 1)
      {key, safe}
    end)
  end

  defp sanitize_response(value, depth) when is_list(value) and depth < 16,
    do: Enum.map(value, &sanitize_response(&1, depth + 1))

  defp sanitize_response(_value, depth) when depth >= 16, do: "[TRUNCATED]"
  defp sanitize_response(value, _depth), do: value

  defp sensitive_name?(key) when is_binary(key) do
    normalized = key |> String.downcase() |> String.replace(~r/[^a-z0-9]/, "")
    Enum.any?(@sensitive_names, &String.contains?(normalized, &1))
  end

  defp sensitive_name?(_key), do: false

  defp service_root(state) do
    with {:ok, 200, _headers, root} <- request(state, :get, "/redfish/v1/", nil),
         version when is_binary(version) and version != "" <- root["RedfishVersion"] do
      {:ok, root}
    else
      {:error, _category, _message} = error -> error
      _ -> {:error, :failed, "Redfish ServiceRoot response is invalid"}
    end
  end

  defp system(%State{system_path: nil}, _invocation),
    do: {:error, :failed, "No Redfish System is selected for power operations"}

  defp system(state, invocation) do
    with {:ok, 200, collection, _pages, _headers} <-
           read_api_resource(state, :get, "/redfish/v1/Systems", %{}, invocation),
         members when is_list(members) <- collection["Members"],
         true <- Enum.any?(members, &(&1["@odata.id"] == state.system_path)),
         {:ok, 200, _headers, system} <-
           request(state, :get, state.system_path, nil, [], %{}, invocation),
         true <- system["@odata.id"] == state.system_path,
         true <- system["UUID"] == state.expected_uuid do
      {:ok, system}
    else
      false -> {:error, :identity, "Redfish System identity does not match the configured host"}
      {:error, _category, _message} = error -> error
      {:error, _} = error -> error
      _ -> {:error, :failed, "Redfish System response is invalid"}
    end
  end

  defp reset_action(state, system, invocation) do
    with %{"target" => target} = action <- get_in(system, ["Actions", "#ComputerSystem.Reset"]),
         {:ok, path} <- action_path(state, target),
         {:ok, allowed} <- allowable_values(state, action, invocation),
         true <- Enum.all?(allowed, &is_binary/1) do
      {:ok, path, allowed}
    else
      {:error, _} = error -> error
      {:error, :cancelled, _} = error -> error
      _ -> {:error, :failed, "Redfish System does not advertise a usable reset action"}
    end
  end

  defp allowable_values(_state, %{"ResetType@Redfish.AllowableValues" => allowed}, _invocation)
       when is_list(allowed),
       do: {:ok, allowed}

  defp allowable_values(state, %{"@Redfish.ActionInfo" => info_uri}, invocation) do
    with {:ok, info_path} <- resource_path(state, info_uri),
         true <- String.starts_with?(info_path, state.system_path <> "/"),
         {:ok, 200, _headers, %{"Parameters" => parameters}} <-
           request(state, :get, info_path, nil, [], %{}, invocation),
         true <- is_list(parameters),
         %{"AllowableValues" => allowed} <-
           Enum.find(parameters, &(is_map(&1) and &1["Name"] == "ResetType")),
         true <- is_list(allowed) do
      {:ok, allowed}
    else
      {:error, _} = error -> error
      {:error, :cancelled, _} = error -> error
      _ -> {:error, :failed, "Redfish reset ActionInfo is unavailable"}
    end
  end

  defp allowable_values(_state, _action, _invocation),
    do: {:error, :failed, "Redfish reset allowable values are unavailable"}

  defp action_path(state, target) when is_binary(target) do
    with {:ok, path} <- resource_path(state, target),
         true <- String.starts_with?(path, state.system_path <> "/Actions/") do
      {:ok, path}
    else
      _ -> {:error, :failed, "Redfish reset action target is outside the selected System"}
    end
  end

  defp action_path(_state, _target), do: {:error, :failed, "Redfish reset action is invalid"}

  defp resource_path(state, target) when is_binary(target) do
    case RedfishURI.from_link(state.endpoint, target) do
      {:ok, path} -> {:ok, path}
      {:error, _reason} -> {:error, :failed, "Redfish resource URI is outside the BMC origin"}
    end
  end

  defp resource_path(_state, _target), do: {:error, :failed, "Redfish resource URI is invalid"}

  defp power_state(%{"PowerState" => "On"}), do: {:ok, "on"}
  defp power_state(%{"PowerState" => "Off"}), do: {:ok, "off"}
  defp power_state(_system), do: {:error, :failed, "Redfish PowerState is unavailable"}

  defp request(state, method, path, body, extra_headers \\ [], transfer \\ %{}, invocation \\ %{}) do
    host = URI.parse(state.endpoint).host

    options = [
      method: method,
      url: state.endpoint <> path,
      auth: state.auth,
      headers:
        [
          {"accept", Map.get(transfer, "accept", "application/json")},
          {"content-type", Map.get(transfer, "content_type", "application/json")},
          {"accept-encoding", "identity"}
        ] ++ extra_headers,
      connect_options: [
        timeout: state.timeout,
        transport_opts: HTTPS.custom_trust_options(state.cacerts, host)
      ],
      receive_timeout: state.timeout,
      retry: false,
      redirect: false,
      raw: true,
      into: fn {:data, data}, {req, response} ->
        accumulated = if is_binary(response.body), do: response.body, else: ""

        if byte_size(accumulated) + byte_size(data) <= 65_536 do
          {:cont, {req, %{response | body: accumulated <> data}}}
        else
          {:halt, {req, %{response | body: :too_large}}}
        end
      end
    ]

    body = if is_map(body), do: Jason.encode!(body), else: body

    case Skopos.Transports.HTTP.request(options, body, transfer["response_file"], invocation) do
      {:ok,
       %Req.Response{status: status, headers: headers, private: %{skopos_file: file}} = response}
      when status in 200..299 ->
        {:ok, status, headers,
         {:file, file, List.first(Req.Response.get_header(response, "content-type")) || "",
          Enum.join(Req.Response.get_header(response, "content-encoding"), ",")}}

      {:ok, %Req.Response{status: status, headers: headers, body: raw}}
      when is_binary(raw) and byte_size(raw) <= 65_536 ->
        cond do
          status in 200..299 ->
            decoded = if raw == "", do: %{}, else: Jason.decode(raw)

            case decoded do
              {:ok, value} when is_map(value) ->
                {:ok, status, headers, value}

              %{} = value ->
                {:ok, status, headers, value}

              _ ->
                if transfer["task_monitor"] == true do
                  {:ok, status, headers, %{}}
                else
                  {:error, response_failure_category(method),
                   "Redfish response is not a JSON object"}
                end
            end

          transfer["task_monitor"] == true ->
            {:ok, status, headers, %{}}

          status in [401, 403] ->
            {:error, :authentication, "Redfish authentication failed"}

          status == 412 ->
            {:error, :rejected, "Redfish write precondition failed (HTTP 412)"}

          true ->
            {:error, :rejected, "Redfish request was rejected (HTTP #{status})"}
        end

      {:ok, _response} ->
        {:error, response_failure_category(method), "Redfish response exceeded its limit"}

      {:error, :retryable, message} ->
        {:error, :transport, message}

      {:error, :cancelled, _message} ->
        {:error, :cancelled, "Redfish response was cancelled after dispatch"}

      {:error, category, message} ->
        {:error, category, message}

      {:error, %{errors: errors}} = error when is_list(errors) ->
        error

      {:error, %Target.BeforeSendError{}} = error ->
        error
    end
  rescue
    _ -> {:error, :transport, "Redfish request failed"}
  end

  defp response_failure_category(method) when method in [:get, :head], do: :failed
  defp response_failure_category(_method), do: :transport

  defp endpoint(value) when is_binary(value) and byte_size(value) <= 255 do
    case URI.parse(value) do
      %URI{scheme: "https", host: host, path: path, userinfo: nil, query: nil, fragment: nil} =
          uri
      when is_binary(host) and host != "" and path in [nil, ""] and
             (is_nil(uri.port) or uri.port in 1..65_535) ->
        {:ok, value}

      _ ->
        {:error, :invalid_endpoint}
    end
  end

  defp endpoint(_value), do: {:error, :invalid_endpoint}

  defp system_path(path) when is_binary(path) and byte_size(path) <= 512 do
    if Regex.match?(~r{^/redfish/v1/Systems/[A-Za-z0-9._~-]+$}, path),
      do: {:ok, path},
      else: {:error, :invalid_system_path}
  end

  defp system_path(_path), do: {:error, :invalid_system_path}

  defp system_identity(configuration) do
    case {configuration["system_path"], configuration["expected_uuid"]} do
      {nil, nil} ->
        {:ok, nil, nil}

      {path, uuid} ->
        with {:ok, path} <- system_path(path),
             {:ok, uuid} <- required_string(uuid, 128),
             do: {:ok, path, uuid}
    end
  end

  defp required_string(value, max) when is_binary(value) do
    if byte_size(value) in 1..max, do: {:ok, value}, else: {:error, :invalid_string}
  end

  defp required_string(_value, _max), do: {:error, :invalid_string}

  defp not_cancelled(%{cancelled?: callback}) when is_function(callback, 0) do
    if callback.(), do: {:error, :cancelled, "Redfish request was cancelled"}, else: :ok
  rescue
    cause -> {:error, Target.BeforeSendError.exception(cause: cause)}
  catch
    kind, reason ->
      {:error,
       Target.BeforeSendError.exception(cause: ErlangError.exception(original: {kind, reason}))}
  end

  defp not_cancelled(_invocation), do: :ok

  defp read_error(:transport, message), do: {:error, :retryable, message}
  defp read_error(:cancelled, message), do: {:error, :cancelled, message}
  defp read_error(_category, message), do: {:error, :failed, message}
end
