defmodule SkoposWeb.API.V1.TargetFileSchemas do
  @moduledoc false

  alias OpenApiSpex.Schema
  alias SkoposWeb.API.Schemas

  def components do
    %{
      "TargetFile" => file(),
      "TargetFileResponse" => Schemas.data(Schemas.reference("TargetFile")),
      "TargetFilePage" => Schemas.page(Schemas.reference("TargetFile")),
      "TargetFileLimitsResponse" =>
        Schemas.data(
          object(%{
            chunk_bytes: %Schema{type: :integer, minimum: 1},
            max_size_bytes: %Schema{type: :integer, minimum: 0},
            lifetime_seconds: %Schema{type: :integer, minimum: 1}
          })
        ),
      "CreateTargetFileRequest" =>
        object(%{
          file:
            object(%{
              name: %Schema{type: :string, minLength: 1, maxLength: 255},
              media_type: %Schema{
                type: :string,
                minLength: 1,
                maxLength: 256,
                pattern: "^[^\\r\\n]+$"
              },
              size_bytes: %Schema{type: :integer, minimum: 0},
              expected_sha256: %Schema{type: :string, pattern: "^[0-9a-f]{64}$"},
              upload_key: %Schema{type: :string, minLength: 1, maxLength: 120}
            })
        })
    }
  end

  defp file do
    object(%{
      id: Schemas.uuid(),
      target_id: Schemas.uuid(),
      request_id: %Schema{type: :string, nullable: true},
      completion_reason: %Schema{
        type: :string,
        nullable: true,
        enum: ~w(upload eof byte_limit duration_limit event_limit entry_limit)
      },
      name: %Schema{type: :string},
      media_type: %Schema{type: :string},
      size_bytes: %Schema{type: :integer, minimum: 0, nullable: true},
      received_bytes: %Schema{type: :integer, minimum: 0},
      expected_sha256: %Schema{type: :string, pattern: "^[0-9a-f]{64}$", nullable: true},
      sha256: %Schema{type: :string, pattern: "^[0-9a-f]{64}$", nullable: true},
      status: %Schema{type: :string, enum: ~w(uploading receiving ready revoked expired)},
      revision: %Schema{type: :integer, minimum: 1},
      expires_at: Schemas.timestamp(),
      inserted_at: Schemas.timestamp(),
      updated_at: Schemas.timestamp()
    })
  end

  defp object(properties) do
    %Schema{
      type: :object,
      properties: properties,
      required: properties |> Map.keys() |> Enum.sort(),
      additionalProperties: false
    }
  end
end
