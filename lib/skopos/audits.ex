defmodule Skopos.Audits do
  use Ash.Domain,
    otp_app: :skopos

  resources do
    resource Skopos.Audits.AuditSchedule do
      define :list_audit_schedules, action: :read
      define :page_audit_schedules, action: :page
      define :page_audit_schedule_summaries, action: :summaries
      define :get_audit_schedule, action: :read, get_by: [:id]
      define :create_audit_schedule_record, action: :create_record
      define :advance_audit_schedule_record, action: :advance_record, args: [:expected_revision]
      define :deactivate_audit_schedule, action: :deactivate, args: [:expected_revision]

      define :schedule_audit,
        action: :schedule,
        args: [
          :registration_id,
          :name,
          :objective,
          :timezone,
          :cron_expression,
          :report_language,
          :target_ids,
          :management_boundary_id
        ]

      define :wake_audit_schedule,
        action: :wake,
        args: [:id, :expected_revision, :scheduled_for]
    end

    resource Skopos.Audits.AuditRun do
      define :list_audit_runs, action: :read
      define :report_audit_runs, action: :report_period, args: [:from, :to, :target_id]
      define :page_audit_runs, action: :page
      define :page_audit_run_summaries, action: :summaries
      define :get_audit_run, action: :read, get_by: [:id]

      define :audit_runs_for_occurrence,
        action: :for_occurrence,
        args: [:audit_schedule_id, :scheduled_for]

      define :create_audit_run_record, action: :create_record
      define :mark_audit_run_running, action: :mark_running, args: [:expected_revision]
      define :record_audit_run_outcome, action: :record_outcome, args: [:expected_revision]
      define :claim_audit_run, action: :claim, args: [:id]
    end
  end
end
