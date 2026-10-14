defmodule Skopos.Cases.Proposal.ProposalExpirationWorker do
  @moduledoc false

  use Oban.Worker,
    queue: :operations,
    max_attempts: 5,
    unique: [period: :infinity, fields: [:worker, :queue, :args], states: :all]

  alias Skopos.Cases
  alias Skopos.Cases.Proposal

  def job(%Proposal{} = proposal) do
    new(%{"proposal_id" => proposal.id}, scheduled_at: proposal.expires_at)
  end

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"proposal_id" => proposal_id}})
      when is_binary(proposal_id) do
    case Cases.expire_proposal(proposal_id, authorize?: false) do
      {:ok, _proposal} -> :ok
      {:error, error} -> {:error, error}
    end
  end

  def perform(_job), do: {:cancel, "Proposal expiration job arguments are invalid"}
end
