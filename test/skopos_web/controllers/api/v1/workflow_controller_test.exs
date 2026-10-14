defmodule SkoposWeb.API.V1.WorkflowControllerTest do
  use SkoposWeb.ConnCase, async: false

  import OpenApiSpex.TestAssertions
  import Ecto.Query
  import ExUnit.CaptureLog
  import ExUnit.CaptureIO

  alias Skopos.{Accounts, Cases, Providers, Reports, Signals, Targets}
  alias Skopos.Cases.Case
  alias Skopos.Cases.Case.Realtime
  alias Skopos.Cases.Proposal.ReviewDelivery
  alias Skopos.Cases.CaseDispatch.Worker, as: CaseDispatchWorker
  alias Skopos.Providers.{AI, Signal}

  @password "correct horse battery staple"

  setup do
    admin =
      Accounts.bootstrap!("workflow-api-admin@example.com", @password, @password,
        authorize?: true
      )

    operator =
      Accounts.create_user!("workflow-api-operator@example.com", @password, :operator,
        actor: admin
      )

    next_operator =
      Accounts.create_user!("workflow-api-next@example.com", @password, :operator, actor: admin)

    viewer =
      Accounts.create_user!("workflow-api-viewer@example.com", @password, :viewer, actor: admin)

    %{
      admin: admin,
      operator: operator,
      next_operator: next_operator,
      admin_token: token!(admin.email),
      operator_token: token!(operator.email),
      viewer_token: token!(viewer.email)
    }
  end

  test "public manual Case creation durably dispatches one investigation", context do
    body = %{
      "case" => %{
        "trigger_kind" => "manual",
        "source" => "api",
        "source_ref" => "manual-entry-once",
        "title" => "Investigate guest availability",
        "severity" => "warning",
        "initial_context" => %{
          "observed_problem" => "Guest unavailable",
          "desired_outcome" => "Guest responds to the health check"
        }
      }
    }

    first = post_json("/api/v1/cases", body, context.operator_token) |> json_response(201)
    second = post_json("/api/v1/cases", body, context.operator_token) |> json_response(201)
    incident_id = first["data"]["id"]
    assert second["data"]["id"] == incident_id

    assert first["data"]["case_symptom"]["desired_outcome"] ==
             "Guest responds to the health check"

    changed =
      put_in(body, ["case", "initial_context", "desired_outcome"], "Guest remains unavailable")
      |> then(&post_json("/api/v1/cases", &1, context.operator_token))

    assert %{"error" => %{"code" => "validation_failed"}} = json_response(changed, 422)

    assert Cases.case_dispatch!(incident_id, authorize?: false).state == :collecting

    assert [_job] =
             Skopos.Repo.all(Oban.Job)
             |> Enum.filter(
               &(&1.worker == "Skopos.Cases.CaseDispatch.Worker" and
                   &1.args["case_id"] == incident_id)
             )

    assert :ok = CaseDispatchWorker.perform(%Oban.Job{args: %{"case_id" => incident_id}})
    assert :ok = CaseDispatchWorker.perform(%Oban.Job{args: %{"case_id" => incident_id}})

    run = Cases.active_resolution_run!(incident_id, authorize?: false)
    assert run.turn_count == 1
    assert Cases.case_dispatch!(incident_id, authorize?: false).state == :sent

    assert [%{"status" => "started", "ordinal" => 1}] =
             get_data!("/api/v1/cases/#{incident_id}/turns", context.viewer_token)
             |> Enum.map(&Map.take(&1, ["status", "ordinal"]))
  end

  test "manual Case submission preserves a Target selected through the summary API", context do
    created =
      post_json(
        "/api/v1/targets",
        %{
          "target" => %{
            "name" => "Summary-selected host",
            "kind" => "host",
            "type_id" => "custom-os",
            "facts" => %{}
          }
        },
        context.admin_token
      )
      |> json_response(201)

    target_id = created["data"]["id"]

    summary =
      get_json("/api/v1/targets/summaries?ids=#{target_id}&limit=1", context.operator_token)

    assert_operation_response(summary)
    assert [%{"id" => ^target_id, "active" => true}] = json_response(summary, 200)["data"]

    body = %{
      "case" => %{
        "trigger_kind" => "manual",
        "source" => "web",
        "source_ref" => "summary-selected-case",
        "title" => "Investigate selected host",
        "severity" => "warning",
        "initial_target_id" => target_id,
        "initial_context" => %{"desired_outcome" => "Restore host availability"}
      }
    }

    response = post_json("/api/v1/cases", body, context.operator_token)
    assert_operation_response(response)

    assert %{
             "data" => %{
               "id" => id,
               "initial_target_id" => ^target_id,
               "selected_target_id" => ^target_id
             }
           } = json_response(response, 201)

    snapshot = get_data!("/api/v1/cases/#{id}", context.viewer_token)
    assert snapshot["case"]["initial_target_id"] == target_id
    assert snapshot["case"]["selected_target_id"] == target_id
    assert snapshot["case"]["case_symptom"]["desired_outcome"] == "Restore host availability"
  end

  test "public Case creation publishes its changes only after commit", context do
    body = %{
      "case" => %{
        "trigger_kind" => "manual",
        "source" => "api",
        "source_ref" => "notification-on-commit",
        "title" => "Check notification timing",
        "severity" => "warning",
        "initial_context" => %{"desired_outcome" => "Target responds as expected"}
      }
    }

    log =
      capture_log(fn ->
        assert {:ok, case_id} =
                 Ash.transact(Case, fn ->
                   response = post_json("/api/v1/cases", body, context.operator_token)
                   %{"data" => %{"id" => case_id}} = json_response(response, 201)
                   :ok = Realtime.subscribe(case_id)
                   refute_receive {:case_changed, ^case_id}, 20
                   case_id
                 end)

        for _ <- 1..3, do: assert_receive({:case_changed, ^case_id})
        refute_receive {:case_changed, ^case_id}, 100
      end)

    refute log =~ "Missed"
  end

  @tag ai_unsent_retry: true
  test "public Case history exposes a retrying unsent AI request without reserved charges",
       context do
    proposal_setup!(context)
    incident = open_case!(context.operator_token, "unsent-ai-usage")
    assert :ok = CaseDispatchWorker.perform(%Oban.Job{args: %{"case_id" => incident["id"]}})
    [turn] = Cases.list_turns!(actor: context.operator)

    assert {:error, _error} =
             Skopos.Cases.Turn.ResolverDelivery.run(turn.id,
               ai_invocation: %{
                 test_pid: self(),
                 cancelled?: fn ->
                   {:error, error} =
                     Skopos.Repo.query("SELECT invocation_context_unavailable", [],
                       mode: :savepoint
                     )

                   raise error
                 end,
                 respond: fn _request -> flunk("unsent request reached the AI adapter") end
               }
             )

    refute_receive {:resolve, _, _}
    usage = get_data!("/api/v1/cases/#{incident["id"]}", context.viewer_token)["ai_usage"]
    assert usage["budget_charged_units"] == 0
    assert usage["not_dispatched_invocations"] == 1
    assert usage["unknown_invocations"] == 0
    assert usage["unknown_reserved_units"] == 0
    assert usage["pending_reserved_units"] == 0

    assert [
             %{
               "status" => "queued",
               "usage_status" => "not_dispatched",
               "dispatch_confirmed" => false,
               "dispatch_started_at" => nil,
               "input_tokens" => nil,
               "output_tokens" => nil
             }
           ] = get_data!("/api/v1/cases/#{incident["id"]}/ai-invocations", context.viewer_token)
  end

  test "public Case accounting exposes missing post-dispatch usage instead of zero tokens",
       context do
    proposal_setup!(context)
    incident = open_case!(context.operator_token, "unknown-ai-usage")
    assert :ok = CaseDispatchWorker.perform(%Oban.Job{args: %{"case_id" => incident["id"]}})
    [turn] = Cases.list_turns!(actor: context.operator)

    assert :ok =
             Skopos.Cases.Turn.ResolverDelivery.run(turn.id,
               ai_invocation: %{
                 test_pid: self(),
                 respond: fn _ -> {:error, :cancelled, "native response was lost"} end
               }
             )

    assert_receive {:resolve, _state, _request}
    snapshot = get_data!("/api/v1/cases/#{incident["id"]}", context.viewer_token)
    usage = snapshot["ai_usage"]

    assert [
             %{
               "usage_status" => "unknown",
               "input_tokens" => nil,
               "output_tokens" => nil,
               "reserved_units" => allowance
             }
           ] = get_data!("/api/v1/cases/#{incident["id"]}/ai-invocations", context.viewer_token)

    assert allowance > 65_536
    assert allowance < 100_000
    assert [%{"counters" => %{"ai_usage_units" => ^allowance}}] = snapshot["resolution_runs"]
    assert usage["reported_total_tokens"] == 0
    assert usage["unknown_invocations"] == 1
    assert usage["budget_charged_units"] == allowance
    assert usage["unknown_reserved_units"] == allowance
    assert usage["complete"] == false

    assert get_data!("/api/v1/cases/#{incident["id"]}", context.viewer_token)["ai_usage"] == usage
    refute Jason.encode!(usage) =~ "resolver-secret"
    refute Jason.encode!(usage) =~ "request_digest"
  end

  for {name, input, output} <- [{"reported-zero", 0, 0}, {"metered-failure", 17, 9}] do
    test "public Case accounting preserves #{name} separately from a reservation", context do
      proposal_setup!(context)
      incident = open_case!(context.operator_token, unquote(name))
      assert :ok = CaseDispatchWorker.perform(%Oban.Job{args: %{"case_id" => incident["id"]}})
      [turn] = Cases.list_turns!(actor: context.operator)

      assert :ok =
               Skopos.Cases.Turn.ResolverDelivery.run(turn.id,
                 ai_invocation: %{
                   test_pid: self(),
                   respond: fn _ ->
                     {:error, :cancelled, "native response ended",
                      %AI.Usage{
                        input_tokens: unquote(input),
                        output_tokens: unquote(output)
                      }}
                   end
                 }
               )

      assert_receive {:resolve, _state, _request}
      usage = get_data!("/api/v1/cases/#{incident["id"]}", context.viewer_token)["ai_usage"]
      assert usage["reported_input_tokens"] == unquote(input)
      assert usage["reported_output_tokens"] == unquote(output)
      assert usage["reported_invocations"] == 1
      assert usage["unknown_invocations"] == 0
      assert usage["budget_charged_units"] == unquote(input + output)
      assert usage["unknown_reserved_units"] == 0
      assert usage["complete"] == true
      response = get_json("/api/v1/cases/#{incident["id"]}/ai-invocations", context.viewer_token)
      assert_operation_response(response)

      assert [
               %{
                 "usage_status" => "reported",
                 "status" => "failed",
                 "input_tokens" => unquote(input),
                 "output_tokens" => unquote(output),
                 "reasoning_tokens" => nil,
                 "cached_tokens" => nil,
                 "dispatch_confirmed" => true,
                 "reserved_units" => allowance
               }
             ] = json_response(response, 200)["data"]

      assert allowance > 65_536
      assert allowance < 100_000
    end
  end

  test "public Case accounting distinguishes cancellation before the AI adapter is called",
       context do
    proposal_setup!(context)
    incident = open_case!(context.operator_token, "predispatch-cancellation")
    assert :ok = CaseDispatchWorker.perform(%Oban.Job{args: %{"case_id" => incident["id"]}})
    [turn] = Cases.list_turns!(actor: context.operator)

    assert :ok =
             Skopos.Cases.Turn.ResolverDelivery.run(turn.id,
               ai_invocation: %{
                 cancelled?: fn -> true end,
                 test_pid: self(),
                 respond: fn _ ->
                   flunk("cancelled invocation reached the AI adapter")
                 end
               }
             )

    refute_receive {:resolve, _state, _request}
    usage = get_data!("/api/v1/cases/#{incident["id"]}", context.viewer_token)["ai_usage"]
    assert usage["not_dispatched_invocations"] == 1
    assert usage["unknown_invocations"] == 0
    assert usage["reported_invocations"] == 0
    assert usage["budget_charged_units"] == 0
    assert usage["complete"] == true

    assert [
             %{
               "usage_status" => "not_dispatched",
               "dispatch_confirmed" => false,
               "input_tokens" => nil,
               "output_tokens" => nil
             }
           ] =
             get_data!("/api/v1/cases/#{incident["id"]}/ai-invocations", context.viewer_token)
  end

  test "Case accounting covers every invocation while public details remain paginated", context do
    proposal_setup!(context)
    incident = open_case!(context.operator_token, "accounting-pages")
    assert :ok = CaseDispatchWorker.perform(%Oban.Job{args: %{"case_id" => incident["id"]}})
    [first] = Cases.list_turns!(actor: context.operator)

    assert :ok =
             Skopos.Cases.Turn.ResolverDelivery.run(first.id,
               ai_invocation: %{
                 test_pid: self(),
                 respond: fn _ ->
                   {:error, :timeout, "metered timeout",
                    %AI.Usage{input_tokens: 17, output_tokens: 9}}
                 end
               }
             )

    assert_receive {:resolve, _state, _request}
    successor = Enum.find(Cases.list_turns!(actor: context.operator), &(&1.status == :started))

    assert :ok =
             Skopos.Cases.Turn.ResolverDelivery.run(successor.id,
               ai_invocation: %{
                 test_pid: self(),
                 respond: fn _ ->
                   {:error, :cancelled, "metered cancellation",
                    %AI.Usage{input_tokens: 4, output_tokens: 2}}
                 end
               }
             )

    assert_receive {:resolve, _state, _request}
    path = "/api/v1/cases/#{incident["id"]}/ai-invocations"
    first_page = get_json(path <> "?limit=1", context.viewer_token) |> json_response(200)
    assert [%{"input_tokens" => 4, "output_tokens" => 2}] = first_page["data"]
    cursor = first_page["page"]["next"]
    assert is_binary(cursor)

    last_page =
      get_json(path <> "?limit=1&after=" <> URI.encode_www_form(cursor), context.viewer_token)
      |> json_response(200)

    assert [%{"input_tokens" => 17, "output_tokens" => 9}] = last_page["data"]
    assert last_page["page"]["next"] == nil

    assert %{
             "reported_total_tokens" => 32,
             "reported_invocations" => 2,
             "budget_charged_units" => 32,
             "complete" => true
           } =
             get_data!("/api/v1/cases/#{incident["id"]}", context.viewer_token)["ai_usage"]

    unauthenticated = build_conn() |> put_req_header("accept", "application/json") |> get(path)
    assert json_response(unauthenticated, 401)["error"]["code"] == "unauthenticated"

    for page <- [first_page, last_page] do
      encoded = Jason.encode!(page)
      refute encoded =~ "request_digest"
      refute encoded =~ "idempotency_key"
      refute encoded =~ "session_id"
      refute encoded =~ "resolver-secret"
    end
  end

  test "public manual Case creation requires an explicit desired outcome", context do
    body = %{
      "case" => %{
        "trigger_kind" => "manual",
        "source" => "api",
        "source_ref" => "missing-desired-outcome",
        "title" => "Check service",
        "severity" => "warning",
        "initial_context" => %{"observed_problem" => "Service stopped"}
      }
    }

    response = post_json("/api/v1/cases", body, context.operator_token)
    assert %{"error" => %{"code" => "bad_request"}} = json_response(response, 400)
    assert Cases.list_cases!(actor: context.admin) == []
  end

  test "direct audit Case creation is rejected before an idle Case is stored", context do
    body = %{
      "case" => %{
        "trigger_kind" => "audit",
        "source" => "api",
        "source_ref" => "unsupported-direct-audit",
        "title" => "Inspect storage health",
        "severity" => "info",
        "initial_context" => %{"desired_outcome" => "Storage health is normal"}
      }
    }

    response = post_json("/api/v1/cases", body, context.operator_token)
    assert %{"error" => %{"code" => "validation_failed"}} = json_response(response, 422)
    assert Cases.list_cases!(actor: context.admin) == []
    assert Cases.list_turns!(actor: context.admin) == []
  end

  test "manual Case and its dispatch job roll back together before a safe retry", context do
    body = %{
      "case" => %{
        "trigger_kind" => "manual",
        "source" => "api",
        "source_ref" => "rolled-back-manual-entry",
        "title" => "Investigate a rolled back request",
        "severity" => "warning",
        "initial_context" => %{"desired_outcome" => "Target responds as expected"}
      }
    }

    log =
      capture_log(fn ->
        assert {:error, _reason} =
                 Ash.transact(Case, fn ->
                   response = post_json("/api/v1/cases", body, context.operator_token)
                   assert %{"data" => %{"id" => case_id}} = json_response(response, 201)
                   :ok = Realtime.subscribe(case_id)
                   send(self(), {:rolled_back_case, case_id})
                   {:error, :simulated_persistence_failure}
                 end)

        assert_receive {:rolled_back_case, rolled_back_id}
        refute_receive {:case_changed, ^rolled_back_id}, 100
      end)

    refute log =~ "Missed"

    assert Cases.list_cases!(actor: context.admin) == []
    assert Skopos.Repo.all(Oban.Job) == []

    accepted = post_json("/api/v1/cases", body, context.operator_token)
    assert %{"data" => %{"id" => incident_id}} = json_response(accepted, 201)
    assert [_dispatch] = Cases.list_cases!(actor: context.admin)
    assert Cases.case_dispatch!(incident_id, authorize?: false).state == :collecting
  end

  test "Case queue search, filters, and sorting are applied before pagination", context do
    older = open_case!(context.operator_token, "queue-older", "warning")
    newer = open_case!(context.operator_token, "queue-newer", "critical")

    searched = get_json("/api/v1/cases?query=QUEUE-OLDER", context.viewer_token)

    assert %{"data" => [%{"id" => searched_id}], "page" => %{"next" => nil}} =
             json_response(searched, 200)

    assert searched_id == older["id"]
    assert_operation_response(searched)

    sorted = get_json("/api/v1/cases?sort=severity_desc", context.viewer_token)

    assert [%{"id" => first_id}, %{"id" => second_id}] = json_response(sorted, 200)["data"]
    assert [first_id, second_id] == [newer["id"], older["id"]]
    assert_operation_response(sorted)

    filtered = get_json("/api/v1/cases?status=resolved", context.viewer_token)
    assert %{"data" => [], "page" => %{"next" => nil}} = json_response(filtered, 200)
    assert_operation_response(filtered)

    invalid = get_json("/api/v1/cases?status=unknown", context.viewer_token)
    assert %{"error" => %{"code" => "validation_failed"}} = json_response(invalid, 422)
  end

  @tag case_summary: true
  test "Case summary identities and choices are scoped before paging without full investigation context",
       context do
    target =
      post_json(
        "/api/v1/targets",
        %{
          "target" => %{
            "name" => "Report reference host",
            "kind" => "host",
            "type_id" => "custom-os"
          }
        },
        context.admin_token
      )
      |> json_response(201)
      |> Map.fetch!("data")

    older =
      post_json(
        "/api/v1/cases",
        %{
          "case" => %{
            "trigger_kind" => "manual",
            "source" => "api",
            "source_ref" => "summary-older",
            "title" => "Older report candidate",
            "severity" => "warning",
            "initial_target_id" => target["id"],
            "initial_context" => %{
              "desired_outcome" => "Target responds as expected",
              "padding" => String.duplicate("x", 30_000)
            }
          }
        },
        context.operator_token
      )
      |> json_response(201)
      |> Map.fetch!("data")

    newer = open_case!(context.operator_token, "summary-newer", "critical")
    path = "/api/v1/cases/summaries"
    first = get_json(path <> "?limit=1&sort=updated_asc", context.viewer_token)

    assert %{"data" => [%{"id" => older_id} = item], "page" => %{"next" => cursor}} =
             json_response(first, 200)

    assert older_id == older["id"]
    assert is_binary(cursor)
    assert_operation_response(first)

    assert Enum.sort(Map.keys(item)) ==
             ~w(id title status report_language revision initial_target_id selected_target_id inserted_at updated_at)
             |> Enum.sort()

    assert item["initial_target_id"] == target["id"]
    assert item["selected_target_id"] == target["id"]
    assert byte_size(first.resp_body) < 2_000

    next =
      get_json(
        path <> "?limit=1&sort=updated_asc&after=" <> URI.encode_www_form(cursor),
        context.viewer_token
      )

    assert %{"data" => [%{"id" => newer_id}], "page" => %{"next" => nil}} =
             json_response(next, 200)

    assert newer_id == newer["id"]
    assert_operation_response(next)

    known = get_json(path <> "?ids=#{older_id}&limit=1", context.viewer_token)
    assert json_response(known, 200)["data"] == [item]
    assert_operation_response(known)

    sorted =
      get_json(
        path <> "?ids=#{older_id},#{newer_id}&query=API&status=running&sort=severity_desc&limit=1",
        context.operator_token
      )

    assert [%{"id" => ^newer_id}] = json_response(sorted, 200)["data"]
    assert_operation_response(sorted)
    missing = get_json(path <> "?ids=#{Ecto.UUID.generate()}", context.admin_token)
    assert json_response(missing, 200)["data"] == []

    cancelled =
      post_json(
        "/api/v1/cases/#{older_id}/cancel",
        %{"case" => %{"expected_revision" => 1}},
        context.operator_token
      )

    assert %{"data" => %{"revision" => 2, "status" => "cancelled"}} =
             json_response(cancelled, 200)

    changed = get_json(path <> "?ids=#{older_id}&status=cancelled", context.viewer_token)

    assert [%{"id" => ^older_id, "status" => "cancelled", "revision" => 2}] =
             json_response(changed, 200)["data"]

    assert_operation_response(changed)

    assert json_response(
             get_json(path <> "?ids=#{older_id}&status=running", context.viewer_token),
             200
           )["data"] == []

    assert json_response(get_json("/api/v1/cases?query=summary-newer", context.viewer_token), 200)[
             "data"
           ]
           |> hd()
           |> Map.has_key?("initial_context")
  end

  @tag case_summary: true
  test "remote CLI resolves a Case beyond the first choice page through the authenticated summary read",
       context do
    selected = open_case!(context.operator_token, "summary-cli-selected", "warning")
    for index <- 1..50, do: open_case!(context.operator_token, "summary-cli-#{index}", "critical")

    first = get_json("/api/v1/cases/summaries", context.viewer_token) |> json_response(200)
    assert length(first["data"]) == 50
    refute Enum.any?(first["data"], &(&1["id"] == selected["id"]))
    assert is_binary(first["page"]["next"])

    root = Path.join(System.tmp_dir!(), "case-summary-cli-#{System.unique_integer([:positive])}")
    config_path = Path.join(root, "config.json")

    :ok =
      SkoposCLI.Config.save(
        %{"server" => "https://skopos.example", "token" => context.viewer_token},
        config_path
      )

    on_exit(fn -> File.rm_rf(root) end)
    stub = {__MODULE__, make_ref()}
    Req.Test.stub(stub, &SkoposWeb.Endpoint.call(&1, SkoposWeb.Endpoint.init([])))
    runtime = [config_path: config_path, request_options: [plug: {Req.Test, stub}]]

    output =
      capture_io(fn ->
        assert SkoposCLI.CLI.run(
                 [
                   "case",
                   "summaries",
                   "--ids",
                   selected["id"],
                   "--query",
                   "summary-cli-selected",
                   "--status",
                   "running",
                   "--sort",
                   "severity_desc",
                   "--limit",
                   "1"
                 ],
                 runtime
               ) == 0
      end)
      |> Jason.decode!()

    assert [%{"id" => id, "revision" => 1, "status" => "running"} = item] = output["data"]
    assert id == selected["id"]
    assert output["page"]["next"] == nil
    refute Map.has_key?(item, "initial_context")

    next =
      capture_io(fn ->
        assert SkoposCLI.CLI.run(
                 ["case", "summaries", "--after", first["page"]["next"]],
                 runtime
               ) == 0
      end)
      |> Jason.decode!()

    assert [%{"id" => ^id}] = next["data"]
    assert next["page"]["next"] == nil
  end

  @tag case_summary: true
  test "Case summary reads enforce bounds and retain database failures instead of reporting empty choices",
       context do
    incident = open_case!(context.operator_token, "summary-read-failure", "critical")
    path = "/api/v1/cases/summaries"
    ids = [incident["id"] | for(_ <- 1..99, do: Ecto.UUID.generate())]

    assert [%{"id" => id}] =
             json_response(
               get_json(path <> "?ids=" <> Enum.join(ids, ","), context.viewer_token),
               200
             )["data"]

    assert id == incident["id"]
    assert get_json(path, nil).status == 401

    for query <- [
          "ids=",
          "ids=not-a-uuid",
          "ids=" <> Enum.join([Ecto.UUID.generate() | ids], ","),
          "query=",
          "query=" <> String.duplicate("x", 201),
          "status=unknown",
          "sort=unknown"
        ] do
      failed = get_json(path <> "?" <> query, context.admin_token)
      assert %{"error" => %{"code" => "validation_failed"}} = json_response(failed, 422)
      assert_operation_response(failed)
    end

    for query <- ["after=", "limit=101"] do
      assert %{"error" => %{"code" => "invalid_pagination"}} =
               json_response(get_json(path <> "?" <> query, context.admin_token), 422)
    end

    Skopos.Repo.query!(
      "ALTER TABLE cases RENAME COLUMN initial_context TO unavailable_initial_context"
    )

    try do
      projected = get_json(path <> "?ids=#{id}&sort=severity_desc", context.viewer_token)
      assert [%{"id" => ^id}] = json_response(projected, 200)["data"]
      assert_operation_response(projected)
    after
      Skopos.Repo.query!(
        "ALTER TABLE cases RENAME COLUMN unavailable_initial_context TO initial_context"
      )
    end

    Skopos.Repo.query!("ALTER TABLE cases RENAME COLUMN title TO unavailable_title")

    try do
      capture_log(fn ->
        failed = get_json(path <> "?ids=#{id}", context.viewer_token)
        assert %{"error" => %{"code" => "internal_error"}} = json_response(failed, 500)
        refute Map.has_key?(json_response(failed, 500), "data")
      end)
    after
      Skopos.Repo.query!("ALTER TABLE cases RENAME COLUMN unavailable_title TO title")
    end

    assert [%{"id" => ^id}] =
             json_response(get_json(path <> "?ids=#{id}", context.viewer_token), 200)["data"]
  end

  @tag condition_history_capacity: true
  test "authenticated Case snapshot and split expose native Condition ownership", context do
    current = Cases.current_authority_setting!(actor: context.admin)

    Cases.configure_authority_setting!(
      current.setting_revision,
      current.authority_mode,
      true,
      current.max_elapsed_seconds,
      current.max_resolver_turns,
      current.max_target_requests,
      current.max_effects,
      current.max_related_targets,
      current.max_ai_usage_units,
      current.max_no_progress_turns,
      "Enable Signal intake for Case API",
      actor: context.admin
    )

    provider =
      Providers.create_provider!(
        "case-api-signal",
        :signal,
        "fixture-signal",
        %{"source" => "case-api-monitor"},
        %{"secret" => "case-api-secret"},
        actor: context.admin
      )
      |> then(&Providers.check_provider!(&1.id, 1, %{}, actor: context.admin))
      |> then(&Providers.enable_provider!(&1, 1, actor: context.admin))

    target =
      Targets.create_target!("case-api-host", "host", "linux", %{}, nil, actor: context.admin)

    Targets.create_external_identity!(
      target.id,
      "case-api-monitor",
      "hostname",
      "case-api-host",
      actor: context.admin
    )

    now = DateTime.add(DateTime.utc_now(), -10, :second)

    events =
      for name <- ["api.service", "db.service"] do
        %Signal.Event{
          receipt_id: "case-api-receipt",
          event_key: name,
          state: :firing,
          occurred_at: now,
          target_ref: %{kind: :hostname, value: "case-api-host"},
          attributes: %{"labels" => %{"service" => name, "alertname" => "ServiceUnavailable"}}
        }
      end

    Signals.ingest_signal!(
      provider.id,
      provider.revision,
      %Signal.Envelope{body: "case-api-receipt", headers: %{}, received_at: now},
      %{
        authenticate: fn adapter, _envelope ->
          {:ok,
           %Signal.AuthenticatedReceipt{receipt_id: "case-api-receipt", source: adapter.source}}
        end,
        normalize: fn _adapter, _envelope, _receipt -> {:ok, events} end
      }
    )

    [incident] = Cases.list_cases!(actor: context.admin)
    listed = get_data!("/api/v1/cases", context.viewer_token)
    assert [%{"id" => listed_id, "condition_count" => 2, "firing_condition_count" => 2}] = listed
    assert listed_id == incident.id
    assert %{status: :sent} = Cases.send_initial_case_turn!(incident.id, authorize?: false)
    run = Cases.active_resolution_run!(incident.id, authorize?: false)
    [turn] = Cases.started_turns_for_run!(run.id, authorize?: false)

    snapshot = get_data!("/api/v1/cases/#{incident.id}", context.viewer_token)
    assert length(snapshot["conditions"]) == 2

    current_condition =
      Signals.get_condition!(hd(snapshot["conditions"])["id"], authorize?: false)

    historical_condition =
      current_condition
      |> Map.take(
        ~w(signal_correlation_id target_id occurrence first_fired_at current_occurred_at)a
      )
      |> Map.merge(%{
        predicate: "Historical fixture",
        occurrence: current_condition.occurrence + 1,
        subject_key: "history-capacity",
        subject_ref: %{},
        state: :recovered
      })
      |> Signals.create_condition_record!(authorize?: false)

    for index <- 1..100 do
      attached_at = DateTime.add(incident.inserted_at, index, :second)

      membership =
        Cases.attach_case_condition_record!(
          %{
            case_id: incident.id,
            condition_id: historical_condition.id,
            attached_at: attached_at,
            reason: "Historical fixture"
          },
          authorize?: false
        )

      Cases.detach_case_condition_record!(
        membership,
        membership.revision,
        %{detached_at: DateTime.add(attached_at, 1, :second), reason: String.duplicate("h", 500)},
        authorize?: false
      )
    end

    response = get_json("/api/v1/cases/#{incident.id}", context.viewer_token)
    assert byte_size(response.resp_body) < 30_000
    snapshot = json_response(response, 200)["data"]
    refute Map.has_key?(snapshot, "condition_history")
    assert length(snapshot["conditions"]) == 2
    assert snapshot["case"]["condition_count"] == 2
    assert snapshot["case"]["firing_condition_count"] == 2

    history_path = "/api/v1/cases/#{incident.id}/condition-history"
    history_response = get_json("#{history_path}?limit=100", context.viewer_token)
    history = json_response(history_response, 200)
    assert_operation_response(history_response)
    assert length(history["data"]) == 100
    assert Enum.all?(history["data"], &(&1["condition_id"] == historical_condition.id))
    assert Enum.all?(history["data"], &(&1["detached_at"] != nil))
    history_query = URI.encode_query(%{"after" => history["page"]["next"], "limit" => 100})
    history_tail = get_json("#{history_path}?#{history_query}", context.viewer_token)
    assert length(json_response(history_tail, 200)["data"]) == 2
    assert json_response(history_tail, 200)["page"]["next"] == nil
    assert json_response(get_json(history_path, nil), 401)["error"]["code"] == "unauthenticated"

    Skopos.Repo.query!(
      "ALTER TABLE operations RENAME COLUMN result_details TO unavailable_result_details"
    )

    try do
      capture_log(fn ->
        metadata_only = get_json("/api/v1/cases/#{incident.id}", context.viewer_token)
        assert json_response(metadata_only, 200)["data"]["conditions"] == snapshot["conditions"]
        assert_operation_response(metadata_only)
      end)
    after
      Skopos.Repo.query!(
        "ALTER TABLE operations RENAME COLUMN unavailable_result_details TO result_details"
      )
    end

    root = Path.join(System.tmp_dir!(), "condition-cli-#{System.unique_integer([:positive])}")
    config_path = Path.join(root, "config.json")

    :ok =
      SkoposCLI.Config.save(
        %{"server" => "https://skopos.example", "token" => context.viewer_token},
        config_path
      )

    on_exit(fn -> File.rm_rf(root) end)
    stub = {__MODULE__, make_ref()}
    Req.Test.stub(stub, &SkoposWeb.Endpoint.call(&1, SkoposWeb.Endpoint.init([])))
    runtime = [config_path: config_path, request_options: [plug: {Req.Test, stub}]]

    history_cli =
      capture_io(fn ->
        assert SkoposCLI.CLI.run(
                 [
                   "case",
                   "condition-history",
                   incident.id,
                   "--limit",
                   "100",
                   "--after",
                   history["page"]["next"]
                 ],
                 runtime
               ) == 0
      end)

    assert Map.take(Jason.decode!(history_cli), ["data", "page"]) ==
             json_response(history_tail, 200)

    Skopos.Repo.query!(
      "ALTER TABLE case_condition_memberships RENAME COLUMN reason TO unavailable_reason"
    )

    try do
      capture_log(fn ->
        current_only = get_json("/api/v1/cases/#{incident.id}", context.viewer_token)
        assert json_response(current_only, 200)["data"]["conditions"] == snapshot["conditions"]
        failed = get_json(history_path, context.viewer_token)
        assert json_response(failed, 500)["error"]["code"] == "internal_error"

        capture_io(:stderr, fn ->
          assert SkoposCLI.CLI.run(["case", "condition-history", incident.id], runtime) == 4
        end)
      end)
    after
      Skopos.Repo.query!(
        "ALTER TABLE case_condition_memberships RENAME COLUMN unavailable_reason TO reason"
      )
    end

    assert json_response(get_json("#{history_path}?limit=100", context.viewer_token), 200) ==
             history

    for {table, column} <- [
          {"case_condition_memberships", "condition_id"},
          {"conditions", "predicate"}
        ] do
      Skopos.Repo.query!("ALTER TABLE #{table} RENAME COLUMN #{column} TO unavailable_#{column}")

      try do
        assert {:error, %Ash.Error.Unknown{} = cause} =
                 Cases.case_reconnect_snapshot(incident.id, actor: context.admin)

        assert Exception.message(cause) =~ "does not exist"

        capture_log(fn ->
          failed = get_json("/api/v1/cases/#{incident.id}", context.viewer_token)
          assert json_response(failed, 500)["error"]["code"] == "internal_error"

          capture_io(:stderr, fn ->
            assert SkoposCLI.CLI.run(["case", "show", incident.id], runtime) == 4
          end)
        end)
      after
        Skopos.Repo.query!(
          "ALTER TABLE #{table} RENAME COLUMN unavailable_#{column} TO #{column}"
        )
      end

      assert get_data!("/api/v1/cases/#{incident.id}", context.viewer_token)["conditions"] ==
               snapshot["conditions"]
    end

    refute_receive {:resolve, _, _}
    refute_receive {:effect, _, _}

    Skopos.Repo.query!(
      "ALTER TABLE evidences RENAME COLUMN observed_at TO unavailable_observed_at"
    )

    try do
      assert {:error, %Ash.Error.Unknown{} = cause} =
               Cases.case_reconnect_snapshot(incident.id, actor: context.admin)

      assert Exception.message(cause) =~ "does not exist"
      failed = get_json("/api/v1/cases/#{incident.id}", context.viewer_token)
      assert json_response(failed, 500)["error"]["code"] == "internal_error"
      assert_operation_response(failed)

      failed_cli =
        capture_io(:stderr, fn ->
          assert SkoposCLI.CLI.run(["case", "show", incident.id], runtime) == 4
        end)

      assert %{"http_status" => 500, "error" => %{"code" => "internal_error"}} =
               Jason.decode!(failed_cli)
    after
      Skopos.Repo.query!(
        "ALTER TABLE evidences RENAME COLUMN unavailable_observed_at TO observed_at"
      )
    end

    assert length(get_data!("/api/v1/cases/#{incident.id}", context.viewer_token)["conditions"]) ==
             2

    refs = Enum.map(snapshot["conditions"], & &1["subject_ref"])
    assert Enum.all?(refs, &(&1["kind"] == "native_labels" and is_binary(&1["digest"])))
    assert length(Enum.uniq(refs)) == 2

    revisions =
      snapshot["conditions"]
      |> Enum.map(&Map.take(&1, ["id", "revision"]))
      |> Enum.sort_by(& &1["id"])

    db_condition_id =
      Signals.list_signal_events!(actor: context.admin)
      |> Enum.find(&(&1.event_key == "db.service"))
      |> Map.fetch!(:condition_id)

    [moved] = Enum.filter(snapshot["conditions"], &(&1["id"] == db_condition_id))

    Cases.complete_turn!(
      turn.id,
      turn.revision,
      %{
        "outcome" => "decision",
        "condition_revisions" => revisions,
        "condition_assessments" => [
          %{
            "condition_id" => moved["id"],
            "revision" => moved["revision"],
            "status" => "still_failing",
            "evidence_ids" => [],
            "reason" => "Database service remains unavailable"
          }
        ],
        "condition_groups" => [
          %{
            "condition_ids" => Enum.map(revisions, & &1["id"]),
            "assessment" => "unknown",
            "reason" => "No common cause observation yet",
            "evidence_ids" => []
          }
        ],
        "intent" => %{"type" => "handoff", "reason" => "Investigate separately"}
      },
      :none,
      %{"action" => "route_resolver_decision", "turn_id" => turn.id},
      "Review Resolver decision",
      authorize?: false
    )

    # Later history from a different Condition revision cannot replace current AI context.
    source = Cases.get_turn!(turn.id, authorize?: false)
    inputs = Map.take(source, Ash.Resource.Info.action(source.__struct__, :create_record).accept)

    for index <- 1..100 do
      Cases.create_turn_record!(
        Map.merge(Map.drop(inputs, [:id]), %{
          ordinal: index + 10_000,
          idempotency_key: "condition-context-history:#{index}",
          completed_at: DateTime.add(source.completed_at, index, :microsecond),
          result: %{
            "outcome" => "decision",
            "condition_revisions" => [],
            "condition_groups" => [],
            "condition_assessments" => []
          }
        }),
        authorize?: false
      )
    end

    snapshot = get_data!("/api/v1/cases/#{incident.id}", context.viewer_token)
    assert snapshot["condition_context"]["groups"]["id"] == turn.id
    assert snapshot["condition_context"]["assessments"]["id"] == turn.id

    assert snapshot["condition_context"]["assessments"]["condition_assessments"] == [
             %{
               "condition_id" => moved["id"],
               "revision" => moved["revision"],
               "status" => "still_failing",
               "evidence_ids" => [],
               "reason" => "Database service remains unavailable"
             }
           ]

    assert snapshot["condition_context"]["groups"]["condition_revisions"] == revisions

    [current_context] =
      Cases.latest_turn_condition_context!(incident.id, revisions, "condition_groups",
        actor: context.operator
      )

    refute Ash.Resource.selected?(current_context, :intent)
    refute Ash.Resource.selected?(current_context, :result)
    summaries = get_data!("/api/v1/cases/#{incident.id}/turns", context.viewer_token)
    refute Enum.any?(summaries, &(&1["id"] == turn.id))
    refute Map.has_key?(hd(summaries), "decision")
    full = get_data!("/api/v1/turns/#{turn.id}", context.viewer_token)

    assert %{
             "condition_revisions" => ^revisions,
             "condition_groups" => [%{"assessment" => "unknown"}]
           } = full

    Skopos.Repo.query!("ALTER TABLE turns RENAME COLUMN result TO unavailable_result")

    try do
      assert {:error, %Ash.Error.Unknown{} = cause} =
               Cases.case_reconnect_snapshot(incident.id, actor: context.operator)

      assert Exception.message(cause) =~ "does not exist"

      capture_log(fn ->
        failed = get_json("/api/v1/cases/#{incident.id}", context.viewer_token)
        assert json_response(failed, 500)["error"]["code"] == "internal_error"
        assert_operation_response(failed)
      end)
    after
      Skopos.Repo.query!("ALTER TABLE turns RENAME COLUMN unavailable_result TO result")
    end

    assert get_data!("/api/v1/cases/#{incident.id}", context.viewer_token)["condition_context"] ==
             snapshot["condition_context"]

    parent = Cases.get_case!(incident.id, authorize?: false)

    body = %{
      "case" => %{
        "expected_revision" => parent.revision,
        "condition_ids" => [moved["id"]],
        "expected_conditions" => revisions,
        "reason" => "Independent database failure"
      }
    }

    denied = post_json("/api/v1/cases/#{parent.id}/split", body, context.viewer_token)
    assert json_response(denied, 403)["error"]["code"] == "forbidden"

    stale_membership =
      body
      |> put_in(
        ["case", "expected_conditions"],
        List.update_at(
          revisions,
          0,
          &Map.update!(&1, "revision", fn revision -> revision + 1 end)
        )
      )
      |> then(&post_json("/api/v1/cases/#{parent.id}/split", &1, context.operator_token))

    assert json_response(stale_membership, 409)["error"]["code"] == "conflict"

    :ok = Realtime.subscribe(parent.id)
    response = post_json("/api/v1/cases/#{parent.id}/split", body, context.operator_token)

    assert %{"data" => %{"id" => child_id, "split_parent_id" => parent_id}} =
             json_response(response, 200)

    assert_operation_response(response)
    assert parent_id == parent.id
    assert_receive {:case_changed, ^parent_id}

    stale_revision =
      body
      |> put_in(["case", "reason"], "Stale Case revision")
      |> then(&post_json("/api/v1/cases/#{parent.id}/split", &1, context.operator_token))

    assert json_response(stale_revision, 409)["error"]["code"] == "conflict"

    parent_snapshot = get_data!("/api/v1/cases/#{parent.id}", context.viewer_token)
    child_snapshot = get_data!("/api/v1/cases/#{child_id}", context.viewer_token)
    assert length(parent_snapshot["conditions"]) == 1
    assert Enum.map(child_snapshot["conditions"], & &1["id"]) == [moved["id"]]
    assert hd(parent_snapshot["conditions"])["id"] != moved["id"]

    assert Enum.sort(
             Enum.map(get_data!("/api/v1/cases", context.viewer_token), & &1["condition_count"])
           ) == [1, 1]

    parent_tail = get_data!("#{history_path}?#{history_query}", context.viewer_token)
    assert length(parent_tail) == 2

    assert Enum.any?(
             parent_tail,
             &(&1["condition_id"] == moved["id"] && &1["detached_at"] != nil)
           )

    child_history = get_data!("/api/v1/cases/#{child_id}/condition-history", context.viewer_token)
    assert length(child_history) == 1
    assert hd(child_history)["condition_id"] == moved["id"]

    timeline = get_data!("/api/v1/cases/#{parent.id}/timeline", context.viewer_token)
    assert Enum.any?(timeline, &(&1["related_case_id"] == child_id))
  end

  test "authority and Case lifecycle remain revisioned and reconnectable", context do
    current = get_data!("/api/v1/authority-setting", context.viewer_token)
    assert current["authority_mode"] == "readonly"
    assert current["setting_revision"] == 1

    configured =
      put_json(
        "/api/v1/authority-setting",
        %{
          "authority_setting" =>
            current
            |> Map.take([
              "authority_mode",
              "signal_automation_enabled",
              "max_elapsed_seconds",
              "max_resolver_turns",
              "max_target_requests",
              "max_effects",
              "max_related_targets",
              "max_ai_usage_units",
              "max_no_progress_turns"
            ])
            |> Map.merge(%{
              "expected_setting_revision" => current["setting_revision"],
              "authority_mode" => "ask",
              "reason" => "require operator approval"
            })
        },
        context.admin_token
      )

    assert %{"data" => %{"authority_mode" => "ask", "setting_revision" => 2}} =
             json_response(configured, 200)

    assert_operation_response(configured)

    authority_history = get_json("/api/v1/authority-settings", context.viewer_token)
    assert %{"data" => [_, _], "page" => %{"next" => nil}} = json_response(authority_history, 200)
    assert_operation_response(authority_history)

    stale_setting =
      put_json(
        "/api/v1/authority-setting",
        %{
          "authority_setting" => %{
            "expected_setting_revision" => 1,
            "authority_mode" => "readonly",
            "signal_automation_enabled" => false,
            "max_elapsed_seconds" => 3600,
            "max_resolver_turns" => 20,
            "max_target_requests" => 100,
            "max_effects" => 10,
            "max_related_targets" => 20,
            "max_ai_usage_units" => 1_000_000,
            "max_no_progress_turns" => 3,
            "reason" => "stale authority update"
          }
        },
        context.admin_token
      )

    assert %{"error" => %{"code" => "conflict"}} = json_response(stale_setting, 409)

    language =
      patch_json(
        "/api/v1/account/language",
        %{"account" => %{"preferred_language" => "ja"}},
        context.operator_token
      )

    assert %{"data" => %{"preferred_language" => "ja"}} = json_response(language, 200)

    incident = open_case!(context.operator_token, "lifecycle-1")
    assert incident["status"] == "running"
    assert incident["operator_action"] == "none"
    assert incident["authority_mode"] == "ask"
    assert incident["report_language"] == "ja"

    cases = get_json("/api/v1/cases", context.viewer_token)
    assert %{"data" => [%{"id" => case_id}]} = json_response(cases, 200)
    assert case_id == incident["id"]
    assert_operation_response(cases)

    claimed =
      post_json(
        "/api/v1/cases/#{incident["id"]}/claim",
        %{"case" => %{"expected_revision" => incident["revision"]}},
        context.operator_token
      )

    assert %{"data" => %{"revision" => 2, "current_owner_id" => owner_id}} =
             json_response(claimed, 200)

    assert_operation_response(claimed)

    assert owner_id == context.operator.id

    retried_claim =
      post_json(
        "/api/v1/cases/#{incident["id"]}/claim",
        %{"case" => %{"expected_revision" => incident["revision"]}},
        context.operator_token
      )

    assert json_response(retried_claim, 200)["data"] == json_response(claimed, 200)["data"]

    handed_off =
      post_json(
        "/api/v1/cases/#{incident["id"]}/handoff",
        %{"case" => %{"expected_revision" => 2, "owner_id" => context.next_operator.id}},
        context.operator_token
      )

    assert %{"data" => %{"revision" => 3, "current_owner_id" => next_owner}} =
             json_response(handed_off, 200)

    assert next_owner == context.next_operator.id
    assert_operation_response(handed_off)

    cancelled =
      post_json(
        "/api/v1/cases/#{incident["id"]}/cancel",
        %{"case" => %{"expected_revision" => 3}},
        token!(context.next_operator.email)
      )

    assert %{
             "data" => %{
               "revision" => 4,
               "cancel_requested" => true,
               "status" => "cancelled"
             }
           } =
             json_response(cancelled, 200)

    assert_operation_response(cancelled)

    report = Reports.generate_report!(incident["id"], 4, actor: context.operator)

    snapshot = get_json("/api/v1/cases/#{incident["id"]}", context.viewer_token)

    assert %{
             "data" => %{
               "case" => %{"id" => case_id, "revision" => 4},
               "resolution_runs" => [
                 %{"generation" => 1, "status" => "cancelled", "active" => false}
               ],
               "proposals" => [],
               "operations" => [],
               "verification_attempts" => [],
               "reports" => [%{"id" => report_id, "case_revision" => 4}]
             }
           } = json_response(snapshot, 200)

    assert_operation_response(snapshot)

    assert case_id == incident["id"]
    assert report_id == report.id
    [report_summary] = json_response(snapshot, 200)["data"]["reports"]
    refute Map.has_key?(report_summary, "content")
    refute Map.has_key?(report_summary, "document")
    complete_report = get_json("/api/v1/reports/#{report.id}", context.viewer_token)
    assert_operation_response(complete_report)
    assert json_response(complete_report, 200)["data"]["content"] == report.content
    refute snapshot.resp_body =~ "pending_intent"
    refute snapshot.resp_body =~ "idempotency_key"

    timeline = get_json("/api/v1/cases/#{incident["id"]}/timeline?limit=2", context.viewer_token)

    assert %{"data" => first_events, "page" => %{"next" => cursor}} =
             json_response(timeline, 200)

    assert_operation_response(timeline)

    assert Enum.map(first_events, & &1["type"]) == ["case_cancelled", "case_handed_off"]
    assert is_binary(cursor)
    refute timeline.resp_body =~ "idempotency_key"
    refute Enum.any?(first_events, &Map.has_key?(&1, "data"))

    older_timeline =
      get_json(
        "/api/v1/cases/#{incident["id"]}/timeline?limit=2&after=" <>
          URI.encode_www_form(cursor),
        context.viewer_token
      )

    assert_operation_response(older_timeline)
    older_page = json_response(older_timeline, 200)
    assert Enum.map(older_page["data"], & &1["type"]) == ["case_claimed", "case_opened"]
    assert older_page["page"]["next"] == nil

    viewer_mutation =
      post_json(
        "/api/v1/cases/#{incident["id"]}/claim",
        %{"case" => %{"expected_revision" => 4}},
        context.viewer_token
      )

    assert %{"error" => %{"code" => "forbidden"}} = json_response(viewer_mutation, 403)
  end

  test "a needs-attention Case resumes once with extended limits", context do
    incident = open_case!(context.operator_token, "resume-1")
    run = Cases.active_resolution_run!(incident["id"], authorize?: false)

    attention =
      Cases.require_case_attention!(
        incident["id"],
        incident["revision"],
        run.id,
        run.revision,
        "workflow-api-attention",
        "Resolver turn limit exhausted",
        %{"kind" => "observe"},
        "Extend limits or investigate manually",
        authorize?: false
      )

    paused_run = Cases.get_resolution_run!(run.id, authorize?: false)

    lower_limits =
      resume_input(attention, paused_run, paused_run.revision)
      |> Map.put("max_resolver_turns", paused_run.max_resolver_turns - 1)

    rejected =
      post_json(
        "/api/v1/cases/#{incident["id"]}/resume",
        %{"case" => lower_limits},
        context.operator_token
      )

    assert %{"error" => %{"code" => "validation_failed", "details" => %{"fields" => fields}}} =
             json_response(rejected, 422)

    assert "max_resolver_turns" in fields
    assert Cases.active_resolution_run!(incident["id"], authorize?: false).id == paused_run.id

    stale =
      post_json(
        "/api/v1/cases/#{incident["id"]}/resume",
        %{
          "case" => resume_input(attention, paused_run, paused_run.revision + 1)
        },
        context.operator_token
      )

    assert %{"error" => %{"code" => "conflict"}} = json_response(stale, 409)

    resumed =
      post_json(
        "/api/v1/cases/#{incident["id"]}/resume",
        %{"case" => resume_input(attention, paused_run, paused_run.revision)},
        context.operator_token
      )

    assert %{"data" => %{"generation" => 2, "status" => "running", "active" => true}} =
             json_response(resumed, 200)

    assert_operation_response(resumed)

    snapshot = get_data!("/api/v1/cases/#{incident["id"]}", context.viewer_token)
    assert snapshot["case"]["status"] == "running", inspect(snapshot["case"])
    assert Enum.map(snapshot["resolution_runs"], & &1["generation"]) == [2, 1]
    assert Enum.map(snapshot["resolution_runs"], & &1["status"]) == ["running", "superseded"]

    assert %{"data" => [%{"status" => "started", "ordinal" => 1}]} =
             "/api/v1/cases/#{incident["id"]}/turns"
             |> get_json(context.viewer_token)
             |> json_response(200)
  end

  test "Proposal decision and status polling never dispatch an effect from HTTP", context do
    configure_mode!(:ask, context.admin)
    setup = proposal_setup!(context)
    {incident, proposal} = awaiting_proposal!(setup, context.operator)

    wrong_digest =
      post_json(
        "/api/v1/proposals/#{proposal.id}/decision",
        %{
          "proposal" => %{
            "expected_revision" => proposal.revision,
            "proposal_digest" => String.duplicate("0", 64),
            "decision" => "approved",
            "reason" => "stale proposal input"
          }
        },
        context.operator_token
      )

    assert %{"error" => %{"code" => "conflict"}} = json_response(wrong_digest, 409)

    decision_body = %{
      "proposal" => %{
        "expected_revision" => proposal.revision,
        "proposal_digest" => proposal.proposal_digest,
        "decision" => "approved",
        "reason" => "the evidence supports this exact restart"
      }
    }

    approved =
      post_json(
        "/api/v1/proposals/#{proposal.id}/decision",
        decision_body,
        context.operator_token
      )

    assert %{"data" => %{"status" => "authorized", "revision" => approved_revision}} =
             json_response(approved, 200)

    assert_operation_response(approved)

    assert approved_revision > proposal.revision

    proposal_response = get_json("/api/v1/proposals/#{proposal.id}", context.viewer_token)
    assert %{"data" => %{"id" => proposal_id}} = json_response(proposal_response, 200)
    assert proposal_id == proposal.id
    assert_operation_response(proposal_response)

    duplicate =
      post_json(
        "/api/v1/proposals/#{proposal.id}/decision",
        decision_body,
        context.operator_token
      )

    assert json_response(duplicate, 200)["data"] == json_response(approved, 200)["data"]
    assert length(Cases.list_approvals!(actor: context.admin)) == 1
    assert Cases.list_operations!(actor: context.admin) == []

    turns = get_json("/api/v1/cases/#{incident.id}/turns", context.viewer_token)

    assert %{
             "data" => [
               %{
                 "ordinal" => 1,
                 "status" => "completed",
                 "summary" => %{"outcome" => "decision", "type" => "proposal"},
                 "progress_kind" => "proposal"
               }
             ],
             "page" => %{"next" => nil}
           } = json_response(turns, 200)

    assert_operation_response(turns)

    evidence = get_json("/api/v1/cases/#{incident.id}/evidence", context.viewer_token)

    assert %{
             "data" => [
               %{
                 "kind" => "observation",
                 "source" => "fixture",
                 "source_ref" => "observation-1",
                 "summary" => %{"status" => nil}
               }
             ],
             "page" => %{"next" => nil}
           } = json_response(evidence, 200)

    assert_operation_response(evidence)

    approvals = get_json("/api/v1/cases/#{incident.id}/approvals", context.viewer_token)

    assert %{
             "data" => [
               %{
                 "proposal_id" => proposal_id,
                 "decision" => "approved",
                 "source" => "human",
                 "reason" => "the evidence supports this exact restart"
               }
             ],
             "page" => %{"next" => nil}
           } = json_response(approvals, 200)

    assert_operation_response(approvals)

    assert proposal_id == proposal.id

    assert %{"data" => [], "page" => %{"next" => nil}} =
             get_json("/api/v1/cases/#{incident.id}/review-decisions", context.viewer_token)
             |> json_response(200)

    for response <- [turns, evidence, approvals] do
      refute response.resp_body =~ "idempotency_key"
      refute response.resp_body =~ "resolver-secret"
      refute response.resp_body =~ "provider-secret"
      refute response.resp_body =~ "clearance_digest"
      refute response.resp_body =~ "session_id"
    end

    operation = Cases.accept_operation!(proposal.id, authorize?: false)
    operation_response = get_json("/api/v1/operations/#{operation.id}", context.viewer_token)

    assert %{"data" => %{"id" => operation_id, "status" => "queued"}} =
             json_response(operation_response, 200)

    assert_operation_response(operation_response)

    assert operation_id == operation.id
    assert Cases.get_operation!(operation.id, authorize?: false).revision == operation.revision

    assert :ok =
             Skopos.Cases.Operation.Delivery.run(operation.id,
               target_invocation: %{
                 test_pid: self(),
                 respond: fn ->
                   {:ok,
                    %Skopos.Providers.Target.EffectResult{
                      status: :applied,
                      reference: "remote-operation-1",
                      details: %{"changed" => true}
                    }}
                 end
               }
             )

    assert_receive {:effect, _state, _request}
    attempt = Cases.verification_attempt_by_operation!(operation.id, authorize?: false)

    verification_response =
      get_json("/api/v1/verification-attempts/#{attempt.id}", context.viewer_token)

    assert %{"data" => %{"id" => attempt_id, "status" => "queued"}} =
             json_response(verification_response, 200)

    assert_operation_response(verification_response)

    assert attempt_id == attempt.id

    snapshot = get_data!("/api/v1/cases/#{incident.id}", context.viewer_token)
    assert Enum.map(snapshot["proposals"], & &1["status"]) == ["authorized"]
    assert Enum.map(snapshot["operations"], & &1["status"]) == ["applied"]
    assert Enum.map(snapshot["verification_attempts"], & &1["status"]) == ["queued"]

    for response <- [operation_response, verification_response] do
      refute response.resp_body =~ "authorization_digest"
      refute response.resp_body =~ "idempotency_key"
      refute response.resp_body =~ "provider-secret"
    end
  end

  test "expired Proposal decision returns conflict and stops the Case", context do
    configure_mode!(:ask, context.admin)
    setup = proposal_setup!(context)
    {incident, proposal} = awaiting_proposal!(setup, context.operator)
    run = Cases.active_resolution_run!(incident.id, authorize?: false)

    Skopos.Repo.update_all(
      from(item in Skopos.Cases.Proposal, where: item.id == ^proposal.id),
      set: [expires_at: DateTime.add(DateTime.utc_now(), -1, :second)]
    )

    expired =
      post_json(
        "/api/v1/proposals/#{proposal.id}/decision",
        %{
          "proposal" => %{
            "expected_revision" => proposal.revision,
            "proposal_digest" => proposal.proposal_digest,
            "decision" => "approved",
            "reason" => "Approval arrived after expiry"
          }
        },
        context.operator_token
      )

    assert %{"error" => %{"code" => "proposal_expired"}} = json_response(expired, 409)
    assert_operation_response(expired)
    assert Cases.get_proposal!(proposal.id, authorize?: false).status == :invalidated
    assert Cases.get_case!(incident.id, authorize?: false).status == :needs_attention
    assert Cases.get_resolution_run!(run.id, authorize?: false).status == :needs_attention
    assert Cases.list_approvals!(actor: context.admin) == []
    assert Cases.list_operations!(actor: context.admin) == []
  end

  test "auto Reviewer decisions and their exact approval are reconnectable without AI sessions",
       context do
    configure_mode!(:auto, context.admin)
    setup = proposal_setup!(context)
    {incident, reviewing} = awaiting_proposal!(setup, context.operator)

    assert reviewing.status == :reviewing

    assert :ok =
             ReviewDelivery.run(reviewing.id,
               ai_invocation: %{
                 test_pid: self(),
                 respond: fn _request ->
                   {:ok,
                    %AI.ReviewDecision{
                      purpose_assessment: :remediation,
                      verdict: :approved,
                      reason: "The cited evidence supports this exact change",
                      usage: %AI.Usage{input_tokens: 3, output_tokens: 2}
                    }}
                 end
               }
             )

    assert_receive {:review, %{api_key: "reviewer-secret"}, _request}

    response =
      get_json("/api/v1/cases/#{incident.id}/review-decisions", context.viewer_token)

    assert %{
             "data" => [
               %{
                 "proposal_id" => proposal_id,
                 "outcome" => "decision",
                 "verdict" => "approved",
                 "selection_source" => "assignment",
                 "provider_id" => reviewer_id,
                 "input_tokens" => 3,
                 "output_tokens" => 2
               }
             ],
             "page" => %{"next" => nil}
           } = json_response(response, 200)

    assert_operation_response(response)

    assert proposal_id == reviewing.id
    assert reviewer_id == setup.reviewer.id

    usage = get_data!("/api/v1/cases/#{incident.id}", context.viewer_token)["ai_usage"]

    assert %{
             "reported_total_tokens" => 5,
             "reported_invocations" => 1,
             "unknown_invocations" => 0,
             "budget_charged_units" => 5,
             "complete" => true
           } = usage

    assert [
             %{
               "role" => "reviewer",
               "proposal_id" => ^proposal_id,
               "usage_status" => "reported",
               "input_tokens" => 3,
               "output_tokens" => 2
             }
           ] =
             get_data!("/api/v1/cases/#{incident.id}/ai-invocations", context.viewer_token)

    assert %{"data" => [%{"proposal_id" => ^proposal_id, "source" => "reviewer"}]} =
             get_json("/api/v1/cases/#{incident.id}/approvals", context.viewer_token)
             |> json_response(200)

    refute response.resp_body =~ "session_id"
    refute response.resp_body =~ "resolver_session_id"
    refute response.resp_body =~ "assignment_id"
    refute response.resp_body =~ "proposal_digest"
    refute response.resp_body =~ "reviewer-secret"
  end

  test "unexpected Reviewer failures stop for provider repair without creating an approval",
       context do
    configure_mode!(:auto, context.admin)
    setup = proposal_setup!(context)
    {incident, reviewing} = awaiting_proposal!(setup, context.operator)

    assert :ok =
             ReviewDelivery.run(reviewing.id,
               ai_invocation: %{
                 test_pid: self(),
                 respond: fn _request -> raise "credential internal-review-secret" end
               }
             )

    response =
      get_json("/api/v1/cases/#{incident.id}/review-decisions", context.viewer_token)

    assert %{"data" => [], "page" => %{"next" => nil}} = json_response(response, 200)

    assert_operation_response(response)

    stopped = Cases.get_case!(incident.id, authorize?: false)
    assert stopped.status == :needs_attention

    assert stopped.pending_intent == %{
             "action" => "restore_reviewer_delivery",
             "proposal_id" => reviewing.id
           }

    assert stopped.required_human_input == "Restore Reviewer AI availability and resume the Case"
    assert Cases.get_proposal!(reviewing.id, authorize?: false).status == :invalidated

    snapshot = get_data!("/api/v1/cases/#{incident.id}", context.viewer_token)
    assert snapshot["case"]["operator_action"] == "intervention_required"

    refute response.resp_body =~ "internal-review-secret"
    refute response.resp_body =~ "RuntimeError"
  end

  @tag pending_proposal_identity: true
  test "an explicit Reviewer handoff remains an operator decision beyond the history window",
       context do
    configure_mode!(:auto, context.admin)
    setup = proposal_setup!(context)
    {incident, reviewing} = awaiting_proposal!(setup, context.operator)

    assert :ok =
             ReviewDelivery.run(reviewing.id,
               ai_invocation: %{
                 test_pid: self(),
                 respond: fn _request ->
                   {:ok,
                    %AI.ReviewDecision{
                      purpose_assessment: :remediation,
                      verdict: :needs_human,
                      reason: "The evidence requires an operator decision",
                      usage: %AI.Usage{input_tokens: 2, output_tokens: 2}
                    }}
                 end
               }
             )

    snapshot = get_data!("/api/v1/cases/#{incident.id}", context.viewer_token)
    assert snapshot["case"]["status"] == "running"
    assert snapshot["case"]["operator_action"] == "decision_required"
    assert snapshot["case"]["pending_proposal_id"] == reviewing.id
    assert [%{"status" => "awaiting_human"}] = snapshot["proposals"]

    # Historical records test read capacity; they do not authorize or dispatch effects.
    current = Cases.get_proposal!(reviewing.id, authorize?: false)

    inputs =
      Map.take(current, Ash.Resource.Info.action(current.__struct__, :create_record).accept)

    source_turn = Cases.get_turn!(current.source_turn_id, authorize?: false)

    turn_inputs =
      Map.take(
        source_turn,
        Ash.Resource.Info.action(source_turn.__struct__, :create_record).accept
      )

    for index <- 1..100 do
      turn =
        Cases.create_turn_record!(
          Map.merge(Map.drop(turn_inputs, [:id]), %{
            ordinal: index + 1,
            idempotency_key: "pending-history:#{index}"
          }),
          authorize?: false
        )

      Cases.create_proposal_record!(
        Map.merge(Map.drop(inputs, [:id]), %{
          source_turn_id: turn.id,
          status: :authorized,
          reserved_operation_id: Ecto.UUID.generate(),
          operation_idempotency_key: "pending-history:#{index}"
        }),
        authorize?: false
      )
    end

    snapshot = get_data!("/api/v1/cases/#{incident.id}", context.viewer_token)
    assert snapshot["case"]["pending_proposal_id"] == reviewing.id
    assert length(snapshot["proposals"]) == 100
    refute Enum.any?(snapshot["proposals"], &(&1["id"] == reviewing.id))

    assert get_data!("/api/v1/proposals/#{reviewing.id}", context.operator_token)["status"] ==
             "awaiting_human"

    root =
      Path.join(System.tmp_dir!(), "pending-proposal-cli-#{System.unique_integer([:positive])}")

    config_path = Path.join(root, "config.json")
    on_exit(fn -> File.rm_rf(root) end)

    :ok =
      SkoposCLI.Config.save(
        %{"server" => "https://skopos.example", "token" => context.operator_token},
        config_path
      )

    stub = {__MODULE__, make_ref()}
    Req.Test.stub(stub, &SkoposWeb.Endpoint.call(&1, SkoposWeb.Endpoint.init([])))

    output =
      capture_io(fn ->
        assert SkoposCLI.CLI.run(["case", "wait", incident.id, "--timeout", "0"],
                 config_path: config_path,
                 request_options: [plug: {Req.Test, stub}]
               ) == 11
      end)

    assert Jason.decode!(output)["outcome"] == "approval_required"
  end

  test "contract rejects malformed Case identifiers and action bodies", context do
    invalid_id = get_json("/api/v1/cases/not-a-uuid", context.viewer_token)

    assert %{"error" => %{"code" => "validation_failed", "details" => %{"fields" => ["id"]}}} =
             json_response(invalid_id, 422)

    assert_operation_response(invalid_id)

    incident = open_case!(context.operator_token, "invalid-action-contract")

    invalid_revision =
      post_json(
        "/api/v1/cases/#{incident["id"]}/claim",
        %{"case" => %{"expected_revision" => 0}},
        context.operator_token
      )

    assert %{
             "error" => %{
               "code" => "validation_failed",
               "details" => %{"fields" => ["expected_revision"]}
             }
           } = json_response(invalid_revision, 422)

    assert_operation_response(invalid_revision)
  end

  @tag normalized_public_receipt: true
  test "public clients read the complete normalized receipt and opaque reference",
       context do
    configure_mode!(:full_access, context.admin)
    setup = proposal_setup!(context, token: "!")
    {incident, proposal} = awaiting_proposal!(setup, context.operator)
    operation = Cases.accept_operation!(proposal.id, authorize?: false)
    details = %{"payload" => String.duplicate("!", 65_522)}
    expected_details = %{"payload" => String.duplicate("[REDACTED]", 65_522)}
    reference = " " <> String.duplicate("!", 65_534) <> " "
    expected_reference = " " <> String.duplicate("[REDACTED]", 65_534) <> " "

    assert :ok =
             Skopos.Cases.Operation.Delivery.run(operation.id,
               target_invocation: %{
                 test_pid: self(),
                 respond: fn ->
                   {:ok,
                    %Skopos.Providers.Target.EffectResult{
                      status: :applied,
                      details: details,
                      reference: reference
                    }}
                 end
               }
             )

    assert_receive {:effect, _, _}

    saved = Cases.get_operation!(operation.id, actor: context.operator)
    initial_snapshot = get_json("/api/v1/cases/#{incident.id}", context.viewer_token)
    assert byte_size(initial_snapshot.resp_body) < 20_000
    assert hd(json_response(initial_snapshot, 200)["data"]["operations"])["status"] == "applied"
    verification = Cases.verification_attempt_by_operation!(operation.id, authorize?: false)
    source_turn = Cases.get_turn!(proposal.source_turn_id, authorize?: false)

    # Capacity fixtures use the internal record actions; only the original receipt was delivered.
    copy_inputs = fn record ->
      Map.take(record, Ash.Resource.Info.action(record.__struct__, :create_record).accept)
      |> Map.drop([:id])
    end

    padded_intent = Map.put(source_turn.intent, "padding", "")
    intent_padding = String.duplicate("x", 65_536 - byte_size(Jason.encode!(padded_intent)))
    padded_intent = Map.put(padded_intent, "padding", intent_padding)
    padded_result = Map.update!(source_turn.result, "intent", &Map.put(&1, "padding", ""))
    decision_padding = String.duplicate("x", 65_536 - byte_size(Jason.encode!(padded_result)))

    padded_result =
      Map.update!(padded_result, "intent", &Map.put(&1, "padding", decision_padding))

    assert byte_size(Jason.encode!(padded_intent)) == 65_536
    assert byte_size(Jason.encode!(padded_result)) == 65_536

    padded_proposal_fields =
      Map.new(
        ~w(selectors parameters expected_result verification_intent verification_tool resolver_identity preflight_context)a,
        fn field ->
          base = Map.put(Map.fetch!(proposal, field), "padding", "")

          body =
            Map.put(
              base,
              "padding",
              String.duplicate("x", 65_536 - byte_size(Jason.encode!(base)))
            )

          assert byte_size(Jason.encode!(body)) == 65_536
          {field, body}
        end
      )

    for index <- 1..100 do
      turn =
        Cases.create_turn_record!(
          Map.merge(copy_inputs.(source_turn), %{
            ordinal: index + 1,
            idempotency_key: "history-capacity:#{index}",
            intent: padded_intent,
            result: padded_result
          }),
          authorize?: false
        )

      next_proposal =
        Cases.create_proposal_record!(
          Map.merge(Map.merge(copy_inputs.(proposal), padded_proposal_fields), %{
            source_turn_id: turn.id,
            reserved_operation_id: Ecto.UUID.generate(),
            operation_idempotency_key: "history-capacity:#{index}"
          }),
          authorize?: false
        )

      next_operation =
        Cases.create_operation_record!(
          Map.merge(copy_inputs.(saved), %{
            proposal_id: next_proposal.id,
            idempotency_key: "history-capacity:#{index}"
          }),
          authorize?: false
        )

      Cases.create_verification_attempt_record!(
        Map.merge(copy_inputs.(verification), %{
          operation_id: next_operation.id,
          proposal_id: next_proposal.id
        }),
        authorize?: false
      )
    end

    for index <- 1..99 do
      Cases.append_evidence!(
        incident.id,
        operation.resolution_run_id,
        nil,
        "public-summary:#{index}",
        "operation_outcome",
        "operation",
        operation.id,
        %{"target_id" => setup.target.id},
        saved.completed_at,
        authorize?: false
      )
    end

    for token <- [context.operator_token, context.viewer_token] do
      response = get_json("/api/v1/cases/#{incident.id}/evidence?limit=100", token)
      assert_operation_response(response)
      body = json_response(response, 200)
      receipt = Enum.find(body["data"], &(&1["source_ref"] == operation.id))
      refute Map.has_key?(receipt, "content")
      assert receipt["summary"]["status"] == "applied"
      assert receipt["summary"]["target_id"] == setup.target.id
      assert length(body["data"]) == 100
      assert byte_size(response.resp_body) < 100_000
      query = URI.encode_query(%{"limit" => 100, "after" => body["page"]["next"]})
      next = get_json("/api/v1/cases/#{incident.id}/evidence?#{query}", token)
      assert_operation_response(next)
      tail = json_response(next, 200)
      assert length(tail["data"]) == 1
      assert tail["page"]["next"] == nil
      assert length(Enum.uniq_by(body["data"] ++ tail["data"], & &1["id"])) == 101

      response = get_json("/api/v1/evidence/#{receipt["id"]}", token)
      assert_operation_response(response)
      receipt = json_response(response, 200)["data"]
      assert receipt["content"]["details"] == expected_details
      assert receipt["content"]["reference"] == expected_reference
      assert receipt["content"]["parameters"] == %{"service" => "api"}
      assert receipt["content"]["tool_id"] == proposal.tool_id
      refute Map.has_key?(receipt, "stored_content")

      root = Path.join(System.tmp_dir!(), "evidence-cli-#{System.unique_integer([:positive])}")
      config_path = Path.join(root, "config.json")

      :ok =
        SkoposCLI.Config.save(
          %{"server" => "https://skopos.example", "token" => token},
          config_path
        )

      on_exit(fn -> File.rm_rf(root) end)
      stub = {__MODULE__, make_ref()}
      Req.Test.stub(stub, &SkoposWeb.Endpoint.call(&1, SkoposWeb.Endpoint.init([])))
      runtime = [config_path: config_path, request_options: [plug: {Req.Test, stub}]]

      listed =
        capture_io(fn ->
          assert SkoposCLI.CLI.run(["case", "evidence", incident.id, "--limit", "100"], runtime) ==
                   0
        end)

      assert length(Jason.decode!(listed)["data"]) == 100
      assert byte_size(listed) < 100_000

      shown =
        capture_io(fn ->
          assert SkoposCLI.CLI.run(["evidence", "show", receipt["id"]], runtime) == 0
        end)

      assert Jason.decode!(shown)["data"]["content"] == receipt["content"]

      response = get_json("/api/v1/operations/#{operation.id}", token)
      assert_operation_response(response)
      assert json_response(response, 200)["data"]["reference"] == expected_reference
      assert json_response(response, 200)["data"]["result_details"] == expected_details

      response = get_json("/api/v1/cases/#{incident.id}", token)
      assert_operation_response(response)
      snapshot = json_response(response, 200)["data"]
      assert byte_size(response.resp_body) < 500_000
      assert length(snapshot["operations"]) == 100
      assert length(snapshot["proposals"]) == 100
      refute Map.has_key?(hd(snapshot["proposals"]), "parameters")
      refute Map.has_key?(hd(snapshot["operations"]), "reference")
      refute Map.has_key?(hd(snapshot["operations"]), "result_details")
      refute Map.has_key?(hd(snapshot["verification_attempts"]), "operation_reference")

      reconnected =
        capture_io(fn ->
          assert SkoposCLI.CLI.run(["case", "show", incident.id], runtime) == 10
        end)

      assert byte_size(reconnected) < 500_000
      assert Jason.decode!(reconnected)["data"]["operations"] == snapshot["operations"]

      for {collection, original_id, command} <- [
            {"turns", source_turn.id, "turns"},
            {"proposals", proposal.id, "proposals"},
            {"operations", operation.id, "operations"},
            {"verification-attempts", verification.id, "verifications"}
          ] do
        first = get_json("/api/v1/cases/#{incident.id}/#{collection}?limit=100", token)
        assert_operation_response(first)
        first_page = json_response(first, 200)
        assert length(first_page["data"]) == 100
        assert byte_size(first.resp_body) < 150_000
        refute Enum.any?(first_page["data"], &(&1["id"] == original_id))
        query = URI.encode_query(%{"limit" => 100, "after" => first_page["page"]["next"]})
        tail = get_json("/api/v1/cases/#{incident.id}/#{collection}?#{query}", token)
        assert_operation_response(tail)

        assert %{"data" => [%{"id" => ^original_id}], "page" => %{"next" => nil}} =
                 json_response(tail, 200)

        cli_page =
          capture_io(fn ->
            assert SkoposCLI.CLI.run(
                     [
                       "case",
                       command,
                       incident.id,
                       "--limit",
                       "100",
                       "--after",
                       first_page["page"]["next"]
                     ],
                     runtime
                   ) == 0
          end)

        assert [%{"id" => ^original_id}] = Jason.decode!(cli_page)["data"]
        assert get_json("/api/v1/cases/#{incident.id}/#{collection}", nil).status == 401

        if collection in ["proposals", "turns"] do
          {singular, column, body_key, read, page_read} =
            case collection do
              "proposals" ->
                {"proposal", "parameters", "parameters", &Cases.get_proposal/2,
                 &Cases.page_case_proposals/2}

              "turns" ->
                {"turn", "intent", "intent", &Cases.get_turn/2, &Cases.page_case_turns/2}
            end

          maximum = get_json("/api/v1/cases/#{incident.id}/#{collection}?limit=500", token)
          assert_operation_response(maximum)
          assert json_response(maximum, 422)["error"]["code"] == "invalid_pagination"

          assert {:ok, maximum} =
                   page_read.(incident.id, actor: context.operator, page: [limit: 500])

          assert length(maximum.results) == 101

          assert Enum.all?(
                   maximum.results,
                   &(not Ash.Resource.selected?(&1, String.to_existing_atom(column)))
                 )

          if collection == "turns",
            do: assert(Enum.all?(maximum.results, &(not Ash.Resource.selected?(&1, :result))))

          selected_id = hd(first_page["data"])["id"]
          assert get_json("/api/v1/#{collection}/#{selected_id}", nil).status == 401
          selected = get_json("/api/v1/#{collection}/#{selected_id}", token)
          assert_operation_response(selected)
          selected_body = json_response(selected, 200)["data"]

          expected_padding =
            if collection == "turns",
              do: intent_padding,
              else: padded_proposal_fields.parameters["padding"]

          assert selected_body[body_key]["padding"] == expected_padding

          if collection == "turns",
            do: assert(selected_body["decision"]["padding"] == decision_padding)

          if collection == "proposals" do
            for field <-
                  ~w(selectors parameters expected_result verification_intent verification_tool)a do
              assert selected_body[Atom.to_string(field)] ==
                       Map.fetch!(padded_proposal_fields, field)
            end
          end

          exact =
            capture_io(fn ->
              assert SkoposCLI.CLI.run([singular, "show", selected_id], runtime) == 0
            end)

          assert Jason.decode!(exact)["data"] == selected_body

          Skopos.Repo.query!(
            "ALTER TABLE #{collection} RENAME COLUMN #{column} TO unavailable_#{column}"
          )

          try do
            assert {:ok, page} = page_read.(incident.id, actor: context.operator)
            assert length(page.results) == 100

            assert {:error, %Ash.Error.Unknown{} = cause} =
                     read.(selected_id, actor: context.operator)

            assert Exception.message(cause) =~ "does not exist"

            capture_log(fn ->
              assert get_json("/api/v1/cases/#{incident.id}", token).status == 200
              assert get_json("/api/v1/#{collection}/#{selected_id}", token).status == 500

              capture_io(:stderr, fn ->
                assert SkoposCLI.CLI.run([singular, "show", selected_id], runtime) == 4
              end)
            end)
          after
            Skopos.Repo.query!(
              "ALTER TABLE #{collection} RENAME COLUMN unavailable_#{column} TO #{column}"
            )
          end

          assert json_response(get_json("/api/v1/#{collection}/#{selected_id}", token), 200)[
                   "data"
                 ] ==
                   selected_body
        end

        {table, column, read} =
          case collection do
            "turns" ->
              {"turns", "status", &Cases.page_case_turns/2}

            "proposals" ->
              {"proposals", "status", &Cases.page_case_proposals/2}

            "operations" ->
              {"operations", "outcome_category", &Cases.page_case_operations/2}

            "verification-attempts" ->
              {"verification_attempts", "outcome_category", &Cases.page_case_verifications/2}
          end

        Skopos.Repo.query!(
          "ALTER TABLE #{table} RENAME COLUMN #{column} TO unavailable_#{column}"
        )

        try do
          assert {:error, %Ash.Error.Unknown{}} =
                   read.(incident.id, actor: context.operator, page: [limit: 100])

          capture_log(fn ->
            failed = get_json("/api/v1/cases/#{incident.id}/#{collection}", token)
            assert json_response(failed, 500)["error"]["code"] == "internal_error"
            assert_operation_response(failed)

            capture_io(:stderr, fn ->
              assert SkoposCLI.CLI.run(["case", command, incident.id], runtime) == 4
            end)
          end)
        after
          Skopos.Repo.query!(
            "ALTER TABLE #{table} RENAME COLUMN unavailable_#{column} TO #{column}"
          )
        end

        assert get_json("/api/v1/cases/#{incident.id}/#{collection}?#{query}", token).status ==
                 200

        refute_receive {:effect, _, _}, 0
        refute_receive {:resolve, _, _}, 0
      end

      response = get_json("/api/v1/verification-attempts/#{verification.id}", token)
      assert_operation_response(response)
      assert json_response(response, 200)["data"]["operation_reference"] == expected_reference
    end

    assert get_json("/api/v1/cases/#{incident.id}/evidence", nil).status == 401

    receipt =
      Cases.list_evidence!(actor: context.operator) |> Enum.find(&(&1.source_ref == operation.id))

    assert get_json("/api/v1/evidence/#{receipt.id}", nil).status == 401
    assert get_json("/api/v1/evidence/not-a-uuid", context.viewer_token).status == 422

    assert get_json("/api/v1/evidence/#{Ecto.UUID.generate()}", context.viewer_token).status ==
             404
  end

  @tag unicode_evidence_summary: true
  test "display labels bound Unicode codepoints while exact evidence remains available",
       context do
    incident = open_case!(context.operator_token, "unicode-evidence-label")
    run = Cases.active_resolution_run!(incident["id"], authorize?: false)
    title = "A" <> String.duplicate("\u0301", 32_000)

    evidence =
      Cases.append_evidence!(
        incident["id"],
        run.id,
        nil,
        "unicode-label",
        "signal_event",
        "fixture",
        "unicode-label",
        %{"state" => "firing", "attributes" => %{"title" => title}},
        DateTime.utc_now(),
        authorize?: false
      )

    response = get_json("/api/v1/cases/#{incident["id"]}/evidence", context.viewer_token)
    assert_operation_response(response)
    [summary] = json_response(response, 200)["data"]
    assert byte_size(summary["summary"]["title"]) <= 800
    response = get_json("/api/v1/evidence/#{evidence.id}", context.viewer_token)
    assert json_response(response, 200)["data"]["content"]["attributes"]["title"] == title
  end

  defp resume_input(incident, run, expected_run_revision) do
    %{
      "expected_case_revision" => incident.revision,
      "resolution_run_id" => run.id,
      "expected_run_revision" => expected_run_revision,
      "authority_mode" => Atom.to_string(run.authority_mode),
      "max_elapsed_seconds" => run.max_elapsed_seconds + 60,
      "max_resolver_turns" => run.max_resolver_turns + 1,
      "max_target_requests" => run.max_target_requests,
      "max_effects" => run.max_effects,
      "max_related_targets" => run.max_related_targets,
      "max_ai_usage_units" => run.max_ai_usage_units,
      "max_no_progress_turns" => run.max_no_progress_turns,
      "reason" => "extend the bounded investigation"
    }
  end

  defp proposal_setup!(context, opts \\ []) do
    provider =
      Providers.create_provider!(
        "workflow-target-provider",
        :target,
        "fixture-target",
        %{"endpoint" => "reachable"},
        %{"token" => Keyword.get(opts, :token, "provider-secret")},
        actor: context.admin
      )
      |> then(&Providers.enable_provider!(&1, 1, actor: context.admin))

    target =
      Targets.create_target!("workflow-linux", "host", "linux", %{}, nil, actor: context.admin)

    method =
      Targets.create_access_method!(
        target.id,
        provider.id,
        "workflow-ssh",
        "ssh",
        "ssh://workflow-linux",
        provider.revision,
        10,
        ["effect.service", "observe.service"],
        actor: context.admin
      )
      |> then(&Targets.check_access_method!(&1.id, &1.revision, %{}, actor: context.admin))

    resolver =
      Providers.create_provider!(
        "workflow-resolver",
        :ai,
        "fixture-ai",
        %{"model" => "resolver-model"},
        %{"api_key" => "resolver-secret"},
        actor: context.admin
      )
      |> then(&Providers.check_provider!(&1.id, 1, %{}, actor: context.admin))
      |> then(&Providers.enable_provider!(&1, 1, actor: context.admin))

    assignment =
      Skopos.TestAIUsage.configure!(resolver.id, :resolver, 10, context.admin)
      |> Map.fetch!(:resolver)

    reviewer =
      Providers.create_provider!(
        "workflow-reviewer",
        :ai,
        "fixture-ai",
        %{"model" => "reviewer-model"},
        %{"api_key" => "reviewer-secret"},
        actor: context.admin
      )
      |> then(&Providers.check_provider!(&1.id, 1, %{}, actor: context.admin))
      |> then(&Providers.enable_provider!(&1, 1, actor: context.admin))

    reviewer_assignment =
      Skopos.TestAIUsage.configure!(reviewer.id, :reviewer, 10, context.admin)
      |> Map.fetch!(:reviewer)

    %{
      provider: provider,
      target: target,
      method: method,
      resolver: resolver,
      assignment: assignment,
      reviewer: reviewer,
      reviewer_assignment: reviewer_assignment
    }
  end

  defp awaiting_proposal!(setup, operator) do
    incident =
      Cases.open_case!(
        :manual,
        "api",
        "proposal-1",
        "Restart unhealthy service",
        :warning,
        %{"desired_outcome" => "Target responds as expected"},
        setup.target.id,
        :en,
        actor: operator
      )

    run = Cases.active_resolution_run!(incident.id, authorize?: false)

    evidence =
      Cases.append_evidence!(
        incident.id,
        run.id,
        nil,
        "workflow-evidence",
        "observation",
        "fixture",
        "observation-1",
        %{"service" => "unhealthy"},
        DateTime.utc_now(),
        authorize?: false
      )

    started =
      Cases.start_turn!(
        incident.id,
        run.id,
        "workflow-turn",
        %{"objective" => "Restore the service"},
        %{"action" => "continue"},
        "Review Resolver limits",
        authorize?: false
      )

    turn =
      Cases.complete_turn!(
        started.value.id,
        started.value.revision,
        %{
          "outcome" => "decision",
          "intent" => proposal_intent(evidence.id, setup),
          "resolver" => %{
            "provider_id" => setup.resolver.id,
            "provider_revision" => setup.resolver.revision,
            "assignment_id" => setup.assignment.id,
            "assignment_revision" => setup.assignment.revision
          },
          "usage" => %{"input_tokens" => 1, "output_tokens" => 1}
        },
        :proposal,
        %{"action" => "route_resolver_decision", "turn_id" => started.value.id},
        "Review the Resolver decision",
        authorize?: false
      ).value

    proposal = Cases.materialize_proposal!(turn.id, authorize?: false)
    {incident, Cases.route_proposal_authority!(proposal.id, authorize?: false)}
  end

  defp proposal_intent(evidence_id, setup) do
    tool = %{
      "request_kind" => "effect",
      "id" => "effect-tool",
      "target_id" => setup.target.id,
      "target_revision" => setup.target.revision,
      "access_method_id" => setup.method.id,
      "access_method_revision" => setup.method.revision,
      "provider_id" => setup.provider.id,
      "provider_revision" => setup.provider.revision,
      "capability" => "effect.service",
      "operation" => "service.restart"
    }

    %{
      "type" => "proposal",
      "delay_seconds" => 0,
      "purpose" => "remediation",
      "request_kind" => "effect",
      "tool_id" => tool["id"],
      "target_id" => tool["target_id"],
      "target_revision" => tool["target_revision"],
      "access_method_id" => tool["access_method_id"],
      "access_method_revision" => tool["access_method_revision"],
      "capability" => tool["capability"],
      "operation" => tool["operation"],
      "selectors" => %{"service" => "api"},
      "parameters" => %{"service" => "api"},
      "reason" => "Restart the unhealthy API service",
      "evidence_ids" => [evidence_id],
      "affected_conditions" => [],
      "expected_result" => %{"service" => "running"},
      "tool" => tool,
      "verification_intent" => %{
        "tool_id" => "verification-tool",
        "selectors" => %{"service" => "api"},
        "parameters" => %{"service" => "api"},
        "expected_result" => %{"service" => "running"}
      },
      "verification_tool" => %{
        "id" => "verification-tool",
        "target_id" => setup.target.id,
        "target_revision" => setup.target.revision,
        "access_method_id" => setup.method.id,
        "access_method_revision" => setup.method.revision,
        "provider_id" => setup.provider.id,
        "provider_revision" => setup.provider.revision,
        "capability" => "observe.service",
        "operation" => "service.inspect"
      }
    }
  end

  defp configure_mode!(mode, admin) do
    current = Cases.current_authority_setting!(actor: admin)

    Cases.configure_authority_setting!(
      current.setting_revision,
      mode,
      current.signal_automation_enabled,
      current.max_elapsed_seconds,
      current.max_resolver_turns,
      current.max_target_requests,
      current.max_effects,
      current.max_related_targets,
      current.max_ai_usage_units,
      current.max_no_progress_turns,
      "workflow API mode",
      actor: admin
    )
  end

  defp open_case!(token, source_ref, severity \\ "warning") do
    response =
      post_json(
        "/api/v1/cases",
        %{
          "case" => %{
            "trigger_kind" => "manual",
            "source" => "api",
            "source_ref" => source_ref,
            "title" => "Investigate #{source_ref}",
            "severity" => severity,
            "initial_context" => %{"desired_outcome" => "Target responds as expected"}
          }
        },
        token
      )

    assert_operation_response(response)

    response
    |> json_response(201)
    |> Map.fetch!("data")
  end

  defp get_data!(path, token) do
    response = get_json(path, token)
    assert_operation_response(response)
    response |> json_response(200) |> Map.fetch!("data")
  end

  defp token!(email) do
    request(
      :post,
      "/api/v1/sessions",
      %{"session" => %{"email" => to_string(email), "password" => @password}},
      nil
    )
    |> json_response(201)
    |> get_in(["data", "token"])
  end

  defp get_json(path, token), do: request(:get, path, nil, token)
  defp post_json(path, body, token), do: request(:post, path, body, token)
  defp put_json(path, body, token), do: request(:put, path, body, token)
  defp patch_json(path, body, token), do: request(:patch, path, body, token)

  defp request(method, path, body, token) do
    build_json_conn(body)
    |> maybe_authorize(token)
    |> dispatch_request(method, path, body)
  end

  defp dispatch_request(conn, :get, path, _body), do: get(conn, path)
  defp dispatch_request(conn, :post, path, body), do: post(conn, path, body)
  defp dispatch_request(conn, :put, path, body), do: put(conn, path, body)
  defp dispatch_request(conn, :patch, path, body), do: patch(conn, path, body)

  defp maybe_authorize(conn, nil), do: conn
  defp maybe_authorize(conn, token), do: put_req_header(conn, "authorization", "Bearer " <> token)
end
