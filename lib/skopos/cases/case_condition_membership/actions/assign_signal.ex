defmodule Skopos.Cases.CaseConditionMembership.Actions.AssignSignal do
  use Ash.Resource.Actions.Implementation

  alias Skopos.{Cases, Signals, Targets}

  alias Skopos.Cases.{Case, CaseConditionMembership, CaseDispatch, ResolutionRun}
  alias Skopos.Cases.Case.AdmissionLock, as: CaseAdmissionLock

  @max_conditions 32
  @max_graph_nodes 128

  @impl true
  def run(input, _opts, _context) do
    args = input.arguments

    result =
      Ash.transact([Case, ResolutionRun, CaseConditionMembership, CaseDispatch], fn ->
        # A short global admission lock makes first-event Case creation deterministic
        # across application instances. No remote I/O happens while it is held.
        with :ok <- CaseAdmissionLock.acquire(),
             {:ok, condition} <- Signals.get_condition(args.condition_id, authorize?: false),
             true <- condition.state == :firing || {:error, "Condition is not firing"},
             {:ok, existing} <-
               Cases.active_case_condition(condition.id,
                 authorize?: false,
                 not_found_error?: false
               ) do
          case existing do
            %CaseConditionMembership{} = membership ->
              with {:ok, incident} <- Cases.get_case(membership.case_id, authorize?: false) do
                {:ok, %{case: incident, membership: membership}}
              end

            nil ->
              attach_new(condition, args)
          end
        end
      end)

    case result do
      {:ok, {:ok, assigned}} -> {:ok, assigned}
      {:ok, {:error, _error} = failed} -> failed
      other -> other
    end
  end

  defp attach_new(condition, args) do
    with {:ok, candidate} <- candidate(condition, args.received_at),
         {:ok, incident, new?} <- case_for_candidate(candidate, condition, args),
         {:ok, membership} <-
           Cases.attach_case_condition_record(
             %{
               case_id: incident.id,
               condition_id: condition.id,
               attached_at: args.received_at,
               reason: attachment_reason(candidate, new?)
             },
             authorize?: false
           ) do
      {:ok, %{case: incident, membership: membership}}
    end
  end

  defp case_for_candidate({incident, _dispatch}, _condition, _args),
    do: {:ok, incident, false}

  defp case_for_candidate(nil, condition, args) do
    with {:ok, incident} <-
           Cases.open_case(
             :signal,
             args.source,
             condition.id,
             args.title,
             args.severity,
             Map.put(args.initial_context, "initial_condition_id", condition.id),
             condition.target_id,
             nil,
             authorize?: false
           ),
         {:ok, _dispatch} <- create_dispatch(incident, condition, args.received_at) do
      {:ok, incident, true}
    end
  end

  defp attachment_reason(_candidate, true), do: "initial_signal"
  defp attachment_reason({_incident, :recurrence}, false), do: "same_native_recurrence"
  defp attachment_reason({_incident, :same_subject}, false), do: "same_affected_subject"
  defp attachment_reason(_candidate, false), do: "bounded_graph_time_locality"

  defp create_dispatch(incident, condition, received_at) do
    due_at =
      DateTime.add(received_at, Application.fetch_env!(:skopos, :case_collect_seconds), :second)

    state = if incident.status == :running, do: :collecting, else: :disabled

    with {:ok, dispatch} <-
           Cases.create_case_dispatch_record(
             %{
               case_id: incident.id,
               state: state,
               first_received_at: received_at,
               due_at: due_at,
               anchor_target_id: condition.target_id
             },
             authorize?: false
           ) do
      if state == :collecting do
        with {:ok, job} <-
               %{"case_id" => incident.id}
               |> Skopos.Cases.CaseDispatch.Worker.new(scheduled_at: due_at)
               |> Oban.insert(),
             true <-
               is_integer(job.id) || {:error, "Initial Signal dispatch job was not persisted"} do
          {:ok, dispatch}
        end
      else
        {:ok, dispatch}
      end
    end
  end

  defp candidate(condition, received_at) do
    with {:ok, recurrence} <- recurrence_candidate(condition) do
      if recurrence do
        {:ok, {recurrence, :recurrence}}
      else
        with {:ok, subject} <- subject_candidate(condition) do
          if subject,
            do: {:ok, {subject, :same_subject}},
            else: graph_candidate(condition, received_at)
        end
      end
    end
  end

  defp subject_candidate(%{target_id: nil}), do: {:ok, nil}
  defp subject_candidate(%{subject_ref: subject}) when map_size(subject) == 0, do: {:ok, nil}

  defp subject_candidate(condition) do
    with {:ok, matches} <-
           Signals.same_subject_conditions(condition.subject_key, condition.predicate,
             authorize?: false
           ),
         true <- length(matches) < 64 || {:ok, nil} do
      matches
      |> Enum.reject(&(&1.id == condition.id))
      |> Enum.filter(
        &(&1.target_id == condition.target_id and &1.subject_ref == condition.subject_ref)
      )
      |> Enum.reduce_while({:ok, MapSet.new()}, fn match, {:ok, case_ids} ->
        case Cases.active_case_condition(match.id,
               authorize?: false,
               not_found_error?: false
             ) do
          {:ok, %CaseConditionMembership{case_id: id}} ->
            {:cont, {:ok, MapSet.put(case_ids, id)}}

          {:ok, nil} ->
            {:cont, {:ok, case_ids}}

          {:error, _error} = error ->
            {:halt, error}
        end
      end)
      |> case do
        {:ok, case_ids} ->
          case MapSet.to_list(case_ids) do
            [case_id] -> active_subject_case(case_id)
            _other -> {:ok, nil}
          end

        {:error, _error} = error ->
          error
      end
    else
      {:ok, nil} -> {:ok, nil}
      {:error, _error} = error -> error
    end
  end

  defp active_subject_case(case_id) do
    with {:ok, incident} <- Cases.get_case(case_id, authorize?: false),
         true <- admits_new_condition?(incident),
         true <- incident.trigger_kind == :signal,
         {:ok, members} <- Cases.active_conditions_for_case(incident.id, authorize?: false),
         true <- length(members) < @max_conditions do
      {:ok, incident}
    else
      false -> {:ok, nil}
      {:error, _error} = error -> error
    end
  end

  defp recurrence_candidate(%{occurrence: 1}), do: {:ok, nil}

  defp recurrence_candidate(condition) do
    with {:ok, previous} <-
           Signals.previous_condition_for_identity(
             condition.signal_correlation_id,
             condition.occurrence,
             condition.subject_key,
             condition.predicate,
             authorize?: false,
             not_found_error?: false
           ),
         true <- same_subject?(previous, condition),
         {:ok, membership} <-
           Cases.active_case_condition(previous.id,
             authorize?: false,
             not_found_error?: false
           ),
         %CaseConditionMembership{} <- membership,
         {:ok, incident} <- Cases.get_case(membership.case_id, authorize?: false),
         true <- admits_new_condition?(incident) and incident.trigger_kind == :signal,
         {:ok, members} <- Cases.active_conditions_for_case(incident.id, authorize?: false),
         true <- length(members) < @max_conditions do
      {:ok, incident}
    else
      false -> {:ok, nil}
      nil -> {:ok, nil}
      {:ok, nil} -> {:ok, nil}
      {:error, _error} = error -> error
      _other -> {:ok, nil}
    end
  end

  defp same_subject?(nil, _condition), do: false

  defp same_subject?(previous, condition) do
    previous.subject_key == condition.subject_key and
      previous.subject_ref == condition.subject_ref and
      previous.predicate == condition.predicate and
      previous.target_id == condition.target_id
  end

  defp graph_candidate(%{target_id: nil}, _received_at), do: {:ok, nil}

  defp graph_candidate(condition, received_at) do
    with {:ok, target} <- Targets.get_target(condition.target_id, authorize?: false),
         {:ok, local_ids} <- within_two(condition.target_id),
         {:ok, dispatches} <- Cases.admitting_case_dispatches(authorize?: false) do
      dispatches
      |> Enum.find_value(fn dispatch ->
        # Concurrent requests can acquire the admission lock out of receipt order.
        # Keep an earlier receipt only when it is still local to the fixed window.
        earliest =
          DateTime.add(
            dispatch.first_received_at,
            -Application.fetch_env!(:skopos, :case_collect_seconds),
            :second
          )

        with true <- DateTime.compare(received_at, earliest) != :lt,
             true <- DateTime.compare(received_at, dispatch.due_at) == :lt,
             true <- dispatch.anchor_target_id in local_ids,
             {:ok, anchor} <- Targets.get_target(dispatch.anchor_target_id, authorize?: false),
             true <- anchor.management_boundary_id == target.management_boundary_id,
             {:ok, incident} <- Cases.get_case(dispatch.case_id, authorize?: false),
             true <- incident.trigger_kind == :signal,
             true <- admits_new_condition?(incident),
             {:ok, members} <-
               Cases.active_conditions_for_case(incident.id, authorize?: false),
             true <- length(members) < @max_conditions,
             {:ok, conditions} <- member_conditions(members),
             true <- Enum.all?(conditions, &(&1.target_id in local_ids)) do
          {incident, dispatch}
        else
          _other -> nil
        end
      end)
      |> then(&{:ok, &1})
    else
      {:error, :graph_too_large} -> {:ok, nil}
      {:error, _error} = error -> error
    end
  end

  defp admits_new_condition?(%{status: :running}), do: true

  defp admits_new_condition?(%{
         status: :needs_attention,
         pending_intent: %{"action" => "start_resolution"}
       }),
       do: true

  defp admits_new_condition?(_incident), do: false

  defp member_conditions(members) do
    members
    |> Enum.reduce_while({:ok, []}, fn member, {:ok, conditions} ->
      case Signals.get_condition(member.condition_id, authorize?: false) do
        {:ok, condition} -> {:cont, {:ok, [condition | conditions]}}
        {:error, _error} = error -> {:halt, error}
      end
    end)
  end

  defp within_two(target_id) do
    with {:ok, first_edges} <-
           Targets.adjacent_relationships_for_case_admission(target_id, authorize?: false),
         true <- length(first_edges) <= @max_graph_nodes || {:error, :graph_too_large},
         first <- first_edges |> Enum.map(&other_id(&1, target_id)) |> Enum.uniq(),
         true <- length(first) <= @max_graph_nodes || {:error, :graph_too_large} do
      first
      |> Enum.reduce_while({:ok, MapSet.new([target_id | first])}, fn id, {:ok, found} ->
        case Targets.adjacent_relationships_for_case_admission(id, authorize?: false) do
          {:ok, edges} ->
            next = Enum.map(edges, &other_id(&1, id))
            found = Enum.reduce(next, found, &MapSet.put(&2, &1))

            if length(edges) <= @max_graph_nodes and MapSet.size(found) <= @max_graph_nodes,
              do: {:cont, {:ok, found}},
              else: {:halt, {:error, :graph_too_large}}

          {:error, _error} = error ->
            {:halt, error}
        end
      end)
    end
  end

  defp other_id(edge, id) do
    if edge.source_target_id == id, do: edge.destination_target_id, else: edge.source_target_id
  end
end
