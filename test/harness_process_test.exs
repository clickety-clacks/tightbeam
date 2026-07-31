defmodule Tightbeam.HarnessProcessTest do
  use Tightbeam.TestCase, async: false

  alias Tightbeam.{AdapterCoordinator, DB, HarnessProcess}

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

    prior_ps = Application.get_env(:tightbeam, :harness_process_ps)
    ps = Path.join(test_dir, "ps")

    File.write!(ps, """
    #!/bin/sh
    pid=$4
    kill -0 "$pid" 2>/dev/null || exit 3
    case "$2" in
      lstart=) printf 'test-process-start\\n' ;;
      stat=) printf 'S\\n' ;;
      *) exit 2 ;;
    esac
    """)

    File.chmod!(ps, 0o755)
    Application.put_env(:tightbeam, :harness_process_ps, ps)

    on_exit(fn ->
      if prior_ps,
        do: Application.put_env(:tightbeam, :harness_process_ps, prior_ps),
        else: Application.delete_env(:tightbeam, :harness_process_ps)
    end)

    start_supervised!({DB, path: ":memory:", name: db})
    start_supervised!({DynamicSupervisor, strategy: :one_for_one, name: sup})
    :ok = HarnessProcess.ensure_schema(db)
    %{db: db, sup: sup, test_dir: test_dir}
  end

  test "park waits for grace then SIGKILLs the exact recorded live process", ctx do
    {port, row} = launch_stubborn(ctx, {:claude, "shared", "testhost"})
    on_exit(fn -> close_port(port) end)

    assert {:ok, fenced} = HarnessProcess.begin_park(ctx.db, {:claude, "shared", "testhost"})
    assert fenced.launch_id == row.launch_id
    assert HarnessProcess.fenced?(ctx.db, {:claude, "shared", "testhost"})

    assert :ok = HarnessProcess.park(ctx.db, fenced, 50)

    assert [%{state: "killed", kill_sent_at: sent_at, resolved_at: resolved_at}] =
             HarnessProcess.list(ctx.db)

    assert is_integer(sent_at)
    assert is_integer(resolved_at)
    refute HarnessProcess.fenced?(ctx.db, {:claude, "shared", "testhost"})
  end

  test "the coordinator persists identity during real adapter boot and resolves planned close",
       ctx do
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
             process_identity_dir: ctx.test_dir
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
               [%{state: "running", os_pid: pid, process_started_at: "test-process-start"}]
               when is_integer(pid),
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

  test "a reused PID with a different start time is never signalled", ctx do
    {port, row} = launch_stubborn(ctx, {:claude, "shared", "testhost"})
    on_exit(fn -> close_port(port) end)

    {:ok, _} =
      DB.query(
        ctx.db,
        "UPDATE harness_processes SET processStartedAt = 'not-the-recorded-start' WHERE launchId = ?1",
        [row.launch_id]
      )

    assert :ok = HarnessProcess.reconcile(ctx.db)
    assert [%{state: "exited", kill_sent_at: nil}] = HarnessProcess.list(ctx.db)

    assert {_, 0} =
             System.cmd("kill", ["-0", Integer.to_string(row.os_pid)], stderr_to_stdout: true)

    System.cmd("kill", ["-9", Integer.to_string(row.os_pid)], stderr_to_stdout: true)
  end

  test "an unconfirmed durable park fences checkout after coordinator state is recreated", ctx do
    key = {:claude, "shared", "testhost"}

    opts =
      HarnessProcess.prepare_launch(
        [
          cmd: [System.find_executable("false")],
          stderr_path: Path.join(ctx.test_dir, "never-launched.stderr")
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
    opts =
      HarnessProcess.prepare_launch(
        [
          cmd: ["sh", "-c", "trap '' HUP TERM; while :; do sleep 1; done"],
          stderr_path: Path.join(ctx.test_dir, "adapter.stderr")
        ],
        ctx.db,
        key
      )

    [executable | args] = Keyword.fetch!(opts, :cmd)

    port =
      Port.open({:spawn_executable, System.find_executable(executable)}, [
        :binary,
        :exit_status,
        {:args, args}
      ])

    :ok =
      HarnessProcess.capture_identity(
        ctx.db,
        Keyword.fetch!(opts, :harness_process_launch_id)
      )

    [row] = HarnessProcess.list(ctx.db)
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
