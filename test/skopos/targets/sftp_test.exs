defmodule Skopos.Targets.SFTPTest do
  use Skopos.DataCase, async: false

  alias Skopos.{Accounts, Providers, Targets}
  alias Skopos.Providers.Target
  alias Skopos.Targets.TargetRequest.Request
  @password "correct horse battery staple"
  @bytes <<0, 255, 1, 128, 10>>

  defmodule Backend do
    @behaviour :ssh_sftpd_file_api
    for {name, arity} <- [
          delete: 2,
          del_dir: 2,
          get_cwd: 1,
          is_dir: 2,
          list_dir: 2,
          make_dir: 2,
          position: 3,
          read_file_info: 2,
          read_link: 2,
          read_link_info: 2,
          write_file_info: 3
        ] do
      args = Macro.generate_arguments(arity, __MODULE__)
      @impl true
      def unquote(name)(unquote_splicing(args)),
        do: apply(:ssh_sftpd_file, unquote(name), [unquote_splicing(args)])
    end

    @impl true
    def make_symlink(target, link, state) do
      if Agent.get(state, &Map.get(&1, :openssh_symlink, false)),
        do: :ssh_sftpd_file.make_symlink(link, target, state),
        else: :ssh_sftpd_file.make_symlink(target, link, state)
    end

    @impl true
    def open(path, flags, state) do
      result = :ssh_sftpd_file.open(path, flags, state)
      Agent.update(state, fn value -> %{value | opens: value.opens + 1} end)
      result
    end

    @impl true
    def close(handle, state), do: :ssh_sftpd_file.close(handle, state)

    @impl true
    def read(handle, count, state) do
      result = :ssh_sftpd_file.read(handle, count, state)

      control =
        Agent.get_and_update(state, fn value -> {value, %{value | reads: value.reads + 1}} end)

      Process.sleep(control.read_delay)
      if control.read_drop, do: exit(:kill)
      result
    end

    @impl true
    def write(handle, data, state) do
      result = :ssh_sftpd_file.write(handle, data, state)
      after_write(result, state)
    end

    @impl true
    def rename(source, destination, state) do
      result = :ssh_sftpd_file.rename(source, destination, state)
      after_write(result, state)
    end

    defp after_write(result, state) do
      control =
        Agent.get_and_update(state, fn value -> {value, %{value | writes: value.writes + 1}} end)

      Process.sleep(control.write_delay)

      if control.write_drop,
        do: exit(:kill)

      result
    end
  end

  setup_all do
    directory = Path.join(System.tmp_dir!(), "skopos-sftp-#{System.unique_integer([:positive])}")
    File.mkdir_p!(directory)
    host_key = :public_key.generate_key({:rsa, 2048, 65537})
    private = :public_key.pem_entry_encode(:RSAPrivateKey, host_key)
    File.write!(Path.join(directory, "ssh_host_rsa_key"), :public_key.pem_encode([private]))
    File.chmod!(Path.join(directory, "ssh_host_rsa_key"), 0o600)
    File.write!(Path.join(directory, "download.bin"), @bytes)

    {:ok, agent} =
      Agent.start_link(fn ->
        %{
          opens: 0,
          reads: 0,
          writes: 0,
          read_delay: 0,
          write_delay: 0,
          read_drop: false,
          write_drop: false
        }
      end)

    {:ok, daemon} =
      :ssh.daemon(0,
        system_dir: String.to_charlist(directory),
        user_passwords: [{~c"tester", ~c"secret"}],
        auth_methods: ~c"password",
        subsystems: [
          :ssh_sftpd.subsystem_spec(
            root: String.to_charlist(directory),
            file_handler: {Backend, agent}
          )
        ]
      )

    {:ok, info} = :ssh.daemon_info(daemon)
    endpoint = "ssh://127.0.0.1:#{Keyword.fetch!(info, :port)}"

    fingerprint =
      host_key
      |> :ssh_file.extract_public_key()
      |> then(&:ssh.hostkey_fingerprint(:sha256, &1))
      |> to_string()

    on_exit(fn ->
      :ssh.stop_daemon(daemon)
      File.rm_rf!(directory)
    end)

    %{directory: directory, endpoint: endpoint, fingerprint: fingerprint, agent: agent}
  end

  setup context do
    Agent.update(context.agent, fn _ ->
      %{
        opens: 0,
        reads: 0,
        writes: 0,
        read_delay: 0,
        write_delay: 0,
        read_drop: false,
        write_drop: false
      }
    end)

    context =
      if context[:openssh_symlink] do
        Agent.update(context.agent, &Map.put(&1, :openssh_symlink, true))

        {:ok, daemon} =
          :ssh.daemon(0,
            system_dir: String.to_charlist(context.directory),
            id_string: ~c"OpenSSH_9.9",
            user_passwords: [{~c"tester", ~c"secret"}],
            auth_methods: ~c"password",
            subsystems: [
              :ssh_sftpd.subsystem_spec(
                root: String.to_charlist(context.directory),
                file_handler: {Backend, context.agent}
              )
            ]
          )

        on_exit(fn -> :ssh.stop_daemon(daemon) end)
        {:ok, info} = :ssh.daemon_info(daemon)
        %{context | endpoint: "ssh://127.0.0.1:#{Keyword.fetch!(info, :port)}"}
      else
        context
      end

    admin = Accounts.bootstrap!("sftp-admin@example.com", @password, @password)

    operator =
      Accounts.create_user!("sftp-operator@example.com", @password, :operator, actor: admin)

    viewer = Accounts.create_user!("sftp-viewer@example.com", @password, :viewer, actor: admin)
    adapter = Map.get(context, :adapter, "ssh")

    provider =
      Providers.create_provider!(
        "SFTP " <> adapter,
        :target,
        adapter,
        %{
          "host_key_fingerprints" => %{context.endpoint => context.fingerprint},
          "connect_timeout_ms" => 2000,
          "operation_timeout_ms" => Map.get(context, :operation_timeout_ms, 1000)
        },
        %{"username" => "tester", "auth_method" => "password", "password" => "secret"},
        actor: admin
      )
      |> then(&Providers.enable_provider!(&1, &1.revision, actor: admin))

    target =
      Targets.create_target!(
        "SFTP peer",
        Map.get(context, :kind, "network_device"),
        Map.get(context, :type, "custom-network-device"),
        %{},
        nil,
        actor: admin
      )

    method =
      Targets.create_access_method!(
        target.id,
        provider.id,
        "same SSH Method",
        Map.get(context, :protocol, "ssh"),
        context.endpoint,
        provider.revision,
        100,
        ["request.ssh.observe", "request.ssh.effect"],
        actor: admin
      )
      |> then(&Targets.check_access_method!(&1.id, &1.revision, %{}, actor: admin))

    assert method.check_status == :passed

    Map.merge(context, %{
      admin: admin,
      operator: operator,
      viewer: viewer,
      provider: provider,
      target: target,
      method: method
    })
  end

  test "generic SSH subsystem exchanges caller-supplied SFTP protocol frames", context do
    initialize = <<5::32, 1, 3::32>>

    result =
      request(context, :effect, "subsystem.session", %{
        "subsystem" => "sftp",
        "steps" => [
          %{"op" => "send", "data" => Base.encode64(initialize)},
          %{"op" => "receive", "until" => %{"bytes" => 9}},
          %{"op" => "close"}
        ]
      })
      |> Targets.clear_target_request!(actor: context.operator)
      |> Targets.dispatch_target_effect!(%{}, actor: context.operator, authorize?: false)

    assert result.status == :applied
    assert {:ok, <<5::32, 2, 3::32>>} = Base.decode64(Enum.at(result.details["steps"], 1)["data"])
    assert result.details["steps"] |> List.last() |> Map.fetch!("op") == "close"
    assert Agent.get(context.agent, & &1.opens) == 0
  end

  test "native metadata preserves the server attributes without an exec command", context do
    result =
      request(context, :observation, "sftp.read_file_info", %{"path" => "/download.bin"})
      |> Targets.clear_target_request!(actor: context.operator)
      |> Targets.dispatch_target_observation!(%{}, actor: context.operator)

    assert result.facts["attributes"]["size"] == 5
    assert result.facts["attributes"]["type"] == "regular"
    assert is_integer(result.facts["attributes"]["mode"])
    assert is_list(result.facts["attributes"]["mtime"])
    assert result.evidence == [%{"source" => "sftp", "path" => "/download.bin"}]
    assert Agent.get(context.agent, & &1.opens) == 0

    resolved =
      request(context, :observation, "sftp.real_path", %{"path" => "/download.bin"})
      |> Targets.clear_target_request!(actor: context.operator)
      |> Targets.dispatch_target_observation!(%{}, actor: context.operator)

    assert resolved.facts["paths"] == ["/download.bin"]
  end

  test "fresh native metadata is verification evidence without a recovery verdict", context do
    name = "fresh-" <> Ecto.UUID.generate()
    local = Path.join(context.directory, name)
    File.write!(local, @bytes)

    verify = fn ->
      request(context, :verification, "sftp.read_file_info", %{"path" => "/" <> name})
      |> Targets.clear_target_request!(actor: context.operator)
      |> Targets.dispatch_target_verification!(%{}, actor: context.operator)
    end

    first = verify.()
    assert first.status == :unknown
    assert first.facts["attributes"]["size"] == 5
    File.write!(local, "different")
    second = verify.()
    assert second.status == :unknown
    assert second.facts["attributes"]["size"] == 9
  end

  test "native directory creation and removal use effect authority", context do
    path = "/directory-" <> Ecto.UUID.generate()

    for operation <- ["sftp.make_dir", "sftp.del_dir"] do
      assert {:error, _} =
               request(context, :observation, operation, %{"path" => path})
               |> Targets.clear_target_request(actor: context.operator)
    end

    result =
      request(context, :effect, "sftp.make_dir", %{"path" => path})
      |> Targets.clear_target_request!(actor: context.operator)
      |> Targets.dispatch_target_effect!(%{}, actor: context.operator, authorize?: false)

    assert result.status == :applied

    observed =
      request(context, :observation, "sftp.read_file_info", %{"path" => path})
      |> Targets.clear_target_request!(actor: context.operator)
      |> Targets.dispatch_target_observation!(%{}, actor: context.operator)

    assert observed.facts["attributes"]["type"] == "directory"

    removed =
      request(context, :effect, "sftp.del_dir", %{"path" => path})
      |> Targets.clear_target_request!(actor: context.operator)
      |> Targets.dispatch_target_effect!(%{}, actor: context.operator, authorize?: false)

    assert removed.status == :applied
    refute File.dir?(Path.join(context.directory, String.trim_leading(path, "/")))
  end

  @tag openssh_symlink: true
  test "OpenSSH link creation preserves the requested path and target", context do
    target = "/download.bin"
    link = "/openssh-link-" <> Ecto.UUID.generate()

    assert request(context, :effect, "sftp.make_symlink", %{"path" => link, "target" => target})
           |> Targets.clear_target_request!(actor: context.operator)
           |> Targets.dispatch_target_effect!(%{}, actor: context.operator, authorize?: false)
           |> Map.fetch!(:status) == :applied

    observed =
      request(context, :observation, "sftp.read_link", %{"path" => link})
      |> Targets.clear_target_request!(actor: context.operator)
      |> Targets.dispatch_target_observation!(%{}, actor: context.operator)

    assert observed.facts["target"] == target
  end

  test "native rename link and permission operations preserve exact paths", context do
    suffix = Ecto.UUID.generate()
    source = "/source-" <> suffix <> ".bin"
    moved = "/moved-" <> suffix <> ".bin"
    link = "/link-" <> suffix
    File.write!(Path.join(context.directory, String.trim_leading(source, "/")), @bytes)

    apply_native = fn operation, parameters ->
      request(context, :effect, operation, parameters)
      |> Targets.clear_target_request!(actor: context.operator)
      |> Targets.dispatch_target_effect!(%{}, actor: context.operator, authorize?: false)
    end

    observe_native = fn operation, path ->
      request(context, :observation, operation, %{"path" => path})
      |> Targets.clear_target_request!(actor: context.operator)
      |> Targets.dispatch_target_observation!(%{}, actor: context.operator)
    end

    assert apply_native.("sftp.rename", %{"path" => source, "destination" => moved}).status ==
             :applied

    assert apply_native.("sftp.make_symlink", %{
             "path" => link,
             "target" => moved
           }).status == :applied

    assert observe_native.("sftp.read_link", link).facts["target"] == moved

    assert observe_native.("sftp.read_link_info", link).facts["attributes"]["type"] == "symlink"
    assert observe_native.("sftp.read_file_info", link).facts["attributes"]["size"] == 5

    assert apply_native.("sftp.write_file_info", %{
             "path" => moved,
             "attributes" => %{"mode" => 0o600}
           }).status == :applied

    mode = observe_native.("sftp.read_file_info", moved).facts["attributes"]["mode"]
    assert Bitwise.band(mode, 0o777) == 0o600

    for path <- [link, moved],
        do: assert(apply_native.("sftp.delete", %{"path" => path}).status == :applied)

    refute File.exists?(Path.join(context.directory, String.trim_leading(moved, "/")))
  end

  test "native directory observations stop at explicit entry and byte limits", context do
    suffix = Ecto.UUID.generate()
    relative = "listing-" <> suffix
    folder = Path.join(context.directory, relative)
    File.mkdir_p!(folder)
    File.write!(Path.join(folder, "one.bin"), @bytes)
    File.write!(Path.join(folder, "two.bin"), @bytes)

    list = fn entries, bytes ->
      request(context, :observation, "sftp.list_dir", %{
        "path" => "/" <> relative,
        "max_entries" => entries,
        "max_bytes" => bytes,
        "response_file" => %{"name" => "directory.json", "media_type" => "application/json"}
      })
      |> Targets.clear_target_request!(actor: context.operator)
      |> Targets.dispatch_target_observation!(%{}, actor: context.operator)
    end

    complete = list.(10, 4_096).facts
    assert complete["completion_reason"] == "eof"
    entries = directory_entries(context, complete["file"])
    assert Enum.sort(Enum.map(entries, & &1["name"])) == ["one.bin", "two.bin"]
    assert Enum.all?(entries, &(&1["attributes"]["size"] == 5))
    assert complete["entry_count"] == 2
    refute Map.has_key?(complete, "entries")

    limited = list.(1, 4_096).facts
    assert limited["completion_reason"] == "entry_limit"
    assert length(directory_entries(context, limited["file"])) == 1

    assert Targets.get_artifact!(limited["file"]["id"], actor: context.operator).completion_reason ==
             :entry_limit

    byte_limited = list.(10, 2).facts
    assert byte_limited["completion_reason"] == "byte_limit"
    assert directory_entries(context, byte_limited["file"]) == []
    refute Map.has_key?(byte_limited, "cursor")

    for index <- 1..500,
        do:
          File.write!(
            Path.join(folder, String.pad_leading(Integer.to_string(index), 100, "a")),
            @bytes
          )

    large = list.(1_000, 1_048_576).facts
    assert large["entry_count"] == 502
    assert large["file"]["size_bytes"] > 65_536
    assert length(directory_entries(context, large["file"])) == 502
  end

  defp directory_entries(context, file) do
    Skopos.Providers.Target.FileWriter.stream(file, fn offset ->
      Targets.read_bound_artifact_chunk(file, offset, actor: context.operator)
    end)
    |> Enum.to_list()
    |> IO.iodata_to_binary()
    |> Jason.decode!()
  end

  test "native mutation loss leaves an unknown result and known denial stays failed", context do
    suffix = Ecto.UUID.generate()
    source = "/mutation-" <> suffix
    destination = source <> "-moved"
    File.write!(Path.join(context.directory, String.trim_leading(source, "/")), @bytes)
    Agent.update(context.agent, &%{&1 | write_drop: true})

    clearance =
      request(context, :effect, "sftp.rename", %{"path" => source, "destination" => destination})
      |> Targets.clear_target_request!(actor: context.operator)

    result =
      Targets.dispatch_target_effect!(clearance, %{}, actor: context.operator, authorize?: false)

    assert result.status == :unknown
    assert Agent.get(context.agent, & &1.writes) == 1
    refute File.exists?(Path.join(context.directory, String.trim_leading(source, "/")))

    assert File.read!(Path.join(context.directory, String.trim_leading(destination, "/"))) ==
             @bytes

    Agent.update(context.agent, &%{&1 | write_drop: false})

    assert {:error, denied} =
             request(context, :effect, "sftp.delete", %{"path" => "/absent-" <> suffix})
             |> Targets.clear_target_request!(actor: context.operator)
             |> Targets.dispatch_target_effect(%{}, actor: context.operator, authorize?: false)

    assert Enum.any?(
             denied.errors,
             &match?(%Skopos.Providers.Target.Error{category: :failed}, &1)
           )
  end

  test "native SFTP cancellation and lost replies preserve uncertainty without replay", context do
    file = stage_file(context)

    params = %{
      "path" => "/interrupted.bin",
      "body_file" => "payload",
      "files" => %{"payload" => file}
    }

    clearance =
      request(context, :effect, "sftp.write_file", params)
      |> Targets.clear_target_request!(actor: context.operator)

    before = Agent.get(context.agent, & &1.opens)

    assert {:error, _} =
             Targets.dispatch_target_effect(clearance, %{cancelled?: fn -> true end},
               actor: context.operator,
               authorize?: false
             )

    assert Agent.get(context.agent, & &1.opens) == before

    Agent.update(context.agent, &%{&1 | write_delay: 300})
    cancel = fn -> Agent.get(context.agent, &(&1.writes > 0)) end

    result =
      Targets.dispatch_target_effect!(clearance, %{cancelled?: cancel},
        actor: context.operator,
        authorize?: false
      )

    assert result.status == :unknown
    assert Agent.get(context.agent, & &1.writes) == 1
    assert File.read!(Path.join(context.directory, "interrupted.bin")) == @bytes

    Agent.update(context.agent, &%{&1 | write_delay: 0, write_drop: true})

    dropped =
      request(context, :effect, "sftp.write_file", params)
      |> Targets.clear_target_request!(actor: context.operator)
      |> Targets.dispatch_target_effect!(%{}, actor: context.operator, authorize?: false)

    assert dropped.status == :unknown
    assert Agent.get(context.agent, & &1.writes) == 2
  end

  @tag sftp_fresh_context: true
  test "SFTP stops subsequent writes after a fresh context fault and retains acknowledged bytes",
       context do
    bytes = :binary.copy(<<42>>, 65_536)
    file = stage_file(context, bytes)

    clearance =
      request(context, :effect, "sftp.write_file", %{
        "path" => "/fresh-context.bin",
        "body_file" => "payload",
        "files" => %{"payload" => file}
      })
      |> Targets.clear_target_request!(actor: context.operator)

    fresh = fn ->
      if Agent.get(context.agent, &(&1.writes > 0)) do
        {:error, cause} =
          Skopos.Repo.query("SELECT sftp_fresh_context_unavailable", [], mode: :savepoint)

        raise cause
      end

      false
    end

    assert {:error, error} =
             Targets.dispatch_target_effect(
               clearance,
               %{before_send?: fresh, cancelled?: fn -> false end},
               actor: context.operator,
               authorize?: false
             )

    assert Exception.message(error) =~ "sftp_fresh_context_unavailable"
    assert Target.Error.context_failure?(error)
    assert is_nil(Target.BeforeSendError.unwrap(error))
    assert Target.Error.context_progress(error)["bytes_written"] == 32_768
    assert Agent.get(context.agent, & &1.writes) == 1

    assert File.read!(Path.join(context.directory, "fresh-context.bin")) ==
             :binary.copy(<<42>>, 32_768)
  end

  for kind <- [:observation, :verification] do
    @tag sftp_fresh_context: true, sftp_read_kind: kind
    test "SFTP #{kind} retains received bytes when fresh context stops the next read", context do
      File.write!(Path.join(context.directory, "fresh-read.bin"), :binary.copy(<<43>>, 65_536))

      clearance =
        request(context, context.sftp_read_kind, "sftp.read_file", %{
          "path" => "/fresh-read.bin",
          "response_file" => %{
            "name" => "partial.bin",
            "media_type" => "application/octet-stream"
          }
        })
        |> Targets.clear_target_request!(actor: context.operator)

      fresh = fn ->
        if Agent.get(context.agent, &(&1.reads > 0)) do
          {:error, cause} =
            Skopos.Repo.query("SELECT sftp_fresh_read_unavailable", [], mode: :savepoint)

          raise cause
        end

        false
      end

      dispatch =
        if context.sftp_read_kind == :observation,
          do: &Targets.dispatch_target_observation/3,
          else: &Targets.dispatch_target_verification/3

      assert {:error, error} =
               dispatch.(
                 clearance,
                 %{before_send?: fresh, cancelled?: fn -> false end},
                 actor: context.operator
               )

      assert Exception.message(error) =~ "sftp_fresh_read_unavailable"
      assert Target.Error.context_failure?(error)
      assert is_nil(Target.BeforeSendError.unwrap(error))
      [receipt] = Targets.page_artifacts!(context.target.id, actor: context.operator).results
      assert receipt.status == :receiving
      assert receipt.received_bytes == 32_768
      assert receipt.completion_reason == nil

      assert Target.Error.context_progress(error) ==
               %{"receiving_file_id" => receipt.id, "received_bytes" => 32_768}

      assert {:error, _} =
               Targets.artifact_reference(receipt.id, context.target.id, actor: context.operator)

      assert Agent.get(context.agent, & &1.reads) == 1
    end
  end

  @tag sftp_context_fault: true
  test "SFTP preserves original in-flight context faults across all three ports", context do
    Agent.update(context.agent, &%{&1 | read_delay: 300, write_delay: 300})
    file = stage_file(context)

    for {kind, operation, parameters, counter, dispatch} <- [
          {:effect, "sftp.write_file",
           %{"path" => "/fault.bin", "body_file" => "payload", "files" => %{"payload" => file}},
           :writes, &Targets.dispatch_target_effect/3},
          {:observation, "sftp.read_file",
           %{
             "path" => "/download.bin",
             "response_file" => %{
               "name" => "fault-read.bin",
               "media_type" => "application/octet-stream"
             }
           }, :reads, &Targets.dispatch_target_observation/3},
          {:verification, "sftp.read_file",
           %{
             "path" => "/download.bin",
             "response_file" => %{
               "name" => "fault-verify.bin",
               "media_type" => "application/octet-stream"
             }
           }, :reads, &Targets.dispatch_target_verification/3}
        ] do
      before = Agent.get(context.agent, &Map.fetch!(&1, counter))

      clearance =
        request(context, kind, operation, parameters)
        |> Targets.clear_target_request!(actor: context.operator)

      callback = fn ->
        if Agent.get(context.agent, &(Map.fetch!(&1, counter) > before)) do
          {:error, cause} =
            Skopos.Repo.query("SELECT sftp_context_unavailable", [], mode: :savepoint)

          raise cause
        end

        false
      end

      assert {:error, error} =
               dispatch.(clearance, %{cancelled?: callback},
                 actor: context.operator,
                 authorize?: false
               )

      assert Exception.message(error) =~ "sftp_context_unavailable"
      assert Skopos.Providers.Target.Error.context_failure?(error)
      assert Agent.get(context.agent, &Map.fetch!(&1, counter)) == before + 1
    end

    assert File.read!(Path.join(context.directory, "fault.bin")) == @bytes
  end

  test "cancelled or dropped SFTP downloads cannot publish complete files", context do
    parameters = %{
      "path" => "/download.bin",
      "response_file" => %{"name" => "partial.bin", "media_type" => "application/octet-stream"}
    }

    Agent.update(context.agent, &%{&1 | read_delay: 300})
    cancel = fn -> Agent.get(context.agent, &(&1.reads > 0)) end

    assert {:error, _} =
             request(context, :observation, "sftp.read_file", parameters)
             |> Targets.clear_target_request!(actor: context.operator)
             |> Targets.dispatch_target_observation(%{cancelled?: cancel},
               actor: context.operator
             )

    Agent.update(context.agent, &%{&1 | read_delay: 0, read_drop: true})

    assert {:error, _} =
             request(context, :observation, "sftp.read_file", parameters)
             |> Targets.clear_target_request!(actor: context.operator)
             |> Targets.dispatch_target_observation(%{}, actor: context.operator)

    receipts = Targets.page_artifacts!(context.target.id, actor: context.operator).results
    assert length(receipts) == 2

    for receipt <- receipts do
      assert receipt.status == :receiving
      assert receipt.completion_reason == nil

      assert {:error, _} =
               Targets.artifact_reference(receipt.id, context.target.id, actor: context.operator)
    end

    assert Agent.get(context.agent, & &1.reads) == 2
  end

  test "revoked files, insufficient authority and stale Methods cannot open a remote file",
       context do
    file = stage_file(context)

    intent =
      request(context, :effect, "sftp.write_file", %{
        "path" => "/never-opened.bin",
        "body_file" => "payload",
        "files" => %{"payload" => file}
      })

    clearance = Targets.clear_target_request!(intent, actor: context.operator)

    assert {:error, _} =
             Targets.dispatch_target_effect(clearance, %{}, actor: context.viewer)

    readonly =
      %{intent | authority_mode: :readonly}
      |> Targets.clear_target_request!(actor: context.operator)

    assert {:error, _} =
             Targets.dispatch_target_effect(readonly, %{},
               actor: context.operator,
               authorize?: false
             )

    Targets.revoke_artifact!(file["id"], actor: context.operator)

    assert {:error, _} =
             Targets.dispatch_target_effect(clearance, %{},
               actor: context.operator,
               authorize?: false
             )

    fresh = stage_file(context)
    fresh_intent = put_in(intent.parameters["files"]["payload"], fresh)
    stale = Targets.clear_target_request!(fresh_intent, actor: context.operator)

    Targets.update_access_method!(context.method, context.method.revision, %{priority: 90},
      actor: context.admin
    )

    assert {:error, _} =
             Targets.dispatch_target_effect(stale, %{},
               actor: context.operator,
               authorize?: false
             )

    assert Agent.get(context.agent, & &1.opens) == 0
    refute File.exists?(Path.join(context.directory, "never-opened.bin"))
  end

  test "native transfer deadlines leave writes uncertain and reads unpublished", context do
    file = stage_file(context)
    Agent.update(context.agent, &%{&1 | write_delay: 1_500})

    result =
      request(context, :effect, "sftp.write_file", %{
        "path" => "/timed-out.bin",
        "body_file" => "payload",
        "files" => %{"payload" => file}
      })
      |> Targets.clear_target_request!(actor: context.operator)
      |> Targets.dispatch_target_effect!(%{}, actor: context.operator, authorize?: false)

    assert result.status == :unknown
    assert Agent.get(context.agent, & &1.writes) == 1

    Agent.update(context.agent, &%{&1 | write_delay: 0, read_delay: 1_500})

    assert {:error, _} =
             request(context, :observation, "sftp.read_file", %{
               "path" => "/download.bin",
               "response_file" => %{
                 "name" => "timeout.bin",
                 "media_type" => "application/octet-stream"
               }
             })
             |> Targets.clear_target_request!(actor: context.operator)
             |> Targets.dispatch_target_observation(%{}, actor: context.operator)

    receipt =
      Targets.page_artifacts!(context.target.id, actor: context.operator).results
      |> Enum.find(&(&1.name == "timeout.bin"))

    assert receipt.status == :receiving
    assert receipt.completion_reason == nil
    assert Agent.get(context.agent, & &1.reads) == 1
  end

  test "an unexpected input port failure after native truncate leaves the effect unknown",
       context do
    file = stage_file(context)

    {:ok, state} =
      Skopos.Transports.SSH.build(
        %{
          "host_key_fingerprints" => %{context.endpoint => context.fingerprint},
          "connect_timeout_ms" => 2_000,
          "operation_timeout_ms" => 1_000
        },
        %{"username" => "tester", "auth_method" => "password", "password" => "secret"}
      )

    remote = "/worker-failure-" <> Ecto.UUID.generate()
    File.write!(Path.join(context.directory, String.trim_leading(remote, "/")), @bytes)

    request = %{
      capability: "request.ssh.effect",
      operation: "sftp.write_file",
      selectors: %{},
      parameters: %{"path" => remote, "body_file" => "payload"},
      files: %{"payload" => file},
      connection: %Skopos.Providers.Target.Connection{endpoint: context.endpoint}
    }

    invocation = %{
      file_reader: fn "payload", 0 ->
        if Agent.get(context.agent, & &1.opens) == 0,
          do: {:ok, @bytes},
          else: raise("native input port stopped unexpectedly")
      end
    }

    assert {:ok, %Skopos.Providers.Target.EffectResult{status: :unknown}} =
             Skopos.Targets.Adapters.SSH.effect(state, request, invocation)

    assert File.read!(Path.join(context.directory, String.trim_leading(remote, "/"))) == <<>>
    assert Agent.get(context.agent, & &1.opens) == 1
  end

  test "empty and multi-chunk native files retain exact bytes in both directions", context do
    for bytes <- [<<>>, :binary.copy(@bytes, 60_001)] do
      suffix = Integer.to_string(byte_size(bytes))
      file = stage_file(context, bytes)
      remote = "/sized-" <> suffix <> ".bin"

      result =
        request(context, :effect, "sftp.write_file", %{
          "path" => remote,
          "body_file" => "payload",
          "files" => %{"payload" => file}
        })
        |> Targets.clear_target_request!(actor: context.operator)
        |> Targets.dispatch_target_effect!(%{}, actor: context.operator, authorize?: false)

      assert result.status == :applied
      assert result.details["bytes_written"] == byte_size(bytes)
      assert File.read!(Path.join(context.directory, String.trim_leading(remote, "/"))) == bytes

      downloaded =
        request(context, :observation, "sftp.read_file", %{
          "path" => remote,
          "response_file" => %{
            "name" => "sized-" <> suffix <> ".bin",
            "media_type" => "application/octet-stream"
          }
        })
        |> Targets.clear_target_request!(actor: context.operator)
        |> Targets.dispatch_target_observation!(%{}, actor: context.operator)

      received = downloaded.facts["file"]
      assert received["size_bytes"] == byte_size(bytes)
      assert received["sha256"] == file["sha256"]

      actual =
        Skopos.Providers.Target.FileWriter.stream(received, fn offset ->
          Targets.read_bound_artifact_chunk(received, offset, actor: context.operator)
        end)
        |> Enum.to_list()
        |> IO.iodata_to_binary()

      assert actual == bytes
    end

    assert Agent.get(context.agent, & &1.writes) > 1
    assert Agent.get(context.agent, & &1.reads) > 2
  end

  defp stage_file(context, bytes \\ @bytes) do
    file =
      Targets.begin_artifact!(
        context.target.id,
        "input.bin",
        "application/octet-stream",
        byte_size(bytes),
        Base.encode16(:crypto.hash(:sha256, bytes), case: :lower),
        Ecto.UUID.generate(),
        actor: context.operator
      )

    bytes
    |> :binary.bin_to_list()
    |> Enum.chunk_every(262_144)
    |> Enum.reduce(0, fn chunk, offset ->
      binary = :binary.list_to_bin(chunk)
      Targets.append_artifact_chunk!(file.id, offset, binary, actor: context.operator)
      offset + byte_size(binary)
    end)

    Targets.complete_artifact!(file.id, actor: context.operator)
    Targets.artifact_reference!(file.id, context.target.id, actor: context.operator)
  end

  for phase <- [:begin, :append] do
    @tag ssh_file_port_fault: true, sftp_file_fault_phase: phase
    test "SFTP #{phase} storage faults retain their original cause", context do
      phase = context.sftp_file_fault_phase
      condition = if phase == :begin, do: "TRUE", else: "NEW.received_bytes <> OLD.received_bytes"
      event = if phase == :begin, do: "INSERT", else: "UPDATE"

      Skopos.Repo.query!("""
      CREATE FUNCTION pg_temp.reject_sftp_file_port() RETURNS trigger LANGUAGE plpgsql AS $$
      BEGIN
        IF #{condition} THEN RAISE EXCEPTION 'SFTP file port unavailable'; END IF;
        RETURN NEW;
      END $$;
      """)

      Skopos.Repo.query!(
        "CREATE TRIGGER reject_sftp_file_port BEFORE #{event} ON artifacts FOR EACH ROW EXECUTE FUNCTION pg_temp.reject_sftp_file_port()"
      )

      clearance =
        request(context, :observation, "sftp.read_file", %{
          "path" => "/download.bin",
          "response_file" => %{
            "name" => "download-fault.bin",
            "media_type" => "application/octet-stream"
          }
        })
        |> Targets.clear_target_request!(actor: context.operator)

      assert {:error, error} =
               Targets.dispatch_target_observation(clearance, %{}, actor: context.operator)

      if phase == :begin do
        assert %Target.BeforeSendError{cause: cause} = Target.BeforeSendError.unwrap(error)
        assert Exception.message(cause) =~ "SFTP file port unavailable"
        assert Agent.get(context.agent, & &1.opens) == 0
      else
        assert Exception.message(error) =~ "SFTP file port unavailable"
        assert Target.Error.context_failure?(error)

        assert %{"receiving_file_id" => id, "received_bytes" => 0, "pending_chunk_bytes" => 5} =
                 Target.Error.context_progress(error)

        assert Targets.get_artifact!(id, actor: context.operator).status == :receiving
        assert Agent.get(context.agent, & &1.opens) == 1
      end
    end
  end

  @tag ssh_file_port_fault: true
  test "SFTP receipt publication failure leaves downloaded bytes unpublished", context do
    Skopos.Repo.query!("""
    CREATE FUNCTION pg_temp.reject_sftp_completion() RETURNS trigger LANGUAGE plpgsql AS $$
    BEGIN
      IF NEW.status = 'ready' AND NEW.request_id = 'sftp-save-failure' THEN
        RAISE EXCEPTION 'test SFTP receipt publication unavailable';
      END IF;
      RETURN NEW;
    END
    $$
    """)

    Skopos.Repo.query!("""
    CREATE TRIGGER reject_sftp_completion BEFORE UPDATE ON artifacts
    FOR EACH ROW EXECUTE FUNCTION pg_temp.reject_sftp_completion()
    """)

    read =
      request(context, :observation, "sftp.read_file", %{
        "path" => "/download.bin",
        "response_file" => %{"name" => "unsaved.bin", "media_type" => "application/octet-stream"}
      })

    read = %{read | operation_id: "sftp-save-failure"}

    assert {:error, error} =
             read
             |> Targets.clear_target_request!(actor: context.operator)
             |> Targets.dispatch_target_observation(%{}, actor: context.operator)

    [receipt] = Targets.page_artifacts!(context.target.id, actor: context.operator).results
    assert receipt.status == :receiving
    assert receipt.received_bytes == 5
    assert receipt.completion_reason == nil
    assert Exception.message(error) =~ "test SFTP receipt publication unavailable"

    assert Target.Error.context_progress(error) == %{
             "receiving_file_id" => receipt.id,
             "received_bytes" => 5
           }

    assert {:error, _} =
             Targets.artifact_reference(receipt.id, context.target.id, actor: context.operator)

    assert Agent.get(context.agent, & &1.opens) == 1
    Skopos.Repo.query!("DROP TRIGGER reject_sftp_completion ON artifacts")
  end

  for phase <- [:initial, :stream] do
    @tag ssh_file_port_fault: true, sftp_reader_fault_phase: phase
    test "public SFTP input reader #{phase} faults retain cause and partial remote bytes",
         context do
      file = stage_file(context)
      remote = "/reader-fault-#{Ecto.UUID.generate()}.bin"

      request = %Target.EffectRequest{
        provider_revision: context.provider.revision,
        target_id: context.target.id,
        target_revision: context.target.revision,
        access_method_id: context.method.id,
        access_method_revision: context.method.revision,
        connection: %Target.Connection{endpoint: context.endpoint},
        capability: "request.ssh.effect",
        operation: "sftp.write_file",
        authorization_digest: "fixture",
        operation_id: Ecto.UUID.generate(),
        idempotency_key: Ecto.UUID.generate(),
        files: %{"payload" => file},
        parameters: %{"path" => remote, "body_file" => "payload"}
      }

      reader = fn "payload", offset ->
        if context.sftp_reader_fault_phase == :stream and offset == 0 do
          {:ok, binary_part(@bytes, 0, 2)}
        else
          {:error, cause} =
            Skopos.Repo.query("SELECT sftp_reader_context_unavailable", [], mode: :savepoint)

          {:error, Target.Error.context_failure(cause)}
        end
      end

      assert {:error, error} =
               Providers.target_effect(context.provider.id, request, %{file_reader: reader},
                 actor: context.operator,
                 authorize?: false
               )

      if context.sftp_reader_fault_phase == :initial do
        assert %Target.BeforeSendError{cause: cause} = Target.BeforeSendError.unwrap(error)
        assert Exception.message(cause) =~ "sftp_reader_context_unavailable"
        assert Agent.get(context.agent, & &1.opens) == 0
        refute File.exists?(Path.join(context.directory, String.trim_leading(remote, "/")))
      else
        assert Exception.message(error) =~ "sftp_reader_context_unavailable"
        assert Target.Error.context_failure?(error)
        assert Target.Error.context_progress(error)["input_file_id"] == file["id"]
        assert Agent.get(context.agent, & &1.writes) == 1

        assert File.read!(Path.join(context.directory, String.trim_leading(remote, "/"))) ==
                 binary_part(@bytes, 0, 2)
      end
    end
  end

  for {adapter, kind, type, protocol} <- [
        {"ssh", "network_device", "custom-network-device", "ssh"},
        {"linux-ssh", "host", "linux", "ssh"},
        {"ios-xe-ssh", "network_device", "cisco_ios_xe", "ssh_cli"}
      ] do
    @tag adapter: adapter, kind: kind, type: type, protocol: protocol
    test "#{adapter} downloads and uploads exact binary files through one checked Method",
         context do
      assert Enum.any?(
               context.method.operation_catalog.observations,
               &(&1.operation == "sftp.read_file")
             )

      assert Enum.any?(
               context.method.operation_catalog.effects,
               &(&1.operation == "sftp.write_file")
             )

      read =
        request(context, :observation, "sftp.read_file", %{
          "path" => "/download.bin",
          "response_file" => %{
            "name" => "download.bin",
            "media_type" => "application/octet-stream"
          }
        })

      result =
        read
        |> Targets.clear_target_request!(actor: context.operator)
        |> Targets.dispatch_target_observation!(%{}, actor: context.operator)

      assert result.facts["completion_reason"] == "eof"
      file = result.facts["file"]
      assert file["size_bytes"] == byte_size(@bytes)
      assert file["sha256"] == Base.encode16(:crypto.hash(:sha256, @bytes), case: :lower)
      assert Targets.read_bound_artifact_chunk!(file, 0, actor: context.operator) == @bytes

      assert Targets.get_artifact!(file["id"], actor: context.operator).request_id ==
               read.operation_id

      assert {:error, _} = Targets.read_bound_artifact_chunk(file, 0, actor: context.viewer)
      remote = "/uploaded-" <> context.adapter <> ".bin"
      parameters = %{"path" => remote, "body_file" => "payload", "files" => %{"payload" => file}}

      assert {:error, _} =
               request(context, :observation, "sftp.write_file", parameters)
               |> Targets.clear_target_request(actor: context.operator)

      effect =
        request(context, :effect, "sftp.write_file", parameters)
        |> Targets.clear_target_request!(actor: context.operator)
        |> Targets.dispatch_target_effect!(%{}, actor: context.operator, authorize?: false)

      assert effect.status == :applied
      assert effect.details["bytes_written"] == byte_size(@bytes)
      assert File.read!(Path.join(context.directory, String.trim_leading(remote, "/"))) == @bytes

      verification =
        request(context, :verification, "sftp.read_file", %{
          "path" => remote,
          "response_file" => %{"name" => "verify.bin", "media_type" => "application/octet-stream"}
        })

      verification = %{verification | expected: %{"sha256" => file["sha256"], "size_bytes" => 5}}

      verified =
        verification
        |> Targets.clear_target_request!(actor: context.operator)
        |> Targets.dispatch_target_verification!(%{}, actor: context.operator)

      assert verified.status == :verified
      assert verified.facts["file"]["sha256"] == file["sha256"]
    end
  end

  defp request(context, kind, operation, parameters) do
    id = Ecto.UUID.generate()

    %Request{
      kind: kind,
      authority_mode: if(kind == :effect, do: :full_access, else: :readonly),
      target_id: context.target.id,
      target_revision: context.target.revision,
      access_method_id: context.method.id,
      access_method_revision: context.method.revision,
      capability: if(kind == :effect, do: "request.ssh.effect", else: "request.ssh.observe"),
      operation: operation,
      operation_id: id,
      idempotency_key: if(kind == :effect, do: id),
      parameters: parameters
    }
  end
end
