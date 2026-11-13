defmodule Tightbeam.RuntimeChanges do
  @moduledoc "Durable session changes accepted for the next turn boundary."

  alias Tightbeam.DB
  alias Tightbeam.DB.Txn

  @ddl """
  CREATE TABLE IF NOT EXISTS runtime_changes (
    seq INTEGER PRIMARY KEY AUTOINCREMENT,
    id TEXT NOT NULL UNIQUE,
    sessionKey TEXT NOT NULL REFERENCES sessions(sessionKey),
    request TEXT NOT NULL,
    state TEXT NOT NULL CHECK(state IN ('pending','applied','failed')),
    result TEXT,
    createdAt INTEGER NOT NULL,
    finishedAt INTEGER
  );
  CREATE INDEX IF NOT EXISTS runtime_changes_pending
    ON runtime_changes(sessionKey, state, seq);
  """

  def ensure_schema(db), do: DB.execute(db, @ddl)

  def enqueue(db, session_key, request) do
    id = "rtc_" <> Tightbeam.Id.uuid4()

    {:ok, :ok} =
      DB.transaction(db, fn txn ->
        Txn.q(
          txn,
          """
          INSERT INTO runtime_changes(id,sessionKey,request,state,createdAt)
          VALUES(?1,?2,?3,'pending',?4)
          """,
          [id, session_key, JSON.encode!(request), System.system_time(:millisecond)]
        )

        :ok
      end)

    %{
      ok: true,
      accepted: true,
      change_id: id,
      applies: "after_turn",
      message: "Change accepted; takes effect after this turn.",
      projection_committed: false
    }
  end

  def pending(db, session_key) do
    {:ok, rows} =
      DB.query(
        db,
        "SELECT id,request FROM runtime_changes WHERE sessionKey=?1 AND state='pending' ORDER BY seq",
        [session_key]
      )

    Enum.map(rows, fn [id, request] -> {id, JSON.decode!(request)} end)
  end

  def pending_sessions(db) do
    {:ok, rows} =
      DB.query(
        db,
        "SELECT DISTINCT sessionKey FROM runtime_changes WHERE state='pending'"
      )

    Enum.map(rows, &hd/1)
  end

  def status(db, session_key) do
    {:ok, rows} =
      DB.query(
        db,
        "SELECT id,state,result,createdAt,finishedAt FROM runtime_changes WHERE sessionKey=?1 ORDER BY seq",
        [session_key]
      )

    Enum.map(rows, fn [id, state, result, created_at, finished_at] ->
      %{
        changeId: id,
        state: state,
        result: result && JSON.decode!(result),
        createdAt: created_at,
        finishedAt: finished_at
      }
    end)
  end

  # The successful pointer swap calls this in its own transaction: a restart
  # must not repeat a handoff that already committed.
  def finish_in_txn(txn, id, result) do
    state = if result[:ok] == true, do: "applied", else: "failed"

    Txn.q(
      txn,
      """
      UPDATE runtime_changes SET state=?2,result=?3,finishedAt=?4
      WHERE id=?1 AND state='pending'
      """,
      [id, state, JSON.encode!(result), System.system_time(:millisecond)]
    )

    :ok
  end

  def finish(db, id, result) do
    {:ok, :ok} = DB.transaction(db, &finish_in_txn(&1, id, result))
    :ok
  end
end
