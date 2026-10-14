defmodule Skopos.Targets.Adapters.Kubernetes do
  @moduledoc false
  @behaviour Skopos.Providers.Adapter
  @behaviour Skopos.Providers.Target

  alias Skopos.Providers.Target
  alias Skopos.Transports.Kubernetes, as: Client
  alias Skopos.Transports.Kubernetes.State
  alias Skopos.Targets.Adapters.Kubernetes.Session

  @observe "request.kubernetes.observe"
  @effect "request.kubernetes.effect"
  @methods %{
    "GET" => :get,
    "HEAD" => :head,
    "POST" => :post,
    "PUT" => :put,
    "PATCH" => :patch,
    "DELETE" => :delete
  }
  @max_body_bytes 65_536

  @impl Skopos.Providers.Adapter
  def type, do: "kubernetes-api"
  @impl Skopos.Providers.Adapter
  def kind, do: :target
  @impl Skopos.Providers.Adapter
  def build(configuration, credentials), do: Client.build(configuration, credentials)
  @impl Skopos.Providers.Adapter
  def check(state, input), do: Client.check(state, input)

  @impl Skopos.Providers.Target
  def bind_connection(state, %Target.Connection{endpoint: endpoint}) do
    case Client.endpoint(state, endpoint) do
      :ok -> {:ok, state}
      {:error, _category, message} -> {:error, :failed, message}
    end
  end

  @impl Skopos.Providers.Target
  def access_method_profile do
    %Target.AccessMethodProfile{method: "api", capabilities: [@observe, @effect]}
  end

  @impl Skopos.Providers.Target
  def capabilities(state, _invocation) do
    scope =
      if state && state.namespace,
        do: " Namespace boundary: #{state.namespace}.",
        else: " Scope: the registered API endpoint, subject to Kubernetes RBAC."

    output = %{
      "type" => "object",
      "properties" => %{
        "response" => %{},
        "http_status" => %{"type" => "integer"},
        "content_type" => %{"type" => "string"},
        "file" => Target.FileReference.schema(),
        "content_encoding" => %{"type" => "string"},
        "watch" => %{
          "type" => "object",
          "properties" => %{
            "event_count" => %{
              "type" => "integer",
              "minimum" => 0,
              "description" =>
                "Number of complete decoded JSON events; exact event bytes remain in the file."
            },
            "resource_version" => %{"type" => ["string", "null"]},
            "partial_event" => %{"type" => "boolean"},
            "resume_strategy" => %{
              "type" => "string",
              "enum" => ["cursor", "list", "unavailable"]
            },
            "error" => %{"type" => ["object", "null"]}
          },
          "required" => [
            "event_count",
            "resource_version",
            "partial_event",
            "resume_strategy",
            "error"
          ],
          "additionalProperties" => false
        },
        "completion_reason" => %{
          "type" => "string",
          "enum" => ["eof", "byte_limit", "duration_limit", "event_limit"]
        }
      },
      "required" => ["response", "http_status", "content_type"],
      "additionalProperties" => false
    }

    {:ok,
     %Target.Capabilities{
       observations: [
         %Target.Operation{
           capability: @observe,
           operation: "request.observe",
           description:
             "Read an exact Kubernetes API path, including discovery and subresources." <> scope,
           input_schema: schema(["GET", "HEAD"]),
           output_schema: output,
           verification_schema: %{output | "required" => []}
         }
       ],
       effects: [
         %Target.Operation{
           capability: @effect,
           operation: "request.execute",
           description:
             "Send an exact Kubernetes API HTTP request after review. Bodies can be literal UTF-8 strings or immutable files; response_file preserves full binary results." <>
               scope,
           input_schema: schema(["POST", "PUT", "PATCH", "DELETE"])
         },
         Session.effect()
       ]
     }}
  end

  @impl Skopos.Providers.Target
  def classify_request(%State{} = state, request) do
    with {:ok, operation} <- exact_request(state, request), do: {:ok, operation.kind}
  end

  def classify_request(_state, _request), do: invalid()

  @impl Skopos.Providers.Target
  def observe(%State{} = state, request, invocation) do
    with {:ok, %{kind: :observation} = operation} <- exact_request(state, request),
         {:ok, response} <- Client.run(state, operation, invocation, :read),
         :ok <- read_status(response) do
      {:ok, %Target.Observation{facts: facts(response), observed_at: DateTime.utc_now()}}
    else
      {:ok, _effect} -> invalid()
      error -> error
    end
  end

  def observe(_state, _request, _invocation), do: invalid()

  @impl Skopos.Providers.Target
  def effect(%State{} = state, request, invocation) do
    with {:ok, %{kind: :effect} = operation} <- exact_request(state, request) do
      execute_effect(state, operation, invocation)
    else
      {:ok, _observation} -> invalid()
      error -> error
    end
  end

  def effect(_state, _request, _invocation), do: invalid()

  defp execute_effect(state, %{transport: :websocket} = operation, invocation),
    do: Skopos.Transports.Kubernetes.Session.request(state, operation, invocation)

  defp execute_effect(state, operation, invocation) do
    case Client.run(state, operation, invocation, :effect) do
      {:ok, response} ->
        body = response.body
        reference = if is_map(body), do: get_in(body, ["metadata", "resourceVersion"])

        {:ok,
         %Target.EffectResult{
           status:
             cond do
               Map.get(response, :completion_reason) in ~w(byte_limit duration_limit event_limit) ->
                 :unknown

               response.status in 200..299 ->
                 :applied

               true ->
                 :failed
             end,
           reference: reference,
           details:
             Map.put(facts(response), "category", to_string(status_category(response.status)))
         }}

      {:error, :unknown_after_dispatch, message} ->
        {:ok, %Target.EffectResult{status: :unknown, details: %{"error" => message}}}

      error ->
        error
    end
  end

  @impl Skopos.Providers.Target
  def verify(%State{} = state, request, invocation) do
    with {:ok, observation} <- observe(state, request, invocation) do
      status =
        cond do
          request.expected == %{} ->
            :unknown

          Enum.all?(request.expected, fn {key, value} -> observation.facts[key] == value end) ->
            :verified

          true ->
            :not_verified
        end

      {:ok,
       %Target.Verification{
         status: status,
         facts: observation.facts,
         observed_at: observation.observed_at
       }}
    end
  end

  def verify(_state, _request, _invocation), do: invalid()

  defp exact_request(state, %{operation: "websocket.session", capability: @effect} = request) do
    with :ok <- Client.endpoint(state, request.connection.endpoint),
         true <- request.selectors == %{},
         :ok <- path_scope(request.parameters["path"], state.namespace, :effect, :websocket),
         {:ok, operation} <- Session.compile(request) do
      {:ok, operation}
    else
      _ -> invalid()
    end
  end

  defp exact_request(state, request) do
    with :ok <- Client.endpoint(state, request.connection.endpoint),
         true <- request.selectors == %{},
         %{"method" => verb, "path" => path} = parameters <- request.parameters,
         true <-
           Enum.all?(
             Map.keys(parameters),
             &(&1 in ~w(method path query body body_file content_type accept response_file capture))
           ),
         true <- Target.FileWriter.valid_options?(parameters["response_file"]),
         {:ok, method} <- Map.fetch(@methods, verb),
         {:ok, kind} <- request_kind(request, method),
         :ok <- path_scope(path, state.namespace, kind),
         {:ok, query} <- query(Map.get(parameters, "query", %{})),
         true <- valid_capture?(parameters, state.request_timeout),
         {:ok, content_type} <-
           media_type(Map.get(parameters, "content_type", "application/json")),
         {:ok, accept} <- media_type(Map.get(parameters, "accept", "application/json")),
         {:ok, body} <-
           request_body(kind, parameters, content_type, Map.get(request, :files, %{})),
         :ok <- body_scope(state.namespace, body, content_type) do
      {:ok,
       %{
         kind: kind,
         method: method,
         path: path,
         query: query,
         body: body,
         response_file: parameters["response_file"],
         capture: parameters["capture"],
         headers: [{"content-type", content_type}, {"accept", accept}]
       }}
    else
      _ -> invalid()
    end
  rescue
    _ -> invalid()
  end

  defp request_kind(%{capability: @observe, operation: "request.observe"}, method)
       when method in [:get, :head], do: {:ok, :observation}

  defp request_kind(%{capability: @effect, operation: "request.execute"}, method)
       when method in [:post, :put, :patch, :delete], do: {:ok, :effect}

  defp request_kind(_request, _method), do: invalid()

  defp path_scope(path, namespace, kind, transport \\ :http)

  defp path_scope(path, namespace, kind, transport)
       when is_binary(path) and byte_size(path) in 1..2_048 do
    uri = URI.parse(path)
    parts = String.split(path, "/", trim: true)

    canonical? =
      String.starts_with?(path, "/") and not String.contains?(path, ["//", "\\"]) and
        not Regex.match?(~r/[\s\x00-\x1f\x7f]|%(?:25|2e|2f|5c|0[0-9a-f]|1[0-9a-f]|7f)/i, path) and
        Enum.all?(parts, &(&1 not in [".", ".."])) and
        Enum.all?([uri.scheme, uri.host, uri.userinfo, uri.fragment, uri.query], &is_nil/1)

    supported? =
      case parts do
        ["api", _version, "namespaces", selected | rest] when rest != [] ->
          (is_nil(namespace) or selected == namespace) and resource_path?(rest, transport)

        ["apis", _group, _version, "namespaces", selected | rest] when rest != [] ->
          (is_nil(namespace) or selected == namespace) and resource_path?(rest, transport)

        ["api"] ->
          kind == :observation

        ["api", _version] ->
          kind == :observation

        ["apis"] ->
          kind == :observation

        ["apis", _group] ->
          kind == :observation

        ["apis", _group, _version] ->
          kind == :observation

        ["version"] ->
          kind == :observation

        ["openapi" | _rest] ->
          kind == :observation

        ["api", _version | rest] ->
          is_nil(namespace) and resource_path?(rest, transport)

        ["apis", _group, _version | rest] ->
          is_nil(namespace) and resource_path?(rest, transport)

        _ ->
          false
      end

    if canonical? and supported?, do: :ok, else: invalid()
  end

  defp path_scope(_path, _namespace, _kind, _transport), do: invalid()

  # These Kubernetes protocol subresources require a maintained connection;
  # they cannot be admitted as an ordinary bounded HTTP observation.
  defp resource_path?([_resource, _name, subresource | _rest], :http)
       when subresource in ["exec", "attach", "portforward", "proxy"], do: false

  defp resource_path?(parts, _transport), do: parts != []

  defp query(query) when is_map(query) and map_size(query) <= 32 do
    if Enum.all?(query, fn {key, value} ->
         is_binary(key) and byte_size(key) in 1..120 and is_binary(value) and
           byte_size(value) <= 2_048 and String.valid?(value) and
           not Regex.match?(~r/[\x00-\x1f\x7f]/, key <> value)
       end) do
      {:ok, Map.to_list(query)}
    else
      invalid()
    end
  end

  defp query(_query), do: invalid()

  defp valid_capture?(parameters, timeout) do
    watch? =
      String.downcase(get_in(parameters, ["query", "watch"]) || "false") in ["true", "t", "1"]

    capture = parameters["capture"]

    cond do
      is_nil(capture) ->
        not watch?

      not is_map(capture) or not is_map(parameters["response_file"]) ->
        false

      true ->
        keys =
          if watch?, do: ~w(duration_ms max_bytes max_events), else: ~w(duration_ms max_bytes)

        Enum.sort(Map.keys(capture)) == Enum.sort(keys) and
          is_integer(capture["duration_ms"]) and capture["duration_ms"] in 1..timeout and
          is_integer(capture["max_bytes"]) and capture["max_bytes"] > 0 and
          (not watch? or (is_integer(capture["max_events"]) and capture["max_events"] in 1..4_096))
    end
  end

  defp media_type(value) when is_binary(value) and byte_size(value) in 1..256 do
    if String.contains?(value, "/") and Regex.match?(~r/\A[\x20-\x7e]+\z/, value),
      do: {:ok, value},
      else: invalid()
  end

  defp media_type(_value), do: invalid()

  defp request_body(:effect, %{"body_file" => label} = parameters, _type, files) do
    with false <- Map.has_key?(parameters, "body"),
         true <- is_binary(label),
         {:ok, reference} <- Map.fetch(files, label),
         true <- Target.FileReference.valid?(reference) do
      {:ok, {:file, label, reference}}
    else
      _ -> invalid()
    end
  end

  defp request_body(kind, parameters, type, _files) do
    if Map.has_key?(parameters, "body_file"),
      do: invalid(),
      else: body(kind, parameters["body"], type)
  end

  defp body(_kind, nil, _type), do: {:ok, nil}

  defp body(:effect, body, type) when is_binary(body) and byte_size(body) <= @max_body_bytes do
    json? =
      type
      |> String.split(";")
      |> hd()
      |> String.trim()
      |> String.downcase()
      |> String.ends_with?(["/json", "+json"])

    if String.valid?(body) and (not json? or match?({:ok, _}, Jason.decode(body))),
      do: {:ok, body},
      else: invalid()
  end

  defp body(_kind, _body, _type), do: invalid()

  defp body_scope(nil, _body, _type), do: :ok
  defp body_scope(_namespace, nil, _type), do: :ok

  # File contents stay opaque. The exact URL enforces the configured namespace;
  # the API server checks a resource's body namespace against that URL.
  defp body_scope(_namespace, {:file, _label, _reference}, _type), do: :ok

  defp body_scope(namespace, body, type) do
    media = type |> String.split(";") |> hd() |> String.trim() |> String.downcase()

    decoded =
      cond do
        String.ends_with?(media, ["/json", "+json"]) -> Jason.decode(body)
        String.ends_with?(media, ["/yaml", "+yaml"]) -> YamlElixir.read_from_string(body)
        true -> {:ok, nil}
      end

    case decoded do
      {:ok, %{"metadata" => %{"namespace" => selected}}}
      when selected not in [nil, "", namespace] ->
        invalid()

      {:ok, _body} ->
        :ok

      _error ->
        invalid()
    end
  end

  defp schema(methods) do
    properties = %{
      "method" => %{"type" => "string", "enum" => methods},
      "path" => %{"type" => "string", "minLength" => 1, "maxLength" => 2_048},
      "query" => %{
        "type" => "object",
        "maxProperties" => 32,
        "additionalProperties" => %{"type" => "string", "maxLength" => 2_048}
      },
      "content_type" => %{"type" => "string", "maxLength" => 256},
      "accept" => %{"type" => "string", "maxLength" => 256},
      "response_file" => Target.FileWriter.options_schema(),
      "capture" => %{
        "type" => "object",
        "properties" => %{
          "duration_ms" => %{"type" => "integer", "minimum" => 1, "maximum" => 30_000},
          "max_bytes" => %{"type" => "integer", "minimum" => 1},
          "max_events" => %{"type" => "integer", "minimum" => 1, "maximum" => 4_096}
        },
        "required" => ["duration_ms", "max_bytes"],
        "additionalProperties" => false
      }
    }

    properties =
      if "PATCH" in methods,
        do:
          properties
          |> Map.put("body", %{
            "type" => ["string", "null"],
            "maxLength" => @max_body_bytes
          })
          |> Map.put("body_file", %{"type" => "string", "minLength" => 1, "maxLength" => 120})
          |> Map.put("files", Target.FileReference.set_schema()),
        else: properties

    %{
      "type" => "object",
      "properties" => %{
        "selectors" => %{"type" => "object", "maxProperties" => 0},
        "parameters" => %{
          "type" => "object",
          "properties" => properties,
          "required" => ["method", "path"],
          "additionalProperties" => false
        }
      },
      "required" => ["selectors", "parameters"],
      "additionalProperties" => false
    }
  end

  defp facts(response) do
    facts = %{
      "response" => response.body,
      "http_status" => response.status,
      "content_type" => response.content_type
    }

    facts = if response[:watch], do: Map.put(facts, "watch", response.watch), else: facts

    case response do
      %{file: file, content_encoding: encoding, completion_reason: reason} ->
        facts
        |> Map.put("file", file)
        |> Map.put("content_encoding", encoding)
        |> Map.put("completion_reason", reason)

      _ ->
        facts
    end
  end

  defp read_status(%{status: status}) when status in 200..299, do: :ok

  defp read_status(%{status: 410, watch: %{"error" => %{"code" => 410}}}), do: :ok

  defp read_status(%{status: status}),
    do:
      {:error, read_category(status_category(status)),
       "Kubernetes API rejected request (HTTP #{status})"}

  defp read_category(:not_found), do: :retryable
  defp read_category(_category), do: :failed
  defp status_category(409), do: :conflict
  defp status_category(401), do: :authentication
  defp status_category(403), do: :forbidden
  defp status_category(404), do: :not_found
  defp status_category(status) when status in 200..299, do: :applied
  defp status_category(_status), do: :api_rejected
  defp invalid, do: {:error, :failed, "Kubernetes API request is invalid"}
end
