defmodule Skopos.Cases.Proposal.Actions.Authority do
  use Ash.Resource.Actions.Implementation

  require Ash.Query

  alias Skopos.{Accounts, Cases, Targets}

  alias Skopos.Cases.{Approval, Case, CaseEvent, Proposal, ResolutionRun, ReviewDecision, Turn}
  alias Skopos.Cases.ResolutionRun.Budget, as: Budget

  alias Skopos.Cases.Case.AdmissionLock, as: CaseAdmissionLock
  alias Skopos.Cases.Case.ConditionContext, as: ConditionContext

  alias Skopos.Cases.Proposal.ProposalExpirationWorker
  alias Skopos.Targets.TargetRequest.{RequestError, Clearance}

  @impl true
  def run(input, opts, context) do
    case opts[:operation] do
      :route ->
        route(input.arguments.proposal_id)

      :decide ->
        decide(input.arguments, context.actor)

      :expire ->
        expire(input.arguments.proposal_id)

      :review ->
        apply_review(input.arguments.proposal_id, input.arguments.review_decision_id)

      :supersede_context ->
        supersede_context(input.arguments.proposal_id)

      :review_delivery_failure ->
        fail_review_delivery(
          input.arguments.proposal_id,
          input.arguments.category,
          input.arguments.reason
        )
    end
  end

  defp route(proposal_id) do
    with {:ok, source} <- Cases.get_proposal(proposal_id, authorize?: false) do
      Ash.transact([Case, ResolutionRun, Proposal, Approval, Turn, CaseEvent], fn ->
        with :ok <- CaseAdmissionLock.acquire(),
             {:ok, incident} <- lock_case(source.case_id),
             {:ok, run} <- lock_run(source.resolution_run_id, incident.id),
             {:ok, proposal} <- lock_proposal(source.id, incident.id, run.id),
             {:ok, current?} <- ConditionContext.current?(incident, proposal.source_turn_id) do
          if current? do
            route_locked(proposal, incident, run)
          else
            if proposal.status in [:proposed, :blocked] and
                 incident.pending_intent["proposal_id"] == proposal.id,
               do: supersede_locked(proposal, incident, run),
               else: invalid("Proposal Conditions changed before authority routing")
          end
        end
      end)
    end
  end

  defp route_locked(%{status: :blocked, request_kind: :observation} = proposal, incident, run) do
    reconsider_blocked_observation(proposal, incident, run)
  end

  defp route_locked(%{status: :blocked} = proposal, incident, run) do
    require_attention(
      proposal,
      incident,
      run,
      proposal.preflight_reason || "Target request could not be admitted",
      "review_blocked_proposal",
      "Review the blocked Proposal and resume the Case"
    )
  end

  defp route_locked(%{status: :proposed} = proposal, incident, run) do
    with :ok <- valid_context(proposal, incident, run) do
      case proposal.authority_mode do
        :readonly -> route_readonly(proposal, incident, run)
        :ask -> await_human(proposal, incident)
        :auto -> route_auto(proposal, incident, run)
        :full_access -> authorize_full_access(proposal, incident, run)
      end
    end
  end

  defp route_locked(%{status: :authorized} = proposal, _incident, _run) do
    with :ok <- schedule_acceptance(proposal), do: proposal
  end

  defp route_locked(
         %{status: status} = proposal,
         _incident,
         _run
       )
       when status in [
              :recommended,
              :awaiting_human,
              :reviewing,
              :rejected,
              :invalidated
            ],
       do: proposal

  defp reconsider_blocked_observation(proposal, incident, run) do
    reason = proposal.preflight_reason || "Target observation request was denied"
    category = proposal.preflight_context["category"] || "denied"

    case Budget.consume(
           case_id: incident.id,
           resolution_run_id: run.id,
           kind: :no_progress,
           amount: 1,
           ledger_key: Budget.key("proposal:blocked-observation", proposal.id),
           actor: nil,
           event_type: "observation_proposal_blocked",
           event_data: %{
             "proposal_id" => proposal.id,
             "category" => category,
             "reason" => reason
           },
           pending_intent: %{"action" => "review_blocked_proposal", "proposal_id" => proposal.id},
           required_human_input: "Review the denied Target observation and resume the Case",
           operation: fn _case, _run -> {:ok, proposal} end,
           duplicate: fn _case, _run -> {:ok, proposal} end
         ) do
      {:ok, %{status: status}} when status in [:charged, :duplicate] ->
        start_blocked_observation_retry(proposal, incident, run, reason, category)

      {:ok, %{status: :exhausted}} ->
        proposal

      {:error, _error} = error ->
        error
    end
  end

  defp start_blocked_observation_retry(proposal, incident, run, reason, category) do
    intent = %{
      "objective" => "Choose another Target observation after the previous request was denied",
      "source" => "target_observation_denied",
      "blocked_proposal_id" => proposal.id,
      "rejection_category" => category,
      "rejection_reason" => reason,
      "rejected_capability" => proposal.capability,
      "rejected_operation" => proposal.operation
    }

    with {:ok, started} <-
           Cases.start_turn(
             incident.id,
             run.id,
             "proposal:blocked-observation:next-turn:#{proposal.id}",
             intent,
             %{"action" => "continue_resolution", "blocked_proposal_id" => proposal.id},
             "Review Resolver limits or the denied observation",
             authorize?: false
           ) do
      case started do
        %{status: status, value: %Turn{} = turn} when status in [:charged, :duplicate] ->
          with {:ok, _case} <- handoff(incident, proposal, :continue, turn.id) do
            proposal
          end

        %{status: :exhausted} ->
          proposal
      end
    end
  end

  defp decide(arguments, actor) do
    with {:ok, current_actor} <- current_actor(actor),
         {:ok, source} <- Cases.get_proposal(arguments.proposal_id, authorize?: false) do
      result =
        Ash.transact([Case, ResolutionRun, Proposal, Approval, Turn, CaseEvent], fn ->
          with :ok <- CaseAdmissionLock.acquire(),
               {:ok, incident} <- lock_case(source.case_id),
               {:ok, run} <- lock_run(source.resolution_run_id, incident.id),
               {:ok, proposal} <- lock_proposal(source.id, incident.id, run.id),
               {:ok, existing} <- existing_approval(proposal.id),
               {:ok, current?} <- ConditionContext.current?(incident, proposal.source_turn_id) do
            cond do
              existing ->
                replay_human(existing, proposal, arguments, current_actor)

              not current? and proposal.status == :awaiting_human ->
                supersede_locked(proposal, incident, run)

              not current? ->
                invalid("Proposal Conditions changed before human decision")

              true ->
                decide_locked(proposal, incident, run, arguments, current_actor)
            end
          end
        end)

      case result do
        {:ok, %Proposal{status: status} = proposal}
        when status in [:invalidated, :awaiting_human] ->
          if expired?(proposal), do: expired_error(), else: result

        _other ->
          result
      end
    end
  end

  defp decide_locked(proposal, incident, run, arguments, actor) do
    cond do
      expired?(proposal) and proposal.status == :awaiting_human ->
        expire_locked(proposal, incident, run)

      expired?(proposal) and proposal.status == :invalidated ->
        expired_error()

      true ->
        with :ok <- expected_proposal(proposal, arguments),
             :ok <- human_decidable(proposal),
             :ok <- valid_context(proposal, incident, run),
             :ok <- available_pending(incident.pending_intent, proposal.id) do
          case arguments.decision do
            :approved -> authorize_with(proposal, incident, run, actor, :human, arguments.reason)
            :rejected -> reject_human(proposal, incident, run, arguments.reason, actor)
          end
        end
    end
  end

  defp expire(proposal_id) do
    with {:ok, source} <- Cases.get_proposal(proposal_id, authorize?: false) do
      Ash.transact([Case, ResolutionRun, Proposal, CaseEvent], fn ->
        with {:ok, incident} <- lock_case(source.case_id),
             {:ok, run} <- lock_run_any(source.resolution_run_id, incident.id),
             {:ok, proposal} <- lock_proposal(source.id, incident.id, run.id) do
          expire_locked(proposal, incident, run)
        end
      end)
    end
  end

  defp expire_locked(%{status: :awaiting_human} = proposal, incident, run) do
    if expired?(proposal) and incident.status == :running and run.active and
         run.status == :running and run.generation == proposal.case_generation and
         incident.pending_intent["action"] == "decide_proposal" and
         incident.pending_intent["proposal_id"] == proposal.id do
      with {:ok, invalidated} <- transition(proposal, :invalidated),
           %Proposal{} <-
             require_attention(
               invalidated,
               incident,
               run,
               "Proposal approval window expired",
               "review_expired_proposal",
               "Review the expired Proposal and resume the Case"
             ) do
        invalidated
      end
    else
      proposal
    end
  end

  defp expire_locked(proposal, _incident, _run), do: proposal

  defp expired?(proposal),
    do: DateTime.compare(DateTime.utc_now(), proposal.expires_at) != :lt

  defp expired_error do
    {:error,
     Ash.Error.Changes.InvalidAttribute.exception(field: :expires_at, message: "has expired")}
  end

  defp recommend(proposal, incident, run) do
    with {:ok, recommended} <- transition(proposal, :recommended) do
      require_attention(
        recommended,
        incident,
        run,
        "Readonly mode does not authorize remote effects",
        "view_recommendation",
        "Review the recommendation and handle the effect outside Skopos"
      )
    end
  end

  defp route_readonly(%{request_kind: :effect} = proposal, incident, run),
    do: recommend(proposal, incident, run)

  defp route_readonly(%{request_kind: :observation} = proposal, incident, run),
    do: authorize_observation(proposal, incident, run, :readonly)

  defp route_auto(%{request_kind: :observation} = proposal, incident, run),
    do: authorize_observation(proposal, incident, run, :auto_observation)

  defp route_auto(proposal, incident, _run), do: await_reviewer(proposal, incident)

  defp authorize_observation(proposal, incident, run, source) do
    with {:ok, actor} <- current_owner(incident) do
      authorize_with(
        proposal,
        incident,
        run,
        actor,
        source,
        "The registered Target Method admitted the exact observation request"
      )
    end
  end

  defp await_human(proposal, incident) do
    with {:ok, waiting} <- transition(proposal, :awaiting_human),
         {:ok, _case} <- handoff(incident, waiting, :human),
         :ok <- schedule_expiration(waiting) do
      waiting
    end
  end

  defp await_reviewer(proposal, incident) do
    with {:ok, reviewing} <- transition(proposal, :reviewing),
         {:ok, _case} <- handoff(incident, reviewing, :review),
         {:ok, job} <- enqueue_review(reviewing.id),
         true <-
           is_integer(job.id) ||
             {:error,
              Ash.Error.Unknown.UnknownError.exception(
                error: "Proposal Reviewer job was not persisted"
              )} do
      reviewing
    end
  end

  defp apply_review(proposal_id, decision_id) do
    with {:ok, source} <- Cases.get_proposal(proposal_id, authorize?: false),
         {:ok, decision} <- Cases.review_decision_by_proposal(proposal_id, authorize?: false),
         true <- decision.id == decision_id || invalid("ReviewDecision does not match Proposal") do
      Ash.transact([Case, ResolutionRun, Proposal, Approval, ReviewDecision], fn ->
        with :ok <- CaseAdmissionLock.acquire(),
             {:ok, incident} <- lock_case(source.case_id),
             {:ok, run} <- lock_run(source.resolution_run_id, incident.id),
             {:ok, proposal} <- lock_proposal(source.id, incident.id, run.id) do
          apply_review_locked(proposal, decision, incident, run)
        end
      end)
    end
  end

  defp apply_review_locked(%{status: :authorized} = proposal, _decision, _incident, _run),
    do: schedule_if_authorized(proposal)

  defp apply_review_locked(
         %{status: :awaiting_human} = proposal,
         %{verdict: :rejected} = decision,
         incident,
         run
       ),
       do: reject_review(proposal, decision, incident, run)

  defp apply_review_locked(%{status: :awaiting_human} = proposal, _decision, _incident, _run),
    do: proposal

  defp apply_review_locked(
         %{status: :rejected} = proposal,
         %{verdict: :rejected},
         _incident,
         _run
       ),
       do: proposal

  defp apply_review_locked(%{status: :reviewing} = proposal, decision, incident, run) do
    with {:ok, current?} <- ConditionContext.current?(incident, proposal.source_turn_id) do
      if current? do
        with :ok <- valid_context(proposal, incident, run),
             true <-
               decision.proposal_digest == proposal.proposal_digest ||
                 invalid("ReviewDecision Proposal digest changed") do
          case decision.verdict do
            :approved ->
              if decision.purpose_assessment == proposal.purpose,
                do: approve_review(proposal, decision, incident, run),
                else: invalid("Reviewer purpose assessment does not authorize this Proposal")

            :rejected ->
              reject_review(proposal, decision, incident, run)

            :needs_human ->
              await_human_review(proposal, decision, incident)
          end
        end
      else
        supersede_locked(proposal, incident, run)
      end
    end
  end

  defp apply_review_locked(_proposal, _decision, _incident, _run),
    do: invalid("Proposal is not awaiting Reviewer decision")

  defp supersede_context(proposal_id) do
    with {:ok, source} <- Cases.get_proposal(proposal_id, authorize?: false) do
      Ash.transact([Case, ResolutionRun, Proposal, Turn, CaseEvent], fn ->
        with :ok <- CaseAdmissionLock.acquire(),
             {:ok, incident} <- lock_case(source.case_id),
             {:ok, run} <- lock_run_any(source.resolution_run_id, incident.id),
             {:ok, proposal} <- lock_proposal(source.id, incident.id, run.id),
             {:ok, current?} <- ConditionContext.current?(incident, proposal.source_turn_id) do
          cond do
            proposal.status == :invalidated ->
              proposal

            incident.status != :running or run.status != :running ->
              proposal

            proposal.status in [:reviewing, :authorized] and not current? ->
              with {:ok, nil} <-
                     Cases.operation_by_proposal(proposal.id,
                       authorize?: false,
                       not_found_error?: false
                     ) do
                supersede_locked(proposal, incident, run)
              else
                {:ok, _operation} -> invalid("Proposal already has an accepted Operation")
                {:error, _error} = error -> error
              end

            proposal.status != :reviewing ->
              proposal

            true ->
              invalid("Proposal context is still current")
          end
        end
      end)
    end
  end

  defp supersede_locked(proposal, incident, run) do
    intent = %{"action" => "continue_resolution", "source_proposal_id" => proposal.id}

    with true <-
           incident.pending_intent["proposal_id"] == proposal.id ||
             invalid("Case pending decision changed"),
         {:ok, invalidated} <- transition(proposal, :invalidated),
         {:ok, _cleared} <- handoff(incident, invalidated, :clear),
         {:ok, started} <-
           Cases.start_turn(
             incident.id,
             run.id,
             Budget.key("proposal:context-changed", proposal.id),
             %{
               "objective" => "Reassess the Case with current Conditions",
               "source_proposal_id" => proposal.id
             },
             intent,
             "Review Resolver limits",
             authorize?: false
           ),
         {:ok, _pending} <- pending_after_supersede(started, invalidated) do
      invalidated
    end
  end

  defp pending_after_supersede(%{status: :exhausted}, _proposal), do: {:ok, :needs_attention}

  defp pending_after_supersede(%{status: status, case: incident, value: turn}, proposal)
       when status in [:charged, :duplicate] do
    handoff(incident, proposal, :continue, turn.id)
  end

  defp fail_review_delivery(proposal_id, category, reason) do
    with {:ok, source} <- Cases.get_proposal(proposal_id, authorize?: false) do
      Ash.transact([Case, ResolutionRun, Proposal, CaseEvent], fn ->
        with {:ok, incident} <- lock_case(source.case_id),
             {:ok, run} <- lock_run(source.resolution_run_id, incident.id),
             {:ok, proposal} <- lock_proposal(source.id, incident.id, run.id) do
          fail_review_delivery_locked(proposal, incident, run, category, reason)
        end
      end)
    end
  end

  defp fail_review_delivery_locked(
         %{status: :reviewing} = proposal,
         %{status: :needs_attention},
         %{status: :needs_attention},
         _category,
         _reason
       ) do
    with {:ok, invalidated} <- transition(proposal, :invalidated), do: invalidated
  end

  defp fail_review_delivery_locked(
         %{status: :reviewing} = proposal,
         incident,
         run,
         category,
         reason
       ) do
    with :ok <- valid_context(proposal, incident, run),
         {:ok, invalidated} <- transition(proposal, :invalidated) do
      require_attention(
        invalidated,
        incident,
        run,
        "Reviewer delivery failed: #{reason}",
        "restore_reviewer_delivery",
        reviewer_recovery(category)
      )
    end
  end

  defp fail_review_delivery_locked(
         %{status: :invalidated} = proposal,
         %{status: :needs_attention},
         %{status: :needs_attention},
         _category,
         _reason
       ),
       do: proposal

  defp fail_review_delivery_locked(_proposal, _incident, _run, _category, _reason),
    do: invalid("Proposal is not awaiting Reviewer delivery")

  defp reviewer_recovery("budget_exhausted"),
    do: "Review the Case AI usage limit and resume the Case"

  defp reviewer_recovery("authentication"),
    do: "Repair Reviewer AI authentication and resume the Case"

  defp reviewer_recovery("invalid_output"),
    do: "Use a Reviewer AI that produces valid decisions and resume the Case"

  defp reviewer_recovery("disclosure_limit"),
    do: "Reduce the evidence scope and resume the Case"

  defp reviewer_recovery(_category),
    do: "Restore Reviewer AI availability and resume the Case"

  defp approve_review(proposal, decision, incident, run) do
    with {:ok, actor} <- current_owner(incident) do
      authorize_with(proposal, incident, run, actor, :reviewer, decision.reason)
    end
  end

  defp await_human_review(proposal, decision, incident) do
    with {:ok, waiting} <- transition(proposal, :awaiting_human),
         {:ok, _case} <- handoff(incident, waiting, :human, decision.id),
         :ok <- schedule_expiration(waiting) do
      waiting
    end
  end

  defp reject_review(proposal, decision, incident, run) do
    with {:ok, actor} <- current_owner(incident),
         {:ok, rejected} <- transition(proposal, :rejected),
         {:ok, started} <- start_reconsideration(rejected, incident, run, decision.reason, actor),
         {:ok, _case} <- continue_after_rejection(started, incident, rejected) do
      rejected
    end
  end

  defp authorize_full_access(proposal, incident, run) do
    with {:ok, actor} <- current_owner(incident) do
      authorize_with(
        proposal,
        incident,
        run,
        actor,
        :full_access,
        "FullAccess mode authorized the exact Proposal"
      )
    end
  end

  defp authorize_with(proposal, incident, run, actor, source, reason) do
    with {:ok, clearance} <- revalidate(proposal, actor),
         {:ok, approval} <-
           create_approval(proposal, actor, :approved, source, reason, clearance),
         {:ok, authorized} <- transition(proposal, :authorized),
         {:ok, _case} <- handoff(incident, authorized, :dispatch, approval.id),
         :ok <- schedule_acceptance(authorized) do
      authorized
    else
      {:blocked, category, blocked_reason} ->
        invalidate(proposal, incident, run, category, blocked_reason)

      {:error, _error} = error ->
        error
    end
  end

  defp reject_human(proposal, incident, run, reason, actor) do
    with {:ok, _approval} <-
           create_approval(proposal, actor, :rejected, :human, reason, nil),
         {:ok, rejected} <- transition(proposal, :rejected),
         {:ok, started} <- start_reconsideration(rejected, incident, run, reason, actor),
         {:ok, _case} <- continue_after_rejection(started, incident, rejected) do
      rejected
    end
  end

  defp start_reconsideration(proposal, incident, run, reason, actor) do
    Cases.start_turn(
      incident.id,
      run.id,
      Budget.key("proposal:rejected", proposal.id),
      %{
        "objective" => "Continue resolution after a rejected Proposal",
        "rejected_proposal_id" => proposal.id,
        "rejected_proposal_digest" => proposal.proposal_digest,
        "reason" => reason
      },
      %{"action" => "continue_resolution", "rejected_proposal_id" => proposal.id},
      "Review Resolver limits or handle the rejected Proposal manually",
      actor: actor,
      authorize?: false
    )
  end

  defp continue_after_rejection(%{status: status}, _incident, _proposal)
       when status == :exhausted,
       do: {:ok, :needs_attention}

  defp continue_after_rejection(%{value: %Turn{} = turn}, incident, proposal) do
    handoff(incident, proposal, :continue, turn.id)
  end

  defp invalidate(proposal, incident, run, category, reason) do
    with {:ok, invalidated} <- transition(proposal, :invalidated) do
      require_attention(
        invalidated,
        incident,
        run,
        "Proposal authorization failed: #{reason}",
        "review_invalidated_proposal",
        "Review the #{category} authorization failure and resume the Case"
      )
    end
  end

  defp create_approval(proposal, actor, decision, source, reason, clearance) do
    Cases.create_approval_record(
      %{
        proposal_id: proposal.id,
        case_id: proposal.case_id,
        resolution_run_id: proposal.resolution_run_id,
        actor_id: actor.id,
        actor_role_version: actor.role_version,
        decision: decision,
        source: source,
        proposal_digest: proposal.proposal_digest,
        proposal_revision: proposal.revision,
        case_generation: proposal.case_generation,
        clearance_digest: clearance_digest(clearance),
        reason: reason,
        decided_at: DateTime.utc_now()
      },
      authorize?: false
    )
  end

  defp revalidate(proposal, actor) do
    case Targets.clear_target_request(Proposal.target_request(proposal), actor: actor) do
      {:ok, %Clearance{} = clearance} ->
        if clearance.provider_id == proposal.provider_id and
             clearance.provider_revision == proposal.provider_revision do
          {:ok, clearance}
        else
          {:blocked, :stale_context, "Target Provider changed after the Proposal"}
        end

      {:error, error} ->
        case find_error(error) do
          %RequestError{category: category, message: message} ->
            {:blocked, category, message}

          _other ->
            {:error, error}
        end
    end
  end

  defp require_attention(proposal, incident, run, reason, action, required_input) do
    pending = %{"action" => action, "proposal_id" => proposal.id}

    with {:ok, _case} <-
           Cases.require_case_attention(
             incident.id,
             incident.revision,
             run.id,
             run.revision,
             Budget.key("proposal:attention:#{action}", proposal.id),
             String.slice(reason, 0, 500),
             pending,
             required_input,
             authorize?: false
           ) do
      proposal
    end
  end

  defp transition(proposal, status) do
    Cases.transition_proposal(proposal, proposal.revision, %{status: status}, authorize?: false)
  end

  defp handoff(incident, proposal, kind, reference_id \\ nil) do
    Cases.handoff_case_proposal(
      incident,
      incident.revision,
      proposal.id,
      kind,
      reference_id,
      authorize?: false
    )
  end

  defp valid_context(proposal, incident, run) do
    cond do
      incident.status != :running or incident.cancel_requested ->
        invalid("Case resolution is not running")

      run.status != :running ->
        invalid("ResolutionRun is not running")

      proposal.case_generation != run.generation ->
        invalid("Proposal Case generation changed")

      proposal.authority_mode != incident.authority_mode or
          proposal.authority_mode != run.authority_mode ->
        invalid("Proposal authority mode changed")

      DateTime.compare(DateTime.utc_now(), proposal.expires_at) != :lt ->
        invalid("Proposal has expired")

      true ->
        :ok
    end
  end

  defp expected_proposal(proposal, arguments) do
    cond do
      proposal.revision != arguments.expected_revision -> stale(:revision)
      proposal.proposal_digest != arguments.proposal_digest -> stale(:proposal_digest)
      true -> :ok
    end
  end

  defp stale(field) do
    {:error, Ash.Error.Changes.StaleRecord.exception(resource: Proposal, field: field)}
  end

  defp human_decidable(%{status: :awaiting_human, authority_mode: mode})
       when mode in [:ask, :auto],
       do: :ok

  defp human_decidable(_proposal), do: invalid("Proposal is not awaiting a human decision")

  defp available_pending(pending, _proposal_id) when map_size(pending) == 0, do: :ok

  defp available_pending(%{"proposal_id" => proposal_id}, proposal_id), do: :ok

  defp available_pending(_pending, _proposal_id),
    do: invalid("Case has another pending decision")

  defp replay_human(approval, proposal, arguments, actor) do
    if approval.source == :human and approval.actor_id == actor.id and
         approval.decision == arguments.decision and
         approval.proposal_digest == arguments.proposal_digest and
         approval.reason == arguments.reason do
      schedule_if_authorized(proposal)
    else
      invalid("Proposal already has a different decision")
    end
  end

  defp current_owner(%{current_owner_id: owner_id}) when is_binary(owner_id),
    do: current_actor(%{id: owner_id})

  defp current_owner(_incident), do: invalid("Case has no operational owner")

  defp current_actor(%{id: actor_id}) do
    case Accounts.get_user(actor_id, authorize?: false) do
      {:ok, %{role: role} = actor} when role in [:admin, :operator] -> {:ok, actor}
      {:ok, _unavailable} -> invalid("Actor cannot authorize a Proposal")
      {:error, _error} = error -> error
    end
  end

  defp current_actor(_actor), do: invalid("Actor cannot authorize a Proposal")

  defp lock_case(id) do
    Case
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(id: id)
    |> Ash.Query.lock(:for_update)
    |> Ash.read_one(authorize?: false)
    |> required("Case is unavailable")
  end

  defp lock_run(id, case_id) do
    ResolutionRun
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(id: id, case_id: case_id, active: true)
    |> Ash.Query.lock(:for_update)
    |> Ash.read_one(authorize?: false)
    |> required("Active ResolutionRun is unavailable")
  end

  defp lock_run_any(id, case_id) do
    ResolutionRun
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(id: id, case_id: case_id)
    |> Ash.Query.lock(:for_update)
    |> Ash.read_one(authorize?: false)
    |> required("ResolutionRun is unavailable")
  end

  defp lock_proposal(id, case_id, run_id) do
    Proposal
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(id: id, case_id: case_id, resolution_run_id: run_id)
    |> Ash.Query.lock(:for_update)
    |> Ash.read_one(authorize?: false)
    |> required("Proposal is unavailable")
  end

  defp existing_approval(proposal_id) do
    Approval
    |> Ash.Query.for_read(:by_proposal, %{proposal_id: proposal_id})
    |> Ash.Query.lock(:for_update)
    |> Ash.read_one(authorize?: false)
  end

  defp required({:ok, nil}, message), do: invalid(message)
  defp required(result, _message), do: result

  defp schedule_if_authorized(%{status: :authorized} = proposal) do
    with :ok <- schedule_acceptance(proposal), do: proposal
  end

  defp schedule_if_authorized(proposal), do: proposal

  defp schedule_acceptance(proposal) do
    case Skopos.Cases.Operation.AcceptanceWorker.new(%{"proposal_id" => proposal.id})
         |> Oban.insert() do
      {:ok, %Oban.Job{id: id}} when is_integer(id) ->
        :ok

      {:ok, _unpersisted} ->
        {:error,
         Ash.Error.Unknown.UnknownError.exception(
           error: "Operation acceptance job was not persisted"
         )}

      {:error, _error} = error ->
        error
    end
  end

  defp schedule_expiration(proposal) do
    case proposal |> ProposalExpirationWorker.job() |> Oban.insert() do
      {:ok, %Oban.Job{id: id}} when is_integer(id) ->
        :ok

      {:ok, _unpersisted} ->
        {:error,
         Ash.Error.Unknown.UnknownError.exception(
           error: "Proposal expiration job was not persisted"
         )}

      {:error, _error} = error ->
        error
    end
  end

  defp clearance_digest(nil), do: nil
  defp clearance_digest(clearance), do: Base.encode16(clearance.digest, case: :lower)

  defp find_error(%RequestError{} = error), do: error

  defp find_error(%{errors: [error]}), do: find_error(error)

  defp find_error(_error), do: nil

  defp enqueue_review(proposal_id) do
    %{"proposal_id" => proposal_id}
    |> Skopos.Cases.Proposal.ReviewWorker.new()
    |> Oban.insert()
  end

  defp invalid(message),
    do: {:error, Ash.Error.Changes.InvalidChanges.exception(message: message)}
end
