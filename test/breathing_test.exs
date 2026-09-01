defmodule Tightbeam.BreathingTest do
  use Tightbeam.TestCase, async: false

  alias Tightbeam.{Breathing, DB}

  setup do
    db = :"breathing_db_#{System.unique_integer([:positive])}"
    start_supervised!({DB, path: ":memory:", name: db})
    :ok = ensure_all_schemas(db)

    {:ok, _} =
      DB.query(
        db,
        "INSERT INTO users (userId, isAdmin, creationKind, createdAt) VALUES ('owner', 0, 'admin_add', 1)"
      )

    %{db: db, holder: ensure_main_session(db, "owner").session_key}
  end

  test "session state gate beats a pending wake", %{db: db, holder: holder} do
    :ok =
      DB.execute(
        db,
        "INSERT INTO wakes (wakeId, sessionKey, origin, prompt, dueAt, createdAt) VALUES ('wake_1', '#{holder}', 'test', 'breathing', 9, 1)"
      )

    assert %{
             schema: "breathing-v1",
             breathing: true,
             reason: "pending_wake",
             evidence: %{wake: %{"wakeId" => "wake_1"}}
           } =
             query(db, "session", holder)

    :ok = DB.execute(db, "UPDATE sessions SET state = 'retired' WHERE sessionKey = '#{holder}'")

    assert %{
             breathing: false,
             reason: "session_retired",
             evidence: %{session: %{"state" => "retired"}}
           } =
             query(db, "session", holder)
  end

  test "assignment failed terminal evidence and work-item winner are deterministic", %{
    db: db,
    holder: holder
  } do
    :ok =
      DB.execute(
        db,
        "INSERT INTO work_items (id, title, ownerUserId, createdByUser, createdAt) VALUES ('wi_1', 'breathing', 'owner', 'owner', 1)"
      )

    :ok =
      DB.execute(
        db,
        "INSERT INTO assignments (id, subject, holderKey, openedByUser, openedAt, workItemId) VALUES ('asg_queued', 'breathing', '#{holder}', 'owner', 2, 'wi_1'), ('asg_running', 'breathing', '#{holder}', 'owner', 1, 'wi_1'), ('asg_failed', 'breathing', '#{holder}', 'owner', 3, 'wi_1')"
      )

    :ok =
      DB.execute(
        db,
        "INSERT INTO turns (sessionKey, messageId, origin, prompt, assignmentId, status, error, createdAt) VALUES ('#{holder}', 'm1', 'test', 'breathing', 'asg_queued', 'queued', NULL, 10), ('#{holder}', 'm2', 'test', 'breathing', 'asg_running', 'running', NULL, 11), ('#{holder}', 'm3', 'test', 'breathing', 'asg_failed', 'failed', 'usageLimitExceeded', 12)"
      )

    assert %{
             breathing: false,
             reason: "latest_terminal_failed",
             evidence: %{turn: %{"error" => "usageLimitExceeded"}}
           } =
             query(db, "assignment", "asg_failed")

    assert %{breathing: true, reason: "open_assignment_lively", evidence: %{assignment: winner}} =
             query(db, "work-item", "wi_1")

    assert winner.reason == "running_turn"
    assert winner.id == "asg_running"
    assert winner.openedAt == 1
  end

  test "attestation testimony never makes an otherwise idle assignment breathe", %{
    db: db,
    holder: holder
  } do
    :ok =
      DB.execute(
        db,
        "INSERT INTO work_items (id, title, ownerUserId, createdByUser, createdAt) VALUES ('wi_attest', 'breathing', 'owner', 'owner', 1)"
      )

    :ok =
      DB.execute(
        db,
        "INSERT INTO assignments (id, subject, holderKey, openedByUser, openedAt, workItemId) VALUES ('asg_attest', 'breathing', '#{holder}', 'owner', 1, 'wi_attest')"
      )

    :ok =
      DB.execute(
        db,
        "INSERT INTO attests (id, assignmentId, kind, bySession, ts) VALUES ('att_progress', 'asg_attest', 'progress', '#{holder}', 10), ('att_reaffirm', 'asg_attest', 'verdict', '#{holder}', 11)"
      )

    assert %{breathing: false, reason: "no_current_path"} =
             query(db, "assignment", "asg_attest")
  end

  test "all state gates and terminal reasons beat physical paths", %{db: db, holder: holder} do
    assert %{reason: "session_missing", breathing: false} = query(db, "session", "missing")
    assert %{reason: "assignment_missing", breathing: false} = query(db, "assignment", "missing")
    assert %{reason: "work_item_missing", breathing: false} = query(db, "work-item", "missing")

    :ok =
      DB.execute(
        db,
        "INSERT INTO work_items (id, title, ownerUserId, createdByUser, createdAt) VALUES ('wi_terminal', 'breathing', 'owner', 'owner', 1)"
      )

    :ok =
      DB.execute(
        db,
        "INSERT INTO assignments (id, subject, holderKey, openedByUser, openedAt, workItemId) VALUES ('asg_closed', 'breathing', '#{holder}', 'owner', 1, 'wi_terminal'), ('asg_canceled', 'breathing', '#{holder}', 'owner', 2, 'wi_terminal')"
      )

    :ok =
      DB.execute(
        db,
        "INSERT INTO turns (sessionKey, messageId, origin, prompt, assignmentId, status, createdAt) VALUES ('#{holder}', 'closed_running', 'test', 'breathing', 'asg_closed', 'running', 1), ('#{holder}', 'canceled', 'test', 'breathing', 'asg_canceled', 'canceled', 2)"
      )

    :ok = DB.execute(db, "UPDATE assignments SET state = 'closed' WHERE id = 'asg_closed'")

    assert %{reason: "assignment_closed", breathing: false} =
             query(db, "assignment", "asg_closed")

    assert %{reason: "latest_terminal_canceled", breathing: false} =
             query(db, "assignment", "asg_canceled")

    :ok = DB.execute(db, "UPDATE work_items SET state = 'closed' WHERE id = 'wi_terminal'")

    assert %{reason: "work_item_terminal", breathing: false} =
             query(db, "work-item", "wi_terminal")
  end

  test "session precedence is running, queued, then the earliest pending wake", %{
    db: db,
    holder: holder
  } do
    :ok =
      DB.execute(
        db,
        "INSERT INTO wakes (wakeId, sessionKey, origin, prompt, dueAt, createdAt) VALUES ('wake_z', '#{holder}', 'test', 'breathing', 8, 1), ('wake_a', '#{holder}', 'test', 'breathing', 8, 1)"
      )

    assert %{reason: "pending_wake", evidence: %{wake: %{"wakeId" => "wake_a"}}} =
             query(db, "session", holder)

    :ok =
      DB.execute(
        db,
        "INSERT INTO turns (sessionKey, messageId, origin, prompt, status, createdAt) VALUES ('#{holder}', 'queued', 'test', 'breathing', 'queued', 4), ('#{holder}', 'running', 'test', 'breathing', 'running', 3)"
      )

    assert %{reason: "running_turn", breathing: true} = query(db, "session", holder)

    :ok = DB.execute(db, "UPDATE turns SET status = 'delivered' WHERE status = 'running'")
    assert %{reason: "queued_turn", breathing: true} = query(db, "session", holder)
  end

  test "retired assignment holder and direct work-item path are physical gates", %{
    db: db,
    holder: holder
  } do
    :ok =
      DB.execute(
        db,
        "INSERT INTO work_items (id, title, ownerUserId, createdByUser, createdAt) VALUES ('wi_direct', 'breathing', 'owner', 'owner', 1), ('wi_holder', 'breathing', 'owner', 'owner', 1)"
      )

    :ok =
      DB.execute(
        db,
        "INSERT INTO turns (sessionKey, messageId, origin, prompt, jobRef, status, createdAt) VALUES ('#{holder}', 'direct', 'test', 'breathing', 'wi_direct', 'running', 4)"
      )

    assert %{reason: "running_turn", breathing: true} = query(db, "work-item", "wi_direct")

    :ok =
      DB.execute(
        db,
        "INSERT INTO assignments (id, subject, holderKey, openedByUser, openedAt, workItemId) VALUES ('asg_holder', 'breathing', '#{holder}', 'owner', 1, 'wi_holder')"
      )

    :ok = DB.execute(db, "UPDATE sessions SET state = 'retired' WHERE sessionKey = '#{holder}'")
    assert %{reason: "holder_retired", breathing: false} = query(db, "assignment", "asg_holder")
  end

  test "work-item reports no open and ordered non-lively linked assignments", %{
    db: db,
    holder: holder
  } do
    :ok =
      DB.execute(
        db,
        "INSERT INTO work_items (id, title, ownerUserId, createdByUser, createdAt) VALUES ('wi_empty', 'breathing', 'owner', 'owner', 1), ('wi_idle', 'breathing', 'owner', 'owner', 1)"
      )

    assert %{reason: "no_open_assignment", breathing: false} = query(db, "work-item", "wi_empty")

    :ok =
      DB.execute(
        db,
        "INSERT INTO assignments (id, subject, holderKey, openedByUser, openedAt, workItemId) VALUES ('asg_late', 'breathing', '#{holder}', 'owner', 2, 'wi_idle'), ('asg_early', 'breathing', '#{holder}', 'owner', 1, 'wi_idle')"
      )

    assert %{reason: "all_open_assignments_not_lively", evidence: %{open_assignments: entries}} =
             query(db, "work-item", "wi_idle")

    assert Enum.map(entries, & &1.id) == ["asg_early", "asg_late"]
    assert Enum.all?(entries, &(!&1.breathing && &1.reason == "no_current_path"))
  end

  test "authorization errors never return a synthetic breathing answer", %{db: db, holder: holder} do
    assert %{code: "process_denied"} =
             Breathing.query(db, %{
               principal: {:process, "gate"},
               params: %{target_kind: "session", target_id: holder}
             })

    assert %{code: "invalid_breathing_target"} =
             Breathing.query(db, %{
               principal: {:user, "owner"},
               params: %{target_kind: "turn", target_id: holder}
             })
  end

  defp query(db, kind, id),
    do:
      Breathing.query(db, %{
        principal: {:user, "owner"},
        params: %{target_kind: kind, target_id: id}
      })
end
