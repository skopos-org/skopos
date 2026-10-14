defmodule SkoposWeb.API.V1.ContractControllerTest do
  use SkoposWeb.ConnCase, async: false

  alias Skopos.{Accounts, Cases}

  @password "correct horse battery staple"
  @uuid "00000000-0000-0000-0000-000000000000"

  @required_routes [
    {:get, "/api/v1/openapi.json"},
    {:post, "/api/v1/accounts/bootstrap"},
    {:post, "/api/v1/sessions"},
    {:get, "/api/v1/oidc"},
    {:post, "/api/v1/cli/session-requests"},
    {:post, "/api/v1/cli/session-requests/:id/exchange"},
    {:get, "/api/v1/session"},
    {:delete, "/api/v1/session"},
    {:get, "/api/v1/accounts"},
    {:post, "/api/v1/accounts"},
    {:patch, "/api/v1/accounts/:id/role"},
    {:patch, "/api/v1/account/language"},
    {:get, "/api/v1/oidc/provider"},
    {:put, "/api/v1/oidc/provider"},
    {:post, "/api/v1/oidc/link-requests"},
    {:post, "/api/v1/cli/session-requests/:id/approve"},
    {:post, "/api/v1/cli/session-requests/:id/deny"},
    {:get, "/api/v1/providers"},
    {:post, "/api/v1/providers"},
    {:get, "/api/v1/providers/:id"},
    {:patch, "/api/v1/providers/:id"},
    {:put, "/api/v1/providers/:id/ai-usage"},
    {:post, "/api/v1/providers/:id/check"},
    {:post, "/api/v1/providers/:id/target-capabilities"},
    {:post, "/api/v1/providers/:id/enable"},
    {:post, "/api/v1/providers/:id/disable"},
    {:get, "/api/v1/ai-usage-role-assignments"},
    {:get, "/api/v1/management-boundaries"},
    {:post, "/api/v1/management-boundaries"},
    {:patch, "/api/v1/management-boundaries/:id"},
    {:post, "/api/v1/management-boundaries/:id/deactivate"},
    {:get, "/api/v1/targets"},
    {:post, "/api/v1/targets"},
    {:get, "/api/v1/targets/:id"},
    {:patch, "/api/v1/targets/:id"},
    {:post, "/api/v1/targets/:id/deactivate"},
    {:get, "/api/v1/external-identities"},
    {:post, "/api/v1/external-identities"},
    {:patch, "/api/v1/external-identities/:id"},
    {:post, "/api/v1/external-identities/:id/deactivate"},
    {:get, "/api/v1/access-methods"},
    {:post, "/api/v1/access-methods"},
    {:patch, "/api/v1/access-methods/:id"},
    {:post, "/api/v1/access-methods/:id/deactivate"},
    {:get, "/api/v1/target-relationships"},
    {:post, "/api/v1/target-relationships"},
    {:patch, "/api/v1/target-relationships/:id"},
    {:post, "/api/v1/target-relationships/:id/deactivate"},
    {:get, "/api/v1/inventory-imports"},
    {:post, "/api/v1/inventory-imports/manual-preview"},
    {:post, "/api/v1/inventory-imports/provider-preview"},
    {:get, "/api/v1/inventory-imports/:id"},
    {:get, "/api/v1/inventory-imports/:id/rows"},
    {:post, "/api/v1/inventory-imports/:id/apply"},
    {:get, "/api/v1/authority-settings"},
    {:get, "/api/v1/authority-setting"},
    {:put, "/api/v1/authority-setting"},
    {:get, "/api/v1/cases"},
    {:post, "/api/v1/cases"},
    {:get, "/api/v1/cases/:id"},
    {:get, "/api/v1/cases/:id/timeline"},
    {:get, "/api/v1/cases/:id/turns"},
    {:get, "/api/v1/cases/:id/evidence"},
    {:get, "/api/v1/cases/:id/approvals"},
    {:get, "/api/v1/cases/:id/review-decisions"},
    {:post, "/api/v1/cases/:id/claim"},
    {:post, "/api/v1/cases/:id/split"},
    {:post, "/api/v1/cases/:id/handoff"},
    {:post, "/api/v1/cases/:id/cancel"},
    {:post, "/api/v1/cases/:id/resume"},
    {:get, "/api/v1/proposals/:id"},
    {:post, "/api/v1/proposals/:id/decision"},
    {:get, "/api/v1/operations/:id"},
    {:get, "/api/v1/verification-attempts/:id"},
    {:post, "/api/v1/signals/alertmanager/:provider_id"},
    {:post, "/api/v1/signals/generic/:provider_id"},
    {:post, "/api/v1/signals/zabbix/:provider_id"},
    {:get, "/api/v1/signal-receipts"},
    {:get, "/api/v1/signal-receipts/:id"},
    {:get, "/api/v1/signal-receipts/:id/events"},
    {:get, "/api/v1/audit-schedules"},
    {:post, "/api/v1/audit-schedules"},
    {:get, "/api/v1/audit-schedules/:id"},
    {:post, "/api/v1/audit-schedules/:id/deactivate"},
    {:get, "/api/v1/audit-runs"},
    {:get, "/api/v1/audit-runs/:id"},
    {:get, "/api/v1/reports"},
    {:get, "/api/v1/report-setting"},
    {:put, "/api/v1/report-setting"},
    {:get, "/api/v1/reports/:id"},
    {:post, "/api/v1/cases/:case_id/reports"},
    {:get, "/api/v1/deliveries"},
    {:post, "/api/v1/deliveries"},
    {:get, "/api/v1/deliveries/:id"}
  ]

  test "the versioned router exposes every mandatory client capability" do
    actual =
      SkoposWeb.Router
      |> Phoenix.Router.routes()
      |> Enum.map(&{&1.verb, &1.path})
      |> MapSet.new()

    missing = @required_routes |> MapSet.new() |> MapSet.difference(actual)
    assert missing == MapSet.new()

    refute Enum.any?(actual, fn
             {_verb, "/api/" <> rest} -> not String.starts_with?(rest, "v1/")
             _route -> false
           end)
  end

  test "every management route rejects a missing bearer credential with one error contract" do
    protected_routes()
    |> Enum.each(fn route ->
      response = request(route.verb, concrete_path(route.path), %{}, nil)

      assert %{
               "error" => %{
                 "code" => "unauthenticated",
                 "message" => message,
                 "request_id" => request_id
               }
             } = json_response(response, 401)

      assert is_binary(message)
      assert is_binary(request_id)
    end)
  end

  test "all collection reads use the shared cursor envelope for a fresh client" do
    admin =
      Accounts.bootstrap!("contract-admin@example.com", @password, @password, authorize?: true)

    operator =
      Accounts.create_user!("contract-operator@example.com", @password, :operator, actor: admin)

    viewer =
      Accounts.create_user!("contract-viewer@example.com", @password, :viewer, actor: admin)

    viewer_token = token!(viewer.email)

    incident =
      Cases.open_case!(
        :manual,
        "api-contract",
        "cursor-envelope",
        "Verify API collection contracts",
        :info,
        %{"desired_outcome" => "Target responds as expected"},
        nil,
        :en,
        actor: operator
      )

    global_collections = [
      "/api/v1/accounts",
      "/api/v1/providers",
      "/api/v1/ai-usage-role-assignments",
      "/api/v1/management-boundaries",
      "/api/v1/targets",
      "/api/v1/external-identities",
      "/api/v1/access-methods",
      "/api/v1/target-relationships",
      "/api/v1/inventory-imports",
      "/api/v1/authority-settings",
      "/api/v1/cases",
      "/api/v1/signal-receipts",
      "/api/v1/audit-schedules",
      "/api/v1/audit-runs",
      "/api/v1/reports",
      "/api/v1/deliveries"
    ]

    case_collections =
      Enum.map(~w(timeline turns evidence approvals review-decisions), fn collection ->
        "/api/v1/cases/#{incident.id}/#{collection}"
      end)

    Enum.each(global_collections ++ case_collections, fn path ->
      response = request(:get, path <> "?limit=1", nil, viewer_token)
      assert %{"data" => data, "page" => %{"next" => next}} = json_response(response, 200)
      assert is_list(data)
      assert is_nil(next) or is_binary(next)
    end)

    assert %{
             "error" => %{
               "code" => "invalid_pagination",
               "message" => "Pagination input is invalid",
               "request_id" => request_id
             }
           } =
             request(:get, "/api/v1/cases?limit=0", nil, viewer_token)
             |> json_response(422)

    assert is_binary(request_id)

    assert %{"error" => %{"code" => "invalid_pagination"}} =
             request(:get, "/api/v1/cases?after=not-a-keyset", nil, viewer_token)
             |> json_response(422)
  end

  defp protected_routes do
    SkoposWeb.Router
    |> Phoenix.Router.routes()
    |> Enum.filter(fn route ->
      String.starts_with?(route.path, "/api/v1") and
        route.plug not in [SkoposWeb.APIErrorController, SkoposWeb.SignalWebhookController] and
        {route.verb, route.path} not in [
          {:get, "/api/v1/openapi.json"},
          {:post, "/api/v1/accounts/bootstrap"},
          {:post, "/api/v1/sessions"},
          {:get, "/api/v1/oidc"},
          {:post, "/api/v1/cli/session-requests"},
          {:post, "/api/v1/cli/session-requests/:id/exchange"}
        ]
    end)
  end

  defp concrete_path(path) do
    Regex.replace(~r/:[a-z_]+/, path, @uuid)
  end

  defp token!(email) do
    request(
      :post,
      "/api/v1/sessions",
      %{"session" => %{"email" => to_string(email), "password" => @password}},
      nil
    )
    |> json_response(201)
    |> get_in(["data", "token"])
  end

  defp request(method, path, body, token) do
    build_json_conn(body)
    |> maybe_authorize(token)
    |> dispatch_request(method, path, body)
  end

  defp maybe_authorize(conn, nil), do: conn
  defp maybe_authorize(conn, token), do: put_req_header(conn, "authorization", "Bearer " <> token)

  defp dispatch_request(conn, :get, path, _body), do: get(conn, path)
  defp dispatch_request(conn, :post, path, body), do: post(conn, path, body)
  defp dispatch_request(conn, :patch, path, body), do: patch(conn, path, body)
  defp dispatch_request(conn, :put, path, body), do: put(conn, path, body)
  defp dispatch_request(conn, :delete, path, _body), do: delete(conn, path)
end
