import Config

# config/runtime.exs is executed for all environments, including
# during releases. It is executed after compilation and before the
# system starts, so it is typically used to load production configuration
# and secrets from environment variables or elsewhere. Do not define
# any compile-time configuration in here, as it won't be applied.
# The block below contains prod specific runtime configuration.

# ## Using releases
#
# If you use `mix release`, you need to explicitly enable the server
# by passing the PHX_SERVER=true when you start it:
#
#     PHX_SERVER=true bin/skopos_server start
#
# Alternatively, you can use `mix phx.gen.release` to generate a `bin/server`
# script that automatically sets the env var above.
if config_env() != :cli do
  if System.get_env("PHX_SERVER") do
    config :skopos, SkoposWeb.Endpoint, server: true
  end

  config :skopos, SkoposWeb.Endpoint,
    http: [port: String.to_integer(System.get_env("PORT", "4000"))]

  case_collect_seconds =
    case Integer.parse(System.get_env("SKOPOS_CASE_COLLECT_SECONDS", "5")) do
      {seconds, ""} when seconds in 0..30 -> seconds
      _other -> raise "SKOPOS_CASE_COLLECT_SECONDS must be an integer from 0 to 30"
    end

  config :skopos, :case_collect_seconds, case_collect_seconds

  public_url =
    System.get_env("SKOPOS_PUBLIC_URL", "http://localhost:4000")
    |> String.trim_trailing("/")

  public_uri = URI.parse(public_url)

  unless public_uri.scheme in ["http", "https"] and is_binary(public_uri.host) and
           public_uri.path in [nil, ""] and is_nil(public_uri.userinfo) and
           is_nil(public_uri.query) and is_nil(public_uri.fragment) do
    raise "SKOPOS_PUBLIC_URL must be an HTTP(S) origin without credentials, path, query, or fragment"
  end

  config :skopos, :public_url, public_url

  config :skopos, SkoposWeb.Endpoint,
    url: [host: public_uri.host, port: public_uri.port, scheme: public_uri.scheme]

  if config_env() == :prod do
    encoded_credentials_key =
      System.get_env("SKOPOS_CREDENTIALS_KEY") ||
        raise("Missing environment variable `SKOPOS_CREDENTIALS_KEY`!")

    credentials_key =
      case Base.decode64(encoded_credentials_key) do
        {:ok, key} when byte_size(key) == 32 -> key
        _other -> raise "SKOPOS_CREDENTIALS_KEY must be a Base64-encoded 32-byte key"
      end

    config :skopos, Skopos.Vault,
      ciphers: [
        default: {Cloak.Ciphers.AES.GCM, tag: "AES.GCM.V1", key: credentials_key, iv_length: 12}
      ]

    database_options =
      case System.get_env("DATABASE_URL") do
        nil ->
          [
            hostname: System.fetch_env!("DATABASE_HOST"),
            port: String.to_integer(System.get_env("DATABASE_PORT", "5432")),
            database: System.fetch_env!("DATABASE_NAME"),
            username: System.fetch_env!("DATABASE_USER"),
            password: System.fetch_env!("DATABASE_PASSWORD")
          ]

        database_url ->
          [url: database_url]
      end

    maybe_ipv6 = if System.get_env("ECTO_IPV6") in ~w(true 1), do: [:inet6], else: []

    config :skopos,
           Skopos.Repo,
           database_options ++
             [
               pool_size: String.to_integer(System.get_env("POOL_SIZE") || "10"),
               socket_options: maybe_ipv6
             ]

    # The secret key base is used to sign/encrypt cookies and other secrets.
    # A default value is used in config/dev.exs and config/test.exs but you
    # want to use a different value for prod and you most likely don't want
    # to check this value into version control, so we use an environment
    # variable instead.
    secret_key_base =
      System.get_env("SECRET_KEY_BASE") ||
        raise """
        environment variable SECRET_KEY_BASE is missing.
        You can generate one by calling: mix phx.gen.secret
        """

    config :skopos, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")

    config :skopos, SkoposWeb.Endpoint,
      http: [
        # Enable IPv6 and bind on all interfaces.
        # Set it to  {0, 0, 0, 0, 0, 0, 0, 1} for local network only access.
        # See the documentation on https://bandit.hexdocs.pm/Bandit.html#t:options/0
        # for details about using IPv6 vs IPv4 and loopback vs public addresses.
        ip: {0, 0, 0, 0, 0, 0, 0, 0}
      ],
      secret_key_base: secret_key_base

    # ## SSL Support
    #
    # To get SSL working, you will need to add the `https` key
    # to your endpoint configuration:
    #
    #     config :skopos, SkoposWeb.Endpoint,
    #       https: [
    #         ...,
    #         port: 443,
    #         cipher_suite: :strong,
    #         keyfile: System.get_env("SOME_APP_SSL_KEY_PATH"),
    #         certfile: System.get_env("SOME_APP_SSL_CERT_PATH")
    #       ]
    #
    # The `cipher_suite` is set to `:strong` to support only the
    # latest and more secure SSL ciphers. This means old browsers
    # and clients may not be supported. You can set it to
    # `:compatible` for wider support.
    #
    # `:keyfile` and `:certfile` expect an absolute path to the key
    # and cert in disk or a relative path inside priv, for example
    # "priv/ssl/server.key". For all supported SSL configuration
    # options, see https://plug.hexdocs.pm/Plug.SSL.html#configure/1
    #
    # We also recommend setting `force_ssl` in your config/prod.exs,
    # ensuring no data is ever sent via http, always redirecting to https:
    #
    #     config :skopos, SkoposWeb.Endpoint,
    #       force_ssl: [hsts: true]
    #
    # Check `Plug.SSL` for all available options in `force_ssl`.
  end

  if config_env() == :prod do
    config :skopos,
      token_signing_secret:
        System.get_env("SKOPOS_TOKEN_SIGNING_SECRET") ||
          raise("Missing environment variable `SKOPOS_TOKEN_SIGNING_SECRET`!")
  end
end
