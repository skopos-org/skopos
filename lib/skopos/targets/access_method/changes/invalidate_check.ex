defmodule Skopos.Targets.AccessMethod.Changes.InvalidateCheck do
  use Ash.Resource.Change

  @impl true
  def init(opts) do
    {:ok, opts}
  end

  @impl true
  def change(changeset, _opts, _context) do
    if Enum.any?(
         [:target_id, :provider_id, :provider_revision, :method, :endpoint],
         &Ash.Changeset.changing_attribute?(changeset, &1)
       ) do
      changeset
      |> Ash.Changeset.change_attribute(
        :connection_revision,
        changeset.data.connection_revision + 1
      )
      |> Ash.Changeset.change_attribute(:check_status, nil)
      |> Ash.Changeset.change_attribute(:check_attempt_id, nil)
      |> Ash.Changeset.change_attribute(:checked_at, nil)
      |> Ash.Changeset.change_attribute(:check_message, nil)
      |> Ash.Changeset.change_attribute(:checked_connection_revision, nil)
      |> Ash.Changeset.change_attribute(:checked_target_revision, nil)
      |> Ash.Changeset.change_attribute(:observed_capabilities, [])
      |> Ash.Changeset.change_attribute(:operation_catalog, nil)
    else
      changeset
    end
  end
end
