defmodule Tightbeam.DiagnosticExpiryTest do
  use Tightbeam.TestCase, async: false

  alias Tightbeam.{DB, DiagnosticExpiry, EventLog}

  setup do
    db = :"diagnostic_expiry_db_#{System.unique_integer([:positive])}"
    start_supervised!({DB, path: ":memory:", name: db})
    :ok = EventLog.ensure_schema(db)
    %{db: db}
  end

  test "expires only the three diagnostic kinds before the cutoff", %{db: db} do
    for kind <- ~w(rule_effect_failed rule_notice_failed rail_episode_writer_unavailable),
        ts <- [90, 100, 110] do
      insert(db, kind, ts)
    end

    for kind <- ~w(wake_undeliverable decision_request_ruled queued_message_suppressed rail_sweep) do
      insert(db, kind, 90)
    end

    assert {:ok, {:done, 3}} = DiagnosticExpiry.expire_batch(db, 0, nil, 100)
    assert {:ok, {:done, 0}} = DiagnosticExpiry.expire_batch(db, 0, nil, 100)

    assert {:ok,
            [
              ["wake_undeliverable"],
              ["decision_request_ruled"],
              ["queued_message_suppressed"],
              ["rail_sweep"]
            ]} = DB.query(db, "SELECT kind FROM lifecycle_events WHERE ts=90 ORDER BY id")

    assert {:ok, [[6]]} = DB.query(db, "SELECT COUNT(*) FROM lifecycle_events WHERE ts>=100")
  end

  test "bounds a batch, with new arrivals deferred to the next pass", %{db: db} do
    for _ <- 1..71, do: insert(db, "rule_notice_failed", 90)
    assert {:ok, {:more, 50, 71, 50}} = DiagnosticExpiry.expire_batch(db, 0, nil, 100)
    insert(db, "rule_effect_failed", 90)
    assert {:ok, {:done, 21}} = DiagnosticExpiry.expire_batch(db, 50, 71, 100)
    assert {:ok, [[72]]} = DB.query(db, "SELECT id FROM lifecycle_events")
    assert {:ok, {:done, 1}} = DiagnosticExpiry.expire_batch(db, 0, nil, 100)
  end

  test "failed deletion rolls back and retry removes each eligible row once", %{db: db} do
    for _ <- 1..3, do: insert(db, "rule_notice_failed", 90)

    assert :ok =
             DB.execute(db, """
             CREATE TRIGGER fixture_fail BEFORE DELETE ON lifecycle_events
             WHEN OLD.id = 2 BEGIN SELECT RAISE(FAIL, 'fixture interruption'); END
             """)

    assert {:error, error} = DiagnosticExpiry.expire_batch(db, 0, nil, 100)
    assert Exception.message(error) =~ "fixture interruption"
    assert {:ok, [[1], [2], [3]]} = DB.query(db, "SELECT id FROM lifecycle_events ORDER BY id")
    assert :ok = DB.execute(db, "DROP TRIGGER fixture_fail")
    assert {:ok, {:done, 3}} = DiagnosticExpiry.expire_batch(db, 0, nil, 100)
    assert {:ok, {:done, 0}} = DiagnosticExpiry.expire_batch(db, 0, nil, 100)
  end

  defp insert(db, kind, ts) do
    assert {:ok, []} =
             DB.query(
               db,
               "INSERT INTO lifecycle_events(ts, kind, subject) VALUES (?1, ?2, 'fixture')",
               [ts, kind]
             )
  end
end
