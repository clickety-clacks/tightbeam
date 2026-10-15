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

  defp insert_rows(db, count, ts) do
    assert {:ok, _} =
             DB.transaction(db, fn txn ->
               for _ <- 1..count do
                 Txn.q(
                   txn,
                   "INSERT INTO lifecycle_events (ts,kind,subject) VALUES (?1,'test','sample')",
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
