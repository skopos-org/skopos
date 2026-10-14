defmodule SkoposCLI.BrowserLogin do
  @moduledoc false

  alias SkoposCLI.Client

  @listen_options [:binary, packet: :raw, active: false, reuseaddr: true, ip: {127, 0, 0, 1}]

  def run(%Client{} = client, timeout, open_browser, listen) do
    with {:ok, listener} <- listen.(0, @listen_options) do
      try do
        authorize(client, listener, timeout, open_browser)
      after
        :gen_tcp.close(listener)
      end
    else
      {:error, reason} ->
        {:error, "Cannot open the loopback callback: #{:inet.format_error(reason)}"}
    end
  end

  def open_browser(url) do
    command =
      case :os.type() do
        {:unix, :darwin} -> {"open", [url]}
        {:win32, _name} -> {"cmd", ["/c", "start", "", url]}
        _other -> {"xdg-open", [url]}
      end

    case System.cmd(elem(command, 0), elem(command, 1), stderr_to_stdout: true) do
      {_output, 0} -> :ok
      {_output, _status} -> {:error, "Cannot open the browser"}
    end
  rescue
    ErlangError -> {:error, "Cannot open the browser"}
  end

  defp authorize(client, listener, timeout, open_browser) do
    with {:ok, {_address, port}} <- :inet.sockname(listener),
         verifier <- random_secret(),
         challenge <- verifier |> digest() |> Base.url_encode64(padding: false),
         {:ok, _status, %{"data" => request}} <-
           Client.request(client, :post, "/cli/session-requests", %{
             "request" => %{
               "redirect_uri" => "http://127.0.0.1:#{port}/callback",
               "code_challenge" => challenge
             }
           }),
         authorization_url when is_binary(authorization_url) <- request["authorization_url"],
         :ok <- open_browser.(authorization_url),
         {:ok, callback} <- await_callback(listener, timeout),
         true <- callback["request_id"] == request["id"],
         code when is_binary(code) <- callback["code"],
         {:ok, _status, %{"data" => %{"token" => token, "account" => account}}} <-
           Client.request(
             client,
             :post,
             "/cli/session-requests/#{URI.encode_www_form(request["id"])}/exchange",
             %{"request" => %{"code" => code, "verifier" => verifier}}
           ) do
      {:ok, token, account}
    else
      false -> {:error, "Browser callback did not match the login request"}
      nil -> {:error, "Browser callback did not contain an authorization code"}
      {:error, :timeout} -> {:error, "Browser login timed out"}
      {:error, :http, _status, _body} = error -> error
      {:error, :transport, _message} = error -> error
      {:error, message} when is_binary(message) -> {:error, message}
      _other -> {:error, "Browser login failed"}
    end
  end

  defp await_callback(listener, timeout) do
    with {:ok, socket} <- :gen_tcp.accept(listener, timeout) do
      try do
        with {:ok, request} <- receive_headers(socket, "", timeout),
             {:ok, query} <- parse_callback(request) do
          respond(socket, 200, "Authentication completed. You can close this window.")
          {:ok, query}
        else
          {:error, "Browser authorization returned " <> _reason} = error ->
            respond(socket, 200, "Authentication was not authorized. You can close this window.")
            error

          {:error, _reason} = error ->
            respond(socket, 400, "Authentication callback was invalid.")
            error
        end
      after
        :gen_tcp.close(socket)
      end
    end
  end

  defp receive_headers(_socket, data, _timeout) when byte_size(data) > 8_192,
    do: {:error, "Browser callback headers were too large"}

  defp receive_headers(socket, data, timeout) do
    if String.contains?(data, "\r\n\r\n") do
      {:ok, data}
    else
      case :gen_tcp.recv(socket, 0, timeout) do
        {:ok, chunk} -> receive_headers(socket, data <> chunk, timeout)
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp parse_callback(request) do
    with [request_line | _headers] <- String.split(request, "\r\n"),
         ["GET", target, _version] <- String.split(request_line, " ", parts: 3),
         %URI{path: "/callback", query: query} when is_binary(query) <- URI.parse(target),
         params <- URI.decode_query(query) do
      case params["error"] do
        nil -> {:ok, params}
        error -> {:error, "Browser authorization returned #{error}"}
      end
    else
      _other -> {:error, "Browser callback request was invalid"}
    end
  end

  defp respond(socket, status, message) do
    body = "<!doctype html><meta charset=\"utf-8\"><title>Skopos</title><p>#{message}</p>"
    reason = if status == 200, do: "OK", else: "Bad Request"

    response =
      "HTTP/1.1 #{status} #{reason}\r\ncontent-type: text/html; charset=utf-8\r\ncontent-length: #{byte_size(body)}\r\nconnection: close\r\n\r\n#{body}"

    :gen_tcp.send(socket, response)
  end

  defp random_secret do
    32
    |> :crypto.strong_rand_bytes()
    |> Base.url_encode64(padding: false)
  end

  defp digest(value), do: :crypto.hash(:sha256, value)
end
