defmodule Skopos.Accounts do
  use Ash.Domain,
    otp_app: :skopos

  resources do
    resource Skopos.Accounts.User do
      define :bootstrap, action: :bootstrap, args: [:email, :password, :password_confirmation]
      define :create_user, action: :create_user, args: [:email, :password, :role]
      define :change_role, action: :change_role, args: [:role]

      define :change_preferred_language,
        action: :change_preferred_language,
        args: [:preferred_language]

      define :list_users, action: :page
      define :get_user, action: :read, get_by: [:id]
      define :sign_in, action: :sign_in_with_password, args: [:email, :password]
    end

    resource Skopos.Accounts.Token
    resource Skopos.Accounts.UserIdentity

    resource Skopos.Accounts.OIDC.Provider do
      define :configure_oidc, action: :configure
      define :current_oidc_provider, action: :current
      define :oidc_available?, action: :available

      define :begin_oidc_authorization,
        action: :begin_authorization,
        args: [:request_id, :start_token, :provider_revision, :callback_uri]

      define :complete_oidc_authorization,
        action: :complete_authorization,
        args: [:params, :browser_binding, :provider_revision, :request_id]
    end

    resource Skopos.Accounts.OIDC.Request do
      define :request_oidc_link, action: :request_link

      define :request_cli_login,
        action: :request_cli_login,
        args: [:redirect_uri, :code_challenge]

      define :approve_cli_login,
        action: :approve_cli_login,
        args: [:id, :start_token]

      define :deny_cli_login,
        action: :deny_cli_login,
        args: [:id, :start_token]

      define :exchange_cli_login,
        action: :exchange_cli_login,
        args: [:id, :code, :verifier]
    end
  end
end
