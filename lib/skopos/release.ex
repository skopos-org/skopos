defmodule Skopos.Release do
  @moduledoc false

  @app :skopos

  alias Skopos.{Cases, Reports}
  alias Skopos.Cases.AuthoritySetting
  alias Skopos.Reports.Setting

  def migrate do
    Application.ensure_all_started(:ssl)
    Application.load(@app)

    for repo <- Application.fetch_env!(@app, :ecto_repos) do
      {:ok, _, _} =
        Ecto.Migrator.with_repo(repo, fn repo ->
          Ecto.Migrator.run(repo, :up, all: true)
          seed()
        end)
    end
  end

  def seed do
    if is_nil(
         AuthoritySetting
         |> Ash.Query.for_read(:current)
         |> Ash.read_one!(authorize?: false)
       ) do
      Cases.bootstrap_authority_setting!(authorize?: false)
    end

    if is_nil(Setting |> Ash.Query.for_read(:current) |> Ash.read_one!(authorize?: false)) do
      Reports.bootstrap_setting!(authorize?: false)
    end

    :ok
  end
end
