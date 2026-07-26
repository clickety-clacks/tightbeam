defmodule Tightbeam.Idempotency do
  @moduledoc """
  Durable idempotency ledger for spawn/retire/wake/assign/condition (TS reference:
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
    operation      TEXT NOT NULL CHECK (operation IN ('spawn','retire','wake','assign','condition','work-item-create')),
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

  # SQLite cannot ALTER a CHECK: databases created before the newest operation
  # joined the set get a rebuild (rename, recreate with the widened CHECK,
  # copy, drop). 'work-item-create' is the current frontier (work-item
  # brackets); a DB whose CHECK predates it (e.g. only through 'condition') is
  # rebuilt. The rebuild is ONE transaction so a crash cannot strand keys in a
  # half-migrated state, and a resume guard finishes any rebuild interrupted by
  # a crash of an earlier (non-transactional) release before proceeding.
  defp widen_operation_check(db) do
    recover_half_migrated(db)

    {:ok, rows} =
      DB.query(
        db,
        "SELECT sql FROM sqlite_master WHERE type='table' AND name='wire_idempotency'",
        []
      )

    case rows do
      [[sql]] ->
        unless String.contains?(sql, "'work-item-create'"), do: rebuild(db)
        :ok

      _ ->
        :ok
    end
  end

  # An older release migrated with separate committed statements; a crash after
  # the rename could leave wire_idempotency_old behind. Complete the copy (and
  # drop) atomically before any caller reads the ledger, so no key is stranded.
  # INSERT OR IGNORE tolerates a crash at any point (empty, partial, or full
  # copy) because the primary key dedupes.
  defp recover_half_migrated(db) do
    {:ok, [[old_exists]]} =
      DB.query(
        db,
        "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='wire_idempotency_old'"
      )

    if old_exists == 1 do
      transaction!(db, fn txn ->
        Txn.exec(txn, @ddl)
        Txn.q(txn, "INSERT OR IGNORE INTO wire_idempotency SELECT * FROM wire_idempotency_old")
        Txn.exec(txn, "DROP TABLE wire_idempotency_old")
        :ok
      end)
    end

    :ok
  end

  defp rebuild(db) do
    transaction!(db, fn txn ->
      Txn.exec(txn, "ALTER TABLE wire_idempotency RENAME TO wire_idempotency_old")
      Txn.exec(txn, @ddl)
      Txn.q(txn, "INSERT INTO wire_idempotency SELECT * FROM wire_idempotency_old")
      Txn.exec(txn, "DROP TABLE wire_idempotency_old")
      :ok
    end)

    :ok
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

    row_from_query(rows)
  end

  @doc "Prior result lookup inside an existing DB transaction."
  @spec get_in_txn(Txn.t(), String.t(), String.t(), String.t()) :: row() | nil
  def get_in_txn(%Txn{} = txn, owner_user_id, operation, idempotency_key) do
    rows =
      Txn.q(
        txn,
        """
          SELECT ownerUserId, operation, idempotencyKey, sessionKey
          FROM wire_idempotency
          WHERE ownerUserId = ?1 AND operation = ?2 AND idempotencyKey = ?3
        """,
        [owner_user_id, operation, idempotency_key]
      )

    row_from_query(rows)
  end

  defp row_from_query(rows) do
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
    transaction!(db, &put_in_txn(&1, row))
  end

  @doc "Record a completed operation inside an existing DB transaction."
  @spec put_in_txn(Txn.t(), row()) :: :ok
  def put_in_txn(%Txn{} = txn, row) do
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
  end

  defp transaction!(db, fun) do
    case DB.transaction(db, fun) do
      {:ok, result} -> result
      {:error, error} -> raise error
    end
  end
end
