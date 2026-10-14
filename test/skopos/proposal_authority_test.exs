defmodule Skopos.ProposalAuthorityTest do
  use Skopos.DataCase, async: false

  alias Skopos.{Accounts, Cases, Providers, Signals, Targets}

  alias Skopos.Cases.Operation.AcceptanceWorker, as: OperationAcceptanceWorker
  alias Skopos.Cases.Operation.Worker, as: OperationWorker

  alias Skopos.Cases.Proposal.{
    ProposalExpirationWorker,
    ReviewDelivery,
    ReviewProjection,
    ReviewWorker
  }

  alias Skopos.Providers.{AI, Signal}
  alias Skopos.Providers.Target, as: ProviderTarget

  @password "correct horse battery staple"

  setup do
    admin =
      Accounts.bootstrap!("authority-admin@example.com", @password, @password, authorize?: true)

    operator =
      Accounts.create_user!("authority-operator@example.com", @password, :operator, actor: admin)

    provider =
      Providers.create_provider!(
        "authority-target-provider",
        :target,
        "fixture-target",
        %{"endpoint" => "reachable"},
        %{"token" => "authority-target-secret"},
        actor: admin
      )
      |> then(&Providers.enable_provider!(&1, 1, actor: admin))

    target = Targets.create_target!("authority-linux", "host", "linux", %{}, nil, actor: admin)

    method =
      Targets.create_access_method!(
        target.id,
        provider.id,
        "authority-ssh",
        "ssh",
        "ssh://authority-linux",
        provider.revision,
        10,
        ["effect.service", "observe.service"],
        actor: admin
      )
      |> then(&Targets.check_access_method!(&1.id, &1.revision, %{}, actor: admin))

    resolver_provider = ai_provider!(admin, "authority-resolver", "resolver-model")

    resolver_assignment =
      Skopos.TestAIUsage.configure!(resolver_provider.id, :resolver, 10, admin)
      |> Map.fetch!(:resolver)

    reviewer_provider = ai_provider!(admin, "authority-reviewer", "reviewer-model")

    reviewer_assignment =
      Skopos.TestAIUsage.configure!(reviewer_provider.id, :reviewer, 10, admin)
      |> Map.fetch!(:reviewer)

    %{
      admin: admin,
      operator: operator,
      provider: provider,
      target: target,
      method: method,
      resolver_provider: resolver_provider,
      resolver_assignment: resolver_assignment,
      reviewer_provider: reviewer_provider,
      reviewer_assignment: reviewer_assignment
    }
  end

  for {table, column, attempt} <- [
        {"ai_invocations", "category", 1},
        {"ai_usage_role_assignments", "priority", 1},
        {"evidences", "content", 3}
      ] do
    @tag proposal_review_input_read_fault: true,
         read_table: table,
         read_column: column,
         delivery_attempt: attempt
    test "temporary #{table} input read failure retains the exact reviewing Proposal", context do
      configure_mode!(:auto, context.admin)
      {incident, run, proposal} = proposal!("review-input-read", context)
      Cases.route_proposal_authority!(proposal.id, authorize?: false)
      before_proposal = Cases.get_proposal!(proposal.id, authorize?: false)
      before_case = Cases.get_case!(incident.id, authorize?: false)
      before_run = Cases.get_resolution_run!(run.id, authorize?: false)

      Repo.query!(
        "ALTER TABLE #{context.read_table} RENAME COLUMN #{context.read_column} TO unavailable_input"
      )

      try do
        assert {:error, _error} =
                 ReviewWorker.perform(%Oban.Job{
                   args: %{"proposal_id" => proposal.id},
                   attempt: context.delivery_attempt,
                   max_attempts: 3
                 })
      after
        Repo.query!(
          "ALTER TABLE #{context.read_table} RENAME COLUMN unavailable_input TO #{context.read_column}"
        )
      end

      assert Cases.get_proposal!(proposal.id, authorize?: false) == before_proposal
      assert Cases.get_case!(incident.id, authorize?: false) == before_case
      assert Cases.get_resolution_run!(run.id, authorize?: false) == before_run
      assert Cases.list_ai_invocations!(authorize?: false) == []
      assert Cases.list_review_decisions!(actor: context.admin) == []
      assert Cases.list_approvals!(actor: context.admin) == []
      assert Cases.list_operations!(actor: context.admin) == []

      assert :ok =
               ReviewDelivery.run(proposal.id,
                 ai_invocation: %{
                   test_pid: self(),
                   respond: fn _request ->
                     {:ok,
                      %AI.ReviewDecision{
                        purpose_assessment: :remediation,
                        verdict: :approved,
                        reason: "The exact effect follows the cited evidence",
                        usage: %AI.Usage{input_tokens: 3, output_tokens: 2}
                      }}
                   end
                 }
               )

      assert_receive {:review, _, _}

      assert :ok =
               ReviewWorker.perform(%Oban.Job{
                 args: %{"proposal_id" => proposal.id},
                 attempt: 2,
                 max_attempts: 3
               })

      refute_receive {:review, _, _}
      assert Cases.get_proposal!(proposal.id, authorize?: false).status == :authorized
      assert Cases.get_resolution_run!(run.id, authorize?: false).ai_usage_units == 5
      assert [_invocation] = Cases.list_ai_invocations!(authorize?: false)
      assert [_decision] = Cases.list_review_decisions!(actor: context.admin)
      assert [_approval] = Cases.list_approvals!(actor: context.admin)
      assert acceptance_jobs(proposal.id) == 1
    end
  end

  for {mode, worker, expected_status} <- [
        {:auto, ReviewWorker, :reviewing},
        {:ask, ProposalExpirationWorker, :awaiting_human},
        {:full_access, OperationAcceptanceWorker, :authorized}
      ] do
    @tag authority_mode: mode, required_worker: worker, scheduled_status: expected_status
    test "#{mode} Proposal routing cannot commit without its required continuation job",
         context do
      configure_mode!(context.authority_mode, context.admin)
      {incident, run, proposal} = proposal!("authority-job-persistence", context)
      before_case = Cases.get_case!(incident.id, actor: context.operator)
      before_run = Cases.get_resolution_run!(run.id, authorize?: false)
      before_proposal = Cases.get_proposal!(proposal.id, actor: context.operator)
      before_events = Cases.list_case_events!(actor: context.operator)

      Repo.query!("""
      CREATE FUNCTION pg_temp.reject_authority_job() RETURNS trigger LANGUAGE plpgsql AS $$
      BEGIN
        IF NEW.worker = '#{Oban.Worker.to_string(context.required_worker)}' THEN RETURN NULL; END IF;
        RETURN NEW;
      END;
      $$;
      """)

      Repo.query!("""
      CREATE TRIGGER reject_authority_job BEFORE INSERT ON oban_jobs
      FOR EACH ROW EXECUTE FUNCTION pg_temp.reject_authority_job()
      """)

      assert {:error, _error} = Cases.route_proposal_authority(proposal.id, authorize?: false)
      assert Cases.get_case!(incident.id, actor: context.operator) == before_case
      assert Cases.get_resolution_run!(run.id, authorize?: false) == before_run
      assert Cases.get_proposal!(proposal.id, actor: context.operator) == before_proposal
      assert Cases.list_case_events!(actor: context.operator) == before_events
      assert Cases.list_approvals!(actor: context.operator) == []
      assert Cases.list_review_decisions!(actor: context.operator) == []

      Repo.query!("DROP TRIGGER reject_authority_job ON oban_jobs")

      scheduled = Cases.route_proposal_authority!(proposal.id, authorize?: false)
      assert scheduled.status == context.scheduled_status
      assert Cases.route_proposal_authority!(proposal.id, authorize?: false).id == scheduled.id

      assert [job] =
               Repo.all(Oban.Job)
               |> Enum.filter(&(&1.worker == Oban.Worker.to_string(context.required_worker)))

      assert job.args == %{"proposal_id" => proposal.id}
      assert is_integer(job.id)
      assert Cases.list_operations!(actor: context.operator) == []
      assert Cases.list_ai_invocations!(actor: context.operator) == []
    end
  end

  test "saved Reviewer approval retries acceptance scheduling without another paid review",
       context do
    configure_mode!(:auto, context.admin)
    {incident, run, proposal} = proposal!("paid-review-job-persistence", context)
    reviewing = Cases.route_proposal_authority!(proposal.id, authorize?: false)
    before_case = Cases.get_case!(incident.id, actor: context.operator)

    Repo.query!("""
    CREATE FUNCTION pg_temp.reject_review_acceptance_job() RETURNS trigger LANGUAGE plpgsql AS $$
    BEGIN
      IF NEW.worker = 'Skopos.Cases.Operation.AcceptanceWorker' THEN RETURN NULL; END IF;
      RETURN NEW;
    END;
    $$;
    """)

    Repo.query!("""
    CREATE TRIGGER reject_review_acceptance_job BEFORE INSERT ON oban_jobs
    FOR EACH ROW EXECUTE FUNCTION pg_temp.reject_review_acceptance_job()
    """)

    assert {:error, _error} =
             ReviewDelivery.run(reviewing.id,
               ai_invocation: %{
                 test_pid: self(),
                 respond: fn _request ->
                   {:ok,
                    %AI.ReviewDecision{
                      purpose_assessment: :remediation,
                      verdict: :approved,
                      reason: "The proposed exact request is justified",
                      usage: %AI.Usage{input_tokens: 3, output_tokens: 2}
                    }}
                 end
               }
             )

    assert_receive {:review, %{model: "reviewer-model"}, _request}
    assert Cases.get_case!(incident.id, actor: context.operator) == before_case
    assert Cases.get_proposal!(proposal.id, actor: context.operator).status == :reviewing
    assert Cases.get_resolution_run!(run.id, authorize?: false).ai_usage_units == 5
    assert [decision] = Cases.list_review_decisions!(actor: context.operator)
    assert decision.verdict == :approved
    invocations = Cases.list_ai_invocations!(actor: context.operator)
    assert Cases.list_approvals!(actor: context.operator) == []
    assert acceptance_jobs(proposal.id) == 0

    Repo.query!("DROP TRIGGER reject_review_acceptance_job ON oban_jobs")

    for _ <- 1..2 do
      assert :ok =
               ReviewDelivery.run(reviewing.id,
                 ai_invocation: %{
                   test_pid: self(),
                   respond: fn _request -> flunk("saved approval was reviewed again") end
                 }
               )
    end

    assert Cases.get_proposal!(proposal.id, actor: context.operator).status == :authorized
    assert acceptance_jobs(proposal.id) == 1
    assert length(Cases.list_approvals!(actor: context.operator)) == 1
    assert Cases.get_resolution_run!(run.id, authorize?: false).ai_usage_units == 5
    assert Cases.list_ai_invocations!(actor: context.operator) == invocations
    refute_receive {:review, _, _}
  end

  test "Reviewer receives distinct citable ranges of a captured file", context do
    configure_mode!(:auto, context.admin)
    {incident, run, proposal} = proposal!("file-review", context, :effect)

    upload =
      Targets.begin_artifact!(
        context.target.id,
        "response.bin",
        "application/octet-stream",
        5,
        "b55f1659c0645fd1cee6dfa8b3af06795e9da7e48cb65c2b999f896c9f539dbd",
        "review-file",
        actor: context.operator
      )

    Targets.append_artifact_chunk!(upload.id, 0, <<255, 0, 1, 2, 255>>, actor: context.operator)
    Targets.complete_artifact!(upload.id, actor: context.operator)
    reference = Targets.artifact_reference!(upload.id, context.target.id, actor: context.operator)

    source =
      Cases.append_evidence!(
        incident.id,
        run.id,
        nil,
        "review-file-source",
        "observation",
        "fixture",
        "native-file",
        %{"target_id" => context.target.id, "facts" => %{"file" => reference}},
        DateTime.utc_now(),
        authorize?: false
      )

    receipts =
      for {offset, length} <- [{1, 3}, {4, 1}] do
        turn =
          Cases.start_turn!(
            incident.id,
            run.id,
            "review-file-range-#{offset}",
            %{},
            %{},
            "Review limits",
            authorize?: false
          ).value

        Cases.complete_turn!(
          turn.id,
          turn.revision,
          %{
            "outcome" => "decision",
            "intent" => %{
              "type" => "file_read",
              "source_evidence_id" => source.id,
              "reference" => reference,
              "offset" => offset,
              "length" => length,
              "reason" => "Inspect response"
            }
          },
          :observation_pending,
          %{"action" => "route_resolver_decision", "turn_id" => turn.id},
          "Continue",
          authorize?: false
        )

        Cases.capture_file_read!(turn.id, authorize?: false)
      end

    reviewing = Cases.route_proposal_authority!(proposal.id, authorize?: false)

    selection = %AI.Selection{
      role: :reviewer,
      provider_id: context.reviewer_provider.id,
      provider_revision: context.reviewer_provider.revision,
      source: :assignment,
      assignment_id: context.reviewer_assignment.id,
      assignment_revision: context.reviewer_assignment.revision
    }

    assert {:ok, request, _context} = ReviewProjection.build(reviewing.id, selection)

    slices =
      Enum.filter(request.context_evidence, &(&1.kind == "file_read"))
      |> Enum.sort_by(& &1.content["offset"])

    assert Enum.map(slices, & &1.id) == Enum.map(receipts, & &1.id)
    assert Enum.map(slices, & &1.content["value"]) == [<<0, 1, 2>>, "/w=="]
    assert Enum.map(slices, & &1.content["encoding"]) == ["utf8", "base64"]

    for slice <- slices do
      assert slice.content["source_evidence_id"] == source.id
      assert slice.content["source_observed_at"] == DateTime.to_iso8601(source.observed_at)
      assert slice.content["reference"] == reference
      refute Map.has_key?(Cases.get_evidence!(slice.id, actor: context.operator).content, "value")
    end

    [first, second] = receipts

    assert :ok =
             ReviewDelivery.run(reviewing.id,
               ai_invocation: %{
                 test_pid: self(),
                 respond: fn _request ->
                   {:ok,
                    %AI.ReviewDecision{
                      purpose_assessment: :remediation,
                      verdict: :rejected,
                      reason: "Gather more direct evidence",
                      usage: %AI.Usage{input_tokens: 1, output_tokens: 1}
                    }}
                 end
               }
             )

    current = Cases.get_case!(incident.id, authorize?: false)
    started = Cases.get_turn!(current.pending_intent["turn_id"], authorize?: false)

    {_incident, _run, cited_proposal} =
      proposal_for_case!(current, "file-cited-review", context, :effect, nil,
        evidence: first,
        started: started
      )

    Cases.route_downstream_decision!(cited_proposal.source_turn_id, authorize?: false)
    cited_reviewing = Cases.get_proposal!(cited_proposal.id, authorize?: false)
    assert {:ok, cited_request, _context} = ReviewProjection.build(cited_reviewing.id, selection)
    assert [cited] = cited_request.cited_evidence
    assert cited.id == first.id
    assert cited.content["value"] == <<0, 1, 2>>

    assert Enum.any?(
             cited_request.context_evidence,
             &(&1.id == second.id and &1.content["value"] == "/w==")
           )

    viewer = Accounts.change_role!(context.operator, :viewer, actor: context.admin)
    assert {:error, _} = ReviewProjection.build(cited_reviewing.id, selection)
    owner = Accounts.change_role!(viewer, :operator, actor: context.admin)
    Targets.revoke_artifact!(reference["id"], actor: owner)
    assert {:ok, unavailable, _context} = ReviewProjection.build(cited_reviewing.id, selection)
    assert [cited] = unavailable.cited_evidence
    assert cited.content["status"] == "unavailable"
    refute Map.has_key?(cited.content, "value")
    assert Cases.get_evidence!(first.id, actor: owner).content == first.content

    for index <- 1..2 do
      Cases.append_evidence!(
        incident.id,
        run.id,
        nil,
        "review-context-limit-#{index}",
        "observation",
        "fixture",
        "context",
        %{
          "target_id" => context.target.id,
          "facts" => %{"entry" => index, "padding" => String.duplicate("x", 34000)}
        },
        DateTime.utc_now(),
        authorize?: false
      )
    end

    assert {:ok, bounded, _context} = ReviewProjection.build(cited_reviewing.id, selection)

    assert Enum.find(bounded.cited_evidence, &(&1.id == first.id)).content["status"] ==
             "unavailable"

    assert Enum.find(bounded.context_evidence, &(&1.id == second.id)).content["status"] ==
             "unavailable"

    assert Enum.count(bounded.context_evidence, &get_in(&1.content, ["facts", "padding"])) == 1
  end

  test "Readonly records a recommendation and pauses without Approval or effect", context do
    {incident, run, proposal} = proposal!("readonly", context)

    assert {:ok, recommended} = Cases.route_proposal_authority(proposal.id, authorize?: false)
    assert {:ok, duplicate} = Cases.route_proposal_authority(proposal.id, authorize?: false)

    assert recommended.status == :recommended
    assert duplicate.id == recommended.id
    assert Cases.list_approvals!(actor: context.admin) == []

    paused_case = Cases.get_case!(incident.id, authorize?: false)
    assert paused_case.status == :needs_attention

    assert paused_case.pending_intent == %{
             "action" => "view_recommendation",
             "proposal_id" => proposal.id
           }

    assert Cases.get_resolution_run!(run.id, authorize?: false).status == :needs_attention
    refute_receive {:effect, _, _}
  end

  test "Readonly observation uses the same approval and durable Operation path", context do
    {incident, run, proposal} = proposal!("readonly-observation", context, :observation)

    assert {:ok, authorized} = Cases.route_proposal_authority(proposal.id, authorize?: false)
    assert authorized.status == :authorized

    assert [approval] = Cases.list_approvals!(actor: context.admin)
    assert approval.source == :readonly
    assert approval.decision == :approved

    operation = Cases.accept_operation!(proposal.id, authorize?: false)
    assert operation.request_kind == :observation

    observed_at = DateTime.utc_now()

    assert :ok =
             Skopos.Cases.Operation.Delivery.run(operation.id,
               target_invocation: %{
                 test_pid: self(),
                 respond: fn ->
                   {:ok,
                    %ProviderTarget.Observation{
                      facts: %{"status" => "degraded", "detail" => "disk latency"},
                      observed_at: observed_at
                    }}
                 end
               }
             )

    assert_receive {:observe, _state, %{operation: "service.inspect"}}
    refute_receive {:effect, _, _}
    assert Cases.verification_attempts_for_case!(incident.id, actor: context.admin) == []

    [evidence] =
      Cases.list_evidence!(actor: context.admin)
      |> Enum.filter(&(&1.source_ref == operation.id))

    assert evidence.kind == "observation"

    assert evidence.content["facts"] == %{
             "status" => "degraded",
             "detail" => "disk latency"
           }

    current = Cases.get_case!(incident.id, authorize?: false)
    assert current.pending_intent["action"] == "resolve_turn"
    assert Cases.get_resolution_run!(run.id, authorize?: false).target_request_count == 1
  end

  test "Auto routes a cleared observation without Reviewer or human approval", context do
    configure_mode!(:auto, context.admin)
    {incident, run, proposal} = proposal!("auto-observation", context, :observation)

    assert {:ok, authorized} = Cases.route_proposal_authority(proposal.id, authorize?: false)
    assert {:ok, replayed} = Cases.route_proposal_authority(proposal.id, authorize?: false)
    assert authorized.status == :authorized
    assert replayed.id == authorized.id

    assert [approval] = Cases.list_approvals!(actor: context.admin)
    assert approval.source == :auto_observation
    assert approval.decision == :approved
    assert Cases.list_review_decisions!(actor: context.admin) == []
    assert review_jobs(proposal.id) == 0
    assert acceptance_jobs(proposal.id) == 1

    operation = Cases.accept_operation!(proposal.id, authorize?: false)
    assert operation.request_kind == :observation
    assert Cases.get_resolution_run!(run.id, authorize?: false).effect_count == 0
    assert Cases.get_case!(incident.id, authorize?: false).status == :running
    refute_receive {:review, _, _}
    refute_receive {:effect, _, _}
  end

  test "Auto invalidates an observation when Target instructions change before authority",
       context do
    configure_mode!(:auto, context.admin)
    {incident, _run, proposal} = proposal!("observation-policy-change", context, :observation)

    Targets.update_target!(
      context.target,
      context.target.revision,
      %{operating_instructions: "Do not inspect this service"},
      actor: context.admin
    )

    assert {:ok, invalidated} = Cases.route_proposal_authority(proposal.id, authorize?: false)
    assert invalidated.status == :invalidated
    assert Cases.list_approvals!(actor: context.admin) == []
    assert Cases.list_operations!(actor: context.admin) == []
    assert Cases.get_case!(incident.id, authorize?: false).status == :needs_attention
  end

  test "Auto permits an observation when another Target instructions change", context do
    configure_mode!(:auto, context.admin)
    {_incident, _run, proposal} = proposal!("effect-policy-observation", context, :observation)

    other =
      Targets.create_target!("other-target", "host", "linux", %{}, nil, actor: context.admin)

    Targets.update_target!(
      other,
      other.revision,
      %{operating_instructions: "Do not change this other Target"},
      actor: context.admin
    )

    assert {:ok, authorized} = Cases.route_proposal_authority(proposal.id, authorize?: false)
    assert authorized.status == :authorized
    assert [approval] = Cases.list_approvals!(actor: context.admin)
    assert approval.source == :auto_observation
  end

  test "Auto refuses an observation when the exact Access Method changes", context do
    configure_mode!(:auto, context.admin)
    {incident, run, proposal} = proposal!("auto-observation-stale", context, :observation)

    Targets.update_access_method!(
      context.method,
      context.method.revision,
      %{priority: context.method.priority + 1},
      actor: context.admin
    )

    assert {:ok, invalidated} = Cases.route_proposal_authority(proposal.id, authorize?: false)
    assert invalidated.status == :invalidated
    assert Cases.list_approvals!(actor: context.admin) == []
    assert Cases.list_operations!(actor: context.admin) == []
    assert Cases.get_case!(incident.id, authorize?: false).status == :needs_attention
    assert Cases.get_resolution_run!(run.id, authorize?: false).status == :needs_attention
    refute_receive {:observe, _, _}
  end

  test "multilingual Proposal reason uses the Resolver codepoint limit through routing",
       context do
    reason = String.duplicate("界", 116) <> String.duplicate("a", 196)
    assert length(String.codepoints(reason)) == 312
    assert byte_size(reason) == 544

    {_incident, _run, proposal} =
      proposal!("multilingual-reason", context, :observation, reason)

    assert proposal.reason == reason

    assert {:ok, routed} =
             Cases.route_downstream_decision(proposal.source_turn_id, authorize?: false)

    assert routed.status == :running
    assert routed.pending_intent["proposal_id"] == proposal.id
  end

  test "Ask approval is exact, immutable, retryable and only exposes a dispatch reference",
       context do
    configure_mode!(:ask, context.admin)
    {incident, run, proposal} = proposal!("ask-approve", context)

    assert {:ok, waiting} = Cases.route_proposal_authority(proposal.id, authorize?: false)
    assert waiting.status == :awaiting_human
    assert Cases.list_approvals!(actor: context.admin) == []

    assert {:ok, authorized} =
             Cases.decide_proposal(
               waiting.id,
               waiting.revision,
               waiting.proposal_digest,
               :approved,
               "The evidence supports this exact restart",
               actor: context.operator
             )

    assert {:ok, duplicate} =
             Cases.decide_proposal(
               waiting.id,
               waiting.revision,
               waiting.proposal_digest,
               :approved,
               "The evidence supports this exact restart",
               actor: context.operator
             )

    assert duplicate.id == authorized.id
    assert authorized.status == :authorized
    assert [approval] = Cases.list_approvals!(actor: context.admin)
    assert approval.decision == :approved
    assert approval.source == :human
    assert approval.actor_id == context.operator.id
    assert approval.actor_role_version == context.operator.role_version
    assert approval.proposal_digest == waiting.proposal_digest
    assert byte_size(approval.clearance_digest) == 64

    assert Cases.get_case!(incident.id, authorize?: false).pending_intent == %{
             "action" => "dispatch_operation",
             "approval_id" => approval.id,
             "operation_id" => proposal.reserved_operation_id,
             "proposal_id" => proposal.id
           }

    assert Cases.get_resolution_run!(run.id, authorize?: false).effect_count == 0
    assert acceptance_jobs(proposal.id) == 1

    acceptance_job = %Oban.Job{args: %{"proposal_id" => proposal.id}}
    assert :ok = OperationAcceptanceWorker.perform(acceptance_job)
    assert :ok = OperationAcceptanceWorker.perform(acceptance_job)

    [operation] = Cases.list_operations!(actor: context.admin)
    assert operation.proposal_id == proposal.id
    assert operation.id == proposal.reserved_operation_id
    assert operation_jobs(operation.id) == 1
    assert Cases.get_resolution_run!(run.id, authorize?: false).effect_count == 1

    assert {:error, _error} =
             Cases.decide_proposal(
               waiting.id,
               authorized.revision,
               waiting.proposal_digest,
               :rejected,
               "Opposite decision",
               actor: context.operator
             )

    refute_receive {:effect, _, _}
  end

  test "Ask rejection records one decision and starts one new Resolver Turn", context do
    configure_mode!(:ask, context.admin)
    {incident, run, proposal} = proposal!("ask-reject", context)
    waiting = Cases.route_proposal_authority!(proposal.id, authorize?: false)
    initial_turn_count = length(Cases.list_turns!(actor: context.admin))

    rejected =
      Cases.decide_proposal!(
        waiting.id,
        waiting.revision,
        waiting.proposal_digest,
        :rejected,
        "Try a non-disruptive alternative",
        actor: context.operator
      )

    duplicate =
      Cases.decide_proposal!(
        waiting.id,
        waiting.revision,
        waiting.proposal_digest,
        :rejected,
        "Try a non-disruptive alternative",
        actor: context.operator
      )

    assert rejected.status == :rejected
    assert duplicate.id == rejected.id
    assert [approval] = Cases.list_approvals!(actor: context.admin)
    assert approval.decision == :rejected
    assert approval.source == :human
    assert is_nil(approval.clearance_digest)

    turns = Cases.list_turns!(actor: context.admin)
    assert length(turns) == initial_turn_count + 1
    reconsideration = Enum.max_by(turns, & &1.ordinal)
    assert reconsideration.intent["rejected_proposal_id"] == proposal.id

    assert Cases.get_case!(incident.id, authorize?: false).pending_intent == %{
             "action" => "resolve_turn",
             "proposal_id" => proposal.id,
             "rejected_proposal_id" => proposal.id,
             "turn_id" => reconsideration.id
           }

    assert Cases.get_resolution_run!(run.id, authorize?: false).effect_count == 0
    refute_receive {:effect, _, _}
  end

  test "FullAccess leaves a mode Approval while Auto only waits for Reviewer", context do
    configure_mode!(:full_access, context.admin)
    {full_case, full_run, full_proposal} = proposal!("full", context)

    authorized = Cases.route_proposal_authority!(full_proposal.id, authorize?: false)
    assert authorized.status == :authorized
    assert [approval] = Cases.list_approvals!(actor: context.admin)
    assert approval.source == :full_access
    assert approval.actor_id == context.operator.id

    assert Cases.get_case!(full_case.id, authorize?: false).pending_intent["action"] ==
             "dispatch_operation"

    assert Cases.get_resolution_run!(full_run.id, authorize?: false).effect_count == 0
    assert acceptance_jobs(full_proposal.id) == 1
    refute_receive {:effect, _, _}

    configure_mode!(:auto, context.admin)
    {auto_case, auto_run, auto_proposal} = proposal!("auto", context)
    reviewing = Cases.route_proposal_authority!(auto_proposal.id, authorize?: false)

    assert reviewing.status == :reviewing

    assert Cases.get_case!(auto_case.id, authorize?: false).pending_intent == %{
             "action" => "review_proposal",
             "proposal_digest" => auto_proposal.proposal_digest,
             "proposal_id" => auto_proposal.id
           }

    assert length(Cases.list_approvals!(actor: context.admin)) == 1
    assert review_jobs(auto_proposal.id) == 1
    assert acceptance_jobs(auto_proposal.id) == 0
    assert Cases.get_resolution_run!(auto_run.id, authorize?: false).effect_count == 0
    refute_receive {:review, _, _}
  end

  test "Auto accepts one isolated assigned Reviewer decision and usage", context do
    configure_mode!(:auto, context.admin)

    initial_target =
      Targets.create_target!("authority-linked-guest", "host", "linux", %{}, nil,
        actor: context.admin
      )

    relation =
      Targets.create_relationship!(
        initial_target.id,
        context.target.id,
        "hosted_by",
        %{},
        nil,
        actor: context.admin
      )

    Accounts.change_preferred_language!(context.operator, :ja, actor: context.operator)

    {incident, run, proposal} =
      proposal!("review-approved", Map.put(context, :initial_target, initial_target), :effect)

    independent_evidence =
      Cases.append_evidence!(
        incident.id,
        run.id,
        nil,
        "review-context-identity",
        "observation",
        "target",
        "linux-identity-current",
        %{
          "target_id" => initial_target.id,
          "status" => "applied",
          "operation" => "linux.identity.inspect",
          "facts" => %{"machine_id" => "responsive-guest"}
        },
        DateTime.utc_now(),
        authorize?: false
      )

    reviewing = Cases.route_proposal_authority!(proposal.id, authorize?: false)

    response = %AI.ReviewDecision{
      purpose_assessment: :remediation,
      verdict: :approved,
      reason: "The exact effect follows the cited evidence",
      usage: %AI.Usage{input_tokens: 3, output_tokens: 2}
    }

    invocation = %{
      test_pid: self(),
      respond: fn request ->
        key = Skopos.Cases.ResolutionRun.Budget.key("proposal:reviewer_assignment", proposal.id)
        event = Cases.case_event_by_idempotency!(incident.id, key, authorize?: false)
        assert event.data["provider_id"] == context.reviewer_provider.id
        assert event.data["assignment_id"] == context.reviewer_assignment.id
        assert request.session_id == "reviewer:#{proposal.id}"
        assert request.resolver_session_id == "resolver:#{run.id}"
        assert request.report_language == :ja
        refute request.session_id == request.resolver_session_id
        assert request.proposal.tool_id == proposal.tool_id
        assert request.proposal.affected_conditions == proposal.affected_conditions

        assert request.proposal.affected_conditions == []
        assert request.conditions == []

        assert request.initial_target_id == initial_target.id
        assert [%AI.TargetRelation{id: relation_id}] = request.target_relations
        assert relation_id == relation.id
        assert request.source_evidence == []

        refute request.objective =~ proposal.reason
        assert Enum.map(request.cited_evidence, & &1.id) == proposal.evidence_ids
        assert Enum.any?(request.context_evidence, &(&1.id == independent_evidence.id))
        assert Enum.all?(request.context_evidence, &is_integer(&1.observed_at_us))
        {:ok, response}
      end
    }

    assert :ok = ReviewDelivery.run(reviewing.id, ai_invocation: invocation)
    assert_receive {:review, %{model: "reviewer-model"}, _request}

    [decision] = Cases.list_review_decisions!(actor: context.admin)
    assert decision.outcome == :decision
    assert decision.verdict == :approved
    assert decision.selection_source == :assignment
    assert decision.provider_id == context.reviewer_provider.id
    assert decision.proposal_digest == proposal.proposal_digest
    assert decision.session_id != decision.resolver_session_id

    authorized = Cases.get_proposal!(proposal.id, authorize?: false)
    assert authorized.status == :authorized
    assert [approval] = Cases.list_approvals!(actor: context.admin)
    assert approval.source == :reviewer
    assert approval.proposal_digest == proposal.proposal_digest
    assert Cases.get_resolution_run!(run.id, authorize?: false).ai_usage_units == 5

    [record] = Cases.list_ai_invocations!(authorize?: false)
    assert record.status == :completed
    assert record.input_tokens == 3
    assert record.output_tokens == 2

    assert Cases.get_case!(incident.id, authorize?: false).pending_intent["action"] ==
             "dispatch_operation"

    assert acceptance_jobs(proposal.id) == 1

    assert :ok =
             ReviewDelivery.run(reviewing.id,
               ai_invocation: %{respond: fn _ -> flunk("accepted review called AI twice") end}
             )

    refute_receive {:review, _, _}
    assert acceptance_jobs(proposal.id) == 1
    refute_receive {:effect, _, _}
  end

  test "Reviewer sees the current direct Target relationship and loses it after deactivation",
       context do
    configure_mode!(:auto, context.admin)

    guest =
      Targets.create_target!("linked-guest", "host", "linux", %{}, nil, actor: context.admin)

    unrelated =
      Targets.create_target!("unrelated", "host", "linux", %{}, nil, actor: context.admin)

    relation =
      Targets.create_relationship!(
        guest.id,
        context.target.id,
        "hosted_by",
        %{"source" => "inventory"},
        nil,
        actor: context.admin
      )

    Targets.create_relationship!(
      guest.id,
      unrelated.id,
      "hosted_by",
      %{},
      nil,
      actor: context.admin
    )

    target =
      Targets.update_target!(
        context.target,
        context.target.revision,
        %{operating_instructions: "Do not modify root"},
        actor: context.admin
      )

    method =
      Targets.check_access_method!(context.method.id, context.method.revision, %{},
        actor: context.admin
      )

    {incident, _run, proposal} =
      proposal!(
        "linked-target",
        %{context | target: target, method: method} |> Map.put(:initial_target, guest),
        :effect
      )

    reviewing = Cases.route_proposal_authority!(proposal.id, authorize?: false)

    selection = %AI.Selection{
      role: :reviewer,
      provider_id: context.reviewer_provider.id,
      provider_revision: context.reviewer_provider.revision,
      assignment_id: context.reviewer_assignment.id,
      assignment_revision: context.reviewer_assignment.revision,
      source: :assignment
    }

    assert {:ok, request, _context} = ReviewProjection.build(reviewing.id, selection)
    assert request.initial_target_id == guest.id
    assert request.proposal.target_id == context.target.id
    assert request.operating_instructions == "Do not modify root"
    assert request.proposal.evidence_ids == Enum.map(request.cited_evidence, & &1.id)

    assert [%AI.TargetRelation{id: id, kind: "hosted_by"} = projected] =
             request.target_relations

    assert id == relation.id
    assert projected.source_target.id == guest.id
    assert projected.destination_target.id == context.target.id
    assert projected.revision == relation.revision

    Targets.deactivate_relationship!(relation, relation.revision, actor: context.admin)

    assert {:ok, changed, _context} = ReviewProjection.build(reviewing.id, selection)
    assert changed.initial_target_id == incident.initial_target_id
    assert changed.target_relations == []
  end

  test "Auto Reviewer accepts cited Case evidence preserved from a prior generation", context do
    configure_mode!(:auto, context.admin)

    signal_provider =
      Providers.create_provider!(
        "review-resumed-monitor",
        :signal,
        "fixture-signal",
        %{"source" => "review-monitor"},
        %{"secret" => "review-secret"},
        actor: context.admin
      )
      |> then(&Providers.check_provider!(&1.id, 1, %{}, actor: context.admin))
      |> then(&Providers.enable_provider!(&1, 1, actor: context.admin))

    Targets.create_external_identity!(
      context.target.id,
      "review-monitor",
      "hostname",
      context.target.name,
      actor: context.admin
    )

    occurred_at = DateTime.add(DateTime.utc_now(), -10, :second)

    Signals.ingest_signal!(
      signal_provider.id,
      signal_provider.revision,
      %Signal.Envelope{body: "review-initial", headers: %{}, received_at: occurred_at},
      %{
        authenticate: fn state, _envelope ->
          {:ok, %Signal.AuthenticatedReceipt{receipt_id: "review-initial", source: state.source}}
        end,
        normalize: fn _state, _envelope, _receipt ->
          {:ok,
           [
             %Signal.Event{
               receipt_id: "review-initial",
               event_key: "review-resumed-evidence",
               state: :firing,
               occurred_at: occurred_at,
               target_ref: %{kind: :hostname, value: context.target.name},
               attributes: %{
                 "labels" => %{"alertname" => "ServiceUnavailable", "service" => "api.service"}
               }
             }
           ]}
        end
      },
      authorize?: false
    )

    [incident] = Cases.list_cases!(actor: context.admin)

    first_run = Cases.active_resolution_run!(incident.id, authorize?: false)

    [prior_evidence] = Cases.signal_context_evidence!(incident.id, authorize?: false)

    waiting =
      Cases.require_case_attention!(
        incident.id,
        incident.revision,
        first_run.id,
        first_run.revision,
        "review-prior-generation-wait",
        "Resolver delivery failed",
        %{"action" => "retry_resolver"},
        "Retry Resolver delivery",
        authorize?: false
      )

    paused = Cases.active_resolution_run!(incident.id, authorize?: false)

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
      "Continue reviewing prior evidence",
      actor: context.operator
    )

    second_run = Cases.active_resolution_run!(incident.id, authorize?: false)
    assert second_run.generation == 2
    [started] = Cases.started_turns_for_run!(second_run.id, authorize?: false)

    {:ok, condition_revisions} =
      Skopos.Cases.Case.ConditionContext.current_condition_revisions(incident)

    turn =
      Cases.complete_turn!(
        started.id,
        started.revision,
        %{
          "outcome" => "decision",
          "condition_revisions" => condition_revisions,
          "intent" =>
            proposal_intent(prior_evidence.id, context, :effect)
            |> Map.put(
              "affected_conditions",
              Enum.map(condition_revisions, fn %{"id" => id, "revision" => revision} ->
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
        %{"action" => "route_resolver_decision", "turn_id" => started.id},
        "Review the Resolver decision",
        authorize?: false
      ).value

    Cases.route_downstream_decision!(turn.id, authorize?: false)

    reviewing =
      Cases.list_proposals!(authorize?: false)
      |> Enum.find(&(&1.source_turn_id == turn.id))

    assert reviewing.status == :reviewing

    selection = %AI.Selection{
      role: :reviewer,
      provider_id: context.reviewer_provider.id,
      provider_revision: context.reviewer_provider.revision,
      assignment_id: context.reviewer_assignment.id,
      assignment_revision: context.reviewer_assignment.revision,
      source: :assignment
    }

    assert {:ok, request, _context} = ReviewProjection.build(reviewing.id, selection)
    assert Cases.get_case!(incident.id, authorize?: false).status == :running
    assert Enum.map(request.cited_evidence, & &1.id) == [prior_evidence.id]
  end

  test "Auto reviews required chronology beyond 100 Target receipts and reconsiders once",
       context do
    configure_mode!(:auto, context.admin)

    {incident, run, proposal} = proposal!("review-rejection", context)
    reviewing = Cases.route_proposal_authority!(proposal.id, authorize?: false)
    initial_turn_count = length(Cases.list_turns!(actor: context.admin))

    observed_at = DateTime.utc_now()

    before_effect =
      Cases.append_evidence!(
        incident.id,
        run.id,
        nil,
        "review-rejection:reachable-before-effect",
        "observation",
        "target",
        "linux-identity",
        %{
          "target_id" => context.target.id,
          "operation" => "linux.identity.inspect",
          "status" => "applied",
          "facts" => %{"reachable" => true}
        },
        DateTime.add(observed_at, -10, :second),
        authorize?: false
      )

    applied_effect =
      Cases.append_evidence!(
        incident.id,
        run.id,
        nil,
        "review-rejection:prior-effect",
        "operation_outcome",
        "target",
        "bmc-power-reset",
        %{
          "target_id" => context.target.id,
          "operation" => "bmc.power.reset",
          "status" => "applied"
        },
        DateTime.add(observed_at, -5, :second),
        authorize?: false
      )

    after_effect =
      Cases.append_evidence!(
        incident.id,
        run.id,
        nil,
        "review-rejection:unreachable-after-effect",
        "observation",
        "target",
        "linux-identity",
        %{
          "target_id" => context.target.id,
          "operation" => "linux.identity.inspect",
          "status" => "failed",
          "facts" => %{"reachable" => false}
        },
        observed_at,
        authorize?: false
      )

    for index <- 1..101 do
      Cases.append_evidence!(
        incident.id,
        run.id,
        nil,
        "review-rejection:newer-target-#{index}",
        "observation",
        "target",
        "target-inspection",
        %{
          "target_id" => context.target.id,
          "operation" => "generic.inspect",
          "status" => "applied",
          "facts" => %{"sample" => index, "payload" => String.duplicate("x", 60_000)}
        },
        DateTime.add(observed_at, index, :microsecond),
        authorize?: false
      )
    end

    response = %AI.ReviewDecision{
      purpose_assessment: :remediation,
      verdict: :rejected,
      reason: "The guest was reachable before reset; the later failure may be caused by it",
      usage: %AI.Usage{input_tokens: 2, output_tokens: 2}
    }

    assert :ok =
             ReviewDelivery.run(reviewing.id,
               ai_invocation: %{
                 test_pid: self(),
                 respond: fn request ->
                   refute request.session_id == request.resolver_session_id
                   assert AI.input_size(request) <= AI.max_input_bytes()
                   assert length(request.context_evidence) < 10

                   chronology =
                     request.context_evidence
                     |> Enum.filter(
                       &(&1.id in [before_effect.id, applied_effect.id, after_effect.id])
                     )
                     |> Enum.sort_by(& &1.observed_at_us)

                   assert Enum.map(chronology, & &1.id) == [
                            before_effect.id,
                            applied_effect.id,
                            after_effect.id
                          ]

                   {:ok, response}
                 end
               }
             )

    assert_receive {:review, %{model: "reviewer-model"}, _request}
    [decision] = Cases.list_review_decisions!(actor: context.admin)
    assert decision.selection_source == :assignment
    assert decision.provider_id == context.reviewer_provider.id

    rejected = Cases.get_proposal!(proposal.id, authorize?: false)
    assert rejected.status == :rejected
    assert Cases.list_approvals!(actor: context.admin) == []

    turns = Cases.list_turns!(actor: context.admin)
    assert length(turns) == initial_turn_count + 1
    reconsideration = Enum.max_by(turns, & &1.ordinal)
    assert reconsideration.intent["rejected_proposal_id"] == proposal.id

    assert Cases.get_case!(incident.id, authorize?: false).pending_intent == %{
             "action" => "resolve_turn",
             "proposal_id" => proposal.id,
             "rejected_proposal_id" => proposal.id,
             "turn_id" => reconsideration.id
           }

    assert Cases.get_resolution_run!(run.id, authorize?: false).ai_usage_units == 4

    assert :ok =
             ReviewDelivery.run(reviewing.id,
               ai_invocation: %{respond: fn _ -> flunk("rejected review called AI twice") end}
             )

    assert length(Cases.list_turns!(actor: context.admin)) == initial_turn_count + 1
    refute_receive {:effect, _, _}
  end

  @tag reviewer_condition_before_send: true
  test "a built-in Reviewer Condition read fault retries without sending or changing authority",
       context do
    {incident, run, proposal, _signal_provider} = signal_proposal!(context)
    reviewing = Cases.route_proposal_authority!(proposal.id, authorize?: false)
    original_run = Cases.get_resolution_run!(run.id, authorize?: false)
    injected = :atomics.new(1, [])

    try do
      assert {:error, error} =
               ReviewDelivery.run(reviewing.id,
                 ai_invocation: %{
                   test_pid: self(),
                   cancelled?: fn ->
                     if :atomics.compare_exchange(injected, 1, 0, 1) == :ok do
                       Repo.query!(
                         "ALTER TABLE conditions RENAME COLUMN subject_key TO unavailable_subject_key"
                       )
                     end

                     false
                   end,
                   respond: fn _ -> flunk("unreadable Conditions were sent to Reviewer AI") end
                 }
               )

      assert Exception.message(error) =~ "subject_key"
    after
      if :atomics.get(injected, 1) == 1 do
        Repo.query!("ALTER TABLE conditions RENAME COLUMN unavailable_subject_key TO subject_key")
      end
    end

    refute_receive {:review, _, _}

    assert [%{status: :queued, dispatch_confirmed: false, usage_reported: false}] =
             Cases.list_ai_invocations!(authorize?: false)

    assert Cases.get_case!(incident.id, authorize?: false).status == :running
    assert Cases.get_proposal!(proposal.id, authorize?: false).status == :reviewing

    assert Cases.get_resolution_run!(run.id, authorize?: false).ai_usage_units ==
             original_run.ai_usage_units
  end

  @tag reviewer_condition_before_send: true
  test "a changed Condition before Reviewer send supersedes stale authority without charging AI",
       context do
    {incident, run, proposal, signal_provider} = signal_proposal!(context)
    reviewing = Cases.route_proposal_authority!(proposal.id, authorize?: false)
    original_run = Cases.get_resolution_run!(run.id, authorize?: false)
    injected = :atomics.new(1, [])

    assert :ok =
             ReviewDelivery.run(reviewing.id,
               ai_invocation: %{
                 test_pid: self(),
                 cancelled?: fn ->
                   if :atomics.compare_exchange(injected, 1, 0, 1) == :ok do
                     ingest_authority_signal!(
                       signal_provider,
                       context.target.name,
                       "review-recovered",
                       :recovered,
                       DateTime.utc_now()
                     )
                   end

                   false
                 end,
                 respond: fn _ -> flunk("changed Conditions were sent to Reviewer AI") end
               }
             )

    refute_receive {:review, _, _}
    assert Cases.get_case!(incident.id, authorize?: false).status == :running
    assert Cases.get_proposal!(proposal.id, authorize?: false).status == :invalidated
    assert Cases.list_approvals!(actor: context.admin) == []

    assert [%{status: :failed, dispatch_confirmed: false, usage_reported: false}] =
             Cases.list_ai_invocations!(authorize?: false)

    assert Cases.get_resolution_run!(run.id, authorize?: false).ai_usage_units ==
             original_run.ai_usage_units

    assert :ok = ReviewDelivery.run(reviewing.id)
    refute_receive {:review, _, _}
    assert Cases.get_case!(incident.id, authorize?: false).status == :running
  end

  for {read_fault?, schema_error?} <- [{false, false}, {true, false}, {true, true}] do
    @tag paid_proposal_context_read_fault: read_fault?,
         condition_read_fault: read_fault?,
         metered_proposal_error_context_read_fault: schema_error?,
         schema_error: schema_error?
    test "paid Proposal Review handles #{if read_fault?, do: "unavailable", else: "changed"} Conditions with #{if schema_error?, do: "schema error", else: "approval"} without applying stale authority",
         context do
      {incident, run, proposal, signal_provider} = signal_proposal!(context)

      reviewing = Cases.route_proposal_authority!(proposal.id, authorize?: false)

      response = %AI.ReviewDecision{
        purpose_assessment: :remediation,
        verdict: :approved,
        reason: "Approve the action based on the former firing Condition",
        usage: %AI.Usage{input_tokens: 3, output_tokens: 2}
      }

      try do
        result =
          ReviewDelivery.run(reviewing.id,
            delivery_attempt: 1,
            max_delivery_attempts: 3,
            ai_invocation: %{
              test_pid: self(),
              respond: fn _request ->
                if context.condition_read_fault do
                  Repo.query!(
                    "ALTER TABLE conditions RENAME COLUMN subject_key TO unavailable_subject_key"
                  )
                else
                  ingest_authority_signal!(
                    signal_provider,
                    context.target.name,
                    "review-recovered",
                    :recovered,
                    DateTime.utc_now()
                  )
                end

                if context.schema_error do
                  {:error, :invalid_output, "Object schema was rejected",
                   %AI.Usage{input_tokens: 3, output_tokens: 2}, "schema_validation"}
                else
                  {:ok, response}
                end
              end
            }
          )

        if context.condition_read_fault,
          do: assert(match?({:error, _}, result)),
          else: assert(result == :ok)
      after
        if context.condition_read_fault do
          Repo.query!(
            "ALTER TABLE conditions RENAME COLUMN unavailable_subject_key TO subject_key"
          )
        end
      end

      assert_receive {:review, %{model: "reviewer-model"}, _request}

      if context.condition_read_fault do
        assert Cases.get_proposal!(proposal.id, authorize?: false).status == :reviewing

        if context.schema_error do
          assert Cases.list_review_decisions!(actor: context.admin) == []

          assert [
                   %{
                     status: :failed,
                     category: "invalid_output",
                     failure_code: "schema_validation",
                     input_tokens: 3,
                     output_tokens: 2
                   }
                 ] = Cases.list_ai_invocations!(authorize?: false)

          assert Cases.get_case!(incident.id, authorize?: false).status == :running
          assert Cases.get_resolution_run!(run.id, authorize?: false).ai_usage_units == 5
          assert Cases.list_approvals!(actor: context.admin) == []
          assert Cases.list_operations!(actor: context.admin) == []

          for _ <- 1..2 do
            assert {:error, _} =
                     ReviewWorker.perform(%Oban.Job{
                       args: %{"proposal_id" => proposal.id},
                       attempt: 1,
                       max_attempts: 3
                     })
          end

          refute_receive {:review, _, _}
          assert Cases.get_resolution_run!(run.id, authorize?: false).ai_usage_units == 5

          assert :ok =
                   ReviewDelivery.run(proposal.id,
                     delivery_attempt: 2,
                     max_delivery_attempts: 3,
                     ai_invocation: %{
                       test_pid: self(),
                       respond: fn request ->
                         assert request.retry_context["rejection_code"] == "schema_validation"
                         {:ok, response}
                       end
                     }
                   )

          assert_receive {:review, _, _}
          assert Cases.get_proposal!(proposal.id, authorize?: false).status == :authorized
          assert Cases.get_resolution_run!(run.id, authorize?: false).ai_usage_units == 10
          assert [_approval] = Cases.list_approvals!(actor: context.admin)
          assert acceptance_jobs(proposal.id) == 1
        else
          assert [%{verdict: :approved, input_tokens: 3, output_tokens: 2}] =
                   Cases.list_review_decisions!(actor: context.admin)

          assert [%{status: :completed, category: nil}] =
                   Cases.list_ai_invocations!(authorize?: false)

          assert Cases.list_approvals!(actor: context.admin) == []
          assert Cases.list_operations!(actor: context.admin) == []
          assert Cases.get_resolution_run!(run.id, authorize?: false).ai_usage_units == 5

          for _ <- 1..2 do
            assert :ok = ReviewWorker.perform(%Oban.Job{args: %{"proposal_id" => proposal.id}})
          end

          refute_receive {:review, _, _}
          assert Cases.get_proposal!(proposal.id, authorize?: false).status == :authorized
          assert [_approval] = Cases.list_approvals!(actor: context.admin)
          assert acceptance_jobs(proposal.id) == 1
          assert Cases.get_resolution_run!(run.id, authorize?: false).ai_usage_units == 5
        end
      else
        assert Cases.get_proposal!(proposal.id, authorize?: false).status == :invalidated
        assert [%{verdict: :approved}] = Cases.list_review_decisions!(actor: context.admin)
        assert Cases.list_approvals!(actor: context.admin) == []
        assert Cases.list_operations!(actor: context.admin) == []
        assert Cases.get_resolution_run!(run.id, authorize?: false).ai_usage_units == 5

        [invocation] = Cases.list_ai_invocations!(authorize?: false)
        assert invocation.category == nil
        assert invocation.status == :completed

        current = Cases.get_case!(incident.id, authorize?: false)
        assert current.pending_intent["action"] == "resolve_turn"
        assert current.pending_intent["source_proposal_id"] == proposal.id
        assert [_reassessment] = Cases.started_turns_for_run!(run.id, authorize?: false)
      end
    end
  end

  test "Auto stops before review or effect when only Resolver is assigned", context do
    configure_mode!(:auto, context.admin)
    Skopos.TestAIUsage.configure!(context.reviewer_provider.id, :resolver, 10, context.admin)

    {incident, run, proposal} = proposal!("reviewer-unassigned", context)
    reviewing = Cases.route_proposal_authority!(proposal.id, authorize?: false)

    assert :ok = ReviewDelivery.run(reviewing.id)

    assert Cases.get_proposal!(proposal.id, authorize?: false).status == :invalidated
    stopped = Cases.get_case!(incident.id, authorize?: false)
    assert stopped.status == :needs_attention
    assert stopped.pending_intent["action"] == "restore_reviewer_delivery"
    assert Cases.get_resolution_run!(run.id, authorize?: false).status == :needs_attention
    assert Cases.list_review_decisions!(actor: context.admin) == []
    assert Cases.list_approvals!(actor: context.admin) == []
    refute_receive {:review, _, _}
    refute_receive {:effect, _, _}
  end

  test "a persisted Reviewer assignment cannot be replayed after its role is removed", context do
    configure_mode!(:auto, context.admin)
    {incident, _run, proposal} = proposal!("reviewer-role-removed", context)
    reviewing = Cases.route_proposal_authority!(proposal.id, authorize?: false)

    assert {:error, _retryable} =
             ReviewDelivery.run(reviewing.id,
               delivery_attempt: 1,
               max_delivery_attempts: 3,
               ai_invocation: %{
                 test_pid: self(),
                 respond: fn _request -> {:error, :timeout, "review deadline exceeded"} end
               }
             )

    assert_receive {:review, _, _}

    Skopos.TestAIUsage.configure!(context.reviewer_provider.id, :resolver, 10, context.admin)

    assert :ok =
             ReviewDelivery.run(reviewing.id,
               assignment_generation: 1,
               delivery_attempt: 2,
               max_delivery_attempts: 3
             )

    assert Cases.get_case!(incident.id, authorize?: false).status == :needs_attention
    assert Cases.list_review_decisions!(actor: context.admin) == []
    assert Cases.list_approvals!(actor: context.admin) == []
    refute_receive {:review, _, _}
    refute_receive {:effect, _, _}
  end

  test "Reviewer delivery retries remain autonomous and terminal failure stops the Case",
       context do
    configure_mode!(:auto, context.admin)
    {incident, run, proposal} = proposal!("review-timeout", context)
    reviewing = Cases.route_proposal_authority!(proposal.id, authorize?: false)

    for attempt <- 1..2 do
      assert {:error, message} =
               ReviewDelivery.run(reviewing.id,
                 delivery_attempt: attempt,
                 max_delivery_attempts: 3,
                 ai_invocation: %{
                   test_pid: self(),
                   respond: fn _request -> {:error, :timeout, "review deadline exceeded"} end
                 }
               )

      assert message =~ "attempt #{attempt} of 3"
      assert_receive {:review, _, _}
      assert Cases.get_proposal!(proposal.id, authorize?: false).status == :reviewing
      assert Cases.get_case!(incident.id, authorize?: false).status == :running
      assert Cases.list_review_decisions!(actor: context.admin) == []
    end

    assert :ok =
             ReviewDelivery.run(reviewing.id,
               delivery_attempt: 3,
               max_delivery_attempts: 3,
               ai_invocation: %{
                 test_pid: self(),
                 respond: fn _request -> {:error, :timeout, "review deadline exceeded"} end
               }
             )

    assert_receive {:review, _, _}
    assert Cases.list_review_decisions!(actor: context.admin) == []
    assert Cases.get_proposal!(proposal.id, authorize?: false).status == :invalidated

    stopped = Cases.get_case!(incident.id, authorize?: false)
    assert stopped.status == :needs_attention
    assert stopped.pending_intent["action"] == "restore_reviewer_delivery"
    assert stopped.pending_intent["proposal_id"] == proposal.id
    assert stopped.stop_reason == "Reviewer delivery failed: Reviewer AI timed out"

    assert Cases.get_resolution_run!(run.id, authorize?: false).status == :needs_attention
    records = Cases.list_ai_invocations!(authorize?: false)
    assert length(records) == 3
    assert Enum.all?(records, &(&1.reserved_units > 65_536 and not &1.usage_reported))

    assert Cases.get_resolution_run!(run.id, authorize?: false).ai_usage_units ==
             Enum.sum(Enum.map(records, & &1.reserved_units))

    assert Enum.all?(records, &(&1.status == :failed and &1.category == "timeout"))
    assert Cases.list_approvals!(actor: context.admin) == []
    refute_receive {:effect, _, _}
  end

  test "Reviewer schema rejection charges usage and never approves or disables the Provider",
       context do
    configure_mode!(:auto, context.admin)
    {_incident, run, proposal} = proposal!("review-schema-failover", context)
    reviewing = Cases.route_proposal_authority!(proposal.id, authorize?: false)

    assert :ok =
             ReviewDelivery.run(reviewing.id,
               ai_invocation: %{
                 test_pid: self(),
                 respond: fn _request ->
                   {:error, :invalid_output,
                    "AI provider JSON does not match the requested schema",
                    %AI.Usage{
                      input_tokens: 7,
                      output_tokens: 5,
                      cached_tokens: 3,
                      reasoning_tokens: 2,
                      finish_reason: "stop"
                    }, "schema_validation"}
                 end
               }
             )

    assert_receive {:review, %{model: "reviewer-model"}, _request}
    refute_receive {:review, _, _}

    failed_provider = Providers.get_provider!(context.reviewer_provider.id, authorize?: false)
    assert failed_provider.enabled
    assert failed_provider.check_status == :passed

    assert Cases.list_review_decisions!(actor: context.admin) == []
    assert Cases.get_proposal!(proposal.id, authorize?: false).status == :invalidated
    assert Cases.get_resolution_run!(run.id, authorize?: false).ai_usage_units == 12

    assert [
             %{
               input_tokens: 7,
               output_tokens: 5,
               cached_tokens: 3,
               reasoning_tokens: 2,
               finish_reason: "stop",
               category: "invalid_output",
               failure_code: "schema_validation"
             }
           ] =
             Cases.list_ai_invocations!(authorize?: false)
  end

  test "Reviewer invalid output corrects once on the assigned Provider and preserves usage",
       context do
    configure_mode!(:auto, context.admin)
    {incident, run, proposal} = proposal!("review-invalid-alternate", context)
    backup = ai_provider!(context.admin, "authority-reviewer-backup", "backup-reviewer-model")

    Skopos.TestAIUsage.configure!(backup.id, :reviewer, 20, context.admin)

    reviewing = Cases.route_proposal_authority!(proposal.id, authorize?: false)

    invalid = %{
      test_pid: self(),
      respond: fn request ->
        assert request.retry_context == nil

        {:error, :invalid_output, "AI provider output does not match schema",
         %AI.Usage{input_tokens: 11, output_tokens: 7}, "schema_validation", "/reason"}
      end
    }

    assert {:error, message} =
             ReviewDelivery.run(reviewing.id,
               delivery_attempt: 1,
               max_delivery_attempts: 3,
               ai_invocation: invalid
             )

    assert message =~ "invalid_output on attempt 1 of 3"
    assert_receive {:review, %{model: "reviewer-model"}, _request}
    assert Cases.get_proposal!(proposal.id, authorize?: false).status == :reviewing
    assert Cases.list_review_decisions!(actor: context.admin) == []
    refute_receive {:effect, _, _}
    assert [%{category: "invalid_output"}] = Cases.list_ai_invocations!(authorize?: false)

    assert {:error, ^message} =
             ReviewDelivery.run(reviewing.id,
               delivery_attempt: 1,
               max_delivery_attempts: 3,
               ai_invocation: %{respond: fn _ -> flunk("terminal failure called AI again") end}
             )

    response = %AI.ReviewDecision{
      purpose_assessment: :remediation,
      verdict: :approved,
      reason: "The assigned Reviewer accepted the cited Target evidence",
      usage: %AI.Usage{input_tokens: 3, output_tokens: 2}
    }

    assert :ok =
             ReviewDelivery.run(reviewing.id,
               delivery_attempt: 2,
               max_delivery_attempts: 3,
               ai_invocation: %{
                 test_pid: self(),
                 respond: fn request ->
                   assert request.retry_context == %{
                            "category" => "invalid_output",
                            "rejection_code" => "schema_validation",
                            "rejection_path" => "/reason"
                          }

                   {:ok, response}
                 end
               }
             )

    assert_receive {:review, %{model: "reviewer-model"}, _request}
    assert Cases.get_proposal!(proposal.id, authorize?: false).status == :authorized
    assert Cases.get_case!(incident.id, authorize?: false).status == :running
    assert Cases.get_resolution_run!(run.id, authorize?: false).ai_usage_units == 23

    assert [first, second] =
             Cases.list_ai_invocations!(authorize?: false)
             |> Enum.sort_by(& &1.idempotency_key)

    assert %{status: :failed, category: "invalid_output", input_tokens: 11, output_tokens: 7} =
             first

    assert first.provider_id == context.reviewer_provider.id
    assert first.rejection_path == "/reason"
    assert %{status: :completed, input_tokens: 3, output_tokens: 2} = second
    assert second.provider_id == context.reviewer_provider.id
    refute second.provider_id == backup.id
    refute_receive {:effect, _, _}
  end

  test "AI attempt result rejects invalid schema paths and cannot rewrite terminal diagnostics",
       context do
    {_incident, run, proposal} = proposal!("review-path-bounds", context)
    selection = Providers.select_reviewer_ai!([], authorize?: false)
    key = "review-path-bounds:attempt"

    invocation =
      Cases.create_ai_invocation_record!(
        %{
          case_id: proposal.case_id,
          resolution_run_id: run.id,
          proposal_id: proposal.id,
          provider_id: selection.provider_id,
          assignment_id: selection.assignment_id,
          role: :reviewer,
          idempotency_key: key,
          request_digest: Skopos.Cases.AIInvocation.request_digest(%{}),
          provider_revision: selection.provider_revision,
          assignment_revision: selection.assignment_revision,
          selection_source: selection.source,
          reserved_units: 65_536,
          dispatch_started_at: DateTime.utc_now()
        },
        authorize?: false
      )

    attrs = %{
      status: :failed,
      category: "invalid_output",
      failure_code: "schema_validation",
      usage: %AI.Usage{input_tokens: 7, output_tokens: 5},
      completed_at: DateTime.utc_now()
    }

    for path <- ["not-a-pointer", "/" <> String.duplicate("x", 200)] do
      assert {:error, _error} =
               Cases.record_ai_invocation_outcome(
                 invocation,
                 invocation.revision,
                 Map.put(attrs, :rejection_path, path),
                 authorize?: false
               )

      assert Cases.ai_invocation_by_idempotency!(key, authorize?: false).status == :dispatching
    end

    stored =
      Cases.record_ai_invocation_outcome!(
        invocation,
        invocation.revision,
        Map.put(attrs, :rejection_path, "/reason"),
        authorize?: false
      )

    assert {:error, _error} =
             Cases.record_ai_invocation_outcome(
               stored,
               stored.revision,
               Map.put(attrs, :rejection_path, "/verdict"),
               authorize?: false
             )

    assert %{rejection_path: "/reason", input_tokens: 7, output_tokens: 5} =
             Cases.ai_invocation_by_idempotency!(key, authorize?: false)
  end

  test "Reviewer repeated schema rejection stops after two paid calls without an alternate AI",
       context do
    configure_mode!(:auto, context.admin)
    {_incident, run, proposal} = proposal!("review-schema-no-fallback", context)

    Providers.disable_provider!(
      context.resolver_provider,
      context.resolver_provider.revision,
      actor: context.admin
    )

    reviewing = Cases.route_proposal_authority!(proposal.id, authorize?: false)

    assert {:error, message} =
             ReviewDelivery.run(reviewing.id,
               delivery_attempt: 1,
               max_delivery_attempts: 3,
               ai_invocation: %{
                 test_pid: self(),
                 respond: fn _request ->
                   {:error, :invalid_output,
                    "AI provider JSON does not match the requested schema",
                    %AI.Usage{input_tokens: 7, output_tokens: 5}}
                 end
               }
             )

    assert message =~ "invalid_output on attempt 1 of 3"
    assert_receive {:review, %{model: "reviewer-model"}, _request}

    assert {:error, second_message} =
             ReviewDelivery.run(reviewing.id,
               delivery_attempt: 2,
               max_delivery_attempts: 3,
               ai_invocation: %{
                 test_pid: self(),
                 respond: fn request ->
                   assert request.retry_context == %{
                            "category" => "invalid_output",
                            "rejection_code" => "invalid_output"
                          }

                   {:error, :invalid_output,
                    "AI provider JSON still does not match the requested schema",
                    %AI.Usage{input_tokens: 7, output_tokens: 5}}
                 end
               }
             )

    assert second_message =~ "invalid_output on attempt 2 of 3"
    assert_receive {:review, %{model: "reviewer-model"}, _request}

    assert :ok =
             ReviewDelivery.run(reviewing.id,
               delivery_attempt: 3,
               max_delivery_attempts: 3,
               ai_invocation: %{respond: fn _ -> flunk("no alternate called AI") end}
             )

    refute_receive {:review, _, _}
    assert Cases.get_proposal!(proposal.id, authorize?: false).status == :invalidated

    assert Cases.get_case!(proposal.case_id, authorize?: false).stop_reason =~
             "Reviewer output remained invalid"

    assert Cases.get_resolution_run!(run.id, authorize?: false).status == :needs_attention
    assert Cases.get_resolution_run!(run.id, authorize?: false).ai_usage_units == 24
  end

  test "Reviewer uses another assigned Provider after two metered invalid responses", context do
    configure_mode!(:auto, context.admin)
    {_incident, run, proposal} = proposal!("review-invalid-third", context)
    backup = ai_provider!(context.admin, "authority-reviewer-third", "backup-reviewer-model")
    Skopos.TestAIUsage.configure!(backup.id, :reviewer, 20, context.admin)
    reviewing = Cases.route_proposal_authority!(proposal.id, authorize?: false)

    for attempt <- 1..2 do
      assert {:error, _message} =
               ReviewDelivery.run(reviewing.id,
                 delivery_attempt: attempt,
                 max_delivery_attempts: 3,
                 ai_invocation: %{
                   test_pid: self(),
                   respond: fn request ->
                     if attempt == 2,
                       do: assert(request.retry_context["category"] == "invalid_output")

                     {:error, :invalid_output, "Review response schema is invalid",
                      %AI.Usage{input_tokens: 7, output_tokens: 5}, "schema_validation"}
                   end
                 }
               )

      assert_receive {:review, %{model: "reviewer-model"}, _request}
    end

    assert :ok =
             ReviewDelivery.run(reviewing.id,
               delivery_attempt: 3,
               max_delivery_attempts: 3,
               ai_invocation: %{
                 test_pid: self(),
                 respond: fn request ->
                   assert request.retry_context["rejection_code"] == "schema_validation"

                   {:ok,
                    %AI.ReviewDecision{
                      purpose_assessment: :remediation,
                      verdict: :rejected,
                      reason: "The alternate Reviewer rejected the proposal",
                      usage: %AI.Usage{input_tokens: 3, output_tokens: 2}
                    }}
                 end
               }
             )

    assert_receive {:review, %{model: "backup-reviewer-model"}, _request}
    assert Cases.get_resolution_run!(run.id, authorize?: false).ai_usage_units == 29

    invocations = Cases.list_ai_invocations!(authorize?: false)
    assert Enum.count(invocations, &(&1.provider_id == context.reviewer_provider.id)) == 2
    assert Enum.count(invocations, &(&1.provider_id == backup.id)) == 1
    assert Cases.get_proposal!(proposal.id, authorize?: false).status == :rejected
  end

  @tag owned_context_read_fault: true
  test "a changed Reviewer assignment after claim sends no proposal review", context do
    configure_mode!(:auto, context.admin)
    {incident, run, proposal} = proposal!("review-assignment-changed", context)
    reviewing = Cases.route_proposal_authority!(proposal.id, authorize?: false)
    changed = :atomics.new(1, [])

    assert {:error, _retry} =
             ReviewDelivery.run(reviewing.id,
               delivery_attempt: 1,
               max_delivery_attempts: 3,
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
                 respond: fn _request -> flunk("obsolete Reviewer assignment dispatched AI") end
               }
             )

    refute_receive {:review, _, _}

    assert [%{dispatch_confirmed: false, usage_reported: false, category: "context_changed"}] =
             Cases.list_ai_invocations!(authorize?: false)

    assert Cases.get_resolution_run!(run.id, authorize?: false).ai_usage_units == 0
    refute Cases.get_proposal!(proposal.id, authorize?: false).status == :authorized
    assert Cases.get_case!(incident.id, authorize?: false).status == :running
    assert Cases.get_proposal!(proposal.id, authorize?: false).status == :reviewing

    Skopos.Repo.query!(
      "ALTER TABLE ai_usage_role_assignments RENAME COLUMN priority TO unavailable_priority"
    )

    try do
      assert {:error, error} =
               ReviewDelivery.run(reviewing.id, delivery_attempt: 1, max_delivery_attempts: 3)

      assert Exception.message(error) =~ "priority"
    after
      Skopos.Repo.query!(
        "ALTER TABLE ai_usage_role_assignments RENAME COLUMN unavailable_priority TO priority"
      )
    end

    assert {:error, _retry} =
             ReviewDelivery.run(reviewing.id, delivery_attempt: 1, max_delivery_attempts: 3)

    refute_receive {:review, _, _}
    assert Cases.get_case!(incident.id, authorize?: false).status == :running
    assert Cases.get_resolution_run!(run.id, authorize?: false).ai_usage_units == 0

    assert :ok =
             ReviewDelivery.run(reviewing.id,
               delivery_attempt: 2,
               max_delivery_attempts: 3,
               ai_invocation: %{
                 test_pid: self(),
                 respond: fn _request ->
                   {:ok,
                    %AI.ReviewDecision{
                      purpose_assessment: :remediation,
                      verdict: :rejected,
                      reason: "The current Reviewer rejected the proposal",
                      usage: %AI.Usage{input_tokens: 3, output_tokens: 2}
                    }}
                 end
               }
             )

    assert_receive {:review, _, _}
    assert Cases.get_proposal!(proposal.id, authorize?: false).status == :rejected
    assert Cases.get_resolution_run!(run.id, authorize?: false).ai_usage_units == 5
    assert :ok = ReviewDelivery.run(reviewing.id, delivery_attempt: 1, max_delivery_attempts: 3)
    assert :ok = ReviewDelivery.run(reviewing.id, delivery_attempt: 2, max_delivery_attempts: 3)
    refute_receive {:review, _, _}
    assert Cases.get_resolution_run!(run.id, authorize?: false).ai_usage_units == 5
  end

  @tag owned_context_read_fault: true
  test "a built-in proposal Reviewer Case read fault remains an unsent retry", context do
    configure_mode!(:auto, context.admin)
    {incident, run, proposal} = proposal!("owned-review-context-read", context)
    reviewing = Cases.route_proposal_authority!(proposal.id, authorize?: false)
    original_run = Cases.get_resolution_run!(run.id, authorize?: false)
    injected = :atomics.new(1, [])

    try do
      assert {:error, error} =
               ReviewDelivery.run(reviewing.id,
                 ai_invocation: %{
                   test_pid: self(),
                   cancelled?: fn ->
                     if :atomics.compare_exchange(injected, 1, 0, 1) == :ok,
                       do:
                         Skopos.Repo.query!(
                           "ALTER TABLE cases RENAME COLUMN title TO unavailable_case_title"
                         )

                     false
                   end,
                   respond: fn _request -> flunk("an unreadable Case dispatched Reviewer AI") end
                 }
               )

      assert Exception.message(error) =~ "title"
    after
      if :atomics.get(injected, 1) == 1,
        do: Skopos.Repo.query!("ALTER TABLE cases RENAME COLUMN unavailable_case_title TO title")
    end

    refute_receive {:review, _, _}

    assert [%{status: :queued, dispatch_confirmed: false, usage_reported: false}] =
             Cases.list_ai_invocations!(authorize?: false)

    assert Cases.get_case!(incident.id, authorize?: false).status == :running
    assert Cases.get_proposal!(proposal.id, authorize?: false).status == :reviewing

    assert Cases.get_resolution_run!(run.id, authorize?: false).ai_usage_units ==
             original_run.ai_usage_units
  end

  @tag ai_unsent_retry: true
  test "a proposal Reviewer read fault retries its unsent invocation without stopping the Case",
       context do
    configure_mode!(:auto, context.admin)
    {incident, run, proposal} = proposal!("review-unsent-read", context)
    reviewing = Cases.route_proposal_authority!(proposal.id, authorize?: false)
    before_case = Cases.get_case!(incident.id, authorize?: false)
    before_run = Cases.get_resolution_run!(run.id, authorize?: false)
    before_proposal = Cases.get_proposal!(proposal.id, authorize?: false)

    assert {:error, error} =
             ReviewDelivery.run(reviewing.id,
               ai_invocation: %{
                 test_pid: self(),
                 cancelled?: fn ->
                   {:error, error} =
                     Skopos.Repo.query("SELECT invocation_context_unavailable", [],
                       mode: :savepoint
                     )

                   raise error
                 end,
                 respond: fn _request -> flunk("unsent Reviewer was called") end
               }
             )

    assert Exception.message(error) =~ "invocation_context_unavailable"
    refute_receive {:review, _, _}
    assert Cases.get_case!(incident.id, authorize?: false) == before_case
    assert Cases.get_resolution_run!(run.id, authorize?: false) == before_run
    assert Cases.get_proposal!(proposal.id, authorize?: false) == before_proposal

    assert [%{status: :queued, dispatch_confirmed: false} = unsent] =
             Cases.list_ai_invocations!(authorize?: false)

    assert unsent.dispatch_started_at == nil
    assert unsent.usage_reported == false

    assert :ok =
             ReviewDelivery.run(reviewing.id,
               delivery_attempt: 2,
               ai_invocation: %{
                 test_pid: self(),
                 respond: fn _request ->
                   {:ok,
                    %AI.ReviewDecision{
                      purpose_assessment: :remediation,
                      verdict: :approved,
                      reason: "The exact effect follows the cited evidence",
                      usage: %AI.Usage{input_tokens: 3, output_tokens: 2}
                    }}
                 end
               }
             )

    assert_receive {:review, _, _}

    assert [%{id: invocation_id, status: :completed}] =
             Cases.list_ai_invocations!(authorize?: false)

    assert invocation_id == unsent.id

    assert Cases.get_resolution_run!(run.id, authorize?: false).ai_usage_units ==
             before_run.ai_usage_units + 5

    assert :ok = ReviewDelivery.run(reviewing.id)
    refute_receive {:review, _, _}

    assert Cases.get_resolution_run!(run.id, authorize?: false).ai_usage_units ==
             before_run.ai_usage_units + 5
  end

  @tag ai_unsent_retry: true
  test "the AI retry action rejects sent, metered, unproved and terminal failures", context do
    {_incident, run, proposal} = proposal!("unsent-proof", context)
    selection = Providers.select_reviewer_ai!([], authorize?: false)

    invocation =
      Cases.create_ai_invocation_record!(
        %{
          case_id: proposal.case_id,
          resolution_run_id: run.id,
          proposal_id: proposal.id,
          provider_id: selection.provider_id,
          assignment_id: selection.assignment_id,
          role: :reviewer,
          idempotency_key: "unsent-proof",
          request_digest: Skopos.Cases.AIInvocation.request_digest(%{}),
          provider_revision: selection.provider_revision,
          assignment_revision: selection.assignment_revision,
          selection_source: selection.source,
          reserved_units: 65_536,
          dispatch_started_at: DateTime.utc_now()
        },
        authorize?: false
      )

    storage = Ash.Error.Unknown.UnknownError.exception(error: "Storage read failed")

    no_send =
      AI.Error.exception(category: :failed, message: "Local context failed", dispatched?: false)

    proof = Ash.Error.to_error_class([storage, no_send])

    for error <- [
          no_send,
          Ash.Error.to_error_class([storage, %{no_send | dispatched?: true}]),
          Ash.Error.to_error_class([storage, %{no_send | dispatched?: nil}]),
          Ash.Error.to_error_class([
            storage,
            %{no_send | usage: %AI.Usage{input_tokens: 0, output_tokens: 0}}
          ])
        ] do
      assert {:error, _error} =
               Cases.retry_unsent_ai_invocation(invocation, invocation.revision, error,
                 authorize?: false
               )
    end

    terminal =
      Cases.record_ai_invocation_outcome!(
        invocation,
        invocation.revision,
        %{status: :unknown, completed_at: DateTime.utc_now()},
        authorize?: false
      )

    assert {:error, _error} =
             Cases.retry_unsent_ai_invocation(terminal, terminal.revision, proof,
               authorize?: false
             )

    assert [%{status: :unknown}] = Cases.list_ai_invocations!(authorize?: false)
  end

  test "an interrupted Reviewer dispatch retries without a human approval request",
       context do
    configure_mode!(:auto, context.admin)
    {incident, run, proposal} = proposal!("review-interrupted", context)
    reviewing = Cases.route_proposal_authority!(proposal.id, authorize?: false)
    parent = self()

    task =
      Task.async(fn ->
        ReviewDelivery.run(reviewing.id,
          delivery_attempt: 1,
          max_delivery_attempts: 3,
          ai_invocation: %{
            test_pid: parent,
            respond: fn _request ->
              send(parent, :reviewer_remote_started)
              receive do: (:never -> :unreachable)
            end
          }
        )
      end)

    assert_receive {:review, _, _request}, 2_000
    assert_receive :reviewer_remote_started, 2_000
    assert nil == Task.shutdown(task, :brutal_kill)

    [dispatching] = Cases.list_ai_invocations!(authorize?: false)
    assert dispatching.role == :reviewer
    assert dispatching.status == :dispatching

    Skopos.TestAIUsage.configure!(context.reviewer_provider.id, :reviewer, 11, context.admin)

    Skopos.Repo.query!("""
    CREATE FUNCTION pg_temp.reject_interrupted_review_outcome() RETURNS trigger LANGUAGE plpgsql AS $$
    BEGIN
      IF NEW.status = 'unknown' THEN
        RAISE EXCEPTION 'injected interrupted review outcome persistence failure';
      END IF;
      RETURN NEW;
    END; $$;
    """)

    Skopos.Repo.query!("""
    CREATE TRIGGER reject_interrupted_review_outcome BEFORE UPDATE ON ai_invocations
    FOR EACH ROW EXECUTE FUNCTION pg_temp.reject_interrupted_review_outcome();
    """)

    try do
      assert {:error, error} =
               ReviewDelivery.run(reviewing.id, delivery_attempt: 1, max_delivery_attempts: 3)

      assert Exception.message(error) =~ "injected interrupted review outcome persistence failure"
    after
      Skopos.Repo.query!("DROP TRIGGER reject_interrupted_review_outcome ON ai_invocations")
    end

    assert [%{status: :dispatching}] = Cases.list_ai_invocations!(authorize?: false)
    assert Cases.get_resolution_run!(run.id, authorize?: false).ai_usage_units == 0
    assert Cases.get_case!(incident.id, authorize?: false).status == :running
    refute_receive {:review, _, _}

    assert {:error, retry_reason} =
             ReviewDelivery.run(reviewing.id,
               delivery_attempt: 1,
               max_delivery_attempts: 3,
               ai_invocation: %{
                 test_pid: self(),
                 respond: fn _request -> flunk("interrupted Reviewer called AI again") end
               }
             )

    assert retry_reason == "Reviewer response was lost on attempt 1 of 3"

    refute_receive {:review, _, _}

    [unknown] = Cases.list_ai_invocations!(authorize?: false)
    assert unknown.id == dispatching.id
    assert unknown.status == :unknown
    assert unknown.category == "response_unknown"
    assert unknown.failure_code == "response_unknown"
    assert unknown.reserved_units == dispatching.reserved_units
    assert unknown.reserved_units > 65_536

    assert Cases.list_review_decisions!(actor: context.admin) == []
    assert Cases.get_proposal!(proposal.id, authorize?: false).status == :reviewing

    assert Cases.get_resolution_run!(run.id, authorize?: false).ai_usage_units ==
             unknown.reserved_units

    assert Cases.get_case!(incident.id, authorize?: false).status == :running
    assert Cases.list_approvals!(actor: context.admin) == []
    refute_receive {:effect, _, _}

    response = %AI.ReviewDecision{
      purpose_assessment: :remediation,
      verdict: :approved,
      reason: "The bounded retry recovered the independent review",
      usage: %AI.Usage{input_tokens: 3, output_tokens: 2}
    }

    assert :ok =
             ReviewDelivery.run(reviewing.id,
               delivery_attempt: 2,
               max_delivery_attempts: 3,
               ai_invocation: %{
                 test_pid: self(),
                 respond: fn _request -> {:ok, response} end
               }
             )

    assert_receive {:review, _, _}
    assert Cases.get_proposal!(proposal.id, authorize?: false).status == :authorized
    assert [%{verdict: :approved}] = Cases.list_review_decisions!(actor: context.admin)
    assert [%{source: :reviewer}] = Cases.list_approvals!(actor: context.admin)

    records = Cases.list_ai_invocations!(authorize?: false)
    assert Enum.count(records, &(&1.status == :unknown)) == 1
    assert Enum.count(records, &(&1.status == :completed)) == 1

    events = Cases.list_case_events!(actor: context.admin)

    assert Enum.count(events, fn event ->
             event.data["request_key"] == "review-unknown:#{unknown.id}"
           end) == 1
  end

  test "Reviewer budget exhaustion stops the Case instead of requesting approval", context do
    configure_mode!(:auto, context.admin)
    {incident, run, proposal} = proposal!("review-budget", context)
    run = Cases.get_resolution_run!(run.id, authorize?: false)

    run =
      Cases.update_resolution_run_counters!(
        run,
        run.revision,
        %{ai_usage_units: run.max_ai_usage_units - 1},
        authorize?: false
      )

    reviewing = Cases.route_proposal_authority!(proposal.id, authorize?: false)

    assert :ok =
             ReviewDelivery.run(reviewing.id,
               ai_invocation: %{
                 test_pid: self(),
                 respond: fn _request ->
                   {:ok,
                    %AI.ReviewDecision{
                      purpose_assessment: :remediation,
                      verdict: :approved,
                      reason: "The exact observation is safe",
                      usage: %AI.Usage{input_tokens: 2, output_tokens: 2}
                    }}
                 end
               }
             )

    assert_receive {:review, _, _}
    assert Cases.list_review_decisions!(actor: context.admin) == []
    assert Cases.get_proposal!(proposal.id, authorize?: false).status == :invalidated

    stopped = Cases.get_case!(incident.id, authorize?: false)
    assert stopped.status == :needs_attention
    assert stopped.pending_intent["action"] == "review_ai_usage"

    assert stopped.required_human_input ==
             "Increase the AI usage limit or decide the Proposal manually"

    paused = Cases.get_resolution_run!(run.id, authorize?: false)
    assert paused.status == :needs_attention
    assert paused.ai_usage_units == run.ai_usage_units + 4

    [invocation] = Cases.list_ai_invocations!(authorize?: false)
    assert invocation.status == :failed
    assert invocation.category == "budget_exhausted"
    assert {invocation.input_tokens, invocation.output_tokens} == {2, 2}
    assert Cases.list_approvals!(actor: context.admin) == []

    assert :ok = ReviewDelivery.run(reviewing.id, ai_invocation: %{test_pid: self()})
    refute_receive {:review, _, _}

    assert Cases.get_resolution_run!(run.id, authorize?: false).ai_usage_units ==
             paused.ai_usage_units

    assert Cases.list_ai_invocations!(authorize?: false) == [invocation]
  end

  test "stale Target context invalidates Ask approval and cannot be overridden", context do
    configure_mode!(:ask, context.admin)
    {incident, run, proposal} = proposal!("stale", context)
    waiting = Cases.route_proposal_authority!(proposal.id, authorize?: false)

    Targets.update_access_method!(
      context.method,
      context.method.revision,
      %{priority: context.method.priority + 1},
      actor: context.admin
    )

    assert {:ok, invalidated} =
             Cases.decide_proposal(
               waiting.id,
               waiting.revision,
               waiting.proposal_digest,
               :approved,
               "Approve only if the route is unchanged",
               actor: context.operator
             )

    assert invalidated.status == :invalidated
    assert Cases.list_approvals!(actor: context.admin) == []
    assert Cases.get_case!(incident.id, authorize?: false).status == :needs_attention
    assert Cases.get_resolution_run!(run.id, authorize?: false).status == :needs_attention
    refute_receive {:effect, _, _}
  end

  test "FullAccess invalidates a Proposal when Target instructions change", context do
    configure_mode!(:full_access, context.admin)
    {incident, run, proposal} = proposal!("policy-change", context)

    Targets.update_target!(
      context.target,
      context.target.revision,
      %{operating_instructions: "Do not restart API"},
      actor: context.admin
    )

    invalidated = Cases.route_proposal_authority!(proposal.id, authorize?: false)

    assert invalidated.status == :invalidated
    assert Cases.list_approvals!(actor: context.admin) == []
    assert Cases.get_case!(incident.id, authorize?: false).status == :needs_attention
    assert Cases.get_resolution_run!(run.id, authorize?: false).effect_count == 0
    refute_receive {:effect, _, _}
  end

  test "durable expiration pauses an awaiting human Case without an effect", context do
    configure_mode!(:ask, context.admin)
    {incident, run, proposal} = proposal!("expired", context)
    waiting = Cases.route_proposal_authority!(proposal.id, authorize?: false)

    assert [job] =
             Skopos.Repo.all(
               from(item in Oban.Job,
                 where:
                   item.worker == ^Oban.Worker.to_string(ProposalExpirationWorker) and
                     fragment("?->>'proposal_id'", item.args) == ^waiting.id
               )
             )

    assert job.state == "scheduled"

    Skopos.Repo.update_all(
      from(item in Skopos.Cases.Proposal, where: item.id == ^waiting.id),
      set: [expires_at: DateTime.add(DateTime.utc_now(), -1, :second)]
    )

    assert :ok = ProposalExpirationWorker.perform(job)
    assert :ok = ProposalExpirationWorker.perform(job)

    assert Cases.get_proposal!(waiting.id, authorize?: false).status == :invalidated

    stopped = Cases.get_case!(incident.id, authorize?: false)
    assert stopped.status == :needs_attention

    assert stopped.pending_intent == %{
             "action" => "review_expired_proposal",
             "proposal_id" => waiting.id
           }

    assert Cases.get_resolution_run!(run.id, authorize?: false).status == :needs_attention

    assert Enum.count(
             Cases.list_case_events!(actor: context.admin),
             &(&1.case_id == incident.id and &1.event_type == "case_needs_attention")
           ) == 1

    assert {:error, _error} =
             Cases.decide_proposal(
               waiting.id,
               waiting.revision,
               waiting.proposal_digest,
               :approved,
               "Expired input must fail",
               actor: context.operator
             )

    assert Cases.list_approvals!(actor: context.admin) == []
    assert Cases.list_operations!(actor: context.admin) == []
    refute_receive {:effect, _, _}
  end

  test "revoked human authority fails without a decision", context do
    configure_mode!(:ask, context.admin)
    {_incident, _run, proposal} = proposal!("revoked", context)
    waiting = Cases.route_proposal_authority!(proposal.id, authorize?: false)

    Accounts.change_role!(context.operator, :viewer, actor: context.admin)

    assert {:error, _error} =
             Cases.decide_proposal(
               waiting.id,
               waiting.revision,
               waiting.proposal_digest,
               :approved,
               "Revoked authority must fail",
               actor: context.operator
             )

    assert Cases.list_approvals!(actor: context.admin) == []
    refute_receive {:effect, _, _}
  end

  test "concurrent late approval and expiry stop once without dispatch", context do
    configure_mode!(:ask, context.admin)
    {incident, run, proposal} = proposal!("expiry-race", context)
    waiting = Cases.route_proposal_authority!(proposal.id, authorize?: false)

    Skopos.Repo.update_all(
      from(item in Skopos.Cases.Proposal, where: item.id == ^waiting.id),
      set: [expires_at: DateTime.add(DateTime.utc_now(), -1, :second)]
    )

    [decision, expiry] =
      [
        Task.async(fn ->
          Cases.decide_proposal(
            waiting.id,
            waiting.revision,
            waiting.proposal_digest,
            :approved,
            "Late concurrent approval",
            actor: context.operator
          )
        end),
        Task.async(fn ->
          ProposalExpirationWorker.perform(%Oban.Job{args: %{"proposal_id" => waiting.id}})
        end)
      ]
      |> Task.await_many(10_000)

    assert {:error, _error} = decision
    assert expiry == :ok
    assert Cases.get_proposal!(waiting.id, authorize?: false).status == :invalidated
    assert Cases.get_case!(incident.id, authorize?: false).status == :needs_attention
    assert Cases.get_resolution_run!(run.id, authorize?: false).status == :needs_attention
    assert Cases.list_approvals!(actor: context.admin) == []
    assert Cases.list_operations!(actor: context.admin) == []
  end

  defp proposal!(suffix, context, request_kind \\ :effect, reason \\ nil) do
    initial_target = Map.get(context, :initial_target, context.target)

    incident =
      Cases.open_case!(
        :manual,
        "test",
        "authority-#{suffix}",
        "Authority #{suffix}",
        :warning,
        %{"desired_outcome" => "Target responds as expected"},
        initial_target.id,
        :en,
        actor: context.operator
      )

    incident =
      if initial_target.id == context.target.id do
        incident
      else
        Cases.record_case_selected_target!(
          incident,
          incident.revision,
          context.target.id,
          context.target.revision,
          authorize?: false
        )
      end

    proposal_for_case!(incident, suffix, context, request_kind, reason)
  end

  defp signal_proposal!(context) do
    configure_mode!(:auto, context.admin)
    enable_signal_automation!(context.admin)

    signal_provider =
      Providers.create_provider!(
        "authority-native-monitor",
        :signal,
        "fixture-signal",
        %{"source" => "authority-native"},
        %{"secret" => "authority-native-secret"},
        actor: context.admin
      )
      |> then(&Providers.check_provider!(&1.id, 1, %{}, actor: context.admin))
      |> then(&Providers.enable_provider!(&1, 1, actor: context.admin))

    Targets.create_external_identity!(
      context.target.id,
      "authority-native",
      "hostname",
      context.target.name,
      actor: context.admin
    )

    ingest_authority_signal!(
      signal_provider,
      context.target.name,
      "review-firing",
      :firing,
      DateTime.add(DateTime.utc_now(), -10, :second)
    )

    [incident] = Cases.list_cases!(actor: context.admin)
    %{status: :sent} = Cases.send_initial_case_turn!(incident.id, authorize?: false)
    run = Cases.active_resolution_run!(incident.id, authorize?: false)
    [started] = Cases.started_turns_for_run!(run.id, authorize?: false)
    [source_evidence] = Cases.signal_context_evidence!(incident.id, authorize?: false)

    {incident, run, proposal} =
      proposal_for_case!(incident, "native-review", context, :effect, nil,
        started: started,
        evidence: source_evidence
      )

    {incident, run, proposal, signal_provider}
  end

  defp ingest_authority_signal!(
         provider,
         target_name,
         receipt_id,
         state,
         occurred_at,
         extras \\ %{}
       ) do
    Signals.ingest_signal!(
      provider.id,
      provider.revision,
      %Signal.Envelope{body: receipt_id, headers: %{}, received_at: occurred_at},
      %{
        authenticate: fn provider_state, _envelope ->
          {:ok,
           %Signal.AuthenticatedReceipt{receipt_id: receipt_id, source: provider_state.source}}
        end,
        normalize: fn _state, _envelope, _receipt ->
          {:ok,
           [
             %Signal.Event{
               receipt_id: receipt_id,
               event_key: "native-review-service",
               state: state,
               occurred_at: occurred_at,
               target_ref: %{kind: :hostname, value: target_name},
               attributes:
                 Map.merge(
                   %{
                     "labels" => %{
                       "alertname" => "ServiceUnavailable",
                       "service" => "api.service"
                     }
                   },
                   extras
                 )
             }
           ]}
        end
      },
      authorize?: false
    )
  end

  defp proposal_for_case!(incident, suffix, context, request_kind, reason, opts \\ []) do
    run = Cases.active_resolution_run!(incident.id, authorize?: false)

    evidence =
      Keyword.get_lazy(opts, :evidence, fn ->
        Cases.append_evidence!(
          incident.id,
          run.id,
          nil,
          "authority-evidence-#{suffix}",
          "observation",
          "fixture",
          "observation-#{suffix}",
          %{"service" => "unhealthy"},
          DateTime.utc_now(),
          authorize?: false
        )
      end)

    started =
      Keyword.get_lazy(opts, :started, fn ->
        Cases.start_turn!(
          incident.id,
          run.id,
          "authority-turn-#{suffix}",
          %{"objective" => "Restore the service"},
          %{"action" => "continue"},
          "Review Resolver limits",
          authorize?: false
        ).value
      end)

    intent = proposal_intent(evidence.id, context, request_kind)

    intent =
      if incident.trigger_kind == :signal and request_kind == :effect do
        {:ok, conditions} = Skopos.Cases.Case.ConditionContext.current_conditions(incident)

        Map.put(
          intent,
          "affected_conditions",
          Enum.map(conditions, &%{"condition_id" => &1.id, "revision" => &1.revision})
        )
      else
        intent
      end

    intent = if is_binary(reason), do: Map.put(intent, "reason", reason), else: intent

    result =
      %{
        "outcome" => "decision",
        "intent" => intent,
        "resolver" => %{
          "provider_id" => context.resolver_provider.id,
          "provider_revision" => context.resolver_provider.revision,
          "assignment_id" => context.resolver_assignment.id,
          "assignment_revision" => context.resolver_assignment.revision
        },
        "usage" => %{"input_tokens" => 1, "output_tokens" => 1}
      }

    result =
      if incident.trigger_kind == :signal do
        {:ok, revisions} =
          Skopos.Cases.Case.ConditionContext.current_condition_revisions(incident)

        Map.put(result, "condition_revisions", revisions)
      else
        result
      end

    turn =
      Cases.complete_turn!(
        started.id,
        started.revision,
        result,
        :proposal,
        %{"action" => "route_resolver_decision", "turn_id" => started.id},
        "Review the Resolver decision",
        authorize?: false
      ).value

    proposal = Cases.materialize_proposal!(turn.id, authorize?: false)
    {incident, run, proposal}
  end

  defp proposal_intent(evidence_id, context, :effect) do
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
      "selectors" => %{"service" => "api"},
      "parameters" => %{"service" => "api"},
      "reason" => "Restart the unhealthy API service",
      "evidence_ids" => [evidence_id],
      "affected_conditions" => [],
      "expected_result" => %{"service" => "running"},
      "tool" => tool,
      "verification_intent" => %{
        "tool_id" => "verification-tool",
        "selectors" => %{"service" => "api"},
        "parameters" => %{"service" => "api"},
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
      "selectors" => %{"service" => "api"},
      "parameters" => %{"service" => "api"},
      "reason" => "Inspect the unhealthy API service",
      "evidence_ids" => [evidence_id],
      "affected_conditions" => [],
      "expected_result" => %{},
      "tool" => tool,
      "verification_intent" => %{},
      "verification_tool" => %{}
    }
  end

  defp configure_mode!(mode, admin) do
    current = Cases.current_authority_setting!(actor: admin)

    Cases.configure_authority_setting!(
      current.setting_revision,
      mode,
      current.signal_automation_enabled,
      current.max_elapsed_seconds,
      current.max_resolver_turns,
      current.max_target_requests,
      current.max_effects,
      current.max_related_targets,
      current.max_ai_usage_units,
      current.max_no_progress_turns,
      "test #{mode} Proposal routing",
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
      "Enable native Signal review verification",
      actor: admin
    )
  end

  defp ai_provider!(admin, name, model) do
    Providers.create_provider!(
      name,
      :ai,
      "fixture-ai",
      %{"model" => model},
      %{"api_key" => "#{name}-secret"},
      actor: admin
    )
    |> then(&Providers.check_provider!(&1.id, 1, %{}, actor: admin))
    |> then(&Providers.enable_provider!(&1, 1, actor: admin))
  end

  defp review_jobs(proposal_id) do
    Skopos.Repo.aggregate(
      from(job in Oban.Job,
        where:
          job.worker == ^Oban.Worker.to_string(ReviewWorker) and
            fragment("?->>'proposal_id'", job.args) == ^proposal_id
      ),
      :count
    )
  end

  defp acceptance_jobs(proposal_id) do
    Skopos.Repo.aggregate(
      from(job in Oban.Job,
        where:
          job.worker == ^Oban.Worker.to_string(OperationAcceptanceWorker) and
            fragment("?->>'proposal_id'", job.args) == ^proposal_id
      ),
      :count
    )
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
end
