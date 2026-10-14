defmodule Skopos.Cases.AIInvocation do
  alias Skopos.Providers.AI

  use Ash.Resource,
    otp_app: :skopos,
    domain: Skopos.Cases,
    authorizers: [Ash.Policy.Authorizer],
    data_layer: AshPostgres.DataLayer

  postgres do
    table "ai_invocations"
    repo Skopos.Repo

    custom_indexes do
      index [:case_id]
      index [:resolution_run_id]
      index [:turn_id]
      index [:proposal_id]
    end
  end

  actions do
    defaults [:read]

    read :page_for_case do
      argument :case_id, :uuid, allow_nil?: false
      filter expr(case_id == ^arg(:case_id))
      pagination keyset?: true, required?: true, default_limit: 100, max_page_size: 500
      prepare build(sort: [inserted_at: :desc, id: :desc], load: [:usage_status])
    end

    read :by_idempotency do
      get? true
      argument :idempotency_key, :string, allow_nil?: false
      filter expr(idempotency_key == ^arg(:idempotency_key))
    end

    create :create_record do
      accept [
        :case_id,
        :resolution_run_id,
        :turn_id,
        :proposal_id,
        :provider_id,
        :assignment_id,
        :role,
        :idempotency_key,
        :request_digest,
        :provider_revision,
        :assignment_revision,
        :selection_source,
        :reserved_units,
        :dispatch_started_at
      ]

      change set_attribute(:status, :dispatching)
      validate present(:dispatch_started_at)
      validate Skopos.Cases.AIInvocation.Validations.Subject
    end

    update :retry_unsent do
      accept []
      require_atomic? false
      argument :expected_revision, :integer, allow_nil?: false, constraints: [min: 1]
      argument :before_send_failure, :term, allow_nil?: false, sensitive?: true
      change set_attribute(:status, :queued)
      validate Skopos.Validations.CurrentRevision
      validate changing(:status, from: :dispatching)
      validate Skopos.Cases.AIInvocation.Validations.Unsent
      change set_attribute(:dispatch_started_at, nil)
      change set_attribute(:dispatch_confirmed, false)
      change optimistic_lock(:revision)
    end

    update :begin_dispatch do
      accept []
      require_atomic? false
      argument :expected_revision, :integer, allow_nil?: false, constraints: [min: 1]

      argument :request_digest, :string,
        allow_nil?: false,
        constraints: [min_length: 64, max_length: 64]

      argument :reserved_units, :integer, allow_nil?: false, constraints: [min: 1]
      change set_attribute(:status, :dispatching)
      change set_attribute(:request_digest, arg(:request_digest))
      change set_attribute(:reserved_units, arg(:reserved_units))
      validate Skopos.Validations.CurrentRevision
      validate changing(:status, from: :queued)
      change set_attribute(:dispatch_started_at, &DateTime.utc_now/0)
      change set_attribute(:dispatch_confirmed, nil)
      change optimistic_lock(:revision)
    end

    update :record_outcome do
      accept [
        :status,
        :category,
        :failure_code,
        :rejection_path,
        :result_digest,
        :completed_at
      ]

      require_atomic? false
      argument :usage, :struct, constraints: [instance_of: AI.Usage]
      argument :dispatched?, :boolean
      argument :expected_revision, :integer, allow_nil?: false, constraints: [min: 1]
      validate Skopos.Validations.CurrentRevision
      validate changing(:status, from: :dispatching)
      validate attribute_in(:status, [:completed, :failed, :unknown])
      validate present(:completed_at)
      change Skopos.Cases.AIInvocation.Changes.RecordUsage
      change optimistic_lock(:revision)
    end

    action :settle_stopped, :atom do
      transaction? false
      argument :case_id, :uuid, allow_nil?: false
      argument :resolution_run_id, :uuid, allow_nil?: false
      argument :role, :atom, allow_nil?: false, constraints: [one_of: [:resolver, :reviewer]]
      argument :turn_id, :uuid
      argument :proposal_id, :uuid
      run Skopos.Cases.AIInvocation.Actions.SettleStopped
    end

    action :claim, :struct do
      constraints instance_of: Skopos.Cases.AIInvocation.Claim
      transaction? false
      argument :role, :atom, allow_nil?: false, constraints: [one_of: [:resolver, :reviewer]]
      argument :case_id, :uuid, allow_nil?: false
      argument :expected_case_revision, :integer, allow_nil?: false, constraints: [min: 1]
      argument :resolution_run_id, :uuid, allow_nil?: false
      argument :turn_id, :uuid
      argument :expected_turn_revision, :integer, constraints: [min: 1]
      argument :proposal_id, :uuid
      argument :expected_proposal_revision, :integer, constraints: [min: 1]
      argument :provider_id, :uuid, allow_nil?: false
      argument :assignment_id, :uuid, allow_nil?: false
      argument :provider_revision, :integer, allow_nil?: false, constraints: [min: 1]
      argument :assignment_revision, :integer, allow_nil?: false, constraints: [min: 1]

      argument :selection_source, :atom,
        allow_nil?: false,
        constraints: [one_of: [:assignment]]

      argument :request_digest, :string,
        allow_nil?: false,
        constraints: [min_length: 64, max_length: 64]

      argument :request_size_bytes, :integer,
        allow_nil?: false,
        constraints: [min: 1, max: AI.max_input_bytes()]

      argument :delivery_attempt, :integer, constraints: [min: 1]

      argument :invocation_context, :struct,
        allow_nil?: false,
        constraints: [instance_of: Skopos.Cases.Case.InvocationContext]

      run Skopos.Cases.AIInvocation.Actions.Claim
    end
  end

  policies do
    policy action(:page_for_case) do
      authorize_if actor_attribute_equals(:role, :admin)
      authorize_if actor_attribute_equals(:role, :operator)
      authorize_if actor_attribute_equals(:role, :viewer)
    end

    policy action([
             :read,
             :by_idempotency,
             :create_record,
             :record_outcome,
             :retry_unsent,
             :begin_dispatch,
             :settle_stopped,
             :claim
           ]) do
      forbid_if always()
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :role, :atom,
      allow_nil?: false,
      public?: true,
      constraints: [one_of: [:resolver, :reviewer]]

    attribute :status, :atom,
      allow_nil?: false,
      public?: true,
      constraints: [one_of: [:queued, :dispatching, :completed, :failed, :unknown]]

    attribute :idempotency_key, :string,
      allow_nil?: false,
      constraints: [min_length: 1, max_length: 500]

    attribute :request_digest, :string,
      allow_nil?: false,
      constraints: [min_length: 64, max_length: 64]

    attribute :provider_revision, :integer, allow_nil?: false, constraints: [min: 1]
    attribute :assignment_revision, :integer, allow_nil?: false, constraints: [min: 1]

    attribute :selection_source, :atom,
      allow_nil?: false,
      constraints: [one_of: [:assignment]]

    attribute :reserved_units, :integer, allow_nil?: false, constraints: [min: 1]
    attribute :usage_reported, :boolean, allow_nil?: false, default: false
    attribute :dispatch_confirmed, :boolean
    attribute :input_tokens, :integer, allow_nil?: false, default: 0, constraints: [min: 0]
    attribute :output_tokens, :integer, allow_nil?: false, default: 0, constraints: [min: 0]
    attribute :cached_tokens, :integer, constraints: [min: 0]
    attribute :reasoning_tokens, :integer, constraints: [min: 0]
    attribute :finish_reason, :string, constraints: [min_length: 1, max_length: 40]
    attribute :category, :string, constraints: [min_length: 1, max_length: 120]
    attribute :failure_code, :string, constraints: [min_length: 1, max_length: 120]

    attribute :rejection_path, :string,
      constraints: [max_length: 200, length_count: :bytes, match: ~r/\A\//, trim?: false]

    attribute :result_digest, :string, constraints: [min_length: 64, max_length: 64]
    attribute :dispatch_started_at, :utc_datetime_usec
    attribute :completed_at, :utc_datetime_usec
    attribute :revision, :integer, allow_nil?: false, default: 1, constraints: [min: 1]
    timestamps()
  end

  relationships do
    belongs_to :case, Skopos.Cases.Case, allow_nil?: false
    belongs_to :resolution_run, Skopos.Cases.ResolutionRun, allow_nil?: false
    belongs_to :turn, Skopos.Cases.Turn
    belongs_to :proposal, Skopos.Cases.Proposal
    belongs_to :provider, Skopos.Providers.Provider, allow_nil?: false
    belongs_to :assignment, Skopos.Providers.AIUsageRoleAssignment, allow_nil?: false
  end

  calculations do
    calculate :usage_status,
              :atom,
              expr(
                cond do
                  status == :dispatching -> :pending
                  usage_reported -> :reported
                  dispatch_confirmed == false -> :not_dispatched
                  true -> :unknown
                end
              )
  end

  identities do
    identity :unique_idempotency, [:idempotency_key]
  end

  def usage_aggregates do
    [
      :ai_budget_charged_units,
      :ai_reported_input_tokens,
      :ai_reported_output_tokens,
      :ai_reported_invocations,
      :ai_unknown_invocations,
      :ai_pending_invocations,
      :ai_not_dispatched_invocations,
      :ai_unknown_reserved_units,
      :ai_pending_reserved_units
    ]
  end

  # A pure projection of already loaded resource aggregates; I/O and actor
  # admission remain in the Case reconnect action.
  def usage_summary(incident) do
    %{
      reported_input_tokens: incident.ai_reported_input_tokens,
      reported_output_tokens: incident.ai_reported_output_tokens,
      reported_total_tokens:
        incident.ai_reported_input_tokens + incident.ai_reported_output_tokens,
      reported_invocations: incident.ai_reported_invocations,
      unknown_invocations: incident.ai_unknown_invocations,
      pending_invocations: incident.ai_pending_invocations,
      not_dispatched_invocations: incident.ai_not_dispatched_invocations,
      budget_charged_units: incident.ai_budget_charged_units,
      unknown_reserved_units: incident.ai_unknown_reserved_units,
      pending_reserved_units: incident.ai_pending_reserved_units,
      complete: incident.ai_unknown_invocations == 0 and incident.ai_pending_invocations == 0
    }
  end

  def request_digest(request) do
    request
    |> :erlang.term_to_binary([:deterministic])
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  def rejection_path(error) do
    case AI.Error.find(error) do
      %AI.Error{failure_path: path} when is_binary(path) -> path
      _other -> nil
    end
  end

  def retry_context([]), do: nil

  def retry_context(failures) do
    latest = Enum.max_by(failures, & &1.completed_at, DateTime)

    context = %{
      "category" => "invalid_output",
      "rejection_code" => latest.failure_code || "invalid_output"
    }

    if latest.rejection_path,
      do: Map.put(context, "rejection_path", latest.rejection_path),
      else: context
  end

  def retryable_unsent?(error) do
    AI.Error.context_failure?(error) and
      match?(%AI.Error{dispatched?: false, usage: nil}, AI.Error.find(error))
  end

  def failure_accounting(error, reserved_units) do
    ai_error = AI.Error.find(error)

    usage =
      case ai_error do
        %AI.Error{usage: %AI.Usage{} = value} -> value
        _other -> nil
      end

    dispatched? = if match?(%AI.Error{}, ai_error), do: ai_error.dispatched?, else: nil

    failure_accounting(usage, dispatched?, reserved_units)
    |> Map.put(:ai_error, ai_error)
  end

  def failure_accounting(%AI.Usage{} = usage, _dispatched?, _reserved_units) do
    %{amount: usage.input_tokens + usage.output_tokens, usage: usage, dispatched?: true}
  end

  def failure_accounting(nil, true, reserved_units),
    do: %{amount: reserved_units, usage: nil, dispatched?: true}

  def failure_accounting(nil, dispatched?, _reserved_units),
    do: %{amount: 0, usage: nil, dispatched?: dispatched?}
end
