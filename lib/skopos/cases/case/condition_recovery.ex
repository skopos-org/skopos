defmodule Skopos.Cases.Case.ConditionRecovery do
  @moduledoc false

  alias Skopos.{Cases, Targets}

  defmodule EffectIncomplete do
    @moduledoc false
    use Splode.Error, class: :invalid, fields: []

    @impl true
    def message(_error), do: "Relevant Target effect is not complete"
  end

  @max_lineage_depth 32
  @max_citations_per_condition 3
  @observation_source_fields ~w(id case_id purpose status dispatch_started_at target_id target_revision capability operation selectors)a

  # Evidence availability does not decide whether the fault recovered.
  def assess_current(incident, exclude_operation_id \\ nil) do
    with {:ok, memberships} <-
           Cases.active_conditions_for_case(incident.id,
             authorize?: false,
             query: [select: [:id, :case_id, :condition_id, :attached_at, :detached_at]],
             load: [:condition]
           ) do
      assess_loaded(incident, memberships, exclude_operation_id)
    end
  end

  def assess_loaded(incident, memberships, exclude_operation_id \\ nil) do
    with true <- memberships != [] || invalid("Signal Case has no active Conditions"),
         {:ok, effects} <-
           lineage_effects(
             incident,
             Enum.map(memberships, & &1.condition_id),
             exclude_operation_id
           ),
         {:ok, assessments} <- prepare_assessments(memberships, incident, effects),
         {:ok, assessments} <- scan_assessment_pages(incident, assessments, nil) do
      {:ok, Enum.map(assessments, &finish_assessment/1)}
    end
  end

  defp prepare_assessments(memberships, incident, effects) do
    Enum.reduce_while(memberships, {:ok, []}, fn membership, {:ok, collected} ->
      with {:ok, baseline} <- condition_baseline(incident, membership.condition_id, effects),
           {:ok, assessment} <- prepare_assessment(membership.condition, baseline) do
        {:cont, {:ok, [assessment | collected]}}
      else
        {:error, _error} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, assessments} -> {:ok, Enum.reverse(assessments)}
      error -> error
    end
  end

  defp scan_assessment_pages(incident, assessments, cursor) do
    page_options = if cursor, do: [after: cursor], else: []

    with {:ok, page} <-
           Cases.condition_assessment_evidence(
             incident.id,
             inherited_baseline(incident),
             authorize?: false,
             page: page_options
           ),
         {:ok, assessments} <-
           Enum.reduce_while(assessments, {:ok, []}, fn assessment, {:ok, collected} ->
             case assess_window(assessment, page.results) do
               {:ok, assessed} -> {:cont, {:ok, [assessed | collected]}}
               {:error, _error} = error -> {:halt, error}
             end
           end) do
      assessments = Enum.reverse(assessments)

      if page.more? do
        scan_assessment_pages(incident, assessments, List.last(page.results).__metadata__.keyset)
      else
        {:ok, assessments}
      end
    end
  end

  def inherited_baseline(incident), do: incident.recovery_baseline_at || incident.inserted_at

  def applied_effect_refresh_at(incident, run_id, condition_ids) do
    if condition_ids == [] do
      {:ok, nil}
    else
      with {:ok, case_ids} <- lineage_case_ids(incident, MapSet.new(), 0) do
        Enum.reduce_while(case_ids, {:ok, nil}, fn case_id, {:ok, latest_at} ->
          case Cases.latest_applied_recovery_effect(case_id, run_id, condition_ids,
                 authorize?: false
               ) do
            {:ok, [operation]} ->
              {:cont, {:ok, later_time(latest_at, operation.completed_at)}}

            {:ok, []} ->
              {:cont, {:ok, latest_at}}

            {:error, _error} = error ->
              {:halt, error}
          end
        end)
      end
    end
  end

  def baseline_for_case(incident) do
    inherited = inherited_baseline(incident)

    with {:ok, operations} <-
           Cases.latest_recovery_effect(incident.id, nil, nil, authorize?: false) do
      case operations do
        [] ->
          {:ok, inherited}

        [%{status: status, completed_at: %DateTime{} = at} | _]
        when status in [:applied, :failed, :partial, :unknown] ->
          {:ok, if(DateTime.compare(at, inherited) == :gt, do: at, else: inherited)}

        _other ->
          invalid("Latest Target effect is not complete")
      end
    end
  end

  # This marks evidence available for AI review; it never decides recovery.
  def manual_evidence_ids(incident, run, target, evidence)
      when incident.trigger_kind in [:manual, :audit] and not is_nil(target) do
    case baseline_for_case(incident) do
      {:ok, baseline} ->
        with {:ok, candidates} <-
               select_evidence(evidence, &manual_candidate(&1, incident, run, target, baseline)) do
          {:ok, Enum.map(candidates, & &1.id)}
        end

      {:error, %Ash.Error.Changes.InvalidChanges{}} ->
        {:ok, []}

      {:error, _error} = error ->
        error
    end
  end

  def manual_evidence_ids(_incident, _run, _target, _evidence), do: {:ok, []}

  defp manual_candidate(
         %{kind: "file_read"} = evidence,
         incident,
         run,
         target,
         baseline
       ) do
    if is_binary(evidence.content["value"]) do
      case Cases.file_read_source(evidence.id, incident.id, authorize?: false) do
        {:ok, source} -> manual_candidate(source, incident, run, target, baseline)
        {:error, error} -> unavailable_source(error)
      end
    else
      {:ok, false}
    end
  end

  defp manual_candidate(evidence, incident, run, target, baseline) do
    if DateTime.compare(evidence.observed_at, baseline) != :lt and
         evidence.content["target_id"] == target.id do
      case evidence do
        %{
          kind: "observation",
          source: "operation",
          source_ref: operation_id,
          content: %{"status" => "applied", "facts" => facts}
        }
        when is_map(facts) and map_size(facts) > 0 ->
          case Cases.get_operation(operation_id, authorize?: false, not_found_error?: false) do
            {:ok, %{} = operation} ->
              {:ok,
               evidence.resolution_run_id == run.id and operation.case_id == incident.id and
                 operation.resolution_run_id == run.id and
                 operation.target_id == target.id and operation.target_revision == target.revision and
                 operation.purpose == :investigation and operation.status == :applied and
                 is_struct(operation.dispatch_started_at, DateTime) and
                 DateTime.compare(operation.dispatch_started_at, baseline) != :lt}

            {:error, _error} = error ->
              error

            _other ->
              {:ok, false}
          end

        %{
          kind: "target_verification",
          source: "verification",
          content: %{"status" => "verified", "operation_id" => operation_id}
        } ->
          with {:ok, %{} = operation} <-
                 Cases.get_operation(operation_id, authorize?: false, not_found_error?: false),
               {:ok, %{} = attempt} <-
                 Cases.verification_attempt_by_operation(operation_id,
                   authorize?: false,
                   not_found_error?: false
                 ) do
            {:ok,
             operation.case_id == incident.id and operation.target_id == target.id and
               operation.target_revision == target.revision and
               operation.purpose == :remediation and operation.status == :applied and
               attempt.status == :verified and attempt.case_id == incident.id and
               attempt.observed_at == evidence.observed_at}
          else
            {:error, _error} = error -> error
            _other -> {:ok, false}
          end

        _other ->
          {:ok, false}
      end
    else
      {:ok, false}
    end
  end

  def ready_for_review?(assessments) when is_list(assessments) and assessments != [] do
    Enum.all?(assessments, &(&1.status == :ready_for_review))
  end

  def ready_for_review?(_assessments), do: false

  defp current_evidence(
         %{kind: "file_read"} = evidence,
         condition,
         baseline,
         target_revision,
         _metadata
       ) do
    case Cases.file_read_source(evidence.id, evidence.case_id, authorize?: false) do
      {:ok, source} ->
        current_evidence(source, condition, baseline, target_revision, source.content)

      {:error, error} ->
        unavailable_source(error)
    end
  end

  defp current_evidence(evidence, condition, baseline, target_revision, metadata)
       when is_struct(baseline, DateTime) do
    if DateTime.compare(evidence.observed_at, baseline) != :lt and
         DateTime.compare(evidence.observed_at, condition.current_occurred_at) != :lt and
         metadata["target_id"] == condition.target_id do
      valid_operation_evidence(evidence, condition, target_revision, metadata)
    else
      {:ok, false}
    end
  end

  defp prepare_assessment(condition, after_at) do
    cond do
      condition.state != :recovered ->
        {:ok, %{assessment: result(condition, :firing)}}

      is_nil(condition.target_id) ->
        {:ok, %{assessment: result(condition, :unmapped_target)}}

      true ->
        case Targets.get_target(condition.target_id, authorize?: false, not_found_error?: false) do
          {:ok, %{active: true, revision: revision}} ->
            {:ok,
             %{
               condition: condition,
               after_at: after_at,
               target_revision: revision,
               current: [],
               failed: []
             }}

          {:error, _error} = error ->
            error

          _other ->
            {:ok, %{assessment: result(condition, :target_changed)}}
        end
    end
  end

  defp assess_window(%{assessment: _assessment} = collected, _evidence), do: {:ok, collected}

  defp assess_window(collected, evidence) do
    Enum.reduce_while(evidence, {:ok, collected}, fn item, {:ok, collected} ->
      with {:ok, failed?} <-
             current_failed_observation(
               item,
               collected.condition,
               collected.after_at,
               collected.target_revision,
               item.recovery_metadata
             ),
           {:ok, current?} <-
             current_evidence(
               item,
               collected.condition,
               collected.after_at,
               collected.target_revision,
               item.recovery_metadata
             ) do
        {:cont,
         {:ok,
          %{
            collected
            | failed: add_citation(collected.failed, item, failed?),
              current: add_citation(collected.current, item, current?)
          }}}
      else
        {:error, _error} = error -> {:halt, error}
      end
    end)
  end

  defp add_citation(citations, _evidence, false), do: citations

  defp add_citation(citations, _evidence, true)
       when length(citations) >= @max_citations_per_condition, do: citations

  defp add_citation(citations, evidence, true) do
    scope = citation_scope(evidence)

    if Enum.any?(citations, fn {_id, previous_scope} -> scope == previous_scope end),
      do: citations,
      else: citations ++ [{evidence.id, scope}]
  end

  defp finish_assessment(%{assessment: assessment}), do: assessment

  defp finish_assessment(collected) do
    citations = Enum.map(collected.current, &elem(&1, 0))
    failed_ids = Enum.map(collected.failed, &elem(&1, 0))

    status =
      cond do
        citations != [] ->
          :ready_for_review

        DateTime.compare(collected.condition.current_occurred_at, collected.after_at) == :lt ->
          :stale_source

        true ->
          :needs_observation
      end

    result(collected.condition, status, citations, failed_ids)
  end

  defp condition_baseline(incident, condition_id, effects) do
    case Map.get(effects, condition_id) do
      nil ->
        {:ok, inherited_baseline(incident)}

      %{status: status, completed_at: %DateTime{} = completed_at}
      when status in [:applied, :failed, :partial, :unknown] ->
        inherited = inherited_baseline(incident)

        {:ok,
         if(DateTime.compare(completed_at, inherited) == :gt, do: completed_at, else: inherited)}

      _other ->
        {:error, EffectIncomplete.exception([])}
    end
  end

  defp lineage_effects(incident, condition_ids, exclude_operation_id) do
    with {:ok, case_ids} <- lineage_case_ids(incident, MapSet.new(), 0) do
      Enum.reduce_while(case_ids, {:ok, %{}}, fn case_id, {:ok, collected} ->
        case scoped_effects(case_id, condition_ids, exclude_operation_id) do
          {:ok, effects} ->
            {:cont,
             {:ok,
              Map.merge(collected, effects, fn _id, first, second ->
                newest_effect(first, second)
              end)}}

          {:error, _error} = error ->
            {:halt, error}
        end
      end)
    end
  end

  defp scoped_effects(case_id, condition_ids, exclude_operation_id) do
    Enum.reduce_while(condition_ids, {:ok, %{}}, fn id, {:ok, effects} ->
      case Cases.latest_recovery_effect(case_id, [id], exclude_operation_id, authorize?: false) do
        {:ok, [operation]} ->
          {:cont, {:ok, Map.put(effects, id, operation)}}

        {:ok, []} ->
          {:cont, {:ok, effects}}

        {:error, _error} = error ->
          {:halt, error}
      end
    end)
  end

  defp newest_effect(first, second) do
    key = fn operation ->
      {DateTime.to_unix(operation.accepted_at, :microsecond), operation.id}
    end

    if key.(first) >= key.(second), do: first, else: second
  end

  defp later_time(nil, at), do: at

  defp later_time(first, second),
    do: if(DateTime.compare(first, second) == :lt, do: second, else: first)

  defp lineage_case_ids(_incident, _seen, depth)
       when depth >= @max_lineage_depth,
       do: invalid("Case split lineage exceeds recovery bound")

  defp lineage_case_ids(incident, seen, depth) do
    if MapSet.member?(seen, incident.id) do
      invalid("Case split lineage contains a cycle")
    else
      with {:ok, parents} <- parent_case_ids(incident, MapSet.put(seen, incident.id), depth + 1) do
        {:ok, [incident.id | parents]}
      end
    end
  end

  defp parent_case_ids(%{split_parent_id: nil}, _seen, _depth), do: {:ok, []}

  defp parent_case_ids(%{split_parent_id: parent_id}, seen, depth) do
    with {:ok, parent} <-
           Cases.get_case(parent_id,
             authorize?: false,
             query: [select: [:id, :split_parent_id]]
           ) do
      lineage_case_ids(parent, seen, depth)
    end
  end

  defp citation_scope(%{kind: "file_read", id: id}), do: {"file_read", id}

  defp citation_scope(evidence) do
    content = evidence.recovery_metadata

    {evidence.kind, content["capability"], content["operation"], content["selectors"]}
  end

  defp result(condition, status, evidence_ids \\ [], failed_observation_ids \\ []) do
    %{
      condition_id: condition.id,
      revision: condition.revision,
      status: status,
      evidence_ids: evidence_ids,
      failed_observation_ids: failed_observation_ids
    }
  end

  defp select_evidence(evidence, candidate) do
    evidence
    |> Enum.reduce_while({:ok, []}, fn item, {:ok, selected} ->
      case candidate.(item) do
        {:ok, true} -> {:cont, {:ok, [item | selected]}}
        {:ok, false} -> {:cont, {:ok, selected}}
        {:error, _error} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, selected} -> {:ok, Enum.reverse(selected)}
      error -> error
    end
  end

  defp current_failed_observation(evidence, condition, baseline, target_revision, metadata) do
    with true <- DateTime.compare(evidence.observed_at, baseline) != :lt,
         true <- DateTime.compare(evidence.observed_at, condition.current_occurred_at) != :lt,
         true <-
           evidence.kind == "observation" and
             evidence.source == "operation" and
             metadata["target_id"] == condition.target_id and
             metadata["status"] == "failed",
         {:ok, %{} = operation} <-
           Cases.get_operation(evidence.source_ref,
             authorize?: false,
             not_found_error?: false,
             query: [select: @observation_source_fields]
           ),
         true <- operation.id == evidence.source_ref and operation.case_id == evidence.case_id,
         true <-
           operation.purpose == :investigation and operation.status == :failed and
             is_struct(operation.dispatch_started_at, DateTime),
         true <-
           operation.target_id == condition.target_id and
             operation.target_revision == target_revision,
         true <-
           operation.capability == metadata["capability"] and
             operation.operation == metadata["operation"] and
             operation.selectors == metadata["selectors"] do
      {:ok, true}
    else
      {:error, _error} = error -> error
      _invalid -> {:ok, false}
    end
  end

  defp valid_operation_evidence(
         %{kind: "observation", source: "operation"} = evidence,
         condition,
         revision,
         content
       ) do
    with true <- content["status"] == "applied",
         true <- content["target_id"] == condition.target_id,
         {:ok, %{} = operation} <-
           Cases.get_operation(evidence.source_ref,
             authorize?: false,
             not_found_error?: false,
             query: [select: @observation_source_fields]
           ),
         true <- operation.purpose == :investigation and operation.status == :applied,
         true <- operation.case_id == evidence.case_id and operation.id == evidence.source_ref,
         true <-
           operation.target_id == condition.target_id and operation.target_revision == revision,
         true <- operation.capability == content["capability"],
         true <- operation.operation == content["operation"],
         true <- operation.selectors == content["selectors"] do
      {:ok, true}
    else
      {:error, _error} = error -> error
      _other -> {:ok, false}
    end
  end

  defp valid_operation_evidence(
         %{kind: "target_verification", source: "verification"} = evidence,
         condition,
         revision,
         content
       ) do
    with true <- content["status"] == "verified" and content["target_id"] == condition.target_id,
         {:ok, %{} = operation} <-
           Cases.get_operation(content["operation_id"],
             authorize?: false,
             not_found_error?: false,
             query: [select: [:id, :case_id, :purpose, :status, :target_id, :target_revision]]
           ),
         true <- operation.purpose == :remediation and operation.status == :applied,
         true <-
           operation.case_id == evidence.case_id and operation.target_id == condition.target_id,
         true <- operation.target_revision == revision,
         {:ok, %{} = attempt} <-
           Cases.verification_attempt_by_operation(operation.id,
             authorize?: false,
             not_found_error?: false,
             query: [select: [:status, :target_id, :target_revision, :observed_at]]
           ),
         true <- attempt.status == :verified and attempt.target_id == condition.target_id,
         true <-
           attempt.target_revision == revision and attempt.observed_at == evidence.observed_at do
      {:ok, true}
    else
      {:error, _error} = error -> error
      _other -> {:ok, false}
    end
  end

  defp valid_operation_evidence(_evidence, _condition, _revision, _content), do: {:ok, false}

  defp invalid(message),
    do: {:error, Ash.Error.Changes.InvalidChanges.exception(message: message)}

  defp unavailable_source(%Ash.Error.Invalid{errors: [%type{}]})
       when type in [
              Ash.Error.Changes.InvalidChanges,
              Ash.Error.Changes.InvalidAttribute,
              Ash.Error.Query.NotFound,
              Ash.Error.Action.InvalidArgument
            ],
       do: {:ok, false}

  defp unavailable_source(%Ash.Error.Forbidden{errors: [%Ash.Error.Forbidden.Policy{}]}),
    do: {:ok, false}

  defp unavailable_source(error), do: {:error, error}
end
