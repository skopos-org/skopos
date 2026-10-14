defmodule Skopos.Audits.AuditRun do
  use Ash.Resource,
    otp_app: :skopos,
    domain: Skopos.Audits,
    authorizers: [Ash.Policy.Authorizer],
    data_layer: AshPostgres.DataLayer

  @summary_fields ~w(id audit_schedule_id schedule_revision target_key target_id target_revision case_id case_revision scheduled_for status started_at completed_at revision inserted_at updated_at)a
  def summary_fields, do: @summary_fields

  postgres do
    table "audit_runs"
    repo Skopos.Repo

    custom_indexes do
      index [:audit_schedule_id]
      index [:target_id]
      index [:case_id]
      index [:status]
    end

    check_constraints do
      check_constraint [:target_id, :target_revision],
                       "audit_runs_target_pair",
                       check:
                         "(target_id IS NULL AND target_revision IS NULL) OR " <>
                           "(target_id IS NOT NULL AND target_revision IS NOT NULL)",
                       message: "must be set together"

      check_constraint [:case_id, :case_revision],
                       "audit_runs_case_pair",
                       check:
                         "(case_id IS NULL AND case_revision IS NULL) OR " <>
                           "(case_id IS NOT NULL AND case_revision IS NOT NULL)",
                       message: "must be set together"
    end
  end

  actions do
    defaults [:read]

    read :report_period do
      pagination keyset?: true, required?: true, default_limit: 100, max_page_size: 100
      argument :from, :utc_datetime_usec, allow_nil?: false
      argument :to, :utc_datetime_usec, allow_nil?: false
      argument :target_id, :uuid

      filter expr(
               scheduled_for >= ^arg(:from) and scheduled_for < ^arg(:to) and
                 (is_nil(^arg(:target_id)) or target_id == ^arg(:target_id))
             )

      prepare build(sort: [scheduled_for: :asc, id: :asc])
    end

    read :page do
      pagination keyset?: true, required?: true, default_limit: 50, max_page_size: 100
      prepare build(sort: [scheduled_for: :desc, id: :desc])
    end

    read :summaries do
      argument :ids, {:array, :uuid}, constraints: [min_length: 1, max_length: 100]
      filter expr(is_nil(^arg(:ids)) or id in ^arg(:ids))
      pagination keyset?: true, required?: true, default_limit: 50, max_page_size: 100
      prepare build(select: @summary_fields, sort: [scheduled_for: :desc, id: :desc])
    end

    read :for_occurrence do
      argument :audit_schedule_id, :uuid, allow_nil?: false
      argument :scheduled_for, :utc_datetime_usec, allow_nil?: false

      filter expr(
               audit_schedule_id == ^arg(:audit_schedule_id) and
                 scheduled_for == ^arg(:scheduled_for)
             )

      prepare build(sort: [target_key: :asc])
    end

    create :create_record do
      accept [
        :audit_schedule_id,
        :schedule_revision,
        :target_key,
        :target_id,
        :target_revision,
        :scheduled_for,
        :status,
        :reason,
        :started_at,
        :completed_at
      ]
    end

    update :mark_running do
      accept [:started_at]
      require_atomic? false
      argument :expected_revision, :integer, allow_nil?: false, constraints: [min: 1]
      filter expr(status == :queued)
      validate Skopos.Validations.CurrentRevision
      change set_attribute(:status, :running)
      change optimistic_lock(:revision)
    end

    update :record_outcome do
      accept [:status, :reason, :case_id, :case_revision, :completed_at]
      require_atomic? false
      argument :expected_revision, :integer, allow_nil?: false, constraints: [min: 1]
      filter expr(status in [:queued, :running])
      validate Skopos.Validations.CurrentRevision
      validate attribute_in(:status, [:case_opened, :skipped, :cancelled, :failed])
      validate present(:completed_at)
      change optimistic_lock(:revision)
    end

    action :claim, :struct do
      constraints instance_of: Skopos.Audits.AuditRun.ClaimResult
      transaction? false
      argument :id, :uuid, allow_nil?: false
      run Skopos.Audits.AuditRun.Actions.Claim
    end
  end

  policies do
    policy action([:for_occurrence, :create_record, :mark_running, :record_outcome, :claim]) do
      forbid_if always()
    end

    policy action([:read, :page, :report_period, :summaries]) do
      authorize_if actor_attribute_equals(:role, :admin)
      authorize_if actor_attribute_equals(:role, :operator)
      authorize_if actor_attribute_equals(:role, :viewer)
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :schedule_revision, :integer do
      allow_nil? false
      public? true
      constraints min: 1
    end

    attribute :target_key, :string do
      allow_nil? false
      public? true
      constraints min_length: 1, max_length: 160
    end

    attribute :target_revision, :integer do
      public? true
      constraints min: 1
    end

    attribute :case_revision, :integer do
      public? true
      constraints min: 1
    end

    attribute :scheduled_for, :utc_datetime_usec do
      allow_nil? false
      public? true
    end

    attribute :status, :atom do
      allow_nil? false
      public? true
      constraints one_of: [:queued, :running, :case_opened, :skipped, :cancelled, :failed]
    end

    attribute :reason, :string do
      public? true
      constraints min_length: 1, max_length: 1_000
    end

    attribute :started_at, :utc_datetime_usec do
      public? true
    end

    attribute :completed_at, :utc_datetime_usec do
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
    belongs_to :audit_schedule, Skopos.Audits.AuditSchedule do
      allow_nil? false
      public? true
    end

    belongs_to :target, Skopos.Targets.Target do
      public? true
    end

    belongs_to :case, Skopos.Cases.Case do
      public? true
    end
  end

  identities do
    identity :unique_occurrence_target, [:audit_schedule_id, :scheduled_for, :target_key]
  end
end
