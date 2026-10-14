defmodule Skopos.Targets.Adapters.RedfishURI do
  @moduledoc false

  @max_uri_bytes 2_048
  @unsafe_escape ~r/%(?:25|2e|2f|5c)/i

  def relative(uri) when is_binary(uri) and byte_size(uri) in 11..@max_uri_bytes do
    with %URI{} = parsed <- URI.parse(uri),
         true <- is_nil(parsed.scheme) and is_nil(parsed.host) and is_nil(parsed.userinfo),
         :ok <- valid_parts(parsed, uri) do
      {:ok, relative_path(parsed)}
    else
      _ -> {:error, :invalid_resource_uri}
    end
  rescue
    _ -> {:error, :invalid_resource_uri}
  end

  def relative(_uri), do: {:error, :invalid_resource_uri}

  def from_link(endpoint, uri) when is_binary(endpoint) and is_binary(uri) do
    with %URI{} = origin <- URI.parse(endpoint),
         %URI{} = parsed <- URI.parse(uri),
         true <- same_origin?(origin, parsed),
         :ok <- valid_parts(parsed, uri) do
      {:ok, relative_path(parsed)}
    else
      _ -> {:error, :invalid_resource_uri}
    end
  rescue
    _ -> {:error, :invalid_resource_uri}
  end

  def from_link(_endpoint, _uri), do: {:error, :invalid_resource_uri}

  # Task monitors are opaque service-generated links, not Redfish resource identifiers.
  def monitor(endpoint, uri) when is_binary(endpoint) and is_binary(uri) do
    with %URI{} = origin <- URI.parse(endpoint),
         %URI{path: path} = parsed <- URI.parse(uri),
         true <- byte_size(uri) in 1..@max_uri_bytes,
         true <- same_origin?(origin, parsed),
         true <- is_binary(path) and String.starts_with?(path, "/"),
         true <- not String.starts_with?(path, "//"),
         true <- is_nil(parsed.fragment) and is_nil(parsed.userinfo),
         true <- not String.match?(uri, ~r/[\x00-\x20\x7f\\]/) do
      {:ok, relative_path(parsed)}
    else
      _ -> {:error, :invalid_resource_uri}
    end
  rescue
    _ -> {:error, :invalid_resource_uri}
  end

  def monitor(_endpoint, _uri), do: {:error, :invalid_resource_uri}

  def from_link(endpoint, uri, current_path)
      when is_binary(endpoint) and is_binary(uri) and is_binary(current_path) do
    with {:ok, current} <- relative(current_path),
         %URI{scheme: nil, host: nil, path: nil, query: query} when is_binary(query) <-
           URI.parse(uri) do
      endpoint
      |> Kernel.<>(current)
      |> URI.merge(uri)
      |> URI.to_string()
      |> then(&from_link(endpoint, &1))
    else
      _ -> from_link(endpoint, uri)
    end
  rescue
    _ -> {:error, :invalid_resource_uri}
  end

  def from_link(_endpoint, _uri, _current_path), do: {:error, :invalid_resource_uri}

  defp same_origin?(origin, %URI{scheme: nil, host: nil}), do: origin.scheme == "https"

  defp same_origin?(origin, uri) do
    origin.scheme == "https" and uri.scheme == origin.scheme and uri.host == origin.host and
      (uri.port || 443) == (origin.port || 443)
  end

  defp valid_parts(uri, original) do
    path = uri.path
    segments = if is_binary(path), do: String.split(path, "/", trim: true), else: []

    if byte_size(original) <= @max_uri_bytes and is_binary(path) and
         (path == "/redfish/v1" or String.starts_with?(path, "/redfish/v1/")) and
         not String.contains?(path, ["\\", "//"]) and
         not Regex.match?(@unsafe_escape, path) and
         Enum.all?(segments, &(&1 not in [".", "..", ""])) and
         is_nil(uri.fragment) and is_nil(uri.userinfo) and
         (is_nil(uri.query) or not String.contains?(uri.query, ["\r", "\n"])) do
      :ok
    else
      {:error, :invalid_resource_uri}
    end
  end

  defp relative_path(%URI{path: path, query: nil}), do: path
  defp relative_path(%URI{path: path, query: query}), do: path <> "?" <> query
end
