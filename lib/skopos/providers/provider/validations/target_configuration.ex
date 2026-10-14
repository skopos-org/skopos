defmodule Skopos.Providers.Provider.Validations.TargetConfiguration do
  use Ash.Resource.Validation

  @impl true
  def init(opts) do
    {:ok, opts}
  end

  @impl true
  def validate(changeset, _opts, _context) do
    alias Skopos.Providers
    alias Skopos.Providers.Registry
    provider = changeset.data

    if provider.kind == :target do
      with {:ok, current} <-
             Providers.get_active_provider(provider.id, authorize?: false, load: [:credentials]),
           true <- current.revision == provider.revision,
           {:ok, adapter} <- Registry.fetch(provider.adapter_type, Providers.Target),
           {:ok, _state} <- Registry.build(adapter, provider.configuration, current.credentials) do
        :ok
      else
        _ ->
          {:error,
           field: :configuration, message: "Target configuration or credentials are invalid"}
      end
    else
      :ok
    end
  end

  @impl true
  def atomic(changeset, opts, context), do: validate(changeset, opts, context)
end
