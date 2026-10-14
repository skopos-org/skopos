defmodule Skopos.CaseReportTest do
  use Skopos.DataCase, async: false

  alias Skopos.{Accounts, Cases, Reports}
  alias Skopos.Cases.{Case, Operation, VerificationAttempt}
  alias Skopos.Cases.Case.Symptom, as: CaseSymptom
  alias Skopos.Reports.Report.Content
  alias Skopos.Reports.Report.Document
  alias Skopos.Reports.Report
  alias Skopos.Reports.Report.GenerationWorker

  @password "correct horse battery staple"

  setup do
    admin =
      Accounts.bootstrap!("report-admin@example.com", @password, @password, authorize?: true)

    operator =
      Accounts.create_user!("report-operator@example.com", @password, :operator, actor: admin)

    viewer = Accounts.create_user!("report-viewer@example.com", @password, :viewer, actor: admin)
    %{admin: admin, operator: operator, viewer: viewer}
  end

  test "a terminal Case revision becomes one immutable localized Report", context do
    operator =
      Accounts.change_preferred_language!(context.operator, :ja, actor: context.operator)

    incident = open!("ja-report", operator)
    run = Cases.active_resolution_run!(incident.id, authorize?: false)
    now = DateTime.utc_now()

    first_turn =
      Cases.create_turn_record!(
        %{
          case_id: incident.id,
          resolution_run_id: run.id,
          ordinal: 1,
          idempotency_key: "report-turn-1",
          status: :completed,
          intent: %{"objective" => "障害を解決する"},
          result: %{
            "intent" => %{
              "type" => "proposal",
              "reason" => "サービス停止が主因の可能性があります"
            }
          },
          progress_kind: :proposal,
          started_at: now,
          completed_at: now
        },
        authorize?: false
      )

    Cases.create_turn_record!(
      %{
        case_id: incident.id,
        resolution_run_id: run.id,
        ordinal: 2,
        idempotency_key: "report-turn-2",
        status: :completed,
        intent: %{"objective" => "残る不確実性を確認する"},
        result: %{
          "intent" => %{
            "type" => "handoff",
            "reason" => "複合要因のため物理状態を確認できません",
            "required_input" => "ディスクLEDを確認してください"
          }
        },
        progress_kind: :human_input,
        started_at: DateTime.add(now, 1, :second),
        completed_at: DateTime.add(now, 1, :second)
      },
      authorize?: false
    )

    evidence =
      Cases.append_evidence!(
        incident.id,
        run.id,
        first_turn.id,
        "report-evidence",
        "observation",
        "linux-ssh",
        "host-1",
        %{"uncertainty" => "hardware path remains unknown"},
        now,
        authorize?: false
      )

    terminal =
      Cases.record_case_attention!(
        incident,
        incident.revision,
        "複合要因の調査には現地確認が必要です",
        %{"action" => "inspect_hardware"},
        "ディスクLEDを確認してください",
        authorize?: false
      )

    Cases.pause_resolution_run!(run, run.revision, authorize?: false)

    report =
      Reports.generate_report!(terminal.id, terminal.revision, actor: context.operator)

    assert report.language == :ja
    assert report.outcome == :needs_attention
    assert report.revision == 1
    assert byte_size(report.content_digest) == 64
    assert report.content["labels"]["summary"] == "概要"
    assert report.content["outcome_label"] == "対応が必要"
    assert report.content["case"]["revision"] == terminal.revision
    assert report.content["raw_evidence"] |> hd() |> Map.fetch!("id") == evidence.id
    assert length(report.content["resolver_turns"]) == 2

    assert get_in(report.content, ["resolver_turns", Access.at(1), "decision", "reason"]) ==
             "複合要因のため物理状態を確認できません"

    assert report.content["unresolved"]["required_human_input"] ==
             "ディスクLEDを確認してください"

    document = Document.build(report)
    assert document["title"] == "Case ja-report"
    assert document["condition"] == nil
    assert document["required_human_input"] == "ディスクLEDを確認してください"
    assert document["text"] =~ "未確認"
    assert document["text"] =~ "ディスクLEDを確認してください"

    serialized = Jason.encode!(report.content)
    refute serialized =~ "pending_intent"
    refute serialized =~ "idempotency_key"
    refute serialized =~ "resolver_identity"
    refute serialized =~ "session_id"

    retried = Reports.generate_report!(terminal.id, terminal.revision, actor: context.operator)
    assert retried.id == report.id
    assert retried.generated_at == report.generated_at
    assert retried.content_digest == report.content_digest
    assert retried.content == report.content

    reloaded = Reports.get_report!(report.id, actor: context.viewer)
    assert reloaded.content == report.content
    assert Reports.list_reports!(actor: context.viewer) |> Enum.map(& &1.id) == [report.id]

    assert {:error, %Ash.Error.Forbidden{}} =
             Reports.generate_report(terminal.id, terminal.revision, actor: context.viewer)
  end

  test "English labels are fixed at Case open and a running Case stays unchanged on failure",
       context do
    running = open!("running-report", context.operator)

    assert {:error, _error} =
             Reports.generate_report(running.id, running.revision, actor: context.operator)

    unchanged = Cases.get_case!(running.id, actor: context.viewer)
    assert unchanged.status == :running
    assert unchanged.revision == running.revision
    assert Reports.list_reports!(actor: context.viewer) == []

    resolved =
      Cases.record_case_resolution!(running, running.revision, DateTime.utc_now(),
        authorize?: false
      )

    assert {:error, _error} =
             Reports.generate_report(resolved.id, resolved.revision + 1, actor: context.operator)

    still_resolved = Cases.get_case!(resolved.id, actor: context.viewer)
    assert still_resolved.status == :resolved
    assert still_resolved.revision == resolved.revision

    report = Reports.generate_report!(resolved.id, resolved.revision, actor: context.operator)
    assert report.content["labels"]["summary"] == "Summary"
    assert report.content["outcome_label"] == "Resolved"
  end

  test "a final automatic Report failure is persisted without claiming completion", context do
    incident = open!("failed-report", context.operator)

    job = %Oban.Job{
      args: %{"case_id" => incident.id, "case_revision" => incident.revision},
      attempt: 3,
      max_attempts: 3
    }

    assert {:error, _error} =
             GenerationWorker.perform(job)

    assert {:error, _error} = GenerationWorker.perform(job)

    setting = Reports.current_setting!(actor: context.admin)
    Reports.configure_setting!(setting, setting.revision, false, actor: context.admin)
    assert :ok = GenerationWorker.perform(%{job | meta: %{"snoozed" => 1}})

    assert Reports.list_reports!(actor: context.admin) == []

    assert [event] =
             Cases.list_case_events!(actor: context.admin)
             |> Enum.filter(
               &(&1.case_id == incident.id and &1.event_type == "report_generation_failed")
             )

    assert event.resolution_run_id == nil
    assert event.data["case_revision"] == incident.revision
  end

  test "disabling automatic reports suppresses queued work while manual generation remains available",
       context do
    setting = Reports.current_setting!(actor: context.admin)
    assert setting.automatic_case_reports_enabled

    incident = open!("automatic-off", context.operator)

    resolved =
      Cases.record_case_resolution!(incident, incident.revision, DateTime.utc_now(),
        authorize?: false
      )

    queued_job = %Oban.Job{
      args: %{"case_id" => resolved.id, "case_revision" => resolved.revision},
      attempt: 1,
      max_attempts: 3
    }

    assert {:error, %Ash.Error.Forbidden{}} =
             Reports.configure_setting(setting, setting.revision, false, actor: context.operator)

    disabled = Reports.configure_setting!(setting, setting.revision, false, actor: context.admin)
    assert disabled.revision == setting.revision + 1
    assert disabled.changed_by_id == context.admin.id
    refute Reports.current_setting!(actor: context.viewer).automatic_case_reports_enabled

    assert :ok = GenerationWorker.perform(queued_job)
    assert Reports.list_reports!(actor: context.viewer) == []

    manual = Reports.generate_report!(resolved.id, resolved.revision, actor: context.operator)
    assert manual.case_id == resolved.id

    another = open!("automatic-on", context.operator)

    another_resolved =
      Cases.record_case_resolution!(another, another.revision, DateTime.utc_now(),
        authorize?: false
      )

    assert {:error, _stale} =
             Reports.configure_setting(setting, setting.revision, true, actor: context.admin)

    enabled = Reports.configure_setting!(disabled, disabled.revision, true, actor: context.admin)
    assert enabled.automatic_case_reports_enabled

    assert :ok =
             GenerationWorker.perform(%Oban.Job{
               args: %{
                 "case_id" => another_resolved.id,
                 "case_revision" => another_resolved.revision
               },
               attempt: 1,
               max_attempts: 3
             })

    assert Reports.report_by_case_revision!(another_resolved.id, another_resolved.revision,
             authorize?: false
           )
  end

  test "automatic generation fails closed when its setting cannot be read", context do
    incident = open!("automatic-setting-unavailable", context.operator)

    resolved =
      Cases.record_case_resolution!(incident, incident.revision, DateTime.utc_now(),
        authorize?: false
      )

    Ecto.Adapters.SQL.query!(Skopos.Repo, "DELETE FROM report_settings", [])

    assert {:error, _error} =
             GenerationWorker.perform(%Oban.Job{
               args: %{"case_id" => resolved.id, "case_revision" => resolved.revision},
               attempt: 1,
               max_attempts: 3
             })

    assert Reports.list_reports!(actor: context.admin) == []
  end

  test "projection preserves multiple operation outcomes and raw uncertainty", _context do
    incident = %Case{
      id: Ash.UUID.generate(),
      revision: 7,
      report_language: :ja,
      status: :needs_attention,
      pending_intent: %{}
    }

    records = %{
      runs: [],
      events: [],
      turns: [],
      evidence: [],
      proposals: [],
      reviews: [],
      approvals: [],
      operations: [
        %Operation{
          id: Ash.UUID.generate(),
          purpose: :remediation,
          request_kind: :effect,
          status: :applied,
          operation: "service.restart"
        },
        %Operation{
          id: Ash.UUID.generate(),
          purpose: :remediation,
          request_kind: :effect,
          status: :unknown,
          operation: "interface.reset",
          outcome_category: "connection_lost",
          result_details: %{"uncertainty" => "remote acceptance cannot be confirmed"}
        }
      ],
      verifications: [
        %VerificationAttempt{
          id: Ash.UUID.generate(),
          status: :unknown,
          operation: "interface.inspect",
          outcome_category: "timeout",
          facts: %{"state" => "unknown"}
        }
      ]
    }

    content = Content.build(incident, records)
    assert Enum.map(content["operations"], & &1["status"]) == ["applied", "unknown"]
    assert Enum.map(content["operations"], & &1["purpose"]) == ["remediation", "remediation"]
    document = Document.build(%Report{content: content, language: :ja})

    assert Enum.map(document["actions"], & &1["name"]) == [
             "service.restart",
             "interface.reset"
           ]

    assert get_in(content, ["operations", Access.at(1), "result_details", "uncertainty"]) ==
             "remote acceptance cannot be confirmed"

    assert content["verifications"] |> hd() |> Map.fetch!("status") == "unknown"
  end

  test "readable projection shows every monitored condition and only cited recovery facts",
       _context do
    now = DateTime.utc_now() |> DateTime.to_iso8601()
    later = DateTime.utc_now() |> DateTime.add(1, :second) |> DateTime.to_iso8601()
    source_id = Ash.UUID.generate()
    cited_id = Ash.UUID.generate()
    uncited_id = Ash.UUID.generate()
    condition_id = Ash.UUID.generate()
    turn_id = Ash.UUID.generate()
    review_id = Ash.UUID.generate()

    report = %Report{
      case_id: Ash.UUID.generate(),
      case_revision: 2,
      language: :en,
      content_digest: String.duplicate("a", 64),
      content: %{
        "case" => %{
          "title" => "Optical link incident",
          "status" => "resolved",
          "inserted_at" => now,
          "updated_at" => later
        },
        "outcome_label" => "Resolved",
        "resolution_turn_id" => turn_id,
        "resolution_review_event_id" => review_id,
        "recovery_reviews" => [
          %{
            "id" => review_id,
            "source_turn_id" => turn_id,
            "verdict" => "approved",
            "reason" => "The laser reading directly addresses the optical symptom",
            "evidence_ids" => [cited_id],
            "provider_id" => Ash.UUID.generate(),
            "inserted_at" => later
          }
        ],
        "conditions" => [
          %{
            "id" => condition_id,
            "revision" => 2,
            "predicate" => "VendorOpticalFault",
            "state" => "recovered"
          }
        ],
        "resolver_turns" => [
          %{
            "id" => turn_id,
            "decision" => %{
              "type" => "recovery_conclusion",
              "reason" => "The link is usable again",
              "evidence_ids" => [cited_id],
              "condition_claims" => [
                %{
                  "condition_id" => condition_id,
                  "revision" => 2,
                  "evidence_id" => cited_id,
                  "reason" => "The optical reading is within the expected range"
                }
              ]
            }
          }
        ],
        "operations" => [],
        "verifications" => [],
        "raw_evidence" => [
          %{
            "id" => source_id,
            "kind" => "signal_event",
            "source_ref" => "native-optical-event",
            "observed_at" => now,
            "content" => %{
              "condition_id" => condition_id,
              "state" => "firing",
              "attributes" => %{
                "title" => "Optical link fault",
                "labels" => %{"vendor_fiber_lane" => "uplink-3"}
              }
            }
          },
          %{
            "id" => cited_id,
            "kind" => "observation",
            "observed_at" => later,
            "content" => %{"facts" => %{"laser_bias_ma" => 1.9}}
          },
          %{
            "id" => uncited_id,
            "kind" => "observation",
            "observed_at" => later,
            "content" => %{"facts" => %{"unrelated_port" => "healthy"}}
          }
        ]
      }
    }

    document = Document.build(report)

    assert [
             %{
               "id" => ^condition_id,
               "source_evidence_id" => ^source_id,
               "evidence_id" => ^cited_id
             } = condition
           ] = document["conditions"]

    assert condition["symptom"] =~ "vendor_fiber_lane=uplink-3"
    assert condition["evidence_facts"] == "laser_bias_ma=1.9"
    assert Enum.map(document["cited_evidence"], & &1["id"]) == [cited_id]
    refute document["text"] =~ uncited_id
    refute document["text"] =~ "unrelated_port"
    assert document["conclusion_turn_id"] == turn_id
    assert document["recovery_reviews"] |> hd() |> Map.fetch!("id") == review_id

    without_review =
      %{report | content: Map.put(report.content, "resolution_review_event_id", nil)}

    assert Document.build(without_review)["conclusion"] == nil
  end

  test "manual report shows only the accepted fact keys for its original symptom", _context do
    case_id = Ash.UUID.generate()
    evidence_id = Ash.UUID.generate()
    unrelated_id = Ash.UUID.generate()
    turn_id = Ash.UUID.generate()
    review_id = Ash.UUID.generate()
    original = "vendor_power_rail=degraded"

    symptom =
      CaseSymptom.current(%{
        id: case_id,
        trigger_kind: :manual,
        title: "Power rail case",
        initial_context: %{
          "observed_problem" => original,
          "desired_outcome" => "Power rail is healthy"
        }
      })

    claim = %{
      "symptom_id" => symptom.id,
      "evidence_id" => evidence_id,
      "fact_keys" => ["vendor_power_rail"],
      "reason" => "The same power rail is now healthy"
    }

    assessment = %{
      "symptom_id" => symptom.id,
      "desired_outcome" => "Power rail is healthy",
      "status" => "supported",
      "evidence_ids" => [evidence_id],
      "reason" => "The observed rail state supports recovery"
    }

    report = %Report{
      case_id: case_id,
      case_revision: 3,
      language: :en,
      content_digest: String.duplicate("b", 64),
      content: %{
        "case" => %{
          "id" => case_id,
          "trigger_kind" => "manual",
          "title" => "Power rail case",
          "initial_context" => %{
            "observed_problem" => original,
            "desired_outcome" => "Power rail is healthy"
          },
          "status" => "resolved"
        },
        "outcome_label" => "Resolved",
        "resolution_turn_id" => turn_id,
        "resolution_review_event_id" => review_id,
        "resolver_turns" => [
          %{
            "id" => turn_id,
            "decision" => %{
              "type" => "recovery_conclusion",
              "reason" => "Power rail recovered",
              "evidence_ids" => [evidence_id],
              "desired_outcome_claims" => [claim]
            }
          }
        ],
        "recovery_reviews" => [
          %{
            "id" => review_id,
            "source_turn_id" => turn_id,
            "verdict" => "approved",
            "reason" => "Observed rail is healthy",
            "evidence_ids" => [evidence_id],
            "desired_outcome_claims" => [claim],
            "desired_outcome_assessment" => assessment
          }
        ],
        "raw_evidence" => [
          %{
            "id" => evidence_id,
            "kind" => "observation",
            "content" => %{
              "facts" => %{
                "vendor_power_rail" => "healthy",
                "unrelated_fan" => "healthy"
              }
            }
          },
          %{
            "id" => unrelated_id,
            "kind" => "observation",
            "content" => %{"facts" => %{"other_rail" => "healthy"}}
          }
        ]
      }
    }

    document = Document.build(report)

    assert document["case_symptom"] == %{
             "id" => symptom.id,
             "text" => original,
             "desired_outcome" => "Power rail is healthy",
             "status" => "supported",
             "review_reason" => "Observed rail is healthy",
             "claim_evidence" => [
               %{
                 "evidence_id" => evidence_id,
                 "fact_keys" => ["vendor_power_rail"],
                 "facts" => "vendor_power_rail=healthy"
               }
             ]
           }

    assert document["text"] =~ "vendor_power_rail=healthy"
    refute document["text"] =~ "unrelated_fan"
    refute document["text"] =~ unrelated_id

    assert document["recovery_reviews"] |> hd() |> Map.fetch!("desired_outcome_assessment") ==
             assessment

    refute Map.has_key?(hd(document["recovery_reviews"]), "desired_outcome_claims")

    without_acceptance =
      %{report | content: Map.put(report.content, "resolution_review_event_id", nil)}
      |> Document.build()

    assert without_acceptance["case_symptom"]["status"] == "unknown"
    assert without_acceptance["case_symptom"]["claim_evidence"] == []
  end

  test "unresolved audit report keeps the original objective without implying recovery",
       _context do
    case_id = Ash.UUID.generate()
    evidence_id = Ash.UUID.generate()
    objective = "Confirm BMC thermal alarm is cleared"

    symptom =
      CaseSymptom.current(%{
        id: case_id,
        trigger_kind: :audit,
        title: "Thermal audit",
        initial_context: %{"desired_outcome" => objective}
      })

    report = %Report{
      case_id: case_id,
      case_revision: 4,
      language: :en,
      content_digest: String.duplicate("c", 64),
      content: %{
        "case" => %{
          "id" => case_id,
          "trigger_kind" => "audit",
          "title" => "Thermal audit",
          "initial_context" => %{"desired_outcome" => objective},
          "status" => "needs_attention"
        },
        "outcome_label" => "Needs attention",
        "unresolved" => %{"stop_reason" => "Thermal state remains uncertain"},
        "recovery_reviews" => [
          %{
            "id" => Ash.UUID.generate(),
            "source_turn_id" => Ash.UUID.generate(),
            "verdict" => "rejected",
            "reason" => "Temperature observation does not cover the alarm",
            "evidence_ids" => [evidence_id],
            "desired_outcome_claims" => [
              %{"symptom_id" => symptom.id, "evidence_id" => evidence_id}
            ],
            "desired_outcome_assessment" => %{
              "symptom_id" => symptom.id,
              "desired_outcome" => objective,
              "status" => "unsupported",
              "evidence_ids" => [evidence_id],
              "reason" => "Alarm status was not observed"
            }
          }
        ]
      }
    }

    document = Document.build(report)
    assert document["case_symptom"]["text"] == "Thermal audit"
    assert document["case_symptom"]["desired_outcome"] == objective
    assert document["case_symptom"]["status"] == "unsupported"
    assert document["case_symptom"]["claim_evidence"] == []
    assert document["conclusion"] == nil
    assert document["text"] =~ "Outcome not confirmed"
    refute document["text"] =~ "Outcome confirmed"
  end

  defp open!(source_ref, actor) do
    Cases.open_case!(
      :manual,
      "test",
      source_ref,
      "Case #{source_ref}",
      :warning,
      %{"source_ref" => source_ref, "desired_outcome" => "Target responds as expected"},
      nil,
      :en,
      actor: actor
    )
  end
end
