defmodule Tightbeam.SupervisionTest do
  use Tightbeam.TestCase, async: false

  alias Tightbeam.{DB, Gateway, Org, Supervision, Wakes}
  alias Tightbeam.Model

  setup do
    db = String.to_atom("supervision_db_#{System.unique_integer([:positive])}")
    start_supervised!({DB, path: ":memory:", name: db})
    ensure_all_schemas(db)

    {:ok, _} =
      DB.query(db, "INSERT INTO users (userId,isAdmin,createdAt) VALUES ('flynn',1,1)")

    main = ensure_main_session(db, "flynn")
    parent = session(db, "parent", main.session_key)
    holder = session(db, "holder", parent.session_key)

    {:ok, _} =
      DB.query(
        db,
        "INSERT INTO assignments (id,subject,holderKey,openedByUser,openedAt,state) " <>
          "VALUES ('asg_inactive','ship it',?1,'flynn',?2,'open')",
        [holder.session_key, System.system_time(:millisecond)]
      )

    %{db: db, main: main, parent: parent, holder: holder}
  end

  test "a due deadline stores one ordinary notice and an unanswered rung readdresses it", ctx do
    opened_at = System.system_time(:millisecond) - 5_000
    interval_ms = 1_000

    assert {:ok, _} =
             DB.query(ctx.db, "UPDATE assignments SET openedAt=?2 WHERE id=?1", [
               "asg_inactive",
               opened_at
             ])

    open_deadline!(ctx.db, "asg_inactive", opened_at, interval_ms)

    deadline = pending_deadline!(ctx.db, "asg_inactive")

    assert is_map(deadline)
    assert deadline.due_at <= System.system_time(:millisecond)
    assert {:ok, :ok} = Supervision.deadline(ctx.db, deadline)

    assert {:ok, [[notice_id, prompt, holder, episode_ref]]} =
             DB.query(
               ctx.db,
               "SELECT wakeId,prompt,sessionKey,obligationRef FROM wakes " <>
                 "WHERE assignmentId='asg_inactive' AND consumer='prompt' " <>
                 "AND state='pending' AND obligationRef LIKE 'assignment-inactivity-episode-v1:%'"
             )

    assert prompt =~ "asg_inactive"
    assert prompt =~ "ship it"
    assert holder == ctx.holder.session_key
    assert String.starts_with?(episode_ref, "assignment-inactivity-episode-v1:")

    climb = pending_climb!(ctx.db, "asg_inactive")

    assert is_map(climb)

    assert {:ok, _} =
             DB.query(ctx.db, "UPDATE wakes SET dueAt=0 WHERE wakeId=?1 AND state='pending'", [
               climb.wake_id
             ])

    assert {:ok, :ok} = Supervision.climb(ctx.db, Wakes.get(ctx.db, climb.wake_id))

    notice = Wakes.get(ctx.db, notice_id)
    assert notice.state == "pending"
    assert notice.session_key == ctx.parent.session_key
    assert notice.prompt == prompt

    assert {:ok, [[1]]} =
             DB.query(
               ctx.db,
               "SELECT COUNT(*) FROM wakes WHERE assignmentId='asg_inactive' " <>
                 "AND consumer='prompt' AND obligationRef=?1 AND state='pending'",
               [episode_ref]
             )

    assert {:ok, {:canceled, {^notice_id, nil}}} =
             DB.transaction(ctx.db, fn txn ->
               Wakes.undeliverable_delivery_in_txn(
                 txn,
                 notice_id,
                 "recipient is not currently resolvable",
                 System.system_time(:millisecond)
               )
             end)

    assert Wakes.get(ctx.db, notice_id).state == "canceled"

    assert {:ok, [[nil]]} =
             DB.query(ctx.db, "SELECT deliveredTurnSeq FROM wakes WHERE wakeId=?1", [notice_id])

    next_climb = pending_climb!(ctx.db, "asg_inactive")

    assert is_map(next_climb)

    assert {:ok, _} =
             DB.query(ctx.db, "UPDATE wakes SET dueAt=0 WHERE wakeId=?1 AND state='pending'", [
               next_climb.wake_id
             ])

    assert {:ok, :ok} =
             Supervision.climb(ctx.db, Wakes.get(ctx.db, next_climb.wake_id))

    assert {:ok, [[successor_id, successor_prompt, main]]} =
             DB.query(
               ctx.db,
               "SELECT wakeId,prompt,sessionKey FROM wakes " <>
                 "WHERE assignmentId='asg_inactive' AND consumer='prompt' " <>
                 "AND state='pending' AND obligationRef=?1",
               [episode_ref]
             )

    assert successor_id != notice_id
    assert successor_prompt == prompt
    assert main == ctx.main.session_key
    assert Wakes.get(ctx.db, notice_id).state == "canceled"
  end

  test "legacy controller cleanup survives a real migration transaction and stamps once", ctx do
    legacy =
      Wakes.schedule(ctx.db, %{
        session_key: ctx.holder.session_key,
        assignment_id: "asg_inactive",
        origin: "process:tightbeam",
        creator_session_key: nil,
        prompt: "legacy scheduled controller",
        due_at: System.system_time(:millisecond) + 60_000
      })

    assert {:ok, _} =
             DB.query(
               ctx.db,
               """
               INSERT INTO supervision_liveness_sidecar (
                 wakeId,assignmentId,controllerOrigin,wakeKind,controllerState,chargedGeneration
               ) VALUES (?1,'asg_inactive','scheduled','prod','pending',1)
               """,
               [legacy.wake_id]
             )

    assert :ok = Supervision.migrate_open_assignments(ctx.db, 60_000)

    migrated = pending_deadline!(ctx.db, "asg_inactive")
    assert migrated.wake_id != legacy.wake_id
    assert Wakes.get(ctx.db, legacy.wake_id).state == "canceled"

    assert {:ok, [["settled"]]} =
             DB.query(
               ctx.db,
               "SELECT controllerState FROM supervision_liveness_sidecar WHERE wakeId=?1",
               [legacy.wake_id]
             )

    assert :ok = Supervision.migrate_open_assignments(ctx.db, 1)
    assert pending_deadline!(ctx.db, "asg_inactive").wake_id == migrated.wake_id

    assert {:ok, [[1]]} =
             DB.query(
               ctx.db,
               "SELECT COUNT(*) FROM wakes WHERE assignmentId='asg_inactive' AND consumer='assignment_inactivity_deadline' AND state='pending'"
             )
  end

  test "holder wake registration moves its deadline from registration time, not future due time",
       ctx do
    opened_at = System.system_time(:millisecond)
    interval_ms = 60_000
    open_deadline!(ctx.db, "asg_inactive", opened_at, interval_ms)

    old_deadline = pending_deadline!(ctx.db, "asg_inactive")

    wake =
      Wakes.schedule(ctx.db, %{
        session_key: ctx.holder.session_key,
        creator_session_key: ctx.holder.session_key,
        assignment_id: "asg_inactive",
        origin: "session:#{ctx.holder.session_key}",
        prompt: "recheck this assignment later",
        due_at: System.system_time(:millisecond) + 2 * interval_ms
      })

    assert wake.created_at < wake.due_at

    deadline = pending_deadline!(ctx.db, "asg_inactive")
    assert deadline.due_at == wake.created_at + interval_ms
    assert deadline.due_at < wake.due_at

    if deadline.wake_id == old_deadline.wake_id do
      # Opening and registration can share one millisecond, making the old
      # row already the exact deadline derived from the registration time.
      assert old_deadline.due_at == wake.created_at + interval_ms
    else
      assert Wakes.get(ctx.db, old_deadline.wake_id).state == "canceled"
    end

    assert {:ok, :ignored} =
             DB.transaction(ctx.db, fn txn ->
               Supervision.activity_in_txn(
                 txn,
                 "asg_inactive",
                 ctx.parent.session_key,
                 wake.created_at + interval_ms
               )
             end)

    assert pending_deadline!(ctx.db, "asg_inactive").wake_id == deadline.wake_id
  end

  test "deadline and reopen lookups keep indexed plans with long assignment history", ctx do
    history_size = 20_000

    assert {:ok, []} =
             DB.query(
               ctx.db,
               """
               WITH RECURSIVE seq(value) AS (
                 VALUES (1)
                 UNION ALL
                 SELECT value + 1 FROM seq WHERE value < #{history_size}
               )
               INSERT INTO wakes (wakeId,sessionKey,origin,consumer,dueAt,state,createdAt,assignmentId)
               SELECT 'historical-deadline-' || printf('%08d',value),
                      ?1,'process:tightbeam','assignment_inactivity_deadline',value,'fired',value,?2
               FROM seq
               """,
               [ctx.holder.session_key, "asg_inactive"]
             )

    assert {:ok, []} =
             DB.query(
               ctx.db,
               """
               WITH RECURSIVE seq(value) AS (
                 VALUES (1)
                 UNION ALL
                 SELECT value + 1 FROM seq WHERE value < #{history_size}
               )
               INSERT INTO assignment_reopenings (
                 assignmentId,ts,reopenedByUser,reason,priorOutcome,priorClosedAt
               )
               SELECT ?1,value,'flynn','synthetic historical close','completed',value
               FROM seq
               """,
               ["asg_inactive"]
             )

    assert {:ok, [[^history_size]]} =
             DB.query(
               ctx.db,
               "SELECT COUNT(*) FROM wakes WHERE assignmentId=?1 AND consumer='assignment_inactivity_deadline'",
               ["asg_inactive"]
             )

    assert {:ok, [[^history_size]]} =
             DB.query(
               ctx.db,
               "SELECT COUNT(*) FROM assignment_reopenings WHERE assignmentId=?1",
               [
                 "asg_inactive"
               ]
             )

    assert {:ok, deadline_plan} =
             DB.query(
               ctx.db,
               "EXPLAIN QUERY PLAN SELECT prompt FROM wakes WHERE assignmentId=?1 AND consumer=?2 ORDER BY createdAt DESC,wakeId DESC LIMIT 1",
               ["asg_inactive", "assignment_inactivity_deadline"]
             )

    assert Enum.any?(deadline_plan, fn [_, _, _, detail] ->
             String.contains?(detail, "wakes_assignment_consumer_created_order")
           end)

    assert {:ok, reopen_plan} =
             DB.query(
               ctx.db,
               "EXPLAIN QUERY PLAN SELECT MAX(ts) FROM assignment_reopenings WHERE assignmentId=?1",
               ["asg_inactive"]
             )

    assert Enum.any?(reopen_plan, fn [_, _, _, detail] ->
             String.contains?(detail, "assignment_reopenings_activity_source_order")
           end)

    assert {:ok, reconciliation_plan} =
             DB.query(
               ctx.db,
               "EXPLAIN QUERY PLAN SELECT wakeId FROM wakes INDEXED BY wakes_delivered_turn " <>
                 "WHERE deliveredTurnSeq IS NOT NULL AND " <>
                 "(substr(obligationRef,1,length(?1))=?1 OR substr(obligationRef,1,length(?2))=?2)",
               [
                 "terminal-child-owner-notification:",
                 "terminal-child-owner-action-reminder:"
               ]
             )

    assert Enum.any?(reconciliation_plan, fn [_, _, _, detail] ->
             String.contains?(detail, "wakes_delivered_turn")
           end)

    assert {:ok, terminal_action_plan} =
             DB.query(
               ctx.db,
               "EXPLAIN QUERY PLAN SELECT id FROM attests WHERE bySession=?1 AND kind='progress' AND note LIKE ?2 ESCAPE ?3 LIMIT 1",
               [
                 ctx.main.session_key,
                 "completion-handoff-action asg_inactive attest w_history %",
                 "\\"
               ]
             )

    assert Enum.any?(terminal_action_plan, fn [_, _, _, detail] ->
             String.contains?(detail, "attests_terminal_action_note")
           end)
  end

  test "an unanswered climb preserves a delivered rung and creates a fresh parent notice", ctx do
    opened_at = System.system_time(:millisecond) - 5_000
    interval_ms = 1_000

    assert {:ok, _} =
             DB.query(ctx.db, "UPDATE assignments SET openedAt=?2 WHERE id=?1", [
               "asg_inactive",
               opened_at
             ])

    open_deadline!(ctx.db, "asg_inactive", opened_at, interval_ms)
    deadline = pending_deadline!(ctx.db, "asg_inactive")
    assert {:ok, :ok} = Supervision.deadline(ctx.db, deadline)

    notice =
      Enum.find(Wakes.list_pending(ctx.db), fn wake ->
        wake.consumer == "prompt" and wake.assignment_id == "asg_inactive"
      end)

    assert is_map(notice)

    assert {:ok, {:appended, _, _, _}} =
             DB.transaction(ctx.db, fn txn ->
               Gateway.deliver_prompt_in_txn(
                 txn,
                 notice.session_key,
                 notice.origin,
                 notice.prompt,
                 wake_id: notice.wake_id,
                 fire_wake_in_txn: true
               )
             end)

    assert {:ok, [[delivered_turn_seq]]} =
             DB.query(ctx.db, "SELECT deliveredTurnSeq FROM wakes WHERE wakeId=?1", [
               notice.wake_id
             ])

    assert is_integer(delivered_turn_seq)

    climb = pending_climb!(ctx.db, "asg_inactive")

    assert is_map(climb)

    assert {:ok, _} =
             DB.query(ctx.db, "UPDATE wakes SET dueAt=0 WHERE wakeId=?1 AND state='pending'", [
               climb.wake_id
             ])

    assert {:ok, :ok} = Supervision.climb(ctx.db, Wakes.get(ctx.db, climb.wake_id))

    assert {:ok, [["fired", ^delivered_turn_seq, holder, prompt, episode_ref]]} =
             DB.query(
               ctx.db,
               "SELECT state,deliveredTurnSeq,sessionKey,prompt,obligationRef FROM wakes WHERE wakeId=?1",
               [notice.wake_id]
             )

    assert holder == ctx.holder.session_key

    assert {:ok, [[successor_id, successor_holder, ^prompt, ^episode_ref]]} =
             DB.query(
               ctx.db,
               "SELECT wakeId,sessionKey,prompt,obligationRef FROM wakes " <>
                 "WHERE assignmentId='asg_inactive' AND consumer='prompt' " <>
                 "AND state='pending' AND obligationRef=?1",
               [episode_ref]
             )

    assert successor_id != notice.wake_id
    assert successor_holder == ctx.parent.session_key
  end

  test "retiring a pending notice recipient readdresses the same episode wake", ctx do
    opened_at = System.system_time(:millisecond) - 5_000
    interval_ms = 1_000

    assert {:ok, _} =
             DB.query(ctx.db, "UPDATE assignments SET openedAt=?2 WHERE id=?1", [
               "asg_inactive",
               opened_at
             ])

    open_deadline!(ctx.db, "asg_inactive", opened_at, interval_ms)
    deadline = pending_deadline!(ctx.db, "asg_inactive")
    assert {:ok, :ok} = Supervision.deadline(ctx.db, deadline)

    notice =
      Enum.find(Wakes.list_pending(ctx.db), fn wake ->
        wake.consumer == "prompt" and wake.assignment_id == "asg_inactive"
      end)

    assert is_map(notice)
    climb = pending_climb!(ctx.db, "asg_inactive")

    assert {:ok, _} =
             DB.query(ctx.db, "UPDATE wakes SET dueAt=0 WHERE wakeId=?1 AND state='pending'", [
               climb.wake_id
             ])

    assert {:ok, :ok} = Supervision.climb(ctx.db, Wakes.get(ctx.db, climb.wake_id))
    assert Wakes.get(ctx.db, notice.wake_id).session_key == ctx.parent.session_key

    assert %{state: "retired"} = Org.retire(ctx.db, ctx.parent.session_key, "user:flynn")

    readdressed = Wakes.get(ctx.db, notice.wake_id)
    assert readdressed.state == "pending"
    assert readdressed.session_key == ctx.main.session_key
    assert readdressed.target_gate == 1
    assert readdressed.prompt == notice.prompt
    assert readdressed.obligation_ref == notice.obligation_ref

    next_climb = pending_climb!(ctx.db, "asg_inactive")

    assert {:ok, _} =
             DB.query(ctx.db, "UPDATE wakes SET dueAt=0 WHERE wakeId=?1 AND state='pending'", [
               next_climb.wake_id
             ])

    assert {:ok, :ok} = Supervision.climb(ctx.db, Wakes.get(ctx.db, next_climb.wake_id))
    assert Wakes.get(ctx.db, notice.wake_id).session_key == ctx.main.session_key

    assert {:ok, [[1]]} =
             DB.query(
               ctx.db,
               "SELECT COUNT(*) FROM wakes WHERE assignmentId='asg_inactive' AND consumer='prompt' AND obligationRef=?1 AND state='pending'",
               [notice.obligation_ref]
             )
  end

  test "activity from an authenticated holder moves a pending deadline once at its event time",
       ctx do
    opened_at = System.system_time(:millisecond)
    interval_ms = 60_000
    open_deadline!(ctx.db, "asg_inactive", opened_at, interval_ms)

    event_at = System.system_time(:millisecond) + 10

    assert {:ok, :reset} =
             DB.transaction(ctx.db, fn txn ->
               Supervision.activity_in_txn(
                 txn,
                 "asg_inactive",
                 ctx.holder.session_key,
                 event_at
               )
             end)

    deadline = pending_deadline!(ctx.db, "asg_inactive")
    assert deadline.due_at == event_at + interval_ms

    assert {:ok, :reset} =
             DB.transaction(ctx.db, fn txn ->
               Supervision.activity_in_txn(
                 txn,
                 "asg_inactive",
                 ctx.holder.session_key,
                 event_at
               )
             end)

    assert pending_deadline!(ctx.db, "asg_inactive").wake_id == deadline.wake_id
    assert pending_deadline!(ctx.db, "asg_inactive").due_at == event_at + interval_ms
  end

  defp open_deadline!(db, assignment_id, opened_at, interval_ms) do
    assert {:ok, :ok} =
             DB.transaction(db, fn txn ->
               Supervision.assignment_opened_in_txn(txn, assignment_id, opened_at, interval_ms)
             end)
  end

  defp pending_deadline!(db, assignment_id) do
    pending_internal_wake!(db, "assignment_inactivity_deadline", assignment_id)
  end

  defp pending_climb!(db, assignment_id) do
    pending_internal_wake!(db, "assignment_inactivity_climb", assignment_id)
  end

  defp pending_internal_wake!(db, consumer, assignment_id) do
    assert {:ok, [[wake_id]]} =
             DB.query(
               db,
               "SELECT wakeId FROM wakes WHERE consumer=?1 AND assignmentId=?2 AND state='pending' ORDER BY dueAt,wakeId LIMIT 1",
               [consumer, assignment_id]
             )

    Wakes.get(db, wake_id)
  end

  defp session(db, key, spawned_by) do
    Org.create(db, %{
      session_key: key,
      display_name: key,
      owner_user_id: "flynn",
      origin: "user:flynn",
      spawned_by: spawned_by,
      kind: "custom",
      is_built_in: false,
      archetype: "default",
      harness: "claude",
      provider: "anthropic",
      model: Model.new("fable"),
      host: "testhost"
    })
  end
end
