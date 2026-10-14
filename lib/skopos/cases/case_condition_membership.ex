defmodule Skopos.Cases.CaseConditionMembership do
  use Ash.Resource,
    otp_app: :skopos,
    domain: Skopos.Cases,
    authorizers: [Ash.Policy.Authorizer],
    data_layer: AshPostgres.DataLayer

  postgres do
    table "case_condition_memberships"
    repo Skopos.Repo

    custom_indexes do
      index [:condition_id],
        unique: true,
        name: "case_condition_one_active_owner",
        where: "detached_at IS NULL"

      index [:case_id], where: "detached_at IS NULL"
    end
  end

  actions do
    defaults [:read]

    read :active_for_condition do
      get? true
      argument :condition_id, :uuid, allow_nil?: false
      filter expr(condition_id == ^arg(:condition_id) and is_nil(detached_at))
    end

    read :active_for_case do
      argument :case_id, :uuid, allow_nil?: false
      filter expr(case_id == ^arg(:case_id) and is_nil(detached_at))
      prepare build(sort: [attached_at: :asc, id: :asc])
    end

    read :page_history_for_case do
      argument :case_id, :uuid, allow_nil?: false
      filter expr(case_id == ^arg(:case_id))
      pagination keyset?: true, required?: true, default_limit: 100, max_page_size: 500

      prepare build(
                select: [:id, :case_id, :condition_id, :attached_at, :detached_at, :reason],
                sort: [attached_at: :desc, id: :desc]
              )
    end

    read :history_for_condition do
      argument :condition_id, :uuid, allow_nil?: false
      filter expr(condition_id == ^arg(:condition_id))
      prepare build(sort: [attached_at: :asc, id: :asc])
    end

    create :attach_record do
      accept [:case_id, :condition_id, :attached_at, :reason]
    end

    update :detach_record do
      accept [:detached_at, :reason]
      require_atomic? false
      argument :expected_revision, :integer, allow_nil?: false, constraints: [min: 1]
      filter expr(is_nil(detached_at))
      validate Skopos.Validations.CurrentRevision
      change optimistic_lock(:revision)
    end

    action :assign_signal, :map do
      transaction? false
      argument :condition_id, :uuid, allow_nil?: false
      argument :source, :string, allow_nil?: false
      argument :title, :string, allow_nil?: false
      argument :severity, :atom, allow_nil?: false
      argument :received_at, :utc_datetime_usec, allow_nil?: false
      argument :initial_context, :map, allow_nil?: false
      run Skopos.Cases.CaseConditionMembership.Actions.AssignSignal
    end
  end

  policies do
    policy action([
             :active_for_condition,
             :active_for_case,
             :history_for_condition,
             :attach_record,
             :detach_record,
             :assign_signal
           ]) do
      forbid_if always()
    end

    policy action([:read, :page_history_for_case]) do
      authorize_if actor_attribute_equals(:role, :admin)
      authorize_if actor_attribute_equals(:role, :operator)
      authorize_if actor_attribute_equals(:role, :viewer)
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :attached_at, :utc_datetime_usec do
      allow_nil? false
      public? true
    end

    attribute :detached_at, :utc_datetime_usec do
      public? true
    end

    attribute :reason, :string do
      allow_nil? false
      public? true
      constraints min_length: 1, max_length: 500
    end

    attribute :revision, :integer do
      allow_nil? false
      public? true
      default 1
      constraints min: 1
    end

    timestamps()
  end

  relationships do
    belongs_to :case, Skopos.Cases.Case do
      allow_nil? false
      public? true
    end

    belongs_to :condition, Skopos.Signals.Condition do
      allow_nil? false
      public? true
    end
  end
end
