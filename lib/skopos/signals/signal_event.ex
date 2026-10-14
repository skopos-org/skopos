defmodule Skopos.Signals.SignalEvent do
  use Ash.Resource,
    otp_app: :skopos,
    domain: Skopos.Signals,
    authorizers: [Ash.Policy.Authorizer],
    data_layer: AshPostgres.DataLayer

  postgres do
    table "signal_events"
    repo Skopos.Repo

    custom_indexes do
      index [:signal_receipt_id]
      index [:signal_correlation_id]
      index [:condition_id]
      index [:case_id]
      index [:target_id]
    end
  end

  actions do
    defaults [:read]

    read :page_for_receipt do
      argument :signal_receipt_id, :uuid, allow_nil?: false
      filter expr(signal_receipt_id == ^arg(:signal_receipt_id))
      pagination keyset?: true, required?: true, default_limit: 100, max_page_size: 500
      prepare build(sort: [occurred_at: :asc, inserted_at: :asc, id: :asc])
    end

    read :by_receipt_event do
      get? true
      argument :signal_receipt_id, :uuid, allow_nil?: false

      argument :event_key, :string,
        allow_nil?: false,
        constraints: [min_length: 1, max_length: 500]

      filter expr(
               signal_receipt_id == ^arg(:signal_receipt_id) and
                 event_key == ^arg(:event_key)
             )
    end

    create :create_record do
      accept [
        :signal_receipt_id,
        :signal_correlation_id,
        :condition_id,
        :event_key,
        :state,
        :source_sequence,
        :occurred_at,
        :target_ref,
        :attributes,
        :metadata,
        :case_id,
        :target_id
      ]

      validate {Skopos.Validations.BoundedMap, attribute: :attributes}
      validate {Skopos.Validations.BoundedMap, attribute: :metadata}
    end
  end

  policies do
    policy action([:by_receipt_event, :create_record]) do
      forbid_if always()
    end

    policy action([:read, :page_for_receipt]) do
      authorize_if actor_attribute_equals(:role, :admin)
      authorize_if actor_attribute_equals(:role, :operator)
      authorize_if actor_attribute_equals(:role, :viewer)
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :event_key, :string do
      allow_nil? false
      public? true
      constraints min_length: 1, max_length: 500
    end

    attribute :state, :atom do
      allow_nil? false
      public? true
      constraints one_of: [:firing, :recovered]
    end

    attribute :source_sequence, :string do
      public? true
      constraints max_length: 500
    end

    attribute :occurred_at, :utc_datetime_usec do
      allow_nil? false
      public? true
    end

    attribute :target_ref, :map do
      public? true
    end

    attribute :attributes, :map do
      allow_nil? false
      public? true
      default %{}
    end

    attribute :metadata, :map do
      allow_nil? false
      public? true
      default %{}
    end

    timestamps()
  end

  relationships do
    belongs_to :signal_receipt, Skopos.Signals.SignalReceipt do
      allow_nil? false
      public? true
    end

    belongs_to :signal_correlation, Skopos.Signals.SignalCorrelation do
      allow_nil? false
      public? true
    end

    belongs_to :condition, Skopos.Signals.Condition do
      public? true
    end

    belongs_to :case, Skopos.Cases.Case do
      public? true
    end

    belongs_to :target, Skopos.Targets.Target do
      public? true
    end
  end

  identities do
    identity :unique_receipt_event, [:signal_receipt_id, :signal_correlation_id]
  end
end
