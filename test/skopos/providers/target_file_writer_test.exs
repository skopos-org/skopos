defmodule Skopos.Providers.TargetFileWriterTest do
  use ExUnit.Case, async: true

  alias Skopos.Providers.Target.FileWriter
  alias Skopos.Providers.Target

  test "one append preserves exact offsets and bytes across storage chunks" do
    owner = self()

    writer =
      writer(fn offset, bytes ->
        send(owner, {:append, offset, bytes})
        {:ok, offset + byte_size(bytes)}
      end)

    assert {:ok, 12} = FileWriter.append(writer, 7, <<1, 2, 3, 4, 5>>)
    assert_receive {:append, 7, <<1, 2>>}
    assert_receive {:append, 9, <<3, 4>>}
    assert_receive {:append, 11, <<5>>}
    assert {:ok, 12} = FileWriter.append(writer, 12, <<>>)
    refute_receive {:append, _, _}
  end

  test "cancellation, storage failure and incorrect acknowledgement stop before the next chunk" do
    owner = self()
    cancelled = :atomics.new(1, [])

    writer =
      writer(fn offset, bytes ->
        send(owner, {:append, offset, bytes})
        :atomics.put(cancelled, 1, 1)
        {:ok, offset + byte_size(bytes)}
      end)

    checkpoint = fn -> if :atomics.get(cancelled, 1) == 1, do: {:error, :cancelled}, else: :ok end

    assert {:error, :cancelled} = FileWriter.append(writer, 0, <<1, 2, 3>>, checkpoint)
    assert_receive {:append, 0, <<1, 2>>}
    refute_receive {:append, _, _}

    for {ack, expected} <- [
          {{:error, :storage_unavailable}, :storage_unavailable},
          {{:ok, 3}, :invalid_chunk_ack}
        ] do
      failed = %{
        writer
        | append: fn offset, bytes ->
            send(owner, {:append, offset, bytes})
            ack
          end
      }

      assert {:error, ^expected} = FileWriter.append(failed, 0, <<1, 2, 3>>)
      assert_receive {:append, 0, <<1, 2>>}
      refute_receive {:append, _, _}
    end
  end

  test "a marked fault retains confirmed chunks when a later append fails" do
    cause = RuntimeError.exception("storage unavailable")

    output =
      writer(fn
        0, <<1, 2>> -> {:ok, 2}
        2, <<3>> -> {:error, Target.Error.context_failure(cause)}
      end)

    assert {:error, error} = FileWriter.append(output, 0, <<1, 2, 3>>)
    assert Exception.message(error) =~ "storage unavailable"

    assert Target.Error.context_progress(error) == %{
             "receiving_file_id" => "writer",
             "received_bytes" => 2,
             "pending_chunk_bytes" => 1
           }

    enriched = Target.Error.context_failure(error, %{"http_status" => 200})

    assert Target.Error.context_progress(enriched) == %{
             "http_status" => 200,
             "receiving_file_id" => "writer",
             "received_bytes" => 2,
             "pending_chunk_bytes" => 1
           }
  end

  defp writer(append) do
    %FileWriter{
      id: "writer",
      status: :receiving,
      offset: 0,
      chunk_bytes: 2,
      append: append,
      complete: nil,
      read: nil,
      abort: nil
    }
  end
end
