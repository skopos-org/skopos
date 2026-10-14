defmodule Skopos.NotificationDeliveryTest do
  use Skopos.DataCase, async: false

  import Ecto.Query

  alias Skopos.{Accounts, Cases, Notifications, Providers, Reports}
  alias Skopos.Notifications.Delivery.{Dispatch, DispatchWorker}
  alias Skopos.Providers.Notification
  alias Skopos.Reports.Report.Document

  @password "correct horse battery staple"

  setup do
    admin =
      Accounts.bootstrap!("delivery-admin@example.com", @password, @password, authorize?: true)

    operator =
      Accounts.create_user!("delivery-operator@example.com", @password, :operator, actor: admin)

    viewer =
      Accounts.create_user!("delivery-viewer@example.com", @password, :viewer, actor: admin)

    provider =
      Providers.create_provider!(
        "delivery-provider",
        :notification,
        "fixture-notification",
        %{"destination" => "test-webhook"},
        %{"token" => "delivery-secret"},
        actor: admin
      )
      |> then(&Providers.check_provider!(&1.id, 1, %{}, actor: admin))
      |> then(&Providers.enable_provider!(&1, 1, actor: admin))

    report = report!(operator)

    %{admin: admin, operator: operator, viewer: viewer, provider: provider, report: report}
  end

  test "enqueue durably binds one Report and Notification Provider revision", context do
    delivery = enqueue!(context, "delivery-one")

    assert delivery.status == :queued
    assert delivery.report_id == context.report.id
    assert delivery.report_revision == context.report.revision
    assert delivery.provider_id == context.provider.id
    assert delivery.provider_revision == context.provider.revision
    assert delivery.destination_id == context.provider.id
    assert delivery.destination_revision == context.provider.revision
    assert delivery_jobs(delivery.id) == 1

    retried = enqueue!(context, "delivery-one")
    assert retried.id == delivery.id
    assert delivery_jobs(delivery.id) == 1

    assert {:error, _error} =
             Notifications.enqueue_delivery(
               context.report.id,
               context.report.revision,
               context.provider.id,
               context.provider.revision + 1,
               "delivery-one",
               actor: context.operator
             )

    assert {:error, %Ash.Error.Forbidden{}} =
             Notifications.enqueue_delivery(
               context.report.id,
               context.report.revision,
               context.provider.id,
               context.provider.revision,
               "viewer-delivery",
               actor: context.viewer
             )
  end

  test "one claimed dispatch persists every typed remote outcome", context do
    for status <- [:accepted, :delivered, :failed, :unknown] do
      delivery = enqueue!(context, "delivery-#{status}")

      assert {:ok, terminal} =
               Dispatch.run(
                 delivery.id,
                 invocation(%Notification.Result{
                   status: status,
                   reference: "remote-#{status}",
                   details: %{"status" => to_string(status)}
                 })
               )

      assert terminal.status == status
      assert terminal.reference == "remote-#{status}"
      assert terminal.details == %{"status" => to_string(status)}
      assert terminal.revision == 3

      assert_receive {:delivery, %{token: "delivery-secret"}, request}
      assert request.report_id == context.report.id
      assert request.report_revision == context.report.revision
      assert request.destination_id == context.provider.id
      assert request.destination_revision == context.provider.revision
      assert request.idempotency_key == "delivery-#{status}"
      assert request.payload == Document.build(context.report)
      assert request.payload["text"] =~ "Notification delivery report"
      refute_receive {:delivery, _, _}

      job =
        Skopos.Repo.one!(
          from(job in Oban.Job,
            where:
              job.worker == ^Oban.Worker.to_string(DispatchWorker) and
                fragment("?->>'delivery_id'", job.args) == ^delivery.id
          )
        )

      assert :ok = DispatchWorker.perform(job)
      refute_receive {:delivery, _, _}
    end
  end

  test "lost dispatch ownership becomes unknown without a blind resend", context do
    delivery = enqueue!(context, "delivery-interrupted")

    assert {:ok, %{state: :claimed, delivery: dispatching}} =
             Notifications.claim_delivery_dispatch(delivery.id, authorize?: false)

    assert dispatching.status == :dispatching

    assert {:ok, unknown} =
             Dispatch.run(
               delivery.id,
               invocation(%Notification.Result{status: :delivered})
             )

    assert unknown.status == :unknown
    assert unknown.details["message"] =~ "ownership was lost"
    refute_receive {:delivery, _, _}
    assert delivery_jobs(delivery.id) == 1

    explicit_retry = enqueue!(context, "delivery-explicit-retry")
    refute explicit_retry.id == delivery.id
    assert explicit_retry.status == :queued
    assert delivery_jobs(explicit_retry.id) == 1
  end

  test "timeout is unknown, while a stale Provider fails before send and keeps the Report",
       context do
    timed = enqueue!(context, "delivery-timeout")

    assert {:ok, timed_out} =
             Dispatch.run(timed.id, %{
               test_pid: self(),
               respond: fn -> {:error, :timeout, "remote response was lost"} end
             })

    assert timed_out.status == :unknown
    assert_receive {:delivery, _, _}

    stale = enqueue!(context, "delivery-stale")

    Providers.disable_provider!(context.provider, context.provider.revision, actor: context.admin)

    assert {:ok, failed} =
             Dispatch.run(
               stale.id,
               invocation(%Notification.Result{status: :delivered})
             )

    assert failed.status == :failed
    assert failed.details == %{"message" => "Notification Provider rejected delivery"}
    refute_receive {:delivery, _, _}

    assert Reports.get_report!(context.report.id, actor: context.viewer).content ==
             context.report.content
  end

  defp report!(operator) do
    incident =
      Cases.open_case!(
        :manual,
        "test",
        "notification-delivery-report",
        "Notification delivery report",
        :warning,
        %{"summary" => "service recovered", "desired_outcome" => "Target responds as expected"},
        nil,
        :en,
        actor: operator
      )

    resolved =
      Cases.record_case_resolution!(incident, incident.revision, DateTime.utc_now(),
        authorize?: false
      )

    Reports.generate_report!(resolved.id, resolved.revision, actor: operator)
  end

  defp enqueue!(context, key) do
    Notifications.enqueue_delivery!(
      context.report.id,
      context.report.revision,
      context.provider.id,
      context.provider.revision,
      key,
      actor: context.operator
    )
  end

  defp invocation(result) do
    %{test_pid: self(), respond: fn -> {:ok, result} end}
  end

  defp delivery_jobs(delivery_id) do
    Skopos.Repo.aggregate(
      from(job in Oban.Job,
        where:
          job.worker == ^Oban.Worker.to_string(DispatchWorker) and
            fragment("?->>'delivery_id'", job.args) == ^delivery_id
      ),
      :count
    )
  end
end
