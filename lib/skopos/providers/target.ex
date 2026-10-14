defmodule Skopos.Providers.Target do
  @moduledoc false

  # Pure protocol-port limits shared by admission and canonical receipt storage.
  # Fixed observation/verification framing fits within the unchanged JSON
  # scaffolding's headroom in the redaction expansion bound.
  def max_payload_bytes, do: 65_536
  def max_result_bytes, do: Skopos.Providers.Redactor.max_encoded_bytes(max_payload_bytes())

  # Opaque references are UTF-8 text, with bytes and whitespace preserved.
  def valid_result_reference?(value, maximum \\ max_result_bytes())
  def valid_result_reference?(nil, _maximum), do: true

  def valid_result_reference?(value, maximum) do
    is_binary(value) and byte_size(value) in 1..maximum and String.valid?(value) and
      not String.contains?(value, <<0>>)
  end

  defmodule EvidenceRequirement do
    @moduledoc false
    @enforce_keys [:parameter, :fact, :observation]
    defstruct @enforce_keys

    @type t :: %__MODULE__{
            parameter: String.t(),
            fact: String.t(),
            observation: String.t()
          }
  end

  defmodule Operation do
    @moduledoc false
    @enforce_keys [:capability, :operation, :description, :input_schema]
    defstruct @enforce_keys ++
                [
                  output_schema: nil,
                  verification_schema: nil,
                  evidence_requirements: []
                ]

    @type t :: %__MODULE__{
            capability: String.t(),
            operation: String.t(),
            description: String.t(),
            input_schema: map(),
            output_schema: map() | nil,
            verification_schema: map() | nil,
            evidence_requirements: [EvidenceRequirement.t()]
          }
  end

  defmodule Capabilities do
    @moduledoc false
    @enforce_keys [:observations, :effects]
    defstruct [:observations, :effects]
    @type t :: %__MODULE__{observations: [Operation.t()], effects: [Operation.t()]}

    # The same typed value crosses the role port and the Method persistence seam.
    def constraints do
      operation = [
        instance_of: Operation,
        fields: [
          capability: [type: :string, allow_nil?: false],
          operation: [type: :string, allow_nil?: false],
          description: [type: :string, allow_nil?: false],
          input_schema: [type: :map, allow_nil?: false],
          output_schema: [type: :map],
          verification_schema: [type: :map],
          evidence_requirements: [
            type: {:array, :struct},
            allow_nil?: false,
            constraints: [
              items: [
                instance_of: EvidenceRequirement,
                fields: [
                  parameter: [type: :string, allow_nil?: false],
                  fact: [type: :string, allow_nil?: false],
                  observation: [type: :string, allow_nil?: false]
                ]
              ]
            ]
          ]
        ]
      ]

      [
        instance_of: __MODULE__,
        fields: [
          observations: [
            type: {:array, :struct},
            allow_nil?: false,
            constraints: [items: operation]
          ],
          effects: [type: {:array, :struct}, allow_nil?: false, constraints: [items: operation]]
        ]
      ]
    end
  end

  defmodule Connection do
    @moduledoc false
    @enforce_keys [:endpoint]
    defstruct @enforce_keys
    @type t :: %__MODULE__{endpoint: String.t()}
  end

  defmodule FileReference do
    @moduledoc false
    @fields ~w(id target_id name media_type size_bytes sha256)a
    @keys Enum.map(@fields, &Atom.to_string/1)

    # Pure wire value shared by storage and protocol ports; it performs no I/O.
    def from_metadata(metadata),
      do: Map.new(@fields, &{Atom.to_string(&1), Map.fetch!(metadata, &1)})

    def valid?(reference) when is_map(reference) do
      Enum.sort(Map.keys(reference)) == Enum.sort(@keys) and
        valid_id?(reference["id"]) and valid_id?(reference["target_id"]) and
        valid_metadata?(reference["name"], reference["media_type"]) and
        is_integer(reference["size_bytes"]) and reference["size_bytes"] >= 0 and
        is_binary(reference["sha256"]) and
        Regex.match?(~r/\A[0-9a-f]{64}\z/, reference["sha256"])
    end

    def valid?(_reference), do: false

    def present_in?(value, reference),
      do: valid?(reference) and contains_reference?(value, reference)

    def references_in(value) when is_map(value) do
      if valid?(value), do: [value], else: Enum.flat_map(Map.values(value), &references_in/1)
    end

    def references_in(value) when is_list(value), do: Enum.flat_map(value, &references_in/1)
    def references_in(_value), do: []

    defp contains_reference?(value, reference) when value == reference, do: true

    defp contains_reference?(value, reference) when is_map(value),
      do: Enum.any?(value, fn {_key, nested} -> contains_reference?(nested, reference) end)

    defp contains_reference?(value, reference) when is_list(value),
      do: Enum.any?(value, &contains_reference?(&1, reference))

    defp contains_reference?(_value, _reference), do: false

    def valid_metadata?(name, media_type),
      do:
        bounded_text?(name, 255) and bounded_text?(media_type, 256) and
          not String.contains?(media_type, ["\r", "\n"])

    def valid_set?(files) when is_map(files) and map_size(files) <= 100 do
      Enum.all?(files, fn {label, reference} ->
        is_binary(label) and Regex.match?(~r/\A[A-Za-z0-9][A-Za-z0-9_.-]{0,119}\z/, label) and
          valid?(reference)
      end)
    end

    def valid_set?(_files), do: false

    def schema do
      %{
        "type" => "object",
        "properties" => %{
          "id" => %{"type" => "string", "format" => "uuid"},
          "target_id" => %{"type" => "string", "format" => "uuid"},
          "name" => %{"type" => "string", "minLength" => 1, "maxLength" => 255},
          "media_type" => %{"type" => "string", "minLength" => 1, "maxLength" => 256},
          "size_bytes" => %{"type" => "integer", "minimum" => 0},
          "sha256" => %{"type" => "string", "pattern" => "^[0-9a-f]{64}$"}
        },
        "required" => @keys,
        "additionalProperties" => false
      }
    end

    def set_schema do
      %{
        "type" => "object",
        "maxProperties" => 100,
        "propertyNames" => %{"pattern" => "^[A-Za-z0-9][A-Za-z0-9_.-]{0,119}$"},
        "additionalProperties" => schema()
      }
    end

    def split(parameters) do
      {files, parameters} = Map.pop(parameters, "files", %{})
      if valid_set?(files), do: {:ok, parameters, files}, else: {:error, :invalid_files}
    end

    defp valid_id?(id), do: is_binary(id) and match?({:ok, ^id}, Ecto.UUID.cast(id))

    defp bounded_text?(value, maximum),
      do:
        is_binary(value) and String.valid?(value) and
          length(String.codepoints(value)) in 1..maximum
  end

  defmodule FileWriter do
    @moduledoc false
    @enforce_keys [:id, :status, :offset, :chunk_bytes, :append, :complete, :read, :abort]
    defstruct @enforce_keys

    def append(writer, offset, bytes, checkpoint \\ fn -> :ok end)

    def append(%__MODULE__{}, offset, <<>>, _checkpoint) when is_integer(offset) and offset >= 0,
      do: {:ok, offset}

    def append(
          %__MODULE__{chunk_bytes: limit, append: callback} = writer,
          offset,
          bytes,
          checkpoint
        )
        when is_integer(limit) and limit > 0 and is_integer(offset) and offset >= 0 and
               is_binary(bytes) and is_function(callback, 2) and is_function(checkpoint, 0) do
      count = min(limit, byte_size(bytes))
      <<chunk::binary-size(^count), rest::binary>> = bytes

      with :ok <- checkpoint.(),
           {:ok, next} when next == offset + count <- callback.(offset, chunk) do
        append(writer, next, rest, checkpoint)
      else
        {:error, error} ->
          if Skopos.Providers.Target.Error.context_failure?(error) do
            {:error,
             Skopos.Providers.Target.Error.context_failure(error, %{
               "receiving_file_id" => writer.id,
               "received_bytes" => offset,
               "pending_chunk_bytes" => byte_size(bytes)
             })}
          else
            {:error, error}
          end

        _ ->
          {:error, :invalid_chunk_ack}
      end
    end

    def append(_writer, _offset, _bytes, _checkpoint), do: {:error, :invalid_chunk}

    def stream(%{"size_bytes" => size}, reader)
        when is_integer(size) and size >= 0 and is_function(reader, 1) do
      Stream.unfold(0, fn offset ->
        if offset == size do
          nil
        else
          case reader.(offset) do
            {:ok, chunk}
            when is_binary(chunk) and byte_size(chunk) > 0 and offset + byte_size(chunk) <= size ->
              {chunk, offset + byte_size(chunk)}

            {:error, error} ->
              throw({:file_read_error, error})

            _ ->
              throw({:file_read_error, :invalid_chunk})
          end
        end
      end)
    end

    def valid_options?(nil), do: true

    def valid_options?(%{"name" => name, "media_type" => media} = options),
      do: map_size(options) == 2 and FileReference.valid_metadata?(name, media)

    def valid_options?(_options), do: false

    def options_schema do
      %{
        "type" => "object",
        "properties" => Map.take(FileReference.schema()["properties"], ~w(name media_type)),
        "required" => ~w(name media_type),
        "additionalProperties" => false
      }
    end
  end

  defmodule AccessMethodProfile do
    @moduledoc false
    @enforce_keys [:method, :capabilities]
    defstruct @enforce_keys

    @type t :: %__MODULE__{
            method: String.t(),
            capabilities: [String.t()]
          }
  end

  defmodule CapabilitiesRequest do
    @moduledoc false
    @enforce_keys [:provider_revision, :connection]
    defstruct @enforce_keys
    @type t :: %__MODULE__{provider_revision: pos_integer(), connection: Connection.t()}
  end

  defmodule MethodRequest do
    @moduledoc false
    @enforce_keys [
      :provider_revision,
      :connection,
      :capability,
      :operation,
      :selectors,
      :parameters
    ]
    defstruct @enforce_keys ++ [files: %{}]
  end

  defmodule RequestClassification do
    @moduledoc false
    @enforce_keys [:kind]
    defstruct @enforce_keys
  end

  defmodule ObservationRequest do
    @moduledoc false

    @enforce_keys [
      :provider_revision,
      :target_id,
      :target_revision,
      :access_method_id,
      :access_method_revision,
      :connection,
      :capability,
      :operation,
      :authorization_digest
    ]

    defstruct @enforce_keys ++
                [
                  selectors: %{},
                  parameters: %{},
                  files: %{},
                  max_attempts: 1,
                  authority_mode: nil
                ]

    @type t :: %__MODULE__{}
  end

  defmodule Observation do
    @moduledoc false
    @enforce_keys [:facts, :observed_at]
    defstruct @enforce_keys ++ [evidence: [], state_facts: nil]
    @type t :: %__MODULE__{}

    def details(%__MODULE__{} = value) do
      details = %{
        "facts" => value.facts,
        "evidence" => value.evidence,
        "observed_at" => DateTime.to_iso8601(value.observed_at)
      }

      if value.state_facts,
        do: Map.put(details, "state_facts", value.state_facts),
        else: details
    end
  end

  defmodule EffectRequest do
    @moduledoc false

    @enforce_keys [
      :provider_revision,
      :target_id,
      :target_revision,
      :access_method_id,
      :access_method_revision,
      :connection,
      :capability,
      :operation,
      :authorization_digest,
      :operation_id,
      :idempotency_key
    ]

    defstruct @enforce_keys ++
                [
                  selectors: %{},
                  parameters: %{},
                  files: %{},
                  authority_mode: nil
                ]

    @type t :: %__MODULE__{}
  end

  defmodule EffectResult do
    @moduledoc false
    @enforce_keys [:status]
    @derive {Inspect, except: [:protected_reference]}
    defstruct @enforce_keys ++ [reference: nil, details: %{}, protected_reference: nil]
    @type t :: %__MODULE__{}
  end

  defmodule VerificationRequest do
    @moduledoc false

    @enforce_keys [
      :provider_revision,
      :target_id,
      :target_revision,
      :access_method_id,
      :access_method_revision,
      :connection,
      :capability,
      :operation,
      :authorization_digest,
      :operation_id
    ]

    defstruct @enforce_keys ++
                [
                  selectors: %{},
                  parameters: %{},
                  files: %{},
                  reference: nil,
                  expected: %{}
                ]

    @type t :: %__MODULE__{}
  end

  defmodule Verification do
    @moduledoc false
    @enforce_keys [:status, :observed_at]
    defstruct @enforce_keys ++ [facts: %{}, evidence: []]
    @type t :: %__MODULE__{}
  end

  defmodule Error do
    @moduledoc false
    use Splode.Error, class: :unknown, fields: [:category, :message, :progress]
    @context_failure_message "Target invocation context check failed"

    @impl true
    def message(error), do: error.message

    def unwrap(%__MODULE__{} = error), do: error
    def unwrap(%Ash.Error.Unknown{errors: [error]}), do: unwrap(error)
    def unwrap(_error), do: nil

    def context_failure(cause, progress \\ nil) do
      if find(cause) do
        error = Ash.Error.to_error_class(cause)
        %{error | errors: Enum.map(error.errors, &enrich_progress(&1, progress))}
      else
        Ash.Error.to_error_class([
          cause,
          exception(category: :failed, message: @context_failure_message, progress: progress)
        ])
      end
    end

    defp enrich_progress(
           %__MODULE__{category: :failed, message: @context_failure_message} = error,
           progress
         )
         when is_map(progress),
         do: %{error | progress: Map.merge(error.progress || %{}, progress)}

    defp enrich_progress(error, _progress), do: error

    def context_failure?(%{errors: errors} = error) when is_list(errors),
      do: not is_nil(find(error))

    def context_failure?(_error), do: false

    def context_progress(%__MODULE__{progress: progress}) when is_map(progress), do: progress

    def context_progress(%{errors: errors}) when is_list(errors),
      do: Enum.find_value(errors, &context_progress/1)

    def context_progress(_error), do: nil

    defp find(%__MODULE__{category: :failed, message: @context_failure_message} = error),
      do: error

    defp find(%{errors: errors}) when is_list(errors), do: Enum.find_value(errors, &find/1)
    defp find(_error), do: nil
  end

  defmodule BeforeSendError do
    @moduledoc false
    use Splode.Error, class: :unknown, fields: [:cause]
    @type t :: %__MODULE__{}

    @impl true
    def message(%{cause: %Skopos.Providers.Target.Error{category: :cancelled}}),
      do: "Target request was cancelled before dispatch"

    def message(_error), do: "Target request was not sent because its local input was unavailable"

    def unwrap(%__MODULE__{} = error), do: error
    def unwrap(%Ash.Error.Unknown{errors: [error]}), do: unwrap(error)
    def unwrap(_error), do: nil

    def retryable?(%__MODULE__{cause: %Skopos.Providers.Target.Error{category: :cancelled}}),
      do: false

    def retryable?(%__MODULE__{cause: cause}), do: unexpected?(cause)

    defp unexpected?(%{errors: errors}) when is_list(errors) and errors != [],
      do: Enum.any?(errors, &unexpected?/1)

    defp unexpected?(%{class: class}) when class in [:invalid, :forbidden], do: false
    defp unexpected?(_error), do: true
  end

  @type invocation :: map()
  @type read_error ::
          {:error, :retryable | :timeout | :failed | :cancelled, String.t()}
          | {:error, BeforeSendError.t()}
          | {:error, Ash.Error.t()}
  @type effect_error ::
          {:error, :failed | :cancelled, String.t()}
          | {:error, BeforeSendError.t()}
          | {:error, Ash.Error.t()}

  @callback capabilities(state :: term(), invocation()) ::
              {:ok, Capabilities.t()} | read_error()
  @callback bind_connection(state :: term(), Connection.t()) ::
              {:ok, term()} | {:error, :failed, String.t()}
  @callback observe(state :: term(), ObservationRequest.t(), invocation()) ::
              {:ok, Observation.t()} | read_error()
  @callback effect(state :: term(), EffectRequest.t(), invocation()) ::
              {:ok, EffectResult.t()} | effect_error()
  @callback verify(state :: term(), VerificationRequest.t(), invocation()) ::
              {:ok, Verification.t()} | read_error()
  @callback resource_scope(operation :: String.t(), capability :: String.t(), selectors :: map()) ::
              String.t()

  @callback access_method_profile() :: AccessMethodProfile.t() | :unrestricted

  @callback classify_request(state :: term(), MethodRequest.t()) ::
              {:ok, :observation | :effect} | {:error, :failed, String.t()}

  @optional_callbacks resource_scope: 3

  def classify_request(adapter, state, %MethodRequest{} = request) when is_atom(adapter) do
    cond do
      not valid_method_request?(request) ->
        {:error, :failed, "Target Method request is invalid"}

      not function_exported?(adapter, :classify_request, 2) ->
        {:error, :failed, "Target classifier is unavailable"}

      true ->
        classify_with_adapter(adapter, state, request)
    end
  end

  def classify_request(_adapter, _state, _request),
    do: {:error, :failed, "Target Method request is invalid"}

  defp classify_with_adapter(adapter, state, request) do
    case adapter.classify_request(state, request) do
      {:ok, kind} when kind in [:observation, :effect] ->
        {:ok, %RequestClassification{kind: kind}}

      {:error, :failed, reason} when is_binary(reason) and byte_size(reason) in 1..500 ->
        {:error, :failed, reason}

      _other ->
        {:error, :failed, "Target classifier returned an invalid result"}
    end
  rescue
    _error -> {:error, :failed, "Target classifier returned an invalid result"}
  catch
    _kind, _reason -> {:error, :failed, "Target classifier returned an invalid result"}
  end

  defp valid_method_request?(%MethodRequest{} = request) do
    is_integer(request.provider_revision) and request.provider_revision > 0 and
      match?(%Connection{}, request.connection) and
      bounded_binary?(request.connection.endpoint, 1_024) and
      bounded_binary?(request.capability, 120) and
      bounded_binary?(request.operation, 120) and
      bounded_map?(request.selectors) and bounded_map?(request.parameters) and
      FileReference.valid_set?(request.files)
  end

  defp bounded_binary?(value, maximum),
    do: is_binary(value) and byte_size(value) in 1..maximum and String.valid?(value)

  defp bounded_map?(value) when is_map(value) and map_size(value) <= 100 do
    case Jason.encode(value) do
      {:ok, encoded} -> byte_size(encoded) <= max_payload_bytes()
      {:error, _reason} -> false
    end
  end

  defp bounded_map?(_value), do: false

  def capability_names(%Capabilities{} = capabilities) do
    (capabilities.observations ++ capabilities.effects)
    |> Enum.map(& &1.capability)
    |> Enum.uniq()
  end
end
