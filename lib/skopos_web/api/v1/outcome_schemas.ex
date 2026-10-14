defmodule SkoposWeb.API.V1.OutcomeSchemas do
  @moduledoc false

  alias OpenApiSpex.Schema
  alias SkoposWeb.API.Schemas

  def components do
    %{
      "SignalWebhookPayload" => map(),
      "CanonicalSignalWebhookPayload" => canonical_signal_webhook_payload(),
      "SignalWebhookAccepted" => webhook_accepted(),
      "SignalWebhookError" => webhook_error(),
      "SignalWebhookValidationError" => webhook_validation_error(),
      "SignalReceipt" => signal_receipt(),
      "SignalReceiptResponse" => Schemas.data(ref("SignalReceipt")),
      "SignalReceiptPage" => Schemas.page(ref("SignalReceipt")),
      "SignalEvent" => signal_event(),
      "SignalEventPage" => Schemas.page(ref("SignalEvent")),
      "AuditSchedule" => audit_schedule(),
      "AuditScheduleResponse" => Schemas.data(ref("AuditSchedule")),
      "AuditSchedulePage" => Schemas.page(ref("AuditSchedule")),
      "AuditScheduleSummary" => audit_schedule_summary(),
      "AuditScheduleSummaryPage" => Schemas.page(ref("AuditScheduleSummary")),
      "CreateAuditScheduleRequest" => create_audit_schedule_request(),
      "DeactivateAuditScheduleRequest" => deactivate_audit_schedule_request(),
      "AuditRun" => audit_run(),
      "AuditRunResponse" => Schemas.data(ref("AuditRun")),
      "AuditRunPage" => Schemas.page(ref("AuditRun")),
      "AuditRunSummary" => audit_run_summary(),
      "AuditRunSummaryPage" => Schemas.page(ref("AuditRunSummary")),
      "Report" => report(),
      "ReportSummary" => report_summary(),
      "ReportSummaryResponse" => Schemas.data(ref("ReportSummary")),
      "ReportSetting" => report_setting(),
      "ReportSettingResponse" => Schemas.data(ref("ReportSetting")),
      "UpdateReportSettingRequest" => update_report_setting_request(),
      "ReportDocument" => report_document(),
      "ReportResponse" => Schemas.data(ref("Report")),
      "ReportPage" => Schemas.page(ref("ReportSummary")),
      "PeriodSummary" => period_summary(),
      "PeriodSummaryResponse" => Schemas.data(ref("PeriodSummary")),
      "GenerateReportRequest" => generate_report_request(),
      "Delivery" => delivery(),
      "DeliveryResponse" => Schemas.data(ref("Delivery")),
      "DeliveryPage" => Schemas.page(ref("Delivery")),
      "DeliverySummary" => delivery_summary(),
      "LatestDeliverySummary" => latest_delivery_summary(),
      "DeliverySummaryPage" => Schemas.page(ref("DeliverySummary")),
      "DeliverySummaryResponse" => Schemas.data(ref("DeliverySummary")),
      "LatestDeliveriesResponse" =>
        Schemas.data(%Schema{type: :array, items: ref("LatestDeliverySummary"), maxItems: 100}),
      "CreateDeliveryRequest" => create_delivery_request()
    }
  end

  def ref(name), do: Schemas.reference(name)

  def report_ids_parameter(required? \\ false) do
    {:ids, options} = Schemas.reference_ids_parameter()
    {:report_ids, Keyword.put(options, :required, required?)}
  end

  defp canonical_signal_webhook_payload do
    object(
      %{
        event_key: string(1, 500),
        state: enum(~w(firing recovered)),
        occurred_at: Schemas.timestamp(),
        title: string(1, 200),
        severity: enum(~w(info warning error critical)),
        source_sequence: string(1, 500),
        target_ref: object(%{kind: string(1, 80), value: string(1, 500)}, [:kind, :value], false),
        facts: %Schema{
          type: :object,
          description:
            "At most 32 flat string, number or boolean facts; encoded facts must be at most 8000 bytes. Keys are 1-120 characters and string values at most 1000 characters.",
          maxProperties: 32,
          additionalProperties: %Schema{
            oneOf: [
              %Schema{type: :string, maxLength: 1_000},
              %Schema{type: :number},
              %Schema{type: :boolean}
            ]
          }
        }
      },
      [:event_key, :state, :occurred_at, :title],
      false
    )
  end

  defp webhook_accepted do
    object(%{receipt_id: string(1, 500)}, [:receipt_id], false)
  end

  defp webhook_error do
    object(
      %{errors: object(%{detail: %Schema{type: :string}}, [:detail], false)},
      [:errors],
      false
    )
  end

  defp webhook_validation_error do
    %Schema{oneOf: [ref("SignalWebhookError"), Schemas.reference("ErrorResponse")]}
  end

  defp signal_receipt do
    object(
      %{
        id: Schemas.uuid(),
        provider_id: Schemas.uuid(),
        provider_revision: positive_integer(),
        receipt_id: string(1, 500),
        source: string(1, 120),
        received_at: Schemas.timestamp(),
        event_count: %Schema{type: :integer, minimum: 1, maximum: 1_000},
        inserted_at: Schemas.timestamp(),
        updated_at: Schemas.timestamp()
      },
      ~w(id provider_id provider_revision receipt_id source received_at event_count inserted_at updated_at)a,
      false
    )
  end

  defp signal_event do
    object(
      %{
        id: Schemas.uuid(),
        signal_receipt_id: Schemas.uuid(),
        event_key: string(1, 500),
        state: enum(~w(firing recovered)),
        source_sequence: nullable_string(500),
        occurred_at: Schemas.timestamp(),
        target_ref: nullable_map(),
        case_id: nullable_uuid(),
        target_id: nullable_uuid(),
        inserted_at: Schemas.timestamp(),
        updated_at: Schemas.timestamp()
      },
      ~w(id signal_receipt_id event_key state source_sequence occurred_at target_ref case_id target_id inserted_at updated_at)a,
      false
    )
  end

  defp audit_schedule do
    object(
      %{
        id: Schemas.uuid(),
        name: string(1, 120),
        desired_outcome: string(1, 2_000),
        timezone: string(1, 120),
        cron_expression: string(1, 120),
        report_language: enum(~w(en ja)),
        target_ids: %Schema{type: :array, items: Schemas.uuid()},
        management_boundary_id: nullable_uuid(),
        active: %Schema{type: :boolean},
        next_run_at: Schemas.timestamp(),
        revision: positive_integer(),
        inserted_at: Schemas.timestamp(),
        updated_at: Schemas.timestamp()
      },
      ~w(id name desired_outcome timezone cron_expression report_language target_ids management_boundary_id active next_run_at revision inserted_at updated_at)a,
      false
    )
  end

  defp create_audit_schedule_request do
    wrapped(
      :audit_schedule,
      %{
        registration_id: Schemas.uuid(),
        name: string(1, 120),
        desired_outcome: string(1, 2_000),
        timezone: string(1, 120),
        cron_expression: string(1, 120),
        report_language: enum(~w(en ja)),
        target_ids: %Schema{type: :array, items: Schemas.uuid()},
        management_boundary_id: nullable_uuid()
      },
      ~w(registration_id name desired_outcome timezone cron_expression report_language)a
    )
  end

  defp audit_schedule_summary do
    schema = audit_schedule()
    fields = Skopos.Audits.AuditSchedule.summary_fields()
    %{schema | properties: Map.take(schema.properties, fields), required: fields}
  end

  defp audit_run_summary do
    schema = audit_run()
    fields = Skopos.Audits.AuditRun.summary_fields()
    %{schema | properties: Map.take(schema.properties, fields), required: fields}
  end

  defp deactivate_audit_schedule_request do
    wrapped(:audit_schedule, %{expected_revision: positive_integer()}, [:expected_revision])
  end

  defp audit_run do
    object(
      %{
        id: Schemas.uuid(),
        audit_schedule_id: Schemas.uuid(),
        schedule_revision: positive_integer(),
        target_key: string(1, 160),
        target_id: nullable_uuid(),
        target_revision: nullable_positive_integer(),
        case_id: nullable_uuid(),
        case_revision: nullable_positive_integer(),
        scheduled_for: Schemas.timestamp(),
        status: enum(~w(queued running case_opened skipped cancelled failed)),
        reason: nullable_string(1_000),
        started_at: nullable_timestamp(),
        completed_at: nullable_timestamp(),
        revision: positive_integer(),
        inserted_at: Schemas.timestamp(),
        updated_at: Schemas.timestamp()
      },
      ~w(id audit_schedule_id schedule_revision target_key target_id target_revision case_id case_revision scheduled_for status reason started_at completed_at revision inserted_at updated_at)a,
      false
    )
  end

  defp report do
    object(
      %{
        id: Schemas.uuid(),
        case_id: Schemas.uuid(),
        case_revision: positive_integer(),
        language: enum(~w(en ja)),
        outcome: enum(~w(resolved needs_attention cancelled)),
        document: ref("ReportDocument"),
        content: map(),
        content_digest: digest(),
        generated_at: Schemas.timestamp(),
        revision: positive_integer()
      },
      ~w(id case_id case_revision language outcome document content content_digest generated_at revision)a,
      false
    )
  end

  defp report_summary do
    fields = Skopos.Reports.Report.summary_fields()

    properties =
      report().properties
      |> Map.take(fields)
      |> Map.put(:operation_count, %Schema{type: :integer, minimum: 0})
      |> Map.put(:verification_count, %Schema{type: :integer, minimum: 0})

    object(properties, fields, false)
  end

  defp report_document do
    action =
      object(
        %{
          id: Schemas.uuid(),
          name: %Schema{type: :string},
          status: %Schema{type: :string},
          outcome_category: nullable_string(500),
          detail: nullable_string(10_000),
          completed_at: nullable_timestamp()
        },
        ~w(id name status outcome_category detail completed_at)a,
        false
      )

    verification =
      object(
        %{
          id: Schemas.uuid(),
          status: %Schema{type: :string},
          outcome_category: nullable_string(500),
          facts: nullable_string(10_000),
          observed_at: nullable_timestamp()
        },
        ~w(id status outcome_category facts observed_at)a,
        false
      )

    condition =
      object(
        %{
          id: Schemas.uuid(),
          target_id: nullable_uuid(),
          predicate: %Schema{type: :string},
          source_state: %Schema{type: :string},
          symptom: %Schema{type: :string},
          source_evidence_id: nullable_uuid(),
          assessment: nullable_string(10_000),
          evidence_id: nullable_uuid(),
          evidence_facts: nullable_string(10_000)
        },
        ~w(id target_id predicate source_state symptom source_evidence_id assessment evidence_id evidence_facts)a,
        false
      )

    cited_evidence =
      object(
        %{
          id: Schemas.uuid(),
          kind: %Schema{type: :string},
          observed_at: Schemas.timestamp(),
          facts: nullable_string(10_000)
        },
        ~w(id kind observed_at facts)a,
        false
      )

    symptom_citation =
      object(
        %{
          evidence_id: Schemas.uuid(),
          fact_keys: %Schema{type: :array, items: string(1, 120)},
          facts: nullable_string(10_000)
        },
        ~w(evidence_id fact_keys facts)a,
        false
      )

    case_symptom =
      object(
        %{
          id: digest(),
          text: string(1, 2_000),
          desired_outcome: string(1, 2_000),
          status: enum(~w(supported unsupported unknown)),
          review_reason: nullable_string(1_000),
          claim_evidence: %Schema{type: :array, items: symptom_citation}
        },
        ~w(id text desired_outcome status review_reason claim_evidence)a,
        false
      )
      |> Map.put(:nullable, true)

    recovery_review =
      object(
        %{
          id: Schemas.uuid(),
          source_turn_id: Schemas.uuid(),
          verdict: enum(~w(approved rejected needs_human)),
          reason: string(1, 1_000),
          evidence_ids: %Schema{type: :array, items: Schemas.uuid()},
          desired_outcome_assessment: Schemas.desired_outcome_assessment(true),
          provider_id: Schemas.uuid(),
          inserted_at: Schemas.timestamp()
        },
        ~w(id source_turn_id verdict reason evidence_ids desired_outcome_assessment provider_id inserted_at)a,
        false
      )

    object(
      %{
        title: %Schema{type: :string},
        outcome: %Schema{type: :string},
        opened_at: Schemas.timestamp(),
        finished_at: Schemas.timestamp(),
        target_id: nullable_uuid(),
        source: %Schema{type: :string},
        source_ref: %Schema{type: :string},
        severity: %Schema{type: :string},
        conditions: %Schema{type: :array, items: condition},
        case_symptom: case_symptom,
        actions: %Schema{type: :array, items: action},
        verifications: %Schema{type: :array, items: verification},
        cited_evidence: %Schema{type: :array, items: cited_evidence},
        conclusion: nullable_string(10_000),
        conclusion_turn_id: nullable_uuid(),
        recovery_reviews: %Schema{type: :array, items: recovery_review},
        stop_reason: nullable_string(10_000),
        required_human_input: nullable_string(10_000),
        case_id: Schemas.uuid(),
        case_revision: positive_integer(),
        digest: digest(),
        text: %Schema{type: :string}
      },
      ~w(title outcome opened_at finished_at target_id source source_ref severity conditions case_symptom actions verifications cited_evidence conclusion conclusion_turn_id recovery_reviews stop_reason required_human_input case_id case_revision digest text)a,
      false
    )
  end

  defp period_summary do
    case_source =
      object(
        %{
          id: Schemas.uuid(),
          title: %Schema{type: :string},
          status: enum(~w(running needs_attention resolved cancelled)),
          trigger_kind: enum(~w(manual signal audit)),
          opened_at: Schemas.timestamp(),
          target_id: nullable_uuid()
        },
        ~w(id title status trigger_kind opened_at target_id)a,
        false
      )

    audit_source =
      object(
        %{
          id: Schemas.uuid(),
          status: enum(~w(queued running case_opened skipped cancelled failed)),
          scheduled_for: Schemas.timestamp(),
          target_id: nullable_uuid(),
          case_id: nullable_uuid(),
          reason: nullable_string(10_000)
        },
        ~w(id status scheduled_for target_id case_id reason)a,
        false
      )

    object(
      %{
        from: Schemas.timestamp(),
        to: Schemas.timestamp(),
        as_of: Schemas.timestamp(),
        target_id: nullable_uuid(),
        case_count: %Schema{type: :integer},
        case_status:
          object(
            Map.new(
              ~w(running needs_attention resolved cancelled),
              &{String.to_atom(&1), %Schema{type: :integer}}
            ),
            ~w(running needs_attention resolved cancelled)a,
            false
          ),
        case_trigger:
          object(
            Map.new(~w(manual signal audit), &{String.to_atom(&1), %Schema{type: :integer}}),
            ~w(manual signal audit)a,
            false
          ),
        recovery:
          object(
            %{
              measured_cases: %Schema{type: :integer},
              unmeasured_resolved_cases: %Schema{type: :integer},
              average_seconds: %Schema{type: :integer, nullable: true}
            },
            ~w(measured_cases unmeasured_resolved_cases average_seconds)a,
            false
          ),
        audit_count: %Schema{type: :integer},
        audit_status:
          object(
            Map.new(
              ~w(queued running case_opened skipped cancelled failed),
              &{String.to_atom(&1), %Schema{type: :integer}}
            ),
            ~w(queued running case_opened skipped cancelled failed)a,
            false
          ),
        daily: %Schema{
          type: :array,
          items:
            object(
              %{
                date: %Schema{type: :string, format: :date},
                cases: %Schema{type: :integer},
                audits: %Schema{type: :integer}
              },
              ~w(date cases audits)a,
              false
            )
        },
        cases: %Schema{type: :array, items: case_source},
        audits: %Schema{type: :array, items: audit_source},
        case_sources_truncated: %Schema{type: :boolean},
        audit_sources_truncated: %Schema{type: :boolean}
      },
      ~w(from to as_of target_id case_count case_status case_trigger recovery audit_count audit_status daily cases audits case_sources_truncated audit_sources_truncated)a,
      false
    )
  end

  defp generate_report_request do
    wrapped(:report, %{expected_case_revision: positive_integer()}, [:expected_case_revision])
  end

  defp report_setting do
    object(
      %{
        id: Schemas.uuid(),
        automatic_case_reports_enabled: %Schema{type: :boolean},
        revision: positive_integer(),
        changed_by_id: nullable_uuid(),
        updated_at: Schemas.timestamp()
      },
      ~w(id automatic_case_reports_enabled revision changed_by_id updated_at)a,
      false
    )
  end

  defp update_report_setting_request do
    wrapped(
      :report_setting,
      %{
        expected_revision: positive_integer(),
        automatic_case_reports_enabled: %Schema{type: :boolean}
      },
      [:expected_revision, :automatic_case_reports_enabled]
    )
  end

  defp delivery do
    object(
      %{
        id: Schemas.uuid(),
        report_id: Schemas.uuid(),
        report_revision: positive_integer(),
        provider_id: Schemas.uuid(),
        provider_revision: positive_integer(),
        destination_id: Schemas.uuid(),
        destination_revision: positive_integer(),
        status: enum(~w(queued dispatching accepted delivered failed unknown)),
        reference: nullable_string(1_024),
        details: map(),
        enqueued_at: Schemas.timestamp(),
        dispatch_started_at: nullable_timestamp(),
        completed_at: nullable_timestamp(),
        revision: positive_integer()
      },
      ~w(id report_id report_revision provider_id provider_revision destination_id destination_revision status reference details enqueued_at dispatch_started_at completed_at revision)a,
      false
    )
  end

  defp delivery_summary do
    schema = delivery()
    fields = Skopos.Notifications.Delivery.summary_fields()
    %{schema | properties: Map.take(schema.properties, fields), required: fields}
  end

  defp create_delivery_request do
    wrapped(
      :delivery,
      %{
        report_id: Schemas.uuid(),
        report_revision: positive_integer(),
        provider_id: Schemas.uuid(),
        provider_revision: positive_integer(),
        idempotency_key: string(1, 1_024)
      },
      [:report_id, :report_revision, :provider_id, :provider_revision, :idempotency_key]
    )
  end

  defp latest_delivery_summary do
    schema = delivery_summary()

    %{
      schema
      | properties: Map.put(schema.properties, :attempt_count, positive_integer()),
        required: [:attempt_count | schema.required]
    }
  end

  defp wrapped(name, properties, required) do
    object(%{name => object(properties, required)}, [name])
  end

  defp digest, do: %Schema{type: :string, minLength: 64, maxLength: 64}
  defp enum(values), do: %Schema{type: :string, enum: values}

  defp string(min_length, max_length),
    do: %Schema{type: :string, minLength: min_length, maxLength: max_length}

  defp nullable_string(max_length),
    do: %Schema{type: :string, maxLength: max_length, nullable: true}

  defp positive_integer, do: %Schema{type: :integer, minimum: 1}
  defp nullable_positive_integer, do: %Schema{type: :integer, minimum: 1, nullable: true}
  defp map, do: %Schema{type: :object, additionalProperties: true}
  defp nullable_map, do: %Schema{type: :object, additionalProperties: true, nullable: true}
  defp nullable_uuid, do: %Schema{type: :string, format: :uuid, nullable: true}
  defp nullable_timestamp, do: %Schema{type: :string, format: :"date-time", nullable: true}

  defp object(properties, required, additional_properties \\ nil) do
    %Schema{
      type: :object,
      properties: properties,
      required: required,
      additionalProperties: additional_properties
    }
  end
end
