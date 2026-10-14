defmodule Skopos.Providers.Provider.Actions.Notification do
  use Ash.Resource.Actions.Implementation

  alias Skopos.Providers
  alias Skopos.Providers.{Notification, Redactor, Registry}

  @statuses [:accepted, :delivered, :failed, :unknown]
  @failures [:failed, :cancelled]
  @max_payload_fields 100
  @max_payload_bytes 1_048_576
  @max_identity_bytes 1_024

  @impl true
  def run(input, _opts, _context) do
    %{provider_id: provider_id, request: request, invocation: invocation} = input.arguments

    with :ok <- validate_request(request),
         :ok <- ensure_not_cancelled(invocation),
         {:ok, provider} <-
           Providers.load_provider_for_invocation(
             provider_id,
             request.provider_revision,
             :notification,
             authorize?: false
           ),
         {:ok, adapter} <- fetch_notification_adapter(provider.adapter_type),
         {:ok, state} <- build_state(adapter, provider) do
      adapter
      |> deliver(state, request, invocation, provider.credentials)
      |> normalize_result(provider.credentials)
    end
  rescue
    _error -> {:error, notification_error(:failed, "Notification provider failed")}
  catch
    _kind, _reason -> {:error, notification_error(:failed, "Notification provider failed")}
  end

  defp validate_request(%Notification.Request{} = request) do
    if positive?(request.provider_revision) and bounded_identity?(request.report_id) and
         positive?(request.report_revision) and bounded_identity?(request.destination_id) and
         positive?(request.destination_revision) and bounded_identity?(request.idempotency_key) and
         bounded_payload?(request.payload) do
      :ok
    else
      {:error, notification_error(:failed, "Notification request is invalid")}
    end
  end

  defp validate_request(_request),
    do: {:error, notification_error(:failed, "Notification request is invalid")}

  defp fetch_notification_adapter(adapter_type) do
    case Registry.fetch(adapter_type, Notification) do
      {:ok, adapter} ->
        {:ok, adapter}

      {:error, _reason} ->
        {:error, notification_error(:failed, "Notification adapter is unavailable")}
    end
  end

  defp build_state(adapter, provider) do
    case Registry.build(adapter, provider.configuration, provider.credentials) do
      {:ok, state} ->
        {:ok, state}

      {:error, _reason} ->
        {:error, notification_error(:failed, "Notification configuration is invalid")}
    end
  end

  defp deliver(adapter, state, request, invocation, credentials) do
    adapter.deliver(state, request, invocation)
  rescue
    error ->
      unknown(Redactor.message(Exception.message(error), credentials))
  catch
    _kind, _reason -> unknown("Notification outcome is unknown")
  end

  defp normalize_result({:ok, %Notification.Result{status: status} = result}, credentials)
       when status in @statuses do
    if bounded_payload?(result.details) and
         (is_nil(result.reference) or bounded_identity?(result.reference)) do
      {:ok, Redactor.value(result, credentials)}
    else
      {:error, notification_error(:failed, "Invalid notification result")}
    end
  end

  defp normalize_result({:error, :timeout, message}, credentials) when is_binary(message),
    do: unknown(Redactor.message(message, credentials)) |> normalize_result(credentials)

  defp normalize_result({:error, category, message}, credentials)
       when category in @failures and is_binary(message),
       do: {:error, notification_error(category, Redactor.message(message, credentials))}

  defp normalize_result(_result, _credentials),
    do: {:error, notification_error(:failed, "Invalid notification result")}

  defp unknown(message) do
    {:ok, %Notification.Result{status: :unknown, details: %{error: message}}}
  end

  defp ensure_not_cancelled(%{cancelled?: cancelled?}) when is_function(cancelled?, 0) do
    if cancelled?.() do
      {:error, notification_error(:cancelled, "Notification delivery was cancelled")}
    else
      :ok
    end
  end

  defp ensure_not_cancelled(_invocation), do: :ok

  defp positive?(value), do: is_integer(value) and value > 0

  defp bounded_identity?(value),
    do: is_binary(value) and byte_size(value) > 0 and byte_size(value) <= @max_identity_bytes

  defp bounded_payload?(payload)
       when is_map(payload) and map_size(payload) <= @max_payload_fields,
       do: :erlang.external_size(payload) <= @max_payload_bytes

  defp bounded_payload?(_payload), do: false

  defp notification_error(category, message),
    do: Notification.Error.exception(category: category, message: message)
end
