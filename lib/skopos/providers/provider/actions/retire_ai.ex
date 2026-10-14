defmodule Skopos.Providers.Provider.Actions.RetireAI do
  @moduledoc false

  use Ash.Resource.Actions.Implementation

  require Ash.Query

  alias Skopos.Providers
  alias Skopos.Providers.{AIUsageRoleAssignment, Provider}

  @impl true
  def run(input, _opts, _context) do
    %{id: id, expected_revision: expected_revision} = input.arguments

    with {:ok, _provider} <- Providers.get_provider(id, authorize?: false) do
      Ash.transact([Provider, AIUsageRoleAssignment], fn ->
        with {:ok, provider} <- locked_provider(id) do
          retire(provider, expected_revision)
        end
      end)
    end
  end

  defp locked_provider(id) do
    Provider
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(id: id)
    |> Ash.Query.lock(:for_update)
    |> Ash.read_one(authorize?: false)
  end

  defp retire(%Provider{kind: :ai, retired_at: retired_at} = provider, _expected_revision)
       when not is_nil(retired_at),
       do: provider

  defp retire(%Provider{kind: :ai, revision: revision} = provider, revision) do
    with :ok <- disable_assignments(provider.id),
         {:ok, retired} <-
           provider
           |> Ash.Changeset.for_update(
             :retire_record,
             %{expected_revision: revision, credentials: %{}},
             authorize?: false
           )
           |> Ash.update(authorize?: false) do
      retired
    end
  end

  defp retire(%Provider{kind: :ai}, _expected_revision),
    do: {:error, Ash.Error.Changes.StaleRecord.exception(resource: Provider, field: :revision)}

  defp retire(_provider, _expected_revision),
    do:
      {:error,
       Ash.Error.Changes.InvalidAttribute.exception(
         field: :kind,
         message: "only AI connections can be deleted"
       )}

  defp disable_assignments(provider_id) do
    AIUsageRoleAssignment
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(provider_id: provider_id, enabled: true)
    |> Ash.Query.lock(:for_update)
    |> Ash.read(authorize?: false)
    |> case do
      {:ok, assignments} ->
        Enum.reduce_while(assignments, :ok, fn assignment, _acc ->
          case assignment
               |> Ash.Changeset.for_update(
                 :update,
                 %{expected_revision: assignment.revision, enabled: false},
                 authorize?: false
               )
               |> Ash.update(authorize?: false) do
            {:ok, _updated} -> {:cont, :ok}
            {:error, error} -> {:halt, {:error, error}}
          end
        end)

      {:error, error} ->
        {:error, error}
    end
  end
end
