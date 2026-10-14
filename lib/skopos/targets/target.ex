defmodule Skopos.Targets.Target do
  use Ash.Resource,
    otp_app: :skopos,
    domain: Skopos.Targets,
    authorizers: [Ash.Policy.Authorizer],
    data_layer: AshPostgres.DataLayer

  @reference_fields ~w(id name kind type_id active revision management_boundary_id)a
  def reference_fields, do: @reference_fields
  @management_calculations [:method_count, :relationship_count, :has_operating_instructions]
  def management_fields, do: @reference_fields ++ @management_calculations

  postgres do
    table "targets"
    repo Skopos.Repo

    custom_indexes do
      index [:management_boundary_id]
    end
  end

  actions do
    defaults [:read]

    action :type_catalog, :map do
      run fn _input, _context -> {:ok, Skopos.Targets.TypeCatalog.snapshot()} end
    end

    read :page do
      pagination keyset?: true, required?: true, default_limit: 50, max_page_size: 100
      prepare build(sort: [inserted_at: :asc, id: :asc])
    end

    read :reference_page do
      argument :ids, {:array, :uuid}, constraints: [min_length: 1, max_length: 100]
      argument :active, :boolean
      argument :exclude_id, :uuid

      filter expr(
               (is_nil(^arg(:ids)) or id in ^arg(:ids)) and
                 (is_nil(^arg(:active)) or active == ^arg(:active)) and
                 (is_nil(^arg(:exclude_id)) or id != ^arg(:exclude_id))
             )

      pagination keyset?: true, required?: true, default_limit: 50, max_page_size: 100
      prepare build(select: @reference_fields, sort: [inserted_at: :asc, id: :asc])
    end

    read :management_page do
      argument :ids, {:array, :uuid}, constraints: [min_length: 1, max_length: 100]
      argument :active, :boolean

      argument :query, :string,
        constraints: [
          allow_empty?: true,
          max_length: Skopos.Targets.SearchQuery.max_codepoints()
        ]

      filter expr(
               (is_nil(^arg(:ids)) or id in ^arg(:ids)) and
                 (is_nil(^arg(:active)) or active == ^arg(:active)) and
                 (is_nil(^arg(:query)) or
                    contains(string_downcase(name), string_downcase(^arg(:query))) or
                    contains(string_downcase(kind), string_downcase(^arg(:query))) or
                    contains(string_downcase(type_id), string_downcase(^arg(:query))))
             )

      pagination keyset?: true, required?: true, default_limit: 50, max_page_size: 100

      prepare build(
                select: @reference_fields,
                load: @management_calculations,
                sort: [name: :asc, id: :asc]
              )

      prepare fn query, context ->
        methods =
          Ash.Query.for_read(Skopos.Targets.AccessMethod, :management_summary, %{},
            actor: context.actor
          )

        query
        |> Ash.Query.load(access_methods: methods)
        |> Ash.Query.around_transaction(fn query, callback ->
          try do
            callback.(query)
          rescue
            error in Ash.Error.Unknown -> {:error, error}
          end
        end)
      end
    end

    read :search_index do
      argument :query, :string,
        allow_nil?: false,
        constraints: [min_length: 1, max_length: Skopos.Targets.SearchQuery.max_codepoints()]

      filter expr(active == true and contains(search_text, ^arg(:query)))
      prepare build(sort: [name: :asc, id: :asc])
    end

    create :create do
      primary? true
      accept [:name, :kind, :type_id, :facts, :management_boundary_id, :operating_instructions]
      validate {Skopos.Validations.BoundedMap, attribute: :facts}
      validate Skopos.Targets.Target.Validations.Type
      change {Skopos.Targets.Changes.BuildSearchText, fields: [:name, :kind, :type_id, :facts]}
      change Skopos.Targets.Changes.EnqueueCaseReconciliation
    end

    update :update do
      primary? true
      accept [:name, :kind, :type_id, :facts, :management_boundary_id, :operating_instructions]
      require_atomic? false

      argument :expected_revision, :integer, allow_nil?: false, constraints: [min: 1]

      validate Skopos.Validations.CurrentRevision
      validate {Skopos.Validations.BoundedMap, attribute: :facts}
      validate Skopos.Targets.Target.Validations.Type
      change {Skopos.Targets.Changes.BuildSearchText, fields: [:name, :kind, :type_id, :facts]}
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

    action :search, :struct do
      constraints instance_of: Skopos.Targets.SearchResult

      argument :query, :string,
        allow_nil?: false,
        constraints: [min_length: 1, max_length: Skopos.Targets.SearchQuery.max_codepoints()]

      argument :max_results, :integer,
        allow_nil?: false,
        default: 20,
        constraints: [min: 1, max: 50]

      run Skopos.Targets.Target.Actions.Search
    end
  end

  policies do
    policy action(:type_catalog) do
      authorize_if actor_attribute_equals(:role, :admin)
      authorize_if actor_attribute_equals(:role, :operator)
      authorize_if actor_attribute_equals(:role, :viewer)
    end

    policy action([:create, :update, :deactivate]) do
      authorize_if actor_attribute_equals(:role, :admin)
    end

    policy action(:search_index) do
      forbid_if always()
    end

    policy action(:search) do
      authorize_if actor_attribute_equals(:role, :admin)
      authorize_if actor_attribute_equals(:role, :operator)
    end

    policy action([:read, :page, :reference_page, :management_page]) do
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

    attribute :type_id, :string do
      allow_nil? false
      public? true
      constraints min_length: 1, max_length: 120
    end

    attribute :facts, :map do
      allow_nil? false
      public? true
      default %{}
    end

    attribute :operating_instructions, :string do
      allow_nil? false
      public? true
      default ""
      constraints allow_empty?: true, max_length: 4_000
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

    attribute :revision, :integer do
      allow_nil? false
      public? true
      default 1
      constraints min: 1
    end

    timestamps()
  end

  relationships do
    belongs_to :management_boundary, Skopos.Targets.ManagementBoundary do
      public? true
    end

    has_many :external_identities, Skopos.Targets.ExternalIdentity
    has_many :access_methods, Skopos.Targets.AccessMethod

    has_many :outgoing_relationships, Skopos.Targets.Relationship do
      destination_attribute :source_target_id
    end

    has_many :incoming_relationships, Skopos.Targets.Relationship do
      destination_attribute :destination_target_id
    end
  end

  calculations do
    calculate :method_count,
              :integer,
              expr(count(access_methods, query: [filter: expr(active == true)]))

    calculate :relationship_count,
              :integer,
              expr(outgoing_relationship_count + incoming_relationship_count)

    calculate :has_operating_instructions, :boolean, expr(operating_instructions != "")
  end

  aggregates do
    count :outgoing_relationship_count, :outgoing_relationships do
      filter expr(active == true)
    end

    count :incoming_relationship_count, :incoming_relationships do
      filter expr(active == true)
    end
  end
end
