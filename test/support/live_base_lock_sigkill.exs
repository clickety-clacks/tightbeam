ExUnit.start(autorun: false)

defmodule GuardLockKill do
  import ExUnit.Assertions
  alias Tightbeam.LiveBaseLock, as: Lock
  alias Exqlite.Sqlite3

  def child(arena) do
    assert File.read!(Path.join(arena, ".native-lock-arena")) == "isolated native lock proof\n"
    {:ok, _} = Application.ensure_all_started(:crypto)
    {:ok, _} = Application.ensure_all_started(:exqlite)
    path = Path.join(arena, "kill.lock")
    {:ok, lock} = Lock.acquire(path)
    {:ok, conn} = Sqlite3.open(":memory:")
    :ok = Lock.attach_sqlite!(lock, conn)
    {:ok, statement} = Sqlite3.prepare(conn, "SELECT 1")
    :ok = Lock.release(lock)
    assert {:error, :lock_busy} = Lock.acquire(path)
    receipt = %{pid: System.pid(), arena: arena, inode: File.stat!(path).inode}
    temporary = Path.join(arena, "ready.json.tmp")
    File.write!(temporary, JSON.encode!(receipt))
    File.rename!(temporary, Path.join(arena, "ready.json"))
    IO.puts("native-lock-ready")

    receive do
      :never -> assert is_reference(conn) and is_reference(statement)
    end
  end

  def controller(arena) do
    File.write!(Path.join(arena, ".native-lock-arena"), "isolated native lock proof\n")
    executable = System.find_executable("elixir")

    args =
      ["--erl", "+S 2:2"] ++
        Enum.flat_map(:code.get_path(), fn path -> ["-pa", List.to_string(path)] end) ++
        [Path.expand(__ENV__.file), "--child", arena]

    port =
      Port.open(
        {:spawn_executable, String.to_charlist(executable)},
        [:binary, :exit_status, :stderr_to_stdout, args: Enum.map(args, &String.to_charlist/1)]
      )

    {:os_pid, pid} = Port.info(port, :os_pid)
    assert pid > 1

    try do
      await_ready(port, arena, System.monotonic_time(:millisecond) + 10_000)
      receipt = JSON.decode!(File.read!(Path.join(arena, "ready.json")))
      assert receipt["pid"] == Integer.to_string(pid)
      assert receipt["arena"] == arena
      {:os_pid, ^pid} = Port.info(port, :os_pid)
      path = Path.join(arena, "kill.lock")
      assert File.stat!(path).inode == receipt["inode"]
      assert {:error, :lock_busy} = Lock.acquire(path)
      assert {"", 0} = System.cmd("kill", ["-KILL", Integer.to_string(pid)])
      status = await_exit(port, arena, System.monotonic_time(:millisecond) + 10_000)
      result = JSON.encode!(%{pid: pid, exit_status: status, arena: arena})
      File.write!(Path.join(arena, "kill-result.json"), result)
      IO.puts("native-lock-kill-result: " <> result)
      assert status == 137
      assert {:ok, replacement} = Lock.acquire(path)

      try do
        assert File.stat!(path).inode == receipt["inode"]
      after
        :ok = Lock.release(replacement)
      end
    after
      cleanup(port, pid, arena)
    end

    IO.puts("native-lock-sigkill: ok")
  end

  defp await_ready(port, arena, deadline) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)
    if remaining == 0, do: flunk("native child readiness timed out")

    if File.regular?(Path.join(arena, "ready.json")) do
      :ok
    else
      receive do
        {^port, {:data, bytes}} ->
          File.write!(Path.join(arena, "child.log"), bytes, [:append])
          await_ready(port, arena, deadline)

        {^port, {:exit_status, status}} ->
          flunk("native child exited before readiness: #{status}")
      after
        min(remaining, 20) -> await_ready(port, arena, deadline)
      end
    end
  end

  defp await_exit(port, arena, deadline) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {^port, {:data, bytes}} ->
        File.write!(Path.join(arena, "child.log"), bytes, [:append])
        await_exit(port, arena, deadline)

      {^port, {:exit_status, status}} ->
        status
    after
      remaining -> flunk("owned native child exit timed out")
    end
  end

  defp cleanup(port, pid, arena) do
    case Port.info(port, :os_pid) do
      {:os_pid, ^pid} ->
        System.cmd("kill", ["-KILL", Integer.to_string(pid)], stderr_to_stdout: true)
        status = await_exit(port, arena, System.monotonic_time(:millisecond) + 5_000)
        IO.puts("native-lock-cleanup-exit: #{status}")

      nil ->
        :ok
    end

    if Port.info(port), do: Port.close(port)
    assert Port.info(port) == nil
  end
end

case System.argv() do
  ["--child", arena] -> GuardLockKill.child(arena)
  [_payload, _base, arena] -> GuardLockKill.controller(arena)
end
