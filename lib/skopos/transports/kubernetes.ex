defmodule Skopos.Transports.Kubernetes do
  @moduledoc false

  @configuration_keys ~w(namespace request_timeout_ms)
  @credential_keys ~w(kubeconfig)
  @name_pattern ~r/^[a-z0-9]([-a-z0-9.]*[a-z0-9])?$/

  defmodule State do
    @moduledoc false
    @enforce_keys [:connection, :namespace, :endpoint, :request_timeout]
    defstruct @enforce_keys
  end

  defmodule Watch do
    @moduledoc false
    alias Skopos.Providers.Target
    @max_frame_bytes 1_048_576

    # Interpret a completed bounded file through the supplied receipt reader.
    # The file remains the source for exact event content and order.
    def read(response, reader, query) do
      if json?(response.content_type, response.content_encoding) do
        read_events(response, reader, query)
      else
        {:ok,
         %{
           "event_count" => 0,
           "resource_version" => nil,
           "partial_event" => true,
           "resume_strategy" => "unavailable",
           "error" => %{"reason" => "unsupported_framing"}
         }}
      end
    end

    def limit(bytes, response, maximum) do
      media = List.first(Req.Response.get_header(response, "content-type")) || ""
      encoding = Enum.join(Req.Response.get_header(response, "content-encoding"), ",")

      if json?(media, encoding) do
        previous = Map.get(response.private, :skopos_watch_events, 0)
        positions = :binary.matches(bytes, "\n")
        remaining = maximum - previous
        boundary = Enum.at(positions, remaining - 1)
        count = previous + min(length(positions), remaining)
        private = Map.put(response.private, :skopos_watch_events, count)

        if boundary do
          {position, 1} = boundary
          private = Map.put(private, :skopos_completion_reason, :event_limit)
          {binary_part(bytes, 0, position + 1), %{response | private: private}}
        else
          {bytes, %{response | private: private}}
        end
      else
        {bytes, response}
      end
    end

    defp json?(media, encoding) do
      media = media |> String.split(";") |> hd() |> String.trim() |> String.downcase()

      String.ends_with?(media, ["/json", "+json"]) and
        String.downcase(encoding) in ["", "identity"]
    end

    defp read_events(response, reader, query) do
      cursor = query["resourceVersion"]
      cursor = if cursor in [nil, "", "0"], do: nil, else: cursor

      initial = %{
        "event_count" => 0,
        "resource_version" => cursor,
        "partial_event" => false,
        "error" => nil
      }

      bytes =
        Skopos.Providers.Target.FileWriter.stream(response.file, reader)
        |> Stream.map(&{:data, &1})

      result =
        bytes
        |> Stream.concat([{:end, response.completion_reason}])
        |> Stream.transform(0, &bounded_frame/2)
        |> K8s.Client.HTTPStream.transform_to_lines()
        |> Enum.reduce_while(initial, fn
          {:parse_error, reason}, state ->
            {:halt, state |> failure(%{"reason" => reason}) |> Map.put("partial_event", true)}

          next, state ->
            {:cont, event(next, state, response.status)}
        end)

      strategy =
        cond do
          get_in(result, ["error", "code"]) == 410 -> "list"
          result["resource_version"] -> "cursor"
          true -> "unavailable"
        end

      {:ok, Map.put(result, "resume_strategy", strategy)}
    catch
      {:file_read_error, %{category: :cancelled}} ->
        {:error, :cancelled, "Kubernetes watch file reading was cancelled"}

      {:file_read_error, cause} ->
        if Target.Error.context_failure?(cause) do
          {:error,
           Target.Error.context_failure(cause, %{
             "http_status" => response.status,
             "file" => response.file,
             "completion_reason" => response.completion_reason
           })}
        else
          {:error, :failed, "Kubernetes watch file is unavailable"}
        end
    end

    defp bounded_frame({:data, bytes}, previous) do
      [first | rest] = :binary.split(bytes, "\n", [:global])
      lengths = [previous + byte_size(first) | Enum.map(rest, &byte_size/1)]

      if Enum.max(lengths) > @max_frame_bytes,
        do: {[{:parse_error, "frame_too_large"}], 0},
        else: {[{:data, bytes}], List.last(lengths)}
    end

    defp bounded_frame({:end, reason}, remaining) do
      events = [{:partial, reason != "eof" and remaining > 0}]
      {if(reason == "eof", do: events ++ [:done], else: events), remaining}
    end

    defp event({:partial, value}, state, _status), do: Map.put(state, "partial_event", value)
    defp event(:done, state, _status), do: state

    defp event({:line, line}, state, status) do
      case Jason.decode(line) do
        {:ok, %{"type" => "ERROR", "object" => object}} when is_map(object) ->
          state |> Map.update!("event_count", &(&1 + 1)) |> failure(object)

        {:ok, %{"type" => type, "object" => %{"metadata" => %{"resourceVersion" => cursor}}}}
        when is_binary(type) and is_binary(cursor) and byte_size(cursor) in 1..2_048 ->
          state = Map.update!(state, "event_count", &(&1 + 1))
          if state["error"], do: state, else: Map.put(state, "resource_version", cursor)

        {:ok, %{"kind" => "Status"} = object} when status == 410 ->
          failure(state, object)

        _ ->
          failure(state, %{"reason" => "invalid_event"})
      end
    end

    defp failure(%{"error" => error} = state, _object) when not is_nil(error), do: state

    defp failure(state, object) do
      error =
        Map.take(object, ["code", "reason", "message"])
        |> Enum.flat_map(fn
          {"code", value} when is_integer(value) ->
            [{"code", value}]

          {key, value} when key in ["reason", "message"] and is_binary(value) ->
            [{key, String.slice(value, 0, 2_048)}]

          _ ->
            []
        end)
        |> Map.new()

      error = if map_size(error) == 0, do: %{"reason" => "invalid_error_event"}, else: error

      state |> Map.put("error", error) |> Map.put("resource_version", nil)
    end
  end

  def build(configuration, credentials)
      when is_map(configuration) and is_map(credentials) do
    with :ok <- exact_keys(configuration, @configuration_keys),
         :ok <- exact_keys(credentials, @credential_keys),
         {:ok, namespace} <- namespace(configuration),
         {:ok, timeout} <- timeout(configuration),
         kubeconfig when is_binary(kubeconfig) <- Map.get(credentials, "kubeconfig"),
         true <- byte_size(kubeconfig) in 1..65_536,
         :ok <- static_kubeconfig(kubeconfig),
         {:ok, connection} <- K8s.Conn.from_string(kubeconfig),
         endpoint when is_binary(endpoint) <- connection.url do
      {:ok,
       %State{
         connection: connection,
         namespace: namespace,
         endpoint: String.trim_trailing(endpoint, "/"),
         request_timeout: timeout
       }}
    else
      _error -> {:error, :invalid_configuration}
    end
  rescue
    _error -> {:error, :invalid_configuration}
  end

  def build(_configuration, _credentials), do: {:error, :invalid_configuration}

  def check(%State{} = state, %{"endpoint" => endpoint}) do
    with :ok <- endpoint(state, endpoint),
         operation <- %{
           method: :get,
           path: "/api",
           query: [],
           body: nil,
           headers: [{"accept", "application/json"}]
         },
         {:ok, %{status: status}} <- run(state, operation, %{}, :read) do
      case status do
        status when status in 200..299 -> :ok
        401 -> {:error, :authentication, "Kubernetes authentication failed"}
        403 -> {:error, :capability, "Kubernetes API discovery is forbidden"}
        _ -> {:error, :capability, "Kubernetes API rejected the connection check"}
      end
    else
      {:error, :authentication, message} -> {:error, :authentication, message}
      {:error, :forbidden, message} -> {:error, :capability, message}
      {:error, :invalid_configuration, message} -> {:error, :invalid_configuration, message}
      {:error, _category, message} -> {:error, :unreachable, message}
    end
  end

  def check(_state, _input),
    do: {:error, :invalid_configuration, "Kubernetes check requires an endpoint"}

  # Both HTTP and upgraded sessions use the same credential and TLS owner.
  def connection_options(%State{} = state) do
    with {:ok, options} <- K8s.Conn.RequestOptions.generate(state.connection) do
      host = URI.parse(state.endpoint).host

      tls =
        if state.connection.ca_cert,
          do: Skopos.Transports.HTTPS.custom_trust_options([state.connection.ca_cert], host),
          else: [
            customize_hostname_check: [
              match_fun: :public_key.pkix_verify_hostname_match_fun(:https)
            ]
          ]

      headers =
        Enum.map(options.headers, fn {key, value} -> {String.downcase(to_string(key)), value} end)

      {:ok, headers, Keyword.merge(options.ssl_options, tls)}
    end
  end

  defp request(state, operation, invocation) do
    with {:ok, headers, tls} <- connection_options(state) do
      request_options = [
        method: operation.method,
        url: state.endpoint <> operation.path,
        params: operation.query,
        headers: headers ++ operation.headers ++ [{"accept-encoding", "identity"}],
        connect_options: [
          timeout: state.request_timeout,
          transport_opts: tls
        ],
        receive_timeout: state.request_timeout,
        retry: false,
        redirect: false,
        raw: true,
        capture: Map.get(operation, :capture),
        data_limiter:
          if(get_in(operation, [:capture, "max_events"]),
            do: &Watch.limit(&1, &2, operation.capture["max_events"])
          ),
        into: &collect/2
      ]

      Skopos.Transports.HTTP.request(
        request_options,
        operation.body,
        Map.get(operation, :response_file),
        invocation
      )
    end
  end

  defp collect({:data, data}, {request, response}) do
    accumulated = if is_binary(response.body), do: response.body, else: ""

    if byte_size(accumulated) + byte_size(data) <= 65_536,
      do: {:cont, {request, %{response | body: accumulated <> data}}},
      else: {:halt, {request, %{response | body: :too_large}}}
  end

  def run(state, operation, invocation, phase) when is_map(operation) and is_map(invocation) do
    if cancelled?(invocation).() do
      {:error, :cancelled, "Kubernetes operation was cancelled"}
    else
      result = request(state, operation, invocation)

      with {:ok, response} <- normalize(result, phase) do
        if get_in(operation, [:capture, "max_events"]) do
          {:ok, raw} = result

          with {:ok, watch} <-
                 Watch.read(response, raw.private[:skopos_file_reader], Map.new(operation.query)),
               do: {:ok, Map.put(response, :watch, watch)}
        else
          {:ok, response}
        end
      end
    end
  rescue
    _error -> operation_failure(phase)
  catch
    _kind, _reason -> operation_failure(phase)
  end

  defp normalize({:ok, %Req.Response{body: :too_large}}, :effect),
    do:
      {:error, :unknown_after_dispatch,
       "Kubernetes response exceeded the inline size limit after dispatch"}

  defp normalize({:ok, %Req.Response{body: :too_large}}, _phase),
    do: {:error, :failed, "Kubernetes response exceeded the inline size limit"}

  defp normalize({:ok, %Req.Response{private: %{skopos_file: file}} = response}, _phase) do
    {:ok,
     %{
       status: response.status,
       content_type: List.first(Req.Response.get_header(response, "content-type")) || "",
       body: "",
       file: file,
       content_encoding: Enum.join(Req.Response.get_header(response, "content-encoding"), ","),
       completion_reason: Atom.to_string(response.private[:skopos_completion_reason])
     }}
  end

  defp normalize({:ok, %Req.Response{} = response}, phase) do
    raw = response.body || ""
    content_type = response |> Req.Response.get_header("content-type") |> List.first() || ""
    content_type = content_type |> String.split(";") |> hd()

    encoding = Req.Response.get_header(response, "content-encoding")
    json? = String.ends_with?(String.downcase(content_type), ["/json", "+json"])
    body = if json? and raw != "", do: Jason.decode(raw), else: {:ok, raw}

    if String.valid?(raw) and encoding in [[], ["identity"]] and match?({:ok, _}, body) do
      {:ok, %{status: response.status, content_type: content_type, body: elem(body, 1)}}
    else
      invalid_inline_response(phase)
    end
  end

  defp normalize({:error, _category, message}, :effect),
    do: {:error, :unknown_after_dispatch, message}

  defp normalize({:error, category, message}, _phase), do: {:error, category, message}

  defp normalize({:error, %{errors: errors}} = error, _phase) when is_list(errors), do: error
  defp normalize({:error, %Skopos.Providers.Target.BeforeSendError{}} = error, _phase), do: error

  defp normalize({:error, _error}, :effect),
    do: {:error, :unknown_after_dispatch, "Kubernetes effect result is unknown"}

  defp normalize({:error, _error}, _phase),
    do: {:error, :unreachable, "Kubernetes API request failed"}

  defp normalize(_result, :effect),
    do: {:error, :unknown_after_dispatch, "Kubernetes effect result is unknown"}

  defp normalize(_result, _phase),
    do: {:error, :failed, "Kubernetes API response is invalid"}

  defp invalid_inline_response(:effect),
    do:
      {:error, :unknown_after_dispatch,
       "Kubernetes did not return a valid UTF-8 inline response after dispatch"}

  defp invalid_inline_response(_phase),
    do: {:error, :failed, "Kubernetes did not return a valid UTF-8 inline response"}

  defp operation_failure(:effect),
    do: {:error, :unknown_after_dispatch, "Kubernetes effect result is unknown"}

  defp operation_failure(_phase), do: {:error, :failed, "Kubernetes operation failed"}

  def endpoint(state, endpoint) when is_binary(endpoint) do
    if String.trim_trailing(endpoint, "/") == state.endpoint,
      do: :ok,
      else: {:error, :invalid_configuration, "Kubernetes endpoint does not match kubeconfig"}
  end

  def endpoint(_state, _endpoint),
    do: {:error, :invalid_configuration, "Kubernetes endpoint is invalid"}

  defp timeout(configuration) do
    case Map.get(configuration, "request_timeout_ms", 30_000) do
      value when is_integer(value) and value in 100..600_000 -> {:ok, value}
      _value -> {:error, :invalid_timeout}
    end
  end

  defp static_kubeconfig(kubeconfig) do
    with {:ok, document} <- YamlElixir.read_from_string(kubeconfig),
         true <- static_users?(document["users"]),
         true <- static_clusters?(document["clusters"]) do
      :ok
    else
      _error -> {:error, :unsafe_kubeconfig}
    end
  end

  defp static_users?(users) when is_list(users) and users != [] do
    Enum.all?(users, fn
      %{"user" => user} when is_map(user) ->
        static_user?(user)

      _user ->
        false
    end)
  end

  defp static_users?(_users), do: false

  defp static_user?(%{"token" => token} = user),
    do: map_size(user) == 1 and nonempty?(token)

  defp static_user?(
         %{
           "client-certificate-data" => certificate,
           "client-key-data" => private_key
         } = user
       ),
       do: map_size(user) == 2 and nonempty?(certificate) and nonempty?(private_key)

  defp static_user?(_user), do: false

  defp static_clusters?(clusters) when is_list(clusters) and clusters != [] do
    Enum.all?(clusters, fn
      %{"cluster" => cluster} when is_map(cluster) ->
        is_binary(cluster["server"]) and
          cluster["insecure-skip-tls-verify"] != true and
          not Map.has_key?(cluster, "certificate-authority")

      _cluster ->
        false
    end)
  end

  defp static_clusters?(_clusters), do: false

  defp exact_keys(map, allowed) do
    if exact_keys?(map, allowed),
      do: :ok,
      else: {:error, :unknown_key}
  end

  defp exact_keys?(map, allowed),
    do: Enum.all?(Map.keys(map), &(is_binary(&1) and &1 in allowed))

  defp namespace(configuration) do
    case Map.get(configuration, "namespace") do
      value when value in [nil, ""] ->
        {:ok, nil}

      value when is_binary(value) ->
        if valid_name?(value), do: {:ok, value}, else: {:error, :invalid_name}

      _value ->
        {:error, :invalid_name}
    end
  end

  defp nonempty?(value), do: is_binary(value) and byte_size(value) > 0
  defp cancelled?(%{cancelled?: callback}) when is_function(callback, 0), do: callback
  defp cancelled?(_invocation), do: fn -> false end

  def valid_name?(value),
    do: is_binary(value) and byte_size(value) in 1..253 and Regex.match?(@name_pattern, value)
end
