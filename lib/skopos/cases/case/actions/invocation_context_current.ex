defmodule Skopos.Cases.Case.Actions.InvocationContextCurrent do
  use Ash.Resource.Actions.Implementation

  alias Skopos.{Cases, Providers, Targets}
  alias Skopos.Cases.Case.ConditionContext

  @impl true
  def run(input, _opts, _context) do
    expected = input.arguments.invocation_context

    with {:ok, %{status: :running, cancel_requested: false} = incident} <-
           Cases.get_case(expected.case_id, authorize?: false, not_found_error?: false),
         true <- incident.revision == expected.case_revision,
         {:ok, %{active: true, status: :running} = run} <-
           Cases.get_resolution_run(expected.resolution_run_id,
             authorize?: false,
             not_found_error?: false
           ),
         true <- run.case_id == incident.id and run.generation == expected.run_generation,
         true <- DateTime.compare(DateTime.utc_now(), run.deadline_at) == :lt,
         {:ok, true} <- subject_current(expected),
         {:ok, conditions} <- ConditionContext.current_condition_revisions(incident),
         true <- conditions == expected.conditions,
         {:ok, true} <- all_current(expected.targets, &target_current/1),
         {:ok, true} <- all_current(expected.methods, &method_current/1),
         {:ok, current?} <- selection_current(expected.selection) do
      {:ok, current?}
    else
      {:error, _cause} = error -> error
      _changed -> {:ok, false}
    end
  end

  defp subject_current(%{
         subject: {kind, id, revision, status},
         case_id: case_id,
         resolution_run_id: run_id
       }) do
    result =
      case kind do
        :turn ->
          Cases.get_turn(id, authorize?: false, not_found_error?: false)

        :proposal ->
          Cases.get_proposal(id, authorize?: false, not_found_error?: false)

        :operation ->
          Cases.get_operation(id, authorize?: false, not_found_error?: false)

        :verification ->
          Cases.get_verification_attempt(id, authorize?: false, not_found_error?: false)
      end

    case result do
      {:ok,
       %{revision: ^revision, status: ^status, case_id: ^case_id, resolution_run_id: ^run_id}} ->
        {:ok, true}

      {:error, _cause} = error ->
        error

      _changed ->
        {:ok, false}
    end
  end

  defp target_current(%{id: id, revision: revision}) do
    case Targets.get_target(id, authorize?: false, not_found_error?: false) do
      {:ok, %{revision: ^revision, active: true}} -> {:ok, true}
      {:error, _cause} = error -> error
      _changed -> {:ok, false}
    end
  end

  defp method_current(expected) do
    with {:ok, %{provider_id: id, provider_revision: revision, target_id: target_id}} <-
           Targets.load_access_method_for_use(
             expected.access_method_id,
             expected.access_method_revision,
             expected.capability,
             authorize?: false,
             not_found_error?: false
           ),
         true <-
           id == expected.provider_id and revision == expected.provider_revision and
             target_id == expected.target_id,
         {:ok, provider} <-
           Providers.load_provider_for_invocation(id, revision, :target,
             authorize?: false,
             not_found_error?: false
           ) do
      {:ok, not is_nil(provider)}
    else
      {:error, _cause} = error -> error
      _changed -> {:ok, false}
    end
  end

  defp selection_current(nil), do: {:ok, true}

  defp selection_current(expected) do
    case Providers.load_current_ai_usage_role_assignment(
           expected.assignment_id,
           expected.role,
           expected.assignment_revision,
           expected.provider_revision,
           authorize?: false,
           not_found_error?: false
         ) do
      {:ok, %{provider_id: id}} -> {:ok, id == expected.provider_id}
      {:error, _cause} = error -> error
      _changed -> {:ok, false}
    end
  end

  defp all_current(values, check) do
    Enum.reduce_while(values, {:ok, true}, fn value, _current ->
      case check.(value) do
        {:ok, true} -> {:cont, {:ok, true}}
        other -> {:halt, other}
      end
    end)
  end
end
