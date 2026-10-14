defmodule SkoposCLI.FileAPITest do
  use SkoposWeb.ConnCase, async: false

  import ExUnit.CaptureIO

  alias Skopos.{Accounts, Targets}
  alias SkoposCLI.{CLI, Config}

  @bytes <<255, 0, 1, 2, 255>>
  @digest "b55f1659c0645fd1cee6dfa8b3af06795e9da7e48cb65c2b999f896c9f539dbd"

  setup do
    admin = Accounts.bootstrap!("file-cli@example.invalid", "test-password", "test-password")
    token = Accounts.sign_in!(admin.email, "test-password").__metadata__.token
    target = Targets.create_target!("file-host", "host", "custom-os", %{}, nil, actor: admin)
    root = Path.join(System.tmp_dir!(), "skopos-file-cli-#{System.unique_integer([:positive])}")
    config_path = Path.join(root, "config.json")
    :ok = Config.save(%{"server" => "https://skopos.example", "token" => token}, config_path)
    path = Path.join(root, "firmware.bin")
    File.write!(path, @bytes)
    on_exit(fn -> File.rm_rf(root) end)
    stub = {__MODULE__, make_ref()}
    Req.Test.stub(stub, &SkoposWeb.Endpoint.call(&1, SkoposWeb.Endpoint.init([])))

    %{
      admin: admin,
      target: target,
      root: root,
      path: path,
      stub: stub,
      runtime: [config_path: config_path, request_options: [plug: {Req.Test, stub}]]
    }
  end

  test "CLI uploads binary bytes through the authenticated API and reports the published digest",
       context do
    output =
      capture_io(fn ->
        assert CLI.run(
                 [
                   "file",
                   "upload",
                   context.target.id,
                   "--file",
                   context.path,
                   "--upload-key",
                   "cli-upload"
                 ],
                 context.runtime
               ) == 0
      end)

    assert %{"outcome" => "succeeded", "data" => file} = Jason.decode!(output)
    assert file["target_id"] == context.target.id
    assert file["status"] == "ready"
    assert file["sha256"] == @digest
    assert file["size_bytes"] == 5
    refute output =~ context.path

    shown =
      capture_io(fn ->
        assert CLI.run(["file", "show", context.target.id, file["id"]], context.runtime) == 0
      end)

    assert get_in(Jason.decode!(shown), ["data", "sha256"]) == @digest
  end

  test "CLI downloads exactly the published binary into a private local file", context do
    uploaded =
      capture_io(fn ->
        assert CLI.run(
                 [
                   "file",
                   "upload",
                   context.target.id,
                   "--file",
                   context.path,
                   "--upload-key",
                   "cli-download"
                 ],
                 context.runtime
               ) == 0
      end)
      |> Jason.decode!()
      |> Map.fetch!("data")

    destination = Path.join(context.root, "download.bin")

    output =
      capture_io(fn ->
        assert CLI.run(
                 ["file", "download", context.target.id, uploaded["id"], "--output", destination],
                 context.runtime
               ) == 0
      end)

    assert %{"outcome" => "succeeded", "data" => %{"sha256" => @digest}} = Jason.decode!(output)
    assert File.read!(destination) == @bytes
    assert File.stat!(destination).mode == 0o100600
  end

  test "a lost chunk acknowledgement stops once and a fresh CLI resumes the persisted offset",
       context do
    previous = Application.get_env(:skopos, :artifact_limits)
    Application.put_env(:skopos, :artifact_limits, %{chunk_bytes: 2})

    on_exit(fn ->
      if previous,
        do: Application.put_env(:skopos, :artifact_limits, previous),
        else: Application.delete_env(:skopos, :artifact_limits)
    end)

    attempts = start_supervised!({Agent, fn -> 0 end})

    Req.Test.stub(context.stub, fn conn ->
      response = SkoposWeb.Endpoint.call(conn, SkoposWeb.Endpoint.init([]))

      if conn.method == "PUT" do
        assert response.status == 200
        Agent.update(attempts, &(&1 + 1))
        Req.Test.transport_error(response, :timeout)
      else
        response
      end
    end)

    error =
      capture_io(:stderr, fn ->
        assert CLI.run(
                 [
                   "file",
                   "upload",
                   context.target.id,
                   "--file",
                   context.path,
                   "--upload-key",
                   "lost-chunk"
                 ],
                 context.runtime
               ) == 5
      end)

    assert %{"outcome" => "unknown", "file_id" => id, "offset" => 0} = Jason.decode!(error)
    assert Agent.get(attempts, & &1) == 1
    refute error =~ "Bearer"

    Req.Test.stub(context.stub, &SkoposWeb.Endpoint.call(&1, SkoposWeb.Endpoint.init([])))

    shown =
      capture_io(fn ->
        assert CLI.run(["file", "show", context.target.id, id], context.runtime) == 0
      end)

    assert get_in(Jason.decode!(shown), ["data", "received_bytes"]) == 2

    output =
      capture_io(fn ->
        assert CLI.run(
                 ["file", "upload", context.target.id, "--file", context.path, "--resume", id],
                 context.runtime
               ) == 0
      end)

    assert %{"data" => %{"id" => ^id, "status" => "ready", "sha256" => @digest}} =
             Jason.decode!(output)
  end

  test "CLI reads incoming progress and downloads only the completed receipt", context do
    request_id = Ecto.UUID.generate()

    receipt =
      Targets.begin_artifact_receipt!(
        context.target.id,
        "response.bin",
        "application/octet-stream",
        "incoming-cli",
        %{request_id: request_id},
        actor: context.admin
      )

    Targets.append_artifact_chunk!(receipt.id, 0, @bytes, actor: context.admin)

    shown =
      capture_io(fn ->
        assert CLI.run(["file", "show", context.target.id, receipt.id], context.runtime) == 0
      end)
      |> Jason.decode!()
      |> Map.fetch!("data")

    assert shown["status"] == "receiving"
    assert shown["request_id"] == request_id
    assert is_nil(shown["size_bytes"])
    destination = Path.join(context.root, "response.bin")

    capture_io(:stderr, fn ->
      assert CLI.run(
               ["file", "download", context.target.id, receipt.id, "--output", destination],
               context.runtime
             ) == 4
    end)

    refute File.exists?(destination)
    Targets.complete_artifact_receipt!(receipt.id, actor: context.admin)

    output =
      capture_io(fn ->
        assert CLI.run(
                 ["file", "download", context.target.id, receipt.id, "--output", destination],
                 context.runtime
               ) == 0
      end)

    assert %{"outcome" => "succeeded", "data" => %{"sha256" => @digest}} = Jason.decode!(output)
    assert File.read!(destination) == @bytes
    assert File.stat!(destination).mode == 0o100600
  end

  test "CLI lists received files with their original request identity", context do
    request_id = Ecto.UUID.generate()

    receipt =
      Targets.begin_artifact_receipt!(
        context.target.id,
        "tracked.bin",
        "application/octet-stream",
        "tracked-cli",
        %{request_id: request_id},
        actor: context.admin
      )

    listed =
      capture_io(fn ->
        assert CLI.run(["file", "list", context.target.id], context.runtime) == 0
      end)
      |> Jason.decode!()
      |> Map.fetch!("data")

    assert [%{"id" => id, "request_id" => ^request_id, "status" => "receiving"}] = listed
    assert id == receipt.id
  end

  test "a lost creation acknowledgement retains the key and a fresh CLI recovers the same file",
       context do
    attempts = start_supervised!({Agent, fn -> 0 end})

    Req.Test.stub(context.stub, fn conn ->
      response = SkoposWeb.Endpoint.call(conn, SkoposWeb.Endpoint.init([]))

      if conn.method == "POST" and String.ends_with?(conn.request_path, "/files") do
        assert response.status == 201
        Agent.update(attempts, &(&1 + 1))
        Req.Test.transport_error(response, :timeout)
      else
        response
      end
    end)

    error =
      capture_io(:stderr, fn ->
        assert CLI.run(
                 [
                   "file",
                   "upload",
                   context.target.id,
                   "--file",
                   context.path,
                   "--upload-key",
                   "lost-create"
                 ],
                 context.runtime
               ) == 5
      end)

    assert %{"outcome" => "unknown", "upload_key" => "lost-create"} = Jason.decode!(error)
    assert Agent.get(attempts, & &1) == 1
    Req.Test.stub(context.stub, &SkoposWeb.Endpoint.call(&1, SkoposWeb.Endpoint.init([])))

    before =
      capture_io(fn ->
        assert CLI.run(["file", "list", context.target.id], context.runtime) == 0
      end)
      |> Jason.decode!()
      |> Map.fetch!("data")

    assert [%{"status" => "uploading", "id" => id}] = before

    output =
      capture_io(fn ->
        assert CLI.run(
                 [
                   "file",
                   "upload",
                   context.target.id,
                   "--file",
                   context.path,
                   "--upload-key",
                   "lost-create"
                 ],
                 context.runtime
               ) == 0
      end)

    assert get_in(Jason.decode!(output), ["data", "id"]) == id
  end

  test "corrupt downloads and existing destinations cannot publish or overwrite local bytes",
       context do
    uploaded =
      capture_io(fn ->
        assert CLI.run(
                 [
                   "file",
                   "upload",
                   context.target.id,
                   "--file",
                   context.path,
                   "--upload-key",
                   "corrupt-download"
                 ],
                 context.runtime
               ) == 0
      end)
      |> Jason.decode!()
      |> Map.fetch!("data")

    destination = Path.join(context.root, "rejected.bin")

    Req.Test.stub(context.stub, fn conn ->
      response = SkoposWeb.Endpoint.call(conn, SkoposWeb.Endpoint.init([]))

      if conn.method == "GET" and String.ends_with?(conn.request_path, "/chunks/0"),
        do: %{response | resp_body: <<255, 0, 1, 2, 0>>},
        else: response
    end)

    error =
      capture_io(:stderr, fn ->
        assert CLI.run(
                 ["file", "download", context.target.id, uploaded["id"], "--output", destination],
                 context.runtime
               ) == 4
      end)

    assert error =~ "integrity check failed"
    refute File.exists?(destination)
    assert Path.wildcard(destination <> ".part-*") == []

    File.write!(destination, "existing bytes")

    error =
      capture_io(:stderr, fn ->
        assert CLI.run(
                 ["file", "download", context.target.id, uploaded["id"], "--output", destination],
                 context.runtime
               ) == 4
      end)

    assert error =~ "already exists"
    assert File.read!(destination) == "existing bytes"
  end

  test "empty downloads still pass server expiry authorization before creating a local file",
       context do
    previous = Application.get_env(:skopos, :artifact_limits)
    Application.put_env(:skopos, :artifact_limits, %{lifetime_seconds: 1})

    on_exit(fn ->
      if previous,
        do: Application.put_env(:skopos, :artifact_limits, previous),
        else: Application.delete_env(:skopos, :artifact_limits)
    end)

    File.write!(context.path, "")

    uploaded =
      capture_io(fn ->
        assert CLI.run(
                 [
                   "file",
                   "upload",
                   context.target.id,
                   "--file",
                   context.path,
                   "--upload-key",
                   "empty-expiry"
                 ],
                 context.runtime
               ) == 0
      end)
      |> Jason.decode!()
      |> Map.fetch!("data")

    destination = Path.join(context.root, "empty.bin")

    capture_io(fn ->
      assert CLI.run(
               ["file", "download", context.target.id, uploaded["id"], "--output", destination],
               context.runtime
             ) == 0
    end)

    assert File.read!(destination) == ""
    File.rm!(destination)
    Process.sleep(1_100)

    error =
      capture_io(:stderr, fn ->
        assert CLI.run(
                 ["file", "download", context.target.id, uploaded["id"], "--output", destination],
                 context.runtime
               ) == 4
      end)

    assert %{"http_status" => 422} = Jason.decode!(error)
    refute File.exists?(destination)
  end

  test "an invalid chunk acknowledgement is unknown and is never automatically replayed",
       context do
    attempts = start_supervised!({Agent, fn -> 0 end})

    Req.Test.stub(context.stub, fn conn ->
      response = SkoposWeb.Endpoint.call(conn, SkoposWeb.Endpoint.init([]))

      if conn.method == "PUT" do
        Agent.update(attempts, &(&1 + 1))
        %{response | resp_body: "{invalid JSON"}
      else
        response
      end
    end)

    error =
      capture_io(:stderr, fn ->
        assert CLI.run(
                 [
                   "file",
                   "upload",
                   context.target.id,
                   "--file",
                   context.path,
                   "--upload-key",
                   "invalid-ack"
                 ],
                 context.runtime
               ) == 15
      end)

    assert %{"outcome" => "unknown", "file_id" => id, "offset" => 0} = Jason.decode!(error)
    assert Agent.get(attempts, & &1) == 1
    refute error =~ "invalid JSON"
    Req.Test.stub(context.stub, &SkoposWeb.Endpoint.call(&1, SkoposWeb.Endpoint.init([])))

    output =
      capture_io(fn ->
        assert CLI.run(
                 ["file", "upload", context.target.id, "--file", context.path, "--resume", id],
                 context.runtime
               ) == 0
      end)

    assert get_in(Jason.decode!(output), ["data", "sha256"]) == @digest
  end

  test "resume rejects changed local content before appending or publishing any more bytes",
       context do
    staged =
      Targets.begin_artifact!(
        context.target.id,
        "firmware.bin",
        "application/octet-stream",
        5,
        @digest,
        "changed-source",
        actor: context.admin
      )

    Targets.append_artifact_chunk!(staged.id, 0, <<255, 0>>, actor: context.admin)
    File.write!(context.path, <<0, 0, 1, 2, 255>>)

    capture_io(:stderr, fn ->
      assert CLI.run(
               [
                 "file",
                 "upload",
                 context.target.id,
                 "--file",
                 context.path,
                 "--resume",
                 staged.id
               ],
               context.runtime
             ) == 4
    end)

    shown =
      capture_io(fn ->
        assert CLI.run(["file", "show", context.target.id, staged.id], context.runtime) == 0
      end)
      |> Jason.decode!()
      |> Map.fetch!("data")

    assert shown["status"] == "uploading"
    assert shown["received_bytes"] == 2
  end
end
