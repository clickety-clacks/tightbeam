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

    holder = ensure_main_session(db, "owner").session_key
    %{db: db, holder: holder}
  end

  test "session uses pending wake only after its active-state gate", %{db: db, holder: holder} do
    :ok = insert_wake(db, "wake_session", holder, nil, nil, 9)

    assert %{schema: "breathing-v1", breathing: true, reason: "pending_wake"} =
             query(db, "session", holder)

    assert %{evidence: %{wake: %{"wakeId" => "wake_session", "dueAt" => 9}}} =
             query(db, "session", holder)

    :ok = DB.execute(db, "UPDATE sessions SET state = 'retired' WHERE sessionKey = '#{holder}'")

    assert %{
             breathing: false,
             reason: "session_retired",
             evidence: %{session: %{"state" => "retired"}}
           } =
             query(db, "session", holder)
  end

  test "assignment exposes the selected failed terminal turn and ignores attests", %{
    db: db,
    holder: holder
  } do
    :ok = insert_work_item(db, "wi_breathing")
    :ok = insert_assignment(db, "asg_breathing", holder, "wi_breathing", 4)
    :ok = insert_turn(db, holder, "asg_breathing", nil, "failed", 11, "usageLimitExceeded")

    assert %{breathing: false, reason: "latest_terminal_failed", evidence: %{turn: turn}} =
             query(db, "assignment", "asg_breathing")

    assert turn["status"] == "failed"
    assert turn["error"] == "usageLimitExceeded"
  end

  test "work-item orders linked living assignments by physical current path", %{
    db: db,
    holder: holder
  } do
    :ok = insert_work_item(db, "wi_lively")
    :ok = insert_assignment(db, "asg_queued", holder, "wi_lively", 2)
    :ok = insert_assignment(db, "asg_running", holder, "wi_lively", 1)
    :ok = insert_turn(db, holder, "asg_queued", nil, "queued", 10, nil)
    :ok = insert_turn(db, holder, "asg_running", nil, "running", 11, nil)

    assert %{breathing: true, reason: "open_assignment_lively", evidence: %{assignment: winner}} =
             query(db, "work-item", "wi_lively")

    assert winner.reason == "running_turn"
    assert winner.id == "asg_running"
    assert winner.openedAt == 1
  end

  test "attestation testimony never makes an otherwise idle assignment breathe", %{
    db: db,
    holder: holder
  } do
    :ok = insert_work_item(db, "wi_attest")
    :ok = insert_assignment(db, "asg_attest", holder, "wi_attest", 1)

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

    :ok = insert_work_item(db, "wi_terminal")
    :ok = insert_assignment(db, "asg_closed", holder, "wi_terminal", 1)
    :ok = insert_turn(db, holder, "asg_closed", nil, "running", 1, nil)
    :ok = DB.execute(db, "UPDATE assignments SET state = 'closed' WHERE id = 'asg_closed'")

    assert %{reason: "assignment_closed", breathing: false} =
             query(db, "assignment", "asg_closed")

    :ok = insert_assignment(db, "asg_canceled", holder, "wi_terminal", 2)
    :ok = insert_turn(db, holder, "asg_canceled", nil, "canceled", 2, nil)

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
    :ok = insert_wake(db, "wake_z", holder, nil, nil, 8)
    :ok = insert_wake(db, "wake_a", holder, nil, nil, 8)

    assert %{reason: "pending_wake", evidence: %{wake: %{"wakeId" => "wake_a"}}} =
             query(db, "session", holder)

    :ok = insert_turn(db, holder, nil, nil, "queued", 4, nil)
    :ok = insert_turn(db, holder, nil, nil, "running", 3, nil)

    assert %{reason: "running_turn", breathing: true} = query(db, "session", holder)

    :ok = DB.execute(db, "UPDATE turns SET status = 'delivered' WHERE status = 'running'")
    assert %{reason: "queued_turn", breathing: true} = query(db, "session", holder)
  end

  test "retired assignment holder and direct work-item path are physical gates", %{
    db: db,
    holder: holder
  } do
    :ok = insert_work_item(db, "wi_direct")
    :ok = insert_turn(db, holder, nil, "wi_direct", "running", 4, nil)

    assert %{reason: "running_turn", breathing: true} = query(db, "work-item", "wi_direct")

    :ok = insert_work_item(db, "wi_holder")
    :ok = insert_assignment(db, "asg_holder", holder, "wi_holder", 1)
    :ok = DB.execute(db, "UPDATE sessions SET state = 'retired' WHERE sessionKey = '#{holder}'")

    assert %{reason: "holder_retired", breathing: false} = query(db, "assignment", "asg_holder")
  end

  test "work-item reports no open and ordered non-lively linked assignments", %{
    db: db,
    holder: holder
  } do
    :ok = insert_work_item(db, "wi_empty")
    assert %{reason: "no_open_assignment", breathing: false} = query(db, "work-item", "wi_empty")

    :ok = insert_work_item(db, "wi_idle")
    :ok = insert_assignment(db, "asg_late", holder, "wi_idle", 2)
    :ok = insert_assignment(db, "asg_early", holder, "wi_idle", 1)

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

  defp insert_work_item(db, id) do
    :ok =
      DB.execute(
        db,
        "INSERT INTO work_items (id, title, ownerUserId, createdByUser, createdAt) VALUES ('#{id}', 'breathing', 'owner', 'owner', 1)"
      )
  end

  defp insert_assignment(db, id, holder, work_item_id, opened_at) do
    :ok =
      DB.execute(
        db,
        "INSERT INTO assignments (id, subject, holderKey, openedByUser, openedAt, workItemId) VALUES ('#{id}', 'breathing', '#{holder}', 'owner', #{opened_at}, '#{work_item_id}')"
      )
  end

  defp insert_turn(db, holder, assignment_id, work_item_id, status, created_at, error) do
    :ok =
      DB.execute(
        db,
        "INSERT INTO turns (sessionKey, messageId, origin, prompt, assignmentId, jobRef, status, error, createdAt) VALUES ('#{holder}', 'm#{created_at}', 'test', 'breathing', #{sql(assignment_id)}, #{sql(work_item_id)}, '#{status}', #{sql(error)}, #{created_at})"
      )
  end

  defp insert_wake(db, id, holder, assignment_id, work_item_id, due_at) do
    :ok =
      DB.execute(
        db,
        "INSERT INTO wakes (wakeId, sessionKey, origin, prompt, assignmentId, work_item_id, dueAt, createdAt) VALUES ('#{id}', '#{holder}', 'test', 'breathing', #{sql(assignment_id)}, #{sql(work_item_id)}, #{due_at}, 1)"
      )
  end

  defp sql(nil), do: "NULL"
  defp sql(value), do: "'#{value}'"
end
