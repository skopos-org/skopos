defmodule Skopos.Inventories.NetBox.API do
  @moduledoc false

  @behaviour Skopos.Providers.Adapter
  @behaviour Skopos.Providers.Inventory

  alias Skopos.Providers.Inventory
  alias Skopos.Transports.HTTPS

  @configuration_keys ~w(base_url ca_certificate connect_timeout_ms request_timeout_ms)
  @credential_keys ~w(token)
  @scope_keys ~w(resource filters page_size)
  @reserved_filters ~w(limit offset start ordering fields brief exclude depth)
  @filter_pattern ~r/^[a-z][a-z0-9_]{0,63}$/
  @max_response_bytes 1_048_576

  @resources %{
    "devices" => %{
      path: "dcim/devices/",
      object_type: "dcim.device",
      kind: :device,
      fields:
        ~w(id display name status site location rack role tenant platform primary_ip4 primary_ip6 oob_ip serial asset_tag cluster device_type tags custom_fields created last_updated)
    },
    "virtual_machines" => %{
      path: "virtualization/virtual-machines/",
      object_type: "virtualization.virtualmachine",
      kind: :virtual_machine,
      fields:
        ~w(id display name status site cluster device role tenant platform primary_ip4 primary_ip6 vcpus memory disk serial tags custom_fields created last_updated)
    }
  }

  defmodule State do
    @moduledoc false
    @enforce_keys [
      :base_url,
      :authorization,
      :connect_timeout,
      :request_timeout,
      :transport_opts
    ]
    defstruct @enforce_keys
  end

  @impl Skopos.Providers.Adapter
  def type, do: "netbox-api"

  @impl Skopos.Providers.Adapter
  def kind, do: :inventory

  @impl Skopos.Providers.Adapter
  def build(configuration, credentials) when is_map(configuration) and is_map(credentials) do
    with :ok <- exact_keys(configuration, @configuration_keys),
         :ok <- exact_keys(credentials, @credential_keys),
         {:ok, base_url, host} <- base_url(configuration["base_url"]),
         {:ok, authorization} <- authorization(credentials["token"]),
         {:ok, connect_timeout} <- timeout(configuration, "connect_timeout_ms", 10_000),
         {:ok, request_timeout} <- timeout(configuration, "request_timeout_ms", 30_000),
         {:ok, transport_opts} <- HTTPS.transport_options(configuration["ca_certificate"], host) do
      {:ok,
       %State{
         base_url: base_url,
         authorization: authorization,
         connect_timeout: connect_timeout,
         request_timeout: request_timeout,
         transport_opts: transport_opts
       }}
    else
      _error -> {:error, :invalid_configuration}
    end
  rescue
    _error -> {:error, :invalid_configuration}
  end

  def build(_configuration, _credentials), do: {:error, :invalid_configuration}

  @impl Skopos.Providers.Adapter
  def check(%State{} = state, input) when is_map(input) do
    with {:ok, spec, filters, _page_size} <- scope(input),
         {:ok, _body, _version} <- request(state, spec, filters, 0, 1) do
      :ok
    else
      {:error, :authentication, message} -> {:error, :authentication, message}
      {:error, :capability, message} -> {:error, :capability, message}
      {:error, :retryable, message} -> {:error, :unreachable, message}
      {:error, _category, message} -> {:error, :invalid_configuration, message}
    end
  end

  def check(_state, _input),
    do: {:error, :invalid_configuration, "NetBox check scope is invalid"}

  @impl Skopos.Providers.Inventory
  def fetch_page(%State{} = state, %Inventory.Request{scope: scope}, cursor, _invocation) do
    with {:ok, spec, filters, page_size} <- scope(scope),
         {:ok, offset} <- offset(cursor),
         {:ok, body, version} <- request(state, spec, filters, offset, page_size),
         {:ok, records, next_cursor} <- page(body, spec, offset) do
      {:ok,
       %Inventory.Page{
         records: records,
         source_version: "netbox-api:#{version}",
         next_cursor: next_cursor
       }}
    else
      {:error, category, message} when category in [:retryable, :failed, :cancelled] ->
        {:error, category, message}

      {:error, :authentication, _message} ->
        {:error, :failed, "NetBox authentication failed"}

      {:error, :capability, _message} ->
        {:error, :failed, "NetBox inventory request is forbidden"}
    end
  end

  def fetch_page(_state, _request, _cursor, _invocation),
    do: {:error, :failed, "NetBox inventory request is invalid"}

  defp request(state, spec, filters, offset, page_size) do
    options = [
      method: :get,
      url: state.base_url <> spec.path,
      params: query(spec, filters, offset, page_size),
      headers: [
        {"accept", "application/json"},
        {"authorization", state.authorization}
      ],
      connect_options: [timeout: state.connect_timeout, transport_opts: state.transport_opts],
      receive_timeout: state.request_timeout,
      retry: false,
      redirect: false,
      decode_body: false
    ]

    Req.request(options)
    |> response()
  rescue
    _error -> {:error, :retryable, "NetBox endpoint is unreachable"}
  catch
    _kind, _reason -> {:error, :retryable, "NetBox endpoint is unreachable"}
  end

  defp response({:ok, %Req.Response{status: status, body: body} = response})
       when status in 200..299 and is_binary(body) and byte_size(body) <= @max_response_bytes do
    with [version] when is_binary(version) and byte_size(version) in 1..40 <-
           Req.Response.get_header(response, "api-version"),
         {:ok, decoded} when is_map(decoded) <- Jason.decode(body) do
      {:ok, decoded, version}
    else
      _error -> {:error, :failed, "NetBox response is invalid"}
    end
  end

  defp response({:ok, %Req.Response{status: 401}}),
    do: {:error, :authentication, "NetBox authentication failed"}

  defp response({:ok, %Req.Response{status: 403}}),
    do: {:error, :capability, "NetBox inventory request is forbidden"}

  defp response({:ok, %Req.Response{status: status}}) when status == 429 or status in 500..599,
    do: {:error, :retryable, "NetBox endpoint is temporarily unavailable"}

  defp response({:ok, %Req.Response{status: status}}) when status in 400..499,
    do: {:error, :failed, "NetBox rejected the inventory request"}

  defp response({:ok, %Req.Response{}}),
    do: {:error, :failed, "NetBox response exceeded its limit"}

  defp response({:error, _error}), do: {:error, :retryable, "NetBox endpoint is unreachable"}
  defp response(_response), do: {:error, :failed, "NetBox response is invalid"}

  defp page(%{"results" => results, "next" => next}, spec, offset)
       when is_list(results) and (is_nil(next) or is_binary(next)) do
    with {:ok, records} <- records(results, spec),
         {:ok, next_cursor} <- next_cursor(next, offset, length(results)) do
      {:ok, records, next_cursor}
    end
  end

  defp page(_body, _spec, _offset), do: {:error, :failed, "NetBox page is invalid"}

  defp records(results, spec) do
    Enum.reduce_while(results, {:ok, []}, fn object, {:ok, records} ->
      case record(object, spec) do
        {:ok, record} -> {:cont, {:ok, [record | records]}}
        {:error, _category, _message} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, records} -> {:ok, Enum.reverse(records)}
      error -> error
    end
  end

  defp record(%{"id" => id} = object, spec) when is_integer(id) and id > 0 do
    with {:ok, name} <- object_name(object),
         {:ok, last_updated} <- required_string(object["last_updated"], 80) do
      attributes =
        object
        |> Map.take(spec.fields)
        |> Map.put("name", name)
        |> Map.put("kind", spec.object_type)
        |> Map.put("platform", platform(object))
        |> Map.put("object_type", spec.object_type)
        |> Map.put("last_updated", last_updated)

      {:ok,
       %Inventory.Record{
         external_id: "#{spec.object_type}:#{id}",
         kind: spec.kind,
         source_ref: "/api/#{spec.path}#{id}/",
         attributes: attributes
       }}
    else
      _error -> {:error, :failed, "NetBox object is invalid"}
    end
  end

  defp record(_object, _spec), do: {:error, :failed, "NetBox object is invalid"}

  defp object_name(%{"name" => name}) when is_binary(name) and byte_size(name) in 1..120,
    do: {:ok, name}

  defp object_name(%{"display" => display})
       when is_binary(display) and byte_size(display) in 1..120,
       do: {:ok, display}

  defp object_name(_object), do: {:error, :invalid_name}

  defp platform(%{"platform" => %{"slug" => slug}})
       when is_binary(slug) and byte_size(slug) in 1..120,
       do: slug

  defp platform(%{"platform" => %{"name" => name}})
       when is_binary(name) and byte_size(name) in 1..120,
       do: name

  defp platform(_object), do: "unknown"

  defp query(spec, filters, offset, page_size) do
    [
      {"fields", Enum.join(spec.fields, ",")},
      {"limit", page_size},
      {"offset", offset},
      {"ordering", "id"}
    ] ++ filter_query(filters)
  end

  defp filter_query(filters) do
    Enum.flat_map(filters, fn {key, values} ->
      Enum.map(List.wrap(values), &{key, &1})
    end)
  end

  defp scope(scope) do
    with true <- is_map(scope),
         :ok <- exact_keys(scope, @scope_keys),
         %{} = spec <- @resources[scope["resource"]],
         {:ok, filters} <- filters(Map.get(scope, "filters", %{})),
         {:ok, page_size} <- page_size(Map.get(scope, "page_size", 100)) do
      {:ok, spec, filters, page_size}
    else
      _error -> {:error, :failed, "NetBox inventory scope is invalid"}
    end
  end

  defp filters(filters) when is_map(filters) and map_size(filters) <= 20 do
    if Enum.all?(filters, fn {key, value} -> valid_filter?(key, value) end),
      do: {:ok, filters},
      else: {:error, :invalid_filters}
  end

  defp filters(_filters), do: {:error, :invalid_filters}

  defp valid_filter?(key, value) when is_binary(key) do
    Regex.match?(@filter_pattern, key) and key not in @reserved_filters and
      valid_filter_value?(value)
  end

  defp valid_filter?(_key, _value), do: false

  defp valid_filter_value?(values) when is_list(values) and length(values) in 1..20,
    do: Enum.all?(values, &scalar_filter?/1)

  defp valid_filter_value?(value), do: scalar_filter?(value)

  defp scalar_filter?(value) when is_integer(value), do: value >= 0
  defp scalar_filter?(value) when is_boolean(value), do: true
  defp scalar_filter?(value) when is_binary(value), do: byte_size(value) in 1..200
  defp scalar_filter?(_value), do: false

  defp page_size(value) when is_integer(value) and value in 1..200, do: {:ok, value}
  defp page_size(_value), do: {:error, :invalid_page_size}

  defp offset(nil), do: {:ok, 0}

  defp offset(value) when is_binary(value) do
    case Integer.parse(value) do
      {offset, ""} when offset > 0 -> {:ok, offset}
      _error -> {:error, :failed, "NetBox inventory cursor is invalid"}
    end
  end

  defp offset(_value), do: {:error, :failed, "NetBox inventory cursor is invalid"}

  defp next_cursor(nil, _offset, _count), do: {:ok, nil}

  defp next_cursor(next, offset, count) when count > 0 do
    with %URI{query: query} when is_binary(query) <- URI.parse(next),
         params <- URI.decode_query(query),
         {next_offset, ""} <- Integer.parse(Map.get(params, "offset", "")),
         true <- next_offset == offset + count do
      {:ok, Integer.to_string(next_offset)}
    else
      _error -> {:error, :failed, "NetBox pagination response is invalid"}
    end
  end

  defp next_cursor(_next, _offset, _count),
    do: {:error, :failed, "NetBox pagination response is invalid"}

  defp base_url(value) when is_binary(value) do
    case URI.parse(value) do
      %URI{scheme: "https", host: host, path: path} = uri
      when is_binary(host) and byte_size(host) > 0 and is_binary(path) ->
        if is_nil(uri.userinfo) and is_nil(uri.query) and is_nil(uri.fragment) and
             String.ends_with?(path, "/api/") and (is_nil(uri.port) or uri.port in 1..65_535) do
          {:ok, URI.to_string(uri), host}
        else
          {:error, :invalid_url}
        end

      _uri ->
        {:error, :invalid_url}
    end
  end

  defp base_url(_value), do: {:error, :invalid_url}

  defp authorization(token) do
    with {:ok, token} <- required_string(token, 4_096),
         false <- String.match?(token, ~r/[\s\x00-\x1f\x7f]/) do
      scheme = if String.starts_with?(token, "nbt_"), do: "Bearer", else: "Token"
      {:ok, scheme <> " " <> token}
    else
      _error -> {:error, :invalid_token}
    end
  end

  defp timeout(configuration, key, default) do
    case Map.get(configuration, key, default) do
      value when is_integer(value) and value in 100..600_000 -> {:ok, value}
      _value -> {:error, :invalid_timeout}
    end
  end

  defp exact_keys(map, allowed) do
    if Enum.all?(Map.keys(map), &(is_binary(&1) and &1 in allowed)),
      do: :ok,
      else: {:error, :unknown_key}
  end

  defp required_string(value, maximum)
       when is_binary(value) and byte_size(value) >= 1 and byte_size(value) <= maximum,
       do: {:ok, value}

  defp required_string(_value, _maximum), do: {:error, :invalid_string}
end
