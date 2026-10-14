defmodule Skopos.Providers.Registry do
  @moduledoc false

  alias Skopos.Providers.{Adapter, Target}

  @kinds [:ai, :signal, :target, :inventory, :notification]
  @check_failures [
    :invalid_configuration,
    :authentication,
    :unreachable,
    :capability,
    :provider_failure
  ]

  def fetch(type) when is_binary(type) do
    case Enum.filter(adapters(), &(valid?(&1) and &1.type() == type)) do
      [adapter] -> {:ok, adapter}
      [] -> {:error, :unknown_adapter}
      _duplicates -> {:error, :duplicate_adapter}
    end
  end

  def fetch(_type), do: {:error, :unknown_adapter}

  def fetch(type, behaviour) when is_atom(behaviour) do
    with {:ok, adapter} <- fetch(type),
         true <- implements?(adapter, behaviour) do
      {:ok, adapter}
    else
      {:error, reason} -> {:error, reason}
      false -> {:error, :unsupported_kind}
    end
  end

  def kind(adapter), do: adapter.kind()

  def build(adapter, configuration, credentials)
      when is_atom(adapter) and is_map(configuration) and is_map(credentials) do
    case adapter.build(configuration, credentials) do
      {:ok, state} -> {:ok, state}
      {:error, reason} -> {:error, reason}
      _other -> {:error, :invalid_adapter_response}
    end
  rescue
    _error -> {:error, :invalid_adapter_configuration}
  catch
    _kind, _reason -> {:error, :invalid_adapter_configuration}
  end

  def build(_adapter, _configuration, _credentials),
    do: {:error, :invalid_adapter_configuration}

  def check(adapter, state, input) when is_atom(adapter) and is_map(input) do
    case adapter.check(state, input) do
      :ok ->
        :ok

      {:error, category, message} when category in @check_failures and is_binary(message) ->
        {:error, category, message}

      _other ->
        {:error, :provider_failure, "Provider check failed"}
    end
  rescue
    _error -> {:error, :provider_failure, "Provider check failed"}
  catch
    _kind, _reason -> {:error, :provider_failure, "Provider check failed"}
  end

  defp adapters, do: Application.get_env(:skopos, :provider_adapters, [])

  defp valid?(adapter) do
    Code.ensure_loaded?(adapter) and
      Adapter in behaviours(adapter) and
      function_exported?(adapter, :type, 0) and
      function_exported?(adapter, :kind, 0) and
      function_exported?(adapter, :build, 2) and
      function_exported?(adapter, :check, 2) and
      adapter.kind() in @kinds and
      (adapter.kind() != :target or implements?(adapter, Target))
  end

  defp behaviours(adapter) do
    adapter.module_info(:attributes)
    |> Keyword.get_values(:behaviour)
    |> List.flatten()
  end

  defp implements?(adapter, behaviour) do
    if Code.ensure_loaded?(behaviour) and behaviour in behaviours(adapter) do
      optional = MapSet.new(behaviour.behaviour_info(:optional_callbacks))

      Enum.all?(behaviour.behaviour_info(:callbacks), fn {callback, arity} ->
        MapSet.member?(optional, {callback, arity}) or
          function_exported?(adapter, callback, arity)
      end)
    else
      false
    end
  end
end
