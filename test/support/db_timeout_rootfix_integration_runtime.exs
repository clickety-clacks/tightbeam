[payload, base, locks] = System.argv()
payload = Path.expand(payload)
^payload = Application.app_dir(:tightbeam) |> Path.expand()
false = File.exists?(base)

{:ok, _} = Application.ensure_all_started(:exqlite)
{:ok, _} = Application.ensure_all_started(:crypto)
Application.put_env(:tightbeam, :autostart, false)
Application.put_env(:tightbeam, :base_dir, base)
Application.put_env(:ex_unit, :assert_receive_timeout, 1_000)

alias Tightbeam.{Boot, DB, Ledger, Model, ModelCatalog, Org, SessionLane, Wakes}
import ExUnit.Assertions

{:ok, db} =
  DB.start_link(path: Path.join(base, "state.db"), name: DB, guard_inputs: [lock_dir: locks])

:ignore = Boot.start_link(%{base_dir: base})

for session_key <- ["lane-rootfix", "wake-rootfix"] do
  Org.create(db, %{
    session_key: session_key,
    display_name: session_key,
    owner_user_id: "rootfix-owner",
    origin: "user:rootfix-owner",
    archetype: "default",
    host: Tightbeam.Placement.local_host_name(),
    harness: "claude",
    provider: "anthropic",
    model: Model.new("fable")
  })
end

{:ok, task_sup} = Task.Supervisor.start_link([])
{:ok, _registry} = Registry.start_link(keys: :unique, name: Tightbeam.LaneRegistry)

{:ok, catalog} =
  ModelCatalog.start_link(
    base_dir: base,
    db: db,
    credential_status: fn _provider, _host -> {:needs_onboarding, :rootfix_fixture} end,
    name: :rootfix_model_catalog
  )

# Complete one ordinary read first. The trigger below must exercise the
# catalog's real Placement.hosts/2 database read, not a hosts test double.
catalog_before = ModelCatalog.get(catalog)
true = is_map(catalog_before)

parent = self()

{:ok, scheduler} =
  Wakes.start_link(
    db: db,
    name: :rootfix_wake_scheduler,
    tick_ms: 60_000,
    deliver: fn wake -> send(parent, {:wake_delivered, wake.wake_id}) end
  )

wake =
  Wakes.schedule(db, %{
    session_key: "wake-rootfix",
    origin: "user:rootfix-owner",
    owner_user_id: "rootfix-owner",
    prompt: "wake through the stalled owner",
    due_at: System.system_time(:millisecond)
  })

runner = fn turn ->
  send(parent, {:runner_started, turn.seq, self()})

  receive do
    :release_runner -> {:ok, %{text: "lane complete"}}
  end
end

{:ok, lane} =
  SessionLane.start_link(
    session_key: "lane-rootfix",
    db: db,
    task_sup: task_sup,
    runner: runner,
    on_terminal: fn session_key, seq -> send(parent, {:lane_terminal, session_key, seq}) end
  )

{:ok, lane_seq} =
  Ledger.enqueue(db, %{
    session_key: "lane-rootfix",
    message_id: "m_rootfix_lane",
    origin: "user:rootfix-owner",
    prompt: "finalize through the stalled owner"
  })

# The initial nudge can run before enqueue; the explicit nudge plus this barrier
# makes the runner's execution the fact that opens the trigger window.
:ok = SessionLane.nudge("lane-rootfix")

{_, runner_pid} =
  receive do
    {:runner_started, ^lane_seq, pid} -> {lane_seq, pid}
  after
    1_000 -> raise "lane runner did not start"
  end

wake_id = wake.wake_id

publication =
  Task.async(fn ->
    DB.transaction_then(
      db,
      fn _txn -> :prepared end,
      fn :prepared ->
        send(parent, {:publication_started, self()})

        receive do
          :release_publication -> :published
        end
      end
    )
  end)

publication_pid =
  receive do
    {:publication_started, pid} -> pid
  after
    1_000 -> raise "publication callback did not start"
  end

wake_task = Task.async(fn -> Wakes.fire_due(scheduler) end)
catalog_task = Task.async(fn -> ModelCatalog.get(catalog) end)
boot_task = Task.async(fn -> Boot.start_link(%{base_dir: base}) end)
send(runner_pid, :release_runner)

wake_before_release = Task.yield(wake_task, 1_000)
catalog_before_release = Task.yield(catalog_task, 1_000)
boot_before_release = Task.yield(boot_task, 1_000)

assert {:ok, :ok} = wake_before_release
assert {:ok, inventories} = catalog_before_release
assert is_map(inventories)
assert {:ok, :ignore} = boot_before_release

assert_receive {:wake_delivered, ^wake_id}
assert_receive {:lane_terminal, "lane-rootfix", ^lane_seq}

send(publication_pid, :release_publication)
assert {:ok, :published} = Task.await(publication)

assert Wakes.get(db, wake.wake_id).state == "fired"
assert {:ok, [["delivered"]]} = DB.query(db, "SELECT status FROM turns WHERE seq=?1", [lane_seq])
assert Process.alive?(catalog)
assert Process.alive?(scheduler)
assert Process.alive?(lane)
assert :ok = GenServer.stop(lane)
assert :ok = GenServer.stop(catalog)
assert :ok = GenServer.stop(scheduler)
assert :ok = GenServer.stop(task_sup)
assert :ok = GenServer.stop(db)

IO.puts("db-timeout-rootfix-integration: ok")
