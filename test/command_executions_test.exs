defmodule Tightbeam.CommandExecutionsTest do
  use Tightbeam.TestCase, async: false

  alias Tightbeam.{CommandExecutions, DB}

  @helper Path.expand("../cli/target/release/tightbeam", __DIR__)

  setup do
    previous_host = System.get_env("TIGHTBEAM_LOCAL_HOST_NAME")
    System.put_env("TIGHTBEAM_LOCAL_HOST_NAME", "testhost")

    root =
      Path.join(
        System.tmp_dir!(),
        "command-executions-#{System.pid()}-#{System.unique_integer([:positive, :monotonic])}"
      )

    File.mkdir_p!(root)
    db = :"command_executions_db_#{System.unique_integer([:positive])}"
    start_supervised!({DB, path: Path.join(root, "state.db"), name: db})
    :ok = CommandExecutions.ensure_schema(db)
    assert File.exists?(@helper)
    on_exit(fn -> File.rm_rf!(root) end)

    on_exit(fn ->
      if previous_host do
        System.put_env("TIGHTBEAM_LOCAL_HOST_NAME", previous_host)
      else
        System.delete_env("TIGHTBEAM_LOCAL_HOST_NAME")
      end
    end)

    %{db: db, root: root}
  end

  test "prepares exact single-use intent and refuses idempotency drift", ctx do
    attrs = attrs(ctx, "same-key", ["/bin/echo", "hello"])
    first = CommandExecutions.prepare(ctx.db, attrs)
    second = CommandExecutions.prepare(ctx.db, attrs)

    assert first.execution_id == second.execution_id
    assert first.state == "prepared"
    assert first.command == ["/bin/echo", "hello"]
    assert first.command_sha256 == sha256(first.command_json)

    assert %{
             "executionId" => execution_id,
             "command" => ["/bin/echo", "hello"],
             "commandJson" => command_json,
             "commandSha256" => command_sha256,
             "holderSessionKey" => "agent:test",
             "assignmentId" => "asg_test",
             "turnIntent" => "test exact command",
             "host" => "testhost",
             "cause" => "test",
             "principal" => "agent:test"
           } = first.prepared_path |> File.read!() |> JSON.decode!()

    assert execution_id == first.execution_id
    assert command_json == first.command_json
    assert command_sha256 == first.command_sha256

    assert CommandExecutions.helper_command(first, @helper) ==
             [@helper, "command-exec", first.prepared_path]

    assert_raise ArgumentError, ~r/already bound to another execution intent/, fn ->
      CommandExecutions.prepare(ctx.db, %{attrs | command: ["/bin/echo", "different"]})
    end

    assert_raise ArgumentError, ~r/receipt_root must be a non-empty string/, fn ->
      CommandExecutions.prepare(ctx.db, %{attrs | receipt_root: ""})
    end
  end

  test "a pre-start caller death settles only through explicit not_started evidence", ctx do
    row = CommandExecutions.prepare(ctx.db, attrs(ctx, "pre-start", ["/bin/true"]))
    caller = Task.async(fn -> Process.sleep(:infinity) end)
    Task.shutdown(caller, :brutal_kill)

    settled =
      CommandExecutions.mark_not_started(ctx.db, row.execution_id, "caller died before launch")

    assert settled.state == "not_started"
    assert settled.last_error == "caller died before launch"
    refute File.exists?(row.launcher_identity_path)
    refute File.exists?(row.started_path)
    refute File.exists?(row.stdout_path)

    assert_raise ArgumentError, ~r/already consumed/, fn ->
      CommandExecutions.mark_not_started(ctx.db, row.execution_id, "retry")
    end
  end

  test "success records start and distinct exact output evidence", ctx do
    row =
      execute(ctx, "success", [
        "/bin/sh",
        "-c",
        "printf 'stdout bytes'; printf 'stderr bytes' >&2"
      ])

    assert row.state == "finished"
    assert row.exit_code == 0
    assert row.signal == nil
    assert row.stdout_bytes == byte_size("stdout bytes")
    assert row.stdout_sha256 == sha256("stdout bytes")
    assert row.stderr_bytes == byte_size("stderr bytes")
    assert row.stderr_sha256 == sha256("stderr bytes")
    assert is_integer(row.os_pid)
    assert is_integer(row.process_group_id)
    assert is_integer(row.started_at)
    assert is_integer(row.finished_at)
  end

  test "quiet and loud command failures are finished executions", ctx do
    quiet = execute(ctx, "quiet-failure", ["/bin/sh", "-c", "exit 7"])
    loud = execute(ctx, "loud-failure", ["/bin/sh", "-c", "printf boom >&2; exit 9"])

    assert %{state: "finished", exit_code: 7, stdout_bytes: 0, stderr_bytes: 0} = quiet
    assert %{state: "finished", exit_code: 9, stdout_bytes: 0, stderr_bytes: 4} = loud
    assert loud.stderr_sha256 == sha256("boom")
  end

  test "a command signal is terminal evidence distinct from an exit code", ctx do
    signaled = execute(ctx, "signal", ["/bin/sh", "-c", "kill -TERM $$"])

    assert signaled.state == "finished"
    assert signaled.exit_code == nil
    assert signaled.signal == 15
  end

  test "the exec child restores SIGPIPE before recording command evidence", ctx do
    signaled = execute(ctx, "sigpipe", ["/bin/sh", "-c", "kill -13 $$; exit 0"])

    assert signaled.state == "finished"
    assert signaled.exit_code == nil
    assert signaled.signal == 13
  end

  test "the detached command reads EOF rather than the invoker stdin", ctx do
    row =
      CommandExecutions.prepare(
        ctx.db,
        attrs(ctx, "detached-stdin", [
          "/bin/sh",
          "-c",
          "if IFS= read -r line; then printf 'input:%s' \"$line\"; else printf eof; fi"
        ])
      )

    {_output, 0} =
      System.cmd(
        "/bin/sh",
        ["-c", ~S(printf secret | "$0" command-exec "$1"), @helper, row.prepared_path]
      )

    assert eventually(fn -> File.exists?(row.terminal_path) end)
    finished = CommandExecutions.refresh(ctx.db, row.execution_id)
    assert finished.state == "finished"
    assert File.read!(finished.stdout_path) == "eof"
  end

  test "terminal output evidence refuses captured-byte drift", ctx do
    row = execute(ctx, "output-drift", ["/bin/sh", "-c", "printf sealed"])
    File.write!(row.stdout_path, "changed")

    assert_raise CommandExecutions.ReceiptError, ~r/output evidence does not match/, fn ->
      CommandExecutions.refresh(ctx.db, row.execution_id)
    end
  end

  test "boot reconciliation records malformed receipt evidence and continues", ctx do
    malformed = CommandExecutions.prepare(ctx.db, attrs(ctx, "malformed", ["/bin/true"]))
    File.write!(malformed.started_path, "")

    healthy = CommandExecutions.prepare(ctx.db, attrs(ctx, "healthy", ["/bin/true"]))

    assert :ok = CommandExecutions.reconcile(ctx.db)

    assert %{state: "started_unknown", last_error: error} =
             CommandExecutions.get!(ctx.db, malformed.execution_id)

    assert error =~ "reconciliation refused"
    assert error =~ "invalid JSON"
    assert CommandExecutions.get!(ctx.db, healthy.execution_id).state == "prepared"
  end

  test "boot reconciliation bounds decoding to unresolved rows", ctx do
    finished = execute(ctx, "terminal-history", ["/bin/true"])
    refused = CommandExecutions.prepare(ctx.db, attrs(ctx, "refused-history", ["/bin/true"]))

    assert CommandExecutions.mark_not_started(ctx.db, refused.execution_id, "test refusal").state ==
             "not_started"

    {:ok, []} =
      DB.query(
        ctx.db,
        "UPDATE command_executions SET commandJson = 'not-json' WHERE state IN ('finished','not_started')"
      )

    assert :ok = CommandExecutions.reconcile(ctx.db)

    assert {:ok, [["finished"], ["not_started"]]} =
             DB.query(
               ctx.db,
               "SELECT state FROM command_executions WHERE executionId IN (?1, ?2) ORDER BY state",
               [finished.execution_id, refused.execution_id]
             )
  end

  test "exec failure is durably not_started and duplicate consumption is refused", ctx do
    row = CommandExecutions.prepare(ctx.db, attrs(ctx, "exec-failure", ["/no/such/tb-command"]))

    {output, 10} =
      System.cmd(@helper, ["command-exec", row.prepared_path], stderr_to_stdout: true)

    assert output =~ ~s("state":"not_started")
    settled = CommandExecutions.refresh(ctx.db, row.execution_id)
    assert settled.state == "not_started"
    assert settled.last_error =~ "exec failed"
    refute File.exists?(row.started_path)

    {duplicate, 1} =
      System.cmd(@helper, ["command-exec", row.prepared_path], stderr_to_stdout: true)

    assert duplicate =~ "execution already consumed"
  end

  test "a receipt pinned to another host is refused before consumption", ctx do
    row =
      CommandExecutions.prepare(
        ctx.db,
        %{attrs(ctx, "wrong-host", ["/bin/true"]) | host: "another-host"}
      )

    {output, 1} =
      System.cmd(@helper, ["command-exec", row.prepared_path], stderr_to_stdout: true)

    assert output =~ "prepared execution is pinned to host another-host, not testhost"
    refute File.exists?(row.claim_path)
    assert CommandExecutions.get!(ctx.db, row.execution_id).state == "prepared"
  end

  test "a terminal bound turn settles prepared intent without inferring a start", ctx do
    :ok =
      DB.execute(
        ctx.db,
        "CREATE TABLE turns (seq INTEGER, sessionKey TEXT, status TEXT)"
      )

    {:ok, []} =
      DB.query(
        ctx.db,
        "INSERT INTO turns (seq, sessionKey, status) VALUES (?1, ?2, ?3)",
        [42, "agent:test", "delivered"]
      )

    row =
      CommandExecutions.prepare(
        ctx.db,
        Map.put(attrs(ctx, "terminal-turn", ["/bin/true"]), :turn_seq, 42)
      )

    assert :ok = CommandExecutions.reconcile(ctx.db)
    settled = CommandExecutions.get!(ctx.db, row.execution_id)
    assert settled.state == "not_started"
    assert settled.last_error == "bound turn became terminal without a launcher identity"
    refute File.exists?(row.started_path)
  end

  test "detached supervisor finishes after the invoking adapter is killed post-start", ctx do
    row =
      CommandExecutions.prepare(
        ctx.db,
        attrs(ctx, "post-start-kill", [
          "/bin/sh",
          "-c",
          "sleep 0.2; printf detached"
        ])
      )

    adapter =
      spawn(fn ->
        port =
          Port.open({:spawn_executable, @helper}, [
            :binary,
            :exit_status,
            args: ["command-exec", row.prepared_path]
          ])

        receive do
          :hold -> Port.close(port)
        end
      end)

    assert eventually(fn -> File.exists?(row.started_path) end)
    Process.exit(adapter, :kill)
    assert eventually(fn -> File.exists?(row.terminal_path) end)

    finished = CommandExecutions.refresh(ctx.db, row.execution_id)
    assert finished.state == "finished"
    assert File.read!(finished.stdout_path) == "detached"
  end

  test "receipt races reconcile deterministically and idempotently", ctx do
    launcher_only = CommandExecutions.prepare(ctx.db, attrs(ctx, "launcher-only", ["/bin/true"]))
    write_receipt(launcher_only.claim_path, "claimed\n")

    write_receipt(
      launcher_only.launcher_identity_path,
      JSON.encode!(%{executionId: launcher_only.execution_id, osPid: 11, processGroupId: 11})
    )

    assert %{state: "started_unknown", os_pid: 11, process_group_id: 11} =
             CommandExecutions.refresh(ctx.db, launcher_only.execution_id)

    started_only = CommandExecutions.prepare(ctx.db, attrs(ctx, "started-only", ["/bin/true"]))
    write_receipt(started_only.claim_path, "claimed\n")

    write_receipt(
      started_only.launcher_identity_path,
      JSON.encode!(%{executionId: started_only.execution_id, osPid: 12, processGroupId: 12})
    )

    write_receipt(
      started_only.started_path,
      JSON.encode!(%{executionId: started_only.execution_id, osPid: 12, startedAt: 20})
    )

    assert %{state: "started", os_pid: 12, started_at: 20} =
             CommandExecutions.refresh(ctx.db, started_only.execution_id)

    assert :ok = CommandExecutions.reconcile(ctx.db)
    assert :ok = CommandExecutions.reconcile(ctx.db)
    assert CommandExecutions.get!(ctx.db, launcher_only.execution_id).state == "started_unknown"
    assert CommandExecutions.get!(ctx.db, started_only.execution_id).state == "started_unknown"
  end

  defp execute(ctx, key, command) do
    row = CommandExecutions.prepare(ctx.db, attrs(ctx, key, command))
    {_output, 0} = System.cmd(@helper, ["command-exec", row.prepared_path])
    assert eventually(fn -> File.exists?(row.terminal_path) end)
    CommandExecutions.refresh(ctx.db, row.execution_id)
  end

  defp attrs(ctx, idempotency_key, command) do
    %{
      idempotency_key: idempotency_key,
      holder_session_key: "agent:test",
      assignment_id: "asg_test",
      turn_intent: "test exact command",
      host: "testhost",
      cwd: ctx.root,
      command: command,
      cause: "test",
      principal: "agent:test",
      receipt_root: ctx.root
    }
  end

  defp eventually(fun, attempts \\ 200)
  defp eventually(fun, 0), do: fun.()

  defp eventually(fun, attempts) do
    if fun.() do
      true
    else
      Process.sleep(10)
      eventually(fun, attempts - 1)
    end
  end

  defp write_receipt(path, bytes) do
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, bytes)
  end

  defp sha256(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
end
