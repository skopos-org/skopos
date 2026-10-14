defmodule Skopos.TestAIUsage do
  @moduledoc false

  alias Skopos.Providers

  def configure!(provider_id, scope, priority, actor) do
    current = assignments(provider_id)

    Providers.configure_ai_usage!(
      provider_id,
      scope,
      priority,
      revision(current, :resolver),
      revision(current, :reviewer),
      actor: actor
    )

    assignments(provider_id)
  end

  def assignment!(provider_id, role) do
    assignments(provider_id) |> Map.fetch!(role)
  end

  defp assignments(provider_id) do
    Providers.list_ai_usage_role_assignments!(authorize?: false)
    |> Enum.filter(&(&1.provider_id == provider_id))
    |> Map.new(&{&1.role, &1})
  end

  defp revision(assignments, role) do
    case Map.get(assignments, role) do
      nil -> nil
      assignment -> assignment.revision
    end
  end
end
