defmodule Skopos.FileOperationTest do
  use Skopos.DataCase, async: false

  alias Skopos.{Accounts, Cases, Providers, Targets}
  alias Skopos.Providers.AI
  alias Skopos.Cases.Operation.Delivery
  alias Skopos.Cases.Proposal.ReviewDelivery

  defmodule Peer do
    import Plug.Conn
    def init(agent), do: agent

    def call(conn, agent) do
      case {conn.method, conn.request_path} do
        {"GET", "/api"} ->
          conn
          |> put_resp_content_type("application/json")
          |> send_resp(200, ~s({"versions":["v1"]}))

        {"GET", "/api/v1/namespaces/default/configmaps"} ->
          Agent.update(agent, &Map.update(&1, :watches, 1, fn count -> count + 1 end))

          conn
          |> put_resp_content_type("application/json")
          |> send_resp(
            200,
            ~s({"type":"ADDED","object":{"metadata":{"resourceVersion":"opaque-7"}}}\n) <>
              ~s({"type":"BOOKMARK","object":{"metadata":{"resourceVersion":"opaque-9"}}}\n)
          )

        {method, path}
        when method in ["PUT", "OPS!V2"] and path in ["/binary", "/api/service/binary"] ->
          {:ok, bytes, conn} = read_body(conn)
          Agent.update(agent, &Map.put(&1, :writes, [bytes | &1.writes]))

          case Agent.get(agent, &Map.get(&1, :after_write)) do
            :drop -> Process.exit(self(), :kill)
            callback when is_function(callback, 0) -> callback.()
            nil -> :ok
          end

          conn |> put_resp_content_type("application/octet-stream") |> send_resp(200, bytes)

        _ ->
          send_resp(conn, 200, "ready")
      end
    end
  end

  setup do
    admin =
      Accounts.bootstrap!(
        "file-case-admin@example.invalid",
        "test-only-password",
        "test-only-password"
      )

    operator =
      Accounts.create_user!("file-case-operator@example.invalid", "test-only-password", :operator,
        actor: admin
      )

    agent = start_supervised!({Agent, fn -> %{writes: []} end})

    peer =
      start_supervised!(
        {Bandit,
         plug: {Peer, agent},
         scheme: :https,
         port: 0,
         certfile: Path.expand("test/support/certs/kubernetes_fixture.pem"),
         keyfile: Path.expand("test/support/certs/kubernetes_fixture_key.pem"),
         startup_log: false}
      )

    {:ok, {_address, port}} = ThousandIsland.listener_info(peer)

    provider =
      Providers.create_provider!(
        "Case file HTTP",
        :target,
        "http-api",
        %{"ca_certificate" => File.read!("test/support/certs/kubernetes_fixture_ca.pem")},
        %{},
        actor: admin
      )
      |> then(&Providers.enable_provider!(&1, &1.revision, actor: admin))

    target =
      Targets.create_target!("file-device", "network_device", "custom-network-device", %{}, nil,
        actor: admin
      )

    method =
      Targets.create_access_method!(
        target.id,
        provider.id,
        "Case file HTTP",
        "http",
        "https://127.0.0.1:#{port}",
        provider.revision,
        100,
        ["request.http.observe", "request.http.effect"],
        actor: admin
      )
      |> then(&Targets.check_access_method!(&1.id, &1.revision, %{}, actor: admin))

    ai =
      Providers.create_provider!(
        "Case file AI fixture",
        :ai,
        "fixture-ai",
        %{"model" => "file-review-fixture"},
        %{"api_key" => "test-only"},
        actor: admin
      )
      |> then(&Providers.check_provider!(&1.id, &1.revision, %{}, actor: admin))
      |> then(&Providers.enable_provider!(&1, &1.revision, actor: admin))

    assignments = Skopos.TestAIUsage.configure!(ai.id, :all, 10, admin)
    current = Cases.current_authority_setting!(actor: admin)

    Cases.configure_authority_setting!(
      current.setting_revision,
      :auto,
      current.signal_automation_enabled,
      current.max_elapsed_seconds,
      current.max_resolver_turns,
      current.max_target_requests,
      current.max_effects,
      current.max_related_targets,
      current.max_ai_usage_units,
      current.max_no_progress_turns,
      "Case file review test",
      actor: admin
    )

    %{
      admin: admin,
      operator: operator,
      provider: provider,
      target: target,
      method: method,
      ai: ai,
      assignments: assignments,
      agent: agent,
      endpoint: "https://127.0.0.1:#{port}"
    }
  end

  test "Case observations retain bounded native watch cursor and file without replay", context do
    certificate = File.read!("test/support/certs/kubernetes_fixture_ca.pem") |> Base.encode64()

    kubeconfig = """
    apiVersion: v1
    kind: Config
    clusters:
      - name: target
        cluster:
          server: #{context.endpoint}
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
          namespace: default
    current-context: target
    """

    provider =
      Providers.create_provider!(
        "Case watch",
        :target,
        "kubernetes-api",
        %{"namespace" => "default", "request_timeout_ms" => 1_000},
        %{"kubeconfig" => kubeconfig},
        actor: context.admin
      )
      |> then(&Providers.enable_provider!(&1, &1.revision, actor: context.admin))

    target =
      Targets.create_target!("watch-cluster", "cluster", "kubernetes", %{}, nil,
        actor: context.admin
      )

    method =
      Targets.create_access_method!(
        target.id,
        provider.id,
        "Watch API",
        "api",
        context.endpoint,
        provider.revision,
        100,
        ["request.kubernetes.observe"],
        actor: context.admin
      )
      |> then(&Targets.check_access_method!(&1.id, &1.revision, %{}, actor: context.admin))

    context = %{context | provider: provider, target: target, method: method}

    parameters = %{
      "method" => "GET",
      "path" => "/api/v1/namespaces/default/configmaps",
      "query" => %{"watch" => "true", "resourceVersion" => "opaque-4"},
      "capture" => %{"duration_ms" => 500, "max_bytes" => 4_096, "max_events" => 1},
      "response_file" => %{"name" => "case-watch.jsonl", "media_type" => "application/json"}
    }

    proposal =
      proposal!(context, parameters,
        kind: "observation",
        capability: "request.kubernetes.observe",
        operation: "request.observe"
      )

    operation = Cases.accept_operation!(proposal.id, authorize?: false)
    assert operation.parameters == parameters
    assert :ok = Delivery.run(operation.id)
    stored = Cases.get_operation!(operation.id, actor: context.operator)
    assert stored.status == :applied
    facts = stored.result_details["facts"]
    assert facts["completion_reason"] == "event_limit"

    assert facts["watch"] == %{
             "event_count" => 1,
             "resource_version" => "opaque-7",
             "partial_event" => false,
             "resume_strategy" => "cursor",
             "error" => nil
           }

    file = facts["file"]

    assert Targets.read_bound_artifact_chunk!(file, 0, actor: context.operator) ==
             ~s({"type":"ADDED","object":{"metadata":{"resourceVersion":"opaque-7"}}}\n)

    evidence =
      Cases.list_evidence!(actor: context.admin)
      |> Enum.find(&(&1.source == "operation" and &1.source_ref == operation.id))

    assert evidence.content["parameters"] == parameters
    assert evidence.content["facts"] == facts
    assert :ok = Delivery.run(operation.id)
    assert Agent.get(context.agent, & &1.watches) == 1
  end

  test "Reviewer approved SFTP upload uses the exact file and never replays a completed operation",
       context do
    {context, directory} = sftp_context(context)
    file = stage_file(context)

    parameters = %{
      "path" => "/case-upload.bin",
      "body_file" => "payload",
      "files" => %{"payload" => file}
    }

    proposal =
      proposal!(context, parameters,
        capability: "request.ssh.effect",
        operation: "sftp.write_file",
        verification_operation: "sftp.read_file",
        verification_parameters: %{
          "path" => "/case-upload.bin",
          "response_file" => %{"name" => "verify.bin", "media_type" => "application/octet-stream"}
        },
        verification_expected: Map.take(file, ~w(sha256 size_bytes))
      )

    assert proposal.status == :reviewing
    refute File.exists?(Path.join(directory, "case-upload.bin"))
    approve!(proposal)
    operation = Cases.accept_operation!(proposal.id, authorize?: false)
    assert :ok = Delivery.run(operation.id)
    stored = Cases.get_operation!(operation.id, actor: context.operator)
    assert stored.status == :applied
    assert stored.parameters == parameters
    assert stored.result_details["bytes_written"] == 5
    assert File.read!(Path.join(directory, "case-upload.bin")) == <<255, 0, 1, 2, 255>>

    evidence =
      Cases.list_evidence!(actor: context.admin)
      |> Enum.find(&(&1.source == "operation" and &1.source_ref == operation.id))

    assert evidence.content["parameters"] == parameters
    File.write!(Path.join(directory, "case-upload.bin"), "later independent change")
    assert :ok = Delivery.run(operation.id)
    assert File.read!(Path.join(directory, "case-upload.bin")) == "later independent change"
  end

  test "Reviewer approved SFTP metadata retains fresh evidence without declaring recovery",
       context do
    {context, directory} = sftp_context(context)
    directory_parameters = %{"path" => "/case-directory"}

    mkdir =
      proposal!(context, directory_parameters,
        capability: "request.ssh.effect",
        operation: "sftp.make_dir",
        verification_operation: "sftp.read_file_info",
        verification_parameters: directory_parameters,
        verification_expected: %{}
      )

    assert mkdir.status == :reviewing
    refute File.dir?(Path.join(directory, "case-directory"))
    approve!(mkdir)
    directory_operation = Cases.accept_operation!(mkdir.id, authorize?: false)
    assert :ok = Delivery.run(directory_operation.id)

    assert Cases.get_operation!(directory_operation.id, actor: context.operator).status ==
             :applied

    verification = Cases.accept_verification!(directory_operation.id, authorize?: false)
    assert :ok = Skopos.Cases.VerificationAttempt.Delivery.run(verification.id)

    observed =
      Cases.get_verification_attempt!(verification.id, actor: context.operator)

    assert observed.status == :unknown
    assert observed.facts["attributes"]["type"] == "directory"
  end

  test "Reviewer approved RESTCONF file capture preserves uncertainty without replay", context do
    provider =
      Providers.create_provider!(
        "Case RESTCONF",
        :target,
        "restconf",
        %{
          "api_root" => "/api/service",
          "ca_certificate" => File.read!("test/support/certs/kubernetes_fixture_ca.pem")
        },
        %{"username" => "fixture", "password" => "test-only"},
        actor: context.admin
      )
      |> then(&Providers.enable_provider!(&1, &1.revision, actor: context.admin))

    method =
      Targets.create_access_method!(
        context.target.id,
        provider.id,
        "Case RESTCONF",
        "restconf",
        context.endpoint,
        provider.revision,
        100,
        ["request.restconf.observe", "request.restconf.effect"],
        actor: context.admin
      )
      |> then(&Targets.check_access_method!(&1.id, &1.revision, %{}, actor: context.admin))

    context = %{context | provider: provider, method: method}
    reference = stage_file(context)

    parameters = %{
      "method" => "OPS!V2",
      "path" => "/binary",
      "body_file" => "payload",
      "files" => %{"payload" => reference},
      "content_type" => "application/octet-stream",
      "capture" => %{"duration_ms" => 500, "max_bytes" => 3},
      "response_file" => %{
        "name" => "restconf-sample.bin",
        "media_type" => "application/octet-stream"
      }
    }

    proposal = proposal!(context, parameters, capability: "request.restconf.effect")
    assert proposal.status == :reviewing
    approve!(proposal)
    operation = Cases.accept_operation!(proposal.id, authorize?: false)
    assert :ok = Delivery.run(operation.id)
    stored = Cases.get_operation!(operation.id, actor: context.operator)
    assert stored.status == :unknown
    assert stored.parameters == parameters
    assert stored.result_details["completion_reason"] == "byte_limit"

    assert Targets.read_bound_artifact_chunk!(stored.result_details["file"], 0,
             actor: context.operator
           ) == <<255, 0, 1>>

    evidence =
      Cases.list_evidence!(actor: context.admin)
      |> Enum.find(&(&1.source == "operation" and &1.source_ref == operation.id))

    assert evidence.content["parameters"] == parameters
    assert evidence.content["details"] == stored.result_details
    assert :ok = Delivery.run(operation.id)
    assert Agent.get(context.agent, & &1.writes) == [<<255, 0, 1, 2, 255>>]
  end

  test "Reviewer approval binds native HTTP verb and file identity through Case execution",
       context do
    file =
      Targets.begin_artifact!(
        context.target.id,
        "payload.bin",
        "application/octet-stream",
        5,
        "b55f1659c0645fd1cee6dfa8b3af06795e9da7e48cb65c2b999f896c9f539dbd",
        "case-input",
        actor: context.operator
      )

    Targets.append_artifact_chunk!(file.id, 0, <<255, 0, 1, 2, 255>>, actor: context.operator)
    Targets.complete_artifact!(file.id, actor: context.operator)
    reference = Targets.artifact_reference!(file.id, context.target.id, actor: context.operator)

    parameters = %{
      "method" => "OPS!V2",
      "path" => "/binary",
      "body_file" => "payload",
      "files" => %{"payload" => reference},
      "response_file" => %{"name" => "result.bin", "media_type" => "application/octet-stream"}
    }

    proposal = proposal!(context, parameters)
    assert proposal.parameters == parameters
    assert proposal.status == :reviewing
    assert Cases.list_approvals!(actor: context.admin) == []
    assert Agent.get(context.agent, & &1.writes) == []

    invocation = %{
      test_pid: self(),
      respond: fn request ->
        assert request.proposal.parameters == parameters
        assert request.proposal.parameters["files"]["payload"] == reference
        assert request.session_id != request.resolver_session_id

        {:ok,
         %AI.ReviewDecision{
           purpose_assessment: :remediation,
           verdict: :approved,
           reason: "Approve this exact immutable payload",
           usage: %AI.Usage{input_tokens: 3, output_tokens: 2}
         }}
      end
    }

    assert :ok = ReviewDelivery.run(proposal.id, ai_invocation: invocation)
    assert_receive {:review, _state, _request}
    [approval] = Cases.list_approvals!(actor: context.admin)
    assert approval.source == :reviewer
    assert approval.proposal_digest == proposal.proposal_digest
    operation = Cases.accept_operation!(proposal.id, authorize?: false)
    assert operation.parameters == parameters
    assert :ok = Delivery.run(operation.id)
    stored = Cases.get_operation!(operation.id, authorize?: false)
    assert stored.status == :applied
    assert stored.parameters == parameters
    reply = stored.result_details["file"]
    assert reply["target_id"] == context.target.id
    assert reply["sha256"] == reference["sha256"]

    assert Targets.read_bound_artifact_chunk!(reply, 0, actor: context.operator) ==
             <<255, 0, 1, 2, 255>>

    evidence =
      Cases.list_evidence!(actor: context.admin)
      |> Enum.find(&(&1.source == "operation" and &1.source_ref == operation.id))

    assert evidence.content["parameters"]["files"]["payload"] == reference
    assert evidence.content["details"]["file"] == reply
    assert :ok = Delivery.run(operation.id)
    assert Agent.get(context.agent, & &1.writes) == [<<255, 0, 1, 2, 255>>]
  end

  test "Reviewer approved capture limits remain bound to the Case result without replay",
       context do
    reference = stage_file(context)

    parameters =
      file_parameters(reference)
      |> Map.put("capture", %{"duration_ms" => 500, "max_bytes" => 3})

    proposal = proposal!(context, parameters)
    approve!(proposal)
    operation = Cases.accept_operation!(proposal.id, authorize?: false)
    assert operation.parameters == parameters
    assert :ok = Delivery.run(operation.id)
    stored = Cases.get_operation!(operation.id, actor: context.operator)
    assert stored.status == :unknown
    assert stored.parameters == parameters
    assert stored.result_details["completion_reason"] == "byte_limit"
    reply = stored.result_details["file"]
    assert Targets.read_bound_artifact_chunk!(reply, 0, actor: context.operator) == <<255, 0, 1>>

    assert Targets.get_artifact!(reply["id"], actor: context.operator).completion_reason ==
             :byte_limit

    evidence =
      Cases.list_evidence!(actor: context.admin)
      |> Enum.find(&(&1.source == "operation" and &1.source_ref == operation.id))

    assert evidence.content["parameters"]["capture"] == parameters["capture"]
    assert evidence.content["details"]["completion_reason"] == "byte_limit"
    assert :ok = Delivery.run(operation.id)
    assert Agent.get(context.agent, & &1.writes) == [<<255, 0, 1, 2, 255>>]
  end

  test "a revoked approved file is rejected before Case dispatch", context do
    reference = stage_file(context)
    proposal = proposal!(context, file_parameters(reference))
    approve!(proposal)
    operation = Cases.accept_operation!(proposal.id, authorize?: false)
    Targets.revoke_artifact!(reference["id"], actor: context.operator)
    assert :ok = Delivery.run(operation.id)
    stored = Cases.get_operation!(operation.id, authorize?: false)
    assert stored.status == :failed
    assert stored.outcome_category == "authorization_invalidated"
    assert stored.parameters["files"]["payload"] == reference
    incident = Cases.get_case!(proposal.case_id, authorize?: false)
    run = Cases.get_resolution_run!(proposal.resolution_run_id, authorize?: false)
    turns = Cases.list_turns!(actor: context.admin)
    assert :ok = Delivery.run(operation.id)

    assert Cases.get_case!(proposal.case_id, authorize?: false).pending_intent ==
             incident.pending_intent

    assert Cases.get_resolution_run!(proposal.resolution_run_id, authorize?: false).turn_count ==
             run.turn_count

    assert Cases.list_turns!(actor: context.admin) |> Enum.map(& &1.id) ==
             Enum.map(turns, & &1.id)

    assert Agent.get(context.agent, & &1.writes) == []
  end

  test "an outcome save failure preserves the received file without repeating the effect",
       context do
    reference = stage_file(context)

    parameters =
      file_parameters(reference)
      |> Map.put("capture", %{"duration_ms" => 500, "max_bytes" => 3})

    proposal = proposal!(context, parameters)
    approve!(proposal)
    operation = Cases.accept_operation!(proposal.id, authorize?: false)

    # Fail only the outcome publication after the real HTTP peer has replied.
    Skopos.Repo.query!("""
    CREATE FUNCTION pg_temp.reject_file_operation_outcome() RETURNS trigger LANGUAGE plpgsql AS $$
    BEGIN
      IF NEW.status = 'unknown' THEN
        RAISE EXCEPTION 'test outcome publication unavailable';
      END IF;
      RETURN NEW;
    END;
    $$;
    """)

    Skopos.Repo.query!("""
    CREATE TRIGGER reject_file_operation_outcome BEFORE UPDATE ON operations
    FOR EACH ROW EXECUTE FUNCTION pg_temp.reject_file_operation_outcome()
    """)

    assert {:error, _} = Delivery.run(operation.id)
    assert Agent.get(context.agent, & &1.writes) == [<<255, 0, 1, 2, 255>>]
    assert Cases.get_operation!(operation.id, authorize?: false).status == :dispatching

    page = Targets.page_artifacts!(context.target.id, actor: context.operator)
    received = Enum.find(page.results, &(&1.name == "case-result.bin"))
    assert received.status == :ready
    assert received.completion_reason == :byte_limit
    assert Map.get(received, :request_id) == operation.id
    reply = Targets.artifact_reference!(received.id, context.target.id, actor: context.operator)

    assert Targets.read_bound_artifact_chunk!(reply, 0, actor: context.operator) ==
             <<255, 0, 1>>

    Skopos.Repo.query!("DROP TRIGGER reject_file_operation_outcome ON operations")
    assert :ok = Delivery.run(operation.id)
    recovered = Cases.get_operation!(operation.id, authorize?: false)
    assert recovered.status == :unknown
    assert recovered.outcome_category == "dispatch_interrupted"
    assert recovered.parameters["files"]["payload"] == reference
    assert recovered.parameters["capture"] == parameters["capture"]
    assert Targets.get_artifact!(received.id, actor: context.operator).request_id == operation.id
    assert :ok = Delivery.run(operation.id)
    assert Agent.get(context.agent, & &1.writes) == [<<255, 0, 1, 2, 255>>]

    evidence =
      Cases.list_evidence!(actor: context.admin)
      |> Enum.filter(&(&1.source == "operation" and &1.source_ref == operation.id))

    assert [%{content: %{"status" => "unknown"}}] = evidence

    assert Targets.artifact_reference!(received.id, context.target.id, actor: context.operator) ==
             reply
  end

  test "a lost file reply remains unknown with a visible receipt and no duplicate send",
       context do
    reference = stage_file(context)
    proposal = proposal!(context, file_parameters(reference))
    approve!(proposal)
    operation = Cases.accept_operation!(proposal.id, authorize?: false)
    Agent.update(context.agent, &Map.put(&1, :after_write, :drop))

    assert :ok = Delivery.run(operation.id)
    stored = Cases.get_operation!(operation.id, authorize?: false)
    assert stored.status == :unknown
    refute Map.has_key?(stored.result_details, "file")
    page = Targets.page_artifacts!(context.target.id, actor: context.operator)
    receipt = Enum.find(page.results, &(&1.name == "case-result.bin"))
    assert receipt.status == :receiving
    assert receipt.request_id == operation.id
    assert stored.result_details["reason"] =~ receipt.id

    assert {:error, _} =
             Targets.artifact_reference(receipt.id, context.target.id, actor: context.operator)

    assert :ok = Delivery.run(operation.id)
    assert Agent.get(context.agent, & &1.writes) == [<<255, 0, 1, 2, 255>>]
  end

  test "Case cancellation before dispatch does not send or open a response file", context do
    reference = stage_file(context)
    proposal = proposal!(context, file_parameters(reference))
    approve!(proposal)
    operation = Cases.accept_operation!(proposal.id, authorize?: false)
    incident = Cases.get_case!(proposal.case_id, actor: context.operator)
    Cases.request_case_cancellation!(incident.id, incident.revision, actor: context.operator)

    assert :ok = Delivery.run(operation.id)
    stored = Cases.get_operation!(operation.id, actor: context.operator)
    assert stored.status == :failed
    assert stored.outcome_category == "cancelled_before_dispatch"
    assert Agent.get(context.agent, & &1.writes) == []
    [input] = Targets.page_artifacts!(context.target.id, actor: context.operator).results
    assert input.id == reference["id"]
  end

  test "Case cancellation after the send leaves an unknown effect and unusable response file",
       context do
    reference = stage_file(context)

    proposal =
      proposal!(
        context,
        Map.put(file_parameters(reference), "capture", %{"duration_ms" => 500, "max_bytes" => 3})
      )

    approve!(proposal)
    operation = Cases.accept_operation!(proposal.id, authorize?: false)

    requester = self()

    Agent.update(context.agent, fn state ->
      Map.put(state, :after_write, fn ->
        incident = Cases.get_case!(proposal.case_id, actor: context.operator)
        Cases.request_case_cancellation!(incident.id, incident.revision, actor: context.operator)

        # Keep the response outstanding while the bounded context poll sees cancellation.
        send(requester, {:effect_sent, self()})

        receive do
          :release_response -> :ok
        after
          5_000 -> raise "test peer response was not released"
        end
      end)
    end)

    assert :ok = Delivery.run(operation.id)
    assert_received {:effect_sent, peer}
    send(peer, :release_response)
    stored = Cases.get_operation!(operation.id, actor: context.operator)
    assert stored.status == :unknown
    assert stored.result_details["reason"] =~ "cancellation"
    refute Map.has_key?(stored.result_details, "file")
    page = Targets.page_artifacts!(context.target.id, actor: context.operator)
    receipt = Enum.find(page.results, &(&1.name == "case-result.bin"))
    assert receipt.status == :receiving
    assert receipt.request_id == operation.id

    assert {:error, _} =
             Targets.artifact_reference(receipt.id, context.target.id, actor: context.operator)

    assert :ok = Delivery.run(operation.id)
    assert Agent.get(context.agent, & &1.writes) == [<<255, 0, 1, 2, 255>>]
  end

  test "an approved input that expires before dispatch cannot be sent", context do
    previous = Application.get_env(:skopos, :artifact_limits)
    Application.put_env(:skopos, :artifact_limits, %{lifetime_seconds: 3})

    on_exit(fn ->
      if previous,
        do: Application.put_env(:skopos, :artifact_limits, previous),
        else: Application.delete_env(:skopos, :artifact_limits)
    end)

    reference = stage_file(context)
    proposal = proposal!(context, file_parameters(reference))
    approve!(proposal)
    operation = Cases.accept_operation!(proposal.id, authorize?: false)
    input = Targets.get_artifact!(reference["id"], actor: context.operator)
    Process.sleep(max(DateTime.diff(input.expires_at, DateTime.utc_now(), :millisecond), 0) + 20)

    assert :ok = Delivery.run(operation.id)
    stored = Cases.get_operation!(operation.id, actor: context.operator)
    assert stored.status == :failed
    assert stored.outcome_category == "authorization_invalidated"
    assert Agent.get(context.agent, & &1.writes) == []

    assert {:error, _} =
             Targets.artifact_reference(input.id, context.target.id, actor: context.operator)

    assert [only] = Targets.page_artifacts!(context.target.id, actor: context.operator).results
    assert only.id == input.id
  end

  test "changed or cross-Target file references cannot produce a cleared Case proposal",
       context do
    reference = stage_file(context)

    foreign =
      Targets.create_target!(
        "other-file-device",
        "network_device",
        "custom-network-device",
        %{},
        nil,
        actor: context.admin
      )

    for invalid <- [
          Map.put(reference, "sha256", String.duplicate("0", 64)),
          Map.put(reference, "target_id", foreign.id)
        ] do
      proposal = proposal!(context, file_parameters(invalid), route?: false)
      assert proposal.status == :blocked
      assert proposal.preflight_status != :cleared
    end

    assert Cases.list_approvals!(actor: context.admin) == []
    assert Agent.get(context.agent, & &1.writes) == []
  end

  defp stage_file(context) do
    file =
      Targets.begin_artifact!(
        context.target.id,
        "case-input.bin",
        "application/octet-stream",
        5,
        "b55f1659c0645fd1cee6dfa8b3af06795e9da7e48cb65c2b999f896c9f539dbd",
        Ecto.UUID.generate(),
        actor: context.operator
      )

    Targets.append_artifact_chunk!(file.id, 0, <<255, 0, 1, 2, 255>>, actor: context.operator)
    Targets.complete_artifact!(file.id, actor: context.operator)
    Targets.artifact_reference!(file.id, context.target.id, actor: context.operator)
  end

  defp file_parameters(reference) do
    %{
      "method" => "PUT",
      "path" => "/binary",
      "body_file" => "payload",
      "files" => %{"payload" => reference},
      "response_file" => %{
        "name" => "case-result.bin",
        "media_type" => "application/octet-stream"
      }
    }
  end

  defp sftp_context(context) do
    directory = Path.join(System.tmp_dir!(), "skopos-case-sftp-#{Ecto.UUID.generate()}")
    File.mkdir_p!(directory)
    key = :public_key.generate_key({:rsa, 2048, 65537})
    private = :public_key.pem_entry_encode(:RSAPrivateKey, key)
    File.write!(Path.join(directory, "ssh_host_rsa_key"), :public_key.pem_encode([private]))
    File.chmod!(Path.join(directory, "ssh_host_rsa_key"), 0o600)

    {:ok, daemon} =
      :ssh.daemon(0,
        system_dir: String.to_charlist(directory),
        user_passwords: [{~c"tester", ~c"secret"}],
        auth_methods: ~c"password",
        subsystems: [:ssh_sftpd.subsystem_spec(root: String.to_charlist(directory))]
      )

    on_exit(fn ->
      :ssh.stop_daemon(daemon)
      File.rm_rf!(directory)
    end)

    {:ok, info} = :ssh.daemon_info(daemon)
    endpoint = "ssh://127.0.0.1:#{Keyword.fetch!(info, :port)}"

    fingerprint =
      key
      |> :ssh_file.extract_public_key()
      |> then(&:ssh.hostkey_fingerprint(:sha256, &1))
      |> to_string()

    provider =
      Providers.create_provider!(
        "Case SFTP",
        :target,
        "ssh",
        %{"host_key_fingerprints" => %{endpoint => fingerprint}},
        %{"username" => "tester", "auth_method" => "password", "password" => "secret"},
        actor: context.admin
      )
      |> then(&Providers.enable_provider!(&1, &1.revision, actor: context.admin))

    method =
      Targets.create_access_method!(
        context.target.id,
        provider.id,
        "Case SFTP",
        "ssh",
        endpoint,
        provider.revision,
        100,
        ["request.ssh.observe", "request.ssh.effect"],
        actor: context.admin
      )
      |> then(&Targets.check_access_method!(&1.id, &1.revision, %{}, actor: context.admin))

    context = %{context | provider: provider, method: method}
    {context, directory}
  end

  defp approve!(proposal) do
    :ok =
      ReviewDelivery.run(proposal.id,
        ai_invocation: %{
          test_pid: self(),
          respond: fn request ->
            assert request.proposal.parameters == proposal.parameters

            {:ok,
             %AI.ReviewDecision{
               purpose_assessment: :remediation,
               verdict: :approved,
               reason: "Approve this exact immutable payload",
               usage: %AI.Usage{input_tokens: 3, output_tokens: 2}
             }}
          end
        }
      )
  end

  defp proposal!(context, parameters, opts \\ []) do
    kind = Keyword.get(opts, :kind, "effect")
    capability = Keyword.get(opts, :capability, "request.http.effect")
    operation = Keyword.get(opts, :operation, "request.execute")

    incident =
      Cases.open_case!(
        :manual,
        "test",
        Ecto.UUID.generate(),
        "Apply exact file payload",
        :warning,
        %{"desired_outcome" => "The device accepts the exact payload"},
        context.target.id,
        :en,
        actor: context.operator
      )

    run = Cases.active_resolution_run!(incident.id, authorize?: false)

    evidence =
      Cases.append_evidence!(
        incident.id,
        run.id,
        nil,
        Ecto.UUID.generate(),
        "observation",
        "wire-fixture",
        "device-status",
        %{"target_id" => context.target.id, "status" => "ready"},
        DateTime.utc_now(),
        authorize?: false
      )

    tool = %{
      "id" => "file-effect",
      "request_kind" => kind,
      "target_id" => context.target.id,
      "target_revision" => context.target.revision,
      "access_method_id" => context.method.id,
      "access_method_revision" => context.method.revision,
      "provider_id" => context.provider.id,
      "provider_revision" => context.provider.revision,
      "capability" => capability,
      "operation" => operation
    }

    intent = %{
      "type" => "proposal",
      "delay_seconds" => 0,
      "purpose" => if(kind == "observation", do: "investigation", else: "remediation"),
      "request_kind" => kind,
      "tool_id" => tool["id"],
      "target_id" => context.target.id,
      "target_revision" => context.target.revision,
      "access_method_id" => context.method.id,
      "access_method_revision" => context.method.revision,
      "capability" => capability,
      "operation" => operation,
      "tool" => tool,
      "selectors" => %{},
      "parameters" => parameters,
      "reason" => "Send the exact reviewed file to the device",
      "evidence_ids" => [evidence.id],
      "affected_conditions" => [],
      "expected_result" => Keyword.get(opts, :verification_expected, %{"status" => 200}),
      "verification_intent" => %{
        "tool_id" => "file-verification",
        "selectors" => %{},
        "parameters" =>
          Keyword.get(opts, :verification_parameters, %{"method" => "GET", "path" => "/"}),
        "expected_result" => Keyword.get(opts, :verification_expected, %{"status" => 200})
      },
      "verification_tool" => %{
        tool
        | "id" => "file-verification",
          "request_kind" => "observation",
          "capability" => String.replace_suffix(capability, ".effect", ".observe"),
          "operation" => Keyword.get(opts, :verification_operation, "request.observe")
      }
    }

    intent =
      if kind == "observation",
        do:
          intent
          |> Map.put("expected_result", %{})
          |> Map.put("verification_intent", %{})
          |> Map.put("verification_tool", %{}),
        else: intent

    turn =
      Cases.start_turn!(
        incident.id,
        run.id,
        Ecto.UUID.generate(),
        %{"objective" => "Apply reviewed payload"},
        %{"action" => "continue"},
        "Review limits",
        authorize?: false
      ).value

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
        "Review decision",
        authorize?: false
      ).value

    proposal = Cases.materialize_proposal!(completed.id, authorize?: false)

    if Keyword.get(opts, :route?, true),
      do: Cases.route_proposal_authority!(proposal.id, authorize?: false),
      else: proposal
  end
end
