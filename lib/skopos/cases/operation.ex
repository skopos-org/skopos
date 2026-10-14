defmodule Skopos.Cases.Operation do
  use Ash.Resource,
    otp_app: :skopos,
    domain: Skopos.Cases,
    authorizers: [Ash.Policy.Authorizer],
    simple_notifiers: [Skopos.Cases.Case.RealtimeNotifier],
    data_layer: AshPostgres.DataLayer,
    extensions: [AshStateMachine, AshCloak]

  @summary_fields ~w(id case_id resolution_run_id proposal_id approval_id actor_id target_id access_method_id provider_id status case_generation authority_mode request_kind purpose capability operation dispatch_started_at outcome_category accepted_at not_before completed_at revision inserted_at updated_at)a

  def summary_fields, do: @summary_fields

  postgres do
    table "operations"
    repo Skopos.Repo

    custom_indexes do
      index [:case_id]
      index [:resolution_run_id]
      index [:target_id]
      index [:target_id, :resource_scope]
    end
  end

  field_policies do
    private_fields :include

    field_policy [:protected_reference, :encrypted_protected_reference] do
      forbid_if always()
    end

    field_policy :* do
      authorize_if always()
    end
  end

  state_machine do
    state_attribute :status
    initial_states [:queued]
    default_initial_state :queued

    transitions do
      transition :mark_dispatching, from: :queued, to: :dispatching
      transition :retry_unsent, from: :dispatching, to: :queued
      transition :record_no_send, from: [:queued, :dispatching], to: :failed

      transition :record_outcome,
        from: :dispatching,
        to: [:applied, :failed, :partial, :unknown]
    end
  end

  cloak do
    vault(Skopos.Vault)
    attributes([:protected_reference])
  end

  actions do
    defaults [:read]

    read :for_case do
      argument :case_id, :uuid, allow_nil?: false
      filter expr(case_id == ^arg(:case_id))
      prepare build(sort: [updated_at: :desc, id: :desc], limit: 100)
    end

    read :summaries_for_case do
      argument :case_id, :uuid, allow_nil?: false
      filter expr(case_id == ^arg(:case_id))
      prepare build(select: @summary_fields, sort: [updated_at: :desc, id: :desc], limit: 100)
    end

    read :page_for_case do
      argument :case_id, :uuid, allow_nil?: false
      filter expr(case_id == ^arg(:case_id))
      pagination keyset?: true, required?: true, default_limit: 100, max_page_size: 500
      prepare build(select: @summary_fields, sort: [inserted_at: :desc, id: :desc])
    end

    read :latest_recovery_effect do
      argument :case_id, :uuid, allow_nil?: false
      argument :condition_ids, {:array, :uuid}
      argument :exclude_operation_id, :uuid

      filter expr(
               case_id == ^arg(:case_id) and purpose == :remediation and
                 not (status == :failed and is_nil(dispatch_started_at)) and
                 (is_nil(^arg(:exclude_operation_id)) or id != ^arg(:exclude_operation_id)) and
                 (is_nil(^arg(:condition_ids)) or
                    exists(
                      proposal,
                      fragment(
                        "EXISTS (SELECT 1 FROM unnest(?) AS affected WHERE (affected->>'condition_id')::uuid = ANY(?::uuid[]))",
                        affected_conditions,
                        ^arg(:condition_ids)
                      )
                    ))
             )

      prepare build(select: @summary_fields, sort: [accepted_at: :desc, id: :desc], limit: 1)
    end

    read :latest_applied_recovery_effect do
      argument :case_id, :uuid, allow_nil?: false
      argument :resolution_run_id, :uuid, allow_nil?: false
      argument :condition_ids, {:array, :uuid}, allow_nil?: false, constraints: [min_length: 1]

      filter expr(
               case_id == ^arg(:case_id) and resolution_run_id == ^arg(:resolution_run_id) and
                 purpose == :remediation and status == :applied and not is_nil(completed_at) and
                 exists(
                   proposal,
                   fragment(
                     "EXISTS (SELECT 1 FROM unnest(?) AS affected WHERE (affected->>'condition_id')::uuid = ANY(?::uuid[]))",
                     affected_conditions,
                     ^arg(:condition_ids)
                   )
                 )
             )

      prepare build(select: @summary_fields, sort: [completed_at: :desc, id: :desc], limit: 1)
    end

    read :recent_method_observations do
      argument :case_id, :uuid, allow_nil?: false
      argument :resolution_run_id, :uuid, allow_nil?: false
      argument :target_id, :uuid, allow_nil?: false
      argument :access_method_id, :uuid, allow_nil?: false
      argument :access_method_revision, :integer, allow_nil?: false

      filter expr(
               case_id == ^arg(:case_id) and
                 resolution_run_id == ^arg(:resolution_run_id) and
                 target_id == ^arg(:target_id) and
                 access_method_id == ^arg(:access_method_id) and
                 access_method_revision == ^arg(:access_method_revision) and
                 purpose == :investigation and
                 status in [:applied, :failed]
             )

      prepare build(sort: [completed_at: :desc, id: :desc], limit: 4)
    end

    read :by_proposal do
      get? true
      argument :proposal_id, :uuid, allow_nil?: false
      filter expr(proposal_id == ^arg(:proposal_id))
    end

    create :create_record do
      accept [
        :id,
        :case_id,
        :resolution_run_id,
        :proposal_id,
        :approval_id,
        :actor_id,
        :target_id,
        :access_method_id,
        :provider_id,
        :case_generation,
        :authority_mode,
        :proposal_revision,
        :approval_proposal_revision,
        :actor_role_version,
        :target_revision,
        :access_method_revision,
        :provider_revision,
        :request_kind,
        :purpose,
        :capability,
        :operation,
        :selectors,
        :parameters,
        :idempotency_key,
        :authorization_digest,
        :accepted_at,
        :not_before
      ]

      validate {Skopos.Validations.BoundedMap, attribute: :selectors}
      validate {Skopos.Validations.BoundedMap, attribute: :parameters}
      change Skopos.Cases.Operation.Changes.SetResourceScope
      validate present(:purpose)
    end

    update :mark_dispatching do
      accept [:dispatch_started_at]
      require_atomic? false
      argument :expected_revision, :integer, allow_nil?: false, constraints: [min: 1]
      validate Skopos.Validations.CurrentRevision
      change transition_state(:dispatching)
      change optimistic_lock(:revision)
    end

    update :retry_unsent do
      accept []
      require_atomic? false
      argument :expected_revision, :integer, allow_nil?: false, constraints: [min: 1]

      argument :before_send_failure, :struct,
        allow_nil?: false,
        sensitive?: true,
        constraints: [instance_of: Skopos.Providers.Target.BeforeSendError]

      validate Skopos.Validations.CurrentRevision
      change transition_state(:queued)
      change set_attribute(:dispatch_started_at, nil)
      change optimistic_lock(:revision)
    end

    update :record_outcome do
      accept [
        :status,
        :outcome_category,
        :reference,
        :result_details,
        :completed_at,
        :protected_reference
      ]

      require_atomic? false
      argument :expected_revision, :integer, allow_nil?: false, constraints: [min: 1]
      validate Skopos.Validations.CurrentRevision
      validate present(:completed_at)
      validate present(:outcome_category)

      validate {Skopos.Validations.BoundedMap,
                attribute: :result_details, max_bytes: Skopos.Providers.Target.max_result_bytes()}

      validate {Skopos.Validations.BoundedMap, argument: :protected_reference} do
        where present(:protected_reference)
      end

      change Skopos.Cases.Operation.Changes.TransitionOutcome
      change optimistic_lock(:revision)
    end

    update :record_no_send do
      accept [:outcome_category, :result_details, :completed_at]
      require_atomic? false
      argument :expected_revision, :integer, allow_nil?: false, constraints: [min: 1]

      argument :before_send_failure, :struct,
        sensitive?: true,
        constraints: [instance_of: Skopos.Providers.Target.BeforeSendError]

      validate attribute_equals(:status, :queued) do
        where absent(:before_send_failure)
      end

      validate Skopos.Validations.CurrentRevision
      validate present(:completed_at)
      validate present(:outcome_category)

      validate {Skopos.Validations.BoundedMap,
                attribute: :result_details, max_bytes: Skopos.Providers.Target.max_result_bytes()}

      change transition_state(:failed)
      change set_attribute(:dispatch_started_at, nil)
      change optimistic_lock(:revision)
    end

    action :accept, :struct do
      constraints instance_of: __MODULE__
      transaction? false
      argument :proposal_id, :uuid, allow_nil?: false
      run Skopos.Cases.Operation.Actions.Accept
    end

    action :claim_dispatch, :struct do
      constraints instance_of: Skopos.Cases.Operation.Claim
      transaction? false
      argument :id, :uuid, allow_nil?: false
      run Skopos.Cases.Operation.Actions.ClaimDispatch
    end

    action :account_observation_progress, :struct do
      constraints instance_of: Skopos.Cases.ResolutionRun.BudgetResult
      transaction? false
      argument :id, :uuid, allow_nil?: false
      run Skopos.Cases.Operation.Actions.AccountObservationProgress
    end

    action :read_result_reference, :map do
      public? false
      transaction? false
      argument :reference_id, :uuid, allow_nil?: false
      argument :case_id, :uuid, allow_nil?: false

      argument :clearance, :struct,
        allow_nil?: false,
        sensitive?: true,
        constraints: [instance_of: Skopos.Targets.TargetRequest.Clearance]

      run Skopos.Cases.Operation.Actions.ResultReference
    end
  end

  policies do
    policy action([
             :by_proposal,
             :create_record,
             :mark_dispatching,
             :retry_unsent,
             :record_outcome,
             :record_no_send,
             :accept,
             :claim_dispatch,
             :account_observation_progress
           ]) do
      forbid_if always()
    end

    policy action([
             :read,
             :for_case,
             :summaries_for_case,
             :page_for_case,
             :latest_recovery_effect,
             :latest_applied_recovery_effect
           ]) do
      authorize_if actor_attribute_equals(:role, :admin)
      authorize_if actor_attribute_equals(:role, :operator)
      authorize_if actor_attribute_equals(:role, :viewer)
    end

    policy action(:read_result_reference) do
      authorize_if actor_attribute_equals(:role, :admin)
      authorize_if actor_attribute_equals(:role, :operator)
    end
  end

  attributes do
    uuid_primary_key :id, writable?: true

    attribute :case_generation, :integer, allow_nil?: false, public?: true, constraints: [min: 1]

    attribute :authority_mode, :atom,
      allow_nil?: false,
      public?: true,
      constraints: [one_of: [:readonly, :ask, :auto, :full_access]]

    attribute :proposal_revision, :integer,
      allow_nil?: false,
      public?: true,
      constraints: [min: 1]

    attribute :approval_proposal_revision, :integer,
      allow_nil?: false,
      public?: true,
      constraints: [min: 1]

    attribute :actor_role_version, :integer,
      allow_nil?: false,
      public?: true,
      constraints: [min: 1]

    attribute :target_revision, :integer, allow_nil?: false, public?: true, constraints: [min: 1]

    attribute :access_method_revision, :integer,
      allow_nil?: false,
      public?: true,
      constraints: [min: 1]

    attribute :provider_revision, :integer,
      allow_nil?: false,
      public?: true,
      constraints: [min: 1]

    attribute :purpose, :atom do
      public? true
      constraints one_of: [:investigation, :remediation]
    end

    attribute :request_kind, :atom,
      allow_nil?: false,
      public?: true,
      constraints: [one_of: [:observation, :effect]]

    attribute :capability, :string,
      allow_nil?: false,
      public?: true,
      constraints: [min_length: 1, max_length: 120]

    attribute :operation, :string,
      allow_nil?: false,
      public?: true,
      constraints: [min_length: 1, max_length: 120]

    attribute :selectors, :map, allow_nil?: false, public?: true

    attribute :resource_scope, :string,
      allow_nil?: false,
      constraints: [min_length: 1, max_length: 500]

    attribute :parameters, :map, allow_nil?: false, public?: true

    attribute :idempotency_key, :string,
      allow_nil?: false,
      public?: true,
      constraints: [min_length: 1, max_length: 500]

    attribute :authorization_digest, :string,
      allow_nil?: false,
      public?: true,
      constraints: [min_length: 64, max_length: 64]

    attribute :accepted_at, :utc_datetime_usec, allow_nil?: false, public?: true

    attribute :not_before, :utc_datetime_usec,
      allow_nil?: false,
      public?: true,
      default: &DateTime.utc_now/0

    attribute :dispatch_started_at, :utc_datetime_usec, public?: true

    attribute :outcome_category, :string,
      public?: true,
      constraints: [min_length: 1, max_length: 120]

    attribute :reference, :string,
      public?: true,
      constraints: [
        min_length: 1,
        max_length: Skopos.Providers.Target.max_result_bytes(),
        length_count: :bytes,
        match: ~r/\A[^\x00]*\z/u,
        trim?: false
      ]

    attribute :protected_reference, :map, sensitive?: true

    attribute :result_details, :map, allow_nil?: false, public?: true, default: %{}
    attribute :completed_at, :utc_datetime_usec, public?: true
    attribute :revision, :integer, allow_nil?: false, default: 1, constraints: [min: 1]
    timestamps()
  end

  relationships do
    belongs_to :case, Skopos.Cases.Case, allow_nil?: false, public?: true
    belongs_to :resolution_run, Skopos.Cases.ResolutionRun, allow_nil?: false, public?: true
    belongs_to :proposal, Skopos.Cases.Proposal, allow_nil?: false, public?: true
    belongs_to :approval, Skopos.Cases.Approval, allow_nil?: false, public?: true
    belongs_to :actor, Skopos.Accounts.User, allow_nil?: false, public?: true
    belongs_to :target, Skopos.Targets.Target, allow_nil?: false, public?: true
    belongs_to :access_method, Skopos.Targets.AccessMethod, allow_nil?: false, public?: true
    belongs_to :provider, Skopos.Providers.Provider, allow_nil?: false, public?: true
  end

  identities do
    identity :unique_proposal, [:proposal_id]
    identity :unique_idempotency, [:idempotency_key]
  end
end
