defmodule Tightbeam.Wire.OperatorSession do
  @moduledoc false

  alias Tightbeam.{Devices, Org}

  # The provisioned operator bearer carries no user identity itself. As with
  # CLI dispatch, the caller names the ordinary user operation identity.
  def operator_token?(token, deps) do
    is_binary(token) and token != "" and token == deps[:cli_token]
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
