defmodule Skopos.Providers.Provider.Actions.Check do
  use Ash.Resource.Actions.Implementation

  alias Skopos.Providers
  alias Skopos.Providers.{Provider, Redactor, Registry}

  @impl true
  def run(input, _opts, context) do
    %{id: id, expected_revision: expected_revision, input: check_input} = input.arguments

    with {:ok, provider} <-
           Providers.get_active_provider(id,
             actor: context.actor,
             authorize?: false,
             load: [:credentials]
           ),
         :ok <- ensure_revision(provider, expected_revision),
         :ok <- ensure_remote_check_owner(provider) do
      result = check_result(provider, check_input)
      record(provider, expected_revision, result, context)
    end
  end

  defp ensure_remote_check_owner(%{kind: :target}) do
    {:error,
     Ash.Error.Changes.InvalidAttribute.exception(
       field: :kind,
       message: "Check the registered Access Method for a Target connection"
     )}
  end

  defp ensure_remote_check_owner(_provider), do: :ok

  defp ensure_revision(%{revision: revision}, revision), do: :ok

  defp ensure_revision(_provider, _expected_revision) do
    {:error, Ash.Error.Changes.StaleRecord.exception(resource: Provider, field: :revision)}
  end

  defp check_result(provider, input) do
    case Registry.fetch(provider.adapter_type) do
      {:ok, adapter} ->
        run_check(adapter, provider.configuration, provider.credentials, input)

      {:error, _reason} ->
        {:error, :provider_failure, "Provider adapter is unavailable"}
    end
  end

  defp run_check(adapter, configuration, credentials, input) do
    case Registry.build(adapter, configuration, credentials) do
      {:ok, state} -> Registry.check(adapter, state, input)
      {:error, _reason} -> {:error, :invalid_configuration, "Provider configuration is invalid"}
    end
  end

  defp record(provider, expected_revision, result, context) do
    {status, category, message} = normalize(result, provider.credentials)

    case Providers.record_provider_check(
           provider,
           expected_revision,
           status,
           category,
           message,
           actor: context.actor,
           authorize?: false
         ) do
      {:ok, updated_provider} -> {:ok, Ash.Resource.unload(updated_provider, :credentials)}
      {:error, error} -> {:error, error}
    end
  end

  defp normalize(:ok, _credentials), do: {:passed, nil, nil}

  defp normalize({:error, category, message}, credentials),
    do: {:failed, category, Redactor.message(message, credentials)}
end
