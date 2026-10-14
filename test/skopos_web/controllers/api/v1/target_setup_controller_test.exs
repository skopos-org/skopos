defmodule SkoposWeb.API.V1.TargetSetupControllerTest do
  use SkoposWeb.ConnCase, async: false

  import OpenApiSpex.TestAssertions
  import ExUnit.CaptureIO
  import ExUnit.CaptureLog

  alias Skopos.{Accounts, Providers}
  alias Skopos.Providers.Registry

  @password "correct horse battery staple"
  @provider_secret "target-provider-secret"

  setup do
    admin =
      Accounts.bootstrap!("target-api-admin@example.com", @password, @password, authorize?: true)

    operator =
      Accounts.create_user!("target-api-operator@example.com", @password, :operator, actor: admin)

    viewer =
      Accounts.create_user!("target-api-viewer@example.com", @password, :viewer, actor: admin)

    target_provider =
      Providers.create_provider!(
        "target-api-provider",
        :target,
        "fixture-target",
        %{"endpoint" => "reachable"},
        %{"token" => @provider_secret},
        actor: admin
      )
      |> then(&Providers.enable_provider!(&1, 1, actor: admin))

    inventory_provider =
      Providers.create_provider!(
        "inventory-api-provider",
        :inventory,
        "fixture-inventory",
        %{"source" => "netbox"},
        %{"token" => "inventory-provider-secret"},
        actor: admin
      )
      |> then(&Providers.check_provider!(&1.id, 1, %{}, actor: admin))
      |> then(&Providers.enable_provider!(&1, 1, actor: admin))

    %{
      admin: admin,
      admin_token: token!(admin.email),
      operator: operator,
      operator_token: token!(operator.email),
      viewer_token: token!(viewer.email),
      target_provider: target_provider,
      inventory_provider: inventory_provider
    }
  end

  test "Method checks publish observed capabilities independently of grants", context do
    target = create_target!(context.admin_token, "method-check", "host", "custom-os", nil)
    method = create_access_method!(context, target, "method-check", "ssh", ["observe.service"])
    path = "/api/v1/access-methods/#{method["id"]}/check"
    body = %{"access_method" => %{"expected_revision" => method["revision"]}}
    assert post_json(path, body, context.operator_token) |> response(403)
    checked_response = post_json(path, body, context.admin_token)
    assert_operation_response(checked_response)
    %{"data" => checked} = json_response(checked_response, 200)
    assert checked["check"]["status"] == "passed"
    assert "observe.command" in checked["check"]["observed_capabilities"]
    assert "effect.command" in checked["check"]["observed_capabilities"]
    assert checked["capabilities"] == ["observe.service"]
    assert checked["check"]["checked_target_revision"] == target["revision"]

    assert get_json("/api/v1/access-methods", context.viewer_token)
           |> json_response(200)
           |> get_in(["data", Access.at(0), "check", "status"]) == "passed"
  end

  @tag inventory_row_summaries: true
  test "preview display pages omit candidate data while keeping every row available for full apply",
       context do
    csv =
      NimbleCSV.RFC4180.dump_to_iodata([
        ~w(external_id identity_kind name kind type_id facts_json)
        | for index <- 1..101 do
            [
              "asset-#{index}",
              "custom-os",
              "Host #{index}",
              "host",
              "custom-os",
              Jason.encode!(%{"blob" => String.duplicate("x", 65_000)})
            ]
          end
      ])
      |> IO.iodata_to_binary()

    preview =
      post_json(
        "/api/v1/inventory-imports/manual-preview",
        %{"inventory_import" => %{"source" => "display-fixture", "csv" => csv}},
        context.admin_token
      )
      |> json_response(201)
      |> Map.fetch!("data")

    assert preview["row_count"] == 101
    assert preview["error_count"] == 0
    id = preview["id"]
    path = "/api/v1/inventory-imports/#{id}/rows/summaries"
    first = get_json("#{path}?limit=100", context.viewer_token)
    assert %{"data" => summaries, "page" => %{"next" => cursor}} = json_response(first, 200)
    assert_operation_response(first)
    assert Enum.map(summaries, & &1["position"]) == Enum.to_list(1..100)

    assert Map.keys(hd(summaries)) |> Enum.sort() ==
             ~w(disposition errors id identity_value position)

    assert byte_size(first.resp_body) < 25_000
    refute first.resp_body =~ "blob"

    tail =
      get_json("#{path}?limit=100&after=#{URI.encode_www_form(cursor)}", context.operator_token)

    assert %{
             "data" => [%{"position" => 101, "identity_value" => "asset-101"}],
             "page" => %{"next" => nil}
           } = json_response(tail, 200)

    assert_operation_response(tail)

    assert get_json(path, context.admin_token)
           |> json_response(200)
           |> Map.fetch!("data")
           |> length() == 50

    assert get_json(path, nil) |> json_response(401)

    assert get_json("/api/v1/inventory-imports/not-a-uuid/rows/summaries", context.viewer_token)
           |> json_response(422)

    for query <- ["limit=101", "after=invalid"] do
      assert %{"error" => %{"code" => "invalid_pagination"}} =
               get_json("#{path}?#{query}", context.viewer_token) |> json_response(422)
    end

    applied =
      post_json(
        "/api/v1/inventory-imports/#{id}/apply",
        %{
          "inventory_import" => %{
            "expected_revision" => preview["revision"],
            "expected_digest" => preview["content_digest"]
          }
        },
        context.admin_token
      )
      |> json_response(200)

    assert applied["data"]["status"] == "applied"
    assert applied["data"]["row_count"] == 101

    assert %{"data" => targets, "page" => %{"next" => target_cursor}} =
             get_json("/api/v1/targets/summaries?limit=100", context.viewer_token)
             |> json_response(200)

    assert length(targets) == 100

    assert %{"data" => [_], "page" => %{"next" => nil}} =
             get_json(
               "/api/v1/targets/summaries?limit=100&after=#{URI.encode_www_form(target_cursor)}",
               context.viewer_token
             )
             |> json_response(200)
  end

  @tag provider_references: true
  test "Provider references page compatible metadata without loading stored configuration",
       context do
    configuration = %{"blob" => String.duplicate("x", 65_525)}

    providers =
      for index <- 1..100 do
        suffix = Integer.to_string(index)

        Providers.create_provider!(
          String.duplicate("𠮷", 120 - String.length(suffix)) <> suffix,
          :target,
          "fixture-target",
          configuration,
          %{"token" => @provider_secret},
          actor: context.admin
        )
      end

    selected =
      Providers.create_provider!(
        "Selected SSH",
        :target,
        "ssh",
        configuration,
        %{"password" => @provider_secret},
        actor: context.admin
      )

    path =
      "/api/v1/providers/references?kind=target&enabled=false&adapter_types=fixture-target,ssh&limit=100"

    first = get_json(path, context.viewer_token)
    page = json_response(first, 200)
    assert length(page["data"]) == 100
    assert byte_size(first.resp_body) < 150_000
    assert Enum.map(page["data"], & &1["id"]) == Enum.map(providers, & &1.id)

    assert Enum.all?(
             page["data"],
             &(Enum.sort(Map.keys(&1)) == ~w(adapter_type enabled id kind name revision))
           )

    tail =
      get_json(
        path <> "&after=" <> URI.encode_www_form(page["page"]["next"]),
        context.viewer_token
      )

    assert [%{"id" => id, "access_method_profile" => %{"method" => "ssh"}}] =
             json_response(tail, 200)["data"]

    assert id == selected.id
    assert json_response(tail, 200)["page"]["next"] == nil
    assert_operation_response(tail)

    known =
      get_json(
        "/api/v1/providers/references?ids=#{selected.id},#{hd(providers).id}&limit=100",
        context.viewer_token
      )

    assert Enum.map(json_response(known, 200)["data"], & &1["id"]) == [
             hd(providers).id,
             selected.id
           ]

    assert get_json("/api/v1/providers/#{selected.id}", context.viewer_token)
           |> json_response(200)
           |> get_in(["data", "configuration"]) == configuration

    Providers.update_provider!(selected, selected.revision, %{name: "Current SSH"},
      actor: context.admin
    )

    assert [%{"id" => ^id, "name" => "Current SSH", "revision" => 2}] =
             get_json("/api/v1/providers/references?ids=#{id}", context.viewer_token)
             |> json_response(200)
             |> Map.fetch!("data")
  end

  @tag target_references: true
  test "Target references retain arbitrary destinations beyond the first page without facts",
       context do
    alias Skopos.Targets
    facts = %{"blob" => String.duplicate("x", 65_000)}

    targets =
      for index <- 1..101 do
        suffix = Integer.to_string(index)

        Targets.create_target!(
          String.duplicate("𠮷", 120 - String.length(suffix)) <> suffix,
          "host",
          "custom-os",
          facts,
          nil,
          %{operating_instructions: String.duplicate("𠮷", 4_000)},
          actor: context.admin
        )
      end

    inactive =
      Targets.create_target!("Inactive target", "host", "custom-os", facts, nil,
        actor: context.admin
      )

    Targets.deactivate_target!(inactive, inactive.revision, actor: context.admin)
    path = "/api/v1/targets/references?active=true&limit=100"
    first = get_json(path, context.viewer_token)
    page = json_response(first, 200)
    assert byte_size(first.resp_body) < 150_000
    assert Enum.map(page["data"], & &1["id"]) == Enum.map(Enum.take(targets, 100), & &1.id)

    assert Enum.all?(
             page["data"],
             &(Enum.sort(Map.keys(&1)) ==
                 ~w(active id kind management_boundary_id name revision type_id))
           )

    tail =
      get_json(
        path <> "&after=" <> URI.encode_www_form(page["page"]["next"]),
        context.viewer_token
      )

    assert [%{"id" => id}] = json_response(tail, 200)["data"]
    assert id == List.last(targets).id
    assert json_response(tail, 200)["page"]["next"] == nil
    assert_operation_response(tail)
    selected = List.last(targets)

    known =
      get_json(
        "/api/v1/targets/references?ids=#{selected.id},#{inactive.id}&limit=100",
        context.viewer_token
      )

    assert Enum.map(json_response(known, 200)["data"], & &1["id"]) == [selected.id, inactive.id]

    excluded =
      get_json(
        "/api/v1/targets/references?ids=#{selected.id},#{hd(targets).id}&exclude_id=#{hd(targets).id}",
        context.viewer_token
      )

    assert Enum.map(json_response(excluded, 200)["data"], & &1["id"]) == [selected.id]

    assert get_json("/api/v1/targets/#{selected.id}", context.viewer_token)
           |> json_response(200)
           |> get_in(["data", "facts"]) == facts

    Targets.update_target!(selected, selected.revision, %{name: "Current Target"},
      actor: context.admin
    )

    assert [%{"id" => ^id, "name" => "Current Target", "revision" => 2}] =
             get_json("/api/v1/targets/references?ids=#{id}", context.viewer_token)
             |> json_response(200)
             |> Map.fetch!("data")
  end

  @tag target_scope: true
  @tag reference_contract: true
  test "reference filters keep existing read roles and reject invalid or oversized ID sets",
       context do
    target = create_target!(context.admin_token, "reference-contract", "host", "custom-os", nil)

    for {path, id} <- [
          {"/api/v1/providers/references", context.target_provider.id},
          {"/api/v1/targets/references", target["id"]}
        ] do
      for token <- [context.admin_token, context.operator_token, context.viewer_token] do
        response = get_json(path <> "?ids=#{id}", token)
        assert [%{"id" => ^id}] = json_response(response, 200)["data"]
        assert_operation_response(response)
      end

      assert response(get_json(path <> "?ids=#{id}", nil), 401)

      for query <- [
            "ids=not-a-uuid",
            "ids=",
            "ids=" <> Enum.map_join(1..101, ",", fn _ -> Ecto.UUID.generate() end)
          ] do
        invalid = get_json(path <> "?" <> query, context.viewer_token)
        assert json_response(invalid, 422)["error"]["code"] == "validation_failed"
        assert_operation_response(invalid)
      end

      assert json_response(
               get_json(path <> "?ids=#{Ecto.UUID.generate()}", context.viewer_token),
               200
             )["data"] == []
    end

    for query <- ["kind=unsupported", "enabled=invalid", "adapter_types="] do
      assert get_json("/api/v1/providers/references?" <> query, context.viewer_token)
             |> json_response(422)
             |> get_in(["error", "code"]) == "validation_failed"
    end

    for query <- ["active=invalid", "exclude_id=not-a-uuid"] do
      assert get_json("/api/v1/targets/references?" <> query, context.viewer_token)
             |> json_response(422)
             |> get_in(["error", "code"]) == "validation_failed"
    end
  end

  @tag target_scope: true
  test "management Method pages retain unchecked connections and page only the selected Target",
       context do
    other = create_target!(context.admin_token, "other-host", "host", "custom-os", nil)
    selected = create_target!(context.admin_token, "selected-host", "host", "custom-os", nil)
    create_access_method!(context, other, "unrelated", "ssh", [])
    inactive = create_access_method!(context, selected, "inactive", "ssh", [])

    post_json(
      "/api/v1/access-methods/#{inactive["id"]}/deactivate",
      %{"access_method" => %{"expected_revision" => inactive["revision"]}},
      context.admin_token
    )
    |> json_response(200)

    methods =
      for index <- 1..101 do
        create_access_method!(context, selected, "unchecked-#{index}", "ssh", [])
      end

    path = "/api/v1/access-methods?target_id=#{selected["id"]}&active=true&limit=100"
    first = get_json(path, context.viewer_token) |> json_response(200)
    assert Enum.map(first["data"], & &1["id"]) == Enum.map(Enum.take(methods, 100), & &1["id"])
    assert Enum.all?(first["data"], &(&1["check"]["current"] == false))
    assert first["page"]["next"]

    next =
      get_json(
        path <> "&after=" <> URI.encode_www_form(first["page"]["next"]),
        context.viewer_token
      )

    assert json_response(next, 200)["data"] == [List.last(methods)]
    assert json_response(next, 200)["page"]["next"] == nil
    assert_operation_response(next)
  end

  @tag target_scope: true
  @tag target_summaries: true
  test "Target management summaries count complete collections and limit Methods per Target",
       context do
    alias Skopos.Targets
    busy = create_target!(context.admin_token, "A busy host", "host", "custom-os", nil)
    selected = create_target!(context.admin_token, "B selected host", "host", "custom-os", nil)
    peer = create_target!(context.admin_token, "C related host", "host", "custom-os", nil)

    for index <- 1..101 do
      create_access_method!(context, busy, "busy-#{index}", "ssh", [])
    end

    regular = create_access_method!(context, selected, "regular", "ssh", [])
    preferred = create_access_method!(context, selected, "preferred", "ssh", [])
    create_access_method!(context, selected, "third", "ssh", [])
    inactive = create_access_method!(context, selected, "inactive", "ssh", [])

    Targets.update_access_method!(preferred["id"], preferred["revision"], %{priority: 0},
      actor: context.admin
    )

    Targets.deactivate_access_method!(inactive["id"], inactive["revision"], actor: context.admin)

    Targets.create_relationship!(selected["id"], peer["id"], "hosted_by", %{}, nil,
      actor: context.admin
    )

    Targets.create_relationship!(
      peer["id"],
      selected["id"],
      "connected_to",
      %{},
      ~U[2000-01-01 00:00:00Z],
      actor: context.admin
    )

    retired =
      Targets.create_relationship!(selected["id"], busy["id"], "connected_to", %{}, nil,
        actor: context.admin
      )

    Targets.deactivate_relationship!(retired, retired.revision, actor: context.admin)

    Targets.update_target!(
      selected["id"],
      selected["revision"],
      %{operating_instructions: "Preserve boot disk"},
      actor: context.admin
    )

    response = get_json("/api/v1/targets/summaries?active=true&limit=3", context.viewer_token)

    assert %{"data" => [busy_summary, selected_summary, peer_summary], "page" => %{"next" => nil}} =
             json_response(response, 200)

    assert busy_summary["method_count"] == 101
    assert length(busy_summary["methods"]) == 2
    assert selected_summary["method_count"] == 3
    assert selected_summary["relationship_count"] == 2
    assert selected_summary["has_operating_instructions"] == true
    assert selected_summary["revision"] == 2
    assert Enum.map(selected_summary["methods"], & &1["id"]) == [preferred["id"], regular["id"]]
    assert peer_summary["method_count"] == 0
    assert peer_summary["relationship_count"] == 2
    assert peer_summary["methods"] == []
    assert peer_summary["has_operating_instructions"] == false
    refute Map.has_key?(selected_summary, "facts")
    refute Map.has_key?(selected_summary, "operating_instructions")
    assert_operation_response(response)
  end

  @tag target_scope: true
  @tag target_summaries: true
  test "Target summary paging and search omit full detail while retaining complete counts",
       context do
    alias Skopos.Targets
    facts = %{"needle-only-in-facts" => String.duplicate("x", 64983)}

    targets =
      for index <- 1..101 do
        suffix = "HOST-" <> String.pad_leading(Integer.to_string(index), 3, "0")

        target =
          Targets.create_target!(
            String.duplicate("𠮷", 120 - String.length(suffix)) <> suffix,
            "host",
            "custom-os",
            facts,
            nil,
            actor: context.admin
          )

        for connection <- 1..2 do
          Targets.create_access_method!(
            target.id,
            context.target_provider.id,
            "connection-#{connection}",
            "ssh",
            "ssh://192.0.2.10:22",
            context.target_provider.revision,
            connection,
            [],
            actor: context.admin
          )
        end

        Targets.update_target!(
          target,
          target.revision,
          %{operating_instructions: String.duplicate("🌏", 4000)},
          actor: context.admin
        )
      end

    selected = List.last(targets)

    first =
      get_json(
        "/api/v1/targets/summaries?active=true&query=CuStOm-Os&limit=100",
        context.viewer_token
      )

    assert length(json_response(first, 200)["data"]) == 100
    assert byte_size(first.resp_body) < 150_000

    assert Enum.all?(
             json_response(first, 200)["data"],
             &(&1["has_operating_instructions"] == true)
           )

    assert Enum.all?(
             json_response(first, 200)["data"],
             &(&1["method_count"] == 2 and length(&1["methods"]) == 2)
           )

    assert_operation_response(first)
    refute Enum.any?(json_response(first, 200)["data"], &(&1["id"] == selected.id))
    cursor = json_response(first, 200)["page"]["next"]

    tail =
      get_json(
        "/api/v1/targets/summaries?active=true&query=CuStOm-Os&limit=100&after=" <>
          URI.encode_www_form(cursor),
        context.viewer_token
      )

    assert [%{"id" => selected_id, "methods" => [_, _], "method_count" => 2}] =
             json_response(tail, 200)["data"]

    assert selected_id == selected.id
    assert json_response(tail, 200)["page"]["next"] == nil
    assert_operation_response(tail)

    exact =
      get_json(
        "/api/v1/targets/summaries?ids=#{selected.id}&query=HOST-101",
        context.viewer_token
      )

    assert [%{"id" => selected_id, "revision" => 2}] = json_response(exact, 200)["data"]
    assert selected_id == selected.id

    updated =
      Targets.update_target!(selected, selected.revision, %{name: "Renamed host"},
        actor: context.admin
      )

    assert [%{"name" => "Renamed host", "revision" => 3}] =
             get_json("/api/v1/targets/summaries?ids=#{updated.id}", context.viewer_token)
             |> json_response(200)
             |> Map.fetch!("data")

    assert get_json("/api/v1/targets/summaries?query=needle-only-in-facts", context.viewer_token)
           |> json_response(200)
           |> Map.fetch!("data") == []

    assert get_json("/api/v1/targets/#{updated.id}", context.viewer_token)
           |> json_response(200)
           |> get_in(["data", "facts"]) == facts
  end

  @tag target_summaries: true
  test "Target summary filters authorize reads and search literal inventory labels", context do
    selected = create_target!(context.admin_token, "Host_% literal", "host", "custom-os", nil)
    other = create_target!(context.admin_token, "Host other", "host", "custom-os", nil)
    path = "/api/v1/targets/summaries"

    for token <- [context.admin_token, context.operator_token, context.viewer_token] do
      response = get_json(path <> "?query=" <> URI.encode_www_form("_%"), token)
      assert [%{"id" => id}] = json_response(response, 200)["data"]
      assert id == selected["id"]
      assert_operation_response(response)
    end

    assert response(get_json(path, nil), 401)

    for query <- [
          "ids=not-a-uuid",
          "ids=",
          "active=invalid",
          "ids=" <> Enum.map_join(1..101, ",", fn _ -> Ecto.UUID.generate() end),
          "query=" <> String.duplicate("x", 201)
        ] do
      invalid = get_json(path <> "?" <> query, context.viewer_token)
      assert json_response(invalid, 422)["error"]["code"] == "validation_failed"
      assert_operation_response(invalid)
    end

    for query <- ["after=invalid", "limit=101"] do
      invalid_page = get_json(path <> "?" <> query, context.viewer_token)
      assert json_response(invalid_page, 422)["error"]["code"] == "invalid_pagination"
      assert_operation_response(invalid_page)
    end

    assert json_response(
             get_json(path <> "?ids=#{Ecto.UUID.generate()}", context.viewer_token),
             200
           )["data"] == []

    assert length(json_response(get_json(path <> "?query=", context.viewer_token), 200)["data"]) ==
             2

    Skopos.Targets.deactivate_target!(other["id"], other["revision"], actor: context.admin)

    assert [%{"id" => id, "active" => false, "revision" => 2}] =
             json_response(get_json(path <> "?active=false", context.viewer_token), 200)["data"]

    assert id == other["id"]
  end

  @tag target_scope: true
  @tag method_projection: true
  test "referenced Method IDs are filtered before paging and retain inactive lower-priority identities",
       context do
    alias Skopos.Targets

    selected =
      create_target!(context.admin_token, "selected-identity-host", "host", "custom-os", nil)

    other = create_target!(context.admin_token, "other-identity-host", "host", "custom-os", nil)
    first = create_access_method!(context, selected, "first-method", "ssh", [])
    last = create_access_method!(context, selected, "last-method", "ssh", [])
    peer = create_access_method!(context, other, "peer-method", "ssh", [])

    Targets.update_access_method!(last["id"], last["revision"], %{priority: 500},
      actor: context.admin
    )

    Targets.deactivate_access_method!(last["id"], 2, actor: context.admin)
    path = "/api/v1/access-methods?ids=#{last["id"]},#{peer["id"]}&limit=1"

    response = get_json(path, context.viewer_token)
    assert_operation_response(response)

    assert %{"data" => [%{"id" => peer_id}], "page" => %{"next" => cursor}} =
             json_response(response, 200)

    assert peer_id == peer["id"]
    assert is_binary(cursor)
    tail = get_json(path <> "&after=" <> URI.encode_www_form(cursor), context.viewer_token)
    assert_operation_response(tail)

    assert %{
             "data" => [
               %{"id" => last_id, "name" => "last-method", "active" => false, "priority" => 500} =
                 row
             ],
             "page" => %{"next" => nil}
           } = json_response(tail, 200)

    assert last_id == last["id"]
    refute Map.has_key?(row, "operation_catalog")
    refute Map.has_key?(row, "check_attempt_id")
    refute last_id == first["id"]

    scoped = get_json(path <> "&target_id=#{selected["id"]}", context.operator_token)
    assert [%{"id" => ^last_id}] = json_response(scoped, 200)["data"]
    active = get_json(path <> "&active=true", context.admin_token)
    assert [%{"id" => ^peer_id}] = json_response(active, 200)["data"]

    assert [] =
             get_json("/api/v1/access-methods?ids=#{Ecto.UUID.generate()}", context.viewer_token)
             |> json_response(200)
             |> Map.fetch!("data")
  end

  @tag target_scope: true
  @tag method_projection: true
  test "Method identity filters reject unbounded or malformed requests and require authentication",
       context do
    path = "/api/v1/access-methods"
    assert response(get_json(path <> "?ids=#{Ecto.UUID.generate()}", nil), 401)

    for query <- [
          "ids=not-a-uuid",
          "ids=",
          "ids=" <> Enum.map_join(1..101, ",", fn _ -> Ecto.UUID.generate() end)
        ] do
      response = get_json(path <> "?" <> query, context.viewer_token)
      assert %{"error" => %{"code" => "validation_failed"}} = json_response(response, 422)
    end

    ids = for _ <- 1..100, do: Ecto.UUID.generate()
    filters = %{ids: ids}

    assert {:ok, %{results: []}} =
             Skopos.Targets.page_access_methods(filters, actor: context.admin)

    assert {:error, %Ash.Error.Invalid{}} =
             Skopos.Targets.page_access_methods(%{ids: [Ecto.UUID.generate() | ids]},
               actor: context.admin
             )

    assert {:error, %Ash.Error.Invalid{}} =
             Skopos.Targets.page_access_methods(%{ids: ["not-a-uuid"]}, actor: context.admin)

    response = get_json(path <> "?ids=" <> Enum.join(ids, ","), context.viewer_token)
    assert_operation_response(response)
    assert [] = json_response(response, 200)["data"]
  end

  @tag target_scope: true
  @tag method_projection: true
  test "management Method pages do not hydrate the execution catalog and preserve checked state",
       context do
    target = create_target!(context.admin_token, "projection-host", "host", "custom-os", nil)
    method = create_access_method!(context, target, "projection-method", "ssh", [])

    checked =
      post_json(
        "/api/v1/access-methods/#{method["id"]}/check",
        %{"access_method" => %{"expected_revision" => method["revision"]}},
        context.admin_token
      )
      |> json_response(200)
      |> Map.fetch!("data")

    assert checked["check"]["current"] == true

    assert {:ok, page} =
             Skopos.Targets.page_access_methods(
               %{target_id: target["id"], active: true},
               actor: context.admin,
               page: [limit: 50]
             )

    assert [row] = page.results
    assert row.check_current == true
    refute Ash.Resource.selected?(row, :operation_catalog)
    refute Ash.Resource.selected?(row, :check_attempt_id)

    response =
      get_json(
        "/api/v1/access-methods?target_id=#{target["id"]}&active=true&limit=50",
        context.viewer_token
      )

    assert json_response(response, 200)["data"] == [checked]
    assert_operation_response(response)
  end

  @tag target_scope: true
  test "identity pages exclude other Targets before applying the cursor", context do
    selected = create_target!(context.admin_token, "identity-host", "host", "custom-os", nil)
    other = create_target!(context.admin_token, "other-identity-host", "host", "custom-os", nil)
    alias Skopos.Targets

    Targets.create_external_identity!(other["id"], "inventory", "hostname", "other",
      actor: context.admin
    )

    inactive =
      Targets.create_external_identity!(selected["id"], "inventory", "hostname", "inactive",
        actor: context.admin
      )

    Targets.deactivate_external_identity!(inactive, inactive.revision, actor: context.admin)

    identities =
      for index <- 1..101 do
        Targets.create_external_identity!(
          selected["id"],
          "inventory",
          "hostname",
          "host-#{index}",
          actor: context.admin
        )
      end

    path = "/api/v1/external-identities?target_id=#{selected["id"]}&active=true&limit=100"
    first = get_json(path, context.operator_token) |> json_response(200)
    assert Enum.map(first["data"], & &1["id"]) == Enum.map(Enum.take(identities, 100), & &1.id)

    next =
      get_json(
        path <> "&after=" <> URI.encode_www_form(first["page"]["next"]),
        context.operator_token
      )

    assert [%{"id" => id, "revision" => 1}] = json_response(next, 200)["data"]
    assert id == List.last(identities).id
    assert json_response(next, 200)["page"]["next"] == nil
    assert_operation_response(next)

    assert [%{"id" => inactive_id, "revision" => 2}] =
             get_json(String.replace(path, "active=true", "active=false"), context.viewer_token)
             |> json_response(200)
             |> Map.fetch!("data")

    assert inactive_id == inactive.id
  end

  @tag relationship_scope: true
  test "relationship pages include both directions without hiding expired active records",
       context do
    alias Skopos.Targets
    selected = create_target!(context.admin_token, "relation-host", "host", "custom-os", nil)
    other = create_target!(context.admin_token, "relation-peer", "host", "custom-os", nil)
    unrelated = create_target!(context.admin_token, "unrelated-host", "host", "custom-os", nil)

    Targets.create_relationship!(other["id"], unrelated["id"], "unrelated", %{}, nil,
      actor: context.admin
    )

    inactive =
      Targets.create_relationship!(selected["id"], other["id"], "inactive", %{}, nil,
        actor: context.admin
      )

    Targets.deactivate_relationship!(inactive, inactive.revision, actor: context.admin)

    relationships =
      for index <- 1..101 do
        {source, destination} =
          if rem(index, 2) == 0, do: {other, selected}, else: {selected, other}

        Targets.create_relationship!(
          source["id"],
          destination["id"],
          "edge-#{index}",
          %{"index" => index},
          ~U[2000-01-01 00:00:00Z],
          actor: context.admin
        )
      end

    path = "/api/v1/target-relationships?target_id=#{selected["id"]}&active=true&limit=100"
    first = get_json(path, context.viewer_token) |> json_response(200)
    assert Enum.map(first["data"], & &1["id"]) == Enum.map(Enum.take(relationships, 100), & &1.id)
    assert Enum.any?(first["data"], &(&1["source_target_id"] == selected["id"]))
    assert Enum.any?(first["data"], &(&1["destination_target_id"] == selected["id"]))

    next =
      get_json(
        path <> "&after=" <> URI.encode_www_form(first["page"]["next"]),
        context.viewer_token
      )

    assert [%{"id" => id, "facts" => %{"index" => 101}}] = json_response(next, 200)["data"]
    assert id == List.last(relationships).id
    assert json_response(next, 200)["page"]["next"] == nil
    assert_operation_response(next)
  end

  @tag target_scope_contract: true
  test "scoped management pages preserve read roles and reject malformed scope", context do
    target = create_target!(context.admin_token, "scope-contract", "host", "custom-os", nil)
    method = create_access_method!(context, target, "scope-contract", "ssh", [])

    identity =
      post_data!(
        "/api/v1/external-identities",
        %{
          "external_identity" => %{
            "target_id" => target["id"],
            "source" => "inventory",
            "kind" => "hostname",
            "value" => "scope-contract"
          }
        },
        context.admin_token
      )

    peer = create_target!(context.admin_token, "scope-contract-peer", "host", "custom-os", nil)
    relationship = create_relationship!(context.admin_token, peer, target, "connected_to")

    for {path, record} <- [
          {"/api/v1/access-methods", method},
          {"/api/v1/external-identities", identity},
          {"/api/v1/target-relationships", relationship}
        ] do
      scoped = path <> "?target_id=#{target["id"]}&active=true"

      for token <- [context.admin_token, context.operator_token, context.viewer_token] do
        response = get_json(scoped, token)
        assert json_response(response, 200)["data"] == [record]
        assert_operation_response(response)
      end

      assert response(get_json(scoped, nil), 401)

      for {query, code} <- [
            {"target_id=not-a-uuid", "validation_failed"},
            {"active=unknown", "validation_failed"},
            {"limit=101", "invalid_pagination"},
            {"after=", "invalid_pagination"}
          ] do
        response = get_json(path <> "?" <> query, context.viewer_token)
        assert json_response(response, 422)["error"]["code"] == code
        assert_operation_response(response)
      end

      assert get_json(
               path <> "?target_id=#{Ecto.UUID.generate()}&active=true",
               context.viewer_token
             )
             |> json_response(200)
             |> Map.fetch!("data") == []
    end
  end

  @tag method_detail: true
  test "registered Method detail is reachable beyond the first global page", context do
    target = create_target!(context.admin_token, "method-detail", "host", "custom-os", nil)

    for index <- 1..100 do
      create_access_method!(context, target, "earlier-method-#{index}", "ssh", [])
    end

    method = create_access_method!(context, target, "selected-method", "ssh", [])

    page =
      get_json("/api/v1/access-methods?limit=100", context.viewer_token) |> json_response(200)

    assert length(page["data"]) == 100
    refute Enum.any?(page["data"], &(&1["id"] == method["id"]))
    path = "/api/v1/access-methods/#{method["id"]}"

    checked =
      post_json(
        path <> "/check",
        %{"access_method" => %{"expected_revision" => method["revision"]}},
        context.admin_token
      )
      |> json_response(200)
      |> Map.fetch!("data")

    assert checked["revision"] > method["revision"]

    for token <- [context.admin_token, context.operator_token, context.viewer_token] do
      response = get_json(path, token)
      assert json_response(response, 200)["data"] == checked
      assert_operation_response(response)
    end

    assert response(get_json(path, nil), 401)

    assert response(
             get_json("/api/v1/access-methods/#{Ecto.UUID.generate()}", context.viewer_token),
             404
           )

    root = Path.join(System.tmp_dir!(), "method-detail-cli-#{System.unique_integer([:positive])}")
    config_path = Path.join(root, "config.json")

    :ok =
      SkoposCLI.Config.save(
        %{"server" => "https://skopos.example", "token" => context.viewer_token},
        config_path
      )

    on_exit(fn -> File.rm_rf(root) end)
    stub = {__MODULE__, make_ref()}
    Req.Test.stub(stub, &SkoposWeb.Endpoint.call(&1, SkoposWeb.Endpoint.init([])))
    runtime = [config_path: config_path, request_options: [plug: {Req.Test, stub}]]

    shown =
      capture_io(fn ->
        assert SkoposCLI.CLI.run(["access-method", "show", method["id"]], runtime) == 0
      end)

    assert Jason.decode!(shown)["data"] == checked

    Skopos.Repo.query!(
      "ALTER TABLE access_methods RENAME COLUMN revision TO unavailable_revision"
    )

    try do
      assert {:error, %Ash.Error.Unknown{} = cause} =
               Skopos.Targets.get_access_method(method["id"], actor: context.admin)

      assert Exception.message(cause) =~ "does not exist"

      capture_log(fn ->
        failed = get_json(path, context.viewer_token)
        assert json_response(failed, 500)["error"]["code"] == "internal_error"

        capture_io(:stderr, fn ->
          assert SkoposCLI.CLI.run(["access-method", "show", method["id"]], runtime) == 4
        end)
      end)
    after
      Skopos.Repo.query!(
        "ALTER TABLE access_methods RENAME COLUMN unavailable_revision TO revision"
      )
    end

    assert json_response(get_json(path, context.viewer_token), 200)["data"] == checked
    refute_receive {:check, _, _}
  end

  @tag boundary_choices: true
  test "boundary pages omit large facts while selected detail preserves them", context do
    facts = %{"payload" => String.duplicate("x", 65_522)}
    assert byte_size(Jason.encode!(facts)) == 65_536

    boundaries =
      for index <- 1..101 do
        name = String.duplicate("🌏", 116) <> String.pad_leading(Integer.to_string(index), 4, "0")

        Skopos.Targets.create_management_boundary!(name, String.duplicate("🌏", 80), facts,
          actor: context.admin
        )
      end

    selected = List.last(boundaries)
    response = get_json("/api/v1/management-boundaries?limit=100", context.viewer_token)
    page = json_response(response, 200)
    assert length(page["data"]) == 100
    assert byte_size(response.resp_body) < 150_000
    assert Enum.all?(page["data"], &(not Map.has_key?(&1, "facts")))
    refute Enum.any?(page["data"], &(&1["id"] == selected.id))
    assert_operation_response(response)
    query = URI.encode_query(%{"limit" => 100, "after" => page["page"]["next"]})

    tail =
      get_json("/api/v1/management-boundaries?#{query}", context.viewer_token)
      |> json_response(200)

    assert Enum.map(tail["data"], & &1["id"]) == [selected.id]
    assert tail["page"]["next"] == nil
    path = "/api/v1/management-boundaries/#{selected.id}"

    for token <- [context.admin_token, context.operator_token, context.viewer_token] do
      response = get_json(path, token)
      assert json_response(response, 200)["data"]["facts"] == facts
      assert_operation_response(response)
    end

    assert response(get_json(path, nil), 401)

    assert response(
             get_json(
               "/api/v1/management-boundaries/#{Ecto.UUID.generate()}",
               context.viewer_token
             ),
             404
           )

    root = Path.join(System.tmp_dir!(), "boundary-cli-#{System.unique_integer([:positive])}")
    config_path = Path.join(root, "config.json")

    :ok =
      SkoposCLI.Config.save(
        %{"server" => "https://skopos.example", "token" => context.viewer_token},
        config_path
      )

    on_exit(fn -> File.rm_rf(root) end)
    stub = {__MODULE__, make_ref()}
    Req.Test.stub(stub, &SkoposWeb.Endpoint.call(&1, SkoposWeb.Endpoint.init([])))
    runtime = [config_path: config_path, request_options: [plug: {Req.Test, stub}]]

    listed =
      capture_io(fn ->
        assert SkoposCLI.CLI.run(
                 ["boundary", "list", "--limit", "100", "--after", page["page"]["next"]],
                 runtime
               ) == 0
      end)

    assert Jason.decode!(listed)["data"] == tail["data"]

    shown =
      capture_io(fn ->
        assert SkoposCLI.CLI.run(["boundary", "show", selected.id], runtime) == 0
      end)

    assert Jason.decode!(shown)["data"]["facts"] == facts

    Skopos.Repo.query!(
      "ALTER TABLE management_boundaries RENAME COLUMN facts TO unavailable_facts"
    )

    try do
      assert json_response(
               get_json("/api/v1/management-boundaries?limit=100", context.viewer_token),
               200
             ) == page

      assert {:error, %Ash.Error.Unknown{} = cause} =
               Skopos.Targets.get_management_boundary(selected.id, actor: context.admin)

      assert Exception.message(cause) =~ "does not exist"

      capture_log(fn ->
        assert json_response(get_json(path, context.viewer_token), 500)["error"]["code"] ==
                 "internal_error"

        capture_io(:stderr, fn ->
          assert SkoposCLI.CLI.run(["boundary", "show", selected.id], runtime) == 4
        end)
      end)
    after
      Skopos.Repo.query!(
        "ALTER TABLE management_boundaries RENAME COLUMN unavailable_facts TO facts"
      )
    end

    assert json_response(get_json(path, context.viewer_token), 200)["data"]["facts"] == facts

    Skopos.Repo.query!("ALTER TABLE management_boundaries RENAME COLUMN name TO unavailable_name")

    try do
      assert {:error, %Ash.Error.Unknown{} = cause} =
               Skopos.Targets.page_management_boundaries(actor: context.admin)

      assert Exception.message(cause) =~ "does not exist"

      capture_log(fn ->
        assert json_response(get_json("/api/v1/management-boundaries", context.viewer_token), 500)[
                 "error"
               ]["code"] == "internal_error"

        capture_io(:stderr, fn ->
          assert SkoposCLI.CLI.run(["boundary", "list"], runtime) == 4
        end)
      end)
    after
      Skopos.Repo.query!(
        "ALTER TABLE management_boundaries RENAME COLUMN unavailable_name TO name"
      )
    end

    assert json_response(
             get_json("/api/v1/management-boundaries?limit=100", context.viewer_token),
             200
           ) == page
  end

  test "Target type catalog publishes custom choices per supported category", context do
    response = get_json("/api/v1/target-types", context.viewer_token)
    assert_operation_response(response)

    %{"data" => %{"categories" => categories, "types" => types, "methods" => methods}} =
      json_response(response, 200)

    assert length(categories) == 9
    assert Enum.any?(categories, &(&1["id"] == "storage"))

    by_id = Map.new(types, &{&1["id"], &1})
    refute Map.has_key?(by_id, "generic")

    assert by_id["custom-network-device"]["category_id"] == "network-device"

    assert by_id["custom-network-device"]["access_method_types"] == [
             "ssh",
             "netconf",
             "restconf",
             "http-api"
           ]

    assert by_id["custom-os"]["category_id"] == "os"
    assert by_id["custom-bmc"]["access_method_types"] == ["redfish", "ipmi"]

    assert by_id["hpe-ilo"]["access_method_types"] == [
             "redfish",
             "ipmi",
             "hpe-ilo-redfish",
             "hpe-ilo-ipmi"
           ]

    assert by_id["dell-idrac"]["access_method_types"] == [
             "redfish",
             "ipmi",
             "dell-idrac-redfish",
             "dell-idrac-ipmi"
           ]

    assert by_id["cisco_ios_xe"]["category_id"] == "network-device"
    method_ids = Enum.map(methods, & &1["adapter_type"])

    assert Enum.any?(
             methods,
             &(&1["adapter_type"] == "hpe-ilo-ipmi" and &1["protocol"] == "ipmi")
           )

    for type <- types, adapter_type <- type["access_method_types"] do
      assert {:ok, adapter} = Registry.fetch(adapter_type, Providers.Target)
      assert %Providers.Target.AccessMethodProfile{} = adapter.access_method_profile()
      assert adapter_type in method_ids
    end
  end

  test "every published compatible Method binds through the same authenticated API", context do
    %{"data" => catalog} =
      get_json("/api/v1/target-types", context.admin_token) |> json_response(200)

    # Registration seam only: remote check results are fixtures here. Wire/auth behavior
    # is proved in each protocol adapter's separate connection tests.
    providers =
      for descriptor <- catalog["methods"], into: %{} do
        endpoint =
          if descriptor["protocol"] in ["ssh", "netconf"],
            do: "ssh://device.example.test:22",
            else:
              if(descriptor["protocol"] == "ipmi",
                do: "ipmi://device.example.test:623",
                else: "https://device.example.test"
              )

        {configuration, credentials} =
          Skopos.TargetConnectionFixture.input(descriptor["adapter_type"], endpoint)

        provider =
          Providers.create_provider!(
            descriptor["adapter_type"],
            :target,
            descriptor["adapter_type"],
            configuration,
            credentials,
            actor: context.admin
          )

        enabled = Providers.enable_provider!(provider, provider.revision, actor: context.admin)
        {:ok, adapter} = Registry.fetch(descriptor["adapter_type"], Providers.Target)
        {descriptor["adapter_type"], {enabled, endpoint, adapter.access_method_profile()}}
      end

    for type <- catalog["types"] do
      target = create_target!(context.admin_token, type["id"], type["kind"], type["id"], nil)

      for adapter_type <- type["access_method_types"] do
        {provider, endpoint, profile} = Map.fetch!(providers, adapter_type)

        method =
          post_data!(
            "/api/v1/access-methods",
            %{
              "access_method" => %{
                "target_id" => target["id"],
                "provider_id" => provider.id,
                "name" => adapter_type,
                "method" => profile.method,
                "endpoint" => endpoint,
                "provider_revision" => provider.revision,
                "capabilities" => profile.capabilities
              }
            },
            context.admin_token
          )

        assert method["target_id"] == target["id"]
        assert method["provider_id"] == provider.id
      end
    end
  end

  test "Target creation enforces the published type and its kind", context do
    for {kind, type_id} <- [{"host", "unsupported-device"}, {"cluster", "linux"}] do
      response =
        post_json(
          "/api/v1/targets",
          %{
            "target" => %{
              "name" => "invalid-target",
              "kind" => kind,
              "type_id" => type_id,
              "facts" => %{}
            }
          },
          context.admin_token
        )

      assert %{"error" => %{"code" => "validation_failed"}} = json_response(response, 422)
    end
  end

  test "Access Method API rejects a Provider mismatch and accepts its declared binding",
       context do
    endpoint = "https://example.test"

    provider =
      Providers.create_provider!(
        "http-binding-provider",
        :target,
        "http-api",
        %{},
        %{},
        actor: context.admin
      )
      |> then(&Providers.enable_provider!(&1, &1.revision, actor: context.admin))

    target = create_target!(context.admin_token, "http-binding-target", "host", "linux", nil)

    method = %{
      "target_id" => target["id"],
      "provider_id" => provider.id,
      "name" => "http-api",
      "method" => "http",
      "endpoint" => endpoint,
      "provider_revision" => provider.revision,
      "priority" => 100,
      "capabilities" => ["request.http.observe", "request.http.effect"]
    }

    invalid =
      post_json(
        "/api/v1/access-methods",
        %{"access_method" => %{method | "method" => "ipmi"}},
        context.admin_token
      )

    assert %{"error" => %{"code" => "validation_failed"}} = json_response(invalid, 422)

    unknown_field =
      post_json(
        "/api/v1/access-methods",
        %{"access_method" => Map.put(method, "unexpected_property", "ignored")},
        context.admin_token
      )

    assert %{"error" => %{"code" => "bad_request"}} = json_response(unknown_field, 400)

    bmc =
      create_target!(
        context.admin_token,
        "bmc-http-mismatch",
        "management_plane",
        "custom-bmc",
        nil
      )

    wrong_target =
      post_json(
        "/api/v1/access-methods",
        %{"access_method" => %{method | "target_id" => bmc["id"]}},
        context.admin_token
      )

    assert %{"error" => %{"code" => "validation_failed"}} = json_response(wrong_target, 422)

    registered =
      post_data!("/api/v1/access-methods", %{"access_method" => method}, context.admin_token)

    assert registered["method"] == "http"
    assert registered["provider_id"] == provider.id
  end

  test "administrator registers a layered environment and every permitted access path", context do
    boundary =
      post_data!(
        "/api/v1/management-boundaries",
        %{
          "management_boundary" => %{
            "name" => "primary-dc",
            "kind" => "datacenter",
            "facts" => %{"region" => "jp"}
          }
        },
        context.admin_token
      )

    linux = create_target!(context.admin_token, "linux-01", "host", "linux", boundary["id"])

    kubernetes =
      create_target!(
        context.admin_token,
        "cluster-01",
        "cluster",
        "kubernetes",
        boundary["id"]
      )

    bmc =
      create_target!(
        context.admin_token,
        "bmc-01",
        "management_plane",
        "custom-bmc",
        boundary["id"]
      )

    ios_xe =
      create_target!(
        context.admin_token,
        "edge-01",
        "network_device",
        "cisco_ios_xe",
        boundary["id"]
      )

    junos =
      create_target!(
        context.admin_token,
        "edge-future",
        "network_device",
        "custom-network-device",
        boundary["id"]
      )

    identity =
      post_data!(
        "/api/v1/external-identities",
        %{
          "external_identity" => %{
            "target_id" => linux["id"],
            "source" => "zabbix",
            "kind" => "hostid",
            "value" => "10427"
          }
        },
        context.admin_token
      )

    assert identity["target_id"] == linux["id"]

    linux_ssh =
      create_access_method!(
        context,
        linux,
        "linux-ssh",
        "ssh",
        ["observe.command", "effect.command"]
      )

    ssh_exec =
      create_access_method!(
        context,
        junos,
        "ssh",
        "ssh",
        ["observe.command"]
      )

    ios_ssh =
      create_access_method!(
        context,
        ios_xe,
        "ios-ssh",
        "ssh_cli",
        ["observe.command", "effect.command"]
      )

    ios_netconf =
      create_access_method!(
        context,
        ios_xe,
        "ios-netconf",
        "netconf",
        ["observe.config", "effect.config"]
      )

    assert ssh_exec["method"] == "ssh"
    assert Enum.sort([ios_ssh["method"], ios_netconf["method"]]) == ["netconf", "ssh_cli"]
    assert linux_ssh["provider_id"] == context.target_provider.id

    hosted_by = create_relationship!(context.admin_token, kubernetes, linux, "hosted_by")
    managed_by = create_relationship!(context.admin_token, linux, bmc, "managed_by")
    assert hosted_by["source_target_id"] == kubernetes["id"]
    assert managed_by["destination_target_id"] == bmc["id"]

    updated =
      patch_json(
        "/api/v1/targets/#{linux["id"]}",
        %{
          "target" => %{
            "expected_revision" => linux["revision"],
            "operating_instructions" => "Do not modify root"
          }
        },
        context.admin_token
      )
      |> json_response(200)
      |> Map.fetch!("data")

    assert updated["operating_instructions"] == "Do not modify root"

    target_page = get_json("/api/v1/targets?limit=3", context.viewer_token)

    assert %{"data" => first_targets, "page" => %{"next" => cursor}} =
             json_response(target_page, 200)

    assert_operation_response(target_page)

    assert length(first_targets) == 3
    assert is_binary(cursor)

    method_page = get_json("/api/v1/access-methods", context.viewer_token)
    assert %{"data" => methods} = json_response(method_page, 200)
    assert_operation_response(method_page)

    assert Enum.sort(Enum.map(methods, & &1["name"])) ==
             ~w(ios-netconf ios-ssh linux-ssh ssh)

    for response <- [target_page, method_page] do
      refute response.resp_body =~ @provider_secret
      refute response.resp_body =~ "credentials"
      refute response.resp_body =~ "search_text"
    end
  end

  test "revision conflicts, invalid relationships and mutation policy are stable", context do
    target = create_target!(context.admin_token, "linux-02", "host", "linux", nil)

    updated =
      patch_json(
        "/api/v1/targets/#{target["id"]}",
        %{"target" => %{"expected_revision" => 1, "facts" => %{"site" => "tokyo"}}},
        context.admin_token
      )

    assert %{"data" => %{"revision" => 2}} = json_response(updated, 200)
    assert_operation_response(updated)

    stale =
      patch_json(
        "/api/v1/targets/#{target["id"]}",
        %{"target" => %{"expected_revision" => 1, "name" => "stale-name"}},
        context.admin_token
      )

    assert %{"error" => %{"code" => "conflict"}} = json_response(stale, 409)

    invalid_relationship =
      post_json(
        "/api/v1/target-relationships",
        %{
          "relationship" => %{
            "source_target_id" => target["id"],
            "destination_target_id" => target["id"],
            "kind" => "runs_on",
            "facts" => %{}
          }
        },
        context.admin_token
      )

    assert %{"error" => %{"code" => "validation_failed"}} =
             json_response(invalid_relationship, 422)

    for token <- [context.operator_token, context.viewer_token] do
      forbidden =
        post_json(
          "/api/v1/targets",
          %{
            "target" => %{
              "name" => "forbidden",
              "kind" => "host",
              "type_id" => "linux",
              "facts" => %{}
            }
          },
          token
        )

      assert %{"error" => %{"code" => "forbidden"}} = json_response(forbidden, 403)

      shown = get_json("/api/v1/targets/#{target["id"]}", token)
      assert %{"data" => %{"id" => id}} = json_response(shown, 200)
      assert_operation_response(shown)

      assert id == target["id"]
    end
  end

  test "manual and Provider inventory previews expose rows and apply only the accepted digest",
       context do
    csv =
      "external_id,identity_kind,name,kind,type_id,facts_json\r\n" <>
        "server-1,linux,linux-imported,host,linux,\"{\"\"cpu\"\":8}\"\r\n"

    preview =
      post_data!(
        "/api/v1/inventory-imports/manual-preview",
        %{"inventory_import" => %{"source" => "netbox", "csv" => csv}},
        context.admin_token
      )

    assert preview["status"] == "previewed"
    assert preview["row_count"] == 1
    assert preview["error_count"] == 0

    imports = get_json("/api/v1/inventory-imports", context.viewer_token)
    assert %{"data" => [%{"id" => import_id}]} = json_response(imports, 200)
    assert import_id == preview["id"]
    assert_operation_response(imports)

    shown = get_json("/api/v1/inventory-imports/#{preview["id"]}", context.viewer_token)
    assert %{"data" => %{"id" => ^import_id}} = json_response(shown, 200)
    assert_operation_response(shown)

    rows = get_json("/api/v1/inventory-imports/#{preview["id"]}/rows", context.viewer_token)

    assert %{
             "data" => [
               %{
                 "disposition" => "create",
                 "identity_value" => "server-1",
                 "errors" => []
               }
             ],
             "page" => %{"next" => nil}
           } = json_response(rows, 200)

    assert_operation_response(rows)

    wrong_digest =
      post_json(
        "/api/v1/inventory-imports/#{preview["id"]}/apply",
        %{
          "inventory_import" => %{
            "expected_revision" => preview["revision"],
            "expected_digest" => String.duplicate("0", 64)
          }
        },
        context.admin_token
      )

    assert %{"error" => %{"code" => "conflict"}} = json_response(wrong_digest, 409)

    applied =
      post_json(
        "/api/v1/inventory-imports/#{preview["id"]}/apply",
        %{
          "inventory_import" => %{
            "expected_revision" => preview["revision"],
            "expected_digest" => preview["content_digest"]
          }
        },
        context.admin_token
      )

    assert %{"data" => %{"status" => "applied", "revision" => 2}} =
             json_response(applied, 200)

    assert_operation_response(applied)

    assert %{"data" => targets} =
             get_json("/api/v1/targets", context.viewer_token) |> json_response(200)

    assert Enum.any?(targets, &(&1["name"] == "linux-imported"))

    provider_preview =
      post_data!(
        "/api/v1/inventory-imports/provider-preview",
        %{
          "inventory_import" => %{
            "source" => "netbox-provider",
            "provider_id" => context.inventory_provider.id,
            "provider_revision" => context.inventory_provider.revision,
            "scope" => %{}
          }
        },
        context.admin_token
      )

    assert provider_preview["source_type"] == "inventory"
    assert provider_preview["snapshot_status"] == "complete"
    assert provider_preview["row_count"] == 0

    forbidden =
      post_json(
        "/api/v1/inventory-imports/manual-preview",
        %{"inventory_import" => %{"source" => "forbidden", "csv" => csv}},
        context.operator_token
      )

    assert %{"error" => %{"code" => "forbidden"}} = json_response(forbidden, 403)

    for response <- [rows, applied] do
      refute response.resp_body =~ "inventory-provider-secret"
      refute response.resp_body =~ "credentials"
    end
  end

  test "contract rejects malformed Target and inventory inputs before domain actions", context do
    invalid_id = get_json("/api/v1/targets/not-a-uuid", context.viewer_token)

    assert %{"error" => %{"code" => "validation_failed", "details" => %{"fields" => ["id"]}}} =
             json_response(invalid_id, 422)

    assert_operation_response(invalid_id)

    target = create_target!(context.admin_token, "revision-contract", "host", "linux", nil)

    invalid_revision =
      patch_json(
        "/api/v1/targets/#{target["id"]}",
        %{"target" => %{"expected_revision" => 0, "name" => "invalid"}},
        context.admin_token
      )

    assert %{
             "error" => %{
               "code" => "validation_failed",
               "details" => %{"fields" => ["expected_revision"]}
             }
           } = json_response(invalid_revision, 422)

    assert_operation_response(invalid_revision)

    invalid_preview =
      post_json(
        "/api/v1/inventory-imports/manual-preview",
        %{"inventory_import" => %{"source" => "netbox", "csv" => ""}},
        context.admin_token
      )

    assert %{
             "error" => %{
               "code" => "validation_failed",
               "details" => %{"fields" => ["csv"]}
             }
           } = json_response(invalid_preview, 422)

    assert_operation_response(invalid_preview)
  end

  defp create_target!(token, name, kind, type_id, boundary_id) do
    post_data!(
      "/api/v1/targets",
      %{
        "target" => %{
          "name" => name,
          "kind" => kind,
          "type_id" => type_id,
          "facts" => %{},
          "management_boundary_id" => boundary_id
        }
      },
      token
    )
  end

  defp create_access_method!(context, target, name, method, capabilities) do
    post_data!(
      "/api/v1/access-methods",
      %{
        "access_method" => %{
          "target_id" => target["id"],
          "provider_id" => context.target_provider.id,
          "name" => name,
          "method" => method,
          "endpoint" => "ssh://192.0.2.10:22",
          "provider_revision" => context.target_provider.revision,
          "priority" => 100,
          "capabilities" => capabilities
        }
      },
      context.admin_token
    )
  end

  defp create_relationship!(token, source, destination, kind) do
    post_data!(
      "/api/v1/target-relationships",
      %{
        "relationship" => %{
          "source_target_id" => source["id"],
          "destination_target_id" => destination["id"],
          "kind" => kind,
          "facts" => %{}
        }
      },
      token
    )
  end

  defp post_data!(path, body, token) do
    response = post_json(path, body, token)
    assert_operation_response(response)

    response
    |> json_response(201)
    |> Map.fetch!("data")
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

  defp post_json(path, body, token), do: request(:post, path, body, token)
  defp patch_json(path, body, token), do: request(:patch, path, body, token)
  defp get_json(path, token), do: request(:get, path, nil, token)

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
end
