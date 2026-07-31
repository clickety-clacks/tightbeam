defmodule Tightbeam.HarnessProcessTest do
  use Tightbeam.TestCase, async: false

  alias Tightbeam.{AdapterCoordinator, DB, HarnessProcess}

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
        "harness-process-#{System.unique_integer([:positive, :monotonic])}"
      )

    File.mkdir_p!(test_dir)
    on_exit(fn -> File.rm_rf!(test_dir) end)

    prior_timeout = Application.get_env(:tightbeam, :harness_process_command_timeout_ms)

    on_exit(fn ->
      if prior_timeout,
        do: Application.put_env(:tightbeam, :harness_process_command_timeout_ms, prior_timeout),
        else: Application.delete_env(:tightbeam, :harness_process_command_timeout_ms)
    end)

    assert File.exists?(@helper)
    start_supervised!({DB, path: ":memory:", name: db})
    start_supervised!({DynamicSupervisor, strategy: :one_for_one, name: sup})
    :ok = HarnessProcess.ensure_schema(db)
    %{db: db, sup: sup, test_dir: test_dir}
  end

  test "park SIGKILLs the whole minted process group, including a tool subprocess", ctx do
    marker = Path.join(ctx.test_dir, "tool-writes")

    script = """
    trap '' HUP TERM
    (trap '' HUP TERM; while :; do printf x >> #{marker}; sleep 0.02; done) &
    while :; do sleep 1; done
    """

    {port, row} = launch(ctx, {:claude, "shared", "testhost"}, ["sh", "-c", script])
    on_exit(fn -> close_port(port) end)
    assert eventually(fn -> File.exists?(marker) and File.stat!(marker).size > 0 end)

    assert row.os_pid == row.process_group_id
    assert {:ok, fenced} = HarnessProcess.begin_park(ctx.db, {:claude, "shared", "testhost"})
    assert :ok = HarnessProcess.park(ctx.db, fenced, 50)
    assert :ok = HarnessProcess.complete_park(ctx.db, {:claude, "shared", "testhost"})

    assert [%{state: "killed", kill_sent_at: sent_at, resolved_at: resolved_at}] =
             HarnessProcess.list(ctx.db)

    assert is_integer(sent_at)
    assert is_integer(resolved_at)
    size = File.stat!(marker).size
    Process.sleep(100)
    assert File.stat!(marker).size == size
    refute HarnessProcess.fenced?(ctx.db, {:claude, "shared", "testhost"})
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

    assert [%{state: state, resolved_at: resolved_at}] =
             AdapterCoordinator.harness_processes(coordinator)

    assert state in ["closed_gracefully", "killed"]
    assert is_integer(resolved_at)
  end

  test "boot reconciliation kills a recorded orphan without a live monitor", ctx do
    {port, row} = launch_stubborn(ctx, {:codex, "shared", "testhost"})
    on_exit(fn -> close_port(port) end)

    assert row.state == "running"
    assert :ok = HarnessProcess.reconcile(ctx.db)
    assert [%{state: "killed"}] = HarnessProcess.list(ctx.db)
  end

  test "the stacked schema upgrade adds group and kill-attempt identity columns", ctx do
    old_db = :"old_harness_process_db_#{System.unique_integer([:positive])}"

    start_supervised!(Supervisor.child_spec({DB, path: ":memory:", name: old_db}, id: old_db))

    :ok =
      DB.execute(old_db, """
      CREATE TABLE harness_processes (
        launchId TEXT PRIMARY KEY,
        adapterKey TEXT NOT NULL,
        harness TEXT NOT NULL,
        preset TEXT NOT NULL,
        host TEXT NOT NULL,
        ssh TEXT,
        identityPath TEXT NOT NULL,
        osPid INTEGER,
        processStartedAt TEXT,
        state TEXT NOT NULL,
        createdAt INTEGER NOT NULL,
        parkRequestedAt INTEGER,
        killSentAt INTEGER,
        resolvedAt INTEGER,
        lastError TEXT
      )
      """)

    assert :ok = HarnessProcess.ensure_schema(old_db)
    {:ok, columns} = DB.query(old_db, "PRAGMA table_info(harness_processes)")
    names = MapSet.new(columns, &Enum.at(&1, 1))
    assert MapSet.subset?(MapSet.new(~w(helperPath processGroupId killAttemptedAt)), names)
    assert ctx.db != old_db
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
             "--",
             "env",
             "A=B",
             "adapter"
           ] = Keyword.fetch!(opts, :cmd)

    assert identity_path =~ "/harness-processes/"
  end

  test "inspection failure is unconfirmed and retry uses the durable group", ctx do
    {port, row} = launch_stubborn(ctx, {:claude, "shared", "testhost"})
    on_exit(fn -> close_port(port) end)
    assert {:ok, fenced} = HarnessProcess.begin_park(ctx.db, {:claude, "shared", "testhost"})
    failing_helper = System.find_executable("false")

    {:ok, _} =
      DB.query(
        ctx.db,
        "UPDATE harness_processes SET helperPath = ?2 WHERE launchId = ?1",
        [row.launch_id, failing_helper]
      )

    fenced = %{fenced | helper_path: failing_helper}

    assert {:error, {:park_unconfirmed, {:process_inspection_failed, 1, ""}}} =
             HarnessProcess.park(ctx.db, fenced, 50)

    assert HarnessProcess.fenced?(ctx.db, {:claude, "shared", "testhost"})

    {:ok, _} =
      DB.query(ctx.db, "UPDATE harness_processes SET helperPath = ?2 WHERE launchId = ?1", [
        row.launch_id,
        @helper
      ])

    assert :ok = HarnessProcess.retry(ctx.db, row.launch_id)
    assert [%{state: "killed"}] = HarnessProcess.list(ctx.db)
    refute HarnessProcess.fenced?(ctx.db, {:claude, "shared", "testhost"})
  end

  test "an accepted command that never returns is bounded and remains unconfirmed", ctx do
    {port, row} = launch_stubborn(ctx, {:claude, "shared", "testhost"})
    on_exit(fn -> close_port(port) end)
    hanging = Path.join(ctx.test_dir, "hanging-helper")
    File.write!(hanging, "#!/bin/sh\nexec sleep 30\n")
    File.chmod!(hanging, 0o755)
    Application.put_env(:tightbeam, :harness_process_command_timeout_ms, 50)

    assert {:ok, fenced} = HarnessProcess.begin_park(ctx.db, {:claude, "shared", "testhost"})

    {:ok, _} =
      DB.query(ctx.db, "UPDATE harness_processes SET helperPath = ?2 WHERE launchId = ?1", [
        row.launch_id,
        hanging
      ])

    fenced = %{fenced | helper_path: hanging}

    assert {:error, {:park_unconfirmed, :process_inspection_timeout}} =
             HarnessProcess.park(ctx.db, fenced, 100)

    assert HarnessProcess.fenced?(ctx.db, {:claude, "shared", "testhost"})

    coordinator =
      start_supervised!(
        {AdapterCoordinator,
         adapter_sup: ctx.sup,
         adapter_context: fn _ -> [] end,
         adapter_opts: fn _, _ -> [] end,
         db: ctx.db,
         name: :operator_release_coordinator}
      )

    assert {_, 0} =
             System.cmd(
               @helper,
               ["harness-group", "kill", Integer.to_string(row.process_group_id)],
               stderr_to_stdout: true
             )

    assert eventually(fn ->
             match?(
               {_, 3},
               System.cmd(
                 @helper,
                 ["harness-group", "status", Integer.to_string(row.process_group_id)],
                 stderr_to_stdout: true
               )
             )
           end)

    assert :ok =
             AdapterCoordinator.release_harness_park(
               coordinator,
               row.launch_id,
               "operator verified externally"
             )

    refute HarnessProcess.fenced?(ctx.db, {:claude, "shared", "testhost"})

    assert [%{state: "unconfirmed", resolved_at: resolved_at, last_error: last_error}] =
             HarnessProcess.list(ctx.db)

    assert is_integer(resolved_at)
    assert last_error == "operator_release: operator verified externally"
  end

  test "a crash window after kill attempt is never labelled graceful", ctx do
    {port, row} = launch_stubborn(ctx, {:claude, "shared", "testhost"})
    on_exit(fn -> close_port(port) end)
    assert {:ok, _} = HarnessProcess.begin_park(ctx.db, {:claude, "shared", "testhost"})

    {:ok, _} =
      DB.query(ctx.db, "UPDATE harness_processes SET killAttemptedAt = ?2 WHERE launchId = ?1", [
        row.launch_id,
        System.system_time(:millisecond)
      ])

    assert {_, 0} =
             System.cmd(
               @helper,
               ["harness-group", "kill", Integer.to_string(row.process_group_id)],
               stderr_to_stdout: true
             )

    assert eventually(fn ->
             match?(
               {_, 3},
               System.cmd(
                 @helper,
                 ["harness-group", "status", Integer.to_string(row.process_group_id)],
                 stderr_to_stdout: true
               )
             )
           end)

    assert :ok = HarnessProcess.reconcile(ctx.db)
    assert [%{state: "unconfirmed", last_error: last_error}] = HarnessProcess.list(ctx.db)
    assert last_error == inspect(:kill_delivery_unknown)
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

  test "an unconfirmed durable park fences checkout after coordinator recreation", ctx do
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

    assert {:error, {:park_unconfirmed, "claude:shared@testhost"}} =
             AdapterCoordinator.adapter_for(coordinator, key)

    refute_receive :adapter_started
    assert [%{state: "unconfirmed"}] = AdapterCoordinator.harness_processes(coordinator)
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

  defp close_port(port) do
    if Port.info(port), do: Port.close(port)
  catch
    :error, :badarg -> :ok
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
