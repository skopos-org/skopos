defmodule Skopos.Targets.RedfishURITest do
  use ExUnit.Case, async: true

  alias Skopos.Targets.Adapters.RedfishURI

  @origin "https://bmc.example.test:8443"

  test "accepts only Redfish paths on the checked HTTPS origin" do
    assert {:ok, "/redfish/v1/Chassis/1"} =
             RedfishURI.from_link(@origin, @origin <> "/redfish/v1/Chassis/1")

    assert {:ok, "/redfish/v1/Chassis?$skip=2"} =
             RedfishURI.from_link(@origin, "?$skip=2", "/redfish/v1/Chassis?$skip=1")

    assert {:error, :invalid_resource_uri} =
             RedfishURI.from_link(@origin, "https://other.example/redfish/v1/Chassis")

    assert {:error, :invalid_resource_uri} =
             RedfishURI.from_link(@origin, "https://bmc.example.test/redfish/v1/Chassis")

    assert {:error, :invalid_resource_uri} =
             RedfishURI.relative("//other.example/redfish/v1/Chassis")

    assert {:error, :invalid_resource_uri} =
             RedfishURI.relative("/redfish/v1/%252e%252e/SessionService")

    assert {:error, :invalid_resource_uri} =
             RedfishURI.relative("/redfish/v1/%2f../SessionService")
  end
end
