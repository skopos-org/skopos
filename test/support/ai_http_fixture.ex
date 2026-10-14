defmodule Skopos.AIHTTPFixture do
  import Plug.Conn

  def init(agent), do: agent

  def call(conn, agent) do
    {:ok, body, conn} = read_body(conn)

    request = %{
      path: conn.request_path,
      headers: conn.req_headers,
      body: body
    }

    mode =
      Agent.get_and_update(agent, fn state ->
        {mode, state} = next_mode(state)
        {mode, %{state | requests: [request | state.requests]}}
      end)

    response = respond(conn, request, check_decision(request.body, mode))
    Agent.update(agent, &Map.put(&1, :response_complete, true))
    response
  end

  defp next_mode(%{mode: {:sequence, [mode | remaining]}} = state),
    do: {mode, %{state | mode: {:sequence, remaining}}}

  defp next_mode(%{mode: {:sequence, []}} = state),
    do: {{:raw_text, ""}, state}

  defp next_mode(state), do: {state.mode, state}

  defp respond(conn, request, {:sleep, milliseconds}) do
    Process.sleep(milliseconds)
    respond(conn, request, {:decision, handoff()})
  end

  defp respond(conn, request, {:sleep, milliseconds, decision}) do
    Process.sleep(milliseconds)
    respond(conn, request, {:decision, decision})
  end

  defp respond(conn, request, {:decision, decision}) do
    decision = wire_decision(decision)

    cond do
      request.path == "/v1/messages" and
          String.contains?(request.body, "\"output_format\"") ->
        json(conn, anthropic_text_response(decision))

      request.path == "/v1/messages" ->
        json(conn, anthropic_response(decision))

      String.contains?(request.body, "\"tool_choice\"") ->
        json(conn, openai_tool_response(decision))

      true ->
        json(conn, openai_text_response(decision))
    end
  end

  defp respond(conn, _request, {:raw_text, text}) do
    json(conn, openai_text_response(text, false))
  end

  defp respond(conn, _request, {:raw_tool_arguments, arguments}) do
    json(conn, openai_tool_response(arguments, :raw))
  end

  defp respond(conn, _request, {:raw_text_length, text}) do
    response = openai_text_response(text, false)
    choices = Enum.map(response["choices"], &Map.put(&1, "finish_reason", "length"))
    json(conn, %{response | "choices" => choices})
  end

  defp respond(conn, _request, {:stream, decision}) do
    decision = wire_decision(decision)

    first = %{
      "id" => "chatcmpl-test",
      "object" => "chat.completion.chunk",
      "created" => 1,
      "model" => "test-model",
      "choices" => [
        %{
          "index" => 0,
          "delta" => %{"role" => "assistant", "content" => Jason.encode!(decision)},
          "finish_reason" => nil
        }
      ]
    }

    last = %{
      "id" => "chatcmpl-test",
      "object" => "chat.completion.chunk",
      "created" => 1,
      "model" => "test-model",
      "choices" => [%{"index" => 0, "delta" => %{}, "finish_reason" => "stop"}],
      "usage" => %{"prompt_tokens" => 7, "completion_tokens" => 5, "total_tokens" => 12}
    }

    body =
      "data: #{Jason.encode!(first)}\n\n" <>
        "data: #{Jason.encode!(last)}\n\n" <>
        "data: [DONE]\n\n"

    conn
    |> put_resp_content_type("text/event-stream")
    |> send_resp(200, body)
  end

  defp json(conn, body) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, Jason.encode!(body))
  end

  defp openai_text_response(decision) do
    openai_text_response(decision, true)
  end

  defp openai_text_response(decision, encode?) do
    content = if encode?, do: Jason.encode!(decision), else: decision
    base_response(%{"role" => "assistant", "content" => content}, "stop")
  end

  defp openai_tool_response(decision), do: openai_tool_response(Jason.encode!(decision), :raw)

  defp openai_tool_response(arguments, :raw) do
    base_response(
      %{
        "role" => "assistant",
        "content" => nil,
        "tool_calls" => [
          %{
            "id" => "call_test",
            "type" => "function",
            "function" => %{
              "name" => "structured_output",
              "arguments" => arguments
            }
          }
        ]
      },
      "tool_calls"
    )
  end

  defp base_response(message, finish_reason) do
    %{
      "id" => "chatcmpl-test",
      "object" => "chat.completion",
      "created" => 1,
      "model" => "test-model",
      "choices" => [
        %{"index" => 0, "message" => message, "finish_reason" => finish_reason}
      ],
      "usage" => %{"prompt_tokens" => 7, "completion_tokens" => 5, "total_tokens" => 12}
    }
  end

  defp anthropic_text_response(decision) do
    %{
      "id" => "msg_test",
      "type" => "message",
      "role" => "assistant",
      "model" => "test-model",
      "stop_reason" => "end_turn",
      "content" => [%{"type" => "text", "text" => Jason.encode!(decision)}],
      "usage" => %{"input_tokens" => 7, "output_tokens" => 5}
    }
  end

  defp anthropic_response(decision) do
    %{
      "id" => "msg-test",
      "type" => "message",
      "role" => "assistant",
      "model" => "test-model",
      "stop_reason" => "tool_use",
      "content" => [
        %{
          "type" => "tool_use",
          "id" => "toolu_test",
          "name" => "structured_output",
          "input" => decision
        }
      ],
      "usage" => %{"input_tokens" => 7, "output_tokens" => 5}
    }
  end

  defp check_decision(body, {:decision, _decision} = mode) do
    if String.contains?(body, "Return the required connection-check object"),
      do: {:decision, %{"status" => "ready"}},
      else: mode
  end

  defp check_decision(_body, mode), do: mode

  defp wire_decision(%{"type" => "proposal", "reason" => reason} = decision) do
    verification = decision["verification"]

    %{
      "reason" => reason,
      "intent" => %{
        "type" => "proposal",
        "delay_seconds" => decision["delay_seconds"],
        "purpose" => decision["purpose"],
        "action" => action(decision),
        "evidence_ids" => decision["evidence_ids"],
        "affected_conditions" => decision["affected_conditions"],
        "verification" =>
          verification
          |> action()
          |> Map.put("expected_result_json", Jason.encode!(verification["expected_result"]))
      }
    }
  end

  defp wire_decision(%{"type" => _type, "reason" => reason} = decision) do
    %{
      "reason" => reason,
      "intent" => Map.drop(decision, ["reason"])
    }
  end

  defp wire_decision(decision), do: decision

  def action(value) do
    %{
      "tool_id" => value["tool_id"],
      "selectors_json" => Jason.encode!(value["selectors"]),
      "parameters_json" => Jason.encode!(value["parameters"])
    }
  end

  defp handoff, do: %{"type" => "handoff", "reason" => "probe", "required_input" => "human"}
end
