defmodule Skopos.Targets.ExternalIdentity do
  use Ash.Resource,
    otp_app: :skopos,
    domain: Skopos.Targets,
    authorizers: [Ash.Policy.Authorizer],
    data_layer: AshPostgres.DataLayer

  postgres do
    table "external_identities"
    repo Skopos.Repo

    custom_indexes do
      index [:target_id]
    end
  end

  actions do
    defaults [:read]

    read :page do
      argument :target_id, :uuid
      argument :active, :boolean

      filter expr(
               (is_nil(^arg(:target_id)) or target_id == ^arg(:target_id)) and
                 (is_nil(^arg(:active)) or active == ^arg(:active))
             )

      pagination keyset?: true, required?: true, default_limit: 50, max_page_size: 100
      prepare build(sort: [inserted_at: :asc, id: :asc])
    end

    read :search_index do
      argument :query, :string,
        allow_nil?: false,
        constraints: [min_length: 1, max_length: 200]

      filter expr(
               active == true and target.active == true and contains(search_text, ^arg(:query))
             )

      prepare build(sort: [inserted_at: :asc, id: :asc])
    end

    read :for_source do
      argument :source, :string,
        allow_nil?: false,
        constraints: [min_length: 1, max_length: 120]

      filter expr(source == ^arg(:source) and active == true and target.active == true)
      prepare build(load: [:target], sort: [kind: :asc, value: :asc])
    end

    read :resolve do
      get? true

      argument :source, :string,
        allow_nil?: false,
        constraints: [min_length: 1, max_length: 120]

      argument :kind, :string,
        allow_nil?: false,
        constraints: [min_length: 1, max_length: 80]

      argument :value, :string,
        allow_nil?: false,
        constraints: [min_length: 1, max_length: 500]

      filter expr(
               source == ^arg(:source) and kind == ^arg(:kind) and value == ^arg(:value) and
                 active == true and target.active == true
             )

      prepare build(load: [:target])
    end

    create :create do
      primary? true
      accept [:target_id, :source, :kind, :value]
      change {Skopos.Targets.Changes.BuildSearchText, fields: [:source, :kind, :value]}
      change Skopos.Targets.Changes.EnqueueCaseReconciliation
    end

    update :update do
      primary? true
      accept [:target_id, :source, :kind, :value]
      require_atomic? false

      argument :expected_revision, :integer, allow_nil?: false, constraints: [min: 1]

      validate Skopos.Validations.CurrentRevision
      change {Skopos.Targets.Changes.BuildSearchText, fields: [:source, :kind, :value]}
      change Skopos.Targets.Changes.EnqueueCaseReconciliation
      change optimistic_lock(:revision)
    end

    update :deactivate do
      accept []
      argument :expected_revision, :integer, allow_nil?: false, constraints: [min: 1]
      validate Skopos.Validations.CurrentRevision
      change set_attribute(:active, false)
      change optimistic_lock(:revision)
    end
  end

  policies do
    policy action([:create, :update, :deactivate]) do
      authorize_if actor_attribute_equals(:role, :admin)
    end

    policy action([:search_index, :for_source, :resolve]) do
      forbid_if always()
    end

    policy action([:read, :page]) do
      authorize_if actor_attribute_equals(:role, :admin)
      authorize_if actor_attribute_equals(:role, :operator)
      authorize_if actor_attribute_equals(:role, :viewer)
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :source, :string do
      allow_nil? false
      public? true
      constraints min_length: 1, max_length: 120
    end

    attribute :kind, :string do
      allow_nil? false
      public? true
      constraints min_length: 1, max_length: 80
    end

    attribute :value, :string do
      allow_nil? false
      public? true
      constraints min_length: 1, max_length: 500
    end

    attribute :search_text, :string do
      allow_nil? false
      public? false
      constraints max_length: 1_024
    end

    attribute :active, :boolean do
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
    belongs_to :target, Skopos.Targets.Target do
      allow_nil? false
      public? true
    end
  end

  identities do
    identity :unique_source_identity, [:source, :kind, :value]
  end
end
