defmodule SkoposWeb.CacheBodyReader do
  @moduledoc false

  def read_body(conn, opts) do
    case Plug.Conn.read_body(conn, opts) do
      {:ok, body, conn} -> {:ok, body, cache(conn, body)}
      {:more, body, conn} -> {:more, body, cache(conn, body)}
      other -> other
    end
  end

  def raw_body(conn) do
    conn.assigns
    |> Map.get(:raw_body, [])
    |> Enum.reverse()
    |> IO.iodata_to_binary()
  end

  defp cache(conn, body) do
    Plug.Conn.assign(conn, :raw_body, [body | Map.get(conn.assigns, :raw_body, [])])
  end
end
