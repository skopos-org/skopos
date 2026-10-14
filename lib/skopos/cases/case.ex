defmodule Skopos.Cases.Case do
  use Ash.Resource,
    otp_app: :skopos,
    domain: Skopos.Cases,
    authorizers: [Ash.Policy.Authorizer],
    simple_notifiers: [Skopos.Cases.Case.RealtimeNotifier],
    data_layer: AshPostgres.DataLayer

  @summary_fields ~w(id title status report_language revision initial_target_id selected_target_id inserted_at updated_at)a

  def summary_fields, do: @summary_fields

  postgres do
    table "cases"
    repo Skopos.Repo

    identity_wheres_to_sql unique_trigger: "trigger_kind <> 'signal'",
                           one_active_signal_trigger:
                             "trigger_kind = 'signal' AND status IN ('running', 'needs_attention')"

    custom_indexes do
      index [:authority_setting_id]
      index [:split_parent_id]
      index [:initial_target_id]
      index [:selected_target_id]
      index [:current_owner_id]
    end

    check_constraints do
      check_constraint [:selected_target_id, :selected_target_revision],
                       "cases_selected_target_pair",
                       check:
                         "(selected_target_id IS NULL AND selected_target_revision IS NULL) OR " <>
                           "(selected_target_id IS NOT NULL AND selected_target_revision IS NOT NULL)",
                       message: "must be set together"
    end
  end

  actions do
    defaults [:read]

    action :invocation_context_current, :boolean do
      transaction? false

      argument :invocation_context, :struct,
        allow_nil?: false,
        constraints: [instance_of: Skopos.Cases.Case.InvocationContext]

      run Skopos.Cases.Case.Actions.InvocationContextCurrent
    end

    read :report_period do
      pagination keyset?: true, required?: true, default_limit: 100, max_page_size: 100
      argument :from, :utc_datetime_usec, allow_nil?: false
      argument :to, :utc_datetime_usec, allow_nil?: false
      argument :target_id, :uuid

      filter expr(
               inserted_at >= ^arg(:from) and inserted_at < ^arg(:to) and
                 (is_nil(^arg(:target_id)) or selected_target_id == ^arg(:target_id) or
                    (is_nil(selected_target_id) and initial_target_id == ^arg(:target_id)))
             )

      prepare build(sort: [inserted_at: :asc, id: :asc])
    end

    read :page do
      pagination keyset?: true, required?: true, default_limit: 50, max_page_size: 100

      argument :query, :ci_string, constraints: [min_length: 1, max_length: 200]

      argument :status, :atom,
        constraints: [one_of: [:running, :needs_attention, :resolved, :cancelled]]

      argument :sort, :atom,
        allow_nil?: false,
        default: :updated_desc,
        constraints: [one_of: [:updated_desc, :updated_asc, :severity_desc]]

      prepare Skopos.Cases.Case.Preparations.Queue
    end

    read :summaries do
      pagination keyset?: true, required?: true, default_limit: 50, max_page_size: 100
      argument :ids, {:array, :uuid}, constraints: [min_length: 1, max_length: 100]
      argument :query, :ci_string, constraints: [min_length: 1, max_length: 200]

      argument :status, :atom,
        constraints: [one_of: [:running, :needs_attention, :resolved, :cancelled]]

      argument :sort, :atom,
        allow_nil?: false,
        default: :updated_desc,
        constraints: [one_of: [:updated_desc, :updated_asc, :severity_desc]]

      prepare {Skopos.Cases.Case.Preparations.Queue, summary?: true}
    end

    read :by_trigger do
      get? true
      argument :trigger_kind, :atom, allow_nil?: false
      argument :source, :string, allow_nil?: false
      argument :source_ref, :string, allow_nil?: false

      filter expr(
               trigger_kind == ^arg(:trigger_kind) and source == ^arg(:source) and
                 source_ref == ^arg(:source_ref)
             )
    end

    read :active_by_trigger do
      get? true
      argument :source, :string, allow_nil?: false
      argument :source_ref, :string, allow_nil?: false

      filter expr(
               trigger_kind == :signal and source == ^arg(:source) and
                 source_ref == ^arg(:source_ref) and status in [:running, :needs_attention]
             )
    end

    read :running_signals_without_target do
      filter expr(
               trigger_kind == :signal and status == :running and
                 is_nil(selected_target_id) and
                 exists(condition_memberships, is_nil(detached_at) and condition.state == :firing)
             )

      prepare build(sort: [inserted_at: :asc, id: :asc])
    end

    read :waiting_for_external_identity do
      argument :source, :string, allow_nil?: false
      argument :kind, :string, allow_nil?: false
      argument :value, :string, allow_nil?: false

      filter expr(
               trigger_kind == :signal and status == :needs_attention and
                 is_nil(selected_target_id) and source == ^arg(:source) and
                 get_path(pending_intent, ["action"]) == "provide_human_input" and
                 get_path(initial_context, ["target_ref", "kind"]) == ^arg(:kind) and
                 get_path(initial_context, ["target_ref", "value"]) == ^arg(:value) and
                 exists(condition_memberships, is_nil(detached_at) and condition.state == :firing)
             )

      prepare build(sort: [inserted_at: :asc, id: :asc])
    end

    create :create_record do
      accept [
        :trigger_kind,
        :source,
        :source_ref,
        :title,
        :severity,
        :report_language,
        :status,
        :initial_context,
        :authority_setting_id,
        :authority_setting_revision,
        :authority_mode,
        :max_elapsed_seconds,
        :max_resolver_turns,
        :max_target_requests,
        :max_effects,
        :max_related_targets,
        :max_ai_usage_units,
        :max_no_progress_turns,
        :cancel_requested,
        :pending_intent,
        :stop_reason,
        :required_human_input,
        :initial_target_id,
        :split_parent_id,
        :recovery_baseline_at,
        :selected_target_id,
        :selected_target_revision,
        :current_owner_id
      ]

      validate {Skopos.Validations.BoundedMap, attribute: :initial_context}
      validate {Skopos.Validations.BoundedMap, attribute: :pending_intent}
    end

    update :record_owner do
      accept []
      require_atomic? false
      argument :expected_revision, :integer, allow_nil?: false, constraints: [min: 1]
      argument :owner_id, :uuid, allow_nil?: false
      validate Skopos.Validations.CurrentRevision
      validate attribute_in(:status, [:running, :needs_attention])
      change set_attribute(:current_owner_id, arg(:owner_id))
      change optimistic_lock(:revision)
    end

    update :record_selected_target do
      accept []
      require_atomic? false
      argument :expected_revision, :integer, allow_nil?: false, constraints: [min: 1]
      argument :target_id, :uuid, allow_nil?: false
      argument :target_revision, :integer, allow_nil?: false, constraints: [min: 1]
      validate Skopos.Validations.CurrentRevision
      validate attribute_equals(:status, :running)
      validate attribute_equals(:cancel_requested, false)
      change set_attribute(:selected_target_id, arg(:target_id))
      change set_attribute(:selected_target_revision, arg(:target_revision))
      change optimistic_lock(:revision)
    end

    update :record_pending_intent do
      accept []
      require_atomic? false
      argument :expected_revision, :integer, allow_nil?: false, constraints: [min: 1]
      argument :pending_intent, :map, allow_nil?: false
      validate Skopos.Validations.CurrentRevision
      validate attribute_equals(:status, :running)
      validate attribute_equals(:cancel_requested, false)
      validate {Skopos.Validations.BoundedMap, argument: :pending_intent}
      change set_attribute(:pending_intent, arg(:pending_intent))
      change set_attribute(:stop_reason, nil)
      change set_attribute(:required_human_input, nil)
      change optimistic_lock(:revision)
    end

    update :record_cancellation do
      accept []
      require_atomic? false
      argument :expected_revision, :integer, allow_nil?: false, constraints: [min: 1]
      validate Skopos.Validations.CurrentRevision
      validate attribute_in(:status, [:running, :needs_attention])
      change set_attribute(:status, :cancelled)
      change set_attribute(:cancel_requested, true)
      change set_attribute(:stop_reason, "Resolution cancelled by an operator")
      change set_attribute(:pending_intent, %{})
      change set_attribute(:required_human_input, nil)
      change optimistic_lock(:revision)
    end

    update :record_attention do
      accept []
      require_atomic? false
      argument :expected_revision, :integer, allow_nil?: false, constraints: [min: 1]
      argument :reason, :string, allow_nil?: false, constraints: [min_length: 1, max_length: 500]
      argument :pending_intent, :map, allow_nil?: false

      argument :required_human_input, :string,
        allow_nil?: false,
        constraints: [min_length: 1, max_length: 1_000]

      validate Skopos.Validations.CurrentRevision
      validate attribute_in(:status, [:running, :needs_attention])
      validate attribute_equals(:cancel_requested, false)
      validate {Skopos.Validations.BoundedMap, argument: :pending_intent}
      change set_attribute(:status, :needs_attention)
      change set_attribute(:stop_reason, arg(:reason))
      change set_attribute(:pending_intent, arg(:pending_intent))
      change set_attribute(:required_human_input, arg(:required_human_input))
      change optimistic_lock(:revision)
    end

    update :record_resume do
      accept [
        :authority_mode,
        :max_elapsed_seconds,
        :max_resolver_turns,
        :max_target_requests,
        :max_effects,
        :max_related_targets,
        :max_ai_usage_units,
        :max_no_progress_turns,
        :current_owner_id,
        :selected_target_id,
        :selected_target_revision
      ]

      require_atomic? false
      argument :expected_revision, :integer, allow_nil?: false, constraints: [min: 1]
      validate Skopos.Validations.CurrentRevision
      validate attribute_equals(:status, :needs_attention)
      change set_attribute(:status, :running)
      change set_attribute(:cancel_requested, false)
      change set_attribute(:stop_reason, nil)
      change set_attribute(:pending_intent, %{})
      change set_attribute(:required_human_input, nil)
      change optimistic_lock(:revision)
    end

    update :record_resolution do
      accept []
      require_atomic? false
      argument :expected_revision, :integer, allow_nil?: false, constraints: [min: 1]
      argument :resolved_at, :utc_datetime_usec, allow_nil?: false
      validate Skopos.Validations.CurrentRevision
      validate attribute_equals(:status, :running)
      validate attribute_equals(:cancel_requested, false)
      change set_attribute(:status, :resolved)
      change set_attribute(:resolved_at, arg(:resolved_at))
      change set_attribute(:pending_intent, %{})
      change set_attribute(:stop_reason, nil)
      change set_attribute(:required_human_input, nil)
      change optimistic_lock(:revision)
    end

    update :record_split_reallocation do
      accept [
        :max_resolver_turns,
        :max_target_requests,
        :max_effects,
        :max_related_targets,
        :max_ai_usage_units,
        :selected_target_id,
        :selected_target_revision
      ]

      require_atomic? false
      argument :expected_revision, :integer, allow_nil?: false, constraints: [min: 1]
      argument :turn_count, :integer, allow_nil?: false, constraints: [min: 0]
      argument :ai_usage_units, :integer, allow_nil?: false, constraints: [min: 0]
      validate Skopos.Validations.CurrentRevision
      validate attribute_equals(:status, :running)
      validate attribute_equals(:cancel_requested, false)
      change Skopos.Cases.Case.Changes.SplitReallocation
      change optimistic_lock(:revision)
    end

    update :mark_budget_exhausted do
      accept []
      require_atomic? false

      argument :expected_revision, :integer, allow_nil?: false, constraints: [min: 1]
      argument :resolution_run_id, :uuid, allow_nil?: false
      argument :expected_run_revision, :integer, allow_nil?: false, constraints: [min: 1]
      argument :reason, :string, allow_nil?: false, constraints: [min_length: 1, max_length: 500]
      argument :limit, :atom, allow_nil?: false
      argument :kind, :atom, allow_nil?: false
      argument :amount, :integer, allow_nil?: false, constraints: [min: 1]
      argument :ledger_key, :string, allow_nil?: false, constraints: [min_length: 1]
      argument :pending_intent, :map, allow_nil?: false
      argument :event_data, :map, allow_nil?: false

      argument :required_human_input, :string,
        allow_nil?: false,
        constraints: [min_length: 1, max_length: 1_000]

      validate Skopos.Validations.CurrentRevision
      validate attribute_equals(:status, :running)
      validate attribute_equals(:cancel_requested, false)
      validate {Skopos.Validations.BoundedMap, argument: :pending_intent}

      change set_attribute(:status, :needs_attention)
      change set_attribute(:stop_reason, arg(:reason))
      change set_attribute(:pending_intent, arg(:pending_intent))
      change set_attribute(:required_human_input, arg(:required_human_input))
      change optimistic_lock(:revision)
      change Skopos.Cases.Case.Changes.BudgetExhaustion
    end

    update :queue_resolver_turn do
      accept []
      require_atomic? false
      argument :expected_revision, :integer, allow_nil?: false, constraints: [min: 1]
      argument :source_turn_id, :uuid, allow_nil?: false
      argument :next_turn_id, :uuid, allow_nil?: false
      validate Skopos.Validations.CurrentRevision
      validate attribute_equals(:status, :running)
      validate attribute_equals(:cancel_requested, false)
      change Skopos.Cases.Case.Changes.QueueResolverTurn
      change optimistic_lock(:revision)
    end

    update :handoff_operation do
      accept []
      require_atomic? false
      argument :expected_revision, :integer, allow_nil?: false, constraints: [min: 1]
      argument :operation_id, :uuid, allow_nil?: false

      argument :kind, :atom,
        allow_nil?: false,
        constraints: [one_of: [:verification, :resolver, :stale_dispatch]]

      argument :next_turn_id, :uuid
      argument :source_turn_id, :uuid
      argument :evidence_id, :uuid
      validate Skopos.Validations.CurrentRevision
      validate attribute_equals(:status, :running)
      validate attribute_equals(:cancel_requested, false)
      change Skopos.Cases.Case.Changes.OperationHandoff
      change optimistic_lock(:revision)
    end

    update :handoff_verification do
      accept []
      require_atomic? false
      argument :expected_revision, :integer, allow_nil?: false, constraints: [min: 1]
      argument :verification_attempt_id, :uuid, allow_nil?: false
      argument :verification_evidence_id, :uuid, allow_nil?: false

      argument :kind, :atom,
        allow_nil?: false,
        constraints: [one_of: [:evaluate, :resolve_turn]]

      argument :next_turn_id, :uuid
      validate Skopos.Validations.CurrentRevision
      validate attribute_equals(:status, :running)
      validate attribute_equals(:cancel_requested, false)
      change Skopos.Cases.Case.Changes.VerificationHandoff
      change optimistic_lock(:revision)
    end

    update :handoff_proposal do
      accept []
      require_atomic? false
      argument :expected_revision, :integer, allow_nil?: false, constraints: [min: 1]
      argument :proposal_id, :uuid, allow_nil?: false

      argument :kind, :atom,
        allow_nil?: false,
        constraints: [one_of: [:review, :human, :dispatch, :continue, :clear]]

      argument :reference_id, :uuid
      validate Skopos.Validations.CurrentRevision
      validate attribute_equals(:status, :running)
      validate attribute_equals(:cancel_requested, false)
      change Skopos.Cases.Case.Changes.ProposalHandoff
      change optimistic_lock(:revision)
    end

    action :open, :struct do
      constraints instance_of: __MODULE__
      transaction? false

      argument :trigger_kind, :atom,
        allow_nil?: false,
        constraints: [one_of: [:manual, :signal, :audit]]

      argument :source, :string,
        allow_nil?: false,
        constraints: [min_length: 1, max_length: 120]

      argument :source_ref, :string,
        allow_nil?: false,
        constraints: [min_length: 1, max_length: 500]

      argument :title, :string,
        allow_nil?: false,
        constraints: [min_length: 1, max_length: 200]

      argument :severity, :atom,
        allow_nil?: false,
        constraints: [one_of: [:info, :warning, :error, :critical]]

      argument :report_language, :atom, constraints: [one_of: [:en, :ja]]

      argument :initial_context, :map, allow_nil?: false, default: %{}
      argument :initial_target_id, :uuid

      run {Skopos.Cases.Case.Actions.Open, []}
    end

    action :reconnect, :struct do
      constraints instance_of: Skopos.Cases.Case.ReconnectSnapshot
      transaction? false
      argument :id, :uuid, allow_nil?: false
      run Skopos.Cases.Case.Actions.Reconnect
    end

    action :split_conditions, :struct do
      constraints instance_of: __MODULE__
      transaction? false
      argument :id, :uuid, allow_nil?: false
      argument :expected_revision, :integer, allow_nil?: false, constraints: [min: 1]

      argument :condition_ids, {:array, :uuid},
        allow_nil?: false,
        constraints: [min_length: 1, max_length: 31]

      argument :expected_conditions, {:array, :map},
        allow_nil?: false,
        constraints: [min_length: 2, max_length: 32]

      argument :reason, :string,
        allow_nil?: false,
        constraints: [min_length: 1, max_length: 500]

      argument :source_turn_id, :uuid

      run Skopos.Cases.Case.Actions.SplitConditions
    end

    action :claim, :struct do
      constraints instance_of: __MODULE__
      transaction? false
      argument :id, :uuid, allow_nil?: false
      argument :expected_revision, :integer, allow_nil?: false, constraints: [min: 1]
      run {Skopos.Cases.Case.Actions.Lifecycle, operation: :claim}
    end

    action :handoff, :struct do
      constraints instance_of: __MODULE__
      transaction? false
      argument :id, :uuid, allow_nil?: false
      argument :expected_revision, :integer, allow_nil?: false, constraints: [min: 1]
      argument :owner_id, :uuid, allow_nil?: false
      run {Skopos.Cases.Case.Actions.Lifecycle, operation: :handoff}
    end

    action :request_cancellation, :struct do
      constraints instance_of: __MODULE__
      transaction? false
      argument :id, :uuid, allow_nil?: false
      argument :expected_revision, :integer, allow_nil?: false, constraints: [min: 1]
      run {Skopos.Cases.Case.Actions.Lifecycle, operation: :request_cancellation}
    end

    action :reconcile_verified_effect, :struct do
      constraints instance_of: __MODULE__
      transaction? false
      argument :id, :uuid, allow_nil?: false
      argument :verification_attempt_id, :uuid, allow_nil?: false
      run Skopos.Cases.Case.Actions.VerifiedEffectRecovery
    end

    action :continue_after_verification, :boolean do
      transaction? false
      argument :id, :uuid, allow_nil?: false
      argument :verification_attempt_id, :uuid, allow_nil?: false
      run Skopos.Cases.Case.Actions.ContinueAfterVerification
    end

    action :recheck_signal_conditions, :map do
      transaction? false
      argument :id, :uuid, allow_nil?: false
      run Skopos.Cases.Case.Actions.RecheckSignalConditions
    end

    action :require_attention, :struct do
      constraints instance_of: __MODULE__
      transaction? false
      argument :id, :uuid, allow_nil?: false
      argument :expected_revision, :integer, allow_nil?: false, constraints: [min: 1]
      argument :resolution_run_id, :uuid, allow_nil?: false
      argument :expected_run_revision, :integer, allow_nil?: false, constraints: [min: 1]

      argument :idempotency_key, :string,
        allow_nil?: false,
        constraints: [min_length: 1, max_length: 500]

      argument :reason, :string,
        allow_nil?: false,
        constraints: [min_length: 1, max_length: 500]

      argument :pending_intent, :map, allow_nil?: false, default: %{}

      argument :required_human_input, :string, constraints: [min_length: 1, max_length: 1_000]

      run {Skopos.Cases.Case.Actions.Lifecycle, operation: :require_attention}
    end

    action :resume, :struct do
      constraints instance_of: Skopos.Cases.ResolutionRun
      transaction? false
      argument :id, :uuid, allow_nil?: false
      argument :expected_case_revision, :integer, allow_nil?: false, constraints: [min: 1]
      argument :resolution_run_id, :uuid, allow_nil?: false
      argument :expected_run_revision, :integer, allow_nil?: false, constraints: [min: 1]

      argument :authority_mode, :atom,
        allow_nil?: false,
        constraints: [one_of: [:readonly, :ask, :auto, :full_access]]

      argument :max_elapsed_seconds, :integer,
        allow_nil?: false,
        constraints: [min: 60, max: 2_592_000]

      argument :max_resolver_turns, :integer,
        allow_nil?: false,
        constraints: [min: 1, max: 1_000]

      argument :max_target_requests, :integer,
        allow_nil?: false,
        constraints: [min: 1, max: 10_000]

      argument :max_effects, :integer,
        allow_nil?: false,
        constraints: [min: 0, max: 1_000]

      argument :max_related_targets, :integer,
        allow_nil?: false,
        constraints: [min: 0, max: 1_000]

      argument :max_ai_usage_units, :integer,
        allow_nil?: false,
        constraints: [min: 1, max: 1_000_000_000]

      argument :max_no_progress_turns, :integer,
        allow_nil?: false,
        constraints: [min: 1, max: 100]

      argument :reason, :string,
        allow_nil?: false,
        constraints: [min_length: 1, max_length: 500]

      run {Skopos.Cases.Case.Actions.Lifecycle, operation: :resume}
    end

    action :resume_after_target_registration, :struct do
      constraints instance_of: Skopos.Cases.ResolutionRun
      transaction? false
      argument :id, :uuid, allow_nil?: false
      argument :external_identity_id, :uuid, allow_nil?: false

      argument :expected_identity_revision, :integer,
        allow_nil?: false,
        constraints: [min: 1]

      run {Skopos.Cases.Case.Actions.Lifecycle, operation: :resume_after_target_registration}
    end

    action :search_targets, :struct do
      constraints instance_of: Skopos.Cases.ResolutionRun.BudgetResult
      transaction? false
      argument :id, :uuid, allow_nil?: false
      argument :resolution_run_id, :uuid, allow_nil?: false

      argument :idempotency_key, :string,
        allow_nil?: false,
        constraints: [min_length: 1, max_length: 500]

      argument :query, :string,
        allow_nil?: false,
        constraints: [min_length: 1, max_length: Skopos.Targets.SearchQuery.max_codepoints()]

      argument :max_results, :integer,
        allow_nil?: false,
        default: 20,
        constraints: [min: 1, max: 50]

      argument :pending_intent, :map, allow_nil?: false

      argument :required_human_input, :string,
        allow_nil?: false,
        constraints: [min_length: 1, max_length: 1_000]

      run Skopos.Cases.Case.Actions.TargetSearch
    end

    action :select_target, :struct do
      constraints instance_of: __MODULE__
      transaction? false
      argument :id, :uuid, allow_nil?: false
      argument :expected_revision, :integer, allow_nil?: false, constraints: [min: 1]
      argument :resolution_run_id, :uuid, allow_nil?: false

      argument :evidence_ids, {:array, :uuid},
        allow_nil?: false,
        constraints: [min_length: 1, max_length: 100]

      argument :target_id, :uuid, allow_nil?: false
      argument :target_revision, :integer, allow_nil?: false, constraints: [min: 1]

      argument :reason, :string,
        allow_nil?: false,
        constraints: [min_length: 1, max_length: 500]

      argument :idempotency_key, :string,
        allow_nil?: false,
        constraints: [min_length: 1, max_length: 500]

      run Skopos.Cases.Case.Actions.TargetSelection
    end

    action :route_target_discovery, :struct do
      constraints instance_of: Skopos.Cases.ResolutionRun.BudgetResult
      transaction? false
      argument :turn_id, :uuid, allow_nil?: false
      run Skopos.Cases.Case.Actions.TargetDiscoveryRoute
    end

    action :route_related_target, :struct do
      constraints instance_of: Skopos.Cases.ResolutionRun.BudgetResult
      transaction? false
      argument :turn_id, :uuid, allow_nil?: false
      run Skopos.Cases.Case.Actions.RelatedTargetRoute
    end

    action :route_downstream_decision, :struct do
      constraints instance_of: __MODULE__
      transaction? false
      argument :turn_id, :uuid, allow_nil?: false
      run Skopos.Cases.Case.Actions.DownstreamDecisionRoute
    end

    action :route_resolver_decision, :map do
      transaction? false
      argument :turn_id, :uuid, allow_nil?: false
      run Skopos.Cases.Case.Actions.DecisionRoute
    end

    action :route_resolver_failure, :boolean do
      transaction? false
      argument :turn_id, :uuid, allow_nil?: false
      argument :category, :string, allow_nil?: false
      argument :rejection_code, :string
      argument :rejection_path, :string
      run Skopos.Cases.Case.Actions.ResolverFailureRoute
    end
  end

  policies do
    policy action([
             :open,
             :split_conditions,
             :claim,
             :handoff,
             :request_cancellation,
             :resume,
             :search_targets,
             :select_target
           ]) do
      authorize_if actor_attribute_equals(:role, :admin)
      authorize_if actor_attribute_equals(:role, :operator)
    end

    policy action([
             :by_trigger,
             :invocation_context_current,
             :active_by_trigger,
             :unresolved_signals_without_target,
             :create_record,
             :record_owner,
             :record_selected_target,
             :record_pending_intent,
             :record_cancellation,
             :record_attention,
             :record_resume,
             :record_resolution,
             :record_split_reallocation,
             :mark_budget_exhausted,
             :queue_resolver_turn,
             :handoff_operation,
             :handoff_verification,
             :handoff_proposal,
             :require_attention,
             :reconcile_verified_effect,
             :continue_after_verification,
             :recheck_signal_conditions,
             :resume_after_target_registration,
             :route_target_discovery,
             :route_related_target,
             :route_downstream_decision,
             :route_resolver_decision,
             :route_resolver_failure
           ]) do
      forbid_if always()
    end

    policy action([:read, :page, :summaries, :report_period, :reconnect]) do
      authorize_if actor_attribute_equals(:role, :admin)
      authorize_if actor_attribute_equals(:role, :operator)
      authorize_if actor_attribute_equals(:role, :viewer)
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :trigger_kind, :atom do
      allow_nil? false
      public? true
      constraints one_of: [:manual, :signal, :audit]
    end

    attribute :source, :string do
      allow_nil? false
      public? true
      constraints min_length: 1, max_length: 120
    end

    attribute :source_ref, :string do
      allow_nil? false
      public? true
      constraints min_length: 1, max_length: 500
    end

    attribute :title, :string do
      allow_nil? false
      public? true
      constraints min_length: 1, max_length: 200
    end

    attribute :severity, :atom do
      allow_nil? false
      public? true
      constraints one_of: [:info, :warning, :error, :critical]
    end

    attribute :report_language, :atom do
      allow_nil? false
      public? true
      default :en
      constraints one_of: [:en, :ja]
    end

    attribute :status, :atom do
      allow_nil? false
      public? true
      constraints one_of: [:running, :needs_attention, :resolved, :cancelled]
    end

    attribute :initial_context, :map do
      allow_nil? false
      public? true
      default %{}
    end

    attribute :authority_setting_revision, :integer do
      allow_nil? false
      public? true
      constraints min: 1
    end

    attribute :authority_mode, :atom do
      allow_nil? false
      public? true
      constraints one_of: [:readonly, :ask, :auto, :full_access]
    end

    attribute :max_elapsed_seconds, :integer do
      allow_nil? false
      public? true
      constraints min: 60, max: 2_592_000
    end

    attribute :max_resolver_turns, :integer do
      allow_nil? false
      public? true
      constraints min: 0, max: 1_000
    end

    attribute :max_target_requests, :integer do
      allow_nil? false
      public? true
      constraints min: 0, max: 10_000
    end

    attribute :max_effects, :integer do
      allow_nil? false
      public? true
      constraints min: 0, max: 1_000
    end

    attribute :max_related_targets, :integer do
      allow_nil? false
      public? true
      constraints min: 0, max: 1_000
    end

    attribute :max_ai_usage_units, :integer do
      allow_nil? false
      public? true
      constraints min: 0, max: 1_000_000_000
    end

    attribute :max_no_progress_turns, :integer do
      allow_nil? false
      public? true
      constraints min: 1, max: 100
    end

    attribute :cancel_requested, :boolean do
      allow_nil? false
      public? true
      default false
    end

    attribute :stop_reason, :string do
      public? true
      constraints max_length: 500
    end

    attribute :pending_intent, :map do
      allow_nil? false
      public? true
      default %{}
    end

    attribute :required_human_input, :string do
      public? true
      constraints max_length: 1_000
    end

    attribute :resolved_at, :utc_datetime_usec do
      public? true
    end

    attribute :recovery_baseline_at, :utc_datetime_usec do
      public? false
    end

    attribute :revision, :integer do
      allow_nil? false
      public? true
      default 1
      constraints min: 1
    end

    attribute :selected_target_revision, :integer do
      public? true
      constraints min: 1
    end

    timestamps()
  end

  relationships do
    belongs_to :split_parent, Skopos.Cases.Case do
      public? true
    end

    belongs_to :authority_setting, Skopos.Cases.AuthoritySetting do
      allow_nil? false
      public? true
    end

    belongs_to :initial_target, Skopos.Targets.Target do
      public? true
    end

    belongs_to :selected_target, Skopos.Targets.Target do
      public? true
    end

    belongs_to :current_owner, Skopos.Accounts.User do
      public? true
    end

    has_many :resolution_runs, Skopos.Cases.ResolutionRun
    has_many :ai_invocations, Skopos.Cases.AIInvocation
    has_many :condition_memberships, Skopos.Cases.CaseConditionMembership
    has_many :events, Skopos.Cases.CaseEvent
    has_many :reports, Skopos.Reports.Report
  end

  calculations do
    calculate :severity_rank,
              :integer,
              expr(
                cond do
                  severity == :critical -> 4
                  severity == :error -> 3
                  severity == :warning -> 2
                  true -> 1
                end
              )
  end

  aggregates do
    sum :ai_budget_charged_units, :resolution_runs, :ai_usage_units do
      default 0
    end

    for field <- [:input_tokens, :output_tokens] do
      sum :"ai_reported_#{field}", :ai_invocations, field do
        authorize? false
        default 0
        filter expr(usage_status == :reported)
      end
    end

    for status <- [:reported, :unknown, :pending, :not_dispatched] do
      count :"ai_#{status}_invocations", :ai_invocations do
        authorize? false
        filter expr(usage_status == ^status)
      end
    end

    for status <- [:unknown, :pending] do
      sum :"ai_#{status}_reserved_units", :ai_invocations, :reserved_units do
        authorize? false
        default 0
        filter expr(usage_status == ^status)
      end
    end

    count :condition_count, :condition_memberships do
      filter expr(is_nil(detached_at))
    end

    count :firing_condition_count, :condition_memberships do
      filter expr(is_nil(detached_at) and condition.state == :firing)
    end
  end

  identities do
    identity :unique_trigger, [:trigger_kind, :source, :source_ref] do
      where expr(trigger_kind != :signal)
    end

    identity :one_active_signal_trigger, [:trigger_kind, :source, :source_ref] do
      where expr(trigger_kind == :signal and status in [:running, :needs_attention])
    end
  end
end
