defmodule SkoposWeb.API.V1.TargetSetupJSON do
  @moduledoc false

  def boundary(boundary) do
    %{
      id: boundary.id,
      name: boundary.name,
      kind: boundary.kind,
      facts: boundary.facts,
      active: boundary.active,
      revision: boundary.revision,
      inserted_at: boundary.inserted_at,
      updated_at: boundary.updated_at
    }
  end

  def target(target) do
    %{
      id: target.id,
      name: target.name,
      kind: target.kind,
      type_id: target.type_id,
      facts: target.facts,
      operating_instructions: target.operating_instructions,
      management_boundary_id: target.management_boundary_id,
      active: target.active,
      revision: target.revision,
      inserted_at: target.inserted_at,
      updated_at: target.updated_at
    }
  end

  def identity(identity) do
    %{
      id: identity.id,
      target_id: identity.target_id,
      source: identity.source,
      kind: identity.kind,
      value: identity.value,
      active: identity.active,
      revision: identity.revision,
      inserted_at: identity.inserted_at,
      updated_at: identity.updated_at
    }
  end

  def target_summary(target) do
    target
    |> Map.take(Skopos.Targets.Target.management_fields())
    |> Map.put(
      :methods,
      Enum.map(
        target.access_methods,
        &Map.take(&1, Skopos.Targets.AccessMethod.management_fields())
      )
    )
  end

  def access_method(method) do
    %{
      id: method.id,
      target_id: method.target_id,
      provider_id: method.provider_id,
      name: method.name,
      method: method.method,
      endpoint: method.endpoint,
      provider_revision: method.provider_revision,
      priority: method.priority,
      capabilities: method.capabilities,
      check: %{
        current: method.check_current,
        status: method.check_status,
        message: method.check_message,
        checked_at: method.checked_at,
        checked_target_revision: method.checked_target_revision,
        observed_capabilities: method.observed_capabilities
      },
      active: method.active,
      revision: method.revision,
      inserted_at: method.inserted_at,
      updated_at: method.updated_at
    }
  end

  def relationship(relationship) do
    %{
      id: relationship.id,
      source_target_id: relationship.source_target_id,
      destination_target_id: relationship.destination_target_id,
      kind: relationship.kind,
      facts: relationship.facts,
      valid_until: relationship.valid_until,
      active: relationship.active,
      revision: relationship.revision,
      inserted_at: relationship.inserted_at,
      updated_at: relationship.updated_at
    }
  end
end
