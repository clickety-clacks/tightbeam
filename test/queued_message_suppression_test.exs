defmodule Tightbeam.QueuedMessageSuppressionTest do
  use Tightbeam.TestCase, async: false

  alias Tightbeam.{Assignments, DB, Gateway, Ledger, Rules, Wakes}

  setup do
    db = String.to_atom("queued_message_suppression_#{System.unique_integer([:positive])}")
    start_supervised!({DB, path: ":memory:", name: db})
    :ok = ensure_all_schemas(db)

    :ok =
      DB.execute(db, """
      INSERT INTO sessions
        (sessionKey, displayName, ownerUserId, origin, archetype, identityName,
         harness, provider, model, thinkingLevel, modelContext, createdAt, updatedAt)
      VALUES
        ('k1', 'K1', 'flynn', 'user:flynn', 'default', 'default',
         'claude', 'anthropic', 'claude-sonnet-5', 'medium', NULL, 1, 1)
      """)

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
