defmodule Skopos.Cases.Operation.Delivery do
  @moduledoc false

  alias Skopos.{Cases, Targets}

  alias Skopos.Cases.{
    Case,
    CaseEvent,
    Operation,
    ResolutionRun,
    Turn
  }

  alias Skopos.Cases.Operation.Claim, as: OperationClaim
  alias Skopos.Cases.ResolutionRun.Budget, as: Budget
  alias Skopos.Cases.ResolutionRun.BudgetResult

  alias Skopos.Providers.Target, as: ProviderTarget

  @terminal [:applied, :failed, :partial, :unknown]

  def run(operation_id, opts \\ []) do
    case Cases.claim_operation_dispatch(operation_id, authorize?: false) do
      {:ok, %OperationClaim{state: :claimed} = claim} ->
        dispatch(claim, opts)

      {:ok, %OperationClaim{state: :deferred, operation: operation}} ->
        remaining = DateTime.diff(operation.not_before, DateTime.utc_now(), :millisecond)
        {:snooze, if(remaining > 0, do: div(remaining + 999, 1000), else: 5)}

      {:ok, %OperationClaim{state: :terminal, operation: operation}} ->
        handoff(operation)

      {:error, error} ->
        {:error, error}
    end
  end

  defp dispatch(
         %OperationClaim{
           operation: operation,
           actor: actor,
           clearance: clearance,
           invocation_context: context
         },
         opts
       ) do
    invocation =
      Map.put(
        Keyword.get(opts, :target_invocation, %{}),
        :result_reference_reader,
        fn reference ->
          Cases.read_operation_result_reference(reference, operation.case_id, clearance,
            actor: actor
          )
        end
      )

    outcome =
      Skopos.Cases.Case.InvocationContext.with_invocation(context, invocation, fn supplied ->
        dispatch_target(operation, clearance, supplied, actor)
      end)
      |> returned_context(context)

    case outcome do
      {:error, %ProviderTarget.BeforeSendError{} = error} -> unsent(operation, error)
      outcome -> persist_and_handoff(operation, outcome)
    end
  end

  defp returned_context(%{context_failure: _cause} = outcome, _context), do: outcome

  defp returned_context(%{status: _status} = outcome, context) do
    case Cases.invocation_context_current(context, authorize?: false) do
      {:ok, true} -> outcome
      {:ok, false} -> %{outcome | category: "authorization_invalidated"}
      {:error, cause} -> Map.put(outcome, :context_failure, cause)
    end
  end

  defp returned_context(outcome, _context), do: outcome

  defp dispatch_target(%{request_kind: :observation}, clearance, invocation, actor) do
    case Targets.dispatch_target_observation(clearance, invocation,
           actor: actor,
           authorize?: false
         ) do
      {:ok, %ProviderTarget.Observation{} = result} ->
        normalize(result)

      {:error, error} ->
        case ProviderTarget.BeforeSendError.unwrap(error) do
          nil -> with_context_failure(failed_observation(error), error)
          unsent -> {:error, unsent}
        end
    end
  end

  defp dispatch_target(%{request_kind: :effect}, clearance, invocation, actor) do
    case Targets.dispatch_target_effect(clearance, invocation,
           actor: actor,
           authorize?: false
         ) do
      {:ok, %ProviderTarget.EffectResult{} = result} ->
        normalize(result)

      {:error, error} ->
        case ProviderTarget.BeforeSendError.unwrap(error) do
          nil ->
            unknown("dispatch_error", "Target dispatch result is unknown")
            |> with_context_failure(error)

          unsent ->
            {:error, unsent}
        end
    end
  end

  defp unsent(operation, error) do
    if ProviderTarget.BeforeSendError.retryable?(error) do
      case Cases.retry_unsent_operation(operation, operation.revision, error, authorize?: false) do
        {:ok, _queued} -> {:error, error.cause}
        {:error, save_error} -> {:error, Ash.Error.to_error_class([error.cause, save_error])}
      end
    else
      case Cases.record_operation_no_send(
             operation,
             operation.revision,
             %{
               before_send_failure: error,
               outcome_category: "input_unavailable",
               result_details: %{"message" => "Target request input is unavailable"},
               completed_at: DateTime.utc_now()
             },
             authorize?: false
           ) do
        {:ok, terminal} -> handoff(terminal)
        {:error, save_error} -> {:error, Ash.Error.to_error_class([error.cause, save_error])}
      end
    end
  end

  defp with_context_failure(outcome, error) do
    if ProviderTarget.Error.context_failure?(error) do
      outcome =
        case ProviderTarget.Error.context_progress(error) do
          nil -> outcome
          progress -> %{outcome | details: Map.put(outcome.details, "progress", progress)}
        end

      Map.put(outcome, :context_failure, error)
    else
      outcome
    end
  end

  defp persist_and_handoff(operation, %{context_failure: cause} = outcome) do
    case persist_and_handoff(operation, Map.delete(outcome, :context_failure)) do
      :ok -> {:error, cause}
      {:error, error} -> {:error, Ash.Error.to_error_class([cause, error])}
      other -> other
    end
  end

  defp persist_and_handoff(operation, outcome) do
    with {:ok, terminal} <-
           Cases.record_operation_outcome(
             operation,
             operation.revision,
             %{
               status: outcome.status,
               outcome_category: outcome.category,
               reference:
                 if(Map.get(outcome, :protected_reference),
                   do: operation.id,
                   else: outcome.reference
                 ),
               protected_reference: Map.get(outcome, :protected_reference),
               result_details: outcome.details,
               completed_at: DateTime.utc_now()
             },
             authorize?: false
           ) do
      handoff(terminal)
    end
  end

  defp normalize(%ProviderTarget.EffectResult{} = result) do
    %{
      status: result.status,
      category: "target_#{result.status}",
      reference: result.reference,
      protected_reference: result.protected_reference,
      details: result.details
    }
  end

  defp normalize(%ProviderTarget.Observation{} = result) do
    %{
      status: :applied,
      category: "target_observed",
      reference: nil,
      details: ProviderTarget.Observation.details(result)
    }
  end

  defp failed_observation(error) do
    %{
      status: :failed,
      category: "observation_failed",
      reference: nil,
      details:
        %{"message" => observation_failure_message(error)}
        |> maybe_put_provider_category(observation_failure_category(error))
    }
  rescue
    _error ->
      %{status: :failed, category: "observation_failed", reference: nil, details: %{}}
  end

  defp observation_failure_message(%ProviderTarget.Error{message: message}), do: message

  defp observation_failure_message(%{errors: errors}) when is_list(errors) do
    Enum.find_value(errors, &target_error_message/1) || "Target observation failed"
  end

  defp observation_failure_message(error), do: Exception.message(error)

  defp observation_failure_category(%ProviderTarget.Error{category: category}),
    do: category

  defp observation_failure_category(%{errors: errors}) when is_list(errors),
    do: Enum.find_value(errors, &observation_failure_category/1)

  defp observation_failure_category(_error), do: nil

  defp maybe_put_provider_category(details, category)
       when category in [:retryable, :timeout, :failed, :cancelled],
       do: Map.put(details, "provider_category", Atom.to_string(category))

  defp maybe_put_provider_category(details, _category), do: details

  defp target_error_message(%ProviderTarget.Error{message: message}), do: message

  defp target_error_message(%{errors: errors}) when is_list(errors),
    do: Enum.find_value(errors, &target_error_message/1)

  defp target_error_message(_error), do: nil

  defp unknown(category, message) do
    %{status: :unknown, category: category, reference: nil, details: %{"message" => message}}
  end

  defp handoff(%Operation{status: status} = operation) when status in @terminal do
    case Cases.get_case(operation.case_id, authorize?: false) do
      {:ok, %{status: :running, cancel_requested: false}} -> handoff_running(operation)
      {:ok, _stopped} -> :ok
      {:error, error} -> {:error, error}
    end
  end

  defp handoff(_operation), do: {:error, "Operation has no terminal outcome"}

  defp handoff_running(operation) do
    with {:ok, proposal} <- Cases.get_proposal(operation.proposal_id, authorize?: false),
         {:ok, evidence} <-
           Cases.append_evidence(
             operation.case_id,
             operation.resolution_run_id,
             evidence_turn_id(operation, proposal),
             "operation:outcome:#{operation.id}",
             evidence_kind(operation),
             "operation",
             operation.id,
             %{"target_id" => operation.target_id},
             operation.completed_at,
             authorize?: false
           ),
         {:ok, progress} <- account_observation_progress(operation),
         {:ok, incident} <- Cases.get_case(operation.case_id, authorize?: false) do
      if progress == :exhausted or incident.status != :running,
        do: :ok,
        else: continue_handoff(operation, proposal, evidence, incident)
    end
  end

  defp account_observation_progress(%Operation{purpose: :investigation} = operation) do
    case Cases.account_observation_progress(operation.id, authorize?: false) do
      {:ok, %BudgetResult{status: :exhausted}} ->
        {:ok, :exhausted}

      {:ok, %BudgetResult{status: status}} when status in [:charged, :duplicate] ->
        {:ok, :continue}

      {:error, _error} = error ->
        error
    end
  end

  defp account_observation_progress(_operation), do: {:ok, :continue}

  defp continue_handoff(
         %{outcome_category: category} = operation,
         _proposal,
         _evidence,
         incident
       )
       when category in ["source_context_changed", "target_effect_changed"] do
    if incident.pending_intent["source_operation_id"] == operation.id and
         incident.pending_intent["action"] == "resolve_turn",
       do: :ok,
       else: {:error, "Stale Operation has no reassessment Turn"}
  end

  defp continue_handoff(
         %{outcome_category: "authorization_invalidated", id: operation_id},
         _proposal,
         _evidence,
         %{pending_intent: %{"action" => "resolve_turn", "source_operation_id" => operation_id}}
       ),
       do: :ok

  defp continue_handoff(
         %{outcome_category: "authorization_invalidated"} = operation,
         _proposal,
         _evidence,
         incident
       ) do
    with {:ok, target} <- Targets.get_target(operation.target_id, authorize?: false),
         true <- target.active and incident.selected_target_id == target.id,
         {:ok, current} <- refresh_selected_target(incident, target),
         {:ok, run} <- Cases.get_resolution_run(operation.resolution_run_id, authorize?: false),
         {:ok, started} <-
           Cases.start_turn(
             current.id,
             run.id,
             Budget.key("operation:authorization-changed", operation.id),
             %{
               "objective" => "Reassess this Target under its current operating instructions",
               "source_operation_id" => operation.id
             },
             %{"action" => "continue_resolution", "source_operation_id" => operation.id},
             "Review Resolver limits",
             authorize?: false
           ) do
      case started do
        %{status: :exhausted} ->
          :ok

        %{status: status, case: updated, value: turn} when status in [:charged, :duplicate] ->
          case Cases.handoff_case_operation(
                 updated,
                 updated.revision,
                 operation.id,
                 :stale_dispatch,
                 turn.id,
                 nil,
                 nil,
                 authorize?: false
               ) do
            {:ok, _case} -> :ok
            {:error, _error} = error -> error
          end
      end
    else
      false -> {:error, "Target changed before Operation reassessment"}
      {:error, _error} = error -> error
    end
  end

  defp continue_handoff(
         %{status: :failed, dispatch_started_at: nil} = operation,
         proposal,
         evidence,
         incident
       ) do
    continue_with_result(operation, proposal, evidence, incident)
  end

  defp continue_handoff(
         %{purpose: :remediation} = operation,
         %{verification_intent: intent, verification_tool: tool} = proposal,
         evidence,
         incident
       )
       when map_size(intent) == 0 and map_size(tool) == 0 do
    continue_with_result(operation, proposal, evidence, incident)
  end

  defp continue_handoff(%{purpose: :remediation} = operation, _proposal, _evidence, incident) do
    pending = %{
      "action" => "verify_operation",
      "operation_id" => operation.id,
      "proposal_id" => operation.proposal_id
    }

    result =
      if incident.pending_intent == pending do
        {:ok, incident}
      else
        Cases.handoff_case_operation(
          incident,
          incident.revision,
          operation.id,
          :verification,
          nil,
          nil,
          nil,
          authorize?: false
        )
      end

    case result do
      {:ok, _case} ->
        accept_verification(operation)

      {:error, _error} = conflict ->
        case Cases.verification_attempt_by_operation(operation.id,
               authorize?: false,
               not_found_error?: false
             ) do
          {:ok, %Skopos.Cases.VerificationAttempt{}} -> :ok
          _missing -> conflict
        end
    end
  end

  defp continue_handoff(
         %{purpose: :investigation} = operation,
         proposal,
         evidence,
         incident
       ) do
    continue_with_result(operation, proposal, evidence, incident)
  end

  defp continue_with_result(operation, proposal, evidence, incident) do
    Ash.transact([Case, ResolutionRun, Turn, CaseEvent], fn ->
      with {:ok, source_turn} <- Cases.get_turn(proposal.source_turn_id, authorize?: false),
           {:ok, result} <-
             Cases.start_turn(
               operation.case_id,
               operation.resolution_run_id,
               "operation:result:next-turn:#{operation.id}",
               result_turn_intent(source_turn, evidence),
               %{"action" => "continue_resolution", "operation_id" => operation.id},
               "Review Resolver limits or continue the Case manually",
               authorize?: false
             ) do
        set_result_pending(operation, proposal, evidence, incident, result)
      end
    end)
    |> case do
      {:ok, :ok} -> :ok
      {:error, _error} = error -> error
    end
  end

  defp refresh_selected_target(%{selected_target_revision: revision} = incident, %{
         revision: revision
       }),
       do: {:ok, incident}

  defp refresh_selected_target(incident, target) do
    Cases.record_case_selected_target(
      incident,
      incident.revision,
      target.id,
      target.revision,
      authorize?: false
    )
  end

  defp result_turn_intent(source_turn, evidence) do
    intent = %{
      "objective" => "Assess the actual Target result and obtain further evidence if needed",
      "source" => "target_result",
      "source_turn_id" => source_turn.id,
      "evidence_id" => evidence.id
    }

    case source_turn.intent do
      %{"source" => "target_relationship", "relationship_id" => relationship_id} ->
        Map.put(intent, "prior_relationship_id", relationship_id)

      _other ->
        intent
    end
  end

  defp set_result_pending(_operation, _proposal, _evidence, _incident, %{status: :exhausted}),
    do: :ok

  defp set_result_pending(operation, proposal, evidence, incident, %{
         status: status,
         value: turn
       })
       when status in [:charged, :duplicate] do
    pending = %{
      "action" => "resolve_turn",
      "turn_id" => turn.id,
      "source_turn_id" => proposal.source_turn_id,
      "operation_id" => operation.id,
      "evidence_id" => evidence.id
    }

    case Cases.get_case(incident.id, authorize?: false) do
      {:ok, %{pending_intent: ^pending}} ->
        :ok

      {:ok, current} ->
        Cases.handoff_case_operation(
          current,
          current.revision,
          operation.id,
          :resolver,
          turn.id,
          proposal.source_turn_id,
          evidence.id,
          authorize?: false
        )
        |> case do
          {:ok, _case} -> :ok
          {:error, _error} = error -> error
        end

      {:error, _error} = error ->
        error
    end
  end

  defp accept_verification(operation) do
    case Cases.accept_verification(operation.id, authorize?: false) do
      {:ok, _attempt} ->
        :ok

      {:error, error} ->
        case Cases.get_case(operation.case_id, authorize?: false) do
          {:ok, %{status: :needs_attention}} -> :ok
          _active -> {:error, error}
        end
    end
  end

  defp evidence_kind(%{purpose: :investigation}), do: "observation"
  defp evidence_kind(%{purpose: :remediation}), do: "operation_outcome"

  defp evidence_turn_id(%{purpose: :investigation}, proposal), do: proposal.source_turn_id
  defp evidence_turn_id(%{purpose: :remediation}, _proposal), do: nil
end
