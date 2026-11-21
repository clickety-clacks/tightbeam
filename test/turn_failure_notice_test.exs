defmodule Tightbeam.TurnFailureNoticeTest do
  use Tightbeam.TestCase, async: false

  alias Tightbeam.{ConnRegistry, DB, Ledger, Model, Org, Wakes}

  alias Tightbeam.Productions.Bubble

  @limit_429 "API error: 429 This request would exceed your account's rate limit. " <>
               "Please try again later · model not changed"

  defmodule LaneDoorbell do
    use GenServer
    def start_link(name), do: GenServer.start_link(__MODULE__, :ok, name: name)
    def init(state), do: {:ok, state}
    def handle_call({:ensure_lane, _key}, _from, state), do: {:reply, :ok, state}
    def handle_cast({:ensure_lane, _key}, state), do: {:noreply, state}
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

    db = :"turn_failure_notice_db_#{System.unique_integer([:positive])}"
    start_supervised!({DB, path: ":memory:", name: db})
    :ok = Tightbeam.Schema.ensure_all(db)

    {:ok, _} =
      DB.query(db, "INSERT INTO users (userId, isAdmin, createdAt) VALUES ('flynn', 1, 1)")

    main = session(db, Org.personal_session_key("flynn"), nil, true)
    lane = session(db, "agent:lane", main.session_key)
    reviewer = session(db, "agent:reviewer", lane.session_key)
    assignment = assignment!(db, "asg_review", reviewer.session_key, lane.session_key)

    %{db: db, main: main, lane: lane, reviewer: reviewer, assignment: assignment}
  end

  test "automatic retries of one failed delivery notify once, not per attempt", ctx do
    wake =
      Wakes.schedule(ctx.db, %{
        session_key: ctx.reviewer.session_key,
        origin: "agent:lane",
        creator_session_key: ctx.lane.session_key,
        prompt: "review the change",
        due_at: 1,
        assignment_id: ctx.assignment
      })

    first =
      failed_turn!(ctx.db, ctx.reviewer.session_key,
        assignment_id: ctx.assignment,
        wake_id: wake.wake_id,
        error: @limit_429
      )

    assert :ok = Bubble.recognize_terminal(ctx.db, first)
    assert {:retry, retry_wake_id} = preserve_failed_intent!(ctx.db, first)

    assert {:ok, []} =
             DB.query(ctx.db, "UPDATE assignments SET currentOpenerSessionKey=?1 WHERE id=?2", [
               ctx.main.session_key,
               ctx.assignment
             ])

    retried =
      failed_turn!(ctx.db, ctx.reviewer.session_key,
        assignment_id: ctx.assignment,
        wake_id: retry_wake_id,
        error: @limit_429
      )

    assert :ok = Bubble.recognize_terminal(ctx.db, retried)
    assert :ok = Bubble.recognize_terminal(ctx.db, first)
    assert [{recipient, prompt}] = notices(ctx.db)
    assert recipient == ctx.lane.session_key
    assert prompt =~ @limit_429
  end

  test "health redelivery of a failed batch carrier retains its notice identity", ctx do
    wake =
      Wakes.schedule(ctx.db, %{
        session_key: ctx.reviewer.session_key,
        origin: "process:tightbeam",
        prompt: "a sealed batch",
        due_at: 1,
        digest: true
      })

    first =
      failed_turn!(ctx.db, ctx.reviewer.session_key,
        assignment_id: ctx.assignment,
        wake_id: wake.wake_id,
        error: @limit_429
      )

    assert :ok = Bubble.recognize_terminal(ctx.db, first)

    assert {:ok, 1} =
             DB.transaction(ctx.db, fn txn ->
               Wakes.record_health_redelivery_source_in_txn(txn, first, "rate-limit-dead")
               Wakes.redeliver_pending_health_intents_in_txn(txn, ctx.reviewer, %{seq: first + 1})
             end)

    assert {:ok, retried} = Ledger.claim_next(ctx.db, ctx.reviewer.session_key, "notice-test")
    assert retried.wake_id == nil

    assert :ok =
             Ledger.finish(ctx.db, retried.seq, "failed", @limit_429,
               owner_lease: retried.owner_lease
             )

    assert :ok = Bubble.recognize_terminal(ctx.db, retried.seq)
    assert [{recipient, prompt}] = notices(ctx.db)
    assert recipient == ctx.lane.session_key
    assert prompt =~ @limit_429
  end

  test "a new failed delivery after an earlier one is its own notice", ctx do
    first =
      failed_turn!(ctx.db, ctx.reviewer.session_key,
        assignment_id: ctx.assignment,
        error: @limit_429
      )

    second =
      failed_turn!(ctx.db, ctx.reviewer.session_key,
        assignment_id: ctx.assignment,
        error: @limit_429
      )

    assert :ok = Bubble.recognize_terminal(ctx.db, first)
    assert :ok = Bubble.recognize_terminal(ctx.db, second)
    assert length(notices(ctx.db)) == 2
  end

  test "a failed turn with no assignment goes to the session's current parent", ctx do
    seq = failed_turn!(ctx.db, ctx.reviewer.session_key, error: "adapter died")
    assert :ok = Bubble.recognize_terminal(ctx.db, seq)
    assert [{recipient, prompt}] = notices(ctx.db)
    assert recipient == ctx.lane.session_key
    assert prompt =~ "adapter died"
  end

  test "a parentless worker's failure reaches the owner's active main session", ctx do
    worker = session(ctx.db, "agent:parentless", nil)
    seq = failed_turn!(ctx.db, worker.session_key, error: "adapter died")

    assert :ok = Bubble.recognize_terminal(ctx.db, seq)
    assert [{recipient, prompt}] = notices(ctx.db)
    assert recipient == ctx.main.session_key
    assert prompt =~ "adapter died"
  end

  test "an existing interrupted-outcome question owns the notice", ctx do
    seq =
      failed_turn!(ctx.db, ctx.reviewer.session_key,
        assignment_id: ctx.assignment,
        prompt: "[assignment: #{ctx.assignment}]\n\nreview the change",
        error: "interrupted: outcome unknown"
      )

    assert {:ok, :ok} =
             DB.transaction(ctx.db, fn txn ->
               Wakes.record_health_redelivery_source_in_txn(
                 txn,
                 seq,
                 "interrupted-outcome-unknown"
               )
             end)

    assert :ok = Bubble.recognize_terminal(ctx.db, seq)
    assert notices(ctx.db) == []

    assert {:ok, []} =
             DB.query(
               ctx.db,
               "SELECT 1 FROM messages WHERE sessionKey=?1 AND clientMessageId=?2",
               [
                 ctx.lane.session_key,
                 "wake-undelivered:#{seq}"
               ]
             )

    wake = Wakes.get(ctx.db, "w_health_redelivery_parent_#{seq}")
    assert wake.session_key == ctx.lane.session_key
    assert wake.prompt =~ "Reason: interrupted: outcome unknown"
  end

  test "a retired opener falls back to the session's current parent", ctx do
    other = session(ctx.db, "agent:other-opener", ctx.main.session_key)
    asg = assignment!(ctx.db, "asg_retired_opener", ctx.reviewer.session_key, other.session_key)

    {:ok, _} =
      DB.query(ctx.db, "UPDATE sessions SET state='retired' WHERE sessionKey=?1", [
        other.session_key
      ])

    assert {:ok, []} =
             DB.query(ctx.db, "UPDATE sessions SET state='retired' WHERE sessionKey=?1", [
               ctx.lane.session_key
             ])

    seq = failed_turn!(ctx.db, ctx.reviewer.session_key, assignment_id: asg, error: @limit_429)
    assert :ok = Bubble.recognize_terminal(ctx.db, seq)
    assert [{recipient, prompt}] = notices(ctx.db)
    assert recipient == ctx.main.session_key
    assert prompt =~ @limit_429
  end

  defp notices(db) do
    {:ok, rows} =
      DB.query(
        db,
        """
        SELECT sessionKey,prompt FROM turns
        WHERE wakeId LIKE 'bubble:%' OR wakeId LIKE 'w_turn_failure_%'
        UNION ALL
        SELECT sessionKey,prompt FROM wakes
        WHERE (wakeId LIKE 'bubble:%' OR wakeId LIKE 'w_turn_failure_%')
          AND NOT EXISTS (SELECT 1 FROM turns WHERE turns.wakeId=wakes.wakeId)
        """
      )

    Enum.map(rows, &List.to_tuple/1)
  end

  defp preserve_failed_intent!(db, seq) do
    {:ok, result} = DB.transaction(db, &Wakes.preserve_failed_intent_for_terminal_in_txn(&1, seq))
    result
  end

  defp failed_turn!(db, session_key, opts) do
    unique = System.unique_integer([:positive])

    {:ok, seq} =
      Ledger.enqueue(db, %{
        session_key: session_key,
        message_id: "notice-#{unique}",
        origin: "agent:lane",
        prompt: Keyword.get(opts, :prompt, "review the change"),
        wake_id: Keyword.get(opts, :wake_id),
        assignment_id: Keyword.get(opts, :assignment_id),
        request_ref: nil
      })

    {:ok, turn} = Ledger.claim_next(db, session_key, "notice-test")
    assert turn.seq == seq

    assert :ok =
             Ledger.finish(
               db,
               seq,
               Keyword.get(opts, :status, "failed"),
               Keyword.get(opts, :error, "provider failure"),
               owner_lease: turn.owner_lease
             )

    {:ok, _} = DB.query(db, "UPDATE turns SET endedAt=10 WHERE seq=?1", [seq])
    seq
  end

  defp assignment!(db, id, holder, opener) do
    {:ok, []} =
      DB.query(
        db,
        """
        INSERT INTO assignments
          (id,subject,holderKey,openedBySession,openedAt,state,holderHarness,holderProvider)
        VALUES (?1,'review the change',?2,?3,1,'open','claude','anthropic')
        """,
        [id, holder, opener]
      )

    id
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
end
