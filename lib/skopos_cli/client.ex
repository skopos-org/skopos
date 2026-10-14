defmodule SkoposCLI.Client do
  @moduledoc false

  defstruct [:server, :token, request_options: []]

  def new(server, token, request_options \\ []) do
    with {:ok, normalized} <- normalize_server(server) do
      {:ok, %__MODULE__{server: normalized, token: token, request_options: request_options}}
    end
  end

  def request(%__MODULE__{} = client, method, path, body \\ nil, query \\ []) do
    wire_options = if is_nil(body), do: [], else: [json: body]
    perform(client, method, path, query, wire_options, :json)
  end

  def request_binary(%__MODULE__{} = client, method, path, body \\ nil) do
    wire_options = [decode_body: false]

    wire_options =
      if is_nil(body),
        do: Keyword.put(wire_options, :headers, [{"accept", "application/octet-stream"}]),
        else:
          Keyword.merge(wire_options,
            body: body,
            headers: [{"content-type", "application/octet-stream"}]
          )

    perform(client, method, path, [], wire_options, :binary)
  end

  defp perform(client, method, path, query, wire_options, format) do
    options = [
      method: method,
      url: client.server <> "/api/v1" <> path,
      headers: headers(client.token),
      params: query,
      receive_timeout: 30_000,
      retry: false
    ]

    headers =
      Enum.reduce(wire_options[:headers] || [], headers(client.token), fn {key, value}, current ->
        List.keystore(current, key, 0, {key, value})
      end)

    options = Keyword.merge(options, Keyword.delete(wire_options, :headers))
    options = Keyword.put(options, :headers, headers)

    case Req.request(Keyword.merge(options, client.request_options)) do
      {:ok, %Req.Response{status: status, body: response}} when status in 200..299 ->
        {:ok, status, if(format == :binary, do: response, else: normalize_body(response))}

      {:ok, %Req.Response{status: status, body: response}} ->
        {:error, :http, status, error_body(response, format)}

      {:error, error} ->
        {:error, :transport, Exception.message(error)}
    end
  end

  defp error_body(body, :binary) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, decoded} when is_map(decoded) -> decoded
      _ -> %{"error" => %{"message" => "Server rejected the binary transfer"}}
    end
  end

  defp error_body(body, _format), do: normalize_body(body)

  defp normalize_server(server) when is_binary(server) do
    uri = URI.parse(server)

    if uri.scheme in ["http", "https"] and is_binary(uri.host) and uri.userinfo == nil and
         uri.path in [nil, "", "/"] and is_nil(uri.query) and is_nil(uri.fragment) do
      {:ok, String.trim_trailing(server, "/")}
    else
      {:error, "Server must be an HTTP or HTTPS origin without a path, query, or credentials"}
    end
  end

  defp normalize_server(_server), do: {:error, "Server is not configured"}

  defp headers(nil), do: [{"accept", "application/json"}]

  defp headers(token) do
    [{"accept", "application/json"}, {"authorization", "Bearer #{token}"}]
  end

  defp normalize_body(body) when is_map(body) or is_list(body), do: body
  defp normalize_body(""), do: %{}
  defp normalize_body(body) when is_binary(body), do: %{"message" => body}
  defp normalize_body(body), do: %{"message" => inspect(body)}
end
