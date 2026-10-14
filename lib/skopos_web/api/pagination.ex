defmodule SkoposWeb.API.Pagination do
  @moduledoc false

  @default_limit 50
  @max_limit 100
  @max_cursor_bytes 16_384

  def parse(params) when is_map(params) do
    with {:ok, limit} <- parse_limit(Map.get(params, "limit")),
         {:ok, cursor} <- parse_cursor(Map.get(params, "after")) do
      {:ok, [limit: limit, after: cursor] |> Enum.reject(fn {_key, value} -> is_nil(value) end)}
    end
  end

  def next_cursor(%Ash.Page.Keyset{more?: true, results: results}) do
    results
    |> List.last()
    |> case do
      nil -> nil
      record -> record.__metadata__.keyset
    end
  end

  def next_cursor(%Ash.Page.Keyset{}), do: nil

  defp parse_limit(nil), do: {:ok, @default_limit}
  defp parse_limit(limit) when is_integer(limit) and limit in 1..@max_limit, do: {:ok, limit}

  defp parse_limit(limit) when is_binary(limit) do
    case Integer.parse(limit) do
      {parsed, ""} when parsed in 1..@max_limit -> {:ok, parsed}
      _invalid -> {:error, :invalid_pagination}
    end
  end

  defp parse_limit(_limit), do: {:error, :invalid_pagination}

  defp parse_cursor(nil), do: {:ok, nil}

  defp parse_cursor(cursor)
       when is_binary(cursor) and byte_size(cursor) > 0 and
              byte_size(cursor) <= @max_cursor_bytes,
       do: {:ok, cursor}

  defp parse_cursor(_cursor), do: {:error, :invalid_pagination}
end
