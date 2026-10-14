defmodule Skopos.AuthoritySettingTest do
  use Skopos.DataCase, async: false

  alias Skopos.{Accounts, Cases}

  @password "correct horse battery staple"

  setup do
    admin =
      Accounts.bootstrap!("authority-admin@example.com", @password, @password, authorize?: true)

    operator =
      Accounts.create_user!("authority-operator@example.com", @password, :operator, actor: admin)

    viewer =
      Accounts.create_user!("authority-viewer@example.com", @password, :viewer, actor: admin)

    %{admin: admin, operator: operator, viewer: viewer}
  end

  test "a fresh database exposes one finite readonly default with automation disabled", context do
    setting = Cases.current_authority_setting!(actor: context.viewer)

    assert setting.authority_mode == :readonly
    refute setting.signal_automation_enabled
    assert setting.setting_revision == 1
    assert setting.reason == "system bootstrap"
    assert is_nil(setting.changed_by_id)

    assert setting.max_elapsed_seconds == 3_600
    assert setting.max_resolver_turns == 20
    assert setting.max_target_requests == 100
    assert setting.max_effects == 10
    assert setting.max_related_targets == 20
    assert setting.max_ai_usage_units == 1_000_000
    assert setting.max_no_progress_turns == 3

    refute Map.has_key?(Map.from_struct(setting), :commands)
    refute Map.has_key?(Map.from_struct(setting), :alert_conditions)
    refute Map.has_key?(Map.from_struct(setting), :remediation_steps)
  end

  test "an administrator replaces the complete setting and preserves its audit history",
       context do
    initial = Cases.current_authority_setting!(actor: context.admin)

    configured =
      configure!(initial, context.admin, %{
        authority_mode: :auto,
        signal_automation_enabled: true,
        max_elapsed_seconds: 7_200,
        max_resolver_turns: 40,
        reason: "enable supervised autonomous resolution"
      })

    assert configured.setting_revision == 2
    assert configured.authority_mode == :auto
    assert configured.signal_automation_enabled
    assert configured.max_elapsed_seconds == 7_200
    assert configured.max_resolver_turns == 40
    assert configured.changed_by_id == context.admin.id

    assert Cases.current_authority_setting!(actor: context.operator).id == configured.id

    history =
      Cases.list_authority_settings!(actor: context.viewer)
      |> Enum.sort_by(& &1.setting_revision)

    assert [bootstrap, current] = history
    assert bootstrap.id == initial.id
    refute bootstrap.active
    assert bootstrap.authority_mode == :readonly
    assert bootstrap.setting_revision == 1
    assert current.id == configured.id
    assert current.active
  end

  test "stale, concurrent, and invalid changes leave exactly one current revision", context do
    initial = Cases.current_authority_setting!(actor: context.admin)

    attempts =
      for reason <- ["first concurrent edit", "second concurrent edit"] do
        Task.async(fn -> configure(initial, context.admin, %{reason: reason}) end)
      end
      |> Task.await_many()

    assert Enum.count(attempts, &match?({:ok, _setting}, &1)) == 1
    assert Enum.count(attempts, &match?({:error, _error}, &1)) == 1

    current = Cases.current_authority_setting!(actor: context.admin)
    assert current.setting_revision == 2

    assert {:error, _error} = configure(initial, context.admin, %{reason: "stale edit"})

    assert {:error, _error} =
             Cases.configure_authority_setting(
               current.setting_revision,
               :auto,
               true,
               59,
               current.max_resolver_turns,
               current.max_target_requests,
               current.max_effects,
               current.max_related_targets,
               current.max_ai_usage_units,
               current.max_no_progress_turns,
               "invalid elapsed limit",
               actor: context.admin
             )

    settings = Cases.list_authority_settings!(actor: context.admin)
    assert Enum.count(settings, & &1.active) == 1
    assert length(settings) == 2
    assert Cases.current_authority_setting!(actor: context.admin).id == current.id
  end

  test "operator and viewer cannot change or bypass standing settings", context do
    initial = Cases.current_authority_setting!(actor: context.operator)

    assert {:error, %Ash.Error.Forbidden{}} =
             configure(initial, context.operator, %{reason: "operator edit"})

    assert {:error, %Ash.Error.Forbidden{}} =
             configure(initial, context.viewer, %{reason: "viewer edit"})

    assert {:error, %Ash.Error.Forbidden{}} =
             Cases.create_authority_setting_revision(
               setting_attributes(initial, %{setting_revision: 2, reason: "direct create"}),
               actor: context.admin
             )
  end

  defp configure!(current, actor, overrides) do
    {:ok, setting} = configure(current, actor, overrides)
    setting
  end

  defp configure(current, actor, overrides) do
    values = setting_attributes(current, overrides)

    Cases.configure_authority_setting(
      current.setting_revision,
      values.authority_mode,
      values.signal_automation_enabled,
      values.max_elapsed_seconds,
      values.max_resolver_turns,
      values.max_target_requests,
      values.max_effects,
      values.max_related_targets,
      values.max_ai_usage_units,
      values.max_no_progress_turns,
      values.reason,
      actor: actor
    )
  end

  defp setting_attributes(current, overrides) do
    %{
      authority_mode: current.authority_mode,
      signal_automation_enabled: current.signal_automation_enabled,
      max_elapsed_seconds: current.max_elapsed_seconds,
      max_resolver_turns: current.max_resolver_turns,
      max_target_requests: current.max_target_requests,
      max_effects: current.max_effects,
      max_related_targets: current.max_related_targets,
      max_ai_usage_units: current.max_ai_usage_units,
      max_no_progress_turns: current.max_no_progress_turns,
      setting_revision: current.setting_revision,
      active: true,
      reason: "update standing controls"
    }
    |> Map.merge(overrides)
  end
end
