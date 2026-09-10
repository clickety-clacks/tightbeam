defmodule Tightbeam.RecoveryScenario do
  alias Tightbeam.{DB, Gateway, Model, Org, Placement, Wakes}

  def await!(predicate, deadline \\ nil) do
    deadline = deadline || System.monotonic_time(:millisecond) + 60_000

    if predicate.() do
      :ok
    else
      if System.monotonic_time(:millisecond) >= deadline,
        do: raise("recovery scenario barrier timed out")

      receive do
      after
        20 -> await!(predicate, deadline)
      end
    end
  end

  def rows(sql, params \\ []) do
    {:ok, rows} = DB.query(DB, sql, params)
    rows
  end

  def snapshot do
    Map.new(
      ~w(turns messages wakes artifacts attests work_items assignments harness_health_observations harness_health_incidents),
      fn table ->
        {table, rows("SELECT * FROM #{table} ORDER BY rowid")}
      end
    )
    |> Map.put(
      "columns",
      Map.new(~w(assignments wakes), fn table ->
        {table, Enum.map(rows("PRAGMA table_info(#{table})"), &Enum.at(&1, 1))}
      end)
    )
  end

  def prepare! do
    host = Placement.local_host_name()

    for suffix <- ~w(a b c) do
      Org.create(DB, %{
        session_key: "agent:recovery:#{suffix}",
        display_name: "Recovery #{suffix}",
        owner_user_id: "recovery-admin",
        origin: "user:recovery-admin",
        archetype: "default",
        host: host,
        harness: "fixture",
        provider: "fixture_provider",
        model: Model.new("fixture-model")
      })
    end

    :appended =
      Gateway.deliver_prompt("agent:recovery:a", "user:recovery-admin", "RECOVERY_HOLD_A")

    # Synthetic, committed preservation subjects. No product handlers are changed.
    :ok =
      DB.execute(
        DB,
        "INSERT INTO work_items(id,title,ownerUserId,createdByUser,createdAt) VALUES ('wi_recovery_preserve','Recovery preservation','recovery-admin','recovery-admin',1)"
      )

    :ok =
      DB.execute(
        DB,
        "INSERT INTO assignments(id,subject,holderKey,openedByUser,openedAt,workItemId) VALUES ('asg_recovery_preserve','Recovery preservation','agent:recovery:a','recovery-admin',1,'wi_recovery_preserve')"
      )

    report = Path.join(Application.fetch_env!(:tightbeam, :base_dir), "preserved-report.txt")
    bytes = "Deterministic recovery preservation report\n"
    File.write!(report, bytes)

    %{artifact_id: _artifact_id} =
      Tightbeam.Artifacts.record(DB, %{
        principal: {:session, "agent:recovery:a"},
        session_key: "agent:recovery:a",
        params: %{
          work_item_id: "wi_recovery_preserve",
          kind: "report",
          title: "Recovery preservation",
          origin_path: report,
          content_sha256: Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)
        }
      })

    %{assignment: _assignment} =
      Tightbeam.Assignments.__handle__(DB, "attest", %{
        verb: "attest",
        origin: "agent:recovery:a",
        principal: {:session, "agent:recovery:a"},
        session_key: "agent:recovery:a",
        params: %{
          assignment_id: "asg_recovery_preserve",
          kind: "progress",
          note: "Committed before gateway death"
        }
      })

    await!(fn ->
      rows("SELECT status FROM turns WHERE sessionKey=?1", ["agent:recovery:a"]) == [["running"]]
    end)

    :appended =
      Gateway.deliver_prompt("agent:recovery:a", "user:recovery-admin", "RECOVERY_SUCCESSOR_A")

    # Freeze only the test arena scheduler while constructing the two durable
    # delivery boundaries. Process death removes this suspension; normal restart
    # owns all later recovery and scheduling.
    :ok = :sys.suspend(Tightbeam.WakeScheduler)

    for suffix <- ~w(b c) do
      Wakes.schedule(DB, %{
        wake_id: "w_recovery_#{suffix}",
        session_key: "agent:recovery:#{suffix}",
        origin: "user:recovery-admin",
        prompt: "RECOVERY_WAKE_#{suffix}",
        due_at: System.system_time(:millisecond) - 1,
        sender_scheduled: true
      })
    end

    :appended =
      Gateway.deliver_prompt("agent:recovery:c", "user:recovery-admin", "RECOVERY_WAKE_c",
        wake_id: "w_recovery_c"
      )

    await!(fn ->
      rows("SELECT status FROM turns WHERE wakeId='w_recovery_c'") == [["delivered"]]
    end)

    [["running"], ["queued"]] =
      rows("SELECT status FROM turns WHERE sessionKey='agent:recovery:a' ORDER BY seq")

    [] = rows("SELECT seq FROM turns WHERE wakeId='w_recovery_b'")

    [["pending"], ["pending"]] =
      rows(
        "SELECT state FROM wakes WHERE wakeId IN ('w_recovery_b','w_recovery_c') ORDER BY wakeId"
      )

    snapshot()
  end

  def recovered! do
    await!(fn ->
      rows("SELECT status FROM turns WHERE sessionKey='agent:recovery:a' ORDER BY seq") == [
        ["failed_unknown"],
        ["delivered"]
      ] and
        rows("SELECT status FROM turns WHERE wakeId='w_recovery_b'") == [["delivered"]] and
        rows(
          "SELECT state FROM wakes WHERE wakeId IN ('w_recovery_b','w_recovery_c') ORDER BY wakeId"
        ) == [["fired"], ["fired"]]
    end)

    [["delivered"]] = rows("SELECT status FROM turns WHERE wakeId='w_recovery_c'")
    # Publication/fired and consumer terminal are independent assertions.
    for suffix <- ~w(b c) do
      [[1]] = rows("SELECT COUNT(*) FROM turns WHERE wakeId=?1", ["w_recovery_#{suffix}"])

      [[1]] =
        rows("SELECT COUNT(*) FROM messages WHERE sessionKey=?1 AND content LIKE ?2", [
          "agent:recovery:#{suffix}",
          "%RECOVERY_WAKE_#{suffix}%"
        ])
    end

    snapshot()
  end
end

# The controller launches the same assembled cold payload for both phases.
# Ordinary Application startup owns recovery, lanes, and the wake scheduler.
[payload, base, locks] = System.argv()
true = Path.expand(payload) == Path.expand(Application.app_dir(:tightbeam))
arena = System.fetch_env!("RECOVERY_FIXTURE_ARENA") |> Path.expand()
^arena = System.fetch_env!("TIGHTBEAM_BASE_DIR") |> Path.expand()
^arena = Path.expand(base)
evidence = System.fetch_env!("RECOVERY_EVIDENCE_DIR") |> Path.expand()
true = Path.dirname(arena) == evidence
"tightbeam recovery acceptance arena v1\n" = File.read!(Path.join(evidence, ".soak-arena"))
"test" = System.fetch_env!("MIX_ENV")
phase = System.fetch_env!("RECOVERY_PHASE")
true = phase in ["prepare", "restart"]

{:ok, _} = Application.ensure_all_started(:exqlite)
{:ok, _} = Application.ensure_all_started(:crypto)
Application.put_env(:tightbeam, :autostart, false)
Application.put_env(:tightbeam, :base_dir, base)
Application.put_env(:tightbeam, :fixture_harness, true)
Application.put_env(:tightbeam, :local_host_name, "testhost")
alias Tightbeam.{Boot, DB, Harness, LiveBaseLock}

if phase == "prepare" do
  false = File.exists?(base)

  {:ok, db} =
    DB.start_link(path: Path.join(base, "state.db"), name: DB, guard_inputs: [lock_dir: locks])

  :ignore = Boot.start_link(%{base_dir: base})
  true = File.regular?(Path.join(base, "build-owner.json"))
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
else
  true = File.regular?(Path.join(base, "build-owner.json"))
end

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

Application.put_env(:tightbeam, :live_base_guard, lock_dir: locks)
Application.put_env(:tightbeam, :drain_timeout_ms, 1_000)
Application.put_env(:tightbeam, :base_dir, arena)
Application.put_env(:tightbeam, :cwd, Path.join(arena, "work"))
Application.put_env(:tightbeam, :port, 0)
Application.put_env(:tightbeam, :default_harness, :fixture)

Application.put_env(
  :tightbeam,
  :default_model,
  Tightbeam.Model.new("fixture-model")
)

Application.put_env(:tightbeam, :autostart, true)
File.mkdir_p!(Path.join(arena, "work"))
arena_tmp = Path.join(arena, "tmp")
File.mkdir_p!(arena_tmp)
System.put_env("TMPDIR", arena_tmp)

{:ok, _apps} = Application.ensure_all_started(:tightbeam)

if phase == "prepare" do
  # Use the existing synthetic provider onboarding lifecycle, not live auth files.
  %{user_id: "recovery-admin", is_admin: true} =
    Tightbeam.Devices.add_user(Tightbeam.DB, "recovery-admin", false)

  onboard =
    Tightbeam.Gateway.handlers(%{
      base_dir: arena,
      db: Tightbeam.DB,
      onboarding_lease_ms: 1_800_000
    })["onboard"]

  call = %{origin: "user:recovery-admin", params: %{provider: "fixture-provider"}}

  %{provider: :fixture_provider, status: "ready", staging_path: staging, lease_id: lease} =
    onboard.(put_in(call.params[:phase], "begin"))

  staging = Path.expand(staging)
  true = String.starts_with?(staging, arena <> "/")
  File.write!(Path.join(staging, "fixture.json"), "fixture-provider-credential")

  %{provider: :fixture_provider, status: "onboarded"} =
    onboard.(call |> put_in([:params, :phase], "finish") |> put_in([:params, :lease_id], lease))
end

:onboarded = Tightbeam.Credentials.status(:fixture_provider)

state =
  if phase == "prepare",
    do: Tightbeam.RecoveryScenario.prepare!(),
    else: Tightbeam.RecoveryScenario.recovered!()

false = File.exists?(tripwire)
File.write!(Path.join(evidence, "#{phase}-state.json"), JSON.encode!(state))

# Readiness remains a distinct observation from consumer completion.
Tightbeam.Readiness.await_settled()

config = %{
  base_dir: arena,
  db: Tightbeam.DB,
  default_harness: :fixture,
  default_model: Tightbeam.Model.new("fixture-model")
}

summary = Tightbeam.Readiness.summary(config, Tightbeam.ModelCatalog, Tightbeam.Archetypes.all())

readiness = %{
  runnable: summary.runnable?,
  lines: Tightbeam.Readiness.render(summary, config),
  harnesses:
    Enum.map(summary.harnesses, fn row ->
      %{harness: row.harness, runnable: row.runnable?, credential: inspect(row.credential)}
    end)
}

{_id, bandit, _type, _modules} =
  Enum.find(
    Supervisor.which_children(Tightbeam.Supervisor),
    fn {id, _pid, _type, modules} -> id == Bandit or (is_list(modules) and Bandit in modules) end
  )

{:ok, {_address, bound_port}} = ThousandIsland.listener_info(bandit)
# A boot receipt is only a synchronization barrier, never a recovery verdict.
File.write!(
  Path.join(evidence, "#{phase}-boot.json.pending"),
  JSON.encode!(%{
    pid: System.pid(),
    port: bound_port,
    readiness: readiness,
    base: arena,
    phase: phase,
    boot_epoch: Application.fetch_env!(:tightbeam, :boot_epoch)
  })
)

# The test controller owns the OS death boundary. No recovery helpers here.
File.rename!(
  Path.join(evidence, "#{phase}-boot.json.pending"),
  Path.join(evidence, "#{phase}-boot.json")
)

receive do
  :stop -> :ok
end
