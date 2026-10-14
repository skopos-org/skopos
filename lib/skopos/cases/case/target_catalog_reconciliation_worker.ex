defmodule Skopos.Cases.Case.TargetCatalogReconciliationWorker do
  @moduledoc false

  use Oban.Worker,
    queue: :resolver,
    max_attempts: 10,
    unique: [period: :infinity, fields: [:worker, :queue, :args], states: :all]

  alias Skopos.{Cases, Targets}
  alias Skopos.Targets.ExternalIdentity

  @impl Oban.Worker
  def perform(%Oban.Job{
        args: %{"resource" => resource, "resource_id" => id, "revision" => revision}
      })
      when resource in ["target", "external_identity"] and is_binary(id) and
             is_integer(revision) and revision > 0 do
    change_key = Enum.join([resource, id, revision], ":")

    with {:ok, change} <- current_change(resource, id, revision) do
      case change do
        :stale -> :ok
        identity -> reconcile(change_key, identity)
      end
    end
  end

  def perform(_job), do: {:cancel, "Target catalog reconciliation arguments are invalid"}

  defp reconcile(change_key, identity) do
    with {:ok, running} <- Cases.running_signal_cases_without_target(authorize?: false),
         {:ok, waiting} <- waiting_cases(identity) do
      result =
        Enum.reduce_while(running ++ waiting, {:ok, false}, fn incident, {:ok, busy?} ->
          case wake(incident, change_key, identity) do
            :ok -> {:cont, {:ok, busy?}}
            :busy -> {:cont, {:ok, true}}
            {:error, error} -> {:halt, {:error, error}}
          end
        end)

      case result do
        {:ok, true} -> {:error, "Case still has an active Resolver Turn"}
        {:ok, false} -> :ok
        {:error, _error} = error -> error
      end
    end
  end

  defp waiting_cases(%ExternalIdentity{} = identity) do
    case Targets.get_target(identity.target_id, authorize?: false) do
      {:ok, %{active: true}} ->
        Cases.signal_cases_waiting_for_external_identity(
          identity.source,
          identity.kind,
          identity.value,
          authorize?: false
        )

      {:ok, %{active: false}} ->
        {:ok, []}

      {:error, _error} = error ->
        error
    end
  end

  defp waiting_cases(nil), do: {:ok, []}

  defp wake(%{status: :running} = incident, change_key, _identity) do
    with {:ok, run} <- Cases.active_resolution_run(incident.id, authorize?: false),
         {:ok, started} <- Cases.started_turns_for_run(run.id, authorize?: false) do
      if started == [] do
        start_turn(incident, run, change_key)
      else
        :busy
      end
    end
  end

  defp wake(%{status: :needs_attention} = incident, _change_key, %ExternalIdentity{} = identity) do
    case Cases.resume_case_after_target_registration(
           incident.id,
           identity.id,
           identity.revision,
           authorize?: false
         ) do
      {:ok, _run} -> :ok
      {:error, _error} = error -> error
    end
  end

  defp start_turn(incident, run, change_key) do
    key = "target-catalog:" <> digest([incident.id, change_key])

    case Cases.start_turn(
           incident.id,
           run.id,
           key,
           %{"objective" => "Re-evaluate the incident after the Target catalog changed"},
           %{"action" => "continue"},
           "Review Resolver limits",
           authorize?: false
         ) do
      {:ok, %{status: status}} when status in [:charged, :duplicate, :exhausted] -> :ok
      {:error, _error} = error -> already_started_or(error, run.id)
    end
  end

  defp already_started_or(error, run_id) do
    case Cases.started_turns_for_run(run_id, authorize?: false) do
      {:ok, [_started | _rest]} -> :ok
      _missing -> error
    end
  end

  defp digest(parts) do
    raw = Enum.join(parts, ":")
    :crypto.hash(:sha256, raw) |> Base.encode16(case: :lower)
  end

  defp current_change("external_identity", id, revision) do
    case Targets.get_external_identity(id, authorize?: false) do
      {:ok, %{revision: ^revision, active: true} = identity} -> {:ok, identity}
      {:ok, _changed_identity} -> {:ok, :stale}
      {:error, _error} = error -> error
    end
  end

  defp current_change("target", id, revision) do
    case Targets.get_target(id, authorize?: false) do
      {:ok, %{revision: ^revision, active: true}} -> {:ok, nil}
      {:ok, _changed_target} -> {:ok, :stale}
      {:error, _error} = error -> error
    end
  end
end
