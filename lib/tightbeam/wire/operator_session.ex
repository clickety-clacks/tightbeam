defmodule Tightbeam.Wire.OperatorSession do
  @moduledoc false

  alias Tightbeam.{DB, Devices, Org}

  # The provisioned operator bearer carries no user identity itself. As with
  # CLI dispatch, the caller names the ordinary user operation identity.
  def operator_token?(token, deps) do
    is_binary(token) and token != "" and token == deps[:cli_token]
  end

  def resolve_user(db, user_id) when is_binary(user_id) and user_id != "" do
    case Devices.user(db, user_id) do
      nil -> {:error, "not_found"}
      user -> {:ok, user}
    end
  end

  def resolve_user(_db, _user_id), do: {:error, "invalid_message"}

  def resolve_default_read_principal(db) do
    {:ok, rows} =
      DB.query(
        db,
        "SELECT userId FROM users WHERE isAdmin = 1 ORDER BY createdAt, userId LIMIT 1",
        []
      )

    case rows do
      [[user_id]] -> resolve_user(db, user_id)
      [] -> {:ok, %{user_id: "org", is_admin: true}}
    end
  end

  def resolve(db, %{"asUser" => user_id, "sessionKey" => session_key})
      when is_binary(user_id) and user_id != "" and is_binary(session_key) and
             session_key != "" do
    with user when not is_nil(user) <- Devices.user(db, user_id),
         session when not is_nil(session) <- Org.get(db, session_key),
         true <- session.owner_user_id == user_id or user.is_admin do
      {:ok, user, session}
    else
      _ -> {:error, "not_found"}
    end
  end

  def resolve(_db, _message), do: {:error, "invalid_message"}
end
