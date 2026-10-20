defmodule Tightbeam.LifecycleRuntimeIndexesTest do
  use Tightbeam.TestCase, async: false
  import ExUnit.CaptureLog
  alias Tightbeam.{DB, LifecycleRuntimeFixture, Schema}

  test "bootstrap indexes every named runtime lookup without changing its result" do
    db = start_supervised!({DB, path: ":memory:", name: nil})
    :ok = Schema.ensure_all(db)

    :ok =
      DB.execute(db, """
      DROP INDEX lifecycle_events_subject_kind;
      """)

    :ok = LifecycleRuntimeFixture.seed!(db)

    for %{sql: sql, params: params, expected: expected} <- LifecycleRuntimeFixture.cases() do
      assert {:ok, plan} = DB.query(db, "EXPLAIN QUERY PLAN " <> sql, params)
      # Recorded cleanup reads no longer depend on lifecycle history indexes.
      if String.contains?(sql, "lifecycle_events") do
        assert Enum.any?(plan, &Regex.match?(~r/\bSCAN (?:lifecycle_events|e)\b/, List.last(&1)))
      end

      assert DB.query(db, sql, params) == {:ok, expected}
    end

    :ok = Schema.ensure_all(db)
    :ok = LifecycleRuntimeFixture.assert_plans_and_results!(db)
  end

  test "index failure rolls back both access paths and preserves lifecycle bytes" do
    db = start_supervised!({DB, path: ":memory:", name: nil})
    :ok = Schema.ensure_all(db)

    :ok =
      DB.execute(db, """
      DROP INDEX lifecycle_events_subject_kind;
      CREATE TABLE lifecycle_events_subject_kind(x);
      INSERT INTO lifecycle_events(ts,kind,subject,detail) VALUES(0,'synthetic','preserved','not json');
      """)

    capture_log(fn ->
      assert_raise Schema.ShapeError, ~r/lifecycle runtime index migration failed/, fn ->
        Schema.ensure_all(db)
      end
    end)

    assert {:ok, []} =
             DB.query(
               db,
               "SELECT name FROM sqlite_master WHERE type='index' AND name='lifecycle_events_subject_kind'"
             )

    assert {:ok, [["not json"]]} =
             DB.query(
               db,
               "SELECT detail FROM lifecycle_events WHERE subject='preserved'"
             )

    assert {:ok, [[1]]} = DB.query(db, "PRAGMA foreign_keys")
    assert {:ok, [[0]]} = DB.query(db, "PRAGMA ignore_check_constraints")
    assert {:ok, [[5000]]} = DB.query(db, "PRAGMA busy_timeout")
  end

  test "boot preserves legacy cleanup history without rewriting malformed detail" do
    db = start_supervised!({DB, path: ":memory:", name: nil})
    :ok = Schema.ensure_all(db)
    :ok = LifecycleRuntimeFixture.seed!(db)

    :ok =
      DB.execute(db, """
      INSERT INTO lifecycle_events(ts,kind,subject,detail)
      VALUES (0,'rail_sweep','unrelated','not json'),
             (0,'idle_cleanup_pending_observed','bad','not json');
      """)

    assert {:ok, history} = DB.query(db, "SELECT * FROM lifecycle_events ORDER BY id")

    # Retired source machinery no longer interprets its historical rows during
    # boot. The data remains available for audit and does not block startup.
    _log = capture_log(fn -> assert :ok = Schema.ensure_all(db) end)
    assert DB.query(db, "SELECT * FROM lifecycle_events ORDER BY id") == {:ok, history}

    assert {:ok, [[2]]} =
             DB.query(db, "SELECT count(*) FROM lifecycle_events WHERE detail='not json'")

    assert {:ok, [[1]]} =
             DB.query(
               db,
               "SELECT count(*) FROM lifecycle_events WHERE kind='idle_cleanup_pending_observed' AND subject='bad' AND detail='not json'"
             )

    :ok = LifecycleRuntimeFixture.assert_plans_and_results!(db)
    :ok = Schema.ensure_all(db)
  end
end
