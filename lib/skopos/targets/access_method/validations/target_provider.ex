defmodule Skopos.Targets.AccessMethod.Validations.TargetProvider do
  use Ash.Resource.Validation

  alias Skopos.{Providers, Targets}
  alias Skopos.Providers.Registry
  alias Skopos.Providers.Target.AccessMethodProfile
  alias Skopos.Targets.TypeCatalog

  @impl true
  def init(opts), do: {:ok, opts}

  @impl true
  def validate(changeset, _opts, _context) do
    provider_id = Ash.Changeset.get_attribute(changeset, :provider_id)
    provider_revision = Ash.Changeset.get_attribute(changeset, :provider_revision)

    case Providers.load_provider_for_invocation(
           provider_id,
           provider_revision,
           :target,
           authorize?: false
         ) do
      {:ok, provider} ->
        validate_profile(changeset, provider)

      {:error, _error} ->
        {:error,
         field: :provider_id,
         message: "must reference an enabled target Provider at the specified revision"}
    end
  end

  defp validate_profile(changeset, provider) do
    case Registry.fetch(provider.adapter_type, Providers.Target) do
      {:ok, adapter} ->
        case adapter.access_method_profile() do
          :unrestricted ->
            :ok

          %AccessMethodProfile{} = profile ->
            validate_binding(changeset, provider, profile, adapter)

          _invalid ->
            {:error, field: :provider_id, message: "Target Provider has no binding profile"}
        end

      {:error, _reason} ->
        {:error, field: :provider_id, message: "must reference a Target Provider adapter"}
    end
  end

  defp validate_binding(changeset, provider, profile, adapter) do
    target_id = Ash.Changeset.get_attribute(changeset, :target_id)
    capabilities = Ash.Changeset.get_attribute(changeset, :capabilities)

    connection = %Providers.Target.Connection{
      endpoint: Ash.Changeset.get_attribute(changeset, :endpoint)
    }

    with true <- Ash.Changeset.get_attribute(changeset, :method) == profile.method,
         {:ok, state} <- Registry.build(adapter, provider.configuration, provider.credentials),
         {:ok, _state} <- adapter.bind_connection(state, connection),
         true <- is_list(capabilities),
         true <- Enum.uniq(capabilities) == capabilities,
         true <- Enum.all?(capabilities, &(&1 in profile.capabilities)),
         {:ok, %{active: true} = target} <- Targets.get_target(target_id, authorize?: false),
         true <- TypeCatalog.allows_method?(target.type_id, provider.adapter_type) do
      :ok
    else
      _other ->
        {:error,
         field: :method,
         message: "Access Method must match its Provider, Target and granted capabilities"}
    end
  end
end
