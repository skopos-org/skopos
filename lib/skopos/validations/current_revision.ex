defmodule Skopos.Validations.CurrentRevision do
  use Ash.Resource.Validation

  import Ash.Expr

  alias Ash.Error.Changes.InvalidAttribute

  @impl true
  def init(opts), do: {:ok, opts}

  @impl true
  def validate(changeset, _opts, _context) do
    expected_revision = Ash.Changeset.get_argument(changeset, :expected_revision)

    if Ash.Changeset.get_attribute(changeset, :revision) == expected_revision do
      :ok
    else
      {:error, field: :revision, message: "is stale"}
    end
  end

  @impl true
  def atomic(changeset, _opts, context) do
    expected_revision = Ash.Changeset.get_argument(changeset, :expected_revision)

    {:atomic, [:revision], expr(^atomic_ref(:revision) != ^expected_revision),
     expr(
       error(^InvalidAttribute, %{
         field: :revision,
         value: ^atomic_ref(:revision),
         message: ^(context.message || "is stale"),
         vars: %{}
       })
     )}
  end
end
