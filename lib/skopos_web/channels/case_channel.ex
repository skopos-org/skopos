defmodule SkoposWeb.CaseChannel do
  use SkoposWeb, :channel

  alias AshAuthentication.Plug.Helpers
  alias Skopos.Cases
  alias Skopos.Cases.Case.Realtime

  @max_token_bytes 16_384

  @impl true
  def join("case:" <> case_id, %{"token" => token}, socket)
      when is_binary(token) and byte_size(token) in 1..@max_token_bytes do
    with {:ok, user} <- authenticate(token),
         {:ok, _incident} <- Cases.get_case(case_id, actor: user),
         :ok <- Realtime.subscribe(case_id) do
      {:ok, assign(socket, :case_id, case_id)}
    else
      _error -> {:error, %{reason: "unavailable"}}
    end
  end

  def join("case:" <> _case_id, _payload, _socket),
    do: {:error, %{reason: "unavailable"}}

  @impl true
  def handle_info({:case_changed, case_id}, %{assigns: %{case_id: case_id}} = socket) do
    push(socket, "changed", %{})
    {:noreply, socket}
  end

  defp authenticate(token) do
    conn =
      %Plug.Conn{req_headers: [{"authorization", "Bearer " <> token}]}
      |> Helpers.retrieve_from_bearer(:skopos)

    case conn.assigns do
      %{current_user: user} when not is_nil(user) -> {:ok, user}
      _assigns -> {:error, :unauthenticated}
    end
  end
end
