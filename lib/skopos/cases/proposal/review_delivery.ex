defmodule Skopos.Cases.Proposal.ReviewDelivery do
  @moduledoc false

  require Ash.Query

  alias Skopos.{Cases, Providers}

  alias Skopos.Cases.{AIInvocation, Case, CaseEvent, Proposal, ResolutionRun, ReviewDecision}
  alias Skopos.Cases.ResolutionRun.Budget, as: Budget

  alias Skopos.Cases.Case.AdmissionLock, as: CaseAdmissionLock
  alias Skopos.Cases.Case.ConditionContext, as: ConditionContext

  alias Skopos.Cases.AIInvocation.Claim, as: AIInvocationClaim
  alias Skopos.Cases.Proposal.ReviewProjection
  alias Skopos.Cases.ResolutionRun.BudgetResult

  alias Skopos.Providers.AI

  def run(proposal_id, opts \\ []) do
    with {:ok, proposal} <- Cases.get_proposal(proposal_id, authorize?: false),
         {:ok, incident} <- Cases.get_case(proposal.case_id, authorize?: false) do
      cond do
        incident.cancel_requested ->
          with {:ok, :ok} <-
                 Cases.settle_stopped_ai_invocations(
                   proposal.case_id,
                   proposal.resolution_run_id,
                   :reviewer,
                   nil,
                   proposal.id,
                   authorize?: false
                 ),
               do: :ok

        proposal.status == :invalidated ->
          :ok

        true ->
          case existing_decision(proposal.id) do
            {:ok, %ReviewDecision{} = decision} -> apply(decision)
            {:ok, nil} -> select_and_deliver(proposal, opts)
            {:error, _error} = error -> error
          end
      end
    end
  end

  defp select_and_deliver(proposal, opts) do
    with {:ok, failures} <- invalid_review_attempts(proposal) do
      excluded =
        failures
        |> Enum.group_by(& &1.provider_id)
        |> Enum.filter(fn {_provider_id, attempts} -> length(attempts) >= 2 end)
        |> Enum.map(&elem(&1, 0))

      case assigned_selection(proposal, assignment_generation(opts), excluded) do
        {:ok, selection} ->
          deliver(proposal, selection, retry_context(failures), opts)

        {:error, error} when length(failures) >= 2 ->
          stop_after_invalid_if_no_alternate(proposal, error, excluded, opts)

        {:error, error} ->
          persist_failure(proposal, error, nil, opts)
      end
    else
      {:error, error} -> persist_failure(proposal, error, nil, opts)
    end
  end

  defp replay_or_persist_failure(proposal, error, opts) do
    if AI.Error.context_failure?(error) do
      {:error, error}
    else
      with {:ok, invocation} <-
             Cases.ai_invocation_by_idempotency(
               "reviewer:#{proposal.id}:attempt:#{delivery_attempt(opts)}",
               authorize?: false,
               not_found_error?: false
             ) do
        case invocation do
          %{status: :dispatching} ->
            with {:ok, unknown} <-
                   record_invocation(invocation, :unknown,
                     category: "response_unknown",
                     failure_code: "response_unknown"
                   ),
                 do: persist_interruption(proposal, nil, unknown, opts)

          %{status: :unknown} ->
            persist_interruption(proposal, nil, invocation, opts)

          %{status: :failed, category: "context_changed"} ->
            replay_terminal_failure(proposal, invocation, opts)

          _other ->
            persist_failure(proposal, error, nil, opts)
        end
      end
    end
  end

  defp deliver(proposal, selection, retry_context, opts) do
    with {:ok, current} <- current_selection(selection),
         {:ok, request, context} <- ReviewProjection.build(proposal.id, current, retry_context),
         {:ok, incident} <- Cases.get_case(proposal.case_id, authorize?: false),
         {:ok, claim} <-
           claim_invocation(proposal, incident, current, request, context, delivery_attempt(opts)) do
      dispatch(proposal, current, request, claim, opts)
    else
      {:error, :context_changed} -> supersede_changed_context(proposal)
      {:error, error} -> replay_or_persist_failure(proposal, error, opts)
    end
  end

  defp dispatch(proposal, selection, request, %AIInvocationClaim{state: :claimed} = claim, opts) do
    outcome =
      Skopos.Cases.Case.InvocationContext.with_invocation(
        claim.invocation_context,
        Keyword.get(opts, :ai_invocation, %{}),
        fn invocation ->
          Providers.ai_review(selection.provider_id, request, invocation, authorize?: false)
        end
      )

    case outcome do
      {:ok, decision} ->
        case accept(proposal, selection, request, claim.invocation, decision) do
          {:ok, {:decision, stored}} ->
            apply(stored)

          {:ok, :stopped} ->
            :ok

          {:error, :context_changed} ->
            settle_and_supersede(proposal, claim.invocation, decision.usage)

          {:error, _error} = error ->
            error
        end

      {:error, error} ->
        if AIInvocation.retryable_unsent?(error) do
          case Cases.retry_unsent_ai_invocation(
                 claim.invocation,
                 claim.invocation.revision,
                 error,
                 authorize?: false
               ) do
            {:ok, _queued} -> {:error, error}
            {:error, save_error} -> {:error, Ash.Error.to_error_class([error, save_error])}
          end
        else
          persist_dispatch_failure(proposal, error, claim, opts)
        end
    end
  end

  defp dispatch(
         proposal,
         selection,
         _request,
         %AIInvocationClaim{state: :interrupted, invocation: invocation},
         opts
       ),
       do: persist_interruption(proposal, selection, invocation, opts)

  defp dispatch(
         proposal,
         _selection,
         _request,
         %AIInvocationClaim{state: :terminal, invocation: invocation},
         opts
       ) do
    case existing_decision(proposal.id) do
      {:ok, %ReviewDecision{} = decision} -> apply(decision)
      _missing -> replay_terminal_failure(proposal, invocation, opts)
    end
  end

  defp claim_invocation(proposal, incident, selection, request, context, delivery_attempt) do
    Ash.transact([AIInvocation, Case, Proposal], fn ->
      with :ok <- CaseAdmissionLock.acquire(),
           {:ok, current_case} <- Cases.get_case(incident.id, authorize?: false),
           {:ok, true} <- review_context_current(proposal, current_case) do
        do_claim_invocation(proposal, context, selection, request, delivery_attempt)
      else
        {:ok, false} -> {:error, :context_changed}
        other -> other
      end
    end)
    |> case do
      {:ok, {:ok, _claim} = claimed} -> claimed
      {:ok, {:error, _error} = failed} -> failed
      other -> other
    end
  end

  defp do_claim_invocation(proposal, context, selection, request, delivery_attempt) do
    Cases.claim_ai_invocation(
      :reviewer,
      proposal.case_id,
      context.case_revision,
      proposal.resolution_run_id,
      nil,
      nil,
      proposal.id,
      proposal.revision,
      selection.provider_id,
      selection.assignment_id,
      selection.provider_revision,
      selection.assignment_revision,
      selection.source,
      AIInvocation.request_digest(
        {request, delivery_attempt, selection.provider_id, selection.assignment_id}
      ),
      delivery_attempt,
      %{invocation_context: context, request_size_bytes: AI.input_size(request)},
      authorize?: false
    )
  end

  defp assigned_selection(proposal, generation, excluded) do
    key = assignment_key(proposal.id, generation)

    case Cases.case_event_by_idempotency(proposal.case_id, key,
           authorize?: false,
           not_found_error?: false
         ) do
      {:ok, %CaseEvent{} = event} -> selection_from_event(event, proposal)
      {:ok, nil} -> create_assignment(proposal, key, excluded)
      {:error, _error} = error -> error
    end
  end

  defp create_assignment(proposal, key, excluded) do
    with {:ok, %AI.Selection{role: :reviewer} = selection} <-
           Providers.select_reviewer_ai(excluded, authorize?: false),
         {:ok, _event} <-
           Cases.create_case_event_record(
             %{
               case_id: proposal.case_id,
               resolution_run_id: proposal.resolution_run_id,
               event_type: "reviewer_assigned",
               idempotency_key: key,
               data: selection_data(selection, proposal.id)
             },
             authorize?: false
           ) do
      {:ok, selection}
    else
      {:error, _error} = error ->
        case Cases.case_event_by_idempotency(proposal.case_id, key,
               authorize?: false,
               not_found_error?: false
             ) do
          {:ok, %CaseEvent{} = event} -> selection_from_event(event, proposal)
          _missing -> error
        end
    end
  end

  defp invalid_review_attempts(proposal) do
    case Cases.list_ai_invocations(
           query: [
             filter: [
               proposal_id: proposal.id,
               role: :reviewer,
               status: :failed,
               category: "invalid_output"
             ]
           ],
           authorize?: false
         ) do
      {:ok, invocations} ->
        {:ok, invocations}

      {:error, _error} = error ->
        error
    end
  end

  defp retry_context(failures), do: AIInvocation.retry_context(failures)

  defp stop_after_invalid_if_no_alternate(proposal, error, excluded, opts) do
    case Providers.eligible_ai_usage_role_assignments(:reviewer, authorize?: false) do
      {:ok, assignments} ->
        if Enum.any?(assignments, &(&1.provider_id not in excluded)) do
          persist_failure(proposal, error, nil, opts)
        else
          stop_delivery(
            proposal,
            "invalid_output",
            "Reviewer output remained invalid after two metered attempts"
          )
        end

      {:error, _error} ->
        persist_failure(proposal, error, nil, opts)
    end
  end

  defp selection_data(selection, proposal_id) do
    %{
      "proposal_id" => proposal_id,
      "provider_id" => selection.provider_id,
      "provider_revision" => selection.provider_revision,
      "assignment_id" => selection.assignment_id,
      "assignment_revision" => selection.assignment_revision,
      "source" => to_string(selection.source)
    }
  end

  defp selection_from_event(%CaseEvent{data: data, resolution_run_id: run_id}, proposal)
       when run_id == proposal.resolution_run_id do
    source = source(data["source"])

    if data["proposal_id"] == proposal.id and is_binary(data["provider_id"]) and
         is_integer(data["provider_revision"]) and is_binary(data["assignment_id"]) and
         is_integer(data["assignment_revision"]) and not is_nil(source) do
      {:ok,
       %AI.Selection{
         role: :reviewer,
         provider_id: data["provider_id"],
         provider_revision: data["provider_revision"],
         assignment_id: data["assignment_id"],
         assignment_revision: data["assignment_revision"],
         source: source
       }}
    else
      {:error, ai_error(:invalid_input, "Persisted Reviewer assignment is invalid")}
    end
  end

  defp selection_from_event(_event, _proposal),
    do: {:error, ai_error(:invalid_input, "Persisted Reviewer assignment is invalid")}

  defp current_selection(%AI.Selection{source: :assignment} = selection) do
    case Providers.load_current_ai_usage_role_assignment(
           selection.assignment_id,
           :reviewer,
           selection.assignment_revision,
           selection.provider_revision,
           authorize?: false,
           not_found_error?: false
         ) do
      {:ok, %{provider_id: provider_id}} when provider_id == selection.provider_id ->
        {:ok, selection}

      {:ok, _changed} ->
        {:error, ai_error(:unavailable, "Reviewer assignment changed")}

      {:error, error} = failure ->
        if AI.Error.context_failure?(error) or AI.Error.unwrap(error),
          do: failure,
          else: {:error, ai_error(:unavailable, "Reviewer assignment is unavailable")}
    end
  end

  defp current_selection(_selection),
    do: {:error, ai_error(:unavailable, "Reviewer assignment is unavailable")}

  defp accept(proposal, selection, request, invocation, decision) do
    usage = decision.usage.input_tokens + decision.usage.output_tokens
    attrs = decision_attrs(proposal, selection, request, decision)

    result =
      Ash.transact([AIInvocation, Case, ResolutionRun, Proposal, ReviewDecision], fn ->
        with :ok <- CaseAdmissionLock.acquire(),
             {:ok, incident} <- lock_case(proposal.case_id),
             {:ok, current_proposal} <- lock_proposal(proposal.id),
             true <-
               (incident.status == :running and not incident.cancel_requested and
                  current_proposal.status == :reviewing and
                  current_proposal.revision == proposal.revision) || {:error, :context_changed},
             {:ok, charged} <-
               charge_usage(
                 proposal,
                 usage,
                 "review-result:#{invocation.id}",
                 %{
                   "action" => "review_ai_usage",
                   "proposal_id" => proposal.id,
                   "ai_invocation_id" => invocation.id
                 }
               ) do
          case charged.status do
            status when status in [:charged, :duplicate] ->
              with {:ok, stored} <- store_decision(attrs),
                   {:ok, _invocation} <-
                     record_invocation(invocation, :completed,
                       usage: decision.usage,
                       result_digest: attrs.result_digest
                     ) do
                {:accepted, stored}
              end

            :exhausted ->
              with {:ok, _invocation} <-
                     record_invocation(invocation, :completed,
                       usage: decision.usage,
                       category: "budget_exhausted"
                     ) do
                {:exhausted, charged.reason}
              end
          end
        end
      end)

    case result do
      {:ok, {:accepted, stored}} ->
        {:ok, {:decision, stored}}

      {:ok, {:exhausted, reason}} ->
        with :ok <- stop_delivery(proposal, "budget_exhausted", reason), do: {:ok, :stopped}

      {:error, :context_changed} ->
        {:error, :context_changed}

      {:error, error} ->
        case accepted_or_existing({:error, error}, proposal.id) do
          {:ok, stored} -> {:ok, {:decision, stored}}
          {:error, _error} = failure -> failure
        end
    end
  end

  defp decision_attrs(proposal, selection, request, decision) do
    base = %{
      proposal_id: proposal.id,
      case_id: proposal.case_id,
      resolution_run_id: proposal.resolution_run_id,
      provider_id: selection.provider_id,
      assignment_id: selection.assignment_id,
      outcome: :decision,
      verdict: decision.verdict,
      purpose_assessment: decision.purpose_assessment,
      category: nil,
      reason: decision.reason,
      selection_source: selection.source,
      provider_revision: selection.provider_revision,
      assignment_revision: selection.assignment_revision,
      session_id: request.session_id,
      resolver_session_id: request.resolver_session_id,
      proposal_digest: proposal.proposal_digest,
      input_tokens: decision.usage.input_tokens,
      output_tokens: decision.usage.output_tokens,
      decided_at: DateTime.utc_now()
    }

    Map.put(base, :result_digest, result_digest(base))
  end

  defp store_decision(attrs),
    do: Cases.create_review_decision_record(attrs, authorize?: false)

  defp persist_dispatch_failure(proposal, error, claim, opts) do
    if match?(%AI.Error{category: :cancelled}, AI.Error.unwrap(error)) do
      with {:ok, current?} <-
             Cases.invocation_context_current(claim.invocation_context, authorize?: false),
           {:ok, incident} <- Cases.get_case(proposal.case_id, authorize?: false),
           {:ok, proposal_current?} <- review_context_current(proposal, incident) do
        if not current? and proposal_current? do
          persist_failure(
            proposal,
            error,
            claim.invocation,
            opts,
            {"context_changed", "Reviewer input changed during delivery"}
          )
        else
          persist_failure(proposal, error, claim.invocation, opts)
        end
      else
        {:error, cause} -> {:error, Ash.Error.to_error_class([error, cause])}
      end
    else
      persist_failure(proposal, error, claim.invocation, opts)
    end
  end

  defp persist_failure(proposal, error, invocation, opts, classification \\ nil) do
    if is_nil(invocation) and AI.Error.context_failure?(error) do
      {:error, error}
    else
      {category, reason} = classification || failure(error)

      with {:ok, _invocation} <- record_failure(proposal, invocation, category, error) do
        cond do
          AI.Error.context_failure?(error) ->
            {:error, error}

          retryable_failure?(category) and retry_available?(opts) ->
            {:error,
             "Reviewer delivery #{category} on attempt #{delivery_attempt(opts)} of #{max_delivery_attempts(opts)}"}

          true ->
            stop_delivery(proposal, category, reason)
        end
      else
        {:error, save_error} -> {:error, Ash.Error.to_error_class([error, save_error])}
      end
    end
  end

  defp persist_interruption(proposal, _selection, invocation, opts) do
    reason =
      "Reviewer response is unknown after dispatch; #{invocation.reserved_units} AI usage units were reserved"

    with {:ok, charged} <-
           charge_usage(
             proposal,
             invocation.reserved_units,
             "review-unknown:#{invocation.id}",
             %{
               "action" => "reserve_unknown_review_usage",
               "proposal_id" => proposal.id,
               "ai_invocation_id" => invocation.id,
               "reserved_usage_units" => invocation.reserved_units
             }
           ) do
      case charged.status do
        status when status in [:charged, :duplicate] ->
          if retry_available?(opts) do
            {:error,
             "Reviewer response was lost on attempt #{delivery_attempt(opts)} of #{max_delivery_attempts(opts)}"}
          else
            stop_delivery(proposal, "response_unknown", reason)
          end

        :exhausted ->
          :ok
      end
    end
  end

  defp apply(decision) do
    case Cases.apply_proposal_review(decision.proposal_id, decision.id, authorize?: false) do
      {:ok, _proposal} ->
        :ok

      {:error, _error} = error ->
        with "budget_exhausted" <- decision.category,
             {:ok, %{status: :needs_attention}} <-
               Cases.get_case(decision.case_id, authorize?: false) do
          :ok
        else
          _other -> error
        end
    end
  end

  defp charge_usage(proposal, 0, _idempotency_key, _metadata) do
    with {:ok, incident} <- Cases.get_case(proposal.case_id, authorize?: false),
         {:ok, run} <- Cases.get_resolution_run(proposal.resolution_run_id, authorize?: false) do
      {:ok, %BudgetResult{status: :charged, case: incident, run: run, value: run}}
    end
  end

  defp charge_usage(proposal, amount, idempotency_key, metadata) do
    Cases.charge_resolution_run(
      proposal.case_id,
      proposal.resolution_run_id,
      :ai_usage,
      amount,
      idempotency_key,
      metadata,
      "Increase the AI usage limit or decide the Proposal manually",
      authorize?: false
    )
  end

  defp record_failure(_proposal, nil, _category, _error), do: {:ok, nil}

  defp record_failure(proposal, invocation, category, error),
    do:
      settle_failed_usage(
        proposal,
        invocation,
        category,
        AIInvocation.failure_accounting(error, invocation.reserved_units),
        failure_code(error)
      )

  defp settle_failed_usage(proposal, invocation, category, accounting, failure_code) do
    key =
      if accounting.usage,
        do: "review-result:#{invocation.id}",
        else: "review-unknown:#{invocation.id}"

    Ash.transact([AIInvocation, Case, ResolutionRun, CaseEvent], fn ->
      with {:ok, _charged} <-
             charge_usage(
               proposal,
               accounting.amount,
               key,
               %{"action" => "review_ai_usage", "proposal_id" => proposal.id}
             ),
           {:ok, recorded} <-
             record_invocation(invocation, :failed,
               usage: accounting.usage,
               dispatched?: accounting.dispatched?,
               category: category,
               failure_code: failure_code,
               rejection_path: AIInvocation.rejection_path(Map.get(accounting, :ai_error))
             ) do
        recorded
      end
    end)
  end

  defp record_invocation(invocation, status, attrs) do
    usage = Keyword.get(attrs, :usage)

    Cases.record_ai_invocation_outcome(
      invocation,
      invocation.revision,
      %{
        status: status,
        usage: usage,
        dispatched?: Keyword.get(attrs, :dispatched?),
        category: Keyword.get(attrs, :category),
        failure_code: Keyword.get(attrs, :failure_code),
        rejection_path: Keyword.get(attrs, :rejection_path),
        result_digest: Keyword.get(attrs, :result_digest),
        completed_at: DateTime.utc_now()
      },
      authorize?: false
    )
  end

  defp existing_decision(proposal_id),
    do:
      Cases.review_decision_by_proposal(proposal_id,
        authorize?: false,
        not_found_error?: false
      )

  defp replay_terminal_failure(proposal, %{status: :failed, category: category}, opts) do
    category = category || "failed"

    if retryable_failure?(category) and retry_available?(opts) do
      {:error,
       "Reviewer delivery #{category} on attempt #{delivery_attempt(opts)} of #{max_delivery_attempts(opts)}"}
    else
      stop_delivery(proposal, category, public_failure_atom(category))
    end
  end

  defp replay_terminal_failure(_proposal, _invocation, _opts),
    do: {:error, "Reviewer AI invocation is already terminal"}

  defp stop_delivery(proposal, "cancelled" = category, reason) do
    with {:ok, incident} <- Cases.get_case(proposal.case_id, authorize?: false) do
      if incident.cancel_requested do
        :ok
      else
        with {:ok, current?} <- ConditionContext.current?(incident, proposal.source_turn_id) do
          if current?,
            do: fail_delivery(proposal, category, reason),
            else: supersede_changed_context(proposal)
        end
      end
    end
  end

  defp stop_delivery(proposal, category, reason), do: fail_delivery(proposal, category, reason)

  defp fail_delivery(proposal, category, reason) do
    case Cases.fail_proposal_review_delivery(
           proposal.id,
           category,
           String.slice(reason, 0, 1_000),
           authorize?: false
         ) do
      {:ok, _proposal} -> :ok
      {:error, _error} = error -> error
    end
  end

  defp retryable_failure?(category),
    do:
      category in [
        "timeout",
        "unreachable",
        "rate_limited",
        "failed",
        "invalid_output",
        "context_changed"
      ]

  defp retry_available?(opts), do: delivery_attempt(opts) < max_delivery_attempts(opts)

  defp delivery_attempt(opts), do: max(Keyword.get(opts, :delivery_attempt, 1), 1)

  defp max_delivery_attempts(opts),
    do: max(Keyword.get(opts, :max_delivery_attempts, 1), delivery_attempt(opts))

  defp assignment_generation(opts),
    do: max(Keyword.get(opts, :assignment_generation, delivery_attempt(opts)), 1)

  defp accepted_or_existing({:error, error}, proposal_id) do
    case existing_decision(proposal_id) do
      {:ok, %ReviewDecision{} = stored} -> {:ok, stored}
      _missing -> {:error, error}
    end
  end

  defp review_context_current(proposal, %{status: :running, cancel_requested: false} = incident) do
    with {:ok, %{status: :reviewing, revision: revision}} <-
           Cases.get_proposal(proposal.id, authorize?: false),
         {:ok, conditions_current?} <-
           ConditionContext.current?(incident, proposal.source_turn_id) do
      {:ok, revision == proposal.revision and conditions_current?}
    else
      {:error, _cause} = error -> error
      _changed -> {:ok, false}
    end
  end

  defp review_context_current(_proposal, _stopped), do: {:ok, false}

  defp lock_case(case_id) do
    Case
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(id: case_id)
    |> Ash.Query.lock(:for_update)
    |> Ash.read_one(authorize?: false)
  end

  defp lock_proposal(proposal_id) do
    Proposal
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(id: proposal_id)
    |> Ash.Query.lock(:for_update)
    |> Ash.read_one(authorize?: false)
  end

  defp settle_and_supersede(proposal, invocation, usage) do
    with :ok <- settle_changed_context(proposal, invocation, usage) do
      supersede_changed_context(proposal)
    end
  end

  defp supersede_changed_context(proposal) do
    case Cases.supersede_proposal_context(proposal.id, authorize?: false) do
      {:ok, _proposal} -> :ok
      {:error, _error} = error -> error
    end
  end

  defp settle_changed_context(proposal, invocation, usage) do
    accounting = AIInvocation.failure_accounting(usage, true, invocation.reserved_units)

    case settle_failed_usage(proposal, invocation, "context_changed", accounting, nil) do
      {:ok, _invocation} -> :ok
      {:error, _error} = error -> error
    end
  end

  defp failure(error) do
    case find_error(error) do
      %AI.Error{category: category} ->
        {to_string(category), public_failure(category)}

      _error ->
        {"failed", "Reviewer delivery failed"}
    end
  end

  defp failure_code(error) do
    case find_error(error) do
      %AI.Error{failure_code: code} when is_binary(code) -> code
      _error -> nil
    end
  end

  defp public_failure(:authentication), do: "Reviewer authentication failed"
  defp public_failure(:unreachable), do: "Reviewer AI is unreachable"
  defp public_failure(:timeout), do: "Reviewer AI timed out"
  defp public_failure(:rate_limited), do: "Reviewer AI rate limit was exceeded"
  defp public_failure(:cancelled), do: "Reviewer decision was cancelled"
  defp public_failure(:invalid_input), do: "Reviewer input is invalid"
  defp public_failure(:invalid_output), do: "Reviewer output is invalid"
  defp public_failure(:unavailable), do: "Reviewer AI is unavailable"
  defp public_failure(:budget_exhausted), do: "Reviewer AI budget is exhausted"
  defp public_failure(:disclosure_limit), do: "Reviewer evidence exceeds the AI input limit"
  defp public_failure(_category), do: "Reviewer delivery failed"

  defp public_failure_atom(category) do
    case category do
      "authentication" -> public_failure(:authentication)
      "unreachable" -> public_failure(:unreachable)
      "timeout" -> public_failure(:timeout)
      "rate_limited" -> public_failure(:rate_limited)
      "cancelled" -> public_failure(:cancelled)
      "invalid_input" -> public_failure(:invalid_input)
      "invalid_output" -> public_failure(:invalid_output)
      "unavailable" -> public_failure(:unavailable)
      "budget_exhausted" -> public_failure(:budget_exhausted)
      "disclosure_limit" -> public_failure(:disclosure_limit)
      _category -> public_failure(:failed)
    end
  end

  defp find_error(error), do: AI.Error.unwrap(error)

  defp result_digest(attrs) do
    attrs
    |> Map.drop([:decided_at, :result_digest])
    |> :erlang.term_to_binary([:deterministic])
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp assignment_key(proposal_id, 1),
    do: Budget.key("proposal:reviewer_assignment", proposal_id)

  defp assignment_key(proposal_id, generation),
    do: Budget.key("proposal:reviewer_assignment:#{generation}", proposal_id)

  defp source("assignment"), do: :assignment
  defp source(_value), do: nil
  defp ai_error(category, message), do: AI.Error.exception(category: category, message: message)
end
