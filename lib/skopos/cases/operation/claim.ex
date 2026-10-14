defmodule Skopos.Cases.Operation.Claim do
  @moduledoc false

  @enforce_keys [:state, :operation]
  defstruct @enforce_keys ++ [actor: nil, clearance: nil, invocation_context: nil]

  @type t :: %__MODULE__{
          state: :claimed | :deferred | :terminal,
          operation: struct(),
          actor: struct() | nil,
          clearance: Skopos.Targets.TargetRequest.Clearance.t() | nil,
          invocation_context: Skopos.Cases.Case.InvocationContext.t() | nil
        }
end
