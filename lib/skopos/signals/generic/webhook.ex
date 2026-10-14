defmodule Skopos.Signals.Generic.Webhook do
  @moduledoc false

  @behaviour Skopos.Providers.Adapter
  @behaviour Skopos.Providers.Signal

  alias Skopos.Providers.Signal
  alias Skopos.Signals.Webhook

  @allowed_keys ~w(event_key state occurred_at title severity source_sequence target_ref facts)

  @impl Skopos.Providers.Adapter
  def type, do: "generic-webhook"

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
         :ok <- allowed_keys(payload),
         {:ok, event_key} <- string(payload["event_key"], 500, "event_key"),
         {:ok, state} <- state(payload["state"]),
         {:ok, occurred_at} <- timestamp(payload["occurred_at"]),
         {:ok, title} <- string(payload["title"], 200, "title"),
         {:ok, severity} <- severity(Map.get(payload, "severity", "warning")),
         {:ok, sequence} <- optional_string(payload, "source_sequence", 500),
         {:ok, target_ref} <- optional_target_ref(payload),
         {:ok, facts} <- facts(Map.get(payload, "facts", %{})) do
      {:ok,
       [
         %Signal.Event{
           receipt_id: receipt.receipt_id,
           event_key: event_key,
           state: state,
           occurred_at: occurred_at,
           source_sequence: sequence,
           target_ref: target_ref,
           attributes: %{"title" => title, "severity" => severity, "facts" => facts}
         }
       ]}
    end
  end

  defp allowed_keys(payload) do
    if Map.keys(payload) -- @allowed_keys == [],
      do: :ok,
      else: {:error, :invalid_input, "Generic Signal payload has unknown fields"}
  end

  defp string(value, max, field) when is_binary(value) do
    if String.length(value) in 1..max,
      do: {:ok, value},
      else: {:error, :invalid_input, "Generic Signal #{field} is invalid"}
  end

  defp string(_value, _max, field),
    do: {:error, :invalid_input, "Generic Signal #{field} is invalid"}

  defp optional_string(payload, field, max) do
    if Map.has_key?(payload, field),
      do: string(payload[field], max, field),
      else: {:ok, nil}
  end

  defp state("firing"), do: {:ok, :firing}
  defp state("recovered"), do: {:ok, :recovered}
  defp state(_value), do: {:error, :invalid_input, "Generic Signal state is invalid"}

  defp severity(value) when value in ~w(info warning error critical), do: {:ok, value}
  defp severity(_value), do: {:error, :invalid_input, "Generic Signal severity is invalid"}

  defp timestamp(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> {:ok, datetime}
      _invalid -> {:error, :invalid_input, "Generic Signal occurred_at is invalid"}
    end
  end

  defp timestamp(_value), do: {:error, :invalid_input, "Generic Signal occurred_at is invalid"}

  defp optional_target_ref(payload) do
    if Map.has_key?(payload, "target_ref"),
      do: target_ref(payload["target_ref"]),
      else: {:ok, nil}
  end

  defp target_ref(%{"kind" => kind, "value" => value} = ref) when map_size(ref) == 2 do
    with {:ok, kind} <- string(kind, 80, "target_ref.kind"),
         {:ok, value} <- string(value, 500, "target_ref.value") do
      {:ok, %{"kind" => kind, "value" => value}}
    end
  end

  defp target_ref(_value),
    do: {:error, :invalid_input, "Generic Signal target_ref is invalid"}

  defp facts(value) when is_map(value) and map_size(value) <= 32 do
    valid? =
      Enum.all?(value, fn {key, fact} ->
        is_binary(key) and String.length(key) in 1..120 and
          (is_boolean(fact) or is_number(fact) or
             (is_binary(fact) and String.length(fact) <= 1_000))
      end)

    if valid? and byte_size(Jason.encode!(value)) <= 8_000,
      do: {:ok, value},
      else: {:error, :invalid_input, "Generic Signal facts are invalid"}
  end

  defp facts(_value), do: {:error, :invalid_input, "Generic Signal facts are invalid"}
end
