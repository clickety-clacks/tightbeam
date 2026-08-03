defmodule Tightbeam.HarnessProcessTest do
  use Tightbeam.TestCase, async: false

  alias Tightbeam.{AdapterCoordinator, DB, EventLog, HarnessProcess}
  alias Tightbeam.HarnessProcessCensus

  # A BARE NAME MUST RESOLVE. `Port.open({:spawn_executable, name})` never searches PATH --
  # it raises `:enoent` for anything that is not a real path. Call sites pass "ssh", so every
  # remote identity read and every remote `harness-group` failed BEFORE it was attempted, and
  # the rescue dressed it as exit 127 with an Erlang message -- which reads as the SATELLITE
  # refusing a command that never left the gateway. The suite was green with that bug: nothing
  # reached this code without a real ssh, so nothing could fail.
  test "a bare executable name is resolved to a path rather than handed over unresolved" do
    assert {:ok, path} = HarnessProcess.resolve_executable_for_test("sh")
    assert String.starts_with?(path, "/"), "must resolve to a real path, got: #{path}"
    assert File.exists?(path)
  end

  # An absolute path is taken as given: a satellite's own CLI lives at a path that is NOT on
  # this gateway's PATH, so resolving it through `find_executable` would reject it.
  test "an absolute path is taken as given, not looked up on PATH" do
    assert {:ok, "/bin/sh"} = HarnessProcess.resolve_executable_for_test("/bin/sh")
    assert :error = HarnessProcess.resolve_executable_for_test("/nonexistent/tb-probe")
  end

  test "an unresolvable name is refused rather than raised on" do
    assert :error = HarnessProcess.resolve_executable_for_test("tightbeam-no-such-binary")
  end

  @helper Path.expand("../cli/target/release/tightbeam", __DIR__)
  @fake_adapter ~S"""
  const rl = require("node:readline").createInterface({ input: process.stdin });
  const send = (o) => process.stdout.write(JSON.stringify({ jsonrpc: "2.0", ...o }) + "\n");
  rl.on("line", (line) => {
    const m = JSON.parse(line);
    if (m.method === "initialize") send({ id: m.id, result: { protocolVersion: 1 } });
  });
  """

  setup do
    db = :"harness_process_db_#{System.unique_integer([:positive])}"
    sup = :"harness_process_sup_#{System.unique_integer([:positive])}"

    test_dir =
      Path.join(
        System.tmp_dir!(),
        "harness-process-#{System.pid()}-#{System.unique_integer([:positive, :monotonic])}"
      )

    File.mkdir_p!(test_dir)
    db_path = Path.join(test_dir, "harness.sqlite3")

    prior_timeout = Application.get_env(:tightbeam, :harness_process_command_timeout_ms)

    on_exit(fn ->
      if prior_timeout,
        do: Application.put_env(:tightbeam, :harness_process_command_timeout_ms, prior_timeout),
        else: Application.delete_env(:tightbeam, :harness_process_command_timeout_ms)
    end)

    assert File.exists?(@helper)
    start_supervised!({DB, path: db_path, name: db})
    start_supervised!({DynamicSupervisor, strategy: :one_for_one, name: sup})
    :ok = HarnessProcess.ensure_schema(db)

    on_exit(fn ->
      cleanup_result = kill_fixture_groups(test_dir)

      if cleanup_result != :ok do
        {:error, failures} = cleanup_result

        flunk("fixture cleanup failed; identities preserved at #{test_dir}: #{inspect(failures)}")
      end

      cleanup_db = :"harness_process_cleanup_db_#{System.unique_integer([:positive])}"
      {:ok, cleanup_db_pid} = DB.start_link(path: db_path, name: cleanup_db)

      HarnessProcess.list(cleanup_db)
      |> Enum.filter(&is_integer(&1.resolved_at))
      |> Enum.each(&File.rm(&1.identity_path))

      GenServer.stop(cleanup_db_pid)
      File.rm_rf!(test_dir)
    end)

    %{db: db, sup: sup, test_dir: test_dir}
  end

  test "an old harness process schema is refused without partial DDL" do
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

  test "the coordinator records group identity during real adapter boot", ctx do
    path = Path.join(ctx.test_dir, "adapter.js")
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
             stderr_path: Path.join(ctx.test_dir, "adapter.stderr"),
             process_identity_dir: ctx.test_dir,
             process_helper: @helper
           ]
         end,
         park_grace_ms: 50,
         db: ctx.db,
         name: :identity_integration_coordinator}
      )

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
  end

  test "boot reconciliation kills a recorded orphan without a live monitor", ctx do
    {_port, row} = launch_stubborn(ctx, {:codex, "shared", "testhost"})

    assert row.state == "running"
    assert :ok = HarnessProcess.reconcile(ctx.db)
    assert [%{state: "killed"}] = HarnessProcess.list(ctx.db)
    refute File.exists?(row.identity_path)
  end

  test "remote launch wraps the harness with the same session helper", ctx do
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

  test "identity capture cannot mutate an already-resolved launch", ctx do
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
    File.write!(row.identity_path, "999999123\t999999123\tboot-marker\t#{launch_id}\n")

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

  test "kill delivery failure remains fenced and the reconcile sweep retries it", ctx do
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

  test "a kill command that never returns is bounded and remains kill_failed", ctx do
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

  test "continuous helper output cannot starve the absolute command deadline", ctx do
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

  test "every unresolved launch fences a replacement before DOWN reconciliation", ctx do
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

  test "park selection follows durable launch sequence, not clock or ULID order", ctx do
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

  test "boot reconciliation waits for a launcher identity that appears after row insertion",
       ctx do
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

  test "boot reconciliation clears a fence with no unresolved launch", ctx do
    key = {:codex, "shared", "testhost"}

    assert {:ok, :no_launch} = HarnessProcess.begin_park(ctx.db, key)
    assert HarnessProcess.fenced?(ctx.db, key)

    assert :ok = HarnessProcess.reconcile(ctx.db)
    refute HarnessProcess.fenced?(ctx.db, key)
  end

  test "DOWN reconciliation authorizes and signals the recorded group", ctx do
    key = {:claude, "shared", "testhost"}
    {_port, row} = launch_stubborn(ctx, key)

    assert :ok = HarnessProcess.reconcile_key(ctx.db, key)
    assert [%{state: "exited", kill_sent_at: sent_at}] = HarnessProcess.list(ctx.db)
    assert is_integer(sent_at)
    assert row.process_group_id > 0
  end

  test "a helper refusal cannot resolve a launch without attempting the group kill", ctx do
    key = {:claude, "shared", "testhost"}
    {_port, row} = launch_stubborn(ctx, key)
    refusing_helper = Path.join(ctx.test_dir, "refusing-helper")

    File.write!(
      refusing_helper,
      "#!/bin/sh\necho 'harness identity lock is not held' >&2\nexit 1\n"
    )

    File.chmod!(refusing_helper, 0o755)

    {:ok, _} =
      DB.query(
        ctx.db,
        "UPDATE harness_processes SET helperPath = ?2 WHERE launchId = ?1",
        [row.launch_id, refusing_helper]
      )

    assert {:error, {:kill_failed, {:signal_refused, "harness identity lock is not held"}}} =
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
  end

  test "a second reconciler losing the terminal race cannot corrupt the resolved row", ctx do
    key = {:claude, "shared", "testhost"}
    {_port, row} = launch_stubborn(ctx, key)
    gate_dir = Path.join(ctx.test_dir, "reconcile-race")
    racing_helper = Path.join(ctx.test_dir, "racing-helper")
    File.mkdir_p!(gate_dir)

    File.write!(
      racing_helper,
      """
      #!/bin/sh
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

  test "a mismatched boot identity refuses the signal and remains retryable", ctx do
    key = {:claude, "shared", "testhost"}
    {_port, row} = launch_stubborn(ctx, key)

    {:ok, _} =
      DB.query(
        ctx.db,
        "UPDATE harness_processes SET bootIdentity = 'prior-boot' WHERE launchId = ?1",
        [
          row.launch_id
        ]
      )

    assert :ok = HarnessProcess.reconcile(ctx.db)

    assert [%{state: "kill_failed", kill_sent_at: nil, last_error: last_error}] =
             HarnessProcess.list(ctx.db)

    assert last_error =~ "boot identity does not match"

    {:ok, _} =
      DB.query(ctx.db, "UPDATE harness_processes SET bootIdentity = ?2 WHERE launchId = ?1", [
        row.launch_id,
        row.boot_identity
      ])
  end

  test "planned close returns reconciliation failure and keeps the launch fenced", ctx do
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

    {:ok, _} =
      DB.query(
        ctx.db,
        "UPDATE harness_processes SET bootIdentity = 'prior-boot' WHERE launchId = ?1",
        [launch_id]
      )

    assert {:error,
            {:kill_failed,
             {:signal_refused, "harness boot identity does not match the current boot"}}} =
             AdapterCoordinator.close_adapter(coordinator, key)

    assert [%{state: "kill_failed", resolved_at: nil}] =
             AdapterCoordinator.harness_processes(coordinator)

    assert HarnessProcess.fenced?(ctx.db, key)
  end

  test "a propagated reconciliation failure does not kill coordinator accounting", ctx do
    # The whole schema: a death is now told to the sessions it halted.
    :ok = ensure_all_schemas(ctx.db)
    path = Path.join(ctx.test_dir, "failed-reconcile-adapter.js")
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
             stderr_path: Path.join(ctx.test_dir, "failed-reconcile.stderr"),
             process_identity_dir: ctx.test_dir,
             process_helper: @helper
           ]
         end,
         backoff_base_ms: 60_000,
         db: ctx.db,
         name: :surviving_failed_reconcile_coordinator}
      )

    assert {:ok, adapter, 1} = AdapterCoordinator.adapter_for(coordinator, key)

    assert eventually(fn ->
             match?([%{state: "running"}], AdapterCoordinator.harness_processes(coordinator))
           end)

    [%{launch_id: launch_id}] = AdapterCoordinator.harness_processes(coordinator)

    {:ok, _} =
      DB.query(
        ctx.db,
        "UPDATE harness_processes SET bootIdentity = 'prior-boot' WHERE launchId = ?1",
        [launch_id]
      )

    Process.exit(adapter, :kill)

    assert eventually(fn ->
             Process.alive?(coordinator) and
               match?(
                 %{generation: 2, failures: 1, timer: timer} when is_reference(timer),
                 :sys.get_state(coordinator).adapters[key]
               )
           end)

    assert [%{state: "kill_failed", resolved_at: nil}] = HarnessProcess.list(ctx.db)

    assert Enum.any?(EventLog.lifecycle_events(ctx.db), fn event ->
             event.kind == "adapter_reconcile_failed" and
               event.subject == "claude:shared@testhost" and
               event.detail =~ "kill_failed"
           end)
  end

  test "identity removal failure is cleanup and does not suppress the scheduled restart", ctx do
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

  test "a park with no launch fences and cancels a pending checkout", ctx do
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

  test "a kill_failed durable park fences checkout after coordinator recreation", ctx do
    key = {:claude, "shared", "testhost"}

    opts =
      HarnessProcess.prepare_launch(
        [
          cmd: [System.find_executable("false")],
          stderr_path: Path.join(ctx.test_dir, "never-launched.stderr"),
          process_helper: @helper
        ],
        ctx.db,
        key
      )

    assert {:error, _reason} =
             HarnessProcess.capture_identity(
               ctx.db,
               Keyword.fetch!(opts, :harness_process_launch_id),
               0
             )

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
