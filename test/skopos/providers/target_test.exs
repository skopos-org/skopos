defmodule Skopos.Providers.TargetTest do
  use Skopos.DataCase, async: false

  alias Skopos.Accounts
  alias Skopos.Providers
  alias Skopos.Providers.Target

  @password "correct horse battery staple"
  @token "target-provider-secret"

  setup do
    admin =
      Accounts.bootstrap!("target-admin@example.com", @password, @password, authorize?: true)

    operator =
      Accounts.create_user!("target-operator@example.com", @password, :operator, actor: admin)

    viewer = Accounts.create_user!("target-viewer@example.com", @password, :viewer, actor: admin)

    provider =
      Providers.create_provider!(
        "target-provider",
        :target,
        "fixture-target",
        %{"endpoint" => "reachable"},
        %{"token" => @token},
        actor: admin
      )
      |> then(&Providers.enable_provider!(&1, 1, actor: admin))

    %{admin: admin, operator: operator, viewer: viewer, provider: provider}
  end

  test "capabilities use the Ash interface, current gate and kind policy", context do
    capabilities = %Target.Capabilities{
      observations: [operation("observe.system", "system.inspect", "Inspect system state")],
      effects: [operation("effect.service", "service.restart", "Restart one service")]
    }

    assert ^capabilities =
             Providers.target_capabilities!(
               context.provider.id,
               %Target.CapabilitiesRequest{
                 provider_revision: context.provider.revision,
                 connection: %Target.Connection{endpoint: "reachable"}
               },
               invocation(capabilities),
               actor: context.admin
             )

    assert_receive {:capabilities,
                    %{token: @token, connection: %Target.Connection{endpoint: "reachable"}}}

    assert {:error, %Ash.Error.Forbidden{}} =
             Providers.target_capabilities(
               context.provider.id,
               %Target.CapabilitiesRequest{
                 provider_revision: context.provider.revision,
                 connection: %Target.Connection{endpoint: "reachable"}
               },
               invocation(capabilities),
               actor: context.viewer
             )
  end

  test "capability discovery rejects an invalid connection before the adapter", context do
    for endpoint <- ["", String.duplicate("x", 1_025)] do
      request = %Target.CapabilitiesRequest{
        provider_revision: context.provider.revision,
        connection: %Target.Connection{endpoint: endpoint}
      }

      assert {:error, error} =
               Providers.target_capabilities(
                 context.provider.id,
                 request,
                 invocation(flunk_response()),
                 actor: context.admin
               )

      assert target_error(error).message == "Invalid Method connection"
    end

    refute_receive {:capabilities, _state}
  end

  test "unregistered connection discovery requires registration authority", context do
    request = %Target.CapabilitiesRequest{
      provider_revision: context.provider.revision,
      connection: %Target.Connection{endpoint: "reachable"}
    }

    assert {:error, %Ash.Error.Forbidden{}} =
             Providers.target_capabilities(
               context.provider.id,
               request,
               invocation(%Target.Capabilities{observations: [], effects: []}),
               actor: context.operator
             )

    refute_receive {:capabilities, _state}
  end

  test "capabilities reject malformed or duplicate operations and redact credentials", context do
    duplicate = operation("observe.system", "system.inspect", "Inspect system state")

    effect_with_requirement = %{
      operation(
        "effect.service",
        "service.restart",
        "Restart one service",
        %{
          "type" => "object",
          "properties" => %{
            "parameters" => %{
              "type" => "object",
              "properties" => %{"expected_status" => %{"type" => "string"}}
            }
          }
        }
      )
      | evidence_requirements: [
          %Target.EvidenceRequirement{
            parameter: "expected_status",
            fact: "status",
            observation: "system.inspect"
          }
        ]
    }

    for capabilities <- [
          %Target.Capabilities{observations: [duplicate, duplicate], effects: []},
          %Target.Capabilities{observations: [%{duplicate | output_schema: nil}], effects: []},
          %Target.Capabilities{
            observations: [
              %{duplicate | output_schema: %{"type" => "unsupported-json-type"}}
            ],
            effects: []
          },
          %Target.Capabilities{
            observations: [
              %{duplicate | verification_schema: %{"type" => "unsupported-json-type"}}
            ],
            effects: []
          },
          %Target.Capabilities{
            observations: [
              %Target.Operation{
                capability: "",
                operation: "system.inspect",
                description: "Inspect system state",
                input_schema: %{}
              }
            ],
            effects: []
          },
          %Target.Capabilities{
            observations: [
              operation(
                "observe.system",
                "system.inspect",
                "Inspect system state",
                %{"payload" => String.duplicate("x", 65_537)}
              )
            ],
            effects: []
          },
          %Target.Capabilities{observations: [], effects: [effect_with_requirement]},
          %Target.Capabilities{
            observations: [duplicate],
            effects: [
              %{
                effect_with_requirement
                | evidence_requirements: [
                    %{
                      hd(effect_with_requirement.evidence_requirements)
                      | parameter: "missing_parameter"
                    }
                  ]
              }
            ]
          }
        ] do
      assert {:error, error} =
               Providers.target_capabilities(
                 context.provider.id,
                 %Target.CapabilitiesRequest{
                   provider_revision: context.provider.revision,
                   connection: %Target.Connection{endpoint: "reachable"}
                 },
                 invocation(capabilities),
                 actor: context.admin
               )

      assert target_error(error).message == "Invalid capabilities result"
    end

    secret_bearing = %Target.Capabilities{
      observations: [
        operation(
          "observe.system",
          "system.inspect",
          "Inspect using #{@token}",
          %{"properties" => %{"credential" => %{"const" => @token}}}
        )
      ],
      effects: []
    }

    assert %Target.Capabilities{observations: [redacted]} =
             Providers.target_capabilities!(
               context.provider.id,
               %Target.CapabilitiesRequest{
                 provider_revision: context.provider.revision,
                 connection: %Target.Connection{endpoint: "reachable"}
               },
               invocation(secret_bearing),
               actor: context.admin
             )

    assert redacted.description == "Inspect using [REDACTED]"
    assert redacted.input_schema["properties"]["credential"]["const"] == "[REDACTED]"
    refute inspect(redacted) =~ @token
  end

  test "observations retry bounded read failures and redact results", context do
    request = observation_request(context.provider.revision, 3)

    observation = %Target.Observation{
      facts: %{output: @token},
      observed_at: DateTime.utc_now(),
      evidence: ["credential=#{@token}"]
    }

    Process.put(:target_attempt, 0)

    invocation = %{
      test_pid: self(),
      respond: fn ->
        attempt = Process.get(:target_attempt, 0) + 1
        Process.put(:target_attempt, attempt)

        if attempt == 1,
          do: {:error, :retryable, "connection reset"},
          else: {:ok, observation}
      end
    }

    assert %Target.Observation{} =
             observed =
             Providers.target_observe!(context.provider.id, request, invocation,
               actor: context.admin,
               authorize?: false
             )

    assert observed.facts == %{output: "[REDACTED]"}
    assert observed.evidence == ["credential=[REDACTED]"]
    assert_receive {:observe, %{token: @token}, ^request}
    assert_receive {:observe, %{token: @token}, ^request}
    refute_receive {:observe, _, _}
  end

  test "timeouts remain typed and cancellation or stale revision prevents dispatch", context do
    timeout_request = observation_request(context.provider.revision, 1)

    assert {:error, error} =
             Providers.target_observe(
               context.provider.id,
               timeout_request,
               invocation({:error, :timeout, "read deadline exceeded"}),
               actor: context.admin,
               authorize?: false
             )

    assert target_error(error).category == :timeout
    assert_receive {:observe, %{token: @token}, ^timeout_request}

    cancelled_request = observation_request(context.provider.revision, 2)

    assert {:error, error} =
             Providers.target_observe(
               context.provider.id,
               cancelled_request,
               %{cancelled?: fn -> true end, test_pid: self()},
               actor: context.admin,
               authorize?: false
             )

    assert %Target.BeforeSendError{cause: %Target.Error{category: :cancelled}} =
             Target.BeforeSendError.unwrap(error)

    refute_receive {:observe, _, _}

    stale_request = observation_request(context.provider.revision + 1, 1)

    assert {:error, _error} =
             Providers.target_observe(
               context.provider.id,
               stale_request,
               invocation(flunk_response()),
               actor: context.admin,
               authorize?: false
             )

    refute_receive {:observe, _, _}
  end

  test "request retry and payload bounds stop before dispatch", context do
    invalid_connection = %{
      observation_request(context.provider.revision, 1)
      | connection: %Target.Connection{endpoint: ""}
    }

    assert {:error, connection_error} =
             Providers.target_observe(
               context.provider.id,
               invalid_connection,
               invocation(flunk_response()),
               actor: context.admin,
               authorize?: false
             )

    assert target_error(connection_error).message == "Invalid Method connection"
    refute_receive {:observe, _, _}

    invalid_vocabulary = %{
      observation_request(context.provider.revision, 1)
      | capability: :system,
        operation: ""
    }

    assert {:error, vocabulary_error} =
             Providers.target_observe(
               context.provider.id,
               invalid_vocabulary,
               invocation(flunk_response()),
               actor: context.admin,
               authorize?: false
             )

    assert target_error(vocabulary_error).message == "Invalid observation request"
    refute_receive {:observe, _, _}

    excessive_retries = observation_request(context.provider.revision, 6)

    assert {:error, retry_error} =
             Providers.target_observe(
               context.provider.id,
               excessive_retries,
               invocation(flunk_response()),
               actor: context.admin,
               authorize?: false
             )

    assert target_error(retry_error).message == "Invalid observation request"
    refute_receive {:observe, _, _}

    oversized_effect = %{
      effect_request(context.provider.revision, "operation-oversized")
      | parameters: %{"payload" => String.duplicate("x", 65_537)}
    }

    assert {:error, effect_error} =
             Providers.target_effect(
               context.provider.id,
               oversized_effect,
               invocation(flunk_response()),
               actor: context.admin,
               authorize?: false
             )

    assert target_error(effect_error).message == "Invalid effect request"
    refute_receive {:effect, _, _}
  end

  test "non-JSON Target results are rejected at the Provider boundary", context do
    request = observation_request(context.provider.revision, 1)

    invalid = %Target.Observation{
      facts: %{"process" => self()},
      observed_at: DateTime.utc_now(),
      evidence: [{:raw, "tuple"}]
    }

    assert {:error, error} =
             Providers.target_observe(
               context.provider.id,
               request,
               invocation(invalid),
               actor: context.admin,
               authorize?: false
             )

    assert target_error(error).message == "Invalid observation result"
    assert_receive {:observe, %{token: @token}, ^request}

    oversized_combination = %Target.Observation{
      facts: %{"first" => String.duplicate("x", 40_000)},
      observed_at: DateTime.utc_now(),
      evidence: [String.duplicate("y", 40_000)]
    }

    assert {:error, size_error} =
             Providers.target_observe(
               context.provider.id,
               request,
               invocation(oversized_combination),
               actor: context.admin,
               authorize?: false
             )

    assert target_error(size_error).message == "Invalid observation result"
    assert_receive {:observe, %{token: @token}, ^request}
  end

  test "effects dispatch once and preserve applied, unknown, partial and failed results",
       context do
    for status <- [:applied, :unknown, :partial, :failed] do
      request = effect_request(context.provider.revision, "operation-#{status}")
      result = %Target.EffectResult{status: status, details: %{status: status}}

      assert ^result =
               Providers.target_effect!(context.provider.id, request, invocation(result),
                 actor: context.operator,
                 authorize?: false
               )

      assert_receive {:effect, %{token: @token}, ^request}
      refute_receive {:effect, _, _}
    end

    request = effect_request(context.provider.revision, "operation-retry")

    assert {:error, error} =
             Providers.target_effect(
               context.provider.id,
               request,
               invocation({:error, :retryable, "unsafe retry"}),
               actor: context.admin,
               authorize?: false
             )

    assert target_error(error).category == :failed
    assert_receive {:effect, %{token: @token}, ^request}
    refute_receive {:effect, _, _}

    raised_request = effect_request(context.provider.revision, "operation-lost-response")

    assert %Target.EffectResult{status: :unknown, details: %{error: message}} =
             Providers.target_effect!(
               context.provider.id,
               raised_request,
               %{test_pid: self(), respond: fn -> raise "lost #{@token}" end},
               actor: context.admin,
               authorize?: false
             )

    assert message == "lost [REDACTED]"
    assert_receive {:effect, %{token: @token}, ^raised_request}
    refute_receive {:effect, _, _}
  end

  test "only context-marked aggregates retain classified causes and redact their progress",
       context do
    classified =
      Ash.Error.Changes.InvalidAttribute.exception(field: :context, message: "context #{@token}")

    progress = %{"bytes_sent" => 8, "description" => "receipt #{@token}"}
    fault = Target.Error.context_failure(classified, progress)
    request = effect_request(context.provider.revision, "context-error")

    assert {:error, %Ash.Error.Invalid{} = error} =
             Providers.target_effect(context.provider.id, request, invocation({:error, fault}),
               actor: context.admin,
               authorize?: false
             )

    assert Target.Error.context_failure?(error)
    assert Exception.message(error) =~ "context [REDACTED]"
    refute Exception.message(error) =~ @token

    assert Target.Error.context_progress(error) == %{
             "bytes_sent" => 8,
             "description" => "receipt [REDACTED]"
           }

    assert_receive {:effect, _, ^request}

    unrelated =
      Ash.Error.to_error_class([
        RuntimeError.exception("native #{@token}"),
        Target.Error.exception(category: :failed, message: "ordinary receipt error")
      ])

    assert {:error, rejected} =
             Providers.target_effect(
               context.provider.id,
               request,
               invocation({:error, unrelated}),
               actor: context.admin,
               authorize?: false
             )

    refute Target.Error.context_failure?(rejected)
    assert target_error(rejected).message == "Invalid effect result"
    refute Exception.message(rejected) =~ @token
    assert_receive {:effect, _, ^request}
  end

  test "verification is independent and malformed or raised adapter results are rejected",
       context do
    request = verification_request(context.provider.revision)
    verification = %Target.Verification{status: :verified, observed_at: DateTime.utc_now()}

    assert ^verification =
             Providers.target_verify!(context.provider.id, request, invocation(verification),
               actor: context.admin,
               authorize?: false
             )

    assert_receive {:verify, %{token: @token}, ^request}

    assert {:error, malformed} =
             Providers.target_verify(
               context.provider.id,
               request,
               invocation(%{status: :verified}),
               actor: context.admin,
               authorize?: false
             )

    assert target_error(malformed).message == "Invalid verification result"

    assert {:error, raised} =
             Providers.target_verify(
               context.provider.id,
               request,
               %{respond: fn -> raise "credential #{@token} failed" end},
               actor: context.admin,
               authorize?: false
             )

    assert target_error(raised).message == "credential [REDACTED] failed"
    refute inspect(raised) =~ @token
  end

  test "adapter observation and verification facts are bounded", context do
    oversized = %{"payload" => String.duplicate("x", 65_537)}
    observation_request = observation_request(context.provider.revision, 1)

    assert {:error, observation_error} =
             Providers.target_observe(
               context.provider.id,
               observation_request,
               invocation(%Target.Observation{facts: oversized, observed_at: DateTime.utc_now()}),
               actor: context.admin,
               authorize?: false
             )

    assert target_error(observation_error).message == "Invalid observation result"

    verification_request = verification_request(context.provider.revision)

    assert {:error, verification_error} =
             Providers.target_verify(
               context.provider.id,
               verification_request,
               invocation(%Target.Verification{
                 status: :verified,
                 observed_at: DateTime.utc_now(),
                 facts: oversized
               }),
               actor: context.admin,
               authorize?: false
             )

    assert target_error(verification_error).message == "Invalid verification result"
  end

  @tag redaction_capacity: true
  @tag reference_capacity: true
  test "opaque effect references obey the raw byte budget before normalization", context do
    request = effect_request(context.provider.revision, "reference-limit")
    reference = " " <> String.duplicate("x", 65_534) <> " "

    assert {:ok, %Target.EffectResult{reference: ^reference}} =
             Providers.target_effect(
               context.provider.id,
               request,
               invocation(%Target.EffectResult{status: :applied, reference: reference}),
               actor: context.admin,
               authorize?: false
             )

    for invalid <- [reference <> "x", String.duplicate("界", 21_846), <<255>>, "a\0b"] do
      assert {:error, error} =
               Providers.target_effect(
                 context.provider.id,
                 request,
                 invocation(%Target.EffectResult{status: :applied, reference: invalid}),
                 actor: context.admin,
                 authorize?: false
               )

      assert target_error(error).message == "Invalid effect result"
    end
  end

  @tag redaction_capacity: true
  test "redaction does not expand its inserted markers in a bounded effect receipt", context do
    provider =
      Providers.create_provider!(
        "marker-redaction-provider",
        :target,
        "fixture-target",
        %{"endpoint" => "reachable"},
        %{"api_key" => "ab", "token" => "["},
        actor: context.admin
      )
      |> then(&Providers.enable_provider!(&1, 1, actor: context.admin))

    details = %{"payload" => String.duplicate("ab", 6_000)}
    expected = %{"payload" => String.duplicate("[REDACTED]", 6_000)}
    assert byte_size(Jason.encode!(details)) == 12_014
    assert byte_size(Jason.encode!(expected)) == 60_014

    assert {:ok, %Target.EffectResult{status: :applied, details: ^expected}} =
             Providers.target_effect(
               provider.id,
               effect_request(provider.revision, "marker-redaction"),
               invocation(%Target.EffectResult{status: :applied, details: details}),
               actor: context.admin,
               authorize?: false
             )
  end

  @tag json_capacity: true
  test "effect request and receipt limits count encoded JSON bytes", context do
    payload = %{"payload" => String.duplicate("x", 65_522)}
    assert byte_size(Jason.encode!(payload)) == 65_536
    request = %{effect_request(context.provider.revision, "json-limit") | parameters: payload}
    result = %Target.EffectResult{status: :applied, details: payload}

    assert {:ok, ^result} =
             Providers.target_effect(context.provider.id, request, invocation(result),
               actor: context.admin,
               authorize?: false
             )

    assert_receive {:effect, _state, ^request}

    escaped = %{"payload" => String.duplicate(<<0>>, 11_000)}
    assert byte_size(Jason.encode!(escaped)) == 66_014

    assert {:error, input_error} =
             Providers.target_effect(
               context.provider.id,
               %{request | parameters: escaped},
               invocation(flunk_response()),
               actor: context.admin,
               authorize?: false
             )

    assert target_error(input_error).message == "Invalid effect request"
    refute_receive {:effect, _state, _request}
  end

  @tag escaped_json_capacity: true
  test "escaped JSON above the result limit is rejected for every Target receipt", context do
    escaped = %{"payload" => String.duplicate(<<0>>, 11_000)}
    assert byte_size(Jason.encode!(escaped)) == 66_014

    effect = %Target.EffectResult{status: :applied, details: escaped}

    assert {:error, effect_error} =
             Providers.target_effect(
               context.provider.id,
               effect_request(context.provider.revision, "escaped-json"),
               invocation(effect),
               actor: context.admin,
               authorize?: false
             )

    assert target_error(effect_error).message == "Invalid effect result"

    for {facts, evidence} <- [{escaped, []}, {%{}, [escaped]}] do
      assert {:error, observation_error} =
               Providers.target_observe(
                 context.provider.id,
                 observation_request(context.provider.revision, 1),
                 invocation(%Target.Observation{
                   facts: facts,
                   evidence: evidence,
                   observed_at: DateTime.utc_now()
                 }),
                 actor: context.admin,
                 authorize?: false
               )

      assert target_error(observation_error).message == "Invalid observation result"

      assert {:error, verification_error} =
               Providers.target_verify(
                 context.provider.id,
                 verification_request(context.provider.revision),
                 invocation(%Target.Verification{
                   status: :verified,
                   facts: facts,
                   evidence: evidence,
                   observed_at: DateTime.utc_now()
                 }),
                 actor: context.admin,
                 authorize?: false
               )

      assert target_error(verification_error).message == "Invalid verification result"
    end
  end

  defp observation_request(provider_revision, max_attempts) do
    struct!(Target.ObservationRequest,
      provider_revision: provider_revision,
      target_id: "target-1",
      target_revision: 4,
      access_method_id: "access-method-1",
      access_method_revision: 2,
      connection: %Target.Connection{endpoint: "ssh://192.0.2.10:22"},
      capability: "observe.command",
      operation: "system.inspect",
      authorization_digest: "authorization-digest",
      max_attempts: max_attempts
    )
  end

  defp effect_request(provider_revision, operation_id) do
    struct!(Target.EffectRequest,
      provider_revision: provider_revision,
      target_id: "target-1",
      target_revision: 4,
      access_method_id: "access-method-1",
      access_method_revision: 2,
      connection: %Target.Connection{endpoint: "ssh://192.0.2.10:22"},
      capability: "effect.command",
      operation: "service.restart",
      authorization_digest: "authorization-digest",
      operation_id: operation_id,
      idempotency_key: "idempotency-#{operation_id}"
    )
  end

  defp verification_request(provider_revision) do
    struct!(Target.VerificationRequest,
      provider_revision: provider_revision,
      target_id: "target-1",
      target_revision: 4,
      access_method_id: "access-method-1",
      access_method_revision: 2,
      connection: %Target.Connection{endpoint: "ssh://192.0.2.10:22"},
      capability: "observe.command",
      operation: "service.inspect",
      authorization_digest: "authorization-digest",
      operation_id: "operation-1"
    )
  end

  defp invocation(%_{} = response),
    do: %{test_pid: self(), respond: fn -> {:ok, response} end}

  defp invocation(response), do: %{test_pid: self(), respond: fn -> response end}

  defp flunk_response, do: fn -> flunk("stale invocation reached adapter") end

  defp operation(capability, operation, description, input_schema \\ %{}) do
    %Target.Operation{
      capability: capability,
      operation: operation,
      description: description,
      input_schema: input_schema,
      output_schema: %{
        "type" => "object",
        "properties" => %{"status" => %{"type" => "string"}},
        "additionalProperties" => false
      }
    }
  end

  defp target_error(%{errors: errors}) do
    Enum.find_value(errors, fn
      %Target.Error{} = error -> error
      nested when is_map(nested) -> target_error(nested)
      _other -> nil
    end)
  end

  defp target_error(_error), do: nil
end
