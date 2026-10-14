defmodule Skopos.Accounts.User.Changes.RevokeTokens do
  use Ash.Resource.Change

  alias AshAuthentication.{Info, Strategy}

  @impl true
  def change(changeset, _opts, context) do
    Ash.Changeset.after_action(changeset, fn changeset, user ->
      strategy = Info.strategy!(changeset.resource, :log_out_everywhere)

      with :ok <-
             Strategy.action(
               strategy,
               :log_out_everywhere,
               %{user: user},
               Ash.Context.to_opts(context)
             ) do
        {:ok, user}
      end
    end)
  end

  @impl true
  def atomic(changeset, opts, context) do
    {:ok, change(changeset, opts, context)}
  end
end
