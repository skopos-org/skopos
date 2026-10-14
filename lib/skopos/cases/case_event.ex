defmodule Skopos.Cases.CaseEvent do
  use Ash.Resource,
    otp_app: :skopos,
    domain: Skopos.Cases,
    authorizers: [Ash.Policy.Authorizer],
    simple_notifiers: [Skopos.Cases.Case.RealtimeNotifier],
    data_layer: AshPostgres.DataLayer

  postgres do
    table "case_events"
    repo Skopos.Repo

    custom_indexes do
      index [:case_id]
      index [:resolution_run_id]
      index [:actor_id]
    end
  end

  actions do
    defaults [:read]

    read :timeline do
      prepare build(sort: [inserted_at: :asc, id: :asc])
    end

    read :page_for_case do
      argument :case_id, :uuid, allow_nil?: false
      filter expr(case_id == ^arg(:case_id))
      pagination keyset?: true, required?: true, default_limit: 100, max_page_size: 500
      prepare build(sort: [inserted_at: :desc, id: :desc])
    end

    read :by_idempotency do
      get? true
      argument :case_id, :uuid, allow_nil?: false

      argument :idempotency_key, :string,
        allow_nil?: false,
        constraints: [min_length: 1, max_length: 500]

      filter expr(case_id == ^arg(:case_id) and idempotency_key == ^arg(:idempotency_key))
    end

    read :target_history do
      argument :case_id, :uuid, allow_nil?: false
      argument :resolution_run_id, :uuid, allow_nil?: false

      filter expr(
               case_id == ^arg(:case_id) and
                 resolution_run_id == ^arg(:resolution_run_id) and
                 event_type in ["case_opened", "case_target_selected", "related_target_traversed"]
             )

      prepare build(sort: [inserted_at: :asc, id: :asc])
    end

    read :recovery_review_history do
      argument :case_id, :uuid, allow_nil?: false
      filter expr(case_id == ^arg(:case_id) and event_type == "recovery_review_decided")
      prepare build(sort: [inserted_at: :desc, id: :desc], limit: 501)
    end

    read :observation_progress_history do
      argument :case_id, :uuid, allow_nil?: false
      argument :resolution_run_id, :uuid, allow_nil?: false

      filter expr(
               case_id == ^arg(:case_id) and resolution_run_id == ^arg(:resolution_run_id) and
                 event_type == "observation_progress"
             )

      prepare build(sort: [inserted_at: :desc, id: :desc], limit: 1_001)
    end

    create :create_record do
      accept [
        :case_id,
        :resolution_run_id,
        :actor_id,
        :event_type,
        :idempotency_key,
        :data
      ]

      validate {Skopos.Validations.BoundedMap, attribute: :data}
    end

    action :record_report_generation_failure, :struct do
      constraints instance_of: __MODULE__
      transaction? false
      argument :case_id, :uuid, allow_nil?: false
      argument :case_revision, :integer, allow_nil?: false, constraints: [min: 1]
      run Skopos.Cases.CaseEvent.Actions.RecordReportGenerationFailure
    end
  end

  policies do
    policy action([
             :by_idempotency,
             :target_history,
             :recovery_review_history,
             :observation_progress_history,
             :create_record,
             :record_report_generation_failure
           ]) do
      forbid_if always()
    end

    policy action([:read, :timeline, :page_for_case]) do
      authorize_if actor_attribute_equals(:role, :admin)
      authorize_if actor_attribute_equals(:role, :operator)
      authorize_if actor_attribute_equals(:role, :viewer)
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :event_type, :string do
      allow_nil? false
      public? true
      constraints min_length: 1, max_length: 80
    end

    attribute :idempotency_key, :string do
      public? true
      constraints min_length: 1, max_length: 500
    end

    attribute :data, :map do
      allow_nil? false
      public? true
      default %{}
    end

    create_timestamp :inserted_at
  end

  relationships do
    belongs_to :case, Skopos.Cases.Case do
      allow_nil? false
      public? true
    end

    belongs_to :resolution_run, Skopos.Cases.ResolutionRun do
      public? true
    end

    belongs_to :actor, Skopos.Accounts.User do
      public? true
    end
  end

  identities do
    identity :unique_idempotency, [:case_id, :idempotency_key]
  end
end
