defmodule Skopos.Providers do
  use Ash.Domain,
    otp_app: :skopos

  resources do
    resource Skopos.Providers.Provider do
      define :list_providers, action: :read
      define :page_providers, action: :page
      define :page_provider_references, action: :reference_page
      define :page_provider_summaries, action: :management_page
      define :get_provider, action: :read, get_by: [:id]
      define :get_active_provider, action: :active, args: [:id]

      define :load_provider_for_invocation,
        action: :for_invocation,
        args: [:id, :expected_revision, :expected_kind]

      define :create_provider,
        action: :create,
        args: [:name, :kind, :adapter_type, :configuration, :credentials]

      define :update_provider, action: :update, args: [:expected_revision]
      define :check_provider, action: :check, args: [:id, :expected_revision, :input]

      define :target_capabilities,
        action: :target_capabilities,
        args: [:provider_id, :request, :invocation]

      define :check_target_connection,
        action: :target_check,
        args: [:provider_id, :request, :invocation]

      define :target_classify,
        action: :target_classify,
        args: [:provider_id, :request, :invocation]

      define :target_observe,
        action: :target_observe,
        args: [:provider_id, :request, :invocation]

      define :target_effect,
        action: :target_effect,
        args: [:provider_id, :request, :invocation]

      define :target_verify,
        action: :target_verify,
        args: [:provider_id, :request, :invocation]

      define :signal_ingest,
        action: :signal_ingest,
        args: [:provider_id, :expected_revision, :envelope, :invocation]

      define :inventory_snapshot,
        action: :inventory_snapshot,
        args: [:provider_id, :request, :invocation]

      define :notification_deliver,
        action: :notification_deliver,
        args: [:provider_id, :request, :invocation]

      define :ai_resolve,
        action: :ai_resolve,
        args: [:provider_id, :request, :invocation]

      define :ai_review,
        action: :ai_review,
        args: [:provider_id, :request, :invocation]

      define :ai_review_recovery,
        action: :ai_review_recovery,
        args: [:provider_id, :request, :invocation]

      define :record_provider_check,
        action: :record_check,
        args: [:expected_revision, :check_status, :check_category, :check_message]

      define :enable_provider, action: :enable, args: [:expected_revision]
      define :disable_provider, action: :disable, args: [:expected_revision]
      define :retire_ai_provider, action: :retire_ai, args: [:id, :expected_revision]
    end

    resource Skopos.Providers.AIUsageRoleAssignment do
      define :list_ai_usage_role_assignments, action: :read
      define :page_ai_usage_role_assignments, action: :page
      define :eligible_ai_usage_role_summaries, action: :eligibility_summary, args: [:role]
      define :get_ai_usage_role_assignment, action: :read, get_by: [:id]

      define :eligible_ai_usage_role_assignments,
        action: :eligible,
        args: [:role]

      define :load_current_ai_usage_role_assignment,
        action: :current_assignment,
        args: [:id, :role, :expected_assignment_revision, :expected_provider_revision]

      define :configure_ai_usage,
        action: :configure,
        args: [
          :provider_id,
          :scope,
          :priority,
          :expected_resolver_revision,
          :expected_reviewer_revision
        ]

      define :select_resolver_ai, action: :select_resolver

      define :select_reviewer_ai,
        action: :select_reviewer,
        args: [:excluded_provider_ids]
    end
  end
end
