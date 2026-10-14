defmodule Skopos.Targets.Target.Validations.Type do
  use Ash.Resource.Validation

  alias Skopos.Targets.TypeCatalog

  @impl true
  def init(opts), do: {:ok, opts}

  @impl true
  def validate(changeset, _opts, _context) do
    type_id = Ash.Changeset.get_attribute(changeset, :type_id)
    kind = Ash.Changeset.get_attribute(changeset, :kind)

    case TypeCatalog.fetch(type_id) do
      %{kind: ^kind} -> :ok
      nil -> {:error, field: :type_id, message: "must identify a supported Target type"}
      _type -> {:error, field: :kind, message: "must match the Target type"}
    end
  end
end
