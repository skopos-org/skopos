defmodule Skopos.Notifications.Delivery.Dispatch do
  @moduledoc false

  alias Skopos.{Notifications, Providers, Reports}
  alias Skopos.Notifications.Delivery.DispatchClaim
  alias Skopos.Providers.Notification
  alias Skopos.Reports.Report.Document

  def run(delivery_id, invocation \\ %{}) do
    case Notifications.claim_delivery_dispatch(delivery_id, authorize?: false) do
      {:ok, %DispatchClaim{state: :claimed, delivery: delivery}} ->
        dispatch(delivery, invocation)

      {:ok, %DispatchClaim{state: :terminal, delivery: delivery}} ->
        {:ok, delivery}

      {:error, error} ->
        {:error, error}
    end
  end

  defp dispatch(delivery, invocation) do
    with {:ok, report} <- Reports.get_report(delivery.report_id, authorize?: false) do
      request = %Notification.Request{
        provider_revision: delivery.provider_revision,
        report_id: report.id,
        report_revision: report.revision,
        destination_id: delivery.destination_id,
        destination_revision: delivery.destination_revision,
        idempotency_key: delivery.idempotency_key,
        payload: Document.build(report)
      }

      outcome =
        case Providers.notification_deliver(
               delivery.provider_id,
               request,
               invocation,
               authorize?: false
             ) do
          {:ok, %Notification.Result{} = result} ->
            %{
              status: result.status,
              reference: result.reference,
              details: result.details
            }

          {:error, _error} ->
            %{
              status: :failed,
              reference: nil,
              details: %{"message" => "Notification Provider rejected delivery"}
            }
        end

      Notifications.record_delivery_outcome(
        delivery,
        delivery.revision,
        Map.put(outcome, :completed_at, DateTime.utc_now()),
        authorize?: false
      )
    end
  end
end
