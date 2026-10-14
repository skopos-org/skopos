defmodule Skopos.Cases.Evidence.Actions.FileRead do
  @moduledoc false
  use Ash.Resource.Actions.Implementation
  require Ash.Query

  alias Skopos.{Accounts, Cases, Targets}
  alias Skopos.Cases.{Case, CaseEvent, Evidence, ResolutionRun, Turn}
  alias Skopos.Cases.Case.{AdmissionLock, ConditionContext}
  alias Skopos.Cases.Evidence.Citation
  alias Skopos.Providers.AI
  alias Skopos.Providers.Target.FileReference

  @impl true
  def run(input, opts, _context) do
    case opts[:operation] do
      :capture -> capture(input.arguments.turn_id)
      :read -> read(input.arguments)
      :source -> file_source(input.arguments)
    end
  end

  defp capture(turn_id) do
    with {:ok, snapshot} <- capture_snapshot(turn_id) do
      if snapshot.existing do
        {:ok, snapshot.existing}
      else
        with {:ok, result} <- read_bytes(snapshot.intent, snapshot.actor) do
          Ash.transact([Case, ResolutionRun, Evidence, CaseEvent], fn ->
            with :ok <- AdmissionLock.acquire(),
                 :ok <- current_snapshot(snapshot),
                 {:ok, true} <- ConditionContext.current?(snapshot.incident, snapshot.turn.id) do
              append(snapshot, result)
            end
          end)
        end
      end
    end
  end

  defp capture_snapshot(turn_id) do
    Ash.transact([Case, ResolutionRun, Turn, Evidence], fn ->
      with :ok <- AdmissionLock.acquire(),
           {:ok, turn} <- Cases.get_turn(turn_id, authorize?: false),
           true <-
             (turn.status == :completed and turn.result["outcome"] == "decision" and
                get_in(turn.result, ["intent", "type"]) == "file_read") ||
               invalid("Turn has no file-read decision"),
           {:ok, {incident, run, actor}} <- current_context(turn.case_id, turn.resolution_run_id),
           {:ok, true} <- ConditionContext.current?(incident, turn.id),
           intent <- turn.result["intent"],
           :ok <- valid_range(intent["reference"], intent["offset"], intent["length"], incident),
           true <-
             AI.valid_resolver_reason?(intent["reason"]) ||
               invalid("File-read reason is invalid"),
           {:ok, source} <- source(intent, incident, run),
           {:ok, existing} <-
             Cases.evidence_by_idempotency(incident.id, "file-read:#{turn.id}",
               authorize?: false,
               not_found_error?: false
             ),
           :ok <- matching_receipt(existing, intent) do
        %{
          turn: turn,
          incident: incident,
          run: run,
          actor: actor,
          intent: intent,
          source: source,
          existing: existing
        }
      else
        {:ok, false} -> invalid("File-read Condition context changed")
        error -> error
      end
    end)
  end

  defp append(snapshot, result) do
    %{turn: turn, intent: intent, source: source, actor: actor} = snapshot

    with {:ok, existing} <-
           Cases.evidence_by_idempotency(turn.case_id, "file-read:#{turn.id}",
             authorize?: false,
             not_found_error?: false
           ),
         :ok <- matching_receipt(existing, intent) do
      if existing do
        existing
      else
        content =
          receipt(intent, source, result)
          |> Map.merge(%{"actor_id" => actor.id, "actor_role_version" => actor.role_version})

        with {:ok, evidence} <-
               Cases.append_evidence(
                 turn.case_id,
                 turn.resolution_run_id,
                 turn.id,
                 "file-read:#{turn.id}",
                 "file_read",
                 "file_store",
                 turn.id,
                 content,
                 DateTime.utc_now(),
                 actor: actor,
                 authorize?: false
               ),
             do: evidence
      end
    end
  end

  defp read(%{id: id, case_id: case_id}) do
    with {:ok, snapshot} <- read_snapshot(id, case_id) do
      content = snapshot.evidence.content

      if content["status"] == "unavailable" do
        {:ok, content}
      else
        with {:ok, result} <- read_bytes(snapshot.intent, snapshot.actor) do
          Ash.transact([Case, ResolutionRun], fn ->
            with :ok <- current_snapshot(snapshot) do
              project(content, snapshot.intent, snapshot.source, result)
            end
          end)
        end
      end
    end
  end

  # Recovery callers use the original observation's freshness and native operation
  # admission. This action checks current file authority without rereading bytes
  # inside their transaction; both AI projections obtain bytes through :read.
  defp file_source(arguments) do
    Ash.transact([Case, ResolutionRun, Evidence], fn -> file_source_snapshot(arguments) end)
  end

  defp file_source_snapshot(%{id: id, case_id: case_id}) do
    with {:ok, evidence} <- Cases.get_evidence(id, authorize?: false),
         true <- evidence.case_id == case_id || invalid("File source belongs to another Case"),
         {:ok, {incident, _run, actor}} <-
           current_context(case_id, evidence.resolution_run_id),
         content <- evidence.content,
         true <-
           (evidence.kind == "file_read" and content["status"] == "available") ||
             invalid("File contents were not obtained"),
         :ok <-
           valid_range(
             content["reference"],
             content["offset"],
             content["requested_length"],
             incident
           ),
         reference <- content["reference"],
         {:ok, current_reference} <-
           Targets.artifact_reference(reference["id"], reference["target_id"], actor: actor),
         true <- current_reference == reference || invalid("File reference changed"),
         {:ok, source} <- original_source(evidence, reference, MapSet.new(), 0),
         true <-
           content["source_observed_at"] == DateTime.to_iso8601(source.observed_at) ||
             invalid("File observation time does not match its source"),
         do: source
  end

  defp original_source(_evidence, _reference, _seen, depth) when depth >= 32,
    do: invalid("File source lineage exceeds the evidence bound")

  defp original_source(%{kind: "file_read"} = evidence, reference, seen, depth) do
    content = evidence.content

    with true <-
           (not MapSet.member?(seen, evidence.id) and content["status"] == "available" and
              content["reference"] == reference) || invalid("File source lineage is invalid"),
         {:ok, source} <- Cases.get_evidence(content["source_evidence_id"], authorize?: false),
         true <-
           (source.case_id == evidence.case_id and
              source.content["target_id"] == reference["target_id"] and
              FileReference.present_in?(source.content, reference)) ||
             invalid("File reference is absent from its original source"),
         {:ok, original} <-
           original_source(source, reference, MapSet.put(seen, evidence.id), depth + 1),
         true <-
           content["source_observed_at"] == DateTime.to_iso8601(original.observed_at) ||
             invalid("File observation time changed in its lineage"),
         do: {:ok, original}
  end

  defp original_source(%{kind: kind} = evidence, _reference, _seen, _depth)
       when kind in ["observation", "target_verification"], do: {:ok, evidence}

  defp original_source(_evidence, _reference, _seen, _depth),
    do: invalid("File has no native Target observation source")

  defp read_snapshot(id, case_id) do
    Ash.transact([Case, ResolutionRun, Evidence], fn ->
      with {:ok, evidence} <- Cases.get_evidence(id, authorize?: false),
           true <-
             (evidence.kind == "file_read" and evidence.case_id == case_id) ||
               invalid("File-read Evidence does not belong to this Case"),
           {:ok, {incident, run, actor}} <- current_context(case_id, evidence.resolution_run_id),
           true <-
             evidence.content["status"] in ["available", "unavailable"] ||
               invalid("File-read Evidence status is invalid"),
           intent <- receipt_intent(evidence.content),
           :ok <- valid_range(intent["reference"], intent["offset"], intent["length"], incident),
           {:ok, source} <- source(intent, incident, run) do
        %{
          evidence: evidence,
          incident: incident,
          run: run,
          actor: actor,
          intent: intent,
          source: source
        }
      end
    end)
  end

  defp read_bytes(intent, actor) do
    result =
      with {:ok, metadata} <- Targets.get_artifact(intent["reference"]["id"], actor: actor),
           {:ok, bytes} <-
             Targets.read_bound_artifact_range(
               intent["reference"],
               intent["offset"],
               intent["length"],
               actor: actor
             ) do
        {:ok, %{bytes: bytes, completion_reason: metadata.completion_reason}}
      end

    case result do
      {:ok, result} ->
        {:ok, result}

      {:error, %Ash.Error.Invalid{errors: [%type{}]}}
      when type in [
             Ash.Error.Query.NotFound,
             Ash.Error.Changes.InvalidAttribute,
             Ash.Error.Action.InvalidArgument
           ] ->
        {:ok, :unavailable}

      {:error, %Ash.Error.Forbidden{errors: [%Ash.Error.Forbidden.Policy{}]}} ->
        {:ok, :unavailable}

      error ->
        error
    end
  end

  defp project(content, intent, source, :unavailable),
    do:
      receipt(intent, source, :unavailable)
      |> Map.merge(Map.take(content, ["actor_id", "actor_role_version"]))

  defp project(content, intent, source, %{bytes: bytes} = result) do
    expected = receipt(intent, source, result)

    if Map.take(content, Map.keys(expected)) == expected do
      if String.valid?(bytes),
        do: Map.merge(content, %{"encoding" => "utf8", "value" => bytes}),
        else: Map.merge(content, %{"encoding" => "base64", "value" => Base.encode64(bytes)})
    else
      {:error,
       Ash.Error.Action.InvalidArgument.exception(
         field: :id,
         message: "File-read Evidence integrity check failed"
       )}
    end
  end

  defp receipt(intent, source, result) do
    content = %{
      "target_id" => intent["reference"]["target_id"],
      "source_evidence_id" => intent["source_evidence_id"],
      "source_observed_at" =>
        if(source.kind == "file_read",
          do: source.content["source_observed_at"],
          else: DateTime.to_iso8601(source.observed_at)
        ),
      "reference" => intent["reference"],
      "offset" => intent["offset"],
      "requested_length" => intent["length"],
      "reason" => intent["reason"]
    }

    if result == :unavailable do
      Map.merge(content, %{"status" => "unavailable", "failure_code" => "file_unavailable"})
    else
      bytes = result.bytes
      next = intent["offset"] + byte_size(bytes)

      Map.merge(content, %{
        "status" => "available",
        "source_completion_reason" =>
          result.completion_reason && to_string(result.completion_reason),
        "byte_count" => byte_size(bytes),
        "sha256" => :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower),
        "next_offset" => next,
        "eof" => next == intent["reference"]["size_bytes"]
      })
    end
  end

  defp receipt_intent(content),
    do: %{
      "reference" => content["reference"],
      "offset" => content["offset"],
      "length" => content["requested_length"],
      "source_evidence_id" => content["source_evidence_id"],
      "reason" => content["reason"]
    }

  defp matching_receipt(nil, _intent), do: :ok

  defp matching_receipt(existing, intent) do
    if existing.kind == "file_read" and existing.content["status"] in ["available", "unavailable"] and
         receipt_intent(existing.content) ==
           Map.take(intent, ~w(reference offset length source_evidence_id reason)),
       do: :ok,
       else: invalid("File-read receipt does not match the source decision")
  end

  defp source(intent, incident, run) do
    with {:ok, source} <- Cases.get_evidence(intent["source_evidence_id"], authorize?: false),
         :ok <- Citation.validate(source, incident, run),
         true <-
           FileReference.present_in?(source.content, intent["reference"]) ||
             invalid("File reference is not present in the cited Case Evidence"),
         do: {:ok, source}
  end

  defp current_snapshot(snapshot) do
    with {:ok, {incident, _run, actor}} <- current_context(snapshot.incident.id, snapshot.run.id),
         true <-
           (incident.current_owner_id == snapshot.incident.current_owner_id and
              incident.selected_target_id == snapshot.incident.selected_target_id and
              incident.selected_target_revision == snapshot.incident.selected_target_revision and
              actor.role_version == snapshot.actor.role_version) ||
             invalid("File-read authority or Target changed"),
         do: :ok
  end

  defp current_context(case_id, run_id) do
    with {:ok, incident} <-
           Case
           |> Ash.Query.for_read(:read)
           |> Ash.Query.filter(id == ^case_id)
           |> Ash.Query.lock(:for_update)
           |> Ash.read_one(authorize?: false, not_found_error?: true),
         true <-
           (incident.status == :running and not incident.cancel_requested) ||
             invalid("Case is not running"),
         {:ok, run} <- Cases.get_resolution_run(run_id, authorize?: false),
         true <-
           (run.case_id == incident.id and run.active and run.status == :running and
              DateTime.compare(DateTime.utc_now(), run.deadline_at) == :lt) ||
             invalid("File-read ResolutionRun is not current"),
         {:ok, actor} <- Accounts.get_user(incident.current_owner_id, authorize?: false),
         true <-
           actor.role in [:admin, :operator] || invalid("Case owner cannot read file contents"),
         {:ok, target} <- Targets.get_target(incident.selected_target_id, authorize?: false),
         true <-
           (target.active and target.revision == incident.selected_target_revision) ||
             invalid("File-read Target changed"),
         do: {:ok, {incident, run, actor}}
  end

  defp valid_range(reference, offset, length, incident) do
    if FileReference.valid?(reference) and reference["target_id"] == incident.selected_target_id and
         is_integer(offset) and offset >= 0 and offset <= reference["size_bytes"] and
         is_integer(length) and length in 1..AI.file_read_bytes(),
       do: :ok,
       else: invalid("File-read reference, Target or range is invalid")
  end

  defp invalid(message),
    do: {:error, Ash.Error.Changes.InvalidChanges.exception(message: message)}
end
