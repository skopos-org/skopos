defmodule Skopos.Transports.IPMI do
  @moduledoc false

  alias Skopos.Providers.Target

  use Rustler, otp_app: :skopos, crate: :ipmi_nif

  def send_command(_address, _session, _timeout_ms, _request, _token),
    do: :erlang.nif_error(:nif_not_loaded)

  def exchange_command(address, session, timeout, request, invocation) do
    exchange(invocation, fn cancellation ->
      send_command(address, session, timeout, request, cancellation)
    end)
  end

  def exchange_console(address, session, timeout, request, invocation) do
    case exchange(invocation, fn cancellation ->
           sol_exchange(address, session, timeout, request, cancellation)
         end) do
      {:ok, result} ->
        {status, reason} =
          case result.status do
            0 -> {:applied, nil}
            5 -> {:failed, "BMC rejected SOL activation"}
            _ -> {:unknown, "SOL exchange ended without a complete receipt"}
          end

        {:ok,
         %{result | status: status}
         |> Map.put(:reason, reason)
         |> Map.update!(:activation_completion, &if(&1 < 0, do: nil, else: &1))
         |> Map.update!(:deactivation_completion, &if(&1 < 0, do: nil, else: &1))}

      {:error, "outcome_unknown"} ->
        {:ok, %{status: :unknown, output: [], reason: "SOL exchange interrupted"}}

      result ->
        result
    end
  end

  defp exchange(invocation, native_call) do
    cancellation = cancellation_token()

    task =
      Task.async(fn ->
        callback =
          Map.get(invocation, :before_send?, Map.get(invocation, :cancelled?, fn -> false end))

        case stop_check(callback) do
          {:ok, false} ->
            native_call.(cancellation)

          {:ok, true} ->
            {:error,
             Target.BeforeSendError.exception(
               cause:
                 Target.Error.exception(
                   category: :cancelled,
                   message: "IPMI request was cancelled"
                 )
             )}

          {:error, cause} ->
            {:error, Target.BeforeSendError.exception(cause: cause)}
        end
      end)

    await_exchange(task, cancellation, Map.get(invocation, :cancelled?, fn -> false end))
  end

  defp await_exchange(task, cancellation, cancelled?) do
    case Task.yield(task, 0) do
      {:ok, result} ->
        result

      {:exit, _} ->
        {:error, "outcome_unknown"}

      nil ->
        case stop_check(cancelled?) do
          {:ok, false} ->
            case Task.yield(task, 20) do
              nil -> await_exchange(task, cancellation, cancelled?)
              {:ok, result} -> result
              {:exit, _} -> {:error, "outcome_unknown"}
            end

          {:ok, true} ->
            cancel(cancellation)
            await_stopped(task, nil)

          {:error, cause} ->
            case Task.yield(task, 0) do
              {:ok, result} ->
                result

              {:exit, _} ->
                {:error, Skopos.Providers.Target.Error.context_failure(cause)}

              nil ->
                cancel(cancellation)
                await_stopped(task, cause)
            end
        end
    end
  end

  defp stop_check(callback) do
    {:ok, callback.() not in [false, nil]}
  rescue
    cause -> {:error, cause}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  defp await_stopped(task, cause) do
    case Task.yield(task, 20) do
      nil ->
        await_stopped(task, cause)

      {:ok, result} when is_nil(cause) ->
        result

      {:ok, {:error, "cancelled"}} ->
        {:error, Skopos.Providers.Target.BeforeSendError.exception(cause: cause)}

      {:ok, {:ok, _receipt} = result} ->
        result

      _ when is_nil(cause) ->
        {:error, "outcome_unknown"}

      _ ->
        {:error, Skopos.Providers.Target.Error.context_failure(cause)}
    end
  end

  def cancellation_token, do: :erlang.nif_error(:nif_not_loaded)
  def cancel(_token), do: :erlang.nif_error(:nif_not_loaded)

  def sol_exchange(_address, _session, _timeout_ms, _request, _token),
    do: :erlang.nif_error(:nif_not_loaded)
end
