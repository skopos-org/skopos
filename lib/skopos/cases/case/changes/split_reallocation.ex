defmodule Skopos.Cases.Case.Changes.SplitReallocation do
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    turns = Ash.Changeset.get_argument(changeset, :turn_count)
    usage = Ash.Changeset.get_argument(changeset, :ai_usage_units)
    turn_limit = Ash.Changeset.get_attribute(changeset, :max_resolver_turns)
    usage_limit = Ash.Changeset.get_attribute(changeset, :max_ai_usage_units)

    if active_capacity?(
         %{max_resolver_turns: turn_limit, max_ai_usage_units: usage_limit},
         %{turn_count: turns, ai_usage_units: usage}
       ) do
      changeset
      |> Ash.Changeset.change_attribute(:status, :running)
      |> Ash.Changeset.change_attribute(:pending_intent, %{})
      |> Ash.Changeset.change_attribute(:stop_reason, nil)
      |> Ash.Changeset.change_attribute(:required_human_input, nil)
    else
      changeset
      |> Ash.Changeset.change_attribute(:status, :needs_attention)
      |> Ash.Changeset.change_attribute(:pending_intent, %{})
      |> Ash.Changeset.change_attribute(:stop_reason, "No Resolver capacity remains after split")
      |> Ash.Changeset.change_attribute(:required_human_input, "Increase Case limits")
    end
  end

  def active_capacity?(limits, counters) do
    limits.max_resolver_turns > Map.get(counters, :turn_count, 0) and
      limits.max_ai_usage_units > Map.get(counters, :ai_usage_units, 0)
  end
end
