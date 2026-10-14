defmodule Skopos.Targets.IOSXERESTCONFTest do
  use Skopos.DataCase, async: false

  alias Skopos.{Accounts, Providers, Targets}
  alias Skopos.Providers.Target
  alias Skopos.Targets.TargetRequest.Request

  @password "correct horse battery staple"
  @capabilities ["observe.system", "observe.interface", "effect.interface"]

  defmodule Stub do
    import Plug.Conn

    def init(agent), do: agent

    def call(conn, agent) do
      {:ok, body, conn} = read_body(conn)

      authorized? =
        get_req_header(conn, "authorization") == ["Basic " <> Base.encode64("tester:secret")]

      Agent.update(
        agent,
        &Map.update!(&1, :requests, fn requests ->
          [{conn.method, conn.request_path} | requests]
        end)
      )

      if authorized?, do: route(conn, agent, body), else: send_resp(conn, 401, "")
    end

    defp route(%{request_path: "/.well-known/host-meta"} = conn, _agent, _body),
      do:
        conn
        |> put_resp_content_type("application/xrd+xml")
        |> send_resp(
          200,
          ~s(<XRD xmlns="http://docs.oasis-open.org/ns/xri/xrd-1.0"><Link rel="restconf" href="/custom/api"/></XRD>)
        )

    defp route(%{request_path: "/custom/api"} = conn, _agent, _body),
      do: json(conn, 200, %{"ietf-restconf:restconf" => %{}})

    defp route(
           %{
             method: "GET",
             request_path: "/custom/api/data/ietf-restconf-monitoring:restconf-state/capabilities"
           } = conn,
           _agent,
           _body
         ),
         do: json(conn, 200, %{"ietf-restconf-monitoring:capabilities" => %{"capability" => []}})

    defp route(
           %{method: "GET", request_path: "/custom/api/data/Cisco-IOS-XE-native:native/hostname"} =
             conn,
           _agent,
           _body
         ),
         do: json(conn, 200, %{"Cisco-IOS-XE-native:hostname" => "router-one"})

    defp route(
           %{method: "GET", request_path: "/custom/api/data/Cisco-IOS-XE-native:native/version"} =
             conn,
           _agent,
           _body
         ),
         do: json(conn, 200, %{"Cisco-IOS-XE-native:version" => "17.15"})

    defp route(
           %{
             method: "GET",
             request_path: "/custom/api/data/ietf-interfaces:interfaces/interface=Loopback100"
           } = conn,
           agent,
           _body
         ) do
      interface = Agent.get(agent, & &1.interface)
      json(conn, 200, %{"ietf-interfaces:interface" => interface})
    end

    defp route(
           %{
             method: "GET",
             request_path:
               "/custom/api/data/ietf-interfaces:interfaces-state/interface=Loopback100"
           } = conn,
           agent,
           _body
         ) do
      interface = Agent.get(agent, & &1.interface)
      status = if interface["enabled"], do: "up", else: "down"

      json(conn, 200, %{
        "ietf-interfaces:interface" => %{
          "name" => "Loopback100",
          "admin-status" => status,
          "oper-status" => status,
          "statistics" => %{"in-errors" => 2, "out-errors" => 3}
        }
      })
    end

    defp route(
           %{
             method: "PATCH",
             request_path: "/custom/api/data/ietf-interfaces:interfaces/interface=Loopback100"
           } = conn,
           agent,
           body
         ) do
      Process.sleep(Agent.get(agent, & &1.patch_delay_ms))
      %{"ietf-interfaces:interface" => patch} = Jason.decode!(body)
      Agent.update(agent, &%{&1 | interface: Map.merge(&1.interface, Map.delete(patch, "name"))})
      send_resp(conn, 204, "")
    end

    defp route(conn, _agent, _body), do: send_resp(conn, 404, "")

    defp json(conn, status, value) do
      conn
      |> put_resp_content_type("application/yang-data+json")
      |> send_resp(status, Jason.encode!(value))
    end
  end

  setup do
    agent =
      start_supervised!(
        {Agent,
         fn ->
           %{
             requests: [],
             patch_delay_ms: 0,
             interface: %{
               "name" => "Loopback100",
               "description" => "initial",
               "enabled" => true
             }
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
    endpoint = "https://127.0.0.1:#{port}"
    admin = Accounts.bootstrap!("iosxe-admin@example.com", @password, @password)

    operator =
      Accounts.create_user!("iosxe-operator@example.com", @password, :operator, actor: admin)

    provider =
      Providers.create_provider!(
        "ios-xe-restconf",
        :target,
        "ios-xe-restconf",
        %{
          "ca_certificate" => File.read!("test/support/certs/kubernetes_fixture_ca.pem"),
          "request_timeout_ms" => 500
        },
        %{"username" => "tester", "password" => "secret"},
        actor: admin
      )

    checked =
      Skopos.TargetConnectionFixture.check_connection(provider, endpoint, admin)

    assert {:ok, _catalog} = checked

    target =
      Targets.create_target!("router-one", "network_device", "cisco_ios_xe", %{}, nil,
        actor: admin
      )

    method =
      Targets.create_access_method!(
        target.id,
        provider.id,
        "RESTCONF",
        "restconf",
        endpoint,
        provider.revision,
        100,
        @capabilities,
        actor: admin
      )
      |> then(&Targets.check_access_method!(&1.id, &1.revision, %{}, actor: admin))

    %{
      admin: admin,
      operator: operator,
      provider: provider,
      target: target,
      method: method,
      agent: agent
    }
  end

  test "public RESTCONF route observes, applies, rejects stale state and verifies freshly",
       context do
    assert %Target.Capabilities{observations: observations, effects: effects} =
             Providers.target_capabilities!(
               context.provider.id,
               %Target.CapabilitiesRequest{
                 provider_revision: context.provider.revision,
                 connection: %Target.Connection{endpoint: context.method.endpoint}
               },
               %{},
               actor: context.admin
             )

    assert Enum.map(observations, & &1.operation) == [
             "ios_xe.system.inspect",
             "ios_xe.interface.inspect",
             "request.observe"
           ]

    assert Enum.map(effects, & &1.operation) == [
             "ios_xe.interface.description.set",
             "ios_xe.interface.admin_state.set",
             "request.execute"
           ]

    assert Enum.map(Enum.take(effects, 2), & &1.evidence_requirements) == [
             [
               %Target.EvidenceRequirement{
                 parameter: "expected_description",
                 fact: "description",
                 observation: "ios_xe.interface.inspect"
               }
             ],
             [
               %Target.EvidenceRequirement{
                 parameter: "expected_enabled",
                 fact: "enabled",
                 observation: "ios_xe.interface.inspect"
               }
             ]
           ]

    tools = Map.new(observations, &{&1.operation, &1})
    interface_tool = tools["ios_xe.interface.inspect"]

    assert MapSet.new(Map.keys(interface_tool.verification_schema["properties"])) ==
             MapSet.new(
               ~w(name description enabled admin_status oper_status input_errors output_errors)
             )

    system = observe!(context, "observe.system", "ios_xe.system.inspect", %{})
    assert_schema_accepts!(tools["ios_xe.system.inspect"].output_schema, system.facts)
    assert system.facts == %{"hostname" => "router-one", "version" => "17.15"}

    before =
      observe!(context, "observe.interface", "ios_xe.interface.inspect", %{
        "interface" => "Loopback100"
      })

    assert_schema_accepts!(interface_tool.output_schema, before.facts)
    assert before.facts["description"] == "initial"
    assert before.facts["input_errors"] == 2

    assert %Target.EffectResult{status: :applied} =
             effect!(context, "ios_xe.interface.description.set", %{
               "description" => "changed",
               "expected_description" => "initial"
             })

    assert %Target.Verification{status: :verified} =
             verify!(context, %{"description" => "changed"})

    assert %Target.EffectResult{status: :failed, details: %{"category" => "stale"}} =
             effect!(context, "ios_xe.interface.description.set", %{
               "description" => "wrong",
               "expected_description" => "initial"
             })

    assert %Target.EffectResult{status: :applied} =
             effect!(context, "ios_xe.interface.admin_state.set", %{
               "enabled" => false,
               "expected_enabled" => true
             })

    assert %Target.Verification{status: :verified} =
             verify!(context, %{"enabled" => false, "admin_status" => "down"})

    Agent.update(context.agent, &%{&1 | patch_delay_ms: 1_000})

    assert %Target.EffectResult{status: :unknown} =
             effect!(context, "ios_xe.interface.admin_state.set", %{
               "enabled" => true,
               "expected_enabled" => false
             })
  end

  test "invalid selectors and unknown configuration keys stop before network access", context do
    count = length(requests(context))

    invalid =
      target_request(
        context,
        :observation,
        "observe.interface",
        "ios_xe.interface.inspect",
        %{"interface" => "Loopback100\nshutdown"},
        %{}
      )

    assert {:error, _error} =
             Targets.clear_target_request(invalid, actor: context.operator)

    assert length(requests(context)) == count

    assert {:error, :invalid_configuration} =
             Skopos.Targets.Profiles.IOSXE.RESTCONF.build(
               %{
                 "ca_certificate" => File.read!("test/support/certs/kubernetes_fixture_ca.pem"),
                 "insecure" => true
               },
               %{"username" => "tester", "password" => "secret"}
             )

    assert {:ok, state} =
             Skopos.Targets.Profiles.IOSXE.RESTCONF.build(
               %{"ca_certificate" => File.read!("test/support/certs/kubernetes_fixture_ca.pem")},
               %{"username" => "tester", "password" => "secret"}
             )

    wrong_hostname = String.replace(context.method.endpoint, "127.0.0.1", "127.0.0.2")

    assert {:error, :unreachable, _message} =
             Skopos.Targets.Profiles.IOSXE.RESTCONF.check(state, %{"endpoint" => wrong_hostname})
  end

  test "registered IOS XE Method dispatches an exact generic request through shared RESTCONF",
       context do
    method =
      Targets.update_access_method!(
        context.method,
        context.method.revision,
        %{
          capabilities: @capabilities ++ ["request.restconf.observe", "request.restconf.effect"]
        },
        actor: context.admin
      )

    context = %{context | method: method}
    parameters = %{"method" => "GET", "path" => "/data/Cisco-IOS-XE-native:native/hostname"}

    read =
      target_request(
        context,
        :observation,
        "request.restconf.observe",
        "request.observe",
        %{},
        parameters
      )

    clearance = Targets.clear_target_request!(read, actor: context.operator)

    assert %Target.Observation{facts: %{"http_status" => 200, "body" => body}} =
             Targets.dispatch_target_observation!(clearance, %{}, actor: context.operator)

    assert Jason.decode!(body) == %{"Cisco-IOS-XE-native:hostname" => "router-one"}

    patch =
      target_request(context, :effect, "request.restconf.effect", "request.execute", %{}, %{
        "method" => "PATCH",
        "path" => "/data/ietf-interfaces:interfaces/interface=Loopback100",
        "body" => ~s({"ietf-interfaces:interface":{"description":"generic-change"}})
      })

    assert %Target.EffectResult{status: :applied} =
             patch
             |> Targets.clear_target_request!(actor: context.operator)
             |> Targets.dispatch_target_effect!(%{}, actor: context.operator, authorize?: false)

    assert %Target.Verification{status: :verified} =
             verify!(context, %{"description" => "generic-change"})

    before = length(requests(context))
    disguised = %{read | parameters: patch.parameters, authority_mode: :readonly}
    assert {:error, _} = Targets.clear_target_request(disguised, actor: context.operator)
    assert length(requests(context)) == before
  end

  defp observe!(context, capability, operation, selectors) do
    target_request(context, :observation, capability, operation, selectors, %{})
    |> Targets.clear_target_request!(actor: context.operator)
    |> Targets.dispatch_target_observation!(%{}, actor: context.operator)
  end

  defp effect!(context, operation, parameters) do
    target_request(
      context,
      :effect,
      "effect.interface",
      operation,
      %{"interface" => "Loopback100"},
      parameters
    )
    |> Targets.clear_target_request!(actor: context.operator)
    |> Targets.dispatch_target_effect!(%{}, actor: context.operator, authorize?: false)
  end

  defp verify!(context, expected) do
    target_request(
      context,
      :verification,
      "observe.interface",
      "ios_xe.interface.inspect",
      %{"interface" => "Loopback100"},
      %{},
      expected
    )
    |> Targets.clear_target_request!(actor: context.operator)
    |> Targets.dispatch_target_verification!(%{}, actor: context.operator)
  end

  defp target_request(
         context,
         kind,
         capability,
         operation,
         selectors,
         parameters,
         expected \\ %{}
       ) do
    struct!(Request,
      kind: kind,
      authority_mode: :full_access,
      target_id: context.target.id,
      target_revision: context.target.revision,
      access_method_id: context.method.id,
      access_method_revision: context.method.revision,
      capability: capability,
      operation: operation,
      selectors: selectors,
      parameters: parameters,
      operation_id: if(kind in [:effect, :verification], do: Ecto.UUID.generate()),
      idempotency_key: if(kind == :effect, do: Ecto.UUID.generate()),
      expected: expected
    )
  end

  defp requests(context), do: Agent.get(context.agent, & &1.requests)

  defp assert_schema_accepts!(schema, facts) do
    assert {:ok, root} = JSV.build(schema, warnings: :silent)
    assert {:ok, _validated} = JSV.validate(facts, root, cast: false)
  end
end
