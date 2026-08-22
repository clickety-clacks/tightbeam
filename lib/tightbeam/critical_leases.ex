defmodule Tightbeam.CriticalLeases do
  @moduledoc "Bounded critical-section leases for session lifecycle deferral."

  alias Tightbeam.DB
  alias Tightbeam.DB.Txn
  alias Tightbeam.Firehose.Publisher

  @ddl """
  CREATE TABLE IF NOT EXISTS critical_leases (
    sessionKey   TEXT PRIMARY KEY REFERENCES sessions(sessionKey),
    reason       TEXT NOT NULL,
    startedAt    INTEGER NOT NULL,
    expiresAt    INTEGER NOT NULL,
    hardDeadline INTEGER NOT NULL,
    updatedAt    INTEGER NOT NULL
  );
  """

  @spec ensure_schema(DB.server()) :: :ok | {:error, term()}
  def ensure_schema(db \\ DB), do: DB.execute(db, @ddl)

  @doc "Set or renew one lease without moving its original hard deadline."
  @spec declare(DB.server(), String.t(), pos_integer(), String.t(), pos_integer()) :: map()
  def declare(db, session_key, duration_ms, reason, hard_cap_ms, firehose_call \\ nil) do
    now = System.system_time(:millisecond)

    {:ok, lease} =
      DB.transaction(db, fn txn ->
        lease =
          case active_in_txn(txn, session_key, now) do
            nil ->
              hard_deadline = now + hard_cap_ms
              expires_at = min(now + duration_ms, hard_deadline)

              Txn.q(
                txn,
                """
                INSERT INTO critical_leases
                  (sessionKey, reason, startedAt, expiresAt, hardDeadline, updatedAt)
                VALUES (?1, ?2, ?3, ?4, ?5, ?3)
                ON CONFLICT(sessionKey) DO UPDATE SET
                  reason=excluded.reason, startedAt=excluded.startedAt,
                  expiresAt=excluded.expiresAt, hardDeadline=excluded.hardDeadline,
                  updatedAt=excluded.updatedAt
                """,
                [session_key, reason, now, expires_at, hard_deadline]
              )

              lease(session_key, reason, now, expires_at, hard_deadline, now)

            current ->
              expires_at = min(current.hard_deadline, max(now, current.expires_at) + duration_ms)
              updated_at = max(now, current.updated_at + 1)

              Txn.q(
                txn,
                "UPDATE critical_leases SET reason=?2, expiresAt=?3, updatedAt=?4 WHERE sessionKey=?1",
                [session_key, reason, expires_at, updated_at]
              )

              %{current | reason: reason, expires_at: expires_at, updated_at: updated_at}
          end

        if match?(%{firehose_in_txn: true}, firehose_call),
          do: Publisher.maybe_accepted_in_txn(txn, firehose_call, lease)

        lease
      end)

    lease
  end

  @doc "Return an unexpired lease inside the caller's transaction."
  @spec active_in_txn(Txn.t(), String.t(), integer()) :: map() | nil
  def active_in_txn(%Txn{} = txn, session_key, now) do
    case Txn.q(
           txn,
           "SELECT reason, startedAt, expiresAt, hardDeadline, updatedAt FROM critical_leases WHERE sessionKey=?1 AND expiresAt>?2",
           [session_key, now]
         ) do
      [[reason, started_at, expires_at, hard_deadline, updated_at]] ->
        lease(session_key, reason, started_at, expires_at, hard_deadline, updated_at)

      [] ->
        nil
    end
  end

  @doc "Return a lease row regardless of expiry, or nil."
  @spec get(DB.server(), String.t()) :: map() | nil
  def get(db \\ DB, session_key) do
    case DB.query(
           db,
           "SELECT reason, startedAt, expiresAt, hardDeadline, updatedAt FROM critical_leases WHERE sessionKey=?1",
           [session_key]
         ) do
      {:ok, [[reason, started_at, expires_at, hard_deadline, updated_at]]} ->
        lease(session_key, reason, started_at, expires_at, hard_deadline, updated_at)

      {:ok, []} ->
        nil
    end
  end

  defp lease(session_key, reason, started_at, expires_at, hard_deadline, updated_at) do
    %{
      session_key: session_key,
      reason: reason,
      started_at: started_at,
      expires_at: expires_at,
      hard_deadline: hard_deadline,
      updated_at: updated_at
    }
  end
end
