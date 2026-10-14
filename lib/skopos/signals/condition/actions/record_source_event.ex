defmodule Skopos.Signals.Condition.Actions.RecordSourceEvent do
  use Ash.Resource.Actions.Implementation

  alias Skopos.Signals

  @impl true
  def run(input, _opts, _context) do
    args = input.arguments

    with {:ok, latest_any} <-
           Signals.latest_condition_for_correlation(args.signal_correlation_id,
             authorize?: false,
             not_found_error?: false
           ),
         {:ok, latest_identity} <-
           Signals.latest_condition_for_identity(
             args.signal_correlation_id,
             args.subject_key,
             args.predicate,
             authorize?: false,
             not_found_error?: false
           ) do
      if same_identity?(latest_identity, args) do
        record(latest_identity, latest_any, args)
      else
        record(nil, latest_any, args)
      end
    end
  end

  defp same_identity?(nil, _args), do: true

  defp same_identity?(condition, args) do
    condition.target_id == args.target_id and condition.subject_ref == args.subject_ref
  end

  # SignalReceipt ingestion holds the corresponding SignalCorrelation row lock for this action.
  # A stale event is retained as native history, but cannot be assigned to a
  # newer occurrence when its original occurrence is uncertain.
  defp record(_latest_identity, _latest_any, %{current: false}), do: {:ok, %{condition: nil}}
  defp record(nil, _latest_any, %{state: :recovered}), do: {:ok, %{condition: nil}}

  defp record(%{state: :recovered} = latest, _latest_any, %{state: :recovered}),
    do: {:ok, %{condition: latest}}

  defp record(%{state: :firing} = latest, _latest_any, %{state: :firing} = args),
    do: update(latest, args)

  defp record(%{state: :firing} = latest, _latest_any, %{state: :recovered} = args),
    do: update(latest, args)

  defp record(_latest_identity, latest_any, %{state: :firing} = args) do
    with {:ok, condition} <-
           Signals.create_condition_record(
             %{
               signal_correlation_id: args.signal_correlation_id,
               target_id: args.target_id,
               occurrence: if(latest_any, do: latest_any.occurrence + 1, else: 1),
               predicate: args.predicate,
               subject_key: args.subject_key,
               subject_ref: args.subject_ref,
               state: :firing,
               first_fired_at: args.occurred_at,
               current_occurred_at: args.occurred_at,
               current_source_sequence: args.source_sequence
             },
             authorize?: false
           ) do
      {:ok, %{condition: condition}}
    end
  end

  defp update(latest, args) do
    with {:ok, condition} <-
           Signals.record_condition_state(
             latest,
             latest.revision,
             %{
               state: args.state,
               current_occurred_at: args.occurred_at,
               current_source_sequence: args.source_sequence
             },
             authorize?: false
           ) do
      {:ok, %{condition: condition}}
    end
  end
end
