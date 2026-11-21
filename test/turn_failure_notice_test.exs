defmodule Tightbeam.TurnFailureNoticeTest do
  use Tightbeam.TestCase, async: false

  alias Tightbeam.{ConnRegistry, DB, Ledger, Model, Org, TurnFailureNotice, Wakes}

  @limit_429 "API error: 429 This request would exceed your account's rate limit. " <>
               "Please try again later · model not changed"

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

  test "a failed first turn tells the assignment's opener the verbatim reason", ctx do
    seq = failed_turn!(ctx.db, ctx.reviewer.session_key, assignment_id: ctx.assignment)

    assert {:scheduled, wake_id} = notify!(ctx.db, seq, @limit_429)

    wake = Wakes.get(ctx.db, wake_id)
    assert wake.session_key == ctx.lane.session_key
    assert wake.consumer == "prompt"
    assert wake.class == "blocker"
    assert wake.prompt =~ "Reason: " <> @limit_429 <> "\n"
    assert wake.prompt =~ "assignment #{ctx.assignment}"
    assert wake.prompt =~ ctx.reviewer.session_key
    assert wake.prompt =~ "model fable"

    assert notices(ctx.db) == [ctx.lane.session_key]
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

    assert {:scheduled, notice} = notify!(ctx.db, first, @limit_429)
    assert {:retry, retry_wake_id} = preserve_failed_intent!(ctx.db, first)

    retried =
      failed_turn!(ctx.db, ctx.reviewer.session_key,
        assignment_id: ctx.assignment,
        wake_id: retry_wake_id,
        error: @limit_429
      )

    assert :duplicate = notify!(ctx.db, retried, @limit_429)
    # The same terminal committing twice cannot double-notify either.
    assert :duplicate = notify!(ctx.db, first, @limit_429)

    assert notices(ctx.db) == [ctx.lane.session_key]
    assert Wakes.get(ctx.db, notice).session_key == ctx.lane.session_key
  end

  test "a new failed delivery after an earlier one is its own notice", ctx do
    first = failed_turn!(ctx.db, ctx.reviewer.session_key, assignment_id: ctx.assignment)
    second = failed_turn!(ctx.db, ctx.reviewer.session_key, assignment_id: ctx.assignment)

    assert {:scheduled, a} = notify!(ctx.db, first, "first reason")
    assert {:scheduled, b} = notify!(ctx.db, second, "second reason")
    assert a != b
    assert length(notices(ctx.db)) == 2
  end

  test "a failed turn with no assignment goes to the session's current parent", ctx do
    seq = failed_turn!(ctx.db, ctx.reviewer.session_key)

    assert {:scheduled, wake_id} = notify!(ctx.db, seq, "adapter died")
    assert Wakes.get(ctx.db, wake_id).session_key == ctx.lane.session_key
  end

  test "the recorded error is the reason when the caller has no sentence", ctx do
    seq = failed_turn!(ctx.db, ctx.reviewer.session_key, error: "turn task crashed: boom")

    assert {:scheduled, wake_id} = notify!(ctx.db, seq, nil)
    assert Wakes.get(ctx.db, wake_id).prompt =~ "Reason: turn task crashed: boom\n"
  end

  test "nobody else accountable, a delivered turn, or an interrupted turn sends nothing", ctx do
    orphan = session(ctx.db, "agent:orphan", nil)
    self_opened = assignment!(ctx.db, "asg_self", orphan.session_key, orphan.session_key)
    seq = failed_turn!(ctx.db, orphan.session_key, assignment_id: self_opened)
    assert :none = notify!(ctx.db, seq, "boom")

    delivered = failed_turn!(ctx.db, ctx.reviewer.session_key, status: "delivered", error: nil)
    assert :none = notify!(ctx.db, delivered, nil)

    # interrupted-outcome-unknown already asks the parent whether to redeliver.
    interrupted = failed_turn!(ctx.db, ctx.reviewer.session_key, assignment_id: ctx.assignment)
    assert :none = notify!(ctx.db, interrupted, "interrupted: outcome unknown")

    assert notices(ctx.db) == []
  end

  test "a retired opener falls back to the session's current parent", ctx do
    other = session(ctx.db, "agent:other-opener", ctx.main.session_key)
    asg = assignment!(ctx.db, "asg_retired_opener", ctx.reviewer.session_key, other.session_key)

    {:ok, _} =
      DB.query(ctx.db, "UPDATE sessions SET state='retired' WHERE sessionKey=?1", [
        other.session_key
      ])

    seq = failed_turn!(ctx.db, ctx.reviewer.session_key, assignment_id: asg)
    assert {:scheduled, wake_id} = notify!(ctx.db, seq, "boom")
    assert Wakes.get(ctx.db, wake_id).session_key == ctx.lane.session_key
  end

  defp notify!(db, seq, sentence) do
    {:ok, result} = DB.transaction(db, &TurnFailureNotice.schedule_in_txn(&1, seq, sentence))
    result
  end

  defp notices(db) do
    {:ok, rows} =
      DB.query(
        db,
        "SELECT sessionKey FROM wakes WHERE wakeId LIKE 'w_turn_failure_%' ORDER BY createdAt,wakeId"
      )

    List.flatten(rows)
  end

  defp preserve_failed_intent!(db, seq) do
    {:ok, result} = DB.transaction(db, &Wakes.preserve_failed_intent_for_terminal_in_txn(&1, seq))
    result
  end

  defp failed_turn!(db, session_key, opts \\ []) do
    unique = System.unique_integer([:positive])

    {:ok, seq} =
      Ledger.enqueue(db, %{
        session_key: session_key,
        message_id: "notice-#{unique}",
        origin: "agent:lane",
        prompt: "review the change",
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
