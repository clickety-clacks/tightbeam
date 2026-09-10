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
alias Tightbeam.{Boot, DB, Harness, LiveBaseLock, Model}

{:ok, db} =
  DB.start_link(path: Path.join(base, "state.db"), name: DB, guard_inputs: [lock_dir: locks])

:ignore = Boot.start_link(%{base_dir: base})
marker = File.read!(Path.join(base, "build-owner.json"))
:ok = GenServer.stop(db)
key = :crypto.hash(:sha256, base) |> Base.encode16(case: :lower)
lock_path = Path.join(locks, key <> ".lock")

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
File.write!(Path.join(base, ".soak-arena"), "tightbeam recovery acceptance arena v1\n")
Tightbeam.RecoveryFixture.place_adapter!(base, seed_credential: false)
tripwire = Path.join(base, "forbidden-execution.log")
bin = Path.join(base, "fixture-bin")
File.mkdir_p!(bin)
# These are synthetic CLI probes, never harness adapters or provider clients.
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

for name <- ["claude", "codex", "fixture", "npm", "ssh"] do
  true = System.find_executable(name) == Path.join(bin, name)
end

for module <- Harness.all() do
  %{input: %{profile: profile}} =
    Enum.find(
      module.conformance_vectors()["ensure_adapter"],
      &(&1.case == "local_present")
    )

  true = File.exists?(Path.join(base, "adapters/node_modules/.bin/#{profile.adapter_bin}"))
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

parent = self()

shutdown_observer =
  spawn_monitor(fn ->
    :ok = Tightbeam.Firehose.Hub.register(Tightbeam.Firehose.Hub, self(), %{mode: :pending})
    send(parent, :shutdown_observer_ready)

    receive do
      :firehose_shutdown ->
        true = :persistent_term.get({Tightbeam.Application, :draining})
        epoch = Application.fetch_env!(:tightbeam, :boot_epoch)

        {:ok, [[nil]]} =
          DB.query(DB, "SELECT cleanShutdownAt FROM boot_epochs WHERE epoch = ?1", [epoch])

        :ok = Tightbeam.Firehose.Hub.shutdown_delivered(Tightbeam.Firehose.Hub, self())
        send(parent, :shutdown_before_clean_stamp)
    after
      10_000 -> raise "Hub shutdown notification missing"
    end
  end)

receive do
  :shutdown_observer_ready -> :ok
after
  5_000 -> raise "Hub observer registration missing"
end

try do
  for name <- [
        DB,
        Tightbeam.Firehose.Hub,
        Tightbeam.WakeScheduler,
        Tightbeam.Supervision,
        Tightbeam.LaneManager
      ] do
    true = is_pid(Process.whereis(name))
  end

  Tightbeam.Readiness.await_settled()
  ^marker = File.read!(Path.join(base, "build-owner.json"))
  :ok = DB.assert_base_admitted!(DB, base)
  entries = Tightbeam.AdminProjection.served_entries(DB, base)
  true = Enum.any?(entries, &(&1.resource == "identity"))

  for entry <- entries do
    expected = Map.put(entry.item, "rowVersion", 1)
    ^expected = Tightbeam.AdminProjection.stamped_item(DB, entry.resource, entry.key)
  end

  {:ok, [[2]]} = DB.query(DB, "SELECT COUNT(*) FROM boot_epochs", [])
  {:ok, [[0]]} = DB.query(DB, "SELECT COUNT(*) FROM turns", [])
  false = File.exists?(tripwire)
  true = File.regular?(Path.join(base, "gateway.json"))
after
  :ok = Application.stop(:tightbeam)
end

receive do
  :shutdown_before_clean_stamp -> :ok
after
  5_000 -> raise "Hub shutdown ordering proof missing"
end

{observer_pid, observer_ref} = shutdown_observer

receive do
  {:DOWN, ^observer_ref, :process, ^observer_pid, :normal} -> :ok
after
  5_000 -> raise "Hub observer did not terminate normally"
end

await.(await, 100)
false = File.exists?(tripwire)
IO.puts("guarded-application-startup: ok")
