defmodule Skopos.Notifications do
  use Ash.Domain,
    otp_app: :skopos

  resources do
    resource Skopos.Notifications.Delivery do
      define :list_deliveries, action: :read
      define :page_deliveries, action: :page
      define :page_delivery_summaries, action: :summaries
      define :latest_deliveries_for_reports, action: :latest_for_reports, args: [:report_ids]

      define :delivery_summary_by_request,
        action: :summary_by_request,
        args: [:idempotency_key],
        get?: true

      define :get_delivery, action: :read, get_by: [:id]
      define :delivery_by_idempotency, action: :by_idempotency, args: [:idempotency_key]
      define :create_delivery_record, action: :create_record
      define :mark_delivery_dispatching, action: :mark_dispatching, args: [:expected_revision]
      define :record_delivery_outcome, action: :record_outcome, args: [:expected_revision]

      define :enqueue_delivery,
        action: :enqueue,
        args: [
          :report_id,
          :report_revision,
          :provider_id,
          :provider_revision,
          :idempotency_key
        ]

      define :claim_delivery_dispatch, action: :claim_dispatch, args: [:id]
    end
  end
end
