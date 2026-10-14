defmodule Skopos.Targets.TargetRequest.RequestError do
  @moduledoc false

  use Splode.Error, class: :forbidden, fields: [:category, :message]

  @impl true
  def message(error), do: error.message

  def expected?(%{errors: errors}) when is_list(errors),
    do: errors != [] and Enum.all?(errors, &expected?/1)

  def expected?(%{class: class}) when class in [:invalid, :forbidden], do: true
  def expected?(_error), do: false
end
