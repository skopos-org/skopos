defmodule Skopos.TargetRequestTest do
  use Skopos.DataCase, async: false

  alias Skopos.{Accounts, Providers, Targets}
  alias Skopos.Providers.Target, as: ProviderTarget
  alias Skopos.Targets.TargetRequest.{RequestError, Request, Clearance}

  @password "correct horse battery staple"

  setup do
    admin = Accounts.bootstrap!("admin@example.com", @password, @password, authorize?: true)

    operator =
      Accounts.create_user!("operator@example.com", @password, :operator, actor: admin)

    viewer = Accounts.create_user!("viewer@example.com", @password, :viewer, actor: admin)

    provider = enabled_target_provider!(admin)
    linux = create_target!(admin, "linux-01", "host", "linux")

    ssh =
      create_method!(admin, provider, linux, "ssh", "ssh", "ssh://192.0.2.10:22")

    api =
      create_method!(admin, provider, linux, "api", "agent", "https://192.0.2.10")

    %{
      admin: admin,
      operator: operator,
      viewer: viewer,
      provider: provider,
      linux: linux,
      ssh: ssh,
      api: api
    }
  end

  @tag request_actor_read_fault: true
  test "Target request clearance preserves temporary actor read errors", context do
    input =
      request(context.linux, context.ssh, :observation, :auto,
        capability: "observe.command",
        operation: "filesystem.read"
      )

    Repo.query!("ALTER TABLE users RENAME COLUMN role_version TO unavailable_role_version")

    try do
      assert {:error, %Ash.Error.Unknown{}} =
               Targets.clear_target_request(input, actor: context.operator)
    after
      Repo.query!("ALTER TABLE users RENAME COLUMN unavailable_role_version TO role_version")
    end

    assert %Clearance{} = Targets.clear_target_request!(input, actor: context.operator)
    refute_receive {:observe, _, _}
    refute_receive {:effect, _, _}
  end

  @tag request_method_read_fault: true
  test "Target clearance distinguishes a Method storage fault from a stale Method", context do
    input =
      request(context.linux, context.ssh, :observation, :auto,
        capability: "observe.command",
        operation: "filesystem.read"
      )

    Repo.query!(
      "ALTER TABLE access_methods RENAME COLUMN capabilities TO unavailable_capabilities"
    )

    try do
      assert {:error, %Ash.Error.Unknown{} = error} =
               Targets.clear_target_request(input, actor: context.operator)

      assert Exception.message(error) =~ "does not exist"
      denied = RequestError.exception(category: :forbidden, message: "denied")
      invalid = Ash.Error.Action.InvalidArgument.exception(field: :request, message: "invalid")
      assert RequestError.expected?(Ash.Error.to_error_class(denied))
      assert RequestError.expected?(Ash.Error.to_error_class(invalid))
      refute RequestError.expected?(Ash.Error.to_error_class([denied, error]))
      refute RequestError.expected?(Ash.Error.to_error_class([invalid, error]))
    after
      Repo.query!(
        "ALTER TABLE access_methods RENAME COLUMN unavailable_capabilities TO capabilities"
      )
    end

    assert %Clearance{} = Targets.clear_target_request!(input, actor: context.operator)
    refute_receive {:observe, _, _}
    refute_receive {:effect, _, _}
  end

  test "cleared request dispatches the exact registered Method snapshot",
       context do
    other = create_target!(context.admin, "linux-02", "host", "linux")

    other_method =
      create_method!(
        context.admin,
        context.provider,
        other,
        "ssh",
        "ssh",
        "ssh://192.0.2.11:22"
      )

    request =
      request(other, other_method, :observation, :auto,
        capability: "observe.command",
        operation: "filesystem.read",
        selectors: %{"path" => "/usr/credential/service/token"},
        parameters: %{"command" => "cat /usr/credential/service/token"}
      )

    assert %Clearance{} =
             clearance = Targets.clear_target_request!(request, actor: context.operator)

    observation = %ProviderTarget.Observation{
      facts: %{"exists" => true},
      observed_at: DateTime.utc_now()
    }

    assert ^observation =
             Targets.dispatch_target_observation!(
               clearance,
               invocation(observation),
               actor: context.operator
             )

    assert_receive {:observe, _state, dispatched}
    assert dispatched.target_id == other.id
    assert dispatched.access_method_id == other_method.id
    assert dispatched.operation == "filesystem.read"
    assert dispatched.selectors == request.selectors
    assert dispatched.parameters == request.parameters
    assert dispatched.authorization_digest == clearance.digest
    assert dispatched.connection.endpoint == other_method.endpoint

    verification_request =
      request(other, other_method, :verification, :auto,
        capability: "observe.command",
        operation: "filesystem.verify",
        selectors: %{"path" => "/usr/credential/service/token"}
      )

    verification_clearance =
      Targets.clear_target_request!(verification_request, actor: context.operator)

    verification = %ProviderTarget.Verification{
      status: :verified,
      observed_at: DateTime.utc_now()
    }

    assert ^verification =
             Targets.dispatch_target_verification!(
               verification_clearance,
               invocation(verification),
               actor: context.operator
             )

    assert_receive {:verify, _state, verify_request}
    assert verify_request.access_method_id == other_method.id
    assert verify_request.operation == "filesystem.verify"
    assert verify_request.connection.endpoint == other_method.endpoint

    assert {:error, %Ash.Error.Forbidden{}} =
             Providers.target_observe(
               context.provider.id,
               dispatched,
               invocation(observation),
               actor: context.operator
             )

    refute_receive {:observe, _, _}
  end

  test "tampered or stale clearance and downgraded actors stop before dispatch", context do
    base =
      request(context.linux, context.ssh, :observation, :auto,
        capability: "observe.command",
        operation: "system.inspect"
      )

    clearance = Targets.clear_target_request!(base, actor: context.operator)
    tampered = %{clearance | parameters: %{"command" => "different"}}

    assert {:error, tampered_error} =
             Targets.dispatch_target_observation(
               tampered,
               invocation(flunk_response()),
               actor: context.operator
             )

    assert request_error(tampered_error).category == :clearance_mismatch

    Targets.update_target!(
      context.linux,
      context.linux.revision,
      %{operating_instructions: "Do not modify root"},
      actor: context.admin
    )

    assert {:error, target_error} =
             Targets.dispatch_target_observation(
               clearance,
               invocation(flunk_response()),
               actor: context.operator
             )

    assert request_error(target_error).category == :stale_context

    rechecked =
      Targets.check_access_method!(context.ssh.id, context.ssh.revision, %{},
        actor: context.admin
      )

    current_request = %{
      base
      | target_revision: context.linux.revision + 1,
        access_method_revision: rechecked.revision
    }

    current_clearance = Targets.clear_target_request!(current_request, actor: context.operator)

    edited =
      Targets.update_access_method!(rechecked, rechecked.revision, %{priority: 10},
        actor: context.admin
      )

    assert {:error, method_error} =
             Targets.dispatch_target_observation(
               current_clearance,
               invocation(flunk_response()),
               actor: context.operator
             )

    assert request_error(method_error).category == :stale_context

    current_request = %{current_request | access_method_revision: edited.revision}
    current_clearance = Targets.clear_target_request!(current_request, actor: context.operator)

    Providers.update_provider!(
      context.provider,
      context.provider.revision,
      %{configuration: %{"endpoint" => "reachable"}},
      actor: context.admin
    )

    assert {:error, provider_error} =
             Targets.dispatch_target_observation(
               current_clearance,
               invocation(flunk_response()),
               actor: context.operator
             )

    assert request_error(provider_error).category == :stale_context
    refute_receive {:observe, _, _}
  end

  test "clearance reloads actor authorization before dispatch", context do
    request =
      request(context.linux, context.ssh, :observation, :readonly,
        capability: "observe.command",
        operation: "system.inspect"
      )

    clearance = Targets.clear_target_request!(request, actor: context.operator)
    Accounts.change_role!(context.operator, :viewer, actor: context.admin)

    assert {:error, error} =
             Targets.dispatch_target_observation(
               clearance,
               invocation(flunk_response()),
               actor: context.operator
             )

    assert request_error(error).category == :forbidden
    refute_receive {:observe, _, _}
  end

  test "readonly permits effect recommendations but rejects their dispatch", context do
    observation =
      request(context.linux, context.ssh, :observation, :readonly,
        capability: "observe.command",
        operation: "system.inspect"
      )

    assert %Clearance{} =
             Targets.clear_target_request!(observation, actor: context.operator)

    effect =
      request(context.linux, context.ssh, :effect, :readonly,
        capability: "effect.command",
        operation: "command.execute",
        parameters: %{"command" => "systemctl restart service"}
      )

    clearance = Targets.clear_target_request!(effect, actor: context.operator)

    assert {:error, error} =
             Targets.dispatch_target_effect(clearance, invocation(flunk_response()),
               actor: context.operator,
               authorize?: false
             )

    assert request_error(error).category == :forbidden
    refute_receive {:effect, _, _}
  end

  test "exact clearance supplies an authorized reader for immutable file bytes", context do
    file = operation_file!(context)
    base = file_request(context, file)
    clearance = Targets.clear_target_request!(base, actor: context.operator)
    assert clearance.parameters == base.parameters

    response = %ProviderTarget.Observation{facts: %{}, observed_at: DateTime.utc_now()}

    invocation = %{
      test_pid: self(),
      file_reader: fn _, _ -> flunk("caller supplied file authority was trusted") end,
      respond: fn invocation ->
        assert {:ok, <<255, 0, 1, 2, 255>>} = invocation.file_reader.("payload", 0)
        assert {:error, _} = invocation.file_reader.("unbound", 0)
        assert {:error, _} = invocation.file_reader.("payload", -1)
        {:ok, response}
      end
    }

    assert ^response =
             Targets.dispatch_target_observation!(clearance, invocation, actor: context.operator)

    assert_receive {:observe, _, dispatched}
    assert dispatched.files == %{"payload" => file}
    assert dispatched.parameters == %{"command" => "inspect file"}
  end

  test "file scope, ownership and metadata are checked before clearance and dispatch", context do
    file = operation_file!(context)
    base = file_request(context, file)
    clearance = Targets.clear_target_request!(base, actor: context.operator)

    for changed <- [
          Map.put(file, "target_id", Ash.UUID.generate()),
          Map.put(file, "sha256", String.duplicate("0", 64)),
          Map.put(file, "size_bytes", 6),
          Map.put(file, "path", "/tmp/not-file-authority")
        ] do
      assert {:error, error} =
               Targets.clear_target_request(file_request(context, changed),
                 actor: context.operator
               )

      assert request_error(error).category == :invalid_file
    end

    other_operator =
      Accounts.create_user!(
        "other-operator@example.com",
        @password,
        :operator,
        actor: context.admin
      )

    assert {:error, error} = Targets.clear_target_request(base, actor: other_operator)
    assert request_error(error).category == :invalid_file

    assert {:error, error} =
             Targets.dispatch_target_observation(clearance, invocation(flunk_response()),
               actor: other_operator
             )

    assert request_error(error).category == :clearance_mismatch

    tampered = %{
      clearance
      | parameters: put_in(base.parameters, ["files", "payload", "size_bytes"], 6)
    }

    assert {:error, error} =
             Targets.dispatch_target_observation(
               tampered,
               invocation(flunk_response()),
               actor: context.operator
             )

    assert request_error(error).category == :clearance_mismatch

    Targets.revoke_artifact!(file["id"], actor: context.operator)

    assert {:error, error} =
             Targets.dispatch_target_observation(
               clearance,
               invocation(flunk_response()),
               actor: context.operator
             )

    assert request_error(error).category == :invalid_file
    refute_receive {:observe, _, _}
  end

  test "effect and verification ports retain the same bound file identity", context do
    file = operation_file!(context)

    for {kind, capability, operation, response, dispatch} <- [
          {:effect, "effect.command", "command.execute",
           %ProviderTarget.EffectResult{status: :applied}, &Targets.dispatch_target_effect/3},
          {:verification, "observe.command", "filesystem.verify",
           %ProviderTarget.Verification{status: :verified, observed_at: DateTime.utc_now()},
           &Targets.dispatch_target_verification/3}
        ] do
      input =
        request(context.linux, context.ssh, kind, :full_access,
          capability: capability,
          operation: operation,
          parameters: %{"files" => %{"payload" => file}}
        )

      clearance = Targets.clear_target_request!(input, actor: context.operator)

      invocation = %{
        test_pid: self(),
        respond: fn invocation ->
          assert {:ok, <<255, 0, 1, 2, 255>>} = invocation.file_reader.("payload", 0)
          {:ok, response}
        end
      }

      assert {:ok, ^response} =
               dispatch.(clearance, invocation, actor: context.operator, authorize?: false)

      assert_receive {_, _, dispatched}
      assert dispatched.parameters == %{}
      assert dispatched.files == %{"payload" => file}
    end
  end

  test "a file reader rechecks cancellation, current role and revocation at each read", context do
    file = operation_file!(context)

    clearance =
      Targets.clear_target_request!(file_request(context, file), actor: context.operator)

    response = %ProviderTarget.Observation{facts: %{}, observed_at: DateTime.utc_now()}

    invocation = %{
      cancelled?: fn -> Process.get(:cancel_file_read, false) end,
      respond: fn invocation ->
        assert {:ok, <<255, 0, 1, 2, 255>>} = invocation.file_reader.("payload", 0)
        Process.put(:cancel_file_read, true)

        assert {:error, %RequestError{category: :cancelled}} =
                 invocation.file_reader.("payload", 0)

        Process.delete(:cancel_file_read)
        Accounts.change_role!(context.operator, :viewer, actor: context.admin)

        assert {:error, %RequestError{category: :forbidden}} =
                 invocation.file_reader.("payload", 0)

        Accounts.change_role!(context.operator, :operator, actor: context.admin)
        assert {:ok, <<255, 0, 1, 2, 255>>} = invocation.file_reader.("payload", 0)
        Targets.revoke_artifact!(file["id"], actor: context.admin)

        assert {:error, %RequestError{category: :invalid_file}} =
                 invocation.file_reader.("payload", 0)

        {:ok, response}
      end
    }

    assert ^response =
             Targets.dispatch_target_observation!(clearance, invocation, actor: context.operator)
  end

  test "unfinished and expired files cannot enter a cleared request", context do
    previous = Application.get_env(:skopos, :artifact_limits)
    Application.put_env(:skopos, :artifact_limits, %{lifetime_seconds: 1})

    on_exit(fn ->
      if previous,
        do: Application.put_env(:skopos, :artifact_limits, previous),
        else: Application.delete_env(:skopos, :artifact_limits)
    end)

    upload =
      Targets.begin_artifact!(
        context.linux.id,
        "device.bin",
        "application/octet-stream",
        5,
        "b55f1659c0645fd1cee6dfa8b3af06795e9da7e48cb65c2b999f896c9f539dbd",
        "unfinished",
        actor: context.operator
      )

    incomplete = %{
      "id" => upload.id,
      "target_id" => context.linux.id,
      "name" => "device.bin",
      "media_type" => "application/octet-stream",
      "size_bytes" => 5,
      "sha256" => upload.expected_sha256
    }

    assert {:error, error} =
             Targets.clear_target_request(file_request(context, incomplete),
               actor: context.operator
             )

    assert request_error(error).category == :invalid_file

    file = operation_file!(context, "expires")

    clearance =
      Targets.clear_target_request!(file_request(context, file), actor: context.operator)

    Process.sleep(1_100)

    assert {:error, error} =
             Targets.clear_target_request(file_request(context, file), actor: context.operator)

    assert request_error(error).category == :invalid_file

    assert {:error, error} =
             Targets.dispatch_target_observation(clearance, invocation(flunk_response()),
               actor: context.operator
             )

    assert request_error(error).category == :invalid_file
    refute_receive {:observe, _, _}
  end

  defp operation_file!(context, key \\ "operation-file") do
    upload =
      Targets.begin_artifact!(
        context.linux.id,
        "device.bin",
        "application/octet-stream",
        5,
        "b55f1659c0645fd1cee6dfa8b3af06795e9da7e48cb65c2b999f896c9f539dbd",
        key,
        actor: context.operator
      )

    Targets.append_artifact_chunk!(upload.id, 0, <<255, 0, 1, 2, 255>>, actor: context.operator)
    Targets.complete_artifact!(upload.id, actor: context.operator)
    Targets.artifact_reference!(upload.id, context.linux.id, actor: context.operator)
  end

  test "a cleared request supplies one scoped incoming file writer", context do
    input =
      request(context.linux, context.ssh, :observation, :auto,
        capability: "observe.command",
        operation: "system.inspect"
      )

    clearance = Targets.clear_target_request!(input, actor: context.operator)

    invocation = %{
      file_writer: fn _, _, _ -> flunk("caller supplied receipt authority was trusted") end,
      cancelled?: fn -> Process.get(:cancel_file_write, false) end,
      respond: fn invocation ->
        {:ok, writer} =
          invocation.file_writer.("peer-response-1", "response.bin", "application/octet-stream")

        assert writer.status == :receiving
        assert writer.offset == 0
        assert {:error, _} = writer.read.(0)
        assert {:ok, 5} = writer.append.(0, <<255, 0, 1, 2, 255>>)

        {:ok, same_writer} =
          invocation.file_writer.("peer-response-1", "response.bin", "application/octet-stream")

        assert same_writer.id == writer.id
        assert same_writer.offset == 5

        assert {:error, %RequestError{category: :file_transfer_failed}} =
                 invocation.file_writer.(
                   "peer-response-1",
                   "changed.bin",
                   "application/octet-stream"
                 )

        assert {:error, _} = same_writer.complete.(6, nil, :eof)
        {:ok, reference} = same_writer.complete.(5, nil, :eof)
        assert reference["target_id"] == context.linux.id
        assert reference["size_bytes"] == 5

        assert reference["sha256"] ==
                 "b55f1659c0645fd1cee6dfa8b3af06795e9da7e48cb65c2b999f896c9f539dbd"

        assert {:ok, <<255, 0, 1, 2, 255>>} = writer.read.(0)

        Accounts.change_role!(context.operator, :viewer, actor: context.admin)
        assert {:error, %RequestError{category: :forbidden}} = writer.read.(0)
        assert {:error, %RequestError{category: :forbidden}} = writer.complete.(5, nil, :eof)
        assert {:error, %RequestError{category: :forbidden}} = writer.abort.()
        Accounts.change_role!(context.operator, :operator, actor: context.admin)
        Process.put(:cancel_file_write, true)
        assert {:error, %RequestError{category: :cancelled}} = writer.read.(0)

        assert {:error, %RequestError{category: :cancelled}} =
                 writer.append.(0, <<255, 0, 1, 2, 255>>)

        assert {:error, %RequestError{category: :cancelled}} = writer.complete.(nil, nil, :eof)
        assert {:ok, :revoked} = writer.abort.()
        Process.delete(:cancel_file_write)
        assert {:error, _} = writer.read.(0)

        assert {:error, _} =
                 Targets.artifact_reference(writer.id, context.linux.id, actor: context.operator)

        {:ok,
         %ProviderTarget.Observation{
           facts: %{"file" => reference},
           observed_at: DateTime.utc_now()
         }}
      end
    }

    assert {:ok, _} =
             Targets.dispatch_target_observation(clearance, invocation, actor: context.operator)
  end

  defp file_request(context, file) do
    request(context.linux, context.ssh, :observation, :auto,
      capability: "observe.command",
      operation: "system.inspect",
      parameters: %{"command" => "inspect file", "files" => %{"payload" => file}}
    )
  end

  defp request(target, method, kind, mode, opts) do
    struct!(Request,
      kind: kind,
      authority_mode: mode,
      target_id: target.id,
      target_revision: target.revision,
      access_method_id: method.id,
      access_method_revision: method.revision,
      capability: Keyword.fetch!(opts, :capability),
      operation: Keyword.fetch!(opts, :operation),
      selectors: Keyword.get(opts, :selectors, %{}),
      parameters: Keyword.get(opts, :parameters, %{}),
      operation_id: if(kind in [:effect, :verification], do: "operation-1"),
      idempotency_key: if(kind == :effect, do: "idempotency-1")
    )
  end

  defp create_target!(admin, name, kind, type_id) do
    Targets.create_target!(name, kind, type_id, %{}, nil, actor: admin)
  end

  defp create_method!(admin, provider, target, name, method, endpoint) do
    Targets.create_access_method!(
      target.id,
      provider.id,
      name,
      method,
      endpoint,
      provider.revision,
      100,
      ["observe.command", "effect.command"],
      actor: admin
    )
    |> then(&Targets.check_access_method!(&1.id, &1.revision, %{}, actor: admin))
  end

  defp enabled_target_provider!(admin) do
    provider =
      Providers.create_provider!(
        "target-provider",
        :target,
        "fixture-target",
        %{"endpoint" => "reachable"},
        %{"token" => "private-token"},
        actor: admin
      )

    Providers.enable_provider!(provider, provider.revision, actor: admin)
  end

  defp invocation(%_{} = response),
    do: %{test_pid: self(), respond: fn -> {:ok, response} end}

  defp invocation(response), do: %{test_pid: self(), respond: fn -> response.() end}

  defp flunk_response, do: fn -> flunk("denied request reached adapter") end

  defp request_error(%{errors: errors}) do
    Enum.find_value(errors, fn
      %RequestError{} = error -> error
      nested when is_map(nested) -> request_error(nested)
      _other -> nil
    end)
  end

  defp request_error(_error), do: nil
end
