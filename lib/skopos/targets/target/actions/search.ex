defmodule Skopos.Targets.Target.Actions.Search do
  use Ash.Resource.Actions.Implementation

  import Ash.Expr
  require Ash.Query

  alias Skopos.Targets
  alias Skopos.Targets.{ExternalIdentity, Relationship, SearchResult, Target}

  @impl true
  def run(input, _opts, _context) do
    query = input.arguments.query |> String.trim() |> String.downcase()
    max_results = input.arguments.max_results

    if query == "" do
      {:error, "query must contain non-whitespace characters"}
    else
      with {:ok, targets} <- read_index(Target, query, max_results),
           {:ok, identities} <- read_index(ExternalIdentity, query, max_results),
           {:ok, relationships} <- read_index(Relationship, query, max_results),
           {:ok, candidates} <-
             load_candidates(targets, identities, relationships, max_results) do
        {:ok, %SearchResult{targets: candidates}}
      end
    end
  end

  defp read_index(resource, query, limit) do
    resource
    |> Ash.Query.for_read(:search_index, %{query: query})
    |> Ash.Query.limit(limit)
    |> Ash.read(domain: Targets, authorize?: false)
  end

  defp load_candidates(targets, identities, relationships, limit) do
    ids =
      Enum.map(targets, & &1.id) ++
        Enum.map(identities, & &1.target_id) ++
        Enum.flat_map(relationships, &[&1.source_target_id, &1.destination_target_id])

    ids = Enum.uniq(ids)

    if ids == [] do
      {:ok, []}
    else
      Target
      |> Ash.Query.for_read(:read)
      |> Ash.Query.filter(expr(active == true and id in ^ids))
      |> Ash.Query.sort(name: :asc, id: :asc)
      |> Ash.Query.limit(limit)
      |> Ash.read(domain: Targets, authorize?: false)
    end
  end
end
