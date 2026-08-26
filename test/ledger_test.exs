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
        (sessionKey, displayName, kind, isBuiltIn, ownerUserId, origin, operationalParent,
         archetype, identityName,
         harness, provider, model, thinkingLevel, modelContext, createdAt, updatedAt)
      VALUES
        ('ledger-main', 'Ledger Main', 'main', 1, 'flynn', 'user:flynn',
         'ledger-main', 'default', 'default',
         'claude', 'anthropic', 'claude-sonnet-5', 'medium', NULL, 1, 1),
        ('k1', 'K1', 'custom', 0, 'flynn', 'user:flynn',
         'ledger-main', 'default', 'default',
         'claude', 'anthropic', 'claude-sonnet-5', 'medium', NULL, 1, 1),
        ('k2', 'K2', 'custom', 0, 'flynn', 'user:flynn',
         'ledger-main', 'default', 'default',
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

    :ok = Ledger.finish(db, t.seq, "delivered", nil, owner_lease: t.owner_lease)
    {:ok, t2} = Ledger.claim_next(db, "k1", "lane")
    assert t2.prompt == "b"
    assert :none = Ledger.claim_next(db, "k2", "lane")
  end

  test "exactly-one durable terminal transition (CAS)", %{db: db} do
    enqueue!(db, "k1", "a")
    {:ok, t} = Ledger.claim_next(db, "k1", "lane")

    assert :ok = Ledger.finish(db, t.seq, "delivered", nil, owner_lease: t.owner_lease)

    assert :already_terminal =
             Ledger.finish(db, t.seq, "failed", nil, owner_lease: t.owner_lease)
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

    assert {:ok, %{seq: ^first, owner_lease: lease}} = Ledger.claim_next(db, "k1", "lane")

    assert {:ok, [["running", "gpt-5.6-sol", "high", "1m", "codex"]]} = mind(db, first)

    # The trace reads TERMINAL turns — the stamp must survive terminalization.
    :ok = Ledger.finish(db, first, "delivered", nil, owner_lease: lease)

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
    :ok = Ledger.finish(db, t.seq, "delivered", nil, owner_lease: t.owner_lease)

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

  # The single writer every turn passes through. `Org.personal_session_key/1`
  # COMPOSES a key from a user id, so a well-formed address can name no session
  # at all — and the enqueue that accepts one has already lost the prompt.
  test "enqueue refuses a turn addressed to a session that has no row", %{db: db} do
    assert {:error, :no_session} =
             Ledger.enqueue(db, %{
               session_key: "agent:main:clawline:flynn:main",
               message_id: "m-phantom",
               origin: "process:tightbeam",
               prompt: "a prompt nobody can claim"
             })

    assert {:ok, [[0]]} = DB.query(db, "SELECT COUNT(*) FROM turns")
  end

  # The guard is EXISTENCE, not activeness, and this is the line it must not
  # cross: a `targetGate = 0` decision notice delivers to a retired target by
  # design, and spec escalation-delivery-v1 forbids an active-session gate on
  # that path. The retired target's turn is unclaimable all the same — naming it
  # is `claim_next/3`'s job, not this write's.
  test "enqueue still accepts a notice addressed to a retired session", %{db: db} do
    :ok = DB.execute(db, "UPDATE sessions SET state = 'retired' WHERE sessionKey = 'k2'")

    assert {:ok, _seq} =
             Ledger.enqueue(db, %{
               session_key: "k2",
               message_id: "m-retired",
               origin: "process:tightbeam",
               prompt: "a decision that outlived its session"
             })

    assert {:unclaimable, :session_retired} = Ledger.claim_next(db, "k2", "lane")
  end

  # `:none` meaning both "nothing queued" and "queued work nobody can ever
  # claim" is what let six orphaned turns look like an idle queue for hours.
  test "claim_next separates an empty queue from work nobody can claim", %{db: db} do
    assert :none = Ledger.claim_next(db, "k1", "lane")

    insert_orphan_turn(db, "agent:main:clawline:flynn:main")

    assert {:unclaimable, :no_session} =
             Ledger.claim_next(db, "agent:main:clawline:flynn:main", "lane")
  end

  test "unclaimable turns age into failed carrying the reason", %{db: db} do
    seq = insert_orphan_turn(db, "agent:main:clawline:flynn:main")

    assert [^seq] =
             Ledger.fail_unclaimable(db, "agent:main:clawline:flynn:main", :no_session)

    assert {:ok, [["failed", error]]} =
             DB.query(db, "SELECT status, error FROM turns WHERE seq = ?1", [seq])

    assert error =~ "no session row"

    # The named terminal rides the existing at-least-once publication feed.
    assert [%{seq: ^seq, status: "failed"}] = Ledger.unpublished_terminals(db)
    assert Ledger.fail_unclaimable(db, "agent:main:clawline:flynn:main", :no_session) == []
  end

  # Review finding 3. The diagnosis and the failure are separate transactions,
  # so the cause has to be re-asserted by the UPDATE itself. A session created
  # in that window makes the turn claimable again, and aging it anyway destroys
  # live work on the strength of a reading that had already expired.
  test "a session appearing after the diagnosis spares its turn", %{db: db} do
    seq = insert_orphan_turn(db, "agent:main:clawline:flynn:main")

    assert {:unclaimable, :no_session} =
             Ledger.claim_next(db, "agent:main:clawline:flynn:main", "lane")

    :ok =
      DB.execute(db, """
      INSERT INTO sessions
        (sessionKey, displayName, kind, isBuiltIn, ownerUserId, origin, operationalParent,
         archetype, identityName,
         harness, provider, model, thinkingLevel, modelContext, createdAt, updatedAt)
      VALUES
        ('agent:main:clawline:flynn:main', 'Flynn', 'main', 1, 'flynn', 'user:flynn',
         'agent:main:clawline:flynn:main', 'default',
         'default', 'claude', 'anthropic', 'claude-sonnet-5', 'medium', NULL, 1, 1);
      """)

    assert Ledger.fail_unclaimable(db, "agent:main:clawline:flynn:main", :no_session) == []
    assert {:ok, [["queued"]]} = DB.query(db, "SELECT status FROM turns WHERE seq = ?1", [seq])
    assert {:ok, %{seq: ^seq}} = Ledger.claim_next(db, "agent:main:clawline:flynn:main", "lane")
  end

  # Re-review finding. Identifying the aged rows by the error string this
  # function itself wrote makes a second aging re-report the first batch, so the
  # lane announces rows it did not touch. Only the statement that did the work
  # knows what it did.
  test "aging reports the rows it transitioned, never a previous batch", %{db: db} do
    first = insert_orphan_turn(db, "agent:main:clawline:flynn:main")
    assert [^first] = Ledger.fail_unclaimable(db, "agent:main:clawline:flynn:main", :no_session)

    second = insert_orphan_turn(db, "agent:main:clawline:flynn:main")
    assert [^second] = Ledger.fail_unclaimable(db, "agent:main:clawline:flynn:main", :no_session)
  end

  # A turn the ledger would refuse today, written the way the pre-guard gateway
  # wrote it — the reproduction for the ORPHANS already in a live database.
  defp insert_orphan_turn(db, session_key) do
    :ok =
      DB.execute(db, """
        INSERT INTO turns (sessionKey, messageId, origin, prompt, createdAt)
        VALUES ('#{session_key}', 'm_#{System.unique_integer([:positive])}',
                'process:tightbeam', 'orphan', 1)
      """)

    {:ok, [[seq]]} =
      DB.query(db, "SELECT seq FROM turns WHERE sessionKey = ?1 ORDER BY seq DESC LIMIT 1", [
        session_key
      ])

    seq
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
