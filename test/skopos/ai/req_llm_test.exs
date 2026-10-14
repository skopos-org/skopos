defmodule Skopos.AI.ReqLLMTest do
  use Skopos.DataCase, async: false

  alias Skopos.Accounts
  alias Skopos.AI.ReqLLM, as: Adapter
  alias Skopos.Providers
  alias Skopos.Providers.AI

  import ExUnit.CaptureLog

  alias Skopos.AIHTTPFixture, as: ProviderStub

  setup do
    agent = start_supervised!({Agent, fn -> %{mode: {:decision, handoff()}, requests: []} end})

    server =
      start_supervised!({Bandit, plug: {ProviderStub, agent}, port: 0, startup_log: false})

    {:ok, {_address, port}} = ThousandIsland.listener_info(server)

    %{agent: agent, endpoint: "http://127.0.0.1:#{port}"}
  end

  test "model output defaults reach Resolver requests within the remaining Case budget",
       context do
    state =
      state!("anthropic", context.endpoint, %{"api_key" => "test-secret"}, %{
        "model" => "claude-sonnet-4-5"
      })

    request = resolver_request()
    request = %{request | budget: %{request.budget | remaining_tokens: 100_000}}
    assert {:ok, _} = Adapter.resolve(state, request, %{})
    [sent] = requests(context.agent)
    assert Jason.decode!(sent.body)["max_tokens"] == 64_000

    set_mode(context.agent, {:decision, handoff()})
    request = %{request | budget: %{request.budget | remaining_tokens: 1_000}}
    assert {:ok, _} = Adapter.resolve(state, request, %{})
    [sent] = requests(context.agent)
    assert Jason.decode!(sent.body)["max_tokens"] == 1_000
  end

  test "explicit output overrides and unknown-model defaults retain the Case ceiling", context do
    request = resolver_request()
    request = %{request | budget: %{request.budget | remaining_tokens: 100_000}}

    for {configuration, expected} <- [{%{}, 4_096}, {%{"max_tokens" => 65_536}, 65_536}] do
      state =
        state!("openai", context.endpoint <> "/v1", %{"api_key" => "test-secret"}, configuration)

      set_mode(context.agent, {:decision, handoff()})
      assert {:ok, _} = Adapter.resolve(state, request, %{})
      [sent] = requests(context.agent)
      assert Jason.decode!(sent.body)["max_tokens"] == expected

      set_mode(context.agent, {:decision, handoff()})
      bounded = %{request | budget: %{request.budget | remaining_tokens: 1_000}}
      assert {:ok, _} = Adapter.resolve(state, bounded, %{})
      [sent] = requests(context.agent)
      assert Jason.decode!(sent.body)["max_tokens"] == 1_000
    end
  end

  test "generate_object preserves the exact file binding offered by each file-bearing Method",
       context do
    reference = %{
      "id" => "05a8c403-9e38-4f1b-a037-c464e0385b66",
      "target_id" => "16e3f9a0-66b1-48e1-ae07-d5552f4e90f8",
      "name" => "input.bin",
      "media_type" => "application/octet-stream",
      "size_bytes" => 5,
      "sha256" => "b55f1659c0645fd1cee6dfa8b3af06795e9da7e48cb65c2b999f896c9f539dbd"
    }

    for {type, operation, input} <- [
          {"ssh", "sftp.write_file", %{"path" => "/validation/input.bin"}},
          {"restconf", "request.execute",
           %{
             "method" => "PUT",
             "path" => "/data/example:input",
             "headers" => %{"X-Proof" => "arbitrary-value"}
           }},
          {"http-api", "request.execute", %{"method" => "PUT", "path" => "/binary"}},
          {"redfish", "request.execute", %{"method" => "POST", "uri" => "/redfish/v1/Oem/Input"}},
          {"kubernetes-api", "request.execute",
           %{"method" => "POST", "path" => "/apis/example.test/v1/widgets"}}
        ],
        provider <- ["openai", "anthropic"] do
      {:ok, adapter} = Providers.Registry.fetch(type)
      endpoint = if type == "ssh", do: "ssh://127.0.0.1:9", else: "https://127.0.0.1:9"
      {configuration, credentials} = Skopos.TargetConnectionFixture.input(type, endpoint)
      {:ok, transport} = adapter.build(configuration, credentials)

      {:ok, transport} =
        adapter.bind_connection(transport, %Skopos.Providers.Target.Connection{
          endpoint: endpoint
        })

      {:ok, catalog} = adapter.capabilities(transport, %{})
      upload = Enum.find(catalog.effects, &(&1.operation == operation))

      tool = %{
        proposal_tool()
        | target_id: reference["target_id"],
          operation: upload.operation,
          capability: upload.capability,
          input_schema: upload.input_schema
      }

      request = %{
        resolver_request()
        | selected_target_id: tool.target_id,
          selected_target_revision: tool.target_revision,
          proposal_tools: [tool],
          evidence: [
            %AI.Evidence{
              id: "attachment-source",
              kind: "manual_context",
              target_id: tool.target_id,
              content: %{"files" => %{"payload" => reference}}
            }
          ]
      }

      parameters =
        Map.merge(input, %{"body_file" => "payload", "files" => %{"payload" => reference}})

      wire = %{
        "reason" => "Send the exact supplied file through the selected Method",
        "intent" => %{
          "type" => "proposal",
          "delay_seconds" => 30,
          "purpose" => "investigation",
          "action" => %{
            "tool_id" => tool.id,
            "selectors_json" => "{}",
            "parameters_json" => Jason.encode!(parameters)
          },
          "evidence_ids" => [],
          "affected_conditions" => []
        }
      }

      set_mode(context.agent, {:decision, wire})
      ai_endpoint = if provider == "openai", do: context.endpoint <> "/v1", else: context.endpoint
      state = state!(provider, ai_endpoint, %{"api_key" => "file-secret"})
      assert {:ok, decision} = Adapter.resolve(state, request, %{})
      assert decision.intent.parameters == parameters
      assert decision.intent.delay_seconds == 30
      assert :ok = AI.Validator.validate_decision(:resolve, decision, request)

      if type == "restconf" do
        invalid = %{
          decision
          | intent: %{
              decision.intent
              | parameters: Map.put(parameters, "uri", "https://127.0.0.1:9/data/example:input")
            }
        }

        assert {:error, %AI.Error{category: :invalid_output}} =
                 AI.Validator.validate_decision(:resolve, invalid, request)
      end

      [sent] = requests(context.agent)
      assert {:ok, _} = JSV.validate(wire, JSV.build!(output_schema(sent)))
      assert sent.body =~ "parameters.files"
      assert sent.body =~ "body_file"

      {:ok, protocol_parameters, files} =
        Skopos.Providers.Target.FileReference.split(decision.intent.parameters)

      method_request = %Skopos.Providers.Target.MethodRequest{
        provider_revision: 1,
        connection: %Skopos.Providers.Target.Connection{endpoint: endpoint},
        capability: upload.capability,
        operation: upload.operation,
        selectors: %{},
        parameters: protocol_parameters,
        files: files
      }

      assert {:ok, %{kind: :effect}} =
               Skopos.Providers.Target.classify_request(adapter, transport, method_request)

      assert {:error, _, _} =
               Skopos.Providers.Target.classify_request(adapter, transport, %{
                 method_request
                 | files: %{}
               })
    end
  end

  test "continued investigation discloses current citations while retaining historical facts",
       context do
    tool = %{
      proposal_tool()
      | request_kind: :observation,
        capability: "observe.command",
        operation: "service.inspect"
    }

    historical = %AI.Evidence{
      id: "previous-run-observation",
      kind: "observation",
      target_id: tool.target_id,
      content: %{"service" => "api", "status" => "pending"}
    }

    request = %{
      resolver_request()
      | selected_target_id: tool.target_id,
        selected_target_revision: tool.target_revision,
        proposal_tools: [tool],
        historical_evidence: [historical]
    }

    wire = %{
      "reason" => "Observe the pending request after the disclosed delay",
      "intent" => %{
        "type" => "proposal",
        "delay_seconds" => 30,
        "purpose" => "investigation",
        "action" => %{
          "tool_id" => tool.id,
          "selectors_json" => Jason.encode!(%{"service" => "api"}),
          "parameters_json" => Jason.encode!(%{"grace_seconds" => 0})
        },
        "evidence_ids" => [],
        "affected_conditions" => []
      }
    }

    set_mode(context.agent, {:decision, wire})
    state = state!("openai", context.endpoint <> "/v1", %{"api_key" => "test-secret"})
    assert {:ok, decision} = Adapter.resolve(state, request, %{})
    assert :ok = AI.Validator.validate_decision(:resolve, decision, request)
    [sent] = requests(context.agent)
    payload = user_payload(sent)
    assert payload["investigation_evidence_ids"] == []

    assert [%{"id" => "previous-run-observation", "content" => %{"status" => "pending"}}] =
             payload["historical_evidence"]

    assert decision.intent.delay_seconds == 30
    stale = %{decision | intent: %{decision.intent | evidence_ids: ["previous-run-observation"]}}

    assert {:error, %AI.Error{category: :invalid_output}} =
             AI.Validator.validate_decision(:resolve, stale, request)
  end

  test "invalid encoded Method objects retain usage and never become Target inputs", context do
    tool = proposal_tool()
    request = %{resolver_request() | proposal_tools: [tool]}

    wire = %{
      "reason" => "Investigate with the selected Method",
      "intent" => %{
        "type" => "proposal",
        "delay_seconds" => 0,
        "purpose" => "investigation",
        "action" => %{
          "tool_id" => tool.id,
          "selectors_json" => Jason.encode!(%{"service" => "api"}),
          "parameters_json" => Jason.encode!(%{"grace_seconds" => 5})
        },
        "evidence_ids" => [],
        "affected_conditions" => []
      }
    }

    for provider <- ["openai", "anthropic"],
        field <- ["selectors_json", "parameters_json"],
        invalid <- ["{broken}", "[]", "null", ~s("not an object")] do
      endpoint = if provider == "openai", do: context.endpoint <> "/v1", else: context.endpoint
      state = state!(provider, endpoint, %{"api_key" => "decode-secret"})
      set_mode(context.agent, {:decision, put_in(wire, ["intent", "action", field], invalid)})

      assert {:error, :invalid_output, _, %AI.Usage{input_tokens: 7, output_tokens: 5},
              "decision_validation"} = Adapter.resolve(state, request, %{})
    end

    state = state!("openai", context.endpoint <> "/v1", %{"api_key" => "decode-secret"})

    wrong_type =
      put_in(
        wire,
        ["intent", "action", "parameters_json"],
        Jason.encode!(%{"grace_seconds" => "5"})
      )

    set_mode(context.agent, {:decision, wrong_type})
    assert {:ok, decoded} = Adapter.resolve(state, request, %{})
    assert decoded.intent.parameters == %{"grace_seconds" => "5"}

    assert {:error, %AI.Error{category: :invalid_output}} =
             AI.Validator.validate_decision(:resolve, decoded, request)
  end

  test "generate_object binds an offered file range to its exact source", context do
    reference = %{
      "id" => "05a8c403-9e38-4f1b-a037-c464e0385b66",
      "target_id" => "16e3f9a0-66b1-48e1-ae07-d5552f4e90f8",
      "name" => "native-response.bin",
      "media_type" => "application/octet-stream",
      "size_bytes" => 5,
      "sha256" => "b55f1659c0645fd1cee6dfa8b3af06795e9da7e48cb65c2b999f896c9f539dbd"
    }

    source = %AI.Evidence{
      id: "source-1",
      kind: "observation",
      target_id: reference["target_id"],
      content: %{"facts" => %{"steps" => [%{"file" => reference}]}}
    }

    request = %{
      resolver_request()
      | selected_target_id: reference["target_id"],
        selected_target_revision: 1,
        evidence: [source],
        disclosure: %{
          disclosure()
          | allowed_target_ids: [reference["target_id"]],
            allowed_evidence_kinds: ["observation"]
        }
    }

    for provider <- ["openai", "anthropic"] do
      endpoint = if provider == "openai", do: context.endpoint <> "/v1", else: context.endpoint
      state = state!(provider, endpoint, %{"api_key" => "file-secret"})

      set_mode(
        context.agent,
        {:decision,
         %{
           "type" => "file_read",
           "file_ref" => "file-1",
           "offset" => 1,
           "length" => 3,
           "reason" => "Inspect the response"
         }}
      )

      assert {:ok,
              %AI.ResolverDecision{
                intent: %AI.FileRead{
                  source_evidence_id: "source-1",
                  reference: ^reference,
                  offset: 1,
                  length: 3
                },
                usage: %AI.Usage{input_tokens: 7, output_tokens: 5}
              }} = Adapter.resolve(state, request, %{})

      [sent] = requests(context.agent)
      payload = user_payload(sent)

      assert payload["file_read_options"] == [
               %{
                 "file_ref" => "file-1",
                 "source_evidence_id" => "source-1",
                 "reference" => reference
               }
             ]

      variant =
        Enum.find(
          output_schema(sent)["properties"]["intent"]["anyOf"],
          &(get_in(&1, ["properties", "type", "enum"]) == ["file_read"])
        )

      assert variant["properties"]["file_ref"]["enum"] == ["file-1"]
      assert variant["properties"]["length"]["maximum"] == 8192
      refute sent.body =~ "file-secret"
    end
  end

  test "one adapter handles OpenAI and Anthropic without putting credentials in prompts",
       context do
    providers = [
      {"openai", context.endpoint <> "/v1", %{"api_key" => "openai-secret"}},
      {"anthropic", context.endpoint, %{"api_key" => "anthropic-secret"}}
    ]

    for {provider, endpoint, credentials} <- providers do
      state = state!(provider, endpoint, credentials)

      assert {:ok,
              %AI.ResolverDecision{
                intent: %AI.Handoff{reason: "probe", required_input: "human"},
                usage: %AI.Usage{input_tokens: 7, output_tokens: 5}
              }} = Adapter.resolve(state, resolver_request(), %{})
    end

    requests = requests(context.agent)

    assert Enum.map(requests, & &1.path) == [
             "/v1/chat/completions",
             "/v1/messages"
           ]

    refute Enum.any?(requests, &String.contains?(&1.body, "openai-secret"))
    refute Enum.any?(requests, &String.contains?(&1.body, "anthropic-secret"))
    assert Enum.all?(requests, &String.contains?(&1.body, "report_language"))
    assert Enum.all?(requests, &String.contains?(&1.body, "human-facing reason"))

    assert Enum.all?(requests, &String.contains?(&1.body, "one intent allowed"))
    assert Enum.all?(requests, &String.contains?(&1.body, "expected_result_json"))

    assert Enum.all?(requests, fn request ->
             String.contains?(request.body, "Recovery is a terminal intent") and
               String.contains?(request.body, "current observation") and
               String.contains?(request.body, "Do not propose remediation when") and
               String.contains?(request.body, "returned facts can directly establish") and
               String.contains?(request.body, "tool's verification_schema")
           end)

    for request <- requests do
      schema = output_schema(request)
      assert schema["additionalProperties"] == false
      assert MapSet.new(schema["required"]) == MapSet.new(Map.keys(schema["properties"]))
      assert schema["properties"]["reason"]["type"] == "string"

      if request.path != "/v1/messages" do
        assert schema["properties"]["reason"]["maxLength"] == 500
      end

      refute Map.has_key?(schema["properties"], "arguments_json")

      assert Enum.any?(schema["properties"]["intent"]["anyOf"], fn variant ->
               get_in(variant, ["properties", "type", "enum"]) == ["handoff"]
             end)

      target_search =
        Enum.find(schema["properties"]["intent"]["anyOf"], fn variant ->
          get_in(variant, ["properties", "type", "enum"]) == ["target_search"]
        end)

      handoff =
        Enum.find(schema["properties"]["intent"]["anyOf"], fn variant ->
          get_in(variant, ["properties", "type", "enum"]) == ["handoff"]
        end)

      if request.path != "/v1/messages" do
        assert get_in(target_search, ["properties", "query", "maxLength"]) == 200
        assert get_in(handoff, ["properties", "required_input", "maxLength"]) == 250
      end
    end
  end

  test "Resolver accepts a Target search query within the Target catalog limit", context do
    state = state!("openai", context.endpoint <> "/v1", %{"api_key" => "test-secret"})
    query = String.duplicate("a", 120)

    set_mode(
      context.agent,
      {:decision, %{"type" => "target_search", "reason" => "find", "query" => query}}
    )

    assert {:ok, %AI.ResolverDecision{intent: %AI.TargetSearch{query: ^query}}} =
             Adapter.resolve(state, resolver_request(), %{})
  end

  test "Resolver selects one of 22 mapped Targets by offered ref and carries its native citation",
       context do
    state = state!("openai", context.endpoint <> "/v1", %{"api_key" => "test-secret"})

    candidates =
      for index <- 1..22 do
        %AI.TargetCandidate{
          id: "target-#{index}",
          revision: 1,
          name: "node-#{index}",
          kind: "network_device",
          type_id: "custom-network-device",
          facts: %{}
        }
      end

    conditions =
      for index <- 1..22 do
        %AI.Condition{
          id: "condition-#{index}",
          revision: 1,
          occurrence: 1,
          predicate: "unavailable",
          subject_key: "node-#{index}",
          subject_ref: %{"name" => "node-#{index}"},
          state: :firing,
          target_id: "target-#{index}",
          current_occurred_at_us: 1
        }
      end

    evidence =
      for index <- 1..22 do
        %AI.Evidence{
          id: "source-#{index}",
          kind: "signal_event",
          target_id: "target-#{index}",
          content: %{
            "current" => true,
            "condition_id" => "condition-#{index}",
            "condition_revision" => 1
          }
        }
      end

    request = %{
      resolver_request()
      | conditions: conditions,
        evidence: evidence,
        target_candidates: candidates
    }

    set_mode(context.agent, {
      :decision,
      %{
        "reason" => "Investigate the independently signaled core node",
        "intent" => %{"type" => "target_selection", "candidate_ref" => "candidate-22"},
        "condition_groups" => [
          %{
            "condition_ids" => Enum.map(1..22, &"condition-#{&1}"),
            "assessment" => "unknown",
            "reason" => "The source events do not establish a common cause",
            "evidence_ids" => Enum.map(1..22, &"source-#{&1}")
          }
        ]
      }
    })

    assert {:ok,
            %AI.ResolverDecision{
              condition_groups: [group],
              intent: %AI.TargetSelection{
                target_id: "target-22",
                target_revision: 1,
                evidence_ids: ["source-22"]
              }
            }} = Adapter.resolve(state, request, %{})

    assert length(group["evidence_ids"]) == 22
    assert [^group] = AI.normalize_condition_groups([group], conditions, evidence)

    [wire] = requests(context.agent)
    payload = user_payload(wire)
    assert length(payload["target_candidates"]) == 22

    assert Enum.find(payload["target_candidates"], &(&1["candidate_ref"] == "candidate-22"))[
             "supporting_evidence_ids"
           ] == ["source-22"]

    selection_schema =
      Enum.find(output_schema(wire)["properties"]["intent"]["anyOf"], fn variant ->
        get_in(variant, ["properties", "type", "enum"]) == ["target_selection"]
      end)

    assert get_in(selection_schema, ["properties", "candidate_ref", "enum"]) ==
             Enum.map(1..22, &"candidate-#{&1}")

    refute Map.has_key?(selection_schema["properties"], "target_id")
    refute Map.has_key?(selection_schema["properties"], "evidence_ids")
  end

  test "Resolver object output carries optional bounded Condition hypotheses beside one intent",
       context do
    state = state!("openai", context.endpoint <> "/v1", %{"api_key" => "test-secret"})

    conditions =
      Enum.map(~w(condition-a condition-b), fn id ->
        %AI.Condition{
          id: id,
          revision: 1,
          occurrence: 1,
          predicate: "unavailable",
          subject_key: id,
          subject_ref: %{"name" => id},
          state: :firing,
          target_id: nil,
          current_occurred_at_us: 1
        }
      end)

    request = %{resolver_request() | conditions: conditions}

    group = %{
      "condition_ids" => ~w(condition-a condition-b),
      "assessment" => "unknown",
      "reason" => "The two alerts have no shared cause observation",
      "evidence_ids" => []
    }

    set_mode(context.agent, {
      :decision,
      %{
        "reason" => "Observe the affected devices",
        "intent" => %{"type" => "handoff", "required_input" => "Provide a safe observation"},
        "condition_groups" => [group]
      }
    })

    assert {:ok, %AI.ResolverDecision{condition_groups: [^group]}} =
             Adapter.resolve(state, request, %{})

    [wire] = requests(context.agent)
    assert output_schema(wire)["properties"]["condition_groups"]["maxItems"] == 32
    assert length(user_payload(wire)["conditions"]) == 2
  end

  test "Case split is a distinct Resolver intent with citations for both scopes", context do
    state = state!("openai", context.endpoint <> "/v1", %{"api_key" => "test-secret"})

    conditions =
      Enum.map(~w(condition-a condition-b), fn id ->
        %AI.Condition{
          id: id,
          revision: 1,
          occurrence: 1,
          predicate: "unavailable",
          subject_key: id,
          subject_ref: %{"name" => id},
          state: :firing,
          target_id: id,
          current_occurred_at_us: 1
        }
      end)

    evidence =
      Enum.map(conditions, fn condition ->
        %AI.Evidence{
          id: "observation-#{condition.id}",
          kind: "observation",
          target_id: condition.target_id,
          observed_at_us: 2,
          content: %{"status" => "applied", "target_id" => condition.target_id}
        }
      end)

    request = %{resolver_request() | conditions: conditions, evidence: evidence}

    source_only = %{
      request
      | evidence:
          Enum.map(conditions, fn condition ->
            %AI.Evidence{
              id: "source-#{condition.id}",
              kind: "signal_event",
              target_id: condition.target_id,
              observed_at_us: 2,
              content: %{"status" => "firing"}
            }
          end)
    }

    set_mode(context.agent, {
      :decision,
      %{
        "reason" => "Investigate both",
        "intent" => %{"type" => "target_search", "query" => "nodes"}
      }
    })

    assert {:ok, %AI.ResolverDecision{intent: %AI.TargetSearch{}}} =
             Adapter.resolve(state, source_only, %{})

    [source_wire] = requests(context.agent)
    refute "case_split" in user_payload(source_wire)["allowed_intents"]

    set_mode(context.agent, {
      :decision,
      %{
        "reason" => "Investigate both faults separately",
        "intent" => %{
          "type" => "case_split",
          "condition_ids" => ["condition-a"],
          "evidence_ids" => ["observation-condition-a"],
          "remaining_evidence_ids" => ["observation-condition-b"]
        }
      }
    })

    assert {:ok, %AI.ResolverDecision{intent: %AI.CaseSplit{condition_ids: ["condition-a"]}}} =
             Adapter.resolve(state, request, %{})

    [wire] = requests(context.agent)
    assert "case_split" in user_payload(wire)["allowed_intents"]
  end

  test "ReqLLM object responses retain usage when the returned schema is invalid", context do
    state = state!("openai", context.endpoint <> "/v1", %{"api_key" => "test-secret"})

    set_mode(context.agent, {:decision, handoff()})

    assert {:ok,
            %AI.ResolverDecision{
              intent: %AI.Handoff{reason: "probe", required_input: "human"},
              usage: %AI.Usage{input_tokens: 7, output_tokens: 5}
            }} = Adapter.resolve(state, resolver_request(), %{})

    [request] = requests(context.agent)
    body = Jason.decode!(request.body)

    assert get_in(body, ["tool_choice", "function", "name"]) == "structured_output"
    assert get_in(body, ["tools", Access.at(0), "function", "name"]) == "structured_output"
    refute Map.has_key?(body, "response_format")
    assert output_schema(hd(requests(context.agent)))["additionalProperties"] == false

    set_mode(context.agent, {:decision, %{"status" => "ready"}})
    assert :ok = Adapter.check(state, %{})

    set_mode(
      context.agent,
      {:decision,
       %{"verdict" => "approved", "purpose_assessment" => "remediation", "reason" => "bounded"}}
    )

    assert {:ok, %AI.ReviewDecision{verdict: :approved, reason: "bounded"}} =
             Adapter.review(state, review_request(), %{})

    set_mode(context.agent, {:decision, %{"unexpected" => true}})

    assert {:error, :invalid_output, _message, %AI.Usage{input_tokens: 7, output_tokens: 5},
            "schema_validation", _path} =
             Adapter.resolve(state, resolver_request(), %{})

    set_mode(context.agent, {:raw_text, "```json\n{\"status\":\"ready\"}\n```"})
    assert :ok = Adapter.check(state, %{})

    assert {:error, :invalid_output, _message, %AI.Usage{input_tokens: 7, output_tokens: 5},
            "schema_validation", _path} =
             Adapter.resolve(state, resolver_request(), %{})
  end

  test "ReqLLM repaired object output is rejected with metered usage", context do
    state = state!("openai", context.endpoint <> "/v1", %{"api_key" => "test-secret"})

    set_mode(
      context.agent,
      {:raw_tool_arguments,
       ~s({"reason":"probe","intent":{"type":"handoff","required_input":"human",},})}
    )

    assert {:error, :invalid_output, "AI provider output required repair",
            %AI.Usage{input_tokens: 7, output_tokens: 5}, "repair_required"} =
             Adapter.resolve(state, resolver_request(), %{})
  end

  @tag persisted_native_context: true
  test "a persisted Resolver invalidates an in-flight native assignment and continues without replaying it",
       context do
    alias Skopos.Cases
    alias Skopos.Cases.Turn.ResolverDelivery

    admin =
      Accounts.bootstrap!(
        "native-case-admin@example.com",
        "correct horse battery staple",
        "correct horse battery staple",
        authorize?: true
      )

    authority = Cases.current_authority_setting!(actor: admin)

    Cases.configure_authority_setting!(
      authority.setting_revision,
      :auto,
      true,
      600,
      4,
      5,
      2,
      3,
      100_000,
      2,
      "Allow bounded native interruption recovery",
      actor: admin
    )

    provider =
      Providers.create_provider!(
        "native-case-ai",
        :ai,
        Adapter.type(),
        %{
          "provider" => "openai",
          "model" => "test-model",
          "endpoint" => context.endpoint <> "/v1"
        },
        %{"api_key" => "native-case-secret"},
        actor: admin
      )
      |> then(&Providers.check_provider!(&1.id, 1, %{}, actor: admin))
      |> then(&Providers.enable_provider!(&1, 1, actor: admin))

    Skopos.TestAIUsage.configure!(provider.id, :resolver, 10, admin)

    incident =
      Cases.open_case!(
        :manual,
        "test",
        "native-case-context",
        "Investigate the unavailable service",
        :warning,
        %{"desired_outcome" => "The service responds"},
        nil,
        :en,
        actor: admin
      )

    run = Cases.active_resolution_run!(incident.id, authorize?: false)

    turn =
      Cases.start_turn!(
        incident.id,
        run.id,
        "native-case-turn",
        %{"objective" => "Resolve the incident"},
        %{"action" => "continue"},
        "Review Resolver limits",
        authorize?: false
      ).value

    changed = :atomics.new(1, [])
    set_mode(context.agent, {:sleep, 1_000})

    assert :ok =
             ResolverDelivery.run(turn.id,
               ai_invocation: %{
                 cancelled?: fn ->
                   if requests(context.agent) != [] and
                        :atomics.compare_exchange(changed, 1, 0, 1) == :ok,
                      do: Skopos.TestAIUsage.configure!(provider.id, :resolver, 11, admin)

                   false
                 end
               }
             )

    assert :atomics.get(changed, 1) == 1
    assert length(requests(context.agent)) == 1

    assert [
             %{
               status: :failed,
               category: "context_changed",
               dispatch_confirmed: true,
               usage_reported: false,
               reserved_units: reserved_units
             }
           ] = Cases.list_ai_invocations!(authorize?: false)

    assert reserved_units > 65_536
    assert reserved_units < 100_000
    assert Cases.get_resolution_run!(run.id, authorize?: false).ai_usage_units == reserved_units
    current = Cases.get_case!(incident.id, authorize?: false)
    assert current.status == :running
    assert current.pending_intent["action"] == "resolve_turn"
    next_id = current.pending_intent["turn_id"]
    refute next_id == turn.id

    set_mode(
      context.agent,
      {:decision,
       %{
         "type" => "target_search",
         "query" => "service host",
         "reason" => "Find the affected registered Target"
       }}
    )

    assert :ok = ResolverDelivery.run(next_id)
    assert length(requests(context.agent)) == 1

    assert Cases.get_resolution_run!(run.id, authorize?: false).ai_usage_units ==
             reserved_units + 12

    assert :ok = ResolverDelivery.run(turn.id)
    assert :ok = ResolverDelivery.run(next_id)
    assert length(requests(context.agent)) == 1

    assert Cases.get_resolution_run!(run.id, authorize?: false).ai_usage_units ==
             reserved_units + 12

    assert length(Cases.list_ai_invocations!(authorize?: false)) == 2
  end

  @tag invocation_read_fault: true
  test "a local read fault before each native AI role sends nothing and retains no-send accounting",
       context do
    admin =
      Accounts.bootstrap!(
        "unsent-read-admin@example.com",
        "correct horse battery staple",
        "correct horse battery staple",
        authorize?: true
      )

    provider =
      Providers.create_provider!(
        "unsent-read-ai",
        :ai,
        Adapter.type(),
        %{
          "provider" => "openai",
          "model" => "test-model",
          "endpoint" => context.endpoint <> "/v1"
        },
        %{"api_key" => "callback-secret"},
        actor: admin
      )
      |> then(&Providers.check_provider!(&1.id, 1, %{}, actor: admin))
      |> then(&Providers.enable_provider!(&1, 1, actor: admin))

    evidence = %AI.Evidence{
      id: "current-observation",
      kind: "observation",
      target_id: "target-1",
      content: %{"facts" => %{"service_state" => "active"}}
    }

    symptom_id = String.duplicate("c", 64)

    recovery_request = %AI.RecoveryReviewRequest{
      provider_revision: provider.revision,
      session_id: "recovery-reviewer",
      resolver_session_id: "recovery-resolver",
      case_id: "case-1",
      objective: "Restore service health",
      report_language: :en,
      conditions: [],
      case_symptom: %{
        id: symptom_id,
        text: "The service is unavailable",
        desired_outcome: "The service responds"
      },
      source_evidence: [],
      cited_evidence: [evidence],
      conclusion: %AI.RecoveryConclusion{
        reason: "The service responded",
        evidence_ids: [evidence.id],
        desired_outcome_claims: [
          %{
            "symptom_id" => symptom_id,
            "evidence_id" => evidence.id,
            "fact_keys" => ["service_state"],
            "reason" => "The service is active"
          }
        ]
      },
      budget: budget()
    }

    cancelled? = fn ->
      {:error, error} =
        Skopos.Repo.query("SELECT invocation_context_unavailable", [], mode: :savepoint)

      raise error
    end

    for {role, action, request} <- [
          {:resolve, &Providers.ai_resolve/4, resolver_request()},
          {:review, &Providers.ai_review/4, review_request()},
          {:review_recovery, &Providers.ai_review_recovery/4, recovery_request}
        ],
        phase <- [:provider_entry, :native_send] do
      assert :ok = AI.Validator.validate_request(role, request)
      set_mode(context.agent, {:decision, handoff()})
      checks = :atomics.new(1, [])

      before_send? = fn ->
        if phase == :native_send and :atomics.add_get(checks, 1, 1) == 1,
          do: false,
          else: cancelled?.()
      end

      assert {:error, error} =
               action.(
                 provider.id,
                 request,
                 %{before_send?: before_send?, cancelled?: fn -> false end},
                 actor: admin
               )

      assert AI.Error.context_failure?(error)
      assert Exception.message(error) =~ "invocation_context_unavailable"
      assert %AI.Error{category: :failed, dispatched?: false} = AI.Error.find(error)
      assert requests(context.agent) == []

      assert %{amount: 0, usage: nil, dispatched?: false} =
               Skopos.Cases.AIInvocation.failure_accounting(error, 65_536)
    end

    assert %{check_status: :passed} =
             Providers.check_provider!(provider.id, provider.revision, %{}, actor: admin)

    assert length(requests(context.agent)) == 1
  end

  @tag invocation_read_fault: true
  test "a local read fault during a native AI request retains its cause and dispatch accounting",
       context do
    admin =
      Accounts.bootstrap!(
        "invocation-read-admin@example.com",
        "correct horse battery staple",
        "correct horse battery staple",
        authorize?: true
      )

    provider =
      Providers.create_provider!(
        "invocation-read-ai",
        :ai,
        Adapter.type(),
        %{
          "provider" => "openai",
          "model" => "test-model",
          "endpoint" => context.endpoint <> "/v1"
        },
        %{"api_key" => "callback-secret"},
        actor: admin
      )
      |> then(&Providers.check_provider!(&1.id, 1, %{}, actor: admin))
      |> then(&Providers.enable_provider!(&1, 1, actor: admin))

    for fault <- [:storage, :classified_storage, :invalid_read] do
      set_mode(context.agent, {:sleep, 500})

      cancelled? = fn ->
        if requests(context.agent) == [] do
          false
        else
          if fault == :invalid_read do
            {:error, invalid} = Providers.get_provider("invalid-context-id", authorize?: false)
            raise invalid
          else
            {:error, cause} =
              Skopos.Repo.query("SELECT invocation_context_unavailable", [], mode: :savepoint)

            if fault == :classified_storage do
              {:error, invalid} = Providers.get_provider("invalid-context-id", authorize?: false)
              raise Ash.Error.to_error_class([invalid, cause])
            else
              raise cause
            end
          end
        end
      end

      assert {:error, error} =
               Providers.ai_resolve(provider.id, resolver_request(), %{cancelled?: cancelled?},
                 actor: admin
               )

      assert AI.Error.context_failure?(error)

      if fault == :invalid_read do
        assert Exception.message(error) =~ "id"
      else
        assert Exception.message(error) =~ "invocation_context_unavailable"
      end

      if fault != :storage, do: assert(match?(%Ash.Error.Invalid{}, error))
      assert %AI.Error{category: :failed, dispatched?: true} = AI.Error.find(error)
      assert length(requests(context.agent)) == 1

      assert %{amount: 65_536, usage: nil, dispatched?: true} =
               Skopos.Cases.AIInvocation.failure_accounting(error, 65_536)
    end

    set_mode(context.agent, {:decision, handoff()})

    assert %{check_status: :passed} =
             Providers.check_provider!(provider.id, provider.revision, %{}, actor: admin)

    assert length(requests(context.agent)) == 1
  end

  @tag completed_response_race: true
  test "cancellation during a slow context check preserves the received native decision and usage",
       context do
    admin =
      Accounts.bootstrap!(
        "received-response-admin@example.com",
        "correct horse battery staple",
        "correct horse battery staple",
        authorize?: true
      )

    provider =
      Providers.create_provider!(
        "received-response-ai",
        :ai,
        Adapter.type(),
        %{
          "provider" => "openai",
          "model" => "test-model",
          "endpoint" => context.endpoint <> "/v1"
        },
        %{"api_key" => "received-response-secret"},
        actor: admin
      )
      |> then(&Providers.check_provider!(&1.id, 1, %{}, actor: admin))
      |> then(&Providers.enable_provider!(&1, 1, actor: admin))

    set_mode(context.agent, {:decision, handoff()})

    cancelled? = fn ->
      # The remote response arrives while this waiting check is still blocked.
      Process.sleep(500)
      true
    end

    assert {:ok,
            %AI.ResolverDecision{
              usage: %AI.Usage{input_tokens: 7, output_tokens: 5}
            }} =
             Providers.ai_resolve(
               provider.id,
               resolver_request(),
               %{before_send?: fn -> false end, cancelled?: cancelled?},
               actor: admin
             )

    assert length(requests(context.agent)) == 1
  end

  @tag completed_response_race: true
  test "received buffered and streamed usage survives a deadline or context fault", context do
    admin =
      Accounts.bootstrap!(
        "response-races-admin@example.com",
        "correct horse battery staple",
        "correct horse battery staple",
        authorize?: true
      )

    for stream? <- [false, true] do
      mode = if stream?, do: :stream, else: :decision
      set_mode(context.agent, {mode, %{"status" => "ready"}})

      provider =
        Providers.create_provider!(
          "response-races-ai-#{stream?}",
          :ai,
          Adapter.type(),
          %{
            "provider" => "openai",
            "model" => "test-model",
            "endpoint" => context.endpoint <> "/v1",
            "stream" => stream?,
            "timeout_ms" => 1000
          },
          %{"api_key" => "response-races-secret"},
          actor: admin
        )
        |> then(&Providers.check_provider!(&1.id, 1, %{}, actor: admin))
        |> then(&Providers.enable_provider!(&1, 1, actor: admin))

      for stop <- [:cancel, :deadline, :read_fault] do
        set_mode(context.agent, {mode, handoff()})

        cancelled? = fn ->
          Process.sleep(if stop == :deadline, do: 1100, else: 500)

          case stop do
            :cancel ->
              true

            :deadline ->
              false

            :read_fault ->
              {:error, error} =
                Skopos.Repo.query("SELECT invocation_context_unavailable", [], mode: :savepoint)

              raise error
          end
        end

        assert {:ok,
                %AI.ResolverDecision{
                  usage: %AI.Usage{input_tokens: 7, output_tokens: 5}
                }} =
                 Providers.ai_resolve(
                   provider.id,
                   resolver_request(),
                   %{before_send?: fn -> false end, cancelled?: cancelled?},
                   actor: admin
                 )

        assert length(requests(context.agent)) == 1
      end

      set_mode(context.agent, {mode, %{"unexpected" => true}})

      cancelled? = fn ->
        Process.sleep(500)
        true
      end

      assert {:error, error} =
               Providers.ai_resolve(
                 provider.id,
                 resolver_request(),
                 %{before_send?: fn -> false end, cancelled?: cancelled?},
                 actor: admin
               )

      assert %AI.Error{
               category: :invalid_output,
               dispatched?: true,
               usage: %AI.Usage{input_tokens: 7, output_tokens: 5}
             } = AI.Error.find(error)

      assert %{amount: 12, dispatched?: true} =
               Skopos.Cases.AIInvocation.failure_accounting(error, 65_536)

      assert length(requests(context.agent)) == 1
    end
  end

  test "plain output requests preserve timeout and cancellation", context do
    state =
      state!("openai", context.endpoint <> "/v1", %{"api_key" => "test-secret"}, %{
        "timeout_ms" => 100
      })

    set_mode(context.agent, {:sleep, 500})
    assert {:error, :timeout, _message} = Adapter.resolve(state, resolver_request(), %{})

    set_mode(context.agent, {:sleep, 500})
    cancelled? = fn -> requests(context.agent) != [] end

    assert {:error, :cancelled, _message} =
             Adapter.resolve(state, resolver_request(), %{
               before_send?: fn -> false end,
               cancelled?: cancelled?
             })

    assert length(requests(context.agent)) == 1
  end

  test "object requests accept complete JSON text through the same schema and retain usage",
       context do
    state = state!("openai", context.endpoint <> "/v1", %{"api_key" => "test-secret"})

    set_mode(context.agent, {:raw_text, ~s({"status":"ready"})})
    assert :ok = Adapter.check(state, %{})

    valid = %{"reason" => "確認", "intent" => %{"type" => "handoff", "required_input" => "確認"}}
    set_mode(context.agent, {:raw_text, Jason.encode!(valid)})

    assert {:ok,
            %AI.ResolverDecision{
              intent: %AI.Handoff{reason: "確認", required_input: "確認"},
              usage: %AI.Usage{input_tokens: 7, output_tokens: 5}
            }} =
             Adapter.resolve(state, resolver_request(), %{})

    [request] = requests(context.agent)
    body = Jason.decode!(request.body)
    assert get_in(body, ["tools", Access.at(0), "function", "name"]) == "structured_output"
    refute Map.has_key?(body, "response_format")

    set_mode(
      context.agent,
      {:raw_text, ~s({"verdict":"rejected","purpose_assessment":"unknown","reason":"証拠不足"})}
    )

    assert {:ok,
            %AI.ReviewDecision{
              verdict: :rejected,
              reason: "証拠不足",
              usage: %AI.Usage{input_tokens: 7, output_tokens: 5}
            }} =
             Adapter.review(state, review_request(), %{})

    set_mode(
      context.agent,
      {:raw_text,
       ~s({"reason":"確認","intent":{"type":"handoff","required_input":"確認"},"extra":true})}
    )

    assert {:error, :invalid_output, _, %AI.Usage{input_tokens: 7, output_tokens: 5},
            "schema_validation", _path} =
             Adapter.resolve(state, resolver_request(), %{})

    set_mode(
      context.agent,
      {:raw_text, ~s({"reason":"bad","intent":{"type":"recovery","evidence_ids":["invented"]}})}
    )

    assert {:error, :invalid_output, _, %AI.Usage{input_tokens: 7, output_tokens: 5},
            "schema_validation", _path} =
             Adapter.resolve(state, resolver_request(), %{})

    set_mode(context.agent, {:raw_text, ~s({"reason":)})

    assert {:error, :invalid_output, _, %AI.Usage{input_tokens: 7, output_tokens: 5},
            "missing_structured_object"} =
             Adapter.resolve(state, resolver_request(), %{})

    set_mode(context.agent, {:raw_text, ~s(["not an object"])})

    assert {:error, :invalid_output, _, %AI.Usage{input_tokens: 7, output_tokens: 5},
            "missing_structured_object"} =
             Adapter.resolve(state, resolver_request(), %{})

    set_mode(context.agent, {:raw_text_length, Jason.encode!(valid)})

    assert {:error, :invalid_output, "AI provider JSON was truncated",
            %AI.Usage{finish_reason: "length"}, "truncated"} =
             Adapter.resolve(state, resolver_request(), %{})
  end

  test "Reviewer receives the registered Case Target link as inventory context", context do
    state = state!("openai", context.endpoint <> "/v1", %{"api_key" => "test-secret"})
    request = review_request()

    guest = %AI.TargetCandidate{
      id: "guest-1",
      revision: 1,
      name: "linux-r8",
      kind: "host",
      type_id: "linux",
      facts: %{}
    }

    host = %AI.TargetCandidate{
      id: request.proposal.target_id,
      revision: request.proposal.target_revision,
      name: "physical-host-r8",
      kind: "physical_host",
      type_id: "custom-physical-server",
      facts: %{}
    }

    relation = %AI.TargetRelation{
      id: "hosted-by-1",
      revision: 2,
      source_target: guest,
      destination_target: host,
      kind: "hosted_by",
      attributes: %{}
    }

    request = %{request | initial_target_id: guest.id, target_relations: [relation]}

    set_mode(
      context.agent,
      {:decision,
       %{"verdict" => "approved", "purpose_assessment" => "remediation", "reason" => "linked"}}
    )

    assert {:ok, %AI.ReviewDecision{verdict: :approved}} = Adapter.review(state, request, %{})

    [sent] = requests(context.agent)
    payload = reviewer_payload(sent)
    assert payload["case_initial_target_id"] == guest.id
    assert get_in(payload, ["registered_target_relations", Access.at(0), "id"]) == relation.id

    assert get_in(payload, ["registered_target_relations", Access.at(0), "source_target", "name"]) ==
             guest.name

    assert get_in(payload, [
             "registered_target_relations",
             Access.at(0),
             "destination_target",
             "id"
           ]) ==
             host.id
  end

  test "Reviewer distinguishes current recovery evidence from historical successful facts",
       context do
    state = state!("openai", context.endpoint <> "/v1", %{"api_key" => "test-secret"})

    request =
      review_request()
      |> Map.put(:resolution_run_id, "current-run")
      |> Map.put(:recovery_evidence_ids, ["evidence-1"])

    set_mode(
      context.agent,
      {:decision,
       %{"verdict" => "approved", "purpose_assessment" => "remediation", "reason" => "bounded"}}
    )

    assert {:ok, %AI.ReviewDecision{verdict: :approved}} = Adapter.review(state, request, %{})
    [sent] = requests(context.agent)
    payload = reviewer_payload(sent)
    assert payload["resolution_run_id"] == "current-run"
    assert payload["recovery_evidence_ids"] == ["evidence-1"]

    assert Enum.any?(
             payload["recent_case_evidence"],
             &(&1["id"] == "independent-responsive-guest")
           )

    system = hd(Jason.decode!(sent.body)["messages"])["content"]
    assert system =~ "Historical success does not establish the current outcome"
    assert system =~ "availability does not establish recovery"
  end

  test "Reviewer receives a bounded schema correction after a paid invalid response", context do
    state = state!("openai", context.endpoint <> "/v1", %{"api_key" => "test-secret"})

    request = %{
      review_request()
      | retry_context: %{
          "category" => "invalid_output",
          "rejection_code" => "schema_validation"
        }
    }

    set_mode(
      context.agent,
      {:decision,
       %{"verdict" => "rejected", "purpose_assessment" => "unknown", "reason" => "No proof"}}
    )

    assert {:ok, %AI.ReviewDecision{verdict: :rejected}} = Adapter.review(state, request, %{})

    assert reviewer_payload(hd(requests(context.agent)))["retry_context"] ==
             request.retry_context
  end

  test "Reviewer truncated retry requests a compact decision without relaxing its judgment",
       context do
    state = state!("openai", context.endpoint <> "/v1", %{"api_key" => "test-secret"})

    request = %{
      review_request()
      | retry_context: %{"category" => "invalid_output", "rejection_code" => "truncated"}
    }

    set_mode(
      context.agent,
      {:decision,
       %{
         "verdict" => "rejected",
         "purpose_assessment" => "unknown",
         "reason" => "Insufficient evidence"
       }}
    )

    assert {:ok, %AI.ReviewDecision{verdict: :rejected}} = Adapter.review(state, request, %{})
    [wire] = requests(context.agent)
    assert reviewer_payload(wire)["retry_context"] == request.retry_context

    assert Enum.any?(Jason.decode!(wire.body)["messages"], fn message ->
             message["role"] == "system" and
               String.contains?(message["content"], "rejection_code is truncated") and
               String.contains?(message["content"], "compact complete JSON object") and
               String.contains?(message["content"], "same evidence and safety requirements")
           end)
  end

  test "eligible Target traversal also permits handoff when operator input is needed",
       context do
    state = state!("openai", context.endpoint <> "/v1", %{"api_key" => "test-secret"})

    source = %AI.TargetCandidate{
      id: "target-1",
      revision: 1,
      name: "cluster",
      kind: "cluster",
      type_id: "kubernetes",
      facts: %{}
    }

    destination = %AI.TargetCandidate{
      id: "target-2",
      revision: 1,
      name: "host",
      kind: "host",
      type_id: "linux",
      facts: %{}
    }

    request = %{
      resolver_request()
      | selected_target_id: "target-1",
        selected_target_revision: 1,
        evidence: [
          %AI.Evidence{
            id: "evidence-1",
            kind: "observation",
            target_id: "target-1",
            content: %{"status" => "applied"}
          }
        ],
        target_relations: [
          %AI.TargetRelation{
            id: "relationship-1",
            revision: 1,
            source_target: source,
            destination_target: destination,
            kind: "hosted_by"
          }
        ],
        traversable_relation_ids: ["relationship-1"],
        disclosure: %{
          disclosure()
          | allowed_target_ids: ["target-1", "target-2"],
            allowed_evidence_kinds: ["observation"]
        }
    }

    set_mode(context.agent, {
      :decision,
      %{
        "type" => "target_traversal",
        "reason" => "Inspect the related host",
        "relationship_id" => "relationship-1",
        "evidence_ids" => ["evidence-1"]
      }
    })

    assert {:ok,
            %AI.ResolverDecision{
              intent: %AI.TargetTraversal{relationship_id: "relationship-1"}
            }} = Adapter.resolve(state, request, %{})

    [provider_request] = requests(context.agent)
    variants = output_schema(provider_request)["properties"]["intent"]["anyOf"]
    payload = user_payload(provider_request)

    assert "target_traversal" in payload["allowed_intents"]

    assert payload["traversal_options"] == [
             %{
               "relationship_id" => "relationship-1",
               "relationship_kind" => "hosted_by",
               "direction" => "source_to_destination",
               "next_target_id" => "target-2",
               "next_target_name" => "host",
               "next_target_kind" => "host",
               "next_target_type_id" => "linux"
             }
           ]

    assert "handoff" in payload["allowed_intents"]

    assert Enum.any?(variants, fn variant ->
             get_in(variant, ["properties", "type", "enum"]) == ["handoff"]
           end)

    set_mode(context.agent, {:decision, handoff()})

    assert {:ok, %AI.ResolverDecision{intent: %AI.Handoff{}}} =
             Adapter.resolve(state, request, %{})

    unavailable = %{request | traversable_relation_ids: []}

    assert {:ok, %AI.ResolverDecision{intent: %AI.Handoff{}}} =
             Adapter.resolve(state, unavailable, %{})

    unavailable_request = context.agent |> requests() |> List.last()
    unavailable_payload = user_payload(unavailable_request)
    assert length(unavailable_payload["target_relations"]) == 1
    assert unavailable_payload["traversable_relation_ids"] == []
    assert unavailable_payload["traversal_options"] == []
    refute "target_traversal" in unavailable_payload["allowed_intents"]
  end

  test "effect preconditions remain bound to cited observation after private wire decoding",
       context do
    state = state!("openai", context.endpoint <> "/v1", %{"api_key" => "test-secret"})
    observation = %{observation_tool() | operation: "bmc.power.inspect"}

    observation_request = %AI.ProposalTool{
      proposal_tool()
      | id: "request-observation",
        request_kind: :observation,
        capability: "observe.power",
        operation: "bmc.power.inspect",
        input_schema: tool_input_schema(),
        evidence_requirements: []
    }

    effect = %AI.ProposalTool{
      proposal_tool()
      | operation: "bmc.power.on",
        input_schema:
          tool_input_schema(
            %{"observed_power_state" => %{"type" => "string", "enum" => ["on", "off"]}},
            ["observed_power_state"]
          ),
        evidence_requirements: [
          %Skopos.Providers.Target.EvidenceRequirement{
            parameter: "observed_power_state",
            fact: "power_state",
            observation: "bmc.power.inspect"
          }
        ]
    }

    request = %{
      resolver_request()
      | selected_target_id: "target-1",
        selected_target_revision: 4,
        evidence: [
          %AI.Evidence{
            id: "observed-off",
            kind: "observation",
            target_id: "target-1",
            observed_at_us: 11,
            content: %{
              "tool_id" => observation_request.id,
              "facts" => %{"power_state" => "off"}
            }
          }
        ],
        observation_tools: [observation],
        proposal_tools: [observation_request, effect],
        conditions: [
          %AI.Condition{
            id: "power-condition",
            revision: 2,
            occurrence: 1,
            predicate: "Power is off",
            subject_key: "host-1",
            subject_ref: %{},
            state: :firing,
            target_id: "target-1",
            current_occurred_at_us: 10
          }
        ]
    }

    assert {:ok, %AI.ResolverDecision{intent: %AI.Handoff{}}} =
             Adapter.resolve(state, request, %{})

    [provider_request] = requests(context.agent)

    payload = user_payload(provider_request)
    disclosed = Enum.find(payload["proposal_tools"], &(&1["operation"] == effect.operation))
    assert disclosed["input_schema"] == effect.input_schema

    assert disclosed["evidence_requirements"] == [
             %{
               "parameter" => "observed_power_state",
               "fact" => "power_state",
               "observation" => "bmc.power.inspect"
             }
           ]

    for {observed, valid?} <- [{"off", true}, {"on", false}] do
      set_mode(
        context.agent,
        {:decision,
         %{
           "reason" => "Restore the currently observed power state",
           "intent" => %{
             "type" => "proposal",
             "delay_seconds" => 0,
             "purpose" => "remediation",
             "action" => %{
               "tool_id" => effect.id,
               "selectors_json" => Jason.encode!(%{"service" => "api"}),
               "parameters_json" => Jason.encode!(%{"observed_power_state" => observed})
             },
             "evidence_ids" => ["observed-off"],
             "affected_conditions" => [%{"condition_id" => "power-condition", "revision" => 2}],
             "verification" => %{
               "expected_result_json" => Jason.encode!(%{"power_state" => "on"})
             }
           }
         }}
      )

      assert {:ok, decision} = Adapter.resolve(state, request, %{})

      if valid?,
        do: assert(:ok == AI.Validator.validate_decision(:resolve, decision, request)),
        else:
          assert(match?({:error, _}, AI.Validator.validate_decision(:resolve, decision, request)))
    end

    recovered = %AI.Condition{
      id: "power-condition",
      revision: 2,
      occurrence: 1,
      predicate: "Power is off",
      subject_key: "host-1",
      subject_ref: %{},
      state: :recovered,
      target_id: "target-1",
      current_occurred_at_us: 10,
      recovery_status: :ready_for_review,
      recovery_evidence_ids: ["observed-off"]
    }

    request = %{
      request
      | alert_state: :recovered,
        conditions: [recovered],
        recovery_evidence_ids: ["observed-off"]
    }

    set_mode(context.agent, {:decision, handoff()})

    assert {:ok, %AI.ResolverDecision{intent: %AI.Handoff{}}} =
             Adapter.resolve(state, request, %{})

    recovered_schema =
      context.agent
      |> requests()
      |> List.last()
      |> output_schema()
      |> get_in(["properties", "intent", "anyOf"])
      |> Enum.find(&Map.has_key?(Map.get(&1, "properties", %{}), "verification"))

    assert get_in(recovered_schema, [
             "properties",
             "affected_conditions",
             "items",
             "properties",
             "condition_id",
             "enum"
           ]) ==
             [recovered.id]
  end

  test "Resolver schema retries receive explicit bounded correction context", context do
    state =
      state!("openai", context.endpoint <> "/v1", %{"api_key" => "test-secret"})

    request = %{
      resolver_request()
      | retry_context: %{
          "category" => "invalid_output",
          "rejection_code" => "schema_validation",
          "rejection_path" => "/intent/type"
        }
    }

    assert :ok = AI.Validator.validate_request(:resolve, request)

    set_mode(context.agent, {:decision, handoff()})

    assert {:ok, %AI.ResolverDecision{intent: %AI.Handoff{}}} =
             Adapter.resolve(state, request, %{})

    [wire_request] = requests(context.agent)
    body = Jason.decode!(wire_request.body)
    user_payload = user_payload(wire_request)

    assert user_payload["retry_context"] == request.retry_context
    assert user_payload["operating_instructions"] == "Avoid modifying root"

    assert Enum.any?(body["messages"], fn message ->
             message["role"] == "system" and
               String.contains?(message["content"], "previous response was rejected") and
               String.contains?(message["content"], "Copy enum values exactly") and
               String.contains?(message["content"], "at most 250 Unicode codepoints")
           end)
  end

  test "Resolver receives a rejected recovery reason and guidance to seek new symptom evidence",
       context do
    state = state!("openai", context.endpoint <> "/v1", %{"api_key" => "test-secret"})

    objective =
      Jason.encode!(%{
        "case_title" => "Metrics unavailable",
        "turn_intent" => %{
          "source" => "recovery_review_rejected",
          "review_reason" => "A unit list does not show that the endpoint responds"
        }
      })

    request = %{resolver_request() | objective: objective}
    set_mode(context.agent, {:decision, handoff()})

    assert {:ok, %AI.ResolverDecision{intent: %AI.Handoff{}}} =
             Adapter.resolve(state, request, %{})

    [wire_request] = requests(context.agent)
    assert user_payload(wire_request)["objective"] == objective

    assert Enum.any?(Jason.decode!(wire_request.body)["messages"], fn message ->
             message["role"] == "system" and
               String.contains?(message["content"], "Do not repeat a recovery claim") and
               String.contains?(message["content"], "direct observation")
           end)
  end

  test "schema rejection logs bounded failure metadata without response contents", context do
    state = state!("openai", context.endpoint <> "/v1", %{"api_key" => "test-secret"})

    set_mode(context.agent, {
      :raw_text,
      ~s({"reason":"test-secret","intent":{"type":"handoff","required_input":"test-secret"},"unexpected_private_key":"test-secret"})
    })

    output =
      capture_log(fn ->
        assert {:error, :invalid_output, _, %AI.Usage{}, "schema_validation", _path} =
                 Adapter.resolve(state, resolver_request(), %{})
      end)

    assert output =~ "AI object schema mismatch"
    assert output =~ "category=schema_validation"
    assert output =~ "path="
    assert output =~ "bytes="
    assert output =~ "errors="
    refute output =~ "test-secret"
    refute output =~ "unexpected_private_key"
  end

  test "nested proposal rejection logs metadata without tool names or untrusted values",
       context do
    state = state!("openai", context.endpoint <> "/v1", %{"api_key" => "test-secret"})

    set_mode(context.agent, {
      :raw_text,
      ~s({"reason":"Review the proposed action","intent":{"type":"proposal","action":{"tool_id":"test-secret","unexpected_private_key":"test-secret"},"evidence_ids":[],"affected_conditions":[]}})
    })

    output =
      capture_log(fn ->
        assert {:error, :invalid_output, _, %AI.Usage{}, "schema_validation", _path} =
                 Adapter.resolve(state, resolver_request(), %{})
      end)

    assert output =~ "category=schema_validation"
    assert output =~ "path=intent"
    refute output =~ "test-secret"
    refute output =~ "unexpected_private_key"
  end

  test "missing object logs its shape without response text", context do
    state = state!("openai", context.endpoint <> "/v1", %{"api_key" => "test-secret"})
    set_mode(context.agent, {:raw_text, "test-secret"})

    output =
      capture_log(fn ->
        assert {:error, :invalid_output, "AI provider did not return a structured object",
                %AI.Usage{}, "missing_structured_object"} =
                 Adapter.resolve(state, resolver_request(), %{})
      end)

    assert output =~ "AI object missing"
    assert output =~ "raw_kind=text"
    assert output =~ "bytes=11"
    refute output =~ "test-secret"
  end

  test "a text object with a nested schema error reports the rejected location", context do
    state = state!("openai", context.endpoint <> "/v1", %{"api_key" => "test-secret"})
    set_mode(context.agent, {:raw_text, ~s({"reason":"inspect","intent":{"type":"handoff"}})})

    assert {:error, :invalid_output,
            "AI provider JSON does not match the requested schema at /intent/required_input",
            %AI.Usage{input_tokens: 7, output_tokens: 5}, "schema_validation", _path} =
             Adapter.resolve(state, resolver_request(), %{})
  end

  test "a complete JSON code fence preserves the exact decision and its metered usage", context do
    state = state!("openai", context.endpoint <> "/v1", %{"api_key" => "test-secret"})

    set_mode(context.agent, {
      :raw_text,
      "```json\n{\"reason\":\"確認\",\"intent\":{\"type\":\"handoff\",\"required_input\":\"確認\"}}\n```"
    })

    assert {:ok,
            %AI.ResolverDecision{
              intent: %AI.Handoff{required_input: "確認"},
              usage: %AI.Usage{input_tokens: 7, output_tokens: 5}
            }} = Adapter.resolve(state, resolver_request(), %{})

    set_mode(context.agent, {
      :raw_text,
      "```json\n{\"reason\":\"確認\",\"intent\":{\"type\":\"handoff\",\"required_input\":\"確認\"},\"extra\":true}\n```"
    })

    assert {:error, :invalid_output, _, %AI.Usage{}, "schema_validation", _path} =
             Adapter.resolve(state, resolver_request(), %{})
  end

  test "Resolver truncated retry requests one compact complete JSON decision", context do
    state = state!("openai", context.endpoint <> "/v1", %{"api_key" => "test-secret"})

    request = %{
      resolver_request()
      | retry_context: %{"category" => "invalid_output", "rejection_code" => "truncated"}
    }

    assert :ok = AI.Validator.validate_request(:resolve, request)
    set_mode(context.agent, {:decision, handoff()})

    assert {:ok, %AI.ResolverDecision{intent: %AI.Handoff{}}} =
             Adapter.resolve(state, request, %{})

    [wire_request] = requests(context.agent)
    body = Jason.decode!(wire_request.body)
    assert user_payload(wire_request)["retry_context"] == request.retry_context

    assert Enum.any?(body["messages"], fn message ->
             message["role"] == "system" and
               String.contains?(message["content"], "rejection_code is truncated") and
               String.contains?(message["content"], "compact complete JSON object")
           end)
  end

  test "local validation rejects schema-invalid arguments without a second request", context do
    state = state!("openai", context.endpoint <> "/v1", %{"api_key" => "test-secret"})

    set_mode(context.agent, {
      :decision,
      %{
        "reason" => "The monitoring source recovered",
        "intent" => %{"type" => "recovery", "evidence_ids" => ["stale-evidence"]}
      }
    })

    assert {:error, :invalid_output, _message, %AI.Usage{input_tokens: 7, output_tokens: 5},
            "schema_validation", _path} =
             Adapter.resolve(state, resolver_request(), %{})

    assert [_request] = requests(context.agent)
  end

  test "schema rejection includes a bounded JSON path for the corrective Resolver turn",
       context do
    state = state!("openai", context.endpoint <> "/v1", %{"api_key" => "test-secret"})

    set_mode(context.agent, {
      :decision,
      %{"reason" => "Check this", "intent" => %{"type" => "handoff", "required_input" => 42}}
    })

    assert {:error, :invalid_output, message, %AI.Usage{input_tokens: 7, output_tokens: 5},
            "schema_validation", path} = Adapter.resolve(state, resolver_request(), %{})

    assert message =~ "AI provider JSON does not match the requested schema at /intent"
    assert String.starts_with?(path, "/intent")
    assert byte_size(path) <= 200
    assert [_request] = requests(context.agent)
  end

  test "buffered AI calls support the resolver queue concurrency", context do
    state =
      state!("openai", context.endpoint <> "/v1", %{"api_key" => "test-secret"}, %{
        "timeout_ms" => 8_000
      })

    set_mode(context.agent, {:sleep, 5_500})

    results =
      1..10
      |> Task.async_stream(
        fn _index -> Adapter.resolve(state, resolver_request(), %{}) end,
        max_concurrency: 10,
        ordered: false,
        timeout: 10_000
      )
      |> Enum.to_list()

    assert Enum.all?(results, fn
             {:ok, {:ok, %AI.ResolverDecision{intent: %AI.Handoff{}}}} -> true
             _other -> false
           end)

    assert length(requests(context.agent)) == 10
  end

  test "multilingual output stays within the codepoint-bounded AI contract", context do
    reason = String.duplicate("界", 500)
    required_input = String.duplicate("界", 250)

    set_mode(context.agent, {
      :decision,
      %{
        "type" => "handoff",
        "reason" => reason,
        "required_input" => required_input
      }
    })

    state = state!("openai", context.endpoint <> "/v1", %{"api_key" => "test-secret"})

    assert {:ok,
            %AI.ResolverDecision{
              intent: %AI.Handoff{reason: ^reason, required_input: ^required_input}
            }} = Adapter.resolve(state, resolver_request(), %{})

    [resolver_request] = requests(context.agent)
    resolver_schema = output_schema(resolver_request)
    assert resolver_schema["properties"]["reason"]["maxLength"] == 500

    set_mode(context.agent, {
      :decision,
      %{
        "verdict" => "approved",
        "purpose_assessment" => "remediation",
        "reason" => String.duplicate("界", 1_000)
      }
    })

    assert {:ok, %AI.ReviewDecision{verdict: :approved}} =
             Adapter.review(state, review_request(), %{})

    [review_request] = requests(context.agent)
    assert output_schema(review_request)["properties"]["reason"]["maxLength"] == 1_000

    set_mode(context.agent, {
      :decision,
      %{"type" => "handoff", "reason" => String.duplicate("界", 501), "required_input" => "x"}
    })

    assert {:error, :invalid_output, _message, %AI.Usage{input_tokens: 7, output_tokens: 5},
            "schema_validation", _path} =
             Adapter.resolve(state, resolver_request(), %{})
  end

  test "recovered Condition assessments survive ReqLLM object decoding", context do
    state = state!("openai", context.endpoint <> "/v1", %{"api_key" => "test-secret"})

    condition = %AI.Condition{
      id: "condition-1",
      revision: 2,
      occurrence: 1,
      predicate: "Endpoint unavailable",
      subject_key: "endpoint",
      subject_ref: %{},
      state: :recovered,
      target_id: "target-1",
      current_occurred_at_us: 10,
      recovery_status: :ready_for_review,
      recovery_evidence_ids: ["direct-observation"]
    }

    observation = %AI.Evidence{
      id: "direct-observation",
      kind: "observation",
      target_id: "target-1",
      observed_at_us: 11,
      content: %{"status" => "applied", "facts" => %{"endpoint_up" => false}}
    }

    request = %{
      resolver_request()
      | alert_state: :recovered,
        conditions: [condition],
        evidence: [observation],
        recovery_evidence_ids: [observation.id]
    }

    claim = %{
      "condition_id" => condition.id,
      "revision" => condition.revision,
      "status" => "still_failing",
      "evidence_ids" => [observation.id],
      "reason" => "The endpoint still fails"
    }

    set_mode(context.agent, {
      :decision,
      %{
        "reason" => "Continue investigating the endpoint",
        "intent" => %{
          "type" => "handoff",
          "required_input" => "Inspect the endpoint"
        },
        "condition_assessments" => [claim]
      }
    })

    assert {:ok,
            %AI.ResolverDecision{
              intent: %AI.Handoff{},
              condition_assessments: [^claim]
            }} = Adapter.resolve(state, request, %{})

    [wire_request] = requests(context.agent)
    schema = output_schema(wire_request)
    assert get_in(schema, ["properties", "condition_assessments", "maxItems"]) == 1

    assert get_in(schema, [
             "properties",
             "condition_assessments",
             "items",
             "properties",
             "evidence_ids",
             "items",
             "enum"
           ]) ==
             [observation.id]

    assert get_in(schema, [
             "properties",
             "condition_assessments",
             "items",
             "properties",
             "evidence_ids",
             "minItems"
           ]) == 1

    assert get_in(user_payload(wire_request), [
             "conditions",
             Access.at(0),
             "recovery_evidence_ids"
           ]) ==
             [observation.id]
  end

  test "each recovered Condition assessment schema exposes only its own current citations",
       context do
    state = state!("openai", context.endpoint <> "/v1", %{"api_key" => "test-secret"})

    conditions =
      for number <- 1..2 do
        %AI.Condition{
          id: "condition-#{number}",
          revision: number,
          occurrence: 1,
          predicate: "Endpoint unavailable",
          subject_key: "endpoint-#{number}",
          subject_ref: %{},
          state: :recovered,
          target_id: "target-#{number}",
          current_occurred_at_us: 10,
          recovery_status: :ready_for_review,
          recovery_evidence_ids: ["current-#{number}"]
        }
      end

    evidence =
      for number <- 1..2 do
        %AI.Evidence{
          id: "current-#{number}",
          kind: "observation",
          target_id: "target-#{number}",
          observed_at_us: 11,
          content: %{"status" => "applied", "facts" => %{"endpoint_up" => false}}
        }
      end

    request = %{
      resolver_request()
      | alert_state: :recovered,
        conditions: conditions,
        evidence: evidence,
        recovery_evidence_ids: Enum.map(evidence, & &1.id)
    }

    set_mode(context.agent, {:decision, handoff()})

    assert {:ok, %AI.ResolverDecision{intent: %AI.Handoff{}}} =
             Adapter.resolve(state, request, %{})

    [wire_request] = requests(context.agent)

    variants =
      get_in(output_schema(wire_request), [
        "properties",
        "condition_assessments",
        "items",
        "anyOf"
      ])

    assert get_in(output_schema(wire_request), [
             "properties",
             "condition_assessments",
             "minItems"
           ]) == 0

    assert Enum.map(variants, fn variant ->
             properties = variant["properties"]

             {properties["condition_id"]["enum"], properties["revision"]["enum"],
              properties["evidence_ids"]["items"]["enum"]}
           end) == [
             {["condition-1"], [1], ["current-1"]},
             {["condition-2"], [2], ["current-2"]}
           ]

    partial = %{
      "condition_id" => "condition-1",
      "revision" => 1,
      "status" => "still_failing",
      "evidence_ids" => ["current-1"],
      "reason" => "The cited endpoint is still unavailable"
    }

    for assessments <- [[], [partial]] do
      set_mode(context.agent, {
        :decision,
        %{
          "reason" => "Continue the per-Condition investigation",
          "intent" => %{"type" => "handoff", "required_input" => "Observe the other endpoint"},
          "condition_assessments" => assessments
        }
      })

      assert {:ok, %AI.ResolverDecision{condition_assessments: ^assessments}} =
               Adapter.resolve(state, request, %{})
    end
  end

  test "recovered Condition without current citations can only be assessed unknown", context do
    state = state!("openai", context.endpoint <> "/v1", %{"api_key" => "test-secret"})

    condition = %AI.Condition{
      id: "condition-1",
      revision: 2,
      occurrence: 1,
      predicate: "Endpoint unavailable",
      subject_key: "endpoint",
      subject_ref: %{},
      state: :recovered,
      target_id: "target-1",
      current_occurred_at_us: 10,
      recovery_status: :needs_observation,
      recovery_evidence_ids: []
    }

    request = %{resolver_request() | alert_state: :recovered, conditions: [condition]}

    claim = %{
      "condition_id" => condition.id,
      "revision" => condition.revision,
      "status" => "unknown",
      "evidence_ids" => [],
      "reason" => "The endpoint has not been measured after the recovery event"
    }

    set_mode(context.agent, {
      :decision,
      %{
        "reason" => "Request a current endpoint measurement",
        "intent" => %{"type" => "handoff", "required_input" => "Measure the endpoint"},
        "condition_assessments" => [claim]
      }
    })

    assert {:ok, %AI.ResolverDecision{condition_assessments: [^claim]}} =
             Adapter.resolve(state, request, %{})

    [wire_request] = requests(context.agent)
    schema = output_schema(wire_request)
    assessment = get_in(schema, ["properties", "condition_assessments", "items", "properties"])

    assert assessment["status"]["enum"] == ["unknown"]
    assert assessment["evidence_ids"]["maxItems"] == 0
  end

  test "recovery schema exposes only eligible Target recovery Evidence", context do
    state = state!("openai", context.endpoint <> "/v1", %{"api_key" => "test-secret"})

    ordinary = %AI.Evidence{
      id: "observation-1",
      kind: "observation",
      content: %{"status" => "observed"}
    }

    request = %{
      resolver_request()
      | alert_state: :recovered,
        evidence: [ordinary],
        disclosure: %{
          resolver_request().disclosure
          | allowed_evidence_kinds: ["observation"]
        }
    }

    assert {:ok, %AI.ResolverDecision{}} = Adapter.resolve(state, request, %{})
    [ordinary_request] = requests(context.agent)
    ordinary_variants = output_schema(ordinary_request)["properties"]["intent"]["anyOf"]
    ordinary_payload = user_payload(ordinary_request)

    refute "recovery" in ordinary_payload["allowed_intents"]
    assert "target_search" in ordinary_payload["allowed_intents"]

    refute Enum.any?(ordinary_variants, fn variant ->
             get_in(variant, ["properties", "type", "enum"]) == ["recovery"]
           end)

    assert Enum.any?(ordinary_variants, fn variant ->
             get_in(variant, ["properties", "type", "enum"]) == ["target_search"]
           end)

    verified = %AI.Evidence{
      id: "verification-1",
      kind: "target_verification",
      content: %{"status" => "verified", "operation_id" => "operation-1"}
    }

    second_verified = %AI.Evidence{
      id: "verification-2",
      kind: "target_verification",
      content: %{"status" => "verified", "operation_id" => "operation-2"}
    }

    request = %{
      request
      | evidence: [ordinary, verified, second_verified],
        recovery_evidence_ids: ["verification-1", "verification-2"],
        disclosure: %{
          request.disclosure
          | allowed_evidence_kinds: ["observation", "target_verification"]
        }
    }

    set_mode(context.agent, {
      :decision,
      %{
        "type" => "recovery",
        "reason" => "Fresh verification and monitoring agree",
        "evidence_ids" => ["verification-1", "verification-2", "verification-1"],
        "condition_claims" => []
      }
    })

    assert {:ok,
            %AI.ResolverDecision{
              intent: %AI.RecoveryConclusion{
                evidence_ids: ["verification-1", "verification-2"]
              }
            }} = Adapter.resolve(state, request, %{})

    verified_request = requests(context.agent) |> List.last()
    assert "recovery" in user_payload(verified_request)["allowed_intents"]
    assert "handoff" in user_payload(verified_request)["allowed_intents"]

    recovery =
      Enum.find(output_schema(verified_request)["properties"]["intent"]["anyOf"], fn variant ->
        get_in(variant, ["properties", "type", "enum"]) == ["recovery"]
      end)

    terminal_types =
      Enum.map(output_schema(verified_request)["properties"]["intent"]["anyOf"], fn variant ->
        get_in(variant, ["properties", "type", "enum"])
      end)

    assert ["recovery"] in terminal_types
    assert ["handoff"] in terminal_types

    assert get_in(recovery, ["properties", "evidence_ids", "items", "enum"]) == [
             "verification-1",
             "verification-2"
           ]

    observed = %AI.Evidence{
      id: "observation-recovered",
      kind: "observation",
      target_id: "target-1",
      content: %{
        "status" => "applied",
        "category" => "target_observed",
        "facts" => %{"ready" => true}
      }
    }

    observed_request = %{
      request
      | evidence: [ordinary, observed],
        recovery_evidence_ids: ["observation-recovered"],
        selected_target_id: "target-1",
        selected_target_revision: 1
    }

    set_mode(context.agent, {
      :decision,
      %{
        "type" => "recovery",
        "reason" => "Fresh Target observation confirms recovery",
        "evidence_ids" => ["observation-recovered"],
        "condition_claims" => []
      }
    })

    assert {:ok, %AI.ResolverDecision{}} = Adapter.resolve(state, observed_request, %{})

    recovery =
      requests(context.agent)
      |> List.last()
      |> output_schema()
      |> get_in(["properties", "intent", "anyOf"])
      |> Enum.find(fn variant ->
        get_in(variant, ["properties", "type", "enum"]) == ["recovery"]
      end)

    assert get_in(recovery, ["properties", "evidence_ids", "items", "enum"]) == [
             "observation-recovered"
           ]
  end

  test "manual recovery schema binds original symptom to current cited fact keys", context do
    state = state!("openai", context.endpoint <> "/v1", %{"api_key" => "test-secret"})
    symptom_id = String.duplicate("a", 64)

    observed = %AI.Evidence{
      id: "observation-current",
      kind: "observation",
      target_id: "target-1",
      content: %{"status" => "applied", "facts" => %{"service_state" => "active"}}
    }

    request = %{
      resolver_request()
      | alert_state: :not_applicable,
        case_symptom: %{
          id: symptom_id,
          text: "The API service is unavailable",
          desired_outcome: "The API service responds to health checks"
        },
        evidence: [observed],
        recovery_evidence_ids: [observed.id],
        disclosure: %{
          resolver_request().disclosure
          | allowed_evidence_kinds: ["observation"]
        }
    }

    set_mode(context.agent, {
      :decision,
      %{
        "type" => "recovery",
        "reason" => "The API service is active",
        "evidence_ids" => [observed.id],
        "condition_claims" => [],
        "desired_outcome_claims" => [
          %{
            "symptom_id" => symptom_id,
            "evidence_id" => observed.id,
            "fact_keys" => ["service_state"],
            "reason" => "The observed state is active"
          }
        ]
      }
    })

    assert {:ok, %AI.ResolverDecision{intent: %AI.RecoveryConclusion{} = conclusion}} =
             Adapter.resolve(state, request, %{})

    assert [%{"symptom_id" => ^symptom_id}] = conclusion.desired_outcome_claims
    [wire_request] = requests(context.agent)

    assert user_payload(wire_request)["case_symptom"] == %{
             "id" => symptom_id,
             "text" => "The API service is unavailable",
             "desired_outcome" => "The API service responds to health checks"
           }

    recovery =
      wire_request
      |> output_schema()
      |> get_in(["properties", "intent", "anyOf"])
      |> Enum.find(&(get_in(&1, ["properties", "type", "enum"]) == ["recovery"]))

    claim = get_in(recovery, ["properties", "desired_outcome_claims"])
    assert claim["minItems"] == 1
    assert get_in(claim, ["items", "properties", "symptom_id", "enum"]) == [symptom_id]

    assert get_in(claim, ["items", "properties", "fact_keys", "items", "enum"]) == [
             "service_state"
           ]
  end

  test "manual recovery can cite delivered file values but cannot cite a bare receipt", context do
    state = state!("openai", context.endpoint <> "/v1", %{"api_key" => "test-secret"})
    symptom_id = String.duplicate("b", 64)

    file = %AI.Evidence{
      id: "file-current",
      kind: "file_read",
      target_id: "target-1",
      content: %{"status" => "available", "encoding" => "utf8", "value" => "active"}
    }

    request = %{
      resolver_request()
      | alert_state: :not_applicable,
        case_symptom: %{
          id: symptom_id,
          text: "Unknown service status",
          desired_outcome: "The service is active"
        },
        evidence: [file],
        recovery_evidence_ids: [file.id],
        disclosure: %{resolver_request().disclosure | allowed_evidence_kinds: ["file_read"]}
    }

    set_mode(
      context.agent,
      {:decision,
       %{
         "type" => "recovery",
         "reason" => "The file contents report active",
         "evidence_ids" => [file.id],
         "condition_claims" => [],
         "desired_outcome_claims" => [
           %{
             "symptom_id" => symptom_id,
             "evidence_id" => file.id,
             "fact_keys" => ["value"],
             "reason" => "The body says active"
           }
         ]
       }}
    )

    assert {:ok, %AI.ResolverDecision{} = decision} = Adapter.resolve(state, request, %{})
    assert :ok = AI.Validator.validate_decision(:resolve, decision, request)
    [wire] = requests(context.agent)

    recovery =
      wire
      |> output_schema()
      |> get_in(["properties", "intent", "anyOf"])
      |> Enum.find(&(get_in(&1, ["properties", "type", "enum"]) == ["recovery"]))

    assert get_in(recovery, [
             "properties",
             "desired_outcome_claims",
             "items",
             "properties",
             "fact_keys",
             "items",
             "enum"
           ]) == ["value"]

    assert Enum.find(user_payload(wire)["evidence"], &(&1["id"] == file.id))["content"]["value"] ==
             "active"

    for content <- [Map.delete(file.content, "value"), %{"status" => "unavailable"}] do
      absent = %{request | evidence: [%{file | content: content}]}

      assert {:error, %AI.Error{category: :invalid_output}} =
               AI.Validator.validate_decision(:resolve, decision, absent)
    end
  end

  test "streamed and buffered responses produce the same decision", context do
    buffered = state!("openai", context.endpoint <> "/v1", %{"api_key" => "test-secret"})

    streamed =
      state!("openai", context.endpoint <> "/v1", %{"api_key" => "test-secret"}, %{
        "stream" => true
      })

    assert {:ok, buffered_decision} = Adapter.resolve(buffered, resolver_request(), %{})
    set_mode(context.agent, {:stream, handoff()})
    assert {:ok, streamed_decision} = Adapter.resolve(streamed, resolver_request(), %{})
    assert streamed_decision.intent == buffered_decision.intent
    assert streamed_decision.usage.input_tokens == buffered_decision.usage.input_tokens
    assert streamed_decision.usage.output_tokens == buffered_decision.usage.output_tokens

    set_mode(context.agent, {:stream, %{"unexpected" => true}})

    assert {:error, :invalid_output, _message, %AI.Usage{input_tokens: 7, output_tokens: 5},
            "schema_validation", _path} =
             Adapter.resolve(streamed, resolver_request(), %{})
  end

  test "review uses an isolated prompt without resolver sessions or Target tools", context do
    set_mode(
      context.agent,
      {:decision,
       %{"verdict" => "approved", "purpose_assessment" => "remediation", "reason" => "bounded"}}
    )

    state = state!("openai", context.endpoint <> "/v1", %{"api_key" => "test-secret"})

    assert {:ok,
            %AI.ReviewDecision{
              verdict: :approved,
              reason: "bounded",
              usage: %AI.Usage{input_tokens: 7, output_tokens: 5}
            }} = Adapter.review(state, review_request(), %{})

    [request] = requests(context.agent)
    assert request.body =~ "proposal-tool"
    assert request.body =~ "authoritative-request-value"
    assert request.body =~ "recent_case_evidence"
    assert request.body =~ "Check recent Case evidence for facts"
    assert request.body =~ "may be truncated"
    assert request.body =~ "validated_contract"
    assert request.body =~ "Do not infer an Access Method's capability set from cited evidence"
    assert request.body =~ "Write the human-facing reason in the report_language"

    assert %{
             "report_language" => "ja",
             "operating_instructions" => "Do not perform destructive actions",
             "validated_contract" => %{
               "access_method_current_and_authorized" => true,
               "input_matches_provider_schema" => true,
               "proposal_matches_disclosed_provider_tool" => true,
               "target_revision_current" => true
             }
           } = reviewer_payload(request)

    refute request.body =~ "resolver-private-session"
    refute request.body =~ "observation_tools"
    refute request.body =~ "proposal_tools"
  end

  test "manual Recovery Reviewer must assess the original symptom and exact citations", context do
    state = state!("openai", context.endpoint <> "/v1", %{"api_key" => "test-secret"})
    symptom_id = String.duplicate("c", 64)

    evidence = %AI.Evidence{
      id: "observation-current",
      kind: "observation",
      target_id: "target-1",
      content: %{"facts" => %{"service_state" => "active"}}
    }

    claim = %{
      "symptom_id" => symptom_id,
      "evidence_id" => evidence.id,
      "fact_keys" => ["service_state"],
      "reason" => "The service is active"
    }

    request = %AI.RecoveryReviewRequest{
      provider_revision: 1,
      session_id: "reviewer:turn-1",
      resolver_session_id: "resolver:run-1",
      case_id: "case-1",
      objective: "Restore the API service",
      report_language: :en,
      conditions: [],
      case_symptom: %{
        id: symptom_id,
        text: "The API service is unavailable",
        desired_outcome: "The API service responds to health checks"
      },
      source_evidence: [],
      cited_evidence: [evidence],
      conclusion: %AI.RecoveryConclusion{
        reason: "The service is active",
        evidence_ids: [evidence.id],
        desired_outcome_claims: [claim]
      },
      budget: budget()
    }

    assessment = %{
      "symptom_id" => symptom_id,
      "desired_outcome" => "The API service responds to health checks",
      "evidence_ids" => [evidence.id],
      "status" => "supported",
      "reason" => "The observed service state satisfies the desired outcome"
    }

    set_mode(context.agent, {
      :decision,
      %{
        "verdict" => "approved",
        "reason" => "The current service observation supports recovery",
        "desired_outcome_assessment" => assessment
      }
    })

    assert {:ok, %AI.ReviewDecision{desired_outcome_assessment: ^assessment} = decision} =
             Adapter.review_recovery(state, request, %{})

    assert :ok = AI.Validator.validate_decision(:review_recovery, decision, request)
    [wire] = requests(context.agent)

    assert reviewer_payload(wire)["case_symptom"] == %{
             "id" => symptom_id,
             "text" => "The API service is unavailable",
             "desired_outcome" => "The API service responds to health checks"
           }

    schema = output_schema(wire)
    assert "desired_outcome_assessment" in schema["required"]

    assert get_in(schema, [
             "properties",
             "desired_outcome_assessment",
             "properties",
             "symptom_id",
             "enum"
           ]) ==
             [symptom_id]

    assert get_in(schema, [
             "properties",
             "desired_outcome_assessment",
             "properties",
             "desired_outcome",
             "enum"
           ]) ==
             ["The API service responds to health checks"]

    assert {:error, _error} =
             AI.Validator.validate_decision(
               :review_recovery,
               %{
                 decision
                 | desired_outcome_assessment: %{assessment | "status" => "unsupported"}
               },
               request
             )

    assert {:error, _error} =
             AI.Validator.validate_decision(
               :review_recovery,
               %{
                 decision
                 | desired_outcome_assessment: %{assessment | "evidence_ids" => ["other"]}
               },
               request
             )

    assert {:error, _error} =
             AI.Validator.validate_decision(
               :review_recovery,
               %{
                 decision
                 | desired_outcome_assessment: %{
                     assessment
                     | "desired_outcome" => "The API service is unavailable"
                   }
               },
               request
             )
  end

  test "Reviewer sees monitor state and current observations without a recovery verdict",
       context do
    state = state!("openai", context.endpoint <> "/v1", %{"api_key" => "test-secret"})

    condition = %AI.Condition{
      id: "condition-1",
      revision: 2,
      occurrence: 1,
      predicate: "service inactive",
      subject_key: "api.service",
      subject_ref: %{},
      state: :recovered,
      target_id: "target-1",
      current_occurred_at_us: 10,
      recovery_status: :ready_for_review,
      recovery_evidence_ids: ["evidence-1"]
    }

    claim = %{"condition_id" => condition.id, "revision" => condition.revision}

    request = %{
      review_request()
      | conditions: [condition],
        proposal: %{proposal() | affected_conditions: [claim]}
    }

    set_mode(
      context.agent,
      {:decision,
       %{
         "verdict" => "approved",
         "purpose_assessment" => "remediation",
         "reason" => "Measured inactive"
       }}
    )

    assert {:ok, %AI.ReviewDecision{verdict: :approved}} = Adapter.review(state, request, %{})

    [wire_request] = requests(context.agent)
    [visible] = reviewer_payload(wire_request)["current_conditions"]

    assert visible["monitor_state"] == "recovered"
    assert visible["current_target_observation_ids"] == ["evidence-1"]
    refute Map.has_key?(visible, "recovery_status")
    refute Map.has_key?(visible, "recovery_evidence_ids")
    refute Map.has_key?(visible, "state")
  end

  test "generate_object offers causal raw remediation followed by separately planned investigation",
       context do
    {:ok, methods} = Skopos.Targets.Adapters.SSH.capabilities(nil, %{})
    command = Enum.find(methods.effects, &(&1.operation == "command.execute"))

    tool = %{
      proposal_tool()
      | operation: command.operation,
        capability: command.capability,
        input_schema: command.input_schema
    }

    request = %{
      resolver_request()
      | selected_target_id: "target-1",
        selected_target_revision: 4,
        proposal_tools: [tool],
        observation_tools: [],
        disclosure: %{
          disclosure()
          | allowed_target_ids: ["target-1"],
            allowed_evidence_kinds: ["observation"]
        },
        evidence: [
          %AI.Evidence{
            id: "evidence-1",
            kind: "observation",
            target_id: "target-1",
            content: %{"status" => "applied", "facts" => %{"stdout" => "api.service inactive"}}
          }
        ]
    }

    expected = %{"service" => "api.service", "state" => "active"}

    response = %{
      "reason" => "Start the service shown inactive by current Target output",
      "intent" => %{
        "type" => "proposal",
        "delay_seconds" => 0,
        "purpose" => "remediation",
        "action" => %{
          "tool_id" => tool.id,
          "selectors_json" => "{}",
          "parameters_json" => Jason.encode!(%{"command" => "systemctl start api.service"})
        },
        "evidence_ids" => ["evidence-1"],
        "affected_conditions" => [],
        "verification" => %{"expected_result_json" => Jason.encode!(expected)}
      }
    }

    for provider <- ["openai", "anthropic"] do
      endpoint = if provider == "openai", do: context.endpoint <> "/v1", else: context.endpoint
      state = state!(provider, endpoint, %{"api_key" => "remediation-secret"})
      set_mode(context.agent, {:decision, response})

      assert {:ok,
              %AI.ResolverDecision{
                intent: %AI.Proposal{
                  purpose: :remediation,
                  request_kind: :effect,
                  verification_intent: nil,
                  expected_result: ^expected
                }
              } = decision} =
               Adapter.resolve(state, request, %{})

      assert :ok = AI.Validator.validate_decision(:resolve, decision, request)
      invalid = %{decision | intent: %{decision.intent | expected_result: %{}}}
      assert {:error, _error} = AI.Validator.validate_decision(:resolve, invalid, request)
    end
  end

  test "generate_object offers opaque investigation without a remediation verification tool",
       context do
    {:ok, methods} = Skopos.Targets.Adapters.SSH.capabilities(nil, %{})
    command = Enum.find(methods.effects, &(&1.operation == "command.execute"))

    tool = %{
      proposal_tool()
      | operation: command.operation,
        capability: command.capability,
        input_schema: command.input_schema
    }

    request = %{
      resolver_request()
      | selected_target_id: "target-1",
        selected_target_revision: 4,
        disclosure: %{
          disclosure()
          | allowed_target_ids: ["target-1"],
            allowed_evidence_kinds: ["signal"]
        },
        proposal_tools: [tool],
        evidence: [
          %AI.Evidence{
            id: "evidence-1",
            kind: "signal",
            target_id: "target-1",
            content: %{"predicate" => "service unavailable"}
          }
        ],
        observation_tools: []
    }

    response = %{
      "reason" => "Inspect service status before selecting a repair",
      "intent" => %{
        "type" => "proposal",
        "delay_seconds" => 0,
        "purpose" => "investigation",
        "action" => %{
          "tool_id" => tool.id,
          "selectors_json" => "{}",
          "parameters_json" => Jason.encode!(%{"command" => "service nginx status"})
        },
        "evidence_ids" => ["evidence-1"],
        "affected_conditions" => []
      }
    }

    for provider <- ["openai", "anthropic"], initial_evidence <- [[], request.evidence] do
      request = %{request | evidence: initial_evidence}

      response =
        put_in(response, ["intent", "evidence_ids"], Enum.map(initial_evidence, & &1.id))

      endpoint = if provider == "openai", do: context.endpoint <> "/v1", else: context.endpoint
      state = state!(provider, endpoint, %{"api_key" => "diagnostic-secret"})
      set_mode(context.agent, {:decision, response})

      assert {:ok,
              %AI.ResolverDecision{
                intent: %AI.Proposal{
                  purpose: :investigation,
                  request_kind: :effect,
                  verification_intent: nil,
                  expected_result: %{}
                }
              } = decision} = Adapter.resolve(state, request, %{})

      assert :ok = AI.Validator.validate_decision(:resolve, decision, request)
    end
  end

  test "tool choices are rebound to the exact registered Target and Access Method", context do
    request = %{
      resolver_request()
      | selected_target_id: "target-1",
        selected_target_revision: 4,
        disclosure: %{
          disclosure()
          | allowed_target_ids: ["target-1"],
            allowed_evidence_kinds: ["observation"]
        },
        evidence: [
          %AI.Evidence{
            id: "evidence-1",
            kind: "observation",
            target_id: "target-1",
            content: %{"status" => "stopped"}
          },
          %AI.Evidence{
            id: "source-evidence-1",
            kind: "signal_event",
            target_id: nil,
            content: %{"current" => true, "state" => "firing"}
          },
          %AI.Evidence{
            id: "verification-1",
            kind: "target_verification",
            target_id: "target-1",
            content: %{"status" => "verified"}
          }
        ],
        observation_tools: [observation_tool()],
        proposal_tools: [proposal_tool()]
    }

    decision = %{
      "type" => "proposal",
      "delay_seconds" => 0,
      "purpose" => "remediation",
      "reason" => "Restore availability",
      "tool_id" => "proposal-tool",
      "selectors" => %{"service" => "api"},
      "parameters" => %{"grace_seconds" => 5},
      "evidence_ids" => ["evidence-1"],
      "affected_conditions" => [],
      "expected_result" => %{"status" => "running"},
      "verification" => %{
        "tool_id" => "observe-tool",
        "selectors" => %{"service" => "api"},
        "parameters" => %{},
        "expected_result" => %{"status" => "running"}
      }
    }

    set_mode(context.agent, {:decision, decision})
    state = state!("openai", context.endpoint <> "/v1", %{"api_key" => "test-secret"})

    assert {:ok,
            %AI.ResolverDecision{
              intent: %AI.Proposal{
                tool_id: "proposal-tool",
                target_id: "target-1",
                target_revision: 4,
                access_method_id: "access-1",
                access_method_revision: 3,
                request_kind: :effect,
                purpose: :remediation,
                capability: "effect.command",
                operation: "service.restart",
                expected_result: %{"status" => "running"},
                verification_intent: %AI.VerificationIntent{
                  tool_id: "observe-tool",
                  expected_result: %{"status" => "running"}
                }
              }
            }} = Adapter.resolve(state, request, %{})

    [provider_request] = requests(context.agent)
    assert String.contains?(provider_request.body, "output_schema")
    assert String.contains?(provider_request.body, "verification_schema")
    assert user_payload(provider_request)["effect_evidence_ids"] == ["evidence-1"]
    schema = output_schema(provider_request)

    proposal_variant =
      Enum.find(schema["properties"]["intent"]["anyOf"], fn variant ->
        get_in(variant, ["properties", "type", "enum"]) == ["proposal"] and
          get_in(variant, ["properties", "purpose", "enum"]) == ["remediation"]
      end)

    refute Map.has_key?(proposal_variant["properties"], "expected_result_json")

    assert get_in(proposal_variant, ["properties", "evidence_ids", "items", "enum"]) == [
             "evidence-1"
           ]

    [action_schema] = get_in(proposal_variant, ["properties", "action", "anyOf"])
    assert get_in(action_schema, ["properties", "tool_id", "enum"]) == ["proposal-tool"]

    assert Enum.sort(Map.keys(action_schema["properties"])) ==
             ~w(parameters_json selectors_json tool_id)

    assert action_schema["properties"]["selectors_json"]["type"] == "string"
    assert action_schema["properties"]["parameters_json"]["maxLength"] == AI.max_output_bytes()

    assert hd(user_payload(provider_request)["proposal_tools"])["input_schema"] ==
             proposal_tool().input_schema

    verification_schemas =
      get_in(proposal_variant, ["properties", "verification", "anyOf"])

    assert Enum.any?(verification_schemas, fn variant ->
             get_in(variant, ["properties", "tool_id", "enum"]) == ["observe-tool"] and
               Map.has_key?(variant["properties"], "expected_result_json")
           end)

    refute Enum.any?(verification_schemas, fn variant ->
             get_in(variant, ["properties", "tool_id", "enum"]) == ["proposal-tool"]
           end)

    invalid_citation = %{
      "reason" => "Restore availability",
      "intent" => %{
        "type" => "proposal",
        "delay_seconds" => 0,
        "purpose" => "remediation",
        "action" => ProviderStub.action(decision),
        "evidence_ids" => ["source-evidence-1"],
        "affected_conditions" => [],
        "verification" =>
          decision["verification"]
          |> ProviderStub.action()
          |> Map.put(
            "expected_result_json",
            Jason.encode!(decision["verification"]["expected_result"])
          )
      }
    }

    set_mode(context.agent, {:raw_text, Jason.encode!(invalid_citation)})

    assert {:error, :invalid_output,
            "AI provider JSON does not match the requested schema at /intent/evidence_ids",
            %AI.Usage{}, "schema_validation", _path} = Adapter.resolve(state, request, %{})

    set_mode(context.agent, {:decision, %{decision | "tool_id" => "invented-tool"}})

    assert {:error, :invalid_output, _message, %AI.Usage{input_tokens: 7, output_tokens: 5},
            "schema_validation", _path} =
             Adapter.resolve(state, request, %{})

    set_mode(context.agent, {:decision, Map.delete(decision, "tool_id")})

    assert {:error, :invalid_output, _message, %AI.Usage{input_tokens: 7, output_tokens: 5},
            "schema_validation", _path} =
             Adapter.resolve(state, request, %{})

    malformed = put_in(decision, ["verification", "expected_result"], "not-an-object")
    set_mode(context.agent, {:decision, malformed})

    assert {:error, :invalid_output, _message, %AI.Usage{input_tokens: 7, output_tokens: 5},
            "decision_validation"} =
             Adapter.resolve(state, request, %{})
  end

  test "observation proposals may name current investigative Conditions without effect authority",
       context do
    condition = %AI.Condition{
      id: "condition-1",
      revision: 3,
      occurrence: 1,
      predicate: "service unavailable",
      subject_key: "service",
      subject_ref: %{},
      state: :firing,
      target_id: "target-1",
      current_occurred_at_us: 1
    }

    tool = %{
      proposal_tool()
      | request_kind: :observation,
        capability: "observe.command",
        operation: "service.inspect"
    }

    request = %{
      resolver_request()
      | selected_target_id: "target-1",
        selected_target_revision: 4,
        conditions: [condition],
        disclosure: %{disclosure() | allowed_target_ids: ["target-1"]},
        proposal_tools: [tool]
    }

    claim = %{"condition_id" => condition.id, "revision" => condition.revision}

    set_mode(context.agent, {
      :raw_text,
      Jason.encode!(%{
        "reason" => "Inspect this service",
        "intent" => %{
          "type" => "proposal",
          "delay_seconds" => 0,
          "purpose" => "investigation",
          "action" => %{
            "tool_id" => tool.id,
            "selectors_json" => Jason.encode!(%{"service" => "api"}),
            "parameters_json" => Jason.encode!(%{"grace_seconds" => 5})
          },
          "evidence_ids" => [],
          "affected_conditions" => [claim]
        }
      })
    })

    state = state!("openai", context.endpoint <> "/v1", %{"api_key" => "test-secret"})

    assert {:ok,
            %AI.ResolverDecision{
              intent: %AI.Proposal{
                request_kind: :observation,
                purpose: :investigation,
                affected_conditions: [^claim],
                verification_intent: nil
              }
            }} = Adapter.resolve(state, request, %{})

    [wire] = requests(context.agent)

    proposal_schema =
      output_schema(wire)["properties"]["intent"]["anyOf"]
      |> Enum.find(&(get_in(&1, ["properties", "type", "enum"]) == ["proposal"]))

    assert proposal_schema["properties"]["affected_conditions"]["minItems"] == 0
  end

  test "effect proposal carries a cited related Condition and exact relationship revision",
       context do
    effect_target = %AI.TargetCandidate{
      id: "target-1",
      revision: 4,
      name: "controller",
      kind: "host",
      type_id: "custom-os",
      facts: %{}
    }

    condition_target = %AI.TargetCandidate{
      id: "target-2",
      revision: 2,
      name: "guest",
      kind: "host",
      type_id: "linux",
      facts: %{}
    }

    condition = %AI.Condition{
      id: "condition-2",
      revision: 3,
      occurrence: 1,
      predicate: "service unavailable",
      subject_key: "service",
      subject_ref: %{},
      state: :recovered,
      target_id: condition_target.id,
      current_occurred_at_us: 10,
      recovery_status: :ready_for_review,
      recovery_evidence_ids: ["symptom-observation"]
    }

    relation = %AI.TargetRelation{
      id: "relation-1",
      revision: 7,
      source_target: condition_target,
      destination_target: effect_target,
      kind: "managed_by"
    }

    request = %{
      resolver_request()
      | alert_state: :recovered,
        selected_target_id: effect_target.id,
        selected_target_revision: effect_target.revision,
        conditions: [condition],
        recovery_evidence_ids: ["symptom-observation"],
        disclosure: %{
          disclosure()
          | allowed_target_ids: [effect_target.id, condition_target.id],
            allowed_evidence_kinds: ["observation"]
        },
        evidence: [
          %AI.Evidence{
            id: "effect-observation",
            kind: "observation",
            target_id: effect_target.id,
            observed_at_us: 12,
            content: %{"status" => "applied", "facts" => %{"power_state" => "off"}}
          },
          %AI.Evidence{
            id: "symptom-observation",
            kind: "observation",
            target_id: condition_target.id,
            observed_at_us: 13,
            content: %{"status" => "applied", "facts" => %{"service" => "inactive"}}
          }
        ],
        target_relations: [relation],
        observation_tools: [observation_tool()],
        proposal_tools: [proposal_tool()]
    }

    claim = %{
      "condition_id" => condition.id,
      "revision" => condition.revision,
      "relationship_id" => relation.id,
      "relationship_revision" => relation.revision
    }

    result = %{
      "reason" => "The guest remains unavailable while its controller reports power off",
      "intent" => %{
        "type" => "proposal",
        "delay_seconds" => 0,
        "purpose" => "remediation",
        "action" => %{
          "tool_id" => "proposal-tool",
          "selectors_json" => Jason.encode!(%{"service" => "api"}),
          "parameters_json" => Jason.encode!(%{"grace_seconds" => 5})
        },
        "evidence_ids" => ["effect-observation", "symptom-observation"],
        "affected_conditions" => [claim],
        "verification" => %{
          "tool_id" => "observe-tool",
          "selectors_json" => Jason.encode!(%{"service" => "api"}),
          "parameters_json" => "{}",
          "expected_result_json" => Jason.encode!(%{"status" => "running"})
        }
      }
    }

    assert AI.proposal_evidence_ids(request) == [
             "effect-observation",
             "symptom-observation"
           ]

    set_mode(context.agent, {:raw_text, Jason.encode!(result)})
    state = state!("openai", context.endpoint <> "/v1", %{"api_key" => "test-secret"})

    assert {:ok,
            %AI.ResolverDecision{intent: %AI.Proposal{affected_conditions: [^claim]}} =
              accepted} = Adapter.resolve(state, request, %{})

    assert :ok = AI.Validator.validate_decision(:resolve, accepted, request)

    for ids <- [["effect-observation"], ["symptom-observation"]] do
      incomplete = %{accepted | intent: %{accepted.intent | evidence_ids: ids}}

      assert {:error, %AI.Error{category: :invalid_output}} =
               AI.Validator.validate_decision(:resolve, incomplete, request)
    end

    [wire] = requests(context.agent)
    assert user_payload(wire)["effect_evidence_ids"] == result["intent"]["evidence_ids"]

    proposal_schema =
      output_schema(wire)["properties"]["intent"]["anyOf"]
      |> Enum.find(&(get_in(&1, ["properties", "purpose", "enum"]) == ["remediation"]))

    assert get_in(proposal_schema, [
             "properties",
             "affected_conditions",
             "items",
             "properties",
             "relationship_id",
             "enum"
           ]) ==
             [relation.id]

    changed =
      put_in(result, ["intent", "affected_conditions"], [
        %{claim | "relationship_revision" => relation.revision + 1}
      ])

    set_mode(context.agent, {:raw_text, Jason.encode!(changed)})

    assert {:ok, %AI.ResolverDecision{} = stale_decision} =
             Adapter.resolve(state, request, %{})

    assert {:error, %AI.Error{category: :invalid_output}} =
             AI.Validator.validate_decision(:resolve, stale_decision, request)

    failed_request = %{
      request
      | conditions: [
          %{
            condition
            | recovery_status: :needs_observation,
              recovery_evidence_ids: [],
              failed_observation_ids: ["symptom-observation"]
          }
        ],
        recovery_evidence_ids: [],
        evidence:
          Enum.map(request.evidence, fn
            %{id: "symptom-observation"} = item ->
              %{item | content: %{"status" => "failed", "category" => "observation_failed"}}

            item ->
              item
          end)
    }

    set_mode(context.agent, {:raw_text, Jason.encode!(result)})

    assert {:ok, %AI.ResolverDecision{} = failed_observation_decision} =
             Adapter.resolve(state, failed_request, %{})

    assert :ok =
             AI.Validator.validate_decision(:resolve, failed_observation_decision, failed_request)

    assert AI.recovery_evidence_ids(failed_request) == []
  end

  test "malformed output, deadline, and caller cancellation stay typed", context do
    state =
      state!("openai", context.endpoint <> "/v1", %{"api_key" => "test-secret"}, %{
        "timeout_ms" => 500
      })

    set_mode(context.agent, {:decision, %{"unexpected" => true}})

    assert {:error, :invalid_output, _message, %AI.Usage{input_tokens: 7, output_tokens: 5},
            "schema_validation", _path} =
             Adapter.resolve(state, resolver_request(), %{})

    set_mode(context.agent, {:sleep, 1_000})
    assert {:error, :timeout, _message} = Adapter.resolve(state, resolver_request(), %{})

    set_mode(context.agent, {:sleep, 1_000})
    cancelled? = fn -> requests(context.agent) != [] end

    assert {:error, :cancelled, _message} =
             Adapter.resolve(state, resolver_request(), %{
               before_send?: fn -> false end,
               cancelled?: cancelled?
             })

    assert length(requests(context.agent)) == 1
  end

  test "configuration rejects unknown fields and invalid provider credentials", context do
    base = %{
      "provider" => "openai",
      "model" => "test-model",
      "endpoint" => context.endpoint <> "/v1"
    }

    credentials = %{"api_key" => "secret"}

    assert {:error, :invalid_configuration} =
             Adapter.build(Map.put(base, "typo", true), credentials)

    assert {:error, :invalid_configuration} =
             Adapter.build(Map.put(base, "output_mode", "structured"), credentials)

    assert {:error, :invalid_configuration} =
             Adapter.build(base, %{})

    assert {:error, :invalid_configuration} =
             Adapter.build(%{base | "provider" => "unknown"}, %{"api_key" => "secret"})

    assert {:error, :invalid_configuration} =
             Adapter.build(Map.put(base, "reasoning_effort", "unbounded"), credentials)

    assert {:ok, %{reasoning_effort: :low}} =
             Adapter.build(Map.put(base, "reasoning_effort", "low"), credentials)
  end

  test "the public service catalog includes every installed object provider and excludes other operations" do
    services = Adapter.services()
    registered = ReqLLM.Providers.list() |> Enum.map(&Atom.to_string/1)

    assert Enum.map(services, & &1.id) ==
             Enum.reject(registered, &(&1 in ~w(cohere elevenlabs typesafe)))

    assert Enum.find(services, &(&1.id == "ollama")).auth == "none"
    assert Enum.find(services, &(&1.id == "google_vertex")).auth == "service_account_json"
    assert Enum.find(services, &(&1.id == "openai_codex")).auth == "oauth_access_token"
  end

  test "every catalog service can build a model connection using its supported credential profile" do
    for service <- Adapter.services() do
      configuration =
        %{"provider" => service.id, "model" => "skopos-test-model"}
        |> Map.merge(
          case service.id do
            "azure" -> %{"endpoint" => "https://example.openai.azure.com"}
            "amazon_bedrock" -> %{"region" => "us-east-1"}
            "google_vertex" -> %{"project_id" => "skopos-test"}
            "openai_codex" -> %{"chatgpt_account_id" => "test-account"}
            _ -> %{}
          end
        )

      credentials =
        case service.auth do
          "none" ->
            %{}

          "optional_api_key" ->
            %{}

          "service_account_json" ->
            %{
              "service_account_json" =>
                ~s({"client_email":"test@example.com","private_key":"test"})
            }

          "oauth_access_token" ->
            %{"access_token" => "test-token"}

          "api_key" ->
            %{"api_key" => "test-key"}
        end

      assert {:ok, state} = Adapter.build(configuration, credentials), service.id
      assert state.provider == String.to_existing_atom(service.id)
      assert state.model.provider == state.provider
    end

    assert {:error, :invalid_configuration} =
             Adapter.build(%{"provider" => "ollama", "model" => "llama3"}, %{
               "api_key" => "ignored"
             })

    assert {:error, :invalid_configuration} =
             Adapter.build(%{"provider" => "google_vertex", "model" => "gemini"}, %{})
  end

  test "unsupported Azure model family is reported as capability, not network failure" do
    assert {:ok, state} =
             Adapter.build(
               %{
                 "provider" => "azure",
                 "model" => "model-outside-azure-families",
                 "endpoint" => "https://example.openai.azure.com"
               },
               %{"api_key" => "test-key"}
             )

    assert {:error, :capability, "AI model family is not supported by this service"} =
             Adapter.check(state, %{})
  end

  test "OpenRouter catalog structured-output metadata selects its schema path without tools" do
    assert {:ok, state} =
             Adapter.build(
               %{"provider" => "openrouter", "model" => "gryphe/mythomax-l2-13b"},
               %{"api_key" => "test-key"}
             )

    assert state.model.extra["structured_output"] == true
    assert state.model.capabilities == nil
    assert state.provider_options[:openrouter_structured_output_mode] == :json_schema
  end

  test "OpenRouter models without tool metadata send a schema request through Resolver",
       context do
    state =
      state!("openrouter", context.endpoint <> "/v1", %{"api_key" => "test-key"}, %{
        "model" => "gryphe/mythomax-l2-13b"
      })

    set_mode(context.agent, {:decision, handoff()})

    assert {:ok, %AI.ResolverDecision{intent: %AI.Handoff{}}} =
             Adapter.resolve(state, resolver_request(), %{})

    [request] = requests(context.agent)
    body = Jason.decode!(request.body)
    assert body["response_format"]["type"] == "json_schema"
    refute Map.has_key?(body, "tools")
  end

  test "known models retain LLMDB metadata while unknown model IDs remain usable", context do
    known =
      state!("openai", context.endpoint <> "/v1", %{"api_key" => "test-secret"}, %{
        "model" => "gpt-4o-mini"
      })

    unknown =
      state!("openai", context.endpoint <> "/v1", %{"api_key" => "test-secret"}, %{
        "model" => "model-released-after-skopos"
      })

    assert known.model.id == "gpt-4o-mini"
    assert known.model.capabilities != nil
    assert known.model.execution != nil

    assert unknown.model.id == "model-released-after-skopos"
    assert unknown.model.provider == :openai
    assert unknown.model.capabilities == nil
    assert unknown.model.execution == nil
  end

  test "reasoning effort is passed through the provider-neutral adapter", context do
    state =
      state!("openai", context.endpoint <> "/v1", %{"api_key" => "test-secret"}, %{
        "reasoning_effort" => "high"
      })

    set_mode(context.agent, {:decision, handoff()})
    assert {:ok, %AI.ResolverDecision{}} = Adapter.resolve(state, resolver_request(), %{})

    [request] = requests(context.agent)
    assert Jason.decode!(request.body)["reasoning_effort"] == "high"
  end

  test "hosted Provider lifecycles and public AI actions invoke the registered adapter",
       context do
    admin =
      Accounts.bootstrap!(
        "req-llm-admin@example.com",
        "correct horse battery staple",
        "correct horse battery staple",
        authorize?: true
      )

    for {provider_name, endpoint} <- [
          {"openai", context.endpoint <> "/v1"},
          {"anthropic", context.endpoint},
          {"ollama", context.endpoint <> "/v1"}
        ] do
      set_mode(context.agent, {:decision, handoff()})

      provider =
        Providers.create_provider!(
          "#{provider_name}-ai",
          :ai,
          Adapter.type(),
          %{
            "provider" => provider_name,
            "model" => "test-model",
            "endpoint" => endpoint
          },
          if(provider_name == "ollama", do: %{}, else: %{"api_key" => "provider-secret"}),
          actor: admin
        )

      provider = Providers.check_provider!(provider.id, 1, %{}, actor: admin)

      assert provider.check_status == :passed,
             inspect({provider_name, provider.check_category, provider.check_message})

      provider = Providers.enable_provider!(provider, 1, actor: admin)

      assert {:ok, %AI.ResolverDecision{intent: %AI.Handoff{reason: "probe"}}} =
               Providers.ai_resolve(provider.id, resolver_request(), %{}, actor: admin)

      set_mode(
        context.agent,
        {:decision,
         %{"verdict" => "approved", "purpose_assessment" => "remediation", "reason" => "bounded"}}
      )

      assert {:ok, %AI.ReviewDecision{verdict: :approved, reason: "bounded"}} =
               Providers.ai_review(provider.id, review_request(), %{}, actor: admin)

      set_mode(context.agent, {:decision, %{"unexpected" => true}})

      assert {:error, error} =
               Providers.ai_resolve(provider.id, resolver_request(), %{}, actor: admin)

      assert %AI.Error{
               category: :invalid_output,
               usage: %AI.Usage{input_tokens: 7, output_tokens: 5},
               dispatched?: true
             } = ai_error(error)
    end
  end

  defp ai_error(%AI.Error{} = error), do: error
  defp ai_error(%{errors: errors}), do: Enum.find_value(errors, &ai_error/1)
  defp ai_error(_error), do: nil

  defp state!(provider, endpoint, credentials, extra_configuration \\ %{}) do
    configuration =
      Map.merge(
        %{
          "provider" => provider,
          "model" => "test-model",
          "endpoint" => endpoint
        },
        extra_configuration
      )

    assert {:ok, state} = Adapter.build(configuration, credentials)
    state
  end

  defp resolver_request do
    %AI.ResolverRequest{
      provider_revision: 1,
      session_id: "resolver-session",
      case_id: "case-1",
      turn: 1,
      objective: "Restore service health",
      alert_state: :firing,
      report_language: :en,
      operating_instructions: "Avoid modifying root",
      disclosure: disclosure(),
      budget: budget(),
      evidence: [],
      target_candidates: [],
      observation_results: [],
      target_relations: [],
      observation_tools: [],
      proposal_tools: []
    }
  end

  defp review_request do
    %AI.ReviewRequest{
      provider_revision: 1,
      session_id: "review-session",
      resolver_session_id: "resolver-private-session",
      case_id: "case-1",
      objective: "Restore service health",
      resolution_run_id: "review-run",
      recovery_evidence_ids: [],
      report_language: :ja,
      operating_instructions: "Do not perform destructive actions",
      proposal: proposal(),
      source_evidence: [
        %AI.Evidence{
          id: "source-evidence-1",
          kind: "signal_event",
          target_id: nil,
          content: %{"requirement" => "authoritative-request-value"}
        }
      ],
      cited_evidence: [
        %AI.Evidence{
          id: "evidence-1",
          kind: "observation",
          target_id: "target-1",
          content: %{"status" => "stopped"}
        }
      ],
      context_evidence: [
        %AI.Evidence{
          id: "independent-responsive-guest",
          kind: "observation",
          target_id: "target-1",
          observed_at_us: 1_000_000,
          content: %{"facts" => %{"machine_id" => "responsive-guest"}}
        }
      ],
      budget: budget()
    }
  end

  defp reviewer_payload(request) do
    request.body
    |> Jason.decode!()
    |> get_in(["messages", Access.at(1), "content"])
    |> Jason.decode!()
  end

  defp proposal do
    %AI.Proposal{
      tool_id: "proposal-tool",
      target_id: "target-1",
      target_revision: 1,
      access_method_id: "access-1",
      access_method_revision: 1,
      request_kind: :effect,
      purpose: :remediation,
      capability: "effect.command",
      operation: "service.restart",
      selectors: %{"service" => "api"},
      parameters: %{},
      reason: "Restore availability",
      evidence_ids: ["evidence-1"],
      expected_result: %{"status" => "running"},
      verification_intent: %AI.VerificationIntent{
        tool_id: "observe-tool",
        selectors: %{"service" => "api"},
        parameters: %{},
        expected_result: %{"status" => "running"}
      }
    }
  end

  defp observation_tool do
    %AI.ObservationTool{
      id: "observe-tool",
      target_id: "target-1",
      target_revision: 4,
      access_method_id: "access-1",
      access_method_revision: 3,
      provider_id: "target-provider",
      provider_revision: 2,
      capability: "observe.command",
      operation: "service.inspect",
      description: "Inspect one service",
      input_schema: tool_input_schema(),
      output_schema: verification_schema(),
      verification_schema: verification_schema()
    }
  end

  defp proposal_tool do
    %AI.ProposalTool{
      id: "proposal-tool",
      target_id: "target-1",
      target_revision: 4,
      access_method_id: "access-1",
      access_method_revision: 3,
      provider_id: "target-provider",
      provider_revision: 2,
      request_kind: :effect,
      capability: "effect.command",
      operation: "service.restart",
      description: "Restart one service",
      input_schema:
        tool_input_schema(
          %{
            "grace_seconds" => %{"type" => "integer", "minimum" => 0, "maximum" => 30}
          },
          ["grace_seconds"]
        )
    }
  end

  defp disclosure do
    %AI.Disclosure{
      allowed_target_ids: [],
      allowed_evidence_kinds: [],
      max_items: 20,
      max_bytes: 20_000
    }
  end

  defp budget do
    %AI.Budget{
      remaining_turns: 3,
      remaining_tokens: 2_000,
      remaining_target_requests: 3,
      remaining_effects: 1,
      remaining_related_targets: 2
    }
  end

  defp handoff,
    do: %{"type" => "handoff", "reason" => "probe", "required_input" => "human"}

  defp tool_input_schema(parameter_properties \\ %{}, parameter_required \\ []) do
    %{
      "type" => "object",
      "properties" => %{
        "selectors" => %{
          "type" => "object",
          "properties" => %{"service" => %{"type" => "string", "minLength" => 1}},
          "required" => ["service"],
          "additionalProperties" => false
        },
        "parameters" => %{
          "type" => "object",
          "properties" => parameter_properties,
          "required" => parameter_required,
          "additionalProperties" => false
        }
      },
      "required" => ["selectors", "parameters"],
      "additionalProperties" => false
    }
  end

  defp verification_schema,
    do: %{
      "type" => "object",
      "properties" => %{"status" => %{"type" => "string"}},
      "minProperties" => 1,
      "additionalProperties" => false
    }

  defp output_schema(request) do
    body = Jason.decode!(request.body)

    case request.path do
      "/v1/messages" ->
        get_in(body, ["output_format", "schema"]) ||
          get_in(body, ["tools", Access.at(0), "input_schema"])

      _other ->
        get_in(body, ["tools", Access.at(0), "function", "parameters"])
    end
  end

  defp set_mode(agent, mode),
    do: Agent.update(agent, &%{&1 | mode: mode, requests: []})

  defp requests(agent),
    do: Agent.get(agent, &Enum.reverse(&1.requests))

  defp user_payload(request) do
    request.body
    |> Jason.decode!()
    |> Map.fetch!("messages")
    |> Enum.find(fn message ->
      message["role"] == "user" and
        match?({:ok, %{"case_id" => _}}, Jason.decode(message["content"]))
    end)
    |> Map.fetch!("content")
    |> Jason.decode!()
  end
end
