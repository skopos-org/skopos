defmodule SkoposWeb.API.V1.AccountJSON do
  @moduledoc false

  def data(user) do
    %{
      id: user.id,
      email: to_string(user.email),
      role: user.role,
      role_version: user.role_version,
      preferred_language: user.preferred_language,
      inserted_at: user.inserted_at,
      updated_at: user.updated_at
    }
  end
end
