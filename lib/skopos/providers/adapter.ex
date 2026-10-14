defmodule Skopos.Providers.Adapter do
  @moduledoc false

  @type kind :: :ai | :signal | :target | :inventory | :notification
  @type check_failure ::
          :invalid_configuration
          | :authentication
          | :unreachable
          | :capability
          | :provider_failure

  @callback type() :: String.t()
  @callback kind() :: kind()
  @callback build(configuration :: map(), credentials :: map()) ::
              {:ok, state :: term()} | {:error, term()}
  @callback check(state :: term(), input :: map()) ::
              :ok | {:error, check_failure(), String.t()}
end
