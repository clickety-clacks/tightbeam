defmodule Tightbeam.DBBackgroundOverloadTest do
  use Tightbeam.TestCase, async: false
  import ExUnit.CaptureLog
  alias Tightbeam.DB

  setup do
    db = start_supervised!({DB, path: ":memory:", name: nil})
    :sys.suspend(db)
    on_exit(fn -> if Process.alive?(db), do: :sys.resume(db) end)
    for _ <- 1..128, do: send(db, {:"$gen_call", {self(), make_ref()}, {:query, "SELECT 1", []}})
    %{db: db}
  end

  test "background passes defer overload from a result, a raise, or a match", %{db: db} do
    log =
      capture_log([level: :debug], fn ->
        assert :deferred =
                 DB.background_pass(
                   fn -> DB.transaction(db, fn _ -> flunk("ran") end) end,
                   :deferred
                 )

        assert :ok = DB.background_pass(fn -> raise DB.Overloaded end)
        assert :ok = DB.background_pass(fn -> {:ok, _} = DB.query(db, "SELECT 1") end)
      end)

    assert length(Regex.scan(~r/background pass deferred/, log)) == 3

    assert_raise RuntimeError, "unrelated", fn ->
      DB.background_pass(fn -> raise "unrelated" end)
    end
  end

  test "notice drain skips its pass under overload", %{db: db} do
    assert Tightbeam.NoticeBatcher.recover(db) == []
  end

  test "lane reconcile keeps its state under overload", %{db: db} do
    state = %{db: db, interval: 3_600_000}
    assert {:noreply, ^state} = Tightbeam.LaneManager.handle_info(:tick, state)
  end

  test "bubble sweep keeps its cursor under overload", %{db: db} do
    state = %{db: db, interval: 3_600_000}
    assert {:noreply, ^state} = Tightbeam.Productions.BubbleSweeper.handle_info(:tick, state)
  end

  test "scheduler tick skips overload and retains its next tick", %{db: db} do
    state = %{
      db: db,
      internal_consumers: %{},
      tick_ms: 3_600_000,
      deliver: fn _ -> flunk("delivery must not run") end,
      delivery_opts: []
    }

    assert {:noreply, ^state} = Tightbeam.Wakes.handle_info(:tick, state)
  end

  test "supervision sweep skips overload and retains its next tick", %{db: db} do
    state = %{db: db, sweep_ms: 3_600_000}
    assert {:noreply, ^state} = Tightbeam.Supervision.handle_info(:scheduled_sweep, state)
  end

  test "sentinel stop notification skips overload", %{db: db} do
    # An absent declaration takes the stop path during reconciliation.
    state = %{db: db, host: "test-host", children: %{}, failures: %{}}

    assert {:noreply, ^state} =
             Tightbeam.SentinelSupervisor.handle_info({:restart, "missing"}, state)
  end

  test "turn cancellation skips overload without losing lane state", %{db: db} do
    state = %{
      db: db,
      task_ref: make_ref(),
      current_seq: 1,
      current_message_id: "message",
      current_owner_lease: nil
    }

    assert {:reply, {:error, %DB.Overloaded{}}, ^state} =
             Tightbeam.SessionLane.handle_call(:cancel_current, {self(), make_ref()}, state)
  end

  test "retention skips overload and preserves its cursor", %{db: db} do
    state = %{db: db, days: 60, cursor: 42, cutoff: nil}
    assert {:noreply, ^state} = Tightbeam.Retention.handle_info(:trim, state)
  end
end
