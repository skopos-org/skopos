defmodule Skopos.RelatedTargetRouteTest do
  use Skopos.DataCase, async: false

  alias Skopos.{Accounts, Cases, Providers, Signals, Targets}
  alias Skopos.Cases.Turn.ResolverProjection, as: ResolverProjection
  alias Skopos.Providers.{AI, Signal}

  @password "correct horse battery staple"

  setup do
    admin =
      Accounts.bootstrap!("relation-admin@example.com", @password, @password, authorize?: true)

    operator =
      Accounts.create_user!("relation-operator@example.com", @password, :operator, actor: admin)

    configure_limits!(admin, 8)

    provider =
      Providers.create_provider!(
        "relationship-target-provider",
        :target,
        "fixture-target",
        %{"endpoint" => "reachable"},
        %{"token" => "relationship-provider-secret"},
        actor: admin
      )
      |> then(&Providers.enable_provider!(&1, 1, actor: admin))

    linux = target!(admin, provider, "linux-01", "host", "linux", "linux-ssh")
    vm = target!(admin, provider, "vm-01", "virtual_machine", "custom-vm", "vm-ssh")
    bmc = target!(admin, provider, "bmc-01", "management_plane", "custom-bmc", "redfish")
    kubernetes = target!(admin, provider, "cluster-01", "cluster", "kubernetes", "k8s-api")

    switch =
      target!(admin, provider, "switch-01", "network_device", "cisco_ios_xe", "switch-netconf")

    runs_on = relationship!(admin, linux, vm, "runs_on")
    managed_by = relationship!(admin, vm, bmc, "managed_by")
    hosted_by = relationship!(admin, kubernetes, linux, "hosted_by")
    connected_through = relationship!(admin, linux, switch, "connected_through")

    %{
      admin: admin,
      operator: operator,
      provider: provider,
      linux: linux,
      vm: vm,
      bmc: bmc,
      kubernetes: kubernetes,
      switch: switch,
      runs_on: runs_on,
      managed_by: managed_by,
      hosted_by: hosted_by,
      connected_through: connected_through
    }
  end

  @tag projection_neighbor_read_fault: true
  test "Resolver retries an unreadable adjacent Target before paying for an incomplete context",
       context do
    provider =
      Providers.create_provider!(
        "neighbor-fault-ai",
        :ai,
        "fixture-ai",
        %{"model" => "resolver-model"},
        %{"api_key" => "fixture-secret"},
        actor: context.admin
      )
      |> then(&Providers.check_provider!(&1.id, &1.revision, %{}, actor: context.admin))
      |> then(&Providers.enable_provider!(&1, &1.revision, actor: context.admin))

    Skopos.TestAIUsage.configure!(provider.id, :resolver, 10, context.admin)
    {incident, run, _evidence, turn} = case_with_evidence!("late-neighbor-read", context)
    assert {:ok, baseline, _context} = projection(turn, context)
    assert context.vm.id in adjacent_target_ids(baseline, context.linux.id)
    before_case = Cases.get_case!(incident.id, authorize?: false)
    before_run = Cases.get_resolution_run!(run.id, authorize?: false)
    before_turn = Cases.get_turn!(turn.id, authorize?: false)

    columns =
      Repo.query!(
        "SELECT attname FROM pg_attribute WHERE attrelid = 'targets'::regclass AND attnum > 0 AND NOT attisdropped ORDER BY attnum"
      ).rows
      |> List.flatten()

    Repo.query!(
      "CREATE FUNCTION pg_temp.failed_neighbor_revision(bigint) RETURNS bigint LANGUAGE plpgsql STABLE AS $$ BEGIN RAISE EXCEPTION 'Adjacent Target read temporarily unavailable'; END $$"
    )

    Repo.query!("ALTER TABLE targets RENAME TO targets_projection_source")

    fields =
      Enum.map_join(columns, ", ", fn
        "revision" ->
          "CASE WHEN id = '#{context.vm.id}'::uuid THEN pg_temp.failed_neighbor_revision(revision) ELSE revision END AS revision"

        column ->
          "\"#{column}\""
      end)

    Repo.query!("CREATE VIEW targets AS SELECT #{fields} FROM targets_projection_source")

    try do
      assert {:ok, selected} = Targets.get_target(context.linux.id, authorize?: false)
      assert selected.id == context.linux.id
      assert {:error, %Ash.Error.Unknown{} = error} = projection(turn, context)
      assert Exception.message(error) =~ "Adjacent Target read temporarily unavailable"

      assert {:error, %Ash.Error.Unknown{}} =
               Skopos.Cases.Turn.ResolverWorker.perform(%Oban.Job{args: %{"turn_id" => turn.id}})

      assert Cases.list_ai_invocations!(authorize?: false) == []
    after
      Repo.query!("DROP VIEW targets")
      Repo.query!("ALTER TABLE targets_projection_source RENAME TO targets")
      Repo.query!("DROP FUNCTION pg_temp.failed_neighbor_revision(bigint)")
    end

    assert Cases.get_turn!(turn.id, authorize?: false) == before_turn
    assert Cases.get_case!(incident.id, authorize?: false) == before_case
    assert Cases.get_resolution_run!(run.id, authorize?: false) == before_run

    assert :ok =
             Skopos.Cases.Turn.ResolverDelivery.run(turn.id,
               ai_invocation: %{
                 test_pid: self(),
                 respond: fn request ->
                   assert context.vm.id in adjacent_target_ids(request, context.linux.id)

                   {:ok,
                    %AI.ResolverDecision{
                      intent: %AI.Handoff{
                        reason: "Review fixture observations",
                        required_input: "Review"
                      },
                      usage: %AI.Usage{input_tokens: 7, output_tokens: 5}
                    }}
                 end
               }
             )

    assert_receive {:resolve, _, _}

    assert :ok =
             Skopos.Cases.Turn.ResolverWorker.perform(%Oban.Job{args: %{"turn_id" => turn.id}})

    refute_receive {:resolve, _, _}
    assert Cases.get_resolution_run!(run.id, authorize?: false).ai_usage_units == 12
    assert [invocation] = Cases.list_ai_invocations!(authorize?: false)
    assert invocation.status == :completed
  end

  @tag relationship_read_fault: true
  test "a saved related Target decision retries unreadable metadata without a new investigation",
       context do
    {incident, run, evidence, turn} = case_with_evidence!("relationship-read", context)
    source = complete_traversal!(turn, context.runs_on, context.vm, evidence)
    before_case = Cases.get_case!(incident.id, authorize?: false)
    before_run = Cases.get_resolution_run!(run.id, authorize?: false)
    before_turn = Cases.get_turn!(source.id, authorize?: false)
    before_evidence = Cases.list_evidence!(actor: context.admin)
    before_turns = Cases.list_turns!(actor: context.admin)
    before_events = Cases.list_case_events!(actor: context.admin)
    job = %Oban.Job{args: %{"turn_id" => source.id}}
    Repo.query!("ALTER TABLE relationships RENAME COLUMN facts TO unavailable_facts")

    try do
      assert {:error, _error} = Cases.route_related_target(source.id, authorize?: false)
      assert {:error, _error} = Skopos.Cases.Case.DecisionRouteWorker.perform(job)
    after
      Repo.query!("ALTER TABLE relationships RENAME COLUMN unavailable_facts TO facts")
    end

    assert Cases.get_case!(incident.id, authorize?: false) == before_case
    assert Cases.get_resolution_run!(run.id, authorize?: false) == before_run
    assert Cases.get_turn!(source.id, authorize?: false) == before_turn
    assert Cases.list_evidence!(actor: context.admin) == before_evidence
    assert Cases.list_turns!(actor: context.admin) == before_turns
    assert Cases.list_case_events!(actor: context.admin) == before_events
    assert Cases.list_ai_invocations!(authorize?: false) == []
    assert :ok = Skopos.Cases.Case.DecisionRouteWorker.perform(job)
    assert :ok = Skopos.Cases.Case.DecisionRouteWorker.perform(job)
    assert Cases.get_case!(incident.id, authorize?: false).selected_target_id == context.vm.id
    after_run = Cases.get_resolution_run!(run.id, authorize?: false)
    assert after_run.related_target_count == before_run.related_target_count + 1
    assert after_run.turn_count == before_run.turn_count + 1
    assert after_run.ai_usage_units == before_run.ai_usage_units
    assert length(Cases.list_turns!(actor: context.admin)) == length(before_turns) + 1
    assert Cases.list_evidence!(actor: context.admin) == before_evidence
  end

  test "Resolver traverses evidence-selected layers without family branches or inherited access",
       context do
    {incident, run, evidence, first_turn} = case_with_evidence!("layered", context)

    assert {:ok, request, _context} = projection(first_turn, context)

    assert adjacent_target_ids(request, context.linux.id) ==
             MapSet.new([context.vm.id, context.kubernetes.id, context.switch.id])

    assert Enum.map(request.observation_tools, & &1.access_method_id) == [
             access_method_id!(context.linux.id)
           ]

    vm_source = complete_traversal!(first_turn, context.runs_on, context.vm, evidence)
    vm_turn = route_traversal!(vm_source)

    assert route_traversal!(vm_source).id == vm_turn.id
    assert vm_turn.intent["evidence_ids"] == [evidence.id]
    assert vm_turn.intent["reason"] == "The current evidence implicates the adjacent layer"

    assert Cases.get_case!(incident.id, authorize?: false).selected_target_id == context.vm.id

    assert Cases.get_case!(incident.id, authorize?: false).pending_intent == %{
             "action" => "resolve_turn",
             "turn_id" => vm_turn.id,
             "source_turn_id" => vm_source.id
           }

    assert {:ok, vm_request, _context} = projection(vm_turn, context)

    assert adjacent_target_ids(vm_request, context.vm.id) ==
             MapSet.new([context.linux.id, context.bmc.id])

    assert traversable_target_ids(vm_request, context.vm.id) == MapSet.new([context.bmc.id])

    assert Enum.map(vm_request.observation_tools, & &1.access_method_id) == [
             access_method_id!(context.vm.id)
           ]

    bmc_turn =
      vm_turn
      |> complete_traversal!(context.managed_by, context.bmc, evidence)
      |> route_traversal!()

    selected = Cases.get_case!(incident.id, authorize?: false)
    assert selected.selected_target_id == context.bmc.id
    assert selected.selected_target_revision == context.bmc.revision

    assert {:ok, bmc_request, _context} = projection(bmc_turn, context)
    assert adjacent_target_ids(bmc_request, context.bmc.id) == MapSet.new([context.vm.id])
    assert traversable_target_ids(bmc_request, context.bmc.id) == MapSet.new()

    assert Enum.map(bmc_request.observation_tools, & &1.access_method_id) == [
             access_method_id!(context.bmc.id)
           ]

    refreshed_run = Cases.get_resolution_run!(run.id, authorize?: false)
    assert refreshed_run.related_target_count == 2

    traversal_events =
      Cases.list_case_events!(actor: context.admin)
      |> Enum.filter(&(&1.event_type == "related_target_traversed"))

    assert Enum.map(traversal_events, & &1.data["relationship_revision"]) == [1, 1]

    assert Enum.map(traversal_events, & &1.data["next_target_id"]) == [
             context.vm.id,
             context.bmc.id
           ]
  end

  test "an entered relationship requires Target evidence before it can be revisited",
       context do
    {cycle_case, cycle_run, cycle_evidence, cycle_first_turn} =
      case_with_evidence!("cycle", context)

    cycle_vm_turn =
      cycle_first_turn
      |> complete_traversal!(context.runs_on, context.vm, cycle_evidence)
      |> route_traversal!()

    cycle_source =
      complete_traversal!(cycle_vm_turn, context.runs_on, context.linux, cycle_evidence)

    rejected_turn = route_traversal!(cycle_source)
    assert rejected_turn.status == :started

    assert Cases.get_case!(cycle_case.id, authorize?: false).selected_target_id ==
             context.vm.id

    assert Cases.get_resolution_run!(cycle_run.id, authorize?: false).related_target_count == 1

    assert evidence_for_source_turn!(cycle_source.id, context.admin).content["message"] ==
             "Reassess the selected Target before returning through the same relationship"

    assert {:ok, rejected_request, _context} = projection(rejected_turn, context)

    assert adjacent_target_ids(rejected_request, context.vm.id) ==
             MapSet.new([context.linux.id, context.bmc.id])

    assert traversable_target_ids(rejected_request, context.vm.id) ==
             MapSet.new([context.bmc.id])

    {_observed_case, _observed_run, _observed_evidence, observed_turn} =
      case_with_evidence!(
        "cycle-after-observation",
        context,
        context.vm,
        %{"source" => "target_result"}
      )

    assert {:ok, observed_request, _context} = projection(observed_turn, context)

    assert adjacent_target_ids(observed_request, context.vm.id) ==
             MapSet.new([context.linux.id, context.bmc.id])

    {observed_case, observed_run, observed_evidence, observed_after_traversal} =
      case_with_evidence!(
        "cycle-after-entered-observation",
        context,
        context.vm,
        %{"source" => "target_result", "prior_relationship_id" => context.runs_on.id}
      )

    assert {:ok, observed_after_traversal_request, _context} =
             projection(observed_after_traversal, context)

    assert adjacent_target_ids(observed_after_traversal_request, context.vm.id) ==
             MapSet.new([context.linux.id, context.bmc.id])

    assert traversable_target_ids(observed_after_traversal_request, context.vm.id) ==
             MapSet.new([context.bmc.id])

    reverse_source =
      complete_traversal!(
        observed_after_traversal,
        context.runs_on,
        context.linux,
        observed_evidence
      )

    assert %{status: :started} = route_traversal!(reverse_source)

    assert Cases.get_case!(observed_case.id, authorize?: false).selected_target_id ==
             context.vm.id

    assert Cases.get_resolution_run!(observed_run.id, authorize?: false).related_target_count == 0

    configure_limits!(context.admin, 1)
    {incident, run, evidence, first_turn} = case_with_evidence!("bounded", context)

    vm_turn =
      first_turn
      |> complete_traversal!(context.runs_on, context.vm, evidence)
      |> route_traversal!()

    bmc_source = complete_traversal!(vm_turn, context.managed_by, context.bmc, evidence)
    assert {:ok, exhausted} = Cases.route_related_target(bmc_source.id, authorize?: false)
    assert exhausted.status == :exhausted

    stopped_case = Cases.get_case!(incident.id, authorize?: false)
    assert stopped_case.status == :needs_attention
    assert stopped_case.stop_reason == "Related Target limit exhausted"
    assert stopped_case.selected_target_id == context.vm.id
    assert Cases.get_resolution_run!(run.id, authorize?: false).related_target_count == 1
  end

  @tag signal_citation_read_fault: true
  test "a resumed run can traverse with the Case's current Signal evidence", context do
    signal_provider =
      Providers.create_provider!(
        "resumed-relation-monitor",
        :signal,
        "fixture-signal",
        %{"source" => "relation-monitor"},
        %{"secret" => "relation-monitor-secret"},
        actor: context.admin
      )
      |> then(&Providers.check_provider!(&1.id, 1, %{}, actor: context.admin))
      |> then(&Providers.enable_provider!(&1, 1, actor: context.admin))

    Targets.create_external_identity!(
      context.linux.id,
      "relation-monitor",
      "hostname",
      context.linux.name,
      actor: context.admin
    )

    received_at = DateTime.utc_now()

    Signals.ingest_signal!(
      signal_provider.id,
      signal_provider.revision,
      %Signal.Envelope{body: "resumed-relation", headers: %{}, received_at: received_at},
      %{
        authenticate: fn state, _envelope ->
          {:ok,
           %Signal.AuthenticatedReceipt{receipt_id: "resumed-relation", source: state.source}}
        end,
        normalize: fn _state, _envelope, _receipt ->
          {:ok,
           [
             %Signal.Event{
               receipt_id: "resumed-relation",
               event_key: "linux-service-unavailable",
               state: :firing,
               occurred_at: received_at,
               target_ref: %{kind: :hostname, value: context.linux.name},
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

    [incident] = Cases.list_cases!(actor: context.admin)

    prior_run = Cases.active_resolution_run!(incident.id, authorize?: false)

    [signal] = Cases.signal_context_evidence!(incident.id, authorize?: false)

    attention =
      Cases.require_case_attention!(
        incident.id,
        incident.revision,
        prior_run.id,
        prior_run.revision,
        "resumed-relation-attention",
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
        "Continue autonomous resolution",
        actor: context.operator
      )

    resumed_turn =
      Cases.list_turns!(actor: context.admin)
      |> Enum.find(&(&1.resolution_run_id == resumed_run.id))

    source = complete_traversal!(resumed_turn, context.runs_on, context.vm, signal)
    before_case = Cases.get_case!(incident.id, authorize?: false)
    before_run = Cases.get_resolution_run!(resumed_run.id, authorize?: false)
    before_evidence = Cases.list_evidence!(actor: context.admin)
    before_turns = Cases.list_turns!(actor: context.admin)

    Repo.query!(
      "ALTER TABLE case_condition_memberships RENAME COLUMN condition_id TO unavailable_condition_id"
    )

    try do
      assert {:error, _error} = Cases.route_related_target(source.id, authorize?: false)
    after
      Repo.query!(
        "ALTER TABLE case_condition_memberships RENAME COLUMN unavailable_condition_id TO condition_id"
      )
    end

    assert Cases.get_case!(incident.id, authorize?: false) == before_case
    assert Cases.get_resolution_run!(resumed_run.id, authorize?: false) == before_run
    assert Cases.list_evidence!(actor: context.admin) == before_evidence
    assert Cases.list_turns!(actor: context.admin) == before_turns
    next_turn = route_traversal!(source)

    selected = Cases.get_case!(incident.id, authorize?: false)
    assert selected.status == :running
    assert selected.selected_target_id == context.vm.id
    assert next_turn.resolution_run_id == resumed_run.id
    refute evidence_for_source_turn!(resumed_turn.id, context.admin)
  end

  test "stale relationships, changed authority, and missing Access Methods become Evidence",
       context do
    {stale_case, stale_run, stale_evidence, stale_turn} =
      case_with_evidence!("stale-edge", context)

    stale_source =
      complete_traversal!(stale_turn, context.runs_on, context.vm, stale_evidence)

    Targets.update_relationship!(
      context.runs_on,
      context.runs_on.revision,
      %{facts: %{"rack" => "r2"}},
      actor: context.admin
    )

    assert {:ok, _next} = Cases.route_related_target(stale_source.id, authorize?: false)
    stale_failure = evidence_for_source_turn!(stale_source.id, context.admin)
    assert stale_failure.content["category"] == "stale_relationship"

    assert {:ok, replayed_stale} =
             Cases.route_related_target(stale_source.id, authorize?: false)

    assert replayed_stale.status == :duplicate

    assert Enum.count(
             Cases.list_evidence!(actor: context.admin),
             &(&1.turn_id == stale_source.id and &1.kind == "relationship_traversal_error")
           ) == 1

    assert Cases.get_case!(stale_case.id, authorize?: false).selected_target_id ==
             context.linux.id

    assert Cases.get_resolution_run!(stale_run.id, authorize?: false).related_target_count == 0

    denied_relationship =
      relationship!(context.admin, context.linux, context.vm, "supported_by")

    {denied_case, denied_run, denied_evidence, denied_turn} =
      case_with_evidence!("denied-owner", context)

    denied_source =
      complete_traversal!(denied_turn, denied_relationship, context.vm, denied_evidence)

    Accounts.change_role!(context.operator, :viewer, actor: context.admin)

    assert {:ok, _next} = Cases.route_related_target(denied_source.id, authorize?: false)
    denied_failure = evidence_for_source_turn!(denied_source.id, context.admin)
    assert denied_failure.content["category"] == "denied"

    assert Cases.get_case!(denied_case.id, authorize?: false).selected_target_id ==
             context.linux.id

    assert Cases.get_resolution_run!(denied_run.id, authorize?: false).related_target_count == 0

    Accounts.change_role!(
      Accounts.get_user!(context.operator.id, authorize?: false),
      :operator,
      actor: context.admin
    )

    unavailable =
      Targets.create_target!(
        "unavailable-01",
        "host",
        "custom-os",
        %{},
        nil,
        actor: context.admin
      )

    relationship = relationship!(context.admin, context.linux, unavailable, "peers_with")
    {incident, run, evidence, turn} = case_with_evidence!("missing-method", context)
    source_turn = complete_traversal!(turn, relationship, unavailable, evidence)

    assert {:ok, _next} = Cases.route_related_target(source_turn.id, authorize?: false)
    failure = evidence_for_source_turn!(source_turn.id, context.admin)
    assert failure.content["category"] == "unavailable"
    assert failure.content["message"] =~ "no available Access Method"
    assert Cases.get_case!(incident.id, authorize?: false).selected_target_id == context.linux.id
    assert Cases.get_resolution_run!(run.id, authorize?: false).related_target_count == 0
  end

  defp case_with_evidence!(source_ref, context),
    do:
      case_with_evidence!(source_ref, context, context.linux, %{
        "objective" => "Find and resolve the I/O fault"
      })

  defp case_with_evidence!(source_ref, context, target, turn_intent) do
    incident =
      Cases.open_case!(
        :manual,
        "test",
        source_ref,
        "Investigate Linux I/O errors",
        :critical,
        %{
          "observed_problem" => "I/O errors are increasing",
          "desired_outcome" => "I/O errors have stopped"
        },
        target.id,
        :en,
        actor: context.operator
      )

    run = Cases.active_resolution_run!(incident.id, authorize?: false)

    evidence =
      Cases.append_evidence!(
        incident.id,
        run.id,
        nil,
        "signal-#{source_ref}",
        "signal",
        "zabbix",
        source_ref,
        %{"target_id" => target.id, "message" => "I/O errors are increasing"},
        DateTime.utc_now(),
        authorize?: false
      )

    turn =
      Cases.start_turn!(
        incident.id,
        run.id,
        "start-#{source_ref}",
        turn_intent,
        %{"action" => "continue"},
        "Review Resolver limits",
        authorize?: false
      ).value

    {incident, run, evidence, turn}
  end

  defp complete_traversal!(turn, relationship, next_target, evidence) do
    incident = Cases.get_case!(turn.case_id, authorize?: false)

    result =
      Cases.complete_turn!(
        turn.id,
        turn.revision,
        %{
          "outcome" => "decision",
          "intent" => traversal_intent(relationship, incident, next_target, evidence),
          "usage" => %{"input_tokens" => 1, "output_tokens" => 1}
        },
        :hypothesis,
        %{"action" => "route_resolver_decision", "turn_id" => turn.id},
        "Review the Resolver decision",
        authorize?: false
      )

    result.value
  end

  defp traversal_intent(relationship, incident, next_target, evidence) do
    source = Targets.get_target!(relationship.source_target_id, authorize?: false)
    destination = Targets.get_target!(relationship.destination_target_id, authorize?: false)

    %{
      "type" => "target_traversal",
      "relationship_id" => relationship.id,
      "relationship_revision" => relationship.revision,
      "next_target_id" => next_target.id,
      "next_target_revision" => next_target.revision,
      "evidence_ids" => [evidence.id],
      "reason" => "The current evidence implicates the adjacent layer",
      "relationship" => %{
        "id" => relationship.id,
        "revision" => relationship.revision,
        "source_target_id" => source.id,
        "source_target_revision" => source.revision,
        "destination_target_id" => destination.id,
        "destination_target_revision" => destination.revision,
        "kind" => relationship.kind,
        "selected_target_id" => incident.selected_target_id
      }
    }
  end

  defp route_traversal!(source_turn) do
    Cases.route_related_target!(source_turn.id, authorize?: false).value
  end

  defp projection(turn, _context) do
    ResolverProjection.build(turn.id, selection())
  end

  defp adjacent_target_ids(request, current_target_id) do
    request.target_relations
    |> Enum.map(fn relationship ->
      if relationship.source_target.id == current_target_id,
        do: relationship.destination_target.id,
        else: relationship.source_target.id
    end)
    |> MapSet.new()
  end

  defp traversable_target_ids(request, current_target_id) do
    request.target_relations
    |> Enum.filter(&(&1.id in request.traversable_relation_ids))
    |> Enum.map(fn relationship ->
      if relationship.source_target.id == current_target_id,
        do: relationship.destination_target.id,
        else: relationship.source_target.id
    end)
    |> MapSet.new()
  end

  defp access_method_id!(target_id) do
    [method] = Targets.available_access_methods_for_target!(target_id, authorize?: false)
    method.id
  end

  defp evidence_for_source_turn!(turn_id, actor) do
    Cases.list_evidence!(actor: actor)
    |> Enum.find(&(&1.turn_id == turn_id and &1.kind == "relationship_traversal_error"))
  end

  defp target!(admin, provider, name, kind, type_id, method_name) do
    target = Targets.create_target!(name, kind, type_id, %{}, nil, actor: admin)

    Targets.create_access_method!(
      target.id,
      provider.id,
      method_name,
      method_name,
      "fixture://#{name}",
      provider.revision,
      10,
      ["observe.system"],
      actor: admin
    )
    |> then(&Targets.check_access_method!(&1.id, &1.revision, %{}, actor: admin))

    target
  end

  defp relationship!(admin, source, destination, kind) do
    Targets.create_relationship!(source.id, destination.id, kind, %{}, nil, actor: admin)
  end

  defp selection do
    %AI.Selection{
      role: :resolver,
      provider_id: Ecto.UUID.generate(),
      provider_revision: 1,
      source: :assignment
    }
  end

  defp configure_limits!(admin, max_related_targets) do
    current = Cases.current_authority_setting!(actor: admin)

    Cases.configure_authority_setting!(
      current.setting_revision,
      :auto,
      true,
      600,
      20,
      20,
      5,
      max_related_targets,
      100_000,
      10,
      "configure related Target tests",
      actor: admin
    )
  end
end
