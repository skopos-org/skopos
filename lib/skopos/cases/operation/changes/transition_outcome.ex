defmodule Skopos.Cases.Operation.Changes.TransitionOutcome do
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    AshStateMachine.transition_state(
      changeset,
      Ash.Changeset.get_attribute(changeset, :status)
    )
  end
end
