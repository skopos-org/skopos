defmodule Skopos.CaseHistoryTest do
  use Skopos.DataCase, async: false

  import Ecto.Query

  alias Skopos.{Accounts, Cases, Repo}
  alias Skopos.Cases.ResolutionRun

  @password "correct horse battery staple"

  setup do
    admin =
      Accounts.bootstrap!("history-admin@example.com", @password, @password, authorize?: true)

    operator =
      Accounts.create_user!("history-operator@example.com", @password, :operator, actor: admin)

    viewer = Accounts.create_user!("history-viewer@example.com", @password, :viewer, actor: admin)

    configure_limits!(admin)
    %{admin: admin, operator: operator, viewer: viewer}
  end

  test "Turn completion and Evidence survive reload and retries do not duplicate history",
       context do
    {incident, run} = open!("durable-history", context.operator)
    intent = %{"action" => "inspect", "target" => "linux-01"}

    started = start!(incident, run, "turn-1", intent)
    assert started.status == :charged
    assert started.value.ordinal == 1
    assert started.run.turn_count == 1

    retried = start!(incident, run, "turn-1", intent)
    assert retried.status == :duplicate
    assert retried.value.id == started.value.id
    assert [%Oban.Job{queue: "resolver", state: "available"}] = jobs_for(started.value.id)

    assert {:error, _error} =
             start(incident, run, "turn-1", %{"action" => "change-the-request"})

    observed_at = DateTime.utc_now()

    evidence =
      Cases.append_evidence!(
        incident.id,
        run.id,
        started.value.id,
        "evidence-1",
        "command_output",
        "linux-01",
        "journalctl",
        %{"lines" => ["I/O error"]},
        observed_at,
        authorize?: false
      )

    retried_evidence =
      Cases.append_evidence!(
        incident.id,
        run.id,
        started.value.id,
        "evidence-1",
        "command_output",
        "linux-01",
        "journalctl",
        %{"lines" => ["I/O error"]},
        observed_at,
        authorize?: false
      )

    assert retried_evidence.id == evidence.id

    assert {:error, _error} =
             Cases.append_evidence(
               incident.id,
               run.id,
               started.value.id,
               "evidence-1",
               "command_output",
               "linux-01",
               "journalctl",
               %{"lines" => ["different"]},
               observed_at,
               authorize?: false
             )

    completed =
      complete!(started.value, %{"finding" => "storage path"}, :evidence)

    assert completed.status == :charged
    assert completed.value.status == :completed
    assert completed.value.result == %{"finding" => "storage path"}

    repeated =
      complete!(started.value, %{"finding" => "storage path"}, :evidence)

    assert repeated.status == :duplicate
    assert repeated.value.id == completed.value.id

    assert [turn] = Cases.list_turns!(actor: context.viewer)
    assert turn.status == :completed
    assert turn.result == %{"finding" => "storage path"}
    assert [reloaded_evidence] = Cases.list_evidence!(actor: context.viewer)
    assert reloaded_evidence.content == %{"lines" => ["I/O error"]}

    assert Enum.map(Cases.list_case_events!(actor: context.viewer), & &1.event_type) == [
             "case_opened",
             "turn_started",
             "evidence_added",
             "turn_completed"
           ]
  end

  test "Turn and Resolver job commit or roll back together", context do
    {incident, run} = open!("atomic-turn-delivery", context.operator)
    intent = %{"action" => "inspect"}

    assert {:error, :simulated_failure} =
             Repo.transaction(fn ->
               started = start!(incident, run, "rolled-back-turn", intent)
               assert [_job] = jobs_for(started.value.id)
               Repo.rollback(:simulated_failure)
             end)

    assert Cases.list_turns!(actor: context.viewer) == []

    assert Repo.all(Oban.Job)
           |> Enum.filter(&(&1.worker == "Skopos.Cases.Turn.ResolverWorker")) == []

    reloaded_run = Cases.get_resolution_run!(run.id, actor: context.viewer)
    assert reloaded_run.turn_count == 0

    accepted = start!(incident, reloaded_run, "rolled-back-turn", intent)
    assert accepted.status == :charged
    assert [_job] = jobs_for(accepted.value.id)

    retried = start!(incident, accepted.run, "rolled-back-turn", intent)
    assert retried.status == :duplicate
    assert retried.value.id == accepted.value.id
    assert [_job] = jobs_for(accepted.value.id)
  end

  test "concurrent duplicate Turn delivery creates one Turn and one Resolver job", context do
    {incident, run} = open!("concurrent-turn-delivery", context.operator)
    intent = %{"action" => "inspect"}

    results =
      for _attempt <- 1..2 do
        Task.async(fn -> start(incident, run, "same-turn", intent) end)
      end
      |> Task.await_many()

    assert Enum.all?(results, &match?({:ok, _result}, &1))

    accepted = Enum.map(results, fn {:ok, result} -> result end)
    assert Enum.sort(Enum.map(accepted, & &1.status)) == [:charged, :duplicate]
    assert [turn] = Cases.list_turns!(actor: context.viewer)
    assert [_job] = jobs_for(turn.id)
  end

  test "concurrent distinct charges serialize and cannot exceed the configured limit", context do
    {incident, run} = open!("concurrent-budget", context.operator)

    results =
      1..3
      |> Enum.map(fn index ->
        Task.async(fn ->
          Cases.charge_resolution_run(
            incident.id,
            run.id,
            :target_request,
            1,
            "request-#{index}",
            %{"action" => "inspect", "request" => index},
            "Increase the Target request limit or inspect manually",
            authorize?: false
          )
        end)
      end)
      |> Task.await_many()

    assert Enum.all?(results, &match?({:ok, _result}, &1))
    statuses = Enum.map(results, fn {:ok, result} -> result.status end)
    assert Enum.sort(statuses) == [:charged, :charged, :exhausted]

    reloaded_run = Cases.get_resolution_run!(run.id, actor: context.viewer)
    assert reloaded_run.target_request_count == 2
    assert reloaded_run.status == :needs_attention

    reloaded_case = Cases.get_case!(incident.id, actor: context.viewer)
    assert reloaded_case.status == :needs_attention
    refute reloaded_case.status == :resolved
  end

  test "budget exhaustion rejects stale state and rolls back when its event cannot persist",
       context do
    {incident, run} = open!("atomic-exhaustion", context.operator)
    key = "budget-exhaustion-collision"
    pending = %{"action" => "inspect"}

    exhaust = fn case_revision ->
      Cases.mark_case_budget_exhausted(
        incident,
        case_revision,
        run.id,
        run.revision,
        "Target request limit exhausted",
        :target_request,
        :target_request,
        1,
        key,
        pending,
        "Inspect manually",
        %{},
        authorize?: false
      )
    end

    assert {:error, _error} = exhaust.(999)

    Cases.create_case_event_record!(
      %{
        case_id: incident.id,
        resolution_run_id: run.id,
        event_type: "reserved_key",
        idempotency_key: key,
        data: %{}
      },
      authorize?: false
    )

    assert {:error, _error} = exhaust.(incident.revision)

    assert Cases.get_case!(incident.id, actor: context.viewer).status == :running
    assert Cases.get_resolution_run!(run.id, actor: context.viewer).status == :running

    assert Enum.count(
             Cases.list_case_events!(actor: context.viewer),
             &(&1.case_id == incident.id and &1.idempotency_key == key)
           ) == 1
  end

  test "paid AI usage and its budget stop commit together and replay only once", context do
    {incident, run} = open!("paid-ai-stop", context.operator)

    Repo.query!("""
    CREATE FUNCTION pg_temp.reject_paid_ai_stop() RETURNS trigger LANGUAGE plpgsql AS $$
    BEGIN
      IF NEW.event_type = 'limit_exhausted' THEN RAISE EXCEPTION 'paid_ai_stop_unavailable'; END IF;
      RETURN NEW;
    END; $$;
    """)

    Repo.query!(
      "CREATE TRIGGER reject_paid_ai_stop BEFORE INSERT ON case_events FOR EACH ROW EXECUTE FUNCTION pg_temp.reject_paid_ai_stop()"
    )

    assert {:error, cause} = charge(incident, run, :ai_usage, 2, "paid-ai-stop")
    assert Exception.message(cause) =~ "paid_ai_stop_unavailable"
    assert Cases.get_resolution_run!(run.id, actor: context.viewer).ai_usage_units == 0
    assert Cases.get_resolution_run!(run.id, actor: context.viewer).status == :running
    assert Cases.get_case!(incident.id, actor: context.viewer).status == :running

    Repo.query!("DROP TRIGGER reject_paid_ai_stop ON case_events")

    for _attempt <- 1..2 do
      assert {:ok, result} = charge(incident, run, :ai_usage, 2, "paid-ai-stop")
      assert result.status == :exhausted
      assert Cases.get_resolution_run!(run.id, actor: context.viewer).ai_usage_units == 2
      assert Cases.get_case!(incident.id, actor: context.viewer).status == :needs_attention
    end

    assert Enum.count(
             Cases.list_case_events!(actor: context.viewer),
             &(&1.case_id == incident.id and &1.event_type == "limit_exhausted")
           ) == 1
  end

  test "each finite limit persists its exact handoff and never marks the Case resolved",
       context do
    scenarios = [
      {:turn,
       fn incident, run ->
         start!(incident, run, "turn-at-limit", %{"action" => "inspect"})
         start!(incident, run, "turn-over-limit", %{"action" => "inspect-next"})
       end},
      {:target_request,
       fn incident, run ->
         charge!(incident, run, :target_request, 2, "target-at-limit")
         charge!(incident, run, :target_request, 1, "target-over-limit")
       end},
      {:effect,
       fn incident, run ->
         charge!(incident, run, :effect, 1, "effect-over-limit")
       end},
      {:related_target,
       fn incident, run ->
         charge!(incident, run, :related_target, 1, "related-over-limit")
       end},
      {:ai_usage,
       fn incident, run ->
         charge!(incident, run, :ai_usage, 2, "ai-over-limit")
       end},
      {:no_progress,
       fn incident, run ->
         started = start!(incident, run, "no-progress-turn", %{"action" => "inspect"})
         completed = complete!(started.value, %{"finding" => "none"}, :none)
         assert completed.status in [:charged, :duplicate]

         charge_with_limit!(
           incident,
           run,
           :target_request,
           1,
           "after-no-progress",
           "no_progress"
         )
       end},
      {:elapsed,
       fn incident, run ->
         past = DateTime.add(DateTime.utc_now(), -1, :second)

         Repo.update_all(
           from(item in ResolutionRun, where: item.id == ^run.id),
           set: [deadline_at: past]
         )

         charge_with_limit!(incident, run, :target_request, 1, "after-deadline", "elapsed")
       end}
    ]

    for {expected_limit, operation} <- scenarios do
      {incident, run} = open!("limit-#{expected_limit}", context.operator)
      pending = %{"action" => "continue", "limit" => to_string(expected_limit)}
      result = operation.(incident, run)

      assert result.status == :exhausted, "#{expected_limit} did not exhaust"
      assert result.case.status == :needs_attention
      assert result.case.pending_intent == pending
      refute result.case.status == :resolved

      replayed = operation.(incident, run)
      assert replayed.status == :exhausted
      assert replayed.reason == result.reason

      if expected_limit == :ai_usage do
        assert Cases.get_resolution_run!(run.id, actor: context.viewer).ai_usage_units == 2
      end

      events =
        Cases.list_case_events!(actor: context.viewer)
        |> Enum.filter(&(&1.case_id == incident.id))

      assert Enum.count(events, &(&1.event_type == "limit_exhausted")) == 1
      event = List.last(events)

      assert event.event_type == "limit_exhausted"
      assert event.data["limit"] == to_string(expected_limit)
      assert event.data["pending_intent"] == pending
      assert event.data["required_human_input"] == "Review the exhausted limit"
    end
  end

  test "a Turn cannot commit its budget charge without a persisted Resolver job", context do
    {incident, run} = open!("turn-job-persistence", context.operator)
    before_run = Cases.get_resolution_run!(run.id, actor: context.viewer)
    before_case = Cases.get_case!(incident.id, actor: context.viewer)
    before_events = Cases.list_case_events!(actor: context.viewer)

    Repo.query!("""
    CREATE FUNCTION pg_temp.reject_resolver_job() RETURNS trigger LANGUAGE plpgsql AS $$
    BEGIN
      IF NEW.worker = 'Skopos.Cases.Turn.ResolverWorker' THEN RETURN NULL; END IF;
      RETURN NEW;
    END;
    $$;
    """)

    Repo.query!("""
    CREATE TRIGGER reject_resolver_job BEFORE INSERT ON oban_jobs
    FOR EACH ROW EXECUTE FUNCTION pg_temp.reject_resolver_job()
    """)

    assert {:error, _error} = start(incident, run, "turn", %{"action" => "inspect"})
    assert Cases.get_resolution_run!(run.id, actor: context.viewer) == before_run
    assert Cases.get_case!(incident.id, actor: context.viewer) == before_case
    assert Cases.list_case_events!(actor: context.viewer) == before_events
    assert Cases.list_turns!(actor: context.viewer) == []

    Repo.query!("DROP TRIGGER reject_resolver_job ON oban_jobs")

    accepted = start!(incident, run, "turn", %{"action" => "inspect"})
    assert accepted.status == :charged
    assert start!(incident, run, "turn", %{"action" => "inspect"}).status == :duplicate
    assert Cases.get_resolution_run!(run.id, actor: context.viewer).turn_count == 1
    assert [%Oban.Job{id: job_id}] = jobs_for(accepted.value.id)
    assert is_integer(job_id)
    assert length(Cases.list_turns!(actor: context.viewer)) == 1
  end

  test "a budget replay cannot use a charge from a previous resolution generation", context do
    {incident, run} = open!("budget-replay-generation", context.operator)
    charged = charge!(incident, run, :target_request, 1, "same-request")
    assert charge!(incident, run, :target_request, 1, "same-request").status == :duplicate

    attention =
      Cases.require_case_attention!(
        incident.id,
        incident.revision,
        run.id,
        charged.run.revision,
        "pause-for-resume",
        "Operator requested another resolution generation",
        %{"action" => "continue"},
        "Resume resolution",
        authorize?: false
      )

    paused = Cases.active_resolution_run!(incident.id, authorize?: false)

    resumed =
      Cases.resume_case!(
        attention.id,
        attention.revision,
        paused.id,
        paused.revision,
        :auto,
        paused.max_elapsed_seconds + 60,
        paused.max_resolver_turns + 1,
        paused.max_target_requests,
        paused.max_effects,
        paused.max_related_targets,
        paused.max_ai_usage_units,
        paused.max_no_progress_turns,
        "Retry resolution in a new generation",
        actor: context.operator
      )

    before_run = Cases.get_resolution_run!(resumed.id, actor: context.viewer)
    before_case = Cases.get_case!(incident.id, actor: context.viewer)
    before_events = Cases.list_case_events!(actor: context.viewer)

    assert {:error, _error} = charge(incident, resumed, :target_request, 1, "same-request")

    assert Cases.get_resolution_run!(resumed.id, actor: context.viewer) == before_run
    assert Cases.get_case!(incident.id, actor: context.viewer) == before_case
    assert Cases.list_case_events!(actor: context.viewer) == before_events
  end

  for {producer, kind, type, kind_field, amount_field, expected_replay} <- [
        {:charged, :target_request, "budget_charged", "kind", "amount", :duplicate},
        {:exhausted, :effect, "limit_exhausted", "attempted_kind", "attempted_amount", :exhausted}
      ],
      fault <- [:missing_kind, :missing_amount, :changed_kind, :changed_amount, :changed_type] do
    @tag budget_fault: fault
    test "a #{producer} budget replay rejects #{fault} in its persisted event", context do
      producer = unquote(producer)
      fault = context.budget_fault
      kind = unquote(kind)
      type = unquote(type)
      kind_field = unquote(kind_field)
      amount_field = unquote(amount_field)
      {incident, run} = open!("budget-replay-#{producer}-#{fault}", context.operator)

      assert charge!(incident, run, kind, 1, "request").status == producer
      assert charge!(incident, run, kind, 1, "request").status == unquote(expected_replay)
      assert {:error, _error} = charge(incident, run, kind, 2, "request")

      event =
        Cases.list_case_events!(actor: context.viewer)
        |> Enum.find(&(&1.case_id == incident.id and &1.event_type == type))

      damaged =
        case fault do
          :missing_kind -> [data: Map.delete(event.data, kind_field)]
          :missing_amount -> [data: Map.delete(event.data, amount_field)]
          :changed_kind -> [data: Map.put(event.data, kind_field, "ai_usage")]
          :changed_amount -> [data: Map.put(event.data, amount_field, 2)]
          :changed_type -> [event_type: "case_claimed"]
        end

      # Simulate damage at the database boundary; replay and observation use Ash actions.
      Repo.update_all(
        from(item in Skopos.Cases.CaseEvent, where: item.id == ^event.id),
        set: damaged
      )

      before_run = Cases.get_resolution_run!(run.id, actor: context.viewer)
      before_case = Cases.get_case!(incident.id, actor: context.viewer)
      before_events = Cases.list_case_events!(actor: context.viewer)

      assert {:error, _error} = charge(incident, run, kind, 1, "request")

      assert Cases.get_resolution_run!(run.id, actor: context.viewer) == before_run
      assert Cases.get_case!(incident.id, actor: context.viewer) == before_case
      assert Cases.list_case_events!(actor: context.viewer) == before_events
    end
  end

  test "history has no authorized public mutation path and cancellation stops new charges",
       context do
    {incident, run} = open!("append-only", context.operator)
    started = start!(incident, run, "append-only-turn", %{"action" => "inspect"})

    assert {:error, %Ash.Error.Forbidden{}} =
             Cases.create_turn_record(
               %{
                 case_id: incident.id,
                 resolution_run_id: run.id,
                 ordinal: 2,
                 idempotency_key: "bypass",
                 status: :started,
                 intent: %{},
                 result: %{},
                 started_at: DateTime.utc_now()
               },
               actor: context.admin
             )

    assert {:error, %Ash.Error.Forbidden{}} =
             Cases.create_evidence_record(
               %{
                 case_id: incident.id,
                 resolution_run_id: run.id,
                 turn_id: started.value.id,
                 idempotency_key: "bypass",
                 kind: "bypass",
                 source: "test",
                 source_ref: "test",
                 content: %{},
                 observed_at: DateTime.utc_now()
               },
               actor: context.admin
             )

    cancelled =
      Cases.request_case_cancellation!(incident.id, incident.revision, actor: context.operator)

    assert cancelled.cancel_requested

    assert {:error, _error} =
             Cases.charge_resolution_run(
               incident.id,
               run.id,
               :target_request,
               1,
               "cancelled-request",
               %{"action" => "inspect"},
               "Review cancellation",
               authorize?: false
             )
  end

  defp start!(incident, run, key, intent) do
    start(incident, run, key, intent) |> then(fn {:ok, result} -> result end)
  end

  defp start(incident, run, key, intent) do
    limit = limit_name(key)

    Cases.start_turn(
      incident.id,
      run.id,
      key,
      intent,
      %{"action" => "continue", "limit" => limit},
      "Review the exhausted limit",
      authorize?: false
    )
  end

  defp jobs_for(turn_id) do
    Oban.Job
    |> Repo.all()
    |> Enum.filter(&(&1.args["turn_id"] == turn_id))
  end

  defp complete!(turn, result, progress_kind) do
    Cases.complete_turn!(
      turn.id,
      turn.revision,
      result,
      progress_kind,
      %{"action" => "continue", "limit" => "no_progress"},
      "Review the exhausted limit",
      authorize?: false
    )
  end

  defp charge!(incident, run, kind, amount, key) do
    charge(incident, run, kind, amount, key)
    |> then(fn {:ok, result} -> result end)
  end

  defp charge_with_limit!(incident, run, kind, amount, key, limit) do
    Cases.charge_resolution_run!(
      incident.id,
      run.id,
      kind,
      amount,
      key,
      %{"action" => "continue", "limit" => limit},
      "Review the exhausted limit",
      authorize?: false
    )
  end

  defp charge(incident, run, kind, amount, key) do
    Cases.charge_resolution_run(
      incident.id,
      run.id,
      kind,
      amount,
      key,
      %{"action" => "continue", "limit" => to_string(kind)},
      "Review the exhausted limit",
      authorize?: false
    )
  end

  defp limit_name(key) do
    cond do
      String.starts_with?(key, "no-progress") -> "no_progress"
      true -> "turn"
    end
  end

  defp open!(source_ref, actor) do
    incident =
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

    {incident, Cases.active_resolution_run!(incident.id, authorize?: false)}
  end

  defp configure_limits!(admin) do
    current = Cases.current_authority_setting!(actor: admin)

    Cases.configure_authority_setting!(
      current.setting_revision,
      :auto,
      true,
      60,
      1,
      2,
      0,
      0,
      1,
      1,
      "configure history acceptance",
      actor: admin
    )
  end
end
