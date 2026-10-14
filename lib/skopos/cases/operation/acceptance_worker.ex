defmodule Skopos.Cases.Operation.AcceptanceWorker do
  @moduledoc false

  alias Skopos.Cases
  alias Skopos.Targets.TargetRequest.RequestError
  alias Skopos.Cases.ResolutionRun.Budget, as: Budget

  use Oban.Worker,
    queue: :operations,
    max_attempts: 3,
    unique: [
      period: :infinity,
      fields: [:worker, :queue, :args],
      states: [:available, :scheduled, :executing, :retryable]
    ]

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"proposal_id" => proposal_id}}) when is_binary(proposal_id) do
    case Cases.accept_operation(proposal_id, authorize?: false) do
      {:ok, _operation} ->
        :ok

      {:error, error} = failure ->
        if RequestError.expected?(error), do: require_attention(proposal_id, error), else: failure
    end
  end

  def perform(_job), do: {:cancel, "Operation acceptance job arguments are invalid"}

  defp require_attention(proposal_id, original_error) do
    with {:ok, proposal} <- Cases.get_proposal(proposal_id, authorize?: false),
         {:ok, incident} <- Cases.get_case(proposal.case_id, authorize?: false),
         {:ok, run} <- Cases.get_resolution_run(proposal.resolution_run_id, authorize?: false),
         {:ok, operation} <-
           Cases.operation_by_proposal(proposal.id, authorize?: false, not_found_error?: false) do
      cond do
        not is_nil(operation) ->
          :ok

        incident.status == :needs_attention ->
          :ok

        proposal.status == :authorized and incident.status == :running and
          not incident.cancel_requested and run.status == :running and run.active ->
          pause(incident, run, proposal.id, original_error)

        true ->
          {:cancel, "Operation acceptance is no longer applicable"}
      end
    else
      {:error, error} -> {:error, Ash.Error.to_error_class([original_error, error])}
    end
  end

  defp pause(incident, run, proposal_id, original_error) do
    case Cases.require_case_attention(
           incident.id,
           incident.revision,
           run.id,
           run.revision,
           Budget.key("operation:acceptance:failure", proposal_id),
           "Operation acceptance failed",
           incident.pending_intent,
           "Review the current authority and Target configuration, then resume the Case",
           authorize?: false
         ) do
      {:ok, _case} -> :ok
      {:error, error} -> {:error, Ash.Error.to_error_class([original_error, error])}
    end
  end
end
