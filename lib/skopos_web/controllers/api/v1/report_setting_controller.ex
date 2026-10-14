defmodule SkoposWeb.API.V1.ReportSettingController do
  use SkoposWeb, :api_controller

  action_fallback SkoposWeb.API.FallbackController

  alias Skopos.Reports
  alias SkoposWeb.API.{Response, Schemas}
  alias SkoposWeb.API.V1.{OutcomeJSON, OutcomeSchemas}

  tags ["Reports"]

  operation :show,
    operation_id: "getReportSetting",
    summary: "Get automatic Case Report generation setting",
    responses:
      [ok: {"Report setting", "application/json", OutcomeSchemas.ref("ReportSettingResponse")}] ++
        Schemas.errors([:unauthorized, :forbidden, :internal_server_error])

  operation :update,
    operation_id: "updateReportSetting",
    summary: "Enable or disable automatic Case Report generation",
    request_body:
      {"Report setting", "application/json", OutcomeSchemas.ref("UpdateReportSettingRequest"),
       required: true},
    responses:
      [
        ok:
          {"Report setting updated", "application/json",
           OutcomeSchemas.ref("ReportSettingResponse")}
      ] ++
        Schemas.errors([
          :bad_request,
          :unauthorized,
          :forbidden,
          :conflict,
          :unprocessable_entity,
          :internal_server_error
        ])

  def show(conn, _params) do
    with {:ok, setting} <- Reports.current_setting(actor: conn.assigns.current_user) do
      Response.data(conn, OutcomeJSON.report_setting(setting))
    end
  end

  def update(conn, %{"report_setting" => input}) do
    with {:ok, setting} <- Reports.current_setting(actor: conn.assigns.current_user),
         {:ok, updated} <-
           Reports.configure_setting(
             setting,
             input["expected_revision"],
             input["automatic_case_reports_enabled"],
             actor: conn.assigns.current_user
           ) do
      Response.data(conn, OutcomeJSON.report_setting(updated))
    end
  end

  def update(_conn, _params), do: {:error, :bad_request}
end
