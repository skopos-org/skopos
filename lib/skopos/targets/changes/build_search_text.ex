defmodule Skopos.Targets.Changes.BuildSearchText do
  use Ash.Resource.Change

  @impl true
  def init(opts) do
    case Keyword.fetch(opts, :fields) do
      {:ok, fields} when is_list(fields) -> {:ok, Keyword.put(opts, :fields, fields)}
      _other -> {:error, "fields must be a list"}
    end
  end

  @impl true
  def change(changeset, opts, _context) do
    search_text =
      opts[:fields]
      |> Enum.map(&Ash.Changeset.get_attribute(changeset, &1))
      |> Enum.reject(&is_nil/1)
      |> Enum.map_join(" ", &search_value/1)
      |> String.downcase()

    Ash.Changeset.force_change_attribute(changeset, :search_text, search_text)
  end

  defp search_value(value) when is_binary(value), do: value
  defp search_value(value) when is_map(value), do: Jason.encode!(value)
  defp search_value(value), do: to_string(value)
end
