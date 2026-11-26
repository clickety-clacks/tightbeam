defmodule Tightbeam.ExecutionMapTurnVersionsTest do
  use Tightbeam.TestCase, async: false

  alias Tightbeam.{DB, ExecutionMapTurnVersions, Ledger}
  alias Tightbeam.DB.Txn

  test "backfill resumes from its committed cursor and accounts for interleaved writes" do
    db = start_supervised!({DB, path: ":memory:", name: nil})
    :ok = Ledger.ensure_schema(db)

    assert {:ok, _} =
             DB.query(db, """
             WITH RECURSIVE n(i) AS (
               VALUES(1) UNION ALL SELECT i + 1 FROM n WHERE i < 5000
             )
             INSERT INTO turns (seq, sessionKey, messageId, origin, prompt, jobRef, createdAt)
             SELECT i, 'source', printf('turn-%d', i), 'process:test', '', 'wi_old', i FROM n
             """)

    assert :ok = ExecutionMapTurnVersions.ensure_schema(db)
    refute ready?(db)
    assert :more = ExecutionMapTurnVersions.backfill_batch(db)
    assert [["wi_old", 4096]] == groups(db)

    assert {:ok, _} = DB.query(db, "UPDATE turns SET jobRef='wi_moved' WHERE seq IN (1, 4999)")
    assert {:ok, _} = DB.query(db, "DELETE FROM turns WHERE seq IN (2, 5000)")

    assert {:ok, _} =
             DB.query(db, """
             INSERT INTO turns (sessionKey, messageId, origin, prompt, jobRef, createdAt)
             VALUES ('source', 'new-turn', 'process:test', '', 'wi_new', 5001)
             """)

    assert [["wi_moved", 1], ["wi_new", 1], ["wi_old", 4094]] == groups(db)

    assert :ok = ExecutionMapTurnVersions.ensure_schema(db)
    refute ready?(db)
    assert :ok = ExecutionMapTurnVersions.backfill(db)
    assert ready?(db)
    assert [["wi_moved", 2], ["wi_new", 1], ["wi_old", 4996]] == groups(db)

    assert :ok = ExecutionMapTurnVersions.backfill(db)
    assert [["wi_moved", 2], ["wi_new", 1], ["wi_old", 4996]] == groups(db)
  end

  defp ready?(db) do
    {:ok, ready?} = DB.read_transaction(db, &ExecutionMapTurnVersions.ready?/1)
    ready?
  end

  defp groups(db) do
    {:ok, rows} =
      DB.read_transaction(db, fn txn ->
        Txn.q(txn, "SELECT jobRef, turnCount FROM execution_map_turn_versions ORDER BY jobRef")
      end)

    rows
  end
end
