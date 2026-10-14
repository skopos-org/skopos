defmodule Skopos.Cases.Case.Preparations.Queue do
  @moduledoc false

  use Ash.Resource.Preparation
  require Ash.Query

  @impl true
  def prepare(query, options, _context) do
    text = Ash.Query.get_argument(query, :query)
    status = Ash.Query.get_argument(query, :status)
    ids = Ash.Query.get_argument(query, :ids)

    sort =
      case Ash.Query.get_argument(query, :sort) do
        :updated_asc -> [updated_at: :asc, id: :asc]
        :severity_desc -> [severity_rank: :desc, updated_at: :desc, id: :desc]
        _other -> [updated_at: :desc, id: :desc]
      end

    query =
      if is_nil(text) do
        query
      else
        Ash.Query.filter(
          query,
          contains(title, ^text) or contains(source, ^text) or contains(source_ref, ^text)
        )
      end

    query = if is_nil(status), do: query, else: Ash.Query.filter(query, status == ^status)
    query = if is_nil(ids), do: query, else: Ash.Query.filter(query, id in ^ids)
    query = Ash.Query.sort(query, sort)

    if options[:summary?] do
      Ash.Query.select(query, Skopos.Cases.Case.summary_fields())
    else
      Ash.Query.load(query, [:condition_count, :firing_condition_count])
    end
  end
end
