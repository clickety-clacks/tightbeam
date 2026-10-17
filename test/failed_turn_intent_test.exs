defmodule Tightbeam.FailedTurnIntentTest do
  use Tightbeam.TestCase, async: false

  alias Tightbeam.{ConnRegistry, DB, Ledger, Model, Org, Wakes}

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
        "INSERT INTO users (userId, isAdmin, createdAt) VALUES ('flynn', 1, 1)"
      )

    main = session(db, Org.personal_session_key("flynn"), nil, true)
    parent = session(db, "parent", main.session_key)
    child = session(db, "child", parent.session_key)

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

    assert {:retry, retry_id} = preserve_failed_intent!(ctx.db, seq)
    assert {:retry, ^retry_id} = preserve_failed_intent!(ctx.db, seq)

    assert {:ok, [[root, 0, ^seq, "failed", ^retry_id]]} =
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

    assert :not_retryable = preserve_failed_intent!(ctx.db, seq)

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

    assert {:retry, _retry_id} = preserve_failed_intent!(ctx.db, seq)

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

  defp preserve_failed_intent!(db, seq) do
    DB.transaction(db, &Wakes.preserve_failed_intent_for_terminal_in_txn(&1, seq))
    |> case do
      {:ok, result} -> result
      {:error, error} -> raise error
    end
  end

  defp session(db, key, parent, built_in? \\ false, owner \\ "flynn") do
    Org.create(db, %{
      session_key: key,
      display_name: key,
      kind: if(built_in?, do: "main", else: "custom"),
      owner_user_id: owner,
      origin: "user:#{owner}",
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

    assert :ok = Ledger.finish(db, seq, status, error, owner_lease: turn.owner_lease)

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
