defmodule Skopos.Cases.Evidence.Projection do
  @moduledoc false

  alias Skopos.Cases
  alias Skopos.Providers.AI

  def with_condition_evidence(case_id, conditions, cited_evidence, context_evidence) do
    available_ids = MapSet.new(cited_evidence ++ context_evidence, & &1.id)

    conditions
    |> Enum.flat_map(&(&1.recovery_evidence_ids ++ &1.failed_observation_ids))
    |> Enum.uniq()
    |> Enum.reject(&MapSet.member?(available_ids, &1))
    |> Enum.reduce_while({:ok, []}, fn id, {:ok, loaded} ->
      case Cases.get_evidence(id, authorize?: false) do
        {:ok, %{case_id: ^case_id} = item} ->
          {:cont, {:ok, [project_item(item) | loaded]}}

        {:error, %Ash.Error.Unknown{}} = error ->
          {:halt, error}

        {:error, %Ash.Error.Framework{}} = error ->
          {:halt, error}

        _unavailable ->
          {:halt, {:error, "Reviewer Condition Evidence is unavailable"}}
      end
    end)
    |> case do
      {:ok, required} -> {:ok, Enum.reverse(required) ++ context_evidence}
      error -> error
    end
  end

  def bound_review_context(request, chronology_ids \\ []) do
    required_ids =
      MapSet.new(
        chronology_ids ++
          Map.get(request, :recovery_evidence_ids, []) ++
          Enum.flat_map(
            request.conditions,
            &(&1.recovery_evidence_ids ++ &1.failed_observation_ids)
          )
      )

    {required, optional} =
      Enum.split_with(request.context_evidence, &MapSet.member?(required_ids, &1.id))

    base = %{request | context_evidence: required}
    required_size = AI.input_size(base)

    if required_size <= AI.max_input_bytes() do
      maximum = min(AI.max_input_bytes(), required_size + AI.optional_context_bytes())

      Enum.reduce(optional, base, fn item, current ->
        candidate = %{current | context_evidence: current.context_evidence ++ [item]}

        if AI.input_size(candidate) <= maximum and review_items(candidate) <= 100,
          do: candidate,
          else: current
      end)
    else
      base
    end
  end

  defp review_items(request) do
    length(request.conditions) + length(request.source_evidence) + length(request.cited_evidence) +
      length(request.context_evidence) + length(Map.get(request, :target_relations, []))
  end

  def recent(case_id, cited_ids) do
    with {:ok, evidence} <- Cases.review_context_evidence(case_id, authorize?: false) do
      {:ok, project(evidence, cited_ids)}
    end
  end

  def recent(case_id, target_id, cited_ids) do
    with {:ok, target_ids, chronology_ids} <- target_context_ids(case_id, target_id),
         {:ok, target_evidence} <- load_context(case_id, target_ids),
         {:ok, case_evidence} <- Cases.review_context_evidence(case_id, authorize?: false) do
      anchors =
        Enum.filter(target_evidence, &(&1.id in chronology_ids and &1.id not in cited_ids))

      optional = project(target_evidence ++ case_evidence, cited_ids ++ chronology_ids)
      {:ok, Enum.map(anchors, &project_item/1) ++ optional, chronology_ids}
    end
  end

  defp target_context_ids(case_id, target_id, after_key \\ nil, state \\ nil) do
    with {:ok, page} <-
           Cases.review_target_context_evidence(case_id, target_id,
             page: if(after_key, do: [limit: 100, after: after_key], else: [limit: 100]),
             authorize?: false
           ) do
      state =
        state ||
          %{
            recent: Enum.take(page.results, 32) |> Enum.map(& &1.id),
            effect: nil,
            before: nil,
            after: nil
          }

      state = Enum.reduce(page.results, state, &chronology_anchor/2)

      if page.more? and is_nil(state.before) do
        target_context_ids(case_id, target_id, List.last(page.results).__metadata__.keyset, state)
      else
        anchors = Enum.reject([state.before, state.effect, state.after], &is_nil/1)
        ids = Enum.map(anchors, & &1.id)
        {:ok, Enum.uniq(ids ++ state.recent), ids}
      end
    end
  end

  defp chronology_anchor(item, state) do
    status = item.summary["status"]

    cond do
      is_nil(state.effect) and item.kind == "operation_outcome" and status == "applied" ->
        later_failure =
          if state.after && DateTime.compare(state.after.observed_at, item.observed_at) == :gt,
            do: state.after

        %{state | effect: item, after: later_failure}

      is_nil(state.effect) and is_nil(state.after) and
        item.kind in ["observation", "target_verification"] and
          status in ["failed", "not_verified"] ->
        %{state | after: item}

      not is_nil(state.effect) and is_nil(state.before) and
        item.kind in ["observation", "target_verification"] and status in ["applied", "verified"] and
          DateTime.compare(item.observed_at, state.effect.observed_at) == :lt ->
        %{state | before: item}

      true ->
        state
    end
  end

  defp load_context(case_id, ids) do
    Enum.reduce_while(ids, {:ok, []}, fn id, {:ok, items} ->
      case Cases.get_evidence(id, authorize?: false) do
        {:ok, %{case_id: ^case_id} = item} -> {:cont, {:ok, items ++ [item]}}
        {:error, _error} = error -> {:halt, error}
        _unavailable -> {:halt, {:error, "Reviewer context Evidence is unavailable"}}
      end
    end)
  end

  defp project(evidence, cited_ids) do
    excluded = MapSet.new(cited_ids)

    evidence
    |> Enum.uniq_by(& &1.id)
    |> Enum.reject(&MapSet.member?(excluded, &1.id))
    |> Enum.uniq_by(&context_identity/1)
    |> Enum.take(32)
    |> Enum.sort_by(& &1.observed_at, {:desc, DateTime})
    |> Enum.map(&project_item/1)
  end

  defp project_item(item) do
    %AI.Evidence{
      id: item.id,
      kind: item.kind,
      target_id: item.content["target_id"],
      observed_at_us: DateTime.to_unix(item.observed_at, :microsecond),
      content: item.content
    }
  end

  def file_contents(incident, run, evidence) do
    evidence
    |> Enum.reduce_while({:ok, []}, fn item, {:ok, loaded} ->
      if item.kind == "file_read" and file_target_id(item) == incident.selected_target_id do
        case file_content(item, incident, run) do
          {:ok, content} -> {:cont, {:ok, [%{item | content: content} | loaded]}}
          {:error, _error} = error -> {:halt, error}
        end
      else
        {:cont, {:ok, [item | loaded]}}
      end
    end)
    |> case do
      {:ok, loaded} -> {:ok, Enum.reverse(loaded)}
      error -> error
    end
  end

  defp file_content(item, incident, run) do
    with {:ok, stored} <- Cases.get_evidence(item.id, authorize?: false),
         true <-
           stored.case_id == incident.id || {:error, "File-read Evidence belongs to another Case"} do
      if stored.resolution_run_id == run.id do
        Cases.read_file_content(item.id, incident.id, authorize?: false)
      else
        {:ok,
         stored.content
         |> Map.drop(["value", "encoding"])
         |> Map.put("original_status", stored.content["status"])
         |> Map.put("status", "historical")
         |> Map.put("resolution_run_id", stored.resolution_run_id)}
      end
    end
  end

  defp file_target_id(%AI.Evidence{target_id: id}), do: id
  defp file_target_id(%Cases.Evidence{content: content}), do: content["target_id"]

  defp context_identity(%{kind: "file_read", id: id}), do: {"file_read", id}

  defp context_identity(item) do
    {item.content["target_id"], item.content["operation"], item.kind, item.content["status"],
     item.content["selectors"], item.content["parameters"], item.content["facts"],
     item.content["reference"]}
  end
end
