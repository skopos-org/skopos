defmodule SkoposWeb.APIErrorControllerTest do
  use SkoposWeb.ConnCase, async: true

  test "returns JSON for an unknown API route", %{conn: conn} do
    conn = get(conn, "/api/v1/missing")

    assert %{
             "error" => %{
               "code" => "not_found",
               "message" => "API route was not found",
               "request_id" => request_id
             }
           } = json_response(conn, 404)

    assert is_binary(request_id)
  end
end
