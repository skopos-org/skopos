defmodule Skopos.AuditScheduleTest do
  use Skopos.DataCase, async: false

  import Ecto.Query

  alias Skopos.{Accounts, Audits, Cases, Repo, Targets}
  alias Skopos.Audits.{AuditRun, AuditSchedule}
  alias Skopos.Audits.AuditSchedule.Scheduling

  @password "correct horse battery staple"

  setup do
    admin =
      Accounts.bootstrap!("audit-admin@example.com", @password, @password, authorize?: true)

    operator =
      Accounts.create_user!("audit-operator@example.com", @password, :operator, actor: admin)

    viewer = Accounts.create_user!("audit-viewer@example.com", @password, :viewer, actor: admin)

    configure_limits!(admin)

    boundary =
      Targets.create_management_boundary!("audit-dc", "datacenter", %{}, actor: admin)

    target =
      Targets.create_target!("audit-linux", "host", "linux", %{}, boundary.id, actor: admin)

    %{admin: admin, operator: operator, viewer: viewer, boundary: boundary, target: target}
  end

  test "timezone scheduling rejects invalid input and handles DST transitions" do
    before_spring = DateTime.from_naive!(~N[2026-03-28 23:00:00], "Etc/UTC")

    assert {:ok, spring_next} = Scheduling.next_run("0 2 * * *", "Europe/Berlin", before_spring)
    assert spring_next == DateTime.from_naive!(~N[2026-03-30 00:00:00], "Etc/UTC")

    before_fall = DateTime.from_naive!(~N[2026-10-24 23:00:00], "Etc/UTC")
    assert {:ok, fall_next} = Scheduling.next_run("0 2 * * *", "Europe/Berlin", before_fall)
    assert fall_next == DateTime.from_naive!(~N[2026-10-25 00:00:00], "Etc/UTC")

    assert {:error, "Timezone is invalid"} =
             Scheduling.next_run("0 2 * * *", "invalid/timezone", before_fall)

    assert {:error, "Cron expression is invalid"} =
             Scheduling.next_run("not cron", "Etc/UTC", before_fall)

    assert {:error, "Audit schedules do not support @reboot"} =
             Scheduling.next_run("@reboot", "Etc/UTC", before_fall)
  end

  test "an audit schedule cannot persist an empty desired outcome", context do
    assert {:error, %Ash.Error.Invalid{}} =
             Audits.schedule_audit(
               Ash.UUID.generate(),
               "empty-outcome-audit",
               "  ",
               "Etc/UTC",
               "0 * * * *",
               :en,
               [context.target.id],
               nil,
               actor: context.admin
             )

    assert Audits.list_audit_schedules!(actor: context.admin) == []
  end

  test "one due occurrence opens one ordinary Resolver Case despite duplicate wakeups", context do
    schedule = schedule!(context, "explicit-audit", :ja, [context.target.id], nil)

    assert schedule.active
    assert schedule.revision == 1
    assert [%Oban.Job{state: "scheduled"} = wake_job] = jobs_for_schedule(schedule.id)
    assert DateTime.compare(wake_job.scheduled_at, schedule.next_run_at) == :eq

    assert :ok = AuditSchedule.WakeWorker.perform(wake_job)
    advanced = current_schedule(schedule.id, context.viewer)

    assert advanced.revision == 2
    assert DateTime.compare(advanced.next_run_at, schedule.next_run_at) == :gt

    assert :ok = AuditSchedule.WakeWorker.perform(wake_job)

    assert [run] =
             Audits.audit_runs_for_occurrence!(schedule.id, schedule.next_run_at,
               authorize?: false
             )

    assert run.status == :queued
    assert run.target_id == context.target.id
    assert run.target_revision == context.target.revision
    assert one_job_for_run?(run.id)

    run_job = job_for_run(run.id)
    assert :ok = AuditRun.Worker.perform(run_job)

    [completed] =
      Audits.audit_runs_for_occurrence!(schedule.id, schedule.next_run_at, authorize?: false)

    assert completed.status == :case_opened
    assert completed.case_id
    assert completed.case_revision == 1

    incident = Cases.get_case!(completed.case_id, actor: context.viewer)
    assert incident.trigger_kind == :audit
    assert incident.source == "audit-schedule"
    assert incident.source_ref == "audit-run:#{run.id}"
    assert incident.report_language == :ja
    assert incident.selected_target_id == context.target.id
    assert incident.selected_target_revision == context.target.revision
    assert incident.authority_mode == :auto
    assert incident.max_resolver_turns == 5
    assert incident.current_owner_id == context.admin.id
    assert incident.initial_context["desired_outcome"] == "Inspect storage health"

    assert [turn] = Cases.list_turns!(actor: context.viewer)
    assert turn.intent["objective"] == "Inspect storage health"
    assert turn.intent["audit_run_id"] == run.id
    assert one_resolver_job?(turn.id)

    assert {:ok, repeated} = AuditRun.Dispatch.run(run.id)
    assert repeated.id == completed.id
    assert length(Cases.list_cases!(actor: context.viewer)) == 1
    assert length(Cases.list_turns!(actor: context.viewer)) == 1
  end

  test "empty management scope is a visible skipped Run", context do
    empty_boundary =
      Targets.create_management_boundary!("empty-audit-dc", "datacenter", %{},
        actor: context.admin
      )

    schedule = schedule!(context, "empty-scope", :en, [], empty_boundary.id)
    wake!(schedule)

    assert [run] =
             Audits.audit_runs_for_occurrence!(schedule.id, schedule.next_run_at,
               authorize?: false
             )

    assert run.status == :skipped
    assert run.target_id == nil
    assert run.target_key == "scope:#{empty_boundary.id}"
    assert run.reason == "Management boundary has no active Targets"
    assert run.completed_at
    refute one_job_for_run?(run.id)
  end

  test "deactivation and Target revision changes prevent queued Case creation", context do
    cancelled_schedule = schedule!(context, "cancelled-audit", :en, [context.target.id], nil)
    wake!(cancelled_schedule)
    [cancelled_run] = occurrence_runs(cancelled_schedule)

    advanced = current_schedule(cancelled_schedule.id, context.viewer)
    Audits.deactivate_audit_schedule!(advanced, advanced.revision, actor: context.admin)

    assert {:ok, cancelled} = AuditRun.Dispatch.run(cancelled_run.id)
    assert cancelled.status == :cancelled
    assert cancelled.case_id == nil

    changed_schedule = schedule!(context, "changed-target-audit", :en, [context.target.id], nil)
    wake!(changed_schedule)
    [changed_run] = occurrence_runs(changed_schedule)

    Targets.update_target!(
      context.target,
      context.target.revision,
      %{name: "audit-linux-renamed"},
      actor: context.admin
    )

    assert {:ok, skipped} = AuditRun.Dispatch.run(changed_run.id)
    assert skipped.status == :skipped
    assert skipped.reason == "Target changed before Audit Case creation"
    assert Cases.list_cases!(actor: context.viewer) == []
  end

  test "a persisted running marker resumes idempotently after interruption", context do
    schedule = schedule!(context, "resumed-audit", :en, [context.target.id], nil)
    wake!(schedule)
    [run] = occurrence_runs(schedule)

    assert {:ok, %{state: :claimed, run: running}} =
             Audits.claim_audit_run(run.id, authorize?: false)

    assert running.status == :running
    assert running.started_at

    assert {:ok, completed} = AuditRun.Dispatch.run(run.id)
    assert completed.status == :case_opened

    assert {:ok, same} = AuditRun.Dispatch.run(run.id)
    assert same.case_id == completed.case_id
    assert length(Cases.list_cases!(actor: context.viewer)) == 1
    assert length(Cases.list_turns!(actor: context.viewer)) == 1
  end

  test "a persisted Case resumes the initial audit Turn after interruption", context do
    schedule = schedule!(context, "case-interrupted-audit", :en, [context.target.id], nil)
    wake!(schedule)
    [run] = occurrence_runs(schedule)
    assert {:ok, %{state: :claimed}} = Audits.claim_audit_run(run.id, authorize?: false)

    incident = opened_audit_case!(run, schedule)
    assert Cases.list_turns!(actor: context.viewer) == []

    assert {:ok, completed} = AuditRun.Dispatch.run(run.id)
    assert completed.status == :case_opened
    assert completed.case_id == incident.id
    assert length(Cases.list_cases!(actor: context.viewer)) == 1
    assert length(Cases.list_turns!(actor: context.viewer)) == 1
  end

  test "a persisted initial Turn resumes Run outcome recording without another Turn", context do
    schedule = schedule!(context, "turn-interrupted-audit", :en, [context.target.id], nil)
    wake!(schedule)
    [run] = occurrence_runs(schedule)
    assert {:ok, %{state: :claimed}} = Audits.claim_audit_run(run.id, authorize?: false)

    incident = opened_audit_case!(run, schedule)
    resolution_run = Cases.active_resolution_run!(incident.id, authorize?: false)

    started =
      Cases.start_turn!(
        incident.id,
        resolution_run.id,
        "audit-run:#{run.id}:initial",
        %{
          "objective" => schedule.objective,
          "audit_schedule_id" => schedule.id,
          "audit_run_id" => run.id
        },
        %{"action" => "continue"},
        "Review Resolver limits",
        authorize?: false
      )

    assert started.status == :charged
    assert {:ok, completed} = AuditRun.Dispatch.run(run.id)
    assert completed.status == :case_opened
    assert completed.case_id == incident.id
    assert length(Cases.list_cases!(actor: context.viewer)) == 1
    assert length(Cases.list_turns!(actor: context.viewer)) == 1
  end

  test "only an administrator can create a valid one-scope schedule", context do
    assert {:error, %Ash.Error.Forbidden{}} =
             Audits.schedule_audit(
               Ash.UUID.generate(),
               "viewer-audit",
               "Inspect storage health",
               "Etc/UTC",
               "0 * * * *",
               :en,
               [context.target.id],
               nil,
               actor: context.viewer
             )

    assert {:error, _error} =
             Audits.schedule_audit(
               Ash.UUID.generate(),
               "two-scopes",
               "Inspect storage health",
               "Etc/UTC",
               "0 * * * *",
               :en,
               [context.target.id],
               context.boundary.id,
               actor: context.admin
             )

    assert {:error, _error} =
             Audits.schedule_audit(
               Ash.UUID.generate(),
               "no-scope",
               "Inspect storage health",
               "Etc/UTC",
               "0 * * * *",
               :en,
               [],
               nil,
               actor: context.admin
             )
  end

  defp schedule!(context, name, language, target_ids, boundary_id) do
    Audits.schedule_audit!(
      Ash.UUID.generate(),
      name,
      "Inspect storage health",
      "Etc/UTC",
      "0 * * * *",
      language,
      target_ids,
      boundary_id,
      actor: context.admin
    )
  end

  defp wake!(schedule) do
    Audits.wake_audit_schedule!(
      schedule.id,
      schedule.revision,
      schedule.next_run_at,
      authorize?: false
    )
  end

  defp occurrence_runs(schedule) do
    Audits.audit_runs_for_occurrence!(schedule.id, schedule.next_run_at, authorize?: false)
  end

  defp opened_audit_case!(run, schedule) do
    Cases.open_case!(
      :audit,
      "audit-schedule",
      "audit-run:#{run.id}",
      "Scheduled audit: #{schedule.name}",
      :info,
      %{
        "desired_outcome" => schedule.objective,
        "audit_schedule_id" => schedule.id,
        "audit_run_id" => run.id,
        "scheduled_for" => DateTime.to_iso8601(run.scheduled_for)
      },
      run.target_id,
      schedule.report_language,
      authorize?: false
    )
  end

  defp current_schedule(id, actor) do
    Audits.list_audit_schedules!(actor: actor) |> Enum.find(&(&1.id == id))
  end

  defp jobs_for_schedule(schedule_id) do
    from(job in Oban.Job,
      where:
        job.worker == "Skopos.Audits.AuditSchedule.WakeWorker" and
          fragment("?->>'audit_schedule_id'", job.args) == ^schedule_id
    )
    |> Repo.all()
  end

  defp one_job_for_run?(run_id) do
    Repo.aggregate(run_job_query(run_id), :count) == 1
  end

  defp job_for_run(run_id) do
    run_id |> run_job_query() |> first() |> Repo.one()
  end

  defp run_job_query(run_id) do
    from job in Oban.Job,
      where:
        job.worker == "Skopos.Audits.AuditRun.Worker" and
          fragment("?->>'audit_run_id'", job.args) == ^run_id
  end

  defp one_resolver_job?(turn_id) do
    Repo.exists?(
      from job in Oban.Job,
        where:
          job.worker == "Skopos.Cases.Turn.ResolverWorker" and
            fragment("?->>'turn_id'", job.args) == ^turn_id
    )
  end

  defp configure_limits!(admin) do
    current = Cases.current_authority_setting!(actor: admin)

    Cases.configure_authority_setting!(
      current.setting_revision,
      :auto,
      true,
      3_600,
      5,
      20,
      3,
      10,
      100_000,
      3,
      "configure scheduled Audit acceptance",
      actor: admin
    )
  end
end
