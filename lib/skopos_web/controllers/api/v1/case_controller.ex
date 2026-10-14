defmodule SkoposWeb.API.V1.CaseController do
  use SkoposWeb, :api_controller

  action_fallback SkoposWeb.API.FallbackController

  alias Skopos.Cases
  alias SkoposWeb.API.{Pagination, Response, Schemas}
  alias SkoposWeb.API.V1.{WorkflowJSON, WorkflowSchemas}

  @list_errors Schemas.errors([
                 :unauthorized,
                 :forbidden,
                 :unprocessable_entity,
                 :internal_server_error
               ])
  @show_errors Schemas.errors([
                 :unauthorized,
                 :forbidden,
                 :not_found,
                 :unprocessable_entity,
                 :internal_server_error
               ])
  @write_errors Schemas.errors([
                  :bad_request,
                  :unauthorized,
                  :forbidden,
                  :not_found,
                  :conflict,
                  :unprocessable_entity,
                  :internal_server_error
                ])

  tags ["Cases"]

  operation :index,
    operation_id: "listCases",
    summary: "List Cases",
    parameters: WorkflowSchemas.case_page_parameters(),
    responses:
      [ok: {"Case page", "application/json", WorkflowSchemas.ref("CasePage")}] ++ @list_errors

  operation :summaries,
    operation_id: "listCaseSummaries",
    summary: "List Case summaries",
    parameters: WorkflowSchemas.case_page_parameters() ++ [Schemas.reference_ids_parameter()],
    responses:
      [ok: {"Case summary page", "application/json", WorkflowSchemas.ref("CaseSummaryPage")}] ++
        @list_errors

  operation :show,
    operation_id: "getCase",
    summary: "Reconnect to a Case",
    parameters: Schemas.id_parameter(),
    responses:
      [ok: {"Case snapshot", "application/json", WorkflowSchemas.ref("CaseSnapshotResponse")}] ++
        @show_errors

  operation :create,
    operation_id: "createCase",
    summary: "Open a Case",
    request_body:
      {"Case", "application/json", WorkflowSchemas.ref("CreateCaseRequest"), required: true},
    responses:
      [created: {"Case opened", "application/json", WorkflowSchemas.ref("CaseResponse")}] ++
        @write_errors

  operation :timeline,
    operation_id: "listCaseTimeline",
    summary: "List Case timeline events",
    parameters: Schemas.id_parameter() ++ Schemas.pagination_parameters(),
    responses:
      [ok: {"Case event page", "application/json", WorkflowSchemas.ref("CaseEventPage")}] ++
        @show_errors

  operation :turns,
    operation_id: "listCaseResolverTurns",
    summary: "List Case Resolver turn summaries",
    parameters: Schemas.id_parameter() ++ Schemas.pagination_parameters(),
    responses:
      [
        ok:
          {"Resolver-turn summary page", "application/json",
           WorkflowSchemas.ref("ResolverTurnPage")}
      ] ++
        @show_errors

  operation :proposals,
    operation_id: "listCaseProposals",
    summary: "List Case proposal summaries",
    parameters: Schemas.id_parameter() ++ Schemas.pagination_parameters(),
    responses:
      [ok: {"Proposal summary page", "application/json", WorkflowSchemas.ref("ProposalPage")}] ++
        @show_errors

  operation :condition_history,
    operation_id: "listCaseConditionHistory",
    summary: "List Case Condition membership history",
    parameters: Schemas.id_parameter() ++ Schemas.pagination_parameters(),
    responses:
      [
        ok:
          {"Condition membership page", "application/json",
           WorkflowSchemas.ref("CaseConditionMembershipPage")}
      ] ++ @show_errors

  operation :show_turn,
    operation_id: "getResolverTurn",
    summary: "Get a complete Resolver turn",
    parameters: Schemas.id_parameter(),
    responses:
      [ok: {"Resolver turn", "application/json", WorkflowSchemas.ref("ResolverTurnResponse")}] ++
        @show_errors

  operation :evidence,
    operation_id: "listCaseEvidence",
    summary: "List Case evidence",
    parameters: Schemas.id_parameter() ++ Schemas.pagination_parameters(),
    responses:
      [ok: {"Evidence page", "application/json", WorkflowSchemas.ref("EvidencePage")}] ++
        @show_errors

  operation :operations,
    operation_id: "listCaseOperations",
    summary: "List Case operation summaries",
    parameters: Schemas.id_parameter() ++ Schemas.pagination_parameters(),
    responses:
      [ok: {"Operation page", "application/json", WorkflowSchemas.ref("OperationPage")}] ++
        @show_errors

  operation :verifications,
    operation_id: "listCaseVerifications",
    summary: "List Case verification summaries",
    parameters: Schemas.id_parameter() ++ Schemas.pagination_parameters(),
    responses:
      [
        ok:
          {"Verification page", "application/json",
           WorkflowSchemas.ref("VerificationAttemptPage")}
      ] ++
        @show_errors

  operation :show_evidence,
    operation_id: "getEvidence",
    summary: "Get complete Case evidence",
    parameters: Schemas.id_parameter(),
    responses:
      [ok: {"Evidence", "application/json", WorkflowSchemas.ref("EvidenceResponse")}] ++
        @show_errors

  operation :ai_invocations,
    operation_id: "listCaseAIInvocations",
    summary: "List Case AI invocation accounting",
    parameters: Schemas.id_parameter() ++ Schemas.pagination_parameters(),
    responses:
      [ok: {"AI invocation page", "application/json", WorkflowSchemas.ref("AIInvocationPage")}] ++
        @show_errors

  operation :approvals,
    operation_id: "listCaseApprovals",
    summary: "List Case approvals",
    parameters: Schemas.id_parameter() ++ Schemas.pagination_parameters(),
    responses:
      [ok: {"Approval page", "application/json", WorkflowSchemas.ref("ApprovalPage")}] ++
        @show_errors

  operation :review_decisions,
    operation_id: "listCaseReviewDecisions",
    summary: "List Case reviewer decisions",
    parameters: Schemas.id_parameter() ++ Schemas.pagination_parameters(),
    responses:
      [
        ok:
          {"Review-decision page", "application/json", WorkflowSchemas.ref("ReviewDecisionPage")}
      ] ++ @show_errors

  operation :claim,
    operation_id: "claimCase",
    summary: "Claim a Case",
    parameters: Schemas.id_parameter(),
    request_body:
      {"Case revision", "application/json", WorkflowSchemas.ref("CaseRevisionRequest"),
       required: true},
    responses:
      [ok: {"Case claimed", "application/json", WorkflowSchemas.ref("CaseResponse")}] ++
        @write_errors

  operation :split,
    operation_id: "splitCaseConditions",
    summary: "Move selected Conditions into a separate Case",
    parameters: Schemas.id_parameter(),
    request_body:
      {"Case split", "application/json", WorkflowSchemas.ref("SplitCaseRequest"), required: true},
    responses:
      [ok: {"Separate Case", "application/json", WorkflowSchemas.ref("CaseResponse")}] ++
        @write_errors

  operation :handoff,
    operation_id: "handoffCase",
    summary: "Handoff a Case",
    parameters: Schemas.id_parameter(),
    request_body:
      {"Case handoff", "application/json", WorkflowSchemas.ref("HandoffCaseRequest"),
       required: true},
    responses:
      [ok: {"Case handed off", "application/json", WorkflowSchemas.ref("CaseResponse")}] ++
        @write_errors

  operation :cancel,
    operation_id: "cancelCase",
    summary: "Request Case cancellation",
    parameters: Schemas.id_parameter(),
    request_body:
      {"Case revision", "application/json", WorkflowSchemas.ref("CaseRevisionRequest"),
       required: true},
    responses:
      [
        ok:
          {"Case cancellation requested", "application/json", WorkflowSchemas.ref("CaseResponse")}
      ] ++ @write_errors

  operation :resume,
    operation_id: "resumeCase",
    summary: "Resume a Case with new limits",
    parameters: Schemas.id_parameter(),
    request_body:
      {"Case resume", "application/json", WorkflowSchemas.ref("ResumeCaseRequest"),
       required: true},
    responses:
      [
        ok:
          {"Resolution run resumed", "application/json",
           WorkflowSchemas.ref("ResolutionRunResponse")}
      ] ++ @write_errors

  def index(conn, params) do
    with {:ok, page} <- Pagination.parse(params),
         {:ok, cases} <-
           Cases.page_cases(
             params["query"],
             params["status"],
             params["sort"] || "updated_desc",
             page: page,
             actor: conn.assigns.current_user
           ) do
      Response.page(conn, cases, &WorkflowJSON.case_record/1)
    end
  end

  def summaries(conn, params) do
    input = OpenApiSpex.params(conn) |> Map.take([:ids, :query, :status, :sort])

    with {:ok, page} <- Pagination.parse(params),
         {:ok, cases} <-
           Cases.page_case_summaries(input, page: page, actor: conn.assigns.current_user) do
      Response.page(conn, cases, &WorkflowJSON.case_summary/1)
    end
  end

  def show(conn, %{"id" => id}) do
    with {:ok, snapshot} <- Cases.case_reconnect_snapshot(id, actor: conn.assigns.current_user) do
      Response.data(conn, WorkflowJSON.snapshot(snapshot))
    end
  end

  def create(conn, %{"case" => input}) do
    with true <- input["trigger_kind"] == "manual" || {:error, :bad_request},
         {:ok, incident} <-
           Cases.open_case(
             input["trigger_kind"],
             input["source"],
             input["source_ref"],
             input["title"],
             input["severity"],
             input["initial_context"] || %{},
             input["initial_target_id"],
             nil,
             actor: conn.assigns.current_user
           ) do
      Response.data(conn, WorkflowJSON.case_record(incident), :created)
    end
  end

  def create(_conn, _params), do: {:error, :bad_request}

  def timeline(conn, %{"id" => id} = params) do
    with {:ok, page} <- Pagination.parse(params),
         {:ok, events} <-
           Cases.page_case_events(id, page: page, actor: conn.assigns.current_user) do
      Response.page(conn, events, &WorkflowJSON.event/1)
    end
  end

  def turns(conn, %{"id" => id} = params) do
    page_case_records(conn, params, &Cases.page_case_turns(id, &1), &WorkflowJSON.turn_summary/1)
  end

  def show_turn(conn, %{"id" => id}) do
    with {:ok, turn} <- Cases.get_turn(id, actor: conn.assigns.current_user) do
      Response.data(conn, WorkflowJSON.turn(turn))
    end
  end

  def evidence(conn, %{"id" => id} = params) do
    page_case_records(
      conn,
      params,
      &Cases.page_case_evidence(id, &1),
      &WorkflowJSON.evidence_summary/1
    )
  end

  def show_evidence(conn, %{"id" => id}) do
    with {:ok, evidence} <- Cases.get_evidence(id, actor: conn.assigns.current_user) do
      Response.data(conn, WorkflowJSON.evidence(evidence))
    end
  end

  def proposals(conn, %{"id" => id} = params) do
    page_case_records(conn, params, &Cases.page_case_proposals(id, &1), fn record ->
      Map.take(record, Skopos.Cases.Proposal.summary_fields())
    end)
  end

  def condition_history(conn, %{"id" => id} = params) do
    page_case_records(
      conn,
      params,
      &Cases.page_case_condition_history(id, &1),
      &WorkflowJSON.condition_membership/1
    )
  end

  def operations(conn, %{"id" => id} = params) do
    page_case_records(conn, params, &Cases.page_case_operations(id, &1), fn record ->
      Map.take(record, Skopos.Cases.Operation.summary_fields())
    end)
  end

  def verifications(conn, %{"id" => id} = params) do
    page_case_records(conn, params, &Cases.page_case_verifications(id, &1), fn record ->
      Map.take(record, Skopos.Cases.VerificationAttempt.summary_fields())
    end)
  end

  def ai_invocations(conn, %{"id" => id} = params) do
    page_case_records(
      conn,
      params,
      &Cases.page_case_ai_invocations(id, &1),
      &WorkflowJSON.ai_invocation/1
    )
  end

  def approvals(conn, %{"id" => id} = params) do
    page_case_records(conn, params, &Cases.page_case_approvals(id, &1), &WorkflowJSON.approval/1)
  end

  def review_decisions(conn, %{"id" => id} = params) do
    page_case_records(
      conn,
      params,
      &Cases.page_case_review_decisions(id, &1),
      &WorkflowJSON.review_decision/1
    )
  end

  def claim(conn, %{"id" => id, "case" => %{"expected_revision" => revision}}) do
    with {:ok, incident} <- Cases.claim_case(id, revision, actor: conn.assigns.current_user) do
      Response.data(conn, WorkflowJSON.case_record(incident))
    end
  end

  def claim(_conn, _params), do: {:error, :bad_request}

  def split(
        conn,
        %{
          "id" => id,
          "case" => %{
            "expected_revision" => revision,
            "condition_ids" => ids,
            "expected_conditions" => expected,
            "reason" => reason
          }
        }
      ) do
    with {:ok, child} <-
           Cases.split_case_conditions(id, revision, ids, expected, reason,
             actor: conn.assigns.current_user
           ) do
      Response.data(conn, WorkflowJSON.case_record(child))
    end
  end

  def split(_conn, _params), do: {:error, :bad_request}

  def handoff(
        conn,
        %{"id" => id, "case" => %{"expected_revision" => revision, "owner_id" => owner_id}}
      ) do
    with {:ok, incident} <-
           Cases.handoff_case(id, revision, owner_id, actor: conn.assigns.current_user) do
      Response.data(conn, WorkflowJSON.case_record(incident))
    end
  end

  def handoff(_conn, _params), do: {:error, :bad_request}

  def cancel(conn, %{"id" => id, "case" => %{"expected_revision" => revision}}) do
    with {:ok, incident} <-
           Cases.request_case_cancellation(id, revision, actor: conn.assigns.current_user) do
      Response.data(conn, WorkflowJSON.case_record(incident))
    end
  end

  def cancel(_conn, _params), do: {:error, :bad_request}

  def resume(
        conn,
        %{
          "id" => id,
          "case" =>
            %{
              "expected_case_revision" => case_revision,
              "resolution_run_id" => run_id,
              "expected_run_revision" => run_revision
            } = input
        }
      ) do
    with {:ok, run} <-
           Cases.resume_case(
             id,
             case_revision,
             run_id,
             run_revision,
             input["authority_mode"],
             input["max_elapsed_seconds"],
             input["max_resolver_turns"],
             input["max_target_requests"],
             input["max_effects"],
             input["max_related_targets"],
             input["max_ai_usage_units"],
             input["max_no_progress_turns"],
             input["reason"],
             actor: conn.assigns.current_user
           ) do
      Response.data(conn, WorkflowJSON.resolution_run(run))
    end
  end

  def resume(_conn, _params), do: {:error, :bad_request}

  defp page_case_records(conn, params, read, serializer) do
    with {:ok, page} <- Pagination.parse(params),
         {:ok, records} <- read.(page: page, actor: conn.assigns.current_user) do
      Response.page(conn, records, serializer)
    end
  end
end
