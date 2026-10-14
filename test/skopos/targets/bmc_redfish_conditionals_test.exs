defmodule Skopos.Targets.BMCRedfishConditionalsTest do
  use Skopos.DataCase, async: false

  alias Skopos.{Accounts, Cases, Providers, Targets}
  alias Skopos.Providers.Target
  alias Skopos.Targets.Adapters.Redfish
  alias Skopos.Targets.TargetRequest.Request

  @system_path "/redfish/v1/Systems/1"
  @uuid "b70d412b-9707-4784-ae6d-14ce38586e00"

  defmodule Stub do
    import Plug.Conn

    @system_path "/redfish/v1/Systems/1"
    @uuid "b70d412b-9707-4784-ae6d-14ce38586e00"

    def init(agent), do: agent

    def call(conn, agent) do
      Agent.update(
        agent,
        &Map.update(&1, :paths, [conn.request_path], fn paths -> [conn.request_path | paths] end)
      )

      if get_req_header(conn, "authorization") == ["Basic " <> Base.encode64("tester:secret")] do
        route(conn, agent)
      else
        send_resp(conn, 401, "")
      end
    end

    defp route(%{method: "GET", request_path: "/redfish/v1/Systems"} = conn, agent) do
      if Agent.get(agent, &Map.get(&1, :delay_power?, false)), do: Process.sleep(300)

      if Agent.get(agent, &Map.get(&1, :no_system, false)),
        do: send_resp(conn, 404, ""),
        else: json(conn, 200, %{"Members" => [%{"@odata.id" => @system_path}]})
    end

    defp route(%{method: "GET", request_path: "/redfish/v1/"} = conn, _agent) do
      json(conn, 200, %{"@odata.id" => "/redfish/v1/", "RedfishVersion" => "1.16.0"})
    end

    defp route(%{request_path: "/redfish/v1/Oem/ContextProbe"} = conn, _agent) do
      Process.sleep(300)
      json(conn, 200, %{"Id" => "context-probe"})
    end

    defp route(%{method: "GET", request_path: "/redfish/v1/Oem/Bundle/content"} = conn, _agent) do
      conn
      |> put_resp_content_type("application/octet-stream")
      |> send_resp(200, <<255, 0, 1, 2, 255>>)
    end

    defp route(%{method: "PUT", request_path: "/redfish/v1/Oem/Bundle/content"} = conn, agent) do
      {:ok, bytes, conn} = read_body(conn)

      Agent.update(
        agent,
        &Map.put(&1, :file_input, {bytes, get_req_header(conn, "content-type")})
      )

      conn |> put_resp_content_type("application/octet-stream") |> send_resp(200, bytes)
    end

    defp route(%{request_path: "/redfish/v1/Oem/Bundle/Interrupted"} = conn, _agent) do
      conn = send_chunked(conn, 200)
      {:ok, _conn} = chunk(conn, <<255, 0>>)
      Process.sleep(50)
      Process.exit(self(), :kill)
    end

    defp route(%{request_path: "/redfish/v1/Oem/Bundle/Cancelled"} = conn, agent) do
      conn = send_chunked(conn, 200)
      {:ok, conn} = chunk(conn, <<255, 0>>)
      Agent.update(agent, &Map.put(&1, :cancelled, true))
      Process.sleep(150)
      conn
    end

    defp route(%{method: "POST", request_path: "/redfish/v1/UpdateService/upload"} = conn, agent) do
      {:ok, parameter_headers, conn} = read_part_headers(conn)
      {:ok, parameters, conn} = read_part_body(conn, [])
      {:ok, file_headers, conn} = read_part_headers(conn)
      {:ok, bytes, conn} = read_part_body(conn, [])
      {:done, conn} = read_part_headers(conn)

      Agent.update(
        agent,
        &Map.put(&1, :multipart_input, {parameter_headers, parameters, file_headers, bytes})
      )

      conn
      |> put_resp_header("location", "/redfish/v1/TaskService/TaskMonitors/2")
      |> put_resp_content_type("application/octet-stream")
      |> send_resp(202, <<255, 0, 1, 2, 255>>)
    end

    defp route(%{request_path: "/redfish/v1/Oem/Property"} = conn, agent) do
      if conn.method == "PATCH" do
        {:ok, body, _conn} = read_body(conn)
        %{"Name" => name} = Jason.decode!(body)
        Agent.update(agent, &%{&1 | name: name, writes: &1.writes + 1})
        send_resp(conn, 204, "")
      else
        json(conn, 200, %{"Name" => Agent.get(agent, & &1.name)})
      end
    end

    defp route(%{method: "GET", request_path: @system_path} = conn, agent) do
      state = Agent.get(agent, & &1)
      reset = %{"target" => @system_path <> "/Actions/ComputerSystem.Reset"}

      reset =
        if Map.get(state, :action_info?, false),
          do: Map.put(reset, "@Redfish.ActionInfo", @system_path <> "/ResetActionInfo"),
          else: Map.put(reset, "ResetType@Redfish.AllowableValues", ["ForceOff", "On"])

      conn
      |> put_resp_header("etag", ~s("rev-#{state.revision}"))
      |> json(200, %{
        "@odata.id" => @system_path,
        "UUID" => @uuid,
        "PowerState" => state.power,
        "Name" => state.name,
        "Actions" => %{
          "#ComputerSystem.Reset" => reset
        }
      })
    end

    defp route(
           %{method: "GET", request_path: "/redfish/v1/Systems/1/ResetActionInfo"} = conn,
           agent
         ) do
      if Agent.get(agent, &Map.get(&1, :delay_power?, false)), do: Process.sleep(300)

      json(conn, 200, %{
        "Parameters" => [%{"Name" => "ResetType", "AllowableValues" => ["ForceOff", "On"]}]
      })
    end

    defp route(
           %{method: "POST", request_path: "/redfish/v1/Systems/1/Actions/ComputerSystem.Reset"} =
             conn,
           agent
         ) do
      {:ok, body, conn} = read_body(conn)

      case Jason.decode!(body) do
        %{"ResetType" => "ForceOff"} ->
          Agent.update(agent, &%{&1 | power: "Off", writes: &1.writes + 1})
          if Agent.get(agent, &Map.get(&1, :delay_power?, false)), do: Process.sleep(300)
          json(conn, 200, %{})

        _ ->
          send_resp(conn, 400, "")
      end
    end

    defp route(%{method: "PATCH", request_path: @system_path} = conn, agent) do
      {:ok, body, conn} = read_body(conn)
      expected = Agent.get(agent, &~s("rev-#{&1.revision}"))

      if get_req_header(conn, "if-match") == [expected] do
        %{"Name" => name} = Jason.decode!(body)
        Agent.update(agent, &%{&1 | name: name, revision: &1.revision + 1, writes: &1.writes + 1})
        send_resp(conn, 204, "")
      else
        send_resp(conn, 412, Jason.encode!(%{"error" => "precondition failed"}))
      end
    end

    defp route(%{method: "GET", request_path: "/redfish/v1/Oem/Pages"} = conn, agent) do
      case conn.query_string do
        "page=2" ->
          Process.sleep(Agent.get(agent, &Map.get(&1, :page_delay_ms, 0)))
          json(conn, 200, %{"Members" => [%{"Id" => "second"}]})

        "" ->
          json(conn, 200, %{
            "Members" => [%{"Id" => "first"}],
            "Members@odata.nextLink" => "?page=2"
          })
      end
    end

    defp route(%{method: "GET", request_path: "/redfish/v1/Oem/Loop"} = conn, _agent) do
      json(conn, 200, %{
        "Members" => [%{"Id" => "repeated"}],
        "Members@odata.nextLink" => "/redfish/v1/Oem/Loop"
      })
    end

    defp route(%{method: "GET", request_path: "/redfish/v1/Oem/Endless"} = conn, _agent) do
      page =
        case URI.decode_query(conn.query_string) do
          %{"page" => value} -> String.to_integer(value)
          _ -> 1
        end

      json(conn, 200, %{
        "Members" => [%{"Id" => Integer.to_string(page)}],
        "Members@odata.nextLink" => "?page=#{page + 1}"
      })
    end

    defp route(%{method: "GET", request_path: "/redfish/v1/Oem/Cross"} = conn, _agent) do
      json(conn, 200, %{
        "Members" => [],
        "Members@odata.nextLink" => "https://other.example/redfish/v1/Oem/Pages"
      })
    end

    defp route(%{method: "GET", request_path: "/redfish/v1/Oem/Large"} = conn, _agent) do
      json(conn, 200, %{"Value" => String.duplicate("x", 70_000)})
    end

    defp route(%{method: "GET", request_path: "/redfish/v1/Oem/Visible"} = conn, _agent) do
      json(conn, 200, %{
        "Result" => "safe",
        "hidden" => "private-value",
        "Nested" => %{"Public" => "visible", "Private" => "private-value"}
      })
    end

    defp route(%{method: "GET", request_path: "/redfish/v1/Oem/Example"} = conn, _agent) do
      json(conn, 200, %{"Result" => "safe", "Password" => "fixture-secret"})
    end

    defp route(%{method: "HEAD", request_path: "/redfish/v1/Oem/Example"} = conn, _agent) do
      conn
      |> put_resp_header("etag", ~s("oem-1"))
      |> send_resp(200, "")
    end

    defp route(%{method: "GET", request_path: "/redfish/v1/Oem/Wrong"} = conn, _agent) do
      json(conn, 200, %{"Result" => %{"unexpected" => "object"}})
    end

    defp route(%{method: "POST", request_path: "/redfish/v1/Oem/Echo"} = conn, agent) do
      {:ok, body, conn} = read_body(conn)
      %{"Password" => secret} = Jason.decode!(body)
      Agent.update(agent, &Map.update!(&1, :echo_calls, fn count -> count + 1 end))
      json(conn, 200, %{"Result" => Base.encode64(secret), "Message" => "changed"})
    end

    defp route(%{method: "POST", request_path: "/redfish/v1/Oem/Plain"} = conn, _agent) do
      json(conn, 200, %{"Result" => "done", "hidden" => "private-value"})
    end

    defp route(%{method: "POST", request_path: "/redfish/v1/Oem/Async"} = conn, _agent) do
      conn
      |> put_resp_header("location", "/redfish/v1/TaskService/TaskMonitors/1?token=private-value")
      |> json(202, %{"Message" => "accepted"})
    end

    defp route(%{method: "POST", request_path: "/redfish/v1/Oem/AsyncSafe"} = conn, _agent) do
      conn
      |> put_resp_header("location", "/redfish/v1/TaskService/TaskMonitors/2")
      |> json(202, %{"Message" => "accepted"})
    end

    defp route(%{method: "POST", request_path: "/redfish/v1/Oem/OpaqueAsync"} = conn, agent) do
      Agent.update(agent, &Map.update(&1, :async_writes, 1, fn count -> count + 1 end))

      conn
      |> put_resp_header(
        "location",
        Agent.get(
          agent,
          &Map.get(&1, :task_location, "/vendor/monitor/session-secret?ticket=private-value")
        )
      )
      |> put_resp_header("retry-after", Agent.get(agent, &Map.get(&1, :retry_after, "3")))
      |> json(202, %{
        "TaskState" => "Running",
        "TaskMonitor" => "/vendor/monitor/session-secret?ticket=private-value",
        "Ticket" => "private-value"
      })
    end

    defp route(%{method: "GET", request_path: "/vendor/monitor/session-secret"} = conn, agent) do
      Agent.update(agent, &Map.put(&1, :monitor_query, conn.query_string))
      status = Agent.get(agent, &Map.get(&1, :monitor_status, 202))

      conn
      |> put_resp_header("retry-after", "3")
      |> json(status, Agent.get(agent, &Map.get(&1, :monitor_body, %{"TaskState" => "Running"})))
    end

    defp route(%{method: "DELETE", request_path: "/vendor/monitor/session-secret"} = conn, agent) do
      Agent.update(
        agent,
        &Map.merge(&1, %{
          async_cancels: Map.get(&1, :async_cancels, 0) + 1,
          cancel_query: conn.query_string
        })
      )

      send_resp(conn, 204, "")
    end

    defp route(%{method: "PATCH", request_path: "/vendor/monitor/session-secret"} = conn, agent) do
      {:ok, body, conn} = read_body(conn)

      Agent.update(
        agent,
        &Map.put(&1, :monitor_patch, {conn.query_string, body, get_req_header(conn, "if-match")})
      )

      json(conn, 200, %{"Message" => "updated", "Ticket" => "private-value"})
    end

    defp route(%{method: "POST", request_path: "/redfish/v1/Oem/Drop"} = _conn, agent) do
      Agent.update(agent, &Map.update!(&1, :echo_calls, fn count -> count + 1 end))
      Process.exit(self(), :kill)
    end

    defp route(%{method: "GET", request_path: "/redfish/v1/Oem/Malformed"} = conn, _agent),
      do: send_resp(conn, 200, "[")

    defp route(%{method: "POST", request_path: "/redfish/v1/Oem/Malformed"} = conn, agent) do
      Agent.update(agent, &%{&1 | name: "changed", writes: &1.writes + 1})
      send_resp(conn, 200, "[")
    end

    defp route(%{method: "GET", request_path: "/redfish/v1/Oem/Redirect"} = conn, _agent) do
      conn
      |> put_resp_header("location", "/redfish/v1/Oem/Pages")
      |> send_resp(302, "")
    end

    defp route(conn, _agent), do: send_resp(conn, 404, "")

    defp json(conn, status, value) do
      conn
      |> put_resp_content_type("application/json")
      |> send_resp(status, Jason.encode!(value))
    end
  end

  for {kind, fault_path, fault_mode} <- [
        {:capabilities, "/redfish/v1/Systems", :raise},
        {:capabilities, "/redfish/v1/Systems/1/ResetActionInfo", :raise},
        {:capabilities, "/redfish/v1/Systems", :cancel},
        {:capabilities, "/redfish/v1/Systems/1/ResetActionInfo", :cancel},
        {:observation, "/redfish/v1/Systems", :raise},
        {:verification, "/redfish/v1/Systems", :raise},
        {:effect, "/redfish/v1/Systems/1/Actions/ComputerSystem.Reset", :raise}
      ] do
    @tag power_context_fault: true,
         power_kind: kind,
         power_fault_path: fault_path,
         power_fault_mode: fault_mode
    test "Redfish #{kind} retains native power #{fault_mode} at #{fault_path}", context do
      kind = context.power_kind

      method =
        Targets.update_access_method!(
          context.method,
          context.method.revision,
          %{capabilities: context.method.capabilities ++ ["effect.power"]},
          actor: context.admin
        )

      method = Targets.check_access_method!(method.id, method.revision, %{}, actor: context.admin)
      context = %{context | method: method}

      Agent.update(
        context.agent,
        &Map.merge(&1, %{
          paths: [],
          delay_power?: true,
          action_info?: String.ends_with?(context.power_fault_path, "ResetActionInfo")
        })
      )

      callback = fn ->
        fault? =
          Agent.get(context.agent, fn peer ->
            if kind == :effect, do: peer.writes > 0, else: context.power_fault_path in peer.paths
          end)

        if fault? do
          if context.power_fault_mode == :raise do
            {:error, cause} =
              Skopos.Repo.query("SELECT redfish_power_context_unavailable", [], mode: :savepoint)

            raise cause
          end
        end

        fault? and context.power_fault_mode == :cancel
      end

      invocation = %{cancelled?: callback}

      result =
        if kind == :capabilities do
          Providers.target_capabilities(
            method.provider_id,
            %Target.CapabilitiesRequest{
              provider_revision: method.provider_revision,
              connection: %Target.Connection{endpoint: method.endpoint}
            },
            invocation,
            actor: context.admin
          )
        else
          input =
            file_request(
              context,
              kind,
              if(kind == :effect, do: %{"observed_power_state" => "on"}, else: %{})
            )

          input = %{
            input
            | capability: if(kind == :effect, do: "effect.power", else: "observe.power"),
              operation: if(kind == :effect, do: "bmc.power.off", else: "bmc.power.inspect")
          }

          clearance = Targets.clear_target_request!(input, actor: context.operator)

          dispatch =
            case kind do
              :observation -> &Targets.dispatch_target_observation/3
              :verification -> &Targets.dispatch_target_verification/3
              :effect -> &Targets.dispatch_target_effect/3
            end

          dispatch.(clearance, invocation, actor: context.operator, authorize?: false)
        end

      assert {:error, error} = result

      if context.power_fault_mode == :raise do
        assert Exception.message(error) =~ "redfish_power_context_unavailable"
        assert Target.Error.context_failure?(error)
      else
        assert Target.Error.unwrap(error).category == :cancelled
        refute Target.Error.context_failure?(error)
      end

      assert is_nil(Target.BeforeSendError.unwrap(error))

      if kind == :effect do
        assert Target.Error.context_progress(error) == %{
                 "reset_type" => "ForceOff",
                 "pre_power_state" => "on"
               }
      end

      peer = Agent.get(context.agent, & &1)
      assert Enum.count(peer.paths, &(&1 == "/redfish/v1/Systems")) == 1
      assert peer.writes == if(kind == :effect, do: 1, else: 0)
    end
  end

  @tag protocol_context_fault: true
  test "checked Redfish Method retains context read failures after dispatch", context do
    resource_requests = fn ->
      Agent.get(
        context.agent,
        &Enum.count(&1.paths, fn path -> path == "/redfish/v1/Oem/ContextProbe" end)
      )
    end

    for {kind, verb, dispatch} <- [
          {:observation, "GET", &Targets.dispatch_target_observation/3},
          {:effect, "PATCH", &Targets.dispatch_target_effect/3},
          {:verification, "GET", &Targets.dispatch_target_verification/3},
          {:task_observation, "GET", &Targets.dispatch_target_observation/3}
        ] do
      parameters = %{"method" => verb, "uri" => "/redfish/v1/Oem/ContextProbe"}
      parameters = if kind == :effect, do: Map.put(parameters, "body", %{}), else: parameters
      reference = Ecto.UUID.generate()

      input =
        if kind == :task_observation do
          file_request(context, :observation, %{"result_reference" => reference})
          |> Map.put(:operation, "task.observe")
        else
          file_request(context, kind, parameters)
        end

      clearance =
        input
        |> Targets.clear_target_request!(actor: context.operator)

      before_requests = resource_requests.()

      callback = fn ->
        if resource_requests.() > before_requests do
          {:error, cause} =
            Skopos.Repo.query("SELECT redfish_context_unavailable", [], mode: :savepoint)

          raise cause
        end

        false
      end

      invocation = %{
        cancelled?: callback,
        result_reference_reader: fn ^reference ->
          {:ok, %{"kind" => "redfish_task_monitor", "uri" => "/redfish/v1/Oem/ContextProbe"}}
        end
      }

      assert {:error, error} =
               dispatch.(clearance, invocation,
                 actor: context.operator,
                 authorize?: false
               )

      assert Exception.message(error) =~ "redfish_context_unavailable"
      assert Target.Error.context_failure?(error)
      assert is_nil(Target.BeforeSendError.unwrap(error))
      assert resource_requests.() == before_requests + 1
    end
  end

  @tag protocol_context_fault: true
  test "checked Redfish Method retains context read failure on a following page", context do
    Agent.update(context.agent, &Map.put(&1, :page_delay_ms, 300))

    page_requests = fn ->
      Agent.get(
        context.agent,
        &Enum.count(&1.paths, fn path -> path == "/redfish/v1/Oem/Pages" end)
      )
    end

    before_requests = page_requests.()

    clearance =
      file_request(context, :observation, %{"method" => "GET", "uri" => "/redfish/v1/Oem/Pages"})
      |> Targets.clear_target_request!(actor: context.operator)

    callback = fn ->
      if page_requests.() >= before_requests + 2 do
        {:error, cause} =
          Skopos.Repo.query("SELECT redfish_page_context_unavailable", [], mode: :savepoint)

        raise cause
      end

      false
    end

    assert {:error, error} =
             Targets.dispatch_target_observation(clearance, %{cancelled?: callback},
               actor: context.operator
             )

    assert Exception.message(error) =~ "redfish_page_context_unavailable"
    assert Target.Error.context_failure?(error)
    assert page_requests.() == before_requests + 2
  end

  test "checked Redfish verification reads generic resources and compares supplied facts",
       context do
    input =
      file_request(context, :verification, %{
        "method" => "GET",
        "uri" => "/redfish/v1/Oem/Property"
      })

    before_writes = Agent.get(context.agent, & &1.writes)

    for {expected, status} <- [
          {%{}, :unknown},
          {%{"response" => %{"Name" => "original"}}, :verified},
          {%{"response" => %{"Name" => "different"}}, :not_verified}
        ] do
      clearance =
        %{input | expected: expected}
        |> Targets.clear_target_request!(actor: context.operator)

      assert %Target.Verification{
               status: ^status,
               facts: %{"response" => %{"Name" => "original"}}
             } =
               Targets.dispatch_target_verification!(clearance, %{}, actor: context.operator)
    end

    assert Agent.get(context.agent, & &1.writes) == before_writes
  end

  test "checked Redfish Method returns exact binary file content without JSON decoding",
       context do
    request = %Request{
      kind: :observation,
      authority_mode: :readonly,
      target_id: context.target.id,
      target_revision: context.target.revision,
      access_method_id: context.method.id,
      access_method_revision: context.method.revision,
      capability: "request.redfish.observe",
      operation: "request.observe",
      parameters: %{
        "method" => "GET",
        "uri" => "/redfish/v1/Oem/Bundle/content",
        "accept" => "application/octet-stream",
        "response_file" => %{"name" => "bundle.bin", "media_type" => "application/octet-stream"}
      }
    }

    result =
      request
      |> Targets.clear_target_request!(actor: context.operator)
      |> Targets.dispatch_target_observation!(%{}, actor: context.operator)

    file = result.facts["file"]
    assert file["size_bytes"] == 5
    assert file["sha256"] == "b55f1659c0645fd1cee6dfa8b3af06795e9da7e48cb65c2b999f896c9f539dbd"

    assert Targets.read_bound_artifact_chunk!(file, 0, actor: context.operator) ==
             <<255, 0, 1, 2, 255>>

    assert result.facts["response"] == %{}

    assert {:ok, _} =
             JSV.validate(
               result.facts,
               JSV.build!(
                 Enum.find(
                   context.method.operation_catalog.observations,
                   &(&1.capability == "request.redfish.observe")
                 ).output_schema
               )
             )
  end

  test "checked Redfish effects send immutable raw and native multipart files", context do
    bytes = <<255, 0, 1, 2, 255>>
    raw = stage_file(context, bytes, "raw.bin", "application/octet-stream")
    boundary = "skopos-wire-boundary"
    media = "multipart/form-data; boundary=#{boundary}"

    multipart =
      IO.iodata_to_binary([
        "--#{boundary}\r\nContent-Disposition: form-data; name=\"UpdateParameters\"\r\nContent-Type: application/json\r\n\r\n{}\r\n",
        "--#{boundary}\r\nContent-Disposition: form-data; name=\"UpdateFile\"; filename=\"firmware.bin\"\r\nContent-Type: application/octet-stream\r\n\r\n",
        bytes,
        "\r\n--#{boundary}--\r\n"
      ])

    envelope = stage_file(context, multipart, "request.multipart", media)

    for {verb, uri, input, content_type, outcome} <- [
          {"PUT", "/redfish/v1/Oem/Bundle/content", raw, "application/octet-stream", :applied},
          {"POST", "/redfish/v1/UpdateService/upload", envelope, media, :unknown}
        ] do
      parameters = %{
        "method" => verb,
        "uri" => uri,
        "body_file" => "payload",
        "files" => %{"payload" => input},
        "content_type" => content_type,
        "response_file" => %{"name" => "reply.bin", "media_type" => "application/octet-stream"}
      }

      clearance =
        file_request(context, :effect, parameters)
        |> Targets.clear_target_request!(actor: context.operator)

      result =
        Targets.dispatch_target_effect!(clearance, %{},
          actor: context.operator,
          authorize?: false
        )

      assert result.status == outcome

      assert Targets.read_bound_artifact_chunk!(result.details["file"], 0,
               actor: context.operator
             ) == bytes

      assert result.details["file"]["sha256"] ==
               "b55f1659c0645fd1cee6dfa8b3af06795e9da7e48cb65c2b999f896c9f539dbd"

      if verb == "POST" do
        assert result.protected_reference["uri"] == "/redfish/v1/TaskService/TaskMonitors/2"
        refute Map.has_key?(result.details, "task_location")
      end

      catalog =
        Enum.find(
          context.method.operation_catalog.effects,
          &(&1.capability == "request.redfish.effect")
        )

      assert {:ok, _} =
               JSV.validate(
                 %{"selectors" => %{}, "parameters" => parameters},
                 JSV.build!(catalog.input_schema)
               )

      for invalid <- [
            Map.put(parameters, "body", %{}),
            Map.put(parameters, "body_file", "missing"),
            Map.put(parameters, "uri", "https://other.example/redfish/v1/UpdateService/upload")
          ] do
        assert {:error, _} =
                 Targets.clear_target_request(file_request(context, :effect, invalid),
                   actor: context.operator
                 )
      end

      Targets.revoke_artifact!(input["id"], actor: context.operator)

      assert {:error, _} =
               Targets.dispatch_target_effect(clearance, %{},
                 actor: context.operator,
                 authorize?: false
               )
    end

    assert Agent.get(context.agent, & &1.file_input) == {bytes, ["application/octet-stream"]}

    {parameter_headers, parameters, file_headers, upload} =
      Agent.get(context.agent, & &1.multipart_input)

    assert parameters == "{}"
    assert upload == bytes

    assert List.keyfind(parameter_headers, "content-disposition", 0) ==
             {"content-disposition", "form-data; name=\"UpdateParameters\""}

    assert List.keyfind(file_headers, "content-disposition", 0) ==
             {"content-disposition", "form-data; name=\"UpdateFile\"; filename=\"firmware.bin\""}

    assert List.keyfind(file_headers, "content-type", 0) ==
             {"content-type", "application/octet-stream"}

    paths = Agent.get(context.agent, & &1.paths)
    assert Enum.count(paths, &(&1 == "/redfish/v1/UpdateService/upload")) == 1
    # One raw PUT, plus no calls after the input file was revoked.
    assert Enum.count(paths, &(&1 == "/redfish/v1/Oem/Bundle/content")) == 1
  end

  test "Redfish overflow and interruption never publish partial files", context do
    previous = Application.get_env(:skopos, :artifact_limits)
    Application.put_env(:skopos, :artifact_limits, %{chunk_bytes: 3, max_size_bytes: 4})

    on_exit(fn ->
      if previous,
        do: Application.put_env(:skopos, :artifact_limits, previous),
        else: Application.delete_env(:skopos, :artifact_limits)
    end)

    for uri <- ["/redfish/v1/Oem/Bundle/content", "/redfish/v1/Oem/Bundle/Interrupted"] do
      clearance =
        file_request(context, :observation, %{
          "method" => "GET",
          "uri" => uri,
          "response_file" => %{
            "name" => "partial.bin",
            "media_type" => "application/octet-stream"
          }
        })
        |> Targets.clear_target_request!(actor: context.operator)

      assert {:error, _} =
               Targets.dispatch_target_observation(clearance, %{}, actor: context.operator)
    end

    receipts = Targets.page_artifacts!(context.target.id, actor: context.operator).results
    assert length(receipts) == 2

    for receipt <- receipts do
      assert receipt.status == :receiving
      assert receipt.received_bytes <= 4
      assert is_nil(receipt.sha256)

      assert {:error, _} =
               Targets.artifact_reference(receipt.id, context.target.id, actor: context.operator)
    end
  end

  test "cancelled Redfish file effects remain unknown without replay", context do
    clearance =
      file_request(context, :effect, %{
        "method" => "POST",
        "uri" => "/redfish/v1/Oem/Bundle/Cancelled",
        "body" => %{},
        "response_file" => %{
          "name" => "cancelled.bin",
          "media_type" => "application/octet-stream"
        }
      })
      |> Targets.clear_target_request!(actor: context.operator)

    assert {:error, _} =
             Targets.dispatch_target_effect(clearance, %{cancelled?: fn -> true end},
               actor: context.operator,
               authorize?: false
             )

    assert Targets.page_artifacts!(context.target.id, actor: context.operator).results == []

    result =
      Targets.dispatch_target_effect!(
        clearance,
        %{cancelled?: fn -> Agent.get(context.agent, &Map.get(&1, :cancelled, false)) end},
        actor: context.operator,
        authorize?: false
      )

    assert result.status == :unknown
    refute Map.has_key?(result.details, "file")
    [receipt] = Targets.page_artifacts!(context.target.id, actor: context.operator).results
    assert receipt.status == :receiving

    assert {:error, _} =
             Targets.artifact_reference(receipt.id, context.target.id, actor: context.operator)

    assert Agent.get(
             context.agent,
             &Enum.count(&1.paths, fn path -> path == "/redfish/v1/Oem/Bundle/Cancelled" end)
           ) == 1
  end

  test "lost Redfish file effect response retains receipt identity without replay", context do
    clearance =
      file_request(context, :effect, %{
        "method" => "POST",
        "uri" => "/redfish/v1/Oem/Drop",
        "body" => %{},
        "response_file" => %{"name" => "lost.bin", "media_type" => "application/octet-stream"}
      })
      |> Targets.clear_target_request!(actor: context.operator)

    result =
      Targets.dispatch_target_effect!(clearance, %{}, actor: context.operator, authorize?: false)

    assert result.status == :unknown
    assert Agent.get(context.agent, & &1.echo_calls) == 1
    [receipt] = Targets.page_artifacts!(context.target.id, actor: context.operator).results
    assert result.details["reason"] =~ receipt.id

    assert {:error, _} =
             Targets.artifact_reference(receipt.id, context.target.id, actor: context.operator)
  end

  @tag file_publication_fault: true
  test "failed Redfish file publication cannot report success or resend the body", context do
    input = stage_file(context, <<255, 0, 1, 2, 255>>, "request.bin", "application/octet-stream")

    Skopos.Repo.query!("""
    CREATE FUNCTION pg_temp.reject_redfish_file_ready() RETURNS trigger LANGUAGE plpgsql AS $$
    BEGIN
      IF NEW.status = 'ready' THEN RAISE EXCEPTION 'injected file publication failure'; END IF;
      RETURN NEW;
    END $$;
    """)

    Skopos.Repo.query!(
      "CREATE TRIGGER reject_redfish_file_ready BEFORE UPDATE ON artifacts FOR EACH ROW EXECUTE FUNCTION pg_temp.reject_redfish_file_ready()"
    )

    clearance =
      file_request(context, :effect, %{
        "method" => "PUT",
        "uri" => "/redfish/v1/Oem/Bundle/content",
        "body_file" => "payload",
        "files" => %{"payload" => input},
        "content_type" => "application/octet-stream",
        "response_file" => %{"name" => "reply.bin", "media_type" => "application/octet-stream"}
      })
      |> Targets.clear_target_request!(actor: context.operator)

    assert {:error, error} =
             Targets.dispatch_target_effect(clearance, %{},
               actor: context.operator,
               authorize?: false
             )

    assert Exception.message(error) =~ "injected file publication failure"
    receipts = Targets.page_artifacts!(context.target.id, actor: context.operator).results
    receipt = Enum.find(receipts, &(&1.id != input["id"]))
    assert receipt.status == :receiving
    assert receipt.received_bytes == 5

    assert Target.Error.context_progress(error) == %{
             "http_status" => 200,
             "receiving_file_id" => receipt.id,
             "received_bytes" => 5
           }

    assert {:error, _} =
             Targets.artifact_reference(receipt.id, context.target.id, actor: context.operator)

    assert Agent.get(
             context.agent,
             &Enum.count(&1.paths, fn path -> path == "/redfish/v1/Oem/Bundle/content" end)
           ) == 1
  end

  test "an undecodable reply after a Redfish change stays unknown", context do
    clearance =
      file_request(context, :effect, %{
        "method" => "POST",
        "uri" => "/redfish/v1/Oem/Malformed",
        "body" => %{}
      })
      |> Targets.clear_target_request!(actor: context.operator)

    result =
      Targets.dispatch_target_effect!(clearance, %{}, actor: context.operator, authorize?: false)

    assert result.status == :unknown
    assert Agent.get(context.agent, &{&1.name, &1.writes}) == {"changed", 1}
  end

  test "generic Method registers and dispatches without a selected ComputerSystem", context do
    Agent.update(context.agent, &Map.merge(&1, %{no_system: true, paths: []}))

    provider =
      Providers.create_provider!(
        "service-root-only",
        :target,
        "redfish",
        %{
          "ca_certificate" => File.read!("test/support/certs/kubernetes_fixture_ca.pem")
        },
        %{"username" => "tester", "password" => "secret"},
        actor: context.admin
      )

    checked =
      Skopos.TargetConnectionFixture.check_connection(
        provider,
        context.method.endpoint,
        context.admin
      )

    assert {:ok, _catalog} = checked

    capabilities =
      Providers.target_capabilities!(
        provider.id,
        %Target.CapabilitiesRequest{
          provider_revision: provider.revision,
          connection: %Target.Connection{endpoint: context.method.endpoint}
        },
        %{},
        actor: context.admin
      )

    assert Target.capability_names(capabilities) == [
             "request.redfish.observe",
             "request.redfish.effect"
           ]

    method =
      Targets.create_access_method!(
        context.target.id,
        provider.id,
        "Service root",
        "redfish",
        context.method.endpoint,
        provider.revision,
        100,
        Target.capability_names(capabilities),
        actor: context.admin
      )
      |> then(&Targets.check_access_method!(&1.id, &1.revision, %{}, actor: context.admin))

    read = %Request{
      kind: :observation,
      authority_mode: :readonly,
      target_id: context.target.id,
      target_revision: context.target.revision,
      access_method_id: method.id,
      access_method_revision: method.revision,
      capability: "request.redfish.observe",
      operation: "request.observe",
      parameters: %{"method" => "GET", "uri" => "/redfish/v1/Oem/Example"}
    }

    clearance = Targets.clear_target_request!(read, actor: context.operator)
    observation = Targets.dispatch_target_observation!(clearance, %{}, actor: context.operator)
    assert observation.facts["response"]["Result"] == "safe"

    write = %{
      read
      | kind: :effect,
        authority_mode: :full_access,
        capability: "request.redfish.effect",
        operation: "request.execute",
        operation_id: Ecto.UUID.generate(),
        idempotency_key: Ecto.UUID.generate(),
        parameters: %{
          "method" => "PATCH",
          "uri" => "/redfish/v1/Oem/Property",
          "body" => %{"Name" => "generic"}
        }
    }

    clearance = Targets.clear_target_request!(write, actor: context.operator)

    assert %{status: :applied, details: %{"http_status" => 204}} =
             Targets.dispatch_target_effect!(clearance, %{},
               actor: context.operator,
               authorize?: false
             )

    assert Agent.get(context.agent, & &1.name) == "generic"
    read = %{read | parameters: %{"method" => "GET", "uri" => "/redfish/v1/Oem/Property"}}
    clearance = Targets.clear_target_request!(read, actor: context.operator)

    assert %Target.Observation{facts: %{"response" => %{"Name" => "generic"}}} =
             Targets.dispatch_target_observation!(clearance, %{}, actor: context.operator)

    refute Enum.any?(
             Agent.get(context.agent, & &1.paths),
             &String.starts_with?(&1, "/redfish/v1/Systems")
           )
  end

  test "an opaque async monitor is retained privately without a TaskService path assumption",
       context do
    {:ok, state} = redfish_state(context.method.endpoint)

    assert {:ok, %Target.EffectResult{status: :unknown} = result} =
             Redfish.effect(
               state,
               method_effect_request(context, "POST", "/redfish/v1/Oem/OpaqueAsync", %{})
               |> Map.update!(:parameters, &Map.put(&1, "include_response", true)),
               %{}
             )

    assert result.protected_reference == %{
             "kind" => "redfish_task_monitor",
             "uri" => "/vendor/monitor/session-secret?ticket=private-value",
             "retry_after_seconds" => 3
           }

    refute Jason.encode!(result.details) =~ "session-secret"
    refute Jason.encode!(result.details) =~ "private-value"
    assert result.details["retry_after_seconds"] == 3
    refute inspect(result) =~ "private-value"
    refute Map.has_key?(result.details, "task_location")

    retry_at = DateTime.add(DateTime.utc_now(), 120, :second)

    Agent.update(
      context.agent,
      &Map.put(&1, :retry_after, Calendar.strftime(retry_at, "%a, %d %b %Y %H:%M:%S GMT"))
    )

    assert {:ok, timed} =
             Redfish.effect(
               state,
               method_effect_request(context, "POST", "/redfish/v1/Oem/OpaqueAsync", %{}),
               %{}
             )

    assert timed.protected_reference["retry_after_seconds"] in 118..120

    Agent.update(context.agent, &Map.put(&1, :retry_after, "not a valid delay"))

    assert {:ok, malformed} =
             Redfish.effect(
               state,
               method_effect_request(context, "POST", "/redfish/v1/Oem/OpaqueAsync", %{}),
               %{}
             )

    assert malformed.status == :unknown

    assert malformed.protected_reference["uri"] ==
             "/vendor/monitor/session-secret?ticket=private-value"

    refute Map.has_key?(malformed.protected_reference, "retry_after_seconds")

    Agent.update(
      context.agent,
      &Map.put(
        &1,
        :task_location,
        "https://other.example/vendor/monitor/session-secret?ticket=private-value"
      )
    )

    assert {:ok, outside} =
             Redfish.effect(
               state,
               method_effect_request(context, "POST", "/redfish/v1/Oem/OpaqueAsync", %{})
               |> Map.update!(:parameters, &Map.put(&1, "include_response", true)),
               %{}
             )

    assert outside.status == :unknown
    assert outside.protected_reference == nil
    refute Jason.encode!(outside.details) =~ "private-value"
    refute Jason.encode!(outside.details) =~ "session-secret"
  end

  test "the checked read Method follows only the supplied protected task reference", context do
    reference_id = Ecto.UUID.generate()

    request =
      file_request(context, :observation, %{"result_reference" => reference_id})
      |> Map.put(:operation, "task.observe")

    clearance = Targets.clear_target_request!(request, actor: context.operator)

    invocation = %{
      result_reference_reader: fn ^reference_id ->
        {:ok,
         %{
           "kind" => "redfish_task_monitor",
           "uri" => "/vendor/monitor/session-secret?ticket=private-value"
         }}
      end
    }

    assert %Target.Observation{facts: facts} =
             Targets.dispatch_target_observation!(clearance, invocation, actor: context.operator)

    assert facts["http_status"] == 202
    assert facts["task_state"] == "Running"
    assert facts["task_outcome"] == "running"
    assert facts["retry_after_seconds"] == 3
    assert Agent.get(context.agent, & &1.monitor_query) == "ticket=private-value"
    refute Jason.encode!(facts) =~ "private-value"

    Agent.update(context.agent, &Map.merge(&1, %{monitor_status: 204, monitor_body: %{}}))

    completed =
      Targets.dispatch_target_observation!(clearance, invocation, actor: context.operator)

    assert completed.facts["task_outcome"] == "completed"
    refute inspect(completed) =~ "session-secret"

    for {status, body, expected} <- [
          {200, %{"TaskState" => "Exception"}, "failed"},
          {200, %{"TaskState" => "FutureState", "TaskMonitor" => "private-value"}, "unknown"},
          {200, "opaque native response", "completed"},
          {404, %{}, "unavailable"},
          {410, %{}, "unavailable"},
          {403, %{}, "unknown"},
          {302, %{}, "unknown"},
          {500, %{}, "failed"}
        ] do
      Agent.update(context.agent, &Map.merge(&1, %{monitor_status: status, monitor_body: body}))

      observation =
        Targets.dispatch_target_observation!(clearance, invocation, actor: context.operator)

      assert observation.facts["http_status"] == status
      assert observation.facts["task_outcome"] == expected
      refute inspect(observation) =~ "private-value"
    end

    paths = Agent.get(context.agent, & &1.paths)

    for uri <- [
          "https://other.example/vendor/task?ticket=private-value",
          "https://user:password@127.0.0.1/vendor/task",
          "//other.example/vendor/task",
          "/vendor/task#fragment",
          "/vendor/task\r\nheader"
        ] do
      denied = %{
        result_reference_reader: fn ^reference_id ->
          {:ok, %{"kind" => "redfish_task_monitor", "uri" => uri}}
        end
      }

      assert {:error, _} =
               Targets.dispatch_target_observation(clearance, denied, actor: context.operator)

      assert Agent.get(context.agent, & &1.paths) == paths
    end

    assert {:error, _} =
             Targets.dispatch_target_observation(clearance, %{}, actor: context.operator)

    assert Agent.get(context.agent, & &1.paths) == paths

    assert Agent.get(context.agent, & &1.writes) == 0
  end

  @tag protected_reference_fault: true
  test "saved monitor input faults retain their cause without sending or retrying HTTP",
       context do
    reference = Ecto.UUID.generate()

    cause =
      Ash.Error.Unknown.exception(errors: [RuntimeError.exception("stored input read failed")])

    paths = Agent.get(context.agent, & &1.paths)

    for {kind, operation, parameters} <- [
          {:observation, "request.observe",
           %{"method" => "GET", "result_reference" => reference}},
          {:observation, "task.observe", %{"result_reference" => reference}},
          {:effect, "request.execute", %{"method" => "DELETE", "result_reference" => reference}}
        ] do
      request = file_request(context, kind, parameters) |> Map.put(:operation, operation)
      clearance = Targets.clear_target_request!(request, actor: context.operator)

      invocation = %{
        result_reference_reader: fn ^reference ->
          send(self(), :input_read)
          {:error, cause}
        end
      }

      result =
        case kind do
          :observation ->
            Targets.dispatch_target_observation(clearance, invocation, actor: context.operator)

          :effect ->
            Targets.dispatch_target_effect(clearance, invocation,
              actor: context.operator,
              authorize?: false
            )
        end

      assert {:error, error} = result
      assert %Target.BeforeSendError{cause: ^cause} = Target.BeforeSendError.unwrap(error)
      assert_receive :input_read
      refute_receive :input_read, 0
      assert Agent.get(context.agent, & &1.paths) == paths
    end
  end

  test "saved monitor destinations bind the exact native request and fail before sending unavailable references",
       context do
    reference = Ecto.UUID.generate()
    uri = "/vendor/monitor/session-secret?ticket=private-value"

    invocation = %{
      result_reference_reader: fn ^reference ->
        {:ok, %{"kind" => "redfish_task_monitor", "uri" => uri}}
      end
    }

    request =
      file_request(context, :effect, %{
        "method" => "PATCH",
        "result_reference" => reference,
        "body" => %{"TaskState" => "Suspended"},
        "include_response" => true
      })
      |> Map.put(:selectors, %{"if_match" => ~s("task-rev-3")})

    clearance = Targets.clear_target_request!(request, actor: context.operator)

    assert %Target.EffectResult{status: :applied} =
             result =
             Targets.dispatch_target_effect!(clearance, invocation,
               actor: context.operator,
               authorize?: false
             )

    {"ticket=private-value", bytes, [~s("task-rev-3")]} =
      Agent.get(context.agent, & &1.monitor_patch)

    assert Jason.decode!(bytes) == %{"TaskState" => "Suspended"}
    refute Jason.encode!(result.details) =~ "private-value"
    refute inspect(result) =~ "session-secret"

    Agent.update(
      context.agent,
      &Map.merge(&1, %{
        monitor_status: 200,
        monitor_body: %{
          "TaskMonitor" => uri,
          "Ticket" => "private-value",
          "TaskState" => "Suspended"
        }
      })
    )

    read =
      file_request(context, :observation, %{"method" => "GET", "result_reference" => reference})

    read_clearance = Targets.clear_target_request!(read, actor: context.operator)

    observed =
      Targets.dispatch_target_observation!(read_clearance, invocation, actor: context.operator)

    assert observed.facts["response"]["TaskState"] == "Suspended"
    assert [%{"result_reference" => ^reference}] = observed.evidence
    refute Jason.encode!(Map.take(observed, [:facts, :evidence])) =~ "private-value"
    refute inspect(observed) =~ "session-secret"
    paths = Agent.get(context.agent, & &1.paths)

    for parameters <- [
          Map.put(request.parameters, "uri", "/redfish/v1/Oem/Property"),
          Map.delete(request.parameters, "result_reference"),
          Map.put(request.parameters, "result_reference", "invalid-reference")
        ] do
      assert {:error, _} =
               Targets.clear_target_request(%{request | parameters: parameters},
                 actor: context.operator
               )

      assert Agent.get(context.agent, & &1.paths) == paths
    end

    for reader <- [
          fn ^reference -> {:error, "Remote result reference is unavailable"} end,
          fn ^reference -> {:ok, %{"kind" => "another_protocol", "uri" => uri}} end,
          fn ^reference ->
            {:ok,
             %{"kind" => "redfish_task_monitor", "uri" => "https://other.example/vendor/task"}}
          end
        ] do
      assert {:error, _} =
               Targets.dispatch_target_effect(clearance, %{result_reference_reader: reader},
                 actor: context.operator,
                 authorize?: false
               )

      assert {:error, _} =
               Targets.dispatch_target_observation(
                 read_clearance,
                 %{result_reference_reader: reader},
                 actor: context.operator
               )

      assert Agent.get(context.agent, & &1.paths) == paths
    end

    assert {:error, _} =
             Targets.dispatch_target_effect(clearance, %{},
               actor: context.operator,
               authorize?: false
             )

    assert Agent.get(context.agent, & &1.paths) == paths
  end

  @tag protected_reference_case: true
  test "a reviewed Case write is followed through its saved monitor without resolving the Case",
       context do
    ai =
      Providers.create_provider!(
        "Task AI fixture",
        :ai,
        "fixture-ai",
        %{"model" => "task-fixture"},
        %{"api_key" => "test-only"},
        actor: context.admin
      )
      |> then(&Providers.check_provider!(&1.id, &1.revision, %{}, actor: context.admin))
      |> then(&Providers.enable_provider!(&1, &1.revision, actor: context.admin))

    assignments = Skopos.TestAIUsage.configure!(ai.id, :all, 10, context.admin)
    setting = Cases.current_authority_setting!(actor: context.admin)

    Cases.configure_authority_setting!(
      setting.setting_revision,
      :auto,
      setting.signal_automation_enabled,
      setting.max_elapsed_seconds,
      setting.max_resolver_turns,
      setting.max_target_requests,
      setting.max_effects,
      setting.max_related_targets,
      setting.max_ai_usage_units,
      setting.max_no_progress_turns,
      "Task Case fixture",
      actor: context.admin
    )

    incident =
      Cases.open_case!(
        :manual,
        "test",
        Ecto.UUID.generate(),
        "Apply asynchronous configuration",
        :warning,
        %{"desired_outcome" => "The requested configuration works"},
        context.target.id,
        :en,
        actor: context.operator
      )

    context = Map.merge(context, %{ai: ai, assignments: assignments, incident: incident})

    proposal =
      task_case_proposal!(context, :effect, "request.execute", %{
        "method" => "POST",
        "uri" => "/redfish/v1/Oem/OpaqueAsync",
        "body" => %{}
      })

    assert proposal.status == :reviewing

    assert :ok =
             Skopos.Cases.Proposal.ReviewDelivery.run(proposal.id,
               ai_invocation: %{
                 test_pid: self(),
                 respond: fn request ->
                   send(self(), {:task_reviewed, request.proposal.parameters})

                   {:ok,
                    %Skopos.Providers.AI.ReviewDecision{
                      verdict: :approved,
                      purpose_assessment: :remediation,
                      reason: "Approve this exact async write",
                      usage: %Skopos.Providers.AI.Usage{input_tokens: 3, output_tokens: 2}
                    }}
                 end
               }
             )

    assert_receive {:task_reviewed, %{"uri" => "/redfish/v1/Oem/OpaqueAsync"}}
    operation = Cases.accept_operation!(proposal.id, authorize?: false)
    assert :ok = Skopos.Cases.Operation.Delivery.run(operation.id)
    stored = Cases.get_operation!(operation.id, actor: context.operator)
    assert stored.status == :unknown
    assert stored.reference == operation.id

    for {http_status, body, expected} <- [
          {202, %{"TaskState" => "Running"}, "running"},
          {204, %{}, "completed"}
        ] do
      Agent.update(
        context.agent,
        &Map.merge(&1, %{monitor_status: http_status, monitor_body: body})
      )

      observation =
        task_case_proposal!(context, :observation, "task.observe", %{
          "result_reference" => operation.id
        })

      follow_up = Cases.accept_operation!(observation.id, authorize?: false)

      if http_status == 202 do
        assert_unsent_reference_retry(context, operation, follow_up)
      end

      assert :ok = Skopos.Cases.Operation.Delivery.run(follow_up.id)
      result = Cases.get_operation!(follow_up.id, actor: context.operator)
      assert result.status == :applied
      assert result.result_details["facts"]["task_outcome"] == expected
      assert Cases.get_case!(incident.id, actor: context.operator).status == :running
      refute Jason.encode!(SkoposWeb.API.V1.WorkflowJSON.operation(result)) =~ "private-value"
      assert Agent.get(context.agent, & &1.monitor_query) == "ticket=private-value"
    end

    fresh_observation =
      Cases.list_evidence!(actor: context.operator)
      |> Enum.filter(
        &(&1.case_id == incident.id and &1.source == "operation" and
            &1.content["status"] == "applied")
      )
      |> Enum.max_by(& &1.observed_at, DateTime)

    cancellation =
      task_case_proposal!(
        Map.put(context, :evidence, fresh_observation),
        :effect,
        "request.execute",
        %{
          "method" => "DELETE",
          "result_reference" => operation.id
        }
      )

    assert cancellation.status == :reviewing

    assert :ok =
             Skopos.Cases.Proposal.ReviewDelivery.run(cancellation.id,
               ai_invocation: %{
                 test_pid: self(),
                 respond: fn request ->
                   send(self(), {:monitor_effect_review, request.proposal.parameters})

                   {:ok,
                    %Skopos.Providers.AI.ReviewDecision{
                      verdict: :approved,
                      purpose_assessment: :remediation,
                      reason: "Approve this exact new request on the saved monitor",
                      usage: %Skopos.Providers.AI.Usage{input_tokens: 3, output_tokens: 2}
                    }}
                 end
               }
             )

    assert_receive {:monitor_effect_review,
                    %{"method" => "DELETE", "result_reference" => reference}}

    assert reference == operation.id
    cancelled = Cases.accept_operation!(cancellation.id, authorize?: false)
    assert_unsent_reference_retry(context, operation, cancelled)
    assert :ok = Skopos.Cases.Operation.Delivery.run(cancelled.id)
    cancellation_result = Cases.get_operation!(cancelled.id, actor: context.operator)

    assert cancellation_result.status == :applied,
           inspect(
             Map.take(cancellation_result, [
               :status,
               :outcome_category,
               :outcome_message,
               :result_details
             ])
           )

    assert Agent.get(context.agent, & &1.async_cancels) == 1
    assert Agent.get(context.agent, & &1.cancel_query) == "ticket=private-value"
    assert Agent.get(context.agent, & &1.async_writes) == 1

    effect_clearance =
      Targets.clear_target_request!(
        file_request(context, :effect, %{"method" => "DELETE", "result_reference" => operation.id}),
        actor: context.operator
      )

    assert {:ok, %{"kind" => "redfish_task_monitor"}} =
             Cases.read_operation_result_reference(operation.id, incident.id, effect_clearance,
               actor: context.operator
             )

    paths = Agent.get(context.agent, & &1.paths)

    for {case_id, offered, actor} <- [
          {Ecto.UUID.generate(), effect_clearance, context.operator},
          {incident.id, effect_clearance, context.admin},
          {incident.id, %{effect_clearance | target_id: Ecto.UUID.generate()}, context.operator},
          {incident.id, %{effect_clearance | access_method_id: Ecto.UUID.generate()},
           context.operator},
          {incident.id, %{effect_clearance | provider_id: Ecto.UUID.generate()}, context.operator}
        ] do
      reader = fn id ->
        Cases.read_operation_result_reference(id, case_id, offered, actor: actor)
      end

      assert {:error, _} =
               Targets.dispatch_target_effect(
                 effect_clearance,
                 %{result_reference_reader: reader},
                 actor: context.operator,
                 authorize?: false
               )

      assert Agent.get(context.agent, & &1.paths) == paths
    end

    current = Cases.get_case!(incident.id, actor: context.operator)
    assert {:error, _} = Skopos.Cases.Operation.Delivery.run(operation.id)

    assert Cases.get_case!(incident.id, actor: context.operator).pending_intent ==
             current.pending_intent

    assert Agent.get(context.agent, & &1.async_writes) == 1

    rejected =
      task_case_proposal!(
        Map.put(context, :evidence, fresh_observation),
        :effect,
        "request.execute",
        %{
          "method" => "DELETE",
          "result_reference" => operation.id
        }
      )

    paths = Agent.get(context.agent, & &1.paths)

    assert :ok =
             Skopos.Cases.Proposal.ReviewDelivery.run(rejected.id,
               ai_invocation: %{
                 test_pid: self(),
                 respond: fn request ->
                   send(self(), {:monitor_effect_rejected, request.proposal.parameters})

                   {:ok,
                    %Skopos.Providers.AI.ReviewDecision{
                      verdict: :rejected,
                      purpose_assessment: :remediation,
                      reason: "Do not cancel this task again",
                      usage: %Skopos.Providers.AI.Usage{input_tokens: 3, output_tokens: 2}
                    }}
                 end
               }
             )

    assert_receive {:monitor_effect_rejected,
                    %{"method" => "DELETE", "result_reference" => ^reference}}

    assert Cases.get_proposal!(rejected.id, actor: context.operator).status == :rejected
    assert {:error, _} = Cases.accept_operation(rejected.id, authorize?: false)
    assert Agent.get(context.agent, & &1.paths) == paths
    assert Agent.get(context.agent, & &1.async_cancels) == 1

    missing_proposal =
      task_case_proposal!(context, :observation, "task.observe", %{
        "result_reference" => operation.id
      })

    missing_operation = Cases.accept_operation!(missing_proposal.id, authorize?: false)
    source_id = Ecto.UUID.dump!(operation.id)

    %{rows: [[ciphertext]]} =
      Repo.query!("SELECT encrypted_protected_reference FROM operations WHERE id = $1", [
        source_id
      ])

    Repo.query!("UPDATE operations SET encrypted_protected_reference = NULL WHERE id = $1", [
      source_id
    ])

    try do
      assert :ok = Skopos.Cases.Operation.Delivery.run(missing_operation.id)
    after
      Repo.query!("UPDATE operations SET encrypted_protected_reference = $1 WHERE id = $2", [
        ciphertext,
        source_id
      ])
    end

    missing = Cases.get_operation!(missing_operation.id, actor: context.operator)
    assert missing.status == :failed
    assert missing.outcome_category == "input_unavailable"
    assert missing.dispatch_started_at == nil
    assert Agent.get(context.agent, & &1.paths) == paths
    assert :ok = Skopos.Cases.Operation.Delivery.run(missing_operation.id)
    assert Agent.get(context.agent, & &1.paths) == paths

    proposal =
      task_case_proposal!(context, :observation, "task.observe", %{
        "result_reference" => operation.id
      })

    denied_operation = Cases.accept_operation!(proposal.id, authorize?: false)
    paths = Agent.get(context.agent, & &1.paths)
    method = Targets.get_access_method!(context.method.id, actor: context.admin)

    Targets.update_access_method!(
      method,
      method.revision,
      %{capabilities: ["request.redfish.effect"]},
      actor: context.admin
    )

    assert :ok = Skopos.Cases.Operation.Delivery.run(denied_operation.id)
    denied = Cases.get_operation!(denied_operation.id, actor: context.operator)
    assert denied.status == :failed
    assert denied.outcome_category == "authorization_invalidated"
    assert Agent.get(context.agent, & &1.paths) == paths
  end

  defp assert_unsent_reference_retry(context, source, follow_up) do
    paths = Agent.get(context.agent, & &1.paths)
    ai_invocations = Cases.list_ai_invocations!(authorize?: false)
    source_id = Ecto.UUID.dump!(source.id)

    %{rows: [[ciphertext]]} =
      Repo.query!(
        "SELECT encrypted_protected_reference FROM operations WHERE id = $1",
        [source_id]
      )

    Repo.query!(
      "UPDATE operations SET encrypted_protected_reference = $1 WHERE id = $2",
      ["invalid encrypted input", source_id]
    )

    try do
      assert {:error, error} = Skopos.Cases.Operation.Delivery.run(follow_up.id)
      assert Exception.message(error) =~ "non-alphabet"
    after
      Repo.query!(
        "UPDATE operations SET encrypted_protected_reference = $1 WHERE id = $2",
        [ciphertext, source_id]
      )
    end

    unsent = Cases.get_operation!(follow_up.id, actor: context.operator)
    assert unsent.status == :queued
    assert unsent.dispatch_started_at == nil
    assert Agent.get(context.agent, & &1.paths) == paths
    assert Agent.get(context.agent, & &1.async_writes) == 1
    assert Cases.list_ai_invocations!(authorize?: false) == ai_invocations
    refute Jason.encode!(SkoposWeb.API.V1.WorkflowJSON.operation(unsent)) =~ "private-value"
  end

  defp task_case_proposal!(context, kind, operation, parameters) do
    incident = Cases.get_case!(context.incident.id, actor: context.operator)
    run = Cases.active_resolution_run!(incident.id, authorize?: false)

    evidence =
      Map.get_lazy(context, :evidence, fn ->
        Cases.append_evidence!(
          incident.id,
          run.id,
          nil,
          Ecto.UUID.generate(),
          "observation",
          "tls-fixture",
          "task-peer",
          %{"target_id" => context.target.id},
          DateTime.utc_now(),
          authorize?: false
        )
      end)

    capability = if kind == :effect, do: "request.redfish.effect", else: "request.redfish.observe"

    tool = %{
      "id" => Ecto.UUID.generate(),
      "request_kind" => Atom.to_string(kind),
      "target_id" => context.target.id,
      "target_revision" => context.target.revision,
      "access_method_id" => context.method.id,
      "access_method_revision" => context.method.revision,
      "provider_id" => context.method.provider_id,
      "provider_revision" => context.method.provider_revision,
      "capability" => capability,
      "operation" => operation
    }

    intent = %{
      "type" => "proposal",
      "delay_seconds" => 0,
      "purpose" => if(kind == :effect, do: "remediation", else: "investigation"),
      "request_kind" => tool["request_kind"],
      "tool_id" => tool["id"],
      "tool" => tool,
      "target_id" => context.target.id,
      "target_revision" => context.target.revision,
      "access_method_id" => context.method.id,
      "access_method_revision" => context.method.revision,
      "capability" => capability,
      "operation" => operation,
      "selectors" => %{},
      "parameters" => parameters,
      "reason" => "Send this exact task request",
      "evidence_ids" => [evidence.id],
      "affected_conditions" => [],
      "expected_result" =>
        if(kind == :effect,
          do: %{"desired_outcome" => "The requested configuration works"},
          else: %{}
        ),
      "verification_intent" => %{},
      "verification_tool" => %{}
    }

    turn =
      case Cases.started_turns_for_run!(run.id, authorize?: false) do
        [started] ->
          started

        [] ->
          Cases.start_turn!(
            incident.id,
            run.id,
            Ecto.UUID.generate(),
            %{"objective" => "Check task progress"},
            %{"action" => "continue"},
            "Review limits",
            authorize?: false
          ).value
      end

    resolver = context.assignments.resolver

    result = %{
      "outcome" => "decision",
      "intent" => intent,
      "resolver" => %{
        "provider_id" => context.ai.id,
        "provider_revision" => context.ai.revision,
        "assignment_id" => resolver.id,
        "assignment_revision" => resolver.revision
      },
      "usage" => %{"input_tokens" => 1, "output_tokens" => 1}
    }

    completed =
      Cases.complete_turn!(
        turn.id,
        turn.revision,
        result,
        :proposal,
        %{"action" => "route_resolver_decision", "turn_id" => turn.id},
        "Review request",
        authorize?: false
      ).value

    Cases.route_resolver_decision!(completed.id, authorize?: false)
    Cases.proposal_by_source_turn!(completed.id, authorize?: false)
  end

  test "Redfish Method effects validate URI and ETag and preserve uncertain results", context do
    {:ok, state} = redfish_state(context.method.endpoint)
    {:ok, capabilities} = Redfish.capabilities(state, %{})

    assert Enum.any?(capabilities.effects, fn operation ->
             operation.capability == "request.redfish.effect"
           end)

    assert "request.redfish.effect" in Redfish.access_method_profile().capabilities

    request = method_effect_request(context, "PATCH", @system_path, %{"Name" => "requested"})
    request = %{request | selectors: %{"if_match" => ~s("rev-1")}}

    assert {:ok, %{status: :applied, details: %{"http_status" => 204}}} =
             Redfish.effect(state, request, %{})

    assert Agent.get(context.agent, &{&1.name, &1.writes}) == {"requested", 1}

    for uri <- ["https://other.example/redfish/v1/Systems/1", "/redfish/v1/../Oem/Plain"] do
      assert {:error, :failed, _} =
               Redfish.effect(state, method_effect_request(context, "POST", uri, %{}), %{})
    end

    oversized =
      method_effect_request(context, "POST", "/redfish/v1/Oem/Plain", %{
        "Value" => String.duplicate("x", 70_000)
      })

    assert {:error, :failed, _} = Redfish.effect(state, oversized, %{})

    assert {:ok, %{status: :applied, details: plain}} =
             Redfish.effect(
               state,
               method_effect_request(context, "POST", "/redfish/v1/Oem/Plain", %{}),
               %{}
             )

    assert plain == %{"http_status" => 200, "response_redacted" => true}

    assert {:ok, %{status: :unknown} = async} =
             Redfish.effect(
               state,
               method_effect_request(context, "POST", "/redfish/v1/Oem/AsyncSafe", %{}),
               %{}
             )

    assert async.protected_reference["uri"] == "/redfish/v1/TaskService/TaskMonitors/2"
    refute Map.has_key?(async.details, "task_location")

    assert {:ok, %{status: :unknown, details: lost}} =
             Redfish.effect(
               state,
               method_effect_request(context, "POST", "/redfish/v1/Oem/Drop", %{}),
               %{}
             )

    assert lost["reason"] =~ "lost"
    assert Agent.get(context.agent, & &1.echo_calls) == 1
  end

  test "named controller profiles share generic requests and uncertain delivery", context do
    for type <- ["hpe-ilo-redfish", "dell-idrac-redfish"] do
      provider =
        Providers.create_provider!(
          type,
          :target,
          type,
          %{
            "ca_certificate" => File.read!("test/support/certs/kubernetes_fixture_ca.pem")
          },
          %{"username" => "tester", "password" => "secret"},
          actor: context.admin
        )

      checked =
        Skopos.TargetConnectionFixture.check_connection(
          provider,
          context.method.endpoint,
          context.admin
        )

      assert {:ok, _catalog} = checked

      capabilities =
        Providers.target_capabilities!(
          provider.id,
          %Target.CapabilitiesRequest{
            provider_revision: provider.revision,
            connection: %Target.Connection{endpoint: context.method.endpoint}
          },
          %{},
          actor: context.admin
        )

      assert Target.capability_names(capabilities) == [
               "request.redfish.observe",
               "request.redfish.effect"
             ]

      {:ok, adapter} = Providers.Registry.fetch(type, Target)
      assert adapter.type() == type
      assert adapter.access_method_profile().method == "redfish"

      read = %Target.ObservationRequest{
        provider_revision: provider.revision,
        target_id: context.target.id,
        target_revision: context.target.revision,
        access_method_id: context.method.id,
        access_method_revision: context.method.revision,
        connection: %Target.Connection{endpoint: context.method.endpoint},
        capability: "request.redfish.observe",
        operation: "request.observe",
        authorization_digest: "fixture",
        parameters: %{"method" => "GET", "uri" => "/redfish/v1/Oem/Example"}
      }

      assert %Target.Observation{facts: %{"response" => %{"Result" => "safe"}}} =
               Providers.target_observe!(provider.id, read, %{},
                 actor: context.admin,
                 authorize?: false
               )

      effect =
        struct!(
          Target.EffectRequest,
          Map.merge(
            Map.take(
              Map.from_struct(read),
              [
                :provider_revision,
                :target_id,
                :target_revision,
                :access_method_id,
                :access_method_revision,
                :connection,
                :authorization_digest
              ]
            ),
            %{
              capability: "request.redfish.effect",
              operation: "request.execute",
              operation_id: Ecto.UUID.generate(),
              idempotency_key: Ecto.UUID.generate(),
              parameters: %{"method" => "POST", "uri" => "/redfish/v1/Oem/Drop", "body" => %{}}
            }
          )
        )

      assert %Target.EffectResult{status: :unknown, details: %{"reason" => reason}} =
               Providers.target_effect!(provider.id, effect, %{},
                 actor: context.admin,
                 authorize?: false
               )

      assert reason =~ "lost"
    end

    assert Agent.get(context.agent, & &1.echo_calls) == 2
  end

  test "power observation and effect keep the observed-state precondition", context do
    {:ok, state} = redfish_state(context.method.endpoint)

    observation = %Target.ObservationRequest{
      provider_revision: context.method.provider_revision,
      target_id: context.target.id,
      target_revision: context.target.revision,
      access_method_id: context.method.id,
      access_method_revision: context.method.revision,
      connection: %Target.Connection{endpoint: context.method.endpoint},
      capability: "observe.power",
      operation: "bmc.power.inspect",
      authorization_digest: "fixture"
    }

    before_paths = Agent.get(context.agent, & &1.paths)

    for {message, callback} <- [
          {"redfish_initial_power_context_unavailable",
           fn ->
             {:error, cause} =
               Skopos.Repo.query("SELECT redfish_initial_power_context_unavailable", [],
                 mode: :savepoint
               )

             raise cause
           end},
          {"redfish_initial_power_throw", fn -> throw(:redfish_initial_power_throw) end}
        ] do
      assert {:error, %Target.BeforeSendError{cause: cause}} =
               Redfish.observe(state, observation, %{cancelled?: callback})

      assert Exception.message(cause) =~ message
      assert Agent.get(context.agent, & &1.paths) == before_paths
    end

    assert {:ok, %Target.Observation{facts: %{"power_state" => "on"}}} =
             Redfish.observe(state, observation, %{})

    effect = %Target.EffectRequest{
      provider_revision: context.method.provider_revision,
      target_id: context.target.id,
      target_revision: context.target.revision,
      access_method_id: context.method.id,
      access_method_revision: context.method.revision,
      connection: observation.connection,
      capability: "effect.power",
      operation: "bmc.power.off",
      authorization_digest: "fixture",
      operation_id: Ecto.UUID.generate(),
      idempotency_key: Ecto.UUID.generate(),
      parameters: %{"observed_power_state" => "off"}
    }

    assert {:error, :failed, _} = Redfish.effect(state, effect, %{})
    assert Agent.get(context.agent, & &1.writes) == 0

    assert {:ok, %Target.EffectResult{status: :applied}} =
             Redfish.effect(
               state,
               %{effect | parameters: %{"observed_power_state" => "on"}},
               %{}
             )

    assert Agent.get(context.agent, & &1.writes) == 1

    assert {:ok, %Target.Observation{facts: %{"power_state" => "off"}}} =
             Redfish.observe(state, observation, %{})
  end

  test "System identity constrains power convenience without blocking the protocol", context do
    {:ok, state} = redfish_state(context.method.endpoint)
    state = %{state | expected_uuid: "different-system"}
    assert :ok = Redfish.check(state, %{"endpoint" => context.method.endpoint})
    assert {:ok, capabilities} = Redfish.capabilities(state, %{})

    assert Target.capability_names(capabilities) == [
             "request.redfish.observe",
             "request.redfish.effect"
           ]

    request = %Target.ObservationRequest{
      provider_revision: context.method.provider_revision,
      target_id: context.target.id,
      target_revision: context.target.revision,
      access_method_id: context.method.id,
      access_method_revision: context.method.revision,
      connection: %Target.Connection{endpoint: context.method.endpoint},
      capability: "request.redfish.observe",
      operation: "request.observe",
      authorization_digest: "fixture",
      parameters: %{"method" => "GET", "uri" => "/redfish/v1/Oem/Example"}
    }

    assert {:ok, %Target.Observation{facts: %{"response" => %{"Result" => "safe"}}}} =
             Redfish.observe(state, request, %{})

    power = %{
      request
      | capability: "observe.power",
        operation: "bmc.power.inspect",
        parameters: %{}
    }

    assert {:error, :failed, message} = Redfish.observe(state, power, %{})
    assert message =~ "identity"
    assert Agent.get(context.agent, & &1.writes) == 0
  end

  defp stage_file(context, bytes, name, media) do
    hash = :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)

    file =
      Targets.begin_artifact!(
        context.target.id,
        name,
        media,
        byte_size(bytes),
        hash,
        "redfish-file-#{System.unique_integer()}",
        actor: context.operator
      )

    Targets.append_artifact_chunk!(file.id, 0, bytes, actor: context.operator)
    Targets.complete_artifact!(file.id, actor: context.operator)
    Targets.artifact_reference!(file.id, context.target.id, actor: context.operator)
  end

  defp file_request(context, kind, parameters) do
    %Request{
      kind: kind,
      authority_mode: :full_access,
      target_id: context.target.id,
      target_revision: context.target.revision,
      access_method_id: context.method.id,
      access_method_revision: context.method.revision,
      capability:
        if(kind == :effect, do: "request.redfish.effect", else: "request.redfish.observe"),
      operation: if(kind == :effect, do: "request.execute", else: "request.observe"),
      operation_id: "redfish-file-#{System.unique_integer()}",
      idempotency_key: "redfish-file-#{System.unique_integer()}",
      parameters: parameters
    }
  end

  defp method_effect_request(context, method, uri, body) do
    %Target.EffectRequest{
      provider_revision: 1,
      target_id: context.target.id,
      target_revision: context.target.revision,
      access_method_id: context.method.id,
      access_method_revision: context.method.revision,
      connection: %Target.Connection{endpoint: context.method.endpoint},
      capability: "request.redfish.effect",
      operation: "request.execute",
      authorization_digest: "fixture",
      operation_id: Ecto.UUID.generate(),
      idempotency_key: Ecto.UUID.generate(),
      parameters: %{"method" => method, "uri" => uri, "body" => body}
    }
  end

  test "Redfish Method reads standard and OEM resources without operation registration",
       context do
    {:ok, state} = redfish_state(context.method.endpoint)
    {:ok, capabilities} = Redfish.capabilities(state, %{})

    assert Enum.any?(capabilities.observations, fn operation ->
             operation.capability == "request.redfish.observe"
           end)

    assert "request.redfish.observe" in Redfish.access_method_profile().capabilities

    assert %Target.Capabilities{} =
             Providers.target_capabilities!(
               context.method.provider_id,
               %Target.CapabilitiesRequest{
                 provider_revision: context.method.provider_revision,
                 connection: %Target.Connection{endpoint: context.method.endpoint}
               },
               %{},
               actor: context.admin
             )

    request = %Target.ObservationRequest{
      provider_revision: 1,
      target_id: context.target.id,
      target_revision: context.target.revision,
      access_method_id: context.method.id,
      access_method_revision: context.method.revision,
      connection: %Target.Connection{endpoint: context.method.endpoint},
      capability: "request.redfish.observe",
      operation: "request.observe",
      authorization_digest: "fixture"
    }

    for {uri, expected} <- [
          {@system_path, "original"},
          {"/redfish/v1/Oem/Example", "safe"}
        ] do
      assert {:ok, observation} =
               Redfish.observe(
                 state,
                 %{request | parameters: %{"method" => "GET", "uri" => uri}},
                 %{}
               )

      assert observation.facts["response"]["Name"] == expected or
               observation.facts["response"]["Result"] == expected

      refute inspect(observation) =~ "fixture-secret"
    end

    assert {:ok, head} =
             Redfish.observe(
               state,
               %{
                 request
                 | parameters: %{"method" => "HEAD", "uri" => "/redfish/v1/Oem/Example"}
               },
               %{}
             )

    assert head.facts == %{"http_status" => 200, "response" => %{}}
    assert [%{"etag" => ~s("oem-1")}] = Enum.map(head.evidence, &Map.take(&1, ["etag"]))

    for parameters <- [
          %{"method" => "POST", "uri" => "/redfish/v1/Oem/Example"},
          %{"method" => "GET", "uri" => "https://other.example/redfish/v1/Oem/Example"},
          %{"method" => "GET", "uri" => "/redfish/v1/Oem/Example", "extra" => true}
        ] do
      assert {:error, :failed, _} =
               Redfish.observe(state, %{request | parameters: parameters}, %{})
    end

    assert {:error, :failed, _} =
             Redfish.observe(
               state,
               %{request | parameters: %{"method" => "GET", "uri" => "/redfish/v1/Oem/Large"}},
               %{}
             )
  end

  test "Provider classifies exact Redfish verbs and rejects malformed connection or URI",
       context do
    request = %Target.MethodRequest{
      provider_revision: context.method.provider_revision,
      connection: %Target.Connection{endpoint: context.method.endpoint},
      capability: "request.redfish.observe",
      operation: "request.observe",
      selectors: %{},
      parameters: %{"method" => "GET", "uri" => "/redfish/v1/Oem/Example"}
    }

    classify = fn input ->
      Providers.target_classify(context.method.provider_id, input, %{}, authorize?: false)
    end

    assert {:ok, %Target.RequestClassification{kind: :observation}} = classify.(request)

    write = %{
      request
      | capability: "request.redfish.effect",
        operation: "request.execute",
        parameters: %{"method" => "POST", "uri" => "/redfish/v1/Oem/Plain", "body" => %{}}
    }

    assert {:ok, %Target.RequestClassification{kind: :effect}} = classify.(write)

    for invalid <- [
          %{request | parameters: %{"method" => "POST", "uri" => "/redfish/v1/Oem/Plain"}},
          %{request | connection: %Target.Connection{endpoint: "https://other.example/redfish"}},
          %{
            write
            | parameters: %{
                "method" => "POST",
                "uri" => "/redfish/v1/../Oem/Plain",
                "body" => %{}
              }
          }
        ] do
      assert {:error, _} = classify.(invalid)
    end

    assert Agent.get(context.agent, & &1.writes) == 0
  end

  test "Case projection reads each checked Method catalog without contacting either endpoint",
       context do
    second_agent =
      start_supervised!(%{
        id: :second_redfish_state,
        start:
          {Agent, :start_link,
           [
             fn ->
               %{revision: 1, name: "second", power: "Unavailable", writes: 0, echo_calls: 0}
             end
           ]}
      })

    second_server =
      start_supervised!(%{
        id: :second_redfish_server,
        start:
          {Bandit, :start_link,
           [
             [
               plug: {Stub, second_agent},
               scheme: :https,
               port: 0,
               certfile: Path.expand("test/support/certs/kubernetes_fixture.pem"),
               keyfile: Path.expand("test/support/certs/kubernetes_fixture_key.pem"),
               startup_log: false
             ]
           ]}
      })

    {:ok, {_address, port}} = ThousandIsland.listener_info(second_server)
    endpoint = "https://127.0.0.1:#{port}"

    second =
      Targets.create_access_method!(
        context.target.id,
        context.method.provider_id,
        "Second controller",
        "redfish",
        endpoint,
        context.method.provider_revision,
        200,
        ["request.redfish.observe", "request.redfish.effect"],
        actor: context.admin
      )
      |> then(&Targets.check_access_method!(&1.id, &1.revision, %{}, actor: context.admin))

    Agent.update(context.agent, &Map.put(&1, :paths, []))
    Agent.update(second_agent, &Map.put(&1, :paths, []))

    incident =
      Skopos.Cases.open_case!(
        :manual,
        "test",
        "checked-method-projection",
        "Investigate controller reachability",
        :warning,
        %{"observed_problem" => "controller alert", "desired_outcome" => "controller healthy"},
        context.target.id,
        :en,
        actor: context.admin
      )

    run = Skopos.Cases.active_resolution_run!(incident.id, authorize?: false)

    turn =
      Skopos.Cases.start_turn!(
        incident.id,
        run.id,
        "checked-method-projection",
        %{"objective" => "Investigate the controller"},
        %{"action" => "continue"},
        "Review Resolver limits",
        authorize?: false
      )

    selection = %Skopos.Providers.AI.Selection{
      role: :resolver,
      provider_id: Ecto.UUID.generate(),
      provider_revision: 1,
      source: :assignment
    }

    assert {:ok, projection, _context} =
             Skopos.Cases.Turn.ResolverProjection.build(turn.value.id, selection)

    assert Enum.any?(
             projection.observation_tools,
             &(&1.access_method_id == context.method.id and &1.capability == "observe.power")
           )

    assert Enum.map(
             Enum.filter(projection.observation_tools, &(&1.access_method_id == second.id)),
             &{&1.capability, &1.operation}
           ) == [
             {"request.redfish.observe", "request.observe"},
             {"request.redfish.observe", "task.observe"}
           ]

    assert Enum.map(
             Enum.filter(
               projection.proposal_tools,
               &(&1.access_method_id == second.id and &1.request_kind == :effect)
             ),
             & &1.capability
           ) == ["request.redfish.effect"]

    assert Agent.get(context.agent, & &1.writes) == 0
    assert Agent.get(second_agent, & &1.writes) == 0
    assert Agent.get(context.agent, & &1.paths) == []
    assert Agent.get(second_agent, & &1.paths) == []
  end

  defp redfish_state(endpoint) do
    with {:ok, state} <-
           Redfish.build(
             %{
               "system_path" => @system_path,
               "expected_uuid" => @uuid,
               "ca_certificate" => File.read!("test/support/certs/kubernetes_fixture_ca.pem")
             },
             %{"username" => "tester", "password" => "secret"}
           ),
         do: Redfish.bind_connection(state, %Target.Connection{endpoint: endpoint})
  end

  setup do
    agent =
      start_supervised!(
        {Agent, fn -> %{revision: 1, name: "original", power: "On", writes: 0, echo_calls: 0} end}
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

    admin =
      Accounts.bootstrap!(
        "bmc-etag-admin@example.invalid",
        "test-only-password",
        "test-only-password"
      )

    operator =
      Accounts.create_user!("bmc-etag-operator@example.invalid", "test-only-password", :operator,
        actor: admin
      )

    target =
      Targets.create_target!("etag-host", "management_plane", "custom-bmc", %{}, nil,
        actor: admin
      )

    provider =
      Providers.create_provider!(
        "etag-bmc",
        :target,
        "redfish",
        %{
          "system_path" => @system_path,
          "expected_uuid" => @uuid,
          "ca_certificate" => File.read!("test/support/certs/kubernetes_fixture_ca.pem")
        },
        %{"username" => "tester", "password" => "secret"},
        actor: admin
      )

    checked =
      Skopos.TargetConnectionFixture.check_connection(provider, endpoint, admin)

    assert {:ok, _catalog} = checked

    method =
      Targets.create_access_method!(
        target.id,
        provider.id,
        "Redfish",
        "redfish",
        endpoint,
        provider.revision,
        100,
        ["observe.power", "request.redfish.observe", "request.redfish.effect"],
        actor: admin
      )
      |> then(&Targets.check_access_method!(&1.id, &1.revision, %{}, actor: admin))

    %{admin: admin, operator: operator, target: target, method: method, agent: agent}
  end

  test "Method pagination stays on origin and rejects cycles", context do
    {:ok, state} = redfish_state(context.method.endpoint)

    request = %Target.ObservationRequest{
      provider_revision: context.method.provider_revision,
      target_id: context.target.id,
      target_revision: context.target.revision,
      access_method_id: context.method.id,
      access_method_revision: context.method.revision,
      connection: %Target.Connection{endpoint: context.method.endpoint},
      capability: "request.redfish.observe",
      operation: "request.observe",
      authorization_digest: "fixture"
    }

    assert {:ok, observation} =
             Redfish.observe(
               state,
               %{request | parameters: %{"method" => "GET", "uri" => "/redfish/v1/Oem/Pages"}},
               %{}
             )

    assert length(observation.facts["response"]["Members"]) == 2

    for uri <- ["/redfish/v1/Oem/Loop", "/redfish/v1/Oem/Endless", "/redfish/v1/Oem/Cross"] do
      assert {:error, :failed, _} =
               Redfish.observe(
                 state,
                 %{request | parameters: %{"method" => "GET", "uri" => uri}},
                 %{}
               )
    end
  end
end
