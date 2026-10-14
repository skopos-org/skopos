defmodule Skopos.Transports.SSH.Subsystem do
  @moduledoc false
  alias Skopos.Transports.SSH
  alias Skopos.Providers.Target

  def request(operation, invocation, runner) do
    with {:ok, readers, writers} <- file_ports(operation.steps, invocation) do
      runner.(fn channel -> exchange(channel, operation, readers, writers) end)
    end
  end

  defp exchange(channel, operation, readers, writers) do
    initial = %{
      channel: channel,
      buffers: %{0 => <<>>, 1 => <<>>},
      eof?: false,
      sent: 0,
      received: 0,
      limit:
        if(operation.file_output?,
          do: operation.max_bytes,
          else: min(channel.max_output_bytes, operation.max_bytes)
        ),
      inline_limit: operation.inline_bytes,
      inline_received: 0,
      inline_delivered: 0,
      readers: readers,
      writers: writers,
      results: [],
      current: nil
    }

    Enum.with_index(operation.steps)
    |> Enum.reduce_while({:ok, initial}, fn {step, index}, {:ok, state} ->
      current = %{"index" => index, "op" => step["op"]}

      current =
        if writer = writers[index],
          do:
            Map.merge(current, %{
              "receiving_file_id" => writer.id,
              "stream" => step.stream,
              "size_bytes" => 0
            }),
          else: current

      state = %{state | current: current}
      report(state)

      case step(state, step) do
        {:ok, result, next} ->
          next = %{next | results: [Map.put(result, "index", index) | next.results]}
          report(next)
          {:cont, {:ok, next}}

        error ->
          {:halt, error}
      end
    end)
    |> case do
      {:ok, state} ->
        {:ok,
         Map.put(progress(state), "completion_reason", "sequence_complete")
         |> Map.delete("current_step")}

      error ->
        error
    end
  end

  defp step(state, %{"op" => "send", :bytes => bytes}) do
    with :ok <- SSH.channel_send(state.channel, bytes),
         do:
           {:ok, %{"op" => "send", "bytes_sent" => byte_size(bytes)},
            %{state | sent: state.sent + byte_size(bytes)}}
  end

  defp step(state, %{"op" => "send", :file => file}) do
    file
    |> Target.FileWriter.stream(state.readers[state.current["index"]])
    |> Enum.reduce_while({:ok, state}, fn bytes, {:ok, next} ->
      case send_file(next, bytes) do
        {:ok, next} -> {:cont, {:ok, next}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, next} ->
        {:ok, %{"op" => "send", "bytes_sent" => file["size_bytes"], "file_id" => file["id"]},
         next}

      error ->
        error
    end
  catch
    :throw, {:file_read_error, cause} ->
      file_error(cause, :in_flight, %{"input_file_id" => file["id"]})
  end

  defp step(state, %{"op" => "send_eof"}) do
    with :ok <- SSH.channel_eof(state.channel),
         do: {:ok, %{"op" => "send_eof"}, state}
  end

  defp step(state, %{"op" => "close"}) do
    with :ok <- inline_budget(state),
         :ok <- SSH.channel_close(state.channel),
         do:
           {:ok, %{"op" => "close", "unconsumed" => buffered(state)},
            %{state | buffers: %{0 => <<>>, 1 => <<>>}}}
  end

  defp step(state, %{
         "op" => "receive",
         "response_file" => _,
         :matcher => matcher,
         :stream => stream
       }) do
    writer = state.writers[state.current["index"]]

    with {:ok, file, next} <- receive_file(state, matcher, stream, writer, 0),
         do: {:ok, %{"op" => "receive", "stream" => stream, "file" => file}, next}
  end

  defp step(state, %{"op" => "receive", :matcher => matcher, :stream => stream}) do
    with {:ok, bytes, next} <- receive_bytes(state, matcher, stream),
         do:
           {:ok,
            %{
              "op" => "receive",
              "stream" => stream,
              "data" => Base.encode64(bytes),
              "size_bytes" => byte_size(bytes)
            }, next}
  end

  defp receive_bytes(state, matcher, stream) do
    with :ok <- inline_budget(state) do
      report(state)

      case extract(state.buffers[stream], matcher, state.eof?) do
        {:ok, bytes, rest} ->
          {:ok, bytes,
           %{
             state
             | buffers: Map.put(state.buffers, stream, rest),
               inline_delivered: state.inline_delivered + byte_size(bytes)
           }}

        :more ->
          receive_next(state, &receive_bytes(&1, matcher, stream))

        :incomplete ->
          {:error, :disconnected_after_dispatch,
           "SSH subsystem ended before the requested receive completed"}
      end
    end
  end

  defp inline_budget(state) do
    if state.inline_delivered +
         Enum.reduce(state.buffers, 0, fn {_, bytes}, size -> size + byte_size(bytes) end) <=
         state.inline_limit,
       do: :ok,
       else:
         {:error, :output_limit_after_dispatch,
          "SSH subsystem inline evidence exceeded its limit; select response_file for larger output"}
  end

  defp send_file(state, <<>>), do: {:ok, state}

  defp send_file(state, bytes) do
    count = min(byte_size(bytes), 24_000)
    <<chunk::binary-size(^count), tail::binary>> = bytes

    with :ok <- SSH.channel_send(state.channel, chunk) do
      next = %{
        state
        | sent: state.sent + count,
          current: Map.put(state.current, "bytes_sent", state.sent + count)
      }

      report(next)
      send_file(next, tail)
    end
  end

  defp receive_file(state, matcher, stream, writer, offset) do
    case extract(state.buffers[stream], matcher, state.eof?) do
      {:ok, bytes, rest} ->
        with {:ok, next} <- append_file(state, stream, writer, offset, bytes, rest),
             {:ok, file} <-
               complete_file(
                 writer,
                 offset + byte_size(bytes),
                 if(matcher == :eof, do: :eof, else: :byte_limit)
               ) do
          {:ok, file, next}
        end

      :more ->
        count = flush_count(state.buffers[stream], matcher)
        <<bytes::binary-size(^count), rest::binary>> = state.buffers[stream]

        with {:ok, next} <- append_file(state, stream, writer, offset, bytes, rest) do
          next_matcher =
            case matcher do
              {:bytes, remaining} -> {:bytes, remaining - count}
              other -> other
            end

          receive_next(next, &receive_file(&1, next_matcher, stream, writer, offset + count))
        end

      :incomplete ->
        {:error, :disconnected_after_dispatch,
         "SSH subsystem ended before the file receive completed"}
    end
  end

  defp flush_count(buffer, {:delimiter, delimiter}),
    do: max(byte_size(buffer) - byte_size(delimiter) + 1, 0)

  defp flush_count(buffer, _), do: byte_size(buffer)

  defp append_file(state, stream, writer, offset, bytes, rest) do
    with {:ok, _next_offset} <- Target.FileWriter.append(writer, offset, bytes) do
      next = %{
        state
        | buffers: Map.put(state.buffers, stream, rest),
          current: Map.put(state.current, "size_bytes", offset + byte_size(bytes))
      }

      report(next)
      {:ok, next}
    else
      {:error, cause} -> file_error(cause, :in_flight)
      _ -> file_error()
    end
  end

  defp complete_file(writer, size, reason) do
    case writer.complete.(size, nil, reason) do
      {:ok, file} ->
        if(Target.FileReference.valid?(file) and file["size_bytes"] == size,
          do: {:ok, file},
          else: file_error()
        )

      {:error, cause} ->
        file_error(cause, :in_flight, %{
          "receiving_file_id" => writer.id,
          "received_bytes" => size
        })

      _ ->
        file_error()
    end
  end

  defp receive_next(%{channel: channel} = state, continue) do
    receive do
      {:ssh_cm, connection, {:data, id, stream, bytes}}
      when connection == channel.connection and id == channel.id and stream in [0, 1] and
             is_binary(bytes) ->
        selected_file? =
          Map.has_key?(state.current, "receiving_file_id") and state.current["stream"] == stream

        inline_received =
          state.inline_received + if(selected_file?, do: 0, else: byte_size(bytes))

        if state.received + byte_size(bytes) > state.limit or inline_received > state.inline_limit do
          {:error, :output_limit_after_dispatch,
           "SSH subsystem cumulative output exceeded its limit"}
        else
          :ssh_connection.adjust_window(connection, id, byte_size(bytes))

          next = %{
            state
            | buffers: Map.update!(state.buffers, stream, &(&1 <> bytes)),
              received: state.received + byte_size(bytes),
              inline_received: inline_received
          }

          continue.(next)
        end

      {:ssh_cm, connection, {:eof, id}}
      when connection == channel.connection and id == channel.id ->
        continue.(%{state | eof?: true})

      {:ssh_cm, connection, {:closed, id}}
      when connection == channel.connection and id == channel.id ->
        {:error, :disconnected_after_dispatch, "SSH subsystem closed unexpectedly"}

      {:ssh_cm, connection, {:exit_status, id, status}}
      when connection == channel.connection and id == channel.id ->
        receive_next(Map.put(state, :exit_status, status), continue)

      {:ssh_cm, connection, {:exit_signal, id, _, _, _}}
      when connection == channel.connection and id == channel.id ->
        {:error, :disconnected_after_dispatch, "SSH subsystem exited unexpectedly"}
    after
      max(channel.deadline - System.monotonic_time(:millisecond), 0) ->
        {:error, :timeout_after_dispatch, "SSH subsystem receive timed out"}
    end
  end

  defp extract(buffer, {:bytes, count}, _) when byte_size(buffer) >= count do
    <<bytes::binary-size(^count), rest::binary>> = buffer
    {:ok, bytes, rest}
  end

  defp extract(buffer, {:delimiter, delimiter}, eof?) do
    case :binary.match(buffer, delimiter) do
      {offset, size} -> extract(buffer, {:bytes, offset + size}, eof?)
      :nomatch -> if(eof?, do: :incomplete, else: :more)
    end
  end

  defp extract(buffer, :eof, true), do: {:ok, buffer, <<>>}
  defp extract(_, :eof, false), do: :more
  defp extract(_, _, true), do: :incomplete
  defp extract(_, _, false), do: :more
  defp report(state), do: SSH.channel_progress(state.channel, progress(state))

  defp progress(state) do
    result = %{
      "steps" => Enum.reverse(state.results),
      "current_step" => state.current,
      "bytes_sent" => state.sent,
      "bytes_received" => state.received,
      "buffered" => buffered(state)
    }

    if Map.has_key?(state, :exit_status),
      do: Map.put(result, "exit_status", state.exit_status),
      else: result
  end

  defp buffered(state),
    do:
      Map.new(state.buffers, fn {stream, bytes} ->
        file? =
          Map.has_key?(state.current || %{}, "receiving_file_id") and
            state.current["stream"] == stream

        {to_string(stream),
         if(file?, do: %{"unpublished_bytes" => byte_size(bytes)}, else: Base.encode64(bytes))}
      end)

  defp file_ports(steps, invocation) do
    Enum.with_index(steps)
    |> Enum.reduce_while({:ok, %{}, %{}}, fn {step, index}, {:ok, readers, writers} ->
      case step do
        %{"body_file" => label, :file => file} ->
          size = file["size_bytes"]

          case Map.get(invocation, :file_reader) do
            reader when is_function(reader, 2) ->
              case reader.(label, 0) do
                {:ok, bytes}
                when is_binary(bytes) and byte_size(bytes) <= size and
                       (size == 0 or byte_size(bytes) > 0) ->
                  {:cont, {:ok, Map.put(readers, index, &reader.(label, &1)), writers}}

                {:error, cause} ->
                  {:halt, file_error(cause, :before_send)}

                _ ->
                  {:halt, file_error()}
              end

            _ ->
              {:halt, file_error()}
          end

        %{"response_file" => %{"name" => name, "media_type" => media}} ->
          case Map.get(invocation, :file_writer) do
            writer when is_function(writer, 3) ->
              case writer.(Ecto.UUID.generate(), name, media) do
                {:ok, %Target.FileWriter{status: :receiving, offset: 0} = capture} ->
                  {:cont, {:ok, readers, Map.put(writers, index, capture)}}

                {:error, cause} ->
                  {:halt, file_error(cause, :before_send)}

                _ ->
                  {:halt, file_error()}
              end

            _ ->
              {:halt, file_error()}
          end

        _ ->
          {:cont, {:ok, readers, writers}}
      end
    end)
  end

  defp file_error, do: {:error, :failed, "SSH subsystem file could not be read or published"}

  defp file_error(cause, phase, progress \\ nil) do
    if Target.Error.context_failure?(cause) do
      if phase == :before_send,
        do: {:error, Target.BeforeSendError.exception(cause: cause)},
        else: {:error, Target.Error.context_failure(cause, progress)}
    else
      file_error()
    end
  end
end
