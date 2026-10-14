defmodule Skopos.Cases.Case.Actions.SplitConditions do
  use Ash.Resource.Actions.Implementation

  require Ash.Query

  alias Skopos.{Cases, Signals, Targets}

  alias Skopos.Cases.{
    AIInvocation,
    Case,
    CaseConditionMembership,
    CaseDispatch,
    CaseEvent,
    Evidence,
    Operation,
    Proposal,
    ResolutionRun,
    Turn,
    VerificationAttempt
  }

  alias Skopos.Cases.ResolutionRun.Budget, as: Budget

  alias Skopos.Cases.Case.AdmissionLock, as: CaseAdmissionLock
  alias Skopos.Cases.Case.ConditionContext, as: ConditionContext
  alias Skopos.Cases.Case.ConditionRecovery, as: ConditionRecovery
  alias Skopos.Cases.Case.Changes.SplitReallocation

  @budgets [
    max_resolver_turns: :turn_count,
    max_target_requests: :target_request_count,
    max_effects: :effect_count,
    max_related_targets: :related_target_count,
    max_ai_usage_units: :ai_usage_units
  ]

  @impl true
  def run(input, _opts, context) do
    args = input.arguments
    key = split_key(args)

    Ash.transact(
      [
        Case,
        ResolutionRun,
        CaseConditionMembership,
        CaseDispatch,
        Evidence,
        CaseEvent,
        Turn
      ],
      fn ->
        with :ok <- CaseAdmissionLock.acquire(),
             {:ok, parent} <- lock(Case, args.id),
             {:ok, prior} <-
               Cases.case_event_by_idempotency(parent.id, key,
                 authorize?: false,
                 not_found_error?: false
               ) do
          if prior do
            Cases.get_case(prior.data["child_case_id"], authorize?: false)
          else
            split(parent, args, key, context.actor)
          end
        end
      end
    )
    |> case do
      {:ok, {:ok, %Case{} = child}} -> {:ok, child}
      {:ok, {:error, _error} = failed} -> failed
      other -> other
    end
  end

  defp split(parent, args, key, actor) do
    with :ok <- eligible_case(parent, args),
         {:ok, run} <- lock_active_run(parent.id),
         {:ok, dispatch} <- Cases.case_dispatch(parent.id, authorize?: false),
         true <- dispatch.state == :sent || invalid("Case has not dispatched its first Turn"),
         :ok <- quiescent(parent, run),
         {:ok, members} <- Cases.active_conditions_for_case(parent.id, authorize?: false),
         :ok <- exact_members(parent, members, args),
         {:ok, moved} <- moved_members(members, args.condition_ids),
         {:ok, conditions} <- load_conditions(moved),
         {:ok, remaining_conditions} <-
           load_conditions(Enum.reject(members, &(&1.condition_id in args.condition_ids))),
         :ok <- validate_resolver_split(parent, run, args, conditions, remaining_conditions),
         {:ok, selected_target} <- selected_target(conditions),
         {:ok, remaining_target} <- selected_target(remaining_conditions),
         recovery_baseline <- ConditionRecovery.inherited_baseline(parent),
         {:ok, budgets} <- partition(run),
         {:ok, child} <-
           create_child(parent, run, dispatch, selected_target, recovery_baseline, budgets.child),
         {:ok, _copied} <- copy_current_signal_evidence(parent, child, conditions),
         {:ok, _lineage} <- record_child_evidence(parent, child, moved, args, key),
         {:ok, updated_parent, updated_run} <-
           reallocate_parent(
             parent,
             run,
             budgets.parent,
             conditions,
             remaining_conditions,
             remaining_target
           ),
         :ok <- move_members(moved, child.id),
         :ok <-
           record_split(
             updated_parent,
             updated_run,
             child,
             moved,
             args,
             key,
             actor
           ),
         :ok <- start_branches(updated_parent, updated_run, child) do
      Cases.get_case(child.id, authorize?: false)
    end
  end

  defp validate_resolver_split(
         parent,
         run,
         %{source_turn_id: source_turn_id} = args,
         moved,
         remaining
       )
       when is_binary(source_turn_id) do
    with {:ok, %{case_id: case_id, resolution_run_id: run_id, status: :completed} = turn} <-
           Cases.get_turn(source_turn_id, authorize?: false),
         true <- case_id == parent.id and run_id == run.id,
         %{"outcome" => "decision", "intent" => %{"type" => "case_split"} = intent} <-
           turn.result,
         true <- turn.result["condition_revisions"] == args.expected_conditions,
         true <- intent["condition_ids"] == args.condition_ids and intent["reason"] == args.reason,
         {:ok, true} <- cited_group(intent["evidence_ids"], moved, parent.id),
         {:ok, true} <- cited_group(intent["remaining_evidence_ids"], remaining, parent.id) do
      :ok
    else
      {:error, _error} = error ->
        error

      _invalid ->
        {:error,
         Ash.Error.Changes.InvalidAttribute.exception(
           field: :source_turn_id,
           message:
             "AI Case split needs current Target observations for both investigation scopes"
         )}
    end
  end

  defp validate_resolver_split(_parent, _run, _args, _moved, _remaining), do: :ok

  defp cited_group(ids, conditions, case_id) when is_list(ids) and ids != [] do
    Enum.reduce_while(ids, {:ok, false}, fn id, result ->
      case Cases.get_evidence(id, authorize?: false, not_found_error?: false) do
        {:ok, evidence} ->
          valid? =
            not is_nil(evidence) and evidence.case_id == case_id and
              evidence.kind in ["observation", "target_verification"] and
              evidence.content["status"] in ["applied", "verified"] and
              Enum.any?(conditions, fn condition ->
                condition.target_id == evidence.content["target_id"] and
                  DateTime.compare(evidence.observed_at, condition.current_occurred_at) != :lt
              end)

          if valid?, do: {:halt, {:ok, true}}, else: {:cont, result}

        {:error, _error} = error ->
          {:halt, error}
      end
    end)
  end

  defp cited_group(_ids, _conditions, _case_id), do: {:ok, false}

  defp eligible_case(parent, args) do
    cond do
      parent.revision != args.expected_revision ->
        {:error, Ash.Error.Changes.StaleRecord.exception(resource: Case, field: :revision)}

      parent.trigger_kind != :signal or parent.status != :running or parent.cancel_requested ->
        invalid("Only a running Signal Case can be split")

      true ->
        :ok
    end
  end

  defp quiescent(parent, run) do
    with true <-
           DateTime.compare(DateTime.utc_now(), run.deadline_at) == :lt ||
             invalid("Case deadline has elapsed"),
         :ok <- pending_decision_quiescent(parent),
         {:ok, started} <- Cases.started_turns_for_run(run.id, authorize?: false),
         true <- started == [] || invalid("Resolver Turn is still running"),
         :ok <- quiescent_operations(parent.id),
         :ok <- quiescent_proposals(parent.id),
         :ok <- no_rows(AIInvocation, parent.id, [:dispatching]) do
      :ok
    end
  end

  defp quiescent_operations(case_id) do
    with :ok <- no_rows(Operation, case_id, [:queued, :dispatching, :partial, :unknown]),
         :ok <- no_rows(VerificationAttempt, case_id, [:queued, :dispatching, :unknown]) do
      :ok
    end
  end

  defp quiescent_proposals(case_id) do
    with :ok <- no_rows(Proposal, case_id, [:proposed, :reviewing, :awaiting_human]),
         {:ok, authorized} <-
           Proposal
           |> Ash.Query.for_read(:read)
           |> Ash.Query.filter(case_id == ^case_id and status == :authorized)
           |> Ash.read(authorize?: false) do
      Enum.reduce_while(authorized, :ok, fn proposal, :ok ->
        case Cases.operation_by_proposal(proposal.id,
               authorize?: false,
               not_found_error?: false
             ) do
          {:ok, %{status: status}} when status in [:applied, :failed] ->
            {:cont, :ok}

          {:ok, _operation} ->
            {:halt, invalid("Case has an unsettled Proposal or Target operation")}

          {:error, _error} = error ->
            {:halt, error}
        end
      end)
    end
  end

  defp pending_decision_quiescent(%{pending_intent: pending, id: case_id}) do
    cond do
      pending == %{} ->
        :ok

      pending["action"] in ["route_resolver_decision", "resolve_turn"] and
          is_binary(pending["turn_id"]) ->
        case Cases.get_turn(pending["turn_id"], authorize?: false) do
          {:ok, %{case_id: ^case_id, status: :completed}} -> :ok
          {:ok, _turn} -> invalid("Case has another pending decision")
          {:error, _error} = error -> error
        end

      true ->
        invalid("Case has another pending decision")
    end
  end

  defp no_rows(resource, case_id, statuses) do
    query =
      resource
      |> Ash.Query.for_read(:read)
      |> Ash.Query.filter(case_id == ^case_id)
      |> Ash.Query.limit(1)

    query = if statuses, do: Ash.Query.filter(query, status in ^statuses), else: query

    case Ash.read_one(query, authorize?: false) do
      {:ok, nil} -> :ok
      {:ok, _row} -> invalid("Case has an unsettled Proposal or Target operation")
      {:error, _error} = error -> error
    end
  end

  defp exact_members(parent, members, args) do
    with true <- length(members) >= 2 || invalid("Case needs at least two Conditions"),
         {:ok, expected} <- normalize_expected(args.expected_conditions),
         {:ok, current} <- ConditionContext.current_condition_revisions(parent),
         true <-
           expected == current ||
             {:error,
              Ash.Error.Changes.StaleRecord.exception(
                resource: CaseConditionMembership,
                field: :condition_revisions
              )} do
      :ok
    end
  end

  defp normalize_expected(values) when is_list(values) do
    if Enum.all?(values, fn item ->
         is_map(item) and is_binary(item["id"]) and is_integer(item["revision"]) and
           item["revision"] > 0
       end) do
      normalized =
        values
        |> Enum.map(&Map.take(&1, ["id", "revision"]))
        |> Enum.sort_by(& &1["id"])

      if Enum.uniq_by(normalized, & &1["id"]) == normalized,
        do: {:ok, normalized},
        else: invalid("Condition snapshot contains duplicate IDs")
    else
      invalid("Condition snapshot is invalid")
    end
  end

  defp moved_members(members, ids) do
    ids = Enum.uniq(ids)
    by_id = Map.new(members, &{&1.condition_id, &1})

    if length(ids) > 0 and length(ids) < length(members) and
         Enum.all?(ids, &Map.has_key?(by_id, &1)) do
      {:ok, Enum.map(ids, &Map.fetch!(by_id, &1))}
    else
      invalid("Split must move a nonempty proper subset of current Conditions")
    end
  end

  defp load_conditions(members) do
    Enum.reduce_while(members, {:ok, []}, fn member, {:ok, conditions} ->
      case Signals.get_condition(member.condition_id, authorize?: false) do
        {:ok, condition} -> {:cont, {:ok, [condition | conditions]}}
        {:error, _error} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, conditions} -> {:ok, Enum.reverse(conditions)}
      error -> error
    end
  end

  defp selected_target(conditions) do
    case Enum.find(conditions, & &1.target_id) do
      nil -> {:ok, nil}
      condition -> load_selected_target(condition.target_id)
    end
  end

  defp load_selected_target(id) do
    case Targets.get_target(id, authorize?: false) do
      {:ok, %{active: true} = target} -> {:ok, target}
      {:ok, _target} -> invalid("Split Target is inactive")
      {:error, _error} = error -> error
    end
  end

  defp partition(run) do
    allocations =
      Enum.reduce(@budgets, %{parent: %{}, child: %{}}, fn {maximum, counter}, acc ->
        spent = Map.fetch!(run, counter)
        limit = Map.fetch!(run, maximum)

        child_limit = div(max(limit - spent, 0), 2)

        %{
          parent: Map.put(acc.parent, maximum, limit - child_limit),
          child: Map.put(acc.child, maximum, child_limit)
        }
      end)

    if Enum.all?(@budgets, fn {maximum, counter} ->
         Map.fetch!(run, maximum) >= Map.fetch!(run, counter)
       end),
       do: {:ok, allocations},
       else: invalid("Resolution budget counters exceed their limits")
  end

  defp create_child(parent, run, dispatch, selected_target, recovery_baseline, limits) do
    active? = SplitReallocation.active_capacity?(limits, %{})
    status = if active?, do: :running, else: :needs_attention
    reason = if active?, do: nil, else: "No Resolver capacity was allocated to this split Case"

    attrs =
      parent
      |> Map.take([
        :source,
        :severity,
        :report_language,
        :authority_setting_id,
        :authority_setting_revision,
        :authority_mode,
        :max_elapsed_seconds,
        :max_no_progress_turns,
        :current_owner_id
      ])
      |> Map.merge(limits)
      |> Map.merge(%{
        trigger_kind: :signal,
        source_ref: "split:#{Ash.UUID.generate()}",
        title: "#{parent.title} · separate condition" |> String.slice(0, 200),
        status: status,
        initial_context: %{"split_parent_case_id" => parent.id},
        split_parent_id: parent.id,
        recovery_baseline_at: recovery_baseline,
        cancel_requested: false,
        pending_intent: %{},
        stop_reason: reason,
        required_human_input: if(active?, do: nil, else: "Increase Case limits"),
        initial_target_id: selected_target && selected_target.id,
        selected_target_id: selected_target && selected_target.id,
        selected_target_revision: selected_target && selected_target.revision
      })

    with {:ok, child} <- Cases.create_case_record(attrs, authorize?: false),
         {:ok, _run} <-
           Cases.create_resolution_run_record(
             Map.merge(limits, %{
               case_id: child.id,
               generation: 1,
               active: true,
               status: status,
               authority_mode: parent.authority_mode,
               max_elapsed_seconds: run.max_elapsed_seconds,
               max_no_progress_turns: run.max_no_progress_turns,
               turn_count: 0,
               target_request_count: 0,
               effect_count: 0,
               related_target_count: 0,
               ai_usage_units: 0,
               no_progress_turns: 0,
               started_at: run.started_at,
               deadline_at: run.deadline_at
             }),
             authorize?: false
           ),
         {:ok, _dispatch} <-
           Cases.create_case_dispatch_record(
             %{
               case_id: child.id,
               state: :sent,
               first_received_at: dispatch.first_received_at,
               due_at: dispatch.due_at,
               anchor_target_id: selected_target && selected_target.id
             },
             authorize?: false
           ) do
      {:ok, child}
    end
  end

  defp current_signal_evidence(case_id, condition) do
    Evidence
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(
      case_id == ^case_id and kind == "signal_event" and
        stored_content["condition_id"] == ^condition.id
    )
    |> Ash.Query.sort(observed_at: :desc, inserted_at: :desc, id: :desc)
    |> Ash.Query.limit(1)
    |> Ash.read_one(authorize?: false)
    |> case do
      {:ok, %Evidence{} = evidence} ->
        if evidence.content["condition_revision"] == condition.revision and
             evidence.content["current"] == true and
             evidence.content["state"] == to_string(condition.state) and
             evidence.content["source_sequence"] == condition.current_source_sequence and
             DateTime.compare(evidence.observed_at, condition.current_occurred_at) == :eq do
          {:ok, evidence}
        else
          invalid("Current Signal Evidence does not match the Condition")
        end

      {:ok, nil} ->
        invalid("Current Signal Evidence is unavailable")

      {:error, _error} = error ->
        error
    end
  end

  defp copy_current_signal_evidence(parent, child, conditions) do
    with {:ok, child_run} <- Cases.active_resolution_run(child.id, authorize?: false) do
      Enum.reduce_while(conditions, {:ok, []}, fn condition, {:ok, copied} ->
        with {:ok, %Evidence{} = source} <-
               current_signal_evidence(parent.id, condition),
             {:ok, evidence} <-
               Cases.create_evidence_record(
                 %{
                   case_id: child.id,
                   resolution_run_id: child_run.id,
                   idempotency_key: "split:signal:#{source.id}",
                   kind: source.kind,
                   source: source.source,
                   source_ref: source.source_ref,
                   content: source.content,
                   observed_at: source.observed_at
                 },
                 authorize?: false
               ) do
          {:cont, {:ok, [%{"from" => source.id, "to" => evidence.id} | copied]}}
        else
          {:error, _error} = error -> {:halt, error}
        end
      end)
    end
  end

  defp record_child_evidence(parent, child, moved, args, key) do
    with {:ok, child_run} <- Cases.active_resolution_run(child.id, authorize?: false) do
      Cases.create_evidence_record(
        %{
          case_id: child.id,
          resolution_run_id: child_run.id,
          idempotency_key: "split:lineage:#{key}",
          kind: "split_lineage",
          source: "case_split",
          source_ref: parent.id,
          content: %{
            "parent_case_id" => parent.id,
            "condition_ids" => Enum.map(moved, & &1.condition_id),
            "reason" => args.reason,
            "source_turn_id" => Map.get(args, :source_turn_id),
            "historical_context_only" => true
          },
          observed_at: DateTime.utc_now()
        },
        authorize?: false
      )
    end
  end

  defp reallocate_parent(parent, run, limits, moved, remaining, remaining_target) do
    attrs = limits

    moved_target_ids = MapSet.new(moved, & &1.target_id)
    remaining_target_ids = MapSet.new(remaining, & &1.target_id)

    attrs =
      if MapSet.member?(moved_target_ids, parent.selected_target_id) and
           not MapSet.member?(remaining_target_ids, parent.selected_target_id) do
        Map.merge(attrs, %{
          selected_target_id: remaining_target && remaining_target.id,
          selected_target_revision: remaining_target && remaining_target.revision
        })
      else
        attrs
      end

    with {:ok, updated_run} <-
           Cases.reallocate_resolution_run_limits(run, run.revision, limits, authorize?: false),
         {:ok, updated_parent} <-
           Cases.record_case_split_reallocation(
             parent,
             parent.revision,
             run.turn_count,
             run.ai_usage_units,
             attrs,
             authorize?: false
           ),
         {:ok, final_run} <- maybe_pause(updated_run, updated_parent.status == :running) do
      {:ok, updated_parent, final_run}
    end
  end

  defp maybe_pause(run, true), do: {:ok, run}

  defp maybe_pause(run, false),
    do: Cases.pause_resolution_run(run, run.revision, authorize?: false)

  defp move_members(moved, child_id) do
    Enum.reduce_while(moved, :ok, fn member, :ok ->
      with {:ok, _detached} <-
             Cases.detach_case_condition_record(
               member,
               member.revision,
               %{detached_at: DateTime.utc_now(), reason: "split to Case #{child_id}"},
               authorize?: false
             ),
           {:ok, _attached} <-
             Cases.attach_case_condition_record(
               %{
                 case_id: child_id,
                 condition_id: member.condition_id,
                 attached_at: DateTime.utc_now(),
                 reason: "split from Case #{member.case_id}"
               },
               authorize?: false
             ) do
        {:cont, :ok}
      else
        {:error, _error} = error -> {:halt, error}
      end
    end)
  end

  defp record_split(parent, run, child, moved, args, key, actor) do
    ids = Enum.map(moved, & &1.condition_id)
    actor_id = actor && actor.id

    with {:ok, _parent_event} <-
           Cases.create_case_event_record(
             %{
               case_id: parent.id,
               resolution_run_id: run.id,
               actor_id: actor_id,
               event_type: "case_conditions_split_out",
               idempotency_key: key,
               data: %{
                 "child_case_id" => child.id,
                 "condition_ids" => ids,
                 "reason" => args.reason,
                 "source_turn_id" => Map.get(args, :source_turn_id),
                 "authority_mode" => to_string(parent.authority_mode),
                 "turn_ordinal_boundary" => run.turn_count
               }
             },
             authorize?: false
           ),
         {:ok, child_run} <- Cases.active_resolution_run(child.id, authorize?: false),
         {:ok, _child_event} <-
           Cases.create_case_event_record(
             %{
               case_id: child.id,
               resolution_run_id: child_run.id,
               actor_id: actor_id,
               event_type: "case_conditions_split_in",
               idempotency_key: "case:split:parent:#{parent.id}",
               data: %{
                 "parent_case_id" => parent.id,
                 "condition_ids" => ids,
                 "reason" => args.reason,
                 "source_turn_id" => Map.get(args, :source_turn_id)
               }
             },
             authorize?: false
           ) do
      :ok
    end
  end

  defp start_branches(parent, parent_run, child) do
    with :ok <- start_branch(parent, parent_run, child.id),
         {:ok, child_run} <- Cases.active_resolution_run(child.id, authorize?: false),
         :ok <- start_branch(child, child_run, parent.id) do
      :ok
    end
  end

  defp start_branch(%{status: :needs_attention}, _run, _other_case_id), do: :ok

  defp start_branch(incident, run, other_case_id) do
    with {:ok, started} <-
           Cases.start_turn(
             incident.id,
             run.id,
             "case:split:reassess:#{incident.id}:#{other_case_id}",
             %{
               "objective" => "Investigate the Conditions assigned to this Case",
               "related_split_case_id" => other_case_id
             },
             %{"action" => "continue_resolution"},
             "Review Resolver limits",
             authorize?: false
           ),
         true <-
           started.status in [:charged, :duplicate] ||
             invalid("Split reassessment exhausted its Resolver budget"),
         {:ok, current} <- Cases.get_case(incident.id, authorize?: false),
         {:ok, _updated} <-
           Cases.record_case_pending_intent(
             current,
             current.revision,
             %{
               "action" => "resolve_turn",
               "turn_id" => started.value.id,
               "related_split_case_id" => other_case_id
             },
             authorize?: false
           ) do
      :ok
    end
  end

  defp split_key(args) do
    input =
      {args.id, args.expected_revision, Map.get(args, :source_turn_id),
       Enum.sort(args.condition_ids), Enum.sort_by(args.expected_conditions, & &1["id"]),
       args.reason}

    Budget.key("case:split", :erlang.term_to_binary(input, [:deterministic]))
  end

  defp lock_active_run(case_id) do
    ResolutionRun
    |> Ash.Query.for_read(:active_for_case, %{case_id: case_id})
    |> Ash.Query.lock(:for_update)
    |> Ash.read_one(authorize?: false)
    |> case do
      {:ok, nil} -> invalid("Active ResolutionRun is unavailable")
      result -> result
    end
  end

  defp lock(resource, id) do
    resource
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(id: id)
    |> Ash.Query.lock(:for_update)
    |> Ash.read_one(authorize?: false)
    |> case do
      {:ok, nil} -> invalid("Case is unavailable")
      result -> result
    end
  end

  defp invalid(message),
    do: {:error, Ash.Error.Changes.InvalidChanges.exception(message: message)}
end
