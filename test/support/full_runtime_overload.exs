alias Tightbeam.{Boot, DB, Harness}

[payload, base] = System.argv()
true = Path.expand(payload) == Path.expand(Application.app_dir(:tightbeam))
arena = Path.expand(base)
^arena = System.fetch_env!("TIGHTBEAM_BASE_DIR") |> Path.expand()
"test" = System.fetch_env!("MIX_ENV")

{:ok, _} = Application.ensure_all_started(:exqlite)
{:ok, _} = Application.ensure_all_started(:crypto)
System.put_env("RECOVERY_FIXTURE_ARENA", arena)
Application.put_env(:tightbeam, :autostart, false)
Application.put_env(:tightbeam, :base_dir, base)
Application.put_env(:tightbeam, :fixture_harness, true)
Application.put_env(:tightbeam, :local_host_name, "testhost")
Application.put_env(:tightbeam, :kungfu_bundle_root_dir, Path.expand("fixtures/kungfu", __DIR__))

false = File.exists?(base)
{:ok, db} = DB.start_link(path: Path.join(base, "state.db"), name: DB, guard_inputs: [])
:ignore = Boot.start_link(%{base_dir: base})
:ok = GenServer.stop(db)
{:ok, candidate_law} = Tightbeam.Identity.learn!(base, "agentic-engineering", "test")
{:ok, _revision} = Tightbeam.Identity.publish_live!(base, candidate_law)
File.write!(Path.join(base, ".soak-arena"), "tightbeam recovery acceptance arena v1\n")
Tightbeam.RecoveryFixture.place_adapter!(base, seed_credential: false)

tripwire = Path.join(base, "forbidden-execution.log")
bin = Path.join(base, "fixture-bin")
File.mkdir_p!(bin)

for name <- ["claude", "codex", "fixture"] do
  path = Path.join(bin, name)

  File.write!(path, """
  #!/bin/sh
  if [ '#{name}' = codex ] && [ "$#" = 2 ] && [ "$1" = --dangerously-bypass-hook-trust ] && [ "$2" = --version ]; then
    shift
  fi
  if [ "$#" = 1 ] && [ "$1" = --version ]; then
    echo '#{name} fixture-only 0.0.0'
    exit 0
  fi
  echo '#{name}: forbidden non-probe' >> "$GUARD_TRIPWIRE"
  exit 64
  """)

  File.chmod!(path, 0o755)
end

for name <- ["npm", "ssh"] do
  path = Path.join(bin, name)
  File.write!(path, "#!/bin/sh\necho '#{name}: forbidden' >> \"$GUARD_TRIPWIRE\"\nexit 64\n")
  File.chmod!(path, 0o755)
end

System.put_env("GUARD_TRIPWIRE", tripwire)
System.put_env("PATH", bin <> ":" <> System.fetch_env!("PATH"))
for module <- Harness.all(), key <- module.credential_env_vars(), do: System.delete_env(key)

Application.put_env(:tightbeam, :drain_timeout_ms, 1_000)
Application.put_env(:tightbeam, :base_dir, arena)
Application.put_env(:tightbeam, :cwd, Path.join(arena, "work"))
Application.put_env(:tightbeam, :port, 0)
Application.put_env(:tightbeam, :default_harness, :fixture)
Application.put_env(:tightbeam, :default_model, Tightbeam.Model.new("fixture-model"))
Application.put_env(:tightbeam, :autostart, true)
File.mkdir_p!(Path.join(arena, "work"))
arena_tmp = Path.join(arena, "tmp")
File.mkdir_p!(arena_tmp)
System.put_env("TMPDIR", arena_tmp)

{:ok, _apps} = Application.ensure_all_started(:tightbeam)

%{user_id: "recovery-admin", is_admin: true} =
  Tightbeam.Devices.add_user(Tightbeam.DB, "recovery-admin", false)

config = %{
  base_dir: arena,
  cwd: Path.join(arena, "work"),
  port: 0,
  db: Tightbeam.DB,
  default_harness: :fixture,
  default_model: Tightbeam.Model.new("fixture-model"),
  max_live_sessions_per_user: Application.get_env(:tightbeam, :max_live_sessions_per_user),
  wake_tick_ms: 1_000,
  prod_limit: 3,
  escalation_decision_deadline_ms: 86_400_000,
  critical_lease_hard_cap_ms: 14_400_000,
  onboarding_lease_ms: 1_800_000
}

handlers = Tightbeam.Gateway.handlers(config)
onboard = handlers["onboard"]
call = %{origin: "user:recovery-admin", params: %{provider: "fixture-provider"}}

%{provider: :fixture_provider, status: "ready", staging_path: staging, lease_id: lease} =
  onboard.(put_in(call.params[:phase], "begin"))

File.write!(Path.join(Path.expand(staging), "fixture.json"), "fixture-provider-credential")

%{provider: :fixture_provider, status: "onboarded"} =
  onboard.(call |> put_in([:params, :phase], "finish") |> put_in([:params, :lease_id], lease))

:onboarded = Tightbeam.Credentials.status(:fixture_provider)
Tightbeam.Readiness.await_settled()

import ExUnit.Assertions
alias Tightbeam.{Model, Org, Wakes}

key = "agent:overload:recipient"

Org.create(DB, %{
  session_key: key,
  display_name: "Overload recipient",
  owner_user_id: "recovery-admin",
  origin: "user:recovery-admin",
  archetype: "agentic-engineering.coder",
  identity_name: "agentic-engineering.coder",
  identity_revision: Tightbeam.Identity.live_revision!(arena),
  host: "testhost",
  harness: "fixture",
  provider: "fixture_provider",
  model: Model.new("fixture-model")
})

# Settle startup recovery, including the Harklight listener manager, before measuring.
for name <- [
      Tightbeam.WakeScheduler,
      Tightbeam.LaneManager,
      Tightbeam.HarklightWakes
    ],
    do: :sys.get_state(name)

runtime = Process.whereis(Tightbeam.RuntimeSupervisor)

children = fn ->
  Supervisor.which_children(runtime)
  |> Map.new(fn {id, pid, _, _} -> {id, pid} end)
end

before = children.()
root = Process.whereis(Tightbeam.Supervisor)

listener =
  Enum.find_value(before, fn
    {{Bandit, _}, pid} -> pid
    {Bandit, pid} -> pid
    _ -> nil
  end)

assert is_pid(listener)
{:ok, {_address, port}} = ThousandIsland.listener_info(listener)

http_ok = fn ->
  {:ok, socket} = :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false], 1_000)

  :ok =
    :gen_tcp.send(socket, "GET /version HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n")

  {:ok, response} = :gen_tcp.recv(socket, 0, 2_000)
  :gen_tcp.close(socket)
  assert response =~ "HTTP/1.1 200"
end

http_ok.()

# Keep the scheduler at its boundary while recording one durable delivery.
:ok = :sys.suspend(Tightbeam.WakeScheduler)

wake =
  Wakes.schedule(DB, %{
    session_key: key,
    origin: "process:tightbeam",
    prompt: "overload durable wake",
    due_at: System.system_time(:millisecond),
    consumer: "prompt",
    target_gate: 1
  })

owner = Process.whereis(DB)
:ok = :sys.suspend(owner)

for _ <- 1..128,
    do: send(owner, {:"$gen_call", {self(), make_ref()}, {:query, "SELECT 1", []}})

assert DB.overloaded?(DB)

# This is the synchronous production entry in the failed independent review.
# Queue it first, so due delivery cannot mask which callback meets refusal.
nudge = Task.async(fn -> Wakes.nudge_matching(Tightbeam.WakeScheduler, 1) end)
:ok = :sys.resume(Tightbeam.WakeScheduler)
send(Tightbeam.HarnessHealth.RecoveryScheduler, :resume_due)
GenServer.cast(Tightbeam.HarklightWakes, {:origin_ready, key})
send(Tightbeam.WorkspaceCleanup, :drain)
GenServer.cast(Tightbeam.Productions.BubbleSweeper, {:recognize, 0})

try do
  for _ <- 1..10 do
    http_ok.()
    Process.sleep(30)
  end

  assert Process.alive?(root)
  assert children.() == before
  assert Enum.all?(before, fn {_id, pid} -> is_pid(pid) and Process.alive?(pid) end)
  assert Task.yield(nudge, 0) == nil
  :ok = :sys.resume(owner)
  Task.await(nudge, 10_000)
  :ok = Wakes.fire_due(Tightbeam.WakeScheduler)
  deadline = System.monotonic_time(:millisecond) + 15_000

  wait = fn wait ->
    {:ok, rows} =
      DB.query(
        DB,
        "SELECT t.status FROM turns t JOIN wakes w ON w.deliveredTurnSeq=t.seq WHERE w.wakeId=?1",
        [wake.wake_id]
      )

    if rows != [["delivered"]] do
      assert System.monotonic_time(:millisecond) < deadline, inspect(rows)
      Process.sleep(25)
      wait.(wait)
    end
  end

  wait.(wait)
  :ok = Wakes.fire_due(Tightbeam.WakeScheduler)
  {:ok, [[1]]} = DB.query(DB, "SELECT COUNT(*) FROM turns WHERE sessionKey=?1", [key])
  assert children.() == before
  http_ok.()
  refute File.exists?(tripwire)
  IO.puts("full-runtime-overload: listener survived; durable wake delivered once")
after
  :sys.resume(owner)
end

# A service can restart for an unrelated reason during a refusal interval.
# Its initialization must wait, while the existing listener remains available.
for child <- [Wakes, Tightbeam.LaneManager, Tightbeam.HarnessHealth.RecoveryScheduler] do
  :ok = Supervisor.terminate_child(runtime, child)
  :ok = :sys.suspend(owner)

  for _ <- 1..128,
      do: send(owner, {:"$gen_call", {self(), make_ref()}, {:query, "SELECT 1", []}})

  assert DB.overloaded?(DB)
  restart = Task.async(fn -> Supervisor.restart_child(runtime, child) end)

  try do
    assert Task.yield(restart, 200) == nil
    http_ok.()
    assert Process.alive?(root)
    assert Process.alive?(listener)
  after
    :sys.resume(owner)
  end

  assert {:ok, restarted} = Task.await(restart, 10_000)
  assert Process.alive?(restarted)
  assert Process.whereis(Tightbeam.Supervisor) == root
  http_ok.()
end

IO.puts("full-runtime-overload: startup recovery waits without restart cascade")

Application.stop(:tightbeam)
