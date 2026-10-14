defmodule Skopos.Cases.Evidence.Calculations.Content do
  use Ash.Resource.Calculation

  require Ash.Query

  alias Skopos.Cases
  alias Skopos.Cases.{Operation, VerificationAttempt}

  @impl true
  def load(_query, _opts, _context),
    do: [:case_id, :resolution_run_id, :kind, :source, :source_ref, :stored_content, :observed_at]

  @impl true
  def calculate(records, opts, context) do
    with {:ok, operations} <- sources(records, Operation, opts, context),
         {:ok, verifications} <- sources(records, VerificationAttempt, opts, context) do
      Enum.reduce_while(records, {:ok, []}, fn record, {:ok, contents} ->
        case content(record, operations, verifications, opts) do
          {:ok, content} -> {:cont, {:ok, [content | contents]}}
          {:error, _error} = error -> {:halt, error}
        end
      end)
      |> case do
        {:ok, contents} -> {:ok, Enum.reverse(contents)}
        error -> error
      end
    end
  end

  defp sources(records, resource, calculation_opts, context) do
    ids = for record <- records, canonical_source(record) == resource, do: record.source_ref

    if ids == [] do
      {:ok, %{}}
    else
      query = Ash.Query.filter(resource, id in ^Enum.uniq(ids))
      summary? = calculation_opts[:summary?] == true
      recovery_metadata? = calculation_opts[:recovery_metadata?] == true

      query =
        if summary? or recovery_metadata? do
          fields = [:case_id, :resolution_run_id, :target_id, :status, :outcome_category]

          fields =
            case resource do
              Operation -> fields ++ [:purpose, :completed_at]
              VerificationAttempt -> fields ++ [:observed_at]
            end

          fields =
            if recovery_metadata? do
              case resource do
                Operation -> fields ++ [:capability, :operation, :selectors]
                VerificationAttempt -> fields ++ [:operation_id]
              end
            else
              fields
            end

          Ash.Query.select(query, fields)
        else
          query
        end

      opts = [query: query, actor: context.actor, authorize?: context.authorize?]

      result =
        case resource do
          Operation when not summary? and not recovery_metadata? ->
            Cases.list_operations(Keyword.put(opts, :load, [:proposal]))

          Operation ->
            Cases.list_operations(opts)

          VerificationAttempt ->
            Cases.list_verification_attempts(opts)
        end

      case result do
        {:ok, sources} -> {:ok, Map.new(sources, &{&1.id, &1})}
        error -> error
      end
    end
  end

  defp content(evidence, operations, verifications, opts) do
    case canonical_source(evidence) do
      Operation ->
        operation_content(evidence, Map.get(operations, evidence.source_ref), opts)

      VerificationAttempt ->
        verification_content(evidence, Map.get(verifications, evidence.source_ref), opts)

      nil ->
        {:ok,
         if(opts[:summary?], do: summary(evidence.stored_content), else: evidence.stored_content)}
    end
  end

  defp operation_content(evidence, source, opts) do
    with %Operation{} = operation <- source,
         true <- bound?(evidence, operation),
         true <- operation.status in [:applied, :failed, :partial, :unknown],
         true <- evidence.observed_at == operation.completed_at,
         true <- evidence.kind == operation_kind(operation) do
      cond do
        opts[:summary?] -> {:ok, source_summary(operation)}
        opts[:recovery_metadata?] -> {:ok, operation_metadata(operation)}
        true -> full_operation_content(operation)
      end
    else
      _invalid -> invalid_source("Evidence has no matching terminal Operation receipt")
    end
  end

  defp operation_metadata(operation) do
    %{
      "status" => to_string(operation.status),
      "category" => operation.outcome_category,
      "capability" => operation.capability,
      "operation" => operation.operation,
      "selectors" => operation.selectors,
      "target_id" => operation.target_id
    }
  end

  defp full_operation_content(operation) do
    {facts, details} = Map.pop(operation.result_details, "facts")

    {facts, details} =
      if operation.purpose == :investigation and operation.request_kind == :effect and
           is_nil(facts),
         do: {details, %{}},
         else: {facts || %{}, details}

    {:ok,
     Map.merge(operation_metadata(operation), %{
       "reference" => operation.reference,
       "request_kind" => to_string(operation.request_kind),
       "purpose" => to_string(operation.purpose),
       "parameters" => operation.parameters,
       "details" => details,
       "facts" => facts,
       "tool_id" => operation.proposal.tool_id,
       "access_method_id" => operation.access_method_id,
       "access_method_revision" => operation.access_method_revision
     })}
  end

  defp verification_content(evidence, source, opts) do
    with %VerificationAttempt{} = attempt <- source,
         true <- bound?(evidence, attempt),
         true <- attempt.status in [:verified, :not_verified, :unknown],
         true <- evidence.observed_at == attempt.observed_at,
         true <- evidence.kind == "target_verification" do
      cond do
        opts[:summary?] ->
          {:ok, source_summary(attempt)}

        opts[:recovery_metadata?] ->
          {:ok, verification_metadata(attempt)}

        true ->
          {:ok,
           Map.merge(verification_metadata(attempt), %{
             "facts" => attempt.facts,
             "provider_evidence" => attempt.provider_evidence,
             "expected" => attempt.expected,
             "access_method_id" => attempt.access_method_id
           })}
      end
    else
      _invalid -> invalid_source("Evidence has no matching terminal Verification receipt")
    end
  end

  defp verification_metadata(attempt) do
    %{
      "status" => to_string(attempt.status),
      "category" => attempt.outcome_category,
      "operation_id" => attempt.operation_id,
      "target_id" => attempt.target_id
    }
  end

  defp source_summary(source) do
    summary(%{
      "status" => to_string(source.status),
      "category" => source.outcome_category,
      "target_id" => source.target_id
    })
  end

  defp summary(content) do
    attributes = content["attributes"]
    title = if is_map(attributes), do: attributes["title"]
    target_ref = content["target_ref"]
    target_label = if is_map(target_ref), do: target_ref["value"]

    %{
      "status" => summary_text(content["status"] || content["state"], 80),
      "category" => summary_text(content["category"], 120),
      "target_id" => summary_id(content["target_id"]),
      "condition_id" => summary_id(content["condition_id"]),
      "title" => summary_text(title || content["message"], 200),
      "target_label" => summary_text(target_label, 500)
    }
  end

  defp summary_text(value, length) when is_binary(value),
    do: value |> String.to_charlist() |> Enum.take(length) |> List.to_string()

  defp summary_text(_value, _length), do: nil

  defp summary_id(value) do
    case Ecto.UUID.cast(value) do
      {:ok, id} -> id
      :error -> nil
    end
  end

  defp canonical_source(%{source: "operation", kind: kind})
       when kind in ["observation", "operation_outcome"], do: Operation

  defp canonical_source(%{source: "verification", kind: "target_verification"}),
    do: VerificationAttempt

  defp canonical_source(_evidence), do: nil

  defp invalid_source(message) do
    {:error, Ash.Error.Changes.InvalidAttribute.exception(field: :source_ref, message: message)}
  end

  defp bound?(evidence, source) do
    evidence.case_id == source.case_id and
      evidence.resolution_run_id == source.resolution_run_id and
      evidence.stored_content["target_id"] == source.target_id
  end

  defp operation_kind(%{purpose: :investigation}), do: "observation"
  defp operation_kind(%{purpose: :remediation}), do: "operation_outcome"
end
