defmodule Skopos.Providers.SignalTest do
  use Skopos.DataCase, async: false

  alias Skopos.Accounts
  alias Skopos.Providers
  alias Skopos.Providers.Signal

  @password "correct horse battery staple"
  @secret "signal-provider-secret"

  setup do
    admin =
      Accounts.bootstrap!("signal-admin@example.com", @password, @password, authorize?: true)

    provider =
      Providers.create_provider!(
        "signal-provider",
        :signal,
        "fixture-signal",
        %{"source" => "test-monitor"},
        %{"secret" => @secret},
        actor: admin
      )
      |> then(&Providers.check_provider!(&1.id, 1, %{}, actor: admin))
      |> then(&Providers.enable_provider!(&1, 1, actor: admin))

    %{provider: provider}
  end

  test "source authentication precedes normalization and redacts failures", context do
    envelope = envelope("bad-signature")

    invocation = %{
      test_pid: self(),
      authenticate: fn _state, _envelope ->
        {:error, :authentication, "bad #{@secret}"}
      end,
      normalize: fn _state, _envelope, _receipt ->
        flunk("unauthenticated input was normalized")
      end
    }

    assert {:error, error} = ingest(context.provider, envelope, invocation)
    assert signal_error(error).category == :authentication
    assert signal_error(error).message == "bad [REDACTED]"
    refute inspect(error) =~ @secret
    assert_receive {:authenticate, %{secret: @secret}, ^envelope}
    refute_receive {:normalize, _receipt}
  end

  test "repeated source input produces the same authenticated receipt identity", context do
    envelope = envelope("same-event")
    invocation = valid_invocation(:firing, 10, %{kind: :hostname, value: "server-1"})

    first = ingest!(context.provider, envelope, invocation)
    duplicate = ingest!(context.provider, envelope, invocation)

    assert first.receipt.receipt_id == duplicate.receipt.receipt_id
    assert hd(first.events).event_key == hd(duplicate.events).event_key
  end

  test "firing and recovery order and unresolved target data pass through without Case state",
       context do
    target_ref = %{kind: :hostname, value: "missing-server"}

    firing =
      ingest_event!(
        context.provider,
        envelope("firing"),
        valid_invocation(:firing, 10, target_ref)
      )

    recovered =
      ingest_event!(
        context.provider,
        envelope("recovered"),
        valid_invocation(:recovered, 11, target_ref)
      )

    assert [firing.state, recovered.state] == [:firing, :recovered]
    assert [firing.source_sequence, recovered.source_sequence] == [10, 11]
    assert firing.event_key == recovered.event_key
    assert firing.target_ref == target_ref
    refute Map.has_key?(Map.from_struct(firing), :case_id)
  end

  test "one authenticated group normalizes into bounded individual source events", context do
    envelope = envelope("group")

    invocation = %{
      test_pid: self(),
      authenticate: fn adapter_state, _envelope ->
        {:ok,
         %Signal.AuthenticatedReceipt{
           receipt_id: "group-receipt",
           source: adapter_state.source,
           metadata: %{"group" => "database"}
         }}
      end,
      normalize: fn _adapter_state, _envelope, receipt ->
        {:ok,
         [
           event(receipt, "alert-a", :firing, 10),
           event(receipt, "alert-b", :recovered, 11)
         ]}
      end
    }

    result = ingest!(context.provider, envelope, invocation)

    assert result.receipt.receipt_id == "group-receipt"
    assert result.receipt.source == "test-monitor"

    assert Enum.map(result.events, &{&1.event_key, &1.state, &1.source_sequence}) == [
             {"alert-a", :firing, 10},
             {"alert-b", :recovered, 11}
           ]
  end

  test "normalization rejects empty and duplicate source-event batches", context do
    valid = valid_invocation(:firing, 1, nil)

    for events <- [
          [],
          [
            %Signal.Event{
              receipt_id: "receipt",
              event_key: "same-alert",
              state: :firing,
              occurred_at: DateTime.utc_now()
            },
            %Signal.Event{
              receipt_id: "receipt",
              event_key: "same-alert",
              state: :recovered,
              occurred_at: DateTime.utc_now()
            }
          ]
        ] do
      invocation = %{
        valid
        | authenticate: fn adapter_state, _envelope ->
            {:ok,
             %Signal.AuthenticatedReceipt{
               receipt_id: "receipt",
               source: adapter_state.source
             }}
          end,
          normalize: fn _state, _envelope, _receipt -> {:ok, events} end
      }

      assert {:error, error} = ingest(context.provider, envelope("invalid-batch"), invocation)
      assert signal_error(error).message == "Invalid normalized events"
    end
  end

  test "invalid envelope and stale provider revision stop before authentication", context do
    invalid = %Signal.Envelope{
      body: "body",
      headers: %{"x-header" => [:not_normalized]},
      received_at: DateTime.utc_now()
    }

    assert {:error, error} = ingest(context.provider, invalid, unreachable_invocation())
    assert signal_error(error).category == :invalid_input
    refute_receive {:authenticate, _, _}

    assert {:error, _error} =
             Providers.signal_ingest(
               context.provider.id,
               context.provider.revision + 1,
               envelope("stale"),
               unreachable_invocation()
             )

    refute_receive {:authenticate, _, _}
  end

  test "normalization validates identity and redacts normalized values", context do
    envelope = envelope("normalization")
    valid = valid_invocation(:firing, 1, nil)

    mismatched = %{
      valid
      | normalize: fn _state, _envelope, receipt ->
          {:ok, [%{event(receipt, "alert-1", :firing, 1) | receipt_id: "another-receipt"}]}
        end
    }

    assert {:error, error} = ingest(context.provider, envelope, mismatched)
    assert signal_error(error).message == "Invalid normalized events"

    redacted = %{
      valid
      | normalize: fn _state, _envelope, receipt ->
          {:ok,
           [
             %{
               event(receipt, "alert-1", :firing, 1)
               | attributes: %{detail: "credential=#{@secret}"}
             }
           ]}
        end
    }

    event = ingest_event!(context.provider, envelope, redacted)
    assert event.attributes == %{detail: "credential=[REDACTED]"}
  end

  test "receipt and normalized source facts are bounded", context do
    envelope = envelope("bounded-facts")
    valid = valid_invocation(:firing, 1, nil)
    too_many_facts = Map.new(1..101, &{"fact-#{&1}", &1})

    oversized_receipt = %{
      valid
      | authenticate: fn adapter_state, _envelope ->
          {:ok,
           %Signal.AuthenticatedReceipt{
             receipt_id: "receipt",
             source: adapter_state.source,
             metadata: too_many_facts
           }}
        end
    }

    assert {:error, receipt_error} = ingest(context.provider, envelope, oversized_receipt)
    assert signal_error(receipt_error).message == "Authenticated receipt facts are too large"

    oversized_event = %{
      valid
      | normalize: fn _adapter_state, _envelope, receipt ->
          {:ok,
           [
             %{
               event(receipt, "alert-1", :firing, 1)
               | attributes: %{"payload" => String.duplicate("x", 65_537)}
             }
           ]}
        end
    }

    assert {:error, event_error} = ingest(context.provider, envelope, oversized_event)
    assert signal_error(event_error).message == "Invalid normalized events"
  end

  defp ingest(provider, envelope, invocation) do
    Providers.signal_ingest(provider.id, provider.revision, envelope, invocation)
  end

  defp ingest!(provider, envelope, invocation) do
    Providers.signal_ingest!(provider.id, provider.revision, envelope, invocation)
  end

  defp ingest_event!(provider, envelope, invocation) do
    provider |> ingest!(envelope, invocation) |> Map.fetch!(:events) |> List.first()
  end

  defp valid_invocation(state, sequence, target_ref) do
    %{
      test_pid: self(),
      authenticate: fn adapter_state, envelope ->
        receipt_id = Base.encode16(:crypto.hash(:sha256, envelope.body), case: :lower)

        {:ok,
         %Signal.AuthenticatedReceipt{
           receipt_id: receipt_id,
           source: adapter_state.source
         }}
      end,
      normalize: fn _adapter_state, _envelope, receipt ->
        {:ok, [%{event(receipt, "alert-1", state, sequence) | target_ref: target_ref}]}
      end
    }
  end

  defp event(receipt, event_key, state, sequence) do
    %Signal.Event{
      receipt_id: receipt.receipt_id,
      event_key: event_key,
      state: state,
      occurred_at: DateTime.utc_now(),
      source_sequence: sequence
    }
  end

  defp unreachable_invocation do
    %{
      test_pid: self(),
      authenticate: fn _state, _envelope -> flunk("invalid input reached authentication") end,
      normalize: fn _state, _envelope, _receipt ->
        flunk("invalid input reached normalization")
      end
    }
  end

  defp envelope(body) do
    %Signal.Envelope{body: body, headers: %{}, received_at: DateTime.utc_now()}
  end

  defp signal_error(%{errors: errors}) do
    Enum.find_value(errors, fn
      %Signal.Error{} = error -> error
      nested when is_map(nested) -> signal_error(nested)
      _other -> nil
    end)
  end

  defp signal_error(_error), do: nil
end
