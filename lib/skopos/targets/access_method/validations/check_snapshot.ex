defmodule Skopos.Targets.AccessMethod.Validations.CheckSnapshot do
  use Ash.Resource.Validation

  @impl true
  def init(opts) do
    {:ok, opts}
  end

  @impl true
  def validate(changeset, _opts, _context) do
    alias Skopos.{Providers, Targets}
    argument = &Ash.Changeset.get_argument(changeset, &1)
    record = changeset.data
    catalog = argument.(:capability_catalog)

    with true <- record.check_status == :checking,
         true <- record.check_attempt_id == argument.(:attempt_id),
         true <- record.connection_revision == argument.(:connection_revision),
         true <- record.active,
         true <-
           (argument.(:status) == :passed and not is_nil(catalog)) or
             (argument.(:status) == :failed and is_nil(catalog)),
         {:ok, %{active: true} = target} <-
           Targets.get_target(record.target_id, authorize?: false),
         true <- target.revision == argument.(:target_revision),
         {:ok, _provider} <-
           Providers.load_provider_for_invocation(
             record.provider_id,
             record.provider_revision,
             :target,
             authorize?: false
           ) do
      :ok
    else
      _ -> {:error, field: :check_status, message: "connection check is stale"}
    end
  end
end
