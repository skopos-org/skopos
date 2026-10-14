defmodule Skopos.Targets.Profiles.HPEILO.IPMI do
  @moduledoc false

  @behaviour Skopos.Providers.Adapter
  @behaviour Skopos.Providers.Target

  alias Skopos.Targets.Adapters.IPMI

  @impl Skopos.Providers.Adapter
  def type, do: "hpe-ilo-ipmi"

  @impl Skopos.Providers.Adapter
  def kind, do: :target

  @impl Skopos.Providers.Target
  defdelegate access_method_profile(), to: IPMI

  @impl Skopos.Providers.Adapter
  defdelegate build(configuration, credentials), to: IPMI

  @impl Skopos.Providers.Adapter
  defdelegate check(state, input), to: IPMI

  @impl Skopos.Providers.Target
  defdelegate bind_connection(state, connection), to: IPMI

  @impl Skopos.Providers.Target
  defdelegate capabilities(state, invocation), to: IPMI

  @impl Skopos.Providers.Target
  defdelegate classify_request(state, request), to: IPMI

  @impl Skopos.Providers.Target
  defdelegate observe(state, request, invocation), to: IPMI

  @impl Skopos.Providers.Target
  defdelegate effect(state, request, invocation), to: IPMI

  @impl Skopos.Providers.Target
  defdelegate verify(state, request, invocation), to: IPMI
end
