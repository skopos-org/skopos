defmodule SkoposWeb.ApiSpec do
  @moduledoc false

  @behaviour OpenApiSpex.OpenApi

  alias OpenApiSpex.{Components, Info, OpenApi, Paths, SecurityScheme, Server}
  alias SkoposWeb.API.Schemas

  alias SkoposWeb.API.V1.{
    AccountSchemas,
    InventorySchemas,
    OutcomeSchemas,
    ProviderSchemas,
    TargetFileSchemas,
    TargetSchemas,
    WorkflowSchemas
  }

  @impl OpenApiSpex.OpenApi
  def spec do
    %OpenApi{
      info: %Info{
        title: "Skopos API",
        version: Application.spec(:skopos, :vsn) |> to_string()
      },
      servers: [%Server{url: "/"}],
      paths: Paths.from_router(SkoposWeb.Router),
      components: %Components{
        schemas:
          Schemas.components()
          |> Map.merge(AccountSchemas.components())
          |> Map.merge(ProviderSchemas.components())
          |> Map.merge(TargetSchemas.components())
          |> Map.merge(TargetFileSchemas.components())
          |> Map.merge(InventorySchemas.components())
          |> Map.merge(WorkflowSchemas.components())
          |> Map.merge(OutcomeSchemas.components()),
        securitySchemes: %{
          "bearerAuth" => %SecurityScheme{
            type: "http",
            scheme: "bearer",
            bearerFormat: "JWT"
          },
          "webhookBearerAuth" => %SecurityScheme{
            type: "http",
            scheme: "bearer",
            description: "Signal Provider webhook secret"
          }
        }
      },
      security: [%{"bearerAuth" => []}]
    }
    |> OpenApiSpex.resolve_schema_modules()
  end
end
