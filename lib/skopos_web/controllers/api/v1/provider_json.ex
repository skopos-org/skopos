defmodule SkoposWeb.API.V1.ProviderJSON do
  @moduledoc false

  alias Skopos.Providers
  alias Skopos.Providers.Registry
  alias Skopos.Providers.Target.AccessMethodProfile

  def reference(provider) do
    provider
    |> Map.take(Providers.Provider.reference_fields())
    |> with_access_method_profile(provider)
  end

  def data(provider) do
    record = %{
      id: provider.id,
      name: provider.name,
      kind: provider.kind,
      adapter_type: provider.adapter_type,
      configuration: provider.configuration,
      revision: provider.revision,
      enabled: provider.enabled,
      check: check(provider),
      inserted_at: provider.inserted_at,
      updated_at: provider.updated_at
    }

    with_access_method_profile(record, provider)
  end

  def summary(provider) do
    summary =
      provider
      |> Map.take(Providers.Provider.reference_fields())
      |> Map.put(:check, check(provider))

    if provider.kind == :ai do
      Map.merge(summary, %{ai_service: provider.ai_service, ai_model: provider.ai_model})
    else
      summary
    end
  end

  defp check(provider) do
    %{
      status: provider.check_status,
      category: provider.check_category,
      message: provider.check_message,
      checked_revision: provider.checked_revision,
      checked_at: provider.checked_at
    }
  end

  defp with_access_method_profile(record, provider) do
    case access_method_profile(provider) do
      nil -> record
      profile -> Map.put(record, :access_method_profile, profile)
    end
  end

  defp access_method_profile(%{kind: :target, adapter_type: type}) do
    with {:ok, adapter} <- Registry.fetch(type, Providers.Target),
         %AccessMethodProfile{} = profile <- adapter.access_method_profile() do
      %{
        method: profile.method
      }
    else
      _unrestricted -> nil
    end
  end

  defp access_method_profile(_provider), do: nil

  def capabilities(capabilities) do
    %{
      observations: Enum.map(capabilities.observations, &operation/1),
      effects: Enum.map(capabilities.effects, &operation/1)
    }
  end

  defp operation(operation) do
    %{
      capability: operation.capability,
      operation: operation.operation,
      description: operation.description,
      input_schema: operation.input_schema
    }
  end
end
