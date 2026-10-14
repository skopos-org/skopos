defmodule Skopos.CaseLifecycleTest do
  use Skopos.DataCase, async: false

  alias Skopos.{Accounts, Cases, Targets}
  alias Skopos.Cases.Case.Symptom, as: CaseSymptom

  @password "correct horse battery staple"

  setup do
    admin = Accounts.bootstrap!("case-admin@example.com", @password, @password, authorize?: true)

    operator =
      Accounts.create_user!("case-operator@example.com", @password, :operator, actor: admin)

    next_operator =
      Accounts.create_user!("case-next-operator@example.com", @password, :operator, actor: admin)

    viewer = Accounts.create_user!("case-viewer@example.com", @password, :viewer, actor: admin)

    %{admin: admin, operator: operator, next_operator: next_operator, viewer: viewer}
  end

  test "manual opening cannot persist a Case without its initial dispatch job", context do
    open = fn ->
      Cases.open_case(
        :manual,
        "web",
        "missing-initial-dispatch",
        "Inspect the current Target",
        :warning,
        %{"desired_outcome" => "Target responds as expected"},
        nil,
        :en,
        actor: context.operator
      )
    end

    Repo.query!("""
    CREATE FUNCTION pg_temp.reject_initial_dispatch() RETURNS trigger LANGUAGE plpgsql AS $$
    BEGIN
      IF NEW.worker = 'Skopos.Cases.CaseDispatch.Worker' THEN RETURN NULL; END IF;
      RETURN NEW;
    END;
    $$;
    """)

    Repo.query!("""
    CREATE TRIGGER reject_initial_dispatch BEFORE INSERT ON oban_jobs
    FOR EACH ROW EXECUTE FUNCTION pg_temp.reject_initial_dispatch()
    """)

    assert {:error, _error} = open.()
    assert Cases.list_cases!(actor: context.viewer) == []
    assert Cases.list_resolution_runs!(actor: context.viewer) == []
    assert Cases.list_case_events!(actor: context.viewer) == []

    Repo.query!("DROP TRIGGER reject_initial_dispatch ON oban_jobs")

    assert {:ok, incident} = open.()
    assert {:ok, replayed} = open.()
    assert replayed.id == incident.id
    assert Cases.case_dispatch!(incident.id, authorize?: false).state == :collecting

    assert [job] =
             Repo.all(Oban.Job)
             |> Enum.filter(&(&1.worker == "Skopos.Cases.CaseDispatch.Worker"))

    assert job.args == %{"case_id" => incident.id}
    assert is_integer(job.id)
    assert length(Cases.list_cases!(actor: context.viewer)) == 1
  end

  test "Case resolution cannot be repeated after the Case is terminal", context do
    incident = open_case!(:manual, "web", "named-transition", context.operator)

    resolved =
      Cases.record_case_resolution!(incident, incident.revision, DateTime.utc_now(),
        authorize?: false
      )

    assert resolved.status == :resolved

    assert {:error, _error} =
             Cases.record_case_resolution(resolved, resolved.revision, DateTime.utc_now(),
               authorize?: false
             )
  end

  test "owner and Target state actions reject stale or terminal Cases", context do
    incident = open_case!(:manual, "web", "state-action-guards", context.operator)

    target =
      Targets.create_target!("state-guard-host", "host", "linux", %{}, nil, actor: context.admin)

    assert {:error, _error} =
             Cases.record_case_owner(incident, incident.revision + 1, context.next_operator.id,
               authorize?: false
             )

    owned =
      Cases.record_case_owner!(incident, incident.revision, context.next_operator.id,
        authorize?: false
      )

    assert owned.current_owner_id == context.next_operator.id

    selected =
      Cases.record_case_selected_target!(owned, owned.revision, target.id, target.revision,
        authorize?: false
      )

    assert selected.selected_target_id == target.id
    assert selected.selected_target_revision == target.revision

    cancelled = Cases.record_case_cancellation!(selected, selected.revision, authorize?: false)

    assert {:error, _error} =
             Cases.record_case_selected_target(
               cancelled,
               cancelled.revision,
               target.id,
               target.revision,
               authorize?: false
             )
  end

  test "pending intent requires a running Case and its named transition", context do
    incident = open_case!(:manual, "web", "pending-transition", context.operator)
    pending = %{"action" => "resolve_turn", "turn_id" => Ecto.UUID.generate()}

    queued =
      Cases.record_case_pending_intent!(incident, incident.revision, pending, authorize?: false)

    assert queued.pending_intent == pending
    assert queued.stop_reason == nil
    assert queued.required_human_input == nil

    cancelled = Cases.record_case_cancellation!(queued, queued.revision, authorize?: false)

    assert {:error, _error} =
             Cases.record_case_pending_intent(cancelled, cancelled.revision, pending,
               authorize?: false
             )
  end

  test "manual and audit opening reject an absent or blank desired outcome before persistence",
       context do
    for kind <- [:manual, :audit], value <- [nil, "  "] do
      initial_context = if value, do: %{"desired_outcome" => value}, else: %{}

      assert {:error, %Ash.Error.Invalid{}} =
               Cases.open_case(
                 kind,
                 "test",
                 "missing-desired-#{kind}-#{inspect(value)}",
                 "Check target",
                 :warning,
                 initial_context,
                 nil,
                 :en,
                 actor: context.operator
               )
    end

    assert Cases.list_cases!(actor: context.admin) == []
    assert Cases.list_turns!(actor: context.admin) == []
  end

  test "manual and Audit Cases copy one exact standing revision without requiring a Target",
       context do
    target = Targets.create_target!("linux-01", "host", "linux", %{}, nil, actor: context.admin)

    setting =
      configure_authority!(context.admin, %{
        authority_mode: :auto,
        signal_automation_enabled: true,
        max_elapsed_seconds: 7_200,
        max_resolver_turns: 40,
        reason: "enable Case acceptance"
      })

    manual =
      open_case!(:manual, "web", "manual-1", context.operator, target.id)

    audit = open_case!(:audit, "schedule", "audit-1", context.operator)

    for incident <- [manual, audit] do
      assert incident.authority_setting_id == setting.id
      assert incident.authority_setting_revision == 2
      assert incident.authority_mode == :auto
      assert incident.max_elapsed_seconds == 7_200
      assert incident.max_resolver_turns == 40

      run = Cases.active_resolution_run!(incident.id, authorize?: false)
      assert run.generation == 1
      assert run.authority_mode == :auto
      assert run.max_elapsed_seconds == 7_200
      assert run.status == :running
    end

    assert manual.initial_target_id == target.id
    assert is_nil(audit.initial_target_id)

    updated_setting =
      configure_authority!(context.admin, %{
        authority_mode: :full_access,
        signal_automation_enabled: true,
        max_elapsed_seconds: 10_800,
        max_resolver_turns: 50,
        reason: "future Cases only"
      })

    reloaded = Cases.get_case!(manual.id, actor: context.viewer)
    assert CaseSymptom.current(reloaded) == CaseSymptom.current(manual)
    assert CaseSymptom.current(reloaded).desired_outcome == "Target responds as expected"
    assert reloaded.authority_setting_revision == 2
    assert reloaded.authority_mode == :auto
    assert reloaded.max_elapsed_seconds == 7_200

    later = open_case!(:manual, "cli", "manual-2", context.operator)
    assert later.authority_setting_id == updated_setting.id
    assert later.authority_setting_revision == 3
    assert later.authority_mode == :full_access
  end

  test "Case opening and a concurrent standing-setting revision produce one complete snapshot",
       context do
    current = Cases.current_authority_setting!(actor: context.admin)

    configure = fn ->
      Cases.configure_authority_setting(
        current.setting_revision,
        :auto,
        true,
        current.max_elapsed_seconds + 60,
        current.max_resolver_turns + 1,
        current.max_target_requests,
        current.max_effects,
        current.max_related_targets,
        current.max_ai_usage_units,
        current.max_no_progress_turns,
        "concurrent setting revision",
        actor: context.admin
      )
    end

    open = fn ->
      Cases.open_case(
        :manual,
        "web",
        "concurrent-open",
        "Concurrent open",
        :warning,
        %{"desired_outcome" => "Target responds as expected"},
        nil,
        :en,
        actor: context.operator
      )
    end

    assert [{:ok, _setting}, {:ok, incident}] =
             [Task.async(configure), Task.async(open)] |> Task.await_many()

    snapshot =
      Cases.list_authority_settings!(actor: context.viewer)
      |> Enum.find(&(&1.id == incident.authority_setting_id))

    assert incident.authority_setting_revision == snapshot.setting_revision
    assert incident.authority_mode == snapshot.authority_mode
    assert incident.max_elapsed_seconds == snapshot.max_elapsed_seconds
    assert incident.max_resolver_turns == snapshot.max_resolver_turns

    run = Cases.active_resolution_run!(incident.id, authorize?: false)
    assert run.authority_mode == incident.authority_mode
    assert run.max_elapsed_seconds == incident.max_elapsed_seconds
  end

  test "claim, handoff and cancellation are revisioned and retryable", context do
    incident = open_case!(:manual, "web", "manual-claim", context.operator)

    claimed = Cases.claim_case!(incident.id, incident.revision, actor: context.operator)
    assert claimed.current_owner_id == context.operator.id
    assert claimed.revision == 2

    retried_claim = Cases.claim_case!(incident.id, incident.revision, actor: context.operator)
    assert retried_claim.id == claimed.id
    assert retried_claim.revision == claimed.revision

    handed_off =
      Cases.handoff_case!(claimed.id, claimed.revision, context.next_operator.id,
        actor: context.operator
      )

    assert handed_off.current_owner_id == context.next_operator.id
    assert handed_off.revision == 3

    assert {:error, _error} =
             Cases.handoff_case(
               handed_off.id,
               handed_off.revision,
               context.viewer.id,
               actor: context.operator
             )

    cancelled =
      Cases.request_case_cancellation!(handed_off.id, handed_off.revision,
        actor: context.next_operator
      )

    assert cancelled.cancel_requested
    assert cancelled.status == :cancelled
    assert cancelled.stop_reason == "Resolution cancelled by an operator"
    assert cancelled.revision == 4

    cancelled_run = Cases.list_resolution_runs!(actor: context.viewer) |> hd()
    refute cancelled_run.active
    assert cancelled_run.status == :cancelled
    assert %DateTime{} = cancelled_run.ended_at

    retried_cancel =
      Cases.request_case_cancellation!(handed_off.id, handed_off.revision,
        actor: context.next_operator
      )

    assert retried_cancel.revision == cancelled.revision

    assert Enum.map(Cases.list_case_events!(actor: context.viewer), & &1.event_type) == [
             "case_opened",
             "case_claimed",
             "case_handed_off",
             "case_cancelled"
           ]
  end

  test "attention and concurrent resume preserve history and create one new generation",
       context do
    operator =
      Accounts.change_preferred_language!(context.operator, :ja, actor: context.operator)

    incident =
      open_case!(:manual, "cli", "manual-resume", operator)

    assert incident.report_language == :ja
    first_run = Cases.active_resolution_run!(incident.id, authorize?: false)

    attention =
      Cases.require_case_attention!(
        incident.id,
        incident.revision,
        first_run.id,
        first_run.revision,
        "limit:turns:1",
        "Resolver turn limit exhausted",
        %{"kind" => "observe", "target" => "linux-01"},
        "Extend limits or investigate manually",
        authorize?: false
      )

    assert attention.status == :needs_attention
    assert attention.stop_reason == "Resolver turn limit exhausted"
    assert attention.revision == 2

    paused_run = Cases.active_resolution_run!(incident.id, authorize?: false)
    assert paused_run.id == first_run.id
    assert paused_run.status == :needs_attention
    assert paused_run.revision == 2

    resume = fn ->
      Cases.resume_case(
        attention.id,
        attention.revision,
        paused_run.id,
        paused_run.revision,
        :auto,
        paused_run.max_elapsed_seconds + 60,
        paused_run.max_resolver_turns + 1,
        paused_run.max_target_requests,
        paused_run.max_effects,
        paused_run.max_related_targets,
        paused_run.max_ai_usage_units,
        paused_run.max_no_progress_turns,
        "extend one turn",
        actor: context.operator
      )
    end

    results = [Task.async(resume), Task.async(resume)] |> Task.await_many()
    assert [{:ok, resumed_a}, {:ok, resumed_b}] = results
    assert resumed_a.id == resumed_b.id
    assert resumed_a.generation == 2
    assert resumed_a.active
    assert resumed_a.authority_mode == :auto
    assert resumed_a.resumed_by_id == context.operator.id

    assert [resumed_turn] =
             Cases.list_turns!(actor: context.viewer)
             |> Enum.filter(&(&1.resolution_run_id == resumed_a.id))

    assert resumed_turn.status == :started
    assert resumed_turn.intent == %{"objective" => "Continue resolution after operator resume"}

    old_run = Cases.get_resolution_run!(first_run.id, actor: context.viewer)
    refute old_run.active
    assert old_run.status == :superseded

    reloaded = Cases.get_case!(incident.id, actor: context.viewer)
    assert reloaded.status == :running
    assert reloaded.revision == 3
    assert reloaded.authority_setting_revision == incident.authority_setting_revision
    assert reloaded.authority_mode == resumed_a.authority_mode
    assert reloaded.max_elapsed_seconds == resumed_a.max_elapsed_seconds
    assert reloaded.max_resolver_turns == resumed_a.max_resolver_turns
    assert reloaded.report_language == :ja

    runs = Cases.list_resolution_runs!(actor: context.viewer) |> Enum.sort_by(& &1.generation)
    assert Enum.map(runs, & &1.generation) == [1, 2]
    assert Enum.count(runs, & &1.active) == 1

    resumed_event =
      Cases.list_case_events!(actor: context.viewer)
      |> Enum.find(&(&1.event_type == "case_resumed"))

    assert resumed_event.data["prior_generation"] == 1
    assert resumed_event.data["new_generation"] == 2
    assert resumed_event.data["reason"] == "extend one turn"
  end

  test "cancelling an attention Case retires its active run", context do
    incident = open_case!(:manual, "web", "cancel-attention", context.operator)
    run = Cases.active_resolution_run!(incident.id, authorize?: false)

    attention =
      Cases.require_case_attention!(
        incident.id,
        incident.revision,
        run.id,
        run.revision,
        "cancel-attention:pause",
        "Operator review is required",
        %{"action" => "provide_human_input"},
        "Review or cancel",
        authorize?: false
      )

    cancelled =
      Cases.request_case_cancellation!(attention.id, attention.revision, actor: context.operator)

    assert cancelled.status == :cancelled
    assert cancelled.cancel_requested
    assert cancelled.required_human_input == nil
    assert cancelled.pending_intent == %{}

    retired = Cases.get_resolution_run!(run.id, actor: context.viewer)
    refute retired.active
    assert retired.status == :cancelled
    assert %DateTime{} = retired.ended_at

    assert {:error, _error} = Cases.active_resolution_run(incident.id, authorize?: false)
  end

  test "viewer mutation and direct internal writes are forbidden", context do
    assert {:error, %Ash.Error.Forbidden{}} =
             Cases.open_case(
               :manual,
               "web",
               "forbidden",
               "Forbidden",
               :warning,
               %{"desired_outcome" => "Target responds as expected"},
               nil,
               :en,
               actor: context.viewer
             )

    assert {:error, %Ash.Error.Forbidden{}} =
             Cases.create_case_event_record(
               %{
                 case_id: Ash.UUID.generate(),
                 event_type: "bypass",
                 idempotency_key: "bypass",
                 data: %{}
               },
               actor: context.admin
             )
  end

  test "resume cannot reduce a prior run limit", context do
    incident =
      open_case!(:manual, "cli", "manual-no-reduction", context.operator)

    run = Cases.active_resolution_run!(incident.id, authorize?: false)

    attention =
      Cases.require_case_attention!(
        incident.id,
        incident.revision,
        run.id,
        run.revision,
        "limit:manual:no-reduction",
        "Manual handoff",
        %{"kind" => "observe"},
        "Review limits",
        authorize?: false
      )

    paused = Cases.active_resolution_run!(incident.id, authorize?: false)

    assert {:error, _error} =
             Cases.resume_case(
               attention.id,
               attention.revision,
               paused.id,
               paused.revision,
               paused.authority_mode,
               paused.max_elapsed_seconds,
               paused.max_resolver_turns - 1,
               paused.max_target_requests,
               paused.max_effects,
               paused.max_related_targets,
               paused.max_ai_usage_units,
               paused.max_no_progress_turns,
               "invalid reduction",
               actor: context.operator
             )

    assert Cases.active_resolution_run!(incident.id, authorize?: false).id == paused.id
    assert length(Cases.list_resolution_runs!(actor: context.viewer)) == 1
  end

  defp open_case!(
         kind,
         source,
         source_ref,
         actor,
         target_id \\ nil
       ) do
    Cases.open_case!(
      kind,
      source,
      source_ref,
      "#{kind} Case #{source_ref}",
      :warning,
      %{"source_ref" => source_ref, "desired_outcome" => "Target responds as expected"},
      target_id,
      :en,
      actor: actor,
      authorize?: not is_nil(actor)
    )
  end

  defp configure_authority!(actor, overrides) do
    current = Cases.current_authority_setting!(actor: actor)

    values =
      %{
        authority_mode: current.authority_mode,
        signal_automation_enabled: current.signal_automation_enabled,
        max_elapsed_seconds: current.max_elapsed_seconds,
        max_resolver_turns: current.max_resolver_turns,
        max_target_requests: current.max_target_requests,
        max_effects: current.max_effects,
        max_related_targets: current.max_related_targets,
        max_ai_usage_units: current.max_ai_usage_units,
        max_no_progress_turns: current.max_no_progress_turns,
        reason: "configure Case tests"
      }
      |> Map.merge(overrides)

    Cases.configure_authority_setting!(
      current.setting_revision,
      values.authority_mode,
      values.signal_automation_enabled,
      values.max_elapsed_seconds,
      values.max_resolver_turns,
      values.max_target_requests,
      values.max_effects,
      values.max_related_targets,
      values.max_ai_usage_units,
      values.max_no_progress_turns,
      values.reason,
      actor: actor
    )
  end
end
