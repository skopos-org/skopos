defmodule Skopos.Targets.ArtifactChunk do
  use Ash.Resource,
    otp_app: :skopos,
    domain: Skopos.Targets,
    extensions: [AshCloak],
    authorizers: [Ash.Policy.Authorizer],
    data_layer: AshPostgres.DataLayer

  cloak do
    vault(Skopos.Vault)
    attributes([:bytes])
  end

  postgres do
    table "artifact_chunks"
    repo Skopos.Repo
  end

  actions do
    defaults [:read, :destroy]

    create :create_record do
      accept [:artifact_id, :offset, :size_bytes, :sha256, :bytes]
    end

    read :at_offset do
      get? true
      argument :artifact_id, :uuid, allow_nil?: false
      argument :offset, :integer, allow_nil?: false, constraints: [min: 0]
      filter expr(artifact_id == ^arg(:artifact_id) and offset == ^arg(:offset))
    end

    read :containing_offset do
      get? true
      argument :artifact_id, :uuid, allow_nil?: false
      argument :offset, :integer, allow_nil?: false, constraints: [min: 0]

      filter expr(
               artifact_id == ^arg(:artifact_id) and offset <= ^arg(:offset) and
                 offset + size_bytes > ^arg(:offset)
             )
    end
  end

  policies do
    policy always() do
      forbid_if always()
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :offset, :integer, allow_nil?: false, constraints: [min: 0]
    attribute :size_bytes, :integer, allow_nil?: false, constraints: [min: 1]
    attribute :sha256, :string, allow_nil?: false

    attribute :bytes, :binary do
      allow_nil? false
      sensitive? true
    end
  end

  relationships do
    belongs_to :artifact, Skopos.Targets.Artifact do
      allow_nil? false
    end
  end

  identities do
    identity :unique_offset, [:artifact_id, :offset]
  end
end
