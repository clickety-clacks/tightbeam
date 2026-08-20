defmodule Tightbeam.SupervisionTest do
  use Tightbeam.TestCase, async: false
  alias Tightbeam.Model

  alias Tightbeam.{
    Assignments,
    ConditionFacts,
    ConnRegistry,
    DB,
    EventLog,
    Gateway,
    Ledger,
    Org,
    PatrolResponse,
    Projection,
    RailRemedy,
    Roles,
    Rules,
    Schema,
    Supervision,
    Wakes
  }

  defmodule LaneDoorbell do
    use GenServer
    def start_link(name), do: GenServer.start_link(__MODULE__, :ok, name: name)
    def init(state), do: {:ok, state}
    def handle_call({:ensure_lane, _key}, _from, state), do: {:reply, :ok, state}
  end

  defmodule RaceLane do
    use GenServer
    def start_link({name, callback}), do: GenServer.start_link(__MODULE__, callback, name: name)
    def init(callback), do: {:ok, callback}

    def handle_call({:ensure_lane, key}, _from, callback) do
      callback.(key)
      {:reply, :ok, callback}
    end
  end

  defmodule ParkRaceDB do
    use GenServer

    def start_link({name, db, parent, transition}),
      do: GenServer.start_link(__MODULE__, {db, parent, transition}, name: name)

    def init({db, parent, transition}),
      do: {:ok, %{db: db, parent: parent, transition: transition, request_reads: 0}}

    def handle_call({:query, sql, _params} = request, _from, state) do
      result = GenServer.call(state.db, request)

      if current_request_query?(sql) do
        request_reads = state.request_reads + 1
        {:ok, [[id | _]]} = result

        if request_reads == 1 do
          transition_request(state.db, id, state.transition)
          send(state.parent, {:request_changed_before_park, state.transition, id})
        else
          send(state.parent, {:request_rechecked, state.transition, request_reads})
        end

        {:reply, result, %{state | request_reads: request_reads}}
      else
        {:reply, result, state}
      end
    end

    def handle_call(request, _from, state),
      do: {:reply, GenServer.call(state.db, request), state}

    # The gate read, identified by its SHAPE rather than by one adjacency: it is
    # the only `decision_requests` select that keys on `raiserId` and takes the
    # newest row. Written this way because the previous spelling required
    # `WHERE raiserId` to be adjacent, and stopped matching the moment the gate
    # read stated `kind = 'statute'` in front of it — a proxy that silently
    # matches nothing turns this whole race proof into a green no-op.
    defp current_request_query?(sql) do
      String.contains?(sql, "FROM decision_requests") and
        String.contains?(sql, "raiserId = ?1") and
        String.contains?(sql, "ORDER BY rowid DESC LIMIT 1")
    end

    defp transition_request(db, id, :rule_allow) do
      {:ok, _} =
        DB.query(
          db,
          "UPDATE decision_requests SET status = 'ruled', decision = 'allow', ruledAt = 1 WHERE id = ?1 AND status = 'open'",
          [id]
        )
    end

    defp transition_request(db, id, :withdraw) do
      {:ok, _} =
        DB.query(
          db,
          "UPDATE decision_requests SET status = 'withdrawn', withdrawnBy = 'session:holder', withdrawnReason = 'race', withdrawnAt = 1 WHERE id = ?1 AND status = 'open'",
          [id]
        )
    end
  end

  setup do
    db = :"supervision_db_#{System.unique_integer([:positive])}"
    start_supervised!({DB, path: ":memory:", name: db})

    :ok = Tightbeam.Schema.ensure_all(db)

    {:ok, _} =
      DB.query(db, "INSERT INTO users (userId, isAdmin, createdAt) VALUES ('flynn', 1, 1)")

    main = session(db, Org.personal_session_key("flynn"), nil, true)
    supervisor = session(db, "supervisor", main.session_key)
    holder = session(db, "holder", supervisor.session_key)
    assignment(db, "asg_1", holder.session_key, "ship it", 1)

    # Resolved, not just joined: containment refuses a write root with a symlink component,
    # and macOS's tmp dir is one (`/var` → `/private/var`). A script-tier statute under an
    # unresolved base never reaches its check.
    {tmp, 0} = System.cmd("/bin/realpath", [System.tmp_dir!()])

    base =
      Path.join(String.trim(tmp), "tb-supervision-rules-#{System.unique_integer([:positive])}")

    File.mkdir_p!(base)
    handlers = Gateway.handlers(%{db: db, wake_tick_ms: 60_000})
    Rules.load!(base, Map.keys(handlers))
    on_exit(fn -> File.rm_rf!(base) end)

    %{
      db: db,
      handlers: handlers,
      main: main,
      supervisor: supervisor,
      holder: holder,
      base: base
    }
  end

  test "schema and neutral row APIs expose the exact durable state", ctx do
    assert Assignments.oldest_open(ctx.db, "holder").id == "asg_1"
    assert Assignments.attest_count(ctx.db, "asg_1") == 0
    assert Ledger.pending_count(ctx.db, "holder") == 0
    assert Ledger.last_terminal_seq(ctx.db, "holder") == nil
    assert Wakes.pending_count(ctx.db, "holder") == 0
    assert Supervision.prod_state(ctx.db, "asg_1") == nil
    assert Supervision.watermark(ctx.db, "holder") == nil

    assert {:ok, columns} = DB.query(ctx.db, "PRAGMA table_info(supervision_watermarks)")
    names = Enum.map(columns, &Enum.at(&1, 1))

    assert names ==
             ~w(sessionKey lastEvaluatedTerminal pendingBranch pendingAssignment pendingK pendingN)

    refute "pendingTarget" in names
  end

  test "startup refuses noncanonical liveness epoch provenance", ctx do
    {:ok, _} = DB.query(ctx.db, "DELETE FROM supervision_liveness_epoch")

    assert_raise RuntimeError, ~r/invalid supervision_liveness_epoch/, fn ->
      start_liveness!(ctx,
        name: :invalid_liveness_epoch_supervision,
        sweep_ms: 60_000
      )
    end
  end

  test "work-item liveness selects its current bracket before another assignment", ctx do
    :ok =
      DB.execute(
        ctx.db,
        """
        INSERT INTO work_items
          (id, title, ownerUserId, state, createdByUser, createdAt)
        VALUES ('wi_bracket_first', 'Bracket first', 'flynn', 'open', 'flynn', 1);
        UPDATE assignments SET workItemId='wi_bracket_first' WHERE id='asg_1';
        INSERT INTO supervision_entitlements
          (assignmentId, generation, dueAt, state, lastAttemptGeneration,
           claimClock, basisKind, basisId, terminusAt, cause, principal,
           supervisionIntervalMs)
        VALUES
          ('asg_1', 4, 5000, 'armed', NULL, NULL, 'assignment_open',
           'asg_1', NULL, 'assignment_open', 'user:flynn', 1000);
        """
      )

    bracket =
      Wakes.schedule(ctx.db, %{
        session_key: ctx.holder.session_key,
        origin: "process:tightbeam",
        prompt: "route the remaining work",
        due_at: 4_000,
        work_item_id: "wi_bracket_first"
      })

    {:ok, _} =
      DB.query(
        ctx.db,
        "UPDATE work_items SET slateWakeId=?2 WHERE id=?1",
        ["wi_bracket_first", bracket.wake_id]
      )

    assert {:ok, {:ok, %{kind: "routing_bracket", id: "wi_bracket_first"}}} =
             DB.transaction(ctx.db, fn txn ->
               Supervision.liveness_trigger_in_txn(txn, {:work_item, "wi_bracket_first"})
             end)
  end

  test "prod claims once, counts delivery once, and freezes its outbox numbers", ctx do
    insert_entitlement!(ctx.db, "asg_1", generation: 1, due_at: 0)
    seq = terminal!(ctx.db, "holder")

    assert {:prodded, 1} = Supervision.evaluate(ctx.db, ctx.handlers, 3, "holder", seq)
    assert :duplicate = Supervision.evaluate(ctx.db, ctx.handlers, 99, "holder", seq)

    assert %{attemptCount: 1, prodCount: 1, deniedStreak: 0} =
             Supervision.prod_state(ctx.db, "asg_1")

    assert %{
             lastEvaluatedTerminal: ^seq,
             pendingBranch: nil,
             pendingAssignment: nil,
             pendingK: nil,
             pendingN: nil
           } = Supervision.watermark(ctx.db, "holder")

    assert [wake] = Wakes.list_pending(ctx.db)
    assert wake.session_key == "holder"
    assert wake.origin == "process:tightbeam"
    assert wake.prompt =~ "prod 1 of 3"
    assert wake.reresolve == nil

    assert [%{"decision" => "none", "ref" => "asg_1", "statute" => nil}] =
             rail_sweep_details(ctx.db, "holder")
  end

  # THE OUTAGE REGRESSION (2026-08-15). During the 2026-08-10 claude outage,
  # prods fired into a dead harness became failed turns, the stored counter
  # climbed anyway, ladders exhausted into a dead tree (127 stalls in one day),
  # and nothing re-armed them at recovery. The ladder measures the HOLDER's
  # unaccountability, so only prods that were DELIVERED — heard, then ignored —
  # may advance it. A failed prod turn is evidence about the transport.
  test "a prod whose wake-turn failed does not advance the ladder; a delivered one does",
       ctx do
    insert_entitlement!(ctx.db, "asg_1", generation: 1, due_at: 0)
    seq1 = terminal!(ctx.db, "holder")

    assert {:prodded, 1} = Supervision.evaluate(ctx.db, ctx.handlers, 1, "holder", seq1)
    assert [wake] = Wakes.list_pending(ctx.db)

    # The prod's turn FAILED — the harness was down; nobody heard anything.
    # Settle the wake and its sidecar exactly as the real turn-end path does:
    # an unsettled sidecar row gates the next evaluation as :controlled.
    {:ok, _} =
      DB.query(
        ctx.db,
        """
        INSERT INTO turns (sessionKey, messageId, origin, prompt, status, wakeId, createdAt)
        VALUES ('holder', 'm_prod_1', 'process:tightbeam', 'prod', 'failed', ?1, 1)
        """,
        [wake.wake_id]
      )

    settle_supervision_wake!(ctx.db, wake.wake_id)

    {:ok, _} =
      DB.query(ctx.db, "UPDATE supervision_entitlements SET dueAt=0 WHERE assignmentId='asg_1'")

    seq2 = terminal!(ctx.db, "holder")

    # n=1: the OLD ladder would already escalate here (one prod SENT) and stamp
    # stalledAt. The heard count is zero, so the ladder must prod again and the
    # strand must not read as stalled.
    assert {:prodded, 1} = Supervision.evaluate(ctx.db, ctx.handlers, 1, "holder", seq2)
    assert %{stalledAt: nil} = Supervision.prod_state(ctx.db, "asg_1")

    # The harness recovered: the RETRY prod's turn is genuinely delivered — a
    # failed turn is terminal in production and never becomes delivered; the
    # recovery path is a new wake with a new turn (Sol review).
    assert [retry_wake] = Wakes.list_pending(ctx.db)

    {:ok, _} =
      DB.query(
        ctx.db,
        """
        INSERT INTO turns (sessionKey, messageId, origin, prompt, status, wakeId, createdAt, endedAt)
        VALUES ('holder', 'm_prod_2', 'process:tightbeam', 'prod', 'delivered', ?1, 2, 2)
        """,
        [retry_wake.wake_id]
      )

    settle_supervision_wake!(ctx.db, retry_wake.wake_id)

    {:ok, _} =
      DB.query(ctx.db, "UPDATE supervision_entitlements SET dueAt=0 WHERE assignmentId='asg_1'")

    seq3 = terminal!(ctx.db, "holder")

    # One heard-and-ignored prod at n=1: NOW the ladder climbs.
    assert {:escalated, 1, "supervisor"} =
             Supervision.evaluate(ctx.db, ctx.handlers, 1, "holder", seq3)

    assert %{stalledAt: stalled} = Supervision.prod_state(ctx.db, "asg_1")
    assert stalled != nil
  end

  # THE REPAIR-SEAM REGRESSION (Sol review, blocking). A typed liveness
  # receipt is the holder's lawful repair verb; heard-prod history from before
  # it must never resurrect a rung. Without the epoch boundary, one delivered
  # pre-receipt prod at n=1 re-escalated an accountable holder immediately.
  test "a typed receipt starts a fresh heard-prod epoch — no rung from pre-repair history",
       ctx do
    insert_entitlement!(ctx.db, "asg_1", generation: 1, due_at: 0)
    seq1 = terminal!(ctx.db, "holder")

    assert {:prodded, 1} = Supervision.evaluate(ctx.db, ctx.handlers, 1, "holder", seq1)
    assert [wake] = Wakes.list_pending(ctx.db)

    # Heard and, for a while, ignored.
    {:ok, _} =
      DB.query(
        ctx.db,
        """
        INSERT INTO turns (sessionKey, messageId, origin, prompt, status, wakeId, createdAt, endedAt)
        VALUES ('holder', 'm_reset_1', 'process:tightbeam', 'prod', 'delivered', ?1, 1, 1)
        """,
        [wake.wake_id]
      )

    settle_supervision_wake!(ctx.db, wake.wake_id)

    # Then the holder REPAIRS: a verdict files a typed liveness receipt.
    {:ok, _} =
      DB.query(
        ctx.db,
        "INSERT INTO attests (id, assignmentId, kind, verdictKind, byUser, ts) VALUES ('att_epoch','asg_1','verdict','verified','flynn',2)"
      )

    seq2 = terminal!(ctx.db, "holder")
    assert :rebased = Supervision.evaluate(ctx.db, ctx.handlers, 1, "holder", seq2)

    {:ok, _} =
      DB.query(ctx.db, "UPDATE supervision_entitlements SET dueAt=0 WHERE assignmentId='asg_1'")

    seq3 = terminal!(ctx.db, "holder")

    # n=1 with one delivered pre-receipt prod: a lifetime count escalates here.
    # The epoch count starts fresh — prod 1, no stall.
    assert {:prodded, 1} = Supervision.evaluate(ctx.db, ctx.handlers, 1, "holder", seq3)
    assert %{stalledAt: nil} = Supervision.prod_state(ctx.db, "asg_1")
  end

  # THE LEGACY-TRANSFER REGRESSION (Sol confirmation round). Retirement-era
  # sidecar rows carry transfer evidence but a NULL chargedGeneration. Before
  # any receipt exists they are real heard evidence (NULL fails >= silently);
  # after a receipt they belong to history like everything else pre-repair.
  test "F2 retirement elevation remains ordinary transfer evidence outside patrol sources", ctx do
    insert_entitlement!(ctx.db, "asg_1", generation: 1, due_at: 0)

    # The sidecar's coherence trigger demands a matching escalation wake row
    # at insert time (pending, lineage-reresolved), exactly as the claim path
    # writes one; it is then settled the way turn-end would settle it.
    {:ok, _} =
      DB.query(
        ctx.db,
        """
        INSERT INTO wakes
          (wakeId, sessionKey, origin, prompt, consumer, dueAt, state, createdAt,
           assignmentId, reresolve, reresolveSeed, reresolveRung, rumination, targetGate)
        VALUES ('w_legacy', 'supervisor', 'process:tightbeam', 'legacy transfer', 'prompt',
                1, 'pending', 1, 'asg_1', 'lineage', 'holder', 1, 0, 1)
        """
      )

    {:ok, _} =
      DB.query(
        ctx.db,
        """
        INSERT INTO supervision_liveness_sidecar
          (wakeId, assignmentId, controllerOrigin, wakeKind, controllerState,
           transferEvidenceId, retirementEpoch, retiringSessionKey,
           retirementOutcomeKind, retirementOutcomeId, retirementTargetSessionKey,
           retirementCause, retirementPrincipal, retirementActionNeeded)
        VALUES ('w_legacy', 'asg_1', 'retirement_elevation', 'escalation', 'settled',
                'ev_legacy', 0, 'holder',
                'parent_elevation', 'out_legacy', 'supervisor',
                'parent_target_retired', 'process:tightbeam', 0)
        """
      )

    # Firing a lineage wake also requires its transfer TURN to exist — the
    # durable delivery to the parent, queued until the parent runs.
    {:ok, _} =
      DB.query(
        ctx.db,
        """
        INSERT INTO turns (sessionKey, messageId, origin, prompt, status, wakeId, assignmentId, createdAt)
        VALUES ('supervisor', 'm_legacy', 'process:tightbeam', 'legacy transfer', 'queued', 'w_legacy', 'asg_1', 1)
        """
      )

    # The retirement_elevation sidecar is born settled and immutable; only
    # the wake itself needs firing.
    {:ok, _} =
      DB.query(ctx.db, "UPDATE wakes SET state='fired', firedAt=1 WHERE wakeId='w_legacy'")

    assert {:ok, [[0, 0]]} =
             DB.query(
               ctx.db,
               "SELECT (SELECT COUNT(*) FROM supervision_patrol_response_episodes WHERE originatingWakeId='w_legacy'),(SELECT COUNT(*) FROM patrol_output_sources WHERE wakeId='w_legacy')"
             )

    seq1 = terminal!(ctx.db, "holder")

    # One heard escalation at n=1: the ladder honors the durable transfer.
    assert {:escalated, 1, "supervisor"} =
             Supervision.evaluate(ctx.db, ctx.handlers, 1, "holder", seq1)

    cancel_wake!(ctx.db, hd(Wakes.list_pending(ctx.db)))

    # The holder repairs.
    {:ok, _} =
      DB.query(
        ctx.db,
        "INSERT INTO attests (id, assignmentId, kind, verdictKind, byUser, ts) VALUES ('att_legacy','asg_1','verdict','verified','flynn',2)"
      )

    seq2 = terminal!(ctx.db, "holder")
    assert :rebased = Supervision.evaluate(ctx.db, ctx.handlers, 1, "holder", seq2)

    {:ok, _} =
      DB.query(ctx.db, "UPDATE supervision_entitlements SET dueAt=0 WHERE assignmentId='asg_1'")

    seq3 = terminal!(ctx.db, "holder")

    # Post-receipt, the NULL-generation row is history: prod 1, no stall.
    assert {:prodded, 1} = Supervision.evaluate(ctx.db, ctx.handlers, 1, "holder", seq3)
    assert %{stalledAt: nil} = Supervision.prod_state(ctx.db, "asg_1")
  end

  test "F2 an internal effort wake remains ordinary and does not suppress the prod", ctx do
    insert_entitlement!(ctx.db, "asg_1", generation: 1, due_at: 0)

    Wakes.schedule(ctx.db, %{
      session_key: "holder",
      origin: "process:tightbeam",
      consumer: "effort_probe",
      due_at: System.system_time(:millisecond) + 60_000
    })

    assert Wakes.pending_count(ctx.db, "holder") == 0
    seq = terminal!(ctx.db, "holder")
    assert {:prodded, 1} = Supervision.evaluate(ctx.db, ctx.handlers, 3, "holder", seq)
  end

  test "F3 progress prose stays durable without becoming a receipt or acknowledgment", ctx do
    insert_entitlement!(ctx.db, "asg_1", generation: 1, due_at: 0)
    seq1 = terminal!(ctx.db, "holder")
    assert {:prodded, 1} = Supervision.evaluate(ctx.db, ctx.handlers, 2, "holder", seq1)
    [wake] = Wakes.list_pending(ctx.db)
    cancel_wake!(ctx.db, wake)

    {:ok, _} =
      DB.query(
        ctx.db,
        "INSERT INTO attests (id, assignmentId, kind, bySession, ts) VALUES ('att_1','asg_1','progress','holder',2)"
      )

    {:ok, _} =
      DB.query(
        ctx.db,
        "UPDATE supervision_entitlements SET dueAt=0 WHERE assignmentId='asg_1'"
      )

    seq2 = terminal!(ctx.db, "holder")

    # The wire numbering counts HEARD prods (outage regression, 2026-08-15):
    # the canceled first prod never reached anyone, so this send is still
    # "prod 1 of 2". The stored counters below keep counting every attempt —
    # which is this test's actual subject: progress prose resets neither.
    assert {:prodded, 1} = Supervision.evaluate(ctx.db, ctx.handlers, 2, "holder", seq2)

    assert %{attemptCount: 2, prodCount: 2, attestCount: 1, stalledAt: nil} =
             Supervision.prod_state(ctx.db, "asg_1")

    assert {:ok, []} =
             DB.query(ctx.db, "SELECT receiptId FROM supervision_liveness_receipts")
  end

  # Immutable authority: art_201ab36d, SHA-256
  # fe0945a8a210d50db4b8ae27f5c46dcb63f63d6dcef5884a41d3402a662c590a.
  # These cases drive explicit durable rows or synchronous process barriers. They
  # deliberately do not sleep, poll, widen a timeout, or infer a deadline from the
  # wall clock.
  test "F3 a verdict receipt wins before acknowledgment suppression and rebases once", ctx do
    insert_entitlement!(ctx.db, "asg_1", generation: 1, due_at: 0)
    seq1 = terminal!(ctx.db, "holder")
    assert {:prodded, 1} = Supervision.evaluate(ctx.db, ctx.handlers, 2, "holder", seq1)
    cancel_wake!(ctx.db, hd(Wakes.list_pending(ctx.db)))

    {:ok, _} =
      DB.query(
        ctx.db,
        "INSERT INTO attests (id, assignmentId, kind, verdictKind, byUser, ts) VALUES ('att_verdict','asg_1','verdict','verified','flynn',2)"
      )

    seq2 = terminal!(ctx.db, "holder")
    assert :rebased = Supervision.evaluate(ctx.db, ctx.handlers, 2, "holder", seq2)

    assert %{
             attemptCount: 0,
             prodCount: 0,
             supervisionGeneration: 3,
             supervisionBasisKind: "liveness_receipt"
           } =
             Supervision.prod_state(ctx.db, "asg_1")

    assert {:ok, [["verdict", "att_verdict", 3]]} =
             DB.query(
               ctx.db,
               "SELECT sourceKind,sourceId,generation FROM supervision_liveness_receipts"
             )

    assert :duplicate = Supervision.evaluate(ctx.db, ctx.handlers, 2, "holder", seq2)

    {:ok, _} =
      DB.query(ctx.db, "UPDATE supervision_entitlements SET dueAt=0 WHERE assignmentId='asg_1'")

    seq3 = terminal!(ctx.db, "holder")
    assert {:prodded, 1} = Supervision.evaluate(ctx.db, ctx.handlers, 2, "holder", seq3)
  end

  test "several typed effects produce one generation with exact source receipts", ctx do
    attach_work_item!(ctx.db, "asg_1", "wi_receipts")
    insert_entitlement!(ctx.db, "asg_1", generation: 1, due_at: 9_000_000_000_000)
    name = start_liveness!(ctx, sweep_ms: 60_000)

    {:ok, _} =
      DB.query(
        ctx.db,
        "INSERT INTO attests (id, assignmentId, kind, verdictKind, byUser, ts) VALUES ('att_fact','asg_1','verdict','verified','flynn',9000000000000)"
      )

    {:ok, _} =
      DB.query(
        ctx.db,
        "INSERT INTO work_item_events (ts, workItemId, kind) VALUES (9000000001000, 'wi_receipts', 'metadata')"
      )

    sweep_liveness!(name)

    assert {:ok, [["verdict", "att_fact", 2], ["work_item_update", "1", 2]]} =
             DB.query(
               ctx.db,
               "SELECT sourceKind,sourceId,generation FROM supervision_liveness_receipts ORDER BY receiptId"
             )

    assert %{
             supervisionState: "armed",
             supervisionGeneration: 2,
             supervisionDueAt: 9_000_000_061_000,
             supervisionIntervalMs: 60_000,
             supervisionBasisKind: "liveness_receipt",
             supervisionCause: "liveness_receipt",
             supervisionPrincipal: "process:tightbeam"
           } = Supervision.prod_state(ctx.db, "asg_1")

    sweep_liveness!(name)

    assert %{supervisionGeneration: 2, supervisionDueAt: 9_000_000_061_000} =
             Supervision.prod_state(ctx.db, "asg_1")
  end

  test "F3 an artifact receipt wins before acknowledgment while unrelated artifacts do not",
       ctx do
    attach_work_item!(ctx.db, "asg_1", "wi_receipts")
    insert_entitlement!(ctx.db, "asg_1", generation: 4, due_at: 0, interval: 60_000)
    insert_artifact!(ctx.db, "art_other", "holder", "wi_other", 9_000_000_000_000)
    insert_artifact!(ctx.db, "art_effect", "holder", "wi_receipts", 9_000_000_001_000)

    _name = start_liveness!(ctx, sweep_ms: 60_000)

    assert %{
             supervisionState: "armed",
             supervisionGeneration: 5,
             supervisionDueAt: 9_000_000_061_000,
             supervisionBasisKind: "liveness_receipt"
           } = Supervision.prod_state(ctx.db, "asg_1")

    assert {:ok, [["artifact", "art_effect"]]} =
             DB.query(
               ctx.db,
               "SELECT sourceKind,sourceId FROM supervision_liveness_receipts"
             )

    assert Wakes.list_pending(ctx.db) == []
  end

  test "F3 tool call result and durable messages remain byte-equal after acknowledgment", ctx do
    assignment(ctx.db, "asg_f3_tool", "holder", "tool effect", 3)

    %{turn_seq: answer_terminal, wake_id: wake_id} =
      prepare_patrol_answer!(ctx, "asg_f3_tool", "holder")

    assert {:ok, {tool_call, tool_result}} =
             DB.transaction(ctx.db, fn txn ->
               {:appended, tool_call} =
                 Projection.append_in_txn(txn, %{
                   session_key: "holder",
                   role: "assistant",
                   content: ~s({"type":"tool_call","id":"call_f3","name":"read"}),
                   sender: "agent:holder"
                 })

               {:appended, tool_result} =
                 Projection.append_in_txn(txn, %{
                   session_key: "holder",
                   role: "assistant",
                   content: ~s({"type":"tool_result","tool_call_id":"call_f3","value":"ok"}),
                   sender: "process:tool"
                 })

               {tool_call, tool_result}
             end)

    before =
      [Projection.get(ctx.db, tool_call.id), Projection.get(ctx.db, tool_result.id)]
      |> :erlang.term_to_binary()

    assert :ok = Ledger.finish(ctx.db, answer_terminal, "delivered")

    assert :patrol_response_acknowledged =
             Supervision.evaluate(ctx.db, ctx.handlers, 3, "holder", answer_terminal)

    after_bytes =
      [Projection.get(ctx.db, tool_call.id), Projection.get(ctx.db, tool_result.id)]
      |> :erlang.term_to_binary()

    assert after_bytes == before

    assert {:ok, [[^answer_terminal]]} =
             DB.query(
               ctx.db,
               "SELECT answerTerminalId FROM supervision_patrol_response_episodes WHERE originatingWakeId=?1",
               [wake_id]
             )
  end

  test "one bounded assignment checkpoint resets; repeats need a later effect", ctx do
    attach_work_item!(ctx.db, "asg_1", "wi_checkpoint")
    insert_entitlement!(ctx.db, "asg_1", generation: 1, due_at: 0, interval: 60_000)
    now = System.system_time(:millisecond)

    {first, seq1} =
      schedule_checkpoint_via_gateway!(ctx, "resume receipt work", 60_000)

    assert :rebased = Supervision.evaluate(ctx.db, ctx.handlers, 2, "holder", seq1)

    {second, seq2} =
      schedule_checkpoint_via_gateway!(ctx, "same checkpoint again", 120_000)

    {:ok, _} =
      DB.query(ctx.db, "UPDATE supervision_entitlements SET dueAt=0 WHERE assignmentId='asg_1'")

    assert {:prodded, 1} = Supervision.evaluate(ctx.db, ctx.handlers, 2, "holder", seq2)
    prod = Enum.find(Wakes.list_pending(ctx.db), &(&1.origin == "process:tightbeam"))
    cancel_wake!(ctx.db, prod)

    insert_artifact!(ctx.db, "art_checkpoint_reset", "holder", "wi_checkpoint", now + 1)
    seq3 = terminal!(ctx.db, "holder")
    assert :rebased = Supervision.evaluate(ctx.db, ctx.handlers, 2, "holder", seq3)

    {third, seq4} =
      schedule_checkpoint_via_gateway!(ctx, "checkpoint after durable effect", 180_000)

    assert :rebased = Supervision.evaluate(ctx.db, ctx.handlers, 2, "holder", seq4)

    assert {:ok,
            [
              ["checkpoint", first_id],
              ["artifact", "art_checkpoint_reset"],
              ["checkpoint", third_id]
            ]} =
             DB.query(
               ctx.db,
               "SELECT sourceKind,sourceId FROM supervision_liveness_receipts ORDER BY receiptId"
             )

    assert first_id == first.wake_id
    assert third_id == third.wake_id
    refute second.wake_id in [first_id, third_id]
  end

  test "vague progress and unbound, unrelated, or expired wakes are not receipts", ctx do
    assignment(ctx.db, "asg_other", "holder", "other work", 2)
    insert_entitlement!(ctx.db, "asg_1", generation: 1, due_at: 0)
    now = System.system_time(:millisecond)

    for input <- [
          %{prompt: "unbound", due_at: now + 60_000},
          %{prompt: "other assignment", due_at: now + 60_000, assignment_id: "asg_other"},
          %{prompt: "expired", due_at: 1, assignment_id: "asg_1"}
        ] do
      Wakes.schedule(
        ctx.db,
        Map.merge(
          %{
            session_key: "holder",
            origin: "session:holder",
            creator_session_key: "holder"
          },
          input
        )
      )
    end

    {:ok, _} =
      DB.query(
        ctx.db,
        "INSERT INTO attests (id,assignmentId,kind,note,bySession,ts) VALUES ('att_vague','asg_1','progress','blocked, no state change','holder',?1)",
        [now]
      )

    seq = terminal!(ctx.db, "holder")
    assert {:prodded, 1} = Supervision.evaluate(ctx.db, ctx.handlers, 2, "holder", seq)
    assert {:ok, []} = DB.query(ctx.db, "SELECT receiptId FROM supervision_liveness_receipts")
  end

  test "a receipt waits for an already-issued controller and resets after it settles", ctx do
    terminal!(ctx.db, "holder")
    insert_entitlement!(ctx.db, "asg_1", generation: 4, due_at: 0, interval: 60_000)

    name = start_liveness!(ctx, sweep_ms: 60_000)
    assert [%{assignment_id: "asg_1"} = charged] = Wakes.list_pending(ctx.db)

    {:ok, _} =
      DB.query(
        ctx.db,
        "INSERT INTO attests (id, assignmentId, kind, verdictKind, byUser, ts) VALUES ('att_after_due','asg_1','verdict','verified','flynn',9000000000000)"
      )

    sweep_liveness!(name)
    assert Wakes.get(ctx.db, charged.wake_id).state == "pending"
    assert :appended = admit_supervision_wake!(ctx.db, charged)
    assert {:ok, turn} = Ledger.claim_next(ctx.db, "holder", "receipt-after-controller")
    assert :ok = Ledger.finish(ctx.db, turn.seq, "delivered")

    sweep_liveness!(name)

    assert %{
             supervisionState: "armed",
             supervisionGeneration: 6,
             supervisionDueAt: 9_000_000_060_000,
             supervisionBasisKind: "liveness_receipt",
             attemptCount: 0,
             prodCount: 0
           } = Supervision.prod_state(ctx.db, "asg_1")

    assert Ledger.last_terminal_seq(ctx.db, "holder") == turn.seq
  end

  test "restart preserves an armed deadline and a later receipt captures the replacement interval",
       ctx do
    insert_entitlement!(ctx.db, "asg_1",
      generation: 7,
      due_at: 9_000_000_000_000,
      interval: 1_000
    )

    _first = start_liveness!(ctx, sweep_ms: 1_000)
    assert :ok = stop_supervised(Supervision)

    second = start_liveness!(ctx, sweep_ms: 2_000)

    assert %{
             supervisionGeneration: 7,
             supervisionDueAt: 9_000_000_000_000,
             supervisionIntervalMs: 1_000
           } = Supervision.prod_state(ctx.db, "asg_1")

    {:ok, _} =
      DB.query(
        ctx.db,
        "INSERT INTO attests (id, assignmentId, kind, verdictKind, byUser, ts) VALUES ('att_restart','asg_1','verdict','verified','flynn',9000000032000)"
      )

    sweep_liveness!(second)

    assert %{
             supervisionGeneration: 8,
             supervisionDueAt: 9_000_000_034_000,
             supervisionIntervalMs: 2_000,
             supervisionBasisKind: "liveness_receipt"
           } = Supervision.prod_state(ctx.db, "asg_1")
  end

  test "restart drains one durable claimed branch and later sweeps retry without recounting",
       ctx do
    insert_entitlement!(ctx.db, "asg_1", generation: 2, due_at: 5_000, interval: 1_000)

    {:ok, _} =
      DB.query(
        ctx.db,
        """
        UPDATE supervision_entitlements
        SET state='claimed', claimClock=5000, lastAttemptGeneration=2, cause='deadline'
        WHERE assignmentId='asg_1'
        """
      )

    {:ok, _} =
      DB.query(
        ctx.db,
        """
        INSERT INTO assignment_prods
          (assignmentId, attemptCount, prodCount, deniedStreak)
        VALUES ('asg_1', 1, 0, 0)
        """
      )

    {:ok, _} =
      DB.query(
        ctx.db,
        """
        INSERT INTO supervision_watermarks
          (sessionKey, lastEvaluatedTerminal, pendingBranch, pendingAssignment,
           pendingK, pendingN)
        VALUES ('holder', 0, 'prod', 'asg_1', 1, 2)
        """
      )

    test_pid = self()

    retrying =
      Map.put(ctx.handlers, "wake", fn _call ->
        send(test_pid, :claimed_branch_drained)
        %{code: "server_error"}
      end)

    name =
      start_liveness!(%{ctx | handlers: retrying},
        name: :claimed_branch_recovery,
        sweep_ms: 1_000
      )

    assert_receive :claimed_branch_drained
    refute_receive :claimed_branch_drained

    assert %{attemptCount: 1, supervisionGeneration: 2, supervisionState: "claimed"} =
             Supervision.prod_state(ctx.db, "asg_1")

    assert %{pendingBranch: "prod", pendingAssignment: "asg_1"} =
             Supervision.watermark(ctx.db, "holder")

    sweep_liveness!(name)
    assert_receive :claimed_branch_drained
    refute_receive :claimed_branch_drained

    assert %{attemptCount: 1, supervisionGeneration: 2, supervisionState: "claimed"} =
             Supervision.prod_state(ctx.db, "asg_1")
  end

  test "an unbound continuation does not defer a due entitlement", ctx do
    terminal!(ctx.db, "holder")
    insert_entitlement!(ctx.db, "asg_1", generation: 9, due_at: 0, interval: 60_000)

    continuation =
      Wakes.schedule(ctx.db, %{
        session_key: "holder",
        origin: "session:holder",
        prompt: "continue later",
        due_at: 9_000_000_000_000
      })

    _name = start_liveness!(ctx, sweep_ms: 60_000)

    assert %{supervisionState: "armed", supervisionGeneration: 10, prodCount: 1} =
             Supervision.prod_state(ctx.db, "asg_1")

    assert Wakes.get(ctx.db, continuation.wake_id).state == "pending"
    assert Enum.any?(Wakes.list_pending(ctx.db), &(&1.assignment_id == "asg_1"))
  end

  test "terminal recovery and retirement remove child entitlements permanently", ctx do
    assignment(ctx.db, "asg_completed", "holder", "complete", 2)
    assignment(ctx.db, "asg_surrendered", "holder", "surrender", 3)
    assignment(ctx.db, "asg_revoked", "holder", "revoke", 4)

    for id <- ~w(asg_completed asg_surrendered asg_revoked) do
      insert_entitlement!(ctx.db, id, generation: 1, due_at: 9_000_000_000_000)
    end

    {:ok, _} =
      DB.query(
        ctx.db,
        """
        INSERT INTO attests (id, assignmentId, kind, bySession, ts) VALUES
          ('att_completed','asg_completed','completion','holder',10),
          ('att_surrendered','asg_surrendered','surrender','holder',11)
        """
      )

    {:ok, _} =
      DB.query(
        ctx.db,
        "UPDATE assignments SET state='closed', outcome='completed', closedAt=10, closedBySession='holder', closingAttestId='att_completed' WHERE id='asg_completed'"
      )

    {:ok, _} =
      DB.query(
        ctx.db,
        "UPDATE assignments SET state='closed', outcome='surrendered', closedAt=11, closedBySession='holder', closingAttestId='att_surrendered' WHERE id='asg_surrendered'"
      )

    {:ok, _} =
      DB.query(
        ctx.db,
        "UPDATE assignments SET state='closed', outcome='revoked', closedAt=12, closedByUser='flynn' WHERE id='asg_revoked'"
      )

    _name = start_liveness!(ctx, sweep_ms: 60_000)

    assert {:ok, []} =
             DB.query(
               ctx.db,
               "SELECT assignmentId FROM supervision_entitlements WHERE assignmentId IN ('asg_completed','asg_surrendered','asg_revoked')"
             )

    {:ok, _} =
      DB.query(
        ctx.db,
        """
        UPDATE supervision_entitlements
        SET generation=3, dueAt=9000000000000, state='armed',
            lastAttemptGeneration=NULL, claimClock=NULL, basisKind='assignment_open',
            basisId='asg_1', cause='assignment_open', principal='user:flynn',
            supervisionIntervalMs=60000
        WHERE assignmentId='asg_1'
        """
      )

    retire!(ctx.db, "holder")

    assert {:ok, [["closed", "revoked"]]} =
             DB.query(ctx.db, "SELECT state, outcome FROM assignments WHERE id='asg_1'")

    assert {:ok, []} =
             DB.query(
               ctx.db,
               "SELECT assignmentId FROM supervision_entitlements WHERE assignmentId='asg_1'"
             )
  end

  test "startup recovery revokes an open assignment whose holder is already retired", ctx do
    insert_entitlement!(ctx.db, "asg_1", generation: 4, due_at: 9_000_000_000_000)

    {:ok, _} =
      DB.query(
        ctx.db,
        "UPDATE sessions SET state='retired', updatedAt=2 WHERE sessionKey='holder'"
      )

    _name = start_liveness!(ctx, sweep_ms: 60_000)

    assert {:ok, [["closed", "revoked"]]} =
             DB.query(ctx.db, "SELECT state, outcome FROM assignments WHERE id='asg_1'")

    assert {:ok, [["interrupted-by-retire"]]} =
             DB.query(
               ctx.db,
               "SELECT reason FROM assignment_interruptions WHERE assignmentId='asg_1'"
             )

    assert {:ok, []} =
             DB.query(
               ctx.db,
               "SELECT assignmentId FROM supervision_entitlements WHERE assignmentId='asg_1'"
             )
  end

  test "durable parent-turn admission replaces the child row with one virtual transfer proof",
       ctx do
    terminal_seq = terminal!(ctx.db, "holder")
    insert_entitlement!(ctx.db, "asg_1", generation: 1, due_at: 0)

    assert {:escalated, 1, "supervisor"} =
             Supervision.evaluate(ctx.db, ctx.handlers, 0, "holder", terminal_seq)

    assert [escalation] = Wakes.list_pending(ctx.db)
    assert escalation.reresolve == "lineage"

    assert :appended = admit_supervision_wake!(ctx.db, escalation)

    assert %{
             supervisionState: "parent_elevated",
             supervisionTransferWakeId: transfer_wake,
             supervisionTransferSessionKey: "supervisor",
             supervisionDueAt: nil,
             supervisionTerminusAt: nil
           } = Supervision.prod_state(ctx.db, "asg_1")

    assert transfer_wake == escalation.wake_id

    assert {:ok, []} =
             DB.query(ctx.db, "SELECT 1 FROM supervision_entitlements WHERE assignmentId='asg_1'")
  end

  test "startup uses the newest valid parent transfer when history has earlier transfers", ctx do
    first_terminal_seq = terminal!(ctx.db, "holder")
    insert_entitlement!(ctx.db, "asg_1", generation: 1, due_at: 0)

    assert {:escalated, 1, "supervisor"} =
             Supervision.evaluate(ctx.db, ctx.handlers, 0, "holder", first_terminal_seq)

    assert [first_wake] = Wakes.list_pending(ctx.db)
    assert :appended = admit_supervision_wake!(ctx.db, first_wake)

    second_terminal_seq = terminal!(ctx.db, "holder")
    insert_entitlement!(ctx.db, "asg_1", generation: 2, due_at: 0)

    assert {:escalated, 2, main_session_key} =
             Supervision.evaluate(ctx.db, ctx.handlers, 0, "holder", second_terminal_seq)

    assert main_session_key == ctx.main.session_key

    assert [second_wake] = Wakes.list_pending(ctx.db)
    assert :appended = admit_supervision_wake!(ctx.db, second_wake)

    name = start_liveness!(ctx, sweep_ms: 60_000)

    assert is_pid(Process.whereis(name))

    assert %{
             supervisionState: "parent_elevated",
             supervisionTransferWakeId: transfer_wake,
             supervisionTransferSessionKey: ^main_session_key
           } = Supervision.prod_state(ctx.db, "asg_1")

    assert transfer_wake == second_wake.wake_id
    refute transfer_wake == first_wake.wake_id
  end

  test "startup normalizes legacy lineage markers and starts fresh bounded supervision", ctx do
    :ok = DB.execute(ctx.db, "DROP TRIGGER supervision_lineage_fire_requires_sidecar")

    legacy =
      Wakes.schedule(ctx.db, %{
        session_key: "supervisor",
        origin: "process:tightbeam",
        prompt: "legacy escalation history",
        due_at: 0,
        assignment_id: "asg_1",
        reresolve: "lineage",
        reresolve_seed: "holder",
        reresolve_rung: 1
      })

    assert {:ok, {:appended, _target, _message, _opts}} =
             DB.transaction(ctx.db, fn txn ->
               Gateway.deliver_prompt_in_txn(
                 txn,
                 "supervisor",
                 legacy.origin,
                 legacy.prompt,
                 wake_id: legacy.wake_id,
                 sender: legacy.origin,
                 target_gate: legacy,
                 fire_wake_in_txn: true,
                 assignment_id: "asg_1"
               )
             end)

    expected_prompt = "[from process:tightbeam]\n\nlegacy escalation history"

    assert {:ok, [[turn_seq, message_id, ^expected_prompt]]} =
             DB.query(
               ctx.db,
               "SELECT seq, messageId, prompt FROM turns WHERE wakeId=?1",
               [legacy.wake_id]
             )

    assert {:ok, [[message_content]]} =
             DB.query(ctx.db, "SELECT content FROM messages WHERE id=?1", [message_id])

    assert message_content =~ "legacy escalation history"

    assert {:ok, [["lineage", "holder", 1]]} =
             DB.query(
               ctx.db,
               "SELECT reresolve, reresolveSeed, reresolveRung FROM wakes WHERE wakeId=?1",
               [legacy.wake_id]
             )

    assert :ok = Schema.ensure_all(ctx.db)

    name = start_liveness!(ctx, name: :legacy_marker_cleanup, sweep_ms: 60_000)
    assert is_pid(Process.whereis(name))

    assert {:ok, [[nil, nil, nil]]} =
             DB.query(
               ctx.db,
               "SELECT reresolve, reresolveSeed, reresolveRung FROM wakes WHERE wakeId=?1",
               [legacy.wake_id]
             )

    migration_id = "0.1.6/normalize-sidecarless-lineage-v1"

    assert {:ok, [[^migration_id, 1, "release_upgrade", "process:tightbeam"]]} =
             DB.query(
               ctx.db,
               "SELECT migrationId,affectedRows,cause,principal FROM supervision_liveness_migrations"
             )

    assignment(ctx.db, "asg_post_receipt", "holder", "post receipt", 10)

    post_receipt =
      Wakes.schedule(ctx.db, %{
        session_key: "supervisor",
        origin: "process:tightbeam",
        prompt: "post-receipt ordinary delivery",
        due_at: 0,
        assignment_id: "asg_post_receipt"
      })

    assert {:ok, {:appended, _target, _message, _opts}} =
             DB.transaction(ctx.db, fn txn ->
               Gateway.deliver_prompt_in_txn(
                 txn,
                 post_receipt.session_key,
                 post_receipt.origin,
                 post_receipt.prompt,
                 wake_id: post_receipt.wake_id,
                 sender: post_receipt.origin,
                 target_gate: post_receipt,
                 fire_wake_in_txn: true,
                 assignment_id: "asg_post_receipt"
               )
             end)

    assert {:ok, [[0, 0]]} =
             DB.query(
               ctx.db,
               """
               SELECT
                 (SELECT COUNT(*) FROM supervision_liveness_sidecar WHERE wakeId=?1),
                 (SELECT COUNT(*) FROM supervision_entitlements WHERE assignmentId='asg_post_receipt')
               """,
               [post_receipt.wake_id]
             )

    {:ok, _} =
      DB.query(
        ctx.db,
        "UPDATE wakes SET reresolve='lineage',reresolveSeed='holder',reresolveRung=1 WHERE wakeId=?1",
        [post_receipt.wake_id]
      )

    assert_raise RuntimeError, ~r/invalid_parent_transfer/, fn ->
      Supervision.recover_liveness!(ctx.db, 60_000)
    end

    assert {:ok, [["lineage", "holder", 1]]} =
             DB.query(
               ctx.db,
               "SELECT reresolve, reresolveSeed, reresolveRung FROM wakes WHERE wakeId=?1",
               [post_receipt.wake_id]
             )

    assert {:ok, [[nil, nil, nil]]} =
             DB.query(
               ctx.db,
               "SELECT reresolve, reresolveSeed, reresolveRung FROM wakes WHERE wakeId=?1",
               [legacy.wake_id]
             )

    assert {:ok, [[1]]} =
             DB.query(
               ctx.db,
               "SELECT COUNT(*) FROM supervision_liveness_migrations WHERE migrationId=?1",
               [migration_id]
             )

    assert {:ok, [[^turn_seq, ^message_id, ^expected_prompt]]} =
             DB.query(
               ctx.db,
               "SELECT seq, messageId, prompt FROM turns WHERE wakeId=?1",
               [legacy.wake_id]
             )

    assert {:ok, [[^message_content]]} =
             DB.query(ctx.db, "SELECT content FROM messages WHERE id=?1", [message_id])

    assert %{
             attemptCount: 0,
             prodCount: 0,
             supervisionState: "armed",
             supervisionGeneration: 1,
             supervisionBasisKind: "recovery_backfill"
           } = Supervision.prod_state(ctx.db, "asg_1")

    {:ok, _} =
      DB.query(
        ctx.db,
        "UPDATE supervision_entitlements SET dueAt=0 WHERE assignmentId='asg_1'"
      )

    fresh_terminal = terminal!(ctx.db, "holder")
    assert {:prodded, 1} = Supervision.evaluate(ctx.db, ctx.handlers, 2, "holder", fresh_terminal)

    assert [%{assignment_id: "asg_1", wake_id: fresh_wake_id}] = Wakes.list_pending(ctx.db)
    refute fresh_wake_id == legacy.wake_id

    assert {:ok, [["prod", "pending", 2]]} =
             DB.query(
               ctx.db,
               "SELECT wakeKind, controllerState, chargedGeneration FROM supervision_liveness_sidecar WHERE wakeId=?1",
               [fresh_wake_id]
             )
  end

  test "startup migrates one legacy retired parent transfer to Main exactly once", ctx do
    {:ok, _} =
      DB.query(
        ctx.db,
        """
        INSERT INTO work_items
          (id, title, ownerUserId, state, createdByUser, createdAt)
        VALUES ('wi_legacy_transfer', 'legacy transfer', 'flynn', 'open', 'flynn', 1)
        """
      )

    {:ok, _} =
      DB.query(
        ctx.db,
        "UPDATE assignments SET workItemId='wi_legacy_transfer' WHERE id='asg_1'"
      )

    terminal_seq = terminal!(ctx.db, "holder")
    insert_entitlement!(ctx.db, "asg_1", generation: 1, due_at: 0)

    assert {:escalated, 1, "supervisor"} =
             Supervision.evaluate(ctx.db, ctx.handlers, 0, "holder", terminal_seq)

    assert [source_wake] = Wakes.list_pending(ctx.db)
    assert :appended = admit_supervision_wake!(ctx.db, source_wake)

    assert {:ok, [[source_turn_seq]]} =
             DB.query(ctx.db, "SELECT seq FROM turns WHERE wakeId=?1", [source_wake.wake_id])

    source_evidence = "asg_1##{source_turn_seq}"

    {:ok, _} =
      DB.query(
        ctx.db,
        "UPDATE sessions SET state='retired', updatedAt=2 WHERE sessionKey='supervisor'"
      )

    assert {:ok, [[activation_epoch]]} =
             DB.query(ctx.db, "SELECT activatedAt FROM supervision_liveness_epoch WHERE id=0")

    _name = start_liveness!(ctx, sweep_ms: 60_000)

    assert {:ok,
            [
              [
                ^source_evidence,
                ^activation_epoch,
                "supervisor",
                "main_elevation",
                successor_id,
                main_key,
                "legacy_parent_target_retired",
                "process:tightbeam",
                1
              ]
            ]} =
             DB.query(
               ctx.db,
               """
               SELECT transferEvidenceId, retirementEpoch, retiringSessionKey,
                      retirementOutcomeKind, retirementOutcomeId,
                      retirementTargetSessionKey, retirementCause,
                      retirementPrincipal, retirementActionNeeded
               FROM supervision_liveness_sidecar
               WHERE wakeId=?1
               """,
               [source_wake.wake_id]
             )

    assert main_key == ctx.main.session_key

    assert {:ok, [["canceled"]]} =
             DB.query(ctx.db, "SELECT status FROM turns WHERE seq=?1", [
               source_turn_seq
             ])

    ["asg_1", successor_turn] = String.split(successor_id, "#", parts: 2)
    {successor_turn_seq, ""} = Integer.parse(successor_turn)

    assert {:ok,
            [
              [
                successor_wake_id,
                ^main_key,
                "fired",
                "retirement_elevation",
                "escalation",
                "settled",
                nil
              ]
            ]} =
             DB.query(
               ctx.db,
               """
               SELECT w.wakeId, t.sessionKey, w.state, s.controllerOrigin, s.wakeKind,
                      s.controllerState, s.chargedGeneration
               FROM turns t
               JOIN wakes w ON w.wakeId=t.wakeId
               JOIN supervision_liveness_sidecar s ON s.wakeId=w.wakeId
               WHERE t.seq=?1
               """,
               [successor_turn_seq]
             )

    assert successor_wake_id != source_wake.wake_id

    assert %{
             supervisionState: "parent_elevated",
             supervisionCause: "legacy_parent_target_retired",
             supervisionPrincipal: "process:tightbeam",
             supervisionTransferWakeId: ^successor_wake_id,
             supervisionTransferSessionKey: ^main_key,
             supervisionRetirementEpoch: ^activation_epoch,
             supervisionRetirementOutcomeKind: "main_elevation",
             supervisionRetirementOutcomeId: ^successor_id,
             supervisionActionNeeded: true
           } = Supervision.prod_state(ctx.db, "asg_1")

    assert {:ok, [[2, 2]]} =
             DB.query(
               ctx.db,
               "SELECT COUNT(*), COUNT(DISTINCT wakeId) FROM turns WHERE assignmentId='asg_1'"
             )

    assert :ok = stop_supervised(Supervision)
    _replay = start_liveness!(ctx, sweep_ms: 60_000)

    assert {:ok, [[2, 2]]} =
             DB.query(
               ctx.db,
               "SELECT COUNT(*), COUNT(DISTINCT wakeId) FROM turns WHERE assignmentId='asg_1'"
             )
  end

  test "n zero escalates, retired rungs are skipped, and the holder-seeded cycle sinks at Main",
       ctx do
    insert_entitlement!(ctx.db, "asg_1", generation: 1, due_at: 0)
    seq = terminal!(ctx.db, "holder")

    assert {:escalated, 1, "supervisor"} =
             Supervision.evaluate(ctx.db, ctx.handlers, 0, "holder", seq)

    assert [wake] = Wakes.list_pending(ctx.db)
    assert wake.reresolve == "lineage"
    assert wake.reresolve_seed == "holder"
    assert wake.reresolve_rung == 1

    {:ok, _} =
      DB.query(ctx.db, "UPDATE sessions SET spawnedBy = 'holder' WHERE sessionKey = 'supervisor'")

    assert Supervision.ladder_target(ctx.db, "holder", 1) == "supervisor"
    assert Supervision.ladder_target(ctx.db, "holder", 2) == ctx.main.session_key

    retire!(ctx.db, "supervisor")
    assert Supervision.ladder_target(ctx.db, "holder", 1) == ctx.main.session_key
  end

  # The ladder's last rung is the owner's MAIN session, and that key is composed
  # from a user id rather than read from a row. Every substrate notice addressed
  # to a user with no main session went to a session that does not exist, was
  # accepted by delivery, and queued forever — six of them in one soak.
  test "the ladder answers nobody rather than composing a key for a session that has no row",
       ctx do
    assert Supervision.ladder_target(ctx.db, "holder", 2) == ctx.main.session_key

    {:ok, _} =
      DB.query(ctx.db, "DELETE FROM sessions WHERE sessionKey = ?1", [ctx.main.session_key])

    assert Supervision.ladder_target(ctx.db, "holder", 2) == nil
    # Rungs above the chain are the same answer, not a deeper composed key.
    assert Supervision.ladder_target(ctx.db, "holder", 9) == nil
  end

  test "a retired main session is nobody too — the ladder verifies, it does not compose", ctx do
    retire!(ctx.db, ctx.main.session_key)
    assert Supervision.ladder_target(ctx.db, "holder", 2) == nil
  end

  # Review finding 2. The watermark row says "escalation"; retiring it as
  # terminus must clear THAT row. Clearing against a rewritten branch loses the
  # CAS silently, and a watermark that never clears re-enters this path — and
  # re-logs it — on every one-second sweep, forever.
  test "an escalation whose ladder empties at drain time clears its watermark", ctx do
    insert_entitlement!(ctx.db, "asg_1", generation: 1, due_at: 0)
    seq = terminal!(ctx.db, "holder")

    assert {:escalated, 1, "supervisor"} =
             Supervision.evaluate(ctx.db, ctx.handlers, 0, "holder", seq)

    # Re-arm a pending ESCALATION on the row, then empty the ladder underneath
    # it. Re-evaluating the SAME terminal keeps evaluate on its :duplicate path,
    # so nothing rewrites the watermark after the drain — which is the only way
    # to see whether the drain itself cleared it. Re-evaluating a NEW terminal
    # masks the bug: claim_and_act overwrites the whole row regardless.
    {:ok, _} =
      DB.query(
        ctx.db,
        "UPDATE supervision_watermarks SET lastEvaluatedTerminal=?1, pendingBranch='escalation', pendingAssignment='asg_1', pendingK=1, pendingN=0 WHERE sessionKey='holder'",
        [seq]
      )

    retire!(ctx.db, "supervisor")

    {:ok, _} =
      DB.query(ctx.db, "DELETE FROM sessions WHERE sessionKey = ?1", [ctx.main.session_key])

    Supervision.evaluate(ctx.db, ctx.handlers, 0, "holder", seq)

    # THE property: the row the drain cleared is the row the database holds.
    assert %{pendingBranch: nil, pendingAssignment: nil} = Supervision.watermark(ctx.db, "holder")
  end

  # The reproduction, end to end: this is the exact shape of the six orphans —
  # `process:tightbeam` re-resolving a lineage whose owner has no main session.
  test "a lineage notice for an owner with no main session enqueues nothing and is named", ctx do
    retire!(ctx.db, "supervisor")

    {:ok, _} =
      DB.query(ctx.db, "DELETE FROM sessions WHERE sessionKey = ?1", [ctx.main.session_key])

    gate = %{reresolve: "lineage", reresolve_seed: "holder", reresolve_rung: 1}

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert :skipped =
                 Gateway.deliver_prompt(
                   ctx.main.session_key,
                   "process:tightbeam",
                   "a notice with no deliverable holder",
                   db: ctx.db,
                   sender: "process:tightbeam",
                   target_gate: gate
                 )
      end)

    assert log =~ "undeliverable"
    assert log =~ "holder"

    assert {:ok, [[0]]} = DB.query(ctx.db, "SELECT COUNT(*) FROM turns")
    assert Ledger.non_terminal_older_than(ctx.db, -1) == []
  end

  # Review finding 4, on the GATE-LESS arm — the one path that reaches the echo,
  # because it accepts its session key without re-resolving anything. The echo
  # commits in the same transaction and cannot be taken back, so a refused
  # delivery must write NOTHING: a message with no turn is history nobody can
  # answer, and it surfaces as ghost transcript if that key is ever created.
  test "a refused delivery commits no message, not just no turn", ctx do
    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert :skipped =
                 Gateway.deliver_prompt(
                   "agent:main:clawline:nobody:main",
                   "process:tightbeam",
                   "a notice for a key that names no session",
                   db: ctx.db,
                   sender: "process:tightbeam"
                 )
      end)

    assert log =~ "refusing a turn addressed to agent:main:clawline:nobody:main"
    assert {:ok, [[0]]} = DB.query(ctx.db, "SELECT COUNT(*) FROM turns")

    assert {:ok, [[0]]} =
             DB.query(ctx.db, "SELECT COUNT(*) FROM messages WHERE sessionKey = ?1", [
               "agent:main:clawline:nobody:main"
             ])
  end

  test "retirement revokes the held assignment and cancels its pending wake", ctx do
    existing =
      Wakes.schedule(ctx.db, %{
        session_key: "holder",
        target_role: nil,
        origin: "user:flynn",
        prompt: "later",
        due_at: System.system_time(:millisecond) + 60_000
      })

    seq = terminal!(ctx.db, "holder")
    retire!(ctx.db, "holder")

    assert :idle = Supervision.evaluate(ctx.db, ctx.handlers, 3, "holder", seq)
    assert Wakes.get(ctx.db, existing.wake_id).state == "canceled"
    assert Assignments.list(ctx.db, %{holder_key: "holder", state: "open"}) == []

    assert {:ok, [["closed", "revoked"]]} =
             DB.query(ctx.db, "SELECT state, outcome FROM assignments WHERE id='asg_1'")
  end

  test "turn-end remedy acts once through the episode claim and records run-remedy", ctx do
    prepare_review_gate(ctx)
    seq = terminal!(ctx.db, "holder")

    assert {:acted, :rail_remedy} =
             Supervision.evaluate(ctx.db, ctx.handlers, 3, "holder", seq)

    assert :duplicate = Supervision.evaluate(ctx.db, ctx.handlers, 3, "holder", seq)

    assert %{status: "live", occurrence: 1, producer_key: producer_key} =
             RailRemedy.episode(ctx.db, "completion-needs-review", "asg_1")

    assert is_binary(producer_key)

    assert {:ok, [[1]]} =
             DB.query(
               ctx.db,
               "SELECT COUNT(*) FROM assignments WHERE reviewsAssignmentId = 'asg_1'"
             )

    assert [
             %{
               "decision" => "run-remedy",
               "ref" => "asg_1",
               "statute" => "completion-needs-review"
             }
           ] = rail_sweep_details(ctx.db, "holder")

    assert Supervision.prod_state(ctx.db, "asg_1") == nil
  end

  test "turn-end escalation still opens and parks the same decision request", ctx do
    write_rules(
      ctx,
      """
      [[rule]]
      name = "completion-needs-owner"
      verb = "attest"
      text = "owner approval required"
      edges = ["verb", "turn-end"]
      effect = "escalate"
      deny_when = [
        { fact = "attest.kind", op = "eq", value = "completion" }
      ]
      """
    )

    seq = terminal!(ctx.db, "holder")

    assert {:acted, :rail_escalate} =
             Supervision.evaluate(ctx.db, ctx.handlers, 3, "holder", seq)

    assert {:ok, [[id, "open", park_wake_id]]} =
             DB.query(
               ctx.db,
               "SELECT id, status, parkWakeId FROM decision_requests WHERE statuteName = 'completion-needs-owner'"
             )

    assert is_binary(id)
    assert is_binary(park_wake_id)

    assert %{condition_kind: "escalation-ruled", condition_scope: ^id} =
             Wakes.get(ctx.db, park_wake_id)

    assert [
             %{
               "decision" => "escalate-park",
               "ref" => "asg_1",
               "statute" => "completion-needs-owner"
             }
           ] = rail_sweep_details(ctx.db, "holder")
  end

  test "a permanently skipped park does not re-evaluate inline or starve the server", ctx do
    write_rules(
      ctx,
      """
      [[rule]]
      name = "completion-needs-owner"
      verb = "attest"
      text = "owner approval required"
      edges = ["verb", "turn-end"]
      effect = "escalate"
      deny_when = [
        { fact = "attest.kind", op = "eq", value = "completion" }
      ]
      """
    )

    assert {:acted, :rail_escalate} =
             Supervision.evaluate(ctx.db, ctx.handlers, 3, "holder", terminal!(ctx.db, "holder"))

    {:ok, [[id, park_wake_id]]} =
      DB.query(ctx.db, "SELECT id, parkWakeId FROM decision_requests")

    proxy = :"park_rule_race_db_#{System.unique_integer([:positive])}"
    start_supervised!({ParkRaceDB, {proxy, ctx.db, self(), :rule_allow}})
    name = :"park_no_spin_supervision_#{System.unique_integer([:positive])}"

    start_supervised!(
      {Supervision,
       db: proxy, handlers: ctx.handlers, prod_limit: 3, sweep_ms: 60_000, name: name}
    )

    :sys.get_state(name)
    cancel_wake!(ctx.db, Wakes.get(ctx.db, park_wake_id))

    {:ok, _} =
      DB.query(ctx.db, "UPDATE decision_requests SET parkWakeId = NULL WHERE id = ?1", [id])

    retry_seq = terminal!(ctx.db, "holder")
    Supervision.notify_terminal(name, "holder", retry_seq)

    assert_receive {:request_changed_before_park, :rule_allow, ^id}

    # The first barrier proves the terminal handler returned. If that handler self-cast a
    # retry, the cast may sit just behind this already-queued call; the second barrier is
    # necessarily behind it and therefore proves that no inline retry was left to run.
    :sys.get_state(name)
    :sys.get_state(name)
    refute_receive {:request_rechecked, :rule_allow, _}

    assert {:ok, [["ruled", nil]]} =
             DB.query(ctx.db, "SELECT status, parkWakeId FROM decision_requests WHERE id = ?1", [
               id
             ])

    refute match?(
             %{lastEvaluatedTerminal: ^retry_seq},
             Supervision.watermark(ctx.db, "holder")
           )
  end

  test "the production sweep re-drives a permanent skip and parks a still-live obligation",
       ctx do
    write_rules(
      ctx,
      """
      [[rule]]
      name = "completion-needs-owner"
      verb = "attest"
      text = "owner approval required"
      edges = ["verb", "turn-end"]
      effect = "escalate"
      deny_when = [
        { fact = "attest.kind", op = "eq", value = "completion" }
      ]
      """
    )

    assert {:acted, :rail_escalate} =
             Supervision.evaluate(ctx.db, ctx.handlers, 3, "holder", terminal!(ctx.db, "holder"))

    {:ok, [[stale_id, park_wake_id]]} =
      DB.query(ctx.db, "SELECT id, parkWakeId FROM decision_requests")

    proxy = :"park_withdraw_race_db_#{System.unique_integer([:positive])}"
    start_supervised!({ParkRaceDB, {proxy, ctx.db, self(), :withdraw}})
    name = :"park_sweep_supervision_#{System.unique_integer([:positive])}"

    start_supervised!(
      {Supervision, db: proxy, handlers: ctx.handlers, prod_limit: 3, sweep_ms: 10, name: name}
    )

    :sys.get_state(name)
    cancel_wake!(ctx.db, Wakes.get(ctx.db, park_wake_id))

    {:ok, _} =
      DB.query(ctx.db, "UPDATE decision_requests SET parkWakeId = NULL WHERE id = ?1", [stale_id])

    retry_seq = terminal!(ctx.db, "holder")
    Supervision.notify_terminal(name, "holder", retry_seq)

    assert_receive {:request_changed_before_park, :withdraw, ^stale_id}
    assert_receive {:request_rechecked, :withdraw, 2}

    assert eventually(fn ->
             match?(
               {:ok, [[^stale_id, "withdrawn", nil], [new_id, "open", park_wake_id]]}
               when new_id != stale_id and is_binary(park_wake_id),
               DB.query(
                 ctx.db,
                 "SELECT id, status, parkWakeId FROM decision_requests ORDER BY rowid"
               )
             )
           end),
           "the scheduled supervision sweep never parked the replacement request"

    assert %{lastEvaluatedTerminal: ^retry_seq} = Supervision.watermark(ctx.db, "holder")
  end

  test "only a durable self-created continuation suppresses the turn-end remedy", ctx do
    prepare_review_gate(ctx)

    self_wake =
      Wakes.schedule(ctx.db, %{
        session_key: "holder",
        target_role: nil,
        origin: "user:flynn",
        prompt: "self continuation",
        due_at: System.system_time(:millisecond) + 60_000,
        creator_session_key: "holder"
      })

    assert Wakes.self_pending_count(ctx.db, "holder") == 1
    seq = terminal!(ctx.db, "holder")
    assert :idle = Supervision.evaluate(ctx.db, ctx.handlers, 3, "holder", seq)
    assert RailRemedy.episode(ctx.db, "completion-needs-review", "asg_1") == nil
    assert Supervision.prod_state(ctx.db, "asg_1") == nil

    cancel_wake!(ctx.db, self_wake)

    reminder =
      Wakes.schedule(ctx.db, %{
        session_key: "holder",
        target_role: nil,
        origin: "user:flynn",
        prompt: "user reminder",
        due_at: System.system_time(:millisecond) + 60_000,
        creator_session_key: nil
      })

    assert Wakes.pending_count(ctx.db, "holder") == 1
    assert Wakes.self_pending_count(ctx.db, "holder") == 0

    assert {:acted, :rail_remedy} =
             Supervision.evaluate(ctx.db, ctx.handlers, 3, "holder", seq)

    assert %{status: "live"} =
             RailRemedy.episode(ctx.db, "completion-needs-review", "asg_1")

    assert Wakes.get(ctx.db, reminder.wake_id).state == "pending"
    assert Supervision.prod_state(ctx.db, "asg_1") == nil
  end

  test "an unrelated held classed fyi wake does not suppress the turn-end remedy", ctx do
    # Sol xhigh review, finding 8: `schedule_in_txn/2` leaves a class-held
    # member in ordinary `pending` state while moving `dueAt` out to the
    # ceiling. Undelivered mail sitting in the batcher's queue for up to four
    # hours is not a queued continuation supervision can rely on — counting
    # it here let delivery policy silently change WHETHER the fallback fires,
    # not merely when the fyi consumes attention.
    prepare_review_gate(ctx)

    held =
      Wakes.schedule(ctx.db, %{
        session_key: "holder",
        target_role: nil,
        origin: "user:flynn",
        prompt: "unrelated fyi, held by the batcher",
        due_at: System.system_time(:millisecond) + 60_000,
        creator_session_key: "holder",
        class: "fyi"
      })

    assert held.delivery_rule == Wakes.digest_rule()
    refute held.digest, "still a member, not yet a materialized carrier"

    assert Wakes.self_pending_count(ctx.db, "holder") == 0,
           "a held classed member must not read as an already-pending continuation"

    seq = terminal!(ctx.db, "holder")

    assert {:acted, :rail_remedy} =
             Supervision.evaluate(ctx.db, ctx.handlers, 3, "holder", seq)

    assert %{status: "live"} =
             RailRemedy.episode(ctx.db, "completion-needs-review", "asg_1")

    # The held fyi is untouched by any of this — supervision's own decision
    # neither judged it nor held it; delivery timing stayed the batcher's.
    assert Wakes.get(ctx.db, held.wake_id).state == "pending"
  end

  test "turn-end denial without a remedy records re-obligate and uses the normal prod", ctx do
    insert_entitlement!(ctx.db, "asg_1", generation: 1, due_at: 0)
    load_turn_end_deny(ctx)
    seq = terminal!(ctx.db, "holder")

    assert {:prodded, 1} = Supervision.evaluate(ctx.db, ctx.handlers, 3, "holder", seq)

    assert [
             %{
               "decision" => "re-obligate",
               "ref" => "asg_1",
               "statute" => "completion-still-owed"
             }
           ] = rail_sweep_details(ctx.db, "holder")
  end

  # The sweep is the second actor, so the ruling of 2026-07-29 (rails-mechanism §A3) has
  # to reach it too: a rail-check timeout summons a mind here as well. What it must NOT do
  # is park the session — parking is the escalate EFFECT's consequence, and the ruling
  # changed what a timeout additionally does, not what it decides. So the sweep outcome
  # stays the pure deny's: re-obligate, then the normal prod.
  test "a turn-end timeout summons a mind and still re-obligates without parking", ctx do
    insert_entitlement!(ctx.db, "asg_1", generation: 1, due_at: 0)
    stage_rail_wrapper(ctx, "rail-timeout")

    write_rules(ctx, """
    [[rule]]
    name = "completion-check-times-out"
    verb = "attest"
    text = "completion is gated on a check"
    edges = ["turn-end"]
    [rule.check]
    script = "rail-timeout"
    returns = ["pass"]
    [rule.check.effects]
    pass = "allow"
    """)

    seq = terminal!(ctx.db, "holder")

    assert {:prodded, 1} = Supervision.evaluate(ctx.db, ctx.handlers, 3, "holder", seq)

    assert [
             %{
               "decision" => "re-obligate",
               "ref" => "asg_1",
               "statute" => "completion-check-times-out"
             }
           ] = rail_sweep_details(ctx.db, "holder")

    assert {:ok, [["completion-check-times-out", "open", nil]]} =
             DB.query(ctx.db, "SELECT statuteName, status, parkWakeId FROM decision_requests")
  end

  # Recovery through the SWEEP, driven by the real `Supervision.evaluate/5` wiring rather
  # than by calling `Rules.decide` and the close by hand — the point is that the sweep
  # actually runs its `to_close`, which hand-calling the pieces would assume rather than
  # prove. The sensor heals between two turn-ends and the episode closes with no operator
  # verb anywhere in the loop.
  test "the turn-end sweep recovers an episode once the check answers again", ctx do
    insert_entitlement!(ctx.db, "asg_1", generation: 1, due_at: 0)
    stage_rail_wrapper(ctx, "rail-timeout")

    gate = fn script ->
      write_rules(ctx, """
      [[rule]]
      name = "completion-check-times-out"
      verb = "attest"
      text = "completion is gated on a check"
      edges = ["turn-end"]
      [rule.check]
      script = "#{script}"
      returns = ["pass"]
      [rule.check.effects]
      pass = "allow"
      """)
    end

    gate.("rail-timeout")

    assert {:prodded, 1} =
             Supervision.evaluate(ctx.db, ctx.handlers, 3, "holder", terminal!(ctx.db, "holder"))

    assert {:ok, [[id, "open"]]} =
             DB.query(ctx.db, "SELECT id, status FROM decision_requests")

    # A pending prod wake suppresses the next sweep, so clear it the way the prod-counter
    # tests do — the turn under test is the one AFTER the sensor heals.
    for wake <- Wakes.list_pending(ctx.db), do: cancel_wake!(ctx.db, wake)

    # The check recovers. The next sweep renders an observed verdict and the episode goes
    # with it — through the sweep's own actor path.
    stage_rail_script(ctx, "rail-pass", "#!/bin/sh\nprintf pass\n")
    gate.("rail-pass")

    {:ok, _} =
      DB.query(
        ctx.db,
        "UPDATE supervision_entitlements SET dueAt=0 WHERE assignmentId='asg_1' AND state='armed'"
      )

    assert {:prodded, _} =
             Supervision.evaluate(ctx.db, ctx.handlers, 3, "holder", terminal!(ctx.db, "holder"))

    assert {:ok, [["withdrawn", "process:tightbeam", "sensor-recovered"]]} =
             DB.query(
               ctx.db,
               "SELECT status, withdrawnBy, withdrawnReason FROM decision_requests WHERE id = ?1",
               [id]
             )
  end

  test "atomic target gate skips plain dead targets and re-runs the ladder for escalation", ctx do
    registry = start_supervised!({ConnRegistry, name: :supervision_conn_registry})
    lane = start_supervised!({LaneDoorbell, :supervision_lane_manager})
    retire!(ctx.db, "supervisor")

    plain =
      Wakes.schedule(ctx.db, %{
        session_key: "supervisor",
        target_role: nil,
        origin: "process:tightbeam",
        prompt: "plain",
        due_at: 0
      })

    assert :skipped =
             Gateway.deliver_prompt("supervisor", "process:tightbeam", "plain",
               db: ctx.db,
               wake_id: plain.wake_id,
               sender: "process:tightbeam",
               target_gate: plain,
               fire_wake_in_txn: true,
               conn_registry: registry,
               lane_manager: lane
             )

    assert Ledger.pending_count(ctx.db, "supervisor") == 0
    assert Wakes.get(ctx.db, plain.wake_id).state == "pending"
    cancel_wake!(ctx.db, plain)

    gate = %{reresolve: "lineage", reresolve_seed: "holder", reresolve_rung: 1}

    assert :appended =
             Gateway.deliver_prompt("supervisor", "process:tightbeam", "escalate",
               db: ctx.db,
               wake_id: "w_lineage",
               sender: "process:tightbeam",
               target_gate: gate,
               conn_registry: registry,
               lane_manager: lane
             )

    assert Ledger.pending_count(ctx.db, ctx.main.session_key) == 1
    assert Ledger.pending_count(ctx.db, "holder") == 0
  end

  test "F1 and F8.3 supervision delivery commits before its exact acknowledged terminal", ctx do
    insert_entitlement!(ctx.db, "asg_1", generation: 1, due_at: 0)
    seq = terminal!(ctx.db, "holder")
    assert {:prodded, 1} = Supervision.evaluate(ctx.db, ctx.handlers, 2, "holder", seq)
    [originating] = Wakes.list_pending(ctx.db)

    assert {:ok, [["asg_1", wake_id, "prod", 1, ^seq, nil]]} =
             DB.query(
               ctx.db,
               "SELECT assignmentId,originatingWakeId,recoveryBranch,recoveryRung,sourceTerminalId,answerTerminalId FROM supervision_patrol_response_episodes"
             )

    assert wake_id == originating.wake_id

    assert {:ok,
            [[^wake_id, "asg_1", "holder", "supervision_episode", ^wake_id, 0, ^wake_id, nil, 0]]} =
             DB.query(
               ctx.db,
               "SELECT wakeId,assignmentId,holderKey,sourceKind,sourceRef,sourceVersion,rootWakeId,predecessorWakeId,retryOrdinal FROM patrol_output_sources"
             )

    parent = self()
    registry = start_supervised!({ConnRegistry, name: :atomic_fire_registry})

    lane =
      start_supervised!(
        {RaceLane,
         {:atomic_fire_lane,
          fn "holder" ->
            state_at_nudge = Wakes.get(ctx.db, originating.wake_id).state
            assert {:ok, turn} = Ledger.claim_next(ctx.db, "holder", "atomic-fire-race")
            assert turn.wake_id == originating.wake_id
            assert :ok = Ledger.finish(ctx.db, turn.seq, "delivered")

            {:ok, _} =
              DB.query(
                ctx.db,
                "UPDATE supervision_entitlements SET dueAt=0 WHERE assignmentId='asg_1' AND state='armed'"
              )

            result = Supervision.evaluate(ctx.db, ctx.handlers, 2, "holder", turn.seq)
            send(parent, {:race_result, state_at_nudge, result})
          end}}
      )

    scheduler =
      start_supervised!(
        {Wakes,
         db: ctx.db,
         deliver: delivery_fun(ctx.db, registry, lane),
         tick_ms: 60_000,
         name: :atomic_fire_scheduler}
      )

    assert :ok = Wakes.fire_due(scheduler)
    assert_receive {:race_result, "fired", :patrol_response_acknowledged}
    assert Wakes.get(ctx.db, originating.wake_id).state == "fired"
    assert Wakes.list_pending(ctx.db) == []

    assert {:ok,
            [[answer_terminal, acknowledged_at, "patrol_answer_terminal", "process:tightbeam"]]} =
             DB.query(
               ctx.db,
               "SELECT answerTerminalId,acknowledgedAt,acknowledgmentCause,acknowledgmentPrincipal FROM supervision_patrol_response_episodes WHERE originatingWakeId=?1",
               [originating.wake_id]
             )

    assert is_integer(answer_terminal)
    assert is_integer(acknowledged_at)
  end

  test "external direct wake keeps deliver-then-mark ordering", ctx do
    external =
      Wakes.schedule(ctx.db, %{
        session_key: "holder",
        target_role: nil,
        origin: "process:ci",
        prompt: "external",
        due_at: 0
      })

    parent = self()
    registry = start_supervised!({ConnRegistry, name: :external_order_registry})

    lane =
      start_supervised!(
        {RaceLane,
         {:external_order_lane,
          fn "holder" ->
            send(parent, {:external_state_at_nudge, Wakes.get(ctx.db, external.wake_id).state})
          end}}
      )

    scheduler =
      start_supervised!(
        {Wakes,
         db: ctx.db,
         deliver: delivery_fun(ctx.db, registry, lane),
         tick_ms: 60_000,
         name: :external_order_scheduler}
      )

    assert :ok = Wakes.fire_due(scheduler)
    assert_receive {:external_state_at_nudge, "pending"}
    assert Wakes.get(ctx.db, external.wake_id).state == "fired"
  end

  test "F1 synchronous patrol answer quiesces at its exact delivered terminal",
       ctx do
    n = 12
    assignment(ctx.db, "asg_main", ctx.main.session_key, "main work", 2)
    insert_entitlement!(ctx.db, "asg_main", generation: 1, due_at: 0)
    seq = terminal!(ctx.db, ctx.main.session_key)

    assert {:prodded, 1} =
             Supervision.evaluate(ctx.db, ctx.handlers, n, ctx.main.session_key, seq)

    parent = self()
    registry = start_supervised!({ConnRegistry, name: :repeated_race_registry})

    lane =
      start_supervised!(
        {RaceLane,
         {:repeated_race_lane,
          fn session_key ->
            assert {:ok, turn} = Ledger.claim_next(ctx.db, session_key, "repeated-race")
            state_at_nudge = Wakes.get(ctx.db, turn.wake_id).state
            assert :ok = Ledger.finish(ctx.db, turn.seq, "delivered")

            {:ok, _} =
              DB.query(
                ctx.db,
                "UPDATE supervision_entitlements SET dueAt=0 WHERE assignmentId='asg_main' AND state='armed'"
              )

            result = Supervision.evaluate(ctx.db, ctx.handlers, n, session_key, turn.seq)
            send(parent, {:iteration_result, turn.wake_id, state_at_nudge, result})
          end}}
      )

    scheduler =
      start_supervised!(
        {Wakes,
         db: ctx.db,
         deliver: delivery_fun(ctx.db, registry, lane),
         tick_ms: 60_000,
         name: :repeated_race_scheduler}
      )

    assert :ok = Wakes.fire_due(scheduler)
    assert_receive {:iteration_result, wake_id, "fired", :patrol_response_acknowledged}
    assert Wakes.get(ctx.db, wake_id).state == "fired"

    assert Wakes.pending_count(ctx.db, ctx.main.session_key) == 0
    assert Ledger.pending_count(ctx.db, ctx.main.session_key) == 0
    assert %{pendingBranch: nil} = Supervision.watermark(ctx.db, ctx.main.session_key)

    assert Enum.count(EventLog.lifecycle_events(ctx.db), &(&1.kind == "supervision_terminus")) ==
             0
  end

  test "delivered prod and escalation prompts match the stamped templates byte for byte", ctx do
    insert_entitlement!(ctx.db, "asg_1", generation: 1, due_at: 0)
    registry = start_supervised!({ConnRegistry, name: :template_registry})
    lane = start_supervised!({LaneDoorbell, :template_lane})

    prod_seq = terminal!(ctx.db, "holder")
    assert {:prodded, 1} = Supervision.evaluate(ctx.db, ctx.handlers, 3, "holder", prod_seq)
    [prod] = Wakes.list_pending(ctx.db)

    assert :appended =
             Gateway.deliver_prompt(prod.session_key, prod.origin, prod.prompt,
               db: ctx.db,
               wake_id: prod.wake_id,
               sender: prod.origin,
               target_gate: prod,
               fire_wake_in_txn: true,
               conn_registry: registry,
               lane_manager: lane
             )

    expected_prod =
      "[from process:tightbeam]\n\n" <>
        "Your turn ended with no filing and no continuation scheduled for assignment asg_1 — \"ship it\". " <>
        "File completion, schedule your continuation, or file surrender. This is prod 1 of 3; " <>
        "a reply without a row escalates to your spawner."

    assert {:ok, [[^expected_prod]]} =
             DB.query(ctx.db, "SELECT prompt FROM turns WHERE wakeId = ?1", [prod.wake_id])

    # v1 excluded prod turns from attribution for want of a durable carrier;
    # job-forensics-v2 gives the wake one, so the delivered turn now inherits it.
    # jobRef stays NULL here because this assignment belongs to no work item.
    assert prod.assignment_id == "asg_1"

    assert {:ok, [["asg_1", nil]]} =
             DB.query(
               ctx.db,
               "SELECT assignmentId, jobRef FROM turns WHERE wakeId = ?1",
               [prod.wake_id]
             )

    session(ctx.db, "escalating-holder", ctx.supervisor.session_key)
    assignment(ctx.db, "asg_escalation", "escalating-holder", "investigate", 3)
    insert_entitlement!(ctx.db, "asg_escalation", generation: 1, due_at: 0)
    escalation_seq = terminal!(ctx.db, "escalating-holder")

    assert {:escalated, 1, "supervisor"} =
             Supervision.evaluate(ctx.db, ctx.handlers, 0, "escalating-holder", escalation_seq)

    [escalation] = Wakes.list_pending(ctx.db)

    assert {:ok, [["escalation", "pending", 2]]} =
             DB.query(
               ctx.db,
               "SELECT wakeKind,controllerState,chargedGeneration FROM supervision_liveness_sidecar WHERE wakeId=?1",
               [escalation.wake_id]
             )

    assert {:error, %DB.Error{message: pending_sidecar_update}} =
             DB.query(
               ctx.db,
               "UPDATE supervision_liveness_sidecar SET wakeKind='prod' WHERE wakeId=?1",
               [escalation.wake_id]
             )

    assert pending_sidecar_update =~ "pending supervision controller permits settlement only"

    assert {:error, %DB.Error{message: pending_sidecar_delete}} =
             DB.query(
               ctx.db,
               "DELETE FROM supervision_liveness_sidecar WHERE wakeId=?1",
               [escalation.wake_id]
             )

    assert pending_sidecar_delete =~ "pending supervision controller sidecar is required"

    assert {:error, %DB.Error{message: pending_wake_update}} =
             DB.query(
               ctx.db,
               "UPDATE wakes SET sessionKey='holder' WHERE wakeId=?1",
               [escalation.wake_id]
             )

    assert pending_wake_update =~ "pending supervision controller wake identity is immutable"

    incoherent =
      Wakes.schedule(ctx.db, %{
        session_key: "holder",
        origin: "process:ci",
        prompt: "not a supervision controller",
        due_at: 0,
        assignment_id: "asg_escalation"
      })

    assert {:error, %DB.Error{message: incoherent_insert}} =
             DB.query(
               ctx.db,
               """
               INSERT INTO supervision_liveness_sidecar
                 (wakeId,assignmentId,controllerOrigin,wakeKind,controllerState,chargedGeneration)
               VALUES (?1,'asg_escalation','scheduled','prod','pending',2)
               """,
               [incoherent.wake_id]
             )

    assert incoherent_insert =~ "supervision sidecar requires coherent pending wake"

    assert :appended =
             Gateway.deliver_prompt(escalation.session_key, escalation.origin, escalation.prompt,
               db: ctx.db,
               wake_id: escalation.wake_id,
               sender: escalation.origin,
               target_gate: escalation,
               fire_wake_in_txn: true,
               conn_registry: registry,
               lane_manager: lane
             )

    expected_escalation =
      "[from process:tightbeam]\n\n" <>
        "Assignment asg_escalation — \"investigate\" — held by escalating-holder is stalled: " <>
        "0 prods produced no filing and no continuation. This is escalation 1 for this assignment. " <>
        "Why, and what happens next, is your judgment — the substrate only reports the rows."

    assert {:ok, [[^expected_escalation]]} =
             DB.query(ctx.db, "SELECT prompt FROM turns WHERE wakeId = ?1", [escalation.wake_id])

    assert {:error, %DB.Error{message: delete_message}} =
             DB.query(
               ctx.db,
               "DELETE FROM supervision_liveness_sidecar WHERE wakeId=?1",
               [escalation.wake_id]
             )

    assert delete_message =~ "fired supervision lineage sidecar is required"

    assert {:error, %DB.Error{message: update_message}} =
             DB.query(
               ctx.db,
               "UPDATE supervision_liveness_sidecar SET wakeKind='prod' WHERE wakeId=?1",
               [escalation.wake_id]
             )

    assert update_message =~ "fired supervision lineage sidecar identity is immutable"

    assert {:error, %DB.Error{message: state_message}} =
             DB.query(
               ctx.db,
               "UPDATE supervision_liveness_sidecar SET controllerState='pending' WHERE wakeId=?1",
               [escalation.wake_id]
             )

    assert state_message =~ "fired supervision lineage sidecar identity is immutable"

    assert {:error, %DB.Error{message: turn_update_message}} =
             DB.query(
               ctx.db,
               """
               UPDATE turns
               SET seq=seq+100000, sessionKey='holder',
                   wakeId='w_rewritten', assignmentId=NULL
               WHERE wakeId=?1
               """,
               [escalation.wake_id]
             )

    assert turn_update_message =~ "fired supervision lineage turn attribution is immutable"

    assert {:error, %DB.Error{message: turn_delete_message}} =
             DB.query(ctx.db, "DELETE FROM turns WHERE wakeId=?1", [escalation.wake_id])

    assert turn_delete_message =~ "fired supervision lineage turn is required"

    assert {:ok, [["escalation", "settled"]]} =
             DB.query(
               ctx.db,
               "SELECT wakeKind,controllerState FROM supervision_liveness_sidecar WHERE wakeId=?1",
               [escalation.wake_id]
             )
  end

  test "wake validation requires the complete re-resolution triple and nudge false leaves due work pending",
       ctx do
    wake = ctx.handlers["wake"]

    invalid = %{
      origin: "process:tightbeam",
      session_key: "holder",
      params: %{prompt: "x", reresolve: "lineage"}
    }

    assert %{code: "invalid"} = wake.(invalid)

    valid = %{
      origin: "process:tightbeam",
      session_key: "supervisor",
      params: %{
        prompt: "x",
        after_ms: 0,
        nudge: false,
        reresolve: "lineage",
        reresolve_seed: "holder",
        reresolve_rung: 1
      }
    }

    assert %{state: "pending"} = wake.(valid)
    assert [%{reresolve: "lineage"}] = Wakes.list_pending(ctx.db)
  end

  test "F8 boundary 2 supervision wake sidecar episode and source commit atomically", ctx do
    insert_entitlement!(ctx.db, "asg_1", generation: 1, due_at: 0, interval: 60_000)
    seq = terminal!(ctx.db, "holder")

    assert {:escalated, 1, "supervisor"} =
             Supervision.evaluate(ctx.db, ctx.handlers, 0, "holder", seq)

    assert {:ok, [[wake_id, "escalation", "pending", 2]]} =
             DB.query(
               ctx.db,
               """
               SELECT w.wakeId, s.wakeKind, s.controllerState, s.chargedGeneration
               FROM wakes w
               JOIN supervision_liveness_sidecar s ON s.wakeId=w.wakeId
               WHERE w.assignmentId='asg_1'
               """
             )

    assert is_binary(wake_id)
  end

  test "F8 boundary 1 a rejected supervision controller schedule rolls back every row", ctx do
    insert_entitlement!(ctx.db, "asg_1",
      generation: 1,
      due_at: 9_000_000_000_000,
      interval: 60_000
    )

    wake = ctx.handlers["wake"]

    assert_raise RuntimeError, ~r/controller schedule :duplicate/, fn ->
      wake.(%{
        origin: "process:tightbeam",
        principal: {:process, "tightbeam"},
        session_key: "holder",
        params: %{
          prompt: "must not strand a controller wake",
          after_ms: 0,
          nudge: false,
          assignment_id: "asg_1",
          supervision_wake_kind: "prod"
        }
      })
    end

    assert {:ok, [[0]]} =
             DB.query(ctx.db, "SELECT COUNT(*) FROM wakes WHERE assignmentId='asg_1'")

    assert {:ok, [[0]]} =
             DB.query(ctx.db, "SELECT COUNT(*) FROM supervision_liveness_sidecar")
  end

  test "F5 a supervision controller without truthful episode inputs rolls back its wake row",
       ctx do
    {:ok, _} = DB.query(ctx.db, "DELETE FROM supervision_entitlements WHERE assignmentId='asg_1'")
    wake = ctx.handlers["wake"]

    assert_raise RuntimeError, ~r/controller schedule :duplicate/, fn ->
      wake.(%{
        origin: "process:tightbeam",
        principal: {:process, "tightbeam"},
        session_key: "holder",
        params: %{
          prompt: "stale pending supervision branch",
          after_ms: 0,
          nudge: false,
          assignment_id: "asg_1",
          supervision_wake_kind: "prod"
        }
      })
    end

    assert {:ok, [[0]]} =
             DB.query(ctx.db, "SELECT COUNT(*) FROM wakes WHERE assignmentId='asg_1'")

    assert {:ok, [[0]]} =
             DB.query(ctx.db, "SELECT COUNT(*) FROM supervision_liveness_sidecar")
  end

  test "F5 an unknown episode branch rolls back its wake row", ctx do
    wake = ctx.handlers["wake"]

    assert_raise RuntimeError, ~r/unknown controller kind "mystery"/, fn ->
      wake.(%{
        origin: "process:tightbeam",
        principal: {:process, "tightbeam"},
        session_key: "holder",
        params: %{
          prompt: "invalid controller kind",
          after_ms: 0,
          nudge: false,
          assignment_id: "asg_1",
          supervision_wake_kind: "mystery"
        }
      })
    end

    assert {:ok, [[0]]} =
             DB.query(ctx.db, "SELECT COUNT(*) FROM wakes WHERE assignmentId='asg_1'")
  end

  test "F5 every schema-valid invalid episode dimension rolls back with one typed refusal",
       ctx do
    for dimension <- [
          :source_terminal_missing,
          :source_terminal_zero,
          :source_terminal_negative,
          :source_terminal_unknown,
          :source_terminal_other_holder,
          :rung_zero,
          :rung_negative,
          :rung_unequal,
          :wake_other_assignment,
          :escalation_lineage_rung,
          :prod_lineage_fields
        ] do
      assert_invalid_episode_schedule!(ctx, dimension)
    end
  end

  test "production scheduler cancels an unavailable supervision target without stranding its controller",
       ctx do
    insert_entitlement!(ctx.db, "asg_1", generation: 1, due_at: 0)
    terminal_seq = terminal!(ctx.db, "holder")

    assert {:prodded, 1} =
             Supervision.evaluate(ctx.db, ctx.handlers, 3, "holder", terminal_seq)

    assert [wake] = Wakes.list_pending(ctx.db)

    assert {:ok, [["prod", "pending", 2]]} =
             DB.query(
               ctx.db,
               "SELECT wakeKind,controllerState,chargedGeneration FROM supervision_liveness_sidecar WHERE wakeId=?1",
               [wake.wake_id]
             )

    {:ok, _} =
      DB.query(ctx.db, "UPDATE sessions SET state='retired' WHERE sessionKey='holder'")

    registry = start_supervised!({ConnRegistry, name: :unavailable_target_registry})
    lane = start_supervised!({LaneDoorbell, :unavailable_target_lane})

    scheduler =
      start_supervised!(
        {Wakes,
         db: ctx.db,
         deliver: delivery_fun(ctx.db, registry, lane),
         tick_ms: 60_000,
         name: :unavailable_target_scheduler}
      )

    assert :ok = Wakes.fire_due(scheduler)

    assert %{state: "canceled", fired_at: nil} = Wakes.get(ctx.db, wake.wake_id)
    wake_id = wake.wake_id

    assert {:ok, [["settled"]]} =
             DB.query(
               ctx.db,
               "SELECT controllerState FROM supervision_liveness_sidecar WHERE wakeId=?1",
               [wake.wake_id]
             )

    assert {:ok,
            [
              [
                "patrol_source_mismatch",
                "tightbeam:wake-scheduler",
                "scheduler_delivery",
                ^wake_id,
                "no_replacement"
              ]
            ]} =
             DB.query(
               ctx.db,
               "SELECT reasonKind,requesterId,causalSourceKind,causalSourceId,outcomeKind FROM wake_cancellations WHERE wakeId=?1",
               [wake.wake_id]
             )

    assert {:ok, []} = DB.query(ctx.db, "SELECT seq FROM turns WHERE wakeId=?1", [wake.wake_id])
    assert Wakes.list_pending(ctx.db) == []

    assert {:ok, [[^wake_id]]} =
             DB.query(
               ctx.db,
               "SELECT wakeId FROM patrol_output_sources WHERE wakeId=?1",
               [wake.wake_id]
             )
  end

  test "holder retirement tombstones a pending typed patrol wake and preserves its source", ctx do
    insert_entitlement!(ctx.db, "asg_1", generation: 1, due_at: 0)
    terminal_seq = terminal!(ctx.db, "holder")

    assert {:prodded, 1} =
             Supervision.evaluate(ctx.db, ctx.handlers, 3, "holder", terminal_seq)

    assert [wake] = Wakes.list_pending(ctx.db)
    wake_id = wake.wake_id

    retire!(ctx.db, "holder")

    assert %{state: "canceled", fired_at: nil} = Wakes.get(ctx.db, wake_id)

    assert {:ok, [[^wake_id, "supervision_episode"]]} =
             DB.query(
               ctx.db,
               "SELECT wakeId,sourceKind FROM patrol_output_sources WHERE wakeId=?1",
               [wake_id]
             )

    assert {:ok, [["obligation_disposed", "disposition"]]} =
             DB.query(
               ctx.db,
               "SELECT reasonKind,outcomeKind FROM wake_cancellations WHERE wakeId=?1",
               [wake_id]
             )
  end

  test "F5 a schema-valid acknowledgment source mismatch fails closed at delivery", ctx do
    insert_entitlement!(ctx.db, "asg_1", generation: 1, due_at: 60_000)

    wake =
      Wakes.schedule(ctx.db, %{
        session_key: "holder",
        origin: "process:tightbeam",
        prompt: "malformed patrol carrier",
        due_at: 0,
        assignment_id: "asg_1"
      })

    assert {:ok, []} =
             DB.query(
               ctx.db,
               """
               INSERT INTO patrol_output_sources
                 (wakeId,assignmentId,holderKey,sourceKind,sourceRef,sourceVersion,
                  rootWakeId,predecessorWakeId,retryOrdinal,createdAt,
                  sourceCause,sourcePrincipal)
               VALUES (?1,'asg_1','supervisor','supervision_episode',?1,0,
                       ?1,NULL,0,?2,'patrol_output_scheduled','process:tightbeam')
               """,
               [wake.wake_id, wake.created_at]
             )

    assert :skipped =
             Gateway.deliver_prompt(
               "holder",
               "process:tightbeam",
               wake.prompt,
               db: ctx.db,
               wake_id: wake.wake_id,
               sender: wake.origin,
               target_gate: wake,
               fire_wake_in_txn: true,
               assignment_id: "asg_1"
             )

    assert %{state: "canceled", fired_at: nil} = Wakes.get(ctx.db, wake.wake_id)

    assert {:ok, [["patrol_source_mismatch", "no_replacement"]]} =
             DB.query(
               ctx.db,
               "SELECT reasonKind,outcomeKind FROM wake_cancellations WHERE wakeId=?1",
               [wake.wake_id]
             )

    assert {:ok, [[1]]} =
             DB.query(
               ctx.db,
               "SELECT COUNT(*) FROM patrol_output_sources WHERE wakeId=?1",
               [wake.wake_id]
             )

    assert {:ok, []} = DB.query(ctx.db, "SELECT seq FROM turns WHERE wakeId=?1", [wake.wake_id])

    assert :skipped =
             Gateway.deliver_prompt(
               "holder",
               "process:tightbeam",
               wake.prompt,
               db: ctx.db,
               wake_id: wake.wake_id,
               sender: wake.origin,
               target_gate: wake,
               fire_wake_in_txn: true,
               assignment_id: "asg_1"
             )

    assert {:ok, [[1]]} =
             DB.query(
               ctx.db,
               "SELECT COUNT(*) FROM wake_cancellations WHERE wakeId=?1",
               [wake.wake_id]
             )
  end

  test "F18 rejects each frozen retry-chain mismatch one dimension at a time", ctx do
    for dimension <- [
          :assignment,
          :holder,
          :source_kind,
          :source_ref,
          :source_version,
          :root_wake,
          :predecessor_wake,
          :retry_ordinal
        ] do
      assert_retry_dimension_rejected!(ctx, dimension)
    end
  end

  test "F18 later destination generation and current-holder mismatches stop once", ctx do
    for dimension <- [:destination, :generation, :current_holder] do
      assert_later_source_dimension_rejected!(ctx, dimension)
    end
  end

  test "F4 terminal failures and assignment lifecycle outcomes never acknowledge patrol answers",
       ctx do
    for {suffix, terminal_status} <- [
          {"canceled", "canceled"},
          {"failed", "failed"},
          {"failed_unknown", "failed_unknown"}
        ] do
      assignment_id = "asg_f4_#{suffix}"
      holder = "holder_f4_#{suffix}"
      session(ctx.db, holder, "supervisor")
      assignment(ctx.db, assignment_id, holder, suffix, 10)

      %{turn_seq: turn_seq, wake_id: wake_id} =
        prepare_patrol_answer!(ctx, assignment_id, holder)

      case terminal_status do
        "failed_unknown" -> assert [^turn_seq] = Ledger.recover_running(ctx.db)
        status -> assert :ok = Ledger.finish(ctx.db, turn_seq, status)
      end

      assert_no_patrol_acknowledgment!(ctx.db, wake_id, turn_seq)

      refute Supervision.evaluate(ctx.db, ctx.handlers, 3, holder, turn_seq) ==
               :patrol_response_acknowledged

      assert_no_patrol_acknowledgment!(ctx.db, wake_id, turn_seq)
    end

    for {suffix, transition} <- [
          {"completed", :completion},
          {"surrendered", :surrender},
          {"revoked", :revoke}
        ] do
      assignment_id = "asg_f4_#{suffix}"
      holder = "holder_f4_#{suffix}"
      session(ctx.db, holder, "supervisor")
      assignment(ctx.db, assignment_id, holder, suffix, 20)

      %{turn_seq: turn_seq, wake_id: wake_id} =
        prepare_patrol_answer!(ctx, assignment_id, holder)

      result = transition_assignment!(ctx.db, assignment_id, holder, transition)
      assert result.state == "closed"
      assert result.outcome == suffix
      assert :ok = Ledger.finish(ctx.db, turn_seq, "delivered")

      assert_no_patrol_acknowledgment!(ctx.db, wake_id, turn_seq)

      refute Supervision.evaluate(ctx.db, ctx.handlers, 3, holder, turn_seq) ==
               :patrol_response_acknowledged

      assert_no_patrol_acknowledgment!(ctx.db, wake_id, turn_seq)

      assert {:ok, []} =
               DB.query(
                 ctx.db,
                 "SELECT state FROM supervision_entitlements WHERE assignmentId=?1",
                 [
                   assignment_id
                 ]
               )

      assert Enum.any?(
               EventLog.lifecycle_events(ctx.db),
               &(&1.kind == "supervision_entitlement_cleared" and &1.subject == assignment_id)
             )
    end

    assignment(ctx.db, "asg_f4_rail", "holder", "rail wins", 30)

    %{turn_seq: rail_terminal, wake_id: rail_wake_id} =
      prepare_patrol_answer!(ctx, "asg_f4_rail", "holder")

    prepare_review_gate(ctx)
    assert :ok = Ledger.finish(ctx.db, rail_terminal, "delivered")

    assert {:acted, :rail_remedy} =
             Supervision.evaluate(ctx.db, ctx.handlers, 3, "holder", rail_terminal)

    assert {:ok, [[^rail_terminal]]} =
             DB.query(
               ctx.db,
               "SELECT answerTerminalId FROM supervision_patrol_response_episodes WHERE originatingWakeId=?1",
               [rail_wake_id]
             )

    assert Supervision.prod_state(ctx.db, "asg_f4_rail").prodCount == 1
  end

  test "F6 branch and rung episodes acknowledge only their own composite identities", ctx do
    rows = [
      %{name: "prod_1", branch: "prod", rung: 1, n: 3, prior_prods: 0},
      %{name: "prod_2", branch: "prod", rung: 2, n: 3, prior_prods: 1},
      %{name: "escalation_1", branch: "escalation", rung: 1, n: 0, prior_prods: 0},
      %{name: "escalation_2", branch: "escalation", rung: 2, n: 0, prior_prods: 1}
    ]

    prepared =
      Enum.map(rows, fn row ->
        assignment_id = "asg_f6_#{row.name}"
        holder = "holder_f6_#{row.name}"
        session(ctx.db, holder, "supervisor")
        assignment(ctx.db, assignment_id, holder, row.name, 25 + row.rung)
        insert_entitlement!(ctx.db, assignment_id, generation: 1, due_at: 0)

        if row.prior_prods > 0 do
          seed_heard_prod!(ctx, assignment_id, holder)
        end

        source_terminal = terminal!(ctx.db, holder)

        case {row.branch, row.rung} do
          {"prod", rung} ->
            assert {:prodded, ^rung} =
                     Supervision.evaluate(ctx.db, ctx.handlers, row.n, holder, source_terminal)

          {"escalation", rung} ->
            assert {:escalated, ^rung, _target} =
                     Supervision.evaluate(ctx.db, ctx.handlers, row.n, holder, source_terminal)
        end

        wake =
          ctx.db
          |> Wakes.list_pending()
          |> Enum.find(&(&1.assignment_id == assignment_id))

        assert wake
        assert :appended = admit_supervision_wake!(ctx.db, wake)

        assert {:ok, %{seq: answer_terminal, wake_id: wake_id}} =
                 Ledger.claim_next(ctx.db, wake.session_key, "f6-#{row.name}")

        assert wake_id == wake.wake_id

        Map.merge(row, %{
          assignment_id: assignment_id,
          holder: holder,
          source_terminal: source_terminal,
          answer_terminal: answer_terminal,
          wake_id: wake_id
        })
      end)

    prepared
    |> Enum.reverse()
    |> Enum.each(fn row ->
      assert :ok = Ledger.finish(ctx.db, row.answer_terminal, "delivered")
    end)

    for row <- prepared do
      assert {:ok,
              [
                [
                  assignment_id,
                  branch,
                  rung,
                  source_terminal,
                  answer_terminal
                ]
              ]} =
               DB.query(
                 ctx.db,
                 "SELECT assignmentId,recoveryBranch,recoveryRung,sourceTerminalId,answerTerminalId FROM supervision_patrol_response_episodes WHERE originatingWakeId=?1",
                 [row.wake_id]
               )

      assert assignment_id == row.assignment_id
      assert branch == row.branch
      assert rung == row.rung
      assert source_terminal == row.source_terminal
      assert answer_terminal == row.answer_terminal

      assert {:ok, [[1]]} =
               DB.query(
                 ctx.db,
                 "SELECT COUNT(*) FROM supervision_patrol_response_episodes WHERE answerTerminalId=?1",
                 [row.answer_terminal]
               )
    end

    assert {:ok, [[4]]} =
             DB.query(
               ctx.db,
               "SELECT COUNT(DISTINCT assignmentId || ':' || originatingWakeId || ':' || recoveryBranch || ':' || recoveryRung || ':' || sourceTerminalId) FROM supervision_patrol_response_episodes WHERE assignmentId LIKE 'asg_f6_%'"
             )
  end

  test "F7 concurrent finalization and notification consume one answer without crossing lanes",
       ctx do
    %{turn_seq: answer_terminal, wake_id: wake_id} =
      prepare_patrol_answer!(ctx, "asg_1", "holder")

    session(ctx.db, "holder_f7_other", "supervisor")
    assignment(ctx.db, "asg_f7_other", "holder_f7_other", "unrelated", 30)
    insert_entitlement!(ctx.db, "asg_f7_other", generation: 1, due_at: 0)
    unrelated_terminal = terminal!(ctx.db, "holder_f7_other")

    finalizers =
      for owner <- ["finalizer-a", "finalizer-b"] do
        Task.async(fn -> {owner, Ledger.finish(ctx.db, answer_terminal, "delivered")} end)
      end

    assert Enum.sort(Task.await_many(finalizers)) ==
             Enum.sort([{"finalizer-a", :ok}, {"finalizer-b", :already_terminal}])

    evaluations = [
      Task.async(fn ->
        {:answer, Supervision.evaluate(ctx.db, ctx.handlers, 3, "holder", answer_terminal)}
      end),
      Task.async(fn ->
        {:answer, Supervision.evaluate(ctx.db, ctx.handlers, 3, "holder", answer_terminal)}
      end),
      Task.async(fn ->
        {:unrelated,
         Supervision.evaluate(
           ctx.db,
           ctx.handlers,
           3,
           "holder_f7_other",
           unrelated_terminal
         )}
      end)
    ]

    results = Task.await_many(evaluations)
    assert Enum.count(results, &(&1 == {:answer, :patrol_response_acknowledged})) == 1
    assert Enum.count(results, &(&1 == {:answer, :duplicate})) == 1
    assert [{:unrelated, {:prodded, 1}}] = Enum.filter(results, &(elem(&1, 0) == :unrelated))

    assert {:ok, [[^answer_terminal]]} =
             DB.query(
               ctx.db,
               "SELECT answerTerminalId FROM supervision_patrol_response_episodes WHERE originatingWakeId=?1",
               [wake_id]
             )

    assert {:ok, [[1]]} =
             DB.query(
               ctx.db,
               "SELECT COUNT(*) FROM patrol_output_sources WHERE rootWakeId=?1",
               [wake_id]
             )

    assert %{lastEvaluatedTerminal: ^answer_terminal} = Supervision.watermark(ctx.db, "holder")

    assert length(Enum.filter(Wakes.list_pending(ctx.db), &(&1.assignment_id == "asg_f7_other"))) ==
             1

    assert Enum.empty?(Enum.filter(Wakes.list_pending(ctx.db), &(&1.assignment_id == "asg_1")))
  end

  test "F8 boundaries 4 through 6 publish only the committed terminal and acknowledgment", ctx do
    %{turn_seq: answer_terminal, wake_id: wake_id} =
      prepare_patrol_answer!(ctx, "asg_1", "holder")

    assert {:error, %RuntimeError{message: "f8 terminal crash"}} =
             DB.transaction(ctx.db, fn txn ->
               assert true = Ledger.finish_in_txn(txn, answer_terminal, "delivered")
               raise "f8 terminal crash"
             end)

    assert {:ok, [["running"]]} =
             DB.query(ctx.db, "SELECT status FROM turns WHERE seq=?1", [answer_terminal])

    assert {:ok, [[nil]]} =
             DB.query(
               ctx.db,
               "SELECT answerTerminalId FROM supervision_patrol_response_episodes WHERE originatingWakeId=?1",
               [wake_id]
             )

    assert :ok = Ledger.finish(ctx.db, answer_terminal, "delivered")

    assert [%{seq: ^answer_terminal, status: "delivered"}] =
             Enum.filter(Ledger.unpublished_terminals(ctx.db), &(&1.seq == answer_terminal))

    assert :already_terminal = Ledger.finish(ctx.db, answer_terminal, "delivered")

    assert :patrol_response_acknowledged =
             Supervision.evaluate(ctx.db, ctx.handlers, 3, "holder", answer_terminal)

    assert :duplicate =
             Supervision.evaluate(ctx.db, ctx.handlers, 3, "holder", answer_terminal)

    assert {:ok, [[^answer_terminal, 1]]} =
             DB.query(
               ctx.db,
               "SELECT answerTerminalId,(SELECT COUNT(*) FROM patrol_output_sources WHERE rootWakeId=?1) FROM supervision_patrol_response_episodes WHERE originatingWakeId=?1",
               [wake_id]
             )
  end

  test "F9 final patrol state replays idempotently and leaves a later terminal ordinary", ctx do
    %{turn_seq: answer_terminal, wake_id: wake_id} =
      prepare_patrol_answer!(ctx, "asg_1", "holder")

    assert :ok = Ledger.finish(ctx.db, answer_terminal, "delivered")

    assert :patrol_response_acknowledged =
             Supervision.evaluate(ctx.db, ctx.handlers, 3, "holder", answer_terminal)

    assert {:ok, [baseline]} =
             DB.query(
               ctx.db,
               "SELECT assignmentId,originatingWakeId,recoveryBranch,recoveryRung,sourceTerminalId,answerTerminalId,scheduledAt,acknowledgedAt,scheduledCause,scheduledPrincipal,acknowledgmentCause,acknowledgmentPrincipal FROM supervision_patrol_response_episodes WHERE originatingWakeId=?1",
               [wake_id]
             )

    assert {:ok, [[1]]} =
             DB.query(ctx.db, "SELECT COUNT(*) FROM patrol_output_sources WHERE wakeId=?1", [
               wake_id
             ])

    assert {:ok, {:ok, %{answer_terminal_id: ^answer_terminal}}} =
             DB.transaction(ctx.db, fn txn ->
               PatrolResponse.create_supervision_episode_in_txn(txn, wake_id)
             end)

    assert {:ok, {:acknowledged, %{answer_terminal_id: ^answer_terminal}}} =
             DB.transaction(ctx.db, fn txn ->
               PatrolResponse.acknowledge_in_txn(txn, answer_terminal)
             end)

    assert :already_terminal = Ledger.finish(ctx.db, answer_terminal, "delivered")

    assert :duplicate =
             Supervision.evaluate(ctx.db, ctx.handlers, 3, "holder", answer_terminal)

    assert {:ok, [^baseline]} =
             DB.query(
               ctx.db,
               "SELECT assignmentId,originatingWakeId,recoveryBranch,recoveryRung,sourceTerminalId,answerTerminalId,scheduledAt,acknowledgedAt,scheduledCause,scheduledPrincipal,acknowledgmentCause,acknowledgmentPrincipal FROM supervision_patrol_response_episodes WHERE originatingWakeId=?1",
               [wake_id]
             )

    assert {:ok, [[1]]} =
             DB.query(ctx.db, "SELECT COUNT(*) FROM patrol_output_sources WHERE wakeId=?1", [
               wake_id
             ])

    later = terminal!(ctx.db, "holder")

    refute Supervision.evaluate(ctx.db, ctx.handlers, 3, "holder", later) ==
             :patrol_response_acknowledged

    assert {:ok, [^baseline]} =
             DB.query(
               ctx.db,
               "SELECT assignmentId,originatingWakeId,recoveryBranch,recoveryRung,sourceTerminalId,answerTerminalId,scheduledAt,acknowledgedAt,scheduledCause,scheduledPrincipal,acknowledgmentCause,acknowledgmentPrincipal FROM supervision_patrol_response_episodes WHERE originatingWakeId=?1",
               [wake_id]
             )
  end

  test "F10 historical delivery-before-revoke rows stay byte-equal beside admitted-first control",
       ctx do
    assignment(ctx.db, "asg_f10_history", "holder", "historical evidence", 1)

    for {seq, ended_at} <- [
          {19_082, 1_786_525_417_781},
          {19_084, 1_786_525_418_890},
          {19_086, 1_786_525_419_917}
        ] do
      assert {:ok, []} =
               DB.query(
                 ctx.db,
                 "INSERT INTO turns (seq,sessionKey,messageId,origin,prompt,assignmentId,status,createdAt,startedAt,endedAt) VALUES (?1,'holder',?2,'process:tightbeam','historical','asg_f10_history','delivered',?3,?3,?3)",
                 [seq, "m_f10_#{seq}", ended_at]
               )
    end

    revoke_at = 1_786_525_633_131

    assert {:ok, []} =
             DB.query(
               ctx.db,
               "UPDATE assignments SET state='closed',outcome='revoked',closedAt=?2,closedByUser='flynn' WHERE id=?1",
               ["asg_f10_history", revoke_at]
             )

    assert {:ok, historical_before} =
             DB.query(
               ctx.db,
               "SELECT seq,sessionKey,messageId,wakeId,origin,prompt,assignmentId,status,createdAt,startedAt,endedAt,publishedAt FROM turns WHERE seq IN (19082,19084,19086) ORDER BY seq"
             )

    assert Enum.map(historical_before, &Enum.at(&1, 10)) == [
             1_786_525_417_781,
             1_786_525_418_890,
             1_786_525_419_917
           ]

    assert Enum.all?(historical_before, &(Enum.at(&1, 10) < revoke_at))

    session(ctx.db, "holder_f10_control", "supervisor")
    assignment(ctx.db, "asg_f10_control", "holder_f10_control", "admitted control", 140)
    control_wake = prepare_effort_root!(ctx.db, "asg_f10_control", "holder_f10_control")

    assert {:ok, {:appended, "holder_f10_control", _message, _opts}} =
             DB.transaction(ctx.db, fn txn ->
               Gateway.deliver_prompt_in_txn(
                 txn,
                 "holder_f10_control",
                 control_wake.origin,
                 control_wake.prompt,
                 wake_id: control_wake.wake_id,
                 sender: control_wake.origin,
                 target_gate: control_wake,
                 fire_wake_in_txn: true,
                 assignment_id: "asg_f10_control"
               )
             end)

    assert {:ok, %{seq: admitted_turn}} =
             Ledger.claim_next(ctx.db, "holder_f10_control", "f10-control")

    revoked = transition_assignment!(ctx.db, "asg_f10_control", "holder_f10_control", :revoke)
    assert revoked.outcome == "revoked"
    assert :ok = Ledger.finish(ctx.db, admitted_turn, "delivered")

    assert {:ok, [["delivered"]]} =
             DB.query(ctx.db, "SELECT status FROM turns WHERE seq=?1", [admitted_turn])

    assert {:ok, ^historical_before} =
             DB.query(
               ctx.db,
               "SELECT seq,sessionKey,messageId,wakeId,origin,prompt,assignmentId,status,createdAt,startedAt,endedAt,publishedAt FROM turns WHERE seq IN (19082,19084,19086) ORDER BY seq"
             )
  end

  test "F12 lifecycle-before-admission tombstones only the pending wake and queued turn",
       ctx do
    for transition <- [:completion, :surrender, :revoke, :retirement] do
      suffix = Atom.to_string(transition)
      assignment_id = "asg_f12_#{suffix}"
      holder = "holder_f12_#{suffix}"
      session(ctx.db, holder, "supervisor")
      assignment(ctx.db, assignment_id, holder, suffix, 40)

      %{pending_wake: pending_wake, queued_turn: queued_turn} =
        prepare_lifecycle_candidates!(ctx, assignment_id, holder)

      case transition do
        :retirement ->
          retire!(ctx.db, holder)

        other ->
          result = transition_assignment!(ctx.db, assignment_id, holder, other)
          assert result.state == "closed"
      end

      assert %{state: "canceled", fired_at: nil} = Wakes.get(ctx.db, pending_wake.wake_id)

      assert {:ok, [["canceled", ended_at]]} =
               DB.query(ctx.db, "SELECT status,endedAt FROM turns WHERE seq=?1", [queued_turn])

      assert is_integer(ended_at)

      assert {:ok, [[1, "obligation_disposed", "disposition"]]} =
               DB.query(
                 ctx.db,
                 "SELECT COUNT(*),reasonKind,outcomeKind FROM wake_cancellations WHERE wakeId=?1",
                 [pending_wake.wake_id]
               )

      assert Enum.count(
               EventLog.lifecycle_events(ctx.db),
               &(&1.kind == "patrol_turn_stopped" and &1.subject == to_string(queued_turn))
             ) == 1

      assert {:ok, :replay} =
               DB.transaction(ctx.db, fn txn ->
                 PatrolResponse.admit_delivery_in_txn(txn, pending_wake.wake_id, holder)
               end)

      assert :already_terminal = Ledger.finish(ctx.db, queued_turn, "delivered")

      assert {:ok, [[1]]} =
               DB.query(
                 ctx.db,
                 "SELECT COUNT(*) FROM wake_cancellations WHERE wakeId=?1",
                 [pending_wake.wake_id]
               )

      assert Enum.count(
               EventLog.lifecycle_events(ctx.db),
               &(&1.kind == "patrol_turn_stopped" and &1.subject == to_string(queued_turn))
             ) == 1

      assert {:ok, [["canceled"]]} =
               DB.query(
                 ctx.db,
                 "SELECT state FROM effort_checkin_generations WHERE assignmentId=?1",
                 [assignment_id]
               )
    end
  end

  test "F13 closed predecessor retry chains cannot affect a successor on the same work item",
       ctx do
    for placement <- [:shared_holder, :distinct_holders] do
      suffix = Atom.to_string(placement)
      work_item_id = "wi_f13_#{suffix}"
      predecessor_id = "asg_f13_a_#{suffix}"
      successor_id = "asg_f13_b_#{suffix}"
      predecessor_holder = "holder_f13_a_#{suffix}"

      successor_holder =
        if placement == :shared_holder,
          do: predecessor_holder,
          else: "holder_f13_b_#{suffix}"

      session(ctx.db, predecessor_holder, "supervisor")

      if successor_holder != predecessor_holder do
        session(ctx.db, successor_holder, "supervisor")
      end

      assignment(ctx.db, predecessor_id, predecessor_holder, "predecessor", 50)
      assignment(ctx.db, successor_id, successor_holder, "successor", 51)

      %{chain: [root, retry_one, retry_two], queued_turn: queued_turn} =
        prepare_predecessor_chain!(ctx, predecessor_id, predecessor_holder)

      result = transition_assignment!(ctx.db, predecessor_id, predecessor_holder, :completion)
      assert result.state == "closed"
      assert result.outcome == "completed"

      attach_work_item!(ctx.db, predecessor_id, work_item_id)
      attach_work_item!(ctx.db, successor_id, work_item_id)

      insert_entitlement!(ctx.db, successor_id, generation: 1, due_at: 0)
      successor_terminal = terminal!(ctx.db, successor_holder)

      replay_tasks =
        Enum.map([root, retry_one, retry_two], fn wake ->
          Task.async(fn ->
            DB.transaction(ctx.db, fn txn ->
              PatrolResponse.admit_delivery_in_txn(txn, wake.wake_id, predecessor_holder)
            end)
          end)
        end)

      successor_task =
        Task.async(fn ->
          Supervision.evaluate(
            ctx.db,
            ctx.handlers,
            3,
            successor_holder,
            successor_terminal
          )
        end)

      assert Enum.all?(Task.await_many(replay_tasks), &(&1 == {:ok, :replay}))
      assert {:prodded, 1} = Task.await(successor_task)
      assert :already_terminal = Ledger.finish(ctx.db, queued_turn, "delivered")

      assert {:ok, [["canceled"]]} =
               DB.query(ctx.db, "SELECT status FROM turns WHERE seq=?1", [queued_turn])

      assert %{prodCount: 1} = Supervision.prod_state(ctx.db, successor_id)

      assert {:ok, [[2, "armed"]]} =
               DB.query(
                 ctx.db,
                 "SELECT generation,state FROM supervision_entitlements WHERE assignmentId=?1",
                 [successor_id]
               )

      assert [successor_wake] =
               Wakes.list_pending(ctx.db)
               |> Enum.filter(&(&1.assignment_id == successor_id))

      assert {:ok, [[1]]} =
               DB.query(
                 ctx.db,
                 "SELECT COUNT(*) FROM patrol_output_sources WHERE wakeId=?1 AND assignmentId=?2",
                 [successor_wake.wake_id, successor_id]
               )

      assert {:ok, [[0]]} =
               DB.query(
                 ctx.db,
                 "SELECT COUNT(*) FROM wake_cancellations WHERE wakeId=?1",
                 [successor_wake.wake_id]
               )

      assert {:ok, [[0]]} =
               DB.query(
                 ctx.db,
                 "SELECT COUNT(*) FROM patrol_output_sources WHERE wakeId=?1 AND assignmentId=?2",
                 [successor_wake.wake_id, predecessor_id]
               )
    end
  end

  test "F14 typed lifecycle races expose only admission-before or lifecycle-before", ctx do
    transitions = [:completion, :surrender, :revoke, :retirement]

    for transition <- transitions do
      suffix = Atom.to_string(transition)
      assignment_id = "asg_f14_delivery_#{suffix}"
      holder = "holder_f14_delivery_#{suffix}"
      session(ctx.db, holder, "supervisor")
      assignment(ctx.db, assignment_id, holder, "delivery race", 60)
      wake = prepare_pending_patrol_wake!(ctx, assignment_id, holder)

      delivery =
        Task.async(fn ->
          DB.transaction(ctx.db, fn txn ->
            Gateway.deliver_prompt_in_txn(
              txn,
              holder,
              wake.origin,
              wake.prompt,
              wake_id: wake.wake_id,
              sender: wake.origin,
              target_gate: wake,
              fire_wake_in_txn: true,
              assignment_id: assignment_id
            )
          end)
        end)

      lifecycle =
        Task.async(fn -> run_lifecycle!(ctx.db, assignment_id, holder, transition) end)

      Task.await(delivery)
      Task.await(lifecycle)

      assert %{state: wake_state} = Wakes.get(ctx.db, wake.wake_id)
      assert wake_state in ["fired", "canceled"]

      assert {:ok, turns} =
               DB.query(ctx.db, "SELECT status FROM turns WHERE wakeId=?1", [wake.wake_id])

      assert turns in [[], [["canceled"]]]

      assert {:ok, [[1]]} =
               DB.query(
                 ctx.db,
                 "SELECT COUNT(*) FROM patrol_output_sources WHERE wakeId=?1",
                 [wake.wake_id]
               )
    end

    for transition <- transitions do
      suffix = Atom.to_string(transition)
      assignment_id = "asg_f14_turn_#{suffix}"
      holder = "holder_f14_turn_#{suffix}"
      session(ctx.db, holder, "supervisor")
      assignment(ctx.db, assignment_id, holder, "turn race", 70)

      %{turn_seq: turn_seq, wake_id: wake_id} =
        prepare_queued_patrol_turn!(ctx, assignment_id, holder)

      claim = Task.async(fn -> Ledger.claim_next(ctx.db, holder, "f14-race") end)

      lifecycle =
        Task.async(fn -> run_lifecycle!(ctx.db, assignment_id, holder, transition) end)

      claim_result = Task.await(claim)
      Task.await(lifecycle)

      case claim_result do
        {:ok, %{seq: ^turn_seq}} -> assert :ok = Ledger.finish(ctx.db, turn_seq, "delivered")
        :none -> :ok
      end

      assert {:ok, [[status]]} =
               DB.query(ctx.db, "SELECT status FROM turns WHERE seq=?1", [turn_seq])

      assert status in ["canceled", "delivered"]
      assert_no_patrol_acknowledgment!(ctx.db, wake_id, turn_seq)
    end

    for transition <- transitions do
      suffix = Atom.to_string(transition)
      assignment_id = "asg_f14_retry_#{suffix}"
      holder = "holder_f14_retry_#{suffix}"
      session(ctx.db, holder, "supervisor")
      assignment(ctx.db, assignment_id, holder, "retry race", 80)
      root = prepare_effort_root!(ctx.db, assignment_id, holder)

      retry =
        Task.async(fn ->
          create_racing_retry(ctx.db, root, assignment_id, holder, "retry #{suffix}")
        end)

      lifecycle =
        Task.async(fn -> run_lifecycle!(ctx.db, assignment_id, holder, transition) end)

      retry_result = Task.await(retry)
      Task.await(lifecycle)

      assert retry_result in [:created, :lifecycle_won]

      assert {:ok, sources} =
               DB.query(
                 ctx.db,
                 "SELECT retryOrdinal,w.state FROM patrol_output_sources p JOIN wakes w ON w.wakeId=p.wakeId WHERE p.rootWakeId=?1 ORDER BY retryOrdinal",
                 [root.wake_id]
               )

      assert sources in [[[0, "canceled"]], [[0, "canceled"], [1, "canceled"]]]
    end

    assignment_id = "asg_f14_retry_duel"
    holder = "holder_f14_retry_duel"
    session(ctx.db, holder, "supervisor")
    assignment(ctx.db, assignment_id, holder, "retry duel", 90)
    root = prepare_effort_root!(ctx.db, assignment_id, holder)

    retry_tasks =
      for label <- ["a", "b"] do
        Task.async(fn -> create_racing_retry(ctx.db, root, assignment_id, holder, label) end)
      end

    assert Enum.sort(Task.await_many(retry_tasks)) == [:created, :lifecycle_won]

    assert {:ok, [[0, nil], [1, root_wake_id]]} =
             DB.query(
               ctx.db,
               "SELECT retryOrdinal,predecessorWakeId FROM patrol_output_sources WHERE rootWakeId=?1 ORDER BY retryOrdinal",
               [root.wake_id]
             )

    assert root_wake_id == root.wake_id
  end

  test "F15 lifecycle crash boundaries roll back fully and replay one stopped result", ctx do
    assignment_id = "asg_f15"
    holder = "holder_f15"
    session(ctx.db, holder, "supervisor")
    assignment(ctx.db, assignment_id, holder, "crash boundaries", 100)

    assert {:error, %RuntimeError{message: "f15 schedule crash"}} =
             DB.transaction(ctx.db, fn txn ->
               wake =
                 Wakes.schedule_in_txn(txn, %{
                   session_key: holder,
                   origin: "process:tightbeam",
                   prompt: "f15 root",
                   due_at: 0,
                   assignment_id: assignment_id
                 })

               insert_effort_generation_in_txn!(txn, assignment_id, holder, 1, wake.wake_id)

               assert {:ok, _source} =
                        PatrolResponse.create_effort_source_in_txn(
                          txn,
                          wake.wake_id,
                          "effort_generation_prod",
                          assignment_id,
                          1
                        )

               raise "f15 schedule crash"
             end)

    assert {:ok, [[0, 0, 0]]} =
             DB.query(
               ctx.db,
               "SELECT (SELECT COUNT(*) FROM wakes WHERE assignmentId=?1),(SELECT COUNT(*) FROM effort_checkin_generations WHERE assignmentId=?1),(SELECT COUNT(*) FROM patrol_output_sources WHERE assignmentId=?1)",
               [assignment_id]
             )

    assert {:ok, %{wake: root}} =
             DB.transaction(ctx.db, fn txn ->
               wake =
                 Wakes.schedule_in_txn(txn, %{
                   session_key: holder,
                   origin: "process:tightbeam",
                   prompt: "f15 root",
                   due_at: 0,
                   assignment_id: assignment_id
                 })

               insert_effort_generation_in_txn!(txn, assignment_id, holder, 1, wake.wake_id)

               assert {:ok, _source} =
                        PatrolResponse.create_effort_source_in_txn(
                          txn,
                          wake.wake_id,
                          "effort_generation_prod",
                          assignment_id,
                          1
                        )

               %{wake: wake}
             end)

    assert {:error, %RuntimeError{message: "f15 delivery crash"}} =
             DB.transaction(ctx.db, fn txn ->
               assert {:appended, ^holder, _message, _opts} =
                        Gateway.deliver_prompt_in_txn(
                          txn,
                          holder,
                          root.origin,
                          root.prompt,
                          wake_id: root.wake_id,
                          sender: root.origin,
                          target_gate: root,
                          fire_wake_in_txn: true,
                          assignment_id: assignment_id
                        )

               raise "f15 delivery crash"
             end)

    assert %{state: "pending"} = Wakes.get(ctx.db, root.wake_id)

    assert {:ok, [[0]]} =
             DB.query(ctx.db, "SELECT COUNT(*) FROM turns WHERE wakeId=?1", [root.wake_id])

    assert {:ok, {:appended, ^holder, _message, _opts}} =
             DB.transaction(ctx.db, fn txn ->
               Gateway.deliver_prompt_in_txn(
                 txn,
                 holder,
                 root.origin,
                 root.prompt,
                 wake_id: root.wake_id,
                 sender: root.origin,
                 target_gate: root,
                 fire_wake_in_txn: true,
                 assignment_id: assignment_id
               )
             end)

    assert {:ok, [[queued_turn]]} =
             DB.query(ctx.db, "SELECT seq FROM turns WHERE wakeId=?1 AND status='queued'", [
               root.wake_id
             ])

    pending =
      Wakes.schedule(ctx.db, %{
        session_key: holder,
        origin: "process:tightbeam",
        prompt: "f15 pending",
        due_at: 0,
        assignment_id: assignment_id
      })

    assert {:ok, :ok} =
             DB.transaction(ctx.db, fn txn ->
               insert_effort_generation_in_txn!(txn, assignment_id, holder, 2, pending.wake_id)

               assert {:ok, _source} =
                        PatrolResponse.create_effort_source_in_txn(
                          txn,
                          pending.wake_id,
                          "effort_generation_prod",
                          assignment_id,
                          2
                        )

               :ok
             end)

    assert {:error, %RuntimeError{message: "f15 tombstone crash"}} =
             DB.transaction(ctx.db, fn txn ->
               [] =
                 DB.Txn.q(
                   txn,
                   "UPDATE assignments SET state='closed',outcome='revoked',closedAt=101,closedByUser='flynn' WHERE id=?1 AND state='open'",
                   [assignment_id]
                 )

               assert :ok =
                        PatrolResponse.tombstone_assignment_in_txn(
                          txn,
                          assignment_id,
                          "tightbeam:assignments",
                          101
                        )

               raise "f15 tombstone crash"
             end)

    assert %{state: "pending"} = Wakes.get(ctx.db, pending.wake_id)

    assert {:ok, [["queued"]]} =
             DB.query(ctx.db, "SELECT status FROM turns WHERE seq=?1", [queued_turn])

    assert {:ok, [[0]]} =
             DB.query(ctx.db, "SELECT COUNT(*) FROM wake_cancellations WHERE wakeId=?1", [
               pending.wake_id
             ])

    result = transition_assignment!(ctx.db, assignment_id, holder, :completion)
    assert result.state == "closed"
    assert %{state: "canceled"} = Wakes.get(ctx.db, pending.wake_id)

    assert {:ok, [["canceled"]]} =
             DB.query(ctx.db, "SELECT status FROM turns WHERE seq=?1", [queued_turn])

    assert queued_turn in (Ledger.unpublished_terminals(ctx.db) |> Enum.map(& &1.seq))

    assert {:ok, :replay} =
             DB.transaction(ctx.db, fn txn ->
               PatrolResponse.admit_delivery_in_txn(txn, pending.wake_id, holder)
             end)

    assert :already_terminal = Ledger.finish(ctx.db, queued_turn, "delivered")

    assert {:ok, [[1]]} =
             DB.query(ctx.db, "SELECT COUNT(*) FROM wake_cancellations WHERE wakeId=?1", [
               pending.wake_id
             ])

    assert Enum.count(
             EventLog.lifecycle_events(ctx.db),
             &(&1.kind == "patrol_turn_stopped" and &1.subject == to_string(queued_turn))
           ) == 1
  end

  test "destination retirement creates one coherent typed supervision retry", ctx do
    insert_entitlement!(ctx.db, "asg_1", generation: 1, due_at: 0)
    terminal_seq = terminal!(ctx.db, "holder")

    assert {:escalated, 1, "supervisor"} =
             Supervision.evaluate(ctx.db, ctx.handlers, 0, "holder", terminal_seq)

    assert [root] =
             Wakes.list_pending(ctx.db)
             |> Enum.filter(&(&1.assignment_id == "asg_1"))

    retire!(ctx.db, "supervisor")

    assert {:ok,
            [
              [root_wake_id, nil, 0, root_wake_id, "canceled"],
              [retry_wake_id, root_wake_id, 1, root_wake_id, "pending"]
            ]} =
             DB.query(
               ctx.db,
               """
               SELECT p.wakeId,p.predecessorWakeId,p.retryOrdinal,p.rootWakeId,w.state
               FROM patrol_output_sources p JOIN wakes w ON w.wakeId=p.wakeId
               WHERE p.rootWakeId=?1 ORDER BY p.retryOrdinal
               """,
               [root.wake_id]
             )

    assert retry_wake_id != root_wake_id

    assert {:ok, [["target_retired", "replacement", ^retry_wake_id]]} =
             DB.query(
               ctx.db,
               "SELECT reasonKind,outcomeKind,replacementWakeId FROM wake_cancellations WHERE wakeId=?1",
               [root_wake_id]
             )
  end

  test "holder retirement terminalizes an already queued typed patrol turn once", ctx do
    insert_entitlement!(ctx.db, "asg_1", generation: 1, due_at: 0)
    terminal_seq = terminal!(ctx.db, "holder")

    assert {:prodded, 1} =
             Supervision.evaluate(ctx.db, ctx.handlers, 3, "holder", terminal_seq)

    assert [wake] = Wakes.list_pending(ctx.db)
    assert :appended = admit_supervision_wake!(ctx.db, wake)

    assert {:ok, [[turn_seq, "queued"]]} =
             DB.query(ctx.db, "SELECT seq,status FROM turns WHERE wakeId=?1", [wake.wake_id])

    retire!(ctx.db, "holder")

    assert {:ok, [[^turn_seq, "canceled", ended_at]]} =
             DB.query(ctx.db, "SELECT seq,status,endedAt FROM turns WHERE wakeId=?1", [
               wake.wake_id
             ])

    assert is_integer(ended_at)

    assert Enum.count(
             EventLog.lifecycle_events(ctx.db),
             &(&1.kind == "patrol_turn_stopped" and &1.subject == to_string(turn_seq))
           ) == 1

    retire!(ctx.db, "holder")

    assert Enum.count(
             EventLog.lifecycle_events(ctx.db),
             &(&1.kind == "patrol_turn_stopped" and &1.subject == to_string(turn_seq))
           ) == 1
  end

  test "transient refusal preserves the outbox and a later edge drains without recounting", ctx do
    insert_entitlement!(ctx.db, "asg_1", generation: 1, due_at: 0)
    transient = Map.put(ctx.handlers, "wake", fn _ -> %{code: "server_error"} end)
    seq1 = terminal!(ctx.db, "holder")

    assert {:refused, "server_error"} =
             Supervision.evaluate(ctx.db, transient, 3, "holder", seq1)

    assert %{attemptCount: 1, prodCount: 0} = Supervision.prod_state(ctx.db, "asg_1")

    assert %{pendingBranch: "prod", pendingK: 1, pendingN: 3} =
             Supervision.watermark(ctx.db, "holder")

    seq2 = terminal!(ctx.db, "holder")
    assert :not_due = Supervision.evaluate(ctx.db, ctx.handlers, 3, "holder", seq2)
    assert %{attemptCount: 1, prodCount: 1} = Supervision.prod_state(ctx.db, "asg_1")

    assert %{lastEvaluatedTerminal: ^seq2, pendingBranch: nil} =
             Supervision.watermark(ctx.db, "holder")

    assert Enum.count(
             EventLog.lifecycle_events(ctx.db),
             &(&1.kind == "supervision_dispatch_failed")
           ) == 1
  end

  test "statute-tier denials clear atomically, count attempts only, and block at the threshold",
       ctx do
    insert_entitlement!(ctx.db, "asg_1", generation: 1, due_at: 0)
    denied = Map.put(ctx.handlers, "wake", fn _ -> %{code: "rule_denied"} end)
    seq1 = terminal!(ctx.db, "holder")
    seq2 = terminal!(ctx.db, "holder")

    assert {:refused, "rule_denied"} = Supervision.evaluate(ctx.db, denied, 2, "holder", seq1)

    {:ok, _} =
      DB.query(
        ctx.db,
        """
        UPDATE supervision_entitlements
        SET generation=2, dueAt=0, state='armed', lastAttemptGeneration=NULL,
            claimClock=NULL, cause='policy_denied', principal='process:tightbeam'
        WHERE assignmentId='asg_1' AND state='claimed'
        """
      )

    assert {:refused, "rule_denied"} = Supervision.evaluate(ctx.db, denied, 2, "holder", seq2)

    assert %{attemptCount: 2, prodCount: 0, deniedStreak: 2, lastProdAt: nil} =
             Supervision.prod_state(ctx.db, "asg_1")

    assert %{pendingBranch: nil, lastEvaluatedTerminal: ^seq2} =
             Supervision.watermark(ctx.db, "holder")

    lifecycle = EventLog.lifecycle_events(ctx.db)
    assert Enum.count(lifecycle, &(&1.kind == "supervision_prod_denied")) == 2
    assert Enum.count(lifecycle, &(&1.kind == "supervision_blocked")) == 1
    assert Wakes.list_pending(ctx.db) == []
  end

  test "a policy denial event, counter, branch settlement, and successor share one transaction",
       ctx do
    insert_entitlement!(ctx.db, "asg_1", generation: 3, due_at: 5_000, interval: 1_000)

    {:ok, _} =
      DB.query(
        ctx.db,
        """
        UPDATE supervision_entitlements
        SET state='claimed', claimClock=5000, lastAttemptGeneration=3, cause='deadline'
        WHERE assignmentId='asg_1'
        """
      )

    {:ok, _} =
      DB.query(
        ctx.db,
        """
        INSERT INTO assignment_prods
          (assignmentId, attemptCount, prodCount, deniedStreak)
        VALUES ('asg_1', 1, 0, 0)
        """
      )

    {:ok, _} =
      DB.query(
        ctx.db,
        """
        INSERT INTO supervision_watermarks
          (sessionKey, lastEvaluatedTerminal, pendingBranch, pendingAssignment,
           pendingK, pendingN)
        VALUES ('holder', 7, 'prod', 'asg_1', 1, 2)
        """
      )

    assert {:error, %RuntimeError{message: "forced policy rollback"}} =
             DB.transaction(ctx.db, fn txn ->
               Tightbeam.DB.Txn.q(
                 txn,
                 """
                 INSERT INTO events
                   (ts, kind, verb, origin, principal, sessionKey, payload)
                 VALUES (5000, 'denied', 'wake', 'process:tightbeam',
                         'process:tightbeam', 'holder', '{}')
                 """
               )

               [[event_id]] = Tightbeam.DB.Txn.q(txn, "SELECT last_insert_rowid()")

               assert {:armed, 4} =
                        Supervision.transition_in_txn(txn, %{
                          kind: "policy_denied",
                          assignment_id: "asg_1",
                          event_id: event_id,
                          evaluation_clock: 5_000
                        })

               raise "forced policy rollback"
             end)

    assert {:ok, [[3, "claimed", 5_000]]} =
             DB.query(
               ctx.db,
               "SELECT generation, state, claimClock FROM supervision_entitlements WHERE assignmentId='asg_1'"
             )

    assert {:ok, [[0]]} =
             DB.query(
               ctx.db,
               "SELECT deniedStreak FROM assignment_prods WHERE assignmentId='asg_1'"
             )

    assert {:ok, [["prod", "asg_1"]]} =
             DB.query(
               ctx.db,
               "SELECT pendingBranch, pendingAssignment FROM supervision_watermarks WHERE sessionKey='holder'"
             )

    assert {:ok, event_id} =
             DB.transaction(ctx.db, fn txn ->
               Tightbeam.DB.Txn.q(
                 txn,
                 """
                 INSERT INTO events
                   (ts, kind, verb, origin, principal, sessionKey, payload)
                 VALUES (5000, 'denied', 'wake', 'process:tightbeam',
                         'process:tightbeam', 'holder', '{}')
                 """
               )

               [[event_id]] = Tightbeam.DB.Txn.q(txn, "SELECT last_insert_rowid()")

               assert {:armed, 4} =
                        Supervision.transition_in_txn(txn, %{
                          kind: "policy_denied",
                          assignment_id: "asg_1",
                          event_id: event_id,
                          evaluation_clock: 5_000
                        })

               event_id
             end)

    assert {:ok,
            [[4, 6_000, "armed", "policy_denied", basis_id, "policy_denied", "process:tightbeam"]]} =
             DB.query(
               ctx.db,
               """
               SELECT generation, dueAt, state, basisKind, basisId, cause, principal
               FROM supervision_entitlements
               WHERE assignmentId='asg_1'
               """
             )

    assert basis_id == to_string(event_id)

    assert {:ok, [[1]]} =
             DB.query(
               ctx.db,
               "SELECT deniedStreak FROM assignment_prods WHERE assignmentId='asg_1'"
             )

    assert {:ok, [[nil, nil]]} =
             DB.query(
               ctx.db,
               "SELECT pendingBranch, pendingAssignment FROM supervision_watermarks WHERE sessionKey='holder'"
             )
  end

  test "F11 terminal assignment state precedes stale branch drain and dedupe", ctx do
    insert_entitlement!(ctx.db, "asg_1", generation: 1, due_at: 0)
    transient = Map.put(ctx.handlers, "wake", fn _ -> %{code: "server_error"} end)
    seq = terminal!(ctx.db, "holder")
    assert {:refused, "server_error"} = Supervision.evaluate(ctx.db, transient, 3, "holder", seq)

    {:ok, _} =
      DB.query(
        ctx.db,
        "UPDATE assignments SET state='closed', outcome='revoked', closedAt=2, closedByUser='flynn' WHERE id='asg_1'"
      )

    assert :idle = Supervision.evaluate(ctx.db, ctx.handlers, 3, "holder", seq)

    assert %{pendingBranch: nil, lastEvaluatedTerminal: ^seq} =
             Supervision.watermark(ctx.db, "holder")

    assert %{attemptCount: 1, prodCount: 0} = Supervision.prod_state(ctx.db, "asg_1")
    assert Wakes.list_pending(ctx.db) == []
  end

  test "Main self-target takes the no-wake terminus exactly once", ctx do
    assignment(ctx.db, "asg_main", ctx.main.session_key, "main work", 2)
    insert_entitlement!(ctx.db, "asg_main", generation: 1, due_at: 0)
    seq = terminal!(ctx.db, ctx.main.session_key)

    assert :terminus =
             Supervision.evaluate(ctx.db, ctx.handlers, 0, ctx.main.session_key, seq)

    assert :duplicate =
             Supervision.evaluate(ctx.db, ctx.handlers, 0, ctx.main.session_key, seq)

    assert %{attemptCount: 1, prodCount: 0, stalledAt: stalled} =
             Supervision.prod_state(ctx.db, "asg_main")

    assert is_integer(stalled)
    assert Wakes.list_pending(ctx.db) == []

    assert Enum.count(EventLog.lifecycle_events(ctx.db), &(&1.kind == "supervision_terminus")) ==
             1
  end

  test "an unrelated pending wake does not suppress or duplicate a prod", ctx do
    insert_entitlement!(ctx.db, "asg_1", generation: 1, due_at: 0)

    continuation =
      Wakes.schedule(ctx.db, %{
        session_key: "holder",
        target_role: nil,
        origin: "user:flynn",
        prompt: "later",
        due_at: System.system_time(:millisecond) + 60_000
      })

    seq = terminal!(ctx.db, "holder")
    assert {:prodded, 1} = Supervision.evaluate(ctx.db, ctx.handlers, 3, "holder", seq)
    assert :duplicate = Supervision.evaluate(ctx.db, ctx.handlers, 3, "holder", seq)
    assert Wakes.get(ctx.db, continuation.wake_id).state == "pending"
    assert %{prodCount: 1} = Supervision.prod_state(ctx.db, "asg_1")
  end

  test "total catch contains exits and records evaluation failure without losing the claim",
       ctx do
    insert_entitlement!(ctx.db, "asg_1", generation: 1, due_at: 0)
    exiting = Map.put(ctx.handlers, "wake", fn _ -> exit(:handler_exit) end)
    seq = terminal!(ctx.db, "holder")
    name = :"supervision_exit_#{System.unique_integer([:positive])}"

    pid =
      start_supervised!({Supervision, db: ctx.db, handlers: exiting, prod_limit: 3, name: name})

    Supervision.notify_terminal(name, "holder", seq)

    assert eventually(fn ->
             Enum.any?(
               EventLog.lifecycle_events(ctx.db),
               &(&1.kind == "supervision_evaluate_failed")
             )
           end),
           "the contained exit was never recorded as an evaluation failure"

    assert Process.alive?(pid)
    assert %{attemptCount: 1, prodCount: 0} = Supervision.prod_state(ctx.db, "asg_1")
    assert %{pendingBranch: "prod"} = Supervision.watermark(ctx.db, "holder")
  end

  test "retirement handling is total-caught before the server continues", ctx do
    name = :"supervision_retired_#{System.unique_integer([:positive])}"

    pid =
      start_supervised!(
        {Supervision, db: ctx.db, handlers: ctx.handlers, prod_limit: 3, name: name}
      )

    :ok = DB.execute(ctx.db, "DROP TABLE decision_requests")
    Supervision.notify_retired(name, "holder")

    assert eventually(fn ->
             Enum.any?(EventLog.lifecycle_events(ctx.db), fn event ->
               event.kind == "supervision_evaluate_failed" and event.subject == "holder"
             end)
           end),
           "the caught retirement failure was never recorded for holder"

    assert Process.alive?(pid)
    Supervision.request_sweep(name)

    # Same cast barrier: alive? proves nothing about a sweep still sitting in the
    # mailbox, and alive? was this test's only other assertion.
    :sys.get_state(name)
    assert Process.alive?(pid)
  end

  test "retiring a holder revokes its assignments without a stranded-work notice",
       ctx do
    name = start_retirement_supervision(ctx)

    retire!(ctx.db, "holder")
    Supervision.notify_retired(name, "holder")
    :sys.get_state(name)

    assert Projection.list_after(ctx.db, "supervisor", nil, 10) == []
    assert Ledger.pending_count(ctx.db, "supervisor") == 0
    assert Projection.list_after(ctx.db, ctx.main.session_key, nil, 10) == []

    Supervision.notify_retired(name, "holder")
    :sys.get_state(name)

    assert Projection.list_after(ctx.db, "supervisor", nil, 10) == []
    assert Ledger.pending_count(ctx.db, "supervisor") == 0
  end

  test "retirement revocation does not create a fallback stranded-work notice",
       ctx do
    name = start_retirement_supervision(ctx)

    retire!(ctx.db, "supervisor")
    retire!(ctx.db, "holder")
    Supervision.notify_retired(name, "holder")
    :sys.get_state(name)

    assert Projection.list_after(ctx.db, "supervisor", nil, 10) == []
    assert Projection.list_after(ctx.db, ctx.main.session_key, nil, 10) == []
    assert Ledger.pending_count(ctx.db, ctx.main.session_key) == 0
  end

  test "retiring a holder without open assignments delivers no strand notice", ctx do
    idle = session(ctx.db, "idle-holder", ctx.supervisor.session_key)
    name = start_retirement_supervision(ctx)

    retire!(ctx.db, idle.session_key)
    Supervision.notify_retired(name, idle.session_key)
    :sys.get_state(name)

    assert Projection.list_after(ctx.db, ctx.supervisor.session_key, nil, 10) == []
    assert Projection.list_after(ctx.db, ctx.main.session_key, nil, 10) == []
    assert Ledger.pending_count(ctx.db, ctx.supervisor.session_key) == 0
    assert Ledger.pending_count(ctx.db, ctx.main.session_key) == 0
  end

  test "N=0 cross-assignment re-entry exceeds N+1 and then quiesces at Main", ctx do
    {:ok, _} =
      DB.query(ctx.db, "UPDATE sessions SET spawnedBy='holder' WHERE sessionKey='supervisor'")

    assignment(ctx.db, "asg_2", "supervisor", "second", 2)
    insert_entitlement!(ctx.db, "asg_1", generation: 1, due_at: 0)
    insert_entitlement!(ctx.db, "asg_2", generation: 1, due_at: 0)

    h1 = terminal!(ctx.db, "holder")

    assert {:escalated, 1, "supervisor"} =
             Supervision.evaluate(ctx.db, ctx.handlers, 0, "holder", h1)

    fire_all_pending(ctx.db)
    s1 = terminal!(ctx.db, "supervisor")

    assert {:escalated, 1, "holder"} =
             Supervision.evaluate(ctx.db, ctx.handlers, 0, "supervisor", s1)

    fire_all_pending(ctx.db)
    insert_entitlement!(ctx.db, "asg_1", generation: 2, due_at: 0)
    h2 = terminal!(ctx.db, "holder")

    assert {:escalated, 2, main} =
             Supervision.evaluate(ctx.db, ctx.handlers, 0, "holder", h2)

    assert main == ctx.main.session_key
    assert Supervision.prod_state(ctx.db, "asg_1").prodCount == 2
    assert Supervision.prod_state(ctx.db, "asg_1").prodCount > 0 + 1

    fire_all_pending(ctx.db)
    main_terminal = terminal!(ctx.db, ctx.main.session_key)

    assert :idle =
             Supervision.evaluate(ctx.db, ctx.handlers, 0, ctx.main.session_key, main_terminal)

    assert Wakes.list_pending(ctx.db) == []
  end

  test "past-sink open assignment emits one escalation per external terminal and duplicate re-entry is inert",
       ctx do
    {:ok, _} = DB.query(ctx.db, "UPDATE sessions SET spawnedBy=NULL WHERE sessionKey='holder'")
    insert_entitlement!(ctx.db, "asg_1", generation: 1, due_at: 0)

    first = terminal!(ctx.db, "holder")

    assert {:escalated, 1, main} =
             Supervision.evaluate(ctx.db, ctx.handlers, 0, "holder", first)

    assert main == ctx.main.session_key
    assert :duplicate = Supervision.evaluate(ctx.db, ctx.handlers, 0, "holder", first)
    assert length(Wakes.list_pending(ctx.db)) == 1

    fire_all_pending(ctx.db)
    insert_entitlement!(ctx.db, "asg_1", generation: 2, due_at: 0)
    second = terminal!(ctx.db, "holder")

    assert {:escalated, 2, ^main} =
             Supervision.evaluate(ctx.db, ctx.handlers, 0, "holder", second)

    assert length(Wakes.list_pending(ctx.db)) == 1
  end

  test "atomic delivery concurrent-retirement race has only before-or-after outcomes", ctx do
    registry = start_supervised!({ConnRegistry, name: :race_conn_registry})
    lane = start_supervised!({LaneDoorbell, :race_lane_manager})

    for iteration <- 1..20 do
      target = "race_target_#{iteration}"
      session(ctx.db, target, ctx.main.session_key)

      {:ok, _} =
        DB.query(ctx.db, "UPDATE sessions SET spawnedBy=?1 WHERE sessionKey='holder'", [target])

      gate = %{reresolve: "lineage", reresolve_seed: "holder", reresolve_rung: 1}

      delivery =
        Task.async(fn ->
          Gateway.deliver_prompt(target, "process:tightbeam", "race",
            db: ctx.db,
            wake_id: "w_race_#{iteration}",
            sender: "process:tightbeam",
            target_gate: gate,
            conn_registry: registry,
            lane_manager: lane
          )
        end)

      retirement = Task.async(fn -> retire!(ctx.db, target) end)
      assert :appended = Task.await(delivery)
      Task.await(retirement)

      {:ok, rows} =
        DB.query(ctx.db, "SELECT sessionKey FROM turns WHERE wakeId=?1", ["w_race_#{iteration}"])

      assert [[recipient]] = rows
      assert recipient in [target, ctx.main.session_key]
      refute recipient == "holder"
    end
  end

  # spec production-machine-v1 §The prod production: work-blocked is not
  # suppression bolted onto the prodder — the production does not match, the
  # same absence-of-match as a session with no open assignment.
  test "F16.1 and F17 a standing block unmatches until authorized unblock", ctx do
    insert_entitlement!(ctx.db, "asg_1", generation: 1, due_at: 0)
    file_fact(ctx.db, "work-blocked", "holder")

    # The queue is never gated by the standing fact: the blocked holder's
    # turn is accepted, claimed, and finished as ever — a parent that orders
    # a retry must be able to land one.
    seq = terminal!(ctx.db, "holder")

    assert {:no_match, :work_blocked, %{id: "asg_1"}} =
             Supervision.prod_production_matches?(ctx.db, "holder", seq)

    assert :blocked = Supervision.evaluate(ctx.db, ctx.handlers, 3, "holder", seq)
    assert Wakes.list_pending(ctx.db) == []
    # Nothing was claimed and nothing watermarked: retraction re-matches this
    # very terminal from current state.
    assert Supervision.watermark(ctx.db, "holder") == nil

    file_fact(ctx.db, "work-unblocked", "holder")

    assert {:match, %{id: "asg_1"}} =
             Supervision.prod_production_matches?(ctx.db, "holder", seq)

    assert {:prodded, 1} = Supervision.evaluate(ctx.db, ctx.handlers, 3, "holder", seq)
  end

  # Recognition happens at act time or it is not recognition: the claim and
  # the dispatch are two phases, and a fact filed between them must still be
  # seen by the drain.
  test "F16.2 a branch claimed before block is discarded at drain without dispatch",
       ctx do
    insert_entitlement!(ctx.db, "asg_1", generation: 1, due_at: 0)
    transient = Map.put(ctx.handlers, "wake", fn _ -> %{code: "server_error"} end)
    seq = terminal!(ctx.db, "holder")
    assert {:refused, "server_error"} = Supervision.evaluate(ctx.db, transient, 3, "holder", seq)
    assert %{pendingBranch: "prod"} = Supervision.watermark(ctx.db, "holder")

    file_fact(ctx.db, "work-blocked", "holder")

    # The drain re-reads the standing fact and clears the branch without
    # dispatching. The claim already advanced the dedupe watermark, so this
    # terminal reads duplicate afterwards.
    assert :duplicate = Supervision.evaluate(ctx.db, ctx.handlers, 3, "holder", seq)
    assert %{pendingBranch: nil} = Supervision.watermark(ctx.db, "holder")
    assert Wakes.list_pending(ctx.db) == []
    assert %{prodCount: 0} = Supervision.prod_state(ctx.db, "asg_1")

    file_fact(ctx.db, "work-unblocked", "holder")
    seq2 = terminal!(ctx.db, "holder")
    assert {:prodded, 1} = Supervision.evaluate(ctx.db, ctx.handlers, 3, "holder", seq2)
  end

  # The prodder's TRUE act time is the wake FIRE (spec §The prod production;
  # the e2e that forced this fix watched a prod land after the block): a wake
  # scheduled by a pre-block drain is suppressed at delivery, consumed as
  # canceled with the reason named, never delivered.
  test "F16.3 a supervision wake scheduled before block is suppressed at fire", ctx do
    insert_entitlement!(ctx.db, "asg_1", generation: 1, due_at: 0)
    seq = terminal!(ctx.db, "holder")
    assert {:prodded, 1} = Supervision.evaluate(ctx.db, ctx.handlers, 3, "holder", seq)
    assert [%{wake_id: wake_id}] = Wakes.list_pending(ctx.db)

    file_fact(ctx.db, "work-blocked", "holder")

    parent = self()

    scheduler =
      start_supervised!(
        {Wakes,
         db: ctx.db,
         deliver: fn wake ->
           send(parent, {:delivered, wake.wake_id})
           true
         end,
         tick_ms: 60_000,
         name: :suppression_scheduler}
      )

    assert :ok = Wakes.fire_due(scheduler)
    refute_receive {:delivered, ^wake_id}, 200

    assert Wakes.get(ctx.db, wake_id).state == "canceled"

    assert Enum.any?(
             EventLog.lifecycle_events(ctx.db),
             &(&1.kind == "supervision_wake_suppressed" and &1.subject == wake_id)
           )

    # Block recognition does not mutate counters or rungs. The charged prod
    # remains durable while the exact wake is canceled without replacement.
    assert %{prodCount: 1} = Supervision.prod_state(ctx.db, "asg_1")

    # An agent's own wake to the SAME blocked session still delivers — the
    # fact suppresses supervision's mail, never anyone else's.
    agent_wake =
      Wakes.schedule(ctx.db, %{
        session_key: "holder",
        target_role: nil,
        origin: "session:supervisor",
        prompt: "a colleague checking in",
        due_at: 0
      })

    assert :ok = Wakes.fire_due(scheduler)
    assert_receive {:delivered, delivered_id}, 500
    assert delivered_id == agent_wake.wake_id
  end

  test "F16 queued supervision answers and effort prods stop once across five block replays",
       ctx do
    assignment(ctx.db, "asg_f16_supervision", "holder", "queued supervision", 110)

    %{turn_seq: supervision_turn} =
      prepare_queued_patrol_turn!(ctx, "asg_f16_supervision", "holder")

    session(ctx.db, "holder_f16_effort", "supervisor")
    assignment(ctx.db, "asg_f16_effort", "holder_f16_effort", "queued effort", 111)
    effort_wake = prepare_effort_root!(ctx.db, "asg_f16_effort", "holder_f16_effort")

    assert {:ok, {:appended, "holder_f16_effort", _message, _opts}} =
             DB.transaction(ctx.db, fn txn ->
               Gateway.deliver_prompt_in_txn(
                 txn,
                 "holder_f16_effort",
                 effort_wake.origin,
                 effort_wake.prompt,
                 wake_id: effort_wake.wake_id,
                 sender: effort_wake.origin,
                 target_gate: effort_wake,
                 fire_wake_in_txn: true,
                 assignment_id: "asg_f16_effort"
               )
             end)

    assert {:ok, [[effort_turn]]} =
             DB.query(ctx.db, "SELECT seq FROM turns WHERE wakeId=?1 AND status='queued'", [
               effort_wake.wake_id
             ])

    assert %{prodCount: 1} = Supervision.prod_state(ctx.db, "asg_f16_supervision")
    file_fact(ctx.db, "work-blocked", "holder")
    file_fact(ctx.db, "work-blocked", "holder_f16_effort")

    for _replay <- 1..5 do
      assert :none = Ledger.claim_next(ctx.db, "holder", "f16-supervision")
      assert :none = Ledger.claim_next(ctx.db, "holder_f16_effort", "f16-effort")
    end

    assert {:ok, [["canceled"], ["canceled"]]} =
             DB.query(
               ctx.db,
               "SELECT status FROM turns WHERE seq IN (?1,?2) ORDER BY seq",
               [supervision_turn, effort_turn]
             )

    assert Enum.count(
             EventLog.lifecycle_events(ctx.db),
             &(&1.kind == "patrol_turn_stopped" and
                 &1.subject in [to_string(supervision_turn), to_string(effort_turn)])
           ) == 2

    assert %{prodCount: 1} = Supervision.prod_state(ctx.db, "asg_f16_supervision")

    assert {:ok, [[1], [1]]} =
             DB.query(
               ctx.db,
               "SELECT COUNT(*) FROM condition_facts WHERE kind='work-blocked' AND scope IN ('holder','holder_f16_effort') GROUP BY scope ORDER BY scope"
             )

    refute Enum.any?(EventLog.lifecycle_events(ctx.db), fn event ->
             event.kind in ["supervision_prod_denied", "supervision_blocked"] and
               event.subject in ["asg_f16_supervision", "asg_f16_effort"]
           end)
  end

  test "F17 unblock starts from current state and ordinary user traffic is never suppressed",
       ctx do
    insert_entitlement!(ctx.db, "asg_1", generation: 1, due_at: 0)
    file_fact(ctx.db, "work-blocked", "holder")

    user_wake =
      Wakes.schedule(ctx.db, %{
        session_key: "holder",
        origin: "user:flynn",
        prompt: "ordinary user traffic",
        due_at: 0
      })

    assert {:ok, {:appended, "holder", _message, _opts}} =
             DB.transaction(ctx.db, fn txn ->
               Gateway.deliver_prompt_in_txn(
                 txn,
                 "holder",
                 user_wake.origin,
                 user_wake.prompt,
                 wake_id: user_wake.wake_id,
                 sender: user_wake.origin,
                 target_gate: user_wake,
                 fire_wake_in_txn: true
               )
             end)

    assert {:ok, [[user_turn, "queued"]]} =
             DB.query(ctx.db, "SELECT seq,status FROM turns WHERE wakeId=?1", [user_wake.wake_id])

    assert {:ok, %{seq: ^user_turn}} = Ledger.claim_next(ctx.db, "holder", "f17-user")
    assert :ok = Ledger.finish(ctx.db, user_turn, "delivered")

    assert :blocked = Supervision.evaluate(ctx.db, ctx.handlers, 3, "holder", user_turn)
    assert Wakes.list_pending(ctx.db) == []

    file_fact(ctx.db, "work-unblocked", "holder")
    next_terminal = terminal!(ctx.db, "holder")
    assert {:prodded, 1} = Supervision.evaluate(ctx.db, ctx.handlers, 3, "holder", next_terminal)

    assert [fresh] = Wakes.list_pending(ctx.db)
    refute fresh.wake_id == user_wake.wake_id
    assert %{prodCount: 1} = Supervision.prod_state(ctx.db, "asg_1")
  end

  test "F17 a block on another holder leaves this assignment ordinary", ctx do
    insert_entitlement!(ctx.db, "asg_1", generation: 1, due_at: 0)
    file_fact(ctx.db, "work-blocked", "supervisor")
    seq = terminal!(ctx.db, "holder")
    assert {:prodded, 1} = Supervision.evaluate(ctx.db, ctx.handlers, 3, "holder", seq)
  end

  defp cancel_wake!(db, wake) do
    {requester, principal, session_key} = cancellation_requester(wake.origin)

    assert {:ok, {:accepted_in_txn, event_id, %{canceled: true}}} =
             DB.transaction(db, fn txn ->
               trigger = ensure_cancellation_trigger_in_txn(txn, wake)

               outcome =
                 case trigger do
                   {:ok, liveness_trigger} ->
                     %{kind: "no_replacement", liveness_trigger: liveness_trigger}

                   :none ->
                     %{kind: "no_replacement"}
                 end

               Wakes.cancel_in_txn(txn, %{
                 wake_id: wake.wake_id,
                 expected_origin: wake.origin,
                 requester: requester,
                 reason_kind: "requester_withdrew",
                 causal_source: %{
                   kind: "verb_call",
                   accepted_event: %{
                     origin: wake.origin,
                     session_key: session_key,
                     principal: principal
                   }
                 },
                 outcome: outcome
               })
             end)

    assert event_id > 0

    :ok
  end

  defp ensure_cancellation_trigger_in_txn(txn, %{assignment_id: assignment_id})
       when is_binary(assignment_id) do
    case DB.Txn.q(
           txn,
           """
           SELECT a.state, a.openedAt, e.assignmentId
           FROM assignments a
           LEFT JOIN supervision_entitlements e ON e.assignmentId=a.id
           WHERE a.id=?1
           """,
           [assignment_id]
         ) do
      [["open", opened_at, nil]] ->
        Supervision.transition_in_txn(txn, %{
          kind: "assignment_open",
          assignment_id: assignment_id,
          opened_at: opened_at,
          supervision_interval_ms: 60_000,
          principal: "process:tightbeam"
        })

      _ ->
        :ok
    end

    Supervision.liveness_trigger_in_txn(txn, {:assignment, assignment_id})
  end

  defp ensure_cancellation_trigger_in_txn(txn, %{work_item_id: work_item_id})
       when is_binary(work_item_id) do
    Supervision.liveness_trigger_in_txn(txn, {:work_item, work_item_id})
  end

  defp ensure_cancellation_trigger_in_txn(_txn, _wake), do: :none

  defp cancellation_requester("user:" <> id), do: {%{kind: "user", id: id}, {:user, id}, nil}

  defp cancellation_requester("session:" <> id),
    do: {%{kind: "session", id: id}, {:session, id}, id}

  defp cancellation_requester("process:" <> id),
    do: {%{kind: "process", id: id}, {:process, id}, nil}

  defp start_liveness!(ctx, opts) do
    name = Keyword.get(opts, :name, :immutable_liveness_supervision)

    start_supervised!(
      {Supervision,
       db: ctx.db,
       handlers: ctx.handlers,
       prod_limit: Keyword.get(opts, :prod_limit, 2),
       sweep_ms: Keyword.fetch!(opts, :sweep_ms),
       name: name}
    )

    :sys.get_state(name)
    name
  end

  defp sweep_liveness!(name) do
    Supervision.request_sweep(name)
    :sys.get_state(name)
    :ok
  end

  # What the real turn-end path does to a supervision wake once its turn has
  # been resolved: the wake is no longer pending and its sidecar controller is
  # settled. Without this, the pending sidecar row gates the next evaluation
  # as :controlled.
  defp settle_supervision_wake!(db, wake_id) do
    {:ok, _} =
      DB.query(db, "UPDATE wakes SET state='fired', firedAt=1 WHERE wakeId=?1", [wake_id])

    {:ok, _} =
      DB.query(
        db,
        "UPDATE supervision_liveness_sidecar SET controllerState='settled' WHERE wakeId=?1",
        [wake_id]
      )
  end

  defp insert_entitlement!(db, assignment_id, opts) do
    generation = Keyword.fetch!(opts, :generation)
    due_at = Keyword.fetch!(opts, :due_at)
    interval = Keyword.get(opts, :interval, 60_000)
    basis_kind = Keyword.get(opts, :basis_kind, "assignment_open")
    basis_id = Keyword.get(opts, :basis_id, assignment_id)
    cause = Keyword.get(opts, :cause, "assignment_open")

    {:ok, _} =
      DB.query(
        db,
        """
        INSERT INTO supervision_entitlements
          (assignmentId, generation, dueAt, state, lastAttemptGeneration, claimClock,
           basisKind, basisId, terminusAt, cause, principal, supervisionIntervalMs)
        VALUES (?1, ?2, ?3, 'armed', NULL, NULL, ?4, ?5, NULL, ?6,
                'process:tightbeam', ?7)
        """,
        [assignment_id, generation, due_at, basis_kind, basis_id, cause, interval]
      )

    {:ok, _} =
      DB.query(
        db,
        """
        INSERT OR IGNORE INTO supervision_liveness_receipt_state
          (assignmentId, artifactCursor, attestCursor, workItemEventCursor, wakeCursor,
           baselineCause, baselinePrincipal)
        VALUES (?1,
                (SELECT COALESCE(MAX(rowid), 0) FROM artifacts),
                (SELECT COALESCE(MAX(rowid), 0) FROM attests),
                (SELECT COALESCE(MAX(id), 0) FROM work_item_events),
                (SELECT COALESCE(MAX(rowid), 0) FROM wakes),
                'assignment_open', 'process:tightbeam')
        """,
        [assignment_id]
      )

    :ok
  end

  defp prepare_patrol_answer!(ctx, assignment_id, holder) do
    insert_entitlement!(ctx.db, assignment_id, generation: 1, due_at: 0)
    source_terminal = terminal!(ctx.db, holder)
    assert {:prodded, 1} = Supervision.evaluate(ctx.db, ctx.handlers, 3, holder, source_terminal)

    wake =
      ctx.db
      |> Wakes.list_pending()
      |> Enum.find(&(&1.assignment_id == assignment_id))

    assert wake
    assert :appended = admit_supervision_wake!(ctx.db, wake)
    assert {:ok, %{seq: turn_seq, wake_id: wake_id}} = Ledger.claim_next(ctx.db, holder, "f4")
    assert wake_id == wake.wake_id

    %{source_terminal: source_terminal, turn_seq: turn_seq, wake_id: wake_id}
  end

  defp prepare_pending_patrol_wake!(ctx, assignment_id, holder) do
    insert_entitlement!(ctx.db, assignment_id, generation: 1, due_at: 0)
    source_terminal = terminal!(ctx.db, holder)
    assert {:prodded, 1} = Supervision.evaluate(ctx.db, ctx.handlers, 3, holder, source_terminal)

    wake =
      ctx.db
      |> Wakes.list_pending()
      |> Enum.find(&(&1.assignment_id == assignment_id))

    assert wake
    wake
  end

  defp seed_heard_prod!(ctx, assignment_id, holder) do
    wake =
      Wakes.schedule(ctx.db, %{
        session_key: holder,
        origin: "process:tightbeam",
        prompt: "heard prod given",
        due_at: 0,
        assignment_id: assignment_id
      })

    assert {:ok, []} =
             DB.query(
               ctx.db,
               "INSERT INTO supervision_liveness_sidecar (wakeId,assignmentId,controllerOrigin,wakeKind,controllerState,chargedGeneration) VALUES (?1,?2,'scheduled','prod','pending',1)",
               [wake.wake_id, assignment_id]
             )

    assert {:ok, {:appended, ^holder, _message, _opts}} =
             DB.transaction(ctx.db, fn txn ->
               Gateway.deliver_prompt_in_txn(
                 txn,
                 holder,
                 wake.origin,
                 wake.prompt,
                 wake_id: wake.wake_id,
                 sender: wake.origin,
                 target_gate: wake,
                 fire_wake_in_txn: true,
                 assignment_id: assignment_id
               )
             end)

    assert {:ok, %{seq: turn_seq}} = Ledger.claim_next(ctx.db, holder, "f6-heard")
    assert :ok = Ledger.finish(ctx.db, turn_seq, "delivered")
    :ok
  end

  defp prepare_queued_patrol_turn!(ctx, assignment_id, holder) do
    wake = prepare_pending_patrol_wake!(ctx, assignment_id, holder)
    assert :appended = admit_supervision_wake!(ctx.db, wake)

    assert {:ok, [[turn_seq]]} =
             DB.query(ctx.db, "SELECT seq FROM turns WHERE wakeId=?1 AND status='queued'", [
               wake.wake_id
             ])

    %{turn_seq: turn_seq, wake_id: wake.wake_id}
  end

  defp prepare_lifecycle_candidates!(ctx, assignment_id, holder) do
    insert_entitlement!(ctx.db, assignment_id, generation: 1, due_at: 0)
    source_terminal = terminal!(ctx.db, holder)
    assert {:prodded, 1} = Supervision.evaluate(ctx.db, ctx.handlers, 3, holder, source_terminal)

    supervision_wake =
      ctx.db
      |> Wakes.list_pending()
      |> Enum.find(&(&1.assignment_id == assignment_id))

    assert supervision_wake
    assert :appended = admit_supervision_wake!(ctx.db, supervision_wake)

    assert {:ok, [[queued_turn]]} =
             DB.query(ctx.db, "SELECT seq FROM turns WHERE wakeId=?1 AND status='queued'", [
               supervision_wake.wake_id
             ])

    pending_wake =
      Wakes.schedule(ctx.db, %{
        session_key: holder,
        origin: "process:tightbeam",
        prompt: "pending effort output",
        due_at: 0,
        assignment_id: assignment_id
      })

    assert {:ok, []} =
             DB.query(
               ctx.db,
               """
               INSERT INTO effort_checkin_generations
                 (assignmentId,generation,state,baseHorizonMs,multiplier,armedAt,
                  terminalSeqWatermark,holderKey,host,root,baseline,wakeId,evidence,
                  agentProdded,artifactWatermark,attestWatermark,workItemWatermark)
               VALUES (?1,1,'probed',1000,1,1,0,?2,'eezo','.',
                       '{"status":"unavailable","reason":"fixture"}',?3,NULL,0,0,0,0)
               """,
               [assignment_id, holder, supervision_wake.wake_id]
             )

    assert {:ok, {:ok, %{wake_id: pending_wake_id}}} =
             DB.transaction(ctx.db, fn txn ->
               PatrolResponse.create_effort_source_in_txn(
                 txn,
                 pending_wake.wake_id,
                 "effort_generation_prod",
                 assignment_id,
                 1
               )
             end)

    assert pending_wake_id == pending_wake.wake_id
    %{pending_wake: pending_wake, queued_turn: queued_turn}
  end

  defp prepare_predecessor_chain!(ctx, assignment_id, holder) do
    root =
      Wakes.schedule(ctx.db, %{
        session_key: holder,
        origin: "process:tightbeam",
        prompt: "predecessor root",
        due_at: 0,
        assignment_id: assignment_id
      })

    assert {:ok, []} =
             DB.query(
               ctx.db,
               """
               INSERT INTO effort_checkin_generations
                 (assignmentId,generation,state,baseHorizonMs,multiplier,armedAt,
                  terminalSeqWatermark,holderKey,host,root,baseline,wakeId,evidence,
                  agentProdded,artifactWatermark,attestWatermark,workItemWatermark)
               VALUES (?1,1,'probed',1000,1,1,0,?2,'eezo','.',
                       '{"status":"unavailable","reason":"fixture"}',?3,NULL,0,0,0,0)
               """,
               [assignment_id, holder, root.wake_id]
             )

    assert {:ok, {:ok, %{wake_id: root_wake_id}}} =
             DB.transaction(ctx.db, fn txn ->
               PatrolResponse.create_effort_source_in_txn(
                 txn,
                 root.wake_id,
                 "effort_generation_prod",
                 assignment_id,
                 1
               )
             end)

    assert root_wake_id == root.wake_id
    retry_one = attach_predecessor_retry!(ctx.db, root, assignment_id, holder, 1)
    retry_two = attach_predecessor_retry!(ctx.db, retry_one, assignment_id, holder, 2)

    assert {:ok, {:appended, ^holder, _message, _opts}} =
             DB.transaction(ctx.db, fn txn ->
               Gateway.deliver_prompt_in_txn(
                 txn,
                 holder,
                 retry_two.origin,
                 retry_two.prompt,
                 wake_id: retry_two.wake_id,
                 sender: retry_two.origin,
                 target_gate: retry_two,
                 fire_wake_in_txn: true,
                 assignment_id: assignment_id
               )
             end)

    assert {:ok, [[queued_turn]]} =
             DB.query(ctx.db, "SELECT seq FROM turns WHERE wakeId=?1 AND status='queued'", [
               retry_two.wake_id
             ])

    %{chain: [root, retry_one, retry_two], queued_turn: queued_turn}
  end

  defp attach_predecessor_retry!(db, predecessor, assignment_id, holder, ordinal) do
    replacement =
      Wakes.schedule(db, %{
        session_key: holder,
        origin: "process:tightbeam",
        prompt: "predecessor retry #{ordinal}",
        due_at: 0,
        assignment_id: assignment_id
      })

    assert {:ok, {:ok, %{retry_ordinal: ^ordinal}}} =
             DB.transaction(db, fn txn ->
               with {:ok, source} <-
                      PatrolResponse.attach_destination_retry_in_txn(
                        txn,
                        predecessor.wake_id,
                        replacement.wake_id
                      ),
                    true <-
                      Wakes.cancel_in_txn(txn, %{
                        wake_id: predecessor.wake_id,
                        requester: %{kind: "process", id: "tightbeam:effort-checkin"},
                        reason_kind: "superseded",
                        causal_source: %{kind: "wake", id: replacement.wake_id},
                        outcome: %{
                          kind: "replacement",
                          replacement_wake_id: replacement.wake_id
                        }
                      }) do
                 {:ok, source}
               end
             end)

    replacement
  end

  defp prepare_effort_root!(db, assignment_id, holder) do
    root =
      Wakes.schedule(db, %{
        session_key: holder,
        origin: "process:tightbeam",
        prompt: "effort root",
        due_at: 0,
        assignment_id: assignment_id
      })

    assert {:ok, []} =
             DB.query(
               db,
               """
               INSERT INTO effort_checkin_generations
                 (assignmentId,generation,state,baseHorizonMs,multiplier,armedAt,
                  terminalSeqWatermark,holderKey,host,root,baseline,wakeId,evidence,
                  agentProdded,artifactWatermark,attestWatermark,workItemWatermark)
               VALUES (?1,1,'probed',1000,1,1,0,?2,'eezo','.',
                       '{"status":"unavailable","reason":"fixture"}',?3,NULL,0,0,0,0)
               """,
               [assignment_id, holder, root.wake_id]
             )

    assert {:ok, {:ok, %{wake_id: root_wake_id}}} =
             DB.transaction(db, fn txn ->
               PatrolResponse.create_effort_source_in_txn(
                 txn,
                 root.wake_id,
                 "effort_generation_prod",
                 assignment_id,
                 1
               )
             end)

    assert root_wake_id == root.wake_id
    root
  end

  defp assert_retry_dimension_rejected!(ctx, dimension) do
    suffix = Atom.to_string(dimension)
    assignment_id = "asg_f18_#{suffix}"
    other_assignment_id = "asg_f18_other_#{suffix}"
    assignment(ctx.db, assignment_id, "holder", suffix, 120)
    assignment(ctx.db, other_assignment_id, "holder", "other #{suffix}", 121)
    insert_entitlement!(ctx.db, assignment_id, generation: 1, due_at: 60_000)

    root =
      Wakes.schedule(ctx.db, %{
        session_key: "holder",
        origin: "process:tightbeam",
        prompt: "f18 root #{suffix}",
        due_at: 0,
        assignment_id: assignment_id
      })

    tail =
      Wakes.schedule(ctx.db, %{
        session_key: "holder",
        origin: "process:tightbeam",
        prompt: "f18 tail #{suffix}",
        due_at: 0,
        assignment_id: assignment_id
      })

    extra =
      Wakes.schedule(ctx.db, %{
        session_key: "holder",
        origin: "process:tightbeam",
        prompt: "f18 extra #{suffix}",
        due_at: 0,
        assignment_id: assignment_id
      })

    assert {:ok, []} =
             DB.query(
               ctx.db,
               """
               INSERT INTO effort_checkin_generations
                 (assignmentId,generation,state,baseHorizonMs,multiplier,armedAt,
                  terminalSeqWatermark,holderKey,host,root,baseline,wakeId,evidence,
                  agentProdded,artifactWatermark,attestWatermark,workItemWatermark)
               VALUES (?1,1,'probed',1000,1,1,0,'holder','eezo','.',
                       '{"status":"unavailable","reason":"fixture"}',?2,NULL,0,0,0,0)
               """,
               [assignment_id, tail.wake_id]
             )

    root_source = %{
      assignment: assignment_id,
      holder: "holder",
      kind: "effort_generation_prod",
      ref: assignment_id,
      version: 1,
      root: root.wake_id,
      predecessor: nil,
      ordinal: 0
    }

    tail_source = %{
      assignment: assignment_id,
      holder: "holder",
      kind: "effort_generation_prod",
      ref: assignment_id,
      version: 1,
      root: root.wake_id,
      predecessor: root.wake_id,
      ordinal: 1
    }

    {root_source, tail_source} =
      case dimension do
        :assignment -> {Map.put(root_source, :assignment, other_assignment_id), tail_source}
        :holder -> {Map.put(root_source, :holder, "supervisor"), tail_source}
        :source_kind -> {Map.put(root_source, :kind, "effort_generation_probe"), tail_source}
        :source_ref -> {Map.put(root_source, :ref, other_assignment_id), tail_source}
        :source_version -> {Map.put(root_source, :version, 9), tail_source}
        :root_wake -> {root_source, Map.put(tail_source, :root, extra.wake_id)}
        :predecessor_wake -> {root_source, Map.put(tail_source, :predecessor, extra.wake_id)}
        :retry_ordinal -> {root_source, Map.put(tail_source, :ordinal, 2)}
      end

    # F18 alone may bypass the constructor for one schema-valid semantic
    # mismatch. Every row above changes exactly the named dimension.
    assert {:ok, []} =
             DB.query(
               ctx.db,
               """
               INSERT INTO patrol_output_sources
                 (wakeId,assignmentId,holderKey,sourceKind,sourceRef,sourceVersion,
                  rootWakeId,predecessorWakeId,retryOrdinal,createdAt,
                  sourceCause,sourcePrincipal)
               VALUES
                 (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,
                  'patrol_output_scheduled','process:tightbeam'),
                 (?11,?12,?13,?14,?15,?16,?17,?18,?19,?20,
                  'patrol_output_scheduled','process:tightbeam')
               """,
               [
                 root.wake_id,
                 root_source.assignment,
                 root_source.holder,
                 root_source.kind,
                 root_source.ref,
                 root_source.version,
                 root_source.root,
                 root_source.predecessor,
                 root_source.ordinal,
                 root.created_at,
                 tail.wake_id,
                 tail_source.assignment,
                 tail_source.holder,
                 tail_source.kind,
                 tail_source.ref,
                 tail_source.version,
                 tail_source.root,
                 tail_source.predecessor,
                 tail_source.ordinal,
                 tail.created_at
               ]
             )

    assert {:ok, true} =
             DB.transaction(ctx.db, fn txn ->
               Wakes.cancel_in_txn(txn, %{
                 wake_id: root.wake_id,
                 requester: %{kind: "process", id: "tightbeam:effort-checkin"},
                 reason_kind: "superseded",
                 causal_source: %{kind: "wake", id: tail.wake_id},
                 outcome: %{kind: "replacement", replacement_wake_id: tail.wake_id}
               })
             end)

    admission =
      DB.transaction(ctx.db, fn txn ->
        PatrolResponse.admit_delivery_in_txn(txn, tail.wake_id, "holder")
      end)

    assert admission == {:ok, {:stopped, :mismatch}},
           "#{dimension} mismatch admission returned #{inspect(admission)}"

    assert %{state: "canceled", fired_at: nil} = Wakes.get(ctx.db, tail.wake_id)

    assert {:ok, [["patrol_source_mismatch", "no_replacement"]]} =
             DB.query(
               ctx.db,
               "SELECT reasonKind,outcomeKind FROM wake_cancellations WHERE wakeId=?1",
               [tail.wake_id]
             )

    for _replay <- 1..5 do
      assert {:ok, :replay} =
               DB.transaction(ctx.db, fn txn ->
                 PatrolResponse.admit_delivery_in_txn(txn, tail.wake_id, "holder")
               end)
    end

    assert {:ok, [[1]]} =
             DB.query(ctx.db, "SELECT COUNT(*) FROM wake_cancellations WHERE wakeId=?1", [
               tail.wake_id
             ])

    assert {:ok, [[0]]} =
             DB.query(ctx.db, "SELECT COUNT(*) FROM assignment_prods WHERE assignmentId=?1", [
               assignment_id
             ])
  end

  defp assert_invalid_episode_schedule!(ctx, dimension) do
    suffix = Atom.to_string(dimension)
    holder = "holder_f5_#{suffix}"
    other_holder = "holder_f5_other_#{suffix}"
    assignment_id = "asg_f5_#{suffix}"
    other_assignment_id = "asg_f5_other_#{suffix}"
    session(ctx.db, holder, "supervisor")
    session(ctx.db, other_holder, "supervisor")
    assignment(ctx.db, assignment_id, holder, suffix, 140)
    assignment(ctx.db, other_assignment_id, holder, "other #{suffix}", 141)
    source_terminal = terminal!(ctx.db, holder)
    other_terminal = terminal!(ctx.db, other_holder)

    assert {:error, %RuntimeError{message: "invalid_patrol_response_episode"}} =
             DB.transaction(ctx.db, fn txn ->
               branch =
                 if dimension in [:rung_unequal, :escalation_lineage_rung],
                   do: "escalation",
                   else: "prod"

               pending_rung =
                 case dimension do
                   :rung_zero -> 0
                   :rung_negative -> -1
                   _ -> 1
                 end

               {reresolve, seed, wake_rung} =
                 case dimension do
                   :rung_unequal -> {"lineage", holder, 2}
                   :escalation_lineage_rung -> {"lineage", other_holder, 3}
                   :prod_lineage_fields -> {"lineage", holder, 1}
                   _ when branch == "escalation" -> {"lineage", holder, pending_rung}
                   _ -> {nil, nil, nil}
                 end

               wake_assignment =
                 if dimension == :wake_other_assignment,
                   do: other_assignment_id,
                   else: assignment_id

               wake =
                 Wakes.schedule_in_txn(txn, %{
                   session_key: holder,
                   origin: "process:tightbeam",
                   prompt: "invalid episode #{suffix}",
                   due_at: 0,
                   consumer: "prompt",
                   assignment_id: wake_assignment,
                   reresolve: reresolve,
                   reresolve_seed: seed,
                   reresolve_rung: wake_rung
                 })

               unless dimension in [:rung_unequal, :escalation_lineage_rung, :prod_lineage_fields] do
                 DB.Txn.q(
                   txn,
                   "INSERT INTO supervision_liveness_sidecar (wakeId,assignmentId,controllerOrigin,wakeKind,controllerState,chargedGeneration) VALUES (?1,?2,'scheduled',?3,'pending',1)",
                   [wake.wake_id, wake_assignment, branch]
                 )
               end

               unless dimension == :source_terminal_missing do
                 terminal_id =
                   case dimension do
                     :source_terminal_zero -> 0
                     :source_terminal_negative -> -1
                     :source_terminal_unknown -> 9_999_999
                     :source_terminal_other_holder -> other_terminal
                     _ -> source_terminal
                   end

                 DB.Txn.q(
                   txn,
                   "INSERT INTO supervision_watermarks (sessionKey,lastEvaluatedTerminal,pendingBranch,pendingAssignment,pendingK,pendingN) VALUES (?1,?2,?3,?4,?5,3)",
                   [holder, terminal_id, branch, assignment_id, pending_rung]
                 )
               end

               assert {:error, :invalid_patrol_response_episode} =
                        PatrolResponse.create_supervision_episode_in_txn(txn, wake.wake_id)

               raise "invalid_patrol_response_episode"
             end)

    assert {:ok, [[0]]} =
             DB.query(ctx.db, "SELECT COUNT(*) FROM wakes WHERE assignmentId IN (?1,?2)", [
               assignment_id,
               other_assignment_id
             ])

    assert {:ok, [[0]]} =
             DB.query(
               ctx.db,
               "SELECT COUNT(*) FROM supervision_patrol_response_episodes WHERE assignmentId IN (?1,?2)",
               [assignment_id, other_assignment_id]
             )

    assert {:ok, [[0]]} =
             DB.query(
               ctx.db,
               "SELECT COUNT(*) FROM patrol_output_sources WHERE assignmentId IN (?1,?2)",
               [assignment_id, other_assignment_id]
             )
  end

  defp assert_later_source_dimension_rejected!(ctx, dimension) do
    suffix = Atom.to_string(dimension)
    assignment_id = "asg_f18_later_#{suffix}"
    holder = "holder_f18_later_#{suffix}"
    session(ctx.db, holder, "supervisor")
    assignment(ctx.db, assignment_id, holder, suffix, 130)
    insert_entitlement!(ctx.db, assignment_id, generation: 1, due_at: 60_000)
    wake = prepare_effort_root!(ctx.db, assignment_id, holder)

    destination =
      case dimension do
        :destination ->
          "supervisor"

        :generation ->
          assert {:ok, []} =
                   DB.query(
                     ctx.db,
                     "UPDATE effort_checkin_generations SET state='canceled' WHERE assignmentId=?1 AND generation=1",
                     [assignment_id]
                   )

          holder

        :current_holder ->
          assert {:ok, []} =
                   DB.query(ctx.db, "UPDATE assignments SET holderKey='supervisor' WHERE id=?1", [
                     assignment_id
                   ])

          holder
      end

    assert {:ok, {:stopped, :mismatch}} =
             DB.transaction(ctx.db, fn txn ->
               PatrolResponse.admit_delivery_in_txn(txn, wake.wake_id, destination)
             end)

    assert %{state: "canceled", fired_at: nil} = Wakes.get(ctx.db, wake.wake_id)

    assert {:ok, [["patrol_source_mismatch", "no_replacement"]]} =
             DB.query(
               ctx.db,
               "SELECT reasonKind,outcomeKind FROM wake_cancellations WHERE wakeId=?1",
               [wake.wake_id]
             )

    for _replay <- 1..5 do
      assert {:ok, :replay} =
               DB.transaction(ctx.db, fn txn ->
                 PatrolResponse.admit_delivery_in_txn(txn, wake.wake_id, destination)
               end)
    end

    assert {:ok, [[1]]} =
             DB.query(ctx.db, "SELECT COUNT(*) FROM wake_cancellations WHERE wakeId=?1", [
               wake.wake_id
             ])

    assert {:ok, [[0]]} =
             DB.query(ctx.db, "SELECT COUNT(*) FROM assignment_prods WHERE assignmentId=?1", [
               assignment_id
             ])
  end

  defp insert_effort_generation_in_txn!(txn, assignment_id, holder, generation, wake_id) do
    [] =
      DB.Txn.q(
        txn,
        """
        INSERT INTO effort_checkin_generations
          (assignmentId,generation,state,baseHorizonMs,multiplier,armedAt,
           terminalSeqWatermark,holderKey,host,root,baseline,wakeId,evidence,
           agentProdded,artifactWatermark,attestWatermark,workItemWatermark)
        VALUES (?1,?2,'probed',1000,1,1,0,?3,'eezo','.',
                '{"status":"unavailable","reason":"fixture"}',?4,NULL,0,0,0,0)
        """,
        [assignment_id, generation, holder, wake_id]
      )

    :ok
  end

  defp create_racing_retry(db, root, assignment_id, holder, label) do
    case DB.transaction(db, fn txn ->
           replacement =
             Wakes.schedule_in_txn(txn, %{
               session_key: holder,
               origin: "process:tightbeam",
               prompt: label,
               due_at: 0,
               assignment_id: assignment_id
             })

           with {:ok, _source} <-
                  PatrolResponse.attach_destination_retry_in_txn(
                    txn,
                    root.wake_id,
                    replacement.wake_id
                  ),
                true <-
                  Wakes.cancel_in_txn(txn, %{
                    wake_id: root.wake_id,
                    requester: %{kind: "process", id: "tightbeam:effort-checkin"},
                    reason_kind: "superseded",
                    causal_source: %{kind: "wake", id: replacement.wake_id},
                    outcome: %{
                      kind: "replacement",
                      replacement_wake_id: replacement.wake_id
                    }
                  }) do
             :created
           else
             _ -> raise "expected retry race loss"
           end
         end) do
      {:ok, :created} -> :created
      {:error, %RuntimeError{message: "expected retry race loss"}} -> :lifecycle_won
      {:error, error} -> raise error
    end
  end

  defp run_lifecycle!(db, _assignment_id, holder, :retirement), do: retire!(db, holder)

  defp run_lifecycle!(db, assignment_id, holder, transition) do
    result = transition_assignment!(db, assignment_id, holder, transition)
    assert result.state == "closed"
    result
  end

  defp assert_no_patrol_acknowledgment!(db, wake_id, turn_seq) do
    assert {:ok, [[nil]]} =
             DB.query(
               db,
               "SELECT answerTerminalId FROM supervision_patrol_response_episodes WHERE originatingWakeId=?1",
               [wake_id]
             )

    assert {:ok, [[status]]} = DB.query(db, "SELECT status FROM turns WHERE seq=?1", [turn_seq])
    assert status in ["canceled", "failed", "failed_unknown", "delivered"]
  end

  defp transition_assignment!(db, assignment_id, holder, transition) do
    {verb, principal, params} =
      case transition do
        :completion ->
          {"attest", {:session, holder}, %{assignment_id: assignment_id, kind: "completion"}}

        :surrender ->
          {"attest", {:session, holder}, %{assignment_id: assignment_id, kind: "surrender"}}

        :revoke ->
          {"revoke-assignment", {:user, "flynn"}, %{assignment_id: assignment_id}}
      end

    result =
      Assignments.__handle__(db, verb, %{
        verb: verb,
        origin: principal_origin(principal),
        principal: principal,
        session_key: nil,
        params: params
      })

    Map.get(result, :assignment, result)
  end

  defp principal_origin({:session, key}), do: "agent:#{key}"
  defp principal_origin({:user, id}), do: "user:#{id}"

  defp terminal!(db, session_key) do
    message_id = "m_#{System.unique_integer([:positive])}"

    {:ok, seq} =
      Ledger.enqueue(db, %{
        session_key: session_key,
        message_id: message_id,
        origin: "user:flynn",
        prompt: "external"
      })

    assert {:ok, %{seq: ^seq}} = Ledger.claim_next(db, session_key, "test")
    assert :ok = Ledger.finish(db, seq, "delivered")
    seq
  end

  defp schedule_checkpoint_via_gateway!(ctx, prompt, after_ms) do
    message_id = "checkpoint-turn-#{System.unique_integer([:positive])}"

    assert {:ok, seq} =
             Ledger.enqueue(ctx.db, %{
               session_key: "holder",
               message_id: message_id,
               origin: "user:flynn",
               prompt: "checkpoint source turn",
               assignment_id: "asg_1",
               job_ref: "wi_checkpoint"
             })

    assert {:ok, %{seq: ^seq}} = Ledger.claim_next(ctx.db, "holder", "checkpoint-writer")

    assert %{wake_id: wake_id, state: "pending"} =
             ctx.handlers["wake"].(%{
               origin: "user:flynn",
               principal: {:session, "holder"},
               session_key: "holder",
               params: %{
                 prompt: prompt,
                 after_ms: after_ms,
                 nudge: false
               }
             })

    wake = Wakes.get(ctx.db, wake_id)
    assert wake.assignment_id == nil
    assert wake.creator_session_key == "holder"

    assert {:ok, [["asg_1", "holder", ^seq, "process:tightbeam"]]} =
             DB.query(
               ctx.db,
               "SELECT assignmentId,holderSessionKey,sourceTurnSeq,principal FROM supervision_liveness_checkpoint_bindings WHERE wakeId=?1",
               [wake_id]
             )

    assert :ok = Ledger.finish(ctx.db, seq, "delivered")
    {wake, seq}
  end

  defp prepare_review_gate(ctx) do
    reviewer = session(ctx.db, "reviewer", ctx.main.session_key)
    {:ok, _} = DB.query(ctx.db, "UPDATE sessions SET harness='codex' WHERE sessionKey='reviewer'")
    Roles.create!(ctx.db, "reviewer", "flynn", reviewer.session_key)

    write_rules(
      ctx,
      """
      [[rule]]
      name = "completion-needs-review"
      verb = "attest"
      text = "completion requires review"
      edges = ["verb", "turn-end"]
      effect = "remedy"
      deny_when = [
        { fact = "attest.kind", op = "eq", value = "completion" },
        { fact = "assignment.verdicts", op = "not_in", value = ["reviewed-clean"] }
      ]
      [rule.remedy]
      action = "assign"
      produces = "reviewed-clean"
      target_role = "reviewer"
      [rule.remedy.params]
      subject = "review of assignment {assignment_id}"
      reviews = "{assignment_id}"
      """
    )
  end

  defp load_turn_end_deny(ctx) do
    write_rules(
      ctx,
      """
      [[rule]]
      name = "completion-still-owed"
      verb = "attest"
      text = "completion remains owed"
      edges = ["turn-end"]
      deny_when = [
        { fact = "attest.kind", op = "eq", value = "completion" }
      ]
      """
    )
  end

  # A script-tier statute needs the wrapper, the script, and a holder the rail will accept
  # as local — `invocation_context` refuses a non-local holder before anything is spawned,
  # which would class as `script_error` and never reach the timeout under test.
  defp stage_rail_wrapper(ctx, script) do
    # The rail resolves the holder's workdir through the host registry, so the table has
    # to exist; without it the resolution fails and the deny classes `script_error`.
    :ok = Tightbeam.Schema.ensure_all(ctx.db)

    {:ok, _} =
      DB.query(ctx.db, "UPDATE sessions SET host = 'testhost' WHERE sessionKey = ?1", [
        "holder"
      ])

    scripts = Path.join([ctx.base, "identity", "rails", "scripts"])
    bin = Path.join(ctx.base, "bin")
    File.mkdir_p!(scripts)
    File.mkdir_p!(bin)

    stage_rail_script(ctx, script, "#!/bin/sh\nexit 0\n")

    wrapper = Path.join(bin, "tightbeam")
    File.cp!(Path.expand("fixtures/rail_exec/tightbeam", __DIR__), wrapper)
    File.chmod!(wrapper, 0o755)
  end

  defp stage_rail_script(ctx, name, body) do
    path = Path.join([ctx.base, "identity", "rails", "scripts", name])
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, body)
    File.chmod!(path, 0o755)
  end

  defp write_rules(ctx, contents) do
    rules_dir = Path.join(ctx.base, "identity/rules")
    File.mkdir_p!(rules_dir)
    File.write!(Path.join(rules_dir, "turn-end.toml"), contents)
    Rules.load!(ctx.base, Map.keys(ctx.handlers))
  end

  # Agent origin on purpose: work-blocked is an agent-only kind, and
  # ConditionFacts refuses it from process:tightbeam — the substrate never
  # decides a session is blocked (spec production-machine-v1 §Standing facts).
  defp file_fact(db, kind, scope) do
    {:ok, %{fact_id: _}} =
      DB.transaction(
        db,
        &ConditionFacts.file_in_txn(&1, %{kind: kind, scope: scope, origin: "session:supervisor"})
      )

    :ok
  end

  defp rail_sweep_details(db, session_key) do
    db
    |> EventLog.lifecycle_events()
    |> Enum.filter(&(&1.kind == "rail_sweep" and &1.subject == session_key))
    |> Enum.map(&JSON.decode!(&1.detail))
  end

  defp assignment(db, id, holder, subject, opened_at) do
    {:ok, _} =
      DB.query(
        db,
        "INSERT INTO assignments (id, subject, holderKey, openedByUser, openedAt) VALUES (?1, ?2, ?3, 'flynn', ?4)",
        [id, subject, holder, opened_at]
      )
  end

  defp attach_work_item!(db, assignment_id, work_item_id) do
    ensure_work_item!(db, work_item_id)

    {:ok, _} =
      DB.query(db, "UPDATE assignments SET workItemId=?2 WHERE id=?1", [
        assignment_id,
        work_item_id
      ])

    :ok
  end

  defp ensure_work_item!(db, work_item_id) do
    {:ok, _} =
      DB.query(
        db,
        """
        INSERT OR IGNORE INTO work_items
          (id,title,ownerUserId,state,createdByUser,createdAt)
        VALUES (?1,?1,'flynn','open','flynn',1)
        """,
        [work_item_id]
      )

    :ok
  end

  defp insert_artifact!(db, artifact_id, session_key, work_item_id, created_at) do
    ensure_work_item!(db, work_item_id)

    {:ok, _} =
      DB.query(
        db,
        """
        INSERT INTO artifacts
          (artifactId,kind,title,createdBySession,workItemId,originPath,
           recordedTurnEvidence,state,createdAt,updatedAt)
        VALUES (?1,'report',?1,?2,?3,?1,'none','in-workspace',?4,?4)
        """,
        [artifact_id, session_key, work_item_id, created_at]
      )

    :ok
  end

  defp retire!(db, session_key) do
    {:ok, retired} =
      DB.transaction(db, fn txn ->
        Assignments.interrupt_for_retire_in_txn(
          txn,
          session_key,
          "flynn",
          "user:flynn"
        )

        Org.retire_in_txn(txn, session_key, "user:flynn", 1_000)
      end)

    retired
  end

  defp session(db, key, spawned_by, built_in \\ false) do
    Org.create(db, %{
      session_key: key,
      display_name: key,
      owner_user_id: "flynn",
      origin: "user:flynn",
      spawned_by: spawned_by,
      kind: if(built_in, do: "main", else: "custom"),
      is_built_in: built_in,
      archetype: "default",
      harness: "claude",
      provider: "anthropic",
      model: Model.new("fable"),
      host: "eezo"
    })
  end

  defp fire_all_pending(db) do
    for wake <- Wakes.list_pending(db) do
      case DB.query(
             db,
             "SELECT 1 FROM supervision_liveness_sidecar WHERE wakeId=?1 AND controllerState='pending'",
             [wake.wake_id]
           ) do
        {:ok, [[1]]} ->
          assert :appended = admit_supervision_wake!(db, wake)
          assert {:ok, %{seq: seq}} = Ledger.claim_next(db, wake.session_key, "test-controller")
          assert :ok = Ledger.finish(db, seq, "delivered")

        {:ok, []} ->
          {:ok, _} =
            DB.query(
              db,
              "UPDATE wakes SET state='fired', firedAt=?2 WHERE wakeId=?1 AND state='pending'",
              [wake.wake_id, System.system_time(:millisecond)]
            )
      end
    end

    :ok
  end

  defp delivery_fun(db, registry, lane) do
    fn wake ->
      Gateway.deliver_prompt(wake.session_key, wake.origin, wake.prompt,
        db: db,
        wake_id: wake.wake_id,
        sender: wake.origin,
        target_gate: wake,
        fire_wake_in_txn: wake.origin == "process:tightbeam",
        conn_registry: registry,
        lane_manager: lane
      )
    end
  end

  defp admit_supervision_wake!(db, wake) do
    assert {:ok, delivery} =
             DB.transaction(db, fn txn ->
               Gateway.deliver_prompt_in_txn(
                 txn,
                 wake.session_key,
                 wake.origin,
                 wake.prompt,
                 wake_id: wake.wake_id,
                 sender: wake.origin,
                 target_gate: wake,
                 fire_wake_in_txn: true,
                 assignment_id: wake.assignment_id
               )
             end)

    case delivery do
      {:appended, _target, _message, _opts} -> :appended
      other -> other
    end
  end

  defp start_retirement_supervision(ctx) do
    suffix = System.unique_integer([:positive])
    registry = :"retirement_conn_registry_#{suffix}"
    lane = :"retirement_lane_manager_#{suffix}"
    name = :"retirement_supervision_#{suffix}"

    start_supervised!({ConnRegistry, name: registry})
    start_supervised!({LaneDoorbell, lane})

    start_supervised!(
      {Supervision,
       db: ctx.db,
       handlers: ctx.handlers,
       prod_limit: 3,
       conn_registry: registry,
       lane_manager: lane,
       name: name}
    )

    name
  end

  defp eventually(fun, tries \\ 100) do
    cond do
      fun.() ->
        true

      tries == 0 ->
        flunk("condition did not become true")

      true ->
        Process.sleep(10)
        eventually(fun, tries - 1)
    end
  end

  # ── THE ORDER PIN (supervision-impl r21) ──────────────────────────────────
  # This assertion is the executable lease on the turn-end shift: the
  # schedule in Supervision.@turn_end_schedule may only change together with
  # (1) this literal, (2) the termination argument in supervision-impl-v1
  # §r21, and (3) a semantic justification for the new position — order is
  # meaning here (statutes outrank the ladder). If this test surprised you
  # red, you changed the shift without signing the lease — go read the
  # schedule comment in supervision.ex.
  test "the turn-end schedule is exactly the r21 shift, in order" do
    assert Tightbeam.Supervision.turn_end_schedule() == [
             :rail_enforcement,
             :prod_ladder
           ]
  end
end
