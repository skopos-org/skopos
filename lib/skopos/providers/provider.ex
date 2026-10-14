defmodule Skopos.Providers.Provider do
  use Ash.Resource,
    otp_app: :skopos,
    domain: Skopos.Providers,
    extensions: [AshCloak],
    authorizers: [Ash.Policy.Authorizer],
    data_layer: AshPostgres.DataLayer

  @reference_fields ~w(id name kind adapter_type enabled revision)a
  @management_fields @reference_fields ++
                       ~w(check_status check_category check_message checked_revision checked_at)a
  def reference_fields, do: @reference_fields

  cloak do
    vault(Skopos.Vault)
    attributes([:credentials])
  end

  postgres do
    table "providers"
    repo Skopos.Repo
    identity_wheres_to_sql unique_name: "retired_at IS NULL"
  end

  field_policies do
    private_fields :include

    field_policy :credentials do
      forbid_if always()
    end

    field_policy :* do
      authorize_if always()
    end
  end

  actions do
    defaults [:read]

    read :page do
      pagination keyset?: true, required?: true, default_limit: 50, max_page_size: 100
      filter expr(is_nil(retired_at))
      prepare build(sort: [inserted_at: :asc, id: :asc])
    end

    read :reference_page do
      argument :ids, {:array, :uuid}, constraints: [min_length: 1, max_length: 100]

      argument :kind, :atom,
        constraints: [one_of: [:ai, :signal, :target, :inventory, :notification]]

      argument :enabled, :boolean

      argument :adapter_types, {:array, :string},
        constraints: [min_length: 1, max_length: 100, items: [min_length: 1, max_length: 120]]

      filter expr(
               is_nil(retired_at) and
                 (is_nil(^arg(:ids)) or id in ^arg(:ids)) and
                 (is_nil(^arg(:kind)) or kind == ^arg(:kind)) and
                 (is_nil(^arg(:enabled)) or enabled == ^arg(:enabled)) and
                 (is_nil(^arg(:adapter_types)) or adapter_type in ^arg(:adapter_types))
             )

      pagination keyset?: true, required?: true, default_limit: 50, max_page_size: 100
      prepare build(select: @reference_fields, sort: [inserted_at: :asc, id: :asc])
    end

    read :management_page do
      argument :ids, {:array, :uuid}, constraints: [min_length: 1, max_length: 100]

      argument :kinds, {:array, :atom},
        constraints: [
          min_length: 1,
          max_length: 5,
          items: [one_of: [:ai, :signal, :target, :inventory, :notification]]
        ]

      argument :eligible, :boolean

      filter expr(
               is_nil(retired_at) and
                 (is_nil(^arg(:ids)) or id in ^arg(:ids)) and
                 (is_nil(^arg(:kinds)) or kind in ^arg(:kinds)) and
                 (is_nil(^arg(:eligible)) or available_for_invocation == ^arg(:eligible))
             )

      pagination keyset?: true, required?: true, default_limit: 50, max_page_size: 100

      prepare build(
                select: @management_fields,
                sort: [inserted_at: :asc, id: :asc]
              )

      prepare fn query, context ->
        Ash.Query.after_action(query, fn _query, providers ->
          ai = Enum.filter(providers, &(&1.kind == :ai))

          metadata =
            __MODULE__
            |> Ash.Query.select(@management_fields)
            |> Ash.Query.load([:ai_service, :ai_model])

          with {:ok, loaded} <- Ash.load(ai, metadata, actor: context.actor) do
            by_id = Map.new(loaded, &{&1.id, &1})

            {:ok,
             Enum.map(providers, fn
               %{kind: :ai, id: id} -> Map.fetch!(by_id, id)
               provider -> provider
             end)}
          end
        end)
      end
    end

    read :active do
      get? true
      argument :id, :uuid, allow_nil?: false
      filter expr(id == ^arg(:id) and is_nil(retired_at))
    end

    read :for_invocation do
      get? true

      argument :id, :uuid, allow_nil?: false

      argument :expected_revision, :integer,
        allow_nil?: false,
        constraints: [min: 1]

      argument :expected_kind, :atom,
        allow_nil?: false,
        constraints: [one_of: [:ai, :signal, :target, :inventory, :notification]]

      filter expr(
               id == ^arg(:id) and
                 revision == ^arg(:expected_revision) and
                 kind == ^arg(:expected_kind) and
                 available_for_invocation == true
             )

      prepare build(load: [:credentials])
    end

    create :create do
      primary? true
      accept [:name, :kind, :adapter_type, :configuration, :credentials]

      argument :registration_id, :uuid,
        allow_nil?: false,
        default: &Ash.UUID.generate/0

      argument :usage_scope, :atom,
        allow_nil?: false,
        default: :all,
        constraints: [one_of: [:all, :resolver, :reviewer]]

      argument :usage_priority, :integer,
        allow_nil?: false,
        default: 100,
        constraints: [min: 0, max: 10_000]

      change set_attribute(:id, arg(:registration_id))
      change Skopos.Providers.Provider.Changes.ValidateAdapter
      change Skopos.Providers.Provider.Changes.InitializeAIUsage
    end

    update :update do
      primary? true
      accept [:name, :configuration, :credentials]

      argument :expected_revision, :integer,
        allow_nil?: false,
        constraints: [min: 1]

      validate Skopos.Validations.CurrentRevision
      validate compare(:retired_at, is_nil: true)
      change set_attribute(:enabled, false)
      change set_attribute(:checked_revision, nil)
      change set_attribute(:check_status, nil)
      change set_attribute(:check_category, nil)
      change set_attribute(:check_message, nil)
      change set_attribute(:checked_at, nil)
      change optimistic_lock(:revision)
    end

    action :check, :struct do
      constraints instance_of: __MODULE__
      transaction? false

      argument :id, :uuid, allow_nil?: false

      argument :expected_revision, :integer,
        allow_nil?: false,
        constraints: [min: 1]

      argument :input, :map, allow_nil?: false, default: %{}
      run Skopos.Providers.Provider.Actions.Check
    end

    action :retire_ai, :struct do
      constraints instance_of: __MODULE__
      transaction? false

      argument :id, :uuid, allow_nil?: false
      argument :expected_revision, :integer, allow_nil?: false, constraints: [min: 1]

      run Skopos.Providers.Provider.Actions.RetireAI
    end

    action :target_capabilities, :struct do
      constraints instance_of: Skopos.Providers.Target.Capabilities
      transaction? false

      argument :provider_id, :uuid, allow_nil?: false

      argument :request, :struct,
        allow_nil?: false,
        constraints: [instance_of: Skopos.Providers.Target.CapabilitiesRequest]

      argument :invocation, :map, allow_nil?: false, default: %{}
      run {Skopos.Providers.Provider.Actions.Target, operation: :capabilities}
    end

    action :target_check, :struct do
      public? false
      constraints instance_of: Skopos.Providers.Target.Capabilities
      transaction? false
      argument :provider_id, :uuid, allow_nil?: false

      argument :request, :struct,
        allow_nil?: false,
        constraints: [instance_of: Skopos.Providers.Target.CapabilitiesRequest]

      argument :invocation, :map, allow_nil?: false, default: %{}
      run {Skopos.Providers.Provider.Actions.Target, operation: :check}
    end

    action :signal_ingest, :struct do
      constraints instance_of: Skopos.Providers.Signal.IngestResult
      transaction? false

      argument :provider_id, :uuid, allow_nil?: false

      argument :expected_revision, :integer,
        allow_nil?: false,
        constraints: [min: 1]

      argument :envelope, :struct,
        allow_nil?: false,
        constraints: [instance_of: Skopos.Providers.Signal.Envelope]

      argument :invocation, :map, allow_nil?: false, default: %{}
      run Skopos.Providers.Provider.Actions.Signal
    end

    action :inventory_snapshot, :struct do
      constraints instance_of: Skopos.Providers.Inventory.Snapshot
      transaction? false

      argument :provider_id, :uuid, allow_nil?: false

      argument :request, :struct,
        allow_nil?: false,
        constraints: [instance_of: Skopos.Providers.Inventory.Request]

      argument :invocation, :map, allow_nil?: false, default: %{}
      run Skopos.Providers.Provider.Actions.Inventory
    end

    action :notification_deliver, :struct do
      constraints instance_of: Skopos.Providers.Notification.Result
      transaction? false

      argument :provider_id, :uuid, allow_nil?: false

      argument :request, :struct,
        allow_nil?: false,
        constraints: [instance_of: Skopos.Providers.Notification.Request]

      argument :invocation, :map, allow_nil?: false, default: %{}
      run Skopos.Providers.Provider.Actions.Notification
    end

    action :ai_resolve, :struct do
      constraints instance_of: Skopos.Providers.AI.ResolverDecision
      transaction? false

      argument :provider_id, :uuid, allow_nil?: false

      argument :request, :struct,
        allow_nil?: false,
        constraints: [instance_of: Skopos.Providers.AI.ResolverRequest]

      argument :invocation, :map, allow_nil?: false, default: %{}
      run {Skopos.Providers.Provider.Actions.AI, operation: :resolve}
    end

    action :ai_review, :struct do
      constraints instance_of: Skopos.Providers.AI.ReviewDecision
      transaction? false

      argument :provider_id, :uuid, allow_nil?: false

      argument :request, :struct,
        allow_nil?: false,
        constraints: [instance_of: Skopos.Providers.AI.ReviewRequest]

      argument :invocation, :map, allow_nil?: false, default: %{}
      run {Skopos.Providers.Provider.Actions.AI, operation: :review}
    end

    action :ai_review_recovery, :struct do
      constraints instance_of: Skopos.Providers.AI.ReviewDecision
      transaction? false

      argument :provider_id, :uuid, allow_nil?: false

      argument :request, :struct,
        allow_nil?: false,
        constraints: [instance_of: Skopos.Providers.AI.RecoveryReviewRequest]

      argument :invocation, :map, allow_nil?: false, default: %{}
      run {Skopos.Providers.Provider.Actions.AI, operation: :review_recovery}
    end

    action :target_classify, :struct do
      public? false
      constraints instance_of: Skopos.Providers.Target.RequestClassification
      transaction? false

      argument :provider_id, :uuid, allow_nil?: false

      argument :request, :struct,
        allow_nil?: false,
        sensitive?: true,
        constraints: [instance_of: Skopos.Providers.Target.MethodRequest]

      argument :invocation, :map, allow_nil?: false, default: %{}
      run {Skopos.Providers.Provider.Actions.Target, operation: :classify}
    end

    action :target_observe, :struct do
      public? false
      constraints instance_of: Skopos.Providers.Target.Observation
      transaction? false

      argument :provider_id, :uuid, allow_nil?: false

      argument :request, :struct,
        allow_nil?: false,
        sensitive?: true,
        constraints: [instance_of: Skopos.Providers.Target.ObservationRequest]

      argument :invocation, :map, allow_nil?: false, default: %{}
      run {Skopos.Providers.Provider.Actions.Target, operation: :observe}
    end

    action :target_effect, :struct do
      public? false
      constraints instance_of: Skopos.Providers.Target.EffectResult
      transaction? false

      argument :provider_id, :uuid, allow_nil?: false

      argument :request, :struct,
        allow_nil?: false,
        sensitive?: true,
        constraints: [instance_of: Skopos.Providers.Target.EffectRequest]

      argument :invocation, :map, allow_nil?: false, default: %{}
      run {Skopos.Providers.Provider.Actions.Target, operation: :effect}
    end

    action :target_verify, :struct do
      public? false
      constraints instance_of: Skopos.Providers.Target.Verification
      transaction? false

      argument :provider_id, :uuid, allow_nil?: false

      argument :request, :struct,
        allow_nil?: false,
        sensitive?: true,
        constraints: [instance_of: Skopos.Providers.Target.VerificationRequest]

      argument :invocation, :map, allow_nil?: false, default: %{}
      run {Skopos.Providers.Provider.Actions.Target, operation: :verify}
    end

    update :record_check do
      accept []

      argument :expected_revision, :integer,
        allow_nil?: false,
        constraints: [min: 1]

      argument :check_status, :atom,
        allow_nil?: false,
        constraints: [one_of: [:passed, :failed]]

      argument :check_category, :atom,
        constraints: [
          one_of: [
            :invalid_configuration,
            :authentication,
            :unreachable,
            :capability,
            :provider_failure
          ]
        ]

      argument :check_message, :string

      validate Skopos.Validations.CurrentRevision
      validate attribute_does_not_equal(:kind, :target)
      validate compare(:retired_at, is_nil: true)
      change set_attribute(:checked_revision, arg(:expected_revision))
      change set_attribute(:check_status, arg(:check_status))
      change set_attribute(:check_category, arg(:check_category))
      change set_attribute(:check_message, arg(:check_message))
      change atomic_update(:checked_at, expr(now()))

      change atomic_update(
               :enabled,
               expr(if ^arg(:check_status) == :failed, do: false, else: enabled)
             )
    end

    update :enable do
      accept []

      argument :expected_revision, :integer,
        allow_nil?: false,
        constraints: [min: 1]

      validate attribute_equals(:check_status, :passed) do
        message "has not passed its current check"
        where attribute_does_not_equal(:kind, :target)
      end

      validate compare(:checked_revision, is_equal: {:ref, :revision}) do
        message "does not have a current check"
        where attribute_does_not_equal(:kind, :target)
      end

      validate Skopos.Providers.Provider.Validations.TargetConfiguration

      validate Skopos.Validations.CurrentRevision
      validate compare(:retired_at, is_nil: true)
      change set_attribute(:enabled, true)
    end

    update :disable do
      accept []

      argument :expected_revision, :integer,
        allow_nil?: false,
        constraints: [min: 1]

      validate Skopos.Validations.CurrentRevision
      validate compare(:retired_at, is_nil: true)
      change set_attribute(:enabled, false)
    end

    update :retire_record do
      public? false
      accept [:credentials]
      require_atomic? false

      argument :expected_revision, :integer, allow_nil?: false, constraints: [min: 1]

      validate Skopos.Validations.CurrentRevision
      validate attribute_equals(:kind, :ai)
      validate compare(:retired_at, is_nil: true)
      change set_attribute(:enabled, false)
      change set_attribute(:configuration, %{})
      change set_attribute(:check_status, nil)
      change set_attribute(:check_category, nil)
      change set_attribute(:check_message, nil)
      change set_attribute(:checked_revision, nil)
      change set_attribute(:checked_at, nil)
      change atomic_update(:retired_at, expr(now()))
      change optimistic_lock(:revision)
    end
  end

  policies do
    policy action([:create, :update, :check, :enable, :disable, :retire_ai]) do
      authorize_if actor_attribute_equals(:role, :admin)
    end

    policy action([:record_check, :retire_record]) do
      forbid_if always()
    end

    policy action(:for_invocation) do
      forbid_if always()
    end

    policy action(:target_capabilities) do
      authorize_if actor_attribute_equals(:role, :admin)
    end

    policy action([
             :target_check,
             :target_classify,
             :target_observe,
             :target_effect,
             :target_verify
           ]) do
      forbid_if always()
    end

    policy action(:signal_ingest) do
      authorize_if always()
    end

    policy action(:inventory_snapshot) do
      authorize_if actor_attribute_equals(:role, :admin)
      authorize_if actor_attribute_equals(:role, :operator)
    end

    policy action(:notification_deliver) do
      authorize_if actor_attribute_equals(:role, :admin)
      authorize_if actor_attribute_equals(:role, :operator)
    end

    policy action([:ai_resolve, :ai_review, :ai_review_recovery]) do
      authorize_if actor_attribute_equals(:role, :admin)
      authorize_if actor_attribute_equals(:role, :operator)
    end

    policy action([:read, :page, :active, :reference_page, :management_page]) do
      authorize_if actor_attribute_equals(:role, :admin)
      authorize_if actor_attribute_equals(:role, :operator)
      authorize_if actor_attribute_equals(:role, :viewer)
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :name, :string do
      allow_nil? false
      public? true
      constraints min_length: 1, max_length: 120
    end

    attribute :kind, :atom do
      allow_nil? false
      public? true
      constraints one_of: [:ai, :signal, :target, :inventory, :notification]
    end

    attribute :adapter_type, :string do
      allow_nil? false
      public? true
      constraints min_length: 1, max_length: 120
    end

    attribute :configuration, :map do
      allow_nil? false
      public? true
      default %{}
    end

    attribute :credentials, :map do
      allow_nil? false
      sensitive? true
    end

    attribute :revision, :integer do
      allow_nil? false
      public? true
      default 1
      constraints min: 1
    end

    attribute :enabled, :boolean do
      allow_nil? false
      public? true
      default false
    end

    attribute :checked_revision, :integer do
      public? true
      constraints min: 1
    end

    attribute :check_status, :atom do
      public? true
      constraints one_of: [:passed, :failed]
    end

    attribute :check_category, :atom do
      public? true

      constraints one_of: [
                    :invalid_configuration,
                    :authentication,
                    :unreachable,
                    :capability,
                    :provider_failure
                  ]
    end

    attribute :check_message, :string do
      public? true
    end

    attribute :checked_at, :utc_datetime_usec do
      public? true
    end

    attribute :retired_at, :utc_datetime_usec

    timestamps()
  end

  calculations do
    calculate :ai_service, :string, expr(if kind == :ai, do: get_path(configuration, [:provider]))
    calculate :ai_model, :string, expr(if kind == :ai, do: get_path(configuration, [:model]))

    calculate :available_for_invocation,
              :boolean,
              expr(
                if enabled == true and is_nil(retired_at) and
                     (kind == :target or
                        (check_status == :passed and checked_revision == revision)),
                   do: true,
                   else: false
              )
  end

  identities do
    identity :unique_name, [:name], where: expr(is_nil(retired_at))
  end
end
