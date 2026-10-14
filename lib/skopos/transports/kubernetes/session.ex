defmodule Skopos.Transports.Kubernetes.Session do
  @moduledoc false
  alias Mint.WebSocket
  alias Skopos.Providers.Target
  alias Skopos.Transports.Kubernetes
  @poll_ms 20

  def request(configuration, operation, invocation) do
    with :ok <- not_cancelled(invocation),
         {:ok, ports} <- file_ports(operation.steps, invocation) do
      deadline = System.monotonic_time(:millisecond) + configuration.request_timeout
      result = connect(configuration, operation, invocation, ports, deadline)

      # Before dispatch no receipt could have completed. After dispatch retain
      # intent and recorded bytes, including a completion whose reply was lost;
      # the Artifact lifecycle owns retention and expiry.
      if match?({:error, _, _}, result) or match?({:error, %Target.BeforeSendError{}}, result),
        do: for({_, writer} <- ports.writers, do: writer.abort.())

      result
    end
  end

  defp connect(configuration, operation, invocation, ports, deadline) do
    with :ok <- not_cancelled(invocation),
         {:ok, headers, tls} <- Kubernetes.connection_options(configuration),
         endpoint <- URI.parse(configuration.endpoint),
         true <- endpoint.scheme in ["http", "https"] and is_binary(endpoint.host),
         scheme <- if(endpoint.scheme == "https", do: :https, else: :http),
         {:ok, connection} <-
           Mint.HTTP.connect(scheme, endpoint.host, endpoint.port,
             mode: :active,
             protocols: [:http1],
             timeout: configuration.request_timeout,
             transport_opts: if(scheme == :https, do: tls, else: [])
           ) do
      try do
        with :ok <- not_cancelled(invocation),
             true <- System.monotonic_time(:millisecond) < deadline do
          run(connection, headers, configuration, operation, invocation, ports, deadline)
        else
          {:error, :cancelled, _} = error -> error
          {:error, %Target.BeforeSendError{}} = error -> error
          _ -> {:error, :failed, "Kubernetes WebSocket timed out before dispatch"}
        end
      after
        Mint.HTTP.close(connection)
      end
    else
      {:error, :cancelled, _} = error -> error
      {:error, %Target.BeforeSendError{}} = error -> error
      _ -> {:error, :failed, "Kubernetes WebSocket connection failed"}
    end
  end

  defp run(connection, headers, configuration, operation, invocation, ports, deadline) do
    query = URI.encode_query(operation.query)

    path =
      (URI.parse(configuration.endpoint).path || "") <>
        operation.path <> if(query == "", do: "", else: "?" <> query)

    headers = headers ++ [{"sec-websocket-protocol", Enum.join(operation.protocols, ", ")}]

    state = %{
      connection: connection,
      websocket: nil,
      ref: nil,
      deadline: deadline,
      invocation: invocation,
      limit: operation.max_bytes,
      inline_limit: operation.inline_bytes,
      frame_limit: operation.frame_limit,
      sent: 0,
      received: 0,
      inline_received: 0,
      received_frames: 0,
      wire_bytes: 0,
      unfinished_bytes: 0,
      queue: [],
      steps: [],
      current: nil,
      readers: ports.readers,
      writers: ports.writers,
      protocol: nil,
      protocols: operation.protocols,
      http_status: nil,
      closing?: false,
      closed: nil,
      transport_closed?: false
    }

    scheme = if URI.parse(configuration.endpoint).scheme == "https", do: :wss, else: :ws

    with :ok <- not_cancelled(invocation) do
      case WebSocket.upgrade(scheme, connection, path, headers) do
        {:ok, connection, ref} ->
          state = %{state | connection: connection, ref: ref}

          case handshake(state, nil, []) do
            {:ok, state} -> exchange(state, operation.steps)
            {:error, state, reason} -> unknown(state, reason)
          end

        _ ->
          unknown(state, "upgrade_send_failed")
      end
    end
  rescue
    _ ->
      {:ok,
       %Target.EffectResult{
         status: :unknown,
         details: %{"error" => "Kubernetes WebSocket failed after dispatch"}
       }}
  end

  defp handshake(state, status, headers) do
    case read_wire(state) do
      {:ok, next, events} ->
        status =
          Enum.find_value(events, status, fn
            {:status, _, code} -> code
            _ -> nil
          end)

        headers =
          Enum.reduce(events, headers, fn
            {:headers, _, fields}, acc -> acc ++ fields
            _, acc -> acc
          end)

        next = %{next | http_status: status}

        if Enum.any?(events, &match?({:done, _}, &1)) do
          protocol = for {"sec-websocket-protocol", value} <- headers, do: value

          case {protocol, WebSocket.new(next.connection, next.ref, status, headers)} do
            {[selected], {:ok, connection, websocket}} ->
              if selected in next.protocols,
                do:
                  decode_events(
                    %{next | connection: connection, websocket: websocket, protocol: selected},
                    events
                  ),
                else: {:error, next, "upgrade_rejected"}

            _ ->
              {:error, next, "upgrade_rejected"}
          end
        else
          handshake(next, status, headers)
        end

      {:error, next, reason} ->
        {:error, next, reason}
    end
  end

  defp exchange(state, []) do
    details = details(state)

    {:ok,
     %Target.EffectResult{
       status: if(details["omitted_bytes"] == 0, do: :applied, else: :unknown),
       details:
         Map.put(
           details,
           "completion_reason",
           if(details["omitted_bytes"] == 0, do: "sequence_complete", else: "inline_limit")
         )
     }}
  end

  defp exchange(state, [step | rest]) do
    state = %{state | current: %{"op" => Atom.to_string(step.op), "index" => length(state.steps)}}

    case step(state, step) do
      {:ok, next, result} ->
        exchange(%{next | steps: next.steps ++ [result], current: nil}, rest)

      {:error, next, reason} ->
        unknown(next, reason)
    end
  end

  defp step(state, %{op: :send, file: file, prefix: prefix}) do
    reader = state.readers[length(state.steps)]

    case send_file(state, file, reader, prefix, 0) do
      {:ok, next} ->
        {:ok, next,
         %{"op" => "send", "file_id" => file["id"], "bytes_sent" => next.sent - state.sent}}

      error ->
        error
    end
  end

  defp step(state, %{op: :send, frame: frame}) do
    if state.sent + byte_size(elem(frame, 1)) > state.limit do
      {:error, state, "byte_limit"}
    else
      with {:ok, next} <- send_frame(state, frame),
           do:
             {:ok, %{next | sent: next.sent + byte_size(elem(frame, 1))},
              %{"op" => "send", "bytes_sent" => byte_size(elem(frame, 1))}}
    end
  end

  defp step(state, %{op: :receive, count: count} = step) do
    matcher = if Map.get(step, :until_close?), do: {:close, count}, else: count
    writer = state.writers[length(state.steps)]
    current = Map.merge(state.current, %{"frames" => [], "size_bytes" => 0})
    current = if writer, do: Map.put(current, "receiving_file_id", writer.id), else: current
    state = %{state | current: current}

    case frames(state, matcher) do
      {:ok, next} ->
        result = %{"op" => "receive", "frames" => next.current["frames"]}

        if writer do
          reason = if Map.get(step, :until_close?), do: :eof, else: :entry_limit

          case port_call(
                 fn -> writer.complete.(next.current["size_bytes"], nil, reason) end,
                 true
               ) do
            {:ok, file} ->
              if Target.FileReference.valid?(file) and file["id"] == writer.id and
                   file["size_bytes"] == next.current["size_bytes"],
                 do: {:ok, next, Map.put(result, "file", file)},
                 else: {:error, next, "file_complete_failed"}

            {:error, cause} ->
              {:error, next, Target.Error.context_failure(cause)}

            _ ->
              {:error, next, "file_complete_failed"}
          end
        else
          {:ok, next, result}
        end

      error ->
        error
    end
  end

  defp step(%{closed: %{code: code, reason: reason}} = state, %{op: :close}) do
    if code in [1_000, 1_001],
      do:
        {:ok, state,
         %{
           "op" => "close",
           "code" => code,
           "reason" => reason,
           "reply_sent" => state.closed.reply_sent
         }},
      else: {:error, state, "remote_close_error"}
  end

  defp step(state, %{op: :close}) do
    case send_frame(state, :close) do
      {:ok, next} -> await_close(%{next | closing?: true})
      error -> error
    end
  end

  defp await_close(%{closed: closed} = state) when not is_nil(closed),
    do: step(state, %{op: :close})

  defp await_close(state) do
    with {:ok, next} <- receive_frames(state), do: await_close(next)
  end

  # Keep the last confirmed local send count if a later file read fails.
  defp send_file(state, %{"size_bytes" => size}, _, _, size), do: {:ok, state}

  defp send_file(state, file, reader, prefix, offset) do
    with :ok <- not_cancelled(state.invocation, :waiting),
         {:ok, bytes} when is_binary(bytes) and byte_size(bytes) > 0 <-
           port_call(fn -> reader.(offset) end, true),
         true <- offset + byte_size(bytes) <= file["size_bytes"],
         {:ok, next, _} <- step(state, %{op: :send, frame: {:binary, prefix <> bytes}}) do
      send_file(next, file, reader, prefix, offset + byte_size(bytes))
    else
      {:error, %{connection: _}, _} = error -> error
      {:error, :cancelled, _} -> {:error, state, "cancelled"}
      {:error, cause} -> {:error, state, Target.Error.context_failure(cause)}
      _ -> {:error, state, "file_read_failed_after_dispatch"}
    end
  rescue
    cause -> {:error, state, Target.Error.context_failure(cause)}
  end

  defp frames(%{queue: []} = state, {:close, _}) when not is_nil(state.closed),
    do: {:ok, state}

  defp frames(%{queue: [_ | _]} = state, {:close, 0}), do: {:error, state, "frame_limit"}

  defp frames(%{queue: [{opcode, bytes} | tail]} = state, {:close, remaining}),
    do: deliver(state, tail, opcode, bytes, {:close, remaining - 1})

  defp frames(state, {:close, remaining}) do
    with {:ok, next} <- receive_frames(state), do: frames(next, {:close, remaining})
  end

  defp frames(state, 0), do: {:ok, state}

  defp frames(%{queue: [{opcode, bytes} | tail]} = state, count)
       when opcode in [:binary, :text],
       do: deliver(state, tail, opcode, bytes, count - 1)

  defp frames(%{closed: closed} = state, _) when not is_nil(closed),
    do: {:error, state, "remote_closed_before_receive"}

  defp frames(state, count) do
    with {:ok, next} <- receive_frames(state), do: frames(next, count)
  end

  defp deliver(state, tail, opcode, bytes, matcher) do
    writer = state.writers[state.current["index"]]
    offset = state.current["size_bytes"]

    result =
      if writer,
        do: %{
          "opcode" => Atom.to_string(opcode),
          "offset" => offset,
          "size_bytes" => byte_size(bytes)
        },
        else: %{"opcode" => Atom.to_string(opcode), "data" => Base.encode64(bytes)}

    with :ok <- store_frame(writer, offset, bytes, state),
         do:
           frames(
             %{
               state
               | queue: tail,
                 inline_received:
                   state.inline_received + if(writer, do: 0, else: byte_size(bytes)),
                 current: %{
                   state.current
                   | "frames" => state.current["frames"] ++ [result],
                     "size_bytes" => offset + byte_size(bytes)
                 }
             },
             matcher
           ),
         else: (
           {:error, cause} -> {:error, state, cause}
           _ -> {:error, state, "file_or_inline_limit"}
         )
  end

  defp store_frame(nil, _, bytes, state),
    do: if(state.inline_received + byte_size(bytes) <= state.inline_limit, do: :ok, else: :error)

  defp store_frame(writer, offset, bytes, state) do
    case port_call(
           fn ->
             Target.FileWriter.append(writer, offset, bytes, fn ->
               not_cancelled(state.invocation, :waiting)
             end)
           end,
           true
         ) do
      {:ok, _next} -> :ok
      {:error, cause} -> {:error, Target.Error.context_failure(cause)}
      _ -> :error
    end
  end

  defp receive_frames(state) do
    with {:ok, next, events} <- read_wire(state) do
      decode_events(next, events)
    end
  end

  defp decode_events(next, events) do
    Enum.reduce_while(events, {:ok, next}, fn
      {:data, _, bytes}, {:ok, acc} ->
        if acc.wire_bytes + byte_size(bytes) > acc.limit + 65_536 or
             acc.unfinished_bytes + byte_size(bytes) > 1_114_112 do
          {:halt, {:error, acc, "byte_limit"}}
        else
          case WebSocket.decode(acc.websocket, bytes) do
            {:ok, websocket, frames} ->
              consume(
                %{
                  acc
                  | websocket: websocket,
                    wire_bytes: acc.wire_bytes + byte_size(bytes),
                    unfinished_bytes:
                      if(
                        Enum.any?(
                          frames,
                          &match?({opcode, _} when opcode in [:binary, :text], &1)
                        ),
                        do: 0,
                        else: acc.unfinished_bytes + byte_size(bytes)
                      )
                },
                frames
              )
              |> case do
                {:ok, next} -> {:cont, {:ok, next}}
                error -> {:halt, error}
              end

            _ ->
              {:halt, {:error, acc, "invalid_frame"}}
          end
        end

      _, acc ->
        {:cont, acc}
    end)
  end

  defp consume(state, []), do: {:ok, state}

  defp consume(state, [{:ping, bytes} | rest]) do
    with {:ok, next} <- send_frame(state, {:pong, bytes}), do: consume(next, rest)
  end

  defp consume(state, [{:pong, _} | rest]), do: consume(state, rest)

  defp consume(state, [{:close, code, reason} | rest]) do
    state = %{state | closed: %{code: code, reason: reason, reply_sent: state.closing?}}

    if state.closing? do
      consume(state, rest)
    else
      case send_frame(state, {:close, code, reason}) do
        {:ok, next} ->
          consume(%{next | closing?: true, closed: %{state.closed | reply_sent: true}}, rest)

        {:error, next, %{errors: _} = cause} ->
          {:error, next, cause}

        {:error, next, _} ->
          consume(next, rest)
      end
    end
  end

  defp consume(state, [{opcode, bytes} | rest]) when opcode in [:binary, :text] do
    if state.received + byte_size(bytes) <= state.limit and byte_size(bytes) <= 1_048_576 and
         state.received_frames < state.frame_limit do
      consume(
        %{
          state
          | received: state.received + byte_size(bytes),
            received_frames: state.received_frames + 1,
            queue: state.queue ++ [{opcode, bytes}]
        },
        rest
      )
    else
      {:error, state, "byte_limit"}
    end
  end

  defp consume(state, _), do: {:error, state, "invalid_frame"}

  defp send_frame(state, frame) do
    with :ok <- not_cancelled(state.invocation, :sending),
         {:ok, websocket, bytes} <- WebSocket.encode(state.websocket, frame),
         {:ok, connection} <- WebSocket.stream_request_body(state.connection, state.ref, bytes) do
      {:ok, %{state | connection: connection, websocket: websocket}}
    else
      {:error, :cancelled, _} -> {:error, state, "cancelled"}
      {:error, %{errors: _} = cause} -> {:error, state, cause}
      _ -> {:error, state, "send_failed"}
    end
  end

  defp read_wire(state) do
    case receive_wire(state, 0) do
      :empty -> wait_wire(state)
      result -> result
    end
  end

  defp wait_wire(state) do
    remaining = state.deadline - System.monotonic_time(:millisecond)
    check = not_cancelled(state.invocation, :waiting)

    # A stop check may block while the remote response arrives. Retain that
    # response before returning the stop result; new sends still check context.
    case receive_wire(state, 0) do
      :empty ->
        cond do
          match?({:error, _}, check) ->
            {:error, cause} = check
            {:error, state, cause}

          check != :ok ->
            {:error, state, "cancelled"}

          remaining <= 0 ->
            {:error, state, "duration_limit"}

          state.transport_closed? ->
            {:error, state, "disconnected"}

          true ->
            case receive_wire(state, min(@poll_ms, remaining)) do
              :empty -> read_wire(state)
              result -> result
            end
        end

      result ->
        result
    end
  end

  defp receive_wire(state, wait) do
    socket = Mint.HTTP.get_socket(state.connection)

    receive do
      {:tcp, ^socket, _} = message -> stream_message(state, message)
      {:tcp_closed, ^socket} = message -> stream_message(state, message)
      {:tcp_error, ^socket, _} = message -> stream_message(state, message)
      {:ssl, ^socket, _} = message -> stream_message(state, message)
      {:ssl_closed, ^socket} = message -> stream_message(state, message)
      {:ssl_error, ^socket, _} = message -> stream_message(state, message)
    after
      wait -> :empty
    end
  end

  defp stream_message(state, message) do
    case WebSocket.stream(state.connection, message) do
      {:ok, connection, events} ->
        {:ok, %{state | connection: connection}, events}

      {:error, connection, _, events} when events != [] ->
        {:ok, %{state | connection: connection, transport_closed?: true}, events}

      {:error, connection, _, _} ->
        {:error, %{state | connection: connection}, "disconnected"}

      :unknown ->
        {:error, state, "invalid_transport_message"}
    end
  end

  defp details(state) do
    {buffered, omitted} = buffered(state)

    %{
      "protocol" => state.protocol,
      "http_status" => state.http_status,
      "steps" => state.steps,
      "bytes_sent" => state.sent,
      "bytes_received" => state.received,
      "current_step" => state.current,
      "close" =>
        if(state.closed,
          do: Map.new(state.closed, fn {key, value} -> {Atom.to_string(key), value} end)
        ),
      "buffered_frames" => buffered,
      "omitted_bytes" => omitted
    }
  end

  defp buffered(state) do
    {frames, _, omitted} =
      Enum.reduce(state.queue, {[], state.inline_limit - state.inline_received, 0}, fn {opcode,
                                                                                        bytes},
                                                                                       {frames,
                                                                                        remaining,
                                                                                        omitted} ->
        if byte_size(bytes) <= remaining do
          {frames ++ [%{"opcode" => Atom.to_string(opcode), "data" => Base.encode64(bytes)}],
           remaining - byte_size(bytes), omitted}
        else
          {frames ++
             [
               %{
                 "opcode" => Atom.to_string(opcode),
                 "size_bytes" => byte_size(bytes),
                 "content_omitted" => true
               }
             ], remaining, omitted + byte_size(bytes)}
        end
      end)

    {frames, omitted}
  end

  defp unknown(state, %{errors: _} = cause),
    do: {:error, Target.Error.context_failure(cause, details(state))}

  defp unknown(state, reason),
    do:
      {:ok,
       %Target.EffectResult{
         status: :unknown,
         details: Map.put(details(state), "completion_reason", reason)
       }}

  defp file_ports(steps, invocation) do
    Enum.with_index(steps)
    |> Enum.reduce_while({:ok, %{readers: %{}, writers: %{}}}, fn {step, index}, {:ok, ports} ->
      result =
        case step do
          %{file: file, label: label} ->
            reader = Map.get(invocation, :file_reader)

            if is_function(reader, 2) do
              case port_call(fn -> reader.(label, 0) end, false) do
                {:ok, bytes} when is_binary(bytes) ->
                  if byte_size(bytes) <= file["size_bytes"] and
                       (file["size_bytes"] == 0 or byte_size(bytes) > 0),
                     do:
                       {:ok,
                        %{ports | readers: Map.put(ports.readers, index, &reader.(label, &1))}},
                     else: :error

                {:error, %Target.BeforeSendError{}} = error ->
                  error

                {:error, cause} ->
                  {:error, Target.BeforeSendError.exception(cause: cause)}

                _ ->
                  :error
              end
            else
              :error
            end

          %{response_file: %{"name" => name, "media_type" => media}} ->
            writer = Map.get(invocation, :file_writer)

            if is_function(writer, 3) do
              case port_call(fn -> writer.(Ecto.UUID.generate(), name, media) end, false) do
                {:ok, %Target.FileWriter{status: :receiving, offset: 0} = capture} ->
                  {:ok, %{ports | writers: Map.put(ports.writers, index, capture)}}

                {:error, %Target.BeforeSendError{}} = error ->
                  error

                {:error, cause} ->
                  {:error, Target.BeforeSendError.exception(cause: cause)}

                _ ->
                  :error
              end
            else
              :error
            end

          _ ->
            {:ok, ports}
        end

      case result do
        {:ok, ports} ->
          {:cont, {:ok, ports}}

        {:error, cause} ->
          for {_, writer} <- ports.writers, do: writer.abort.()
          {:halt, {:error, cause}}

        _ ->
          for {_, writer} <- ports.writers, do: writer.abort.()
          {:halt, {:error, :failed, "Kubernetes WebSocket file is unavailable"}}
      end
    end)
  end

  defp not_cancelled(invocation, phase \\ :before_send) do
    dispatched? = phase != :before_send
    waiting = Map.get(invocation, :cancelled?, fn -> false end)

    callback =
      if phase == :waiting,
        do: waiting,
        else: Map.get(invocation, :before_send?, waiting)

    cond do
      not callback.() ->
        :ok

      dispatched? ->
        {:error, :cancelled, "Kubernetes WebSocket was cancelled"}

      true ->
        context_failure(
          Target.Error.exception(
            category: :cancelled,
            message: "Kubernetes WebSocket was cancelled"
          ),
          false
        )
    end
  rescue
    cause -> context_failure(cause, phase != :before_send)
  catch
    kind, reason ->
      context_failure(ErlangError.exception(original: {kind, reason}), phase != :before_send)
  end

  defp port_call(callback, dispatched?) do
    callback.()
  rescue
    cause -> context_failure(cause, dispatched?)
  catch
    kind, reason -> context_failure(ErlangError.exception(original: {kind, reason}), dispatched?)
  end

  defp context_failure(cause, true), do: {:error, Target.Error.context_failure(cause)}
  defp context_failure(cause, false), do: {:error, Target.BeforeSendError.exception(cause: cause)}
end
