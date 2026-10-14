defmodule Skopos.Targets.Adapters.SSH.Subsystem do
  @moduledoc false
  alias Skopos.Providers.Target
  @capability "request.ssh.effect"
  @inline_bytes 24_000
  @maximum_bytes 536_870_912

  def effect do
    %Target.Operation{
      capability: @capability,
      operation: "subsystem.session",
      description:
        "Exchange exact binary steps on one caller-selected SSH subsystem, then explicitly close; transport completion is not remote recovery proof",
      input_schema: %{
        "type" => "object",
        "properties" => %{
          "selectors" => %{"type" => "object", "maxProperties" => 0},
          "parameters" =>
            object(
              %{
                "subsystem" => %{"type" => "string", "minLength" => 1, "maxLength" => 255},
                "max_bytes" => %{
                  "type" => "integer",
                  "minimum" => 1,
                  "maximum" => @maximum_bytes,
                  "default" => @inline_bytes,
                  "description" =>
                    "Cumulative byte bound in each direction; larger output requires response_file"
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
                        "data" => %{
                          "type" => "string",
                          "description" => "Exact base64 bytes",
                          "maxLength" => 32_000
                        }
                      }),
                      object(%{
                        "op" => %{"const" => "send"},
                        "body_file" => %{"type" => "string", "minLength" => 1, "maxLength" => 120}
                      }),
                      object(
                        %{
                          "op" => %{"const" => "receive"},
                          "stream" => %{"type" => "integer", "enum" => [0, 1], "default" => 0},
                          "response_file" => Target.FileWriter.options_schema(),
                          "until" => %{
                            "oneOf" => [
                              object(%{
                                "bytes" => %{
                                  "type" => "integer",
                                  "minimum" => 1,
                                  "maximum" => @maximum_bytes
                                }
                              }),
                              object(%{
                                "delimiter" => %{
                                  "type" => "string",
                                  "minLength" => 4,
                                  "maxLength" => 1_368
                                }
                              }),
                              object(%{"eof" => %{"const" => true}})
                            ]
                          }
                        },
                        ~w(op until)
                      ),
                      object(%{"op" => %{"const" => "send_eof"}}),
                      object(%{"op" => %{"const" => "close"}})
                    ]
                  }
                }
              },
              ~w(subsystem steps)
            )
        },
        "required" => ~w(selectors parameters),
        "additionalProperties" => false
      }
    }
  end

  def compile(%{
        capability: @capability,
        selectors: selectors,
        parameters: %{"subsystem" => name, "steps" => steps} = parameters,
        files: files
      })
      when selectors == %{} and is_map(files) and is_binary(name) and
             byte_size(name) in 1..255 and is_list(steps) and length(steps) in 1..64 do
    with :ok <- Skopos.Transports.SSH.validate_subsystem_name(name),
         true <- Enum.all?(Map.keys(parameters), &(&1 in ~w(subsystem steps max_bytes))),
         max_bytes when is_integer(max_bytes) and max_bytes in 1..@maximum_bytes <-
           Map.get(parameters, "max_bytes", @inline_bytes),
         {:ok, compiled, _, true, _} <-
           Enum.reduce_while(
             steps,
             {:ok, [], false, false, 0},
             &compile_step(&1, &2, files, max_bytes)
           ),
         reserve when reserve < 60_000 <- evidence_reserve(steps) do
      {:ok,
       %{
         name: name,
         steps: Enum.reverse(compiled),
         inline_bytes: min(@inline_bytes, div(60_000 - reserve, 2)),
         max_bytes: max_bytes,
         file_output?: Enum.any?(steps, &Map.has_key?(&1, "response_file"))
       }}
    else
      _ -> invalid()
    end
  end

  def compile(_), do: invalid()

  defp compile_step(step, {:ok, steps, eof?, false, sent}, files, limit) do
    case admit(step, eof?, files) do
      {:ok, compiled, bytes} when sent + bytes <= limit ->
        {:cont,
         {:ok, [compiled | steps], eof? or step["op"] == "send_eof", step["op"] == "close",
          sent + bytes}}

      _ ->
        {:halt, invalid()}
    end
  end

  defp compile_step(_, _, _, _), do: {:halt, invalid()}

  defp admit(%{"op" => "send", "data" => encoded} = step, false, _) when map_size(step) == 2 do
    with {:ok, bytes} <- decode(encoded),
         true <- byte_size(bytes) in 1..@inline_bytes,
         do: {:ok, Map.put(step, :bytes, bytes), byte_size(bytes)},
         else: (_ -> invalid())
  end

  defp admit(%{"op" => "send", "body_file" => label} = step, false, files)
       when map_size(step) == 2 do
    with {:ok, file} <- Map.fetch(files, label),
         true <- Target.FileReference.valid?(file),
         do: {:ok, Map.put(step, :file, file), file["size_bytes"]},
         else: (_ -> invalid())
  end

  defp admit(%{"op" => "receive", "until" => until} = step, _, _) do
    with true <- Enum.all?(Map.keys(step), &(&1 in ~w(op until stream response_file))),
         true <- Map.get(step, "stream", 0) in [0, 1],
         true <-
           not Map.has_key?(step, "response_file") or
             (is_map(step["response_file"]) and
                Target.FileWriter.valid_options?(step["response_file"])),
         {:ok, matcher} <- matcher(until),
         true <-
           Map.has_key?(step, "response_file") or
             not match?({:bytes, count} when count > @inline_bytes, matcher),
         do:
           {:ok,
            step |> Map.put(:matcher, matcher) |> Map.put(:stream, Map.get(step, "stream", 0)), 0},
         else: (_ -> invalid())
  end

  defp admit(%{"op" => "send_eof"} = step, false, _) when map_size(step) == 1, do: {:ok, step, 0}
  defp admit(%{"op" => "close"} = step, _, _) when map_size(step) == 1, do: {:ok, step, 0}
  defp admit(_, _, _), do: invalid()

  defp matcher(%{"bytes" => count} = value)
       when map_size(value) == 1 and is_integer(count) and count in 1..@maximum_bytes,
       do: {:ok, {:bytes, count}}

  defp matcher(%{"eof" => true} = value) when map_size(value) == 1, do: {:ok, :eof}

  defp matcher(%{"delimiter" => encoded} = value) when map_size(value) == 1 do
    with {:ok, bytes} <- decode(encoded),
         true <- byte_size(bytes) in 1..1024,
         do: {:ok, {:delimiter, bytes}},
         else: (_ -> invalid())
  end

  defp matcher(_), do: invalid()
  defp decode(value) when is_binary(value), do: Base.decode64(value)
  defp decode(_), do: :error
  defp invalid, do: {:error, :failed, "SSH subsystem session request is invalid"}

  defp evidence_reserve(steps) do
    Enum.reduce(steps, 6_000, fn step, size ->
      case step["response_file"] do
        %{"name" => name, "media_type" => media} ->
          size + 768 + byte_size(name) + byte_size(media)

        _ ->
          size + 256
      end
    end)
  end

  defp object(properties, required \\ nil),
    do: %{
      "type" => "object",
      "properties" => properties,
      "required" => required || Map.keys(properties),
      "additionalProperties" => false
    }
end
