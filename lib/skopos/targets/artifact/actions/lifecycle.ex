defmodule Skopos.Targets.Artifact.Actions.Lifecycle do
  use Ash.Resource.Actions.Implementation

  require Ash.Query

  alias Skopos.Targets
  alias Skopos.Targets.{Artifact, ArtifactChunk, Target}
  alias Skopos.Providers.Target.FileReference

  @impl true
  def run(input, opts, context) do
    case opts[:operation] do
      :limits ->
        {:ok, limits()}

      :begin ->
        begin_upload(input.arguments, context.actor)

      :begin_receipt ->
        begin_receipt(input.arguments, context.actor)

      :append ->
        locked(input.arguments.id, context.actor, &append(&1, input.arguments))

      :complete ->
        locked(input.arguments.id, context.actor, &complete/1)

      :complete_receipt ->
        locked(input.arguments.id, context.actor, &complete_receipt(&1, input.arguments))

      :revoke ->
        locked(input.arguments.id, context.actor, &dispose(&1, :revoked), usable?: false)

      :expire ->
        locked(input.arguments.id, nil, &expire/1, usable?: false, authorize?: false)

      :chunk ->
        read_chunk(input.arguments, context.actor)

      :reference ->
        reference(input.arguments, context.actor)

      :bound_chunk ->
        bound_chunk(input.arguments, context.actor)

      :bound_range ->
        bound_range(input.arguments, context.actor)
    end
  end

  defp begin_upload(arguments, actor) do
    Ash.transact([Target, Artifact], fn -> create_or_resume(arguments, actor, :uploading) end)
  end

  defp begin_receipt(arguments, actor) do
    attributes =
      arguments
      |> Map.delete(:receipt_key)
      |> Map.merge(%{upload_key: arguments.receipt_key, size_bytes: nil, expected_sha256: nil})

    Ash.transact([Target, Artifact], fn -> create_or_resume(attributes, actor, :receiving) end)
  end

  defp create_or_resume(arguments, actor, status) do
    with true <-
           (is_nil(arguments.size_bytes) or arguments.size_bytes <= limits().max_size_bytes) ||
             invalid(:size_bytes, "Artifact exceeds the configured transfer limit"),
         {:ok, %{active: true}} <-
           Target
           |> Ash.Query.for_read(:read, %{}, actor: actor)
           |> Ash.Query.filter(id == ^arguments.target_id)
           |> Ash.Query.lock(:for_update)
           |> Ash.read_one(not_found_error?: true),
         {:ok, existing} <-
           Targets.artifact_by_upload(arguments.target_id, actor.id, arguments.upload_key,
             authorize?: false,
             not_found_error?: false
           ) do
      if existing do
        fields =
          if status == :receiving,
            do: [:name, :media_type, :expected_sha256, :request_id],
            else: [:name, :media_type, :size_bytes, :expected_sha256]

        if Enum.all?(
             fields,
             &(Map.get(existing, &1) == Map.get(arguments, &1))
           ),
           do: existing,
           else: invalid(:upload_key, "This upload key already identifies different content")
      else
        attributes =
          arguments
          |> Map.take([
            :target_id,
            :name,
            :media_type,
            :size_bytes,
            :expected_sha256,
            :request_id,
            :upload_key
          ])
          |> Map.merge(%{
            status: status,
            uploaded_by_id: actor.id,
            expires_at: DateTime.add(DateTime.utc_now(), limits().lifetime_seconds, :second)
          })

        with {:ok, artifact} <- Targets.create_artifact_record(attributes, authorize?: false),
             {:ok, _job} <- schedule_expiry(artifact) do
          artifact
        end
      end
    else
      {:error, _} = error -> error
      _ -> invalid(:target_id, "Artifact Target is unavailable")
    end
  end

  defp schedule_expiry(artifact) do
    %{id: artifact.id}
    |> Artifact.ExpiryWorker.new(scheduled_at: artifact.expires_at)
    |> Oban.insert()
  rescue
    _error in [Postgrex.Error, DBConnection.ConnectionError] ->
      {:error,
       Ash.Error.Unknown.UnknownError.exception(error: "Artifact cleanup could not be saved")}
  end

  defp locked(id, actor, operation, opts \\ []) do
    Ash.transact([Artifact, ArtifactChunk], fn ->
      with {:ok, artifact} <-
             Artifact
             |> Ash.Query.for_read(:read, %{},
               actor: actor,
               authorize?: Keyword.get(opts, :authorize?, true)
             )
             |> Ash.Query.filter(id == ^id)
             |> Ash.Query.lock(:for_update)
             |> Ash.read_one(not_found_error?: true),
           :ok <- if(Keyword.get(opts, :usable?, true), do: unexpired(artifact), else: :ok) do
        operation.(artifact)
      end
    end)
  end

  defp append(artifact, %{offset: offset, bytes: bytes}) do
    size = byte_size(bytes)

    cond do
      artifact.status in [:revoked, :expired] ->
        invalid(:id, "Artifact is unavailable")

      size == 0 or size > limits().chunk_bytes ->
        invalid(:bytes, "Chunk exceeds the configured transfer limit")

      offset < artifact.received_bytes ->
        duplicate_chunk(artifact, offset, bytes)

      artifact.status not in [:uploading, :receiving] ->
        invalid(:id, "Artifact is already complete")

      offset != artifact.received_bytes ->
        invalid(:offset, "Chunk must continue the current upload offset")

      offset + size > min(artifact.size_bytes || limits().max_size_bytes, limits().max_size_bytes) ->
        invalid(:bytes, "Chunk exceeds the file transfer limit")

      true ->
        with {:ok, _chunk} <-
               Targets.create_artifact_chunk_record(
                 %{
                   artifact_id: artifact.id,
                   offset: offset,
                   size_bytes: size,
                   sha256: digest(bytes),
                   bytes: bytes
                 },
                 authorize?: false
               ),
             {:ok, updated} <-
               Targets.record_artifact_state(artifact, %{received_bytes: offset + size},
                 authorize?: false
               ) do
          updated
        end
    end
  end

  defp duplicate_chunk(artifact, offset, bytes) do
    with {:ok, chunk} <- Targets.artifact_chunk_at_offset(artifact.id, offset, authorize?: false),
         true <- chunk.size_bytes == byte_size(bytes) and chunk.sha256 == digest(bytes) do
      artifact
    else
      _ -> invalid(:offset, "A different chunk already occupies this offset")
    end
  end

  defp complete(%{expected_sha256: nil}),
    do: invalid(:id, "Incoming files require receipt completion")

  defp complete(%{status: :ready} = artifact), do: artifact

  defp complete(%{status: status}) when status in [:revoked, :expired],
    do: invalid(:id, "Artifact is unavailable")

  defp complete(artifact) do
    with true <-
           artifact.received_bytes == artifact.size_bytes ||
             invalid(:id, "Artifact upload is incomplete"),
         {:ok, hash} <- hash_chunks(artifact, 0, :crypto.hash_init(:sha256)),
         true <-
           hash == artifact.expected_sha256 ||
             invalid(:expected_sha256, "Artifact integrity check failed"),
         {:ok, completed} <-
           Targets.record_artifact_state(
             artifact,
             %{status: :ready, sha256: hash, completion_reason: :upload},
             authorize?: false
           ) do
      completed
    end
  end

  defp complete_receipt(%{expected_sha256: hash}, _arguments) when not is_nil(hash),
    do: invalid(:id, "Uploaded files require declared-content completion")

  defp complete_receipt(%{status: status} = artifact, arguments)
       when status in [:receiving, :ready] do
    expected_size = Map.get(arguments, :expected_size_bytes)
    expected_hash = Map.get(arguments, :expected_sha256)
    reason = arguments.completion_reason

    with true <-
           (status != :ready or artifact.completion_reason == reason) ||
             invalid(:completion_reason, "Incoming file completion reason cannot be changed"),
         true <-
           (is_nil(expected_size) or
              expected_size == artifact.received_bytes) ||
             invalid(:expected_size_bytes, "Incoming file length does not match the response"),
         {:ok, hash} <- hash_chunks(artifact, 0, :crypto.hash_init(:sha256)),
         true <-
           (is_nil(expected_hash) or expected_hash == hash) ||
             invalid(:expected_sha256, "Incoming file integrity check failed") do
      if status == :ready do
        artifact
      else
        with {:ok, completed} <-
               Targets.record_artifact_state(
                 artifact,
                 %{
                   status: :ready,
                   size_bytes: artifact.received_bytes,
                   sha256: hash,
                   completion_reason: reason
                 },
                 authorize?: false
               ),
             do: completed
      end
    end
  end

  defp complete_receipt(_artifact, _arguments), do: invalid(:id, "Incoming file is unavailable")

  defp hash_chunks(artifact, offset, hash) when offset == artifact.received_bytes,
    do: {:ok, hash |> :crypto.hash_final() |> Base.encode16(case: :lower)}

  defp hash_chunks(artifact, offset, hash) do
    with {:ok, chunk} <-
           Targets.artifact_chunk_at_offset(artifact.id, offset,
             authorize?: false,
             load: [:bytes]
           ),
         :ok <- chunk_integrity(chunk) do
      hash_chunks(artifact, offset + chunk.size_bytes, :crypto.hash_update(hash, chunk.bytes))
    end
  end

  defp read_chunk(arguments, actor) do
    with {:ok, artifact} <- Targets.get_artifact(arguments.id, actor: actor),
         :ok <- ready_for_target(artifact, arguments.target_id) do
      read_verified_chunk(artifact, arguments.offset)
    end
  end

  defp reference(arguments, actor) do
    with {:ok, artifact} <- Targets.get_artifact(arguments.id, actor: actor),
         :ok <- ready_for_target(artifact, arguments.target_id) do
      {:ok, FileReference.from_metadata(artifact)}
    end
  end

  defp bound_chunk(%{reference: reference, offset: offset}, actor) do
    bound_reference(reference, actor, fn artifact ->
      with {:ok, bytes} <- read_verified_chunk(artifact, offset), do: bytes
    end)
  end

  defp bound_range(%{reference: reference, offset: offset, length: length}, actor) do
    with true <-
           length <= limits().chunk_bytes ||
             invalid(:length, "File range exceeds the configured read limit") do
      bound_reference(reference, actor, fn artifact ->
        with true <-
               offset <= artifact.size_bytes || invalid(:offset, "File range starts beyond EOF"),
             {:ok, bytes} <-
               range(artifact, offset, min(length, artifact.size_bytes - offset), []),
             do: bytes
      end)
    end
  end

  defp bound_reference(reference, actor, read) do
    if FileReference.valid?(reference) do
      locked(reference["id"], actor, fn artifact ->
        with :ok <- ready_for_target(artifact, reference["target_id"]),
             true <-
               FileReference.from_metadata(artifact) == reference ||
                 invalid(:reference, "File reference does not match the stored content") do
          read.(artifact)
        end
      end)
    else
      invalid(:reference, "File reference is invalid")
    end
  end

  defp range(_artifact, _offset, 0, reversed),
    do: {:ok, reversed |> Enum.reverse() |> IO.iodata_to_binary()}

  defp range(artifact, offset, length, reversed) do
    with {:ok, chunk} <-
           Targets.artifact_chunk_containing_offset(artifact.id, offset,
             authorize?: false,
             load: [:bytes]
           ),
         :ok <- chunk_integrity(chunk) do
      start = offset - chunk.offset
      count = min(length, chunk.size_bytes - start)

      range(artifact, offset + count, length - count, [
        binary_part(chunk.bytes, start, count) | reversed
      ])
    end
  end

  defp ready_for_target(artifact, target_id) do
    with true <-
           artifact.target_id == target_id ||
             invalid(:target_id, "Artifact does not belong to this Target"),
         true <- artifact.status == :ready || invalid(:id, "Artifact is not ready"),
         :ok <- unexpired(artifact),
         do: :ok
  end

  defp read_verified_chunk(%{size_bytes: 0}, 0), do: {:ok, <<>>}

  defp read_verified_chunk(artifact, offset) do
    with {:ok, chunk} <-
           Targets.artifact_chunk_at_offset(artifact.id, offset,
             authorize?: false,
             load: [:bytes]
           ),
         :ok <- chunk_integrity(chunk) do
      {:ok, chunk.bytes}
    end
  end

  defp expire(%{status: status} = artifact) when status in [:expired, :revoked], do: artifact

  defp expire(artifact) do
    if DateTime.compare(artifact.expires_at, DateTime.utc_now()) == :gt,
      do: artifact,
      else: dispose(artifact, :expired)
  end

  defp dispose(%{status: status} = artifact, status), do: artifact
  defp dispose(%{status: :expired} = artifact, :revoked), do: artifact

  defp dispose(artifact, status) do
    result =
      ArtifactChunk
      |> Ash.Query.filter(artifact_id == ^artifact.id)
      |> Ash.bulk_destroy(:destroy, %{}, authorize?: false, return_errors?: true)

    case result do
      %Ash.BulkResult{status: :success} ->
        with {:ok, revoked} <-
               Targets.record_artifact_state(artifact, %{status: status}, authorize?: false),
             do: revoked

      %Ash.BulkResult{errors: errors} ->
        {:error, errors}
    end
  end

  defp chunk_integrity(chunk) do
    if byte_size(chunk.bytes) == chunk.size_bytes and digest(chunk.bytes) == chunk.sha256,
      do: :ok,
      else: invalid(:id, "Stored artifact integrity check failed")
  end

  defp unexpired(artifact) do
    if DateTime.compare(artifact.expires_at, DateTime.utc_now()) == :gt,
      do: :ok,
      else: invalid(:id, "Artifact has expired")
  end

  defp digest(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)

  defp limits do
    %{chunk_bytes: 262_144, max_size_bytes: 536_870_912, lifetime_seconds: 86_400}
    |> Map.merge(Application.get_env(:skopos, :artifact_limits, %{}))
  end

  defp invalid(field, message),
    do: {:error, Ash.Error.Changes.InvalidAttribute.exception(field: field, message: message)}
end
