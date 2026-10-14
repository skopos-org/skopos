defmodule SkoposWeb.PublicURL do
  @moduledoc false

  def oidc_callback_uri, do: url("/auth/user/oidc/callback")

  def url(path) do
    public = Application.fetch_env!(:skopos, :public_url) |> URI.parse()
    destination = URI.parse(path)

    to_string(%URI{
      destination
      | scheme: public.scheme,
        host: public.host,
        port: public.port,
        userinfo: nil
    })
  end
end
