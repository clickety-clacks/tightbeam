defmodule Tightbeam.Idempotency do
  @moduledoc """
  Durable idempotency ledger for spawn/retire/retain/wake/assign/condition (TS reference:
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

  @doc "Read the lifecycle mode of an existing retire key."
  @spec lifecycle_row(db(), String.t(), String.t(), String.t()) :: map() | nil
  def lifecycle_row(db \\ Tightbeam.DB, owner_user_id, operation, idempotency_key) do
    {:ok, rows} =
      DB.query(
        db,
        """
        SELECT sessionKey,inputDigest,resultJson,completedAt
        FROM wire_idempotency
        WHERE ownerUserId=?1 AND operation=?2 AND idempotencyKey=?3
        """,
        [owner_user_id, operation, idempotency_key]
      )

    case rows do
      [[session_key, digest, result_json, completed_at]] ->
        %{
          session_key: session_key,
          input_digest: digest,
          result_json: result_json,
          completed_at: completed_at
        }

      [] ->
        nil
    end
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

  @doc "Digest the complete input to one generation-bound lifecycle choice."
  @spec lifecycle_input_digest(String.t(), pos_integer()) :: String.t()
  def lifecycle_input_digest(session_key, generation)
      when is_binary(session_key) and is_integer(generation) and generation > 0 do
    canonical_json(%{"generation" => generation, "sessionKey" => session_key})
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  @doc "Read one authorized lifecycle replay inside the caller's transaction."
  @spec lifecycle_get_in_txn(Txn.t(), String.t(), String.t(), String.t(), String.t()) ::
          :miss | :conflict | {:replay, term()}
  def lifecycle_get_in_txn(%Txn{} = txn, owner, operation, key, digest)
      when operation in ["retain", "retire"] do
    case Txn.q(
           txn,
           """
           SELECT inputDigest, resultJson
           FROM wire_idempotency
           WHERE ownerUserId=?1 AND operation=?2 AND idempotencyKey=?3
           """,
           [owner, operation, key]
         ) do
      [] ->
        :miss

      [[^digest, result_json]] when is_binary(result_json) ->
        result = JSON.decode!(result_json)

        if canonical_json(result) == result_json do
          {:replay, result}
        else
          raise "noncanonical lifecycle idempotency result"
        end

      [[_other_digest, _result_json]] ->
        :conflict
    end
  end

  @doc "Commit one terminal lifecycle result with the domain transition."
  @spec put_lifecycle_in_txn(Txn.t(), map()) :: :ok
  def put_lifecycle_in_txn(%Txn{} = txn, row) do
    result_json = canonical_json(Map.fetch!(row, :result))

    Txn.q(
      txn,
      """
      INSERT INTO wire_idempotency
        (ownerUserId, operation, idempotencyKey, sessionKey,
         inputDigest, resultJson, completedAt)
      VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)
      """,
      [
        Map.fetch!(row, :owner_user_id),
        Map.fetch!(row, :operation),
        Map.fetch!(row, :idempotency_key),
        Map.fetch!(row, :session_key),
        Map.fetch!(row, :input_digest),
        result_json,
        Map.fetch!(row, :completed_at)
      ]
    )

    :ok
  end

  @doc "RFC 8785-compatible canonical JSON for the closed lifecycle value set."
  @spec canonical_json(term()) :: String.t()
  def canonical_json(value), do: encode_canonical(value)

  defp encode_canonical(nil), do: "null"
  defp encode_canonical(true), do: "true"
  defp encode_canonical(false), do: "false"
  defp encode_canonical(value) when is_integer(value), do: Integer.to_string(value)
  defp encode_canonical(value) when is_binary(value), do: JSON.encode!(value)

  defp encode_canonical(value) when is_list(value) do
    "[" <> Enum.map_join(value, ",", &encode_canonical/1) <> "]"
  end

  defp encode_canonical(value) when is_map(value) do
    value
    |> Enum.map(fn {key, item} -> {canonical_key(key), item} end)
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.map_join(",", fn {key, item} ->
      JSON.encode!(key) <> ":" <> encode_canonical(item)
    end)
    |> then(&("{" <> &1 <> "}"))
  end

  defp encode_canonical(value) when is_float(value),
    do: raise(ArgumentError, "lifecycle result JSON does not admit floating-point values")

  defp encode_canonical(value),
    do: raise(ArgumentError, "unsupported lifecycle result value: #{inspect(value)}")

  defp canonical_key(key) when is_binary(key), do: key
  defp canonical_key(key) when is_atom(key), do: Atom.to_string(key)

  defp canonical_key(_key),
    do: raise(ArgumentError, "lifecycle result object keys must be strings")

  defp transaction!(db, fun) do
    case DB.transaction(db, fun) do
      {:ok, result} -> result
      {:error, error} -> raise error
    end
  end
end
