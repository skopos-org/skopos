# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

if config_env() != :cli do
  config :elixir, :time_zone_database, Tzdata.TimeZoneDatabase

  config :skopos, :public_url, "http://localhost:4000"

  ai_concurrency = 10

  config :skopos, Oban,
    engine: Oban.Engines.Basic,
    notifier: Oban.Notifiers.Postgres,
    queues: [resolver: ai_concurrency, operations: 10, notifications: 5, audits: 5],
    lifeline: [rescue_after: {12, :minutes}],
    pruner: [max_age: {1, :day}],
    repo: Skopos.Repo

  config :req_llm,
    stream_pool_protocols: [:http1],
    stream_pool_size: ai_concurrency,
    stream_pool_count: 1,
    warn_unverified_models: false

  # These enable behaviors that will become the default in the next major
  # version of Ash. Setting them now opts your application into the new
  # behavior and ensures a seamless upgrade. See the backwards compatibility
  # guide for an explanation of each setting:
  # https://hexdocs.pm/ash/backwards-compatibility-config.html
  config :ash,
    allow_forbidden_field_for_relationships_by_default: true,
    include_embedded_source_by_default?: false,
    show_keysets_for_all_actions?: false,
    default_page_type: :keyset,
    policies: [no_filter_static_forbidden_reads?: false],
    keep_read_action_loads_when_loading?: false,
    default_actions_require_atomic?: true,
    read_action_after_action_hooks_in_order?: true,
    bulk_actions_default_to_errors?: true,
    transaction_rollback_on_error?: true,
    redact_sensitive_values_in_errors?: true,
    default_string_length_count: :codepoints,
    many_to_many_destroy_destination_on_match?: true,
    known_types: [AshPostgres.Timestamptz, AshPostgres.TimestamptzUsec]

  config :spark,
    formatter: [
      remove_parens?: true,
      "Ash.Resource": [
        section_order: [
          :authentication,
          :token,
          :user_identity,
          :postgres,
          :resource,
          :code_interface,
          :actions,
          :policies,
          :pub_sub,
          :preparations,
          :changes,
          :validations,
          :multitenancy,
          :attributes,
          :relationships,
          :calculations,
          :aggregates,
          :identities
        ]
      ],
      "Ash.Domain": [section_order: [:resources, :policies, :authorization, :domain, :execution]]
    ]

  config :skopos,
    ecto_repos: [Skopos.Repo],
    generators: [timestamp_type: :utc_datetime, binary_id: true],
    ash_domains: [
      Skopos.Reports,
      Skopos.Audits,
      Skopos.Signals,
      Skopos.Notifications,
      Skopos.Cases,
      Skopos.Targets,
      Skopos.Providers,
      Skopos.Accounts
    ],
    provider_adapters: [
      Skopos.AI.ReqLLM,
      Skopos.Inventories.NetBox.API,
      Skopos.Notifications.HTTP.Webhook,
      Skopos.Signals.Alertmanager.Webhook,
      Skopos.Signals.Generic.Webhook,
      Skopos.Signals.Zabbix.Webhook,
      Skopos.Targets.Adapters.SSH,
      Skopos.Targets.Adapters.HTTP,
      Skopos.Targets.Adapters.NETCONF,
      Skopos.Targets.Adapters.RESTCONF,
      Skopos.Targets.Adapters.IPMI,
      Skopos.Targets.Adapters.Redfish,
      Skopos.Targets.Profiles.HPEILO.Redfish,
      Skopos.Targets.Profiles.HPEILO.IPMI,
      Skopos.Targets.Profiles.DellIDRAC.Redfish,
      Skopos.Targets.Profiles.DellIDRAC.IPMI,
      Skopos.Targets.Profiles.IOSXE.NETCONF,
      Skopos.Targets.Profiles.IOSXE.RESTCONF,
      Skopos.Targets.Profiles.IOSXE.SSH,
      Skopos.Targets.Adapters.Kubernetes,
      Skopos.Targets.Profiles.Linux.SSH
    ]

  config :phoenix, :filter_parameters, [
    "client_secret",
    "credentials",
    "idempotency_key",
    "password",
    "token"
  ]

  config :tzdata, :autoupdate, :disabled

  # Configure the endpoint
  config :skopos, SkoposWeb.Endpoint,
    url: [host: "localhost"],
    adapter: Bandit.PhoenixAdapter,
    http: [http_1_options: [max_request_line_length: 16_384]],
    render_errors: [
      formats: [json: SkoposWeb.ErrorJSON],
      layout: false
    ],
    pubsub_server: Skopos.PubSub,
    live_view: [signing_salt: "JPQtOoBk"]

  # Configure Elixir's Logger
  config :logger, :default_formatter,
    format: "$time $metadata[$level] $message\n",
    metadata: [:request_id]

  # Use Jason for JSON parsing in Phoenix
  config :phoenix, :json_library, Jason

  # Import environment specific config. This must remain at the bottom
  # of this file so it overrides the configuration defined above.
  import_config "#{config_env()}.exs"
end
