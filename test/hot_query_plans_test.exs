defmodule Tightbeam.HotQueryPlansTest do
  use Tightbeam.TestCase, async: false

  alias Tightbeam.{Assignments, DB, Ledger, Rules, WorkState}

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
    assignment_verdict_plan =
      plan!(db, Assignments.commissioned_review_authors_sql(), ["subject", "session"])

    assert Enum.any?(
             assignment_verdict_plan,
             &String.contains?(&1, "assignments_reviews_assignment")
           )

    count_plan = plan!(db, Rules.assignment_review_verdict_count_sql(), ["subject"])

    assert Enum.any?(count_plan, &String.contains?(&1, "assignments_reviews_assignment"))

    work_item_count_plan =
      plan!(db, Rules.work_item_changes_requested_count_sql(), ["work-item"])

    assert Enum.any?(
             work_item_count_plan,
             &String.contains?(&1, "assignments_reviews_assignment")
           )

    compatibility_count_plan =
      plan!(db, Rules.work_item_review_verdict_count_sql(), ["work-item", "attest"])

    assert Enum.any?(
             compatibility_count_plan,
             &String.contains?(&1, "assignments_reviews_assignment")
           )

    fourth_round_count_plan =
      plan!(db, Rules.work_item_fourth_round_count_sql(), ["work-item"])

    assert Enum.any?(
             fourth_round_count_plan,
             &String.contains?(&1, "assignments_reviews_assignment")
           )
  end

  test "revocation generation reads use both indexed keys", %{db: db} do
    plan = plan!(db, WorkState.assignment_query_sql(), [])

    assert Enum.any?(
             plan,
             &String.contains?(&1, "assignment_revocation_generation_reopened")
           )

    refute Enum.any?(plan, &Regex.match?(~r/^SCAN g\b/, &1))
  end

  test "running turn lookups use the pending-turn partial index", %{db: db} do
    plan = plan!(db, Ledger.running_turn_message_id_sql(), ["session"])

    assert Enum.any?(plan, &String.contains?(&1, "turns_pending"))
    refute Enum.any?(plan, &Regex.match?(~r/^SCAN turns\b/, &1))

    recovery_plan =
      plan!(
        db,
        Ledger.recover_running_rows_sql("sessionKey = ?1 AND (owner IS NULL OR owner <> ?2)"),
        ["session", "replacement"]
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

  test "a failed hot query index migration does not stop schema boot" do
    db = :"hot_query_indexes_failure_db_#{System.unique_integer([:positive])}"
    start_supervised!(Supervisor.child_spec({DB, path: ":memory:", name: db}, id: db))
    :ok = DB.execute(db, "CREATE TABLE assignments_reviews_assignment (id INTEGER)")

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert :ok = Tightbeam.Schema.ensure_all(db)
      end)

    assert log =~ "hot query indexes were not built; continuing without them"
    assert {:ok, [[1]]} = DB.query(db, "SELECT 1")
  end
end
