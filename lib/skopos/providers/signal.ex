defmodule Skopos.Providers.Signal do
  @moduledoc false

  defmodule Envelope do
    @moduledoc false
    @enforce_keys [:body, :headers, :received_at]
    defstruct @enforce_keys
    @type t :: %__MODULE__{body: binary(), headers: map(), received_at: DateTime.t()}
  end

  defmodule AuthenticatedReceipt do
    @moduledoc false
    @enforce_keys [:receipt_id, :source]
    defstruct @enforce_keys ++ [metadata: %{}]
    @type t :: %__MODULE__{}
  end

  defmodule Event do
    @moduledoc false
    @enforce_keys [:receipt_id, :event_key, :state, :occurred_at]

    defstruct @enforce_keys ++
                [
                  source_sequence: nil,
                  target_ref: nil,
                  attributes: %{},
                  metadata: %{}
                ]

    @type t :: %__MODULE__{}
  end

  defmodule IngestResult do
    @moduledoc false
    @enforce_keys [:receipt, :events]
    defstruct @enforce_keys
    @type t :: %__MODULE__{}
  end

  defmodule Error do
    @moduledoc false
    use Splode.Error, class: :unknown, fields: [:category, :message]

    @impl true
    def message(error), do: error.message
  end

  @type invocation :: map()
  @type adapter_error :: {:error, :authentication | :invalid_input | :failed, String.t()}

  @callback authenticate(state :: term(), Envelope.t(), invocation()) ::
              {:ok, AuthenticatedReceipt.t()} | adapter_error()
  @callback normalize(state :: term(), Envelope.t(), AuthenticatedReceipt.t(), invocation()) ::
              {:ok, [Event.t()]} | adapter_error()
end
