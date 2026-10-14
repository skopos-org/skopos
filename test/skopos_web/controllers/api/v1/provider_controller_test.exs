defmodule SkoposWeb.API.V1.ProviderControllerTest do
  use SkoposWeb.ConnCase, async: false

  import OpenApiSpex.TestAssertions
  import ExUnit.CaptureLog

  alias Skopos.{Accounts, Cases, Providers, Targets}

  @password "correct horse battery staple"

  setup do
    admin =
      Accounts.bootstrap!("provider-api-admin@example.com", @password, @password,
        authorize?: true
      )

    operator =
      Accounts.create_user!("provider-api-operator@example.com", @password, :operator,
        actor: admin
      )

    viewer =
      Accounts.create_user!("provider-api-viewer@example.com", @password, :viewer, actor: admin)

    %{
      admin: admin,
      admin_token: token!(admin.email),
      operator_token: token!(operator.email),
      viewer_token: token!(viewer.email)
    }
  end

  @tag setup_readiness: true
  test "setup readiness uses global current connections and independent AI roles", context do
    path = "/api/v1/authority-setting/readiness"
    empty = get_json(path, context.viewer_token)

    assert %{"data" => %{"complete" => false, "reviewer" => false, "target" => false}} =
             json_response(empty, 200)

    assert_operation_response(empty)

    for n <- 1..51 do
      Providers.create_provider!(
        "Unchecked AI #{n}",
        :ai,
        "fixture-ai",
        %{"model" => "fixture"},
        %{"api_key" => "private"},
        actor: context.admin
      )
    end

    ai =
      Providers.create_provider!(
        "Ready AI",
        :ai,
        "fixture-ai",
        %{"model" => "fixture"},
        %{"api_key" => "private"},
        actor: context.admin
      )
      |> then(&Providers.check_provider!(&1.id, 1, %{}, actor: context.admin))
      |> then(&Providers.enable_provider!(&1, 1, actor: context.admin))

    roles =
      Providers.list_ai_usage_role_assignments!(actor: context.admin)
      |> Enum.filter(&(&1.provider_id == ai.id))

    resolver = Enum.find(roles, &(&1.role == :resolver))
    reviewer = Enum.find(roles, &(&1.role == :reviewer))

    Providers.configure_ai_usage!(ai.id, :resolver, 100, resolver.revision, reviewer.revision,
      actor: context.admin
    )

    Providers.create_provider!(
      "Ready Signal",
      :signal,
      "fixture-signal",
      %{"source" => "ready"},
      %{"secret" => "private-signal-secret"},
      actor: context.admin
    )
    |> then(&Providers.check_provider!(&1.id, 1, %{}, actor: context.admin))
    |> then(&Providers.enable_provider!(&1, 1, actor: context.admin))

    provider =
      Providers.create_provider!(
        "Ready Target",
        :target,
        "fixture-target",
        %{"endpoint" => "reachable"},
        %{"token" => "private-target-secret"},
        actor: context.admin
      )
      |> then(&Providers.enable_provider!(&1, 1, actor: context.admin))

    target =
      Targets.create_target!("Managed host", :host, "custom-os", %{}, nil, actor: context.admin)

    method =
      Targets.create_access_method!(
        target.id,
        provider.id,
        "Host SSH",
        :ssh,
        "ssh://host.example",
        provider.revision,
        100,
        ["observe.command"],
        actor: context.admin
      )

    Targets.check_access_method!(method.id, method.revision, %{}, actor: context.admin)

    current = Cases.current_authority_setting!(actor: context.admin)

    Cases.configure_authority_setting!(
      current.setting_revision,
      :auto,
      false,
      current.max_elapsed_seconds,
      current.max_resolver_turns,
      current.max_target_requests,
      current.max_effects,
      current.max_related_targets,
      current.max_ai_usage_units,
      current.max_no_progress_turns,
      "Readiness check",
      actor: context.admin
    )

    missing = get_json(path, context.operator_token)

    assert %{
             "data" => %{
               "ai" => true,
               "resolver" => true,
               "reviewer" => false,
               "authority" => false,
               "signal" => true,
               "target" => true,
               "complete" => false
             }
           } =
             json_response(missing, 200)

    assert_operation_response(missing)

    roles =
      Providers.list_ai_usage_role_assignments!(actor: context.admin)
      |> Enum.filter(&(&1.provider_id == ai.id))

    resolver = Enum.find(roles, &(&1.role == :resolver))
    reviewer = Enum.find(roles, &(&1.role == :reviewer))

    Providers.configure_ai_usage!(ai.id, :all, 100, resolver.revision, reviewer.revision,
      actor: context.admin
    )

    assert %{"data" => %{"complete" => true, "sole_reviewer_provider_id" => id}} =
             get_json(path, context.admin_token) |> json_response(200)

    assert id == ai.id

    Targets.update_target!(target, target.revision, %{name: "Changed host"}, actor: context.admin)

    assert %{"data" => %{"target" => false, "complete" => false}} =
             get_json(path, context.viewer_token) |> json_response(200)

    assert get_json(path, nil) |> response(401)
  end

  @tag provider_registration: true
  test "a caller registration identity locates the exact Provider and cannot overwrite it",
       context do
    registration_id = "10000000-0000-4000-8000-000000000051"

    input = %{
      "provider" => %{
        "registration_id" => registration_id,
        "name" => "Original destination",
        "kind" => "notification",
        "adapter_type" => "fixture-notification",
        "configuration" => %{"destination" => "reachable"},
        "credentials" => %{"token" => "private-registration-secret"}
      }
    }

    created = post_json("/api/v1/providers", input, context.admin_token)
    assert %{"data" => %{"id" => ^registration_id, "revision" => 1}} = json_response(created, 201)
    assert_operation_response(created)
    assert_secret_free(created, ["private-registration-secret"])

    for token <- [context.admin_token, context.operator_token, context.viewer_token] do
      read = get_json("/api/v1/providers/#{registration_id}", token)

      assert %{"data" => %{"id" => ^registration_id, "name" => "Original destination"}} =
               json_response(read, 200)

      assert_operation_response(read)
    end

    conflicting = put_in(input, ["provider", "name"], "Different destination")

    assert %{"error" => %{"code" => "conflict"}} =
             post_json("/api/v1/providers", conflicting, context.admin_token)
             |> json_response(409)

    assert %{"data" => %{"name" => "Original destination", "revision" => 1}} =
             get_json("/api/v1/providers/#{registration_id}", context.admin_token)
             |> json_response(200)
  end

  @tag setup_readiness: true
  test "AI display and role pages return only selected metadata", context do
    first =
      Providers.create_provider!(
        "Large AI configuration",
        :ai,
        "fixture-ai",
        %{
          "model" => "selected-model",
          "provider" => "openai",
          "body" => String.duplicate("x", 60_000)
        },
        %{"api_key" => "private-display-secret"},
        actor: context.admin
      )

    second =
      Providers.create_provider!(
        "Other AI configuration",
        :ai,
        "fixture-ai",
        %{"model" => "other-model"},
        %{"api_key" => "private"},
        actor: context.admin
      )

    response = get_json("/api/v1/providers/summaries?kinds=ai&limit=1", context.viewer_token)
    assert %{"data" => [summary], "page" => %{"next" => cursor}} = json_response(response, 200)
    assert summary["id"] == first.id
    assert summary["ai_model"] == "selected-model"
    assert summary["ai_service"] == "openai"
    refute Map.has_key?(summary, "configuration")
    assert byte_size(response.resp_body) < 3_000
    assert_operation_response(response)
    assert_secret_free(response, ["private-display-secret"])
    assert is_binary(cursor)

    roles =
      get_json(
        "/api/v1/ai-usage-role-assignments?provider_ids=#{second.id}&limit=100",
        context.viewer_token
      )

    assert %{"data" => assignments, "page" => %{"next" => nil}} = json_response(roles, 200)
    assert Enum.map(assignments, & &1["provider_id"]) == [second.id, second.id]
    assert_operation_response(roles)

    assert get_json("/api/v1/ai-usage-role-assignments?provider_ids=invalid", context.admin_token)
           |> response(422)
  end

  @tag provider_registration: true
  test "registration requires a valid identity and creation authority", context do
    registration_id = "10000000-0000-4000-8000-000000000052"

    provider = %{
      "registration_id" => registration_id,
      "name" => "Unregistered destination",
      "kind" => "notification",
      "adapter_type" => "fixture-notification",
      "configuration" => %{"destination" => "reachable"},
      "credentials" => %{"token" => "private-input-secret"}
    }

    for {invalid, status} <- [
          {Map.delete(provider, "registration_id"), 400},
          {%{provider | "registration_id" => "not-a-uuid"}, 422},
          {%{provider | "registration_id" => nil}, 422}
        ] do
      response = post_json("/api/v1/providers", %{"provider" => invalid}, context.admin_token)
      assert %{"error" => _} = json_response(response, status)
      assert_secret_free(response, ["private-input-secret"])
    end

    for token <- [context.operator_token, context.viewer_token] do
      assert %{"error" => %{"code" => "forbidden"}} =
               post_json("/api/v1/providers", %{"provider" => provider}, token)
               |> json_response(403)
    end

    assert %{"error" => %{"code" => "not_found"}} =
             get_json("/api/v1/providers/#{registration_id}", context.admin_token)
             |> json_response(404)
  end

  @tag provider_registration: true
  test "registration persistence failure does not fabricate an accepted receipt", context do
    registration_id = "10000000-0000-4000-8000-000000000053"

    input = %{
      "provider" => %{
        "registration_id" => registration_id,
        "name" => "Failed destination",
        "kind" => "notification",
        "adapter_type" => "fixture-notification",
        "configuration" => %{"destination" => "reachable"},
        "credentials" => %{"token" => "private-storage-secret"}
      }
    }

    Skopos.Repo.query!("""
    CREATE FUNCTION pg_temp.reject_provider_registration() RETURNS trigger LANGUAGE plpgsql AS $$
    BEGIN RAISE EXCEPTION 'registration storage unavailable'; END;
    $$
    """)

    Skopos.Repo.query!(
      "CREATE TRIGGER reject_provider_registration BEFORE INSERT ON providers FOR EACH ROW EXECUTE FUNCTION pg_temp.reject_provider_registration()"
    )

    try do
      capture_log(fn ->
        response = post_json("/api/v1/providers", input, context.admin_token)
        assert %{"error" => %{"code" => "internal_error"}} = json_response(response, 500)
        assert_secret_free(response, ["private-storage-secret"])
      end)
    after
      Skopos.Repo.query!("DROP TRIGGER reject_provider_registration ON providers")
    end

    assert %{"error" => %{"code" => "not_found"}} =
             get_json("/api/v1/providers/#{registration_id}", context.admin_token)
             |> json_response(404)
  end

  @tag provider_summaries: true
  test "management pages filter Provider kinds and eligible choices before pagination", context do
    create_provider!(
      context.admin_token,
      "Unrelated AI",
      "ai",
      "fixture-ai",
      %{"model" => "fixture"},
      %{"api_key" => "private"}
    )

    target =
      create_provider!(context.admin_token, "Target connection", "target", "http-api", %{}, %{})

    inventory =
      create_provider!(
        context.admin_token,
        "Inventory connection",
        "inventory",
        "fixture-inventory",
        %{"source" => "reachable"},
        %{"token" => "private"}
      )

    first =
      get_json("/api/v1/providers/summaries?kinds=target,inventory&limit=1", context.viewer_token)

    assert %{"data" => [summary], "page" => %{"next" => cursor}} = json_response(first, 200)
    assert_operation_response(first)
    assert summary["id"] == target["id"]

    assert Map.keys(summary) |> Enum.sort() ==
             ~w(adapter_type check enabled id kind name revision)

    assert summary["check"]["status"] == nil

    tail =
      get_json(
        "/api/v1/providers/summaries?kinds=target,inventory&limit=1&after=#{URI.encode_www_form(cursor)}",
        context.operator_token
      )

    assert %{"data" => [%{"id" => inventory_id}], "page" => %{"next" => nil}} =
             json_response(tail, 200)

    assert inventory_id == inventory["id"]

    enabled =
      post_json(
        "/api/v1/providers/#{target["id"]}/enable",
        %{"provider" => %{"expected_revision" => 1}},
        context.admin_token
      )

    assert json_response(enabled, 200)["data"]["enabled"]

    assert %{"data" => []} =
             get_json(
               "/api/v1/providers/summaries?kinds=inventory&eligible=true",
               context.viewer_token
             )
             |> json_response(200)

    checked =
      post_json(
        "/api/v1/providers/#{inventory_id}/check",
        %{"provider" => %{"expected_revision" => 1}},
        context.admin_token
      )

    assert json_response(checked, 200)["data"]["check"]["status"] == "passed"

    post_json(
      "/api/v1/providers/#{inventory_id}/enable",
      %{"provider" => %{"expected_revision" => 1}},
      context.admin_token
    )
    |> json_response(200)

    eligible =
      get_json(
        "/api/v1/providers/summaries?kinds=inventory&eligible=true&limit=1",
        context.viewer_token
      )

    assert %{
             "data" => [
               %{
                 "id" => ^inventory_id,
                 "check" => %{"status" => "passed", "checked_revision" => 1}
               }
             ]
           } = json_response(eligible, 200)

    assert_operation_response(eligible)
    assert_secret_free(eligible, ["private", "configuration", "credentials"])
  end

  test "authenticated clients can discover the installed AI object services", context do
    response = get_json("/api/v1/ai-services", context.viewer_token)

    assert %{"data" => services} = json_response(response, 200)
    assert_operation_response(response)
    assert length(services) == 30
    assert Enum.any?(services, &(&1["id"] == "ollama" && &1["auth"] == "none"))
    refute Enum.any?(services, &(&1["id"] in ~w(cohere elevenlabs typesafe)))
  end

  @tag provider_summaries: true
  test "management metadata stays paged past 100 Providers and expires updated eligibility",
       context do
    ids =
      for index <- 1..101 do
        create_provider!(
          context.admin_token,
          "Connection #{index}",
          "target",
          "http-api",
          %{"blob" => String.duplicate("x", 65_000)},
          %{"bearer_token" => "private"}
        )["id"]
      end

    first = get_json("/api/v1/providers/summaries?kinds=target&limit=100", context.viewer_token)
    assert %{"data" => summaries, "page" => %{"next" => cursor}} = json_response(first, 200)
    assert length(summaries) == 100
    assert byte_size(first.resp_body) < 40_000
    refute first.resp_body =~ "blob"

    tail =
      get_json(
        "/api/v1/providers/summaries?kinds=target&limit=100&after=#{URI.encode_www_form(cursor)}",
        context.admin_token
      )

    assert %{"data" => [%{"id" => tail_id}], "page" => %{"next" => nil}} =
             json_response(tail, 200)

    assert tail_id == List.last(ids)

    provider =
      create_provider!(
        context.admin_token,
        "Eligible inventory",
        "inventory",
        "fixture-inventory",
        %{"source" => "reachable"},
        %{"token" => "private"}
      )

    id = provider["id"]

    post_json(
      "/api/v1/providers/#{id}/check",
      %{"provider" => %{"expected_revision" => 1}},
      context.admin_token
    )
    |> json_response(200)

    post_json(
      "/api/v1/providers/#{id}/enable",
      %{"provider" => %{"expected_revision" => 1}},
      context.admin_token
    )
    |> json_response(200)

    assert %{"data" => [%{"id" => ^id}]} =
             get_json(
               "/api/v1/providers/summaries?kinds=inventory&eligible=true",
               context.viewer_token
             )
             |> json_response(200)

    updated =
      patch_json(
        "/api/v1/providers/#{id}",
        %{"provider" => %{"expected_revision" => 1, "name" => "Updated inventory"}},
        context.admin_token
      )
      |> json_response(200)

    assert updated["data"]["revision"] == 2

    assert %{"data" => []} =
             get_json(
               "/api/v1/providers/summaries?kinds=inventory&eligible=true",
               context.viewer_token
             )
             |> json_response(200)

    assert %{
             "data" => [
               %{"id" => ^id, "revision" => 2, "enabled" => false, "check" => %{"status" => nil}}
             ]
           } =
             get_json(
               "/api/v1/providers/summaries?ids=#{id}&eligible=false",
               context.viewer_token
             )
             |> json_response(200)

    for query <- [
          "kinds=invalid",
          "kinds=target,inventory,ai,signal,notification,target",
          "eligible=invalid",
          "ids=invalid",
          "ids=#{Enum.join(ids, ",")}"
        ] do
      assert %{"error" => %{"code" => "validation_failed"}} =
               get_json("/api/v1/providers/summaries?#{query}", context.viewer_token)
               |> json_response(422)
    end

    for query <- ["limit=101", "after=invalid"] do
      assert %{"error" => %{"code" => "invalid_pagination"}} =
               get_json("/api/v1/providers/summaries?#{query}", context.viewer_token)
               |> json_response(422)
    end

    assert build_conn() |> get("/api/v1/providers/summaries") |> json_response(401)
  end

  test "service account credentials are write-only in public AI registration", context do
    secret = ~s({"client_email":"probe@example.com","private_key":"private-probe"})

    response =
      post_json(
        "/api/v1/providers",
        %{
          "provider" => %{
            "registration_id" => Ash.UUID.generate(),
            "name" => "vertex-probe",
            "kind" => "ai",
            "adapter_type" => "req-llm",
            "configuration" => %{
              "provider" => "google_vertex",
              "model" => "gemini-2.5-flash",
              "project_id" => "probe-project"
            },
            "credentials" => %{"service_account_json" => secret}
          }
        },
        context.admin_token
      )

    assert %{"data" => %{"id" => id}} = json_response(response, 201)
    assert_operation_response(response)
    assert_secret_free(response, [secret, "private-probe"])

    shown = get_json("/api/v1/providers/#{id}", context.viewer_token)
    assert_operation_response(shown)
    assert_secret_free(shown, [secret, "private-probe"])
  end

  test "Target Provider returns its Access Method binding for Web and CLI clients", context do
    response =
      post_json(
        "/api/v1/providers",
        %{
          "provider" => %{
            "registration_id" => Ash.UUID.generate(),
            "name" => "public-http-target",
            "kind" => "target",
            "adapter_type" => "http-api",
            "configuration" => %{},
            "credentials" => %{}
          }
        },
        context.admin_token
      )

    assert %{
             "data" => %{
               "access_method_profile" => %{
                 "method" => "http"
               }
             }
           } = json_response(response, 201)

    assert_operation_response(response)
  end

  test "administrator configures every Provider kind without exposing credentials", context do
    providers =
      [
        {"ai", "fixture-ai", %{"model" => "test-model"}, %{"api_key" => "ai-secret"}},
        {"signal", "fixture-signal", %{"source" => "zabbix"}, %{"secret" => "signal-secret"}},
        {"target", "fixture-target", %{"endpoint" => "reachable"}, %{"token" => "target-secret"}},
        {"inventory", "fixture-inventory", %{"source" => "netbox"},
         %{"token" => "inventory-secret"}},
        {"notification", "fixture-notification", %{"destination" => "webhook"},
         %{"token" => "notification-secret"}}
      ]
      |> Enum.map(fn {kind, adapter, configuration, credentials} ->
        response =
          post_json(
            "/api/v1/providers",
            %{
              "provider" => %{
                "registration_id" => Ash.UUID.generate(),
                "name" => "#{kind}-primary",
                "kind" => kind,
                "adapter_type" => adapter,
                "configuration" => configuration,
                "credentials" => credentials
              }
            },
            context.admin_token
          )

        assert %{"data" => %{"id" => id, "kind" => ^kind, "revision" => 1}} =
                 json_response(response, 201)

        assert_operation_response(response)
        assert_secret_free(response, Map.values(credentials))

        if kind == "target" do
          assert post_json(
                   "/api/v1/providers/#{id}/check",
                   %{"provider" => %{"expected_revision" => 1}},
                   context.admin_token
                 )
                 |> response(422)
        else
          checked =
            post_json(
              "/api/v1/providers/#{id}/check",
              %{"provider" => %{"expected_revision" => 1}},
              context.admin_token
            )

          assert %{"data" => %{"check" => %{"status" => "passed", "checked_revision" => 1}}} =
                   json_response(checked, 200)

          assert_operation_response(checked)
        end

        enabled =
          post_json(
            "/api/v1/providers/#{id}/enable",
            %{"provider" => %{"expected_revision" => 1}},
            context.admin_token
          )

        assert %{"data" => %{"enabled" => true}} = json_response(enabled, 200)
        assert_operation_response(enabled)
        assert_secret_free(enabled, Map.values(credentials))
        id
      end)

    first_page = get_json("/api/v1/providers?limit=2", context.viewer_token)

    assert %{"data" => first, "page" => %{"next" => cursor}} =
             json_response(first_page, 200)

    assert_operation_response(first_page)

    assert length(first) == 2
    assert is_binary(cursor)

    assert_secret_free(first_page, [
      "ai-secret",
      "signal-secret",
      "target-secret",
      "inventory-secret",
      "notification-secret"
    ])

    second_page =
      get_json(
        "/api/v1/providers?limit=3&after=#{URI.encode_www_form(cursor)}",
        context.operator_token
      )

    assert %{"data" => remaining, "page" => %{"next" => nil}} =
             json_response(second_page, 200)

    assert length(remaining) == 3
    assert Enum.sort(Enum.map(first ++ remaining, & &1["id"])) == Enum.sort(providers)
  end

  test "Provider lifecycle preserves failed checks and rejects stale revisions", context do
    secret = "credential-never-returned"

    provider =
      create_provider!(
        context.admin_token,
        "inventory-check",
        "inventory",
        "fixture-inventory",
        %{"source" => "echo"},
        %{"token" => secret}
      )

    failed =
      post_json(
        "/api/v1/providers/#{provider["id"]}/check",
        %{"provider" => %{"expected_revision" => 1}},
        context.admin_token
      )

    assert %{
             "data" => %{
               "enabled" => false,
               "check" => %{
                 "status" => "failed",
                 "category" => "authentication",
                 "message" => "credential [REDACTED] was rejected"
               }
             }
           } = json_response(failed, 200)

    assert_secret_free(failed, [secret])

    updated =
      patch_json(
        "/api/v1/providers/#{provider["id"]}",
        %{
          "provider" => %{
            "expected_revision" => 1,
            "configuration" => %{"source" => "reachable"},
            "credentials" => %{"token" => "replacement-secret"}
          }
        },
        context.admin_token
      )

    assert %{"data" => %{"revision" => 2, "enabled" => false, "check" => %{"status" => nil}}} =
             json_response(updated, 200)

    assert_secret_free(updated, [secret, "replacement-secret"])

    stale =
      post_json(
        "/api/v1/providers/#{provider["id"]}/check",
        %{"provider" => %{"expected_revision" => 1}},
        context.admin_token
      )

    assert %{"error" => %{"code" => "conflict"}} = json_response(stale, 409)

    current =
      post_json(
        "/api/v1/providers/#{provider["id"]}/check",
        %{"provider" => %{"expected_revision" => 2}},
        context.admin_token
      )

    assert %{"data" => %{"check" => %{"status" => "passed"}}} = json_response(current, 200)

    disabled =
      post_json(
        "/api/v1/providers/#{provider["id"]}/disable",
        %{"provider" => %{"expected_revision" => 2}},
        context.admin_token
      )

    assert %{"data" => %{"enabled" => false}} = json_response(disabled, 200)
  end

  test "AI connection usage defaults to ALL and changes both roles atomically", context do
    ai =
      create_provider!(
        context.admin_token,
        "ai-role-provider",
        "ai",
        "fixture-ai",
        %{"model" => "test-model"},
        %{"api_key" => "role-secret"}
      )

    [resolver, reviewer] = assignments_for!(context.admin_token, ai["id"])

    assert resolver["provider_id"] == reviewer["provider_id"]
    assert resolver["role"] == "resolver"
    assert reviewer["role"] == "reviewer"

    assert resolver["enabled"] && reviewer["enabled"]
    assert resolver["priority"] == 100

    body = %{
      "usage" => %{
        "scope" => "reviewer",
        "priority" => 5,
        "expected_resolver_revision" => resolver["revision"],
        "expected_reviewer_revision" => reviewer["revision"]
      }
    }

    assert response(
             put_json("/api/v1/providers/#{ai["id"]}/ai-usage", body, context.admin_token),
             204
           ) == ""

    [updated_resolver, updated_reviewer] = assignments_for!(context.admin_token, ai["id"])
    assert updated_resolver["id"] == resolver["id"]
    assert updated_reviewer["id"] == reviewer["id"]
    assert updated_resolver["priority"] == 5
    refute updated_resolver["enabled"]
    assert updated_reviewer["enabled"]
    assert updated_reviewer["revision"] == 2

    stale =
      put_json("/api/v1/providers/#{ai["id"]}/ai-usage", body, context.admin_token)

    assert %{"error" => %{"code" => "conflict"}} = json_response(stale, 409)

    partially_stale =
      put_json(
        "/api/v1/providers/#{ai["id"]}/ai-usage",
        %{
          "usage" => %{
            "scope" => "all",
            "priority" => 8,
            "expected_resolver_revision" => updated_resolver["revision"],
            "expected_reviewer_revision" => reviewer["revision"]
          }
        },
        context.admin_token
      )

    assert %{"error" => %{"code" => "conflict"}} = json_response(partially_stale, 409)

    assert [^updated_resolver, ^updated_reviewer] =
             assignments_for!(context.admin_token, ai["id"])

    target = create_target!(context.admin_token, "reachable", "target-role-secret")

    wrong_kind =
      put_json("/api/v1/providers/#{target["id"]}/ai-usage", body, context.admin_token)

    assert %{"error" => %{"code" => "validation_failed"}} =
             json_response(wrong_kind, 422)

    for token <- [context.operator_token, context.viewer_token] do
      assert %{"error" => %{"code" => "forbidden"}} =
               put_json("/api/v1/providers/#{ai["id"]}/ai-usage", body, token)
               |> json_response(403)
    end

    listed = get_json("/api/v1/ai-usage-role-assignments?limit=1", context.viewer_token)
    assert %{"data" => [_one], "page" => %{"next" => cursor}} = json_response(listed, 200)
    assert is_binary(cursor)
    assert_secret_free(listed, ["role-secret", "target-role-secret"])
  end

  test "AI request settings persist through the public Provider API", context do
    configuration = %{
      "provider" => "openai",
      "model" => "test-model",
      "endpoint" => "https://api.example.test/v1",
      "max_tokens" => 8_192,
      "reasoning_effort" => "none"
    }

    provider =
      create_provider!(
        context.admin_token,
        "ai-settings-provider",
        "ai",
        "req-llm",
        configuration,
        %{"api_key" => "settings-secret"}
      )

    assert provider["configuration"] == configuration

    updated =
      patch_json(
        "/api/v1/providers/#{provider["id"]}",
        %{
          "provider" => %{
            "expected_revision" => provider["revision"],
            "configuration" => %{configuration | "max_tokens" => 65_536}
          }
        },
        context.admin_token
      )

    assert %{"data" => %{"configuration" => saved, "enabled" => false}} =
             json_response(updated, 200)

    assert saved["max_tokens"] == 65_536
    assert saved["reasoning_effort"] == "none"

    updated_provider = json_response(updated, 200)["data"]

    cleared =
      patch_json(
        "/api/v1/providers/#{provider["id"]}",
        %{
          "provider" => %{
            "expected_revision" => updated_provider["revision"],
            "configuration" => Map.delete(saved, "max_tokens")
          }
        },
        context.admin_token
      )

    assert %{"data" => %{"configuration" => defaults}} = json_response(cleared, 200)
    refute Map.has_key?(defaults, "max_tokens")
  end

  test "AI creation accepts an initial usage choice and rejects usage on other kinds", context do
    created =
      post_json(
        "/api/v1/providers",
        %{
          "provider" => %{
            "registration_id" => Ash.UUID.generate(),
            "name" => "review-only",
            "kind" => "ai",
            "adapter_type" => "fixture-ai",
            "configuration" => %{"model" => "test-model"},
            "credentials" => %{"api_key" => "initial-secret"},
            "usage_scope" => "reviewer",
            "usage_priority" => 7
          }
        },
        context.admin_token
      )

    assert %{"data" => %{"id" => id}} = json_response(created, 201)
    [resolver, reviewer] = assignments_for!(context.admin_token, id)
    refute resolver["enabled"]
    assert reviewer["enabled"]
    assert resolver["priority"] == 7
    assert reviewer["priority"] == 7

    rejected =
      post_json(
        "/api/v1/providers",
        %{
          "provider" => %{
            "registration_id" => Ash.UUID.generate(),
            "name" => "target-with-ai-usage",
            "kind" => "target",
            "adapter_type" => "fixture-target",
            "configuration" => %{"endpoint" => "reachable"},
            "credentials" => %{"token" => "test-token"},
            "usage_scope" => "all"
          }
        },
        context.admin_token
      )

    assert %{"error" => %{"code" => "bad_request"}} = json_response(rejected, 400)
  end

  test "administrator deletes an AI connection and revokes its active use", context do
    name = "retired-ai-#{System.unique_integer([:positive])}"
    secret = "credential-to-erase"

    ai =
      create_provider!(
        context.admin_token,
        name,
        "ai",
        "fixture-ai",
        %{"model" => "test-model"},
        %{"api_key" => secret}
      )

    [resolver, reviewer] = assignments_for!(context.admin_token, ai["id"])

    incident =
      Cases.open_case!(
        :manual,
        "web",
        "delete-ai-history-#{System.unique_integer([:positive])}",
        "Historical AI reference",
        :warning,
        %{"desired_outcome" => "Target responds as expected"},
        nil,
        :en,
        authorize?: false
      )

    run = Cases.active_resolution_run!(incident.id, authorize?: false)

    turn =
      Cases.create_turn_record!(
        %{
          case_id: incident.id,
          resolution_run_id: run.id,
          ordinal: 1,
          idempotency_key: "historical-turn",
          status: :started,
          intent: %{},
          started_at: DateTime.utc_now()
        },
        authorize?: false
      )

    invocation =
      Cases.create_ai_invocation_record!(
        %{
          case_id: incident.id,
          resolution_run_id: run.id,
          turn_id: turn.id,
          provider_id: ai["id"],
          assignment_id: resolver["id"],
          role: :resolver,
          idempotency_key: "historical-ai-invocation",
          request_digest: String.duplicate("a", 64),
          provider_revision: 1,
          assignment_revision: 1,
          selection_source: :assignment,
          reserved_units: 1,
          dispatch_started_at: DateTime.utc_now()
        },
        authorize?: false
      )

    assert %{"data" => %{"check" => %{"status" => "passed"}}} =
             post_json(
               "/api/v1/providers/#{ai["id"]}/check",
               %{"provider" => %{"expected_revision" => 1}},
               context.admin_token
             )
             |> json_response(200)

    assert %{"data" => %{"enabled" => true}} =
             post_json(
               "/api/v1/providers/#{ai["id"]}/enable",
               %{"provider" => %{"expected_revision" => 1}},
               context.admin_token
             )
             |> json_response(200)

    assert {:ok, eligible} =
             Providers.load_provider_for_invocation(ai["id"], 1, :ai, authorize?: false)

    assert eligible.id == ai["id"]

    assert %{"error" => %{"code" => "forbidden"}} =
             delete_json(
               "/api/v1/providers/#{ai["id"]}",
               %{"provider" => %{"expected_revision" => 1}},
               context.operator_token
             )
             |> json_response(403)

    assert %{"error" => %{"code" => "conflict"}} =
             delete_json(
               "/api/v1/providers/#{ai["id"]}",
               %{"provider" => %{"expected_revision" => 2}},
               context.admin_token
             )
             |> json_response(409)

    deleted =
      delete_json(
        "/api/v1/providers/#{ai["id"]}",
        %{"provider" => %{"expected_revision" => 1}},
        context.admin_token
      )

    assert response(deleted, 204) == ""
    assert_operation_response(deleted)

    assert response(
             delete_json(
               "/api/v1/providers/#{ai["id"]}",
               %{"provider" => %{"expected_revision" => 1}},
               context.admin_token
             ),
             204
           ) == ""

    assert %{"data" => active} =
             get_json("/api/v1/providers", context.admin_token) |> json_response(200)

    refute Enum.any?(active, &(&1["id"] == ai["id"]))

    assert %{"data" => roles} =
             get_json("/api/v1/ai-usage-role-assignments", context.admin_token)
             |> json_response(200)

    refute Enum.any?(roles, &(&1["provider_id"] == ai["id"]))

    for path <- [
          "/api/v1/providers/#{ai["id"]}/check",
          "/api/v1/providers/#{ai["id"]}/enable"
        ] do
      assert %{"error" => %{"code" => "not_found"}} =
               post_json(path, %{"provider" => %{"expected_revision" => 1}}, context.admin_token)
               |> json_response(404)
    end

    assert %{"error" => %{"code" => "not_found"}} =
             get_json("/api/v1/providers/#{ai["id"]}", context.admin_token)
             |> json_response(404)

    assert %{"error" => %{"code" => "not_found"}} =
             put_json(
               "/api/v1/providers/#{ai["id"]}/ai-usage",
               %{
                 "usage" => %{
                   "scope" => "all",
                   "priority" => 10,
                   "expected_resolver_revision" => 2,
                   "expected_reviewer_revision" => 2
                 }
               },
               context.admin_token
             )
             |> json_response(404)

    assert {:ok, stored} = Providers.get_provider(ai["id"], authorize?: false)
    assert stored.retired_at
    assert stored.configuration == %{}
    assert stored.enabled == false
    assert {:ok, stored} = Ash.load(stored, :credentials, authorize?: false)
    assert stored.credentials == %{}

    assert {:error, _error} =
             Providers.load_provider_for_invocation(ai["id"], 1, :ai, authorize?: false)

    assert {:error, _error} = Providers.select_resolver_ai(authorize?: false)

    assert {:ok, retained} =
             Cases.ai_invocation_by_idempotency("historical-ai-invocation", authorize?: false)

    assert retained.id == invocation.id
    assert retained.provider_id == ai["id"]
    assert retained.assignment_id == resolver["id"]
    assert Cases.get_case!(incident.id, authorize?: false).id == incident.id

    for role_id <- [resolver["id"], reviewer["id"]] do
      assert {:ok, assignment} =
               Providers.get_ai_usage_role_assignment(role_id, authorize?: false)

      assert assignment.enabled == false
    end

    replacement =
      create_provider!(
        context.admin_token,
        name,
        "ai",
        "fixture-ai",
        %{"model" => "replacement-model"},
        %{"api_key" => "replacement-secret"}
      )

    refute replacement["id"] == ai["id"]
    assert replacement["name"] == name
  end

  test "non-AI Provider cannot be deleted through AI removal", context do
    target = create_target!(context.admin_token, "reachable", "target-secret")

    assert %{"error" => %{"code" => "validation_failed"}} =
             delete_json(
               "/api/v1/providers/#{target["id"]}",
               %{"provider" => %{"expected_revision" => 1}},
               context.admin_token
             )
             |> json_response(422)

    assert %{"data" => %{"id" => id}} =
             get_json("/api/v1/providers/#{target["id"]}", context.admin_token)
             |> json_response(200)

    assert id == target["id"]
  end

  test "operator and viewer can read setup but cannot mutate it", context do
    provider = create_target!(context.admin_token, "reachable", "policy-secret")

    for token <- [context.operator_token, context.viewer_token] do
      assert %{"data" => %{"id" => id}} =
               get_json("/api/v1/providers/#{provider["id"]}", token) |> json_response(200)

      assert id == provider["id"]

      forbidden =
        post_json(
          "/api/v1/providers/#{provider["id"]}/check",
          %{"provider" => %{"expected_revision" => 1}},
          token
        )

      assert %{"error" => %{"code" => "forbidden"}} = json_response(forbidden, 403)
      assert_secret_free(forbidden, ["policy-secret"])
    end

    bad_body = post_json("/api/v1/providers", %{}, context.admin_token)
    assert %{"error" => %{"code" => "bad_request"}} = json_response(bad_body, 400)

    invalid_cursor = get_json("/api/v1/providers?after=not-a-keyset", context.admin_token)

    assert %{"error" => %{"code" => "invalid_pagination"}} =
             json_response(invalid_cursor, 422)
  end

  test "enabled Target Provider exposes adapter capabilities to administrators",
       context do
    provider =
      create_target!(context.admin_token, "reachable", "capability-secret")
      |> then(fn provider ->
        post_json(
          "/api/v1/providers/#{provider["id"]}/enable",
          %{"provider" => %{"expected_revision" => provider["revision"]}},
          context.admin_token
        )
        |> json_response(200)
        |> Map.fetch!("data")
      end)

    for token <- [context.admin_token] do
      response =
        post_json(
          "/api/v1/providers/#{provider["id"]}/target-capabilities",
          %{
            "provider" => %{
              "expected_revision" => provider["revision"],
              "endpoint" => "reachable"
            }
          },
          token
        )

      assert %{"data" => %{"observations" => observations, "effects" => effects}} =
               json_response(response, 200)

      assert Enum.any?(observations, &(&1["capability"] == "observe.command"))
      assert Enum.any?(effects, &(&1["capability"] == "effect.command"))
      assert_secret_free(response, ["capability-secret"])
    end

    for token <- [context.operator_token, context.viewer_token] do
      forbidden =
        post_json(
          "/api/v1/providers/#{provider["id"]}/target-capabilities",
          %{
            "provider" => %{
              "expected_revision" => provider["revision"],
              "endpoint" => "reachable"
            }
          },
          token
        )

      assert %{"error" => %{"code" => "forbidden"}} = json_response(forbidden, 403)
    end

    bad_body =
      post_json(
        "/api/v1/providers/#{provider["id"]}/target-capabilities",
        %{},
        context.admin_token
      )

    assert %{"error" => %{"code" => "bad_request"}} = json_response(bad_body, 400)
  end

  defp create_target!(token, endpoint, secret) do
    create_provider!(
      token,
      "target-#{System.unique_integer([:positive])}",
      "target",
      "fixture-target",
      %{"endpoint" => endpoint},
      %{"token" => secret}
    )
  end

  defp create_provider!(token, name, kind, adapter_type, configuration, credentials) do
    post_json(
      "/api/v1/providers",
      %{
        "provider" => %{
          "registration_id" => Ash.UUID.generate(),
          "name" => name,
          "kind" => kind,
          "adapter_type" => adapter_type,
          "configuration" => configuration,
          "credentials" => credentials
        }
      },
      token
    )
    |> json_response(201)
    |> Map.fetch!("data")
  end

  defp assignments_for!(token, provider_id) do
    get_json("/api/v1/ai-usage-role-assignments", token)
    |> json_response(200)
    |> Map.fetch!("data")
    |> Enum.filter(&(&1["provider_id"] == provider_id))
    |> Enum.sort_by(& &1["role"])
  end

  defp token!(email) do
    post_json("/api/v1/sessions", %{
      "session" => %{"email" => to_string(email), "password" => @password}
    })
    |> json_response(201)
    |> get_in(["data", "token"])
  end

  defp assert_secret_free(conn, secrets) do
    refute conn.resp_body =~ "credentials"
    refute conn.resp_body =~ "encrypted_credentials"
    Enum.each(secrets, &refute(conn.resp_body =~ &1))
  end

  defp post_json(path, body, token \\ nil), do: request(:post, path, body, token)
  defp patch_json(path, body, token), do: request(:patch, path, body, token)
  defp put_json(path, body, token), do: request(:put, path, body, token)
  defp delete_json(path, body, token), do: request(:delete, path, body, token)
  defp get_json(path, token), do: request(:get, path, nil, token)

  defp request(method, path, body, token) do
    build_json_conn(body)
    |> maybe_authorize(token)
    |> dispatch_request(method, path, body)
  end

  defp dispatch_request(conn, :get, path, _body), do: get(conn, path)
  defp dispatch_request(conn, :post, path, body), do: post(conn, path, body)
  defp dispatch_request(conn, :patch, path, body), do: patch(conn, path, body)
  defp dispatch_request(conn, :put, path, body), do: put(conn, path, body)
  defp dispatch_request(conn, :delete, path, body), do: delete(conn, path, body)

  defp maybe_authorize(conn, nil), do: conn

  defp maybe_authorize(conn, token),
    do: put_req_header(conn, "authorization", "Bearer " <> token)
end
