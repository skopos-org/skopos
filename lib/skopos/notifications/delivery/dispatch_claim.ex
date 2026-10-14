defmodule Skopos.Notifications.Delivery.DispatchClaim do
  @moduledoc false
  @enforce_keys [:state, :delivery]
  defstruct @enforce_keys
  @type t :: %__MODULE__{}
end
