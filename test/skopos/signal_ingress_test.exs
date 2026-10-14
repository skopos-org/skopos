defmodule Skopos.SignalIngressTest do
  use Skopos.DataCase, async: false

  import Ecto.Query
  import Phoenix.ConnTest
  import Plug.Conn, only: [put_req_header: 3]

  @endpoint SkoposWeb.Endpoint

  alias Skopos.{Accounts, Cases, Providers, Signals, Targets}

  alias Skopos.Cases.Turn.ResolverDelivery, as: ResolverDelivery
  alias Skopos.Cases.Turn.ResolverProjection, as: ResolverProjection
  alias Skopos.Cases.Case.ConditionContext, as: ConditionContext
  alias Skopos.Cases.Case.Realtime

  alias Skopos.Cases.Case.DecisionRouteWorker
  alias Skopos.Providers.{AI, Signal}
  alias Skopos.Repo
  alias Skopos.Cases.Case.RecoveryRecheckWorker, as: RecoveryRecheckWorker

  @password "correct horse battery staple"

  setup do
    admin =
      Accounts.bootstrap!("signal-ingress-admin@example.com", @password, @password,
        authorize?: true
      )

    provider =
      Providers.create_provider!(
        "signal-ingress-provider",
        :signal,
        "fixture-signal",
        %{"source" => "test-monitor"},
        %{"secret" => "signal-secret"},
        actor: admin
      )
      |> then(&Providers.check_provider!(&1.id, 1, %{}, actor: admin))
      |> then(&Providers.enable_provider!(&1, 1, actor: admin))

    %{admin: admin, provider: provider}
  end

  test "Signal source names cannot be mistaken for operation or verification receipts", context do
    enable_signal_automation!(context.admin)
    now = DateTime.utc_now()

    for source <- ["operation", "verification"] do
      provider = signal_provider!(context.admin, source)
      ingest_one!(provider, "source-name-#{source}", :firing, now)

      evidence = Cases.list_evidence!(actor: context.admin) |> Enum.find(&(&1.source == source))
      assert evidence.kind == "signal_event"
      assert evidence.source_ref == "same-alert"
      assert evidence.content["state"] == "firing"
    end
  end

  test "active Signal admission cannot persist without its initial Case dispatch job", context do
    enable_signal_automation!(context.admin)
    now = DateTime.utc_now()
    payload = envelope("dispatch-job-persistence", now)

    incoming =
      invocation("dispatch-job-persistence", [
        event("dispatch-job-persistence", "alert", :firing, now)
      ])

    Repo.query!("""
    CREATE FUNCTION pg_temp.reject_signal_dispatch() RETURNS trigger LANGUAGE plpgsql AS $$
    BEGIN
      IF NEW.worker = 'Skopos.Cases.CaseDispatch.Worker' THEN RETURN NULL; END IF;
      RETURN NEW;
    END;
    $$;
    """)

    Repo.query!("""
    CREATE TRIGGER reject_signal_dispatch BEFORE INSERT ON oban_jobs
    FOR EACH ROW EXECUTE FUNCTION pg_temp.reject_signal_dispatch()
    """)

    assert {:error, _error} =
             Signals.ingest_signal(
               context.provider.id,
               context.provider.revision,
               payload,
               incoming
             )

    assert Cases.list_cases!(actor: context.admin) == []
    assert Cases.list_resolution_runs!(actor: context.admin) == []
    assert Cases.list_case_events!(actor: context.admin) == []
    assert Signals.list_conditions!(actor: context.admin) == []
    assert Signals.list_signal_events!(actor: context.admin) == []
    assert Signals.list_signal_receipts!(actor: context.admin) == []

    Repo.query!("DROP TRIGGER reject_signal_dispatch ON oban_jobs")

    accepted = ingest!(context.provider, payload, incoming)
    assert ingest!(context.provider, payload, incoming).id == accepted.id
    assert [incident] = Cases.list_cases!(actor: context.admin)
    assert Cases.case_dispatch!(incident.id, authorize?: false).state == :collecting

    assert [job] =
             Repo.all(Oban.Job)
             |> Enum.filter(&(&1.worker == "Skopos.Cases.CaseDispatch.Worker"))

    assert job.args == %{"case_id" => incident.id}
    assert is_integer(job.id)
    assert length(Signals.list_conditions!(actor: context.admin)) == 1
    assert length(Signals.list_signal_receipts!(actor: context.admin)) == 1
  end

  test "authenticated firing resolves only an exact registered identity and starts one Case",
       context do
    Accounts.change_preferred_language!(context.admin, :ja, actor: context.admin)
    enable_signal_automation!(context.admin)

    target = Targets.create_target!("linux-01", "host", "linux", %{}, nil, actor: context.admin)

    Targets.create_external_identity!(
      target.id,
      "test-monitor",
      "hostname",
      "linux-01",
      actor: context.admin
    )

    occurred_at = DateTime.utc_now()

    invocation =
      invocation("receipt-1", [
        event("receipt-1", "disk-errors", :firing, occurred_at,
          target_ref: %{kind: :hostname, value: "linux-01"},
          attributes: %{"title" => "Disk errors", "severity" => "critical"}
        )
      ])

    first = ingest!(context.provider, envelope("first", occurred_at), invocation)
    replay = ingest!(context.provider, envelope("first", occurred_at), invocation)

    assert first.id == replay.id
    assert first.event_count == 1

    [signal_event] = Signals.list_signal_events!(actor: context.admin)
    incident = Cases.get_case!(signal_event.case_id, actor: context.admin)

    assert signal_event.target_id == target.id
    assert incident.selected_target_id == target.id
    assert incident.selected_target_revision == target.revision
    assert incident.current_owner_id == context.admin.id
    assert incident.title == "Disk errors"
    assert incident.severity == :critical
    assert incident.status == :running
    assert incident.report_language == :ja

    Accounts.change_preferred_language!(context.admin, :en, actor: context.admin)
    assert Cases.get_case!(incident.id, actor: context.admin).report_language == :ja

    assert length(Signals.list_signal_receipts!(actor: context.admin)) == 1
    assert length(Signals.list_signal_events!(actor: context.admin)) == 1
    [condition] = Signals.list_conditions!(actor: context.admin)
    assert condition.state == :firing
    assert condition.target_id == target.id
    assert condition.occurrence == 1
    assert signal_event.condition_id == condition.id
    assert Cases.list_turns!(actor: context.admin) == []
    assert {:ok, %{state: :collecting}} = Cases.case_dispatch(incident.id, authorize?: false)
    assert length(Cases.list_evidence!(actor: context.admin)) == 1
  end

  test "a pending manual dispatch never absorbs a nearby native Signal", context do
    enable_signal_automation!(context.admin)

    target =
      Targets.create_target!("shared-host", "host", "linux", %{}, nil, actor: context.admin)

    Targets.create_external_identity!(
      target.id,
      "test-monitor",
      "hostname",
      "shared-host",
      actor: context.admin
    )

    manual =
      Cases.open_case!(
        :manual,
        "api",
        "manual-shared-host",
        "Investigate shared host",
        :warning,
        %{"desired_outcome" => "Target responds as expected"},
        target.id,
        :en,
        actor: context.admin
      )

    assert Cases.case_dispatch!(manual.id, authorize?: false).state == :collecting
    received_at = DateTime.add(DateTime.utc_now(), -1, :second)

    ingest!(
      context.provider,
      envelope("manual-nearby-signal", received_at),
      invocation("manual-nearby-signal", [
        event("manual-nearby-signal", "disk-errors", :firing, received_at,
          target_ref: %{kind: :hostname, value: "shared-host"}
        )
      ])
    )

    cases = Cases.list_cases!(actor: context.admin)
    assert length(cases) == 2
    signal_case = Enum.find(cases, &(&1.trigger_kind == :signal))
    assert signal_case.id != manual.id
    assert [membership] = Cases.active_conditions_for_case!(signal_case.id, authorize?: false)
    assert membership.case_id == signal_case.id
    assert Cases.active_conditions_for_case!(manual.id, authorize?: false) == []
  end

  test "one grouped receipt persists separate source events and opens only firing Cases",
       context do
    enable_signal_automation!(context.admin)
    occurred_at = DateTime.utc_now()

    ingest!(
      context.provider,
      envelope("group", occurred_at),
      invocation("group-receipt", [
        event("group-receipt", "alert-a", :firing, occurred_at),
        event("group-receipt", "alert-b", :recovered, occurred_at)
      ])
    )

    events = Signals.list_signal_events!(actor: context.admin)
    cases = Cases.list_cases!(actor: context.admin)

    assert Enum.map(events, &{&1.event_key, &1.state}) |> Enum.sort() == [
             {"alert-a", :firing},
             {"alert-b", :recovered}
           ]

    assert [%{id: case_id}] = cases
    assert [membership] = Cases.active_conditions_for_case!(case_id, authorize?: false)
    assert membership.condition_id == Enum.find(events, &(&1.event_key == "alert-a")).condition_id
    assert Enum.find(events, &(&1.event_key == "alert-a")).case_id == hd(cases).id
    assert is_nil(Enum.find(events, &(&1.event_key == "alert-b")).case_id)
  end

  test "current native Condition Evidence can select its mapped Target without a catalog search",
       context do
    enable_signal_automation!(context.admin)

    targets =
      for name <- ["primary-host", "related-host"], into: %{} do
        target = Targets.create_target!(name, "host", "linux", %{}, nil, actor: context.admin)

        Targets.create_external_identity!(target.id, "test-monitor", "hostname", name,
          actor: context.admin
        )

        {name, target}
      end

    Targets.create_relationship!(
      targets["primary-host"].id,
      targets["related-host"].id,
      "connected_to",
      %{},
      nil,
      actor: context.admin
    )

    at = DateTime.add(DateTime.utc_now(), -10, :second)

    events =
      for name <- ["primary-host", "related-host"] do
        event("mapped-target-selection", name, :firing, at,
          target_ref: %{kind: :hostname, value: name}
        )
      end

    ingest!(
      context.provider,
      envelope("mapped-target-selection", at),
      invocation("mapped-target-selection", events)
    )

    [incident] = Cases.list_cases!(actor: context.admin)
    run = Cases.active_resolution_run!(incident.id, authorize?: false)
    target = targets["related-host"]

    [source] =
      Cases.signal_context_evidence!(incident.id, authorize?: false)
      |> Enum.filter(fn item ->
        {:ok, condition} = Signals.get_condition(item.content["condition_id"], authorize?: false)
        condition.target_id == target.id
      end)

    selected =
      Cases.select_case_target!(
        incident.id,
        incident.revision,
        run.id,
        [source.id],
        target.id,
        target.revision,
        "Inspect the mapped related Target",
        "mapped-target-selection",
        actor: context.admin
      )

    assert selected.selected_target_id == target.id

    recovered_at = DateTime.utc_now()

    ingest!(
      context.provider,
      envelope("mapped-target-recovered", recovered_at),
      invocation("mapped-target-recovered", [
        event("mapped-target-recovered", "related-host", :recovered, recovered_at,
          target_ref: %{kind: :hostname, value: "related-host"}
        )
      ])
    )

    assert {:error, _stale} =
             Cases.select_case_target(
               selected.id,
               selected.revision,
               run.id,
               [source.id],
               target.id,
               target.revision,
               "Old source Evidence cannot select a Target",
               "mapped-target-selection-stale",
               actor: context.admin
             )
  end

  test "a current recovery event durably starts one Resolver recheck after the first Turn",
       context do
    enable_signal_automation!(context.admin)
    at = DateTime.add(DateTime.utc_now(), -10, :second)

    ingest!(
      context.provider,
      envelope("recheck-firing", at),
      invocation("recheck-firing", [event("recheck-firing", "native-fault", :firing, at)])
    )

    [incident] = Cases.list_cases!(actor: context.admin)
    assert %{status: :sent} = Cases.send_initial_case_turn!(incident.id, authorize?: false)
    run = Cases.active_resolution_run!(incident.id, authorize?: false)
    [first_turn] = Cases.started_turns_for_run!(run.id, authorize?: false)

    Cases.complete_turn!(
      first_turn.id,
      first_turn.revision,
      %{"outcome" => "test_no_decision"},
      :none,
      %{},
      "Review Resolver limits",
      authorize?: false
    )

    recovered_at = DateTime.utc_now()

    ingest!(
      context.provider,
      envelope("recheck-recovered", recovered_at),
      invocation("recheck-recovered", [
        event("recheck-recovered", "native-fault", :recovered, recovered_at)
      ])
    )

    worker = Oban.Worker.to_string(RecoveryRecheckWorker)

    assert [_job] =
             Repo.all(
               from job in Oban.Job,
                 where: job.worker == ^worker and job.args["case_id"] == ^incident.id
             )

    assert Cases.get_case!(incident.id, authorize?: false).pending_intent == %{}
    assert :ok = RecoveryRecheckWorker.perform(%Oban.Job{args: %{"case_id" => incident.id}})
    assert [recheck_turn] = Cases.started_turns_for_run!(run.id, authorize?: false)
    assert recheck_turn.intent["source"] == "signal_recheck"

    assert {:snooze, 5} =
             RecoveryRecheckWorker.perform(%Oban.Job{args: %{"case_id" => incident.id}})

    assert length(Cases.list_turns!(actor: context.admin)) == 2

    Cases.complete_turn!(
      recheck_turn.id,
      recheck_turn.revision,
      %{"outcome" => "test_no_decision"},
      :none,
      %{},
      "Review Resolver limits",
      authorize?: false
    )

    current = Cases.get_case!(incident.id, authorize?: false)

    Cases.record_case_pending_intent!(current, current.revision, %{}, authorize?: false)

    assert Cases.get_case!(incident.id, authorize?: false).pending_intent == %{}
    assert :ok = RecoveryRecheckWorker.perform(%Oban.Job{args: %{"case_id" => incident.id}})
    assert length(Cases.list_turns!(actor: context.admin)) == 2

    refute Cases.get_case!(incident.id, authorize?: false).pending_intent["turn_id"] ==
             recheck_turn.id
  end

  test "recovery receipt requires a persisted recheck before accepting recovered state",
       context do
    enable_signal_automation!(context.admin)
    firing_at = DateTime.add(DateTime.utc_now(), -10, :second)
    ingest_one!(context.provider, "missing-recheck-firing", :firing, firing_at)
    [incident] = Cases.list_cases!(actor: context.admin)
    before_conditions = Signals.list_conditions!(actor: context.admin)
    before_events = Signals.list_signal_events!(actor: context.admin)
    before_evidence = Cases.list_evidence!(actor: context.admin)
    recovered_at = DateTime.utc_now()
    payload = envelope("missing-recheck-recovered", recovered_at)

    incoming =
      invocation("missing-recheck-recovered", [
        event("missing-recheck-recovered", "same-alert", :recovered, recovered_at)
      ])

    Repo.query!("""
    CREATE FUNCTION pg_temp.reject_recovery_recheck_job() RETURNS trigger LANGUAGE plpgsql AS $$
    BEGIN
      IF NEW.worker = 'Skopos.Cases.Case.RecoveryRecheckWorker' THEN RETURN NULL; END IF;
      RETURN NEW;
    END;
    $$;
    """)

    Repo.query!("""
    CREATE TRIGGER reject_recovery_recheck_job BEFORE INSERT ON oban_jobs
    FOR EACH ROW EXECUTE FUNCTION pg_temp.reject_recovery_recheck_job()
    """)

    assert {:error, _error} =
             Signals.ingest_signal(
               context.provider.id,
               context.provider.revision,
               payload,
               incoming
             )

    assert Signals.list_conditions!(actor: context.admin) == before_conditions
    assert Signals.list_signal_events!(actor: context.admin) == before_events
    assert Cases.list_evidence!(actor: context.admin) == before_evidence
    assert length(Signals.list_signal_receipts!(actor: context.admin)) == 1

    Repo.query!("DROP TRIGGER reject_recovery_recheck_job ON oban_jobs")

    receipt = ingest!(context.provider, payload, incoming)
    assert ingest!(context.provider, payload, incoming).id == receipt.id
    assert [condition] = Signals.list_conditions!(actor: context.admin)
    assert condition.state == :recovered
    worker = Oban.Worker.to_string(RecoveryRecheckWorker)

    assert [job] =
             Repo.all(
               from job in Oban.Job,
                 where: job.worker == ^worker and job.args["case_id"] == ^incident.id
             )

    assert is_integer(job.id)
    assert length(Signals.list_signal_receipts!(actor: context.admin)) == 2
    assert length(Signals.list_signal_events!(actor: context.admin)) == 2
    refute_receive {:resolve, _, _}
    refute_receive {:effect, _, _}
  end

  test "twenty native recoveries coalesce into one Case-bound recheck", context do
    enable_signal_automation!(context.admin)

    target =
      Targets.create_target!("coalesced-host", "host", "linux", %{}, nil, actor: context.admin)

    Targets.create_external_identity!(
      target.id,
      "test-monitor",
      "hostname",
      "coalesced-host",
      actor: context.admin
    )

    firing_at = DateTime.add(DateTime.utc_now(), -10, :second)
    target_ref = %{kind: :hostname, value: "coalesced-host"}

    firing =
      for index <- 1..20 do
        event("coalesced-firing", "fault-#{index}", :firing, firing_at, target_ref: target_ref)
      end

    ingest!(
      context.provider,
      envelope("coalesced-firing", firing_at),
      invocation("coalesced-firing", firing)
    )

    [incident] = Cases.list_cases!(actor: context.admin)
    assert length(Cases.active_conditions_for_case!(incident.id, authorize?: false)) == 20
    assert %{status: :sent} = Cases.send_initial_case_turn!(incident.id, authorize?: false)

    run = Cases.active_resolution_run!(incident.id, authorize?: false)
    [initial] = Cases.started_turns_for_run!(run.id, authorize?: false)

    Cases.complete_turn!(
      initial.id,
      initial.revision,
      %{"outcome" => "test_no_decision"},
      :none,
      %{},
      "Review Resolver limits",
      authorize?: false
    )

    recovered_at = DateTime.utc_now()

    recovered =
      for index <- 1..20 do
        event("coalesced-recovered", "fault-#{index}", :recovered, recovered_at,
          target_ref: target_ref
        )
      end

    ingest!(
      context.provider,
      envelope("coalesced-recovered", recovered_at),
      invocation("coalesced-recovered", recovered)
    )

    worker = Oban.Worker.to_string(RecoveryRecheckWorker)

    jobs =
      Repo.all(
        from job in Oban.Job,
          where: job.worker == ^worker and job.args["case_id"] == ^incident.id
      )

    assert length(jobs) == 1
    assert :ok = RecoveryRecheckWorker.perform(%Oban.Job{args: %{"case_id" => incident.id}})
    assert [recheck] = Cases.started_turns_for_run!(run.id, authorize?: false)
    assert recheck.intent["source"] == "signal_recheck"
    assert length(recheck.intent["condition_revisions"]) == 20

    assert {:snooze, 5} =
             RecoveryRecheckWorker.perform(%Oban.Job{args: %{"case_id" => incident.id}})

    assert length(Cases.list_turns!(actor: context.admin)) == 2
  end

  test "rolled-back recovery receipt does not leave a recheck job or lose retry", context do
    enable_signal_automation!(context.admin)
    firing_at = DateTime.add(DateTime.utc_now(), -10, :second)

    ingest_one!(context.provider, "rollback-recheck-firing", :firing, firing_at)
    [incident] = Cases.list_cases!(actor: context.admin)
    assert %{status: :sent} = Cases.send_initial_case_turn!(incident.id, authorize?: false)
    run = Cases.active_resolution_run!(incident.id, authorize?: false)
    [initial] = Cases.started_turns_for_run!(run.id, authorize?: false)

    Cases.complete_turn!(
      initial.id,
      initial.revision,
      %{"outcome" => "test_no_decision"},
      :none,
      %{},
      "Review Resolver limits",
      authorize?: false
    )

    incident_id = incident.id
    :ok = Realtime.subscribe(incident_id)
    recovered_at = DateTime.utc_now()

    recover = fn ->
      ingest_one!(context.provider, "rollback-recheck-recovered", :recovered, recovered_at)
    end

    assert {:error, :simulated_persistence_failure} =
             Repo.transaction(fn ->
               recover.()
               Repo.rollback(:simulated_persistence_failure)
             end)

    worker = Oban.Worker.to_string(RecoveryRecheckWorker)

    assert Repo.all(
             from job in Oban.Job,
               where: job.worker == ^worker and job.args["case_id"] == ^incident.id
           ) == []

    [condition] = Signals.list_conditions!(actor: context.admin)
    assert condition.state == :firing
    refute_receive {:case_changed, ^incident_id}, 20

    recover.()

    assert_receive {:case_changed, ^incident_id}

    assert [_job] =
             Repo.all(
               from job in Oban.Job,
                 where: job.worker == ^worker and job.args["case_id"] == ^incident.id
             )

    assert :ok = RecoveryRecheckWorker.perform(%Oban.Job{args: %{"case_id" => incident.id}})
    assert [recheck] = Cases.started_turns_for_run!(run.id, authorize?: false)
    assert recheck.intent["source"] == "signal_recheck"
  end

  test "same Target alerts share a provisional Case while retaining separate Conditions",
       context do
    enable_signal_automation!(context.admin)

    target =
      Targets.create_target!("same-target", "host", "linux", %{}, nil, actor: context.admin)

    Targets.create_external_identity!(
      target.id,
      "test-monitor",
      "hostname",
      "same-target",
      actor: context.admin
    )

    second_provider = signal_provider!(context.admin, "separate-monitor")

    Targets.create_external_identity!(
      target.id,
      "separate-monitor",
      "hostname",
      "same-target",
      actor: context.admin
    )

    occurred_at = DateTime.utc_now()
    attributes = %{"title" => "Identical alert title"}

    ingest!(
      context.provider,
      envelope("separate-a", occurred_at),
      invocation("separate-a", [
        event("separate-a", "event-a", :firing, occurred_at,
          target_ref: %{kind: :hostname, value: "same-target"},
          attributes: attributes
        )
      ])
    )

    ingest!(
      second_provider,
      envelope("separate-b", occurred_at),
      invocation("separate-b", [
        event("separate-b", "event-b", :firing, occurred_at,
          target_ref: %{kind: :hostname, value: "same-target"},
          attributes: attributes
        )
      ])
    )

    assert [incident] = Cases.list_cases!(actor: context.admin)
    assert length(Signals.list_conditions!(actor: context.admin)) == 2
    assert length(Cases.active_conditions_for_case!(incident.id, authorize?: false)) == 2
    assert Cases.list_turns!(actor: context.admin) == []
  end

  test "a due provisional Case starts one initial Resolver Turn for its Conditions", context do
    enable_signal_automation!(context.admin)
    received_at = DateTime.add(DateTime.utc_now(), -10, :second)

    ingest!(
      context.provider,
      envelope("due-case", received_at),
      invocation("due-case", [event("due-case", "disk-errors", :firing, received_at)])
    )

    [incident] = Cases.list_cases!(actor: context.admin)
    assert Cases.list_turns!(actor: context.admin) == []
    job = %Oban.Job{args: %{"case_id" => incident.id}}

    assert :ok = Skopos.Cases.CaseDispatch.Worker.perform(job)
    assert :ok = Skopos.Cases.CaseDispatch.Worker.perform(job)
    assert length(Cases.list_turns!(actor: context.admin)) == 1
    assert {:ok, %{state: :sent}} = Cases.case_dispatch(incident.id, authorize?: false)
  end

  test "first-event collection windows group only arrivals before their fixed deadline",
       context do
    enable_signal_automation!(context.admin)
    original_window = Application.fetch_env!(:skopos, :case_collect_seconds)
    on_exit(fn -> Application.put_env(:skopos, :case_collect_seconds, original_window) end)

    for window <- [0, 5, 10, 30] do
      Application.put_env(:skopos, :case_collect_seconds, window)
      names = Enum.map(1..4, &"window-#{window}-#{&1}")

      for name <- names do
        target = Targets.create_target!(name, "host", "linux", %{}, nil, actor: context.admin)

        Targets.create_external_identity!(target.id, "test-monitor", "hostname", name,
          actor: context.admin
        )
      end

      targets = Targets.list_targets!(actor: context.admin) |> Map.new(&{&1.name, &1.id})

      for name <- tl(names) do
        Targets.create_relationship!(targets[hd(names)], targets[name], "connected_to", %{}, nil,
          actor: context.admin
        )
      end

      before_ids = Cases.list_cases!(actor: context.admin) |> MapSet.new(& &1.id)
      first_at = DateTime.add(DateTime.utc_now(), -400, :second)
      offsets = [0, max(window - 1, 0), 60, 300]

      for {name, offset} <- Enum.zip(names, offsets) do
        at = DateTime.add(first_at, offset, :second)

        ingest!(
          context.provider,
          envelope(name, at),
          invocation(name, [
            event(name, name, :firing, at, target_ref: %{kind: :hostname, value: name})
          ])
        )
      end

      new_cases =
        Cases.list_cases!(actor: context.admin)
        |> Enum.reject(&MapSet.member?(before_ids, &1.id))

      assert length(new_cases) == if(window == 0, do: 4, else: 3)

      first_case =
        Enum.find(new_cases, fn incident ->
          incident.initial_target_id == targets[hd(names)]
        end)

      assert {:ok, dispatch} = Cases.case_dispatch(first_case.id, authorize?: false)
      assert dispatch.due_at == DateTime.add(first_at, window, :second)

      assert length(Cases.active_conditions_for_case!(first_case.id, authorize?: false)) ==
               if(window == 0, do: 1, else: 2)

      for incident <- new_cases do
        assert :ok =
                 Skopos.Cases.CaseDispatch.Worker.perform(%Oban.Job{
                   args: %{"case_id" => incident.id}
                 })

        assert length(
                 Cases.started_turns_for_run!(
                   Cases.active_resolution_run!(incident.id, authorize?: false).id,
                   authorize?: false
                 )
               ) == 1
      end
    end
  end

  test "concurrent receipts admitted out of timestamp order share only the bounded window",
       context do
    enable_signal_automation!(context.admin)
    names = ["ordered-first", "earlier-in-flight", "too-early"]

    targets =
      for name <- names, into: %{} do
        target = Targets.create_target!(name, "host", "linux", %{}, nil, actor: context.admin)

        Targets.create_external_identity!(target.id, "test-monitor", "hostname", name,
          actor: context.admin
        )

        {name, target.id}
      end

    for name <- tl(names) do
      Targets.create_relationship!(targets[hd(names)], targets[name], "connected_to", %{}, nil,
        actor: context.admin
      )
    end

    first_at = DateTime.add(DateTime.utc_now(), -40, :second)

    for {name, at} <- [
          {"ordered-first", first_at},
          {"earlier-in-flight", DateTime.add(first_at, -1, :millisecond)},
          {"too-early", DateTime.add(first_at, -6, :second)}
        ] do
      ingest!(
        context.provider,
        envelope(name, at),
        invocation(name, [
          event(name, name, :firing, at, target_ref: %{kind: :hostname, value: name})
        ])
      )
    end

    cases = Cases.list_cases!(actor: context.admin)
    assert length(cases) == 2

    first = Enum.find(cases, &(&1.initial_target_id == targets["ordered-first"]))
    assert length(Cases.active_conditions_for_case!(first.id, authorize?: false)) == 2
  end

  @tag condition_membership_capacity: true
  test "Case reads preserve the largest native membership set and larger stored sets", context do
    enable_signal_automation!(context.admin)

    target =
      Targets.create_target!("capacity-host", "host", "linux", %{}, nil, actor: context.admin)

    Targets.create_external_identity!(target.id, "test-monitor", "hostname", "capacity-host",
      actor: context.admin
    )

    at = DateTime.add(DateTime.utc_now(), -10, :second)

    events =
      for index <- 1..33 do
        event("membership-capacity", "service-#{index}", :firing, at,
          target_ref: %{kind: :hostname, value: "capacity-host"},
          attributes: %{
            "labels" => %{"service" => "service-#{index}", "alertname" => "ServiceUnavailable"}
          }
        )
      end

    ingest!(
      context.provider,
      envelope("membership-capacity", at),
      invocation("membership-capacity", events)
    )

    cases = Cases.list_cases!(actor: context.admin)
    assert length(cases) == 2

    memberships =
      Enum.map(cases, &{&1, Cases.active_conditions_for_case!(&1.id, authorize?: false)})

    assert Enum.sort(Enum.map(memberships, fn {_incident, members} -> length(members) end)) == [
             1,
             32
           ]

    {incident, members} =
      Enum.find(memberships, fn {_incident, members} -> length(members) == 32 end)

    ids = MapSet.new(members, & &1.condition_id)

    native_event =
      Enum.find(
        Signals.list_signal_events!(actor: context.admin),
        &MapSet.member?(ids, &1.condition_id)
      )

    original = Enum.find(events, &(&1.event_key == native_event.event_key))
    recovery_at = DateTime.add(at, 1, :second)

    recovered = %{
      original
      | receipt_id: "membership-recovery",
        state: :recovered,
        occurred_at: recovery_at
    }

    ingest!(
      context.provider,
      envelope("membership-recovery", recovery_at),
      invocation("membership-recovery", [recovered])
    )

    assert :ok = dispatch_initial!(incident)

    [turn] =
      Cases.started_turns_for_run!(
        Cases.active_resolution_run!(incident.id, authorize?: false).id,
        authorize?: false
      )

    selection = %AI.Selection{
      role: :resolver,
      provider_id: Ecto.UUID.generate(),
      provider_revision: 1,
      source: :assignment
    }

    assert {:ok, request, _context} = ResolverProjection.build(turn.id, selection)
    assert length(request.conditions) == 32
    assert MapSet.new(request.conditions, & &1.id) == ids
    assert Enum.count(request.conditions, &(&1.state == :firing)) == 31
    assert Enum.count(request.conditions, &(&1.state == :recovered)) == 1

    handler = {__MODULE__, make_ref()}
    Process.put(:capacity_query_count, 0)
    Process.put(:capacity_condition_query_count, 0)

    :ok =
      :telemetry.attach(
        handler,
        [:skopos, :repo, :query],
        fn _event, _measurements, metadata, _config ->
          if Process.get(:count_capacity_reads) do
            Process.put(:capacity_query_count, Process.get(:capacity_query_count) + 1)

            if String.contains?(metadata.query, "FROM \"conditions\"") do
              Process.put(
                :capacity_condition_query_count,
                Process.get(:capacity_condition_query_count) + 1
              )
            end
          end
        end,
        nil
      )

    try do
      for {count, kind} <- [{32, "native"}, {102, "internal-record extension"}] do
        if count == 102 do
          # These additional recovered obligations are read-capacity fixtures, not native admission.
          source = Signals.get_condition!(native_event.condition_id, authorize?: false)

          inputs =
            Map.take(source, Ash.Resource.Info.action(source.__struct__, :create_record).accept)

          for index <- 1..70 do
            condition =
              Signals.create_condition_record!(
                Map.merge(inputs, %{
                  occurrence: index + 1000,
                  predicate: "Stored obligation #{index}",
                  subject_key: "stored-obligation-#{index}",
                  subject_ref: %{},
                  state: :recovered
                }),
                authorize?: false
              )

            Cases.attach_case_condition_record!(
              %{
                case_id: incident.id,
                condition_id: condition.id,
                attached_at: at,
                reason: "Read capacity fixture"
              },
              authorize?: false
            )
          end
        end

        Process.put(:capacity_query_count, 0)
        Process.put(:capacity_condition_query_count, 0)
        :erlang.garbage_collect()
        {:memory, before_memory} = Process.info(self(), :memory)
        started = System.monotonic_time(:microsecond)
        Process.put(:count_capacity_reads, true)
        assert {:ok, snapshot} = Cases.case_reconnect_snapshot(incident.id, actor: context.admin)
        Process.put(:count_capacity_reads, false)
        elapsed = System.monotonic_time(:microsecond) - started
        {:memory, after_memory} = Process.info(self(), :memory)
        assert length(snapshot.conditions) == count
        assert snapshot.case.condition_count == count
        assert snapshot.case.firing_condition_count == 31
        assert Enum.all?(snapshot.conditions, &(&1.condition.revision >= 1))
        assert MapSet.subset?(ids, MapSet.new(snapshot.conditions, & &1.condition.id))
        assert Process.get(:capacity_condition_query_count) <= 2

        token = api_token!(context.admin.email)
        public_snapshot = api_get_data!("/api/v1/cases/#{incident.id}", token)
        assert length(public_snapshot["conditions"]) == count
        assert public_snapshot["case"]["condition_count"] == count
        assert public_snapshot["case"]["firing_condition_count"] == 31
        refute Map.has_key?(public_snapshot, "condition_history")

        IO.puts(
          "Condition read measurement " <>
            Jason.encode!(%{
              kind: kind,
              count: count,
              sql_queries: Process.get(:capacity_query_count),
              condition_queries: Process.get(:capacity_condition_query_count),
              elapsed_us: elapsed,
              process_memory_before: before_memory,
              process_memory_after: after_memory,
              retained_term_heap_bytes:
                :erts_debug.size(snapshot) * :erlang.system_info(:wordsize),
              public_data_bytes: byte_size(Jason.encode!(public_snapshot))
            })
        )
      end
    after
      Process.put(:count_capacity_reads, false)
      :telemetry.detach(handler)
    end
  end

  @tag condition_read_frequency: true
  test "PoE and twenty AP stay together when a coincident core Condition is split",
       context do
    enable_signal_automation!(context.admin)

    names = ["poe-01" | Enum.map(1..20, &"ap-#{&1}")] ++ ["core-01"]

    targets =
      Enum.map(names, fn name ->
        target =
          Targets.create_target!(name, "network_device", "custom-network-device", %{}, nil,
            actor: context.admin
          )

        Targets.create_external_identity!(target.id, "test-monitor", "hostname", name,
          actor: context.admin
        )

        {name, target.id}
      end)
      |> Map.new()

    for name <- tl(names) do
      Targets.create_relationship!(targets["poe-01"], targets[name], "connected_to", %{}, nil,
        actor: context.admin
      )
    end

    received_at = DateTime.add(DateTime.utc_now(), -10, :second)

    events =
      Enum.map(names, fn name ->
        event("poe-star", name, :firing, received_at,
          target_ref: %{kind: :hostname, value: name},
          attributes: %{"title" => "#{name} unavailable"}
        )
      end)

    ingest!(context.provider, envelope("poe-star", received_at), invocation("poe-star", events))

    assert [incident] = Cases.list_cases!(actor: context.admin)
    assert length(Signals.list_conditions!(actor: context.admin)) == 22
    assert length(Cases.active_conditions_for_case!(incident.id, authorize?: false)) == 22
    assert Cases.list_turns!(actor: context.admin) == []

    assert :ok =
             Skopos.Cases.CaseDispatch.Worker.perform(%Oban.Job{
               args: %{"case_id" => incident.id}
             })

    [turn] = Cases.list_turns!(actor: context.admin)

    selection = %Skopos.Providers.AI.Selection{
      role: :resolver,
      provider_id: Ecto.UUID.generate(),
      provider_revision: 1,
      source: :assignment
    }

    handler = {__MODULE__, make_ref()}
    Process.put(:condition_context_read_count, 0)

    :ok =
      :telemetry.attach(
        handler,
        [:skopos, :repo, :query],
        fn _event, _measurements, metadata, _config ->
          if Process.get(:count_condition_context_reads) and
               String.contains?(metadata.query, "FROM \"conditions\"") do
            Process.put(
              :condition_context_read_count,
              Process.get(:condition_context_read_count) + 1
            )
          end
        end,
        nil
      )

    request =
      try do
        Process.put(:count_condition_context_reads, true)
        assert {:ok, request, _context} = ResolverProjection.build(turn.id, selection)
        request
      after
        Process.put(:count_condition_context_reads, false)
        :telemetry.detach(handler)
      end

    assert Process.get(:condition_context_read_count) <= 4
    assert length(request.conditions) == 22
    assert request.conditions |> Enum.map(& &1.id) |> Enum.uniq() |> length() == 22
    assert Enum.all?(request.conditions, &(&1.state == :firing and &1.revision == 1))

    assert request.conditions |> Enum.map(& &1.target_id) |> Enum.sort() ==
             targets |> Map.values() |> Enum.sort()

    assert Enum.count(request.evidence, &(&1.kind == "signal_event")) == 22
    assert Enum.all?(request.evidence, &is_binary(&1.content["condition_id"]))

    Repo.query!("ALTER TABLE conditions RENAME COLUMN predicate TO unavailable_predicate")

    try do
      assert {:error, error} = ResolverProjection.build(turn.id, selection)
      assert AI.Error.context_failure?(error)
      assert Exception.message(error) =~ "does not exist"
    after
      Repo.query!("ALTER TABLE conditions RENAME COLUMN unavailable_predicate TO predicate")
    end

    assert {:ok, retried_request, _context} = ResolverProjection.build(turn.id, selection)
    assert retried_request.conditions == request.conditions

    completed =
      Cases.complete_turn!(
        turn.id,
        turn.revision,
        %{
          "outcome" => "decision",
          "condition_revisions" => ConditionContext.condition_revisions(request.conditions),
          "intent" => %{"type" => "handoff", "reason" => "Check the independent core fault"}
        },
        :none,
        %{"action" => "route_resolver_decision", "turn_id" => turn.id},
        "Review the Resolver decision",
        authorize?: false
      ).value

    parent = Cases.get_case!(incident.id, authorize?: false)
    initial_run = Cases.active_resolution_run!(parent.id, authorize?: false)

    core =
      Signals.list_conditions!(actor: context.admin)
      |> Enum.find(&(&1.target_id == targets["core-01"]))

    child =
      Cases.split_case_conditions!(
        parent.id,
        parent.revision,
        [core.id],
        ConditionContext.condition_revisions(request.conditions),
        "The core has independent SSH symptoms",
        actor: context.admin
      )

    assert length(Cases.active_conditions_for_case!(parent.id, authorize?: false)) == 21

    assert [%{condition_id: core_id}] =
             Cases.active_conditions_for_case!(child.id, authorize?: false)

    assert core_id == core.id
    assert length(Cases.signal_context_evidence!(parent.id, authorize?: false)) == 21
    assert length(Cases.signal_context_evidence!(child.id, authorize?: false)) == 1

    parent_run = Cases.active_resolution_run!(parent.id, authorize?: false)
    child_run = Cases.active_resolution_run!(child.id, authorize?: false)

    assert parent_run.max_ai_usage_units + child_run.max_ai_usage_units ==
             initial_run.max_ai_usage_units

    assert parent_run.deadline_at == child_run.deadline_at
    assert length(Cases.started_turns_for_run!(parent_run.id, authorize?: false)) == 1
    assert length(Cases.started_turns_for_run!(child_run.id, authorize?: false)) == 1

    assert Cases.get_case!(parent.id, authorize?: false).status == :running

    assert :ok = DecisionRouteWorker.perform(%Oban.Job{args: %{"turn_id" => completed.id}})
    assert length(Cases.list_turns!(actor: context.admin)) == 3
  end

  test "an explicit cited Resolver split moves native Conditions through the Case action",
       context do
    enable_signal_automation!(context.admin)

    targets =
      for name <- ["poe-switch", "unrelated-core"], into: %{} do
        target =
          Targets.create_target!(name, "network_device", "custom-network-device", %{}, nil,
            actor: context.admin
          )

        Targets.create_external_identity!(target.id, "test-monitor", "hostname", name,
          actor: context.admin
        )

        {name, target}
      end

    Targets.create_relationship!(
      targets["poe-switch"].id,
      targets["unrelated-core"].id,
      "connected_to",
      %{},
      nil,
      actor: context.admin
    )

    at = DateTime.add(DateTime.utc_now(), -10, :second)

    events =
      for name <- ["poe-switch", "unrelated-core"] do
        event("independent-faults", name, :firing, at,
          target_ref: %{kind: :hostname, value: name},
          attributes: %{"title" => "#{name} unreachable"}
        )
      end

    ingest!(
      context.provider,
      envelope("independent-faults", at),
      invocation("independent-faults", events)
    )

    [parent] = Cases.list_cases!(actor: context.admin)
    assert %{status: :sent} = Cases.send_initial_case_turn!(parent.id, authorize?: false)
    run = Cases.active_resolution_run!(parent.id, authorize?: false)
    [turn] = Cases.started_turns_for_run!(run.id, authorize?: false)
    {:ok, revisions} = ConditionContext.current_condition_revisions(parent)

    selection = %AI.Selection{
      role: :resolver,
      provider_id: Ecto.UUID.generate(),
      provider_revision: 1,
      source: :assignment
    }

    assert {:ok, request, _context} = ResolverProjection.build(turn.id, selection)

    assert MapSet.new(Enum.map(request.target_candidates, & &1.id)) ==
             MapSet.new(
               Map.values(targets)
               |> Enum.map(& &1.id)
               |> Enum.reject(&(&1 == parent.selected_target_id))
             )

    for candidate <- request.target_candidates do
      assert AI.target_candidate_evidence_ids(request, candidate.id) != []
    end

    groups =
      for name <- ["unrelated-core", "poe-switch"] do
        condition =
          Signals.list_conditions!(actor: context.admin)
          |> Enum.find(&(&1.target_id == targets[name].id))

        observation =
          Cases.create_evidence_record!(
            %{
              case_id: parent.id,
              resolution_run_id: run.id,
              turn_id: turn.id,
              idempotency_key: "group-observation:#{name}",
              kind: "observation",
              source: "target",
              source_ref: name,
              content: %{
                "target_id" => targets[name].id,
                "status" => "applied",
                "facts" => %{"reachability" => "down"}
              },
              observed_at: DateTime.utc_now()
            },
            authorize?: false
          )

        %{
          "condition_ids" => [condition.id],
          "assessment" => "independent",
          "reason" => "Independent observed failure on #{name}",
          "evidence_ids" => [observation.id]
        }
      end

    moved_condition_id = hd(hd(groups)["condition_ids"])

    current_source =
      Cases.signal_context_evidence!(parent.id, authorize?: false)
      |> Enum.find(&(&1.content["condition_id"] == moved_condition_id))

    assert current_source.content["current"] == true

    completed =
      Cases.complete_turn!(
        turn.id,
        turn.revision,
        %{
          "outcome" => "decision",
          "condition_revisions" => revisions,
          "condition_groups" => groups,
          "intent" => %{
            "type" => "case_split",
            "condition_ids" => hd(groups)["condition_ids"],
            "evidence_ids" => hd(groups)["evidence_ids"],
            "remaining_evidence_ids" => List.last(groups)["evidence_ids"],
            "reason" => "Investigate the core fault separately"
          }
        },
        :none,
        %{"action" => "route_resolver_decision", "turn_id" => turn.id},
        "Review the Resolver decision",
        authorize?: false
      ).value

    assert :ok = DecisionRouteWorker.perform(%Oban.Job{args: %{"turn_id" => completed.id}})

    cases = Cases.list_cases!(actor: context.admin)
    assert length(cases) == 2
    original = Enum.find(cases, &(&1.id == completed.case_id))
    spawned = Enum.find(cases, &(&1.id != completed.case_id))

    assert spawned.split_parent_id == original.id
    assert length(Cases.active_conditions_for_case!(original.id, authorize?: false)) == 1
    assert length(Cases.active_conditions_for_case!(spawned.id, authorize?: false)) == 1
    assert Cases.get_resolution_run!(run.id, authorize?: false).ai_usage_units == 0
    assert :ok = DecisionRouteWorker.perform(%Oban.Job{args: %{"turn_id" => completed.id}})
    assert length(Cases.list_cases!(actor: context.admin)) == 2
  end

  test "two source alerts alone cannot authorize another AI Case branch", context do
    enable_signal_automation!(context.admin)

    targets =
      for name <- ["poe", "ap"], into: %{} do
        target =
          Targets.create_target!(name, "network_device", "custom-network-device", %{}, nil,
            actor: context.admin
          )

        Targets.create_external_identity!(target.id, "test-monitor", "hostname", name,
          actor: context.admin
        )

        {name, target}
      end

    Targets.create_relationship!(targets["poe"].id, targets["ap"].id, "connected_to", %{}, nil,
      actor: context.admin
    )

    at = DateTime.add(DateTime.utc_now(), -10, :second)

    ingest!(
      context.provider,
      envelope("source-only-split", at),
      invocation("source-only-split", [
        event("source-only-split", "poe", :firing, at,
          target_ref: %{kind: :hostname, value: "poe"}
        ),
        event("source-only-split", "ap", :firing, at, target_ref: %{kind: :hostname, value: "ap"})
      ])
    )

    [parent] = Cases.list_cases!(actor: context.admin)
    assert %{status: :sent} = Cases.send_initial_case_turn!(parent.id, authorize?: false)
    run = Cases.active_resolution_run!(parent.id, authorize?: false)
    [turn] = Cases.started_turns_for_run!(run.id, authorize?: false)
    {:ok, revisions} = ConditionContext.current_condition_revisions(parent)
    [moved | _rest] = revisions

    sources = Cases.signal_context_evidence!(parent.id, authorize?: false)
    moved_source = Enum.find(sources, &(&1.content["condition_id"] == moved["id"]))
    remaining_source = Enum.find(sources, &(&1.id != moved_source.id))
    reason = "Separate these coincident alerts"

    completed =
      Cases.complete_turn!(
        turn.id,
        turn.revision,
        %{
          "outcome" => "decision",
          "condition_revisions" => revisions,
          "intent" => %{
            "type" => "case_split",
            "condition_ids" => [moved["id"]],
            "evidence_ids" => [moved_source.id],
            "remaining_evidence_ids" => [remaining_source.id],
            "reason" => reason
          }
        },
        :none,
        %{"action" => "route_resolver_decision", "turn_id" => turn.id},
        "Review the Resolver decision",
        authorize?: false
      ).value

    assert {:error, _rejected} =
             Cases.split_case_from_resolver(
               parent.id,
               Cases.get_case!(parent.id, authorize?: false).revision,
               [moved["id"]],
               revisions,
               reason,
               completed.id,
               authorize?: false
             )

    assert length(Cases.list_cases!(actor: context.admin)) == 1
    assert length(Cases.active_conditions_for_case!(parent.id, authorize?: false)) == 2

    assert :ok = DecisionRouteWorker.perform(%Oban.Job{args: %{"turn_id" => completed.id}})
    assert Cases.get_case!(parent.id, authorize?: false).status == :running
    assert [retry_turn] = Cases.started_turns_for_run!(run.id, authorize?: false)
    assert retry_turn.intent["source"] == "resolver_split_rejected"
    assert :ok = DecisionRouteWorker.perform(%Oban.Job{args: %{"turn_id" => completed.id}})
    assert length(Cases.started_turns_for_run!(run.id, authorize?: false)) == 1
    assert length(Cases.list_cases!(actor: context.admin)) == 1
  end

  test "an explicit split moves one native Condition without minting budgets or replaying a stale route",
       context do
    enable_signal_automation!(context.admin)

    target = Targets.create_target!("split-host", "host", "linux", %{}, nil, actor: context.admin)

    Targets.create_external_identity!(
      target.id,
      "test-monitor",
      "hostname",
      "split-host",
      actor: context.admin
    )

    at = DateTime.add(DateTime.utc_now(), -10, :second)

    events =
      for key <- ["service-a", "service-b", "service-c"] do
        event("split-three", key, :firing, at,
          target_ref: %{kind: :hostname, value: "split-host"},
          attributes: %{
            "labels" => %{"alertname" => "ServiceUnavailable", "service" => "#{key}.service"}
          }
        )
      end

    ingest!(context.provider, envelope("split-three", at), invocation("split-three", events))
    [parent] = Cases.list_cases!(actor: context.admin)
    assert %{status: :sent} = Cases.send_initial_case_turn!(parent.id, authorize?: false)
    run = Cases.active_resolution_run!(parent.id, authorize?: false)
    [initial_turn] = Cases.started_turns_for_run!(run.id, authorize?: false)

    {:ok, snapshot} = ConditionContext.current_condition_revisions(parent)

    moved_id =
      Signals.list_signal_events!(actor: context.admin)
      |> Enum.find(&(&1.event_key == "service-c"))
      |> Map.fetch!(:condition_id)

    moved = Signals.get_condition!(moved_id, actor: context.admin)

    moved_source =
      Cases.signal_context_evidence!(parent.id, authorize?: false)
      |> Enum.find(&(&1.content["condition_id"] == moved.id))

    assert {:error, _running} =
             Cases.split_case_conditions(
               parent.id,
               parent.revision,
               [moved.id],
               snapshot,
               "Do not split while Resolver is running",
               actor: context.admin
             )

    assert length(Cases.active_conditions_for_case!(parent.id, authorize?: false)) == 3

    completed =
      Cases.complete_turn!(
        initial_turn.id,
        initial_turn.revision,
        %{
          "outcome" => "decision",
          "condition_revisions" => snapshot,
          "intent" => %{"type" => "handoff", "reason" => "Investigate the distinct faults"}
        },
        :none,
        %{"action" => "route_resolver_decision", "turn_id" => initial_turn.id},
        "Review the Resolver decision",
        authorize?: false
      ).value

    parent = Cases.get_case!(parent.id, authorize?: false)
    original_max = Cases.get_resolution_run!(run.id, authorize?: false).max_resolver_turns

    child =
      Cases.split_case_conditions!(
        parent.id,
        parent.revision,
        [moved.id],
        snapshot,
        "Core service has a separate failure",
        actor: context.admin
      )

    moved_id = moved.id
    assert child.split_parent_id == parent.id
    assert child.authority_mode == parent.authority_mode
    assert child.authority_setting_id == parent.authority_setting_id
    assert child.selected_target_id == target.id

    assert Cases.split_case_conditions!(
             parent.id,
             parent.revision,
             [moved.id],
             snapshot,
             "Core service has a separate failure",
             actor: context.admin
           ).id == child.id

    assert [%{condition_id: ^moved_id}] =
             Cases.active_conditions_for_case!(child.id, authorize?: false)

    assert length(Cases.active_conditions_for_case!(parent.id, authorize?: false)) == 2
    assert length(Cases.condition_membership_history!(moved.id, authorize?: false)) == 2
    assert length(Cases.signal_context_evidence!(child.id, authorize?: false)) == 1
    assert length(Cases.signal_context_evidence!(parent.id, authorize?: false)) == 2

    parent_run = Cases.active_resolution_run!(parent.id, authorize?: false)
    child_run = Cases.active_resolution_run!(child.id, authorize?: false)

    assert {:error, %Ash.Error.Changes.InvalidChanges{}} =
             Skopos.Cases.Evidence.Citation.validate(
               moved_source,
               Cases.get_case!(parent.id, authorize?: false),
               parent_run
             )

    assert {:error, _stale} =
             Cases.select_case_target(
               parent.id,
               Cases.get_case!(parent.id, authorize?: false).revision,
               parent_run.id,
               [moved_source.id],
               target.id,
               target.revision,
               "Moved Condition cannot select a Target in its former Case",
               "moved-condition-selection",
               actor: context.admin
             )

    for field <- [
          :max_resolver_turns,
          :max_target_requests,
          :max_effects,
          :max_related_targets,
          :max_ai_usage_units
        ] do
      assert Map.fetch!(parent_run, field) + Map.fetch!(child_run, field) ==
               Map.fetch!(run, field)
    end

    assert parent_run.max_resolver_turns + child_run.max_resolver_turns == original_max
    assert parent_run.deadline_at == child_run.deadline_at
    assert parent_run.turn_count + child_run.turn_count == 3
    assert length(Cases.started_turns_for_run!(parent_run.id, authorize?: false)) == 1
    assert length(Cases.started_turns_for_run!(child_run.id, authorize?: false)) == 1

    assert Cases.get_case!(parent.id, authorize?: false).status == :running

    assert Enum.any?(Cases.list_case_events!(actor: context.admin), fn event ->
             event.case_id == parent.id and
               event.event_type == "case_conditions_split_out" and
               event.data["turn_ordinal_boundary"] == 1
           end)

    assert :ok = DecisionRouteWorker.perform(%Oban.Job{args: %{"turn_id" => completed.id}})
    assert length(Cases.list_turns!(actor: context.admin)) == 3

    [parent_turn] = Cases.started_turns_for_run!(parent_run.id, authorize?: false)
    parent = Cases.get_case!(parent.id, authorize?: false)
    assert parent.status == :running
    assert Cases.active_resolution_run!(parent.id, authorize?: false).status == :running
    {:ok, next_snapshot} = ConditionContext.current_condition_revisions(parent)

    Cases.complete_turn!(
      parent_turn.id,
      parent_turn.revision,
      %{
        "outcome" => "decision",
        "condition_revisions" => next_snapshot,
        "intent" => %{"type" => "handoff", "reason" => "Separate remaining conditions"}
      },
      :none,
      %{"action" => "route_resolver_decision", "turn_id" => parent_turn.id},
      "Review the Resolver decision",
      authorize?: false
    )

    parent = Cases.get_case!(parent.id, authorize?: false)
    another_id = hd(next_snapshot)["id"]

    grandchild =
      Cases.split_case_conditions!(
        parent.id,
        parent.revision,
        [another_id],
        next_snapshot,
        "One remaining service is unrelated",
        actor: context.admin
      )

    assert grandchild.split_parent_id == parent.id
    final_parent_run = Cases.active_resolution_run!(parent.id, authorize?: false)
    grandchild_run = Cases.active_resolution_run!(grandchild.id, authorize?: false)

    for field <- [
          :max_resolver_turns,
          :max_target_requests,
          :max_effects,
          :max_related_targets,
          :max_ai_usage_units
        ] do
      assert Map.fetch!(final_parent_run, field) + Map.fetch!(child_run, field) +
               Map.fetch!(grandchild_run, field) == Map.fetch!(run, field)
    end

    assert final_parent_run.max_resolver_turns + child_run.max_resolver_turns +
             grandchild_run.max_resolver_turns == original_max

    assert length(Cases.active_conditions_for_case!(parent.id, authorize?: false)) == 1
    assert length(Cases.active_conditions_for_case!(child.id, authorize?: false)) == 1
    assert length(Cases.active_conditions_for_case!(grandchild.id, authorize?: false)) == 1
  end

  test "a rolled-back Condition split keeps its memberships, budgets and jobs retryable",
       context do
    enable_signal_automation!(context.admin)

    target =
      Targets.create_target!("rollback-host", "host", "linux", %{}, nil, actor: context.admin)

    Targets.create_external_identity!(
      target.id,
      "test-monitor",
      "hostname",
      "rollback-host",
      actor: context.admin
    )

    at = DateTime.add(DateTime.utc_now(), -10, :second)

    events =
      for key <- ["fault-a", "fault-b"] do
        event("rollback-split", key, :firing, at,
          target_ref: %{kind: :hostname, value: "rollback-host"},
          attributes: %{"labels" => %{"alertname" => "ArbitraryFault", "subsystem" => key}}
        )
      end

    ingest!(
      context.provider,
      envelope("rollback-split", at),
      invocation("rollback-split", events)
    )

    [parent] = Cases.list_cases!(actor: context.admin)
    assert %{status: :sent} = Cases.send_initial_case_turn!(parent.id, authorize?: false)
    run = Cases.active_resolution_run!(parent.id, authorize?: false)
    [turn] = Cases.started_turns_for_run!(run.id, authorize?: false)
    {:ok, snapshot} = ConditionContext.current_condition_revisions(parent)

    Cases.complete_turn!(
      turn.id,
      turn.revision,
      %{
        "outcome" => "decision",
        "condition_revisions" => snapshot,
        "intent" => %{"type" => "handoff", "reason" => "Investigate both symptoms"}
      },
      :none,
      %{"action" => "route_resolver_decision", "turn_id" => turn.id},
      "Review the Resolver decision",
      authorize?: false
    )

    parent = Cases.get_case!(parent.id, authorize?: false)
    parent_id = parent.id
    :ok = Realtime.subscribe(parent_id)
    moved_id = hd(snapshot)["id"]
    jobs_before = Repo.aggregate(Oban.Job, :count)

    assert {:error, {:simulated_failure, rolled_back_id}} =
             Repo.transaction(fn ->
               child =
                 Cases.split_case_conditions!(
                   parent.id,
                   parent.revision,
                   [moved_id],
                   snapshot,
                   "Separate fault-a",
                   actor: context.admin
                 )

               Repo.rollback({:simulated_failure, child.id})
             end)

    assert length(Cases.list_cases!(actor: context.admin)) == 1
    assert length(Cases.active_conditions_for_case!(parent.id, authorize?: false)) == 2

    assert Cases.active_resolution_run!(parent.id, authorize?: false).max_ai_usage_units ==
             run.max_ai_usage_units

    assert Repo.aggregate(Oban.Job, :count) == jobs_before
    assert {:error, _not_found} = Cases.get_case(rolled_back_id, authorize?: false)
    refute_receive {:case_changed, ^parent_id}, 20

    child =
      Cases.split_case_conditions!(
        parent.id,
        parent.revision,
        [moved_id],
        snapshot,
        "Separate fault-a",
        actor: context.admin
      )

    assert_receive {:case_changed, ^parent_id}

    assert child.id != rolled_back_id
    assert length(Cases.active_conditions_for_case!(parent.id, authorize?: false)) == 1

    assert [%{condition_id: ^moved_id}] =
             Cases.active_conditions_for_case!(child.id, authorize?: false)

    parent_run = Cases.active_resolution_run!(parent.id, authorize?: false)
    child_run = Cases.active_resolution_run!(child.id, authorize?: false)
    assert parent_run.max_ai_usage_units + child_run.max_ai_usage_units == run.max_ai_usage_units
  end

  test "an oversized Target graph preserves native alerts in separate Cases", context do
    enable_signal_automation!(context.admin)

    anchor =
      Targets.create_target!("dense-anchor", "network_device", "custom-network-device", %{}, nil,
        actor: context.admin
      )

    Targets.create_external_identity!(
      anchor.id,
      "test-monitor",
      "hostname",
      "dense-anchor",
      actor: context.admin
    )

    for index <- 1..128 do
      neighbour =
        Targets.create_target!(
          "dense-neighbour-#{index}",
          "network_device",
          "custom-network-device",
          %{},
          nil,
          actor: context.admin
        )

      Targets.create_relationship!(anchor.id, neighbour.id, "connected_to", %{}, nil,
        actor: context.admin
      )
    end

    occurred_at = DateTime.utc_now()

    for key <- ["dense-a", "dense-b"] do
      ingest!(
        context.provider,
        envelope(key, occurred_at),
        invocation(key, [
          event(key, key, :firing, occurred_at,
            target_ref: %{kind: :hostname, value: "dense-anchor"}
          )
        ])
      )
    end

    assert length(Signals.list_conditions!(actor: context.admin)) == 2
    assert length(Signals.list_signal_events!(actor: context.admin)) == 2
    assert length(Cases.list_cases!(actor: context.admin)) == 2
  end

  test "concurrent monitoring sources converge on one active incident", context do
    enable_signal_automation!(context.admin)

    target =
      Targets.create_target!("concurrent-target", "host", "linux", %{}, nil, actor: context.admin)

    Targets.create_external_identity!(
      target.id,
      "test-monitor",
      "hostname",
      "concurrent-target",
      actor: context.admin
    )

    second_provider = signal_provider!(context.admin, "concurrent-monitor")

    Targets.create_external_identity!(
      target.id,
      "concurrent-monitor",
      "hostname",
      "concurrent-target",
      actor: context.admin
    )

    occurred_at = DateTime.utc_now()

    requests = [
      {context.provider, "concurrent-a", "event-a", "test-monitor"},
      {second_provider, "concurrent-b", "event-b", "concurrent-monitor"}
    ]

    results =
      requests
      |> Enum.map(fn {provider, receipt_id, event_key, _source} ->
        Task.async(fn ->
          Signals.ingest_signal(
            provider.id,
            provider.revision,
            envelope(receipt_id, occurred_at),
            invocation(receipt_id, [
              event(receipt_id, event_key, :firing, occurred_at,
                target_ref: %{kind: :hostname, value: "concurrent-target"}
              )
            ])
          )
        end)
      end)
      |> Task.await_many()

    assert [{:ok, _first}, {:ok, _second}] = results
    assert length(Cases.list_cases!(actor: context.admin)) == 1
    assert Cases.list_turns!(actor: context.admin) == []
    [incident] = Cases.list_cases!(actor: context.admin)
    assert length(Cases.active_conditions_for_case!(incident.id, authorize?: false)) == 2
    assert length(Signals.list_signal_events!(actor: context.admin)) == 2
    assert length(Signals.list_signal_correlations!(actor: context.admin)) == 2
  end

  test "concurrent receipt replay converges and conflicting reuse is rejected", context do
    enable_signal_automation!(context.admin)
    occurred_at = DateTime.utc_now()
    envelope = envelope("concurrent", occurred_at)

    invocation =
      invocation("concurrent-receipt", [
        event("concurrent-receipt", "same-alert", :firing, occurred_at)
      ])

    attempts =
      1..2
      |> Enum.map(fn _attempt ->
        Task.async(fn ->
          Signals.ingest_signal(
            context.provider.id,
            context.provider.revision,
            envelope,
            invocation
          )
        end)
      end)
      |> Task.await_many()

    assert [{:ok, first}, {:ok, second}] = attempts
    assert first.id == second.id
    assert length(Signals.list_signal_receipts!(actor: context.admin)) == 1
    assert length(Signals.list_signal_events!(actor: context.admin)) == 1
    assert length(Cases.list_cases!(actor: context.admin)) == 1

    conflicting =
      invocation("concurrent-receipt", [
        event("concurrent-receipt", "different-alert", :firing, occurred_at)
      ])

    assert {:error, _error} =
             Signals.ingest_signal(
               context.provider.id,
               context.provider.revision,
               envelope,
               conflicting
             )

    assert length(Signals.list_signal_events!(actor: context.admin)) == 1
    assert length(Cases.list_cases!(actor: context.admin)) == 1
  end

  test "late recurrence stays in its open investigation without rewinding earlier recovery",
       context do
    enable_signal_automation!(context.admin)
    base = DateTime.add(DateTime.utc_now(), -40, :second)

    ingest_one!(context.provider, "firing", :firing, DateTime.add(base, 10, :second))
    ingest_one!(context.provider, "recovery", :recovered, DateTime.add(base, 30, :second))
    ingest_one!(context.provider, "delayed", :firing, DateTime.add(base, 20, :second))

    incident = Cases.list_cases!(actor: context.admin) |> List.first()
    correlation = Signals.list_signal_correlations!(actor: context.admin) |> List.first()
    [first_condition] = Signals.list_conditions!(actor: context.admin)

    assert first_condition.state == :recovered
    assert incident.status == :running
    assert correlation.current_state == :recovered
    assert correlation.current_occurred_at == DateTime.add(base, 30, :second)
    assert length(Signals.list_signal_events!(actor: context.admin)) == 3
    assert :ok = dispatch_initial!(incident)
    assert length(Cases.list_turns!(actor: context.admin)) == 1

    ingest_one!(context.provider, "refiring", :firing, DateTime.add(base, 40, :second))

    assert length(Cases.list_cases!(actor: context.admin)) == 1
    same_case = Cases.get_case!(incident.id, actor: context.admin)
    assert same_case.id == incident.id
    assert same_case.status == :running
    assert length(Cases.active_conditions_for_case!(incident.id, authorize?: false)) == 2
    assert length(Cases.list_turns!(actor: context.admin)) == 1
  end

  test "a rotated native alert key for the same affected subject stays in the dispatched Case",
       context do
    enable_signal_automation!(context.admin)

    target =
      Targets.create_target!("rotating-host", "host", "linux", %{}, nil, actor: context.admin)

    Targets.create_external_identity!(
      target.id,
      "test-monitor",
      "hostname",
      "rotating-host",
      actor: context.admin
    )

    base = DateTime.add(DateTime.utc_now(), -30, :second)
    labels = %{"pod" => "pod-a", "namespace" => "default", "alertname" => "PodUnavailable"}

    for {receipt, key, state, offset} <- [
          {"original-firing", "fingerprint-a", :firing, 0},
          {"original-recovery", "fingerprint-a", :recovered, 10}
        ] do
      at = DateTime.add(base, offset, :second)

      ingest!(
        context.provider,
        envelope(receipt, at),
        invocation(receipt, [
          event(receipt, key, state, at,
            target_ref: %{kind: :hostname, value: "rotating-host"},
            attributes: %{"labels" => labels}
          )
        ])
      )
    end

    [incident] = Cases.list_cases!(actor: context.admin)
    assert :ok = dispatch_initial!(incident)
    assert length(Cases.list_turns!(actor: context.admin)) == 1

    at = DateTime.add(base, 20, :second)

    ingest!(
      context.provider,
      envelope("rotated-firing", at),
      invocation("rotated-firing", [
        event("rotated-firing", "fingerprint-b", :firing, at,
          target_ref: %{kind: :hostname, value: "rotating-host"},
          attributes: %{"labels" => labels}
        )
      ])
    )

    assert length(Cases.list_cases!(actor: context.admin)) == 1
    assert length(Signals.list_conditions!(actor: context.admin)) == 2
    assert length(Cases.active_conditions_for_case!(incident.id, authorize?: false)) == 2
    assert length(Cases.list_turns!(actor: context.admin)) == 1
  end

  test "a reused native event key with a different affected subject opens another Case",
       context do
    enable_signal_automation!(context.admin)
    base = DateTime.add(DateTime.utc_now(), -30, :second)

    for {receipt_id, state, offset, pod} <- [
          {"pod-a-firing", :firing, 0, "pod-a"},
          {"pod-a-recovered", :recovered, 10, "pod-a"},
          {"pod-b-firing", :firing, 20, "pod-b"}
        ] do
      occurred_at = DateTime.add(base, offset, :second)

      ingest!(
        context.provider,
        envelope(receipt_id, occurred_at),
        invocation(receipt_id, [
          event(receipt_id, "shared-event-key", state, occurred_at,
            attributes: %{"labels" => %{"pod" => pod, "namespace" => "default"}}
          )
        ])
      )
    end

    assert length(Cases.list_cases!(actor: context.admin)) == 2
    assert length(Signals.list_conditions!(actor: context.admin)) == 2
  end

  test "one native event key can carry two firing subjects without cross-recovery", context do
    enable_signal_automation!(context.admin)
    base = DateTime.add(DateTime.utc_now(), -30, :second)

    for {receipt, state, offset, pod} <- [
          {"pod-a-start", :firing, 0, "pod-a"},
          {"pod-b-start", :firing, 1, "pod-b"},
          {"pod-a-end", :recovered, 2, "pod-a"}
        ] do
      at = DateTime.add(base, offset, :second)

      ingest!(
        context.provider,
        envelope(receipt, at),
        invocation(receipt, [
          event(receipt, "shared-native-key", state, at,
            attributes: %{
              "labels" => %{
                "pod" => pod,
                "namespace" => "default",
                "alertname" => "PodUnavailable"
              }
            }
          )
        ])
      )
    end

    conditions = Signals.list_conditions!(actor: context.admin)
    events = Signals.list_signal_events!(actor: context.admin)

    pod_a_id =
      events
      |> Enum.find(&(&1.state == :firing and &1.attributes["labels"]["pod"] == "pod-a"))
      |> Map.fetch!(:condition_id)

    pod_b_id =
      events
      |> Enum.find(&(&1.state == :firing and &1.attributes["labels"]["pod"] == "pod-b"))
      |> Map.fetch!(:condition_id)

    assert length(conditions) == 2
    assert Signals.get_condition!(pod_a_id, actor: context.admin).state == :recovered
    assert Signals.get_condition!(pod_b_id, actor: context.admin).state == :firing
    assert length(Cases.list_cases!(actor: context.admin)) == 2
  end

  test "a recurrence during Resolver delivery retains its paid decision and routes one reassessment",
       context do
    enable_signal_automation!(context.admin)
    configure_resolver_ai!(context.admin)
    base = DateTime.add(DateTime.utc_now(), -30, :second)
    ingest_one!(context.provider, "initial-ai-firing", :firing, base)

    [incident] = Cases.list_cases!(actor: context.admin)
    assert :ok = dispatch_initial!(incident)
    [first_turn] = Cases.list_turns!(actor: context.admin)

    decision = %AI.ResolverDecision{
      intent: %AI.TargetSearch{query: "current fault", reason: "Find affected target"},
      usage: %AI.Usage{input_tokens: 3, output_tokens: 2}
    }

    assert :ok =
             ResolverDelivery.run(first_turn.id,
               ai_invocation: %{
                 test_pid: self(),
                 respond: fn request ->
                   assert length(request.conditions) == 1

                   ingest_one!(
                     context.provider,
                     "ai-recovery",
                     :recovered,
                     DateTime.add(base, 10)
                   )

                   ingest_one!(context.provider, "ai-refiring", :firing, DateTime.add(base, 20))
                   {:ok, decision}
                 end
               }
             )

    assert Cases.get_turn!(first_turn.id, authorize?: false).result["outcome"] ==
             "decision"

    assert Cases.started_turns_for_run!(first_turn.resolution_run_id, authorize?: false) == []

    for _ <- 1..2 do
      assert %{status: :completed} =
               Cases.route_resolver_decision!(first_turn.id, authorize?: false)
    end

    assert Cases.list_proposals!(actor: context.admin) == []
    assert Cases.list_operations!(actor: context.admin) == []
    assert [%{status: :completed, category: nil}] = Cases.list_ai_invocations!(authorize?: false)

    assert Cases.get_resolution_run!(first_turn.resolution_run_id, authorize?: false).ai_usage_units ==
             5

    [successor] =
      Cases.list_turns!(actor: context.admin)
      |> Enum.filter(&(&1.status == :started))

    assert :ok =
             ResolverDelivery.run(successor.id,
               ai_invocation: %{
                 test_pid: self(),
                 respond: fn request ->
                   assert length(request.conditions) == 2
                   assert Enum.map(request.conditions, & &1.state) == [:recovered, :firing]
                   assert [source | _] = request.evidence

                   {:ok,
                    %{
                      decision
                      | condition_groups: [
                          %{
                            "condition_ids" => Enum.map(request.conditions, & &1.id),
                            "assessment" => "related",
                            "reason" => "The native subject recurred",
                            "evidence_ids" => [source.id]
                          }
                        ]
                    }}
                 end
               }
             )

    result = Cases.get_turn!(successor.id, authorize?: false).result
    assert result["outcome"] == "decision"
    assert [%{"assessment" => "related", "condition_ids" => ids}] = result["condition_groups"]
    assert length(ids) == 2
    assert length(Cases.list_cases!(actor: context.admin)) == 1
  end

  test "a recurrence after Resolver acceptance supersedes its unrouted decision", context do
    enable_signal_automation!(context.admin)
    configure_resolver_ai!(context.admin)
    base = DateTime.add(DateTime.utc_now(), -30, :second)
    ingest_one!(context.provider, "route-initial", :firing, base)

    [incident] = Cases.list_cases!(actor: context.admin)
    assert :ok = dispatch_initial!(incident)
    [first_turn] = Cases.list_turns!(actor: context.admin)

    assert :ok =
             ResolverDelivery.run(first_turn.id,
               ai_invocation: %{
                 test_pid: self(),
                 respond: fn _request ->
                   {:ok,
                    %AI.ResolverDecision{
                      intent: %AI.TargetSearch{query: "old fault", reason: "Find target"},
                      usage: %AI.Usage{input_tokens: 2, output_tokens: 1}
                    }}
                 end
               }
             )

    ingest_one!(context.provider, "route-recovery", :recovered, DateTime.add(base, 10))
    ingest_one!(context.provider, "route-refiring", :firing, DateTime.add(base, 20))

    assert :ok = DecisionRouteWorker.perform(%Oban.Job{args: %{"turn_id" => first_turn.id}})

    [successor] =
      Cases.list_turns!(actor: context.admin)
      |> Enum.filter(&(&1.status == :started))

    assert successor.id != first_turn.id

    assert Cases.get_case!(incident.id, actor: context.admin).pending_intent["turn_id"] ==
             successor.id

    assert :ok = DecisionRouteWorker.perform(%Oban.Job{args: %{"turn_id" => first_turn.id}})
    assert length(Cases.list_turns!(actor: context.admin)) == 2
  end

  test "source recovery alone leaves an attention Case awaiting independent verification",
       context do
    enable_signal_automation!(context.admin)
    base = DateTime.add(DateTime.utc_now(), -10, :second)

    ingest_one!(context.provider, "attention-firing", :firing, base)

    [incident] = Cases.list_cases!(actor: context.admin)
    assert :ok = dispatch_initial!(incident)
    run = Cases.active_resolution_run!(incident.id, authorize?: false)
    [turn] = Cases.started_turns_for_run!(run.id, authorize?: false)

    Cases.complete_turn!(
      turn.id,
      turn.revision,
      %{"outcome" => "delivery_failed", "category" => "invalid_output"},
      :none,
      %{"action" => "retry_resolver", "turn_id" => turn.id},
      "Review the Resolver delivery failure",
      authorize?: false
    )

    current = Cases.get_case!(incident.id, authorize?: false)
    current_run = Cases.get_resolution_run!(run.id, authorize?: false)

    Cases.require_case_attention!(
      current.id,
      current.revision,
      current_run.id,
      current_run.revision,
      "resolver-delivery-failed:test",
      "Resolver delivery failed",
      %{"action" => "retry_resolver", "turn_id" => turn.id},
      "Review the Resolver delivery failure",
      authorize?: false
    )

    ingest_one!(
      context.provider,
      "attention-recovered",
      :recovered,
      DateTime.add(base, 10, :second)
    )

    recovered = Cases.get_case!(incident.id, actor: context.admin)
    assert recovered.status == :needs_attention
    assert recovered.required_human_input == "Review the Resolver delivery failure"
    assert [condition] = Signals.list_conditions!(actor: context.admin)
    assert condition.state == :recovered
    assert [active_run] = Cases.list_resolution_runs!(actor: context.admin)
    assert active_run.id == run.id
    assert active_run.status == :needs_attention
    assert length(Cases.list_turns!(actor: context.admin)) == 1
  end

  test "source sequence orders events that have the same source timestamp", context do
    enable_signal_automation!(context.admin)
    occurred_at = DateTime.utc_now()

    ingest!(
      context.provider,
      envelope("same-time-recovery", occurred_at),
      invocation("same-time-recovery", [
        event("same-time-recovery", "same-time-alert", :recovered, occurred_at,
          source_sequence: 20
        )
      ])
    )

    ingest!(
      context.provider,
      envelope("same-time-delayed", occurred_at),
      invocation("same-time-delayed", [
        event("same-time-delayed", "same-time-alert", :firing, occurred_at, source_sequence: 10)
      ])
    )

    correlation = Signals.list_signal_correlations!(actor: context.admin) |> List.first()
    assert correlation.current_state == :recovered
    assert correlation.current_source_sequence == "20"
    assert Cases.list_cases!(actor: context.admin) == []
    assert length(Signals.list_signal_events!(actor: context.admin)) == 2
  end

  test "disabled automation stores the alert without starting autonomous resolution", context do
    occurred_at = DateTime.utc_now()
    ingest_one!(context.provider, "disabled", :firing, occurred_at)

    incident = Cases.list_cases!(actor: context.admin) |> List.first()

    assert incident.status == :needs_attention
    assert is_nil(incident.current_owner_id)
    assert Cases.list_turns!(actor: context.admin) == []
    assert length(Signals.list_signal_events!(actor: context.admin)) == 1
    assert length(Cases.list_evidence!(actor: context.admin)) == 1
  end

  test "a matching recurrence stays in the Case awaiting operator attention", context do
    base = DateTime.add(DateTime.utc_now(), -30, :second)
    ingest_one!(context.provider, "attention-first", :firing, base)
    ingest_one!(context.provider, "attention-recovered", :recovered, DateTime.add(base, 10))
    ingest_one!(context.provider, "attention-refiring", :firing, DateTime.add(base, 20))

    [incident] = Cases.list_cases!(actor: context.admin)
    assert incident.status == :needs_attention
    assert length(Cases.active_conditions_for_case!(incident.id, authorize?: false)) == 2
    assert Cases.list_turns!(actor: context.admin) == []
  end

  test "a new recurrence after a stopped investigation starts a separate autonomous Case",
       context do
    enable_signal_automation!(context.admin)
    base = DateTime.add(DateTime.utc_now(), -30, :second)
    ingest_one!(context.provider, "stopped-first", :firing, base)

    [old_case] = Cases.list_cases!(actor: context.admin)
    assert :ok = dispatch_initial!(old_case)
    old_run = Cases.active_resolution_run!(old_case.id, authorize?: false)
    old_case = Cases.get_case!(old_case.id, authorize?: false)

    Cases.require_case_attention!(
      old_case.id,
      old_case.revision,
      old_run.id,
      old_run.revision,
      "stopped-investigation",
      "Resolver requires attention",
      %{"action" => "retry_resolver"},
      "Resume the Case",
      authorize?: false
    )

    ingest_one!(context.provider, "stopped-recovered", :recovered, DateTime.add(base, 10))
    ingest_one!(context.provider, "stopped-refiring", :firing, DateTime.add(base, 20))

    assert [first, second] =
             Cases.list_cases!(actor: context.admin)
             |> Enum.sort_by(& &1.inserted_at, DateTime)

    assert first.id == old_case.id
    assert first.status == :needs_attention
    assert second.status == :running
    assert length(Cases.active_conditions_for_case!(first.id, authorize?: false)) == 1
    assert length(Cases.active_conditions_for_case!(second.id, authorize?: false)) == 1
    assert :ok = dispatch_initial!(second)
    assert Enum.count(Cases.list_turns!(actor: context.admin), &(&1.case_id == second.id)) == 1

    ingest_one!(context.provider, "stopped-refiring-duplicate", :firing, DateTime.add(base, 20))
    assert length(Cases.list_cases!(actor: context.admin)) == 2
  end

  test "a later source event is retained after the Case is terminal", context do
    enable_signal_automation!(context.admin)
    occurred_at = DateTime.utc_now()
    ingest_one!(context.provider, "terminal-firing", :firing, occurred_at)

    incident = Cases.list_cases!(actor: context.admin) |> List.first()
    run = Cases.active_resolution_run!(incident.id, authorize?: false)

    Cases.record_case_cancellation!(incident, incident.revision, authorize?: false)

    Cases.retire_resolution_run!(
      run,
      run.revision,
      %{status: :cancelled, ended_at: DateTime.utc_now()},
      authorize?: false
    )

    ingest_one!(
      context.provider,
      "terminal-recovery",
      :recovered,
      DateTime.add(occurred_at, 10, :second)
    )

    assert Cases.get_case!(incident.id, actor: context.admin).status == :cancelled
    assert length(Signals.list_signal_events!(actor: context.admin)) == 2

    assert (Signals.list_signal_correlations!(actor: context.admin) |> List.first()).current_state ==
             :recovered
  end

  test "a new firing of the same alert opens a fresh Case after prior resolution", context do
    enable_signal_automation!(context.admin)
    base = DateTime.utc_now()
    ingest_one!(context.provider, "first-firing", :firing, base)

    [first] = Cases.list_cases!(actor: context.admin)
    first_run = Cases.active_resolution_run!(first.id, authorize?: false)

    Cases.record_case_resolution!(first, first.revision, DateTime.utc_now(), authorize?: false)

    Cases.retire_resolution_run!(
      first_run,
      first_run.revision,
      %{status: :completed, ended_at: DateTime.utc_now()},
      authorize?: false
    )

    ingest_one!(context.provider, "first-recovered", :recovered, DateTime.add(base, 10, :second))
    ingest_one!(context.provider, "second-firing", :firing, DateTime.add(base, 20, :second))

    [second, historical] =
      Cases.list_cases!(actor: context.admin)
      |> Enum.sort_by(& &1.inserted_at, {:desc, DateTime})

    assert historical.id == first.id
    assert historical.status == :resolved
    assert second.id != first.id
    assert second.status == :running

    [second_membership] = Cases.active_conditions_for_case!(second.id, authorize?: false)

    assert Signals.get_condition!(second_membership.condition_id, authorize?: false).state ==
             :firing

    [correlation] = Signals.list_signal_correlations!(actor: context.admin)
    assert correlation.current_state == :firing

    assert correlation.latest_signal_event_id in Enum.map(
             Signals.list_signal_events!(actor: context.admin),
             & &1.id
           )

    ingest_one!(context.provider, "repeat-firing", :firing, DateTime.add(base, 21, :second))
    ingest_one!(context.provider, "stale-firing", :firing, DateTime.add(base, 19, :second))
    assert length(Cases.list_cases!(actor: context.admin)) == 2

    ingest_one!(context.provider, "second-recovered", :recovered, DateTime.add(base, 30, :second))
    ingest_one!(context.provider, "second-recovered", :recovered, DateTime.add(base, 30, :second))

    assert Cases.get_case!(first.id, actor: context.admin).status == :resolved
    events = Signals.list_signal_events!(actor: context.admin)

    [older, newer] =
      Signals.list_conditions!(actor: context.admin)
      |> Enum.sort_by(& &1.occurrence)

    assert older.state == :recovered
    assert newer.state == :recovered
    assert {older.occurrence, newer.occurrence} == {1, 2}
    assert Enum.any?(events, &(&1.condition_id == older.id))
    assert Enum.any?(events, &(&1.condition_id == newer.id))

    assert Enum.find(events, &(DateTime.compare(&1.occurred_at, DateTime.add(base, 19)) == :eq)).condition_id ==
             nil

    assert length(events) == 6
    assert Enum.count(events, &(&1.case_id == first.id)) == 2
    assert Enum.count(events, &(&1.case_id == second.id)) == 3
    assert Enum.count(events, &is_nil(&1.case_id)) == 1
  end

  test "a later Target catalog change re-evaluates a running unresolved Signal Case", context do
    enable_signal_automation!(context.admin)
    occurred_at = DateTime.add(DateTime.utc_now(), -10, :second)
    ingest_one!(context.provider, "unresolved", :firing, occurred_at)

    [incident] = Cases.list_cases!(actor: context.admin)
    assert :ok = dispatch_initial!(incident)

    [first_turn] = Cases.list_turns!(actor: context.admin)

    Cases.complete_turn!(
      first_turn.id,
      first_turn.revision,
      %{"outcome" => "target not found"},
      :none,
      %{"action" => "continue"},
      "Review unresolved Target",
      authorize?: false
    )

    target =
      Targets.create_target!("late-linux", "host", "linux", %{}, nil, actor: context.admin)

    Targets.create_external_identity!(
      target.id,
      "test-monitor",
      "hostname",
      "late-linux",
      actor: context.admin
    )

    Targets.update_target!(target, target.revision, %{facts: %{"catalog" => "updated"}},
      actor: context.admin
    )

    [stale_job, current_job] =
      Repo.all(
        from(job in Oban.Job,
          where:
            job.worker == "Skopos.Cases.Case.TargetCatalogReconciliationWorker" and
              fragment("?->>'resource_id'", job.args) == ^target.id
        )
      )
      |> Enum.sort_by(& &1.args["revision"])

    assert :ok = Skopos.Cases.Case.TargetCatalogReconciliationWorker.perform(stale_job)
    assert length(Cases.list_turns!(actor: context.admin)) == 1
    assert :ok = Skopos.Cases.Case.TargetCatalogReconciliationWorker.perform(current_job)

    turns = Cases.list_turns!(actor: context.admin)
    assert length(turns) == 2
    assert Enum.count(turns, &(&1.status == :started)) == 1

    incident = Cases.list_cases!(actor: context.admin) |> List.first()
    assert incident.status == :running
    assert is_nil(incident.selected_target_id)
  end

  test "matching identity registration resumes the same waiting Signal Case exactly once",
       context do
    enable_signal_automation!(context.admin)
    occurred_at = DateTime.add(DateTime.utc_now(), -10, :second)

    ingest!(
      context.provider,
      envelope("waiting-target", occurred_at),
      invocation("waiting-target", [
        event("waiting-target", "waiting-target-alert", :firing, occurred_at,
          target_ref: %{kind: :hostname, value: "late-linux"}
        )
      ])
    )

    [incident] = Cases.list_cases!(actor: context.admin)
    assert :ok = dispatch_initial!(incident)

    [first_turn] = Cases.list_turns!(actor: context.admin)

    Cases.complete_turn!(
      first_turn.id,
      first_turn.revision,
      %{"outcome" => "decision", "intent" => %{"type" => "handoff"}},
      :human_input,
      %{"action" => "provide_human_input", "source_turn_id" => first_turn.id},
      "Register the Target identity",
      authorize?: false
    )

    incident = Cases.list_cases!(actor: context.admin) |> List.first()
    first_run = Cases.active_resolution_run!(incident.id, authorize?: false)

    waiting =
      Cases.require_case_attention!(
        incident.id,
        incident.revision,
        first_run.id,
        first_run.revision,
        "waiting-target:handoff",
        "The exact Target identity is unavailable",
        %{"action" => "provide_human_input", "source_turn_id" => first_turn.id},
        "Register the exact Target identity",
        authorize?: false
      )

    unrelated =
      Targets.create_target!("unrelated-linux", "host", "linux", %{}, nil, actor: context.admin)

    unrelated_identity =
      Targets.create_external_identity!(
        unrelated.id,
        "test-monitor",
        "hostname",
        "unrelated-linux",
        actor: context.admin
      )

    assert :ok =
             Skopos.Cases.Case.TargetCatalogReconciliationWorker.perform(
               reconciliation_job!(unrelated_identity.id)
             )

    unchanged = Cases.get_case!(waiting.id, actor: context.admin)
    assert unchanged.status == :needs_attention
    assert unchanged.revision == waiting.revision

    token = api_token!(context.admin.email)

    target =
      api_post_data!(
        "/api/v1/targets",
        %{"target" => %{"name" => "late-linux", "kind" => "host", "type_id" => "linux"}},
        token
      )

    identity =
      api_post_data!(
        "/api/v1/external-identities",
        %{
          "external_identity" => %{
            "target_id" => target["id"],
            "source" => "test-monitor",
            "kind" => "hostname",
            "value" => "late-linux"
          }
        },
        token
      )

    job = reconciliation_job!(identity["id"])

    assert job.args == %{
             "resource" => "external_identity",
             "resource_id" => identity["id"],
             "revision" => identity["revision"]
           }

    assert :ok =
             Task.async(fn ->
               Skopos.Cases.Case.TargetCatalogReconciliationWorker.perform(job)
             end)
             |> Task.await()

    resumed = Cases.get_case!(waiting.id, actor: context.admin)
    assert resumed.status == :running
    assert resumed.selected_target_id == target["id"]
    assert resumed.selected_target_revision == target["revision"]
    assert resumed.current_owner_id == context.admin.id

    snapshot = api_get_data!("/api/v1/cases/#{waiting.id}", token)
    assert snapshot["case"]["status"] == "running"
    assert snapshot["case"]["selected_target_id"] == target["id"]

    runs = Cases.list_resolution_runs!(actor: context.admin) |> Enum.sort_by(& &1.generation)

    assert Enum.map(runs, &{&1.generation, &1.status, &1.active}) == [
             {1, :superseded, false},
             {2, :running, true}
           ]

    resumed_run = List.last(runs)
    assert is_nil(resumed_run.resumed_by_id)

    assert [resumed_turn] =
             Cases.list_turns!(actor: context.admin)
             |> Enum.filter(&(&1.resolution_run_id == resumed_run.id))

    assert resumed_turn.status == :started

    assert resumed_turn.intent == %{
             "objective" => "Continue resolution after Target registration"
           }

    assert :ok = Skopos.Cases.Case.TargetCatalogReconciliationWorker.perform(job)
    assert length(Cases.list_resolution_runs!(actor: context.admin)) == 2
    assert length(Cases.list_turns!(actor: context.admin)) == 2
  end

  test "Target reconciliation remains retryable while a Resolver Turn is active", context do
    enable_signal_automation!(context.admin)
    occurred_at = DateTime.add(DateTime.utc_now(), -10, :second)
    ingest_one!(context.provider, "busy-reconciliation", :firing, occurred_at)

    [incident] = Cases.list_cases!(actor: context.admin)
    assert :ok = dispatch_initial!(incident)

    [first_turn] = Cases.list_turns!(actor: context.admin)

    target =
      Targets.create_target!("later-target", "host", "linux", %{}, nil, actor: context.admin)

    job =
      Repo.one!(
        from(job in Oban.Job,
          where:
            job.worker == "Skopos.Cases.Case.TargetCatalogReconciliationWorker" and
              fragment("?->>'resource_id'", job.args) == ^target.id
        )
      )

    assert {:error, "Case still has an active Resolver Turn"} =
             Skopos.Cases.Case.TargetCatalogReconciliationWorker.perform(job)

    Cases.complete_turn!(
      first_turn.id,
      first_turn.revision,
      %{"outcome" => "target not found"},
      :none,
      %{"action" => "continue"},
      "Review unresolved Target",
      authorize?: false
    )

    assert :ok = Skopos.Cases.Case.TargetCatalogReconciliationWorker.perform(job)
    assert length(Cases.list_turns!(actor: context.admin)) == 2
  end

  test "Target registration rolls back when its Case reconciliation job cannot be saved",
       context do
    assert {:error, :job_rejected} =
             Repo.transaction(fn ->
               Repo.query!("""
               CREATE FUNCTION reject_case_reconciliation_job() RETURNS trigger AS $$
               BEGIN
                 IF NEW.worker = 'Skopos.Cases.Case.TargetCatalogReconciliationWorker' THEN
                   RAISE EXCEPTION 'reconciliation job rejected';
                 END IF;
                 RETURN NEW;
               END;
               $$ LANGUAGE plpgsql
               """)

               Repo.query!("""
               CREATE TRIGGER reject_case_reconciliation_job
               BEFORE INSERT ON oban_jobs
               FOR EACH ROW EXECUTE FUNCTION reject_case_reconciliation_job()
               """)

               assert_raise Ash.Error.Unknown, fn ->
                 Targets.create_target!(
                   "job-rejected-target",
                   "host",
                   "linux",
                   %{},
                   nil,
                   actor: context.admin
                 )
               end

               Repo.rollback(:job_rejected)
             end)

    refute Enum.any?(
             Targets.list_targets!(actor: context.admin),
             &(&1.name == "job-rejected-target")
           )

    assert Repo.aggregate(
             from(job in Oban.Job,
               where: job.worker == "Skopos.Cases.Case.TargetCatalogReconciliationWorker"
             ),
             :count
           ) == 0
  end

  test "Target catalog rejects missing Case reconciliation without an orphan Target or identity",
       context do
    existing =
      Targets.create_target!("identity-parent", "host", "linux", %{}, nil, actor: context.admin)

    Repo.query!("""
    CREATE FUNCTION pg_temp.drop_catalog_reconciliation() RETURNS trigger LANGUAGE plpgsql AS $$
    BEGIN
      IF NEW.worker = 'Skopos.Cases.Case.TargetCatalogReconciliationWorker' THEN RETURN NULL; END IF;
      RETURN NEW;
    END;
    $$;
    """)

    Repo.query!("""
    CREATE TRIGGER drop_catalog_reconciliation BEFORE INSERT ON oban_jobs
    FOR EACH ROW EXECUTE FUNCTION pg_temp.drop_catalog_reconciliation()
    """)

    assert {:error, _error} =
             Targets.create_target(
               "missing-reconciliation",
               "host",
               "linux",
               %{},
               nil,
               actor: context.admin
             )

    assert {:error, _error} =
             Targets.create_external_identity(
               existing.id,
               "test-monitor",
               "hostname",
               "missing-identity",
               actor: context.admin
             )

    assert [retained] = Targets.list_targets!(actor: context.admin)
    assert retained.id == existing.id
    assert retained.name == "identity-parent"
    assert retained.revision == 1
    assert Targets.list_external_identities!(actor: context.admin) == []

    Repo.query!("DROP TRIGGER drop_catalog_reconciliation ON oban_jobs")

    target =
      Targets.create_target!(
        "missing-reconciliation",
        "host",
        "linux",
        %{},
        nil,
        actor: context.admin
      )

    identity =
      Targets.create_external_identity!(
        existing.id,
        "test-monitor",
        "hostname",
        "missing-identity",
        actor: context.admin
      )

    jobs =
      Repo.all(Oban.Job)
      |> Enum.filter(&(&1.worker == "Skopos.Cases.Case.TargetCatalogReconciliationWorker"))

    assert Enum.count(jobs, &(&1.args["resource_id"] == target.id)) == 1
    assert Enum.count(jobs, &(&1.args["resource_id"] == identity.id)) == 1
    assert Enum.all?(jobs, &is_integer(&1.id))
    assert [registered] = Targets.list_external_identities!(actor: context.admin)
    assert registered.id == identity.id
    assert registered.target_id == existing.id
    assert registered.value == "missing-identity"
  end

  defp dispatch_initial!(incident) do
    Skopos.Cases.CaseDispatch.Worker.perform(%Oban.Job{args: %{"case_id" => incident.id}})
  end

  defp enable_signal_automation!(admin) do
    current = Cases.current_authority_setting!(actor: admin)

    Cases.configure_authority_setting!(
      current.setting_revision,
      current.authority_mode,
      true,
      current.max_elapsed_seconds,
      current.max_resolver_turns,
      current.max_target_requests,
      current.max_effects,
      current.max_related_targets,
      current.max_ai_usage_units,
      current.max_no_progress_turns,
      "enable Signal ingress",
      actor: admin
    )
  end

  defp configure_resolver_ai!(admin) do
    provider =
      Providers.create_provider!(
        "signal-ingress-resolver-ai",
        :ai,
        "fixture-ai",
        %{"model" => "resolver-model"},
        %{"api_key" => "resolver-test-key"},
        actor: admin
      )
      |> then(&Providers.check_provider!(&1.id, 1, %{}, actor: admin))
      |> then(&Providers.enable_provider!(&1, 1, actor: admin))

    Skopos.TestAIUsage.configure!(provider.id, :resolver, 10, admin)
  end

  defp signal_provider!(admin, source) do
    Providers.create_provider!(
      "signal-ingress-#{source}",
      :signal,
      "fixture-signal",
      %{"source" => source},
      %{"secret" => "signal-secret"},
      actor: admin
    )
    |> then(&Providers.check_provider!(&1.id, 1, %{}, actor: admin))
    |> then(&Providers.enable_provider!(&1, 1, actor: admin))
  end

  defp reconciliation_job!(identity_id) do
    Repo.all(
      from(job in Oban.Job,
        where: job.worker == "Skopos.Cases.Case.TargetCatalogReconciliationWorker"
      )
    )
    |> Enum.find(fn job ->
      job.args["resource"] == "external_identity" and job.args["resource_id"] == identity_id
    end)
  end

  defp api_token!(email) do
    build_json_conn(%{})
    |> post("/api/v1/sessions", %{
      "session" => %{"email" => to_string(email), "password" => @password}
    })
    |> json_response(201)
    |> get_in(["data", "token"])
  end

  defp api_post_data!(path, body, token) do
    build_json_conn(body)
    |> put_req_header("authorization", "Bearer " <> token)
    |> post(path, body)
    |> json_response(201)
    |> Map.fetch!("data")
  end

  defp api_get_data!(path, token) do
    build_json_conn(nil)
    |> put_req_header("authorization", "Bearer " <> token)
    |> get(path)
    |> json_response(200)
    |> Map.fetch!("data")
  end

  defp build_json_conn(_body) do
    Phoenix.ConnTest.build_conn()
    |> put_req_header("accept", "application/json")
    |> put_req_header("content-type", "application/json")
  end

  defp ingest_one!(provider, receipt_id, state, occurred_at) do
    ingest!(
      provider,
      envelope(receipt_id, occurred_at),
      invocation(receipt_id, [event(receipt_id, "same-alert", state, occurred_at)])
    )
  end

  defp ingest!(provider, envelope, invocation) do
    Signals.ingest_signal!(provider.id, provider.revision, envelope, invocation)
  end

  defp invocation(receipt_id, events) do
    %{
      authenticate: fn adapter_state, _envelope ->
        {:ok,
         %Signal.AuthenticatedReceipt{
           receipt_id: receipt_id,
           source: adapter_state.source
         }}
      end,
      normalize: fn _adapter_state, _envelope, _receipt -> {:ok, events} end
    }
  end

  defp event(receipt_id, event_key, state, occurred_at, opts \\ []) do
    %Signal.Event{
      receipt_id: receipt_id,
      event_key: event_key,
      state: state,
      occurred_at: occurred_at,
      source_sequence: Keyword.get(opts, :source_sequence),
      target_ref: Keyword.get(opts, :target_ref),
      attributes: Keyword.get(opts, :attributes, %{})
    }
  end

  defp envelope(body, received_at) do
    %Signal.Envelope{body: body, headers: %{}, received_at: received_at}
  end
end
