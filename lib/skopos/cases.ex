defmodule Skopos.Cases do
  use Ash.Domain,
    otp_app: :skopos

  resources do
    resource Skopos.Cases.AuthoritySetting do
      define :list_authority_settings, action: :read
      define :page_authority_settings, action: :page
      define :current_authority_setting, action: :current
      define :setup_readiness, action: :readiness
      define :bootstrap_authority_setting, action: :bootstrap
      define :create_authority_setting_revision, action: :create_revision
      define :retire_authority_setting, action: :retire, args: [:expected_revision]

      define :configure_authority_setting,
        action: :configure,
        args: [
          :expected_setting_revision,
          :authority_mode,
          :signal_automation_enabled,
          :max_elapsed_seconds,
          :max_resolver_turns,
          :max_target_requests,
          :max_effects,
          :max_related_targets,
          :max_ai_usage_units,
          :max_no_progress_turns,
          :reason
        ]
    end

    resource Skopos.Cases.Case do
      define :invocation_context_current,
        action: :invocation_context_current,
        args: [:invocation_context]

      define :list_cases, action: :read
      define :page_case_summaries, action: :summaries
      define :report_cases, action: :report_period, args: [:from, :to, :target_id]

      define :page_cases,
        action: :page,
        args: [:query, :status, :sort]

      define :get_case, action: :read, get_by: [:id]
      define :case_reconnect_snapshot, action: :reconnect, args: [:id]
      define :case_by_trigger, action: :by_trigger, args: [:trigger_kind, :source, :source_ref]

      define :running_signal_cases_without_target,
        action: :running_signals_without_target

      define :signal_cases_waiting_for_external_identity,
        action: :waiting_for_external_identity,
        args: [:source, :kind, :value]

      define :create_case_record, action: :create_record

      define :record_case_owner, action: :record_owner, args: [:expected_revision, :owner_id]

      define :record_case_selected_target,
        action: :record_selected_target,
        args: [:expected_revision, :target_id, :target_revision]

      define :record_case_pending_intent,
        action: :record_pending_intent,
        args: [:expected_revision, :pending_intent]

      define :record_case_cancellation,
        action: :record_cancellation,
        args: [:expected_revision]

      define :record_case_attention,
        action: :record_attention,
        args: [:expected_revision, :reason, :pending_intent, :required_human_input]

      define :record_case_resume,
        action: :record_resume,
        args: [:expected_revision]

      define :record_case_resolution,
        action: :record_resolution,
        args: [:expected_revision, :resolved_at]

      define :record_case_split_reallocation,
        action: :record_split_reallocation,
        args: [:expected_revision, :turn_count, :ai_usage_units]

      define :mark_case_budget_exhausted,
        action: :mark_budget_exhausted,
        args: [
          :expected_revision,
          :resolution_run_id,
          :expected_run_revision,
          :reason,
          :limit,
          :kind,
          :amount,
          :ledger_key,
          :pending_intent,
          :required_human_input,
          :event_data
        ]

      define :queue_case_resolver_turn,
        action: :queue_resolver_turn,
        args: [:expected_revision, :source_turn_id, :next_turn_id]

      define :handoff_case_operation,
        action: :handoff_operation,
        args: [
          :expected_revision,
          :operation_id,
          :kind,
          :next_turn_id,
          :source_turn_id,
          :evidence_id
        ]

      define :handoff_case_verification,
        action: :handoff_verification,
        args: [
          :expected_revision,
          :verification_attempt_id,
          :verification_evidence_id,
          :kind,
          :next_turn_id
        ]

      define :handoff_case_proposal,
        action: :handoff_proposal,
        args: [:expected_revision, :proposal_id, :kind, :reference_id]

      define :open_case,
        action: :open,
        args: [
          :trigger_kind,
          :source,
          :source_ref,
          :title,
          :severity,
          :initial_context,
          :initial_target_id,
          :report_language
        ]

      define :split_case_conditions,
        action: :split_conditions,
        args: [:id, :expected_revision, :condition_ids, :expected_conditions, :reason]

      define :split_case_from_resolver,
        action: :split_conditions,
        args: [
          :id,
          :expected_revision,
          :condition_ids,
          :expected_conditions,
          :reason,
          :source_turn_id
        ]

      define :claim_case, action: :claim, args: [:id, :expected_revision]
      define :handoff_case, action: :handoff, args: [:id, :expected_revision, :owner_id]

      define :request_case_cancellation,
        action: :request_cancellation,
        args: [:id, :expected_revision]

      define :active_signal_case_by_trigger,
        action: :active_by_trigger,
        args: [:source, :source_ref]

      define :reconcile_verified_effect,
        action: :reconcile_verified_effect,
        args: [:id, :verification_attempt_id]

      define :continue_case_after_verification,
        action: :continue_after_verification,
        args: [:id, :verification_attempt_id]

      define :recheck_signal_conditions,
        action: :recheck_signal_conditions,
        args: [:id]

      define :require_case_attention,
        action: :require_attention,
        args: [
          :id,
          :expected_revision,
          :resolution_run_id,
          :expected_run_revision,
          :idempotency_key,
          :reason,
          :pending_intent,
          :required_human_input
        ]

      define :resume_case,
        action: :resume,
        args: [
          :id,
          :expected_case_revision,
          :resolution_run_id,
          :expected_run_revision,
          :authority_mode,
          :max_elapsed_seconds,
          :max_resolver_turns,
          :max_target_requests,
          :max_effects,
          :max_related_targets,
          :max_ai_usage_units,
          :max_no_progress_turns,
          :reason
        ]

      define :resume_case_after_target_registration,
        action: :resume_after_target_registration,
        args: [:id, :external_identity_id, :expected_identity_revision]

      define :search_case_targets,
        action: :search_targets,
        args: [
          :id,
          :resolution_run_id,
          :idempotency_key,
          :query,
          :max_results,
          :pending_intent,
          :required_human_input
        ]

      define :select_case_target,
        action: :select_target,
        args: [
          :id,
          :expected_revision,
          :resolution_run_id,
          :evidence_ids,
          :target_id,
          :target_revision,
          :reason,
          :idempotency_key
        ]

      define :route_target_discovery,
        action: :route_target_discovery,
        args: [:turn_id]

      define :route_related_target,
        action: :route_related_target,
        args: [:turn_id]

      define :route_downstream_decision,
        action: :route_downstream_decision,
        args: [:turn_id]

      define :route_resolver_decision,
        action: :route_resolver_decision,
        args: [:turn_id]

      define :route_resolver_failure,
        action: :route_resolver_failure,
        args: [:turn_id, :category, :rejection_code, :rejection_path]
    end

    resource Skopos.Cases.ResolutionRun do
      define :list_resolution_runs, action: :read
      define :get_resolution_run, action: :read, get_by: [:id]
      define :resolution_runs_for_case, action: :for_case, args: [:case_id]
      define :active_resolution_run, action: :active_for_case, args: [:case_id]
      define :create_resolution_run_record, action: :create_record
      define :retire_resolution_run, action: :retire, args: [:expected_revision]
      define :pause_resolution_run, action: :pause, args: [:expected_revision]

      define :update_resolution_run_counters,
        action: :update_counters,
        args: [:expected_revision]

      define :record_resolution_run_ai_usage,
        action: :record_ai_usage,
        args: [:expected_revision, :amount]

      define :reallocate_resolution_run_limits,
        action: :reallocate_limits,
        args: [:expected_revision]

      define :charge_resolution_run,
        action: :charge,
        args: [
          :case_id,
          :resolution_run_id,
          :kind,
          :amount,
          :idempotency_key,
          :pending_intent,
          :required_human_input
        ]
    end

    resource Skopos.Cases.CaseEvent do
      define :list_case_events, action: :timeline

      define :page_case_events,
        action: :page_for_case,
        args: [:case_id]

      define :case_event_by_idempotency,
        action: :by_idempotency,
        args: [:case_id, :idempotency_key]

      define :recovery_review_history,
        action: :recovery_review_history,
        args: [:case_id]

      define :observation_progress_history,
        action: :observation_progress_history,
        args: [:case_id, :resolution_run_id]

      define :create_case_event_record, action: :create_record

      define :record_report_generation_failure,
        action: :record_report_generation_failure,
        args: [:case_id, :case_revision]
    end

    resource Skopos.Cases.Turn do
      define :list_turns, action: :read
      define :page_case_turns, action: :page_for_case, args: [:case_id]

      define :latest_turn_condition_context,
        action: :latest_condition_context,
        args: [:case_id, :condition_revisions, :field]

      define :get_turn, action: :read, get_by: [:id]

      define :turn_by_idempotency,
        action: :by_idempotency,
        args: [:resolution_run_id, :idempotency_key]

      define :started_turns_for_run,
        action: :started_for_run,
        args: [:resolution_run_id]

      define :create_turn_record, action: :create_record
      define :complete_turn_record, action: :complete_record, args: [:expected_revision]

      define :start_turn,
        action: :start,
        args: [
          :case_id,
          :resolution_run_id,
          :idempotency_key,
          :intent,
          :pending_intent,
          :required_human_input
        ]

      define :complete_turn,
        action: :complete,
        args: [
          :id,
          :expected_revision,
          :result,
          :progress_kind,
          :pending_intent,
          :required_human_input
        ]
    end

    resource Skopos.Cases.Evidence do
      define :list_evidence, action: :read
      define :page_case_evidence, action: :page_for_case, args: [:case_id]
      define :get_evidence, action: :read, get_by: [:id]

      define :resolver_evidence_window,
        action: :projection_window,
        args: [:case_id, :resolution_run_id]

      define :signal_context_evidence,
        action: :signal_contexts,
        args: [:case_id]

      define :target_continuity_evidence,
        action: :target_continuity,
        args: [:case_id]

      define :review_context_evidence,
        action: :review_context,
        args: [:case_id]

      define :review_target_context_evidence,
        action: :review_target_context,
        args: [:case_id, :target_id]

      define :condition_assessment_evidence,
        action: :condition_assessment_candidates,
        args: [:case_id, :after]

      define :evidence_by_idempotency,
        action: :by_idempotency,
        args: [:case_id, :idempotency_key]

      define :create_evidence_record, action: :create_record

      define :capture_file_read, action: :capture_file_read, args: [:turn_id]
      define :read_file_content, action: :read_file_content, args: [:id, :case_id]
      define :file_read_source, action: :file_read_source, args: [:id, :case_id]

      define :append_evidence,
        action: :append,
        args: [
          :case_id,
          :resolution_run_id,
          :turn_id,
          :idempotency_key,
          :kind,
          :source,
          :source_ref,
          :content,
          :observed_at
        ]
    end

    resource Skopos.Cases.Proposal do
      define :list_proposals, action: :read
      define :get_proposal, action: :read, get_by: [:id]
      define :proposal_summaries_for_case, action: :summaries_for_case, args: [:case_id]
      define :page_case_proposals, action: :page_for_case, args: [:case_id]

      define :proposal_by_source_turn,
        action: :by_source_turn,
        args: [:source_turn_id]

      define :create_proposal_record, action: :create_record
      define :transition_proposal, action: :transition, args: [:expected_revision]
      define :materialize_proposal, action: :materialize, args: [:turn_id]
      define :route_proposal_authority, action: :route_authority, args: [:proposal_id]
      define :expire_proposal, action: :expire, args: [:proposal_id]

      define :apply_proposal_review,
        action: :apply_review,
        args: [:proposal_id, :review_decision_id]

      define :supersede_proposal_context,
        action: :supersede_context,
        args: [:proposal_id]

      define :fail_proposal_review_delivery,
        action: :fail_review_delivery,
        args: [:proposal_id, :category, :reason]

      define :decide_proposal,
        action: :decide,
        args: [:proposal_id, :expected_revision, :proposal_digest, :decision, :reason]
    end

    resource Skopos.Cases.Approval do
      define :list_approvals, action: :read
      define :page_case_approvals, action: :page_for_case, args: [:case_id]
      define :approval_by_proposal, action: :by_proposal, args: [:proposal_id]
      define :create_approval_record, action: :create_record
    end

    resource Skopos.Cases.ReviewDecision do
      define :list_review_decisions, action: :read
      define :page_case_review_decisions, action: :page_for_case, args: [:case_id]
      define :review_decision_by_proposal, action: :by_proposal, args: [:proposal_id]
      define :create_review_decision_record, action: :create_record
    end

    resource Skopos.Cases.Operation do
      define :list_operations, action: :read
      define :get_operation, action: :read, get_by: [:id]
      define :operations_for_case, action: :for_case, args: [:case_id]
      define :operation_summaries_for_case, action: :summaries_for_case, args: [:case_id]
      define :page_case_operations, action: :page_for_case, args: [:case_id]

      define :latest_recovery_effect,
        action: :latest_recovery_effect,
        args: [:case_id, :condition_ids, :exclude_operation_id]

      define :latest_applied_recovery_effect,
        action: :latest_applied_recovery_effect,
        args: [:case_id, :resolution_run_id, :condition_ids]

      define :recent_method_observations,
        action: :recent_method_observations,
        args: [
          :case_id,
          :resolution_run_id,
          :target_id,
          :access_method_id,
          :access_method_revision
        ]

      define :operation_by_proposal, action: :by_proposal, args: [:proposal_id]
      define :create_operation_record, action: :create_record
      define :mark_operation_dispatching, action: :mark_dispatching, args: [:expected_revision]

      define :retry_unsent_operation,
        action: :retry_unsent,
        args: [:expected_revision, :before_send_failure]

      define :record_operation_outcome, action: :record_outcome, args: [:expected_revision]
      define :record_operation_no_send, action: :record_no_send, args: [:expected_revision]
      define :accept_operation, action: :accept, args: [:proposal_id]
      define :claim_operation_dispatch, action: :claim_dispatch, args: [:id]
      define :account_observation_progress, action: :account_observation_progress, args: [:id]

      define :read_operation_result_reference,
        action: :read_result_reference,
        args: [:reference_id, :case_id, :clearance]
    end

    resource Skopos.Cases.VerificationAttempt do
      define :list_verification_attempts, action: :read
      define :get_verification_attempt, action: :read, get_by: [:id]
      define :verification_attempts_for_case, action: :for_case, args: [:case_id]
      define :verification_summaries_for_case, action: :summaries_for_case, args: [:case_id]
      define :page_case_verifications, action: :page_for_case, args: [:case_id]

      define :verification_attempt_by_operation,
        action: :by_operation,
        args: [:operation_id]

      define :create_verification_attempt_record, action: :create_record

      define :mark_verification_dispatching,
        action: :mark_dispatching,
        args: [:expected_revision]

      define :record_verification_outcome, action: :record_outcome, args: [:expected_revision]

      define :retry_unsent_verification,
        action: :retry_unsent,
        args: [:expected_revision, :before_send_failure]

      define :record_verification_no_send, action: :record_no_send, args: [:expected_revision]
      define :accept_verification, action: :accept, args: [:operation_id]
      define :claim_verification_dispatch, action: :claim_dispatch, args: [:id]
      define :evaluate_verification, action: :evaluate, args: [:id]
    end

    resource Skopos.Cases.AIInvocation do
      define :list_ai_invocations, action: :read
      define :page_case_ai_invocations, action: :page_for_case, args: [:case_id]

      define :ai_invocation_by_idempotency,
        action: :by_idempotency,
        args: [:idempotency_key]

      define :create_ai_invocation_record, action: :create_record

      define :settle_stopped_ai_invocations,
        action: :settle_stopped,
        args: [:case_id, :resolution_run_id, :role, :turn_id, :proposal_id]

      define :retry_unsent_ai_invocation,
        action: :retry_unsent,
        args: [:expected_revision, :before_send_failure]

      define :begin_ai_invocation_dispatch,
        action: :begin_dispatch,
        args: [:expected_revision, :request_digest, :reserved_units]

      define :record_ai_invocation_outcome,
        action: :record_outcome,
        args: [:expected_revision]

      define :claim_ai_invocation,
        action: :claim,
        args: [
          :role,
          :case_id,
          :expected_case_revision,
          :resolution_run_id,
          :turn_id,
          :expected_turn_revision,
          :proposal_id,
          :expected_proposal_revision,
          :provider_id,
          :assignment_id,
          :provider_revision,
          :assignment_revision,
          :selection_source,
          :request_digest,
          :delivery_attempt
        ]
    end

    resource Skopos.Cases.CaseConditionMembership do
      define :active_case_condition, action: :active_for_condition, args: [:condition_id]
      define :active_conditions_for_case, action: :active_for_case, args: [:case_id]
      define :page_case_condition_history, action: :page_history_for_case, args: [:case_id]
      define :condition_membership_history, action: :history_for_condition, args: [:condition_id]
      define :attach_case_condition_record, action: :attach_record
      define :detach_case_condition_record, action: :detach_record, args: [:expected_revision]

      define :assign_signal_condition,
        action: :assign_signal,
        args: [:condition_id, :source, :title, :severity, :received_at, :initial_context]
    end

    resource Skopos.Cases.CaseDispatch do
      define :case_dispatch, action: :for_case, args: [:case_id]
      define :admitting_case_dispatches, action: :admitting
      define :create_case_dispatch_record, action: :create_record
      define :record_case_dispatch_state, action: :record_state, args: [:expected_revision]
      define :send_initial_case_turn, action: :send_initial, args: [:case_id]
    end
  end
end
