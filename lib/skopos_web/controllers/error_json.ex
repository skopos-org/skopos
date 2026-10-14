defmodule SkoposWeb.ErrorJSON do
  @moduledoc false

  def render(template, assigns) do
    status = Phoenix.Controller.status_message_from_template(template)

    %{
      error: %{
        code: code(template),
        message: status,
        request_id: request_id(assigns)
      }
    }
  end

  defp code("400" <> _suffix), do: "bad_request"
  defp code("401" <> _suffix), do: "unauthenticated"
  defp code("403" <> _suffix), do: "forbidden"
  defp code("404" <> _suffix), do: "not_found"
  defp code("409" <> _suffix), do: "conflict"
  defp code("422" <> _suffix), do: "validation_failed"
  defp code(_template), do: "internal_error"

  defp request_id(%{conn: conn}) do
    conn
    |> Plug.Conn.get_resp_header("x-request-id")
    |> List.first()
  end

  defp request_id(_assigns), do: nil
end
