defmodule Skopos.Providers.AITest do
  use Skopos.DataCase, async: false

  alias Skopos.Accounts
  alias Skopos.Providers
  alias Skopos.Providers.{AI, Target}

  @password "correct horse battery staple"
  @api_key "ai-provider-secret"

  setup do
    admin = Accounts.bootstrap!("ai-admin@example.com", @password, @password, authorize?: true)

    operator =
      Accounts.create_user!("ai-operator@example.com", @password, :operator, actor: admin)

    provider = create_ai_provider!(admin, "ai-provider", "test-model")

    %{admin: admin, operator: operator, provider: provider}
  end

  test "mixed errors preserve AI usage without classifying the whole error as an AI failure" do
    native =
      AI.Error.exception(
        category: :invalid_output,
        message: "Decision was invalid",
        usage: %AI.Usage{input_tokens: 23, output_tokens: 11},
        dispatched?: true,
        failure_path: "/intent"
      )

    nested = Ash.Error.Unknown.exception(errors: [Ash.Error.Unknown.exception(errors: [native])])
    assert AI.Error.unwrap(native) == native
    assert AI.Error.unwrap(nested) == native

    storage = Ash.Error.Unknown.UnknownError.exception(error: "Database temporarily unavailable")

    for errors <- [[storage, nested], [nested, storage]] do
      mixed = Ash.Error.Unknown.exception(errors: errors)
      assert AI.Error.unwrap(mixed) == nil
      assert AI.Error.context_failure?(mixed)

      invalid =
        Ash.Error.Invalid.exception(
          errors: [
            Ash.Error.Action.InvalidArgument.exception(
              field: :request,
              message: "Invalid request"
            ),
            mixed
          ]
        )

      assert AI.Error.context_failure?(invalid)

      classified = Ash.Error.to_error_class([native, storage, hd(invalid.errors)])
      assert %Ash.Error.Invalid{} = classified
      assert AI.Error.context_failure?(classified)

      read_failure = Ash.Error.to_error_class([native, hd(invalid.errors)])
      assert %Ash.Error.Invalid{} = read_failure
      assert AI.Error.context_failure?(read_failure)
      assert AI.Error.unwrap(read_failure) == nil

      assert %{amount: 34, usage: %AI.Usage{}, dispatched?: true} =
               Skopos.Cases.AIInvocation.failure_accounting(read_failure, 65_536)

      assert %{amount: 34, usage: %AI.Usage{}, dispatched?: true} =
               Skopos.Cases.AIInvocation.failure_accounting(mixed, 65_536)

      assert Skopos.Cases.AIInvocation.rejection_path(mixed) == "/intent"
    end

    assert AI.Error.unwrap(Ash.Error.Framework.exception(errors: [native])) == nil
    refute AI.Error.context_failure?(native)
    refute AI.Error.context_failure?(nested)

    refute AI.Error.context_failure?(
             Ash.Error.Action.InvalidArgument.exception(
               field: :request,
               message: "Invalid request"
             )
           )
  end

  test "an effect on a firing Condition survives a recovered peer but stale or foreign claims do not" do
    conditions = [
      %AI.Condition{
        id: "linux-condition",
        revision: 4,
        occurrence: 1,
        predicate: "Linux endpoint unavailable",
        subject_key: "linux",
        subject_ref: %{},
        state: :recovered,
        target_id: "linux-target",
        current_occurred_at_us: 10
      },
      %AI.Condition{
        id: "kubernetes-condition",
        revision: 7,
        occurrence: 1,
        predicate: "Deployment unavailable",
        subject_key: "deployment",
        subject_ref: %{},
        state: :firing,
        target_id: "kubernetes-target",
        current_occurred_at_us: 20
      }
    ]

    claim = %{"condition_id" => "kubernetes-condition", "revision" => 7}
    assert AI.valid_affected_conditions?(:effect, [claim], conditions, [])
    refute AI.valid_affected_conditions?(:effect, [], conditions, [])
    refute AI.valid_affected_conditions?(:effect, [claim, claim], conditions, [])
    refute AI.valid_affected_conditions?(:effect, [%{claim | "revision" => 6}], conditions, [])

    for id <- ["linux-condition", "foreign-condition"] do
      refute AI.valid_affected_conditions?(
               :effect,
               [%{"condition_id" => id, "revision" => 4}],
               conditions,
               []
             )
    end

    assert AI.valid_affected_conditions?(:observation, [], conditions, [])
    assert AI.valid_affected_conditions?(:observation, [claim], conditions, [])

    assert AI.valid_affected_conditions?(
             :observation,
             [%{"condition_id" => "linux-condition", "revision" => 4}],
             conditions,
             []
           )

    refute AI.valid_affected_conditions?(:observation, [claim, claim], conditions, [])

    refute AI.valid_affected_conditions?(
             :observation,
             [%{claim | "revision" => 6}],
             conditions,
             []
           )

    refute AI.valid_affected_conditions?(
             :observation,
             [%{"condition_id" => "foreign", "revision" => 7}],
             conditions,
             []
           )
  end

  test "a recovered Condition needs a currently eligible cited observation for an effect" do
    condition = %AI.Condition{
      id: "cron-condition",
      revision: 2,
      occurrence: 1,
      predicate: "cron inactive",
      subject_key: "cron.service",
      subject_ref: %{},
      state: :recovered,
      target_id: "linux-target",
      current_occurred_at_us: 20,
      recovery_status: :ready_for_review,
      recovery_evidence_ids: ["cron-inspect"]
    }

    claim = %{"condition_id" => condition.id, "revision" => condition.revision}

    assert AI.valid_affected_conditions?(:effect, [claim], [condition], ["cron-inspect"])
    refute AI.valid_affected_conditions?(:effect, [claim], [condition], ["unrelated"])

    refute AI.valid_affected_conditions?(
             :effect,
             [claim],
             [%{condition | recovery_status: :needs_observation}],
             ["cron-inspect"]
           )

    refute AI.valid_affected_conditions?(
             :effect,
             [claim],
             [%{condition | revision: 3}],
             ["cron-inspect"]
           )
  end

  test "Resolver may cite an earlier current observation when the newest one is unrelated",
       context do
    direct = %AI.Evidence{
      id: "direct-endpoint",
      kind: "observation",
      target_id: "target-1",
      observed_at_us: 20,
      content: %{"status" => "applied", "facts" => %{"endpoint_up" => true}}
    }

    unrelated = %AI.Evidence{
      id: "newer-identity",
      kind: "observation",
      target_id: "target-1",
      observed_at_us: 21,
      content: %{"status" => "applied", "facts" => %{"machine_id" => "guest"}}
    }

    condition = %AI.Condition{
      id: "endpoint-condition",
      revision: 2,
      occurrence: 1,
      predicate: "Endpoint unavailable",
      subject_key: "endpoint",
      subject_ref: %{},
      state: :recovered,
      target_id: "target-1",
      current_occurred_at_us: 19,
      recovery_status: :ready_for_review,
      recovery_evidence_ids: [unrelated.id, direct.id]
    }

    request = %{
      resolver_request(context.provider.revision)
      | alert_state: :recovered,
        conditions: [condition],
        evidence: [unrelated, direct],
        recovery_evidence_ids: [unrelated.id, direct.id]
    }

    conclusion = %AI.RecoveryConclusion{
      reason: "The direct endpoint observation supports the recovered source event",
      evidence_ids: [direct.id],
      condition_claims: [
        %{
          "condition_id" => condition.id,
          "revision" => condition.revision,
          "evidence_id" => direct.id,
          "reason" => "The endpoint itself responded"
        }
      ]
    }

    assert %AI.ResolverDecision{intent: ^conclusion} =
             resolve!(context, request, fn _request ->
               {:ok, %AI.ResolverDecision{intent: conclusion, usage: usage()}}
             end)

    stale =
      put_in(conclusion.condition_claims, [
        %{
          "condition_id" => condition.id,
          "revision" => 1,
          "evidence_id" => direct.id,
          "reason" => "The endpoint itself responded"
        }
      ])

    assert {:error, _error} =
             resolve(context, request, fn _request ->
               {:ok, %AI.ResolverDecision{intent: stale, usage: usage()}}
             end)
  end

  test "recovered source permits still-failing and unknown assessments without closure",
       context do
    evidence = %AI.Evidence{
      id: "endpoint-down",
      kind: "observation",
      target_id: "target-1",
      observed_at_us: 20,
      content: %{"status" => "applied", "facts" => %{"endpoint_up" => false}}
    }

    condition = %AI.Condition{
      id: "endpoint-condition",
      revision: 2,
      occurrence: 1,
      predicate: "Endpoint unavailable",
      subject_key: "endpoint",
      subject_ref: %{},
      state: :recovered,
      target_id: "target-1",
      current_occurred_at_us: 19,
      recovery_status: :ready_for_review,
      recovery_evidence_ids: [evidence.id]
    }

    request = %{
      resolver_request(context.provider.revision)
      | alert_state: :recovered,
        conditions: [condition],
        evidence: [evidence],
        recovery_evidence_ids: [evidence.id]
    }

    handoff = %AI.Handoff{
      reason: "Monitoring recovered, but the endpoint observation still shows failure",
      required_input: "Check the monitoring rule and endpoint"
    }

    claim = %{
      "condition_id" => condition.id,
      "revision" => condition.revision,
      "status" => "still_failing",
      "evidence_ids" => [evidence.id],
      "reason" => "The endpoint still fails"
    }

    decision = %AI.ResolverDecision{
      intent: handoff,
      condition_assessments: [claim],
      usage: usage()
    }

    assert %AI.ResolverDecision{condition_assessments: [^claim]} =
             resolve!(context, request, fn _request -> {:ok, decision} end)

    unknown = %{claim | "status" => "unknown", "evidence_ids" => []}

    assert %AI.ResolverDecision{condition_assessments: [^unknown]} =
             resolve!(context, request, fn _request ->
               {:ok, %{decision | condition_assessments: [unknown]}}
             end)

    for invalid <- [%{claim | "revision" => 1}, %{claim | "evidence_ids" => ["unseen"]}] do
      assert {:error, _error} =
               resolve(context, request, fn _request ->
                 {:ok, %{decision | condition_assessments: [invalid]}}
               end)
    end

    recovery = %AI.RecoveryConclusion{
      reason: "Recovered",
      evidence_ids: [evidence.id],
      condition_claims: [
        %{
          "condition_id" => condition.id,
          "revision" => condition.revision,
          "evidence_id" => evidence.id,
          "reason" => "Endpoint recovered"
        }
      ]
    }

    assert {:error, _error} =
             resolve(context, request, fn _request ->
               {:ok, %{decision | intent: recovery}}
             end)

    matching = %{claim | "status" => "recovered", "reason" => "Cited current observation"}

    assert %AI.ResolverDecision{condition_assessments: [^matching]} =
             resolve!(context, request, fn _request ->
               {:ok, %{decision | intent: recovery, condition_assessments: [matching]}}
             end)
  end

  test "advisory assessments may cover one of several current Conditions", context do
    conditions =
      for index <- 1..2 do
        %AI.Condition{
          id: "condition-#{index}",
          revision: index,
          occurrence: 1,
          predicate: "Endpoint unavailable",
          subject_key: "endpoint-#{index}",
          subject_ref: %{},
          state: :recovered,
          target_id: "target-1",
          current_occurred_at_us: 10,
          recovery_status: :ready_for_review,
          recovery_evidence_ids: ["observation-#{index}"]
        }
      end

    evidence =
      for index <- 1..2 do
        %AI.Evidence{
          id: "observation-#{index}",
          kind: "observation",
          target_id: "target-1",
          observed_at_us: 11,
          content: %{"status" => "applied", "facts" => %{"endpoint_up" => false}}
        }
      end

    request = %{
      resolver_request(context.provider.revision)
      | alert_state: :recovered,
        conditions: conditions,
        evidence: evidence,
        recovery_evidence_ids: Enum.map(evidence, & &1.id)
    }

    partial = %{
      "condition_id" => "condition-1",
      "revision" => 1,
      "status" => "still_failing",
      "evidence_ids" => ["observation-1"],
      "reason" => "This endpoint remains unavailable"
    }

    decision = %AI.ResolverDecision{
      intent: %AI.Handoff{reason: "Investigate the other endpoint", required_input: "Observe it"},
      condition_assessments: [partial],
      usage: usage()
    }

    assert %AI.ResolverDecision{condition_assessments: [^partial]} =
             resolve!(context, request, fn _request -> {:ok, decision} end)

    for invalid_assessments <- [
          [partial, partial],
          [%{partial | "condition_id" => "unrelated"}],
          [%{partial | "revision" => 99}],
          [%{partial | "evidence_ids" => ["observation-2"]}]
        ] do
      assert {:error, _error} =
               resolve(context, request, fn _request ->
                 {:ok, %{decision | condition_assessments: invalid_assessments}}
               end)
    end
  end

  test "Condition group hints never invent, overlap, or silently omit a Condition" do
    conditions = Enum.map(~w(a b c d), &%{id: &1})
    evidence = [%{id: "observed-switch"}]

    groups = [
      %{
        "condition_ids" => ~w(a b),
        "assessment" => "related",
        "reason" => "Both ports lost PoE after the same switch observation",
        "evidence_ids" => ["observed-switch"]
      },
      %{
        "condition_ids" => ~w(b c),
        "assessment" => "independent",
        "reason" => "Overlaps a prior group",
        "evidence_ids" => ["observed-switch"]
      },
      %{
        "condition_ids" => ~w(d unknown-id),
        "assessment" => "related",
        "reason" => "Invented Condition",
        "evidence_ids" => ["observed-switch"]
      },
      %{
        "condition_ids" => ["c"],
        "assessment" => "independent",
        "reason" => "No current Evidence",
        "evidence_ids" => []
      }
    ]

    assert [accepted, unknown_c, unknown_d] =
             AI.normalize_condition_groups(groups, conditions, evidence)

    assert accepted["assessment"] == "related"
    assert accepted["condition_ids"] == ~w(a b)

    assert unknown_c == %{
             "condition_ids" => ["c"],
             "assessment" => "unknown",
             "reason" => nil,
             "evidence_ids" => []
           }

    assert unknown_d["condition_ids"] == ["d"]
    assert unknown_d["assessment"] == "unknown"
  end

  test "autonomous Case split requires current direct observations for both scopes", context do
    conditions =
      for {id, target_id} <- [{"poe", "target-1"}, {"core", "target-2"}] do
        %AI.Condition{
          id: id,
          revision: 1,
          occurrence: 1,
          predicate: "unavailable",
          subject_key: id,
          subject_ref: %{},
          state: :firing,
          target_id: target_id,
          current_occurred_at_us: 10
        }
      end

    sources =
      Enum.map(conditions, fn condition ->
        %AI.Evidence{
          id: "source-#{condition.id}",
          kind: "signal_event",
          target_id: condition.target_id,
          observed_at_us: 11,
          content: %{"status" => "firing"}
        }
      end)

    request = %{
      resolver_request(context.provider.revision)
      | conditions: conditions,
        evidence: sources,
        disclosure: %{
          resolver_request(context.provider.revision).disclosure
          | allowed_evidence_kinds: ["signal_event", "observation"]
        }
    }

    source_only = %AI.CaseSplit{
      condition_ids: ["core"],
      evidence_ids: ["source-core"],
      remaining_evidence_ids: ["source-poe"],
      reason: "Investigate separately"
    }

    assert {:error, rejected} =
             resolve(context, request, fn _request ->
               {:ok, %AI.ResolverDecision{intent: source_only, usage: usage()}}
             end)

    assert ai_error(rejected).category == :invalid_output

    observations =
      Enum.map(conditions, fn condition ->
        %AI.Evidence{
          id: "observed-#{condition.id}",
          kind: "observation",
          target_id: condition.target_id,
          observed_at_us: 12,
          content: %{"status" => "applied", "facts" => %{"reachability" => "down"}}
        }
      end)

    observed_request = %{request | evidence: sources ++ observations}

    observed_split = %{
      source_only
      | evidence_ids: ["observed-core"],
        remaining_evidence_ids: ["observed-poe"]
    }

    assert %AI.ResolverDecision{intent: ^observed_split} =
             resolve!(context, observed_request, fn _request ->
               {:ok, %AI.ResolverDecision{intent: observed_split, usage: usage()}}
             end)
  end

  test "one AI provider carries resolver and reviewer roles without connection duplication",
       context do
    resolver = assign!(context.admin, context.provider, :resolver, 20)
    reviewer = assign!(context.admin, context.provider, :reviewer, 10)

    assert resolver.provider_id == reviewer.provider_id
    assert resolver.role == :resolver
    assert reviewer.role == :reviewer

    for assignment <- Providers.list_ai_usage_role_assignments!(actor: context.admin) do
      fields = Map.from_struct(assignment)
      refute Map.has_key?(fields, :configuration)
      refute Map.has_key?(fields, :credentials)
    end

    assert {:error, _error} =
             Providers.configure_ai_usage(context.provider.id, :resolver, 30, nil, nil,
               actor: context.admin
             )

    target_provider =
      Providers.create_provider!(
        "not-ai",
        :target,
        "fixture-target",
        %{"endpoint" => "reachable"},
        %{"token" => "target-token"},
        actor: context.admin
      )

    assert {:error, wrong_kind} =
             Providers.configure_ai_usage(target_provider.id, :reviewer, 10, nil, nil,
               actor: context.admin
             )

    assert Exception.message(wrong_kind) =~ "only AI connections have usage roles"
  end

  @tag ai_role_selection_read_fault: true
  test "role selection preserves a storage read failure instead of reporting no eligible AI",
       context do
    Skopos.TestAIUsage.configure!(context.provider.id, :all, 10, context.admin)

    Repo.query!(
      "ALTER TABLE ai_usage_role_assignments RENAME COLUMN priority TO unavailable_priority"
    )

    try do
      for result <- [
            Providers.select_resolver_ai(actor: context.operator),
            Providers.select_reviewer_ai([], actor: context.operator)
          ] do
        assert {:error, error} = result
        assert Exception.message(error) =~ "undefined_column"
        refute Exception.message(error) =~ "AI usage role selection failed"
      end
    after
      Repo.query!(
        "ALTER TABLE ai_usage_role_assignments RENAME COLUMN unavailable_priority TO priority"
      )
    end

    assert Providers.select_resolver_ai!(actor: context.operator).provider_id ==
             context.provider.id

    assert Providers.select_reviewer_ai!([], actor: context.operator).provider_id ==
             context.provider.id

    Providers.disable_provider!(context.provider, context.provider.revision, actor: context.admin)

    for {result, role} <- [
          {Providers.select_resolver_ai(actor: context.operator), "Resolver"},
          {Providers.select_reviewer_ai([], actor: context.operator), "Reviewer"}
        ] do
      assert {:error, error} = result
      assert Exception.message(error) =~ "No eligible #{role} AI is assigned"
    end
  end

  test "selection uses role assignments and never borrows a Resolver for review",
       context do
    resolver_assignment = assign!(context.admin, context.provider, :resolver, 50)
    reviewer_provider = create_ai_provider!(context.admin, "reviewer-provider", "review-model")
    reviewer_assignment = assign!(context.admin, reviewer_provider, :reviewer, 10)
    backup_reviewer = create_ai_provider!(context.admin, "backup-reviewer", "backup-model")
    assign!(context.admin, backup_reviewer, :reviewer, 20)

    assert %AI.Selection{
             role: :resolver,
             provider_id: resolver_id,
             provider_revision: resolver_revision,
             source: :assignment,
             assignment_id: resolver_assignment_id
           } = Providers.select_resolver_ai!(actor: context.operator)

    assert resolver_id == context.provider.id
    assert resolver_revision == context.provider.revision
    assert resolver_assignment_id == resolver_assignment.id

    assert %AI.Selection{
             role: :reviewer,
             provider_id: reviewer_id,
             source: :assignment,
             assignment_id: reviewer_assignment_id
           } =
             Providers.select_reviewer_ai!([], actor: context.operator)

    assert reviewer_id == reviewer_provider.id
    assert reviewer_assignment_id == reviewer_assignment.id

    assert %AI.Selection{provider_id: backup_id, source: :assignment} =
             Providers.select_reviewer_ai!([reviewer_provider.id], actor: context.operator)

    assert backup_id == backup_reviewer.id

    Skopos.TestAIUsage.configure!(reviewer_provider.id, :resolver, 10, context.admin)

    Skopos.TestAIUsage.configure!(backup_reviewer.id, :resolver, 20, context.admin)

    assert {:error, no_reviewer} = Providers.select_reviewer_ai([], actor: context.operator)
    assert Exception.message(no_reviewer) =~ "No eligible Reviewer AI is assigned"

    both = Skopos.TestAIUsage.configure!(context.provider.id, :all, 40, context.admin)

    assert %AI.Selection{
             role: :reviewer,
             provider_id: ^resolver_id,
             source: :assignment,
             assignment_id: reviewer_assignment_id
           } = Providers.select_reviewer_ai!([], actor: context.operator)

    assert reviewer_assignment_id == both.reviewer.id

    Skopos.TestAIUsage.configure!(context.provider.id, :reviewer, 40, context.admin)
    Skopos.TestAIUsage.configure!(reviewer_provider.id, :reviewer, 10, context.admin)
    Skopos.TestAIUsage.configure!(backup_reviewer.id, :reviewer, 20, context.admin)
    assert {:error, no_resolver} = Providers.select_resolver_ai(actor: context.operator)
    assert Exception.message(no_resolver) =~ "No eligible Resolver AI is assigned"
  end

  test "persisted AI assignment is valid only for its role and current revisions", context do
    %{resolver: resolver, reviewer: reviewer} =
      Skopos.TestAIUsage.configure!(context.provider.id, :all, 10, context.admin)

    assert {:ok, %{id: resolver_id}} =
             Providers.load_current_ai_usage_role_assignment(
               resolver.id,
               :resolver,
               resolver.revision,
               context.provider.revision,
               authorize?: false
             )

    assert resolver_id == resolver.id

    assert {:ok, %{id: reviewer_id}} =
             Providers.load_current_ai_usage_role_assignment(
               reviewer.id,
               :reviewer,
               reviewer.revision,
               context.provider.revision,
               authorize?: false
             )

    assert reviewer_id == reviewer.id

    for {assignment, role, assignment_revision, provider_revision} <- [
          {resolver, :reviewer, resolver.revision, context.provider.revision},
          {reviewer, :resolver, reviewer.revision, context.provider.revision},
          {reviewer, :reviewer, reviewer.revision + 1, context.provider.revision},
          {reviewer, :reviewer, reviewer.revision, context.provider.revision + 1}
        ] do
      assert {:ok, nil} =
               Providers.load_current_ai_usage_role_assignment(
                 assignment.id,
                 role,
                 assignment_revision,
                 provider_revision,
                 authorize?: false,
                 not_found_error?: false
               )
    end

    Providers.disable_provider!(context.provider, context.provider.revision, actor: context.admin)

    assert {:ok, nil} =
             Providers.load_current_ai_usage_role_assignment(
               reviewer.id,
               :reviewer,
               reviewer.revision,
               context.provider.revision,
               authorize?: false,
               not_found_error?: false
             )
  end

  test "eligible order follows priority, creation order, and current provider state", context do
    first = assign!(context.admin, context.provider, :resolver, 10)
    second_provider = create_ai_provider!(context.admin, "second-resolver", "second-model")
    second = assign!(context.admin, second_provider, :resolver, 10)

    preferred_provider =
      create_ai_provider!(context.admin, "preferred-resolver", "preferred-model")

    preferred = assign!(context.admin, preferred_provider, :resolver, 5)

    eligible_ids = fn ->
      Providers.eligible_ai_usage_role_assignments!(:resolver, authorize?: false)
      |> Enum.map(& &1.id)
    end

    assert eligible_ids.() == [preferred.id, first.id, second.id]

    assert Providers.select_resolver_ai!(actor: context.operator).provider_id ==
             preferred_provider.id

    Providers.disable_provider!(preferred_provider, preferred_provider.revision,
      actor: context.admin
    )

    assert eligible_ids.() == [first.id, second.id]

    assert Providers.select_resolver_ai!(actor: context.operator).provider_id ==
             context.provider.id

    Providers.update_provider!(
      second_provider,
      second_provider.revision,
      %{configuration: %{"model" => "updated-model"}},
      actor: context.admin
    )

    assert eligible_ids.() == [first.id]

    Providers.retire_ai_provider!(context.provider.id, context.provider.revision,
      actor: context.admin
    )

    assert eligible_ids.() == []
    assert {:error, _error} = Providers.select_resolver_ai(actor: context.operator)
  end

  test "an opaque investigation can collect facts before remediation verification exists",
       context do
    request = resolver_request(context.provider.revision)
    tool = Enum.find(request.proposal_tools, &(&1.request_kind == :effect))
    tool = %{tool | capability: "request.ssh.effect", operation: "command.execute"}
    request = %{request | proposal_tools: [tool], observation_tools: [], evidence: []}

    investigation =
      proposal()
      |> Map.put(:purpose, :investigation)
      |> Map.put(:capability, tool.capability)
      |> Map.put(:operation, tool.operation)
      |> Map.put(:selectors, %{})
      |> Map.put(:parameters, %{"command" => "service nginx status"})
      |> Map.put(:expected_result, %{})
      |> Map.put(:verification_intent, nil)
      |> Map.put(:evidence_ids, [])

    assert %AI.ResolverDecision{intent: ^investigation} =
             resolve!(context, request, fn _request ->
               {:ok, %AI.ResolverDecision{intent: investigation, usage: usage()}}
             end)
  end

  test "Resolver returns exactly one Target request, recovery or handoff intent",
       context do
    request = resolver_request(context.provider.revision)

    observation = %AI.Proposal{
      tool_id: "inspect-system-request",
      target_id: "target-1",
      target_revision: 1,
      access_method_id: "access-method-observe",
      access_method_revision: 1,
      request_kind: :observation,
      purpose: :investigation,
      capability: "observe.command",
      operation: "system.inspect",
      selectors: %{},
      parameters: %{},
      reason: "Collect current system state",
      evidence_ids: ["evidence-1"]
    }

    assert %AI.ResolverDecision{intent: ^observation} =
             resolve!(context, request, fn _request ->
               {:ok, %AI.ResolverDecision{intent: observation, usage: usage()}}
             end)

    assert_receive {:resolve, %{model: "test-model", api_key: @api_key}, ^request}

    proposal = proposal()

    later_request = %{
      request
      | turn: 2,
        evidence: [%{evidence() | kind: "observation"}],
        observation_results: [observation_result()]
    }

    assert %AI.ResolverDecision{intent: ^proposal} =
             resolve!(context, later_request, fn _request ->
               {:ok, %AI.ResolverDecision{intent: proposal, usage: usage()}}
             end)

    verified_evidence = %AI.Evidence{
      id: "verification-1",
      kind: "target_verification",
      target_id: "target-1",
      content: %{"status" => "verified", "operation_id" => "operation-1"}
    }

    recovered_request = %{
      later_request
      | turn: 3,
        alert_state: :recovered,
        evidence: later_request.evidence ++ [verified_evidence],
        recovery_evidence_ids: ["verification-1"],
        disclosure: %{
          later_request.disclosure
          | allowed_evidence_kinds:
              Enum.uniq(
                later_request.disclosure.allowed_evidence_kinds ++ ["target_verification"]
              )
        }
    }

    recovery = %AI.RecoveryConclusion{
      reason: "The alert recovered after fresh verification",
      evidence_ids: ["verification-1"]
    }

    assert %AI.ResolverDecision{intent: ^recovery} =
             resolve!(context, recovered_request, fn _request ->
               {:ok, %AI.ResolverDecision{intent: recovery, usage: usage()}}
             end)

    assert %AI.ResolverDecision{intent: ^proposal} =
             resolve!(context, recovered_request, fn _request ->
               {:ok, %AI.ResolverDecision{intent: proposal, usage: usage()}}
             end)

    handoff = %AI.Handoff{
      reason: "A physical inspection is required",
      required_input: "Confirm the drive fault LED"
    }

    assert %AI.ResolverDecision{intent: ^handoff} =
             resolve!(context, recovered_request, fn _request ->
               {:ok, %AI.ResolverDecision{intent: handoff, usage: usage()}}
             end)

    assert %AI.ResolverDecision{intent: ^handoff} =
             resolve!(context, request, fn _request ->
               {:ok, %AI.ResolverDecision{intent: handoff, usage: usage()}}
             end)

    manual_request = %{
      recovered_request
      | alert_state: :not_applicable,
        case_symptom: %{
          id: String.duplicate("a", 64),
          text: "Service is stopped",
          desired_outcome: "Service is running"
        },
        evidence:
          later_request.evidence ++
            [
              %{
                verified_evidence
                | content: Map.put(verified_evidence.content, "facts", %{"service" => "running"})
              }
            ]
    }

    assert %AI.ResolverDecision{intent: ^handoff} =
             resolve!(context, manual_request, fn _request ->
               {:ok, %AI.ResolverDecision{intent: handoff, usage: usage()}}
             end)

    manual_recovery = %{
      recovery
      | desired_outcome_claims: [
          %{
            "symptom_id" => manual_request.case_symptom.id,
            "evidence_id" => "verification-1",
            "fact_keys" => ["service"],
            "reason" => "The service is running"
          }
        ]
    }

    assert %AI.ResolverDecision{intent: ^manual_recovery} =
             resolve!(context, manual_request, fn _request ->
               {:ok, %AI.ResolverDecision{intent: manual_recovery, usage: usage()}}
             end)

    for invalid <- [
          %{manual_recovery | desired_outcome_claims: []},
          %{
            manual_recovery
            | desired_outcome_claims: [
                %{
                  hd(manual_recovery.desired_outcome_claims)
                  | "symptom_id" => String.duplicate("b", 64)
                }
              ]
          },
          %{
            manual_recovery
            | desired_outcome_claims: [
                %{hd(manual_recovery.desired_outcome_claims) | "fact_keys" => ["unobserved"]}
              ]
          }
        ] do
      assert {:error, invalid_recovery} =
               resolve(context, manual_request, fn _request ->
                 {:ok, %AI.ResolverDecision{intent: invalid, usage: usage()}}
               end)

      assert ai_error(invalid_recovery).category == :invalid_output
      assert ai_error(invalid_recovery).failure_code == "recovery"
    end

    ordinary_recovery = %{recovery | evidence_ids: ["observation-1"]}

    assert {:error, ordinary_error} =
             resolve(context, recovered_request, fn _request ->
               {:ok, %AI.ResolverDecision{intent: ordinary_recovery, usage: usage()}}
             end)

    assert ai_error(ordinary_error).category == :invalid_output

    observed = %AI.Evidence{
      id: "observation-recovered",
      kind: "observation",
      target_id: "target-1",
      content: %{
        "status" => "applied",
        "category" => "target_observed",
        "facts" => %{"ready" => true}
      }
    }

    observed_request = %{
      recovered_request
      | evidence: later_request.evidence ++ [observed],
        recovery_evidence_ids: [observed.id]
    }

    observed_recovery = %AI.RecoveryConclusion{
      reason: "The fresh Target observation confirms recovery",
      evidence_ids: [observed.id]
    }

    assert %AI.ResolverDecision{intent: ^observed_recovery} =
             resolve!(context, observed_request, fn _request ->
               {:ok, %AI.ResolverDecision{intent: observed_recovery, usage: usage()}}
             end)

    unmarked = %{observed | id: "observation-unmarked"}

    unmarked_request = %{
      recovered_request
      | evidence: later_request.evidence ++ [unmarked],
        recovery_evidence_ids: []
    }

    unmarked_recovery = %{observed_recovery | evidence_ids: [unmarked.id]}

    assert {:error, unmarked_error} =
             resolve(context, unmarked_request, fn _request ->
               {:ok, %AI.ResolverDecision{intent: unmarked_recovery, usage: usage()}}
             end)

    assert ai_error(unmarked_error).category == :invalid_output
  end

  test "Resolver searches and selects only a bounded offered Target before tools are exposed",
       context do
    request = preselection_request(context.provider.revision)

    search = %AI.TargetSearch{
      query: "linux-01 disk error",
      reason: "Find the registered Target named by the alert facts"
    }

    assert %AI.ResolverDecision{intent: ^search} =
             resolve!(context, request, fn _request ->
               {:ok, %AI.ResolverDecision{intent: search, usage: usage()}}
             end)

    catalog_limit = %{search | query: String.duplicate("a", 200)}

    assert %AI.ResolverDecision{intent: ^catalog_limit} =
             resolve!(context, request, fn _request ->
               {:ok, %AI.ResolverDecision{intent: catalog_limit, usage: usage()}}
             end)

    over_catalog_limit = %{search | query: String.duplicate("a", 201)}

    assert {:error, over_limit} =
             resolve(context, request, fn _request ->
               {:ok, %AI.ResolverDecision{intent: over_catalog_limit, usage: usage()}}
             end)

    assert ai_error(over_limit).category == :invalid_output

    candidate = %AI.TargetCandidate{
      id: "target-1",
      revision: 3,
      name: "linux-01",
      kind: "host",
      type_id: "linux",
      facts: %{"environment" => "production"}
    }

    candidate_evidence = %AI.Evidence{
      id: "candidate-evidence-1",
      kind: "target_candidates",
      content: %{"candidate_ids" => [candidate.id]}
    }

    candidate_request = %{
      request
      | turn: 2,
        target_candidates: [candidate],
        evidence: request.evidence ++ [candidate_evidence],
        disclosure: %{
          request.disclosure
          | allowed_evidence_kinds:
              request.disclosure.allowed_evidence_kinds ++ ["target_candidates"]
        }
    }

    selection = %AI.TargetSelection{
      target_id: candidate.id,
      target_revision: candidate.revision,
      evidence_ids: [candidate_evidence.id],
      reason: "The registered name and environment match the firing alert"
    }

    assert %AI.ResolverDecision{intent: ^selection} =
             resolve!(context, candidate_request, fn _request ->
               {:ok, %AI.ResolverDecision{intent: selection, usage: usage()}}
             end)

    assert {:error, uncited_candidate_error} =
             resolve(context, candidate_request, fn _request ->
               {:ok,
                %AI.ResolverDecision{
                  intent: %{selection | evidence_ids: ["evidence-1"]},
                  usage: usage()
                }}
             end)

    assert ai_error(uncited_candidate_error).category == :invalid_output

    wrong_candidate_evidence = %AI.Evidence{
      id: "candidate-evidence-2",
      kind: "target_candidates",
      content: %{"candidate_ids" => ["target-2"]}
    }

    wrong_candidate_request = %{
      candidate_request
      | evidence: candidate_request.evidence ++ [wrong_candidate_evidence]
    }

    assert {:error, wrong_candidate_error} =
             resolve(context, wrong_candidate_request, fn _request ->
               {:ok,
                %AI.ResolverDecision{
                  intent: %{selection | evidence_ids: [wrong_candidate_evidence.id]},
                  usage: usage()
                }}
             end)

    assert ai_error(wrong_candidate_error).category == :invalid_output

    condition = %AI.Condition{
      id: "condition-1",
      revision: 2,
      occurrence: 1,
      predicate: "NativeFault",
      subject_key: "native-subject",
      subject_ref: %{},
      state: :firing,
      target_id: candidate.id,
      current_occurred_at_us: 1
    }

    signal_evidence = %AI.Evidence{
      id: "current-signal-evidence",
      kind: "signal_event",
      content: %{
        "current" => true,
        "condition_id" => condition.id,
        "condition_revision" => condition.revision
      }
    }

    mapped_request = %{
      candidate_request
      | conditions: [condition],
        evidence: request.evidence ++ [signal_evidence],
        disclosure: %{
          candidate_request.disclosure
          | allowed_evidence_kinds:
              candidate_request.disclosure.allowed_evidence_kinds ++ ["signal_event"]
        }
    }

    mapped_selection = %{selection | evidence_ids: [signal_evidence.id]}

    assert %AI.ResolverDecision{intent: ^mapped_selection} =
             resolve!(context, mapped_request, fn _request ->
               {:ok, %AI.ResolverDecision{intent: mapped_selection, usage: usage()}}
             end)

    stale_signal_request = %{
      mapped_request
      | evidence:
          request.evidence ++
            [%{signal_evidence | content: %{signal_evidence.content | "condition_revision" => 1}}]
    }

    assert {:error, stale_signal_error} =
             resolve(context, stale_signal_request, fn _request ->
               {:ok, %AI.ResolverDecision{intent: mapped_selection, usage: usage()}}
             end)

    assert ai_error(stale_signal_error).category == :invalid_output

    for invalid <- [
          %{selection | target_id: "invented-target"},
          %{selection | target_revision: candidate.revision + 1}
        ] do
      assert {:error, error} =
               resolve(context, candidate_request, fn _request ->
                 {:ok, %AI.ResolverDecision{intent: invalid, usage: usage()}}
               end)

      assert ai_error(error).category == :invalid_output
    end

    [tool] = resolver_request(context.provider.revision).observation_tools
    premature_tools = %{request | observation_tools: [tool]}

    assert {:error, premature_error} =
             resolve(context, premature_tools, unreachable_response())

    assert ai_error(premature_error).category == :invalid_input

    selected_request = resolver_request(context.provider.revision)

    assert %AI.ResolverDecision{intent: ^search} =
             resolve!(context, selected_request, fn _request ->
               {:ok, %AI.ResolverDecision{intent: search, usage: usage()}}
             end)

    undisclosed_candidate = %{
      candidate_request
      | disclosure: %{request.disclosure | allowed_target_ids: []}
    }

    assert {:error, disclosure_error} =
             resolve(context, undisclosed_candidate, unreachable_response())

    assert ai_error(disclosure_error).category == :disclosure_limit
  end

  test "Resolver tool inputs must satisfy the exact offered JSON Schema", context do
    schema = %{
      "type" => "object",
      "properties" => %{
        "selectors" => %{
          "type" => "object",
          "properties" => %{"service" => %{"type" => "string", "minLength" => 1}},
          "required" => ["service"],
          "additionalProperties" => false
        },
        "parameters" => %{"type" => "object", "maxProperties" => 0}
      },
      "required" => ["selectors", "parameters"],
      "additionalProperties" => false
    }

    request = resolver_request(context.provider.revision)
    [observation_tool] = request.observation_tools

    observation_request_tool =
      Enum.find(request.proposal_tools, &(&1.request_kind == :observation))

    proposal_tool = Enum.find(request.proposal_tools, &(&1.request_kind == :effect))

    request = %{
      request
      | observation_tools: [%{observation_tool | input_schema: schema}],
        proposal_tools: [
          %{observation_request_tool | input_schema: schema},
          %{proposal_tool | input_schema: schema}
        ]
    }

    valid_observation = %AI.Proposal{
      tool_id: observation_request_tool.id,
      target_id: observation_request_tool.target_id,
      target_revision: observation_request_tool.target_revision,
      access_method_id: observation_request_tool.access_method_id,
      access_method_revision: observation_request_tool.access_method_revision,
      request_kind: :observation,
      purpose: :investigation,
      capability: observation_request_tool.capability,
      operation: observation_request_tool.operation,
      selectors: %{"service" => "api"},
      parameters: %{},
      reason: "Inspect the named service",
      evidence_ids: ["evidence-1"]
    }

    assert %AI.ResolverDecision{intent: ^valid_observation} =
             resolve!(context, request, fn _request ->
               {:ok, %AI.ResolverDecision{intent: valid_observation, usage: usage()}}
             end)

    self_verifying_proposal = %{
      proposal()
      | selectors: %{"service" => "api"},
        parameters: %{},
        verification_intent: %AI.VerificationIntent{
          tool_id: proposal_tool.id,
          selectors: %{"service" => "api"},
          parameters: %{},
          expected_result: %{"service" => "running"}
        }
    }

    assert {:error, self_verification_error} =
             resolve(context, request, fn _request ->
               {:ok, %AI.ResolverDecision{intent: self_verifying_proposal, usage: usage()}}
             end)

    assert ai_error(self_verification_error).category == :invalid_output

    invalid_observation = %{valid_observation | selectors: %{"service" => 42}}

    assert {:error, invalid_observation_error} =
             resolve(context, request, fn _request ->
               {:ok, %AI.ResolverDecision{intent: invalid_observation, usage: usage()}}
             end)

    assert ai_error(invalid_observation_error).category == :invalid_output

    invalid_proposal = %{
      proposal()
      | selectors: %{},
        parameters: %{},
        verification_intent: %AI.VerificationIntent{
          tool_id: observation_tool.id,
          selectors: %{"service" => "api"},
          parameters: %{},
          expected_result: %{"service" => "running"}
        }
    }

    assert {:error, invalid_proposal_error} =
             resolve(context, request, fn _request ->
               {:ok, %AI.ResolverDecision{intent: invalid_proposal, usage: usage()}}
             end)

    assert ai_error(invalid_proposal_error).category == :invalid_output

    invalid_verification = %{
      proposal()
      | selectors: %{"service" => "api"},
        parameters: %{},
        verification_intent: %AI.VerificationIntent{
          tool_id: observation_tool.id,
          selectors: %{"service" => 42},
          parameters: %{},
          expected_result: %{"service" => "running"}
        }
    }

    assert {:error, invalid_verification_error} =
             resolve(context, request, fn _request ->
               {:ok, %AI.ResolverDecision{intent: invalid_verification, usage: usage()}}
             end)

    assert ai_error(invalid_verification_error).category == :invalid_output

    unknown_verification_fact = %{
      proposal()
      | verification_intent: %AI.VerificationIntent{
          tool_id: observation_tool.id,
          selectors: %{},
          parameters: %{},
          expected_result: %{"invented_status" => "running"}
        }
    }

    assert {:error, unknown_fact_error} =
             resolve(context, request, fn _request ->
               {:ok, %AI.ResolverDecision{intent: unknown_verification_fact, usage: usage()}}
             end)

    assert ai_error(unknown_fact_error).category == :invalid_output

    atom_keyed_verification = %{
      proposal()
      | verification_intent: %AI.VerificationIntent{
          tool_id: observation_tool.id,
          selectors: %{},
          parameters: %{},
          expected_result: %{service: "running"}
        }
    }

    assert {:error, atom_key_error} =
             resolve(context, request, fn _request ->
               {:ok, %AI.ResolverDecision{intent: atom_keyed_verification, usage: usage()}}
             end)

    assert ai_error(atom_key_error).category == :invalid_output

    invalid_schema_request = %{
      request
      | observation_tools: [
          %{observation_tool | input_schema: %{"type" => "unsupported-json-type"}}
        ]
    }

    assert {:error, invalid_schema_error} =
             resolve(context, invalid_schema_request, unreachable_response())

    assert ai_error(invalid_schema_error).category == :invalid_input
  end

  test "Resolver proposals copy required values from cited observation evidence" do
    request = resolver_request(1)
    [observation_tool] = request.observation_tools
    proposal_tool = Enum.find(request.proposal_tools, &(&1.request_kind == :effect))

    observation_tool = %{
      observation_tool
      | access_method_id: proposal_tool.access_method_id,
        operation: "service.inspect"
    }

    requirement = %Target.EvidenceRequirement{
      parameter: "expected_state",
      fact: "state",
      observation: "service.inspect"
    }

    proposal_tool = %{proposal_tool | evidence_requirements: [requirement]}

    observation_evidence = %AI.Evidence{
      id: "observed-state",
      kind: "observation",
      target_id: proposal_tool.target_id,
      content: %{
        "tool_id" => observation_tool.id,
        "facts" => %{"state" => "inactive"}
      }
    }

    request = %{
      request
      | evidence: [observation_evidence],
        observation_tools: [observation_tool],
        proposal_tools: [proposal_tool]
    }

    exact = %{
      proposal()
      | evidence_ids: [observation_evidence.id],
        parameters: %{"expected_state" => "inactive"}
    }

    assert :ok =
             AI.Validator.validate_decision(
               :resolve,
               %AI.ResolverDecision{intent: exact, usage: usage()},
               request
             )

    source_evidence = %AI.Evidence{
      id: "current-signal",
      kind: "signal_event",
      target_id: nil,
      content: %{"current" => true, "state" => "firing"}
    }

    source_cited = %{exact | evidence_ids: [observation_evidence.id, source_evidence.id]}

    assert {:error, %AI.Error{category: :invalid_output}} =
             AI.Validator.validate_decision(
               :resolve,
               %AI.ResolverDecision{intent: source_cited, usage: usage()},
               %{request | evidence: [observation_evidence, source_evidence]}
             )

    invented = %{exact | parameters: %{"expected_state" => "active"}}

    assert {:error, %AI.Error{category: :invalid_output}} =
             AI.Validator.validate_decision(
               :resolve,
               %AI.ResolverDecision{intent: invented, usage: usage()},
               request
             )

    uncited = %{exact | evidence_ids: ["different-evidence"]}

    assert {:error, %AI.Error{category: :invalid_output}} =
             AI.Validator.validate_decision(
               :resolve,
               %AI.ResolverDecision{intent: uncited, usage: usage()},
               request
             )
  end

  test "Resolver rejects traversal when the registered relation is not executable", context do
    request = resolver_request(context.provider.revision)

    traversal = %AI.TargetTraversal{
      relationship_id: "relation-1",
      relationship_revision: 1,
      next_target_id: "target-2",
      next_target_revision: 1,
      evidence_ids: ["evidence-1"],
      reason: "Inspect the linked host"
    }

    assert %AI.ResolverDecision{intent: ^traversal} =
             resolve!(context, request, fn _ ->
               {:ok, %AI.ResolverDecision{intent: traversal, usage: usage()}}
             end)

    unavailable = %{request | traversable_relation_ids: []}

    assert {:error, unavailable_error} =
             resolve(context, unavailable, fn _ ->
               {:ok, %AI.ResolverDecision{intent: traversal, usage: usage()}}
             end)

    assert ai_error(unavailable_error).category == :invalid_output

    unknown = %{request | traversable_relation_ids: ["not-a-disclosed-relation"]}
    assert {:error, unknown_error} = resolve(context, unknown, unreachable_response())
    assert ai_error(unknown_error).category == :invalid_input
  end

  test "Resolver rejects invented effects and recovery without fresh recovered evidence",
       context do
    request = resolver_request(context.provider.revision)
    invented = %{proposal() | tool_id: "invented-effect"}

    assert {:error, proposal_error} =
             resolve(context, request, fn _request ->
               {:ok, %AI.ResolverDecision{intent: invented, usage: usage()}}
             end)

    assert ai_error(proposal_error).category == :invalid_output

    invented_method = %{proposal() | access_method_id: "invented-method"}

    assert {:error, exact_tool_error} =
             resolve(context, request, fn _request ->
               {:ok, %AI.ResolverDecision{intent: invented_method, usage: usage()}}
             end)

    assert ai_error(exact_tool_error).category == :invalid_output

    invented_verification = %{
      proposal()
      | verification_intent: %{
          proposal().verification_intent
          | tool_id: "invented-verification"
        }
    }

    assert {:error, verification_error} =
             resolve(context, request, fn _request ->
               {:ok, %AI.ResolverDecision{intent: invented_verification, usage: usage()}}
             end)

    assert ai_error(verification_error).category == :invalid_output

    recovery = %AI.RecoveryConclusion{
      reason: "Assume recovered",
      evidence_ids: ["evidence-1"]
    }

    assert {:error, recovery_error} =
             resolve(context, request, fn _request ->
               {:ok, %AI.ResolverDecision{intent: recovery, usage: usage()}}
             end)

    assert ai_error(recovery_error).category == :invalid_output

    malformed_request = %{request | evidence: [%{}]}
    assert {:error, malformed} = resolve(context, malformed_request, unreachable_response())
    assert ai_error(malformed).category == :invalid_input

    [observation_tool] = request.observation_tools
    atom_capability = %{request | observation_tools: [%{observation_tool | capability: :system}]}

    assert {:error, vocabulary_error} =
             resolve(context, atom_capability, unreachable_response())

    assert ai_error(vocabulary_error).category == :invalid_input

    atom_kind = %{request | evidence: [%{evidence() | kind: :signal}]}
    assert {:error, kind_error} = resolve(context, atom_kind, unreachable_response())
    assert ai_error(kind_error).category == :invalid_input
  end

  test "Reviewer cannot approve an opaque investigation whose assessed purpose is modification",
       context do
    request = review_request(context.provider.revision)

    proposal = %{
      request.proposal
      | purpose: :investigation,
        expected_result: %{},
        verification_intent: nil
    }

    request = %{request | proposal: proposal}

    for assessment <- [:remediation, :unknown, nil] do
      assert {:error, error} =
               review(context, request, fn _ ->
                 {:ok,
                  Map.put(
                    %AI.ReviewDecision{
                      verdict: :approved,
                      reason: "Insufficiently justified",
                      usage: usage()
                    },
                    :purpose_assessment,
                    assessment
                  )}
               end)

      assert ai_error(error).category == :invalid_output
    end
  end

  test "Reviewer receives isolated source and Proposal evidence", context do
    request = review_request(context.provider.revision)

    request = %{
      request
      | source_evidence: [
          %AI.Evidence{
            id: "source-evidence-1",
            kind: "signal_event",
            target_id: nil,
            content: %{"requirement" => "authoritative request"}
          }
        ]
    }

    assert %AI.ReviewDecision{verdict: :approved} =
             review!(context, request, fn received ->
               fields = Map.from_struct(received)
               refute Map.has_key?(fields, :observation_tools)
               refute Map.has_key?(fields, :proposal_tools)
               refute Map.has_key?(fields, :observation_results)
               assert received.source_evidence != received.cited_evidence

               {:ok,
                %AI.ReviewDecision{
                  purpose_assessment: :remediation,
                  verdict: :approved,
                  reason: "Proposal matches the cited evidence and policy",
                  usage: usage()
                }}
             end)

    assert_receive {:review, %{model: "test-model", api_key: @api_key}, ^request}

    final_turn = %{request | budget: %{request.budget | remaining_turns: 0}}

    assert %AI.ReviewDecision{verdict: :approved} =
             review!(context, final_turn, fn _received ->
               {:ok,
                %AI.ReviewDecision{
                  purpose_assessment: :remediation,
                  verdict: :approved,
                  reason: "Review does not consume a Resolver Turn",
                  usage: usage()
                }}
             end)

    assert_receive {:review, _, ^final_turn}

    same_session = %{request | session_id: request.resolver_session_id}

    assert {:error, isolated_error} = review(context, same_session, unreachable_response())
    assert ai_error(isolated_error).category == :invalid_input
    refute_receive {:review, _, ^same_session}

    assert {:error, malformed_output} =
             review(context, request, fn _request -> {:ok, %{verdict: :approved}} end)

    assert ai_error(malformed_output).category == :invalid_output

    duplicate_source = %{
      request
      | source_evidence: request.source_evidence ++ request.source_evidence
    }

    assert {:error, invalid_source} = review(context, duplicate_source, unreachable_response())
    assert ai_error(invalid_source).category == :invalid_input
    refute_receive {:review, _, ^duplicate_source}

    undisclosed_recovery = %{request | recovery_evidence_ids: ["unavailable-evidence"]}

    assert {:error, invalid_recovery} =
             review(context, undisclosed_recovery, unreachable_response())

    assert ai_error(invalid_recovery).category == :invalid_input
    refute_receive {:review, _, ^undisclosed_recovery}
  end

  test "budgets, disclosure, cancellation and stale providers stop before model dispatch",
       context do
    request = resolver_request(context.provider.revision)

    assert {:error, cancelled} =
             Providers.ai_resolve(
               context.provider.id,
               request,
               %{cancelled?: fn -> true end},
               actor: context.admin
             )

    assert ai_error(cancelled).category == :cancelled

    exhausted = %{request | budget: %{request.budget | remaining_turns: 0}}
    assert {:error, exhausted_error} = resolve(context, exhausted, unreachable_response())
    assert ai_error(exhausted_error).category == :budget_exhausted

    undisclosed = %{request | disclosure: %{request.disclosure | max_bytes: 1}}
    assert {:error, disclosure_error} = resolve(context, undisclosed, unreachable_response())
    assert ai_error(disclosure_error).category == :disclosure_limit

    unsupported_language = %{request | report_language: :fr}

    assert {:error, language_error} =
             resolve(context, unsupported_language, unreachable_response())

    assert ai_error(language_error).category == :invalid_input
    refute_receive {:resolve, _, ^unsupported_language}

    limits = AI.resolver_disclosure_limits()

    for disclosure <- [
          %{request.disclosure | max_items: limits.max_items + 1},
          %{request.disclosure | max_bytes: limits.max_bytes + 1},
          %{
            request.disclosure
            | allowed_target_ids: Enum.map(1..(limits.max_items + 1), &"target-#{&1}")
          }
        ] do
      assert {:error, invalid_limit} =
               resolve(context, %{request | disclosure: disclosure}, unreachable_response())

      assert ai_error(invalid_limit).category == :invalid_input
    end

    Providers.disable_provider!(context.provider, context.provider.revision, actor: context.admin)
    assert {:error, _stale_error} = resolve(context, request, unreachable_response())
    refute_receive {:resolve, _, _}
  end

  test "multilingual decision text uses the same character limits as the provider schema",
       context do
    resolver_request = resolver_request(context.provider.revision)
    reason = String.duplicate("界", 500)
    required_input = String.duplicate("界", 250)

    assert %AI.ResolverDecision{
             intent: %AI.Handoff{reason: ^reason, required_input: ^required_input}
           } =
             resolve!(context, resolver_request, fn _request ->
               {:ok,
                %AI.ResolverDecision{
                  intent: %AI.Handoff{reason: reason, required_input: required_input},
                  usage: usage()
                }}
             end)

    reviewer_reason = String.duplicate("界", 1_000)

    assert %AI.ReviewDecision{reason: ^reviewer_reason} =
             review!(context, review_request(context.provider.revision), fn _request ->
               {:ok,
                %AI.ReviewDecision{
                  purpose_assessment: :remediation,
                  verdict: :approved,
                  reason: reviewer_reason,
                  usage: usage()
                }}
             end)
  end

  test "token usage and provider failures stay typed and redact secrets", context do
    request = resolver_request(context.provider.revision)
    intent = %AI.Handoff{reason: "Need human input", required_input: "Inspect hardware"}

    for oversized_intent <- [
          %AI.Handoff{
            reason: String.duplicate("r", 501),
            required_input: "Inspect hardware"
          },
          %AI.Handoff{
            reason: "Need human input",
            required_input: String.duplicate("i", 251)
          },
          %{proposal() | reason: String.duplicate("r", 501)}
        ] do
      assert {:error, oversized_error} =
               resolve(context, request, fn _request ->
                 {:ok, %AI.ResolverDecision{intent: oversized_intent, usage: usage()}}
               end)

      assert ai_error(oversized_error).category == :invalid_output
    end

    assert {:error, invalid_usage} =
             resolve(context, request, fn _request ->
               {:ok,
                %AI.ResolverDecision{
                  intent: intent,
                  usage: %AI.Usage{input_tokens: -1, output_tokens: 1}
                }}
             end)

    assert ai_error(invalid_usage).category == :invalid_output

    assert {:error, exceeded} =
             resolve(context, request, fn _request ->
               {:ok,
                %AI.ResolverDecision{
                  intent: intent,
                  usage: %AI.Usage{input_tokens: 1_500, output_tokens: 501}
                }}
             end)

    assert ai_error(exceeded).category == :budget_exhausted

    secret_intent = %{intent | reason: "credential #{@api_key} requires inspection"}

    assert %AI.ResolverDecision{intent: %AI.Handoff{reason: redacted_reason}} =
             resolve!(context, request, fn _request ->
               {:ok, %AI.ResolverDecision{intent: secret_intent, usage: usage()}}
             end)

    assert redacted_reason == "credential [REDACTED] requires inspection"

    for category <- [:authentication, :unreachable, :timeout, :rate_limited, :failed] do
      assert {:error, error} =
               resolve(context, request, fn _request ->
                 {:error, category, "credential #{@api_key} failed"}
               end)

      assert ai_error(error).category == category
      assert ai_error(error).message == "credential [REDACTED] failed"
      refute inspect(error) =~ @api_key
    end
  end

  defp create_ai_provider!(admin, name, model) do
    Providers.create_provider!(
      name,
      :ai,
      "fixture-ai",
      %{
        "model" => model,
        "timeout_ms" => 30_000,
        "max_output_tokens" => 2_000
      },
      %{"api_key" => @api_key},
      actor: admin
    )
    |> then(&Providers.check_provider!(&1.id, 1, %{}, actor: admin))
    |> then(&Providers.enable_provider!(&1, 1, actor: admin))
  end

  defp assign!(admin, provider, role, priority) do
    Skopos.TestAIUsage.configure!(provider.id, role, priority, admin)
    |> Map.fetch!(role)
  end

  defp resolve(context, request, respond) do
    Providers.ai_resolve(
      context.provider.id,
      request,
      %{test_pid: self(), respond: respond},
      actor: context.admin
    )
  end

  defp resolve!(context, request, respond) do
    Providers.ai_resolve!(
      context.provider.id,
      request,
      %{test_pid: self(), respond: respond},
      actor: context.admin
    )
  end

  defp review(context, request, respond) do
    Providers.ai_review(
      context.provider.id,
      request,
      %{test_pid: self(), respond: respond},
      actor: context.admin
    )
  end

  defp review!(context, request, respond) do
    Providers.ai_review!(
      context.provider.id,
      request,
      %{test_pid: self(), respond: respond},
      actor: context.admin
    )
  end

  defp resolver_request(provider_revision) do
    %AI.ResolverRequest{
      provider_revision: provider_revision,
      session_id: "resolver-session-1",
      case_id: "case-1",
      turn: 1,
      objective: "Restore service health",
      alert_state: :firing,
      report_language: :en,
      operating_instructions: "Avoid modifying root",
      disclosure: %AI.Disclosure{
        allowed_target_ids: ["target-1", "target-2"],
        allowed_evidence_kinds: ["signal", "observation"],
        max_items: 20,
        max_bytes: 20_000
      },
      budget: budget(),
      evidence: [evidence()],
      target_candidates: [],
      selected_target_id: "target-1",
      selected_target_revision: 1,
      observation_results: [],
      target_relations: [
        %AI.TargetRelation{
          id: "relation-1",
          revision: 1,
          source_target: target_candidate("target-1", "linux"),
          destination_target: target_candidate("target-2", "custom-virtualization"),
          kind: "runs_on"
        }
      ],
      traversable_relation_ids: ["relation-1"],
      observation_tools: [
        %AI.ObservationTool{
          id: "inspect-system",
          target_id: "target-1",
          target_revision: 1,
          access_method_id: "access-method-observe",
          access_method_revision: 1,
          provider_id: "target-provider",
          provider_revision: 1,
          capability: "observe.command",
          operation: "system.inspect",
          description: "Inspect system state",
          input_schema: %{},
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
      proposal_tools: [
        %AI.ProposalTool{
          id: "inspect-system-request",
          target_id: "target-1",
          target_revision: 1,
          access_method_id: "access-method-observe",
          access_method_revision: 1,
          provider_id: "target-provider",
          provider_revision: 1,
          request_kind: :observation,
          capability: "observe.command",
          operation: "system.inspect",
          description: "Inspect system state",
          input_schema: %{}
        },
        %AI.ProposalTool{
          id: "restart-service",
          target_id: "target-1",
          target_revision: 1,
          access_method_id: "access-method-effect",
          access_method_revision: 1,
          provider_id: "target-provider",
          provider_revision: 1,
          request_kind: :effect,
          capability: "effect.command",
          operation: "service.restart",
          description: "Restart one service",
          input_schema: %{}
        }
      ]
    }
  end

  defp preselection_request(provider_revision) do
    request = resolver_request(provider_revision)

    %{
      request
      | selected_target_id: nil,
        selected_target_revision: nil,
        target_candidates: [],
        target_relations: [],
        traversable_relation_ids: [],
        observation_tools: [],
        proposal_tools: [],
        evidence: [%{evidence() | target_id: nil}]
    }
  end

  defp review_request(provider_revision) do
    %AI.ReviewRequest{
      provider_revision: provider_revision,
      session_id: "reviewer-session-1",
      resolver_session_id: "resolver-session-1",
      case_id: "case-1",
      objective: "Restore service health",
      resolution_run_id: "review-run",
      recovery_evidence_ids: [],
      report_language: :en,
      operating_instructions: "Avoid modifying root",
      proposal: proposal(),
      source_evidence: [],
      cited_evidence: [evidence()],
      budget: budget()
    }
  end

  defp evidence do
    %AI.Evidence{
      id: "evidence-1",
      kind: "signal",
      target_id: "target-1",
      content: %{alert: "high load"}
    }
  end

  defp target_candidate(id, type_id) do
    %AI.TargetCandidate{
      id: id,
      revision: 1,
      name: id,
      kind: "host",
      type_id: type_id,
      facts: %{}
    }
  end

  defp observation_result do
    %AI.ObservationResult{
      id: "observation-1",
      tool_id: "inspect-system",
      target_id: "target-1",
      kind: "observation",
      status: :ok,
      content: %{service: "healthy"}
    }
  end

  defp proposal do
    %AI.Proposal{
      tool_id: "restart-service",
      target_id: "target-1",
      target_revision: 1,
      access_method_id: "access-method-effect",
      access_method_revision: 1,
      request_kind: :effect,
      purpose: :remediation,
      capability: "effect.command",
      operation: "service.restart",
      selectors: %{service: "api"},
      parameters: %{service: "api"},
      reason: "Restart the unhealthy service",
      evidence_ids: ["evidence-1"],
      expected_result: %{"service" => "running"},
      verification_intent: %AI.VerificationIntent{
        tool_id: "inspect-system",
        selectors: %{service: "api"},
        parameters: %{service: "api"},
        expected_result: %{"service" => "running"}
      }
    }
  end

  defp budget do
    %AI.Budget{
      remaining_turns: 4,
      remaining_tokens: 2_000,
      remaining_target_requests: 5,
      remaining_effects: 2,
      remaining_related_targets: 3
    }
  end

  defp usage, do: %AI.Usage{input_tokens: 100, output_tokens: 50}

  defp unreachable_response,
    do: fn _request -> flunk("invalid request reached AI adapter") end

  defp ai_error(%{errors: errors}) do
    Enum.find_value(errors, fn
      %AI.Error{} = error -> error
      nested when is_map(nested) -> ai_error(nested)
      _other -> nil
    end)
  end

  defp ai_error(_error), do: nil
end
