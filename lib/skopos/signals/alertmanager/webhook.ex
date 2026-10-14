defmodule Skopos.Signals.Alertmanager.Webhook do
  @moduledoc false

  @behaviour Skopos.Providers.Adapter
  @behaviour Skopos.Providers.Signal

  alias Skopos.Providers.Signal
  alias Skopos.Signals.Webhook

  @impl Skopos.Providers.Adapter
  def type, do: "alertmanager-webhook"

  @impl Skopos.Providers.Adapter
  def kind, do: :signal

  @impl Skopos.Providers.Adapter
  def build(configuration, credentials), do: Webhook.build(configuration, credentials)

  @impl Skopos.Providers.Adapter
  def check(_state, _input), do: :ok

  @impl Skopos.Providers.Signal
  def authenticate(state, envelope, _invocation), do: Webhook.authenticate(state, envelope)

  @impl Skopos.Providers.Signal
  def normalize(_state, envelope, receipt, _invocation) do
    with {:ok, payload} <- Webhook.decode(envelope),
         :ok <- validate_payload(payload),
         {:ok, events} <- events(payload, receipt) do
      {:ok, events}
    end
  end

  defp validate_payload(%{
         "version" => "4",
         "alerts" => alerts,
         "groupKey" => group_key,
         "status" => status
       })
       when is_list(alerts) and alerts != [] and length(alerts) <= 1_000 and
              is_binary(group_key) and status in ["firing", "resolved"],
       do: :ok

  defp validate_payload(_payload),
    do: {:error, :invalid_input, "Alertmanager payload is invalid"}

  defp events(payload, receipt) do
    payload["alerts"]
    |> Enum.reduce_while({:ok, []}, fn alert, {:ok, events} ->
      case event(alert, payload, receipt) do
        {:ok, event} -> {:cont, {:ok, [event | events]}}
        {:error, _category, _message} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, events} -> {:ok, Enum.reverse(events)}
      error -> error
    end
  end

  defp event(
         %{
           "status" => status,
           "fingerprint" => fingerprint,
           "labels" => labels,
           "annotations" => annotations,
           "startsAt" => starts_at,
           "endsAt" => ends_at
         } = alert,
         payload,
         receipt
       )
       when status in ["firing", "resolved"] and is_binary(fingerprint) and
              byte_size(fingerprint) > 0 and is_map(labels) and is_map(annotations) and
              is_binary(starts_at) and is_binary(ends_at) do
    with {:ok, occurred_at} <- occurred_at(status, starts_at, ends_at),
         :ok <- string_map(labels),
         :ok <- string_map(annotations) do
      {:ok,
       %Signal.Event{
         receipt_id: receipt.receipt_id,
         event_key: fingerprint,
         state: state(status),
         occurred_at: occurred_at,
         source_sequence: DateTime.to_unix(occurred_at, :microsecond),
         target_ref: target_ref(labels),
         attributes: %{
           "title" => title(labels, annotations, fingerprint),
           "severity" => severity(labels["severity"]),
           "labels" => labels,
           "annotations" => annotations
         },
         metadata: %{
           "alertmanager" => %{
             "group_key" => payload["groupKey"],
             "truncated_alerts" => payload["truncatedAlerts"],
             "status" => payload["status"],
             "receiver" => payload["receiver"],
             "group_labels" => payload["groupLabels"],
             "common_labels" => payload["commonLabels"],
             "common_annotations" => payload["commonAnnotations"],
             "external_url" => payload["externalURL"],
             "notification_reason" => payload["notification_reason"]
           },
           "alert" => %{
             "generator_url" => alert["generatorURL"],
             "starts_at" => starts_at,
             "ends_at" => ends_at
           }
         }
       }}
    end
  end

  defp event(_alert, _payload, _receipt),
    do: {:error, :invalid_input, "Alertmanager alert is invalid"}

  defp occurred_at("firing", starts_at, _ends_at), do: timestamp(starts_at)
  defp occurred_at("resolved", _starts_at, ends_at), do: timestamp(ends_at)

  defp timestamp(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> {:ok, datetime}
      _invalid -> {:error, :invalid_input, "Alertmanager timestamp is invalid"}
    end
  end

  defp string_map(map) do
    if Enum.all?(map, fn {key, value} -> is_binary(key) and is_binary(value) end),
      do: :ok,
      else: {:error, :invalid_input, "Alertmanager facts are invalid"}
  end

  defp state("firing"), do: :firing
  defp state("resolved"), do: :recovered

  defp title(labels, annotations, fingerprint) do
    first_present([annotations["summary"], labels["alertname"], fingerprint])
  end

  defp target_ref(%{"instance" => instance}) when is_binary(instance) and byte_size(instance) > 0,
    do: %{"kind" => "instance", "value" => instance}

  defp target_ref(_labels), do: nil

  defp severity(value) when value in ["info", "warning", "error", "critical"], do: value
  defp severity(_value), do: "warning"

  defp first_present(values) do
    Enum.find(values, fn value -> is_binary(value) and byte_size(value) > 0 end)
  end
end
