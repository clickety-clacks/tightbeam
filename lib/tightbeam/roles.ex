defmodule Tightbeam.Roles do
  @moduledoc """
  Durable role names with mutable session bindings and owner-Main fallback.

  Roles record assignments; resolution derives a delivery key from those
  recorded facts and never chooses an assignment.
  """

  alias Tightbeam.DB
  alias Tightbeam.DB.Txn
  alias Tightbeam.Org

  @type db :: GenServer.server()

  @type role :: %{
          name: String.t(),
          bound_session_key: String.t() | nil,
          owner_user_id: String.t()
        }

  defmodule TransactionError do
    @moduledoc false
    defexception [:error]

    @impl true
    def message(%{error: error}), do: error.message
  end

  @ddl """
  CREATE TABLE IF NOT EXISTS roles (
    name            TEXT PRIMARY KEY,
    boundSessionKey TEXT,
    ownerUserId     TEXT NOT NULL,
    createdAt       INTEGER NOT NULL,
    updatedAt       INTEGER NOT NULL
  );
  """

  @name_re ~r/^[a-z0-9][a-z0-9-]*(:[a-z0-9][a-z0-9-]*)*$/

  @spec ensure_schema(db()) :: :ok | {:error, term()}
  def ensure_schema(db \\ Tightbeam.DB), do: DB.execute(db, @ddl)

  @doc "Create a role, optionally bound to an existing active session."
  @spec create!(db(), String.t(), String.t(), String.t() | nil) ::
          role() | {:error, %{code: String.t(), message: String.t()}}
  def create!(db \\ Tightbeam.DB, name, owner_user_id, bound_session_key)

  def create!(%Txn{} = txn, name, owner_user_id, bound_session_key) do
    with :ok <- validate_name(name),
         :ok <- role_absent(txn, name),
         :ok <- active_binding(txn, bound_session_key) do
      now = now()

      Txn.q(
        txn,
        """
        INSERT INTO roles (name, boundSessionKey, ownerUserId, createdAt, updatedAt)
        VALUES (?1, ?2, ?3, ?4, ?4)
        """,
        [name, bound_session_key, owner_user_id, now]
      )

      %{name: name, bound_session_key: bound_session_key, owner_user_id: owner_user_id}
    end
  end

  def create!(db, name, owner_user_id, bound_session_key) do
    transaction!(db, fn txn -> create!(txn, name, owner_user_id, bound_session_key) end)
  end

  @doc false
  @spec create_in_txn!(Txn.t(), String.t(), String.t(), String.t() | nil) :: role()
  def create_in_txn!(%Txn{} = txn, name, owner_user_id, bound_session_key) do
    case create!(txn, name, owner_user_id, bound_session_key) do
      {:error, error} -> raise TransactionError, error: error
      role -> role
    end
  end

  @doc false
  @spec migrate_handle(db(), String.t(), String.t(), String.t()) ::
          role() | {:error, %{code: String.t(), message: String.t()}}
  def migrate_handle(db, name, owner_user_id, bound_session_key) do
    transaction!(db, fn txn ->
      with :ok <- validate_name(name),
           :ok <- role_absent(txn, name) do
        now = now()

        Txn.q(
          txn,
          """
          INSERT INTO roles (name, boundSessionKey, ownerUserId, createdAt, updatedAt)
          VALUES (?1, ?2, ?3, ?4, ?4)
          """,
          [name, bound_session_key, owner_user_id, now]
        )

        %{name: name, bound_session_key: bound_session_key, owner_user_id: owner_user_id}
      end
    end)
  end

  @doc "Bind a role to an existing active session."
  @spec bind(db(), String.t(), String.t()) ::
          :ok | {:error, %{code: String.t(), message: String.t()}}
  def bind(db \\ Tightbeam.DB, name, session_key) do
    transaction!(db, fn txn ->
      with :ok <- role_present(txn, name),
           :ok <- active_binding(txn, session_key) do
        Txn.q(
          txn,
          "UPDATE roles SET boundSessionKey = ?2, updatedAt = ?3 WHERE name = ?1",
          [name, session_key, now()]
        )

        :ok
      end
    end)
  end

  @doc "Remove a role name."
  @spec rm(db(), String.t()) :: :ok | {:error, %{code: String.t(), message: String.t()}}
  def rm(db \\ Tightbeam.DB, name) do
    transaction!(db, fn txn ->
      with :ok <- role_present(txn, name) do
        Txn.q(txn, "DELETE FROM roles WHERE name = ?1", [name])
        :ok
      end
    end)
  end

  @doc "Fetch a role by name, or nil."
  @spec get(db(), String.t()) :: role() | nil
  def get(db \\ Tightbeam.DB, name) do
    {:ok, rows} = DB.query(db, select_role_sql() <> " WHERE name = ?1", [name])

    case rows do
      [row] -> to_role(row)
      [] -> nil
    end
  end

  @doc "List all roles sorted by name."
  @spec list(db()) :: [role()]
  def list(db \\ Tightbeam.DB) do
    {:ok, rows} = DB.query(db, select_role_sql() <> " ORDER BY name")
    Enum.map(rows, &to_role/1)
  end

  @doc "Resolve a role to its active binding or its owner's Main session."
  @spec resolve(db(), String.t()) ::
          {:ok, String.t(), boolean()}
          | {:error, %{code: String.t(), message: String.t()}}
  def resolve(db \\ Tightbeam.DB, name) do
    case get(db, name) do
      nil ->
        {:error, %{code: "unknown_role", message: "unknown role: #{name}"}}

      %{bound_session_key: key} = role when is_binary(key) ->
        case Org.get(db, key) do
          %{state: "active"} -> {:ok, key, false}
          _ -> {:ok, Org.personal_session_key(role.owner_user_id), true}
        end

      role ->
        {:ok, Org.personal_session_key(role.owner_user_id), true}
    end
  end

  defp validate_name(name) when is_binary(name) do
    cond do
      String.starts_with?(name, "agent:") ->
        {:error,
         %{code: "invalid_role_name", message: "role name uses reserved agent: prefix: #{name}"}}

      String.starts_with?(name, "user:") ->
        {:error,
         %{code: "invalid_role_name", message: "role name uses reserved user: prefix: #{name}"}}

      Regex.match?(@name_re, name) ->
        :ok

      true ->
        {:error, %{code: "invalid_role_name", message: "invalid role name: #{name}"}}
    end
  end

  defp validate_name(name),
    do: {:error, %{code: "invalid_role_name", message: "invalid role name: #{inspect(name)}"}}

  defp role_absent(txn, name) do
    case Txn.q(txn, "SELECT 1 FROM roles WHERE name = ?1", [name]) do
      [] -> :ok
      _ -> {:error, %{code: "role_exists", message: "role already exists: #{name}"}}
    end
  end

  defp role_present(txn, name) do
    case Txn.q(txn, "SELECT 1 FROM roles WHERE name = ?1", [name]) do
      [] -> {:error, %{code: "unknown_role", message: "unknown role: #{name}"}}
      _ -> :ok
    end
  end

  defp active_binding(_txn, nil), do: :ok

  defp active_binding(txn, session_key) do
    case Txn.q(txn, "SELECT state FROM sessions WHERE sessionKey = ?1", [session_key]) do
      [["active"]] -> :ok
      _ -> {:error, %{code: "unknown_session", message: "unknown active session: #{session_key}"}}
    end
  end

  defp select_role_sql, do: "SELECT name, boundSessionKey, ownerUserId FROM roles"

  defp to_role([name, bound_session_key, owner_user_id]) do
    %{name: name, bound_session_key: bound_session_key, owner_user_id: owner_user_id}
  end

  defp transaction!(db, fun) do
    case DB.transaction(db, fun) do
      {:ok, result} -> result
      {:error, error} -> raise error
    end
  end

  defp now, do: System.system_time(:millisecond)
end
