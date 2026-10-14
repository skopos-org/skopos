defmodule Skopos.Providers.Notification do
  @moduledoc false

  defmodule Request do
    @moduledoc false

    @enforce_keys [
      :provider_revision,
      :report_id,
      :report_revision,
      :destination_id,
      :destination_revision,
      :idempotency_key,
      :payload
    ]

    defstruct @enforce_keys
    @type t :: %__MODULE__{}
  end

  defmodule Result do
    @moduledoc false
    @enforce_keys [:status]
    defstruct @enforce_keys ++ [reference: nil, details: %{}]
    @type t :: %__MODULE__{}
  end

  defmodule Error do
    @moduledoc false
    use Splode.Error, class: :unknown, fields: [:category, :message]

    @impl true
    def message(error), do: error.message
  end

  @type invocation :: map()
  @type adapter_error :: {:error, :timeout | :failed | :cancelled, String.t()}

  @callback deliver(state :: term(), Request.t(), invocation()) ::
              {:ok, Result.t()} | adapter_error()
end
