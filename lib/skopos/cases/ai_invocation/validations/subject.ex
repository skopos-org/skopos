defmodule Skopos.Cases.AIInvocation.Validations.Subject do
  use Ash.Resource.Validation

  @impl true
  def init(opts), do: {:ok, opts}

  @impl true
  def validate(changeset, _opts, _context) do
    role = Ash.Changeset.get_attribute(changeset, :role)
    turn_id = Ash.Changeset.get_attribute(changeset, :turn_id)
    proposal_id = Ash.Changeset.get_attribute(changeset, :proposal_id)

    case {role, turn_id, proposal_id} do
      {:resolver, turn_id, nil} when is_binary(turn_id) -> :ok
      {:reviewer, nil, proposal_id} when is_binary(proposal_id) -> :ok
      {:reviewer, turn_id, nil} when is_binary(turn_id) -> :ok
      _invalid -> {:error, field: :role, message: "does not match the invocation subject"}
    end
  end
end
