defmodule Tightbeam.ExecutionMapTurnVersionsTest do
  use Tightbeam.TestCase, async: false

  import ExUnit.CaptureLog

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

  test "a supervised backfill survives repeated overload and finishes after recovery" do
    db = start_supervised!({DB, path: ":memory:", name: nil})
    :ok = Ledger.ensure_schema(db)

    assert {:ok, _} =
             DB.query(db, """
             INSERT INTO turns (sessionKey, messageId, origin, prompt, jobRef, createdAt)
             VALUES ('source', 'historical-turn', 'process:test', '', 'wi_old', 1)
             """)

    assert :ok = ExecutionMapTurnVersions.ensure_schema(db)
    refute ready?(db)
    :sys.suspend(db)

    {supervisor, worker, monitor} =
      try do
        for _ <- 1..128 do
          send(db, {:"$gen_call", {self(), make_ref()}, {:query, "SELECT 1", []}})
        end

        {worker_state, log} =
          with_log(
            [level: :debug],
            fn ->
              supervisor =
                start_supervised!(%{
                  id: :backfill_supervisor,
                  start:
                    {Supervisor, :start_link,
                     [[{ExecutionMapTurnVersions, db}], [strategy: :one_for_one, max_restarts: 0]]},
                  type: :supervisor
                })

              assert [{ExecutionMapTurnVersions, worker, :worker, _}] =
                       Supervisor.which_children(supervisor)

              monitor = Process.monitor(worker)
              refute_receive {:DOWN, ^monitor, :process, ^worker, _}, 750
              assert Process.alive?(supervisor)
              assert {:message_queue_len, 128} = Process.info(db, :message_queue_len)
              {supervisor, worker, monitor}
            end
          )

        assert length(Regex.scan(~r/background pass deferred/, log)) >= 2
        worker_state
      after
        :sys.resume(db)
      end

    assert_receive {:DOWN, ^monitor, :process, ^worker, :normal}, 5_000
    assert Process.alive?(supervisor)
    assert [] == Supervisor.which_children(supervisor)
    assert ready?(db)
    assert [["wi_old", 1]] == groups(db)
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
