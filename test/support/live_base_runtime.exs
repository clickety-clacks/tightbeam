[payload, base, locks] = System.argv()
payload = Path.expand(payload)
^payload = Application.app_dir(:tightbeam) |> Path.expand()
false = File.exists?(base)
{:ok, _} = Application.ensure_all_started(:exqlite)
{:ok, _} = Application.ensure_all_started(:crypto)
Application.put_env(:tightbeam, :autostart, false)
Application.put_env(:tightbeam, :base_dir, base)
alias Tightbeam.{DB, LiveBaseAdmission, LiveBaseLock, Schema}

{:ok, db} =
  DB.start_link(path: Path.join(base, "state.db"), name: nil, guard_inputs: [lock_dir: locks])

false = File.exists?(Path.join(base, "build-owner.json"))
:ok = Schema.ensure_all(db)
:ok = DB.assert_base_admitted!(db, base)
{:ok, [[stamp]]} = DB.query(db, "SELECT shape FROM schema_stamp", [])
true = stamp == hd(Schema.guard_compatible_stamps())
marker = File.read!(Path.join(base, "build-owner.json"))
:ok = Schema.ensure_all(db)
^marker = File.read!(Path.join(base, "build-owner.json"))
key = :crypto.hash(:sha256, base) |> Base.encode16(case: :lower)
lock_path = Path.join(locks, key <> ".lock")
{:error, :lock_busy} = LiveBaseLock.acquire(lock_path)
:ok = GenServer.stop(db)
# Resource-owner DOWN delivery can follow the stop reply; wait only for the
# actual kernel lock, without substituting an independent lifetime monitor.
await = fn recur, remaining ->
  case LiveBaseLock.acquire(lock_path) do
    {:ok, lock} ->
      :ok = LiveBaseLock.release(lock)

    {:error, :lock_busy} when remaining > 0 ->
      Process.sleep(10)
      recur.(recur, remaining - 1)

    other ->
      raise "lock did not release: #{inspect(other)}"
  end
end

await.(await, 100)
context = LiveBaseAdmission.prepare!(base, payload_root: payload, lock_dir: locks)

{:ok, second} =
  DB.start_link(path: Path.join(base, "state.db"), name: nil, guard_context: context)

:ok = Schema.ensure_all(second)
:ok = DB.assert_base_admitted!(second, base)
{:error, :not_lock_owner} = LiveBaseLock.release(context.lock)
{:error, :lock_busy} = LiveBaseLock.acquire(lock_path)
^marker = File.read!(Path.join(base, "build-owner.json"))
:ok = GenServer.stop(second)
await.(await, 100)
IO.puts("persistent-owner-refresh-handoff: ok")
