defmodule Skopos.Audits.AuditSchedule do
  use Ash.Resource,
    otp_app: :skopos,
    domain: Skopos.Audits,
    authorizers: [Ash.Policy.Authorizer],
    data_layer: AshPostgres.DataLayer

  @summary_fields ~w(id name timezone cron_expression report_language management_boundary_id active next_run_at revision inserted_at updated_at)a
  def summary_fields, do: @summary_fields

  postgres do
    table "audit_schedules"
    repo Skopos.Repo

    custom_indexes do
      index [:management_boundary_id]
      index [:active, :next_run_at]
    end

    check_constraints do
      check_constraint [:target_ids, :management_boundary_id],
                       "audit_schedules_one_scope",
                       check:
                         "(cardinality(target_ids) > 0 AND management_boundary_id IS NULL) OR " <>
                           "(cardinality(target_ids) = 0 AND management_boundary_id IS NOT NULL)",
                       message: "must select Target IDs or one management boundary"
    end
  end

  actions do
    defaults [:read]

    read :page do
      pagination keyset?: true, required?: true, default_limit: 50, max_page_size: 100
      prepare build(sort: [inserted_at: :desc, id: :desc])
    end

    read :summaries do
      argument :ids, {:array, :uuid}, constraints: [min_length: 1, max_length: 100]
      filter expr(is_nil(^arg(:ids)) or id in ^arg(:ids))
      pagination keyset?: true, required?: true, default_limit: 50, max_page_size: 100
      prepare build(select: @summary_fields, sort: [inserted_at: :desc, id: :desc])
    end

    create :create_record do
      argument :registration_id, :uuid, allow_nil?: false
      change set_attribute(:id, arg(:registration_id))

      accept [
        :name,
        :objective,
        :timezone,
        :cron_expression,
        :report_language,
        :target_ids,
        :management_boundary_id,
        :active,
        :next_run_at
      ]
    end

    update :advance_record do
      accept [:next_run_at]
      require_atomic? false
      argument :expected_revision, :integer, allow_nil?: false, constraints: [min: 1]
      filter expr(active == true)
      validate Skopos.Validations.CurrentRevision
      change optimistic_lock(:revision)
    end

    update :deactivate do
      accept []
      require_atomic? false
      argument :expected_revision, :integer, allow_nil?: false, constraints: [min: 1]
      filter expr(active == true)
      validate Skopos.Validations.CurrentRevision
      change set_attribute(:active, false)
      change optimistic_lock(:revision)
    end

    action :schedule, :struct do
      constraints instance_of: __MODULE__
      transaction? false

      argument :registration_id, :uuid, allow_nil?: false

      argument :name, :string,
        allow_nil?: false,
        constraints: [min_length: 1, max_length: 120]

      argument :objective, :string,
        allow_nil?: false,
        constraints: [min_length: 1, max_length: 2_000]

      argument :timezone, :string,
        allow_nil?: false,
        constraints: [min_length: 1, max_length: 120]

      argument :cron_expression, :string,
        allow_nil?: false,
        constraints: [min_length: 1, max_length: 120]

      argument :report_language, :atom,
        allow_nil?: false,
        constraints: [one_of: [:en, :ja]]

      argument :target_ids, {:array, :uuid},
        allow_nil?: false,
        default: []

      argument :management_boundary_id, :uuid

      run Skopos.Audits.AuditSchedule.Actions.Create
    end

    action :wake, :struct do
      constraints instance_of: __MODULE__
      transaction? false
      argument :id, :uuid, allow_nil?: false
      argument :expected_revision, :integer, allow_nil?: false, constraints: [min: 1]
      argument :scheduled_for, :utc_datetime_usec, allow_nil?: false
      run Skopos.Audits.AuditSchedule.Actions.Wake
    end
  end

  policies do
    policy action([:schedule, :deactivate]) do
      authorize_if actor_attribute_equals(:role, :admin)
    end

    policy action([:create_record, :advance_record, :wake]) do
      forbid_if always()
    end

    policy action([:read, :page, :summaries]) do
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

    attribute :objective, :string do
      allow_nil? false
      public? true
      constraints min_length: 1, max_length: 2_000
    end

    attribute :timezone, :string do
      allow_nil? false
      public? true
      constraints min_length: 1, max_length: 120
    end

    attribute :cron_expression, :string do
      allow_nil? false
      public? true
      constraints min_length: 1, max_length: 120
    end

    attribute :report_language, :atom do
      allow_nil? false
      public? true
      constraints one_of: [:en, :ja]
    end

    attribute :target_ids, {:array, :uuid} do
      allow_nil? false
      public? true
      default []
    end

    attribute :active, :boolean do
      allow_nil? false
      public? true
      default true
    end

    attribute :next_run_at, :utc_datetime_usec do
      allow_nil? false
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
    belongs_to :management_boundary, Skopos.Targets.ManagementBoundary do
      public? true
    end

    has_many :runs, Skopos.Audits.AuditRun
  end

  identities do
    identity :unique_name, [:name]
  end
end
