defmodule SkoposWeb.API.FallbackController do
  @moduledoc false

  use SkoposWeb, :controller

  def call(conn, {:error, error}), do: SkoposWeb.API.Response.from_error(conn, error)
  def call(conn, error), do: SkoposWeb.API.Response.from_error(conn, error)
end
