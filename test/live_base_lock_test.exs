defmodule Tightbeam.LiveBaseLockTest do
  use Tightbeam.TestCase, async: false
  alias Tightbeam.LiveBaseLock, as: Lock
  alias Exqlite.Sqlite3
  @moduletag :tmp_dir
  @tag native_sigkill: true
  test "SIGKILL releases only the terminated VM SQLite lock attachment", %{tmp_dir: tmp} do
    Tightbeam.GuardRuntimeFixture.run!(
      tmp,
      "live_base_lock_sigkill.exs",
      "native-lock-sigkill: ok"
    )

    IO.puts(File.read!(Path.join(tmp, "runtime.log")))
  end

  @tag cross_vm_lock: true
  test "separate VM respects exclusion and abrupt VM exit releases SQLite attachment", %{
    tmp_dir: tmp
  } do
    busy_tmp = Path.join(tmp, "busy")
    locks = Path.join(busy_tmp, "locks")
    File.mkdir_p!(locks)
    File.chmod!(locks, 0o700)
    path = Path.join(locks, "cross-vm.lock")
    assert {:ok, lock} = Lock.acquire(path)

    try do
      Tightbeam.GuardRuntimeFixture.run!(
        busy_tmp,
        "live_base_lock_cross_vm_busy.exs",
        "cross-vm-busy: ok"
      )

      assert {:error, :lock_busy} = Lock.acquire(path)
    after
      :ok = Lock.release(lock)
    end

    death_tmp = Path.join(tmp, "death")

    Tightbeam.GuardRuntimeFixture.run!(
      death_tmp,
      "live_base_lock_cross_vm_exit.exs",
      "cross-vm-attached-before-exit: ok",
      exit: 23
    )

    death_path = Path.join([death_tmp, "locks", "cross-vm.lock"])
    inode = File.stat!(death_path).inode
    assert {:ok, replacement} = Lock.acquire(death_path)

    try do
      assert File.stat!(death_path).inode == inode
      assert File.ls!(Path.dirname(death_path)) == ["cross-vm.lock"]
    after
      :ok = Lock.release(replacement)
    end
  end

  @tag db_owner_death: true
  test "DB owner death retains exclusion until its surviving SQLite statement finalizes", %{
    tmp_dir: tmp
  } do
    path = Path.join(tmp, "db-owner-death.lock")
    assert {:ok, lock} = Lock.acquire(path)
    inode = File.stat!(path).inode
    assert {:ok, db} = Tightbeam.DB.start_link(path: ":memory:", name: nil)
    Process.unlink(db)
    monitor = Process.monitor(db)

    try do
      assert {:ok, {conn, statement}} =
               Tightbeam.DB.transaction(db, fn txn ->
                 :ok = Lock.attach_sqlite!(lock, txn.conn)
                 {:ok, statement} = Sqlite3.prepare(txn.conn, "SELECT 1")
                 {txn.conn, statement}
               end)

      try do
        assert {:error, :lock_busy} = Lock.acquire(path)
        Process.exit(db, :kill)
        assert_receive {:DOWN, ^monitor, :process, ^db, :killed}
        refute Process.alive?(db)
        assert {:error, :lock_busy} = Lock.acquire(path)

        # The retained connection is still real and usable after owner death.
        assert :ok = Sqlite3.execute(conn, "SELECT 1")
        assert :ok = Sqlite3.close(conn)
        assert {:error, :lock_busy} = Lock.acquire(path)
        assert :ok = Sqlite3.release(conn, statement)
        assert {:ok, replacement} = acquire_after_down(path, 100)

        try do
          assert File.stat!(path).inode == inode
          assert File.ls!(tmp) == ["db-owner-death.lock"]
        after
          :ok = Lock.release(replacement)
        end
      after
        # Also close/finalize on an assertion failure; these return errors if
        # already closed/finalized, without changing the original failure.
        _ = Sqlite3.release(conn, statement)
        _ = Sqlite3.close(conn)
      end
    after
      if Process.alive?(db), do: GenServer.stop(db)
      Process.demonitor(monitor, [:flush])
      _ = Lock.release(lock)
    end
  end

  test "attachment API retains lock through close and closes failed attachment", %{tmp_dir: tmp} do
    path = Path.join(tmp, "api.lock")
    assert {:ok, resource} = Lock.acquire(path)
    assert {:ok, conn} = Sqlite3.open(":memory:")
    assert :ok = Lock.attach_sqlite!(resource, conn)
    assert :ok = Lock.release(resource)
    assert {:error, :lock_busy} = Lock.acquire(path)
    assert :ok = Sqlite3.close(conn)
    assert {:ok, replacement} = Lock.acquire(path)
    assert :ok = Lock.release(replacement)
    assert {:ok, rejected} = Sqlite3.open(":memory:")
    assert_raise MatchError, fn -> Lock.attach_sqlite!(replacement, rejected) end
    assert {:error, _} = Sqlite3.execute(rejected, "SELECT 1")
  end

  test "DB normal teardown closes retained native SQLite connection", %{tmp_dir: tmp} do
    path = Path.join(tmp, "db.lock")
    assert {:ok, resource} = Lock.acquire(path)
    db = start_supervised!({Tightbeam.DB, path: ":memory:", name: nil})

    assert {:ok, :ok} =
             Tightbeam.DB.transaction(db, fn txn ->
               Lock.attach_sqlite!(resource, txn.conn)
             end)

    assert {:error, :lock_busy} = Lock.acquire(path)
    GenServer.stop(db)
    assert {:ok, replacement} = acquire_after_down(path, 100)
    assert :ok = Lock.release(replacement)
  end

  test "release and transfer revoke pending attachment capabilities", %{tmp_dir: tmp} do
    assert {:ok, lock} = Lock.acquire(Path.join(tmp, "revoke.lock"))
    assert {:ok, token} = Lock.attachment_token(lock)
    assert :ok = Lock.claim(lock)
    assert {:ok, next_token} = Lock.attachment_token(lock)
    assert :ok = Lock.release(lock)
    assert {:ok, conn} = Sqlite3.open(":memory:")
    assert :ok = Sqlite3.enable_load_extension(conn, true)

    assert [[nil]] =
             Tightbeam.DB.run_query(
               conn,
               "SELECT load_extension(?1, 'sqlite3_livebaselock_init')",
               [Application.app_dir(:tightbeam, "priv/live_base_lock.so")]
             )

    assert :ok = Sqlite3.enable_load_extension(conn, false)

    for stale <- [token, next_token] do
      assert_raise Tightbeam.DB.Error, fn ->
        Tightbeam.DB.run_query(conn, "SELECT tightbeam_attach_base_lock(?1)", [stale])
      end
    end

    assert :ok = Sqlite3.close(conn)
    assert {:ok, replacement} = Lock.acquire(Path.join(tmp, "revoke.lock"))
    assert :ok = Lock.release(replacement)
  end

  test "SQLite deferred close retains descriptor until surviving statement finalizes", %{
    tmp_dir: tmp
  } do
    path = Path.join(tmp, "deferred.lock")
    assert {:ok, lock} = Lock.acquire(path)
    assert {:ok, fd} = Lock.attachment_token(lock)
    assert {:ok, conn} = Sqlite3.open(":memory:")
    assert :ok = Sqlite3.enable_load_extension(conn, true)
    extension = Application.app_dir(:tightbeam, "priv/live_base_lock.so")

    assert [[nil]] =
             Tightbeam.DB.run_query(
               conn,
               "SELECT load_extension(?1, 'sqlite3_livebaselock_init')",
               [extension]
             )

    assert :ok = Sqlite3.enable_load_extension(conn, false)
    assert [[1]] = Tightbeam.DB.run_query(conn, "SELECT tightbeam_attach_base_lock(?1)", [fd])
    assert {:ok, statement} = Sqlite3.prepare(conn, "SELECT 1")
    assert :ok = Lock.release(lock)
    assert {:error, :lock_busy} = Lock.acquire(path)
    assert :ok = Sqlite3.close(conn)
    assert {:error, :lock_busy} = Lock.acquire(path)
    assert :ok = Sqlite3.release(conn, statement)
    assert {:ok, next} = Lock.acquire(path)
    assert :ok = Lock.release(next)
  end

  test "dead owner capability cannot attach a reused descriptor", %{tmp_dir: tmp} do
    path = Path.join(tmp, "dead.lock")
    parent = self()

    {pid, monitor} =
      spawn_monitor(fn ->
        {:ok, resource} = Lock.acquire(path)
        {:ok, token} = Lock.attachment_token(resource)
        send(parent, {:token, token})

        receive do
          :stop -> :ok
        end
      end)

    assert_receive {:token, token}
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^pid, :killed}
    assert {:ok, replacement} = acquire_after_down(path, 100)
    assert {:ok, conn} = Sqlite3.open(":memory:")
    assert :ok = Sqlite3.enable_load_extension(conn, true)
    extension = Application.app_dir(:tightbeam, "priv/live_base_lock.so")

    assert [[nil]] =
             Tightbeam.DB.run_query(
               conn,
               "SELECT load_extension(?1, 'sqlite3_livebaselock_init')",
               [extension]
             )

    assert :ok = Sqlite3.enable_load_extension(conn, false)

    assert_raise Tightbeam.DB.Error, fn ->
      Tightbeam.DB.run_query(conn, "SELECT tightbeam_attach_base_lock(?1)", [token])
    end

    assert :ok = Lock.release(replacement)
    assert {:ok, next} = Lock.acquire(path)
    assert :ok = Lock.release(next)
    assert :ok = Sqlite3.close(conn)
  end

  test "descriptor survives transfer and releases on owner death", %{tmp_dir: tmp} do
    path = Path.join(tmp, "base.lock")
    assert {:ok, lock} = Lock.acquire(path)
    inode = File.stat!(path).inode
    assert {:error, :lock_busy} = Lock.acquire(path)
    parent = self()

    child =
      spawn(fn ->
        :ok = Lock.claim(lock)
        send(parent, :claimed)

        receive do
          :stop -> :ok
        end
      end)

    monitor = Process.monitor(child)
    assert_receive :claimed
    assert {:error, :not_lock_owner} = Lock.release(lock)
    assert {:error, :lock_busy} = Lock.acquire(path)
    Process.exit(child, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^child, :killed}
    assert {:ok, next} = acquire_after_down(path, 100)
    assert File.stat!(path).inode == inode
    assert :ok = Lock.release(next)
    assert {:error, :lock_closed} = Lock.claim(lock)
    assert File.ls!(tmp) == ["base.lock"]
  end

  test "symlink and permissive lock files refuse", %{tmp_dir: tmp} do
    path = Path.join(tmp, "base.lock")
    File.write!(path, "")
    File.chmod!(path, 0o644)
    assert {:error, :invalid_lock_file} = Lock.acquire(path)
    link = Path.join(tmp, "alias.lock")
    File.ln_s!(path, link)
    assert {:error, :lock_open_failed} = Lock.acquire(link)
  end

  defp acquire_after_down(path, remaining) do
    case Lock.acquire(path) do
      {:error, :lock_busy} when remaining > 0 ->
        Process.sleep(1)
        acquire_after_down(path, remaining - 1)

      result ->
        result
    end
  end
end
