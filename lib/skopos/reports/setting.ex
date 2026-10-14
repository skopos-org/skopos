defmodule Skopos.Reports.Setting do
  use Ash.Resource,
    otp_app: :skopos,
    domain: Skopos.Reports,
    authorizers: [Ash.Policy.Authorizer],
    data_layer: AshPostgres.DataLayer

  postgres do
    table "report_settings"
    repo Skopos.Repo
  end

  actions do
    defaults [:read]

    create :bootstrap do
      accept []
    end

    read :current do
      get? true
      filter expr(scope == "global")
    end

    update :configure do
      accept [:automatic_case_reports_enabled]

      argument :expected_revision, :integer, allow_nil?: false, constraints: [min: 1]

      validate Skopos.Validations.CurrentRevision

      change set_attribute(:changed_by_id, actor(:id))
      change optimistic_lock(:revision)
    end
  end

  policies do
    policy action(:bootstrap) do
      forbid_if always()
    end

    policy action(:configure) do
      authorize_if actor_attribute_equals(:role, :admin)
    end

    policy action([:read, :current]) do
      authorize_if actor_attribute_equals(:role, :admin)
      authorize_if actor_attribute_equals(:role, :operator)
      authorize_if actor_attribute_equals(:role, :viewer)
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :scope, :string do
      allow_nil? false
      default "global"
    end

    attribute :automatic_case_reports_enabled, :boolean do
      allow_nil? false
      public? true
      default true
    end

    attribute :revision, :integer do
      allow_nil? false
      public? true
      default 1
    end

    timestamps()
  end

  relationships do
    belongs_to :changed_by, Skopos.Accounts.User do
      public? true
    end
  end

  identities do
    identity :unique_scope, [:scope]
  end
end
