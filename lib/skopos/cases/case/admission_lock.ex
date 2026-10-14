defmodule Skopos.Cases.Case.AdmissionLock do
  @moduledoc false

  alias Skopos.Repo

  @lock_key 987_654_321

  def acquire do
    case Repo.query("SELECT pg_advisory_xact_lock($1)", [@lock_key]) do
      {:ok, _result} -> :ok
      {:error, _error} = error -> error
    end
  end
end
