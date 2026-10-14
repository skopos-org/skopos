defmodule Skopos.Cases.Case.Actions.RecheckSignalConditions do
  use Ash.Resource.Actions.Implementation

  require Ash.Query

  alias Skopos.Cases

  alias Skopos.Cases.{Case, CaseDispatch, ResolutionRun, Turn}
  alias Skopos.Cases.Case.AdmissionLock, as: CaseAdmissionLock
  alias Skopos.Cases.Case.ConditionContext, as: ConditionContext

  @impl true
  def run(input, _opts, _context) do
    Ash.transact([Case, CaseDispatch, ResolutionRun, Turn], fn ->
      with :ok <- CaseAdmissionLock.acquire(),
           {:ok, incident} <- lock_case(input.arguments.id),
           {:ok, dispatch} <- Cases.case_dispatch(incident.id, authorize?: false) do
        recheck(incident, dispatch)
      end
    end)
    |> case do
      {:ok, {:ok, result}} -> {:ok, result}
      {:ok, {:error, _reason} = error} -> error
      {:error, _reason} = error -> error
    end
  end

  defp recheck(%{status: status}, _dispatch) when status != :running,
    do: {:ok, %{status: :skipped}}

  defp recheck(_incident, %{state: state}) when state != :sent,
    do: {:ok, %{status: :skipped}}

  defp recheck(incident, _dispatch) do
    with {:ok, run} <- Cases.active_resolution_run(incident.id, authorize?: false),
         {:ok, conditions} <- ConditionContext.current_conditions(incident),
         {:ok, started} <- Cases.started_turns_for_run(run.id, authorize?: false) do
      cond do
        conditions == [] or not Enum.any?(conditions, &(&1.state == :recovered)) ->
          {:ok, %{status: :skipped}}

        started != [] or not available_pending?(incident.pending_intent) ->
          {:ok, %{status: :busy}}

        true ->
          start_recheck(incident, run, conditions)
      end
    end
  end

  defp start_recheck(incident, run, conditions) do
    revisions = ConditionContext.condition_revisions(conditions)

    key =
      "signal:source-recheck:" <>
        (:crypto.hash(:sha256, :erlang.term_to_binary({run.id, revisions}, [:deterministic]))
         |> Base.encode16(case: :lower))

    with {:ok, result} <-
           Cases.start_turn(
             incident.id,
             run.id,
             key,
             %{
               "objective" =>
                 "Investigate the current monitoring state of every attached Condition",
               "condition_revisions" => revisions,
               "source" => "signal_recheck"
             },
             %{"action" => "recheck_signal_conditions"},
             "Review Resolver limits",
             authorize?: false
           ) do
      case result do
        %{status: :charged, value: turn} ->
          set_recheck_pending(incident, turn)

        %{status: :duplicate, value: %{status: :started} = turn} ->
          set_recheck_pending(incident, turn)

        %{status: :duplicate} ->
          {:ok, %{status: :skipped}}

        %{status: :exhausted} ->
          {:ok, %{status: :skipped}}
      end
    end
  end

  defp set_recheck_pending(incident, turn) do
    with {:ok, current} <- Cases.get_case(incident.id, authorize?: false),
         {:ok, _updated} <-
           Cases.record_case_pending_intent(
             current,
             current.revision,
             %{"action" => "resolve_turn", "turn_id" => turn.id},
             authorize?: false
           ) do
      {:ok, %{status: :started}}
    end
  end

  defp available_pending?(pending) when map_size(pending) == 0, do: true

  defp available_pending?(%{"action" => "await_source_recovery"}), do: true

  defp available_pending?(_pending), do: false

  defp lock_case(id) do
    Case
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(id: id)
    |> Ash.Query.lock(:for_update)
    |> Ash.read_one(authorize?: false)
    |> case do
      {:ok, %Case{} = incident} -> {:ok, incident}
      {:ok, nil} -> {:error, "Signal Case is unavailable"}
      {:error, _reason} = error -> error
    end
  end
end
