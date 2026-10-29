defmodule Tightbeam.SupervisionTest do
  use Tightbeam.TestCase, async: false

  alias Tightbeam.{DB, Gateway, HarnessHealth, Ledger, Org, Supervision, Wakes}
  alias Tightbeam.Model
  alias Tightbeam.DB.Txn

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

  test "a due deadline sends one ordinary notice and keeps reminders with the holder", ctx do
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
    assert notice.session_key == ctx.holder.session_key
    assert notice.prompt == prompt

    next_climb = pending_climb!(ctx.db, "asg_inactive")
    assert next_climb.wake_id != climb.wake_id

    assert {:ok, [[1]]} =
             DB.query(
               ctx.db,
               "SELECT COUNT(*) FROM wakes WHERE assignmentId='asg_inactive' " <>
                 "AND consumer='prompt' AND obligationRef=?1 AND state='pending' " <>
                 "AND sessionKey=?2",
               [episode_ref, ctx.holder.session_key]
             )

    assert {:ok, [[0]]} =
             DB.query(
               ctx.db,
               "SELECT COUNT(*) FROM wakes WHERE assignmentId='asg_inactive' " <>
                 "AND consumer='prompt' AND obligationRef=?1 AND state='pending' " <>
                 "AND sessionKey<>?2",
               [episode_ref, ctx.holder.session_key]
             )
  end

  test "two holder notices climb through the parent to the owner and then stop", ctx do
    opened_at = System.system_time(:millisecond) - 10_000
    interval_ms = 1_000

    assert {:ok, _} =
             DB.query(ctx.db, "UPDATE assignments SET openedAt=?1 WHERE id='asg_inactive'", [
               opened_at
             ])

    open_deadline!(ctx.db, "asg_inactive", opened_at, interval_ms)
    assert {:ok, :ok} = Supervision.deadline(ctx.db, pending_deadline!(ctx.db, "asg_inactive"))

    first = episode_notices(ctx.db) |> List.first()
    assert first.session_key == ctx.holder.session_key
    assert first.prompt =~ "blocker or decision request"

    assert {:ok, _} =
             DB.query(ctx.db, "UPDATE wakes SET state='fired',firedAt=?2 WHERE wakeId=?1", [
               first.wake_id,
               System.system_time(:millisecond)
             ])

    fire_due_climb!(ctx.db, first.wake_id, interval_ms)
    [first_after, second] = episode_notices(ctx.db)
    assert first_after.wake_id == first.wake_id
    assert second.session_key == ctx.holder.session_key
    assert second.prompt == first.prompt

    fire_due_climb!(ctx.db, second.wake_id, interval_ms)
    assert length(episode_notices(ctx.db)) == 2
    assert Wakes.get(ctx.db, second.wake_id).session_key == ctx.parent.session_key
    assert Wakes.get(ctx.db, second.wake_id).prompt == first.prompt

    assert :ok = Supervision.migrate_open_assignments(ctx.db, interval_ms)
    assert Wakes.get(ctx.db, second.wake_id).state == "pending"
    assert Wakes.get(ctx.db, second.wake_id).session_key == ctx.parent.session_key

    fire_due_climb!(ctx.db, second.wake_id, interval_ms)
    assert Wakes.get(ctx.db, second.wake_id).session_key == ctx.main.session_key

    fire_due_climb!(ctx.db, second.wake_id, interval_ms)
    assert length(episode_notices(ctx.db)) == 2

    assert {:ok, [[0]]} =
             DB.query(
               ctx.db,
               "SELECT COUNT(*) FROM wakes WHERE assignmentId='asg_inactive' AND consumer='assignment_inactivity_climb' AND state='pending'"
             )
  end

  test "a pending holder notice gets a second interval before climbing without a duplicate",
       ctx do
    opened_at = System.system_time(:millisecond) - 10_000
    interval_ms = 1_000

    assert {:ok, _} =
             DB.query(ctx.db, "UPDATE assignments SET openedAt=?1 WHERE id='asg_inactive'", [
               opened_at
             ])

    open_deadline!(ctx.db, "asg_inactive", opened_at, interval_ms)
    assert {:ok, :ok} = Supervision.deadline(ctx.db, pending_deadline!(ctx.db, "asg_inactive"))
    first = episode_notices(ctx.db) |> List.first()

    fire_due_climb!(ctx.db, first.wake_id, interval_ms)
    assert length(episode_notices(ctx.db)) == 1
    assert Wakes.get(ctx.db, first.wake_id).session_key == ctx.holder.session_key

    fire_due_climb!(ctx.db, first.wake_id, interval_ms)
    assert length(episode_notices(ctx.db)) == 1
    assert Wakes.get(ctx.db, first.wake_id).session_key == ctx.parent.session_key
  end

  test "boot reconciliation replaces stored intervals with the configured default", ctx do
    now = System.system_time(:millisecond)
    opened_at = now - 29 * 60 * 1_000

    assert {:ok, _} =
             DB.query(ctx.db, "UPDATE assignments SET openedAt=?2 WHERE id=?1", [
               "asg_inactive",
               opened_at
             ])

    open_deadline!(ctx.db, "asg_inactive", opened_at, 1_000)
    stale = pending_deadline!(ctx.db, "asg_inactive")

    assert :ok = Supervision.migrate_open_assignments(ctx.db)

    deadline = pending_deadline!(ctx.db, "asg_inactive")
    assert deadline.wake_id != stale.wake_id
    assert deadline.due_at == opened_at + 1_800_000
    assert Wakes.get(ctx.db, stale.wake_id).state == "canceled"
    assert {:ok, %{"intervalMs" => 1_800_000}} = JSON.decode(deadline.prompt)

    assert {:ok, [[0]]} =
             DB.query(
               ctx.db,
               "SELECT COUNT(*) FROM wakes WHERE assignmentId='asg_inactive' " <>
                 "AND consumer='prompt' AND obligationRef LIKE 'assignment-inactivity-episode-v1:%'"
             )

    opened_at = System.system_time(:millisecond) - 1_800_001

    assert {:ok, _} =
             DB.query(ctx.db, "UPDATE assignments SET openedAt=?2 WHERE id=?1", [
               "asg_inactive",
               opened_at
             ])

    assert :ok = Supervision.migrate_open_assignments(ctx.db)
    deadline = pending_deadline!(ctx.db, "asg_inactive")
    assert deadline.due_at <= System.system_time(:millisecond)
    assert {:ok, :ok} = Supervision.deadline(ctx.db, deadline)

    assert {:ok, [[holder]]} =
             DB.query(
               ctx.db,
               "SELECT sessionKey FROM wakes WHERE assignmentId='asg_inactive' " <>
                 "AND consumer='prompt' AND obligationRef LIKE 'assignment-inactivity-episode-v1:%' " <>
                 "AND state='pending'",
               []
             )

    assert holder == ctx.holder.session_key
  end

  test "boot reconciliation ignores a stored one-second entitlement", ctx do
    opened_at = System.system_time(:millisecond) - 29 * 60_000

    assert {:ok, _} =
             DB.query(ctx.db, "UPDATE assignments SET openedAt=?2 WHERE id=?1", [
               "asg_inactive",
               opened_at
             ])

    assert {:ok, _} =
             DB.query(
               ctx.db,
               """
               INSERT INTO supervision_entitlements
                 (assignmentId,generation,dueAt,state,basisKind,basisId,cause,principal,supervisionIntervalMs)
               VALUES ('asg_inactive',1,?1,'armed','assignment_open','asg_inactive',
                 'assignment_open','process:tightbeam',1000)
               """,
               [opened_at + 1_000]
             )

    assert :ok = Supervision.migrate_open_assignments(ctx.db)
    deadline = pending_deadline!(ctx.db, "asg_inactive")
    assert deadline.due_at == opened_at + 1_800_000
    assert {:ok, %{"intervalMs" => 1_800_000}} = JSON.decode(deadline.prompt)
    assert deadline.due_at > System.system_time(:millisecond)
  end

  test "off reminders retract prompts and leave one silent deadline", ctx do
    prior_interval = Application.get_env(:tightbeam, :supervision_interval_ms)

    on_exit(fn ->
      if is_nil(prior_interval),
        do: Application.delete_env(:tightbeam, :supervision_interval_ms),
        else: Application.put_env(:tightbeam, :supervision_interval_ms, prior_interval)
    end)

    opened_at = System.system_time(:millisecond) - 5_000

    assert {:ok, _} =
             DB.query(ctx.db, "UPDATE assignments SET openedAt=?2 WHERE id=?1", [
               "asg_inactive",
               opened_at
             ])

    open_deadline!(ctx.db, "asg_inactive", opened_at, 1_000)
    assert {:ok, :ok} = Supervision.deadline(ctx.db, pending_deadline!(ctx.db, "asg_inactive"))

    reminder =
      Enum.find(Wakes.list_pending(ctx.db), fn wake ->
        wake.consumer == "prompt" and wake.assignment_id == "asg_inactive" and
          String.starts_with?(wake.obligation_ref || "", "assignment-inactivity-episode-v1:")
      end)

    assert is_map(reminder)
    old_climb = pending_climb!(ctx.db, "asg_inactive")
    Application.put_env(:tightbeam, :supervision_interval_ms, :off)

    assert :ok = Supervision.migrate_open_assignments(ctx.db, :off)
    assert Wakes.get(ctx.db, reminder.wake_id).state == "canceled"
    new_deadline = pending_deadline!(ctx.db, "asg_inactive")
    assert Wakes.get(ctx.db, old_climb.wake_id).state == "canceled"
    refute old_climb.wake_id == new_deadline.wake_id

    assert {:ok, [[0]]} =
             DB.query(
               ctx.db,
               "SELECT COUNT(*) FROM wakes WHERE assignmentId='asg_inactive' " <>
                 "AND state='pending' AND consumer='assignment_inactivity_climb'"
             )

    assert {:ok, [[0]]} =
             DB.query(
               ctx.db,
               "SELECT COUNT(*) FROM wakes WHERE assignmentId='asg_inactive' " <>
                 "AND state='pending' AND consumer='prompt' " <>
                 "AND obligationRef LIKE 'assignment-inactivity-episode-v1:%'"
             )

    assert {:ok, _} =
             DB.query(ctx.db, "UPDATE wakes SET dueAt=0 WHERE wakeId=?1 AND state='pending'", [
               new_deadline.wake_id
             ])

    assert {:ok, true} = Supervision.deadline(ctx.db, Wakes.get(ctx.db, new_deadline.wake_id))

    assert {:ok, [[0]]} =
             DB.query(
               ctx.db,
               "SELECT COUNT(*) FROM wakes WHERE assignmentId='asg_inactive' " <>
                 "AND state='pending' AND consumer='prompt' " <>
                 "AND obligationRef LIKE 'assignment-inactivity-episode-v1:%'"
             )
  end

  test "startup restores the climb and cancels notices outside its visited route", ctx do
    opened_at = System.system_time(:millisecond) - 5_000

    assert {:ok, _} =
             DB.query(ctx.db, "UPDATE assignments SET openedAt=?2 WHERE id=?1", [
               "asg_inactive",
               opened_at
             ])

    open_deadline!(ctx.db, "asg_inactive", opened_at, 1_000)
    assert {:ok, :ok} = Supervision.deadline(ctx.db, pending_deadline!(ctx.db, "asg_inactive"))

    holder_notice =
      Enum.find(Wakes.list_pending(ctx.db), fn wake ->
        wake.consumer == "prompt" and wake.assignment_id == "asg_inactive" and
          String.starts_with?(wake.obligation_ref || "", "assignment-inactivity-episode-v1:")
      end)

    assert is_map(holder_notice)
    old_climb = pending_climb!(ctx.db, "asg_inactive")

    wrong_holder_notice =
      Wakes.schedule(ctx.db, %{
        session_key: ctx.parent.session_key,
        assignment_id: "asg_inactive",
        origin: "process:supervision-test",
        prompt: "stale reminder for an ancestor",
        due_at: System.system_time(:millisecond) + 60_000,
        obligation_ref: holder_notice.obligation_ref
      })

    assert :ok = Supervision.migrate_open_assignments(ctx.db, 1_000)

    assert Wakes.get(ctx.db, old_climb.wake_id).state == "canceled"
    assert Wakes.get(ctx.db, wrong_holder_notice.wake_id).state == "canceled"
    assert Wakes.get(ctx.db, holder_notice.wake_id).state == "pending"
    assert Wakes.get(ctx.db, holder_notice.wake_id).session_key == ctx.holder.session_key

    replacement = pending_climb!(ctx.db, "asg_inactive")
    refute replacement.wake_id == old_climb.wake_id
    assert {:ok, %{"intervalMs" => 1_000, "rung" => 1}} = JSON.decode(replacement.prompt)
  end

  test "startup upgrades an active one-second climb to the configured quiet interval", ctx do
    opened_at = System.system_time(:millisecond) - 10_000

    assert {:ok, _} =
             DB.query(ctx.db, "UPDATE assignments SET openedAt=?1 WHERE id='asg_inactive'", [
               opened_at
             ])

    open_deadline!(ctx.db, "asg_inactive", opened_at, 1_000)
    assert {:ok, :ok} = Supervision.deadline(ctx.db, pending_deadline!(ctx.db, "asg_inactive"))
    first = episode_notices(ctx.db) |> List.first()
    old_climb = pending_climb!(ctx.db, "asg_inactive")

    assert :ok = Supervision.migrate_open_assignments(ctx.db)

    upgraded = pending_climb!(ctx.db, "asg_inactive")
    assert upgraded.wake_id != old_climb.wake_id
    assert Wakes.get(ctx.db, old_climb.wake_id).state == "canceled"
    assert Wakes.get(ctx.db, first.wake_id).state == "pending"
    assert upgraded.due_at == first.created_at + 1_800_000
    assert {:ok, %{"intervalMs" => 1_800_000, "rung" => 1}} = JSON.decode(upgraded.prompt)

    assert {:ok, [[0]]} =
             DB.query(
               ctx.db,
               "SELECT COUNT(*) FROM wakes WHERE assignmentId='asg_inactive' AND consumer='assignment_inactivity_deadline' AND state='pending'"
             )
  end

  test "a pending assignment-linked wake from another session suppresses reminders", ctx do
    opened_at = System.system_time(:millisecond) - 5_000
    open_deadline!(ctx.db, "asg_inactive", opened_at, 1_000)

    follow_up =
      Wakes.schedule(ctx.db, %{
        session_key: ctx.holder.session_key,
        creator_session_key: ctx.parent.session_key,
        assignment_id: "asg_inactive",
        origin: "session:#{ctx.parent.session_key}",
        prompt: "finish the scheduled follow-up",
        due_at: System.system_time(:millisecond) + 60_000
      })

    deadline = pending_deadline!(ctx.db, "asg_inactive")

    assert {:ok, _} =
             DB.query(ctx.db, "UPDATE wakes SET dueAt=0 WHERE wakeId=?1", [deadline.wake_id])

    assert {:ok, :ok} = Supervision.deadline(ctx.db, Wakes.get(ctx.db, deadline.wake_id))

    assert Wakes.get(ctx.db, follow_up.wake_id).state == "pending"

    assert {:ok, [[0]]} =
             DB.query(
               ctx.db,
               "SELECT COUNT(*) FROM wakes WHERE assignmentId='asg_inactive' " <>
                 "AND consumer='prompt' AND obligationRef LIKE 'assignment-inactivity-episode-v1:%'"
             )
  end

  test "a model-unavailable incident suppresses holder reminders", ctx do
    opened_at = System.system_time(:millisecond) - 5_000
    open_deadline!(ctx.db, "asg_inactive", opened_at, 1_000)

    assert {:opened, _incident} =
             HarnessHealth.observe(ctx.db, %{
               correlation_id: "supervision-holder-unavailable",
               harness: ctx.holder.harness,
               host: ctx.holder.host,
               failure_class: "model_unavailable",
               evidence_kind: "authoritative-provider",
               session_key: ctx.holder.session_key,
               assignment_id: nil,
               observed_at: System.system_time(:millisecond),
               cause: "model unavailable",
               principal: "process:tightbeam"
             })

    deadline = pending_deadline!(ctx.db, "asg_inactive")

    assert {:ok, _} =
             DB.query(ctx.db, "UPDATE wakes SET dueAt=0 WHERE wakeId=?1", [deadline.wake_id])

    assert {:ok, :ok} = Supervision.deadline(ctx.db, Wakes.get(ctx.db, deadline.wake_id))

    assert {:ok, [[0]]} =
             DB.query(
               ctx.db,
               "SELECT COUNT(*) FROM wakes WHERE assignmentId='asg_inactive' " <>
                 "AND consumer='prompt' AND obligationRef LIKE 'assignment-inactivity-episode-v1:%'"
             )
  end

  test "an open holder harness incident pauses an active reminder climb", ctx do
    opened_at = System.system_time(:millisecond) - 5_000

    assert {:ok, _} =
             DB.query(ctx.db, "UPDATE assignments SET openedAt=?1 WHERE id='asg_inactive'", [
               opened_at
             ])

    open_deadline!(ctx.db, "asg_inactive", opened_at, 1_000)
    assert {:ok, :ok} = Supervision.deadline(ctx.db, pending_deadline!(ctx.db, "asg_inactive"))
    first = episode_notices(ctx.db) |> List.first()

    assert {:opened, _incident} =
             HarnessHealth.observe(ctx.db, %{
               correlation_id: "supervision-climb-holder-unavailable",
               harness: ctx.holder.harness,
               host: ctx.holder.host,
               failure_class: "model_unavailable",
               evidence_kind: "authoritative-provider",
               session_key: ctx.holder.session_key,
               assignment_id: nil,
               observed_at: System.system_time(:millisecond),
               cause: "model unavailable",
               principal: "process:tightbeam"
             })

    fire_due_climb!(ctx.db, first.wake_id, 1_000)
    assert length(episode_notices(ctx.db)) == 1
    assert Wakes.get(ctx.db, first.wake_id).session_key == ctx.holder.session_key
    assert pending_climb!(ctx.db, "asg_inactive").due_at > System.system_time(:millisecond)
  end

  test "an inactive holder suppresses inactivity reminders", ctx do
    opened_at = System.system_time(:millisecond) - 5_000
    open_deadline!(ctx.db, "asg_inactive", opened_at, 1_000)

    assert {:ok, _} =
             DB.query(ctx.db, "UPDATE sessions SET state='retired' WHERE sessionKey=?1", [
               ctx.holder.session_key
             ])

    deadline = pending_deadline!(ctx.db, "asg_inactive")

    assert {:ok, _} =
             DB.query(ctx.db, "UPDATE wakes SET dueAt=0 WHERE wakeId=?1", [deadline.wake_id])

    assert {:ok, :ok} = Supervision.deadline(ctx.db, Wakes.get(ctx.db, deadline.wake_id))

    assert {:ok, [[0]]} =
             DB.query(
               ctx.db,
               "SELECT COUNT(*) FROM wakes WHERE assignmentId='asg_inactive' " <>
                 "AND consumer='prompt' AND obligationRef LIKE 'assignment-inactivity-episode-v1:%'"
             )

    assert pending_deadline!(ctx.db, "asg_inactive").due_at > System.system_time(:millisecond)
  end

  test "a queued turn for another assignment suppresses inactivity reminders", ctx do
    opened_at = System.system_time(:millisecond) - 5_000

    assert {:ok, _} =
             DB.query(
               ctx.db,
               "INSERT INTO assignments (id,subject,holderKey,openedByUser,openedAt,state) " <>
                 "VALUES ('asg_queued_turn','other work',?1,'flynn',?2,'open')",
               [ctx.holder.session_key, opened_at]
             )

    assert {:ok, _seq} =
             Ledger.enqueue(ctx.db, %{
               session_key: ctx.holder.session_key,
               message_id: "queued-session-turn",
               origin: "process:supervision-test",
               prompt: "work on a different assignment",
               assignment_id: "asg_queued_turn"
             })

    open_deadline!(ctx.db, "asg_inactive", opened_at, 1_000)
    deadline = pending_deadline!(ctx.db, "asg_inactive")

    assert {:ok, _} =
             DB.query(ctx.db, "UPDATE wakes SET dueAt=0 WHERE wakeId=?1", [deadline.wake_id])

    assert {:ok, :ok} = Supervision.deadline(ctx.db, Wakes.get(ctx.db, deadline.wake_id))

    assert {:ok, [["queued"]]} =
             DB.query(
               ctx.db,
               "SELECT status FROM turns WHERE sessionKey=?1 AND assignmentId='asg_queued_turn'",
               [ctx.holder.session_key]
             )

    assert {:ok, [[0]]} =
             DB.query(
               ctx.db,
               "SELECT COUNT(*) FROM wakes WHERE assignmentId='asg_inactive' " <>
                 "AND consumer='prompt' AND obligationRef LIKE 'assignment-inactivity-episode-v1:%'"
             )
  end

  test "a resolved model-unavailable incident starts a full quiet interval", ctx do
    opened_at = System.system_time(:millisecond) - 5_000
    open_deadline!(ctx.db, "asg_inactive", opened_at, 1_000)

    assert {:opened, incident} =
             HarnessHealth.observe(ctx.db, %{
               correlation_id: "supervision-holder-unavailable-resolved",
               harness: ctx.holder.harness,
               host: ctx.holder.host,
               failure_class: "model_unavailable",
               evidence_kind: "authoritative-provider",
               session_key: ctx.holder.session_key,
               assignment_id: nil,
               observed_at: System.system_time(:millisecond),
               cause: "model unavailable",
               principal: "process:tightbeam"
             })

    due = pending_deadline!(ctx.db, "asg_inactive")
    assert {:ok, _} = DB.query(ctx.db, "UPDATE wakes SET dueAt=0 WHERE wakeId=?1", [due.wake_id])
    assert {:ok, :ok} = Supervision.deadline(ctx.db, Wakes.get(ctx.db, due.wake_id))

    resolution_at = System.system_time(:millisecond)

    assert {:resolved, %{id: incident_id, resolvedAt: ^resolution_at}} =
             HarnessHealth.resolve(ctx.db, %{
               correlation_id: "supervision-holder-model-restored",
               harness: ctx.holder.harness,
               host: ctx.holder.host,
               failure_class: "model_unavailable",
               session_key: ctx.holder.session_key,
               assignment_id: nil,
               observed_at: resolution_at,
               cause: "model restored",
               principal: "process:tightbeam"
             })

    assert incident_id == incident.id

    due = pending_deadline!(ctx.db, "asg_inactive")
    assert {:ok, _} = DB.query(ctx.db, "UPDATE wakes SET dueAt=0 WHERE wakeId=?1", [due.wake_id])
    assert {:ok, :ok} = Supervision.deadline(ctx.db, Wakes.get(ctx.db, due.wake_id))

    rescheduled = pending_deadline!(ctx.db, "asg_inactive")

    assert {:ok, %{"activityAt" => ^resolution_at, "intervalMs" => 1_000}} =
             JSON.decode(rescheduled.prompt)

    assert rescheduled.due_at >= resolution_at + 1_000

    assert {:ok, [[0]]} =
             DB.query(
               ctx.db,
               "SELECT COUNT(*) FROM wakes WHERE assignmentId='asg_inactive' " <>
                 "AND consumer='prompt' AND obligationRef LIKE 'assignment-inactivity-episode-v1:%'"
             )
  end

  test "a running turn for a different assignment suppresses inactivity reminders", ctx do
    opened_at = System.system_time(:millisecond) - 5_000

    assert {:ok, _} =
             DB.query(
               ctx.db,
               "INSERT INTO assignments (id,subject,holderKey,openedByUser,openedAt,state) " <>
                 "VALUES ('asg_busy_turn','other work',?1,'flynn',?2,'open')",
               [ctx.holder.session_key, opened_at]
             )

    assert {:ok, _seq} =
             Ledger.enqueue(ctx.db, %{
               session_key: ctx.holder.session_key,
               message_id: "busy-session-turn",
               origin: "process:supervision-test",
               prompt: "work on a different assignment",
               assignment_id: "asg_busy_turn"
             })

    assert {:ok, %{seq: _seq}} =
             Ledger.claim_next(ctx.db, ctx.holder.session_key, "supervision-running-turn")

    open_deadline!(ctx.db, "asg_inactive", opened_at, 1_000)
    deadline = pending_deadline!(ctx.db, "asg_inactive")

    assert {:ok, _} =
             DB.query(ctx.db, "UPDATE wakes SET dueAt=0 WHERE wakeId=?1", [deadline.wake_id])

    assert {:ok, :ok} = Supervision.deadline(ctx.db, Wakes.get(ctx.db, deadline.wake_id))

    assert {:ok, [["running"]]} =
             DB.query(
               ctx.db,
               "SELECT status FROM turns WHERE sessionKey=?1 AND assignmentId='asg_busy_turn'",
               [ctx.holder.session_key]
             )

    assert {:ok, [[0]]} =
             DB.query(
               ctx.db,
               "SELECT COUNT(*) FROM wakes WHERE assignmentId='asg_inactive' " <>
                 "AND consumer='prompt' AND obligationRef LIKE 'assignment-inactivity-episode-v1:%'"
             )
  end

  test "startup resumes historical holder reminders by climbing without a fourth", ctx do
    opened_at = System.system_time(:millisecond) - 1_800_001

    for index <- 1..3 do
      Wakes.schedule(ctx.db, %{
        session_key: ctx.holder.session_key,
        assignment_id: "asg_inactive",
        origin: "process:supervision-test",
        consumer: "prompt",
        prompt: "prior inactivity reminder #{index}",
        due_at: System.system_time(:millisecond),
        obligation_ref: "assignment-inactivity-episode-v1:prior-#{index}"
      })
    end

    assert {:ok, _} =
             DB.query(ctx.db, "UPDATE assignments SET openedAt=?2 WHERE id=?1", [
               "asg_inactive",
               opened_at
             ])

    assert :ok = Supervision.migrate_open_assignments(ctx.db)
    climb = pending_climb!(ctx.db, "asg_inactive")
    assert {:ok, %{"intervalMs" => 1_800_000, "rung" => 2}} = JSON.decode(climb.prompt)

    assert {:ok, [[3]]} =
             DB.query(
               ctx.db,
               "SELECT COUNT(*) FROM wakes WHERE assignmentId='asg_inactive' " <>
                 "AND consumer='prompt' " <>
                 "AND obligationRef LIKE 'assignment-inactivity-episode-v1:%'"
             )
  end

  test "legacy controller cleanup reconciles stored intervals on each startup", ctx do
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
    updated = pending_deadline!(ctx.db, "asg_inactive")
    assert updated.wake_id != migrated.wake_id
    assert Wakes.get(ctx.db, migrated.wake_id).state == "canceled"

    assert {:ok, [[1]]} =
             DB.query(
               ctx.db,
               "SELECT COUNT(*) FROM wakes WHERE assignmentId='asg_inactive' AND consumer='assignment_inactivity_deadline' AND state='pending'"
             )
  end

  test "a pending dated continuation defers its assignment's inactivity notice",
       ctx do
    open_deadline!(ctx.db, "asg_inactive", System.system_time(:millisecond), 1_000)
    assert :ok = Supervision.migrate_open_assignments(ctx.db)
    due_at = System.system_time(:millisecond) + 3_600_000

    wake =
      Wakes.schedule(ctx.db, %{
        session_key: ctx.holder.session_key,
        creator_session_key: ctx.holder.session_key,
        assignment_id: "asg_inactive",
        dated_continuation_assignment_id: "asg_inactive",
        origin: "session:#{ctx.holder.session_key}",
        prompt: "continue later",
        due_at: due_at,
        sender_scheduled: true
      })

    assert wake.obligation_ref == "asg_inactive"

    assert {:ok, max_due} =
             DB.transaction(ctx.db, fn txn ->
               Wakes.dated_continuation_due_in_txn(txn, "asg_inactive", wake.created_at)
             end)

    assert max_due == due_at

    deadline = pending_deadline!(ctx.db, "asg_inactive")

    assert {:ok, _} =
             DB.query(ctx.db, "UPDATE wakes SET dueAt=0 WHERE wakeId=?1", [deadline.wake_id])

    assert {:ok, :ok} = Supervision.deadline(ctx.db, Wakes.get(ctx.db, deadline.wake_id))

    assert pending_deadline!(ctx.db, "asg_inactive").due_at >=
             System.system_time(:millisecond) + 29 * 60_000

    assert {:ok, [[0]]} =
             DB.query(
               ctx.db,
               "SELECT COUNT(*) FROM wakes WHERE assignmentId='asg_inactive' AND consumer='prompt' AND obligationRef LIKE 'assignment-inactivity-episode-v1:%'"
             )

    # The due boundary ends coverage even if notification delivery has not run.
    assert {:ok, _} = DB.query(ctx.db, "UPDATE wakes SET dueAt=0 WHERE wakeId=?1", [wake.wake_id])
    next_deadline = pending_deadline!(ctx.db, "asg_inactive")

    assert {:ok, _} =
             DB.query(ctx.db, "UPDATE wakes SET dueAt=0 WHERE wakeId=?1", [next_deadline.wake_id])

    assert {:ok, :ok} = Supervision.deadline(ctx.db, Wakes.get(ctx.db, next_deadline.wake_id))

    assert {:ok, [[0]]} =
             DB.query(
               ctx.db,
               "SELECT COUNT(*) FROM wakes WHERE assignmentId='asg_inactive' AND consumer='prompt' AND obligationRef LIKE 'assignment-inactivity-episode-v1:%'"
             )

    assert pending_deadline!(ctx.db, "asg_inactive").due_at >=
             System.system_time(:millisecond) + 29 * 60_000
  end

  test "cancellation and assignment disposition end dated continuation coverage", ctx do
    holder = ctx.holder.session_key
    origin = "session:#{holder}"

    schedule = fn prompt ->
      Wakes.schedule(ctx.db, %{
        session_key: holder,
        creator_session_key: holder,
        assignment_id: "asg_inactive",
        dated_continuation_assignment_id: "asg_inactive",
        origin: origin,
        prompt: prompt,
        due_at: System.system_time(:millisecond) + 60_000,
        sender_scheduled: true
      })
    end

    covered = fn ->
      DB.transaction(ctx.db, fn txn ->
        Wakes.dated_continuation_due_in_txn(txn, "asg_inactive", System.system_time(:millisecond))
      end)
    end

    first = schedule.("resume once")
    assert {:ok, due_at} = covered.()
    assert due_at == first.due_at

    command = %{
      wake_id: first.wake_id,
      expected_origin: origin,
      requester: %{kind: "session", id: holder},
      reason_kind: "requester_withdrew",
      causal_source: %{
        kind: "verb_call",
        accepted_event: %{origin: origin, session_key: holder, principal: {:session, holder}}
      },
      outcome: %{kind: "no_replacement"}
    }

    assert {:ok, {:accepted_in_txn, _, %{canceled: true}}} =
             DB.transaction(ctx.db, fn txn ->
               {:ok, outcome} = Wakes.public_cancellation_outcome_in_txn(txn, command)
               Wakes.cancel_in_txn(txn, %{command | outcome: outcome})
             end)

    assert {:ok, nil} = covered.()

    second = schedule.("resume again")
    assert {:ok, second.due_at} == covered.()

    assert {:ok, :ok} =
             DB.transaction(ctx.db, fn txn ->
               closed_at = System.system_time(:millisecond)

               Txn.q(
                 txn,
                 "INSERT INTO attests(id,assignmentId,kind,bySession,ts) VALUES('att_dated_closed','asg_inactive','completion',?1,?2)",
                 [holder, closed_at]
               )

               Txn.q(
                 txn,
                 "UPDATE assignments SET state='closed',outcome='completed',closedAt=?1,closedBySession=?2,closingAttestId='att_dated_closed' WHERE id='asg_inactive'",
                 [closed_at, holder]
               )

               Supervision.assignment_closed_in_txn(txn, "asg_inactive")
             end)

    assert {:ok, nil} = covered.()
  end

  test "canceling a continuation restores the inactivity deadline after deferral", ctx do
    holder = ctx.holder.session_key
    origin = "agent:#{holder}"
    open_deadline!(ctx.db, "asg_inactive", System.system_time(:millisecond), 1_000)
    assert :ok = Supervision.migrate_open_assignments(ctx.db)

    schedule = fn prompt, offset ->
      Wakes.schedule(ctx.db, %{
        session_key: holder,
        creator_session_key: holder,
        assignment_id: "asg_inactive",
        dated_continuation_assignment_id: "asg_inactive",
        origin: origin,
        prompt: prompt,
        due_at: System.system_time(:millisecond) + offset,
        sender_scheduled: true
      })
    end

    cancel = fn wake ->
      command = %{
        wake_id: wake.wake_id,
        expected_origin: origin,
        requester: %{kind: "session", id: holder},
        reason_kind: "requester_withdrew",
        causal_source: %{
          kind: "verb_call",
          accepted_event: %{origin: origin, session_key: holder, principal: {:session, holder}}
        },
        outcome: %{kind: "no_replacement"}
      }

      assert {:ok, {:accepted_in_txn, _, %{canceled: true}}} =
               DB.transaction(ctx.db, fn txn ->
                 {:ok, outcome} = Wakes.public_cancellation_outcome_in_txn(txn, command)
                 Wakes.cancel_in_txn(txn, %{command | outcome: outcome})
               end)
    end

    earlier = schedule.("resume earlier", 3_600_000)
    later = schedule.("resume later", 7_200_000)
    deadline = pending_deadline!(ctx.db, "asg_inactive")

    assert {:ok, _} =
             DB.query(ctx.db, "UPDATE wakes SET dueAt=0 WHERE wakeId=?1", [deadline.wake_id])

    assert {:ok, :ok} = Supervision.deadline(ctx.db, Wakes.get(ctx.db, deadline.wake_id))

    assert pending_deadline!(ctx.db, "asg_inactive").due_at >=
             System.system_time(:millisecond) + 29 * 60_000

    cancel.(later)
    assert Wakes.get(ctx.db, later.wake_id).state == "canceled"

    assert pending_deadline!(ctx.db, "asg_inactive").due_at >=
             System.system_time(:millisecond) + 29 * 60_000

    cancel.(earlier)
    restored = pending_deadline!(ctx.db, "asg_inactive")
    assert restored.due_at < earlier.due_at
    assert restored.due_at >= System.system_time(:millisecond) + 29 * 60_000

    assert {:ok, _} =
             DB.query(ctx.db, "UPDATE wakes SET dueAt=0 WHERE wakeId=?1", [restored.wake_id])

    assert {:ok, :ok} = Supervision.deadline(ctx.db, Wakes.get(ctx.db, restored.wake_id))

    assert {:ok, [[0]]} =
             DB.query(
               ctx.db,
               "SELECT COUNT(*) FROM wakes WHERE assignmentId='asg_inactive' AND consumer='prompt' AND obligationRef LIKE 'assignment-inactivity-episode-v1:%'"
             )
  end

  test "dated continuation delivery is one notification and no work receipt", ctx do
    registry = :"dated_registry_#{System.unique_integer([:positive])}"
    lane = :"dated_lane_#{System.unique_integer([:positive])}"
    start_supervised!({Tightbeam.ConnRegistry, name: registry})
    start_supervised!({Tightbeam.NoticeBatcherFixture.LaneStub, lane})
    delivery_opts = [conn_registry: registry, lane_manager: lane]
    holder = ctx.holder.session_key

    wake =
      Wakes.schedule(ctx.db, %{
        session_key: holder,
        creator_session_key: holder,
        assignment_id: "asg_inactive",
        dated_continuation_assignment_id: "asg_inactive",
        origin: "agent:#{holder}",
        prompt: "resume at the scheduled time",
        due_at: System.system_time(:millisecond) + 60_000,
        sender_scheduled: true
      })

    assert wake.obligation_ref == "asg_inactive"
    [carrier_id] = Tightbeam.NoticeBatcher.recover(ctx.db, wake.due_at + 1, delivery_opts)
    assert Wakes.get(ctx.db, wake.wake_id).state == "fired"

    assert {:ok, [["open"]]} =
             DB.query(ctx.db, "SELECT state FROM assignments WHERE id='asg_inactive'")

    assert {:ok, [[0]]} =
             DB.query(ctx.db, "SELECT COUNT(*) FROM attests WHERE assignmentId='asg_inactive'")

    assert {:ok, [[1]]} =
             DB.query(ctx.db, "SELECT COUNT(*) FROM turns WHERE wakeId=?1", [carrier_id])

    assert [] == Tightbeam.NoticeBatcher.recover(ctx.db, wake.due_at + 1, delivery_opts)

    assert {:ok, [[1]]} =
             DB.query(ctx.db, "SELECT COUNT(*) FROM turns WHERE wakeId=?1", [carrier_id])

    assert {:ok, [[0]]} =
             DB.query(ctx.db, "SELECT COUNT(*) FROM attests WHERE assignmentId='asg_inactive'")
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

  test "assignment-pointer wake is excluded when its inactivity deadline is consumed", ctx do
    opened_at = System.system_time(:millisecond) - 5_000
    interval_ms = 1_000

    assert {:ok, _} =
             DB.query(ctx.db, "UPDATE assignments SET openedAt=?2 WHERE id=?1", [
               "asg_inactive",
               opened_at
             ])

    open_deadline!(ctx.db, "asg_inactive", opened_at, interval_ms)
    deadline = pending_deadline!(ctx.db, "asg_inactive")

    pointer =
      Wakes.schedule(ctx.db, %{
        session_key: ctx.holder.session_key,
        creator_session_key: ctx.holder.session_key,
        assignment_id: "asg_inactive",
        activity_assignment_id: nil,
        origin: "session:#{ctx.holder.session_key}",
        prompt: "The assignment is ready for review",
        due_at: System.system_time(:millisecond)
      })

    deadline_id = deadline.wake_id
    deadline_due_at = deadline.due_at

    assert {:ok, [[^deadline_id, ^deadline_due_at]]} =
             DB.query(
               ctx.db,
               "SELECT wakeId,dueAt FROM wakes WHERE assignmentId=?1 " <>
                 "AND consumer='assignment_inactivity_deadline' AND state='pending'",
               ["asg_inactive"]
             )

    assert {:ok, [[1]]} =
             DB.query(ctx.db, "SELECT COUNT(*) FROM wake_activity_exclusions WHERE wakeId=?1", [
               pointer.wake_id
             ])

    assert {:ok, _} =
             DB.query(ctx.db, "UPDATE wakes SET dueAt=0 WHERE wakeId=?1", [deadline.wake_id])

    assert {:ok, :ok} = Supervision.deadline(ctx.db, Wakes.get(ctx.db, deadline.wake_id))
    assert Wakes.get(ctx.db, deadline.wake_id).state == "fired"
    assert Wakes.get(ctx.db, pointer.wake_id).state == "pending"

    # A pending follow-up suppresses a reminder, but it is not work activity.
    # The replacement retains the original activity timestamp rather than
    # treating the conversational assignment pointer as a new receipt.
    replacement = pending_deadline!(ctx.db, "asg_inactive")
    assert replacement.wake_id != deadline.wake_id
    assert replacement.due_at > pointer.created_at
    assert %{"activityAt" => ^opened_at} = JSON.decode!(replacement.prompt)

    assert {:ok, [[0]]} =
             DB.query(
               ctx.db,
               "SELECT COUNT(*) FROM wakes WHERE assignmentId=?1 " <>
                 "AND consumer='prompt' AND obligationRef LIKE 'assignment-inactivity-episode-v1:%'",
               ["asg_inactive"]
             )
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
               INSERT INTO wakes
                 (wakeId,sessionKey,origin,consumer,dueAt,state,createdAt,assignmentId,
                  obligationRef,deliveredTurnSeq)
               SELECT 'historical-deadline-' || printf('%08d',value),
                      ?1,'process:tightbeam','assignment_inactivity_deadline',value,'fired',value,?2,
                      'unrelated-history:' || printf('%08d',value),1
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
               "EXPLAIN QUERY PLAN SELECT prompt FROM wakes WHERE assignmentId=?1 AND consumer=?2 ORDER BY rowid DESC LIMIT 1",
               ["asg_inactive", "assignment_inactivity_deadline"]
             )

    assert Enum.any?(deadline_plan, fn [_, _, _, detail] ->
             String.contains?(detail, "wakes_assignment")
           end)

    refute Enum.any?(deadline_plan, fn [_, _, _, detail] ->
             String.contains?(detail, "TEMP B-TREE")
           end)

    assert {:ok, pending_deadline_plan} =
             DB.query(
               ctx.db,
               "EXPLAIN QUERY PLAN SELECT wakeId FROM wakes INDEXED BY wakes_assignment " <>
                 "WHERE assignmentId=?1 AND consumer=?2 AND state='pending' " <>
                 "ORDER BY rowid DESC LIMIT 1",
               ["asg_inactive", "assignment_inactivity_deadline"]
             )

    assert Enum.any?(pending_deadline_plan, fn [_, _, _, detail] ->
             String.contains?(detail, "wakes_assignment (assignmentId=?)")
           end)

    refute Enum.any?(pending_deadline_plan, fn [_, _, _, detail] ->
             String.contains?(detail, "TEMP B-TREE")
           end)

    assert {:ok, reopen_plan} =
             DB.query(
               ctx.db,
               "EXPLAIN QUERY PLAN SELECT MAX(ts) FROM assignment_reopenings WHERE assignmentId=?1",
               ["asg_inactive"]
             )

    assert Enum.any?(reopen_plan, fn [_, _, _, detail] ->
             String.contains?(detail, "assignment_reopenings_assignment")
           end)

    direct_wake_id = "delivery-history-target"

    assert {:ok, []} =
             DB.query(
               ctx.db,
               """
               INSERT INTO wakes
                 (wakeId,sessionKey,origin,consumer,prompt,dueAt,state,createdAt,obligationRef,deliveredTurnSeq)
               VALUES (?1,?2,'process:tightbeam','prompt','synthetic terminal child notice',1,'fired',1,
                       'terminal-child-owner-notification:synthetic',1)
               """,
               [direct_wake_id, ctx.holder.session_key]
             )

    {delivery_sql, delivery_params} =
      Wakes.source_reconciliation_query({:delivery, ctx.holder.session_key, direct_wake_id})

    assert {:ok, delivery_rows} = DB.query(ctx.db, delivery_sql, delivery_params)
    assert Enum.map(delivery_rows, &Enum.at(&1, 1)) == [direct_wake_id]

    assert {:ok, delivery_plan} =
             DB.query(ctx.db, "EXPLAIN QUERY PLAN " <> delivery_sql, delivery_params)

    assert Enum.any?(delivery_plan, fn [_, _, _, detail] ->
             String.contains?(detail, "SEARCH wakes") and String.contains?(detail, "wakeId=?")
           end)

    refute Enum.any?(delivery_plan, fn [_, _, _, detail] ->
             String.contains?(detail, "SCAN wakes")
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
             detail =~ "SEARCH attests" and detail =~ "bySession=?"
           end)

    refute Enum.any?(terminal_action_plan, fn [_, _, _, detail] ->
             String.contains?(detail, "SCAN attests")
           end)

    assert {:ok, reminder_plan} =
             DB.query(
               ctx.db,
               "EXPLAIN QUERY PLAN SELECT wakeId FROM wakes " <>
                 "INDEXED BY idle_cleanup_wakes_pending_session " <>
                 "WHERE state='pending' AND consumer='prompt' AND sessionKey=?1 " <>
                 "AND obligationRef>=?2 AND obligationRef<?3 ORDER BY rowid",
               [
                 ctx.main.session_key,
                 "terminal-child-owner-action-reminder:",
                 "terminal-child-owner-action-reminder;"
               ]
             )

    assert Enum.any?(reminder_plan, fn [_, _, _, detail] ->
             String.contains?(detail, "idle_cleanup_wakes_pending_session (sessionKey=?)")
           end)
  end

  test "a running holder turn suppresses climb retries without notifying an ancestor", ctx do
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

    assert {:ok, %{seq: ^delivered_turn_seq}} =
             Ledger.claim_next(ctx.db, ctx.holder.session_key, "supervision-notice-turn")

    climb = pending_climb!(ctx.db, "asg_inactive")

    assert is_map(climb)

    assert {:ok, _} =
             DB.query(ctx.db, "UPDATE wakes SET dueAt=0 WHERE wakeId=?1 AND state='pending'", [
               climb.wake_id
             ])

    assert {:ok, :ok} = Supervision.climb(ctx.db, Wakes.get(ctx.db, climb.wake_id))

    assert {:ok, [["fired", ^delivered_turn_seq, holder, episode_ref]]} =
             DB.query(
               ctx.db,
               "SELECT state,deliveredTurnSeq,sessionKey,obligationRef FROM wakes WHERE wakeId=?1",
               [notice.wake_id]
             )

    assert holder == ctx.holder.session_key

    assert {:ok, [[1]]} =
             DB.query(
               ctx.db,
               "SELECT COUNT(*) FROM wakes WHERE assignmentId='asg_inactive' " <>
                 "AND consumer='prompt' AND obligationRef=?1",
               [episode_ref]
             )

    assert {:ok, [[0]]} =
             DB.query(
               ctx.db,
               "SELECT COUNT(*) FROM wakes WHERE assignmentId='asg_inactive' " <>
                 "AND consumer='prompt' AND obligationRef=?1 " <>
                 "AND sessionKey<>?2",
               [episode_ref, ctx.holder.session_key]
             )
  end

  test "retiring an ancestor does not readdress the holder's pending reminder", ctx do
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

    assert %{state: "retired"} = Org.retire(ctx.db, ctx.parent.session_key, "user:flynn", 1_000)

    retained = Wakes.get(ctx.db, notice.wake_id)
    assert retained.state == "pending"
    assert retained.session_key == ctx.holder.session_key
    assert retained.prompt == notice.prompt
    assert retained.obligation_ref == notice.obligation_ref

    next_climb = pending_climb!(ctx.db, "asg_inactive")

    assert {:ok, _} =
             DB.query(ctx.db, "UPDATE wakes SET dueAt=0 WHERE wakeId=?1 AND state='pending'", [
               next_climb.wake_id
             ])

    assert {:ok, :ok} = Supervision.climb(ctx.db, Wakes.get(ctx.db, next_climb.wake_id))
    assert Wakes.get(ctx.db, notice.wake_id).session_key == ctx.holder.session_key

    assert {:ok, [[1]]} =
             DB.query(
               ctx.db,
               "SELECT COUNT(*) FROM wakes WHERE assignmentId='asg_inactive' AND consumer='prompt' AND obligationRef=?1 AND state='pending'",
               [notice.obligation_ref]
             )

    assert {:ok, [[0]]} =
             DB.query(
               ctx.db,
               "SELECT COUNT(*) FROM wakes WHERE assignmentId='asg_inactive' " <>
                 "AND consumer='prompt' AND obligationRef=?1 AND state='pending' " <>
                 "AND sessionKey<>?2",
               [notice.obligation_ref, ctx.holder.session_key]
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

  test "a refused deadline or retraction write fails the assignment change that caused it",
       ctx do
    opened_at = System.system_time(:millisecond)
    interval_ms = 60_000

    refuse!(ctx.db, "BEFORE INSERT ON wakes WHEN NEW.consumer='assignment_inactivity_deadline'")

    assert {:error, _} =
             DB.transaction(ctx.db, fn txn ->
               Txn.exec(txn, "UPDATE assignments SET subject='changed' WHERE id='asg_inactive'")
               Supervision.assignment_opened_in_txn(txn, "asg_inactive", opened_at, interval_ms)
             end)

    assert subject(ctx.db) == "ship it"
    assert deadline_count(ctx.db) == 0

    assert {:error, _} =
             DB.transaction(ctx.db, fn txn ->
               Txn.exec(txn, "UPDATE assignments SET subject='changed' WHERE id='asg_inactive'")
               Supervision.activity_in_txn(txn, "asg_inactive", ctx.holder.session_key, opened_at)
             end)

    assert subject(ctx.db) == "ship it"
    assert deadline_count(ctx.db) == 0

    assert :ok = DB.execute(ctx.db, "DROP TRIGGER refuse_supervision_write")
    open_deadline!(ctx.db, "asg_inactive", opened_at, interval_ms)
    deadline = pending_deadline!(ctx.db, "asg_inactive")

    refuse!(
      ctx.db,
      "BEFORE UPDATE OF state ON wakes WHEN OLD.consumer='assignment_inactivity_deadline'"
    )

    assert {:error, _} =
             DB.transaction(ctx.db, fn txn ->
               Txn.exec(txn, "UPDATE assignments SET state='closed' WHERE id='asg_inactive'")
               Supervision.assignment_closed_in_txn(txn, "asg_inactive")
             end)

    assert {:ok, [["open"]]} =
             DB.query(ctx.db, "SELECT state FROM assignments WHERE id='asg_inactive'")

    assert pending_deadline!(ctx.db, "asg_inactive").wake_id == deadline.wake_id
  end

  defp refuse!(db, condition) do
    assert :ok =
             DB.execute(db, """
             CREATE TRIGGER refuse_supervision_write #{condition}
             BEGIN SELECT RAISE(ABORT,'supervision write refused'); END
             """)
  end

  defp subject(db) do
    {:ok, [[subject]]} = DB.query(db, "SELECT subject FROM assignments WHERE id='asg_inactive'")
    subject
  end

  defp deadline_count(db) do
    {:ok, [[count]]} =
      DB.query(
        db,
        "SELECT COUNT(*) FROM wakes WHERE assignmentId='asg_inactive' AND consumer='assignment_inactivity_deadline'"
      )

    count
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

  defp episode_notices(db) do
    assert {:ok, ids} =
             DB.query(
               db,
               "SELECT wakeId FROM wakes WHERE assignmentId='asg_inactive' AND consumer='prompt' AND obligationRef LIKE 'assignment-inactivity-episode-v1:%' ORDER BY rowid"
             )

    Enum.map(ids, fn [id] -> Wakes.get(db, id) end)
  end

  defp fire_due_climb!(db, previous_wake_id, interval_ms) do
    assert {:ok, _} =
             DB.query(db, "UPDATE wakes SET createdAt=?2 WHERE wakeId=?1", [
               previous_wake_id,
               System.system_time(:millisecond) - interval_ms - 1
             ])

    climb = pending_climb!(db, "asg_inactive")

    assert {:ok, _} =
             DB.query(db, "UPDATE wakes SET dueAt=0 WHERE wakeId=?1", [climb.wake_id])

    assert {:ok, :ok} = Supervision.climb(db, Wakes.get(db, climb.wake_id))
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
