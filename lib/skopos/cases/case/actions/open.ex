defmodule Skopos.Cases.Case.Actions.Open do
  use Ash.Resource.Actions.Implementation

  alias Skopos.{Accounts, Cases}

  alias Skopos.Cases.{AuthoritySetting, Case, CaseDispatch, CaseEvent, ResolutionRun}
  alias Skopos.Cases.Case.Symptom, as: CaseSymptom

  alias Skopos.Targets

  @impl true
  def run(input, _opts, context) do
    arguments = input.arguments

    with :ok <- validate_trigger(arguments.trigger_kind, context.actor),
         :ok <- validate_desired_outcome(arguments),
         {:ok, existing} <- existing_case(arguments) do
      if existing do
        reuse_existing(existing, arguments)
      else
        with {:ok, initial_target} <- load_initial_target(arguments.initial_target_id) do
          create_case(arguments, initial_target, context.actor)
        end
      end
    end
  end

  defp validate_desired_outcome(%{trigger_kind: :signal}), do: :ok

  defp validate_desired_outcome(%{initial_context: context}) do
    if CaseSymptom.valid_desired_outcome?(context["desired_outcome"]),
      do: :ok,
      else:
        {:error,
         Ash.Error.Changes.InvalidAttribute.exception(
           field: :initial_context,
           message: "Manual and audit Cases require a desired_outcome"
         )}
  end

  defp create_case(arguments, initial_target, actor) do
    result =
      Ash.transact([AuthoritySetting, Case, CaseDispatch, ResolutionRun, CaseEvent], fn ->
        with {:ok, setting} <- locked_current_setting(),
             {:ok, report_language} <- report_language(arguments, setting, actor),
             now <- DateTime.utc_now(),
             {:ok, incident} <-
               create_case_record(arguments, initial_target, setting, actor, report_language),
             {:ok, run} <- create_run(incident, setting, now),
             {:ok, _event} <- create_opened_event(incident, run, actor, arguments),
             :ok <- dispatch_manual_case(arguments, incident, now) do
          incident
        end
      end)

    case result do
      {:error, _error} = failed ->
        case existing_case(arguments) do
          {:ok, %Case{} = existing} -> reuse_existing(existing, arguments)
          _other -> failed
        end

      success ->
        success
    end
  end

  defp existing_case(arguments) do
    case_by_trigger(arguments)
  end

  defp reuse_existing(%Case{trigger_kind: :signal} = existing, _arguments),
    do: {:ok, existing}

  defp reuse_existing(%Case{} = existing, arguments) do
    if existing.title == arguments.title and existing.severity == arguments.severity and
         existing.initial_context == arguments.initial_context and
         existing.initial_target_id == arguments.initial_target_id do
      {:ok, existing}
    else
      {:error,
       Ash.Error.Changes.InvalidAttribute.exception(
         field: :initial_context,
         message: "A Case with this source_ref already has a different immutable request"
       )}
    end
  end

  defp case_by_trigger(%{trigger_kind: :signal} = arguments) do
    Cases.active_signal_case_by_trigger(arguments.source, arguments.source_ref,
      authorize?: false,
      not_found_error?: false
    )
  end

  defp case_by_trigger(arguments) do
    Cases.case_by_trigger(arguments.trigger_kind, arguments.source, arguments.source_ref,
      authorize?: false,
      not_found_error?: false
    )
  end

  defp locked_current_setting(attempts \\ 2) do
    result =
      AuthoritySetting
      |> Ash.Query.for_read(:current)
      |> Ash.Query.lock(:for_update)
      |> Ash.read_one(authorize?: false)

    case result do
      {:ok, %AuthoritySetting{} = setting} -> {:ok, setting}
      {:ok, nil} when attempts > 1 -> locked_current_setting(attempts - 1)
      {:ok, nil} -> {:error, "Standing authority setting is unavailable"}
      {:error, _error} = error -> error
    end
  end

  defp create_case_record(arguments, initial_target, setting, actor, report_language) do
    {status, pending_intent, stop_reason, required_human_input} =
      initial_state(arguments, setting)

    attrs = %{
      trigger_kind: arguments.trigger_kind,
      source: arguments.source,
      source_ref: arguments.source_ref,
      title: arguments.title,
      severity: arguments.severity,
      report_language: report_language,
      status: status,
      initial_context: arguments.initial_context,
      authority_setting_id: setting.id,
      authority_setting_revision: setting.setting_revision,
      authority_mode: setting.authority_mode,
      max_elapsed_seconds: setting.max_elapsed_seconds,
      max_resolver_turns: setting.max_resolver_turns,
      max_target_requests: setting.max_target_requests,
      max_effects: setting.max_effects,
      max_related_targets: setting.max_related_targets,
      max_ai_usage_units: setting.max_ai_usage_units,
      max_no_progress_turns: setting.max_no_progress_turns,
      cancel_requested: false,
      pending_intent: pending_intent,
      stop_reason: stop_reason,
      required_human_input: required_human_input,
      initial_target_id: arguments.initial_target_id,
      selected_target_id: initial_target && initial_target.id,
      selected_target_revision: initial_target && initial_target.revision,
      current_owner_id: owner_id(arguments.trigger_kind, setting, actor)
    }

    Cases.create_case_record(attrs, actor: actor, authorize?: false)
  end

  defp create_run(incident, setting, now) do
    attrs = %{
      case_id: incident.id,
      generation: 1,
      active: true,
      status: run_status(incident.status),
      authority_mode: setting.authority_mode,
      max_elapsed_seconds: setting.max_elapsed_seconds,
      max_resolver_turns: setting.max_resolver_turns,
      max_target_requests: setting.max_target_requests,
      max_effects: setting.max_effects,
      max_related_targets: setting.max_related_targets,
      max_ai_usage_units: setting.max_ai_usage_units,
      max_no_progress_turns: setting.max_no_progress_turns,
      turn_count: 0,
      target_request_count: 0,
      effect_count: 0,
      related_target_count: 0,
      ai_usage_units: 0,
      no_progress_turns: 0,
      started_at: now,
      deadline_at: DateTime.add(now, setting.max_elapsed_seconds, :second)
    }

    Cases.create_resolution_run_record(attrs, authorize?: false)
  end

  defp create_opened_event(incident, run, actor, arguments) do
    Cases.create_case_event_record(
      %{
        case_id: incident.id,
        resolution_run_id: run.id,
        actor_id: actor_id(actor),
        event_type: "case_opened",
        idempotency_key:
          idempotency_key("open", [
            arguments.trigger_kind,
            arguments.source,
            arguments.source_ref
          ]),
        data: %{
          "trigger_kind" => to_string(arguments.trigger_kind),
          "source" => arguments.source,
          "source_ref" => arguments.source_ref,
          "report_language" => to_string(incident.report_language),
          "authority_setting_revision" => incident.authority_setting_revision,
          "run_generation" => run.generation,
          "selected_target_id" => incident.selected_target_id,
          "selected_target_revision" => incident.selected_target_revision
        }
      },
      authorize?: false
    )
  end

  defp dispatch_manual_case(%{trigger_kind: :manual}, incident, now) do
    with {:ok, _dispatch} <-
           Cases.create_case_dispatch_record(
             %{
               case_id: incident.id,
               state: :collecting,
               first_received_at: now,
               due_at: now,
               anchor_target_id: incident.initial_target_id
             },
             authorize?: false
           ),
         {:ok, job} <-
           %{"case_id" => incident.id}
           |> Skopos.Cases.CaseDispatch.Worker.new(scheduled_at: now)
           |> Oban.insert(),
         true <- is_integer(job.id) || {:error, "Initial Case dispatch job was not persisted"} do
      :ok
    end
  end

  defp dispatch_manual_case(_arguments, _incident, _now), do: :ok

  defp validate_trigger(:signal, actor) when not is_nil(actor),
    do: {:error, "Signal Cases must be opened by native Condition admission"}

  defp validate_trigger(kind, _actor) when kind in [:signal, :manual, :audit], do: :ok
  defp validate_trigger(_kind, _actor), do: {:error, "Case trigger kind is invalid"}

  defp load_initial_target(nil), do: {:ok, nil}

  defp load_initial_target(id) do
    case Targets.get_target(id, authorize?: false) do
      {:ok, %{active: true} = target} -> {:ok, target}
      {:ok, _target} -> {:error, "Initial Target is inactive"}
      {:error, _error} -> {:error, "Initial Target is unavailable"}
    end
  end

  defp initial_state(%{trigger_kind: :signal}, %{signal_automation_enabled: false}),
    do:
      {:needs_attention, %{"action" => "start_resolution"}, "Signal automation is disabled",
       "Enable automation or claim the Case"}

  defp initial_state(_arguments, _setting), do: {:running, %{}, nil, nil}

  defp run_status(:needs_attention), do: :needs_attention
  defp run_status(_status), do: :running

  defp idempotency_key(prefix, values) do
    digest =
      values
      |> :erlang.term_to_binary()
      |> then(&:crypto.hash(:sha256, &1))
      |> Base.encode16(case: :lower)

    "#{prefix}:#{digest}"
  end

  defp actor_id(nil), do: nil
  defp actor_id(actor), do: actor.id

  defp owner_id(:signal, %{signal_automation_enabled: true, changed_by_id: id}, _actor), do: id
  defp owner_id(:audit, %{changed_by_id: id}, _actor), do: id
  defp owner_id(_trigger_kind, _setting, actor), do: actor_id(actor)

  defp report_language(%{trigger_kind: :signal}, setting, _actor),
    do: preferred_language(setting.changed_by_id, :en)

  defp report_language(%{trigger_kind: :manual}, _setting, %{id: user_id}),
    do: preferred_language(user_id, :en)

  defp report_language(arguments, _setting, _actor), do: {:ok, arguments.report_language}

  defp preferred_language(nil, fallback), do: {:ok, fallback}

  defp preferred_language(user_id, _fallback) do
    with {:ok, user} <- Accounts.get_user(user_id, authorize?: false) do
      {:ok, user.preferred_language}
    end
  end
end
