defmodule Skopos.Cases.Case.Actions.ResolverFailureRoute do
  use Ash.Resource.Actions.Implementation

  alias Skopos.Cases
  alias Skopos.Cases.{Case, CaseEvent, ResolutionRun, Turn}
  alias Skopos.Cases.Case.AdmissionLock, as: CaseAdmissionLock

  @impl true
  def run(input, _opts, _context) do
    Ash.transact([Case, CaseEvent, ResolutionRun, Turn], fn ->
      with :ok <- CaseAdmissionLock.acquire(),
           {:ok, turn} <- Cases.get_turn(input.arguments.turn_id, authorize?: false),
           true <-
             (turn.status == :completed and turn.progress_kind == :delivery_retry and
                turn.result["outcome"] == "delivery_failed" and
                turn.result["category"] == input.arguments.category and
                turn.result["rejection_code"] == input.arguments.rejection_code) ||
               {:error, "Resolver Turn has no matching delivery failure"},
           {:ok, incident} <- Cases.get_case(turn.case_id, authorize?: false),
           {:ok, run} <- Cases.get_resolution_run(turn.resolution_run_id, authorize?: false),
           true <- run.case_id == incident.id || {:error, "ResolutionRun belongs to another Case"} do
        route(turn, incident, run, input.arguments)
      end
    end)
    |> case do
      {:ok, {:ok, true}} -> {:ok, true}
      {:ok, {:error, _reason} = error} -> error
      {:error, _reason} = error -> error
    end
  end

  defp route(_turn, _incident, %{status: :needs_attention}, _arguments), do: {:ok, true}

  defp route(turn, incident, run, _arguments)
       when run.ai_usage_units >= run.max_ai_usage_units do
    Cases.require_case_attention(
      incident.id,
      incident.revision,
      run.id,
      run.revision,
      "resolver-usage-exhausted:#{turn.id}",
      "AI usage limit exhausted after Resolver delivery failure",
      %{"action" => "retry_resolver", "turn_id" => turn.id},
      "Increase the AI usage limit or review the Case",
      authorize?: false
    )
    |> case do
      {:ok, _stopped} -> {:ok, true}
      {:error, _reason} = error -> error
    end
  end

  defp route(turn, incident, _run, arguments) do
    intent = %{"action" => "continue_resolution", "source_turn_id" => turn.id}

    with true <- incident.status == :running || {:error, "Case resolution is not running"},
         {:ok, result} <-
           Cases.start_turn(
             incident.id,
             turn.resolution_run_id,
             "resolver:delivery-retry:#{turn.id}",
             retry_intent(turn, arguments),
             intent,
             "Review Resolver limits or continue the Case manually",
             authorize?: false
           ) do
      queue(turn.id, result)
    end
  end

  defp queue(_source_id, %{status: :exhausted}), do: {:ok, true}

  defp queue(source_id, %{status: status, case: incident, value: next_turn})
       when status in [:charged, :duplicate] do
    pending = %{
      "action" => "resolve_turn",
      "turn_id" => next_turn.id,
      "source_turn_id" => source_id
    }

    if incident.pending_intent == pending do
      {:ok, true}
    else
      case Cases.queue_case_resolver_turn(
             incident,
             incident.revision,
             source_id,
             next_turn.id,
             authorize?: false
           ) do
        {:ok, _updated} -> {:ok, true}
        {:error, _reason} = error -> error
      end
    end
  end

  defp retry_intent(turn, arguments) do
    %{
      "objective" => "Continue resolution after a retryable Resolver delivery failure",
      "source" => "resolver_delivery_failure",
      "source_turn_id" => turn.id,
      "category" => arguments.category
    }
    |> maybe_put("rejection_code", arguments.rejection_code)
    |> maybe_put("rejection_path", arguments.rejection_path)
  end

  defp maybe_put(intent, _key, value) when value in [nil, ""], do: intent
  defp maybe_put(intent, key, value), do: Map.put(intent, key, value)
end
