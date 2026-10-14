defmodule Skopos.Cases.Case.Actions.Reconnect do
  use Ash.Resource.Actions.Implementation

  alias Skopos.Cases
  alias Skopos.Cases.Case.ReconnectSnapshot
  alias Skopos.Cases.AIInvocation
  alias Skopos.Cases.Case.ConditionRecovery, as: ConditionRecovery
  alias Skopos.Reports

  @impl true
  def run(input, _opts, context) do
    case_id = input.arguments.id
    opts = [actor: context.actor]

    with {:ok, incident} <-
           Cases.get_case(
             case_id,
             Keyword.put(
               opts,
               :load,
               [:condition_count, :firing_condition_count] ++ AIInvocation.usage_aggregates()
             )
           ),
         {:ok, memberships} <-
           Cases.active_conditions_for_case(case_id,
             authorize?: false,
             query: [select: [:id, :case_id, :condition_id, :attached_at, :detached_at]],
             load: [:condition]
           ),
         {:ok, conditions} <- current_conditions(incident, memberships),
         {:ok, condition_context} <- latest_condition_context(incident, conditions, opts),
         {:ok, runs} <- Cases.resolution_runs_for_case(case_id, opts),
         {:ok, proposals} <- Cases.proposal_summaries_for_case(case_id, opts),
         {:ok, operations} <- Cases.operation_summaries_for_case(case_id, opts),
         {:ok, attempts} <- Cases.verification_summaries_for_case(case_id, opts),
         {:ok, reports} <- Reports.report_summaries_for_case(case_id, opts) do
      {:ok,
       %ReconnectSnapshot{
         case: incident,
         ai_usage: AIInvocation.usage_summary(incident),
         conditions: conditions,
         condition_context: condition_context,
         resolution_runs: runs,
         proposals: proposals,
         operations: operations,
         verification_attempts: attempts,
         reports: reports
       }}
    end
  end

  defp latest_condition_context(_incident, [], _opts),
    do: {:ok, %{groups: nil, assessments: nil}}

  defp latest_condition_context(incident, conditions, opts) do
    revisions =
      Skopos.Cases.Case.ConditionContext.condition_revisions(Enum.map(conditions, & &1.condition))

    with {:ok, groups} <-
           Cases.latest_turn_condition_context(incident.id, revisions, "condition_groups", opts),
         {:ok, assessments} <-
           Cases.latest_turn_condition_context(
             incident.id,
             revisions,
             "condition_assessments",
             opts
           ) do
      {:ok, %{groups: List.first(groups), assessments: List.first(assessments)}}
    end
  end

  defp current_conditions(incident, memberships) do
    with {:ok, assessments} <- current_assessments(incident, memberships) do
      {:ok,
       Enum.map(memberships, fn membership ->
         %{
           condition: membership.condition,
           membership: membership,
           assessment: Map.get(assessments, membership.condition_id)
         }
       end)}
    end
  end

  defp current_assessments(_incident, []), do: {:ok, %{}}

  defp current_assessments(incident, memberships) do
    case ConditionRecovery.assess_loaded(incident, memberships) do
      {:ok, items} -> {:ok, Map.new(items, &{&1.condition_id, &1})}
      {:error, %ConditionRecovery.EffectIncomplete{}} -> {:ok, %{}}
      {:error, _cause} = error -> error
    end
  end
end
