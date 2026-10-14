defmodule Skopos.Cases.Case.InvocationContext do
  @moduledoc false

  @enforce_keys [
    :case_id,
    :case_revision,
    :resolution_run_id,
    :run_generation,
    :subject,
    :conditions,
    :targets,
    :methods,
    :selection
  ]
  defstruct @enforce_keys
  @type t :: %__MODULE__{}
  @reconcile_ms 200

  def project(incident, run, subject, conditions, selection, methods) do
    methods =
      methods
      |> Enum.map(
        &Map.take(&1, [
          :target_id,
          :target_revision,
          :access_method_id,
          :access_method_revision,
          :provider_id,
          :provider_revision,
          :capability
        ])
      )
      |> Enum.uniq()

    selected =
      if incident.selected_target_id,
        do: [%{id: incident.selected_target_id, revision: incident.selected_target_revision}],
        else: []

    %__MODULE__{
      case_id: incident.id,
      case_revision: incident.revision,
      resolution_run_id: run.id,
      run_generation: run.generation,
      subject: subject,
      conditions: Skopos.Cases.Case.ConditionContext.condition_revisions(conditions),
      targets:
        Enum.uniq(
          selected ++ Enum.map(methods, &%{id: &1.target_id, revision: &1.target_revision})
        ),
      methods: methods,
      selection: selection
    }
  end

  # Ash owns the current facts. This scope only bounds their observation while
  # native tasks wait; a cached observation can never authorize another send.
  def with_invocation(context, supplied, dispatch) do
    table = :ets.new(__MODULE__, [:set, :public, read_concurrency: true])
    poll = :atomics.new(2, [])
    :atomics.put(poll, 1, System.monotonic_time(:millisecond))
    cancelled = Map.get(supplied, :cancelled?, fn -> false end)
    before_send = Map.get(supplied, :before_send?, cancelled)

    try do
      supplied
      |> Map.put(:cancelled?, fn ->
        observe(table, fn ->
          cancelled.() == true or reconcile(context, poll)
        end)
      end)
      |> Map.put(:before_send?, fn ->
        observe(table, fn -> before_send.() == true or changed?(context) end)
      end)
      |> dispatch.()
    after
      :ets.delete(table)
    end
  end

  defp reconcile(context, poll) do
    if System.monotonic_time(:millisecond) >= :atomics.get(poll, 1) and
         :atomics.compare_exchange(poll, 2, 0, 1) == :ok do
      try do
        if System.monotonic_time(:millisecond) >= :atomics.get(poll, 1) do
          try do
            changed?(context)
          after
            :atomics.put(poll, 1, System.monotonic_time(:millisecond) + @reconcile_ms)
          end
        else
          false
        end
      after
        :atomics.put(poll, 2, 0)
      end
    else
      false
    end
  end

  defp changed?(context),
    do: not Skopos.Cases.invocation_context_current!(context, authorize?: false)

  defp observe(table, check) do
    case :ets.lookup(table, :terminal) do
      [{:terminal, result}] ->
        return_observation(result)

      [] ->
        result =
          try do
            {:ok, check.()}
          catch
            kind, cause -> {:error, kind, cause, __STACKTRACE__}
          end

        if result != {:ok, false}, do: :ets.insert_new(table, {:terminal, result})

        # Another native task may have observed a stop during this read.
        case :ets.lookup(table, :terminal) do
          [{:terminal, terminal}] -> return_observation(terminal)
          [] -> return_observation(result)
        end
    end
  end

  defp return_observation({:ok, value}), do: value
  defp return_observation({:error, kind, cause, stack}), do: :erlang.raise(kind, cause, stack)
end
