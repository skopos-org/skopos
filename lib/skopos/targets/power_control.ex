defmodule Skopos.Targets.PowerControl do
  @moduledoc false

  alias Skopos.Providers.Target

  @inspect {"observe.power", "bmc.power.inspect"}
  @effects %{
    "bmc.power.on" => "on",
    "bmc.power.off" => "off",
    "bmc.power.cycle" => "on",
    "bmc.power.reset" => "on"
  }

  def capabilities do
    observation = %Target.Operation{
      capability: elem(@inspect, 0),
      operation: elem(@inspect, 1),
      description: "Read the physical host power state through its BMC",
      input_schema: request_schema(%{}, []),
      output_schema: facts_schema(),
      verification_schema: verification_schema()
    }

    effects =
      Enum.map(@effects, fn {operation, desired} ->
        %Target.Operation{
          capability: "effect.power",
          operation: operation,
          description: effect_description(operation, desired),
          input_schema:
            request_schema(
              %{
                "observed_power_state" => %{
                  "type" => "string",
                  "enum" => ["on", "off"],
                  "description" =>
                    "Current power state from the cited BMC observation, before this operation"
                }
              },
              ["observed_power_state"]
            ),
          evidence_requirements: [
            %Target.EvidenceRequirement{
              parameter: "observed_power_state",
              fact: "power_state",
              observation: elem(@inspect, 1)
            }
          ]
        }
      end)

    %Target.Capabilities{observations: [observation], effects: effects}
  end

  def inspect_request?(%{capability: capability, operation: operation} = request) do
    {capability, operation} == @inspect and request.selectors == %{} and
      request.parameters == %{}
  end

  def effect_request(%{capability: "effect.power", operation: operation} = request) do
    with {:ok, desired} <- Map.fetch(@effects, operation),
         %{"observed_power_state" => expected} <- request.parameters,
         true <- expected in ["on", "off"],
         true <- map_size(request.parameters) == 1 and request.selectors == %{} do
      {:ok, %{operation: operation, expected: expected, desired: desired}}
    else
      _ -> {:error, :failed, "BMC power request is invalid"}
    end
  end

  def effect_request(_request), do: {:error, :failed, "BMC power request is invalid"}

  def observation(power_state, system_id, source)
      when power_state in ["on", "off"] and is_binary(system_id) do
    facts = %{"power_state" => power_state, "system_id" => system_id}

    %Target.Observation{
      facts: facts,
      state_facts: %{"power_state" => power_state},
      observed_at: DateTime.utc_now(),
      evidence: [%{"source" => source, "facts" => facts}]
    }
  end

  def verification(power_state, system_id, source, expected)
      when power_state in ["on", "off"] and is_binary(system_id) do
    status =
      case expected do
        %{"power_state" => state} when state in ["on", "off"] and map_size(expected) == 1 ->
          if state == power_state, do: :verified, else: :not_verified

        _ ->
          :unknown
      end

    facts = %{"power_state" => power_state, "system_id" => system_id}

    %Target.Verification{
      status: status,
      observed_at: DateTime.utc_now(),
      facts: facts,
      evidence: [%{"source" => source, "facts" => facts}]
    }
  end

  def expected_state(needed, observed) when needed == observed, do: :ok

  def expected_state(_needed, _observed),
    do: {:error, :failed, "BMC power state changed since the cited observation"}

  defp effect_description("bmc.power.cycle", _desired),
    do: "Power cycle the physical host; power state alone cannot prove a reboot occurred"

  defp effect_description("bmc.power.reset", _desired),
    do: "Hard reset the physical host; power state alone cannot prove a reboot occurred"

  defp effect_description(operation, desired),
    do: "Set physical host power #{desired} through BMC (#{operation})"

  defp facts_schema do
    %{
      "type" => "object",
      "properties" => %{
        "power_state" => %{"type" => "string", "enum" => ["on", "off"]},
        "system_id" => %{"type" => "string", "minLength" => 1, "maxLength" => 255}
      },
      "required" => ["power_state", "system_id"],
      "additionalProperties" => false
    }
  end

  defp verification_schema do
    %{
      "type" => "object",
      "properties" => %{"power_state" => %{"type" => "string", "enum" => ["on", "off"]}},
      "required" => ["power_state"],
      "additionalProperties" => false
    }
  end

  defp request_schema(parameters, required) do
    %{
      "type" => "object",
      "properties" => %{
        "selectors" => %{
          "type" => "object",
          "properties" => %{},
          "required" => [],
          "additionalProperties" => false
        },
        "parameters" => %{
          "type" => "object",
          "properties" => parameters,
          "required" => required,
          "additionalProperties" => false
        }
      },
      "required" => ["selectors", "parameters"],
      "additionalProperties" => false
    }
  end
end
