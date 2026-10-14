defmodule SkoposWeb.ErrorJSONTest do
  use SkoposWeb.ConnCase, async: true

  test "renders 404" do
    assert SkoposWeb.ErrorJSON.render("404.json", %{}) == %{
             error: %{code: "not_found", message: "Not Found", request_id: nil}
           }
  end

  test "renders 500" do
    assert SkoposWeb.ErrorJSON.render("500.json", %{}) ==
             %{
               error: %{code: "internal_error", message: "Internal Server Error", request_id: nil}
             }
  end
end
