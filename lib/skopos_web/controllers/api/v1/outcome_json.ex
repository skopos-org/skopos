defmodule SkoposWeb.API.V1.OutcomeJSON do
  @moduledoc false

  alias Skopos.Reports.Report.Document

  def receipt(receipt) do
    %{
      id: receipt.id,
      provider_id: receipt.provider_id,
      provider_revision: receipt.provider_revision,
      receipt_id: receipt.receipt_id,
      source: receipt.source,
      received_at: receipt.received_at,
      event_count: receipt.event_count,
      inserted_at: receipt.inserted_at,
      updated_at: receipt.updated_at
    }
  end

  def signal_event(event) do
    %{
      id: event.id,
      signal_receipt_id: event.signal_receipt_id,
      event_key: event.event_key,
      state: event.state,
      source_sequence: event.source_sequence,
      occurred_at: event.occurred_at,
      target_ref: event.target_ref,
      case_id: event.case_id,
      target_id: event.target_id,
      inserted_at: event.inserted_at,
      updated_at: event.updated_at
    }
  end

  def audit_schedule(schedule) do
    %{
      id: schedule.id,
      name: schedule.name,
      desired_outcome: schedule.objective,
      timezone: schedule.timezone,
      cron_expression: schedule.cron_expression,
      report_language: schedule.report_language,
      target_ids: schedule.target_ids,
      management_boundary_id: schedule.management_boundary_id,
      active: schedule.active,
      next_run_at: schedule.next_run_at,
      revision: schedule.revision,
      inserted_at: schedule.inserted_at,
      updated_at: schedule.updated_at
    }
  end

  def audit_run(run) do
    %{
      id: run.id,
      audit_schedule_id: run.audit_schedule_id,
      schedule_revision: run.schedule_revision,
      target_key: run.target_key,
      target_id: run.target_id,
      target_revision: run.target_revision,
      case_id: run.case_id,
      case_revision: run.case_revision,
      scheduled_for: run.scheduled_for,
      status: run.status,
      reason: run.reason,
      started_at: run.started_at,
      completed_at: run.completed_at,
      revision: run.revision,
      inserted_at: run.inserted_at,
      updated_at: run.updated_at
    }
  end

  def report(report) do
    %{
      id: report.id,
      case_id: report.case_id,
      case_revision: report.case_revision,
      language: report.language,
      outcome: report.outcome,
      document: Document.build(report),
      content: report.content,
      content_digest: report.content_digest,
      generated_at: report.generated_at,
      revision: report.revision
    }
  end

  def report_summary(report), do: Map.take(report, Skopos.Reports.Report.summary_fields())

  def report_setting(setting) do
    %{
      id: setting.id,
      automatic_case_reports_enabled: setting.automatic_case_reports_enabled,
      revision: setting.revision,
      changed_by_id: setting.changed_by_id,
      updated_at: setting.updated_at
    }
  end

  def delivery_summary(delivery),
    do: Map.take(delivery, Skopos.Notifications.Delivery.summary_fields())

  def delivery(delivery) do
    %{
      id: delivery.id,
      report_id: delivery.report_id,
      report_revision: delivery.report_revision,
      provider_id: delivery.provider_id,
      provider_revision: delivery.provider_revision,
      destination_id: delivery.destination_id,
      destination_revision: delivery.destination_revision,
      status: delivery.status,
      reference: delivery.reference,
      details: delivery.details,
      enqueued_at: delivery.enqueued_at,
      dispatch_started_at: delivery.dispatch_started_at,
      completed_at: delivery.completed_at,
      revision: delivery.revision
    }
  end
end
