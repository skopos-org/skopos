defmodule SkoposWeb.API.V1.AccountSchemas do
  @moduledoc false

  alias OpenApiSpex.Schema
  alias SkoposWeb.API.Schemas

  def components do
    %{
      "Account" => account(),
      "AccountResponse" => Schemas.data(ref("Account")),
      "AccountPage" => Schemas.page(ref("Account")),
      "BootstrapAccountRequest" => bootstrap_request(),
      "CreateAccountRequest" => create_account_request(),
      "UpdateAccountRoleRequest" => update_role_request(),
      "UpdateAccountLanguageRequest" => update_language_request(),
      "CreateSessionRequest" => create_session_request(),
      "SessionResponse" => Schemas.data(session()),
      "CurrentSessionResponse" => Schemas.data(object(%{account: ref("Account")}, [:account])),
      "OIDCStatusResponse" => Schemas.data(oidc_status()),
      "OIDCProvider" => oidc_provider(),
      "OIDCProviderResponse" => Schemas.data(ref("OIDCProvider")),
      "ConfigureOIDCProviderRequest" => configure_oidc_request(),
      "OIDCLinkResponse" => Schemas.data(authorization()),
      "CreateCLISessionRequest" => create_cli_session_request(),
      "CLISessionRequestResponse" => Schemas.data(cli_session_request()),
      "CLISessionDecisionRequest" => cli_session_decision_request(),
      "CLISessionApprovalResponse" => Schemas.data(cli_session_approval()),
      "CLISessionDenialResponse" => Schemas.data(redirect()),
      "ExchangeCLISessionRequest" => exchange_cli_session_request(),
      "ExchangeCLISessionResponse" => Schemas.data(session())
    }
  end

  def ref(name), do: Schemas.reference(name)

  def page_parameters do
    Schemas.pagination_parameters() ++
      [
        Schemas.reference_ids_parameter(),
        {:roles,
         [
           in: :query,
           style: :form,
           explode: false,
           schema: %Schema{
             type: :array,
             items: %Schema{type: :string, enum: ~w(admin operator viewer)},
             minItems: 1,
             maxItems: 3
           }
         ]}
      ]
  end

  defp account do
    object(
      %{
        id: Schemas.uuid(),
        email: %Schema{type: :string, format: :email},
        role: %Schema{type: :string, enum: ~w(admin operator viewer)},
        role_version: positive_integer(),
        preferred_language: %Schema{type: :string, enum: ~w(en ja)},
        inserted_at: Schemas.timestamp(),
        updated_at: Schemas.timestamp()
      },
      [:id, :email, :role, :role_version, :preferred_language, :inserted_at, :updated_at],
      false
    )
  end

  defp bootstrap_request do
    object(
      %{
        account:
          object(
            %{
              email: %Schema{type: :string, format: :email},
              password: password(),
              password_confirmation: password()
            },
            [:email, :password, :password_confirmation]
          )
      },
      [:account]
    )
  end

  defp create_account_request do
    object(
      %{
        account:
          object(
            %{
              email: %Schema{type: :string, format: :email},
              password: password(),
              role: %Schema{type: :string, enum: ~w(admin operator viewer)}
            },
            [:email, :password, :role]
          )
      },
      [:account]
    )
  end

  defp update_role_request do
    object(
      %{
        account:
          object(
            %{role: %Schema{type: :string, enum: ~w(admin operator viewer)}},
            [:role]
          )
      },
      [:account]
    )
  end

  defp update_language_request do
    object(
      %{
        account:
          object(
            %{preferred_language: %Schema{type: :string, enum: ~w(en ja)}},
            [:preferred_language]
          )
      },
      [:account]
    )
  end

  defp create_session_request do
    object(
      %{
        session:
          object(
            %{
              email: %Schema{type: :string, format: :email},
              password: %Schema{type: :string, writeOnly: true}
            },
            [:email, :password]
          )
      },
      [:session]
    )
  end

  defp session do
    object(
      %{token: %Schema{type: :string}, account: ref("Account")},
      [:token, :account],
      false
    )
  end

  defp oidc_status do
    object(
      %{
        enabled: %Schema{type: :boolean},
        authorization_url: %Schema{type: :string, format: :uri, nullable: true},
        callback_uri: %Schema{type: :string, format: :uri}
      },
      [:enabled, :authorization_url, :callback_uri],
      false
    )
  end

  defp oidc_provider do
    object(
      %{
        id: Schemas.uuid(),
        issuer: %Schema{type: :string, format: :uri},
        client_id: %Schema{type: :string},
        id_token_alg: id_token_algorithm(),
        enabled: %Schema{type: :boolean},
        revision: positive_integer(),
        callback_uri: %Schema{type: :string, format: :uri},
        inserted_at: Schemas.timestamp(),
        updated_at: Schemas.timestamp()
      },
      [:enabled, :callback_uri],
      false
    )
  end

  defp configure_oidc_request do
    object(
      %{
        oidc_provider:
          object(
            %{
              issuer: %Schema{type: :string, format: :uri},
              client_id: %Schema{type: :string, minLength: 1},
              client_secret: %Schema{type: :string, minLength: 1, writeOnly: true},
              id_token_alg: id_token_algorithm(),
              enabled: %Schema{type: :boolean}
            },
            [:issuer, :client_id, :client_secret]
          )
      },
      [:oidc_provider]
    )
  end

  defp authorization do
    object(
      %{
        authorization_url: %Schema{type: :string, format: :uri},
        expires_at: Schemas.timestamp()
      },
      [:authorization_url, :expires_at],
      false
    )
  end

  defp create_cli_session_request do
    object(
      %{
        request:
          object(
            %{
              redirect_uri: %Schema{type: :string, format: :uri},
              code_challenge: %Schema{
                type: :string,
                minLength: 43,
                maxLength: 43,
                writeOnly: true
              }
            },
            [:redirect_uri, :code_challenge]
          )
      },
      [:request]
    )
  end

  defp cli_session_request do
    object(
      %{
        id: Schemas.uuid(),
        authorization_url: %Schema{type: :string, format: :uri},
        expires_at: Schemas.timestamp()
      },
      [:id, :authorization_url, :expires_at],
      false
    )
  end

  defp cli_session_decision_request do
    object(
      %{
        request:
          object(
            %{start_token: %Schema{type: :string, minLength: 1, writeOnly: true}},
            [:start_token]
          )
      },
      [:request]
    )
  end

  defp cli_session_approval do
    object(
      %{redirect_uri: %Schema{type: :string, format: :uri}, account: ref("Account")},
      [:redirect_uri, :account],
      false
    )
  end

  defp redirect do
    object(%{redirect_uri: %Schema{type: :string, format: :uri}}, [:redirect_uri], false)
  end

  defp exchange_cli_session_request do
    object(
      %{
        request:
          object(
            %{
              code: %Schema{type: :string, minLength: 1, writeOnly: true},
              verifier: %Schema{type: :string, minLength: 1, writeOnly: true}
            },
            [:code, :verifier]
          )
      },
      [:request]
    )
  end

  defp password, do: %Schema{type: :string, minLength: 12, writeOnly: true}
  defp positive_integer, do: %Schema{type: :integer, minimum: 1}

  defp id_token_algorithm do
    %Schema{type: :string, enum: ~w(RS256 PS256 ES256 ES384 ES512 EdDSA Ed25519 Ed448)}
  end

  defp object(properties, required, additional_properties \\ nil) do
    %Schema{
      type: :object,
      properties: properties,
      required: required,
      additionalProperties: additional_properties
    }
  end
end
