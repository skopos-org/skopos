defmodule Skopos.Signals.Condition do
  use Ash.Resource,
    otp_app: :skopos,
    domain: Skopos.Signals,
    authorizers: [Ash.Policy.Authorizer],
    data_layer: AshPostgres.DataLayer

  postgres do
    table "conditions"
    repo Skopos.Repo

    custom_indexes do
      index [:signal_correlation_id, :subject_key, :predicate],
        unique: true,
        name: "conditions_one_firing_subject",
        where: "state = 'firing'"

      index [:target_id]
      index [:subject_key, :predicate]
    end
  end

  actions do
    defaults [:read]

    read :latest_for_correlation do
      get? true
      argument :signal_correlation_id, :uuid, allow_nil?: false
      filter expr(signal_correlation_id == ^arg(:signal_correlation_id))
      prepare build(sort: [occurrence: :desc], limit: 1)
    end

    read :latest_for_identity do
      get? true
      argument :signal_correlation_id, :uuid, allow_nil?: false
      argument :subject_key, :string, allow_nil?: false
      argument :predicate, :string, allow_nil?: false

      filter expr(
               signal_correlation_id == ^arg(:signal_correlation_id) and
                 subject_key == ^arg(:subject_key) and predicate == ^arg(:predicate)
             )

      prepare build(sort: [occurrence: :desc], limit: 1)
    end

    read :previous_for_identity do
      get? true
      argument :signal_correlation_id, :uuid, allow_nil?: false
      argument :occurrence, :integer, allow_nil?: false, constraints: [min: 2]
      argument :subject_key, :string, allow_nil?: false
      argument :predicate, :string, allow_nil?: false

      filter expr(
               signal_correlation_id == ^arg(:signal_correlation_id) and
                 occurrence < ^arg(:occurrence) and subject_key == ^arg(:subject_key) and
                 predicate == ^arg(:predicate)
             )

      prepare build(sort: [occurrence: :desc], limit: 1)
    end

    read :same_subject do
      argument :subject_key, :string, allow_nil?: false
      argument :predicate, :string, allow_nil?: false
      filter expr(subject_key == ^arg(:subject_key) and predicate == ^arg(:predicate))
      prepare build(sort: [updated_at: :desc, id: :desc], limit: 64)
    end

    create :create_record do
      accept [
        :signal_correlation_id,
        :target_id,
        :occurrence,
        :predicate,
        :subject_key,
        :subject_ref,
        :state,
        :first_fired_at,
        :current_occurred_at,
        :current_source_sequence
      ]

      validate {Skopos.Validations.BoundedMap,
                attribute: :subject_ref, max_fields: 4, max_bytes: 4_096}
    end

    update :record_state do
      accept [:state, :current_occurred_at, :current_source_sequence]
      require_atomic? false
      argument :expected_revision, :integer, allow_nil?: false, constraints: [min: 1]
      validate Skopos.Validations.CurrentRevision
      change optimistic_lock(:revision)
    end

    action :record_source_event, :map do
      transaction? false
      argument :signal_correlation_id, :uuid, allow_nil?: false
      argument :state, :atom, allow_nil?: false, constraints: [one_of: [:firing, :recovered]]
      argument :occurred_at, :utc_datetime_usec, allow_nil?: false
      argument :source_sequence, :string
      argument :target_id, :uuid
      argument :subject_ref, :map, allow_nil?: false

      argument :subject_key, :string,
        allow_nil?: false,
        constraints: [min_length: 1, max_length: 600]

      argument :predicate, :string,
        allow_nil?: false,
        constraints: [min_length: 1, max_length: 500]

      argument :current, :boolean, allow_nil?: false
      run Skopos.Signals.Condition.Actions.RecordSourceEvent
    end
  end

  policies do
    policy action([
             :latest_for_correlation,
             :latest_for_identity,
             :previous_for_identity,
             :same_subject,
             :create_record,
             :record_state,
             :record_source_event
           ]) do
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

    attribute :occurrence, :integer do
      allow_nil? false
      public? true
      constraints min: 1
    end

    attribute :predicate, :string do
      allow_nil? false
      public? true
      constraints min_length: 1, max_length: 500
    end

    attribute :subject_key, :string do
      allow_nil? false
      public? true
      constraints min_length: 1, max_length: 600
    end

    attribute :subject_ref, :map do
      allow_nil? false
      public? true
      default %{}
    end

    attribute :state, :atom do
      allow_nil? false
      public? true
      constraints one_of: [:firing, :recovered]
    end

    attribute :first_fired_at, :utc_datetime_usec do
      allow_nil? false
      public? true
    end

    attribute :current_occurred_at, :utc_datetime_usec do
      allow_nil? false
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
    belongs_to :signal_correlation, Skopos.Signals.SignalCorrelation do
      allow_nil? false
      public? true
    end

    belongs_to :target, Skopos.Targets.Target do
      public? true
    end
  end

  identities do
    identity :unique_occurrence, [:signal_correlation_id, :occurrence]
  end
end
