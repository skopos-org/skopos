defmodule Skopos.Transports.HTTPS do
  @moduledoc false

  @max_ca_bytes 65_536

  def validate_ca_certificate(pem) do
    with {:ok, _certificates} <- certificates(pem), do: :ok
  end

  def transport_options(ca_certificate, host)
      when (is_nil(ca_certificate) or is_binary(ca_certificate)) and is_binary(host) do
    with {:ok, additional} <- certificates(ca_certificate) do
      {:ok,
       [
         verify: :verify_peer,
         cacerts: :public_key.cacerts_get() ++ additional,
         server_name_indication: String.to_charlist(host),
         customize_hostname_check: [
           match_fun: :public_key.pkix_verify_hostname_match_fun(:https)
         ]
       ]}
    end
  rescue
    _error -> {:error, :invalid_ca_certificate}
  end

  def transport_options(_ca_certificate, _host), do: {:error, :invalid_ca_certificate}

  def parse_ca_certificate(pem) when is_binary(pem), do: certificates(pem)
  def parse_ca_certificate(_pem), do: {:error, :invalid_ca_certificate}

  def custom_trust_options(certificates, host)
      when is_list(certificates) and certificates != [] and is_binary(host) and host != "" do
    [
      verify: :verify_peer,
      cacerts: certificates,
      server_name_indication: String.to_charlist(host),
      partial_chain: fn chain ->
        case Enum.find(chain, &(&1 in certificates)) do
          nil -> :unknown_ca
          certificate -> {:trusted_ca, certificate}
        end
      end,
      verify_fun: verify_fun(certificates, host)
    ]
  end

  defp verify_fun(trusted, host) do
    callback = fn
      certificate, {:bad_cert, :selfsigned_peer}, state ->
        der = :public_key.pkix_encode(:OTPCertificate, certificate, :otp)

        if der in state.trusted and valid_hostname?(certificate, state.host),
          do: {:valid, state},
          else: {:fail, :selfsigned_peer}

      _certificate, {:bad_cert, reason}, _state ->
        {:fail, reason}

      _certificate, {:extension, _extension}, state ->
        {:unknown, state}

      _certificate, :valid, state ->
        {:valid, state}

      certificate, :valid_peer, state ->
        if valid_hostname?(certificate, state.host),
          do: {:valid, state},
          else: {:fail, :hostname_check_failed}
    end

    {callback, %{trusted: trusted, host: host}}
  end

  defp valid_hostname?(certificate, host) do
    references =
      case :inet.parse_address(String.to_charlist(host)) do
        {:ok, address} -> [{:ip, address}]
        {:error, _reason} -> [{:dns_id, String.to_charlist(host)}]
      end

    :public_key.pkix_verify_hostname(certificate, references)
  end

  defp certificates(nil), do: {:ok, []}

  defp certificates(pem) when byte_size(pem) <= @max_ca_bytes do
    certificates =
      pem
      |> :public_key.pem_decode()
      |> Enum.flat_map(fn
        {:Certificate, der, :not_encrypted} -> [der]
        _entry -> []
      end)

    if certificates == [],
      do: {:error, :invalid_ca_certificate},
      else: {:ok, certificates}
  rescue
    _error -> {:error, :invalid_ca_certificate}
  end

  defp certificates(_pem), do: {:error, :invalid_ca_certificate}
end
