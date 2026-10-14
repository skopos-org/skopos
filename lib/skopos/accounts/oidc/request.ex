defmodule Skopos.Accounts.OIDC.Request do
  use Ash.Resource,
    otp_app: :skopos,
    domain: Skopos.Accounts,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "oidc_requests"
    repo Skopos.Repo
  end

  actions do
    defaults [:read]

    create :create_link do
      public? false
      accept []

      argument :user_id, :uuid, allow_nil?: false
      argument :start_token_digest, :binary, allow_nil?: false, sensitive?: true
      argument :expires_at, :utc_datetime_usec, allow_nil?: false

      change set_attribute(:purpose, :link)
      change set_attribute(:user_id, arg(:user_id))
      change set_attribute(:start_token_digest, arg(:start_token_digest))
      change set_attribute(:expires_at, arg(:expires_at))
    end

    create :create_cli_login do
      public? false
      accept []

      argument :start_token_digest, :binary, allow_nil?: false, sensitive?: true
      argument :verifier_digest, :binary, allow_nil?: false, sensitive?: true
      argument :redirect_uri, :string, allow_nil?: false
      argument :expires_at, :utc_datetime_usec, allow_nil?: false

      change set_attribute(:purpose, :cli_login)
      change set_attribute(:start_token_digest, arg(:start_token_digest))
      change set_attribute(:verifier_digest, arg(:verifier_digest))
      change set_attribute(:redirect_uri, arg(:redirect_uri))
      change set_attribute(:expires_at, arg(:expires_at))
    end

    update :start do
      public? false
      require_atomic? false
      accept []

      argument :expected_revision, :integer,
        allow_nil?: false,
        constraints: [min: 1]

      argument :start_token, :string, allow_nil?: false, sensitive?: true
      argument :browser_binding_digest, :binary, sensitive?: true

      validate Skopos.Validations.CurrentRevision
      validate {Skopos.Accounts.OIDC.Request.State, phase: :start}
      change set_attribute(:browser_binding_digest, arg(:browser_binding_digest))
      change atomic_update(:started_at, expr(now()))
      change optimistic_lock(:revision)
    end

    update :complete do
      public? false
      require_atomic? false
      accept []

      argument :expected_revision, :integer,
        allow_nil?: false,
        constraints: [min: 1]

      argument :user_id, :uuid, allow_nil?: false
      argument :code_digest, :binary, sensitive?: true

      validate Skopos.Validations.CurrentRevision
      validate {Skopos.Accounts.OIDC.Request.State, phase: :complete}
      change set_attribute(:user_id, arg(:user_id))
      change set_attribute(:code_digest, arg(:code_digest))
      change atomic_update(:completed_at, expr(now()))
      change optimistic_lock(:revision)
    end

    update :consume do
      public? false
      require_atomic? false
      accept []

      argument :expected_revision, :integer,
        allow_nil?: false,
        constraints: [min: 1]

      argument :code, :string, allow_nil?: false, sensitive?: true
      argument :verifier, :string, allow_nil?: false, sensitive?: true

      validate Skopos.Validations.CurrentRevision
      validate {Skopos.Accounts.OIDC.Request.State, phase: :consume}
      change atomic_update(:consumed_at, expr(now()))
      change optimistic_lock(:revision)
    end

    action :request_link, :map do
      run Skopos.Accounts.OIDC.Request.Actions.Flow
    end

    action :request_cli_login, :map do
      argument :redirect_uri, :string, allow_nil?: false
      argument :code_challenge, :string, allow_nil?: false, sensitive?: true
      run Skopos.Accounts.OIDC.Request.Actions.Flow
    end

    action :approve_cli_login, :map do
      argument :id, :uuid, allow_nil?: false
      argument :start_token, :string, allow_nil?: false, sensitive?: true
      run Skopos.Accounts.OIDC.Request.Actions.Flow
    end

    action :deny_cli_login, :struct do
      constraints instance_of: __MODULE__
      argument :id, :uuid, allow_nil?: false
      argument :start_token, :string, allow_nil?: false, sensitive?: true
      run Skopos.Accounts.OIDC.Request.Actions.Flow
    end

    action :exchange_cli_login, :map do
      argument :id, :uuid, allow_nil?: false
      argument :code, :string, allow_nil?: false, sensitive?: true
      argument :verifier, :string, allow_nil?: false, sensitive?: true
      run Skopos.Accounts.OIDC.Request.Actions.Flow
    end
  end

  policies do
    policy action([:request_link, :approve_cli_login, :deny_cli_login]) do
      authorize_if actor_present()
    end

    policy action([:request_cli_login, :exchange_cli_login]) do
      authorize_if always()
    end

    policy action([
             :read,
             :create_link,
             :create_cli_login,
             :start,
             :complete,
             :consume
           ]) do
      forbid_if always()
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :purpose, :atom do
      allow_nil? false
      public? true
      constraints one_of: [:link, :cli_login]
    end

    attribute :start_token_digest, :binary do
      allow_nil? false
      sensitive? true
    end

    attribute :browser_binding_digest, :binary do
      sensitive? true
    end

    attribute :verifier_digest, :binary do
      sensitive? true
    end

    attribute :code_digest, :binary do
      sensitive? true
    end

    attribute :redirect_uri, :string

    attribute :expires_at, :utc_datetime_usec do
      allow_nil? false
      public? true
    end

    attribute :started_at, :utc_datetime_usec
    attribute :completed_at, :utc_datetime_usec
    attribute :consumed_at, :utc_datetime_usec

    attribute :revision, :integer do
      allow_nil? false
      public? true
      default 1
      constraints min: 1
    end

    timestamps()
  end

  relationships do
    belongs_to :user, Skopos.Accounts.User
  end

  def random_secret(bytes \\ 32) do
    bytes
    |> :crypto.strong_rand_bytes()
    |> Base.url_encode64(padding: false)
  end

  def digest(value) when is_binary(value), do: :crypto.hash(:sha256, value)

  def digest_matches?(digest, value) when is_binary(digest) and is_binary(value) do
    candidate = digest(value)
    byte_size(digest) == byte_size(candidate) and Plug.Crypto.secure_compare(digest, candidate)
  end

  def digest_matches?(_digest, _value), do: false
end
