defmodule SkoposWeb.API.V1.ProviderController do
  use SkoposWeb, :api_controller

  action_fallback SkoposWeb.API.FallbackController

  alias Skopos.Providers
  alias Skopos.AI.ReqLLM
  alias SkoposWeb.API.{Pagination, Response}
  alias SkoposWeb.API.V1.{ProviderJSON, ProviderSchemas}

  @update_fields ~w(name configuration credentials)

  tags ["Providers"]

  operation :services,
    operation_id: "listAIServices",
    summary: "List AI generation services",
    responses:
      [ok: {"AI services", "application/json", ProviderSchemas.ref("AIServiceCatalogResponse")}] ++
        SkoposWeb.API.Schemas.errors([:unauthorized, :internal_server_error])

  operation :index,
    operation_id: "listProviders",
    summary: "List Providers",
    parameters: SkoposWeb.API.Schemas.pagination_parameters(),
    responses:
      [ok: {"Provider page", "application/json", ProviderSchemas.ref("ProviderPage")}] ++
        SkoposWeb.API.Schemas.errors([
          :unauthorized,
          :forbidden,
          :unprocessable_entity,
          :internal_server_error
        ])

  operation :references,
    operation_id: "listProviderReferences",
    summary: "List Provider reference metadata",
    parameters: ProviderSchemas.reference_page_parameters(),
    responses:
      [
        ok:
          {"Provider reference page", "application/json",
           ProviderSchemas.ref("ProviderReferencePage")}
      ] ++
        SkoposWeb.API.Schemas.errors([
          :unauthorized,
          :forbidden,
          :unprocessable_entity,
          :internal_server_error
        ])

  operation :show,
    operation_id: "getProvider",
    summary: "Get a Provider",
    parameters: SkoposWeb.API.Schemas.id_parameter(),
    responses:
      [ok: {"Provider", "application/json", ProviderSchemas.ref("ProviderResponse")}] ++
        SkoposWeb.API.Schemas.errors([
          :unauthorized,
          :forbidden,
          :not_found,
          :unprocessable_entity,
          :internal_server_error
        ])

  operation :summaries,
    operation_id: "listProviderSummaries",
    summary: "List Provider management metadata",
    parameters: ProviderSchemas.summary_page_parameters(),
    responses:
      [
        ok:
          {"Provider management page", "application/json",
           ProviderSchemas.ref("ProviderSummaryPage")}
      ] ++
        SkoposWeb.API.Schemas.errors([
          :unauthorized,
          :forbidden,
          :unprocessable_entity,
          :internal_server_error
        ])

  operation :create,
    operation_id: "createProvider",
    summary: "Create a Provider",
    request_body:
      {"Provider", "application/json", ProviderSchemas.ref("CreateProviderRequest"),
       required: true},
    responses:
      [created: {"Provider created", "application/json", ProviderSchemas.ref("ProviderResponse")}] ++
        SkoposWeb.API.Schemas.errors([
          :bad_request,
          :unauthorized,
          :forbidden,
          :conflict,
          :unprocessable_entity,
          :internal_server_error
        ])

  operation :update,
    operation_id: "updateProvider",
    summary: "Update a Provider",
    parameters: SkoposWeb.API.Schemas.id_parameter(),
    request_body:
      {"Provider update", "application/json", ProviderSchemas.ref("UpdateProviderRequest"),
       required: true},
    responses:
      [ok: {"Provider updated", "application/json", ProviderSchemas.ref("ProviderResponse")}] ++
        SkoposWeb.API.Schemas.errors([
          :bad_request,
          :unauthorized,
          :forbidden,
          :not_found,
          :conflict,
          :unprocessable_entity,
          :internal_server_error
        ])

  operation :check,
    operation_id: "checkProvider",
    summary: "Check a Provider connection",
    parameters: SkoposWeb.API.Schemas.id_parameter(),
    request_body:
      {"Provider check", "application/json", ProviderSchemas.ref("CheckProviderRequest"),
       required: true},
    responses:
      [ok: {"Provider checked", "application/json", ProviderSchemas.ref("ProviderResponse")}] ++
        SkoposWeb.API.Schemas.errors([
          :bad_request,
          :unauthorized,
          :forbidden,
          :not_found,
          :conflict,
          :unprocessable_entity,
          :internal_server_error
        ])

  operation :delete,
    operation_id: "deleteAIProvider",
    summary: "Delete an AI connection and revoke its role assignments",
    parameters: SkoposWeb.API.Schemas.id_parameter(),
    request_body:
      {"Provider revision", "application/json", ProviderSchemas.ref("ProviderRevisionRequest"),
       required: true},
    responses:
      [no_content: {"AI connection deleted", nil, nil}] ++
        SkoposWeb.API.Schemas.errors([
          :bad_request,
          :unauthorized,
          :forbidden,
          :not_found,
          :conflict,
          :unprocessable_entity,
          :internal_server_error
        ])

  operation :configure_ai_usage,
    operation_id: "configureAIUsage",
    summary: "Set an AI connection's usage and selection priority",
    parameters: SkoposWeb.API.Schemas.id_parameter(),
    request_body:
      {"AI usage", "application/json", ProviderSchemas.ref("ConfigureAIUsageRequest"),
       required: true},
    responses:
      [no_content: {"AI usage configured", nil, nil}] ++
        SkoposWeb.API.Schemas.errors([
          :bad_request,
          :unauthorized,
          :forbidden,
          :not_found,
          :conflict,
          :unprocessable_entity,
          :internal_server_error
        ])

  operation :target_capabilities,
    operation_id: "getProviderTargetCapabilities",
    summary: "Get Target capabilities from a Provider",
    parameters: SkoposWeb.API.Schemas.id_parameter(),
    request_body:
      {"Method connection", "application/json", ProviderSchemas.ref("TargetCapabilitiesRequest"),
       required: true},
    responses:
      [
        ok:
          {"Target capabilities", "application/json",
           ProviderSchemas.ref("TargetCapabilitiesResponse")}
      ] ++
        SkoposWeb.API.Schemas.errors([
          :bad_request,
          :unauthorized,
          :forbidden,
          :not_found,
          :conflict,
          :unprocessable_entity,
          :internal_server_error
        ])

  operation :enable,
    operation_id: "enableProvider",
    summary: "Enable a checked Provider",
    parameters: SkoposWeb.API.Schemas.id_parameter(),
    request_body:
      {"Provider revision", "application/json", ProviderSchemas.ref("ProviderRevisionRequest"),
       required: true},
    responses:
      [ok: {"Provider enabled", "application/json", ProviderSchemas.ref("ProviderResponse")}] ++
        SkoposWeb.API.Schemas.errors([
          :bad_request,
          :unauthorized,
          :forbidden,
          :not_found,
          :conflict,
          :unprocessable_entity,
          :internal_server_error
        ])

  operation :disable,
    operation_id: "disableProvider",
    summary: "Disable a Provider",
    parameters: SkoposWeb.API.Schemas.id_parameter(),
    request_body:
      {"Provider revision", "application/json", ProviderSchemas.ref("ProviderRevisionRequest"),
       required: true},
    responses:
      [ok: {"Provider disabled", "application/json", ProviderSchemas.ref("ProviderResponse")}] ++
        SkoposWeb.API.Schemas.errors([
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
         {:ok, providers} <-
           Providers.page_providers(page: page, actor: conn.assigns.current_user) do
      Response.page(conn, providers, &ProviderJSON.data/1)
    end
  end

  def services(conn, _params), do: Response.data(conn, ReqLLM.services())

  def references(conn, params) do
    input = OpenApiSpex.params(conn) |> Map.take([:ids, :kind, :enabled, :adapter_types])

    with {:ok, page} <- Pagination.parse(params),
         {:ok, providers} <-
           Providers.page_provider_references(input, page: page, actor: conn.assigns.current_user) do
      Response.page(conn, providers, &ProviderJSON.reference/1)
    end
  end

  def show(conn, %{"id" => id}) do
    with {:ok, provider} <- Providers.get_active_provider(id, actor: conn.assigns.current_user) do
      Response.data(conn, ProviderJSON.data(provider))
    end
  end

  def summaries(conn, params) do
    input = OpenApiSpex.params(conn) |> Map.take([:ids, :kinds, :eligible])

    with {:ok, page} <- Pagination.parse(params),
         {:ok, providers} <-
           Providers.page_provider_summaries(input, page: page, actor: conn.assigns.current_user) do
      Response.page(conn, providers, &ProviderJSON.summary/1)
    end
  end

  def create(
        conn,
        %{
          "provider" =>
            %{
              "registration_id" => registration_id,
              "name" => name,
              "kind" => kind,
              "adapter_type" => adapter_type,
              "configuration" => configuration,
              "credentials" => credentials
            } = input
        }
      ) do
    usage =
      input
      |> Map.take(["usage_scope", "usage_priority"])
      |> Enum.into(%{}, fn {key, value} -> {String.to_existing_atom(key), value} end)

    with :ok <- validate_usage_kind(kind, usage),
         {:ok, provider} <-
           Providers.create_provider(
             name,
             kind,
             adapter_type,
             configuration,
             credentials,
             Map.put(usage, :registration_id, registration_id),
             actor: conn.assigns.current_user
           ) do
      Response.data(conn, ProviderJSON.data(provider), :created)
    end
  end

  def create(_conn, _params), do: {:error, :bad_request}

  def update(
        conn,
        %{"id" => id, "provider" => %{"expected_revision" => expected_revision} = input}
      ) do
    attrs = attributes(input, @update_fields)

    if map_size(attrs) == 0 do
      {:error, :bad_request}
    else
      with {:ok, provider} <- Providers.get_active_provider(id, actor: conn.assigns.current_user),
           {:ok, updated} <-
             Providers.update_provider(provider, expected_revision, attrs,
               actor: conn.assigns.current_user
             ) do
        Response.data(conn, ProviderJSON.data(updated))
      end
    end
  end

  def update(_conn, _params), do: {:error, :bad_request}

  def delete(conn, %{"id" => id, "provider" => %{"expected_revision" => revision}}) do
    with {:ok, _provider} <-
           Providers.retire_ai_provider(id, revision, actor: conn.assigns.current_user) do
      send_resp(conn, :no_content, "")
    end
  end

  def delete(_conn, _params), do: {:error, :bad_request}

  def configure_ai_usage(
        conn,
        %{
          "id" => id,
          "usage" => %{
            "scope" => scope,
            "priority" => priority,
            "expected_resolver_revision" => resolver_revision,
            "expected_reviewer_revision" => reviewer_revision
          }
        }
      ) do
    with {:ok, true} <-
           Providers.configure_ai_usage(
             id,
             scope,
             priority,
             resolver_revision,
             reviewer_revision,
             actor: conn.assigns.current_user
           ) do
      send_resp(conn, :no_content, "")
    end
  end

  def configure_ai_usage(_conn, _params), do: {:error, :bad_request}

  def check(
        conn,
        %{"id" => id, "provider" => %{"expected_revision" => expected_revision} = input}
      ) do
    with {:ok, provider} <-
           Providers.check_provider(
             id,
             expected_revision,
             Map.get(input, "check_input", %{}),
             actor: conn.assigns.current_user
           ) do
      Response.data(conn, ProviderJSON.data(provider))
    end
  end

  def check(_conn, _params), do: {:error, :bad_request}

  def target_capabilities(
        conn,
        %{
          "id" => id,
          "provider" => %{"expected_revision" => expected_revision, "endpoint" => endpoint}
        }
      ) do
    request = %Providers.Target.CapabilitiesRequest{
      provider_revision: expected_revision,
      connection: %Providers.Target.Connection{endpoint: endpoint}
    }

    with {:ok, capabilities} <-
           Providers.target_capabilities(id, request, %{}, actor: conn.assigns.current_user) do
      Response.data(conn, ProviderJSON.capabilities(capabilities))
    end
  end

  def target_capabilities(_conn, _params), do: {:error, :bad_request}

  def enable(conn, params), do: set_enabled(conn, params, :enable)
  def disable(conn, params), do: set_enabled(conn, params, :disable)

  defp set_enabled(
         conn,
         %{"id" => id, "provider" => %{"expected_revision" => expected_revision}},
         operation
       ) do
    with {:ok, provider} <- Providers.get_active_provider(id, actor: conn.assigns.current_user),
         {:ok, updated} <- change_enabled(provider, expected_revision, operation, conn) do
      Response.data(conn, ProviderJSON.data(updated))
    end
  end

  defp set_enabled(_conn, _params, _operation), do: {:error, :bad_request}

  defp change_enabled(provider, revision, :enable, conn),
    do: Providers.enable_provider(provider, revision, actor: conn.assigns.current_user)

  defp change_enabled(provider, revision, :disable, conn),
    do: Providers.disable_provider(provider, revision, actor: conn.assigns.current_user)

  defp validate_usage_kind("ai", _usage), do: :ok
  defp validate_usage_kind(_kind, usage) when map_size(usage) == 0, do: :ok

  defp validate_usage_kind(_kind, _usage), do: {:error, :bad_request}

  defp attributes(input, fields) do
    fields
    |> Enum.reduce(%{}, fn field, attrs ->
      case Map.fetch(input, field) do
        {:ok, value} -> Map.put(attrs, String.to_existing_atom(field), value)
        :error -> attrs
      end
    end)
  end
end
