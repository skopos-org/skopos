defmodule Skopos.Targets.InventoryImport.Actions.Preview do
  use Ash.Resource.Actions.Implementation

  alias Skopos.Providers
  alias Skopos.Providers.Inventory
  alias Skopos.Targets
  alias Skopos.Targets.{InventoryImport, InventoryImportRow}
  alias Skopos.Targets.InventoryImport.Digest

  @headers ~w(external_id identity_kind name kind type_id facts_json)
  @max_rows 100_000
  @max_candidate_fields 100
  @max_candidate_bytes 65_536

  @impl true
  def run(input, opts, context) do
    result =
      case opts[:operation] do
        :manual -> preview_manual(input.arguments, context.actor)
        :inventory -> preview_inventory(input.arguments, context.actor)
      end

    case result do
      {:error, message} when is_binary(message) ->
        {:error, InventoryImport.Error.exception(category: :invalid_input, message: message)}

      other ->
        other
    end
  end

  defp preview_manual(%{source: source, csv: csv}, actor) do
    with {:ok, records} <- parse_csv(csv),
         {:ok, rows} <- build_rows(source, records),
         {:ok, import} <- persist_preview(:manual, source, nil, nil, nil, rows, actor) do
      {:ok, import}
    end
  end

  defp preview_inventory(arguments, actor) do
    case Providers.inventory_snapshot(
           arguments.provider_id,
           arguments.request,
           arguments.invocation,
           actor: actor
         ) do
      {:ok, %Inventory.Snapshot{} = snapshot} ->
        records = Enum.map(snapshot.records, &inventory_record/1)

        with {:ok, rows} <- build_rows(arguments.source, records),
             {:ok, import} <-
               persist_preview(
                 :inventory,
                 arguments.source,
                 arguments.provider_id,
                 snapshot.status,
                 snapshot.source_version,
                 rows,
                 actor
               ) do
          {:ok, import}
        end

      {:error, error} ->
        {:error, error}
    end
  end

  defp inventory_record(record) do
    {facts, errors} = json_map_result(record.attributes)

    %{
      external_id: record.external_id,
      identity_kind: to_string(record.kind),
      name: value(record.attributes, "name", record.external_id),
      kind: value(record.attributes, "kind", to_string(record.kind)),
      type_id: value(record.attributes, "type_id", to_string(record.kind)),
      facts: facts,
      provenance: %{"source_ref" => record.source_ref},
      errors: errors
    }
  end

  defp parse_csv(csv) do
    try do
      case NimbleCSV.RFC4180.parse_string(csv, skip_headers: false) do
        [@headers | rows] when length(rows) <= @max_rows ->
          {:ok,
           rows
           |> Enum.with_index(1)
           |> Enum.map(fn {columns, position} -> csv_record(columns, position) end)}

        [_wrong_header | _rows] ->
          {:error, "CSV header must be #{Enum.join(@headers, ",")}"}

        [] ->
          {:error, "CSV is empty"}
      end
    rescue
      _error -> {:error, "CSV is invalid"}
    end
  end

  defp csv_record([external_id, identity_kind, name, kind, type_id, facts_json], position) do
    {facts, errors} = decode_facts(facts_json)

    %{
      position: position,
      external_id: external_id,
      identity_kind: identity_kind,
      name: name,
      kind: kind,
      type_id: type_id,
      facts: facts,
      provenance: %{"row" => position},
      errors: errors
    }
  end

  defp csv_record(_columns, position) do
    %{
      position: position,
      external_id: "invalid-row-#{position}",
      identity_kind: "invalid",
      name: "",
      kind: "",
      type_id: "",
      facts: %{},
      provenance: %{"row" => position},
      errors: ["row must contain six columns"]
    }
  end

  defp decode_facts(""), do: {%{}, []}

  defp decode_facts(value) do
    case Jason.decode(value) do
      {:ok, facts} when is_map(facts) -> {facts, []}
      _other -> {%{}, ["facts_json must be a JSON object"]}
    end
  end

  defp build_rows(source, records) when length(records) <= @max_rows do
    with {:ok, identities} <- Targets.external_identities_for_source(source, authorize?: false) do
      identity_index = Map.new(identities, &{{&1.kind, &1.value}, &1})
      duplicate_keys = duplicate_keys(records)

      rows =
        records
        |> Enum.with_index(1)
        |> Enum.map(&build_row(&1, source, identity_index, duplicate_keys))

      {:ok, rows}
    end
  end

  defp build_rows(_source, _records), do: {:error, "Import exceeds #{@max_rows} rows"}

  defp build_row({record, fallback_position}, source, identity_index, duplicate_keys) do
    position = Map.get(record, :position, fallback_position)
    identity_kind = clean(record.identity_kind)
    identity_value = clean(record.external_id)
    key = {identity_kind, identity_value}
    candidate = candidate(record)

    errors =
      Map.get(record, :errors, []) ++
        required_errors(record) ++ field_length_errors(record) ++ candidate_errors(candidate)

    errors = if key in duplicate_keys, do: errors ++ ["duplicate stable identity"], else: errors
    identity = identity_index[key]

    %{
      position: position,
      disposition: disposition(errors, identity),
      identity_source: source,
      identity_kind: bounded_value(identity_kind, "invalid", 80),
      identity_value: bounded_value(identity_value, "invalid-row-#{position}", 500),
      candidate: persistable_candidate(candidate, errors),
      provenance: json_map(Map.get(record, :provenance, %{})),
      errors: Enum.uniq(errors),
      target_id: identity && identity.target_id,
      target_revision: identity && identity.target.revision
    }
  end

  defp disposition([_error | _rest], _identity), do: :error
  defp disposition([], nil), do: :create
  defp disposition([], _identity), do: :update

  defp persist_preview(
         source_type,
         source,
         provider_id,
         snapshot_status,
         source_version,
         rows,
         actor
       ) do
    digest = Digest.rows(rows)
    error_count = Enum.count(rows, &(&1.disposition == :error))

    Ash.transact([InventoryImport, InventoryImportRow], fn ->
      with {:ok, import} <-
             Targets.create_inventory_import_preview(
               %{
                 source_type: source_type,
                 source: source,
                 status: :previewed,
                 snapshot_status: snapshot_status,
                 source_version: source_version,
                 content_digest: digest,
                 row_count: length(rows),
                 error_count: error_count,
                 provider_id: provider_id,
                 created_by_id: actor.id
               },
               actor: actor,
               authorize?: false
             ),
           :ok <- persist_rows(import.id, rows) do
        import
      end
    end)
  end

  defp persist_rows(import_id, rows) do
    inputs = Enum.map(rows, &Map.put(&1, :inventory_import_id, import_id))

    case Ash.bulk_create(inputs, InventoryImportRow, :create,
           domain: Targets,
           authorize?: false,
           return_errors?: true
         ) do
      %Ash.BulkResult{status: :success} -> :ok
      %Ash.BulkResult{errors: errors} -> {:error, errors}
    end
  end

  defp duplicate_keys(records) do
    records
    |> Enum.frequencies_by(&{clean(&1.identity_kind), clean(&1.external_id)})
    |> Enum.filter(fn {_key, count} -> count > 1 end)
    |> Enum.map(&elem(&1, 0))
  end

  defp required_errors(record) do
    [
      {:external_id, "external_id is required"},
      {:identity_kind, "identity_kind is required"},
      {:name, "name is required"},
      {:kind, "kind is required"},
      {:type_id, "type_id is required"}
    ]
    |> Enum.flat_map(fn {field, message} ->
      if clean(Map.get(record, field)) == "", do: [message], else: []
    end)
  end

  defp field_length_errors(record) do
    [external_id: 500, identity_kind: 80, name: 120, kind: 80, type_id: 120]
    |> Enum.flat_map(fn {field, limit} ->
      if String.length(clean(Map.get(record, field))) > limit,
        do: ["#{field} exceeds #{limit} characters"],
        else: []
    end)
  end

  defp candidate(record) do
    %{
      "name" => clean(record.name),
      "kind" => clean(record.kind),
      "type_id" => clean(record.type_id),
      "facts" => json_map(record.facts)
    }
  end

  defp candidate_errors(candidate) do
    case Jason.encode(candidate) do
      {:ok, encoded}
      when map_size(candidate) <= @max_candidate_fields and
             byte_size(encoded) <= @max_candidate_bytes ->
        []

      _other ->
        ["candidate exceeds 64 KiB"]
    end
  end

  defp persistable_candidate(candidate, errors) do
    candidate
    |> Map.update!("name", &bounded_value(&1, "invalid", 120))
    |> Map.update!("kind", &bounded_value(&1, "invalid", 80))
    |> Map.update!("type_id", &bounded_value(&1, "invalid", 120))
    |> then(fn bounded ->
      if "candidate exceeds 64 KiB" in errors, do: Map.put(bounded, "facts", %{}), else: bounded
    end)
  end

  defp bounded_value("", fallback, _limit), do: fallback
  defp bounded_value(value, _fallback, limit), do: String.slice(value, 0, limit)

  defp value(attributes, "name", default),
    do: Map.get(attributes, "name", Map.get(attributes, :name, default))

  defp value(attributes, "kind", default),
    do: Map.get(attributes, "kind", Map.get(attributes, :kind, default))

  defp value(attributes, "type_id", default),
    do: Map.get(attributes, "type_id", Map.get(attributes, :type_id, default))

  defp clean(value) when is_binary(value), do: String.trim(value)
  defp clean(value) when is_atom(value), do: Atom.to_string(value)
  defp clean(_value), do: ""

  defp json_map(value) do
    case json_map_result(value) do
      {map, []} -> map
      {_map, _errors} -> %{}
    end
  end

  defp json_map_result(value) do
    with {:ok, encoded} <- Jason.encode(value),
         {:ok, decoded} when is_map(decoded) <- Jason.decode(encoded) do
      {decoded, []}
    else
      _other -> {%{}, ["facts must contain JSON-compatible values"]}
    end
  end
end
