defmodule Skopos.Providers.Redactor do
  @moduledoc false

  @redacted "[REDACTED]"
  @secret_keys ~w(
    api_key authorization bearer client_secret community credential kubeconfig
    password passphrase private_key secret signing_secret token
  )

  # Each match consumes at least one input byte. Single-pass replacement never
  # scans an inserted marker, and JSON syntax itself is not replaced.
  def max_encoded_bytes(input_bytes), do: input_bytes * byte_size(@redacted)

  def message(message, credentials) when is_binary(message) and is_map(credentials) do
    case secret_strings(credentials) do
      [] -> message
      secrets -> String.replace(message, secrets, @redacted)
    end
  end

  def value(%module{} = value, credentials) do
    redacted = value |> Map.from_struct() |> value(credentials)
    struct(module, redacted)
  end

  def value(value, credentials) when is_map(value) do
    Map.new(value, fn {key, item} -> {key, value(item, credentials)} end)
  end

  def value(value, credentials) when is_list(value),
    do: Enum.map(value, &value(&1, credentials))

  def value(value, credentials) when is_tuple(value) do
    value |> Tuple.to_list() |> value(credentials) |> List.to_tuple()
  end

  def value(value, credentials) when is_binary(value), do: message(value, credentials)
  def value(value, _credentials), do: value

  defp secret_strings(value) when is_map(value) do
    Enum.flat_map(value, fn {key, nested} ->
      if secret_key?(key), do: scalar_strings(nested), else: secret_strings(nested)
    end)
  end

  defp secret_strings(value) when is_list(value), do: Enum.flat_map(value, &secret_strings/1)
  defp secret_strings(_value), do: []

  defp scalar_strings(value) when is_map(value),
    do: value |> Map.values() |> Enum.flat_map(&scalar_strings/1)

  defp scalar_strings(value) when is_list(value), do: Enum.flat_map(value, &scalar_strings/1)
  defp scalar_strings(value) when is_binary(value) and value != "", do: [value]
  defp scalar_strings(value) when is_integer(value) or is_float(value), do: [to_string(value)]
  defp scalar_strings(_value), do: []

  defp secret_key?(key) do
    normalized = key |> to_string() |> String.downcase()

    Enum.any?(@secret_keys, fn secret ->
      normalized == secret or String.ends_with?(normalized, "_#{secret}")
    end)
  end
end
