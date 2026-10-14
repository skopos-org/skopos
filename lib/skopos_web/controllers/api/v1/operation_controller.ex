defmodule SkoposWeb.API.V1.OperationController do
  use SkoposWeb, :api_controller

  action_fallback SkoposWeb.API.FallbackController

  alias Skopos.Cases
  alias SkoposWeb.API.{Response, Schemas}
  alias SkoposWeb.API.V1.{WorkflowJSON, WorkflowSchemas}

  @errors Schemas.errors([
            :unauthorized,
            :forbidden,
            :not_found,
            :unprocessable_entity,
            :internal_server_error
          ])

  tags ["Operations"]

  operation :show,
    operation_id: "getOperation",
    summary: "Get an Operation",
    parameters: Schemas.id_parameter(),
    responses:
      [ok: {"Operation", "application/json", WorkflowSchemas.ref("OperationResponse")}] ++
        @errors

  operation :show_verification,
    operation_id: "getVerificationAttempt",
    summary: "Get a verification attempt",
    parameters: Schemas.id_parameter(),
    responses:
      [
        ok:
          {"Verification attempt", "application/json",
           WorkflowSchemas.ref("VerificationAttemptResponse")}
      ] ++ @errors

  def show(conn, %{"id" => id}) do
    with {:ok, operation} <- Cases.get_operation(id, actor: conn.assigns.current_user) do
      Response.data(conn, WorkflowJSON.operation(operation))
    end
  end

  def show_verification(conn, %{"id" => id}) do
    with {:ok, attempt} <-
           Cases.get_verification_attempt(id, actor: conn.assigns.current_user) do
      Response.data(conn, WorkflowJSON.verification_attempt(attempt))
    end
  end
end
