defmodule Tightbeam.Idempotency do
  @moduledoc """
  Durable idempotency ledger for spawn/retire/wake/assign/condition/settle-turn (TS reference:
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
    operation      TEXT NOT NULL CHECK (operation IN ('spawn','retire','wake','assign','condition','work-item-create','settle-turn')),
    idempotencyKey TEXT NOT NULL,
    sessionKey     TEXT NOT NULL,
    requestFingerprint TEXT,
    responseJson       TEXT,
    PRIMARY KEY (ownerUserId, operation, idempotencyKey)
  );
  """

  @spec ensure_schema(db()) :: :ok | {:error, term()}
  def ensure_schema(db \\ Tightbeam.DB), do: DB.execute(db, @ddl)

  @doc false
  @spec upgrade_settlement_v1_in_txn(Txn.t()) :: :ok
  def upgrade_settlement_v1_in_txn(%Txn{} = txn) do
    :ok =
      Txn.exec(
        txn,
        "ALTER TABLE wire_idempotency RENAME TO wire_idempotency_pre_settlement"
      )

    :ok = Txn.exec(txn, @ddl)

    Txn.q(
      txn,
      """
      INSERT INTO wire_idempotency
        (ownerUserId, operation, idempotencyKey, sessionKey)
      SELECT ownerUserId, operation, idempotencyKey, sessionKey
      FROM wire_idempotency_pre_settlement
      """
    )

    :ok = Txn.exec(txn, "DROP TABLE wire_idempotency_pre_settlement")
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

  @doc "Stored settle-turn replay metadata for one operator/key pair, or nil."
  @spec settlement(db(), String.t(), String.t()) :: map() | nil
  def settlement(db \\ Tightbeam.DB, principal, idempotency_key) do
    {:ok, rows} =
      DB.query(
        db,
        """
        SELECT sessionKey, requestFingerprint, responseJson
        FROM wire_idempotency
        WHERE ownerUserId=?1 AND operation='settle-turn' AND idempotencyKey=?2
        """,
        [principal, idempotency_key]
      )

    settlement_row(rows)
  end

  @doc false
  @spec settlement_in_txn(Txn.t(), String.t(), String.t()) :: map() | nil
  def settlement_in_txn(%Txn{} = txn, principal, idempotency_key) do
    txn
    |> Txn.q(
      """
      SELECT sessionKey, requestFingerprint, responseJson
      FROM wire_idempotency
      WHERE ownerUserId=?1 AND operation='settle-turn' AND idempotencyKey=?2
      """,
      [principal, idempotency_key]
    )
    |> settlement_row()
  end

  @doc false
  @spec put_settlement_in_txn(Txn.t(), map()) :: :ok
  def put_settlement_in_txn(%Txn{} = txn, row) do
    Txn.q(
      txn,
      """
      INSERT INTO wire_idempotency
        (ownerUserId, operation, idempotencyKey, sessionKey, requestFingerprint, responseJson)
      VALUES (?1, 'settle-turn', ?2, ?3, ?4, ?5)
      """,
      [
        Map.fetch!(row, :principal),
        Map.fetch!(row, :idempotency_key),
        Map.fetch!(row, :session_key),
        Map.fetch!(row, :request_fingerprint),
        Map.fetch!(row, :response_json)
      ]
    )

    :ok
  end

  defp settlement_row([[session_key, fingerprint, response_json]])
       when is_binary(fingerprint) and is_binary(response_json),
       do: %{
         session_key: session_key,
         request_fingerprint: fingerprint,
         response_json: response_json
       }

  defp settlement_row([]), do: nil

  defp transaction!(db, fun) do
    case DB.transaction(db, fun) do
      {:ok, result} -> result
      {:error, error} -> raise error
    end
  end
end
