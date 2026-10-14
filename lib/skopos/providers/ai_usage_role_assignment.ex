defmodule Skopos.Providers.AIUsageRoleAssignment do
  use Ash.Resource,
    otp_app: :skopos,
    domain: Skopos.Providers,
    authorizers: [Ash.Policy.Authorizer],
    data_layer: AshPostgres.DataLayer

  postgres do
    table "ai_usage_role_assignments"
    repo Skopos.Repo
  end

  actions do
    defaults [:read]

    read :page do
      argument :provider_ids, {:array, :uuid}, constraints: [min_length: 1, max_length: 50]
      pagination keyset?: true, required?: true, default_limit: 50, max_page_size: 100

      filter expr(
               is_nil(provider.retired_at) and
                 (is_nil(^arg(:provider_ids)) or provider_id in ^arg(:provider_ids))
             )

      prepare build(sort: [inserted_at: :asc, id: :asc])
    end

    read :eligible do
      argument :role, :atom,
        allow_nil?: false,
        constraints: [one_of: [:resolver, :reviewer]]

      filter expr(role == ^arg(:role) and eligible_for_selection == true)

      prepare build(sort: [priority: :asc, inserted_at: :asc, id: :asc], load: [:provider])
    end

    read :eligibility_summary do
      argument :role, :atom, allow_nil?: false, constraints: [one_of: [:resolver, :reviewer]]
      filter expr(role == ^arg(:role) and eligible_for_selection == true)

      prepare build(
                select: [:id, :provider_id],
                limit: 2,
                sort: [priority: :asc, inserted_at: :asc, id: :asc]
              )
    end

    read :current_assignment do
      get? true

      argument :id, :uuid, allow_nil?: false

      argument :role, :atom,
        allow_nil?: false,
        constraints: [one_of: [:resolver, :reviewer]]

      argument :expected_assignment_revision, :integer,
        allow_nil?: false,
        constraints: [min: 1]

      argument :expected_provider_revision, :integer,
        allow_nil?: false,
        constraints: [min: 1]

      filter expr(
               id == ^arg(:id) and revision == ^arg(:expected_assignment_revision) and
                 role == ^arg(:role) and eligible_for_selection == true and
                 provider.revision == ^arg(:expected_provider_revision)
             )

      prepare build(load: [:provider])
    end

    create :create do
      primary? true
      accept [:provider_id, :role, :priority]
      validate Skopos.Providers.AIUsageRoleAssignment.Validations.AIProvider
    end

    update :update do
      primary? true
      accept [:priority, :enabled]
      require_atomic? false

      argument :expected_revision, :integer,
        allow_nil?: false,
        constraints: [min: 1]

      validate Skopos.Validations.CurrentRevision
      validate Skopos.Providers.AIUsageRoleAssignment.Validations.AIProvider
      change optimistic_lock(:revision)
    end

    action :configure, :boolean do
      transaction? false

      argument :provider_id, :uuid, allow_nil?: false

      argument :scope, :atom,
        allow_nil?: false,
        constraints: [one_of: [:all, :resolver, :reviewer]]

      argument :priority, :integer,
        allow_nil?: false,
        constraints: [min: 0, max: 10_000]

      argument :expected_resolver_revision, :integer, constraints: [min: 1]
      argument :expected_reviewer_revision, :integer, constraints: [min: 1]

      run Skopos.Providers.AIUsageRoleAssignment.Actions.Configure
    end

    action :select_resolver, :struct do
      constraints instance_of: Skopos.Providers.AI.Selection
      run {Skopos.Providers.AIUsageRoleAssignment.Actions.Select, role: :resolver}
    end

    action :select_reviewer, :struct do
      constraints instance_of: Skopos.Providers.AI.Selection
      argument :excluded_provider_ids, {:array, :uuid}, allow_nil?: false

      run {Skopos.Providers.AIUsageRoleAssignment.Actions.Select, role: :reviewer}
    end
  end

  policies do
    policy action(:configure) do
      authorize_if actor_attribute_equals(:role, :admin)
    end

    policy action([:create, :update]) do
      forbid_if always()
    end

    policy action([:eligible, :current_assignment, :eligibility_summary]) do
      forbid_if always()
    end

    policy action([:select_resolver, :select_reviewer]) do
      authorize_if actor_attribute_equals(:role, :admin)
      authorize_if actor_attribute_equals(:role, :operator)
    end

    policy action([:read, :page]) do
      authorize_if actor_attribute_equals(:role, :admin)
      authorize_if actor_attribute_equals(:role, :operator)
      authorize_if actor_attribute_equals(:role, :viewer)
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :role, :atom do
      allow_nil? false
      public? true
      constraints one_of: [:resolver, :reviewer]
    end

    attribute :priority, :integer do
      allow_nil? false
      public? true
      default 100
      constraints min: 0, max: 10_000
    end

    attribute :enabled, :boolean do
      allow_nil? false
      public? true
      default true
    end

    attribute :revision, :integer do
      allow_nil? false
      public? true
      default 1
      constraints min: 1
    end

    timestamps()
  end

  relationships do
    belongs_to :provider, Skopos.Providers.Provider do
      allow_nil? false
      public? true
    end
  end

  calculations do
    calculate :eligible_for_selection,
              :boolean,
              expr(
                enabled == true and provider.kind == :ai and
                  provider.available_for_invocation == true
              )
  end

  identities do
    identity :unique_provider_role, [:provider_id, :role]
  end
end
