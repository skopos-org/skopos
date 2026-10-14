defmodule Skopos.ProviderAdapterFixture do
  @behaviour Skopos.Providers.Adapter
  @behaviour Skopos.Providers.Target

  alias Skopos.Providers.Target
  alias Skopos.Targets.ResourceScope

  @observation_operations ~w(
    filesystem.read filesystem.verify generic.inspect linux.identity.inspect
    linux.service.inspect service.inspect system.inspect
  )
  @effect_operations ~w(
    bmc.power.reset command.execute filesystem.delete interface.shutdown
    service.restart linux.service.restart
  )

  @impl true
  def type, do: "fixture-target"

  @impl true
  def kind, do: :target

  @impl Skopos.Providers.Target
  def access_method_profile, do: :unrestricted

  @impl Skopos.Providers.Target
  def resource_scope(operation, capability, selectors)
      when operation in [
             "service.restart",
             "service.inspect",
             "linux.service.restart",
             "linux.service.inspect"
           ] and
             capability in ["effect.service", "observe.service"] and is_map(selectors) do
    case selectors do
      %{"unit" => unit} when map_size(selectors) == 1 -> ResourceScope.service(unit)
      %{"service" => unit} when map_size(selectors) == 1 -> ResourceScope.service(unit)
      _other -> "target"
    end
  end

  def resource_scope(_operation, _capability, _selectors), do: "target"

  @impl true
  def build(%{"endpoint" => endpoint}, %{"token" => token})
      when is_binary(endpoint) and is_binary(token) do
    {:ok, %{endpoint: endpoint, token: token}}
  end

  def build(_configuration, _credentials), do: {:error, :invalid_configuration}

  @impl true
  def check(%{endpoint: "reachable"}, %{"fail" => true}),
    do: {:error, :unreachable, "fixture unreachable"}

  def check(%{endpoint: "reachable"}, _input), do: :ok

  def check(%{endpoint: "echo", token: token}, _input),
    do: {:error, :authentication, "credential #{token} was rejected"}

  def check(%{endpoint: "invalid_response"}, _input), do: :invalid

  def check(%{endpoint: category}, _input)
      when category in ["authentication", "unreachable", "capability"] do
    {:error, String.to_existing_atom(category), "fixture #{category}"}
  end

  def check(_state, _input), do: {:error, :capability, "unsupported fixture endpoint"}

  @impl Skopos.Providers.Target
  def bind_connection(state, connection), do: {:ok, Map.put(state, :connection, connection)}

  @impl Skopos.Providers.Target
  def capabilities(state, invocation) do
    notify(invocation, {:capabilities, state})
    respond(invocation)
  end

  @impl Skopos.Providers.Target
  def classify_request(_state, request) do
    cond do
      request.operation in @observation_operations -> {:ok, :observation}
      request.operation in @effect_operations -> {:ok, :effect}
      true -> {:error, :failed, "Fixture Target request is invalid"}
    end
  end

  @impl Skopos.Providers.Target
  def observe(state, request, invocation) do
    notify(invocation, {:observe, state, request})
    respond(invocation)
  end

  @impl Skopos.Providers.Target
  def effect(state, request, invocation) do
    notify(invocation, {:effect, state, request})
    respond(invocation)
  end

  @impl Skopos.Providers.Target
  def verify(state, request, invocation) do
    notify(invocation, {:verify, state, request})
    respond(invocation)
  end

  defp notify(%{test_pid: pid}, message), do: send(pid, message)
  defp notify(_invocation, _message), do: :ok

  defp respond(%{respond: respond}) when is_function(respond, 0), do: respond.()

  defp respond(%{respond: respond} = invocation) when is_function(respond, 1),
    do: respond.(invocation)

  defp respond(_invocation) do
    # Protocol fixture support is independent of each registered Method's grants.
    schema = %{"type" => "object", "properties" => %{}, "additionalProperties" => false}

    operations = fn capabilities ->
      Enum.map(capabilities, fn capability ->
        %Target.Operation{
          capability: capability,
          operation: "fixture.#{capability}",
          description: "Fixture operation",
          input_schema: schema,
          output_schema: schema
        }
      end)
    end

    {:ok,
     %Target.Capabilities{
       observations:
         operations.(
           ~w(observe.command observe.config observe.identity observe.power observe.service observe.system)
         ),
       effects: operations.(~w(effect.command effect.config effect.power effect.service))
     }}
  end
end
