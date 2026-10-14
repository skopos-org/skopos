defmodule Skopos.ProvidersTest do
  use Skopos.DataCase, async: false

  alias Skopos.Accounts
  alias Skopos.Providers

  import ExUnit.CaptureLog

  @password "correct horse battery staple"
  @token "private-provider-token"

  defmodule IncompleteTarget do
    @behaviour Skopos.Providers.Adapter

    @impl true
    def type, do: "incomplete-target"
    @impl true
    def kind, do: :target
    @impl true
    def build(_configuration, _credentials), do: {:ok, %{}}
    @impl true
    def check(_state, _input), do: :ok
  end

  setup do
    admin = Accounts.bootstrap!("admin@example.com", @password, @password, authorize?: true)

    operator =
      Accounts.create_user!("operator@example.com", @password, :operator, actor: admin)

    viewer = Accounts.create_user!("viewer@example.com", @password, :viewer, actor: admin)

    %{admin: admin, operator: operator, viewer: viewer}
  end

  test "registration rejects a Target adapter without its role contract", context do
    adapters = Application.fetch_env!(:skopos, :provider_adapters)
    Application.put_env(:skopos, :provider_adapters, adapters ++ [IncompleteTarget])
    on_exit(fn -> Application.put_env(:skopos, :provider_adapters, adapters) end)

    assert {:error, error} =
             Providers.create_provider(
               "Incomplete Target",
               :target,
               "incomplete-target",
               %{},
               %{},
               actor: context.admin
             )

    assert Exception.message(error) =~ "is not available"
    assert Providers.list_providers!(actor: context.admin) == []
  end

  test "every configured Target adapter can be registered through the domain action", context do
    providers =
      Application.fetch_env!(:skopos, :provider_adapters)
      |> Enum.filter(&(&1.kind() == :target))
      |> Enum.map(fn adapter ->
        Providers.create_provider!(
          "Credentials for #{adapter.type()}",
          :target,
          adapter.type(),
          %{},
          %{},
          actor: context.admin
        )
      end)

    assert providers != []

    assert MapSet.new(Providers.list_providers!(actor: context.admin), & &1.id) ==
             MapSet.new(providers, & &1.id)
  end

  test "Target credentials enable after pure validation and remote checks belong to Methods",
       context do
    provider =
      Providers.create_provider!(
        "HTTP credentials",
        :target,
        "http-api",
        %{},
        %{"bearer_token" => @token},
        actor: context.admin
      )

    enabled = Providers.enable_provider!(provider, provider.revision, actor: context.admin)
    assert enabled.enabled
    assert is_nil(enabled.check_status)

    assert Providers.load_provider_for_invocation!(enabled.id, enabled.revision, :target,
             authorize?: false
           ).credentials == %{"bearer_token" => @token}

    assert {:error, _} =
             Providers.check_provider(
               enabled.id,
               enabled.revision,
               %{"endpoint" => "http://192.0.2.1"},
               actor: context.admin
             )

    invalid =
      Providers.create_provider!(
        "invalid HTTP configuration",
        :target,
        "http-api",
        %{"timeout_ms" => -1},
        %{},
        actor: context.admin
      )

    assert {:error, _} =
             Providers.enable_provider(invalid, invalid.revision, actor: context.admin)
  end

  test "Ash interface stores only ciphertext and enforces lifecycle policy", context do
    provider = create_provider!(context.admin, "reachable")

    assert provider.revision == 1
    assert provider.kind == :inventory
    refute provider.enabled
    assert %Ash.NotLoaded{} = provider.credentials
    assert is_binary(provider.encrypted_credentials)
    refute provider.encrypted_credentials =~ @token
    refute inspect(provider) =~ @token

    assert [listed] = Providers.list_providers!(actor: context.operator)
    assert listed.id == provider.id
    assert [listed_for_viewer] = Providers.list_providers!(actor: context.viewer)
    assert listed_for_viewer.id == provider.id

    protected =
      Providers.get_provider!(provider.id,
        actor: context.operator,
        load: [:credentials]
      )

    assert %Ash.ForbiddenField{} = protected.credentials

    assert {:error, %Ash.Error.Forbidden{}} =
             Providers.create_provider(
               "forbidden",
               :inventory,
               "fixture-inventory",
               %{"source" => "reachable"},
               %{"token" => @token},
               actor: context.operator
             )

    assert {:error, error} =
             Providers.create_provider(
               "wrong-kind",
               :target,
               "fixture-inventory",
               %{"source" => "reachable"},
               %{"token" => @token},
               actor: context.admin
             )

    assert Exception.message(error) =~ "does not match"
    refute inspect(error) =~ @token

    assert {:error, %Ash.Error.Forbidden{}} =
             Providers.record_provider_check(
               provider,
               1,
               :passed,
               nil,
               nil,
               actor: context.admin
             )
  end

  test "check, enable, edit, and disable use the current revision", context do
    provider = create_provider!(context.admin, "reachable")

    checked = Providers.check_provider!(provider.id, 1, %{}, actor: context.admin)
    assert checked.check_status == :passed
    assert checked.checked_revision == 1
    assert %Ash.NotLoaded{} = checked.credentials

    enabled = Providers.enable_provider!(checked, 1, actor: context.admin)
    assert enabled.enabled

    failed_recheck =
      Providers.check_provider!(enabled.id, 1, %{"fail" => true}, actor: context.admin)

    refute failed_recheck.enabled
    assert failed_recheck.check_category == :unreachable

    edited =
      Providers.update_provider!(
        failed_recheck,
        1,
        %{name: "renamed", configuration: %{"source" => "reachable"}},
        actor: context.admin
      )

    assert edited.revision == 2
    refute edited.enabled
    assert is_nil(edited.checked_revision)
    assert is_nil(edited.check_status)
    assert {:error, _error} = Providers.enable_provider(edited, 2, actor: context.admin)

    checked_again = Providers.check_provider!(edited.id, 2, %{}, actor: context.admin)
    enabled_again = Providers.enable_provider!(checked_again, 2, actor: context.admin)
    disabled = Providers.disable_provider!(enabled_again, 2, actor: context.admin)
    refute disabled.enabled
  end

  test "connection failures remain distinct and persisted messages redact secrets", context do
    for category <- ~w(authentication unreachable capability) do
      provider = create_provider!(context.admin, category, category)
      checked = Providers.check_provider!(provider.id, 1, %{}, actor: context.admin)

      assert checked.check_status == :failed
      assert checked.check_category == String.to_existing_atom(category)
      assert checked.check_message == "fixture #{category}"
    end

    invalid_configuration =
      Providers.create_provider!(
        "invalid-configuration",
        :inventory,
        "fixture-inventory",
        %{},
        %{"token" => @token},
        actor: context.admin
      )
      |> then(&Providers.check_provider!(&1.id, 1, %{}, actor: context.admin))

    assert invalid_configuration.check_category == :invalid_configuration

    provider_failure = create_provider!(context.admin, "invalid_response", "provider-failure")

    assert Providers.check_provider!(provider_failure.id, 1, %{}, actor: context.admin).check_category ==
             :provider_failure

    log =
      capture_log([level: :debug], fn ->
        redacted = create_provider!(context.admin, "echo", "redaction")
        checked = Providers.check_provider!(redacted.id, 1, %{}, actor: context.admin)
        send(self(), {:redacted_check, checked})
      end)

    assert_receive {:redacted_check, checked}

    assert checked.check_category == :authentication
    assert checked.check_message == "credential [REDACTED] was rejected"
    refute inspect(checked) =~ @token
    refute log =~ @token
  end

  test "a stale check result cannot overwrite a newer Provider revision", context do
    provider = create_provider!(context.admin, "reachable")

    edited =
      Providers.update_provider!(
        provider,
        1,
        %{configuration: %{"source" => "reachable"}},
        actor: context.admin
      )

    assert {:error, %Ash.Error.Invalid{} = error} =
             Providers.record_provider_check(
               provider,
               1,
               :passed,
               nil,
               nil,
               actor: context.admin,
               authorize?: false
             )

    assert Exception.message(error) =~ "is stale"
    refute inspect(error) =~ @token
    assert edited.revision == 2

    current = Providers.get_provider!(provider.id, actor: context.admin)
    assert current.revision == 2
    assert is_nil(current.checked_revision)
  end

  test "Inventory invocation requires its current Provider check", context do
    provider = create_provider!(context.admin, "reachable")

    assert {:error, _error} =
             Providers.load_provider_for_invocation(
               provider.id,
               1,
               :inventory,
               authorize?: false
             )

    checked = Providers.check_provider!(provider.id, 1, %{}, actor: context.admin)
    enabled = Providers.enable_provider!(checked, 1, actor: context.admin)

    eligible =
      Providers.load_provider_for_invocation!(
        enabled.id,
        1,
        :inventory,
        authorize?: false
      )

    assert eligible.id == enabled.id
    assert eligible.credentials == %{"token" => @token}

    for {revision, kind} <- [{2, :inventory}, {1, :target}] do
      assert {:error, _error} =
               Providers.load_provider_for_invocation(
                 enabled.id,
                 revision,
                 kind,
                 authorize?: false
               )
    end

    assert {:error, %Ash.Error.Invalid{}} =
             Providers.load_provider_for_invocation(
               enabled.id,
               1,
               :inventory,
               actor: context.admin
             )

    disabled = Providers.disable_provider!(enabled, 1, actor: context.admin)

    assert {:error, _error} =
             Providers.load_provider_for_invocation(
               disabled.id,
               1,
               :inventory,
               authorize?: false
             )
  end

  defp create_provider!(admin, endpoint, name \\ "primary") do
    Providers.create_provider!(
      name,
      :inventory,
      "fixture-inventory",
      %{"source" => endpoint},
      %{"token" => @token},
      actor: admin
    )
  end
end
