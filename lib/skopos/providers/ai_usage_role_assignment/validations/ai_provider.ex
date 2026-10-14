defmodule Skopos.Providers.AIUsageRoleAssignment.Validations.AIProvider do
  use Ash.Resource.Validation

  @impl true
  def init(opts) do
    {:ok, opts}
  end

  @impl true
  def validate(changeset, _opts, _context) do
    provider_id = Ash.Changeset.get_attribute(changeset, :provider_id)

    case Skopos.Providers.get_provider(provider_id, authorize?: false) do
      {:ok, %{kind: :ai, retired_at: nil}} ->
        :ok

      {:ok, %{kind: :ai}} ->
        {:error, field: :provider_id, message: "has been deleted"}

      {:ok, _provider} ->
        {:error, field: :provider_id, message: "must reference an AI provider"}

      {:error, _error} ->
        {:error, field: :provider_id, message: "does not exist"}
    end
  end
end
