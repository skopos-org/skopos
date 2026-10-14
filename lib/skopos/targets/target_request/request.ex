defmodule Skopos.Targets.TargetRequest.Request do
  @moduledoc false

  @enforce_keys [
    :kind,
    :authority_mode,
    :target_id,
    :target_revision,
    :access_method_id,
    :access_method_revision,
    :capability,
    :operation
  ]

  defstruct @enforce_keys ++
              [
                selectors: %{},
                parameters: %{},
                operation_id: nil,
                idempotency_key: nil,
                reference: nil,
                expected: %{},
                max_attempts: 1
              ]
end
