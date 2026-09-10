[payload, base, locks] = System.argv()
payload = Path.expand(payload)
^payload = Application.app_dir(:tightbeam) |> Path.expand()
phase = System.fetch_env!("FIREHOSE_RESTART_PHASE")
true = phase in ["first", "second"]
fresh = phase == "first"
^fresh = not File.exists?(base)
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
if fresh, do: Tightbeam.RecoveryFixture.place_adapter!(base, seed_credential: false)
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
port_path = Path.join(base, "restart-port")

port =
  if fresh do
    {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
    {:ok, {_, selected}} = :inet.sockname(listener)
    :ok = :gen_tcp.close(listener)
    File.write!(port_path, Integer.to_string(selected))
    selected
  else
    port_path |> File.read!() |> String.to_integer()
  end

Application.put_env(:tightbeam, :port, port)
Application.put_env(:tightbeam, :default_harness, :fixture)
Application.put_env(:tightbeam, :default_model, Model.new("fixture-model"))
Application.put_env(:tightbeam, :live_base_guard, lock_dir: locks)
Application.put_env(:tightbeam, :autostart, true)
Application.put_env(:tightbeam, :drain_timeout_ms, 1_000)

if System.get_env("FIREHOSE_MISSING_EXECUTABLE") == "1" do
  empty_bin = Path.join(base, "empty-executable-path")
  File.mkdir_p!(empty_bin)
  System.put_env("PATH", empty_bin)

  for module <- Harness.all() do
    nil = System.find_executable(module.cli_binary())
    false = File.exists?(Path.join([base, "bin", module.cli_binary()]))
  end

  File.write!(
    Path.join(base, "refusal-input.json"),
    JSON.encode!(%{
      "pid" => System.pid(),
      "port" => port,
      "marker" => marker
    })
  )
end

{:ok, _apps} = Application.ensure_all_started(:tightbeam)

import ExUnit.Assertions

try do
  Tightbeam.Readiness.await_settled()
  :ok = DB.assert_base_admitted!(DB, base)
  assert File.regular?(Path.join(base, "state.db"))
  refute File.exists?(tripwire)

  if System.get_env("FIREHOSE_REOPEN_PROOF") == "1" do
    # Use the real catalog server with its existing synthetic dependency options.
    # Only Fixture can derive; its fetch_catalog returns a static entry and does no I/O.
    db_owner = Process.whereis(DB)
    :ok = Supervisor.terminate_child(Tightbeam.Supervisor, Tightbeam.ModelCatalog)
    :ok = Supervisor.delete_child(Tightbeam.Supervisor, Tightbeam.ModelCatalog)

    {:ok, _} =
      Supervisor.start_child(
        Tightbeam.Supervisor,
        {Tightbeam.ModelCatalog,
         base_dir: base,
         db: DB,
         credential_status: fn
           :fixture_provider, "testhost" -> :onboarded
           _, _ -> {:needs_onboarding, :synthetic_refusal}
         end,
         credential_kind: :api_key}
      )

    assert Process.whereis(DB) == db_owner
    deadline = System.monotonic_time(:millisecond) + 5_000

    catalog = fn recur ->
      case Tightbeam.ModelCatalog.get("testhost", "fixture", Tightbeam.ModelCatalog) do
        {[%{family: "fixture-model", efforts: []}], :fresh} ->
          :ok

        other ->
          assert System.monotonic_time(:millisecond) < deadline, inspect(other)
          Process.sleep(10)
          recur.(recur)
      end
    end

    catalog.(catalog)
  end

  if System.get_env("FIREHOSE_REOPEN_PROOF") == "1" and fresh do
    {:ok, device} =
      Tightbeam.ClientE2E.SimClient.pair("127.0.0.1", port,
        device_id: "reopen-restart",
        claimed_name: "Synthetic reopen"
      )

    holder =
      Tightbeam.Org.create(DB, %{
        session_key: "reopen-fixture-holder",
        display_name: "Reopen fixture",
        owner_user_id: device.user_id,
        origin: "user:#{device.user_id}",
        archetype: "default",
        harness: "fixture",
        provider: "fixture_provider",
        model: Model.new("fixture-model"),
        host: "testhost"
      })

    File.write!(
      Path.join(base, "reopen-fixture.json"),
      JSON.encode!(%{
        "token" => device.token,
        "userId" => device.user_id,
        "holder" => holder.session_key
      })
    )
  end

  receipt = Path.join(base, phase <> "-ready.json")

  File.write!(
    receipt <> ".tmp",
    JSON.encode!(%{
      "pid" => System.pid(),
      "port" => port,
      "base" => base,
      "marker" => marker,
      "payload" => payload
    })
  )

  File.rename!(receipt <> ".tmp", receipt)
  deadline = System.monotonic_time(:millisecond) + 60_000

  wait = fn recur ->
    unless File.regular?(Path.join(base, phase <> "-stop")) do
      assert System.monotonic_time(:millisecond) < deadline, "controller stop deadline"

      if System.get_env("FIREHOSE_REOPEN_PROOF") == "1" do
        request = Path.join(base, phase <> "-generations-request.json")
        result = Path.join(base, phase <> "-generations.json")

        if File.regular?(request) and not File.exists?(result) do
          %{"assignmentId" => id} = JSON.decode!(File.read!(request))

          {:ok, [["reopen-fixture-holder"]]} =
            DB.query(DB, "SELECT holderKey FROM assignments WHERE id = ?1", [id])

          {:ok, rows} =
            DB.query(
              DB,
              "SELECT generation, state, wakeId FROM effort_checkin_generations WHERE assignmentId = ?1 ORDER BY generation",
              [id]
            )

          File.write!(result <> ".tmp", JSON.encode!(rows))
          File.rename!(result <> ".tmp", result)
        end
      end

      Process.sleep(10)
      recur.(recur)
    end
  end

  wait.(wait)
after
  :ok = Application.stop(:tightbeam)
end

await.(await, 100)
refute File.exists?(tripwire)
IO.puts("guarded-firehose-restart: " <> phase <> " stopped")
