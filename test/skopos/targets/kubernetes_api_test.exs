defmodule Skopos.Targets.KubernetesAPITest do
  use Skopos.DataCase, async: false

  alias Skopos.{Accounts, Cases, Providers, Targets}
  alias Skopos.Providers.Target
  alias Skopos.Targets.Adapters.Kubernetes
  alias Skopos.Targets.TargetRequest.Request

  @password "correct horse battery staple"
  @namespace "bounded-namespace"
  @capabilities ["request.kubernetes.observe", "request.kubernetes.effect"]

  defmodule KubernetesStub do
    import Plug.Conn

    @namespace "bounded-namespace"

    def init(agent), do: agent

    def call(conn, agent) do
      conn = fetch_query_params(conn)
      {:ok, body, conn} = read_body(conn)

      request = %{
        method: conn.method,
        path: conn.request_path,
        query: conn.query_params,
        body: body,
        content_type: get_req_header(conn, "content-type"),
        accept: get_req_header(conn, "accept"),
        authorized?: get_req_header(conn, "authorization") == ["Bearer static-test-token"]
      }

      Agent.update(agent, &Map.update!(&1, :requests, fn requests -> [request | requests] end))

      if request.authorized? do
        route(conn, agent, request)
      else
        failure(conn, 401, "Unauthorized", "missing bearer token")
      end
    end

    defp route(%{method: "GET", request_path: "/api"} = conn, _agent, _request),
      do: json(conn, 200, %{"kind" => "APIVersions", "versions" => ["v1"]})

    defp route(%{method: "GET"} = conn, agent, %{query: %{"watch" => "true"}}) do
      bytes = Agent.get(agent, & &1.watch_body)
      status = Agent.get(agent, &Map.get(&1, :watch_status, 200))
      media = Agent.get(agent, &Map.get(&1, :watch_media, "application/json"))
      conn = put_resp_content_type(conn, media)

      if status == 200 do
        conn = send_chunked(conn, status)
        first = min(17, byte_size(bytes))
        conn = if first > 0, do: elem(chunk(conn, binary_part(bytes, 0, first)), 1), else: conn

        conn =
          if byte_size(bytes) > first,
            do: elem(chunk(conn, binary_part(bytes, first, byte_size(bytes) - first)), 1),
            else: conn

        Process.sleep(Agent.get(agent, &Map.get(&1, :watch_delay_ms, 0)))
        if Agent.get(agent, &Map.get(&1, :watch_drop, false)), do: Process.exit(self(), :kill)
        conn
      else
        send_resp(conn, status, bytes)
      end
    end

    defp route(
           %{request_path: "/apis/files.example/v1/namespaces/#{@namespace}/bundles/one/content"} =
             conn,
           _agent,
           request
         ) do
      conn = put_resp_content_type(conn, "application/octet-stream")

      case request.query["transfer"] do
        "interrupted" ->
          conn = send_chunked(conn, 200)
          {:ok, _conn} = chunk(conn, <<255, 0>>)
          Process.sleep(50)
          Process.exit(self(), :kill)

        "delayed" ->
          conn = send_chunked(conn, 200)
          {:ok, conn} = chunk(conn, <<255, 0>>)
          Process.sleep(1_000)
          conn

        _ ->
          bytes = if request.method == "GET", do: <<255, 0, 1, 2, 255>>, else: request.body
          send_resp(conn, 200, bytes)
      end
    end

    defp route(%{request_path: "/apis/acme.example/v9/racks/rack-a"} = conn, agent, request) do
      if request.method == "PATCH" do
        patch = Jason.decode!(request.body)
        Agent.update(agent, &Map.put(&1, :rack_mode, patch["spec"]["mode"]))
      end

      json(conn, 200, %{
        "apiVersion" => "acme.example/v9",
        "kind" => "Rack",
        "metadata" => %{"name" => "rack-a", "resourceVersion" => "12"},
        "spec" => %{"mode" => Agent.get(agent, &Map.get(&1, :rack_mode, "idle"))}
      })
    end

    defp route(
           %{request_path: "/apis/example.com/v1/namespaces/#{@namespace}/widgets/context-probe"} =
             conn,
           _agent,
           _request
         ) do
      Process.sleep(300)
      json(conn, 200, %{"kind" => "Widget", "spec" => %{"mode" => "active"}})
    end

    defp route(
           %{method: "GET", request_path: "/api/v1/namespaces/other/pods"} = conn,
           _agent,
           _request
         ),
         do: json(conn, 200, %{"kind" => "PodList", "items" => []})

    defp route(%{method: "GET", request_path: "/api/v1"} = conn, _agent, _request) do
      json(conn, 200, %{
        "apiVersion" => "v1",
        "groupVersion" => "v1",
        "kind" => "APIResourceList",
        "resources" => [
          resource("pods", "Pod", ~w(get list watch)),
          resource("pods/log", "Pod", ~w(get)),
          resource("events", "Event", ~w(get list))
        ]
      })
    end

    defp route(%{method: "GET", request_path: "/apis/apps/v1"} = conn, _agent, _request) do
      json(conn, 200, %{
        "apiVersion" => "v1",
        "groupVersion" => "apps/v1",
        "kind" => "APIResourceList",
        "resources" => [resource("deployments", "Deployment", ~w(get list patch))]
      })
    end

    defp route(%{method: "GET", request_path: "/apis/example.com/v1"} = conn, _agent, _request) do
      json(conn, 200, %{
        "apiVersion" => "v1",
        "groupVersion" => "example.com/v1",
        "kind" => "APIResourceList",
        "resources" => [resource("widgets", "Widget", ~w(get list create update patch))]
      })
    end

    defp route(
           %{
             method: "POST",
             request_path: "/apis/example.com/v1/namespaces/#{@namespace}/widgets"
           } = conn,
           agent,
           %{body: body}
         ) do
      widget = Jason.decode!(body)
      Agent.update(agent, &Map.put(&1, :created_widget, widget))
      json(conn, 201, widget)
    end

    defp route(
           %{
             method: "PUT",
             request_path: "/apis/example.com/v1/namespaces/#{@namespace}/widgets/widget-one"
           } = conn,
           agent,
           %{body: body}
         ) do
      widget = Jason.decode!(body)
      Agent.update(agent, &Map.put(&1, :widget, widget))
      json(conn, 200, widget)
    end

    defp route(
           %{
             method: "GET",
             request_path: "/apis/example.com/v1/namespaces/#{@namespace}/widgets/widget-one"
           } = conn,
           agent,
           _request
         ) do
      json(conn, 200, Agent.get(agent, & &1.widget))
    end

    defp route(
           %{
             method: "PATCH",
             request_path: "/apis/example.com/v1/namespaces/#{@namespace}/widgets/widget-one"
           } = conn,
           agent,
           %{body: body}
         ) do
      patch = Jason.decode!(body)

      widget =
        Agent.get_and_update(agent, fn state ->
          current = state.widget

          updated =
            current
            |> put_in(["metadata", "resourceVersion"], "8")
            |> put_in(["spec", "mode"], get_in(patch, ["spec", "mode"]))

          {updated, %{state | widget: updated}}
        end)

      json(conn, 200, widget)
    end

    defp route(
           %{method: "GET", request_path: "/api/v1/namespaces/#{@namespace}/pods"} = conn,
           _agent,
           _request
         ) do
      json(conn, 200, %{
        "apiVersion" => "v1",
        "kind" => "PodList",
        "metadata" => %{"resourceVersion" => "22"},
        "items" => [pod("pod-one", "22")]
      })
    end

    defp route(
           %{
             method: "GET",
             request_path: "/api/v1/namespaces/#{@namespace}/pods/pod-one"
           } = conn,
           _agent,
           _request
         ) do
      json(conn, 200, pod("pod-one", "22"))
    end

    defp route(
           %{method: "GET", request_path: "/api/v1/namespaces/#{@namespace}/events"} = conn,
           _agent,
           _request
         ) do
      json(conn, 200, %{
        "apiVersion" => "v1",
        "kind" => "EventList",
        "metadata" => %{"resourceVersion" => "31"},
        "items" => [
          %{
            "type" => "Warning",
            "reason" => "Unhealthy",
            "message" => "readiness probe failed",
            "involvedObject" => %{
              "kind" => "Pod",
              "name" => "pod-one",
              "uid" => "pod-uid"
            }
          }
        ]
      })
    end

    defp route(
           %{
             method: "GET",
             request_path: "/apis/apps/v1/namespaces/#{@namespace}/deployments/app"
           } = conn,
           agent,
           _request
         ) do
      json(conn, 200, Agent.get(agent, & &1.deployment))
    end

    defp route(
           %{
             method: "PATCH",
             request_path: "/apis/apps/v1/namespaces/#{@namespace}/deployments/app"
           } = conn,
           agent,
           %{body: body}
         ) do
      patch = Jason.decode!(body)

      result =
        Agent.get_and_update(agent, fn state ->
          current = state.deployment

          if get_in(patch, ["metadata", "uid"]) == get_in(current, ["metadata", "uid"]) and
               get_in(patch, ["metadata", "resourceVersion"]) ==
                 get_in(current, ["metadata", "resourceVersion"]) do
            version = current |> get_in(["metadata", "resourceVersion"]) |> String.to_integer()

            updated =
              current
              |> put_in(["metadata", "resourceVersion"], Integer.to_string(version + 1))
              |> update_in(["metadata", "generation"], &(&1 + 1))
              |> put_in(["spec", "replicas"], get_in(patch, ["spec", "replicas"]))
              |> put_in(["status", "readyReplicas"], get_in(patch, ["spec", "replicas"]))
              |> put_in(["status", "availableReplicas"], get_in(patch, ["spec", "replicas"]))

            {{:ok, updated}, %{state | deployment: updated}}
          else
            {{:error, :conflict}, state}
          end
        end)

      case result do
        {:ok, deployment} ->
          Process.sleep(Agent.get(agent, & &1.patch_delay_ms))
          json(conn, 200, deployment)

        {:error, :conflict} ->
          failure(conn, 409, "Conflict", "resourceVersion changed")
      end
    end

    defp route(
           %{
             method: "PATCH",
             request_path:
               "/apis/example.com/v1/namespaces/#{@namespace}/widgets/widget-one/status"
           } = conn,
           _agent,
           _request
         ) do
      json(conn, 200, %{"metadata" => %{"resourceVersion" => "9"}, "status" => %{"ready" => true}})
    end

    defp route(
           %{
             method: "GET",
             request_path:
               "/apis/example.com/v1/namespaces/#{@namespace}/widgets/widget-one/status"
           } = conn,
           _agent,
           _request
         ) do
      conn
      |> put_resp_content_type("application/yaml")
      |> send_resp(200, "status:\n  ready: true\n")
    end

    defp route(
           %{method: "GET", request_path: "/api/v1/namespaces/#{@namespace}/pods/pod-one/log"} =
             conn,
           _agent,
           _request
         ),
         do:
           conn
           |> put_resp_content_type("text/plain")
           |> send_resp(200, String.duplicate("complete log line\n", 700))

    defp route(
           %{method: "GET", request_path: "/api/v1/namespaces/#{@namespace}/pods/huge/log"} = conn,
           _agent,
           _request
         ),
         do:
           conn
           |> put_resp_content_type("text/plain")
           |> send_resp(200, String.duplicate("x", 70_000))

    defp route(
           %{
             method: "DELETE",
             request_path: "/apis/example.com/v1/namespaces/#{@namespace}/widgets"
           } = conn,
           _agent,
           _request
         ),
         do: json(conn, 200, %{"kind" => "Status", "status" => "Success"})

    defp route(
           %{method: "GET", request_path: "/api/v1/namespaces/#{@namespace}/pods/numeric/log"} =
             conn,
           _agent,
           _request
         ),
         do: conn |> put_resp_content_type("text/plain") |> send_resp(200, "123\n")

    defp route(conn, _agent, _request),
      do: failure(conn, 404, "NotFound", "unexpected Kubernetes fixture route")

    defp resource(name, kind, verbs) do
      %{
        "name" => name,
        "singularName" => "",
        "namespaced" => true,
        "kind" => kind,
        "verbs" => verbs
      }
    end

    defp pod(name, version) do
      %{
        "apiVersion" => "v1",
        "kind" => "Pod",
        "metadata" => %{
          "name" => name,
          "uid" => "pod-uid",
          "resourceVersion" => version
        },
        "status" => %{"phase" => "Running", "nodeName" => "node-one"}
      }
    end

    defp failure(conn, status, reason, message) do
      json(conn, status, %{
        "apiVersion" => "v1",
        "kind" => "Status",
        "status" => "Failure",
        "reason" => reason,
        "message" => message,
        "code" => status
      })
    end

    defp json(conn, status, value) do
      conn
      |> put_resp_content_type("application/json")
      |> send_resp(status, Jason.encode!(value))
    end
  end

  setup do
    deployment = %{
      "apiVersion" => "apps/v1",
      "kind" => "Deployment",
      "metadata" => %{
        "name" => "app",
        "namespace" => @namespace,
        "uid" => "deployment-uid",
        "resourceVersion" => "17",
        "generation" => 7
      },
      "spec" => %{"replicas" => 1},
      "status" => %{
        "readyReplicas" => 1,
        "availableReplicas" => 1,
        "observedGeneration" => 7
      }
    }

    widget = %{
      "apiVersion" => "example.com/v1",
      "kind" => "Widget",
      "metadata" => %{
        "name" => "widget-one",
        "namespace" => @namespace,
        "resourceVersion" => "7"
      },
      "spec" => %{"mode" => "idle"}
    }

    agent =
      start_supervised!(
        {Agent,
         fn ->
           %{
             requests: [],
             deployment: deployment,
             widget: widget,
             created_widget: nil,
             patch_delay_ms: 0
           }
         end}
      )

    server =
      start_supervised!(
        {Bandit,
         plug: {KubernetesStub, agent},
         scheme: :https,
         port: 0,
         certfile: Path.expand("test/support/certs/kubernetes_fixture.pem"),
         keyfile: Path.expand("test/support/certs/kubernetes_fixture_key.pem"),
         startup_log: false}
      )

    {:ok, {_address, port}} = ThousandIsland.listener_info(server)
    endpoint = "https://127.0.0.1:#{port}"

    admin = Accounts.bootstrap!("kubernetes-admin@example.com", @password, @password)

    operator =
      Accounts.create_user!("kubernetes-operator@example.com", @password, :operator, actor: admin)

    provider =
      Providers.create_provider!(
        "kubernetes-api",
        :target,
        "kubernetes-api",
        configuration(),
        %{"kubeconfig" => kubeconfig(endpoint)},
        actor: admin
      )

    checked =
      Skopos.TargetConnectionFixture.check_connection(provider, endpoint, admin)

    assert {:ok, _catalog} = checked

    target =
      Targets.create_target!("cluster-one", "cluster", "kubernetes", %{}, nil, actor: admin)

    method =
      Targets.create_access_method!(
        target.id,
        provider.id,
        "kubernetes-api",
        "api",
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
      agent: agent,
      endpoint: endpoint
    }
  end

  @tag native_case_context: true
  test "Case delivery does not send a native Kubernetes effect after its admitted Method changes",
       context do
    operation = case_operation!(context)
    changed = :atomics.new(1, [])
    before_requests = length(requests(context))

    assert :ok =
             Skopos.Cases.Operation.Delivery.run(operation.id,
               target_invocation: %{
                 cancelled?: fn ->
                   if :atomics.compare_exchange(changed, 1, 0, 1) == :ok do
                     Targets.update_access_method!(
                       context.method,
                       context.method.revision,
                       %{priority: 101},
                       actor: context.admin
                     )
                   end

                   false
                 end
               }
             )

    assert :atomics.get(changed, 1) == 1
    assert length(requests(context)) == before_requests
    saved = Cases.get_operation!(operation.id, actor: context.operator)
    assert saved.status == :failed
    assert saved.dispatch_started_at == nil

    assert Cases.get_case!(operation.case_id, actor: context.operator).pending_intent["action"] ==
             "resolve_turn"

    assert :ok = Skopos.Cases.Operation.Delivery.run(operation.id)
    assert length(requests(context)) == before_requests
  end

  @tag native_case_context: true
  test "Case verification observes the native effect but refuses a changed admitted Method",
       context do
    operation = case_operation!(context)
    assert :ok = Skopos.Cases.Operation.Delivery.run(operation.id)
    applied = Cases.get_operation!(operation.id, actor: context.operator)

    assert applied.status == :applied,
           inspect(Map.take(applied, [:outcome_category, :result_details]))

    assert Enum.count(requests(context), &(&1.method == "PATCH")) == 1

    attempt = Cases.verification_attempt_by_operation!(operation.id, authorize?: false)
    changed = :atomics.new(1, [])
    before_requests = length(requests(context))

    assert :ok =
             Skopos.Cases.VerificationAttempt.Delivery.run(attempt.id,
               target_invocation: %{
                 cancelled?: fn ->
                   if :atomics.compare_exchange(changed, 1, 0, 1) == :ok do
                     Targets.update_access_method!(
                       context.method,
                       context.method.revision,
                       %{priority: 101},
                       actor: context.admin
                     )
                   end

                   false
                 end
               }
             )

    assert :atomics.get(changed, 1) == 1
    assert length(requests(context)) == before_requests
    saved = Cases.get_verification_attempt!(attempt.id, actor: context.operator)
    assert saved.status == :unknown
    assert saved.dispatch_started_at == nil

    assert :ok = Skopos.Cases.VerificationAttempt.Delivery.run(attempt.id)
    assert :ok = Skopos.Cases.Operation.Delivery.run(operation.id)
    assert length(requests(context)) == before_requests
  end

  @tag native_case_context: true
  test "known native Case effect and verification receipts survive Evidence failure without resending",
       context do
    operation = case_operation!(context)

    Repo.query!("""
    CREATE FUNCTION pg_temp.reject_native_case_evidence() RETURNS trigger LANGUAGE plpgsql AS $$
    BEGIN RAISE EXCEPTION 'Native Case Evidence unavailable'; END;
    $$;
    """)

    Repo.query!("""
    CREATE TRIGGER reject_native_case_evidence BEFORE INSERT ON evidences
    FOR EACH ROW WHEN (NEW.source IN ('operation', 'verification'))
    EXECUTE FUNCTION pg_temp.reject_native_case_evidence()
    """)

    try do
      assert {:error, error} = Skopos.Cases.Operation.Delivery.run(operation.id)
      assert Exception.message(error) =~ "Native Case Evidence unavailable"
      assert Cases.get_operation!(operation.id, actor: context.operator).status == :applied
      assert Enum.count(requests(context), &(&1.method == "PATCH")) == 1
    after
      Repo.query!("DROP TRIGGER reject_native_case_evidence ON evidences")
    end

    assert :ok = Skopos.Cases.Operation.Delivery.run(operation.id)
    assert Enum.count(requests(context), &(&1.method == "PATCH")) == 1
    attempt = Cases.verification_attempt_by_operation!(operation.id, authorize?: false)
    before_requests = length(requests(context))

    Repo.query!("""
    CREATE TRIGGER reject_native_case_evidence BEFORE INSERT ON evidences
    FOR EACH ROW WHEN (NEW.source = 'verification')
    EXECUTE FUNCTION pg_temp.reject_native_case_evidence()
    """)

    try do
      assert {:error, error} = Skopos.Cases.VerificationAttempt.Delivery.run(attempt.id)
      assert Exception.message(error) =~ "Native Case Evidence unavailable"
      saved = Cases.get_verification_attempt!(attempt.id, actor: context.operator)
      assert saved.status == :verified
      assert saved.facts["http_status"] == 200
      assert get_in(saved.facts, ["response", "spec", "replicas"]) == 2
      assert length(requests(context)) == before_requests + 1
    after
      Repo.query!("DROP TRIGGER reject_native_case_evidence ON evidences")
    end

    assert :ok = Skopos.Cases.VerificationAttempt.Delivery.run(attempt.id)
    assert :ok = Skopos.Cases.Operation.Delivery.run(operation.id)
    assert length(requests(context)) == before_requests + 1
    assert Cases.get_case!(operation.case_id, actor: context.operator).status == :running
  end

  for change <- [:case_cancellation, :target_instructions, :provider_disabled] do
    @tag native_case_context: true, admitted_change: change
    test "native Case effect observes #{change} after claim without sending or replaying",
         context do
      operation = case_operation!(context)
      changed = :atomics.new(1, [])
      before_requests = length(requests(context))

      assert :ok =
               Skopos.Cases.Operation.Delivery.run(operation.id,
                 target_invocation: %{
                   cancelled?: fn ->
                     if :atomics.compare_exchange(changed, 1, 0, 1) == :ok do
                       case context.admitted_change do
                         :case_cancellation ->
                           incident = Cases.get_case!(operation.case_id, actor: context.operator)

                           Cases.request_case_cancellation!(incident.id, incident.revision,
                             actor: context.operator
                           )

                         :target_instructions ->
                           Targets.update_target!(
                             context.target,
                             context.target.revision,
                             %{
                               operating_instructions:
                                 "Review the updated maintenance constraints"
                             },
                             actor: context.admin
                           )

                         :provider_disabled ->
                           provider =
                             Providers.get_provider!(context.provider.id, actor: context.admin)

                           Providers.disable_provider!(provider, provider.revision,
                             actor: context.admin
                           )
                       end
                     end

                     false
                   end
                 }
               )

      assert :atomics.get(changed, 1) == 1
      assert length(requests(context)) == before_requests
      saved = Cases.get_operation!(operation.id, actor: context.operator)
      assert saved.status == :failed
      assert saved.dispatch_started_at == nil
      assert :ok = Skopos.Cases.Operation.Delivery.run(operation.id)
      assert length(requests(context)) == before_requests
    end
  end

  for change <- [:retired_run, :lost_subject_owner] do
    @tag native_case_context: true, admitted_change: change
    test "a checked native Method cannot make an admitted Case context current after #{change}",
         context do
      operation = case_operation!(context)
      claim = Cases.claim_operation_dispatch!(operation.id, authorize?: false)
      assert claim.state == :claimed
      assert Cases.invocation_context_current!(claim.invocation_context, authorize?: false)
      before_requests = length(requests(context))

      case context.admitted_change do
        :retired_run ->
          run = Cases.get_resolution_run!(operation.resolution_run_id, authorize?: false)

          Cases.retire_resolution_run!(
            run,
            run.revision,
            %{status: :superseded, ended_at: DateTime.utc_now()},
            authorize?: false
          )

        :lost_subject_owner ->
          interrupted = Cases.claim_operation_dispatch!(operation.id, authorize?: false)
          assert interrupted.state == :terminal
          assert interrupted.operation.status == :unknown
      end

      refute Cases.invocation_context_current!(claim.invocation_context, authorize?: false)
      assert length(requests(context)) == before_requests
    end
  end

  @tag native_target_before_send: true
  test "checked Kubernetes requests recheck current facts before native send independently of waiting",
       context do
    owner = self()
    path = "/apis/example.com/v1/namespaces/#{@namespace}/widgets/context-probe"
    resource_requests = fn -> Enum.count(requests(context), &(&1.path == path)) end

    for {kind, verb, capability, operation, dispatch} <- [
          {:observation, "GET", "request.kubernetes.observe", "request.observe",
           &Targets.dispatch_target_observation/3},
          {:effect, "PATCH", "request.kubernetes.effect", "request.execute",
           &Targets.dispatch_target_effect/3},
          {:verification, "GET", "request.kubernetes.observe", "request.observe",
           &Targets.dispatch_target_verification/3}
        ],
        phase <- [:provider_entry, :native_send] do
      parameters = %{"method" => verb, "path" => path}

      parameters =
        if kind == :effect,
          do: Map.put(parameters, "body", ~s({"spec":{"mode":"active"}})),
          else: parameters

      clearance =
        target_request(context, kind, capability, operation, %{}, parameters)
        |> Targets.clear_target_request!(actor: context.operator)

      before = resource_requests.()

      before_send? = fn ->
        if phase == :provider_entry or self() != owner do
          {:error, cause} =
            Skopos.Repo.query("SELECT kubernetes_before_send_unavailable", [], mode: :savepoint)

          raise cause
        end

        false
      end

      assert {:error, error} =
               dispatch.(clearance, %{before_send?: before_send?, cancelled?: fn -> false end},
                 actor: context.operator,
                 authorize?: false
               )

      unsent = Target.BeforeSendError.unwrap(error)
      assert unsent
      assert Exception.message(unsent.cause) =~ "kubernetes_before_send_unavailable"
      assert resource_requests.() == before
    end
  end

  @tag native_target_before_send: true
  test "a current-context stop at native send retains a known-unsent Target result", context do
    owner = self()
    path = "/apis/example.com/v1/namespaces/#{@namespace}/widgets/context-probe"
    before = length(requests(context))

    clearance =
      target_request(context, :effect, "request.kubernetes.effect", "request.execute", %{}, %{
        "method" => "PATCH",
        "path" => path,
        "body" => ~s({"spec":{"mode":"active"}})
      })
      |> Targets.clear_target_request!(actor: context.operator)

    assert {:error, error} =
             Targets.dispatch_target_effect(
               clearance,
               %{before_send?: fn -> self() != owner end, cancelled?: fn -> false end},
               actor: context.operator,
               authorize?: false
             )

    unsent = Target.BeforeSendError.unwrap(error)
    assert unsent
    refute Target.BeforeSendError.retryable?(unsent)
    assert unsent.cause.category == :cancelled
    assert length(requests(context)) == before
  end

  @tag protocol_context_fault: true
  test "checked Kubernetes Method retains context read failures after dispatch", context do
    path = "/apis/example.com/v1/namespaces/#{@namespace}/widgets/context-probe"

    resource_requests = fn ->
      Enum.count(requests(context), &(&1.path == path))
    end

    for {kind, verb, capability, operation, dispatch} <- [
          {:observation, "GET", "request.kubernetes.observe", "request.observe",
           &Targets.dispatch_target_observation/3},
          {:effect, "PATCH", "request.kubernetes.effect", "request.execute",
           &Targets.dispatch_target_effect/3},
          {:verification, "GET", "request.kubernetes.observe", "request.observe",
           &Targets.dispatch_target_verification/3}
        ] do
      parameters = %{"method" => verb, "path" => path}

      parameters =
        if kind == :effect,
          do: Map.put(parameters, "body", ~s({"spec":{"mode":"active"}})),
          else: parameters

      clearance =
        target_request(context, kind, capability, operation, %{}, parameters)
        |> Targets.clear_target_request!(actor: context.operator)

      before_requests = resource_requests.()

      callback = fn ->
        if resource_requests.() > before_requests do
          {:error, cause} =
            Skopos.Repo.query("SELECT kubernetes_context_unavailable", [], mode: :savepoint)

          raise cause
        end

        false
      end

      assert {:error, error} =
               dispatch.(clearance, %{cancelled?: callback},
                 actor: context.operator,
                 authorize?: false
               )

      assert Exception.message(error) =~ "kubernetes_context_unavailable"
      assert Target.Error.context_failure?(error)
      assert is_nil(Target.BeforeSendError.unwrap(error))
      assert resource_requests.() == before_requests + 1
    end
  end

  test "checked API requests publish full binary content without JSON or UTF8 decoding",
       context do
    result =
      observe!(context, "request.kubernetes.observe", "request.observe", %{}, %{
        "method" => "GET",
        "path" => "/apis/files.example/v1/namespaces/#{@namespace}/bundles/one/content",
        "accept" => "application/octet-stream",
        "response_file" => %{"name" => "bundle.bin", "media_type" => "application/octet-stream"}
      })

    file = result.facts["file"]
    assert file["target_id"] == context.target.id
    assert file["size_bytes"] == 5
    assert file["sha256"] == "b55f1659c0645fd1cee6dfa8b3af06795e9da7e48cb65c2b999f896c9f539dbd"

    assert Targets.read_bound_artifact_chunk!(file, 0, actor: context.operator) ==
             <<255, 0, 1, 2, 255>>

    assert result.facts["response"] == ""

    assert_schema_accepts!(
      hd(context.method.operation_catalog.observations).output_schema,
      result.facts
    )
  end

  for mode <- [:raise, :throw] do
    @tag completed_watch_read_fault: true, watch_read_fault_mode: mode
    test "a completed watch retains its file and the #{mode} read fault", context do
      bytes =
        "{\"type\":\"BOOKMARK\",\"object\":{\"metadata\":{\"resourceVersion\":\"opaque-9\"}}}\n"

      Agent.update(context.agent, &Map.put(&1, :watch_body, bytes))
      path = "/apis/example.com/v1/namespaces/#{@namespace}/widgets"

      clearance =
        target_request(
          context,
          :observation,
          "request.kubernetes.observe",
          "request.observe",
          %{},
          %{
            "method" => "GET",
            "path" => path,
            "query" => %{"watch" => "true"},
            "capture" => %{"duration_ms" => 500, "max_bytes" => 4_096, "max_events" => 10},
            "response_file" => %{
              "name" => "watch-read-fault.jsonl",
              "media_type" => "application/json"
            }
          }
        )
        |> Targets.clear_target_request!(actor: context.operator)

      callback = fn ->
        receipts = Targets.page_artifacts!(context.target.id, actor: context.operator).results

        if Enum.any?(receipts, &(&1.status == :ready)) do
          if context.watch_read_fault_mode == :throw, do: throw(:watch_file_context_throw)

          {:error, cause} =
            Skopos.Repo.query("SELECT watch_file_context_unavailable", [], mode: :savepoint)

          raise cause
        end

        false
      end

      before = Enum.count(requests(context), &(&1.path == path))

      assert {:error, error} =
               Targets.dispatch_target_observation(clearance, %{cancelled?: callback},
                 actor: context.operator
               )

      message =
        if context.watch_read_fault_mode == :throw,
          do: "watch_file_context_throw",
          else: "watch_file_context_unavailable"

      assert Exception.message(error) =~ message
      assert Target.Error.context_failure?(error)
      assert is_nil(Target.BeforeSendError.unwrap(error))

      assert %{"http_status" => 200, "file" => file, "completion_reason" => "eof"} =
               Target.Error.context_progress(error)

      assert file["size_bytes"] == byte_size(bytes)

      received =
        Target.FileWriter.stream(file, fn offset ->
          Targets.read_bound_artifact_chunk(file, offset, actor: context.operator)
        end)
        |> Enum.to_list()
        |> IO.iodata_to_binary()

      assert received == bytes
      assert Enum.count(requests(context), &(&1.path == path)) == before + 1
    end
  end

  test "checked API watches preserve exact built-in and CRD streams without an implicit list",
       context do
    bytes =
      "{\"type\":\"ADDED\",\"object\":{\"metadata\":{\"resourceVersion\":\"opaque-7\"}}}\n" <>
        "{\"type\":\"BOOKMARK\",\"object\":{\"metadata\":{\"resourceVersion\":\"opaque-9\"}}}\n"

    Agent.update(context.agent, &Map.put(&1, :watch_body, bytes))
    before = length(requests(context))
    query = %{"watch" => "true", "resourceVersion" => "opaque-4", "allowWatchBookmarks" => "true"}

    for path <- [
          "/api/v1/namespaces/#{@namespace}/events",
          "/apis/example.com/v1/namespaces/#{@namespace}/widgets"
        ] do
      observed =
        observe!(context, "request.kubernetes.observe", "request.observe", %{}, %{
          "method" => "GET",
          "path" => path,
          "query" => query,
          "capture" => %{"duration_ms" => 500, "max_bytes" => 4_096, "max_events" => 10},
          "response_file" => %{"name" => "watch.jsonl", "media_type" => "application/json"}
        })

      assert observed.facts["completion_reason"] == "eof"
      assert observed.facts["watch"]["event_count"] == 2
      assert observed.facts["watch"]["resource_version"] == "opaque-9"
      refute observed.facts["watch"]["partial_event"]
      assert observed.facts["response"] == ""
      file = observed.facts["file"]

      received =
        Stream.unfold(0, fn offset ->
          if offset == file["size_bytes"] do
            nil
          else
            chunk = Targets.read_bound_artifact_chunk!(file, offset, actor: context.operator)
            {chunk, offset + byte_size(chunk)}
          end
        end)
        |> Enum.to_list()
        |> IO.iodata_to_binary()

      assert received == bytes
      assert Enum.any?(requests(context), &(&1.path == path and &1.query == query))
    end

    assert length(requests(context)) == before + 2
  end

  test "an event limit stops at a complete watch frame rather than the network chunk", context do
    prefix =
      "{\"type\":\"ADDED\",\"object\":{\"metadata\":{\"resourceVersion\":\"opaque-7\"}}}\n" <>
        "{\"type\":\"BOOKMARK\",\"object\":{\"metadata\":{\"resourceVersion\":\"opaque-9\"}}}\n"

    bytes =
      prefix <>
        "{\"type\":\"MODIFIED\",\"object\":{\"metadata\":{\"resourceVersion\":\"opaque-12\"}}}\n"

    Agent.update(context.agent, &Map.put(&1, :watch_body, bytes))

    observed =
      observe!(context, "request.kubernetes.observe", "request.observe", %{}, %{
        "method" => "GET",
        "path" => "/apis/example.com/v1/namespaces/#{@namespace}/widgets",
        "query" => %{"watch" => "true", "resourceVersion" => "opaque-4"},
        "capture" => %{"duration_ms" => 500, "max_bytes" => 4_096, "max_events" => 2},
        "response_file" => %{"name" => "watch-bounded.jsonl", "media_type" => "application/json"}
      })

    assert observed.facts["completion_reason"] == "event_limit"
    file = observed.facts["file"]
    assert file["size_bytes"] == byte_size(prefix)
    first = Targets.read_bound_artifact_chunk!(file, 0, actor: context.operator)
    second = Targets.read_bound_artifact_chunk!(file, byte_size(first), actor: context.operator)
    assert first <> second == prefix

    assert Targets.get_artifact!(file["id"], actor: context.operator).completion_reason ==
             :event_limit
  end

  test "watch cursors use complete events and an expired history requires a fresh list",
       context do
    complete =
      "{\"type\":\"ADDED\",\"object\":{\"metadata\":{\"resourceVersion\":\"opaque-7\"}}}\n"

    Agent.update(
      context.agent,
      &Map.put(
        &1,
        :watch_body,
        complete <>
          "{\"type\":\"MODIFIED\",\"object\":{\"metadata\":{\"resourceVersion\":\"opaque-12\"}}}\n"
      )
    )

    parameters = %{
      "method" => "GET",
      "path" => "/apis/example.com/v1/namespaces/#{@namespace}/widgets",
      "query" => %{"watch" => "true", "resourceVersion" => "opaque-4"},
      "capture" => %{
        "duration_ms" => 500,
        "max_bytes" => byte_size(complete) + 12,
        "max_events" => 10
      },
      "response_file" => %{"name" => "watch-partial.jsonl", "media_type" => "application/json"}
    }

    before = length(requests(context))
    partial = observe!(context, "request.kubernetes.observe", "request.observe", %{}, parameters)
    assert partial.facts["completion_reason"] == "byte_limit"
    assert partial.facts["watch"]["event_count"] == 1
    assert partial.facts["watch"]["resource_version"] == "opaque-7"
    assert partial.facts["watch"]["partial_event"]
    assert partial.facts["watch"]["resume_strategy"] == "cursor"

    Agent.update(
      context.agent,
      &Map.put(
        &1,
        :watch_body,
        "{\"type\":\"ERROR\",\"object\":{\"kind\":\"Status\",\"code\":410,\"reason\":\"Expired\"}}\n" <>
          complete
      )
    )

    parameters = parameters |> put_in(["capture", "max_bytes"], 4_096)
    expired = observe!(context, "request.kubernetes.observe", "request.observe", %{}, parameters)
    assert expired.facts["watch"]["event_count"] == 2
    assert expired.facts["watch"]["resource_version"] == nil
    assert expired.facts["watch"]["resume_strategy"] == "list"
    assert expired.facts["watch"]["error"] == %{"code" => 410, "reason" => "Expired"}
    assert length(requests(context)) == before + 2
  end

  test "an HTTP expired watch preserves the status and instructs a fresh list without reconnecting",
       context do
    Agent.update(
      context.agent,
      &Map.merge(&1, %{
        watch_body: "{\"kind\":\"Status\",\"code\":410,\"reason\":\"Expired\"}",
        watch_status: 410
      })
    )

    before = length(requests(context))

    observed =
      observe!(context, "request.kubernetes.observe", "request.observe", %{}, %{
        "method" => "GET",
        "path" => "/api/v1/namespaces/#{@namespace}/events",
        "query" => %{"watch" => "true", "resourceVersion" => "opaque-old"},
        "capture" => %{"duration_ms" => 500, "max_bytes" => 4_096, "max_events" => 10},
        "response_file" => %{"name" => "watch-expired.jsonl", "media_type" => "application/json"}
      })

    assert observed.facts["http_status"] == 410
    assert observed.facts["watch"]["error"] == %{"code" => 410, "reason" => "Expired"}
    assert observed.facts["watch"]["resource_version"] == nil
    assert observed.facts["watch"]["resume_strategy"] == "list"
    assert length(requests(context)) == before + 1
  end

  test "a watch frame beyond the metadata parser bound preserves the file and earlier event count",
       context do
    complete =
      "{\"type\":\"ADDED\",\"object\":{\"metadata\":{\"resourceVersion\":\"opaque-7\"}}}\n"

    bytes =
      complete <>
        "{\"type\":\"MODIFIED\",\"object\":{\"metadata\":{\"resourceVersion\":\"opaque-12\"},\"payload\":\"" <>
        String.duplicate("x", 1_048_577) <> "\"}}\n"

    Agent.update(context.agent, &Map.put(&1, :watch_body, bytes))

    observed =
      observe!(context, "request.kubernetes.observe", "request.observe", %{}, %{
        "method" => "GET",
        "path" => "/apis/example.com/v1/namespaces/#{@namespace}/widgets",
        "query" => %{"watch" => "true", "resourceVersion" => "opaque-4"},
        "capture" => %{"duration_ms" => 500, "max_bytes" => 2_097_152, "max_events" => 10},
        "response_file" => %{"name" => "watch-large.jsonl", "media_type" => "application/json"}
      })

    assert observed.facts["completion_reason"] == "eof"
    assert observed.facts["file"]["size_bytes"] == byte_size(bytes)
    assert observed.facts["watch"]["event_count"] == 1
    assert observed.facts["watch"]["error"] == %{"reason" => "frame_too_large"}
    assert observed.facts["watch"]["resume_strategy"] == "unavailable"
    assert observed.facts["watch"]["resource_version"] == nil
  end

  test "a zero-event watch sample is distinct from a dropped response", context do
    Agent.update(context.agent, &Map.merge(&1, %{watch_body: "", watch_delay_ms: 1_000}))

    parameters = %{
      "method" => "GET",
      "path" => "/api/v1/namespaces/#{@namespace}/events",
      "query" => %{"watch" => "true", "resourceVersion" => "opaque-4"},
      "capture" => %{"duration_ms" => 100, "max_bytes" => 4_096, "max_events" => 10},
      "response_file" => %{"name" => "watch-empty.jsonl", "media_type" => "application/json"}
    }

    empty = observe!(context, "request.kubernetes.observe", "request.observe", %{}, parameters)
    assert empty.facts["completion_reason"] == "duration_limit"
    assert empty.facts["file"]["size_bytes"] == 0
    assert empty.facts["watch"]["event_count"] == 0
    assert empty.facts["watch"]["resource_version"] == "opaque-4"
    assert empty.facts["watch"]["error"] == nil
    refute empty.facts["watch"]["partial_event"]

    Agent.update(
      context.agent,
      &Map.merge(&1, %{
        watch_body:
          "{\"type\":\"ADDED\",\"object\":{\"metadata\":{\"resourceVersion\":\"opaque-7\"}}}\n",
        watch_delay_ms: 80,
        watch_drop: true
      })
    )

    parameters =
      parameters
      |> put_in(["capture", "duration_ms"], 500)
      |> put_in(["response_file", "name"], "watch-dropped.jsonl")

    request =
      target_request(
        context,
        :observation,
        "request.kubernetes.observe",
        "request.observe",
        %{},
        parameters
      )

    clearance = Targets.clear_target_request!(request, actor: context.operator)

    assert {:error, _} =
             Targets.dispatch_target_observation(clearance, %{}, actor: context.operator)

    receipt =
      Targets.page_artifacts!(context.target.id, actor: context.operator).results
      |> Enum.find(&(&1.name == "watch-dropped.jsonl"))

    assert receipt.status == :receiving
    assert receipt.completion_reason == nil

    assert {:error, _} =
             Targets.artifact_reference(receipt.id, context.target.id, actor: context.operator)
  end

  test "an unrecognized watch encoding retains raw bytes without inventing decoded events",
       context do
    Agent.update(
      context.agent,
      &Map.merge(&1, %{watch_body: <<255, 10, 0, 10>>, watch_media: "application/octet-stream"})
    )

    observed =
      observe!(context, "request.kubernetes.observe", "request.observe", %{}, %{
        "method" => "GET",
        "path" => "/api/v1/namespaces/#{@namespace}/events",
        "query" => %{"watch" => "true", "resourceVersion" => "opaque-4"},
        "capture" => %{"duration_ms" => 500, "max_bytes" => 4_096, "max_events" => 1},
        "accept" => "application/octet-stream",
        "response_file" => %{
          "name" => "watch-raw.bin",
          "media_type" => "application/octet-stream"
        }
      })

    assert observed.facts["completion_reason"] == "eof"
    assert observed.facts["file"]["size_bytes"] == 4
    assert observed.facts["watch"]["event_count"] == 0
    assert observed.facts["watch"]["error"] == %{"reason" => "unsupported_framing"}
    assert observed.facts["watch"]["resume_strategy"] == "unavailable"

    assert Targets.read_bound_artifact_chunk!(observed.facts["file"], 0, actor: context.operator) ==
             <<255, 10, 0, 10>>
  end

  test "watch admission requires explicit valid bounds before any wire request", context do
    parameters = %{
      "method" => "GET",
      "path" => "/api/v1/namespaces/#{@namespace}/events",
      "query" => %{"watch" => "true"},
      "capture" => %{"duration_ms" => 500, "max_bytes" => 4_096, "max_events" => 10},
      "response_file" => %{"name" => "watch.jsonl", "media_type" => "application/json"}
    }

    before = length(requests(context))

    for invalid <- [
          Map.delete(parameters, "capture"),
          Map.delete(parameters, "response_file"),
          put_in(parameters, ["capture", "max_events"], 0),
          put_in(parameters, ["capture", "max_events"], 4_097),
          put_in(parameters, ["capture", "duration_ms"], 501),
          put_in(parameters, ["capture", "max_bytes"], 0)
        ] do
      request =
        target_request(
          context,
          :observation,
          "request.kubernetes.observe",
          "request.observe",
          %{},
          invalid
        )

      assert {:error, _} = Targets.clear_target_request(request, actor: context.operator)
    end

    assert length(requests(context)) == before
    assert Targets.page_artifacts!(context.target.id, actor: context.operator).results == []
  end

  test "cancelled watches cannot publish a completed sample or reconnect", context do
    Agent.update(
      context.agent,
      &Map.merge(&1, %{
        watch_body:
          "{\"type\":\"ADDED\",\"object\":{\"metadata\":{\"resourceVersion\":\"opaque-7\"}}}\n",
        watch_delay_ms: 1_000
      })
    )

    parameters = %{
      "method" => "GET",
      "path" => "/api/v1/namespaces/#{@namespace}/events",
      "query" => %{"watch" => "true"},
      "capture" => %{"duration_ms" => 500, "max_bytes" => 4_096, "max_events" => 10},
      "response_file" => %{"name" => "watch-cancelled.jsonl", "media_type" => "application/json"}
    }

    clearance =
      target_request(
        context,
        :observation,
        "request.kubernetes.observe",
        "request.observe",
        %{},
        parameters
      )
      |> Targets.clear_target_request!(actor: context.operator)

    cancelled = fn -> Enum.any?(requests(context), &(&1.query["watch"] == "true")) end

    assert {:error, _} =
             Targets.dispatch_target_observation(clearance, %{cancelled?: cancelled},
               actor: context.operator
             )

    [receipt] = Targets.page_artifacts!(context.target.id, actor: context.operator).results
    assert receipt.status == :receiving
    assert receipt.completion_reason == nil

    assert {:error, _} =
             Targets.artifact_reference(receipt.id, context.target.id, actor: context.operator)

    assert Enum.count(requests(context), &(&1.query["watch"] == "true")) == 1
  end

  test "checked API effects send immutable binary files and preserve their reply", context do
    upload =
      Targets.begin_artifact!(
        context.target.id,
        "bundle.bin",
        "application/octet-stream",
        5,
        "b55f1659c0645fd1cee6dfa8b3af06795e9da7e48cb65c2b999f896c9f539dbd",
        "kube-file-input",
        actor: context.operator
      )

    Targets.append_artifact_chunk!(upload.id, 0, <<255, 0>>, actor: context.operator)
    Targets.append_artifact_chunk!(upload.id, 2, <<1, 2, 255>>, actor: context.operator)
    Targets.complete_artifact!(upload.id, actor: context.operator)
    input = Targets.artifact_reference!(upload.id, context.target.id, actor: context.operator)

    parameters = %{
      "method" => "PUT",
      "path" => "/apis/files.example/v1/namespaces/#{@namespace}/bundles/one/content",
      "content_type" => "application/octet-stream",
      "body_file" => "payload",
      "files" => %{"payload" => input},
      "response_file" => %{"name" => "reply.bin", "media_type" => "application/octet-stream"}
    }

    request =
      target_request(
        context,
        :effect,
        "request.kubernetes.effect",
        "request.execute",
        %{},
        parameters
      )

    clearance = Targets.clear_target_request!(request, actor: context.operator)

    result =
      Targets.dispatch_target_effect!(clearance, %{}, actor: context.operator, authorize?: false)

    assert result.status == :applied

    assert result.details["file"]["sha256"] ==
             "b55f1659c0645fd1cee6dfa8b3af06795e9da7e48cb65c2b999f896c9f539dbd"

    assert Targets.read_bound_artifact_chunk!(result.details["file"], 0, actor: context.operator) ==
             <<255, 0, 1, 2, 255>>

    assert Enum.filter(requests(context), &(&1.method == "PUT")) |> Enum.map(& &1.body) == [
             <<255, 0, 1, 2, 255>>
           ]

    assert_schema_accepts!(hd(context.method.operation_catalog.effects).input_schema, %{
      "selectors" => %{},
      "parameters" => parameters
    })

    for params <- [
          Map.put(parameters, "body", "different"),
          Map.put(parameters, "body_file", "missing"),
          Map.put(
            parameters,
            "path",
            "/apis/files.example/v1/namespaces/other/bundles/one/content"
          )
        ] do
      assert {:error, _} =
               Targets.clear_target_request(%{request | parameters: params},
                 actor: context.operator
               )
    end

    Targets.revoke_artifact!(input["id"], actor: context.operator)

    assert {:error, _} =
             Targets.dispatch_target_effect(clearance, %{},
               actor: context.operator,
               authorize?: false
             )

    assert length(Enum.filter(requests(context), &(&1.method == "PUT"))) == 1
  end

  test "file results preserve content beyond the inline response limit", context do
    result =
      observe!(context, "request.kubernetes.observe", "request.observe", %{}, %{
        "method" => "GET",
        "path" => "/api/v1/namespaces/#{@namespace}/pods/huge/log",
        "response_file" => %{"name" => "pod.log", "media_type" => "text/plain"}
      })

    assert result.facts["file"]["size_bytes"] == 70_000

    file = result.facts["file"]

    bytes =
      Stream.unfold(0, fn
        70_000 ->
          nil

        offset ->
          chunk = Targets.read_bound_artifact_chunk!(file, offset, actor: context.operator)
          {chunk, offset + byte_size(chunk)}
      end)
      |> Enum.to_list()
      |> IO.iodata_to_binary()

    assert bytes == String.duplicate("x", 70_000)
  end

  test "overflow cannot publish a truncated Kubernetes file result", context do
    previous = Application.get_env(:skopos, :artifact_limits)
    Application.put_env(:skopos, :artifact_limits, %{chunk_bytes: 3, max_size_bytes: 4})

    on_exit(fn ->
      if previous,
        do: Application.put_env(:skopos, :artifact_limits, previous),
        else: Application.delete_env(:skopos, :artifact_limits)
    end)

    assert {:error, _} =
             file_clearance(context, "GET")
             |> Targets.dispatch_target_observation(%{}, actor: context.operator)

    [receipt] = Targets.page_artifacts!(context.target.id, actor: context.operator).results
    assert receipt.status == :receiving
    assert receipt.received_bytes <= 4
    assert is_nil(receipt.sha256)

    assert {:error, _} =
             Targets.artifact_reference(receipt.id, context.target.id, actor: context.operator)
  end

  test "an interrupted Kubernetes response cannot be completed by another response", context do
    assert {:error, _} =
             file_clearance(context, "GET", %{"query" => %{"transfer" => "interrupted"}})
             |> Targets.dispatch_target_observation(%{}, actor: context.operator)

    [partial] = Targets.page_artifacts!(context.target.id, actor: context.operator).results
    assert partial.status == :receiving
    assert partial.received_bytes == 2

    assert {:error, _} =
             Targets.artifact_reference(partial.id, context.target.id, actor: context.operator)

    result =
      file_clearance(context, "GET")
      |> Targets.dispatch_target_observation!(%{}, actor: context.operator)

    assert result.facts["file"]["id"] != partial.id

    assert Targets.read_bound_artifact_chunk!(result.facts["file"], 0, actor: context.operator) ==
             <<255, 0, 1, 2, 255>>

    assert Targets.get_artifact!(partial.id, actor: context.operator).status == :receiving
  end

  test "lost Kubernetes file replies leave effects unknown without replay", context do
    result =
      file_clearance(context, "PUT", %{
        "body" => "changed",
        "query" => %{"transfer" => "interrupted"}
      })
      |> Targets.dispatch_target_effect!(%{}, actor: context.operator, authorize?: false)

    assert result.status == :unknown
    refute Map.has_key?(result.details, "file")

    assert Enum.filter(requests(context), &(&1.method == "PUT")) |> Enum.map(& &1.body) == [
             "changed"
           ]

    [receipt] = Targets.page_artifacts!(context.target.id, actor: context.operator).results
    assert receipt.status == :receiving
    assert result.details["error"] =~ receipt.id

    assert {:error, _} =
             Targets.artifact_reference(receipt.id, context.target.id, actor: context.operator)
  end

  test "Kubernetes cancellation and timeout do not publish file results or replay effects",
       context do
    clearance =
      file_clearance(context, "PUT", %{
        "body" => "changed",
        "query" => %{"transfer" => "delayed"}
      })

    count = length(requests(context))

    assert {:error, _} =
             Targets.dispatch_target_effect(clearance, %{cancelled?: fn -> true end},
               actor: context.operator,
               authorize?: false
             )

    assert length(requests(context)) == count
    assert Targets.page_artifacts!(context.target.id, actor: context.operator).results == []

    for invocation <- [
          %{cancelled?: fn -> Enum.any?(requests(context), &(&1.method == "PUT")) end},
          %{}
        ] do
      result =
        Targets.dispatch_target_effect!(clearance, invocation,
          actor: context.operator,
          authorize?: false
        )

      assert result.status == :unknown
      refute Map.has_key?(result.details, "file")
    end

    assert length(Enum.filter(requests(context), &(&1.method == "PUT"))) == 2
    receipts = Targets.page_artifacts!(context.target.id, actor: context.operator).results
    assert length(receipts) == 2

    for receipt <- receipts do
      assert receipt.status == :receiving

      assert {:error, _} =
               Targets.artifact_reference(receipt.id, context.target.id, actor: context.operator)
    end
  end

  @tag file_publication_fault: true
  test "failed Kubernetes result publication cannot report success or repeat a write", context do
    Skopos.Repo.query!("""
    CREATE FUNCTION pg_temp.reject_kubernetes_file_ready() RETURNS trigger LANGUAGE plpgsql AS $$
    BEGIN
      IF NEW.status = 'ready' THEN RAISE EXCEPTION 'injected file publication failure'; END IF;
      RETURN NEW;
    END $$;
    """)

    Skopos.Repo.query!(
      "CREATE TRIGGER reject_kubernetes_file_ready BEFORE UPDATE ON artifacts FOR EACH ROW EXECUTE FUNCTION pg_temp.reject_kubernetes_file_ready()"
    )

    assert {:error, error} =
             file_clearance(context, "PUT", %{"body" => "changed"})
             |> Targets.dispatch_target_effect(%{}, actor: context.operator, authorize?: false)

    assert Exception.message(error) =~ "injected file publication failure"

    assert Enum.filter(requests(context), &(&1.method == "PUT")) |> Enum.map(& &1.body) == [
             "changed"
           ]

    [receipt] = Targets.page_artifacts!(context.target.id, actor: context.operator).results
    assert receipt.status == :receiving
    assert receipt.received_bytes == 7

    assert Target.Error.context_progress(error) == %{
             "http_status" => 200,
             "receiving_file_id" => receipt.id,
             "received_bytes" => 7
           }

    assert {:error, _} =
             Targets.artifact_reference(receipt.id, context.target.id, actor: context.operator)
  end

  test "generic API request reaches a dynamically discovered custom resource", context do
    parameters = %{
      "method" => "GET",
      "path" => "/apis/example.com/v1/namespaces/#{@namespace}/widgets/widget-one"
    }

    observation =
      observe!(context, "request.kubernetes.observe", "request.observe", %{}, parameters)

    assert get_in(observation.facts, ["response", "spec", "mode"]) == "idle"

    request =
      target_request(
        context,
        :effect,
        "request.kubernetes.effect",
        "request.execute",
        %{},
        Map.merge(parameters, %{
          "method" => "PATCH",
          "content_type" => "application/merge-patch+json",
          "body" => Jason.encode!(%{"spec" => %{"mode" => "active"}})
        })
      )

    clearance = Targets.clear_target_request!(request, actor: context.operator)

    assert %Target.EffectResult{status: :applied, reference: "8"} =
             Targets.dispatch_target_effect!(clearance, %{},
               actor: context.operator,
               authorize?: false
             )

    assert get_in(
             observe!(context, "request.kubernetes.observe", "request.observe", %{}, parameters).facts,
             ["response", "spec", "mode"]
           ) == "active"

    assert Enum.any?(requests(context), &(&1.path == parameters["path"]))
  end

  test "API-wide checked Method reaches a cluster CRD and a different namespace", context do
    provider =
      Providers.create_provider!(
        "api-wide",
        :target,
        "kubernetes-api",
        %{"request_timeout_ms" => 500},
        %{"kubeconfig" => kubeconfig(context.endpoint)},
        actor: context.admin
      )
      |> then(&Providers.enable_provider!(&1, &1.revision, actor: context.admin))

    method =
      Targets.create_access_method!(
        context.target.id,
        provider.id,
        "API-wide",
        "api",
        context.endpoint,
        provider.revision,
        110,
        @capabilities,
        actor: context.admin
      )
      |> then(&Targets.check_access_method!(&1.id, &1.revision, %{}, actor: context.admin))

    api_wide = %{context | provider: provider, method: method}
    path = "/apis/acme.example/v9/racks/rack-a"

    result =
      observe!(api_wide, "request.kubernetes.observe", "request.observe", %{}, %{
        "method" => "GET",
        "path" => path
      })

    assert get_in(result.facts, ["response", "spec", "mode"]) == "idle"

    request =
      target_request(api_wide, :effect, "request.kubernetes.effect", "request.execute", %{}, %{
        "method" => "PATCH",
        "path" => path,
        "content_type" => "application/merge-patch+json",
        "body" => ~s({"spec":{"mode":"active"}})
      })

    clearance = Targets.clear_target_request!(request, actor: context.operator)

    assert %Target.EffectResult{status: :applied} =
             Targets.dispatch_target_effect!(clearance, %{},
               actor: context.operator,
               authorize?: false
             )

    fresh =
      observe!(api_wide, "request.kubernetes.observe", "request.observe", %{}, %{
        "method" => "GET",
        "path" => path
      })

    assert get_in(fresh.facts, ["response", "spec", "mode"]) == "active"

    other =
      observe!(api_wide, "request.kubernetes.observe", "request.observe", %{}, %{
        "method" => "GET",
        "path" => "/api/v1/namespaces/other/pods"
      })

    assert other.facts["response"] == %{"kind" => "PodList", "items" => []}

    before = length(requests(context))

    for scope <- [api_wide, context],
        path <- [
          "/api/v1/namespaces/#{@namespace}/pods/one/exec",
          "/api/v1/namespaces/#{@namespace}/pods/one/attach"
        ] do
      read =
        target_request(
          scope,
          :observation,
          "request.kubernetes.observe",
          "request.observe",
          %{},
          %{"method" => "GET", "path" => path}
        )

      assert {:error, _} = Targets.clear_target_request(read, actor: context.operator)
    end

    for path <- [path, "/api/v1/namespaces/other/pods"] do
      scoped =
        target_request(
          context,
          :observation,
          "request.kubernetes.observe",
          "request.observe",
          %{},
          %{"method" => "GET", "path" => path}
        )

      assert {:error, _} = Targets.clear_target_request(scoped, actor: context.operator)
    end

    assert length(requests(context)) == before
  end

  test "exact HTTP Method carries CRD subresource apply and complete YAML response", context do
    path = "/apis/example.com/v1/namespaces/#{@namespace}/widgets/widget-one/status"
    body = "apiVersion: example.com/v1\nkind: Widget\nstatus:\n  ready: true\n"

    request =
      target_request(context, :effect, "request.kubernetes.effect", "request.execute", %{}, %{
        "method" => "PATCH",
        "path" => path,
        "query" => %{"fieldManager" => "skopos-test", "force" => "true"},
        "content_type" => "application/apply-patch+yaml",
        "body" => body
      })

    clearance = Targets.clear_target_request!(request, actor: context.operator)

    assert %Target.EffectResult{status: :applied, reference: "9"} =
             Targets.dispatch_target_effect!(clearance, %{},
               actor: context.operator,
               authorize?: false
             )

    sent = Enum.find(requests(context), &(&1.method == "PATCH"))
    assert sent.path == path
    assert sent.body == body
    assert sent.content_type == ["application/apply-patch+yaml"]
    assert sent.query == %{"fieldManager" => "skopos-test", "force" => "true"}

    result =
      observe!(context, "request.kubernetes.observe", "request.observe", %{}, %{
        "method" => "GET",
        "path" => path,
        "accept" => "application/json;as=Table;g=meta.k8s.io;v=v1, application/yaml"
      })

    assert result.facts["response"] == "status:\n  ready: true\n"
    assert result.facts["content_type"] == "application/yaml"

    assert Enum.any?(
             requests(context),
             &(&1.accept == ["application/json;as=Table;g=meta.k8s.io;v=v1, application/yaml"])
           )
  end

  test "namespace-bound Method rejects conflicting literal JSON and YAML identities before I/O",
       context do
    before = length(requests(context))

    for {content_type, body} <- [
          {"application/merge-patch+json",
           ~s({"metadata":{"namespace":"other"},"spec":{"mode":"active"}})},
          {"application/apply-patch+yaml",
           "metadata:\n  namespace: other\nspec:\n  mode: active\n"}
        ] do
      request =
        target_request(context, :effect, "request.kubernetes.effect", "request.execute", %{}, %{
          "method" => "PATCH",
          "path" => "/apis/example.com/v1/namespaces/#{@namespace}/widgets/widget-one",
          "content_type" => content_type,
          "body" => body
        })

      assert {:error, _} = Targets.clear_target_request(request, actor: context.operator)
    end

    for namespace <- [nil, "", @namespace] do
      request =
        target_request(context, :effect, "request.kubernetes.effect", "request.execute", %{}, %{
          "method" => "PATCH",
          "path" => "/apis/example.com/v1/namespaces/#{@namespace}/widgets/widget-one",
          "body" => Jason.encode!(%{"metadata" => %{"namespace" => namespace}})
        })

      assert {:ok, _clearance} = Targets.clear_target_request(request, actor: context.operator)
    end

    assert length(requests(context)) == before
  end

  test "HTTP Method carries JSON patch, complete text and DELETE collection", context do
    patch_body = ~s([{"op":"replace","path":"/status/ready","value":true}])

    patch =
      target_request(context, :effect, "request.kubernetes.effect", "request.execute", %{}, %{
        "method" => "PATCH",
        "path" => "/apis/example.com/v1/namespaces/#{@namespace}/widgets/widget-one/status",
        "content_type" => "application/json-patch+json",
        "body" => patch_body
      })

    clearance = Targets.clear_target_request!(patch, actor: context.operator)

    assert %Target.EffectResult{status: :applied} =
             Targets.dispatch_target_effect!(clearance, %{},
               actor: context.operator,
               authorize?: false
             )

    assert Enum.any?(
             requests(context),
             &(&1.body == patch_body and &1.content_type == ["application/json-patch+json"])
           )

    observed =
      observe!(context, "request.kubernetes.observe", "request.observe", %{}, %{
        "method" => "GET",
        "path" => "/api/v1/namespaces/#{@namespace}/pods/pod-one/log",
        "query" => %{"tailLines" => "700", "timestamps" => "true"},
        "accept" => "text/plain"
      })

    assert observed.facts["response"] == String.duplicate("complete log line\n", 700)
    assert observed.facts["http_status"] == 200

    numeric =
      observe!(context, "request.kubernetes.observe", "request.observe", %{}, %{
        "method" => "GET",
        "path" => "/api/v1/namespaces/#{@namespace}/pods/numeric/log",
        "accept" => "text/plain"
      })

    assert numeric.facts["response"] == "123\n"

    delete_body = ~s({"kind":"DeleteOptions","apiVersion":"v1","propagationPolicy":"Background"})

    delete =
      target_request(context, :effect, "request.kubernetes.effect", "request.execute", %{}, %{
        "method" => "DELETE",
        "path" => "/apis/example.com/v1/namespaces/#{@namespace}/widgets",
        "query" => %{"labelSelector" => "app=disposable"},
        "body" => delete_body
      })

    clearance = Targets.clear_target_request!(delete, actor: context.operator)

    assert %Target.EffectResult{status: :applied, details: %{"http_status" => 200}} =
             Targets.dispatch_target_effect!(clearance, %{},
               actor: context.operator,
               authorize?: false
             )

    sent = Enum.find(requests(context), &(&1.method == "DELETE"))
    assert sent.body == delete_body
    assert sent.query == %{"labelSelector" => "app=disposable"}
  end

  test "HTTP Method rejects path substitution and unsafe inputs before I/O", context do
    before = length(requests(context))
    path = "/api/v1/namespaces/#{@namespace}/pods"

    for parameters <- [
          %{"method" => "GET", "path" => "https://other.example#{path}"},
          %{"method" => "GET", "path" => "//other.example#{path}"},
          %{"method" => "GET", "path" => path <> "/../nodes"},
          %{"method" => "GET", "path" => path <> "/%2e%2e/nodes"},
          %{"method" => "GET", "path" => path <> "?namespace=other"},
          %{"method" => "GET", "path" => path, "query" => %{"watch" => "T"}},
          %{
            "method" => "GET",
            "path" => path <> "/pod-one/exec",
            "query" => %{"command" => "delete"}
          },
          %{
            "method" => "GET",
            "path" => path,
            "query" => %{"labelSelector" => String.duplicate("x", 2_049)}
          },
          %{
            "method" => "GET",
            "path" => path,
            "accept" => "application/json\r\nAuthorization: injected"
          }
        ] do
      request =
        target_request(
          context,
          :observation,
          "request.kubernetes.observe",
          "request.observe",
          %{},
          parameters
        )

      assert {:error, _} = Targets.clear_target_request(request, actor: context.operator)
    end

    bad_body =
      target_request(context, :effect, "request.kubernetes.effect", "request.execute", %{}, %{
        "method" => "PATCH",
        "path" => path,
        "body" => "{broken"
      })

    assert {:error, _} = Targets.clear_target_request(bad_body, actor: context.operator)
    assert length(requests(context)) == before

    request =
      target_request(
        context,
        :observation,
        "request.kubernetes.observe",
        "request.observe",
        %{},
        %{
          "method" => "GET",
          "path" => "/api/v1/namespaces/#{@namespace}/pods/huge/log",
          "accept" => "text/plain"
        }
      )

    clearance = Targets.clear_target_request!(request, actor: context.operator)

    assert {:error, error} =
             Targets.dispatch_target_observation(clearance, %{}, actor: context.operator)

    assert Exception.message(error) =~ "inline size limit"
  end

  test "one generic Method observes built-in resources without fixed capabilities", context do
    assert %Target.Capabilities{observations: [observation], effects: [effect, session]} =
             Providers.target_capabilities!(
               context.provider.id,
               %Target.CapabilitiesRequest{
                 provider_revision: context.provider.revision,
                 connection: %Target.Connection{endpoint: context.endpoint}
               },
               %{},
               actor: context.admin
             )

    assert session.operation == "websocket.session"
    assert session.capability == "request.kubernetes.effect"
    assert observation.capability == "request.kubernetes.observe"
    assert observation.operation == "request.observe"
    assert effect.capability == "request.kubernetes.effect"
    assert effect.operation == "request.execute"

    pod =
      observe!(context, observation.capability, observation.operation, %{}, %{
        "method" => "GET",
        "path" => "/api/v1/namespaces/#{@namespace}/pods/pod-one",
        "query" => %{"pretty" => "true"}
      })

    assert get_in(pod.facts, ["response", "metadata", "name"]) == "pod-one"
    assert_schema_accepts!(observation.output_schema, pod.facts)

    for {resource, expected_kind} <- [
          {"pods", "PodList"},
          {"events", "EventList"}
        ] do
      result =
        observe!(context, observation.capability, observation.operation, %{}, %{
          "method" => "GET",
          "path" => "/api/v1/namespaces/#{@namespace}/#{resource}"
        })

      assert get_in(result.facts, ["response", "kind"]) == expected_kind
    end

    deployment = deployment_observation!(context)
    assert get_in(deployment, ["response", "spec", "replicas"]) == 1

    assert Enum.all?(requests(context), fn request ->
             request.authorized? and
               (request.path == "/api" or
                  String.contains?(request.path, "/namespaces/#{@namespace}/"))
           end)
  end

  test "generic observations reject changed scope and malformed query before dispatch",
       context do
    request_count = length(requests(context))

    for {path, query} <- [
          {"/api/v1/namespaces/other/pods", %{}},
          {"/api/v1/namespaces/#{@namespace}/pods", %{"labelSelector" => 42}}
        ] do
      request =
        target_request(
          context,
          :observation,
          "request.kubernetes.observe",
          "request.observe",
          %{},
          %{
            "method" => "GET",
            "path" => path,
            "query" => query
          }
        )

      assert {:error, _error} = Targets.clear_target_request(request, actor: context.operator)
    end

    assert length(requests(context)) == request_count

    {:ok, state} =
      Kubernetes.build(configuration(), %{"kubeconfig" => kubeconfig(context.endpoint)})

    wrong_endpoint = %{
      capability: "request.kubernetes.observe",
      operation: "request.observe",
      connection: %{endpoint: "https://127.0.0.1:1"},
      selectors: %{},
      parameters: %{
        "method" => "GET",
        "path" => "/api/v1/namespaces/#{@namespace}/pods/pod-one"
      }
    }

    assert {:error, :failed, _message} = Kubernetes.observe(state, wrong_endpoint, %{})

    assert length(requests(context)) == request_count
  end

  test "Kubernetes Method rejects an unrelated namespace parameter before dispatch", context do
    request_count = length(requests(context))

    request =
      target_request(
        context,
        :observation,
        "request.kubernetes.observe",
        "request.observe",
        %{},
        %{
          "method" => "GET",
          "path" => "/api/v1/namespaces/#{@namespace}/pods/pod-one",
          "namespace" => "other-namespace"
        }
      )

    assert {:error, _error} = Targets.clear_target_request(request, actor: context.operator)
    assert length(requests(context)) == request_count
  end

  test "Kubernetes read rejects a body that the API request would ignore", context do
    request_count = length(requests(context))

    request =
      target_request(
        context,
        :observation,
        "request.kubernetes.observe",
        "request.observe",
        %{},
        %{
          "method" => "GET",
          "path" => "/api/v1/namespaces/#{@namespace}/pods/pod-one",
          "body" => Jason.encode!(%{"metadata" => %{"namespace" => "other-namespace"}})
        }
      )

    assert {:error, _error} = Targets.clear_target_request(request, actor: context.operator)
    assert length(requests(context)) == request_count
  end

  test "generic write preserves conflict and unknown outcomes with independent observation",
       context do
    before = deployment_observation!(context)["response"]
    effect = deployment_patch(context, before, 2)
    clearance = Targets.clear_target_request!(effect, actor: context.operator)

    assert %Target.EffectResult{status: :applied, reference: "18"} =
             Targets.dispatch_target_effect!(clearance, %{},
               actor: context.operator,
               authorize?: false
             )

    fresh = deployment_observation!(context)["response"]
    assert get_in(fresh, ["spec", "replicas"]) == 2

    verification =
      target_request(
        context,
        :verification,
        "request.kubernetes.observe",
        "request.observe",
        %{},
        deployment_get_parameters(),
        %{"response" => fresh}
      )

    verified = Targets.clear_target_request!(verification, actor: context.operator)

    assert %Target.Verification{status: :verified} =
             Targets.dispatch_target_verification!(verified, %{}, actor: context.operator)

    stale =
      Targets.clear_target_request!(deployment_patch(context, before, 0), actor: context.operator)

    assert %Target.EffectResult{status: :failed, details: %{"category" => "conflict"}} =
             Targets.dispatch_target_effect!(stale, %{},
               actor: context.operator,
               authorize?: false
             )

    Agent.update(context.agent, &%{&1 | patch_delay_ms: 1_000})

    lost =
      Targets.clear_target_request!(deployment_patch(context, fresh, 3), actor: context.operator)

    assert %Target.EffectResult{status: :unknown} =
             Targets.dispatch_target_effect!(lost, %{},
               actor: context.operator,
               authorize?: false
             )

    Agent.update(context.agent, &%{&1 | patch_delay_ms: 0})
    reconciled = deployment_observation!(context)["response"]
    assert get_in(reconciled, ["spec", "replicas"]) == 3
    assert length(Enum.filter(requests(context), &(&1.method == "PATCH"))) == 3
  end

  test "HTTP effect cancellation before and after send preserves uncertainty without replay",
       context do
    before = deployment_observation!(context)["response"]
    request = deployment_patch(context, before, 2)
    clearance = Targets.clear_target_request!(request, actor: context.operator)
    count = length(requests(context))

    assert {:error, _} =
             Targets.dispatch_target_effect(clearance, %{cancelled?: fn -> true end},
               actor: context.operator,
               authorize?: false
             )

    assert length(requests(context)) == count

    Agent.update(context.agent, &%{&1 | patch_delay_ms: 1_000})
    cancelled = fn -> Enum.any?(requests(context), &(&1.method == "PATCH")) end

    assert %Target.EffectResult{status: :unknown} =
             Targets.dispatch_target_effect!(clearance, %{cancelled?: cancelled},
               actor: context.operator,
               authorize?: false
             )

    assert length(Enum.filter(requests(context), &(&1.method == "PATCH"))) == 1
    Agent.update(context.agent, &%{&1 | patch_delay_ms: 0})
    assert get_in(deployment_observation!(context), ["response", "spec", "replicas"]) == 2
  end

  test "generic create and update cannot select a different namespace", context do
    {:ok, state} =
      Kubernetes.build(configuration(), %{"kubeconfig" => kubeconfig(context.endpoint)})

    count = length(requests(context))

    for method <- ["POST", "PUT"] do
      request = %{
        capability: "request.kubernetes.effect",
        operation: "request.execute",
        connection: %{endpoint: context.endpoint},
        selectors: %{},
        parameters: %{
          "method" => method,
          "path" => "/apis/apps/v1/namespaces/kube-system/deployments/app",
          "body" =>
            Jason.encode!(%{
              "apiVersion" => "apps/v1",
              "kind" => "Deployment",
              "metadata" => %{"name" => "app", "namespace" => "kube-system"}
            })
        }
      }

      assert {:error, :failed, _message} = Kubernetes.effect(state, request, %{})
    end

    assert length(requests(context)) == count
  end

  test "generic create and update use the configured namespace", context do
    created = %{
      "apiVersion" => "example.com/v1",
      "kind" => "Widget",
      "metadata" => %{"name" => "widget-two", "namespace" => @namespace},
      "spec" => %{"mode" => "active"}
    }

    create =
      target_request(context, :effect, "request.kubernetes.effect", "request.execute", %{}, %{
        "method" => "POST",
        "path" => "/apis/example.com/v1/namespaces/#{@namespace}/widgets",
        "body" => Jason.encode!(created)
      })

    clearance = Targets.clear_target_request!(create, actor: context.operator)

    assert %Target.EffectResult{status: :applied} =
             Targets.dispatch_target_effect!(clearance, %{},
               actor: context.operator,
               authorize?: false
             )

    assert Agent.get(context.agent, & &1.created_widget) == created

    previous =
      observe!(context, "request.kubernetes.observe", "request.observe", %{}, %{
        "method" => "GET",
        "path" => "/apis/example.com/v1/namespaces/#{@namespace}/widgets/widget-one"
      }).facts["response"]

    updated = put_in(previous, ["spec", "mode"], "updated")

    update =
      target_request(context, :effect, "request.kubernetes.effect", "request.execute", %{}, %{
        "method" => "PUT",
        "path" => "/apis/example.com/v1/namespaces/#{@namespace}/widgets/widget-one",
        "body" => Jason.encode!(updated)
      })

    clearance = Targets.clear_target_request!(update, actor: context.operator)

    assert %Target.EffectResult{status: :applied} =
             Targets.dispatch_target_effect!(clearance, %{},
               actor: context.operator,
               authorize?: false
             )

    assert Agent.get(context.agent, & &1.widget) == updated

    assert Enum.all?(
             Enum.filter(requests(context), &(&1.method in ["POST", "PUT"])),
             fn request ->
               String.contains?(request.path, "/namespaces/#{@namespace}/")
             end
           )
  end

  test "kubeconfig cannot execute helpers, read credential paths or disable TLS", context do
    unsafe_exec =
      String.replace(
        kubeconfig(context.endpoint),
        "token: static-test-token",
        "exec:\n          command: cloud-login"
      )

    assert {:error, :invalid_configuration} =
             Kubernetes.build(configuration(), %{"kubeconfig" => unsafe_exec})

    path_based =
      String.replace(
        kubeconfig(context.endpoint),
        "server: #{context.endpoint}",
        "server: #{context.endpoint}\n      certificate-authority: /etc/ca.pem"
      )

    assert {:error, :invalid_configuration} =
             Kubernetes.build(configuration(), %{"kubeconfig" => path_based})

    insecure =
      String.replace(
        kubeconfig(context.endpoint),
        "server: #{context.endpoint}",
        "server: #{context.endpoint}\n      insecure-skip-tls-verify: true"
      )

    assert {:error, :invalid_configuration} =
             Kubernetes.build(configuration(), %{"kubeconfig" => insecure})
  end

  defp case_operation!(context) do
    current = Cases.current_authority_setting!(actor: context.admin)

    Cases.configure_authority_setting!(
      current.setting_revision,
      :full_access,
      current.signal_automation_enabled,
      current.max_elapsed_seconds,
      current.max_resolver_turns,
      current.max_target_requests,
      current.max_effects,
      current.max_related_targets,
      current.max_ai_usage_units,
      current.max_no_progress_turns,
      "Exercise the native Kubernetes delivery path",
      actor: context.admin
    )

    resolver =
      Providers.create_provider!(
        "native-case-resolver",
        :ai,
        "fixture-ai",
        %{"model" => "resolver-model"},
        %{"api_key" => "native-case-fixture-secret"},
        actor: context.admin
      )
      |> then(&Providers.check_provider!(&1.id, 1, %{}, actor: context.admin))
      |> then(&Providers.enable_provider!(&1, 1, actor: context.admin))

    assignment =
      Skopos.TestAIUsage.configure!(resolver.id, :resolver, 10, context.admin).resolver

    incident =
      Cases.open_case!(
        :manual,
        "test",
        "native-kubernetes-case",
        "Restore the registered workload",
        :warning,
        %{"desired_outcome" => "The deployment has two ready replicas"},
        context.target.id,
        :en,
        actor: context.operator
      )

    run = Cases.active_resolution_run!(incident.id, authorize?: false)
    observed = deployment_observation!(context)

    evidence =
      Cases.append_evidence!(
        incident.id,
        run.id,
        nil,
        "native-kubernetes-observation",
        "observation",
        "fixture",
        "native-kubernetes-observation",
        observed,
        DateTime.utc_now(),
        authorize?: false
      )

    turn =
      Cases.start_turn!(
        incident.id,
        run.id,
        "native-kubernetes-turn",
        %{"objective" => "Restore the deployment"},
        %{"action" => "continue"},
        "Review the native target evidence",
        authorize?: false
      ).value

    tool = %{
      "id" => "native-kubernetes-effect",
      "request_kind" => "effect",
      "target_id" => context.target.id,
      "target_revision" => context.target.revision,
      "access_method_id" => context.method.id,
      "access_method_revision" => context.method.revision,
      "provider_id" => context.provider.id,
      "provider_revision" => context.provider.revision,
      "capability" => "request.kubernetes.effect",
      "operation" => "request.execute"
    }

    verification_tool = %{
      tool
      | "id" => "native-kubernetes-verification",
        "request_kind" => "verification",
        "capability" => "request.kubernetes.observe",
        "operation" => "request.observe"
    }

    intent =
      tool
      |> Map.drop(["id", "provider_id", "provider_revision"])
      |> Map.merge(%{
        "type" => "proposal",
        "tool_id" => tool["id"],
        "tool" => tool,
        "purpose" => "remediation",
        "delay_seconds" => 0,
        "selectors" => %{},
        "parameters" => deployment_patch(context, observed["response"], 2).parameters,
        "reason" => "Restore the deployment replica count",
        "evidence_ids" => [evidence.id],
        "affected_conditions" => [],
        "expected_result" => %{"http_status" => 200},
        "verification_tool" => verification_tool,
        "verification_intent" => %{
          "tool_id" => verification_tool["id"],
          "selectors" => %{},
          "parameters" => deployment_get_parameters(),
          "expected_result" => %{"http_status" => 200}
        }
      })

    Cases.complete_turn!(
      turn.id,
      turn.revision,
      %{
        "outcome" => "decision",
        "intent" => intent,
        "resolver" => %{
          "provider_id" => resolver.id,
          "provider_revision" => resolver.revision,
          "assignment_id" => assignment.id,
          "assignment_revision" => assignment.revision
        },
        "usage" => %{"input_tokens" => 1, "output_tokens" => 1}
      },
      :proposal,
      %{"action" => "route_resolver_decision", "turn_id" => turn.id},
      "Review the fixture Resolver decision",
      authorize?: false
    )

    proposal = Cases.materialize_proposal!(turn.id, authorize?: false)
    Cases.route_proposal_authority!(proposal.id, authorize?: false)
    Cases.accept_operation!(proposal.id, authorize?: false)
  end

  defp observe!(context, capability, operation, selectors, parameters) do
    request =
      target_request(context, :observation, capability, operation, selectors, parameters)

    clearance = Targets.clear_target_request!(request, actor: context.operator)
    Targets.dispatch_target_observation!(clearance, %{}, actor: context.operator)
  end

  defp file_clearance(context, verb, options \\ %{}) do
    kind = if verb in ["GET", "HEAD"], do: :observation, else: :effect

    capability =
      if kind == :effect, do: "request.kubernetes.effect", else: "request.kubernetes.observe"

    operation = if kind == :effect, do: "request.execute", else: "request.observe"

    parameters =
      Map.merge(
        %{
          "method" => verb,
          "path" => "/apis/files.example/v1/namespaces/#{@namespace}/bundles/one/content",
          "content_type" => "text/plain",
          "response_file" => %{"name" => "result.bin", "media_type" => "application/octet-stream"}
        },
        options
      )

    target_request(context, kind, capability, operation, %{}, parameters)
    |> Targets.clear_target_request!(actor: context.operator)
  end

  defp deployment_get_parameters do
    %{"method" => "GET", "path" => "/apis/apps/v1/namespaces/#{@namespace}/deployments/app"}
  end

  defp deployment_observation!(context) do
    observe!(
      context,
      "request.kubernetes.observe",
      "request.observe",
      %{},
      deployment_get_parameters()
    ).facts
  end

  defp deployment_patch(context, observed, replicas) do
    target_request(context, :effect, "request.kubernetes.effect", "request.execute", %{}, %{
      "method" => "PATCH",
      "path" => "/apis/apps/v1/namespaces/#{@namespace}/deployments/app",
      "content_type" => "application/merge-patch+json",
      "body" =>
        Jason.encode!(%{
          "metadata" => %{
            "uid" => get_in(observed, ["metadata", "uid"]),
            "resourceVersion" => get_in(observed, ["metadata", "resourceVersion"])
          },
          "spec" => %{"replicas" => replicas}
        })
    })
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
      operation_id:
        if(kind in [:effect, :verification], do: "operation-#{System.unique_integer()}"),
      idempotency_key: if(kind == :effect, do: "idempotency-#{System.unique_integer()}"),
      expected: expected
    )
  end

  defp configuration do
    %{"namespace" => @namespace, "request_timeout_ms" => 500}
  end

  defp kubeconfig(endpoint) do
    certificate =
      "test/support/certs/kubernetes_fixture_ca.pem"
      |> File.read!()
      |> Base.encode64()

    """
    apiVersion: v1
    kind: Config
    clusters:
      - name: target
        cluster:
          server: #{endpoint}
          certificate-authority-data: #{certificate}
    users:
      - name: operator
        user:
          token: static-test-token
    contexts:
      - name: target
        context:
          cluster: target
          user: operator
          namespace: #{@namespace}
    current-context: target
    """
  end

  defp requests(context),
    do: Agent.get(context.agent, &Enum.reverse(&1.requests))

  defp assert_schema_accepts!(schema, facts) do
    assert {:ok, root} = JSV.build(schema, warnings: :silent)
    assert {:ok, _validated} = JSV.validate(facts, root, cast: false)
  end
end
