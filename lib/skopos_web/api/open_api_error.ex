defmodule SkoposWeb.API.OpenAPIError do
  @moduledoc false

  @behaviour Plug

  alias SkoposWeb.API.Response

  @impl Plug
  def init(errors), do: errors

  @impl Plug
  def call(conn, errors) do
    cond do
      Enum.any?(errors, &(field(&1) in ["after", "limit"])) ->
        Response.from_error(conn, :invalid_pagination)

      Enum.any?(errors, &(Map.get(&1, :reason) in [:missing_field, :missing_header])) ->
        Response.from_error(conn, :bad_request)

      true ->
        fields =
          errors |> Enum.map(&field/1) |> Enum.reject(&is_nil/1) |> Enum.uniq() |> Enum.sort()

        details = if fields == [], do: nil, else: %{fields: fields}

        Response.error(
          conn,
          :unprocessable_entity,
          "validation_failed",
          "Request validation failed",
          details
        )
    end
  end

  defp field(%{name: name}) when is_atom(name) and not is_nil(name), do: Atom.to_string(name)
  defp field(%{name: name}) when is_binary(name), do: name

  defp field(%{path: path}) when is_list(path) and path != [] do
    path |> List.last() |> to_string()
  end

  defp field(_error), do: nil
end
