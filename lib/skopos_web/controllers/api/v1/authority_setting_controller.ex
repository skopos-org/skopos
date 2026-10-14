defmodule SkoposWeb.API.V1.AuthoritySettingController do
  use SkoposWeb, :api_controller

  action_fallback SkoposWeb.API.FallbackController

  alias Skopos.Cases
  alias SkoposWeb.API.{Pagination, Response, Schemas}
  alias SkoposWeb.API.V1.{WorkflowJSON, WorkflowSchemas}

  @read_errors Schemas.errors([
                 :unauthorized,
                 :forbidden,
                 :unprocessable_entity,
                 :internal_server_error
               ])
  @write_errors Schemas.errors([
                  :bad_request,
                  :unauthorized,
                  :forbidden,
                  :conflict,
                  :unprocessable_entity,
                  :internal_server_error
                ])

  tags ["Authority settings"]

  operation :readiness,
    operation_id: "getSetupReadiness",
    summary: "Get global current setup readiness",
    responses:
      [ok: {"Setup readiness", "application/json", WorkflowSchemas.ref("SetupReadinessResponse")}] ++
        @read_errors

  operation :index,
    operation_id: "listAuthoritySettings",
    summary: "List authority-setting revisions",
    parameters: Schemas.pagination_parameters(),
    responses:
      [
        ok:
          {"Authority-setting page", "application/json",
           WorkflowSchemas.ref("AuthoritySettingPage")}
      ] ++ @read_errors

  operation :show,
    operation_id: "getAuthoritySetting",
    summary: "Get the current authority setting",
    responses:
      [
        ok:
          {"Current authority setting", "application/json",
           WorkflowSchemas.ref("AuthoritySettingResponse")}
      ] ++ @read_errors

  operation :update,
    operation_id: "updateAuthoritySetting",
    summary: "Create the next authority-setting revision",
    request_body:
      {"Authority setting", "application/json",
       WorkflowSchemas.ref("UpdateAuthoritySettingRequest"), required: true},
    responses:
      [
        ok:
          {"Authority setting updated", "application/json",
           WorkflowSchemas.ref("AuthoritySettingResponse")}
      ] ++ @write_errors

  def index(conn, params) do
    with {:ok, page} <- Pagination.parse(params),
         {:ok, settings} <-
           Cases.page_authority_settings(page: page, actor: conn.assigns.current_user) do
      Response.page(conn, settings, &WorkflowJSON.authority/1)
    end
  end

  def show(conn, _params) do
    with {:ok, setting} <- Cases.current_authority_setting(actor: conn.assigns.current_user) do
      Response.data(conn, WorkflowJSON.authority(setting))
    end
  end

  def readiness(conn, _params) do
    with {:ok, readiness} <- Cases.setup_readiness(actor: conn.assigns.current_user) do
      Response.data(conn, readiness)
    end
  end

  def update(conn, %{"authority_setting" => input}) do
    with {:ok, setting} <-
           Cases.configure_authority_setting(
             input["expected_setting_revision"],
             input["authority_mode"],
             input["signal_automation_enabled"],
             input["max_elapsed_seconds"],
             input["max_resolver_turns"],
             input["max_target_requests"],
             input["max_effects"],
             input["max_related_targets"],
             input["max_ai_usage_units"],
             input["max_no_progress_turns"],
             input["reason"],
             actor: conn.assigns.current_user
           ) do
      Response.data(conn, WorkflowJSON.authority(setting))
    end
  end

  def update(_conn, _params), do: {:error, :bad_request}
end
