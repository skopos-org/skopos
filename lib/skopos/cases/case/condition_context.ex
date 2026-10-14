defmodule Skopos.Cases.Case.ConditionContext do
  @moduledoc false

  alias Skopos.{Cases, Targets}
  alias Skopos.Cases.Case.ConditionRecovery, as: ConditionRecovery
  alias Skopos.Providers.AI
  alias Skopos.Targets.ResourceScope

  def current_conditions(%{trigger_kind: :signal} = incident) do
    with {:ok, memberships} <-
           Cases.active_conditions_for_case(incident.id, authorize?: false, load: [:condition]),
         true <-
           memberships != [] ||
             {:error,
              Ash.Error.Changes.InvalidChanges.exception(
                message: "Signal Case has no active Conditions"
              )} do
      conditions =
        Enum.map(memberships, fn %{condition: condition} ->
          %AI.Condition{
            id: condition.id,
            revision: condition.revision,
            occurrence: condition.occurrence,
            predicate: condition.predicate,
            subject_key: condition.subject_key,
            subject_ref: condition.subject_ref,
            state: condition.state,
            target_id: condition.target_id,
            current_occurred_at_us: DateTime.to_unix(condition.current_occurred_at, :microsecond)
          }
        end)

      {:ok, conditions}
    end
  end

  def current_conditions(_incident), do: {:ok, []}

  def current_condition_context(incident, exclude_operation_id \\ nil) do
    with {:ok, conditions} <- current_conditions(incident) do
      recovery_context(incident, conditions, exclude_operation_id)
    end
  end

  def condition_revisions(conditions) do
    conditions
    |> Enum.map(&%{"id" => &1.id, "revision" => &1.revision})
    |> Enum.sort_by(& &1["id"])
  end

  def current_condition_revisions(incident) do
    with {:ok, conditions} <- current_conditions(incident) do
      {:ok, condition_revisions(conditions)}
    end
  end

  defp recovery_context(%{trigger_kind: :signal} = incident, conditions, exclude_operation_id) do
    case ConditionRecovery.assess_current(incident, exclude_operation_id) do
      {:ok, assessments} ->
        by_id = Map.new(assessments, &{&1.condition_id, &1})

        conditions =
          Enum.map(conditions, fn condition ->
            assessment = Map.fetch!(by_id, condition.id)

            %{
              condition
              | recovery_status: assessment.status,
                recovery_evidence_ids: assessment.evidence_ids,
                failed_observation_ids: assessment.failed_observation_ids
            }
          end)

        proof_ids =
          if ConditionRecovery.ready_for_review?(assessments),
            do: assessments |> Enum.flat_map(& &1.evidence_ids) |> Enum.uniq(),
            else: []

        {:ok, {conditions, proof_ids}}

      {:error, %ConditionRecovery.EffectIncomplete{}} ->
        {:ok, {conditions, []}}

      {:error, _error} = error ->
        error
    end
  end

  defp recovery_context(_incident, conditions, _exclude_operation_id),
    do: {:ok, {conditions, []}}

  def projected_alert_state(%{trigger_kind: :signal}, conditions) do
    if conditions != [] and Enum.all?(conditions, &(&1.state == :recovered)),
      do: :recovered,
      else: :firing
  end

  def projected_alert_state(_incident, _conditions), do: :not_applicable

  # The completed Resolver Turn owns the Conditions considered when it made a
  # decision. An authorization based on that Turn must still see exactly those
  # Conditions. Callers taking a decision hold the Case admission lock.
  def current?(%{trigger_kind: :signal} = incident, source_turn_id) do
    with {:ok, turn} <- Cases.get_turn(source_turn_id, authorize?: false),
         {:ok, revisions} <- current_condition_revisions(incident) do
      {:ok,
       turn.case_id == incident.id and is_list(turn.result["condition_revisions"]) and
         revisions == turn.result["condition_revisions"]}
    end
  end

  def current?(_incident, _source_turn_id), do: {:ok, true}

  def affected_current?(
        incident,
        request_kind,
        claims,
        evidence_ids,
        action,
        exclude_operation_id \\ nil
      ) do
    with {:ok, {conditions, _recovery_ids}} <-
           current_condition_context(incident, exclude_operation_id) do
      condition_kind =
        if action_value(action, :purpose) in [:investigation, "investigation"],
          do: :observation,
          else: request_kind

      if AI.valid_affected_conditions?(condition_kind, claims, conditions, evidence_ids) do
        case current_effect_scope?(
               incident,
               condition_kind,
               claims,
               conditions,
               evidence_ids,
               action
             ) do
          {:error, _error} = error -> error
          current? -> {:ok, current?}
        end
      else
        {:ok, false}
      end
    end
  end

  defp current_effect_scope?(incident, :effect, claims, conditions, evidence_ids, action) do
    current = Map.new(conditions, &{&1.id, &1})
    target_id = action_value(action, :target_id)

    scope_matches?(claims, true, fn claim ->
      condition = Map.fetch!(current, claim["condition_id"])

      if condition.target_id == target_id do
        cond do
          map_size(claim) != 2 ->
            false

          condition.state != :recovered ->
            true

          true ->
            scope_matches?(evidence_ids, false, fn id ->
              if id in condition.recovery_evidence_ids,
                do: same_resource_scope?(id, action, incident.id),
                else: false
            end)
        end
      else
        related_effect_scope?(incident, condition, claim, evidence_ids, action)
      end
    end)
  end

  defp current_effect_scope?(
         _incident,
         _request_kind,
         _claims,
         _conditions,
         _evidence_ids,
         _action
       ),
       do: true

  defp related_effect_scope?(incident, condition, claim, evidence_ids, action) do
    target_id = action_value(action, :target_id)

    with true <- map_size(claim) == 4 and is_binary(condition.target_id),
         {:ok, %{} = relation} <-
           Targets.load_relationship_for_traversal(
             claim["relationship_id"],
             claim["relationship_revision"],
             authorize?: false,
             not_found_error?: false
           ),
         true <-
           Enum.sort([relation.source_target_id, relation.destination_target_id]) ==
             Enum.sort([condition.target_id, target_id]),
         {:ok, %{active: true, revision: condition_revision}} <-
           Targets.get_target(condition.target_id, authorize?: false, not_found_error?: false),
         true <-
           scope_matches?(evidence_ids, false, fn id ->
             symptom_observation?(
               id,
               incident,
               condition,
               condition_revision
             )
           end),
         true <-
           scope_matches?(evidence_ids, false, fn id ->
             effect_target_observation?(id, incident, condition, action)
           end) do
      true
    else
      {:error, _error} = error -> error
      _unavailable -> false
    end
  end

  defp effect_target_observation?(evidence_id, incident, condition, action) do
    with true <- same_resource_scope?(evidence_id, action, incident.id),
         {:ok, %{} = evidence} <-
           Cases.get_evidence(evidence_id, authorize?: false, not_found_error?: false) do
      DateTime.to_unix(evidence.observed_at, :microsecond) >=
        condition.current_occurred_at_us and
        DateTime.compare(evidence.observed_at, ConditionRecovery.inherited_baseline(incident)) !=
          :lt
    else
      {:error, _error} = error -> error
      _unavailable -> false
    end
  end

  defp symptom_observation?(evidence_id, incident, condition, target_revision) do
    with {:ok, %{} = evidence} <-
           Cases.get_evidence(evidence_id, authorize?: false, not_found_error?: false),
         true <-
           evidence.case_id == incident.id and evidence.kind == "observation" and
             evidence.source == "operation",
         true <- evidence.content["target_id"] == condition.target_id,
         true <-
           DateTime.to_unix(evidence.observed_at, :microsecond) >=
             condition.current_occurred_at_us,
         true <-
           DateTime.compare(evidence.observed_at, ConditionRecovery.inherited_baseline(incident)) !=
             :lt,
         {:ok, %{} = observation} <-
           Cases.get_operation(evidence.source_ref, authorize?: false, not_found_error?: false),
         true <-
           observation.case_id == incident.id and
             observation.purpose == :investigation and
             observation.target_id == condition.target_id and
             observation.target_revision == target_revision and
             observation.status in [:applied, :failed] and
             evidence.content["status"] == to_string(observation.status),
         true <-
           condition.state != :recovered or
             (observation.status == :applied and
                evidence_id in condition.recovery_evidence_ids) or
             (observation.status == :failed and
                evidence_id in condition.failed_observation_ids) do
      true
    else
      {:error, _error} = error -> error
      _unavailable -> false
    end
  end

  defp same_resource_scope?(evidence_id, action, case_id) do
    with {:ok, %{} = evidence} <-
           Cases.get_evidence(evidence_id, authorize?: false, not_found_error?: false),
         true <-
           evidence.case_id == case_id and evidence.kind == "observation" and
             evidence.source == "operation",
         {:ok, %{} = observation} <-
           Cases.get_operation(evidence.source_ref, authorize?: false, not_found_error?: false),
         true <- observation.purpose == :investigation and observation.status == :applied,
         true <- observation.case_id == case_id,
         true <- observation.target_id == action_value(action, :target_id),
         true <- observation.target_revision == action_value(action, :target_revision),
         true <-
           evidence.content["status"] == "applied",
         {:ok, %{} = action_method} <-
           Skopos.Targets.get_access_method(action_value(action, :access_method_id),
             authorize?: false,
             not_found_error?: false
           ),
         {:ok, %{} = observation_method} <-
           Skopos.Targets.get_access_method(observation.access_method_id,
             authorize?: false,
             not_found_error?: false
           ) do
      ResourceScope.key(
        action_method,
        action_value(action, :capability),
        action_value(action, :operation),
        action_value(action, :selectors)
      ) ==
        ResourceScope.key(
          observation_method,
          observation.capability,
          observation.operation,
          observation.selectors
        )
    else
      {:error, _error} = error -> error
      _other -> false
    end
  end

  defp scope_matches?(items, initial, predicate) do
    Enum.reduce_while(items, initial, fn item, _result ->
      case predicate.(item) do
        {:error, _error} = error -> {:halt, error}
        ^initial -> {:cont, initial}
        result when is_boolean(result) -> {:halt, result}
      end
    end)
  end

  defp action_value(action, key), do: Map.get(action, key) || Map.get(action, Atom.to_string(key))
end
