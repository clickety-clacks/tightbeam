defmodule Tightbeam.RecognitionRetryTest do
  use Tightbeam.TestCase, async: false
  import ExUnit.CaptureLog
  alias Tightbeam.DB
  alias Tightbeam.DB.Txn

  defmodule DeleteRefusal do
    use GenServer
    def start_link(db), do: GenServer.start_link(__MODULE__, db)
    def init(db), do: {:ok, %{db: db, refused: false}}

    def handle_call({:transaction, _}, _from, %{refused: false} = state),
      do: {:reply, {:error, %DB.Overloaded{}}, %{state | refused: true}}

    def handle_call(request, _from, state), do: {:reply, GenServer.call(state.db, request), state}
  end

  setup do
    db = start_supervised!({DB, path: ":memory:", name: nil})
    :ok = DB.execute(db, "CREATE TABLE recognized_rows(id INTEGER PRIMARY KEY)")
    %{db: db, retry: :sys.get_state(db).retry}
  end

  test "arity two returns the committed value, rolls back recognition and retries it", %{
    db: db,
    retry: retry
  } do
    log =
      capture_log(fn ->
        assert {:ok, {:committed, []}} =
                 DB.transaction_then(
                   db,
                   fn txn ->
                     Txn.q(txn, "INSERT INTO recognized_rows VALUES(1)")
                     :committed
                   end,
                   fn txn, :committed ->
                     Txn.q(txn, "INSERT INTO recognized_rows VALUES(2)")

                     if Txn.q(txn, "SELECT id FROM recognized_rows WHERE id=3") == [],
                       do: raise("retry me")

                     :recognized
                   end,
                   fallback: fn result -> {result, []} end
                 )
      end)

    assert log =~ "post-commit recognition failed"
    assert {:ok, [[1]]} = DB.query(db, "SELECT id FROM recognized_rows")
    assert {:ok, [[0, 0]]} = DB.query(db, "SELECT attempts,flagged FROM pending_recognition")
    :ok = DB.execute(db, "INSERT INTO recognized_rows VALUES(3)")
    retry_now(db, retry)
    assert {:ok, [[1], [2], [3]]} = DB.query(db, "SELECT id FROM recognized_rows ORDER BY id")
    assert {:ok, []} = DB.query(db, "SELECT id FROM pending_recognition")
  end

  test "arity one retries its persisted callback after the retry process restarts", %{
    db: db,
    retry: retry
  } do
    parent = self()
    gate = Path.join(System.tmp_dir!(), "recognition-gate-" <> Tightbeam.Id.uuid4())
    on_exit(fn -> File.rm(gate) end)

    assert {:ok, :committed} =
             DB.transaction_then(db, fn _ -> :committed end, fn :committed ->
               if not File.exists?(gate), do: throw(:not_yet)
               send(parent, :recognized)
               :recognized
             end)

    assert {:ok, [[_]]} = DB.query(db, "SELECT id FROM pending_recognition")
    # Replace only the retry process. It reconstructs the operation from SQL,
    # with no in-memory callback registry.
    :ok = GenServer.stop(retry)
    {:ok, replacement} = Tightbeam.Recognition.start_link(db)
    on_exit(fn -> if Process.alive?(replacement), do: GenServer.stop(replacement) end)
    File.write!(gate, "ready")
    retry_now(db, replacement)
    assert_receive :recognized
    assert {:ok, []} = DB.query(db, "SELECT id FROM pending_recognition")
  end

  test "arity one retries a refused delete without republishing", %{db: db} do
    proxy = start_supervised!({DeleteRefusal, db})
    parent = self()

    assert {:ok, :published} =
             DB.transaction_then(proxy, fn _ -> :committed end, fn _ ->
               send(parent, :published_once)
               :published
             end)

    assert_receive :published_once
    refute_receive :published_once
    assert {:ok, []} = DB.query(db, "SELECT id FROM pending_recognition")
  end

  test "both callback arities contain throw and exit and flag after five retry attempts", %{
    db: db,
    retry: retry
  } do
    assert {:ok, :one} =
             DB.transaction_then(db, fn _ -> :one end, fn _ -> exit(:bad_publication) end)

    assert {:ok, :two} =
             DB.transaction_then(db, fn _ -> :two end, fn _, _ -> throw(:bad_recognition) end)

    for _ <- 1..5 do
      {:ok, before_rows} = DB.query(db, "SELECT id,attempts FROM pending_recognition")
      before_attempts = Map.new(before_rows, fn [id, attempts] -> {id, attempts} end)
      started = System.system_time(:millisecond)
      retry_now(db, retry)
      {:ok, after_rows} = DB.query(db, "SELECT id,attempts,nextAt FROM pending_recognition")

      changed = Enum.filter(after_rows, fn [id, attempt, _] -> attempt > before_attempts[id] end)
      assert length(changed) == 2

      for [_id, attempt, next_at] <- changed do
        assert next_at >= started + trunc(:math.pow(2, attempt - 1)) * 1_000
      end
    end

    assert {:ok, [[5, 1], [5, 1]]} =
             DB.query(db, "SELECT attempts,flagged FROM pending_recognition ORDER BY id")

    assert Process.alive?(retry)
    assert Process.alive?(db)
  end

  test "recognition deadline failure cannot replace a primary commit near its deadline", %{
    db: db,
    retry: retry
  } do
    # This case isolates the inline deadline. Automatic retry has its own cases.
    GenServer.stop(retry)
    parent = self()
    old = Application.get_env(:tightbeam, :db_call_timeout_ms)
    Application.put_env(:tightbeam, :db_call_timeout_ms, 500)

    on_exit(fn ->
      if old,
        do: Application.put_env(:tightbeam, :db_call_timeout_ms, old),
        else: Application.delete_env(:tightbeam, :db_call_timeout_ms)
    end)

    assert {:ok, :committed} =
             DB.transaction_then(
               db,
               fn txn ->
                 Txn.q(txn, "INSERT INTO recognized_rows VALUES(1)")
                 send(parent, {:primary_deadline, txn.deadline})
                 Process.sleep(100)
                 :committed
               end,
               fn txn, _ ->
                 send(parent, {:recognition_deadline, txn.deadline})
                 Process.sleep(600)
                 Txn.q(txn, "INSERT INTO recognized_rows VALUES(2)")
               end
             )

    assert_receive {:primary_deadline, primary_deadline}
    assert_receive {:recognition_deadline, recognition_deadline}
    assert recognition_deadline <= primary_deadline
    assert {:ok, [[1]]} = DB.query(db, "SELECT id FROM recognized_rows")
    assert {:ok, [[0]]} = DB.query(db, "SELECT flagged FROM pending_recognition")
  end

  test "recognition returning an error is rolled back and leaves pending work", %{db: db} do
    assert {:ok, :committed} =
             DB.transaction_then(db, fn _ -> :committed end, fn txn, _ ->
               Txn.q(txn, "INSERT INTO recognized_rows VALUES(2)")
               {:error, :recognition_failed}
             end)

    assert {:ok, []} = DB.query(db, "SELECT id FROM recognized_rows")
    assert {:ok, [[0]]} = DB.query(db, "SELECT flagged FROM pending_recognition")
  end

  test "the retry worker never overlaps an active inline publication", %{db: db, retry: retry} do
    parent = self()

    caller =
      Task.async(fn ->
        DB.transaction_then(db, fn _ -> :committed end, fn _ ->
          send(parent, {:publication, self()})
          receive do: (:release -> :published)
        end)
      end)

    assert_receive {:publication, pid}
    assert pid == caller.pid
    send(retry, :retry)
    :sys.get_state(retry)
    refute_receive {:publication, _}, 30
    send(caller.pid, :release)
    assert {:ok, :published} = Task.await(caller)
    assert {:ok, []} = DB.query(db, "SELECT id FROM pending_recognition")
  end

  test "a failed inline callback arms its retry from the committed row", %{db: db, retry: retry} do
    parent = self()
    calls = :atomics.new(1, [])
    old = Application.get_env(:tightbeam, :db_call_timeout_ms)
    Application.put_env(:tightbeam, :db_call_timeout_ms, 500)

    on_exit(fn ->
      if old,
        do: Application.put_env(:tightbeam, :db_call_timeout_ms, old),
        else: Application.delete_env(:tightbeam, :db_call_timeout_ms)
    end)

    assert {:ok, :committed} =
             DB.transaction_then(db, fn _ -> :committed end, fn _ ->
               if :atomics.add_get(calls, 1, 1) == 1, do: raise("first attempt")
               send(parent, :automatic_retry)
               :recognized
             end)

    state = :sys.get_state(retry)
    assert state.timer != nil
    assert {:ok, [[next_at]]} = DB.query(db, "SELECT nextAt FROM pending_recognition")
    assert next_at <= System.system_time(:millisecond) + 500
    assert_receive :automatic_retry, 1_500
    assert :sys.get_state(retry).timer == nil
    assert {:ok, []} = DB.query(db, "SELECT id FROM pending_recognition")
  end

  test "idle retries make no database calls between events", %{db: db, retry: retry} do
    assert :sys.get_state(retry).timer == nil
    :erlang.trace(db, true, [:receive])
    refute_receive {:trace, ^db, :receive, {:"$gen_call", _, _}}, 1_200
    :erlang.trace(db, false, [:receive])
  end

  test "a committed retry moves the deadline timer earlier and fires without polling", %{
    db: db,
    retry: retry
  } do
    parent = self()

    assert {:ok, pending} =
             DB.transaction(db, fn txn ->
               pending =
                 Tightbeam.Recognition.record(
                   txn,
                   fn _ -> send(parent, :timer_recognized) end,
                   :value,
                   [],
                   []
                 )

               Txn.q(txn, "UPDATE pending_recognition SET nextAt=?1 WHERE id=?2", [
                 System.system_time(:millisecond) + 200,
                 pending.id
               ])

               pending
             end)

    GenServer.cast(retry, :reschedule)
    assert :sys.get_state(retry).due_at != nil
    assert_receive :timer_recognized, 1_000
    assert :sys.get_state(retry).timer == nil

    assert {:ok, []} =
             DB.query(db, "SELECT id FROM pending_recognition WHERE id=?1", [pending.id])
  end

  test "the consistency check repairs and counts a suppressed retry signal", %{
    db: db,
    retry: retry
  } do
    parent = self()
    assert :sys.get_state(retry).timer == nil

    {:ok, pending} =
      DB.transaction(db, fn txn ->
        pending =
          Tightbeam.Recognition.record(
            txn,
            fn _ -> send(parent, :miss_recognized) end,
            :value,
            [],
            []
          )

        Txn.q(txn, "UPDATE pending_recognition SET nextAt=0 WHERE id=?1", [pending.id])
        pending
      end)

    before = Tightbeam.SchedulerMisses.count()

    log =
      capture_log(fn ->
        send(retry, :check_misses)
        :sys.get_state(retry)
      end)

    assert_receive :miss_recognized
    assert Tightbeam.SchedulerMisses.count() == before + 1
    assert log =~ "loop=recognition record=#{pending.id}"
    assert {:ok, []} = DB.query(db, "SELECT id FROM pending_recognition")
  end

  defp retry_now(db, retry) do
    :ok = DB.execute(db, "UPDATE pending_recognition SET nextAt=0 WHERE flagged=0")
    send(retry, :retry)
    :sys.get_state(retry)
  end
end
