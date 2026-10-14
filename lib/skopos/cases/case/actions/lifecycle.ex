defmodule Skopos.Cases.Case.Actions.Lifecycle do
  use Ash.Resource.Actions.Implementation

  alias Skopos.Accounts
  alias Skopos.{Cases, Targets}
  alias Skopos.Cases.{Case, CaseEvent, ResolutionRun}

  @limit_fields [
    :max_elapsed_seconds,
    :max_resolver_turns,
    :max_target_requests,
    :max_effects,
    :max_related_targets,
    :max_ai_usage_units,
    :max_no_progress_turns
  ]

  @impl true
  def run(input, opts, context) do
    case opts[:operation] do
      :claim -> claim(input.arguments, context.actor)
      :handoff -> handoff(input.arguments, context.actor)
      :request_cancellation -> request_cancellation(input.arguments, context.actor)
      :require_attention -> require_attention(input.arguments, context.actor)
      :resume -> resume(input.arguments, context.actor)
      :resume_after_target_registration -> resume_after_target_registration(input.arguments)
    end
  end

  defp claim(arguments, actor) do
    key = idempotency_key("claim", [arguments.id, arguments.expected_revision, actor.id])

    transition_once(arguments.id, key, fn incident ->
      with :ok <- ensure_mutable(incident) do
        record_owner_with_event(
          incident,
          arguments.expected_revision,
          nil,
          actor,
          "case_claimed",
          key,
          actor.id,
          %{"owner_id" => actor.id}
        )
      end
    end)
  end

  defp handoff(arguments, actor) do
    key =
      idempotency_key("handoff", [
        arguments.id,
        arguments.expected_revision,
        arguments.owner_id
      ])

    transition_once(arguments.id, key, fn incident ->
      with :ok <- ensure_mutable(incident),
           :ok <- ensure_operational_owner(arguments.owner_id) do
        record_owner_with_event(
          incident,
          arguments.expected_revision,
          nil,
          actor,
          "case_handed_off",
          key,
          arguments.owner_id,
          %{"from_owner_id" => incident.current_owner_id, "to_owner_id" => arguments.owner_id}
        )
      end
    end)
  end

  defp request_cancellation(arguments, actor) do
    key = idempotency_key("cancel", [arguments.id, arguments.expected_revision])

    transition_once(arguments.id, key, fn incident ->
      with :ok <- ensure_mutable(incident) do
        cancel(incident, arguments.expected_revision, actor, key)
      end
    end)
  end

  defp cancel(incident, expected_revision, actor, key) do
    now = DateTime.utc_now()

    Ash.transact([Case, ResolutionRun, CaseEvent], fn ->
      with {:ok, run} <- Cases.active_resolution_run(incident.id, authorize?: false),
           {:ok, updated} <-
             Cases.record_case_cancellation(incident, expected_revision,
               actor: actor,
               authorize?: false
             ),
           {:ok, cancelled_run} <-
             Cases.retire_resolution_run(
               run,
               run.revision,
               %{status: :cancelled, ended_at: now},
               authorize?: false
             ),
           {:ok, _event} <-
             create_event(updated, cancelled_run, actor, "case_cancelled", key, %{
               "prior_status" => to_string(incident.status)
             }) do
        updated
      end
    end)
  end

  defp require_attention(arguments, actor) do
    transition_once(arguments.id, arguments.idempotency_key, fn incident ->
      with {:ok, run} <- active_run(incident.id, arguments.resolution_run_id),
           true <-
             run.revision == arguments.expected_run_revision ||
               stale(ResolutionRun) do
        Ash.transact([Case, ResolutionRun, CaseEvent], fn ->
          with {:ok, updated} <-
                 Cases.record_case_attention(
                   incident,
                   arguments.expected_revision,
                   arguments.reason,
                   arguments.pending_intent,
                   arguments.required_human_input,
                   actor: actor,
                   authorize?: false
                 ),
               {:ok, _paused} <-
                 Cases.pause_resolution_run(
                   run,
                   arguments.expected_run_revision,
                   authorize?: false
                 ),
               {:ok, _event} <-
                 create_event(
                   updated,
                   run,
                   actor,
                   "case_needs_attention",
                   arguments.idempotency_key,
                   %{
                     "reason" => arguments.reason,
                     "pending_intent" => arguments.pending_intent,
                     "required_human_input" => arguments.required_human_input
                   }
                 ) do
            updated
          end
        end)
      end
    end)
  end

  defp resume(arguments, actor) do
    key =
      idempotency_key("resume", [
        arguments.id,
        arguments.resolution_run_id,
        arguments.expected_run_revision
      ])

    result =
      case event(arguments.id, key) do
        {:ok, %CaseEvent{}} -> active_run_result(arguments.id)
        {:ok, nil} -> resume_with_retry(arguments, actor, key)
        {:error, _error} = error -> error
      end

    with {:ok, run} <- result,
         :ok <- start_resumed_run(arguments.id, run, "Continue resolution after operator resume") do
      {:ok, run}
    end
  end

  defp resume_after_target_registration(arguments) do
    key =
      idempotency_key("target_registration_resume", [
        arguments.id,
        arguments.external_identity_id,
        arguments.expected_identity_revision
      ])

    result =
      case event(arguments.id, key) do
        {:ok, %CaseEvent{}} -> active_run_result(arguments.id)
        {:ok, nil} -> resume_after_target_registration_once(arguments, key)
        {:error, _error} = error -> error
      end

    with {:ok, run} <- result,
         :ok <-
           start_resumed_run(
             arguments.id,
             run,
             "Continue resolution after Target registration"
           ) do
      {:ok, run}
    end
  end

  defp resume_after_target_registration_once(arguments, key) do
    with {:ok, incident} <- Cases.get_case(arguments.id, authorize?: false),
         :ok <- target_registration_wait(incident),
         {:ok, identity} <-
           Targets.get_external_identity(arguments.external_identity_id, authorize?: false),
         :ok <- current_identity(identity, arguments.expected_identity_revision),
         :ok <- matching_signal_identity(incident, identity),
         {:ok, %{active: true} = target} <-
           Targets.get_target(identity.target_id, authorize?: false),
         {:ok, run} <- Cases.active_resolution_run(incident.id, authorize?: false),
         true <-
           run.status == :needs_attention || {:error, "ResolutionRun does not need attention"},
         resume_arguments <- registration_resume_arguments(incident, run),
         {:ok, resumed} <-
           resume_transaction(incident, run, resume_arguments, nil, key,
             selected_target: target,
             target_identity: identity
           ) do
      {:ok, resumed}
    else
      {:error, _error} = failed ->
        case event(arguments.id, key) do
          {:ok, %CaseEvent{}} -> active_run_result(arguments.id)
          _other -> failed
        end
    end
  end

  defp start_resumed_run(case_id, run, objective) do
    turn_key = "resume:#{run.id}:#{run.generation}"

    case Cases.start_turn(
           case_id,
           run.id,
           turn_key,
           %{"objective" => objective},
           %{"action" => "continue"},
           "Review Case inputs and limits",
           authorize?: false
         ) do
      {:ok, %{status: status}} when status in [:charged, :duplicate] -> :ok
      {:ok, %{status: :exhausted}} -> {:error, "Resumed Case exhausted its Resolver limits"}
      {:error, _error} = error -> error
    end
  end

  defp resume_with_retry(arguments, actor, key) do
    case resume_once(arguments, actor, key) do
      {:error, _error} = failed ->
        case event(arguments.id, key) do
          {:ok, %CaseEvent{}} -> active_run_result(arguments.id)
          _other -> failed
        end

      success ->
        success
    end
  end

  defp resume_once(arguments, actor, key) do
    with {:ok, incident} <- Cases.get_case(arguments.id, authorize?: false),
         true <- incident.status == :needs_attention || {:error, "Case does not need attention"},
         true <-
           incident.revision == arguments.expected_case_revision ||
             stale(Case),
         {:ok, run} <- active_run(incident.id, arguments.resolution_run_id),
         true <-
           run.revision == arguments.expected_run_revision ||
             stale(ResolutionRun),
         :ok <- validate_extension(run, arguments) do
      resume_transaction(incident, run, arguments, actor, key)
    end
  end

  defp resume_transaction(incident, run, arguments, actor, key, options \\ []) do
    now = DateTime.utc_now()

    Ash.transact([Case, ResolutionRun, CaseEvent], fn ->
      with {:ok, _retired} <-
             Cases.retire_resolution_run(
               run,
               arguments.expected_run_revision,
               %{status: :superseded, ended_at: now},
               authorize?: false
             ),
           {:ok, updated_case} <-
             Cases.record_case_resume(
               incident,
               arguments.expected_case_revision,
               arguments
               |> Map.take([:authority_mode | @limit_fields])
               |> resume_case_attributes(actor, options),
               actor: actor,
               authorize?: false
             ),
           {:ok, next_run} <- create_resumed_run(incident, run, arguments, actor, now),
           {:ok, _event} <-
             create_event(
               updated_case,
               next_run,
               actor,
               "case_resumed",
               key,
               Map.merge(
                 %{
                   "prior_run_id" => run.id,
                   "prior_generation" => run.generation,
                   "new_generation" => next_run.generation,
                   "reason" => arguments.reason,
                   "prior" => settings_map(run),
                   "new" => settings_map(next_run)
                 },
                 target_registration_event(options)
               )
             ) do
        next_run
      end
    end)
  end

  defp create_resumed_run(incident, run, arguments, actor, now) do
    attrs =
      arguments
      |> Map.take([:authority_mode | @limit_fields])
      |> Map.merge(%{
        case_id: incident.id,
        generation: run.generation + 1,
        active: true,
        status: :running,
        turn_count: 0,
        target_request_count: 0,
        effect_count: 0,
        related_target_count: 0,
        ai_usage_units: 0,
        no_progress_turns: 0,
        started_at: now,
        deadline_at: DateTime.add(now, arguments.max_elapsed_seconds, :second),
        resume_reason: arguments.reason,
        resumed_by_id: actor && actor.id
      })

    Cases.create_resolution_run_record(attrs, authorize?: false)
  end

  defp target_registration_wait(%{
         trigger_kind: :signal,
         status: :needs_attention,
         selected_target_id: nil,
         selected_target_revision: nil,
         pending_intent: %{"action" => "provide_human_input"}
       }),
       do: :ok

  defp target_registration_wait(_incident),
    do: {:error, "Case is not waiting for Target registration"}

  defp current_identity(%{active: true, revision: revision}, revision), do: :ok
  defp current_identity(_identity, _revision), do: {:error, "ExternalIdentity changed"}

  defp matching_signal_identity(
         %{
           source: source,
           initial_context: %{"target_ref" => %{"kind" => kind, "value" => value}}
         },
         %{source: source, kind: kind, value: value}
       ),
       do: :ok

  defp matching_signal_identity(_incident, _identity),
    do: {:error, "ExternalIdentity does not match the Case signal reference"}

  defp registration_resume_arguments(incident, run) do
    run
    |> Map.take([:authority_mode | @limit_fields])
    |> Map.merge(%{
      id: incident.id,
      expected_case_revision: incident.revision,
      resolution_run_id: run.id,
      expected_run_revision: run.revision,
      reason: "The registered ExternalIdentity now resolves the firing signal to a Target"
    })
  end

  defp resume_case_attributes(attributes, nil, options) do
    case options[:selected_target] do
      nil ->
        attributes

      target ->
        Map.merge(attributes, %{
          selected_target_id: target.id,
          selected_target_revision: target.revision
        })
    end
  end

  defp resume_case_attributes(attributes, actor, _options),
    do: Map.put(attributes, :current_owner_id, actor.id)

  defp target_registration_event(options) do
    case {options[:selected_target], options[:target_identity]} do
      {%{id: target_id, revision: target_revision},
       %{id: identity_id, revision: identity_revision}} ->
        %{
          "target_id" => target_id,
          "target_revision" => target_revision,
          "external_identity_id" => identity_id,
          "external_identity_revision" => identity_revision
        }

      _other ->
        %{}
    end
  end

  defp validate_extension(run, arguments) do
    case Enum.find(@limit_fields, &(Map.fetch!(arguments, &1) < Map.fetch!(run, &1))) do
      nil ->
        :ok

      field ->
        {:error,
         Ash.Error.Changes.InvalidAttribute.exception(
           field: field,
           value: Map.fetch!(arguments, field),
           message: "cannot be lower than the prior run limit"
         )}
    end
  end

  defp transition_once(case_id, key, transition) do
    case event(case_id, key) do
      {:ok, %CaseEvent{}} -> Cases.get_case(case_id, authorize?: false)
      {:ok, nil} -> perform_transition(case_id, key, transition)
      {:error, _error} = error -> error
    end
  end

  defp stale(resource) do
    {:error, Ash.Error.Changes.StaleRecord.exception(resource: resource, field: :revision)}
  end

  defp perform_transition(case_id, key, transition) do
    with {:ok, incident} <- Cases.get_case(case_id, authorize?: false) do
      case transition.(incident) do
        {:error, _error} = failed ->
          case event(case_id, key) do
            {:ok, %CaseEvent{}} -> Cases.get_case(case_id, authorize?: false)
            _other -> failed
          end

        success ->
          success
      end
    end
  end

  defp record_owner_with_event(
         incident,
         expected_revision,
         run,
         actor,
         event_type,
         key,
         owner_id,
         data
       ) do
    Ash.transact([Case, CaseEvent], fn ->
      with {:ok, updated} <-
             Cases.record_case_owner(incident, expected_revision, owner_id,
               actor: actor,
               authorize?: false
             ),
           {:ok, _event} <- create_event(updated, run, actor, event_type, key, data) do
        updated
      end
    end)
  end

  defp create_event(incident, run, actor, event_type, key, data) do
    Cases.create_case_event_record(
      %{
        case_id: incident.id,
        resolution_run_id: run && run.id,
        actor_id: actor && actor.id,
        event_type: event_type,
        idempotency_key: key,
        data: data
      },
      authorize?: false
    )
  end

  defp active_run(case_id, expected_id) do
    case Cases.active_resolution_run(case_id, authorize?: false) do
      {:ok, %{id: ^expected_id} = run} -> {:ok, run}
      {:ok, _run} -> {:error, "Active ResolutionRun changed"}
      {:error, _error} = error -> error
    end
  end

  defp active_run_result(case_id), do: Cases.active_resolution_run(case_id, authorize?: false)

  defp event(case_id, key) do
    Cases.case_event_by_idempotency(case_id, key,
      authorize?: false,
      not_found_error?: false
    )
  end

  defp ensure_operational_owner(id) do
    case Accounts.get_user(id, authorize?: false) do
      {:ok, %{role: role}} when role in [:admin, :operator] -> :ok
      {:ok, _user} -> {:error, "Case owner must be an administrator or operator"}
      {:error, _error} -> {:error, "Case owner is unavailable"}
    end
  end

  defp ensure_mutable(%{status: status}) when status in [:running, :needs_attention],
    do: :ok

  defp ensure_mutable(_incident), do: {:error, "Case is already terminal"}

  defp settings_map(record) do
    %{
      "authority_mode" => to_string(record.authority_mode),
      "max_elapsed_seconds" => record.max_elapsed_seconds,
      "max_resolver_turns" => record.max_resolver_turns,
      "max_target_requests" => record.max_target_requests,
      "max_effects" => record.max_effects,
      "max_related_targets" => record.max_related_targets,
      "max_ai_usage_units" => record.max_ai_usage_units,
      "max_no_progress_turns" => record.max_no_progress_turns
    }
  end

  defp idempotency_key(prefix, values) do
    digest =
      values
      |> :erlang.term_to_binary()
      |> then(&:crypto.hash(:sha256, &1))
      |> Base.encode16(case: :lower)

    "#{prefix}:#{digest}"
  end
end
