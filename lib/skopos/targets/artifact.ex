defmodule Skopos.Targets.Artifact do
  use Ash.Resource,
    otp_app: :skopos,
    domain: Skopos.Targets,
    authorizers: [Ash.Policy.Authorizer],
    data_layer: AshPostgres.DataLayer

  alias Skopos.Targets.Artifact.Actions.Lifecycle

  postgres do
    table "artifacts"
    repo Skopos.Repo
  end

  actions do
    defaults [:read]

    read :for_target do
      get? true
      argument :id, :uuid, allow_nil?: false
      argument :target_id, :uuid, allow_nil?: false
      filter expr(id == ^arg(:id) and target_id == ^arg(:target_id))
    end

    read :page do
      argument :target_id, :uuid, allow_nil?: false
      filter expr(target_id == ^arg(:target_id))
      pagination keyset?: true, required?: true, default_limit: 50, max_page_size: 100
      prepare build(sort: [inserted_at: :desc, id: :desc])
    end

    read :by_upload do
      get? true
      argument :target_id, :uuid, allow_nil?: false
      argument :uploaded_by_id, :uuid, allow_nil?: false
      argument :upload_key, :string, allow_nil?: false, sensitive?: true

      filter expr(
               target_id == ^arg(:target_id) and uploaded_by_id == ^arg(:uploaded_by_id) and
                 upload_key == ^arg(:upload_key)
             )
    end

    action :limits, :map do
      run {Lifecycle, operation: :limits}
    end

    action :begin, :struct do
      constraints instance_of: __MODULE__
      transaction? false
      argument :target_id, :uuid, allow_nil?: false
      argument :name, :string, allow_nil?: false, constraints: [min_length: 1, max_length: 255]

      argument :media_type, :string,
        allow_nil?: false,
        constraints: [min_length: 1, max_length: 256, match: ~r/\A[^\r\n]+\z/]

      argument :size_bytes, :integer, allow_nil?: false, constraints: [min: 0]

      argument :expected_sha256, :string,
        allow_nil?: false,
        constraints: [match: ~r/\A[0-9a-f]{64}\z/]

      argument :upload_key, :string,
        allow_nil?: false,
        sensitive?: true,
        constraints: [min_length: 1, max_length: 120]

      run {Lifecycle, operation: :begin}
    end

    action :append, :struct do
      constraints instance_of: __MODULE__
      transaction? false
      argument :id, :uuid, allow_nil?: false
      argument :offset, :integer, allow_nil?: false, constraints: [min: 0]
      argument :bytes, :binary, allow_nil?: false, sensitive?: true
      run {Lifecycle, operation: :append}
    end

    action :begin_receipt, :struct do
      constraints instance_of: __MODULE__
      transaction? false
      argument :target_id, :uuid, allow_nil?: false
      argument :name, :string, allow_nil?: false, constraints: [min_length: 1, max_length: 255]

      argument :media_type, :string,
        allow_nil?: false,
        constraints: [min_length: 1, max_length: 256, match: ~r/\A[^\r\n]+\z/]

      argument :receipt_key, :string,
        allow_nil?: false,
        sensitive?: true,
        constraints: [min_length: 1, max_length: 120]

      argument :request_id, :string

      run {Lifecycle, operation: :begin_receipt}
    end

    action :complete_receipt, :struct do
      constraints instance_of: __MODULE__
      transaction? false
      argument :id, :uuid, allow_nil?: false
      argument :expected_size_bytes, :integer, constraints: [min: 0]
      argument :expected_sha256, :string, constraints: [match: ~r/\A[0-9a-f]{64}\z/]

      argument :completion_reason, :atom,
        allow_nil?: false,
        default: :eof,
        constraints: [one_of: [:eof, :byte_limit, :duration_limit, :event_limit, :entry_limit]]

      run {Lifecycle, operation: :complete_receipt}
    end

    action :complete, :struct do
      constraints instance_of: __MODULE__
      transaction? false
      argument :id, :uuid, allow_nil?: false
      run {Lifecycle, operation: :complete}
    end

    action :chunk, :binary do
      transaction? false
      argument :id, :uuid, allow_nil?: false
      argument :target_id, :uuid, allow_nil?: false
      argument :offset, :integer, allow_nil?: false, constraints: [min: 0]
      run {Lifecycle, operation: :chunk}
    end

    action :reference, :map do
      transaction? false
      argument :id, :uuid, allow_nil?: false
      argument :target_id, :uuid, allow_nil?: false
      run {Lifecycle, operation: :reference}
    end

    action :bound_chunk, :binary do
      transaction? false
      argument :reference, :map, allow_nil?: false, sensitive?: true
      argument :offset, :integer, allow_nil?: false, constraints: [min: 0]
      run {Lifecycle, operation: :bound_chunk}
    end

    action :bound_range, :binary do
      transaction? false
      argument :reference, :map, allow_nil?: false, sensitive?: true
      argument :offset, :integer, allow_nil?: false, constraints: [min: 0]
      argument :length, :integer, allow_nil?: false, constraints: [min: 0]
      run {Lifecycle, operation: :bound_range}
    end

    action :revoke, :struct do
      constraints instance_of: __MODULE__
      transaction? false
      argument :id, :uuid, allow_nil?: false
      run {Lifecycle, operation: :revoke}
    end

    action :expire, :struct do
      constraints instance_of: __MODULE__
      transaction? false
      argument :id, :uuid, allow_nil?: false
      run {Lifecycle, operation: :expire}
    end

    create :create_record do
      accept [
        :target_id,
        :uploaded_by_id,
        :name,
        :media_type,
        :size_bytes,
        :expected_sha256,
        :upload_key,
        :request_id,
        :status,
        :expires_at
      ]
    end

    update :record_state do
      accept [:received_bytes, :status, :sha256, :size_bytes, :completion_reason]
      change optimistic_lock(:revision)
    end
  end

  policies do
    policy action([:create_record, :record_state, :by_upload, :expire]) do
      forbid_if always()
    end

    policy action([
             :read,
             :for_target,
             :page,
             :limits,
             :begin,
             :begin_receipt,
             :append,
             :complete,
             :complete_receipt,
             :chunk,
             :reference,
             :bound_chunk,
             :bound_range,
             :revoke
           ]) do
      authorize_if actor_attribute_equals(:role, :admin)
      authorize_if actor_attribute_equals(:role, :operator)
    end

    policy action([:read, :for_target, :page]) do
      authorize_if actor_attribute_equals(:role, :admin)
      authorize_if relates_to_actor_via(:uploaded_by)
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :name, :string, allow_nil?: false, public?: true
    attribute :media_type, :string, allow_nil?: false, public?: true
    attribute :size_bytes, :integer, public?: true, constraints: [min: 0]

    attribute :received_bytes, :integer,
      allow_nil?: false,
      public?: true,
      default: 0,
      constraints: [min: 0]

    attribute :expected_sha256, :string, public?: true
    attribute :sha256, :string, public?: true
    attribute :upload_key, :string, allow_nil?: false, sensitive?: true
    attribute :request_id, :string, public?: true

    attribute :completion_reason, :atom,
      public?: true,
      constraints: [
        one_of: [:upload, :eof, :byte_limit, :duration_limit, :event_limit, :entry_limit]
      ]

    attribute :expires_at, :utc_datetime_usec, allow_nil?: false, public?: true

    attribute :status, :atom,
      allow_nil?: false,
      public?: true,
      default: :uploading,
      constraints: [one_of: [:uploading, :receiving, :ready, :revoked, :expired]]

    attribute :revision, :integer,
      allow_nil?: false,
      public?: true,
      default: 1,
      constraints: [min: 1]

    timestamps()
  end

  relationships do
    belongs_to :target, Skopos.Targets.Target, allow_nil?: false, public?: true
    belongs_to :uploaded_by, Skopos.Accounts.User, allow_nil?: false
  end

  identities do
    identity :unique_upload, [:target_id, :uploaded_by_id, :upload_key]
  end
end
