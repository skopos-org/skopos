defmodule Skopos.Providers.InventoryTest do
  use Skopos.DataCase, async: false

  alias Skopos.Accounts
  alias Skopos.Providers
  alias Skopos.Providers.Inventory

  @password "correct horse battery staple"
  @token "inventory-provider-secret"

  setup do
    admin =
      Accounts.bootstrap!("inventory-admin@example.com", @password, @password, authorize?: true)

    provider =
      Providers.create_provider!(
        "inventory-provider",
        :inventory,
        "fixture-inventory",
        %{"source" => "test-inventory"},
        %{"token" => @token},
        actor: admin
      )
      |> then(&Providers.check_provider!(&1.id, 1, %{}, actor: admin))
      |> then(&Providers.enable_provider!(&1, 1, actor: admin))

    %{admin: admin, provider: provider}
  end

  test "a stable paginated source produces one complete snapshot", context do
    first = record("server-1")
    second = record("server-2")

    respond = fn
      nil -> {:ok, %Inventory.Page{records: [first], source_version: "v1", next_cursor: "2"}}
      "2" -> {:ok, %Inventory.Page{records: [second], source_version: "v1"}}
    end

    request = request(context.provider.revision)
    snapshot = snapshot!(context, request, respond)

    assert snapshot.status == :complete
    assert snapshot.source_version == "v1"
    assert Enum.map(snapshot.records, & &1.external_id) == ["server-1", "server-2"]
    assert_receive {:page, %{token: @token}, ^request, nil}
    assert_receive {:page, %{token: @token}, ^request, "2"}
  end

  test "page failure preserves prior facts as a resumable redacted partial snapshot", context do
    first = record("server-1")

    respond = fn
      nil -> {:ok, %Inventory.Page{records: [first], source_version: "v1", next_cursor: "2"}}
      "2" -> {:error, :retryable, "credential #{@token} unavailable"}
    end

    snapshot = snapshot!(context, request(context.provider.revision), respond)

    assert snapshot.status == :partial
    assert snapshot.records == [first]
    assert snapshot.source_version == "v1"
    assert snapshot.next_cursor == "2"
    assert snapshot.error == {:retryable, "credential [REDACTED] unavailable"}
    refute inspect(snapshot) =~ @token
  end

  test "a source version change excludes the mixed page", context do
    first = record("server-1")
    changed = record("server-changed")

    respond = fn
      nil -> {:ok, %Inventory.Page{records: [first], source_version: "v1", next_cursor: "2"}}
      "2" -> {:ok, %Inventory.Page{records: [changed], source_version: "v2"}}
    end

    snapshot = snapshot!(context, request(context.provider.revision), respond)

    assert snapshot.status == :partial
    assert snapshot.records == [first]
    assert snapshot.source_version == "v1"
    assert {:source_changed, %{expected: "v1", received: "v2"}} = snapshot.error
  end

  test "missing source rows remain facts without deletion or overwrite directives", context do
    remaining = record("server-1", %{detail: @token})

    snapshot =
      snapshot!(context, request(context.provider.revision), fn nil ->
        {:ok, %Inventory.Page{records: [remaining], source_version: "v2"}}
      end)

    assert snapshot.status == :complete

    assert [%Inventory.Record{external_id: "server-1", attributes: %{detail: "[REDACTED]"}}] =
             snapshot.records

    refute Map.has_key?(Map.from_struct(snapshot), :deletions)
    refute Map.has_key?(Map.from_struct(snapshot), :updates)
  end

  test "page and cancellation bounds return cursors without another fetch", context do
    bounded = %Inventory.Request{
      provider_revision: context.provider.revision,
      scope: %{site: "dc-1"},
      max_pages: 1
    }

    snapshot =
      snapshot!(context, bounded, fn nil ->
        {:ok,
         %Inventory.Page{
           records: [record("server-1")],
           source_version: "v1",
           next_cursor: "2"
         }}
      end)

    assert snapshot.status == :partial
    assert snapshot.next_cursor == "2"
    assert {:page_limit, _message} = snapshot.error
    refute_receive {:page, _, _, "2"}

    Process.put(:cancel_inventory, false)

    invocation = %{
      test_pid: self(),
      cancelled?: fn -> Process.get(:cancel_inventory) end,
      respond: fn
        nil ->
          Process.put(:cancel_inventory, true)

          {:ok,
           %Inventory.Page{
             records: [record("server-1")],
             source_version: "v1",
             next_cursor: "2"
           }}
      end
    }

    cancelled =
      Providers.inventory_snapshot!(
        context.provider.id,
        request(context.provider.revision),
        invocation,
        actor: context.admin
      )

    assert cancelled.status == :partial
    assert cancelled.next_cursor == "2"
    assert {:cancelled, _message} = cancelled.error
    refute_receive {:page, _, _, "2"}
  end

  test "scope and page payloads are bounded", context do
    oversized_scope = %Inventory.Request{
      provider_revision: context.provider.revision,
      scope: %{"payload" => String.duplicate("x", 65_537)}
    }

    assert {:error, request_error} =
             Providers.inventory_snapshot(
               context.provider.id,
               oversized_scope,
               %{test_pid: self(), respond: fn _cursor -> flunk("invalid scope was fetched") end},
               actor: context.admin
             )

    assert inventory_error(request_error).message == "Inventory request is invalid"
    refute_receive {:page, _, _, _}

    oversized_page =
      snapshot!(context, request(context.provider.revision), fn nil ->
        {:ok,
         %Inventory.Page{
           records: Enum.map(1..1_001, &record("server-#{&1}")),
           source_version: "v1"
         }}
      end)

    assert oversized_page.status == :partial
    assert oversized_page.records == []
    assert {:failed, "Invalid inventory page"} = oversized_page.error
  end

  defp snapshot!(context, request, respond) do
    Providers.inventory_snapshot!(
      context.provider.id,
      request,
      %{test_pid: self(), respond: respond},
      actor: context.admin
    )
  end

  defp request(provider_revision) do
    %Inventory.Request{provider_revision: provider_revision, scope: %{site: "dc-1"}}
  end

  defp record(external_id, attributes \\ %{}) do
    %Inventory.Record{
      external_id: external_id,
      kind: :linux,
      source_ref: "inventory:#{external_id}",
      attributes: Map.put_new(attributes, :name, external_id)
    }
  end

  defp inventory_error(%{errors: errors}) do
    Enum.find_value(errors, fn
      %Inventory.Error{} = error -> error
      nested when is_map(nested) -> inventory_error(nested)
      _other -> nil
    end)
  end

  defp inventory_error(_error), do: nil
end
