defmodule Tightbeam.RetentionTest do
  use Tightbeam.TestCase, async: false

  alias Tightbeam.{DB, EventLog, Retention}

  @first DateTime.to_unix(~U[2026-09-19 00:00:00Z], :millisecond)
  @after_last DateTime.to_unix(~U[2026-10-15 00:00:00Z], :millisecond)

  setup do
    db = :"retention_db_#{System.unique_integer([:positive])}"
    start_supervised!({DB, path: ":memory:", name: db})
    :ok = EventLog.ensure_schema(db)
    %{db: db}
  end

  test "only the historical rail_sweep window is deleted, including its first and last days", %{
    db: db
  } do
    rows = [
      {@first - 1, "rail_sweep"},
      {@first, "rail_sweep"},
      {@after_last - 1, "rail_sweep"},
      {@after_last, "rail_sweep"},
      {@first, "rail_remedy"},
      {@first, "decision_request_ruled"},
      {@first - 90 * 86_400_000, "adapter_down"}
    ]

    for {ts, kind} <- rows, do: insert_row(db, ts, kind)
    {:ok, pid} = Retention.start_link(db: db, name: nil)
    drain(pid)

    assert {:ok, retained} = DB.query(db, "SELECT ts,kind FROM lifecycle_events ORDER BY id")

    assert retained == [
             [@first - 1, "rail_sweep"],
             [@after_last, "rail_sweep"],
             [@first, "rail_remedy"],
             [@first, "decision_request_ruled"],
             [@first - 90 * 86_400_000, "adapter_down"]
           ]

    assert {:ok, [[0]]} = DB.query(db, "SELECT id FROM rail_sweep_cleanup")
    GenServer.stop(pid)
  end

  test "a completed pass never deletes later backfilled events, including after restart", %{
    db: db
  } do
    insert_row(db, @first, "rail_sweep")
    {:ok, pid} = Retention.start_link(db: db, name: nil)
    drain(pid)
    assert count(db) == 0
    GenServer.stop(pid)

    insert_row(db, @first, "rail_sweep")
    {:ok, restarted} = Retention.start_link(db: db, name: nil)
    drain(restarted)
    assert count(db) == 1
    GenServer.stop(restarted)
  end

  test "large history is processed in bounded batches without blocking other reads", %{db: db} do
    for _ <- 1..2_001, do: insert_row(db, @first, "rail_sweep")
    {:ok, pid} = Retention.start_link(db: db, name: nil)
    assert count(db) == 2_001

    send(pid, :trim)
    assert %{cursor: 2_000, complete: false} = :sys.get_state(pid)
    assert count(db) == 1
    assert {:ok, [[42]]} = DB.query(db, "SELECT 42")
    drain(pid)
    assert count(db) == 0
    GenServer.stop(pid)
  end

  test "a failed pass leaves the process alive and does not mark cleanup complete", %{db: db} do
    assert :ok = DB.execute(db, "DROP TABLE lifecycle_events")
    {:ok, pid} = Retention.start_link(db: db, name: nil)
    send(pid, :trim)
    assert %{complete: false} = :sys.get_state(pid)
    assert Process.alive?(pid)
    assert {:ok, []} = DB.query(db, "SELECT id FROM rail_sweep_cleanup")
    GenServer.stop(pid)
  end

  defp insert_row(db, ts, kind) do
    assert {:ok, []} =
             DB.query(
               db,
               "INSERT INTO lifecycle_events (ts,kind,subject) VALUES (?1,?2,'sample')",
               [ts, kind]
             )
  end

  defp count(db) do
    {:ok, [[count]]} = DB.query(db, "SELECT COUNT(*) FROM lifecycle_events")
    count
  end

  defp drain(pid) do
    send(pid, :trim)
    eventually(fn -> :sys.get_state(pid).complete end)
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
