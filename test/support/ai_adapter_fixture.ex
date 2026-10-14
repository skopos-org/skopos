defmodule Skopos.AIAdapterFixture do
  @behaviour Skopos.Providers.Adapter
  @behaviour Skopos.Providers.AI

  @impl Skopos.Providers.Adapter
  def type, do: "fixture-ai"

  @impl Skopos.Providers.Adapter
  def kind, do: :ai

  @impl Skopos.Providers.Adapter
  def build(%{"model" => model}, %{"api_key" => api_key})
      when is_binary(model) and is_binary(api_key),
      do: {:ok, %{model: model, api_key: api_key}}

  def build(_configuration, _credentials), do: {:error, :invalid_configuration}

  @impl Skopos.Providers.Adapter
  def check(_state, _input), do: :ok

  @impl Skopos.Providers.AI
  def resolve(state, request, invocation) do
    send(invocation.test_pid, {:resolve, state, request})
    invocation.respond.(request)
  end

  @impl Skopos.Providers.AI
  def review(state, request, invocation) do
    send(invocation.test_pid, {:review, state, request})
    invocation.respond.(request)
  end

  @impl Skopos.Providers.AI
  def review_recovery(state, request, invocation) do
    send(invocation.test_pid, {:review_recovery, state, request})
    invocation.respond.(request)
  end
end
