defmodule SkoposWeb.API.V1.AccountSessionControllerTest do
  use SkoposWeb.ConnCase, async: false

  import OpenApiSpex.TestAssertions

  alias Skopos.Accounts

  @password "correct horse battery staple"

  test "bootstrap and password Session use the stored revocable bearer token" do
    bootstrap =
      post_json("/api/v1/accounts/bootstrap", %{
        "account" => %{
          "email" => "api-admin@example.com",
          "password" => @password,
          "password_confirmation" => @password
        }
      })

    assert %{
             "data" => %{
               "id" => admin_id,
               "email" => "api-admin@example.com",
               "role" => "admin",
               "role_version" => 1,
               "preferred_language" => "en"
             }
           } = json_response(bootstrap, 201)

    assert_operation_response(bootstrap)

    refute bootstrap.resp_body =~ @password
    refute bootstrap.resp_body =~ "hashed_password"

    session = sign_in("api-admin@example.com", @password)

    assert %{"data" => %{"token" => token, "account" => %{"id" => ^admin_id}}} =
             json_response(session, 201)

    assert_operation_response(session)

    assert is_binary(token)
    assert get_resp_header(session, "cache-control") == ["no-store"]

    current = get_json("/api/v1/session", token)

    assert %{"data" => %{"account" => %{"id" => ^admin_id, "role" => "admin"}}} =
             json_response(current, 200)

    assert_operation_response(current)

    assert is_binary(current_request_id(current))

    language =
      patch_json(
        "/api/v1/account/language",
        %{"account" => %{"preferred_language" => "ja"}},
        token
      )

    assert %{"data" => %{"id" => ^admin_id, "preferred_language" => "ja"}} =
             json_response(language, 200)

    assert_operation_response(language)

    persisted = get_json("/api/v1/session", token)

    assert %{"data" => %{"account" => %{"preferred_language" => "ja"}}} =
             json_response(persisted, 200)

    logout = delete_json("/api/v1/session", token)
    assert response(logout, 204) == ""
    assert_operation_response(logout)

    assert %{"error" => %{"code" => "unauthenticated"}} =
             get_json("/api/v1/session", token) |> json_response(401)
  end

  test "missing account and wrong password return the same credential error" do
    bootstrap_admin!()

    missing = sign_in("missing@example.com", "wrong password")
    wrong = sign_in("api-admin@example.com", "wrong password")

    assert json_response(missing, 401) |> error_without_request_id() ==
             json_response(wrong, 401) |> error_without_request_id()

    assert %{
             "error" => %{
               "code" => "invalid_credentials",
               "message" => "Email or password is invalid",
               "request_id" => request_id
             }
           } = json_response(wrong, 401)

    assert is_binary(request_id)
    refute wrong.resp_body =~ "wrong password"
    refute wrong.resp_body =~ "missing@example.com"
  end

  test "missing, invalid and expired bearer credentials are indistinguishable" do
    bootstrap_admin!()
    user = Accounts.sign_in!("api-admin@example.com", @password, authorize?: true)

    {:ok, expired_token, _claims} =
      AshAuthentication.Jwt.token_for_user(
        user,
        %{"purpose" => "user"},
        token_lifetime: -1
      )

    responses = [
      get_json("/api/v1/session", nil),
      get_json("/api/v1/session", "invalid-token"),
      get_json("/api/v1/session", expired_token)
    ]

    assert Enum.all?(responses, fn conn ->
             match?(%{"error" => %{"code" => "unauthenticated"}}, json_response(conn, 401))
           end)

    assert responses
           |> Enum.map(&json_response(&1, 401))
           |> Enum.map(&error_without_request_id/1)
           |> Enum.uniq()
           |> length() == 1
  end

  test "administrator manages Accounts with cursor pagination and role revocation" do
    bootstrap_admin!()
    admin_token = token!(sign_in("api-admin@example.com", @password))

    operator =
      post_json(
        "/api/v1/accounts",
        %{
          "account" => %{
            "email" => "api-operator@example.com",
            "password" => @password,
            "role" => "operator"
          }
        },
        admin_token
      )

    assert %{"data" => %{"id" => operator_id, "role" => "operator"}} =
             json_response(operator, 201)

    _viewer =
      post_json(
        "/api/v1/accounts",
        %{
          "account" => %{
            "email" => "api-viewer@example.com",
            "password" => @password,
            "role" => "viewer"
          }
        },
        admin_token
      )
      |> json_response(201)

    first_page = get_json("/api/v1/accounts?limit=2", admin_token)

    assert %{"data" => first_accounts, "page" => %{"next" => cursor}} =
             json_response(first_page, 200)

    assert length(first_accounts) == 2
    assert is_binary(cursor)
    refute first_page.resp_body =~ "hashed_password"
    refute first_page.resp_body =~ @password

    second_page =
      get_json("/api/v1/accounts?limit=2&after=#{URI.encode_www_form(cursor)}", admin_token)

    assert %{"data" => [_last_account], "page" => %{"next" => nil}} =
             json_response(second_page, 200)

    operator_token = token!(sign_in("api-operator@example.com", @password))

    changed =
      patch_json(
        "/api/v1/accounts/#{operator_id}/role",
        %{"account" => %{"role" => "viewer"}},
        admin_token
      )

    assert %{"data" => %{"id" => ^operator_id, "role" => "viewer", "role_version" => 2}} =
             json_response(changed, 200)

    assert %{"error" => %{"code" => "unauthenticated"}} =
             get_json("/api/v1/session", operator_token) |> json_response(401)
  end

  test "authorization, conflict, not-found and malformed input use stable errors" do
    bootstrap_admin!()
    admin_token = token!(sign_in("api-admin@example.com", @password))

    duplicate_bootstrap =
      post_json("/api/v1/accounts/bootstrap", %{
        "account" => %{
          "email" => "second-admin@example.com",
          "password" => @password,
          "password_confirmation" => @password
        }
      })

    assert %{"error" => %{"code" => "conflict"}} = json_response(duplicate_bootstrap, 409)

    operator =
      post_json(
        "/api/v1/accounts",
        %{
          "account" => %{
            "email" => "restricted-operator@example.com",
            "password" => @password,
            "role" => "operator"
          }
        },
        admin_token
      )

    operator_id = json_response(operator, 201)["data"]["id"]
    operator_token = token!(sign_in("restricted-operator@example.com", @password))

    viewer =
      post_json(
        "/api/v1/accounts",
        %{
          "account" => %{
            "email" => "restricted-viewer@example.com",
            "password" => @password,
            "role" => "viewer"
          }
        },
        admin_token
      )

    viewer_id = json_response(viewer, 201)["data"]["id"]
    viewer_token = token!(sign_in("restricted-viewer@example.com", @password))

    forbidden =
      post_json(
        "/api/v1/accounts",
        %{
          "account" => %{
            "email" => "forbidden@example.com",
            "password" => @password,
            "role" => "viewer"
          }
        },
        operator_token
      )

    assert %{"error" => %{"code" => "forbidden"}} = json_response(forbidden, 403)
    refute forbidden.resp_body =~ @password

    assert %{"data" => [%{"id" => ^viewer_id}]} =
             get_json("/api/v1/accounts", viewer_token) |> json_response(200)

    viewer_forbidden =
      post_json(
        "/api/v1/accounts",
        %{
          "account" => %{
            "email" => "viewer-forbidden@example.com",
            "password" => @password,
            "role" => "viewer"
          }
        },
        viewer_token
      )

    assert %{"error" => %{"code" => "forbidden"}} = json_response(viewer_forbidden, 403)

    not_found =
      patch_json(
        "/api/v1/accounts/00000000-0000-0000-0000-000000000000/role",
        %{"account" => %{"role" => "viewer"}},
        admin_token
      )

    assert %{"error" => %{"code" => "not_found"}} = json_response(not_found, 404)

    bad_body = post_json("/api/v1/accounts", %{}, admin_token)
    assert %{"error" => %{"code" => "bad_request"}} = json_response(bad_body, 400)

    invalid_role =
      post_json(
        "/api/v1/accounts",
        %{
          "account" => %{
            "email" => "invalid-role@example.com",
            "password" => @password,
            "role" => "owner"
          }
        },
        admin_token
      )

    assert %{
             "error" => %{
               "code" => "validation_failed",
               "details" => %{"fields" => ["role"]}
             }
           } = json_response(invalid_role, 422)

    assert_operation_response(invalid_role)

    invalid_cursor = get_json("/api/v1/accounts?after=not-a-keyset", admin_token)

    assert %{"error" => %{"code" => "invalid_pagination"}} =
             json_response(invalid_cursor, 422)

    own_account = get_json("/api/v1/session", operator_token)
    assert %{"data" => %{"account" => %{"id" => ^operator_id}}} = json_response(own_account, 200)
  end

  @tag account_filters: true
  test "account identity and eligible-role filters apply before paging and retain changed owners" do
    bootstrap = bootstrap_admin!()
    admin_id = bootstrap["data"]["id"]
    token = token!(sign_in("api-admin@example.com", @password))

    accounts =
      for {name, role} <- [{"reader", "viewer"}, {"owner", "operator"}, {"peer", "operator"}] do
        post_json(
          "/api/v1/accounts",
          %{
            "account" => %{
              "email" => "#{name}@example.com",
              "password" => @password,
              "role" => role
            }
          },
          token
        )
        |> json_response(201)
        |> Map.fetch!("data")
      end

    [viewer, owner, peer] = accounts
    path = "/api/v1/accounts?roles=operator,admin&limit=2"
    first = get_json(path, token)
    assert_operation_response(first)

    assert %{"data" => [%{"id" => ^admin_id}, %{"id" => owner_id}], "page" => %{"next" => cursor}} =
             json_response(first, 200)

    assert owner_id == owner["id"]
    assert is_binary(cursor)
    tail = get_json(path <> "&after=" <> URI.encode_www_form(cursor), token)
    assert_operation_response(tail)

    assert %{"data" => [%{"id" => peer_id}], "page" => %{"next" => nil}} =
             json_response(tail, 200)

    assert peer_id == peer["id"]

    known = get_json("/api/v1/accounts?ids=#{owner_id}&limit=1", token)
    assert [%{"id" => ^owner_id, "role" => "operator"}] = json_response(known, 200)["data"]

    patch_json("/api/v1/accounts/#{owner_id}/role", %{"account" => %{"role" => "viewer"}}, token)
    |> json_response(200)

    changed = get_json("/api/v1/accounts?ids=#{owner_id}&limit=1", token)
    assert_operation_response(changed)

    assert [%{"id" => ^owner_id, "role" => "viewer", "role_version" => 2} = row] =
             json_response(changed, 200)["data"]

    assert Enum.sort(Map.keys(row)) ==
             ~w(email id inserted_at preferred_language role role_version updated_at)

    assert [] =
             get_json("/api/v1/accounts?ids=#{owner_id}&roles=operator,admin", token)
             |> json_response(200)
             |> Map.fetch!("data")

    viewer_token = token!(sign_in(viewer["email"], @password))
    restricted = get_json("/api/v1/accounts?ids=#{viewer["id"]},#{peer_id}", viewer_token)
    assert [%{"id" => viewer_id}] = json_response(restricted, 200)["data"]
    assert viewer_id == viewer["id"]

    assert [] =
             get_json("/api/v1/accounts?ids=#{peer_id}", viewer_token)
             |> json_response(200)
             |> Map.fetch!("data")

    assert [] =
             get_json("/api/v1/accounts?ids=#{Ecto.UUID.generate()}", token)
             |> json_response(200)
             |> Map.fetch!("data")
  end

  @tag account_filters: true
  test "account filters are bounded, validate roles and retain authenticated self-only reads" do
    bootstrap_admin!()
    token = token!(sign_in("api-admin@example.com", @password))
    path = "/api/v1/accounts"
    assert response(get_json(path <> "?roles=admin", nil), 401)

    for query <- [
          "ids=not-a-uuid",
          "ids=",
          "ids=" <> Enum.map_join(1..101, ",", fn _ -> Ecto.UUID.generate() end),
          "roles=owner",
          "roles=",
          "roles=admin,operator,viewer,admin"
        ] do
      response = get_json(path <> "?" <> query, token)
      assert %{"error" => %{"code" => "validation_failed"}} = json_response(response, 422)
    end

    ids = for _ <- 1..100, do: Ecto.UUID.generate()

    response =
      get_json(path <> "?ids=" <> Enum.join(ids, ",") <> "&roles=admin,operator,viewer", token)

    assert_operation_response(response)
    assert [] = json_response(response, 200)["data"]

    actor = Accounts.sign_in!("api-admin@example.com", @password, authorize?: true)

    assert {:ok, %{results: []}} =
             Accounts.list_users(%{ids: ids, roles: [:admin, :operator, :viewer]}, actor: actor)

    for filters <- [
          %{ids: [Ecto.UUID.generate() | ids]},
          %{ids: ["not-a-uuid"]},
          %{roles: [:owner]},
          %{roles: [:admin, :operator, :viewer, :admin]}
        ] do
      assert {:error, %Ash.Error.Invalid{}} = Accounts.list_users(filters, actor: actor)
    end

    operator =
      Accounts.create_user!("self-operator@example.com", @password, :operator, actor: actor)

    operator_token = token!(sign_in(to_string(operator.email), @password))
    scoped = get_json(path <> "?roles=admin,operator", operator_token)
    assert [%{"id" => operator_id}] = json_response(scoped, 200)["data"]
    assert operator_id == operator.id

    assert [] =
             get_json(path <> "?ids=#{actor.id}", operator_token)
             |> json_response(200)
             |> Map.fetch!("data")
  end

  defp bootstrap_admin! do
    post_json("/api/v1/accounts/bootstrap", %{
      "account" => %{
        "email" => "api-admin@example.com",
        "password" => @password,
        "password_confirmation" => @password
      }
    })
    |> json_response(201)
  end

  defp sign_in(email, password) do
    post_json("/api/v1/sessions", %{
      "session" => %{"email" => email, "password" => password}
    })
  end

  defp token!(conn), do: json_response(conn, 201)["data"]["token"]

  defp post_json(path, body, token \\ nil), do: request(:post, path, body, token)
  defp patch_json(path, body, token), do: request(:patch, path, body, token)
  defp get_json(path, token), do: request(:get, path, nil, token)
  defp delete_json(path, token), do: request(:delete, path, nil, token)

  defp request(method, path, body, token) do
    build_json_conn(body)
    |> maybe_authorize(token)
    |> dispatch_request(method, path, body)
  end

  defp dispatch_request(conn, :get, path, _body), do: get(conn, path)
  defp dispatch_request(conn, :delete, path, _body), do: delete(conn, path)
  defp dispatch_request(conn, :post, path, body), do: post(conn, path, body)
  defp dispatch_request(conn, :patch, path, body), do: patch(conn, path, body)

  defp maybe_authorize(conn, nil), do: conn

  defp maybe_authorize(conn, token),
    do: put_req_header(conn, "authorization", "Bearer " <> token)

  defp current_request_id(conn) do
    conn |> get_resp_header("x-request-id") |> List.first()
  end

  defp error_without_request_id(%{"error" => error}) do
    %{"error" => Map.delete(error, "request_id")}
  end
end
