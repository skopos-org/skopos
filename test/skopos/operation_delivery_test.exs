defmodule Skopos.OperationDeliveryTest do
  use Skopos.DataCase, async: false

  alias Skopos.{Accounts, Cases, Providers, Reports, Signals, Targets}

  alias Skopos.Cases.Turn.ResolverDelivery, as: ResolverDelivery
  alias Skopos.Cases.Turn.ResolverProjection, as: ResolverProjection
  alias Skopos.Cases.Operation.AcceptanceWorker, as: OperationAcceptanceWorker
  alias Skopos.Cases.Operation.Delivery, as: OperationDelivery
  alias Skopos.Cases.Operation.Worker, as: OperationWorker
  alias Skopos.Cases.VerificationAttempt.Delivery, as: VerificationDelivery
  alias Skopos.Cases.VerificationAttempt.Worker, as: VerificationWorker

  alias Skopos.Cases.Case.ConditionContext, as: ConditionContext
  alias Skopos.Cases.Case.ConditionRecovery, as: ConditionRecovery
  alias Skopos.Cases.Case.SignalRecoveryCheckWorker, as: SignalRecoveryCheckWorker

  alias Skopos.Cases.CaseDispatch.Worker, as: CaseDispatchWorker
  alias Skopos.Targets.ResourceScope

  alias Skopos.Providers.{AI, Signal, Target}
  alias Skopos.Reports.Report.GenerationWorker

  @password "correct horse battery staple"

  setup tags do
    admin =
      Accounts.bootstrap!("operation-admin@example.com", @password, @password, authorize?: true)

    operator =
      Accounts.create_user!("operation-operator@example.com", @password, :operator, actor: admin)

    provider =
      Providers.create_provider!(
        "operation-target-provider",
        :target,
        "fixture-target",
        %{"endpoint" => "reachable"},
        %{"token" => if(tags[:normalized_capacity], do: "!", else: "operation-secret")},
        actor: admin
      )
      |> then(&Providers.enable_provider!(&1, 1, actor: admin))

    target = Targets.create_target!("operation-linux", "host", "linux", %{}, nil, actor: admin)

    method =
      Targets.create_access_method!(
        target.id,
        provider.id,
        "operation-ssh",
        "ssh",
        "ssh://operation-linux",
        provider.revision,
        10,
        ["effect.service", "observe.service"],
        actor: admin
      )
      |> then(&Targets.check_access_method!(&1.id, &1.revision, %{}, actor: admin))

    resolver_provider =
      Providers.create_provider!(
        "operation-resolver",
        :ai,
        "fixture-ai",
        %{"model" => "resolver-model"},
        %{"api_key" => "resolver-secret"},
        actor: admin
      )
      |> then(&Providers.check_provider!(&1.id, 1, %{}, actor: admin))
      |> then(&Providers.enable_provider!(&1, 1, actor: admin))

    resolver_assignment =
      Skopos.TestAIUsage.configure!(resolver_provider.id, :resolver, 10, admin)
      |> Map.fetch!(:resolver)

    reviewer_provider =
      Providers.create_provider!(
        "operation-reviewer",
        :ai,
        "fixture-ai",
        %{"model" => "reviewer-model"},
        %{"api_key" => "reviewer-secret"},
        actor: admin
      )
      |> then(&Providers.check_provider!(&1.id, 1, %{}, actor: admin))
      |> then(&Providers.enable_provider!(&1, 1, actor: admin))

    Skopos.TestAIUsage.configure!(reviewer_provider.id, :reviewer, 10, admin)

    configure_mode!(admin, :full_access)

    %{
      admin: admin,
      operator: operator,
      provider: provider,
      target: target,
      method: method,
      resolver_provider: resolver_provider,
      resolver_assignment: resolver_assignment,
      reviewer_provider: reviewer_provider
    }
  end

  for status <- [:applied, :unknown] do
    @tag changed_target_result: true, received_status: status
    test "a received #{status} effect survives changed instructions and returns to the Resolver",
         context do
      {incident, _run, proposal} =
        authorized_proposal!("changed-target-result", context)

      operation = Cases.accept_operation!(proposal.id, authorize?: false)
      details = %{"native_receipt" => "Original command receipt"}

      assert :ok =
               OperationDelivery.run(operation.id,
                 target_invocation:
                   invocation(fn ->
                     Targets.update_target!(
                       context.target,
                       context.target.revision,
                       %{operating_instructions: "Reassess under the changed instructions"},
                       actor: context.admin
                     )

                     {:ok,
                      %Target.EffectResult{
                        status: context.received_status,
                        details: details,
                        reference: "original-command"
                      }}
                   end)
               )

      saved = Cases.get_operation!(operation.id, actor: context.operator)
      assert saved.status == context.received_status
      assert saved.reference == "original-command"
      assert saved.result_details == details
      assert saved.outcome_category == "authorization_invalidated"
      current = Cases.get_case!(incident.id, actor: context.operator)
      assert current.pending_intent["action"] == "resolve_turn"
      assert current.pending_intent["source_operation_id"] == operation.id
      assert current.selected_target_revision == context.target.revision + 1

      assert Cases.verification_attempt_by_operation(operation.id,
               authorize?: false,
               not_found_error?: false
             ) == {:ok, nil}

      assert :ok =
               OperationDelivery.run(operation.id,
                 target_invocation: invocation(fn -> flunk("received effect was resent") end)
               )

      assert Cases.get_case!(incident.id, actor: context.operator).pending_intent ==
               current.pending_intent
    end
  end

  @tag changed_target_result: true
  test "a received effect persists before a failed post-response Case context read", context do
    {_incident, _run, proposal} = authorized_proposal!("received-context-read-fault", context)
    operation = Cases.accept_operation!(proposal.id, authorize?: false)
    details = %{"native_receipt" => "Confirmed command result"}

    try do
      assert {:error, error} =
               OperationDelivery.run(operation.id,
                 target_invocation:
                   invocation(fn ->
                     Repo.query!(
                       "ALTER TABLE cases RENAME COLUMN selected_target_revision TO unavailable_target_revision"
                     )

                     {:ok, %Target.EffectResult{status: :applied, details: details}}
                   end)
               )

      assert Exception.message(error) =~ "selected_target_revision"
    after
      Repo.query!(
        "ALTER TABLE cases RENAME COLUMN unavailable_target_revision TO selected_target_revision"
      )
    end

    saved = Cases.get_operation!(operation.id, actor: context.operator)
    assert saved.status == :applied
    assert saved.result_details == details

    assert :ok =
             OperationDelivery.run(operation.id,
               target_invocation: invocation(fn -> flunk("received effect was resent") end)
             )
  end

  for role <- [:resolver, :proposal, :recovery],
      stop <- [
        :cancel,
        :read_fault,
        :read_and_save_fault,
        :owner_death_then_cancel,
        :settlement_save_failure,
        :previous_unknown_accounted
      ] do
    @tag native_ai_stop: true, native_role: role, native_stop: stop
    test "native #{role} retains usage and cause after #{stop}", context do
      {context, peer} = native_reviewer!(context)

      {incident, run, turn} =
        if context.native_role == :resolver do
          provider = Providers.get_provider!(context.resolver_provider.id, actor: context.admin)
          Providers.disable_provider!(provider, provider.revision, actor: context.admin)
          Skopos.TestAIUsage.configure!(context.reviewer_provider.id, :all, 10, context.admin)

          incident =
            Cases.open_case!(
              :manual,
              "test",
              "native-other-stop",
              "The service is unavailable",
              :warning,
              %{"desired_outcome" => "The service responds"},
              nil,
              :en,
              actor: context.operator
            )

          run = Cases.active_resolution_run!(incident.id, authorize?: false)

          turn =
            Cases.start_turn!(
              incident.id,
              run.id,
              "native-stop-turn",
              %{"objective" => "Investigate"},
              %{"action" => "continue"},
              "Review limits",
              authorize?: false
            ).value

          {incident, run, turn}
        else
          if context.native_role == :proposal do
            configure_mode!(context.admin, :auto)
            authorized_proposal!("native-proposal-stop", context)
          else
            {incident, run, turn, _evidence} =
              recovery_conclusion!(context, "native-recovery-stop")

            Cases.route_downstream_decision!(turn.id, authorize?: false)
            {incident, run, turn}
          end
        end

      before_units = Cases.get_resolution_run!(run.id, authorize?: false).ai_usage_units
      prior_ids = MapSet.new(Cases.list_ai_invocations!(authorize?: false), & &1.id)
      Agent.update(peer, &%{&1 | mode: {:sleep, 1500}, requests: []})
      changed = :atomics.new(1, [])
      parent = self()

      if context.native_stop == :read_and_save_fault do
        Repo.query!("""
        CREATE FUNCTION pg_temp.reject_failed_ai_outcome() RETURNS trigger LANGUAGE plpgsql AS $$
        BEGIN
          IF NEW.status = 'failed' THEN RAISE EXCEPTION 'failed_ai_outcome_unavailable'; END IF;
          RETURN NEW;
        END; $$;
        """)

        Repo.query!(
          "CREATE TRIGGER reject_failed_ai_outcome BEFORE UPDATE ON ai_invocations FOR EACH ROW EXECUTE FUNCTION pg_temp.reject_failed_ai_outcome()"
        )
      end

      opts = [
        ai_invocation: %{
          cancelled?: fn ->
            if Agent.get(peer, &(&1.requests != [])) and
                 :atomics.compare_exchange(changed, 1, 0, 1) == :ok do
              if context.native_stop == :cancel do
                current = Cases.get_case!(incident.id, actor: context.operator)

                Cases.request_case_cancellation!(current.id, current.revision,
                  actor: context.operator
                )
              else
                if context.native_stop in [
                     :owner_death_then_cancel,
                     :settlement_save_failure,
                     :previous_unknown_accounted
                   ] do
                  send(parent, {:native_waiting, self()})
                else
                  {:error, error} =
                    Repo.query("SELECT native_other_ai_context_unavailable", [], mode: :savepoint)

                  raise error
                end
              end
            end

            false
          end
        }
      ]

      delivery =
        case context.native_role do
          :resolver -> ResolverDelivery
          :proposal -> Skopos.Cases.Proposal.ReviewDelivery
          :recovery -> Skopos.Cases.Turn.RecoveryReviewDelivery
        end

      result =
        if context.native_stop in [
             :owner_death_then_cancel,
             :settlement_save_failure,
             :previous_unknown_accounted
           ] do
          task = Task.async(fn -> delivery.run(turn.id, opts) end)
          owner = task.pid
          assert_receive {:native_waiting, ^owner}, 2_000
          assert nil == Task.shutdown(task, :brutal_kill)

          if context.native_stop == :previous_unknown_accounted do
            _first_accounting = delivery.run(turn.id)

            assert Cases.get_resolution_run!(run.id, authorize?: false).ai_usage_units >
                     before_units

            assert Agent.get(peer, &length(&1.requests)) == 1
          end

          current = Cases.get_case!(incident.id, actor: context.operator)
          Cases.request_case_cancellation!(current.id, current.revision, actor: context.operator)

          if context.native_stop == :settlement_save_failure do
            Repo.query!("""
            CREATE FUNCTION pg_temp.reject_stopped_ai_outcome() RETURNS trigger LANGUAGE plpgsql AS $$
            BEGIN
              IF NEW.status = 'unknown' THEN RAISE EXCEPTION 'stopped_ai_outcome_unavailable'; END IF;
              RETURN NEW;
            END; $$
            """)

            Repo.query!(
              "CREATE TRIGGER reject_stopped_ai_outcome BEFORE UPDATE ON ai_invocations FOR EACH ROW EXECUTE FUNCTION pg_temp.reject_stopped_ai_outcome()"
            )

            assert {:error, cause} = delivery.run(turn.id)
            assert Exception.message(cause) =~ "stopped_ai_outcome_unavailable"

            assert Cases.get_resolution_run!(run.id, authorize?: false).ai_usage_units ==
                     before_units

            assert [pending] =
                     Cases.list_ai_invocations!(authorize?: false)
                     |> Enum.reject(&MapSet.member?(prior_ids, &1.id))

            assert pending.status == :dispatching
            Repo.query!("DROP TRIGGER reject_stopped_ai_outcome ON ai_invocations")
          end

          delivery.run(turn.id)
        else
          delivery.run(turn.id, opts)
        end

      assert :atomics.get(changed, 1) == 1

      if context.native_stop == :read_and_save_fault do
        assert {:error, cause} = result
        assert Exception.message(cause) =~ "native_other_ai_context_unavailable"
        assert Exception.message(cause) =~ "failed_ai_outcome_unavailable"

        assert Cases.get_resolution_run!(run.id, authorize?: false).ai_usage_units == before_units

        assert [pending] =
                 Cases.list_ai_invocations!(authorize?: false)
                 |> Enum.reject(&MapSet.member?(prior_ids, &1.id))

        assert pending.status == :dispatching
        Repo.query!("DROP TRIGGER reject_failed_ai_outcome ON ai_invocations")
        current = Cases.get_case!(incident.id, actor: context.operator)
        Cases.request_case_cancellation!(current.id, current.revision, actor: context.operator)
        _settled = delivery.run(turn.id)
      end

      if context.native_stop in [
           :owner_death_then_cancel,
           :settlement_save_failure,
           :previous_unknown_accounted
         ],
         do: assert(result == :ok or match?({:cancel, _}, result), inspect(result))

      assert [invocation] =
               Cases.list_ai_invocations!(authorize?: false)
               |> Enum.reject(&MapSet.member?(prior_ids, &1.id))

      if context.native_stop in [
           :owner_death_then_cancel,
           :settlement_save_failure,
           :previous_unknown_accounted,
           :read_and_save_fault
         ] do
        assert invocation.status == :unknown
        assert invocation.category == "response_unknown"
      else
        assert invocation.status == :failed
        assert invocation.dispatch_confirmed
      end

      refute invocation.usage_reported

      assert Cases.get_resolution_run!(run.id, authorize?: false).ai_usage_units ==
               before_units + invocation.reserved_units

      if context.native_stop in [:read_fault, :read_and_save_fault] do
        assert {:error, error} = result
        assert Exception.message(error) =~ "native_other_ai_context_unavailable"
      else
        assert result == :ok or match?({:cancel, _}, result)
        assert Cases.get_case!(incident.id, actor: context.operator).status == :cancelled
      end

      _replay = delivery.run(turn.id)
      assert Agent.get(peer, &length(&1.requests)) == 1

      if context.native_stop != :read_fault do
        ended = Cases.get_resolution_run!(run.id, authorize?: false)
        assert ended.status == :cancelled
        refute ended.active
      end

      assert Cases.get_resolution_run!(run.id, authorize?: false).ai_usage_units ==
               before_units + invocation.reserved_units
    end
  end

  for boundary <- [:run_limit, :run_deadline] do
    @tag native_budget_transition: true, budget_boundary: boundary
    test "native Reviewer accounts its paid attempt after #{boundary}", context do
      {context, peer} = native_reviewer!(context)
      configure_mode!(context.admin, :auto)
      {_incident, run, proposal} = authorized_proposal!("native-budget-stop", context)
      before_units = Cases.get_resolution_run!(run.id, authorize?: false).ai_usage_units

      Agent.update(peer, &%{&1 | mode: {:sleep, 1_500}, requests: []})
      changed = :atomics.new(1, [])

      _result =
        Skopos.Cases.Proposal.ReviewDelivery.run(proposal.id,
          ai_invocation: %{
            cancelled?: fn ->
              if Agent.get(peer, &(&1.requests != [])) and
                   :atomics.compare_exchange(changed, 1, 0, 1) == :ok do
                if context.budget_boundary == :run_limit do
                  current = Cases.get_resolution_run!(run.id, authorize?: false)

                  Cases.reallocate_resolution_run_limits!(
                    current,
                    current.revision,
                    %{max_ai_usage_units: 1},
                    authorize?: false
                  )
                else
                  Repo.query!(
                    "UPDATE resolution_runs SET deadline_at = now() - interval '1 second' WHERE id = $1",
                    [Ecto.UUID.dump!(run.id)]
                  )
                end
              end

              false
            end
          }
        )

      assert :atomics.get(changed, 1) == 1
      assert [invocation] = Cases.list_ai_invocations!(authorize?: false)
      assert invocation.status == :failed
      assert invocation.dispatch_confirmed

      units =
        if context.budget_boundary == :run_limit do
          assert invocation.usage_reported
          assert invocation.input_tokens + invocation.output_tokens == 12
          12
        else
          refute invocation.usage_reported
          invocation.reserved_units
        end

      for _attempt <- 1..2 do
        _replay = Skopos.Cases.Proposal.ReviewDelivery.run(proposal.id)
        current = Cases.get_resolution_run!(run.id, authorize?: false)
        assert current.ai_usage_units == before_units + units
        assert current.status == :needs_attention
        assert Agent.get(peer, &length(&1.requests)) == 1
      end

      assert Cases.list_approvals!(actor: context.admin) == []
    end
  end

  @tag native_waiting_context: true
  test "a native Reviewer waits with bounded Case reads and retains its completed result",
       context do
    {context, peer} = native_reviewer!(context)
    configure_mode!(context.admin, :auto)
    {_incident, run, proposal} = authorized_proposal!("native-bounded-wait", context)
    before_units = Cases.get_resolution_run!(run.id, authorize?: false).ai_usage_units

    Agent.update(
      peer,
      &Map.put(
        %{
          &1
          | mode:
              {:sleep, 1_500,
               %{
                 "verdict" => "rejected",
                 "purpose_assessment" => "unknown",
                 "reason" => "Fresh evidence is required"
               }},
            requests: []
        },
        :response_complete,
        false
      )
    )

    counts = :atomics.new(3, [])
    handler = "native-wait-#{Ecto.UUID.generate()}"

    :ok =
      :telemetry.attach(
        handler,
        [:skopos, :repo, :query],
        fn _, _, metadata, counters ->
          if metadata[:source] == "cases" and String.starts_with?(metadata.query, "SELECT") do
            :atomics.add(counters, 1, 1)

            if Agent.get(peer, &(&1.requests != [] and not &1.response_complete)),
              do: :atomics.add(counters, 3, 1)
          end
        end,
        counts
      )

    on_exit(fn -> :telemetry.detach(handler) end)

    assert :ok =
             Skopos.Cases.Proposal.ReviewDelivery.run(proposal.id,
               ai_invocation: %{
                 cancelled?: fn ->
                   :atomics.add(counts, 2, 1)
                   false
                 end
               }
             )

    assert :atomics.get(counts, 2) >= 30
    assert :atomics.get(counts, 3) <= 9

    IO.puts(
      "native Reviewer Case reads total=#{:atomics.get(counts, 1)} waiting=#{:atomics.get(counts, 3)} caller_checks=#{:atomics.get(counts, 2)}"
    )

    assert Agent.get(peer, &length(&1.requests)) == 1
    assert [invocation] = Cases.list_ai_invocations!(authorize?: false)
    assert invocation.status == :completed
    assert invocation.usage_reported

    assert Cases.get_resolution_run!(run.id, authorize?: false).ai_usage_units ==
             before_units + 12
  end

  @tag native_reviewer_context: true
  test "a native proposal Reviewer observes its changed assignment and settles paid uncertainty once",
       context do
    {context, peer} = native_reviewer!(context)
    configure_mode!(context.admin, :auto)
    {incident, run, proposal} = authorized_proposal!("native-review-role-change", context)
    before_units = Cases.get_resolution_run!(run.id, authorize?: false).ai_usage_units
    changed = :atomics.new(1, [])
    Agent.update(peer, &%{&1 | mode: {:sleep, 1_000}, requests: []})

    assert {:error, _retry} =
             Skopos.Cases.Proposal.ReviewDelivery.run(proposal.id,
               delivery_attempt: 1,
               max_delivery_attempts: 3,
               ai_invocation: %{
                 cancelled?: fn ->
                   if Agent.get(peer, &(&1.requests != [])) and
                        :atomics.compare_exchange(changed, 1, 0, 1) == :ok,
                      do:
                        Skopos.TestAIUsage.configure!(
                          context.reviewer_provider.id,
                          :reviewer,
                          11,
                          context.admin
                        )

                   false
                 end
               }
             )

    assert :atomics.get(changed, 1) == 1
    assert Agent.get(peer, &length(&1.requests)) == 1
    assert [invocation] = Cases.list_ai_invocations!(authorize?: false)
    assert invocation.status == :failed
    assert invocation.category == "context_changed"
    assert invocation.dispatch_confirmed
    refute invocation.usage_reported

    assert Cases.get_resolution_run!(run.id, authorize?: false).ai_usage_units ==
             before_units + invocation.reserved_units

    assert Cases.get_case!(incident.id, actor: context.operator).status == :running
    assert Cases.list_review_decisions!(actor: context.admin) == []
    assert Cases.list_approvals!(actor: context.admin) == []

    assert {:error, _retry} =
             Skopos.Cases.Proposal.ReviewDelivery.run(proposal.id,
               delivery_attempt: 1,
               max_delivery_attempts: 3
             )

    assert Agent.get(peer, &length(&1.requests)) == 1

    assert Cases.get_resolution_run!(run.id, authorize?: false).ai_usage_units ==
             before_units + invocation.reserved_units

    Agent.update(
      peer,
      &%{
        &1
        | mode:
            {:decision,
             %{
               "verdict" => "rejected",
               "purpose_assessment" => "unknown",
               "reason" => "The proposed change needs fresh evidence"
             }}
      }
    )

    assert :ok =
             Skopos.Cases.Proposal.ReviewDelivery.run(proposal.id,
               delivery_attempt: 2,
               max_delivery_attempts: 3
             )

    assert Agent.get(peer, &length(&1.requests)) == 2

    assert Cases.get_resolution_run!(run.id, authorize?: false).ai_usage_units ==
             before_units + invocation.reserved_units + 12

    assert Cases.list_approvals!(actor: context.admin) == []

    assert Cases.get_case!(incident.id, actor: context.operator).pending_intent["action"] ==
             "resolve_turn"
  end

  for change <- [:reviewer_assignment, :condition_refired] do
    @tag native_reviewer_context: true, native_recovery_change: change
    test "a native Recovery Reviewer retains paid uncertainty and queues reassessment after #{change}",
         context do
      {context, peer} = native_reviewer!(context)

      if context.native_recovery_change == :condition_refired,
        do: enable_signal_automation!(context.admin)

      {incident, run, turn, _evidence} =
        recovery_conclusion!(context, "native-recovery-context-change",
          trigger_kind:
            if(context.native_recovery_change == :condition_refired, do: :signal, else: :manual),
          recover_before_proposal: true
        )

      signal_provider =
        if context.native_recovery_change == :condition_refired,
          do: Enum.find(Providers.list_providers!(actor: context.admin), &(&1.kind == :signal))

      Cases.route_downstream_decision!(turn.id, authorize?: false)
      before_units = Cases.get_resolution_run!(run.id, authorize?: false).ai_usage_units
      prior_ids = MapSet.new(Cases.list_ai_invocations!(authorize?: false), & &1.id)
      changed = :atomics.new(1, [])
      Agent.update(peer, &%{&1 | mode: {:sleep, 1_000}, requests: []})

      assert :ok =
               Skopos.Cases.Turn.RecoveryReviewDelivery.run(turn.id,
                 ai_invocation: %{
                   cancelled?: fn ->
                     if Agent.get(peer, &(&1.requests != [])) and
                          :atomics.compare_exchange(changed, 1, 0, 1) == :ok do
                       if context.native_recovery_change == :reviewer_assignment do
                         Skopos.TestAIUsage.configure!(
                           context.reviewer_provider.id,
                           :reviewer,
                           11,
                           context.admin
                         )
                       else
                         fire_signal!(
                           signal_provider,
                           context,
                           incident.initial_context["signal_event_key"],
                           "refired-during-native-review",
                           DateTime.add(DateTime.utc_now(), 1, :second)
                         )
                       end
                     end

                     false
                   end
                 }
               )

      assert :atomics.get(changed, 1) == 1
      assert Agent.get(peer, &length(&1.requests)) == 1

      assert [invocation] =
               Cases.list_ai_invocations!(authorize?: false)
               |> Enum.reject(&MapSet.member?(prior_ids, &1.id))

      assert invocation.role == :reviewer
      assert invocation.status == :failed
      assert invocation.category == "context_changed"
      assert invocation.dispatch_confirmed
      refute invocation.usage_reported

      assert Cases.get_resolution_run!(run.id, authorize?: false).ai_usage_units ==
               before_units + invocation.reserved_units

      current = Cases.get_case!(incident.id, actor: context.operator)
      assert current.status == :running
      assert current.pending_intent["action"] == "resolve_turn"
      refute current.pending_intent["turn_id"] == turn.id
      successor = Cases.get_turn!(current.pending_intent["turn_id"], actor: context.operator)
      assert successor.intent["source"] == "recovery_review_context_changed"

      refute Enum.any?(
               Cases.list_case_events!(actor: context.admin),
               &(&1.event_type == "case_resolved")
             )

      assert :ok = Skopos.Cases.Turn.RecoveryReviewDelivery.run(turn.id)
      assert Agent.get(peer, &length(&1.requests)) == 1

      assert Cases.get_case!(incident.id, actor: context.operator).pending_intent ==
               current.pending_intent

      assert Cases.get_resolution_run!(run.id, authorize?: false).ai_usage_units ==
               before_units + invocation.reserved_units
    end
  end

  @tag normalized_capacity: true
  test "maximum raw effect survives redaction and failed Evidence storage without losing its known result",
       context do
    details = %{"payload" => String.duplicate("!", 65_522)}
    expected = %{"payload" => String.duplicate("[REDACTED]", 65_522)}
    assert byte_size(Jason.encode!(details)) == 65_536
    assert byte_size(Jason.encode!(expected)) == 655_234

    {incident, _run, proposal} = authorized_proposal!("redacted-effect-receipt", context)
    operation = Cases.accept_operation!(proposal.id, authorize?: false)

    Repo.query!("""
    CREATE FUNCTION pg_temp.reject_redacted_receipt() RETURNS trigger LANGUAGE plpgsql AS $$
    BEGIN RAISE EXCEPTION 'Redacted receipt storage unavailable'; END;
    $$;
    """)

    Repo.query!("""
    CREATE TRIGGER reject_redacted_receipt BEFORE INSERT ON evidences
    FOR EACH ROW WHEN (NEW.source = 'operation')
    EXECUTE FUNCTION pg_temp.reject_redacted_receipt()
    """)

    try do
      assert {:error, error} =
               OperationDelivery.run(operation.id,
                 target_invocation:
                   invocation(fn ->
                     send(self(), :redacted_effect_sent)
                     {:ok, %Target.EffectResult{status: :applied, details: details}}
                   end)
               )

      assert Exception.message(error) =~ "Redacted receipt storage unavailable"
    after
      Repo.query!("DROP TRIGGER reject_redacted_receipt ON evidences")
    end

    assert_received :redacted_effect_sent
    saved = Cases.get_operation!(operation.id, actor: context.operator)
    assert saved.status == :applied
    assert saved.result_details == expected

    for _ <- 1..2 do
      assert :ok =
               OperationDelivery.run(operation.id,
                 target_invocation:
                   invocation(fn -> flunk("known redacted effect was resent") end)
               )
    end

    page = Cases.page_case_evidence!(incident.id, actor: context.operator)
    receipt = Enum.find(page.results, &(&1.source_ref == operation.id))
    assert receipt.summary["status"] == "applied"
    receipt = Cases.get_evidence!(receipt.id, actor: context.operator)
    assert receipt.content["details"] == expected
    assert Enum.count(page.results, &(&1.source_ref == operation.id)) == 1
    assert Cases.get_operation!(operation.id, actor: context.operator).status == :applied
  end

  @tag normalized_verification: true, normalized_capacity: true
  test "maximum raw verification keeps both redacted facts and provider evidence after a save failure",
       context do
    {incident, _run, proposal} = authorized_proposal!("redacted-verification-receipt", context)
    operation = Cases.accept_operation!(proposal.id, authorize?: false)

    assert :ok =
             OperationDelivery.run(operation.id,
               target_invocation: invocation({:ok, %Target.EffectResult{status: :applied}})
             )

    attempt = Cases.verification_attempt_by_operation!(operation.id, authorize?: false)
    facts = %{"payload" => String.duplicate("!", 32_742)}
    items = [%{"payload" => String.duplicate("!", 32_742)}]
    assert byte_size(Jason.encode!(%{"facts" => facts, "evidence" => items})) == 65_536
    expected_facts = %{"payload" => String.duplicate("[REDACTED]", 32_742)}
    expected_items = [%{"payload" => String.duplicate("[REDACTED]", 32_742)}]

    result = %Target.Verification{
      status: :verified,
      facts: facts,
      evidence: items,
      observed_at: DateTime.utc_now()
    }

    Repo.query!("""
    CREATE FUNCTION pg_temp.reject_redacted_verification() RETURNS trigger LANGUAGE plpgsql AS $$
    BEGIN RAISE EXCEPTION 'Redacted verification storage unavailable'; END;
    $$;
    """)

    Repo.query!("""
    CREATE TRIGGER reject_redacted_verification BEFORE INSERT ON evidences
    FOR EACH ROW WHEN (NEW.source = 'verification')
    EXECUTE FUNCTION pg_temp.reject_redacted_verification()
    """)

    try do
      assert {:error, error} =
               VerificationDelivery.run(attempt.id, target_invocation: invocation({:ok, result}))

      assert Exception.message(error) =~ "Redacted verification storage unavailable"
    after
      Repo.query!("DROP TRIGGER reject_redacted_verification ON evidences")
    end

    assert_receive {:verify, _, _}
    saved = Cases.get_verification_attempt!(attempt.id, actor: context.operator)
    assert saved.status == :verified
    assert saved.facts == expected_facts
    assert saved.provider_evidence == %{"items" => expected_items}

    for _ <- 1..2 do
      assert :ok =
               VerificationDelivery.run(attempt.id,
                 target_invocation: invocation(fn -> flunk("known verification was resent") end)
               )
    end

    receipt =
      Cases.page_case_evidence!(incident.id, actor: context.operator).results
      |> Enum.find(&(&1.source_ref == attempt.id))
      |> then(&Cases.get_evidence!(&1.id, actor: context.operator))

    assert receipt.content["facts"] == expected_facts
    assert receipt.content["provider_evidence"] == %{"items" => expected_items}
    refute_receive {:verify, _, _}
  end

  @tag normalized_reference: true, normalized_capacity: true
  test "a bounded opaque result reference retains its bytes through verification and public reads",
       context do
    {incident, _run, proposal} = authorized_proposal!("opaque-result-reference", context)
    operation = Cases.accept_operation!(proposal.id, authorize?: false)
    reference = " " <> String.duplicate("!", 65_534) <> " "
    expected = " " <> String.duplicate("[REDACTED]", 65_534) <> " "
    assert byte_size(reference) == 65_536
    assert byte_size(expected) == 655_342

    assert :ok =
             OperationDelivery.run(operation.id,
               target_invocation:
                 invocation(
                   {:ok,
                    %Target.EffectResult{
                      status: :applied,
                      reference: reference
                    }}
                 )
             )

    assert Cases.get_operation!(operation.id, actor: context.operator).reference == expected
    [attempt] = Cases.verification_attempts_for_case!(incident.id, actor: context.operator)
    assert attempt.operation_reference == expected

    assert :ok =
             VerificationDelivery.run(attempt.id,
               target_invocation:
                 invocation(
                   {:ok,
                    %Target.Verification{
                      status: :verified,
                      observed_at: DateTime.utc_now()
                    }}
                 )
             )

    assert_receive {:verify, _state, request}
    assert request.reference == expected

    assert :ok =
             OperationDelivery.run(operation.id,
               target_invocation:
                 invocation(fn -> flunk("opaque reference effect was resent") end)
             )

    assert operation_evidence_record(operation.id).content["reference"] == expected
    assert Cases.get_case!(incident.id, actor: context.operator).status == :running
  end

  @tag normalized_capacity: true
  test "maximum raw observation retains redacted data and observation time in canonical Evidence",
       context do
    {incident, _run, proposal} =
      authorized_proposal!("redacted-observation", context,
        request_kind: :observation,
        purpose: :investigation
      )

    operation = Cases.accept_operation!(proposal.id, authorize?: false)
    facts = %{"payload" => String.duplicate("!", 65_498)}
    assert byte_size(Jason.encode!(%{"facts" => facts, "evidence" => []})) == 65_536
    observed_at = ~U[2026-10-04 00:00:00.123456Z]
    expected = %{"payload" => String.duplicate("[REDACTED]", 65_498)}

    assert :ok =
             OperationDelivery.run(operation.id,
               target_invocation:
                 invocation(
                   {:ok,
                    %Target.Observation{
                      facts: facts,
                      evidence: [],
                      observed_at: observed_at
                    }}
                 )
             )

    assert_receive {:observe, _, _}
    saved = Cases.get_operation!(operation.id, actor: context.operator)
    assert saved.status == :applied

    assert saved.result_details == %{
             "facts" => expected,
             "evidence" => [],
             "observed_at" => "2026-10-04T00:00:00.123456Z"
           }

    assert :ok =
             OperationDelivery.run(operation.id,
               target_invocation: invocation(fn -> flunk("known observation was resent") end)
             )

    receipt =
      Cases.page_case_evidence!(incident.id, actor: context.operator).results
      |> Enum.find(&(&1.source_ref == operation.id))
      |> then(&Cases.get_evidence!(&1.id, actor: context.operator))

    assert receipt.content["facts"] == expected

    assert receipt.content["details"] == %{
             "evidence" => [],
             "observed_at" => "2026-10-04T00:00:00.123456Z"
           }

    assert receipt.kind == "observation"
  end

  @tag resolver_output_capacity: true
  test "an admitted large Resolver proposal retains its decision and charges usage only once",
       context do
    {:ok, catalog} = Skopos.Targets.Adapters.HTTP.capabilities(nil, %{})

    method =
      Targets.create_access_method!(
        context.target.id,
        context.provider.id,
        "large-output-http",
        "http",
        "http://fixture.example",
        context.provider.revision,
        20,
        Enum.map(catalog.effects, & &1.capability),
        actor: context.admin
      )

    Targets.check_access_method!(method.id, method.revision, invocation({:ok, catalog}),
      actor: context.admin
    )

    {incident, run, first} =
      authorized_proposal!("large-resolver-output", context, request_kind: :observation)

    operation = Cases.accept_operation!(first.id, authorize?: false)

    assert :ok =
             OperationDelivery.run(operation.id,
               target_invocation:
                 invocation(
                   {:ok,
                    %Target.Observation{
                      observed_at: DateTime.utc_now(),
                      facts: %{"service" => "unhealthy"}
                    }}
                 )
             )

    current = Cases.get_case!(incident.id, actor: context.operator)
    turn = Cases.get_turn!(current.pending_intent["turn_id"], authorize?: false)

    parameters = %{"method" => "POST", "path" => "/", "body" => String.duplicate("x", 64_700)}

    assert :ok =
             ResolverDelivery.run(turn.id,
               ai_invocation: %{
                 test_pid: self(),
                 respond: fn request ->
                   tool = Enum.find(request.proposal_tools, &(&1.operation == "request.execute"))

                   proposal =
                     struct!(
                       AI.Proposal,
                       Map.take(
                         Map.from_struct(tool),
                         ~w(target_id target_revision access_method_id access_method_revision request_kind capability operation)a
                       )
                       |> Map.merge(%{
                         tool_id: tool.id,
                         purpose: :investigation,
                         selectors: %{},
                         parameters: parameters,
                         reason: "Observe the current target",
                         evidence_ids: []
                       })
                     )

                   {:ok,
                    %AI.ResolverDecision{
                      intent: proposal,
                      usage: %AI.Usage{input_tokens: 7, output_tokens: 5}
                    }}
                 end
               }
             )

    saved = Cases.get_turn!(turn.id, authorize?: false)
    assert saved.result["intent"]["type"] == "proposal"
    assert saved.result["intent"]["parameters"] == parameters
    assert byte_size(Jason.encode!(saved.result)) > 65_536
    assert Cases.get_resolution_run!(run.id, authorize?: false).ai_usage_units == 12
    Cases.route_downstream_decision!(turn.id, authorize?: false)
    proposal = Cases.proposal_by_source_turn!(turn.id, authorize?: false)
    assert proposal.parameters == parameters

    assert :ok =
             ResolverDelivery.run(turn.id,
               ai_invocation: %{respond: fn _ -> flunk("saved paid AI decision was resent") end}
             )

    assert Cases.get_resolution_run!(run.id, authorize?: false).ai_usage_units == 12
  end

  @tag normalized_capacity: true
  test "the next Resolver receives the exact maximum normalized investigation receipt without replay",
       context do
    setting = Cases.current_authority_setting!(actor: context.admin)

    Cases.configure_authority_setting!(
      setting.setting_revision,
      setting.authority_mode,
      setting.signal_automation_enabled,
      setting.max_elapsed_seconds,
      setting.max_resolver_turns,
      setting.max_target_requests,
      setting.max_effects,
      setting.max_related_targets,
      1_000_000,
      setting.max_no_progress_turns,
      "Allow the measured large-input validation",
      actor: context.admin
    )

    parameters = %{"command" => String.duplicate("x", 60_000)}
    details = %{"payload" => String.duplicate("!", 65_522)}
    reference = " " <> String.duplicate("!", 65_534) <> " "
    expected = %{"payload" => String.duplicate("[REDACTED]", 65_522)}
    expected_reference = " " <> String.duplicate("[REDACTED]", 65_534) <> " "

    {incident, run, proposal} =
      authorized_proposal!("required-large-result", context,
        purpose: :investigation,
        parameters: parameters
      )

    operation = Cases.accept_operation!(proposal.id, authorize?: false)

    assert :ok =
             OperationDelivery.run(operation.id,
               target_invocation:
                 invocation(
                   {:ok,
                    %Target.EffectResult{status: :applied, details: details, reference: reference}}
                 )
             )

    current = Cases.get_case!(incident.id, actor: context.operator)
    receipt = Cases.get_evidence!(current.pending_intent["evidence_id"], actor: context.operator)
    turn = Cases.get_turn!(current.pending_intent["turn_id"], authorize?: false)
    assert receipt.content["facts"] == expected
    assert receipt.content["reference"] == expected_reference

    assert :ok =
             OperationDelivery.run(operation.id,
               target_invocation: invocation(fn -> flunk("known investigation was resent") end)
             )

    for index <- 1..101 do
      Cases.append_evidence!(
        incident.id,
        run.id,
        nil,
        "optional-receipt-note-#{index}",
        "operator_note",
        "fixture",
        "note-#{index}",
        %{"note" => index},
        DateTime.utc_now(),
        authorize?: false
      )
    end

    refute Enum.any?(
             Cases.resolver_evidence_window!(incident.id, run.id, authorize?: false),
             &(&1.id == receipt.id)
           )

    append_investigation_history!(operation, 101)

    with_projection_read_fault("evidences", "kind", "text", receipt.id, fn ->
      assert {:error, %Ash.Error.Unknown{} = error} =
               ResolverDelivery.run(turn.id,
                 ai_invocation: %{
                   respond: fn _ -> flunk("AI ran without its required receipt") end
                 }
               )

      assert Exception.message(error) =~ "Projection record temporarily unavailable"
    end)

    assert Cases.get_resolution_run!(run.id, authorize?: false).ai_usage_units == 0

    assert :ok =
             ResolverDelivery.run(turn.id,
               ai_invocation: %{
                 test_pid: self(),
                 respond: fn request ->
                   assert receipt.id in request.recovery_evidence_ids

                   {:ok,
                    %AI.ResolverDecision{
                      intent: %AI.RecoveryConclusion{
                        reason: "The exact returned payload satisfies the requested outcome",
                        evidence_ids: [receipt.id],
                        desired_outcome_claims: [
                          %{
                            "symptom_id" => request.case_symptom.id,
                            "evidence_id" => receipt.id,
                            "fact_keys" => ["payload"],
                            "reason" => "The actual payload is available for assessment"
                          }
                        ]
                      },
                      usage: %AI.Usage{input_tokens: 534_964, output_tokens: 203}
                    }}
                 end
               }
             )

    assert_received {:resolve, _, request}
    observed = Enum.find(request.evidence, &(&1.id == receipt.id))
    assert observed, "the continuation receipt must reach the Resolver"
    assert observed.content == receipt.content
    assert observed.content["parameters"] == parameters
    assert observed.content["facts"] == expected
    assert observed.content["reference"] == expected_reference

    [resolver_call] = Cases.list_ai_invocations!(authorize?: false)
    assert resolver_call.reserved_units == 1_000_000
    assert resolver_call.usage_reported
    assert resolver_call.input_tokens == 534_964
    assert resolver_call.output_tokens == 203

    assert :ok =
             ResolverDelivery.run(turn.id,
               ai_invocation: %{respond: fn _ -> flunk("saved paid AI result was resent") end}
             )

    assert Cases.get_resolution_run!(run.id, authorize?: false).ai_usage_units == 535_167

    assert Cases.route_downstream_decision!(turn.id, authorize?: false).pending_intent["action"] ==
             "review_recovery"

    assert :ok =
             Skopos.Cases.Turn.RecoveryReviewDelivery.run(turn.id,
               ai_invocation: %{
                 test_pid: self(),
                 respond: fn request ->
                   {:ok,
                    %AI.ReviewDecision{
                      purpose_assessment: :remediation,
                      verdict: :approved,
                      reason: "The cited payload directly supports the desired outcome",
                      desired_outcome_assessment: %{
                        "symptom_id" => request.case_symptom.id,
                        "desired_outcome" => request.case_symptom.desired_outcome,
                        "evidence_ids" => [receipt.id],
                        "status" => "supported",
                        "reason" => "The independent assessment used the exact receipt"
                      },
                      usage: %AI.Usage{input_tokens: 4, output_tokens: 2}
                    }}
                 end
               }
             )

    assert_received {:review_recovery, %{model: "reviewer-model"}, review_request}

    assert Enum.find(review_request.cited_evidence, &(&1.id == receipt.id)).content ==
             receipt.content

    assert Cases.get_case!(incident.id, actor: context.operator).status == :resolved

    assert :ok =
             Skopos.Cases.Turn.RecoveryReviewDelivery.run(turn.id,
               ai_invocation: %{respond: fn _ -> flunk("saved Reviewer result was resent") end}
             )

    assert Cases.get_resolution_run!(run.id, authorize?: false).ai_usage_units == 535_173
  end

  @tag normalized_capacity: true
  test "the proposal Reviewer receives the exact large cited receipt and proposed request",
       context do
    configure_mode!(context.admin, :auto)
    parameters = %{"command" => String.duplicate("x", 60_000)}

    {incident, run, proposal} =
      authorized_proposal!("large-proposal-review", context,
        purpose: :investigation,
        parameters: parameters
      )

    review = fn id ->
      Skopos.Cases.Proposal.ReviewDelivery.run(id,
        ai_invocation: %{
          test_pid: self(),
          respond: fn _request ->
            {:ok,
             %AI.ReviewDecision{
               verdict: :approved,
               purpose_assessment: :investigation,
               reason: "The exact proposal collects additional evidence",
               usage: %AI.Usage{input_tokens: 4, output_tokens: 2}
             }}
          end
        }
      )
    end

    assert :ok = review.(proposal.id)
    assert_received {:review, %{model: "reviewer-model"}, initial_review}
    assert initial_review.proposal.parameters == parameters
    source_result = Cases.get_turn!(proposal.source_turn_id, authorize?: false).result
    operation = Cases.accept_operation!(proposal.id, authorize?: false)

    assert :ok =
             OperationDelivery.run(operation.id,
               target_invocation:
                 invocation(
                   {:ok,
                    %Target.EffectResult{
                      status: :applied,
                      details: %{"payload" => String.duplicate("!", 65_522)},
                      reference: " " <> String.duplicate("!", 65_534) <> " "
                    }}
                 )
             )

    current = Cases.get_case!(incident.id, actor: context.operator)
    receipt = Cases.get_evidence!(current.pending_intent["evidence_id"], actor: context.operator)
    turn = Cases.get_turn!(current.pending_intent["turn_id"], authorize?: false)
    result = put_in(source_result, ["intent", "evidence_ids"], [receipt.id])

    Cases.complete_turn!(
      turn.id,
      turn.revision,
      result,
      :proposal,
      %{"action" => "route_resolver_decision", "turn_id" => turn.id},
      "Review the cited result and follow-up request",
      authorize?: false
    )

    fresh = Cases.materialize_proposal!(turn.id, authorize?: false)
    Cases.route_downstream_decision!(turn.id, authorize?: false)
    assert :ok = review.(fresh.id)
    assert_received {:review, %{model: "reviewer-model"}, request}
    assert request.proposal.parameters == parameters
    assert Enum.find(request.cited_evidence, &(&1.id == receipt.id)).content == receipt.content
    assert Cases.get_proposal!(fresh.id, actor: context.operator).status == :authorized
    assert Cases.get_resolution_run!(run.id, authorize?: false).ai_usage_units == 12

    assert :ok =
             Skopos.Cases.Proposal.ReviewDelivery.run(fresh.id,
               ai_invocation: %{respond: fn _ -> flunk("saved proposal review was resent") end}
             )
  end

  test "large admitted request and result survive an Evidence save failure without resending",
       context do
    parameters = %{"service" => "api", "padding" => String.duplicate("x", 60_000)}
    details = %{"payload" => String.duplicate("y", 65_522)}
    assert byte_size(Jason.encode!(details)) == 65_536

    {incident, _run, proposal} =
      authorized_proposal!("large-receipt", context, parameters: parameters)

    operation = Cases.accept_operation!(proposal.id, authorize?: false)

    Repo.query!("""
    CREATE FUNCTION pg_temp.reject_large_receipt() RETURNS trigger LANGUAGE plpgsql AS $$
    BEGIN RAISE EXCEPTION 'Receipt storage unavailable'; END;
    $$;
    """)

    Repo.query!("""
    CREATE TRIGGER reject_large_receipt BEFORE INSERT ON evidences
    FOR EACH ROW WHEN (NEW.source = 'operation')
    EXECUTE FUNCTION pg_temp.reject_large_receipt()
    """)

    try do
      assert {:error, error} =
               OperationDelivery.run(operation.id,
                 target_invocation:
                   invocation(fn ->
                     send(self(), :large_receipt_effect)
                     {:ok, %Target.EffectResult{status: :applied, details: details}}
                   end)
               )

      assert Exception.message(error) =~ "Receipt storage unavailable"
    after
      Repo.query!("DROP TRIGGER reject_large_receipt ON evidences")
    end

    assert_received :large_receipt_effect
    saved = Cases.get_operation!(operation.id, actor: context.operator)
    assert saved.status == :applied
    assert saved.parameters == parameters
    assert saved.result_details == details

    assert :ok =
             OperationDelivery.run(operation.id,
               target_invocation: invocation(fn -> flunk("saved effect was resent") end)
             )

    receipt = operation_evidence_record(operation.id)
    assert receipt.content["parameters"] == parameters
    assert receipt.content["details"] == details
    assert byte_size(Jason.encode!(receipt.content)) > 65_536

    assert :ok =
             OperationDelivery.run(operation.id,
               target_invocation: invocation(fn -> flunk("saved effect was resent") end)
             )

    page = Cases.page_case_evidence!(incident.id, actor: context.operator)
    public_receipt = Enum.find(page.results, &(&1.id == receipt.id))
    assert public_receipt.summary["status"] == "applied"

    assert Cases.get_evidence!(public_receipt.id, actor: context.operator).content ==
             receipt.content

    with_projection_read_fault("operations", "status", "text", operation.id, fn ->
      assert {:error, error} = Cases.page_case_evidence(incident.id, actor: context.operator)
      assert Exception.message(error) =~ "Projection record temporarily unavailable"
    end)

    assert Cases.get_evidence!(receipt.id, actor: context.operator).content == receipt.content

    receipts = Cases.list_evidence!(actor: context.operator)
    assert Enum.count(receipts, &(&1.source_ref == operation.id)) == 1
    assert Cases.get_case!(incident.id, actor: context.operator).status == :running
  end

  test "large verification receipts survive failed Evidence storage and retain the exact expectation",
       context do
    expected = %{"padding" => String.duplicate("z", 60_000)}

    {incident, _run, proposal} =
      authorized_proposal!("large-verification-receipt", context, verification_expected: expected)

    operation = Cases.accept_operation!(proposal.id, authorize?: false)

    assert :ok =
             OperationDelivery.run(operation.id,
               target_invocation: invocation({:ok, %Target.EffectResult{status: :applied}})
             )

    attempt = Cases.verification_attempt_by_operation!(operation.id, authorize?: false)
    facts = Map.put(expected, "observation", String.duplicate("y", 5_000))

    result = %Target.Verification{
      status: :verified,
      facts: facts,
      observed_at: DateTime.utc_now()
    }

    Repo.query!("""
    CREATE FUNCTION pg_temp.reject_verification_receipt() RETURNS trigger LANGUAGE plpgsql AS $$
    BEGIN RAISE EXCEPTION 'Verification receipt storage unavailable'; END;
    $$;
    """)

    Repo.query!("""
    CREATE TRIGGER reject_verification_receipt BEFORE INSERT ON evidences
    FOR EACH ROW WHEN (NEW.source = 'verification')
    EXECUTE FUNCTION pg_temp.reject_verification_receipt()
    """)

    try do
      assert {:error, error} =
               VerificationDelivery.run(attempt.id, target_invocation: invocation({:ok, result}))

      assert Exception.message(error) =~ "Verification receipt storage unavailable"
    after
      Repo.query!("DROP TRIGGER reject_verification_receipt ON evidences")
    end

    assert_receive {:verify, _, _}
    saved = Cases.get_verification_attempt!(attempt.id, actor: context.operator)
    assert saved.status == :verified
    assert saved.facts == facts
    assert saved.expected == expected

    for _ <- 1..2 do
      assert :ok =
               VerificationDelivery.run(attempt.id,
                 target_invocation: invocation(fn -> flunk("saved verification was resent") end)
               )
    end

    page = Cases.page_case_evidence!(incident.id, actor: context.operator)
    receipt = Enum.find(page.results, &(&1.source_ref == attempt.id))
    assert receipt.summary["status"] == "verified"
    receipt = Cases.get_evidence!(receipt.id, actor: context.operator)
    assert receipt.content["facts"] == facts
    assert receipt.content["expected"] == expected
    assert byte_size(Jason.encode!(receipt.content)) > 65_536
    assert Enum.count(page.results, &(&1.source_ref == attempt.id)) == 1

    assert Cases.get_case!(incident.id, actor: context.operator).pending_intent["action"] ==
             "resolve_turn"

    refute_receive {:verify, _, _}
  end

  test "canonical Evidence requires the original terminal source, scope and observation time",
       context do
    {incident, run, proposal} = authorized_proposal!("receipt-provenance", context)
    operation = Cases.accept_operation!(proposal.id, authorize?: false)

    assert {:error, _} =
             Cases.append_evidence(
               incident.id,
               run.id,
               nil,
               "queued-receipt",
               "operation_outcome",
               "operation",
               operation.id,
               %{"target_id" => operation.target_id},
               DateTime.utc_now(),
               authorize?: false
             )

    assert :ok =
             OperationDelivery.run(operation.id,
               target_invocation: invocation({:ok, %Target.EffectResult{status: :applied}})
             )

    saved = Cases.get_operation!(operation.id, authorize?: false)
    attempt = Cases.verification_attempt_by_operation!(saved.id, authorize?: false)

    assert {:error, _} =
             Cases.append_evidence(
               incident.id,
               run.id,
               nil,
               "queued-verification-receipt",
               "target_verification",
               "verification",
               attempt.id,
               %{"target_id" => attempt.target_id},
               DateTime.utc_now(),
               authorize?: false
             )

    assert :ok =
             VerificationDelivery.run(attempt.id,
               target_invocation: invocation({:ok, verified_result(%{"service" => "running"})})
             )

    verified = Cases.get_verification_attempt!(attempt.id, authorize?: false)
    {other_case, other_run, _proposal} = authorized_proposal!("receipt-other-case", context)
    before_ids = Cases.list_evidence!(actor: context.operator) |> Enum.map(& &1.id) |> Enum.sort()

    for {key, case_id, run_id, kind, source_ref, target_id, observed_at} <- [
          {"foreign-case", other_case.id, other_run.id, "operation_outcome", saved.id,
           saved.target_id, saved.completed_at},
          {"missing-source", incident.id, run.id, "operation_outcome", Ecto.UUID.generate(),
           saved.target_id, saved.completed_at},
          {"wrong-kind", incident.id, run.id, "observation", saved.id, saved.target_id,
           saved.completed_at},
          {"wrong-target", incident.id, run.id, "operation_outcome", saved.id,
           Ecto.UUID.generate(), saved.completed_at},
          {"wrong-time", incident.id, run.id, "operation_outcome", saved.id, saved.target_id,
           DateTime.add(saved.completed_at, 1, :second)}
        ] do
      assert {:error, %Ash.Error.Invalid{} = error} =
               Cases.append_evidence(
                 case_id,
                 run_id,
                 nil,
                 key,
                 kind,
                 "operation",
                 source_ref,
                 %{"target_id" => target_id},
                 observed_at,
                 authorize?: false
               )

      assert Exception.message(error) =~ "no matching terminal Operation receipt"
    end

    for {key, case_id, run_id, source_ref, observed_at} <- [
          {"foreign-verification", other_case.id, other_run.id, verified.id,
           verified.observed_at},
          {"missing-verification", incident.id, run.id, Ecto.UUID.generate(),
           verified.observed_at},
          {"wrong-verification-time", incident.id, run.id, verified.id,
           DateTime.add(verified.observed_at, 1, :second)}
        ] do
      assert {:error, %Ash.Error.Invalid{} = error} =
               Cases.append_evidence(
                 case_id,
                 run_id,
                 nil,
                 key,
                 "target_verification",
                 "verification",
                 source_ref,
                 %{"target_id" => verified.target_id},
                 observed_at,
                 authorize?: false
               )

      assert Exception.message(error) =~ "no matching terminal Verification receipt"
    end

    assert Cases.list_evidence!(actor: context.operator) |> Enum.map(& &1.id) |> Enum.sort() ==
             before_ids
  end

  test "a delayed observation persists its due time and sends once without another Resolver call",
       context do
    {incident, run, proposal} =
      authorized_proposal!("delayed-observation", context,
        request_kind: :observation,
        delay_seconds: 2
      )

    assert Map.get(proposal, :delay_seconds) == 2
    operation = Cases.accept_operation!(proposal.id, authorize?: false)
    assert DateTime.diff(operation.not_before, proposal.inserted_at, :second) == 2
    assert operation_job(operation.id).scheduled_at == operation.not_before

    invocation =
      invocation(fn ->
        send(self(), :delayed_observation_sent)

        {:ok,
         %Target.Observation{
           facts: %{"service" => "running"},
           observed_at: DateTime.utc_now(),
           evidence: []
         }}
      end)

    assert {:snooze, seconds} = OperationDelivery.run(operation.id, target_invocation: invocation)
    assert seconds in 1..2
    refute_receive :delayed_observation_sent
    queued = Cases.get_operation!(operation.id, actor: context.operator)
    assert queued.status == :queued
    assert queued.dispatch_started_at == nil
    assert Cases.get_case!(incident.id, actor: context.operator).status == :running
    assert Cases.get_resolution_run!(run.id, authorize?: false).target_request_count == 1
    assert Cases.list_ai_invocations!(actor: context.operator) == []

    remaining = max(DateTime.diff(operation.not_before, DateTime.utc_now(), :millisecond), 0)
    Process.sleep(remaining + 10)
    assert :ok = OperationDelivery.run(operation.id, target_invocation: invocation)
    assert_receive :delayed_observation_sent
    assert Cases.get_operation!(operation.id, actor: context.operator).status == :applied
    assert :ok = OperationDelivery.run(operation.id, target_invocation: invocation)
    refute_receive :delayed_observation_sent
    assert Cases.get_resolution_run!(run.id, authorize?: false).target_request_count == 1
  end

  test "a protected remote result survives delivery without entering public Case evidence",
       context do
    {incident, _run, proposal} =
      authorized_proposal!("protected-result", context)

    operation = Cases.accept_operation!(proposal.id, authorize?: false)
    protected = %{"uri" => "/vendor/monitor/42?ticket=operation-secret", "kind" => "task"}

    result =
      %Target.EffectResult{status: :unknown, details: %{"http_status" => 202}}
      |> Map.put(:protected_reference, protected)

    assert :ok = OperationDelivery.run(operation.id, target_invocation: invocation({:ok, result}))
    stored = Cases.get_operation!(operation.id, authorize?: false)
    assert stored.status == :unknown
    assert stored.reference == operation.id

    ciphertext =
      Repo.query!("SELECT encrypted_protected_reference FROM operations WHERE id = $1", [
        Ecto.UUID.dump!(operation.id)
      ]).rows
      |> hd()
      |> hd()

    assert is_binary(ciphertext)
    refute ciphertext =~ "operation-secret"
    refute ciphertext =~ "/vendor/monitor/42"

    public = Cases.get_operation!(operation.id, actor: context.operator)
    serialized = SkoposWeb.API.V1.WorkflowJSON.operation(public) |> Jason.encode!()
    refute serialized =~ "ticket"
    refute serialized =~ "operation-secret"

    evidence =
      Cases.evidence_by_idempotency!(incident.id, "operation:outcome:#{operation.id}",
        authorize?: false
      )

    refute Jason.encode!(evidence.content) =~ "ticket"
    assert evidence.content["reference"] == operation.id

    attempt = Cases.verification_attempt_by_operation!(operation.id, authorize?: false)

    assert :ok =
             VerificationDelivery.run(attempt.id,
               target_invocation: %{
                 test_pid: self(),
                 respond: fn invocation ->
                   reader = Map.fetch!(invocation, :result_reference_reader)
                   assert reader.(operation.id) == {:ok, protected}
                   assert {:error, _} = reader.(Ecto.UUID.generate())
                   send(invocation.test_pid, {:protected_reference_read, protected})

                   {:ok,
                    %Target.Verification{
                      status: :unknown,
                      observed_at: DateTime.utc_now(),
                      facts: %{"task_state" => "Running"}
                    }}
                 end
               }
             )

    assert_receive {:protected_reference_read, ^protected}
    assert Cases.get_verification_attempt!(attempt.id, authorize?: false).status == :unknown

    assert :ok =
             OperationDelivery.run(operation.id,
               target_invocation:
                 invocation(fn -> flunk("accepted remote write was repeated") end)
             )

    assert Cases.get_operation!(operation.id, authorize?: false).reference == operation.id
  end

  @tag protected_reference_read_fault: true
  test "a failed local reference read retries verification without repeating the remote write",
       context do
    {incident, _run, proposal} = authorized_proposal!("protected-input-fault", context)
    operation = Cases.accept_operation!(proposal.id, authorize?: false)

    protected = %{
      "kind" => "redfish_task_monitor",
      "uri" => "/vendor/tasks/7?ticket=operation-secret"
    }

    result = %Target.EffectResult{status: :unknown, protected_reference: protected}
    assert :ok = OperationDelivery.run(operation.id, target_invocation: invocation({:ok, result}))
    attempt = Cases.verification_attempt_by_operation!(operation.id, authorize?: false)
    before_invocations = Cases.list_ai_invocations!(authorize?: false)

    assert {:error, error} =
             VerificationDelivery.run(attempt.id,
               target_invocation: %{
                 test_pid: self(),
                 respond: fn invocation ->
                   Repo.query!(
                     "ALTER TABLE access_methods RENAME COLUMN capabilities TO unreadable_capabilities"
                   )

                   try do
                     assert {:error, error} = invocation.result_reference_reader.(operation.id)
                     assert Exception.message(error) =~ "does not exist"
                     {:error, Target.BeforeSendError.exception(cause: error)}
                   after
                     Repo.query!(
                       "ALTER TABLE access_methods RENAME COLUMN unreadable_capabilities TO capabilities"
                     )
                   end
                 end
               }
             )

    assert Exception.message(error) =~ "does not exist"
    unsent = Cases.get_verification_attempt!(attempt.id, authorize?: false)
    assert unsent.status == :queued
    assert unsent.dispatch_started_at == nil
    assert Cases.get_operation!(operation.id, authorize?: false).status == :unknown
    assert Cases.list_ai_invocations!(authorize?: false) == before_invocations

    assert :ok =
             VerificationDelivery.run(attempt.id,
               target_invocation: %{
                 test_pid: self(),
                 respond: fn invocation ->
                   assert {:ok, ^protected} = invocation.result_reference_reader.(operation.id)

                   {:ok,
                    %Target.Verification{
                      status: :unknown,
                      observed_at: DateTime.utc_now(),
                      facts: %{"task_state" => "Running"}
                    }}
                 end
               }
             )

    assert :ok =
             OperationDelivery.run(operation.id,
               target_invocation: invocation(fn -> flunk("remote write repeated") end)
             )

    assert Cases.get_case!(incident.id, authorize?: false).status == :running
  end

  @tag protected_reference_release_fault: true
  test "failed unsent release retains both errors and prevents an uncertain retry", context do
    {_incident, _run, proposal} = authorized_proposal!("protected-release-fault", context)
    operation = Cases.accept_operation!(proposal.id, authorize?: false)

    assert :ok =
             OperationDelivery.run(operation.id,
               target_invocation: invocation({:ok, %Target.EffectResult{status: :unknown}})
             )

    attempt = Cases.verification_attempt_by_operation!(operation.id, authorize?: false)

    Repo.query!("""
    CREATE FUNCTION pg_temp.reject_unsent_release() RETURNS trigger LANGUAGE plpgsql AS $$
    BEGIN
      IF OLD.status = 'dispatching' AND NEW.status = 'queued' THEN
        RAISE EXCEPTION 'test unsent release unavailable';
      END IF;
      RETURN NEW;
    END;
    $$;
    """)

    Repo.query!("""
    CREATE TRIGGER reject_unsent_release BEFORE UPDATE ON verification_attempts
    FOR EACH ROW EXECUTE FUNCTION pg_temp.reject_unsent_release()
    """)

    assert {:error, error} =
             VerificationDelivery.run(attempt.id,
               target_invocation:
                 invocation(fn ->
                   {:error,
                    Target.BeforeSendError.exception(
                      cause: RuntimeError.exception("test input read unavailable")
                    )}
                 end)
             )

    assert Exception.message(error) =~ "test input read unavailable"
    assert Exception.message(error) =~ "test unsent release unavailable"
    uncertain = Cases.get_verification_attempt!(attempt.id, authorize?: false)
    assert uncertain.status == :dispatching
    assert uncertain.dispatch_started_at != nil
    Repo.query!("DROP TRIGGER reject_unsent_release ON verification_attempts")

    assert :ok =
             VerificationDelivery.run(attempt.id,
               target_invocation: invocation(fn -> flunk("uncertain dispatch was repeated") end)
             )

    recovered = Cases.get_verification_attempt!(attempt.id, authorize?: false)
    assert recovered.status == :unknown
    assert recovered.outcome_category == "verification_interrupted"
    assert Cases.get_operation!(operation.id, authorize?: false).status == :unknown
  end

  @tag owned_context_read_fault: true
  test "a Method revision change after Operation claim prevents the effect", context do
    {_incident, _run, proposal} = authorized_proposal!("effect-method-changed", context)
    operation = Cases.accept_operation!(proposal.id, authorize?: false)
    changed = :atomics.new(1, [])

    assert :ok =
             OperationDelivery.run(operation.id,
               target_invocation:
                 invocation(fn -> flunk("obsolete Method dispatched an effect") end)
                 |> Map.put(:cancelled?, fn ->
                   if :atomics.compare_exchange(changed, 1, 0, 1) == :ok do
                     Targets.update_access_method!(
                       context.method,
                       context.method.revision,
                       %{priority: 11},
                       actor: context.admin
                     )
                   end

                   false
                 end)
             )

    refute_receive {:effect, _, _}
    saved = Cases.get_operation!(operation.id, authorize?: false)
    assert saved.status == :failed
    assert saved.dispatch_started_at == nil

    assert Cases.verification_attempt_by_operation!(operation.id,
             authorize?: false,
             not_found_error?: false
           ) == nil

    assert Cases.get_case!(operation.case_id, authorize?: false).pending_intent["action"] ==
             "resolve_turn"

    assert :ok =
             OperationDelivery.run(operation.id,
               target_invocation: invocation(fn -> flunk("obsolete effect was resent") end)
             )

    refute_receive {:effect, _, _}
  end

  @tag owned_context_read_fault: true
  test "a Method revision change after Verification claim prevents the observation", context do
    {_incident, _run, proposal} = authorized_proposal!("verify-method-changed", context)
    operation = Cases.accept_operation!(proposal.id, authorize?: false)

    assert :ok =
             OperationDelivery.run(operation.id,
               target_invocation: invocation({:ok, %Target.EffectResult{status: :applied}})
             )

    assert_receive {:effect, _, _}
    attempt = Cases.verification_attempt_by_operation!(operation.id, authorize?: false)
    changed = :atomics.new(1, [])

    VerificationDelivery.run(attempt.id,
      target_invocation:
        invocation(fn -> flunk("obsolete Method dispatched verification") end)
        |> Map.put(:cancelled?, fn ->
          if :atomics.compare_exchange(changed, 1, 0, 1) == :ok do
            Targets.update_access_method!(
              context.method,
              context.method.revision,
              %{priority: 11},
              actor: context.admin
            )
          end

          false
        end)
    )

    refute_receive {:verify, _, _}
    refute Cases.get_verification_attempt!(attempt.id, authorize?: false).status == :verified

    assert :ok =
             VerificationDelivery.run(attempt.id,
               target_invocation: invocation(fn -> flunk("obsolete verification was resent") end)
             )

    refute_receive {:verify, _, _}
  end

  @tag owned_context_read_fault: true
  test "built-in Operation and Verification Case read faults remain unsent retries", context do
    {_incident, _run, proposal} = authorized_proposal!("owned-target-context-read", context)
    operation = Cases.accept_operation!(proposal.id, authorize?: false)
    injected = :atomics.new(1, [])

    callback = fn ->
      if :atomics.compare_exchange(injected, 1, 0, 1) == :ok,
        do: Repo.query!("ALTER TABLE cases RENAME COLUMN title TO unavailable_case_title")

      false
    end

    try do
      assert {:error, error} =
               OperationDelivery.run(operation.id,
                 target_invocation:
                   invocation(fn -> flunk("an unreadable Case dispatched an effect") end)
                   |> Map.put(:cancelled?, callback)
               )

      assert Exception.message(error) =~ "title"
    after
      if :atomics.get(injected, 1) == 1,
        do: Repo.query!("ALTER TABLE cases RENAME COLUMN unavailable_case_title TO title")
    end

    assert Cases.get_operation!(operation.id, authorize?: false).status == :queued
    refute_receive {:effect, _, _}

    assert :ok =
             OperationDelivery.run(operation.id,
               target_invocation: invocation({:ok, %Target.EffectResult{status: :applied}})
             )

    assert_receive {:effect, _, _}
    attempt = Cases.verification_attempt_by_operation!(operation.id, authorize?: false)
    :atomics.put(injected, 1, 0)

    try do
      assert {:error, error} =
               VerificationDelivery.run(attempt.id,
                 target_invocation:
                   invocation(fn -> flunk("an unreadable Case dispatched verification") end)
                   |> Map.put(:cancelled?, callback)
               )

      assert Exception.message(error) =~ "title"
    after
      if :atomics.get(injected, 1) == 1,
        do: Repo.query!("ALTER TABLE cases RENAME COLUMN unavailable_case_title TO title")
    end

    assert Cases.get_verification_attempt!(attempt.id, authorize?: false).status == :queued
    refute_receive {:verify, _, _}
  end

  @tag target_callback_read_fault: true
  test "a context callback storage fault retries unsent Operation and Verification dispatches",
       context do
    {_incident, _run, proposal} = authorized_proposal!("dispatch-context-read-fault", context)
    operation = Cases.accept_operation!(proposal.id, authorize?: false)

    cancelled? = fn ->
      {:error, error} = Repo.query("SELECT target_context_unavailable", [], mode: :savepoint)
      raise error
    end

    assert {:error, error} =
             OperationDelivery.run(operation.id,
               target_invocation:
                 invocation(fn -> flunk("unsent effect ran") end)
                 |> Map.put(:cancelled?, cancelled?)
             )

    assert Exception.message(error) =~ "target_context_unavailable"
    unsent = Cases.get_operation!(operation.id, authorize?: false)
    assert unsent.status == :queued
    assert unsent.dispatch_started_at == nil
    refute_receive {:effect, _, _}

    assert :ok =
             OperationDelivery.run(operation.id,
               target_invocation: invocation({:ok, %Target.EffectResult{status: :applied}})
             )

    assert_receive {:effect, _, _}
    attempt = Cases.verification_attempt_by_operation!(operation.id, authorize?: false)

    assert {:error, error} =
             VerificationDelivery.run(attempt.id,
               target_invocation:
                 invocation(fn -> flunk("unsent verification ran") end)
                 |> Map.put(:cancelled?, cancelled?)
             )

    assert Exception.message(error) =~ "target_context_unavailable"
    unsent_attempt = Cases.get_verification_attempt!(attempt.id, authorize?: false)
    assert unsent_attempt.status == :queued
    assert unsent_attempt.dispatch_started_at == nil
    refute_receive {:verify, _, _}

    assert :ok =
             VerificationDelivery.run(attempt.id,
               target_invocation:
                 invocation(
                   {:ok, %Target.Verification{status: :verified, observed_at: DateTime.utc_now()}}
                 )
             )

    assert_receive {:verify, _, _}

    assert :ok =
             OperationDelivery.run(operation.id,
               target_invocation: invocation(fn -> flunk("completed effect replayed") end)
             )

    assert :ok =
             VerificationDelivery.run(attempt.id,
               target_invocation: invocation(fn -> flunk("completed verification replayed") end)
             )

    refute_receive {:effect, _, _}
    refute_receive {:verify, _, _}
  end

  for mode <- [:postgres, :missing_record] do
    @tag inflight_target_read_fault: true
    test "in-flight #{mode} Target context faults persist outcomes and original cause",
         context do
      progress = %{"bytes_sent" => 8, "steps" => [%{"op" => "receive", "data" => "Zmlyc3Q="}]}

      failed_response = fn ->
        {:error, cause} =
          case unquote(mode) do
            :postgres ->
              Repo.query("SELECT inflight_target_context_unavailable", [], mode: :savepoint)

            :missing_record ->
              Targets.get_target("00000000-0000-0000-0000-000000000000", authorize?: false)
          end

        {:error, Target.Error.context_failure(cause, progress)}
      end

      expected_message =
        if unquote(mode) == :postgres,
          do: "inflight_target_context_unavailable",
          else: "record not found"

      for kind <- [:effect, :observation] do
        {_incident, _run, proposal} =
          authorized_proposal!("inflight-context-#{kind}", context, request_kind: kind)

        operation = Cases.accept_operation!(proposal.id, authorize?: false)

        assert {:error, error} =
                 OperationDelivery.run(operation.id,
                   target_invocation: invocation(failed_response)
                 )

        assert Exception.message(error) =~ expected_message
        if unquote(mode) == :missing_record, do: assert(%Ash.Error.Invalid{} = error)
        terminal = Cases.get_operation!(operation.id, authorize?: false)
        assert terminal.status == if(kind == :effect, do: :unknown, else: :failed)
        assert terminal.dispatch_started_at != nil
        assert terminal.result_details["progress"] == progress

        assert :ok =
                 OperationDelivery.run(operation.id,
                   target_invocation: invocation(fn -> flunk("in-flight request repeated") end)
                 )

        if kind == :effect do
          assert_receive {:effect, _, _}
          refute_receive {:effect, _, _}
        else
          assert_receive {:observe, _, _}
          refute_receive {:observe, _, _}
        end
      end

      {_incident, _run, proposal} =
        authorized_proposal!("inflight-verification-context", context,
          service: "verification-api"
        )

      operation = Cases.accept_operation!(proposal.id, authorize?: false)

      assert :ok =
               OperationDelivery.run(operation.id,
                 target_invocation: invocation({:ok, %Target.EffectResult{status: :applied}})
               )

      assert_receive {:effect, _, _}
      attempt = Cases.verification_attempt_by_operation!(operation.id, authorize?: false)

      assert {:error, error} =
               VerificationDelivery.run(attempt.id,
                 target_invocation: invocation(failed_response)
               )

      assert Exception.message(error) =~ expected_message
      if unquote(mode) == :missing_record, do: assert(%Ash.Error.Invalid{} = error)
      terminal = Cases.get_verification_attempt!(attempt.id, authorize?: false)
      assert terminal.status == :unknown
      assert terminal.dispatch_started_at != nil
      assert terminal.facts["progress"] == progress

      assert :ok =
               VerificationDelivery.run(attempt.id,
                 target_invocation: invocation(fn -> flunk("in-flight verification repeated") end)
               )

      assert_receive {:verify, _, _}
      refute_receive {:verify, _, _}
    end
  end

  @tag inflight_target_read_fault: true
  test "a failed in-flight fault receipt keeps both causes and never repeats the remote request",
       context do
    progress = %{"bytes_sent" => 8, "steps" => [%{"op" => "receive", "data" => "Zmlyc3Q="}]}

    for kind <- [:operation, :verification] do
      {_incident, _run, proposal} =
        authorized_proposal!("inflight-save-fault-#{kind}", context,
          service: "inflight-save-#{kind}"
        )

      operation = Cases.accept_operation!(proposal.id, authorize?: false)

      {record, delivery, table, get_record} =
        if kind == :operation do
          {operation, &OperationDelivery.run/2, "operations", &Cases.get_operation!/2}
        else
          assert :ok =
                   OperationDelivery.run(operation.id,
                     target_invocation: invocation({:ok, %Target.EffectResult{status: :applied}})
                   )

          assert_receive {:effect, _, _}
          attempt = Cases.verification_attempt_by_operation!(operation.id, authorize?: false)

          {attempt, &VerificationDelivery.run/2, "verification_attempts",
           &Cases.get_verification_attempt!/2}
        end

      Repo.query!("""
      CREATE FUNCTION pg_temp.reject_inflight_receipt() RETURNS trigger LANGUAGE plpgsql AS $$
      BEGIN
        IF NEW.status = 'unknown' THEN
          RAISE EXCEPTION 'inflight receipt save unavailable';
        END IF;
        RETURN NEW;
      END;
      $$;
      """)

      Repo.query!("""
      CREATE TRIGGER reject_inflight_receipt BEFORE UPDATE ON #{table}
      FOR EACH ROW EXECUTE FUNCTION pg_temp.reject_inflight_receipt()
      """)

      try do
        assert {:error, error} =
                 delivery.(record.id,
                   target_invocation:
                     invocation(fn ->
                       {:error, cause} =
                         Repo.query("SELECT inflight_target_context_unavailable", [],
                           mode: :savepoint
                         )

                       {:error, Target.Error.context_failure(cause, progress)}
                     end)
                 )

        assert Exception.message(error) =~ "inflight_target_context_unavailable"
        assert Exception.message(error) =~ "inflight receipt save unavailable"
        assert Target.Error.context_progress(error) == progress
      after
        Repo.query!("DROP TRIGGER reject_inflight_receipt ON #{table}")
        Repo.query!("DROP FUNCTION pg_temp.reject_inflight_receipt()")
      end

      assert get_record.(record.id, authorize?: false).status == :dispatching

      assert :ok =
               delivery.(record.id,
                 target_invocation: invocation(fn -> flunk("uncertain request replayed") end)
               )

      assert get_record.(record.id, authorize?: false).status == :unknown

      if kind == :operation do
        assert_receive {:effect, _, _}
        refute_receive {:effect, _, _}
      else
        assert_receive {:verify, _, _}
        refute_receive {:verify, _, _}
      end
    end
  end

  @tag dispatch_method_read_fault: true
  test "Method storage faults keep unsent Operation and Verification dispatches retryable",
       context do
    {_incident, _run, proposal} = authorized_proposal!("dispatch-method-fault", context)
    operation = Cases.accept_operation!(proposal.id, authorize?: false)

    Repo.query!(
      "ALTER TABLE access_methods RENAME COLUMN capabilities TO unreadable_capabilities"
    )

    try do
      assert {:error, error} =
               OperationDelivery.run(operation.id,
                 target_invocation: invocation(fn -> flunk("unsent operation ran") end)
               )

      assert Exception.message(error) =~ "does not exist"
    after
      Repo.query!(
        "ALTER TABLE access_methods RENAME COLUMN unreadable_capabilities TO capabilities"
      )
    end

    unsent = Cases.get_operation!(operation.id, authorize?: false)
    assert unsent.status == :queued
    assert unsent.dispatch_started_at == nil

    assert :ok =
             OperationDelivery.run(operation.id,
               target_invocation: invocation({:ok, %Target.EffectResult{status: :applied}})
             )

    attempt = Cases.verification_attempt_by_operation!(operation.id, authorize?: false)

    Repo.query!(
      "ALTER TABLE access_methods RENAME COLUMN capabilities TO unreadable_capabilities"
    )

    try do
      assert {:error, error} =
               VerificationDelivery.run(attempt.id,
                 target_invocation: invocation(fn -> flunk("unsent verification ran") end)
               )

      assert Exception.message(error) =~ "does not exist"
    after
      Repo.query!(
        "ALTER TABLE access_methods RENAME COLUMN unreadable_capabilities TO capabilities"
      )
    end

    unsent_attempt = Cases.get_verification_attempt!(attempt.id, authorize?: false)
    assert unsent_attempt.status == :queued
    assert unsent_attempt.dispatch_started_at == nil

    assert :ok =
             VerificationDelivery.run(attempt.id,
               target_invocation:
                 invocation(
                   {:ok, %Target.Verification{status: :verified, observed_at: DateTime.utc_now()}}
                 )
             )

    assert :ok =
             OperationDelivery.run(operation.id,
               target_invocation: invocation(fn -> flunk("original effect repeated") end)
             )
  end

  test "a protected result reader rechecks authority inside the follow-up dispatch", context do
    {incident, _run, proposal} = authorized_proposal!("protected-revocation", context)
    operation = Cases.accept_operation!(proposal.id, authorize?: false)
    protected = %{"uri" => "/vendor/tasks/7?ticket=operation-secret"}

    result =
      %Target.EffectResult{status: :unknown, details: %{"http_status" => 202}}
      |> Map.put(:protected_reference, protected)

    assert :ok = OperationDelivery.run(operation.id, target_invocation: invocation({:ok, result}))
    attempt = Cases.verification_attempt_by_operation!(operation.id, authorize?: false)

    assert :ok =
             VerificationDelivery.run(attempt.id,
               target_invocation: %{
                 test_pid: self(),
                 respond: fn invocation ->
                   reader = Map.fetch!(invocation, :result_reference_reader)
                   before = reader.(operation.id)
                   method = Targets.get_access_method!(context.method.id, actor: context.admin)

                   Targets.update_access_method!(
                     method,
                     method.revision,
                     %{capabilities: ["effect.service"]},
                     actor: context.admin
                   )

                   after_revocation = reader.(operation.id)
                   send(invocation.test_pid, {:reference_authority, before, after_revocation})

                   {:ok,
                    %Target.Verification{
                      status: :unknown,
                      observed_at: DateTime.utc_now(),
                      facts: %{"reference_unavailable" => true}
                    }}
                 end
               }
             )

    assert_receive {:reference_authority, {:ok, ^protected}, {:error, _}}
    current = Cases.get_case!(incident.id, actor: context.operator)
    assert current.status == :running
    assert Cases.get_operation!(operation.id, authorize?: false).status == :unknown
  end

  test "a protected outcome save failure cannot publish a reference or repeat the remote write",
       context do
    {incident, _run, proposal} = authorized_proposal!("protected-save-failure", context)
    operation = Cases.accept_operation!(proposal.id, authorize?: false)
    protected = %{"uri" => "/vendor/monitor/9?ticket=operation-secret"}

    Repo.query!("""
    CREATE FUNCTION pg_temp.reject_protected_operation_outcome() RETURNS trigger LANGUAGE plpgsql AS $$
    BEGIN
      IF NEW.encrypted_protected_reference IS NOT NULL THEN
        RAISE EXCEPTION 'test outcome publication unavailable';
      END IF;
      RETURN NEW;
    END;
    $$;
    """)

    Repo.query!("""
    CREATE TRIGGER reject_protected_operation_outcome BEFORE UPDATE ON operations
    FOR EACH ROW EXECUTE FUNCTION pg_temp.reject_protected_operation_outcome()
    """)

    assert {:error, _} =
             OperationDelivery.run(operation.id,
               target_invocation: %{
                 test_pid: self(),
                 respond: fn invocation ->
                   send(invocation.test_pid, :protected_write_sent)

                   {:ok,
                    %Target.EffectResult{
                      status: :unknown,
                      details: %{"http_status" => 202},
                      protected_reference: protected
                    }}
                 end
               }
             )

    assert_receive :protected_write_sent
    unsaved = Cases.get_operation!(operation.id, actor: context.operator)
    assert unsaved.status == :dispatching
    assert unsaved.reference == nil

    Repo.query!("DROP TRIGGER reject_protected_operation_outcome ON operations")

    assert :ok =
             OperationDelivery.run(operation.id,
               target_invocation: invocation(fn -> send(self(), :protected_write_sent) end)
             )

    refute_receive :protected_write_sent
    recovered = Cases.get_operation!(operation.id, actor: context.operator)
    assert recovered.status == :unknown
    assert recovered.outcome_category == "dispatch_interrupted"
    assert recovered.reference == nil

    evidence =
      Cases.evidence_by_idempotency!(incident.id, "operation:outcome:#{operation.id}",
        authorize?: false
      )

    assert evidence.content["status"] == "unknown"
    refute Jason.encode!(evidence.content) =~ "ticket"
    attempt = Cases.verification_attempt_by_operation!(operation.id, authorize?: false)

    assert :ok =
             VerificationDelivery.run(attempt.id,
               target_invocation: %{
                 test_pid: self(),
                 respond: fn invocation ->
                   result = invocation.result_reference_reader.(operation.id)
                   send(invocation.test_pid, {:unsaved_reference, result})

                   {:ok,
                    %Target.Verification{
                      status: :unknown,
                      observed_at: DateTime.utc_now(),
                      facts: %{}
                    }}
                 end
               }
             )

    assert_receive {:unsaved_reference, {:error, _}}
  end

  test "protected result reads require the current Case owner and the exact Method lineage",
       context do
    {incident, _run, proposal} = authorized_proposal!("protected-scope", context)
    operation = Cases.accept_operation!(proposal.id, authorize?: false)
    protected = %{"uri" => "/vendor/monitor/42?ticket=operation-secret"}

    assert :ok =
             OperationDelivery.run(operation.id,
               target_invocation:
                 invocation(
                   {:ok,
                    %Target.EffectResult{
                      status: :unknown,
                      protected_reference: protected,
                      details: %{"http_status" => 202}
                    }}
                 )
             )

    attempt = Cases.verification_attempt_by_operation!(operation.id, authorize?: false)

    request = %Skopos.Targets.TargetRequest.Request{
      kind: :verification,
      authority_mode: attempt.authority_mode,
      target_id: attempt.target_id,
      target_revision: attempt.target_revision,
      access_method_id: attempt.access_method_id,
      access_method_revision: attempt.access_method_revision,
      capability: attempt.capability,
      operation: attempt.operation,
      selectors: attempt.selectors,
      parameters: attempt.parameters,
      operation_id: attempt.operation_id,
      reference: attempt.operation_reference,
      expected: attempt.expected,
      max_attempts: 1
    }

    clearance = Targets.clear_target_request!(request, actor: context.operator)

    assert {:ok, ^protected} =
             Cases.read_operation_result_reference(operation.id, incident.id, clearance,
               actor: context.operator
             )

    for {case_id, offered, actor} <- [
          {Ecto.UUID.generate(), clearance, context.operator},
          {incident.id, clearance, context.admin},
          {incident.id, %{clearance | target_id: Ecto.UUID.generate()}, context.operator},
          {incident.id, %{clearance | access_method_id: Ecto.UUID.generate()}, context.operator},
          {incident.id, %{clearance | provider_id: Ecto.UUID.generate()}, context.operator}
        ] do
      assert {:error, _} =
               Cases.read_operation_result_reference(operation.id, case_id, offered, actor: actor)
    end

    public = Cases.get_operation!(operation.id, actor: context.operator)
    loaded = Ash.load!(public, :protected_reference, actor: context.operator)
    assert %Ash.ForbiddenField{} = loaded.protected_reference

    Accounts.change_role!(context.operator, :viewer, actor: context.admin)

    assert {:error, _} =
             Cases.read_operation_result_reference(operation.id, incident.id, clearance,
               actor: context.operator
             )
  end

  test "auto diagnostic effects are independently reviewed and return to investigation without repair verification",
       context do
    configure_mode!(context.admin, :auto)
    diagnostic_output = String.duplicate("x", 50_000) <> "\nnginx is running"

    {incident, run, proposal} =
      authorized_proposal!("diagnostic-effect", context, purpose: :investigation)

    assert proposal.status == :reviewing
    assert proposal.request_kind == :effect
    assert proposal.purpose == :investigation
    assert proposal.verification_intent == %{}

    assert :ok =
             Skopos.Cases.Proposal.ReviewDelivery.run(proposal.id,
               ai_invocation: %{
                 test_pid: self(),
                 respond: fn request ->
                   assert request.proposal.purpose == :investigation
                   assert request.proposal.parameters == %{"command" => "service nginx status"}
                   assert request.proposal.verification_intent == nil

                   {:ok,
                    %AI.ReviewDecision{
                      verdict: :approved,
                      purpose_assessment: :investigation,
                      reason: "The exact request collects service status",
                      usage: %AI.Usage{input_tokens: 4, output_tokens: 2}
                    }}
                 end
               }
             )

    decision = Cases.review_decision_by_proposal!(proposal.id, authorize?: false)
    assert decision.purpose_assessment == :investigation
    operation = Cases.accept_operation!(proposal.id, authorize?: false)
    assert operation.request_kind == :effect
    assert operation.purpose == :investigation

    assert :ok =
             OperationDelivery.run(operation.id,
               target_invocation:
                 invocation(
                   {:ok,
                    %Target.EffectResult{
                      status: :applied,
                      details: %{"stdout" => diagnostic_output}
                    }}
                 )
             )

    refute Cases.verification_attempt_by_operation!(operation.id,
             authorize?: false,
             not_found_error?: false
           )

    current = Cases.get_case!(incident.id, actor: context.operator)
    assert current.status == :running
    assert current.pending_intent["action"] == "resolve_turn"
    evidence = Cases.get_evidence!(current.pending_intent["evidence_id"], actor: context.operator)
    assert evidence.kind == "observation"
    assert evidence.content["request_kind"] == "effect"
    assert evidence.content["purpose"] == "investigation"
    assert evidence.content["facts"]["stdout"] == diagnostic_output
    assert Cases.get_resolution_run!(run.id, authorize?: false).effect_count == 1

    assert :ok =
             OperationDelivery.run(operation.id,
               target_invocation: invocation(fn -> flunk("diagnostic effect replayed") end)
             )

    turn = Cases.get_turn!(current.pending_intent["turn_id"], authorize?: false)

    assert :ok =
             ResolverDelivery.run(turn.id,
               target_invocation:
                 invocation({:ok, %Target.Capabilities{observations: [], effects: []}}),
               ai_invocation: %{
                 test_pid: self(),
                 respond: fn request ->
                   assert evidence.id in request.recovery_evidence_ids
                   observed = Enum.find(request.evidence, &(&1.id == evidence.id))
                   assert observed.content["facts"]["stdout"] == diagnostic_output

                   {:ok,
                    %AI.ResolverDecision{
                      intent: %AI.RecoveryConclusion{
                        reason:
                          "The reviewed investigation returned the requested service status",
                        evidence_ids: [evidence.id],
                        desired_outcome_claims: [
                          %{
                            "symptom_id" => request.case_symptom.id,
                            "evidence_id" => evidence.id,
                            "fact_keys" => ["stdout"],
                            "reason" => "The actual output says nginx is running"
                          }
                        ]
                      },
                      usage: %AI.Usage{input_tokens: 3, output_tokens: 2}
                    }}
                 end
               }
             )

    assert Cases.route_downstream_decision!(turn.id, authorize?: false).pending_intent["action"] ==
             "review_recovery"

    approve_recovery!(Cases.get_turn!(turn.id, authorize?: false), context)
    resolved = Cases.get_case!(incident.id, actor: context.operator)
    report = Reports.generate_report!(resolved.id, resolved.revision, actor: context.operator)
    assert get_in(report.content, ["operations", Access.at(0), "purpose"]) == "investigation"
    assert get_in(report.content, ["proposals", Access.at(0), "purpose"]) == "investigation"

    assert get_in(report.content, ["reviews", Access.at(0), "purpose_assessment"]) ==
             "investigation"

    document = Skopos.Reports.Report.Document.build(report)
    assert document["actions"] == []
    assert Enum.any?(document["cited_evidence"], &(&1["id"] == evidence.id))
  end

  test "proposal Reviewer retains prior-run facts without treating them as current manual recovery proof",
       context do
    configure_mode!(context.admin, :auto)

    {incident, run, proposal} =
      authorized_proposal!("review-evidence-availability", context, purpose: :investigation)

    source_result = Cases.get_turn!(proposal.source_turn_id, authorize?: false).result

    review = fn id, verdict, check ->
      assert :ok =
               Skopos.Cases.Proposal.ReviewDelivery.run(id,
                 ai_invocation: %{
                   test_pid: self(),
                   respond: fn request ->
                     check.(request)

                     {:ok,
                      %AI.ReviewDecision{
                        verdict: verdict,
                        purpose_assessment: :investigation,
                        reason: "Judge the exact investigation using available evidence",
                        usage: %AI.Usage{input_tokens: 4, output_tokens: 2}
                      }}
                   end
                 }
               )
    end

    review.(proposal.id, :approved, fn request ->
      assert request.recovery_evidence_ids == []
    end)

    operation = Cases.accept_operation!(proposal.id, authorize?: false)

    assert :ok =
             OperationDelivery.run(operation.id,
               target_invocation:
                 invocation(
                   {:ok,
                    %Target.EffectResult{
                      status: :applied,
                      details: %{"stdout" => "nginx is running"}
                    }}
                 )
             )

    current = Cases.get_case!(incident.id, authorize?: false)
    evidence = Cases.get_evidence!(current.pending_intent["evidence_id"], authorize?: false)

    propose = fn turn ->
      result = put_in(source_result, ["intent", "evidence_ids"], [])

      Cases.complete_turn!(
        turn.id,
        turn.revision,
        result,
        :proposal,
        %{"action" => "route_resolver_decision", "turn_id" => turn.id},
        "Review fresh investigation",
        authorize?: false
      )

      fresh = Cases.materialize_proposal!(turn.id, authorize?: false)
      Cases.route_downstream_decision!(turn.id, authorize?: false)
      Cases.get_proposal!(fresh.id, authorize?: false)
    end

    next_turn = Cases.get_turn!(current.pending_intent["turn_id"], authorize?: false)
    fresh = propose.(next_turn)

    review.(fresh.id, :rejected, fn request ->
      assert request.resolution_run_id == run.id
      assert request.recovery_evidence_ids == [evidence.id]
      assert Enum.any?(request.context_evidence, &(&1.id == evidence.id))
    end)

    current = Cases.get_case!(incident.id, authorize?: false)
    active = Cases.get_resolution_run!(run.id, authorize?: false)

    waiting =
      Cases.require_case_attention!(
        current.id,
        current.revision,
        active.id,
        active.revision,
        "review-evidence-pause",
        "Restart the investigation",
        %{"action" => "retry_resolver"},
        "Resume",
        authorize?: false
      )

    paused = Cases.get_resolution_run!(run.id, authorize?: false)

    resumed =
      Cases.resume_case!(
        waiting.id,
        waiting.revision,
        paused.id,
        paused.revision,
        paused.authority_mode,
        paused.max_elapsed_seconds,
        paused.max_resolver_turns,
        paused.max_target_requests,
        paused.max_effects,
        paused.max_related_targets,
        paused.max_ai_usage_units,
        paused.max_no_progress_turns,
        "Obtain fresh facts",
        actor: context.operator
      )

    [resumed_turn] = Cases.started_turns_for_run!(resumed.id, authorize?: false)
    fresh = propose.(resumed_turn)

    review.(fresh.id, :approved, fn request ->
      assert request.resolution_run_id == resumed.id
      assert request.recovery_evidence_ids == []

      assert Enum.any?(request.context_evidence, fn item ->
               item.id == evidence.id and item.content["facts"]["stdout"] == "nginx is running"
             end)
    end)

    assert Cases.get_proposal!(fresh.id, authorize?: false).status == :authorized
    assert length(Cases.operations_for_case!(incident.id, authorize?: false)) == 1
  end

  test "reviewed raw remediation returns its actual outcome for separately reviewed investigation",
       context do
    configure_mode!(context.admin, :auto)

    for outcome <- [:applied, :unknown] do
      {:ok, capabilities} = Skopos.Targets.Adapters.SSH.capabilities(nil, %{})
      raw = Enum.find(capabilities.effects, &(&1.operation == "command.execute"))
      raw = %{raw | capability: "effect.command"}

      target =
        Targets.create_target!("raw-remediation-#{outcome}", "host", "linux", %{}, nil,
          actor: context.admin
        )

      method =
        Targets.create_access_method!(
          target.id,
          context.provider.id,
          "raw-ssh",
          "ssh",
          "ssh://raw-remediation-#{outcome}",
          context.provider.revision,
          10,
          ["effect.command"],
          actor: context.admin
        )
        |> then(
          &Targets.check_access_method!(
            &1.id,
            &1.revision,
            invocation({:ok, %Target.Capabilities{observations: [], effects: [raw]}}),
            actor: context.admin
          )
        )

      context = %{context | target: target, method: method}

      {incident, run, proposal} =
        authorized_proposal!("raw-remediation-#{outcome}", context, defer_verification: true)

      assert proposal.verification_intent == %{}

      assert :ok =
               Skopos.Cases.Proposal.ReviewDelivery.run(proposal.id,
                 ai_invocation: %{
                   test_pid: self(),
                   respond: fn request ->
                     assert request.proposal.purpose == :remediation
                     assert request.proposal.verification_intent == nil
                     assert request.proposal.expected_result == %{"service" => "running"}

                     {:ok,
                      %AI.ReviewDecision{
                        verdict: :approved,
                        purpose_assessment: :remediation,
                        reason: "Current evidence justifies the exact service change",
                        usage: %AI.Usage{input_tokens: 4, output_tokens: 2}
                      }}
                   end
                 }
               )

      operation = Cases.accept_operation!(proposal.id, authorize?: false)

      response =
        if outcome == :applied,
          do:
            {:ok,
             %Target.EffectResult{
               status: :applied,
               details: %{"stdout" => "start request completed"}
             }},
          else: {:error, :failed, "Remote response was lost"}

      assert :ok = OperationDelivery.run(operation.id, target_invocation: invocation(response))

      current = Cases.get_case!(incident.id, actor: context.operator)
      assert current.status == :running
      assert current.pending_intent["action"] == "resolve_turn"

      evidence =
        Cases.get_evidence!(current.pending_intent["evidence_id"], actor: context.operator)

      assert evidence.kind == "operation_outcome"
      assert evidence.content["purpose"] == "remediation"
      assert evidence.content["status"] == to_string(outcome)

      if outcome == :applied,
        do: assert(evidence.content["details"]["stdout"] == "start request completed"),
        else:
          assert(evidence.content["details"]["message"] == "Target dispatch result is unknown")

      refute Cases.verification_attempt_by_operation!(operation.id,
               authorize?: false,
               not_found_error?: false
             )

      assert Cases.get_resolution_run!(run.id, authorize?: false).effect_count == 1

      assert :ok =
               OperationDelivery.run(operation.id,
                 target_invocation: invocation(fn -> flunk("raw remediation was replayed") end)
               )

      next = Cases.get_turn!(current.pending_intent["turn_id"], authorize?: false)

      assert :ok =
               ResolverDelivery.run(next.id,
                 target_invocation:
                   invocation({:ok, %Target.Capabilities{observations: [], effects: [raw]}}),
                 ai_invocation: %{
                   test_pid: self(),
                   respond: fn request ->
                     assert request.recovery_evidence_ids == []
                     assert request.observation_tools == []
                     [tool] = request.proposal_tools

                     {:ok,
                      %AI.ResolverDecision{
                        intent: %AI.Proposal{
                          tool_id: tool.id,
                          target_id: tool.target_id,
                          target_revision: tool.target_revision,
                          access_method_id: tool.access_method_id,
                          access_method_revision: tool.access_method_revision,
                          request_kind: :effect,
                          purpose: :investigation,
                          capability: tool.capability,
                          operation: tool.operation,
                          selectors: %{},
                          parameters: %{"command" => "systemctl is-active api.service"},
                          reason: "Inspect actual service state after the change",
                          evidence_ids: [evidence.id],
                          expected_result: %{},
                          verification_intent: nil
                        },
                        usage: %AI.Usage{input_tokens: 3, output_tokens: 2}
                      }}
                   end
                 }
               )

      completed = Cases.get_turn!(next.id, authorize?: false)
      assert completed.result["outcome"] == "decision", inspect(completed.result)
      Cases.route_downstream_decision!(next.id, authorize?: false)
      diagnostic = Cases.proposal_by_source_turn!(next.id, authorize?: false)
      assert diagnostic.purpose == :investigation

      assert :ok =
               Skopos.Cases.Proposal.ReviewDelivery.run(diagnostic.id,
                 ai_invocation: %{
                   test_pid: self(),
                   respond: fn request ->
                     assert request.proposal.parameters == %{
                              "command" => "systemctl is-active api.service"
                            }

                     {:ok,
                      %AI.ReviewDecision{
                        verdict: :approved,
                        purpose_assessment: :investigation,
                        reason: "This exact request only inspects the changed service",
                        usage: %AI.Usage{input_tokens: 4, output_tokens: 2}
                      }}
                   end
                 }
               )

      diagnostic_operation = Cases.accept_operation!(diagnostic.id, authorize?: false)

      assert :ok =
               OperationDelivery.run(diagnostic_operation.id,
                 target_invocation:
                   invocation(
                     {:ok,
                      %Target.EffectResult{status: :applied, details: %{"stdout" => "active"}}}
                   )
               )

      current = Cases.get_case!(incident.id, actor: context.operator)
      fresh = Cases.get_evidence!(current.pending_intent["evidence_id"], actor: context.operator)
      assert fresh.kind == "observation"
      assert fresh.content["facts"]["stdout"] == "active"
      conclusion = Cases.get_turn!(current.pending_intent["turn_id"], authorize?: false)

      assert :ok =
               ResolverDelivery.run(conclusion.id,
                 target_invocation:
                   invocation({:ok, %Target.Capabilities{observations: [], effects: [raw]}}),
                 ai_invocation: %{
                   test_pid: self(),
                   respond: fn request ->
                     assert request.recovery_evidence_ids == [fresh.id]

                     {:ok,
                      %AI.ResolverDecision{
                        intent: %AI.RecoveryConclusion{
                          reason: "The actual post-change service response confirms availability",
                          evidence_ids: [fresh.id],
                          desired_outcome_claims: [
                            %{
                              "symptom_id" => request.case_symptom.id,
                              "evidence_id" => fresh.id,
                              "fact_keys" => ["stdout"],
                              "reason" => "The service reports active after the change"
                            }
                          ]
                        },
                        usage: %AI.Usage{input_tokens: 3, output_tokens: 2}
                      }}
                   end
                 }
               )

      Cases.route_downstream_decision!(conclusion.id, authorize?: false)
      approve_recovery!(Cases.get_turn!(conclusion.id, authorize?: false), context)
      assert Cases.get_operation!(operation.id, actor: context.operator).status == outcome
      assert Cases.get_resolution_run!(run.id, authorize?: false).effect_count == 2
      resolved = Cases.get_case!(incident.id, actor: context.operator)
      report = Reports.generate_report!(resolved.id, resolved.revision, actor: context.operator)

      assert Enum.map(Skopos.Reports.Report.Document.build(report)["actions"], & &1["id"]) == [
               operation.id
             ]
    end
  end

  test "the exact latest reviewed investigation result can justify the next remediation",
       context do
    configure_mode!(context.admin, :auto)
    {:ok, catalog} = Skopos.Targets.Adapters.SSH.capabilities(nil, %{})
    raw = Enum.find(catalog.effects, &(&1.operation == "command.execute"))
    raw = %{raw | capability: "effect.service"}

    checked =
      Targets.check_access_method!(
        context.method.id,
        context.method.revision,
        invocation({:ok, %Target.Capabilities{observations: [], effects: [raw]}}),
        actor: context.admin
      )

    context = %{context | method: checked}

    {incident, _run, diagnostic} =
      authorized_proposal!("investigation-before-remedy", context, purpose: :investigation)

    assert :ok =
             Skopos.Cases.Proposal.ReviewDelivery.run(diagnostic.id,
               ai_invocation: %{
                 test_pid: self(),
                 respond: fn request ->
                   assert request.proposal.purpose == :investigation

                   {:ok,
                    %AI.ReviewDecision{
                      verdict: :approved,
                      purpose_assessment: :investigation,
                      reason: "The exact command only obtains service state",
                      usage: %AI.Usage{input_tokens: 3, output_tokens: 2}
                    }}
                 end
               }
             )

    observed = Cases.accept_operation!(diagnostic.id, authorize?: false)

    assert :ok =
             OperationDelivery.run(observed.id,
               target_invocation:
                 invocation(
                   {:ok,
                    %Target.EffectResult{
                      status: :applied,
                      details: %{"stdout" => "api.service inactive"}
                    }}
                 )
             )

    current = Cases.get_case!(incident.id, actor: context.operator)
    evidence = Cases.get_evidence!(current.pending_intent["evidence_id"], actor: context.operator)
    completed = Cases.get_operation!(observed.id, actor: context.operator)
    assert evidence.observed_at == completed.completed_at
    turn_id = current.pending_intent["turn_id"]

    assert :ok =
             ResolverDelivery.run(turn_id,
               target_invocation: %{},
               ai_invocation: %{
                 test_pid: self(),
                 respond: fn request ->
                   tool = Enum.find(request.proposal_tools, &(&1.capability == "effect.service"))
                   assert Enum.any?(request.evidence, &(&1.id == evidence.id))

                   {:ok,
                    %AI.ResolverDecision{
                      intent: %AI.Proposal{
                        tool_id: tool.id,
                        target_id: tool.target_id,
                        target_revision: tool.target_revision,
                        access_method_id: tool.access_method_id,
                        access_method_revision: tool.access_method_revision,
                        request_kind: :effect,
                        purpose: :remediation,
                        capability: tool.capability,
                        operation: tool.operation,
                        selectors: %{},
                        parameters: %{"command" => "systemctl start api.service"},
                        reason: "Start the observed inactive service",
                        evidence_ids: [evidence.id],
                        expected_result: %{"service" => "running"},
                        verification_intent: nil
                      },
                      usage: %AI.Usage{input_tokens: 3, output_tokens: 2}
                    }}
                 end
               }
             )

    result = Cases.get_turn!(turn_id, authorize?: false).result
    assert result["outcome"] == "decision", inspect(result)
    Cases.route_downstream_decision!(turn_id, authorize?: false)
    remedy = Cases.proposal_by_source_turn!(turn_id, authorize?: false)

    assert :ok =
             Skopos.Cases.Proposal.ReviewDelivery.run(remedy.id,
               ai_invocation: %{
                 test_pid: self(),
                 respond: fn request ->
                   assert request.proposal.evidence_ids == [evidence.id]

                   {:ok,
                    %AI.ReviewDecision{
                      verdict: :approved,
                      purpose_assessment: :remediation,
                      reason: "The actual current result justifies this service change",
                      usage: %AI.Usage{input_tokens: 3, output_tokens: 2}
                    }}
                 end
               }
             )

    operation = Cases.accept_operation!(remedy.id, authorize?: false)

    assert :ok =
             OperationDelivery.run(operation.id,
               target_invocation: invocation({:ok, %Target.EffectResult{status: :applied}})
             )

    assert Cases.get_operation!(operation.id, actor: context.operator).status == :applied
  end

  test "opaque investigation preserves readonly refusal and ask operator approval", context do
    for {mode, status} <- [{:readonly, :recommended}, {:ask, :awaiting_human}] do
      configure_mode!(context.admin, mode)

      {incident, _run, proposal} =
        authorized_proposal!("diagnostic-#{mode}", context, purpose: :investigation)

      assert proposal.purpose == :investigation
      assert proposal.request_kind == :effect
      assert proposal.status == status
      assert Cases.operations_for_case!(incident.id, actor: context.operator) == []

      refute Cases.review_decision_by_proposal!(proposal.id,
               authorize?: false,
               not_found_error?: false
             )

      assert {:error, _} = Cases.accept_operation(proposal.id, authorize?: false)
    end
  end

  test "interrupted diagnostic dispatch returns uncertainty to Resolver without replay or repair verification",
       context do
    {incident, _run, proposal} =
      authorized_proposal!("diagnostic-interrupted", context, purpose: :investigation)

    operation = Cases.accept_operation!(proposal.id, authorize?: false)
    assert %{state: :claimed} = Cases.claim_operation_dispatch!(operation.id, authorize?: false)

    assert :ok =
             OperationDelivery.run(operation.id,
               target_invocation: invocation(fn -> flunk("interrupted diagnostic replayed") end)
             )

    stored = Cases.get_operation!(operation.id, actor: context.operator)
    assert stored.status == :unknown
    assert stored.outcome_category == "dispatch_interrupted"

    assert Cases.get_case!(incident.id, actor: context.operator).pending_intent["action"] ==
             "resolve_turn"

    refute Cases.verification_attempt_by_operation!(operation.id,
             authorize?: false,
             not_found_error?: false
           )
  end

  test "accepting an authorized Proposal is atomic and idempotent", context do
    {_incident, run, proposal} = authorized_proposal!("accept", context)

    operation = Cases.accept_operation!(proposal.id, authorize?: false)
    duplicate = Cases.accept_operation!(proposal.id, authorize?: false)

    assert duplicate.id == operation.id
    assert operation.id == proposal.reserved_operation_id
    assert operation.status == :queued
    assert operation.proposal_revision == proposal.revision
    assert Cases.get_resolution_run!(run.id, authorize?: false).effect_count == 1
    assert operation_jobs(operation.id) == 1

    assert %{"operation_id" => operation.id} == operation_job(operation.id).args
    refute_receive {:effect, _, _}
  end

  test "competing Cases defer a Target effect and an interrupted send blocks blind retry",
       context do
    {_first_case, _first_run, first_proposal} = authorized_proposal!("conflict-first", context)
    {second_case, _second_run, second_proposal} = authorized_proposal!("conflict-second", context)
    first = Cases.accept_operation!(first_proposal.id, authorize?: false)
    second = Cases.accept_operation!(second_proposal.id, authorize?: false)

    assert Cases.claim_operation_dispatch!(first.id, authorize?: false).state == :claimed
    assert Cases.claim_operation_dispatch!(second.id, authorize?: false).state == :deferred

    assert {:snooze, 5} =
             OperationDelivery.run(second.id,
               target_invocation: invocation(fn -> flunk("competing effect was sent") end)
             )

    assert Cases.get_operation!(second.id, authorize?: false).status == :queued
    refute_receive {:effect, _, _}

    assert :ok =
             OperationDelivery.run(first.id,
               target_invocation: invocation(fn -> flunk("interrupted effect was resent") end)
             )

    assert Cases.get_operation!(first.id, authorize?: false).status == :unknown

    assert :ok =
             OperationDelivery.run(second.id,
               target_invocation:
                 invocation(fn -> flunk("effect after unknown outcome was sent") end)
             )

    blocked = Cases.get_operation!(second.id, authorize?: false)
    assert blocked.status == :failed
    assert blocked.outcome_category == "prior_effect_unknown"
    assert blocked.dispatch_started_at == nil
    assert Cases.get_case!(second_case.id, authorize?: false).status == :needs_attention
    refute_receive {:effect, _, _}
  end

  test "canonical service selectors separate unrelated resources on one Target", context do
    {_api_case, _api_run, api_proposal} = authorized_proposal!("scope-api", context)

    {_db_case, _db_run, db_proposal} =
      authorized_proposal!("scope-db", context, service: "db")

    api = Cases.accept_operation!(api_proposal.id, authorize?: false)
    db = Cases.accept_operation!(db_proposal.id, authorize?: false)

    assert api.resource_scope == "service:api.service"
    assert db.resource_scope == "service:db.service"
    method = Targets.get_access_method!(api.access_method_id, authorize?: false)

    assert ResourceScope.key(method, "effect.service", "service.restart", %{
             "unit" => "api.service"
           }) ==
             api.resource_scope

    assert ResourceScope.key(method, "effect.power", "bmc.power.cycle", %{"outlet" => "1"}) ==
             "target"

    assert Cases.claim_operation_dispatch!(api.id, authorize?: false).state == :claimed
    assert Cases.claim_operation_dispatch!(db.id, authorize?: false).state == :claimed
  end

  test "a later Case must cite a fresh Target observation after a conflicting effect", context do
    {_first_case, _first_run, first_proposal} = authorized_proposal!("effect-first", context)
    {stale_case, stale_run, stale_proposal} = authorized_proposal!("effect-stale", context)

    {_observed_case, observed_run, observation_proposal} =
      authorized_proposal!("effect-reobserve", context, request_kind: :observation)

    first = Cases.accept_operation!(first_proposal.id, authorize?: false)
    stale = Cases.accept_operation!(stale_proposal.id, authorize?: false)
    observation = Cases.accept_operation!(observation_proposal.id, authorize?: false)

    assert :ok =
             OperationDelivery.run(first.id,
               target_invocation: invocation({:ok, %Target.EffectResult{status: :applied}})
             )

    assert_receive {:effect, _, _}

    assert :ok =
             OperationDelivery.run(stale.id,
               target_invocation: invocation(fn -> flunk("stale effect was sent") end)
             )

    stopped = Cases.get_operation!(stale.id, authorize?: false)
    assert stopped.status == :failed
    assert stopped.outcome_category == "target_effect_changed"
    assert stopped.dispatch_started_at == nil

    assert Cases.get_case!(stale_case.id, authorize?: false).pending_intent["action"] ==
             "resolve_turn"

    assert [_reassessment] = Cases.started_turns_for_run!(stale_run.id, authorize?: false)
    refute_receive {:effect, _, _}

    assert :ok =
             OperationDelivery.run(observation.id,
               target_invocation:
                 invocation({
                   :ok,
                   %Target.Observation{
                     facts: %{"service" => "api"},
                     observed_at: DateTime.utc_now()
                   }
                 })
             )

    assert_receive {:observe, _, _}
    evidence = operation_evidence_record(observation.id)
    [turn] = Cases.started_turns_for_run!(observed_run.id, authorize?: false)

    resolved_turn =
      Cases.complete_turn!(
        turn.id,
        turn.revision,
        %{
          "outcome" => "decision",
          "intent" => proposal_intent(evidence.id, context, :effect),
          "resolver" => %{
            "provider_id" => context.resolver_provider.id,
            "provider_revision" => context.resolver_provider.revision,
            "assignment_id" => context.resolver_assignment.id,
            "assignment_revision" => context.resolver_assignment.revision
          },
          "usage" => %{"input_tokens" => 1, "output_tokens" => 1}
        },
        :proposal,
        %{"action" => "route_resolver_decision", "turn_id" => turn.id},
        "Review the Resolver decision",
        authorize?: false
      ).value

    Cases.route_downstream_decision!(resolved_turn.id, authorize?: false)
    authorized = Cases.proposal_by_source_turn!(resolved_turn.id, authorize?: false)
    fresh = Cases.accept_operation!(authorized.id, authorize?: false)

    assert :ok =
             OperationDelivery.run(fresh.id,
               target_invocation: invocation({:ok, %Target.EffectResult{status: :applied}})
             )

    assert_receive {:effect, _, _}
    assert Cases.get_operation!(fresh.id, authorize?: false).status == :applied
  end

  test "Operation actions enforce only the declared state transitions", context do
    {_incident, _run, proposal} = authorized_proposal!("state-machine", context)
    queued = Cases.accept_operation!(proposal.id, authorize?: false)
    completed_at = DateTime.utc_now()

    assert {:error, error} =
             Cases.record_operation_outcome(
               queued,
               queued.revision,
               %{
                 status: :applied,
                 outcome_category: "target_applied",
                 result_details: %{},
                 completed_at: completed_at
               },
               authorize?: false
             )

    assert Exception.message(error) =~
             "from queued to applied in action record_outcome"

    assert Cases.get_operation!(queued.id, authorize?: false).status == :queued

    claim = Cases.claim_operation_dispatch!(queued.id, authorize?: false)
    dispatching = claim.operation
    assert dispatching.status == :dispatching

    assert {:error, error} =
             Cases.record_operation_no_send(
               dispatching,
               dispatching.revision,
               %{
                 outcome_category: "cancelled_before_dispatch",
                 result_details: %{},
                 completed_at: completed_at
               },
               authorize?: false
             )

    assert %Ash.Error.Invalid{} = error
    still_dispatching = Cases.get_operation!(dispatching.id, authorize?: false)
    assert still_dispatching.status == :dispatching
    assert still_dispatching.dispatch_started_at != nil

    applied =
      Cases.record_operation_outcome!(
        dispatching,
        dispatching.revision,
        %{
          status: :applied,
          outcome_category: "target_applied",
          result_details: %{},
          completed_at: completed_at
        },
        authorize?: false
      )

    assert {:error, error} =
             Cases.mark_operation_dispatching(
               applied,
               applied.revision,
               %{dispatch_started_at: DateTime.utc_now()},
               authorize?: false
             )

    assert Exception.message(error) =~
             "from applied to dispatching in action mark_dispatching"

    assert Cases.get_operation!(applied.id, authorize?: false).status == :applied
  end

  test "Case action rejects a conflicting observation handoff without charging a Turn", context do
    {incident, run, proposal} =
      authorized_proposal!("conflicting-observation-handoff", context, request_kind: :observation)

    operation = Cases.accept_operation!(proposal.id, authorize?: false)
    claim = Cases.claim_operation_dispatch!(operation.id, authorize?: false)
    assert claim.state == :claimed

    Cases.record_operation_outcome!(
      claim.operation,
      claim.operation.revision,
      %{
        status: :applied,
        outcome_category: "target_observed",
        result_details: %{"facts" => %{"active_state" => "active"}},
        completed_at: DateTime.utc_now()
      },
      authorize?: false
    )

    current = Cases.get_case!(incident.id, authorize?: false)

    Cases.record_case_pending_intent!(
      current,
      current.revision,
      %{"action" => "verify_operation", "operation_id" => operation.id},
      authorize?: false
    )

    turns_before = Cases.list_turns!(actor: context.admin) |> length()
    count_before = Cases.get_resolution_run!(run.id, authorize?: false).turn_count

    assert {:error, _error} = OperationDelivery.run(operation.id)
    assert length(Cases.list_turns!(actor: context.admin)) == turns_before
    assert Cases.get_resolution_run!(run.id, authorize?: false).turn_count == count_before
  end

  test "revoked approval authority creates no Operation, job or budget charge", context do
    {incident, run, proposal} = authorized_proposal!("revoked", context)
    Accounts.change_role!(context.operator, :viewer, actor: context.admin)

    assert {:error, _error} = Cases.accept_operation(proposal.id, authorize?: false)
    assert Cases.list_operations!(actor: context.admin) == []
    assert Cases.get_resolution_run!(run.id, authorize?: false).effect_count == 0
    assert operation_jobs(proposal.reserved_operation_id) == 0
    refute_receive {:effect, _, _}

    assert :ok =
             OperationAcceptanceWorker.perform(%Oban.Job{
               args: %{"proposal_id" => proposal.id}
             })

    attention = Cases.get_case!(incident.id, authorize?: false)
    assert attention.status == :needs_attention
    assert attention.pending_intent["action"] == "dispatch_operation"
    assert Cases.get_resolution_run!(run.id, authorize?: false).effect_count == 0
  end

  for {table, predicate, failure} <- [
        {"operations", "TRUE",
         "RAISE EXCEPTION 'test operation acceptance persistence unavailable';"},
        {"oban_jobs", "NEW.worker = 'Skopos.Cases.Operation.Worker'", "RETURN NULL;"}
      ] do
    @tag acceptance_table: table, acceptance_predicate: predicate, acceptance_failure: failure
    test "Operation acceptance #{table} failure retries without pausing or charging", context do
      {incident, run, proposal} = authorized_proposal!("acceptance-save-failure", context)
      before_case = Cases.get_case!(incident.id, actor: context.operator)
      before_run = Cases.get_resolution_run!(run.id, authorize?: false)
      before_invocations = Cases.list_ai_invocations!(actor: context.operator)

      Repo.query!("""
      CREATE FUNCTION pg_temp.reject_operation_acceptance() RETURNS trigger LANGUAGE plpgsql AS $$
      BEGIN
        IF #{context.acceptance_predicate} THEN
          #{context.acceptance_failure}
        END IF;
        RETURN NEW;
      END;
      $$;
      """)

      Repo.query!("""
      CREATE TRIGGER reject_operation_acceptance BEFORE INSERT ON #{context.acceptance_table}
      FOR EACH ROW EXECUTE FUNCTION pg_temp.reject_operation_acceptance()
      """)

      assert {:error, _error} =
               OperationAcceptanceWorker.perform(%Oban.Job{
                 args: %{"proposal_id" => proposal.id},
                 attempt: 1
               })

      assert Cases.get_case!(incident.id, actor: context.operator) == before_case
      assert Cases.get_resolution_run!(run.id, authorize?: false) == before_run
      assert Cases.list_operations!(actor: context.operator) == []
      assert operation_jobs(proposal.reserved_operation_id) == 0
      assert Cases.list_ai_invocations!(actor: context.operator) == before_invocations

      Repo.query!("DROP TRIGGER reject_operation_acceptance ON #{context.acceptance_table}")

      for attempt <- [2, 3] do
        assert :ok =
                 OperationAcceptanceWorker.perform(%Oban.Job{
                   args: %{"proposal_id" => proposal.id},
                   attempt: attempt
                 })
      end

      assert [operation] = Cases.list_operations!(actor: context.operator)
      assert operation.id == proposal.reserved_operation_id
      assert operation.status == :queued
      assert operation_jobs(operation.id) == 1
      assert Cases.get_resolution_run!(run.id, authorize?: false).effect_count == 1
      assert Cases.get_case!(incident.id, actor: context.operator).status == :running
      assert Cases.list_ai_invocations!(actor: context.operator) == before_invocations
      refute_receive {:effect, _, _}
    end
  end

  test "Target instructions changed after approval prevent acceptance", context do
    {_incident, run, proposal} = authorized_proposal!("policy-before-accept", context)

    Targets.update_target!(
      context.target,
      context.target.revision,
      %{operating_instructions: "Do not restart the API service"},
      actor: context.admin
    )

    assert {:error, _error} = Cases.accept_operation(proposal.id, authorize?: false)
    assert Cases.list_operations!(actor: context.admin) == []
    assert Cases.get_resolution_run!(run.id, authorize?: false).effect_count == 0
    assert operation_jobs(proposal.reserved_operation_id) == 0
    refute_receive {:effect, _, _}
  end

  test "effect exhaustion persists attention without an Operation or job", context do
    configure_mode!(context.admin, :full_access, 0)
    {incident, run, proposal} = authorized_proposal!("exhausted", context)

    assert {:error, _error} = Cases.accept_operation(proposal.id, authorize?: false)
    assert Cases.list_operations!(actor: context.admin) == []
    assert operation_jobs(proposal.reserved_operation_id) == 0

    stopped = Cases.get_case!(incident.id, authorize?: false)
    assert stopped.status == :needs_attention
    assert stopped.pending_intent["action"] == "review_effect_limit"
    assert Cases.get_resolution_run!(run.id, authorize?: false).effect_count == 0
    refute_receive {:effect, _, _}
  end

  test "each normalized Target outcome is sent and persisted once", context do
    for status <- [:applied, :failed, :partial, :unknown] do
      case_context = separate_target!(context, "outcome-#{status}")
      {incident, _run, proposal} = authorized_proposal!("outcome-#{status}", case_context)
      operation = Cases.accept_operation!(proposal.id, authorize?: false)

      result = %Target.EffectResult{
        status: status,
        reference: "remote-#{status}",
        details: %{"status" => to_string(status)}
      }

      assert :ok =
               OperationDelivery.run(operation.id,
                 target_invocation: invocation({:ok, result})
               )

      assert_receive {:effect, _state, request}
      assert request.operation_id == operation.id
      assert request.idempotency_key == operation.idempotency_key

      stored = Cases.get_operation!(operation.id, authorize?: false)
      assert stored.status == status
      assert stored.reference == "remote-#{status}"
      assert stored.result_details == %{"status" => to_string(status)}

      assert :ok =
               OperationDelivery.run(operation.id,
                 target_invocation: invocation(fn -> flunk("terminal Operation was resent") end)
               )

      refute_receive {:effect, _, _}

      assert Cases.get_case!(incident.id, authorize?: false).pending_intent["action"] ==
               "verify_operation"

      assert operation_evidence(operation.id) == 1

      evidence = operation_evidence_record(operation.id)
      assert evidence.content["request_kind"] == "effect"
      assert evidence.content["capability"] == "effect.service"
      assert evidence.content["operation"] == "service.restart"
      assert evidence.content["selectors"] == %{"service" => "api"}
      assert evidence.content["parameters"] == %{"service" => "api"}
    end
  end

  test "a lost adapter response becomes unknown and is never resent", context do
    {_incident, _run, proposal} = authorized_proposal!("lost-response", context)
    operation = Cases.accept_operation!(proposal.id, authorize?: false)

    assert :ok =
             OperationDelivery.run(operation.id,
               target_invocation: invocation(fn -> raise "remote response lost" end)
             )

    assert_receive {:effect, _, _}
    assert Cases.get_operation!(operation.id, authorize?: false).status == :unknown

    assert :ok =
             OperationDelivery.run(operation.id,
               target_invocation: invocation(fn -> flunk("unknown Operation was resent") end)
             )

    refute_receive {:effect, _, _}
  end

  test "failed observations persist the bounded Target error and exact request", context do
    {incident, _run, proposal} =
      authorized_proposal!("observation-failure", context, request_kind: :observation)

    operation = Cases.accept_operation!(proposal.id, authorize?: false)

    assert :ok =
             OperationDelivery.run(operation.id,
               target_invocation:
                 invocation({:error, :failed, "service observation failed without a stack trace"})
             )

    assert_receive {:observe, _, _}
    failed = Cases.get_operation!(operation.id, authorize?: false)
    assert failed.status == :failed

    assert failed.result_details == %{
             "message" => "service observation failed without a stack trace",
             "provider_category" => "failed"
           }

    evidence = operation_evidence_record(operation.id)
    assert evidence.case_id == incident.id
    assert evidence.content["request_kind"] == "observation"
    assert evidence.content["operation"] == "service.inspect"
    assert evidence.content["selectors"] == %{"service" => "api"}
    assert evidence.content["details"] == failed.result_details
    assert evidence.content["access_method_revision"] == context.method.revision

    run = Cases.active_resolution_run!(incident.id, authorize?: false)
    assert run.no_progress_turns == 0

    assert :ok =
             OperationDelivery.run(operation.id,
               target_invocation: invocation(fn -> flunk("failed observation was resent") end)
             )

    assert Cases.get_resolution_run!(run.id, authorize?: false).no_progress_turns == 0
  end

  test "observation continuation carries the relationship used to enter its Target", context do
    relationship_id = Ecto.UUID.generate()

    {incident, _run, proposal} =
      authorized_proposal!("observation-relationship", context,
        request_kind: :observation,
        turn_intent: %{
          "objective" => "Inspect the related Target",
          "source" => "target_relationship",
          "relationship_id" => relationship_id
        }
      )

    operation = Cases.accept_operation!(proposal.id, authorize?: false)
    assert :ok = deliver_observation(operation, %{"service" => "api", "state" => "active"})

    pending = Cases.get_case!(incident.id, authorize?: false).pending_intent
    continued = Cases.get_turn!(pending["turn_id"], authorize?: false)
    assert continued.intent["source"] == "target_result"
    assert continued.intent["prior_relationship_id"] == relationship_id
  end

  test "only a new observation result resets the no-progress budget", context do
    {incident, run, proposal} =
      authorized_proposal!("observation-progress", context, request_kind: :observation)

    first = Cases.accept_operation!(proposal.id, authorize?: false)
    assert :ok = deliver_observation(first, %{"service" => "api", "state" => "active"})
    assert Cases.get_resolution_run!(run.id, authorize?: false).no_progress_turns == 0

    duplicate = continue_observation!(incident, context, first.id)
    assert :ok = deliver_observation(duplicate, %{"service" => "api", "state" => "active"})
    assert Cases.get_resolution_run!(run.id, authorize?: false).no_progress_turns == 1

    changed = continue_observation!(incident, context, duplicate.id)
    assert :ok = deliver_observation(changed, %{"service" => "api", "state" => "inactive"})
    assert Cases.get_resolution_run!(run.id, authorize?: false).no_progress_turns == 0

    repeated = continue_observation!(incident, context, changed.id)
    assert :ok = deliver_observation(repeated, %{"service" => "api", "state" => "inactive"})
    assert Cases.get_resolution_run!(run.id, authorize?: false).no_progress_turns == 1

    changed_input = continue_observation!(incident, Map.put(context, :service, "db"), repeated.id)
    assert :ok = deliver_observation(changed_input, %{"service" => "api", "state" => "inactive"})
    assert Cases.get_resolution_run!(run.id, authorize?: false).no_progress_turns == 0

    assert :ok =
             OperationDelivery.run(changed_input.id,
               target_invocation: invocation(fn -> flunk("completed observation was resent") end)
             )

    assert Cases.get_resolution_run!(run.id, authorize?: false).no_progress_turns == 0
  end

  test "novel failed probes remain available but repeated input stops before another paid Turn",
       context do
    {incident, run, proposal} =
      authorized_proposal!("observation-no-progress", context, request_kind: :observation)

    first = Cases.accept_operation!(proposal.id, authorize?: false)

    assert :ok =
             OperationDelivery.run(first.id,
               target_invocation: invocation({:error, :failed, "Target read failed"})
             )

    failed = Cases.get_operation!(first.id, authorize?: false)
    assert failed.result_details["provider_category"] == "failed"
    assert failed.access_method_revision == context.method.revision

    assert Cases.get_resolution_run!(run.id, authorize?: false).no_progress_turns == 0

    different = continue_observation!(incident, Map.put(context, :service, "db"), first.id)

    assert :ok =
             OperationDelivery.run(different.id,
               target_invocation: invocation({:error, :failed, "Different Target read failed"})
             )

    assert Cases.get_resolution_run!(run.id, authorize?: false).no_progress_turns == 0

    second = continue_observation!(incident, context, different.id)

    assert :ok =
             OperationDelivery.run(second.id,
               target_invocation: invocation({:error, :failed, "Target read failed"})
             )

    assert Cases.get_resolution_run!(run.id, authorize?: false).no_progress_turns == 1

    third = continue_observation!(incident, context, second.id)

    assert :ok =
             OperationDelivery.run(third.id,
               target_invocation: invocation({:error, :failed, "Target read still failed"})
             )

    assert Cases.get_resolution_run!(run.id, authorize?: false).no_progress_turns == 2

    fourth = continue_observation!(incident, context, third.id)

    assert :ok =
             OperationDelivery.run(fourth.id,
               target_invocation: invocation({:error, :failed, "Target read still failed"})
             )

    assert Cases.get_resolution_run!(run.id, authorize?: false).no_progress_turns == 3
    stopped = Cases.get_case!(incident.id, authorize?: false)
    assert stopped.status == :needs_attention
    assert stopped.stop_reason == "No-progress turn limit exhausted"
  end

  test "repeated transport failures with one Access Method remove its tools from the next AI request",
       context do
    {incident, run, proposal} =
      authorized_proposal!("method-unreachable", context, request_kind: :observation)

    first = Cases.accept_operation!(proposal.id, authorize?: false)

    assert :ok =
             OperationDelivery.run(first.id,
               target_invocation: invocation({:error, :retryable, "endpoint unavailable"})
             )

    second = continue_observation!(incident, Map.put(context, :service, "db"), first.id)

    assert :ok =
             OperationDelivery.run(second.id,
               target_invocation: invocation({:error, :timeout, "endpoint timed out"})
             )

    Cases.append_evidence!(
      incident.id,
      run.id,
      nil,
      "unrelated-success-after-failure",
      "operation_outcome",
      "target",
      Ecto.UUID.generate(),
      %{"status" => "applied", "target_id" => Ecto.UUID.generate()},
      DateTime.utc_now(),
      authorize?: false
    )

    pending = Cases.get_case!(incident.id, authorize?: false).pending_intent
    next_turn = Cases.get_turn!(pending["turn_id"], authorize?: false)

    assert {:ok, request, _context} =
             ResolverProjection.build(next_turn.id, %AI.Selection{
               role: :resolver,
               provider_id: context.resolver_provider.id,
               provider_revision: context.resolver_provider.revision,
               source: :assignment
             })

    assert request.observation_tools == []
    assert request.proposal_tools == []
    assert Cases.get_resolution_run!(run.id, authorize?: false).status == :running

    assert Cases.get_operation!(first.id, authorize?: false).result_details["provider_category"] ==
             "retryable"
  end

  test "interleaved new reads do not hide repeated identical observations", context do
    {incident, run, proposal} =
      authorized_proposal!("observation-cumulative-repeat", context, request_kind: :observation)

    first = Cases.accept_operation!(proposal.id, authorize?: false)
    assert :ok = deliver_observation(first, %{"service" => "api", "state" => "active"})

    second = continue_observation!(incident, context, first.id)
    assert :ok = deliver_observation(second, %{"service" => "api", "state" => "active"})

    other = continue_observation!(incident, Map.put(context, :service, "db"), second.id)
    assert :ok = deliver_observation(other, %{"service" => "db", "state" => "active"})
    assert Cases.get_resolution_run!(run.id, authorize?: false).no_progress_turns == 0

    third = continue_observation!(incident, context, other.id)
    assert :ok = deliver_observation(third, %{"service" => "api", "state" => "active"})

    another = continue_observation!(incident, Map.put(context, :service, "cache"), third.id)
    assert :ok = deliver_observation(another, %{"service" => "cache", "state" => "active"})
    assert Cases.get_resolution_run!(run.id, authorize?: false).no_progress_turns == 0

    fourth = continue_observation!(incident, context, another.id)
    assert :ok = deliver_observation(fourth, %{"service" => "api", "state" => "active"})

    stopped = Cases.get_case!(incident.id, authorize?: false)
    assert stopped.status == :needs_attention
    assert stopped.stop_reason == "Repeated identical Target observation limit exhausted"

    assert :ok =
             OperationDelivery.run(fourth.id,
               target_invocation: invocation(fn -> flunk("repeated observation was resent") end)
             )

    assert Cases.get_case!(incident.id, authorize?: false).status == :needs_attention
  end

  test "the same Target state across Access Methods does not reset progress", context do
    alternate =
      Targets.create_access_method!(
        context.target.id,
        context.provider.id,
        "operation-alternate-ssh",
        "ssh",
        "ssh://operation-linux-alternate",
        context.provider.revision,
        9,
        ["observe.service"],
        actor: context.admin
      )
      |> then(&Targets.check_access_method!(&1.id, &1.revision, %{}, actor: context.admin))

    alternate_context = %{context | method: alternate}

    {incident, run, proposal} =
      authorized_proposal!("observation-cross-method", context, request_kind: :observation)

    first = Cases.accept_operation!(proposal.id, authorize?: false)

    assert :ok =
             deliver_observation(
               first,
               %{"system_id" => "method-a", "state" => "active"},
               %{"state" => "active"}
             )

    second = continue_observation!(incident, alternate_context, first.id)

    assert :ok =
             deliver_observation(
               second,
               %{"system_id" => "method-b", "state" => "active"},
               %{"state" => "active"}
             )

    assert Cases.get_resolution_run!(run.id, authorize?: false).no_progress_turns == 1

    assert Cases.get_operation!(second.id, authorize?: false).result_details["facts"][
             "system_id"
           ] == "method-b"

    third = continue_observation!(incident, context, second.id)

    assert :ok =
             deliver_observation(
               third,
               %{"system_id" => "method-a", "state" => "active"},
               %{"state" => "active"}
             )

    fourth = continue_observation!(incident, alternate_context, third.id)

    assert :ok =
             deliver_observation(
               fourth,
               %{"system_id" => "method-b", "state" => "active"},
               %{"state" => "active"}
             )

    assert Cases.get_case!(incident.id, authorize?: false).stop_reason ==
             "Repeated identical Target observation limit exhausted"

    progress_events =
      Enum.count(Cases.list_case_events!(actor: context.admin), fn event ->
        event.case_id == incident.id and
          event.event_type in ["observation_progress", "limit_exhausted"]
      end)

    assert Cases.account_observation_progress!(fourth.id, authorize?: false).status == :exhausted

    assert Enum.count(Cases.list_case_events!(actor: context.admin), fn event ->
             event.case_id == incident.id and
               event.event_type in ["observation_progress", "limit_exhausted"]
           end) == progress_events
  end

  test "authorization changed after acceptance fails before Target dispatch", context do
    {incident, _run, proposal} =
      authorized_proposal!("instructions-before-dispatch", context, delay_seconds: 2)

    operation = Cases.accept_operation!(proposal.id, authorize?: false)

    assert {:snooze, _} =
             OperationDelivery.run(operation.id,
               target_invocation:
                 invocation(fn -> flunk("scheduled Operation was sent early") end)
             )

    Targets.update_target!(
      context.target,
      context.target.revision,
      %{operating_instructions: "Do not restart the API service"},
      actor: context.admin
    )

    Process.sleep(
      max(DateTime.diff(operation.not_before, DateTime.utc_now(), :millisecond), 0) + 10
    )

    assert :ok =
             OperationDelivery.run(operation.id,
               target_invocation: invocation(fn -> flunk("invalidated Operation was sent") end)
             )

    invalidated = Cases.get_operation!(operation.id, authorize?: false)
    assert invalidated.status == :failed
    assert invalidated.outcome_category == "authorization_invalidated"
    current = Cases.get_case!(incident.id, authorize?: false)
    assert current.status == :running
    assert current.selected_target_revision == context.target.revision + 1
    assert current.pending_intent["action"] == "resolve_turn"
    refute_receive {:effect, _, _}
  end

  test "restart after the dispatch marker converges to unknown without a send", context do
    {_incident, _run, proposal} = authorized_proposal!("restart", context)
    operation = Cases.accept_operation!(proposal.id, authorize?: false)

    claim = Cases.claim_operation_dispatch!(operation.id, authorize?: false)
    assert claim.state == :claimed
    assert claim.operation.status == :dispatching

    assert :ok =
             OperationDelivery.run(operation.id,
               target_invocation: invocation(fn -> flunk("recovered dispatch was resent") end)
             )

    recovered = Cases.get_operation!(operation.id, authorize?: false)
    assert recovered.status == :unknown
    assert recovered.outcome_category == "dispatch_interrupted"
    refute_receive {:effect, _, _}
    assert operation_evidence(operation.id) == 1
  end

  test "cancellation during scheduled waiting records no-send failure", context do
    {incident, _run, proposal} = authorized_proposal!("cancel", context, delay_seconds: 60)
    operation = Cases.accept_operation!(proposal.id, authorize?: false)

    current = Cases.get_case!(incident.id, authorize?: false)
    Cases.request_case_cancellation!(current.id, current.revision, actor: context.operator)

    assert :ok =
             OperationDelivery.run(operation.id,
               target_invocation: invocation(fn -> flunk("cancelled Operation was sent") end)
             )

    cancelled = Cases.get_operation!(operation.id, authorize?: false)
    assert cancelled.status == :failed
    assert cancelled.outcome_category == "cancelled_before_dispatch"
    assert cancelled.dispatch_started_at == nil
    refute_receive {:effect, _, _}
  end

  test "a request scheduled beyond the run deadline creates no Operation, job or budget charge",
       context do
    {_incident, run, proposal} =
      authorized_proposal!("delay-beyond-deadline", context,
        request_kind: :observation,
        delay_seconds: 86_400
      )

    assert {:error, error} = Cases.accept_operation(proposal.id, authorize?: false)
    assert Exception.message(error) =~ "Authorized Proposal is stale"
    assert Cases.list_operations!(actor: context.admin) == []
    assert Cases.get_resolution_run!(run.id, authorize?: false).target_request_count == 0
    assert operation_jobs(proposal.reserved_operation_id) == 0
  end

  @tag timeout: 90_000
  test "a scheduled request claimed after its run deadline is never sent", context do
    setting = Cases.current_authority_setting!(actor: context.admin)

    Cases.configure_authority_setting!(
      setting.setting_revision,
      :full_access,
      setting.signal_automation_enabled,
      60,
      setting.max_resolver_turns,
      setting.max_target_requests,
      setting.max_effects,
      setting.max_related_targets,
      setting.max_ai_usage_units,
      setting.max_no_progress_turns,
      "Verify elapsed deadline before scheduled dispatch",
      actor: context.admin
    )

    {_incident, run, proposal} =
      authorized_proposal!("elapsed-delay", context,
        request_kind: :observation,
        delay_seconds: 30
      )

    operation = Cases.accept_operation!(proposal.id, authorize?: false)

    invocation =
      invocation(fn ->
        send(self(), :expired_request_sent)
        {:error, :unexpected_send}
      end)

    assert {:snooze, _} = OperationDelivery.run(operation.id, target_invocation: invocation)
    Process.sleep(max(DateTime.diff(run.deadline_at, DateTime.utc_now(), :millisecond), 0) + 10)

    assert :ok = OperationDelivery.run(operation.id, target_invocation: invocation)
    stopped = Cases.get_operation!(operation.id, actor: context.operator)
    assert stopped.status == :failed
    assert stopped.outcome_category == "run_deadline_elapsed"
    assert stopped.dispatch_started_at == nil
    refute_receive :expired_request_sent
  end

  test "native Signal change after acceptance stops the Target send and starts one reassessment",
       context do
    enable_signal_automation!(context.admin)

    {incident, run, proposal, signal_provider} =
      authorized_proposal!("condition-before-send", context, trigger_kind: :signal)

    operation = Cases.accept_operation!(proposal.id, authorize?: false)
    event_key = incident.initial_context["signal_event_key"]

    recover_signal!(
      signal_provider,
      context,
      event_key,
      "condition-before-send-recovered",
      DateTime.utc_now()
    )

    assert :ok =
             OperationDelivery.run(operation.id,
               target_invocation: invocation(fn -> flunk("stale Target request was sent") end)
             )

    stopped = Cases.get_operation!(operation.id, authorize?: false)
    assert stopped.status == :failed
    assert stopped.outcome_category == "source_context_changed"
    assert stopped.dispatch_started_at == nil
    assert Cases.list_verification_attempts!(actor: context.admin) == []
    assert Cases.get_resolution_run!(run.id, authorize?: false).effect_count == 1

    current = Cases.get_case!(incident.id, authorize?: false)
    assert current.pending_intent["action"] == "resolve_turn"
    assert current.pending_intent["source_operation_id"] == operation.id
    assert [_reassessment] = Cases.started_turns_for_run!(run.id, authorize?: false)

    assert %{kind: "operation_outcome"} =
             Cases.evidence_by_idempotency!(
               incident.id,
               "operation:outcome:#{operation.id}",
               authorize?: false
             )

    refute_receive {:effect, _, _}
  end

  test "a delivered effect retries verification scheduling without another Target effect",
       context do
    {incident, run, proposal} = authorized_proposal!("verification-job-persistence", context)
    operation = Cases.accept_operation!(proposal.id, authorize?: false)

    Repo.query!("""
    CREATE FUNCTION pg_temp.reject_verification_job() RETURNS trigger LANGUAGE plpgsql AS $$
    BEGIN
      IF NEW.worker = 'Skopos.Cases.VerificationAttempt.Worker' THEN RETURN NULL; END IF;
      RETURN NEW;
    END;
    $$;
    """)

    Repo.query!("""
    CREATE TRIGGER reject_verification_job BEFORE INSERT ON oban_jobs
    FOR EACH ROW EXECUTE FUNCTION pg_temp.reject_verification_job()
    """)

    assert {:error, _error} =
             OperationDelivery.run(operation.id,
               target_invocation: invocation({:ok, %Target.EffectResult{status: :applied}})
             )

    assert_receive {:effect, _, _}
    assert Cases.get_operation!(operation.id, authorize?: false).status == :applied

    assert Cases.get_case!(incident.id, authorize?: false).pending_intent["action"] ==
             "verify_operation"

    assert Cases.get_resolution_run!(run.id, authorize?: false).target_request_count == 0

    assert {:ok, nil} =
             Cases.verification_attempt_by_operation(operation.id,
               authorize?: false,
               not_found_error?: false
             )

    Repo.query!("DROP TRIGGER reject_verification_job ON oban_jobs")

    for _ <- 1..2 do
      assert :ok =
               OperationDelivery.run(operation.id,
                 target_invocation:
                   invocation(fn -> flunk("the completed effect was sent again") end)
               )
    end

    attempt = Cases.verification_attempt_by_operation!(operation.id, authorize?: false)
    assert attempt.status == :queued
    assert verification_jobs(attempt.id) == 1
    assert Cases.get_resolution_run!(run.id, authorize?: false).target_request_count == 1
    refute_receive {:effect, _, _}
    refute_receive {:verify, _, _}
  end

  @tag dispatch_actor_read_fault: true
  test "a temporary actor read failure retries queued operation before any Target send",
       context do
    {incident, run, proposal} = authorized_proposal!("dispatch-actor-read-failure", context)
    operation = Cases.accept_operation!(proposal.id, authorize?: false)
    before_case = Cases.get_case!(incident.id, authorize?: false)
    before_run = Cases.get_resolution_run!(run.id, authorize?: false)

    Repo.query!("ALTER TABLE users RENAME COLUMN role_version TO unavailable_role_version")

    try do
      assert {:error, _error} =
               OperationWorker.perform(%Oban.Job{args: %{"operation_id" => operation.id}})
    after
      Repo.query!("ALTER TABLE users RENAME COLUMN unavailable_role_version TO role_version")
    end

    unchanged = Cases.get_operation!(operation.id, authorize?: false)
    assert unchanged.status == :queued
    assert unchanged.dispatch_started_at == nil
    assert unchanged.outcome_category == nil
    assert Cases.get_case!(incident.id, authorize?: false) == before_case
    assert Cases.get_resolution_run!(run.id, authorize?: false) == before_run

    assert :ok =
             OperationDelivery.run(operation.id,
               target_invocation: invocation({:ok, %Target.EffectResult{status: :applied}})
             )

    assert_receive {:effect, _, _}

    assert :ok =
             OperationDelivery.run(operation.id,
               target_invocation: invocation(fn -> flunk("saved operation was sent again") end)
             )

    refute_receive {:effect, _, _}
    assert Cases.get_operation!(operation.id, authorize?: false).status == :applied
    attempt = Cases.verification_attempt_by_operation!(operation.id, authorize?: false)
    assert verification_jobs(attempt.id) == 1
  end

  test "terminal Operation automatically creates one exact VerificationAttempt and job",
       context do
    {_incident, run, proposal} = authorized_proposal!("verification-accept", context)
    operation = Cases.accept_operation!(proposal.id, authorize?: false)

    assert :ok =
             OperationDelivery.run(operation.id,
               target_invocation:
                 invocation({:ok, %Target.EffectResult{status: :applied, reference: "remote-1"}})
             )

    assert_receive {:effect, _, _}
    attempt = Cases.verification_attempt_by_operation!(operation.id, authorize?: false)
    duplicate = Cases.accept_verification!(operation.id, authorize?: false)

    assert duplicate.id == attempt.id
    assert attempt.status == :queued
    assert attempt.operation_reference == "remote-1"
    assert attempt.parameters == %{"service" => "api"}
    assert Cases.get_resolution_run!(run.id, authorize?: false).target_request_count == 1
    assert verification_jobs(attempt.id) == 1
    assert %{"verification_attempt_id" => attempt.id} == verification_job(attempt.id).args
    refute_receive {:verify, _, _}
  end

  test "fresh verification outcomes are called and persisted once with parameters", context do
    for status <- [:verified, :not_verified, :unknown] do
      case_context = separate_target!(context, "verification-#{status}")
      {incident, _run, proposal} = authorized_proposal!("verification-#{status}", case_context)
      operation = Cases.accept_operation!(proposal.id, authorize?: false)

      assert :ok =
               OperationDelivery.run(operation.id,
                 target_invocation: invocation({:ok, %Target.EffectResult{status: :applied}})
               )

      assert_receive {:effect, _, _}
      attempt = Cases.verification_attempt_by_operation!(operation.id, authorize?: false)

      result = %Target.Verification{
        status: status,
        observed_at: DateTime.utc_now(),
        facts: %{"service" => to_string(status)},
        evidence: [%{"check" => "service"}]
      }

      assert :ok =
               VerificationDelivery.run(attempt.id,
                 target_invocation: invocation({:ok, result})
               )

      assert_receive {:verify, _state, request}
      assert request.operation_id == operation.id
      assert request.parameters == %{"service" => "api"}

      stored = Cases.get_verification_attempt!(attempt.id, authorize?: false)
      assert stored.status == status
      assert stored.facts == %{"service" => to_string(status)}

      assert :ok =
               VerificationDelivery.run(attempt.id,
                 target_invocation: invocation(fn -> flunk("terminal verification repeated") end)
               )

      refute_receive {:verify, _, _}

      pending = Cases.get_case!(incident.id, authorize?: false).pending_intent
      assert pending["action"] == "resolve_turn"
      assert pending["verification_attempt_id"] == attempt.id

      assessment = Cases.get_turn!(pending["turn_id"], authorize?: false)
      assert assessment.status == :started
      assert assessment.intent["verification_attempt_id"] == attempt.id
      assert assessment.intent["verification_status"] == to_string(status)
      assert verification_evidence(attempt.id) == 1

      current = Cases.get_case!(incident.id, authorize?: false)

      assert {:error, _} =
               Cases.handoff_case_verification(
                 current,
                 current.revision,
                 attempt.id,
                 pending["verification_evidence_id"],
                 :evaluate,
                 nil,
                 authorize?: false
               )

      assert Cases.get_case!(incident.id, authorize?: false).revision == current.revision

      assert :ok =
               OperationDelivery.run(operation.id,
                 target_invocation: invocation(fn -> flunk("terminal effect repeated") end)
               )

      assert Cases.get_case!(incident.id, authorize?: false).pending_intent == pending

      assert Cases.verification_attempt_by_operation!(operation.id, authorize?: false).id ==
               attempt.id
    end
  end

  test "lost verification response and restart after marker never repeat the Target call",
       context do
    {_incident, _run, proposal} = authorized_proposal!("verification-lost", context)
    operation = Cases.accept_operation!(proposal.id, authorize?: false)

    assert :ok =
             OperationDelivery.run(operation.id,
               target_invocation: invocation({:ok, %Target.EffectResult{status: :unknown}})
             )

    assert_receive {:effect, _, _}
    attempt = Cases.verification_attempt_by_operation!(operation.id, authorize?: false)

    claim = Cases.claim_verification_dispatch!(attempt.id, authorize?: false)
    assert claim.state == :claimed

    assert :ok =
             VerificationDelivery.run(attempt.id,
               target_invocation: invocation(fn -> flunk("recovered verification repeated") end)
             )

    recovered = Cases.get_verification_attempt!(attempt.id, authorize?: false)
    assert recovered.status == :unknown
    assert recovered.outcome_category == "verification_interrupted"
    refute_receive {:verify, _, _}
    assert verification_evidence(attempt.id) == 1
  end

  test "a lost verification response is unknown and never repeated", context do
    {_incident, _run, proposal} = authorized_proposal!("verification-response-lost", context)
    operation = Cases.accept_operation!(proposal.id, authorize?: false)

    assert :ok =
             OperationDelivery.run(operation.id,
               target_invocation: invocation({:ok, %Target.EffectResult{status: :applied}})
             )

    assert_receive {:effect, _, _}
    attempt = Cases.verification_attempt_by_operation!(operation.id, authorize?: false)

    assert :ok =
             VerificationDelivery.run(attempt.id,
               target_invocation: invocation(fn -> raise "verification response lost" end)
             )

    assert_receive {:verify, _, _}
    assert Cases.get_verification_attempt!(attempt.id, authorize?: false).status == :unknown

    assert :ok =
             VerificationDelivery.run(attempt.id,
               target_invocation: invocation(fn -> flunk("unknown verification repeated") end)
             )

    refute_receive {:verify, _, _}
  end

  @tag verification_actor_read_fault: true
  test "temporary actor read failure retries fresh verification without repeating the effect",
       context do
    {incident, run, proposal} = authorized_proposal!("verification-actor-read-failure", context)
    operation = Cases.accept_operation!(proposal.id, authorize?: false)

    assert :ok =
             OperationDelivery.run(operation.id,
               target_invocation: invocation({:ok, %Target.EffectResult{status: :applied}})
             )

    assert_receive {:effect, _, _}
    attempt = Cases.verification_attempt_by_operation!(operation.id, authorize?: false)
    before_case = Cases.get_case!(incident.id, authorize?: false)
    before_run = Cases.get_resolution_run!(run.id, authorize?: false)
    before_operation = Cases.get_operation!(operation.id, authorize?: false)
    Repo.query!("ALTER TABLE users RENAME COLUMN role_version TO unavailable_role_version")

    try do
      assert {:error, _error} =
               VerificationWorker.perform(%Oban.Job{
                 args: %{"verification_attempt_id" => attempt.id}
               })
    after
      Repo.query!("ALTER TABLE users RENAME COLUMN unavailable_role_version TO role_version")
    end

    unchanged = Cases.get_verification_attempt!(attempt.id, authorize?: false)
    assert unchanged.status == :queued
    assert unchanged.dispatch_started_at == nil
    assert unchanged.outcome_category == nil
    assert Cases.get_case!(incident.id, authorize?: false) == before_case
    assert Cases.get_resolution_run!(run.id, authorize?: false) == before_run
    assert Cases.get_operation!(operation.id, authorize?: false) == before_operation

    assert :ok =
             VerificationDelivery.run(attempt.id,
               target_invocation:
                 invocation({:ok, verified_result(%{"active_state" => "active"})})
             )

    assert_receive {:verify, _, _}

    assert :ok =
             VerificationDelivery.run(attempt.id,
               target_invocation: invocation(fn -> flunk("fresh verification was repeated") end)
             )

    refute_receive {:verify, _, _}
    refute_receive {:effect, _, _}
    assert Cases.get_verification_attempt!(attempt.id, authorize?: false).status == :verified
  end

  test "Target instructions changed after VerificationAttempt acceptance prevent dispatch",
       context do
    {_incident, _run, proposal} = authorized_proposal!("verification-policy", context)
    operation = Cases.accept_operation!(proposal.id, authorize?: false)

    assert :ok =
             OperationDelivery.run(operation.id,
               target_invocation: invocation({:ok, %Target.EffectResult{status: :applied}})
             )

    assert_receive {:effect, _, _}
    attempt = Cases.verification_attempt_by_operation!(operation.id, authorize?: false)

    Targets.update_target!(
      context.target,
      context.target.revision,
      %{operating_instructions: "Do not inspect this service"},
      actor: context.admin
    )

    assert :ok =
             VerificationDelivery.run(attempt.id,
               target_invocation: invocation(fn -> flunk("invalidated verification was sent") end)
             )

    invalidated = Cases.get_verification_attempt!(attempt.id, authorize?: false)
    assert invalidated.status == :unknown
    assert invalidated.outcome_category == "authorization_invalidated"
    refute_receive {:verify, _, _}
  end

  test "cancellation before verification claim prevents Target dispatch", context do
    {incident, _run, proposal} = authorized_proposal!("verification-cancel", context)
    operation = Cases.accept_operation!(proposal.id, authorize?: false)

    assert :ok =
             OperationDelivery.run(operation.id,
               target_invocation: invocation({:ok, %Target.EffectResult{status: :applied}})
             )

    assert_receive {:effect, _, _}
    attempt = Cases.verification_attempt_by_operation!(operation.id, authorize?: false)
    current = Cases.get_case!(incident.id, authorize?: false)
    Cases.request_case_cancellation!(current.id, current.revision, actor: context.operator)

    assert :ok =
             VerificationDelivery.run(attempt.id,
               target_invocation: invocation(fn -> flunk("cancelled verification was sent") end)
             )

    cancelled = Cases.get_verification_attempt!(attempt.id, authorize?: false)
    assert cancelled.status == :unknown
    assert cancelled.outcome_category == "cancelled_before_verification"
    refute_receive {:verify, _, _}
  end

  test "verification budget exhaustion persists attention without attempt or Target call",
       context do
    {incident, run, proposal} = authorized_proposal!("verification-exhausted", context)

    Cases.charge_resolution_run!(
      incident.id,
      run.id,
      :target_request,
      run.max_target_requests,
      "consume-verification-budget",
      %{"action" => "test"},
      "test",
      authorize?: false
    )

    operation = Cases.accept_operation!(proposal.id, authorize?: false)

    assert :ok =
             OperationDelivery.run(operation.id,
               target_invocation: invocation({:ok, %Target.EffectResult{status: :applied}})
             )

    assert_receive {:effect, _, _}
    assert Cases.list_verification_attempts!(actor: context.admin) == []
    assert Cases.get_case!(incident.id, authorize?: false).status == :needs_attention
    refute_receive {:verify, _, _}
  end

  test "verified Target Evidence starts investigation without automatically resolving a Signal Case",
       context do
    enable_signal_automation!(context.admin)

    {incident, run, proposal, signal_provider} =
      authorized_proposal!("signal-multilingual-recovery", context,
        trigger_kind: :signal,
        additional_event_key: "operation-signal-multilingual-recovery:secondary"
      )

    first_event_key = incident.initial_context["signal_event_key"]
    second_event_key = first_event_key <> ":secondary"

    operation = Cases.accept_operation!(proposal.id, authorize?: false)

    assert :ok =
             OperationDelivery.run(operation.id,
               target_invocation: invocation({:ok, %Target.EffectResult{status: :applied}})
             )

    assert_receive {:effect, _, _}
    attempt = Cases.verification_attempt_by_operation!(operation.id, authorize?: false)
    turns_before = length(Cases.list_turns!(actor: context.admin))

    recover_signal!(signal_provider, context, first_event_key, "primary-recovered")
    still_firing = Cases.get_case!(incident.id, authorize?: false)
    assert still_firing.status == :running
    assert Enum.count(Signals.list_conditions!(actor: context.admin), &(&1.state == :firing)) == 1

    recovered_at = DateTime.utc_now()

    recover_signal!(
      signal_provider,
      context,
      second_event_key,
      "secondary-recovered",
      recovered_at
    )

    recover_signal!(
      signal_provider,
      context,
      second_event_key,
      "secondary-recovered",
      recovered_at
    )

    assert :ok =
             VerificationDelivery.run(attempt.id,
               target_invocation:
                 invocation(
                   {:ok, verified_result(%{"unit" => "api.service", "active_state" => "active"})}
                 )
             )

    assert_receive {:verify, _, _}

    current = Cases.get_case!(incident.id, authorize?: false)
    assert report_jobs(current.id) == []
    assert Reports.list_reports!(actor: context.admin) == []

    assert current.status == :running
    assert Enum.all?(Signals.list_conditions!(actor: context.admin), &(&1.state == :recovered))
    assert length(Cases.list_turns!(actor: context.admin)) == turns_before + 1
    assert Cases.get_resolution_run!(run.id, authorize?: false).status == :running
    assert Cases.get_resolution_run!(run.id, authorize?: false).active
    refute_receive {:effect, _, _}
  end

  test "a Signal Case cannot resolve until its monitoring source also recovers", context do
    enable_signal_automation!(context.admin)

    {incident, _run, proposal, signal_provider} =
      authorized_proposal!("signal-recovery", context, trigger_kind: :signal)

    event_key = incident.initial_context["signal_event_key"]

    operation = Cases.accept_operation!(proposal.id, authorize?: false)

    assert :ok =
             OperationDelivery.run(operation.id,
               target_invocation: invocation({:ok, %Target.EffectResult{status: :applied}})
             )

    assert_receive {:effect, _, _}
    attempt = Cases.verification_attempt_by_operation!(operation.id, authorize?: false)

    recover_signal!(signal_provider, context, event_key, "recovered-before-verification")
    before_verification = Cases.get_case!(incident.id, authorize?: false)
    assert before_verification.status == :running
    assert [%{state: :recovered}] = Signals.list_conditions!(actor: context.admin)

    assert :ok =
             VerificationDelivery.run(attempt.id,
               target_invocation:
                 invocation(
                   {:ok, verified_result(%{"unit" => "api.service", "active_state" => "active"})}
                 )
             )

    assert_receive {:verify, _, _}

    assert Enum.any?(
             Cases.list_evidence!(actor: context.admin),
             &(&1.case_id == incident.id and &1.kind == "signal_event" and
                 &1.content["state"] == "recovered")
           )

    current = Cases.get_case!(incident.id, authorize?: false)
    assert current.status == :running

    assert [_turn] =
             Cases.started_turns_for_run!(
               Cases.active_resolution_run!(current.id, authorize?: false).id,
               authorize?: false
             )

    refute_receive {:effect, _, _}
  end

  test "two recovered Conditions stay open for Resolver assessment after one Target verification",
       context do
    enable_signal_automation!(context.admin)

    {incident, run, proposal, signal_provider} =
      authorized_proposal!("two-service-conditions", context,
        trigger_kind: :signal,
        additional_event_key: "operation-two-service-conditions:db",
        additional_subject: "db.service"
      )

    operation = Cases.accept_operation!(proposal.id, authorize?: false)

    assert :ok =
             OperationDelivery.run(operation.id,
               target_invocation: invocation({:ok, %Target.EffectResult{status: :applied}})
             )

    recover_signal!(
      signal_provider,
      context,
      incident.initial_context["signal_event_key"],
      "api-recovered"
    )

    signal_event!(
      signal_provider,
      context,
      "operation-two-service-conditions:db",
      "db-recovered",
      :recovered,
      DateTime.utc_now(),
      %{"labels" => %{"service" => "db.service", "alertname" => "ServiceUnavailable"}}
    )

    attempt = Cases.verification_attempt_by_operation!(operation.id, authorize?: false)

    assert :ok =
             VerificationDelivery.run(attempt.id,
               target_invocation:
                 invocation(
                   {:ok, verified_result(%{"unit" => "api.service", "active_state" => "active"})}
                 )
             )

    assert Cases.get_case!(incident.id, authorize?: false).status == :running
    assert length(Cases.active_conditions_for_case!(incident.id, authorize?: false)) == 2
    assert length(Cases.list_cases!(actor: context.admin)) == 1
    assert report_jobs(incident.id) == []
    assert [_turn] = Cases.started_turns_for_run!(run.id, authorize?: false)
  end

  @tag recovery_metadata: true
  test "a later effect on one Condition does not stale another recovered Condition",
       context do
    enable_signal_automation!(context.admin)

    {incident, scoped_run, proposal, signal_provider} =
      authorized_proposal!("scoped-effect-recovery", context,
        trigger_kind: :signal,
        additional_event_key: "operation-scoped-effect-recovery:db",
        additional_subject: "db.service",
        affected_event_key: "operation-scoped-effect-recovery"
      )

    assert length(proposal.affected_conditions) == 1

    other_key = "operation-scoped-effect-recovery:db"
    operation = Cases.accept_operation!(proposal.id, authorize?: false)

    assert :ok =
             OperationDelivery.run(operation.id,
               target_invocation: invocation({:ok, %Target.EffectResult{status: :applied}})
             )

    assert_receive {:effect, _, _}

    append_investigation_history!(operation, 101)

    signal_event!(
      signal_provider,
      context,
      other_key,
      "delayed-db-recovery-before-effect",
      :recovered,
      DateTime.add(operation.accepted_at, -1, :microsecond),
      %{"labels" => %{"service" => "db.service", "alertname" => "ServiceUnavailable"}}
    )

    other_correlation =
      Enum.find(
        Signals.list_signal_correlations!(actor: context.admin),
        &(&1.event_key == other_key)
      )

    other =
      Enum.find(
        Signals.list_conditions!(actor: context.admin),
        &(&1.signal_correlation_id == other_correlation.id)
      )

    assert other.state == :recovered

    recover_signal!(
      signal_provider,
      context,
      incident.initial_context["signal_event_key"],
      "api-recovered-after-effect"
    )

    saved_effect = Cases.get_operation!(operation.id, authorize?: false)
    affected_id = hd(proposal.affected_conditions)["condition_id"]

    assert {:ok, refresh_at} =
             ConditionRecovery.applied_effect_refresh_at(incident, scoped_run.id, [affected_id])

    assert refresh_at == saved_effect.completed_at

    {:ok, assessments} = ConditionRecovery.assess_current(incident)
    by_id = Map.new(assessments, &{&1.condition_id, &1.status})
    assert by_id[other.id] == :needs_observation
    assert Enum.all?(assessments, &(&1.status != :stale_source))

    attempt = Cases.verification_attempt_by_operation!(operation.id, authorize?: false)

    assert :ok =
             VerificationDelivery.run(attempt.id,
               target_invocation:
                 invocation(
                   {:ok, verified_result(%{"unit" => "api.service", "active_state" => "active"})}
                 )
             )

    snapshot = Cases.case_reconnect_snapshot!(incident.id, actor: context.operator)
    assert_receive {:verify, _, _}

    receipt =
      Cases.page_case_evidence!(incident.id, actor: context.operator).results
      |> Enum.find(&(&1.source_ref == attempt.id and &1.source == "verification"))

    Repo.query!("ALTER TABLE verification_attempts RENAME COLUMN facts TO unavailable_facts")

    try do
      assert {:ok, metadata_snapshot} =
               Cases.case_reconnect_snapshot(incident.id, actor: context.operator)

      assert metadata_snapshot.conditions == snapshot.conditions

      assert {:error, %Ash.Error.Unknown{} = cause} =
               Cases.get_evidence(receipt.id, authorize?: false)

      assert Exception.message(cause) =~ "does not exist"
      refute_receive {:verify, _, _}
    after
      Repo.query!("ALTER TABLE verification_attempts RENAME COLUMN unavailable_facts TO facts")
    end

    current = Cases.get_case!(incident.id, authorize?: false)
    run = Cases.active_resolution_run!(current.id, authorize?: false)
    [turn] = Cases.started_turns_for_run!(run.id, authorize?: false)
    {:ok, revisions} = ConditionContext.current_condition_revisions(current)

    Cases.complete_turn!(
      turn.id,
      turn.revision,
      %{
        "outcome" => "decision",
        "condition_revisions" => revisions,
        "intent" => %{"type" => "handoff", "reason" => "Separate the independent service"}
      },
      :none,
      %{"action" => "route_resolver_decision", "turn_id" => turn.id},
      "Review the Resolver decision",
      authorize?: false
    )

    current = Cases.get_case!(incident.id, authorize?: false)

    child =
      Cases.split_case_conditions!(
        current.id,
        current.revision,
        [other.id],
        revisions,
        "The other service needs its own investigation",
        actor: context.admin
      )

    assert child.split_parent_id == incident.id

    assert {:ok, [%{condition_id: condition_id, status: :needs_observation}]} =
             ConditionRecovery.assess_current(child)

    assert condition_id == other.id
  end

  for terminal_status <- [:failed, :partial, :unknown] do
    @tag terminal_status: terminal_status
    test "a terminal #{terminal_status} effect needs post-outcome Target evidence", context do
      enable_signal_automation!(context.admin)
      status = context.terminal_status

      {incident, run, proposal, signal_provider} =
        authorized_proposal!("terminal-recovery-#{status}", context, trigger_kind: :signal)

      operation = Cases.accept_operation!(proposal.id, authorize?: false)

      assert :ok =
               OperationDelivery.run(operation.id,
                 target_invocation: invocation({:ok, %Target.EffectResult{status: status}})
               )

      assert_receive {:effect, _, _}

      {:ok, [condition]} = ConditionContext.current_conditions(incident)

      assert {:ok, nil} =
               ConditionRecovery.applied_effect_refresh_at(incident, run.id, [condition.id])

      recover_signal!(
        signal_provider,
        context,
        incident.initial_context["signal_event_key"],
        "post-#{status}-recovery"
      )

      assert {:ok, [%{status: :needs_observation}]} =
               ConditionRecovery.assess_current(incident)
    end
  end

  test "a partial manual Target effect cannot close the Case without observed symptom recovery",
       context do
    {incident, _run, proposal} = authorized_proposal!("manual-partial-effect", context)
    operation = Cases.accept_operation!(proposal.id, authorize?: false)

    assert :ok =
             OperationDelivery.run(operation.id,
               target_invocation: invocation({:ok, %Target.EffectResult{status: :partial}})
             )

    assert Cases.get_operation!(operation.id, authorize?: false).status == :partial
    assert Cases.get_case!(incident.id, authorize?: false).status != :resolved

    refute Enum.any?(
             Cases.list_case_events!(actor: context.admin),
             &(&1.case_id == incident.id and &1.event_type == "case_resolved")
           )
  end

  test "a second effect rejected before send does not stale source recovery", context do
    enable_signal_automation!(context.admin)

    {incident, run, proposal, signal_provider} =
      authorized_proposal!("second-effect-recovery", context, trigger_kind: :signal)

    first = Cases.accept_operation!(proposal.id, authorize?: false)

    assert :ok =
             OperationDelivery.run(first.id,
               target_invocation: invocation({:ok, %Target.EffectResult{status: :applied}})
             )

    assert_receive {:effect, _, _}
    first_attempt = Cases.verification_attempt_by_operation!(first.id, authorize?: false)

    assert :ok =
             VerificationDelivery.run(first_attempt.id,
               target_invocation:
                 invocation(
                   {:ok, verified_result(%{"unit" => "api.service", "active_state" => "active"})}
                 )
             )

    assert Cases.get_case!(incident.id, authorize?: false).pending_intent["action"] ==
             "await_source_recovery"

    Repo.update_all(
      from(item in Skopos.Cases.VerificationAttempt, where: item.id == ^first_attempt.id),
      set: [completed_at: DateTime.add(DateTime.utc_now(), -31, :second)]
    )

    [check_job] = recovery_check_jobs(incident.id)
    assert :ok = SignalRecoveryCheckWorker.perform(check_job)

    [turn] = Cases.started_turns_for_run!(run.id, authorize?: false)
    current = Cases.get_case!(incident.id, authorize?: false)
    {:ok, revisions} = ConditionContext.current_condition_revisions(current)
    source = hd(Cases.signal_context_evidence!(incident.id, authorize?: false))

    completed =
      Cases.complete_turn!(
        turn.id,
        turn.revision,
        %{
          "outcome" => "decision",
          "condition_revisions" => revisions,
          "intent" =>
            signal_proposal_intent(source.id, context, :effect)
            |> Map.put(
              "affected_conditions",
              Enum.map(revisions, fn %{"id" => id, "revision" => revision} ->
                %{"condition_id" => id, "revision" => revision}
              end)
            ),
          "resolver" => %{
            "provider_id" => context.resolver_provider.id,
            "provider_revision" => context.resolver_provider.revision,
            "assignment_id" => context.resolver_assignment.id,
            "assignment_revision" => context.resolver_assignment.revision
          },
          "usage" => %{"input_tokens" => 1, "output_tokens" => 1}
        },
        :proposal,
        %{"action" => "route_resolver_decision", "turn_id" => turn.id},
        "Review the Resolver decision",
        authorize?: false
      ).value

    Cases.route_downstream_decision!(completed.id, authorize?: false)
    second_proposal = Cases.materialize_proposal!(completed.id, authorize?: false)
    second_proposal = Cases.route_proposal_authority!(second_proposal.id, authorize?: false)
    second = Cases.accept_operation!(second_proposal.id, authorize?: false)

    recover_signal!(
      signal_provider,
      context,
      incident.initial_context["signal_event_key"],
      "recovery-before-second-send",
      DateTime.add(second.accepted_at, -1, :microsecond)
    )

    assert {:error, %ConditionRecovery.EffectIncomplete{}} =
             ConditionRecovery.assess_current(incident)

    snapshot = Cases.case_reconnect_snapshot!(incident.id, actor: context.operator)
    assert snapshot.conditions != []
    assert Enum.all?(snapshot.conditions, &is_nil(&1.assessment))

    assert :ok =
             OperationDelivery.run(second.id,
               target_invocation: invocation(fn -> flunk("stale effect was sent") end)
             )

    rejected = Cases.get_operation!(second.id, authorize?: false)
    assert rejected.status == :failed
    assert rejected.dispatch_started_at == nil
    refute_receive {:effect, _, _}

    assert {:ok, [%{status: :needs_observation}]} =
             ConditionRecovery.assess_current(incident)
  end

  test "a later dispatched effect on one Condition invalidates earlier source recovery",
       context do
    enable_signal_automation!(context.admin)

    {incident, run, initial_proposal, signal_provider} =
      authorized_proposal!("later-dispatched-effect", context, trigger_kind: :signal)

    first = Cases.accept_operation!(initial_proposal.id, authorize?: false)

    assert :ok =
             OperationDelivery.run(first.id,
               target_invocation: invocation({:ok, %Target.EffectResult{status: :applied}})
             )

    assert_receive {:effect, _, _}
    first_attempt = Cases.verification_attempt_by_operation!(first.id, authorize?: false)

    assert :ok =
             VerificationDelivery.run(first_attempt.id,
               target_invocation:
                 invocation(
                   {:ok,
                    %Target.Verification{
                      status: :not_verified,
                      observed_at: DateTime.utc_now(),
                      facts: %{"active_state" => "inactive"}
                    }}
                 )
             )

    assert_receive {:verify, _, _}
    [observation_turn] = Cases.started_turns_for_run!(run.id, authorize?: false)
    source = hd(Cases.signal_context_evidence!(incident.id, authorize?: false))

    observation_intent = signal_proposal_intent(source.id, context, :observation)

    observation_proposal =
      complete_signal_proposal!(observation_turn, observation_intent, incident, context)

    observation = Cases.accept_operation!(observation_proposal.id, authorize?: false)

    file =
      Targets.begin_artifact!(
        context.target.id,
        "before-effect.bin",
        "application/octet-stream",
        6,
        "96879611650f80a81392a52e0db9b0237669087c4518e1c130e541a505e0eeef",
        "before-second-effect",
        actor: context.operator
      )

    Targets.append_artifact_chunk!(file.id, 0, "active", actor: context.operator)
    Targets.complete_artifact!(file.id, actor: context.operator)
    reference = Targets.artifact_reference!(file.id, context.target.id, actor: context.operator)

    assert :ok =
             OperationDelivery.run(observation.id,
               target_invocation:
                 invocation({
                   :ok,
                   %Target.Observation{
                     facts: %{
                       "unit" => "api.service",
                       "active_state" => "inactive",
                       "file" => reference
                     },
                     observed_at: DateTime.utc_now()
                   }
                 })
             )

    assert_receive {:observe, _, _}
    observation_evidence = operation_evidence_record(observation.id)
    [effect_turn] = Cases.started_turns_for_run!(run.id, authorize?: false)
    {:ok, revisions} = ConditionContext.current_condition_revisions(incident)

    second_intent =
      signal_proposal_intent(observation_evidence.id, context, :effect)
      |> Map.put(
        "affected_conditions",
        Enum.map(revisions, fn %{"id" => id, "revision" => revision} ->
          %{"condition_id" => id, "revision" => revision}
        end)
      )

    second_proposal = complete_signal_proposal!(effect_turn, second_intent, incident, context)
    second = Cases.accept_operation!(second_proposal.id, authorize?: false)

    assert :ok =
             OperationDelivery.run(second.id,
               target_invocation: invocation({:ok, %Target.EffectResult{status: :applied}})
             )

    assert_receive {:effect, _, _}
    assert Cases.get_operation!(second.id, authorize?: false).status == :applied

    recover_signal!(
      signal_provider,
      context,
      incident.initial_context["signal_event_key"],
      "recovered-before-second-effect",
      DateTime.add(second.accepted_at, -1, :microsecond)
    )

    assert {:ok, [%{status: :stale_source}]} = ConditionRecovery.assess_current(incident)

    second_attempt = Cases.verification_attempt_by_operation!(second.id, authorize?: false)

    assert :ok =
             VerificationDelivery.run(second_attempt.id,
               target_invocation:
                 invocation(
                   {:ok, verified_result(%{"unit" => "api.service", "active_state" => "active"})}
                 )
             )

    [file_turn] = Cases.started_turns_for_run!(run.id, authorize?: false)

    assert :ok =
             ResolverDelivery.run(file_turn.id,
               target_invocation:
                 invocation({:ok, %Target.Capabilities{observations: [], effects: []}}),
               ai_invocation: %{
                 test_pid: self(),
                 respond: fn _request ->
                   {:ok,
                    %AI.ResolverDecision{
                      intent: %AI.FileRead{
                        source_evidence_id: observation_evidence.id,
                        reference: reference,
                        offset: 0,
                        length: 6,
                        reason: "Inspect the earlier captured response"
                      },
                      usage: %AI.Usage{input_tokens: 1, output_tokens: 1}
                    }}
                 end
               }
             )

    Cases.route_resolver_decision!(file_turn.id, authorize?: false)

    [receipt] =
      Cases.list_evidence!(actor: context.operator) |> Enum.filter(&(&1.kind == "file_read"))

    assert receipt.content["source_observed_at"] ==
             DateTime.to_iso8601(observation_evidence.observed_at)

    assert DateTime.compare(receipt.observed_at, second.accepted_at) == :gt

    assert Cases.read_file_content!(receipt.id, incident.id, authorize?: false)["value"] ==
             "active"

    assert {:ok, [%{status: :ready_for_review, evidence_ids: [evidence_id]}]} =
             ConditionRecovery.assess_current(incident)

    assert is_binary(evidence_id)
    assert Cases.get_case!(incident.id, authorize?: false).status == :running
  end

  test "saved fresh verification retries source-recovery scheduling without another observation",
       context do
    enable_signal_automation!(context.admin)

    {incident, run, proposal, _provider} =
      authorized_proposal!("source-wait-job-persistence", context, trigger_kind: :signal)

    operation = Cases.accept_operation!(proposal.id, authorize?: false)

    assert :ok =
             OperationDelivery.run(operation.id,
               target_invocation: invocation({:ok, %Target.EffectResult{status: :applied}})
             )

    assert_receive {:effect, _, _}
    attempt = Cases.verification_attempt_by_operation!(operation.id, authorize?: false)
    before_run = Cases.get_resolution_run!(run.id, authorize?: false)

    Repo.query!("""
    CREATE FUNCTION pg_temp.reject_source_wait_job() RETURNS trigger LANGUAGE plpgsql AS $$
    BEGIN
      IF NEW.worker = 'Skopos.Cases.Case.SignalRecoveryCheckWorker' THEN RETURN NULL; END IF;
      RETURN NEW;
    END;
    $$;
    """)

    Repo.query!("""
    CREATE TRIGGER reject_source_wait_job BEFORE INSERT ON oban_jobs
    FOR EACH ROW EXECUTE FUNCTION pg_temp.reject_source_wait_job()
    """)

    assert {:error, _error} =
             VerificationDelivery.run(attempt.id,
               target_invocation:
                 invocation({:ok, verified_result(%{"active_state" => "active"})})
             )

    assert_receive {:verify, _, _}
    assert Cases.get_verification_attempt!(attempt.id, authorize?: false).status == :verified

    assert Cases.get_case!(incident.id, authorize?: false).pending_intent["action"] ==
             "evaluate_verification"

    assert Cases.get_resolution_run!(run.id, authorize?: false) == before_run
    assert recovery_check_jobs(incident.id) == []

    refute Enum.any?(
             Cases.list_case_events!(actor: context.operator),
             &(&1.event_type == "case_awaiting_source_recovery")
           )

    Repo.query!("DROP TRIGGER reject_source_wait_job ON oban_jobs")

    for _ <- 1..2 do
      assert :ok =
               VerificationDelivery.run(attempt.id,
                 target_invocation:
                   invocation(fn -> flunk("saved verification was dispatched again") end)
               )
    end

    assert Cases.get_case!(incident.id, authorize?: false).pending_intent["action"] ==
             "await_source_recovery"

    assert [_job] = recovery_check_jobs(incident.id)
    assert Cases.get_resolution_run!(run.id, authorize?: false) == before_run
    refute_receive {:verify, _, _}
    refute_receive {:effect, _, _}
  end

  test "a verified Signal effect waits, then investigates once if monitoring stays firing",
       context do
    enable_signal_automation!(context.admin)

    {incident, run, proposal, signal_provider} =
      authorized_proposal!("signal-wait-expired", context, trigger_kind: :signal)

    event_key = incident.initial_context["signal_event_key"]
    operation = Cases.accept_operation!(proposal.id, authorize?: false)

    assert :ok =
             OperationDelivery.run(operation.id,
               target_invocation: invocation({:ok, %Target.EffectResult{status: :applied}})
             )

    attempt = Cases.verification_attempt_by_operation!(operation.id, authorize?: false)

    assert :ok =
             VerificationDelivery.run(attempt.id,
               target_invocation:
                 invocation(
                   {:ok, verified_result(%{"unit" => "api.service", "active_state" => "active"})}
                 )
             )

    waiting = Cases.get_case!(incident.id, authorize?: false)
    assert waiting.status == :running
    assert waiting.pending_intent["action"] == "await_source_recovery"
    [check_job] = recovery_check_jobs(incident.id)
    assert DateTime.compare(check_job.scheduled_at, DateTime.utc_now()) == :gt
    assert :ok = SignalRecoveryCheckWorker.perform(check_job)

    assert Cases.get_case!(incident.id, authorize?: false).pending_intent ==
             waiting.pending_intent

    # Move only the test fixture's completion clock past the wait boundary.
    Repo.update_all(
      from(item in Skopos.Cases.VerificationAttempt, where: item.id == ^attempt.id),
      set: [completed_at: DateTime.add(DateTime.utc_now(), -31, :second)]
    )

    assert :ok = SignalRecoveryCheckWorker.perform(check_job)
    assert :ok = SignalRecoveryCheckWorker.perform(check_job)

    investigating = Cases.get_case!(incident.id, authorize?: false)
    assert investigating.status == :running
    assert investigating.pending_intent["action"] == "resolve_turn"
    assert investigating.pending_intent["verification_attempt_id"] == attempt.id

    assert Enum.count(Cases.list_turns!(actor: context.admin), &(&1.resolution_run_id == run.id)) ==
             2

    assert Enum.count(Cases.list_operations!(actor: context.admin), &(&1.case_id == incident.id)) ==
             1

    recover_signal!(signal_provider, context, event_key, "recovered-after-reinvestigation")
    assert Cases.get_case!(incident.id, authorize?: false).status == :running
    assert [%{state: :recovered}] = Signals.list_conditions!(actor: context.admin)

    assert Enum.count(Cases.list_operations!(actor: context.admin), &(&1.case_id == incident.id)) ==
             1
  end

  test "a delayed pre-effect recovery event cannot settle a verified Signal Case", context do
    enable_signal_automation!(context.admin)

    {incident, _run, proposal, signal_provider} =
      authorized_proposal!("signal-stale-recovery", context, trigger_kind: :signal)

    event_key = incident.initial_context["signal_event_key"]
    operation = Cases.accept_operation!(proposal.id, authorize?: false)

    assert :ok =
             OperationDelivery.run(operation.id,
               target_invocation: invocation({:ok, %Target.EffectResult{status: :applied}})
             )

    attempt = Cases.verification_attempt_by_operation!(operation.id, authorize?: false)

    assert :ok =
             VerificationDelivery.run(attempt.id,
               target_invocation:
                 invocation(
                   {:ok, verified_result(%{"unit" => "api.service", "active_state" => "active"})}
                 )
             )

    assert Cases.get_case!(incident.id, authorize?: false).pending_intent["action"] ==
             "await_source_recovery"

    recovered_before_effect = DateTime.add(operation.accepted_at, -1, :second)

    recover_signal!(
      signal_provider,
      context,
      event_key,
      "late-old-recovery",
      recovered_before_effect
    )

    current = Cases.get_case!(incident.id, authorize?: false)
    assert [%{state: :recovered}] = Signals.list_conditions!(actor: context.admin)
    assert current.status == :running
    assert current.pending_intent["action"] == "await_source_recovery"

    refute Enum.any?(
             Cases.list_case_events!(actor: context.admin),
             &(&1.case_id == incident.id and &1.event_type == "case_resolved")
           )
  end

  test "a resumed run can conclude recovery from prior verified Target Evidence", context do
    {incident, run, proposal} = authorized_proposal!("resume-verification", context)
    operation = Cases.accept_operation!(proposal.id, authorize?: false)

    assert :ok =
             OperationDelivery.run(operation.id,
               target_invocation: invocation({:ok, %Target.EffectResult{status: :applied}})
             )

    attempt = Cases.verification_attempt_by_operation!(operation.id, authorize?: false)

    assert :ok =
             VerificationDelivery.run(attempt.id,
               target_invocation: invocation({:ok, verified_result(%{"service" => "running"})})
             )

    pending_case = Cases.get_case!(incident.id, authorize?: false)
    verification_id = pending_case.pending_intent["verification_evidence_id"]
    current_run = Cases.get_resolution_run!(run.id, authorize?: false)

    attention =
      Cases.require_case_attention!(
        pending_case.id,
        pending_case.revision,
        current_run.id,
        current_run.revision,
        "resume-after-verification",
        "Resolver delivery failed after verification",
        %{"action" => "retry_resolver"},
        "Resume the Case",
        authorize?: false
      )

    paused_run = Cases.get_resolution_run!(run.id, authorize?: false)

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
        "Continue after verified Target recovery",
        actor: context.operator
      )

    resumed_turn =
      Cases.list_turns!(actor: context.admin)
      |> Enum.find(&(&1.resolution_run_id == resumed_run.id))

    assert :ok =
             ResolverDelivery.run(resumed_turn.id,
               target_invocation:
                 invocation({:ok, %Target.Capabilities{observations: [], effects: []}}),
               ai_invocation: %{
                 test_pid: self(),
                 respond: fn request ->
                   assert request.alert_state == :not_applicable
                   assert AI.recovery_evidence_ids(request) == [verification_id]

                   assert Enum.any?(
                            request.historical_evidence,
                            &(&1.kind == "operation_outcome")
                          )

                   refute Enum.any?(request.historical_evidence, &(&1.id == verification_id))

                   {:ok,
                    %AI.ResolverDecision{
                      intent: %AI.RecoveryConclusion{
                        reason: "The prior verified Target state remains current after resume",
                        evidence_ids: [verification_id],
                        desired_outcome_claims: [
                          %{
                            "symptom_id" => request.case_symptom.id,
                            "evidence_id" => verification_id,
                            "fact_keys" => ["service"],
                            "reason" => "The verified service is running"
                          }
                        ]
                      },
                      usage: %AI.Usage{input_tokens: 3, output_tokens: 2}
                    }}
                 end
               }
             )

    completed = Cases.get_turn!(resumed_turn.id, authorize?: false)
    requested = Cases.route_downstream_decision!(completed.id, authorize?: false)
    assert requested.status == :running
    assert requested.pending_intent["action"] == "review_recovery"

    assert {:error, _reason} =
             Skopos.Cases.Turn.RecoveryReviewDelivery.run(completed.id,
               delivery_attempt: 1,
               max_delivery_attempts: 3,
               ai_invocation: %{
                 test_pid: self(),
                 respond: fn _request ->
                   {:error, :invalid_output, "Reviewer response does not match schema",
                    %AI.Usage{input_tokens: 5, output_tokens: 2}, "schema_validation", "/reason"}
                 end
               }
             )

    assert Cases.get_case!(incident.id, authorize?: false).status == :running
    approve_recovery!(completed, context, delivery_attempt: 2, max_delivery_attempts: 3)
    resolved = Cases.get_case!(incident.id, authorize?: false)
    replayed = Cases.route_downstream_decision!(completed.id, authorize?: false)

    assert resolved.status == :resolved
    assert replayed.id == resolved.id
    assert Cases.get_resolution_run!(resumed_run.id, authorize?: false).status == :completed

    assert Enum.count(Cases.list_operations!(actor: context.admin), &(&1.case_id == incident.id)) ==
             1
  end

  @tag late_recovery_evidence_read_fault: true, recovery_metadata: true
  test "a recovered Condition retries unreadable recovery Evidence before concluding",
       context do
    enable_signal_automation!(context.admin)

    {incident, run, proposal, _signal_provider} =
      authorized_proposal!("observation-recovery", context,
        trigger_kind: :signal,
        request_kind: :observation,
        recover_before_proposal: true
      )

    operation = Cases.accept_operation!(proposal.id, authorize?: false)
    observed_at = DateTime.utc_now()

    assert :ok =
             OperationDelivery.run(operation.id,
               target_invocation:
                 invocation(
                   {:ok,
                    %Target.Observation{
                      observed_at: observed_at,
                      facts: %{
                        "unit" => "api.service",
                        "active_state" => "active",
                        "padding" => String.duplicate("x", 64_000)
                      },
                      evidence: [%{"check" => "fresh"}]
                    }}
                 )
             )

    assert_receive {:observe, _, _}
    evidence = operation_evidence_record(operation.id)
    pending = Cases.get_case!(incident.id, authorize?: false).pending_intent
    turn = Cases.get_turn!(pending["turn_id"], authorize?: false)

    # Small foreign-source records exercise retained candidate history, not native observations.
    for index <- 1..257 do
      Cases.create_evidence_record!(
        %{
          case_id: incident.id,
          resolution_run_id: run.id,
          idempotency_key: "recovery-capacity:#{index}",
          kind: "observation",
          source: "capacity_fixture",
          source_ref: "candidate-#{index}",
          content: %{"status" => "applied"},
          observed_at: DateTime.utc_now()
        },
        authorize?: false
      )
    end

    first_page =
      Cases.condition_assessment_evidence!(incident.id, incident.inserted_at, authorize?: false)

    assert length(first_page.results) == 100
    assert first_page.more?
    refute Enum.any?(first_page.results, &(&1.id == evidence.id))

    second_page =
      Cases.condition_assessment_evidence!(incident.id, incident.inserted_at,
        authorize?: false,
        page: [after: List.last(first_page.results).__metadata__.keyset]
      )

    assert length(second_page.results) == 100
    assert second_page.more?

    third_page =
      Cases.condition_assessment_evidence!(incident.id, incident.inserted_at,
        authorize?: false,
        page: [after: List.last(second_page.results).__metadata__.keyset]
      )

    # The setup observation and the delivered receipt precede the 257 capacity records.
    assert length(third_page.results) == 59
    refute third_page.more?
    assert Enum.any?(third_page.results, &(&1.id == evidence.id))

    selection = %AI.Selection{
      role: :resolver,
      provider_id: context.resolver_provider.id,
      provider_revision: context.resolver_provider.revision,
      source: :assignment
    }

    assert {:ok, baseline, _context} = ResolverProjection.build(turn.id, selection)
    assert evidence.id in baseline.recovery_evidence_ids
    before_case = Cases.get_case!(incident.id, authorize?: false)
    before_run = Cases.get_resolution_run!(run.id, authorize?: false)
    before_turn = Cases.get_turn!(turn.id, authorize?: false)
    before_invocations = Cases.list_ai_invocations!(authorize?: false)

    snapshot = Cases.case_reconnect_snapshot!(incident.id, actor: context.operator)

    assert [%{assessment: %{status: :ready_for_review, evidence_ids: [recovery_id]}}] =
             snapshot.conditions

    assert recovery_id == evidence.id

    Repo.query!(
      "ALTER TABLE operations RENAME COLUMN result_details TO unavailable_result_details"
    )

    try do
      assert {:ok, metadata_snapshot} =
               Cases.case_reconnect_snapshot(incident.id, actor: context.operator)

      assert metadata_snapshot.conditions == snapshot.conditions

      assert {:error, %Ash.Error.Unknown{} = cause} =
               Cases.get_evidence(evidence.id, authorize?: false)

      assert Exception.message(cause) =~ "does not exist"
      assert {:error, %Ash.Error.Unknown{}} = ResolverProjection.build(turn.id, selection)
      assert Cases.list_ai_invocations!(authorize?: false) == before_invocations
      refute_receive {:observe, _, _}
      refute_receive {:resolve, _, _}
    after
      Repo.query!(
        "ALTER TABLE operations RENAME COLUMN unavailable_result_details TO result_details"
      )
    end

    with_projection_read_fault("evidences", "content", "jsonb", evidence.id, fn ->
      assert {:error, %Ash.Error.Unknown{} = error} =
               Cases.get_evidence(evidence.id, authorize?: false)

      assert Exception.message(error) =~ "Projection record temporarily unavailable"
      assert {:error, %Ash.Error.Unknown{}} = ResolverProjection.build(turn.id, selection)

      assert {:error, %Ash.Error.Unknown{}} =
               Skopos.Cases.Turn.ResolverWorker.perform(%Oban.Job{args: %{"turn_id" => turn.id}})

      assert Cases.list_ai_invocations!(authorize?: false) == before_invocations
    end)

    assert Cases.get_case!(incident.id, authorize?: false) == before_case
    assert Cases.get_resolution_run!(run.id, authorize?: false) == before_run
    assert Cases.get_turn!(turn.id, authorize?: false) == before_turn

    assert :ok =
             ResolverDelivery.run(turn.id,
               target_invocation:
                 invocation({:ok, %Target.Capabilities{observations: [], effects: []}}),
               ai_invocation: %{
                 test_pid: self(),
                 respond: fn request ->
                   assert request.alert_state == :recovered
                   assert AI.recovery_evidence_ids(request) == [evidence.id]
                   assert [%AI.Condition{} = condition] = request.conditions
                   assert condition.recovery_status == :ready_for_review
                   assert condition.recovery_evidence_ids == [evidence.id]

                   {:ok,
                    %AI.ResolverDecision{
                      intent: %AI.RecoveryConclusion{
                        reason: "Native source and exact service observation are healthy",
                        evidence_ids: [evidence.id],
                        condition_claims: [
                          %{
                            "condition_id" => condition.id,
                            "revision" => condition.revision,
                            "evidence_id" => evidence.id,
                            "reason" => "The inspected service is active"
                          }
                        ]
                      },
                      usage: %AI.Usage{input_tokens: 3, output_tokens: 2}
                    }}
                 end
               }
             )

    assert_receive {:resolve, _, _}

    assert :ok =
             Skopos.Cases.Turn.ResolverWorker.perform(%Oban.Job{args: %{"turn_id" => turn.id}})

    refute_receive {:resolve, _, _}

    assert Cases.get_resolution_run!(run.id, authorize?: false).ai_usage_units ==
             before_run.ai_usage_units + 5

    assert length(Cases.list_ai_invocations!(authorize?: false)) == length(before_invocations) + 1

    completed = Cases.get_turn!(turn.id, authorize?: false)

    requested = Cases.route_downstream_decision!(completed.id, authorize?: false)
    assert requested.status == :running
    approve_recovery!(completed, context)
    resolved = Cases.get_case!(incident.id, authorize?: false)
    assert resolved.status == :resolved
    assert Cases.get_resolution_run!(run.id, authorize?: false).status == :completed
    assert Cases.get_operation!(operation.id, authorize?: false).request_kind == :observation
    assert Enum.count(Cases.list_operations!(actor: context.admin)) == 1

    assert [job] = report_jobs(resolved.id)
    assert job.args["case_revision"] == resolved.revision
    assert :ok = GenerationWorker.perform(job)
    assert :ok = GenerationWorker.perform(job)

    report = Reports.report_by_case_revision!(resolved.id, resolved.revision, authorize?: false)
    assert report.case_id == resolved.id
    assert Enum.count(Reports.list_reports!(actor: context.admin)) == 1
  end

  @tag related_effect_scope_read_fault: true
  test "related Target effect needs both direct observations and a current relationship at dispatch",
       context do
    enable_signal_automation!(context.admin)

    {incident, _run, proposal, _signal_provider} =
      authorized_proposal!("related-effect", context,
        trigger_kind: :signal,
        request_kind: :observation,
        recover_before_proposal: true
      )

    symptom_observation = Cases.accept_operation!(proposal.id, authorize?: false)

    assert :ok =
             deliver_observation(symptom_observation, %{
               "unit" => "api.service",
               "active_state" => "inactive"
             })

    symptom_evidence = operation_evidence_record(symptom_observation.id)
    effect_context = separate_target!(context, "related-effect-target")

    relation =
      Targets.create_relationship!(
        context.target.id,
        effect_context.target.id,
        "managed_by",
        %{},
        nil,
        actor: context.admin
      )

    current = Cases.get_case!(incident.id, authorize?: false)

    Cases.record_case_selected_target!(
      current,
      current.revision,
      effect_context.target.id,
      effect_context.target.revision,
      authorize?: false
    )

    turn =
      incident.id
      |> Cases.get_case!(authorize?: false)
      |> Map.fetch!(:pending_intent)
      |> Map.fetch!("turn_id")
      |> then(&Cases.get_turn!(&1, authorize?: false))

    effect_target_observation_proposal =
      complete_signal_proposal!(
        turn,
        signal_proposal_intent(symptom_evidence.id, effect_context, :observation),
        incident,
        context
      )

    effect_target_observation =
      Cases.accept_operation!(effect_target_observation_proposal.id, authorize?: false)

    assert :ok =
             deliver_observation(effect_target_observation, %{
               "unit" => "api.service",
               "active_state" => "inactive"
             })

    target_evidence = operation_evidence_record(effect_target_observation.id)
    [condition] = ConditionContext.current_conditions(incident) |> elem(1)

    claim = %{
      "condition_id" => condition.id,
      "revision" => condition.revision,
      "relationship_id" => relation.id,
      "relationship_revision" => relation.revision
    }

    action = signal_proposal_intent(target_evidence.id, effect_context, :effect)
    evidence_ids = [symptom_evidence.id, target_evidence.id]

    assert {:ok, true} =
             ConditionContext.affected_current?(
               incident,
               :effect,
               [claim],
               evidence_ids,
               action
             )

    before_case = Cases.get_case!(incident.id, authorize?: false)
    before_run = Cases.active_resolution_run!(incident.id, authorize?: false)
    before_invocations = Cases.list_ai_invocations!(authorize?: false)

    for {table, column} <- [{"relationships", "facts"}, {"access_methods", "name"}] do
      Repo.query!("ALTER TABLE #{table} RENAME COLUMN #{column} TO unavailable_scope_input")

      try do
        assert {:error, error} =
                 ConditionContext.affected_current?(
                   incident,
                   :effect,
                   [claim],
                   evidence_ids,
                   action
                 )

        assert Exception.message(error) =~ "does not exist"
      after
        Repo.query!("ALTER TABLE #{table} RENAME COLUMN unavailable_scope_input TO #{column}")
      end
    end

    assert Cases.get_case!(incident.id, authorize?: false) == before_case
    assert Cases.active_resolution_run!(incident.id, authorize?: false) == before_run
    assert Cases.list_ai_invocations!(authorize?: false) == before_invocations

    assert {:ok, true} =
             ConditionContext.affected_current?(
               incident,
               :effect,
               [claim],
               evidence_ids,
               action
             )

    for {claims, ids} <- [
          {[%{"condition_id" => condition.id, "revision" => condition.revision}], evidence_ids},
          {[%{claim | "relationship_revision" => relation.revision + 1}], evidence_ids},
          {[claim], [symptom_evidence.id]},
          {[claim], [target_evidence.id]}
        ] do
      assert {:ok, false} =
               ConditionContext.affected_current?(
                 incident,
                 :effect,
                 claims,
                 ids,
                 action
               )
    end

    current = Cases.get_case!(incident.id, authorize?: false)
    turn = Cases.get_turn!(current.pending_intent["turn_id"], authorize?: false)

    effect_proposal =
      complete_signal_proposal!(
        turn,
        action
        |> Map.put("evidence_ids", evidence_ids)
        |> Map.put("affected_conditions", [claim]),
        incident,
        context
      )

    effect = Cases.accept_operation!(effect_proposal.id, authorize?: false)

    Targets.deactivate_relationship!(relation, relation.revision, actor: context.admin)

    assert %{state: :terminal} = Cases.claim_operation_dispatch!(effect.id, authorize?: false)
    assert Cases.get_operation!(effect.id, authorize?: false).dispatch_started_at == nil
    refute_receive {:effect, _, _}
  end

  test "a failed native symptom observation supports investigation but never recovery",
       context do
    enable_signal_automation!(context.admin)

    {incident, run, proposal, _signal_provider} =
      authorized_proposal!("failed-related-effect", context,
        trigger_kind: :signal,
        request_kind: :observation,
        recover_before_proposal: true
      )

    symptom_operation = Cases.accept_operation!(proposal.id, authorize?: false)

    assert :ok =
             OperationDelivery.run(symptom_operation.id,
               target_invocation: invocation({:error, :retryable, "Guest is unreachable"})
             )

    symptom = operation_evidence_record(symptom_operation.id)
    assert symptom.content["category"] == "observation_failed"

    assert {:ok,
            [
              %{
                status: :needs_observation,
                evidence_ids: [],
                failed_observation_ids: [failed_id]
              }
            ]} = ConditionRecovery.assess_current(incident)

    assert failed_id == symptom.id
    assert Cases.get_case!(incident.id, authorize?: false).status == :running

    pending = Cases.get_case!(incident.id, authorize?: false).pending_intent
    second_turn = Cases.get_turn!(pending["turn_id"], authorize?: false)

    second_proposal =
      complete_signal_proposal!(
        second_turn,
        signal_proposal_intent(symptom.id, context, :observation),
        incident,
        context
      )

    second_operation = Cases.accept_operation!(second_proposal.id, authorize?: false)

    assert :ok =
             OperationDelivery.run(second_operation.id,
               target_invocation: invocation({:error, :timeout, "Guest still unreachable"})
             )

    symptom = operation_evidence_record(second_operation.id)
    failed_id = symptom.id

    selection = %AI.Selection{
      role: :resolver,
      provider_id: context.resolver_provider.id,
      provider_revision: context.resolver_provider.revision,
      assignment_id: context.resolver_assignment.id,
      assignment_revision: context.resolver_assignment.revision,
      source: :assignment
    }

    pending = Cases.get_case!(incident.id, authorize?: false).pending_intent
    pre_effect_turn = Cases.get_turn!(pending["turn_id"], authorize?: false)

    assert {:ok, suppressed, _context} =
             ResolverProjection.build(pre_effect_turn.id, selection)

    assert suppressed.observation_tools == []

    effect_context = separate_target!(context, "failed-related-effect-target")

    relation =
      Targets.create_relationship!(
        context.target.id,
        effect_context.target.id,
        "managed_by",
        %{},
        nil,
        actor: context.admin
      )

    current = Cases.get_case!(incident.id, authorize?: false)

    Cases.record_case_selected_target!(
      current,
      current.revision,
      effect_context.target.id,
      effect_context.target.revision,
      authorize?: false
    )

    turn = Cases.get_turn!(current.pending_intent["turn_id"], authorize?: false)

    assert {:ok, request, _context} =
             ResolverProjection.build(turn.id, selection)

    assert [%AI.Condition{failed_observation_ids: [^failed_id]}] = request.conditions
    assert request.recovery_evidence_ids == []
    assert failed_id in Enum.map(request.evidence, & &1.id)
    assert relation.id in Enum.map(request.target_relations, & &1.id)
    assert failed_id in AI.proposal_evidence_ids(request)

    effect_target_observation_proposal =
      complete_signal_proposal!(
        turn,
        signal_proposal_intent(symptom.id, effect_context, :observation),
        incident,
        context
      )

    effect_target_observation =
      Cases.accept_operation!(effect_target_observation_proposal.id, authorize?: false)

    assert :ok =
             deliver_observation(effect_target_observation, %{
               "unit" => "api.service",
               "active_state" => "inactive"
             })

    target_evidence = operation_evidence_record(effect_target_observation.id)
    [condition] = ConditionContext.current_conditions(incident) |> elem(1)

    claim = %{
      "condition_id" => condition.id,
      "revision" => condition.revision,
      "relationship_id" => relation.id,
      "relationship_revision" => relation.revision
    }

    assert {:ok, nil} =
             ConditionRecovery.applied_effect_refresh_at(incident, run.id, [condition.id])

    action = signal_proposal_intent(target_evidence.id, effect_context, :effect)

    assert {:ok, true} =
             ConditionContext.affected_current?(
               incident,
               :effect,
               [claim],
               [symptom.id, target_evidence.id],
               action
             )

    assert {:ok, false} =
             ConditionContext.affected_current?(
               incident,
               :effect,
               [claim],
               [symptom.id],
               action
             )

    current = Cases.get_case!(incident.id, authorize?: false)
    turn = Cases.get_turn!(current.pending_intent["turn_id"], authorize?: false)

    effect_proposal =
      complete_signal_proposal!(
        turn,
        action
        |> Map.put("evidence_ids", [symptom.id, target_evidence.id])
        |> Map.put("affected_conditions", [claim]),
        incident,
        context
      )

    assert effect_proposal.affected_conditions == [claim]
    assert Cases.get_case!(incident.id, authorize?: false).status == :running

    effect = Cases.accept_operation!(effect_proposal.id, authorize?: false)

    assert :ok =
             OperationDelivery.run(effect.id,
               target_invocation: invocation({:ok, %Target.EffectResult{status: :applied}})
             )

    assert {:ok, %DateTime{}} =
             ConditionRecovery.applied_effect_refresh_at(incident, run.id, [condition.id])

    assert {:ok, nil} =
             ConditionRecovery.applied_effect_refresh_at(incident, run.id, [Ecto.UUID.generate()])

    attempt = Cases.verification_attempt_by_operation!(effect.id, authorize?: false)

    assert :ok =
             VerificationDelivery.run(attempt.id,
               target_invocation:
                 invocation(
                   {:ok, verified_result(%{"unit" => "api.service", "active_state" => "active"})}
                 )
             )

    waiting = Cases.get_case!(incident.id, authorize?: false)
    assert waiting.pending_intent["action"] == "await_source_recovery"
    {:ok, deadline, _offset} = DateTime.from_iso8601(waiting.pending_intent["wait_until"])
    Process.sleep(max(DateTime.diff(deadline, DateTime.utc_now(), :millisecond), 0) + 100)

    assert :ok =
             SignalRecoveryCheckWorker.perform(%Oban.Job{
               args: %{"case_id" => incident.id, "verification_attempt_id" => attempt.id}
             })

    current = Cases.get_case!(incident.id, authorize?: false)
    assert current.pending_intent["action"] == "resolve_turn"

    Cases.record_case_selected_target!(
      current,
      current.revision,
      context.target.id,
      context.target.revision,
      authorize?: false
    )

    turn = Cases.get_turn!(current.pending_intent["turn_id"], authorize?: false)

    assert {:ok, refreshed, _context} =
             ResolverProjection.build(turn.id, selection)

    assert Enum.any?(refreshed.observation_tools, &(&1.access_method_id == context.method.id))
  end

  test "both Reviewers receive required Condition observations outside recent history", context do
    configure_mode!(context.admin, :auto)
    enable_signal_automation!(context.admin)

    {incident, run, proposal, _signal_provider} =
      authorized_proposal!("review-required-history", context,
        trigger_kind: :signal,
        request_kind: :observation,
        recover_before_proposal: true
      )

    failed_operation = Cases.accept_operation!(proposal.id, authorize?: false)

    assert :ok =
             OperationDelivery.run(failed_operation.id,
               target_invocation: invocation({:error, :failed, "Earlier observation timed out"})
             )

    failed = operation_evidence_record(failed_operation.id)
    pending = Cases.get_case!(incident.id, authorize?: false).pending_intent
    turn = Cases.get_turn!(pending["turn_id"], authorize?: false)

    retry_proposal =
      complete_signal_proposal!(
        turn,
        signal_proposal_intent(failed.id, context, :observation),
        incident,
        context
      )

    healthy_operation = Cases.accept_operation!(retry_proposal.id, authorize?: false)
    assert :ok = deliver_observation(healthy_operation, %{"active_state" => "active"})
    healthy = operation_evidence_record(healthy_operation.id)
    unrelated_target_id = Ecto.UUID.generate()

    for index <- 1..101 do
      Cases.append_evidence!(
        incident.id,
        run.id,
        nil,
        "review-required-history-#{index}",
        "observation",
        "fixture",
        "unrelated-#{index}",
        %{
          "target_id" => if(index <= 40, do: context.target.id, else: unrelated_target_id),
          "facts" => %{"sample" => index}
        },
        DateTime.utc_now(),
        authorize?: false
      )
    end

    refute Enum.any?(
             Cases.review_context_evidence!(incident.id, authorize?: false),
             &(&1.id == failed.id)
           )

    pending = Cases.get_case!(incident.id, authorize?: false).pending_intent
    turn = Cases.get_turn!(pending["turn_id"], authorize?: false)
    {:ok, [condition]} = ConditionContext.current_conditions(incident)

    repair =
      complete_signal_proposal!(
        turn,
        signal_proposal_intent(healthy.id, context)
        |> Map.put("affected_conditions", [
          %{"condition_id" => condition.id, "revision" => condition.revision}
        ]),
        incident,
        context
      )

    assert repair.status == :reviewing

    with_projection_read_fault("evidences", "kind", "text", failed.id, fn ->
      assert {:error, %Ash.Error.Unknown{} = error} =
               Skopos.Cases.Proposal.ReviewDelivery.run(repair.id,
                 ai_invocation: %{
                   respond: fn _ -> flunk("proposal review ran without required evidence") end
                 }
               )

      assert Exception.message(error) =~ "Projection record temporarily unavailable"
    end)

    assert Cases.get_proposal!(repair.id, authorize?: false).status == :reviewing
    assert Cases.get_resolution_run!(run.id, authorize?: false).ai_usage_units == 0

    assert :ok =
             Skopos.Cases.Proposal.ReviewDelivery.run(repair.id,
               ai_invocation: %{
                 test_pid: self(),
                 respond: fn _ ->
                   {:ok,
                    %AI.ReviewDecision{
                      verdict: :rejected,
                      purpose_assessment: :remediation,
                      reason: "The service is already active; a restart is unnecessary",
                      usage: %AI.Usage{input_tokens: 4, output_tokens: 2}
                    }}
                 end
               }
             )

    assert_receive {:review, _, proposal_request}
    assert healthy.id in proposal_request.recovery_evidence_ids
    failed_context = Enum.find(proposal_request.context_evidence, &(&1.id == failed.id))
    assert failed_context, "declared failed observation must reach the proposal Reviewer"
    assert failed_context.content == failed.content

    assert Cases.get_proposal!(repair.id, authorize?: false).status == :rejected

    assert :ok =
             Skopos.Cases.Proposal.ReviewDelivery.run(repair.id,
               ai_invocation: %{respond: fn _ -> flunk("known proposal review was resent") end}
             )

    pending = Cases.get_case!(incident.id, authorize?: false).pending_intent
    turn = Cases.get_turn!(pending["turn_id"], authorize?: false)

    assert :ok =
             ResolverDelivery.run(turn.id,
               target_invocation:
                 invocation({:ok, %Target.Capabilities{observations: [], effects: []}}),
               ai_invocation: %{
                 test_pid: self(),
                 respond: fn request ->
                   [condition] = request.conditions

                   {:ok,
                    %AI.ResolverDecision{
                      intent: %AI.RecoveryConclusion{
                        reason: "The fresh observation reports an active service",
                        evidence_ids: [healthy.id],
                        condition_claims: [
                          %{
                            "condition_id" => condition.id,
                            "revision" => condition.revision,
                            "evidence_id" => healthy.id,
                            "reason" => "Service state is active"
                          }
                        ]
                      },
                      usage: %AI.Usage{input_tokens: 3, output_tokens: 2}
                    }}
                 end
               }
             )

    completed = Cases.get_turn!(turn.id, authorize?: false)
    assert completed.result["outcome"] == "decision", inspect(completed.result)
    Cases.route_downstream_decision!(turn.id, authorize?: false)

    with_projection_read_fault("evidences", "kind", "text", failed.id, fn ->
      assert {:error, %Ash.Error.Unknown{} = error} =
               Skopos.Cases.Turn.RecoveryReviewDelivery.run(turn.id,
                 ai_invocation: %{
                   respond: fn _ -> flunk("recovery review ran without required evidence") end
                 }
               )

      assert Exception.message(error) =~ "Projection record temporarily unavailable"
    end)

    assert Cases.get_case!(incident.id, authorize?: false).status == :running
    assert Cases.get_resolution_run!(run.id, authorize?: false).ai_usage_units == 11

    assert :ok =
             Skopos.Cases.Turn.RecoveryReviewDelivery.run(turn.id,
               ai_invocation: %{
                 test_pid: self(),
                 respond: fn _request ->
                   {:ok,
                    %AI.ReviewDecision{
                      verdict: :approved,
                      purpose_assessment: :remediation,
                      reason: "The newer direct observation supports recovery",
                      usage: %AI.Usage{input_tokens: 4, output_tokens: 2}
                    }}
                 end
               }
             )

    assert_receive {:review_recovery, _, request}
    assert [%AI.Condition{failed_observation_ids: [failed_id]}] = request.conditions
    assert failed_id == failed.id
    item = Enum.find(request.context_evidence, &(&1.id == failed.id))
    assert item, "declared failed observation must reach the independent Reviewer"
    assert item.content == failed.content
    assert Enum.any?(request.cited_evidence, &(&1.id == healthy.id))
    assert Cases.get_case!(incident.id, actor: context.operator).status == :resolved
    assert Cases.get_resolution_run!(run.id, authorize?: false).ai_usage_units == 17

    assert :ok =
             Skopos.Cases.Turn.RecoveryReviewDelivery.run(turn.id,
               ai_invocation: %{respond: fn _ -> flunk("known review was resent") end}
             )
  end

  test "Resolver receives a current failed observation after Signal recovery", context do
    enable_signal_automation!(context.admin)

    {incident, run, proposal, _signal_provider} =
      authorized_proposal!("failed-recovered-resolver", context,
        trigger_kind: :signal,
        request_kind: :observation,
        recover_before_proposal: true
      )

    observation = Cases.accept_operation!(proposal.id, authorize?: false)

    assert :ok =
             OperationDelivery.run(observation.id,
               target_invocation: invocation({:error, :failed, "Guest is unreachable"})
             )

    evidence = operation_evidence_record(observation.id)
    pending = Cases.get_case!(incident.id, authorize?: false).pending_intent
    turn = Cases.get_turn!(pending["turn_id"], authorize?: false)

    assert :ok =
             ResolverDelivery.run(turn.id,
               target_invocation:
                 invocation({:ok, %Target.Capabilities{observations: [], effects: []}}),
               ai_invocation: %{
                 test_pid: self(),
                 respond: fn request ->
                   assert request.alert_state == :recovered

                   assert [%AI.Condition{failed_observation_ids: [evidence_id]}] =
                            request.conditions

                   assert evidence_id == evidence.id

                   {:ok,
                    %AI.ResolverDecision{
                      intent: %AI.Handoff{
                        reason: "The current Linux observation failed",
                        required_input: "Investigate the host"
                      },
                      usage: %AI.Usage{input_tokens: 3, output_tokens: 2}
                    }}
                 end
               }
             )

    completed = Cases.get_turn!(turn.id, authorize?: false)
    assert completed.result["outcome"] == "decision"
    refute completed.result["outcome"] == "context_changed"
    assert Cases.get_resolution_run!(run.id, authorize?: false).ai_usage_units == 5
  end

  test "a recovered Signal with a still-failing Target observation persists a nonterminal assessment",
       context do
    enable_signal_automation!(context.admin)

    {incident, _run, proposal, _signal_provider} =
      authorized_proposal!("still-failing-assessment", context,
        trigger_kind: :signal,
        request_kind: :observation,
        recover_before_proposal: true
      )

    operation = Cases.accept_operation!(proposal.id, authorize?: false)

    assert :ok =
             OperationDelivery.run(operation.id,
               target_invocation:
                 invocation(
                   {:ok,
                    %Target.Observation{
                      observed_at: DateTime.utc_now(),
                      facts: %{"unit" => "api.service", "active_state" => "inactive"},
                      evidence: [%{"check" => "current"}]
                    }}
                 )
             )

    evidence = operation_evidence_record(operation.id)
    pending = Cases.get_case!(incident.id, authorize?: false).pending_intent
    turn = Cases.get_turn!(pending["turn_id"], authorize?: false)

    assert :ok =
             ResolverDelivery.run(turn.id,
               target_invocation:
                 invocation({:ok, %Target.Capabilities{observations: [], effects: []}}),
               ai_invocation: %{
                 test_pid: self(),
                 respond: fn request ->
                   assert request.alert_state == :recovered
                   assert [%AI.Condition{} = condition] = request.conditions
                   assert evidence.id in condition.recovery_evidence_ids

                   {:ok,
                    %AI.ResolverDecision{
                      intent: %AI.Handoff{
                        reason: "Service remains inactive despite monitoring recovery",
                        required_input: "Check the monitoring rule and service"
                      },
                      condition_assessments: [
                        %{
                          "condition_id" => condition.id,
                          "revision" => condition.revision,
                          "status" => "still_failing",
                          "evidence_ids" => [evidence.id],
                          "reason" => "Direct service inspection reports inactive"
                        }
                      ],
                      usage: %AI.Usage{input_tokens: 3, output_tokens: 2}
                    }}
                 end
               }
             )

    completed = Cases.get_turn!(turn.id, authorize?: false)

    assert [%{"status" => "still_failing", "evidence_ids" => [evidence_id]}] =
             completed.result["condition_assessments"]

    assert [%{"status" => "still_failing"}] =
             SkoposWeb.API.V1.WorkflowJSON.turn(completed).condition_assessments

    assert evidence_id == evidence.id

    assert Cases.route_downstream_decision!(completed.id, authorize?: false).status ==
             :needs_attention

    refute Enum.any?(
             Cases.list_case_events!(actor: context.admin),
             &(&1.case_id == incident.id and &1.event_type == "case_resolved")
           )
  end

  test "a recovered Signal with a cited current failing observation admits an effect proposal",
       context do
    enable_signal_automation!(context.admin)

    {incident, _run, observation_proposal, _signal_provider} =
      authorized_proposal!("premature-recovery-effect", context,
        trigger_kind: :signal,
        request_kind: :observation,
        recover_before_proposal: true
      )

    observation = Cases.accept_operation!(observation_proposal.id, authorize?: false)

    assert :ok =
             OperationDelivery.run(observation.id,
               target_invocation:
                 invocation(
                   {:ok,
                    %Target.Observation{
                      observed_at: DateTime.utc_now(),
                      facts: %{"unit" => "api.service", "active_state" => "inactive"},
                      evidence: [%{"check" => "current"}]
                    }}
                 )
             )

    evidence = operation_evidence_record(observation.id)
    current = Cases.get_case!(incident.id, authorize?: false)
    turn = Cases.get_turn!(current.pending_intent["turn_id"], authorize?: false)
    {:ok, [condition]} = ConditionContext.current_conditions(current)

    claim = %{"condition_id" => condition.id, "revision" => condition.revision}
    effect_intent = signal_proposal_intent(evidence.id, context)

    assert {:ok, true} =
             ConditionContext.affected_current?(
               current,
               :effect,
               [claim],
               [evidence.id],
               effect_intent
             )

    assert {:ok, false} =
             ConditionContext.affected_current?(
               current,
               :effect,
               [claim],
               ["unrelated"],
               effect_intent
             )

    unrelated_service = Map.put(effect_intent, "selectors", %{"unit" => "other.service"})

    assert {:ok, false} =
             ConditionContext.affected_current?(
               current,
               :effect,
               [claim],
               [evidence.id],
               unrelated_service
             )

    proposal =
      effect_intent
      |> Map.put("affected_conditions", [claim])
      |> then(&complete_signal_proposal!(turn, &1, current, context))

    assert proposal.request_kind == :effect
    assert proposal.evidence_ids == [evidence.id]
    assert proposal.affected_conditions == [claim]

    effect = Cases.accept_operation!(proposal.id, authorize?: false)

    assert :ok =
             OperationDelivery.run(effect.id,
               target_invocation: invocation({:ok, %Target.EffectResult{status: :applied}})
             )

    assert Cases.get_operation!(effect.id, authorize?: false).status == :applied

    assert Cases.get_case!(incident.id, authorize?: false).status == :running
  end

  for {trigger_kind, revoke} <- [
        {:manual, false},
        {:signal, false},
        {:manual, true},
        {:manual, :corrupt}
      ] do
    @tag file_recovery_trigger: trigger_kind, file_recovery_revoke: revoke
    test "#{trigger_kind} file-only recovery rechecks authority before completion (revoked=#{revoke})",
         context do
      kind = context.file_recovery_trigger
      if kind == :signal, do: enable_signal_automation!(context.admin)

      prepared =
        authorized_proposal!("file-observation-recovery", context,
          request_kind: :observation,
          trigger_kind: kind,
          recover_before_proposal: true
        )

      {incident, run, proposal} = {elem(prepared, 0), elem(prepared, 1), elem(prepared, 2)}

      operation = Cases.accept_operation!(proposal.id, authorize?: false)

      upload =
        Targets.begin_artifact!(
          context.target.id,
          "native-response.bin",
          "application/octet-stream",
          6,
          "96879611650f80a81392a52e0db9b0237669087c4518e1c130e541a505e0eeef",
          "manual-recovery-file",
          actor: context.operator
        )

      Targets.append_artifact_chunk!(upload.id, 0, "active", actor: context.operator)
      Targets.complete_artifact!(upload.id, actor: context.operator)

      reference =
        Targets.artifact_reference!(upload.id, context.target.id, actor: context.operator)

      assert :ok =
               OperationDelivery.run(operation.id,
                 target_invocation:
                   invocation(
                     {:ok,
                      %Target.Observation{
                        observed_at: DateTime.utc_now(),
                        facts: %{"file" => reference},
                        evidence: [%{"check" => "current"}]
                      }}
                   )
               )

      evidence = operation_evidence_record(operation.id)
      pending = Cases.get_case!(incident.id, authorize?: false).pending_intent
      turn = Cases.get_turn!(pending["turn_id"], authorize?: false)

      assert :ok =
               ResolverDelivery.run(turn.id,
                 target_invocation:
                   invocation({:ok, %Target.Capabilities{observations: [], effects: []}}),
                 ai_invocation: %{
                   test_pid: self(),
                   respond: fn _request ->
                     {:ok,
                      %AI.ResolverDecision{
                        intent: %AI.FileRead{
                          source_evidence_id: evidence.id,
                          reference: reference,
                          offset: 0,
                          length: 6,
                          reason: "Inspect the current response"
                        },
                        usage: %AI.Usage{input_tokens: 7, output_tokens: 5}
                      }}
                   end
                 }
               )

      Cases.route_resolver_decision!(turn.id, authorize?: false)

      [receipt] =
        Cases.list_evidence!(actor: context.operator) |> Enum.filter(&(&1.kind == "file_read"))

      pending = Cases.get_case!(incident.id, authorize?: false).pending_intent
      turn = Cases.get_turn!(pending["turn_id"], authorize?: false)

      selection = Providers.select_resolver_ai!([], authorize?: false)
      assert {:ok, projected, _context} = ResolverProjection.build(turn.id, selection)
      assert receipt.id in AI.recovery_evidence_ids(projected)

      assert :ok =
               ResolverDelivery.run(turn.id,
                 target_invocation:
                   invocation({:ok, %Target.Capabilities{observations: [], effects: []}}),
                 ai_invocation: %{
                   test_pid: self(),
                   respond: fn request ->
                     assert request.alert_state ==
                              if(kind == :signal, do: :recovered, else: :not_applicable)

                     assert receipt.id in AI.recovery_evidence_ids(request)
                     slice = Enum.find(request.evidence, &(&1.id == receipt.id))
                     assert slice.content["value"] == "active"
                     assert slice.content["encoding"] == "utf8"

                     {:ok,
                      %AI.ResolverDecision{
                        intent: %AI.RecoveryConclusion{
                          reason: "The requested service is active after direct inspection",
                          evidence_ids: [receipt.id],
                          condition_claims:
                            Enum.map(request.conditions, fn condition ->
                              assert receipt.id in condition.recovery_evidence_ids

                              %{
                                "condition_id" => condition.id,
                                "revision" => condition.revision,
                                "evidence_id" => receipt.id,
                                "reason" => "The body says active"
                              }
                            end),
                          desired_outcome_claims:
                            if(kind == :manual,
                              do: [
                                %{
                                  "symptom_id" => request.case_symptom.id,
                                  "evidence_id" => receipt.id,
                                  "fact_keys" => ["value"],
                                  "reason" => "The exact response body says active"
                                }
                              ],
                              else: []
                            )
                        },
                        usage: %AI.Usage{input_tokens: 3, output_tokens: 2}
                      }}
                   end
                 }
               )

      assert %{"outcome" => "decision"} = Cases.get_turn!(turn.id, authorize?: false).result
      requested = Cases.route_downstream_decision!(turn.id, authorize?: false)
      assert requested.status == :running

      assert :ok =
               Skopos.Cases.Turn.RecoveryReviewDelivery.run(turn.id,
                 ai_invocation: %{
                   test_pid: self(),
                   respond: fn request ->
                     slice = Enum.find(request.cited_evidence, &(&1.id == receipt.id))
                     assert slice.content["value"] == "active"
                     assert slice.content["encoding"] == "utf8"
                     assert slice.content["source_evidence_id"] == evidence.id
                     assert slice.content["reference"] == reference

                     assert slice.content["source_observed_at"] ==
                              DateTime.to_iso8601(evidence.observed_at)

                     case context.file_recovery_revoke do
                       true ->
                         Targets.revoke_artifact!(reference["id"], actor: context.operator)

                       :corrupt ->
                         Skopos.Repo.query!(
                           "UPDATE evidences SET content = jsonb_set(content, '{sha256}', to_jsonb($1::text)) WHERE id = $2",
                           [String.duplicate("0", 64), Ecto.UUID.dump!(receipt.id)]
                         )

                       false ->
                         :ok
                     end

                     {:ok,
                      %AI.ReviewDecision{
                        purpose_assessment: :remediation,
                        verdict: :approved,
                        reason: "The cited service state is active",
                        desired_outcome_assessment:
                          if(kind == :manual,
                            do: %{
                              "symptom_id" => request.case_symptom.id,
                              "desired_outcome" => request.case_symptom.desired_outcome,
                              "evidence_ids" => [receipt.id],
                              "status" => "supported",
                              "reason" => "The current service observation supports the outcome"
                            },
                            else: nil
                          ),
                        usage: %AI.Usage{input_tokens: 4, output_tokens: 2}
                      }}
                   end
                 }
               )

      resolved = Cases.get_case!(incident.id, authorize?: false)

      if context.file_recovery_revoke do
        assert resolved.status == :needs_attention
        assert is_nil(resolved.resolved_at)
      else
        assert resolved.status == :resolved
        assert %DateTime{} = resolved.resolved_at
        assert Cases.get_resolution_run!(run.id, authorize?: false).status == :completed
      end

      assert Cases.get_resolution_run!(run.id, authorize?: false).ai_usage_units == 23

      if context.file_recovery_revoke != :corrupt do
        assert Cases.get_evidence!(receipt.id, actor: context.operator).content == receipt.content
      end
    end
  end

  test "a saved recovery conclusion cannot request Review without a persisted job", context do
    {incident, run, turn, _evidence} = recovery_conclusion!(context, "recovery-review-job")
    before_case = Cases.get_case!(incident.id, actor: context.operator)
    before_run = Cases.get_resolution_run!(run.id, authorize?: false)
    before_events = Cases.list_case_events!(actor: context.operator)
    before_invocations = Cases.list_ai_invocations!(actor: context.operator)

    Repo.query!("""
    CREATE FUNCTION pg_temp.reject_recovery_review_job() RETURNS trigger LANGUAGE plpgsql AS $$
    BEGIN
      IF NEW.worker = 'Skopos.Cases.Turn.RecoveryReviewWorker' THEN RETURN NULL; END IF;
      RETURN NEW;
    END;
    $$;
    """)

    Repo.query!("""
    CREATE TRIGGER reject_recovery_review_job BEFORE INSERT ON oban_jobs
    FOR EACH ROW EXECUTE FUNCTION pg_temp.reject_recovery_review_job()
    """)

    assert {:error, _error} = Cases.route_downstream_decision(turn.id, authorize?: false)
    assert Cases.get_case!(incident.id, actor: context.operator) == before_case
    assert Cases.get_resolution_run!(run.id, authorize?: false) == before_run
    assert Cases.list_case_events!(actor: context.operator) == before_events
    assert Cases.list_ai_invocations!(actor: context.operator) == before_invocations

    Repo.query!("DROP TRIGGER reject_recovery_review_job ON oban_jobs")

    for _ <- 1..2 do
      assert Cases.route_downstream_decision!(turn.id, authorize?: false).pending_intent ==
               %{"action" => "review_recovery", "turn_id" => turn.id}
    end

    assert [job] =
             Repo.all(Oban.Job)
             |> Enum.filter(&(&1.worker == "Skopos.Cases.Turn.RecoveryReviewWorker"))

    assert job.args == %{"turn_id" => turn.id}
    assert is_integer(job.id)
    assert Cases.get_resolution_run!(run.id, authorize?: false) == before_run
    assert Cases.list_ai_invocations!(actor: context.operator) == before_invocations
  end

  for {table, predicate, failure} <- [
        {"case_events", "NEW.event_type = 'case_resolved'",
         "RAISE EXCEPTION 'test completion persistence unavailable';"},
        {"oban_jobs", "NEW.worker = 'Skopos.Reports.Report.GenerationWorker'", "RETURN NULL;"}
      ] do
    @tag completion_table: table, completion_predicate: predicate, completion_failure: failure
    test "a #{table} completion failure retains the approved recovery for replay", context do
      {incident, run, turn, evidence} =
        recovery_conclusion!(context, "recovery-completion-failure")

      assert Cases.route_downstream_decision!(turn.id, authorize?: false).pending_intent[
               "action"
             ] == "review_recovery"

      Repo.query!("""
      CREATE FUNCTION pg_temp.reject_case_completion() RETURNS trigger LANGUAGE plpgsql AS $$
      BEGIN
        IF #{context.completion_predicate} THEN
          #{context.completion_failure}
        END IF;
        RETURN NEW;
      END;
      $$;
      """)

      Repo.query!("""
      CREATE TRIGGER reject_case_completion BEFORE INSERT ON #{context.completion_table}
      FOR EACH ROW EXECUTE FUNCTION pg_temp.reject_case_completion()
      """)

      assert {:error, _} =
               Skopos.Cases.Turn.RecoveryReviewDelivery.run(turn.id,
                 ai_invocation: %{
                   test_pid: self(),
                   respond: fn request ->
                     {:ok,
                      %AI.ReviewDecision{
                        purpose_assessment: :remediation,
                        verdict: :approved,
                        reason: "The current observation supports the desired outcome",
                        desired_outcome_assessment: %{
                          "symptom_id" => request.case_symptom.id,
                          "desired_outcome" => request.case_symptom.desired_outcome,
                          "evidence_ids" => [evidence.id],
                          "status" => "supported",
                          "reason" => "The inspected service is active"
                        },
                        usage: %AI.Usage{input_tokens: 4, output_tokens: 2}
                      }}
                   end
                 }
               )

      assert_receive {:review_recovery, %{model: "reviewer-model"}, _request}
      waiting = Cases.get_case!(incident.id, authorize?: false)
      assert waiting.status == :running
      assert waiting.pending_intent == %{"action" => "review_recovery", "turn_id" => turn.id}
      charged = Cases.get_resolution_run!(run.id, authorize?: false)
      assert charged.status == :running
      assert report_jobs(incident.id) == []
      events = Cases.page_case_events!(incident.id, actor: context.operator).results
      assert Enum.count(events, &(&1.event_type == "recovery_review_decided")) == 1
      refute Enum.any?(events, &(&1.event_type == "case_resolved"))

      Repo.query!("DROP TRIGGER reject_case_completion ON #{context.completion_table}")

      for replay <- 2..3 do
        assert :ok =
                 Skopos.Cases.Turn.RecoveryReviewWorker.perform(%Oban.Job{
                   args: %{"turn_id" => turn.id},
                   attempt: replay,
                   max_attempts: 3
                 })
      end

      refute_receive {:review_recovery, _, _}
      assert Cases.get_case!(incident.id, authorize?: false).status == :resolved
      completed = Cases.get_resolution_run!(run.id, authorize?: false)
      assert completed.status == :completed
      assert completed.ai_usage_units == charged.ai_usage_units
      assert [_job] = report_jobs(incident.id)
      events = Cases.page_case_events!(incident.id, actor: context.operator).results
      assert Enum.count(events, &(&1.event_type == "case_resolved")) == 1
    end
  end

  for {table, column} <- [
        {"cases", "selected_target_revision"},
        {"ai_usage_role_assignments", "priority"},
        {"evidences", "content"}
      ] do
    @tag recovery_review_input_read_fault: true, read_table: table, read_column: column
    test "temporary #{table} recovery Review input read failure retains the saved conclusion",
         context do
      {incident, run, turn, _evidence} =
        recovery_conclusion!(context, "recovery-review-case-read")

      Cases.route_downstream_decision!(turn.id, authorize?: false)
      before_case = Cases.get_case!(incident.id, authorize?: false)
      before_run = Cases.get_resolution_run!(run.id, authorize?: false)
      before_invocations = Cases.list_ai_invocations!(authorize?: false)
      before_events = Cases.list_case_events!(actor: context.operator)

      Repo.query!(
        "ALTER TABLE #{context.read_table} RENAME COLUMN #{context.read_column} TO unavailable_input"
      )

      try do
        assert {:error, _error} =
                 Skopos.Cases.Turn.RecoveryReviewWorker.perform(%Oban.Job{
                   args: %{"turn_id" => turn.id},
                   attempt: 1,
                   max_attempts: 3
                 })
      after
        Repo.query!(
          "ALTER TABLE #{context.read_table} RENAME COLUMN unavailable_input TO #{context.read_column}"
        )
      end

      assert Cases.get_case!(incident.id, authorize?: false) == before_case
      assert Cases.get_resolution_run!(run.id, authorize?: false) == before_run
      assert Cases.list_ai_invocations!(authorize?: false) == before_invocations
      events = Cases.list_case_events!(actor: context.operator)
      refute Enum.any?(events, &(&1.event_type in ["case_attention_required", "case_resolved"]))

      assert Enum.count(events, &(&1.event_type == "recovery_review_decided")) ==
               Enum.count(before_events, &(&1.event_type == "recovery_review_decided"))

      approve_recovery!(turn, context)
      after_run = Cases.get_resolution_run!(run.id, authorize?: false)
      assert after_run.ai_usage_units == before_run.ai_usage_units + 6

      assert :ok =
               Skopos.Cases.Turn.RecoveryReviewWorker.perform(%Oban.Job{
                 args: %{"turn_id" => turn.id},
                 attempt: 2,
                 max_attempts: 3
               })

      refute_receive {:review_recovery, _, _}

      assert Cases.get_resolution_run!(run.id, authorize?: false).ai_usage_units ==
               after_run.ai_usage_units

      assert length(Cases.list_ai_invocations!(authorize?: false)) ==
               length(before_invocations) + 1
    end
  end

  @tag owned_context_read_fault: true
  test "a changed Recovery Reviewer assignment after claim sends no recovery review", context do
    {incident, run, turn, _evidence} =
      recovery_conclusion!(context, "recovery-assignment-changed")

    Cases.route_downstream_decision!(turn.id, authorize?: false)
    before_units = Cases.get_resolution_run!(run.id, authorize?: false).ai_usage_units
    prior_ids = MapSet.new(Cases.list_ai_invocations!(authorize?: false), & &1.id)
    changed = :atomics.new(1, [])

    assert :ok =
             Skopos.Cases.Turn.RecoveryReviewDelivery.run(turn.id,
               ai_invocation: %{
                 test_pid: self(),
                 cancelled?: fn ->
                   if :atomics.compare_exchange(changed, 1, 0, 1) == :ok,
                     do:
                       Skopos.TestAIUsage.configure!(
                         context.reviewer_provider.id,
                         :reviewer,
                         11,
                         context.admin
                       )

                   false
                 end,
                 respond: fn _request -> flunk("obsolete recovery assignment dispatched AI") end
               }
             )

    refute_receive {:review_recovery, _, _}

    assert [%{dispatch_confirmed: false, usage_reported: false}] =
             Cases.list_ai_invocations!(authorize?: false)
             |> Enum.reject(&MapSet.member?(prior_ids, &1.id))

    assert Cases.get_resolution_run!(run.id, authorize?: false).ai_usage_units == before_units
    assert Cases.get_case!(incident.id, authorize?: false).status == :running
    pending = Cases.get_case!(incident.id, authorize?: false).pending_intent
    assert pending["action"] == "resolve_turn"
    refute pending["turn_id"] == turn.id
    successor = Cases.get_turn!(pending["turn_id"], authorize?: false)
    assert successor.intent["source"] == "recovery_review_context_changed"
    assert :ok = Skopos.Cases.Turn.RecoveryReviewDelivery.run(turn.id)
    refute_receive {:review_recovery, _, _}
    assert Cases.get_case!(incident.id, authorize?: false).status == :running
    assert Cases.get_case!(incident.id, authorize?: false).pending_intent == pending
    assert Cases.get_resolution_run!(run.id, authorize?: false).ai_usage_units == before_units
  end

  @tag owned_context_read_fault: true
  test "a built-in Recovery Reviewer Case read fault remains an unsent retry", context do
    {incident, run, turn, _evidence} =
      recovery_conclusion!(context, "owned-recovery-context-read")

    Cases.route_downstream_decision!(turn.id, authorize?: false)
    original_run = Cases.get_resolution_run!(run.id, authorize?: false)
    prior_ids = MapSet.new(Cases.list_ai_invocations!(authorize?: false), & &1.id)
    injected = :atomics.new(1, [])

    try do
      assert {:error, error} =
               Skopos.Cases.Turn.RecoveryReviewDelivery.run(turn.id,
                 ai_invocation: %{
                   test_pid: self(),
                   cancelled?: fn ->
                     if :atomics.compare_exchange(injected, 1, 0, 1) == :ok,
                       do:
                         Repo.query!(
                           "ALTER TABLE cases RENAME COLUMN title TO unavailable_case_title"
                         )

                     false
                   end,
                   respond: fn _request ->
                     flunk("an unreadable Case dispatched Recovery Reviewer AI")
                   end
                 }
               )

      assert Exception.message(error) =~ "title"
    after
      if :atomics.get(injected, 1) == 1,
        do: Repo.query!("ALTER TABLE cases RENAME COLUMN unavailable_case_title TO title")
    end

    refute_receive {:review_recovery, _, _}

    assert [%{status: :queued, dispatch_confirmed: false, usage_reported: false}] =
             Cases.list_ai_invocations!(authorize?: false)
             |> Enum.reject(&MapSet.member?(prior_ids, &1.id))

    assert Cases.get_case!(incident.id, authorize?: false).status == :running

    assert Cases.get_resolution_run!(run.id, authorize?: false).ai_usage_units ==
             original_run.ai_usage_units
  end

  @tag ai_unsent_retry: true
  test "a Recovery Reviewer read fault retries its unsent invocation without requiring attention",
       context do
    {incident, run, turn, _evidence} = recovery_conclusion!(context, "recovery-unsent-read")
    Cases.route_downstream_decision!(turn.id, authorize?: false)
    before_case = Cases.get_case!(incident.id, authorize?: false)
    before_run = Cases.get_resolution_run!(run.id, authorize?: false)
    before_turn = Cases.get_turn!(turn.id, authorize?: false)
    before_invocations = Cases.list_ai_invocations!(authorize?: false)

    assert {:error, error} =
             Skopos.Cases.Turn.RecoveryReviewDelivery.run(turn.id,
               ai_invocation: %{
                 test_pid: self(),
                 cancelled?: fn ->
                   {:error, error} =
                     Skopos.Repo.query("SELECT invocation_context_unavailable", [],
                       mode: :savepoint
                     )

                   raise error
                 end,
                 respond: fn _request -> flunk("unsent Recovery Reviewer was called") end
               }
             )

    assert Exception.message(error) =~ "invocation_context_unavailable"
    refute_receive {:review_recovery, _, _}
    assert Cases.get_case!(incident.id, authorize?: false) == before_case
    assert Cases.get_resolution_run!(run.id, authorize?: false) == before_run
    assert Cases.get_turn!(turn.id, authorize?: false) == before_turn

    [unsent] =
      Cases.list_ai_invocations!(authorize?: false)
      |> Enum.reject(fn invocation ->
        Enum.any?(before_invocations, &(&1.id == invocation.id))
      end)

    assert unsent.status == :queued
    assert unsent.dispatch_confirmed == false
    assert unsent.dispatch_started_at == nil
    assert unsent.usage_reported == false

    assert :ok =
             Skopos.Cases.Turn.RecoveryReviewDelivery.run(turn.id,
               delivery_attempt: 2,
               ai_invocation: %{
                 test_pid: self(),
                 respond: fn request ->
                   assert request.retry_context == nil

                   {:ok,
                    %AI.ReviewDecision{
                      purpose_assessment: :remediation,
                      verdict: :approved,
                      reason: "The claimed facts support the stated recovery",
                      desired_outcome_assessment: %{
                        "symptom_id" => request.case_symptom.id,
                        "desired_outcome" => request.case_symptom.desired_outcome,
                        "evidence_ids" => request.conclusion.evidence_ids,
                        "status" => "supported",
                        "reason" => "The observed service state satisfies the desired outcome"
                      },
                      usage: %AI.Usage{input_tokens: 4, output_tokens: 2}
                    }}
                 end
               }
             )

    assert_receive {:review_recovery, _, _}
    assert Cases.get_case!(incident.id, authorize?: false).status == :resolved

    completed = Enum.find(Cases.list_ai_invocations!(authorize?: false), &(&1.id == unsent.id))
    assert completed.status == :completed

    assert Cases.get_resolution_run!(run.id, authorize?: false).ai_usage_units ==
             before_run.ai_usage_units + 6

    assert :ok = Skopos.Cases.Turn.RecoveryReviewDelivery.run(turn.id)
    refute_receive {:review_recovery, _, _}

    assert Cases.get_resolution_run!(run.id, authorize?: false).ai_usage_units ==
             before_run.ai_usage_units + 6
  end

  @tag recovery_caller_cancellation: true
  test "Recovery Reviewer honors caller cancellation without sending or charging", context do
    {incident, run, turn, _evidence} =
      recovery_conclusion!(context, "recovery-caller-cancellation")

    Cases.route_downstream_decision!(turn.id, authorize?: false)
    before_run = Cases.get_resolution_run!(run.id, authorize?: false)
    before_invocations = Cases.list_ai_invocations!(authorize?: false)

    assert :ok =
             Skopos.Cases.Turn.RecoveryReviewDelivery.run(turn.id,
               ai_invocation: %{
                 test_pid: self(),
                 cancelled?: fn -> true end,
                 respond: fn _request -> flunk("cancelled Recovery Reviewer was sent") end
               }
             )

    refute_receive {:review_recovery, _, _}
    assert Cases.get_case!(incident.id, authorize?: false).resolved_at == nil

    assert Cases.get_resolution_run!(run.id, authorize?: false).ai_usage_units ==
             before_run.ai_usage_units

    [cancelled] =
      Cases.list_ai_invocations!(authorize?: false)
      |> Enum.reject(fn invocation ->
        Enum.any?(before_invocations, &(&1.id == invocation.id))
      end)

    assert cancelled.role == :reviewer
    assert cancelled.status == :failed
    assert cancelled.category == "cancelled"
    assert cancelled.dispatch_confirmed == false
    assert cancelled.usage_reported == false

    assert :ok =
             Skopos.Cases.Turn.RecoveryReviewDelivery.run(turn.id,
               ai_invocation: %{
                 test_pid: self(),
                 respond: fn _request -> flunk("cancelled Recovery Reviewer was replayed") end
               }
             )

    refute_receive {:review_recovery, _, _}
    assert length(Cases.list_ai_invocations!(authorize?: false)) == length(before_invocations) + 1

    assert Cases.get_resolution_run!(run.id, authorize?: false).ai_usage_units ==
             before_run.ai_usage_units
  end

  @tag paid_recovery_context_read_fault: true
  test "a paid Recovery Review is retained when Condition reads fail after its response",
       context do
    enable_signal_automation!(context.admin)

    {incident, run, turn, _evidence} =
      recovery_conclusion!(context, "paid-recovery-context-read",
        trigger_kind: :signal,
        recover_before_proposal: true
      )

    Cases.route_downstream_decision!(turn.id, authorize?: false)
    before_run = Cases.get_resolution_run!(run.id, authorize?: false)

    try do
      assert {:error, _error} =
               Skopos.Cases.Turn.RecoveryReviewDelivery.run(turn.id,
                 ai_invocation: %{
                   test_pid: self(),
                   respond: fn _request ->
                     Repo.query!(
                       "ALTER TABLE conditions RENAME COLUMN subject_key TO unavailable_subject_key"
                     )

                     {:ok,
                      %AI.ReviewDecision{
                        purpose_assessment: :remediation,
                        verdict: :approved,
                        reason: "The current observation supports the stated recovery",
                        usage: %AI.Usage{input_tokens: 4, output_tokens: 2}
                      }}
                   end
                 }
               )
    after
      Repo.query!("ALTER TABLE conditions RENAME COLUMN unavailable_subject_key TO subject_key")
    end

    assert_receive {:review_recovery, _, _}

    reviews =
      Enum.filter(
        Cases.list_case_events!(actor: context.admin),
        &(&1.event_type == "recovery_review_decided")
      )

    invocations = Cases.list_ai_invocations!(authorize?: false)

    assert Cases.get_case!(incident.id, authorize?: false).status == :running
    assert [%{data: %{"verdict" => "approved"}}] = reviews
    assert Enum.count(invocations, &(&1.role == :reviewer and &1.status == :completed)) == 1

    assert Cases.get_resolution_run!(run.id, authorize?: false).ai_usage_units ==
             before_run.ai_usage_units + 6

    for _ <- 1..2 do
      assert :ok =
               Skopos.Cases.Turn.RecoveryReviewWorker.perform(%Oban.Job{
                 args: %{"turn_id" => turn.id}
               })
    end

    refute_receive {:review_recovery, _, _}
    assert Cases.get_case!(incident.id, authorize?: false).status == :resolved

    assert Cases.get_resolution_run!(run.id, authorize?: false).ai_usage_units ==
             before_run.ai_usage_units + 6

    assert length(Cases.list_ai_invocations!(authorize?: false)) == length(invocations)
  end

  for change <- [:reviewer_disabled, :condition_refired] do
    @tag paid_recovery_context_change: true, recovery_change: change
    test "a paid recovery approval cannot resolve after #{change}", context do
      enable_signal_automation!(context.admin)

      {incident, run, turn, _evidence} =
        recovery_conclusion!(context, "paid-recovery-role-change",
          trigger_kind: :signal,
          recover_before_proposal: true
        )

      Cases.route_downstream_decision!(turn.id, authorize?: false)
      before_run = Cases.get_resolution_run!(run.id, authorize?: false)

      assert :ok =
               Skopos.Cases.Turn.RecoveryReviewDelivery.run(turn.id,
                 ai_invocation: %{
                   test_pid: self(),
                   respond: fn _request ->
                     if context.recovery_change == :reviewer_disabled do
                       Providers.disable_provider!(
                         context.reviewer_provider,
                         context.reviewer_provider.revision,
                         actor: context.admin
                       )
                     else
                       signal_provider =
                         Enum.find(
                           Providers.list_providers!(actor: context.admin),
                           &(&1.kind == :signal)
                         )

                       fire_signal!(
                         signal_provider,
                         context,
                         incident.initial_context["signal_event_key"],
                         "refired-after-paid-review",
                         DateTime.add(DateTime.utc_now(), 1, :second)
                       )
                     end

                     {:ok,
                      %AI.ReviewDecision{
                        purpose_assessment: :remediation,
                        verdict: :approved,
                        reason: "The inspected service is active",
                        usage: %AI.Usage{input_tokens: 4, output_tokens: 2}
                      }}
                   end
                 }
               )

      assert_receive {:review_recovery, _, _}
      current = Cases.get_case!(incident.id, authorize?: false)

      assert current.status ==
               if(context.recovery_change == :reviewer_disabled,
                 do: :needs_attention,
                 else: :running
               )

      if context.recovery_change == :condition_refired do
        assert current.pending_intent["action"] == "resolve_turn"
        assert [successor] = Cases.started_turns_for_run!(run.id, authorize?: false)
        assert current.pending_intent["turn_id"] == successor.id
      end

      assert Cases.get_resolution_run!(run.id, authorize?: false).ai_usage_units ==
               before_run.ai_usage_units + 6

      events = Cases.list_case_events!(actor: context.admin)
      assert Enum.count(events, &(&1.event_type == "recovery_review_decided")) == 1
      refute Enum.any?(events, &(&1.event_type == "case_resolved"))

      assert Enum.count(
               Cases.list_ai_invocations!(authorize?: false),
               &(&1.role == :reviewer and &1.status == :completed)
             ) == 1

      assert :ok =
               Skopos.Cases.Turn.RecoveryReviewWorker.perform(%Oban.Job{
                 args: %{"turn_id" => turn.id}
               })

      refute_receive {:review_recovery, _, _}

      refute Enum.any?(
               Cases.list_case_events!(actor: context.admin),
               &(&1.event_type == "case_resolved")
             )

      assert Cases.get_resolution_run!(run.id, authorize?: false).ai_usage_units ==
               before_run.ai_usage_units + 6

      if context.recovery_change == :condition_refired do
        assert [successor] = Cases.started_turns_for_run!(run.id, authorize?: false)

        assert :ok =
                 ResolverDelivery.run(successor.id,
                   ai_invocation: %{
                     test_pid: self(),
                     respond: fn request ->
                       assert Enum.any?(request.conditions, &(&1.state == :firing))

                       {:ok,
                        %AI.ResolverDecision{
                          intent: %AI.TargetSearch{
                            query: "current service fault",
                            reason: "Find the affected Target using the current symptoms"
                          },
                          usage: %AI.Usage{input_tokens: 3, output_tokens: 2}
                        }}
                     end
                   }
                 )

        Cases.route_resolver_decision!(successor.id, authorize?: false)
        advanced = Cases.get_case!(incident.id, authorize?: false)
        advanced_run = Cases.get_resolution_run!(run.id, authorize?: false)
        refute advanced.pending_intent["turn_id"] == successor.id
        assert advanced.pending_intent["action"] == "resolve_turn"

        assert :ok =
                 Skopos.Cases.Turn.RecoveryReviewWorker.perform(%Oban.Job{
                   args: %{"turn_id" => turn.id}
                 })

        assert Cases.get_case!(incident.id, authorize?: false) == advanced
        assert Cases.get_resolution_run!(run.id, authorize?: false) == advanced_run
      end
    end
  end

  @tag recovered_condition_target_read_fault: true
  test "temporary recovered Condition Target read failure does not discard its recovery conclusion",
       context do
    enable_signal_automation!(context.admin)

    {incident, run, turn, _evidence} =
      recovery_conclusion!(context, "recovered-target-read",
        trigger_kind: :signal,
        recover_before_proposal: true
      )

    Cases.route_downstream_decision!(turn.id, authorize?: false)
    before_case = Cases.get_case!(incident.id, authorize?: false)
    before_run = Cases.get_resolution_run!(run.id, authorize?: false)
    before_turn = Cases.get_turn!(turn.id, authorize?: false)
    before_invocations = Cases.list_ai_invocations!(authorize?: false)

    Repo.query!("ALTER TABLE targets RENAME COLUMN facts TO unavailable_facts")

    try do
      assert {:error, _error} =
               Skopos.Cases.Turn.RecoveryReviewWorker.perform(%Oban.Job{
                 args: %{"turn_id" => turn.id},
                 attempt: 1,
                 max_attempts: 3
               })
    after
      Repo.query!("ALTER TABLE targets RENAME COLUMN unavailable_facts TO facts")
    end

    assert Cases.get_case!(incident.id, authorize?: false) == before_case
    assert Cases.get_resolution_run!(run.id, authorize?: false) == before_run
    assert Cases.get_turn!(turn.id, authorize?: false) == before_turn
    assert Cases.list_ai_invocations!(authorize?: false) == before_invocations
    approve_recovery!(turn, context)

    assert Cases.get_resolution_run!(run.id, authorize?: false).ai_usage_units ==
             before_run.ai_usage_units + 6

    assert :ok =
             Skopos.Cases.Turn.RecoveryReviewWorker.perform(%Oban.Job{
               args: %{"turn_id" => turn.id},
               attempt: 2,
               max_attempts: 3
             })

    refute_receive {:review_recovery, _, _}
    assert length(Cases.list_ai_invocations!(authorize?: false)) == length(before_invocations) + 1
  end

  @tag manual_recovery_proof_read_fault: true
  test "manual recovery proof history read failure retries before another paid Resolver call",
       context do
    setting = Cases.current_authority_setting!(actor: context.admin)

    Cases.configure_authority_setting!(
      setting.setting_revision,
      :full_access,
      setting.signal_automation_enabled,
      setting.max_elapsed_seconds,
      setting.max_resolver_turns,
      1,
      0,
      setting.max_related_targets,
      setting.max_ai_usage_units,
      setting.max_no_progress_turns,
      "Conclude from the final allowed observation",
      actor: context.admin
    )

    {incident, run, proposal} =
      authorized_proposal!("manual-proof-read", context, request_kind: :observation)

    operation = Cases.accept_operation!(proposal.id, authorize?: false)
    assert :ok = deliver_observation(operation, %{"active_state" => "active"})
    evidence = operation_evidence_record(operation.id)
    before_case = Cases.get_case!(incident.id, authorize?: false)
    turn = Cases.get_turn!(before_case.pending_intent["turn_id"], authorize?: false)
    before_run = Cases.get_resolution_run!(run.id, authorize?: false)
    before_invocations = Cases.list_ai_invocations!(authorize?: false)

    response = fn request ->
      {:ok,
       %AI.ResolverDecision{
         intent: %AI.RecoveryConclusion{
           reason: "The inspected service is active",
           evidence_ids: [evidence.id],
           desired_outcome_claims: [
             %{
               "symptom_id" => request.case_symptom.id,
               "evidence_id" => evidence.id,
               "fact_keys" => ["active_state"],
               "reason" => "The inspected service is active"
             }
           ]
         },
         usage: %AI.Usage{input_tokens: 3, output_tokens: 2}
       }}
    end

    opts = [ai_invocation: %{test_pid: self(), respond: response}]

    Repo.query!(
      "ALTER TABLE operations RENAME COLUMN outcome_category TO unavailable_outcome_category"
    )

    try do
      assert {:error, _error} = ResolverDelivery.run(turn.id, opts)
    after
      Repo.query!(
        "ALTER TABLE operations RENAME COLUMN unavailable_outcome_category TO outcome_category"
      )
    end

    refute_receive {:resolve, _, _}
    assert Cases.get_case!(incident.id, authorize?: false) == before_case
    assert Cases.get_resolution_run!(run.id, authorize?: false) == before_run
    assert Cases.get_turn!(turn.id, authorize?: false).status == :started
    assert Cases.get_turn!(turn.id, authorize?: false).revision == turn.revision
    assert Cases.list_ai_invocations!(authorize?: false) == before_invocations

    assert :ok = ResolverDelivery.run(turn.id, opts)
    assert_receive {:resolve, _, request}
    assert evidence.id in request.recovery_evidence_ids

    assert Cases.get_resolution_run!(run.id, authorize?: false).ai_usage_units ==
             before_run.ai_usage_units + 5

    assert :ok =
             Skopos.Cases.Turn.ResolverWorker.perform(%Oban.Job{args: %{"turn_id" => turn.id}})

    refute_receive {:resolve, _, _}
    assert length(Cases.list_ai_invocations!(authorize?: false)) == length(before_invocations) + 1
  end

  @tag paid_resolver_context_read_fault: true
  test "a known paid Resolver conclusion survives unavailable Condition reads after response",
       context do
    enable_signal_automation!(context.admin)

    {incident, run, proposal, _signal_provider} =
      authorized_proposal!("paid-context-read", context,
        trigger_kind: :signal,
        request_kind: :observation,
        recover_before_proposal: true
      )

    operation = Cases.accept_operation!(proposal.id, authorize?: false)
    assert :ok = deliver_observation(operation, %{"active_state" => "active"})
    evidence = operation_evidence_record(operation.id)
    before_case = Cases.get_case!(incident.id, authorize?: false)
    turn = Cases.get_turn!(before_case.pending_intent["turn_id"], authorize?: false)
    before_run = Cases.get_resolution_run!(run.id, authorize?: false)
    before_turns = Cases.list_turns!(actor: context.admin)

    try do
      assert :ok =
               ResolverDelivery.run(turn.id,
                 ai_invocation: %{
                   test_pid: self(),
                   respond: fn request ->
                     Repo.query!(
                       "ALTER TABLE conditions RENAME COLUMN subject_key TO unavailable_subject_key"
                     )

                     {:ok,
                      %AI.ResolverDecision{
                        intent: %AI.RecoveryConclusion{
                          reason: "The inspected service is active",
                          evidence_ids: [evidence.id],
                          condition_claims:
                            Enum.map(request.conditions, fn condition ->
                              %{
                                "condition_id" => condition.id,
                                "revision" => condition.revision,
                                "evidence_id" => evidence.id,
                                "reason" =>
                                  "The current observation shows the inspected service is active"
                              }
                            end)
                        },
                        usage: %AI.Usage{input_tokens: 3, output_tokens: 2}
                      }}
                   end
                 }
               )

      assert {:error, _error} =
               Skopos.Cases.Case.DecisionRouteWorker.perform(%Oban.Job{
                 args: %{"turn_id" => turn.id}
               })
    after
      Repo.query!("ALTER TABLE conditions RENAME COLUMN unavailable_subject_key TO subject_key")
    end

    assert_receive {:resolve, _, _}
    saved = Cases.get_turn!(turn.id, authorize?: false)
    assert saved.status == :completed
    assert saved.result["outcome"] == "decision"
    assert get_in(saved.result, ["intent", "type"]) == "recovery_conclusion"
    assert length(Cases.list_turns!(actor: context.admin)) == length(before_turns)

    assert Cases.get_resolution_run!(run.id, authorize?: false).ai_usage_units ==
             before_run.ai_usage_units + 5

    assert [invocation] = Cases.list_ai_invocations!(authorize?: false)
    assert invocation.status == :completed
    assert invocation.category != "context_changed"
    Cases.route_downstream_decision!(turn.id, authorize?: false)
    approve_recovery!(saved, context)

    assert :ok =
             Skopos.Cases.Turn.ResolverWorker.perform(%Oban.Job{args: %{"turn_id" => turn.id}})

    refute_receive {:resolve, _, _}
    assert length(Cases.list_ai_invocations!(authorize?: false)) == 2

    assert Cases.get_resolution_run!(run.id, authorize?: false).ai_usage_units ==
             before_run.ai_usage_units + 11
  end

  for change <- [:read_unavailable, :condition_recovered] do
    @tag metered_resolver_error_context_read_fault: true, error_context_change: change
    test "a metered Resolver schema error keeps its cause after #{change}",
         context do
      enable_signal_automation!(context.admin)

      {incident, run, proposal, signal_provider} =
        authorized_proposal!("metered-error-context-read", context,
          trigger_kind: :signal,
          request_kind: :observation
        )

      operation = Cases.accept_operation!(proposal.id, authorize?: false)
      assert :ok = deliver_observation(operation, %{"active_state" => "inactive"})
      current = Cases.get_case!(incident.id, authorize?: false)
      turn = Cases.get_turn!(current.pending_intent["turn_id"], authorize?: false)
      before_run = Cases.get_resolution_run!(run.id, authorize?: false)

      try do
        assert :ok =
                 ResolverDelivery.run(turn.id,
                   ai_invocation: %{
                     test_pid: self(),
                     respond: fn _request ->
                       case context.error_context_change do
                         :read_unavailable ->
                           Repo.query!(
                             "ALTER TABLE conditions RENAME COLUMN subject_key TO unavailable_subject_key"
                           )

                         :condition_recovered ->
                           recover_signal!(
                             signal_provider,
                             context,
                             incident.initial_context["signal_event_key"],
                             "metered-error-recovered"
                           )
                       end

                       {:error, :invalid_output, "Object schema was rejected",
                        %AI.Usage{input_tokens: 3, output_tokens: 2}, "schema_validation"}
                     end
                   }
                 )
      after
        if context.error_context_change == :read_unavailable do
          Repo.query!(
            "ALTER TABLE conditions RENAME COLUMN unavailable_subject_key TO subject_key"
          )
        end
      end

      assert_receive {:resolve, _, _}
      saved = Cases.get_turn!(turn.id, authorize?: false)
      assert saved.result["outcome"] == "delivery_failed"
      assert saved.result["category"] == "invalid_output"
      assert saved.result["rejection_code"] == "schema_validation"
      assert [invocation] = Cases.list_ai_invocations!(authorize?: false)
      assert invocation.status == :failed
      assert invocation.category == "invalid_output"
      assert invocation.input_tokens == 3
      assert invocation.output_tokens == 2

      assert Cases.get_resolution_run!(run.id, authorize?: false).ai_usage_units ==
               before_run.ai_usage_units + 5

      assert [successor] = Cases.started_turns_for_run!(run.id, authorize?: false)
      assert successor.intent["category"] == "invalid_output"
      assert successor.intent["rejection_code"] == "schema_validation"

      assert {:ok, request, _context} =
               ResolverProjection.build(
                 successor.id,
                 Providers.select_resolver_ai!(authorize?: false)
               )

      assert request.retry_context["rejection_code"] == "schema_validation"

      assert Enum.map(request.conditions, & &1.state) ==
               if(context.error_context_change == :condition_recovered,
                 do: [:recovered],
                 else: [:firing]
               )

      assert :ok =
               Skopos.Cases.Turn.ResolverWorker.perform(%Oban.Job{args: %{"turn_id" => turn.id}})

      refute_receive {:resolve, _, _}
      assert Cases.started_turns_for_run!(run.id, authorize?: false) == [successor]

      assert Cases.get_resolution_run!(run.id, authorize?: false).ai_usage_units ==
               before_run.ai_usage_units + 5
    end
  end

  test "an interrupted Recovery Reviewer is charged once and cannot approve on replay", context do
    {incident, run, turn, _evidence} =
      recovery_conclusion!(context, "interrupted-recovery-review")

    assert Cases.route_downstream_decision!(turn.id, authorize?: false).pending_intent["action"] ==
             "review_recovery"

    before_units = Cases.get_resolution_run!(run.id, authorize?: false).ai_usage_units
    parent = self()

    task =
      Task.async(fn ->
        Skopos.Cases.Turn.RecoveryReviewDelivery.run(turn.id,
          ai_invocation: %{
            test_pid: parent,
            respond: fn _request ->
              send(parent, :recovery_reviewer_remote_started)
              receive do: (:never -> :unreachable)
            end
          }
        )
      end)

    assert_receive {:review_recovery, _, _request}, 2_000
    assert_receive :recovery_reviewer_remote_started, 2_000
    assert nil == Task.shutdown(task, :brutal_kill)
    Skopos.TestAIUsage.configure!(context.reviewer_provider.id, :reviewer, 11, context.admin)

    Repo.query!("""
    CREATE FUNCTION pg_temp.reject_interrupted_recovery_successor() RETURNS trigger LANGUAGE plpgsql AS $$
    BEGIN
      IF NEW.event_type = 'turn_started' THEN
        RAISE EXCEPTION 'injected interrupted recovery successor persistence failure';
      END IF;
      RETURN NEW;
    END; $$;
    """)

    Repo.query!("""
    CREATE TRIGGER reject_interrupted_recovery_successor BEFORE INSERT ON case_events
    FOR EACH ROW EXECUTE FUNCTION pg_temp.reject_interrupted_recovery_successor();
    """)

    try do
      assert {:error, error} = Skopos.Cases.Turn.RecoveryReviewDelivery.run(turn.id)

      assert Exception.message(error) =~
               "injected interrupted recovery successor persistence failure"
    after
      Repo.query!("DROP TRIGGER reject_interrupted_recovery_successor ON case_events")
    end

    assert Cases.get_resolution_run!(run.id, authorize?: false).ai_usage_units == before_units

    assert Cases.get_case!(incident.id, authorize?: false).pending_intent ==
             %{"action" => "review_recovery", "turn_id" => turn.id}

    assert [%{status: :unknown}] =
             Cases.list_ai_invocations!(authorize?: false)
             |> Enum.filter(&(&1.role == :reviewer))

    refute_receive {:review_recovery, _, _}

    assert :ok =
             Skopos.Cases.Turn.RecoveryReviewDelivery.run(turn.id,
               ai_invocation: %{
                 test_pid: self(),
                 respond: fn _ -> flunk("interrupted review was sent again") end
               }
             )

    stopped = Cases.get_case!(incident.id, authorize?: false)
    assert stopped.status == :running
    assert stopped.pending_intent["action"] == "resolve_turn"
    refute stopped.pending_intent["turn_id"] == turn.id
    successor = Cases.get_turn!(stopped.pending_intent["turn_id"], authorize?: false)
    assert successor.intent["source"] == "recovery_review_interrupted"
    assert :ok = Skopos.Cases.Turn.RecoveryReviewDelivery.run(turn.id)

    assert Cases.get_case!(incident.id, authorize?: false).pending_intent ==
             stopped.pending_intent

    refute_receive {:review_recovery, _, _}

    snapshot = Cases.case_reconnect_snapshot!(incident.id, actor: context.operator)
    assert snapshot.ai_usage.unknown_invocations == 1
    refute snapshot.ai_usage.complete
    page = Cases.page_case_ai_invocations!(incident.id, actor: context.operator)
    [missing] = Enum.filter(page.results, &(&1.role == :reviewer))
    assert snapshot.ai_usage.unknown_reserved_units == missing.reserved_units
    assert missing.usage_status == :unknown
    assert missing.dispatch_confirmed == nil

    [reviewer] =
      Enum.filter(Cases.list_ai_invocations!(authorize?: false), fn invocation ->
        invocation.case_id == incident.id and invocation.role == :reviewer
      end)

    assert Cases.get_resolution_run!(run.id, authorize?: false).ai_usage_units ==
             before_units + reviewer.reserved_units

    refute Enum.any?(Cases.list_case_events!(actor: context.admin), fn event ->
             event.case_id == incident.id and event.event_type == "case_resolved"
           end)
  end

  test "Case admission rejects a manual recovery claim for a fact absent from current Evidence",
       context do
    {incident, _run, proposal} =
      authorized_proposal!("manual-missing-fact", context, request_kind: :observation)

    operation = Cases.accept_operation!(proposal.id, authorize?: false)

    assert :ok =
             OperationDelivery.run(operation.id,
               target_invocation:
                 invocation(
                   {:ok,
                    %Target.Observation{
                      observed_at: DateTime.utc_now(),
                      facts: %{"active_state" => "active"},
                      evidence: []
                    }}
                 )
             )

    evidence = operation_evidence_record(operation.id)
    current = Cases.get_case!(incident.id, authorize?: false)
    turn = Cases.get_turn!(current.pending_intent["turn_id"], authorize?: false)
    {:ok, revisions} = ConditionContext.current_condition_revisions(current)

    completed =
      Cases.complete_turn!(
        turn.id,
        turn.revision,
        %{
          "outcome" => "decision",
          "condition_revisions" => revisions,
          "intent" => %{
            "type" => "recovery_conclusion",
            "reason" => "The service is active",
            "evidence_ids" => [evidence.id],
            "condition_claims" => [],
            "desired_outcome_claims" => [
              %{
                "symptom_id" => Skopos.Cases.Case.Symptom.current(current).id,
                "evidence_id" => evidence.id,
                "fact_keys" => ["unobserved_state"],
                "reason" => "Claimed state"
              }
            ]
          }
        },
        :hypothesis,
        %{"action" => "route_resolver_decision", "turn_id" => turn.id},
        "Review the Resolver decision",
        authorize?: false
      ).value

    assert {:error, error} = Cases.route_downstream_decision(completed.id, authorize?: false)
    assert Exception.message(error) =~ "Case symptom claim"
    assert Cases.get_case!(incident.id, authorize?: false).status == :running
  end

  test "a resumed recovered Signal Case keeps a still-current prior-run observation eligible",
       context do
    enable_signal_automation!(context.admin)

    {incident, run, proposal, _signal_provider} =
      authorized_proposal!("resumed-recovered-observation", context,
        trigger_kind: :signal,
        request_kind: :observation,
        recover_before_proposal: true
      )

    operation = Cases.accept_operation!(proposal.id, authorize?: false)

    assert :ok =
             OperationDelivery.run(operation.id,
               target_invocation:
                 invocation(
                   {:ok,
                    %Target.Observation{
                      observed_at: DateTime.utc_now(),
                      facts: %{"unit" => "api.service", "active_state" => "active"},
                      evidence: [%{"check" => "fresh after monitoring recovery"}]
                    }}
                 )
             )

    evidence = operation_evidence_record(operation.id)
    pending = Cases.get_case!(incident.id, authorize?: false)
    current_run = Cases.get_resolution_run!(run.id, authorize?: false)

    attention =
      Cases.require_case_attention!(
        pending.id,
        pending.revision,
        current_run.id,
        current_run.revision,
        "pause-before-current-proof:#{incident.id}",
        "Interrupt Resolver after fresh observation",
        %{"action" => "retry_resolver"},
        "Resume the Case",
        authorize?: false
      )

    paused_run = Cases.get_resolution_run!(run.id, authorize?: false)

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
        "Continue with still-current symptom evidence",
        actor: context.operator
      )

    resumed_turn =
      Cases.list_turns!(actor: context.admin)
      |> Enum.find(&(&1.resolution_run_id == resumed_run.id))

    assert :ok =
             Skopos.Cases.Evidence.Citation.validate(
               evidence,
               Cases.get_case!(incident.id, authorize?: false),
               resumed_run
             )

    assert :ok =
             ResolverDelivery.run(resumed_turn.id,
               target_invocation:
                 invocation({:ok, %Target.Capabilities{observations: [], effects: []}}),
               ai_invocation: %{
                 test_pid: self(),
                 respond: fn request ->
                   assert AI.recovery_evidence_ids(request) == [evidence.id]
                   assert Enum.any?(request.evidence, &(&1.id == evidence.id))
                   refute Enum.any?(request.historical_evidence, &(&1.id == evidence.id))
                   [condition] = request.conditions

                   {:ok,
                    %AI.ResolverDecision{
                      intent: %AI.RecoveryConclusion{
                        reason: "The native symptom cleared and the selected service is active",
                        evidence_ids: [evidence.id],
                        condition_claims: [
                          %{
                            "condition_id" => condition.id,
                            "revision" => condition.revision,
                            "evidence_id" => evidence.id,
                            "reason" => "The observed service is active after source recovery"
                          }
                        ]
                      },
                      usage: %AI.Usage{input_tokens: 3, output_tokens: 2}
                    }}
                 end
               }
             )

    completed = Cases.get_turn!(resumed_turn.id, authorize?: false)
    assert Cases.route_downstream_decision!(completed.id, authorize?: false).status == :running
    approve_recovery!(completed, context)
    assert Cases.get_case!(incident.id, authorize?: false).status == :resolved
  end

  test "a resumed Signal Case can cite current prior-run observation to request a fresh observation",
       context do
    enable_signal_automation!(context.admin)

    {incident, run, proposal, _signal_provider} =
      authorized_proposal!("resumed-observation-citation", context,
        trigger_kind: :signal,
        request_kind: :observation,
        recover_before_proposal: true
      )

    operation = Cases.accept_operation!(proposal.id, authorize?: false)

    assert :ok =
             OperationDelivery.run(operation.id,
               target_invocation:
                 invocation(
                   {:ok,
                    %Target.Observation{
                      observed_at: DateTime.utc_now(),
                      facts: %{"unit" => "api.service", "active_state" => "active"},
                      evidence: [%{"check" => "current source symptom"}]
                    }}
                 )
             )

    evidence = operation_evidence_record(operation.id)
    current = Cases.get_case!(incident.id, authorize?: false)
    current_run = Cases.get_resolution_run!(run.id, authorize?: false)

    attention =
      Cases.require_case_attention!(
        current.id,
        current.revision,
        current_run.id,
        current_run.revision,
        "pause-before-new-observation:#{incident.id}",
        "Continue direct observation after resume",
        %{"action" => "retry_resolver"},
        "Resume the Case",
        authorize?: false
      )

    paused_run = Cases.get_resolution_run!(run.id, authorize?: false)

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
        "Request a fresh symptom observation",
        actor: context.operator
      )

    resumed_turn =
      Cases.list_turns!(actor: context.admin)
      |> Enum.find(&(&1.resolution_run_id == resumed_run.id))

    intent = signal_proposal_intent(evidence.id, context, :observation)
    routed = complete_signal_proposal!(resumed_turn, intent, incident, context)

    assert routed.evidence_ids == [evidence.id]
    assert routed.resolution_run_id == resumed_run.id
    assert Cases.get_case!(incident.id, authorize?: false).status == :running
  end

  test "a Reviewer rejection of unrelated observation facts keeps recovered Signal Conditions open",
       context do
    enable_signal_automation!(context.admin)

    {incident, run, proposal, _signal_provider} =
      authorized_proposal!("unrelated-recovery-proof", context,
        trigger_kind: :signal,
        request_kind: :observation,
        recover_before_proposal: true
      )

    operation = Cases.accept_operation!(proposal.id, authorize?: false)

    assert :ok =
             OperationDelivery.run(operation.id,
               target_invocation:
                 invocation(
                   {:ok,
                    %Target.Observation{
                      observed_at: DateTime.utc_now(),
                      facts: %{"machine_id" => "unrelated-machine", "kernel" => "6.8"},
                      evidence: [%{"check" => "host identity only"}]
                    }}
                 )
             )

    evidence = operation_evidence_record(operation.id)
    pending = Cases.get_case!(incident.id, authorize?: false).pending_intent
    turn = Cases.get_turn!(pending["turn_id"], authorize?: false)

    assert :ok =
             ResolverDelivery.run(turn.id,
               target_invocation:
                 invocation({:ok, %Target.Capabilities{observations: [], effects: []}}),
               ai_invocation: %{
                 test_pid: self(),
                 respond: fn request ->
                   [condition] = request.conditions

                   {:ok,
                    %AI.ResolverDecision{
                      intent: %AI.RecoveryConclusion{
                        reason: "Machine identity proves service recovered",
                        evidence_ids: [evidence.id],
                        condition_claims: [
                          %{
                            "condition_id" => condition.id,
                            "revision" => condition.revision,
                            "evidence_id" => evidence.id,
                            "reason" => "Machine identity proves service is running"
                          }
                        ]
                      },
                      usage: %AI.Usage{input_tokens: 3, output_tokens: 2}
                    }}
                 end
               }
             )

    completed = Cases.get_turn!(turn.id, authorize?: false)
    requested = Cases.route_downstream_decision!(completed.id, authorize?: false)
    assert requested.status == :running
    assert requested.pending_intent["action"] == "review_recovery"

    assert :ok =
             Skopos.Cases.Turn.RecoveryReviewDelivery.run(completed.id,
               ai_invocation: %{
                 test_pid: self(),
                 respond: fn request ->
                   assert [%AI.Evidence{content: %{"facts" => facts}}] =
                            request.cited_evidence

                   assert facts["machine_id"] == "unrelated-machine"

                   {:ok,
                    %AI.ReviewDecision{
                      purpose_assessment: :remediation,
                      verdict: :rejected,
                      reason: "Machine identity does not establish service availability",
                      usage: %AI.Usage{input_tokens: 4, output_tokens: 2}
                    }}
                 end
               }
             )

    assert_receive {:review_recovery, %{model: "reviewer-model"}, _request}
    current = Cases.get_case!(incident.id, authorize?: false)
    assert current.status == :running
    assert current.pending_intent["action"] == "resolve_turn"
    assert Cases.get_resolution_run!(run.id, authorize?: false).status == :running

    refute Enum.any?(
             Cases.list_case_events!(actor: context.admin),
             &(&1.case_id == incident.id and &1.event_type == "case_resolved")
           )

    assert :ok = Skopos.Cases.Turn.RecoveryReviewDelivery.run(completed.id)

    assert Cases.get_case!(incident.id, authorize?: false).pending_intent ==
             current.pending_intent

    Cases.append_evidence!(
      incident.id,
      run.id,
      nil,
      "uncited-identity-after-rejection:#{incident.id}",
      "observation",
      "fixture",
      "uncited-identity:#{incident.id}",
      %{
        "target_id" => context.target.id,
        "operation" => "linux.identity.inspect",
        "status" => "applied",
        "facts" => %{"kernel" => "Linux"}
      },
      DateTime.utc_now(),
      authorize?: false
    )

    retry_turn = Cases.get_turn!(current.pending_intent["turn_id"], authorize?: false)

    assert :ok =
             ResolverDelivery.run(retry_turn.id,
               target_invocation:
                 invocation({:ok, %Target.Capabilities{observations: [], effects: []}}),
               ai_invocation: %{
                 test_pid: self(),
                 respond: fn request ->
                   assert %{
                            "last_rejected_recovery_review" => %{
                              "verdict" => "rejected",
                              "evidence_ids" => [rejected_id],
                              "reason" => review_reason
                            }
                          } = Jason.decode!(request.objective)

                   assert rejected_id == evidence.id
                   assert review_reason =~ "Machine identity does not establish"
                   [condition] = request.conditions

                   {:ok,
                    %AI.ResolverDecision{
                      intent: %AI.RecoveryConclusion{
                        reason: "The same machine identity appears to show recovery",
                        evidence_ids: [evidence.id],
                        condition_claims: [
                          %{
                            "condition_id" => condition.id,
                            "revision" => condition.revision,
                            "evidence_id" => evidence.id,
                            "reason" => "The same identity observation is cited"
                          }
                        ]
                      },
                      usage: %AI.Usage{input_tokens: 3, output_tokens: 2}
                    }}
                 end
               }
             )

    retried = Cases.get_turn!(retry_turn.id, authorize?: false)

    assert retried.result["outcome"] == "decision",
           inspect(Map.take(retried.result, ["outcome", "category", "message", "reason"]))

    stopped = Cases.route_downstream_decision!(retry_turn.id, authorize?: false)
    assert stopped.status == :needs_attention
    assert stopped.stop_reason == "Recovery Review rejected this unchanged evidence"

    assert Enum.count(Cases.list_case_events!(actor: context.admin), fn event ->
             event.case_id == incident.id and event.event_type == "recovery_review_decided"
           end) == 1

    paused_run = Cases.get_resolution_run!(run.id, authorize?: false)

    resumed_run =
      Cases.resume_case!(
        stopped.id,
        stopped.revision,
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
        "Continue investigation with Reviewer feedback",
        actor: context.operator
      )

    resumed_turn =
      Cases.list_turns!(actor: context.admin)
      |> Enum.find(&(&1.resolution_run_id == resumed_run.id))

    assert {:ok, request, _context} =
             ResolverProjection.build(resumed_turn.id, %AI.Selection{
               role: :resolver,
               provider_id: context.resolver_provider.id,
               provider_revision: context.resolver_provider.revision,
               source: :assignment
             })

    assert get_in(Jason.decode!(request.objective), [
             "last_rejected_recovery_review",
             "evidence_ids"
           ]) == [evidence.id]

    source = hd(Cases.signal_context_evidence!(incident.id, authorize?: false))

    proposal =
      complete_signal_proposal!(
        resumed_turn,
        signal_proposal_intent(source.id, context, :observation),
        incident,
        context
      )

    observation = Cases.accept_operation!(proposal.id, authorize?: false)

    assert :ok =
             deliver_observation(observation, %{
               "unit" => "api.service",
               "active_state" => "active"
             })

    fresh = operation_evidence_record(observation.id)
    pending = Cases.get_case!(incident.id, authorize?: false).pending_intent
    fresh_turn = Cases.get_turn!(pending["turn_id"], authorize?: false)

    assert :ok =
             ResolverDelivery.run(fresh_turn.id,
               target_invocation:
                 invocation({:ok, %Target.Capabilities{observations: [], effects: []}}),
               ai_invocation: %{
                 test_pid: self(),
                 respond: fn request ->
                   assert fresh.id in request.recovery_evidence_ids
                   [condition] = request.conditions

                   {:ok,
                    %AI.ResolverDecision{
                      intent: %AI.RecoveryConclusion{
                        reason: "The service is active in a fresh direct observation",
                        evidence_ids: [fresh.id],
                        condition_claims: [
                          %{
                            "condition_id" => condition.id,
                            "revision" => condition.revision,
                            "evidence_id" => fresh.id,
                            "reason" => "The inspected service is active"
                          }
                        ]
                      },
                      usage: %AI.Usage{input_tokens: 3, output_tokens: 2}
                    }}
                 end
               }
             )

    assert Cases.route_downstream_decision!(fresh_turn.id, authorize?: false).pending_intent[
             "action"
           ] == "review_recovery"

    approve_recovery!(fresh_turn, context)

    assert Enum.count(Cases.list_case_events!(actor: context.admin), fn event ->
             event.case_id == incident.id and event.event_type == "recovery_review_decided"
           end) == 2
  end

  test "a missing recovery Reviewer stops a manual Case without claiming resolution", context do
    {incident, run, proposal} =
      authorized_proposal!("missing-recovery-reviewer", context, request_kind: :observation)

    operation = Cases.accept_operation!(proposal.id, authorize?: false)

    assert :ok =
             OperationDelivery.run(operation.id,
               target_invocation:
                 invocation(
                   {:ok,
                    %Target.Observation{
                      observed_at: DateTime.utc_now(),
                      facts: %{"unit" => "api.service", "active_state" => "active"},
                      evidence: [%{"check" => "current"}]
                    }}
                 )
             )

    evidence = operation_evidence_record(operation.id)
    pending = Cases.get_case!(incident.id, authorize?: false).pending_intent
    turn = Cases.get_turn!(pending["turn_id"], authorize?: false)

    assert :ok =
             ResolverDelivery.run(turn.id,
               target_invocation:
                 invocation({:ok, %Target.Capabilities{observations: [], effects: []}}),
               ai_invocation: %{
                 test_pid: self(),
                 respond: fn request ->
                   {:ok,
                    %AI.ResolverDecision{
                      intent: %AI.RecoveryConclusion{
                        reason: "The current service is active",
                        evidence_ids: [evidence.id],
                        desired_outcome_claims: [
                          %{
                            "symptom_id" => request.case_symptom.id,
                            "evidence_id" => evidence.id,
                            "fact_keys" => ["active_state"],
                            "reason" => "The inspected service is active"
                          }
                        ]
                      },
                      usage: %AI.Usage{input_tokens: 3, output_tokens: 2}
                    }}
                 end
               }
             )

    assert Cases.route_downstream_decision!(turn.id, authorize?: false).pending_intent ==
             %{"action" => "review_recovery", "turn_id" => turn.id}

    Providers.disable_provider!(
      context.reviewer_provider,
      context.reviewer_provider.revision,
      actor: context.admin
    )

    assert :ok = Skopos.Cases.Turn.RecoveryReviewDelivery.run(turn.id)
    stopped = Cases.get_case!(incident.id, authorize?: false)
    assert stopped.status == :needs_attention
    assert stopped.pending_intent == %{"action" => "review_recovery", "turn_id" => turn.id}
    assert Cases.get_resolution_run!(run.id, authorize?: false).status == :needs_attention

    refute Enum.any?(
             Cases.list_case_events!(actor: context.admin),
             &(&1.case_id == incident.id and &1.event_type == "case_resolved")
           )
  end

  test "a new firing Condition invalidates a pending recovery review", context do
    enable_signal_automation!(context.admin)

    {incident, run, proposal, signal_provider} =
      authorized_proposal!("stale-recovery-review", context,
        trigger_kind: :signal,
        request_kind: :observation,
        recover_before_proposal: true
      )

    operation = Cases.accept_operation!(proposal.id, authorize?: false)

    assert :ok =
             OperationDelivery.run(operation.id,
               target_invocation:
                 invocation(
                   {:ok,
                    %Target.Observation{
                      observed_at: DateTime.utc_now(),
                      facts: %{"unit" => "api.service", "active_state" => "active"},
                      evidence: [%{"check" => "before refire"}]
                    }}
                 )
             )

    evidence = operation_evidence_record(operation.id)
    pending = Cases.get_case!(incident.id, authorize?: false).pending_intent
    turn = Cases.get_turn!(pending["turn_id"], authorize?: false)

    assert :ok =
             ResolverDelivery.run(turn.id,
               target_invocation:
                 invocation({:ok, %Target.Capabilities{observations: [], effects: []}}),
               ai_invocation: %{
                 test_pid: self(),
                 respond: fn request ->
                   [condition] = request.conditions

                   {:ok,
                    %AI.ResolverDecision{
                      intent: %AI.RecoveryConclusion{
                        reason: "The service was active at the prior observation",
                        evidence_ids: [evidence.id],
                        condition_claims: [
                          %{
                            "condition_id" => condition.id,
                            "revision" => condition.revision,
                            "evidence_id" => evidence.id,
                            "reason" => "The prior service inspection was active"
                          }
                        ]
                      },
                      usage: %AI.Usage{input_tokens: 3, output_tokens: 2}
                    }}
                 end
               }
             )

    assert Cases.route_downstream_decision!(turn.id, authorize?: false).pending_intent ==
             %{"action" => "review_recovery", "turn_id" => turn.id}

    fire_signal!(
      signal_provider,
      context,
      incident.initial_context["signal_event_key"],
      "refired-before-recovery-review",
      DateTime.add(DateTime.utc_now(), 1, :second)
    )

    assert :ok = Skopos.Cases.Turn.RecoveryReviewDelivery.run(turn.id)
    current = Cases.get_case!(incident.id, authorize?: false)
    assert current.status == :needs_attention
    assert Cases.get_resolution_run!(run.id, authorize?: false).status == :needs_attention

    refute Enum.any?(
             Cases.list_case_events!(actor: context.admin),
             &(&1.case_id == incident.id and
                 &1.event_type in ["recovery_review_decided", "case_resolved"])
           )
  end

  @tag late_continuity_read_fault: true
  test "a resumed Case retries unreadable verified continuity without losing it",
       context do
    enable_signal_automation!(context.admin)

    {incident, run, proposal, signal_provider} =
      authorized_proposal!("resume-investigation", context, trigger_kind: :signal)

    event_key = incident.initial_context["signal_event_key"]

    recover_signal!(
      signal_provider,
      context,
      event_key,
      "resume-investigation-stale-source",
      DateTime.add(DateTime.utc_now(), -60, :second)
    )

    signal_event!(
      signal_provider,
      context,
      event_key,
      "resume-investigation-current-source",
      :firing,
      DateTime.utc_now(),
      %{
        "labels" => %{"service" => "api.service", "alertname" => "ServiceUnavailable"},
        "annotations" => %{"description" => "Restore the service to running"}
      }
    )

    [source] = Cases.signal_context_evidence!(incident.id, authorize?: false)

    assert {:error, stale} = Cases.accept_operation(proposal.id, authorize?: false)
    assert Exception.message(stale) =~ "Conditions changed"
    assert Cases.get_proposal!(proposal.id, authorize?: false).status == :invalidated
    assert Cases.get_resolution_run!(run.id, authorize?: false).effect_count == 0

    [reassessment] = Cases.started_turns_for_run!(run.id, authorize?: false)
    {:ok, revisions} = ConditionContext.current_condition_revisions(incident)

    replacement =
      Cases.complete_turn!(
        reassessment.id,
        reassessment.revision,
        %{
          "outcome" => "decision",
          "intent" =>
            Map.put(
              signal_proposal_intent(source.id, context),
              "affected_conditions",
              Enum.map(revisions, fn %{"id" => id, "revision" => revision} ->
                %{"condition_id" => id, "revision" => revision}
              end)
            ),
          "condition_revisions" => revisions,
          "resolver" => %{
            "provider_id" => context.resolver_provider.id,
            "provider_revision" => context.resolver_provider.revision,
            "assignment_id" => context.resolver_assignment.id,
            "assignment_revision" => context.resolver_assignment.revision
          },
          "usage" => %{"input_tokens" => 1, "output_tokens" => 1}
        },
        :proposal,
        %{"action" => "route_resolver_decision", "turn_id" => reassessment.id},
        "Review the Resolver decision",
        authorize?: false
      ).value

    Cases.route_downstream_decision!(replacement.id, authorize?: false)
    authorized = Cases.proposal_by_source_turn!(replacement.id, authorize?: false)

    operation = Cases.accept_operation!(authorized.id, authorize?: false)

    assert :ok =
             OperationDelivery.run(operation.id,
               target_invocation: invocation({:ok, %Target.EffectResult{status: :applied}})
             )

    attempt = Cases.verification_attempt_by_operation!(operation.id, authorize?: false)

    assert :ok =
             VerificationDelivery.run(attempt.id,
               target_invocation:
                 invocation(
                   {:ok, verified_result(%{"unit" => "api.service", "active_state" => "active"})}
                 )
             )

    pending_case = Cases.get_case!(incident.id, authorize?: false)
    verification_id = pending_case.pending_intent["verification_evidence_id"]
    current_run = Cases.get_resolution_run!(run.id, authorize?: false)

    attention =
      Cases.require_case_attention!(
        pending_case.id,
        pending_case.revision,
        current_run.id,
        current_run.revision,
        "resume-firing-after-verification",
        "Resolver delivery failed after verification",
        %{"action" => "retry_resolver"},
        "Resume the Case",
        authorize?: false
      )

    paused_run = Cases.get_resolution_run!(run.id, authorize?: false)

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
        "Continue investigation after verified Target progress",
        actor: context.operator
      )

    resumed_turn =
      Cases.list_turns!(actor: context.admin)
      |> Enum.find(&(&1.resolution_run_id == resumed_run.id))

    capabilities = %Target.Capabilities{
      observations: [
        %Target.Operation{
          capability: "observe.service",
          operation: "service.inspect",
          description: "Inspect service state",
          input_schema: %{
            "type" => "object",
            "properties" => %{
              "selectors" => %{"type" => "object"},
              "parameters" => %{"type" => "object"}
            },
            "required" => ["selectors", "parameters"]
          },
          output_schema: %{"type" => "object"},
          verification_schema: %{"type" => "object"}
        }
      ],
      effects: []
    }

    current_method = Targets.get_access_method!(context.method.id, actor: context.admin)

    Targets.check_access_method!(
      current_method.id,
      current_method.revision,
      %{respond: fn -> {:ok, capabilities} end},
      actor: context.admin
    )

    selection = %AI.Selection{
      role: :resolver,
      provider_id: context.resolver_provider.id,
      provider_revision: context.resolver_provider.revision,
      source: :assignment
    }

    assert {:ok, baseline, _context} = ResolverProjection.build(resumed_turn.id, selection)
    assert Enum.any?(baseline.evidence, &(&1.id == verification_id))
    before_case = Cases.get_case!(incident.id, authorize?: false)
    before_run = Cases.get_resolution_run!(resumed_run.id, authorize?: false)
    before_turn = Cases.get_turn!(resumed_turn.id, authorize?: false)
    before_invocations = Cases.list_ai_invocations!(authorize?: false)

    with_projection_read_fault("operations", "revision", "bigint", operation.id, fn ->
      assert {:error, %Ash.Error.Unknown{} = error} =
               Cases.get_operation(operation.id, authorize?: false)

      assert Exception.message(error) =~ "Projection record temporarily unavailable"
      assert {:error, %Ash.Error.Unknown{}} = ResolverProjection.build(resumed_turn.id, selection)

      assert {:error, %Ash.Error.Unknown{}} =
               Skopos.Cases.Turn.ResolverWorker.perform(%Oban.Job{
                 args: %{"turn_id" => resumed_turn.id}
               })

      assert Cases.list_ai_invocations!(authorize?: false) == before_invocations
    end)

    assert Cases.get_case!(incident.id, authorize?: false) == before_case
    assert Cases.get_resolution_run!(resumed_run.id, authorize?: false) == before_run
    assert Cases.get_turn!(resumed_turn.id, authorize?: false) == before_turn

    assert {:ok, request, _context} =
             ResolverProjection.build(resumed_turn.id, %AI.Selection{
               role: :resolver,
               provider_id: context.resolver_provider.id,
               provider_revision: context.resolver_provider.revision,
               source: :assignment
             })

    assert request.alert_state == :firing

    assert [
             %AI.Evidence{id: source_id, kind: "signal_event", content: source_content},
             %AI.Evidence{id: ^verification_id, kind: "target_verification"}
           ] = request.evidence

    assert source_id == source.id
    refute Enum.any?(request.evidence, &(&1.content["state"] == "recovered"))
    assert Enum.any?(request.historical_evidence, &(&1.kind == "operation_outcome"))
    refute Enum.any?(request.historical_evidence, &(&1.id == verification_id))

    assert get_in(source_content, ["attributes", "annotations", "description"]) ==
             "Restore the service to running"

    assert [%AI.ProposalTool{request_kind: :observation}] = request.proposal_tools
    assert [%AI.ObservationTool{operation: "service.inspect"}] = request.observation_tools

    assert :ok =
             ResolverDelivery.run(resumed_turn.id,
               ai_invocation: %{
                 test_pid: self(),
                 respond: fn request ->
                   assert Enum.any?(request.evidence, &(&1.id == verification_id))

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
             Skopos.Cases.Turn.ResolverWorker.perform(%Oban.Job{
               args: %{"turn_id" => resumed_turn.id}
             })

    refute_receive {:resolve, _, _}

    assert Cases.get_resolution_run!(resumed_run.id, authorize?: false).ai_usage_units ==
             before_run.ai_usage_units + 12

    assert length(Cases.list_ai_invocations!(authorize?: false)) == length(before_invocations) + 1
  end

  test "remaining symptoms create a new Proposal without replaying the prior Operation",
       context do
    {incident, run, proposal} = authorized_proposal!("compound-cause", context)
    first_operation = Cases.accept_operation!(proposal.id, authorize?: false)

    assert :ok =
             OperationDelivery.run(first_operation.id,
               target_invocation: invocation({:ok, %Target.EffectResult{status: :applied}})
             )

    assert_receive {:effect, _, _}
    attempt = Cases.verification_attempt_by_operation!(first_operation.id, authorize?: false)

    assert :ok =
             VerificationDelivery.run(attempt.id,
               target_invocation:
                 invocation(
                   {:ok,
                    %Target.Verification{
                      status: :not_verified,
                      observed_at: DateTime.utc_now(),
                      facts: %{"service" => "degraded"}
                    }}
                 )
             )

    assert_receive {:verify, _, _}
    pending = Cases.get_case!(incident.id, authorize?: false).pending_intent
    turn = Cases.get_turn!(pending["turn_id"], authorize?: false)

    completed =
      Cases.complete_turn!(
        turn.id,
        turn.revision,
        %{
          "outcome" => "decision",
          "intent" => proposal_intent(pending["verification_evidence_id"], context),
          "resolver" => %{
            "provider_id" => context.resolver_provider.id,
            "provider_revision" => context.resolver_provider.revision,
            "assignment_id" => context.resolver_assignment.id,
            "assignment_revision" => context.resolver_assignment.revision
          },
          "usage" => %{"input_tokens" => 1, "output_tokens" => 1}
        },
        :proposal,
        %{"action" => "route_resolver_decision", "turn_id" => turn.id},
        "Review the Resolver decision",
        authorize?: false
      ).value

    routed = Cases.route_downstream_decision!(completed.id, authorize?: false)
    second_proposal_id = routed.pending_intent["proposal_id"]
    second_proposal = Cases.get_proposal!(second_proposal_id, authorize?: false)
    second_operation = Cases.accept_operation!(second_proposal.id, authorize?: false)

    assert second_operation.id != first_operation.id
    assert Cases.get_operation!(first_operation.id, authorize?: false).status == :applied
    assert Cases.get_resolution_run!(run.id, authorize?: false).effect_count == 2

    assert :ok =
             OperationDelivery.run(first_operation.id,
               target_invocation: invocation(fn -> flunk("prior effect was replayed") end)
             )

    assert :ok =
             VerificationDelivery.run(attempt.id,
               target_invocation: invocation(fn -> flunk("prior verification was replayed") end)
             )

    refute_receive {:effect, _, _}
    refute_receive {:verify, _, _}
  end

  defp complete_signal_proposal!(turn, intent, incident, context) do
    {:ok, revisions} = ConditionContext.current_condition_revisions(incident)

    completed =
      Cases.complete_turn!(
        turn.id,
        turn.revision,
        %{
          "outcome" => "decision",
          "condition_revisions" => revisions,
          "intent" => intent,
          "resolver" => %{
            "provider_id" => context.resolver_provider.id,
            "provider_revision" => context.resolver_provider.revision,
            "assignment_id" => context.resolver_assignment.id,
            "assignment_revision" => context.resolver_assignment.revision
          },
          "usage" => %{"input_tokens" => 1, "output_tokens" => 1}
        },
        :proposal,
        %{"action" => "route_resolver_decision", "turn_id" => turn.id},
        "Review the Resolver decision",
        authorize?: false
      ).value

    Cases.route_downstream_decision!(completed.id, authorize?: false)
    Cases.proposal_by_source_turn!(completed.id, authorize?: false)
  end

  defp deliver_observation(operation, facts, state_facts \\ nil) do
    OperationDelivery.run(operation.id,
      target_invocation:
        invocation({
          :ok,
          %Target.Observation{
            facts: facts,
            state_facts: state_facts,
            observed_at: DateTime.utc_now()
          }
        })
    )
  end

  defp continue_observation!(incident, context, prior_operation_id) do
    evidence = operation_evidence_record(prior_operation_id)
    pending = Cases.get_case!(incident.id, authorize?: false).pending_intent
    turn = Cases.get_turn!(pending["turn_id"], authorize?: false)

    result = %{
      "outcome" => "decision",
      "intent" => proposal_intent(evidence.id, context, :observation),
      "resolver" => %{
        "provider_id" => context.resolver_provider.id,
        "provider_revision" => context.resolver_provider.revision,
        "assignment_id" => context.resolver_assignment.id,
        "assignment_revision" => context.resolver_assignment.revision
      },
      "usage" => %{"input_tokens" => 1, "output_tokens" => 1}
    }

    completed =
      Cases.complete_turn!(
        turn.id,
        turn.revision,
        result,
        :observation_pending,
        %{"action" => "route_resolver_decision", "turn_id" => turn.id},
        "Review the Resolver decision",
        authorize?: false
      ).value

    Cases.route_downstream_decision!(completed.id, authorize?: false)
    proposal = Cases.proposal_by_source_turn!(completed.id, authorize?: false)
    Cases.accept_operation!(proposal.id, authorize?: false)
  end

  # Undispatched capacity fixtures use internal Ash record actions, not 101 native requests.
  defp append_investigation_history!(operation, count) do
    proposal = Cases.get_proposal!(operation.proposal_id, authorize?: false)
    turn = Cases.get_turn!(proposal.source_turn_id, authorize?: false)

    copy_inputs = fn record ->
      Map.take(record, Ash.Resource.Info.action(record.__struct__, :create_record).accept)
      |> Map.drop([:id])
    end

    for index <- 1..count do
      key = "investigation-history:#{operation.id}:#{index}"

      next_turn =
        Cases.create_turn_record!(
          Map.merge(copy_inputs.(turn), %{
            ordinal: turn.ordinal + index + 100,
            idempotency_key: key
          }),
          authorize?: false
        )

      next_proposal =
        Cases.create_proposal_record!(
          Map.merge(copy_inputs.(proposal), %{
            source_turn_id: next_turn.id,
            purpose: :investigation,
            reserved_operation_id: Ecto.UUID.generate(),
            operation_idempotency_key: key
          }),
          authorize?: false
        )

      next_operation =
        Cases.create_operation_record!(
          Map.merge(copy_inputs.(operation), %{
            id: next_proposal.reserved_operation_id,
            proposal_id: next_proposal.id,
            purpose: :investigation,
            idempotency_key: key
          }),
          authorize?: false
        )

      Cases.record_operation_no_send!(
        next_operation.id,
        next_operation.revision,
        %{
          outcome_category: "cancelled",
          completed_at: DateTime.utc_now()
        },
        authorize?: false
      )
    end
  end

  # Window and assessment scans remain readable; only the later primary-ID read fails.
  defp with_projection_read_fault(table, column, type, id, run) do
    columns =
      Repo.query!(
        "SELECT attname FROM pg_attribute WHERE attrelid = '#{table}'::regclass AND attnum > 0 AND NOT attisdropped ORDER BY attnum"
      ).rows
      |> List.flatten()

    Repo.query!("""
    CREATE FUNCTION pg_temp.projection_read_fault(#{type}) RETURNS #{type}
    LANGUAGE plpgsql STABLE AS $$ BEGIN
      IF strpos(split_part(current_query(), ' WHERE ', 2), '"id"') > 0
         AND strpos(split_part(current_query(), ' WHERE ', 2), '"case_id"') = 0 THEN
        RAISE EXCEPTION 'Projection record temporarily unavailable';
      END IF;
      RETURN $1;
    END $$
    """)

    Repo.query!("ALTER TABLE #{table} RENAME TO #{table}_projection_source")

    fields =
      Enum.map_join(columns, ", ", fn
        ^column ->
          "CASE WHEN id = '#{id}'::uuid THEN pg_temp.projection_read_fault(#{column}) ELSE #{column} END AS #{column}"

        name ->
          "\"#{name}\""
      end)

    Repo.query!("CREATE VIEW #{table} AS SELECT #{fields} FROM #{table}_projection_source")

    try do
      run.()
    after
      Repo.query!("DROP VIEW #{table}")
      Repo.query!("ALTER TABLE #{table}_projection_source RENAME TO #{table}")
      Repo.query!("DROP FUNCTION pg_temp.projection_read_fault(#{type})")
    end
  end

  defp native_reviewer!(context) do
    peer = start_supervised!({Agent, fn -> %{mode: {:decision, %{}}, requests: []} end})

    server =
      start_supervised!({Bandit, plug: {Skopos.AIHTTPFixture, peer}, port: 0, startup_log: false})

    {:ok, {_address, port}} = ThousandIsland.listener_info(server)

    Providers.disable_provider!(context.reviewer_provider, context.reviewer_provider.revision,
      actor: context.admin
    )

    provider =
      Providers.create_provider!(
        "native-reviewer",
        :ai,
        "req-llm",
        %{
          "provider" => "openai",
          "model" => "test-model",
          "endpoint" => "http://127.0.0.1:#{port}/v1"
        },
        %{"api_key" => "native-reviewer-fixture-secret"},
        actor: context.admin
      )
      |> then(&Providers.check_provider!(&1.id, 1, %{}, actor: context.admin))
      |> then(&Providers.enable_provider!(&1, 1, actor: context.admin))

    Skopos.TestAIUsage.configure!(provider.id, :reviewer, 10, context.admin)
    current = Cases.current_authority_setting!(actor: context.admin)

    Cases.configure_authority_setting!(
      current.setting_revision,
      current.authority_mode,
      current.signal_automation_enabled,
      current.max_elapsed_seconds,
      current.max_resolver_turns,
      current.max_target_requests,
      current.max_effects,
      current.max_related_targets,
      100_000,
      current.max_no_progress_turns,
      "Allow bounded native Reviewer cancellation",
      actor: context.admin
    )

    {%{context | reviewer_provider: provider}, peer}
  end

  defp authorized_proposal!(suffix, context, opts \\ []) do
    trigger_kind = Keyword.get(opts, :trigger_kind, :manual)
    request_kind = Keyword.get(opts, :request_kind, :effect)
    proposal_context = Map.put(context, :service, Keyword.get(opts, :service, "api"))

    {incident, signal_provider} =
      if trigger_kind == :signal do
        signal_case!(suffix, context, opts)
      else
        {Cases.open_case!(
           trigger_kind,
           "test",
           "operation-#{suffix}",
           "Operation #{suffix}",
           :warning,
           %{"desired_outcome" => "Target responds as expected"},
           context.target.id,
           :en,
           actor: context.operator
         ), nil}
      end

    run = Cases.active_resolution_run!(incident.id, authorize?: false)

    evidence =
      Cases.append_evidence!(
        incident.id,
        run.id,
        nil,
        "operation-evidence-#{suffix}",
        "observation",
        "fixture",
        "observation-#{suffix}",
        %{"service" => "unhealthy"},
        DateTime.utc_now(),
        authorize?: false
      )

    started =
      if trigger_kind == :signal do
        assert :ok = CaseDispatchWorker.perform(%Oban.Job{args: %{"case_id" => incident.id}})
        %{value: Enum.find(Cases.list_turns!(actor: context.admin), &(&1.case_id == incident.id))}
      else
        Cases.start_turn!(
          incident.id,
          run.id,
          "operation-turn-#{suffix}",
          Keyword.get(opts, :turn_intent, %{"objective" => "Restore the service"}),
          %{"action" => "continue"},
          "Review Resolver limits",
          authorize?: false
        )
      end

    if trigger_kind == :signal and Keyword.get(opts, :recover_before_proposal, false) do
      recover_signal!(
        signal_provider,
        context,
        incident.initial_context["signal_event_key"],
        "recovered-before-#{suffix}"
      )
    end

    result =
      %{
        "outcome" => "decision",
        "intent" =>
          if(trigger_kind == :signal,
            do: signal_proposal_intent(evidence.id, proposal_context, request_kind),
            else: proposal_intent(evidence.id, proposal_context, request_kind)
          ),
        "resolver" => %{
          "provider_id" => context.resolver_provider.id,
          "provider_revision" => context.resolver_provider.revision,
          "assignment_id" => context.resolver_assignment.id,
          "assignment_revision" => context.resolver_assignment.revision
        },
        "usage" => %{"input_tokens" => 1, "output_tokens" => 1}
      }

    result =
      if Keyword.get(opts, :purpose) == :investigation and request_kind == :effect do
        intent = result["intent"]
        tool = %{intent["tool"] | "operation" => "command.execute"}

        intent =
          intent
          |> Map.put("purpose", "investigation")
          |> Map.put("operation", "command.execute")
          |> Map.put("tool", tool)
          |> Map.put("parameters", %{"command" => "service nginx status"})
          |> Map.put("expected_result", %{})
          |> Map.put("verification_intent", %{})
          |> Map.put("verification_tool", %{})

        Map.put(result, "intent", intent)
      else
        result
      end

    result =
      if Keyword.get(opts, :defer_verification, false) do
        intent = result["intent"]

        tool =
          intent["tool"]
          |> Map.put("capability", "effect.command")
          |> Map.put("operation", "command.execute")

        intent =
          intent
          |> Map.put("tool", tool)
          |> Map.put("capability", "effect.command")
          |> Map.put("operation", "command.execute")
          |> Map.put("selectors", %{})
          |> Map.put("parameters", %{"command" => "systemctl start api.service"})
          |> Map.put("verification_intent", %{})
          |> Map.put("verification_tool", %{})

        Map.put(result, "intent", intent)
      else
        result
      end

    result =
      if trigger_kind == :signal do
        {:ok, revisions} = ConditionContext.current_condition_revisions(incident)
        result = Map.put(result, "condition_revisions", revisions)

        if request_kind == :effect do
          affected_event_key = Keyword.get(opts, :affected_event_key)

          affected_correlation_ids =
            Signals.list_signal_correlations!(actor: context.admin)
            |> Enum.filter(&(&1.event_key == affected_event_key))
            |> MapSet.new(& &1.id)

          conditions_by_id =
            Signals.list_conditions!(actor: context.admin) |> Map.new(&{&1.id, &1})

          claims =
            revisions
            |> Enum.filter(fn %{"id" => id} ->
              is_nil(affected_event_key) or
                MapSet.member?(
                  affected_correlation_ids,
                  Map.fetch!(conditions_by_id, id).signal_correlation_id
                )
            end)
            |> Enum.map(fn %{"id" => id, "revision" => revision} ->
              %{"condition_id" => id, "revision" => revision}
            end)

          put_in(result, ["intent", "affected_conditions"], claims)
        else
          result
        end
      else
        result
      end

    result =
      if parameters = Keyword.get(opts, :parameters),
        do: put_in(result, ["intent", "parameters"], parameters),
        else: result

    result =
      if expected = Keyword.get(opts, :verification_expected),
        do: put_in(result, ["intent", "verification_intent", "expected_result"], expected),
        else: result

    result = put_in(result, ["intent", "delay_seconds"], Keyword.get(opts, :delay_seconds, 0))

    turn =
      Cases.complete_turn!(
        started.value.id,
        started.value.revision,
        result,
        :proposal,
        %{"action" => "route_resolver_decision", "turn_id" => started.value.id},
        "Review the Resolver decision",
        authorize?: false
      ).value

    proposal = Cases.materialize_proposal!(turn.id, authorize?: false)
    authorized = Cases.route_proposal_authority!(proposal.id, authorize?: false)

    if signal_provider,
      do: {incident, run, authorized, signal_provider},
      else: {incident, run, authorized}
  end

  defp signal_proposal_intent(evidence_id, context, kind \\ :effect)

  defp signal_proposal_intent(evidence_id, context, :effect) do
    proposal_intent(evidence_id, context)
    |> put_in(["tool", "operation"], "linux.service.restart")
    |> put_in(["verification_tool", "operation"], "linux.service.inspect")
    |> Map.put("operation", "linux.service.restart")
    |> Map.put("selectors", %{"unit" => "api.service"})
    |> Map.put("expected_result", %{"active_state" => "active"})
    |> put_in(["verification_intent", "selectors"], %{"unit" => "api.service"})
    |> put_in(["verification_intent", "expected_result"], %{"active_state" => "active"})
  end

  defp signal_proposal_intent(evidence_id, context, :observation) do
    proposal_intent(evidence_id, context, :observation)
    |> put_in(["tool", "operation"], "linux.service.inspect")
    |> Map.put("operation", "linux.service.inspect")
    |> Map.put("selectors", %{"unit" => "api.service"})
    |> Map.put("parameters", %{"unit" => "api.service"})
  end

  defp proposal_intent(evidence_id, context),
    do: proposal_intent(evidence_id, context, :effect)

  defp proposal_intent(evidence_id, context, :effect) do
    service = Map.get(context, :service, "api")

    tool = %{
      "request_kind" => "effect",
      "id" => "effect-tool",
      "target_id" => context.target.id,
      "target_revision" => context.target.revision,
      "access_method_id" => context.method.id,
      "access_method_revision" => context.method.revision,
      "provider_id" => context.provider.id,
      "provider_revision" => context.provider.revision,
      "capability" => "effect.service",
      "operation" => "service.restart"
    }

    %{
      "type" => "proposal",
      "delay_seconds" => 0,
      "purpose" => "remediation",
      "request_kind" => "effect",
      "tool_id" => tool["id"],
      "target_id" => tool["target_id"],
      "target_revision" => tool["target_revision"],
      "access_method_id" => tool["access_method_id"],
      "access_method_revision" => tool["access_method_revision"],
      "capability" => tool["capability"],
      "operation" => tool["operation"],
      "selectors" => %{"service" => service},
      "parameters" => %{"service" => service},
      "reason" => "Restart the unhealthy API service",
      "evidence_ids" => [evidence_id],
      "affected_conditions" => [],
      "expected_result" => %{"service" => "running"},
      "tool" => tool,
      "verification_intent" => %{
        "tool_id" => "verification-tool",
        "selectors" => %{"service" => service},
        "parameters" => %{"service" => service},
        "expected_result" => %{"service" => "running"}
      },
      "verification_tool" => %{
        "id" => "verification-tool",
        "target_id" => context.target.id,
        "target_revision" => context.target.revision,
        "access_method_id" => context.method.id,
        "access_method_revision" => context.method.revision,
        "provider_id" => context.provider.id,
        "provider_revision" => context.provider.revision,
        "capability" => "observe.service",
        "operation" => "service.inspect"
      }
    }
  end

  defp proposal_intent(evidence_id, context, :observation) do
    service = Map.get(context, :service, "api")

    tool = %{
      "request_kind" => "observation",
      "id" => "observation-tool",
      "target_id" => context.target.id,
      "target_revision" => context.target.revision,
      "access_method_id" => context.method.id,
      "access_method_revision" => context.method.revision,
      "provider_id" => context.provider.id,
      "provider_revision" => context.provider.revision,
      "capability" => "observe.service",
      "operation" => "service.inspect"
    }

    %{
      "type" => "proposal",
      "delay_seconds" => 0,
      "purpose" => "investigation",
      "request_kind" => "observation",
      "tool_id" => tool["id"],
      "target_id" => tool["target_id"],
      "target_revision" => tool["target_revision"],
      "access_method_id" => tool["access_method_id"],
      "access_method_revision" => tool["access_method_revision"],
      "capability" => tool["capability"],
      "operation" => tool["operation"],
      "selectors" => %{"service" => service},
      "parameters" => %{"service" => service},
      "reason" => "Inspect the unhealthy API service",
      "evidence_ids" => [evidence_id],
      "affected_conditions" => [],
      "expected_result" => %{},
      "tool" => tool,
      "verification_intent" => %{},
      "verification_tool" => %{}
    }
  end

  defp configure_mode!(admin, mode, max_effects \\ nil) do
    current = Cases.current_authority_setting!(actor: admin)

    Cases.configure_authority_setting!(
      current.setting_revision,
      mode,
      current.signal_automation_enabled,
      current.max_elapsed_seconds,
      current.max_resolver_turns,
      current.max_target_requests,
      max_effects || current.max_effects,
      current.max_related_targets,
      current.max_ai_usage_units,
      current.max_no_progress_turns,
      "test #{mode} Operation delivery",
      actor: admin
    )
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
      "enable Signal recovery test",
      actor: admin
    )
  end

  defp invocation(response) when is_function(response, 0),
    do: %{test_pid: self(), respond: response}

  defp invocation(response), do: %{test_pid: self(), respond: fn -> response end}

  defp separate_target!(context, suffix) do
    name = "operation-#{suffix}"
    target = Targets.create_target!(name, "host", "linux", %{}, nil, actor: context.admin)

    method =
      Targets.create_access_method!(
        target.id,
        context.provider.id,
        "method-#{suffix}",
        "ssh",
        "ssh://#{name}",
        context.provider.revision,
        10,
        ["effect.service", "observe.service"],
        actor: context.admin
      )
      |> then(&Targets.check_access_method!(&1.id, &1.revision, %{}, actor: context.admin))

    %{context | target: target, method: method}
  end

  defp verified_result(facts) do
    %Target.Verification{
      status: :verified,
      observed_at: DateTime.utc_now(),
      facts: facts,
      evidence: [%{"check" => "fresh"}]
    }
  end

  defp signal_provider!(incident, context) do
    Providers.create_provider!(
      "signal-#{incident.id}",
      :signal,
      "fixture-signal",
      %{"source" => incident.source},
      %{"secret" => "signal-secret"},
      actor: context.admin
    )
    |> then(&Providers.check_provider!(&1.id, 1, %{}, actor: context.admin))
    |> then(&Providers.enable_provider!(&1, 1, actor: context.admin))
  end

  defp signal_case!(suffix, context, opts) do
    provider = signal_provider!(%{id: suffix, source: "test"}, context)

    Targets.create_external_identity!(
      context.target.id,
      "test",
      "hostname",
      context.target.name,
      actor: context.admin
    )

    fire_signal!(
      provider,
      context,
      "operation-#{suffix}",
      "initial-#{suffix}",
      DateTime.add(DateTime.utc_now(), -10, :second)
    )

    if additional = Keyword.get(opts, :additional_event_key) do
      signal_event!(
        provider,
        context,
        additional,
        "additional-#{suffix}",
        :firing,
        DateTime.add(DateTime.utc_now(), -9, :second),
        %{
          "labels" => %{
            "service" => Keyword.get(opts, :additional_subject, "api.service"),
            "alertname" => "ServiceUnavailable"
          }
        }
      )
    end

    [incident] = Cases.list_cases!(actor: context.admin)
    {incident, provider}
  end

  defp fire_signal!(provider, context, event_key, receipt_id, now) do
    signal_event!(provider, context, event_key, receipt_id, :firing, now)
  end

  defp recover_signal!(provider, context, event_key, receipt_id, now \\ DateTime.utc_now()) do
    signal_event!(provider, context, event_key, receipt_id, :recovered, now)
  end

  defp signal_event!(provider, context, event_key, receipt_id, state, now, attributes \\ nil) do
    Signals.ingest_signal!(
      provider.id,
      provider.revision,
      %Signal.Envelope{body: receipt_id, headers: %{}, received_at: now},
      %{
        authenticate: fn state, _envelope ->
          {:ok, %Signal.AuthenticatedReceipt{receipt_id: receipt_id, source: state.source}}
        end,
        normalize: fn _state, _envelope, _receipt ->
          {:ok,
           [
             %Signal.Event{
               receipt_id: receipt_id,
               event_key: event_key,
               state: state,
               occurred_at: now,
               target_ref: %{kind: :hostname, value: context.target.name},
               attributes:
                 attributes ||
                   %{
                     "labels" => %{
                       "service" => "api.service",
                       "alertname" => "ServiceUnavailable"
                     }
                   }
             }
           ]}
        end
      },
      authorize?: false
    )
  end

  defp recovery_check_jobs(case_id) do
    Skopos.Repo.all(
      from(job in Oban.Job,
        where:
          job.worker == ^Oban.Worker.to_string(SignalRecoveryCheckWorker) and
            fragment("?->>'case_id'", job.args) == ^case_id
      )
    )
  end

  defp recovery_conclusion!(context, suffix, opts \\ []) do
    {incident, run, proposal} =
      authorized_proposal!(suffix, context, Keyword.put(opts, :request_kind, :observation))
      |> then(fn
        {incident, run, proposal} -> {incident, run, proposal}
        {incident, run, proposal, _signal_provider} -> {incident, run, proposal}
      end)

    operation = Cases.accept_operation!(proposal.id, authorize?: false)
    assert :ok = deliver_observation(operation, %{"active_state" => "active"})
    evidence = operation_evidence_record(operation.id)
    pending = Cases.get_case!(incident.id, authorize?: false).pending_intent
    turn = Cases.get_turn!(pending["turn_id"], authorize?: false)

    assert :ok =
             ResolverDelivery.run(turn.id,
               target_invocation:
                 invocation({:ok, %Target.Capabilities{observations: [], effects: []}}),
               ai_invocation: %{
                 test_pid: self(),
                 respond: fn request ->
                   {:ok,
                    %AI.ResolverDecision{
                      intent: %AI.RecoveryConclusion{
                        reason: "The inspected service is active",
                        evidence_ids: [evidence.id],
                        condition_claims:
                          Enum.map(request.conditions, fn condition ->
                            %{
                              "condition_id" => condition.id,
                              "revision" => condition.revision,
                              "evidence_id" => evidence.id,
                              "reason" =>
                                "The current observation shows the inspected service is active"
                            }
                          end),
                        desired_outcome_claims:
                          if(request.case_symptom,
                            do: [
                              %{
                                "symptom_id" => request.case_symptom.id,
                                "evidence_id" => evidence.id,
                                "fact_keys" => ["active_state"],
                                "reason" => "The inspected service is active"
                              }
                            ],
                            else: []
                          )
                      },
                      usage: %AI.Usage{input_tokens: 3, output_tokens: 2}
                    }}
                 end
               }
             )

    {incident, run, turn, evidence}
  end

  defp approve_recovery!(turn, context, delivery_opts \\ []) do
    assert :ok =
             Skopos.Cases.Turn.RecoveryReviewDelivery.run(
               turn.id,
               delivery_opts ++
                 [
                   ai_invocation: %{
                     test_pid: self(),
                     respond: fn request ->
                       assert request.case_id == turn.case_id
                       assert request.conclusion.evidence_ids != []

                       if delivery_opts != [],
                         do:
                           assert(
                             request.retry_context == %{
                               "category" => "invalid_output",
                               "rejection_code" => "schema_validation",
                               "rejection_path" => "/reason"
                             }
                           )

                       assessment =
                         if request.case_symptom do
                           %{
                             "symptom_id" => request.case_symptom.id,
                             "desired_outcome" => request.case_symptom.desired_outcome,
                             "evidence_ids" =>
                               request.conclusion.desired_outcome_claims
                               |> Enum.map(& &1["evidence_id"])
                               |> Enum.uniq(),
                             "status" => "supported",
                             "reason" => "The claimed facts satisfy the desired outcome"
                           }
                         end

                       {:ok,
                        %AI.ReviewDecision{
                          purpose_assessment: :remediation,
                          verdict: :approved,
                          reason:
                            "The cited observation directly checks the stated service state",
                          desired_outcome_assessment: assessment,
                          usage: %AI.Usage{input_tokens: 4, output_tokens: 2}
                        }}
                     end
                   }
                 ]
             )

    assert_receive {:review_recovery, %{model: "reviewer-model"}, _request}
    assert Cases.get_case!(turn.case_id, authorize?: false).status == :resolved

    event =
      Cases.case_event_by_idempotency!(
        turn.case_id,
        Skopos.Cases.ResolutionRun.Budget.key("recovery-review:result", turn.id),
        authorize?: false
      )

    invocation =
      Cases.ai_invocation_by_idempotency!(event.data["invocation_key"], authorize?: false)

    assert invocation.turn_id == turn.id
    assert invocation.status == :completed
    assert invocation.provider_id == context.reviewer_provider.id
  end

  defp operation_jobs(operation_id) do
    Skopos.Repo.aggregate(
      from(job in Oban.Job,
        where:
          job.worker == ^Oban.Worker.to_string(OperationWorker) and
            fragment("?->>'operation_id'", job.args) == ^operation_id
      ),
      :count
    )
  end

  defp operation_job(operation_id) do
    Skopos.Repo.one!(
      from(job in Oban.Job,
        where:
          job.worker == ^Oban.Worker.to_string(OperationWorker) and
            fragment("?->>'operation_id'", job.args) == ^operation_id
      )
    )
  end

  defp operation_evidence(operation_id) do
    Skopos.Repo.aggregate(
      from(evidence in Skopos.Cases.Evidence,
        where: evidence.idempotency_key == ^"operation:outcome:#{operation_id}"
      ),
      :count
    )
  end

  defp operation_evidence_record(operation_id) do
    operation = Cases.get_operation!(operation_id, authorize?: false)

    Cases.evidence_by_idempotency!(
      operation.case_id,
      "operation:outcome:#{operation_id}",
      authorize?: false
    )
  end

  defp verification_jobs(attempt_id) do
    Skopos.Repo.aggregate(
      from(job in Oban.Job,
        where:
          job.worker == ^Oban.Worker.to_string(VerificationWorker) and
            fragment("?->>'verification_attempt_id'", job.args) == ^attempt_id
      ),
      :count
    )
  end

  defp verification_job(attempt_id) do
    Skopos.Repo.one!(
      from(job in Oban.Job,
        where:
          job.worker == ^Oban.Worker.to_string(VerificationWorker) and
            fragment("?->>'verification_attempt_id'", job.args) == ^attempt_id
      )
    )
  end

  defp verification_evidence(attempt_id) do
    Skopos.Repo.aggregate(
      from(evidence in Skopos.Cases.Evidence,
        where: evidence.idempotency_key == ^"verification:outcome:#{attempt_id}"
      ),
      :count
    )
  end

  defp report_jobs(case_id) do
    from(job in Oban.Job,
      where:
        job.worker == ^Oban.Worker.to_string(GenerationWorker) and
          fragment("?->>'case_id'", job.args) == ^case_id
    )
    |> Skopos.Repo.all()
  end
end
