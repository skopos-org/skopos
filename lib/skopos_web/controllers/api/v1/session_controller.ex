defmodule SkoposWeb.API.V1.SessionController do
  use SkoposWeb, :api_controller

  action_fallback SkoposWeb.API.FallbackController

  alias AshAuthentication.Plug.Helpers
  alias Skopos.Accounts
  alias SkoposWeb.API.Response
  alias SkoposWeb.API.V1.{AccountJSON, AccountSchemas}

  tags ["Sessions"]

  operation :create,
    operation_id: "createSession",
    summary: "Create a password session",
    security: [],
    request_body:
      {"Credentials", "application/json", AccountSchemas.ref("CreateSessionRequest"),
       required: true},
    responses:
      [created: {"Session created", "application/json", AccountSchemas.ref("SessionResponse")}] ++
        SkoposWeb.API.Schemas.errors([:bad_request, :unauthorized, :internal_server_error])

  operation :show,
    operation_id: "getCurrentSession",
    summary: "Get the current session",
    responses:
      [ok: {"Current session", "application/json", AccountSchemas.ref("CurrentSessionResponse")}] ++
        SkoposWeb.API.Schemas.errors([:unauthorized, :internal_server_error])

  operation :delete,
    operation_id: "deleteCurrentSession",
    summary: "Revoke the current session",
    responses:
      [no_content: {"Session revoked", nil, nil}] ++
        SkoposWeb.API.Schemas.errors([:unauthorized, :internal_server_error])

  def create(conn, %{"session" => %{"email" => email, "password" => password}}) do
    case Accounts.sign_in(email, password, authorize?: true) do
      {:ok, user} ->
        token = Ash.Resource.get_metadata(user, :token)

        conn
        |> put_resp_header("cache-control", "no-store")
        |> Response.data(%{token: token, account: AccountJSON.data(user)}, :created)

      {:error, _error} ->
        {:error, :invalid_credentials}
    end
  end

  def create(_conn, _params), do: {:error, :bad_request}

  def show(conn, _params) do
    Response.data(conn, %{account: AccountJSON.data(conn.assigns.current_user)})
  end

  def delete(conn, _params) do
    conn
    |> Helpers.revoke_bearer_tokens(:skopos)
    |> send_resp(:no_content, "")
  end
end
