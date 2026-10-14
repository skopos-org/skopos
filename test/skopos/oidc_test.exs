defmodule Skopos.OIDCTest do
  use Skopos.DataCase, async: false

  alias Skopos.Accounts
  alias Skopos.Accounts.{User, UserIdentity}
  alias Skopos.Accounts.OIDC.Provider, as: OIDCProvider
  alias Skopos.Accounts.OIDC.Request, as: OIDCRequest

  @issuer "https://identity.example.test/realms/skopos"
  @stub __MODULE__.Provider
  @password "correct horse battery staple"
  @callback_uri "http://localhost:4000/auth/user/oidc/callback"

  setup do
    Req.Test.set_req_test_to_shared()
    previous = Application.get_env(:skopos, Skopos.Accounts.OIDC.Client)

    Application.put_env(:skopos, Skopos.Accounts.OIDC.Client,
      req_options: [plug: {Req.Test, @stub}]
    )

    key =
      {:rsa, 2048}
      |> JOSE.JWK.generate_key()
      |> JOSE.JWK.merge(%{"alg" => "RS256", "kid" => "skopos-test", "use" => "sig"})

    {_, public_key} = key |> JOSE.JWK.to_public() |> JOSE.JWK.to_map()
    {:ok, response} = Agent.start_link(fn -> nil end)

    Req.Test.stub(@stub, fn conn ->
      case conn.request_path do
        "/realms/skopos/.well-known/openid-configuration" ->
          Req.Test.json(conn, %{
            "issuer" => @issuer,
            "authorization_endpoint" => @issuer <> "/authorize",
            "token_endpoint" => @issuer <> "/token",
            "jwks_uri" => @issuer <> "/jwks",
            "response_types_supported" => ["code"],
            "subject_types_supported" => ["public"],
            "id_token_signing_alg_values_supported" => ["RS256"],
            "code_challenge_methods_supported" => ["S256"]
          })

        "/realms/skopos/jwks" ->
          Req.Test.json(conn, %{"keys" => [public_key]})

        "/realms/skopos/token" ->
          Req.Test.json(conn, Agent.get(response, & &1))
      end
    end)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:skopos, Skopos.Accounts.OIDC.Client, previous),
        else: Application.delete_env(:skopos, Skopos.Accounts.OIDC.Client)

      Req.Test.set_req_test_to_private()
    end)

    %{key: key, response: response}
  end

  test "AttestoClient binds authorization state to the browser and consumes it once", context do
    admin = bootstrap_admin!()
    configure_provider!(admin)
    authorization = Accounts.begin_oidc_authorization!(nil, nil, nil, @callback_uri)
    params = callback_params(authorization, context, "unknown-subject")

    assert {:error, _error} =
             Accounts.complete_oidc_authorization(
               params,
               "another-browser",
               authorization.provider_revision,
               nil
             )

    assert {:error, _error} =
             Accounts.complete_oidc_authorization(
               params,
               authorization.browser_binding,
               authorization.provider_revision,
               nil
             )

    assert Ash.count!(User, authorize?: false) == 1
    assert Ash.count!(UserIdentity, authorize?: false) == 0
  end

  test "an unknown verified OIDC subject cannot create or select a local account", context do
    admin = bootstrap_admin!()
    configure_provider!(admin)
    authorization = Accounts.begin_oidc_authorization!(nil, nil, nil, @callback_uri)

    assert {:error, _error} =
             Accounts.complete_oidc_authorization(
               callback_params(authorization, context, "unknown-subject"),
               authorization.browser_binding,
               authorization.provider_revision,
               nil
             )

    assert Ash.count!(User, authorize?: false) == 1
    assert Ash.count!(UserIdentity, authorize?: false) == 0
  end

  test "a local account explicitly links one verified subject and later signs in", context do
    admin = bootstrap_admin!()
    configure_provider!(admin)
    link_request = Accounts.request_oidc_link!(actor: admin)

    link_authorization =
      Accounts.begin_oidc_authorization!(
        link_request.request.id,
        link_request.start_token,
        nil,
        @callback_uri
      )

    linked =
      Accounts.complete_oidc_authorization!(
        callback_params(link_authorization, context, "linked-subject"),
        link_authorization.browser_binding,
        link_authorization.provider_revision,
        link_request.request.id
      )

    assert linked.linked?
    assert linked.session.user.id == admin.id
    assert is_binary(linked.session.token)

    [identity] = Ash.read!(UserIdentity, authorize?: false)
    assert identity.user_id == admin.id
    assert identity.strategy == "oidc"
    assert identity.uid == "linked-subject"
    assert Ash.get!(OIDCRequest, link_request.request.id, authorize?: false).completed_at

    login_authorization = Accounts.begin_oidc_authorization!(nil, nil, nil, @callback_uri)

    signed_in =
      Accounts.complete_oidc_authorization!(
        callback_params(login_authorization, context, "linked-subject"),
        login_authorization.browser_binding,
        login_authorization.provider_revision,
        nil
      )

    refute signed_in.linked?
    assert signed_in.session.user.id == admin.id
    assert is_binary(signed_in.session.token)

    second_request = Accounts.request_oidc_link!(actor: admin)

    second_authorization =
      Accounts.begin_oidc_authorization!(
        second_request.request.id,
        second_request.start_token,
        nil,
        @callback_uri
      )

    assert {:error, _error} =
             Accounts.complete_oidc_authorization(
               callback_params(second_authorization, context, "another-subject"),
               second_authorization.browser_binding,
               second_authorization.provider_revision,
               second_request.request.id
             )

    assert Ash.count!(UserIdentity, authorize?: false) == 1
    refute Ash.get!(OIDCRequest, second_request.request.id, authorize?: false).completed_at
  end

  test "a verified callback cannot be applied to another account's link request", context do
    admin = bootstrap_admin!()

    operator =
      Accounts.create_user!(
        "oidc-link-operator@example.com",
        @password,
        :operator,
        actor: admin
      )

    configure_provider!(admin)
    admin_request = Accounts.request_oidc_link!(actor: admin)
    operator_request = Accounts.request_oidc_link!(actor: operator)

    admin_authorization =
      Accounts.begin_oidc_authorization!(
        admin_request.request.id,
        admin_request.start_token,
        nil,
        @callback_uri
      )

    _operator_authorization =
      Accounts.begin_oidc_authorization!(
        operator_request.request.id,
        operator_request.start_token,
        nil,
        @callback_uri
      )

    assert {:error, _error} =
             Accounts.complete_oidc_authorization(
               callback_params(admin_authorization, context, "admin-subject"),
               admin_authorization.browser_binding,
               admin_authorization.provider_revision,
               operator_request.request.id
             )

    assert Ash.count!(UserIdentity, authorize?: false) == 0
    refute Ash.get!(OIDCRequest, admin_request.request.id, authorize?: false).completed_at
    refute Ash.get!(OIDCRequest, operator_request.request.id, authorize?: false).completed_at
  end

  test "provider secret is encrypted and issuer identity becomes immutable after linking" do
    admin = bootstrap_admin!()
    provider = configure_provider!(admin)

    encrypted =
      Skopos.Repo.query!("select encrypted_client_secret from oidc_providers where id = $1", [
        Ecto.UUID.dump!(provider.id)
      ]).rows
      |> hd()
      |> hd()

    assert is_binary(encrypted)
    refute encrypted =~ "provider-secret"

    Ash.create!(
      UserIdentity,
      %{strategy: "oidc", uid: "subject", user_id: admin.id},
      action: :link,
      authorize?: false
    )

    assert {:error, _error} =
             Accounts.configure_oidc(
               %{
                 issuer: "https://replacement.example.test",
                 client_id: "replacement",
                 client_secret: "replacement-secret",
                 id_token_alg: "RS256",
                 enabled: true
               },
               actor: admin
             )

    assert Accounts.current_oidc_provider!(actor: admin).id == provider.id
    assert Ash.count!(OIDCProvider, authorize?: false) == 1
  end

  test "CLI exchange request is short-lived, verifier-bound and single-use" do
    verifier = OIDCRequest.random_secret()
    user = bootstrap_admin!()
    challenge = verifier |> OIDCRequest.digest() |> Base.url_encode64(padding: false)
    authorization = Accounts.request_cli_login!("http://127.0.0.1:54321/callback", challenge)

    approval =
      Accounts.approve_cli_login!(
        authorization.request.id,
        authorization.start_token,
        actor: user
      )

    assert {:error, _error} =
             Accounts.exchange_cli_login(
               approval.request.id,
               approval.code,
               "wrong-verifier"
             )

    session = Accounts.exchange_cli_login!(approval.request.id, approval.code, verifier)
    assert is_binary(session.token)
    assert session.user.id == user.id

    assert {:error, _error} =
             Accounts.exchange_cli_login(approval.request.id, approval.code, verifier)
  end

  test "CLI approval requires an actor and exchange uses the actor's current role" do
    admin = bootstrap_admin!()

    operator =
      Accounts.create_user!(
        "oidc-operator@example.com",
        @password,
        :operator,
        actor: admin
      )

    verifier = OIDCRequest.random_secret()
    challenge = verifier |> OIDCRequest.digest() |> Base.url_encode64(padding: false)
    authorization = Accounts.request_cli_login!("http://127.0.0.1:54321/callback", challenge)

    assert {:error, %Ash.Error.Forbidden{}} =
             Accounts.approve_cli_login(
               authorization.request.id,
               authorization.start_token
             )

    approval =
      Accounts.approve_cli_login!(
        authorization.request.id,
        authorization.start_token,
        actor: operator
      )

    Accounts.change_role!(operator, :viewer, actor: admin)
    session = Accounts.exchange_cli_login!(approval.request.id, approval.code, verifier)
    assert session.user.id == operator.id
    assert session.user.role == :viewer
  end

  test "expired and concurrently claimed CLI requests cannot issue multiple grants" do
    admin = bootstrap_admin!()
    verifier = OIDCRequest.random_secret()
    challenge = verifier |> OIDCRequest.digest() |> Base.url_encode64(padding: false)
    expired = Accounts.request_cli_login!("http://127.0.0.1:54321/callback", challenge)

    Skopos.Repo.query!(
      "update oidc_requests set expires_at = now() - interval '1 second' where id = $1",
      [Ecto.UUID.dump!(expired.request.id)]
    )

    assert {:error, _error} =
             Accounts.approve_cli_login(
               expired.request.id,
               expired.start_token,
               actor: admin
             )

    authorization = Accounts.request_cli_login!("http://127.0.0.1:54322/callback", challenge)

    results =
      1..2
      |> Enum.map(fn _attempt ->
        Task.async(fn ->
          Accounts.approve_cli_login(
            authorization.request.id,
            authorization.start_token,
            actor: admin
          )
        end)
      end)
      |> Enum.map(&Task.await/1)

    assert Enum.count(results, &match?({:ok, _approval}, &1)) == 1
    assert Enum.count(results, &match?({:error, _error}, &1)) == 1
  end

  defp callback_params(authorization, context, subject) do
    query = authorization.url |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query()
    now = System.system_time(:second)

    claims = %{
      "iss" => @issuer,
      "sub" => subject,
      "aud" => "skopos",
      "exp" => now + 300,
      "iat" => now,
      "nonce" => query["nonce"]
    }

    {_, id_token} =
      context.key
      |> JOSE.JWT.sign(%{"alg" => "RS256", "kid" => "skopos-test", "typ" => "JWT"}, claims)
      |> JOSE.JWS.compact()

    Agent.update(context.response, fn _current ->
      %{
        "access_token" => "access-token",
        "token_type" => "Bearer",
        "expires_in" => 300,
        "id_token" => id_token
      }
    end)

    %{"state" => query["state"], "code" => "authorization-code"}
  end

  defp bootstrap_admin! do
    Accounts.bootstrap!(
      "oidc-admin@example.com",
      @password,
      @password,
      authorize?: true
    )
  end

  defp configure_provider!(admin) do
    Accounts.configure_oidc!(
      %{
        issuer: @issuer,
        client_id: "skopos",
        client_secret: "provider-secret",
        id_token_alg: "RS256",
        enabled: true
      },
      actor: admin
    )
  end
end
