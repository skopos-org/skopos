defmodule Skopos.Targets.InventoryImport do
  use Ash.Resource,
    otp_app: :skopos,
    domain: Skopos.Targets,
    authorizers: [Ash.Policy.Authorizer],
    data_layer: AshPostgres.DataLayer

  defmodule Error do
    @moduledoc false
    use Splode.Error, class: :invalid, fields: [:category, :message]

    @impl true
    def message(error), do: error.message
  end

  postgres do
    table "inventory_imports"
    repo Skopos.Repo

    custom_indexes do
      index [:provider_id]
      index [:created_by_id]
    end
  end

  actions do
    defaults [:read]

    read :page do
      pagination keyset?: true, required?: true, default_limit: 50, max_page_size: 100
      prepare build(sort: [inserted_at: :asc, id: :asc])
    end

    create :create_preview do
      accept [
        :source_type,
        :source,
        :status,
        :snapshot_status,
        :source_version,
        :content_digest,
        :row_count,
        :error_count,
        :provider_id,
        :created_by_id
      ]
    end

    update :mark_applied do
      accept []
      require_atomic? false
      argument :expected_revision, :integer, allow_nil?: false, constraints: [min: 1]
      validate Skopos.Validations.CurrentRevision
      validate attribute_equals(:status, :previewed)
      change set_attribute(:status, :applied)
      change atomic_update(:applied_at, expr(now()))
      change optimistic_lock(:revision)
    end

    action :preview_manual, :struct do
      constraints instance_of: __MODULE__
      transaction? false
      argument :source, :string, allow_nil?: false, constraints: [min_length: 1, max_length: 120]

      argument :csv, :string,
        allow_nil?: false,
        constraints: [min_length: 1, max_length: 10_485_760]

      run {Skopos.Targets.InventoryImport.Actions.Preview, operation: :manual}
    end

    action :preview_inventory, :struct do
      constraints instance_of: __MODULE__
      transaction? false
      argument :source, :string, allow_nil?: false, constraints: [min_length: 1, max_length: 120]
      argument :provider_id, :uuid, allow_nil?: false

      argument :request, :struct,
        allow_nil?: false,
        constraints: [instance_of: Skopos.Providers.Inventory.Request]

      argument :invocation, :map, allow_nil?: false, default: %{}
      run {Skopos.Targets.InventoryImport.Actions.Preview, operation: :inventory}
    end

    action :apply, :struct do
      constraints instance_of: __MODULE__
      transaction? false
      argument :id, :uuid, allow_nil?: false
      argument :expected_revision, :integer, allow_nil?: false, constraints: [min: 1]

      argument :expected_digest, :string,
        allow_nil?: false,
        constraints: [min_length: 64, max_length: 64]

      run Skopos.Targets.InventoryImport.Actions.Apply
    end
  end

  policies do
    policy action([:preview_manual, :preview_inventory, :apply]) do
      authorize_if actor_attribute_equals(:role, :admin)
    end

    policy action([:create_preview, :mark_applied]) do
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

    attribute :source_type, :atom do
      allow_nil? false
      public? true
      constraints one_of: [:manual, :inventory]
    end

    attribute :source, :string do
      allow_nil? false
      public? true
      constraints min_length: 1, max_length: 120
    end

    attribute :status, :atom do
      allow_nil? false
      public? true
      constraints one_of: [:previewed, :applied]
    end

    attribute :snapshot_status, :atom do
      public? true
      constraints one_of: [:complete, :partial]
    end

    attribute :source_version, :string do
      public? true
      constraints max_length: 1_024
    end

    attribute :content_digest, :string do
      allow_nil? false
      public? true
      constraints min_length: 64, max_length: 64
    end

    attribute :row_count, :integer do
      allow_nil? false
      public? true
      constraints min: 0, max: 100_000
    end

    attribute :error_count, :integer do
      allow_nil? false
      public? true
      constraints min: 0, max: 100_000
    end

    attribute :revision, :integer do
      allow_nil? false
      public? true
      default 1
      constraints min: 1
    end

    attribute :applied_at, :utc_datetime_usec do
      public? true
    end

    timestamps()
  end

  relationships do
    belongs_to :provider, Skopos.Providers.Provider do
      public? true
    end

    belongs_to :created_by, Skopos.Accounts.User do
      allow_nil? false
      public? true
    end

    has_many :rows, Skopos.Targets.InventoryImportRow
  end
end
