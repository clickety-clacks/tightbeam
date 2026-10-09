defmodule Tightbeam.QueuedMessageSuppressionTest do
  use Tightbeam.TestCase, async: false

  alias Tightbeam.{
    Assignments,
    ConnRegistry,
    DB,
    Ledger,
    NoticeBatcher,
    Projection,
    QueuedMessageSuppression,
    Roles,
    Rules,
    Wakes
  }

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

    assert replacement_wake.delivery_rule == "notice-batching-v1 r2"

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

    delayed_retry_wake =
      Wakes.schedule(db, %{
        session_key: "k1",
        origin: "session:sender",
        prompt: "older delayed instruction",
        due_at: System.system_time(:millisecond) + 60_000,
        creator_session_key: "sender"
      })

    assert {:ok, :ok} =
             DB.transaction(db, fn txn ->
               QueuedMessageSuppression.copy_replacement_request_in_txn(
                 txn,
                 delayed_old_wake.wake_id,
                 delayed_retry_wake.wake_id
               )
             end)

    assert {:ok, [[100]]} =
             DB.query(
               db,
               "SELECT requestedAt FROM queued_message_replacement_requests WHERE wakeId=?1",
               [delayed_retry_wake.wake_id]
             )

    # The delayed retry carries its source timestamp even though its wake row is new.
    delayed_old_seq = deliver_wake!(db, delayed_retry_wake)

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

  test "pending dispatch correction shares one real carrier with the other sender", %{db: db} do
    %{turn: turn, assignment: assignment, initial: initial, control: control} =
      busy_dispatch_queue!(db)

    correction = replacement_source!(db, assignment.id, "CORRECTION queue nonce")
    assert_superseded_source!(db, initial, correction)
    assert Wakes.get(db, control.wake_id).state == "pending"
    assert NoticeBatcher.recover(db) == []
    assert {:ok, [[1]]} = DB.query(db, "SELECT COUNT(*) FROM turns WHERE sessionKey='k1'")
    assert {:ok, [[0]]} = DB.query(db, "SELECT COUNT(*) FROM notice_batch_members")

    assert {:ok, [["running"]]} =
             DB.query(db, "SELECT status FROM turns WHERE seq=?1", [turn.seq])

    # End the owned durable turn; no sleeps or process timing establish readiness.
    assert :ok = Ledger.finish(db, turn.seq, "delivered", nil, owner_lease: turn.owner_lease)
    [carrier] = NoticeBatcher.recover(db)
    assert carrier not in [initial.wake_id, control.wake_id, correction.wake_id]

    for source <- [control, correction] do
      assert [%{delivery_wake_id: ^carrier, batch_state: "delivered", member_state: "included"}] =
               NoticeBatcher.source_refs(db, source.wake_id)
    end

    assert NoticeBatcher.source_refs(db, initial.wake_id) == []

    assert {:ok, [[seq, "queued", prompt]]} =
             DB.query(db, "SELECT seq,status,prompt FROM turns WHERE wakeId=?1", [carrier])

    assert prompt =~ control.prompt
    assert prompt =~ correction.prompt
    refute prompt =~ "INITIAL queue nonce"
    assert {control_pos, _} = :binary.match(prompt, control.wake_id)
    assert {correction_pos, _} = :binary.match(prompt, correction.wake_id)
    assert control_pos < correction_pos
    assert {:ok, [[2]]} = DB.query(db, "SELECT COUNT(*) FROM notice_batch_members")

    assert {:ok, [[0]]} =
             DB.query(db, "SELECT COUNT(*) FROM turns WHERE wakeId IN (?1,?2,?3)", [
               initial.wake_id,
               control.wake_id,
               correction.wake_id
             ])

    assert NoticeBatcher.recover(db) == []
    assert {:ok, [[2]]} = DB.query(db, "SELECT COUNT(*) FROM turns WHERE sessionKey='k1'")
    assert {:ok, %{seq: ^seq, prompt: ^prompt}} = Ledger.claim_next(db, "k1", "lane")
  end

  test "a second conversational correction supersedes the first pending correction", %{db: db} do
    %{turn: turn, assignment: assignment, initial: initial, control: control} =
      busy_dispatch_queue!(db)

    older = replacement_source!(db, assignment.id, "OLDER queue nonce")
    newest = replacement_source!(db, assignment.id, "NEWEST queue nonce")

    # CLI --replace-queued scopes suppression; it cannot forge wake/turn attribution.
    assert older.assignment_id == nil
    assert newest.assignment_id == nil
    assert_superseded_source!(db, initial, older)
    assert_superseded_source!(db, older, newest)
    assert Wakes.get(db, control.wake_id).state == "pending"
    assert Wakes.get(db, newest.wake_id).state == "pending"
    assert NoticeBatcher.source_refs(db, older.wake_id) == []
    assert {:ok, [[1]]} = DB.query(db, "SELECT COUNT(*) FROM turns WHERE sessionKey='k1'")
    assert :ok = Ledger.finish(db, turn.seq, "delivered", nil, owner_lease: turn.owner_lease)
    [carrier] = NoticeBatcher.recover(db)
    assert {:ok, [[prompt]]} = DB.query(db, "SELECT prompt FROM turns WHERE wakeId=?1", [carrier])
    assert prompt =~ control.prompt
    assert prompt =~ newest.prompt
    refute prompt =~ "INITIAL queue nonce"
    refute prompt =~ older.prompt

    for source <- [control, newest] do
      assert [%{delivery_wake_id: ^carrier, batch_state: "delivered", member_state: "included"}] =
               NoticeBatcher.source_refs(db, source.wake_id)
    end

    assert {:ok, [[2]]} = DB.query(db, "SELECT COUNT(*) FROM notice_batch_members")
    assert NoticeBatcher.recover(db) == []
    assert {:ok, [[2]]} = DB.query(db, "SELECT COUNT(*) FROM turns WHERE sessionKey='k1'")
  end

  defp busy_dispatch_queue!(db) do
    start_supervised!({ConnRegistry, name: ConnRegistry})
    start_supervised!({Tightbeam.NoticeBatcherFixture.LaneStub, Tightbeam.LaneManager})
    session!(db, "sender")
    session!(db, "other")
    assert %{name: "sender"} = Roles.create!(db, "sender", "flynn", "sender")

    {:appended, message} =
      Projection.append(db, %{
        session_key: "k1",
        role: "user",
        sender: "user:flynn",
        content: "running bounded task"
      })

    {:ok, seq} =
      Ledger.enqueue(db, %{
        session_key: "k1",
        message_id: message.id,
        origin: "user:flynn",
        prompt: "running bounded task"
      })

    assert {:ok, %{seq: ^seq} = turn} = Ledger.claim_next(db, "k1", "lane")

    assignment =
      Assignments.__handle__(db, "dispatch", %{
        verb: "dispatch",
        origin: "agent:sender",
        principal: {:session, "sender"},
        session_key: "k1",
        target_role: nil,
        role_fallback: false,
        supervision_interval_ms: 1_000,
        params: %{
          subject: "pending queue correction",
          brief: "INITIAL queue nonce",
          idempotency_key: "pending-dispatch-once",
          work_item_id: nil
        }
      })

    assert is_binary(assignment.id)

    assert {:ok, [[initial_id]]} =
             DB.query(
               db,
               "SELECT wakeId FROM wakes WHERE assignmentId=?1 AND consumer='prompt' AND digest=0",
               [assignment.id]
             )

    initial = Wakes.get(db, initial_id)
    assert initial.state == "pending"
    assert initial.prompt =~ "INITIAL queue nonce"

    control =
      Wakes.schedule(db, %{
        session_key: "k1",
        origin: "session:other",
        creator_session_key: "other",
        prompt: "CONTROL queue nonce",
        due_at: System.system_time(:millisecond),
        class: "fyi"
      })

    %{turn: turn, assignment: assignment, initial: initial, control: control}
  end

  defp replacement_source!(db, assignment_id, prompt) do
    Wakes.schedule(db, %{
      session_key: "k1",
      origin: "agent:sender",
      creator_session_key: "sender",
      prompt: prompt,
      due_at: System.system_time(:millisecond),
      class: "fyi",
      replacement_assignment_id: assignment_id
    })
  end

  defp assert_superseded_source!(db, source, replacement) do
    assert %{state: "canceled", prompt: prompt} = Wakes.get(db, source.wake_id)
    assert prompt == source.prompt

    assert {:ok, [["superseded", "wake", replacement_id, replacement_id]]} =
             DB.query(
               db,
               "SELECT reasonKind,causalSourceKind,causalSourceId,replacementWakeId FROM wake_cancellations WHERE wakeId=?1",
               [source.wake_id]
             )

    assert replacement_id == replacement.wake_id

    assert {:ok, [[event]]} =
             DB.query(
               db,
               "SELECT detail FROM lifecycle_events WHERE kind='queued_message_suppressed' AND subject=?1",
               [source.wake_id]
             )

    assert %{
             "sourceId" => source_id,
             "replacementWakeId" => ^replacement_id,
             "cause" => "sender_requested_replacement"
           } = JSON.decode!(event)

    assert source_id == source.wake_id
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
    # This suite isolates the pre-claim suppression rules for an already
    # materialized queue row. Seed that legacy source/turn pair below the
    # recipient batching admission path; notice-batch readiness and carrier
    # delivery have their own integration coverage.
    stamped = "[from #{wake.origin}]\n\n#{wake.prompt}"

    {:appended, message} =
      Projection.append(db, %{
        session_key: wake.session_key,
        role: "user",
        content: stamped,
        sender: wake.origin,
        device_id: "test",
        client_message_id: wake.wake_id
      })

    {:ok, seq} =
      Ledger.enqueue(db, %{
        session_key: wake.session_key,
        message_id: message.id,
        wake_id: wake.wake_id,
        origin: wake.origin,
        prompt: stamped,
        assignment_id: wake.assignment_id,
        job_ref: wake.work_item_id
      })

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
