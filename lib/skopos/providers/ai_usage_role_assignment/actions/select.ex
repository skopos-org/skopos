defmodule Skopos.Providers.AIUsageRoleAssignment.Actions.Select do
  use Ash.Resource.Actions.Implementation

  alias Skopos.Providers
  alias Skopos.Providers.AI

  @impl true
  def run(input, opts, _context) do
    role = opts[:role]
    excluded = Map.get(input.arguments, :excluded_provider_ids, []) |> MapSet.new()

    case Providers.eligible_ai_usage_role_assignments(role, authorize?: false) do
      {:ok, assignments} ->
        case Enum.find(assignments, &(not MapSet.member?(excluded, &1.provider_id))) do
          nil -> {:error, ai_error("No eligible #{role_name(role)} AI is assigned")}
          assignment -> {:ok, assigned_selection(assignment, role)}
        end

      {:error, _error} = error ->
        error
    end
  end

  defp assigned_selection(assignment, role) do
    %AI.Selection{
      role: role,
      provider_id: assignment.provider_id,
      provider_revision: assignment.provider.revision,
      source: :assignment,
      assignment_id: assignment.id,
      assignment_revision: assignment.revision
    }
  end

  defp role_name(:resolver), do: "Resolver"
  defp role_name(:reviewer), do: "Reviewer"

  defp ai_error(message), do: AI.Error.exception(category: :unavailable, message: message)
end
