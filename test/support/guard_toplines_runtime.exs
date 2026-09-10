defmodule ToplinesCrashSnapshot do
  alias Tightbeam.DB

  def snapshot(db) do
    {:ok, schema} =
      DB.query(
        db,
        "SELECT type, name, sql FROM sqlite_schema WHERE name NOT LIKE 'sqlite_%' ORDER BY type, name"
      )

    rows =
      for table <- ~w(
            toplines topline_work_memberships topline_concerns topline_concern_refs
            topline_events topline_idempotency topline_placement_obligations
            topline_schema_stamp
          ),
          {:ok, [[1]]} <- [
            DB.query(
              db,
              "SELECT EXISTS(SELECT 1 FROM sqlite_schema WHERE type='table' AND name=?1)",
              [table]
            )
          ],
          into: %{} do
        {:ok, values} = DB.query(db, "SELECT * FROM #{table} ORDER BY rowid")
        {table, values}
      end

    {schema, rows}
  end
end

[payload, base, locks] = System.argv()
true = Path.expand(payload) == Path.expand(Application.app_dir(:tightbeam))
false = File.exists?(base)
{:ok, _} = Application.ensure_all_started(:exqlite)
{:ok, _} = Application.ensure_all_started(:crypto)
Application.put_env(:tightbeam, :autostart, false)
Application.put_env(:tightbeam, :base_dir, base)
Application.put_env(:ex_unit, :assert_receive_timeout, 1_000)
import ExUnit.Assertions
alias Tightbeam.{DB, Schema}
path = Path.join(base, "state.db")

alias Tightbeam.Toplines.Schema, as: ToplinesSchema
db = :guard_toplines_crash
{:ok, first} = DB.start_link(path: path, name: db, guard_inputs: [lock_dir: locks])
Process.unlink(first)

try do
  :ok = Schema.ensure_all(db)
  :ok = DB.assert_base_admitted!(db, base)
  marker = File.read!(Path.join(base, "build-owner.json"))
  :ok = DB.execute(db, "INSERT INTO users (userId, isAdmin, createdAt) VALUES ('mike', 1, 1)")
  assert :ok = ToplinesSchema.activate(db, 123)

  assert {:ok, []} =
           DB.query(db, """
           INSERT INTO toplines (id, ownerUserId, title, state, createdActorKind, createdActorRef, createdAt, updatedAt, closedAt)
           VALUES ('tl_durable', 'mike', 'Durable', 'open', 'user', 'mike', 1, 1, NULL)
           """)

  before = ToplinesCrashSnapshot.snapshot(db)
  monitor = Process.monitor(first)
  Process.exit(first, :kill)
  assert_receive {:DOWN, ^monitor, :process, ^first, :killed}, 1_000

  lock_path =
    Path.join(locks, Base.encode16(:crypto.hash(:sha256, base), case: :lower) <> ".lock")

  await = fn recur, remaining ->
    case Tightbeam.LiveBaseLock.acquire(lock_path) do
      {:ok, lock} ->
        :ok = Tightbeam.LiveBaseLock.release(lock)

      {:error, :lock_busy} when remaining > 0 ->
        Process.sleep(10)
        recur.(recur, remaining - 1)

      other ->
        raise "lock release failed: #{inspect(other)}"
    end
  end

  await.(await, 100)
  {:ok, second} = DB.start_link(path: path, name: db, guard_inputs: [lock_dir: locks])
  Process.unlink(second)
  :ok = Schema.ensure_all(db)
  assert :ok = ToplinesSchema.activate(db, 999)
  assert ToplinesCrashSnapshot.snapshot(db) == before
  assert File.read!(Path.join(base, "build-owner.json")) == marker
  :ok = DB.assert_base_admitted!(db, base)
after
  if pid = Process.whereis(db), do: GenServer.stop(pid)
end

IO.puts("guarded-toplines-crash: ok")
