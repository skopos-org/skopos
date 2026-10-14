defmodule Skopos.Targets.TargetRequest do
  use Ash.Resource,
    otp_app: :skopos,
    domain: Skopos.Targets,
    authorizers: [Ash.Policy.Authorizer]

  actions do
    action :clear_request, :struct do
      constraints instance_of: Skopos.Targets.TargetRequest.Clearance
      transaction? false

      argument :request, :struct,
        allow_nil?: false,
        constraints: [instance_of: Skopos.Targets.TargetRequest.Request]

      run {Skopos.Targets.TargetRequest.Actions.Dispatch, operation: :clear}
    end

    action :dispatch_observation, :struct do
      constraints instance_of: Skopos.Providers.Target.Observation
      transaction? false

      argument :clearance, :struct,
        allow_nil?: false,
        constraints: [instance_of: Skopos.Targets.TargetRequest.Clearance]

      argument :invocation, :map, allow_nil?: false, default: %{}
      run {Skopos.Targets.TargetRequest.Actions.Dispatch, operation: :observe}
    end

    action :dispatch_effect, :struct do
      public? false
      constraints instance_of: Skopos.Providers.Target.EffectResult
      transaction? false

      argument :clearance, :struct,
        allow_nil?: false,
        constraints: [instance_of: Skopos.Targets.TargetRequest.Clearance]

      argument :invocation, :map, allow_nil?: false, default: %{}
      run {Skopos.Targets.TargetRequest.Actions.Dispatch, operation: :effect}
    end

    action :dispatch_verification, :struct do
      constraints instance_of: Skopos.Providers.Target.Verification
      transaction? false

      argument :clearance, :struct,
        allow_nil?: false,
        constraints: [instance_of: Skopos.Targets.TargetRequest.Clearance]

      argument :invocation, :map, allow_nil?: false, default: %{}
      run {Skopos.Targets.TargetRequest.Actions.Dispatch, operation: :verify}
    end
  end

  policies do
    policy action([:clear_request, :dispatch_observation, :dispatch_verification]) do
      authorize_if actor_attribute_equals(:role, :admin)
      authorize_if actor_attribute_equals(:role, :operator)
    end

    policy action(:dispatch_effect) do
      forbid_if always()
    end
  end
end
