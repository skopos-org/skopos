defmodule Skopos.Cases.VerificationAttempt.Worker do
  @moduledoc false

  use Oban.Worker,
    queue: :operations,
    max_attempts: 3,
    unique: [period: :infinity, fields: [:worker, :queue, :args], states: :all]

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"verification_attempt_id" => id}}) when is_binary(id),
    do: Skopos.Cases.VerificationAttempt.Delivery.run(id)

  def perform(_job), do: {:cancel, "Verification job arguments are invalid"}
end
