defmodule Skopos.Accounts.User do
  use Ash.Resource,
    otp_app: :skopos,
    domain: Skopos.Accounts,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    extensions: [AshAuthentication]

  authentication do
    add_ons do
      log_out_everywhere do
        apply_on_password_change? true
      end
    end

    tokens do
      enabled? true
      token_resource Skopos.Accounts.Token
      signing_secret Skopos.Accounts.User.SigningSecret
      store_all_tokens? true
      require_token_presence_for_authentication? true
    end

    strategies do
      password :password do
        identity_field :email
        hash_provider AshAuthentication.Argon2Provider
        registration_enabled? false
        sign_in_tokens_enabled? false
      end
    end
  end

  postgres do
    table "users"
    repo Skopos.Repo
  end

  actions do
    defaults [:read]

    read :page do
      argument :ids, {:array, :uuid}, constraints: [min_length: 1, max_length: 100]

      argument :roles, {:array, :atom},
        constraints: [min_length: 1, max_length: 3, items: [one_of: [:admin, :operator, :viewer]]]

      filter expr(
               (is_nil(^arg(:ids)) or id in ^arg(:ids)) and
                 (is_nil(^arg(:roles)) or role in ^arg(:roles))
             )

      pagination keyset?: true, required?: true, default_limit: 50, max_page_size: 100

      prepare build(
                select: ~w(id email role role_version preferred_language inserted_at updated_at)a,
                sort: [inserted_at: :asc, id: :asc]
              )
    end

    read :get_by_subject do
      description "Get a user by the subject claim in a JWT"
      argument :subject, :string, allow_nil?: false
      get? true
      prepare AshAuthentication.Preparations.FilterBySubject
    end

    read :sign_in_with_password do
      description "Sign in using an email address and password."
      get? true

      argument :email, :ci_string, allow_nil?: false
      argument :password, :string, allow_nil?: false, sensitive?: true

      prepare set_context(%{
                strategy_name: :password,
                private: %{ash_authentication?: true}
              })

      prepare AshAuthentication.Strategy.Password.SignInPreparation

      metadata :token, :string do
        allow_nil? false
      end
    end

    create :bootstrap do
      accept []

      argument :email, :ci_string, allow_nil?: false

      argument :password, :string,
        allow_nil?: false,
        sensitive?: true,
        constraints: [min_length: 12]

      argument :password_confirmation, :string, allow_nil?: false, sensitive?: true

      change set_context(%{strategy_name: :password})
      change set_attribute(:email, arg(:email))
      change set_attribute(:role, :admin)
      change set_attribute(:bootstrap_marker, "initial_admin")
      change {AshAuthentication.Strategy.Password.HashPasswordChange, strategy_name: :password}
      validate AshAuthentication.Strategy.Password.PasswordConfirmationValidation
    end

    create :create_user do
      accept []

      argument :email, :ci_string, allow_nil?: false

      argument :password, :string,
        allow_nil?: false,
        sensitive?: true,
        constraints: [min_length: 12]

      argument :role, :atom,
        allow_nil?: false,
        constraints: [one_of: [:admin, :operator, :viewer]]

      change set_context(%{strategy_name: :password})
      change set_attribute(:email, arg(:email))
      change set_attribute(:role, arg(:role))
      change {AshAuthentication.Strategy.Password.HashPasswordChange, strategy_name: :password}
    end

    update :change_role do
      accept []

      argument :role, :atom,
        allow_nil?: false,
        constraints: [one_of: [:admin, :operator, :viewer]]

      change set_attribute(:role, arg(:role))
      change atomic_update(:role_version, expr(role_version + 1))
      change Skopos.Accounts.User.Changes.RevokeTokens
    end

    update :change_preferred_language do
      accept []

      argument :preferred_language, :atom,
        allow_nil?: false,
        constraints: [one_of: [:en, :ja]]

      change set_attribute(:preferred_language, arg(:preferred_language))
    end
  end

  policies do
    bypass AshAuthentication.Checks.AshAuthenticationInteraction do
      authorize_if always()
    end

    bypass actor_attribute_equals(:role, :admin) do
      authorize_if always()
    end

    policy action(:bootstrap) do
      authorize_if always()
    end

    policy action(:sign_in_with_password) do
      authorize_if always()
    end

    policy action(:change_preferred_language) do
      authorize_if expr(id == ^actor(:id))
    end

    policy action_type(:read) do
      authorize_if expr(id == ^actor(:id))
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :email, :ci_string do
      allow_nil? false
      public? true
    end

    attribute :hashed_password, :string do
      allow_nil? false
      sensitive? true
    end

    attribute :role, :atom do
      allow_nil? false
      public? true
      default :viewer
      constraints one_of: [:admin, :operator, :viewer]
    end

    attribute :role_version, :integer do
      allow_nil? false
      public? true
      default 1
      constraints min: 1
    end

    attribute :preferred_language, :atom do
      allow_nil? false
      public? true
      default :en
      constraints one_of: [:en, :ja]
    end

    attribute :bootstrap_marker, :string do
      sensitive? true
    end

    timestamps()
  end

  identities do
    identity :unique_email, [:email]
    identity :single_bootstrap_admin, [:bootstrap_marker]
  end
end
