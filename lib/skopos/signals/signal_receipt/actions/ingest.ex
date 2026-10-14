defmodule Skopos.Signals.SignalReceipt.Actions.Ingest do
  use Ash.Resource.Actions.Implementation

  require Ash.Query

  alias Skopos.{Cases, Providers, Signals, Targets}

  alias Skopos.Cases.{
    Case,
    CaseConditionMembership,
    CaseDispatch,
    CaseEvent,
    Evidence,
    ResolutionRun
  }

  alias Skopos.Cases.Case.AdmissionLock, as: CaseAdmissionLock

  alias Skopos.Signals.{Condition, SignalCorrelation, SignalEvent, SignalReceipt}
  alias Skopos.Cases.Case.RecoveryRecheckWorker, as: RecoveryRecheckWorker

  alias Skopos.Providers.Signal

  @impl true
  def run(input, _opts, _context) do
    arguments = input.arguments

    with {:ok, %Signal.IngestResult{} = result} <-
           Providers.signal_ingest(
             arguments.provider_id,
             arguments.provider_revision,
             arguments.envelope,
             arguments.invocation,
             authorize?: false
           ),
         digest <- digest(result),
         {:ok, correlations} <- ensure_correlations(arguments.provider_id, result),
         {:ok, receipt} <- persist(arguments, result, digest, correlations) do
      {:ok, receipt}
    end
  end

  defp ensure_correlations(provider_id, result) do
    result.events
    |> Enum.sort_by(& &1.event_key)
    |> Enum.reduce_while({:ok, %{}}, fn event, {:ok, correlations} ->
      case ensure_correlation(provider_id, result.receipt.source, event.event_key) do
        {:ok, correlation} ->
          {:cont, {:ok, Map.put(correlations, event.event_key, correlation.id)}}

        {:error, _error} = error ->
          {:halt, error}
      end
    end)
  end

  defp ensure_correlation(provider_id, source, event_key) do
    case correlation(provider_id, source, event_key) do
      {:ok, %SignalCorrelation{} = existing} ->
        {:ok, existing}

      {:ok, nil} ->
        create_correlation(provider_id, source, event_key)

      {:error, _error} = error ->
        error
    end
  end

  defp create_correlation(provider_id, source, event_key) do
    case Signals.create_signal_correlation_record(
           %{
             provider_id: provider_id,
             source: source,
             event_key: event_key,
             current_state: :pending,
             revision: 1
           },
           authorize?: false
         ) do
      {:ok, correlation} ->
        {:ok, correlation}

      {:error, _error} = failed ->
        case correlation(provider_id, source, event_key) do
          {:ok, %SignalCorrelation{} = existing} -> {:ok, existing}
          _missing -> failed
        end
    end
  end

  defp persist(arguments, result, digest, correlation_ids) do
    resources = [
      SignalCorrelation,
      SignalReceipt,
      SignalEvent,
      Condition,
      Case,
      CaseConditionMembership,
      CaseDispatch,
      ResolutionRun,
      Evidence,
      CaseEvent
    ]

    transaction = fn ->
      with :ok <- CaseAdmissionLock.acquire(),
           {:ok, correlations} <- lock_correlations(correlation_ids),
           {:ok, existing} <- existing_receipt(arguments.provider_id, result.receipt.receipt_id) do
        if existing do
          validate_receipt_replay(existing, result, digest)
        else
          create_receipt_and_events(arguments, result, digest, correlations)
        end
      end
    end

    case Ash.transact(resources, transaction) do
      {:ok, {:ok, %SignalReceipt{} = receipt}} ->
        {:ok, receipt}

      {:error, _error} = failed ->
        case existing_receipt(arguments.provider_id, result.receipt.receipt_id) do
          {:ok, %SignalReceipt{} = receipt} -> validate_receipt_replay(receipt, result, digest)
          _missing -> failed
        end

      success ->
        success
    end
  end

  defp lock_correlations(correlation_ids) do
    correlation_ids
    |> Enum.sort_by(fn {event_key, _id} -> event_key end)
    |> Enum.reduce_while({:ok, %{}}, fn {event_key, id}, {:ok, locked} ->
      result =
        SignalCorrelation
        |> Ash.Query.for_read(:read)
        |> Ash.Query.filter(id: id)
        |> Ash.Query.lock(:for_update)
        |> Ash.read_one(authorize?: false)

      case result do
        {:ok, %SignalCorrelation{} = correlation} ->
          {:cont, {:ok, Map.put(locked, event_key, correlation)}}

        {:ok, nil} ->
          {:halt, {:error, "Signal correlation is unavailable"}}

        {:error, _error} = error ->
          {:halt, error}
      end
    end)
  end

  defp create_receipt_and_events(arguments, result, digest, correlations) do
    receipt = result.receipt

    with {:ok, persisted_receipt} <-
           Signals.create_signal_receipt_record(
             %{
               provider_id: arguments.provider_id,
               provider_revision: arguments.provider_revision,
               receipt_id: receipt.receipt_id,
               source: receipt.source,
               received_at: arguments.envelope.received_at,
               metadata: receipt.metadata,
               normalized_digest: digest,
               event_count: length(result.events)
             },
             authorize?: false
           ),
         {:ok, _processed} <-
           process_events(persisted_receipt, result.events, correlations) do
      {:ok, persisted_receipt}
    end
  end

  defp process_events(receipt, events, correlations) do
    events
    |> Enum.sort_by(& &1.event_key)
    |> Enum.reduce_while({:ok, []}, fn event, {:ok, processed} ->
      correlation = Map.fetch!(correlations, event.event_key)

      case process_event(receipt, event, correlation) do
        {:ok, persisted} -> {:cont, {:ok, [persisted | processed]}}
        {:error, _error} = error -> {:halt, error}
      end
    end)
  end

  defp process_event(receipt, event, correlation) do
    current? = current_event?(event, correlation)

    with {:ok, target} <- resolve_target(receipt.source, event.target_ref),
         {:ok, %{condition: condition}} <-
           Signals.record_condition_source_event(
             correlation.id,
             event.state,
             event.occurred_at,
             sequence(event.source_sequence),
             target && target.id,
             condition_subject_ref(event),
             condition_subject_key(receipt, event, target),
             condition_predicate(event),
             current?,
             authorize?: false
           ),
         {:ok, incident} <-
           case_for_condition(receipt, event, condition, current?),
         {:ok, persisted_event} <-
           create_event(receipt, event, correlation, condition, incident, target),
         {:ok, _correlation} <-
           update_correlation(correlation, persisted_event, event, current?),
         {:ok, _incident} <-
           record_case_input(incident, persisted_event, receipt, event, current?, condition) do
      {:ok, persisted_event}
    end
  end

  defp case_for_condition(_receipt, _event, nil, _current?), do: {:ok, nil}

  defp case_for_condition(receipt, event, condition, true) when event.state == :firing do
    with {:ok, %{case: incident}} <-
           Cases.assign_signal_condition(
             condition.id,
             receipt.source,
             title(event, receipt.source),
             severity(event),
             receipt.received_at,
             initial_context(event),
             authorize?: false
           ) do
      {:ok, incident}
    end
  end

  defp case_for_condition(_receipt, _event, condition, _current?) do
    with {:ok, membership} <-
           Cases.active_case_condition(condition.id,
             authorize?: false,
             not_found_error?: false
           ) do
      case membership do
        nil -> {:ok, nil}
        membership -> Cases.get_case(membership.case_id, authorize?: false)
      end
    end
  end

  defp create_event(receipt, event, correlation, condition, incident, target) do
    Signals.create_signal_event_record(
      %{
        signal_receipt_id: receipt.id,
        signal_correlation_id: correlation.id,
        condition_id: condition && condition.id,
        event_key: event.event_key,
        state: event.state,
        source_sequence: sequence(event.source_sequence),
        occurred_at: event.occurred_at,
        target_ref: json_target_ref(event.target_ref),
        attributes: event.attributes,
        metadata: event.metadata,
        case_id: incident && incident.id,
        target_id: target && target.id
      },
      authorize?: false
    )
  end

  defp record_case_input(nil, _persisted_event, _receipt, _event, _current?, _condition),
    do: {:ok, nil}

  defp record_case_input(
         %{status: status} = incident,
         _persisted_event,
         _receipt,
         _event,
         _current?,
         _condition
       )
       when status in [:resolved, :cancelled],
       do: {:ok, incident}

  defp record_case_input(incident, persisted_event, receipt, event, current?, condition) do
    with {:ok, run} <- Cases.active_resolution_run(incident.id, authorize?: false),
         {:ok, _evidence} <-
           create_evidence(incident, run, persisted_event, receipt, event, current?, condition),
         {:ok, _job} <- maybe_recheck(incident, event, current?) do
      {:ok, incident}
    end
  end

  defp maybe_recheck(%{status: :running} = incident, %{state: :recovered}, true) do
    with {:ok, job} <-
           %{"case_id" => incident.id}
           |> RecoveryRecheckWorker.new(
             scheduled_at: DateTime.add(DateTime.utc_now(), 2, :second)
           )
           |> Oban.insert(),
         true <- is_integer(job.id) || {:error, "Signal recovery recheck job was not persisted"} do
      {:ok, job}
    end
  end

  defp maybe_recheck(_incident, _event, _current?), do: {:ok, nil}

  defp create_evidence(incident, run, persisted_event, receipt, event, current?, condition) do
    key = "signal-event:#{persisted_event.id}"

    with {:ok, evidence} <-
           Cases.create_evidence_record(
             %{
               case_id: incident.id,
               resolution_run_id: run.id,
               idempotency_key: key,
               kind: "signal_event",
               source: receipt.source,
               source_ref: event.event_key,
               content: %{
                 "signal_event_id" => persisted_event.id,
                 "condition_id" => persisted_event.condition_id,
                 "condition_revision" => condition.revision,
                 "state" => to_string(event.state),
                 "current" => current?,
                 "source_sequence" => sequence(event.source_sequence),
                 "target_ref" => json_target_ref(event.target_ref),
                 "attributes" => event.attributes
               },
               observed_at: event.occurred_at
             },
             authorize?: false
           ),
         {:ok, _event} <-
           Cases.create_case_event_record(
             %{
               case_id: incident.id,
               resolution_run_id: run.id,
               event_type: "signal_event_received",
               idempotency_key: key,
               data: %{
                 "signal_event_id" => persisted_event.id,
                 "evidence_id" => evidence.id,
                 "state" => to_string(event.state),
                 "current" => current?
               }
             },
             authorize?: false
           ) do
      {:ok, evidence}
    end
  end

  defp update_correlation(correlation, persisted_event, event, true) do
    Signals.update_signal_correlation_record(
      correlation,
      correlation.revision,
      %{
        current_state: event.state,
        current_occurred_at: event.occurred_at,
        current_source_sequence: sequence(event.source_sequence),
        latest_signal_event_id: persisted_event.id
      },
      authorize?: false
    )
  end

  defp update_correlation(correlation, _persisted_event, _event, false),
    do: {:ok, correlation}

  defp resolve_target(_source, nil), do: {:ok, nil}

  defp resolve_target(source, target_ref) when is_map(target_ref) do
    with {:ok, kind} <- ref_value(target_ref, :kind),
         {:ok, value} <- ref_value(target_ref, :value),
         {:ok, identity} <-
           Targets.resolve_external_identity(source, kind, value,
             authorize?: false,
             not_found_error?: false
           ) do
      {:ok, identity && identity.target}
    else
      :missing -> {:ok, nil}
      {:error, _error} = error -> error
    end
  end

  defp resolve_target(_source, _target_ref), do: {:ok, nil}

  defp ref_value(ref, key) do
    value = Map.get(ref, key) || Map.get(ref, Atom.to_string(key))

    cond do
      is_binary(value) and byte_size(value) > 0 -> {:ok, value}
      is_atom(value) -> {:ok, Atom.to_string(value)}
      true -> :missing
    end
  end

  defp current_event?(_event, %{current_occurred_at: nil}), do: true

  defp current_event?(event, correlation) do
    case DateTime.compare(event.occurred_at, correlation.current_occurred_at) do
      :gt ->
        true

      :lt ->
        false

      :eq ->
        sequence_compare(sequence(event.source_sequence), correlation.current_source_sequence)
    end
  end

  defp sequence_compare(nil, nil), do: true
  defp sequence_compare(nil, _current), do: false
  defp sequence_compare(_incoming, nil), do: true

  defp sequence_compare(incoming, current) do
    case {Integer.parse(incoming), Integer.parse(current)} do
      {{incoming_number, ""}, {current_number, ""}} -> incoming_number >= current_number
      _other -> incoming >= current
    end
  end

  defp existing_receipt(provider_id, receipt_id) do
    Signals.signal_receipt_by_source_identity(provider_id, receipt_id,
      authorize?: false,
      not_found_error?: false
    )
  end

  defp validate_receipt_replay(receipt, result, digest) do
    if receipt.normalized_digest == digest and receipt.source == result.receipt.source and
         receipt.event_count == length(result.events) do
      {:ok, receipt}
    else
      {:error, "Signal receipt identity was reused with different normalized events"}
    end
  end

  defp correlation(provider_id, source, event_key) do
    Signals.signal_correlation_by_source(provider_id, source, event_key,
      authorize?: false,
      not_found_error?: false
    )
  end

  defp title(event, source) do
    case fact(event.attributes, "title") do
      value when is_binary(value) and byte_size(value) > 0 -> String.slice(value, 0, 200)
      _other -> String.slice("#{source}: #{event.event_key}", 0, 200)
    end
  end

  defp severity(event) do
    case fact(event.attributes, "severity") do
      value when value in [:info, :warning, :error, :critical] -> value
      "info" -> :info
      "warning" -> :warning
      "error" -> :error
      "critical" -> :critical
      _other -> :warning
    end
  end

  defp initial_context(event) do
    %{
      "signal_event_key" => event.event_key,
      "target_ref" => json_target_ref(event.target_ref)
    }
  end

  defp json_target_ref(nil), do: nil

  defp json_target_ref(ref) when is_map(ref) do
    Map.new(ref, fn {key, value} -> {to_string(key), value} end)
  end

  defp json_target_ref(_ref), do: nil

  defp fact(facts, key), do: Map.get(facts, key) || Map.get(facts, String.to_existing_atom(key))

  defp condition_subject_ref(event) do
    case fact(event.attributes, "labels") do
      labels when is_map(labels) and map_size(labels) > 0 ->
        digest = :crypto.hash(:sha256, :erlang.term_to_binary(labels, [:deterministic]))
        %{"kind" => "native_labels", "digest" => Base.encode16(digest, case: :lower)}

      _other ->
        %{}
    end
  end

  defp condition_subject_key(receipt, event, %{id: id}) do
    resource = condition_subject_ref(event)

    if map_size(resource) > 0 do
      digest = :crypto.hash(:sha256, :erlang.term_to_binary(resource, [:deterministic]))
      "target:#{id}:#{Base.encode16(digest, case: :lower)}"
    else
      # A Target hint alone may be a cluster or host containing many subjects.
      # Keep the native identity until a more specific resource is observed.
      native = {receipt.provider_id, receipt.source, event.event_key}
      digest = :crypto.hash(:sha256, :erlang.term_to_binary(native, [:deterministic]))
      "target:#{id}:native:#{Base.encode16(digest, case: :lower)}"
    end
  end

  defp condition_subject_key(receipt, event, _target) do
    # An unknown mapping must not conflate two unrelated native event streams.
    native = {receipt.provider_id, receipt.source, event.event_key, condition_subject_ref(event)}
    digest = :crypto.hash(:sha256, :erlang.term_to_binary(native, [:deterministic]))
    "native:#{Base.encode16(digest, case: :lower)}"
  end

  defp condition_predicate(event) do
    labels = fact(event.attributes, "labels") || %{}

    case Map.get(labels, "alertname") do
      value when is_binary(value) and byte_size(value) > 0 -> String.slice(value, 0, 500)
      # A display title can change between notifications for the same native
      # event. Without an explicit alarm name, preserve a stable unknown type.
      _other -> "UnclassifiedSignal"
    end
  end

  defp sequence(nil), do: nil
  defp sequence(value), do: to_string(value)

  defp digest(result) do
    binary = :erlang.term_to_binary(result, [:deterministic])

    :crypto.hash(:sha256, binary)
    |> Base.encode16(case: :lower)
  end
end
