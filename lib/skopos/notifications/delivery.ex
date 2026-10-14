defmodule Skopos.Notifications.Delivery do
  use Ash.Resource,
    otp_app: :skopos,
    domain: Skopos.Notifications,
    authorizers: [Ash.Policy.Authorizer],
    data_layer: AshPostgres.DataLayer

  @summary_fields ~w(id report_id report_revision provider_id provider_revision destination_id destination_revision status reference enqueued_at dispatch_started_at completed_at revision)a

  def summary_fields, do: @summary_fields

  postgres do
    table "deliveries"
    repo Skopos.Repo

    custom_indexes do
      index [:report_id]
      index [:provider_id]
      index [:status]
    end
  end

  actions do
    defaults [:read]

    read :page do
      pagination keyset?: true, required?: true, default_limit: 50, max_page_size: 100
      prepare build(sort: [enqueued_at: :desc, id: :desc])
    end

    read :summaries do
      argument :report_ids, {:array, :uuid}, constraints: [min_length: 1, max_length: 100]
      filter expr(is_nil(^arg(:report_ids)) or report_id in ^arg(:report_ids))
      pagination keyset?: true, required?: true, default_limit: 50, max_page_size: 100
      prepare build(select: @summary_fields, sort: [enqueued_at: :desc, id: :desc])
    end

    read :latest_for_reports do
      argument :report_ids, {:array, :uuid},
        allow_nil?: false,
        constraints: [min_length: 1, max_length: 100]

      filter expr(report_id in ^arg(:report_ids))

      prepare build(
                select: @summary_fields,
                distinct: [:report_id],
                distinct_sort: [report_id: :asc, enqueued_at: :desc, id: :desc],
                sort: [report_id: :asc],
                limit: 100
              )

      prepare fn query, context ->
        Ash.Query.after_action(query, fn _query, deliveries ->
          counts =
            __MODULE__ |> Ash.Query.select(@summary_fields) |> Ash.Query.load(:attempt_count)

          Ash.load(deliveries, counts, actor: context.actor)
        end)
      end
    end

    read :summary_by_request do
      get? true

      argument :idempotency_key, :string,
        allow_nil?: false,
        sensitive?: true,
        constraints: [min_length: 1, max_length: 1_024]

      filter expr(idempotency_key == ^arg(:idempotency_key))
      prepare build(select: @summary_fields)
    end

    read :by_idempotency do
      get? true
      argument :idempotency_key, :string, allow_nil?: false, constraints: [min_length: 1]
      filter expr(idempotency_key == ^arg(:idempotency_key))
    end

    create :create_record do
      accept [
        :report_id,
        :report_revision,
        :provider_id,
        :provider_revision,
        :destination_id,
        :destination_revision,
        :idempotency_key,
        :status,
        :details,
        :enqueued_at
      ]

      validate {Skopos.Validations.BoundedMap,
                attribute: :details, max_fields: 100, max_bytes: 1_048_576}
    end

    update :mark_dispatching do
      accept [:dispatch_started_at]
      require_atomic? false
      argument :expected_revision, :integer, allow_nil?: false, constraints: [min: 1]
      filter expr(status == :queued)
      validate Skopos.Validations.CurrentRevision
      change set_attribute(:status, :dispatching)
      change optimistic_lock(:revision)
    end

    update :record_outcome do
      accept [:status, :reference, :details, :completed_at]
      require_atomic? false
      argument :expected_revision, :integer, allow_nil?: false, constraints: [min: 1]
      filter expr(status == :dispatching)
      validate Skopos.Validations.CurrentRevision
      validate attribute_in(:status, [:accepted, :delivered, :failed, :unknown])
      validate present(:completed_at)

      validate {Skopos.Validations.BoundedMap,
                attribute: :details, max_fields: 100, max_bytes: 1_048_576}

      change optimistic_lock(:revision)
    end

    action :enqueue, :struct do
      constraints instance_of: __MODULE__
      transaction? false
      argument :report_id, :uuid, allow_nil?: false
      argument :report_revision, :integer, allow_nil?: false, constraints: [min: 1]
      argument :provider_id, :uuid, allow_nil?: false
      argument :provider_revision, :integer, allow_nil?: false, constraints: [min: 1]

      argument :idempotency_key, :string,
        allow_nil?: false,
        constraints: [min_length: 1, max_length: 1_024]

      run Skopos.Notifications.Delivery.Actions.Enqueue
    end

    action :claim_dispatch, :struct do
      constraints instance_of: Skopos.Notifications.Delivery.DispatchClaim
      transaction? false
      argument :id, :uuid, allow_nil?: false
      run Skopos.Notifications.Delivery.Actions.ClaimDispatch
    end
  end

  policies do
    policy action(:enqueue) do
      authorize_if actor_attribute_equals(:role, :admin)
      authorize_if actor_attribute_equals(:role, :operator)
    end

    policy action([
             :by_idempotency,
             :create_record,
             :mark_dispatching,
             :record_outcome,
             :claim_dispatch
           ]) do
      forbid_if always()
    end

    policy action([:read, :page, :summaries, :latest_for_reports, :summary_by_request]) do
      authorize_if actor_attribute_equals(:role, :admin)
      authorize_if actor_attribute_equals(:role, :operator)
      authorize_if actor_attribute_equals(:role, :viewer)
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :report_revision, :integer do
      allow_nil? false
      public? true
      constraints min: 1
    end

    attribute :provider_revision, :integer do
      allow_nil? false
      public? true
      constraints min: 1
    end

    attribute :destination_id, :uuid do
      allow_nil? false
      public? true
    end

    attribute :destination_revision, :integer do
      allow_nil? false
      public? true
      constraints min: 1
    end

    attribute :idempotency_key, :string do
      allow_nil? false
      public? true
      constraints min_length: 1, max_length: 1_024
    end

    attribute :status, :atom do
      allow_nil? false
      public? true
      constraints one_of: [:queued, :dispatching, :accepted, :delivered, :failed, :unknown]
    end

    attribute :reference, :string do
      public? true
      constraints min_length: 1, max_length: 1_024
    end

    attribute :details, :map do
      allow_nil? false
      public? true
      default %{}
    end

    attribute :enqueued_at, :utc_datetime_usec do
      allow_nil? false
      public? true
    end

    attribute :dispatch_started_at, :utc_datetime_usec do
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
  end

  relationships do
    belongs_to :report, Skopos.Reports.Report do
      allow_nil? false
      public? true
    end

    belongs_to :provider, Skopos.Providers.Provider do
      allow_nil? false
      public? true
    end
  end

  aggregates do
    count :attempt_count, __MODULE__ do
      filter expr(report_id == parent(report_id))
    end
  end

  identities do
    identity :unique_idempotency, [:idempotency_key]
  end
end
