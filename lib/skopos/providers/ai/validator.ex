defmodule Skopos.Providers.AI.Validator do
  @moduledoc false

  alias Skopos.Cases.Case.Symptom, as: CaseSymptom
  alias Skopos.Providers.{AI, Target}
  alias Skopos.Targets.SearchQuery

  @max_output_bytes AI.max_output_bytes()
  @max_review_items 100
  @max_review_bytes AI.max_input_bytes()

  def validate_request(:resolve, %AI.ResolverRequest{} = request) do
    cond do
      not valid_resolver_request?(request) ->
        {:error, ai_error(:invalid_input, "AI Resolver request is invalid")}

      exhausted?(request.budget) ->
        {:error, ai_error(:budget_exhausted, "AI budget is exhausted")}

      not disclosed?(request) ->
        {:error, ai_error(:disclosure_limit, "AI disclosure limit was exceeded")}

      true ->
        :ok
    end
  end

  def validate_request(:review, %AI.ReviewRequest{} = request) do
    cond do
      not valid_review_request?(request) ->
        {:error, ai_error(:invalid_input, "AI Reviewer request is invalid")}

      review_exhausted?(request.budget) ->
        {:error, ai_error(:budget_exhausted, "AI budget is exhausted")}

      AI.input_size(request) > @max_review_bytes ->
        {:error, ai_error(:disclosure_limit, "AI Reviewer disclosure limit was exceeded")}

      true ->
        :ok
    end
  end

  def validate_request(:review_recovery, %AI.RecoveryReviewRequest{} = request) do
    cond do
      not valid_recovery_review_request?(request) ->
        {:error, ai_error(:invalid_input, "Recovery Reviewer request is invalid")}

      review_exhausted?(request.budget) ->
        {:error, ai_error(:budget_exhausted, "AI budget is exhausted")}

      AI.input_size(request) > @max_review_bytes ->
        {:error, ai_error(:disclosure_limit, "Recovery Reviewer disclosure limit was exceeded")}

      true ->
        :ok
    end
  end

  def validate_request(_operation, _request),
    do: {:error, ai_error(:invalid_input, "AI request is invalid")}

  defp valid_resolver_request?(request) do
    positive?(request.provider_revision) and nonempty?(request.session_id) and
      nonempty?(request.case_id) and positive?(request.turn) and nonempty?(request.objective) and
      request.alert_state in [:firing, :recovered, :not_applicable] and
      request.report_language in [:en, :ja] and
      valid_instructions?(request.operating_instructions) and
      valid_retry_context?(request.retry_context) and
      valid_budget?(request.budget) and
      valid_disclosure?(request.disclosure) and valid_selected_target?(request) and
      CaseSymptom.valid?(request.case_symptom) and
      ((request.alert_state == :not_applicable and not is_nil(request.case_symptom) and
          request.conditions == []) or
         (request.alert_state != :not_applicable and is_nil(request.case_symptom))) and
      valid_resolver_items?(request)
  end

  defp valid_review_request?(
         %AI.ReviewRequest{
           source_evidence: source_evidence,
           cited_evidence: cited_evidence,
           context_evidence: context_evidence
         } = request
       )
       when is_list(source_evidence) and is_list(cited_evidence) and is_list(context_evidence) do
    if is_list(request.conditions) and is_list(request.target_relations) and
         length(source_evidence) + length(cited_evidence) + length(context_evidence) +
           length(request.target_relations) + length(request.conditions) <=
           @max_review_items and
         Enum.all?(source_evidence ++ cited_evidence ++ context_evidence, &valid_evidence?/1) and
         valid_review_relations?(request) do
      source_ids = Enum.map(source_evidence, & &1.id)
      evidence_ids = Enum.map(cited_evidence, & &1.id)
      context_ids = Enum.map(context_evidence, & &1.id)

      positive?(request.provider_revision) and nonempty?(request.session_id) and
        nonempty?(request.resolver_session_id) and
        request.session_id != request.resolver_session_id and nonempty?(request.case_id) and
        nonempty?(request.resolution_run_id) and is_list(request.recovery_evidence_ids) and
        unique?(request.recovery_evidence_ids) and
        Enum.all?(request.recovery_evidence_ids, &(&1 in (evidence_ids ++ context_ids))) and
        nonempty?(request.objective) and request.report_language in [:en, :ja] and
        valid_instructions?(request.operating_instructions) and
        valid_retry_context?(request.retry_context) and
        valid_budget?(request.budget) and unique?(source_ids) and unique?(evidence_ids) and
        unique?(context_ids) and
        MapSet.disjoint?(MapSet.new(evidence_ids), MapSet.new(context_ids)) and
        valid_review_proposal?(request.proposal, evidence_ids) and
        Enum.all?(request.conditions, &valid_condition?/1) and
        AI.valid_affected_conditions?(request.proposal, request.conditions)
    else
      false
    end
  end

  defp valid_review_request?(_request), do: false

  defp valid_recovery_review_request?(
         %AI.RecoveryReviewRequest{
           conditions: conditions,
           source_evidence: source_evidence,
           cited_evidence: cited_evidence,
           context_evidence: context_evidence,
           conclusion: %AI.RecoveryConclusion{} = conclusion
         } = request
       )
       when is_list(conditions) and is_list(source_evidence) and is_list(cited_evidence) and
              is_list(context_evidence) do
    claims = conclusion.condition_claims
    source_ids = Enum.map(source_evidence, &if(is_map(&1), do: Map.get(&1, :id)))
    cited_ids = Enum.map(cited_evidence, &if(is_map(&1), do: Map.get(&1, :id)))
    context_ids = Enum.map(context_evidence, &if(is_map(&1), do: Map.get(&1, :id)))
    by_id = Map.new(Enum.filter(conditions, &match?(%AI.Condition{}, &1)), &{&1.id, &1})

    positive?(request.provider_revision) and nonempty?(request.session_id) and
      nonempty?(request.resolver_session_id) and
      request.session_id != request.resolver_session_id and nonempty?(request.case_id) and
      nonempty?(request.objective) and request.report_language in [:en, :ja] and
      valid_budget?(request.budget) and valid_retry_context?(request.retry_context) and
      length(conditions) <= 32 and
      length(source_evidence) + length(cited_evidence) + length(context_evidence) +
        length(conditions) <=
        @max_review_items and
      Enum.all?(conditions, &valid_condition?/1) and
      Enum.all?(conditions, &(&1.state == :recovered and &1.recovery_status == :ready_for_review)) and
      Enum.all?(source_evidence ++ cited_evidence ++ context_evidence, &valid_evidence?/1) and
      unique?(source_ids) and unique?(cited_ids) and unique?(context_ids) and
      MapSet.disjoint?(MapSet.new(cited_ids), MapSet.new(context_ids)) and
      CaseSymptom.valid?(request.case_symptom) and
      ((conditions == [] and not is_nil(request.case_symptom)) or
         (conditions != [] and is_nil(request.case_symptom))) and
      AI.valid_resolver_reason?(conclusion.reason) and
      is_list(conclusion.evidence_ids) and unique?(conclusion.evidence_ids) and
      Enum.all?(conclusion.evidence_ids, &(&1 in cited_ids)) and
      visible_file_citations?(conclusion.evidence_ids, cited_evidence) and
      CaseSymptom.valid_claims?(
        conclusion.desired_outcome_claims,
        request.case_symptom,
        conclusion.evidence_ids,
        cited_evidence
      ) and
      is_list(claims) and length(claims) == length(conditions) and
      Enum.all?(claims, fn claim ->
        condition = is_map(claim) && Map.get(by_id, claim["condition_id"])

        (condition && claim["revision"] == condition.revision) and
          claim["evidence_id"] in condition.recovery_evidence_ids and
          claim["evidence_id"] in cited_ids and
          AI.valid_resolver_reason?(claim["reason"])
      end)
  end

  defp valid_recovery_review_request?(_request), do: false

  defp valid_review_relations?(%AI.ReviewRequest{
         initial_target_id: initial_id,
         target_relations: relations,
         proposal: %AI.Proposal{target_id: proposal_id} = proposal,
         conditions: conditions
       })
       when is_list(relations) do
    relevant_ids =
      [initial_id | Enum.map(conditions, & &1.target_id)]
      |> Enum.reject(&is_nil/1)
      |> MapSet.new()

    (is_nil(initial_id) or nonempty?(initial_id)) and
      Enum.all?(relations, &valid_relation?/1) and
      unique?(Enum.map(relations, & &1.id)) and
      Enum.all?(relations, fn relation ->
        proposal_id in [relation.source_target.id, relation.destination_target.id] and
          Enum.any?(
            [relation.source_target.id, relation.destination_target.id],
            &MapSet.member?(relevant_ids, &1)
          )
      end) and valid_effect_link_claims?(proposal, conditions, relations)
  end

  defp valid_review_relations?(_request), do: false

  defp valid_effect_link_claims?(%AI.Proposal{purpose: :investigation}, _conditions, _relations),
    do: true

  defp valid_effect_link_claims?(
         %AI.Proposal{request_kind: :observation},
         _conditions,
         _relations
       ),
       do: true

  defp valid_effect_link_claims?(
         %AI.Proposal{request_kind: :effect, target_id: target_id, affected_conditions: claims},
         conditions,
         relations
       ) do
    current = Map.new(conditions, &{&1.id, &1})

    Enum.all?(claims, fn claim ->
      case Map.get(current, claim["condition_id"]) do
        %{target_id: ^target_id} ->
          map_size(claim) == 2

        %{target_id: condition_target_id} when is_binary(condition_target_id) ->
          Enum.any?(relations, fn relation ->
            relation.id == claim["relationship_id"] and
              relation.revision == claim["relationship_revision"] and
              Enum.sort([relation.source_target.id, relation.destination_target.id]) ==
                Enum.sort([condition_target_id, target_id])
          end)

        _unmapped ->
          false
      end
    end)
  end

  defp valid_effect_link_claims?(_proposal, _conditions, _relations), do: false

  defp valid_effect_citations?(%AI.Proposal{purpose: :investigation}, _request), do: true

  defp valid_effect_citations?(%AI.Proposal{} = proposal, request) do
    cited = MapSet.new(proposal.evidence_ids)
    target_evidence = AI.effect_target_evidence_ids(request)
    current = Map.new(request.conditions, &{&1.id, &1})

    Enum.any?(target_evidence, &MapSet.member?(cited, &1)) and
      Enum.all?(proposal.affected_conditions, fn claim ->
        condition = Map.fetch!(current, claim["condition_id"])

        condition.target_id == proposal.target_id or
          Enum.any?(request.evidence, fn
            %AI.Evidence{kind: "observation", target_id: target_id, id: id, observed_at_us: at}
            when is_integer(at) ->
              target_id == condition.target_id and at >= condition.current_occurred_at_us and
                MapSet.member?(cited, id) and
                (condition.state == :firing or id in condition.recovery_evidence_ids or
                   id in condition.failed_observation_ids)

            _other ->
              false
          end)
      end)
  end

  defp valid_retry_context?(nil), do: true

  defp valid_retry_context?(%{"category" => category} = context) do
    Map.keys(context) -- ["category", "rejection_code", "rejection_path"] == [] and
      bounded_retry_value?(category) and
      (is_nil(context["rejection_code"]) or bounded_retry_value?(context["rejection_code"])) and
      (is_nil(context["rejection_path"]) or
         (is_binary(context["rejection_path"]) and
            String.starts_with?(context["rejection_path"], "/") and
            byte_size(context["rejection_path"]) <= 200))
  end

  defp valid_retry_context?(_context), do: false

  defp bounded_retry_value?(value),
    do: is_binary(value) and value != "" and String.length(value) <= 64

  defp valid_budget?(%AI.Budget{} = budget) do
    Enum.all?(
      [
        budget.remaining_turns,
        budget.remaining_tokens,
        budget.remaining_target_requests,
        budget.remaining_effects,
        budget.remaining_related_targets
      ],
      &(is_integer(&1) and &1 >= 0)
    )
  end

  defp valid_budget?(_budget), do: false

  defp exhausted?(budget), do: budget.remaining_turns == 0 or budget.remaining_tokens == 0
  defp review_exhausted?(budget), do: budget.remaining_tokens == 0

  defp valid_disclosure?(%AI.Disclosure{} = disclosure) do
    limits = AI.resolver_disclosure_limits()

    is_integer(disclosure.max_items) and disclosure.max_items >= 0 and
      disclosure.max_items <= limits.max_items and
      is_integer(disclosure.max_bytes) and disclosure.max_bytes >= 0 and
      disclosure.max_bytes <= limits.max_bytes and
      is_list(disclosure.allowed_target_ids) and
      length(disclosure.allowed_target_ids) <= limits.max_items and
      Enum.all?(disclosure.allowed_target_ids, &bounded_identifier?/1) and
      unique?(disclosure.allowed_target_ids) and
      is_list(disclosure.allowed_evidence_kinds) and
      length(disclosure.allowed_evidence_kinds) <= limits.max_items and
      Enum.all?(disclosure.allowed_evidence_kinds, &bounded_kind?/1) and
      encoded_size(%{}, [disclosure]) <= limits.max_bytes
  end

  defp valid_disclosure?(_disclosure), do: false

  defp valid_resolver_items?(request) do
    if Enum.all?(
         [
           request.conditions,
           request.evidence,
           request.historical_evidence,
           request.recovery_evidence_ids,
           request.target_candidates,
           request.observation_results,
           request.target_relations,
           request.traversable_relation_ids,
           request.observation_tools,
           request.proposal_tools
         ],
         &is_list/1
       ) do
      valid? =
        Enum.all?(request.conditions, &valid_condition?/1) and
          Enum.all?(request.evidence, &valid_evidence?/1) and
          Enum.all?(request.historical_evidence, &valid_evidence?/1) and
          Enum.all?(request.target_candidates, &valid_candidate?/1) and
          Enum.all?(request.observation_results, &valid_observation_result?/1) and
          Enum.all?(request.target_relations, &valid_relation?/1) and
          Enum.all?(request.traversable_relation_ids, &bounded_identifier?/1) and
          Enum.all?(request.observation_tools, &valid_tool?/1) and
          Enum.all?(request.proposal_tools, &valid_proposal_tool?/1)

      if valid? do
        condition_ids = Enum.map(request.conditions, & &1.id)
        evidence_ids = Enum.map(request.evidence, & &1.id)
        historical_ids = Enum.map(request.historical_evidence, & &1.id)
        candidate_ids = Enum.map(request.target_candidates, & &1.id)
        result_ids = Enum.map(request.observation_results, & &1.id)
        relation_ids = Enum.map(request.target_relations, & &1.id)
        tool_ids = Enum.map(request.observation_tools ++ request.proposal_tools, & &1.id)

        unique?(condition_ids) and
          unique?(evidence_ids ++ historical_ids ++ result_ids ++ relation_ids) and
          unique?(request.recovery_evidence_ids) and
          Enum.all?(request.recovery_evidence_ids, &(&1 in evidence_ids)) and
          unique?(candidate_ids) and
          unique?(tool_ids) and unique?(request.traversable_relation_ids) and
          Enum.all?(request.traversable_relation_ids, &(&1 in relation_ids)) and
          valid_preselection_tools?(request)
      else
        false
      end
    else
      false
    end
  end

  defp valid_condition?(%AI.Condition{} = condition) do
    nonempty?(condition.id) and positive?(condition.revision) and
      positive?(condition.occurrence) and bounded_string?(condition.predicate, 500) and
      bounded_string?(condition.subject_key, 600) and is_map(condition.subject_ref) and
      condition.state in [:firing, :recovered] and
      condition.recovery_status in [
        nil,
        :firing,
        :stale_source,
        :unmapped_target,
        :needs_observation,
        :target_changed,
        :ready_for_review
      ] and
      is_list(condition.recovery_evidence_ids) and
      length(condition.recovery_evidence_ids) <= 3 and
      unique?(condition.recovery_evidence_ids) and
      Enum.all?(condition.recovery_evidence_ids, &nonempty?/1) and
      is_list(condition.failed_observation_ids) and
      length(condition.failed_observation_ids) <= 3 and
      unique?(condition.failed_observation_ids) and
      Enum.all?(condition.failed_observation_ids, &nonempty?/1) and
      (is_nil(condition.target_id) or nonempty?(condition.target_id)) and
      is_integer(condition.current_occurred_at_us)
  end

  defp valid_condition?(_condition), do: false

  defp valid_evidence?(%AI.Evidence{id: id, kind: kind, target_id: target_id}),
    do: nonempty?(id) and bounded_kind?(kind) and (is_nil(target_id) or nonempty?(target_id))

  defp valid_evidence?(_evidence), do: false

  defp valid_candidate?(%AI.TargetCandidate{} = candidate),
    do:
      nonempty?(candidate.id) and positive?(candidate.revision) and nonempty?(candidate.name) and
        nonempty?(candidate.kind) and nonempty?(candidate.type_id) and is_map(candidate.facts)

  defp valid_candidate?(_candidate), do: false

  defp valid_observation_result?(%AI.ObservationResult{} = result),
    do:
      nonempty?(result.id) and nonempty?(result.tool_id) and nonempty?(result.target_id) and
        bounded_kind?(result.kind) and is_atom(result.status)

  defp valid_observation_result?(_result), do: false

  defp valid_relation?(%AI.TargetRelation{} = relation),
    do:
      nonempty?(relation.id) and positive?(relation.revision) and
        valid_candidate?(relation.source_target) and
        valid_candidate?(relation.destination_target) and
        relation.source_target.id != relation.destination_target.id and
        bounded_kind?(relation.kind) and is_map(relation.attributes)

  defp valid_relation?(_relation), do: false

  defp valid_tool?(%AI.ObservationTool{} = tool),
    do:
      valid_exact_tool?(tool) and nonempty?(tool.description) and
        valid_input_schema?(tool.input_schema) and valid_input_schema?(tool.output_schema) and
        (is_nil(tool.verification_schema) or valid_input_schema?(tool.verification_schema))

  defp valid_tool?(_tool), do: false

  defp valid_proposal_tool?(%AI.ProposalTool{} = tool),
    do:
      valid_exact_tool?(tool) and nonempty?(tool.description) and
        tool.request_kind in [:observation, :effect] and
        valid_input_schema?(tool.input_schema) and
        valid_evidence_requirements?(tool.evidence_requirements)

  defp valid_proposal_tool?(_tool), do: false

  defp disclosed?(request) do
    items = AI.resolver_disclosure_items(request)

    disclosure = request.disclosure

    length(items) <= disclosure.max_items and
      evidence_allowed?(request.evidence, disclosure) and
      evidence_allowed?(request.historical_evidence, disclosure) and
      candidates_allowed?(request.target_candidates, disclosure) and
      results_allowed?(request.observation_results, disclosure) and
      relations_allowed?(request.target_relations, disclosure) and
      tools_allowed?(request.observation_tools, request.proposal_tools, disclosure) and
      AI.resolver_disclosure_size(request) <= disclosure.max_bytes
  end

  defp candidates_allowed?(candidates, disclosure) do
    Enum.all?(candidates, &(&1.id in disclosure.allowed_target_ids))
  end

  defp evidence_allowed?(evidence, disclosure) do
    Enum.all?(evidence, fn item ->
      item.kind in disclosure.allowed_evidence_kinds and
        (is_nil(item.target_id) or item.target_id in disclosure.allowed_target_ids)
    end)
  end

  defp results_allowed?(results, disclosure) do
    Enum.all?(results, fn result ->
      result.kind in disclosure.allowed_evidence_kinds and
        result.target_id in disclosure.allowed_target_ids
    end)
  end

  defp relations_allowed?(relations, disclosure) do
    Enum.all?(relations, fn relation ->
      relation.source_target.id in disclosure.allowed_target_ids and
        relation.destination_target.id in disclosure.allowed_target_ids
    end)
  end

  defp tools_allowed?(observation_tools, proposal_tools, disclosure) do
    Enum.all?(observation_tools ++ proposal_tools, fn tool ->
      tool.target_id in disclosure.allowed_target_ids
    end)
  end

  defp encoded_size(context, items) do
    encoded_items = Enum.map(items, &plain_value/1)

    case Jason.encode(%{context: context, items: encoded_items}) do
      {:ok, encoded} -> byte_size(encoded)
      {:error, _error} -> :infinity
    end
  end

  def validate_decision(:resolve, %AI.ResolverDecision{} = decision, request) do
    with :ok <- validate_usage(decision.usage, request.budget),
         :ok <- validate_resolver_intent(decision.intent, request),
         :ok <- validate_condition_assessments(decision, request),
         true <- encoded_size(%{}, [decision]) <= @max_output_bytes do
      :ok
    else
      false ->
        {:error, ai_error(:invalid_output, "AI Resolver output is too large", "output_too_large")}

      {:error, _error} = error ->
        error
    end
  end

  def validate_decision(:review, %AI.ReviewDecision{} = decision, request) do
    with :ok <- validate_usage(decision.usage, request.budget),
         true <- decision.verdict in [:approved, :rejected, :needs_human],
         true <- decision.purpose_assessment in [:investigation, :remediation, :unknown],
         true <-
           decision.verdict != :approved or
             decision.purpose_assessment == request.proposal.purpose,
         true <- bounded_text?(decision.reason, AI.reviewer_reason_codepoints()),
         true <- review_decision_size(decision) <= @max_output_bytes do
      :ok
    else
      false ->
        {:error, ai_error(:invalid_output, "AI Reviewer output is invalid", "reviewer_output")}

      {:error, _error} = error ->
        error
    end
  end

  def validate_decision(:review_recovery, %AI.ReviewDecision{} = decision, request) do
    with :ok <- validate_usage(decision.usage, request.budget),
         true <- decision.verdict in [:approved, :rejected, :needs_human],
         true <- bounded_text?(decision.reason, AI.reviewer_reason_codepoints()),
         true <-
           CaseSymptom.valid_assessment?(
             decision.desired_outcome_assessment,
             request.case_symptom,
             request.conclusion.desired_outcome_claims,
             decision.verdict
           ),
         true <- encoded_size(%{}, [decision]) <= @max_output_bytes do
      :ok
    else
      false ->
        {:error,
         ai_error(
           :invalid_output,
           "Recovery Reviewer output is invalid",
           "recovery_reviewer_output"
         )}

      {:error, _error} = error ->
        error
    end
  end

  def validate_decision(_operation, _decision, _request),
    do: {:error, ai_error(:invalid_output, "AI output is invalid", "invalid_output")}

  defp validate_resolver_intent(%AI.FileRead{} = read, request) do
    available? =
      Enum.any?(AI.file_read_options(request), fn option ->
        option["source_evidence_id"] == read.source_evidence_id and
          option["reference"] == read.reference
      end)

    if available? and is_integer(read.offset) and read.offset >= 0 and
         read.offset <= read.reference["size_bytes"] and is_integer(read.length) and
         read.length in 1..AI.file_read_bytes() and AI.valid_resolver_reason?(read.reason),
       do: :ok,
       else: {:error, ai_error(:invalid_output, "AI file read is invalid", "file_read")}
  end

  defp validate_resolver_intent(%AI.TargetSearch{} = search, request) do
    if request.budget.remaining_target_requests > 0 and
         bounded_text?(search.query, SearchQuery.max_codepoints()) and
         AI.valid_resolver_reason?(search.reason) do
      :ok
    else
      {:error, ai_error(:invalid_output, "AI Target search is invalid", "target_search")}
    end
  end

  defp validate_resolver_intent(%AI.TargetSelection{} = selection, request) do
    evidence_ids = available_evidence_ids(request)

    candidate =
      Enum.find(request.target_candidates, fn candidate ->
        candidate.id == selection.target_id and
          candidate.revision == selection.target_revision
      end)

    if not is_nil(candidate) and
         AI.valid_resolver_reason?(selection.reason) and
         nonempty_list?(selection.evidence_ids) and
         unique?(selection.evidence_ids) and
         Enum.all?(selection.evidence_ids, &(&1 in evidence_ids)) and
         Enum.any?(
           selection.evidence_ids,
           &(&1 in AI.target_candidate_evidence_ids(request, selection.target_id))
         ) do
      :ok
    else
      {:error, ai_error(:invalid_output, "AI Target selection is invalid", "target_selection")}
    end
  end

  defp validate_resolver_intent(%AI.TargetTraversal{} = traversal, request) do
    evidence_ids = available_evidence_ids(request)

    relationship =
      Enum.find(request.target_relations, fn relationship ->
        relationship.id == traversal.relationship_id and
          relationship.revision == traversal.relationship_revision
      end)

    if request.budget.remaining_related_targets > 0 and not is_nil(relationship) and
         traversal.relationship_id in request.traversable_relation_ids and
         traversal_destination?(relationship, request.selected_target_id, traversal) and
         AI.valid_resolver_reason?(traversal.reason) and
         nonempty_list?(traversal.evidence_ids) and unique?(traversal.evidence_ids) and
         Enum.all?(traversal.evidence_ids, &(&1 in evidence_ids)) do
      :ok
    else
      {:error, ai_error(:invalid_output, "AI Target traversal is invalid", "target_traversal")}
    end
  end

  defp validate_resolver_intent(%AI.Proposal{} = proposal, request) do
    case Enum.find(request.proposal_tools, &(&1.id == proposal.tool_id)) do
      %AI.ProposalTool{} = tool ->
        evidence_ids = request_evidence_ids(proposal, request)

        if request_budget_available?(tool, request) and
             valid_tool_input?(proposal.selectors, proposal.parameters, tool.input_schema) and
             (proposal.purpose == :investigation or
                AI.proposal_requirements_match?(
                  tool,
                  request,
                  proposal.evidence_ids,
                  proposal.parameters
                )) and
             exact_proposal?(proposal, tool) and
             AI.valid_affected_conditions?(proposal, request.conditions) and
             valid_effect_link_claims?(proposal, request.conditions, request.target_relations) and
             valid_effect_citations?(proposal, request) and
             valid_request_verification?(proposal, tool, request.observation_tools) and
             AI.valid_resolver_reason?(proposal.reason) and
             is_integer(proposal.delay_seconds) and proposal.delay_seconds in 0..86_400 and
             valid_request_evidence_ids?(proposal, evidence_ids) do
          :ok
        else
          {:error, ai_error(:invalid_output, "AI Proposal is invalid", "proposal")}
        end

      _tool ->
        {:error, ai_error(:invalid_output, "AI Proposal is invalid", "proposal")}
    end
  end

  defp validate_resolver_intent(%AI.RecoveryConclusion{} = conclusion, request) do
    recovery_evidence_ids = AI.recovery_evidence_ids(request)

    if request.alert_state in [:recovered, :not_applicable] and
         AI.valid_resolver_reason?(conclusion.reason) and
         nonempty_list?(conclusion.evidence_ids) and unique?(conclusion.evidence_ids) and
         Enum.all?(conclusion.evidence_ids, &(&1 in recovery_evidence_ids)) and
         visible_file_citations?(conclusion.evidence_ids, request.evidence) and
         valid_condition_claims?(conclusion.condition_claims, request, conclusion.evidence_ids) and
         CaseSymptom.valid_claims?(
           conclusion.desired_outcome_claims,
           request.case_symptom,
           conclusion.evidence_ids,
           request.evidence
         ) do
      :ok
    else
      {:error, ai_error(:invalid_output, "AI recovery conclusion is invalid", "recovery")}
    end
  end

  defp validate_resolver_intent(%AI.CaseSplit{} = split, request) do
    available = request.conditions |> Enum.map(& &1.id) |> MapSet.new()
    observations = AI.case_split_observations(request)
    cited = observations |> Enum.map(& &1.id) |> MapSet.new()

    moved =
      if is_list(split.condition_ids), do: MapSet.new(split.condition_ids), else: MapSet.new()

    moved_targets =
      request.conditions
      |> Enum.filter(&MapSet.member?(moved, &1.id))
      |> Enum.map(& &1.target_id)
      |> MapSet.new()

    remaining_targets =
      request.conditions
      |> Enum.reject(&MapSet.member?(moved, &1.id))
      |> Enum.map(& &1.target_id)
      |> MapSet.new()

    if is_list(split.condition_ids) and is_list(split.evidence_ids) and
         is_list(split.remaining_evidence_ids) and
         Enum.all?(
           split.condition_ids ++ split.evidence_ids ++ split.remaining_evidence_ids,
           &is_binary/1
         ) and
         MapSet.size(available) > 1 and split.condition_ids != [] and
         MapSet.size(MapSet.new(split.condition_ids)) < MapSet.size(available) and
         MapSet.subset?(MapSet.new(split.condition_ids), available) and
         unique?(split.condition_ids) and nonempty_list?(split.evidence_ids) and
         nonempty_list?(split.remaining_evidence_ids) and unique?(split.evidence_ids) and
         unique?(split.remaining_evidence_ids) and
         MapSet.subset?(MapSet.new(split.evidence_ids ++ split.remaining_evidence_ids), cited) and
         Enum.any?(observations, fn evidence ->
           evidence.id in split.evidence_ids and MapSet.member?(moved_targets, evidence.target_id)
         end) and
         Enum.any?(observations, fn evidence ->
           evidence.id in split.remaining_evidence_ids and
             MapSet.member?(remaining_targets, evidence.target_id)
         end) and
         AI.valid_resolver_reason?(split.reason) do
      :ok
    else
      {:error, ai_error(:invalid_output, "AI Case split request is invalid", "case_split")}
    end
  end

  defp validate_resolver_intent(%AI.Handoff{} = handoff, _request) do
    if AI.valid_resolver_reason?(handoff.reason) and
         bounded_text?(handoff.required_input, AI.handoff_input_codepoints()),
       do: :ok,
       else: {:error, ai_error(:invalid_output, "AI handoff is invalid", "handoff")}
  end

  defp validate_resolver_intent(_intent, _request),
    do: {:error, ai_error(:invalid_output, "AI Resolver intent is invalid", "resolver_intent")}

  defp visible_file_citations?(ids, evidence) do
    Enum.all?(evidence, fn item ->
      item.id not in ids or item.kind != "file_read" or
        (item.content["status"] == "available" and
           is_binary(item.content["value"]) and item.content["encoding"] in ["utf8", "base64"])
    end)
  end

  defp valid_condition_claims?([], %{conditions: []}, _evidence_ids), do: true

  defp valid_condition_claims?(claims, request, evidence_ids) when is_list(claims) do
    expected = Map.new(request.conditions, &{&1.id, &1})

    Enum.all?(claims, &is_map/1) and length(claims) == map_size(expected) and
      MapSet.new(Enum.map(claims, & &1["condition_id"])) == MapSet.new(Map.keys(expected)) and
      Enum.all?(claims, fn claim ->
        condition = Map.get(expected, claim["condition_id"])

        (condition && claim["revision"] == condition.revision) and
          condition.state == :recovered and condition.recovery_status == :ready_for_review and
          claim["evidence_id"] in condition.recovery_evidence_ids and
          claim["evidence_id"] in evidence_ids and
          AI.valid_resolver_reason?(claim["reason"]) and
          claim["evidence_id"] in request.recovery_evidence_ids
      end)
  end

  defp valid_condition_claims?(_claims, _request, _evidence_ids), do: false

  defp validate_condition_assessments(
         %AI.ResolverDecision{condition_assessments: []},
         _request
       ),
       do: :ok

  defp validate_condition_assessments(
         %AI.ResolverDecision{
           intent: intent,
           condition_assessments: assessments
         },
         request
       )
       when is_list(assessments) do
    expected = Map.new(request.conditions, &{&1.id, &1})
    visible = MapSet.new(Enum.map(request.evidence, & &1.id))
    assessed_ids = Enum.map(assessments, &if(is_map(&1), do: &1["condition_id"]))

    issue =
      cond do
        request.alert_state != :recovered ->
          :source_state

        map_size(expected) == 0 or not unique?(assessed_ids) or
            Enum.any?(assessed_ids, &(not Map.has_key?(expected, &1))) ->
          :membership

        true ->
          Enum.find_value(assessments, fn assessment ->
            condition = Map.fetch!(expected, assessment["condition_id"])
            condition_assessment_issue(assessment, condition, visible)
          end) ||
            if(
              match?(%AI.RecoveryConclusion{}, intent) and
                Enum.any?(assessments, &(&1["status"] != "recovered")),
              do: :recovery_intent_conflict,
              else: nil
            )
      end

    if is_nil(issue),
      do: :ok,
      else:
        {:error,
         ai_error(
           :invalid_output,
           "AI Condition assessment is invalid: #{issue}",
           "condition_assessment_#{issue}"
         )}
  end

  defp validate_condition_assessments(_decision, _request),
    do:
      {:error,
       ai_error(:invalid_output, "AI Condition assessment is invalid", "condition_assessment")}

  defp condition_assessment_issue(assessment, condition, visible) do
    ids = assessment["evidence_ids"]

    cond do
      map_size(assessment) != 5 ->
        :shape

      assessment["revision"] != condition.revision ->
        :revision

      not AI.valid_resolver_reason?(assessment["reason"]) ->
        :reason

      not is_list(ids) or length(ids) > 3 or not unique?(ids) ->
        :citation_shape

      not Enum.all?(ids, fn id ->
        id in condition.recovery_evidence_ids and MapSet.member?(visible, id)
      end) ->
        :citation_scope

      assessment["status"] in ["recovered", "still_failing"] and ids == [] ->
        :citation_missing

      assessment["status"] not in ["recovered", "still_failing", "unknown"] ->
        :status

      true ->
        nil
    end
  end

  defp traversal_destination?(relationship, selected_target_id, traversal) do
    next_target =
      cond do
        relationship.source_target.id == selected_target_id ->
          relationship.destination_target

        relationship.destination_target.id == selected_target_id ->
          relationship.source_target

        true ->
          nil
      end

    not is_nil(next_target) and next_target.id == traversal.next_target_id and
      next_target.revision == traversal.next_target_revision
  end

  defp valid_review_proposal?(%AI.Proposal{} = proposal, evidence_ids) do
    nonempty?(proposal.tool_id) and nonempty?(proposal.target_id) and
      positive?(proposal.target_revision) and nonempty?(proposal.access_method_id) and
      positive?(proposal.access_method_revision) and
      AI.valid_proposal_purpose?(proposal.request_kind, proposal.purpose) and
      nonempty?(proposal.capability) and
      nonempty?(proposal.operation) and is_map(proposal.parameters) and
      AI.valid_resolver_reason?(proposal.reason) and is_map(proposal.selectors) and
      is_integer(proposal.delay_seconds) and proposal.delay_seconds in 0..86_400 and
      valid_request_evidence_ids?(proposal, evidence_ids) and
      valid_review_verification?(proposal)
  end

  defp review_decision_size(decision) do
    case Jason.encode(%{
           verdict: decision.verdict,
           purpose_assessment: decision.purpose_assessment,
           reason: decision.reason,
           usage: Map.from_struct(decision.usage)
         }) do
      {:ok, value} -> byte_size(value)
      {:error, _error} -> :infinity
    end
  end

  defp available_evidence_ids(request),
    do: Enum.map(request.evidence ++ request.observation_results, & &1.id)

  defp valid_exact_tool?(tool) do
    nonempty?(tool.id) and nonempty?(tool.target_id) and positive?(tool.target_revision) and
      nonempty?(tool.access_method_id) and positive?(tool.access_method_revision) and
      nonempty?(tool.provider_id) and positive?(tool.provider_revision) and
      nonempty?(tool.capability) and nonempty?(tool.operation)
  end

  defp valid_selected_target?(request) do
    (is_nil(request.selected_target_id) and is_nil(request.selected_target_revision)) or
      (nonempty?(request.selected_target_id) and positive?(request.selected_target_revision) and
         request.selected_target_id in request.disclosure.allowed_target_ids)
  end

  defp valid_preselection_tools?(%{selected_target_id: nil} = request) do
    request.observation_tools == [] and request.proposal_tools == [] and
      request.target_relations == [] and request.traversable_relation_ids == []
  end

  defp valid_preselection_tools?(_request), do: true

  defp exact_proposal?(proposal, tool) do
    AI.valid_proposal_purpose?(proposal.request_kind, proposal.purpose) and
      proposal.request_kind == tool.request_kind and proposal.target_id == tool.target_id and
      proposal.target_revision == tool.target_revision and
      proposal.access_method_id == tool.access_method_id and
      proposal.access_method_revision == tool.access_method_revision and
      proposal.capability == tool.capability and proposal.operation == tool.operation
  end

  defp request_budget_available?(%{request_kind: :observation}, request),
    do: request.budget.remaining_target_requests > 0

  defp request_budget_available?(%{request_kind: :effect}, request),
    do: request.budget.remaining_effects > 0

  defp request_evidence_ids(%{purpose: :investigation}, request),
    do: available_evidence_ids(request)

  defp request_evidence_ids(%{request_kind: :effect}, request),
    do: AI.proposal_evidence_ids(request)

  defp valid_request_evidence_ids?(%{purpose: :investigation, evidence_ids: ids}, available),
    do: is_list(ids) and unique?(ids) and Enum.all?(ids, &(&1 in available))

  defp valid_request_evidence_ids?(%{request_kind: :effect, evidence_ids: ids}, available),
    do: nonempty_list?(ids) and unique?(ids) and Enum.all?(ids, &(&1 in available))

  defp valid_request_verification?(
         %AI.Proposal{purpose: :investigation} = proposal,
         _tool,
         _tools
       ),
       do: proposal.expected_result == %{} and is_nil(proposal.verification_intent)

  defp valid_request_verification?(
         %AI.Proposal{purpose: :remediation, verification_intent: nil} = proposal,
         _tool,
         _tools
       ),
       do: is_map(proposal.expected_result) and map_size(proposal.expected_result) > 0

  defp valid_request_verification?(%AI.Proposal{request_kind: :effect} = proposal, _tool, tools),
    do:
      is_map(proposal.expected_result) and
        valid_verification_intent?(proposal.verification_intent, tools)

  defp valid_review_verification?(%AI.Proposal{purpose: :investigation} = proposal),
    do: proposal.expected_result == %{} and is_nil(proposal.verification_intent)

  defp valid_review_verification?(
         %AI.Proposal{purpose: :remediation, verification_intent: nil} = proposal
       ),
       do: is_map(proposal.expected_result) and map_size(proposal.expected_result) > 0

  defp valid_review_verification?(%AI.Proposal{request_kind: :effect} = proposal),
    do:
      is_map(proposal.expected_result) and
        valid_verification_intent?(proposal.verification_intent)

  defp valid_verification_intent?(%AI.VerificationIntent{} = intent, tools) do
    case Enum.find(tools, &(&1.id == intent.tool_id)) do
      %AI.ObservationTool{} = tool ->
        valid_verification_intent?(intent) and
          valid_tool_input?(intent.selectors, intent.parameters, tool.input_schema) and
          valid_expected_result?(intent.expected_result, tool.verification_schema)

      _tool ->
        false
    end
  end

  defp valid_verification_intent?(_intent, _tools), do: false

  defp valid_verification_intent?(%AI.VerificationIntent{} = intent),
    do:
      nonempty?(intent.tool_id) and is_map(intent.selectors) and is_map(intent.parameters) and
        is_map(intent.expected_result)

  defp valid_verification_intent?(_intent), do: false

  defp valid_expected_result?(expected, schema) when is_map(expected) and is_map(schema) do
    valid_against_schema?(expected, schema)
  end

  defp valid_expected_result?(_expected, _schema), do: false

  defp valid_evidence_requirements?([]), do: true

  defp valid_evidence_requirements?(requirements) when is_list(requirements) do
    length(requirements) <= 20 and
      Enum.all?(requirements, fn
        %Target.EvidenceRequirement{} = requirement ->
          bounded_identifier?(requirement.parameter) and
            bounded_identifier?(requirement.fact) and
            bounded_identifier?(requirement.observation)

        _requirement ->
          false
      end) and
      unique?(Enum.map(requirements, & &1.parameter))
  end

  defp valid_evidence_requirements?(_requirements), do: false

  defp valid_input_schema?(schema) when is_map(schema) do
    try do
      match?({:ok, %JSV.Root{}}, JSV.build(schema, warnings: :silent))
    rescue
      _error -> false
    end
  end

  defp valid_input_schema?(_schema), do: false

  defp valid_tool_input?(selectors, parameters, schema)
       when is_map(selectors) and is_map(parameters) do
    valid_against_schema?(
      %{"selectors" => selectors, "parameters" => parameters},
      schema
    )
  end

  defp valid_tool_input?(_selectors, _parameters, _schema), do: false

  defp valid_against_schema?(value, schema) when is_map(schema) do
    try do
      with {:ok, root} <- JSV.build(schema, warnings: :silent),
           {:ok, _validated} <- JSV.validate(value, root, cast: false) do
        true
      else
        _invalid -> false
      end
    rescue
      _error -> false
    end
  end

  defp valid_against_schema?(_value, _schema), do: false

  defp plain_value(%_{} = value), do: value |> Map.from_struct() |> plain_value()

  defp plain_value(value) when is_map(value),
    do: Map.new(value, fn {key, nested} -> {key, plain_value(nested)} end)

  defp plain_value(value) when is_list(value), do: Enum.map(value, &plain_value/1)
  defp plain_value(value), do: value

  defp validate_usage(%AI.Usage{input_tokens: input, output_tokens: output}, budget)
       when is_integer(input) and input >= 0 and is_integer(output) and output >= 0 do
    if input + output <= budget.remaining_tokens,
      do: :ok,
      else: {:error, ai_error(:budget_exhausted, "AI token budget was exceeded")}
  end

  defp validate_usage(_usage, _budget),
    do: {:error, ai_error(:invalid_output, "AI token usage is invalid", "usage_invalid")}

  defp unique?(items), do: length(items) == MapSet.size(MapSet.new(items))
  defp positive?(value), do: is_integer(value) and value > 0
  defp nonempty?(value), do: is_binary(value) and byte_size(value) > 0
  defp nonempty_list?(value), do: is_list(value) and value != []

  defp valid_instructions?(value),
    do: is_binary(value) and byte_size(value) <= 16_000 and String.valid?(value)

  defp bounded_string?(value, max_bytes),
    do: nonempty?(value) and byte_size(value) <= max_bytes

  defp bounded_text?(value, max_codepoints) when is_binary(value) and byte_size(value) > 0 do
    case :unicode.characters_to_list(value) do
      codepoints when is_list(codepoints) -> length(codepoints) <= max_codepoints
      _invalid -> false
    end
  end

  defp bounded_text?(_value, _max_codepoints), do: false

  defp bounded_kind?(value), do: bounded_string?(value, 120)
  defp bounded_identifier?(value), do: bounded_string?(value, 500)

  defp ai_error(category, message), do: AI.Error.exception(category: category, message: message)

  defp ai_error(category, message, failure_code),
    do: AI.Error.exception(category: category, message: message, failure_code: failure_code)
end
