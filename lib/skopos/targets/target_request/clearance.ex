defmodule Skopos.Targets.TargetRequest.Clearance do
  @moduledoc false

  @enforce_keys [
    :actor_id,
    :kind,
    :authority_mode,
    :target_id,
    :target_revision,
    :access_method_id,
    :access_method_revision,
    :provider_id,
    :provider_revision,
    :capability,
    :operation,
    :selectors,
    :parameters,
    :operation_id,
    :idempotency_key,
    :reference,
    :expected,
    :max_attempts,
    :digest
  ]

  defstruct @enforce_keys
end
