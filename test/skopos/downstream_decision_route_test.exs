defmodule Skopos.DownstreamDecisionRouteTest do
  use Skopos.DataCase, async: false

  alias Skopos.{Accounts, Cases, Providers, Targets}
  alias Skopos.Cases.ResolutionRun.Budget, as: Budget

  @password "correct horse battery staple"

  setup do
    admin =
      Accounts.bootstrap!("downstream-admin@example.com", @password, @password, authorize?: true)

    operator =
      Accounts.create_user!("downstream-operator@example.com", @password, :operator, actor: admin)

    provider =
      Providers.create_provider!(
        "downstream-target-provider",
        :target,
        "fixture-target",
        %{"endpoint" => "reachable"},
        %{"token" => "downstream-target-secret"},
        actor: admin
      )
      |> then(&Providers.enable_provider!(&1, 1, actor: admin))

    target = Targets.create_target!("downstream-linux", "host", "linux", %{}, nil, actor: admin)

    method =
      Targets.create_access_method!(
        target.id,
        provider.id,
        "downstream-ssh",
        "ssh",
        "ssh://downstream-linux",
        provider.revision,
        10,
        ["effect.service", "observe.service"],
        actor: admin
      )
      |> then(&Targets.check_access_method!(&1.id, &1.revision, %{}, actor: admin))

    %{admin: admin, operator: operator, provider: provider, target: target, method: method}
  end

  test "Proposal keeps one exact source Turn for the authority owner", context do
    {incident, run} = open_case!("proposal", context.operator)
    evidence = evidence!(incident, run, "proposal")
    intent = proposal_intent(evidence.id, context)
    turn = completed_turn!(incident, run, "proposal", intent, :proposal)

    assert {:ok, routed} =
             Cases.route_downstream_decision(turn.id, authorize?: false)

    [proposal] = Cases.list_proposals!(actor: context.admin)

    assert proposal.status == :recommended
    assert routed.status == :needs_attention

    assert routed.pending_intent == %{
             "action" => "view_recommendation",
             "proposal_id" => proposal.id
           }

    assert Cases.get_resolution_run!(run.id, authorize?: false).effect_count == 0
    assert Cases.get_turn!(turn.id, authorize?: false).result["intent"] == intent

    key = Budget.key("resolver-route:downstream", turn.id)
    event = Cases.case_event_by_idempotency!(incident.id, key, authorize?: false)
    assert event.event_type == "resolver_decision_routed"
    assert event.data["source_turn_id"] == turn.id
    assert event.data["result_digest"] == turn.result_digest
    assert event.data["intent_type"] == "proposal"

    assert {:ok, replayed} =
             Cases.route_downstream_decision(turn.id, authorize?: false)

    assert replayed.id == routed.id

    assert Enum.count(
             Cases.list_case_events!(actor: context.admin),
             &(&1.case_id == incident.id and &1.event_type == "resolver_decision_routed")
           ) == 1
  end

  test "recovery conclusion cannot use ordinary Evidence as fresh verification", context do
    {incident, run} = open_case!("recovery", context.operator)
    evidence = evidence!(incident, run, "recovery")

    intent = %{
      "type" => "recovery_conclusion",
      "reason" => "An ordinary observation is not a verified recovery check",
      "evidence_ids" => [evidence.id]
    }

    started =
      Cases.start_turn!(
        incident.id,
        run.id,
        "ordinary-evidence-recovery",
        %{"objective" => "Check recovery evidence"},
        %{"action" => "continue"},
        "Review Resolver limits",
        authorize?: false
      ).value

    turn =
      Cases.complete_turn!(
        started.id,
        started.revision,
        %{
          "outcome" => "decision",
          "intent" => intent,
          "resolver" => resolver_identity(),
          "usage" => %{"input_tokens" => 1, "output_tokens" => 1}
        },
        :none,
        %{"action" => "route_resolver_decision", "turn_id" => started.id},
        "Review the Resolver decision",
        authorize?: false
      ).value

    assert {:error, _error} = Cases.route_downstream_decision(turn.id, authorize?: false)
    assert Cases.get_case!(incident.id, authorize?: false).status == :running

    assert Cases.get_case!(incident.id, authorize?: false).pending_intent == %{}

    assert Cases.get_resolution_run!(run.id, authorize?: false).status == :running
  end

  test "handoff pauses the Case once with exact requested human input", context do
    {incident, run} = open_case!("handoff", context.operator)

    intent = %{
      "type" => "handoff",
      "reason" => "The registered methods cannot observe the failed storage path",
      "required_input" => "Attach a storage management Access Method"
    }

    turn = completed_turn!(incident, run, "handoff", intent, :human_input)

    assert {:ok, routed} =
             Cases.route_downstream_decision(turn.id, authorize?: false)

    assert routed.status == :needs_attention
    assert routed.stop_reason == intent["reason"]
    assert routed.required_human_input == intent["required_input"]

    assert routed.pending_intent == %{
             "action" => "provide_human_input",
             "source_turn_id" => turn.id
           }

    assert Cases.get_resolution_run!(run.id, authorize?: false).status == :needs_attention

    assert {:ok, replayed} =
             Cases.route_downstream_decision(turn.id, authorize?: false)

    assert replayed.id == routed.id

    assert Enum.count(
             Cases.list_case_events!(actor: context.admin),
             &(&1.case_id == incident.id and &1.event_type == "case_needs_attention")
           ) == 1
  end

  test "malformed decisions and another pending owner fail without overwrite", context do
    {malformed_case, malformed_run} = open_case!("malformed", context.operator)
    evidence = evidence!(malformed_case, malformed_run, "malformed")

    malformed =
      evidence.id
      |> proposal_intent(context)
      |> Map.delete("verification_tool")

    malformed_turn =
      completed_turn!(malformed_case, malformed_run, "malformed", malformed, :proposal)

    assert {:error, %Ash.Error.Invalid{}} =
             Cases.route_downstream_decision(malformed_turn.id, authorize?: false)

    assert Cases.get_case!(malformed_case.id, authorize?: false).pending_intent == %{}

    {conflict_case, conflict_run} = open_case!("conflict", context.operator)
    conflict_evidence = evidence!(conflict_case, conflict_run, "conflict")

    conflict_turn =
      completed_turn!(
        conflict_case,
        conflict_run,
        "conflict",
        proposal_intent(conflict_evidence.id, context),
        :proposal
      )

    existing = %{"action" => "another_owner", "reference" => "keep-me"}

    Cases.record_case_pending_intent!(
      conflict_case,
      conflict_case.revision,
      existing,
      authorize?: false
    )

    assert {:error, _error} =
             Cases.route_downstream_decision(conflict_turn.id, authorize?: false)

    assert Cases.get_case!(conflict_case.id, authorize?: false).pending_intent == existing
  end

  defp open_case!(source_ref, actor) do
    incident =
      Cases.open_case!(
        :manual,
        "test",
        source_ref,
        "Case #{source_ref}",
        :warning,
        %{"desired_outcome" => "Target responds as expected"},
        nil,
        :en,
        actor: actor
      )

    {incident, Cases.active_resolution_run!(incident.id, authorize?: false)}
  end

  defp evidence!(incident, run, suffix) do
    Cases.append_evidence!(
      incident.id,
      run.id,
      nil,
      "downstream-evidence-#{suffix}",
      "observation",
      "fixture",
      "observation-#{suffix}",
      %{"status" => "observed", "service" => "unhealthy"},
      DateTime.utc_now(),
      authorize?: false
    )
  end

  defp completed_turn!(incident, run, suffix, intent, progress_kind) do
    started =
      Cases.start_turn!(
        incident.id,
        run.id,
        "downstream-turn-#{suffix}",
        %{"objective" => "Resolve the incident"},
        %{"action" => "continue"},
        "Review Resolver limits",
        authorize?: false
      )

    Cases.complete_turn!(
      started.value.id,
      started.value.revision,
      %{
        "outcome" => "decision",
        "intent" => intent,
        "resolver" => resolver_identity(),
        "usage" => %{"input_tokens" => 1, "output_tokens" => 1}
      },
      progress_kind,
      %{"action" => "route_resolver_decision", "turn_id" => started.value.id},
      "Review the Resolver decision",
      authorize?: false
    ).value
  end

  defp proposal_intent(evidence_id, context) do
    verification_tool_id = "observation-tool"
    target_id = context.target.id
    access_method_id = context.method.id
    provider_id = context.provider.id

    %{
      "type" => "proposal",
      "delay_seconds" => 0,
      "purpose" => "remediation",
      "request_kind" => "effect",
      "tool_id" => "effect-tool",
      "target_id" => target_id,
      "target_revision" => context.target.revision,
      "access_method_id" => access_method_id,
      "access_method_revision" => context.method.revision,
      "capability" => "effect.service",
      "operation" => "service.restart",
      "selectors" => %{"service" => "api"},
      "parameters" => %{"service" => "api"},
      "reason" => "Restart the failed API service",
      "evidence_ids" => [evidence_id],
      "affected_conditions" => [],
      "expected_result" => %{"service" => "running"},
      "tool" => %{
        "request_kind" => "effect",
        "id" => "effect-tool",
        "target_id" => target_id,
        "target_revision" => context.target.revision,
        "access_method_id" => access_method_id,
        "access_method_revision" => context.method.revision,
        "provider_id" => provider_id,
        "provider_revision" => context.provider.revision,
        "capability" => "effect.service",
        "operation" => "service.restart"
      },
      "verification_intent" => %{
        "tool_id" => verification_tool_id,
        "selectors" => %{"service" => "api"},
        "parameters" => %{"service" => "api"},
        "expected_result" => %{"service" => "running"}
      },
      "verification_tool" => %{
        "id" => verification_tool_id,
        "target_id" => target_id,
        "target_revision" => context.target.revision,
        "access_method_id" => access_method_id,
        "access_method_revision" => context.method.revision,
        "provider_id" => provider_id,
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
