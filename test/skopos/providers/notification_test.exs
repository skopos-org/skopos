defmodule Skopos.Providers.NotificationTest do
  use Skopos.DataCase, async: false

  alias Skopos.Accounts
  alias Skopos.Providers
  alias Skopos.Providers.Notification

  @password "correct horse battery staple"
  @token "notification-provider-secret"

  setup do
    admin =
      Accounts.bootstrap!("notification-admin@example.com", @password, @password,
        authorize?: true
      )

    provider =
      Providers.create_provider!(
        "notification-provider",
        :notification,
        "fixture-notification",
        %{"destination" => "test-webhook"},
        %{"token" => @token},
        actor: admin
      )
      |> then(&Providers.check_provider!(&1.id, 1, %{}, actor: admin))
      |> then(&Providers.enable_provider!(&1, 1, actor: admin))

    %{admin: admin, provider: provider}
  end

  test "one dispatch preserves all remote statuses and redacts output", context do
    for status <- [:accepted, :delivered, :failed, :unknown] do
      request = request(context.provider.revision, "delivery-#{status}")

      result = %Notification.Result{
        status: status,
        details: %{response: @token}
      }

      assert %Notification.Result{status: ^status, details: %{response: "[REDACTED]"}} =
               deliver!(context, request, fn -> {:ok, result} end)

      assert_receive {:delivery, %{token: @token}, ^request}
      refute_receive {:delivery, _, _}
    end
  end

  test "timeout and callback loss after dispatch remain unknown", context do
    timeout_request = request(context.provider.revision, "delivery-timeout")

    assert %Notification.Result{status: :unknown, details: %{error: timeout_message}} =
             deliver!(context, timeout_request, fn ->
               {:error, :timeout, "timeout with #{@token}"}
             end)

    assert timeout_message == "timeout with [REDACTED]"
    assert_receive {:delivery, %{token: @token}, ^timeout_request}
    refute_receive {:delivery, _, _}

    raised_request = request(context.provider.revision, "delivery-lost-response")

    assert %Notification.Result{status: :unknown, details: %{error: raised_message}} =
             deliver!(context, raised_request, fn -> raise "lost #{@token}" end)

    assert raised_message == "lost [REDACTED]"
    assert_receive {:delivery, %{token: @token}, ^raised_request}
    refute_receive {:delivery, _, _}
  end

  test "caller retries retain the same immutable idempotency key", context do
    request = request(context.provider.revision, "delivery-retry")
    Process.put(:delivery_attempt, 0)

    respond = fn ->
      attempt = Process.get(:delivery_attempt, 0) + 1
      Process.put(:delivery_attempt, attempt)
      status = if attempt == 1, do: :unknown, else: :delivered
      {:ok, %Notification.Result{status: status, reference: "remote-1"}}
    end

    assert %Notification.Result{status: :unknown} = deliver!(context, request, respond)
    assert %Notification.Result{status: :delivered} = deliver!(context, request, respond)

    assert_receive {:delivery, %{token: @token}, ^request}
    assert_receive {:delivery, %{token: @token}, ^request}
    assert request.idempotency_key == "idempotency-delivery-retry"
  end

  test "pre-dispatch cancellation, stale revision and retryable errors cannot cause retries",
       context do
    cancelled = request(context.provider.revision, "delivery-cancelled")

    assert {:error, error} =
             Providers.notification_deliver(
               context.provider.id,
               cancelled,
               %{cancelled?: fn -> true end},
               actor: context.admin
             )

    assert notification_error(error).category == :cancelled
    refute_receive {:delivery, _, _}

    stale = request(context.provider.revision + 1, "delivery-stale")

    assert {:error, _error} =
             Providers.notification_deliver(
               context.provider.id,
               stale,
               %{test_pid: self(), respond: fn -> flunk("stale delivery dispatched") end},
               actor: context.admin
             )

    refute_receive {:delivery, _, _}

    invalid_retry = request(context.provider.revision, "delivery-invalid-retry")

    assert {:error, error} =
             Providers.notification_deliver(
               context.provider.id,
               invalid_retry,
               %{test_pid: self(), respond: fn -> {:error, :retryable, "unsafe retry"} end},
               actor: context.admin
             )

    assert notification_error(error).category == :failed
    assert notification_error(error).message == "Invalid notification result"
    assert_receive {:delivery, %{token: @token}, ^invalid_retry}
    refute_receive {:delivery, _, _}
  end

  test "request and result payloads are bounded", context do
    oversized = %{"payload" => String.duplicate("x", 1_048_577)}
    request = %{request(context.provider.revision, "delivery-oversized") | payload: oversized}

    assert {:error, request_error} =
             Providers.notification_deliver(
               context.provider.id,
               request,
               %{test_pid: self(), respond: fn -> flunk("oversized payload was dispatched") end},
               actor: context.admin
             )

    assert notification_error(request_error).message == "Notification request is invalid"
    refute_receive {:delivery, _, _}

    valid_request = request(context.provider.revision, "delivery-oversized-result")

    assert {:error, result_error} =
             Providers.notification_deliver(
               context.provider.id,
               valid_request,
               %{
                 test_pid: self(),
                 respond: fn ->
                   {:ok, %Notification.Result{status: :delivered, details: oversized}}
                 end
               },
               actor: context.admin
             )

    assert notification_error(result_error).message == "Invalid notification result"
    assert_receive {:delivery, %{token: @token}, ^valid_request}
    refute_receive {:delivery, _, _}
  end

  defp deliver!(context, request, respond) do
    Providers.notification_deliver!(
      context.provider.id,
      request,
      %{test_pid: self(), respond: respond},
      actor: context.admin
    )
  end

  defp request(provider_revision, delivery_id) do
    struct!(Notification.Request,
      provider_revision: provider_revision,
      report_id: "report-1",
      report_revision: 3,
      destination_id: "destination-1",
      destination_revision: 2,
      idempotency_key: "idempotency-#{delivery_id}",
      payload: %{delivery_id: delivery_id}
    )
  end

  defp notification_error(%{errors: errors}) do
    Enum.find_value(errors, fn
      %Notification.Error{} = error -> error
      nested when is_map(nested) -> notification_error(nested)
      _other -> nil
    end)
  end

  defp notification_error(_error), do: nil
end
