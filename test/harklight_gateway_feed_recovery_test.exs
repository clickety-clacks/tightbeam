defmodule Tightbeam.HarklightGatewayFeedRecoveryTest do
  use Tightbeam.TestCase, async: false

  @moduletag tmp_dir: true

  for scenario <- ["journal-first", "sqlite-first", "neither-store", "clean"] do
    @scenario scenario
    @tag timeout: 120_000
    test "filtered feed custody across full gateway replacement with #{scenario}", %{tmp_dir: tmp} do
      fixture = Tightbeam.GuardRuntimeFixture.prepare!(tmp, "harklight_gateway_feed_recovery.exs")
      first = start_gateway(fixture, @scenario, "prepare")

      try do
        {:os_pid, old_pid} = Port.info(first, :os_pid)
        await_file(first, Path.join(tmp, "prepare-ready"))

        if @scenario == "clean" do
          assert_exit(first, 0)
        else
          assert {"", 0} = System.cmd("kill", ["-KILL", Integer.to_string(old_pid)])
          assert_exit(first, 137)
        end

        second = start_gateway(fixture, @scenario, "restart")

        try do
          assert {:os_pid, new_pid} = Port.info(second, :os_pid)
          refute old_pid == new_pid
          await_file(second, Path.join(tmp, "restart-ready"))
          assert_exit(second, 0)
        after
          stop_fixture(second)
        end
      after
        stop_fixture(first)
      end
    end
  end

  defp start_gateway(fixture, scenario, phase) do
    env =
      Enum.map(fixture.env, fn {key, value} ->
        {String.to_charlist(key), if(value, do: String.to_charlist(value), else: false)}
      end)

    Port.open({:spawn_executable, String.to_charlist(fixture.executable)}, [
      :binary,
      :exit_status,
      :stderr_to_stdout,
      args: Enum.map(fixture.args ++ [scenario, phase], &String.to_charlist/1),
      env: env
    ])
  end

  defp await_file(port, path) do
    await_file(port, path, System.monotonic_time(:millisecond) + 45_000, [])
  end

  defp await_file(port, path, deadline, output) do
    unless File.regular?(path) do
      assert System.monotonic_time(:millisecond) < deadline,
             "gateway did not reach #{Path.basename(path)}\n#{Enum.reverse(output)}"

      receive do
        {^port, {:data, bytes}} ->
          await_file(port, path, deadline, [bytes | output])

        {^port, {:exit_status, status}} ->
          flunk("gateway exited #{status}\n#{Enum.reverse(output)}")
      after
        20 -> await_file(port, path, deadline, output)
      end
    end
  end

  defp assert_exit(port, expected) do
    receive do
      {^port, {:data, _bytes}} -> assert_exit(port, expected)
      {^port, {:exit_status, status}} -> assert status == expected
    after
      15_000 -> flunk("gateway did not exit")
    end
  end

  defp stop_fixture(port) do
    case Port.info(port, :os_pid) do
      {:os_pid, pid} ->
        System.cmd("kill", ["-KILL", Integer.to_string(pid)], stderr_to_stdout: true)
        if Port.info(port), do: Port.close(port)

      nil ->
        :ok
    end
  end
end
