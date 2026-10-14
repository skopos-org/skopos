defmodule Skopos.Cases.Case.Actions.ContinueAfterVerification do
  use Ash.Resource.Actions.Implementation

  alias Skopos.Cases

  @impl true
  def run(input, _opts, _context) do
    case_id = input.arguments.id
    attempt_id = input.arguments.verification_attempt_id

    with {:ok, attempt} <- Cases.get_verification_attempt(attempt_id, authorize?: false),
         true <- attempt.case_id == case_id || {:error, "Verification belongs to another Case"},
         {:ok, incident} <- Cases.get_case(case_id, authorize?: false) do
      result =
        if incident.trigger_kind == :signal and attempt.status == :verified do
          Cases.reconcile_verified_effect(case_id, attempt_id, authorize?: false)
        else
          Cases.evaluate_verification(attempt_id, authorize?: false)
        end

      case result do
        {:ok, _continued} ->
          {:ok, true}

        {:error, error} ->
          case Cases.get_case(case_id, authorize?: false) do
            {:ok, %{status: :needs_attention}} -> {:ok, true}
            _active -> {:error, error}
          end
      end
    end
  end
end
