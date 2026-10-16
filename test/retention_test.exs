defmodule Tightbeam.RetentionTest do
  use Tightbeam.TestCase, async: false

  alias Tightbeam.{DB, EventLog, Retention}
  alias Tightbeam.DB.Txn

  @day_ms 86_400_000

  setup do
    db = :"retention_db_#{System.unique_integer([:positive])}"
    start_supervised!({DB, path: ":memory:", name: db})
    :ok = EventLog.ensure_schema(db)
    %{db: db}
  end

  test "startup leaves a large history untouched and batches yield to other database work", %{
    db: db
  } do
    now = System.system_time(:millisecond)
    insert_rows(db, 6_001, now - 61 * @day_ms)
    pid = start_supervised!({Retention, db: db, name: nil})
    assert %{cursor: 0, cutoff: nil, days: 60} = :sys.get_state(pid)
    assert count(db) == 6_001

    send(pid, :trim)
    assert %{cursor: 2_000} = :sys.get_state(pid)
    assert count(db) == 4_001
    assert {:ok, [[42]]} = DB.query(db, "SELECT 42")
    eventually(fn -> count(db) == 0 end)
  end

  test "configured days preserve the cutoff and younger rows with out-of-order timestamps", %{
    db: db
  } do
    previous = Application.get_env(:tightbeam, :retention_days)
    Application.put_env(:tightbeam, :retention_days, 7)

    on_exit(fn ->
      if previous == nil,
        do: Application.delete_env(:tightbeam, :retention_days),
        else: Application.put_env(:tightbeam, :retention_days, previous)
    end)

    pid = start_supervised!({Retention, db: db, name: nil})
    assert %{days: 7} = :sys.get_state(pid)
    cutoff = System.system_time(:millisecond) - 7 * @day_ms
    :sys.replace_state(pid, &%{&1 | cutoff: cutoff})
    insert_rows(db, 1, cutoff)
    insert_rows(db, 1, cutoff - 1)
    insert_rows(db, 1, cutoff + @day_ms)
    insert_rows(db, 1, cutoff - @day_ms)

    send(pid, :trim)
    :sys.get_state(pid)

    assert {:ok, [[^cutoff], [young]]} =
             DB.query(db, "SELECT ts FROM lifecycle_events ORDER BY id")

    assert young == cutoff + @day_ms
  end

  test "a failed batch is logged without stopping the trimmer or unrelated reads", %{db: db} do
    assert :ok = DB.execute(db, "DROP TABLE lifecycle_events")
    pid = start_supervised!({Retention, db: db, name: nil})
    send(pid, :trim)
    assert %{cursor: 0} = :sys.get_state(pid)
    assert Process.alive?(pid)
    assert {:ok, [[1]]} = DB.query(db, "SELECT 1")
  end

  test "invalid retention configuration logs an error and keeps the default", %{db: db} do
    previous = Application.get_env(:tightbeam, :retention_days)
    Application.put_env(:tightbeam, :retention_days, "invalid")

    on_exit(fn ->
      if previous == nil,
        do: Application.delete_env(:tightbeam, :retention_days),
        else: Application.put_env(:tightbeam, :retention_days, previous)
    end)

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        pid = start_supervised!({Retention, db: db, name: nil})
        assert %{days: 60} = :sys.get_state(pid)
      end)

    assert log =~ "invalid retention_days"
  end

  for kind <- ~w(
        decision_request_ruled
        supervision_entitlement_armed
        supervision_entitlement_claimed
        supervision_entitlement_cleared
        supervision_entitlement_deferred
        supervision_entitlement_rearmed
        supervision_entitlement_rebased
        supervision_entitlement_recovered
        supervision_entitlement_recovery_refused
        supervision_entitlement_terminated
        supervision_entitlement_transferred
        idle_cleanup_pending_observed
        lineage_exhausted
        queued_message_suppressed
        wake_undeliverable
        retired_workspace_cleanup_completed
        retired_workspace_cleanup_incomplete
        supervision_entitlement_future
        unknown_future_kind
      ) do
    @kind kind
    test "retention preserves expired #{@kind} state", %{db: db} do
      expired = System.system_time(:millisecond) - 61 * @day_ms

      assert {:ok, []} =
               DB.query(
                 db,
                 "INSERT INTO lifecycle_events (ts,kind,subject,detail) VALUES (?1,?2,'state','evidence')",
                 [expired, @kind]
               )

      insert_rows(db, 1, expired)
      pid = start_supervised!({Retention, db: db, name: nil})
      send(pid, :trim)
      :sys.get_state(pid)

      assert {:ok, [[@kind, "state", "evidence"]]} =
               DB.query(db, "SELECT kind,subject,detail FROM lifecycle_events ORDER BY id")
    end
  end

  test "a pass stops after the first nondeleting batch at or past the cutoff", %{db: db} do
    cutoff = System.system_time(:millisecond) - 60 * @day_ms
    insert_rows(db, 2_000, cutoff - 1)
    insert_rows(db, 4_001, cutoff)
    pid = start_supervised!({Retention, db: db, name: nil})
    :sys.replace_state(pid, &%{&1 | cutoff: cutoff})

    send(pid, :trim)
    assert %{cursor: 2_000, cutoff: ^cutoff} = :sys.get_state(pid)
    eventually(fn -> :sys.get_state(pid).cutoff == nil end)
    assert %{cursor: 0, cutoff: nil} = :sys.get_state(pid)
    assert count(db) == 4_001
    # Another expired row cannot be visited until the next hourly pass.
    insert_rows(db, 1, cutoff - 1)
    Process.sleep(250)
    assert count(db) == 4_002
  end

  test "a nondeleting batch of old protected rows does not end the pass", %{db: db} do
    expired = System.system_time(:millisecond) - 61 * @day_ms
    insert_rows(db, 2_000, expired)
    assert :ok = DB.execute(db, "UPDATE lifecycle_events SET kind='decision_request_ruled'")
    insert_rows(db, 1, expired)
    pid = start_supervised!({Retention, db: db, name: nil})
    send(pid, :trim)
    assert %{cursor: 2_000} = :sys.get_state(pid)
    eventually(fn -> count(db) == 2_000 end)

    assert {:ok, [["decision_request_ruled", 2_000]]} =
             DB.query(db, "SELECT kind,COUNT(*) FROM lifecycle_events GROUP BY kind")
  end

  defp insert_rows(db, count, ts) do
    assert {:ok, _} =
             DB.transaction(db, fn txn ->
               for _ <- 1..count do
                 Txn.q(
                   txn,
                   "INSERT INTO lifecycle_events (ts,kind,subject) VALUES (?1,'rail_sweep','sample')",
                   [ts]
                 )
               end
             end)
  end

  defp count(db) do
    {:ok, [[count]]} = DB.query(db, "SELECT COUNT(*) FROM lifecycle_events")
    count
  end

  defp eventually(fun, attempts \\ 100)
  defp eventually(fun, 0), do: assert(fun.())

  defp eventually(fun, attempts) do
    unless fun.() do
      Process.sleep(20)
      eventually(fun, attempts - 1)
    end
  end
end
