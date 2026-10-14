defmodule SkoposWeb.SignalWebhookControllerTest do
  use SkoposWeb.ConnCase, async: false

  import OpenApiSpex.TestAssertions

  alias Skopos.{Accounts, Cases, Providers, Signals, Targets}
  alias Skopos.Cases.Case.Realtime

  @password "correct horse battery staple"
  @secret "monitoring-webhook-secret"

  setup do
    admin =
      Accounts.bootstrap!("signal-webhook-admin@example.com", @password, @password,
        authorize?: true
      )

    alertmanager = provider!(admin, "alertmanager", "alertmanager-webhook")
    generic = provider!(admin, "generic", "generic-webhook")
    zabbix = provider!(admin, "zabbix", "zabbix-webhook", %{"timezone" => "Asia/Tokyo"})

    %{admin: admin, alertmanager: alertmanager, generic: generic, zabbix: zabbix}
  end

  test "Generic webhook authenticates canonical firing and recovery into one Case", context do
    target =
      Targets.create_target!("generic-linux", "host", "linux", %{}, nil, actor: context.admin)

    Targets.create_external_identity!(target.id, "generic", "hostname", "generic-linux",
      actor: context.admin
    )

    path = "/api/v1/signals/generic/#{context.generic.id}"
    occurred_at = DateTime.utc_now()
    firing = generic_payload(occurred_at, "firing")

    first = context.conn |> authorized() |> post_json(path, firing)
    replay = build_conn() |> authorized() |> post_json(path, firing)
    [incident] = Cases.list_cases!(actor: context.admin)
    incident_id = incident.id
    :ok = Realtime.subscribe(incident_id)

    recovered =
      build_conn()
      |> authorized()
      |> post_json(path, generic_payload(DateTime.add(occurred_at, 10, :second), "recovered"))

    assert_receive {:case_changed, ^incident_id}

    assert json_response(first, 202)["receipt_id"] == json_response(replay, 202)["receipt_id"]
    assert response(recovered, 202)
    assert_operation_response(first)
    assert_operation_response(recovered)

    assert length(Signals.list_signal_receipts!(actor: context.admin)) == 2
    assert incident.initial_target_id == target.id

    events = Signals.list_signal_events!(actor: context.admin) |> Enum.sort_by(& &1.occurred_at)

    assert Enum.map(events, &{&1.event_key, &1.state, &1.case_id, &1.target_id}) == [
             {"service-unavailable", :firing, incident.id, target.id},
             {"service-unavailable", :recovered, incident.id, target.id}
           ]

    assert hd(events).attributes["facts"] == %{"service" => "nginx"}
    [condition] = Signals.list_conditions!(actor: context.admin)
    assert condition.state == :recovered
    assert condition.target_id == target.id
    assert Enum.all?(events, &(&1.condition_id == condition.id))
  end

  test "arbitrary Generic and Zabbix symptoms reach separate Resolver turns", context do
    current = Cases.current_authority_setting!(actor: context.admin)

    Cases.configure_authority_setting!(
      current.setting_revision,
      current.authority_mode,
      true,
      current.max_elapsed_seconds,
      current.max_resolver_turns,
      current.max_target_requests,
      current.max_effects,
      current.max_related_targets,
      current.max_ai_usage_units,
      current.max_no_progress_turns,
      "Exercise native arbitrary sources",
      actor: context.admin
    )

    original_window = Application.fetch_env!(:skopos, :case_collect_seconds)
    Application.put_env(:skopos, :case_collect_seconds, 0)
    on_exit(fn -> Application.put_env(:skopos, :case_collect_seconds, original_window) end)

    generic =
      generic_payload(DateTime.utc_now(), "firing")
      |> Map.merge(%{
        "event_key" => "uncatalogued-vibration",
        "title" => "Uncatalogued vibration pattern"
      })

    zabbix =
      zabbix_payload("1", "1726650000")
      |> Map.merge(%{"event_id" => "9009", "event_name" => "Unexpected optical attenuation"})

    assert response(
             context.conn
             |> authorized()
             |> post_json("/api/v1/signals/generic/#{context.generic.id}", generic),
             202
           )

    assert response(
             build_conn()
             |> authorized()
             |> post_json("/api/v1/signals/zabbix/#{context.zabbix.id}", zabbix),
             202
           )

    cases = Cases.list_cases!(actor: context.admin)
    assert length(cases) == 2

    for incident <- cases do
      assert [membership] = Cases.active_conditions_for_case!(incident.id, authorize?: false)
      assert membership.case_id == incident.id

      assert :ok =
               Skopos.Cases.CaseDispatch.Worker.perform(%Oban.Job{
                 args: %{"case_id" => incident.id}
               })
    end

    assert length(Cases.list_turns!(actor: context.admin)) == 2

    assert Enum.sort(Enum.map(Signals.list_conditions!(actor: context.admin), & &1.predicate)) ==
             ["UnclassifiedSignal", "UnclassifiedSignal"]
  end

  test "Generic webhook rejects malformed canonical fields and wrong credentials", context do
    path = "/api/v1/signals/generic/#{context.generic.id}"
    valid = generic_payload(DateTime.utc_now(), "firing")

    unauthorized =
      context.conn
      |> put_req_header("authorization", "Bearer wrong-secret-value")
      |> post_json(path, valid)

    assert json_response(unauthorized, 401)["errors"]["detail"] ==
             "Webhook authentication failed"

    for invalid <- [
          Map.put(valid, "state", "resolved"),
          Map.put(valid, "occurred_at", "yesterday"),
          Map.put(valid, "target_ref", %{"kind" => "hostname"}),
          Map.put(valid, "facts", %{"nested" => %{"unsafe" => true}}),
          Map.put(valid, "unknown", "field"),
          Map.delete(valid, "event_key")
        ] do
      rejected = build_conn() |> authorized() |> post_json(path, invalid)
      assert rejected.status in [400, 422]
      if rejected.status == 422, do: assert_operation_response(rejected)
    end

    wrong_adapter =
      build_conn()
      |> authorized()
      |> post_json("/api/v1/signals/zabbix/#{context.generic.id}", valid)

    assert response(wrong_adapter, 404)
    assert Signals.list_signal_receipts!(actor: context.admin) == []
    assert Cases.list_cases!(actor: context.admin) == []
  end

  test "Alertmanager authenticates and splits one group into source events", context do
    conn =
      context.conn
      |> authorized()
      |> post_json(
        "/api/v1/signals/alertmanager/#{context.alertmanager.id}",
        alertmanager_payload()
      )

    assert %{"receipt_id" => receipt_id} = json_response(conn, 202)
    assert is_binary(receipt_id)
    assert_operation_response(conn)

    receipts = Signals.list_signal_receipts!(actor: context.admin)
    events = Signals.list_signal_events!(actor: context.admin)

    assert length(receipts) == 1

    assert Enum.map(events, &{&1.event_key, &1.state}) |> Enum.sort() == [
             {"fingerprint-a", :firing},
             {"fingerprint-b", :recovered}
           ]

    firing = Enum.find(events, &(&1.event_key == "fingerprint-a"))
    [condition] = Signals.list_conditions!(actor: context.admin)
    assert condition.state == :firing
    assert condition.predicate == "DiskErrors"
    assert firing.condition_id == condition.id
    assert firing.target_ref == %{"kind" => "instance", "value" => "server-a:9100"}

    assert firing.attributes["labels"] == %{
             "alertname" => "DiskErrors",
             "instance" => "server-a:9100",
             "severity" => "critical"
           }

    assert firing.attributes["annotations"] == %{"summary" => "Disk errors increased"}
    assert firing.metadata["alertmanager"]["truncated_alerts"] == 0
    assert firing.metadata["alertmanager"]["common_labels"] == %{"service" => "storage"}
    assert firing.metadata["alert"]["generator_url"] == "http://prometheus:9090/graph"
  end

  test "an exact Alertmanager retry returns accepted without duplicating persistence", context do
    path = "/api/v1/signals/alertmanager/#{context.alertmanager.id}"
    payload = alertmanager_payload()

    first = context.conn |> authorized() |> post_json(path, payload)
    second = build_conn() |> authorized() |> post_json(path, payload)

    assert json_response(first, 202)["receipt_id"] == json_response(second, 202)["receipt_id"]
    assert length(Signals.list_signal_receipts!(actor: context.admin)) == 1
    assert length(Signals.list_signal_events!(actor: context.admin)) == 2
  end

  test "Alertmanager fingerprint rotation cannot recover a newer firing condition", context do
    path = "/api/v1/signals/alertmanager/#{context.alertmanager.id}"
    [old_alert | _] = alertmanager_payload()["alerts"]
    new_alert = %{old_alert | "fingerprint" => "fingerprint-new"}

    for alert <- [old_alert, new_alert] do
      payload = %{alertmanager_payload() | "alerts" => [alert]}
      assert response(build_conn() |> authorized() |> post_json(path, payload), 202)
    end

    recovered_old = %{
      old_alert
      | "status" => "resolved",
        "endsAt" => "2026-09-18T01:02:00Z"
    }

    payload = %{alertmanager_payload() | "alerts" => [recovered_old], "status" => "resolved"}
    assert response(build_conn() |> authorized() |> post_json(path, payload), 202)

    correlations = Signals.list_signal_correlations!(actor: context.admin)
    conditions = Signals.list_conditions!(actor: context.admin)
    old_correlation = Enum.find(correlations, &(&1.event_key == "fingerprint-a"))
    new_correlation = Enum.find(correlations, &(&1.event_key == "fingerprint-new"))

    assert Enum.find(conditions, &(&1.signal_correlation_id == old_correlation.id)).state ==
             :recovered

    assert Enum.find(conditions, &(&1.signal_correlation_id == new_correlation.id)).state ==
             :firing
  end

  test "authentication runs before Alertmanager body normalization", context do
    conn =
      context.conn
      |> put_req_header("authorization", "Bearer wrong-secret-value")
      |> post_json("/api/v1/signals/alertmanager/#{context.alertmanager.id}", %{"invalid" => true})

    assert json_response(conn, 401) == %{
             "errors" => %{"detail" => "Webhook authentication failed"}
           }

    assert_operation_response(conn)

    assert Signals.list_signal_receipts!(actor: context.admin) == []
  end

  test "authenticated malformed Alertmanager facts are rejected without persistence", context do
    payload = alertmanager_payload() |> put_in(["alerts", Access.at(0), "startsAt"], "invalid")

    conn =
      context.conn
      |> authorized()
      |> post_json("/api/v1/signals/alertmanager/#{context.alertmanager.id}", payload)

    assert json_response(conn, 422) == %{
             "errors" => %{"detail" => "Alertmanager timestamp is invalid"}
           }

    assert_operation_response(conn)

    assert Signals.list_signal_receipts!(actor: context.admin) == []
  end

  test "malformed JSON never reaches Signal persistence", context do
    assert_error_sent 400, fn ->
      context.conn
      |> authorized()
      |> put_req_header("content-type", "application/json")
      |> post("/api/v1/signals/alertmanager/#{context.alertmanager.id}", "{invalid")
    end

    assert Signals.list_signal_receipts!(actor: context.admin) == []
  end

  test "Zabbix problem and recovery retain one source event identity and host reference",
       context do
    path = "/api/v1/signals/zabbix/#{context.zabbix.id}"

    firing =
      context.conn
      |> authorized()
      |> post_json(path, zabbix_payload("1", "1726650000"))

    recovery =
      build_conn()
      |> authorized()
      |> post_json(path, zabbix_payload("0", "1726650060"))

    assert response(firing, 202)
    assert response(recovery, 202)
    assert_operation_response(firing)
    assert_operation_response(recovery)

    events = Signals.list_signal_events!(actor: context.admin) |> Enum.sort_by(& &1.occurred_at)

    assert Enum.map(events, &{&1.event_key, &1.state, &1.source_sequence}) == [
             {"9001", :firing, "1726650000"},
             {"9001", :recovered, "1726650060"}
           ]

    [condition] = Signals.list_conditions!(actor: context.admin)
    assert condition.state == :recovered
    assert Enum.all?(events, &(&1.condition_id == condition.id))

    assert Enum.all?(events, fn event ->
             event.target_ref == %{"kind" => "host_id", "value" => "10601"}
           end)

    assert hd(events).attributes == %{
             "severity" => "error",
             "title" => "Linux disk I/O errors"
           }

    assert hd(events).metadata["zabbix"]["event_name"] == "Linux disk I/O errors"
  end

  test "Zabbix 7.0 date and time facts use the configured source timezone", context do
    payload =
      zabbix_payload("1", "")
      |> Map.put("event_timestamp", "{EVENT.TIMESTAMP}")
      |> Map.put("event_date", "2026.09.18")
      |> Map.put("event_time", "13:40:00")

    conn =
      context.conn
      |> authorized()
      |> post_json("/api/v1/signals/zabbix/#{context.zabbix.id}", payload)

    assert response(conn, 202)
    [event] = Signals.list_signal_events!(actor: context.admin)
    assert DateTime.compare(event.occurred_at, ~U[2026-09-18 04:40:00Z]) == :eq
    assert event.source_sequence == "1789706400"
  end

  test "source-specific endpoints reject a provider for the other adapter", context do
    conn =
      context.conn
      |> authorized()
      |> post_json(
        "/api/v1/signals/zabbix/#{context.alertmanager.id}",
        zabbix_payload("1", "1726650000")
      )

    assert json_response(conn, 404) == %{
             "errors" => %{"detail" => "Signal endpoint was not found"}
           }

    assert_operation_response(conn)

    assert Signals.list_signal_receipts!(actor: context.admin) == []
  end

  test "webhook contract rejects a malformed Provider identifier", context do
    conn =
      context.conn
      |> authorized()
      |> post_json("/api/v1/signals/zabbix/not-a-uuid", zabbix_payload("1", "1726650000"))

    assert %{
             "error" => %{
               "code" => "validation_failed",
               "details" => %{"fields" => ["provider_id"]}
             }
           } = json_response(conn, 422)

    assert_operation_response(conn)
    assert Signals.list_signal_receipts!(actor: context.admin) == []
  end

  defp provider!(admin, name, adapter_type, configuration \\ %{}) do
    Providers.create_provider!(
      name,
      :signal,
      adapter_type,
      Map.put(configuration, "source", name),
      %{"secret" => @secret},
      actor: admin
    )
    |> then(&Providers.check_provider!(&1.id, &1.revision, %{}, actor: admin))
    |> then(&Providers.enable_provider!(&1, &1.revision, actor: admin))
  end

  defp authorized(conn) do
    put_req_header(conn, "authorization", "Bearer #{@secret}")
  end

  defp generic_payload(occurred_at, state) do
    %{
      "event_key" => "service-unavailable",
      "state" => state,
      "occurred_at" => DateTime.to_iso8601(occurred_at),
      "title" => "Nginx is unavailable",
      "severity" => "error",
      "target_ref" => %{"kind" => "hostname", "value" => "generic-linux"},
      "facts" => %{"service" => "nginx"}
    }
  end

  defp post_json(conn, path, payload) do
    conn
    |> put_req_header("content-type", "application/json")
    |> post(path, Jason.encode!(payload))
  end

  defp alertmanager_payload do
    %{
      "version" => "4",
      "groupKey" => "{}:{alertname=\"DiskErrors\"}",
      "truncatedAlerts" => 0,
      "status" => "firing",
      "receiver" => "skopos",
      "groupLabels" => %{"alertname" => "DiskErrors"},
      "commonLabels" => %{"service" => "storage"},
      "commonAnnotations" => %{},
      "externalURL" => "http://alertmanager:9093",
      "alerts" => [
        %{
          "status" => "firing",
          "labels" => %{
            "alertname" => "DiskErrors",
            "instance" => "server-a:9100",
            "severity" => "critical"
          },
          "annotations" => %{"summary" => "Disk errors increased"},
          "startsAt" => "2026-09-18T01:00:00Z",
          "endsAt" => "0001-01-01T00:00:00Z",
          "generatorURL" => "http://prometheus:9090/graph",
          "fingerprint" => "fingerprint-a"
        },
        %{
          "status" => "resolved",
          "labels" => %{"alertname" => "LinkDown", "instance" => "switch-a"},
          "annotations" => %{"summary" => "Link recovered"},
          "startsAt" => "2026-09-18T00:50:00Z",
          "endsAt" => "2026-09-18T01:01:00Z",
          "generatorURL" => "http://prometheus:9090/graph",
          "fingerprint" => "fingerprint-b"
        }
      ]
    }
  end

  defp zabbix_payload(event_value, timestamp) do
    %{
      "event_id" => "9001",
      "event_value" => event_value,
      "event_timestamp" => "1726650000",
      "event_date" => "2024.09.18",
      "event_time" => "09:00:00",
      "recovery_timestamp" => if(event_value == "0", do: timestamp, else: ""),
      "recovery_date" => if(event_value == "0", do: "2024.09.18", else: ""),
      "recovery_time" => if(event_value == "0", do: "09:01:00", else: ""),
      "update_timestamp" => "",
      "host_id" => "10601",
      "host" => "linux-a",
      "host_name" => "Linux A",
      "trigger_id" => "21001",
      "event_name" => "Linux disk I/O errors",
      "severity" => "High",
      "severity_number" => "4",
      "tags" => [%{"tag" => "service", "value" => "storage"}]
    }
  end
end
