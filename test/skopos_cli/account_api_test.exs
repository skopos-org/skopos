defmodule SkoposCLI.AccountAPITest do
  use SkoposWeb.ConnCase, async: false

  import ExUnit.CaptureIO

  alias Skopos.Accounts
  alias SkoposCLI.{CLI, Config}

  @password "correct horse battery staple"

  @tag account_filters: true
  test "remote CLI pages accounts and changes the selected tail account through the authenticated API" do
    Accounts.bootstrap!("account-cli-admin@example.com", @password, @password, authorize?: true)

    token =
      build_json_conn(%{})
      |> post("/api/v1/sessions", %{
        "session" => %{"email" => "account-cli-admin@example.com", "password" => @password}
      })
      |> json_response(201)
      |> get_in(["data", "token"])

    root =
      Path.join(System.tmp_dir!(), "skopos-account-cli-#{System.unique_integer([:positive])}")

    config_path = Path.join(root, "config.json")
    :ok = Config.save(%{"server" => "https://skopos.example", "token" => token}, config_path)
    on_exit(fn -> File.rm_rf(root) end)

    stub = {__MODULE__, make_ref()}
    Req.Test.stub(stub, &SkoposWeb.Endpoint.call(&1, SkoposWeb.Endpoint.init([])))
    runtime = [config_path: config_path, request_options: [plug: {Req.Test, stub}]]

    for index <- [1, 2] do
      output =
        capture_io(
          Jason.encode!(%{
            email: "account-cli-#{index}@example.com",
            password: @password,
            role: "operator"
          }),
          fn -> assert CLI.run(["account", "create", "--input", "-"], runtime) == 0 end
        )

      assert %{"data" => %{"role" => "operator", "role_version" => 1}} = Jason.decode!(output)
      refute output =~ @password
      refute output =~ "hashed_password"
    end

    first =
      capture_io(fn -> assert CLI.run(["account", "list", "--limit", "2"], runtime) == 0 end)

    assert %{"data" => first_accounts, "page" => %{"next" => cursor}} = Jason.decode!(first)
    assert length(first_accounts) == 2
    assert is_binary(cursor)

    tail =
      capture_io(fn ->
        assert CLI.run(["account", "list", "--limit", "2", "--after", cursor], runtime) == 0
      end)

    assert %{
             "data" => [%{"id" => selected_id, "email" => "account-cli-2@example.com"}],
             "page" => %{"next" => nil}
           } =
             Jason.decode!(tail)

    changed =
      capture_io(Jason.encode!(%{role: "viewer"}), fn ->
        assert CLI.run(["account", "change-role", selected_id, "--input", "-"], runtime) == 0
      end)

    assert %{"data" => %{"id" => ^selected_id, "role" => "viewer", "role_version" => 2}} =
             Jason.decode!(changed)

    refreshed =
      capture_io(fn ->
        assert CLI.run(["account", "list", "--limit", "2", "--after", cursor], runtime) == 0
      end)

    assert %{"data" => [%{"id" => ^selected_id, "role" => "viewer", "role_version" => 2}]} =
             Jason.decode!(refreshed)

    refute refreshed =~ @password
    refute refreshed =~ token

    exact =
      capture_io(fn ->
        assert CLI.run(["account", "list", "--ids", selected_id, "--limit", "1"], runtime) == 0
      end)

    assert %{"data" => [%{"id" => ^selected_id, "role" => "viewer"}], "page" => %{"next" => nil}} =
             Jason.decode!(exact)

    eligible =
      capture_io(fn ->
        assert CLI.run(["account", "list", "--roles", "operator", "--limit", "1"], runtime) == 0
      end)

    assert %{
             "data" => [%{"email" => "account-cli-1@example.com", "role" => "operator"}],
             "page" => %{"next" => nil}
           } = Jason.decode!(eligible)

    intersection =
      capture_io(fn ->
        assert CLI.run(
                 ["account", "list", "--ids", selected_id, "--roles", "operator,admin"],
                 runtime
               ) == 0
      end)

    assert %{"data" => [], "page" => %{"next" => nil}} = Jason.decode!(intersection)
  end
end
