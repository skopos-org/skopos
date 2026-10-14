defmodule Skopos.Cases.Case.Actions.TargetSelection do
  use Ash.Resource.Actions.Implementation

  require Ash.Query

  alias Skopos.{Cases, Signals, Targets}
  alias Skopos.Cases.{Case, CaseEvent, Evidence, ResolutionRun}
  alias Skopos.Cases.ResolutionRun.Budget, as: Budget
  alias Skopos.Cases.Evidence.Citation, as: EvidenceCitation

  defmodule CandidateNotOffered do
    @moduledoc false
    use Splode.Error, class: :invalid, fields: []

    @impl true
    def message(_error), do: "Target was not offered by the cited candidate evidence"
  end

  @impl true
  def run(input, _opts, context) do
    arguments = input.arguments
    key = Budget.key("case:target_selection", arguments.idempotency_key)

    Ash.transact([Case, ResolutionRun, Evidence, CaseEvent], fn ->
      with {:ok, incident} <- lock_case(arguments.id),
           {:ok, event} <- existing_event(incident.id, key) do
        if event do
          replay(incident, event, arguments)
        else
          select(incident, arguments, context.actor, key)
        end
      end
    end)
  end

  defp select(incident, arguments, actor, key) do
    with :ok <- expected_revision(incident, arguments.expected_revision),
         :ok <- ensure_running(incident),
         {:ok, run} <- lock_run(arguments.resolution_run_id, incident.id),
         :ok <- unique_evidence(arguments.evidence_ids),
         {:ok, evidence} <- load_evidence(arguments.evidence_ids),
         :ok <- valid_evidence(evidence, incident, run),
         :ok <- offered_candidate(evidence, arguments.target_id, arguments.target_revision),
         {:ok, target} <- Targets.get_target(arguments.target_id, authorize?: false),
         :ok <- current_target(target, arguments.target_revision) do
      if incident.selected_target_id == target.id and
           incident.selected_target_revision == target.revision do
        with {:ok, _event} <-
               create_event(
                 incident,
                 incident,
                 run,
                 actor,
                 key,
                 arguments,
                 "case_target_selection_unchanged"
               ) do
          incident
        end
      else
        with {:ok, updated} <-
               Cases.record_case_selected_target(
                 incident,
                 arguments.expected_revision,
                 target.id,
                 target.revision,
                 authorize?: false
               ),
             {:ok, _event} <-
               create_event(
                 updated,
                 incident,
                 run,
                 actor,
                 key,
                 arguments,
                 "case_target_selected"
               ) do
          updated
        end
      end
    end
  end

  defp replay(incident, event, arguments) do
    expected = event_data(arguments)

    if Map.take(event.data, Map.keys(expected)) == expected do
      incident
    else
      invalid_input(
        "Target-selection idempotency key was already used with different input",
        :idempotency_key
      )
    end
  end

  defp lock_case(id) do
    Case
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(id: id)
    |> Ash.Query.lock(:for_update)
    |> Ash.read_one(authorize?: false)
    |> required("Case is unavailable")
  end

  defp lock_run(id, case_id) do
    ResolutionRun
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(id: id, case_id: case_id, active: true, status: :running)
    |> Ash.Query.lock(:for_update)
    |> Ash.read_one(authorize?: false)
    |> required("Running ResolutionRun is unavailable")
  end

  defp required({:ok, nil}, message), do: invalid_input(message)
  defp required(result, _message), do: result

  defp existing_event(case_id, key) do
    Cases.case_event_by_idempotency(case_id, key,
      authorize?: false,
      not_found_error?: false
    )
  end

  defp expected_revision(%{revision: revision}, revision), do: :ok

  defp expected_revision(_incident, _revision),
    do: invalid_input("Case revision changed", :expected_revision)

  defp ensure_running(%{cancel_requested: false, status: :running}), do: :ok

  defp ensure_running(%{cancel_requested: true}),
    do: invalid_input("Case cancellation was requested")

  defp ensure_running(_incident), do: invalid_input("Case resolution is not running")

  defp unique_evidence(ids) do
    if length(ids) == MapSet.size(MapSet.new(ids)),
      do: :ok,
      else: invalid_input("Target selection evidence contains duplicates", :evidence_ids)
  end

  defp load_evidence(ids) do
    Enum.reduce_while(ids, {:ok, []}, fn id, {:ok, items} ->
      case Cases.get_evidence(id, authorize?: false, not_found_error?: false) do
        {:ok, %Evidence{} = evidence} ->
          {:cont, {:ok, [evidence | items]}}

        {:error, _error} = error ->
          {:halt, error}

        {:ok, nil} ->
          {:halt, invalid_input("Target selection evidence is unavailable", :evidence_ids)}
      end
    end)
  end

  defp valid_evidence(evidence, incident, run) do
    Enum.reduce_while(evidence, :ok, fn item, :ok ->
      case EvidenceCitation.validate(item, incident, run) do
        :ok -> {:cont, :ok}
        {:error, _error} = error -> {:halt, error}
      end
    end)
  end

  defp offered_candidate(evidence, target_id, target_revision) do
    Enum.reduce_while(evidence, {:error, CandidateNotOffered.exception([])}, fn item, rejected ->
      case candidate?(item, target_id, target_revision) do
        {:ok, true} -> {:halt, :ok}
        {:ok, false} -> {:cont, rejected}
        {:error, _error} = error -> {:halt, error}
      end
    end)
  end

  defp candidate?(
         %{
           kind: "target_candidates",
           source: "target_catalog",
           content: %{"targets" => candidates}
         },
         target_id,
         target_revision
       )
       when is_list(candidates) do
    {:ok, Enum.any?(candidates, &(&1["id"] == target_id and &1["revision"] == target_revision))}
  end

  defp candidate?(
         %{
           kind: "signal_event",
           content: %{
             "current" => true,
             "condition_id" => condition_id,
             "condition_revision" => condition_revision
           }
         },
         target_id,
         _target_revision
       ) do
    case Signals.get_condition(condition_id, authorize?: false, not_found_error?: false) do
      {:ok, nil} ->
        {:ok, false}

      {:ok, condition} ->
        {:ok, condition.revision == condition_revision and condition.target_id == target_id}

      {:error, _error} = error ->
        error
    end
  end

  defp candidate?(_other, _target_id, _target_revision), do: {:ok, false}

  defp current_target(%{active: true, revision: revision}, revision), do: :ok

  defp current_target(%{active: false}, _revision),
    do: invalid_input("Selected Target is inactive", :target_id)

  defp current_target(_target, _revision),
    do: invalid_input("Selected Target revision changed", :target_revision)

  defp invalid_input(message, field \\ :id),
    do: {:error, Ash.Error.Action.InvalidArgument.exception(field: field, message: message)}

  defp create_event(incident, prior, run, actor, key, arguments, event_type) do
    Cases.create_case_event_record(
      %{
        case_id: incident.id,
        resolution_run_id: run.id,
        actor_id: actor && actor.id,
        event_type: event_type,
        idempotency_key: key,
        data:
          event_data(arguments)
          |> Map.put("prior_target_id", prior.selected_target_id)
          |> Map.put("prior_target_revision", prior.selected_target_revision)
      },
      authorize?: false
    )
  end

  defp event_data(arguments) do
    %{
      "evidence_ids" => arguments.evidence_ids,
      "target_id" => arguments.target_id,
      "target_revision" => arguments.target_revision,
      "reason" => arguments.reason
    }
  end
end
