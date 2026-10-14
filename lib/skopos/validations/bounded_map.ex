defmodule Skopos.Validations.BoundedMap do
  use Ash.Resource.Validation

  @impl true
  def init(opts) do
    if Keyword.has_key?(opts, :attribute) or Keyword.has_key?(opts, :argument) do
      {:ok, opts |> Keyword.put_new(:max_fields, 100) |> Keyword.put_new(:max_bytes, 65_536)}
    else
      {:error, "expected :attribute or :argument"}
    end
  end

  @impl true
  def validate(changeset, opts, _context) do
    attribute = opts[:attribute] || opts[:argument]

    value =
      if opts[:argument],
        do: Ash.Changeset.get_argument(changeset, attribute),
        else: Ash.Changeset.get_attribute(changeset, attribute)

    cond do
      not is_map(value) ->
        error(attribute, "must be a map")

      map_size(value) > opts[:max_fields] ->
        error(attribute, "has too many fields")

      true ->
        validate_encoding(attribute, value, opts[:max_bytes])
    end
  end

  defp validate_encoding(attribute, value, max_bytes) do
    case Jason.encode(value) do
      {:ok, encoded} when byte_size(encoded) <= max_bytes -> :ok
      {:ok, _encoded} -> error(attribute, "is too large")
      {:error, _error} -> error(attribute, "must contain JSON-compatible values")
    end
  end

  defp error(field, message), do: {:error, field: field, message: message}
end
