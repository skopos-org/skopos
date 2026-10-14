defmodule Skopos.Cases.Case.Changes.BudgetExhaustion do
  use Ash.Resource.Change

  alias Skopos.Cases
  alias Skopos.Cases.ResolutionRun

  @impl true
  def change(changeset, _opts, context) do
    Ash.Changeset.after_action(changeset, fn changeset, incident ->
      with {:ok, run} <- Cases.active_resolution_run(incident.id, authorize?: false),
           :ok <- current_run(run, changeset),
           {:ok, paused_run} <-
             Cases.pause_resolution_run(
               run,
               Ash.Changeset.get_argument(changeset, :expected_run_revision),
               authorize?: false
             ),
           {:ok, _event} <-
             Cases.create_case_event_record(
               %{
                 case_id: incident.id,
                 resolution_run_id: paused_run.id,
                 actor_id: context.actor && context.actor.id,
                 event_type: "limit_exhausted",
                 idempotency_key: Ash.Changeset.get_argument(changeset, :ledger_key),
                 data: event_data(changeset)
               },
               authorize?: false
             ) do
        {:ok, incident}
      end
    end)
  end

  defp current_run(run, changeset) do
    if run.id == Ash.Changeset.get_argument(changeset, :resolution_run_id) and
         run.revision == Ash.Changeset.get_argument(changeset, :expected_run_revision) and
         run.status == :running do
      :ok
    else
      {:error, Ash.Error.Changes.StaleRecord.exception(resource: ResolutionRun, field: :revision)}
    end
  end

  defp event_data(changeset) do
    argument = &Ash.Changeset.get_argument(changeset, &1)

    Map.merge(argument.(:event_data), %{
      "limit" => to_string(argument.(:limit)),
      "reason" => argument.(:reason),
      "attempted_kind" => to_string(argument.(:kind)),
      "attempted_amount" => argument.(:amount),
      "pending_intent" => argument.(:pending_intent),
      "required_human_input" => argument.(:required_human_input)
    })
  end
end
