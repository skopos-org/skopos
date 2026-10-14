defmodule Skopos.Targets.Relationship do
  use Ash.Resource,
    otp_app: :skopos,
    domain: Skopos.Targets,
    authorizers: [Ash.Policy.Authorizer],
    data_layer: AshPostgres.DataLayer

  postgres do
    table "relationships"
    repo Skopos.Repo

    custom_indexes do
      index [:source_target_id]
      index [:destination_target_id]
    end
  end

  actions do
    defaults [:read]

    read :page do
      argument :target_id, :uuid
      argument :active, :boolean

      filter expr(
               (is_nil(^arg(:target_id)) or source_target_id == ^arg(:target_id) or
                  destination_target_id == ^arg(:target_id)) and
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
               active == true and source_target.active == true and
                 destination_target.active == true and
                 (is_nil(valid_until) or valid_until > now()) and
                 contains(search_text, ^arg(:query))
             )

      prepare build(sort: [inserted_at: :asc, id: :asc])
    end

    read :for_traversal do
      get? true

      argument :id, :uuid, allow_nil?: false
      argument :expected_revision, :integer, allow_nil?: false, constraints: [min: 1]

      filter expr(
               id == ^arg(:id) and revision == ^arg(:expected_revision) and active == true and
                 source_target.active == true and destination_target.active == true and
                 (is_nil(valid_until) or valid_until > now())
             )
    end

    read :adjacent_for_traversal do
      argument :target_id, :uuid, allow_nil?: false

      filter expr(
               active == true and source_target.active == true and
                 destination_target.active == true and
                 (is_nil(valid_until) or valid_until > now()) and
                 (source_target_id == ^arg(:target_id) or
                    destination_target_id == ^arg(:target_id))
             )

      prepare build(sort: [inserted_at: :asc, id: :asc], limit: 100)
    end

    read :adjacent_for_case_admission do
      argument :target_id, :uuid, allow_nil?: false

      filter expr(
               active == true and source_target.active == true and
                 destination_target.active == true and
                 (is_nil(valid_until) or valid_until > now()) and
                 (source_target_id == ^arg(:target_id) or
                    destination_target_id == ^arg(:target_id))
             )

      # The 129th edge means the admission graph cannot be proven complete
      # within its 128-node budget. The caller then starts a separate Case.
      prepare build(sort: [inserted_at: :asc, id: :asc], limit: 129)
    end

    create :create do
      primary? true
      accept [:source_target_id, :destination_target_id, :kind, :facts, :valid_until]

      validate compare(:source_target_id, is_not_equal: {:ref, :destination_target_id}),
        message: "must differ from destination target"

      validate {Skopos.Validations.BoundedMap, attribute: :facts}
      change {Skopos.Targets.Changes.BuildSearchText, fields: [:kind, :facts]}
    end

    update :update do
      primary? true
      require_atomic? false
      accept [:source_target_id, :destination_target_id, :kind, :facts, :valid_until]

      argument :expected_revision, :integer, allow_nil?: false, constraints: [min: 1]

      validate Skopos.Validations.CurrentRevision

      validate compare(:source_target_id, is_not_equal: {:ref, :destination_target_id}),
        message: "must differ from destination target"

      validate {Skopos.Validations.BoundedMap, attribute: :facts}
      change {Skopos.Targets.Changes.BuildSearchText, fields: [:kind, :facts]}
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

    policy action([
             :search_index,
             :for_traversal,
             :adjacent_for_traversal,
             :adjacent_for_case_admission
           ]) do
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

    attribute :kind, :string do
      allow_nil? false
      public? true
      constraints min_length: 1, max_length: 120
    end

    attribute :facts, :map do
      allow_nil? false
      public? true
      default %{}
    end

    attribute :search_text, :string do
      allow_nil? false
      public? false
      constraints max_length: 65_536
    end

    attribute :active, :boolean do
      allow_nil? false
      public? true
      default true
    end

    attribute :valid_until, :utc_datetime_usec do
      public? true
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
    belongs_to :source_target, Skopos.Targets.Target do
      allow_nil? false
      public? true
      source_attribute :source_target_id
    end

    belongs_to :destination_target, Skopos.Targets.Target do
      allow_nil? false
      public? true
      source_attribute :destination_target_id
    end
  end

  identities do
    identity :unique_typed_edge, [:source_target_id, :destination_target_id, :kind]
  end
end
