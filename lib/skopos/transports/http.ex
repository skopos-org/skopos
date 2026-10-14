defmodule Skopos.Transports.HTTP do
  @moduledoc false

  alias Skopos.Providers.Target
  @poll_interval 20
  @pool_idle_timeout 60_000

  def request_headers(headers, reserved) when is_map(headers) and map_size(headers) <= 8 do
    normalized =
      Enum.map(headers, fn {name, value} -> {String.downcase(to_string(name)), value} end)

    if length(Enum.uniq_by(normalized, &elem(&1, 0))) == map_size(headers) and
         Enum.all?(normalized, fn {name, value} ->
           byte_size(name) in 1..256 and Regex.match?(~r/\A[!#$%&'*+\-.^_`|~0-9A-Za-z]+\z/, name) and
             name not in reserved and
             is_binary(value) and byte_size(value) <= 1_024 and
             not String.match?(value, ~r/[\x00-\x08\x0a-\x1f\x7f]/)
         end), do: {:ok, Map.new(normalized)}, else: {:error, :invalid_headers}
  rescue
    _ -> {:error, :invalid_headers}
  end

  def request_headers(_headers, _reserved), do: {:error, :invalid_headers}

  # Wire I/O only. Storage and authorization remain in the supplied file ports.
  def request(options, body, output, invocation) do
    with :ok <- not_cancelled(invocation),
         {:ok, body, headers} <- wire_body(body, Map.new(options[:headers] || []), invocation),
         {:ok, writer} <- response_writer(output, invocation) do
      collector =
        if is_nil(writer),
          do: Keyword.fetch!(options, :into),
          else: fn event, acc ->
            collect_response(event, acc, writer, invocation, options[:capture])
          end

      options =
        options |> Keyword.put(:headers, Map.to_list(headers)) |> Keyword.put(:into, collector)

      options = if is_nil(body), do: options, else: Keyword.put(options, :body, body)

      case exchange(options, writer, invocation) do
        {:ok, %Req.Response{status: status} = response} when status in 100..599 ->
          complete_response(response, writer, invocation, options[:method])

        {:error, _category, _message} = error ->
          error

        {:error, %Target.BeforeSendError{}} = error ->
          error

        {:error, %{errors: errors}} = error when is_list(errors) ->
          error

        _other ->
          response_failure(writer)
      end
    end
  rescue
    _error -> {:error, :retryable, "HTTP endpoint request failed"}
  end

  defp exchange(options, writer, invocation) do
    started = System.monotonic_time(:millisecond)
    deadline = started + Keyword.fetch!(options, :receive_timeout)
    channel = make_ref()
    owner = self()

    capture =
      if options[:capture],
        do: %{
          deadline: started + options[:capture]["duration_ms"],
          channel: channel,
          response: nil
        }

    notify = if capture, do: fn response -> send(owner, {channel, response}) end
    task = Task.async(fn -> wire_request(options, writer, notify, invocation) end)

    try do
      await_wire(task, deadline, writer, invocation, capture)
    after
      Task.shutdown(task, :brutal_kill)
      clear_headers(channel)
    end
  end

  defp wire_request(options, writer, notify, invocation) do
    limiter = options[:data_limiter]

    request =
      options
      |> Keyword.drop([:capture, :data_limiter])
      |> Keyword.put(:adapter, __MODULE__)
      |> Req.new()

    request =
      if notify,
        do: Req.Request.put_private(request, :skopos_response_headers, notify),
        else: request

    request =
      if limiter,
        do: Req.Request.put_private(request, :skopos_data_limiter, limiter),
        else: request

    with :ok <- not_cancelled(invocation) do
      case Req.request(request) do
        {:error, %Req.TransportError{reason: :timeout}} -> timeout_failure(writer)
        {:error, %Finch.TransportError{reason: :timeout}} -> timeout_failure(writer)
        result -> result
      end
    end
  rescue
    _error -> response_failure(writer)
  catch
    {:http_file_failure, cause, progress} ->
      {:error, Target.Error.context_failure(cause, progress)}

    {:http_file_failure, _message} ->
      response_failure(writer)

    :http_cancelled ->
      {:error, :cancelled, "HTTP request was cancelled"}

    _kind, _reason ->
      response_failure(writer)
  end

  # Public Req preparation and Finch streaming APIs retain synchronous
  # backpressure while making every response event available to this owner.
  @doc false
  def run(%Req.Request{} = request) do
    options =
      Req.Finch.pool_options(
        connect_options: Req.Request.get_option(request, :connect_options, []),
        inet6: String.contains?(request.url.host || "", ":")
      )
      |> Keyword.put(:protocols, [:http1])
      |> Keyword.put(:pool_max_idle_time, @pool_idle_timeout)

    tag = :crypto.hash(:sha256, :erlang.term_to_binary(options))
    pool = Finch.Pool.new(URI.to_string(request.url), tag: tag)
    :ok = Finch.start_pool(__MODULE__, pool, options)

    wire =
      Finch.build(
        request.method,
        request.url,
        Req.get_headers_list(request),
        stream_body(request.body),
        pool_tag: tag
      )

    case Finch.stream_while(wire, __MODULE__, {request, Req.Response.new()}, &stream_event/2,
           receive_timeout: Req.Request.get_option(request, :receive_timeout, 15_000),
           pool_timeout: Req.Request.get_option(request, :pool_timeout, 5_000)
         ) do
      {:ok, result} -> result
      {:error, error, {request, _response}} -> {request, error}
    end
  end

  defp stream_body(body) when is_nil(body) or is_binary(body) or is_list(body), do: body
  defp stream_body(body), do: {:stream, body}

  defp stream_event({:status, status}, {request, response}),
    do: {:cont, {request, %{response | status: status}}}

  defp stream_event({:headers, fields}, {request, response}) do
    response = %{response | headers: Req.Response.new(headers: fields).headers}

    if response.status in 200..599 && request.private[:skopos_response_headers],
      do: request.private[:skopos_response_headers].(response)

    {:cont, {request, response}}
  end

  defp stream_event({:trailers, fields}, {request, response}),
    do: {:cont, {request, %{response | trailers: Req.Response.new(trailers: fields).trailers}}}

  defp stream_event({:data, _bytes} = event, {request, _response} = acc),
    do: request.into.(event, acc)

  defp await_wire(task, deadline, writer, invocation, capture) do
    capture = take_headers(capture)
    remaining = deadline - System.monotonic_time(:millisecond)
    sample_remaining = if capture, do: capture.deadline - System.monotonic_time(:millisecond)
    finished = Task.yield(task, 0)

    cancellation =
      if match?({:ok, _}, finished), do: :ok, else: not_cancelled(invocation, true)

    cond do
      match?({:ok, _}, finished) ->
        elem(finished, 1)

      cancellation != :ok ->
        stop_wire(task, cancellation)

      match?({:exit, _}, finished) ->
        response_failure(writer)

      capture && sample_remaining <= 0 ->
        case capture.response do
          nil ->
            timeout_failure(writer)

          response ->
            private = Map.put(response.private, :skopos_completion_reason, :duration_limit)
            {:ok, %{response | private: private}}
        end

      remaining <= 0 ->
        stop_wire(task, timeout_failure(writer))

      true ->
        wait =
          min(@poll_interval, if(capture, do: min(remaining, sample_remaining), else: remaining))

        case Task.yield(task, wait) do
          {:ok, result} -> result
          {:exit, _reason} -> response_failure(writer)
          nil -> await_wire(task, deadline, writer, invocation, capture)
        end
    end
  end

  defp stop_wire(task, failure) do
    case Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> result
      _stopped -> failure
    end
  end

  defp take_headers(nil), do: nil

  defp take_headers(%{channel: channel} = capture) do
    receive do
      {^channel, response} -> take_headers(%{capture | response: response})
    after
      0 -> capture
    end
  end

  defp clear_headers(channel) do
    receive do
      {^channel, _response} -> clear_headers(channel)
    after
      0 -> :ok
    end
  end

  defp wire_body({:file, label, reference}, headers, %{file_reader: reader} = invocation)
       when is_function(reader, 2) do
    case prepare_file(fn -> reader.(label, 0) end) do
      {:ok, first} when is_binary(first) ->
        size = reference["size_bytes"]

        stream =
          Stream.unfold({0, first}, fn
            {^size, _chunk} ->
              nil

            {offset, chunk} ->
              progress = %{"input_file_id" => reference["id"], "input_bytes_supplied" => offset}
              check_file_context(invocation, progress)

              chunk =
                if is_nil(chunk),
                  do: read_file_chunk(reader, label, offset, progress),
                  else: chunk

              if byte_size(chunk) == 0 or offset + byte_size(chunk) > size,
                do: throw({:http_file_failure, "HTTP input file could not be read"})

              {chunk, {offset + byte_size(chunk), nil}}
          end)

        headers =
          headers
          |> Map.put("content-length", Integer.to_string(size))
          |> Map.put_new("content-type", reference["media_type"])

        {:ok, stream, headers}

      {:error, %Target.BeforeSendError{}} = error ->
        error

      {:error, cause} ->
        context_failure(cause, false)

      _ ->
        {:error, :failed, "HTTP input file could not be read"}
    end
  end

  defp wire_body({:file, _label, _reference}, _headers, _invocation),
    do: {:error, :failed, "HTTP input file reader is unavailable"}

  defp wire_body(body, headers, _invocation), do: {:ok, body, headers}

  defp read_file_chunk(reader, label, offset, progress) do
    case reader.(label, offset) do
      {:ok, chunk} when is_binary(chunk) -> chunk
      {:error, cause} -> throw({:http_file_failure, cause, progress})
      _ -> throw({:http_file_failure, "HTTP input file could not be read"})
    end
  rescue
    cause -> throw({:http_file_failure, cause, progress})
  catch
    :throw, {:http_file_failure, _, _} = failure ->
      throw(failure)

    :throw, {:http_file_failure, _} = failure ->
      throw(failure)

    kind, reason ->
      throw({:http_file_failure, ErlangError.exception(original: {kind, reason}), progress})
  end

  defp response_writer(nil, _invocation), do: {:ok, nil}

  defp response_writer(%{"name" => name, "media_type" => media}, %{file_writer: callback})
       when is_function(callback, 3) do
    case prepare_file(fn -> callback.(Ecto.UUID.generate(), name, media) end) do
      {:ok, %Target.FileWriter{status: :receiving, offset: 0} = writer} -> {:ok, writer}
      {:error, %Target.BeforeSendError{}} = error -> error
      {:error, cause} -> context_failure(cause, false)
      _ -> {:error, :failed, "HTTP response file could not be opened"}
    end
  end

  defp response_writer(_output, _invocation),
    do: {:error, :failed, "HTTP response file writer is unavailable"}

  defp collect_response({:data, bytes}, {request, response}, writer, invocation, capture) do
    offset = Map.get(response.private, :skopos_received_bytes, 0)

    bytes =
      if capture,
        do: binary_part(bytes, 0, min(byte_size(bytes), capture["max_bytes"] - offset)),
        else: bytes

    {bytes, response} =
      if request.private[:skopos_data_limiter],
        do: request.private[:skopos_data_limiter].(bytes, response),
        else: {bytes, response}

    progress = %{
      "http_status" => response.status,
      "receiving_file_id" => writer.id,
      "received_bytes" => offset,
      "pending_chunk_bytes" => byte_size(bytes)
    }

    check_file_context(invocation, progress)
    offset = append_response(writer, offset, bytes, progress)

    response = %{
      response
      | body: "",
        private: Map.put(response.private, :skopos_received_bytes, offset)
    }

    reason =
      response.private[:skopos_completion_reason] ||
        if(capture && offset == capture["max_bytes"], do: :byte_limit)

    if reason do
      response = %{
        response
        | private: Map.put(response.private, :skopos_completion_reason, reason)
      }

      {:halt, {request, response}}
    else
      {:cont, {request, response}}
    end
  end

  defp append_response(writer, offset, bytes, progress) do
    case Target.FileWriter.append(writer, offset, bytes) do
      {:ok, next} ->
        next

      {:error, cause} ->
        progress = Map.merge(progress, Target.Error.context_progress(cause) || %{})
        throw({:http_file_failure, cause, progress})

      _ ->
        throw({:http_file_failure, file_failure_message(writer)})
    end
  rescue
    cause -> throw({:http_file_failure, cause, progress})
  catch
    :throw, {:http_file_failure, _, _} = failure ->
      throw(failure)

    :throw, {:http_file_failure, _} = failure ->
      throw(failure)

    kind, reason ->
      throw({:http_file_failure, ErlangError.exception(original: {kind, reason}), progress})
  end

  defp check_file_context(invocation, progress) do
    case not_cancelled(invocation, true) do
      :ok -> :ok
      {:error, cause} -> throw({:http_file_failure, cause, progress})
      _ -> throw(:http_cancelled)
    end
  end

  defp prepare_file(callback) do
    callback.()
  rescue
    cause -> context_failure(cause, false)
  catch
    kind, reason -> context_failure(ErlangError.exception(original: {kind, reason}), false)
  end

  defp complete_response(response, nil, _invocation, _method), do: {:ok, response}

  defp complete_response(response, writer, invocation, method) do
    reason = Map.get(response.private, :skopos_completion_reason, :eof)
    sample? = reason in [:byte_limit, :duration_limit, :event_limit]

    expected_size =
      cond do
        sample? -> {:ok, nil}
        method == :head -> {:ok, 0}
        true -> content_length(response)
      end

    with :ok <- not_cancelled(invocation, true),
         {:ok, size} <- expected_size,
         {:ok, hash} <-
           if(method == :head or sample?, do: {:ok, nil}, else: content_digest(response)),
         {:ok, reference} <- writer.complete.(size, hash, reason) do
      private =
        response.private
        |> Map.put(:skopos_file, reference)
        |> Map.put(:skopos_completion_reason, reason)
        |> Map.put(:skopos_file_reader, writer.read)

      {:ok, %{response | private: private}}
    else
      {:error, :cancelled, _} = error ->
        error

      {:error, %{errors: errors} = cause} when is_list(errors) ->
        {:error,
         Target.Error.context_failure(cause, %{
           "http_status" => response.status,
           "receiving_file_id" => writer.id,
           "received_bytes" => Map.get(response.private, :skopos_received_bytes, 0)
         })}

      _ ->
        response_failure(writer)
    end
  end

  # RFC 9530 Content-Digest covers message content, including Content-Encoding.
  # Repr-Digest can describe different bytes (HEAD/range), so it is not used here.
  defp content_digest(response) do
    value =
      Enum.join(
        Req.Response.get_header(response, "content-digest") ++
          Map.get(response.trailers, "content-digest", []),
        ","
      )

    matches =
      Regex.scan(
        ~r/(?:^|,)\s*sha-256\s*=\s*:([A-Za-z0-9+\/=]*):(?:\s*;[^,]*)?(?=\s*(?:,|$))/,
        value
      )

    case matches do
      [[_field, encoded]] ->
        case Base.decode64(encoded) do
          {:ok, hash} when byte_size(hash) == 32 -> {:ok, Base.encode16(hash, case: :lower)}
          _ -> {:error, :invalid_content_digest}
        end

      [] ->
        if String.contains?(value, "sha-256"),
          do: {:error, :invalid_content_digest},
          else: {:ok, nil}

      _ ->
        {:error, :invalid_content_digest}
    end
  end

  defp content_length(%Req.Response{status: status}) when status in [204, 304], do: {:ok, 0}

  defp content_length(response) do
    case Req.Response.get_header(response, "content-length") do
      [] ->
        {:ok, nil}

      [value] ->
        case Integer.parse(value) do
          {size, ""} when size >= 0 -> {:ok, size}
          _ -> {:error, :invalid_content_length}
        end

      _ ->
        {:error, :invalid_content_length}
    end
  end

  defp response_failure(nil), do: {:error, :retryable, "HTTP response was lost after dispatch"}
  defp response_failure(writer), do: {:error, :retryable, file_failure_message(writer)}

  defp timeout_failure(nil), do: {:error, :retryable, "HTTP request reached its time limit"}

  defp timeout_failure(writer),
    do: {:error, :retryable, "HTTP request reached its time limit (file " <> writer.id <> ")"}

  defp file_failure_message(writer),
    do: "HTTP response file is incomplete (file " <> writer.id <> ")"

  defp not_cancelled(invocation, dispatched? \\ false)

  defp not_cancelled(invocation, dispatched?) do
    callback =
      if dispatched?,
        do: Map.get(invocation, :cancelled?),
        else: Map.get(invocation, :before_send?, Map.get(invocation, :cancelled?))

    cond do
      not is_function(callback, 0) or not callback.() ->
        :ok

      dispatched? ->
        {:error, :cancelled, "HTTP request was cancelled"}

      true ->
        context_failure(
          Target.Error.exception(category: :cancelled, message: "HTTP request was cancelled"),
          false
        )
    end
  rescue
    cause -> context_failure(cause, dispatched?)
  catch
    kind, reason -> context_failure(ErlangError.exception(original: {kind, reason}), dispatched?)
  end

  defp context_failure(cause, true), do: {:error, Target.Error.context_failure(cause)}
  defp context_failure(cause, false), do: {:error, Target.BeforeSendError.exception(cause: cause)}
end
