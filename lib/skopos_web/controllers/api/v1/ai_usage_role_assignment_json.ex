defmodule SkoposWeb.API.V1.AIUsageRoleAssignmentJSON do
  @moduledoc false

  def data(assignment) do
    %{
      id: assignment.id,
      provider_id: assignment.provider_id,
      role: assignment.role,
      priority: assignment.priority,
      enabled: assignment.enabled,
      revision: assignment.revision,
      inserted_at: assignment.inserted_at,
      updated_at: assignment.updated_at
    }
  end
end
