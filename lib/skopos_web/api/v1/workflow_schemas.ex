defmodule SkoposWeb.API.V1.WorkflowSchemas do
  @moduledoc false

  alias OpenApiSpex.Schema
  alias SkoposWeb.API.Schemas

  def components do
    %{
      "AuthoritySetting" => authority_setting(),
      "SetupReadinessResponse" => Schemas.data(ref("SetupReadiness")),
      "SetupReadiness" =>
        object(
          %{
            ai: %Schema{type: :boolean},
            resolver: %Schema{type: :boolean},
            reviewer: %Schema{type: :boolean},
            authority: %Schema{type: :boolean},
            signal: %Schema{type: :boolean},
            target: %Schema{type: :boolean},
            complete: %Schema{type: :boolean},
            authority_mode: %Schema{type: :string, enum: ~w(readonly ask auto full_access)},
            sole_reviewer_provider_id: %{Schemas.uuid() | nullable: true},
            first_target_id: %{Schemas.uuid() | nullable: true}
          },
          [
            :ai,
            :resolver,
            :reviewer,
            :authority,
            :signal,
            :target,
            :complete,
            :authority_mode,
            :sole_reviewer_provider_id,
            :first_target_id
          ],
          false
        ),
      "AuthoritySettingResponse" => Schemas.data(ref("AuthoritySetting")),
      "AuthoritySettingPage" => Schemas.page(ref("AuthoritySetting")),
      "UpdateAuthoritySettingRequest" => update_authority_request(),
      "Case" => case_record(),
      "CaseResponse" => Schemas.data(ref("Case")),
      "CasePage" => Schemas.page(ref("Case")),
      "CaseSummary" => summary(case_record(), Skopos.Cases.Case.summary_fields()),
      "CaseSummaryPage" => Schemas.page(ref("CaseSummary")),
      "CreateCaseRequest" => create_case_request(),
      "CaseRevisionRequest" => case_revision_request(),
      "SplitCaseRequest" => split_case_request(),
      "HandoffCaseRequest" => handoff_request(),
      "ResumeCaseRequest" => resume_request(),
      "CaseSnapshot" => snapshot(),
      "CaseAIUsage" => ai_usage(),
      "AIInvocation" => ai_invocation(),
      "AIInvocationPage" => Schemas.page(ref("AIInvocation")),
      "CaseSnapshotResponse" => Schemas.data(ref("CaseSnapshot")),
      "CaseCondition" => case_condition(),
      "CaseConditionMembership" => case_condition_membership(),
      "CaseConditionMembershipPage" => Schemas.page(ref("CaseConditionMembership")),
      "ResolutionRun" => resolution_run(),
      "ResolutionRunResponse" => Schemas.data(ref("ResolutionRun")),
      "CaseEvent" => event(),
      "CaseEventPage" => Schemas.page(ref("CaseEvent")),
      "ResolverTurn" => turn(),
      "ResolverTurnResponse" => Schemas.data(ref("ResolverTurn")),
      "ResolverTurnSummary" => turn_summary(),
      "ResolverTurnPage" => Schemas.page(ref("ResolverTurnSummary")),
      "TurnConditionContext" =>
        summary(
          turn(),
          ~w(id ordinal revision completed_at condition_revisions condition_groups condition_assessments)a
        ),
      "Evidence" => evidence(),
      "EvidenceResponse" => Schemas.data(ref("Evidence")),
      "EvidenceSummary" => evidence_summary(),
      "EvidencePage" => Schemas.page(ref("EvidenceSummary")),
      "Approval" => approval(),
      "ApprovalPage" => Schemas.page(ref("Approval")),
      "ReviewDecision" => review_decision(),
      "ReviewDecisionPage" => Schemas.page(ref("ReviewDecision")),
      "Proposal" => proposal(),
      "ProposalSummary" => summary(proposal(), Skopos.Cases.Proposal.summary_fields()),
      "ProposalPage" => Schemas.page(ref("ProposalSummary")),
      "ProposalResponse" => Schemas.data(ref("Proposal")),
      "DecideProposalRequest" => decide_proposal_request(),
      "Operation" => operation(),
      "OperationSummary" => summary(operation(), Skopos.Cases.Operation.summary_fields()),
      "OperationResponse" => Schemas.data(ref("Operation")),
      "OperationPage" => Schemas.page(ref("OperationSummary")),
      "VerificationAttempt" => verification_attempt(),
      "VerificationAttemptSummary" =>
        summary(verification_attempt(), Skopos.Cases.VerificationAttempt.summary_fields()),
      "VerificationAttemptResponse" => Schemas.data(ref("VerificationAttempt")),
      "VerificationAttemptPage" => Schemas.page(ref("VerificationAttemptSummary")),
      "WorkflowLimits" => limits(),
      "ResolutionCounters" => counters()
    }
  end

  def ref(name), do: Schemas.reference(name)

  def case_page_parameters do
    Schemas.pagination_parameters() ++
      [
        query: [in: :query, schema: %Schema{type: :string, minLength: 1, maxLength: 200}],
        status: [
          in: :query,
          schema: %Schema{type: :string, enum: ~w(running needs_attention resolved cancelled)}
        ],
        sort: [
          in: :query,
          schema: %Schema{
            type: :string,
            enum: ~w(updated_desc updated_asc severity_desc),
            default: "updated_desc"
          }
        ]
      ]
  end

  defp authority_setting do
    object(
      %{
        id: Schemas.uuid(),
        authority_mode: authority_mode(),
        signal_automation_enabled: %Schema{type: :boolean},
        max_elapsed_seconds: integer(60, 2_592_000),
        max_resolver_turns: integer(1, 1_000),
        max_target_requests: integer(1, 10_000),
        max_effects: integer(0, 1_000),
        max_related_targets: integer(0, 1_000),
        max_ai_usage_units: integer(1, 1_000_000_000),
        max_no_progress_turns: integer(1, 100),
        setting_revision: positive_integer(),
        active: %Schema{type: :boolean},
        reason: string(1, 500),
        changed_by_id: nullable_uuid(),
        inserted_at: Schemas.timestamp(),
        updated_at: Schemas.timestamp()
      },
      ~w(id authority_mode signal_automation_enabled max_elapsed_seconds max_resolver_turns max_target_requests max_effects max_related_targets max_ai_usage_units max_no_progress_turns setting_revision active reason changed_by_id inserted_at updated_at)a,
      false
    )
  end

  defp update_authority_request do
    wrapped(
      :authority_setting,
      %{
        expected_setting_revision: positive_integer(),
        authority_mode: authority_mode(),
        signal_automation_enabled: %Schema{type: :boolean},
        max_elapsed_seconds: integer(60, 2_592_000),
        max_resolver_turns: integer(1, 1_000),
        max_target_requests: integer(1, 10_000),
        max_effects: integer(0, 1_000),
        max_related_targets: integer(0, 1_000),
        max_ai_usage_units: integer(1, 1_000_000_000),
        max_no_progress_turns: integer(1, 100),
        reason: string(1, 500)
      },
      ~w(expected_setting_revision authority_mode signal_automation_enabled max_elapsed_seconds max_resolver_turns max_target_requests max_effects max_related_targets max_ai_usage_units max_no_progress_turns reason)a
    )
  end

  defp case_record do
    object(
      %{
        id: Schemas.uuid(),
        trigger_kind: enum(~w(manual signal audit)),
        source: string(1, 120),
        source_ref: string(1, 500),
        split_parent_id: nullable_uuid(),
        title: string(1, 200),
        severity: enum(~w(info warning error critical)),
        condition_count: nullable_non_negative_integer(),
        firing_condition_count: nullable_non_negative_integer(),
        report_language: enum(~w(en ja)),
        status: enum(~w(running needs_attention resolved cancelled)),
        operator_action: enum(~w(none decision_required input_required intervention_required)),
        pending_proposal_id: nullable_uuid(),
        initial_context: map(),
        case_symptom: Schemas.case_symptom(true),
        authority_setting_id: Schemas.uuid(),
        authority_setting_revision: positive_integer(),
        authority_mode: authority_mode(),
        limits: ref("WorkflowLimits"),
        cancel_requested: %Schema{type: :boolean},
        stop_reason: nullable_string(500),
        required_human_input: nullable_string(1_000),
        resolved_at: nullable_timestamp(),
        initial_target_id: nullable_uuid(),
        selected_target_id: nullable_uuid(),
        selected_target_revision: nullable_positive_integer(),
        current_owner_id: nullable_uuid(),
        revision: positive_integer(),
        inserted_at: Schemas.timestamp(),
        updated_at: Schemas.timestamp()
      },
      ~w(id trigger_kind source source_ref split_parent_id title severity condition_count firing_condition_count report_language status operator_action pending_proposal_id initial_context case_symptom authority_setting_id authority_setting_revision authority_mode limits cancel_requested stop_reason required_human_input resolved_at initial_target_id selected_target_id selected_target_revision current_owner_id revision inserted_at updated_at)a,
      false
    )
  end

  defp create_case_request do
    wrapped(
      :case,
      %{
        trigger_kind: enum(~w(manual)),
        source: string(1, 120),
        source_ref: string(1, 500),
        title: string(1, 200),
        severity: enum(~w(info warning error critical)),
        initial_context:
          object(
            %{
              desired_outcome: string(1, 2_000),
              observed_problem: string(1, 2_000)
            },
            [:desired_outcome],
            true
          ),
        initial_target_id: nullable_uuid()
      },
      ~w(trigger_kind source source_ref title severity initial_context)a
    )
  end

  defp case_revision_request do
    wrapped(:case, %{expected_revision: positive_integer()}, [:expected_revision])
  end

  defp split_case_request do
    wrapped(
      :case,
      %{
        expected_revision: positive_integer(),
        condition_ids: array(Schemas.uuid()),
        expected_conditions:
          array(
            object(%{id: Schemas.uuid(), revision: positive_integer()}, [:id, :revision], false)
          ),
        reason: string(1, 500)
      },
      [:expected_revision, :condition_ids, :expected_conditions, :reason]
    )
  end

  defp handoff_request do
    wrapped(
      :case,
      %{expected_revision: positive_integer(), owner_id: Schemas.uuid()},
      [:expected_revision, :owner_id]
    )
  end

  defp resume_request do
    wrapped(
      :case,
      %{
        expected_case_revision: positive_integer(),
        resolution_run_id: Schemas.uuid(),
        expected_run_revision: positive_integer(),
        authority_mode: authority_mode(),
        max_elapsed_seconds: integer(60, 2_592_000),
        max_resolver_turns: integer(1, 1_000),
        max_target_requests: integer(1, 10_000),
        max_effects: integer(0, 1_000),
        max_related_targets: integer(0, 1_000),
        max_ai_usage_units: integer(1, 1_000_000_000),
        max_no_progress_turns: integer(1, 100),
        reason: string(1, 500)
      },
      ~w(expected_case_revision resolution_run_id expected_run_revision authority_mode max_elapsed_seconds max_resolver_turns max_target_requests max_effects max_related_targets max_ai_usage_units max_no_progress_turns reason)a
    )
  end

  defp snapshot do
    object(
      %{
        case: ref("Case"),
        ai_usage: ref("CaseAIUsage"),
        conditions: array(ref("CaseCondition")),
        condition_context:
          object(
            %{
              groups: %Schema{allOf: [ref("TurnConditionContext")], nullable: true},
              assessments: %Schema{allOf: [ref("TurnConditionContext")], nullable: true}
            },
            [:groups, :assessments],
            false
          ),
        resolution_runs: array(ref("ResolutionRun")),
        proposals: array(ref("ProposalSummary")),
        operations: array(ref("OperationSummary")),
        verification_attempts: array(ref("VerificationAttemptSummary")),
        reports: array(ref("ReportSummary"))
      },
      [
        :case,
        :ai_usage,
        :conditions,
        :condition_context,
        :resolution_runs,
        :proposals,
        :operations,
        :verification_attempts,
        :reports
      ],
      false
    )
  end

  defp ai_usage do
    counts =
      ~w(reported_input_tokens reported_output_tokens reported_total_tokens reported_invocations unknown_invocations pending_invocations not_dispatched_invocations budget_charged_units unknown_reserved_units pending_reserved_units)a

    properties =
      Map.new(counts, &{&1, non_negative_integer()})
      |> Map.put(:complete, %Schema{type: :boolean})
      |> Map.put(:budget_charged_units, %{
        non_negative_integer()
        | description:
            "Reported tokens plus allowances for unreported usage; not an invoiced amount."
      })

    object(properties, counts ++ [:complete], false)
  end

  defp ai_invocation do
    properties = %{
      id: Schemas.uuid(),
      case_id: Schemas.uuid(),
      resolution_run_id: Schemas.uuid(),
      provider_id: Schemas.uuid(),
      turn_id: nullable_uuid(),
      proposal_id: nullable_uuid(),
      role: enum(~w(resolver reviewer)),
      status: enum(~w(queued dispatching completed failed unknown)),
      usage_status: enum(~w(reported unknown pending not_dispatched)),
      dispatch_confirmed: %Schema{type: :boolean, nullable: true},
      reserved_units: %{
        positive_integer()
        | description:
            "Input-capacity allowance for unreported usage, capped by remaining run budget; not measured tokens or a billing limit."
      },
      input_tokens: nullable_non_negative_integer(),
      output_tokens: nullable_non_negative_integer(),
      cached_tokens: nullable_non_negative_integer(),
      reasoning_tokens: nullable_non_negative_integer(),
      finish_reason: nullable_string(40),
      dispatch_started_at: nullable_timestamp(),
      completed_at: nullable_timestamp()
    }

    object(properties, properties |> Map.keys() |> Enum.sort(), false)
  end

  defp case_condition do
    object(
      %{
        id: Schemas.uuid(),
        signal_correlation_id: Schemas.uuid(),
        target_id: nullable_uuid(),
        predicate: string(1, 500),
        subject_ref: map(),
        state: enum(~w(firing recovered)),
        recovery_status:
          enum(
            ~w(ready_for_review firing stale_source unmapped_target needs_observation target_changed unknown)
          ),
        recovery_evidence_ids: array(Schemas.uuid()),
        first_fired_at: Schemas.timestamp(),
        current_occurred_at: Schemas.timestamp(),
        revision: positive_integer(),
        membership_id: Schemas.uuid(),
        attached_at: Schemas.timestamp()
      },
      ~w(id signal_correlation_id target_id predicate subject_ref state recovery_status recovery_evidence_ids first_fired_at current_occurred_at revision membership_id attached_at)a,
      false
    )
  end

  defp case_condition_membership do
    object(
      %{
        id: Schemas.uuid(),
        condition_id: Schemas.uuid(),
        case_id: Schemas.uuid(),
        attached_at: Schemas.timestamp(),
        detached_at: nullable_timestamp(),
        reason: string(1, 500)
      },
      ~w(id condition_id case_id attached_at detached_at reason)a,
      false
    )
  end

  defp resolution_run do
    object(
      %{
        id: Schemas.uuid(),
        case_id: Schemas.uuid(),
        generation: positive_integer(),
        active: %Schema{type: :boolean},
        status: enum(~w(running needs_attention completed cancelled superseded)),
        authority_mode: authority_mode(),
        limits: ref("WorkflowLimits"),
        counters: ref("ResolutionCounters"),
        started_at: Schemas.timestamp(),
        deadline_at: Schemas.timestamp(),
        ended_at: nullable_timestamp(),
        resume_reason: nullable_string(500),
        resumed_by_id: nullable_uuid(),
        revision: positive_integer(),
        inserted_at: Schemas.timestamp(),
        updated_at: Schemas.timestamp()
      },
      ~w(id case_id generation active status authority_mode limits counters started_at deadline_at ended_at resume_reason resumed_by_id revision inserted_at updated_at)a,
      false
    )
  end

  defp event do
    object(
      %{
        id: Schemas.uuid(),
        case_id: Schemas.uuid(),
        resolution_run_id: nullable_uuid(),
        actor_id: nullable_uuid(),
        type: string(1, 80),
        related_case_id: nullable_uuid(),
        review_verdict: nullable_string(80),
        review_reason: nullable_string(1_000),
        review_source_turn_id: nullable_uuid(),
        review_provider_id: nullable_uuid(),
        review_evidence_ids: %Schema{type: :array, items: Schemas.uuid()},
        review_desired_outcome_assessment: Schemas.desired_outcome_assessment(true),
        inserted_at: Schemas.timestamp()
      },
      [
        :id,
        :case_id,
        :resolution_run_id,
        :actor_id,
        :type,
        :related_case_id,
        :review_verdict,
        :review_reason,
        :review_source_turn_id,
        :review_provider_id,
        :review_evidence_ids,
        :review_desired_outcome_assessment,
        :inserted_at
      ],
      false
    )
  end

  defp turn do
    object(
      %{
        id: Schemas.uuid(),
        case_id: Schemas.uuid(),
        resolution_run_id: Schemas.uuid(),
        ordinal: positive_integer(),
        status: enum(~w(started completed)),
        intent: map(),
        outcome: nullable_string(),
        decision: nullable_map(),
        condition_revisions:
          nullable_array(
            object(%{id: Schemas.uuid(), revision: positive_integer()}, [:id, :revision], false)
          ),
        condition_groups:
          nullable_array(
            object(
              %{
                condition_ids: array(Schemas.uuid()),
                assessment: enum(~w(related independent unknown)),
                reason: nullable_string(500),
                evidence_ids: array(Schemas.uuid())
              },
              [:condition_ids, :assessment, :reason, :evidence_ids],
              false
            )
          ),
        condition_assessments:
          nullable_array(
            object(
              %{
                condition_id: Schemas.uuid(),
                revision: positive_integer(),
                status: enum(~w(recovered still_failing unknown)),
                evidence_ids: array(Schemas.uuid()),
                reason: string(1, 500)
              },
              [:condition_id, :revision, :status, :evidence_ids, :reason],
              false
            )
          ),
        failure_category: nullable_string(),
        failure_message: nullable_string(),
        progress_kind:
          nullable_enum(
            ~w(evidence hypothesis proposal observation_pending delivery_retry source_change human_input none)
          ),
        started_at: Schemas.timestamp(),
        completed_at: nullable_timestamp(),
        revision: positive_integer(),
        inserted_at: Schemas.timestamp(),
        updated_at: Schemas.timestamp()
      },
      ~w(id case_id resolution_run_id ordinal status intent outcome decision condition_revisions condition_groups condition_assessments failure_category failure_message progress_kind started_at completed_at revision inserted_at updated_at)a,
      false
    )
  end

  defp turn_summary do
    base = summary(turn(), Skopos.Cases.Turn.summary_fields())

    presentation =
      object(
        %{
          outcome: nullable_string(120),
          type: nullable_string(120),
          reason: nullable_string(500),
          target_id: nullable_string(36),
          capability: nullable_string(120),
          operation: nullable_string(120),
          failure_category: nullable_string(120),
          failure_message: nullable_string(500),
          relationship: %Schema{
            type: :object,
            nullable: true,
            additionalProperties: false,
            properties: %{
              source_target_id: nullable_string(36),
              destination_target_id: nullable_string(36),
              kind: nullable_string(120)
            },
            required: [:source_target_id, :destination_target_id, :kind]
          }
        },
        ~w(outcome type reason target_id capability operation failure_category failure_message relationship)a,
        false
      )

    %{
      base
      | properties: Map.put(base.properties, :summary, presentation),
        required: base.required ++ [:summary]
    }
  end

  defp evidence do
    object(
      %{
        id: Schemas.uuid(),
        case_id: Schemas.uuid(),
        resolution_run_id: Schemas.uuid(),
        turn_id: nullable_uuid(),
        kind: string(1, 80),
        source: string(1, 120),
        source_ref: string(1, 500),
        content: map(),
        observed_at: Schemas.timestamp(),
        inserted_at: Schemas.timestamp(),
        updated_at: Schemas.timestamp()
      },
      ~w(id case_id resolution_run_id turn_id kind source source_ref content observed_at inserted_at updated_at)a,
      false
    )
  end

  defp summary(schema, fields) do
    %{
      schema
      | properties: Map.take(schema.properties, fields),
        required: Enum.filter(schema.required, &(&1 in fields))
    }
  end

  defp evidence_summary do
    evidence = evidence()

    summary =
      object(
        %{
          status: nullable_string(80),
          category: nullable_string(120),
          target_id: nullable_uuid(),
          condition_id: nullable_uuid(),
          title: nullable_string(200),
          target_label: nullable_string(500)
        },
        ~w(status category target_id condition_id title target_label)a,
        false
      )

    %{
      evidence
      | properties: evidence.properties |> Map.delete(:content) |> Map.put(:summary, summary),
        required: Enum.reject(evidence.required, &(&1 == :content)) ++ [:summary],
        description:
          "Evidence index metadata with bounded presentation labels. Retrieve /evidence/{id} for exact content; no facts or request/result payloads are included."
    }
  end

  defp approval do
    object(
      %{
        id: Schemas.uuid(),
        proposal_id: Schemas.uuid(),
        case_id: Schemas.uuid(),
        resolution_run_id: Schemas.uuid(),
        actor_id: Schemas.uuid(),
        decision: enum(~w(approved rejected)),
        source: enum(~w(human readonly auto_observation full_access reviewer)),
        proposal_revision: positive_integer(),
        case_generation: positive_integer(),
        reason: string(1, 1_000),
        decided_at: Schemas.timestamp(),
        inserted_at: Schemas.timestamp()
      },
      ~w(id proposal_id case_id resolution_run_id actor_id decision source proposal_revision case_generation reason decided_at inserted_at)a,
      false
    )
  end

  defp review_decision do
    object(
      %{
        id: Schemas.uuid(),
        proposal_id: Schemas.uuid(),
        case_id: Schemas.uuid(),
        resolution_run_id: Schemas.uuid(),
        provider_id: nullable_uuid(),
        outcome: enum(~w(decision delivery_failed)),
        verdict: enum(~w(approved rejected needs_human)),
        purpose_assessment: nullable_enum(~w(investigation remediation unknown)),
        category: nullable_string(80),
        reason: string(1, 1_000),
        selection_source: nullable_enum(~w(assignment)),
        provider_revision: nullable_positive_integer(),
        input_tokens: non_negative_integer(),
        output_tokens: non_negative_integer(),
        decided_at: Schemas.timestamp(),
        inserted_at: Schemas.timestamp()
      },
      ~w(id proposal_id case_id resolution_run_id provider_id outcome verdict purpose_assessment category reason selection_source provider_revision input_tokens output_tokens decided_at inserted_at)a,
      false
    )
  end

  defp proposal do
    object(
      %{
        id: Schemas.uuid(),
        case_id: Schemas.uuid(),
        resolution_run_id: Schemas.uuid(),
        source_turn_id: Schemas.uuid(),
        proposed_for_id: Schemas.uuid(),
        target_id: Schemas.uuid(),
        access_method_id: Schemas.uuid(),
        provider_id: Schemas.uuid(),
        status:
          enum(
            ~w(proposed blocked recommended awaiting_human reviewing authorized rejected invalidated)
          ),
        authority_mode: authority_mode(),
        case_generation: positive_integer(),
        target_revision: positive_integer(),
        access_method_revision: positive_integer(),
        provider_revision: positive_integer(),
        request_kind: enum(~w(observation effect)),
        purpose: nullable_enum(~w(investigation remediation)),
        tool_id: string(1, 200),
        capability: string(1, 120),
        operation: string(1, 120),
        selectors: map(),
        parameters: map(),
        reason: string(1, 500),
        evidence_ids: array(Schemas.uuid(), 0, 100),
        delay_seconds: integer(0, 86_400),
        affected_conditions:
          array(
            object(
              %{
                condition_id: Schemas.uuid(),
                revision: positive_integer(),
                relationship_id: Schemas.uuid(),
                relationship_revision: positive_integer()
              },
              ~w(condition_id revision)a,
              false
            ),
            0,
            100
          ),
        expected_result: map(),
        verification_intent: map(),
        verification_tool: map(),
        preflight_status: enum(~w(cleared blocked)),
        preflight_reason: nullable_string(500),
        proposal_digest: digest(),
        expires_at: Schemas.timestamp(),
        revision: positive_integer(),
        inserted_at: Schemas.timestamp(),
        updated_at: Schemas.timestamp()
      },
      ~w(id case_id resolution_run_id source_turn_id proposed_for_id target_id access_method_id provider_id status authority_mode case_generation target_revision access_method_revision provider_revision request_kind purpose tool_id capability operation selectors parameters reason delay_seconds evidence_ids affected_conditions expected_result verification_intent verification_tool preflight_status preflight_reason proposal_digest expires_at revision inserted_at updated_at)a,
      false
    )
  end

  defp decide_proposal_request do
    wrapped(
      :proposal,
      %{
        expected_revision: positive_integer(),
        proposal_digest: digest(),
        decision: enum(~w(approved rejected)),
        reason: string(1, 1_000)
      },
      [:expected_revision, :proposal_digest, :decision, :reason]
    )
  end

  defp operation do
    object(
      %{
        id: Schemas.uuid(),
        case_id: Schemas.uuid(),
        resolution_run_id: Schemas.uuid(),
        proposal_id: Schemas.uuid(),
        approval_id: Schemas.uuid(),
        actor_id: Schemas.uuid(),
        target_id: Schemas.uuid(),
        access_method_id: Schemas.uuid(),
        provider_id: Schemas.uuid(),
        status: enum(~w(queued dispatching applied failed partial unknown)),
        case_generation: positive_integer(),
        authority_mode: authority_mode(),
        request_kind: enum(~w(observation effect)),
        purpose: nullable_enum(~w(investigation remediation)),
        capability: string(1, 120),
        operation: string(1, 120),
        selectors: map(),
        parameters: map(),
        dispatch_started_at: nullable_timestamp(),
        outcome_category: nullable_string(120),
        reference: nullable_string(Skopos.Providers.Target.max_result_bytes()),
        result_details: map(),
        accepted_at: Schemas.timestamp(),
        not_before: Schemas.timestamp(),
        completed_at: nullable_timestamp(),
        revision: positive_integer(),
        inserted_at: Schemas.timestamp(),
        updated_at: Schemas.timestamp()
      },
      ~w(id case_id resolution_run_id proposal_id approval_id actor_id target_id access_method_id provider_id status case_generation authority_mode request_kind purpose capability operation selectors parameters dispatch_started_at outcome_category reference result_details accepted_at not_before completed_at revision inserted_at updated_at)a,
      false
    )
  end

  defp verification_attempt do
    object(
      %{
        id: Schemas.uuid(),
        case_id: Schemas.uuid(),
        resolution_run_id: Schemas.uuid(),
        operation_id: Schemas.uuid(),
        proposal_id: Schemas.uuid(),
        actor_id: Schemas.uuid(),
        target_id: Schemas.uuid(),
        access_method_id: Schemas.uuid(),
        provider_id: Schemas.uuid(),
        status: enum(~w(queued dispatching verified not_verified unknown)),
        case_generation: positive_integer(),
        authority_mode: enum(~w(ask auto full_access)),
        tool_id: string(1, 500),
        capability: string(1, 120),
        operation: string(1, 120),
        selectors: map(),
        parameters: map(),
        expected: map(),
        operation_reference: nullable_string(Skopos.Providers.Target.max_result_bytes()),
        dispatch_started_at: nullable_timestamp(),
        outcome_category: nullable_string(120),
        facts: map(),
        provider_evidence: map(),
        observed_at: nullable_timestamp(),
        accepted_at: Schemas.timestamp(),
        completed_at: nullable_timestamp(),
        revision: positive_integer(),
        inserted_at: Schemas.timestamp(),
        updated_at: Schemas.timestamp()
      },
      ~w(id case_id resolution_run_id operation_id proposal_id actor_id target_id access_method_id provider_id status case_generation authority_mode tool_id capability operation selectors parameters expected operation_reference dispatch_started_at outcome_category facts provider_evidence observed_at accepted_at completed_at revision inserted_at updated_at)a,
      false
    )
  end

  defp limits do
    object(
      %{
        max_elapsed_seconds: integer(60, 2_592_000),
        max_resolver_turns: integer(0, 1_000),
        max_target_requests: integer(0, 10_000),
        max_effects: integer(0, 1_000),
        max_related_targets: integer(0, 1_000),
        max_ai_usage_units: integer(0, 1_000_000_000),
        max_no_progress_turns: integer(1, 100)
      },
      ~w(max_elapsed_seconds max_resolver_turns max_target_requests max_effects max_related_targets max_ai_usage_units max_no_progress_turns)a,
      false
    )
  end

  defp counters do
    object(
      %{
        resolver_turns: non_negative_integer(),
        target_requests: non_negative_integer(),
        effects: non_negative_integer(),
        related_targets: non_negative_integer(),
        ai_usage_units: non_negative_integer(),
        no_progress_turns: non_negative_integer()
      },
      ~w(resolver_turns target_requests effects related_targets ai_usage_units no_progress_turns)a,
      false
    )
  end

  defp wrapped(name, properties, required) do
    object(%{name => object(properties, required)}, [name])
  end

  defp authority_mode, do: enum(~w(readonly ask auto full_access))
  defp digest, do: %Schema{type: :string, minLength: 64, maxLength: 64}
  defp enum(values), do: %Schema{type: :string, enum: values}
  defp nullable_enum(values), do: %Schema{type: :string, enum: values, nullable: true}

  defp string(min_length, max_length),
    do: %Schema{type: :string, minLength: min_length, maxLength: max_length}

  defp nullable_string(max_length \\ nil),
    do: %Schema{type: :string, maxLength: max_length, nullable: true}

  defp integer(minimum, maximum), do: %Schema{type: :integer, minimum: minimum, maximum: maximum}
  defp positive_integer, do: %Schema{type: :integer, minimum: 1}
  defp nullable_positive_integer, do: %Schema{type: :integer, minimum: 1, nullable: true}
  defp non_negative_integer, do: %Schema{type: :integer, minimum: 0}
  defp nullable_non_negative_integer, do: %Schema{type: :integer, minimum: 0, nullable: true}
  defp map, do: %Schema{type: :object, additionalProperties: true}
  defp nullable_map, do: %Schema{type: :object, additionalProperties: true, nullable: true}
  defp nullable_uuid, do: %Schema{type: :string, format: :uuid, nullable: true}
  defp nullable_timestamp, do: %Schema{type: :string, format: :"date-time", nullable: true}
  defp array(items), do: %Schema{type: :array, items: items}
  defp nullable_array(items), do: %Schema{type: :array, items: items, nullable: true}

  defp array(items, min_items, max_items),
    do: %Schema{type: :array, items: items, minItems: min_items, maxItems: max_items}

  defp object(properties, required, additional_properties \\ nil) do
    %Schema{
      type: :object,
      properties: properties,
      required: required,
      additionalProperties: additional_properties
    }
  end
end
