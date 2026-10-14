defmodule Skopos.Providers.RedactorTest do
  use ExUnit.Case, async: true

  alias Skopos.Providers.Redactor

  test "redacts secrets without destroying non-secret connection identifiers" do
    credentials = %{
      "username" => "skopos",
      "auth_method" => "password",
      "password" => "correct horse battery staple"
    }

    output = "skopos-validation.service belongs to skopos; correct horse battery staple"

    assert Redactor.message(output, credentials) ==
             "skopos-validation.service belongs to skopos; [REDACTED]"
  end

  test "redacts nested values only when they belong to a secret field" do
    credentials = %{
      "endpoint" => %{"host" => "switch-01", "port" => 22},
      "client_secret" => %{"current" => "nested-secret"}
    }

    assert Redactor.message("switch-01:22 nested-secret", credentials) ==
             "switch-01:22 [REDACTED]"
  end
end
