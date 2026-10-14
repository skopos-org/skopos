defmodule Skopos.Cases.Proposal.Actions.Materialize do
  use Ash.Resource.Actions.Implementation

  require Ash.Query

  alias Skopos.{Accounts, Cases, Providers, Targets}

  alias Skopos.Cases.{Case, Evidence, Proposal, ResolutionRun, Turn}
  alias Skopos.Cases.ResolutionRun.Budget, as: Budget
  alias Skopos.Cases.Evidence.Citation, as: EvidenceCitation
  alias Skopos.Cases.Case.AdmissionLock, as: CaseAdmissionLock
  alias Skopos.Cases.Case.ConditionContext, as: ConditionContext

  alias Skopos.Targets.TargetRequest.{RequestError, Request, Clearance}

  @impl true
  def run(input, _opts, _context) do
    with {:ok, source_turn} <- Cases.get_turn(input.arguments.turn_id, authorize?: false) do
      Ash.transact([Case, ResolutionRun, Turn, Evidence, Proposal], fn ->
        with :ok <- CaseAdmissionLock.acquire(),
             {:ok, incident} <- lock_case(source_turn.case_id),
             {:ok, run} <- lock_run(source_turn.resolution_run_id, incident.id),
             {:ok, turn} <- lock_turn(source_turn.id, incident.id, run.id),
             {:ok, existing} <- existing_proposal(turn.id) do
          if existing do
            replay(existing, turn, incident, run)
          else
            materialize(turn, incident, run)
          end
        end
      end)
    end
  end

  defp materialize(turn, incident, run) do
    with :ok <- ensure_running(incident, run),
         :ok <- current_conditions(incident, turn.id),
         {:ok, proposal} <- proposal_data(turn),
         :ok <- current_affected_conditions(incident, proposal.intent),
         {:ok, actor} <- current_actor(incident),
         :ok <-
           valid_evidence(
             purpose(proposal.intent),
             proposal.intent["evidence_ids"],
             incident,
             run
           ),
         reserved_operation_id <- Ash.UUID.generate(),
         operation_key <- Budget.key("proposal:operation", turn.id),
         request <-
           target_request(proposal.intent, incident, reserved_operation_id, operation_key),
         {:ok, preflight} <- preflight(request, actor, proposal.request_tool),
         attrs <-
           attributes(
             proposal,
             turn,
             incident,
             run,
             actor,
             reserved_operation_id,
             operation_key,
             preflight
           ),
         {:ok, stored} <-
           Cases.create_proposal_record(
             Map.put(attrs, :proposal_digest, proposal_digest(attrs)),
             authorize?: false
           ) do
      stored
    end
  end

  defp current_conditions(incident, turn_id) do
    case ConditionContext.current?(incident, turn_id) do
      {:ok, true} -> :ok
      {:ok, false} -> invalid("Completed Resolver Turn Conditions changed")
      {:error, _error} = error -> error
    end
  end

  defp current_affected_conditions(incident, intent) do
    case ConditionContext.affected_current?(
           incident,
           request_kind(intent),
           intent["affected_conditions"],
           intent["evidence_ids"],
           intent
         ) do
      {:ok, true} -> :ok
      {:ok, false} -> invalid("Proposal affected Conditions changed")
      {:error, _error} = error -> error
    end
  end

  defp proposal_data(%{
         status: :completed,
         result_digest: result_digest,
         result: %{
           "outcome" => "decision",
           "resolver" => resolver,
           "intent" => %{"type" => "proposal"} = intent
         }
       })
       when is_binary(result_digest) and is_map(resolver) do
    request_tool = map(intent["tool"])
    verification_intent = map(intent["verification_intent"])
    verification_tool = map(intent["verification_tool"])

    if valid_intent?(intent, request_tool, verification_intent, verification_tool) and
         valid_resolver?(resolver) do
      {:ok,
       %{
         intent: intent,
         request_tool: request_tool,
         verification_intent: verification_intent,
         verification_tool: verification_tool,
         resolver: resolver,
         result_digest: result_digest
       }}
    else
      invalid("Completed Turn contains a malformed Proposal")
    end
  end

  defp proposal_data(_turn), do: invalid("Completed Turn does not contain a Proposal")

  defp valid_intent?(intent, request_tool, verification_intent, verification_tool) do
    values = [
      intent["tool_id"],
      intent["target_id"],
      intent["access_method_id"],
      intent["capability"],
      intent["operation"],
      intent["reason"],
      request_tool["provider_id"]
    ]

    Enum.all?(values, &nonempty?/1) and
      Providers.AI.valid_resolver_reason?(intent["reason"]) and
      positive?(intent["target_revision"]) and
      positive?(intent["access_method_revision"]) and
      is_map(intent["selectors"]) and is_map(intent["parameters"]) and
      is_integer(intent["delay_seconds"]) and intent["delay_seconds"] in 0..86_400 and
      is_list(intent["affected_conditions"]) and
      Providers.AI.valid_proposal_purpose?(request_kind(intent), purpose(intent)) and
      exact_request_tool?(intent, request_tool) and
      valid_verification?(purpose(intent), intent, verification_intent, verification_tool)
  end

  defp exact_request_tool?(intent, tool) do
    intent["tool_id"] == tool["id"] and intent["target_id"] == tool["target_id"] and
      intent["target_revision"] == tool["target_revision"] and
      intent["access_method_id"] == tool["access_method_id"] and
      intent["access_method_revision"] == tool["access_method_revision"] and
      intent["request_kind"] == tool["request_kind"] and
      intent["capability"] == tool["capability"] and
      intent["operation"] == tool["operation"] and positive?(tool["provider_revision"])
  end

  defp valid_verification?(:investigation, intent, verification_intent, verification_tool),
    do:
      intent["expected_result"] == %{} and verification_intent == %{} and verification_tool == %{}

  defp valid_verification?(:remediation, intent, verification_intent, verification_tool),
    do:
      is_map(intent["expected_result"]) and
        ((verification_intent == %{} and verification_tool == %{} and
            map_size(intent["expected_result"]) > 0) or
           exact_verification?(verification_intent, verification_tool))

  defp exact_verification?(intent, tool) do
    intent["tool_id"] == tool["id"] and
      Enum.all?(
        [
          tool["target_id"],
          tool["access_method_id"],
          tool["provider_id"],
          tool["capability"],
          tool["operation"]
        ],
        &nonempty?/1
      ) and
      positive?(tool["target_revision"]) and positive?(tool["access_method_revision"]) and
      positive?(tool["provider_revision"]) and is_map(intent["selectors"]) and
      is_map(intent["parameters"]) and is_map(intent["expected_result"])
  end

  defp valid_resolver?(resolver) do
    Enum.all?([resolver["provider_id"], resolver["assignment_id"]], &nonempty?/1) and
      positive?(resolver["provider_revision"]) and
      positive?(resolver["assignment_revision"])
  end

  defp current_actor(%{current_owner_id: owner_id}) when is_binary(owner_id) do
    case Accounts.get_user(owner_id, authorize?: false) do
      {:ok, %{role: role} = actor} when role in [:admin, :operator] -> {:ok, actor}
      {:ok, _unavailable} -> invalid("Case owner cannot authorize a Proposal")
      {:error, _error} = error -> error
    end
  end

  defp current_actor(_incident), do: invalid("Case has no Proposal owner")

  defp valid_evidence(purpose, ids, incident, run)
       when is_list(ids) and (purpose == :investigation or ids != []) do
    if length(ids) == MapSet.size(MapSet.new(ids)) do
      Enum.reduce_while(ids, :ok, fn id, :ok ->
        case Cases.get_evidence(id, authorize?: false) do
          {:ok, evidence} ->
            case EvidenceCitation.validate(evidence, incident, run) do
              :ok -> {:cont, :ok}
              {:error, _error} = error -> {:halt, error}
            end

          {:error, _error} = error ->
            {:halt, error}
        end
      end)
    else
      invalid("Proposal Evidence identities contain duplicates")
    end
  end

  defp valid_evidence(_purpose, _ids, _incident, _run),
    do: invalid("Proposal must cite Evidence")

  defp target_request(intent, incident, operation_id, operation_key) do
    %Request{
      kind: request_kind(intent),
      authority_mode: incident.authority_mode,
      target_id: intent["target_id"],
      target_revision: intent["target_revision"],
      access_method_id: intent["access_method_id"],
      access_method_revision: intent["access_method_revision"],
      capability: intent["capability"],
      operation: intent["operation"],
      selectors: intent["selectors"],
      parameters: intent["parameters"],
      operation_id: operation_id,
      idempotency_key: operation_key,
      max_attempts: 1
    }
  end

  defp preflight(request, actor, request_tool) do
    case Targets.clear_target_request(request, actor: actor) do
      {:ok, %Clearance{} = clearance} ->
        if clearance.provider_id == request_tool["provider_id"] and
             clearance.provider_revision == request_tool["provider_revision"] do
          {:ok,
           %{
             status: :cleared,
             context: clearance_context(clearance),
             reason: nil
           }}
        else
          {:ok, blocked(:stale_context, "Target Provider changed after the Proposal")}
        end

      {:error, error} ->
        case find_error(error) do
          %RequestError{} = request_error ->
            {:ok, blocked(request_error.category, request_error.message)}

          _other ->
            {:error, error}
        end
    end
  end

  defp clearance_context(clearance) do
    %{
      "clearance_digest" => Base.encode16(clearance.digest, case: :lower),
      "actor_id" => clearance.actor_id,
      "provider_id" => clearance.provider_id,
      "provider_revision" => clearance.provider_revision
    }
  end

  defp blocked(category, reason) do
    %{
      status: :blocked,
      context: %{"category" => to_string(category)},
      reason: String.slice(reason, 0, 500)
    }
  end

  defp attributes(proposal, turn, incident, run, actor, operation_id, operation_key, preflight) do
    intent = proposal.intent
    request_tool = proposal.request_tool

    %{
      case_id: incident.id,
      resolution_run_id: run.id,
      source_turn_id: turn.id,
      proposed_for_id: actor.id,
      target_id: intent["target_id"],
      access_method_id: intent["access_method_id"],
      provider_id: request_tool["provider_id"],
      status: if(preflight.status == :cleared, do: :proposed, else: :blocked),
      authority_mode: incident.authority_mode,
      case_generation: run.generation,
      target_revision: intent["target_revision"],
      access_method_revision: intent["access_method_revision"],
      provider_revision: request_tool["provider_revision"],
      request_kind: request_kind(intent),
      purpose: purpose(intent),
      tool_id: intent["tool_id"],
      capability: intent["capability"],
      operation: intent["operation"],
      selectors: intent["selectors"],
      parameters: intent["parameters"],
      reason: intent["reason"],
      delay_seconds: intent["delay_seconds"],
      evidence_ids: intent["evidence_ids"],
      affected_conditions: intent["affected_conditions"],
      expected_result: intent["expected_result"],
      verification_intent: proposal.verification_intent,
      verification_tool: proposal.verification_tool,
      resolver_identity:
        Map.put(proposal.resolver, "source_result_digest", proposal.result_digest),
      reserved_operation_id: operation_id,
      operation_idempotency_key: operation_key,
      preflight_status: preflight.status,
      preflight_context: preflight.context,
      preflight_reason: preflight.reason,
      expires_at: run.deadline_at,
      revision: 1
    }
  end

  defp purpose(%{"purpose" => "investigation"}), do: :investigation
  defp purpose(%{"purpose" => "remediation"}), do: :remediation
  defp purpose(_intent), do: nil

  defp request_kind(%{"request_kind" => "observation"}), do: :observation
  defp request_kind(%{"request_kind" => "effect"}), do: :effect
  defp request_kind(_intent), do: nil

  defp proposal_digest(attributes) do
    attributes
    |> :erlang.term_to_binary([:deterministic])
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp replay(proposal, turn, incident, run) do
    if proposal.case_id == incident.id and proposal.resolution_run_id == run.id and
         proposal.resolver_identity["source_result_digest"] == turn.result_digest do
      proposal
    else
      invalid("Proposal source Turn was already materialized with different input")
    end
  end

  defp lock_case(id) do
    Case
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(id: id)
    |> Ash.Query.lock(:for_update)
    |> Ash.read_one(authorize?: false)
    |> required("Case is unavailable")
  end

  defp lock_run(id, case_id) do
    ResolutionRun
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(id: id, case_id: case_id, active: true)
    |> Ash.Query.lock(:for_update)
    |> Ash.read_one(authorize?: false)
    |> required("Active ResolutionRun is unavailable")
  end

  defp lock_turn(id, case_id, run_id) do
    Turn
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(id: id, case_id: case_id, resolution_run_id: run_id)
    |> Ash.Query.lock(:for_update)
    |> Ash.read_one(authorize?: false)
    |> required("Proposal source Turn is unavailable")
  end

  defp existing_proposal(turn_id) do
    Proposal
    |> Ash.Query.for_read(:by_source_turn, %{source_turn_id: turn_id})
    |> Ash.Query.lock(:for_update)
    |> Ash.read_one(authorize?: false)
  end

  defp required({:ok, nil}, message), do: invalid(message)
  defp required(result, _message), do: result

  defp ensure_running(%{status: :running, cancel_requested: false}, %{status: :running} = run) do
    if DateTime.compare(DateTime.utc_now(), run.deadline_at) == :lt,
      do: :ok,
      else: invalid("ResolutionRun deadline has elapsed")
  end

  defp ensure_running(%{cancel_requested: true}, _run),
    do: invalid("Case cancellation was requested")

  defp ensure_running(_incident, _run), do: invalid("Case resolution is not running")

  defp invalid(message),
    do: {:error, Ash.Error.Changes.InvalidChanges.exception(message: message)}

  defp map(value) when is_map(value), do: value
  defp map(_value), do: %{}
  defp nonempty?(value), do: is_binary(value) and byte_size(value) > 0
  defp positive?(value), do: is_integer(value) and value > 0

  defp find_error(%RequestError{} = error), do: error

  defp find_error(%{errors: [error]}), do: find_error(error)

  defp find_error(_error), do: nil
end
