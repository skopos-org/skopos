defmodule Skopos.Cases.Case.RealtimeNotifier do
  @moduledoc false

  use Ash.Notifier

  alias Skopos.Cases.Case
  alias Skopos.Cases.Case.Realtime

  @impl true
  def notify(%Ash.Notifier.Notification{data: %Case{id: case_id}}),
    do: Realtime.publish(case_id)

  def notify(%Ash.Notifier.Notification{data: %{case_id: case_id}}) when is_binary(case_id),
    do: Realtime.publish(case_id)

  def notify(_notification), do: :ok
end
