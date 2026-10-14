defmodule Skopos.MixProject do
  use Mix.Project

  def project do
    [
      app: :skopos,
      name: "Skopos",
      source_url: "https://github.com/skopos-org/skopos",
      docs: &docs/0,
      version: "0.1.1",
      elixir: "~> 1.18",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() in [:prod, :cli],
      default_release: if(Mix.env() == :cli, do: :skopos, else: :skopos_server),
      releases: releases(Mix.env()),
      aliases: aliases(),
      deps: deps(),
      usage_rules: usage_rules(),
      listeners: if(Mix.env() == :cli, do: [], else: [Phoenix.CodeReloader]),
      consolidate_protocols: Mix.env() != :dev
    ]
  end

  # Configuration for the OTP application.
  #
  # Type `mix help compile.app` for more information.
  def application do
    if Mix.env() == :cli do
      [mod: {SkoposCLI.Application, []}, extra_applications: [:logger]]
    else
      [mod: {Skopos.Application, []}, extra_applications: [:logger, :runtime_tools, :ssh]]
    end
  end

  def cli do
    [
      preferred_envs: [precommit: :test]
    ]
  end

  # Specifies which paths to compile per environment.
  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(:cli), do: ["lib/skopos_cli"]
  defp elixirc_paths(_), do: ["lib"]

  defp usage_rules do
    [
      skills: [
        location: ".agents/skills",
        build: [
          "ash-framework": [
            description:
              "Load before changing Ash.Domain, Ash.Resource, Ash actions, policies, changes, validations, AshPostgres persistence, AshAuthentication, or AshPhoenix integration, and before running Ash generators.",
            usage_rules: [:ash, ~r/^ash_/]
          ]
        ]
      ]
    ]
  end

  # Specifies your project dependencies.
  #
  # Type `mix help deps` for examples and options.
  defp deps do
    client = [{:req, "~> 0.7"}, {:jason, "~> 1.2"}, {:burrito, "== 1.5.0"}, {:uniq, "~> 0.6"}]

    if Mix.env() == :cli, do: client, else: client ++ server_deps()
  end

  defp server_deps do
    [
      {:ex_doc, "~> 0.40.4", only: :dev, runtime: false},
      {:ash_state_machine, "~> 0.2.13"},
      {:req_llm, "~> 1.24"},
      {:finch, "~> 0.23.0"},
      {:mint, "~> 1.10.2"},
      {:mint_web_socket, "~> 1.0.6"},
      {:rustler, "== 0.38.0", runtime: false},
      {:saxy, "~> 1.6"},
      {:tzdata, "~> 1.1"},
      {:crontab, "~> 1.2"},
      {:k8s, "~> 2.8"},
      {:yaml_elixir, "~> 2.12"},
      {:jsv, "~> 0.23"},
      {:oban, "~> 2.0"},
      {:cloak, "~> 1.0"},
      {:ash_cloak, "~> 0.4"},
      {:argon2_elixir, "~> 4.0"},
      {:simple_sat, "~> 0.1"},
      {:attesto_client, "~> 2.5"},
      {:attesto, "~> 2.1"},
      {:open_api_spex, "~> 3.22"},
      {:ash_authentication, "~> 4.0"},
      {:usage_rules, "~> 1.0", only: [:dev]},
      {:sourceror, "~> 1.8", only: [:dev, :test]},
      {:ash_phoenix, "~> 2.0"},
      {:ash_postgres, "~> 2.0"},
      {:ash, "~> 3.33.11"},
      {:igniter, "~> 0.6", only: [:dev, :test]},
      {:phoenix, "~> 1.8.14"},
      {:phoenix_ecto, "~> 4.5"},
      {:ecto_sql, "~> 3.13"},
      {:postgrex, ">= 0.0.0"},
      {:telemetry_metrics, "~> 1.0"},
      {:telemetry_poller, "~> 1.0"},
      {:gettext, "~> 1.0"},
      {:server_sent_events, "~> 1.1.0"},
      {:nimble_csv, "~> 1.3"},
      {:dns_cluster, "~> 0.2.0"},
      {:bandit, "~> 1.5"}
    ]
  end

  defp docs do
    {options, _binding} = Code.eval_file("docs/ex_doc.exs")
    options
  end

  defp releases(:cli) do
    [
      skopos: [
        steps: [:assemble, &remove_server_assets/1, &Burrito.wrap/1],
        burrito: [
          targets: [
            linux_x86_64: [os: :linux, cpu: :x86_64],
            linux_aarch64: [os: :linux, cpu: :aarch64],
            macos_x86_64: [os: :darwin, cpu: :x86_64],
            macos_aarch64: [os: :darwin, cpu: :aarch64],
            windows_x86_64: [os: :windows, cpu: :x86_64]
          ]
        ]
      ]
    ]
  end

  defp releases(_env), do: [skopos_server: []]

  defp remove_server_assets(release) do
    version = release.applications |> Map.fetch!(:skopos) |> Keyword.fetch!(:vsn)
    app = Path.join([release.path, "lib", "skopos-#{version}"])

    # Mix copies the project's priv/include even when only CLI sources compile.
    # Remove those server assets from the assembled copy, never from the project.
    for directory <- ["priv", "include"], do: File.rm_rf!(Path.join(app, directory))
    release
  end

  # Aliases are shortcuts or tasks specific to the current project.
  # For example, to install project dependencies and perform other setup tasks, run:
  #
  #     $ mix setup
  #
  # See the documentation for `Mix` for more info on aliases.
  defp aliases do
    [
      setup: [
        "deps.get",
        "ash.setup",
        "run priv/repo/seeds.exs",
        "assets.setup",
        "assets.build"
      ],
      "ecto.setup": ["ecto.create", "ecto.migrate", "run priv/repo/seeds.exs"],
      "ecto.reset": ["ecto.drop", "ecto.setup"],
      "assets.setup": ["cmd --cd assets corepack pnpm install --frozen-lockfile"],
      "assets.build": ["cmd --cd assets corepack pnpm run build"],
      test: ["ash.setup --quiet", "run priv/repo/seeds.exs", "test"],
      precommit: [
        "compile --warnings-as-errors",
        "deps.unlock --unused",
        "format --check-formatted",
        "openapi.spec.json --spec SkoposWeb.ApiSpec --pretty=true --vendor-extensions=false --start-app=false --check=true --filename openapi.json",
        "cmd --cd assets corepack pnpm run check:api",
        "cmd --cd assets corepack pnpm run check",
        "assets.build",
        "test"
      ]
    ]
  end
end
