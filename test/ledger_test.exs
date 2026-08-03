defmodule Tightbeam.LedgerTest do
  use Tightbeam.TestCase, async: false

  alias Tightbeam.{DB, Ledger}

  setup do
    name = :"db_#{System.unique_integer([:positive])}"
    start_supervised!({DB, path: ":memory:", name: name})
    :ok = ensure_all_schemas(name)
    create_test_sessions(name)
    %{db: name}
  end

  defp create_test_sessions(db) do
    :ok =
      DB.execute(db, """
      INSERT INTO sessions
        (sessionKey, displayName, ownerUserId, origin, archetype, identityName,
         harness, provider, model, thinkingLevel, modelContext, createdAt, updatedAt)
      VALUES
        ('k1', 'K1', 'flynn', 'user:flynn', 'default', 'default',
         'claude', 'anthropic', 'claude-sonnet-5', 'medium', NULL, 1, 1),
        ('k2', 'K2', 'flynn', 'user:flynn', 'default', 'default',
         'claude', 'anthropic', 'claude-sonnet-5', 'medium', NULL, 1, 1);
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

  # The stamp is the WHOLE identity, in fields. A context variant and a
  # reasoning level are different questions, and a turn's provenance has to be
  # able to tell `gpt-5.6-sol` at high from the same model at medium, and from
  # its 1M-context sibling. Reading back only model+harness would pass with the
  # effort and context columns never written at all.
  test "claim stamps every field of the session's selected mind after a tune",
       %{db: db} do
    first = enqueue!(db, "k1", "before tune")

    assert {:ok, [["queued", nil, nil, nil, nil]]} = mind(db, first)

    :ok =
      DB.execute(
        db,
        """
        UPDATE sessions
        SET model='gpt-5.6-sol', thinkingLevel='high', modelContext='1m', harness='codex'
        WHERE sessionKey='k1'
        """
      )

    assert {:ok, %{seq: ^first}} = Ledger.claim_next(db, "k1", "lane")

    assert {:ok, [["running", "gpt-5.6-sol", "high", "1m", "codex"]]} = mind(db, first)

    # The trace reads TERMINAL turns — the stamp must survive terminalization.
    :ok = Ledger.finish(db, first, "delivered")

    assert {:ok, [["delivered", "gpt-5.6-sol", "high", "1m", "codex"]]} = mind(db, first)
  end

  defp mind(db, seq) do
    DB.query(
      db,
      "SELECT status, model, thinkingLevel, modelContext, harness FROM turns WHERE seq = ?1",
      [seq]
    )
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

  test "fresh schema has trace columns and indexes and is idempotent", %{db: db} do
    assert :ok = Ledger.ensure_schema(db)
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

    assert {:ok, indexes} = DB.query(db, "PRAGMA index_list(turns)")
    index_names = Enum.map(indexes, &Enum.at(&1, 1))
    assert "turns_job_ref" in index_names
    assert "turns_assignment_id" in index_names
  end
end
