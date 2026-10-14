defmodule Skopos.Targets.MethodCheckTest do
  use Skopos.DataCase, async: false

  alias Skopos.{Accounts, Providers, Targets}
  alias Skopos.Providers.Target

  setup do
    admin =
      Accounts.bootstrap!(
        "method-check@example.invalid",
        "test-only-password",
        "test-only-password"
      )

    provider =
      Providers.create_provider!(
        "fixture",
        :target,
        "fixture-target",
        %{"endpoint" => "reachable"},
        %{"token" => "private-check-token"},
        actor: admin
      )
      |> then(&Providers.enable_provider!(&1, &1.revision, actor: admin))

    target = Targets.create_target!("unknown-host", "host", "custom-os", %{}, nil, actor: admin)

    method =
      Targets.create_access_method!(
        target.id,
        provider.id,
        "method",
        "ssh",
        "ssh://192.0.2.11:22",
        provider.revision,
        100,
        ["observe.service"],
        actor: admin
      )

    %{admin: admin, provider: provider, target: target, method: method}
  end

  test "an old completion cannot approve a changed connection", context do
    response = fn ->
      current = Targets.get_access_method!(context.method.id, actor: context.admin)

      Targets.update_access_method!(current, current.revision, %{endpoint: "ssh://192.0.2.12:22"},
        actor: context.admin
      )

      {:ok, catalog()}
    end

    assert {:error, _} =
             Targets.check_access_method(
               context.method.id,
               context.method.revision,
               %{respond: response},
               actor: context.admin
             )

    current = Targets.get_access_method!(context.method.id, actor: context.admin)
    assert current.endpoint == "ssh://192.0.2.12:22"
    assert is_nil(current.check_status)
    assert is_nil(current.operation_catalog)
  end

  test "availability requires a current Method check and the observed grant intersection",
       context do
    assert Targets.available_access_methods!(context.target.id, "observe.service",
             authorize?: false
           ) == []

    checked =
      Targets.check_access_method!(
        context.method.id,
        context.method.revision,
        %{respond: fn -> {:ok, catalog()} end},
        actor: context.admin
      )

    assert [available] =
             Targets.available_access_methods!(context.target.id, "observe.service",
               authorize?: false
             )

    assert available.id == checked.id

    edited =
      Targets.update_access_method!(
        checked,
        checked.revision,
        %{capabilities: ["observe.command"]},
        actor: context.admin
      )

    assert edited.check_current

    assert Targets.available_access_methods!(context.target.id, "observe.service",
             authorize?: false
           ) == []

    assert Targets.available_access_methods!(context.target.id, "observe.command",
             authorize?: false
           ) == []

    assert {:error, _} =
             Targets.load_access_method_for_use(edited.id, edited.revision, "observe.command",
               authorize?: false
             )
  end

  test "a newer check result cannot be overwritten by an older completion", context do
    response = fn ->
      current = Targets.get_access_method!(context.method.id, actor: context.admin)

      inner =
        Targets.check_access_method!(
          current.id,
          current.revision,
          %{respond: fn -> {:ok, %Target.Capabilities{observations: [], effects: []}} end},
          actor: context.admin
        )

      assert inner.check_status == :passed
      {:ok, catalog()}
    end

    assert {:error, _} =
             Targets.check_access_method(
               context.method.id,
               context.method.revision,
               %{respond: response},
               actor: context.admin
             )

    current = Targets.get_access_method!(context.method.id, actor: context.admin)
    assert current.check_status == :passed
    assert current.observed_capabilities == []
    assert current.operation_catalog == %Target.Capabilities{observations: [], effects: []}
  end

  test "a stopped check remains checking without earlier usable facts", context do
    checked =
      Targets.check_access_method!(
        context.method.id,
        context.method.revision,
        %{respond: fn -> {:ok, catalog()} end},
        actor: context.admin
      )

    parent = self()

    {pid, ref} =
      spawn_monitor(fn ->
        Targets.check_access_method!(
          checked.id,
          checked.revision,
          %{
            respond: fn ->
              send(parent, :remote_check_waiting)

              receive do
                :continue -> {:ok, catalog()}
              end
            end
          },
          actor: context.admin
        )
      end)

    assert_receive :remote_check_waiting, 2_000
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^ref, :process, ^pid, :killed}
    current = Targets.get_access_method!(checked.id, actor: context.admin)
    assert current.check_status == :checking
    assert current.observed_capabilities == []
    assert is_nil(current.operation_catalog)
    assert is_nil(current.checked_at)
  end

  test "currentness follows Target and credential revisions without rewriting check history",
       context do
    checked =
      Targets.check_access_method!(
        context.method.id,
        context.method.revision,
        %{respond: fn -> {:ok, catalog()} end},
        actor: context.admin
      )

    assert checked.check_current

    edited_target =
      Targets.update_target!(
        context.target,
        context.target.revision,
        %{facts: %{"serial" => "changed"}},
        actor: context.admin
      )

    current = Targets.get_access_method!(checked.id, actor: context.admin)
    refute current.check_current
    assert current.checked_target_revision != edited_target.revision

    rechecked =
      Targets.check_access_method!(
        current.id,
        current.revision,
        %{respond: fn -> {:ok, catalog()} end},
        actor: context.admin
      )

    assert rechecked.check_current

    Providers.update_provider!(
      context.provider,
      context.provider.revision,
      %{credentials: %{"token" => "changed-private-token"}},
      actor: context.admin
    )

    current = Targets.get_access_method!(checked.id, actor: context.admin)
    refute current.check_current
    assert current.check_status == :passed
    assert current.checked_at == rechecked.checked_at
  end

  test "a failed result write does not leave an earlier passed check usable", context do
    checked =
      Targets.check_access_method!(
        context.method.id,
        context.method.revision,
        %{respond: fn -> {:ok, catalog()} end},
        actor: context.admin
      )

    # Database fault fixture only; product behavior and verification use Ash actions.
    Skopos.Repo.query!("""
    CREATE FUNCTION pg_temp.reject_method_check() RETURNS trigger LANGUAGE plpgsql AS $$
    BEGIN
      IF NEW.check_status = 'passed' THEN
        RAISE EXCEPTION 'injected Method result persistence failure';
      END IF;
      RETURN NEW;
    END;
    $$;
    """)

    Skopos.Repo.query!("""
    CREATE TRIGGER reject_method_result BEFORE UPDATE ON access_methods
    FOR EACH ROW EXECUTE FUNCTION pg_temp.reject_method_check();
    """)

    assert {:error, _} =
             Targets.check_access_method(
               checked.id,
               checked.revision,
               %{respond: fn -> {:ok, catalog()} end},
               actor: context.admin
             )

    current = Targets.get_access_method!(checked.id, actor: context.admin)
    assert current.check_status == :checking
    assert current.observed_capabilities == []
    assert is_nil(current.operation_catalog)
  end

  defp catalog do
    schema = %{"type" => "object", "properties" => %{}, "additionalProperties" => false}

    %Target.Capabilities{
      effects: [],
      observations: [
        %Target.Operation{
          capability: "observe.service",
          operation: "service.inspect",
          description: "Inspect service",
          input_schema: schema,
          output_schema: schema
        }
      ]
    }
  end
end
