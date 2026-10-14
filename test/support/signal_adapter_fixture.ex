defmodule Skopos.SignalAdapterFixture do
  @behaviour Skopos.Providers.Adapter
  @behaviour Skopos.Providers.Signal

  @impl Skopos.Providers.Adapter
  def type, do: "fixture-signal"

  @impl Skopos.Providers.Adapter
  def kind, do: :signal

  @impl Skopos.Providers.Adapter
  def build(%{"source" => source}, %{"secret" => secret})
      when is_binary(source) and is_binary(secret),
      do: {:ok, %{source: source, secret: secret}}

  def build(_configuration, _credentials), do: {:error, :invalid_configuration}

  @impl Skopos.Providers.Adapter
  def check(_state, _input), do: :ok

  @impl Skopos.Providers.Signal
  def authenticate(state, envelope, invocation) do
    notify(invocation, {:authenticate, state, envelope})
    invocation.authenticate.(state, envelope)
  end

  @impl Skopos.Providers.Signal
  def normalize(state, envelope, receipt, invocation) do
    notify(invocation, {:normalize, receipt})
    invocation.normalize.(state, envelope, receipt)
  end

  defp notify(%{test_pid: pid}, message), do: send(pid, message)
  defp notify(_invocation, _message), do: :ok
end
