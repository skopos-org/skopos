defmodule Skopos.Providers.AI do
  @moduledoc false

  @max_input_bytes 2_097_152
  @optional_context_bytes 65_536
  @resolver_disclosure_limits %{max_items: 100, max_bytes: @max_input_bytes}
  @resolver_reason_codepoints 500
  @max_output_bytes 65_536
  @reviewer_reason_codepoints 1_000
  @handoff_input_codepoints 250
  @file_read_bytes 8_192

  def resolver_disclosure_limits, do: @resolver_disclosure_limits
  def max_input_bytes, do: @max_input_bytes
  def optional_context_bytes, do: @optional_context_bytes
  def resolver_reason_codepoints, do: @resolver_reason_codepoints
  def max_output_bytes, do: @max_output_bytes
  def reviewer_reason_codepoints, do: @reviewer_reason_codepoints
  def handoff_input_codepoints, do: @handoff_input_codepoints
  def file_read_bytes, do: @file_read_bytes

  def valid_resolver_reason?(reason) when is_binary(reason) and byte_size(reason) > 0 do
    case :unicode.characters_to_list(reason) do
      codepoints when is_list(codepoints) -> length(codepoints) <= @resolver_reason_codepoints
      _invalid -> false
    end
  end

  def valid_resolver_reason?(_reason), do: false

  defmodule Disclosure do
    @moduledoc false
    @enforce_keys [:allowed_target_ids, :allowed_evidence_kinds, :max_items, :max_bytes]
    defstruct @enforce_keys
    @type t :: %__MODULE__{}
  end

  defmodule Budget do
    @moduledoc false

    @enforce_keys [
      :remaining_turns,
      :remaining_tokens,
      :remaining_target_requests,
      :remaining_effects,
      :remaining_related_targets
    ]

    defstruct @enforce_keys
    @type t :: %__MODULE__{}
  end

  defmodule Evidence do
    @moduledoc false
    @enforce_keys [:id, :kind, :content]
    defstruct @enforce_keys ++ [target_id: nil, observed_at_us: nil]
    @type t :: %__MODULE__{}
  end

  defmodule Condition do
    @moduledoc false

    @enforce_keys [
      :id,
      :revision,
      :occurrence,
      :predicate,
      :subject_key,
      :subject_ref,
      :state,
      :target_id,
      :current_occurred_at_us
    ]

    defstruct @enforce_keys ++
                [recovery_status: nil, recovery_evidence_ids: [], failed_observation_ids: []]

    @type t :: %__MODULE__{}
  end

  def recovery_evidence_ids(request), do: request.recovery_evidence_ids

  def claim_fact_keys(%{kind: kind, content: %{"facts" => facts}})
      when kind in ["observation", "target_verification"] and is_map(facts),
      do: Map.keys(facts)

  # A durable claim names the delivered field; it does not contain file bytes.
  # Current source admission and actual AI disclosure remain the owners' checks.
  def claim_fact_keys(%{kind: "file_read", content: %{"status" => "available"}}),
    do: ["value"]

  def claim_fact_keys(_evidence), do: []

  def target_candidate_evidence_ids(request, target_id) do
    request.evidence
    |> Enum.filter(fn evidence ->
      (evidence.kind == "target_candidates" and is_map(evidence.content) and
         is_list(evidence.content["candidate_ids"]) and
         target_id in evidence.content["candidate_ids"]) or
        (evidence.kind == "signal_event" and is_map(evidence.content) and
           evidence.content["current"] == true and
           Enum.any?(request.conditions, fn condition ->
             condition.id == evidence.content["condition_id"] and
               condition.revision == evidence.content["condition_revision"] and
               condition.target_id == target_id
           end))
    end)
    |> Enum.map(& &1.id)
  end

  def case_split_observations(request) do
    Enum.filter(request.evidence, fn
      %Evidence{kind: kind, target_id: target_id, observed_at_us: observed_at, content: content}
      when kind in ["observation", "target_verification"] and is_binary(target_id) and
             is_integer(observed_at) and is_map(content) ->
        content["status"] in ["applied", "verified"] and
          Enum.any?(request.conditions, fn condition ->
            condition.target_id == target_id and
              is_integer(condition.current_occurred_at_us) and
              observed_at >= condition.current_occurred_at_us
          end)

      _other ->
        false
    end)
  end

  def available_proposal_tools(request) do
    Enum.filter(request.proposal_tools, &proposal_requirements_available?(&1, request))
  end

  def proposal_evidence_ids(request) do
    related_targets =
      request.target_relations
      |> Enum.flat_map(fn relation ->
        cond do
          relation.source_target.id == request.selected_target_id ->
            [relation.destination_target.id]

          relation.destination_target.id == request.selected_target_id ->
            [relation.source_target.id]

          true ->
            []
        end
      end)
      |> MapSet.new()

    conditions =
      Enum.filter(request.conditions, fn condition ->
        MapSet.member?(related_targets, condition.target_id)
      end)

    (request.evidence ++ request.observation_results)
    |> Enum.filter(fn
      %Evidence{kind: "observation", target_id: target_id, observed_at_us: at} = item ->
        target_id == request.selected_target_id or
          Enum.any?(conditions, fn condition ->
            condition.target_id == target_id and is_integer(at) and
              at >= condition.current_occurred_at_us and
              (condition.state == :firing or
                 item.id in condition.recovery_evidence_ids or
                 item.id in condition.failed_observation_ids)
          end)

      %{__struct__: __MODULE__.ObservationResult, kind: "observation", target_id: target_id} ->
        target_id == request.selected_target_id

      _evidence ->
        false
    end)
    |> Enum.map(& &1.id)
    |> Enum.uniq()
  end

  def effect_target_evidence_ids(request) do
    (request.evidence ++ request.observation_results)
    |> Enum.filter(fn
      %Evidence{kind: "observation", target_id: target_id} ->
        target_id == request.selected_target_id

      %{__struct__: __MODULE__.ObservationResult, kind: "observation", target_id: target_id} ->
        target_id == request.selected_target_id

      _other ->
        false
    end)
    |> Enum.map(& &1.id)
    |> Enum.uniq()
  end

  def proposal_requirements_match?(tool, request, evidence_ids, parameters)
      when is_list(evidence_ids) and is_map(parameters) do
    Enum.all?(tool.evidence_requirements, fn requirement ->
      Enum.any?(matching_evidence(requirement, tool, request, evidence_ids), fn evidence ->
        parameters[requirement.parameter] == evidence.content["facts"][requirement.fact]
      end)
    end)
  end

  def proposal_requirements_match?(_tool, _request, _evidence_ids, _parameters), do: false

  defp proposal_requirements_available?(tool, request) do
    tool.request_kind == :observation or
      Enum.all?(tool.evidence_requirements, fn requirement ->
        matching_evidence(requirement, tool, request, nil) != []
      end)
  end

  defp matching_evidence(requirement, tool, request, evidence_ids) do
    observation_tool_ids =
      (request.observation_tools ++ request.proposal_tools)
      |> Enum.filter(fn observation ->
        Map.get(observation, :request_kind, :observation) == :observation and
          observation.target_id == tool.target_id and
          observation.access_method_id == tool.access_method_id and
          observation.provider_id == tool.provider_id and
          observation.operation == requirement.observation
      end)
      |> Enum.map(& &1.id)

    if observation_tool_ids != [] do
      Enum.filter(request.evidence, fn evidence ->
        evidence.kind == "observation" and evidence.target_id == tool.target_id and
          is_map(evidence.content) and
          (is_nil(evidence_ids) or evidence.id in evidence_ids) and
          evidence.content["tool_id"] in observation_tool_ids and
          is_map(evidence.content["facts"]) and
          Map.has_key?(evidence.content["facts"], requirement.fact) and
          not superseded_observation?(evidence, request, tool, requirement, observation_tool_ids)
      end)
    else
      []
    end
  end

  defp superseded_observation?(observation, request, tool, requirement, observation_tool_ids) do
    Enum.any?(request.evidence, fn newer ->
      newer.target_id == tool.target_id and
        newer.id != observation.id and
        later_evidence?(newer, observation) and
        is_map(newer.content) and
        newer.content["access_method_id"] == tool.access_method_id and
        is_map(newer.content["facts"]) and
        Map.has_key?(newer.content["facts"], requirement.fact) and
        ((newer.kind == "target_verification" and newer.content["status"] == "verified") or
           (newer.kind == "observation" and newer.content["tool_id"] in observation_tool_ids))
    end)
  end

  defp later_evidence?(%{observed_at_us: newer}, %{observed_at_us: older})
       when is_integer(newer) and is_integer(older),
       do: newer > older

  defp later_evidence?(_newer, _older), do: false

  defmodule TargetCandidate do
    @moduledoc false
    @enforce_keys [:id, :revision, :name, :kind, :type_id, :facts]
    defstruct @enforce_keys
    @type t :: %__MODULE__{}
  end

  defmodule TargetSearch do
    @moduledoc false
    @enforce_keys [:query, :reason]
    defstruct @enforce_keys
    @type t :: %__MODULE__{}
  end

  defmodule FileRead do
    @moduledoc false
    @enforce_keys [:source_evidence_id, :reference, :offset, :length, :reason]
    defstruct @enforce_keys
    @type t :: %__MODULE__{}
  end

  defmodule TargetSelection do
    @moduledoc false
    @enforce_keys [:target_id, :target_revision, :evidence_ids, :reason]
    defstruct @enforce_keys
    @type t :: %__MODULE__{}
  end

  defmodule ObservationResult do
    @moduledoc false
    @enforce_keys [:id, :tool_id, :target_id, :kind, :status, :content]
    defstruct @enforce_keys
    @type t :: %__MODULE__{}
  end

  defmodule TargetRelation do
    @moduledoc false
    @enforce_keys [:id, :revision, :source_target, :destination_target, :kind]
    defstruct @enforce_keys ++ [attributes: %{}]
    @type t :: %__MODULE__{}
  end

  defmodule TargetTraversal do
    @moduledoc false

    @enforce_keys [
      :relationship_id,
      :relationship_revision,
      :next_target_id,
      :next_target_revision,
      :evidence_ids,
      :reason
    ]

    defstruct @enforce_keys
    @type t :: %__MODULE__{}
  end

  defmodule ObservationTool do
    @moduledoc false

    @enforce_keys [
      :id,
      :target_id,
      :target_revision,
      :access_method_id,
      :access_method_revision,
      :provider_id,
      :provider_revision,
      :capability,
      :operation,
      :description,
      :input_schema,
      :output_schema,
      :verification_schema
    ]

    defstruct @enforce_keys
    @type t :: %__MODULE__{}
  end

  defmodule ProposalTool do
    @moduledoc false

    @enforce_keys [
      :id,
      :target_id,
      :target_revision,
      :access_method_id,
      :access_method_revision,
      :provider_id,
      :provider_revision,
      :request_kind,
      :capability,
      :operation,
      :description,
      :input_schema
    ]

    defstruct @enforce_keys ++ [evidence_requirements: []]
    @type t :: %__MODULE__{}
  end

  defmodule VerificationIntent do
    @moduledoc false
    @enforce_keys [:tool_id, :selectors, :parameters, :expected_result]
    defstruct @enforce_keys
    @type t :: %__MODULE__{}
  end

  defmodule Proposal do
    @moduledoc false

    @enforce_keys [
      :tool_id,
      :target_id,
      :target_revision,
      :access_method_id,
      :access_method_revision,
      :request_kind,
      :purpose,
      :capability,
      :operation,
      :selectors,
      :parameters,
      :reason,
      :evidence_ids
    ]

    defstruct @enforce_keys ++
                [
                  affected_conditions: [],
                  expected_result: %{},
                  verification_intent: nil,
                  delay_seconds: 0
                ]

    @type t :: %__MODULE__{}
  end

  def valid_proposal_purpose?(:observation, :investigation), do: true

  def valid_proposal_purpose?(:effect, purpose) when purpose in [:investigation, :remediation],
    do: true

  def valid_proposal_purpose?(_kind, _purpose), do: false

  def valid_affected_conditions?(%Proposal{purpose: :investigation} = proposal, conditions),
    do:
      valid_affected_conditions?(
        :observation,
        proposal.affected_conditions,
        conditions,
        proposal.evidence_ids
      )

  def valid_affected_conditions?(%Proposal{} = proposal, conditions),
    do:
      valid_affected_conditions?(
        proposal.request_kind,
        proposal.affected_conditions,
        conditions,
        proposal.evidence_ids
      )

  def valid_affected_conditions?(:observation, claims, conditions, _evidence_ids)
      when is_list(claims) and is_list(conditions),
      do: valid_condition_claims?(claims, conditions, false, [])

  def valid_affected_conditions?(:effect, [], [], _evidence_ids),
    do: true

  def valid_affected_conditions?(:effect, claims, conditions, evidence_ids)
      when is_list(claims) and claims != [] and is_list(conditions) and
             is_list(evidence_ids) do
    valid_condition_claims?(claims, conditions, true, evidence_ids)
  end

  def valid_affected_conditions?(_kind, _claims, _conditions, _evidence_ids), do: false

  defp valid_condition_claims?(claims, conditions, effect?, evidence_ids) do
    ids = Enum.map(claims, &if(is_map(&1), do: &1["condition_id"]))
    current = Map.new(conditions, &{&1.id, &1})

    length(claims) <= length(conditions) and length(ids) == MapSet.size(MapSet.new(ids)) and
      Enum.all?(claims, fn
        %{"condition_id" => id, "revision" => revision} = claim
        when is_binary(id) and is_integer(revision) and
               (map_size(claim) == 2 or (effect? and map_size(claim) == 4)) ->
          case Map.get(current, id) do
            %Condition{revision: ^revision} = condition ->
              valid_link_shape?(claim, effect?) and
                (not effect? or condition.state == :firing or
                   (condition.state == :recovered and
                      ((condition.recovery_status == :ready_for_review and
                          Enum.any?(condition.recovery_evidence_ids, &(&1 in evidence_ids))) or
                         Enum.any?(condition.failed_observation_ids, &(&1 in evidence_ids)))))

            _other ->
              false
          end

        _other ->
          false
      end)
  end

  defp valid_link_shape?(claim, true) when map_size(claim) == 4,
    do:
      is_binary(claim["relationship_id"]) and claim["relationship_id"] != "" and
        is_integer(claim["relationship_revision"]) and claim["relationship_revision"] > 0

  defp valid_link_shape?(claim, _effect?), do: map_size(claim) == 2

  defmodule RecoveryConclusion do
    @moduledoc false
    @enforce_keys [:reason, :evidence_ids]
    defstruct @enforce_keys ++ [condition_claims: [], desired_outcome_claims: []]
    @type t :: %__MODULE__{}
  end

  defmodule CaseSplit do
    @moduledoc false
    @enforce_keys [:condition_ids, :evidence_ids, :remaining_evidence_ids, :reason]
    defstruct @enforce_keys
    @type t :: %__MODULE__{}
  end

  defmodule Handoff do
    @moduledoc false
    @enforce_keys [:reason, :required_input]
    defstruct @enforce_keys
    @type t :: %__MODULE__{}
  end

  defmodule Usage do
    @moduledoc false
    @enforce_keys [:input_tokens, :output_tokens]
    defstruct @enforce_keys ++ [cached_tokens: nil, reasoning_tokens: nil, finish_reason: nil]
    @type t :: %__MODULE__{}
  end

  defmodule ResolverDecision do
    @moduledoc false
    @enforce_keys [:intent, :usage]
    defstruct @enforce_keys ++ [condition_groups: [], condition_assessments: []]
    @type t :: %__MODULE__{}
  end

  def normalize_condition_groups(groups, conditions, evidence) do
    available = MapSet.new(Enum.map(conditions, & &1.id))
    cited = MapSet.new(Enum.map(evidence, & &1.id))

    {accepted, assigned} =
      if(is_list(groups), do: Enum.take(groups, 32), else: [])
      |> Enum.reduce({[], MapSet.new()}, fn group, {accepted, assigned} ->
        case valid_group(group, available, cited, assigned) do
          {:ok, normalized} ->
            {[normalized | accepted],
             MapSet.union(assigned, MapSet.new(normalized["condition_ids"]))}

          :invalid ->
            {accepted, assigned}
        end
      end)

    missing =
      conditions
      |> Enum.reject(&MapSet.member?(assigned, &1.id))
      |> Enum.map(fn condition ->
        %{
          "condition_ids" => [condition.id],
          "assessment" => "unknown",
          "reason" => nil,
          "evidence_ids" => []
        }
      end)

    Enum.reverse(accepted) ++ missing
  end

  defp valid_group(
         %{
           "condition_ids" => ids,
           "assessment" => assessment,
           "reason" => reason,
           "evidence_ids" => evidence_ids
         },
         available,
         cited,
         assigned
       )
       when is_list(ids) and is_list(evidence_ids) and
              assessment in ["related", "independent", "unknown"] and
              is_binary(reason) do
    id_set = MapSet.new(ids)
    evidence_set = MapSet.new(evidence_ids)

    if ids != [] and length(ids) <= 32 and length(ids) == MapSet.size(id_set) and
         MapSet.subset?(id_set, available) and MapSet.disjoint?(id_set, assigned) and
         length(evidence_ids) <= 32 and length(evidence_ids) == MapSet.size(evidence_set) and
         MapSet.subset?(evidence_set, cited) and valid_resolver_reason?(reason) and
         (assessment == "unknown" or evidence_ids != []) do
      {:ok,
       %{
         "condition_ids" => ids,
         "assessment" => assessment,
         "reason" => reason,
         "evidence_ids" => evidence_ids
       }}
    else
      :invalid
    end
  end

  defp valid_group(_group, _available, _cited, _assigned), do: :invalid

  defmodule ResolverRequest do
    @moduledoc false

    @enforce_keys [
      :provider_revision,
      :session_id,
      :case_id,
      :turn,
      :objective,
      :alert_state,
      :report_language,
      :operating_instructions,
      :disclosure,
      :budget,
      :evidence,
      :target_candidates,
      :observation_results,
      :target_relations,
      :observation_tools,
      :proposal_tools
    ]

    defstruct @enforce_keys ++
                [
                  selected_target_id: nil,
                  selected_target_revision: nil,
                  retry_context: nil,
                  traversable_relation_ids: [],
                  conditions: [],
                  historical_evidence: [],
                  recovery_evidence_ids: [],
                  case_symptom: nil
                ]

    @type t :: %__MODULE__{}
  end

  defmodule ReviewRequest do
    @moduledoc false

    @enforce_keys [
      :provider_revision,
      :session_id,
      :resolver_session_id,
      :case_id,
      :resolution_run_id,
      :recovery_evidence_ids,
      :objective,
      :report_language,
      :operating_instructions,
      :proposal,
      :source_evidence,
      :cited_evidence,
      :budget
    ]

    defstruct @enforce_keys ++
                [
                  conditions: [],
                  initial_target_id: nil,
                  target_relations: [],
                  context_evidence: [],
                  retry_context: nil
                ]

    @type t :: %__MODULE__{}
  end

  defmodule ReviewDecision do
    @moduledoc false
    @enforce_keys [:verdict, :reason, :usage]
    defstruct @enforce_keys ++ [purpose_assessment: nil, desired_outcome_assessment: nil]
    @type t :: %__MODULE__{}
  end

  defmodule RecoveryReviewRequest do
    @moduledoc false

    @enforce_keys [
      :provider_revision,
      :session_id,
      :resolver_session_id,
      :case_id,
      :objective,
      :report_language,
      :conditions,
      :source_evidence,
      :cited_evidence,
      :conclusion,
      :budget
    ]

    defstruct @enforce_keys ++ [context_evidence: [], retry_context: nil, case_symptom: nil]
    @type t :: %__MODULE__{}
  end

  defmodule Selection do
    @moduledoc false
    @enforce_keys [:role, :provider_id, :provider_revision, :source]
    defstruct @enforce_keys ++ [assignment_id: nil, assignment_revision: nil]
    @type t :: %__MODULE__{}
  end

  defmodule Error do
    @moduledoc false
    use Splode.Error,
      class: :unknown,
      fields: [:category, :message, :usage, :dispatched?, :failure_code, :failure_path]

    @impl true
    def message(error), do: error.message

    # Delivery may handle an AI failure only when the whole error is that failure.
    # A storage failure alongside it must keep its durable retry semantics.
    def unwrap(%__MODULE__{} = error), do: error
    def unwrap(%Ash.Error.Unknown{errors: [error]}), do: unwrap(error)
    def unwrap(_error), do: nil

    # Ash may select Invalid/Forbidden as the outer class of a mixed error.
    # Another action error alongside AI accounting must keep its original cause.
    def context_failure?(%__MODULE__{}), do: false
    def context_failure?(%Ash.Error.Unknown{} = error), do: is_nil(unwrap(error))
    def context_failure?(%Ash.Error.Framework{}), do: true

    def context_failure?(%{errors: errors} = error) when is_list(errors),
      do:
        Enum.any?(errors, &context_failure?/1) or
          (not is_nil(find(error)) and Enum.any?(errors, &is_nil(find(&1))))

    def context_failure?(%{class: class}) when class in [:unknown, :framework], do: true
    def context_failure?(_error), do: false

    # Accounting preserves known native usage even when another failure is present.
    def find(%__MODULE__{} = error), do: error
    def find(%{errors: errors}) when is_list(errors), do: Enum.find_value(errors, &find/1)
    def find(_error), do: nil
  end

  def file_read_options(%ResolverRequest{} = request) do
    alias Skopos.Providers.Target.FileReference

    unavailable =
      request.evidence
      |> Enum.filter(&(&1.kind == "file_read" and &1.content["status"] == "unavailable"))
      |> Enum.map(&get_in(&1.content, ["reference", "id"]))
      |> MapSet.new()

    (request.evidence ++ request.observation_results)
    |> Enum.flat_map(fn source ->
      source.content
      |> FileReference.references_in()
      |> Enum.uniq()
      |> Enum.filter(fn reference ->
        reference["target_id"] == request.selected_target_id and
          not MapSet.member?(unavailable, reference["id"])
      end)
      |> Enum.map(&%{"source_evidence_id" => source.id, "reference" => &1})
    end)
    |> Enum.with_index(1)
    |> Enum.map(fn {option, index} -> Map.put(option, "file_ref", "file-#{index}") end)
  end

  def resolver_disclosure_items(%ResolverRequest{} = request) do
    request.conditions ++
      request.evidence ++
      request.historical_evidence ++
      request.target_candidates ++
      request.observation_results ++
      request.target_relations ++
      request.observation_tools ++
      request.proposal_tools ++
      file_read_options(request)
  end

  def resolver_disclosure_size(%ResolverRequest{} = request) do
    request
    |> plain_value()
    |> Map.put(:file_read_options, plain_value(file_read_options(request)))
    |> encoded_input_size()
  end

  def input_size(request), do: request |> plain_value() |> encoded_input_size()

  defp encoded_input_size(value) do
    case Jason.encode(value) do
      {:ok, value} -> byte_size(value)
      {:error, _error} -> :infinity
    end
  end

  defp plain_value(%_{} = value), do: value |> Map.from_struct() |> plain_value()

  defp plain_value(value) when is_map(value),
    do: Map.new(value, fn {key, nested} -> {key, plain_value(nested)} end)

  defp plain_value(value) when is_list(value), do: Enum.map(value, &plain_value/1)
  defp plain_value(value), do: value

  @type invocation :: map()
  @type adapter_error ::
          {:error,
           :authentication
           | :unreachable
           | :timeout
           | :failed
           | :rate_limited
           | :cancelled
           | :invalid_output, String.t()}
          | {:error, Ash.Error.t()}

  @type metered_adapter_error ::
          {:error, :invalid_output | :failed, String.t(), Usage.t()}
          | {:error, :invalid_output | :failed, String.t(), Usage.t(), String.t()}
          | {:error, :invalid_output | :failed, String.t(), Usage.t(), String.t(),
             String.t() | nil}

  @callback resolve(state :: term(), ResolverRequest.t(), invocation()) ::
              {:ok, ResolverDecision.t()} | adapter_error() | metered_adapter_error()
  @callback review(state :: term(), ReviewRequest.t(), invocation()) ::
              {:ok, ReviewDecision.t()} | adapter_error() | metered_adapter_error()

  @callback review_recovery(state :: term(), RecoveryReviewRequest.t(), invocation()) ::
              {:ok, ReviewDecision.t()} | adapter_error() | metered_adapter_error()
end
