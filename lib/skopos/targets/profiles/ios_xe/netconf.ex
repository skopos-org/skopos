defmodule Skopos.Targets.Profiles.IOSXE.NETCONF do
  @moduledoc false

  @behaviour Skopos.Providers.Adapter
  @behaviour Skopos.Providers.Target

  alias Skopos.Targets.Adapters.NETCONF, as: NETCONFMethod
  alias Skopos.Targets.Profiles.IOSXE
  alias Skopos.Transports.{NETCONF, SSH}

  @interfaces_namespace "urn:ietf:params:xml:ns:yang:ietf-interfaces"
  @ios_xe_namespace "http://cisco.com/ns/yang/Cisco-IOS-XE-native"

  @method_observation "request.netconf.observe"
  @method_effect "request.netconf.effect"

  @impl Skopos.Providers.Adapter
  def type, do: "ios-xe-netconf"

  @impl Skopos.Providers.Adapter
  def kind, do: :target

  @impl Skopos.Providers.Target
  def access_method_profile,
    do: IOSXE.access_method_profile("netconf", @method_observation, @method_effect)

  @impl Skopos.Providers.Adapter
  def build(configuration, credentials), do: NETCONFMethod.build(configuration, credentials)

  @impl Skopos.Providers.Adapter
  def check(state, input), do: NETCONFMethod.check(state, input)

  @impl Skopos.Providers.Target
  defdelegate bind_connection(state, connection), to: NETCONFMethod

  @impl Skopos.Providers.Target
  def capabilities(_state, _invocation) do
    capabilities = IOSXE.capabilities()
    {:ok, method} = NETCONFMethod.capabilities(nil, %{})

    {:ok,
     %{
       capabilities
       | observations: capabilities.observations ++ method.observations,
         effects: capabilities.effects ++ method.effects
     }}
  end

  @impl Skopos.Providers.Target
  def observe(%SSH.Config{} = state, %{capability: @method_observation} = request, invocation),
    do: NETCONFMethod.observe(state, request, invocation)

  def observe(%SSH.Config{} = state, request, invocation) do
    with {:ok, operation} <- IOSXE.observation_request(request),
         {:ok, facts} <-
           observe_operation(
             state,
             request.connection.endpoint,
             operation,
             invocation
           ) do
      IOSXE.observation(facts)
    else
      {:error, category, message} -> IOSXE.read_error(category, message)
      {:error, _cause} = error -> error
    end
  end

  @impl Skopos.Providers.Target
  def classify_request(state, request) do
    case request.capability do
      @method_observation ->
        NETCONFMethod.classify_request(state, request)

      @method_effect ->
        NETCONFMethod.classify_request(state, request)

      "effect.interface" ->
        classify_netconf(IOSXE.effect_request(request), :effect)

      _other ->
        classify_netconf(IOSXE.observation_request(request), :observation)
    end
  end

  defp classify_netconf({:ok, _operation}, kind), do: {:ok, kind}
  defp classify_netconf(_invalid, _kind), do: {:error, :failed, "NETCONF request is invalid"}

  @impl Skopos.Providers.Target
  def effect(%SSH.Config{} = state, %{capability: @method_effect} = request, invocation),
    do: NETCONFMethod.effect(state, request, invocation)

  def effect(%SSH.Config{} = state, request, invocation) do
    with {:ok, operation} <- IOSXE.effect_request(request) do
      apply_operation(
        state,
        request.connection.endpoint,
        operation,
        invocation
      )
    else
      {:error, category, message} -> IOSXE.effect_error(category, message)
    end
  end

  @impl Skopos.Providers.Target
  def verify(%SSH.Config{} = state, %{capability: @method_observation} = request, invocation),
    do: NETCONFMethod.verify(state, request, invocation)

  def verify(%SSH.Config{} = state, request, invocation) do
    with {:ok, name, expected} <- IOSXE.verification_request(request),
         {:ok, facts} <-
           observe_operation(
             state,
             request.connection.endpoint,
             {:interface, name},
             invocation
           ) do
      IOSXE.verification(facts, expected)
    else
      {:error, category, message} -> IOSXE.read_error(category, message)
      {:error, _cause} = error -> error
    end
  end

  defp observe_operation(state, endpoint, :system, invocation) do
    with {:ok, root} <- request(state, endpoint, netconf_system_filter(), invocation),
         {:ok, data} <- reply_data(root),
         {:ok, system_element} <- child(data, "native"),
         {:ok, hostname} <- child_text(system_element, "hostname"),
         {:ok, version} <- child_text(system_element, "version") do
      {:ok, netconf_system_facts(hostname, version)}
    end
  end

  defp observe_operation(state, endpoint, {:interface, name}, invocation) do
    with {:ok, root} <- request(state, endpoint, netconf_interface_filter(name), invocation),
         {:ok, data} <- reply_data(root),
         {:ok, configuration} <- data |> child("interfaces") |> interface(name),
         {:ok, operational} <- data |> child("interfaces-state") |> interface(name) do
      {:ok,
       netconf_interface_facts(name, %{
         "description" => optional_child_text(configuration, "description"),
         "enabled" => optional_child_text(configuration, "enabled"),
         "admin_status" => optional_child_text(operational, "admin-status"),
         "oper_status" => optional_child_text(operational, "oper-status"),
         "input_errors" => statistic(operational, "in-errors"),
         "output_errors" => statistic(operational, "out-errors")
       })}
    end
  end

  defp apply_operation(state, endpoint, {:description, name, expected, desired}, invocation) do
    with {:ok, facts} <- observe_operation(state, endpoint, {:interface, name}, invocation),
         :ok <- IOSXE.match_expected(facts["description"], expected, "description"),
         {:ok, _root} <- edit_interface(state, endpoint, name, "description", desired, invocation) do
      IOSXE.applied(%{"interface" => name, "description" => desired})
    else
      {:stale, observed, field} -> IOSXE.stale(field, observed)
      {:error, category, message} -> IOSXE.effect_error(category, message)
      {:error, _cause} = error -> error
    end
  end

  defp apply_operation(state, endpoint, {:admin_state, name, expected, desired}, invocation) do
    with {:ok, facts} <- observe_operation(state, endpoint, {:interface, name}, invocation),
         :ok <- IOSXE.match_expected(facts["enabled"], expected, "enabled"),
         {:ok, _root} <-
           edit_interface(state, endpoint, name, "enabled", to_string(desired), invocation) do
      IOSXE.applied(%{"interface" => name, "enabled" => desired})
    else
      {:stale, observed, field} -> IOSXE.stale(field, observed)
      {:error, category, message} -> IOSXE.effect_error(category, message)
    end
  end

  defp edit_interface(state, endpoint, name, field, value, invocation) do
    request(state, endpoint, netconf_interface_edit(name, field, value), invocation)
  end

  defp request(state, endpoint, body, invocation) do
    case NETCONF.execute(state, endpoint, body, invocation) do
      {:ok, %NETCONF.Result{root: root}} -> {:ok, root}
      error -> error
    end
  end

  defp reply_data(root) do
    case descendants(root, "data") do
      [data | _rest] -> {:ok, data}
      [] -> {:error, :failed, "IOS XE NETCONF response has no data"}
    end
  end

  defp interface({:ok, parent}, name) do
    parent
    |> children("interface")
    |> Enum.find(&(optional_child_text(&1, "name") == name))
    |> case do
      nil -> {:error, :not_found, "IOS XE interface was not found"}
      element -> {:ok, element}
    end
  end

  defp interface({:error, _category, _message} = error, _name), do: error

  defp statistic(interface, field) do
    case child(interface, "statistics") do
      {:ok, statistics} -> optional_child_text(statistics, field)
      _error -> nil
    end
  end

  defp child({_name, _attributes, children}, wanted) do
    case Enum.find(children, fn
           {name, _attributes, _children} -> local_name(name) == wanted
           _text -> false
         end) do
      nil -> {:error, :failed, "IOS XE NETCONF response is incomplete"}
      element -> {:ok, element}
    end
  end

  defp children({_name, _attributes, children}, wanted) do
    Enum.filter(children, fn
      {name, _attributes, _children} -> local_name(name) == wanted
      _text -> false
    end)
  end

  defp child_text(element, wanted) do
    case child(element, wanted) do
      {:ok, child} -> {:ok, text(child)}
      error -> error
    end
  end

  defp optional_child_text(element, wanted) do
    case child_text(element, wanted) do
      {:ok, value} -> value
      _error -> nil
    end
  end

  defp descendants({name, _attributes, children} = element, wanted) do
    own = if local_name(name) == wanted, do: [element], else: []

    own ++
      Enum.flat_map(children, fn
        {_name, _attributes, _children} = child -> descendants(child, wanted)
        _text -> []
      end)
  end

  defp text({_name, _attributes, children}) do
    children
    |> Enum.filter(&is_binary/1)
    |> IO.iodata_to_binary()
    |> String.trim()
  end

  defp local_name(name), do: name |> String.split(":") |> List.last()

  defp netconf_system_filter do
    """
    <get><filter type="subtree"><native xmlns="#{@ios_xe_namespace}"><hostname/><version/></native></filter></get>
    """
  end

  defp netconf_system_facts(hostname, version),
    do: %{"hostname" => hostname, "version" => version}

  defp netconf_interface_filter(name) do
    escaped = xml_escape(name)

    """
    <get><filter type="subtree"><interfaces xmlns="#{@interfaces_namespace}"><interface><name>#{escaped}</name></interface></interfaces><interfaces-state xmlns="#{@interfaces_namespace}"><interface><name>#{escaped}</name></interface></interfaces-state></filter></get>
    """
  end

  defp netconf_interface_edit(name, field, value) when field in ["description", "enabled"] do
    """
    <edit-config><target><running/></target><default-operation>merge</default-operation><error-option>rollback-on-error</error-option><config><interfaces xmlns="#{@interfaces_namespace}"><interface><name>#{xml_escape(name)}</name><#{field}>#{xml_escape(value)}</#{field}></interface></interfaces></config></edit-config>
    """
  end

  defp netconf_interface_facts(name, raw) do
    %{
      "name" => name,
      "description" => raw["description"],
      "enabled" => netconf_boolean(raw["enabled"], true),
      "admin_status" => raw["admin_status"],
      "oper_status" => raw["oper_status"],
      "input_errors" => netconf_integer(raw["input_errors"]),
      "output_errors" => netconf_integer(raw["output_errors"])
    }
  end

  defp xml_escape(value) when is_boolean(value), do: to_string(value)

  defp xml_escape(value) when is_binary(value) do
    value
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
    |> String.replace("'", "&apos;")
  end

  defp netconf_boolean("true", _default), do: true
  defp netconf_boolean("false", _default), do: false
  defp netconf_boolean(_value, default), do: default

  defp netconf_integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {number, ""} -> number
      _error -> nil
    end
  end

  defp netconf_integer(_value), do: nil
end
