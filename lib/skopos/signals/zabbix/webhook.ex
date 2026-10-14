defmodule Skopos.Signals.Zabbix.Webhook do
  @moduledoc false

  @behaviour Skopos.Providers.Adapter
  @behaviour Skopos.Providers.Signal

  alias Skopos.Providers.Signal
  alias Skopos.Signals.Webhook

  @impl Skopos.Providers.Adapter
  def type, do: "zabbix-webhook"

  @impl Skopos.Providers.Adapter
  def kind, do: :signal

  @impl Skopos.Providers.Adapter
  def build(%{"source" => source} = configuration, credentials)
      when map_size(configuration) in 1..2 do
    with true <- Map.keys(configuration) -- ["source", "timezone"] == [],
         {:ok, state} <- Webhook.build(%{"source" => source}, credentials),
         {:ok, timezone} <- timezone(configuration["timezone"] || "Etc/UTC") do
      {:ok, Map.put(state, :timezone, timezone)}
    else
      _invalid -> {:error, :invalid_configuration}
    end
  end

  def build(_configuration, _credentials), do: {:error, :invalid_configuration}

  @impl Skopos.Providers.Adapter
  def check(_state, _input), do: :ok

  @impl Skopos.Providers.Signal
  def authenticate(state, envelope, _invocation), do: Webhook.authenticate(state, envelope)

  @impl Skopos.Providers.Signal
  def normalize(state, envelope, receipt, _invocation) do
    with {:ok, payload} <- Webhook.decode(envelope),
         {:ok, event} <- event(payload, receipt, state.timezone) do
      {:ok, [event]}
    end
  end

  defp event(
         %{"event_id" => event_id, "event_value" => event_value} = payload,
         receipt,
         timezone
       )
       when is_binary(event_id) and byte_size(event_id) > 0 do
    with {:ok, state} <- state(event_value),
         {:ok, occurred_at, sequence} <- occurred_at(payload, state, timezone),
         :ok <- validate_facts(payload) do
      {:ok,
       %Signal.Event{
         receipt_id: receipt.receipt_id,
         event_key: event_id,
         state: state,
         occurred_at: occurred_at,
         source_sequence: sequence,
         target_ref: target_ref(payload),
         attributes: %{
           "title" => title(payload, event_id),
           "severity" => severity(payload)
         },
         metadata: %{"zabbix" => payload}
       }}
    end
  end

  defp event(_payload, _receipt, _timezone),
    do: {:error, :invalid_input, "Zabbix payload is invalid"}

  defp state(value) when value in [1, "1", "problem", "firing"], do: {:ok, :firing}
  defp state(value) when value in [0, "0", "recovery", "recovered"], do: {:ok, :recovered}
  defp state(_value), do: {:error, :invalid_input, "Zabbix event value is invalid"}

  defp occurred_at(payload, :recovered, timezone) do
    first_timestamp(
      payload["recovery_timestamp"],
      payload["recovery_date"],
      payload["recovery_time"],
      timezone
    )
  end

  defp occurred_at(%{"update_status" => value} = payload, :firing, timezone)
       when value in [1, "1"] do
    first_timestamp(
      payload["update_timestamp"],
      payload["update_date"],
      payload["update_time"],
      timezone
    )
  end

  defp occurred_at(payload, :firing, timezone) do
    first_timestamp(
      payload["event_timestamp"],
      payload["event_date"],
      payload["event_time"],
      timezone
    )
  end

  defp first_timestamp(timestamp, date, time, timezone) do
    case unix_timestamp(timestamp) do
      {:ok, _datetime, _sequence} = result -> result
      :missing -> local_timestamp(date, time, timezone)
    end
  end

  defp unix_timestamp(value) when is_integer(value) and value >= 0 do
    case DateTime.from_unix(value) do
      {:ok, datetime} -> {:ok, datetime, value}
      _invalid -> :missing
    end
  end

  defp unix_timestamp(value) when is_binary(value) do
    case Integer.parse(value) do
      {seconds, ""} when seconds >= 0 -> unix_timestamp(seconds)
      _invalid -> :missing
    end
  end

  defp unix_timestamp(_value), do: :missing

  defp local_timestamp(date, time, timezone) when is_binary(date) and is_binary(time) do
    value = String.replace(date, ".", "-") <> "T" <> time

    with {:ok, naive} <- NaiveDateTime.from_iso8601(value),
         {:ok, datetime} <-
           DateTime.from_naive(naive, timezone, Tzdata.TimeZoneDatabase),
         {:ok, utc} <- DateTime.shift_zone(datetime, "Etc/UTC", Tzdata.TimeZoneDatabase) do
      {:ok, utc, DateTime.to_unix(utc)}
    else
      _invalid -> invalid_timestamp()
    end
  end

  defp local_timestamp(_date, _time, _timezone), do: invalid_timestamp()

  defp invalid_timestamp,
    do: {:error, :invalid_input, "Zabbix event timestamp is invalid"}

  defp timezone(value) when is_binary(value) and byte_size(value) in 1..120 do
    case DateTime.now(value, Tzdata.TimeZoneDatabase) do
      {:ok, _datetime} -> {:ok, value}
      _invalid -> {:error, :invalid_timezone}
    end
  end

  defp timezone(_value), do: {:error, :invalid_timezone}

  defp validate_facts(payload) do
    if Enum.all?(payload, fn {key, _value} -> is_binary(key) end),
      do: :ok,
      else: {:error, :invalid_input, "Zabbix facts are invalid"}
  end

  defp target_ref(%{"host_id" => host_id}) when is_binary(host_id) and byte_size(host_id) > 0,
    do: %{"kind" => "host_id", "value" => host_id}

  defp target_ref(%{"host" => host}) when is_binary(host) and byte_size(host) > 0,
    do: %{"kind" => "host", "value" => host}

  defp target_ref(_payload), do: nil

  defp title(payload, event_id) do
    first_present([payload["event_name"], payload["subject"], "Zabbix event #{event_id}"])
  end

  defp severity(%{"severity_number" => value}) when value in [5, "5"], do: "critical"
  defp severity(%{"severity_number" => value}) when value in [3, "3", 4, "4"], do: "error"
  defp severity(%{"severity_number" => value}) when value in [1, "1", 2, "2"], do: "warning"
  defp severity(%{"severity_number" => value}) when value in [0, "0"], do: "info"

  defp severity(%{"severity" => value}) when is_binary(value) do
    case String.downcase(value) do
      "disaster" -> "critical"
      value when value in ["average", "high"] -> "error"
      value when value in ["information", "warning"] -> "warning"
      "not classified" -> "info"
      _other -> "warning"
    end
  end

  defp severity(_payload), do: "warning"

  defp first_present(values) do
    Enum.find(values, fn
      value when is_binary(value) -> byte_size(value) > 0
      value when is_integer(value) -> value >= 0
      _value -> false
    end)
  end
end
