defmodule Skopos.Providers.Provider.Actions.Signal do
  use Ash.Resource.Actions.Implementation

  alias Skopos.Providers
  alias Skopos.Providers.{Redactor, Registry, Signal}

  @failures [:authentication, :invalid_input, :failed]
  @max_body_bytes 1_048_576
  @max_headers 100
  @max_fact_fields 100
  # Leave room for the persisted evidence envelope around normalized facts.
  @max_fact_bytes 60_000
  @max_events 1_000
  @max_result_bytes 2_097_152
  @max_receipt_id_bytes 500
  @max_source_bytes 120
  @max_event_key_bytes 500

  @impl true
  def run(input, _opts, _context) do
    %{provider_id: provider_id, expected_revision: revision, envelope: envelope} = input.arguments
    invocation = input.arguments.invocation

    with :ok <- validate_envelope(envelope),
         {:ok, provider} <-
           Providers.load_provider_for_invocation(provider_id, revision, :signal,
             authorize?: false
           ),
         {:ok, adapter} <- fetch_signal_adapter(provider.adapter_type),
         {:ok, state} <- build_state(adapter, provider),
         {:ok, receipt} <-
           authenticate(adapter, state, envelope, invocation, provider.credentials),
         :ok <- validate_receipt(receipt),
         {:ok, events} <-
           normalize(adapter, state, envelope, receipt, invocation, provider.credentials),
         :ok <- validate_events(events, receipt),
         result <- %Signal.IngestResult{receipt: receipt, events: events},
         :ok <- validate_result_size(result) do
      {:ok, Redactor.value(result, provider.credentials)}
    end
  rescue
    _error -> {:error, signal_error(:failed, "Signal provider failed")}
  catch
    _kind, _reason -> {:error, signal_error(:failed, "Signal provider failed")}
  end

  defp validate_envelope(%Signal.Envelope{
         body: body,
         headers: headers,
         received_at: %DateTime{}
       })
       when is_binary(body) and byte_size(body) <= @max_body_bytes and is_map(headers) and
              map_size(headers) <= @max_headers do
    if Enum.all?(headers, fn {key, value} -> is_binary(key) and is_binary(value) end) do
      :ok
    else
      {:error, signal_error(:invalid_input, "Signal headers are invalid")}
    end
  end

  defp validate_envelope(_envelope),
    do: {:error, signal_error(:invalid_input, "Signal envelope is invalid")}

  defp fetch_signal_adapter(adapter_type) do
    case Registry.fetch(adapter_type, Signal) do
      {:ok, adapter} -> {:ok, adapter}
      {:error, _reason} -> {:error, signal_error(:failed, "Signal adapter is unavailable")}
    end
  end

  defp build_state(adapter, provider) do
    case Registry.build(adapter, provider.configuration, provider.credentials) do
      {:ok, state} -> {:ok, state}
      {:error, _reason} -> {:error, signal_error(:failed, "Signal configuration is invalid")}
    end
  end

  defp authenticate(adapter, state, envelope, invocation, credentials) do
    safe_call(fn -> adapter.authenticate(state, envelope, invocation) end, credentials)
    |> normalize_adapter_result(credentials)
  end

  defp normalize(adapter, state, envelope, receipt, invocation, credentials) do
    safe_call(fn -> adapter.normalize(state, envelope, receipt, invocation) end, credentials)
    |> normalize_adapter_result(credentials)
  end

  defp validate_receipt(%Signal.AuthenticatedReceipt{
         receipt_id: receipt_id,
         source: source,
         metadata: metadata
       })
       when is_binary(receipt_id) and byte_size(receipt_id) > 0 and
              byte_size(receipt_id) <= @max_receipt_id_bytes and is_binary(source) and
              byte_size(source) > 0 and byte_size(source) <= @max_source_bytes do
    if bounded_facts?(metadata),
      do: :ok,
      else: {:error, signal_error(:invalid_input, "Authenticated receipt facts are too large")}
  end

  defp validate_receipt(_receipt),
    do: {:error, signal_error(:invalid_input, "Invalid authenticated receipt")}

  defp validate_events(events, receipt)
       when is_list(events) and events != [] and length(events) <= @max_events do
    if Enum.all?(events, &valid_event?(&1, receipt)) and unique_event_keys?(events),
      do: :ok,
      else: {:error, signal_error(:invalid_input, "Invalid normalized events")}
  end

  defp validate_events(_events, _receipt),
    do: {:error, signal_error(:invalid_input, "Invalid normalized events")}

  defp valid_event?(
         %Signal.Event{
           receipt_id: receipt_id,
           event_key: event_key,
           state: state,
           occurred_at: %DateTime{},
           source_sequence: sequence,
           target_ref: target_ref,
           attributes: attributes,
           metadata: metadata
         },
         %Signal.AuthenticatedReceipt{receipt_id: receipt_id}
       )
       when is_binary(event_key) and byte_size(event_key) > 0 and
              byte_size(event_key) <= @max_event_key_bytes and
              state in [:firing, :recovered] and
              (is_nil(sequence) or is_integer(sequence) or
                 (is_binary(sequence) and byte_size(sequence) > 0 and
                    byte_size(sequence) <= @max_event_key_bytes)),
       do:
         bounded_facts?(attributes) and bounded_facts?(metadata) and
           (is_nil(target_ref) or bounded_facts?(target_ref))

  defp valid_event?(_event, _receipt), do: false

  defp unique_event_keys?(events) do
    keys = Enum.map(events, & &1.event_key)
    length(keys) == MapSet.size(MapSet.new(keys))
  end

  defp validate_result_size(result) do
    if :erlang.external_size(result) <= @max_result_bytes,
      do: :ok,
      else: {:error, signal_error(:invalid_input, "Normalized Signal result is too large")}
  end

  defp normalize_adapter_result({:ok, value}, _credentials), do: {:ok, value}

  defp normalize_adapter_result({:error, category, message}, credentials)
       when category in @failures and is_binary(message),
       do: {:error, signal_error(category, Redactor.message(message, credentials))}

  defp normalize_adapter_result(_result, _credentials),
    do: {:error, signal_error(:invalid_input, "Invalid signal adapter result")}

  defp bounded_facts?(facts) when is_map(facts) and map_size(facts) <= @max_fact_fields,
    do: :erlang.external_size(facts) <= @max_fact_bytes

  defp bounded_facts?(_facts), do: false

  defp safe_call(callback, credentials) do
    callback.()
  rescue
    error -> {:error, :failed, Redactor.message(Exception.message(error), credentials)}
  catch
    _kind, _reason -> {:error, :failed, "Signal provider failed"}
  end

  defp signal_error(category, message),
    do: Signal.Error.exception(category: category, message: message)
end
