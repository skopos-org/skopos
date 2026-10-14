defmodule Skopos.Cases.Case.Symptom do
  @moduledoc false

  alias Skopos.Providers.AI

  def current(%{id: id, trigger_kind: kind, title: title, initial_context: context})
      when kind in [:manual, :audit] and is_binary(id) and is_map(context) do
    desired_outcome = context["desired_outcome"]

    if valid_desired_outcome?(desired_outcome) do
      build(id, kind, title, context, desired_outcome)
    end
  end

  def current(%{
        "id" => id,
        "trigger_kind" => kind,
        "title" => title,
        "initial_context" => context
      })
      when kind in ["manual", "audit"] do
    current(%{
      id: id,
      trigger_kind: if(kind == "manual", do: :manual, else: :audit),
      title: title,
      initial_context: context
    })
  end

  def current(_incident), do: nil

  defp build(id, kind, title, context, desired_outcome) do
    text =
      case kind do
        :audit -> preferred(context["objective"], title)
        :manual -> preferred(context["observed_problem"], title)
      end

    digest =
      :crypto.hash(
        :sha256,
        :erlang.term_to_binary({id, kind, text, desired_outcome}, [:deterministic])
      )
      |> Base.encode16(case: :lower)

    %{id: digest, text: text, desired_outcome: desired_outcome}
  end

  def valid?(nil), do: true

  def valid?(%{id: id, text: text, desired_outcome: desired_outcome}) do
    is_binary(id) and byte_size(id) == 64 and String.match?(id, ~r/\A[0-9a-f]{64}\z/) and
      is_binary(text) and byte_size(text) <= 8_000 and String.trim(text) != "" and
      String.length(text) <= 2_000 and valid_desired_outcome?(desired_outcome)
  end

  def valid?(_symptom), do: false

  def valid_desired_outcome?(value) when is_binary(value) and byte_size(value) <= 8_000,
    do: String.trim(value) != "" and String.length(value) <= 2_000

  def valid_desired_outcome?(_value), do: false

  def valid_claims?([], nil, _cited_ids, _evidence), do: true

  def valid_claims?(claims, %{id: symptom_id}, cited_ids, evidence)
      when is_list(claims) and is_list(cited_ids) and is_list(evidence) do
    by_id = Map.new(evidence, &{&1.id, &1})

    length(claims) in 1..3 and
      Enum.all?(claims, fn claim ->
        if is_map(claim) and
             Enum.sort(Map.keys(claim)) == ~w(evidence_id fact_keys reason symptom_id) do
          item = Map.get(by_id, claim["evidence_id"])
          keys = claim["fact_keys"]
          available_keys = AI.claim_fact_keys(item)

          claim["symptom_id"] == symptom_id and claim["evidence_id"] in cited_ids and
            not is_nil(item) and is_list(keys) and length(keys) in 1..5 and
            length(Enum.uniq(keys)) == length(keys) and
            Enum.all?(keys, &(is_binary(&1) and &1 in available_keys)) and
            AI.valid_resolver_reason?(claim["reason"])
        else
          false
        end
      end)
  end

  def valid_claims?(_claims, _symptom, _cited_ids, _evidence), do: false

  def valid_assessment?(nil, nil, [], _verdict), do: true

  def valid_assessment?(
        assessment,
        %{id: symptom_id, desired_outcome: desired_outcome},
        claims,
        verdict
      )
      when is_map(assessment) and is_list(claims) do
    expected_ids = claims |> Enum.map(& &1["evidence_id"]) |> Enum.uniq() |> Enum.sort()
    received_ids = assessment["evidence_ids"]

    Enum.sort(Map.keys(assessment)) ==
      ~w(desired_outcome evidence_ids reason status symptom_id) and
      assessment["symptom_id"] == symptom_id and expected_ids != [] and
      assessment["desired_outcome"] == desired_outcome and
      is_list(received_ids) and Enum.all?(received_ids, &is_binary/1) and
      Enum.sort(received_ids) == expected_ids and
      assessment["status"] == assessment_status(verdict) and
      is_binary(assessment["reason"]) and byte_size(assessment["reason"]) <= 4_000 and
      String.trim(assessment["reason"]) != "" and
      String.length(assessment["reason"]) <= 1_000
  end

  def valid_assessment?(_assessment, _symptom, _claims, _verdict), do: false

  defp assessment_status(:approved), do: "supported"
  defp assessment_status(:rejected), do: "unsupported"
  defp assessment_status(:needs_human), do: "unknown"
  defp assessment_status(_verdict), do: nil

  defp preferred(value, fallback)
       when is_binary(value) and byte_size(value) <= 8_000 do
    if String.trim(value) != "" and String.length(value) <= 2_000,
      do: value,
      else: fallback
  end

  defp preferred(_value, fallback), do: fallback
end
