defmodule Skopos.Notifications.HTTP.Webhook do
  @moduledoc false

  @behaviour Skopos.Providers.Adapter
  @behaviour Skopos.Providers.Notification

  alias Skopos.Providers.Notification
  alias Skopos.Transports.HTTPS

  @configuration_keys ~w(url ca_certificate connect_timeout_ms request_timeout_ms)
  @credential_keys ~w(signing_secret)
  @max_request_bytes 1_048_576
  @max_response_bytes 65_536
  @poll_interval 20

  defmodule State do
    @moduledoc false
    @enforce_keys [
      :url,
      :signing_secret,
      :connect_timeout,
      :request_timeout,
      :transport_opts
    ]
    defstruct @enforce_keys
  end

  @impl Skopos.Providers.Adapter
  def type, do: "http-webhook"

  @impl Skopos.Providers.Adapter
  def kind, do: :notification

  @impl Skopos.Providers.Adapter
  def build(configuration, credentials) when is_map(configuration) and is_map(credentials) do
    with :ok <- exact_keys(configuration, @configuration_keys),
         :ok <- exact_keys(credentials, @credential_keys),
         {:ok, url, host} <- endpoint(configuration["url"]),
         {:ok, signing_secret} <- signing_secret(credentials["signing_secret"]),
         {:ok, connect_timeout} <- timeout(configuration, "connect_timeout_ms", 10_000),
         {:ok, request_timeout} <- timeout(configuration, "request_timeout_ms", 30_000),
         {:ok, transport_opts} <- HTTPS.transport_options(configuration["ca_certificate"], host) do
      {:ok,
       %State{
         url: url,
         signing_secret: signing_secret,
         connect_timeout: connect_timeout,
         request_timeout: request_timeout,
         transport_opts: transport_opts
       }}
    else
      _error -> {:error, :invalid_configuration}
    end
  rescue
    _error -> {:error, :invalid_configuration}
  end

  def build(_configuration, _credentials), do: {:error, :invalid_configuration}

  @impl Skopos.Providers.Adapter
  def check(%State{} = state, input) when input == %{} do
    timestamp = timestamp()
    headers = headers(state, "provider-check", timestamp, "")

    case dispatch(state, :head, headers, "", fn -> false end) do
      {:ok, %Req.Response{status: status}} when status in 200..399 or status == 405 ->
        :ok

      {:ok, %Req.Response{status: 401}} ->
        {:error, :authentication, "Webhook authentication failed"}

      {:ok, %Req.Response{status: 403}} ->
        {:error, :capability, "Webhook check is forbidden"}

      {:ok, %Req.Response{status: status}} when status in 400..499 ->
        {:error, :invalid_configuration, "Webhook endpoint rejected the check"}

      {:ok, %Req.Response{}} ->
        {:error, :unreachable, "Webhook endpoint is unavailable"}

      {:error, _category, message} ->
        {:error, :unreachable, message}
    end
  end

  def check(_state, _input),
    do: {:error, :invalid_configuration, "Webhook check input is invalid"}

  @impl Skopos.Providers.Notification
  def deliver(%State{} = state, %Notification.Request{} = request, invocation) do
    with {:ok, body} <- encode(request) do
      timestamp = timestamp()
      headers = headers(state, request.idempotency_key, timestamp, body)

      state
      |> dispatch(:post, headers, body, cancelled?(invocation))
      |> delivery_result()
    end
  end

  def deliver(_state, _request, _invocation),
    do: {:error, :failed, "Webhook notification request is invalid"}

  defp encode(request) do
    with {:ok, body} <-
           Jason.encode(%{
             "idempotency_key" => request.idempotency_key,
             "report" => %{"id" => request.report_id, "revision" => request.report_revision},
             "destination" => %{
               "id" => request.destination_id,
               "revision" => request.destination_revision
             },
             "payload" => request.payload
           }),
         true <- byte_size(body) <= @max_request_bytes do
      {:ok, body}
    else
      _error -> {:error, :failed, "Webhook notification payload is invalid"}
    end
  rescue
    _error -> {:error, :failed, "Webhook notification payload is invalid"}
  end

  defp headers(state, idempotency_key, timestamp, body) do
    signature =
      :crypto.mac(:hmac, :sha256, state.signing_secret, timestamp <> "." <> body)
      |> Base.encode16(case: :lower)

    [
      {"accept", "application/json"},
      {"content-type", "application/json"},
      {"idempotency-key", idempotency_key},
      {"x-skopos-timestamp", timestamp},
      {"x-skopos-signature", "v1=#{signature}"}
    ]
  end

  defp dispatch(state, method, headers, body, cancelled?) do
    if cancelled?.() do
      {:error, :cancelled, "Webhook notification was cancelled"}
    else
      task = Task.async(fn -> request(state, method, headers, body) end)

      await(
        task,
        cancelled?,
        System.monotonic_time(:millisecond) + state.connect_timeout + state.request_timeout
      )
    end
  rescue
    _error -> {:error, :timeout, "Webhook notification outcome is unknown"}
  catch
    _kind, _reason -> {:error, :timeout, "Webhook notification outcome is unknown"}
  end

  defp request(state, method, headers, body) do
    options = [
      method: method,
      url: state.url,
      headers: headers,
      body: body,
      connect_options: [timeout: state.connect_timeout, transport_opts: state.transport_opts],
      receive_timeout: state.request_timeout,
      retry: false,
      redirect: false,
      decode_body: false
    ]

    Req.request(options)
  rescue
    _error -> {:error, :transport_failure}
  catch
    _kind, _reason -> {:error, :transport_failure}
  end

  defp await(task, cancelled?, deadline) do
    cond do
      cancelled?.() ->
        Task.shutdown(task, :brutal_kill)
        {:error, :timeout, "Webhook notification outcome is unknown"}

      System.monotonic_time(:millisecond) >= deadline ->
        Task.shutdown(task, :brutal_kill)
        {:error, :timeout, "Webhook notification timed out"}

      true ->
        case Task.yield(task, @poll_interval) do
          {:ok, {:ok, %Req.Response{}} = result} -> result
          {:ok, {:error, _error}} -> {:error, :timeout, "Webhook notification outcome is unknown"}
          {:exit, _reason} -> {:error, :timeout, "Webhook notification outcome is unknown"}
          nil -> await(task, cancelled?, deadline)
        end
    end
  end

  defp delivery_result({:ok, %Req.Response{status: 202} = response}),
    do: result(:accepted, response)

  defp delivery_result({:ok, %Req.Response{status: status} = response})
       when status in 200..299,
       do: result(:delivered, response)

  defp delivery_result({:ok, %Req.Response{status: status} = response})
       when status in 300..499,
       do: result(:failed, response)

  defp delivery_result({:ok, %Req.Response{status: status} = response})
       when status in 500..599,
       do: result(:unknown, response)

  defp delivery_result({:ok, %Req.Response{}}),
    do: {:error, :failed, "Webhook response is invalid"}

  defp delivery_result({:error, category, message}), do: {:error, category, message}
  defp delivery_result(_result), do: {:error, :timeout, "Webhook notification outcome is unknown"}

  defp result(status, response) do
    {:ok,
     %Notification.Result{
       status: status,
       reference: reference(response),
       details: response_details(response)
     }}
  end

  defp response_details(%Req.Response{status: status, body: body}) do
    %{"http_status" => status}
    |> add_response(body)
  end

  defp add_response(details, ""), do: details

  defp add_response(details, body)
       when is_binary(body) and byte_size(body) <= @max_response_bytes do
    value =
      case Jason.decode(body) do
        {:ok, decoded} -> decoded
        _error -> body
      end

    Map.put(details, "response", value)
  end

  defp add_response(details, _body), do: Map.put(details, "response_omitted", true)

  defp reference(response) do
    ["location", "x-request-id"]
    |> Enum.find_value(fn header ->
      case Req.Response.get_header(response, header) do
        [value] when is_binary(value) and byte_size(value) in 1..1_024 -> value
        _other -> nil
      end
    end)
  end

  defp endpoint(value) when is_binary(value) do
    case URI.parse(value) do
      %URI{scheme: "https", host: host, path: path} = uri
      when is_binary(host) and byte_size(host) > 0 and is_binary(path) and byte_size(path) > 0 ->
        if is_nil(uri.userinfo) and is_nil(uri.query) and is_nil(uri.fragment) and
             (is_nil(uri.port) or uri.port in 1..65_535),
           do: {:ok, URI.to_string(uri), host},
           else: {:error, :invalid_url}

      _uri ->
        {:error, :invalid_url}
    end
  end

  defp endpoint(_value), do: {:error, :invalid_url}

  defp signing_secret(value) when is_binary(value) and byte_size(value) in 32..4_096 do
    if String.contains?(value, <<0>>),
      do: {:error, :invalid_signing_secret},
      else: {:ok, value}
  end

  defp signing_secret(_value), do: {:error, :invalid_signing_secret}

  defp timeout(configuration, key, default) do
    case Map.get(configuration, key, default) do
      value when is_integer(value) and value in 100..600_000 -> {:ok, value}
      _value -> {:error, :invalid_timeout}
    end
  end

  defp exact_keys(map, allowed) do
    if Enum.all?(Map.keys(map), &(is_binary(&1) and &1 in allowed)),
      do: :ok,
      else: {:error, :unknown_key}
  end

  defp cancelled?(%{cancelled?: callback}) when is_function(callback, 0), do: callback
  defp cancelled?(_invocation), do: fn -> false end
  defp timestamp, do: System.system_time(:second) |> Integer.to_string()
end
