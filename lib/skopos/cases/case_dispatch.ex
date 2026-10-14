defmodule Skopos.Cases.CaseDispatch do
  use Ash.Resource,
    otp_app: :skopos,
    domain: Skopos.Cases,
    authorizers: [Ash.Policy.Authorizer],
    data_layer: AshPostgres.DataLayer

  postgres do
    table "case_dispatches"
    repo Skopos.Repo
  end

  actions do
    defaults [:read]

    read :for_case do
      get? true
      argument :case_id, :uuid, allow_nil?: false
      filter expr(case_id == ^arg(:case_id))
    end

    read :admitting do
      filter expr(state in [:collecting, :disabled])
      prepare build(sort: [first_received_at: :asc, id: :asc])
    end

    create :create_record do
      accept [:case_id, :state, :first_received_at, :due_at, :anchor_target_id]
    end

    update :record_state do
      accept [:state]
      require_atomic? false
      argument :expected_revision, :integer, allow_nil?: false, constraints: [min: 1]
      validate Skopos.Validations.CurrentRevision
      change optimistic_lock(:revision)
    end

    action :send_initial, :map do
      transaction? false
      argument :case_id, :uuid, allow_nil?: false
      run Skopos.Cases.CaseDispatch.Actions.SendInitial
    end
  end

  policies do
    policy action([:for_case, :admitting, :create_record, :record_state, :send_initial]) do
      forbid_if always()
    end

    policy action(:read) do
      authorize_if actor_attribute_equals(:role, :admin)
      authorize_if actor_attribute_equals(:role, :operator)
      authorize_if actor_attribute_equals(:role, :viewer)
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :state, :atom do
      allow_nil? false
      public? true
      constraints one_of: [:collecting, :sent, :disabled]
    end

    attribute :first_received_at, :utc_datetime_usec do
      allow_nil? false
      public? true
    end

    attribute :due_at, :utc_datetime_usec do
      allow_nil? false
      public? true
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

    belongs_to :anchor_target, Skopos.Targets.Target do
      public? true
    end
  end

  identities do
    identity :one_dispatch_per_case, [:case_id]
  end
end
