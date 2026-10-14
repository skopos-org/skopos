defmodule Skopos.PeriodReportTest do
  use Skopos.DataCase, async: false

  alias Skopos.{Accounts, Audits, Cases, Providers, Reports, Signals, Targets}
  alias Skopos.Providers.Signal

  @password "correct horse battery staple"

  test "period summary counts Cases, measured recovery and audit outcomes" do
    admin = Accounts.bootstrap!("period-admin@example.com", @password, @password)
    viewer = Accounts.create_user!("period-viewer@example.com", @password, :viewer, actor: admin)
    boundary = Targets.create_management_boundary!("period-dc", "datacenter", %{}, actor: admin)

    target =
      Targets.create_target!("period-host", "host", "linux", %{}, boundary.id, actor: admin)

    other = Targets.create_target!("other-host", "host", "linux", %{}, boundary.id, actor: admin)

    opened =
      Cases.open_case!(
        :manual,
        "period-test",
        "period-1",
        "Service unavailable",
        :warning,
        %{"desired_outcome" => "Target responds as expected"},
        target.id,
        :en,
        actor: admin
      )

    resolved =
      Cases.record_case_resolution!(opened, opened.revision, DateTime.utc_now(),
        authorize?: false
      )

    provider =
      Providers.create_provider!(
        "period-signal",
        :signal,
        "fixture-signal",
        %{"source" => "period-test"},
        %{"secret" => "period-secret"},
        actor: admin
      )
      |> then(&Providers.check_provider!(&1.id, 1, %{}, actor: admin))
      |> then(&Providers.enable_provider!(&1, 1, actor: admin))

    Targets.create_external_identity!(target.id, "period-test", "hostname", target.name,
      actor: admin
    )

    occurred_at = DateTime.utc_now()

    Signals.ingest_signal!(
      provider.id,
      provider.revision,
      %Signal.Envelope{body: "period-2", headers: %{}, received_at: occurred_at},
      %{
        authenticate: fn adapter, _envelope ->
          {:ok, %Signal.AuthenticatedReceipt{receipt_id: "period-2", source: adapter.source}}
        end,
        normalize: fn _adapter, _envelope, _receipt ->
          {:ok,
           [
             %Signal.Event{
               receipt_id: "period-2",
               event_key: "period-2",
               state: :firing,
               occurred_at: occurred_at,
               target_ref: %{kind: :hostname, value: target.name},
               attributes: %{"title" => "Another service unavailable"}
             }
           ]}
        end
      }
    )

    [attention] = Enum.filter(Cases.list_cases!(actor: admin), &(&1.trigger_kind == :signal))
    assert attention.status == :needs_attention

    Cases.open_case!(
      :manual,
      "period-test",
      "period-other",
      "Other target",
      :warning,
      %{"desired_outcome" => "Target responds as expected"},
      other.id,
      :en,
      actor: admin
    )

    now = DateTime.utc_now()

    schedule =
      Audits.create_audit_schedule_record!(
        %{
          registration_id: Ash.UUID.generate(),
          name: "period-audit",
          objective: "Inspect service",
          timezone: "Etc/UTC",
          cron_expression: "0 0 * * *",
          report_language: :en,
          target_ids: [target.id],
          next_run_at: now
        },
        authorize?: false
      )

    run =
      Audits.create_audit_run_record!(
        %{
          audit_schedule_id: schedule.id,
          schedule_revision: schedule.revision,
          target_key: "target:#{target.id}",
          target_id: target.id,
          target_revision: target.revision,
          scheduled_for: now,
          status: :skipped,
          reason: "No observation"
        },
        authorize?: false
      )

    from = DateTime.add(now, -3600, :second)
    to = DateTime.add(now, 3600, :second)
    summary = Reports.period_summary!(from, to, target.id, actor: viewer)

    assert summary["case_count"] == 2
    assert summary["case_status"]["resolved"] == 1
    assert summary["case_status"]["needs_attention"] == 1
    assert summary["case_trigger"]["manual"] == 1
    assert summary["case_trigger"]["signal"] == 1

    assert %{
             "measured_cases" => 1,
             "unmeasured_resolved_cases" => 0,
             "average_seconds" => average_seconds
           } = summary["recovery"]

    assert is_integer(average_seconds) and average_seconds >= 0

    assert summary["audit_count"] == 1
    assert summary["audit_status"]["skipped"] == 1
    assert Enum.map(summary["cases"], & &1["id"]) == [resolved.id, attention.id]
    assert Enum.map(summary["audits"], & &1["id"]) == [run.id]
    assert summary["audits"] |> hd() |> Map.fetch!("reason") == "No observation"
    assert [%{"cases" => 2, "audits" => 1}] = summary["daily"]

    empty = Reports.period_summary!(DateTime.add(now, -7200), from, target.id, actor: viewer)
    assert empty["case_count"] == 0
    assert empty["audit_count"] == 0
    assert empty["daily"] == []

    assert {:error, _error} = Reports.period_summary(to, from, target.id, actor: viewer)
  end

  test "period summary counts beyond one source page while marking visible sources as limited" do
    admin = Accounts.bootstrap!("period-pages-admin@example.com", @password, @password)
    from = DateTime.utc_now() |> DateTime.add(-600, :second)

    for index <- 1..101 do
      Cases.open_case!(
        :manual,
        "period-pages",
        "case-#{index}",
        "Period Case #{index}",
        :warning,
        %{"desired_outcome" => "Target responds as expected"},
        nil,
        :en,
        actor: admin
      )
    end

    to = DateTime.utc_now() |> DateTime.add(600, :second)
    summary = Reports.period_summary!(from, to, nil, actor: admin)

    assert summary["case_count"] == 101
    assert summary["case_status"]["running"] == 101
    assert summary["case_trigger"]["manual"] == 101
    assert summary["case_sources_truncated"]
    assert length(summary["cases"]) == 100

    assert Enum.map(summary["cases"], & &1["opened_at"]) ==
             Enum.sort(Enum.map(summary["cases"], & &1["opened_at"]))
  end
end
