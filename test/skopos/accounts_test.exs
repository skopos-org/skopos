defmodule Skopos.AccountsTest do
  use Skopos.DataCase, async: false

  alias Skopos.Accounts
  alias Skopos.Accounts.Token
  alias Skopos.Accounts.User

  @password "correct horse battery staple"

  test "only one bootstrap administrator is created and the password is hashed" do
    admin = bootstrap_admin!()

    assert admin.role == :admin
    assert admin.role_version == 1
    assert admin.preferred_language == :en
    assert admin.hashed_password != @password
    assert String.starts_with?(admin.hashed_password, "$argon2")

    assert {:error, error} =
             Accounts.bootstrap(
               "second@example.com",
               @password,
               @password,
               authorize?: true
             )

    assert Exception.message(error) =~ "bootstrap_marker"
    assert Ash.count!(User, authorize?: false) == 1
  end

  test "password sign-in stores a revocable token and hides credential material" do
    bootstrap_admin!()

    assert {:error, missing_error} =
             Accounts.sign_in("missing@example.com", "wrong password", authorize?: true)

    assert {:error, wrong_error} =
             Accounts.sign_in("admin@example.com", "wrong password", authorize?: true)

    assert error_messages(missing_error) == error_messages(wrong_error)
    assert Enum.any?(error_messages(wrong_error), &String.contains?(&1, "Authentication failed"))
    refute inspect(wrong_error) =~ "wrong password"

    signed_in = Accounts.sign_in!("admin@example.com", @password, authorize?: true)
    token = Ash.Resource.get_metadata(signed_in, :token)

    assert is_binary(token)
    refute inspect(signed_in) =~ token
    assert authenticated_user(token).id == signed_in.id

    [stored_token] = Ash.read!(Token, authorize?: false)
    refute inspect(stored_token) =~ token
    refute Map.has_key?(Map.from_struct(stored_token), :token)
  end

  test "logout and expiry invalidate authentication" do
    bootstrap_admin!()
    signed_in = Accounts.sign_in!("admin@example.com", @password, authorize?: true)
    token = Ash.Resource.get_metadata(signed_in, :token)

    token
    |> bearer_conn()
    |> AshAuthentication.Plug.Helpers.revoke_bearer_tokens(:skopos)

    assert authenticated_user(token) == nil

    {:ok, expired_token, claims} =
      AshAuthentication.Jwt.token_for_user(
        signed_in,
        %{"purpose" => "user"},
        token_lifetime: -1
      )

    assert claims["exp"] < System.system_time(:second)
    assert authenticated_user(expired_token) == nil
  end

  test "administrator policy is enforced and role changes revoke existing tokens" do
    admin = bootstrap_admin!()

    operator =
      Accounts.create_user!("operator@example.com", @password, :operator, actor: admin)

    assert {:error, %Ash.Error.Forbidden{}} =
             Accounts.create_user(
               "forbidden@example.com",
               @password,
               :viewer,
               actor: operator
             )

    signed_in = Accounts.sign_in!("operator@example.com", @password, authorize?: true)
    token = Ash.Resource.get_metadata(signed_in, :token)
    assert authenticated_user(token).role == :operator

    viewer = Accounts.change_role!(operator, :viewer, actor: admin)
    assert viewer.role == :viewer
    assert viewer.role_version == operator.role_version + 1
    assert authenticated_user(token) == nil

    renewed = Accounts.sign_in!("operator@example.com", @password, authorize?: true)
    renewed_token = Ash.Resource.get_metadata(renewed, :token)
    assert authenticated_user(renewed_token).role == :viewer
  end

  test "each account controls its own preferred language" do
    admin = bootstrap_admin!()
    operator = Accounts.create_user!("operator@example.com", @password, :operator, actor: admin)

    updated = Accounts.change_preferred_language!(operator, :ja, actor: operator)
    assert updated.preferred_language == :ja

    assert {:error, %Ash.Error.Forbidden{}} =
             Accounts.change_preferred_language(admin, :ja, actor: operator)
  end

  defp bootstrap_admin! do
    Accounts.bootstrap!("admin@example.com", @password, @password, authorize?: true)
  end

  defp authenticated_user(token) do
    token
    |> bearer_conn()
    |> AshAuthentication.Plug.Helpers.retrieve_from_bearer(:skopos)
    |> then(& &1.assigns[:current_user])
  end

  defp bearer_conn(token) do
    Plug.Test.conn(:get, "/")
    |> Plug.Conn.put_req_header("authorization", "Bearer " <> token)
  end

  defp error_messages(error), do: Enum.map(error.errors, &Exception.message/1)
end
