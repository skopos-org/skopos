defmodule Skopos.Targets.Profiles.IOSXE.RESTCONF do
  @moduledoc false

  @behaviour Skopos.Providers.Adapter
  @behaviour Skopos.Providers.Target

  alias Skopos.Targets.Profiles.IOSXE
  alias Skopos.Transports.RESTCONF, as: Transport
  alias Skopos.Transports.RESTCONF.State
  alias Skopos.Targets.Adapters.RESTCONF, as: RESTCONFMethod

  @method_observation "request.restconf.observe"
  @method_effect "request.restconf.effect"

  @impl Skopos.Providers.Adapter
  def type, do: "ios-xe-restconf"

  @impl Skopos.Providers.Adapter
  def kind, do: :target

  @impl Skopos.Providers.Target
  def access_method_profile,
    do: IOSXE.access_method_profile("restconf", @method_observation, @method_effect)

  @impl Skopos.Providers.Adapter
  defdelegate build(configuration, credentials), to: RESTCONFMethod

  @impl Skopos.Providers.Adapter
  defdelegate check(state, input), to: RESTCONFMethod

  @impl Skopos.Providers.Target
  defdelegate bind_connection(state, connection), to: RESTCONFMethod

  @impl Skopos.Providers.Target
  def capabilities(state, invocation) do
    capabilities = IOSXE.capabilities()

    with {:ok, generic} <- RESTCONFMethod.capabilities(state, invocation) do
      {:ok,
       %{
         capabilities
         | observations: capabilities.observations ++ generic.observations,
           effects: capabilities.effects ++ generic.effects
       }}
    end
  end

  @impl Skopos.Providers.Target
  def observe(%State{} = state, %{capability: @method_observation} = request, invocation),
    do: RESTCONFMethod.observe(state, request, invocation)

  def observe(%State{} = state, request, invocation) do
    with {:ok, endpoint} <- Transport.endpoint(request.connection.endpoint),
         {:ok, operation} <- IOSXE.observation_request(request),
         {:ok, facts} <- observe_operation(state, endpoint, operation, invocation) do
      IOSXE.observation(facts)
    else
      {:error, category, message} -> IOSXE.read_error(category, message)
    end
  end

  @impl Skopos.Providers.Target
  def classify_request(%State{} = state, request) do
    with {:ok, _endpoint} <- Transport.endpoint(request.connection.endpoint) do
      case request.capability do
        capability when capability in [@method_observation, @method_effect] ->
          RESTCONFMethod.classify_request(state, request)

        "effect.interface" ->
          classify_restconf(IOSXE.effect_request(request), :effect)

        _other ->
          classify_restconf(IOSXE.observation_request(request), :observation)
      end
    else
      _ -> {:error, :failed, "RESTCONF request is invalid"}
    end
  end

  defp classify_restconf({:ok, _operation}, kind), do: {:ok, kind}
  defp classify_restconf(_invalid, _kind), do: {:error, :failed, "RESTCONF request is invalid"}

  @impl Skopos.Providers.Target
  def effect(%State{} = state, %{capability: @method_effect} = request, invocation),
    do: RESTCONFMethod.effect(state, request, invocation)

  def effect(%State{} = state, request, invocation) do
    with {:ok, endpoint} <- Transport.endpoint(request.connection.endpoint),
         {:ok, operation} <- IOSXE.effect_request(request) do
      apply_operation(state, endpoint, operation, invocation)
    else
      {:error, category, message} -> IOSXE.effect_error(category, message)
    end
  end

  @impl Skopos.Providers.Target
  def verify(%State{} = state, %{capability: @method_observation} = request, invocation),
    do: RESTCONFMethod.verify(state, request, invocation)

  def verify(%State{} = state, request, invocation) do
    with {:ok, endpoint} <- Transport.endpoint(request.connection.endpoint),
         {:ok, name, expected} <- IOSXE.verification_request(request),
         {:ok, facts} <-
           observe_operation(state, endpoint, {:interface, name}, invocation) do
      IOSXE.verification(facts, expected)
    else
      {:error, category, message} -> IOSXE.read_error(category, message)
    end
  end

  defp observe_operation(state, endpoint, :system, invocation) do
    {hostname_path, version_path} = restconf_system_paths()

    with {:ok, hostname} <-
           request(
             state,
             endpoint,
             :get,
             hostname_path,
             nil,
             invocation,
             :read
           ),
         {:ok, version} <-
           request(
             state,
             endpoint,
             :get,
             version_path,
             nil,
             invocation,
             :read
           ),
         {:ok, facts} <- restconf_system_facts(hostname, version) do
      {:ok, facts}
    else
      {:error, _category, _message} = error -> error
    end
  end

  defp observe_operation(state, endpoint, {:interface, name}, invocation) do
    {configuration_path, operational_path} = restconf_interface_paths(name)

    with {:ok, configuration} <-
           request(
             state,
             endpoint,
             :get,
             configuration_path,
             nil,
             invocation,
             :read
           ),
         {:ok, operational} <-
           request(
             state,
             endpoint,
             :get,
             operational_path,
             nil,
             invocation,
             :read
           ),
         {:ok, facts} <- restconf_interface_facts(name, configuration, operational) do
      {:ok, facts}
    end
  end

  defp apply_operation(state, endpoint, {:description, name, expected, desired}, invocation) do
    with {:ok, facts} <- observe_operation(state, endpoint, {:interface, name}, invocation),
         :ok <- IOSXE.match_expected(facts["description"], expected, "description"),
         {:ok, _body} <-
           patch_interface(state, endpoint, name, %{"description" => desired}, invocation) do
      IOSXE.applied(%{"interface" => name, "description" => desired})
    else
      {:stale, observed, field} -> IOSXE.stale(field, observed)
      {:error, category, message} -> IOSXE.effect_error(category, message)
    end
  end

  defp apply_operation(state, endpoint, {:admin_state, name, expected, desired}, invocation) do
    with {:ok, facts} <- observe_operation(state, endpoint, {:interface, name}, invocation),
         :ok <- IOSXE.match_expected(facts["enabled"], expected, "enabled"),
         {:ok, _body} <-
           patch_interface(state, endpoint, name, %{"enabled" => desired}, invocation) do
      IOSXE.applied(%{"interface" => name, "enabled" => desired})
    else
      {:stale, observed, field} -> IOSXE.stale(field, observed)
      {:error, category, message} -> IOSXE.effect_error(category, message)
    end
  end

  defp patch_interface(state, endpoint, name, values, invocation) do
    {path, _operational_path} = restconf_interface_paths(name)
    body = restconf_interface_body(name, values)

    request(
      state,
      endpoint,
      :patch,
      path,
      body,
      invocation,
      :effect
    )
  end

  defp request(state, endpoint, method, path, body, invocation, phase) do
    operation = %{
      method: method,
      path: path,
      body: if(is_nil(body), do: nil, else: Jason.encode!(body)),
      query: %{},
      accept: "application/yang-data+json",
      content_type: "application/yang-data+json"
    }

    case Transport.request(state, endpoint, operation, invocation, phase) do
      {:ok, %{status: status, body: body}} when status in 200..299 ->
        if body == "" do
          {:ok, %{}}
        else
          case Jason.decode(body) do
            {:ok, value} when is_map(value) -> {:ok, value}
            _ -> {:error, :failed, "IOS XE RESTCONF response is invalid"}
          end
        end

      {:ok, %{status: 401}} ->
        {:error, :authentication, "IOS XE RESTCONF authentication failed"}

      {:ok, %{status: 403}} ->
        {:error, :forbidden, "IOS XE RESTCONF request is forbidden"}

      {:ok, %{status: 404}} ->
        {:error, :not_found, "IOS XE RESTCONF resource was not found"}

      {:ok, %{status: 409}} ->
        {:error, :conflict, "IOS XE RESTCONF resource changed"}

      {:ok, _response} ->
        {:error, :rejected, "IOS XE RESTCONF request was rejected"}

      {:error, _category, _message} = error ->
        error
    end
  end

  defp restconf_system_paths do
    {
      "/data/Cisco-IOS-XE-native:native/hostname",
      "/data/Cisco-IOS-XE-native:native/version"
    }
  end

  defp restconf_system_facts(
         %{"Cisco-IOS-XE-native:hostname" => hostname},
         %{"Cisco-IOS-XE-native:version" => version}
       ),
       do: {:ok, %{"hostname" => hostname, "version" => version}}

  defp restconf_system_facts(_hostname, _version),
    do: {:error, :failed, "IOS XE RESTCONF system response is invalid"}

  defp restconf_interface_paths(name) do
    key = URI.encode_www_form(name)

    {
      "/data/ietf-interfaces:interfaces/interface=#{key}",
      "/data/ietf-interfaces:interfaces-state/interface=#{key}"
    }
  end

  defp restconf_interface_body(name, values),
    do: %{"ietf-interfaces:interface" => Map.put(values, "name", name)}

  defp restconf_interface_facts(
         name,
         %{"ietf-interfaces:interface" => configuration},
         %{"ietf-interfaces:interface" => operational}
       ) do
    {:ok,
     %{
       "name" => name,
       "description" => configuration["description"],
       "enabled" => Map.get(configuration, "enabled", true),
       "admin_status" => operational["admin-status"],
       "oper_status" => operational["oper-status"],
       "input_errors" => get_in(operational, ["statistics", "in-errors"]),
       "output_errors" => get_in(operational, ["statistics", "out-errors"])
     }}
  end

  defp restconf_interface_facts(_name, _configuration, _operational),
    do: {:error, :failed, "IOS XE RESTCONF interface response is invalid"}
end
