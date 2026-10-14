defmodule Skopos.Targets.InventoryImport.Digest do
  @moduledoc false

  alias Skopos.Targets.InventoryImportRow

  @fields [
    :position,
    :disposition,
    :identity_source,
    :identity_kind,
    :identity_value,
    :candidate,
    :provenance,
    :errors,
    :target_id,
    :target_revision
  ]

  def rows(rows) do
    rows
    |> Enum.map(&row/1)
    |> Jason.encode!()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  def row(%InventoryImportRow{} = row),
    do: row |> Map.from_struct() |> Map.take(@fields)

  def row(row), do: Map.take(row, @fields)
end
