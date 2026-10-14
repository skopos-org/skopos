defmodule SkoposWeb.API.V1.WorkflowJSON do
  @moduledoc false

  alias Skopos.Cases.Case.Symptom, as: CaseSymptom

  def authority(setting) do
    %{
      id: setting.id,
      authority_mode: setting.authority_mode,
      signal_automation_enabled: setting.signal_automation_enabled,
      max_elapsed_seconds: setting.max_elapsed_seconds,
      max_resolver_turns: setting.max_resolver_turns,
      max_target_requests: setting.max_target_requests,
      max_effects: setting.max_effects,
      max_related_targets: setting.max_related_targets,
      max_ai_usage_units: setting.max_ai_usage_units,
      max_no_progress_turns: setting.max_no_progress_turns,
      setting_revision: setting.setting_revision,
      active: setting.active,
      reason: setting.reason,
      changed_by_id: setting.changed_by_id,
      inserted_at: setting.inserted_at,
      updated_at: setting.updated_at
    }
  end

  def case_summary(incident), do: Map.take(incident, Skopos.Cases.Case.summary_fields())

  def case_record(incident) do
    action = operator_action(incident)

    %{
      id: incident.id,
      trigger_kind: incident.trigger_kind,
      source: incident.source,
      source_ref: incident.source_ref,
      split_parent_id: incident.split_parent_id,
      title: incident.title,
      severity: incident.severity,
      condition_count: loaded_count(incident.condition_count),
      firing_condition_count: loaded_count(incident.firing_condition_count),
      report_language: incident.report_language,
      status: incident.status,
      operator_action: action,
      pending_proposal_id:
        if(action == :decision_required, do: incident.pending_intent["proposal_id"], else: nil),
      initial_context: incident.initial_context,
      case_symptom: CaseSymptom.current(incident),
      authority_setting_id: incident.authority_setting_id,
      authority_setting_revision: incident.authority_setting_revision,
      authority_mode: incident.authority_mode,
      limits: limits(incident),
      cancel_requested: incident.cancel_requested,
      stop_reason: incident.stop_reason,
      required_human_input: incident.required_human_input,
      resolved_at: incident.resolved_at,
      initial_target_id: incident.initial_target_id,
      selected_target_id: incident.selected_target_id,
      selected_target_revision: incident.selected_target_revision,
      current_owner_id: incident.current_owner_id,
      revision: incident.revision,
      inserted_at: incident.inserted_at,
      updated_at: incident.updated_at
    }
  end

  defp loaded_count(value) when is_integer(value), do: value
  defp loaded_count(_value), do: nil

  defp operator_action(%{pending_intent: %{"action" => "decide_proposal"}}),
    do: :decision_required

  defp operator_action(%{pending_intent: %{"action" => "provide_human_input"}}),
    do: :input_required

  defp operator_action(%{status: :needs_attention}), do: :intervention_required
  defp operator_action(_incident), do: :none

  def snapshot(snapshot) do
    %{
      case: case_record(snapshot.case),
      ai_usage: snapshot.ai_usage,
      conditions: Enum.map(snapshot.conditions, &condition/1),
      condition_context:
        Map.new(snapshot.condition_context, fn {key, turn} ->
          {key, turn_condition_context(turn)}
        end),
      resolution_runs: Enum.map(snapshot.resolution_runs, &resolution_run/1),
      proposals:
        Enum.map(snapshot.proposals, &Map.take(&1, Skopos.Cases.Proposal.summary_fields())),
      operations:
        Enum.map(snapshot.operations, &Map.take(&1, Skopos.Cases.Operation.summary_fields())),
      verification_attempts:
        Enum.map(
          snapshot.verification_attempts,
          &Map.take(&1, Skopos.Cases.VerificationAttempt.summary_fields())
        ),
      reports: Enum.map(snapshot.reports, &Map.take(&1, Skopos.Reports.Report.summary_fields()))
    }
  end

  def condition(%{condition: condition, membership: membership, assessment: assessment}) do
    %{
      id: condition.id,
      signal_correlation_id: condition.signal_correlation_id,
      target_id: condition.target_id,
      predicate: condition.predicate,
      subject_ref: condition.subject_ref,
      state: condition.state,
      recovery_status: if(assessment, do: assessment.status, else: :unknown),
      recovery_evidence_ids: if(assessment, do: assessment.evidence_ids, else: []),
      first_fired_at: condition.first_fired_at,
      current_occurred_at: condition.current_occurred_at,
      revision: condition.revision,
      membership_id: membership.id,
      attached_at: membership.attached_at
    }
  end

  def condition_membership(membership) do
    %{
      id: membership.id,
      condition_id: membership.condition_id,
      case_id: membership.case_id,
      attached_at: membership.attached_at,
      detached_at: membership.detached_at,
      reason: membership.reason
    }
  end

  def resolution_run(run) do
    %{
      id: run.id,
      case_id: run.case_id,
      generation: run.generation,
      active: run.active,
      status: run.status,
      authority_mode: run.authority_mode,
      limits: limits(run),
      counters: %{
        resolver_turns: run.turn_count,
        target_requests: run.target_request_count,
        effects: run.effect_count,
        related_targets: run.related_target_count,
        ai_usage_units: run.ai_usage_units,
        no_progress_turns: run.no_progress_turns
      },
      started_at: run.started_at,
      deadline_at: run.deadline_at,
      ended_at: run.ended_at,
      resume_reason: run.resume_reason,
      resumed_by_id: run.resumed_by_id,
      revision: run.revision,
      inserted_at: run.inserted_at,
      updated_at: run.updated_at
    }
  end

  def event(event) do
    %{
      id: event.id,
      case_id: event.case_id,
      resolution_run_id: event.resolution_run_id,
      actor_id: event.actor_id,
      type: event.event_type,
      related_case_id: related_case_id(event),
      review_verdict: review_value(event, "verdict"),
      review_reason: review_value(event, "reason"),
      review_source_turn_id: review_value(event, "source_turn_id"),
      review_provider_id: review_value(event, "provider_id"),
      review_evidence_ids: review_evidence_ids(event),
      review_desired_outcome_assessment: review_value(event, "desired_outcome_assessment"),
      inserted_at: event.inserted_at
    }
  end

  defp related_case_id(%{event_type: "case_conditions_split_out", data: data}),
    do: data["child_case_id"]

  defp related_case_id(%{event_type: "case_conditions_split_in", data: data}),
    do: data["parent_case_id"]

  defp related_case_id(_event), do: nil

  defp review_value(%{event_type: "recovery_review_decided", data: data}, key),
    do: data[key]

  defp review_value(_event, _key), do: nil

  defp review_evidence_ids(%{event_type: "recovery_review_decided", data: data}),
    do: data["evidence_ids"] || []

  defp review_evidence_ids(_event), do: []

  def ai_invocation(invocation) do
    reported? = invocation.usage_status == :reported

    %{
      id: invocation.id,
      case_id: invocation.case_id,
      resolution_run_id: invocation.resolution_run_id,
      provider_id: invocation.provider_id,
      turn_id: invocation.turn_id,
      proposal_id: invocation.proposal_id,
      role: invocation.role,
      status: invocation.status,
      usage_status: invocation.usage_status,
      dispatch_confirmed: invocation.dispatch_confirmed,
      reserved_units: invocation.reserved_units,
      input_tokens: if(reported?, do: invocation.input_tokens),
      output_tokens: if(reported?, do: invocation.output_tokens),
      cached_tokens: if(reported?, do: invocation.cached_tokens),
      reasoning_tokens: if(reported?, do: invocation.reasoning_tokens),
      finish_reason: if(reported?, do: invocation.finish_reason),
      dispatch_started_at: invocation.dispatch_started_at,
      completed_at: invocation.completed_at
    }
  end

  def turn(turn) do
    %{
      id: turn.id,
      case_id: turn.case_id,
      resolution_run_id: turn.resolution_run_id,
      ordinal: turn.ordinal,
      status: turn.status,
      intent: turn.intent,
      outcome: turn.result["outcome"],
      decision: turn.result["intent"],
      condition_revisions: turn.result["condition_revisions"],
      condition_groups: turn.result["condition_groups"],
      condition_assessments: turn.result["condition_assessments"],
      failure_category: turn.result["category"],
      failure_message: turn.result["message"],
      progress_kind: turn.progress_kind,
      started_at: turn.started_at,
      completed_at: turn.completed_at,
      revision: turn.revision,
      inserted_at: turn.inserted_at,
      updated_at: turn.updated_at
    }
  end

  def turn_summary(turn),
    do: Map.take(turn, Skopos.Cases.Turn.summary_fields()) |> Map.put(:summary, turn.summary)

  defp turn_condition_context(nil), do: nil

  defp turn_condition_context(turn),
    do:
      Map.take(turn, [:id, :ordinal, :revision, :completed_at])
      |> Map.merge(turn.condition_context)

  def evidence(evidence) do
    evidence_record(evidence) |> Map.put(:content, evidence.content)
  end

  def evidence_summary(evidence) do
    evidence_record(evidence) |> Map.put(:summary, evidence.summary)
  end

  defp evidence_record(evidence) do
    %{
      id: evidence.id,
      case_id: evidence.case_id,
      resolution_run_id: evidence.resolution_run_id,
      turn_id: evidence.turn_id,
      kind: evidence.kind,
      source: evidence.source,
      source_ref: evidence.source_ref,
      observed_at: evidence.observed_at,
      inserted_at: evidence.inserted_at,
      updated_at: evidence.updated_at
    }
  end

  def approval(approval) do
    %{
      id: approval.id,
      proposal_id: approval.proposal_id,
      case_id: approval.case_id,
      resolution_run_id: approval.resolution_run_id,
      actor_id: approval.actor_id,
      decision: approval.decision,
      source: approval.source,
      proposal_revision: approval.proposal_revision,
      case_generation: approval.case_generation,
      reason: approval.reason,
      decided_at: approval.decided_at,
      inserted_at: approval.inserted_at
    }
  end

  def review_decision(decision) do
    %{
      id: decision.id,
      proposal_id: decision.proposal_id,
      case_id: decision.case_id,
      resolution_run_id: decision.resolution_run_id,
      provider_id: decision.provider_id,
      outcome: decision.outcome,
      verdict: decision.verdict,
      purpose_assessment: decision.purpose_assessment,
      category: decision.category,
      reason: decision.reason,
      selection_source: decision.selection_source,
      provider_revision: decision.provider_revision,
      input_tokens: decision.input_tokens,
      output_tokens: decision.output_tokens,
      decided_at: decision.decided_at,
      inserted_at: decision.inserted_at
    }
  end

  def proposal(proposal) do
    %{
      id: proposal.id,
      case_id: proposal.case_id,
      resolution_run_id: proposal.resolution_run_id,
      source_turn_id: proposal.source_turn_id,
      proposed_for_id: proposal.proposed_for_id,
      target_id: proposal.target_id,
      access_method_id: proposal.access_method_id,
      provider_id: proposal.provider_id,
      status: proposal.status,
      authority_mode: proposal.authority_mode,
      case_generation: proposal.case_generation,
      target_revision: proposal.target_revision,
      access_method_revision: proposal.access_method_revision,
      provider_revision: proposal.provider_revision,
      request_kind: proposal.request_kind,
      purpose: proposal.purpose,
      tool_id: proposal.tool_id,
      capability: proposal.capability,
      operation: proposal.operation,
      selectors: proposal.selectors,
      parameters: proposal.parameters,
      reason: proposal.reason,
      delay_seconds: proposal.delay_seconds,
      evidence_ids: proposal.evidence_ids,
      affected_conditions: proposal.affected_conditions,
      expected_result: proposal.expected_result,
      verification_intent: proposal.verification_intent,
      verification_tool: proposal.verification_tool,
      preflight_status: proposal.preflight_status,
      preflight_reason: proposal.preflight_reason,
      proposal_digest: proposal.proposal_digest,
      expires_at: proposal.expires_at,
      revision: proposal.revision,
      inserted_at: proposal.inserted_at,
      updated_at: proposal.updated_at
    }
  end

  def operation(operation) do
    %{
      id: operation.id,
      case_id: operation.case_id,
      resolution_run_id: operation.resolution_run_id,
      proposal_id: operation.proposal_id,
      approval_id: operation.approval_id,
      actor_id: operation.actor_id,
      target_id: operation.target_id,
      access_method_id: operation.access_method_id,
      provider_id: operation.provider_id,
      status: operation.status,
      case_generation: operation.case_generation,
      authority_mode: operation.authority_mode,
      request_kind: operation.request_kind,
      purpose: operation.purpose,
      capability: operation.capability,
      operation: operation.operation,
      selectors: operation.selectors,
      parameters: operation.parameters,
      dispatch_started_at: operation.dispatch_started_at,
      outcome_category: operation.outcome_category,
      reference: operation.reference,
      result_details: operation.result_details,
      accepted_at: operation.accepted_at,
      not_before: operation.not_before,
      completed_at: operation.completed_at,
      revision: operation.revision,
      inserted_at: operation.inserted_at,
      updated_at: operation.updated_at
    }
  end

  def verification_attempt(attempt) do
    %{
      id: attempt.id,
      case_id: attempt.case_id,
      resolution_run_id: attempt.resolution_run_id,
      operation_id: attempt.operation_id,
      proposal_id: attempt.proposal_id,
      actor_id: attempt.actor_id,
      target_id: attempt.target_id,
      access_method_id: attempt.access_method_id,
      provider_id: attempt.provider_id,
      status: attempt.status,
      case_generation: attempt.case_generation,
      authority_mode: attempt.authority_mode,
      tool_id: attempt.tool_id,
      capability: attempt.capability,
      operation: attempt.operation,
      selectors: attempt.selectors,
      parameters: attempt.parameters,
      expected: attempt.expected,
      operation_reference: attempt.operation_reference,
      dispatch_started_at: attempt.dispatch_started_at,
      outcome_category: attempt.outcome_category,
      facts: attempt.facts,
      provider_evidence: attempt.provider_evidence,
      observed_at: attempt.observed_at,
      accepted_at: attempt.accepted_at,
      completed_at: attempt.completed_at,
      revision: attempt.revision,
      inserted_at: attempt.inserted_at,
      updated_at: attempt.updated_at
    }
  end

  defp limits(value) do
    %{
      max_elapsed_seconds: value.max_elapsed_seconds,
      max_resolver_turns: value.max_resolver_turns,
      max_target_requests: value.max_target_requests,
      max_effects: value.max_effects,
      max_related_targets: value.max_related_targets,
      max_ai_usage_units: value.max_ai_usage_units,
      max_no_progress_turns: value.max_no_progress_turns
    }
  end
end
