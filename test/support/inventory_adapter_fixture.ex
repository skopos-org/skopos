defmodule Skopos.InventoryAdapterFixture do
  @behaviour Skopos.Providers.Adapter
  @behaviour Skopos.Providers.Inventory

  @impl Skopos.Providers.Adapter
  def type, do: "fixture-inventory"

  @impl Skopos.Providers.Adapter
  def kind, do: :inventory

  @impl Skopos.Providers.Adapter
  def build(%{"source" => source}, %{"token" => token})
      when is_binary(source) and is_binary(token),
      do: {:ok, %{source: source, token: token}}

  def build(_configuration, _credentials), do: {:error, :invalid_configuration}

  @impl Skopos.Providers.Adapter
  def check(%{source: "reachable"}, %{"fail" => true}),
    do: {:error, :unreachable, "fixture unreachable"}

  def check(%{source: "echo", token: token}, _input),
    do: {:error, :authentication, "credential #{token} was rejected"}

  def check(%{source: "invalid_response"}, _input), do: :invalid

  def check(%{source: category}, _input)
      when category in ["authentication", "unreachable", "capability"],
      do: {:error, String.to_existing_atom(category), "fixture #{category}"}

  def check(_state, _input), do: :ok

  @impl Skopos.Providers.Inventory
  def fetch_page(state, request, cursor, %{test_pid: pid, respond: respond}) do
    send(pid, {:page, state, request, cursor})
    respond.(cursor)
  end

  def fetch_page(_state, _request, nil, _invocation) do
    {:ok, %Skopos.Providers.Inventory.Page{records: [], source_version: "fixture-v1"}}
  end
end
