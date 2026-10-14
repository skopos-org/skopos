defmodule SkoposWeb.CaseChannelTest do
  use SkoposWeb.ConnCase, async: false

  import Phoenix.ChannelTest
  import Plug.Conn

  alias AshAuthentication.Plug.Helpers
  alias Skopos.{Accounts, Cases}
  alias SkoposWeb.{CaseChannel, UserSocket}

  @endpoint SkoposWeb.Endpoint
  @password "correct horse battery staple"

  setup do
    admin =
      Accounts.bootstrap!("channel-admin@example.com", @password, @password, authorize?: true)

    signed_in = Accounts.sign_in!(admin.email, @password, authorize?: true)
    token = Ash.Resource.get_metadata(signed_in, :token)
    incident = open_case!("channel-primary", signed_in)

    %{admin: signed_in, case: incident, token: token}
  end

  test "join requires a current bearer token and a readable Case", context do
    assert {:error, %{reason: "unavailable"}} = join_case(context.case.id, %{})

    assert {:error, %{reason: "unavailable"}} =
             join_case(context.case.id, %{"token" => "invalid"})

    assert {:error, %{reason: "unavailable"}} =
             join_case(Ecto.UUID.generate(), %{"token" => context.token})

    revoked =
      Phoenix.ConnTest.build_conn()
      |> put_req_header("authorization", "Bearer " <> context.token)
      |> Helpers.revoke_bearer_tokens(:skopos)

    assert revoked.status in [nil, 200]

    assert {:error, %{reason: "unavailable"}} =
             join_case(context.case.id, %{"token" => context.token})
  end

  test "successful Case writes push only to the matching topic", context do
    assert {:ok, _reply, _socket} = join_case(context.case.id, %{"token" => context.token})
    other = open_case!("channel-other", context.admin)

    Cases.claim_case!(other.id, other.revision, actor: context.admin)
    refute_push "changed", %{}, 100

    Cases.claim_case!(context.case.id, context.case.revision, actor: context.admin)
    assert_push "changed", %{}
  end

  test "failed writes do not publish a Case change", context do
    :ok = Skopos.Cases.Case.Realtime.subscribe(context.case.id)

    assert {:error, _error} =
             Cases.record_case_owner(
               context.case,
               context.case.revision + 100,
               context.admin.id,
               authorize?: false
             )

    refute_receive {:case_changed, _case_id}, 100
  end

  defp join_case(case_id, payload) do
    UserSocket
    |> socket("case-channel-test", %{})
    |> subscribe_and_join(CaseChannel, "case:" <> case_id, payload)
  end

  defp open_case!(source_ref, actor) do
    Cases.open_case!(
      :manual,
      "channel-test",
      source_ref,
      "Case #{source_ref}",
      :warning,
      %{"desired_outcome" => "Target responds as expected"},
      nil,
      :en,
      actor: actor
    )
  end
end
