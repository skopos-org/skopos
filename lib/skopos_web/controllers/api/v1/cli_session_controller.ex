defmodule SkoposWeb.API.V1.CLISessionController do
  use SkoposWeb, :api_controller

  action_fallback SkoposWeb.API.FallbackController

  alias Skopos.Accounts
  alias SkoposWeb.API.Response
  alias SkoposWeb.API.V1.{AccountJSON, AccountSchemas}
  alias SkoposWeb.PublicURL

  tags ["CLI sessions"]

  operation :create,
    operation_id: "createCLISessionRequest",
    summary: "Start a CLI browser session request",
    security: [],
    request_body:
      {"CLI session request", "application/json", AccountSchemas.ref("CreateCLISessionRequest"),
       required: true},
    responses:
      [
        created:
          {"CLI session request created", "application/json",
           AccountSchemas.ref("CLISessionRequestResponse")}
      ] ++
        SkoposWeb.API.Schemas.errors([
          :bad_request,
          :unprocessable_entity,
          :internal_server_error
        ])

  operation :approve,
    operation_id: "approveCLISessionRequest",
    summary: "Approve a CLI browser session request",
    parameters: SkoposWeb.API.Schemas.id_parameter(),
    request_body:
      {"CLI session approval", "application/json",
       AccountSchemas.ref("CLISessionDecisionRequest"), required: true},
    responses:
      [
        ok:
          {"CLI session request approved", "application/json",
           AccountSchemas.ref("CLISessionApprovalResponse")}
      ] ++
        SkoposWeb.API.Schemas.errors([
          :bad_request,
          :unauthorized,
          :forbidden,
          :unprocessable_entity,
          :internal_server_error
        ])

  operation :deny,
    operation_id: "denyCLISessionRequest",
    summary: "Deny a CLI browser session request",
    parameters: SkoposWeb.API.Schemas.id_parameter(),
    request_body:
      {"CLI session denial", "application/json", AccountSchemas.ref("CLISessionDecisionRequest"),
       required: true},
    responses:
      [
        ok:
          {"CLI session request denied", "application/json",
           AccountSchemas.ref("CLISessionDenialResponse")}
      ] ++
        SkoposWeb.API.Schemas.errors([
          :bad_request,
          :unauthorized,
          :forbidden,
          :unprocessable_entity,
          :internal_server_error
        ])

  operation :exchange,
    operation_id: "exchangeCLISessionRequest",
    summary: "Exchange an approved CLI browser grant",
    security: [],
    parameters: SkoposWeb.API.Schemas.id_parameter(),
    request_body:
      {"CLI session exchange", "application/json",
       AccountSchemas.ref("ExchangeCLISessionRequest"), required: true},
    responses:
      [
        created:
          {"CLI session created", "application/json",
           AccountSchemas.ref("ExchangeCLISessionResponse")}
      ] ++
        SkoposWeb.API.Schemas.errors([
          :bad_request,
          :unauthorized,
          :unprocessable_entity,
          :internal_server_error
        ])

  def create(
        conn,
        %{
          "request" => %{
            "redirect_uri" => redirect_uri,
            "code_challenge" => code_challenge
          }
        }
      ) do
    with {:ok, %{request: request, start_token: start_token}} <-
           Accounts.request_cli_login(redirect_uri, code_challenge) do
      conn
      |> put_resp_header("cache-control", "no-store")
      |> Response.data(
        %{
          id: request.id,
          authorization_url:
            PublicURL.url("/cli-login/#{request.id}#token=#{URI.encode_www_form(start_token)}"),
          expires_at: request.expires_at
        },
        :created
      )
    else
      _error -> {:error, :bad_request}
    end
  end

  def create(_conn, _params), do: {:error, :bad_request}

  def approve(
        conn,
        %{"id" => id, "request" => %{"start_token" => start_token}}
      ) do
    with {:ok, %{request: request, code: code, user: user}} <-
           Accounts.approve_cli_login(id, start_token, actor: conn.assigns.current_user) do
      conn
      |> put_resp_header("cache-control", "no-store")
      |> Response.data(%{
        redirect_uri: append_query(request.redirect_uri, %{request_id: request.id, code: code}),
        account: AccountJSON.data(user)
      })
    else
      _error -> {:error, :invalid_credentials}
    end
  end

  def approve(_conn, _params), do: {:error, :bad_request}

  def deny(conn, %{"id" => id, "request" => %{"start_token" => start_token}}) do
    with {:ok, request} <-
           Accounts.deny_cli_login(id, start_token, actor: conn.assigns.current_user) do
      conn
      |> put_resp_header("cache-control", "no-store")
      |> Response.data(%{
        redirect_uri:
          append_query(request.redirect_uri, %{
            request_id: request.id,
            error: "access_denied"
          })
      })
    else
      _error -> {:error, :invalid_credentials}
    end
  end

  def deny(_conn, _params), do: {:error, :bad_request}

  def exchange(
        conn,
        %{"id" => id, "request" => %{"code" => code, "verifier" => verifier}}
      ) do
    with {:ok, %{token: token, user: user}} <-
           Accounts.exchange_cli_login(id, code, verifier) do
      conn
      |> put_resp_header("cache-control", "no-store")
      |> Response.data(%{token: token, account: AccountJSON.data(user)}, :created)
    else
      _error -> {:error, :invalid_credentials}
    end
  end

  def exchange(_conn, _params), do: {:error, :bad_request}

  defp append_query(uri, values) do
    parsed = URI.parse(uri)

    query =
      values
      |> Enum.into(%{}, fn {key, value} -> {to_string(key), to_string(value)} end)
      |> URI.encode_query()

    to_string(%URI{parsed | query: query})
  end
end
