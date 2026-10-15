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
    assert Enum.any?(plan, &String.contains?(&1, "SEARCH w USING INDEX sqlite_autoindex_wakes_1 (wakeId=?)"))
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
end
