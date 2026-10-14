defmodule Skopos.Targets.Changes.EnqueueCaseReconciliation do
  use Ash.Resource.Change

  @impl true
  def init(opts) do
    {:ok, opts}
  end

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.after_action(changeset, fn changeset, result ->
      resource =
        case changeset.resource do
          Skopos.Targets.Target -> "target"
          Skopos.Targets.ExternalIdentity -> "external_identity"
        end

      args = %{"resource" => resource, "resource_id" => result.id, "revision" => result.revision}

      case args |> Skopos.Cases.Case.TargetCatalogReconciliationWorker.new() |> Oban.insert() do
        {:ok, %Oban.Job{id: id}} when is_integer(id) -> {:ok, result}
        {:ok, _unpersisted} -> {:error, "Case reconciliation job was not persisted"}
        {:error, error} -> {:error, error}
      end
    end)
  end

  @impl true
  def atomic(changeset, opts, context), do: {:ok, change(changeset, opts, context)}
end
