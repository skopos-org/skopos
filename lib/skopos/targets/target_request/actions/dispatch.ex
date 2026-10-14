defmodule Skopos.Targets.TargetRequest.Actions.Dispatch do
  use Ash.Resource.Actions.Implementation

  alias Skopos.{Accounts, Providers, Targets}
  alias Skopos.Providers.Target, as: ProviderTarget
  alias Skopos.Targets.TargetRequest.{RequestError, Request, Clearance}

  @authority_modes [:readonly, :ask, :auto, :full_access]
  @request_kinds [:observation, :effect, :verification]
  @max_payload_items 100
  @max_payload_bytes ProviderTarget.max_payload_bytes()

  @impl true
  def run(input, opts, context) do
    case opts[:operation] do
      :clear -> clear(context.actor, input.arguments.request)
      operation -> dispatch(operation, context.actor, input.arguments)
    end
  end

  defp clear(actor, %Request{} = request) do
    with {:ok, current_actor} <- current_actor(actor),
         :ok <- validate_request(request),
         {:ok, context} <- resolve(request),
         :ok <- admit_files(request, current_actor),
         :ok <- classify(request, context) do
      {:ok, build_clearance(current_actor, request, context)}
    end
  end

  defp dispatch(operation, actor, %{clearance: %Clearance{} = clearance} = arguments) do
    with :ok <- expected_dispatch(operation, clearance.kind),
         :ok <- valid_digest(clearance),
         {:ok, current_actor} <- current_actor(actor),
         :ok <- same_actor(current_actor, clearance),
         request <- request_from_clearance(clearance),
         :ok <- validate_request(request),
         {:ok, context} <- resolve(request),
         :ok <- admit_files(request, current_actor),
         :ok <- classify(request, context),
         :ok <- validate_authority(request),
         :ok <- current_provider(context.access_method, clearance) do
      invocation = bind_file_ports(arguments.invocation, current_actor, clearance)
      invoke(operation, current_actor, context.access_method, clearance, invocation)
    end
  end

  defp dispatch(_operation, _actor, _arguments),
    do: {:error, request_error(:invalid_clearance, "Target request clearance is invalid")}

  defp resolve(request) do
    with {:ok, target} <- Targets.get_target(request.target_id, authorize?: false),
         :ok <- current(target.revision, request.target_revision),
         :ok <- active(target.active, :inactive_target),
         {:ok, access_method} <-
           Targets.load_access_method_for_use(
             request.access_method_id,
             request.access_method_revision,
             request.capability,
             authorize?: false
           ),
         :ok <- same_target(access_method, target) do
      {:ok,
       %{
         target: target,
         access_method: access_method
       }}
    else
      {:error, %RequestError{} = error} ->
        {:error, error}

      {:error, error} = failure ->
        if RequestError.expected?(error),
          do: {:error, request_error(:stale_context, "Target request context is unavailable")},
          else: failure
    end
  end

  defp classify(request, %{access_method: method}) do
    {:ok, parameters, files} = ProviderTarget.FileReference.split(request.parameters)

    input = %ProviderTarget.MethodRequest{
      provider_revision: method.provider_revision,
      connection: %ProviderTarget.Connection{endpoint: method.endpoint},
      capability: request.capability,
      operation: request.operation,
      selectors: request.selectors,
      parameters: parameters,
      files: files
    }

    expected = if request.kind == :effect, do: :effect, else: :observation

    case Providers.target_classify(method.provider_id, input, %{}, authorize?: false) do
      {:ok, %ProviderTarget.RequestClassification{kind: ^expected}} ->
        :ok

      {:ok, %ProviderTarget.RequestClassification{}} ->
        {:error,
         request_error(:denied, "Target request kind does not match Method classification")}

      {:error, error} = failure ->
        if RequestError.expected?(error) or
             match?(%ProviderTarget.Error{category: :failed}, ProviderTarget.Error.unwrap(error)),
           do:
             {:error, request_error(:denied, "Target Method request is invalid or unsupported")},
           else: failure
    end
  end

  defp build_clearance(actor, request, context) do
    attributes = %{
      actor_id: actor.id,
      kind: request.kind,
      authority_mode: request.authority_mode,
      target_id: context.target.id,
      target_revision: context.target.revision,
      access_method_id: context.access_method.id,
      access_method_revision: context.access_method.revision,
      provider_id: context.access_method.provider_id,
      provider_revision: context.access_method.provider_revision,
      capability: request.capability,
      operation: request.operation,
      selectors: request.selectors,
      parameters: request.parameters,
      operation_id: request.operation_id,
      idempotency_key: request.idempotency_key,
      reference: request.reference,
      expected: request.expected,
      max_attempts: request.max_attempts
    }

    struct!(Clearance, Map.put(attributes, :digest, digest(attributes)))
  end

  defp request_from_clearance(clearance) do
    struct!(Request,
      kind: clearance.kind,
      authority_mode: clearance.authority_mode,
      target_id: clearance.target_id,
      target_revision: clearance.target_revision,
      access_method_id: clearance.access_method_id,
      access_method_revision: clearance.access_method_revision,
      capability: clearance.capability,
      operation: clearance.operation,
      selectors: clearance.selectors,
      parameters: clearance.parameters,
      operation_id: clearance.operation_id,
      idempotency_key: clearance.idempotency_key,
      reference: clearance.reference,
      expected: clearance.expected,
      max_attempts: clearance.max_attempts
    )
  end

  defp invoke(:observe, actor, method, clearance, invocation) do
    {:ok, parameters, files} = ProviderTarget.FileReference.split(clearance.parameters)

    request = %ProviderTarget.ObservationRequest{
      provider_revision: clearance.provider_revision,
      target_id: clearance.target_id,
      target_revision: clearance.target_revision,
      access_method_id: clearance.access_method_id,
      access_method_revision: clearance.access_method_revision,
      connection: %ProviderTarget.Connection{endpoint: method.endpoint},
      capability: clearance.capability,
      operation: clearance.operation,
      authorization_digest: clearance.digest,
      authority_mode: clearance.authority_mode,
      selectors: clearance.selectors,
      parameters: parameters,
      files: files,
      max_attempts: clearance.max_attempts
    }

    Providers.target_observe(method.provider_id, request, invocation,
      actor: actor,
      authorize?: false
    )
  end

  defp invoke(:effect, actor, method, clearance, invocation) do
    {:ok, parameters, files} = ProviderTarget.FileReference.split(clearance.parameters)

    request = %ProviderTarget.EffectRequest{
      provider_revision: clearance.provider_revision,
      target_id: clearance.target_id,
      target_revision: clearance.target_revision,
      access_method_id: clearance.access_method_id,
      access_method_revision: clearance.access_method_revision,
      connection: %ProviderTarget.Connection{endpoint: method.endpoint},
      capability: clearance.capability,
      operation: clearance.operation,
      authorization_digest: clearance.digest,
      authority_mode: clearance.authority_mode,
      selectors: clearance.selectors,
      parameters: parameters,
      files: files,
      operation_id: clearance.operation_id,
      idempotency_key: clearance.idempotency_key
    }

    Providers.target_effect(method.provider_id, request, invocation,
      actor: actor,
      authorize?: false
    )
  end

  defp invoke(:verify, actor, method, clearance, invocation) do
    {:ok, parameters, files} = ProviderTarget.FileReference.split(clearance.parameters)

    request = %ProviderTarget.VerificationRequest{
      provider_revision: clearance.provider_revision,
      target_id: clearance.target_id,
      target_revision: clearance.target_revision,
      access_method_id: clearance.access_method_id,
      access_method_revision: clearance.access_method_revision,
      connection: %ProviderTarget.Connection{endpoint: method.endpoint},
      capability: clearance.capability,
      operation: clearance.operation,
      authorization_digest: clearance.digest,
      selectors: clearance.selectors,
      parameters: parameters,
      files: files,
      operation_id: clearance.operation_id,
      reference: clearance.reference,
      expected: clearance.expected
    }

    Providers.target_verify(method.provider_id, request, invocation,
      actor: actor,
      authorize?: false
    )
  end

  defp admit_files(request, actor) do
    with {:ok, _parameters, files} <- ProviderTarget.FileReference.split(request.parameters) do
      Enum.reduce_while(files, :ok, fn {_label, reference}, :ok ->
        with true <- reference["target_id"] == request.target_id,
             {:ok, ^reference} <-
               Targets.artifact_reference(reference["id"], request.target_id, actor: actor) do
          {:cont, :ok}
        else
          _ -> {:halt, unavailable_file()}
        end
      end)
    else
      _ -> unavailable_file()
    end
  end

  defp bind_file_ports(invocation, actor, clearance) do
    {:ok, _parameters, files} = ProviderTarget.FileReference.split(clearance.parameters)

    invocation
    |> Map.put(:file_reader, fn label, offset ->
      file_action(actor, invocation, fn current_actor ->
        with {:ok, reference} <- Map.fetch(files, label),
             do: Targets.read_bound_artifact_chunk(reference, offset, actor: current_actor)
      end)
    end)
    |> Map.put(:file_writer, fn response_key, name, media_type ->
      begin_file_writer(actor, invocation, clearance, response_key, name, media_type)
    end)
  end

  defp begin_file_writer(actor, invocation, clearance, response_key, name, media_type) do
    if bounded_string?(response_key, 120) and String.valid?(response_key) do
      receipt_key =
        digest(%{
          clearance: clearance.digest,
          response_key: response_key
        })
        |> Base.encode16(case: :lower)

      with {:ok, artifact} <-
             file_action(
               actor,
               invocation,
               fn current_actor ->
                 Targets.begin_artifact_receipt(
                   clearance.target_id,
                   name,
                   media_type,
                   receipt_key,
                   %{request_id: clearance.operation_id},
                   actor: current_actor
                 )
               end,
               :file_transfer_failed
             ),
           {:ok, limits} <- Targets.artifact_limits(actor: actor) do
        {:ok,
         %ProviderTarget.FileWriter{
           id: artifact.id,
           status: artifact.status,
           offset: artifact.received_bytes,
           chunk_bytes: limits.chunk_bytes,
           append: fn offset, bytes ->
             with {:ok, current} <-
                    file_action(
                      actor,
                      invocation,
                      fn current_actor ->
                        Targets.append_artifact_chunk(artifact.id, offset, bytes,
                          actor: current_actor
                        )
                      end,
                      :file_transfer_failed
                    ),
                  do: {:ok, current.received_bytes}
           end,
           complete: fn expected_size, expected_hash, completion_reason ->
             with {:ok, current} <-
                    file_action(
                      actor,
                      invocation,
                      fn current_actor ->
                        Targets.complete_artifact_receipt(
                          artifact.id,
                          %{
                            expected_size_bytes: expected_size,
                            expected_sha256: expected_hash,
                            completion_reason: completion_reason
                          },
                          actor: current_actor
                        )
                      end,
                      :file_transfer_failed
                    ),
                  do: {:ok, ProviderTarget.FileReference.from_metadata(current)}
           end,
           read: fn offset ->
             file_action(
               actor,
               invocation,
               fn current_actor ->
                 Targets.read_artifact_chunk(artifact.id, clearance.target_id, offset,
                   actor: current_actor
                 )
               end,
               :invalid_file
             )
           end,
           abort: fn ->
             with {:ok, current} <-
                    file_action(
                      actor,
                      invocation,
                      fn current_actor ->
                        Targets.revoke_artifact(artifact.id, actor: current_actor)
                      end,
                      :file_transfer_failed,
                      true
                    ),
                  do: {:ok, current.status}
           end
         }}
      end
    else
      file_failure(:file_transfer_failed)
    end
  end

  defp file_action(
         actor,
         invocation,
         callback,
         failure \\ :invalid_file,
         allow_cancelled? \\ false
       ) do
    with false <- not allow_cancelled? and cancelled?(invocation),
         {:ok, current_actor} <- current_actor(actor),
         {:ok, result} <- callback.(current_actor) do
      {:ok, result}
    else
      true ->
        {:error, request_error(:cancelled, "Target invocation was cancelled")}

      {:error, %RequestError{} = error} ->
        {:error, error}

      {:error, cause} ->
        if RequestError.expected?(cause),
          do: file_failure(failure),
          else: {:error, ProviderTarget.Error.context_failure(cause)}

      _ ->
        file_failure(failure)
    end
  rescue
    cause -> {:error, ProviderTarget.Error.context_failure(cause)}
  catch
    kind, reason ->
      {:error,
       ProviderTarget.Error.context_failure(ErlangError.exception(original: {kind, reason}))}
  end

  defp file_failure(:invalid_file), do: unavailable_file()

  defp file_failure(:file_transfer_failed),
    do: {:error, request_error(:file_transfer_failed, "Target file transfer could not be saved")}

  defp cancelled?(%{cancelled?: callback}) when is_function(callback, 0), do: callback.()
  defp cancelled?(_invocation), do: false

  defp unavailable_file,
    do: {:error, request_error(:invalid_file, "Target file reference is invalid or unavailable")}

  defp validate_request(%Request{} = request) do
    cond do
      request.kind not in @request_kinds ->
        invalid_request()

      request.authority_mode not in @authority_modes ->
        invalid_request()

      not nonempty_binary?(request.target_id) ->
        invalid_request()

      not positive_integer?(request.target_revision) ->
        invalid_request()

      not nonempty_binary?(request.access_method_id) ->
        invalid_request()

      not positive_integer?(request.access_method_revision) ->
        invalid_request()

      not bounded_string?(request.capability, 120) ->
        invalid_request()

      not bounded_string?(request.operation, 120) ->
        invalid_request()

      not bounded_map?(request.selectors) ->
        invalid_request()

      not bounded_map?(request.parameters) ->
        invalid_request()

      not bounded_map?(request.expected) ->
        invalid_request()

      not is_integer(request.max_attempts) or request.max_attempts not in 1..5 ->
        invalid_request()

      request.kind == :effect and not nonempty_binary?(request.operation_id) ->
        invalid_request()

      request.kind == :effect and not nonempty_binary?(request.idempotency_key) ->
        invalid_request()

      request.kind == :verification and not nonempty_binary?(request.operation_id) ->
        invalid_request()

      not ProviderTarget.valid_result_reference?(request.reference) ->
        invalid_request()

      true ->
        :ok
    end
  end

  defp validate_authority(%Request{kind: :effect, authority_mode: :readonly}),
    do: {:error, request_error(:forbidden, "Readonly authority cannot execute Target effects")}

  defp validate_authority(%Request{}), do: :ok

  defp current_actor(%{id: actor_id}) do
    case Accounts.get_user(actor_id, authorize?: false) do
      {:ok, %{role: role} = actor} when role in [:admin, :operator] ->
        {:ok, actor}

      {:ok, _other} ->
        {:error, request_error(:forbidden, "Actor is not authorized for Target requests")}

      {:error, _error} = error ->
        error
    end
  end

  defp current_actor(_actor),
    do: {:error, request_error(:forbidden, "Actor is not authorized for Target requests")}

  defp same_actor(%{id: id}, %{actor_id: id}), do: :ok

  defp same_actor(_actor, _clearance),
    do: {:error, request_error(:clearance_mismatch, "Target request clearance actor changed")}

  defp same_target(%{target_id: id}, %{id: id}), do: :ok

  defp same_target(_method, _target),
    do: {:error, request_error(:out_of_scope, "Access Method belongs to another Target")}

  defp current_provider(method, clearance) do
    if method.provider_id == clearance.provider_id and
         method.provider_revision == clearance.provider_revision do
      :ok
    else
      {:error, request_error(:stale_context, "Target Provider changed")}
    end
  end

  defp expected_dispatch(:observe, :observation), do: :ok
  defp expected_dispatch(:effect, :effect), do: :ok
  defp expected_dispatch(:verify, :verification), do: :ok

  defp expected_dispatch(_operation, _kind),
    do:
      {:error,
       request_error(:invalid_clearance, "Target request clearance kind does not match dispatch")}

  defp valid_digest(%Clearance{} = clearance) do
    attributes = clearance |> Map.from_struct() |> Map.delete(:digest)
    expected = digest(attributes)

    if is_binary(clearance.digest) and byte_size(clearance.digest) == byte_size(expected) and
         :crypto.hash_equals(clearance.digest, expected) do
      :ok
    else
      {:error, request_error(:clearance_mismatch, "Target request clearance was modified")}
    end
  end

  defp digest(attributes) do
    key = Application.fetch_env!(:skopos, :token_signing_secret)
    payload = :erlang.term_to_binary(attributes, [:deterministic])
    :crypto.mac(:hmac, :sha256, key, "skopos-target-clearance-v1\0" <> payload)
  end

  defp current(value, value), do: :ok

  defp current(_actual, _expected),
    do: {:error, request_error(:stale_context, "Target revision changed")}

  defp active(true, _category), do: :ok
  defp active(false, category), do: {:error, request_error(category, "Target is inactive")}

  defp bounded_map?(map) when is_map(map) and map_size(map) <= @max_payload_items do
    case Jason.encode(map) do
      {:ok, encoded} -> byte_size(encoded) <= @max_payload_bytes
      {:error, _error} -> false
    end
  end

  defp bounded_map?(_map), do: false
  defp bounded_string?(value, max) when is_binary(value), do: byte_size(value) in 1..max
  defp bounded_string?(_value, _max), do: false
  defp positive_integer?(value), do: is_integer(value) and value > 0
  defp nonempty_binary?(value), do: is_binary(value) and byte_size(value) > 0

  defp invalid_request(),
    do: {:error, request_error(:invalid_request, "Target request is invalid")}

  defp request_error(category, message) do
    RequestError.exception(category: category, message: message)
  end
end
