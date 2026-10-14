defmodule Skopos.Cases.Turn.TraversalBoundary do
  @moduledoc false

  def immediate_reverse?(relationship_id, %{
        "source" => "target_relationship",
        "relationship_id" => relationship_id
      }),
      do: true

  def immediate_reverse?(relationship_id, %{
        "source" => "target_result",
        "prior_relationship_id" => relationship_id
      }),
      do: true

  def immediate_reverse?(_relationship_id, _intent), do: false
end
