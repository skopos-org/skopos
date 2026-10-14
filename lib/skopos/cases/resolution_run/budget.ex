defmodule Skopos.Cases.ResolutionRun.Budget do
  require Ash.Query

  alias Skopos.Cases
  alias Skopos.Cases.{Case, CaseEvent, ResolutionRun}
  alias Skopos.Cases.Case.AdmissionLock, as: CaseAdmissionLock
  alias Skopos.Cases.ResolutionRun.BudgetResult

  @counter_fields [
    :turn_count,
    :target_request_count,
    :effect_count,
    :related_target_count,
    :ai_usage_units,
    :no_progress_turns
  ]

  @spec consume(keyword()) :: {:ok, BudgetResult.t()} | {:error, term()}
  def consume(opts) do
    Ash.transact([Case, ResolutionRun, CaseEvent], fn -> consume_locked(opts) end)
  end

  def key(namespace, raw_key) do
    digest = :crypto.hash(:sha256, raw_key) |> Base.encode16(case: :lower)
    "#{namespace}:#{digest}"
  end

  defp consume_locked(opts) do
    with :ok <- admission_lock(opts),
         {:ok, incident} <- lock_case(opts[:case_id]),
         {:ok, run} <- lock_run(opts[:resolution_run_id], incident.id, opts[:kind]),
         {:ok, event} <- existing_event(incident.id, opts[:ledger_key]) do
      if event do
        replay_result(incident, run, event, opts)
      else
        consume_new(incident, run, opts)
      end
    end
  end

  defp admission_lock(opts) do
    if opts[:admission_lock?], do: CaseAdmissionLock.acquire(), else: :ok
  end

  defp replay_result(incident, run, event, opts) do
    with :ok <- validate_replay(run, event, opts) do
      if event.event_type == "limit_exhausted" do
        %BudgetResult{
          status: :exhausted,
          case: incident,
          run: run,
          reason: incident.stop_reason
        }
      else
        duplicate_result(incident, run, opts)
      end
    end
  end

  defp validate_replay(run, event, opts) do
    if event.resolution_run_id == run.id and
         replay_input_matches?(event, opts) and replay_data_matches?(event, opts) do
      :ok
    else
      invalid("Idempotency key was already used with different budget input")
    end
  end

  defp replay_input_matches?(%CaseEvent{event_type: "limit_exhausted", data: data}, opts) do
    data["attempted_kind"] == to_string(opts[:kind]) and
      data["attempted_amount"] == opts[:amount]
  end

  defp replay_input_matches?(%CaseEvent{event_type: type, data: data}, opts) do
    type == opts[:event_type] and data["kind"] == to_string(opts[:kind]) and
      data["amount"] == opts[:amount]
  end

  defp replay_data_matches?(event, opts) do
    opts
    |> Keyword.get(:event_data, %{})
    |> Enum.all?(fn {key, value} -> event.data[key] == value end)
  end

  defp consume_new(incident, run, opts) do
    if stopped_usage?(incident, run, opts) do
      charge(incident, run, opts)
    else
      with :ok <- ensure_running(incident, run) do
        case exhausted_limit(run, opts[:kind], opts[:amount], DateTime.utc_now()) do
          nil -> charge(incident, run, opts)
          limit -> exhaust(incident, run, limit, opts)
        end
      end
    end
  end

  defp stopped_usage?(incident, run, opts),
    do:
      opts[:kind] == :ai_usage and
        (incident.cancel_requested or incident.status != :running or
           not run.active or run.status != :running)

  defp charge(incident, run, opts) do
    with {:ok, updated_run} <-
           update_counters(incident, run, opts),
         {:ok, value} <- opts[:operation].(incident, updated_run),
         {:ok, _event} <-
           create_event(
             incident,
             updated_run,
             opts[:actor],
             opts[:event_type],
             opts[:ledger_key],
             event_data(opts, updated_run, value)
           ) do
      %BudgetResult{status: :charged, case: incident, run: updated_run, value: value}
    end
  end

  defp update_counters(incident, run, opts) do
    if stopped_usage?(incident, run, opts) do
      Cases.record_resolution_run_ai_usage(run, run.revision, opts[:amount], authorize?: false)
    else
      Cases.update_resolution_run_counters(
        run,
        run.revision,
        next_counters(run, opts[:kind], opts[:amount]),
        authorize?: false
      )
    end
  end

  defp exhaust(incident, run, limit, opts) do
    with {:ok, run} <- account_exhausted_usage(run, opts[:kind], opts[:amount]),
         {:ok, updated_case} <-
           Cases.mark_case_budget_exhausted(
             incident,
             incident.revision,
             run.id,
             run.revision,
             limit_reason(limit),
             limit,
             opts[:kind],
             opts[:amount],
             opts[:ledger_key],
             opts[:pending_intent],
             opts[:required_human_input],
             Keyword.get(opts, :event_data, %{}),
             actor: opts[:actor],
             authorize?: false
           ),
         {:ok, paused_run} <- Cases.active_resolution_run(incident.id, authorize?: false) do
      %BudgetResult{
        status: :exhausted,
        case: updated_case,
        run: paused_run,
        reason: updated_case.stop_reason
      }
    end
  end

  defp account_exhausted_usage(run, :ai_usage, amount),
    do: Cases.record_resolution_run_ai_usage(run, run.revision, amount, authorize?: false)

  defp account_exhausted_usage(run, _kind, _amount), do: {:ok, run}

  defp duplicate_result(incident, run, opts) do
    with {:ok, value} <- opts[:duplicate].(incident, run) do
      %BudgetResult{status: :duplicate, case: incident, run: run, value: value}
    end
  end

  defp lock_case(id) do
    Case
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(id: id)
    |> Ash.Query.lock(:for_update)
    |> Ash.read_one(authorize?: false)
    |> required("Case is unavailable")
  end

  defp lock_run(id, case_id, kind) do
    query =
      ResolutionRun
      |> Ash.Query.for_read(:read)
      |> Ash.Query.filter(id: id, case_id: case_id)

    query = if kind == :ai_usage, do: query, else: Ash.Query.filter(query, active: true)

    query
    |> Ash.Query.lock(:for_update)
    |> Ash.read_one(authorize?: false)
    |> required("ResolutionRun is unavailable")
  end

  defp required({:ok, nil}, message), do: invalid(message)
  defp required(result, _message), do: result

  defp existing_event(case_id, key) do
    Cases.case_event_by_idempotency(case_id, key,
      authorize?: false,
      not_found_error?: false
    )
  end

  defp ensure_running(%{cancel_requested: true}, _run),
    do: invalid("Case cancellation was requested")

  defp ensure_running(%{status: :running}, %{status: :running}), do: :ok
  defp ensure_running(_incident, _run), do: invalid("Case resolution is not running")

  defp exhausted_limit(run, kind, amount, now) do
    cond do
      DateTime.compare(now, run.deadline_at) in [:eq, :gt] ->
        :elapsed

      run.no_progress_turns >= run.max_no_progress_turns ->
        :no_progress

      kind == :repeated_observation ->
        :repeated_observation

      true ->
        case limit(kind) do
          nil ->
            nil

          {counter, maximum} ->
            if Map.fetch!(run, counter) + amount > Map.fetch!(run, maximum), do: kind
        end
    end
  end

  defp limit(:turn), do: {:turn_count, :max_resolver_turns}
  defp limit(:target_request), do: {:target_request_count, :max_target_requests}
  defp limit(:effect), do: {:effect_count, :max_effects}
  defp limit(:related_target), do: {:related_target_count, :max_related_targets}
  defp limit(:ai_usage), do: {:ai_usage_units, :max_ai_usage_units}
  defp limit(:no_progress), do: nil
  defp limit(:progress), do: nil
  defp limit(:pending_result), do: nil

  defp next_counters(run, :progress, _amount) do
    run |> current_counters() |> Map.put(:no_progress_turns, 0)
  end

  defp next_counters(run, :no_progress, amount) do
    Map.update!(current_counters(run), :no_progress_turns, &(&1 + amount))
  end

  defp next_counters(run, :pending_result, _amount), do: current_counters(run)

  defp next_counters(run, kind, amount) do
    {counter, _maximum} = limit(kind)
    Map.update!(current_counters(run), counter, &(&1 + amount))
  end

  defp current_counters(run), do: Map.take(run, @counter_fields)

  defp event_data(opts, run, value) do
    base =
      opts
      |> Keyword.get(:event_data, %{})
      |> Map.merge(%{
        "kind" => to_string(opts[:kind]),
        "amount" => opts[:amount],
        "run_revision" => run.revision
      })

    case value do
      %{id: id} -> Map.put(base, "record_id", id)
      _other -> base
    end
  end

  defp create_event(incident, run, actor, event_type, key, data) do
    Cases.create_case_event_record(
      %{
        case_id: incident.id,
        resolution_run_id: run.id,
        actor_id: actor && actor.id,
        event_type: event_type,
        idempotency_key: key,
        data: data
      },
      authorize?: false
    )
  end

  defp limit_reason(:elapsed), do: "Resolution elapsed-time limit exhausted"
  defp limit_reason(:turn), do: "Resolver turn limit exhausted"
  defp limit_reason(:target_request), do: "Target request limit exhausted"
  defp limit_reason(:effect), do: "Remote effect limit exhausted"
  defp limit_reason(:related_target), do: "Related Target limit exhausted"
  defp limit_reason(:ai_usage), do: "AI usage limit exhausted"
  defp limit_reason(:no_progress), do: "No-progress turn limit exhausted"

  defp limit_reason(:repeated_observation),
    do: "Repeated identical Target observation limit exhausted"

  defp invalid(message),
    do: {:error, Ash.Error.Changes.InvalidChanges.exception(message: message)}
end
