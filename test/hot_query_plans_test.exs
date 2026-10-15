defmodule Tightbeam.HotQueryPlansTest do
  use Tightbeam.TestCase, async: false

  alias Tightbeam.{DB, Ledger, Supervision}

  # Production databases carry no sqlite_stat1, so these plans are checked
  # without ANALYZE: the planner then prefers equality indexes such as
  # wakes_wait_recognition(state, ...) over the narrower partial indexes.
  setup do
    db = :"hot_query_plans_db_#{System.unique_integer([:positive])}"
    start_supervised!({DB, path: ":memory:", name: db})
    :ok = Tightbeam.Schema.ensure_all(db)
    assert {:ok, []} = DB.query(db, "SELECT name FROM sqlite_master WHERE name='sqlite_stat1'")
    %{db: db}
  end

  defp plan!(db, sql, params) do
    {:ok, rows} = DB.query(db, "EXPLAIN QUERY PLAN " <> sql, params)
    plan = Enum.map(rows, &List.last/1)
    IO.puts("plan: " <> Enum.join(plan, " | "))
    plan
  end

  test "transfer candidates use the wake assignment index", %{db: db} do
    plan = plan!(db, Supervision.transfer_candidate_sql(), ["assignment", nil])
    assert Enum.any?(plan, &String.contains?(&1, "USING INDEX wakes_assignment (assignmentId=?)"))
    refute Enum.any?(plan, &Regex.match?(~r/^SCAN (wakes|w|d)\b/, &1))
    assert {:ok, []} = DB.query(db, Supervision.transfer_candidate_sql(), ["assignment", nil])
    assert :ok = Tightbeam.Schema.ensure_all(db)
  end

  test "idle-cleanup delivery state uses its primary key", %{db: db} do
    params = Supervision.idle_cleanup_delivery_history_params(String.duplicate("a", 64), "tok")
    plan = plan!(db, Supervision.idle_cleanup_delivery_history_sql(), params)

    assert hd(plan) =~
             "SEARCH idle_cleanup_state USING INDEX sqlite_autoindex_idle_cleanup_state"

    refute Enum.any?(plan, &Regex.match?(~r/^SCAN /, &1))
    assert {:ok, []} = DB.query(db, Supervision.idle_cleanup_delivery_history_sql(), params)
  end

  test "ended scheduled controllers are read from their recorded-state index", %{db: db} do
    plan = plan!(db, Supervision.ended_controllers_sql(), [])
    assert hd(plan) =~ "supervision_liveness_ended_controller"

    assert Enum.any?(
             plan,
             &Regex.match?(~r/^SEARCH w USING (?:COVERING )?INDEX .* \(wakeId=\?/, &1)
           )

    refute Enum.any?(plan, &Regex.match?(~r/^SCAN w/, &1))
  end

  test "unpublished terminals are read from the unpublished partial index", %{db: db} do
    plan = plan!(db, Ledger.unpublished_terminals_sql(), [])
    assert Enum.any?(plan, &String.contains?(&1, "turns_unpublished"))
    refute Enum.any?(plan, &Regex.match?(~r/^SCAN turns$/, &1))

    for seq <- [3, 1, 2] do
      {:ok, _} =
        DB.query(
          db,
          """
          INSERT INTO turns (seq, sessionKey, messageId, origin, prompt, status, createdAt, endedAt)
          VALUES (?1, 's', ?2, 'test', 'p', 'delivered', 1, 1)
          """,
          [seq, "m#{seq}"]
        )
    end

    assert Enum.map(Ledger.unpublished_terminals(db), & &1.seq) == [1, 2, 3]
  end

  test "review verdict counts find review assignments through their subject index", %{db: db} do
    direct_plan =
      plan!(db, "SELECT id FROM assignments WHERE reviewsAssignmentId=?1", ["subject"])

    assert Enum.any?(direct_plan, &String.contains?(&1, "assignments_reviews_assignment"))

    assignment_verdict_plan =
      plan!(
        db,
        """
        SELECT v.verdictKind, v.byHarness, v.byProvider
        FROM attests AS v
        JOIN assignments AS r ON r.id = v.assignmentId
        WHERE r.reviewsAssignmentId = ?1
          AND v.kind = 'verdict'
          AND v.bySession = r.holderKey
          AND v.bySession != ?2
        ORDER BY v.ts ASC, v.id ASC
        """,
        ["subject", "session"]
      )

    assert Enum.any?(
             assignment_verdict_plan,
             &String.contains?(&1, "assignments_reviews_assignment")
           )

    count_plan =
      plan!(
        db,
        """
        SELECT COUNT(*)
        FROM assignments review
        JOIN attests verdict ON verdict.assignmentId=review.id
        WHERE review.reviewsAssignmentId =
              (SELECT COALESCE(reviewsAssignmentId, id) FROM assignments WHERE id = ?1)
          AND verdict.kind = 'verdict'
        """,
        ["subject"]
      )

    assert Enum.any?(count_plan, &String.contains?(&1, "assignments_reviews_assignment"))

    work_item_count_plan =
      plan!(
        db,
        """
        SELECT COUNT(*)
        FROM assignments producer
        JOIN assignments review ON review.reviewsAssignmentId=producer.id
        JOIN attests verdict ON verdict.assignmentId=review.id
        WHERE producer.workItemId=?1
          AND review.workItemId IS NULL
          AND verdict.kind='verdict'
          AND verdict.verdictKind='changes-requested'
        """,
        ["work-item"]
      )

    assert Enum.any?(
             work_item_count_plan,
             &String.contains?(&1, "assignments_reviews_assignment")
           )

    compatibility_count_plan =
      plan!(
        db,
        """
        SELECT COUNT(*)
        FROM assignments producer
        JOIN assignments review ON review.reviewsAssignmentId=producer.id
        JOIN attests verdict ON verdict.assignmentId=review.id
        WHERE producer.workItemId=?1
          AND review.workItemId IS NULL
          AND review.reviewsAssignmentId IS NOT NULL
          AND verdict.kind='verdict'
          AND verdict.rowid <= (SELECT rowid FROM attests WHERE id=?2)
        """,
        ["work-item", "attest"]
      )

    assert Enum.any?(
             compatibility_count_plan,
             &String.contains?(&1, "assignments_reviews_assignment")
           )
  end

  test "revocation generation reads use both indexed keys", %{db: db} do
    plan =
      plan!(
        db,
        """
        SELECT a.id,
               (SELECT r.reason FROM assignment_revocation_generations g
                JOIN assignment_revocations r ON r.id=g.revocationId
                WHERE g.assignmentId=a.id AND g.reopeningId IS
                  (SELECT reopening.id FROM assignment_reopenings reopening
                   WHERE reopening.assignmentId=a.id ORDER BY reopening.id DESC LIMIT 1))
        FROM assignments a
        """,
        []
      )

    assert Enum.any?(
             plan,
             &String.contains?(&1, "assignment_revocation_generation_reopened")
           )

    refute Enum.any?(plan, &Regex.match?(~r/^SCAN g\b/, &1))
  end

  test "running turn lookups use the pending-turn partial index", %{db: db} do
    plan =
      plan!(
        db,
        "SELECT messageId FROM turns WHERE sessionKey=?1 AND status='running' " <>
          "AND status IN ('queued','running') LIMIT 1",
        ["session"]
      )

    assert Enum.any?(plan, &String.contains?(&1, "turns_pending"))
    refute Enum.any?(plan, &Regex.match?(~r/^SCAN turns\b/, &1))

    recovery_plan =
      plan!(
        db,
        "SELECT seq,sessionKey FROM turns WHERE status='running' " <>
          "AND status IN ('queued','running') AND sessionKey=?1",
        ["session"]
      )

    assert Enum.any?(recovery_plan, &String.contains?(&1, "turns_pending"))
    refute Enum.any?(recovery_plan, &Regex.match?(~r/^SCAN turns\b/, &1))
  end

  test "hot query indexes are recorded and skipped on a second boot", %{db: db} do
    {:ok, [[applied_at]]} =
      DB.query(db, "SELECT appliedAt FROM hot_query_indexes_migration WHERE id=0")

    {:ok, [[before_version]]} = DB.query(db, "PRAGMA schema_version")
    assert :ok = Tightbeam.Schema.ensure_all(db)

    assert {:ok, [[^applied_at]]} =
             DB.query(db, "SELECT appliedAt FROM hot_query_indexes_migration WHERE id=0")

    assert {:ok, [[^before_version]]} = DB.query(db, "PRAGMA schema_version")

    assert {:ok, [[index_sql]]} =
             DB.query(
               db,
               "SELECT sql FROM sqlite_master WHERE type='index' " <>
                 "AND name='assignment_revocation_generation_reopened'"
             )

    refute index_sql =~ "WHERE"
  end
end
