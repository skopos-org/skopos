defmodule Skopos.Providers.Provider.Changes.InitializeAIUsage do
  use Ash.Resource.Change

  alias Skopos.Providers

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.after_action(changeset, fn changeset, provider ->
      scope = Ash.Changeset.get_argument(changeset, :usage_scope)
      priority = Ash.Changeset.get_argument(changeset, :usage_priority)

      case provider.kind do
        :ai ->
          case Providers.configure_ai_usage(
                 provider.id,
                 scope,
                 priority,
                 nil,
                 nil,
                 authorize?: false
               ) do
            {:ok, true} -> {:ok, provider}
            {:error, error} -> {:error, error}
          end

        _kind ->
          {:ok, provider}
      end
    end)
  end
end
