defmodule Skopos.Targets.Adapters.Kubernetes.Session do
  @moduledoc false
  alias Skopos.Providers.Target
  @inline_bytes 24_000
  @max_bytes 536_870_912

  def effect do
    %Target.Operation{
      capability: "request.kubernetes.effect",
      operation: "websocket.session",
      description:
        "Exchange exact frames on one Kubernetes API WebSocket path after review, then explicitly close. Channel bytes remain opaque; session completion is not remote recovery proof.",
      input_schema:
        object(%{
          "selectors" => %{"type" => "object", "maxProperties" => 0},
          "parameters" =>
            object(
              %{
                "path" => %{"type" => "string", "minLength" => 1, "maxLength" => 2_048},
                "query" => %{
                  "type" => "object",
                  "maxProperties" => 32,
                  "additionalProperties" => %{
                    "oneOf" => [
                      string(),
                      %{"type" => "array", "minItems" => 1, "maxItems" => 32, "items" => string()}
                    ]
                  }
                },
                "protocols" => %{
                  "type" => "array",
                  "minItems" => 1,
                  "maxItems" => 8,
                  "items" => %{"type" => "string", "minLength" => 1, "maxLength" => 120}
                },
                "max_bytes" => %{
                  "type" => "integer",
                  "minimum" => 1,
                  "maximum" => @max_bytes,
                  "description" =>
                    "Cumulative payload bytes per direction; inline evidence remains bounded to 24000 bytes and 256 received frames"
                },
                "files" => Target.FileReference.set_schema(),
                "steps" => %{
                  "type" => "array",
                  "minItems" => 1,
                  "maxItems" => 64,
                  "items" => %{
                    "oneOf" => [
                      object(%{
                        "op" => %{"const" => "send"},
                        "opcode" => %{"type" => "string", "enum" => ["binary", "text"]},
                        "data" => %{"type" => "string", "maxLength" => 32_000}
                      }),
                      object(
                        %{
                          "op" => %{"const" => "send"},
                          "body_file" => %{
                            "type" => "string",
                            "minLength" => 1,
                            "maxLength" => 120
                          },
                          "prefix" => %{
                            "type" => "string",
                            "maxLength" => 344,
                            "description" =>
                              "Base64 prefix on every binary file frame; defaults to empty"
                          }
                        },
                        ~w(op body_file)
                      ),
                      receive_schema(false),
                      receive_schema(true),
                      object(%{"op" => %{"const" => "close"}})
                    ]
                  }
                }
              },
              ~w(path protocols steps)
            )
        })
    }
  end

  def compile(%{
        parameters: %{"path" => path, "protocols" => protocols, "steps" => steps} = parameters,
        files: files
      }) do
    with true <-
           Enum.all?(Map.keys(parameters), &(&1 in ~w(path query protocols steps max_bytes))),
         true <- is_list(protocols) and length(protocols) in 1..8,
         true <- length(Enum.uniq(protocols)) == length(protocols),
         true <- Enum.all?(protocols, &protocol?/1),
         {:ok, query} <- query(parameters["query"] || %{}),
         limit when is_integer(limit) and limit in 1..@max_bytes <-
           Map.get(parameters, "max_bytes", @inline_bytes),
         true <- is_list(steps) and length(steps) in 1..64,
         %{"op" => "close"} = final <- List.last(steps),
         true <- map_size(final) == 1,
         {:ok, compiled, sent} <- compile_steps(Enum.drop(steps, -1), files),
         true <- Enum.reduce(compiled, 0, &(Map.get(&1, :count, 0) + &2)) <= 256,
         reserve when reserve < 60_000 <- evidence_reserve(compiled),
         true <- sent <= limit do
      {:ok,
       %{
         kind: :effect,
         transport: :websocket,
         path: path,
         query: query,
         protocols: protocols,
         steps: compiled ++ [%{op: :close}],
         max_bytes: limit,
         frame_limit: frame_limit(compiled),
         inline_bytes: min(@inline_bytes, div((60_000 - reserve) * 3, 4))
       }}
    else
      _ -> invalid()
    end
  end

  def compile(_), do: invalid()

  defp compile_steps(steps, files) do
    Enum.reduce_while(steps, {:ok, [], 0}, fn step, {:ok, compiled, total} ->
      case step do
        %{"op" => "send", "opcode" => opcode, "data" => encoded}
        when map_size(step) == 3 and opcode in ["binary", "text"] and is_binary(encoded) ->
          case Base.decode64(encoded) do
            {:ok, bytes} when byte_size(bytes) <= @inline_bytes ->
              if opcode == "binary" or String.valid?(bytes),
                do:
                  {:cont,
                   {:ok,
                    compiled ++
                      [
                        %{
                          op: :send,
                          frame: {if(opcode == "binary", do: :binary, else: :text), bytes}
                        }
                      ], total + byte_size(bytes)}},
                else: {:halt, invalid()}

            _ ->
              {:halt, invalid()}
          end

        %{"op" => "send", "body_file" => label} ->
          with true <- Enum.all?(Map.keys(step), &(&1 in ~w(op body_file prefix))),
               {:ok, file} <- Map.fetch(files, label),
               true <- Target.FileReference.valid?(file),
               {:ok, prefix} <- Base.decode64(Map.get(step, "prefix", "")),
               true <- byte_size(prefix) <= 256 do
            {:cont,
             {:ok, compiled ++ [%{op: :send, file: file, label: label, prefix: prefix}],
              total + file["size_bytes"]}}
          else
            _ -> {:halt, invalid()}
          end

        %{"op" => "receive", "count" => count}
        when is_integer(count) and count in 1..64 ->
          receive_step(step, compiled, total, count, false)

        %{"op" => "receive", "until_close" => true, "max_frames" => count}
        when is_integer(count) and count in 1..64 ->
          receive_step(step, compiled, total, count, true)

        _ ->
          {:halt, invalid()}
      end
    end)
  end

  defp receive_step(step, compiled, total, count, until_close?) do
    keys =
      if until_close?,
        do: ~w(op until_close max_frames response_file),
        else: ~w(op count response_file)

    file = step["response_file"]

    if Enum.all?(Map.keys(step), &(&1 in keys)) and
         (not Map.has_key?(step, "response_file") or
            (is_map(file) and Target.FileWriter.valid_options?(file))) do
      {:cont,
       {:ok,
        compiled ++
          [%{op: :receive, count: count, until_close?: until_close?, response_file: file}], total}}
    else
      {:halt, invalid()}
    end
  end

  defp receive_schema(until_close?) do
    properties = %{
      "op" => %{"const" => "receive"},
      "response_file" => Target.FileWriter.options_schema()
    }

    properties =
      if until_close?,
        do:
          Map.merge(properties, %{
            "until_close" => %{"const" => true},
            "max_frames" => %{"type" => "integer", "minimum" => 1, "maximum" => 64}
          }),
        else:
          Map.put(properties, "count", %{"type" => "integer", "minimum" => 1, "maximum" => 64})

    object(properties, Map.keys(properties) -- ["response_file"])
  end

  defp query(values) when is_map(values) and map_size(values) <= 32 do
    Enum.reduce_while(values, {:ok, []}, fn {key, value}, {:ok, pairs} ->
      values = if is_list(value), do: value, else: [value]

      if text?(key, 120) and byte_size(key) > 0 and length(values) in 1..32 and
           Enum.all?(values, &text?(&1, 2_048)),
         do: {:cont, {:ok, pairs ++ Enum.map(values, &{key, &1})}},
         else: {:halt, invalid()}
    end)
  end

  defp query(_), do: invalid()

  defp evidence_reserve(steps) do
    Enum.reduce(steps, 6_000 + 128 * frame_limit(steps), fn step, size ->
      file =
        case step do
          %{response_file: %{"name" => name, "media_type" => media}} ->
            900 + 6 * (byte_size(name) + byte_size(media))

          _ ->
            0
        end

      size + 256 + file
    end)
  end

  defp frame_limit(steps),
    do: min(256, 64 + Enum.reduce(steps, 0, &(Map.get(&1, :count, 0) + &2)))

  defp protocol?(value),
    do:
      is_binary(value) and byte_size(value) in 1..120 and
        Regex.match?(~r/\A[!#$%&'*+\-.^_`|~0-9A-Za-z]+\z/, value)

  defp text?(value, maximum),
    do:
      is_binary(value) and byte_size(value) <= maximum and String.valid?(value) and
        not Regex.match?(~r/[\x00-\x1f\x7f]/, value)

  defp string, do: %{"type" => "string", "maxLength" => 2_048}

  defp object(properties, required \\ nil),
    do: %{
      "type" => "object",
      "properties" => properties,
      "required" => required || Map.keys(properties),
      "additionalProperties" => false
    }

  defp invalid, do: {:error, :failed, "Kubernetes WebSocket request is invalid"}
end
