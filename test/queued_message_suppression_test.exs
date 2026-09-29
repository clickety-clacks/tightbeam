defmodule Tightbeam.QueuedMessageSuppressionTest do
  use Tightbeam.TestCase, async: false

  alias Tightbeam.{Assignments, DB, Gateway, Ledger, Roles, Rules, Wakes}

  setup do
    db = String.to_atom("queued_message_suppression_#{System.unique_integer([:positive])}")
    start_supervised!({DB, path: ":memory:", name: db})
    :ok = ensure_all_schemas(db)

    register_hosts(db, %{
      Tightbeam.Placement.local_host_name() => %{
        ssh: nil,
        base_dir: Application.fetch_env!(:tightbeam, :base_dir),
        cli_bin: nil
      }
    })

    :ok =
      DB.execute(db, """
      INSERT INTO sessions
        (sessionKey, displayName, ownerUserId, origin, archetype, identityName,
         harness, provider, model, thinkingLevel, modelContext, createdAt, updatedAt)
      VALUES
        ('k1', 'K1', 'flynn', 'user:flynn', 'default', 'default',
         'claude', 'anthropic', 'claude-sonnet-5', 'medium', NULL, 1, 1)
      """)

    {:ok, _} =
      DB.query(db, "UPDATE sessions SET host=?1 WHERE sessionKey='k1'", [
        Tightbeam.Placement.local_host_name()
      ])

    %{db: db}
  end

  test "suppresses an exact liveness wake after a newer typed receipt", %{db: db} do
    assignment!(db, "asg_liveness")
    wake = liveness_wake!(db, "asg_liveness", "old liveness notice")
    seq = deliver_wake!(db, wake)

    assert {:ok, [["asg_liveness", wake_id, wake_created_at]]} =
             DB.query(
               db,
               "SELECT assignmentId,wakeId,wakeCreatedAt FROM queued_message_scopes WHERE turnSeq=?1",
               [seq]
             )

    assert wake_id == wake.wake_id
    assert wake_created_at == wake.created_at

    {:ok, _} =
      DB.query(
        db,
        """
        INSERT INTO supervision_liveness_receipts
          (assignmentId,sourceKind,sourceId,sourceAt,acceptedAt,generation,expiresAt)
        VALUES ('asg_liveness','progress','progress-1',?1,?2,2,NULL)
        """,
        [wake.created_at, wake.created_at + 1]
      )

    assert :none = Ledger.claim_next(db, "k1", "lane")

    assert {:ok, [["canceled", error]]} =
             DB.query(db, "SELECT status,error FROM turns WHERE seq=?1", [seq])

    assert error =~ "verified_liveness_recovery"
  end

  test "sender replacement is isolated by sender, holder, assignment and protected traffic", %{
    db: db
  } do
    assignment!(db, "asg_replace")
    assignment!(db, "asg_other")
    session!(db, "k2")
    session!(db, "other")
    session!(db, "reporter")
    session!(db, "sender")

    :ok =
      DB.execute(
        db,
        "UPDATE assignments SET openedByUser=NULL,openedBySession='sender' WHERE id='asg_replace'"
      )

    {:ok, own_seq} =
      Ledger.enqueue(db, %{
        session_key: "k1",
        message_id: "replace-own",
        origin: "session:sender",
        prompt: "own earlier assignment message",
        assignment_id: "asg_replace"
      })

    other_sender_wake =
      Wakes.schedule(db, %{
        session_key: "k1",
        origin: "session:other",
        prompt: "other sender message",
        due_at: System.system_time(:millisecond) + 60_000,
        creator_session_key: "other",
        assignment_id: "asg_replace"
      })

    other_sender_seq = deliver_wake!(db, other_sender_wake)

    {:ok, other_sender_direct_seq} =
      Ledger.enqueue(db, %{
        session_key: "k1",
        message_id: "replace-other-sender-direct",
        origin: "session:other",
        prompt: "other sender direct assignment message",
        assignment_id: "asg_replace"
      })

    {:ok, other_assignment_seq} =
      Ledger.enqueue(db, %{
        session_key: "k1",
        message_id: "replace-other-assignment",
        origin: "session:sender",
        prompt: "same sender, other assignment",
        assignment_id: "asg_other"
      })

    {:ok, human_seq} =
      Ledger.enqueue(db, %{
        session_key: "k1",
        message_id: "replace-human",
        origin: "user:flynn",
        prompt: "human request",
        assignment_id: "asg_replace"
      })

    report_wake =
      Wakes.schedule(db, %{
        session_key: "k1",
        origin: "agent:reporter",
        prompt: "reported material",
        due_at: System.system_time(:millisecond) + 60_000,
        creator_session_key: "reporter",
        assignment_id: "asg_replace",
        class: "fyi",
        sender_scheduled: true
      })

    report_seq = deliver_wake!(db, report_wake)

    {:ok, process_failure_seq} =
      Ledger.enqueue(db, %{
        session_key: "k1",
        message_id: "replace-process-failure",
        origin: "process:tightbeam",
        prompt: "system failure notice",
        assignment_id: "asg_replace",
        queue_message_kind: "failure"
      })

    decision_wake =
      Wakes.schedule(db, %{
        session_key: "k1",
        origin: "session:sender",
        prompt: "decision notice",
        due_at: System.system_time(:millisecond) + 60_000,
        assignment_id: "asg_replace",
        creator_session_key: "sender",
        target_gate: 0
      })

    {:ok, decision_seq} =
      Ledger.enqueue(db, %{
        session_key: "k1",
        message_id: "replace-decision",
        wake_id: decision_wake.wake_id,
        origin: "session:sender",
        prompt: "decision notice",
        assignment_id: "asg_replace",
        request_ref: "dr_decision"
      })

    failure_wake =
      Wakes.schedule(db, %{
        session_key: "k1",
        origin: "session:sender",
        prompt: "failure notice",
        due_at: System.system_time(:millisecond) + 60_000,
        assignment_id: "asg_replace",
        creator_session_key: "sender",
        obligation_ref: "terminal-child-owner-notification:asg_replace"
      })

    {:ok, failure_seq} =
      Ledger.enqueue(db, %{
        session_key: "k1",
        message_id: "replace-failure",
        wake_id: failure_wake.wake_id,
        origin: "session:sender",
        prompt: "failure notice",
        assignment_id: "asg_replace"
      })

    {:ok, other_holder_seq} =
      Ledger.enqueue(db, %{
        session_key: "k2",
        message_id: "replace-other-holder",
        origin: "session:sender",
        prompt: "same sender and assignment, other holder",
        assignment_id: "asg_replace"
      })

    replacement_wake =
      Wakes.schedule(db, %{
        session_key: "k1",
        origin: "session:sender",
        prompt: "replacement prompt",
        due_at: System.system_time(:millisecond),
        creator_session_key: "sender",
        replacement_assignment_id: "asg_replace",
        class: "fyi"
      })

    assert replacement_wake.delivery_rule == "batcher-inhibited r1"

    assert {:ok, [["asg_replace"]]} =
             DB.query(
               db,
               "SELECT assignmentId FROM queued_message_replacement_requests WHERE wakeId=?1",
               [replacement_wake.wake_id]
             )

    replacement_seq = deliver_wake!(db, replacement_wake)

    assert {:ok, [["canceled"]]} =
             DB.query(db, "SELECT status FROM turns WHERE seq=?1", [own_seq])

    for seq <- [
          other_sender_seq,
          other_sender_direct_seq,
          other_assignment_seq,
          human_seq,
          report_seq,
          process_failure_seq,
          decision_seq,
          failure_seq,
          other_holder_seq
        ] do
      assert {:ok, [["queued"]]} = DB.query(db, "SELECT status FROM turns WHERE seq=?1", [seq])
    end

    assert {:ok, [[10]]} =
             DB.query(
               db,
               "SELECT COUNT(*) FROM turns WHERE seq IN (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10)",
               [
                 own_seq,
                 other_sender_seq,
                 other_sender_direct_seq,
                 other_assignment_seq,
                 human_seq,
                 report_seq,
                 process_failure_seq,
                 decision_seq,
                 failure_seq,
                 other_holder_seq
               ]
             )

    assert {:ok, [[detail]]} =
             DB.query(
               db,
               """
               SELECT detail FROM lifecycle_events
               WHERE kind='queued_message_suppressed' AND subject=?1
               """,
               [Integer.to_string(own_seq)]
             )

    assert detail =~ "sender-replacement"
    assert detail =~ "sender_requested_replacement"
    assert detail =~ "asg_replace"
    assert detail =~ "session:sender"
    assert detail =~ "#{replacement_seq}"
  end

  test "replacement delivery claims next and keeps source durable when request time regresses", %{
    db: db
  } do
    assignment!(db, "asg_next")
    session!(db, "sender")

    :ok =
      DB.execute(
        db,
        "UPDATE assignments SET openedByUser=NULL,openedBySession='sender' WHERE id='asg_next'"
      )

    old_wake =
      Wakes.schedule(db, %{
        session_key: "k1",
        origin: "session:sender",
        prompt: "old prompt",
        due_at: System.system_time(:millisecond),
        creator_session_key: "sender",
        replacement_assignment_id: "asg_next"
      })

    old_seq = deliver_wake!(db, old_wake)

    # The production edge is two requests in one millisecond. Put the older
    # durable request ahead of the current wall clock to exercise that tie
    # deterministically, including a clock step backward between requests.
    old_request_at = System.system_time(:millisecond) + 60_000

    {:ok, _} =
      DB.query(
        db,
        "UPDATE queued_message_replacement_requests SET requestedAt=?1 WHERE wakeId=?2",
        [old_request_at, old_wake.wake_id]
      )

    wake =
      Wakes.schedule(db, %{
        session_key: "k1",
        origin: "session:sender",
        prompt: "new prompt",
        due_at: System.system_time(:millisecond),
        creator_session_key: "sender",
        replacement_assignment_id: "asg_next"
      })

    new_seq = deliver_wake!(db, wake)

    assert {:ok, [[new_request_at]]} =
             DB.query(
               db,
               "SELECT requestedAt FROM queued_message_replacement_requests WHERE wakeId=?1",
               [wake.wake_id]
             )

    assert new_request_at > old_request_at

    assert {:ok, %{seq: ^new_seq, prompt: "[from session:sender]\n\nnew prompt"}} =
             Ledger.claim_next(db, "k1", "lane")

    assert {:ok, [["canceled", "queued-message-suppressed: sender_requested_replacement"]]} =
             DB.query(db, "SELECT status,error FROM turns WHERE seq=?1", [old_seq])

    assert {:ok, [[2]]} =
             DB.query(db, "SELECT COUNT(*) FROM turns WHERE seq IN (?1,?2)", [old_seq, new_seq])
  end

  test "a delayed older replacement cannot cancel a newer queued replacement", %{db: db} do
    assignment!(db, "asg_delayed_replacement")
    session!(db, "sender")

    :ok =
      DB.execute(
        db,
        """
        UPDATE assignments SET openedByUser=NULL,openedBySession='sender'
        WHERE id='asg_delayed_replacement'
        """
      )

    delayed_old_wake =
      Wakes.schedule(db, %{
        session_key: "k1",
        origin: "session:sender",
        prompt: "older delayed instruction",
        due_at: System.system_time(:millisecond) + 60_000,
        creator_session_key: "sender",
        replacement_assignment_id: "asg_delayed_replacement"
      })

    assert {:ok, _} =
             DB.query(
               db,
               "UPDATE queued_message_replacement_requests SET requestedAt=100 WHERE wakeId=?1",
               [delayed_old_wake.wake_id]
             )

    assert {:ok, [[100]]} =
             DB.query(
               db,
               "SELECT requestedAt FROM queued_message_replacement_requests WHERE wakeId=?1",
               [delayed_old_wake.wake_id]
             )

    newer_wake =
      Wakes.schedule(db, %{
        session_key: "k1",
        origin: "session:sender",
        prompt: "newer instruction",
        due_at: System.system_time(:millisecond),
        creator_session_key: "sender",
        replacement_assignment_id: "asg_delayed_replacement"
      })

    assert {:ok, _} =
             DB.query(
               db,
               "UPDATE queued_message_replacement_requests SET requestedAt=200 WHERE wakeId=?1",
               [newer_wake.wake_id]
             )

    assert {:ok, [[200]]} =
             DB.query(
               db,
               "SELECT requestedAt FROM queued_message_replacement_requests WHERE wakeId=?1",
               [newer_wake.wake_id]
             )

    assert delayed_old_wake.due_at > newer_wake.due_at

    newer_seq = deliver_wake!(db, newer_wake)
    # deliver_wake!/2 appends directly, so this models the older scheduled wake
    # firing late after the newer replacement is already queued.
    delayed_old_seq = deliver_wake!(db, delayed_old_wake)

    assert {:ok, [["queued"]]} =
             DB.query(db, "SELECT status FROM turns WHERE seq=?1", [newer_seq])

    assert {:ok, []} =
             DB.query(
               db,
               "SELECT 1 FROM lifecycle_events WHERE kind='queued_message_suppressed' AND subject=?1",
               [Integer.to_string(newer_seq)]
             )

    assert {:ok, %{seq: ^newer_seq, prompt: "[from session:sender]\n\nnewer instruction"}} =
             Ledger.claim_next(db, "k1", "lane")

    assert {:ok, [["queued"]]} =
             DB.query(db, "SELECT status FROM turns WHERE seq=?1", [delayed_old_seq])
  end

  test "replacement keeps a same-sender generic FYI wake in FIFO", %{db: db} do
    assignment!(db, "asg_fyi")
    session!(db, "sender")

    :ok =
      DB.execute(
        db,
        "UPDATE assignments SET openedByUser=NULL,openedBySession='sender' WHERE id='asg_fyi'"
      )

    report_wake =
      Wakes.schedule(db, %{
        session_key: "k1",
        origin: "session:sender",
        prompt: "keep this FYI",
        due_at: System.system_time(:millisecond),
        creator_session_key: "sender",
        assignment_id: "asg_fyi",
        class: "fyi",
        sender_scheduled: true
      })

    report_seq = deliver_wake!(db, report_wake)

    replacement_wake =
      Wakes.schedule(db, %{
        session_key: "k1",
        origin: "session:sender",
        prompt: "replacement instruction",
        due_at: System.system_time(:millisecond),
        creator_session_key: "sender",
        replacement_assignment_id: "asg_fyi",
        class: "fyi"
      })

    replacement_seq = deliver_wake!(db, replacement_wake)

    assert {:ok, [["queued"]]} =
             DB.query(db, "SELECT status FROM turns WHERE seq=?1", [report_seq])

    assert {:ok, [["queued"]]} =
             DB.query(db, "SELECT status FROM turns WHERE seq=?1", [replacement_seq])

    assert {:ok, []} =
             DB.query(
               db,
               "SELECT 1 FROM lifecycle_events WHERE kind='queued_message_suppressed' AND subject=?1",
               [Integer.to_string(report_seq)]
             )

    # deliver_wake!/2 appends directly; the scheduler fires prompt wakes before delivery.
    assert {:ok, [[1, "pending"]]} =
             DB.query(
               db,
               "SELECT COUNT(*),MIN(state) FROM wakes WHERE wakeId=?1",
               [report_wake.wake_id]
             )

    assert {:ok, []} =
             DB.query(
               db,
               "SELECT 1 FROM queued_message_replacement_requests WHERE wakeId=?1",
               [report_wake.wake_id]
             )

    assert {:ok, %{seq: ^report_seq, prompt: "[from session:sender]\n\nkeep this FYI"}} =
             Ledger.claim_next(db, "k1", "lane")

    assert {:ok, [["queued"]]} =
             DB.query(db, "SELECT status FROM turns WHERE seq=?1", [replacement_seq])
  end

  test "later same-sender wake replaces a dispatch prompt without changing dispatch replay",
       %{db: db} do
    session!(db, "sender")
    assert %{name: "sender"} = Roles.create!(db, "sender", "flynn", "sender")

    dispatch = %{
      verb: "dispatch",
      origin: "agent:sender",
      principal: {:session, "sender"},
      session_key: "k1",
      params: %{
        subject: "initial assignment prompt",
        brief: "the initial instruction",
        idempotency_key: "dispatch-initial-once",
        work_item_id: nil
      },
      target_role: nil,
      role_fallback: false,
      supervision_interval_ms: 1_000
    }

    assignment = Assignments.__handle__(db, "dispatch", dispatch)
    assignment_id = assignment.id
    assert assignment.openedBySession == "sender"
    assert assignment.holderKey == "k1"

    assert {:ok, [[source_seq, "queued", "agent:sender", source_prompt]]} =
             DB.query(
               db,
               "SELECT seq,status,origin,prompt FROM turns WHERE sessionKey=?1 AND assignmentId=?2",
               ["k1", assignment_id]
             )

    assert source_prompt =~ assignment_id
    assert source_prompt =~ "the initial instruction"

    assert %{id: replayed_id} = Assignments.__handle__(db, "dispatch", dispatch)
    assert replayed_id == assignment_id

    assert {:ok, [[1]]} =
             DB.query(db, "SELECT COUNT(*) FROM turns WHERE sessionKey=?1", ["k1"])

    assert {:ok, [[1]]} =
             DB.query(
               db,
               "SELECT COUNT(*) FROM assignments WHERE subject=?1",
               ["initial assignment prompt"]
             )

    replacement_wake =
      Wakes.schedule(db, %{
        session_key: "k1",
        origin: "agent:sender",
        prompt: "the later replacement instruction",
        due_at: System.system_time(:millisecond),
        creator_session_key: "sender",
        replacement_assignment_id: assignment.id,
        class: "fyi"
      })

    replacement_seq = deliver_wake!(db, replacement_wake)

    assert {:ok, [["k1", "agent:sender", "sender"]]} =
             DB.query(
               db,
               "SELECT sessionKey,origin,creatorSessionKey FROM wakes WHERE wakeId=?1",
               [replacement_wake.wake_id]
             )

    assert {:ok, [[^assignment_id]]} =
             DB.query(
               db,
               "SELECT assignmentId FROM queued_message_replacement_requests WHERE wakeId=?1",
               [replacement_wake.wake_id]
             )

    assert {:ok, [["canceled", "queued-message-suppressed: sender_requested_replacement"]]} =
             DB.query(db, "SELECT status,error FROM turns WHERE seq=?1", [source_seq])

    assert {:ok, [["queued", "k1", "agent:sender"]]} =
             DB.query(
               db,
               "SELECT status,sessionKey,origin FROM turns WHERE seq=?1",
               [replacement_seq]
             )

    assert %{id: replayed_after_replacement} = Assignments.__handle__(db, "dispatch", dispatch)
    assert replayed_after_replacement == assignment_id

    assert {:ok, [[1]]} =
             DB.query(
               db,
               "SELECT COUNT(*) FROM assignments WHERE subject=?1 AND state='open'",
               ["initial assignment prompt"]
             )

    assert {:ok, [[2]]} = DB.query(db, "SELECT COUNT(*) FROM turns WHERE sessionKey=?1", ["k1"])
  end

  test "replacement leaves a turn that became running untouched", %{db: db} do
    assignment!(db, "asg_running")
    session!(db, "sender")

    :ok =
      DB.execute(
        db,
        "UPDATE assignments SET openedByUser=NULL,openedBySession='sender' WHERE id='asg_running'"
      )

    {:ok, running_seq} =
      Ledger.enqueue(db, %{
        session_key: "k1",
        message_id: "running-source",
        origin: "session:sender",
        prompt: "already running",
        assignment_id: "asg_running"
      })

    {:ok, _} =
      DB.query(db, "UPDATE turns SET status='running',startedAt=2 WHERE seq=?1", [running_seq])

    wake =
      Wakes.schedule(db, %{
        session_key: "k1",
        origin: "session:sender",
        prompt: "replacement while source runs",
        due_at: System.system_time(:millisecond),
        creator_session_key: "sender",
        replacement_assignment_id: "asg_running"
      })

    _replacement_seq = deliver_wake!(db, wake)

    assert {:ok, [["running"]]} =
             DB.query(db, "SELECT status FROM turns WHERE seq=?1", [running_seq])

    assert {:ok, []} =
             DB.query(
               db,
               """
               SELECT 1 FROM lifecycle_events
               WHERE kind='queued_message_suppressed' AND subject=?1
               """,
               [Integer.to_string(running_seq)]
             )
  end

  test "suppresses an exact liveness wake after a newer assignment disposition", %{db: db} do
    :ok = DB.execute(db, "INSERT INTO users (userId,createdAt) VALUES ('flynn',1)")
    assignment!(db, "asg_closed")
    wake = liveness_wake!(db, "asg_closed", "old effort check")
    seq = deliver_wake!(db, wake)

    Process.sleep(2)

    assert %{assignment: %{state: "closed", outcome: "completed"}} =
             Assignments.__handle__(db, "attest", %{
               principal: {:session, "k1"},
               origin: "session:k1",
               params: %{
                 assignment_id: "asg_closed",
                 kind: "completion",
                 note: "fixture completion"
               }
             })

    assert :none = Ledger.claim_next(db, "k1", "lane")

    assert {:ok, [["canceled", error]]} =
             DB.query(db, "SELECT status,error FROM turns WHERE seq=?1", [seq])

    assert error =~ "newer_assignment_disposition"
  end

  test "suppresses stale liveness after admitted continuation and preserves the continuation", %{
    db: db
  } do
    coverage_policy!()
    assignment!(db, "asg_continuation")

    {:ok, running_turn} =
      Ledger.enqueue(db, %{
        session_key: "k1",
        message_id: "continuation-origin",
        origin: "agent:holder",
        prompt: "originating turn"
      })

    assert {:ok, %{seq: ^running_turn, owner_lease: running_turn_lease}} =
             Ledger.claim_next(db, "k1", "lane")

    assert {:ok, continuation_wake} =
             DB.transaction(db, fn txn ->
               Wakes.register_wait_in_txn(txn, %{
                 session_key: "k1",
                 origin: "agent:holder",
                 prompt: "continue from the durable observation",
                 due_at: System.system_time(:millisecond),
                 assignment_id: "asg_continuation",
                 after_turn: true,
                 registrant_session_key: "k1",
                 owner_user_id: "flynn"
               })
             end)

    assert continuation_wake.wait_mode == "after-turn"

    assert :ok =
             Ledger.finish(db, running_turn, "delivered", nil, owner_lease: running_turn_lease)

    assert {:ok, true} =
             DB.transaction(db, &Wakes.covering_continuation_in_txn?(&1, "asg_continuation"))

    stale_wake = liveness_wake!(db, "asg_continuation", "stale liveness notice")
    stale_seq = deliver_wake!(db, stale_wake)

    assert :none = Ledger.claim_next(db, "k1", "lane")

    assert {:ok, [["canceled", error]]} =
             DB.query(db, "SELECT status,error FROM turns WHERE seq=?1", [stale_seq])

    assert error =~ "admitted_continuation_coverage"

    {:ok, continuation_seq} =
      Ledger.enqueue(db, %{
        session_key: "k1",
        message_id: "admitted-continuation-turn",
        wake_id: continuation_wake.wake_id,
        origin: "agent:holder",
        prompt: "the admitted continuation itself",
        assignment_id: "asg_continuation",
        queue_message_kind: "liveness"
      })

    assert {:ok, []} =
             DB.query(db, "SELECT 1 FROM queued_message_scopes WHERE turnSeq=?1", [
               continuation_seq
             ])

    assert {:ok, %{seq: ^continuation_seq}} = Ledger.claim_next(db, "k1", "lane")
  end

  test "scoped fyi unique material remains claimable after a later disposition", %{db: db} do
    work_item!(db, "wi_material")
    wake = report_wake!(db, "wi_material", "unique material result")

    {:ok, _} =
      DB.query(db, "UPDATE work_items SET state='closed' WHERE id='wi_material'", [])

    seq = deliver_wake!(db, wake)

    assert {:ok, []} =
             DB.query(db, "SELECT 1 FROM queued_message_scopes WHERE turnSeq=?1", [seq])

    assert {:ok, %{seq: ^seq, prompt: prompt}} = Ledger.claim_next(db, "k1", "lane")
    assert prompt =~ "unique material result"
  end

  test "explicit report and failure classifications are deferred and remain claimable", %{db: db} do
    {:ok, report_seq} =
      Ledger.enqueue(db, %{
        session_key: "k1",
        message_id: "explicit-report",
        origin: "agent:reporter",
        prompt: "deferred report",
        queue_message_kind: "report"
      })

    {:ok, failure_seq} =
      Ledger.enqueue(db, %{
        session_key: "k1",
        message_id: "explicit-failure",
        origin: "process:tightbeam",
        prompt: "deferred failure",
        queue_message_kind: "failure"
      })

    assert {:ok, []} = DB.query(db, "SELECT 1 FROM queued_message_scopes", [])

    assert {:ok, %{seq: ^report_seq, owner_lease: report_seq_lease}} =
             Ledger.claim_next(db, "k1", "lane")

    assert :ok = Ledger.finish(db, report_seq, "delivered", nil, owner_lease: report_seq_lease)
    assert {:ok, %{seq: ^failure_seq}} = Ledger.claim_next(db, "k1", "lane")
  end

  test "human, decision and unscoped liveness-shaped traffic fails open", %{db: db} do
    assignment!(db, "asg_preserve")

    human_wake = liveness_wake!(db, "asg_preserve", "human request")

    {:ok, human_seq} =
      Ledger.enqueue(db, %{
        session_key: "k1",
        message_id: "human-request",
        wake_id: human_wake.wake_id,
        origin: "user:flynn",
        prompt: "keep this request",
        assignment_id: "asg_preserve",
        queue_message_kind: "liveness"
      })

    decision_wake =
      Wakes.schedule(db, %{
        session_key: "k1",
        origin: "process:tightbeam",
        prompt: "keep this decision notification",
        due_at: System.system_time(:millisecond) + 60_000,
        target_gate: 0,
        assignment_id: "asg_preserve",
        consumer: "effort_probe"
      })

    {:ok, decision_seq} =
      Ledger.enqueue(db, %{
        session_key: "k1",
        message_id: "decision-notification",
        wake_id: decision_wake.wake_id,
        origin: "process:tightbeam",
        prompt: "keep this decision notification",
        assignment_id: "asg_preserve",
        queue_message_kind: "liveness"
      })

    unscoped_wake =
      Wakes.schedule(db, %{
        session_key: "k1",
        origin: "process:tightbeam",
        prompt: "keep this unscoped notice",
        due_at: System.system_time(:millisecond) + 60_000,
        consumer: "effort_probe"
      })

    {:ok, unscoped_seq} =
      Ledger.enqueue(db, %{
        session_key: "k1",
        message_id: "unscoped-notice",
        wake_id: unscoped_wake.wake_id,
        origin: "process:tightbeam",
        prompt: "keep this unscoped notice",
        queue_message_kind: "liveness"
      })

    assert {:ok, []} =
             DB.query(
               db,
               "SELECT 1 FROM queued_message_scopes WHERE turnSeq IN (?1,?2,?3)",
               [human_seq, decision_seq, unscoped_seq]
             )
  end

  defp work_item!(db, id) do
    :ok =
      DB.execute(db, """
      INSERT INTO work_items
        (id,title,ownerUserId,state,createdByUser,createdAt)
      VALUES ('#{id}','#{id}','flynn','open','flynn',1)
      """)
  end

  defp assignment!(db, id) do
    :ok =
      DB.execute(db, """
      INSERT INTO assignments
        (id,subject,holderKey,openedByUser,openedAt,state)
      VALUES ('#{id}','#{id}','k1','flynn',1,'open')
      """)

    :ok =
      DB.execute(db, """
      INSERT INTO assignment_effects (assignmentId,effectKind)
      VALUES ('#{id}','coordination')
      """)
  end

  defp session!(db, id) do
    :ok =
      DB.execute(db, """
      INSERT INTO sessions
        (sessionKey,displayName,ownerUserId,origin,archetype,identityName,
         harness,provider,model,thinkingLevel,modelContext,createdAt,updatedAt)
      VALUES ('#{id}','#{id}','flynn','user:flynn','default','default',
              'claude','anthropic','claude-sonnet-5','medium',NULL,1,1)
      """)
  end

  defp report_wake!(db, work_item_id, prompt) do
    Wakes.schedule(db, %{
      session_key: "k1",
      origin: "agent:reporter",
      prompt: prompt,
      due_at: System.system_time(:millisecond) + 60_000,
      work_item_id: work_item_id,
      class: "fyi",
      sender_scheduled: true
    })
  end

  defp liveness_wake!(db, assignment_id, prompt) do
    Wakes.schedule(db, %{
      session_key: "k1",
      origin: "process:tightbeam",
      prompt: prompt,
      due_at: System.system_time(:millisecond) + 60_000,
      assignment_id: assignment_id,
      consumer: "effort_probe"
    })
  end

  defp deliver_wake!(db, wake) do
    assert {:ok, {:appended, "k1", _message, _opts}} =
             DB.transaction(db, fn txn ->
               Gateway.deliver_prompt_in_txn(
                 txn,
                 wake.session_key,
                 wake.origin,
                 wake.prompt,
                 wake_id: wake.wake_id,
                 sender: wake.origin,
                 device_id: "test",
                 client_message_id: wake.wake_id,
                 target_gate: wake
               )
             end)

    assert {:ok, [[seq]]} =
             DB.query(db, "SELECT seq FROM turns WHERE wakeId=?1", [wake.wake_id])

    seq
  end

  defp coverage_policy! do
    base =
      Path.join(
        System.tmp_dir!(),
        "queued-message-coverage-#{System.unique_integer([:positive])}"
      )

    rules_dir = Path.join(base, "identity/rules")
    File.mkdir_p!(rules_dir)

    File.write!(Path.join(rules_dir, "coverage.toml"), """
    [[policy]]
    name = "queued-message-coverage"
    purpose = "wait-prod-coverage"
    when = [{fact="wait.coverage_valid",op="eq",value=true}]
    """)

    Rules.load!(base, ~w(wake attest))
  end
end
