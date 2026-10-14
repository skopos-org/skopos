defmodule Skopos.Cases.Case.Changes.QueueResolverTurn do
  use Ash.Resource.Change

  alias Skopos.Cases

  @impl true
  def change(changeset, _opts, _context) do
    source_id = Ash.Changeset.get_argument(changeset, :source_turn_id)
    next_id = Ash.Changeset.get_argument(changeset, :next_turn_id)
    current = changeset.data.pending_intent

    if available?(current, source_id) do
      case same_run(changeset.data, source_id, next_id) do
        {:ok, true} ->
          changeset
          |> Ash.Changeset.change_attribute(:pending_intent, %{
            "action" => "resolve_turn",
            "turn_id" => next_id,
            "source_turn_id" => source_id
          })
          |> Ash.Changeset.change_attribute(:stop_reason, nil)
          |> Ash.Changeset.change_attribute(:required_human_input, nil)

        {:ok, false} ->
          Ash.Changeset.add_error(changeset,
            field: :next_turn_id,
            message: "Resolver Turn belongs to another Case or ResolutionRun"
          )

        {:error, error} ->
          Ash.Changeset.add_error(changeset, error)
      end
    else
      Ash.Changeset.add_error(changeset,
        field: :pending_intent,
        message: "Case already has another pending decision"
      )
    end
  end

  defp available?(%{"action" => action, "turn_id" => source_id}, source_id)
       when action in ["resolve_turn", "route_resolver_decision", "review_recovery"],
       do: true

  defp available?(current, _source_id) when map_size(current) == 0, do: true
  defp available?(_current, _source_id), do: false

  defp same_run(incident, source_id, next_id) when source_id != next_id do
    with {:ok, %{case_id: source_case_id, resolution_run_id: source_run_id}} <-
           Cases.get_turn(source_id, authorize?: false, not_found_error?: false),
         {:ok, %{case_id: next_case_id, resolution_run_id: next_run_id}} <-
           Cases.get_turn(next_id, authorize?: false, not_found_error?: false) do
      {:ok,
       source_case_id == incident.id and next_case_id == incident.id and
         source_run_id == next_run_id}
    else
      {:error, error} -> {:error, error}
      {:ok, nil} -> {:ok, false}
    end
  end

  defp same_run(_incident, _source_id, _next_id), do: {:ok, false}
end
