defmodule Skopos.Targets.InventoryImport.Actions.Apply do
  use Ash.Resource.Actions.Implementation

  alias Skopos.Targets
  alias Skopos.Targets.{ExternalIdentity, InventoryImport, InventoryImportRow, Target}
  alias Skopos.Targets.InventoryImport.Digest

  @impl true
  def run(input, _opts, context) do
    apply_import(input.arguments, context.actor)
  end

  defp apply_import(arguments, actor) do
    with {:ok, import} <- Targets.get_inventory_import(arguments.id, authorize?: false),
         :ok <- expected_digest(import, arguments.expected_digest) do
      if import.status == :applied do
        {:ok, import}
      else
        apply_preview(import, arguments.expected_revision, actor)
      end
    end
  end

  defp apply_preview(import, expected_revision, actor) do
    with :ok <- current_revision(import, expected_revision),
         :ok <- applicable(import),
         {:ok, rows} <- Targets.inventory_import_rows(import.id, authorize?: false),
         :ok <- verify_rows(import, rows) do
      Ash.transact([InventoryImport, InventoryImportRow, Target, ExternalIdentity], fn ->
        with :ok <- apply_rows(rows, actor),
             {:ok, applied} <-
               Targets.mark_inventory_import_applied(import, expected_revision,
                 actor: actor,
                 authorize?: false
               ) do
          applied
        end
      end)
    end
  end

  defp apply_rows(rows, actor) do
    sources = rows |> Enum.map(& &1.identity_source) |> Enum.uniq()

    with {:ok, identities} <- load_identities(sources) do
      identity_index = Map.new(identities, &{{&1.source, &1.kind, &1.value}, &1})

      rows
      |> Enum.reduce_while({:ok, identity_index}, fn row, {:ok, index} ->
        case apply_row(row, index, actor) do
          {:ok, next_index} -> {:cont, {:ok, next_index}}
          {:error, _reason} = error -> {:halt, error}
        end
      end)
      |> case do
        {:ok, _index} -> :ok
        error -> error
      end
    end
  end

  defp apply_row(%{disposition: :create} = row, index, actor) do
    key = identity_key(row)

    with :ok <- ensure_identity_absent(index, key),
         {:ok, target} <-
           Targets.create_target(
             row.candidate["name"],
             row.candidate["kind"],
             row.candidate["type_id"],
             imported_facts(row),
             nil,
             actor: actor,
             authorize?: false
           ),
         {:ok, identity} <-
           Targets.create_external_identity(
             target.id,
             row.identity_source,
             row.identity_kind,
             row.identity_value,
             actor: actor,
             authorize?: false
           ) do
      {:ok, Map.put(index, key, %{identity | target: target})}
    else
      {:error, _reason} = error -> error
    end
  end

  defp apply_row(%{disposition: :update} = row, index, actor) do
    with %{} = identity <-
           Map.get(index, identity_key(row)) ||
             failure(:identity_changed, "Stable identity changed after preview"),
         :ok <- same_target(identity, row),
         :ok <- current_target(identity, row),
         facts <- merge_imported_facts(identity.target.facts, row),
         {:ok, _target} <-
           Targets.update_target(identity.target, row.target_revision, %{facts: facts},
             actor: actor,
             authorize?: false
           ) do
      {:ok, index}
    else
      {:error, _reason} = error -> error
    end
  end

  defp load_identities(sources) do
    Enum.reduce_while(sources, {:ok, []}, fn source, {:ok, identities} ->
      case Targets.external_identities_for_source(source, authorize?: false) do
        {:ok, source_identities} -> {:cont, {:ok, source_identities ++ identities}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp identity_key(row), do: {row.identity_source, row.identity_kind, row.identity_value}

  defp ensure_identity_absent(index, key) do
    if Map.has_key?(index, key),
      do: failure(:identity_changed, "Stable identity appeared after preview"),
      else: :ok
  end

  defp imported_facts(row), do: %{"inventory" => %{row.identity_source => row.candidate["facts"]}}

  defp merge_imported_facts(facts, row) do
    inventory =
      facts |> Map.get("inventory", %{}) |> Map.put(row.identity_source, row.candidate["facts"])

    Map.put(facts, "inventory", inventory)
  end

  defp verify_rows(import, rows) do
    if length(rows) == import.row_count and Digest.rows(rows) == import.content_digest,
      do: :ok,
      else: failure(:preview_changed, "Persisted preview changed")
  end

  defp expected_digest(%{content_digest: digest}, digest), do: :ok

  defp expected_digest(_import, _digest),
    do: failure(:digest_changed, "Import digest changed")

  defp current_revision(%{revision: revision}, revision), do: :ok

  defp current_revision(_import, _expected_revision),
    do: failure(:revision_changed, "Import revision changed")

  defp applicable(%{error_count: 0}), do: :ok

  defp applicable(_import),
    do: failure(:row_errors, "Import contains row errors")

  defp same_target(%{target_id: target_id}, %{target_id: target_id}), do: :ok

  defp same_target(_identity, _row),
    do: failure(:identity_changed, "Stable identity target changed")

  defp current_target(%{target: %{revision: revision}}, %{target_revision: revision}), do: :ok

  defp current_target(_identity, _row),
    do: failure(:target_changed, "Target changed after preview")

  defp failure(category, message),
    do: {:error, InventoryImport.Error.exception(category: category, message: message)}
end
