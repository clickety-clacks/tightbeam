defmodule Tightbeam.HarnessProcessFixture do
  @moduledoc false
  import ExUnit.Assertions
  import Tightbeam.TestCase, only: [ensure_all_schemas: 1]
  alias Tightbeam.{AdapterCoordinator, DB, EventLog, HarnessProcess, HarnessProcessCensus}
  @helper Path.expand("../../cli/target/release/tightbeam", __DIR__)
  @fake_adapter ~S"""
  const rl = require("node:readline").createInterface({ input: process.stdin });
  const send = (o) => process.stdout.write(JSON.stringify({ jsonrpc: "2.0", ...o }) + "\n");
  rl.on("line", (line) => {
    const m = JSON.parse(line);
    if (m.method === "initialize") send({ id: m.id, result: { protocolVersion: 1 } });
  });
  """

  def run!(tmp, scenario) do
    %{executable: executable, args: args, env: env} =
      Tightbeam.GuardRuntimeFixture.prepare!(tmp, "harness_process_runtime.exs")

    {output, status} =
      System.cmd(executable, args ++ [Integer.to_string(scenario)],
        env: env,
        stderr_to_stdout: true
      )

    File.write!(Path.join(tmp, "runtime.log"), output)
    assert status == 0, output
    assert output =~ "harness-process-case: #{scenario}: ok"
  end

  def run_case!(scenario, base, locks) do
    test_dir = Path.join(base, "harness-process-#{System.pid()}-1")
    assert File.exists?(@helper)

    {:ok, db} =
      DB.start_link(path: Path.join(base, "state.db"), name: nil, guard_inputs: [lock_dir: locks])

    File.mkdir_p!(test_dir)

    {:ok, fixtures} = Supervisor.start_link([], strategy: :one_for_one)
    Process.put({__MODULE__, :supervisor}, fixtures)
    Process.put({__MODULE__, :on_exit}, [])
    sup = start_supervised!({DynamicSupervisor, strategy: :one_for_one})
    start_supervised!({Tightbeam.RailEpisodes, name: Tightbeam.RailEpisodes})
    start_supervised!({Tightbeam.TurnObservations, name: Tightbeam.TurnObservations})
    Tightbeam.Rules.load!(Path.join(base, "absent-rules"), [])

    try do
      :ok = ensure_all_schemas(db)
      :ok = DB.assert_base_admitted!(db, base)
      scenario(scenario, %{db: db, sup: sup, test_dir: test_dir})
    after
      if Process.alive?(fixtures), do: Supervisor.stop(fixtures)

      try do
        assert :ok = kill_fixture_groups(test_dir)
        for callback <- Process.get({__MODULE__, :on_exit}, []), do: callback.()
      after
        if Process.alive?(db), do: GenServer.stop(db)
      end
    end

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
          raise "harness fixture lock did not release: #{inspect(other)}"
      end
    end

    await.(await, 100)

    {:ok, cleanup_db} =
      DB.start_link(path: Path.join(base, "state.db"), name: nil, guard_inputs: [lock_dir: locks])

    try do
      :ok = DB.assert_base_admitted!(cleanup_db, base)

      HarnessProcess.list(cleanup_db)
      |> Enum.filter(&is_integer(&1.resolved_at))
      |> Enum.each(&File.rm(&1.identity_path))

      assert HarnessProcessCensus.capture_for_root(test_dir).count == 0
    after
      GenServer.stop(cleanup_db)
    end

    await.(await, 100)
    IO.puts("harness-process-case: #{scenario}: ok")
  end

  defp start_supervised!(child) do
    {:ok, pid} = Supervisor.start_child(Process.get({__MODULE__, :supervisor}), child)
    pid
  end

  defp on_exit(callback) do
    Process.put({__MODULE__, :on_exit}, [callback | Process.get({__MODULE__, :on_exit}, [])])
    :ok
  end

  defp scenario(0, _ctx) do
    assert {:ok, path} = HarnessProcess.resolve_executable_for_test("sh")
    assert String.starts_with?(path, "/"), "must resolve to a real path, got: #{path}"
    assert File.exists?(path)
  end

  defp scenario(1, _ctx) do
    assert {:ok, "/bin/sh"} = HarnessProcess.resolve_executable_for_test("/bin/sh")
    assert :error = HarnessProcess.resolve_executable_for_test("/nonexistent/tb-probe")
  end

  defp scenario(2, _ctx) do
    assert :error = HarnessProcess.resolve_executable_for_test("tightbeam-no-such-binary")
  end

  defp scenario(3, _ctx) do
    old_db = :"old_harness_process_db_#{System.unique_integer([:positive])}"

    start_supervised!(Supervisor.child_spec({DB, path: ":memory:", name: old_db}, id: old_db))

    :ok =
      DB.execute(old_db, """
      CREATE TABLE harness_processes (
        launchId TEXT PRIMARY KEY,
        adapterKey TEXT NOT NULL,
        state TEXT NOT NULL
      )
      """)

    assert_raise DB.Error,
                 ~r/pre-release harness_processes shape.*not upgraded by design.*Reset the database/,
                 fn -> HarnessProcess.ensure_schema(old_db) end

    assert {:ok, [[0]]} =
             DB.query(
               old_db,
               "SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name = 'harness_park_fences'"
             )
  end

  defp scenario(4, ctx) do
    path = Path.join(ctx.test_dir, "adapter.js")
    File.write!(path, @fake_adapter)
    key = {:claude, "shared", "testhost"}

    coordinator =
      start_supervised!({
        AdapterCoordinator,
        # Wait bound, not the subject: 50ms was enough for the fake adapter to
        # exit gracefully on quiet hosts and NOT on a loaded CI runner, where
        # the park killed it and the row read "killed" (run 30941227365). The
        # graceful path exits promptly; this only bounds a genuinely-slow one.
        adapter_sup: ctx.sup,
        adapter_context: fn _ -> [] end,
        adapter_opts: fn _, _ ->
          [
            harness: :claude,
            cmd: [System.find_executable("node"), path],
            home: ctx.test_dir,
            cwd: ctx.test_dir,
            stderr_path: Path.join(ctx.test_dir, "adapter.stderr"),
            process_identity_dir: ctx.test_dir,
            process_helper: @helper
          ]
        end,
        park_grace_ms: 5_000,
        db: ctx.db,
        name: :identity_integration_coordinator
      })

    assert {:ok, adapter, 1} = AdapterCoordinator.adapter_for(coordinator, key)
    assert Process.alive?(adapter)

    assert eventually(fn ->
             match?(
               [%{state: "running", os_pid: pid, process_group_id: pid}],
               AdapterCoordinator.harness_processes(coordinator)
             )
           end)

    assert :ok = AdapterCoordinator.close_adapter(coordinator, key)

    assert [
             %{
               state: "closed_gracefully",
               resolved_at: resolved_at,
               identity_path: identity_path
             }
           ] =
             AdapterCoordinator.harness_processes(coordinator)

    assert is_integer(resolved_at)
    refute File.exists?(identity_path)
    refute File.exists?(identity_path <> ".authority")
  end

  defp scenario(5, ctx) do
    {_port, row} = launch_stubborn(ctx, {:codex, "shared", "testhost"})

    assert row.state == "running"
    assert :ok = HarnessProcess.reconcile(ctx.db)
    assert [%{state: "killed"}] = HarnessProcess.list(ctx.db)
    refute File.exists?(row.identity_path)
    refute File.exists?(row.identity_path <> ".authority")
  end

  defp scenario(6, ctx) do
    opts =
      HarnessProcess.prepare_launch(
        [
          cmd: ["ssh", "-o", "BatchMode=yes", "worker", "exec", "env", "A=B", "adapter"],
          process_ssh: "worker",
          process_helper: "/srv/tightbeam/bin/tightbeam",
          process_identity_dir: "/srv/tightbeam"
        ],
        ctx.db,
        {:claude, "shared", "worker"}
      )

    assert [
             "ssh",
             "-o",
             "BatchMode=yes",
             "worker",
             "exec",
             "/srv/tightbeam/bin/tightbeam",
             "harness-exec",
             identity_path,
             launch_id,
             "--",
             "env",
             "A=B",
             "adapter"
           ] = Keyword.fetch!(opts, :cmd)

    assert identity_path =~ "/harness-processes/"
    assert is_binary(launch_id)
  end

  defp scenario(7, ctx) do
    opts =
      HarnessProcess.prepare_launch(
        [
          cmd: [System.find_executable("false")],
          stderr_path: Path.join(ctx.test_dir, "resolved-capture.stderr"),
          process_helper: @helper
        ],
        ctx.db,
        {:claude, "shared", "testhost"}
      )

    launch_id = Keyword.fetch!(opts, :harness_process_launch_id)
    [row] = HarnessProcess.list(ctx.db)
    # Forged identities MUST carry an unallocatable pgid: teardown raw-kills
    # every identity-recorded group it discovers, and 999999123 exceeds every
    # OS pid ceiling (macOS ~99998, linux default 4194304), so the kill is
    # ESRCH by construction and can never reach a real process. Never forge a
    # low number here.
    File.write!(row.identity_path, "999999123\t999999123\t0\t0\tboot-marker\t#{launch_id}\n")

    {:ok, _} =
      DB.query(
        ctx.db,
        """
        UPDATE harness_processes
           SET state = 'exited', resolvedAt = 42, lastError = 'terminal'
         WHERE launchId = ?1
        """,
        [launch_id]
      )

    [resolved] = HarnessProcess.list(ctx.db)
    assert :ok = HarnessProcess.capture_identity(ctx.db, launch_id)
    assert HarnessProcess.list(ctx.db) == [resolved]
  end

  defp scenario(8, ctx) do
    opts =
      HarnessProcess.prepare_launch(
        [
          cmd: [System.find_executable("false")],
          stderr_path: Path.join(ctx.test_dir, "unbounded-capture.stderr"),
          process_helper: @helper
        ],
        ctx.db,
        {:claude, "shared", "testhost"}
      )

    launch_id = Keyword.fetch!(opts, :harness_process_launch_id)
    [row] = HarnessProcess.list(ctx.db)
    # See the forged-pgid note above: 999999123 is unallocatable by construction.
    File.write!(row.identity_path, "999999123\t999999123\t0\t0\tboot-marker\t#{launch_id}\n")

    assert :ok = HarnessProcess.capture_identity(ctx.db, launch_id, :infinity)
  end

  defp scenario(9, ctx) do
    {_port, row} = launch_stubborn(ctx, {:claude, "shared", "testhost"})
    assert {:ok, fenced} = HarnessProcess.begin_park(ctx.db, {:claude, "shared", "testhost"})
    failing_helper = System.find_executable("false")

    {:ok, _} =
      DB.query(
        ctx.db,
        "UPDATE harness_processes SET helperPath = ?2 WHERE launchId = ?1",
        [row.launch_id, failing_helper]
      )

    fenced = %{fenced | helper_path: failing_helper}

    assert {:error, {:kill_failed, {:sigkill_not_delivered, 1, ""}}} =
             HarnessProcess.park(ctx.db, fenced)

    assert HarnessProcess.fenced?(ctx.db, {:claude, "shared", "testhost"})
    assert [%{state: "kill_failed"}] = HarnessProcess.list(ctx.db)

    {:ok, _} =
      DB.query(ctx.db, "UPDATE harness_processes SET helperPath = ?2 WHERE launchId = ?1", [
        row.launch_id,
        @helper
      ])

    assert :ok = HarnessProcess.reconcile(ctx.db)
    assert [%{state: "killed"}] = HarnessProcess.list(ctx.db)
    refute HarnessProcess.fenced?(ctx.db, {:claude, "shared", "testhost"})
  end

  defp scenario(10, ctx) do
    {_port, row} = launch_stubborn(ctx, {:claude, "shared", "testhost"})
    hanging = grouped_helper(ctx, "hanging-helper", "exec sleep 30")
    Application.put_env(:tightbeam, :harness_process_command_timeout_ms, 50)

    assert {:ok, fenced} = HarnessProcess.begin_park(ctx.db, {:claude, "shared", "testhost"})

    {:ok, _} =
      DB.query(ctx.db, "UPDATE harness_processes SET helperPath = ?2 WHERE launchId = ?1", [
        row.launch_id,
        hanging
      ])

    fenced = %{fenced | helper_path: hanging}

    assert {:error, {:kill_failed, :sigkill_delivery_unconfirmed}} =
             HarnessProcess.park(ctx.db, fenced)

    assert HarnessProcess.fenced?(ctx.db, {:claude, "shared", "testhost"})
    assert [%{state: "kill_failed", resolved_at: nil}] = HarnessProcess.list(ctx.db)
  end

  defp scenario(11, ctx) do
    {_port, row} = launch_stubborn(ctx, {:claude, "shared", "testhost"})
    noisy = grouped_helper(ctx, "noisy-helper", "while :; do printf x; done")
    Application.put_env(:tightbeam, :harness_process_command_timeout_ms, 50)

    assert {:ok, fenced} = HarnessProcess.begin_park(ctx.db, {:claude, "shared", "testhost"})

    {:ok, _} =
      DB.query(ctx.db, "UPDATE harness_processes SET helperPath = ?2 WHERE launchId = ?1", [
        row.launch_id,
        noisy
      ])

    started_at = System.monotonic_time(:millisecond)

    assert {:error, {:kill_failed, :sigkill_delivery_unconfirmed}} =
             HarnessProcess.park(ctx.db, %{fenced | helper_path: noisy})

    assert System.monotonic_time(:millisecond) - started_at < 1_000

    assert eventually(fn -> HarnessProcessCensus.capture_for_root(ctx.test_dir).count >= 2 end)
    assert :ok = kill_fixture_groups(ctx.test_dir)
    assert eventually(fn -> HarnessProcessCensus.capture_for_root(ctx.test_dir).count == 0 end)
  end

  defp scenario(12, ctx) do
    {_port, _row} = launch_stubborn(ctx, {:claude, "shared", "testhost"})

    assert HarnessProcess.fenced?(ctx.db, {:claude, "shared", "testhost"})

    assert_raise RuntimeError, ~r/adapter park in progress/, fn ->
      HarnessProcess.prepare_launch(
        [
          cmd: [System.find_executable("false")],
          stderr_path: Path.join(ctx.test_dir, "replacement.stderr"),
          process_helper: @helper
        ],
        ctx.db,
        {:claude, "shared", "testhost"}
      )
    end
  end

  defp scenario(13, ctx) do
    for {launch_id, sequence} <- [{"zz_old", 1}, {"aa_new", 2}] do
      {:ok, _} =
        DB.query(
          ctx.db,
          """
          INSERT INTO harness_processes
            (launchId, adapterKey, harness, preset, host, helperPath, identityPath,
             launchSequence, state, createdAt)
          VALUES (?1, 'claude:shared@testhost', 'claude', 'shared', 'testhost',
                  ?2, ?3, ?4, 'launching', 100)
          """,
          [launch_id, @helper, Path.join(ctx.test_dir, launch_id <> ".identity"), sequence]
        )
    end

    assert {:ok, %{launch_id: "aa_new", state: "park_requested"}} =
             HarnessProcess.begin_park(ctx.db, {:claude, "shared", "testhost"})
  end

  defp scenario(14, ctx) do
    key = {:codex, "shared", "testhost"}

    opts =
      HarnessProcess.prepare_launch(
        [
          cmd: ["sh", "-c", "trap '' HUP TERM; while :; do sleep 1; done"],
          stderr_path: Path.join(ctx.test_dir, "delayed.stderr"),
          process_helper: @helper
        ],
        ctx.db,
        key
      )

    owner = self()

    launcher =
      Task.async(fn ->
        Process.sleep(100)
        [executable | args] = Keyword.fetch!(opts, :cmd)
        port = Port.open({:spawn_executable, executable}, [:binary, :exit_status, {:args, args}])
        send(owner, {:delayed_port, port})

        receive do
          :done -> :ok
        end
      end)

    assert :ok = HarnessProcess.reconcile(ctx.db)
    assert_receive {:delayed_port, _port}
    assert [%{state: "killed"}] = HarnessProcess.list(ctx.db)
    send(launcher.pid, :done)
    assert Task.await(launcher) == :ok
  end

  defp scenario(15, ctx) do
    key = {:codex, "shared", "testhost"}

    assert {:ok, :no_launch} = HarnessProcess.begin_park(ctx.db, key)
    assert HarnessProcess.fenced?(ctx.db, key)

    assert :ok = HarnessProcess.reconcile(ctx.db)
    refute HarnessProcess.fenced?(ctx.db, key)
  end

  defp scenario(16, ctx) do
    key = {:claude, "shared", "testhost"}
    {_port, row} = launch_stubborn(ctx, key)

    assert :ok = HarnessProcess.reconcile_key(ctx.db, key)
    assert [%{state: "exited", kill_sent_at: sent_at}] = HarnessProcess.list(ctx.db)
    assert is_integer(sent_at)
    assert row.process_group_id > 0
  end

  defp scenario(17, ctx) do
    fixture_path =
      Path.expand("../fixtures/harness_process/dead_missing_identity_repair.json", __DIR__)

    rows = fixture_path |> File.read!() |> JSON.decode!()
    prior_identity_wait = Application.get_env(:tightbeam, :harness_process_identity_wait_ms)
    Application.put_env(:tightbeam, :harness_process_identity_wait_ms, 0)

    on_exit(fn ->
      if prior_identity_wait,
        do:
          Application.put_env(
            :tightbeam,
            :harness_process_identity_wait_ms,
            prior_identity_wait
          ),
        else: Application.delete_env(:tightbeam, :harness_process_identity_wait_ms)
    end)

    for fixture <- rows do
      [harness, preset, host] = String.split(fixture["adapter_key"], ~r/[:@]/)
      key = {String.to_existing_atom(harness), preset, host}
      identity_path = Path.join(ctx.test_dir, fixture["launch_id"] <> ".identity")

      {:ok, _} =
        DB.query(
          ctx.db,
          """
          INSERT INTO harness_processes
            (launchId, adapterKey, harness, preset, host, helperPath, identityPath,
             launchSequence, osPid, state, createdAt, killAttemptedAt, lastError)
          VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, 'kill_failed', 1, ?10,
                  'identity material unavailable')
          """,
          [
            fixture["launch_id"],
            fixture["adapter_key"],
            harness,
            preset,
            host,
            @helper,
            identity_path,
            fixture["launch_sequence"],
            fixture["recorded_pid"],
            fixture["kill_attempted_at"]
          ]
        )

      assert :ok = HarnessProcess.settle_proven_dead(ctx.db, key)
      assert :already_resolved = HarnessProcess.settle_proven_dead(ctx.db, key)
      refute HarnessProcess.fenced?(ctx.db, key)

      resolved = Enum.find(HarnessProcess.list(ctx.db), &(&1.launch_id == fixture["launch_id"]))
      assert resolved.state == fixture["repaired_state"]
      assert resolved.os_pid == fixture["recorded_pid"]
      assert resolved.kill_attempted_at == fixture["kill_attempted_at"]
      assert resolved.kill_sent_at == fixture["kill_sent_at"]
      assert is_integer(resolved.resolved_at)
      assert resolved.last_error =~ "identity_unavailable"

      assert [event] =
               Enum.filter(EventLog.lifecycle_events(ctx.db), fn event ->
                 event.kind == "harness_cleanup_failed" and
                   event.subject == fixture["adapter_key"]
               end)

      assert event.detail =~ fixture["launch_id"]
      assert event.detail =~ "identity_recovery"
      assert event.detail =~ "identity_unavailable"
    end
  end

  defp scenario(18, ctx) do
    key = {:claude, "shared", "testhost"}
    {_port, row} = launch_stubborn(ctx, key)
    refusing_helper = Path.join(ctx.test_dir, "refusing-helper")

    File.write!(
      refusing_helper,
      "#!/bin/sh\necho 'harness cleanup incomplete: harness session leader disappeared during cleanup' >&2\nexit 1\n"
    )

    File.chmod!(refusing_helper, 0o755)

    {:ok, _} =
      DB.query(
        ctx.db,
        "UPDATE harness_processes SET helperPath = ?2 WHERE launchId = ?1",
        [row.launch_id, refusing_helper]
      )

    assert {:error,
            {:kill_failed,
             {:signal_refused,
              "harness cleanup incomplete: harness session leader disappeared during cleanup"}}} =
             HarnessProcess.reconcile_key(ctx.db, key)

    assert [
             %{
               state: "kill_failed",
               kill_attempted_at: attempted_at,
               kill_sent_at: nil,
               resolved_at: nil
             }
           ] = HarnessProcess.list(ctx.db)

    assert is_integer(attempted_at)
    assert HarnessProcess.fenced?(ctx.db, key)
  end

  defp scenario(19, ctx) do
    key = {:claude, "shared", "testhost"}
    {_port, row} = launch_stubborn(ctx, key)
    gate_dir = Path.join(ctx.test_dir, "reconcile-race")
    racing_helper = Path.join(ctx.test_dir, "racing-helper")
    File.mkdir_p!(gate_dir)

    File.write!(
      racing_helper,
      """
      #!/bin/sh
      # The reconciler asks for the current boot identity before it kills;
      # that call is not part of this race's choreography — pass it through.
      [ "$1" = "boot-identity" ] && exec #{@helper} "$@"
      if mkdir #{gate_dir}/first 2>/dev/null; then
        touch #{gate_dir}/first-started
        while [ ! -f #{gate_dir}/release-first ]; do sleep 0.01; done
        exec #{@helper} "$@"
      else
        touch #{gate_dir}/second-started
        while [ -e "$3" ]; do sleep 0.01; done
        exec #{@helper} "$@"
      fi
      """
    )

    File.chmod!(racing_helper, 0o755)

    {:ok, _} =
      DB.query(
        ctx.db,
        "UPDATE harness_processes SET helperPath = ?2 WHERE launchId = ?1",
        [row.launch_id, racing_helper]
      )

    first = Task.async(fn -> HarnessProcess.reconcile_key(ctx.db, key) end)
    assert eventually(fn -> File.exists?(Path.join(gate_dir, "first-started")) end)

    second = Task.async(fn -> HarnessProcess.reconcile_key(ctx.db, key) end)
    assert eventually(fn -> File.exists?(Path.join(gate_dir, "second-started")) end)
    File.touch!(Path.join(gate_dir, "release-first"))

    assert Task.await(first) == :ok
    assert Task.await(second) == :already_resolved

    assert [%{state: "exited", resolved_at: resolved_at, last_error: nil}] =
             HarnessProcess.list(ctx.db)

    assert is_integer(resolved_at)
    refute File.exists?(row.identity_path)
    refute HarnessProcess.fenced?(ctx.db, key)
  end

  defp scenario(20, ctx) do
    path = Path.join(ctx.test_dir, "planned-close-adapter.js")
    File.write!(path, @fake_adapter)
    key = {:claude, "shared", "testhost"}

    coordinator =
      start_supervised!(
        {AdapterCoordinator,
         adapter_sup: ctx.sup,
         adapter_context: fn _ -> [] end,
         adapter_opts: fn _, _ ->
           [
             harness: :claude,
             cmd: [System.find_executable("node"), path],
             home: ctx.test_dir,
             cwd: ctx.test_dir,
             stderr_path: Path.join(ctx.test_dir, "planned-close.stderr"),
             process_identity_dir: ctx.test_dir,
             process_helper: @helper
           ]
         end,
         park_grace_ms: 50,
         db: ctx.db,
         name: :failed_planned_close_coordinator}
      )

    assert {:ok, adapter, 1} = AdapterCoordinator.adapter_for(coordinator, key)
    assert Process.alive?(adapter)

    assert eventually(fn ->
             match?([%{state: "running"}], AdapterCoordinator.harness_processes(coordinator))
           end)

    [%{launch_id: launch_id}] = AdapterCoordinator.harness_processes(coordinator)

    # A GENUINE cannot-identify (a corrupted identity file the signal helper
    # refuses to act on). This test once faked the row's bootIdentity, but a
    # recorded-boot mismatch is now proof of a reboot orphan and RESOLVES —
    # reality cannot produce a row that disagrees with the file it was
    # captured from.
    identity_path = Path.join([ctx.test_dir, "harness-processes", launch_id <> ".identity"])
    File.write!(identity_path, "not\tan\tidentity\n")

    assert {:error, {:kill_failed, {:signal_refused, refusal}}} =
             AdapterCoordinator.close_adapter(coordinator, key)

    assert refusal =~ "identity"

    assert [%{state: "kill_failed", resolved_at: nil}] =
             AdapterCoordinator.harness_processes(coordinator)

    assert HarnessProcess.fenced?(ctx.db, key)
  end

  defp scenario(21, ctx) do
    # The whole schema: a death is now told to the sessions it halted.
    :ok = ensure_all_schemas(ctx.db)
    path = Path.join(ctx.test_dir, "failed-reconcile-adapter.js")
    File.write!(path, @fake_adapter)
    key = {:claude, "shared", "testhost"}
    owner = self()
    starts = :atomics.new(1, signed: false)

    coordinator =
      start_supervised!(
        {AdapterCoordinator,
         adapter_sup: ctx.sup,
         adapter_context: fn _ -> [] end,
         adapter_opts: fn _, _ ->
           attempt = :atomics.add_get(starts, 1, 1)
           send(owner, {:adapter_started, attempt})

           [
             harness: :claude,
             cmd: [System.find_executable("node"), path],
             home: ctx.test_dir,
             cwd: ctx.test_dir,
             stderr_path: Path.join(ctx.test_dir, "failed-reconcile.stderr"),
             process_identity_dir: ctx.test_dir,
             process_helper: @helper
           ]
         end,
         backoff_base_ms: 500,
         db: ctx.db,
         name: :surviving_failed_reconcile_coordinator}
      )

    assert {:ok, adapter, 1} = AdapterCoordinator.adapter_for(coordinator, key)
    assert_receive {:adapter_started, 1}

    assert eventually(fn ->
             match?([%{state: "running"}], AdapterCoordinator.harness_processes(coordinator))
           end)

    [%{launch_id: launch_id}] = AdapterCoordinator.harness_processes(coordinator)

    # A GENUINE cannot-identify: corrupt the identity file the signal helper
    # verifies before it will authorize a kill. (This test once faked the
    # row's bootIdentity instead — but a recorded-boot mismatch is now proof
    # of a reboot orphan and RESOLVES; reality cannot produce a row whose
    # boot disagrees with its own identity file, since capture copies one
    # from the other.)
    identity_path = Path.join([ctx.test_dir, "harness-processes", launch_id <> ".identity"])
    File.write!(identity_path, "not	an	identity
")

    Process.exit(adapter, :kill)

    assert eventually(fn ->
             match?(
               %{generation: 2, pid: nil, timer: timer} when is_reference(timer),
               :sys.get_state(coordinator).adapters[key]
             )
           end)

    send(coordinator, {:restart_adapter, key, 2})
    send(coordinator, {:restart_adapter, key, 2})

    checkouts =
      for _ <- 1..4 do
        Task.async(fn -> AdapterCoordinator.adapter_for(coordinator, key) end)
      end

    assert_receive {:adapter_started, 2}, 2_000

    assert [{:ok, successor_pid, 2}] =
             checkouts
             |> Enum.map(&Task.await(&1, 2_000))
             |> Enum.uniq()

    assert Process.alive?(successor_pid)
    refute_receive {:adapter_started, 3}, 700

    assert eventually(fn ->
             case :sys.get_state(coordinator).adapters[key] do
               %{generation: 2, pid: pid} when is_pid(pid) -> Process.alive?(pid)
               _ -> false
             end
           end)

    assert [successor, failed] = HarnessProcess.list(ctx.db)
    assert successor.state == "running"
    assert failed.launch_id == launch_id
    assert failed.state == "exited"
    assert is_integer(failed.resolved_at)
    assert failed.last_error =~ "signal_refused"

    assert {:ok, [[0]]} =
             DB.query(
               ctx.db,
               "SELECT COUNT(*) FROM harness_park_fences WHERE adapterKey = ?1",
               ["claude:shared@testhost"]
             )

    assert Enum.any?(EventLog.lifecycle_events(ctx.db), fn event ->
             event.kind == "harness_cleanup_failed" and
               event.subject == "claude:shared@testhost" and
               event.detail =~ launch_id and
               event.detail =~ "process_group_kill" and
               event.detail =~ "signal_refused"
           end)

    refute Enum.any?(EventLog.lifecycle_events(ctx.db), fn event ->
             event.kind == "adapter_reconcile_failed" and
               event.subject == "claude:shared@testhost"
           end)
  end

  defp scenario(22, ctx) do
    # The whole schema: a death is now told to the sessions it halted.
    :ok = ensure_all_schemas(ctx.db)
    path = Path.join(ctx.test_dir, "cleanup-failure-adapter.js")
    cleanup_failing_helper = Path.join(ctx.test_dir, "cleanup-failing-helper")
    File.write!(path, @fake_adapter)

    File.write!(
      cleanup_failing_helper,
      """
      #!/bin/sh
      #{@helper} "$@"
      status=$?
      # Sabotage ONLY the harness-group (kill/cleanup) mode: under harness-exec
      # $3 is the launch ULID, not a path, and mutating it litters the cwd with
      # <ULID>/residual directories (two were once committed by mistake).
      if [ "$status" -eq 0 ] && [ "$1" = "harness-group" ]; then
        rm -f "$3"
        mkdir "$3"
        touch "$3/residual"
      fi
      exit "$status"
      """
    )

    File.chmod!(cleanup_failing_helper, 0o755)
    key = {:claude, "shared", "testhost"}
    owner = self()
    starts = :atomics.new(1, signed: false)

    coordinator =
      start_supervised!(
        {AdapterCoordinator,
         adapter_sup: ctx.sup,
         adapter_context: fn _ -> [] end,
         adapter_opts: fn _, _ ->
           attempt = :atomics.add_get(starts, 1, 1)
           send(owner, {:adapter_started, attempt})

           [
             harness: :claude,
             cmd: [System.find_executable("node"), path],
             home: ctx.test_dir,
             cwd: ctx.test_dir,
             stderr_path: Path.join(ctx.test_dir, "cleanup-failure.stderr"),
             process_identity_dir: ctx.test_dir,
             process_helper: if(attempt == 1, do: cleanup_failing_helper, else: @helper)
           ]
         end,
         backoff_base_ms: 1,
         db: ctx.db,
         name: :cleanup_failure_restart_coordinator}
      )

    assert {:ok, adapter, 1} = AdapterCoordinator.adapter_for(coordinator, key)
    assert_receive {:adapter_started, 1}

    assert eventually(fn ->
             match?([%{state: "running"}], AdapterCoordinator.harness_processes(coordinator))
           end)

    Process.exit(adapter, :kill)

    assert_receive {:adapter_started, 2}, 2_000

    assert eventually(fn ->
             case :sys.get_state(coordinator).adapters[key].pid do
               pid when is_pid(pid) -> Process.alive?(pid)
               _ -> false
             end
           end)

    assert eventually(fn ->
             Enum.any?(AdapterCoordinator.harness_processes(coordinator), &(&1.state == "exited"))
           end)

    resolved =
      Enum.find(AdapterCoordinator.harness_processes(coordinator), &(&1.state == "exited"))

    assert is_integer(resolved.resolved_at)
    assert resolved.last_error == nil

    assert {:ok, [[0]]} =
             DB.query(
               ctx.db,
               "SELECT COUNT(*) FROM harness_park_fences WHERE adapterKey = ?1",
               ["claude:shared@testhost"]
             )

    assert Enum.any?(EventLog.lifecycle_events(ctx.db), fn event ->
             event.kind == "identity_remove_failed" and
               event.subject == "claude:shared@testhost"
           end)

    File.rm_rf!(resolved.identity_path)
  end

  defp scenario(23, ctx) do
    key = {:claude, "shared", "testhost"}
    owner = self()

    coordinator =
      start_supervised!(
        {AdapterCoordinator,
         adapter_sup: ctx.sup,
         adapter_context: fn ^key ->
           send(owner, {:context_started, self()})

           receive do
             :release_context -> []
           end
         end,
         adapter_opts: fn _, _ ->
           send(owner, :adapter_started)
           []
         end,
         db: ctx.db,
         name: :pending_checkout_park_coordinator}
      )

    checkout = Task.async(fn -> AdapterCoordinator.adapter_for(coordinator, key) end)
    assert_receive {:context_started, context_worker}
    assert :ok = AdapterCoordinator.close_adapter(coordinator, key)
    assert Task.await(checkout) == {:error, {:parked, "claude:shared@testhost"}}

    send(context_worker, :release_context)
    refute_receive :adapter_started
    refute HarnessProcess.fenced?(ctx.db, key)
  end

  defp scenario(24, ctx) do
    key = {:claude, "shared", "testhost"}

    _opts =
      HarnessProcess.prepare_launch(
        [
          cmd: [System.find_executable("false")],
          stderr_path: Path.join(ctx.test_dir, "unreadable-identity.stderr"),
          process_helper: @helper
        ],
        ctx.db,
        key
      )

    assert [%{identity_path: identity_path, os_pid: nil}] = HarnessProcess.list(ctx.db)
    File.write!(identity_path, "this names no process\n")
    on_exit(fn -> File.rm(identity_path) end)

    assert {:ok, %{state: "park_requested"}} = HarnessProcess.begin_park(ctx.db, key)
    owner = self()

    coordinator =
      start_supervised!(
        {AdapterCoordinator,
         adapter_sup: ctx.sup,
         adapter_context: fn _ -> [] end,
         adapter_opts: fn _, _ ->
           send(owner, :adapter_started)
           []
         end,
         db: ctx.db,
         name: :durable_fence_coordinator}
      )

    assert {:error, {:park_fenced, "claude:shared@testhost"}} =
             AdapterCoordinator.adapter_for(coordinator, key)

    refute_receive :adapter_started
    assert [%{state: "kill_failed"}] = AdapterCoordinator.harness_processes(coordinator)
  end

  defp scenario(25, ctx) do
    key = {:claude, "shared", "testhost"}

    HarnessProcess.prepare_launch(
      [
        cmd: [System.find_executable("false")],
        stderr_path: Path.join(ctx.test_dir, "never-launched.stderr"),
        process_helper: @helper
      ],
      ctx.db,
      key
    )

    assert [%{state: "launching", os_pid: nil, identity_path: identity_path}] =
             HarnessProcess.list(ctx.db)

    refute File.exists?(identity_path)

    assert :ok = HarnessProcess.reconcile(ctx.db)

    assert [%{state: "exited", resolved_at: resolved_at, last_error: nil}] =
             HarnessProcess.list(ctx.db)

    assert is_integer(resolved_at)
    refute HarnessProcess.fenced?(ctx.db, key)

    assert Enum.any?(
             EventLog.lifecycle_events(ctx.db),
             &(&1.kind == "harness_launch_unlaunched" and &1.subject == "claude:shared@testhost")
           )
  end

  defp scenario(26, ctx) do
    key = {:claude, "shared", "testhost"}

    HarnessProcess.prepare_launch(
      [
        cmd: [System.find_executable("false")],
        stderr_path: Path.join(ctx.test_dir, "reboot-orphan.stderr"),
        process_helper: @helper
      ],
      ctx.db,
      key
    )

    assert [%{identity_path: identity_path, launch_id: launch_id}] =
             HarnessProcess.list(ctx.db)

    # The identity file exactly as the launcher writes it — pid, pgid, leader
    # start time, boot identity, launch id — but with a boot identity no running kernel has.
    File.mkdir_p!(Path.dirname(identity_path))
    File.write!(identity_path, "999999	999999	0	0	boot-that-ended	#{launch_id}
")

    assert :ok = HarnessProcess.reconcile(ctx.db)

    assert [%{state: "exited", last_error: nil, resolved_at: resolved_at}] =
             HarnessProcess.list(ctx.db)

    assert is_integer(resolved_at)
    refute HarnessProcess.fenced?(ctx.db, key)

    assert Enum.any?(
             EventLog.lifecycle_events(ctx.db),
             &(&1.kind == "harness_launch_reboot_orphan" and
                 &1.subject == "claude:shared@testhost")
           )
  end

  defp scenario(27, ctx) do
    key = {:claude, "shared", "testhost"}

    HarnessProcess.prepare_launch(
      [
        cmd: [System.find_executable("false")],
        stderr_path: Path.join(ctx.test_dir, "never-launched-reboot.stderr"),
        process_helper: @helper
      ],
      ctx.db,
      key
    )

    assert {:ok, %{state: "park_requested"}} = HarnessProcess.begin_park(ctx.db, key)
    owner = self()

    # The successor coordinator reconciles at init, exactly as the rebooted
    # gateway does.
    coordinator =
      start_supervised!(
        {AdapterCoordinator,
         adapter_sup: ctx.sup,
         adapter_context: fn _ -> [] end,
         adapter_opts: fn _, _ ->
           send(owner, :adapter_started)
           []
         end,
         db: ctx.db,
         name: :unlaunched_recovery_coordinator}
      )

    refute HarnessProcess.fenced?(ctx.db, key)
    assert [%{state: "exited"}] = AdapterCoordinator.harness_processes(coordinator)

    AdapterCoordinator.adapter_for(coordinator, key)
    assert_receive :adapter_started
  end

  defp scenario(28, ctx) do
    opts =
      HarnessProcess.prepare_launch(
        [
          cmd: ["unused"],
          home: ctx.test_dir,
          stderr_path: Path.join(ctx.test_dir, "legacy-four-field.stderr"),
          process_identity_dir: ctx.test_dir,
          process_helper: @helper
        ],
        ctx.db,
        {:claude, "shared", "legacy-four-field"}
      )

    launch_id = Keyword.fetch!(opts, :harness_process_launch_id)
    [row] = HarnessProcess.list(ctx.db)
    File.write!(row.identity_path, "999999123\t999999123\tboot-marker\t#{launch_id}\n")

    assert :ok = HarnessProcess.capture_identity(ctx.db, launch_id)
    [captured] = HarnessProcess.list(ctx.db)
    assert captured.os_pid == 999_999_123
    assert captured.process_group_id == 999_999_123
    assert captured.boot_identity == "boot-marker"
    assert captured.identity_token == launch_id
  end

  defp scenario(29, ctx) do
    marker = Path.join(ctx.test_dir, "legacy-harness-group-entered")
    legacy_helper = Path.join(ctx.test_dir, "legacy-helper")

    File.write!(
      legacy_helper,
      """
      #!/bin/sh
      if [ "$1" = "boot-identity" ]; then
        echo boot-marker
        exit 0
      fi
      if [ "$1" = "harness-group" ]; then
        # The legacy binary requires the command plus exactly four arguments.
        # It reaches numeric killpg only after this argument-count gate.
        [ "$#" -eq 5 ] || exit 64
        touch "#{marker}"
        exit 0
      fi
      exit 64
      """
    )

    File.chmod!(legacy_helper, 0o755)
    key = {:claude, "shared", "legacy-helper-skew"}

    opts =
      HarnessProcess.prepare_launch(
        [
          cmd: ["unused"],
          process_identity_dir: ctx.test_dir,
          process_helper: legacy_helper
        ],
        ctx.db,
        key
      )

    launch_id = Keyword.fetch!(opts, :harness_process_launch_id)
    [row] = HarnessProcess.list(ctx.db)
    File.write!(row.identity_path, "999999123\t999999123\tboot-marker\t#{launch_id}\n")

    assert :ok = HarnessProcess.capture_identity(ctx.db, launch_id)
    refute File.exists?(row.identity_path <> ".authority")

    assert {:error, {:kill_failed, {:sigkill_not_delivered, 64, ""}}} =
             HarnessProcess.reconcile_key(ctx.db, key)

    refute File.exists?(marker), "legacy helper reached its numeric group-signal body"

    assert [%{state: "kill_failed", resolved_at: nil, kill_sent_at: nil}] =
             HarnessProcess.list(ctx.db)

    assert HarnessProcess.fenced?(ctx.db, key)
  end

  defp scenario(30, ctx) do
    helper = grouped_helper(ctx, "boot-mismatch.sh", "while :; do sleep 60; done")
    {port, row} = launch(ctx, {:claude, "shared", "boot-mismatch"}, [helper])

    assert eventually(fn -> match?({^port, _}, {port, %{state: "running"}}) end)

    {output, exit} =
      System.cmd(
        @helper,
        [
          "harness-group",
          Integer.to_string(row.process_group_id),
          row.identity_path,
          "boot-that-ended",
          row.launch_id
        ],
        stderr_to_stdout: true
      )

    assert exit != 0
    assert output =~ "boot identity"

    Port.close(port)
  end

  defp scenario(31, ctx) do
    launch_id = "same-group-#{System.unique_integer([:positive, :monotonic])}"

    identity_path =
      Path.join([ctx.test_dir, "helper", "harness-processes", launch_id <> ".identity"])

    File.mkdir_p!(Path.dirname(identity_path))

    helper = Path.join(ctx.test_dir, "same-group-inner.sh")

    File.write!(
      helper,
      """
      #!/bin/sh
      exec "#{@helper}" harness-exec "#{identity_path}" "#{launch_id}" -- /bin/sh -c '
        while :; do
          if [ -f "#{identity_path}" ]; then
            pgid=$(awk -F"\\t" "{print \\$2}" "#{identity_path}")
            exec "#{@helper}" harness-group "$pgid" "#{identity_path}" "$("#{@helper}" boot-identity)" "#{launch_id}"
          fi
          sleep 0.05
        done
      '
      """
    )

    File.chmod!(helper, 0o755)

    task =
      Task.async(fn ->
        System.cmd("/bin/sh", [helper], stderr_to_stdout: true)
      end)

    assert {:ok, {_output, _exit}} =
             Task.yield(task, 20_000) ||
               flunk("same-group harness-group timed out — caller frozen")
  end

  defp launch_stubborn(ctx, key) do
    launch(ctx, key, ["sh", "-c", "trap '' HUP TERM; while :; do sleep 1; done"])
  end

  defp launch(ctx, key, cmd) do
    opts =
      HarnessProcess.prepare_launch(
        [
          cmd: cmd,
          stderr_path: Path.join(ctx.test_dir, "adapter.stderr"),
          process_helper: @helper
        ],
        ctx.db,
        key
      )

    [executable | args] = Keyword.fetch!(opts, :cmd)

    port =
      Port.open({:spawn_executable, executable}, [
        :binary,
        :exit_status,
        {:args, args}
      ])

    :ok =
      HarnessProcess.capture_identity(
        ctx.db,
        Keyword.fetch!(opts, :harness_process_launch_id)
      )

    [row | _] = HarnessProcess.list(ctx.db)
    {port, row}
  end

  defp kill_fixture_groups(test_dir) do
    if eventually(fn -> kill_censused_fixture_groups(test_dir) end) do
      :ok
    else
      snapshot = HarnessProcessCensus.capture_for_root(test_dir)
      {:error, [{:fixture_processes_survived, HarnessProcessCensus.format(snapshot)}]}
    end
  end

  defp kill_censused_fixture_groups(test_dir) do
    test_dir
    |> HarnessProcessCensus.capture_for_root()
    |> Map.fetch!(:processes)
    |> Enum.map(& &1.pgid)
    |> Enum.uniq()
    |> Enum.each(&kill_fixture_group/1)

    HarnessProcessCensus.capture_for_root(test_dir).count == 0
  end

  defp grouped_helper(ctx, name, command) do
    helper = Path.join(ctx.test_dir, name)
    launch_id = "#{name}-#{System.unique_integer([:positive, :monotonic])}"

    identity_path =
      Path.join([ctx.test_dir, "helper", "harness-processes", launch_id <> ".identity"])

    File.mkdir_p!(Path.dirname(identity_path))

    File.write!(
      helper,
      "#!/bin/sh\nexec \"#{@helper}\" harness-exec \"#{identity_path}\" \"#{launch_id}\" -- sh -c '#{command}'\n"
    )

    File.chmod!(helper, 0o755)
    helper
  end

  defp kill_fixture_group(process_group_id) do
    System.cmd("/bin/kill", ["-KILL", "--", "-#{process_group_id}"], stderr_to_stdout: true)
    :ok
  end

  defp eventually(fun, attempts \\ 200)

  defp eventually(fun, attempts) do
    cond do
      fun.() ->
        true

      attempts == 0 ->
        false

      true ->
        Process.sleep(10)
        eventually(fun, attempts - 1)
    end
  end
end
