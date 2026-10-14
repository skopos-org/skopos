defmodule Skopos.Cases.Case.Actions.DownstreamDecisionRoute do
  use Ash.Resource.Actions.Implementation

  require Ash.Query

  alias Skopos.{Cases, Providers}

  alias Skopos.Cases.{Approval, Case, CaseEvent, Evidence, Proposal, ResolutionRun, Turn}
  alias Skopos.Cases.Turn.RecoveryReviewFingerprint, as: RecoveryReviewFingerprint

  alias Skopos.Cases.ResolutionRun.Budget, as: Budget

  alias Skopos.Cases.Case.AdmissionLock, as: CaseAdmissionLock
  alias Skopos.Cases.Case.Symptom, as: CaseSymptom
  alias Skopos.Cases.Case.ConditionContext, as: ConditionContext
  alias Skopos.Cases.Case.ConditionRecovery, as: ConditionRecovery

  alias Skopos.Reports.Report.GenerationWorker

  @impl true
  def run(input, _opts, _context) do
    with {:ok, source_turn} <- Cases.get_turn(input.arguments.turn_id, authorize?: false) do
      case resolved_replay(source_turn) do
        {:ok, %Case{}} = replayed ->
          replayed

        :continue ->
          with :ok <- file_recovery_inputs(source_turn) do
            Ash.transact(
              [Case, ResolutionRun, Turn, Evidence, Proposal, Approval, CaseEvent],
              fn ->
                with :ok <- CaseAdmissionLock.acquire(),
                     {:ok, incident} <- lock_case(source_turn.case_id),
                     {:ok, run} <- lock_run(source_turn.resolution_run_id, incident.id),
                     {:ok, turn} <- lock_turn(source_turn.id, incident.id, run.id),
                     {:ok, current?} <- ConditionContext.current?(incident, turn.id),
                     true <-
                       current? ||
                         {:error,
                          Ash.Error.Action.InvalidArgument.exception(
                            field: :turn_id,
                            message: "Resolver Condition snapshot changed"
                          )},
                     {:ok, intent} <- downstream_intent(turn),
                     :ok <- validate_intent(intent, turn, incident, run) do
                  route(turn, intent, incident, run)
                end
              end
            )
          end

        {:error, _error} = error ->
          error
      end
    end
  end

  defp file_recovery_inputs(%{
         case_id: case_id,
         result: %{"intent" => %{"type" => "recovery_conclusion", "evidence_ids" => ids}}
       })
       when is_list(ids) do
    Enum.reduce_while(ids, :ok, fn id, :ok ->
      with {:ok, evidence} <- Cases.get_evidence(id, authorize?: false) do
        if evidence.kind == "file_read" do
          case Cases.read_file_content(id, case_id, authorize?: false) do
            {:ok, %{"status" => "available", "value" => value}} when is_binary(value) ->
              {:cont, :ok}

            {:ok, _unavailable} ->
              {:halt,
               {:error,
                Ash.Error.Action.InvalidArgument.exception(
                  field: :turn_id,
                  message: "Recovery file contents are no longer available"
                )}}

            {:error, _error} = error ->
              {:halt, error}
          end
        else
          {:cont, :ok}
        end
      else
        {:error, _error} = error -> {:halt, error}
      end
    end)
  end

  defp file_recovery_inputs(_turn), do: :ok

  defp route(turn, %{"type" => "recovery_conclusion"} = intent, incident, run) do
    with :ok <- ensure_running(incident, run),
         {:ok, review} <- recovery_review_event(turn) do
      case review do
        nil ->
          request_recovery_review(turn, intent, incident, run)

        %CaseEvent{data: %{"verdict" => "approved"}} = event ->
          complete_reviewed_recovery(turn, intent, incident, run, event)

        %CaseEvent{} ->
          incident
      end
    end
  end

  defp route(turn, intent, incident, run), do: route_other(turn, intent, incident, run)

  defp request_recovery_review(turn, intent, incident, run) do
    pending = %{"action" => "review_recovery", "turn_id" => turn.id}

    with :ok <- available_pending_intent(incident.pending_intent, pending, turn),
         {:ok, existing} <- existing_event(incident.id, review_request_key(turn)) do
      if existing do
        if incident.pending_intent == pending and
             existing.event_type == "recovery_review_requested" and
             existing.resolution_run_id == run.id and
             existing.data["result_digest"] == turn.result_digest do
          incident
        else
          invalid("Recovery Review request was already used with different input")
        end
      else
        case review_retry_gate(incident, intent) do
          :ok ->
            persist_recovery_review_request(turn, intent, incident, run, pending)

          {:blocked, reason} ->
            Cases.require_case_attention(
              incident.id,
              incident.revision,
              run.id,
              run.revision,
              "unchanged-recovery-review:#{turn.id}",
              reason,
              %{"action" => "retry_resolver"},
              "Collect new recovery evidence before asking for another review",
              authorize?: false
            )
            |> action_value()

          {:error, _error} = error ->
            error
        end
      end
    end
  end

  defp review_retry_gate(incident, intent) do
    with {:ok, fingerprint} <- RecoveryReviewFingerprint.current(incident, intent),
         {:ok, history} <- Cases.recovery_review_history(incident.id, authorize?: false) do
      cond do
        length(history) >= 501 ->
          {:blocked, "Recovery Review history exceeds the safe comparison limit"}

        Enum.any?(history, fn event ->
          event.data["verdict"] == "rejected" and
              event.data["review_fingerprint"] == fingerprint
        end) ->
          {:blocked, "Recovery Review rejected this unchanged evidence"}

        true ->
          :ok
      end
    end
  end

  defp persist_recovery_review_request(turn, intent, incident, run, pending) do
    with :ok <- available_pending_intent(incident.pending_intent, pending, turn),
         {:ok, updated} <-
           Cases.record_case_pending_intent(
             incident,
             incident.revision,
             pending,
             authorize?: false
           ),
         {:ok, _event} <-
           Cases.create_case_event_record(
             %{
               case_id: incident.id,
               resolution_run_id: run.id,
               event_type: "recovery_review_requested",
               idempotency_key: review_request_key(turn),
               data: %{
                 "source_turn_id" => turn.id,
                 "result_digest" => turn.result_digest,
                 "evidence_ids" => intent["evidence_ids"]
               }
             },
             authorize?: false
           ),
         {:ok, job} <-
           %{"turn_id" => turn.id}
           |> Skopos.Cases.Turn.RecoveryReviewWorker.new()
           |> Oban.insert(),
         true <-
           is_integer(job.id) ||
             {:error,
              Ash.Error.Unknown.UnknownError.exception(
                error: "Recovery Reviewer job was not persisted"
              )} do
      updated
    end
  end

  defp complete_reviewed_recovery(turn, intent, incident, run, event) do
    expected = %{
      "source_turn_id" => turn.id,
      "result_digest" => turn.result_digest,
      "evidence_ids" => intent["evidence_ids"],
      "condition_claims" => intent["condition_claims"],
      "desired_outcome_claims" => intent["desired_outcome_claims"]
    }

    with :ok <- available_pending_intent(incident.pending_intent, %{}, turn),
         true <-
           (event.event_type == "recovery_review_decided" and
              event.resolution_run_id == run.id and event.data["verdict"] == "approved" and
              Map.take(event.data, Map.keys(expected)) == expected and
              is_binary(event.data["ai_invocation_id"]) and
              is_binary(event.data["provider_id"]) and
              is_binary(event.data["invocation_key"])) ||
             invalid("Recovery Review did not approve this exact conclusion"),
         true <-
           CaseSymptom.valid_assessment?(
             event.data["desired_outcome_assessment"],
             CaseSymptom.current(incident),
             intent["desired_outcome_claims"],
             :approved
           ) || invalid("Recovery Review did not assess this desired outcome"),
         {:ok, invocation} <-
           Cases.ai_invocation_by_idempotency(event.data["invocation_key"],
             authorize?: false,
             not_found_error?: false
           ),
         true <-
           ((invocation && invocation.id == event.data["ai_invocation_id"]) and
              invocation.turn_id == turn.id and invocation.case_id == incident.id and
              invocation.resolution_run_id == run.id and invocation.role == :reviewer and
              invocation.status == :completed and
              invocation.provider_id == event.data["provider_id"] and
              invocation.assignment_id == event.data["assignment_id"] and
              invocation.result_digest ==
                Skopos.Cases.AIInvocation.request_digest(event.data)) ||
             invalid("Recovery Reviewer invocation is unavailable"),
         {:ok, assignment} <-
           Providers.load_current_ai_usage_role_assignment(
             invocation.assignment_id,
             :reviewer,
             invocation.assignment_revision,
             invocation.provider_revision,
             authorize?: false,
             not_found_error?: false
           ),
         true <-
           (assignment && assignment.provider_id == invocation.provider_id) ||
             {:error,
              Ash.Error.Action.InvalidArgument.exception(
                field: :turn_id,
                message: "Recovery Reviewer assignment changed"
              )},
         {:ok, resolved} <-
           complete_recovery(
             incident,
             run,
             route_key(turn),
             Map.put(resolved_event_data(turn, intent), "recovery_review_event_id", event.id)
           ) do
      resolved
    end
  end

  defp complete_recovery(incident, run, idempotency_key, data) do
    now = DateTime.utc_now()

    with :ok <- condition_completion_ready(incident),
         {:ok, resolved} <-
           Cases.record_case_resolution(incident, incident.revision, now, authorize?: false),
         {:ok, _completed} <-
           Cases.retire_resolution_run(
             run,
             run.revision,
             %{status: :completed, ended_at: now},
             authorize?: false
           ),
         {:ok, _event} <-
           Cases.create_case_event_record(
             %{
               case_id: incident.id,
               resolution_run_id: run.id,
               event_type: "case_resolved",
               idempotency_key: idempotency_key,
               data: data
             },
             authorize?: false
           ),
         {:ok, job} <-
           %{"case_id" => resolved.id, "case_revision" => resolved.revision}
           |> GenerationWorker.new()
           |> Oban.insert(),
         true <-
           is_integer(job.id) ||
             {:error,
              Ash.Error.Unknown.UnknownError.exception(
                error: "Report generation job was not persisted"
              )} do
      {:ok, resolved}
    end
  end

  defp condition_completion_ready(%{trigger_kind: :signal} = incident) do
    with {:ok, assessments} <- ConditionRecovery.assess_current(incident),
         true <-
           ConditionRecovery.ready_for_review?(assessments) ||
             invalid("Signal Conditions require current observations and Resolver assessment") do
      :ok
    end
  end

  defp condition_completion_ready(_incident), do: :ok

  defp recovery_review_event(turn) do
    existing_event(turn.case_id, review_result_key(turn))
  end

  defp route_other(turn, %{"type" => "handoff"} = intent, incident, run) do
    pending = pending_intent("provide_human_input", turn)
    key = route_key(turn)

    with {:ok, event} <- existing_event(incident.id, key) do
      if event do
        replay_handoff(incident, event, turn, intent, pending)
      else
        with :ok <- ensure_running(incident, run),
             :ok <- available_pending_intent(incident.pending_intent, pending, turn) do
          Cases.require_case_attention(
            incident.id,
            incident.revision,
            run.id,
            run.revision,
            key,
            intent["reason"],
            pending,
            intent["required_input"],
            authorize?: false
          )
          |> action_value()
        end
      end
    end
  end

  defp route_other(turn, %{"type" => "proposal"} = intent, incident, run) do
    with {:ok, proposal} <- Cases.materialize_proposal(turn.id, authorize?: false),
         pending <- %{
           "action" => "route_proposal",
           "proposal_id" => proposal.id,
           "source_turn_id" => turn.id
         },
         %Case{} <- persist_or_replay(turn, intent, incident, run, pending),
         {:ok, _proposal} <-
           Cases.route_proposal_authority(proposal.id, authorize?: false),
         {:ok, routed} <- Cases.get_case(incident.id, authorize?: false) do
      routed
    end
  end

  defp route_other(turn, intent, incident, run) do
    pending = pending_intent("evaluate_recovery", turn)
    persist_or_replay(turn, intent, incident, run, pending)
  end

  defp persist_or_replay(turn, intent, incident, run, pending) do
    key = route_key(turn)

    with {:ok, event} <- existing_event(incident.id, key) do
      if event do
        replay(incident, event, turn, intent, pending)
      else
        persist(incident, run, turn, intent, pending, key)
      end
    end
  end

  defp persist(incident, run, turn, intent, pending, key) do
    with :ok <- ensure_running(incident, run),
         :ok <- available_pending_intent(incident.pending_intent, pending, turn),
         {:ok, updated} <-
           Cases.record_case_pending_intent(
             incident,
             incident.revision,
             pending,
             authorize?: false
           ),
         {:ok, _event} <-
           Cases.create_case_event_record(
             %{
               case_id: incident.id,
               resolution_run_id: run.id,
               event_type: "resolver_decision_routed",
               idempotency_key: key,
               data: event_data(turn, intent, pending)
             },
             authorize?: false
           ) do
      updated
    end
  end

  defp replay(incident, event, turn, intent, pending) do
    if event.event_type == "resolver_decision_routed" and
         event.resolution_run_id == turn.resolution_run_id and
         event.data == event_data(turn, intent, pending) do
      incident
    else
      invalid("Resolver decision route was already used with different input")
    end
  end

  defp replay_handoff(incident, event, turn, intent, pending) do
    expected = %{
      "reason" => intent["reason"],
      "pending_intent" => pending,
      "required_human_input" => intent["required_input"]
    }

    if event.event_type == "case_needs_attention" and
         event.resolution_run_id == turn.resolution_run_id and event.data == expected do
      incident
    else
      invalid("Resolver decision route was already used with different input")
    end
  end

  defp downstream_intent(%{
         status: :completed,
         result_digest: digest,
         result: %{"outcome" => "decision", "intent" => %{"type" => type} = intent}
       })
       when is_binary(digest) and type in ["proposal", "recovery_conclusion", "handoff"],
       do: {:ok, intent}

  defp downstream_intent(_turn),
    do: invalid("Completed Turn does not contain a downstream Resolver decision")

  defp validate_intent(%{"type" => "proposal"}, _turn, _incident, _run), do: :ok

  defp validate_intent(
         %{
           "type" => "recovery_conclusion",
           "reason" => reason,
           "evidence_ids" => evidence_ids,
           "condition_claims" => claims,
           "desired_outcome_claims" => symptom_claims
         },
         turn,
         incident,
         run
       )
       when is_binary(reason) and is_list(evidence_ids) do
    with :ok <- valid_reason(reason),
         :ok <- valid_recovery_state(incident),
         :ok <- valid_case_evidence(evidence_ids, incident.id),
         :ok <- valid_fresh_verification(evidence_ids, claims, turn, incident, run),
         :ok <- valid_desired_outcome_claims(symptom_claims, evidence_ids, incident, run) do
      :ok
    end
  end

  defp validate_intent(
         %{
           "type" => "handoff",
           "reason" => reason,
           "required_input" => required_input
         },
         _turn,
         _incident,
         _run
       )
       when is_binary(reason) and is_binary(required_input) and byte_size(required_input) > 0 and
              byte_size(required_input) <= 1_000,
       do: valid_reason(reason)

  defp validate_intent(_intent, _turn, _incident, _run),
    do: invalid("Downstream Resolver decision is malformed")

  defp valid_desired_outcome_claims([], _evidence_ids, %{trigger_kind: :signal}, _run), do: :ok

  defp valid_desired_outcome_claims(claims, evidence_ids, incident, run)
       when incident.trigger_kind in [:manual, :audit] and is_list(claims) do
    cited =
      claims
      |> Enum.filter(&is_map/1)
      |> Enum.map(& &1["evidence_id"])
      |> Enum.filter(&is_binary/1)
      |> Enum.uniq()

    with {:ok, evidence} <- fetch_claim_evidence(cited, incident.id),
         true <-
           CaseSymptom.valid_claims?(
             claims,
             CaseSymptom.current(incident),
             evidence_ids,
             evidence
           ) || invalid("Recovery conclusion lacks a current Case symptom claim"),
         :ok <- verify_claim_evidence(evidence, incident, run) do
      :ok
    end
  end

  defp valid_desired_outcome_claims(_claims, _evidence_ids, _incident, _run),
    do: invalid("Recovery conclusion has unexpected desired outcome claims")

  defp fetch_claim_evidence(ids, case_id) do
    Enum.reduce_while(ids, {:ok, []}, fn id, {:ok, items} ->
      case Cases.get_evidence(id, authorize?: false, not_found_error?: false) do
        {:ok, %{case_id: ^case_id} = item} -> {:cont, {:ok, [item | items]}}
        {:error, _error} = error -> {:halt, error}
        _unavailable -> {:halt, invalid("Recovery conclusion cites unavailable Case Evidence")}
      end
    end)
  end

  defp verify_claim_evidence(items, incident, run) do
    Enum.reduce_while(items, :ok, fn item, :ok ->
      result =
        case item.kind do
          "observation" ->
            valid_fresh_observation(item, incident, run)

          "target_verification" ->
            with :ok <- valid_continuity_evidence(item, incident),
                 :ok <- validate_target_continuity_verification([item.id], incident) do
              :ok
            end

          "file_read" ->
            with {:ok, source} <- Cases.file_read_source(item.id, incident.id, authorize?: false),
                 do: verify_claim_evidence([source], incident, run)

          _other ->
            invalid("Recovery conclusion cites unsupported Case Evidence")
        end

      case result do
        :ok -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp valid_reason(reason) do
    if Skopos.Providers.AI.valid_resolver_reason?(reason),
      do: :ok,
      else: invalid("Downstream Resolver decision is malformed")
  end

  defp valid_recovery_state(%{trigger_kind: :signal}), do: :ok

  defp valid_recovery_state(%{trigger_kind: kind}) when kind in [:manual, :audit],
    do: :ok

  defp valid_recovery_state(_incident),
    do: invalid("Monitoring source has not confirmed recovery")

  defp valid_fresh_verification(
         evidence_ids,
         claims,
         _turn,
         %{trigger_kind: :signal} = incident,
         _run
       ) do
    with {:ok, assessments} <- ConditionRecovery.assess_current(incident),
         true <-
           ConditionRecovery.ready_for_review?(assessments) ||
             invalid("Signal Conditions require current observations and Resolver assessment"),
         true <- is_list(claims) || invalid("Recovery conclusion lacks Condition claims"),
         expected <- Map.new(assessments, &{&1.condition_id, &1}),
         true <-
           length(claims) == map_size(expected) ||
             invalid("Recovery conclusion omits a Condition"),
         true <-
           Enum.all?(claims, fn claim ->
             is_map(claim) and
               case Map.get(expected, claim["condition_id"]) do
                 nil ->
                   false

                 assessment ->
                   assessment.revision == claim["revision"] and
                     claim["evidence_id"] in assessment.evidence_ids and
                     claim["evidence_id"] in evidence_ids and
                     Skopos.Providers.AI.valid_resolver_reason?(claim["reason"])
               end
           end) || invalid("Recovery conclusion cites a changed Condition"),
         true <-
           MapSet.new(Enum.map(claims, & &1["condition_id"])) == MapSet.new(Map.keys(expected)) ||
             invalid("Recovery conclusion contains duplicate Condition claims") do
      :ok
    end
  end

  defp valid_fresh_verification(evidence_ids, [], turn, incident, run) do
    evidence_id = turn.intent["verification_evidence_id"]
    operation_id = turn.intent["operation_id"]

    if is_binary(evidence_id) and is_binary(operation_id) do
      validate_current_verification(evidence_ids, evidence_id, operation_id, incident, run)
    else
      validate_continuity_verification(evidence_ids, incident, run)
    end
  end

  defp valid_fresh_verification(_evidence_ids, _claims, _turn, _incident, _run),
    do: invalid("Recovery conclusion has unexpected Condition claims")

  defp validate_current_verification(evidence_ids, evidence_id, operation_id, incident, run) do
    if evidence_id in evidence_ids do
      case Cases.get_evidence(evidence_id, authorize?: false, not_found_error?: false) do
        {:ok,
         %{
           case_id: case_id,
           resolution_run_id: run_id,
           kind: "target_verification",
           source: "verification",
           content: %{"status" => "verified", "operation_id" => ^operation_id}
         }}
        when case_id == incident.id and run_id == run.id ->
          :ok

        {:error, _error} = error ->
          error

        {:ok, _unavailable} ->
          invalid("Recovery conclusion lacks the current verified Target Evidence")
      end
    else
      invalid("Recovery conclusion omits the current verification Evidence")
    end
  end

  defp validate_continuity_verification(evidence_ids, incident, run) do
    case validate_target_continuity_verification(evidence_ids, incident) do
      :ok ->
        :ok

      {:error, %Ash.Error.Changes.InvalidChanges{}} ->
        validate_fresh_observation(evidence_ids, incident, run)

      {:error, _error} = error ->
        error
    end
  end

  defp validate_target_continuity_verification(evidence_ids, incident) do
    with {:ok, candidates} <-
           Cases.target_continuity_evidence(incident.id, authorize?: false),
         %{} = latest <-
           Enum.find(candidates, &(&1.content["target_id"] == incident.selected_target_id)),
         true <-
           latest.id in evidence_ids ||
             invalid("Recovery conclusion omits the latest verified Target Evidence"),
         :ok <- valid_continuity_evidence(latest, incident) do
      :ok
    else
      nil -> invalid("Recovery conclusion lacks verified Target Evidence")
      {:error, _error} = error -> error
    end
  end

  defp validate_fresh_observation(evidence_ids, incident, run) do
    Enum.reduce_while(
      evidence_ids,
      invalid("Recovery conclusion lacks fresh Target Evidence"),
      fn
        evidence_id, _result ->
          case Cases.get_evidence(evidence_id, authorize?: false, not_found_error?: false) do
            {:ok, %Evidence{} = evidence} ->
              case valid_fresh_observation(evidence, incident, run) do
                :ok -> {:halt, :ok}
                {:error, %Ash.Error.Changes.InvalidChanges{}} = error -> {:cont, error}
                {:error, _error} = error -> {:halt, error}
              end

            {:ok, nil} ->
              {:cont, invalid("Recovery conclusion cites unavailable Target Evidence")}

            {:error, _error} = error ->
              {:halt, error}
          end
      end
    )
  end

  defp valid_fresh_observation(%{kind: "file_read"} = evidence, incident, run) do
    with {:ok, source} <- Cases.file_read_source(evidence.id, incident.id, authorize?: false),
         do: valid_fresh_observation(source, incident, run)
  end

  defp valid_fresh_observation(
         %{
           case_id: case_id,
           resolution_run_id: run_id,
           kind: "observation",
           source: "operation",
           source_ref: operation_id,
           observed_at: observed_at,
           content: %{
             "status" => "applied",
             "target_id" => target_id,
             "facts" => facts
           }
         },
         %{
           id: case_id,
           selected_target_id: target_id,
           selected_target_revision: target_revision
         } = incident,
         %{id: run_id}
       )
       when is_map(facts) and map_size(facts) > 0 do
    with {:ok, baseline} <- ConditionRecovery.baseline_for_case(incident),
         true <- DateTime.compare(observed_at, baseline) in [:eq, :gt],
         {:ok,
          %{
            case_id: ^case_id,
            resolution_run_id: ^run_id,
            target_id: ^target_id,
            target_revision: ^target_revision,
            purpose: :investigation,
            status: :applied,
            dispatch_started_at: %DateTime{} = dispatch_started_at
          }} <- Cases.get_operation(operation_id, authorize?: false, not_found_error?: false) do
      if DateTime.compare(dispatch_started_at, baseline) in [:eq, :gt],
        do: :ok,
        else: invalid("Recovery conclusion cites an earlier Target observation")
    else
      {:error, _error} = error -> error
      _stale -> invalid("Recovery conclusion cites stale Target observation")
    end
  end

  defp valid_fresh_observation(_evidence, _incident, _run),
    do: invalid("Recovery conclusion lacks fresh Target Evidence")

  defp valid_continuity_evidence(
         %{
           case_id: case_id,
           kind: "target_verification",
           source: "verification",
           content: %{
             "status" => "verified",
             "operation_id" => operation_id,
             "target_id" => target_id
           }
         },
         %{id: case_id, selected_target_id: target_id, selected_target_revision: target_revision}
       ) do
    case Cases.get_operation(operation_id, authorize?: false, not_found_error?: false) do
      {:ok,
       %{
         case_id: ^case_id,
         target_id: ^target_id,
         target_revision: ^target_revision,
         status: :applied
       }} ->
        :ok

      {:error, _error} = error ->
        error

      {:ok, _unavailable} ->
        invalid("Recovery conclusion cites stale Target verification")
    end
  end

  defp valid_continuity_evidence(_evidence, _incident),
    do: invalid("Recovery conclusion lacks verified Target Evidence")

  defp valid_case_evidence(ids, case_id) do
    with :ok <- unique_ids(ids) do
      Enum.reduce_while(ids, :ok, fn id, :ok ->
        case Cases.get_evidence(id, authorize?: false, not_found_error?: false) do
          {:ok, %{case_id: ^case_id}} -> {:cont, :ok}
          {:error, _error} = error -> {:halt, error}
          _unavailable -> {:halt, invalid("Resolver decision cites unavailable Evidence")}
        end
      end)
    end
  end

  defp unique_ids(ids) when is_list(ids) and ids != [] do
    if Enum.all?(ids, &(is_binary(&1) and byte_size(&1) > 0)) and
         length(ids) == MapSet.size(MapSet.new(ids)) do
      :ok
    else
      invalid("Resolver decision Evidence identities are invalid")
    end
  end

  defp unique_ids(_ids), do: invalid("Resolver decision Evidence identities are invalid")

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

  defp lock_turn(id, case_id, run_id) do
    Turn
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(id: id, case_id: case_id, resolution_run_id: run_id)
    |> Ash.Query.lock(:for_update)
    |> Ash.read_one(authorize?: false)
    |> required("Resolver Turn is unavailable")
  end

  defp required({:ok, nil}, message), do: invalid(message)
  defp required(result, _message), do: result

  defp ensure_running(%{status: :running, cancel_requested: false}, %{status: :running}), do: :ok

  defp ensure_running(%{cancel_requested: true}, _run),
    do: invalid("Case cancellation was requested")

  defp ensure_running(_incident, _run), do: invalid("Case resolution is not running")

  defp available_pending_intent(current, _pending, _turn) when map_size(current) == 0, do: :ok
  defp available_pending_intent(pending, pending, _turn), do: :ok

  defp available_pending_intent(%{"action" => "resolve_turn", "turn_id" => id}, _pending, %{
         id: id
       }),
       do: :ok

  defp available_pending_intent(
         %{"action" => "review_recovery", "turn_id" => id},
         _pending,
         %{id: id}
       ),
       do: :ok

  defp available_pending_intent(_current, _pending, _turn),
    do: invalid("Case already has another pending decision")

  defp existing_event(case_id, key) do
    Cases.case_event_by_idempotency(case_id, key,
      authorize?: false,
      not_found_error?: false
    )
  end

  defp event_data(turn, intent, pending) do
    %{
      "source_turn_id" => turn.id,
      "result_digest" => turn.result_digest,
      "intent_type" => intent["type"],
      "pending_intent" => pending
    }
  end

  defp resolved_event_data(turn, intent) do
    %{
      "source_turn_id" => turn.id,
      "result_digest" => turn.result_digest,
      "intent_type" => intent["type"],
      "reason" => intent["reason"],
      "evidence_ids" => intent["evidence_ids"]
    }
  end

  defp resolved_replay(
         %{
           status: :completed,
           result_digest: digest,
           result: %{
             "outcome" => "decision",
             "intent" => %{"type" => "recovery_conclusion"} = intent
           }
         } = source_turn
       )
       when is_binary(digest) do
    with {:ok, event} <- existing_event(source_turn.case_id, route_key(source_turn)) do
      case event do
        %CaseEvent{event_type: "case_resolved", data: data} ->
          if Map.drop(data, ["recovery_review_event_id"]) ==
               resolved_event_data(source_turn, intent) and
               is_binary(data["recovery_review_event_id"]),
             do: Cases.get_case(source_turn.case_id, authorize?: false),
             else: invalid("Recovery conclusion was already resolved with different input")

        _other ->
          :continue
      end
    end
  end

  defp resolved_replay(_turn), do: :continue

  defp pending_intent(action, turn),
    do: %{"action" => action, "source_turn_id" => turn.id}

  defp route_key(turn), do: Budget.key("resolver-route:downstream", turn.id)

  defp review_request_key(turn), do: Budget.key("recovery-review:requested", turn.id)
  defp review_result_key(turn), do: Budget.key("recovery-review:result", turn.id)

  defp action_value({:ok, value}), do: value
  defp action_value({:error, _error} = error), do: error

  defp invalid(message),
    do: {:error, Ash.Error.Changes.InvalidChanges.exception(message: message)}
end
