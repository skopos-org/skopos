defmodule Skopos.Cases.CaseDispatch.Worker do
  use Oban.Worker,
    queue: :resolver,
    max_attempts: 10,
    unique: [period: :infinity, fields: [:worker, :queue, :args], states: :all]

  alias Skopos.Cases

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"case_id" => case_id}}) when is_binary(case_id) do
    case Cases.send_initial_case_turn(case_id, authorize?: false) do
      {:ok, %{status: :sent}} ->
        :ok

      {:ok, %{status: :disabled}} ->
        :ok

      {:ok, %{status: :early, due_at: due_at}} ->
        {:snooze, max(DateTime.diff(due_at, DateTime.utc_now(), :second), 1)}

      {:error, _error} = error ->
        error
    end
  end

  def perform(_job), do: {:cancel, "Case dispatch arguments are invalid"}
end
