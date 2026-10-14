defmodule Skopos.Targets.ResourceScope do
  @moduledoc false

  alias Skopos.Providers
  alias Skopos.Providers.Registry

  def key(%{provider_id: provider_id}, capability, operation, selectors)
      when is_binary(capability) and is_binary(operation) and is_map(selectors) do
    with {:ok, %{kind: :target, adapter_type: type}} <-
           Providers.get_provider(provider_id, authorize?: false),
         {:ok, adapter} <- Registry.fetch(type),
         true <- function_exported?(adapter, :resource_scope, 3),
         scope when is_binary(scope) and byte_size(scope) in 1..255 <-
           adapter.resource_scope(operation, capability, selectors) do
      scope
    else
      _unavailable -> "target"
    end
  rescue
    _error -> "target"
  end

  def key(_method, _capability, _operation, _selectors), do: "target"

  def service(unit) when is_binary(unit) do
    if unit != "" and String.trim(unit) == unit do
      name = if String.contains?(unit, "."), do: unit, else: unit <> ".service"
      "service:" <> name
    else
      "target"
    end
  end

  def service(_unit), do: "target"
end
