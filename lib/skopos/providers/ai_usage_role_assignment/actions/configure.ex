defmodule Skopos.Providers.AIUsageRoleAssignment.Actions.Configure do
  @moduledoc false

  use Ash.Resource.Actions.Implementation

  require Ash.Query

  alias Skopos.Providers
  alias Skopos.Providers.{AIUsageRoleAssignment, Provider}

  @impl true
  def run(input, _opts, _context) do
    args = input.arguments

    with {:ok, _provider} <- Providers.get_active_provider(args.provider_id, authorize?: false) do
      Ash.transact([Provider, AIUsageRoleAssignment], fn -> configure_locked(args) end)
    end
  end

  defp configure_locked(args) do
    with {:ok, provider} <- locked_provider(args.provider_id),
         :ok <- ensure_ai(provider),
         {:ok, assignments} <- locked_assignments(provider.id),
         :ok <- ensure_revisions(assignments, args),
         :ok <- apply_roles(assignments, args) do
      true
    end
  end

  defp locked_provider(id) do
    Provider
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(id == ^id and is_nil(retired_at))
    |> Ash.Query.lock(:for_update)
    |> Ash.read_one(authorize?: false)
  end

  defp locked_assignments(provider_id) do
    AIUsageRoleAssignment
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(provider_id: provider_id)
    |> Ash.Query.lock(:for_update)
    |> Ash.read(authorize?: false)
    |> case do
      {:ok, records} -> {:ok, Map.new(records, &{&1.role, &1})}
      error -> error
    end
  end

  defp ensure_ai(%Provider{kind: :ai}), do: :ok

  defp ensure_ai(_provider),
    do:
      {:error,
       Ash.Error.Changes.InvalidAttribute.exception(
         field: :kind,
         message: "only AI connections have usage roles"
       )}

  defp ensure_revisions(assignments, args) do
    matches? =
      Enum.all?([:resolver, :reviewer], fn role ->
        current = Map.get(assignments, role)
        expected = Map.get(args, String.to_existing_atom("expected_#{role}_revision"))
        if current, do: current.revision == expected, else: is_nil(expected)
      end)

    if matches?,
      do: :ok,
      else:
        {:error,
         Ash.Error.Changes.StaleRecord.exception(
           resource: AIUsageRoleAssignment,
           field: :revision
         )}
  end

  defp apply_roles(assignments, args) do
    Enum.reduce_while([:resolver, :reviewer], :ok, fn role, _acc ->
      enabled = args.scope in [:all, role]

      result =
        case Map.get(assignments, role) do
          nil ->
            with {:ok, assignment} <-
                   AIUsageRoleAssignment
                   |> Ash.Changeset.for_create(
                     :create,
                     %{provider_id: args.provider_id, role: role, priority: args.priority},
                     authorize?: false
                   )
                   |> Ash.create(authorize?: false) do
              if enabled,
                do: {:ok, assignment},
                else:
                  assignment
                  |> Ash.Changeset.for_update(
                    :update,
                    %{expected_revision: assignment.revision, enabled: false},
                    authorize?: false
                  )
                  |> Ash.update(authorize?: false)
            end

          %{enabled: ^enabled, priority: priority} when priority == args.priority ->
            {:ok, :unchanged}

          assignment ->
            assignment
            |> Ash.Changeset.for_update(
              :update,
              %{
                expected_revision: assignment.revision,
                enabled: enabled,
                priority: args.priority
              },
              authorize?: false
            )
            |> Ash.update(authorize?: false)
        end

      case result do
        {:ok, _record} -> {:cont, :ok}
        {:error, error} -> {:halt, {:error, error}}
      end
    end)
  end
end
