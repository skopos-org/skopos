defmodule SkoposWeb.API.V1.InventoryImportJSON do
  @moduledoc false

  def data(import) do
    %{
      id: import.id,
      source_type: import.source_type,
      source: import.source,
      status: import.status,
      snapshot_status: import.snapshot_status,
      source_version: import.source_version,
      content_digest: import.content_digest,
      row_count: import.row_count,
      error_count: import.error_count,
      provider_id: import.provider_id,
      created_by_id: import.created_by_id,
      revision: import.revision,
      applied_at: import.applied_at,
      inserted_at: import.inserted_at,
      updated_at: import.updated_at
    }
  end

  def row(row) do
    %{
      id: row.id,
      inventory_import_id: row.inventory_import_id,
      position: row.position,
      disposition: row.disposition,
      identity_source: row.identity_source,
      identity_kind: row.identity_kind,
      identity_value: row.identity_value,
      candidate: row.candidate,
      provenance: row.provenance,
      errors: row.errors,
      target_id: row.target_id,
      target_revision: row.target_revision,
      inserted_at: row.inserted_at,
      updated_at: row.updated_at
    }
  end

  def row_summary(row), do: Map.take(row, Skopos.Targets.InventoryImportRow.summary_fields())
end
