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
  def ensure_schema(db \\ Tightbeam.DB), do: DB.execute(db, @ddl)

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

  @doc false
  def migrate_reparent_in_txn(txn) do
    Txn.exec(txn, """
    CREATE TABLE wire_idempotency_reparent (
      ownerUserId TEXT NOT NULL,
      operation TEXT NOT NULL CHECK (operation IN ('spawn','retire','wake','assign','condition','work-item-create','session-reparent')),
      idempotencyKey TEXT NOT NULL,
      sessionKey TEXT NOT NULL,
      requestFingerprint TEXT,
      canonicalResponse TEXT,
      PRIMARY KEY(ownerUserId,operation,idempotencyKey),
      CHECK (operation != 'session-reparent' OR
        (requestFingerprint IS NOT NULL AND canonicalResponse IS NOT NULL))
    );
    INSERT INTO wire_idempotency_reparent(ownerUserId,operation,idempotencyKey,sessionKey)
      SELECT ownerUserId,operation,idempotencyKey,sessionKey FROM wire_idempotency;
    DROP TABLE wire_idempotency;
    ALTER TABLE wire_idempotency_reparent RENAME TO wire_idempotency;
    """)
  end

  @doc false
  def reparent_result_in_txn(txn, owner, key) do
    case Txn.q(txn, """
    SELECT requestFingerprint,canonicalResponse FROM wire_idempotency
    WHERE ownerUserId=?1 AND operation='session-reparent' AND idempotencyKey=?2
    """, [owner,key]) do
      [[fingerprint,response]] -> %{fingerprint: fingerprint, response: Jason.decode!(response)}
      [] -> nil
    end
  end

  @doc false
  def put_reparent_in_txn(txn, owner, key, fingerprint, event, response) do
    Txn.q(txn, """
    INSERT INTO wire_idempotency(ownerUserId,operation,idempotencyKey,sessionKey,requestFingerprint,canonicalResponse)
    VALUES (?1,'session-reparent',?2,?3,?4,?5)
    """, [owner,key,event,fingerprint,Jason.encode!(response)])
    :ok
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
