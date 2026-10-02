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
      DROP INDEX lifecycle_events_idle_cleanup_kind_id;
      """)

    :ok = LifecycleRuntimeFixture.seed!(db)

    for %{sql: sql, params: params, expected: expected} <- LifecycleRuntimeFixture.cases() do
      assert {:ok, plan} = DB.query(db, "EXPLAIN QUERY PLAN " <> sql, params)
      assert Enum.any?(plan, &Regex.match?(~r/\bSCAN (?:lifecycle_events|e)\b/, List.last(&1)))
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
      DROP INDEX lifecycle_events_idle_cleanup_kind_id;
      CREATE TABLE lifecycle_events_idle_cleanup_kind_id(x);
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

  test "the JSON access path does not add write constraints or hide malformed detail" do
    db = start_supervised!({DB, path: ":memory:", name: nil})
    :ok = Schema.ensure_all(db)

    :ok =
      DB.execute(db, """
      INSERT INTO lifecycle_events(ts,kind,subject,detail)
      VALUES (0,'rail_sweep','unrelated','not json'),
             (0,'idle_cleanup_pending_observed','bad','not json');
      """)

    query =
      Enum.find(
        LifecycleRuntimeFixture.cases(),
        &String.starts_with?(String.trim(&1.sql), "SELECT e.subject")
      )

    assert {:error, %DB.Error{message: message}} = DB.query(db, query.sql, ["index-session", nil])
    assert message =~ "malformed JSON"
    :ok = Schema.ensure_all(db)
  end
end
