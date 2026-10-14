defmodule SkoposWeb.API.V1.AIUsageRoleAssignmentController do
  use SkoposWeb, :api_controller

  action_fallback SkoposWeb.API.FallbackController

  alias Skopos.Providers
  alias SkoposWeb.API.{Pagination, Response}
  alias SkoposWeb.API.V1.{AIUsageRoleAssignmentJSON, ProviderSchemas}

  tags ["AI usage roles"]

  operation :index,
    operation_id: "listAIUsageRoleAssignments",
    summary: "List AI usage-role assignments",
    parameters: ProviderSchemas.assignment_page_parameters(),
    responses:
      [
        ok:
          {"AI usage-role assignment page", "application/json",
           ProviderSchemas.ref("AIUsageRoleAssignmentPage")}
      ] ++
        SkoposWeb.API.Schemas.errors([
          :unauthorized,
          :forbidden,
          :unprocessable_entity,
          :internal_server_error
        ])

  def index(conn, params) do
    input = OpenApiSpex.params(conn) |> Map.take([:provider_ids])

    with {:ok, page} <- Pagination.parse(params),
         {:ok, assignments} <-
           Providers.page_ai_usage_role_assignments(
             input,
             page: page,
             actor: conn.assigns.current_user
           ) do
      Response.page(conn, assignments, &AIUsageRoleAssignmentJSON.data/1)
    end
  end
end
