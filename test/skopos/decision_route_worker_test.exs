defmodule Skopos.DecisionRouteWorkerTest do
  use Skopos.DataCase, async: false

  alias Skopos.{Accounts, Cases, Providers, Targets}
  alias Skopos.Cases.Case.DecisionRouteWorker

  @password "correct horse battery staple"

  setup do
    admin = Accounts.bootstrap!("route-admin@example.com", @password, @password, authorize?: true)

    operator =
      Accounts.create_user!("route-operator@example.com", @password, :operator, actor: admin)

    provider =
      Providers.create_provider!(
        "route-target-provider",
        :target,
        "fixture-target",
        %{"endpoint" => "reachable"},
        %{"token" => "route-target-secret"},
        actor: admin
      )
      |> then(&Providers.enable_provider!(&1, 1, actor: admin))

    target = Targets.create_target!("route-effect-linux", "host", "linux", %{}, nil, actor: admin)

    method =
      Targets.create_access_method!(
        target.id,
        provider.id,
        "route-ssh",
        "ssh",
        "ssh://route-effect-linux",
        provider.revision,
        10,
        ["effect.service", "observe.service"],
        actor: admin
      )
      |> then(&Targets.check_access_method!(&1.id, &1.revision, %{}, actor: admin))

    %{admin: admin, operator: operator, provider: provider, target: target, method: method}
  end

  test "persisted Target discovery is routed once across duplicate delivery", context do
    target =
      Targets.create_target!("route-linux", "host", "linux", %{}, nil, actor: context.admin)

    {incident, run} = open_case!("target-search", context.operator)

    turn =
      completed_turn!(incident, run, "target-search", %{
        "type" => "target_search",
        "query" => "route-linux",
        "reason" => "Find the registered affected host"
      })

    job = %Oban.Job{args: %{"turn_id" => turn.id}}
    assert :ok = DecisionRouteWorker.perform(job)
    assert :ok = DecisionRouteWorker.perform(job)

    assert [evidence] =
             Cases.list_evidence!(actor: context.admin)
             |> Enum.filter(&(&1.case_id == incident.id))

    assert evidence.kind == "target_candidates"
    assert Enum.any?(evidence.content["targets"], &(&1["id"] == target.id))

    assert Enum.count(Cases.list_turns!(actor: context.admin), &(&1.case_id == incident.id)) == 2
    assert Cases.get_resolution_run!(run.id, authorize?: false).target_request_count == 1
  end

  @tag saved_proposal_citation_read_fault: true
  test "a saved Proposal decision survives a temporary citation read failure", context do
    {incident, run} = open_case!("citation-read", context.operator)
    evidence = evidence!(incident, run, "citation-read")

    turn =
      completed_turn!(
        incident,
        run,
        "citation-read",
        proposal_intent(evidence.id, context),
        :proposal
      )

    before_case = Cases.get_case!(incident.id, authorize?: false)
    before_run = Cases.get_resolution_run!(run.id, authorize?: false)
    before_turn = Cases.get_turn!(turn.id, authorize?: false)
    before_events = Cases.list_case_events!(actor: context.admin)
    job = %Oban.Job{args: %{"turn_id" => turn.id}}
    Repo.query!("ALTER TABLE evidences RENAME COLUMN content TO unavailable_content")

    try do
      assert {:error, source_error} = Cases.materialize_proposal(turn.id, authorize?: false)
      assert Exception.message(source_error) =~ "undefined_column"
      assert {:error, _error} = DecisionRouteWorker.perform(job)
    after
      Repo.query!("ALTER TABLE evidences RENAME COLUMN unavailable_content TO content")
    end

    assert Cases.get_case!(incident.id, authorize?: false) == before_case
    assert Cases.get_resolution_run!(run.id, authorize?: false) == before_run
    assert Cases.get_turn!(turn.id, authorize?: false) == before_turn
    assert Cases.list_case_events!(actor: context.admin) == before_events
    assert Cases.list_proposals!(actor: context.admin) == []
    assert Cases.list_operations!(actor: context.admin) == []
    assert Cases.list_ai_invocations!(authorize?: false) == []
    assert :ok = DecisionRouteWorker.perform(job)
    assert :ok = DecisionRouteWorker.perform(job)
    assert [proposal] = Cases.list_proposals!(actor: context.admin)
    assert proposal.source_turn_id == turn.id
    assert proposal.status == :recommended

    assert Cases.get_resolution_run!(run.id, authorize?: false).ai_usage_units ==
             before_run.ai_usage_units

    assert Cases.list_operations!(actor: context.admin) == []
    assert Cases.list_ai_invocations!(authorize?: false) == []
  end

  test "persisted Proposal reaches the authority pending state without an effect", context do
    {incident, run} = open_case!("proposal", context.operator)
    evidence = evidence!(incident, run, "proposal")

    turn =
      completed_turn!(incident, run, "proposal", proposal_intent(evidence.id, context), :proposal)

    assert :ok =
             DecisionRouteWorker.perform(%Oban.Job{args: %{"turn_id" => turn.id}})

    assert :ok =
             DecisionRouteWorker.perform(%Oban.Job{args: %{"turn_id" => turn.id}})

    routed = Cases.get_case!(incident.id, authorize?: false)

    [proposal] = Cases.list_proposals!(actor: context.admin)

    assert proposal.status == :recommended

    assert routed.pending_intent == %{
             "action" => "view_recommendation",
             "proposal_id" => proposal.id
           }

    assert routed.status == :needs_attention
    assert Cases.get_resolution_run!(run.id, authorize?: false).status == :needs_attention
    assert Cases.get_resolution_run!(run.id, authorize?: false).effect_count == 0
  end

  test "malformed persisted decision becomes explicit attention without Target calls", context do
    {incident, run} = open_case!("malformed", context.operator)

    turn =
      completed_turn!(incident, run, "malformed", %{
        "type" => "unrecognized_intent",
        "request" => %{"operation" => "must-not-run"}
      })

    job = %Oban.Job{args: %{"turn_id" => turn.id}}
    assert :ok = DecisionRouteWorker.perform(job)
    assert :ok = DecisionRouteWorker.perform(job)

    attention = Cases.get_case!(incident.id, authorize?: false)
    assert attention.status == :needs_attention
    assert attention.stop_reason == "Resolver decision routing failed"

    assert attention.pending_intent == %{
             "action" => "review_resolver_route",
             "source_turn_id" => turn.id
           }

    paused = Cases.get_resolution_run!(run.id, authorize?: false)
    assert paused.status == :needs_attention
    assert paused.target_request_count == 0
    assert paused.effect_count == 0
    assert Cases.list_evidence!(actor: context.admin) == []
  end

  test "rejected Target selection is re-evaluated with current candidates", context do
    {incident, run} = open_case!("selection-rejected", context.operator)
    unrelated = evidence!(incident, run, "selection-rejected")

    turn =
      completed_turn!(incident, run, "selection-rejected", %{
        "type" => "target_selection",
        "target_id" => context.target.id,
        "target_revision" => context.target.revision,
        "evidence_ids" => [unrelated.id],
        "reason" => "The observation shows the Target"
      })

    job = %Oban.Job{args: %{"turn_id" => turn.id}}
    assert :ok = DecisionRouteWorker.perform(job)
    assert :ok = DecisionRouteWorker.perform(job)

    refreshed = Cases.get_case!(incident.id, authorize?: false)
    assert refreshed.status == :running
    assert refreshed.selected_target_id == nil
    assert refreshed.pending_intent["action"] == "resolve_turn"
    assert refreshed.pending_intent["source_turn_id"] == turn.id

    assert [next_turn] =
             Cases.list_turns!(actor: context.admin)
             |> Enum.filter(&(&1.case_id == incident.id and &1.id != turn.id))

    assert next_turn.intent["source"] == "resolver_target_selection_rejected"
    assert next_turn.intent["rejection_code"] == "candidate_citation_changed"
    assert next_turn.status == :started

    assert Cases.list_case_events!(actor: context.admin)
           |> Enum.count(&(&1.event_type == "case_target_selected")) == 0
  end

  @tag queue_read_fault: true
  test "Resolver retry preserves unreadable valid source and next Turns", context do
    {incident, run} = open_case!("queue-read", context.operator)
    source = completed_turn!(incident, run, "queue-read", %{"type" => "handoff"})

    next_turn =
      Cases.start_turn!(
        incident.id,
        run.id,
        "queue-next",
        %{"objective" => "Continue investigation"},
        %{"action" => "continue"},
        "Review Resolver limits",
        authorize?: false
      ).value

    current = Cases.get_case!(incident.id, authorize?: false)
    before_run = Cases.get_resolution_run!(run.id, authorize?: false)
    before_turns = Cases.list_turns!(authorize?: false)

    columns =
      Repo.query!(
        "SELECT attname FROM pg_attribute WHERE attrelid = 'turns'::regclass AND attnum > 0 AND NOT attisdropped ORDER BY attnum"
      ).rows
      |> List.flatten()

    Repo.query!(
      "CREATE FUNCTION pg_temp.queue_read_fault(bigint) RETURNS bigint LANGUAGE plpgsql STABLE AS $$ BEGIN RAISE EXCEPTION 'Queued Turn temporarily unavailable'; END $$"
    )

    for {name, id} <- [{"source", source.id}, {"next", next_turn.id}] do
      Repo.query!("ALTER TABLE turns RENAME TO turns_queue_source")

      fields =
        Enum.map_join(columns, ", ", fn
          "revision" ->
            "CASE WHEN id = '#{id}'::uuid THEN pg_temp.queue_read_fault(revision) ELSE revision END AS revision"

          column ->
            "\"#{column}\""
        end)

      Repo.query!("CREATE VIEW turns AS SELECT #{fields} FROM turns_queue_source")

      try do
        assert {:error, %Ash.Error.Unknown{}} = Cases.get_turn(id, authorize?: false)

        result =
          Cases.queue_case_resolver_turn(current, current.revision, source.id, next_turn.id,
            authorize?: false
          )

        assert {:error, %Ash.Error.Unknown{} = error} = result
        assert Exception.message(error) =~ "Queued Turn temporarily unavailable", name
      after
        Repo.query!("DROP VIEW turns")
        Repo.query!("ALTER TABLE turns_queue_source RENAME TO turns")
      end

      assert Cases.get_case!(incident.id, authorize?: false) == current
      assert Cases.get_resolution_run!(run.id, authorize?: false) == before_run
      assert Cases.list_turns!(authorize?: false) == before_turns
      assert Cases.list_ai_invocations!(authorize?: false) == []
    end

    Repo.query!("DROP FUNCTION pg_temp.queue_read_fault(bigint)")

    assert {:ok, updated} =
             Cases.queue_case_resolver_turn(current, current.revision, source.id, next_turn.id,
               authorize?: false
             )

    assert updated.pending_intent == %{
             "action" => "resolve_turn",
             "turn_id" => next_turn.id,
             "source_turn_id" => source.id
           }

    assert {:error, _stale} =
             Cases.queue_case_resolver_turn(current, current.revision, source.id, next_turn.id,
               authorize?: false
             )

    assert Cases.get_case!(incident.id, authorize?: false).pending_intent ==
             updated.pending_intent

    assert Cases.list_ai_invocations!(authorize?: false) == []
  end

  test "Resolver retry rejects foreign, missing and identical Turns", context do
    {incident, run} = open_case!("retry-owner", context.operator)
    source = completed_turn!(incident, run, "retry-owner", %{"type" => "handoff"})
    {other, other_run} = open_case!("retry-other", context.operator)

    foreign =
      Cases.start_turn!(
        other.id,
        other_run.id,
        "foreign-turn",
        %{"objective" => "Unrelated investigation"},
        %{"action" => "continue"},
        "Review Resolver limits",
        authorize?: false
      ).value

    current = Cases.get_case!(incident.id, authorize?: false)

    for {source_id, next_id} <- [
          {source.id, foreign.id},
          {source.id, source.id},
          {Ash.UUID.generate(), foreign.id},
          {source.id, Ash.UUID.generate()}
        ] do
      assert {:error, %Ash.Error.Invalid{} = error} =
               Cases.queue_case_resolver_turn(
                 current,
                 current.revision,
                 source_id,
                 next_id,
                 authorize?: false
               )

      assert Exception.message(error) =~ "Resolver Turn belongs to another Case or ResolutionRun"
    end

    reloaded = Cases.get_case!(incident.id, authorize?: false)
    assert reloaded.revision == current.revision
    assert reloaded.pending_intent == current.pending_intent
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

  defp completed_turn!(incident, run, suffix, intent, progress_kind \\ :hypothesis) do
    started =
      Cases.start_turn!(
        incident.id,
        run.id,
        "decision-route-#{suffix}",
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

  defp evidence!(incident, run, suffix) do
    Cases.append_evidence!(
      incident.id,
      run.id,
      nil,
      "route-evidence-#{suffix}",
      "observation",
      "fixture",
      "observation-#{suffix}",
      %{"service" => "unhealthy"},
      DateTime.utc_now(),
      authorize?: false
    )
  end

  defp proposal_intent(evidence_id, context) do
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
      "target_revision" => 1,
      "access_method_id" => access_method_id,
      "access_method_revision" => context.method.revision,
      "capability" => "effect.service",
      "operation" => "service.restart",
      "selectors" => %{"service" => "api"},
      "parameters" => %{"service" => "api"},
      "reason" => "Restart the failed service",
      "evidence_ids" => [evidence_id],
      "affected_conditions" => [],
      "expected_result" => %{"service" => "running"},
      "tool" => %{
        "request_kind" => "effect",
        "id" => "effect-tool",
        "target_id" => target_id,
        "target_revision" => 1,
        "access_method_id" => access_method_id,
        "access_method_revision" => context.method.revision,
        "provider_id" => provider_id,
        "provider_revision" => 1,
        "capability" => "effect.service",
        "operation" => "service.restart"
      },
      "verification_intent" => %{
        "tool_id" => "observation-tool",
        "selectors" => %{"service" => "api"},
        "parameters" => %{"service" => "api"},
        "expected_result" => %{"service" => "running"}
      },
      "verification_tool" => %{
        "id" => "observation-tool",
        "target_id" => target_id,
        "target_revision" => 1,
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
