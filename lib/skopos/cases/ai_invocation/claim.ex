defmodule Skopos.Cases.AIInvocation.Claim do
  @moduledoc false

  @enforce_keys [:state, :invocation]
  defstruct @enforce_keys ++ [invocation_context: nil]

  @type t :: %__MODULE__{
          state: :claimed | :interrupted | :terminal,
          invocation: struct(),
          invocation_context: Skopos.Cases.Case.InvocationContext.t() | nil
        }
end
