defmodule Skopos.Targets.Adapters.RESTCONF do
  @moduledoc false
  @behaviour Skopos.Providers.Adapter
  @behaviour Skopos.Providers.Target
  alias Skopos.Providers.Target
  alias Skopos.Transports.RESTCONF, as: Transport
  @read "request.restconf.observe"
  @effect "request.restconf.effect"
  @owned_headers ~w(host content-length transfer-encoding authorization proxy-authorization cookie accept content-type accept-encoding last-event-id)
  @methods %{
    "GET" => :get,
    "HEAD" => :head,
    "OPTIONS" => :options
  }
  @impl Skopos.Providers.Adapter
  def type, do: "restconf"
  @impl Skopos.Providers.Adapter
  def kind, do: :target
  @impl Skopos.Providers.Adapter
  defdelegate build(configuration, credentials), to: Transport

  @impl Skopos.Providers.Target
  def bind_connection(state, %Target.Connection{endpoint: endpoint}) do
    with {:ok, _endpoint} <- Transport.endpoint(endpoint), do: {:ok, state}
  end

  @impl Skopos.Providers.Target
  def access_method_profile,
    do: %Target.AccessMethodProfile{method: "restconf", capabilities: [@read, @effect]}

  @impl Skopos.Providers.Adapter
  def check(state, %{"endpoint" => endpoint}) do
    case Transport.check(state, endpoint) do
      :ok -> :ok
      {:error, :authentication, message} -> {:error, :authentication, message}
      {:error, :capability, message} -> {:error, :capability, message}
      {:error, _category, message} -> {:error, :unreachable, message}
    end
  end

  def check(_state, _input),
    do: {:error, :invalid_configuration, "RESTCONF check requires an endpoint"}

  @impl Skopos.Providers.Target
  def capabilities(_state, _invocation) do
    output = %{
      "type" => "object",
      "properties" => %{
        "http_status" => %{"type" => "integer"},
        "content_type" => %{"type" => "string"},
        "body" => %{"type" => "string"},
        "file" => Target.FileReference.schema(),
        "content_encoding" => %{"type" => "string"},
        "etag" => %{"type" => "string", "maxLength" => 2_048},
        "location" => %{"type" => "string", "maxLength" => 2_048},
        "completion_reason" => %{"type" => "string", "enum" => ~w(eof byte_limit duration_limit)},
        "notifications" => %{
          "type" => "object",
          "properties" => %{
            "event_count" => %{"type" => "integer", "minimum" => 0},
            "last_notification_id" => %{
              "type" => ["string", "null"],
              "description" =>
                "ID supplied by the last complete decoded notification, not a guarantee of server replay support."
            },
            "partial_event" => %{"type" => "boolean"},
            "error" => %{"type" => ["object", "null"]}
          },
          "required" => ~w(event_count last_notification_id partial_event error),
          "additionalProperties" => false
        }
      },
      "required" => ["http_status", "content_type", "body"],
      "additionalProperties" => false
    }

    {:ok,
     %Target.Capabilities{
       observations: [
         %Target.Operation{
           capability: @read,
           operation: "request.observe",
           description:
             "Read an exact root-relative RESTCONF path or same-origin advertised URI; capture preserves bounded notifications and arbitrary media in a file",
           input_schema: schema(:observation),
           output_schema: output,
           verification_schema: output
         }
       ],
       effects: [
         %Target.Operation{
           capability: @effect,
           operation: "request.execute",
           description:
             "Send an exact root-relative path or same-origin URI, protocol verb, headers and literal or file body after authority review; sampled replies leave effects unknown",
           input_schema: schema(:effect)
         }
       ]
     }}
  end

  @impl Skopos.Providers.Target
  def classify_request(state, request) do
    with {:ok, operation} <- operation(state, request) do
      {:ok, if(operation.method in [:get, :head, :options], do: :observation, else: :effect)}
    end
  end

  @impl Skopos.Providers.Target
  def observe(state, request, invocation) do
    with {:ok, operation} <- operation(state, request),
         true <- operation.method in [:get, :head, :options],
         {:ok, response} <-
           Transport.request(
             state,
             request.connection.endpoint,
             operation,
             invocation,
             :read
           ),
         :ok <- accepted(response) do
      {:ok,
       %Target.Observation{
         facts: facts(response),
         observed_at: DateTime.utc_now(),
         evidence: [%{"source" => "restconf", "path" => operation.uri || operation.path}]
       }}
    else
      false -> {:error, :failed, "RESTCONF observation request is invalid"}
      {:error, _category, _message} = error -> read_error(error)
      {:error, _cause} = error -> error
    end
  end

  @impl Skopos.Providers.Target
  def effect(state, request, invocation) do
    with {:ok, operation} <- operation(state, request),
         true <- operation.method not in [:get, :head, :options] do
      case Transport.request(
             state,
             request.connection.endpoint,
             operation,
             invocation,
             :effect
           ) do
        {:ok, response} ->
          status =
            cond do
              Map.get(response, :completion_reason) in ~w(byte_limit duration_limit) -> :unknown
              response.status == 202 -> :unknown
              response.status in 200..299 -> :applied
              response.status in 400..599 -> :failed
              true -> :unknown
            end

          {:ok,
           %Target.EffectResult{
             status: status,
             reference: request.operation,
             details: facts(response)
           }}

        {:error, :unknown_after_dispatch, message} ->
          {:ok,
           %Target.EffectResult{
             status: :unknown,
             reference: request.operation,
             details: %{"reason" => message}
           }}

        {:error, :cancelled, _message} = error ->
          error

        {:error, _category, message} ->
          {:error, :failed, message}

        {:error, _cause} = error ->
          error
      end
    else
      _ -> {:error, :failed, "RESTCONF effect request is invalid"}
    end
  end

  @impl Skopos.Providers.Target
  def verify(state, request, invocation) do
    with {:ok, observation} <- observe(state, request, invocation) do
      status =
        cond do
          map_size(request.expected) == 0 ->
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

  defp operation(state, request) do
    parameters = request.parameters
    read? = request.capability == @read and request.operation == "request.observe"
    write? = request.capability == @effect and request.operation == "request.execute"

    with true <- request.selectors == %{} and (read? or write?),
         true <-
           Enum.all?(
             Map.keys(parameters),
             &(&1 in ~w(method path uri query body body_file headers accept content_type response_file capture last_event_id))
           ),
         true <- Target.FileWriter.valid_options?(parameters["response_file"]),
         {:ok, _endpoint} <- Transport.endpoint(request.connection.endpoint),
         {:ok, method} <- request_method(parameters["method"]),
         true <-
           (read? and method in [:get, :head, :options]) or
             (write? and method not in [:get, :head, :options]),
         true <- location?(request.connection.endpoint, parameters),
         true <- capture?(parameters, state.request_timeout),
         true <- event_id?(parameters["last_event_id"]),
         {:ok, headers} <-
           Skopos.Transports.HTTP.request_headers(
             Map.get(parameters, "headers", %{}),
             @owned_headers
           ),
         {:ok, body} <-
           request_body(parameters, Map.get(request, :files, %{}), state.max_body_bytes),
         true <- not read? or is_nil(body),
         query <- Map.get(parameters, "query", %{}),
         true <- is_map(query) and map_size(query) <= 100,
         true <-
           Enum.all?(query, fn {key, value} ->
             is_binary(key) and is_binary(value) and byte_size(key) <= 255 and
               byte_size(value) <= 2048
           end),
         accept <- Map.get(parameters, "accept", "application/yang-data+json"),
         content_type <- Map.get(parameters, "content_type", "application/yang-data+json"),
         true <- media?(accept) and media?(content_type) do
      {:ok,
       %{
         method: method,
         path: parameters["path"],
         uri: parameters["uri"],
         body: body,
         query: query,
         accept: accept,
         content_type: content_type,
         response_file: parameters["response_file"],
         capture: parameters["capture"],
         last_event_id: parameters["last_event_id"],
         headers: headers
       }}
    else
      _ -> {:error, :failed, "RESTCONF request is invalid"}
    end
  rescue
    _ -> {:error, :failed, "RESTCONF request is invalid"}
  end

  defp request_method(verb) when is_binary(verb) and byte_size(verb) in 1..64 do
    if Regex.match?(~r/\A[!#$%&'*+.^_`|~0-9A-Za-z-]+\z/, verb),
      do: {:ok, Map.get(@methods, verb, verb)},
      else: {:error, :invalid_method}
  end

  defp request_method(_), do: {:error, :invalid_method}

  defp location?(endpoint, %{"uri" => uri} = parameters),
    do:
      not Map.has_key?(parameters, "path") and
        match?({:ok, _}, Transport.resource_uri(endpoint, uri))

  defp location?(_endpoint, parameters), do: Transport.path?(parameters["path"])

  defp capture?(
         %{
           "capture" => %{"duration_ms" => duration, "max_bytes" => bytes} = capture,
           "response_file" => file
         },
         timeout
       ),
       do:
         map_size(capture) == 2 and is_map(file) and is_integer(duration) and
           duration in 1..timeout and is_integer(bytes) and bytes > 0

  defp capture?(%{"capture" => _}, _timeout), do: false

  defp capture?(%{"accept" => accept}, _timeout) when is_binary(accept),
    do:
      accept |> String.split(";", parts: 2) |> hd() |> String.trim() |> String.downcase() !=
        "text/event-stream"

  defp capture?(_parameters, _timeout), do: true

  defp event_id?(nil), do: true

  defp event_id?(id) when is_binary(id) and byte_size(id) <= 2_048,
    do: String.valid?(id) and not Regex.match?(~r/[\x00-\x1f\x7f]/, id)

  defp event_id?(_), do: false

  defp request_body(%{"body_file" => label} = parameters, files, _limit) do
    with false <- Map.has_key?(parameters, "body"),
         true <- is_binary(label),
         {:ok, reference} <- Map.fetch(files, label),
         true <- Target.FileReference.valid?(reference),
         do: {:ok, {:file, label, reference}},
         else: (_ -> {:error, :invalid_body})
  end

  defp request_body(parameters, _files, limit) do
    body = parameters["body"]

    if is_nil(body) or (is_binary(body) and String.valid?(body) and byte_size(body) <= limit),
      do: {:ok, body},
      else: {:error, :invalid_body}
  end

  defp facts(response) do
    facts = %{
      "http_status" => response.status,
      "content_type" => response.headers |> Map.get("content-type", [""]) |> List.first(),
      "body" => response.body
    }

    facts =
      if response[:notifications],
        do: Map.put(facts, "notifications", response.notifications),
        else: facts

    facts =
      Enum.reduce(["etag", "location"], facts, fn name, facts ->
        case Map.get(response.headers, name) do
          [value] when is_binary(value) and byte_size(value) <= 2_048 ->
            if String.valid?(value), do: Map.put(facts, name, value), else: facts

          _ ->
            facts
        end
      end)

    case response do
      %{file: file, completion_reason: reason, content_encoding: encoding} ->
        facts
        |> Map.put("file", file)
        |> Map.put("completion_reason", reason)
        |> Map.put("content_encoding", encoding)

      _ ->
        facts
    end
  end

  defp media?(value) when is_binary(value) and byte_size(value) in 1..256,
    do: String.contains?(value, "/") and Regex.match?(~r/\A[\x20-\x7e]+\z/, value)

  defp media?(_), do: false

  defp accepted(%{status: status}) when status in 200..299, do: :ok

  defp accepted(%{status: status}),
    do: {:error, :failed, "RESTCONF request rejected (HTTP #{status})"}

  defp read_error({:error, category, message}) when category in [:timeout, :cancelled, :failed],
    do: {:error, category, message}

  defp read_error({:error, _category, message}), do: {:error, :retryable, message}

  defp schema(kind) do
    method = %{
      "type" => "string",
      "minLength" => 1,
      "maxLength" => 64,
      "pattern" => "^[!#$%&'*+.^_`|~0-9A-Za-z-]+$"
    }

    method =
      if kind == :observation,
        do: Map.put(method, "enum", ~w(GET HEAD OPTIONS)),
        else: Map.put(method, "not", %{"enum" => ~w(GET HEAD OPTIONS)})

    %{
      "type" => "object",
      "properties" => %{
        "selectors" => %{"type" => "object", "additionalProperties" => false},
        "parameters" => %{
          "type" => "object",
          "properties" => %{
            "method" => method,
            "path" => %{"type" => "string", "minLength" => 1, "maxLength" => 2048},
            "uri" => %{"type" => "string", "minLength" => 1, "maxLength" => 2048},
            "body" => %{"type" => ["string", "null"], "maxLength" => 60_000},
            "body_file" => %{"type" => "string", "minLength" => 1, "maxLength" => 120},
            "files" => Target.FileReference.set_schema(),
            "query" => %{"type" => "object", "additionalProperties" => %{"type" => "string"}},
            "accept" => %{"type" => "string", "maxLength" => 256},
            "content_type" => %{"type" => "string", "maxLength" => 256},
            "response_file" => Target.FileWriter.options_schema(),
            "last_event_id" => %{"type" => "string", "maxLength" => 2048},
            "headers" => %{
              "type" => "object",
              "maxProperties" => 8,
              "additionalProperties" => %{"type" => "string", "maxLength" => 1024}
            },
            "capture" => %{
              "type" => "object",
              "properties" => %{
                "duration_ms" => %{"type" => "integer", "minimum" => 1, "maximum" => 600_000},
                "max_bytes" => %{"type" => "integer", "minimum" => 1}
              },
              "required" => ~w(duration_ms max_bytes),
              "additionalProperties" => false
            }
          },
          "required" => ["method"],
          "oneOf" => [
            %{"required" => ["path"], "not" => %{"required" => ["uri"]}},
            %{"required" => ["uri"], "not" => %{"required" => ["path"]}}
          ],
          "additionalProperties" => false
        }
      },
      "required" => ["selectors", "parameters"],
      "additionalProperties" => false
    }
  end
end
