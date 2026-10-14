defmodule SkoposWeb.API.Response do
  @moduledoc false

  import Plug.Conn
  import Phoenix.Controller, only: [json: 2]

  alias SkoposWeb.API.Pagination
  alias Skopos.Targets.InventoryImport

  def data(conn, value, status \\ :ok) do
    conn
    |> put_status(status)
    |> json(%{data: value})
  end

  def page(conn, %Ash.Page.Keyset{} = page, serializer) when is_function(serializer, 1) do
    json(conn, %{
      data: Enum.map(page.results, serializer),
      page: %{next: Pagination.next_cursor(page)}
    })
  end

  def error(conn, status, code, message, details \\ nil) do
    body = %{
      error:
        %{code: code, message: message, request_id: request_id(conn)}
        |> maybe_put_details(details)
    }

    conn
    |> put_status(status)
    |> json(body)
  end

  def from_error(conn, :invalid_credentials),
    do: error(conn, :unauthorized, "invalid_credentials", "Email or password is invalid")

  def from_error(conn, :invalid_pagination),
    do: error(conn, :unprocessable_entity, "invalid_pagination", "Pagination input is invalid")

  def from_error(conn, :bad_request),
    do: error(conn, :bad_request, "bad_request", "Request body is invalid")

  def from_error(conn, :not_found),
    do: error(conn, :not_found, "not_found", "Resource was not found")

  def from_error(conn, %Ash.Error.Forbidden{}),
    do: error(conn, :forbidden, "forbidden", "The operation is not permitted")

  def from_error(conn, %Ash.Error.Invalid{errors: errors}) do
    cond do
      Enum.any?(errors, &not_found?/1) ->
        from_error(conn, :not_found)

      Enum.any?(errors, &invalid_keyset?/1) ->
        from_error(conn, :invalid_pagination)

      Enum.any?(errors, &conflict?/1) ->
        error(conn, :conflict, "conflict", "Resource state conflicts with the request")

      true ->
        error(
          conn,
          :unprocessable_entity,
          "validation_failed",
          "Request validation failed",
          validation_details(errors)
        )
    end
  end

  def from_error(conn, _error),
    do: error(conn, :internal_server_error, "internal_error", "Request could not be completed")

  defp request_id(conn) do
    conn
    |> get_resp_header("x-request-id")
    |> List.first()
  end

  defp maybe_put_details(body, nil), do: body
  defp maybe_put_details(body, details), do: Map.put(body, :details, details)

  defp not_found?(%Ash.Error.Query.NotFound{}), do: true
  defp not_found?(_error), do: false

  defp invalid_keyset?(%Ash.Error.Page.InvalidKeyset{}), do: true
  defp invalid_keyset?(_error), do: false

  defp conflict?(%Ash.Error.Changes.StaleRecord{}), do: true

  defp conflict?(%InventoryImport.Error{category: category})
       when category in [
              :digest_changed,
              :identity_changed,
              :preview_changed,
              :revision_changed,
              :target_changed
            ],
       do: true

  defp conflict?(%Ash.Error.Changes.InvalidAttribute{field: :revision, message: "is stale"}),
    do: true

  defp conflict?(%Ash.Error.Changes.InvalidAttribute{message: message}) do
    is_binary(message) and String.contains?(message, "already been taken")
  end

  defp conflict?(_error), do: false

  defp validation_details(errors) do
    fields =
      errors
      |> Enum.flat_map(&validation_fields/1)
      |> Enum.uniq()
      |> Enum.sort()

    if fields == [], do: nil, else: %{fields: fields}
  end

  defp validation_fields(%{field: field}) when is_atom(field), do: [Atom.to_string(field)]

  defp validation_fields(%{fields: fields}) when is_list(fields),
    do: Enum.map(fields, &to_string/1)

  defp validation_fields(%{errors: errors}) when is_list(errors),
    do: Enum.flat_map(errors, &validation_fields/1)

  defp validation_fields(_error), do: []
end
