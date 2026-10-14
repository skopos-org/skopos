defmodule Skopos.Transports.RESTCONF do
  @moduledoc false
  alias Skopos.Transports.HTTPS
  alias Skopos.Providers.Target.FileWriter

  @configuration_keys ~w(ca_certificate api_root connect_timeout_ms request_timeout_ms max_body_bytes)
  @xrd_namespace "http://docs.oasis-open.org/ns/xri/xrd-1.0"

  defmodule State do
    @moduledoc false
    @enforce_keys [
      :auth,
      :client_tls,
      :ca_certificate,
      :api_root,
      :connect_timeout,
      :request_timeout,
      :max_body_bytes
    ]
    @derive {Inspect, except: [:auth, :client_tls]}
    defstruct @enforce_keys
  end

  defmodule Notifications do
    @moduledoc false
    alias Skopos.Providers.Target
    @max_summary_bytes 1_048_576

    def read(response, reader) do
      cond do
        response.content_encoding not in ["", "identity"] ->
          unavailable("unsupported_encoding")

        response.file["size_bytes"] > @max_summary_bytes ->
          unavailable("summary_limit")

        true ->
          bytes =
            FileWriter.stream(response.file, reader) |> Enum.to_list() |> IO.iodata_to_binary()

          if String.valid?(bytes) do
            {events, parser} = ServerSentEvents.Parser.parse(bytes)

            id =
              case List.last(events) do
                %{id: id} when byte_size(id) <= 2_048 -> id
                _ -> nil
              end

            {:ok,
             %{
               "event_count" => length(events),
               "last_notification_id" => id,
               "partial_event" =>
                 not is_nil(parser.event) or parser.phase in [:key, :value_start, :value],
               "error" => nil
             }}
          else
            unavailable("invalid_utf8")
          end
      end
    catch
      {:file_read_error, %{category: :cancelled}} ->
        {:error, :cancelled, "RESTCONF notification reading was cancelled"}

      {:file_read_error, cause} ->
        if Target.Error.context_failure?(cause) do
          {:error,
           Target.Error.context_failure(cause, %{
             "http_status" => response.status,
             "file" => response.file,
             "completion_reason" => response.completion_reason
           })}
        else
          {:error, :failed, "RESTCONF notification file is unavailable"}
        end
    end

    defp unavailable(reason),
      do:
        {:ok,
         %{
           "event_count" => 0,
           "last_notification_id" => nil,
           "partial_event" => true,
           "error" => %{"reason" => reason}
         }}
  end

  def build(configuration, credentials) when is_map(configuration) and is_map(credentials) do
    with true <- Enum.all?(Map.keys(configuration), &(&1 in @configuration_keys)),
         true <-
           Enum.all?(
             Map.keys(credentials),
             &(&1 in ~w(username password bearer_token client_certificate client_private_key))
           ),
         {:ok, client_tls} <- client_tls(credentials),
         http_credentials <- Map.take(credentials, ~w(username password bearer_token)),
         {:ok, auth} <-
           if(http_credentials == %{} and client_tls != [],
             do: {:ok, nil},
             else: auth(http_credentials)
           ),
         :ok <- HTTPS.validate_ca_certificate(configuration["ca_certificate"]),
         root <- configuration["api_root"],
         true <- is_nil(root) or (path?(root) and root != "/"),
         {:ok, connect_timeout} <- timeout(configuration, "connect_timeout_ms", 10_000),
         {:ok, request_timeout} <- timeout(configuration, "request_timeout_ms", 30_000),
         limit when is_integer(limit) and limit in 1..60_000 <-
           Map.get(configuration, "max_body_bytes", 60_000) do
      {:ok,
       %State{
         auth: auth,
         client_tls: client_tls,
         ca_certificate: configuration["ca_certificate"],
         api_root: root,
         connect_timeout: connect_timeout,
         request_timeout: request_timeout,
         max_body_bytes: limit
       }}
    else
      _ -> {:error, :invalid_configuration}
    end
  end

  def build(_configuration, _credentials), do: {:error, :invalid_configuration}

  defp auth(%{"username" => username, "password" => password} = credentials)
       when map_size(credentials) == 2 and is_binary(username) and byte_size(username) in 1..255 and
              is_binary(password) and byte_size(password) in 1..4096 do
    if String.contains?(username, ":"),
      do: {:error, :invalid_credentials},
      else: {:ok, "Basic " <> Base.encode64(username <> ":" <> password)}
  end

  defp auth(%{"bearer_token" => token} = credentials)
       when map_size(credentials) == 1 and is_binary(token) and byte_size(token) in 1..4096 do
    if Regex.match?(~r/^[A-Za-z0-9._~+\/-]+=*$/, token),
      do: {:ok, "Bearer " <> token},
      else: {:error, :invalid_credentials}
  end

  defp auth(_credentials), do: {:error, :invalid_credentials}

  defp client_tls(credentials) do
    case {credentials["client_certificate"], credentials["client_private_key"]} do
      {nil, nil} ->
        {:ok, []}

      {certificate, private_key}
      when is_binary(certificate) and is_binary(private_key) and
             byte_size(certificate) in 1..65_536 and byte_size(private_key) in 1..65_536 ->
        entries = :public_key.pem_decode(certificate)
        certificates = for {:Certificate, der, :not_encrypted} <- entries, do: der

        with true <- certificates != [] and length(certificates) == length(entries),
             [{type, der, :not_encrypted}] <- :public_key.pem_decode(private_key),
             true <- type in [:RSAPrivateKey, :ECPrivateKey, :PrivateKeyInfo] do
          {:ok, [certs_keys: [%{cert: certificates, key: {type, der}}]]}
        else
          _ -> {:error, :invalid_client_certificate}
        end

      _ ->
        {:error, :invalid_client_certificate}
    end
  rescue
    _ -> {:error, :invalid_client_certificate}
  end

  def endpoint(value) when is_binary(value) and byte_size(value) in 1..2048 do
    case URI.parse(value) do
      %URI{scheme: "https", host: host, userinfo: nil, path: path, query: nil, fragment: nil} =
          uri
      when is_binary(host) and host != "" and path in [nil, ""] and uri.port in 1..65_535 ->
        {:ok, URI.to_string(%{uri | path: nil})}

      _ ->
        {:error, :failed, "RESTCONF endpoint is invalid"}
    end
  end

  def endpoint(_value), do: {:error, :failed, "RESTCONF endpoint is invalid"}

  def resource_uri(endpoint, value) when is_binary(value) and byte_size(value) in 1..2_048 do
    uri = URI.parse(value)

    if origin(uri) == origin(URI.parse(endpoint)) and is_nil(uri.userinfo) and
         is_nil(uri.fragment) and
         path?(uri.path || "/") and String.valid?(value) and
         not Regex.match?(~r/[\x00-\x20\x7f\\]/, value),
       do: {:ok, value},
       else:
         {:error, :failed, "RESTCONF resource URI is outside the registered origin or invalid"}
  rescue
    _ -> {:error, :failed, "RESTCONF resource URI is invalid"}
  end

  def resource_uri(_endpoint, _value), do: {:error, :failed, "RESTCONF resource URI is invalid"}

  def path?(value) when is_binary(value) and byte_size(value) in 1..2048 do
    uri = URI.parse(value)
    decoded = URI.decode(value)

    String.valid?(value) and String.starts_with?(value, "/") and
      not String.starts_with?(value, "//") and
      is_nil(uri.scheme) and is_nil(uri.host) and is_nil(uri.query) and is_nil(uri.fragment) and
      not Regex.match?(~r/%(?![0-9a-fA-F]{2})/, value) and
      not Regex.match?(~r/[\x00-\x20\x7f\\]/, decoded) and
      not Regex.match?(~r/%[0-9a-fA-F]{2}/, decoded) and
      not Enum.any?(String.split(decoded, "/"), &(&1 in [".", ".."]))
  rescue
    _ -> false
  end

  def path?(_value), do: false

  def check(state, endpoint) do
    case request(
           state,
           endpoint,
           %{
             method: :get,
             path: "/",
             query: %{},
             body: nil,
             accept: "application/yang-data+json",
             content_type: "application/yang-data+json"
           },
           %{},
           :read
         ) do
      {:ok, %{status: status}} when status in 200..299 -> :ok
      {:ok, %{status: 401}} -> {:error, :authentication, "RESTCONF authentication failed"}
      {:ok, %{status: _status}} -> {:error, :capability, "RESTCONF root request was rejected"}
      {:error, _category, _message} = error -> error
    end
  end

  def request(state, value, operation, invocation, phase) do
    deadline = System.monotonic_time(:millisecond) + state.request_timeout

    with {:ok, endpoint} <- endpoint(value),
         {:ok, path} <- resource_path(state, endpoint, operation, invocation, deadline) do
      run_http(state, endpoint, path, operation, invocation, phase, deadline)
    else
      {:error, _category, _message} = error -> error
      {:error, %{errors: errors}} = error when is_list(errors) -> error
      {:error, %Skopos.Providers.Target.BeforeSendError{}} = error -> error
    end
  end

  defp resource_path(_state, endpoint, %{uri: uri}, _invocation, _deadline) when is_binary(uri) do
    with {:ok, _} <- resource_uri(endpoint, uri), do: {:ok, URI.parse(uri).path || "/"}
  end

  defp resource_path(state, endpoint, operation, invocation, deadline) do
    with true <- path?(operation.path),
         {:ok, root} <- root(state, endpoint, invocation, deadline),
         do: {:ok, if(operation.path == "/", do: root, else: root <> operation.path)},
         else: (
           false -> {:error, :failed, "RESTCONF resource path is invalid"}
           error -> error
         )
  end

  defp root(%State{api_root: root}, _endpoint, _invocation, _deadline) when is_binary(root),
    do: {:ok, root}

  defp root(state, endpoint, invocation, deadline) do
    operation = %{
      method: :get,
      query: %{},
      body: nil,
      accept: "application/xrd+xml",
      content_type: "application/xrd+xml"
    }

    with {:ok, %{status: 200, body: body}} <-
           run_http(
             state,
             endpoint,
             "/.well-known/host-meta",
             operation,
             invocation,
             :read,
             deadline
           ),
         {:ok, {name, attributes, children}} <- Saxy.SimpleForm.parse_string(body),
         namespaces <- Map.new(attributes),
         true <- element?(name, namespaces, "XRD"),
         [href] <-
           for(
             {tag, attrs, _content} <- children,
             attrs = Map.new(attrs),
             element?(tag, Map.merge(namespaces, attrs), "Link"),
             attrs["rel"] == "restconf",
             do: attrs["href"]
           ),
         true <- is_binary(href),
         %URI{} = uri <- URI.merge(endpoint, href),
         true <- origin(uri) == origin(URI.parse(endpoint)),
         true <- is_nil(uri.userinfo) and is_nil(uri.query) and is_nil(uri.fragment),
         true <- path?(uri.path) and uri.path != "/" do
      {:ok, String.trim_trailing(uri.path, "/")}
    else
      {:ok, %{status: 401}} -> {:error, :authentication, "RESTCONF authentication failed"}
      {:error, category, message} when is_atom(category) -> {:error, category, message}
      {:error, %{errors: errors}} = error when is_list(errors) -> error
      {:error, %Skopos.Providers.Target.BeforeSendError{}} = error -> error
      _ -> {:error, :failed, "RESTCONF root discovery is invalid"}
    end
  rescue
    _ -> {:error, :failed, "RESTCONF root discovery is invalid"}
  end

  defp element?(name, attributes, expected) do
    case String.split(name, ":", parts: 2) do
      [^expected] -> attributes["xmlns"] == @xrd_namespace
      [prefix, ^expected] -> attributes["xmlns:" <> prefix] == @xrd_namespace
      _ -> false
    end
  end

  defp origin(uri), do: {uri.scheme, uri.host, uri.port}

  defp run_http(state, endpoint, path, operation, invocation, phase, deadline) do
    remaining = deadline - System.monotonic_time(:millisecond)

    cond do
      cancelled?(invocation) ->
        {:error, :cancelled, "RESTCONF request was cancelled before dispatch"}

      remaining <= 0 ->
        {:error, :timeout, "RESTCONF request timed out before dispatch"}

      true ->
        result = http(state, endpoint, path, operation, invocation, remaining)

        with {:ok, response} <- normalize(result, phase) do
          if response[:file] && media(response.headers) == "text/event-stream" do
            {:ok, raw} = result

            with {:ok, notifications} <-
                   Notifications.read(response, raw.private[:skopos_file_reader]),
                 do: {:ok, Map.put(response, :notifications, notifications)}
          else
            {:ok, response}
          end
        end
    end
  end

  defp http(state, endpoint, path, operation, invocation, remaining) do
    {:ok, tls} = HTTPS.transport_options(state.ca_certificate, URI.parse(endpoint).host)

    options = [
      method: operation.method,
      url: Map.get(operation, :uri) || endpoint <> path,
      params: operation.query,
      headers:
        if(state.auth, do: [{"authorization", state.auth}], else: []) ++
          [
            {"accept", operation.accept},
            {"content-type", operation.content_type},
            {"accept-encoding", "identity"}
          ] ++
          if(Map.get(operation, :last_event_id),
            do: [{"last-event-id", operation.last_event_id}],
            else: []
          ) ++ Map.to_list(Map.get(operation, :headers, %{})),
      connect_options: [
        timeout: min(state.connect_timeout, remaining),
        transport_opts: Keyword.merge(tls, state.client_tls)
      ],
      receive_timeout: remaining,
      retry: false,
      redirect: false,
      raw: true,
      capture: Map.get(operation, :capture),
      into: fn {:data, data}, {request, response} ->
        body = if is_binary(response.body), do: response.body, else: ""

        if byte_size(body) + byte_size(data) <= state.max_body_bytes,
          do: {:cont, {request, %{response | body: body <> data}}},
          else: {:halt, {request, %{response | body: :too_large}}}
      end
    ]

    Skopos.Transports.HTTP.request(
      options,
      operation.body,
      Map.get(operation, :response_file),
      invocation
    )
  end

  defp media(headers),
    do:
      headers
      |> Map.get("content-type", [""])
      |> List.first()
      |> String.split(";")
      |> hd()
      |> String.trim()
      |> String.downcase()

  defp normalize({:ok, %Req.Response{private: %{skopos_file: file}} = response}, _phase) do
    {:ok,
     %{
       status: response.status,
       headers: response.headers,
       body: "",
       file: file,
       completion_reason: Atom.to_string(response.private[:skopos_completion_reason]),
       content_encoding: Enum.join(Req.Response.get_header(response, "content-encoding"), ",")
     }}
  end

  defp normalize({:ok, %Req.Response{status: status, headers: headers, body: body}}, phase)
       when is_binary(body) do
    if String.valid?(body),
      do: {:ok, %{status: status, headers: headers, body: body}},
      else: {:error, failure(phase, :failed), "RESTCONF response is not UTF-8"}
  end

  defp normalize({:ok, %Req.Response{}}, phase),
    do: {:error, failure(phase, :failed), "RESTCONF response exceeded its limit"}

  defp normalize({:error, :retryable, message}, phase),
    do: {:error, failure(phase, :unreachable), message}

  defp normalize({:error, %{errors: errors}} = error, _phase) when is_list(errors), do: error
  defp normalize({:error, %Skopos.Providers.Target.BeforeSendError{}} = error, _phase), do: error

  defp normalize({:error, category, message}, phase),
    do: {:error, failure(phase, category), message}

  defp failure(:effect, _category), do: :unknown_after_dispatch
  defp failure(_phase, category), do: category

  defp cancelled?(%{cancelled?: callback}) when is_function(callback, 0), do: callback.()
  defp cancelled?(_invocation), do: false

  defp timeout(configuration, key, default) do
    case Map.get(configuration, key, default) do
      value when is_integer(value) and value in 100..600_000 -> {:ok, value}
      _ -> {:error, :invalid_timeout}
    end
  end
end
