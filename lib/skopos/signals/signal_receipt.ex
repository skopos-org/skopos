defmodule Skopos.Signals.SignalReceipt do
  use Ash.Resource,
    otp_app: :skopos,
    domain: Skopos.Signals,
    authorizers: [Ash.Policy.Authorizer],
    data_layer: AshPostgres.DataLayer

  postgres do
    table "signal_receipts"
    repo Skopos.Repo

    custom_indexes do
      index [:provider_id]
      index [:source]
    end
  end

  actions do
    defaults [:read]

    read :page do
      pagination keyset?: true, required?: true, default_limit: 50, max_page_size: 100
      prepare build(sort: [received_at: :desc, id: :desc])
    end

    read :by_source_identity do
      get? true
      argument :provider_id, :uuid, allow_nil?: false

      argument :receipt_id, :string,
        allow_nil?: false,
        constraints: [min_length: 1, max_length: 500]

      filter expr(provider_id == ^arg(:provider_id) and receipt_id == ^arg(:receipt_id))
    end

    create :create_record do
      accept [
        :provider_id,
        :provider_revision,
        :receipt_id,
        :source,
        :received_at,
        :metadata,
        :normalized_digest,
        :event_count
      ]

      validate {Skopos.Validations.BoundedMap, attribute: :metadata}
    end

    action :ingest, :struct do
      constraints instance_of: __MODULE__
      transaction? false

      argument :provider_id, :uuid, allow_nil?: false
      argument :provider_revision, :integer, allow_nil?: false, constraints: [min: 1]

      argument :envelope, :struct,
        allow_nil?: false,
        constraints: [instance_of: Skopos.Providers.Signal.Envelope]

      argument :invocation, :map, allow_nil?: false, default: %{}
      run Skopos.Signals.SignalReceipt.Actions.Ingest
    end
  end

  policies do
    policy action([:by_source_identity, :create_record]) do
      forbid_if always()
    end

    policy action(:ingest) do
      authorize_if always()
    end

    policy action([:read, :page]) do
      authorize_if actor_attribute_equals(:role, :admin)
      authorize_if actor_attribute_equals(:role, :operator)
      authorize_if actor_attribute_equals(:role, :viewer)
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :provider_revision, :integer do
      allow_nil? false
      public? true
      constraints min: 1
    end

    attribute :receipt_id, :string do
      allow_nil? false
      public? true
      constraints min_length: 1, max_length: 500
    end

    attribute :source, :string do
      allow_nil? false
      public? true
      constraints min_length: 1, max_length: 120
    end

    attribute :received_at, :utc_datetime_usec do
      allow_nil? false
      public? true
    end

    attribute :metadata, :map do
      allow_nil? false
      public? true
      default %{}
    end

    attribute :normalized_digest, :string do
      allow_nil? false
      public? false
      constraints min_length: 64, max_length: 64
    end

    attribute :event_count, :integer do
      allow_nil? false
      public? true
      constraints min: 1, max: 1_000
    end

    timestamps()
  end

  relationships do
    belongs_to :provider, Skopos.Providers.Provider do
      allow_nil? false
      public? true
    end

    has_many :events, Skopos.Signals.SignalEvent
  end

  identities do
    identity :unique_source_receipt, [:provider_id, :receipt_id]
  end
end
