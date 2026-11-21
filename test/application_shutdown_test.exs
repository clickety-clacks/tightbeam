defmodule Tightbeam.ApplicationShutdownTest do
  use Tightbeam.TestCase, async: false

  alias Tightbeam.{DB, EventLog}
  alias Tightbeam.Firehose.Hub

  setup do
    start_supervised!({DB, path: ":memory:", name: DB})
    :ok = EventLog.ensure_schema(DB)
    :ok = DB.execute(DB, "CREATE TABLE turns (status TEXT)")
    epoch = EventLog.boot(DB)
    Application.put_env(:tightbeam, :boot_epoch, epoch)
    Application.put_env(:tightbeam, :drain_timeout_ms, 500)
    start_supervised!({Hub, name: Hub})

    on_exit(fn -> :persistent_term.erase({Tightbeam.Application, :shutdown_deadline}) end)
    %{epoch: epoch}
  end

  @tag timeout: 5_000
  test "an unacknowledged firehose stop is bounded by its deadline" do
    :ok = Hub.register(Hub, self(), %{mode: :pending})
    started = System.monotonic_time(:millisecond)
    assert {:error, _} = Hub.shutdown(Hub, started + 100)
    assert System.monotonic_time(:millisecond) - started < 500
    assert_received :firehose_shutdown
    assert :ok = Hub.shutdown_delivered(Hub, self())
  end

  test "a normal stop stamps the epoch inside the shutdown budget", %{epoch: epoch} do
    started = System.monotonic_time(:millisecond)
    wall_started = System.system_time(:millisecond)
    assert :state = Tightbeam.Application.prep_stop(:state)
    stamp = assert_stamped(epoch)
    deadline = Tightbeam.Application.shutdown_deadline(0x7FFFFFFFFFFFFFFF)
    assert stamp < wall_started + (deadline - started)
  end

  @tag timeout: 5_000
  test "a client that never acknowledges leaves time to stamp", %{epoch: epoch} do
    Application.put_env(:tightbeam, :drain_timeout_ms, 5_500)
    :ok = Hub.register(Hub, self(), %{mode: :pending})
    started = System.monotonic_time(:millisecond)
    assert :state = Tightbeam.Application.prep_stop(:state)
    assert System.monotonic_time(:millisecond) - started < 900
    assert_received :firehose_shutdown
    assert_stamped(epoch)
  end

  @tag timeout: 5_000
  test "a drain that exhausts its allowance still stamps inside the budget", %{
    epoch: epoch,
    timeout: test_timeout
  } do
    Application.put_env(:tightbeam, :drain_timeout_ms, 5_500)
    :ok = DB.execute(DB, "INSERT INTO turns VALUES ('running')")
    db = Process.whereis(DB)
    caller = self()
    assert 1 = :erlang.trace(db, true, [:receive, :send, :monotonic_timestamp])

    try do
      started = System.monotonic_time(:millisecond)
      wall_started = System.system_time(:millisecond)
      assert :state = Tightbeam.Application.prep_stop(:state)
      deadline = Tightbeam.Application.shutdown_deadline(0x7FFFFFFFFFFFFFFF)

      # Match this shutdown's transaction and successful reply. The DB sends
      # that reply after COMMIT; the VM timestamps the send even if this test
      # resumes late. cleanShutdownAt alone is sampled before UPDATE/COMMIT.
      assert_receive {:trace_ts, ^db, :receive,
                      {:"$gen_call", {^caller, reply_tag},
                       {:transaction_until, _callback, ^deadline}}, _received_at},
                     test_timeout

      assert_receive {:trace_ts, ^db, :send, {^reply_tag, {{:ok, _result}, _timing}},
                      _destination, committed_at},
                     test_timeout

      assert System.convert_time_unit(committed_at, :nanosecond, :millisecond) - started < 900

      stamp = assert_stamped(epoch)
      assert stamp - wall_started < 900
    after
      :erlang.trace(db, false, [:receive, :send, :monotonic_timestamp])
    end
  end

  test "a short budget reserves time for the stamp" do
    # Check the reservation without depending on scheduling a DB transaction
    # inside 13 ms. The drain-exhaustion test exercises the actual stamp.
    started = -1_000
    budget = 25
    deadline = started + budget
    work_deadline = Tightbeam.Application.shutdown_work_deadline(deadline, budget)

    assert work_deadline == started + 12
    assert deadline - work_deadline == 13
  end

  @tag timeout: 5_000
  test "a short budget still stamps after exhausting the drain", %{epoch: epoch} do
    Application.put_env(:tightbeam, :drain_timeout_ms, 1_000)
    :ok = DB.execute(DB, "INSERT INTO turns VALUES ('running')")
    started = System.monotonic_time(:millisecond)

    assert :state = Tightbeam.Application.prep_stop(:state)
    elapsed = System.monotonic_time(:millisecond) - started

    assert elapsed >= 500
    assert elapsed < 3_000
    assert_stamped(epoch)
  end

  @tag timeout: 5_000
  test "a stalled database cannot add a fresh stamp timeout" do
    :ok = :sys.suspend(DB)
    started = System.monotonic_time(:millisecond)

    try do
      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert :state = Tightbeam.Application.prep_stop(:state)
        end)

      assert System.monotonic_time(:millisecond) - started < 900
      assert log =~ "clean shutdown stamp failed"
    after
      :sys.resume(DB)
    end
  end

  defp assert_stamped(epoch) do
    assert {:ok, [[stamp]]} =
             DB.query(DB, "SELECT cleanShutdownAt FROM boot_epochs WHERE epoch = ?1", [epoch])

    assert is_integer(stamp)
    stamp
  end
end
