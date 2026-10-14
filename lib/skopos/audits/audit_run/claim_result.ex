defmodule Skopos.Audits.AuditRun.ClaimResult do
  @moduledoc false

  @enforce_keys [:state, :run, :schedule]
  defstruct @enforce_keys

  @type t :: %__MODULE__{
          state: :claimed | :terminal,
          run: struct(),
          schedule: struct()
        }
end
