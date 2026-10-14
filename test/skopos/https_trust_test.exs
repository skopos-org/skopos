defmodule Skopos.HTTPSTrustTest do
  use ExUnit.Case, async: true

  alias Skopos.Transports.HTTPS

  @ca_path "test/support/certs/kubernetes_fixture_ca.pem"
  @leaf_path "test/support/certs/kubernetes_fixture.pem"

  test "custom trust accepts the configured CA and verifies the peer hostname" do
    {:ok, trusted} = @ca_path |> File.read!() |> HTTPS.parse_ca_certificate()
    {:ok, [leaf_der]} = @leaf_path |> File.read!() |> HTTPS.parse_ca_certificate()
    leaf = :public_key.pkix_decode_cert(leaf_der, :otp)

    options = HTTPS.custom_trust_options(trusted, "127.0.0.1")
    assert Keyword.fetch!(options, :verify) == :verify_peer
    assert Keyword.fetch!(options, :cacerts) == trusted
    assert {:trusted_ca, hd(trusted)} == Keyword.fetch!(options, :partial_chain).(trusted)

    {verify, state} = Keyword.fetch!(options, :verify_fun)
    assert {:valid, _state} = verify.(leaf, :valid_peer, state)

    {wrong_host_verify, wrong_host_state} =
      trusted |> HTTPS.custom_trust_options("wrong.example") |> Keyword.fetch!(:verify_fun)

    assert {:fail, :hostname_check_failed} =
             wrong_host_verify.(leaf, :valid_peer, wrong_host_state)

    assert {:fail, :selfsigned_peer} = verify.(leaf, {:bad_cert, :selfsigned_peer}, state)
  end

  test "malformed CA and untrusted certificate are rejected" do
    assert {:error, :invalid_ca_certificate} = HTTPS.parse_ca_certificate("not a certificate")
    assert {:error, :invalid_ca_certificate} = HTTPS.parse_ca_certificate(nil)

    {:ok, [leaf_der]} = @leaf_path |> File.read!() |> HTTPS.parse_ca_certificate()
    leaf = :public_key.pkix_decode_cert(leaf_der, :otp)
    {:ok, trusted} = @ca_path |> File.read!() |> HTTPS.parse_ca_certificate()

    {verify, state} =
      trusted |> HTTPS.custom_trust_options("localhost") |> Keyword.fetch!(:verify_fun)

    assert {:fail, :unknown_ca} = verify.(leaf, {:bad_cert, :unknown_ca}, state)
  end
end
