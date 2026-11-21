defmodule Tightbeam.AdapterFirstStartIdentityTest do
  use Tightbeam.TestCase, async: false
  @moduletag tmp_dir: true

  alias Tightbeam.{DB, EventLog, HarnessProcess}
  alias Tightbeam.Acp.Adapter

  @helper Path.expand("../cli/target/release/tightbeam", __DIR__)

  test "first unanswered identity check permits readiness and later proves identity", %{tmp_dir: tmp} do
    db = start_supervised!({DB, path: ":memory:", name: nil})
    :ok = HarnessProcess.ensure_schema(db)
    :ok = EventLog.ensure_schema(db)
    script = Path.join(tmp, "adapter.js")

    File.write!(script, ~S"""
    const rl = require("node:readline").createInterface({ input: process.stdin });
    rl.on("line", (line) => {
      const request = JSON.parse(line);
      if (request.method === "initialize") {
        process.stdout.write(JSON.stringify({jsonrpc: "2.0", id: request.id, result: {protocolVersion: 1}}) + "\n");
      }
    });
    """)

    checks = :atomics.new(1, [])
    previous = Application.get_env(:tightbeam, :harness_process_command_runner_for_test)

    parent = self()

    Application.put_env(:tightbeam, :harness_process_command_runner_for_test, fn exe, args, _timeout ->
      if List.first(args) == "harness-check" do
        case :atomics.add_get(checks, 1, 1) do
          1 ->
            {:error, :timeout}

          2 ->
            send(parent, {:retry_started, self()})

            receive do
              :release_retry -> System.cmd(exe, args, stderr_to_stdout: true)
            end

          _ ->
            System.cmd(exe, args, stderr_to_stdout: true)
        end
      else
        System.cmd(exe, args, stderr_to_stdout: true)
      end
    end)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:tightbeam, :harness_process_command_runner_for_test, previous),
        else: Application.delete_env(:tightbeam, :harness_process_command_runner_for_test)
    end)

    opts =
      HarnessProcess.prepare_launch(
        [cmd: [System.find_executable("node"), script], process_helper: @helper,
         process_identity_dir: tmp, home: tmp, cwd: tmp, harness: :claude],
        db, {:claude, "shared", "fixture-host"}
      )

    {:ok, adapter} = Adapter.start_link(Keyword.merge(opts, db: db, on_ready: fn -> send(parent, :ready) end))
    on_exit(fn -> if Process.alive?(adapter), do: GenServer.stop(adapter) end)
    assert_receive :ready, 7_000
    assert {:pending, _} = Adapter.launch_identity_status(adapter)
    assert [%{state: "launching", last_error: nil}] = HarnessProcess.list(db)

    assert_receive {:retry_started, retry}, 2_000
    send(retry, :release_retry)
    assert eventually(fn -> Adapter.launch_identity_status(adapter) == :ok end)
    assert [%{state: "running", last_error: nil}] = HarnessProcess.list(db)
    assert :atomics.get(checks, 1) >= 2
  end

  defp eventually(fun, attempts \\ 100)
  defp eventually(fun, 0), do: fun.()
  defp eventually(fun, attempts) do
    if fun.(), do: true, else: (Process.sleep(100); eventually(fun, attempts - 1))
  end
end
