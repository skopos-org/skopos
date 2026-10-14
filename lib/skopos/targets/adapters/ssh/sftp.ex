defmodule Skopos.Targets.Adapters.SSH.SFTP do
  @moduledoc false
  alias Skopos.Providers.Target
  @read "request.ssh.observe"
  @write "request.ssh.effect"
  @read_methods %{
    "sftp.read_file_info" => :read_file_info,
    "sftp.read_link_info" => :read_link_info,
    "sftp.read_link" => :read_link,
    "sftp.real_path" => :real_path,
    "sftp.list_dir" => :list_dir
  }
  @write_methods %{
    "sftp.make_dir" => :make_dir,
    "sftp.del_dir" => :del_dir,
    "sftp.delete" => :delete,
    "sftp.rename" => :rename,
    "sftp.make_symlink" => :make_symlink,
    "sftp.write_file_info" => :write_file_info
  }

  def capabilities do
    %Target.Capabilities{
      observations:
        [
          %Target.Operation{
            capability: @read,
            operation: "sftp.read_file",
            description:
              "Download exact remote file bytes over the registered SSH connection into an authenticated file; remote paths and permissions belong to the server",
            input_schema: schema(:read),
            output_schema: %{
              "type" => "object",
              "properties" => %{
                "file" => Target.FileReference.schema(),
                "completion_reason" => %{"const" => "eof"}
              },
              "required" => ~w(file completion_reason),
              "additionalProperties" => false
            },
            verification_schema: %{
              "type" => "object",
              "properties" =>
                Map.take(Target.FileReference.schema()["properties"], ~w(size_bytes sha256)),
              "additionalProperties" => false
            }
          }
        ] ++ metadata_capabilities(),
      effects:
        [
          %Target.Operation{
            capability: @write,
            operation: "sftp.write_file",
            description:
              "Write admitted immutable file bytes to the exact remote path after authority review; existing content is overwritten, interrupted writes remain uncertain and are never automatically replayed",
            input_schema: schema(:write)
          }
        ] ++ metadata_effects()
    }
  end

  defp metadata_capabilities do
    @read_methods
    |> Enum.sort()
    |> Enum.map(fn {name, method} ->
      %Target.Operation{
        capability: @read,
        operation: name,
        description:
          "SFTP #{method} at the exact remote path; unavailable attributes remain null",
        input_schema: request_schema(metadata_parameters(method)),
        output_schema: %{"type" => "object"},
        verification_schema: %{
          "type" => "object",
          "maxProperties" => 0,
          "additionalProperties" => false
        }
      }
    end)
  end

  defp metadata_effects do
    @write_methods
    |> Enum.sort()
    |> Enum.map(fn {name, method} ->
      %Target.Operation{
        capability: @write,
        operation: name,
        description:
          "Send native SFTP #{method} at the exact path after authority review; acknowledgement does not verify the resulting attributes",
        input_schema: request_schema(metadata_parameters(method))
      }
    end)
  end

  def operation(%{
        capability: capability,
        operation: name,
        selectors: selectors,
        parameters: %{"path" => path} = parameters
      })
      when selectors == %{} and capability in [@read, @write] and
             name not in ["sftp.read_file", "sftp.write_file"] do
    methods = if capability == @read, do: @read_methods, else: @write_methods

    with {:ok, method} <- Map.fetch(methods, name),
         true <- path?(path),
         true <-
           Enum.sort(Map.keys(parameters)) == Enum.sort(Map.keys(metadata_parameters(method))),
         {:ok, args} <- metadata_args(method, parameters),
         do:
           {:ok,
            %{
              kind:
                cond do
                  method == :list_dir -> :directory
                  capability == @read -> :metadata_read
                  true -> :metadata_write
                end,
              method: method,
              path: path,
              args: args,
              output: Map.get(parameters, "response_file")
            }},
         else: (_ -> invalid())
  end

  def operation(%{
        capability: @read,
        operation: "sftp.read_file",
        selectors: selectors,
        parameters: %{"path" => path, "response_file" => options} = parameters
      })
      when selectors == %{} and map_size(parameters) == 2 do
    if path?(path) and is_map(options) and Target.FileWriter.valid_options?(options),
      do: {:ok, %{kind: :read, path: path, output: options}},
      else: invalid()
  end

  def operation(%{
        capability: @write,
        operation: "sftp.write_file",
        selectors: selectors,
        parameters: %{"path" => path, "body_file" => label} = parameters,
        files: files
      })
      when selectors == %{} and map_size(parameters) == 2 do
    with true <- path?(path) and is_binary(label),
         {:ok, file} <- Map.fetch(files, label),
         true <- Target.FileReference.valid?(file),
         do: {:ok, %{kind: :write, path: path, label: label, file: file}},
         else: (_ -> invalid())
  end

  def operation(_request), do: invalid()

  # Compare only the caller's literal byte-integrity condition. This says
  # nothing about service recovery or the meaning of the downloaded content.
  def expected_status(_file, expected) when expected == %{}, do: :unknown

  def expected_status(file, expected) do
    if Enum.all?(expected, fn {key, value} ->
         key in ~w(size_bytes sha256) and Map.fetch(file, key) == {:ok, value}
       end), do: :verified, else: :not_verified
  end

  defp invalid, do: {:error, :failed, "SFTP request is invalid"}

  defp path?(path),
    do:
      is_binary(path) and String.valid?(path) and byte_size(path) in 1..4096 and
        not String.contains?(path, <<0>>)

  defp schema(kind) do
    properties = %{"path" => path_schema()}

    properties =
      if kind == :read,
        do: Map.put(properties, "response_file", Target.FileWriter.options_schema()),
        else:
          Map.merge(properties, %{
            "body_file" => %{
              "type" => "string",
              "minLength" => 1,
              "maxLength" => 120
            },
            "files" => Target.FileReference.set_schema()
          })

    request_schema(properties)
  end

  defp path_schema, do: %{"type" => "string", "minLength" => 1, "maxLength" => 4096}

  defp metadata_parameters(method) do
    extra =
      case method do
        :list_dir ->
          %{
            "max_entries" => %{"type" => "integer", "minimum" => 1, "maximum" => 10_000},
            "max_bytes" => %{"type" => "integer", "minimum" => 2, "maximum" => 1_048_576},
            "response_file" => Target.FileWriter.options_schema()
          }

        :rename ->
          %{"destination" => path_schema()}

        :make_symlink ->
          %{"target" => path_schema()}

        :write_file_info ->
          %{"attributes" => attributes_schema()}

        _ ->
          %{}
      end

    Map.put(extra, "path", path_schema())
  end

  defp metadata_args(method, parameters) when method in [:rename, :make_symlink] do
    key = if method == :rename, do: "destination", else: "target"
    value = parameters[key]
    if path?(value), do: {:ok, [parameters["path"], value]}, else: invalid()
  end

  defp metadata_args(:write_file_info, parameters) do
    values = parameters["attributes"]

    if is_map(values) and map_size(values) > 0 and
         Enum.all?(values, fn {key, value} -> attribute?(key, value) end) and
         paired?(values, "uid", "gid") and paired?(values, "atime", "mtime"),
       do: {:ok, [parameters["path"], values]},
       else: invalid()
  end

  defp metadata_args(:list_dir, %{
         "path" => path,
         "max_entries" => entries,
         "max_bytes" => bytes,
         "response_file" => output
       })
       when is_integer(entries) and entries in 1..10_000 and is_integer(bytes) and
              bytes in 2..1_048_576 do
    if is_map(output) and Target.FileWriter.valid_options?(output),
      do: {:ok, [path, entries, bytes]},
      else: invalid()
  end

  defp metadata_args(:list_dir, _parameters), do: invalid()

  defp metadata_args(_method, parameters), do: {:ok, [parameters["path"]]}

  defp paired?(map, left, right), do: Map.has_key?(map, left) == Map.has_key?(map, right)

  defp attribute?("size", value),
    do: is_integer(value) and value >= 0 and value < 18_446_744_073_709_551_616

  defp attribute?(key, value) when key in ~w(mode uid gid),
    do: is_integer(value) and value >= 0 and value < 4_294_967_296

  defp attribute?("type", value), do: value in ~w(regular directory symlink device other)

  defp attribute?(key, [[year, month, day], [hour, minute, second]])
       when key in ~w(atime mtime ctime),
       do:
         is_integer(year) and year in 1970..9999 and is_integer(month) and is_integer(day) and
           :calendar.valid_date({year, month, day}) and is_integer(hour) and hour in 0..23 and
           is_integer(minute) and minute in 0..59 and is_integer(second) and second in 0..59

  defp attribute?(_key, _value), do: false

  defp attributes_schema do
    integer = %{"type" => "integer", "minimum" => 0, "maximum" => 4_294_967_295}

    time = %{
      "type" => "array",
      "minItems" => 2,
      "maxItems" => 2,
      "items" => %{
        "type" => "array",
        "minItems" => 3,
        "maxItems" => 3,
        "items" => %{"type" => "integer"}
      }
    }

    %{
      "type" => "object",
      "minProperties" => 1,
      "additionalProperties" => false,
      "properties" => %{
        "mode" => integer,
        "uid" => integer,
        "gid" => integer,
        "size" => %{"type" => "integer", "minimum" => 0, "maximum" => 18_446_744_073_709_551_615},
        "type" => %{"type" => "string", "enum" => ~w(regular directory symlink device other)},
        "atime" => time,
        "mtime" => time,
        "ctime" => time
      },
      "dependentRequired" => %{
        "uid" => ["gid"],
        "gid" => ["uid"],
        "atime" => ["mtime"],
        "mtime" => ["atime"]
      }
    }
  end

  defp request_schema(properties) do
    %{
      "type" => "object",
      "properties" => %{
        "selectors" => %{"type" => "object", "maxProperties" => 0},
        "parameters" => %{
          "type" => "object",
          "properties" => properties,
          "required" => Map.keys(properties),
          "additionalProperties" => false
        }
      },
      "required" => ~w(selectors parameters),
      "additionalProperties" => false
    }
  end
end
