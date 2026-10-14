defmodule Skopos.Providers.Provider.Actions.AI do
  use Ash.Resource.Actions.Implementation

  alias Skopos.Providers
  alias Skopos.Providers.{AI, Redactor, Registry}

  @adapter_failures [
    :authentication,
    :unreachable,
    :timeout,
    :failed,
    :rate_limited,
    :cancelled,
    :invalid_output
  ]

  @impl true
  def run(input, opts, _context) do
    %{provider_id: provider_id, request: request, invocation: invocation} = input.arguments
    operation = opts[:operation]

    with :ok <- ensure_not_cancelled(invocation),
         :ok <- AI.Validator.validate_request(operation, request),
         {:ok, provider} <-
           Providers.load_provider_for_invocation(
             provider_id,
             request.provider_revision,
             :ai,
             authorize?: false
           ),
         {:ok, adapter} <- fetch_ai_adapter(provider.adapter_type),
         {:ok, state} <- build_state(adapter, provider),
         {:ok, decision} <-
           call_adapter(operation, adapter, state, request, invocation, provider.credentials),
         validation <- AI.Validator.validate_decision(operation, decision, request) do
      case validation do
        :ok ->
          {:ok, Redactor.value(decision, provider.credentials)}

        {:error, %AI.Error{} = error} ->
          {:error, %{error | usage: decision.usage, dispatched?: true}}

        error ->
          error
      end
    end
  rescue
    _error -> {:error, ai_error(:failed, "AI provider failed")}
  catch
    _kind, _reason -> {:error, ai_error(:failed, "AI provider failed")}
  end

  defp fetch_ai_adapter(adapter_type) do
    case Registry.fetch(adapter_type, AI) do
      {:ok, adapter} -> {:ok, adapter}
      {:error, _reason} -> {:error, ai_error(:failed, "AI adapter is unavailable", false)}
    end
  end

  defp build_state(adapter, provider) do
    case Registry.build(adapter, provider.configuration, provider.credentials) do
      {:ok, state} -> {:ok, state}
      {:error, _reason} -> {:error, ai_error(:failed, "AI configuration is invalid", false)}
    end
  end

  defp call_adapter(operation, adapter, state, request, invocation, credentials) do
    result =
      case operation do
        :resolve -> adapter.resolve(state, request, invocation)
        :review -> adapter.review(state, request, invocation)
        :review_recovery -> adapter.review_recovery(state, request, invocation)
      end

    normalize_adapter_result(operation, result, credentials)
  rescue
    error -> {:error, ai_error(:failed, Redactor.message(Exception.message(error), credentials))}
  catch
    _kind, _reason -> {:error, ai_error(:failed, "AI provider failed")}
  end

  defp normalize_adapter_result(:resolve, {:ok, %AI.ResolverDecision{} = decision}, _credentials),
    do: {:ok, decision}

  defp normalize_adapter_result(:review, {:ok, %AI.ReviewDecision{} = decision}, _credentials),
    do: {:ok, decision}

  defp normalize_adapter_result(
         :review_recovery,
         {:ok, %AI.ReviewDecision{} = decision},
         _credentials
       ),
       do: {:ok, decision}

  defp normalize_adapter_result(_operation, {:error, category, message}, credentials)
       when category in @adapter_failures and is_binary(message),
       do:
         {:error,
          AI.Error.exception(
            category: category,
            message: Redactor.message(message, credentials),
            dispatched?: true
          )}

  defp normalize_adapter_result(
         _operation,
         {:error, category, message, %AI.Usage{} = usage},
         credentials
       )
       when category in @adapter_failures and is_binary(message),
       do:
         {:error,
          AI.Error.exception(
            category: category,
            message: Redactor.message(message, credentials),
            usage: usage,
            dispatched?: true
          )}

  defp normalize_adapter_result(
         _operation,
         {:error, category, message, %AI.Usage{} = usage, failure_code, failure_path},
         credentials
       )
       when category in @adapter_failures and is_binary(message) and is_binary(failure_code) and
              byte_size(failure_code) <= 80 and
              (is_nil(failure_path) or
                 (is_binary(failure_path) and byte_size(failure_path) <= 200)),
       do:
         {:error,
          AI.Error.exception(
            category: category,
            message: Redactor.message(message, credentials),
            usage: usage,
            dispatched?: true,
            failure_code: failure_code,
            failure_path:
              if(failure_path, do: Redactor.message(failure_path, credentials), else: nil)
          )}

  defp normalize_adapter_result(
         _operation,
         {:error, category, message, %AI.Usage{} = usage, failure_code},
         credentials
       )
       when category in @adapter_failures and is_binary(message) and is_binary(failure_code) and
              byte_size(failure_code) <= 80,
       do:
         {:error,
          AI.Error.exception(
            category: category,
            message: Redactor.message(message, credentials),
            usage: usage,
            dispatched?: true,
            failure_code: failure_code
          )}

  defp normalize_adapter_result(_operation, {:error, error}, credentials) do
    if AI.Error.context_failure?(error) and match?(%AI.Error{}, AI.Error.find(error)),
      do: {:error, Redactor.value(error, credentials)},
      else: invalid_output()
  end

  defp normalize_adapter_result(_operation, _result, _credentials), do: invalid_output()

  defp invalid_output,
    do:
      {:error,
       AI.Error.exception(
         category: :invalid_output,
         message: "AI output is invalid",
         dispatched?: true
       )}

  defp ensure_not_cancelled(invocation) do
    callback = Map.get(invocation, :before_send?, Map.get(invocation, :cancelled?))

    if is_function(callback, 0) and callback.(),
      do: {:error, ai_error(:cancelled, "AI decision was cancelled", false)},
      else: :ok
  rescue
    error -> callback_failure(error)
  catch
    kind, reason -> callback_failure(ErlangError.exception(original: {kind, reason}))
  end

  defp callback_failure(cause),
    do:
      {:error,
       Ash.Error.to_error_class([
         cause,
         ai_error(:failed, "AI invocation context check failed", false)
       ])}

  defp ai_error(category, message, dispatched? \\ nil),
    do: AI.Error.exception(category: category, message: message, dispatched?: dispatched?)
end
