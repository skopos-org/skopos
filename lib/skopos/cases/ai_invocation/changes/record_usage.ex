defmodule Skopos.Cases.AIInvocation.Changes.RecordUsage do
  use Ash.Resource.Change

  alias Skopos.Providers.AI

  @impl true
  def change(changeset, _opts, _context) do
    usage = Ash.Changeset.get_argument(changeset, :usage)
    dispatched? = Ash.Changeset.get_argument(changeset, :dispatched?)

    cond do
      is_nil(usage) ->
        changeset
        |> Ash.Changeset.change_attributes(%{
          usage_reported: false,
          dispatch_confirmed: dispatched?,
          input_tokens: 0,
          output_tokens: 0,
          cached_tokens: nil,
          reasoning_tokens: nil,
          finish_reason: nil
        })

      valid?(usage) ->
        changeset
        |> Ash.Changeset.change_attributes(
          Map.merge(
            Map.from_struct(usage),
            %{usage_reported: true, dispatch_confirmed: true}
          )
        )

      true ->
        Ash.Changeset.add_error(changeset, field: :usage, message: "Native AI usage is invalid")
    end
  end

  defp valid?(%AI.Usage{} = usage),
    do:
      Enum.all?([usage.input_tokens, usage.output_tokens], &count?/1) and
        Enum.all?([usage.cached_tokens, usage.reasoning_tokens], &(is_nil(&1) or count?(&1)))

  defp valid?(_), do: false
  defp count?(value), do: is_integer(value) and value >= 0
end
