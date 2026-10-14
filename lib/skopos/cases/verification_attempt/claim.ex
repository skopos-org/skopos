defmodule Skopos.Cases.VerificationAttempt.Claim do
  @moduledoc false

  @enforce_keys [:state, :attempt]
  defstruct @enforce_keys ++ [actor: nil, clearance: nil, invocation_context: nil]

  @type t :: %__MODULE__{
          state: :claimed | :terminal,
          attempt: struct(),
          actor: struct() | nil,
          clearance: Skopos.Targets.TargetRequest.Clearance.t() | nil,
          invocation_context: Skopos.Cases.Case.InvocationContext.t() | nil
        }
end
