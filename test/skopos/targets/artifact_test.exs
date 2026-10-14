defmodule Skopos.Targets.ArtifactTest do
  use Skopos.DataCase, async: false
  use Oban.Testing, repo: Skopos.Repo

  alias Skopos.{Accounts, Targets}

  setup do
    admin =
      Accounts.bootstrap!(
        "artifact-admin@example.invalid",
        "test-only-password",
        "test-only-password"
      )

    target = Targets.create_target!("transfer-host", "host", "custom-os", %{}, nil, actor: admin)
    %{admin: admin, target: target}
  end

  test "an operator publishes exact binary only after complete length and integrity checks",
       context do
    bytes = <<255, 0, 1, 2, 255>>
    digest = "b55f1659c0645fd1cee6dfa8b3af06795e9da7e48cb65c2b999f896c9f539dbd"

    upload =
      Targets.begin_artifact!(
        context.target.id,
        "device.bin",
        "application/octet-stream",
        5,
        digest,
        "binary-upload",
        actor: context.admin
      )

    assert upload.status == :uploading
    assert is_nil(upload.sha256)

    assert {:error, _} =
             Targets.read_artifact_chunk(upload.id, context.target.id, 0, actor: context.admin)

    staged =
      Targets.append_artifact_chunk!(upload.id, 0, binary_part(bytes, 0, 2), actor: context.admin)

    assert staged.received_bytes == 2
    assert {:error, _} = Targets.complete_artifact(upload.id, actor: context.admin)
    Targets.append_artifact_chunk!(upload.id, 2, binary_part(bytes, 2, 3), actor: context.admin)
    complete = Targets.complete_artifact!(upload.id, actor: context.admin)
    assert complete.status == :ready
    assert complete.sha256 == digest

    assert Targets.read_artifact_chunk!(complete.id, context.target.id, 0, actor: context.admin) ==
             <<255, 0>>

    assert Targets.read_artifact_chunk!(complete.id, context.target.id, 2, actor: context.admin) ==
             <<1, 2, 255>>

    assert {:error, _} =
             Targets.append_artifact_chunk(complete.id, 5, <<1>>, actor: context.admin)

    reread = Targets.get_artifact!(complete.id, actor: context.admin)
    assert reread.sha256 == digest
    assert reread.status == :ready
  end

  test "unknown-length incoming bytes become a file only after explicit receipt completion",
       context do
    receipt =
      Targets.begin_artifact_receipt!(
        context.target.id,
        "response.bin",
        "application/octet-stream",
        "response-1",
        actor: context.admin
      )

    assert receipt.status == :receiving
    assert is_nil(receipt.size_bytes)
    assert is_nil(receipt.expected_sha256)
    assert is_nil(receipt.sha256)
    Targets.append_artifact_chunk!(receipt.id, 0, <<255, 0>>, actor: context.admin)

    assert {:error, _} =
             Targets.artifact_reference(receipt.id, context.target.id, actor: context.admin)

    assert {:error, _} = Targets.complete_artifact(receipt.id, actor: context.admin)
    Targets.append_artifact_chunk!(receipt.id, 2, <<1, 2, 255>>, actor: context.admin)

    completed = Targets.complete_artifact_receipt!(receipt.id, actor: context.admin)
    assert completed.status == :ready
    assert completed.size_bytes == 5
    assert completed.sha256 == "b55f1659c0645fd1cee6dfa8b3af06795e9da7e48cb65c2b999f896c9f539dbd"
    reference = Targets.artifact_reference!(receipt.id, context.target.id, actor: context.admin)
    assert Targets.read_bound_artifact_chunk!(reference, 0, actor: context.admin) == <<255, 0>>
    assert Targets.read_bound_artifact_chunk!(reference, 2, actor: context.admin) == <<1, 2, 255>>

    assert Targets.begin_artifact_receipt!(
             context.target.id,
             "response.bin",
             "application/octet-stream",
             "response-1",
             actor: context.admin
           ).id == receipt.id

    assert Targets.complete_artifact_receipt!(receipt.id, actor: context.admin).revision ==
             completed.revision
  end

  test "a captured file keeps one immutable completion reason", context do
    receipt =
      Targets.begin_artifact_receipt!(
        context.target.id,
        "sample.bin",
        "application/octet-stream",
        "captured-response",
        actor: context.admin
      )

    Targets.append_artifact_chunk!(receipt.id, 0, <<255, 0>>, actor: context.admin)

    completed =
      Targets.complete_artifact_receipt!(receipt.id, %{completion_reason: :byte_limit},
        actor: context.admin
      )

    assert completed.completion_reason == :byte_limit

    assert Targets.complete_artifact_receipt!(receipt.id, %{completion_reason: :byte_limit},
             actor: context.admin
           ).revision == completed.revision

    assert {:error, _} =
             Targets.complete_artifact_receipt(receipt.id, %{completion_reason: :eof},
               actor: context.admin
             )

    assert Targets.get_artifact!(receipt.id, actor: context.admin).completion_reason ==
             :byte_limit

    assert Targets.read_artifact_chunk!(receipt.id, context.target.id, 0, actor: context.admin) ==
             <<255, 0>>
  end

  test "revoking a completed artifact makes its bytes unavailable", context do
    digest = "b55f1659c0645fd1cee6dfa8b3af06795e9da7e48cb65c2b999f896c9f539dbd"

    upload =
      Targets.begin_artifact!(
        context.target.id,
        "device.bin",
        "application/octet-stream",
        5,
        digest,
        "revoke-upload",
        actor: context.admin
      )

    Targets.append_artifact_chunk!(upload.id, 0, <<255, 0, 1, 2, 255>>, actor: context.admin)
    Targets.complete_artifact!(upload.id, actor: context.admin)
    revoked = Targets.revoke_artifact!(upload.id, actor: context.admin)
    assert revoked.status == :revoked

    assert {:error, _} =
             Targets.read_artifact_chunk(upload.id, context.target.id, 0, actor: context.admin)

    assert Targets.get_artifact!(upload.id, actor: context.admin).sha256 == digest
  end

  test "an empty receipt publishes the empty digest while input uploads still require a manifest",
       context do
    receipt = begin_receipt(context, "empty-response")

    ready =
      Targets.complete_artifact_receipt!(receipt.id, %{expected_size_bytes: 0},
        actor: context.admin
      )

    assert ready.size_bytes == 0
    assert ready.sha256 == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
    reference = Targets.artifact_reference!(receipt.id, context.target.id, actor: context.admin)
    assert Targets.read_bound_artifact_chunk!(reference, 0, actor: context.admin) == <<>>
    assert Targets.read_bound_artifact_range!(reference, 0, 8, actor: context.admin) == <<>>

    assert {:error, _} =
             Targets.begin_artifact(
               context.target.id,
               "input.bin",
               "application/octet-stream",
               nil,
               nil,
               "missing-manifest",
               actor: context.admin
             )

    upload = begin_upload(context, "input-manifest")
    assert {:error, _} = Targets.complete_artifact_receipt(upload.id, actor: context.admin)
    assert {:error, _} = Targets.complete_artifact(receipt.id, actor: context.admin)
  end

  test "receipt bounds and peer promises reject incomplete or changed content", context do
    previous = Application.get_env(:skopos, :artifact_limits)
    Application.put_env(:skopos, :artifact_limits, %{chunk_bytes: 3, max_size_bytes: 5})

    on_exit(fn ->
      if previous,
        do: Application.put_env(:skopos, :artifact_limits, previous),
        else: Application.delete_env(:skopos, :artifact_limits)
    end)

    receipt = begin_receipt(context, "bounded-response")

    assert {:error, _} =
             Targets.begin_artifact_receipt(
               context.target.id,
               "different.bin",
               "application/octet-stream",
               "bounded-response",
               actor: context.admin
             )

    assert {:error, _} =
             Targets.append_artifact_chunk(receipt.id, 0, <<255, 0, 1, 2>>, actor: context.admin)

    assert Targets.get_artifact!(receipt.id, actor: context.admin).received_bytes == 0
    Targets.append_artifact_chunk!(receipt.id, 0, <<255, 0, 1>>, actor: context.admin)

    assert Targets.append_artifact_chunk!(receipt.id, 0, <<255, 0, 1>>, actor: context.admin).received_bytes ==
             3

    assert {:error, _} =
             Targets.append_artifact_chunk(receipt.id, 0, <<255, 0, 2>>, actor: context.admin)

    assert {:error, _} =
             Targets.append_artifact_chunk(receipt.id, 3, <<2, 255, 0>>, actor: context.admin)

    Targets.append_artifact_chunk!(receipt.id, 3, <<2, 255>>, actor: context.admin)

    assert {:error, _} =
             Targets.complete_artifact_receipt(receipt.id, %{expected_size_bytes: 6},
               actor: context.admin
             )

    assert {:error, _} =
             Targets.complete_artifact_receipt(
               receipt.id,
               %{expected_sha256: String.duplicate("0", 64)},
               actor: context.admin
             )

    staged = Targets.get_artifact!(receipt.id, actor: context.admin)
    assert staged.received_bytes == 5
    assert staged.status == :receiving
    assert is_nil(staged.size_bytes)
    assert is_nil(staged.sha256)

    assert {:error, _} =
             Targets.artifact_reference(receipt.id, context.target.id, actor: context.admin)

    ready =
      Targets.complete_artifact_receipt!(
        receipt.id,
        %{
          expected_size_bytes: 5,
          expected_sha256: "b55f1659c0645fd1cee6dfa8b3af06795e9da7e48cb65c2b999f896c9f539dbd"
        },
        actor: context.admin
      )

    assert ready.status == :ready

    assert {:error, _} =
             Targets.complete_artifact_receipt(receipt.id, %{expected_size_bytes: 6},
               actor: context.admin
             )
  end

  test "receipt append and publication failures leave only unpublished durable progress",
       context do
    receipt = begin_receipt(context, "failed-response")
    # Persistence-failure fixture; verification stays at the public action seam.
    Skopos.Repo.query!("""
    CREATE FUNCTION pg_temp.reject_receipt_write() RETURNS trigger LANGUAGE plpgsql AS $$
    BEGIN
      IF NEW.received_bytes <> OLD.received_bytes OR NEW.status <> OLD.status THEN
        RAISE EXCEPTION 'injected receipt persistence failure';
      END IF;
      RETURN NEW;
    END;
    $$;
    """)

    reject_write = """
    CREATE TRIGGER reject_receipt_write BEFORE UPDATE ON artifacts
    FOR EACH ROW EXECUTE FUNCTION pg_temp.reject_receipt_write();
    """

    Skopos.Repo.query!(reject_write)

    assert {:error, _} =
             Targets.append_artifact_chunk(receipt.id, 0, <<255, 0, 1, 2, 255>>,
               actor: context.admin
             )

    assert Targets.get_artifact!(receipt.id, actor: context.admin).received_bytes == 0
    Skopos.Repo.query!("DROP TRIGGER reject_receipt_write ON artifacts")
    Targets.append_artifact_chunk!(receipt.id, 0, <<255, 0, 1, 2, 255>>, actor: context.admin)
    Skopos.Repo.query!(reject_write)
    assert {:error, _} = Targets.complete_artifact_receipt(receipt.id, actor: context.admin)
    staged = Targets.get_artifact!(receipt.id, actor: context.admin)
    assert staged.status == :receiving
    assert staged.received_bytes == 5
    assert is_nil(staged.size_bytes)
    assert is_nil(staged.sha256)

    assert {:error, _} =
             Targets.artifact_reference(receipt.id, context.target.id, actor: context.admin)

    Skopos.Repo.query!("DROP TRIGGER reject_receipt_write ON artifacts")
    ready = Targets.complete_artifact_receipt!(receipt.id, actor: context.admin)
    assert ready.size_bytes == 5
    assert ready.sha256 == "b55f1659c0645fd1cee6dfa8b3af06795e9da7e48cb65c2b999f896c9f539dbd"
  end

  defp begin_receipt(context, key) do
    Targets.begin_artifact_receipt!(
      context.target.id,
      "response.bin",
      "application/octet-stream",
      key,
      actor: context.admin
    )
  end

  test "a ready file has one exact reference for authorized operation reads", context do
    upload = begin_upload(context, "operation-file")

    assert {:error, _} =
             Targets.artifact_reference(upload.id, context.target.id, actor: context.admin)

    Targets.append_artifact_chunk!(upload.id, 0, <<255, 0, 1, 2, 255>>, actor: context.admin)
    Targets.complete_artifact!(upload.id, actor: context.admin)
    reference = Targets.artifact_reference!(upload.id, context.target.id, actor: context.admin)

    assert reference == %{
             "id" => upload.id,
             "target_id" => context.target.id,
             "name" => "device.bin",
             "media_type" => "application/octet-stream",
             "size_bytes" => 5,
             "sha256" => "b55f1659c0645fd1cee6dfa8b3af06795e9da7e48cb65c2b999f896c9f539dbd"
           }

    assert Targets.read_bound_artifact_chunk!(reference, 0, actor: context.admin) ==
             <<255, 0, 1, 2, 255>>

    for {key, value} <- [
          {"sha256", String.duplicate("0", 64)},
          {"size_bytes", 6},
          {"target_id", Ash.UUID.generate()},
          {"media_type", "text/plain"},
          {"name", "replacement.bin"}
        ] do
      assert {:error, _} =
               Targets.read_bound_artifact_chunk(Map.put(reference, key, value), 0,
                 actor: context.admin
               )
    end

    Targets.revoke_artifact!(upload.id, actor: context.admin)
    assert {:error, _} = Targets.read_bound_artifact_chunk(reference, 0, actor: context.admin)
  end

  test "a canonical file range reads exact offsets across uneven stored chunks", context do
    upload =
      Targets.begin_artifact!(
        context.target.id,
        "ranged.bin",
        "application/octet-stream",
        5,
        "b55f1659c0645fd1cee6dfa8b3af06795e9da7e48cb65c2b999f896c9f539dbd",
        "ranged-input",
        actor: context.admin
      )

    Targets.append_artifact_chunk!(upload.id, 0, <<255, 0>>, actor: context.admin)
    Targets.append_artifact_chunk!(upload.id, 2, <<1, 2, 255>>, actor: context.admin)
    Targets.complete_artifact!(upload.id, actor: context.admin)
    reference = Targets.artifact_reference!(upload.id, context.target.id, actor: context.admin)

    assert Targets.read_bound_artifact_range!(reference, 1, 3, actor: context.admin) ==
             <<0, 1, 2>>

    assert Targets.read_bound_artifact_range!(reference, 4, 9, actor: context.admin) == <<255>>
    assert Targets.read_bound_artifact_range!(reference, 5, 8, actor: context.admin) == <<>>
    assert Targets.read_bound_artifact_range!(reference, 0, 0, actor: context.admin) == <<>>
    assert {:error, _} = Targets.read_bound_artifact_range(reference, 6, 1, actor: context.admin)

    assert {:error, _} =
             Targets.read_bound_artifact_range(reference, 0, 262_145, actor: context.admin)

    assert Targets.artifact_reference!(upload.id, context.target.id, actor: context.admin) ==
             reference

    previous = Application.get_env(:skopos, :artifact_limits)
    Application.put_env(:skopos, :artifact_limits, %{chunk_bytes: 2})

    on_exit(fn ->
      if previous,
        do: Application.put_env(:skopos, :artifact_limits, previous),
        else: Application.delete_env(:skopos, :artifact_limits)
    end)

    assert {:error, _} = Targets.read_bound_artifact_range(reference, 1, 3, actor: context.admin)
    assert Targets.read_bound_artifact_range!(reference, 1, 2, actor: context.admin) == <<0, 1>>
  end

  test "file ranges reject missing or corrupt chunks rather than returning partial bytes",
       context do
    upload = begin_upload(context, "damaged-range")
    Targets.append_artifact_chunk!(upload.id, 0, <<255, 0>>, actor: context.admin)
    Targets.append_artifact_chunk!(upload.id, 2, <<1, 2, 255>>, actor: context.admin)
    Targets.complete_artifact!(upload.id, actor: context.admin)
    reference = Targets.artifact_reference!(upload.id, context.target.id, actor: context.admin)
    {:ok, id} = Ecto.UUID.dump(upload.id)

    # Storage faults are injected; callers observe rejection through the public file action.
    Skopos.Repo.query!(
      ~s(UPDATE artifact_chunks SET sha256 = $1 WHERE artifact_id = $2 AND "offset" = 2),
      [String.duplicate("0", 64), id]
    )

    assert {:error, error} =
             Targets.read_bound_artifact_range(reference, 1, 3, actor: context.admin)

    assert Exception.message(error) =~ "integrity check failed"

    Skopos.Repo.query!(~s(DELETE FROM artifact_chunks WHERE artifact_id = $1 AND "offset" = 2), [
      id
    ])

    assert {:error, _} = Targets.read_bound_artifact_range(reference, 1, 3, actor: context.admin)
  end

  test "a valid Unicode file name remains usable through its canonical reference", context do
    name = String.duplicate("機", 90)

    upload =
      Targets.begin_artifact!(
        context.target.id,
        name,
        "application/octet-stream",
        5,
        "b55f1659c0645fd1cee6dfa8b3af06795e9da7e48cb65c2b999f896c9f539dbd",
        "unicode-name",
        actor: context.admin
      )

    Targets.append_artifact_chunk!(upload.id, 0, <<255, 0, 1, 2, 255>>, actor: context.admin)
    Targets.complete_artifact!(upload.id, actor: context.admin)
    reference = Targets.artifact_reference!(upload.id, context.target.id, actor: context.admin)
    assert reference["name"] == name

    assert Targets.read_bound_artifact_chunk!(reference, 0, actor: context.admin) ==
             <<255, 0, 1, 2, 255>>
  end

  test "lost acknowledgements can resume the same upload without replacing bytes", context do
    upload = begin_upload(context, "resume-upload")
    assert begin_upload(context, "resume-upload").id == upload.id

    assert {:error, _} =
             Targets.begin_artifact(
               context.target.id,
               "other.bin",
               "application/octet-stream",
               5,
               upload.expected_sha256,
               "resume-upload",
               actor: context.admin
             )

    assert {:error, _} =
             Targets.append_artifact_chunk(upload.id, 1, <<255, 0>>, actor: context.admin)

    Targets.append_artifact_chunk!(upload.id, 0, <<255, 0>>, actor: context.admin)
    retried = Targets.append_artifact_chunk!(upload.id, 0, <<255, 0>>, actor: context.admin)
    assert retried.received_bytes == 2

    assert {:error, _} =
             Targets.append_artifact_chunk(upload.id, 0, <<0, 255>>, actor: context.admin)

    assert Targets.get_artifact!(upload.id, actor: context.admin).received_bytes == 2
    Targets.append_artifact_chunk!(upload.id, 2, <<1, 2, 255>>, actor: context.admin)
    completed = Targets.complete_artifact!(upload.id, actor: context.admin)

    assert Targets.complete_artifact!(upload.id, actor: context.admin).revision ==
             completed.revision

    assert Targets.append_artifact_chunk!(upload.id, 0, <<255, 0>>, actor: context.admin).status ==
             :ready

    assert Targets.read_artifact_chunk!(upload.id, context.target.id, 0, actor: context.admin) ==
             <<255, 0>>
  end

  defp begin_upload(context, key, opts \\ []) do
    Targets.begin_artifact!(
      context.target.id,
      "device.bin",
      "application/octet-stream",
      5,
      "b55f1659c0645fd1cee6dfa8b3af06795e9da7e48cb65c2b999f896c9f539dbd",
      key,
      actor: Keyword.get(opts, :actor, context.admin)
    )
  end

  test "file bytes are scoped to their uploader and exact Target", context do
    owner =
      Accounts.create_user!("artifact-owner@example.invalid", "test-only-password", :operator,
        actor: context.admin
      )

    other =
      Accounts.create_user!("artifact-other@example.invalid", "test-only-password", :operator,
        actor: context.admin
      )

    viewer =
      Accounts.create_user!("artifact-viewer@example.invalid", "test-only-password", :viewer,
        actor: context.admin
      )

    other_target =
      Targets.create_target!("other-host", "host", "custom-os", %{}, nil, actor: context.admin)

    upload = begin_upload(context, "private-upload", actor: owner)
    Targets.append_artifact_chunk!(upload.id, 0, <<255, 0, 1, 2, 255>>, actor: owner)
    Targets.complete_artifact!(upload.id, actor: owner)
    reference = Targets.artifact_reference!(upload.id, context.target.id, actor: owner)

    for actor <- [other, viewer, nil] do
      assert {:error, _} = Targets.get_artifact(upload.id, actor: actor)

      assert {:error, _} =
               Targets.read_artifact_chunk(upload.id, context.target.id, 0, actor: actor)

      assert {:error, _} =
               Targets.append_artifact_chunk(upload.id, 0, <<255, 0, 1, 2, 255>>, actor: actor)

      assert {:error, _} = Targets.complete_artifact(upload.id, actor: actor)
      assert {:error, _} = Targets.revoke_artifact(upload.id, actor: actor)
      assert {:error, _} = Targets.read_bound_artifact_range(reference, 1, 3, actor: actor)
    end

    assert Targets.page_artifacts!(context.target.id, actor: other).results == []
    assert {:error, _} = Targets.read_artifact_chunk(upload.id, other_target.id, 0, actor: owner)

    assert {:error, _} =
             Targets.artifact_by_upload(context.target.id, owner.id, "private-upload",
               actor: owner
             )

    assert Targets.read_artifact_chunk!(upload.id, context.target.id, 0, actor: owner) ==
             <<255, 0, 1, 2, 255>>

    assert Targets.read_bound_artifact_range!(reference, 1, 3, actor: owner) == <<0, 1, 2>>

    for {key, value} <- [
          {"sha256", String.duplicate("0", 64)},
          {"size_bytes", 6},
          {"target_id", other_target.id},
          {"name", "replacement.bin"}
        ] do
      assert {:error, _} =
               Targets.read_bound_artifact_range(Map.put(reference, key, value), 1, 3,
                 actor: owner
               )
    end

    assert {:error, _} = Targets.read_bound_artifact_range(reference, -1, 3, actor: owner)
    assert {:error, _} = Targets.read_bound_artifact_range(reference, 1, -1, actor: owner)

    assert Targets.read_artifact_chunk!(upload.id, context.target.id, 0, actor: context.admin) ==
             <<255, 0, 1, 2, 255>>

    Targets.revoke_artifact!(upload.id, actor: owner)
    assert {:error, _} = Targets.read_bound_artifact_range(reference, 1, 3, actor: owner)
  end

  test "length and digest failures do not publish or replace staged bytes", context do
    previous = Application.get_env(:skopos, :artifact_limits)
    Application.put_env(:skopos, :artifact_limits, %{chunk_bytes: 3, max_size_bytes: 5})

    on_exit(fn ->
      if previous,
        do: Application.put_env(:skopos, :artifact_limits, previous),
        else: Application.delete_env(:skopos, :artifact_limits)
    end)

    digest = "b55f1659c0645fd1cee6dfa8b3af06795e9da7e48cb65c2b999f896c9f539dbd"

    assert {:error, _} =
             Targets.begin_artifact(
               context.target.id,
               "too-big",
               "application/octet-stream",
               6,
               digest,
               "too-big",
               actor: context.admin
             )

    upload = begin_upload(context, "bad-digest")

    assert {:error, _} =
             Targets.append_artifact_chunk(upload.id, 0, <<255, 0, 1, 2>>, actor: context.admin)

    assert {:error, _} = Targets.append_artifact_chunk(upload.id, 0, <<>>, actor: context.admin)
    assert Targets.get_artifact!(upload.id, actor: context.admin).received_bytes == 0
    Targets.append_artifact_chunk!(upload.id, 0, <<255, 0, 1>>, actor: context.admin)

    assert {:error, _} =
             Targets.append_artifact_chunk(upload.id, 3, <<2, 255, 0>>, actor: context.admin)

    Targets.append_artifact_chunk!(upload.id, 3, <<2, 0>>, actor: context.admin)
    assert {:error, error} = Targets.complete_artifact(upload.id, actor: context.admin)
    assert Exception.message(error) =~ "integrity check failed"
    refute Exception.message(error) =~ "<<255"
    current = Targets.get_artifact!(upload.id, actor: context.admin)
    assert current.status == :uploading
    assert is_nil(current.sha256)

    assert {:error, _} =
             Targets.read_artifact_chunk(upload.id, context.target.id, 0, actor: context.admin)
  end

  test "expiry is persisted with the upload and expires ready and interrupted files", context do
    previous = Application.get_env(:skopos, :artifact_limits)
    Application.put_env(:skopos, :artifact_limits, %{lifetime_seconds: 1})

    on_exit(fn ->
      if previous,
        do: Application.put_env(:skopos, :artifact_limits, previous),
        else: Application.delete_env(:skopos, :artifact_limits)
    end)

    ready = begin_upload(context, "expires-ready")
    interrupted = begin_upload(context, "expires-interrupted")
    request_id = Ecto.UUID.generate()

    incoming =
      Targets.begin_artifact_receipt!(
        context.target.id,
        "expires-incoming.bin",
        "application/octet-stream",
        "expires-incoming",
        %{request_id: request_id},
        actor: context.admin
      )

    Targets.append_artifact_chunk!(incoming.id, 0, <<255, 0>>, actor: context.admin)
    Targets.append_artifact_chunk!(ready.id, 0, <<255, 0, 1, 2, 255>>, actor: context.admin)
    Targets.complete_artifact!(ready.id, actor: context.admin)
    reference = Targets.artifact_reference!(ready.id, context.target.id, actor: context.admin)
    Targets.append_artifact_chunk!(interrupted.id, 0, <<255, 0>>, actor: context.admin)

    for upload <- [ready, interrupted, incoming] do
      assert_enqueued(worker: Skopos.Targets.Artifact.ExpiryWorker, args: %{id: upload.id})
      assert {:error, _} = Targets.expire_artifact(upload.id, actor: context.admin)
    end

    Process.sleep(1_050)

    assert {:error, _} =
             Targets.read_artifact_chunk(ready.id, context.target.id, 0, actor: context.admin)

    assert {:error, _} =
             Targets.read_bound_artifact_range(reference, 1, 3, actor: context.admin)

    assert {:error, _} =
             Targets.append_artifact_chunk(interrupted.id, 2, <<1, 2, 255>>, actor: context.admin)

    assert {:error, _} = Targets.complete_artifact_receipt(incoming.id, actor: context.admin)

    for upload <- [ready, interrupted, incoming] do
      assert :ok = perform_job(Skopos.Targets.Artifact.ExpiryWorker, %{id: upload.id})
      assert Targets.get_artifact!(upload.id, actor: context.admin).status == :expired
      assert :ok = perform_job(Skopos.Targets.Artifact.ExpiryWorker, %{id: upload.id})
    end

    assert Targets.get_artifact!(incoming.id, actor: context.admin).request_id == request_id
  end

  test "receipt provenance cannot be reassigned by reusing a receipt key", context do
    request_id = Ecto.UUID.generate()

    receipt =
      Targets.begin_artifact_receipt!(
        context.target.id,
        "tracked.bin",
        "application/octet-stream",
        "tracked-reply",
        %{request_id: request_id},
        actor: context.admin
      )

    assert {:error, _} =
             Targets.begin_artifact_receipt(
               context.target.id,
               "tracked.bin",
               "application/octet-stream",
               "tracked-reply",
               %{request_id: Ecto.UUID.generate()},
               actor: context.admin
             )

    Targets.append_artifact_chunk!(receipt.id, 0, <<255, 0, 1, 2, 255>>, actor: context.admin)
    ready = Targets.complete_artifact_receipt!(receipt.id, actor: context.admin)
    assert ready.request_id == request_id
    disposed = Targets.revoke_artifact!(receipt.id, actor: context.admin)
    assert disposed.request_id == request_id
    assert disposed.status == :revoked
  end

  test "a failed progress write rolls back the received chunk", context do
    upload = begin_upload(context, "failed-progress")
    # Database fault fixture; results and retry are observed through public actions.
    Skopos.Repo.query!("""
    CREATE FUNCTION pg_temp.reject_artifact_progress() RETURNS trigger LANGUAGE plpgsql AS $$
    BEGIN
      IF NEW.received_bytes <> OLD.received_bytes THEN
        RAISE EXCEPTION 'injected artifact progress persistence failure';
      END IF;
      RETURN NEW;
    END;
    $$;
    """)

    Skopos.Repo.query!("""
    CREATE TRIGGER reject_artifact_progress BEFORE UPDATE ON artifacts
    FOR EACH ROW EXECUTE FUNCTION pg_temp.reject_artifact_progress();
    """)

    assert {:error, _} =
             Targets.append_artifact_chunk(upload.id, 0, <<1, 2>>, actor: context.admin)

    current = Targets.get_artifact!(upload.id, actor: context.admin)
    assert current.received_bytes == 0
    assert current.status == :uploading
    Skopos.Repo.query!("DROP TRIGGER reject_artifact_progress ON artifacts")

    Targets.append_artifact_chunk!(upload.id, 0, <<255, 0>>, actor: context.admin)
    Targets.append_artifact_chunk!(upload.id, 2, <<1, 2, 255>>, actor: context.admin)
    assert Targets.complete_artifact!(upload.id, actor: context.admin).status == :ready

    assert Targets.read_artifact_chunk!(upload.id, context.target.id, 0, actor: context.admin) ==
             <<255, 0>>
  end

  test "failed publication and revocation preserve the previous readable state", context do
    upload = begin_upload(context, "failed-publication")
    Targets.append_artifact_chunk!(upload.id, 0, <<255, 0, 1, 2, 255>>, actor: context.admin)
    # Reject only status persistence; chunk removal and publication must roll back with it.
    Skopos.Repo.query!("""
    CREATE FUNCTION pg_temp.reject_artifact_status() RETURNS trigger LANGUAGE plpgsql AS $$
    BEGIN
      IF NEW.status <> OLD.status THEN
        RAISE EXCEPTION 'injected artifact status persistence failure';
      END IF;
      RETURN NEW;
    END;
    $$;
    """)

    reject_status = """
    CREATE TRIGGER reject_artifact_status BEFORE UPDATE ON artifacts
    FOR EACH ROW EXECUTE FUNCTION pg_temp.reject_artifact_status();
    """

    Skopos.Repo.query!(reject_status)
    assert {:error, _} = Targets.complete_artifact(upload.id, actor: context.admin)
    current = Targets.get_artifact!(upload.id, actor: context.admin)
    assert current.status == :uploading
    assert is_nil(current.sha256)

    assert {:error, _} =
             Targets.read_artifact_chunk(upload.id, context.target.id, 0, actor: context.admin)

    Skopos.Repo.query!("DROP TRIGGER reject_artifact_status ON artifacts")
    Targets.complete_artifact!(upload.id, actor: context.admin)
    Skopos.Repo.query!(reject_status)
    assert {:error, _} = Targets.revoke_artifact(upload.id, actor: context.admin)

    assert Targets.read_artifact_chunk!(upload.id, context.target.id, 0, actor: context.admin) ==
             <<255, 0, 1, 2, 255>>

    Skopos.Repo.query!("DROP TRIGGER reject_artifact_status ON artifacts")
    revoked = Targets.revoke_artifact!(upload.id, actor: context.admin)
    assert Targets.revoke_artifact!(upload.id, actor: context.admin).revision == revoked.revision
  end

  for fault <- [:missing_row, :storage_error] do
    @tag expiry_job_fault: fault
    test "a file is not accepted when durable cleanup returns #{fault}", context do
      rejection =
        case context.expiry_job_fault do
          :missing_row -> "RETURN NULL;"
          :storage_error -> "RAISE EXCEPTION 'injected artifact cleanup persistence failure';"
        end

      # Local DB fault fixture at the intent persistence seam, no remote operation is involved.
      Skopos.Repo.query!("""
      CREATE FUNCTION pg_temp.reject_artifact_expiry_job() RETURNS trigger LANGUAGE plpgsql AS $$
      BEGIN
        IF NEW.worker = 'Skopos.Targets.Artifact.ExpiryWorker' THEN
          #{rejection}
        END IF;
        RETURN NEW;
      END;
      $$;
      """)

      Skopos.Repo.query!("""
      CREATE TRIGGER reject_artifact_expiry_job BEFORE INSERT ON oban_jobs
      FOR EACH ROW EXECUTE FUNCTION pg_temp.reject_artifact_expiry_job();
      """)

      upload = fn ->
        Targets.begin_artifact(
          context.target.id,
          "device.bin",
          "application/octet-stream",
          5,
          "b55f1659c0645fd1cee6dfa8b3af06795e9da7e48cb65c2b999f896c9f539dbd",
          "failed-cleanup",
          actor: context.admin
        )
      end

      receipt = fn ->
        Targets.begin_artifact_receipt(
          context.target.id,
          "response.bin",
          "application/octet-stream",
          "failed-incoming-cleanup",
          actor: context.admin
        )
      end

      case context.expiry_job_fault do
        :missing_row ->
          assert_raise Ash.Error.Unknown, upload
          assert_raise Ash.Error.Unknown, receipt

        :storage_error ->
          assert {:error, _} = upload.()
          assert {:error, _} = receipt.()
      end

      assert Targets.page_artifacts!(context.target.id, actor: context.admin).results == []
      refute_enqueued(worker: Skopos.Targets.Artifact.ExpiryWorker)

      Skopos.Repo.query!("DROP TRIGGER reject_artifact_expiry_job ON oban_jobs")
      upload = begin_upload(context, "failed-cleanup")
      assert upload.status == :uploading
      assert_enqueued(worker: Skopos.Targets.Artifact.ExpiryWorker, args: %{id: upload.id})
      receipt = begin_receipt(context, "failed-incoming-cleanup")
      assert receipt.status == :receiving
      assert_enqueued(worker: Skopos.Targets.Artifact.ExpiryWorker, args: %{id: receipt.id})
    end
  end
end
