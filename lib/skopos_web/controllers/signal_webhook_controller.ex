defmodule SkoposWeb.SignalWebhookController do
  use SkoposWeb, :api_controller

  alias Skopos.{Providers, Signals}
  alias Skopos.Providers.Signal
  alias SkoposWeb.API.Schemas
  alias SkoposWeb.API.V1.OutcomeSchemas

  @webhook_responses [
    accepted:
      {"Signal accepted", "application/json", OutcomeSchemas.ref("SignalWebhookAccepted")},
    bad_request: {"Malformed JSON", nil, nil},
    unauthorized:
      {"Webhook authentication failed", "application/json",
       OutcomeSchemas.ref("SignalWebhookError")},
    not_found:
      {"Signal endpoint not found", "application/json", OutcomeSchemas.ref("SignalWebhookError")},
    unprocessable_entity:
      {"Webhook payload rejected", "application/json",
       OutcomeSchemas.ref("SignalWebhookValidationError")},
    service_unavailable:
      {"Signal could not be accepted", "application/json",
       OutcomeSchemas.ref("SignalWebhookError")}
  ]

  tags ["Signal webhooks"]

  operation :alertmanager,
    operation_id: "ingestAlertmanagerSignal",
    summary: "Accept an Alertmanager webhook",
    security: [%{"webhookBearerAuth" => []}],
    parameters: Schemas.id_parameter(:provider_id),
    request_body:
      {"Alertmanager webhook payload", "application/json",
       OutcomeSchemas.ref("SignalWebhookPayload"), required: true},
    responses: @webhook_responses

  operation :zabbix,
    operation_id: "ingestZabbixSignal",
    summary: "Accept a Zabbix webhook",
    security: [%{"webhookBearerAuth" => []}],
    parameters: Schemas.id_parameter(:provider_id),
    request_body:
      {"Zabbix webhook payload", "application/json", OutcomeSchemas.ref("SignalWebhookPayload"),
       required: true},
    responses: @webhook_responses

  operation :generic,
    operation_id: "ingestGenericSignal",
    summary: "Accept a canonical Skopos Signal webhook",
    security: [%{"webhookBearerAuth" => []}],
    parameters: Schemas.id_parameter(:provider_id),
    request_body:
      {"Canonical Signal payload", "application/json",
       OutcomeSchemas.ref("CanonicalSignalWebhookPayload"), required: true},
    responses: @webhook_responses

  def alertmanager(conn, %{"provider_id" => provider_id}),
    do: ingest(conn, provider_id, "alertmanager-webhook")

  def zabbix(conn, %{"provider_id" => provider_id}),
    do: ingest(conn, provider_id, "zabbix-webhook")

  def generic(conn, %{"provider_id" => provider_id}),
    do: ingest(conn, provider_id, "generic-webhook")

  defp ingest(conn, provider_id, adapter_type) do
    with {:ok, provider} <- provider(provider_id, adapter_type),
         envelope <- envelope(conn),
         {:ok, receipt} <-
           Signals.ingest_signal(
             provider.id,
             provider.revision,
             envelope,
             %{},
             authorize?: false
           ) do
      conn
      |> put_status(:accepted)
      |> json(%{receipt_id: receipt.receipt_id})
    else
      {:error, :not_found} -> error(conn, :not_found, "Signal endpoint was not found")
      {:error, failure} -> signal_error(conn, failure)
    end
  end

  defp provider(id, adapter_type) do
    case Providers.get_provider(id, authorize?: false, not_found_error?: false) do
      {:ok, %{kind: :signal, adapter_type: ^adapter_type} = provider} -> {:ok, provider}
      _missing -> {:error, :not_found}
    end
  end

  defp envelope(conn) do
    %Signal.Envelope{
      body: SkoposWeb.CacheBodyReader.raw_body(conn),
      headers: headers(conn),
      received_at: DateTime.utc_now()
    }
  end

  defp headers(conn) do
    Map.new(conn.req_headers, fn {name, value} -> {String.downcase(name), value} end)
  end

  defp signal_error(conn, failure) do
    case find_signal_error(failure) do
      %Signal.Error{category: :authentication} ->
        error(conn, :unauthorized, "Webhook authentication failed")

      %Signal.Error{category: :invalid_input, message: message} ->
        error(conn, :unprocessable_entity, message)

      _failure ->
        error(conn, :service_unavailable, "Signal could not be accepted")
    end
  end

  defp find_signal_error(%Signal.Error{} = error), do: error

  defp find_signal_error(%{errors: errors}) when is_list(errors) do
    Enum.find_value(errors, &find_signal_error/1)
  end

  defp find_signal_error(%{} = error) do
    error
    |> Map.values()
    |> Enum.find_value(&find_signal_error/1)
  end

  defp find_signal_error(_error), do: nil

  defp error(conn, status, detail) do
    conn
    |> put_status(status)
    |> json(%{errors: %{detail: detail}})
  end
end
