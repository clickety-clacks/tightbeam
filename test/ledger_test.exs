defmodule Tightbeam.LedgerTest do
  use ExUnit.Case, async: false

  alias Tightbeam.{DB, Ledger}

  setup do
    name = :"db_#{System.unique_integer([:positive])}"
    start_supervised!({DB, path: ":memory:", name: name})
    :ok = Ledger.ensure_schema(name)
    create_test_sessions(name)
    %{db: name}
  end

  defp create_test_sessions(db) do
    :ok =
      DB.execute(db, """
      CREATE TABLE sessions (
        sessionKey TEXT PRIMARY KEY,
        model TEXT NOT NULL,
        harness TEXT NOT NULL,
        state TEXT NOT NULL DEFAULT 'active',
        adjudicationHold TEXT,
        updatedAt INTEGER NOT NULL DEFAULT 0
      );
      INSERT INTO sessions (sessionKey, model, harness)
      VALUES
        ('k1', 'claude-sonnet-5[medium]', 'claude'),
        ('k2', 'claude-sonnet-5[medium]', 'claude');
      """)
  end

  defp enqueue!(db, sk, prompt, opts \\ []) do
    {:ok, seq} =
      Ledger.enqueue(db, %{
        session_key: sk,
        message_id: Keyword.get(opts, :message_id, "s_#{System.unique_integer([:positive])}"),
        origin: "user:test",
        prompt: prompt,
        wake_id: Keyword.get(opts, :wake_id)
      })

    seq
  end

  test "seq is the authoritative execution order", %{db: db} do
    s1 = enqueue!(db, "k1", "first")
    s2 = enqueue!(db, "k1", "second")
    assert s2 > s1

    {:ok, t1} = Ledger.claim_next(db, "k1", "lane-a")
    assert t1.prompt == "first"
  end

  test "one turn per session, enforced in SQL", %{db: db} do
    enqueue!(db, "k1", "a")
    enqueue!(db, "k1", "b")

    {:ok, t} = Ledger.claim_next(db, "k1", "lane")
    assert :busy = Ledger.claim_next(db, "k1", "lane")

    :ok = Ledger.finish(db, t.seq, "delivered")
    {:ok, t2} = Ledger.claim_next(db, "k1", "lane")
    assert t2.prompt == "b"
    assert :none = Ledger.claim_next(db, "k2", "lane")
  end

  test "exactly-one durable terminal transition (CAS)", %{db: db} do
    enqueue!(db, "k1", "a")
    {:ok, t} = Ledger.claim_next(db, "k1", "lane")

    assert :ok = Ledger.finish(db, t.seq, "delivered")
    assert :already_terminal = Ledger.finish(db, t.seq, "failed")
  end

  test "wakeId dedupe: at-least-once attempts, exactly-once enqueue", %{db: db} do
    assert {:ok, _} =
             Ledger.enqueue(db, %{
               session_key: "k1",
               message_id: "m1",
               origin: "system",
               prompt: "p",
               wake_id: "w_1"
             })

    assert {:error, :duplicate_wake} =
             Ledger.enqueue(db, %{
               session_key: "k1",
               message_id: "m2",
               origin: "system",
               prompt: "p",
               wake_id: "w_1"
             })
  end

  test "recovery: running turns become failed_unknown, never re-queued", %{db: db} do
    enqueue!(db, "k1", "orphan")
    {:ok, t} = Ledger.claim_next(db, "k1", "lane")

    assert [seq] = Ledger.recover_running(db)
    assert seq == t.seq
    assert Ledger.recover_running(db) == []
    # next queued work proceeds; the orphan is terminal
    enqueue!(db, "k1", "next")
    {:ok, t2} = Ledger.claim_next(db, "k1", "lane")
    assert t2.prompt == "next"
  end

  test "claim stamps the session's selected mind after a queued turn is tuned",
       %{db: db} do
    first = enqueue!(db, "k1", "before tune")

    assert {:ok, [["queued", nil, nil]]} =
             DB.query(db, "SELECT status, model, harness FROM turns WHERE seq = ?1", [first])

    :ok =
      DB.execute(
        db,
        "UPDATE sessions SET model='gpt-5.6-sol[high]', harness='codex' WHERE sessionKey='k1'"
      )

    assert {:ok, %{seq: ^first}} = Ledger.claim_next(db, "k1", "lane")

    assert {:ok, [["running", "gpt-5.6-sol[high]", "codex"]]} =
             DB.query(db, "SELECT status, model, harness FROM turns WHERE seq = ?1", [first])
  end

  test "publication feed: terminal rows surface until marked published", %{db: db} do
    enqueue!(db, "k1", "a")
    {:ok, t} = Ledger.claim_next(db, "k1", "lane")
    :ok = Ledger.finish(db, t.seq, "delivered")

    assert [%{seq: seq, status: "delivered"}] = Ledger.unpublished_terminals(db)
    :ok = Ledger.mark_published(db, seq)
    assert Ledger.unpublished_terminals(db) == []
  end

  test "reconciler feed + conservation audit", %{db: db} do
    enqueue!(db, "k1", "a")
    enqueue!(db, "k2", "b")
    assert Enum.sort(Ledger.pending_sessions(db)) == ["k1", "k2"]

    # nothing is old yet
    assert Ledger.non_terminal_older_than(db, 60_000) == []
    # everything is "old" at 0ms — the audit sees pending work
    assert length(Ledger.non_terminal_older_than(db, -1)) == 2
  end

  test "transaction rollback leaves no partial rows", %{db: db} do
    assert {:error, _} =
             DB.transaction(db, fn txn ->
               Ledger.enqueue_in_txn(txn, %{
                 session_key: "k1",
                 message_id: "m",
                 origin: "user:test",
                 prompt: "p"
               })

               raise "boom"
             end)

    {:ok, rows} = DB.query(db, "SELECT COUNT(*) FROM turns")
    assert rows == [[0]]
  end

  test "legacy turns gains exactly four nullable trace columns additively with indexes" do
    db = :"legacy_turns_#{System.unique_integer([:positive])}"

    start_supervised!(%{
      id: db,
      start: {DB, :start_link, [[path: ":memory:", name: db]]}
    })

    :ok =
      DB.execute(db, """
      CREATE TABLE turns (
        seq INTEGER PRIMARY KEY AUTOINCREMENT, sessionKey TEXT NOT NULL,
        messageId TEXT NOT NULL, wakeId TEXT UNIQUE, origin TEXT NOT NULL,
        prompt TEXT NOT NULL, roleRef TEXT, roleFallback INTEGER NOT NULL DEFAULT 0,
        status TEXT NOT NULL DEFAULT 'queued', owner TEXT, adapterGen INTEGER,
        requestRef TEXT, error TEXT, createdAt INTEGER NOT NULL, startedAt INTEGER,
        endedAt INTEGER, publishedAt INTEGER
      );
      INSERT INTO turns
        (sessionKey, messageId, origin, prompt, createdAt)
      VALUES ('legacy', 'm_old', 'user:test', 'preserve', 7);
      """)

    assert {:ok, [[root_before]]} =
             DB.query(
               db,
               "SELECT rootpage FROM sqlite_master WHERE type='table' AND name='turns'"
             )

    assert :ok = Ledger.ensure_schema(db)

    assert {:ok, [[root_after]]} =
             DB.query(
               db,
               "SELECT rootpage FROM sqlite_master WHERE type='table' AND name='turns'"
             )

    assert root_after == root_before

    assert {:ok, columns} = DB.query(db, "PRAGMA table_info(turns)")

    trace_columns =
      for [_cid, name, _type, not_null, default, _pk] <- columns,
          name in ~w(assignmentId jobRef model harness),
          do: {name, not_null, default}

    assert trace_columns == [
             {"assignmentId", 0, nil},
             {"jobRef", 0, nil},
             {"model", 0, nil},
             {"harness", 0, nil}
           ]

    assert {:ok, [["legacy", "m_old", "preserve", nil, nil, nil, nil]]} =
             DB.query(
               db,
               "SELECT sessionKey, messageId, prompt, assignmentId, jobRef, model, harness FROM turns"
             )

    assert {:ok, indexes} = DB.query(db, "PRAGMA index_list(turns)")
    index_names = Enum.map(indexes, &Enum.at(&1, 1))
    assert "turns_job_ref" in index_names
    assert "turns_assignment_id" in index_names
  end
end
