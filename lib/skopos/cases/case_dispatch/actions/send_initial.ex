defmodule Skopos.Cases.CaseDispatch.Actions.SendInitial do
  use Ash.Resource.Actions.Implementation

  alias Skopos.Cases
  alias Skopos.Cases.{Case, CaseDispatch, ResolutionRun, Turn}
  alias Skopos.Cases.Case.AdmissionLock, as: CaseAdmissionLock

  @impl true
  def run(input, _opts, _context) do
    case_id = input.arguments.case_id

    result =
      Ash.transact([CaseDispatch, Case, ResolutionRun, Turn], fn ->
        with :ok <- CaseAdmissionLock.acquire(),
             {:ok, dispatch} <- lock_dispatch(case_id) do
          send_if_due(dispatch)
        end
      end)

    case result do
      {:ok, {:ok, value}} -> {:ok, value}
      {:ok, {:error, _error} = failed} -> failed
      other -> other
    end
  end

  defp lock_dispatch(case_id) do
    CaseDispatch
    |> Ash.Query.for_read(:for_case, %{case_id: case_id})
    |> Ash.Query.lock(:for_update)
    |> Ash.read_one(authorize?: false)
  end

  defp send_if_due(%{state: :disabled}), do: {:ok, %{status: :disabled}}
  defp send_if_due(%{state: :sent}), do: {:ok, %{status: :sent}}

  defp send_if_due(%{state: :collecting} = dispatch) do
    if DateTime.compare(DateTime.utc_now(), dispatch.due_at) == :lt do
      {:ok, %{status: :early, due_at: dispatch.due_at}}
    else
      with {:ok, incident} <- Cases.get_case(dispatch.case_id, authorize?: false),
           true <- incident.status == :running || {:error, "Case is not running"},
           {:ok, run} <- Cases.active_resolution_run(incident.id, authorize?: false),
           :ok <- initial_turn(incident, run),
           {:ok, _dispatch} <-
             Cases.record_case_dispatch_state(dispatch, dispatch.revision, %{state: :sent},
               authorize?: false
             ) do
        {:ok, %{status: :sent}}
      end
    end
  end

  defp initial_turn(%{trigger_kind: :signal} = incident, run) do
    with {:ok, members} <- Cases.active_conditions_for_case(incident.id, authorize?: false),
         true <- members != [] || {:error, "Case has no active Conditions"} do
      start_turn(incident, run, "signal-initial", "Investigate all active Signal conditions")
    end
  end

  defp initial_turn(%{trigger_kind: :manual} = incident, run) do
    if run.turn_count > 0 do
      :ok
    else
      start_turn(incident, run, "manual-initial", incident.title)
    end
  end

  defp initial_turn(_incident, _run), do: {:error, "Case trigger cannot be dispatched"}

  defp start_turn(incident, run, prefix, objective) do
    case Cases.start_turn(
           incident.id,
           run.id,
           "#{prefix}:#{incident.id}:#{run.generation}",
           %{"objective" => objective},
           %{"action" => "continue"},
           "Review Resolver limits",
           authorize?: false
         ) do
      {:ok, %{status: status}} when status in [:charged, :duplicate, :exhausted] -> :ok
      {:error, _error} = error -> error
      _other -> {:error, "Initial Resolver Turn was not accepted"}
    end
  end
end
