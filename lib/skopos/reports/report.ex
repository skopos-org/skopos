defmodule Skopos.Reports.Report do
  use Ash.Resource,
    otp_app: :skopos,
    domain: Skopos.Reports,
    authorizers: [Ash.Policy.Authorizer],
    simple_notifiers: [Skopos.Cases.Case.RealtimeNotifier],
    data_layer: AshPostgres.DataLayer

  @summary_fields ~w(id case_id case_revision language outcome content_digest generated_at revision)a
  @summary_calculations [:operation_count, :verification_count]

  def summary_fields, do: @summary_fields ++ @summary_calculations

  postgres do
    table "reports"
    repo Skopos.Repo

    custom_indexes do
      index [:case_id]
    end
  end

  actions do
    defaults [:read]

    read :page do
      argument :ids, {:array, :uuid}, constraints: [min_length: 1, max_length: 100]
      filter expr(is_nil(^arg(:ids)) or id in ^arg(:ids))
      pagination keyset?: true, required?: true, default_limit: 50, max_page_size: 100

      prepare build(
                select: @summary_fields,
                load: @summary_calculations,
                sort: [generated_at: :desc, id: :desc]
              )
    end

    read :by_case_revision do
      get? true
      argument :case_id, :uuid, allow_nil?: false
      argument :case_revision, :integer, allow_nil?: false, constraints: [min: 1]
      filter expr(case_id == ^arg(:case_id) and case_revision == ^arg(:case_revision))
    end

    read :summary_by_case_revision do
      get? true
      argument :case_id, :uuid, allow_nil?: false

      argument :case_revision, :integer,
        allow_nil?: false,
        constraints: [min: 1, max: 9_223_372_036_854_775_807]

      filter expr(case_id == ^arg(:case_id) and case_revision == ^arg(:case_revision))
      prepare build(select: @summary_fields, load: @summary_calculations)
    end

    read :summaries_for_case do
      argument :case_id, :uuid, allow_nil?: false
      filter expr(case_id == ^arg(:case_id))

      prepare build(
                select: @summary_fields,
                load: @summary_calculations,
                sort: [generated_at: :desc, id: :desc],
                limit: 100
              )
    end

    create :create_record do
      accept [
        :case_id,
        :case_revision,
        :language,
        :outcome,
        :content,
        :content_digest,
        :generated_at
      ]

      validate {Skopos.Validations.BoundedMap,
                attribute: :content, max_fields: 20, max_bytes: 10_485_760}
    end

    action :generate, :struct do
      constraints instance_of: __MODULE__
      transaction? false
      argument :case_id, :uuid, allow_nil?: false
      argument :expected_case_revision, :integer, allow_nil?: false, constraints: [min: 1]
      run Skopos.Reports.Report.Actions.Generate
    end

    action :period_summary, :map do
      transaction? false
      argument :from, :utc_datetime_usec, allow_nil?: false
      argument :to, :utc_datetime_usec, allow_nil?: false
      argument :target_id, :uuid
      run Skopos.Reports.Report.Actions.PeriodSummary
    end
  end

  policies do
    policy action([:by_case_revision, :create_record]) do
      forbid_if always()
    end

    policy action(:generate) do
      authorize_if actor_attribute_equals(:role, :admin)
      authorize_if actor_attribute_equals(:role, :operator)
    end

    policy action([:read, :page, :summary_by_case_revision, :summaries_for_case, :period_summary]) do
      authorize_if actor_attribute_equals(:role, :admin)
      authorize_if actor_attribute_equals(:role, :operator)
      authorize_if actor_attribute_equals(:role, :viewer)
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :case_revision, :integer do
      allow_nil? false
      public? true
      constraints min: 1
    end

    attribute :language, :atom do
      allow_nil? false
      public? true
      constraints one_of: [:en, :ja]
    end

    attribute :outcome, :atom do
      allow_nil? false
      public? true
      constraints one_of: [:resolved, :needs_attention, :cancelled]
    end

    attribute :content, :map do
      allow_nil? false
      public? true
    end

    attribute :content_digest, :string do
      allow_nil? false
      public? true
      constraints min_length: 64, max_length: 64
    end

    attribute :generated_at, :utc_datetime_usec do
      allow_nil? false
      public? true
    end

    attribute :revision, :integer do
      allow_nil? false
      public? true
      default 1
      constraints min: 1
    end
  end

  relationships do
    belongs_to :case, Skopos.Cases.Case do
      allow_nil? false
      public? true
    end
  end

  calculations do
    calculate :operation_count,
              :integer,
              expr(fragment("COALESCE(jsonb_array_length(? -> 'operations'), 0)", content))

    calculate :verification_count,
              :integer,
              expr(fragment("COALESCE(jsonb_array_length(? -> 'verifications'), 0)", content))
  end

  identities do
    identity :unique_case_revision, [:case_id, :case_revision]
  end
end
