defmodule SkoposWeb.API.V1.AccountController do
  use SkoposWeb, :api_controller

  action_fallback SkoposWeb.API.FallbackController

  alias Skopos.Accounts
  alias SkoposWeb.API.{Pagination, Response}
  alias SkoposWeb.API.V1.{AccountJSON, AccountSchemas}

  tags ["Accounts"]

  operation :bootstrap,
    operation_id: "bootstrapAccount",
    summary: "Create the initial administrator",
    security: [],
    request_body:
      {"Initial administrator", "application/json", AccountSchemas.ref("BootstrapAccountRequest"),
       required: true},
    responses:
      [
        created:
          {"Administrator created", "application/json", AccountSchemas.ref("AccountResponse")}
      ] ++
        SkoposWeb.API.Schemas.errors([
          :bad_request,
          :conflict,
          :unprocessable_entity,
          :internal_server_error
        ])

  operation :index,
    operation_id: "listAccounts",
    summary: "List accounts",
    parameters: AccountSchemas.page_parameters(),
    responses:
      [ok: {"Account page", "application/json", AccountSchemas.ref("AccountPage")}] ++
        SkoposWeb.API.Schemas.errors([
          :unauthorized,
          :forbidden,
          :unprocessable_entity,
          :internal_server_error
        ])

  operation :create,
    operation_id: "createAccount",
    summary: "Create an account",
    request_body:
      {"Account", "application/json", AccountSchemas.ref("CreateAccountRequest"), required: true},
    responses:
      [created: {"Account created", "application/json", AccountSchemas.ref("AccountResponse")}] ++
        SkoposWeb.API.Schemas.errors([
          :bad_request,
          :unauthorized,
          :forbidden,
          :conflict,
          :unprocessable_entity,
          :internal_server_error
        ])

  operation :update_role,
    operation_id: "updateAccountRole",
    summary: "Update an account role",
    parameters: SkoposWeb.API.Schemas.id_parameter(),
    request_body:
      {"Role update", "application/json", AccountSchemas.ref("UpdateAccountRoleRequest"),
       required: true},
    responses:
      [ok: {"Account updated", "application/json", AccountSchemas.ref("AccountResponse")}] ++
        SkoposWeb.API.Schemas.errors([
          :bad_request,
          :unauthorized,
          :forbidden,
          :not_found,
          :unprocessable_entity,
          :internal_server_error
        ])

  operation :update_language,
    operation_id: "updatePreferredLanguage",
    summary: "Update the current account language",
    request_body:
      {"Language update", "application/json", AccountSchemas.ref("UpdateAccountLanguageRequest"),
       required: true},
    responses:
      [ok: {"Account updated", "application/json", AccountSchemas.ref("AccountResponse")}] ++
        SkoposWeb.API.Schemas.errors([
          :bad_request,
          :unauthorized,
          :forbidden,
          :unprocessable_entity,
          :internal_server_error
        ])

  def bootstrap(
        conn,
        %{
          "account" => %{
            "email" => email,
            "password" => password,
            "password_confirmation" => confirmation
          }
        }
      ) do
    with {:ok, user} <- Accounts.bootstrap(email, password, confirmation, authorize?: true) do
      Response.data(conn, AccountJSON.data(user), :created)
    end
  end

  def bootstrap(_conn, _params), do: {:error, :bad_request}

  def index(conn, params) do
    filters = OpenApiSpex.params(conn) |> Map.take([:ids, :roles])

    with {:ok, page} <- Pagination.parse(params),
         {:ok, users} <-
           Accounts.list_users(filters, page: page, actor: conn.assigns.current_user) do
      Response.page(conn, users, &AccountJSON.data/1)
    end
  end

  def create(
        conn,
        %{"account" => %{"email" => email, "password" => password, "role" => role}}
      ) do
    with {:ok, user} <-
           Accounts.create_user(email, password, role, actor: conn.assigns.current_user) do
      Response.data(conn, AccountJSON.data(user), :created)
    end
  end

  def create(_conn, _params), do: {:error, :bad_request}

  def update_role(conn, %{"id" => id, "account" => %{"role" => role}}) do
    with {:ok, user} <- Accounts.get_user(id, actor: conn.assigns.current_user),
         {:ok, updated} <- Accounts.change_role(user, role, actor: conn.assigns.current_user) do
      Response.data(conn, AccountJSON.data(updated))
    end
  end

  def update_role(_conn, _params), do: {:error, :bad_request}

  def update_language(conn, %{"account" => %{"preferred_language" => language}}) do
    with {:ok, updated} <-
           Accounts.change_preferred_language(
             conn.assigns.current_user,
             language,
             actor: conn.assigns.current_user
           ) do
      Response.data(conn, AccountJSON.data(updated))
    end
  end

  def update_language(_conn, _params), do: {:error, :bad_request}
end
