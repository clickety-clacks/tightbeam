Code.require_file("../scripts/support/soak_gateway.exs", __DIR__)

defmodule Tightbeam.FullGatewayRecoveryTest do
  use Tightbeam.TestCase, async: false

  @tag timeout: 240_000
  test "ordinary gateway startup recovers A and both durable wake boundaries after OS death" do
    arena =
      Path.join(
        System.tmp_dir!(),
        "full-recovery-#{Base.encode16(:crypto.strong_rand_bytes(12))}"
      )

    File.mkdir_p!(arena)
    File.write!(Path.join(arena, ".soak-arena"), "tightbeam recovery acceptance arena v1\n")
    fixture = Tightbeam.GuardRuntimeFixture.prepare!(arena, "full_gateway_recovery.exs")
    {head, 0} = System.cmd("git", ["rev-parse", "HEAD"])
    {tree, 0} = System.cmd("git", ["rev-parse", "HEAD^{tree}"])
    candidate = candidate_identity!(arena)

    File.write!(
      Path.join(arena, "candidate.json"),
      JSON.encode!(%{
        head: String.trim(head),
        predecessor_tree: String.trim(tree),
        candidate_tree: candidate.tree,
        candidate_patch_sha256: candidate.patch_sha256,
        source: File.cwd!()
      })
    )

    first = launch(fixture, arena, "prepare")

    try do
      old = await_receipt!(first, arena, "prepare")
      assert_serving_ready!(old, arena, "prepare")
      {:os_pid, old_pid} = Port.info(first, :os_pid)
      assert Integer.to_string(old_pid) == old["pid"]
      assert old["base"] == fixture.base
      assert {"", 0} = System.cmd("kill", ["-KILL", Integer.to_string(old_pid)])
      exit_status = await_exit!(first, arena, "prepare")

      File.write!(
        Path.join(arena, "kill-result.json"),
        JSON.encode!(%{old_pid: old_pid, exit_status: exit_status})
      )

      IO.puts("Recovery kill-result.json: #{File.read!(Path.join(arena, "kill-result.json"))}")
      assert exit_status == 137
      started = System.monotonic_time(:millisecond)
      second = launch(fixture, arena, "restart")
      assert candidate_identity!(arena) == candidate

      try do
        new = await_receipt!(second, arena, "restart")
        assert_serving_ready!(new, arena, "restart")
        assert new["pid"] != old["pid"]
        assert new["base"] == fixture.base
        before = JSON.decode!(File.read!(Path.join(arena, "prepare-state.json")))
        after_state = JSON.decode!(File.read!(Path.join(arena, "restart-state.json")))

        for table <- ~w(artifacts attests work_items harness_health_incidents) do
          assert before[table] == after_state[table], "unexpected mutation of #{table}"
        end

        # R1 permits the first notice for a legacy-null open obligation. Bind
        # that one new claim exactly; no other assignment mutation is permitted.
        assert before["columns"] == after_state["columns"]
        assignment_columns = before["columns"]["assignments"]
        assert [prior_row] = before["assignments"]
        assert [current_row] = after_state["assignments"]
        prior = Map.new(Enum.zip(assignment_columns, prior_row))
        current = Map.new(Enum.zip(assignment_columns, current_row))
        assert {nil, preserved} = Map.pop(prior, "reminderState")
        assert {encoded, ^preserved} = Map.pop(current, "reminderState")
        assert prior["id"] == "asg_recovery_preserve"
        assert prior["holderKey"] == "agent:recovery:a"
        assert prior["openedByUser"] == "recovery-admin"
        assert prior["state"] == "open"
        claim = JSON.decode!(encoded)
        assert %{"pending" => %{"consumer" => %{"wake" => notice_id}}} = claim

        assert claim == %{
                 "version" => 1,
                 "claimEpoch" => 1,
                 "pending" => %{
                   "consumer" => %{"wake" => notice_id},
                   "intent" => notice_id,
                   "epoch" => 1,
                   "snapshot" => %{
                     "kind" => "prod",
                     "target" => prior["holderKey"],
                     "consequence" => nil
                   }
                 }
               }

        wake_columns = before["columns"]["wakes"]
        before_wakes = Enum.map(before["wakes"], &Map.new(Enum.zip(wake_columns, &1)))
        after_wakes = Enum.map(after_state["wakes"], &Map.new(Enum.zip(wake_columns, &1)))
        refute Enum.any?(before_wakes, &(&1["wakeId"] == notice_id))
        assert [notice] = Enum.filter(after_wakes, &(&1["wakeId"] == notice_id))
        assert notice["assignmentId"] == prior["id"]
        assert notice["sessionKey"] == prior["holderKey"]
        assert notice["ownerUserId"] == prior["openedByUser"]
        assert notice["origin"] == "process:tightbeam"
        assert notice["state"] == "pending"
        assert notice["firedAt"] == nil

        # Every committed pre-crash message remains byte-identical exactly once.
        assert length(before["artifacts"]) >= 1
        assert length(before["attests"]) >= 1
        prior_health = before["harness_health_observations"]
        post_health = after_state["harness_health_observations"]
        for row <- prior_health, do: assert(Enum.count(post_health, &(&1 == row)) == 1)

        assert [
                 [
                   _id,
                   "harness-turn:1:interrupted-outcome-unknown",
                   "fixture",
                   "testhost",
                   "interrupted-outcome-unknown",
                   "terminal-failure",
                   "agent:recovery:a",
                   nil,
                   _observed_at,
                   "boot recovery interrupted the running turn; outcome unknown",
                   "process:tightbeam",
                   nil
                 ]
               ] = post_health -- prior_health

        # Exactly the expected observation is allowed, never a provider incident
        # or an unrelated auth/adapter/rate-limit/model degradation observation.

        for row <- before["messages"],
            do: assert(Enum.count(after_state["messages"], &(&1 == row)) == 1)

        File.write!(
          Path.join(arena, "recovery-result.json"),
          JSON.encode!(%{
            old_pid: old["pid"],
            new_pid: new["pid"],
            exit_status: exit_status,
            recovery_ms: System.monotonic_time(:millisecond) - started
          })
        )
      after
        stop_gateway!(second, arena, "restart")
      end
    rescue
      error ->
        failure = Exception.format(:error, error, __STACKTRACE__)
        File.write!(Path.join(arena, "primary-failure.txt"), failure)
        IO.puts("Recovery primary failure: #{failure}")
        reraise error, __STACKTRACE__
    after
      try do
        stop_gateway!(first, arena, "prepare")
      after
        cleanup_fixture_descendants!(arena)
      end

      for name <-
            ~w(candidate.json prepare-state.json restart-state.json prepare-boot.json restart-boot.json recovery-result.json) do
        case File.read(Path.join(arena, name)) do
          {:ok, bytes} -> IO.puts("Recovery #{name}: #{bytes}")
          {:error, :enoent} -> IO.puts("Recovery #{name}: absent")
        end
      end

      IO.puts("Recovery evidence arena: #{arena}")
    end
  end

  defp candidate_identity!(arena) do
    env = [{"GIT_INDEX_FILE", Path.join(arena, "candidate.index")}]

    git = fn args ->
      {output, 0} = System.cmd("git", args, env: env, stderr_to_stdout: true)
      output
    end

    # Include the composer's staged new source paths, not only HEAD paths and
    # the historical recovery fixture manifest. The temporary index stays private.
    {index_tree, 0} = System.cmd("git", ["write-tree"])
    git.(["read-tree", String.trim(index_tree)])
    git.(["add", "-u"])

    git.([
      "add",
      "--",
      "scripts/soak.exs",
      "scripts/support/soak_gateway.exs",
      "test/support/recovery_fixture.ex",
      "test/support/recovery_acp_fixture.js",
      "test/support/full_gateway_recovery.exs",
      "test/recovery_fixture_contract_test.exs",
      "test/full_gateway_recovery_test.exs"
    ])

    tree = git.(["write-tree"]) |> String.trim()
    patch = git.(["diff", "--cached", "--binary", "--full-index", "HEAD"])
    File.write!(Path.join(arena, "candidate.patch"), patch)
    %{tree: tree, patch_sha256: Base.encode16(:crypto.hash(:sha256, patch), case: :lower)}
  end

  defp assert_serving_ready!(receipt, arena, phase) do
    IO.puts("Recovery #{phase} readiness receipt: #{JSON.encode!(receipt)}")

    {:ok, socket} =
      :gen_tcp.connect(~c"127.0.0.1", receipt["port"], [:binary, active: false], 5_000)

    :ok =
      :gen_tcp.send(
        socket,
        "GET /version HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n"
      )

    response = read_http!(socket, "")
    :gen_tcp.close(socket)
    File.write!(Path.join(arena, "#{phase}-serving.txt"), response)
    IO.puts("Recovery #{phase} serving: #{response}")
    assert response =~ ~r/^HTTP\/1\.[01] 200 /
    assert receipt["readiness"]["runnable"] == true

    assert Enum.any?(
             receipt["readiness"]["harnesses"],
             &(&1["harness"] == "fixture" and &1["runnable"])
           )

    assert Enum.any?(receipt["readiness"]["lines"], &String.starts_with?(&1, "READY:"))
  end

  defp read_http!(socket, acc) do
    case :gen_tcp.recv(socket, 0, 5_000) do
      {:ok, bytes} -> read_http!(socket, acc <> bytes)
      {:error, :closed} -> acc
      other -> flunk("serving read failed: #{inspect(other)}")
    end
  end

  defp stop_gateway!(port, arena, phase) do
    if info = Port.info(port, :os_pid) do
      {:os_pid, pid} = info
      assert pid > 1
      System.cmd("kill", ["-TERM", Integer.to_string(pid)], stderr_to_stdout: true)

      status =
        case shutdown_exit(port, arena, phase, System.monotonic_time(:millisecond) + 2_000) do
          :timeout ->
            IO.puts(
              "Recovery #{phase} cleanup: TERM timeout for owned PID #{pid}; escalating KILL"
            )

            {:os_pid, ^pid} = Port.info(port, :os_pid)
            System.cmd("kill", ["-KILL", Integer.to_string(pid)], stderr_to_stdout: true)
            shutdown_exit(port, arena, phase, System.monotonic_time(:millisecond) + 5_000)

          exit ->
            exit
        end

      IO.puts("Recovery #{phase} cleanup exit: #{inspect(status)}")
      assert is_integer(status), "owned gateway failed to exit after KILL"
      if Port.info(port), do: Port.close(port)
    end
  end

  defp shutdown_exit(port, arena, phase, deadline) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {^port, {:data, bytes}} ->
        File.write!(Path.join(arena, "#{phase}.log"), bytes, [:append])
        shutdown_exit(port, arena, phase, deadline)

      {^port, {:exit_status, status}} ->
        status
    after
      remaining -> :timeout
    end
  end

  defp cleanup_fixture_descendants!(arena) do
    assert File.read!(Path.join(arena, ".soak-arena")) ==
             "tightbeam recovery acceptance arena v1\n"

    # Reuse the suite's identity-file and exact-root census; never a global kill.
    census = Tightbeam.HarnessProcessCensus.capture_for_root(arena)

    Enum.each(census.processes, fn process ->
      assert process.pid > 1
      System.cmd("kill", ["-TERM", Integer.to_string(process.pid)], stderr_to_stdout: true)
    end)

    deadline = System.monotonic_time(:millisecond) + 5_000
    await_fixture_exit!(arena, deadline, false)
  end

  defp await_fixture_exit!(arena, deadline, killed?) do
    census = Tightbeam.HarnessProcessCensus.capture_for_root(arena)

    cond do
      census.count == 0 ->
        IO.puts("Recovery cleanup: zero owned fixture descendants")

      System.monotonic_time(:millisecond) < deadline ->
        receive do
        after
          20 -> await_fixture_exit!(arena, deadline, killed?)
        end

      not killed? ->
        Enum.each(census.processes, fn process ->
          assert process.pid > 1
          System.cmd("kill", ["-KILL", Integer.to_string(process.pid)], stderr_to_stdout: true)
        end)

        await_fixture_exit!(arena, System.monotonic_time(:millisecond) + 5_000, true)

      true ->
        flunk("owned fixture cleanup failed: #{Tightbeam.HarnessProcessCensus.format(census)}")
    end
  end

  defp launch(fixture, arena, phase) do
    assert File.read!(Path.join(arena, ".soak-arena")) ==
             "tightbeam recovery acceptance arena v1\n"

    env =
      fixture.env ++
        [
          {"MIX_ENV", "test"},
          {"RECOVERY_FIXTURE_ARENA", fixture.base},
          {"RECOVERY_EVIDENCE_DIR", arena},
          {"RECOVERY_PHASE", phase}
        ]

    Port.open({:spawn_executable, String.to_charlist(fixture.executable)}, [
      :binary,
      :exit_status,
      :stderr_to_stdout,
      args: Enum.map(fixture.args, &String.to_charlist/1),
      cd: String.to_charlist(File.cwd!()),
      env:
        Enum.map(env, fn {key, value} ->
          {String.to_charlist(key), if(is_nil(value), do: false, else: String.to_charlist(value))}
        end)
    ])
  end

  defp await_receipt!(port, arena, phase, deadline \\ nil) do
    deadline = deadline || System.monotonic_time(:millisecond) + 90_000
    path = Path.join(arena, "#{phase}-boot.json")

    if File.regular?(path) do
      JSON.decode!(File.read!(path))
    else
      assert System.monotonic_time(:millisecond) < deadline, "#{phase} timed out; arena #{arena}"

      receive do
        {^port, {:data, bytes}} ->
          File.write!(Path.join(arena, "#{phase}.log"), bytes, [:append])
          await_receipt!(port, arena, phase, deadline)

        {^port, {:exit_status, status}} ->
          log = File.read!(Path.join(arena, "#{phase}.log"))
          flunk("#{phase} gateway exited #{status}; arena #{arena}\n#{log}")
      after
        20 -> await_receipt!(port, arena, phase, deadline)
      end
    end
  end

  defp await_exit!(port, arena, phase) do
    receive do
      {^port, {:data, bytes}} ->
        File.write!(Path.join(arena, "#{phase}.log"), bytes, [:append])
        await_exit!(port, arena, phase)

      {^port, {:exit_status, status}} ->
        status
    after
      10_000 -> flunk("killed arena gateway did not exit")
    end
  end
end
