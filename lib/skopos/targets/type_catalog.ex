defmodule Skopos.Targets.TypeCatalog do
  @moduledoc false

  @methods [
    %{adapter_type: "ssh", label: "SSH", protocol: "ssh"},
    %{adapter_type: "http-api", label: "HTTP API", protocol: "http"},
    %{adapter_type: "netconf", label: "NETCONF", protocol: "netconf"},
    %{adapter_type: "restconf", label: "RESTCONF", protocol: "restconf"},
    %{adapter_type: "redfish", label: "Redfish", protocol: "redfish"},
    %{adapter_type: "ipmi", label: "IPMI (RMCP+)", protocol: "ipmi"},
    %{adapter_type: "kubernetes-api", label: "Kubernetes API", protocol: "kubernetes"},
    %{adapter_type: "linux-ssh", label: "Linux SSH", protocol: "ssh"},
    %{adapter_type: "ios-xe-ssh", label: "Cisco IOS XE SSH/CLI", protocol: "ssh"},
    %{adapter_type: "ios-xe-netconf", label: "Cisco IOS XE NETCONF", protocol: "netconf"},
    %{adapter_type: "ios-xe-restconf", label: "Cisco IOS XE RESTCONF", protocol: "restconf"},
    %{adapter_type: "hpe-ilo-redfish", label: "HPE iLO Redfish", protocol: "redfish"},
    %{adapter_type: "hpe-ilo-ipmi", label: "HPE iLO IPMI", protocol: "ipmi"},
    %{adapter_type: "dell-idrac-redfish", label: "Dell iDRAC Redfish", protocol: "redfish"},
    %{adapter_type: "dell-idrac-ipmi", label: "Dell iDRAC IPMI", protocol: "ipmi"}
  ]

  @categories [
    %{id: "physical-server", label: "Physical server"},
    %{id: "network-device", label: "Network device"},
    %{id: "os", label: "Operating system"},
    %{id: "virtualization", label: "Virtualization"},
    %{id: "workload-platform", label: "Workload platform"},
    %{id: "storage", label: "Storage"},
    %{id: "data-service", label: "Data service"},
    %{id: "application-service", label: "Application / infrastructure service"},
    %{id: "power-facility", label: "Power / facility"}
  ]

  @types [
    %{
      id: "custom-bmc",
      label: "Custom BMC",
      category_id: "physical-server",
      kind: "management_plane",
      access_method_types: ["redfish", "ipmi"]
    },
    %{
      id: "hpe-ilo",
      label: "HPE iLO",
      category_id: "physical-server",
      kind: "management_plane",
      access_method_types: ["redfish", "ipmi", "hpe-ilo-redfish", "hpe-ilo-ipmi"]
    },
    %{
      id: "dell-idrac",
      label: "Dell iDRAC",
      category_id: "physical-server",
      kind: "management_plane",
      access_method_types: ["redfish", "ipmi", "dell-idrac-redfish", "dell-idrac-ipmi"]
    },
    %{
      id: "custom-physical-server",
      label: "Custom physical server",
      category_id: "physical-server",
      kind: "physical_host",
      access_method_types: ["ssh", "http-api"]
    },
    %{
      id: "cisco_ios_xe",
      label: "Cisco IOS XE",
      category_id: "network-device",
      kind: "network_device",
      access_method_types: [
        "ios-xe-ssh",
        "ios-xe-netconf",
        "ios-xe-restconf",
        "netconf",
        "restconf",
        "ssh",
        "http-api"
      ]
    },
    %{
      id: "custom-network-device",
      label: "Custom network device",
      category_id: "network-device",
      kind: "network_device",
      access_method_types: ["ssh", "netconf", "restconf", "http-api"]
    },
    %{
      id: "linux",
      label: "Linux",
      category_id: "os",
      kind: "host",
      access_method_types: ["linux-ssh", "ssh", "http-api"]
    },
    %{
      id: "custom-os",
      label: "Custom operating system",
      category_id: "os",
      kind: "host",
      access_method_types: ["ssh", "http-api"]
    },
    %{
      id: "custom-virtualization",
      label: "Custom virtualization platform",
      category_id: "virtualization",
      kind: "hypervisor",
      access_method_types: ["ssh", "http-api"]
    },
    %{
      id: "custom-vm",
      label: "Custom virtual machine",
      category_id: "virtualization",
      kind: "virtual_machine",
      access_method_types: ["ssh", "http-api"]
    },
    %{
      id: "kubernetes",
      label: "Kubernetes",
      category_id: "workload-platform",
      kind: "cluster",
      access_method_types: ["kubernetes-api"]
    }
  ]

  def snapshot, do: %{categories: @categories, types: @types, methods: @methods}
  def fetch(id) when is_binary(id), do: Enum.find(@types, &(&1.id == id))
  def fetch(_id), do: nil

  def allows_method?(type_id, adapter_type) do
    case fetch(type_id) do
      %{access_method_types: allowed} -> adapter_type in allowed
      nil -> false
    end
  end
end
