defmodule SkoposWeb.API.V1.ProposalController do
  use SkoposWeb, :api_controller

  action_fallback SkoposWeb.API.FallbackController

  alias Skopos.Cases
  alias SkoposWeb.API.{Response, Schemas}
  alias SkoposWeb.API.V1.{WorkflowJSON, WorkflowSchemas}

  tags ["Proposals"]

  operation :show,
    operation_id: "getProposal",
    summary: "Get a Proposal",
    parameters: Schemas.id_parameter(),
    responses:
      [ok: {"Proposal", "application/json", WorkflowSchemas.ref("ProposalResponse")}] ++
        Schemas.errors([
          :unauthorized,
          :forbidden,
          :not_found,
          :unprocessable_entity,
          :internal_server_error
        ])

  operation :decide,
    operation_id: "decideProposal",
    summary: "Approve or reject a Proposal",
    parameters: Schemas.id_parameter(),
    request_body:
      {"Proposal decision", "application/json", WorkflowSchemas.ref("DecideProposalRequest"),
       required: true},
    responses:
      [ok: {"Proposal decided", "application/json", WorkflowSchemas.ref("ProposalResponse")}] ++
        Schemas.errors([
          :bad_request,
          :unauthorized,
          :forbidden,
          :not_found,
          :conflict,
          :unprocessable_entity,
          :internal_server_error
        ])

  def show(conn, %{"id" => id}) do
    with {:ok, proposal} <- Cases.get_proposal(id, actor: conn.assigns.current_user) do
      Response.data(conn, WorkflowJSON.proposal(proposal))
    end
  end

  def decide(
        conn,
        %{
          "id" => id,
          "proposal" => %{
            "expected_revision" => revision,
            "proposal_digest" => digest,
            "decision" => decision,
            "reason" => reason
          }
        }
      ) do
    case Cases.decide_proposal(id, revision, digest, decision, reason,
           actor: conn.assigns.current_user
         ) do
      {:ok, proposal} ->
        Response.data(conn, WorkflowJSON.proposal(proposal))

      {:error, error} ->
        if expired_proposal?(error) do
          Response.error(
            conn,
            :conflict,
            "proposal_expired",
            "Proposal approval window has expired"
          )
        else
          {:error, error}
        end
    end
  end

  def decide(_conn, _params), do: {:error, :bad_request}

  defp expired_proposal?(%Ash.Error.Changes.InvalidAttribute{
         field: :expires_at,
         message: "has expired"
       }),
       do: true

  defp expired_proposal?(%{errors: errors}) when is_list(errors),
    do: Enum.any?(errors, &expired_proposal?/1)

  defp expired_proposal?(_error), do: false
end
