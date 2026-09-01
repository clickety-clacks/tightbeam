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
        "INSERT INTO attests (id, assignmentId, kind, verdictKind, note, bySession, ts) VALUES ('att_progress', 'asg_attest', 'progress', NULL, NULL, '#{holder}', 10), ('att_reaffirm', 'asg_attest', 'verdict', 'verified', 'standing reaffirmation', '#{holder}', 11)"
      )

    :ok =
      DB.execute(
        db,
        "INSERT INTO condition_facts (ts, kind, scope, origin) VALUES (12, 'patrol-response-acknowledged', 'assignment:asg_attest', 'patrol')"
      )

    assert %{breathing: false, reason: "no_current_path"} =
             query(db, "assignment", "asg_attest")
  end

  test "pending assignment continuation wake breathes through its due boundary", %{
    db: db,
    holder: holder
  } do
    due_at = 9_999_999_999_999
    :ok = insert_work_item(db, "wi_continuation")
    :ok = insert_assignment(db, "asg_continuation", holder, "wi_continuation", 1)

    :ok =
      DB.execute(
        db,
        "INSERT INTO attests (id, assignmentId, kind, note, bySession, ts) VALUES ('att_tick', 'asg_continuation', 'progress', 'semantic testimony', '#{holder}', 10)"
      )

    assert %{breathing: false, reason: "no_current_path"} =
             query(db, "assignment", "asg_continuation")

    :ok = insert_wake(db, "wake_continuation", holder, "asg_continuation", nil, due_at)

    assert %{
             breathing: true,
             reason: "pending_wake",
             evidence: %{
               wake: %{
                 "wakeId" => "wake_continuation",
                 "assignmentId" => "asg_continuation",
                 "dueAt" => ^due_at,
                 "state" => "pending"
               }
             }
           } = query(db, "assignment", "asg_continuation")

    :ok = DB.execute(db, "UPDATE wakes SET state = 'fired' WHERE wakeId = 'wake_continuation'")

    assert %{breathing: false, reason: "no_current_path"} =
             query(db, "assignment", "asg_continuation")
  end

  test "all state gates and terminal reasons beat physical paths", %{db: db, holder: holder} do
    assert %{reason: "session_missing", breathing: false} = query(db, "session", "missing")
    assert %{reason: "assignment_missing", breathing: false} = query(db, "assignment", "missing")
    assert %{reason: "work_item_missing", breathing: false} = query(db, "work-item", "missing")

    :ok = insert_work_item(db, "wi_terminal")
    :ok = insert_assignment(db, "asg_closed", holder, "wi_terminal", 1)
    :ok = insert_turn(db, holder, "asg_closed", nil, "running", 1, nil)

    :ok =
      DB.execute(
        db,
        "INSERT INTO attests (id, assignmentId, kind, bySession, ts) VALUES ('att_closed', 'asg_closed', 'completion', '#{holder}', 3)"
      )

    :ok =
      DB.execute(
        db,
        "UPDATE assignments SET state = 'closed', outcome = 'completed', closedAt = 3, closedBySession = '#{holder}', closingAttestId = 'att_closed' WHERE id = 'asg_closed'"
      )

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

  test "A16 matches the shared dual-line JSON fixture", %{db: db} do
    assert File.read!("test/fixtures/breathing-v1-parity.json") ==
             "{\"schema\":\"breathing-v1\",\"target\":{\"kind\":\"session\",\"id\":\"parity_missing\"},\"breathing\":false,\"reason\":\"session_missing\",\"evidence\":{}}\n"

    assert %{
             schema: "breathing-v1",
             target: %{kind: "session", id: "parity_missing"},
             breathing: false,
             reason: "session_missing",
             evidence: %{}
           } = query(db, "session", "parity_missing")
  end

  test "A1 through A9 select the closed session and assignment vocabulary", %{
    db: db,
    holder: holder
  } do
    assert %{
             schema: "breathing-v1",
             target: %{kind: "session", id: "missing"},
             breathing: false,
             reason: "session_missing",
             evidence: %{}
           } = query(db, "session", "missing")

    :ok = insert_turn(db, holder, nil, nil, "running", 2, nil)
    :ok = insert_turn(db, holder, nil, nil, "running", 3, nil)

    assert %{reason: "running_turn", evidence: %{turn: %{"seq" => 2}}} =
             query(db, "session", holder)

    :ok = DB.execute(db, "UPDATE turns SET status = 'delivered' WHERE status = 'running'")
    :ok = insert_turn(db, holder, nil, nil, "queued", 4, nil)
    :ok = insert_turn(db, holder, nil, nil, "queued", 5, nil)

    assert %{reason: "queued_turn", evidence: %{turn: %{"seq" => 4}}} =
             query(db, "session", holder)

    :ok = insert_wake(db, "wake_b", holder, nil, nil, 6)
    :ok = DB.execute(db, "UPDATE sessions SET state = 'retired' WHERE sessionKey = '#{holder}'")
    assert %{reason: "session_retired", breathing: false} = query(db, "session", holder)

    :ok = insert_work_item(db, "wi_a6_a9")
    :ok = insert_assignment(db, "asg_failed_a6", holder, "wi_a6_a9", 1)
    :ok = insert_assignment(db, "asg_delivered_a7", holder, "wi_a6_a9", 2)
    :ok = insert_assignment(db, "asg_closed_a8", holder, "wi_a6_a9", 3)
    :ok = insert_assignment(db, "asg_retired_a9", holder, "wi_a6_a9", 4)
    :ok = DB.execute(db, "UPDATE sessions SET state = 'active' WHERE sessionKey = '#{holder}'")
    :ok = insert_turn(db, holder, "asg_failed_a6", nil, "failed", 6, "usageLimitExceeded")
    :ok = insert_turn(db, holder, "asg_delivered_a7", nil, "delivered", 7, nil)
    :ok = insert_turn(db, holder, "asg_closed_a8", nil, "running", 8, nil)
    :ok = insert_turn(db, holder, "asg_retired_a9", nil, "delivered", 9, nil)
    :ok = insert_turn(db, holder, "asg_retired_a9", nil, "queued", 10, nil)
    :ok = insert_wake(db, "wake_a8", holder, "asg_closed_a8", nil, 1)
    :ok = insert_wake(db, "wake_a9", holder, "asg_retired_a9", nil, 1)

    :ok =
      DB.execute(
        db,
        "INSERT INTO attests (id, assignmentId, kind, bySession, ts) VALUES ('att_closed_a8', 'asg_closed_a8', 'completion', '#{holder}', 11)"
      )

    :ok =
      DB.execute(
        db,
        "UPDATE assignments SET state = 'closed', outcome = 'completed', closedAt = 11, closedBySession = '#{holder}', closingAttestId = 'att_closed_a8' WHERE id = 'asg_closed_a8'"
      )

    assert %{
             reason: "latest_terminal_failed",
             evidence: %{turn: %{"error" => "usageLimitExceeded"}}
           } =
             query(db, "assignment", "asg_failed_a6")

    assert %{reason: "no_current_path", breathing: false} =
             query(db, "assignment", "asg_delivered_a7")

    assert %{reason: "assignment_closed", breathing: false} =
             query(db, "assignment", "asg_closed_a8")

    :ok = DB.execute(db, "UPDATE sessions SET state = 'retired' WHERE sessionKey = '#{holder}'")

    assert %{reason: "holder_retired", breathing: false} =
             query(db, "assignment", "asg_retired_a9")
  end

  test "A10 through A20 compose direct, linked, excluded, and private evidence", %{
    db: db,
    holder: holder
  } do
    :ok = insert_work_item(db, "wi_direct_wake")
    :ok = insert_wake(db, "wake_direct", holder, nil, "wi_direct_wake", 1)
    assert %{reason: "pending_wake", breathing: true} = query(db, "work-item", "wi_direct_wake")

    :ok = insert_work_item(db, "wi_ordered")

    for {id, opened_at, status} <- [
          {"asg_idle", 1, nil},
          {"asg_pending", 4, :wake},
          {"asg_queued", 3, "queued"},
          {"asg_running", 2, "running"}
        ] do
      :ok = insert_assignment(db, id, holder, "wi_ordered", opened_at)

      if is_binary(status),
        do: :ok = insert_turn(db, holder, id, nil, status, opened_at + 20, nil)

      if status == :wake, do: :ok = insert_wake(db, "wake_#{id}", holder, id, nil, 20)
    end

    assert %{reason: "open_assignment_lively", evidence: %{assignment: winner}} =
             query(db, "work-item", "wi_ordered")

    assert %{id: "asg_running", reason: "running_turn"} = winner

    :ok = insert_work_item(db, "wi_all_idle")
    :ok = insert_assignment(db, "asg_same_b", holder, "wi_all_idle", 1)
    :ok = insert_assignment(db, "asg_same_a", holder, "wi_all_idle", 1)

    assert %{reason: "all_open_assignments_not_lively", evidence: %{open_assignments: idle}} =
             query(db, "work-item", "wi_all_idle")

    assert Enum.map(idle, & &1.id) == ["asg_same_a", "asg_same_b"]

    :ok = insert_work_item(db, "wi_terminal_conflict")
    :ok = insert_turn(db, holder, nil, "wi_terminal_conflict", "running", 40, nil)

    :ok =
      DB.execute(db, "UPDATE work_items SET state = 'closed' WHERE id = 'wi_terminal_conflict'")

    assert %{reason: "work_item_terminal", breathing: false} =
             query(db, "work-item", "wi_terminal_conflict")

    :ok = insert_work_item(db, "wi_excluded")
    :ok = insert_assignment(db, "asg_excluded", holder, "wi_excluded", 1)

    :ok =
      DB.execute(
        db,
        "INSERT INTO attests (id, assignmentId, kind, verdictKind, note, bySession, ts) VALUES ('att_attest', 'asg_excluded', 'progress', NULL, 'attest', '#{holder}', 1), ('att_reaffirmation', 'asg_excluded', 'verdict', 'verified', 'standing reaffirmation', '#{holder}', 2)"
      )

    :ok =
      DB.execute(
        db,
        "INSERT INTO condition_facts (ts, kind, scope, origin) VALUES (3, 'patrol-response-acknowledged', 'asg_excluded', 'test')"
      )

    assert %{reason: "no_current_path", breathing: false} =
             query(db, "assignment", "asg_excluded")

    :ok =
      DB.execute(
        db,
        "UPDATE sessions SET cliToken = 'MUST-NOT-LEAK' WHERE sessionKey = '#{holder}'"
      )

    refute inspect(query(db, "session", holder)) =~ "MUST-NOT-LEAK"
  end

  test "A13 snapshot reads, A14 restart reads, and repeated reads are stable" do
    snapshot_path =
      Path.join(System.tmp_dir!(), "breathing-snapshot-#{System.unique_integer([:positive])}.db")

    writer_db = :"breathing_writer_#{System.unique_integer([:positive])}"
    reader_db = :"breathing_reader_#{System.unique_integer([:positive])}"
    {:ok, writer_pid} = DB.start_link(path: snapshot_path, name: writer_db)
    Process.unlink(writer_pid)
    :ok = ensure_all_schemas(writer_db)

    {:ok, _} =
      DB.query(
        writer_db,
        "INSERT INTO users (userId, isAdmin, creationKind, createdAt) VALUES ('owner', 0, 'admin_add', 1)"
      )

    snapshot_holder = ensure_main_session(writer_db, "owner").session_key
    :ok = insert_work_item(writer_db, "wi_snapshot")
    :ok = insert_assignment(writer_db, "asg_snapshot", snapshot_holder, "wi_snapshot", 1)
    :ok = insert_turn(writer_db, snapshot_holder, "asg_snapshot", nil, "running", 1, nil)

    :ok =
      DB.execute(
        writer_db,
        "INSERT INTO attests (id, assignmentId, kind, bySession, ts) VALUES ('att_snapshot', 'asg_snapshot', 'completion', '#{snapshot_holder}', 2)"
      )

    {:ok, reader_pid} = DB.start_link(path: snapshot_path, name: reader_db)
    Process.unlink(reader_pid)

    writer =
      Task.async(fn ->
        DB.execute(
          writer_db,
          "UPDATE assignments SET state = 'closed', outcome = 'completed', closedAt = 2, closedBySession = '#{snapshot_holder}', closingAttestId = 'att_snapshot' WHERE id = 'asg_snapshot'"
        )
      end)

    reader = Task.async(fn -> query(reader_db, "assignment", "asg_snapshot") end)
    assert :ok = Task.await(writer)
    assert %{breathing: breathing, reason: reason} = Task.await(reader)
    assert {breathing, reason} in [{true, "running_turn"}, {false, "assignment_closed"}]

    assert %{reason: "assignment_closed", breathing: false} =
             query(reader_db, "assignment", "asg_snapshot")

    :ok = GenServer.stop(reader_pid)
    :ok = GenServer.stop(writer_pid)
    File.rm(snapshot_path)

    path =
      Path.join(System.tmp_dir!(), "breathing-restart-#{System.unique_integer([:positive])}.db")

    restart_db = :"breathing_restart_#{System.unique_integer([:positive])}"
    {:ok, restart_pid} = DB.start_link(path: path, name: restart_db)
    Process.unlink(restart_pid)
    :ok = ensure_all_schemas(restart_db)

    {:ok, _} =
      DB.query(
        restart_db,
        "INSERT INTO users (userId, isAdmin, creationKind, createdAt) VALUES ('owner', 0, 'admin_add', 1)"
      )

    restart_holder = ensure_main_session(restart_db, "owner").session_key
    :ok = insert_wake(restart_db, "wake_restart", restart_holder, nil, nil, 9)
    before = query(restart_db, "session", restart_holder)
    assert before == query(restart_db, "session", restart_holder)
    :ok = GenServer.stop(restart_pid)

    {:ok, restarted_pid} = DB.start_link(path: path, name: restart_db)
    Process.unlink(restarted_pid)
    assert before == query(restart_db, "session", restart_holder)
    :ok = GenServer.stop(restarted_pid)
    File.rm(path)
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
