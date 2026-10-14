defmodule Skopos.Accounts.OIDC.Request.State do
  use Ash.Resource.Validation

  alias Ash.Changeset
  alias Skopos.Accounts.OIDC.Request, as: OIDCRequest

  @impl true
  def validate(changeset, options, _context) do
    case options[:phase] do
      :start -> validate_start(changeset)
      :complete -> validate_complete(changeset)
      :consume -> validate_consume(changeset)
    end
  end

  defp validate_start(changeset) do
    request = changeset.data
    token = Changeset.get_argument(changeset, :start_token)

    cond do
      expired?(request) -> {:error, field: :expires_at, message: "has expired"}
      request.started_at -> {:error, field: :started_at, message: "has already been used"}
      request.completed_at -> {:error, field: :completed_at, message: "has already completed"}
      OIDCRequest.digest_matches?(request.start_token_digest, token) -> :ok
      true -> {:error, field: :start_token, message: "is invalid"}
    end
  end

  defp validate_complete(changeset) do
    request = changeset.data
    code_digest = Changeset.get_argument(changeset, :code_digest)

    cond do
      expired?(request) ->
        {:error, field: :expires_at, message: "has expired"}

      is_nil(request.started_at) ->
        {:error, field: :started_at, message: "has not started"}

      request.completed_at ->
        {:error, field: :completed_at, message: "has already completed"}

      request.purpose == :cli_login and not is_binary(code_digest) ->
        {:error, field: :code_digest, message: "is required for CLI login"}

      request.purpose == :link and not is_nil(code_digest) ->
        {:error, field: :code_digest, message: "is not used for account linking"}

      true ->
        :ok
    end
  end

  defp validate_consume(changeset) do
    request = changeset.data

    cond do
      request.purpose != :cli_login ->
        {:error, field: :purpose, message: "is not a CLI login"}

      expired?(request) ->
        {:error, field: :expires_at, message: "has expired"}

      is_nil(request.completed_at) ->
        {:error, field: :completed_at, message: "has not completed"}

      request.consumed_at ->
        {:error, field: :consumed_at, message: "has already been used"}

      not OIDCRequest.digest_matches?(
        request.code_digest,
        Changeset.get_argument(changeset, :code)
      ) ->
        {:error, field: :code, message: "is invalid"}

      not OIDCRequest.digest_matches?(
        request.verifier_digest,
        Changeset.get_argument(changeset, :verifier)
      ) ->
        {:error, field: :verifier, message: "is invalid"}

      true ->
        :ok
    end
  end

  defp expired?(request), do: DateTime.compare(request.expires_at, DateTime.utc_now()) != :gt
end
