defmodule Tightbeam.FailedTurnIntentTest do
  use Tightbeam.TestCase, async: false

  alias Tightbeam.{ConnRegistry, DB, Ledger, Model, Org, Supervision, Wakes}

  defmodule LaneDoorbell do
    use GenServer
    def start_link(name), do: GenServer.start_link(__MODULE__, :ok, name: name)
    def init(state), do: {:ok, state}
    def handle_call({:ensure_lane, _key}, _from, state), do: {:reply, :ok, state}
  end

  setup do
    case ConnRegistry.start_link(name: Tightbeam.ConnRegistry) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end

    case LaneDoorbell.start_link(Tightbeam.LaneManager) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end

    db = :"failed_intent_db_#{System.unique_integer([:positive])}"
    start_supervised!({DB, path: ":memory:", name: db})
    :ok = Tightbeam.Schema.ensure_all(db)

    {:ok, _} =
      DB.query(
        db,
        "INSERT INTO users (userId, isAdmin, creationKind, createdAt) VALUES ('flynn', 1, 'admin_add', 1)"
      )

    main = session(db, Org.personal_session_key("flynn"), nil, true)
    parent = session(db, "parent", main.session_key)
    child = session(db, "child", parent.session_key)

    supervision = :"failed_intent_supervision_#{System.unique_integer([:positive])}"

    start_supervised!(
      {Supervision,
       db: db, handlers: %{}, prod_limit: 3, sweep_ms: 60_000, recover: false, name: supervision}
    )

    _ = :sys.get_state(supervision)

    %{db: db, parent: parent, child: child}
  end

  test "a rate-limited wake keeps one deterministic pending successor", ctx do
    wake =
      Wakes.schedule(ctx.db, %{
        session_key: ctx.child.session_key,
        origin: "agent:sender",
        prompt: "continue the work",
        due_at: 1
      })

    {:ok, _} =
      DB.query(ctx.db, "UPDATE wakes SET state='fired', firedAt=10 WHERE wakeId=?1", [
        wake.wake_id
      ])

    seq = terminal!(ctx.db, ctx.child.session_key, "failed", "provider rate limit", wake.wake_id)

    assert :ok = Supervision.classify_terminal(ctx.db, seq)
    assert :ok = Supervision.classify_terminal(ctx.db, seq)

    assert {:ok, [[root, 0, ^seq, "failed", retry_id]]} =
             DB.query(
               ctx.db,
               "SELECT rootWakeId, attempt, sourceTurnSeq, outcome, retryWakeId FROM wake_retry_attempts WHERE wakeId=?1",
               [wake.wake_id]
             )

    assert root == wake.wake_id

    assert {:ok, [[^retry_id, ^root, 1, "pending", 30_010, "intent prompt"]]} =
             DB.query(
               ctx.db,
               """
               SELECT r.wakeId, r.rootWakeId, r.attempt, r.outcome, w.dueAt, w.prompt
               FROM wake_retry_attempts r JOIN wakes w ON w.wakeId=r.wakeId
               WHERE r.predecessorWakeId=?1
               """,
               [wake.wake_id]
             )

    assert String.starts_with?(retry_id, "wr_")

    assert {:accepted_in_txn, _event_id, %{canceled: true}} =
             public_cancel(ctx.db, wake.wake_id, "agent:sender")

    assert Wakes.get(ctx.db, retry_id).state == "canceled"

    assert {:ok, [["canceled"]]} =
             DB.query(ctx.db, "SELECT outcome FROM wake_retry_attempts WHERE wakeId=?1", [
               retry_id
             ])
  end

  test "a non-rate-limit failure is not retried without a safe run boundary", ctx do
    wake =
      Wakes.schedule(ctx.db, %{
        session_key: ctx.child.session_key,
        origin: "agent:sender",
        prompt: "continue the work",
        due_at: 1
      })

    seq =
      terminal!(
        ctx.db,
        ctx.child.session_key,
        "failed",
        "tool failed after running",
        wake.wake_id
      )

    assert :ok = Supervision.classify_terminal(ctx.db, seq)

    assert {:ok, [[0]]} = DB.query(ctx.db, "SELECT COUNT(*) FROM wake_retry_attempts")
  end

  test "an assignment-bound rate-limit retry preserves work lineage", ctx do
    wake =
      Wakes.schedule(ctx.db, %{
        session_key: ctx.child.session_key,
        origin: "agent:sender",
        prompt: "continue assigned work",
        due_at: 1,
        work_item_id: "wi_repro",
        assignment_id: "asg_repro"
      })

    seq = terminal!(ctx.db, ctx.child.session_key, "failed", "provider rate limit", wake.wake_id)

    assert :ok = Supervision.classify_terminal(ctx.db, seq)

    assert {:ok, [["wi_repro", "asg_repro"]]} =
             DB.query(
               ctx.db,
               """
               SELECT w.work_item_id, w.assignmentId
               FROM wake_retry_attempts r
               JOIN wakes w ON w.wakeId=r.retryWakeId
               WHERE r.wakeId=?1
               """,
               [wake.wake_id]
             )
  end

  test "two boot sweeps leave predecessor terminal history unclassified" do
    db = :"legacy_failed_intent_db_#{System.unique_integer([:positive])}"

    start_supervised!(%{
      id: db,
      start: {DB, :start_link, [[path: ":memory:", name: db]]}
    })

    :ok = Tightbeam.Schema.ensure_all(db)

    {:ok, _} =
      DB.query(
        db,
        "INSERT INTO users (userId, isAdmin, creationKind, createdAt) VALUES ('legacy-owner', 1, 'admin_add', 1)"
      )

    legacy = session(db, Org.personal_session_key("legacy-owner"), nil, true)
    legacy_seq = terminal!(db, legacy.session_key, "failed", "provider rate limit")

    assert {:ok, []} = DB.query(db, "SELECT firstTurnSeq FROM patrol_failure_boundary")

    supervision = :"legacy_failed_intent_supervision_#{System.unique_integer([:positive])}"

    start_supervised!(%{
      id: supervision,
      start:
        {Supervision, :start_link,
         [
           [
             db: db,
             handlers: %{},
             prod_limit: 3,
             sweep_ms: 60_000,
             recover: false,
             name: supervision
           ]
         ]}
    })

    _ = :sys.get_state(supervision)
    Supervision.request_sweep(supervision)
    _ = :sys.get_state(supervision)

    assert {:ok, [[first_turn_seq]]} =
             DB.query(db, "SELECT firstTurnSeq FROM patrol_failure_boundary WHERE id=0")

    assert first_turn_seq == legacy_seq + 1
    assert {:ok, [[0]]} = DB.query(db, "SELECT COUNT(*) FROM patrol_terminal_classifications")
    assert {:ok, [[0]]} = DB.query(db, "SELECT COUNT(*) FROM patrol_failure_streaks")
    assert {:ok, [[0]]} = DB.query(db, "SELECT COUNT(*) FROM patrol_failure_escalations")
  end

  test "six consecutive ordinary failures route one patrol cause to the parent", ctx do
    seqs =
      for n <- 1..6 do
        seq = terminal!(ctx.db, ctx.child.session_key, "failed", "provider failure #{n}")
        assert :ok = Supervision.classify_terminal(ctx.db, seq)
        seq
      end

    assert {:ok, [[1]]} = DB.query(ctx.db, "SELECT COUNT(*) FROM patrol_failure_escalations")

    assert {:ok, [[escalation_id, 6, first_seq, threshold_seq, "admitted", "parent"]]} =
             DB.query(
               ctx.db,
               """
               SELECT e.id, s.failureCount, e.firstTurnSeq,
                      e.thresholdTurnSeq, e.state, e.firstRecipient
               FROM patrol_failure_escalations e
               JOIN patrol_failure_streaks s ON s.escalationId=e.id
               """
             )

    assert first_seq == hd(seqs)
    assert threshold_seq == List.last(seqs)

    assert {:ok, [["parent", "queued", request_ref, wake_id]]} =
             DB.query(
               ctx.db,
               """
               SELECT sessionKey, status, requestRef, wakeId FROM turns
               WHERE requestRef LIKE 'bubble:patrol:%'
               """
             )

    assert request_ref == "bubble:patrol:#{escalation_id}"
    assert wake_id == "bubble:patrol:#{escalation_id}:parent"

    {:ok, notice} = Ledger.claim_next(ctx.db, ctx.parent.session_key, "notice-test")

    assert :ok =
             Ledger.finish(ctx.db, notice.seq, "failed", "parent could not run",
               owner_lease: notice.owner_lease,
               cause: "test"
             )

    assert :ok = Supervision.classify_terminal(ctx.db, notice.seq)
    assert :ok = Tightbeam.Productions.Bubble.recognize_terminal(ctx.db, notice.seq)

    assert {:ok, [[main_key]]} =
             DB.query(
               ctx.db,
               "SELECT sessionKey FROM turns WHERE requestRef=?1 AND sessionKey != 'parent'",
               [request_ref]
             )

    assert main_key == Org.personal_session_key("flynn")

    assert {:ok, []} =
             DB.query(ctx.db, "SELECT 1 FROM patrol_failure_streaks WHERE sessionKey='parent'")

    Enum.each(seqs, &Supervision.classify_terminal(ctx.db, &1))
    seventh = terminal!(ctx.db, ctx.child.session_key, "failed", "another failure")
    assert :ok = Supervision.classify_terminal(ctx.db, seventh)

    assert {:ok, [[1, 2]]} =
             DB.query(
               ctx.db,
               """
               SELECT (SELECT COUNT(*) FROM patrol_failure_escalations),
                      (SELECT COUNT(*) FROM turns WHERE requestRef LIKE 'bubble:patrol:%')
               """
             )
  end

  test "delivered turns reset the streak and failed Bubble notices never join it", ctx do
    for n <- 1..5 do
      seq = terminal!(ctx.db, ctx.child.session_key, "failed", "first incident #{n}")
      assert :ok = Supervision.classify_terminal(ctx.db, seq)
    end

    delivered = terminal!(ctx.db, ctx.child.session_key, "delivered", nil)
    assert :ok = Supervision.classify_terminal(ctx.db, delivered)

    for n <- 1..5 do
      seq = terminal!(ctx.db, ctx.child.session_key, "failed", "second incident #{n}")
      assert :ok = Supervision.classify_terminal(ctx.db, seq)
    end

    for n <- 1..6 do
      seq =
        terminal!(
          ctx.db,
          ctx.parent.session_key,
          "failed",
          "notice failure #{n}",
          nil,
          "bubble:#{n}"
        )

      assert :ok = Supervision.classify_terminal(ctx.db, seq)
    end

    assert {:ok, [[0]]} = DB.query(ctx.db, "SELECT COUNT(*) FROM patrol_failure_escalations")

    assert {:ok, [[5]]} =
             DB.query(
               ctx.db,
               "SELECT failureCount FROM patrol_failure_streaks WHERE sessionKey='child'"
             )

    assert {:ok, []} =
             DB.query(ctx.db, "SELECT 1 FROM patrol_failure_streaks WHERE sessionKey='parent'")
  end

  defp session(db, key, parent, built_in? \\ false) do
    Org.create(db, %{
      session_key: key,
      display_name: key,
      kind: if(built_in?, do: "main", else: "custom"),
      owner_user_id: "flynn",
      origin: "user:flynn",
      archetype: "default",
      harness: "claude",
      provider: "anthropic",
      host: "testhost",
      model: Model.new("fable"),
      spawned_by: parent,
      operational_parent: parent,
      is_built_in: built_in?
    })
  end

  defp terminal!(db, session_key, status, error, wake_id \\ nil, request_ref \\ nil) do
    created_at = System.unique_integer([:positive])

    {:ok, seq} =
      Ledger.enqueue(db, %{
        session_key: session_key,
        message_id: "intent-#{created_at}",
        origin: "process:test",
        prompt: "intent prompt",
        wake_id: wake_id,
        request_ref: request_ref
      })

    {:ok, turn} = Ledger.claim_next(db, session_key, "intent-test")

    assert :ok =
             Ledger.finish(db, seq, status, error,
               owner_lease: turn.owner_lease,
               cause: "test"
             )

    {:ok, _} = DB.query(db, "UPDATE turns SET endedAt=10 WHERE seq=?1", [seq])
    seq
  end

  defp public_cancel(db, wake_id, expected_origin) do
    case DB.transaction(db, fn txn ->
           Wakes.cancel_in_txn(txn, %{
             wake_id: wake_id,
             expected_origin: expected_origin,
             requester: %{kind: "session", id: "test-session"},
             reason_kind: "requester_withdrew",
             causal_source: %{
               kind: "verb_call",
               accepted_event: %{
                 origin: expected_origin,
                 session_key: "test-session",
                 principal: {:session, "test-session"}
               }
             },
             outcome: %{kind: "no_replacement"}
           })
         end) do
      {:ok, result} -> result
      {:error, _} -> false
    end
  end
end
