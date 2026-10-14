defmodule Skopos.Cases.Operation.Actions.ResultReference do
  use Ash.Resource.Actions.Implementation

  alias Skopos.{Accounts, Cases, Providers, Targets}

  @impl true
  def run(input, _opts, %{actor: %{id: actor_id, role_version: actor_version}}) do
    %{reference_id: reference_id, case_id: case_id, clearance: clearance} = input.arguments

    with true <- clearance.kind in [:observation, :verification, :effect],
         true <- offered?(clearance, reference_id),
         {:ok, actor} <- Accounts.get_user(actor_id, authorize?: false),
         true <- actor.role in [:admin, :operator] and actor.role_version == actor_version,
         true <- clearance.actor_id == actor.id,
         {:ok, incident} <- Cases.get_case(case_id, authorize?: false),
         true <- incident.current_owner_id == actor.id,
         true <- incident.status == :running and not incident.cancel_requested,
         true <- incident.selected_target_id == clearance.target_id,
         {:ok, run} <- Cases.active_resolution_run(case_id, authorize?: false),
         true <- run.active and DateTime.compare(DateTime.utc_now(), run.deadline_at) == :lt,
         {:ok, source} <- Cases.get_operation(reference_id, authorize?: false),
         true <- same_scope?(source, case_id, clearance),
         {:ok, method} <-
           Targets.load_access_method_for_use(
             clearance.access_method_id,
             clearance.access_method_revision,
             clearance.capability,
             authorize?: false
           ),
         true <- method.provider_id == source.provider_id,
         true <- method.provider_revision == source.provider_revision,
         {:ok, target} <- Targets.get_target(source.target_id, authorize?: false),
         true <- target.active and target.revision == clearance.target_revision,
         {:ok, _provider} <-
           Providers.load_provider_for_invocation(
             source.provider_id,
             source.provider_revision,
             :target,
             authorize?: false
           ),
         {:ok, loaded} <- Ash.load(source, :protected_reference, authorize?: false),
         reference when is_map(reference) and map_size(reference) > 0 <-
           loaded.protected_reference do
      {:ok, reference}
    else
      {:error, _error} = error -> error
      _ -> unavailable()
    end
  end

  def run(_input, _opts, _context), do: unavailable()

  defp offered?(clearance, reference_id),
    do:
      clearance.reference == reference_id or
        clearance.parameters["result_reference"] == reference_id

  defp same_scope?(source, case_id, clearance) do
    source.reference == source.id and source.case_id == case_id and
      source.status in [:applied, :unknown, :partial] and
      source.target_id == clearance.target_id and
      source.target_revision == clearance.target_revision and
      source.access_method_id == clearance.access_method_id and
      source.access_method_revision == clearance.access_method_revision and
      source.provider_id == clearance.provider_id and
      source.provider_revision == clearance.provider_revision
  end

  defp unavailable do
    {:error,
     Ash.Error.Action.InvalidArgument.exception(
       field: :reference_id,
       message: "Remote result reference is unavailable"
     )}
  end
end
