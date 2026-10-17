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

    assert {:ok, :canceled} =
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
    assert Wakes.get(ctx.db, old_deadline.wake_id).state == "canceled"

    deadline = pending_deadline!(ctx.db, "asg_inactive")
    assert deadline.due_at == wake.created_at + interval_ms
    assert deadline.due_at < wake.due_at

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
