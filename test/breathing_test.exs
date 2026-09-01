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
