defmodule Skopos.Targets do
  use Ash.Domain,
    otp_app: :skopos

  resources do
    resource Skopos.Targets.ManagementBoundary do
      define :page_management_boundaries, action: :page
      define :get_management_boundary, action: :read, get_by: [:id]
      define :create_management_boundary, action: :create, args: [:name, :kind, :facts]
      define :update_management_boundary, action: :update, args: [:expected_revision]
      define :deactivate_management_boundary, action: :deactivate, args: [:expected_revision]
    end

    resource Skopos.Targets.Target do
      define :list_target_types, action: :type_catalog
      define :list_targets, action: :read
      define :page_targets, action: :page
      define :page_target_references, action: :reference_page
      define :page_target_summaries, action: :management_page
      define :get_target, action: :read, get_by: [:id]

      define :create_target,
        action: :create,
        args: [:name, :kind, :type_id, :facts, :management_boundary_id]

      define :update_target, action: :update, args: [:expected_revision]
      define :deactivate_target, action: :deactivate, args: [:expected_revision]
      define :search_targets, action: :search, args: [:query, :max_results]
    end

    resource Skopos.Targets.ExternalIdentity do
      define :list_external_identities, action: :read
      define :page_external_identities, action: :page
      define :get_external_identity, action: :read, get_by: [:id]
      define :external_identities_for_source, action: :for_source, args: [:source]

      define :resolve_external_identity,
        action: :resolve,
        args: [:source, :kind, :value]

      define :create_external_identity,
        action: :create,
        args: [:target_id, :source, :kind, :value]

      define :update_external_identity, action: :update, args: [:expected_revision]
      define :deactivate_external_identity, action: :deactivate, args: [:expected_revision]
    end

    resource Skopos.Targets.AccessMethod do
      define :page_access_methods, action: :page
      define :get_access_method, action: :read, get_by: [:id]

      define :available_access_methods_for_target,
        action: :available_for_target,
        args: [:target_id]

      define :create_access_method,
        action: :create,
        args: [
          :target_id,
          :provider_id,
          :name,
          :method,
          :endpoint,
          :provider_revision,
          :priority,
          :capabilities
        ]

      define :update_access_method, action: :update, args: [:expected_revision]
      define :deactivate_access_method, action: :deactivate, args: [:expected_revision]
      define :check_access_method, action: :check, args: [:id, :expected_revision, :invocation]

      define :begin_access_method_check,
        action: :begin_check,
        args: [:expected_revision, :attempt_id]

      define :record_access_method_check,
        action: :record_check,
        args: [
          :expected_revision,
          :attempt_id,
          :connection_revision,
          :target_revision,
          :status,
          :message,
          :capability_catalog
        ]

      define :available_access_methods,
        action: :available,
        args: [:target_id, :capability]

      define :load_access_method_for_use,
        action: :for_use,
        args: [:id, :expected_revision, :capability]
    end

    resource Skopos.Targets.Relationship do
      define :page_relationships, action: :page
      define :get_relationship, action: :read, get_by: [:id]

      define :create_relationship,
        action: :create,
        args: [:source_target_id, :destination_target_id, :kind, :facts, :valid_until]

      define :update_relationship, action: :update, args: [:expected_revision]
      define :deactivate_relationship, action: :deactivate, args: [:expected_revision]

      define :load_relationship_for_traversal,
        action: :for_traversal,
        args: [:id, :expected_revision]

      define :adjacent_relationships_for_traversal,
        action: :adjacent_for_traversal,
        args: [:target_id]

      define :adjacent_relationships_for_case_admission,
        action: :adjacent_for_case_admission,
        args: [:target_id]
    end

    resource Skopos.Targets.TargetRequest do
      define :clear_target_request, action: :clear_request, args: [:request]

      define :dispatch_target_observation,
        action: :dispatch_observation,
        args: [:clearance, :invocation]

      define :dispatch_target_effect,
        action: :dispatch_effect,
        args: [:clearance, :invocation]

      define :dispatch_target_verification,
        action: :dispatch_verification,
        args: [:clearance, :invocation]
    end

    resource Skopos.Targets.InventoryImport do
      define :page_inventory_imports, action: :page
      define :get_inventory_import, action: :read, get_by: [:id]
      define :create_inventory_import_preview, action: :create_preview

      define :mark_inventory_import_applied,
        action: :mark_applied,
        args: [:expected_revision]

      define :preview_manual_inventory,
        action: :preview_manual,
        args: [:source, :csv]

      define :preview_provider_inventory,
        action: :preview_inventory,
        args: [:source, :provider_id, :request, :invocation]

      define :apply_inventory_import,
        action: :apply,
        args: [:id, :expected_revision, :expected_digest]
    end

    resource Skopos.Targets.InventoryImportRow do
      define :list_inventory_import_rows, action: :read

      define :page_inventory_import_rows,
        action: :page_for_import,
        args: [:inventory_import_id]

      define :page_inventory_import_row_summaries,
        action: :summary_page,
        args: [:inventory_import_id]

      define :inventory_import_rows,
        action: :for_import,
        args: [:inventory_import_id]
    end

    resource Skopos.Targets.Artifact do
      define :get_artifact, action: :read, get_by: [:id]
      define :get_artifact_for_target, action: :for_target, args: [:id, :target_id]
      define :page_artifacts, action: :page, args: [:target_id]
      define :artifact_limits, action: :limits

      define :begin_artifact,
        action: :begin,
        args: [:target_id, :name, :media_type, :size_bytes, :expected_sha256, :upload_key]

      define :append_artifact_chunk, action: :append, args: [:id, :offset, :bytes]

      define :begin_artifact_receipt,
        action: :begin_receipt,
        args: [:target_id, :name, :media_type, :receipt_key]

      define :complete_artifact_receipt, action: :complete_receipt, args: [:id]
      define :complete_artifact, action: :complete, args: [:id]
      define :revoke_artifact, action: :revoke, args: [:id]
      define :expire_artifact, action: :expire, args: [:id]
      define :read_artifact_chunk, action: :chunk, args: [:id, :target_id, :offset]
      define :artifact_reference, action: :reference, args: [:id, :target_id]
      define :read_bound_artifact_chunk, action: :bound_chunk, args: [:reference, :offset]

      define :read_bound_artifact_range,
        action: :bound_range,
        args: [:reference, :offset, :length]

      define :create_artifact_record, action: :create_record
      define :record_artifact_state, action: :record_state

      define :artifact_by_upload,
        action: :by_upload,
        args: [:target_id, :uploaded_by_id, :upload_key]
    end

    resource Skopos.Targets.ArtifactChunk do
      define :create_artifact_chunk_record, action: :create_record
      define :artifact_chunk_at_offset, action: :at_offset, args: [:artifact_id, :offset]

      define :artifact_chunk_containing_offset,
        action: :containing_offset,
        args: [:artifact_id, :offset]
    end
  end
end
