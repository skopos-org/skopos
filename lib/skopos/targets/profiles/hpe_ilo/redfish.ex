defmodule Skopos.Targets.Profiles.HPEILO.Redfish do
  @moduledoc false

  @behaviour Skopos.Providers.Adapter
  @behaviour Skopos.Providers.Target

  alias Skopos.Targets.Adapters.Redfish

  @impl Skopos.Providers.Adapter
  def type, do: "hpe-ilo-redfish"

  @impl Skopos.Providers.Adapter
  def kind, do: :target

  @impl Skopos.Providers.Target
  defdelegate access_method_profile(), to: Redfish

  @impl Skopos.Providers.Adapter
  defdelegate build(configuration, credentials), to: Redfish

  @impl Skopos.Providers.Adapter
  defdelegate check(state, input), to: Redfish

  @impl Skopos.Providers.Target
  defdelegate bind_connection(state, connection), to: Redfish

  @impl Skopos.Providers.Target
  defdelegate capabilities(state, invocation), to: Redfish

  @impl Skopos.Providers.Target
  defdelegate classify_request(state, request), to: Redfish

  @impl Skopos.Providers.Target
  defdelegate observe(state, request, invocation), to: Redfish

  @impl Skopos.Providers.Target
  defdelegate effect(state, request, invocation), to: Redfish

  @impl Skopos.Providers.Target
  defdelegate verify(state, request, invocation), to: Redfish
end
