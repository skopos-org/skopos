defmodule Skopos.Cases.Proposal do
  alias Skopos.Targets.TargetRequest.Request

  @summary_fields ~w(id case_id resolution_run_id source_turn_id proposed_for_id target_id access_method_id provider_id status authority_mode request_kind purpose tool_id capability operation reason delay_seconds preflight_status proposal_digest expires_at revision inserted_at updated_at)a

  def summary_fields, do: @summary_fields

  use Ash.Resource,
    otp_app: :skopos,
    domain: Skopos.Cases,
    authorizers: [Ash.Policy.Authorizer],
    simple_notifiers: [Skopos.Cases.Case.RealtimeNotifier],
    data_layer: AshPostgres.DataLayer

  postgres do
    table "proposals"
    repo Skopos.Repo

    custom_indexes do
      index [:case_id]
      index [:resolution_run_id]
      index [:target_id]
      index [:proposed_for_id]
    end
  end

  actions do
    defaults [:read]

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

    read :by_source_turn do
      get? true
      argument :source_turn_id, :uuid, allow_nil?: false
      filter expr(source_turn_id == ^arg(:source_turn_id))
    end

    create :create_record do
      accept [
        :case_id,
        :resolution_run_id,
        :source_turn_id,
        :proposed_for_id,
        :target_id,
        :access_method_id,
        :provider_id,
        :status,
        :authority_mode,
        :case_generation,
        :target_revision,
        :access_method_revision,
        :provider_revision,
        :request_kind,
        :purpose,
        :tool_id,
        :capability,
        :operation,
        :selectors,
        :parameters,
        :delay_seconds,
        :reason,
        :evidence_ids,
        :affected_conditions,
        :expected_result,
        :verification_intent,
        :verification_tool,
        :resolver_identity,
        :reserved_operation_id,
        :operation_idempotency_key,
        :preflight_status,
        :preflight_context,
        :preflight_reason,
        :proposal_digest,
        :expires_at,
        :revision
      ]

      validate {Skopos.Validations.BoundedMap, attribute: :selectors}
      validate {Skopos.Validations.BoundedMap, attribute: :parameters}
      validate {Skopos.Validations.BoundedMap, attribute: :expected_result}
      validate {Skopos.Validations.BoundedMap, attribute: :verification_intent}
      validate {Skopos.Validations.BoundedMap, attribute: :verification_tool}
      validate {Skopos.Validations.BoundedMap, attribute: :resolver_identity}
      validate {Skopos.Validations.BoundedMap, attribute: :preflight_context}
      validate present(:purpose)
    end

    update :transition do
      accept [:status]
      require_atomic? false
      argument :expected_revision, :integer, allow_nil?: false, constraints: [min: 1]
      validate Skopos.Validations.CurrentRevision
      change optimistic_lock(:revision)
    end

    action :materialize, :struct do
      constraints instance_of: __MODULE__
      transaction? false
      argument :turn_id, :uuid, allow_nil?: false
      run Skopos.Cases.Proposal.Actions.Materialize
    end

    action :route_authority, :struct do
      constraints instance_of: __MODULE__
      transaction? false
      argument :proposal_id, :uuid, allow_nil?: false
      run {Skopos.Cases.Proposal.Actions.Authority, operation: :route}
    end

    action :decide, :struct do
      constraints instance_of: __MODULE__
      transaction? false
      argument :proposal_id, :uuid, allow_nil?: false
      argument :expected_revision, :integer, allow_nil?: false, constraints: [min: 1]

      argument :proposal_digest, :string,
        allow_nil?: false,
        constraints: [min_length: 64, max_length: 64]

      argument :decision, :atom,
        allow_nil?: false,
        constraints: [one_of: [:approved, :rejected]]

      argument :reason, :string,
        allow_nil?: false,
        constraints: [min_length: 1, max_length: 1_000]

      run {Skopos.Cases.Proposal.Actions.Authority, operation: :decide}
    end

    action :expire, :struct do
      constraints instance_of: __MODULE__
      transaction? false
      argument :proposal_id, :uuid, allow_nil?: false
      run {Skopos.Cases.Proposal.Actions.Authority, operation: :expire}
    end

    action :apply_review, :struct do
      constraints instance_of: __MODULE__
      transaction? false
      argument :proposal_id, :uuid, allow_nil?: false
      argument :review_decision_id, :uuid, allow_nil?: false
      run {Skopos.Cases.Proposal.Actions.Authority, operation: :review}
    end

    action :supersede_context, :struct do
      constraints instance_of: __MODULE__
      transaction? false
      argument :proposal_id, :uuid, allow_nil?: false
      run {Skopos.Cases.Proposal.Actions.Authority, operation: :supersede_context}
    end

    action :fail_review_delivery, :struct do
      constraints instance_of: __MODULE__
      transaction? false
      argument :proposal_id, :uuid, allow_nil?: false
      argument :category, :string, allow_nil?: false, constraints: [min_length: 1, max_length: 80]

      argument :reason, :string,
        allow_nil?: false,
        constraints: [min_length: 1, max_length: 1_000]

      run {Skopos.Cases.Proposal.Actions.Authority, operation: :review_delivery_failure}
    end
  end

  policies do
    policy action([
             :by_source_turn,
             :create_record,
             :transition,
             :materialize,
             :route_authority,
             :expire,
             :apply_review,
             :supersede_context,
             :fail_review_delivery
           ]) do
      forbid_if always()
    end

    policy action(:decide) do
      authorize_if actor_attribute_equals(:role, :admin)
      authorize_if actor_attribute_equals(:role, :operator)
    end

    policy action([:read, :summaries_for_case, :page_for_case]) do
      authorize_if actor_attribute_equals(:role, :admin)
      authorize_if actor_attribute_equals(:role, :operator)
      authorize_if actor_attribute_equals(:role, :viewer)
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :status, :atom do
      allow_nil? false
      public? true

      constraints one_of: [
                    :proposed,
                    :blocked,
                    :recommended,
                    :awaiting_human,
                    :reviewing,
                    :authorized,
                    :rejected,
                    :invalidated
                  ]
    end

    attribute :authority_mode, :atom do
      allow_nil? false
      public? true
      constraints one_of: [:readonly, :ask, :auto, :full_access]
    end

    attribute :case_generation, :integer do
      allow_nil? false
      public? true
      constraints min: 1
    end

    attribute :target_revision, :integer do
      allow_nil? false
      public? true
      constraints min: 1
    end

    attribute :access_method_revision, :integer do
      allow_nil? false
      public? true
      constraints min: 1
    end

    attribute :provider_revision, :integer do
      allow_nil? false
      public? true
      constraints min: 1
    end

    attribute :purpose, :atom do
      public? true
      constraints one_of: [:investigation, :remediation]
    end

    attribute :request_kind, :atom do
      allow_nil? false
      public? true
      constraints one_of: [:observation, :effect]
    end

    attribute :tool_id, :string do
      allow_nil? false
      public? true
      constraints min_length: 1, max_length: 200
    end

    attribute :capability, :string do
      allow_nil? false
      public? true
      constraints min_length: 1, max_length: 120
    end

    attribute :operation, :string do
      allow_nil? false
      public? true
      constraints min_length: 1, max_length: 120
    end

    attribute :selectors, :map do
      allow_nil? false
      public? true
    end

    attribute :parameters, :map do
      allow_nil? false
      public? true
    end

    attribute :delay_seconds, :integer,
      allow_nil?: false,
      public?: true,
      default: 0,
      constraints: [min: 0, max: 86_400]

    attribute :reason, :string do
      allow_nil? false
      public? true
      constraints min_length: 1, max_length: 500
    end

    attribute :evidence_ids, {:array, :uuid} do
      allow_nil? false
      public? true
      constraints min_length: 0, max_length: 100
    end

    attribute :affected_conditions, {:array, :map} do
      allow_nil? false
      public? true
      default []
      constraints max_length: 100
    end

    attribute :expected_result, :map do
      allow_nil? false
      public? true
    end

    attribute :verification_intent, :map do
      allow_nil? false
      public? true
    end

    attribute :verification_tool, :map do
      allow_nil? false
      public? true
    end

    attribute :resolver_identity, :map do
      allow_nil? false
      public? true
    end

    attribute :reserved_operation_id, :uuid do
      allow_nil? false
      public? true
    end

    attribute :operation_idempotency_key, :string do
      allow_nil? false
      public? true
      constraints min_length: 1, max_length: 500
    end

    attribute :preflight_status, :atom do
      allow_nil? false
      public? true
      constraints one_of: [:cleared, :blocked]
    end

    attribute :preflight_context, :map do
      allow_nil? false
      public? true
    end

    attribute :preflight_reason, :string do
      public? true
      constraints max_length: 500
    end

    attribute :proposal_digest, :string do
      allow_nil? false
      public? true
      constraints min_length: 64, max_length: 64
    end

    attribute :expires_at, :utc_datetime_usec do
      allow_nil? false
      public? true
    end

    attribute :revision, :integer do
      allow_nil? false
      default 1
      constraints min: 1
    end

    timestamps()
  end

  relationships do
    belongs_to :case, Skopos.Cases.Case do
      allow_nil? false
      public? true
    end

    belongs_to :resolution_run, Skopos.Cases.ResolutionRun do
      allow_nil? false
      public? true
    end

    belongs_to :source_turn, Skopos.Cases.Turn do
      allow_nil? false
      public? true
    end

    belongs_to :proposed_for, Skopos.Accounts.User do
      allow_nil? false
      public? true
    end

    belongs_to :target, Skopos.Targets.Target do
      allow_nil? false
      public? true
    end

    belongs_to :access_method, Skopos.Targets.AccessMethod do
      allow_nil? false
      public? true
    end

    belongs_to :provider, Skopos.Providers.Provider do
      allow_nil? false
      public? true
    end
  end

  identities do
    identity :unique_source_turn, [:source_turn_id]
    identity :unique_reserved_operation, [:reserved_operation_id]
  end

  def target_request(%__MODULE__{} = proposal) do
    %Request{
      kind: proposal.request_kind,
      authority_mode: proposal.authority_mode,
      target_id: proposal.target_id,
      target_revision: proposal.target_revision,
      access_method_id: proposal.access_method_id,
      access_method_revision: proposal.access_method_revision,
      capability: proposal.capability,
      operation: proposal.operation,
      selectors: proposal.selectors,
      parameters: proposal.parameters,
      operation_id: proposal.reserved_operation_id,
      idempotency_key: proposal.operation_idempotency_key,
      max_attempts: 1
    }
  end
end
