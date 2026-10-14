defmodule Skopos.Cases.Evidence.Preparations.ActiveCondition do
  @moduledoc false

  use Ash.Resource.Preparation

  require Ash.Query

  alias Skopos.Cases

  @impl true
  def prepare(query, _options, _context) do
    case Cases.active_conditions_for_case(Ash.Query.get_argument(query, :case_id),
           authorize?: false
         ) do
      {:ok, memberships} ->
        # An empty IN list is folded to SQL FALSE after the surrounding read
        # has already reserved parameters for its Case and kind filters.
        ids =
          case Enum.map(memberships, & &1.condition_id) do
            [] -> ["00000000-0000-0000-0000-000000000000"]
            values -> values
          end

        Ash.Query.filter(query, stored_content["condition_id"] in ^ids)

      {:error, error} ->
        Ash.Query.add_error(query, error)
    end
  end
end
