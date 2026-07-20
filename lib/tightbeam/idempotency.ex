defmodule Tightbeam.Idempotency do
  @moduledoc """
  Durable idempotency ledger for spawn/retire/wake/assign (TS reference:
  src/wire/idempotency.ts). Same key + same operation + same owner → the
  original session, forever. Scope is (owner_user_id, operation, key) — a
  spawn key never collides with a retire key.
  """

  alias Tightbeam.DB
  alias Tightbeam.DB.Txn

  @type db :: GenServer.server()

  @type row :: %{
          owner_user_id: String.t(),
          operation: String.t(),
          idempotency_key: String.t(),
          session_key: String.t()
        }

  @ddl """
  CREATE TABLE IF NOT EXISTS wire_idempotency (
    ownerUserId    TEXT NOT NULL,
    operation      TEXT NOT NULL CHECK (operation IN ('spawn','retire','wake','assign')),
    idempotencyKey TEXT NOT NULL,
    sessionKey     TEXT NOT NULL,
    PRIMARY KEY (ownerUserId, operation, idempotencyKey)
  );
  """

  @spec ensure_schema(db()) :: :ok | {:error, term()}
  def ensure_schema(db \\ Tightbeam.DB) do
    :ok = DB.execute(db, @ddl)
    widen_operation_check(db)
  end

  # SQLite cannot ALTER a CHECK: databases created before 'wake' joined the
  # operation set get a rebuild (rename, recreate with the widened CHECK,
  # copy, drop). Detected via the stored DDL; idempotent.
  defp widen_operation_check(db) do
    {:ok, rows} =
      DB.query(
        db,
        "SELECT sql FROM sqlite_master WHERE type='table' AND name='wire_idempotency'",
        []
      )

    case rows do
      [[sql]] ->
        if String.contains?(sql, "'assign'") do
          :ok
        else
          :ok = DB.execute(db, "ALTER TABLE wire_idempotency RENAME TO wire_idempotency_old;")
          :ok = DB.execute(db, @ddl)

          {:ok, _} =
            DB.query(db, "INSERT INTO wire_idempotency SELECT * FROM wire_idempotency_old", [])

          :ok = DB.execute(db, "DROP TABLE wire_idempotency_old;")
        end

      _ ->
        :ok
    end
  end

  @doc "Prior result for this (owner, operation, key), or nil."
  @spec get(db(), String.t(), String.t(), String.t()) :: row() | nil
  def get(db \\ Tightbeam.DB, owner_user_id, operation, idempotency_key) do
    {:ok, rows} =
      DB.query(
        db,
        """
          SELECT ownerUserId, operation, idempotencyKey, sessionKey
          FROM wire_idempotency
          WHERE ownerUserId = ?1 AND operation = ?2 AND idempotencyKey = ?3
        """,
        [owner_user_id, operation, idempotency_key]
      )

    case rows do
      [[owner_user_id, operation, idempotency_key, session_key]] ->
        %{
          owner_user_id: owner_user_id,
          operation: operation,
          idempotency_key: idempotency_key,
          session_key: session_key
        }

      [] ->
        nil
    end
  end

  @doc "Record a completed operation's session_key under its key."
  @spec put(db(), row()) :: :ok
  def put(db \\ Tightbeam.DB, row) do
    transaction!(db, fn txn ->
      Txn.q(
        txn,
        """
          INSERT INTO wire_idempotency (ownerUserId, operation, idempotencyKey, sessionKey)
          VALUES (?1, ?2, ?3, ?4)
        """,
        [
          Map.fetch!(row, :owner_user_id),
          Map.fetch!(row, :operation),
          Map.fetch!(row, :idempotency_key),
          Map.fetch!(row, :session_key)
        ]
      )

      :ok
    end)
  end

  defp transaction!(db, fun) do
    case DB.transaction(db, fun) do
      {:ok, result} -> result
      {:error, error} -> raise error
    end
  end
end
