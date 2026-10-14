defmodule Skopos.Cases.Case.SignalRecoveryCheckWorker do
  @moduledoc false

  use Oban.Worker,
    queue: :resolver,
    max_attempts: 5,
    unique: [period: :infinity, fields: [:worker, :queue, :args], states: :all]

  alias Skopos.Cases

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"case_id" => case_id, "verification_attempt_id" => attempt_id}})
      when is_binary(case_id) and is_binary(attempt_id) do
    with {:ok, incident} <- Cases.get_case(case_id, authorize?: false) do
      case incident do
        %{
          status: :running,
          pending_intent: %{
            "action" => "await_source_recovery",
            "verification_attempt_id" => ^attempt_id
          }
        } ->
          case Cases.reconcile_verified_effect(case_id, attempt_id, authorize?: false) do
            {:ok, _case} -> :ok
            {:error, _error} = error -> error
          end

        _other ->
          :ok
      end
    end
  end

  def perform(_job), do: {:cancel, "Signal recovery check arguments are invalid"}
end
