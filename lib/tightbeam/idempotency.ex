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

  @type onboarding_identity :: %{
          principal: String.t(),
          ceremony_id: String.t() | nil,
          phase: String.t(),
          response_kind: String.t() | nil,
          idempotency_key: String.t()
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

  @doc """
  Build the stable identity for one onboarding mutation.

  The function deliberately has no response-value argument. A caller can
  deduplicate a typed response, but cannot store or hash its secret through
  this seam.
  """
  @spec onboarding_identity(
          String.t(),
          String.t() | nil,
          String.t(),
          String.t() | nil,
          String.t()
        ) ::
          onboarding_identity()
  def onboarding_identity(principal, ceremony_id, phase, response_kind, idempotency_key)
      when is_binary(principal) and byte_size(principal) > 0 and
             is_binary(idempotency_key) and byte_size(idempotency_key) > 0 do
    valid? =
      case {phase, ceremony_id, response_kind} do
        {"begin", nil, nil} ->
          true

        {"respond", id, kind} when is_binary(id) and byte_size(id) > 0 ->
          kind in ["code", "approved"]

        {mutation, id, nil} when mutation in ["restart", "cancel"] ->
          is_binary(id) and byte_size(id) > 0

        _other ->
          false
      end

    if valid? do
      %{
        principal: principal,
        ceremony_id: ceremony_id,
        phase: phase,
        response_kind: response_kind,
        idempotency_key: idempotency_key
      }
    else
      raise ArgumentError, "invalid onboarding idempotency identity"
    end
  end

  def onboarding_identity(_principal, _ceremony_id, _phase, _response_kind, _idempotency_key) do
    raise ArgumentError, "invalid onboarding idempotency identity"
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
