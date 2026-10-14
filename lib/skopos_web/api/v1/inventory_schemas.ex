defmodule SkoposWeb.API.V1.InventorySchemas do
  @moduledoc false

  alias OpenApiSpex.Schema
  alias SkoposWeb.API.Schemas

  def components do
    %{
      "InventoryImport" => inventory_import(),
      "InventoryImportResponse" => Schemas.data(ref("InventoryImport")),
      "InventoryImportPage" => Schemas.page(ref("InventoryImport")),
      "InventoryImportRow" => inventory_import_row(),
      "InventoryImportRowPage" => Schemas.page(ref("InventoryImportRow")),
      "InventoryImportRowSummary" =>
        object(
          %{
            id: Schemas.uuid(),
            position: %Schema{type: :integer, minimum: 1, maximum: 100_000},
            disposition: enum(~w(create update error)),
            identity_value: string(1, 500),
            errors: %Schema{type: :array, maxItems: 20, items: string(1, 500)}
          },
          [:id, :position, :disposition, :identity_value, :errors],
          false
        ),
      "InventoryImportRowSummaryPage" => Schemas.page(ref("InventoryImportRowSummary")),
      "ManualInventoryPreviewRequest" => manual_preview_request(),
      "ProviderInventoryPreviewRequest" => provider_preview_request(),
      "ApplyInventoryImportRequest" => apply_request()
    }
  end

  def ref(name), do: Schemas.reference(name)

  defp inventory_import do
    object(
      %{
        id: Schemas.uuid(),
        source_type: enum(~w(manual inventory)),
        source: string(1, 120),
        status: enum(~w(previewed applied)),
        snapshot_status: nullable_enum(~w(complete partial)),
        source_version: %Schema{type: :string, maxLength: 1_024, nullable: true},
        content_digest: %Schema{type: :string, minLength: 64, maxLength: 64},
        row_count: count(),
        error_count: count(),
        provider_id: nullable_uuid(),
        created_by_id: Schemas.uuid(),
        revision: positive_integer(),
        applied_at: nullable_timestamp(),
        inserted_at: Schemas.timestamp(),
        updated_at: Schemas.timestamp()
      },
      [
        :id,
        :source_type,
        :source,
        :status,
        :snapshot_status,
        :source_version,
        :content_digest,
        :row_count,
        :error_count,
        :provider_id,
        :created_by_id,
        :revision,
        :applied_at,
        :inserted_at,
        :updated_at
      ],
      false
    )
  end

  defp inventory_import_row do
    object(
      %{
        id: Schemas.uuid(),
        inventory_import_id: Schemas.uuid(),
        position: %Schema{type: :integer, minimum: 1, maximum: 100_000},
        disposition: enum(~w(create update error)),
        identity_source: string(1, 120),
        identity_kind: string(1, 80),
        identity_value: string(1, 500),
        candidate: map(),
        provenance: map(),
        errors: %Schema{type: :array, maxItems: 20, items: string(1, 500)},
        target_id: nullable_uuid(),
        target_revision: %Schema{type: :integer, minimum: 1, nullable: true},
        inserted_at: Schemas.timestamp(),
        updated_at: Schemas.timestamp()
      },
      [
        :id,
        :inventory_import_id,
        :position,
        :disposition,
        :identity_source,
        :identity_kind,
        :identity_value,
        :candidate,
        :provenance,
        :errors,
        :target_id,
        :target_revision,
        :inserted_at,
        :updated_at
      ],
      false
    )
  end

  defp manual_preview_request do
    wrapped(
      %{
        source: string(1, 120),
        csv: %Schema{type: :string, minLength: 1, maxLength: 10_485_760}
      },
      [:source, :csv]
    )
  end

  defp provider_preview_request do
    wrapped(
      %{
        source: string(1, 120),
        provider_id: Schemas.uuid(),
        provider_revision: positive_integer(),
        scope: map(),
        max_pages: %Schema{type: :integer, minimum: 1, maximum: 100}
      },
      [:source, :provider_id, :provider_revision]
    )
  end

  defp apply_request do
    wrapped(
      %{
        expected_revision: positive_integer(),
        expected_digest: %Schema{type: :string, minLength: 64, maxLength: 64}
      },
      [:expected_revision, :expected_digest]
    )
  end

  defp wrapped(properties, required) do
    object(%{inventory_import: object(properties, required)}, [:inventory_import])
  end

  defp enum(values), do: %Schema{type: :string, enum: values}
  defp nullable_enum(values), do: %Schema{type: :string, enum: values, nullable: true}

  defp string(min_length, max_length),
    do: %Schema{type: :string, minLength: min_length, maxLength: max_length}

  defp count, do: %Schema{type: :integer, minimum: 0, maximum: 100_000}
  defp positive_integer, do: %Schema{type: :integer, minimum: 1}
  defp map, do: %Schema{type: :object, additionalProperties: true}
  defp nullable_uuid, do: %Schema{type: :string, format: :uuid, nullable: true}
  defp nullable_timestamp, do: %Schema{type: :string, format: :"date-time", nullable: true}

  defp object(properties, required, additional_properties \\ nil) do
    %Schema{
      type: :object,
      properties: properties,
      required: required,
      additionalProperties: additional_properties
    }
  end
end
