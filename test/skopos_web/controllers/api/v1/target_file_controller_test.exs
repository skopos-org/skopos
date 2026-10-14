defmodule SkoposWeb.API.V1.TargetFileControllerTest do
  use SkoposWeb.ConnCase, async: false

  import OpenApiSpex.TestAssertions
  alias Skopos.{Accounts, Targets}

  @password "test-only-password"

  setup do
    admin = Accounts.bootstrap!("file-api-admin@example.invalid", @password, @password)
    signed_in = Accounts.sign_in!(admin.email, @password)
    target = Targets.create_target!("file-host", "host", "custom-os", %{}, nil, actor: admin)
    %{admin: admin, target: target, token: signed_in.__metadata__.token}
  end

  test "an authenticated operator creates a scoped file without exposing storage fields",
       context do
    body = %{
      "file" => %{
        "name" => "device.bin",
        "media_type" => "application/octet-stream",
        "size_bytes" => 5,
        "expected_sha256" => "b55f1659c0645fd1cee6dfa8b3af06795e9da7e48cb65c2b999f896c9f539dbd",
        "upload_key" => "public-file-upload"
      }
    }

    conn =
      build_json_conn(body)
      |> put_req_header("authorization", "Bearer " <> context.token)
      |> post("/api/v1/targets/#{context.target.id}/files", body)

    assert %{"data" => file} = json_response(conn, 201)
    assert_operation_response(conn)
    assert file["target_id"] == context.target.id
    assert file["status"] == "uploading"
    assert file["received_bytes"] == 0
    assert Map.fetch!(file, "request_id") == nil
    assert is_nil(file["sha256"])
    refute Map.has_key?(file, "upload_key")
    refute Map.has_key?(file, "uploaded_by_id")
    refute Map.has_key?(file, "bytes")

    assert file["expected_sha256"] ==
             "b55f1659c0645fd1cee6dfa8b3af06795e9da7e48cb65c2b999f896c9f539dbd"
  end

  test "authentication precedes body decoding on protected API routes", context do
    conn =
      build_json_conn(%{})
      |> post("/api/v1/targets/#{context.target.id}/files", "{invalid JSON")

    assert %{"error" => %{"code" => "unauthenticated"}} = json_response(conn, 401)
    assert_operation_response(conn, "createTargetFile")
  end

  test "incoming file metadata and completed bytes use the authenticated file endpoint",
       context do
    request_id = Ecto.UUID.generate()

    receipt =
      Targets.begin_artifact_receipt!(
        context.target.id,
        "response.bin",
        "application/octet-stream",
        "incoming-api",
        %{request_id: request_id},
        actor: context.admin
      )

    Targets.append_artifact_chunk!(receipt.id, 0, <<255, 0, 1, 2, 255>>, actor: context.admin)
    path = "/api/v1/targets/#{context.target.id}/files/#{receipt.id}"

    shown =
      build_json_conn()
      |> put_req_header("authorization", "Bearer " <> context.token)
      |> get(path)

    assert %{
             "data" => %{
               "status" => "receiving",
               "size_bytes" => nil,
               "expected_sha256" => nil,
               "received_bytes" => 5,
               "sha256" => nil
             }
           } = json_response(shown, 200)

    assert_operation_response(shown)
    assert json_response(shown, 200)["data"]["request_id"] == request_id

    premature =
      build_json_conn()
      |> put_req_header("authorization", "Bearer " <> context.token)
      |> post(path <> "/complete")

    assert json_response(premature, 422)["error"]["code"] == "validation_failed"
    Targets.complete_artifact_receipt!(receipt.id, actor: context.admin)

    ready =
      build_json_conn()
      |> put_req_header("authorization", "Bearer " <> context.token)
      |> get(path)

    assert %{
             "data" => %{
               "status" => "ready",
               "size_bytes" => 5,
               "expected_sha256" => nil,
               "sha256" => "b55f1659c0645fd1cee6dfa8b3af06795e9da7e48cb65c2b999f896c9f539dbd"
             }
           } = json_response(ready, 200)

    assert_operation_response(ready)
    assert json_response(ready, 200)["data"]["request_id"] == request_id

    downloaded =
      build_conn()
      |> put_req_header("accept", "application/octet-stream")
      |> put_req_header("authorization", "Bearer " <> context.token)
      |> get(path <> "/chunks/0")

    assert response(downloaded, 200) == <<255, 0, 1, 2, 255>>
    assert_operation_response(downloaded)
  end

  test "raw binary chunks cross the authenticated endpoint and persist readable progress",
       context do
    body = %{
      "file" => %{
        "name" => "device.bin",
        "media_type" => "application/octet-stream",
        "size_bytes" => 5,
        "expected_sha256" => "b55f1659c0645fd1cee6dfa8b3af06795e9da7e48cb65c2b999f896c9f539dbd",
        "upload_key" => "raw-chunk-upload"
      }
    }

    %{"data" => file} =
      build_json_conn(body)
      |> put_req_header("authorization", "Bearer " <> context.token)
      |> post("/api/v1/targets/#{context.target.id}/files", body)
      |> json_response(201)

    path = "/api/v1/targets/#{context.target.id}/files/#{file["id"]}"

    conn =
      build_conn()
      |> put_req_header("accept", "application/json")
      |> put_req_header("content-type", "application/octet-stream")
      |> put_req_header("authorization", "Bearer " <> context.token)
      |> put(path <> "/chunks/0", <<255, 0, 1, 2, 255>>)

    assert %{"data" => %{"received_bytes" => 5, "status" => "uploading"}} =
             json_response(conn, 200)

    assert_operation_response(conn)

    shown =
      build_json_conn()
      |> put_req_header("authorization", "Bearer " <> context.token)
      |> get(path)

    assert %{"data" => %{"received_bytes" => 5, "sha256" => nil}} = json_response(shown, 200)
    assert_operation_response(shown)
    assert get_resp_header(shown, "cache-control") == ["no-store"]

    completed =
      build_json_conn()
      |> put_req_header("authorization", "Bearer " <> context.token)
      |> post(path <> "/complete")

    assert %{
             "data" => %{
               "status" => "ready",
               "sha256" => "b55f1659c0645fd1cee6dfa8b3af06795e9da7e48cb65c2b999f896c9f539dbd"
             }
           } = json_response(completed, 200)

    assert_operation_response(completed)

    downloaded =
      build_conn()
      |> put_req_header("accept", "application/octet-stream")
      |> put_req_header("authorization", "Bearer " <> context.token)
      |> get(path <> "/chunks/0")

    assert response(downloaded, 200) == <<255, 0, 1, 2, 255>>
    assert get_resp_header(downloaded, "content-type") == ["application/octet-stream"]
    assert get_resp_header(downloaded, "cache-control") == ["no-store"]
    assert_operation_response(downloaded)

    revoked =
      build_json_conn()
      |> put_req_header("authorization", "Bearer " <> context.token)
      |> delete(path)

    assert %{"data" => %{"status" => "revoked"}} = json_response(revoked, 200)
    assert_operation_response(revoked)

    unavailable =
      build_conn()
      |> put_req_header("accept", "application/octet-stream")
      |> put_req_header("authorization", "Bearer " <> context.token)
      |> get(path <> "/chunks/0")

    assert %{"error" => %{"code" => "validation_failed"}} = json_response(unavailable, 422)
    assert_operation_response(unavailable)
  end

  test "raw requests reject wrong actor and Target before decoding their bodies", context do
    upload =
      Targets.begin_artifact!(
        context.target.id,
        "private.bin",
        "application/octet-stream",
        5,
        "b55f1659c0645fd1cee6dfa8b3af06795e9da7e48cb65c2b999f896c9f539dbd",
        "scope-upload",
        actor: context.admin
      )

    viewer =
      Accounts.create_user!("file-viewer@example.invalid", @password, :viewer,
        actor: context.admin
      )

    other =
      Accounts.create_user!("file-other@example.invalid", @password, :operator,
        actor: context.admin
      )

    other_target =
      Targets.create_target!("other-file-host", "host", "custom-os", %{}, nil,
        actor: context.admin
      )

    paths = [
      {context.target.id, nil, 401},
      {context.target.id, Accounts.sign_in!(viewer.email, @password).__metadata__.token, 404},
      {context.target.id, Accounts.sign_in!(other.email, @password).__metadata__.token, 404},
      {other_target.id, context.token, 404}
    ]

    for {target_id, token, status} <- paths do
      conn = build_json_conn(%{})
      conn = if token, do: put_req_header(conn, "authorization", "Bearer " <> token), else: conn

      rejected =
        put(conn, "/api/v1/targets/#{target_id}/files/#{upload.id}/chunks/0", "{invalid JSON")

      assert json_response(rejected, status)["error"]
      assert_operation_response(rejected, "appendTargetFileChunk")
    end

    assert Targets.get_artifact!(upload.id, actor: context.admin).received_bytes == 0
  end

  test "a truncated HTTP chunk is not committed as successful upload progress", context do
    upload =
      Targets.begin_artifact!(
        context.target.id,
        "truncated.bin",
        "application/octet-stream",
        5,
        "b55f1659c0645fd1cee6dfa8b3af06795e9da7e48cb65c2b999f896c9f539dbd",
        "truncated-upload",
        actor: context.admin
      )

    rejected =
      build_conn()
      |> put_req_header("accept", "application/json")
      |> put_req_header("content-type", "application/octet-stream")
      |> put_req_header("content-length", "5")
      |> put_req_header("authorization", "Bearer " <> context.token)
      |> put("/api/v1/targets/#{context.target.id}/files/#{upload.id}/chunks/0", <<255, 0>>)

    assert json_response(rejected, 400)["error"]
    assert Targets.get_artifact!(upload.id, actor: context.admin).received_bytes == 0
  end

  test "file metadata pages reach all scoped files and an off-page ID remains readable",
       context do
    path = "/api/v1/targets/#{context.target.id}/files"

    ids =
      for index <- 1..51 do
        body = %{
          "file" => %{
            "name" => "page-#{index}.bin",
            "media_type" => "application/octet-stream",
            "size_bytes" => 0,
            "expected_sha256" =>
              "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
            "upload_key" => "page-#{index}"
          }
        }

        conn =
          build_json_conn(body)
          |> put_req_header("authorization", "Bearer " <> context.token)
          |> post(path, body)

        json_response(conn, 201)["data"]["id"]
      end

    other =
      Targets.create_target!("other-file-host", "host", "custom-os", %{}, nil,
        actor: context.admin
      )

    Targets.begin_artifact_receipt!(
      other.id,
      "other.bin",
      "application/octet-stream",
      "other-file",
      %{},
      actor: context.admin
    )

    first_conn =
      build_json_conn()
      |> put_req_header("authorization", "Bearer " <> context.token)
      |> get(path)

    assert_operation_response(first_conn)
    assert %{"data" => first, "page" => %{"next" => cursor}} = json_response(first_conn, 200)
    assert length(first) == 50
    assert is_binary(cursor)
    assert Enum.all?(first, &(&1["target_id"] == context.target.id))
    refute Enum.any?(first, &Map.has_key?(&1, "bytes"))

    last_conn =
      build_json_conn()
      |> put_req_header("authorization", "Bearer " <> context.token)
      |> get(path, %{"after" => cursor, "limit" => 50})

    assert_operation_response(last_conn)
    assert %{"data" => [last], "page" => %{"next" => nil}} = json_response(last_conn, 200)
    assert MapSet.new(Enum.map(first, & &1["id"]) ++ [last["id"]]) == MapSet.new(ids)
    refute Enum.any?(first, &(&1["id"] == last["id"]))

    shown =
      build_json_conn()
      |> put_req_header("authorization", "Bearer " <> context.token)
      |> get(path <> "/" <> last["id"])

    assert json_response(shown, 200)["data"] == last
    assert_operation_response(shown)
  end

  test "a fresh client can list transfer progress and obtain the server chunk limits", context do
    upload =
      Targets.begin_artifact!(
        context.target.id,
        "listed.bin",
        "application/octet-stream",
        5,
        "b55f1659c0645fd1cee6dfa8b3af06795e9da7e48cb65c2b999f896c9f539dbd",
        "listed-upload",
        actor: context.admin
      )

    Targets.append_artifact_chunk!(upload.id, 0, <<255, 0>>, actor: context.admin)

    listed =
      build_json_conn()
      |> put_req_header("authorization", "Bearer " <> context.token)
      |> get("/api/v1/targets/#{context.target.id}/files")

    assert %{"data" => [%{"id" => id, "received_bytes" => 2, "status" => "uploading"}]} =
             json_response(listed, 200)

    assert id == upload.id
    assert_operation_response(listed)

    limits =
      build_json_conn()
      |> put_req_header("authorization", "Bearer " <> context.token)
      |> get("/api/v1/target-file-limits")

    assert %{
             "data" => %{
               "chunk_bytes" => 262_144,
               "max_size_bytes" => 536_870_912,
               "lifetime_seconds" => 86_400
             }
           } = json_response(limits, 200)

    assert_operation_response(limits)
  end
end
