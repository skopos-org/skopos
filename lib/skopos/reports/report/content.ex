defmodule Skopos.Reports.Report.Content do
  @moduledoc false
  use Gettext, backend: Skopos.Gettext

  alias Skopos.Cases.Case

  @case_fields [
    :id,
    :revision,
    :trigger_kind,
    :source,
    :source_ref,
    :title,
    :severity,
    :status,
    :initial_context,
    :initial_target_id,
    :selected_target_id,
    :selected_target_revision,
    :authority_mode,
    :authority_setting_revision,
    :cancel_requested,
    :stop_reason,
    :required_human_input,
    :resolved_at,
    :inserted_at,
    :updated_at
  ]

  @run_fields [
    :id,
    :generation,
    :status,
    :active,
    :authority_mode,
    :turn_count,
    :target_request_count,
    :effect_count,
    :related_target_count,
    :ai_usage_units,
    :no_progress_turns,
    :started_at,
    :deadline_at,
    :ended_at,
    :resume_reason,
    :resumed_by_id,
    :revision
  ]

  @event_fields [:id, :resolution_run_id, :actor_id, :event_type, :inserted_at]

  @condition_fields [
    :id,
    :signal_correlation_id,
    :target_id,
    :predicate,
    :subject_ref,
    :state,
    :occurrence,
    :revision,
    :first_fired_at,
    :current_occurred_at
  ]

  @turn_fields [
    :id,
    :resolution_run_id,
    :ordinal,
    :status,
    :intent,
    :progress_kind,
    :started_at,
    :completed_at,
    :revision
  ]

  @evidence_fields [
    :id,
    :resolution_run_id,
    :turn_id,
    :kind,
    :source,
    :source_ref,
    :content,
    :observed_at,
    :inserted_at
  ]

  @proposal_fields [
    :id,
    :resolution_run_id,
    :source_turn_id,
    :proposed_for_id,
    :target_id,
    :access_method_id,
    :provider_id,
    :status,
    :authority_mode,
    :case_generation,
    :target_revision,
    :access_method_revision,
    :provider_revision,
    :request_kind,
    :purpose,
    :tool_id,
    :capability,
    :operation,
    :selectors,
    :parameters,
    :reason,
    :evidence_ids,
    :expected_result,
    :verification_intent,
    :preflight_status,
    :preflight_reason,
    :expires_at,
    :revision,
    :inserted_at
  ]

  @review_fields [
    :id,
    :proposal_id,
    :resolution_run_id,
    :outcome,
    :verdict,
    :purpose_assessment,
    :category,
    :reason,
    :selection_source,
    :provider_revision,
    :decided_at
  ]

  @approval_fields [
    :id,
    :proposal_id,
    :resolution_run_id,
    :actor_id,
    :decision,
    :source,
    :proposal_revision,
    :case_generation,
    :reason,
    :decided_at
  ]

  @operation_fields [
    :id,
    :resolution_run_id,
    :proposal_id,
    :approval_id,
    :actor_id,
    :target_id,
    :access_method_id,
    :provider_id,
    :status,
    :case_generation,
    :authority_mode,
    :target_revision,
    :access_method_revision,
    :provider_revision,
    :request_kind,
    :purpose,
    :capability,
    :operation,
    :selectors,
    :parameters,
    :accepted_at,
    :dispatch_started_at,
    :outcome_category,
    :reference,
    :result_details,
    :completed_at,
    :revision
  ]

  @verification_fields [
    :id,
    :operation_id,
    :proposal_id,
    :resolution_run_id,
    :actor_id,
    :target_id,
    :access_method_id,
    :provider_id,
    :status,
    :case_generation,
    :target_revision,
    :access_method_revision,
    :provider_revision,
    :tool_id,
    :capability,
    :operation,
    :selectors,
    :parameters,
    :expected,
    :operation_reference,
    :accepted_at,
    :dispatch_started_at,
    :outcome_category,
    :facts,
    :provider_evidence,
    :observed_at,
    :completed_at,
    :revision
  ]

  @target_events ["case_opened", "case_target_selected", "related_target_traversed"]

  def build(%Case{} = incident, records) do
    locale = Atom.to_string(incident.report_language)
    events = records.events

    %{
      "schema_version" => 1,
      "language" => locale,
      "labels" => labels(locale),
      "outcome_label" => outcome_label(locale, incident.status),
      "case" => plain(incident, @case_fields),
      "conditions" => plain(Map.get(records, :conditions, []), @condition_fields),
      "timeline" => plain(records.events, @event_fields),
      "resolution_turn_id" => resolution_turn_id(events),
      "resolution_review_event_id" => resolution_review_event_id(events),
      "recovery_reviews" => recovery_reviews(events),
      "target_path" =>
        events |> Enum.filter(&(&1.event_type in @target_events)) |> Enum.map(&target_event/1),
      "resolution_runs" => plain(records.runs, @run_fields),
      "resolver_turns" => Enum.map(records.turns, &turn/1),
      "raw_evidence" => plain(records.evidence, @evidence_fields),
      "proposals" => plain(records.proposals, @proposal_fields),
      "reviews" => plain(records.reviews, @review_fields),
      "approvals" => plain(records.approvals, @approval_fields),
      "operations" => plain(records.operations, @operation_fields),
      "verifications" => plain(records.verifications, @verification_fields),
      "unresolved" => %{
        "stop_reason" => incident.stop_reason,
        "required_human_input" => incident.required_human_input
      }
    }
  end

  defp resolution_turn_id(events) do
    events
    |> Enum.find(&(&1.event_type == "case_resolved"))
    |> case do
      nil -> nil
      event -> event.data["source_turn_id"]
    end
  end

  defp resolution_review_event_id(events) do
    events
    |> Enum.find(&(&1.event_type == "case_resolved"))
    |> case do
      nil -> nil
      event -> event.data["recovery_review_event_id"]
    end
  end

  defp recovery_reviews(events) do
    events
    |> Enum.filter(&(&1.event_type == "recovery_review_decided"))
    |> Enum.map(fn event ->
      %{
        "id" => event.id,
        "source_turn_id" => event.data["source_turn_id"],
        "verdict" => event.data["verdict"],
        "reason" => event.data["reason"],
        "evidence_ids" => event.data["evidence_ids"],
        "desired_outcome_claims" => event.data["desired_outcome_claims"],
        "desired_outcome_assessment" => event.data["desired_outcome_assessment"],
        "provider_id" => event.data["provider_id"],
        "inserted_at" => event.inserted_at
      }
    end)
  end

  def digest(content) do
    content
    |> :erlang.term_to_binary([:deterministic])
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp labels(locale) do
    Gettext.with_locale(Skopos.Gettext, locale, fn ->
      %{
        "summary" => dgettext("reports", "Summary"),
        "conditions" => dgettext("reports", "Monitored conditions"),
        "timeline" => dgettext("reports", "Timeline"),
        "target_path" => dgettext("reports", "Target path"),
        "resolution_runs" => dgettext("reports", "Resolution runs"),
        "resolver_turns" => dgettext("reports", "Resolver decisions"),
        "raw_evidence" => dgettext("reports", "Raw evidence"),
        "proposals" => dgettext("reports", "Proposals"),
        "reviews" => dgettext("reports", "Reviews"),
        "approvals" => dgettext("reports", "Approvals"),
        "operations" => dgettext("reports", "Operations"),
        "verifications" => dgettext("reports", "Verifications"),
        "unresolved" => dgettext("reports", "Unresolved items")
      }
    end)
  end

  defp outcome_label(locale, outcome) do
    Gettext.with_locale(Skopos.Gettext, locale, fn ->
      case outcome do
        :resolved -> dgettext("reports", "Resolved")
        :needs_attention -> dgettext("reports", "Needs attention")
        :cancelled -> dgettext("reports", "Cancelled")
      end
    end)
  end

  defp turn(turn) do
    result = turn.result || %{}

    turn
    |> plain(@turn_fields)
    |> Map.merge(%{
      "outcome" => result["outcome"],
      "decision" => plain(result["intent"]),
      "usage" => plain(result["usage"]),
      "failure_category" => result["category"],
      "failure_message" => result["message"]
    })
  end

  defp target_event(event) do
    fields =
      case event.event_type do
        "case_opened" ->
          ~w(selected_target_id selected_target_revision)

        "case_target_selected" ->
          ~w(evidence_ids target_id target_revision prior_target_id prior_target_revision reason)

        "related_target_traversed" ->
          ~w(source_turn_id relationship_id relationship_revision source_target_id source_target_revision destination_target_id destination_target_revision next_target_id next_target_revision evidence_ids reason)
      end

    event
    |> plain(@event_fields)
    |> Map.put("details", event.data |> Map.take(fields) |> plain())
  end

  defp plain(records, fields) when is_list(records),
    do: Enum.map(records, &plain(&1, fields))

  defp plain(record, fields), do: record |> Map.take(fields) |> plain()

  defp plain(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp plain(%NaiveDateTime{} = value), do: NaiveDateTime.to_iso8601(value)
  defp plain(%_{} = value), do: value |> Map.from_struct() |> plain()

  defp plain(value) when is_map(value),
    do: Map.new(value, fn {key, nested} -> {to_string(key), plain(nested)} end)

  defp plain(value) when is_list(value), do: Enum.map(value, &plain/1)
  defp plain(value) when is_atom(value) and not is_nil(value), do: Atom.to_string(value)
  defp plain(value), do: value
end
