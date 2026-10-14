defmodule Skopos.Signals.SignalCorrelation do
  use Ash.Resource,
    otp_app: :skopos,
    domain: Skopos.Signals,
    authorizers: [Ash.Policy.Authorizer],
    data_layer: AshPostgres.DataLayer

  postgres do
    table "signal_correlations"
    repo Skopos.Repo

    custom_indexes do
      index [:provider_id]
      index [:latest_signal_event_id]
    end
  end

  actions do
    defaults [:read]

    read :by_source_identity do
      get? true
      argument :provider_id, :uuid, allow_nil?: false

      argument :source, :string,
        allow_nil?: false,
        constraints: [min_length: 1, max_length: 120]

      argument :event_key, :string,
        allow_nil?: false,
        constraints: [min_length: 1, max_length: 500]

      filter expr(
               provider_id == ^arg(:provider_id) and source == ^arg(:source) and
                 event_key == ^arg(:event_key)
             )
    end

    create :create_record do
      accept [:provider_id, :source, :event_key, :current_state, :revision]
    end

    update :update_record do
      accept [
        :current_state,
        :current_occurred_at,
        :current_source_sequence,
        :latest_signal_event_id
      ]

      require_atomic? false
      argument :expected_revision, :integer, allow_nil?: false, constraints: [min: 1]
      validate Skopos.Validations.CurrentRevision
      change optimistic_lock(:revision)
    end
  end

  policies do
    policy action([:by_source_identity, :create_record, :update_record]) do
      forbid_if always()
    end

    policy action(:read) do
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

    attribute :event_key, :string do
      allow_nil? false
      public? true
      constraints min_length: 1, max_length: 500
    end

    attribute :current_state, :atom do
      allow_nil? false
      public? true
      default :pending
      constraints one_of: [:pending, :firing, :recovered]
    end

    attribute :current_occurred_at, :utc_datetime_usec do
      public? true
    end

    attribute :current_source_sequence, :string do
      public? true
      constraints max_length: 500
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

    belongs_to :latest_signal_event, Skopos.Signals.SignalEvent do
      public? true
    end

    has_many :events, Skopos.Signals.SignalEvent
  end

  identities do
    identity :unique_source_event, [:provider_id, :source, :event_key]
  end
end
