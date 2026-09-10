import ExUnit.Assertions
alias Tightbeam.LiveBaseLock, as: Lock
alias Exqlite.Sqlite3
[_, _, locks] = System.argv()
{:ok, _} = Application.ensure_all_started(:crypto)
{:ok, _} = Application.ensure_all_started(:exqlite)
path = Path.join(locks, "cross-vm.lock")
assert {:ok, lock} = Lock.acquire(path)
assert {:ok, conn} = Sqlite3.open(":memory:")
assert :ok = Lock.attach_sqlite!(lock, conn)
assert {:ok, statement} = Sqlite3.prepare(conn, "SELECT 1")
assert :ok = Lock.release(lock)
assert {:error, :lock_busy} = Lock.acquire(path)
# Keep both actual resources live until an abrupt VM halt. No normal DB close,
# statement finalization, or application shutdown callback releases this lock.
assert is_reference(conn) and is_reference(statement)
IO.puts("cross-vm-attached-before-exit: ok")
System.halt(23)
