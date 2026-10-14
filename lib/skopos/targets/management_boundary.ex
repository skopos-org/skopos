defmodule Skopos.Targets.ManagementBoundary do
  use Ash.Resource,
    otp_app: :skopos,
    domain: Skopos.Targets,
    authorizers: [Ash.Policy.Authorizer],
    data_layer: AshPostgres.DataLayer

  @summary_fields ~w(id name kind active revision inserted_at updated_at)a
  def summary_fields, do: @summary_fields

  postgres do
    table "management_boundaries"
    repo Skopos.Repo
  end

  actions do
    defaults [:read]

    read :page do
      argument :ids, {:array, :uuid}, constraints: [min_length: 1, max_length: 100]
      argument :active, :boolean

      filter expr(
               (is_nil(^arg(:ids)) or id in ^arg(:ids)) and
                 (is_nil(^arg(:active)) or active == ^arg(:active))
             )

      pagination keyset?: true, required?: true, default_limit: 50, max_page_size: 100
      prepare build(select: @summary_fields, sort: [inserted_at: :asc, id: :asc])
    end

    create :create do
      primary? true
      accept [:name, :kind, :facts]
      validate {Skopos.Validations.BoundedMap, attribute: :facts}
    end

    update :update do
      primary? true
      accept [:name, :kind, :facts]
      require_atomic? false

      argument :expected_revision, :integer, allow_nil?: false, constraints: [min: 1]

      validate Skopos.Validations.CurrentRevision
      validate {Skopos.Validations.BoundedMap, attribute: :facts}
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

    policy action([:read, :page]) do
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

    attribute :kind, :string do
      allow_nil? false
      public? true
      constraints min_length: 1, max_length: 80
    end

    attribute :facts, :map do
      allow_nil? false
      public? true
      default %{}
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

  identities do
    identity :unique_name, [:name]
  end
end
