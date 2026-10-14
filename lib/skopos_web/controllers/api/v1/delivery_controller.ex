defmodule SkoposWeb.API.V1.DeliveryController do
  use SkoposWeb, :api_controller

  action_fallback SkoposWeb.API.FallbackController

  alias Skopos.Notifications
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

  tags ["Deliveries"]

  operation :index,
    operation_id: "listDeliveries",
    summary: "List Report deliveries",
    parameters: Schemas.pagination_parameters(),
    responses:
      [ok: {"Delivery page", "application/json", OutcomeSchemas.ref("DeliveryPage")}] ++
        @list_errors

  operation :summaries,
    operation_id: "listDeliverySummaries",
    summary: "List Report delivery summaries",
    parameters: Schemas.pagination_parameters() ++ [OutcomeSchemas.report_ids_parameter()],
    responses:
      [
        ok:
          {"Delivery summary page", "application/json", OutcomeSchemas.ref("DeliverySummaryPage")}
      ] ++
        @list_errors

  operation :latest,
    operation_id: "listLatestReportDeliveries",
    summary: "Get the latest delivery for each referenced Report",
    parameters: [OutcomeSchemas.report_ids_parameter(true)],
    responses:
      [
        ok:
          {"Latest deliveries", "application/json",
           OutcomeSchemas.ref("LatestDeliveriesResponse")}
      ] ++
        @list_errors ++ Schemas.errors([:bad_request])

  operation :receipt,
    operation_id: "getDeliveryReceipt",
    summary: "Get the saved delivery for its original request key",
    parameters: [
      idempotency_key: [
        in: :query,
        required: true,
        schema: %OpenApiSpex.Schema{type: :string, minLength: 1, maxLength: 1_024}
      ]
    ],
    responses:
      [
        ok:
          {"Delivery summary", "application/json", OutcomeSchemas.ref("DeliverySummaryResponse")}
      ] ++
        @show_errors ++ Schemas.errors([:bad_request])

  operation :show,
    operation_id: "getDelivery",
    summary: "Get a Report delivery",
    parameters: Schemas.id_parameter(),
    responses:
      [ok: {"Delivery", "application/json", OutcomeSchemas.ref("DeliveryResponse")}] ++
        @show_errors

  operation :create,
    operation_id: "createDelivery",
    summary: "Enqueue a Report delivery",
    request_body:
      {"Delivery", "application/json", OutcomeSchemas.ref("CreateDeliveryRequest"),
       required: true},
    responses:
      [accepted: {"Delivery queued", "application/json", OutcomeSchemas.ref("DeliveryResponse")}] ++
        Schemas.errors([
          :bad_request,
          :unauthorized,
          :forbidden,
          :not_found,
          :conflict,
          :unprocessable_entity,
          :internal_server_error
        ])

  def index(conn, params) do
    with {:ok, page} <- Pagination.parse(params),
         {:ok, deliveries} <-
           Notifications.page_deliveries(page: page, actor: conn.assigns.current_user) do
      Response.page(conn, deliveries, &OutcomeJSON.delivery/1)
    end
  end

  def summaries(conn, params) do
    input = OpenApiSpex.params(conn) |> Map.take([:report_ids])

    with {:ok, page} <- Pagination.parse(params),
         {:ok, deliveries} <-
           Notifications.page_delivery_summaries(input,
             page: page,
             actor: conn.assigns.current_user
           ) do
      Response.page(conn, deliveries, &OutcomeJSON.delivery_summary/1)
    end
  end

  def latest(conn, _params) do
    with {:ok, deliveries} <-
           Notifications.latest_deliveries_for_reports(
             OpenApiSpex.params(conn).report_ids,
             actor: conn.assigns.current_user
           ) do
      Response.data(
        conn,
        Enum.map(
          deliveries,
          &Map.put(OutcomeJSON.delivery_summary(&1), :attempt_count, &1.attempt_count)
        )
      )
    end
  end

  def receipt(conn, _params) do
    with {:ok, delivery} <-
           Notifications.delivery_summary_by_request(
             OpenApiSpex.params(conn).idempotency_key,
             actor: conn.assigns.current_user
           ) do
      Response.data(conn, OutcomeJSON.delivery_summary(delivery))
    end
  end

  def show(conn, %{"id" => id}) do
    with {:ok, delivery} <- Notifications.get_delivery(id, actor: conn.assigns.current_user) do
      Response.data(conn, OutcomeJSON.delivery(delivery))
    end
  end

  def create(conn, %{"delivery" => input}) do
    with {:ok, delivery} <-
           Notifications.enqueue_delivery(
             input["report_id"],
             input["report_revision"],
             input["provider_id"],
             input["provider_revision"],
             input["idempotency_key"],
             actor: conn.assigns.current_user
           ) do
      Response.data(conn, OutcomeJSON.delivery(delivery), :accepted)
    end
  end

  def create(_conn, _params), do: {:error, :bad_request}
end
