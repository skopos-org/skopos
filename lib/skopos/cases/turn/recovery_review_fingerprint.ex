defmodule Skopos.Cases.Turn.RecoveryReviewFingerprint do
  @moduledoc false

  alias Skopos.Cases
  alias Skopos.Cases.AIInvocation
  alias Skopos.Cases.Case.Symptom, as: CaseSymptom

  def current(incident, intent) do
    cited_ids = intent["evidence_ids"]

    with {:ok, source} <- source_evidence(incident) do
      {:ok,
       digest(
         cited_ids,
         intent["condition_claims"],
         intent["desired_outcome_claims"],
         CaseSymptom.current(incident),
         source
       )}
    end
  end

  def reviewed(request) do
    digest(
      request.conclusion.evidence_ids,
      request.conclusion.condition_claims,
      request.conclusion.desired_outcome_claims,
      request.case_symptom,
      request.source_evidence
    )
  end

  defp source_evidence(%{trigger_kind: :signal} = incident),
    do: Cases.signal_context_evidence(incident.id, authorize?: false)

  defp source_evidence(_incident), do: {:ok, []}

  defp digest(cited_ids, claims, symptom_claims, case_symptom, source) do
    AIInvocation.request_digest(%{
      cited_ids: Enum.sort(cited_ids),
      claims:
        claims
        |> Enum.map(&Map.take(&1, ["condition_id", "revision", "evidence_id"]))
        |> Enum.sort_by(& &1["condition_id"]),
      case_symptom_id: case_symptom && case_symptom.id,
      desired_outcome_claims: Enum.sort_by(symptom_claims, &{&1["evidence_id"], &1["fact_keys"]}),
      source_ids: source |> Enum.map(& &1.id) |> Enum.sort()
    })
  end
end
