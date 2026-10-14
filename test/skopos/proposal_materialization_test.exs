defmodule Skopos.ProposalMaterializationTest do
  use Skopos.DataCase, async: false

  alias Skopos.{Accounts, Cases, Providers, Signals, Targets}
  alias Skopos.Providers.Signal

  @password "correct horse battery staple"

  setup do
    admin =
      Accounts.bootstrap!("proposal-admin@example.com", @password, @password, authorize?: true)

    operator =
      Accounts.create_user!("proposal-operator@example.com", @password, :operator, actor: admin)

    provider =
      Providers.create_provider!(
        "proposal-target-provider",
        :target,
        "fixture-target",
        %{"endpoint" => "reachable"},
        %{"token" => "proposal-target-secret"},
        actor: admin
      )
      |> then(&Providers.enable_provider!(&1, 1, actor: admin))

    target = Targets.create_target!("proposal-linux", "host", "linux", %{}, nil, actor: admin)

    method =
      Targets.create_access_method!(
        target.id,
        provider.id,
        "proposal-ssh",
        "ssh",
        "ssh://proposal-linux",
        provider.revision,
        10,
        ["effect.service", "observe.service", "effect.command"],
        actor: admin
      )
      |> then(&Targets.check_access_method!(&1.id, &1.revision, %{}, actor: admin))

    %{admin: admin, operator: operator, provider: provider, target: target, method: method}
  end

  test "exact accepted Proposal materializes once without dispatch", context do
    {incident, run, evidence, turn, intent} = proposal_turn!("exact", context)

    assert {:ok, proposal} = Cases.materialize_proposal(turn.id, authorize?: false)
    assert {:ok, duplicate} = Cases.materialize_proposal(turn.id, authorize?: false)

    assert duplicate.id == proposal.id
    assert duplicate.reserved_operation_id == proposal.reserved_operation_id
    assert duplicate.proposal_digest == proposal.proposal_digest
    assert proposal.status == :proposed
    assert proposal.preflight_status == :cleared
    assert proposal.case_id == incident.id
    assert proposal.resolution_run_id == run.id
    assert proposal.source_turn_id == turn.id
    assert proposal.target_id == context.target.id
    assert proposal.target_revision == context.target.revision
    assert proposal.access_method_id == context.method.id
    assert proposal.access_method_revision == context.method.revision
    assert proposal.provider_id == context.provider.id
    assert proposal.provider_revision == context.provider.revision
    assert proposal.tool_id == intent["tool_id"]
    assert proposal.evidence_ids == [evidence.id]
    assert proposal.selectors == intent["selectors"]
    assert proposal.parameters == intent["parameters"]
    assert proposal.verification_intent == intent["verification_intent"]
    assert proposal.verification_tool == intent["verification_tool"]
    assert proposal.expires_at == run.deadline_at
    assert byte_size(proposal.proposal_digest) == 64
    assert proposal.preflight_context["provider_id"] == context.provider.id
    assert is_binary(proposal.preflight_context["clearance_digest"])
    assert Cases.get_resolution_run!(run.id, authorize?: false).effect_count == 0
    refute_receive {:effect, _, _}
  end

  test "a first opaque investigation persists without inventing prior Evidence", context do
    {incident, run} = open_case!("first-investigation", context)

    intent =
      proposal_intent(nil, context)
      |> Map.merge(%{
        "purpose" => "investigation",
        "capability" => "effect.command",
        "operation" => "command.execute",
        "selectors" => %{},
        "parameters" => %{"command" => "service nginx status"},
        "reason" => "Collect the first service status evidence",
        "evidence_ids" => [],
        "expected_result" => %{},
        "verification_intent" => nil,
        "verification_tool" => %{}
      })
      |> put_in(["tool", "capability"], "effect.command")
      |> put_in(["tool", "operation"], "command.execute")

    turn = completed_turn!(incident, run, "first-investigation", intent)
    assert {:ok, proposal} = Cases.materialize_proposal(turn.id, authorize?: false)
    assert proposal.purpose == :investigation
    assert proposal.request_kind == :effect
    assert proposal.evidence_ids == []
    assert proposal.verification_intent == %{}
    assert proposal.preflight_status == :cleared
    assert Cases.operations_for_case!(incident.id, actor: context.operator) == []
  end

  test "every registered Method preserves an exact investigation through Resolver and Reviewer",
       context do
    configure_matrix_ai!(context)

    catalog = Skopos.Targets.TypeCatalog.snapshot()

    for descriptor <- catalog.methods do
      type = Enum.find(catalog.types, &(descriptor.adapter_type in &1.access_method_types))
      {provider, target, method} = checked_method_fixture!(descriptor, type, context.admin)
      local = %{context | provider: provider, target: target, method: method}
      {incident, _run, proposal} = reviewed_method_investigation!(descriptor, local)

      Targets.update_access_method!(method, method.revision, %{capabilities: []},
        actor: context.admin
      )

      assert {:error, _} = Cases.accept_operation(proposal.id, authorize?: false)
      assert Cases.operations_for_case!(incident.id, actor: context.operator) == []
    end
  end

  test "every registered Method returns actual connection failure to its Case without replay",
       context do
    configure_matrix_ai!(context)
    catalog = Skopos.Targets.TypeCatalog.snapshot()

    for descriptor <- catalog.methods do
      type = Enum.find(catalog.types, &(descriptor.adapter_type in &1.access_method_types))
      {provider, target, method} = checked_method_fixture!(descriptor, type, context.admin)
      local = %{context | provider: provider, target: target, method: method}
      {incident, run, proposal} = reviewed_method_investigation!(descriptor, local)
      operation = Cases.accept_operation!(proposal.id, authorize?: false)

      # The actual configured adapter/transport connects to the refused loopback
      # endpoint. This proves Case integration, not successful native wire I/O.
      assert :ok = Skopos.Cases.Operation.Delivery.run(operation.id)
      stored = Cases.get_operation!(operation.id, actor: context.operator)
      assert stored.status in [:failed, :unknown]
      refute stored.outcome_category == "authorization_invalidated"
      assert stored.parameters == proposal.parameters
      assert stored.purpose == :investigation

      current = Cases.get_case!(incident.id, actor: context.operator)
      assert current.status == :running
      assert current.pending_intent["action"] == "resolve_turn"

      evidence =
        Cases.get_evidence!(current.pending_intent["evidence_id"], actor: context.operator)

      assert evidence.source_ref == stored.id
      assert evidence.content["parameters"] == proposal.parameters
      assert evidence.content["purpose"] == "investigation"
      assert evidence.content["status"] == Atom.to_string(stored.status)
      assert Cases.verification_attempts_for_case!(incident.id, actor: context.operator) == []

      assert :ok = Skopos.Cases.Operation.Delivery.run(operation.id)
      assert Cases.get_operation!(operation.id, actor: context.operator) == stored

      assert Cases.get_case!(incident.id, actor: context.operator).pending_intent ==
               current.pending_intent

      assert Cases.get_resolution_run!(run.id, authorize?: false).effect_count == 1
      assert [only_operation] = Cases.operations_for_case!(incident.id, actor: context.operator)
      assert only_operation.id == stored.id
      assert only_operation.status == stored.status
      assert only_operation.parameters == proposal.parameters
    end
  end

  test "foreign Evidence and revoked owner authority fail without a Proposal", context do
    {incident, run} = open_case!("foreign-source", context)
    {other_case, other_run} = open_case!("foreign-evidence", context)
    foreign = evidence!(other_case, other_run, "foreign")
    turn = completed_turn!(incident, run, "foreign", proposal_intent(foreign.id, context))

    assert {:error, _error} = Cases.materialize_proposal(turn.id, authorize?: false)
    assert Cases.list_proposals!(actor: context.admin) == []

    own = evidence!(incident, run, "revoked")
    revoked_turn = completed_turn!(incident, run, "revoked", proposal_intent(own.id, context))
    Accounts.change_role!(context.operator, :viewer, actor: context.admin)

    assert {:error, _error} = Cases.materialize_proposal(revoked_turn.id, authorize?: false)
    assert Cases.list_proposals!(actor: context.admin) == []
  end

  test "the current Signal Evidence remains available after a Case resumes", context do
    {_incident, _prior_run, resumed_run, current, _stale, resumed_turn} =
      resumed_signal_case!("current-signal", context)

    completed =
      complete_turn!(resumed_turn, proposal_intent(current.id, context))

    assert {:ok, proposal} = Cases.materialize_proposal(completed.id, authorize?: false)
    assert proposal.resolution_run_id == resumed_run.id
    assert proposal.evidence_ids == [current.id]
  end

  test "a stale Signal Evidence cannot cross a resumed Case generation", context do
    {_incident, _prior_run, _resumed_run, _current, stale, resumed_turn} =
      resumed_signal_case!("stale-signal", context)

    completed =
      complete_turn!(resumed_turn, proposal_intent(stale.id, context))

    assert {:error, _error} = Cases.materialize_proposal(completed.id, authorize?: false)
    assert Cases.list_proposals!(actor: context.admin) == []
  end

  for {label, kind} <- [
        {"no", :none},
        {"stale", :stale},
        {"recovered", :recovered},
        {"fabricated", :fabricated}
      ] do
    test "a Signal effect with #{label} affected Condition cannot materialize", context do
      {incident, _prior_run, _resumed_run, current, _stale, turn} =
        resumed_signal_case!("invalid-affected-#{unquote(label)}", context)

      condition =
        incident.id
        |> Cases.active_conditions_for_case!(authorize?: false)
        |> Enum.map(&Signals.get_condition!(&1.condition_id, authorize?: false))
        |> Enum.find(&(&1.state == :firing))

      claims =
        case unquote(kind) do
          :none ->
            []

          :stale ->
            [%{"condition_id" => condition.id, "revision" => condition.revision + 1}]

          :recovered ->
            recovered =
              Signals.list_conditions!(actor: context.admin)
              |> Enum.find(&(&1.state == :recovered))

            [%{"condition_id" => recovered.id, "revision" => recovered.revision}]

          :fabricated ->
            [%{"condition_id" => Ash.UUID.generate(), "revision" => 1}]
        end

      completed = complete_turn!(turn, proposal_intent(current.id, context), claims: claims)
      assert {:error, _error} = Cases.materialize_proposal(completed.id, authorize?: false)
      assert Cases.list_proposals!(actor: context.admin) == []
    end
  end

  test "a changed Access Method records stale preflight and preserves the offered revisions",
       context do
    {_incident, run, _evidence, turn, _intent} = proposal_turn!("stale-method", context)

    Targets.update_access_method!(
      context.method,
      context.method.revision,
      %{priority: context.method.priority + 1},
      actor: context.admin
    )

    assert {:ok, proposal} = Cases.materialize_proposal(turn.id, authorize?: false)
    assert proposal.status == :blocked
    assert proposal.preflight_context["category"] == "stale_context"
    assert proposal.access_method_revision == context.method.revision
    assert proposal.provider_revision == context.provider.revision
    assert Cases.get_resolution_run!(run.id, authorize?: false).effect_count == 0
  end

  test "an elapsed ResolutionRun cannot materialize a stale Proposal", context do
    {_incident, run, _evidence, turn, _intent} = proposal_turn!("expired", context)
    past = DateTime.add(DateTime.utc_now(), -1, :second)

    Skopos.Repo.update_all(
      from(item in Skopos.Cases.ResolutionRun, where: item.id == ^run.id),
      set: [deadline_at: past]
    )

    assert {:error, _error} = Cases.materialize_proposal(turn.id, authorize?: false)
    assert Cases.list_proposals!(actor: context.admin) == []
    refute_receive {:effect, _, _}
  end

  defp proposal_turn!(suffix, context) do
    {incident, run} = open_case!(suffix, context)
    evidence = evidence!(incident, run, suffix)
    intent = proposal_intent(evidence.id, context)
    turn = completed_turn!(incident, run, suffix, intent)
    {incident, run, evidence, turn, intent}
  end

  defp open_case!(suffix, context) do
    incident =
      Cases.open_case!(
        :manual,
        "test",
        "proposal-#{suffix}",
        "Proposal #{suffix}",
        :warning,
        %{"desired_outcome" => "Target responds as expected"},
        context.target.id,
        :en,
        actor: context.operator
      )

    {incident, Cases.active_resolution_run!(incident.id, authorize?: false)}
  end

  defp configure_matrix_ai!(context) do
    ai =
      Providers.create_provider!(
        "matrix-ai",
        :ai,
        "fixture-ai",
        %{"model" => "matrix"},
        %{
          "api_key" => "matrix-secret"
        },
        actor: context.admin
      )
      |> then(&Providers.check_provider!(&1.id, &1.revision, %{}, actor: context.admin))
      |> then(&Providers.enable_provider!(&1, &1.revision, actor: context.admin))

    Skopos.TestAIUsage.configure!(ai.id, :all, 10, context.admin)
    current = Cases.current_authority_setting!(actor: context.admin)

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
      "Review exact Method investigations",
      actor: context.admin
    )
  end

  defp reviewed_method_investigation!(descriptor, context) do
    {incident, run} = open_case!(descriptor.adapter_type, context)

    begun =
      Cases.start_turn!(
        incident.id,
        run.id,
        "matrix-#{descriptor.adapter_type}",
        %{"objective" => "Collect current device evidence"},
        %{"action" => "continue"},
        "Review the Resolver decision",
        authorize?: false
      ).value

    selection = Providers.select_resolver_ai!(authorize?: false)

    assert {:ok, request, _context} =
             Skopos.Cases.Turn.ResolverProjection.build(begun.id, selection)

    {capability, operation, parameters} = exact_investigation(descriptor.protocol)

    tool =
      Enum.find(
        request.proposal_tools,
        &(&1.capability == capability and &1.operation == operation)
      )

    assert tool, "#{descriptor.adapter_type} did not offer its exact Method request"

    identity =
      Map.from_struct(tool)
      |> Map.take([
        :id,
        :target_id,
        :target_revision,
        :access_method_id,
        :access_method_revision,
        :provider_id,
        :provider_revision,
        :capability,
        :operation,
        :request_kind
      ])
      |> Map.new(fn {key, value} ->
        {Atom.to_string(key), if(is_atom(value), do: Atom.to_string(value), else: value)}
      end)

    intent =
      Map.drop(identity, ["id", "provider_id", "provider_revision"])
      |> Map.merge(%{
        "type" => "proposal",
        "delay_seconds" => 0,
        "purpose" => "investigation",
        "request_kind" => "effect",
        "tool_id" => tool.id,
        "tool" => identity,
        "selectors" => %{},
        "parameters" => parameters,
        "reason" => "Collect current evidence through the selected Method",
        "evidence_ids" => [],
        "affected_conditions" => [],
        "expected_result" => %{},
        "verification_intent" => nil,
        "verification_tool" => %{}
      })

    completed = complete_turn!(begun, intent)
    proposal = Cases.materialize_proposal!(completed.id, authorize?: false)

    assert proposal.preflight_status == :cleared,
           "#{descriptor.adapter_type}: #{inspect(proposal.preflight_context)} #{proposal.preflight_reason}"

    assert proposal.purpose == :investigation
    assert proposal.request_kind == :effect
    assert proposal.parameters == parameters
    assert proposal.provider_id == context.provider.id
    assert proposal.access_method_revision == context.method.revision

    reviewing = Cases.route_proposal_authority!(proposal.id, authorize?: false)
    assert reviewing.status == :reviewing
    reviewer = Providers.select_reviewer_ai!([], authorize?: false)

    assert {:ok, review, _context} =
             Skopos.Cases.Proposal.ReviewProjection.build(proposal.id, reviewer)

    assert review.proposal.purpose == :investigation
    assert review.proposal.parameters == parameters
    assert review.proposal.verification_intent == nil

    assert :ok =
             Skopos.Cases.Proposal.ReviewDelivery.run(proposal.id,
               ai_invocation: %{
                 test_pid: self(),
                 respond: fn delivered ->
                   assert delivered.proposal.parameters == parameters
                   assert delivered.proposal.purpose == :investigation

                   {:ok,
                    %Skopos.Providers.AI.ReviewDecision{
                      verdict: :approved,
                      purpose_assessment: :investigation,
                      reason: "Fixture approves the exact investigation",
                      usage: %Skopos.Providers.AI.Usage{input_tokens: 3, output_tokens: 2}
                    }}
                 end
               }
             )

    assert_receive {:review, %{model: "matrix"}, _}
    authorized = Cases.get_proposal!(proposal.id, actor: context.operator)
    assert authorized.status == :authorized

    approval =
      Cases.list_approvals!(actor: context.operator)
      |> Enum.find(&(&1.proposal_id == proposal.id))

    assert approval.proposal_digest == proposal.proposal_digest

    {incident, run, authorized}
  end

  # A remote check snapshot is substituted at its action lifecycle here. Actual
  # registration, catalogs, binding, classification and Case consumers run normally;
  # native connection/check/dispatch behavior belongs to the protocol peer tests.
  defp checked_method_fixture!(descriptor, type, admin) do
    endpoint =
      case descriptor.protocol do
        protocol when protocol in ["ssh", "netconf"] -> "ssh://127.0.0.1:9"
        "ipmi" -> "ipmi://127.0.0.1:9"
        _ -> "https://127.0.0.1:9"
      end

    {configuration, credentials} =
      Skopos.TargetConnectionFixture.input(descriptor.adapter_type, endpoint)

    configuration =
      if descriptor.protocol in ["ipmi", "redfish"],
        do: Map.put(configuration, "timeout_ms", 100),
        else: configuration

    provider =
      Providers.create_provider!(
        descriptor.adapter_type,
        :target,
        descriptor.adapter_type,
        configuration,
        credentials,
        actor: admin
      )
      |> then(&Providers.enable_provider!(&1, &1.revision, actor: admin))

    target =
      Targets.create_target!(descriptor.adapter_type, type.kind, type.id, %{}, nil, actor: admin)

    {:ok, adapter} = Providers.Registry.fetch(descriptor.adapter_type, Skopos.Providers.Target)
    profile = adapter.access_method_profile()
    {:ok, state} = adapter.build(configuration, credentials)

    {:ok, state} =
      adapter.bind_connection(state, %Skopos.Providers.Target.Connection{endpoint: endpoint})

    {:ok, capabilities} = adapter.capabilities(state, %{})

    method =
      Targets.create_access_method!(
        target.id,
        provider.id,
        descriptor.adapter_type,
        profile.method,
        endpoint,
        provider.revision,
        100,
        profile.capabilities,
        actor: admin
      )

    checking =
      Targets.begin_access_method_check!(method, method.revision, Ecto.UUID.generate(),
        authorize?: false
      )

    checked =
      Targets.record_access_method_check!(
        checking,
        checking.revision,
        checking.check_attempt_id,
        checking.connection_revision,
        target.revision,
        :passed,
        "Fixture remote check result",
        capabilities,
        authorize?: false
      )

    {provider, target, Targets.get_access_method!(checked.id, actor: admin)}
  end

  defp exact_investigation("ssh"),
    do: {"request.ssh.effect", "command.execute", %{"command" => "printf '%s' 'device-evidence'"}}

  defp exact_investigation("ipmi"),
    do:
      {"request.ipmi.effect", "command.execute",
       %{"netfn" => 6, "command" => 1, "include_response" => true}}

  defp exact_investigation("netconf"),
    do:
      {"request.netconf.effect", "rpc.execute",
       %{"body" => "<custom-action xmlns=\"urn:example:device\"/>"}}

  defp exact_investigation("restconf"),
    do:
      {"request.restconf.effect", "request.execute",
       %{"method" => "POST", "path" => "/operations/example:inspect", "body" => "{}"}}

  defp exact_investigation("redfish"),
    do:
      {"request.redfish.effect", "request.execute",
       %{"method" => "POST", "uri" => "/redfish/v1/Oem/Inspect", "body" => %{}}}

  defp exact_investigation("http"),
    do:
      {"request.http.effect", "request.execute",
       %{"method" => "POST", "path" => "/api/inspect", "body" => "{}"}}

  defp exact_investigation("kubernetes"),
    do:
      {"request.kubernetes.effect", "request.execute",
       %{"method" => "POST", "path" => "/apis/example.test/v1/widgets", "body" => "{}"}}

  defp evidence!(incident, run, suffix) do
    Cases.append_evidence!(
      incident.id,
      run.id,
      nil,
      "proposal-evidence-#{suffix}",
      "observation",
      "fixture",
      "observation-#{suffix}",
      %{"service" => "unhealthy"},
      DateTime.utc_now(),
      authorize?: false
    )
  end

  defp completed_turn!(incident, run, suffix, intent) do
    started =
      Cases.start_turn!(
        incident.id,
        run.id,
        "proposal-turn-#{suffix}",
        %{"objective" => "Restore the service"},
        %{"action" => "continue"},
        "Review Resolver limits",
        authorize?: false
      )

    complete_turn!(started.value, intent)
  end

  defp complete_turn!(turn, intent, opts \\ []) do
    incident = Cases.get_case!(turn.case_id, authorize?: false)

    result = %{
      "outcome" => "decision",
      "intent" => intent,
      "resolver" => resolver_identity(),
      "usage" => %{"input_tokens" => 1, "output_tokens" => 1}
    }

    result =
      if incident.trigger_kind == :signal do
        {:ok, revisions} =
          Skopos.Cases.Case.ConditionContext.current_condition_revisions(incident)

        {:ok, conditions} = Skopos.Cases.Case.ConditionContext.current_conditions(incident)

        claims =
          Keyword.get_lazy(opts, :claims, fn ->
            conditions
            |> Enum.filter(&(&1.state == :firing))
            |> Enum.map(&%{"condition_id" => &1.id, "revision" => &1.revision})
          end)

        result
        |> Map.put("condition_revisions", revisions)
        |> put_in(["intent", "affected_conditions"], claims)
      else
        result
      end

    Cases.complete_turn!(
      turn.id,
      turn.revision,
      result,
      :proposal,
      %{"action" => "route_resolver_decision", "turn_id" => turn.id},
      "Review the Resolver decision",
      authorize?: false
    ).value
  end

  defp resumed_signal_case!(suffix, context) do
    enable_signal_automation!(context.admin)
    source = "proposal-monitor-#{suffix}"
    event_key = "proposal-signal-#{suffix}"

    provider =
      Providers.create_provider!(
        source,
        :signal,
        "fixture-signal",
        %{"source" => source},
        %{"secret" => "proposal-monitor-secret"},
        actor: context.admin
      )
      |> then(&Providers.check_provider!(&1.id, 1, %{}, actor: context.admin))
      |> then(&Providers.enable_provider!(&1, 1, actor: context.admin))

    Targets.create_external_identity!(
      context.target.id,
      source,
      "hostname",
      context.target.name,
      actor: context.admin
    )

    now = DateTime.utc_now()

    for {receipt_id, state, seconds_ago} <- [
          {"#{suffix}-initial", :firing, 120},
          {"#{suffix}-recovered", :recovered, 90},
          {"#{suffix}-refired", :firing, 60}
        ] do
      ingest_proposal_signal!(
        provider,
        context.target.name,
        event_key,
        receipt_id,
        state,
        DateTime.add(now, -seconds_ago, :second)
      )
    end

    [incident] = Cases.list_cases!(actor: context.admin)
    prior_run = Cases.active_resolution_run!(incident.id, authorize?: false)
    [current] = Cases.signal_context_evidence!(incident.id, authorize?: false)

    stale =
      Cases.list_evidence!(actor: context.admin)
      |> Enum.find(&(&1.case_id == incident.id and &1.content["state"] == "recovered"))

    assert stale.kind == "signal_event"
    assert current.content["state"] == "firing"

    attention =
      Cases.require_case_attention!(
        incident.id,
        incident.revision,
        prior_run.id,
        prior_run.revision,
        "proposal-signal-attention-#{suffix}",
        "Resolver interrupted",
        %{"action" => "retry_resolver"},
        "Resume the Case",
        authorize?: false
      )

    paused_run = Cases.get_resolution_run!(prior_run.id, authorize?: false)

    resumed_run =
      Cases.resume_case!(
        attention.id,
        attention.revision,
        paused_run.id,
        paused_run.revision,
        paused_run.authority_mode,
        paused_run.max_elapsed_seconds,
        paused_run.max_resolver_turns,
        paused_run.max_target_requests,
        paused_run.max_effects,
        paused_run.max_related_targets,
        paused_run.max_ai_usage_units,
        paused_run.max_no_progress_turns,
        "Continue after Resolver interruption",
        actor: context.operator
      )

    resumed_turn =
      Cases.list_turns!(actor: context.admin)
      |> Enum.find(&(&1.resolution_run_id == resumed_run.id))

    {incident, prior_run, resumed_run, current, stale, resumed_turn}
  end

  defp ingest_proposal_signal!(provider, target_name, event_key, receipt_id, state, occurred_at) do
    Signals.ingest_signal!(
      provider.id,
      provider.revision,
      %Signal.Envelope{body: receipt_id, headers: %{}, received_at: occurred_at},
      %{
        authenticate: fn provider_state, _envelope ->
          {:ok,
           %Signal.AuthenticatedReceipt{receipt_id: receipt_id, source: provider_state.source}}
        end,
        normalize: fn _provider_state, _envelope, _receipt ->
          {:ok,
           [
             %Signal.Event{
               receipt_id: receipt_id,
               event_key: event_key,
               state: state,
               occurred_at: occurred_at,
               target_ref: %{kind: :hostname, value: target_name},
               attributes: %{
                 "labels" => %{
                   "alertname" => "ServiceUnavailable",
                   "service" => "api.service"
                 }
               }
             }
           ]}
        end
      },
      authorize?: false
    )
  end

  defp enable_signal_automation!(admin) do
    current = Cases.current_authority_setting!(actor: admin)

    Cases.configure_authority_setting!(
      current.setting_revision,
      current.authority_mode,
      true,
      current.max_elapsed_seconds,
      current.max_resolver_turns,
      current.max_target_requests,
      current.max_effects,
      current.max_related_targets,
      current.max_ai_usage_units,
      current.max_no_progress_turns,
      "enable resumed Signal Proposal test",
      actor: admin
    )
  end

  defp proposal_intent(evidence_id, context) do
    %{
      "type" => "proposal",
      "delay_seconds" => 0,
      "purpose" => "remediation",
      "request_kind" => "effect",
      "tool_id" => "effect-tool",
      "target_id" => context.target.id,
      "target_revision" => context.target.revision,
      "access_method_id" => context.method.id,
      "access_method_revision" => context.method.revision,
      "capability" => "effect.service",
      "operation" => "service.restart",
      "selectors" => %{"service" => "api"},
      "parameters" => %{"service" => "api"},
      "reason" => "Restart the unhealthy API service",
      "evidence_ids" => [evidence_id],
      "affected_conditions" => [],
      "expected_result" => %{"service" => "running"},
      "tool" => %{
        "request_kind" => "effect",
        "id" => "effect-tool",
        "target_id" => context.target.id,
        "target_revision" => context.target.revision,
        "access_method_id" => context.method.id,
        "access_method_revision" => context.method.revision,
        "provider_id" => context.provider.id,
        "provider_revision" => context.provider.revision,
        "capability" => "effect.service",
        "operation" => "service.restart"
      },
      "verification_intent" => %{
        "tool_id" => "verification-tool",
        "selectors" => %{"service" => "api"},
        "parameters" => %{"service" => "api"},
        "expected_result" => %{"service" => "running"}
      },
      "verification_tool" => %{
        "id" => "verification-tool",
        "target_id" => context.target.id,
        "target_revision" => context.target.revision,
        "access_method_id" => context.method.id,
        "access_method_revision" => context.method.revision,
        "provider_id" => context.provider.id,
        "provider_revision" => context.provider.revision,
        "capability" => "observe.service",
        "operation" => "service.inspect"
      }
    }
  end

  defp resolver_identity do
    %{
      "provider_id" => Ash.UUID.generate(),
      "provider_revision" => 1,
      "assignment_id" => Ash.UUID.generate(),
      "assignment_revision" => 1
    }
  end
end
