defmodule Skopos.Cases.ResolutionRun.BudgetResult do
  @type t :: %__MODULE__{
          status: :charged | :duplicate | :exhausted,
          case: struct() | map(),
          run: struct() | map(),
          value: term(),
          reason: String.t() | nil
        }

  @enforce_keys [:status, :case, :run]
  defstruct [:status, :case, :run, :value, :reason]
end
