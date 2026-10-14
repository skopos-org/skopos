defmodule SkoposCLI.Config do
  @moduledoc false

  @filename "config.json"

  def load(path \\ path()) do
    with {:ok, encoded} <- File.read(path),
         {:ok, config} when is_map(config) <- Jason.decode(encoded) do
      {:ok, config}
    else
      {:error, :enoent} -> {:ok, %{}}
      {:error, %Jason.DecodeError{}} -> {:error, "CLI configuration is not valid JSON: #{path}"}
      {:error, reason} -> {:error, "Cannot read CLI configuration: #{:file.format_error(reason)}"}
      _other -> {:error, "CLI configuration must be a JSON object: #{path}"}
    end
  end

  def save(config, path \\ path()) when is_map(config) do
    directory = Path.dirname(path)
    directory_existed? = File.dir?(directory)
    temporary = path <> ".tmp-#{System.unique_integer([:positive])}"

    with :ok <- File.mkdir_p(directory),
         :ok <- maybe_protect_new_directory(directory, directory_existed?),
         :ok <- File.write(temporary, Jason.encode!(config, pretty: true) <> "\n"),
         :ok <- File.chmod(temporary, 0o600),
         :ok <- replace_file(temporary, path) do
      :ok
    else
      {:error, reason} ->
        File.rm(temporary)
        {:error, "Cannot write CLI configuration: #{:file.format_error(reason)}"}
    end
  end

  def clear_token(path \\ path()) do
    with {:ok, config} <- load(path) do
      save(Map.delete(config, "token"), path)
    end
  end

  def path do
    System.get_env("SKOPOS_CONFIG") ||
      Path.join(System.get_env("XDG_CONFIG_HOME") || default_config_home(), @filename)
  end

  defp default_config_home do
    Path.join(System.user_home!(), ".config/skopos")
  end

  defp maybe_protect_new_directory(_directory, true), do: :ok
  defp maybe_protect_new_directory(directory, false), do: File.chmod(directory, 0o700)

  defp replace_file(temporary, path) do
    case File.rename(temporary, path) do
      :ok ->
        :ok

      {:error, reason} when reason in [:eexist, :eacces] ->
        with true <- File.exists?(path),
             :ok <- File.rm(path),
             :ok <- File.rename(temporary, path) do
          :ok
        else
          false -> {:error, reason}
          error -> error
        end

      error ->
        error
    end
  end
end
