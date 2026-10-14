defmodule Skopos.Inventories.NetBoxAPITest do
  use Skopos.DataCase, async: false

  import Plug.Conn

  alias Skopos.{Accounts, Providers}
  alias Skopos.Providers.Inventory

  @password "correct horse battery staple"
  @token "nbt_fixture.token"

  defmodule Stub do
    import Plug.Conn

    def init(agent), do: agent

    def call(conn, agent) do
      conn = fetch_query_params(conn)

      if get_req_header(conn, "authorization") == ["Bearer nbt_fixture.token"] do
        route(conn, agent)
      else
        send_resp(conn, 401, "")
      end
    end

    defp route(%{method: "GET", request_path: "/api/dcim/devices/"} = conn, agent) do
      state = Agent.get(agent, & &1)
      offset = integer(conn.query_params["offset"], 0)

      if state.fail_offset == offset do
        send_resp(conn, 503, "")
      else
        limit = integer(conn.query_params["limit"], 100)

        devices =
          state.devices
          |> Enum.filter(&filter?(&1, conn.query_params))
          |> Enum.sort_by(& &1["id"])

        results = Enum.slice(devices, offset, limit)

        next =
          if offset + length(results) < length(devices) do
            "https://netbox.example/api/dcim/devices/?limit=#{limit}&offset=#{offset + length(results)}"
          end

        json(conn, 200, %{"count" => length(devices), "next" => next, "results" => results})
      end
    end

    defp route(
           %{method: "GET", request_path: "/api/virtualization/virtual-machines/"} = conn,
           agent
         ) do
      virtual_machines = Agent.get(agent, & &1.virtual_machines)

      json(conn, 200, %{
        "count" => length(virtual_machines),
        "next" => nil,
        "results" => virtual_machines
      })
    end

    defp route(conn, _agent), do: send_resp(conn, 404, "")

    defp filter?(device, %{"tenant_id" => tenant_id}) do
      to_string(get_in(device, ["tenant", "id"])) == tenant_id
    end

    defp filter?(_device, _params), do: true

    defp integer(nil, default), do: default
    defp integer(value, _default), do: String.to_integer(value)

    defp json(conn, status, value) do
      conn
      |> put_resp_header("api-version", "4.7")
      |> put_resp_content_type("application/json")
      |> send_resp(status, Jason.encode!(value))
    end
  end

  setup do
    agent =
      start_supervised!(
        {Agent,
         fn ->
           %{
             fail_offset: nil,
             devices: [
               device(1, "router-one", 1),
               device(2, "other-tenant", 2),
               device(3, "server-one", 1)
             ],
             virtual_machines: [virtual_machine(4, "vm-one")]
           }
         end}
      )

    server =
      start_supervised!(
        {Bandit,
         plug: {Stub, agent},
         scheme: :https,
         port: 0,
         certfile: Path.expand("test/support/certs/kubernetes_fixture.pem"),
         keyfile: Path.expand("test/support/certs/kubernetes_fixture_key.pem"),
         startup_log: false}
      )

    {:ok, {_address, port}} = ThousandIsland.listener_info(server)
    admin = Accounts.bootstrap!("netbox-admin@example.com", @password, @password)

    provider =
      Providers.create_provider!(
        "netbox",
        :inventory,
        "netbox-api",
        %{
          "base_url" => "https://127.0.0.1:#{port}/api/",
          "ca_certificate" => File.read!("test/support/certs/kubernetes_fixture_ca.pem")
        },
        %{"token" => @token},
        actor: admin
      )

    scope = %{
      "resource" => "devices",
      "filters" => %{"tenant_id" => 1},
      "page_size" => 1
    }

    checked = Providers.check_provider!(provider.id, provider.revision, scope, actor: admin)
    provider = Providers.enable_provider!(checked, checked.revision, actor: admin)

    %{admin: admin, provider: provider, agent: agent, scope: scope}
  end

  test "the public inventory route scopes pages and preserves safe partial results", context do
    snapshot = snapshot(context)

    assert snapshot.status == :complete
    assert snapshot.source_version == "netbox-api:4.7"
    assert Enum.map(snapshot.records, & &1.external_id) == ["dcim.device:1", "dcim.device:3"]

    assert Enum.map(snapshot.records, & &1.source_ref) == [
             "/api/dcim/devices/1/",
             "/api/dcim/devices/3/"
           ]

    assert hd(snapshot.records).attributes["name"] == "router-one"
    assert hd(snapshot.records).attributes["kind"] == "dcim.device"
    assert hd(snapshot.records).attributes["platform"] == "ios-xe"
    assert hd(snapshot.records).attributes["last_updated"] == "2026-09-18T00:00:01Z"

    virtual_machines =
      snapshot(context, %{
        "resource" => "virtual_machines",
        "filters" => %{},
        "page_size" => 10
      })

    assert [%Inventory.Record{external_id: "virtualization.virtualmachine:4"} = virtual_machine] =
             virtual_machines.records

    assert virtual_machine.kind == :virtual_machine
    assert virtual_machine.attributes["kind"] == "virtualization.virtualmachine"

    Agent.update(context.agent, fn state ->
      %{state | devices: [device(1, "router-renamed", 1), device(2, "other-tenant", 2)]}
    end)

    changed = snapshot(context)
    assert Enum.map(changed.records, & &1.external_id) == ["dcim.device:1"]
    assert hd(changed.records).attributes["name"] == "router-renamed"
    refute Map.has_key?(Map.from_struct(changed), :deletions)

    Agent.update(context.agent, fn state ->
      %{
        state
        | devices: [device(1, "router-renamed", 1), device(3, "server-one", 1)],
          fail_offset: 1
      }
    end)

    partial = snapshot(context)
    assert partial.status == :partial
    assert Enum.map(partial.records, & &1.external_id) == ["dcim.device:1"]
    assert partial.next_cursor == "1"
    assert {:retryable, "NetBox endpoint is temporarily unavailable"} = partial.error
  end

  defp snapshot(context, scope \\ nil) do
    request = %Inventory.Request{
      provider_revision: context.provider.revision,
      scope: scope || context.scope
    }

    Providers.inventory_snapshot!(context.provider.id, request, %{}, actor: context.admin)
  end

  defp device(id, name, tenant_id) do
    %{
      "id" => id,
      "display" => name,
      "name" => name,
      "status" => %{"value" => "active", "label" => "Active"},
      "tenant" => %{"id" => tenant_id, "name" => "tenant-#{tenant_id}"},
      "platform" => %{"name" => "IOS XE", "slug" => "ios-xe"},
      "serial" => "serial-#{id}",
      "created" => "2026-09-17T00:00:00Z",
      "last_updated" => "2026-09-18T00:00:01Z",
      "custom_fields" => %{},
      "tags" => []
    }
  end

  defp virtual_machine(id, name) do
    device(id, name, 1)
    |> Map.merge(%{"vcpus" => 4, "memory" => 8_192, "disk" => 100})
  end
end
