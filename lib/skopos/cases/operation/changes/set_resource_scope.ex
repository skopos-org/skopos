defmodule Skopos.Cases.Operation.Changes.SetResourceScope do
  use Ash.Resource.Change

  alias Skopos.Targets
  alias Skopos.Targets.ResourceScope

  @impl true
  def change(changeset, _opts, _context) do
    capability = Ash.Changeset.get_attribute(changeset, :capability)
    operation = Ash.Changeset.get_attribute(changeset, :operation)
    selectors = Ash.Changeset.get_attribute(changeset, :selectors)
    access_method_id = Ash.Changeset.get_attribute(changeset, :access_method_id)

    method =
      case Targets.get_access_method(access_method_id, authorize?: false) do
        {:ok, method} -> method
        _unavailable -> nil
      end

    Ash.Changeset.change_attribute(
      changeset,
      :resource_scope,
      ResourceScope.key(method, capability, operation, selectors)
    )
  end
end
