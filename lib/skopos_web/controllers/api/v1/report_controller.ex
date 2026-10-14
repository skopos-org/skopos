defmodule SkoposWeb.API.V1.ReportController do
  use SkoposWeb, :api_controller

  alias OpenApiSpex.Schema

  action_fallback SkoposWeb.API.FallbackController

  alias Skopos.Reports
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

  tags ["Reports"]

  operation :index,
    operation_id: "listReports",
    summary: "List Reports",
    parameters: Schemas.pagination_parameters() ++ [Schemas.reference_ids_parameter()],
    responses:
      [ok: {"Report page", "application/json", OutcomeSchemas.ref("ReportPage")}] ++ @list_errors

  operation :show,
    operation_id: "getReport",
    summary: "Get a Report",
    parameters: Schemas.id_parameter(),
    responses:
      [ok: {"Report", "application/json", OutcomeSchemas.ref("ReportResponse")}] ++ @show_errors

  operation :revision,
    operation_id: "getCaseReportRevision",
    summary: "Get the Report summary for an exact Case revision",
    parameters:
      Schemas.id_parameter(:case_id) ++
        [
          case_revision: [
            in: :path,
            required: true,
            schema: %Schema{type: :integer, minimum: 1, maximum: 9_223_372_036_854_775_807}
          ]
        ],
    responses:
      [ok: {"Report summary", "application/json", OutcomeSchemas.ref("ReportSummaryResponse")}] ++
        @show_errors

  operation :summary,
    operation_id: "getPeriodOperationsSummary",
    summary: "Summarize Cases and scheduled audits opened in a UTC half-open period",
    parameters: [
      {:from, [in: :query, required: true, schema: Schemas.timestamp()]},
      {:to, [in: :query, required: true, schema: Schemas.timestamp()]},
      {:target_id, [in: :query, schema: %Schema{type: :string, format: :uuid}]}
    ],
    responses:
      [ok: {"Period summary", "application/json", OutcomeSchemas.ref("PeriodSummaryResponse")}] ++
        Schemas.errors([
          :bad_request,
          :unauthorized,
          :forbidden,
          :unprocessable_entity,
          :internal_server_error
        ])

  operation :generate,
    operation_id: "generateCaseReport",
    summary: "Generate a Case Report",
    parameters: Schemas.id_parameter(:case_id),
    request_body:
      {"Case revision", "application/json", OutcomeSchemas.ref("GenerateReportRequest"),
       required: true},
    responses:
      [created: {"Report generated", "application/json", OutcomeSchemas.ref("ReportResponse")}] ++
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
    input = OpenApiSpex.params(conn) |> Map.take([:ids])

    with {:ok, page} <- Pagination.parse(params),
         {:ok, reports} <-
           Reports.page_reports(input, page: page, actor: conn.assigns.current_user) do
      Response.page(conn, reports, &OutcomeJSON.report_summary/1)
    end
  end

  def show(conn, %{"id" => id}) do
    with {:ok, report} <- Reports.get_report(id, actor: conn.assigns.current_user) do
      Response.data(conn, OutcomeJSON.report(report))
    end
  end

  def revision(conn, _params) do
    %{case_id: case_id, case_revision: revision} = OpenApiSpex.params(conn)

    with {:ok, report} <-
           Reports.report_summary_by_case_revision(case_id, revision,
             actor: conn.assigns.current_user
           ) do
      Response.data(conn, OutcomeJSON.report_summary(report))
    end
  end

  def summary(conn, %{"from" => from, "to" => to} = params) do
    with {:ok, from_time, _offset} <- DateTime.from_iso8601(from),
         {:ok, to_time, _offset} <- DateTime.from_iso8601(to),
         {:ok, result} <-
           Reports.period_summary(
             from_time,
             to_time,
             Map.get(params, "target_id"),
             actor: conn.assigns.current_user
           ) do
      Response.data(conn, result)
    else
      {:error, :invalid_format} -> {:error, :bad_request}
      {:error, :missing_offset} -> {:error, :bad_request}
      other -> other
    end
  end

  def summary(_conn, _params), do: {:error, :bad_request}

  def generate(
        conn,
        %{"case_id" => case_id, "report" => %{"expected_case_revision" => revision}}
      ) do
    with {:ok, report} <-
           Reports.generate_report(case_id, revision, actor: conn.assigns.current_user) do
      Response.data(conn, OutcomeJSON.report(report), :created)
    end
  end

  def generate(_conn, _params), do: {:error, :bad_request}
end
