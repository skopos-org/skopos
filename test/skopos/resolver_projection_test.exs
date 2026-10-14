defmodule Skopos.ResolverProjectionTest do
  use Skopos.DataCase, async: false

  alias Skopos.{Accounts, Cases, Providers, Signals, Targets}
  alias Skopos.Cases.Turn.ResolverProjection, as: ResolverProjection
  alias Skopos.Providers.{AI, Signal, Target}

  @password "correct horse battery staple"
  @provider_secret "target-provider-secret"

  setup do
    admin =
      Accounts.bootstrap!("projection-admin@example.com", @password, @password, authorize?: true)

    operator =
      Accounts.create_user!("projection-operator@example.com", @password, :operator, actor: admin)

    current = Cases.current_authority_setting!(actor: admin)

    Cases.configure_authority_setting!(
      current.setting_revision,
      :auto,
      true,
      600,
      4,
      5,
      2,
      3,
      10_000,
      2,
      "configure Resolver projection",
      actor: admin
    )

    provider =
      Providers.create_provider!(
        "projection-target-provider",
        :target,
        "fixture-target",
        %{"endpoint" => "reachable"},
        %{"token" => @provider_secret},
        actor: admin
      )
      |> then(&Providers.enable_provider!(&1, 1, actor: admin))

    target =
      Targets.create_target!(
        "linux-01",
        "host",
        "linux",
        %{"site" => "tokyo"},
        nil,
        actor: admin
      )

    method =
      Targets.create_access_method!(
        target.id,
        provider.id,
        "primary-ssh",
        "ssh",
        "ssh://endpoint-secret",
        provider.revision,
        10,
        ["observe.system", "effect.service"],
        actor: admin
      )
      |> then(&Targets.check_access_method!(&1.id, &1.revision, %{}, actor: admin))

    %{
      admin: admin,
      operator: operator,
      provider: provider,
      target: target,
      method: method
    }
  end

  test "selected Target operating instructions reach the Resolver", context do
    target =
      Targets.update_target!(
        context.target,
        context.target.revision,
        %{operating_instructions: "Do not modify root"},
        actor: context.admin
      )

    {incident, run} = open!("operator-instructions", context.operator, target)
    started = start!(incident, run, "operator-instructions-turn")
    capabilities = %Target.Capabilities{observations: [], effects: []}
    checked_catalog!(context, capabilities)

    assert {:ok, request, _context} =
             ResolverProjection.build(started.value.id, selection())

    assert request.operating_instructions == "Do not modify root"
    assert request.selected_target_revision == target.revision
  end

  test "selected Target projection exposes only the active method-operation intersection",
       context do
    other =
      Targets.create_target!("switch-01", "network_device", "cisco_ios_xe", %{}, nil,
        actor: context.admin
      )

    operator =
      Accounts.change_preferred_language!(context.operator, :ja, actor: context.operator)

    {incident, run} = open!("selected", operator, context.target)

    signal =
      Cases.append_evidence!(
        incident.id,
        run.id,
        nil,
        "projection-signal",
        "signal",
        "zabbix",
        "event-1",
        %{"target_id" => context.target.id, "message" => "disk errors increasing"},
        DateTime.utc_now(),
        authorize?: false
      )

    searched =
      Cases.search_case_targets!(
        incident.id,
        run.id,
        "projection-search",
        "switch-01",
        20,
        %{"action" => "search_targets"},
        "Review Target search",
        actor: context.operator
      )

    assert searched.value.content["targets"] |> hd() |> Map.fetch!("id") == other.id

    started = start!(incident, searched.run, "selected-turn")

    capabilities = %Target.Capabilities{
      observations: [
        operation("observe.system", "system.inspect", "Inspect using #{@provider_secret}"),
        operation("observe.network", "network.inspect", "Inspect network state")
      ],
      effects: [
        operation("effect.service", "service.restart", "Restart one service"),
        operation("effect.user", "user.disable", "Disable one user")
      ]
    }

    context = checked_catalog!(context, capabilities)

    assert {:ok, request, _context} =
             ResolverProjection.build(started.value.id, selection())

    assert request.case_id == incident.id
    assert request.turn == 1
    assert request.session_id == "resolver:#{run.id}"
    assert request.alert_state == :not_applicable
    assert request.report_language == :ja
    assert request.selected_target_id == context.target.id
    assert request.selected_target_revision == context.target.revision
    assert request.budget.remaining_turns == 4
    assert request.budget.remaining_target_requests == 4

    assert [%AI.ObservationTool{} = observation] = request.observation_tools
    assert observation.access_method_id == context.method.id
    assert observation.provider_id == context.provider.id
    assert observation.provider_revision == context.provider.revision
    assert observation.capability == "observe.system"
    assert observation.operation == "system.inspect"
    assert observation.description == "Access Method primary-ssh: Inspect using [REDACTED]"

    assert [%AI.ProposalTool{} = observation_request, %AI.ProposalTool{} = proposal] =
             request.proposal_tools

    assert observation_request.request_kind == :observation
    assert proposal.request_kind == :effect
    assert proposal.provider_id == context.provider.id
    assert proposal.provider_revision == context.provider.revision
    assert proposal.capability == "effect.service"
    assert proposal.operation == "service.restart"

    assert Enum.any?(
             request.evidence,
             &(&1.id == signal.id and &1.target_id == context.target.id)
           )

    assert [%AI.TargetCandidate{id: candidate_id}] = request.target_candidates
    assert candidate_id == other.id
    assert other.id in request.disclosure.allowed_target_ids

    encoded = inspect(request)
    refute encoded =~ @provider_secret
    refute encoded =~ "endpoint-secret"

    refute_receive {:observe, _, _}
    refute_receive {:effect, _, _}
    refute_receive {:resolve, _, _}
  end

  test "registered relation stays visible while traversal requires an available next Access Method",
       context do
    guest =
      Targets.create_target!("guest-without-access", "host", "linux", %{}, nil,
        actor: context.admin
      )

    relation =
      Targets.create_relationship!(
        guest.id,
        context.target.id,
        "hosted_by",
        %{},
        nil,
        actor: context.admin
      )

    {incident, run} = open!("related-unavailable", context.operator, context.target)
    started = start!(incident, run, "related-unavailable-turn")
    capabilities = %Target.Capabilities{observations: [], effects: []}
    context = checked_catalog!(context, capabilities)

    assert {:ok, unavailable, _context} =
             ResolverProjection.build(started.value.id, selection())

    assert [%AI.TargetRelation{id: id}] = unavailable.target_relations
    assert id == relation.id
    assert unavailable.traversable_relation_ids == []

    Targets.create_access_method!(
      guest.id,
      context.provider.id,
      "guest-ssh",
      "ssh",
      "ssh://guest",
      context.provider.revision,
      10,
      ["observe.system"],
      actor: context.admin
    )
    |> then(&Targets.check_access_method!(&1.id, &1.revision, %{}, actor: context.admin))

    assert {:ok, available, _context} =
             ResolverProjection.build(started.value.id, selection())

    assert [%AI.TargetRelation{id: ^id}] = available.target_relations
    assert available.traversable_relation_ids == [id]
  end

  test "exhausted traversal budget retains relation evidence for an effect", context do
    guest =
      Targets.create_target!("guest-after-traversal", "host", "linux", %{}, nil,
        actor: context.admin
      )

    relation =
      Targets.create_relationship!(
        guest.id,
        context.target.id,
        "managed_by",
        %{},
        nil,
        actor: context.admin
      )

    {incident, run} = open!("relation-after-traversal", context.operator, context.target)

    run =
      Cases.update_resolution_run_counters!(
        run,
        run.revision,
        %{related_target_count: run.max_related_targets},
        authorize?: false
      )

    started = start!(incident, run, "relation-after-traversal-turn")
    capabilities = %Target.Capabilities{observations: [], effects: []}
    checked_catalog!(context, capabilities)

    assert {:ok, request, _context} =
             ResolverProjection.build(started.value.id, selection())

    assert [%AI.TargetRelation{id: id, revision: revision}] = request.target_relations
    assert id == relation.id
    assert revision == relation.revision
    assert request.traversable_relation_ids == []
  end

  test "effect tools require a matching observation fact before disclosure", context do
    {incident, run} = open!("evidence-gate", context.operator, context.target)
    started = start!(incident, run, "evidence-gate-turn")

    observation = operation("observe.system", "system.inspect", "Inspect system state")

    effect = %Target.Operation{
      capability: "effect.service",
      operation: "service.restart",
      description: "Restart using the observed state",
      input_schema: %{
        "type" => "object",
        "properties" => %{
          "selectors" => %{"type" => "object", "maxProperties" => 0},
          "parameters" => %{
            "type" => "object",
            "properties" => %{"expected_status" => %{"type" => "string"}},
            "required" => ["expected_status"],
            "additionalProperties" => false
          }
        },
        "required" => ["selectors", "parameters"],
        "additionalProperties" => false
      },
      evidence_requirements: [
        %Target.EvidenceRequirement{
          parameter: "expected_status",
          fact: "status",
          observation: "system.inspect"
        }
      ]
    }

    capabilities = %Target.Capabilities{observations: [observation], effects: [effect]}
    context = checked_catalog!(context, capabilities)

    assert {:ok, before_observation, _context} =
             ResolverProjection.build(started.value.id, selection())

    assert [%AI.ObservationTool{id: observation_tool_id}] =
             before_observation.observation_tools

    assert [%AI.ProposalTool{request_kind: :observation, id: observation_request_id}] =
             before_observation.proposal_tools

    refute observation_tool_id == observation_request_id

    evidence =
      Cases.append_evidence!(
        incident.id,
        run.id,
        started.value.id,
        "evidence-gate-observation",
        "observation",
        "target_provider",
        observation_request_id,
        %{
          "target_id" => context.target.id,
          "tool_id" => observation_request_id,
          "facts" => %{"status" => "inactive"}
        },
        DateTime.utc_now(),
        authorize?: false
      )

    assert {:ok, after_observation, _context} =
             ResolverProjection.build(started.value.id, selection())

    assert [_observation_request, %AI.ProposalTool{} = proposal] =
             after_observation.proposal_tools

    assert proposal.operation == "service.restart"
    assert proposal.evidence_requirements == effect.evidence_requirements
    assert Enum.any?(after_observation.evidence, &(&1.id == evidence.id))

    Cases.append_evidence!(
      incident.id,
      run.id,
      started.value.id,
      "evidence-gate-verification",
      "target_verification",
      "fixture",
      "verified-current-state",
      %{
        "target_id" => context.target.id,
        "access_method_id" => proposal.access_method_id,
        "status" => "verified",
        "facts" => %{"status" => "active"}
      },
      DateTime.add(evidence.observed_at, 1, :microsecond),
      authorize?: false
    )

    assert {:ok, after_verification, _context} =
             ResolverProjection.build(started.value.id, selection())

    refute Enum.any?(after_verification.proposal_tools, &(&1.operation == "service.restart"))
  end

  test "preselection projection exposes candidates without probing Target providers", context do
    {incident, run} = open!("preselection", context.operator)

    searched =
      Cases.search_case_targets!(
        incident.id,
        run.id,
        "preselection-search",
        "linux-01",
        20,
        %{"action" => "search_targets"},
        "Review Target search",
        actor: context.operator
      )

    started =
      Cases.start_turn!(
        incident.id,
        searched.run.id,
        "preselection-turn",
        %{
          "objective" => "Select a returned Target",
          "source" => "target_search",
          "evidence_id" => searched.value.id
        },
        %{"action" => "continue"},
        "Review Target search",
        authorize?: false
      )

    assert {:ok, request, _context} =
             ResolverProjection.build(started.value.id, selection())

    assert is_nil(request.selected_target_id)
    assert request.observation_tools == []
    assert request.proposal_tools == []
    assert [%AI.TargetCandidate{id: target_id}] = request.target_candidates
    assert target_id == context.target.id
  end

  test "projection enforces the AI contract byte and item ceilings", context do
    {incident, run} = open!("bounded", context.operator, context.target)

    for index <- 1..50 do
      Cases.append_evidence!(
        incident.id,
        run.id,
        nil,
        "bounded-evidence-#{index}",
        "observation",
        "fixture",
        "observation-#{index}",
        %{
          "target_id" => context.target.id,
          "ordinal" => index,
          "payload" => String.duplicate("x", 2_000)
        },
        DateTime.utc_now(),
        authorize?: false
      )
    end

    started = start!(incident, run, "bounded-turn")

    assert {:ok, request, _context} =
             ResolverProjection.build(started.value.id, selection())

    limits = AI.resolver_disclosure_limits()
    assert length(AI.resolver_disclosure_items(request)) <= limits.max_items
    assert AI.resolver_disclosure_size(request) <= limits.max_bytes
    assert length(request.evidence) <= limits.max_items
    assert :ok = AI.Validator.validate_request(:resolve, request)
  end

  test "selected observations and verification retain their exact facts and diagnostics",
       context do
    {incident, run} = open!("compact-evidence", context.operator, context.target)

    applied =
      Cases.append_evidence!(
        incident.id,
        run.id,
        nil,
        "compact-applied-observation",
        "observation",
        "fixture",
        Ecto.UUID.generate(),
        %{
          "request_kind" => "observation",
          "target_id" => context.target.id,
          "access_method_id" => context.method.id,
          "capability" => "observe.service",
          "operation" => "service.inspect",
          "selectors" => %{"unit" => "api.service"},
          "parameters" => %{},
          "status" => "applied",
          "category" => "target_observed",
          "facts" => %{"active_state" => "inactive"},
          "details" => %{
            "stdout" => %{"encoding" => "utf-8", "value" => String.duplicate("x", 8_000)}
          }
        },
        DateTime.utc_now(),
        authorize?: false
      )

    failed =
      Cases.append_evidence!(
        incident.id,
        run.id,
        nil,
        "compact-failed-effect",
        "operation_outcome",
        "fixture",
        Ecto.UUID.generate(),
        %{
          "request_kind" => "effect",
          "target_id" => context.target.id,
          "access_method_id" => context.method.id,
          "capability" => "request.ssh.effect",
          "operation" => "command.execute",
          "selectors" => %{},
          "parameters" => %{"command" => "systemctl start api.service"},
          "status" => "failed",
          "category" => "target_failed",
          "facts" => %{},
          "details" => %{
            "exit_status" => 1,
            "stderr" => %{
              "encoding" => "utf-8",
              "value" => "Interactive authentication required\n" <> String.duplicate("x", 4_000)
            }
          }
        },
        DateTime.add(DateTime.utc_now(), 1, :second),
        authorize?: false
      )

    verification =
      Cases.append_evidence!(
        incident.id,
        run.id,
        nil,
        "compact-verification",
        "target_verification",
        "fixture",
        Ecto.UUID.generate(),
        %{
          "target_id" => context.target.id,
          "access_method_id" => context.method.id,
          "operation_id" => Ecto.UUID.generate(),
          "status" => "not_verified",
          "category" => "target_not_verified",
          "expected" => %{"active_state" => "active"},
          "facts" => %{"active_state" => "inactive"},
          "provider_evidence" => %{"raw" => String.duplicate("x", 8_000)}
        },
        DateTime.add(DateTime.utc_now(), 2, :second),
        authorize?: false
      )

    started = start!(incident, run, "compact-evidence-turn")

    assert {:ok, request, _context} =
             ResolverProjection.build(started.value.id, selection())

    projected_applied = Enum.find(request.evidence, &(&1.id == applied.id))
    assert projected_applied.content["facts"] == %{"active_state" => "inactive"}
    assert projected_applied.content == applied.content
    assert projected_applied.content["details"]["stdout"]["value"] == String.duplicate("x", 8_000)

    projected_failed = Enum.find(request.evidence, &(&1.id == failed.id))
    assert projected_failed.content == failed.content
    assert projected_failed.content["details"]["exit_status"] == 1

    assert projected_failed.content["details"]["stderr"]["value"] ==
             "Interactive authentication required\n" <> String.duplicate("x", 4_000)

    projected_verification = Enum.find(request.evidence, &(&1.id == verification.id))
    assert projected_verification.content["facts"] == %{"active_state" => "inactive"}
    assert projected_verification.content == verification.content

    assert projected_verification.content["provider_evidence"]["raw"] ==
             String.duplicate("x", 8_000)
  end

  test "projection gives the Resolver bounded feedback for a rejected schema", context do
    {incident, run} = open!("schema-retry", context.operator, context.target)

    started =
      Cases.start_turn!(
        incident.id,
        run.id,
        "schema-retry-turn",
        %{
          "objective" => "Continue resolution after a retryable Resolver delivery failure",
          "source" => "resolver_delivery_failure",
          "source_turn_id" => Ecto.UUID.generate(),
          "category" => "invalid_output",
          "rejection_code" => "schema_validation"
        },
        %{"action" => "continue"},
        "Review Resolver limits",
        authorize?: false
      )

    assert {:ok, request, _context} =
             ResolverProjection.build(started.value.id, selection())

    assert request.retry_context == %{
             "category" => "invalid_output",
             "rejection_code" => "schema_validation"
           }
  end

  test "projection reserves the latest context from every correlated Signal source", context do
    now = DateTime.utc_now()
    target_ref = %{kind: :hostname, value: "linux-01"}

    for source <- ["alertmanager", "zabbix"] do
      Targets.create_external_identity!(
        context.target.id,
        source,
        "hostname",
        "linux-01",
        actor: context.admin
      )
    end

    alertmanager_provider = signal_provider!(context.admin, "alertmanager")
    zabbix_provider = signal_provider!(context.admin, "zabbix")

    ingest_signal!(
      alertmanager_provider,
      "alert-stale",
      "alert-fingerprint",
      "Stale alert title",
      target_ref,
      DateTime.add(now, -2, :second)
    )

    [incident] = Cases.list_cases!(actor: context.admin)
    run = Cases.active_resolution_run!(incident.id, authorize?: false)
    [stale] = Cases.signal_context_evidence!(incident.id, authorize?: false)

    ingest_signal!(
      alertmanager_provider,
      "alert-current",
      "alert-fingerprint",
      "Kubernetes workload is unavailable",
      target_ref,
      DateTime.add(now, -1, :second)
    )

    [alertmanager] = Cases.signal_context_evidence!(incident.id, authorize?: false)

    ingest_signal!(
      zabbix_provider,
      "zabbix-current",
      "zabbix-event-42",
      "skopos-validation.service is inactive on linux-01",
      target_ref,
      now
    )

    zabbix =
      Cases.signal_context_evidence!(incident.id, authorize?: false)
      |> Enum.find(&(&1.source == "zabbix"))

    assert length(Cases.active_conditions_for_case!(incident.id, authorize?: false)) == 2

    other =
      Targets.create_target!("candidate-01", "host", "linux", %{}, nil, actor: context.admin)

    searched =
      Cases.search_case_targets!(
        incident.id,
        run.id,
        "multi-source-search",
        "candidate-01",
        20,
        %{"action" => "search_targets"},
        "Review Target search",
        actor: context.operator
      )

    for index <- 1..50 do
      Cases.append_evidence!(
        incident.id,
        run.id,
        nil,
        "multi-source-history-#{index}",
        "observation",
        "fixture",
        "history-#{index}",
        %{
          "target_id" => context.target.id,
          "payload" => String.duplicate("x", 2_000),
          "ordinal" => index
        },
        DateTime.add(now, index + 1, :second),
        authorize?: false
      )
    end

    started = start!(incident, searched.run, "multi-source-turn")

    assert {:ok, request, _context} =
             ResolverProjection.build(started.value.id, selection())

    signal_evidence = Enum.filter(request.evidence, &(&1.kind == "signal_event"))

    assert MapSet.new(Enum.map(signal_evidence, & &1.id)) ==
             MapSet.new([alertmanager.id, zabbix.id])

    refute Enum.any?(request.evidence, &(&1.id == stale.id))

    assert Enum.any?(signal_evidence, fn evidence ->
             get_in(evidence.content, ["attributes", "title"]) ==
               "skopos-validation.service is inactive on linux-01"
           end)

    assert Enum.any?(request.target_candidates, &(&1.id == other.id))
    assert :ok = AI.Validator.validate_request(:resolve, request)
  end

  test "projection keeps only the latest result of an identical Target request", context do
    {incident, run} = open!("repeated-observation", context.operator, context.target)
    now = DateTime.utc_now()

    evidence = fn key, selectors, observed_at ->
      Cases.append_evidence!(
        incident.id,
        run.id,
        nil,
        key,
        "observation",
        "fixture",
        key,
        %{
          "request_kind" => "observation",
          "target_id" => context.target.id,
          "access_method_id" => context.method.id,
          "capability" => "observe.service",
          "operation" => "service.inspect",
          "selectors" => selectors,
          "parameters" => %{},
          "status" => "failed"
        },
        observed_at,
        authorize?: false
      )
    end

    older = evidence.("same-request-older", %{"unit" => "api.service"}, DateTime.add(now, -2))
    newest = evidence.("same-request-newest", %{"unit" => "api.service"}, now)

    different =
      evidence.("different-request", %{"unit" => "worker.service"}, DateTime.add(now, -1))

    started = start!(incident, run, "repeated-observation-turn")

    assert {:ok, request, _context} =
             ResolverProjection.build(started.value.id, selection())

    evidence_ids = Enum.map(request.evidence, & &1.id)
    assert newest.id in evidence_ids
    assert different.id in evidence_ids
    refute older.id in evidence_ids
  end

  test "inactive methods and disabled Providers are never exposed as tools", context do
    {method_case, method_run} = open!("inactive-method", context.operator, context.target)
    method_turn = start!(method_case, method_run, "inactive-method-turn")

    Targets.deactivate_access_method!(context.method, context.method.revision,
      actor: context.admin
    )

    assert {:ok, method_request, _context} =
             ResolverProjection.build(method_turn.value.id, selection())

    assert method_request.observation_tools == []
    assert method_request.proposal_tools == []

    second_method =
      Targets.create_access_method!(
        context.target.id,
        context.provider.id,
        "secondary-ssh",
        "ssh",
        "ssh://secondary",
        context.provider.revision,
        20,
        ["observe.system"],
        actor: context.admin
      )
      |> then(&Targets.check_access_method!(&1.id, &1.revision, %{}, actor: context.admin))

    assert second_method.active
    {provider_case, provider_run} = open!("disabled-provider", context.operator, context.target)
    provider_turn = start!(provider_case, provider_run, "disabled-provider-turn")

    Providers.disable_provider!(context.provider, context.provider.revision, actor: context.admin)

    assert {:ok, provider_request, _context} =
             ResolverProjection.build(provider_turn.value.id, selection())

    assert provider_request.observation_tools == []
    assert provider_request.proposal_tools == []
  end

  test "cancelled Cases and stale selected Targets stop before capability probing", context do
    {incident, run} = open!("cancelled", context.operator, context.target)
    started = start!(incident, run, "cancelled-turn")
    Cases.request_case_cancellation!(incident.id, incident.revision, actor: context.operator)

    assert {:error, "Case cancellation was requested"} =
             ResolverProjection.build(started.value.id, selection())

    {stale_case, stale_run} = open!("stale", context.operator, context.target)
    stale_turn = start!(stale_case, stale_run, "stale-turn")

    Targets.update_target!(
      context.target,
      context.target.revision,
      %{facts: %{"site" => "osaka"}},
      actor: context.admin
    )

    assert {:error, "Selected Target revision changed"} =
             ResolverProjection.build(stale_turn.value.id, selection())
  end

  defp open!(source_ref, actor, target \\ nil) do
    incident =
      Cases.open_case!(
        :manual,
        "test",
        source_ref,
        "Case #{source_ref}",
        :warning,
        %{"observed_problem" => "service unavailable", "desired_outcome" => "service available"},
        target && target.id,
        :en,
        actor: actor
      )

    {incident, Cases.active_resolution_run!(incident.id, authorize?: false)}
  end

  defp start!(incident, run, key) do
    Cases.start_turn!(
      incident.id,
      run.id,
      key,
      %{"objective" => "Identify and resolve the incident"},
      %{"action" => "continue"},
      "Review Resolver limits",
      authorize?: false
    )
  end

  defp selection do
    %AI.Selection{
      role: :resolver,
      provider_id: Ecto.UUID.generate(),
      provider_revision: 7,
      source: :assignment
    }
  end

  defp operation(capability, operation, description) do
    %Target.Operation{
      capability: capability,
      operation: operation,
      description: description,
      input_schema: %{"type" => "object"},
      output_schema: %{
        "type" => "object",
        "properties" => %{"status" => %{"type" => "string"}},
        "additionalProperties" => false
      },
      verification_schema: %{
        "type" => "object",
        "properties" => %{"status" => %{"type" => "string"}},
        "minProperties" => 1,
        "additionalProperties" => false
      }
    }
  end

  defp signal_provider!(admin, source) do
    Providers.create_provider!(
      "projection-#{source}",
      :signal,
      "fixture-signal",
      %{"source" => source},
      %{"secret" => "signal-secret"},
      actor: admin
    )
    |> then(&Providers.check_provider!(&1.id, 1, %{}, actor: admin))
    |> then(&Providers.enable_provider!(&1, 1, actor: admin))
  end

  defp ingest_signal!(provider, receipt_id, event_key, title, target_ref, occurred_at) do
    envelope = %Signal.Envelope{body: receipt_id, headers: %{}, received_at: occurred_at}

    event = %Signal.Event{
      receipt_id: receipt_id,
      event_key: event_key,
      state: :firing,
      occurred_at: occurred_at,
      target_ref: target_ref,
      attributes: %{"title" => title, "severity" => "critical"}
    }

    invocation = %{
      authenticate: fn adapter_state, _envelope ->
        {:ok,
         %Signal.AuthenticatedReceipt{
           receipt_id: receipt_id,
           source: adapter_state.source
         }}
      end,
      normalize: fn _adapter_state, _envelope, _receipt -> {:ok, [event]} end
    }

    Signals.ingest_signal!(provider.id, provider.revision, envelope, invocation)
  end

  defp checked_catalog!(context, capabilities) do
    current = Targets.get_access_method!(context.method.id, actor: context.admin)

    method =
      Targets.check_access_method!(
        current.id,
        current.revision,
        %{respond: fn -> {:ok, capabilities} end},
        actor: context.admin
      )

    %{context | method: method}
  end
end
