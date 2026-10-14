defmodule Skopos.InventoryImportTest do
  use Skopos.DataCase, async: false

  alias Skopos.{Accounts, Providers, Targets}
  alias Skopos.Providers.Inventory

  @password "correct horse battery staple"
  @headers ~w(external_id identity_kind name kind type_id facts_json)

  setup do
    admin =
      Accounts.bootstrap!("inventory-import-admin@example.com", @password, @password,
        authorize?: true
      )

    operator =
      Accounts.create_user!("inventory-import-operator@example.com", @password, :operator,
        actor: admin
      )

    provider =
      Providers.create_provider!(
        "inventory-import-provider",
        :inventory,
        "fixture-inventory",
        %{"source" => "test-inventory"},
        %{"token" => "inventory-token"},
        actor: admin
      )
      |> then(&Providers.check_provider!(&1.id, 1, %{}, actor: admin))
      |> then(&Providers.enable_provider!(&1, 1, actor: admin))

    %{admin: admin, operator: operator, provider: provider}
  end

  test "manual preview applies stable identities without replacing manual fields or matching by IP",
       context do
    existing =
      Targets.create_target!(
        "manual-name",
        "host",
        "linux",
        %{"owner" => "operations", "ip" => "192.0.2.10"},
        nil,
        actor: context.admin
      )

    same_ip =
      Targets.create_target!(
        "same-ip",
        "host",
        "custom-os",
        %{"ip" => "192.0.2.20", "owner" => "network"},
        nil,
        actor: context.admin
      )

    Targets.create_external_identity!(existing.id, "netbox", "linux", "server-1",
      actor: context.admin
    )

    preview =
      Targets.preview_manual_inventory!(
        "netbox",
        csv([
          row("server-1", "updated-name", %{"ip" => "192.0.2.99", "cpu" => 8}),
          row("server-2", "new-name", %{"ip" => "192.0.2.20"})
        ]),
        actor: context.admin
      )

    assert preview.status == :previewed
    assert preview.row_count == 2
    assert preview.error_count == 0

    assert Enum.map(rows(preview, context.admin), & &1.disposition) == [:update, :create]

    applied =
      Targets.apply_inventory_import!(
        preview.id,
        preview.revision,
        preview.content_digest,
        actor: context.admin
      )

    assert applied.status == :applied
    assert applied.revision == 2

    refreshed = Targets.get_target!(existing.id, actor: context.admin)
    assert refreshed.name == "manual-name"
    assert refreshed.kind == "host"
    assert refreshed.type_id == "linux"
    assert refreshed.facts["owner"] == "operations"
    assert refreshed.facts["ip"] == "192.0.2.10"
    assert refreshed.facts["inventory"]["netbox"] == %{"ip" => "192.0.2.99", "cpu" => 8}

    untouched = Targets.get_target!(same_ip.id, actor: context.admin)
    assert untouched.facts == %{"ip" => "192.0.2.20", "owner" => "network"}

    identities = Targets.list_external_identities!(actor: context.admin)
    created_identity = Enum.find(identities, &(&1.value == "server-2"))
    refute is_nil(created_identity)
    refute created_identity.target_id == same_ip.id

    retried =
      Targets.apply_inventory_import!(
        preview.id,
        preview.revision,
        preview.content_digest,
        actor: context.admin
      )

    assert retried.id == applied.id
    assert retried.revision == applied.revision
    assert Enum.count(Targets.list_external_identities!(actor: context.admin)) == 2
  end

  test "a large preview reports duplicate and oversized rows and cannot be applied", context do
    ordinary_rows =
      Enum.map(1..1_000, fn number ->
        row("server-#{number}", "server-#{number}", %{"ordinal" => number})
      end)

    preview =
      Targets.preview_manual_inventory!(
        "large-source",
        csv(
          ordinary_rows ++
            [
              row("server-1", "duplicate", %{}),
              row("oversized", "oversized", %{"payload" => String.duplicate("x", 66_000)})
            ]
        ),
        actor: context.admin
      )

    assert preview.row_count == 1_002
    assert preview.error_count == 3

    error_rows = Enum.filter(rows(preview, context.admin), &(&1.disposition == :error))
    assert length(error_rows) == 3
    assert Enum.count(error_rows, &(&1.errors == ["duplicate stable identity"])) == 2
    assert Enum.any?(error_rows, &("candidate exceeds 64 KiB" in &1.errors))

    assert {:error, _error} =
             Targets.apply_inventory_import(
               preview.id,
               preview.revision,
               preview.content_digest,
               actor: context.admin
             )

    assert Targets.list_targets!(actor: context.admin) == []
  end

  test "apply rejects a changed target and rolls back earlier rows", context do
    existing =
      Targets.create_target!("existing", "host", "linux", %{}, nil, actor: context.admin)

    Targets.create_external_identity!(existing.id, "cmdb", "linux", "existing-id",
      actor: context.admin
    )

    preview =
      Targets.preview_manual_inventory!(
        "cmdb",
        csv([
          row("new-id", "new-target", %{}),
          row("existing-id", "existing", %{"state" => "new"})
        ]),
        actor: context.admin
      )

    Targets.update_target!(existing, existing.revision, %{facts: %{"changed" => true}},
      actor: context.admin
    )

    assert {:error, _error} =
             Targets.apply_inventory_import(
               preview.id,
               preview.revision,
               preview.content_digest,
               actor: context.admin
             )

    refute Enum.any?(
             Targets.list_external_identities!(actor: context.admin),
             &(&1.value == "new-id")
           )

    assert {:error, _error} =
             Targets.apply_inventory_import(
               preview.id,
               preview.revision,
               String.duplicate("0", 64),
               actor: context.admin
             )
  end

  test "apply rejects a persisted preview whose rows no longer match its digest", context do
    preview =
      Targets.preview_manual_inventory!(
        "cmdb",
        csv([row("server-1", "server-1", %{})]),
        actor: context.admin
      )

    Repo.query!(
      "UPDATE inventory_import_rows SET candidate = jsonb_set(candidate, '{name}', '\"tampered\"') WHERE inventory_import_id::text = $1",
      [preview.id]
    )

    assert {:error, _error} =
             Targets.apply_inventory_import(
               preview.id,
               preview.revision,
               preview.content_digest,
               actor: context.admin
             )

    assert Targets.list_targets!(actor: context.admin) == []
  end

  test "a partial provider snapshot can add observed rows but never removes missing targets",
       context do
    missing =
      Targets.create_target!("missing-from-snapshot", "host", "linux", %{}, nil,
        actor: context.admin
      )

    Targets.create_external_identity!(missing.id, "netbox", "linux", "missing-server",
      actor: context.admin
    )

    request = %Inventory.Request{provider_revision: context.provider.revision, scope: %{}}

    invocation = %{
      test_pid: self(),
      respond: fn
        nil ->
          {:ok,
           %Inventory.Page{
             records: [record("observed-server")],
             source_version: "v1",
             next_cursor: "next"
           }}

        "next" ->
          {:error, :retryable, "source unavailable"}
      end
    }

    preview =
      Targets.preview_provider_inventory!(
        "netbox",
        context.provider.id,
        request,
        invocation,
        actor: context.admin
      )

    assert preview.snapshot_status == :partial
    assert preview.row_count == 1
    assert preview.error_count == 0

    Targets.apply_inventory_import!(
      preview.id,
      preview.revision,
      preview.content_digest,
      actor: context.admin
    )

    assert Targets.get_target!(missing.id, actor: context.admin).active

    values =
      Targets.list_external_identities!(actor: context.admin)
      |> Enum.map(& &1.value)
      |> Enum.sort()

    assert values == ["missing-server", "observed-server"]
  end

  test "only an administrator can preview or apply imports", context do
    assert {:error, %Ash.Error.Forbidden{}} =
             Targets.preview_manual_inventory(
               "netbox",
               csv([row("server-1", "server-1", %{})]),
               actor: context.operator
             )
  end

  defp rows(import, actor) do
    Targets.list_inventory_import_rows!(actor: actor)
    |> Enum.filter(&(&1.inventory_import_id == import.id))
    |> Enum.sort_by(& &1.position)
  end

  defp csv(rows) do
    [@headers | rows]
    |> NimbleCSV.RFC4180.dump_to_iodata()
    |> IO.iodata_to_binary()
  end

  defp row(id, name, facts) do
    [id, "linux", name, "host", "linux", Jason.encode!(facts)]
  end

  defp record(id) do
    %Inventory.Record{
      external_id: id,
      kind: :linux,
      source_ref: "inventory:#{id}",
      attributes: %{name: id, kind: "host", type_id: "linux", ip: "192.0.2.30"}
    }
  end
end
