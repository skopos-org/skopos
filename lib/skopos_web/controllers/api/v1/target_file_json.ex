defmodule SkoposWeb.API.V1.TargetFileJSON do
  @moduledoc false

  def file(artifact) do
    Map.take(artifact, [
      :id,
      :target_id,
      :request_id,
      :completion_reason,
      :name,
      :media_type,
      :size_bytes,
      :received_bytes,
      :expected_sha256,
      :sha256,
      :status,
      :revision,
      :expires_at,
      :inserted_at,
      :updated_at
    ])
  end
end
