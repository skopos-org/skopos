defmodule Skopos.Providers.Provider.Changes.ValidateAdapter do
  use Ash.Resource.Change

  @impl true
  def init(opts) do
    {:ok, opts}
  end

  @impl true
  def change(changeset, _opts, _context) do
    adapter_type = Ash.Changeset.get_attribute(changeset, :adapter_type)
    kind = Ash.Changeset.get_attribute(changeset, :kind)

    case Skopos.Providers.Registry.fetch(adapter_type) do
      {:ok, adapter} ->
        if Skopos.Providers.Registry.kind(adapter) == kind do
          changeset
        else
          Ash.Changeset.add_error(changeset,
            field: :kind,
            message: "does not match the selected adapter"
          )
        end

      {:error, _reason} ->
        Ash.Changeset.add_error(changeset,
          field: :adapter_type,
          message: "is not available"
        )
    end
  end
end
