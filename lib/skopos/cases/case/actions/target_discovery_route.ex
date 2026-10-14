defmodule Skopos.Cases.Case.Actions.TargetDiscoveryRoute do
  use Ash.Resource.Actions.Implementation

  alias Skopos.Cases
  alias Skopos.Cases.{Case, CaseEvent, Evidence, ResolutionRun, Turn}
  alias Skopos.Cases.ResolutionRun.Budget, as: Budget

  @impl true
  def run(input, _opts, _context) do
    Ash.transact([Case, ResolutionRun, Turn, Evidence, CaseEvent], fn ->
      with {:ok, turn} <- Cases.get_turn(input.arguments.turn_id, authorize?: false),
           :ok <- completed_decision(turn),
           {:ok, incident} <- Cases.get_case(turn.case_id, authorize?: false),
           {:ok, run} <- Cases.get_resolution_run(turn.resolution_run_id, authorize?: false) do
        route(turn, incident, run, turn.result["intent"])
      end
    end)
  end

  defp route(
         turn,
         incident,
         run,
         %{"type" => "target_search", "query" => query, "reason" => reason}
       )
       when is_binary(query) and is_binary(reason) do
    pending = %{"action" => "route_target_search", "source_turn_id" => turn.id}

    with {:ok, searched} <-
           Cases.search_case_targets(
             incident.id,
             run.id,
             route_key(turn, "target-search"),
             query,
             20,
             pending,
             "Review Target discovery or increase its limit",
             authorize?: false
           ) do
      continue_after_search(turn, reason, searched) |> action_value()
    end
  end

  defp route(
         turn,
         incident,
         run,
         %{
           "type" => "target_selection",
           "target_id" => target_id,
           "target_revision" => target_revision,
           "evidence_ids" => evidence_ids,
           "reason" => reason
         }
       )
       when is_binary(target_id) and is_integer(target_revision) and is_list(evidence_ids) and
              is_binary(reason) do
    with {:ok, selected} <-
           Cases.select_case_target(
             incident.id,
             incident.revision,
             run.id,
             evidence_ids,
             target_id,
             target_revision,
             reason,
             route_key(turn, "target-selection"),
             authorize?: false
           ),
         {:ok, selection_event} <-
           Cases.case_event_by_idempotency(
             incident.id,
             Budget.key("case:target_selection", route_key(turn, "target-selection")),
             authorize?: false
           ) do
      context =
        if selection_event.event_type == "case_target_selection_unchanged" do
          %{
            "source" => "target_selection_unchanged",
            "selected_target_id" => target_id,
            "reason" => reason,
            "objective" =>
              "The Target is already selected; choose another available action or hand off"
          }
        else
          %{
            "source" => "target_selection",
            "selected_target_id" => target_id,
            "reason" => reason
          }
        end

      start_next_turn(turn, selected, run, context)
      |> action_value()
    end
  end

  defp route(_turn, _incident, _run, _intent),
    do: invalid("Completed Turn does not contain a Target discovery decision")

  defp continue_after_search(_turn, _reason, %{status: :exhausted} = result), do: {:ok, result}

  defp continue_after_search(turn, reason, searched) do
    start_next_turn(turn, searched.case, searched.run, %{
      "source" => "target_search",
      "evidence_id" => searched.value.id,
      "reason" => reason
    })
  end

  defp start_next_turn(turn, incident, run, context) do
    with {:ok, result} <-
           Cases.start_turn(
             incident.id,
             run.id,
             route_key(turn, "next-turn"),
             Map.put_new(
               context,
               "objective",
               "Continue resolution with the accepted Target discovery"
             ),
             %{"action" => "continue_resolution", "source_turn_id" => turn.id},
             "Review Resolver limits or continue the Case manually",
             authorize?: false
           ) do
      set_pending_turn(result, turn.id)
    end
  end

  defp set_pending_turn(%{status: :exhausted} = result, _source_turn_id),
    do: {:ok, result}

  defp set_pending_turn(
         %{status: status, case: incident, value: next_turn} = result,
         source_turn_id
       )
       when status in [:charged, :duplicate] do
    pending = %{
      "action" => "resolve_turn",
      "turn_id" => next_turn.id,
      "source_turn_id" => source_turn_id
    }

    if incident.pending_intent == pending do
      {:ok, result}
    else
      with :ok <- available_pending_turn(incident.pending_intent, source_turn_id),
           {:ok, _updated} <-
             Cases.record_case_pending_intent(
               incident,
               incident.revision,
               pending,
               authorize?: false
             ) do
        {:ok, result}
      end
    end
  end

  defp available_pending_turn(current, _source_turn_id) when map_size(current) == 0, do: :ok

  defp available_pending_turn(
         %{"action" => action, "turn_id" => source_turn_id},
         source_turn_id
       )
       when action in ["resolve_turn", "route_resolver_decision"],
       do: :ok

  defp available_pending_turn(_current, _source_turn_id),
    do: invalid("Case already has another pending decision")

  defp action_value({:ok, value}), do: value
  defp action_value({:error, _error} = error), do: error

  defp completed_decision(%{
         status: :completed,
         result: %{"outcome" => "decision", "intent" => intent}
       })
       when is_map(intent),
       do: :ok

  defp completed_decision(_turn),
    do: invalid("Target discovery requires a completed Resolver decision")

  defp route_key(turn, kind), do: "resolver-route:#{turn.id}:#{kind}"

  defp invalid(message),
    do: {:error, Ash.Error.Changes.InvalidChanges.exception(message: message)}
end
