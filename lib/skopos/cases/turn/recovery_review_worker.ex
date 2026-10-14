defmodule Skopos.Cases.Turn.RecoveryReviewWorker do
  @moduledoc false

  use Oban.Worker,
    queue: :resolver,
    max_attempts: 3,
    unique: [period: :infinity, fields: [:worker, :queue, :args], states: :all]

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"turn_id" => turn_id}, attempt: attempt, max_attempts: maximum})
      when is_binary(turn_id),
      do:
        Skopos.Cases.Turn.RecoveryReviewDelivery.run(turn_id,
          delivery_attempt: attempt,
          max_delivery_attempts: maximum
        )

  def perform(_job), do: {:cancel, "Recovery Reviewer job arguments are invalid"}
end
