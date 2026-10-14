defmodule Skopos.Cases.Evidence.Citation do
  @moduledoc false

  alias Skopos.Cases
  alias Skopos.Cases.Case.ConditionRecovery, as: ConditionRecovery

  def validate(
        %{
          case_id: case_id,
          kind: "signal_event",
          content: %{"current" => true}
        } = evidence,
        %{id: case_id},
        _run
      ) do
    latest_source_evidence(evidence, case_id)
  end

  def validate(%{kind: "signal_event"}, _incident, _run), do: unavailable()

  def validate(%{case_id: case_id, resolution_run_id: run_id}, %{id: case_id}, %{id: run_id}),
    do: :ok

  def validate(
        %{id: evidence_id, case_id: case_id, kind: "observation"},
        %{id: case_id, trigger_kind: :signal} = incident,
        _run
      ) do
    case ConditionRecovery.assess_current(incident) do
      {:ok, assessments} ->
        if Enum.any?(assessments, fn assessment ->
             assessment.status == :ready_for_review and evidence_id in assessment.evidence_ids
           end),
           do: :ok,
           else: unavailable()

      {:error, _error} = error ->
        error
    end
  end

  def validate(
        %{
          case_id: case_id,
          kind: "target_verification",
          source: "verification",
          content: %{
            "status" => "verified",
            "operation_id" => operation_id,
            "target_id" => target_id
          }
        } = evidence,
        %{
          id: case_id,
          selected_target_id: target_id,
          selected_target_revision: target_revision
        },
        _run
      ) do
    with :ok <- latest_target_evidence(evidence, case_id, target_id),
         :ok <- verified_operation(operation_id, case_id, target_id, target_revision),
         do: :ok
  end

  def validate(_evidence, _incident, _run), do: unavailable()

  defp latest_source_evidence(evidence, case_id) do
    case Cases.signal_context_evidence(case_id, authorize?: false) do
      {:ok, candidates} ->
        if Enum.any?(candidates, &(&1.id == evidence.id)), do: :ok, else: unavailable()

      {:error, _error} = error ->
        error
    end
  end

  defp latest_target_evidence(evidence, case_id, target_id) do
    case Cases.target_continuity_evidence(case_id, authorize?: false) do
      {:ok, candidates} ->
        case Enum.find(candidates, &(&1.content["target_id"] == target_id)) do
          %{id: id} when id == evidence.id -> :ok
          _unavailable -> unavailable()
        end

      {:error, _error} = error ->
        error
    end
  end

  defp verified_operation(operation_id, case_id, target_id, target_revision) do
    case Cases.get_operation(operation_id, authorize?: false) do
      {:ok,
       %{
         case_id: ^case_id,
         target_id: ^target_id,
         target_revision: ^target_revision,
         status: :applied
       }} ->
        :ok

      {:ok, _unavailable} ->
        unavailable()

      {:error, _error} = error ->
        error
    end
  end

  defp unavailable,
    do:
      {:error,
       Ash.Error.Changes.InvalidChanges.exception(
         message: "Cited evidence is unavailable for this case"
       )}
end
