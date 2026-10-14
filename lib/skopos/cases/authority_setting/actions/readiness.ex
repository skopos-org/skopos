defmodule Skopos.Cases.AuthoritySetting.Actions.Readiness do
  use Ash.Resource.Actions.Implementation

  alias Skopos.{Cases, Providers, Targets}
  require Ash.Query

  @impl true
  def run(_input, _opts, context) do
    with {:ok, setting} <- Cases.current_authority_setting(actor: context.actor),
         {:ok, ai} <- eligible_provider(:ai, context.actor),
         {:ok, signal} <- eligible_provider(:signal, context.actor),
         {:ok, resolvers} <-
           Providers.eligible_ai_usage_role_summaries(:resolver, authorize?: false),
         {:ok, reviewers} <-
           Providers.eligible_ai_usage_role_summaries(:reviewer, authorize?: false),
         {:ok, methods} <-
           Targets.page_access_methods(
             page: [limit: 1],
             actor: context.actor,
             query: Ash.Query.filter(Targets.AccessMethod, check_current == true)
           ),
         {:ok, targets} <-
           Targets.page_target_references(%{active: true}, page: [limit: 1], actor: context.actor) do
      resolver = resolvers != []
      reviewer = reviewers != []

      authority =
        not is_nil(setting.changed_by_id) and
          (setting.authority_mode != :auto or reviewer)

      target = methods.results != []

      {:ok,
       %{
         ai: ai,
         resolver: resolver,
         reviewer: reviewer,
         authority: authority,
         signal: signal,
         target: target,
         complete: ai and resolver and authority and signal and target,
         authority_mode: setting.authority_mode,
         sole_reviewer_provider_id: sole_provider(reviewers),
         first_target_id:
           case targets.results do
             [first] -> first.id
             [] -> nil
           end
       }}
    end
  end

  defp eligible_provider(kind, actor) do
    with {:ok, page} <-
           Providers.page_provider_summaries(%{kinds: [kind], eligible: true},
             page: [limit: 1],
             actor: actor
           ) do
      {:ok, page.results != []}
    end
  end

  defp sole_provider([assignment]), do: assignment.provider_id
  defp sole_provider(_assignments), do: nil
end
