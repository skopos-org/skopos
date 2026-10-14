defmodule Skopos.TargetDiscoveryRouteTest do
  use Skopos.DataCase, async: false

  alias Skopos.{Accounts, Cases, Targets}

  @password "correct horse battery staple"

  setup do
    admin =
      Accounts.bootstrap!("route-admin@example.com", @password, @password, authorize?: true)

    operator =
      Accounts.create_user!("route-operator@example.com", @password, :operator, actor: admin)

    target =
      Targets.create_target!(
        "linux-route-01",
        "host",
        "linux",
        %{"site" => "tokyo"},
        nil,
        actor: admin
      )

    %{admin: admin, operator: operator, target: target}
  end

  test "persisted Target search routes once to candidate Evidence and the next Turn", context do
    {incident, run, source_turn} = completed_turn!("search", context.operator, search_intent())

    assert {:ok, routed} = Cases.route_target_discovery(source_turn.id, authorize?: false)
    assert routed.status == :charged
    assert routed.value.ordinal == 2
    assert routed.value.intent["source"] == "target_search"

    assert Cases.get_case!(incident.id, authorize?: false).pending_intent == %{
             "action" => "resolve_turn",
             "source_turn_id" => source_turn.id,
             "turn_id" => routed.value.id
           }

    assert {:ok, replayed} = Cases.route_target_discovery(source_turn.id, authorize?: false)
    assert replayed.status == :duplicate
    assert replayed.value.id == routed.value.id

    refreshed = Cases.get_resolution_run!(run.id, authorize?: false)
    assert refreshed.target_request_count == 1
    assert refreshed.turn_count == 2

    evidence = Cases.list_evidence!(actor: context.admin)
    assert [candidate] = Enum.filter(evidence, &(&1.kind == "target_candidates"))
    assert candidate.id == routed.value.intent["evidence_id"]

    assert [%{"id" => target_id, "revision" => target_revision}] =
             candidate.content["targets"]

    assert target_id == context.target.id
    assert target_revision == context.target.revision
    assert Cases.get_case!(incident.id, authorize?: false).selected_target_id == nil
  end

  test "persisted Target selection can use only cited candidates and starts one next Turn",
       context do
    incident = open!("selection", context.operator)
    run = Cases.active_resolution_run!(incident.id, authorize?: false)

    searched =
      Cases.search_case_targets!(
        incident.id,
        run.id,
        "selection-candidates",
        "linux-route-01",
        20,
        %{"action" => "find_target"},
        "Select a registered Target",
        actor: context.operator
      )

    intent = %{
      "type" => "target_selection",
      "target_id" => context.target.id,
      "target_revision" => context.target.revision,
      "evidence_ids" => [searched.value.id],
      "reason" => "The name and site match the incident"
    }

    source_turn = completed_turn!(incident, searched.run, "selection", intent)

    assert {:ok, routed} = Cases.route_target_discovery(source_turn.id, authorize?: false)
    assert routed.status == :charged
    assert routed.value.ordinal == 2
    assert routed.value.intent["selected_target_id"] == context.target.id

    selected = Cases.get_case!(incident.id, authorize?: false)
    assert selected.selected_target_id == context.target.id
    assert selected.selected_target_revision == context.target.revision
    assert selected.pending_intent["action"] == "resolve_turn"
    assert selected.pending_intent["source_turn_id"] == source_turn.id
    assert selected.pending_intent["turn_id"] == routed.value.id

    assert {:ok, replayed} = Cases.route_target_discovery(source_turn.id, authorize?: false)
    assert replayed.status == :duplicate
    assert replayed.value.id == routed.value.id

    events = Cases.list_case_events!(actor: context.admin)
    assert Enum.count(events, &(&1.event_type == "case_target_selected")) == 1
    assert Targets.list_external_identities!(actor: context.admin) == []
  end

  @tag target_selection_read_fault: true
  test "Target selection retains unreadable citation cause and retries the saved decision",
       context do
    incident = open!("selection-read-fault", context.operator)
    run = Cases.active_resolution_run!(incident.id, authorize?: false)

    searched =
      Cases.search_case_targets!(
        incident.id,
        run.id,
        "selection-read-candidates",
        "linux-route-01",
        20,
        %{"action" => "find_target"},
        "Select a registered Target",
        actor: context.operator
      )

    source =
      completed_turn!(incident, searched.run, "selection-read", %{
        "type" => "target_selection",
        "target_id" => context.target.id,
        "target_revision" => context.target.revision,
        "evidence_ids" => [searched.value.id],
        "reason" => "The discovered Target matches the incident"
      })

    before_case = Cases.get_case!(incident.id, authorize?: false)
    before_run = Cases.get_resolution_run!(run.id, authorize?: false)
    before_turn = Cases.get_turn!(source.id, authorize?: false)
    before_events = Cases.list_case_events!(actor: context.admin)
    job = %Oban.Job{args: %{"turn_id" => source.id}}
    Repo.query!("ALTER TABLE evidences RENAME COLUMN content TO unavailable_content")

    try do
      assert {:error, error} =
               Cases.select_case_target(
                 incident.id,
                 before_case.revision,
                 run.id,
                 [searched.value.id],
                 context.target.id,
                 context.target.revision,
                 "The discovered Target matches the incident",
                 "selection-read-direct",
                 authorize?: false
               )

      assert Exception.message(error) =~ "does not exist"
      assert {:error, _} = Skopos.Cases.Case.DecisionRouteWorker.perform(job)
    after
      Repo.query!("ALTER TABLE evidences RENAME COLUMN unavailable_content TO content")
    end

    assert Cases.get_case!(incident.id, authorize?: false) == before_case
    assert Cases.get_resolution_run!(run.id, authorize?: false) == before_run
    assert Cases.get_turn!(source.id, authorize?: false) == before_turn
    assert Cases.list_case_events!(actor: context.admin) == before_events
    assert Cases.list_ai_invocations!(authorize?: false) == []
    assert :ok = Skopos.Cases.Case.DecisionRouteWorker.perform(job)
    assert :ok = Skopos.Cases.Case.DecisionRouteWorker.perform(job)
    assert Cases.get_case!(incident.id, authorize?: false).selected_target_id == context.target.id
    after_run = Cases.get_resolution_run!(run.id, authorize?: false)
    assert after_run.turn_count == before_run.turn_count + 1
    assert after_run.ai_usage_units == before_run.ai_usage_units
  end

  test "search and selection hand the current Turn to downstream routing", context do
    {incident, _run, search_turn} =
      completed_turn!("discovery-chain", context.operator, search_intent())

    searched = Cases.route_target_discovery!(search_turn.id, authorize?: false)

    selection_turn =
      Cases.complete_turn!(
        searched.value.id,
        searched.value.revision,
        %{
          "outcome" => "decision",
          "intent" => %{
            "type" => "target_selection",
            "target_id" => context.target.id,
            "target_revision" => context.target.revision,
            "evidence_ids" => [searched.value.intent["evidence_id"]],
            "reason" => "The discovered Target matches the incident"
          },
          "usage" => %{"input_tokens" => 1, "output_tokens" => 1}
        },
        :hypothesis,
        %{"action" => "route_resolver_decision", "turn_id" => searched.value.id},
        "Review the Resolver decision",
        authorize?: false
      ).value

    selected = Cases.route_target_discovery!(selection_turn.id, authorize?: false)
    assert Cases.get_resolution_run!(selected.run.id, authorize?: false).no_progress_turns == 2

    downstream_turn =
      Cases.complete_turn!(
        selected.value.id,
        selected.value.revision,
        %{
          "outcome" => "decision",
          "intent" => %{
            "type" => "handoff",
            "reason" => "A real operator decision is required",
            "required_input" => "Choose a maintenance window"
          },
          "usage" => %{"input_tokens" => 1, "output_tokens" => 1}
        },
        :human_input,
        %{"action" => "route_resolver_decision", "turn_id" => selected.value.id},
        "Review the Resolver decision",
        authorize?: false
      ).value

    assert {:ok, routed} = Cases.route_downstream_decision(downstream_turn.id, authorize?: false)
    assert routed.status == :needs_attention
    assert routed.stop_reason == "A real operator decision is required"
    refute routed.stop_reason == "Resolver decision routing failed"

    assert routed.pending_intent == %{
             "action" => "provide_human_input",
             "source_turn_id" => downstream_turn.id
           }

    assert Cases.get_resolution_run!(selected.run.id, authorize?: false).turn_count == 3
    assert Cases.get_case!(incident.id, authorize?: false).selected_target_id == context.target.id
  end

  test "selecting the current Target again records no selection change and preserves replay",
       context do
    incident = open!("selection-repeat", context.operator)
    run = Cases.active_resolution_run!(incident.id, authorize?: false)

    searched =
      Cases.search_case_targets!(
        incident.id,
        run.id,
        "selection-repeat-candidates",
        "linux-route-01",
        20,
        %{"action" => "find_target"},
        "Select a registered Target",
        actor: context.operator
      )

    intent = %{
      "type" => "target_selection",
      "target_id" => context.target.id,
      "target_revision" => context.target.revision,
      "evidence_ids" => [searched.value.id],
      "reason" => "The Target matches"
    }

    source = completed_turn!(incident, searched.run, "selection-repeat", intent)
    first = Cases.route_target_discovery!(source.id, authorize?: false)
    selected = Cases.get_case!(incident.id, authorize?: false)

    repeat =
      Cases.complete_turn!(
        first.value.id,
        first.value.revision,
        %{
          "outcome" => "decision",
          "intent" => intent,
          "usage" => %{"input_tokens" => 1, "output_tokens" => 1}
        },
        :none,
        %{"action" => "route_resolver_decision", "turn_id" => first.value.id},
        "Review the Resolver decision",
        authorize?: false
      ).value

    assert {:ok, routed} = Cases.route_target_discovery(repeat.id, authorize?: false)
    assert routed.status == :charged
    assert routed.value.intent["source"] == "target_selection_unchanged"
    assert routed.value.intent["objective"] =~ "already selected"

    assert Cases.get_case!(incident.id, authorize?: false).selected_target_id ==
             selected.selected_target_id

    assert {:ok, replayed} = Cases.route_target_discovery(repeat.id, authorize?: false)
    assert replayed.status == :duplicate
    assert replayed.value.id == routed.value.id

    events = Cases.list_case_events!(actor: context.admin)
    assert Enum.count(events, &(&1.event_type == "case_target_selected")) == 1
    assert Enum.count(events, &(&1.event_type == "case_target_selection_unchanged")) == 1
    assert Cases.get_resolution_run!(run.id, authorize?: false).no_progress_turns == 2
  end

  test "stale selection and non-discovery results fail without a next Turn", context do
    incident = open!("rejected", context.operator)
    run = Cases.active_resolution_run!(incident.id, authorize?: false)

    searched =
      Cases.search_case_targets!(
        incident.id,
        run.id,
        "rejected-candidates",
        "linux-route-01",
        20,
        %{"action" => "find_target"},
        "Select a registered Target",
        actor: context.operator
      )

    intent = %{
      "type" => "target_selection",
      "target_id" => context.target.id,
      "target_revision" => context.target.revision,
      "evidence_ids" => [searched.value.id],
      "reason" => "Use the stale candidate"
    }

    source_turn = completed_turn!(incident, searched.run, "rejected", intent)

    Targets.update_target!(
      context.target,
      context.target.revision,
      %{facts: %{"site" => "osaka"}},
      actor: context.admin
    )

    assert {:error, _error} = Cases.route_target_discovery(source_turn.id, authorize?: false)
    assert Cases.get_case!(incident.id, authorize?: false).selected_target_id == nil
    assert Cases.get_resolution_run!(run.id, authorize?: false).turn_count == 1

    {_other_case, _other_run, other_turn} =
      completed_turn!("not-discovery", context.operator, %{
        "type" => "handoff",
        "reason" => "Need input",
        "required_input" => "Confirm ownership"
      })

    assert {:error, _error} = Cases.route_target_discovery(other_turn.id, authorize?: false)
  end

  test "unrelated pending work rejects discovery without partial progress", context do
    {incident, run, source_turn} =
      completed_turn!("pending-conflict", context.operator, search_intent())

    Cases.record_case_pending_intent!(
      incident,
      incident.revision,
      %{
        "action" => "resolve_turn",
        "turn_id" => Ash.UUID.generate()
      },
      authorize?: false
    )

    assert {:error, _error} = Cases.route_target_discovery(source_turn.id, authorize?: false)
    assert Cases.get_resolution_run!(run.id, authorize?: false).turn_count == 1
    assert Cases.list_evidence!(actor: context.admin) == []
  end

  defp completed_turn!(source_ref, actor, intent) do
    incident = open!(source_ref, actor)
    run = Cases.active_resolution_run!(incident.id, authorize?: false)
    {incident, run, completed_turn!(incident, run, source_ref, intent)}
  end

  defp completed_turn!(incident, run, key, intent) do
    started =
      Cases.start_turn!(
        incident.id,
        run.id,
        "source-#{key}",
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
        "usage" => %{"input_tokens" => 1, "output_tokens" => 1}
      },
      :hypothesis,
      %{"action" => "route_resolver_decision", "turn_id" => started.value.id},
      "Review the Resolver decision",
      authorize?: false
    ).value
  end

  defp open!(source_ref, actor) do
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
  end

  defp search_intent do
    %{
      "type" => "target_search",
      "query" => "linux-route-01",
      "reason" => "Find the registered Target"
    }
  end
end
