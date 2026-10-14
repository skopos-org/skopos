defmodule Skopos.Cases.AuthoritySetting.Actions.Configure do
  use Ash.Resource.Actions.Implementation

  alias Skopos.Cases
  alias Skopos.Cases.AuthoritySetting

  @setting_fields [
    :authority_mode,
    :signal_automation_enabled,
    :max_elapsed_seconds,
    :max_resolver_turns,
    :max_target_requests,
    :max_effects,
    :max_related_targets,
    :max_ai_usage_units,
    :max_no_progress_turns,
    :reason
  ]

  @impl true
  def run(input, _opts, context) do
    arguments = input.arguments

    Ash.transact(AuthoritySetting, fn ->
      with {:ok, current} <- Cases.current_authority_setting(authorize?: false),
           true <-
             current.setting_revision == arguments.expected_setting_revision ||
               stale(:setting_revision),
           {:ok, _retired} <-
             Cases.retire_authority_setting(current, current.revision,
               actor: context.actor,
               authorize?: false
             ),
           attributes <-
             arguments
             |> Map.take(@setting_fields)
             |> Map.merge(%{
               setting_revision: current.setting_revision + 1,
               active: true,
               changed_by_id: context.actor.id
             }),
           {:ok, setting} <-
             Cases.create_authority_setting_revision(attributes,
               actor: context.actor,
               authorize?: false
             ) do
        setting
      end
    end)
  end

  defp stale(field) do
    {:error, Ash.Error.Changes.StaleRecord.exception(resource: AuthoritySetting, field: field)}
  end
end
