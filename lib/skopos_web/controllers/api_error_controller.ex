defmodule SkoposWeb.APIErrorController do
  use SkoposWeb, :controller

  def not_found(conn, _params) do
    SkoposWeb.API.Response.error(conn, :not_found, "not_found", "API route was not found")
  end
end
