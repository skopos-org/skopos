defmodule SkoposWeb.API.V1.TargetSchemas do
  @moduledoc false

  alias OpenApiSpex.Schema
  alias SkoposWeb.API.Schemas

  def components do
    %{
      "ManagementBoundary" => management_boundary(),
      "ManagementBoundaryResponse" => Schemas.data(ref("ManagementBoundary")),
      "ManagementBoundarySummary" =>
        resource(%{name: string(1, 120), kind: string(1, 80), active: %Schema{type: :boolean}}, [
          :name,
          :kind,
          :active
        ]),
      "ManagementBoundaryPage" => Schemas.page(ref("ManagementBoundarySummary")),
      "CreateManagementBoundaryRequest" => create_management_boundary_request(),
      "UpdateManagementBoundaryRequest" => update_management_boundary_request(),
      "DeactivateManagementBoundaryRequest" => deactivate_request(:management_boundary),
      "Target" => target(),
      "TargetCategory" => target_category(),
      "TargetType" => target_type(),
      "TargetMethodType" => target_method_type(),
      "TargetTypeCatalog" => target_type_catalog(),
      "TargetTypeCatalogResponse" => Schemas.data(ref("TargetTypeCatalog")),
      "TargetResponse" => Schemas.data(ref("Target")),
      "TargetPage" => Schemas.page(ref("Target")),
      "TargetReference" =>
        object(
          %{
            id: Schemas.uuid(),
            name: string(1, 120),
            kind: string(1, 80),
            type_id: string(1, 120),
            active: %Schema{type: :boolean},
            revision: positive_integer(),
            management_boundary_id: %Schema{type: :string, format: :uuid, nullable: true}
          },
          [:id, :name, :kind, :type_id, :active, :revision, :management_boundary_id],
          false
        ),
      "TargetReferencePage" => Schemas.page(ref("TargetReference")),
      "TargetSummary" =>
        object(
          %{
            id: Schemas.uuid(),
            name: string(1, 120),
            kind: string(1, 80),
            type_id: string(1, 120),
            active: %Schema{type: :boolean},
            revision: positive_integer(),
            management_boundary_id: %Schema{type: :string, format: :uuid, nullable: true},
            method_count: %Schema{type: :integer, minimum: 0},
            relationship_count: %Schema{type: :integer, minimum: 0},
            has_operating_instructions: %Schema{type: :boolean},
            methods: %Schema{type: :array, items: ref("AccessMethodSummary"), maxItems: 2}
          },
          [
            :id,
            :name,
            :kind,
            :type_id,
            :active,
            :revision,
            :management_boundary_id,
            :method_count,
            :relationship_count,
            :has_operating_instructions,
            :methods
          ],
          false
        ),
      "TargetSummaryPage" => Schemas.page(ref("TargetSummary")),
      "AccessMethodSummary" =>
        object(
          %{
            id: Schemas.uuid(),
            target_id: Schemas.uuid(),
            method: string(1, 120),
            endpoint: string(1, 1024),
            priority: %Schema{type: :integer, minimum: 0, maximum: 10000}
          },
          [:id, :target_id, :method, :endpoint, :priority],
          false
        ),
      "CreateTargetRequest" => create_target_request(),
      "UpdateTargetRequest" => update_target_request(),
      "DeactivateTargetRequest" => deactivate_request(:target),
      "ExternalIdentity" => external_identity(),
      "ExternalIdentityResponse" => Schemas.data(ref("ExternalIdentity")),
      "ExternalIdentityPage" => Schemas.page(ref("ExternalIdentity")),
      "CreateExternalIdentityRequest" => create_external_identity_request(),
      "UpdateExternalIdentityRequest" => update_external_identity_request(),
      "DeactivateExternalIdentityRequest" => deactivate_request(:external_identity),
      "AccessMethod" => access_method(),
      "AccessMethodResponse" => Schemas.data(ref("AccessMethod")),
      "AccessMethodPage" => Schemas.page(ref("AccessMethod")),
      "CreateAccessMethodRequest" => create_access_method_request(),
      "UpdateAccessMethodRequest" => update_access_method_request(),
      "CheckAccessMethodRequest" => deactivate_request(:access_method),
      "DeactivateAccessMethodRequest" => deactivate_request(:access_method),
      "TargetRelationship" => relationship(),
      "TargetRelationshipResponse" => Schemas.data(ref("TargetRelationship")),
      "TargetRelationshipPage" => Schemas.page(ref("TargetRelationship")),
      "CreateTargetRelationshipRequest" => create_relationship_request(),
      "UpdateTargetRelationshipRequest" => update_relationship_request(),
      "DeactivateTargetRelationshipRequest" => deactivate_request(:relationship)
    }
  end

  def ref(name), do: Schemas.reference(name)

  def reference_page_parameters do
    Schemas.pagination_parameters() ++
      [
        Schemas.reference_ids_parameter(),
        {:active, [in: :query, schema: %Schema{type: :boolean}]},
        {:exclude_id, [in: :query, schema: Schemas.uuid()]}
      ]
  end

  def management_page_parameters do
    Schemas.pagination_parameters() ++
      [
        {:target_id, [in: :query, schema: Schemas.uuid()]},
        {:active, [in: :query, schema: %Schema{type: :boolean}]}
      ]
  end

  def summary_page_parameters do
    Schemas.pagination_parameters() ++
      [
        Schemas.reference_ids_parameter(),
        {:active, [in: :query, schema: %Schema{type: :boolean}]},
        {:query, [in: :query, schema: string(0, Skopos.Targets.SearchQuery.max_codepoints())]}
      ]
  end

  defp management_boundary do
    resource(
      %{
        name: string(1, 120),
        kind: string(1, 80),
        facts: map(),
        active: %Schema{type: :boolean}
      },
      [:name, :kind, :facts, :active]
    )
  end

  defp create_management_boundary_request do
    wrapped(:management_boundary, %{name: string(1, 120), kind: string(1, 80), facts: map()}, [
      :name,
      :kind
    ])
  end

  defp update_management_boundary_request do
    update_request(:management_boundary, %{
      name: string(1, 120),
      kind: string(1, 80),
      facts: map()
    })
  end

  defp target do
    resource(
      %{
        name: string(1, 120),
        kind: string(1, 80),
        type_id: string(1, 120),
        facts: map(),
        operating_instructions: string(0, 4_000),
        management_boundary_id: nullable_uuid(),
        active: %Schema{type: :boolean}
      },
      [:name, :kind, :type_id, :facts, :operating_instructions, :management_boundary_id, :active]
    )
  end

  defp target_category do
    %Schema{
      type: :object,
      properties: %{id: string(1, 80), label: string(1, 120)},
      required: [:id, :label],
      additionalProperties: false
    }
  end

  defp target_type do
    %Schema{
      type: :object,
      properties: %{
        id: string(1, 120),
        label: string(1, 120),
        category_id: string(1, 80),
        kind: string(1, 80),
        access_method_types: %Schema{type: :array, items: string(1, 120)}
      },
      required: [:id, :label, :category_id, :kind, :access_method_types],
      additionalProperties: false
    }
  end

  defp target_type_catalog do
    %Schema{
      type: :object,
      properties: %{
        categories: %Schema{type: :array, items: ref("TargetCategory")},
        types: %Schema{type: :array, items: ref("TargetType")},
        methods: %Schema{type: :array, items: ref("TargetMethodType")}
      },
      required: [:categories, :types, :methods],
      additionalProperties: false
    }
  end

  defp target_method_type do
    object(
      %{
        adapter_type: string(1, 120),
        label: string(1, 120),
        protocol: %Schema{
          type: :string,
          enum: ~w(ssh http netconf restconf redfish ipmi kubernetes)
        }
      },
      [:adapter_type, :label, :protocol]
    )
  end

  defp create_target_request do
    wrapped(
      :target,
      %{
        name: string(1, 120),
        kind: string(1, 80),
        type_id: string(1, 120),
        facts: map(),
        management_boundary_id: nullable_uuid()
      },
      [:name, :kind, :type_id]
    )
  end

  defp update_target_request do
    update_request(:target, %{
      name: string(1, 120),
      kind: string(1, 80),
      type_id: string(1, 120),
      facts: map(),
      operating_instructions: string(0, 4_000),
      management_boundary_id: nullable_uuid()
    })
  end

  defp external_identity do
    resource(
      %{
        target_id: Schemas.uuid(),
        source: string(1, 120),
        kind: string(1, 80),
        value: string(1, 500),
        active: %Schema{type: :boolean}
      },
      [:target_id, :source, :kind, :value, :active]
    )
  end

  defp create_external_identity_request do
    wrapped(
      :external_identity,
      %{
        target_id: Schemas.uuid(),
        source: string(1, 120),
        kind: string(1, 80),
        value: string(1, 500)
      },
      [:target_id, :source, :kind, :value]
    )
  end

  defp update_external_identity_request do
    update_request(:external_identity, %{
      target_id: Schemas.uuid(),
      source: string(1, 120),
      kind: string(1, 80),
      value: string(1, 500)
    })
  end

  defp access_method do
    resource(
      %{
        target_id: Schemas.uuid(),
        provider_id: Schemas.uuid(),
        name: string(1, 120),
        method: string(1, 120),
        endpoint: string(1, 1_024),
        provider_revision: positive_integer(),
        priority: priority(),
        capabilities: string_array(100, 120),
        check:
          object(
            %{
              current: %Schema{type: :boolean},
              status: %Schema{
                type: :string,
                enum: ["checking", "passed", "failed"],
                nullable: true
              },
              message: %Schema{type: :string, nullable: true, maxLength: 500},
              checked_at: nullable_timestamp(),
              checked_target_revision: %Schema{type: :integer, minimum: 1, nullable: true},
              observed_capabilities: string_array(100, 120)
            },
            [
              :current,
              :status,
              :message,
              :checked_at,
              :checked_target_revision,
              :observed_capabilities
            ],
            false
          ),
        active: %Schema{type: :boolean}
      },
      [
        :target_id,
        :provider_id,
        :name,
        :method,
        :endpoint,
        :provider_revision,
        :priority,
        :capabilities,
        :check,
        :active
      ]
    )
  end

  defp create_access_method_request do
    wrapped(
      :access_method,
      %{
        target_id: Schemas.uuid(),
        provider_id: Schemas.uuid(),
        name: string(1, 120),
        method: string(1, 120),
        endpoint: string(1, 1_024),
        provider_revision: positive_integer(),
        priority: priority(),
        capabilities: string_array(100, 120)
      },
      [:target_id, :provider_id, :name, :method, :endpoint, :provider_revision]
    )
  end

  defp update_access_method_request do
    update_request(:access_method, %{
      target_id: Schemas.uuid(),
      provider_id: Schemas.uuid(),
      name: string(1, 120),
      method: string(1, 120),
      endpoint: string(1, 1_024),
      provider_revision: positive_integer(),
      priority: priority(),
      capabilities: string_array(100, 120)
    })
  end

  defp relationship do
    resource(
      %{
        source_target_id: Schemas.uuid(),
        destination_target_id: Schemas.uuid(),
        kind: string(1, 120),
        facts: map(),
        valid_until: nullable_timestamp(),
        active: %Schema{type: :boolean}
      },
      [:source_target_id, :destination_target_id, :kind, :facts, :valid_until, :active]
    )
  end

  defp create_relationship_request do
    wrapped(
      :relationship,
      %{
        source_target_id: Schemas.uuid(),
        destination_target_id: Schemas.uuid(),
        kind: string(1, 120),
        facts: map(),
        valid_until: nullable_timestamp()
      },
      [:source_target_id, :destination_target_id, :kind]
    )
  end

  defp update_relationship_request do
    update_request(:relationship, %{
      source_target_id: Schemas.uuid(),
      destination_target_id: Schemas.uuid(),
      kind: string(1, 120),
      facts: map(),
      valid_until: nullable_timestamp()
    })
  end

  defp resource(properties, required) do
    object(
      Map.merge(
        %{
          id: Schemas.uuid(),
          revision: positive_integer(),
          inserted_at: Schemas.timestamp(),
          updated_at: Schemas.timestamp()
        },
        properties
      ),
      [:id, :revision, :inserted_at, :updated_at | required],
      false
    )
  end

  defp wrapped(name, properties, required) do
    object(%{name => object(properties, required)}, [name])
  end

  defp update_request(name, properties) do
    wrapped(
      name,
      Map.put(properties, :expected_revision, positive_integer()),
      [:expected_revision]
    )
    |> put_in([Access.key(:properties), name, Access.key(:minProperties)], 2)
  end

  defp deactivate_request(name) do
    wrapped(name, %{expected_revision: positive_integer()}, [:expected_revision])
  end

  defp string_array(max_items, max_length) do
    %Schema{
      type: :array,
      maxItems: max_items,
      items: string(1, max_length)
    }
  end

  defp string(min_length, max_length) do
    %Schema{type: :string, minLength: min_length, maxLength: max_length}
  end

  defp priority, do: %Schema{type: :integer, minimum: 0, maximum: 10_000}
  defp positive_integer, do: %Schema{type: :integer, minimum: 1}
  defp map, do: %Schema{type: :object, additionalProperties: true}
  defp nullable_uuid, do: %Schema{type: :string, format: :uuid, nullable: true}
  defp nullable_timestamp, do: %Schema{type: :string, format: :"date-time", nullable: true}

  defp object(properties, required, additional_properties \\ nil) do
    %Schema{
      type: :object,
      properties: properties,
      required: required,
      additionalProperties: additional_properties
    }
  end
end
