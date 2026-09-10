[payload, base, locks] = System.argv()
payload = Path.expand(payload)
^payload = Application.app_dir(:tightbeam) |> Path.expand()
false = File.exists?(base)
{:ok, _} = Application.ensure_all_started(:exqlite)
{:ok, _} = Application.ensure_all_started(:crypto)
Application.put_env(:tightbeam, :autostart, false)
Application.put_env(:tightbeam, :base_dir, base)
Application.put_env(:tightbeam, :fixture_harness, true)
Application.put_env(:tightbeam, :local_host_name, "testhost")
alias Tightbeam.{AdapterCoordinator, Boot, DB, HarnessProcess, LiveBaseLock, Model}

{:ok, db} =
  DB.start_link(path: Path.join(base, "state.db"), name: DB, guard_inputs: [lock_dir: locks])

:ignore = Boot.start_link(%{base_dir: base})
:ok = GenServer.stop(db)
key = :crypto.hash(:sha256, base) |> Base.encode16(case: :lower)
lock_path = Path.join(locks, key <> ".lock")

await_lock = fn recur, remaining ->
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

await_lock.(await_lock, 100)
File.write!(Path.join(base, ".soak-arena"), "tightbeam recovery acceptance arena v1\n")
fixture = Tightbeam.RecoveryFixture.place_adapter!(base, seed_credential: false)
escape_identity = Path.join(base, "application-stop-escapee.identity")

File.write!(
  fixture.bundle,
  File.read!(fixture.bundle) <>
    """

    const childProcess = require("node:child_process");
    const escapee = childProcess.spawn(
      path.join(arena, "bin", "tightbeam"),
      ["harness-exec", #{JSON.encode!(escape_identity)}, "application-stop-escapee", "--", "/bin/sleep", "400"],
      { stdio: "ignore" }
    );
    escapee.unref();
    """
)

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
System.put_env("RECOVERY_FIXTURE_ARENA", base)
System.put_env("PATH", bin <> ":" <> System.fetch_env!("PATH"))

for name <- ["claude", "codex", "fixture", "npm", "ssh"] do
  true = System.find_executable(name) == Path.join(bin, name)
end

File.mkdir_p!(Path.join(base, "work"))
Application.put_env(:tightbeam, :cwd, Path.join(base, "work"))
Application.put_env(:tightbeam, :port, 0)
Application.put_env(:tightbeam, :default_harness, :fixture)
Application.put_env(:tightbeam, :default_model, Model.new("fixture-model"))
Application.put_env(:tightbeam, :live_base_guard, lock_dir: locks)
Application.put_env(:tightbeam, :autostart, true)
Application.put_env(:tightbeam, :drain_timeout_ms, 1_000)
{:ok, _apps} = Application.ensure_all_started(:tightbeam)

%{user_id: "shutdown-admin", is_admin: true} =
  Tightbeam.Devices.add_user(Tightbeam.DB, "shutdown-admin", false)

onboard =
  Tightbeam.Gateway.handlers(%{
    base_dir: base,
    db: Tightbeam.DB,
    onboarding_lease_ms: 60_000
  })["onboard"]

call = %{origin: "user:shutdown-admin", params: %{provider: "fixture-provider"}}

%{provider: :fixture_provider, status: "ready", staging_path: staging, lease_id: lease} =
  onboard.(put_in(call.params[:phase], "begin"))

File.write!(Path.join(staging, "fixture.json"), "fixture-provider-credential")

%{provider: :fixture_provider, status: "onboarded"} =
  onboard.(call |> put_in([:params, :phase], "finish") |> put_in([:params, :lease_id], lease))

harness_key = {:fixture, "shared", "testhost"}
{:ok, _adapter, _generation} = AdapterCoordinator.adapter_for(AdapterCoordinator, harness_key)

await = fn recur, fun, remaining, failure ->
  cond do
    fun.() ->
      :ok

    remaining > 0 ->
      Process.sleep(20)
      recur.(recur, fun, remaining - 1, failure)

    true ->
      raise failure
  end
end

await.(
  await,
  fn -> File.exists?(escape_identity <> ".authority") end,
  1_500,
  "escape identity missing"
)

[authority, escape_pid, escape_pgid, _seconds, _micros, _boot, "application-stop-escapee"] =
  escape_identity
  |> Kernel.<>(".authority")
  |> File.read!()
  |> String.trim()
  |> String.split("\t")

"tightbeam-harness-identity-v2" = authority
{escape_pid, ""} = Integer.parse(escape_pid)
{escape_pgid, ""} = Integer.parse(escape_pgid)

[row] = HarnessProcess.list(DB)
true = row.state == "running"
true = row.process_group_id != escape_pgid
launch_id = row.launch_id

:ok = Application.stop(:tightbeam)
await_lock.(await_lock, 100)

{:ok, evidence_db} =
  DB.start_link(
    path: Path.join(base, "state.db"),
    name: :application_stop_evidence_db,
    guard_inputs: [lock_dir: locks]
  )

alive? = fn ->
  case System.cmd("/bin/kill", ["-0", Integer.to_string(escape_pid)], stderr_to_stdout: true) do
    {_output, 0} -> true
    {_output, _status} -> false
  end
end

try do
  {:ok, [["killed", park_requested_at, kill_attempted_at, kill_sent_at, resolved_at, nil]]} =
    DB.query(
      evidence_db,
      """
      SELECT state, parkRequestedAt, killAttemptedAt, killSentAt, resolvedAt, lastError
        FROM harness_processes
       WHERE launchId = ?1
      """,
      [launch_id]
    )

  true =
    Enum.all?([park_requested_at, kill_attempted_at, kill_sent_at, resolved_at], &is_integer/1)

  {:ok, [[0]]} = DB.query(evidence_db, "SELECT COUNT(*) FROM harness_park_fences", [])

  :ok =
    await.(await, fn -> not alive?.() end, 750, "detached descendant survived Application.stop")

  false = File.exists?(tripwire)
  IO.puts("application-stop-harness-cleanup: ok")
after
  if alive?.(), do: System.cmd("/bin/kill", ["-KILL", Integer.to_string(escape_pid)])
  GenServer.stop(evidence_db)
end
