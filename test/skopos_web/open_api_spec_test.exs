defmodule SkoposWeb.OpenAPISpecTest do
  use SkoposWeb.ConnCase, async: true

  @http_methods [:delete, :get, :head, :options, :patch, :post, :put, :trace]
  @account_provider_controllers [
    SkoposWeb.API.V1.AccountController,
    SkoposWeb.API.V1.AIUsageRoleAssignmentController,
    SkoposWeb.API.V1.CLISessionController,
    SkoposWeb.API.V1.OIDCController,
    SkoposWeb.API.V1.ProviderController,
    SkoposWeb.API.V1.SessionController
  ]
  @target_inventory_controllers [
    SkoposWeb.API.V1.InventoryImportController,
    SkoposWeb.API.V1.TargetSetupController
  ]
  @workflow_controllers [
    SkoposWeb.API.V1.AuthoritySettingController,
    SkoposWeb.API.V1.CaseController,
    SkoposWeb.API.V1.OperationController,
    SkoposWeb.API.V1.ProposalController
  ]

  test "the application serves the resolved specification" do
    document =
      build_conn()
      |> get("/api/v1/openapi.json")
      |> json_response(200)

    assert document["openapi"] == "3.0.0"
    assert document["info"]["title"] == "Skopos API"
    assert document["components"]["securitySchemes"]["bearerAuth"]["scheme"] == "bearer"

    assert document["paths"]["/api/v1/openapi.json"]["get"]["operationId"] ==
             "getOpenAPISpecification"
  end

  test "every product API route has an operation contract" do
    missing = api_routes() -- documented_operations()

    assert missing == []
    refute {:get, "/api/v1/openapi.json"} in missing
  end

  test "contract validation uses the existing API error envelope" do
    response =
      build_conn()
      |> put_resp_header("x-request-id", "openapi-test")
      |> SkoposWeb.API.OpenAPIError.call([%{name: :email}])

    assert %{
             "error" => %{
               "code" => "validation_failed",
               "message" => "Request validation failed",
               "request_id" => "openapi-test",
               "details" => %{"fields" => ["email"]}
             }
           } = json_response(response, 422)
  end

  test "account and Provider routes have unique operations without response secrets" do
    routes =
      SkoposWeb.Router
      |> Phoenix.Router.routes()
      |> Enum.filter(&(&1.plug in @account_provider_controllers))
      |> Enum.map(&{&1.verb, normalize_path(&1.path)})

    assert routes -- documented_operations() == []

    operation_ids =
      for {_path, path_item} <- SkoposWeb.ApiSpec.spec().paths,
          method <- @http_methods,
          %OpenApiSpex.Operation{operationId: id} <- [Map.get(path_item, method)],
          do: id

    assert length(operation_ids) == length(Enum.uniq(operation_ids))

    schemas = SkoposWeb.ApiSpec.spec().components.schemas
    refute Map.has_key?(schemas["Account"].properties, :password)
    refute Map.has_key?(schemas["Provider"].properties, :credentials)
    refute Map.has_key?(schemas["OIDCProvider"].properties, :client_secret)
    assert schemas["CreateProviderRequest"].properties.provider.properties.credentials.writeOnly

    assert schemas["ConfigureOIDCProviderRequest"].properties.oidc_provider.properties.client_secret.writeOnly
  end

  test "Target and Inventory routes have complete operations and relationship fields" do
    routes =
      SkoposWeb.Router
      |> Phoenix.Router.routes()
      |> Enum.filter(&(&1.plug in @target_inventory_controllers))
      |> Enum.map(&{&1.verb, normalize_path(&1.path)})

    assert routes -- documented_operations() == []

    relationship = SkoposWeb.ApiSpec.spec().components.schemas["TargetRelationship"]

    assert Map.keys(relationship.properties) |> Enum.sort() ==
             ~w(active destination_target_id facts id inserted_at kind revision source_target_id updated_at valid_until)a

    assert relationship.additionalProperties == false
  end

  test "Authority, Case, Proposal and Operation routes have complete operations" do
    routes =
      SkoposWeb.Router
      |> Phoenix.Router.routes()
      |> Enum.filter(&(&1.plug in @workflow_controllers))
      |> Enum.map(&{&1.verb, normalize_path(&1.path)})

    assert routes -- documented_operations() == []

    case_schema = SkoposWeb.ApiSpec.spec().components.schemas["Case"]
    refute Map.has_key?(case_schema.properties, :pending_intent)
    assert case_schema.additionalProperties == false
  end

  test "Signal webhooks use their Provider secret security scheme" do
    spec = SkoposWeb.ApiSpec.spec()

    assert spec.components.securitySchemes["webhookBearerAuth"].scheme == "bearer"

    assert spec.paths["/api/v1/signals/alertmanager/{provider_id}"].post.security == [
             %{"webhookBearerAuth" => []}
           ]

    assert spec.paths["/api/v1/signals/zabbix/{provider_id}"].post.security == [
             %{"webhookBearerAuth" => []}
           ]
  end

  defp api_routes do
    SkoposWeb.Router
    |> Phoenix.Router.routes()
    |> Enum.filter(&product_api_route?/1)
    |> Enum.map(&{&1.verb, normalize_path(&1.path)})
    |> Enum.sort()
  end

  defp documented_operations do
    for {path, path_item} <- SkoposWeb.ApiSpec.spec().paths,
        method <- @http_methods,
        match?(%OpenApiSpex.Operation{}, Map.get(path_item, method)),
        do: {method, path}
  end

  defp product_api_route?(route) do
    String.starts_with?(route.path, "/api/v1") and
      route.plug != SkoposWeb.APIErrorController
  end

  defp normalize_path(path) do
    Regex.replace(~r/:([a-z_]+)/, path, "{\\1}")
  end
end
