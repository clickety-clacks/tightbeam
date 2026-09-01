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

  defp query(db, kind, id),
    do:
      Breathing.query(db, %{
        principal: {:user, "owner"},
        params: %{target_kind: kind, target_id: id}
      })
end
