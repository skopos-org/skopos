defmodule Skopos.Cases.Turn do
  @summary_fields ~w(id case_id resolution_run_id ordinal status progress_kind started_at completed_at revision inserted_at updated_at)a
  # Retain the admitted 64 KiB AI decision plus current Condition revisions,
  # normalized groups and exact tool/relationship snapshots added by delivery.
  @max_result_bytes 131_072

  def summary_fields, do: @summary_fields
  def max_result_bytes, do: @max_result_bytes

  use Ash.Resource,
    otp_app: :skopos,
    domain: Skopos.Cases,
    authorizers: [Ash.Policy.Authorizer],
    simple_notifiers: [Skopos.Cases.Case.RealtimeNotifier],
    data_layer: AshPostgres.DataLayer

  postgres do
    table "turns"
    repo Skopos.Repo
    identity_wheres_to_sql one_started_turn: "status = 'started'"

    custom_indexes do
      index [:case_id]
      index [:resolution_run_id]
    end
  end

  actions do
    defaults [:read]

    read :page_for_case do
      argument :case_id, :uuid, allow_nil?: false
      filter expr(case_id == ^arg(:case_id))
      pagination keyset?: true, required?: true, default_limit: 100, max_page_size: 500

      prepare build(
                select: @summary_fields,
                load: [:summary],
                sort: [inserted_at: :desc, id: :desc]
              )
    end

    read :latest_condition_context do
      argument :case_id, :uuid, allow_nil?: false
      argument :condition_revisions, {:array, :map}, allow_nil?: false

      argument :field, :string,
        allow_nil?: false,
        constraints: [match: ~r/\Acondition_(groups|assessments)\z/]

      filter expr(
               case_id == ^arg(:case_id) and status == :completed and
                 fragment(
                   "? -> 'condition_revisions' = to_jsonb(?::jsonb[])",
                   result,
                   ^arg(:condition_revisions)
                 ) and
                 fragment("jsonb_typeof(? -> ?) = 'array'", result, ^arg(:field)) and
                 (^arg(:field) == "condition_groups" or
                    fragment("? -> ? <> '[]'::jsonb", result, ^arg(:field)))
             )

      prepare build(
                select: [:id, :ordinal, :revision, :completed_at],
                load: [:condition_context],
                sort: [completed_at: :desc, inserted_at: :desc, id: :desc],
                limit: 1
              )
    end

    read :by_idempotency do
      get? true
      argument :resolution_run_id, :uuid, allow_nil?: false

      argument :idempotency_key, :string,
        allow_nil?: false,
        constraints: [min_length: 1, max_length: 500]

      filter expr(
               resolution_run_id == ^arg(:resolution_run_id) and
                 idempotency_key == ^arg(:idempotency_key)
             )
    end

    read :started_for_run do
      argument :resolution_run_id, :uuid, allow_nil?: false

      filter expr(resolution_run_id == ^arg(:resolution_run_id) and status == :started)
    end

    create :create_record do
      accept [
        :case_id,
        :resolution_run_id,
        :ordinal,
        :idempotency_key,
        :status,
        :intent,
        :result,
        :result_digest,
        :progress_kind,
        :started_at,
        :completed_at
      ]

      validate {Skopos.Validations.BoundedMap, attribute: :intent}
      validate {Skopos.Validations.BoundedMap, attribute: :result, max_bytes: @max_result_bytes}
    end

    update :complete_record do
      accept [:result, :result_digest, :progress_kind, :completed_at]
      require_atomic? false
      argument :expected_revision, :integer, allow_nil?: false, constraints: [min: 1]
      validate Skopos.Validations.CurrentRevision
      validate attribute_equals(:status, :started)
      validate {Skopos.Validations.BoundedMap, attribute: :result, max_bytes: @max_result_bytes}
      change set_attribute(:status, :completed)
      change optimistic_lock(:revision)
    end

    action :start, :struct do
      constraints instance_of: Skopos.Cases.ResolutionRun.BudgetResult
      transaction? false
      argument :case_id, :uuid, allow_nil?: false
      argument :resolution_run_id, :uuid, allow_nil?: false

      argument :idempotency_key, :string,
        allow_nil?: false,
        constraints: [min_length: 1, max_length: 500]

      argument :intent, :map, allow_nil?: false
      argument :pending_intent, :map, allow_nil?: false

      argument :required_human_input, :string,
        allow_nil?: false,
        constraints: [min_length: 1, max_length: 1_000]

      run Skopos.Cases.Turn.Actions.Start
    end

    action :complete, :struct do
      constraints instance_of: Skopos.Cases.ResolutionRun.BudgetResult
      transaction? false
      argument :id, :uuid, allow_nil?: false
      argument :expected_revision, :integer, allow_nil?: false, constraints: [min: 1]
      argument :result, :map, allow_nil?: false

      argument :progress_kind, :atom,
        allow_nil?: false,
        constraints: [
          one_of: [
            :evidence,
            :hypothesis,
            :proposal,
            :observation_pending,
            :delivery_retry,
            :source_change,
            :human_input,
            :none
          ]
        ]

      argument :pending_intent, :map, allow_nil?: false

      argument :required_human_input, :string,
        allow_nil?: false,
        constraints: [min_length: 1, max_length: 1_000]

      run Skopos.Cases.Turn.Actions.Complete
    end
  end

  policies do
    policy action([
             :by_idempotency,
             :started_for_run,
             :create_record,
             :complete_record,
             :start,
             :complete
           ]) do
      forbid_if always()
    end

    policy action([:read, :page_for_case, :latest_condition_context]) do
      authorize_if actor_attribute_equals(:role, :admin)
      authorize_if actor_attribute_equals(:role, :operator)
      authorize_if actor_attribute_equals(:role, :viewer)
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :ordinal, :integer do
      allow_nil? false
      public? true
    end

    attribute :idempotency_key, :string do
      allow_nil? false
      public? true
    end

    attribute :status, :atom do
      allow_nil? false
      public? true
      constraints one_of: [:started, :completed]
    end

    attribute :intent, :map do
      allow_nil? false
      public? true
    end

    attribute :result, :map do
      allow_nil? false
      public? true
      default %{}
    end

    attribute :result_digest, :string do
      public? true
    end

    attribute :progress_kind, :atom do
      public? true

      constraints one_of: [
                    :evidence,
                    :hypothesis,
                    :proposal,
                    :observation_pending,
                    :delivery_retry,
                    :source_change,
                    :human_input,
                    :none
                  ]
    end

    attribute :started_at, :utc_datetime_usec do
      allow_nil? false
      public? true
    end

    attribute :completed_at, :utc_datetime_usec do
      public? true
    end

    attribute :revision, :integer do
      allow_nil? false
      default 1
      constraints min: 1
    end

    timestamps()
  end

  relationships do
    belongs_to :case, Skopos.Cases.Case do
      allow_nil? false
      public? true
    end

    belongs_to :resolution_run, Skopos.Cases.ResolutionRun do
      allow_nil? false
      public? true
    end
  end

  calculations do
    calculate :summary,
              :map,
              expr(
                fragment(
                  """
                  (SELECT jsonb_build_object(
                    'outcome', left(r.value ->> 'outcome', 120),
                    'type', left(r.value #>> '{intent,type}', 120),
                    'reason', left(r.value #>> '{intent,reason}', 500),
                    'target_id', left(coalesce(r.value #>> '{intent,target_id}', r.value #>> '{intent,next_target_id}', r.value #>> '{intent,relationship,destination_target_id}'), 36),
                    'capability', left(r.value #>> '{intent,tool,capability}', 120),
                    'operation', left(r.value #>> '{intent,tool,operation}', 120),
                    'failure_category', left(r.value ->> 'category', 120),
                    'failure_message', left(r.value ->> 'message', 500),
                    'relationship', CASE WHEN jsonb_typeof(r.value #> '{intent,relationship}') = 'object' THEN jsonb_build_object(
                      'source_target_id', left(r.value #>> '{intent,relationship,source_target_id}', 36),
                      'destination_target_id', left(r.value #>> '{intent,relationship,destination_target_id}', 36),
                      'kind', left(r.value #>> '{intent,relationship,kind}', 120)) ELSE NULL END
                  ) FROM (SELECT ?::jsonb AS value) r)
                  """,
                  result
                )
              )

    calculate :condition_context,
              :map,
              expr(
                fragment(
                  """
                  (SELECT jsonb_build_object(
                    'condition_revisions', r.value -> 'condition_revisions',
                    'condition_groups', r.value -> 'condition_groups',
                    'condition_assessments', r.value -> 'condition_assessments'
                  ) FROM (SELECT ?::jsonb AS value) r)
                  """,
                  result
                )
              )
  end

  identities do
    identity :unique_idempotency, [:resolution_run_id, :idempotency_key]
    identity :unique_ordinal, [:resolution_run_id, :ordinal]

    identity :one_started_turn, [:resolution_run_id] do
      where expr(status == :started)
    end
  end
end
