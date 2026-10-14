defmodule Skopos.Accounts.OIDC.Provider do
  use Ash.Resource,
    otp_app: :skopos,
    domain: Skopos.Accounts,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshCloak]

  postgres do
    table "oidc_providers"
    repo Skopos.Repo
  end

  field_policies do
    private_fields :include

    field_policy :client_secret do
      forbid_if always()
    end

    field_policy :* do
      authorize_if always()
    end
  end

  cloak do
    vault(Skopos.Vault)
    attributes([:client_secret])
  end

  actions do
    defaults [:read]

    read :current do
      get? true
      filter expr(singleton == "oidc")
    end

    create :create_configuration do
      public? false
      accept [:issuer, :client_id, :client_secret, :id_token_alg, :enabled]
      change set_attribute(:singleton, "oidc")
    end

    update :update_configuration do
      public? false
      accept [:issuer, :client_id, :client_secret, :id_token_alg, :enabled]

      argument :expected_revision, :integer,
        allow_nil?: false,
        constraints: [min: 1]

      validate Skopos.Validations.CurrentRevision
      change optimistic_lock(:revision)
    end

    action :configure, :struct do
      constraints instance_of: __MODULE__

      argument :issuer, :string, allow_nil?: false
      argument :client_id, :string, allow_nil?: false
      argument :client_secret, :string, allow_nil?: false, sensitive?: true
      argument :id_token_alg, :string, allow_nil?: false, default: "RS256"
      argument :enabled, :boolean, allow_nil?: false, default: true

      run Skopos.Accounts.OIDC.Provider.Configure
    end

    action :available, :boolean do
      run Skopos.Accounts.OIDC.Provider.Available
    end

    action :begin_authorization, :map do
      argument :request_id, :uuid
      argument :start_token, :string, sensitive?: true
      argument :provider_revision, :integer, constraints: [min: 1]
      argument :callback_uri, :string, allow_nil?: false
      run Skopos.Accounts.OIDC.Provider.Actions.Authorization
    end

    action :complete_authorization, :map do
      argument :params, :map, allow_nil?: false, sensitive?: true
      argument :browser_binding, :string, allow_nil?: false, sensitive?: true
      argument :provider_revision, :integer, allow_nil?: false, constraints: [min: 1]
      argument :request_id, :uuid
      run Skopos.Accounts.OIDC.Provider.Actions.Authorization
    end
  end

  policies do
    policy action(:configure) do
      authorize_if actor_attribute_equals(:role, :admin)
    end

    policy action(:available) do
      authorize_if always()
    end

    policy action([:begin_authorization, :complete_authorization]) do
      authorize_if always()
    end

    policy action_type(:read) do
      authorize_if actor_attribute_equals(:role, :admin)
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :issuer, :string do
      allow_nil? false
      public? true
    end

    attribute :client_id, :string do
      allow_nil? false
      public? true
    end

    attribute :client_secret, :string do
      allow_nil? false
      sensitive? true
    end

    attribute :id_token_alg, :string do
      allow_nil? false
      public? true
      default "RS256"
    end

    attribute :enabled, :boolean do
      allow_nil? false
      public? true
      default true
    end

    attribute :revision, :integer do
      allow_nil? false
      public? true
      default 1
      constraints min: 1
    end

    attribute :singleton, :string do
      allow_nil? false
      default "oidc"
    end

    timestamps()
  end

  identities do
    identity :one_oidc_provider, [:singleton]
  end
end
