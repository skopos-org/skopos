defmodule Skopos.Cases.Proposal.ReviewWorker do
  @moduledoc false

  use Oban.Worker,
    queue: :resolver,
    max_attempts: 3,
    unique: [period: :infinity, fields: [:worker, :queue, :args], states: :all]

  @impl Oban.Worker
  def perform(%Oban.Job{
        args: %{"proposal_id" => proposal_id},
        attempt: attempt,
        max_attempts: max_attempts
      })
      when is_binary(proposal_id),
      do:
        Skopos.Cases.Proposal.ReviewDelivery.run(proposal_id,
          delivery_attempt: attempt,
          max_delivery_attempts: max_attempts
        )

  def perform(_job), do: {:cancel, "Reviewer job arguments are invalid"}
end
