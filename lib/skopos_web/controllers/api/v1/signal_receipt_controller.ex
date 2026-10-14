defmodule SkoposWeb.API.V1.SignalReceiptController do
  use SkoposWeb, :api_controller

  action_fallback SkoposWeb.API.FallbackController

  alias Skopos.Signals
  alias SkoposWeb.API.{Pagination, Response, Schemas}
  alias SkoposWeb.API.V1.{OutcomeJSON, OutcomeSchemas}

  @list_errors Schemas.errors([
                 :unauthorized,
                 :forbidden,
                 :unprocessable_entity,
                 :internal_server_error
               ])
  @show_errors Schemas.errors([
                 :unauthorized,
                 :forbidden,
                 :not_found,
                 :unprocessable_entity,
                 :internal_server_error
               ])

  tags ["Signals"]

  operation :index,
    operation_id: "listSignalReceipts",
    summary: "List Signal receipts",
    parameters: Schemas.pagination_parameters(),
    responses:
      [
        ok: {"Signal receipt page", "application/json", OutcomeSchemas.ref("SignalReceiptPage")}
      ] ++ @list_errors

  operation :show,
    operation_id: "getSignalReceipt",
    summary: "Get a Signal receipt",
    parameters: Schemas.id_parameter(),
    responses:
      [
        ok: {"Signal receipt", "application/json", OutcomeSchemas.ref("SignalReceiptResponse")}
      ] ++ @show_errors

  operation :events,
    operation_id: "listSignalReceiptEvents",
    summary: "List normalized events for a Signal receipt",
    parameters: Schemas.id_parameter() ++ Schemas.pagination_parameters(),
    responses:
      [
        ok: {"Signal event page", "application/json", OutcomeSchemas.ref("SignalEventPage")}
      ] ++ @show_errors

  def index(conn, params) do
    with {:ok, page} <- Pagination.parse(params),
         {:ok, receipts} <-
           Signals.page_signal_receipts(page: page, actor: conn.assigns.current_user) do
      Response.page(conn, receipts, &OutcomeJSON.receipt/1)
    end
  end

  def show(conn, %{"id" => id}) do
    with {:ok, receipt} <- Signals.get_signal_receipt(id, actor: conn.assigns.current_user) do
      Response.data(conn, OutcomeJSON.receipt(receipt))
    end
  end

  def events(conn, %{"id" => id} = params) do
    with {:ok, page} <- Pagination.parse(params),
         {:ok, events} <-
           Signals.page_signal_events_for_receipt(id,
             page: page,
             actor: conn.assigns.current_user
           ) do
      Response.page(conn, events, &OutcomeJSON.signal_event/1)
    end
  end
end
