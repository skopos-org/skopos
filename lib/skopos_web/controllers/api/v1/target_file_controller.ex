defmodule SkoposWeb.API.V1.TargetFileController do
  use SkoposWeb, :controller
  use OpenApiSpex.ControllerSpecs

  plug :no_cache
  plug :read_upload when action == :append_chunk

  plug OpenApiSpex.Plug.CastAndValidate,
    render_error: SkoposWeb.API.OpenAPIError,
    replace_params: false

  action_fallback SkoposWeb.API.FallbackController
  alias Skopos.Targets
  alias SkoposWeb.API.{Pagination, Response, Schemas}
  alias SkoposWeb.API.V1.TargetFileJSON

  tags ["Targets"]

  @errors Schemas.errors([
            :bad_request,
            :unauthorized,
            :forbidden,
            :not_found,
            :conflict,
            :unprocessable_entity,
            :internal_server_error
          ])
  @file_response {"File metadata", "application/json", Schemas.reference("TargetFileResponse")}
  @file_parameters Schemas.id_parameter(:target_id) ++ Schemas.id_parameter()
  @chunk_parameters @file_parameters ++
                      [
                        {:offset,
                         [
                           in: :path,
                           required: true,
                           schema: %OpenApiSpex.Schema{type: :integer, minimum: 0}
                         ]}
                      ]

  operation :index,
    operation_id: "listTargetFiles",
    summary: "List Target file metadata and progress",
    parameters: Schemas.id_parameter(:target_id) ++ Schemas.pagination_parameters(),
    responses:
      [ok: {"File page", "application/json", Schemas.reference("TargetFilePage")}] ++ @errors

  operation :limits,
    operation_id: "getTargetFileLimits",
    summary: "Get server file transfer limits",
    responses:
      [
        ok:
          {"File transfer limits", "application/json",
           Schemas.reference("TargetFileLimitsResponse")}
      ] ++ @errors

  operation :show,
    operation_id: "getTargetFile",
    summary: "Get Target file metadata and upload progress",
    parameters: @file_parameters,
    responses: [ok: @file_response] ++ @errors

  operation :append_chunk,
    operation_id: "appendTargetFileChunk",
    summary: "Upload a binary chunk at its exact offset",
    parameters: @chunk_parameters,
    request_body:
      {"Binary chunk", "application/octet-stream",
       %OpenApiSpex.Schema{type: :string, format: :binary}, required: true},
    responses: [ok: @file_response] ++ @errors

  operation :complete,
    operation_id: "completeTargetFile",
    summary: "Validate and publish a completely uploaded file",
    parameters: @file_parameters,
    responses: [ok: @file_response] ++ @errors

  operation :revoke,
    operation_id: "revokeTargetFile",
    summary: "Remove a Target file from use",
    parameters: @file_parameters,
    responses: [ok: @file_response] ++ @errors

  operation :download_chunk,
    operation_id: "downloadTargetFileChunk",
    summary: "Download a completed Target file chunk",
    parameters: @chunk_parameters,
    responses:
      [
        ok:
          {"Binary chunk", "application/octet-stream",
           %OpenApiSpex.Schema{type: :string, format: :binary}}
      ] ++ @errors

  operation :create,
    operation_id: "createTargetFile",
    summary: "Begin uploading a Target file",
    parameters: Schemas.id_parameter(:target_id),
    request_body:
      {"File metadata", "application/json", Schemas.reference("CreateTargetFileRequest"),
       required: true},
    responses:
      [created: {"Staged file", "application/json", Schemas.reference("TargetFileResponse")}] ++
        @errors

  def create(conn, %{"target_id" => target_id, "file" => input}) do
    with {:ok, artifact} <-
           Targets.begin_artifact(
             target_id,
             input["name"],
             input["media_type"],
             input["size_bytes"],
             input["expected_sha256"],
             input["upload_key"],
             actor: conn.assigns.current_user
           ) do
      Response.data(conn, TargetFileJSON.file(artifact), :created)
    end
  end

  def create(_conn, _params), do: {:error, :bad_request}

  def index(conn, %{"target_id" => target_id} = params) do
    with {:ok, page} <- Pagination.parse(params),
         {:ok, artifacts} <-
           Targets.page_artifacts(target_id, page: page, actor: conn.assigns.current_user),
         do: Response.page(conn, artifacts, &TargetFileJSON.file/1)
  end

  def limits(conn, _params) do
    with {:ok, limits} <- Targets.artifact_limits(actor: conn.assigns.current_user),
         do: Response.data(conn, limits)
  end

  def show(conn, %{"id" => id, "target_id" => target_id}) do
    with {:ok, artifact} <-
           Targets.get_artifact_for_target(id, target_id, actor: conn.assigns.current_user),
         do: Response.data(conn, TargetFileJSON.file(artifact))
  end

  def append_chunk(conn, %{"id" => id, "offset" => offset}) do
    with {:ok, artifact} <-
           Targets.append_artifact_chunk(id, offset, conn.body_params,
             actor: conn.assigns.current_user
           ),
         do: Response.data(conn, TargetFileJSON.file(artifact))
  end

  def complete(conn, %{"id" => id, "target_id" => target_id}) do
    with {:ok, _file} <-
           Targets.get_artifact_for_target(id, target_id, actor: conn.assigns.current_user),
         {:ok, artifact} <- Targets.complete_artifact(id, actor: conn.assigns.current_user),
         do: Response.data(conn, TargetFileJSON.file(artifact))
  end

  def revoke(conn, %{"id" => id, "target_id" => target_id}) do
    with {:ok, _file} <-
           Targets.get_artifact_for_target(id, target_id, actor: conn.assigns.current_user),
         {:ok, artifact} <- Targets.revoke_artifact(id, actor: conn.assigns.current_user),
         do: Response.data(conn, TargetFileJSON.file(artifact))
  end

  def download_chunk(conn, %{"id" => id, "target_id" => target_id, "offset" => offset}) do
    with {:ok, bytes} <-
           Targets.read_artifact_chunk(id, target_id, offset, actor: conn.assigns.current_user) do
      conn |> put_resp_content_type("application/octet-stream", nil) |> send_resp(:ok, bytes)
    end
  end

  defp no_cache(conn, _opts), do: put_resp_header(conn, "cache-control", "no-store")

  defp read_upload(conn, _opts) do
    with {:ok, _artifact} <-
           Targets.get_artifact_for_target(
             conn.path_params["id"],
             conn.path_params["target_id"],
             actor: conn.assigns.current_user
           ),
         {:ok, limits} <- Targets.artifact_limits(actor: conn.assigns.current_user) do
      case read_body(conn, length: limits.chunk_bytes + 1, read_length: limits.chunk_bytes + 1) do
        {:ok, body, updated} when byte_size(body) <= limits.chunk_bytes ->
          if complete_body?(updated, body),
            do: %{updated | body_params: body},
            else: updated |> Response.from_error(:bad_request) |> halt()

        {:ok, _body, updated} ->
          invalid_chunk(updated)

        {:more, _body, updated} ->
          invalid_chunk(updated)

        {:error, _reason} ->
          conn |> Response.from_error(:bad_request) |> halt()
      end
    else
      {:error, error} -> conn |> Response.from_error(error) |> halt()
    end
  end

  defp complete_body?(conn, body) do
    case get_req_header(conn, "content-length") do
      [] -> true
      [length] -> Integer.parse(length) == {byte_size(body), ""}
      _ -> false
    end
  end

  defp invalid_chunk(conn) do
    conn
    |> Response.error(:unprocessable_entity, "validation_failed", "Request validation failed", %{
      fields: ["bytes"]
    })
    |> halt()
  end
end
