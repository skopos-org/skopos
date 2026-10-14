defmodule SkoposCLI.FileTransfer do
  @moduledoc false

  alias SkoposCLI.Client

  @hash_chunk_bytes 65_536

  def download(client, target_id, id, options) do
    context = %{"target_id" => target_id, "file_id" => id}
    path = "/targets/#{URI.encode_www_form(target_id)}/files/#{URI.encode_www_form(id)}"

    with {:ok, destination} <- required(options[:output], "--output PATH", context),
         :ok <- unused_destination(destination, context),
         {:ok, %{"data" => limits}} <- request(client, :get, "/target-file-limits", nil, context),
         {:ok, %{"data" => file}} <- request(client, :get, path, nil, context),
         :ok <- check(file["status"] == "ready", "File is not available for download", context),
         :ok <-
           check(
             file["size_bytes"] <= limits["max_size_bytes"],
             "File exceeds the server transfer limit",
             context
           ) do
      download_file(client, path, file, limits["chunk_bytes"], destination, context)
    end
  end

  defp download_file(client, path, file, chunk_size, destination, context) do
    temporary =
      destination <> ".part-" <> Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false)

    with {:ok, io} <- local(File.open(temporary, [:write, :binary, :exclusive]), context) do
      try do
        with :ok <- local(File.chmod(temporary, 0o600), context),
             :ok <-
               download_chunks(
                 client,
                 path,
                 file,
                 chunk_size,
                 io,
                 0,
                 :crypto.hash_init(:sha256),
                 context
               ),
             :ok <- local(:file.sync(io), context),
             :ok <- local(File.close(io), context),
             :ok <- local(File.ln(temporary, destination), context) do
          {:ok, %{"data" => file}}
        end
      after
        File.close(io)
        File.rm(temporary)
      end
    end
  end

  defp download_chunks(
         client,
         path,
         %{"size_bytes" => 0, "sha256" => expected},
         _chunk_size,
         _io,
         0,
         hash,
         context
       ) do
    with {:ok, _status, bytes} <-
           contextual(Client.request_binary(client, :get, path <> "/chunks/0"), context),
         :ok <- check(bytes == <<>>, "Server returned invalid download bytes", context) do
      actual = hash |> :crypto.hash_final() |> Base.encode16(case: :lower)
      check(actual == expected, "Downloaded file integrity check failed", context)
    end
  end

  defp download_chunks(
         _client,
         _path,
         %{"size_bytes" => offset, "sha256" => expected},
         _chunk_size,
         _io,
         offset,
         hash,
         context
       ) do
    actual = hash |> :crypto.hash_final() |> Base.encode16(case: :lower)
    check(actual == expected, "Downloaded file integrity check failed", context)
  end

  defp download_chunks(client, path, file, chunk_size, io, offset, hash, context) do
    context = Map.put(context, "offset", offset)

    with {:ok, _status, bytes} <-
           contextual(Client.request_binary(client, :get, path <> "/chunks/#{offset}"), context),
         :ok <-
           check(
             is_binary(bytes) and byte_size(bytes) > 0 and byte_size(bytes) <= chunk_size and
               offset + byte_size(bytes) <= file["size_bytes"],
             "Server returned invalid download bytes",
             context
           ),
         :ok <- local(IO.binwrite(io, bytes), context) do
      download_chunks(
        client,
        path,
        file,
        chunk_size,
        io,
        offset + byte_size(bytes),
        :crypto.hash_update(hash, bytes),
        context
      )
    end
  end

  defp unused_destination(path, context) do
    case File.lstat(path) do
      {:error, :enoent} -> :ok
      {:ok, _stat} -> {:error, :local, "Output file already exists", context}
      error -> local(error, context)
    end
  end

  def upload(client, target_id, options) do
    context = %{
      "target_id" => target_id,
      "upload_key" => options[:upload_key],
      "file_id" => options[:resume]
    }

    with {:ok, path} <- required(options[:file], "--file PATH", context),
         {:ok, key} <- upload_key(options, context),
         {:ok, %{"data" => limits}} <- request(client, :get, "/target-file-limits", nil, context),
         {:ok, stat} <- local(File.stat(path), context),
         :ok <- check(stat.type == :regular, "Input must be a regular file", context),
         :ok <-
           check(
             stat.size <= limits["max_size_bytes"],
             "File exceeds the server transfer limit",
             context
           ),
         {:ok, io} <- local(File.open(path, [:read, :binary]), context) do
      try do
        with {:ok, digest, size} <- hash_file(io, limits["max_size_bytes"], context),
             :ok <- check(size == stat.size, "Input changed while being read", context) do
          metadata = %{
            "name" => Path.basename(path),
            "media_type" => options[:media_type] || "application/octet-stream",
            "size_bytes" => size,
            "expected_sha256" => digest,
            "upload_key" => key
          }

          upload_file(
            client,
            target_id,
            io,
            metadata,
            limits["chunk_bytes"],
            options[:resume],
            context
          )
        end
      after
        File.close(io)
      end
    end
  end

  defp upload_file(client, target_id, io, metadata, chunk_size, resume, context) do
    path = "/targets/#{URI.encode_www_form(target_id)}/files"

    with {:ok, %{"data" => file}} <- begin_or_resume(client, path, metadata, resume, context),
         :ok <-
           check(
             file["expected_sha256"] == metadata["expected_sha256"],
             "Resume file digest does not match the local file",
             context
           ),
         :ok <-
           check(
             file["size_bytes"] == metadata["size_bytes"] and file["name"] == metadata["name"],
             "Resume file metadata does not match the local file",
             context
           ),
         :ok <-
           check(
             file["status"] in ["uploading", "ready"],
             "File is unavailable for upload",
             context
           ) do
      context = Map.merge(context, %{"file_id" => file["id"], "offset" => file["received_bytes"]})
      file_path = path <> "/" <> URI.encode_www_form(file["id"])

      with {:ok, uploaded} <- upload_chunks(client, file_path, io, file, chunk_size, context),
           {:ok, %{"data" => complete} = response} <-
             request(
               client,
               :post,
               file_path <> "/complete",
               nil,
               Map.put(context, "offset", uploaded["received_bytes"])
             ),
           :ok <-
             check(
               complete["status"] == "ready" and complete["sha256"] == metadata["expected_sha256"],
               "Published file does not match the local digest",
               context
             ) do
        {:ok, response}
      end
    end
  end

  defp upload_key(options, context) do
    cond do
      options[:resume] && options[:upload_key] ->
        {:error, :local, "Choose --upload-key or --resume", context}

      options[:resume] ->
        {:ok, nil}

      true ->
        required(options[:upload_key], "--upload-key KEY or --resume FILE_ID", context)
    end
  end

  defp begin_or_resume(client, path, metadata, nil, context),
    do: request(client, :post, path, %{"file" => metadata}, context)

  defp begin_or_resume(client, path, _metadata, id, context),
    do: request(client, :get, path <> "/" <> URI.encode_www_form(id), nil, context)

  defp upload_chunks(
         _client,
         _path,
         _io,
         %{"received_bytes" => size, "size_bytes" => size} = file,
         _chunk_size,
         _context
       ),
       do: {:ok, file}

  defp upload_chunks(client, path, io, file, chunk_size, context) do
    offset = file["received_bytes"]
    count = min(chunk_size, file["size_bytes"] - offset)
    context = Map.put(context, "offset", offset)

    with {:ok, bytes} <- local(:file.pread(io, offset, count), context),
         :ok <- check(byte_size(bytes) == count, "Input changed during upload", context),
         {:ok, _status, encoded} <-
           contextual(
             Client.request_binary(client, :put, path <> "/chunks/#{offset}", bytes),
             context
           ),
         {:ok, %{"data" => next}} <- decode(encoded, context),
         :ok <-
           check(
             next["received_bytes"] == offset + count,
             "Server returned unexpected upload progress",
             context
           ) do
      upload_chunks(client, path, io, next, chunk_size, context)
    end
  end

  defp hash_file(io, maximum, context),
    do: hash_file(io, maximum, 0, :crypto.hash_init(:sha256), context)

  defp hash_file(io, maximum, size, hash, context) do
    case :file.read(io, @hash_chunk_bytes) do
      {:ok, bytes} when size + byte_size(bytes) <= maximum ->
        hash_file(io, maximum, size + byte_size(bytes), :crypto.hash_update(hash, bytes), context)

      {:ok, _bytes} ->
        {:error, :local, "File exceeds the server transfer limit", context}

      :eof ->
        {:ok, hash |> :crypto.hash_final() |> Base.encode16(case: :lower), size}

      {:error, reason} ->
        local({:error, reason}, context)
    end
  end

  defp request(client, method, path, body, context) do
    case contextual(Client.request(client, method, path, body), context) do
      {:ok, _status, %{"data" => data} = response} when is_map(data) ->
        {:ok, response}

      {:ok, _status, _response} ->
        {:error, :protocol, "Server returned invalid file metadata", context}

      error ->
        error
    end
  end

  defp decode(encoded, context) do
    case Jason.decode(encoded) do
      {:ok, %{"data" => data} = response} when is_map(data) -> {:ok, response}
      _ -> {:error, :protocol, "Server returned invalid file metadata", context}
    end
  end

  defp contextual({:error, :http, status, body}, context),
    do: {:error, :http, status, body, context}

  defp contextual({:error, :transport, message}, context),
    do: {:error, :transport, message, context}

  defp contextual(result, _context), do: result

  defp required(value, _label, _context) when is_binary(value) and byte_size(value) > 0,
    do: {:ok, value}

  defp required(_value, label, context),
    do: {:error, :local, "This command requires #{label}", context}

  defp check(true, _message, _context), do: :ok
  defp check(false, message, context), do: {:error, :local, message, context}

  defp local({:ok, value}, _context), do: {:ok, value}
  defp local(:ok, _context), do: :ok

  defp local({:error, reason}, context),
    do: {:error, :local, "Cannot access local file: #{:file.format_error(reason)}", context}

  defp local(:eof, context), do: {:error, :local, "Input ended during upload", context}
end
