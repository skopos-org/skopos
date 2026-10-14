defmodule SkoposWeb.API.V1.InventoryImportController do
  use SkoposWeb, :api_controller

  action_fallback SkoposWeb.API.FallbackController

  alias Skopos.Providers.Inventory
  alias Skopos.Targets
  alias SkoposWeb.API.{Pagination, Response, Schemas}
  alias SkoposWeb.API.V1.{InventoryImportJSON, InventorySchemas}

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
  @write_errors Schemas.errors([
                  :bad_request,
                  :unauthorized,
                  :forbidden,
                  :not_found,
                  :conflict,
                  :unprocessable_entity,
                  :internal_server_error
                ])

  tags ["Inventory imports"]

  operation :index,
    operation_id: "listInventoryImports",
    summary: "List inventory imports",
    parameters: Schemas.pagination_parameters(),
    responses:
      [
        ok:
          {"Inventory import page", "application/json",
           InventorySchemas.ref("InventoryImportPage")}
      ] ++ @list_errors

  operation :show,
    operation_id: "getInventoryImport",
    summary: "Get an inventory import",
    parameters: Schemas.id_parameter(),
    responses:
      [
        ok:
          {"Inventory import", "application/json",
           InventorySchemas.ref("InventoryImportResponse")}
      ] ++ @show_errors

  operation :rows,
    operation_id: "listInventoryImportRows",
    summary: "List inventory import rows",
    parameters: Schemas.id_parameter() ++ Schemas.pagination_parameters(),
    responses:
      [
        ok:
          {"Inventory import row page", "application/json",
           InventorySchemas.ref("InventoryImportRowPage")}
      ] ++ @show_errors

  operation :preview_manual,
    operation_id: "previewManualInventory",
    summary: "Preview a manual CSV inventory import",
    request_body:
      {"Manual inventory preview", "application/json",
       InventorySchemas.ref("ManualInventoryPreviewRequest"), required: true},
    responses:
      [
        created:
          {"Inventory preview created", "application/json",
           InventorySchemas.ref("InventoryImportResponse")}
      ] ++ @write_errors

  operation :row_summaries,
    operation_id: "listInventoryImportRowSummaries",
    summary: "List inventory preview row display metadata",
    parameters: Schemas.id_parameter() ++ Schemas.pagination_parameters(),
    responses:
      [
        ok:
          {"Inventory row display page", "application/json",
           InventorySchemas.ref("InventoryImportRowSummaryPage")}
      ] ++ @show_errors

  operation :preview_provider,
    operation_id: "previewProviderInventory",
    summary: "Preview inventory from an Inventory Provider",
    request_body:
      {"Provider inventory preview", "application/json",
       InventorySchemas.ref("ProviderInventoryPreviewRequest"), required: true},
    responses:
      [
        created:
          {"Inventory preview created", "application/json",
           InventorySchemas.ref("InventoryImportResponse")}
      ] ++ @write_errors

  operation :apply_import,
    operation_id: "applyInventoryImport",
    summary: "Apply a reviewed inventory preview",
    parameters: Schemas.id_parameter(),
    request_body:
      {"Inventory import revision and digest", "application/json",
       InventorySchemas.ref("ApplyInventoryImportRequest"), required: true},
    responses:
      [
        ok:
          {"Inventory import applied", "application/json",
           InventorySchemas.ref("InventoryImportResponse")}
      ] ++ @write_errors

  def index(conn, params) do
    with {:ok, page} <- Pagination.parse(params),
         {:ok, imports} <-
           Targets.page_inventory_imports(page: page, actor: conn.assigns.current_user) do
      Response.page(conn, imports, &InventoryImportJSON.data/1)
    end
  end

  def show(conn, %{"id" => id}) do
    with {:ok, import} <- Targets.get_inventory_import(id, actor: conn.assigns.current_user) do
      Response.data(conn, InventoryImportJSON.data(import))
    end
  end

  def rows(conn, %{"id" => id} = params) do
    with {:ok, page} <- Pagination.parse(params),
         {:ok, rows} <-
           Targets.page_inventory_import_rows(id,
             page: page,
             actor: conn.assigns.current_user
           ) do
      Response.page(conn, rows, &InventoryImportJSON.row/1)
    end
  end

  def preview_manual(conn, %{"inventory_import" => %{"source" => source, "csv" => csv}}) do
    with {:ok, import} <-
           Targets.preview_manual_inventory(source, csv, actor: conn.assigns.current_user) do
      Response.data(conn, InventoryImportJSON.data(import), :created)
    end
  end

  def preview_manual(_conn, _params), do: {:error, :bad_request}

  def row_summaries(conn, %{"id" => id} = params) do
    with {:ok, page} <- Pagination.parse(params),
         {:ok, rows} <-
           Targets.page_inventory_import_row_summaries(id,
             page: page,
             actor: conn.assigns.current_user
           ) do
      Response.page(conn, rows, &InventoryImportJSON.row_summary/1)
    end
  end

  def preview_provider(
        conn,
        %{
          "inventory_import" =>
            %{
              "source" => source,
              "provider_id" => provider_id,
              "provider_revision" => provider_revision
            } = input
        }
      ) do
    request = %Inventory.Request{
      provider_revision: provider_revision,
      scope: input["scope"] || %{},
      max_pages: input["max_pages"] || 100
    }

    with {:ok, import} <-
           Targets.preview_provider_inventory(source, provider_id, request, %{},
             actor: conn.assigns.current_user
           ) do
      Response.data(conn, InventoryImportJSON.data(import), :created)
    end
  end

  def preview_provider(_conn, _params), do: {:error, :bad_request}

  def apply_import(
        conn,
        %{
          "id" => id,
          "inventory_import" => %{
            "expected_revision" => expected_revision,
            "expected_digest" => expected_digest
          }
        }
      ) do
    with {:ok, import} <-
           Targets.apply_inventory_import(id, expected_revision, expected_digest,
             actor: conn.assigns.current_user
           ) do
      Response.data(conn, InventoryImportJSON.data(import))
    end
  end

  def apply_import(_conn, _params), do: {:error, :bad_request}
end
