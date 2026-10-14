defmodule Skopos.Signals.Webhook do
  @moduledoc false

  alias Skopos.Providers.Signal

  @max_source_bytes 120
  @min_secret_bytes 16

  def build(%{"source" => source} = configuration, %{"secret" => secret} = credentials)
      when map_size(configuration) == 1 and map_size(credentials) == 1 and is_binary(source) and
             is_binary(secret) and byte_size(source) in 1..@max_source_bytes and
             byte_size(secret) >= @min_secret_bytes do
    {:ok, %{source: source, secret: secret}}
  end

  def build(_configuration, _credentials), do: {:error, :invalid_configuration}

  def authenticate(state, envelope) do
    with {:ok, presented} <- bearer(envelope.headers),
         true <- secure_compare(presented, state.secret) do
      {:ok,
       %Signal.AuthenticatedReceipt{
         receipt_id: digest(envelope.body),
         source: state.source
       }}
    else
      _failure -> {:error, :authentication, "Webhook authentication failed"}
    end
  end

  def decode(%Signal.Envelope{body: body}) do
    case Jason.decode(body) do
      {:ok, value} when is_map(value) -> {:ok, value}
      _invalid -> {:error, :invalid_input, "Webhook body is invalid"}
    end
  end

  defp bearer(headers) do
    case Map.get(headers, "authorization") do
      "Bearer " <> token when byte_size(token) > 0 -> {:ok, token}
      _missing -> :error
    end
  end

  defp secure_compare(left, right) when byte_size(left) == byte_size(right),
    do: Plug.Crypto.secure_compare(left, right)

  defp secure_compare(_left, _right), do: false

  defp digest(body) do
    :crypto.hash(:sha256, body)
    |> Base.encode16(case: :lower)
  end
end
