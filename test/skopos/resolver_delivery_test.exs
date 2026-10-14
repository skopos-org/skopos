defmodule Skopos.ResolverDeliveryTest do
  use Skopos.DataCase, async: false

  import Ecto.Query

  alias Skopos.{Accounts, Cases, Providers, Targets}
  alias Skopos.Cases.Turn.ResolverDelivery, as: ResolverDelivery
  alias Skopos.Cases.Turn.ResolverWorker, as: ResolverWorker
  alias Skopos.Cases.ResolutionRun.Budget, as: Budget
  alias Skopos.Cases.Case.DecisionRouteWorker
  alias Skopos.Providers.{AI, Target}

  @password "correct horse battery staple"
  @api_key "resolver-provider-secret"

  setup do
    admin =
      Accounts.bootstrap!("delivery-admin@example.com", @password, @password, authorize?: true)

    operator =
      Accounts.create_user!("delivery-operator@example.com", @password, :operator, actor: admin)

    current = Cases.current_authority_setting!(actor: admin)

    Cases.configure_authority_setting!(
      current.setting_revision,
      :auto,
      true,
      600,
      4,
      5,
      2,
      3,
      10_000,
      2,
      "configure Resolver delivery",
      actor: admin
    )

    provider =
      Providers.create_provider!(
        "resolver-ai",
        :ai,
        "fixture-ai",
        %{"model" => "resolver-model"},
        %{"api_key" => @api_key},
        actor: admin
      )
      |> then(&Providers.check_provider!(&1.id, 1, %{}, actor: admin))
      |> then(&Providers.enable_provider!(&1, 1, actor: admin))

    assignment =
      Skopos.TestAIUsage.configure!(provider.id, :resolver, 10, admin)
      |> Map.fetch!(:resolver)

    %{admin: admin, operator: operator, provider: provider, assignment: assignment}
  end

  @tag resolver_case_read_fault: true
  test "temporary Case input read failure retries the same Turn before AI dispatch", context do
    {incident, run, turn} = turn!("resolver-case-read-failure", context.operator)
    before_case = Cases.get_case!(incident.id, authorize?: false)
    before_run = Cases.get_resolution_run!(run.id, authorize?: false)

    Repo.query!(
      "ALTER TABLE cases RENAME COLUMN selected_target_revision TO unavailable_target_revision"
    )

    try do
      assert {:error, _error} = ResolverWorker.perform(%Oban.Job{args: %{"turn_id" => turn.id}})
    after
      Repo.query!(
        "ALTER TABLE cases RENAME COLUMN unavailable_target_revision TO selected_target_revision"
      )
    end

    current_turn = Cases.get_turn!(turn.id, authorize?: false)
    assert current_turn.status == :started
    assert current_turn.revision == turn.revision
    assert current_turn.ordinal == turn.ordinal
    assert current_turn.result == %{}
    assert Cases.get_case!(incident.id, authorize?: false) == before_case
    assert Cases.get_resolution_run!(run.id, authorize?: false) == before_run
    assert Cases.list_ai_invocations!(authorize?: false) == []

    assert :ok =
             ResolverDelivery.run(turn.id,
               ai_invocation: %{
                 test_pid: self(),
                 respond: fn _request ->
                   {:ok,
                    %AI.ResolverDecision{
                      intent: %AI.TargetSearch{
                        query: "linux-01 disk errors",
                        reason: "Find the affected registered Target"
                      },
                      usage: %AI.Usage{input_tokens: 7, output_tokens: 5}
                    }}
                 end
               }
             )

    assert_receive {:resolve, _, _}
    assert :ok = ResolverWorker.perform(%Oban.Job{args: %{"turn_id" => turn.id}})
    refute_receive {:resolve, _, _}
    assert Cases.get_resolution_run!(run.id, authorize?: false).ai_usage_units == 12
    assert [invocation] = Cases.list_ai_invocations!(authorize?: false)
    assert invocation.status == :completed
    assert [_job] = route_jobs(turn.id)
  end

  @tag post_dispatch_case_read_fault: true
  test "unreadable Case state after dispatch is retryable rather than a false cancellation",
       context do
    {incident, run, turn} = turn!("post-dispatch-case-read", context.operator)
    before_case = Cases.get_case!(incident.id, authorize?: false)
    before_run = Cases.get_resolution_run!(run.id, authorize?: false)

    try do
      assert {:error, _error} =
               ResolverDelivery.run(turn.id,
                 ai_invocation: %{
                   test_pid: self(),
                   respond: fn _request ->
                     Repo.query!(
                       "ALTER TABLE cases RENAME COLUMN selected_target_revision TO unavailable_target_revision"
                     )

                     {:error, :invalid_output, "Object schema was rejected",
                      %AI.Usage{input_tokens: 7, output_tokens: 5}, "schema_validation"}
                   end
                 }
               )
    after
      Repo.query!(
        "ALTER TABLE cases RENAME COLUMN unavailable_target_revision TO selected_target_revision"
      )
    end

    assert_receive {:resolve, _, _}
    assert Cases.get_case!(incident.id, authorize?: false) == before_case
    assert Cases.get_resolution_run!(run.id, authorize?: false) == before_run
    assert Cases.get_turn!(turn.id, authorize?: false).status == :started
    assert [%{status: :dispatching}] = Cases.list_ai_invocations!(authorize?: false)
    assert :ok = ResolverWorker.perform(%Oban.Job{args: %{"turn_id" => turn.id}})
    refute_receive {:resolve, _, _}
    assert [%{status: :unknown}] = Cases.list_ai_invocations!(authorize?: false)
    assert Cases.get_resolution_run!(run.id, authorize?: false).ai_usage_units == 10_000
  end

  @tag missing_resolver_assignment: true
  test "a genuinely missing Resolver assignment requires attention without invoking AI",
       context do
    {incident, run, turn} = turn!("missing-resolver", context.operator)
    Providers.disable_provider!(context.provider, context.provider.revision, actor: context.admin)

    assert :ok = ResolverWorker.perform(%Oban.Job{args: %{"turn_id" => turn.id}})
    assert Cases.get_case!(incident.id, authorize?: false).status == :needs_attention
    assert Cases.get_resolution_run!(run.id, authorize?: false).status == :needs_attention
    assert Cases.list_ai_invocations!(authorize?: false) == []
    refute_receive {:resolve, _, _}
  end

  @tag ai_unsent_retry: true
  test "a Resolver callback read fault retries the same unsent invocation without changing the decision",
       context do
    {incident, run, turn} = turn!("resolver-unsent-read", context.operator)
    before_case = Cases.get_case!(incident.id, authorize?: false)
    before_run = Cases.get_resolution_run!(run.id, authorize?: false)
    before_turn = Cases.get_turn!(turn.id, authorize?: false)

    assert {:error, error} =
             ResolverDelivery.run(turn.id,
               ai_invocation: %{
                 test_pid: self(),
                 cancelled?: fn ->
                   {:error, error} =
                     Repo.query("SELECT invocation_context_unavailable", [], mode: :savepoint)

                   raise error
                 end,
                 respond: fn _request -> flunk("unsent Resolver was called") end
               }
             )

    assert %Ash.Error.Unknown{} = error
    assert Exception.message(error) =~ "invocation_context_unavailable"
    refute_receive {:resolve, _, _}
    assert Cases.get_case!(incident.id, authorize?: false) == before_case
    assert Cases.get_resolution_run!(run.id, authorize?: false) == before_run
    assert Cases.get_turn!(turn.id, authorize?: false) == before_turn

    assert [%{status: :queued, dispatch_confirmed: false} = unsent] =
             Cases.list_ai_invocations!(authorize?: false)

    assert unsent.usage_reported == false
    assert unsent.dispatch_started_at == nil
    parent = self()

    retry =
      Task.async(fn ->
        ResolverDelivery.run(turn.id,
          ai_invocation: %{
            test_pid: parent,
            respond: fn _request ->
              {:ok,
               %AI.ResolverDecision{
                 intent: %AI.TargetSearch{
                   query: "linux-01 disk errors",
                   reason: "Find the affected registered Target"
                 },
                 usage: %AI.Usage{input_tokens: 7, output_tokens: 5}
               }}
            end
          }
        )
      end)

    assert :ok = Task.await(retry, 5_000)

    assert_receive {:resolve, _, _}

    assert [%{id: invocation_id, status: :completed}] =
             Cases.list_ai_invocations!(authorize?: false)

    assert invocation_id == unsent.id
    assert Cases.get_resolution_run!(run.id, authorize?: false).ai_usage_units == 12
    assert :ok = ResolverWorker.perform(%Oban.Job{args: %{"turn_id" => turn.id}})
    refute_receive {:resolve, _, _}
    assert Cases.get_resolution_run!(run.id, authorize?: false).ai_usage_units == 12
  end

  @tag owned_context_read_fault: true
  test "a changed Resolver assignment after claim sends no AI request", context do
    {incident, run, turn} = turn!("resolver-assignment-changed", context.operator)
    changed = :atomics.new(1, [])

    assert :ok =
             ResolverDelivery.run(turn.id,
               ai_invocation: %{
                 test_pid: self(),
                 cancelled?: fn ->
                   if :atomics.compare_exchange(changed, 1, 0, 1) == :ok do
                     Skopos.TestAIUsage.configure!(
                       context.provider.id,
                       :resolver,
                       11,
                       context.admin
                     )
                   end

                   false
                 end,
                 respond: fn _request -> flunk("obsolete Resolver assignment dispatched AI") end
               }
             )

    refute_receive {:resolve, _, _}

    assert [%{dispatch_confirmed: false, usage_reported: false}] =
             Cases.list_ai_invocations!(authorize?: false)

    assert Cases.get_resolution_run!(run.id, authorize?: false).ai_usage_units == 0
    assert Cases.get_case!(incident.id, authorize?: false).status == :running

    assert Cases.get_case!(incident.id, authorize?: false).pending_intent["action"] ==
             "resolve_turn"

    next_id = Cases.get_case!(incident.id, authorize?: false).pending_intent["turn_id"]
    refute next_id == turn.id

    assert :ok =
             ResolverDelivery.run(next_id,
               ai_invocation: %{
                 test_pid: self(),
                 respond: fn _request ->
                   {:ok,
                    %AI.ResolverDecision{
                      intent: %AI.TargetSearch{
                        query: "linux-01 disk errors",
                        reason: "Find the affected registered Target"
                      },
                      usage: %AI.Usage{input_tokens: 7, output_tokens: 5}
                    }}
                 end
               }
             )

    assert_receive {:resolve, _, _}
    assert :ok = ResolverDelivery.run(turn.id)
    assert :ok = ResolverDelivery.run(next_id)
    refute_receive {:resolve, _, _}
    assert Cases.get_resolution_run!(run.id, authorize?: false).ai_usage_units == 12
    assert length(Cases.list_ai_invocations!(authorize?: false)) == 2
  end

  @tag owned_context_read_fault: true
  test "a projected Resolver assignment cannot be rebased by claim", context do
    {_incident, _run, turn} = turn!("resolver-projected-assignment", context.operator)
    selection = Providers.select_resolver_ai!(authorize?: false)

    assert {:ok, request, projected} =
             Skopos.Cases.Turn.ResolverProjection.build(turn.id, selection)

    Skopos.TestAIUsage.configure!(context.provider.id, :resolver, 11, context.admin)

    assert {:error, _changed} =
             Cases.claim_ai_invocation(
               :resolver,
               turn.case_id,
               projected.case_revision,
               turn.resolution_run_id,
               turn.id,
               turn.revision,
               nil,
               nil,
               selection.provider_id,
               selection.assignment_id,
               selection.provider_revision,
               selection.assignment_revision,
               selection.source,
               Skopos.Cases.AIInvocation.request_digest(request),
               nil,
               %{
                 invocation_context: projected,
                 request_size_bytes: AI.resolver_disclosure_size(request)
               },
               authorize?: false
             )

    assert Cases.list_ai_invocations!(authorize?: false) == []
    assert Cases.get_turn!(turn.id, authorize?: false).status == :started
  end

  @tag changed_context_save_failure: true
  test "failed successor persistence rolls back Resolver settlement and preserves the dispatch marker",
       context do
    {incident, run, turn} = turn!("resolver-context-save-failure", context.operator)
    before_turn = Cases.get_turn!(turn.id, authorize?: false)

    Repo.query!("""
    CREATE FUNCTION pg_temp.reject_context_successor() RETURNS trigger LANGUAGE plpgsql AS $$
    BEGIN
      IF NEW.event_type = 'turn_started' THEN
        RAISE EXCEPTION 'injected context successor persistence failure';
      END IF;
      RETURN NEW;
    END; $$;
    """)

    Repo.query!("""
    CREATE TRIGGER reject_context_successor BEFORE INSERT ON case_events
    FOR EACH ROW EXECUTE FUNCTION pg_temp.reject_context_successor();
    """)

    changed = :atomics.new(1, [])

    try do
      assert {:error, error} =
               ResolverDelivery.run(turn.id,
                 ai_invocation: %{
                   test_pid: self(),
                   cancelled?: fn ->
                     if :atomics.compare_exchange(changed, 1, 0, 1) == :ok,
                       do:
                         Skopos.TestAIUsage.configure!(
                           context.provider.id,
                           :resolver,
                           11,
                           context.admin
                         )

                     false
                   end,
                   respond: fn _request -> flunk("obsolete Resolver dispatched AI") end
                 }
               )

      assert Exception.message(error) =~ "injected context successor persistence failure"
    after
      Repo.query!("DROP TRIGGER reject_context_successor ON case_events")
    end

    refute_receive {:resolve, _, _}
    assert Cases.get_turn!(turn.id, authorize?: false) == before_turn
    assert Cases.get_case!(incident.id, authorize?: false).status == :running
    assert Cases.get_resolution_run!(run.id, authorize?: false).ai_usage_units == 0

    assert [%{status: :dispatching, usage_reported: false}] =
             Cases.list_ai_invocations!(authorize?: false)

    assert [only_turn] = Cases.list_turns!(authorize?: false)
    assert only_turn.id == turn.id

    assert :ok = ResolverWorker.perform(%Oban.Job{args: %{"turn_id" => turn.id}})
    refute_receive {:resolve, _, _}

    assert [%{status: :unknown, category: "response_unknown"} = unknown] =
             Cases.list_ai_invocations!(authorize?: false)

    assert Cases.get_resolution_run!(run.id, authorize?: false).ai_usage_units ==
             unknown.reserved_units
  end

  @tag owned_context_read_fault: true
  test "a built-in Resolver Case read fault remains an unsent retry", context do
    {incident, run, turn} = turn!("owned-resolver-context-read", context.operator)
    original_run = Cases.get_resolution_run!(run.id, authorize?: false)
    injected = :atomics.new(1, [])

    try do
      assert {:error, error} =
               ResolverDelivery.run(turn.id,
                 ai_invocation: %{
                   test_pid: self(),
                   cancelled?: fn ->
                     if :atomics.compare_exchange(injected, 1, 0, 1) == :ok do
                       Repo.query!(
                         "ALTER TABLE cases RENAME COLUMN title TO unavailable_case_title"
                       )
                     end

                     false
                   end,
                   respond: fn _request -> flunk("an unreadable Case dispatched Resolver AI") end
                 }
               )

      assert Exception.message(error) =~ "title"
    after
      if :atomics.get(injected, 1) == 1 do
        Repo.query!("ALTER TABLE cases RENAME COLUMN unavailable_case_title TO title")
      end
    end

    refute_receive {:resolve, _, _}

    assert [%{status: :queued, dispatch_confirmed: false, usage_reported: false}] =
             Cases.list_ai_invocations!(authorize?: false)

    assert Cases.get_case!(incident.id, authorize?: false).status == :running
    assert Cases.get_turn!(turn.id, authorize?: false).status == :started

    assert Cases.get_resolution_run!(run.id, authorize?: false).ai_usage_units ==
             original_run.ai_usage_units
  end

  @tag ai_unsent_retry: true
  test "an unsent retry save failure retains the unknown-response marker instead of resending",
       context do
    {_incident, run, turn} = turn!("resolver-unsent-save-failure", context.operator)

    try do
      assert {:error, error} =
               ResolverDelivery.run(turn.id,
                 ai_invocation: %{
                   test_pid: self(),
                   cancelled?: fn ->
                     Repo.query!(
                       "ALTER TABLE ai_invocations RENAME COLUMN dispatch_started_at TO unavailable_dispatch_started_at"
                     )

                     {:error, error} =
                       Repo.query("SELECT invocation_context_unavailable", [], mode: :savepoint)

                     raise error
                   end,
                   respond: fn _request -> flunk("unsent request was dispatched") end
                 }
               )

      assert Exception.message(error) =~ "invocation_context_unavailable"
      assert Exception.message(error) =~ "dispatch_started_at"
    after
      Repo.query!(
        "ALTER TABLE ai_invocations RENAME COLUMN unavailable_dispatch_started_at TO dispatch_started_at"
      )
    end

    refute_receive {:resolve, _, _}
    assert Cases.get_resolution_run!(run.id, authorize?: false).ai_usage_units == 0
    assert [%{status: :dispatching} = interrupted] = Cases.list_ai_invocations!(authorize?: false)

    assert :ok =
             ResolverWorker.perform(%Oban.Job{args: %{"turn_id" => turn.id}})

    refute_receive {:resolve, _, _}

    assert [%{status: :unknown, id: invocation_id}] =
             Cases.list_ai_invocations!(authorize?: false)

    assert invocation_id == interrupted.id

    assert Cases.get_resolution_run!(run.id, authorize?: false).ai_usage_units ==
             interrupted.reserved_units
  end

  test "result and AI usage commit once after a durable exact assignment", context do
    {incident, run, turn} = turn!("success", context.operator)

    decision = %AI.ResolverDecision{
      intent: %AI.TargetSearch{
        query: "linux-01 disk errors",
        reason: "Find the registered Target referenced by the incident"
      },
      usage: %AI.Usage{input_tokens: 7, output_tokens: 5}
    }

    ai_invocation = %{
      test_pid: self(),
      respond: fn request ->
        key = Budget.key("turn:resolver_assignment", turn.id)

        assert {:ok, event} =
                 Cases.case_event_by_idempotency(incident.id, key, authorize?: false)

        assert event.data["provider_id"] == context.provider.id
        assert event.data["provider_revision"] == context.provider.revision
        assert event.data["assignment_id"] == context.assignment.id
        assert event.data["assignment_revision"] == context.assignment.revision
        assert request.provider_revision == context.provider.revision
        {:ok, decision}
      end
    }

    assert :ok = ResolverDelivery.run(turn.id, ai_invocation: ai_invocation)
    assert_receive {:resolve, %{model: "resolver-model", api_key: @api_key}, _request}

    completed = Cases.get_turn!(turn.id, authorize?: false)
    assert completed.status == :completed
    assert completed.result["outcome"] == "decision"
    assert completed.result["intent"]["type"] == "target_search"
    assert completed.result["usage"] == %{"input_tokens" => 7, "output_tokens" => 5}
    assert [%Oban.Job{args: %{"turn_id" => turn_id}}] = route_jobs(turn.id)
    assert turn_id == turn.id

    charged = Cases.get_resolution_run!(run.id, authorize?: false)
    assert charged.ai_usage_units == 12

    [record] = Cases.list_ai_invocations!(authorize?: false)
    assert record.status == :completed
    assert record.input_tokens == 7
    assert record.output_tokens == 5

    assert :ok =
             ResolverDelivery.run(turn.id,
               ai_invocation: %{
                 test_pid: self(),
                 respond: fn _request -> flunk("completed Turn called AI again") end
               }
             )

    assert :ok = ResolverWorker.perform(%Oban.Job{args: %{"turn_id" => turn.id}})
    refute_receive {:resolve, _, _}

    events = Cases.list_case_events!(actor: context.admin)
    assert Enum.count(events, &(&1.event_type == "resolver_assigned")) == 1
    assert Enum.count(events, &(&1.event_type == "budget_charged")) == 1
    assert Enum.count(events, &(&1.event_type == "turn_completed")) == 1
  end

  for fault <- [:missing_row, :storage_error] do
    @tag route_job_fault: fault
    test "saved paid Resolver result retries #{fault} routing without another AI call", context do
      {_incident, run, turn} = turn!("route-job-persistence", context.operator)

      rejection =
        case context.route_job_fault do
          :missing_row -> "RETURN NULL;"
          :storage_error -> "RAISE EXCEPTION 'injected route job persistence failure';"
        end

      Repo.query!("""
      CREATE FUNCTION pg_temp.reject_resolver_route_job() RETURNS trigger LANGUAGE plpgsql AS $$
      BEGIN
        IF NEW.worker = 'Skopos.Cases.Case.DecisionRouteWorker' THEN #{rejection} END IF;
        RETURN NEW;
      END;
      $$;
      """)

      Repo.query!("""
      CREATE TRIGGER reject_resolver_route_job BEFORE INSERT ON oban_jobs
      FOR EACH ROW EXECUTE FUNCTION pg_temp.reject_resolver_route_job()
      """)

      deliver = fn ->
        ResolverDelivery.run(turn.id,
          ai_invocation: %{
            test_pid: self(),
            respond: fn _request ->
              {:ok,
               %AI.ResolverDecision{
                 intent: %AI.TargetSearch{
                   query: "linux-01 disk errors",
                   reason: "Find the registered Target referenced by the incident"
                 },
                 usage: %AI.Usage{input_tokens: 7, output_tokens: 5}
               }}
            end
          }
        )
      end

      case context.route_job_fault do
        :missing_row -> assert {:error, _error} = deliver.()
        :storage_error -> assert_raise Postgrex.Error, deliver
      end

      assert_receive {:resolve, _, _}
      completed = Cases.get_turn!(turn.id, authorize?: false)
      assert completed.status == :completed
      assert completed.result["outcome"] == "decision"
      assert Cases.get_resolution_run!(run.id, authorize?: false).ai_usage_units == 12
      assert [invocation] = Cases.list_ai_invocations!(authorize?: false)
      assert invocation.status == :completed
      assert route_jobs(turn.id) == []

      Repo.query!("DROP TRIGGER reject_resolver_route_job ON oban_jobs")

      for _ <- 1..2 do
        assert :ok = ResolverWorker.perform(%Oban.Job{args: %{"turn_id" => turn.id}})
      end

      assert Cases.get_turn!(turn.id, authorize?: false) == completed
      assert Cases.get_resolution_run!(run.id, authorize?: false).ai_usage_units == 12
      assert Cases.list_ai_invocations!(authorize?: false) == [invocation]
      assert [%Oban.Job{id: id}] = route_jobs(turn.id)
      assert is_integer(id)
      refute_receive {:resolve, _, _}
    end
  end

  test "Resolver chooses a file range and receives exact citable contents next turn", context do
    {turn, run, source, reference} = file_turn!(context)

    assert :ok =
             ResolverDelivery.run(turn.id,
               ai_invocation: %{
                 test_pid: self(),
                 respond: fn request ->
                   assert Enum.any?(request.evidence, &(&1.id == source.id))

                   {:ok,
                    %AI.ResolverDecision{
                      intent:
                        struct!(AI.FileRead,
                          source_evidence_id: source.id,
                          reference: reference,
                          offset: 1,
                          length: 3,
                          reason: "Inspect the native response"
                        ),
                      usage: %AI.Usage{input_tokens: 7, output_tokens: 5}
                    }}
                 end
               }
             )

    assert :ok = DecisionRouteWorker.perform(%Oban.Job{args: %{"turn_id" => turn.id}})
    assert :ok = DecisionRouteWorker.perform(%Oban.Job{args: %{"turn_id" => turn.id}})

    [receipt] =
      Cases.list_evidence!(actor: context.operator) |> Enum.filter(&(&1.kind == "file_read"))

    refute Map.has_key?(receipt.content, "value")

    [next] =
      Cases.list_turns!(actor: context.operator)
      |> Enum.filter(&(&1.resolution_run_id == run.id and &1.id != turn.id))

    assert next.status == :started
    assert next.intent["file_read_evidence_id"] == receipt.id

    assert :ok =
             ResolverDelivery.run(next.id,
               ai_invocation: %{
                 test_pid: self(),
                 respond: fn request ->
                   slice = Enum.find(request.evidence, &(&1.id == receipt.id))
                   assert slice.kind == "file_read"
                   assert slice.content["value"] == <<0, 1, 2>>
                   assert slice.content["encoding"] == "utf8"
                   assert slice.content["offset"] == 1
                   assert slice.content["byte_count"] == 3
                   assert slice.content["next_offset"] == 4
                   assert slice.content["eof"] == false
                   assert slice.content["source_evidence_id"] == source.id

                   assert slice.content["source_observed_at"] ==
                            DateTime.to_iso8601(source.observed_at)

                   assert slice.content["source_completion_reason"] == "upload"
                   assert AI.resolver_disclosure_size(request) <= request.disclosure.max_bytes

                   {:ok,
                    %AI.ResolverDecision{
                      intent: %AI.TargetSearch{
                        query: "resolver-file-host",
                        reason: "Continue the investigation"
                      },
                      usage: %AI.Usage{input_tokens: 11, output_tokens: 3}
                    }}
                 end
               }
             )

    current = Cases.get_resolution_run!(run.id, authorize?: false)
    assert current.turn_count == 2
    assert current.target_request_count == 0
    assert current.effect_count == 0
    assert current.ai_usage_units == 26
    assert Cases.get_evidence!(receipt.id, actor: context.operator).content == receipt.content
  end

  for disposition <- [:revoked, :expired] do
    @tag artifact_disposition: disposition
    test "a #{disposition} file reaches the next Resolver without a human handoff", context do
      {turn, run, source, reference} = file_turn!(context)
      file_decision!(turn, source, reference)

      if context.artifact_disposition == :expired do
        Skopos.Repo.query!(
          "UPDATE artifacts SET expires_at = now() - interval '1 second' WHERE id = $1",
          [Ecto.UUID.dump!(reference["id"])]
        )

        Targets.expire_artifact!(reference["id"], authorize?: false)
      else
        Targets.revoke_artifact!(reference["id"], actor: context.operator)
      end

      assert Targets.get_artifact!(reference["id"], actor: context.operator).status ==
               context.artifact_disposition

      assert {:error, _error} =
               Targets.read_bound_artifact_range(reference, 0, 3, actor: context.operator)

      assert :ok = DecisionRouteWorker.perform(%Oban.Job{args: %{"turn_id" => turn.id}})

      [next] =
        Cases.list_turns!(actor: context.operator)
        |> Enum.filter(&(&1.resolution_run_id == run.id and &1.id != turn.id))

      assert :ok =
               ResolverDelivery.run(next.id,
                 ai_invocation: %{
                   test_pid: self(),
                   respond: fn request ->
                     receipt = Enum.find(request.evidence, &(&1.kind == "file_read"))
                     assert receipt.content["status"] == "unavailable"
                     refute Map.has_key?(receipt.content, "value")
                     assert AI.file_read_options(request) == []

                     {:ok,
                      %AI.ResolverDecision{
                        intent: %AI.TargetSearch{
                          query: "resolver-file-host",
                          reason: "Seek another source"
                        },
                        usage: %AI.Usage{input_tokens: 7, output_tokens: 5}
                      }}
                   end
                 }
               )

      incident = Cases.get_case!(turn.case_id, authorize?: false)
      assert incident.status == :running
      assert incident.required_human_input == nil

      assert Cases.get_turn!(next.id, authorize?: false).result["intent"]["type"] ==
               "target_search"

      assert Cases.get_resolution_run!(run.id, authorize?: false).ai_usage_units == 24
      assert Cases.get_evidence!(source.id, actor: context.operator).content == source.content
    end
  end

  test "file receipt persistence failure retries routing without a second AI charge", context do
    {turn, run, source, reference} = file_turn!(context)
    file_decision!(turn, source, reference)

    Skopos.Repo.query!("""
    CREATE FUNCTION pg_temp.reject_routed_file_event() RETURNS trigger LANGUAGE plpgsql AS $$
    BEGIN
      IF NEW.event_type = 'evidence_added' AND NEW.data->>'kind' = 'file_read' THEN
        RAISE EXCEPTION 'injected routed file receipt failure';
      END IF;
      RETURN NEW;
    END; $$;
    """)

    Skopos.Repo.query!("""
    CREATE TRIGGER reject_routed_file_event BEFORE INSERT ON case_events
    FOR EACH ROW EXECUTE FUNCTION pg_temp.reject_routed_file_event();
    """)

    job = %Oban.Job{args: %{"turn_id" => turn.id}}
    assert {:error, _} = DecisionRouteWorker.perform(job)
    assert Cases.get_case!(turn.case_id, authorize?: false).status == :running
    refute Enum.any?(Cases.list_evidence!(actor: context.operator), &(&1.kind == "file_read"))
    Skopos.Repo.query!("DROP TRIGGER reject_routed_file_event ON case_events")
    assert :ok = DecisionRouteWorker.perform(job)
    assert :ok = DecisionRouteWorker.perform(job)

    assert Enum.count(Cases.list_evidence!(actor: context.operator), &(&1.kind == "file_read")) ==
             1

    assert Enum.count(
             Cases.list_turns!(actor: context.operator),
             &(&1.resolution_run_id == run.id)
           ) == 2

    current = Cases.get_resolution_run!(run.id, authorize?: false)
    assert current.ai_usage_units == 12
    assert current.target_request_count == 0
    assert current.effect_count == 0
  end

  test "routing resumes after the file receipt committed but the successor failed", context do
    {turn, run, source, reference} = file_turn!(context)
    file_decision!(turn, source, reference)

    Skopos.Repo.query!("""
    CREATE FUNCTION pg_temp.reject_file_successor() RETURNS trigger LANGUAGE plpgsql AS $$
    BEGIN
      IF NEW.event_type = 'turn_started' THEN
        RAISE EXCEPTION 'injected successor persistence failure';
      END IF;
      RETURN NEW;
    END; $$;
    """)

    Skopos.Repo.query!("""
    CREATE TRIGGER reject_file_successor BEFORE INSERT ON case_events
    FOR EACH ROW EXECUTE FUNCTION pg_temp.reject_file_successor();
    """)

    job = %Oban.Job{args: %{"turn_id" => turn.id}}
    assert {:error, _} = DecisionRouteWorker.perform(job)

    [receipt] =
      Cases.list_evidence!(actor: context.operator) |> Enum.filter(&(&1.kind == "file_read"))

    assert Enum.count(
             Cases.list_turns!(actor: context.operator),
             &(&1.resolution_run_id == run.id)
           ) == 1

    Skopos.Repo.query!("DROP TRIGGER reject_file_successor ON case_events")
    assert :ok = DecisionRouteWorker.perform(job)
    assert :ok = DecisionRouteWorker.perform(job)

    assert [^receipt] =
             Cases.list_evidence!(actor: context.operator)
             |> Enum.filter(&(&1.kind == "file_read"))

    assert Enum.count(
             Cases.list_turns!(actor: context.operator),
             &(&1.resolution_run_id == run.id)
           ) == 2

    assert Cases.get_resolution_run!(run.id, authorize?: false).ai_usage_units == 12
  end

  test "a cancelled Case cannot route a saved file-read decision", context do
    {turn, run, source, reference} = file_turn!(context)
    file_decision!(turn, source, reference)
    incident = Cases.get_case!(turn.case_id, authorize?: false)
    Cases.request_case_cancellation!(incident.id, incident.revision, actor: context.operator)
    assert :ok = DecisionRouteWorker.perform(%Oban.Job{args: %{"turn_id" => turn.id}})
    refute Enum.any?(Cases.list_evidence!(actor: context.operator), &(&1.kind == "file_read"))

    assert Enum.count(
             Cases.list_turns!(actor: context.operator),
             &(&1.resolution_run_id == run.id)
           ) == 1
  end

  test "requested file contents have priority over optional evidence within disclosure limits",
       context do
    bytes = :binary.copy(<<0>>, 8192)

    {turn, run, source, reference} =
      file_turn!(context,
        chunks: [bytes],
        sha256: "9f1dcbc35c350d6027f98be0f5c8b43b42ca52b7604459c0c42be3aa88913d47"
      )

    file_decision!(turn, source, reference)

    for index <- 1..2 do
      Cases.append_evidence!(
        turn.case_id,
        run.id,
        nil,
        "optional-long-context-#{index}",
        "observation",
        "fixture",
        "optional-#{index}",
        %{
          "target_id" => reference["target_id"],
          "facts" => %{"optional_data" => String.duplicate("x", 62000)}
        },
        DateTime.utc_now(),
        authorize?: false
      )
    end

    assert :ok = DecisionRouteWorker.perform(%Oban.Job{args: %{"turn_id" => turn.id}})

    [next] =
      Cases.list_turns!(actor: context.operator)
      |> Enum.filter(&(&1.resolution_run_id == run.id and &1.id != turn.id))

    assert :ok =
             ResolverDelivery.run(next.id,
               ai_invocation: %{
                 test_pid: self(),
                 respond: fn request ->
                   receipt = Enum.find(request.evidence, &(&1.kind == "file_read"))
                   assert receipt.content["value"] == bytes
                   assert receipt.content["encoding"] == "utf8"
                   assert AI.resolver_disclosure_size(request) <= AI.max_input_bytes()

                   assert Enum.count(
                            request.evidence,
                            &get_in(&1.content, ["facts", "optional_data"])
                          ) <= 1

                   {:ok,
                    %AI.ResolverDecision{
                      intent: %AI.TargetSearch{query: "resolver-file-host", reason: "Continue"},
                      usage: %AI.Usage{input_tokens: 7, output_tokens: 5}
                    }}
                 end
               }
             )

    assert Cases.get_turn!(next.id, authorize?: false).result["intent"]["type"] == "target_search"
  end

  test "Resolver repeating an already selected Target is charged as no progress", context do
    target =
      Targets.create_target!(
        "selected-repeat-target",
        "host",
        "linux",
        %{},
        nil,
        actor: context.admin
      )

    turn = selected_turn!("selected-repeat", context.operator, target)
    run = Cases.get_resolution_run!(turn.resolution_run_id, authorize?: false)

    candidates =
      Cases.search_case_targets!(
        turn.case_id,
        run.id,
        "selected-repeat-candidates",
        "selected-repeat-target",
        20,
        %{"action" => "find_target"},
        "Inspect registered Target",
        actor: context.operator
      )

    decision = %AI.ResolverDecision{
      intent: %AI.TargetSelection{
        target_id: target.id,
        target_revision: target.revision,
        evidence_ids: [candidates.value.id],
        reason: "Select the same Target again"
      },
      usage: %AI.Usage{input_tokens: 7, output_tokens: 5}
    }

    assert :ok =
             ResolverDelivery.run(turn.id,
               ai_invocation: %{
                 test_pid: self(),
                 respond: fn request ->
                   assert request.selected_target_id == target.id
                   assert Enum.any?(request.target_candidates, &(&1.id == target.id))
                   {:ok, decision}
                 end
               }
             )

    assert Cases.get_turn!(turn.id, authorize?: false).progress_kind == :none
    assert Cases.get_resolution_run!(run.id, authorize?: false).no_progress_turns == 1
    assert Cases.get_resolution_run!(run.id, authorize?: false).ai_usage_units == 12
  end

  test "unknown timeout reserves finite usage and requires attention", context do
    {incident, run, turn} = turn!("timeout", context.operator)

    assert :ok =
             ResolverDelivery.run(turn.id,
               ai_invocation: %{
                 test_pid: self(),
                 respond: fn _request -> {:error, :timeout, "model deadline exceeded"} end
               }
             )

    assert_receive {:resolve, %{api_key: @api_key}, _request}

    completed = Cases.get_turn!(turn.id, authorize?: false)
    assert completed.status == :completed
    assert completed.result["outcome"] == "delivery_failed"
    assert completed.result["category"] == "timeout"

    current = Cases.get_case!(incident.id, authorize?: false)
    assert current.status == :needs_attention
    assert current.stop_reason == "AI usage limit exhausted after Resolver delivery failure"

    refute Enum.any?(
             Cases.list_turns!(authorize?: false),
             &(&1.resolution_run_id == run.id and &1.status == :started)
           )

    active = Cases.get_resolution_run!(run.id, authorize?: false)
    assert active.status == :needs_attention
    assert active.ai_usage_units == 10_000

    record =
      Cases.list_ai_invocations!(authorize?: false)
      |> Enum.find(&(&1.turn_id == turn.id))

    assert record.status == :failed
    assert record.category == "timeout"
  end

  test "unclassified invalid output stops without a blind retry", context do
    {incident, run, turn} = turn!("malformed", context.operator)

    assert :ok = invalid_output(turn)
    assert_receive {:resolve, %{api_key: @api_key}, _request}

    completed = Cases.get_turn!(turn.id, authorize?: false)
    assert completed.status == :completed
    assert completed.result["outcome"] == "delivery_failed"
    assert completed.result["category"] == "invalid_output"
    assert completed.result["rejection_code"] == "invalid_output"
    assert completed.progress_kind == :human_input

    stopped_run = Cases.get_resolution_run!(run.id, authorize?: false)
    assert stopped_run.status == :needs_attention
    assert stopped_run.turn_count == 1
    assert stopped_run.ai_usage_units == 2

    current = Cases.get_case!(incident.id, authorize?: false)
    assert current.status == :needs_attention
    assert current.stop_reason =~ "invalid_output"

    assert :ok = invalid_output(turn, fn -> flunk("completed Turn called AI again") end)
    refute_receive {:resolve, _, _}

    assert Enum.count(Cases.list_turns!(authorize?: false), &(&1.resolution_run_id == run.id)) ==
             1
  end

  test "invalid per-Condition assessment records a distinct rejection without another paid call",
       context do
    {incident, run, turn} = turn!("condition-assessment-invalid", context.operator)

    assert :ok =
             invalid_output(turn, fn ->
               {:error, :invalid_output, "AI Condition assessment is invalid: citation_scope",
                %AI.Usage{input_tokens: 7, output_tokens: 5},
                "condition_assessment_citation_scope"}
             end)

    assert_receive {:resolve, %{api_key: @api_key}, _request}
    completed = Cases.get_turn!(turn.id, authorize?: false)
    assert completed.result["rejection_code"] == "condition_assessment_citation_scope"
    assert Cases.get_case!(incident.id, authorize?: false).status == :needs_attention
    assert Cases.get_resolution_run!(run.id, authorize?: false).ai_usage_units == 12

    refute Enum.any?(Cases.list_turns!(authorize?: false), fn candidate ->
             candidate.resolution_run_id == run.id and candidate.status == :started
           end)
  end

  test "one metered schema rejection gets a corrective turn on the same healthy Provider",
       context do
    {_incident, _run, turn} = turn!("schema-failover", context.operator)

    assert :ok =
             invalid_output(turn, fn ->
               {:error, :invalid_output, "Adapter rejected schema",
                %AI.Usage{input_tokens: 7, output_tokens: 5}, "schema_validation", "/intent/type"}
             end)

    assert_receive {:resolve, %{api_key: @api_key}, _request}

    successor =
      Cases.list_turns!(authorize?: false)
      |> Enum.find(&(&1.resolution_run_id == turn.resolution_run_id and &1.status == :started))

    assert successor.intent["category"] == "invalid_output"
    assert successor.intent["rejection_code"] == "schema_validation"
    assert successor.intent["rejection_path"] == "/intent/type"
    assert [%{rejection_path: "/intent/type"}] = Cases.list_ai_invocations!(authorize?: false)

    before_retry = Cases.get_case!(successor.case_id, authorize?: false)
    turn_count = length(Cases.list_turns!(authorize?: false))

    assert {:error, _reason} =
             Cases.route_resolver_failure(
               turn.id,
               "timeout",
               "schema_validation",
               "/intent/type",
               authorize?: false
             )

    assert {:ok, true} =
             Cases.route_resolver_failure(
               turn.id,
               "invalid_output",
               "schema_validation",
               "/intent/type",
               authorize?: false
             )

    assert Cases.get_case!(successor.case_id, authorize?: false).revision == before_retry.revision
    assert length(Cases.list_turns!(authorize?: false)) == turn_count

    assert Cases.get_turn!(turn.id, authorize?: false).progress_kind == :delivery_retry

    assert Cases.get_resolution_run!(turn.resolution_run_id, authorize?: false).no_progress_turns ==
             0

    assert Cases.get_resolution_run!(turn.resolution_run_id, authorize?: false).ai_usage_units ==
             12

    failed_provider = Providers.get_provider!(context.provider.id, authorize?: false)
    assert failed_provider.enabled
    assert failed_provider.check_status == :passed

    decision = %AI.ResolverDecision{
      intent: %AI.TargetSearch{query: "continue safely", reason: "Use current evidence"},
      usage: %AI.Usage{input_tokens: 2, output_tokens: 1}
    }

    assert :ok =
             ResolverDelivery.run(successor.id,
               ai_invocation: %{
                 test_pid: self(),
                 respond: fn _request -> {:ok, decision} end
               }
             )

    assert_receive {:resolve, %{api_key: @api_key}, _request}

    assignment_key = Budget.key("turn:resolver_assignment", successor.id)
    event = Cases.case_event_by_idempotency!(successor.case_id, assignment_key, authorize?: false)
    assert event.data["provider_id"] == context.provider.id
    assert event.data["assignment_id"] == context.assignment.id
  end

  test "second schema rejection stops the route without disabling the Provider",
       context do
    {incident, run, turn} = turn!("schema-no-fallback", context.operator)

    assert :ok =
             invalid_output(turn, fn ->
               {:error, :invalid_output, "AI provider JSON does not match the requested schema",
                %AI.Usage{input_tokens: 7, output_tokens: 5}, "schema_validation"}
             end)

    assert_receive {:resolve, %{api_key: @api_key}, _request}

    [successor] =
      Cases.list_turns!(authorize?: false)
      |> Enum.filter(&(&1.resolution_run_id == run.id and &1.status == :started))

    assert :ok =
             invalid_output(successor, fn ->
               {:error, :invalid_output, "AI provider JSON does not match the requested schema",
                %AI.Usage{input_tokens: 4, output_tokens: 3}, "schema_validation"}
             end)

    stopped = Cases.get_case!(incident.id, authorize?: false)
    assert stopped.status == :needs_attention
    assert Cases.get_resolution_run!(run.id, authorize?: false).status == :needs_attention
    assert Cases.get_resolution_run!(run.id, authorize?: false).ai_usage_units == 19
    assert Providers.get_provider!(context.provider.id, authorize?: false).enabled

    completed = Cases.get_turn!(turn.id, authorize?: false)
    assert completed.result["rejection_code"] == "schema_validation"

    refute Enum.any?(Cases.list_turns!(authorize?: false), fn candidate ->
             candidate.resolution_run_id == run.id and candidate.status == :started
           end)
  end

  test "one metered missing object receives a corrective turn, then stops if still missing",
       context do
    {incident, run, turn} = turn!("missing-object-correction", context.operator)

    assert :ok =
             invalid_output(turn, fn ->
               {:error, :invalid_output, "AI provider did not return a structured object",
                %AI.Usage{input_tokens: 7, output_tokens: 5}, "missing_structured_object"}
             end)

    assert_receive {:resolve, %{api_key: @api_key}, _request}

    [successor] =
      Cases.list_turns!(authorize?: false)
      |> Enum.filter(&(&1.resolution_run_id == run.id and &1.status == :started))

    assert successor.intent["rejection_code"] == "missing_structured_object"

    assert :ok =
             invalid_output(successor, fn ->
               {:error, :invalid_output, "AI provider JSON does not match the requested schema",
                %AI.Usage{input_tokens: 4, output_tokens: 3}, "schema_validation"}
             end)

    assert Cases.get_case!(incident.id, authorize?: false).status == :needs_attention
    assert Cases.get_resolution_run!(run.id, authorize?: false).ai_usage_units == 19
    refute Enum.any?(Cases.list_turns!(authorize?: false), &(&1.status == :started))
  end

  test "one metered truncated reply receives a corrective turn and stops if still truncated",
       context do
    {incident, run, turn} = turn!("truncated-limit", context.operator)

    assert :ok =
             invalid_output(turn, fn ->
               {:error, :invalid_output, "AI provider JSON was truncated",
                %AI.Usage{input_tokens: 9, output_tokens: 8}, "truncated"}
             end)

    assert Cases.get_case!(incident.id, authorize?: false).status == :running
    assert Cases.get_resolution_run!(run.id, authorize?: false).ai_usage_units == 17

    [successor] =
      Cases.list_turns!(authorize?: false)
      |> Enum.filter(&(&1.resolution_run_id == run.id and &1.status == :started))

    assert successor.intent["rejection_code"] == "truncated"

    assert :ok =
             invalid_output(successor, fn ->
               {:error, :invalid_output, "AI provider JSON was truncated",
                %AI.Usage{input_tokens: 9, output_tokens: 8}, "truncated"}
             end)

    stopped = Cases.get_case!(incident.id, authorize?: false)
    assert stopped.status == :needs_attention
    assert stopped.stop_reason == "Resolver output reached the configured token limit"
    assert stopped.required_human_input =~ "Increase this AI connection's max output tokens"
    assert Cases.get_resolution_run!(run.id, authorize?: false).ai_usage_units == 34
    assert Cases.get_turn!(turn.id, authorize?: false).result["rejection_code"] == "truncated"
    assert Enum.count(Cases.list_ai_invocations!(authorize?: false)) == 2

    refute Enum.any?(
             Cases.list_turns!(authorize?: false),
             &(&1.resolution_run_id == run.id and &1.status == :started)
           )

    assert Cases.list_proposals!(authorize?: false) == []
    assert Cases.list_operations!(authorize?: false) == []

    assert :ok =
             invalid_output(turn, fn -> flunk("completed Turn called AI again") end)

    assert Cases.get_resolution_run!(run.id, authorize?: false).ai_usage_units == 34

    refute Enum.any?(Cases.list_turns!(authorize?: false), fn candidate ->
             candidate.resolution_run_id == run.id and candidate.status == :started
           end)
  end

  test "metered invalid response above the remaining budget persists physical usage", context do
    {incident, run, turn} = turn!("metered-overrun", context.operator)
    current = Cases.get_resolution_run!(run.id, authorize?: false)

    Cases.update_resolution_run_counters!(
      current,
      current.revision,
      %{ai_usage_units: current.max_ai_usage_units - 1},
      authorize?: false
    )

    assert :ok =
             invalid_output(turn, fn ->
               {:error, :invalid_output, "AI provider output is not valid JSON",
                %AI.Usage{
                  input_tokens: 2,
                  output_tokens: 2,
                  cached_tokens: 1,
                  reasoning_tokens: 1,
                  finish_reason: "stop"
                }, "json_decode"}
             end)

    assert Cases.get_case!(incident.id, authorize?: false).status == :needs_attention
    assert Cases.get_turn!(turn.id, authorize?: false).result["rejection_code"] == "json_decode"

    assert [
             %{
               status: :failed,
               input_tokens: 2,
               output_tokens: 2,
               cached_tokens: 1,
               reasoning_tokens: 1,
               finish_reason: "stop",
               failure_code: "json_decode"
             }
           ] =
             Cases.list_ai_invocations!(authorize?: false)
  end

  test "an interrupted dispatch starts one bounded autonomous successor", context do
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
      200_000,
      current.max_no_progress_turns,
      "allow a bounded interrupted invocation retry",
      actor: context.admin
    )

    incident =
      Cases.open_case!(
        :manual,
        "test",
        "interrupted",
        "Service is unavailable",
        :critical,
        %{"desired_outcome" => "Target responds as expected"},
        nil,
        :en,
        actor: context.operator
      )

    run = Cases.active_resolution_run!(incident.id, authorize?: false)
    turn = start_turn!(incident, run, "interrupted")
    parent = self()

    task =
      Task.async(fn ->
        ResolverDelivery.run(turn.id,
          ai_invocation: %{
            test_pid: parent,
            respond: fn _request ->
              send(parent, :resolver_remote_started)
              receive do: (:never -> :unreachable)
            end
          }
        )
      end)

    assert_receive {:resolve, _, _request}, 2_000
    assert_receive :resolver_remote_started, 2_000

    assert nil == Task.shutdown(task, :brutal_kill)

    [dispatching] = Cases.list_ai_invocations!(authorize?: false)
    assert dispatching.status == :dispatching
    assert dispatching.reserved_units > 65_536
    assert dispatching.reserved_units < 200_000

    Skopos.TestAIUsage.configure!(context.provider.id, :resolver, 11, context.admin)

    assert :ok =
             ResolverDelivery.run(turn.id,
               ai_invocation: %{
                 test_pid: self(),
                 respond: fn _request -> flunk("interrupted dispatch called AI again") end
               }
             )

    refute_receive {:resolve, _, _}

    [unknown] = Cases.list_ai_invocations!(authorize?: false)
    assert unknown.id == dispatching.id
    assert unknown.status == :unknown
    assert unknown.category == "response_unknown"
    assert unknown.failure_code == "response_unknown"

    completed = Cases.get_turn!(turn.id, authorize?: false)
    assert completed.status == :completed
    assert completed.result["outcome"] == "delivery_unknown"
    assert completed.result["reserved_usage_units"] == dispatching.reserved_units
    assert completed.progress_kind == :none

    [successor] =
      Cases.list_turns!(authorize?: false)
      |> Enum.filter(&(&1.resolution_run_id == run.id and &1.status == :started))

    assert successor.intent == %{
             "ai_invocation_id" => unknown.id,
             "objective" => "Continue resolution after a lost Resolver response",
             "source" => "resolver_delivery_interruption",
             "source_turn_id" => turn.id
           }

    running = Cases.get_case!(incident.id, authorize?: false)
    assert running.status == :running
    assert running.required_human_input == nil

    assert running.pending_intent == %{
             "action" => "resolve_turn",
             "turn_id" => successor.id,
             "source_turn_id" => turn.id
           }

    assert Cases.get_resolution_run!(run.id, authorize?: false).ai_usage_units ==
             dispatching.reserved_units

    assert :ok =
             ResolverDelivery.run(turn.id,
               ai_invocation: %{
                 test_pid: self(),
                 respond: fn _request -> flunk("unknown dispatch called AI again") end
               }
             )

    events = Cases.list_case_events!(actor: context.admin)

    assert Enum.count(events, fn event ->
             event.data["request_key"] == "resolver-unknown:#{unknown.id}"
           end) == 1

    assert Enum.count(Cases.list_turns!(authorize?: false), &(&1.resolution_run_id == run.id)) ==
             2
  end

  test "a competing Turn completion still accounts for the later AI result", context do
    {_incident, run, turn} = turn!("competing-result", context.operator)

    ai_invocation = %{
      test_pid: self(),
      respond: fn _request ->
        Cases.complete_turn!(
          turn.id,
          turn.revision,
          %{"outcome" => "already_accepted"},
          :hypothesis,
          %{"action" => "route_resolver_decision", "turn_id" => turn.id},
          "Review the accepted result",
          authorize?: false
        )

        {:ok,
         %AI.ResolverDecision{
           intent: %AI.Handoff{reason: "Competing response", required_input: "Review"},
           usage: %AI.Usage{input_tokens: 10, output_tokens: 10}
         }}
      end
    }

    assert :ok = ResolverDelivery.run(turn.id, ai_invocation: ai_invocation)
    assert_receive {:resolve, _, _}

    completed = Cases.get_turn!(turn.id, authorize?: false)
    assert completed.result == %{"outcome" => "already_accepted"}
    assert Cases.get_resolution_run!(run.id, authorize?: false).ai_usage_units == 20

    [invocation] = Cases.list_ai_invocations!(authorize?: false)
    assert invocation.status == :completed
    assert invocation.category == "superseded"
    assert route_jobs(turn.id) == []
  end

  test "cancelled Case stops before AI dispatch", context do
    {incident, _run, turn} = turn!("cancelled", context.operator)
    Cases.request_case_cancellation!(incident.id, incident.revision, actor: context.operator)

    assert {:cancel, "Case resolution was cancelled"} =
             ResolverDelivery.run(turn.id,
               ai_invocation: %{
                 test_pid: self(),
                 respond: fn _request -> flunk("cancelled Case called AI") end
               }
             )

    assert Cases.get_turn!(turn.id, authorize?: false).status == :started
    refute_receive {:resolve, _, _}
  end

  test "accepted observation and Proposal retain exact offered tool snapshots", context do
    {target, method} = target_context!(context.admin)

    observation_turn = selected_turn!("observation-snapshot", context.operator, target)

    assert :ok =
             ResolverDelivery.run(observation_turn.id,
               ai_invocation: %{
                 test_pid: self(),
                 respond: fn request ->
                   tool = Enum.find(request.proposal_tools, &(&1.request_kind == :observation))

                   {:ok,
                    %AI.ResolverDecision{
                      intent: %AI.Proposal{
                        tool_id: tool.id,
                        target_id: tool.target_id,
                        target_revision: tool.target_revision,
                        access_method_id: tool.access_method_id,
                        access_method_revision: tool.access_method_revision,
                        request_kind: :observation,
                        purpose: :investigation,
                        capability: tool.capability,
                        operation: tool.operation,
                        selectors: %{"path" => "/var/log/messages"},
                        parameters: %{"path" => "/var/log/messages"},
                        reason: "Inspect the current error source",
                        evidence_ids: []
                      },
                      usage: %AI.Usage{input_tokens: 2, output_tokens: 3}
                    }}
                 end
               }
             )

    observation_intent = Cases.get_turn!(observation_turn.id, authorize?: false).result["intent"]
    assert observation_intent["type"] == "proposal"
    assert observation_intent["request_kind"] == "observation"
    assert observation_intent["selectors"] == %{"path" => "/var/log/messages"}
    assert observation_intent["tool"]["target_id"] == target.id
    assert observation_intent["tool"]["target_revision"] == target.revision
    assert observation_intent["tool"]["access_method_id"] == method.id
    assert observation_intent["tool"]["access_method_revision"] == method.revision
    assert observation_intent["tool"]["provider_id"] == method.provider_id
    assert observation_intent["tool"]["provider_revision"] == method.provider_revision
    assert observation_intent["tool"]["request_kind"] == "observation"
    assert observation_intent["tool"]["capability"] == "observe.system"
    assert observation_intent["tool"]["operation"] == "system.inspect"

    proposal_case =
      Cases.open_case!(
        :manual,
        "test",
        "proposal-snapshot",
        "Case proposal-snapshot",
        :warning,
        %{"desired_outcome" => "Target responds as expected"},
        target.id,
        :en,
        actor: context.operator
      )

    proposal_run = Cases.active_resolution_run!(proposal_case.id, authorize?: false)

    evidence =
      Cases.append_evidence!(
        proposal_case.id,
        proposal_run.id,
        nil,
        "proposal-snapshot-evidence",
        "observation",
        "fixture",
        "observation-1",
        %{"target_id" => target.id, "service" => "unhealthy"},
        DateTime.utc_now(),
        authorize?: false
      )

    proposal_turn = start_turn!(proposal_case, proposal_run, "proposal-snapshot")

    assert :ok =
             ResolverDelivery.run(proposal_turn.id,
               ai_invocation: %{
                 test_pid: self(),
                 respond: fn request ->
                   proposal_tool =
                     Enum.find(request.proposal_tools, &(&1.request_kind == :effect))

                   [observation_tool] = request.observation_tools

                   {:ok,
                    %AI.ResolverDecision{
                      intent: %AI.Proposal{
                        tool_id: proposal_tool.id,
                        target_id: proposal_tool.target_id,
                        target_revision: proposal_tool.target_revision,
                        access_method_id: proposal_tool.access_method_id,
                        access_method_revision: proposal_tool.access_method_revision,
                        request_kind: :effect,
                        purpose: :remediation,
                        capability: proposal_tool.capability,
                        operation: proposal_tool.operation,
                        selectors: %{"service" => "api"},
                        parameters: %{
                          "service" => "api",
                          "enabled" => true,
                          "expected_enabled" => false,
                          "optional" => nil
                        },
                        reason: "Restart the unhealthy service",
                        evidence_ids: [evidence.id],
                        expected_result: %{"service" => "running"},
                        verification_intent: %AI.VerificationIntent{
                          tool_id: observation_tool.id,
                          selectors: %{"service" => "api"},
                          parameters: %{"service" => "api"},
                          expected_result: %{"service" => "running"}
                        }
                      },
                      usage: %AI.Usage{input_tokens: 3, output_tokens: 4}
                    }}
                 end
               }
             )

    proposal_intent = Cases.get_turn!(proposal_turn.id, authorize?: false).result["intent"]
    assert proposal_intent["type"] == "proposal"
    assert proposal_intent["selectors"] == %{"service" => "api"}

    assert proposal_intent["parameters"] == %{
             "service" => "api",
             "enabled" => true,
             "expected_enabled" => false,
             "optional" => nil
           }

    assert proposal_intent["tool"]["provider_id"] == method.provider_id
    assert proposal_intent["tool"]["provider_revision"] == method.provider_revision
    assert proposal_intent["tool"]["request_kind"] == "effect"

    assert proposal_intent["verification_intent"]["selectors"] == %{
             "service" => "api"
           }

    assert proposal_intent["verification_tool"]["id"] =~ "observation:"
    assert proposal_intent["verification_tool"]["access_method_id"] == method.id
    assert proposal_intent["verification_tool"]["provider_id"] == method.provider_id
    assert proposal_intent["verification_tool"]["provider_revision"] == method.provider_revision
    assert proposal_intent["verification_tool"]["operation"] == "system.inspect"
  end

  test "accepted relationship snapshot reaches the durable related Target route", context do
    {linux, linux_method} = target_context!(context.admin)

    vm =
      Targets.create_target!(
        "snapshot-vm",
        "virtual_machine",
        "custom-vm",
        %{},
        nil,
        actor: context.admin
      )

    vm_method =
      Targets.create_access_method!(
        vm.id,
        linux_method.provider_id,
        "snapshot-vm-ssh",
        "ssh",
        "ssh://snapshot-vm",
        linux_method.provider_revision,
        10,
        ["observe.system"],
        actor: context.admin
      )
      |> then(&Targets.check_access_method!(&1.id, &1.revision, %{}, actor: context.admin))

    relationship =
      Targets.create_relationship!(linux.id, vm.id, "runs_on", %{}, nil, actor: context.admin)

    incident =
      Cases.open_case!(
        :manual,
        "test",
        "relationship-snapshot",
        "Investigate Linux I/O errors",
        :critical,
        %{"desired_outcome" => "Target responds as expected"},
        linux.id,
        :en,
        actor: context.operator
      )

    run = Cases.active_resolution_run!(incident.id, authorize?: false)

    evidence =
      Cases.append_evidence!(
        incident.id,
        run.id,
        nil,
        "relationship-snapshot-evidence",
        "observation",
        "fixture",
        "io-errors",
        %{"target_id" => linux.id, "io_errors" => 12},
        DateTime.utc_now(),
        authorize?: false
      )

    turn = start_turn!(incident, run, "relationship-snapshot")

    assert :ok =
             ResolverDelivery.run(turn.id,
               ai_invocation: %{
                 test_pid: self(),
                 respond: fn request ->
                   [offered] = request.target_relations

                   assert offered.id == relationship.id
                   assert offered.revision == relationship.revision
                   assert offered.source_target.id == linux.id
                   assert offered.destination_target.id == vm.id

                   {:ok,
                    %AI.ResolverDecision{
                      intent: %AI.TargetTraversal{
                        relationship_id: offered.id,
                        relationship_revision: offered.revision,
                        next_target_id: offered.destination_target.id,
                        next_target_revision: offered.destination_target.revision,
                        evidence_ids: [evidence.id],
                        reason: "The I/O evidence implicates the VM layer"
                      },
                      usage: %AI.Usage{input_tokens: 4, output_tokens: 3}
                    }}
                 end
               }
             )

    completed = Cases.get_turn!(turn.id, authorize?: false)
    intent = completed.result["intent"]
    assert intent["type"] == "target_traversal"
    assert intent["relationship"]["id"] == relationship.id
    assert intent["relationship"]["revision"] == relationship.revision
    assert intent["relationship"]["source_target_revision"] == linux.revision
    assert intent["relationship"]["destination_target_revision"] == vm.revision

    assert :ok = DecisionRouteWorker.perform(%Oban.Job{args: %{"turn_id" => turn.id}})

    selected = Cases.get_case!(incident.id, authorize?: false)
    assert selected.selected_target_id == vm.id
    assert Cases.get_resolution_run!(run.id, authorize?: false).related_target_count == 1

    [event] =
      Cases.list_case_events!(actor: context.admin)
      |> Enum.filter(&(&1.event_type == "related_target_traversed"))

    assert event.data["relationship_id"] == relationship.id
    assert event.data["next_target_id"] == vm.id

    assert [available_method] =
             Targets.available_access_methods_for_target!(vm.id, authorize?: false)

    assert available_method.id == vm_method.id
  end

  defp file_turn!(context, opts \\ []) do
    chunks = Keyword.get(opts, :chunks, [<<255, 0>>, <<1, 2, 255>>])

    sha256 =
      Keyword.get(
        opts,
        :sha256,
        "b55f1659c0645fd1cee6dfa8b3af06795e9da7e48cb65c2b999f896c9f539dbd"
      )

    target =
      Targets.create_target!("resolver-file-host", "host", "custom-os", %{}, nil,
        actor: context.admin
      )

    turn = selected_turn!("file-inspection", context.operator, target)
    run = Cases.get_resolution_run!(turn.resolution_run_id, authorize?: false)

    upload =
      Targets.begin_artifact!(
        target.id,
        "native-response.bin",
        "application/octet-stream",
        Enum.sum(Enum.map(chunks, &byte_size/1)),
        sha256,
        "resolver-file",
        actor: context.operator
      )

    Enum.reduce(chunks, 0, fn bytes, offset ->
      Targets.append_artifact_chunk!(upload.id, offset, bytes, actor: context.operator)
      offset + byte_size(bytes)
    end)

    Targets.complete_artifact!(upload.id, actor: context.operator)
    reference = Targets.artifact_reference!(upload.id, target.id, actor: context.operator)

    source =
      Cases.append_evidence!(
        turn.case_id,
        run.id,
        nil,
        "resolver-native-file",
        "observation",
        "fixture",
        "native-response",
        %{
          "target_id" => target.id,
          "status" => "applied",
          "facts" => %{"steps" => [%{"file" => reference}]}
        },
        DateTime.utc_now(),
        authorize?: false
      )

    {turn, run, source, reference}
  end

  defp file_decision!(turn, source, reference) do
    assert :ok =
             ResolverDelivery.run(turn.id,
               ai_invocation: %{
                 test_pid: self(),
                 respond: fn _request ->
                   {:ok,
                    %AI.ResolverDecision{
                      intent: %AI.FileRead{
                        source_evidence_id: source.id,
                        reference: reference,
                        offset: 0,
                        length: reference["size_bytes"],
                        reason: "Inspect the response"
                      },
                      usage: %AI.Usage{input_tokens: 7, output_tokens: 5}
                    }}
                 end
               }
             )
  end

  defp turn!(source_ref, actor) do
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

    run = Cases.active_resolution_run!(incident.id, authorize?: false)

    started =
      Cases.start_turn!(
        incident.id,
        run.id,
        "turn-#{source_ref}",
        %{"objective" => "Resolve the incident"},
        %{"action" => "continue"},
        "Review Resolver limits",
        authorize?: false
      )

    {incident, run, started.value}
  end

  defp selected_turn!(source_ref, actor, target) do
    incident =
      Cases.open_case!(
        :manual,
        "test",
        source_ref,
        "Case #{source_ref}",
        :warning,
        %{"desired_outcome" => "Target responds as expected"},
        target.id,
        :en,
        actor: actor
      )

    run = Cases.active_resolution_run!(incident.id, authorize?: false)
    start_turn!(incident, run, source_ref)
  end

  defp start_turn!(incident, run, key) do
    Cases.start_turn!(
      incident.id,
      run.id,
      "turn-#{key}",
      %{"objective" => "Resolve the incident"},
      %{"action" => "continue"},
      "Review Resolver limits",
      authorize?: false
    ).value
  end

  defp target_context!(admin) do
    provider =
      Providers.create_provider!(
        "snapshot-target-provider",
        :target,
        "fixture-target",
        %{"endpoint" => "reachable"},
        %{"token" => "snapshot-target-secret"},
        actor: admin
      )
      |> then(&Providers.enable_provider!(&1, 1, actor: admin))

    target =
      Targets.create_target!("snapshot-linux", "host", "linux", %{}, nil, actor: admin)

    method =
      Targets.create_access_method!(
        target.id,
        provider.id,
        "snapshot-ssh",
        "ssh",
        "ssh://snapshot",
        provider.revision,
        10,
        ["observe.system", "effect.service"],
        actor: admin
      )
      |> then(&Targets.check_access_method!(&1.id, &1.revision, %{}, actor: admin))

    capabilities = %Target.Capabilities{
      observations: [
        %Target.Operation{
          capability: "observe.system",
          operation: "system.inspect",
          description: "Inspect system state",
          input_schema: %{"type" => "object"},
          output_schema: %{
            "type" => "object",
            "properties" => %{"status" => %{"type" => "string"}},
            "additionalProperties" => false
          },
          verification_schema: %{
            "type" => "object",
            "properties" => %{"service" => %{"type" => "string"}},
            "minProperties" => 1,
            "additionalProperties" => false
          }
        }
      ],
      effects: [
        %Target.Operation{
          capability: "effect.service",
          operation: "service.restart",
          description: "Restart one service",
          input_schema: %{"type" => "object"}
        }
      ]
    }

    method =
      Targets.check_access_method!(
        method.id,
        method.revision,
        %{respond: fn -> {:ok, capabilities} end},
        actor: admin
      )

    {target, method}
  end

  defp invalid_output(
         turn,
         callback \\ fn ->
           {:error, :invalid_output, "AI output is invalid",
            %AI.Usage{input_tokens: 1, output_tokens: 1}}
         end
       ) do
    ResolverDelivery.run(turn.id,
      ai_invocation: %{
        test_pid: self(),
        respond: fn _request -> callback.() end
      }
    )
  end

  defp route_jobs(turn_id) do
    from(job in Oban.Job,
      where:
        job.worker == ^Oban.Worker.to_string(DecisionRouteWorker) and
          fragment("?->>'turn_id'", job.args) == ^turn_id
    )
    |> Skopos.Repo.all()
  end
end
