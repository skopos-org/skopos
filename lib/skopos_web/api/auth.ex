defmodule SkoposWeb.API.Auth do
  @moduledoc false

  import Plug.Conn

  alias AshAuthentication.Plug.Helpers
  alias SkoposWeb.API.Response

  def init(opts), do: opts

  def call(conn, _opts) do
    conn = Helpers.retrieve_from_bearer(conn, :skopos)

    if conn.assigns[:current_user] do
      conn
    else
      conn
      |> Response.error(:unauthorized, "unauthenticated", "Authentication is required")
      |> halt()
    end
  end
end
