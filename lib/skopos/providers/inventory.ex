defmodule Skopos.Providers.Inventory do
  @moduledoc false

  defmodule Request do
    @moduledoc false
    @enforce_keys [:provider_revision, :scope]
    defstruct @enforce_keys ++ [max_pages: 100]
    @type t :: %__MODULE__{}
  end

  defmodule Record do
    @moduledoc false
    @enforce_keys [:external_id, :kind, :source_ref, :attributes]
    defstruct @enforce_keys
    @type t :: %__MODULE__{}
  end

  defmodule Page do
    @moduledoc false
    @enforce_keys [:records, :source_version]
    defstruct @enforce_keys ++ [next_cursor: nil]
    @type t :: %__MODULE__{}
  end

  defmodule Snapshot do
    @moduledoc false
    @enforce_keys [:status, :records]
    defstruct @enforce_keys ++ [source_version: nil, next_cursor: nil, error: nil]
    @type t :: %__MODULE__{}
  end

  defmodule Error do
    @moduledoc false
    use Splode.Error, class: :unknown, fields: [:category, :message]

    @impl true
    def message(error), do: error.message
  end

  @type invocation :: map()
  @type adapter_error :: {:error, :retryable | :failed | :cancelled, String.t()}

  @callback fetch_page(state :: term(), Request.t(), cursor :: String.t() | nil, invocation()) ::
              {:ok, Page.t()} | adapter_error()
end
