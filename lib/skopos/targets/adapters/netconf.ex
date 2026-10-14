defmodule Skopos.Targets.Adapters.NETCONF do
  @moduledoc false

  @behaviour Skopos.Providers.Adapter
  @behaviour Skopos.Providers.Target

  alias Skopos.Providers.Target
  alias Skopos.Transports.{NETCONF, SSH}

  @observation "request.netconf.observe"
  @effect "request.netconf.effect"

  @impl Skopos.Providers.Adapter
  def type, do: "netconf"

  @impl Skopos.Providers.Adapter
  def kind, do: :target

  @impl Skopos.Providers.Target
  def access_method_profile do
    %Target.AccessMethodProfile{
      method: "netconf",
      capabilities: [@observation, @effect]
    }
  end

  @impl Skopos.Providers.Adapter
  def build(configuration, credentials) when is_map(configuration),
    do: SSH.build(Map.put_new(configuration, "max_output_bytes", 60_000), credentials)

  def build(configuration, credentials), do: SSH.build(configuration, credentials)

  @impl Skopos.Providers.Target
  defdelegate bind_connection(state, connection), to: Skopos.Targets.Adapters.SSH

  @impl Skopos.Providers.Adapter
  def check(%SSH.Config{} = state, %{"endpoint" => endpoint}) do
    case NETCONF.check(state, endpoint) do
      {:ok, _session} ->
        :ok

      {:error, category, message} when category in [:authentication, :host_key] ->
        {:error, :authentication, message}

      {:error, _category, message} ->
        {:error, :unreachable, message}
    end
  end

  def check(_state, _input),
    do: {:error, :invalid_configuration, "NETCONF check requires an endpoint"}

  @impl Skopos.Providers.Target
  def capabilities(_state, _invocation) do
    input = %{
      "type" => "object",
      "properties" => %{
        "selectors" => %{"type" => "object", "maxProperties" => 0},
        "parameters" => %{
          "type" => "object",
          "properties" => %{
            "body" => %{
              "type" => "string",
              "minLength" => 1,
              "maxLength" => NETCONF.max_body_bytes()
            }
          },
          "required" => ["body"],
          "additionalProperties" => false
        }
      },
      "required" => ["selectors", "parameters"],
      "additionalProperties" => false
    }

    output = %{
      "type" => "object",
      "properties" => %{"reply" => %{"type" => "string", "minLength" => 1, "maxLength" => 60_000}},
      "required" => ["reply"],
      "additionalProperties" => false
    }

    sequence_input =
      put_in(input, ["properties", "parameters"], %{
        "type" => "object",
        "properties" => %{
          "rpcs" => %{
            "type" => "array",
            "minItems" => 1,
            "maxItems" => 8,
            "items" => %{
              "type" => "string",
              "minLength" => 1,
              "maxLength" => NETCONF.max_body_bytes()
            }
          }
        },
        "required" => ["rpcs"],
        "additionalProperties" => false
      })

    subscription_input =
      put_in(input, ["properties", "parameters"], %{
        "type" => "object",
        "properties" => %{
          "body" => %{
            "type" => "string",
            "minLength" => 1,
            "maxLength" => NETCONF.max_body_bytes()
          },
          "max_events" => %{"type" => "integer", "minimum" => 1, "maximum" => 20},
          "wait_ms" => %{"type" => "integer", "minimum" => 100, "maximum" => 20_000},
          "rpcs" => %{
            "type" => "array",
            "maxItems" => 8,
            "description" =>
              "Optional same-session RPCs; ${subscription_id} inserts the ID returned by establish-subscription",
            "items" => %{
              "type" => "string",
              "minLength" => 1,
              "maxLength" => NETCONF.max_body_bytes()
            }
          }
        },
        "required" => ["body", "max_events", "wait_ms"],
        "additionalProperties" => false
      })

    {:ok,
     %Target.Capabilities{
       observations: [
         %Target.Operation{
           capability: @observation,
           operation: "rpc.observe",
           description: "Read one exact NETCONF RPC",
           input_schema: input,
           output_schema: output,
           verification_schema: output
         }
       ],
       effects: [
         %Target.Operation{
           capability: @effect,
           operation: "rpc.execute",
           description: "Execute one exact NETCONF RPC after authority review",
           input_schema: input
         },
         %Target.Operation{
           capability: @effect,
           operation: "rpc.sequence",
           description: "Execute exact NETCONF RPCs in one session after authority review",
           input_schema: sequence_input
         },
         %Target.Operation{
           capability: @effect,
           operation: "rpc.subscribe",
           description:
             "Run a NETCONF subscription and optional same-session RPCs while receiving bounded notifications",
           input_schema: subscription_input
         }
       ]
     }}
  end

  @impl Skopos.Providers.Target
  def classify_request(%SSH.Config{} = state, %{operation: "rpc.subscribe"} = request) do
    with {:ok, _body, _rpcs, _max_events, wait_ms} <- subscription_request(request),
         true <- wait_ms + 100 < state.operation_timeout do
      {:ok, :effect}
    else
      _invalid -> {:error, :failed, "NETCONF subscription is invalid"}
    end
  end

  def classify_request(_state, %{operation: "rpc.sequence"} = request) do
    case sequence_bodies(request) do
      {:ok, _bodies} -> {:ok, :effect}
      error -> error
    end
  end

  def classify_request(_state, request) do
    case request_body(request) do
      {:ok, body} ->
        with {:ok, kind} <- NETCONF.classify_body(body) do
          if request.capability == @effect, do: {:ok, :effect}, else: {:ok, kind}
        end

      error ->
        error
    end
  end

  @impl Skopos.Providers.Target
  def observe(%SSH.Config{} = state, request, invocation) do
    with true <- request.capability == @observation,
         {:ok, body} <- request_body(request),
         {:ok, :observation} <- NETCONF.classify_body(body),
         {:ok, %NETCONF.Result{reply: reply}} <-
           NETCONF.execute(state, request.connection.endpoint, body, invocation) do
      {:ok, %Target.Observation{facts: %{"reply" => reply}, observed_at: DateTime.utc_now()}}
    else
      false -> {:error, :failed, "NETCONF observation request is invalid"}
      {:ok, :effect} -> {:error, :failed, "NETCONF observation is unsafe"}
      {:error, category, message} -> read_error(category, message)
      {:error, _cause} = error -> error
    end
  end

  @impl Skopos.Providers.Target
  def effect(%SSH.Config{} = state, %{operation: "rpc.subscribe"} = request, invocation) do
    with {:ok, body, rpcs, max_events, wait_ms} <- subscription_request(request) do
      case NETCONF.subscribe(
             state,
             request.connection.endpoint,
             body,
             rpcs,
             max_events,
             wait_ms,
             invocation
           ) do
        {:ok, progress, completion} ->
          {:ok,
           %Target.EffectResult{
             status: :applied,
             details:
               Map.put(subscription_details(progress), "completion", Atom.to_string(completion))
           }}

        {:error, category, message, progress} ->
          subscription_error(category, message, progress)

        {:error, _cause} = error ->
          error
      end
    end
  end

  def effect(%SSH.Config{} = state, %{operation: "rpc.sequence"} = request, invocation) do
    with {:ok, bodies} <- sequence_bodies(request) do
      case NETCONF.execute_many(
             state,
             request.connection.endpoint,
             bodies,
             invocation
           ) do
        {:ok, replies} ->
          {:ok,
           %Target.EffectResult{
             status: :applied,
             details: %{"completed" => length(replies), "replies" => replies}
           }}

        {:error, :rejected, message, replies} ->
          {:ok,
           %Target.EffectResult{
             status: if(replies == [], do: :failed, else: :partial),
             details: %{"completed" => length(replies), "replies" => replies, "error" => message}
           }}

        {:error, category, message, replies} ->
          sequence_error(category, message, replies)

        {:error, _cause} = error ->
          error
      end
    end
  end

  def effect(%SSH.Config{} = state, request, invocation) do
    with true <- request.capability == @effect,
         {:ok, body} <- request_body(request),
         {:ok, %NETCONF.Result{reply: reply}} <-
           NETCONF.execute(state, request.connection.endpoint, body, invocation) do
      {:ok, %Target.EffectResult{status: :applied, details: %{"reply" => reply}}}
    else
      false -> {:error, :failed, "NETCONF effect request is invalid"}
      {:error, category, message} -> effect_error(category, message)
      {:error, _cause} = error -> error
    end
  end

  @impl Skopos.Providers.Target
  def verify(%SSH.Config{} = state, request, invocation) do
    with true <- request.capability == @observation,
         {:ok, body} <- request_body(request),
         {:ok, :observation} <- NETCONF.classify_body(body),
         {:ok, %NETCONF.Result{reply: reply}} <-
           NETCONF.execute(state, request.connection.endpoint, body, invocation) do
      facts = %{"reply" => reply}

      status =
        cond do
          request.expected == %{} -> :unknown
          Enum.all?(request.expected, fn {key, value} -> facts[key] == value end) -> :verified
          true -> :not_verified
        end

      {:ok, %Target.Verification{status: status, observed_at: DateTime.utc_now(), facts: facts}}
    else
      false -> {:error, :failed, "NETCONF verification request is invalid"}
      {:ok, :effect} -> {:error, :failed, "NETCONF verification is unsafe"}
      {:error, category, message} -> read_error(category, message)
      {:error, _cause} = error -> error
    end
  end

  defp request_body(%{
         capability: capability,
         operation: operation,
         selectors: %{},
         parameters: %{"body" => body} = parameters
       })
       when {capability, operation} in [
              {@observation, "rpc.observe"},
              {@effect, "rpc.execute"}
            ] and map_size(parameters) == 1 and is_binary(body),
       do: {:ok, body}

  defp request_body(_request), do: {:error, :failed, "NETCONF RPC request is invalid"}

  defp sequence_bodies(%{
         capability: @effect,
         operation: "rpc.sequence",
         selectors: %{},
         parameters: %{"rpcs" => bodies} = parameters
       })
       when map_size(parameters) == 1 and is_list(bodies) and length(bodies) in 1..8 do
    if Enum.all?(bodies, &match?({:ok, _kind}, NETCONF.classify_body(&1))),
      do: {:ok, bodies},
      else: {:error, :failed, "NETCONF sequence is invalid"}
  end

  defp sequence_bodies(_request), do: {:error, :failed, "NETCONF sequence is invalid"}

  defp subscription_request(%{
         capability: @effect,
         operation: "rpc.subscribe",
         selectors: %{},
         parameters:
           %{"body" => body, "max_events" => max_events, "wait_ms" => wait_ms} = parameters
       })
       when map_size(parameters) in [3, 4] and is_integer(max_events) and max_events in 1..20 and
              is_integer(wait_ms) and wait_ms in 100..20_000 do
    kind = NETCONF.subscription_kind(body)
    rpcs = Map.get(parameters, "rpcs", [])

    if kind in [:legacy, :dynamic] and is_list(rpcs) and length(rpcs) <= 8 and
         (kind == :dynamic or rpcs == []) and
         Enum.all?(rpcs, &match?({:ok, _kind}, NETCONF.classify_body(&1))) do
      {:ok, body, rpcs, max_events, wait_ms}
    else
      {:error, :failed, "NETCONF subscription is invalid"}
    end
  end

  defp subscription_request(_request), do: {:error, :failed, "NETCONF subscription is invalid"}

  defp subscription_error(category, message, progress) do
    if category in [
         :timeout_after_dispatch,
         :cancelled_after_dispatch,
         :disconnected_after_dispatch,
         :output_limit_after_dispatch,
         :unknown_after_dispatch
       ] or progress.events != [] or progress.subscription_id != nil do
      {:ok,
       %Target.EffectResult{
         status: :unknown,
         details: Map.put(subscription_details(progress), "error", message)
       }}
    else
      effect_error(category, message)
    end
  end

  defp subscription_details(progress) do
    details = %{
      "events" => progress.events,
      "received" => length(progress.events),
      "replies" => progress.replies,
      "completed" => length(progress.replies)
    }

    if progress.subscription_id == nil,
      do: details,
      else: Map.put(details, "subscription_id", progress.subscription_id)
  end

  defp sequence_error(category, message, replies) do
    if category in [
         :timeout_after_dispatch,
         :cancelled_after_dispatch,
         :disconnected_after_dispatch,
         :output_limit_after_dispatch,
         :unknown_after_dispatch
       ] or replies != [] do
      {:ok,
       %Target.EffectResult{
         status: :unknown,
         details: %{"completed" => length(replies), "replies" => replies, "error" => message}
       }}
    else
      effect_error(category, message)
    end
  end

  defp read_error(:cancelled, message), do: {:error, :cancelled, message}

  defp read_error(category, message) when category in [:timeout, :timeout_after_dispatch],
    do: {:error, :timeout, message}

  defp read_error(category, message)
       when category in [:unreachable, :disconnected, :disconnected_after_dispatch],
       do: {:error, :retryable, message}

  defp read_error(_category, message), do: {:error, :failed, message}

  defp effect_error(category, message)
       when category in [
              :timeout_after_dispatch,
              :cancelled_after_dispatch,
              :disconnected_after_dispatch,
              :output_limit_after_dispatch,
              :unknown_after_dispatch
            ],
       do: {:ok, %Target.EffectResult{status: :unknown, details: %{"error" => message}}}

  defp effect_error(:rejected, message),
    do: {:ok, %Target.EffectResult{status: :failed, details: %{"error" => message}}}

  defp effect_error(:cancelled, message), do: {:error, :cancelled, message}
  defp effect_error(_category, message), do: {:error, :failed, message}
end
