defmodule Skopos.Cases.Turn.RecoveryReviewProjection do
  @moduledoc false

  alias Skopos.Cases
  alias Skopos.Cases.Case.Symptom, as: CaseSymptom
  alias Skopos.Cases.Case.ConditionContext, as: ConditionContext
  alias Skopos.Cases.Case.InvocationContext
  alias Skopos.Cases.Case.ConditionRecovery, as: ConditionRecovery
  alias Skopos.Cases.Evidence.Projection, as: EvidenceProjection
  alias Skopos.Providers.AI

  def build(turn_id, selection, retry_context \\ nil)

  def build(turn_id, %AI.Selection{role: :reviewer} = selection, retry_context) do
    with {:ok, turn} <- Cases.get_turn(turn_id, authorize?: false),
         {:ok, incident} <- Cases.get_case(turn.case_id, authorize?: false),
         {:ok, run} <- Cases.get_resolution_run(turn.resolution_run_id, authorize?: false),
         :ok <- eligible(turn, incident, run),
         {:ok, {conditions, _recovery_ids}} <-
           ConditionContext.current_condition_context(incident),
         {:ok, source_evidence} <- source_evidence(incident),
         {:ok, cited_evidence} <- cited_evidence(turn, incident),
         {:ok, cited_evidence} <- EvidenceProjection.file_contents(incident, run, cited_evidence),
         {:ok, context_evidence} <-
           EvidenceProjection.recent(incident.id, Enum.map(cited_evidence, & &1.id)),
         {:ok, context_evidence} <-
           EvidenceProjection.with_condition_evidence(
             incident.id,
             conditions,
             cited_evidence,
             context_evidence
           ),
         {:ok, context_evidence} <-
           EvidenceProjection.file_contents(incident, run, context_evidence) do
      intent = turn.result["intent"]

      request =
        %AI.RecoveryReviewRequest{
          provider_revision: selection.provider_revision,
          session_id: "recovery-reviewer:#{turn.id}",
          resolver_session_id: "resolver:#{run.id}",
          case_id: incident.id,
          objective: objective(incident),
          report_language: incident.report_language,
          conditions: conditions,
          case_symptom: CaseSymptom.current(incident),
          source_evidence: source_evidence,
          cited_evidence: cited_evidence,
          context_evidence: context_evidence,
          conclusion: %AI.RecoveryConclusion{
            reason: intent["reason"],
            evidence_ids: intent["evidence_ids"],
            condition_claims: Map.get(intent, "condition_claims", []),
            desired_outcome_claims: Map.get(intent, "desired_outcome_claims", [])
          },
          retry_context: retry_context,
          budget: budget(run)
        }
        |> EvidenceProjection.bound_review_context()

      case AI.Validator.validate_request(:review_recovery, request) do
        :ok ->
          context =
            InvocationContext.project(
              incident,
              run,
              {:turn, turn.id, turn.revision, turn.status},
              conditions,
              selection,
              []
            )

          {:ok, request, context}

        {:error, _error} = error ->
          error
      end
    end
  end

  def build(_turn_id, _selection, _retry_context),
    do: {:error, "Recovery Reviewer AI selection is invalid"}

  defp eligible(turn, incident, run) do
    with true <-
           (turn.status == :completed and turn.result["outcome"] == "decision" and
              get_in(turn.result, ["intent", "type"]) == "recovery_conclusion") ||
             {:error, "Turn has no RecoveryConclusion"},
         true <-
           (incident.status == :running and not incident.cancel_requested and run.active and
              run.status == :running and run.case_id == incident.id) ||
             {:error, "Recovery Review context is not running"},
         true <-
           incident.pending_intent == %{"action" => "review_recovery", "turn_id" => turn.id} ||
             {:error, "Case is not awaiting this Recovery Review"},
         {:ok, true} <- ConditionContext.current?(incident, turn.id),
         :ok <- conditions_ready(incident) do
      :ok
    else
      {:ok, false} -> {:error, "Recovery Review Condition context changed"}
      {:error, _error} = error -> error
    end
  end

  defp conditions_ready(%{trigger_kind: :signal} = incident) do
    with {:ok, assessments} <- ConditionRecovery.assess_current(incident),
         true <-
           ConditionRecovery.ready_for_review?(assessments) ||
             {:error, "Conditions no longer have current review evidence"} do
      :ok
    end
  end

  defp conditions_ready(_incident), do: :ok

  defp source_evidence(%{trigger_kind: :signal} = incident) do
    with {:ok, items} <- Cases.signal_context_evidence(incident.id, authorize?: false) do
      {:ok, Enum.map(items, &project_evidence/1)}
    end
  end

  defp source_evidence(_incident), do: {:ok, []}

  defp objective(incident) do
    case Jason.encode(%{"title" => incident.title, "initial_context" => incident.initial_context}) do
      {:ok, encoded} -> String.slice(encoded, 0, 8_000)
      {:error, _error} -> incident.title
    end
  end

  defp cited_evidence(turn, incident) do
    turn.result["intent"]["evidence_ids"]
    |> Enum.reduce_while({:ok, []}, fn id, {:ok, items} ->
      case Cases.get_evidence(id, authorize?: false) do
        {:ok, %{case_id: case_id} = item} when case_id == incident.id ->
          {:cont, {:ok, [project_evidence(item) | items]}}

        {:error, %Ash.Error.Unknown{}} = error ->
          {:halt, error}

        {:error, %Ash.Error.Framework{}} = error ->
          {:halt, error}

        _unavailable ->
          {:halt, {:error, "Recovery Review cited Evidence is unavailable"}}
      end
    end)
    |> case do
      {:ok, items} -> {:ok, Enum.reverse(items)}
      error -> error
    end
  end

  defp project_evidence(item) do
    %AI.Evidence{
      id: item.id,
      kind: item.kind,
      target_id: item.content["target_id"],
      observed_at_us: DateTime.to_unix(item.observed_at, :microsecond),
      content: item.content
    }
  end

  defp budget(run) do
    %AI.Budget{
      remaining_turns: max(run.max_resolver_turns - run.turn_count, 0),
      remaining_tokens: max(run.max_ai_usage_units - run.ai_usage_units, 0),
      remaining_target_requests: max(run.max_target_requests - run.target_request_count, 0),
      remaining_effects: max(run.max_effects - run.effect_count, 0),
      remaining_related_targets: max(run.max_related_targets - run.related_target_count, 0)
    }
  end
end
