defmodule Tightbeam.FirehoseColdRestartTest do
  use Tightbeam.TestCase, async: false
  alias Tightbeam.ClientE2E.{SimClient, WS}

  @direct_apply_classes [
    "work_item.created",
    "work_item.updated",
    "work_item.iceboxed",
    "work_item.reopened",
    "work_item.closed",
    "work_item.failed",
    "assignment.opened",
    "assignment.closed",
    "assignment.reopened",
    "attest.filed",
    "artifact.recorded",
    "artifact.archived",
    "artifact.released",
    "turn.queued",
    "turn.started",
    "turn.ended",
    "wake.scheduled",
    "wake.fired",
    "wake.canceled",
    "session.spawned",
    "session.updated",
    "session.harness_changed",
    "session.retired"
  ]

  @tag :tmp_dir
  @tag timeout: 120_000
  @tag :preauth_restart
  test "external client reconnects after a real guarded gateway process restart", %{tmp_dir: tmp} do
    plan = Tightbeam.GuardRuntimeFixture.prepare!(tmp, "firehose_cold_restart.exs")
    manifest = File.read!(Path.join(plan.payload, "build-manifest.json"))
    first = launch(plan, "first")

    try do
      old = receipt!(first, plan, "first")
      {:os_pid, old_pid} = Port.info(first, :os_pid)
      assert old["pid"] == Integer.to_string(old_pid)
      assert old["base"] == plan.base
      assert old["payload"] == plan.payload

      {:ok, device} =
        SimClient.pair("127.0.0.1", old["port"],
          device_id: "restart-firehose",
          claimed_name: "Synthetic restart"
        )

      ws = subscribe!(old["port"], device.token)

      {:ok, preauth} =
        WS.connect("127.0.0.1", old["port"], "/ws/changes?protocolVersion=2")

      try do
        before = create!(plan, old["port"], device, "Before process restart")
        assert_change!(ws, before)
        assert detail!(old["port"], device.token, before["id"]) == before
        File.write!(Path.join(plan.base, "first-stop"), "stop\n")
        assert {:ok, {:closed, 1012}, _} = WS.recv_event(ws, 5_000)
        assert {:ok, {:closed, 1012}, _} = WS.recv_event(preauth, 5_000)
        assert exit!(first, plan, "first") == 0
        second = launch(plan, "second")

        try do
          new = receipt!(second, plan, "second")
          {:os_pid, new_pid} = Port.info(second, :os_pid)
          assert new["pid"] == Integer.to_string(new_pid)
          assert new_pid != old_pid
          assert new["port"] == old["port"]
          assert new["base"] == old["base"]
          assert new["marker"] == old["marker"]
          assert new["payload"] == old["payload"]
          assert File.read!(Path.join(plan.payload, "build-manifest.json")) == manifest
          # The old device token and committed row survive the real process boundary.
          assert detail!(new["port"], device.token, before["id"]) == before
          resumed = subscribe!(new["port"], device.token)

          try do
            after_item = create!(plan, new["port"], device, "After process restart")
            assert after_item["id"] != before["id"]
            assert_change!(resumed, after_item)
            assert detail!(new["port"], device.token, after_item["id"]) == after_item
            assert detail!(new["port"], device.token, before["id"]) == before
            File.write!(Path.join(plan.base, "second-stop"), "stop\n")
            assert {:ok, {:closed, 1012}, _} = WS.recv_event(resumed, 5_000)
            assert exit!(second, plan, "second") == 0

            File.write!(
              Path.join(tmp, "restart-result.json"),
              JSON.encode!(%{
                "oldPid" => old_pid,
                "newPid" => new_pid,
                "base" => plan.base,
                "beforeId" => before["id"],
                "afterId" => after_item["id"],
                "firstExit" => 0,
                "secondExit" => 0,
                "preAuthCloseCode" => 1012,
                "closeCode" => 1012
              })
            )

            IO.puts(File.read!(Path.join(tmp, "restart-result.json")))
          after
            WS.close(resumed)
          end
        after
          cleanup!(second, plan, "second")
        end
      after
        WS.close(preauth)
        WS.close(ws)
      end
    after
      cleanup!(first, plan, "first")
    end

    refute File.exists?(Path.join(plan.base, "forbidden-execution.log"))
    assert Tightbeam.HarnessProcessCensus.capture_for_root(plan.base).count == 0
  end

  @tag :tmp_dir
  @tag timeout: 120_000
  test "required resource rows converge across a full gateway process restart", %{tmp_dir: tmp} do
    plan = Tightbeam.GuardRuntimeFixture.prepare!(tmp, "firehose_cold_restart.exs")
    first = launch(plan, "first", true, true)

    try do
      boot = receipt!(first, plan, "first")
      fixture = JSON.decode!(File.read!(Path.join(plan.base, "reopen-fixture.json")))
      device = %{token: fixture["token"], user_id: fixture["userId"]}
      ids = direct_apply_action!(plan, "first", %{"op" => "seed"})
      ws = subscribe!(boot["port"], device.token, @direct_apply_classes)

      try do
        client = direct_apply_seed_model!(boot["port"], device.token, ids)

        {client, ws} =
          Enum.reduce(direct_apply_resources("before"), {client, ws}, fn spec, {model, socket} ->
            {action, expected} = direct_apply_command(ids, spec, "before")
            result = direct_apply_action!(plan, "first", action)
            {notice, socket, intervening} = receive_direct_apply_notice!(socket, result)
            assert notice["class"] == expected
            assert notice["resource"] == result["resource"]
            assert notice["payload"][result["keyField"]] == result["key"]
            assert is_integer(notice["payload"]["rowVersion"])
            if result["resource"] == "turns", do: assert(notice["payload"]["status"] == "queued")

            row =
              direct_apply_rest_row!(
                boot["port"],
                device.token,
                result["resource"],
                result["key"]
              )

            assert notice["payload"] == row

            model =
              Enum.reduce(intervening, model, fn notice, acc ->
                direct_apply_apply_notice(acc, notice)
              end)

            {direct_apply_apply(model, result["resource"], result["key"], notice["payload"]),
             socket}
          end)

        snapshot = direct_apply_complete_model!(boot["port"], device.token, ids)

        assert client == snapshot,
               "the held model did not match a complete walk before the gateway restart: " <>
                 inspect(direct_apply_model_diff(client, snapshot))

        before_restart = client
        File.write!(Path.join(plan.base, "first-stop"), "stop\n")
        assert {:ok, {:closed, 1012}, _} = WS.recv_event(ws, 5_000)
        assert exit!(first, plan, "first") == 0
        WS.close(ws)

        second = launch(plan, "second", true, true)

        try do
          reopened = receipt!(second, plan, "second")
          assert reopened["pid"] != boot["pid"]
          assert reopened["base"] == boot["base"]
          assert reopened["port"] == boot["port"]
          assert reopened["marker"] == boot["marker"]

          resumed = subscribe!(reopened["port"], device.token, @direct_apply_classes)

          try do
            {client, resumed} =
              Enum.reduce(
                direct_apply_resources("after"),
                {client, resumed},
                fn spec, {model, socket} ->
                  {action, expected} = direct_apply_command(ids, spec, "after")
                  result = direct_apply_action!(plan, "second", action)
                  {notice, socket, intervening} = receive_direct_apply_notice!(socket, result)
                  assert notice["class"] == expected
                  assert notice["resource"] == result["resource"]
                  assert notice["payload"][result["keyField"]] == result["key"]
                  assert is_integer(notice["payload"]["rowVersion"])

                  if result["resource"] == "turns",
                    do: assert(notice["payload"]["status"] == "queued")

                  row =
                    direct_apply_rest_row!(
                      reopened["port"],
                      device.token,
                      result["resource"],
                      result["key"]
                    )

                  assert notice["payload"] == row

                  model =
                    Enum.reduce(intervening, model, fn notice, acc ->
                      direct_apply_apply_notice(acc, notice)
                    end)

                  {direct_apply_apply(
                     model,
                     result["resource"],
                     result["key"],
                     notice["payload"]
                   ), socket}
                end
              )

            assert client == direct_apply_complete_model!(reopened["port"], device.token, ids),
                   "the held model did not match a complete walk after the gateway restart"

            for {resource, key} <- [
                  {"work-items", ids["workItemId"]},
                  {"assignments", ids["assignmentId"]},
                  {"wakes", ids["wakeId"]},
                  {"sessions", ids["sessionKey"]}
                ] do
              assert client[{resource, key}]["rowVersion"] >
                       before_restart[{resource, key}]["rowVersion"],
                     "#{resource} version did not advance across the gateway restart"
            end

            File.write!(Path.join(plan.base, "second-stop"), "stop\n")
            assert {:ok, {:closed, 1012}, _} = WS.recv_event(resumed, 5_000)
            assert exit!(second, plan, "second") == 0
          after
            WS.close(resumed)
          end
        after
          cleanup!(second, plan, "second")
        end
      after
        WS.close(ws)
      end
    after
      cleanup!(first, plan, "first")
    end

    refute File.exists?(Path.join(plan.base, "forbidden-execution.log"))
    census = Tightbeam.HarnessProcessCensus.capture_for_root(plan.base)
    assert census.count == 0, Tightbeam.HarnessProcessCensus.format(census)
  end

  @tag :tmp_dir
  @tag timeout: 120_000
  test "parallel cold arenas isolate rows and clean an owned failed journey", %{tmp_dir: tmp} do
    survivor_plan =
      Tightbeam.GuardRuntimeFixture.prepare!(
        Path.join(tmp, "survivor"),
        "firehose_cold_restart.exs"
      )

    doomed_plan =
      Tightbeam.GuardRuntimeFixture.prepare!(
        Path.join(tmp, "doomed"),
        "firehose_cold_restart.exs"
      )

    survivor = launch(survivor_plan, "first")

    try do
      live = receipt!(survivor, survivor_plan, "first")
      doomed = launch(doomed_plan, "first")

      try do
        other = receipt!(doomed, doomed_plan, "first")
        assert live["pid"] != other["pid"]
        assert live["port"] != other["port"]
        assert live["base"] != other["base"]

        {:ok, user} =
          SimClient.pair("127.0.0.1", live["port"],
            device_id: "survivor",
            claimed_name: "Synthetic"
          )

        {:ok, other_user} =
          SimClient.pair("127.0.0.1", other["port"],
            device_id: "doomed",
            claimed_name: "Synthetic"
          )

        ws = subscribe!(live["port"], user.token)
        other_ws = subscribe!(other["port"], other_user.token)

        try do
          kept = create!(survivor_plan, live["port"], user, "Survivor only")
          isolated = create!(doomed_plan, other["port"], other_user, "Doomed only")
          assert_change!(ws, kept)
          assert_change!(other_ws, isolated)
          assert detail!(live["port"], user.token, kept["id"]) == kept
          assert detail!(other["port"], other_user.token, isolated["id"]) == isolated

          for {port, token, id} <- [
                {live["port"], user.token, isolated["id"]},
                {other["port"], other_user.token, kept["id"]}
              ] do
            assert {:ok, {{_, 404, _}, _, _}} =
                     :httpc.request(
                       :get,
                       {~c"http://127.0.0.1:#{port}/api/work-items/#{id}",
                        [{~c"authorization", String.to_charlist("Bearer " <> token)}]},
                       [timeout: 2_000],
                       body_format: :binary
                     )
          end

          assert_raise RuntimeError, "forced cold journey failure", fn ->
            try do
              raise "forced cold journey failure"
            after
              WS.close(other_ws)
              cleanup!(doomed, doomed_plan, "first")
            end
          end

          assert Port.info(doomed) == nil

          assert {:error, :econnrefused} =
                   :gen_tcp.connect(
                     {127, 0, 0, 1},
                     other["port"],
                     [:binary, active: false],
                     1_000
                   )

          assert Tightbeam.HarnessProcessCensus.capture_for_root(doomed_plan.base).count == 0
          # Cleanup of the failed arena must not stop or corrupt the other gateway.
          {:os_pid, survivor_pid} = Port.info(survivor, :os_pid)
          assert Integer.to_string(survivor_pid) == live["pid"]
          continued = create!(survivor_plan, live["port"], user, "Survivor continues")
          assert_change!(ws, continued)
          assert detail!(live["port"], user.token, kept["id"]) == kept
          File.write!(Path.join(survivor_plan.base, "first-stop"), "stop\n")
          assert {:ok, {:closed, 1012}, _} = WS.recv_event(ws, 5_000)
          assert exit!(survivor, survivor_plan, "first") == 0

          IO.puts(
            JSON.encode!(%{
              "survivorPid" => live["pid"],
              "doomedPid" => other["pid"],
              "survivorId" => kept["id"],
              "doomedId" => isolated["id"],
              "continuedId" => continued["id"],
              "doomedPortClosed" => true
            })
          )
        after
          WS.close(ws)
          WS.close(other_ws)
        end
      after
        cleanup!(doomed, doomed_plan, "first")
      end
    after
      cleanup!(survivor, survivor_plan, "first")
    end

    for plan <- [survivor_plan, doomed_plan] do
      refute File.exists?(Path.join(plan.base, "forbidden-execution.log"))
      assert Tightbeam.HarnessProcessCensus.capture_for_root(plan.base).count == 0
    end
  end

  @tag :tmp_dir
  @tag timeout: 120_000
  test "reopen audit and effort generations survive a real guarded process restart", %{
    tmp_dir: tmp
  } do
    plan = Tightbeam.GuardRuntimeFixture.prepare!(tmp, "firehose_cold_restart.exs")
    first = launch(plan, "first", true)

    try do
      old = receipt!(first, plan, "first")
      fixture = JSON.decode!(File.read!(Path.join(plan.base, "reopen-fixture.json")))
      device = %{token: fixture["token"], user_id: fixture["userId"]}
      item = create!(plan, old["port"], device, "Reopen restart")

      %{"result" => %{"id" => id}} =
        dispatch!(
          plan,
          old["port"],
          device,
          "assign",
          %{"subject" => "Restart durable assignment", "workItemId" => item["id"]},
          %{"sessionKey" => fixture["holder"]}
        )

      %{"result" => %{"state" => "closed"}} =
        dispatch!(plan, old["port"], device, "revoke-assignment", %{
          "assignmentId" => id,
          "reason" => "restart lifecycle control"
        })

      ws = subscribe!(old["port"], device.token, ["assignment."])

      try do
        %{"result" => %{"state" => "open"}} =
          dispatch!(plan, old["port"], device, "reopen-assignment", %{
            "assignmentId" => id,
            "reason" => "First restart"
          })

        {:ok, {:text, raw}, _} = WS.recv(ws, 2_000)

        assert %{
                 "class" => "assignment.reopened",
                 "refs" => %{"assignmentId" => ^id},
                 "payload" => snapshot
               } = JSON.decode!(raw)

        assert assignment_detail!(old["port"], device.token, id) == snapshot
        before = dispatch!(plan, old["port"], device, "assignment-get", %{"assignmentId" => id})
        assert %{"result" => %{"reopenings" => [%{"reason" => "First restart"}]}} = before
        generations = generations!(plan, "first", id)
        assert [[1, "canceled", _], [2, "armed", _]] = generations
        File.write!(Path.join(plan.base, "first-stop"), "stop\n")
        assert {:ok, {:closed, 1012}, _} = WS.recv_event(ws, 5_000)
        assert exit!(first, plan, "first") == 0
        second = launch(plan, "second", true)

        try do
          new = receipt!(second, plan, "second")
          assert new["pid"] != old["pid"]
          assert new["base"] == old["base"]
          assert new["port"] == old["port"]
          assert new["marker"] == old["marker"]
          assert generations!(plan, "second", id) == generations

          assert dispatch!(plan, new["port"], device, "assignment-get", %{"assignmentId" => id}) ==
                   before

          assert assignment_detail!(new["port"], device.token, id) == snapshot
          resumed = subscribe!(new["port"], device.token, ["assignment."])

          try do
            %{"result" => %{"state" => "closed"}} =
              dispatch!(plan, new["port"], device, "revoke-assignment", %{
                "assignmentId" => id,
                "reason" => "restart lifecycle control"
              })

            {:ok, {:text, raw}, _} = WS.recv(resumed, 2_000)

            assert %{
                     "class" => "assignment.closed",
                     "payload" => %{"outcome" => "revoked"} = closed
                   } = JSON.decode!(raw)

            assert assignment_detail!(new["port"], device.token, id) == closed

            %{"result" => %{"state" => "open"}} =
              dispatch!(plan, new["port"], device, "reopen-assignment", %{
                "assignmentId" => id,
                "reason" => "After restart"
              })

            {:ok, {:text, raw}, _} = WS.recv(resumed, 2_000)
            assert %{"class" => "assignment.reopened", "payload" => reopened} = JSON.decode!(raw)
            assert assignment_detail!(new["port"], device.token, id) == reopened

            %{"result" => %{"reopenings" => history}} =
              dispatch!(plan, new["port"], device, "assignment-get", %{"assignmentId" => id})

            assert Enum.map(history, & &1["reason"]) == ["First restart", "After restart"]
            File.write!(Path.join(plan.base, "second-stop"), "stop\n")
            assert {:ok, {:closed, 1012}, _} = WS.recv_event(resumed, 5_000)
            assert exit!(second, plan, "second") == 0

            IO.puts(
              JSON.encode!(%{
                "assignmentId" => id,
                "oldPid" => old["pid"],
                "newPid" => new["pid"],
                "generations" => generations,
                "history" => history
              })
            )
          after
            WS.close(resumed)
          end
        after
          cleanup!(second, plan, "second")
        end
      after
        WS.close(ws)
      end
    after
      cleanup!(first, plan, "first")
    end

    refute File.exists?(Path.join(plan.base, "forbidden-execution.log"))
    assert Tightbeam.HarnessProcessCensus.capture_for_root(plan.base).count == 0
  end

  defp generations!(plan, phase, id) do
    path = Path.join(plan.base, phase <> "-generations-request.json")
    File.write!(path <> ".tmp", JSON.encode!(%{"assignmentId" => id}))
    File.rename!(path <> ".tmp", path)
    result = Path.join(plan.base, phase <> "-generations.json")
    deadline = System.monotonic_time(:millisecond) + 5_000

    wait = fn recur ->
      if File.regular?(result) do
        JSON.decode!(File.read!(result))
      else
        assert System.monotonic_time(:millisecond) < deadline, "generation receipt deadline"
        Process.sleep(10)
        recur.(recur)
      end
    end

    wait.(wait)
  end

  defp dispatch!(plan, port, device, verb, params, extra \\ %{}) do
    %{"cliToken" => token} =
      Path.join(plan.base, "gateway.json") |> File.read!() |> JSON.decode!()

    headers = [
      {~c"authorization", String.to_charlist("Bearer " <> token)},
      {~c"x-tightbeam-cli-version",
       String.to_charlist(Tightbeam.CliCompatibility.required_version())}
    ]

    body =
      JSON.encode!(
        Map.merge(%{"verb" => verb, "asUser" => device.user_id, "params" => params}, extra)
      )

    {:ok, {{_, 200, _}, _, raw}} =
      :httpc.request(
        :post,
        {~c"http://127.0.0.1:#{port}/agent/dispatch", headers, ~c"application/json", body},
        [timeout: 2_000],
        body_format: :binary
      )

    JSON.decode!(raw)
  end

  defp assignment_detail!(port, token, id) do
    {:ok, {{_, 200, _}, _, raw}} =
      :httpc.request(
        :get,
        {~c"http://127.0.0.1:#{port}/api/assignments/#{id}",
         [{~c"authorization", String.to_charlist("Bearer " <> token)}]},
        [timeout: 2_000],
        body_format: :binary
      )

    JSON.decode!(raw)["item"]
  end

  @tag :tmp_dir
  @tag :cold_executable_refusal
  @tag timeout: 60_000
  test "cold startup refuses absent registered executables and leaves no serving child", %{
    tmp_dir: tmp
  } do
    plan = Tightbeam.GuardRuntimeFixture.prepare!(tmp, "firehose_cold_restart.exs")
    plan = %{plan | env: plan.env ++ [{"FIREHOSE_MISSING_EXECUTABLE", "1"}]}
    port = launch(plan, "first")
    {:os_pid, pid} = Port.info(port, :os_pid)

    try do
      assert exit!(port, plan, "first", System.monotonic_time(:millisecond) + 30_000) == 1
      assert read_log(plan, "first") =~ "no usable harness CLI is installed"
      evidence = JSON.decode!(File.read!(Path.join(plan.base, "refusal-input.json")))
      assert evidence["pid"] == Integer.to_string(pid)
      assert File.read!(Path.join(plan.base, "build-owner.json")) == evidence["marker"]
      assert evidence["requestedPort"] in 1..65_535
      assert evidence["boundPort"] == nil
      refute File.exists?(Path.join(plan.base, "restart-port"))
      refute File.exists?(Path.join(plan.base, "first-ready.json"))
      assert Port.info(port) == nil

      assert {:error, :econnrefused} =
               :gen_tcp.connect(
                 {127, 0, 0, 1},
                 evidence["requestedPort"],
                 [:binary, active: false],
                 1_000
               )

      refute File.exists?(Path.join(plan.base, "forbidden-execution.log"))
      assert Tightbeam.HarnessProcessCensus.capture_for_root(plan.base).count == 0
      IO.puts(JSON.encode!(%{"refusedPid" => pid, "exit" => 1, "portClosed" => true}))
    after
      cleanup!(port, plan, "first")
    end
  end

  @tag :tmp_dir
  @tag :cold_disconnected_convergence
  @tag timeout: 60_000
  test "full canonical snapshot recovers writes committed while the client is disconnected", %{
    tmp_dir: tmp
  } do
    plan = Tightbeam.GuardRuntimeFixture.prepare!(tmp, "firehose_cold_restart.exs")
    child = launch(plan, "first")

    try do
      boot = receipt!(child, plan, "first")

      {:ok, device} =
        SimClient.pair("127.0.0.1", boot["port"],
          device_id: "disconnected-inventory",
          claimed_name: "Synthetic inventory"
        )

      ws = subscribe!(boot["port"], device.token)

      try do
        assert snapshot!(plan, boot["port"], device) == %{}
        first = create!(plan, boot["port"], device, "Before disconnect")
        assert_change!(ws, first)
        model = %{first["id"] => first}
        assert snapshot!(plan, boot["port"], device) == model
        :ok = WS.close(ws)
        second = create!(plan, boot["port"], device, "Committed while disconnected")
        resumed = subscribe!(boot["port"], device.token)

        try do
          rebuilt = snapshot!(plan, boot["port"], device)
          assert rebuilt == Map.put(model, second["id"], second)
          third = create!(plan, boot["port"], device, "After reconnect")
          assert_change!(resumed, third)
          rebuilt = Map.put(rebuilt, third["id"], third)
          assert map_size(rebuilt) == 3
          assert snapshot!(plan, boot["port"], device) == rebuilt
          File.write!(Path.join(plan.base, "first-stop"), "stop\n")
          assert {:ok, {:closed, 1012}, _} = WS.recv_event(resumed, 5_000)
          assert exit!(child, plan, "first") == 0

          IO.puts(
            JSON.encode!(%{
              "pid" => boot["pid"],
              "snapshotIds" => Enum.sort(Map.keys(rebuilt)),
              "exactSnapshotSize" => 3,
              "exit" => 0
            })
          )
        after
          WS.close(resumed)
        end
      after
        WS.close(ws)
      end
    after
      cleanup!(child, plan, "first")
    end

    refute File.exists?(Path.join(plan.base, "forbidden-execution.log"))
    census = Tightbeam.HarnessProcessCensus.capture_for_root(plan.base)
    assert census.count == 0, Tightbeam.HarnessProcessCensus.format(census)
  end

  @tag :tmp_dir
  test "cleanup rejects a surviving root process even after the gateway Port is gone", %{
    tmp_dir: tmp
  } do
    root = Path.expand(tmp)
    script = Path.join(root, "held-probe.sh")
    File.write!(script, "printf 'ready\\n'\nIFS= read -r release\nexit 0\n")

    probe =
      Port.open({:spawn_executable, ~c"/bin/sh"}, [
        :binary,
        :exit_status,
        args: [String.to_charlist(script)]
      ])

    try do
      assert_receive {^probe, {:data, "ready\n"}}, 2_000
      {:os_pid, probe_pid} = Port.info(probe, :os_pid)

      finished =
        Port.open({:spawn_executable, ~c"/bin/sh"}, [
          :exit_status,
          args: [~c"-c", ~c"exit 0"]
        ])

      assert_receive {^finished, {:exit_status, 0}}, 2_000
      assert Port.info(finished) == nil

      error =
        assert_raise ExUnit.AssertionError, fn ->
          cleanup!(finished, %{base: root}, "census-proof")
        end

      assert error.message =~ "census cleanup deadline"
      assert error.message =~ "harness fixture processes: 1"
      assert error.message =~ "pid=#{probe_pid} "
      assert error.message =~ script

      # The deadline must neither signal the survivor nor report it as gone.
      assert Port.info(probe, :os_pid) == {:os_pid, probe_pid}
      assert Port.command(probe, "release\n")
      assert_receive {^probe, {:exit_status, 0}}, 2_000
      assert cleanup!(finished, %{base: root}, "census-proof") == :ok
      assert Tightbeam.HarnessProcessCensus.capture_for_root(root).count == 0
    after
      if Port.info(probe) do
        Port.command(probe, "release\n")
        assert_receive {^probe, {:exit_status, 0}}, 2_000
      end
    end
  end

  defp snapshot!(plan, port, device) do
    %{"result" => %{"workItems" => items}} = dispatch!(plan, port, device, "work-item-list", %{})
    assert length(items) == length(Enum.uniq_by(items, & &1["id"]))

    Map.new(items, fn legacy ->
      item = detail!(port, device.token, legacy["id"])
      shared = Map.keys(legacy) -- (Map.keys(legacy) -- Map.keys(item))
      assert Map.take(legacy, shared) == Map.take(item, shared)
      assert is_integer(legacy["priority"])
      {legacy["id"], item}
    end)
  end

  defp launch(plan, phase, reopen \\ false, direct_apply_matrix \\ false) do
    env =
      plan.env ++
        [
          {"FIREHOSE_RESTART_PHASE", phase},
          {"FIREHOSE_REOPEN_PROOF", if(reopen, do: "1", else: "0")},
          {"FIREHOSE_DIRECT_APPLY_MATRIX", if(direct_apply_matrix, do: "1", else: "0")}
        ]

    Port.open({:spawn_executable, String.to_charlist(plan.executable)}, [
      :binary,
      :exit_status,
      :stderr_to_stdout,
      args: Enum.map(plan.args, &String.to_charlist/1),
      env:
        Enum.map(env, fn {key, value} ->
          {String.to_charlist(key), if(is_nil(value), do: false, else: String.to_charlist(value))}
        end)
    ])
  end

  defp receipt!(port, plan, phase, deadline \\ nil) do
    deadline = deadline || System.monotonic_time(:millisecond) + 30_000
    path = Path.join(plan.base, phase <> "-ready.json")

    if File.regular?(path) do
      JSON.decode!(File.read!(path))
    else
      assert System.monotonic_time(:millisecond) < deadline, "boot deadline: #{plan.base}"

      receive do
        {^port, {:data, data}} ->
          log!(plan, phase, data)
          receipt!(port, plan, phase, deadline)

        {^port, {:exit_status, status}} ->
          flunk("gateway #{phase} exited #{status}: #{read_log(plan, phase)}")
      after
        10 -> receipt!(port, plan, phase, deadline)
      end
    end
  end

  defp exit!(port, plan, phase, deadline \\ nil) do
    deadline = deadline || System.monotonic_time(:millisecond) + 10_000
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {^port, {:data, data}} ->
        log!(plan, phase, data)
        exit!(port, plan, phase, deadline)

      {^port, {:exit_status, status}} ->
        File.write!(Path.join(plan.base, phase <> "-exit"), Integer.to_string(status))
        status
    after
      remaining -> :timeout
    end
  end

  defp cleanup!(port, plan, phase) do
    if info = Port.info(port, :os_pid) do
      {:os_pid, pid} = info
      assert pid > 1
      System.cmd("kill", ["-TERM", Integer.to_string(pid)], stderr_to_stdout: true)

      case exit!(port, plan, phase, System.monotonic_time(:millisecond) + 2_000) do
        :timeout ->
          {:os_pid, ^pid} = Port.info(port, :os_pid)
          System.cmd("kill", ["-KILL", Integer.to_string(pid)], stderr_to_stdout: true)
          assert is_integer(exit!(port, plan, phase))

        status ->
          assert is_integer(status)
      end
    end

    # Port exit need not coincide with the end of a fixture version probe.
    # Wait on the actual census even when the gateway Port is already gone;
    # a persistent survivor still fails, with its identity, at the deadline.
    await_census_zero!(plan.base, System.monotonic_time(:millisecond) + 2_000)
  end

  defp await_census_zero!(root, deadline) do
    census = Tightbeam.HarnessProcessCensus.capture_for_root(root)
    remaining = deadline - System.monotonic_time(:millisecond)

    cond do
      census.count == 0 ->
        :ok

      remaining <= 0 ->
        flunk("census cleanup deadline: " <> Tightbeam.HarnessProcessCensus.format(census))

      true ->
        Process.sleep(min(25, remaining))
        await_census_zero!(root, deadline)
    end
  end

  defp log!(plan, phase, data),
    do: File.write!(Path.join(Path.dirname(plan.base), phase <> ".log"), data, [:append])

  defp read_log(plan, phase) do
    case File.read(Path.join(Path.dirname(plan.base), phase <> ".log")) do
      {:ok, log} -> log
      _ -> "(no output)"
    end
  end

  defp subscribe!(port, token, classes \\ ["work_item.created"]) do
    {:ok, ws} = WS.connect("127.0.0.1", port, "/ws/changes?protocolVersion=2")
    :ok = WS.send_text(ws, JSON.encode!(%{"type" => "auth", "token" => token}))
    {:ok, {:text, raw}, ws} = WS.recv(ws, 2_000)
    assert %{"type" => "auth_result", "success" => true} = JSON.decode!(raw)

    :ok =
      WS.send_text(
        ws,
        JSON.encode!(%{
          "type" => "subscribe",
          "protocolVersion" => 2,
          "subscriptionId" => "restart",
          "filters" => %{"classes" => classes}
        })
      )

    {:ok, {:text, raw}, ws} = WS.recv(ws, 2_000)
    assert %{"type" => "subscription_ready"} = JSON.decode!(raw)
    ws
  end

  defp assert_change!(ws, item) do
    {:ok, {:text, raw}, _} = WS.recv(ws, 2_000)

    assert %{"type" => "change", "class" => "work_item.created", "payload" => ^item} =
             JSON.decode!(raw)
  end

  defp create!(plan, port, device, title) do
    %{"cliToken" => token} =
      Path.join(plan.base, "gateway.json") |> File.read!() |> JSON.decode!()

    headers = [
      {~c"authorization", String.to_charlist("Bearer " <> token)},
      {~c"x-tightbeam-cli-version",
       String.to_charlist(Tightbeam.CliCompatibility.required_version())}
    ]

    body =
      JSON.encode!(%{
        "verb" => "work-item-create",
        "asUser" => device.user_id,
        "params" => %{"title" => title}
      })

    {:ok, {{_, 200, _}, _, raw}} =
      :httpc.request(
        :post,
        {~c"http://127.0.0.1:#{port}/agent/dispatch", headers, ~c"application/json", body},
        [timeout: 2_000],
        body_format: :binary
      )

    %{"result" => %{"id" => id}} = JSON.decode!(raw)
    detail!(port, device.token, id)
  end

  defp detail!(port, token, id) do
    {:ok, {{_, 200, _}, _, raw}} =
      :httpc.request(
        :get,
        {~c"http://127.0.0.1:#{port}/api/work-items/#{id}",
         [{~c"authorization", String.to_charlist("Bearer " <> token)}]},
        [timeout: 2_000],
        body_format: :binary
      )

    JSON.decode!(raw)["item"]
  end

  defp direct_apply_resources("before") do
    [
      {"work-items", "workItemId", "work_item.updated"},
      {"assignments", "assignmentId", "assignment.closed"},
      {"attests", "attestAssignmentId", "attest.filed"},
      {"artifacts", "workItemId", "artifact.recorded"},
      {"turns", "workItemId", "turn.queued"},
      {"wakes", "wakeId", "wake.scheduled"},
      {"sessions", "sessionKey", "session.updated"}
    ]
  end

  defp direct_apply_resources("after") do
    [
      {"work-items", "workItemId", "work_item.updated"},
      {"assignments", "assignmentId", "assignment.reopened"},
      {"attests", "attestAssignmentId", "attest.filed"},
      {"artifacts", "workItemId", "artifact.recorded"},
      {"turns", "workItemId", "turn.queued"},
      {"wakes", "wakeId", "wake.scheduled"},
      {"sessions", "sessionKey", "session.updated"}
    ]
  end

  defp direct_apply_command(ids, {resource, key_name, expected_class}, phase) do
    key = Map.fetch!(ids, key_name)

    {%{"op" => "mutate", "resource" => resource, "phase" => phase, key_name => key},
     expected_class}
  end

  defp direct_apply_seed_model!(port, token, ids) do
    direct_apply_complete_model!(port, token, ids)
  end

  defp direct_apply_complete_model!(port, token, ids) do
    sessions = direct_apply_collection_rows!(port, token, "/api/sessions")

    assignments =
      [ids["assignmentId"], ids["attestAssignmentId"]]
      |> Enum.uniq()
      |> Enum.map(&direct_apply_rest_row!(port, token, "assignments", &1))

    resource_rows = [
      {"work-items", direct_apply_collection_rows!(port, token, "/api/work-items")},
      {"assignments", assignments},
      {"attests", direct_apply_collection_rows!(port, token, "/api/attests")},
      {"artifacts", direct_apply_collection_rows!(port, token, "/api/artifacts")},
      {"turns", direct_apply_session_rows!(port, token, sessions, "turns")},
      {"wakes", direct_apply_session_rows!(port, token, sessions, "wakes")},
      {"sessions", sessions}
    ]

    Enum.reduce(resource_rows, %{}, fn {resource, rows}, model ->
      Enum.reduce(rows, model, fn row, acc ->
        key = direct_apply_row_key(resource, row)
        Map.put(acc, {resource, key}, %{"rowVersion" => row["rowVersion"], "value" => row})
      end)
    end)
  end

  defp direct_apply_model_diff(client, snapshot) do
    client_keys = Map.keys(client) |> MapSet.new()
    snapshot_keys = Map.keys(snapshot) |> MapSet.new()
    common = MapSet.intersection(client_keys, snapshot_keys)

    changed =
      common
      |> Enum.filter(&(Map.fetch!(client, &1) != Map.fetch!(snapshot, &1)))
      |> Enum.take(5)
      |> Enum.map(fn key ->
        held = Map.fetch!(client, key)
        current = Map.fetch!(snapshot, key)

        %{
          key: key,
          held_version: held["rowVersion"],
          snapshot_version: current["rowVersion"],
          held_row: held["value"],
          snapshot_row: current["value"]
        }
      end)

    %{
      missing: MapSet.difference(snapshot_keys, client_keys) |> Enum.take(10),
      extra: MapSet.difference(client_keys, snapshot_keys) |> Enum.take(10),
      changed: changed
    }
  end

  defp direct_apply_session_rows!(port, token, sessions, resource) do
    Enum.flat_map(sessions, fn session ->
      session_key = URI.encode(session["sessionKey"])
      direct_apply_collection_rows!(port, token, "/api/sessions/#{session_key}/#{resource}")
    end)
  end

  defp direct_apply_collection_rows!(port, token, path) do
    direct_apply_collection_pages!(port, token, path, nil, [])
  end

  defp direct_apply_collection_pages!(port, token, path, cursor, rows) do
    query =
      if is_nil(cursor),
        do: "?limit=500&tail=false",
        else: "?limit=500&after=#{URI.encode_www_form(cursor)}"

    body = direct_apply_get!(port, token, path <> query)
    rows = rows ++ body["items"]
    page = body["page"]

    if Map.get(page, "after", Map.get(page, "hasMoreAfter", false)) do
      next_cursor = Map.get(page, "newest") || Map.get(page, "newestCursor")
      direct_apply_collection_pages!(port, token, path, next_cursor, rows)
    else
      rows
    end
  end

  defp direct_apply_get!(port, token, path) do
    {:ok, {{_, 200, _}, _, raw}} =
      :httpc.request(
        :get,
        {String.to_charlist("http://127.0.0.1:#{port}#{path}"),
         [{~c"authorization", String.to_charlist("Bearer " <> token)}]},
        [timeout: 2_000],
        body_format: :binary
      )

    JSON.decode!(raw)
  end

  defp direct_apply_row_key("work-items", row), do: row["id"]
  defp direct_apply_row_key("assignments", row), do: row["id"]
  defp direct_apply_row_key("attests", row), do: row["id"]
  defp direct_apply_row_key("artifacts", row), do: row["artifactId"]
  defp direct_apply_row_key("turns", row), do: row["seq"]
  defp direct_apply_row_key("wakes", row), do: row["wakeId"]
  defp direct_apply_row_key("sessions", row), do: row["sessionKey"]

  defp direct_apply_apply(model, resource, key, row) do
    version = row["rowVersion"]

    case model[{resource, key}] do
      %{"rowVersion" => held} when held >= version -> model
      _ -> Map.put(model, {resource, key}, %{"rowVersion" => version, "value" => row})
    end
  end

  defp direct_apply_apply_notice(model, notice) do
    resource = notice["resource"]
    row = notice["payload"]
    direct_apply_apply(model, resource, direct_apply_row_key(resource, row), row)
  end

  defp direct_apply_rest_row!(port, token, resource, key) do
    path = direct_apply_detail_path(resource, key)

    {:ok, {{_, 200, _}, _, raw}} =
      :httpc.request(
        :get,
        {String.to_charlist("http://127.0.0.1:#{port}#{path}"),
         [{~c"authorization", String.to_charlist("Bearer " <> token)}]},
        [timeout: 2_000],
        body_format: :binary
      )

    JSON.decode!(raw)["item"]
  end

  defp direct_apply_detail_path("work-items", key), do: "/api/work-items/#{key}"
  defp direct_apply_detail_path("assignments", key), do: "/api/assignments/#{key}"
  defp direct_apply_detail_path("attests", key), do: "/api/attests/#{key}"
  defp direct_apply_detail_path("artifacts", key), do: "/api/artifacts/#{key}"
  defp direct_apply_detail_path("turns", key), do: "/api/turns/#{key}"
  defp direct_apply_detail_path("wakes", key), do: "/api/wakes/#{key}"
  defp direct_apply_detail_path("sessions", key), do: "/api/sessions/#{URI.encode(key)}"

  defp receive_direct_apply_notice!(ws, result, skipped \\ []) do
    case WS.recv(ws, 5_000) do
      {:ok, {:text, raw}, next_ws} ->
        frame = JSON.decode!(raw)

        if frame["type"] == "change" and frame["class"] == result["class"] and
             frame["resource"] == result["resource"] and
             frame["payload"][result["keyField"]] == result["key"] do
          {frame, next_ws, Enum.reverse(skipped)}
        else
          skipped = if frame["type"] == "change", do: [frame | skipped], else: skipped
          receive_direct_apply_notice!(next_ws, result, skipped)
        end

      {:error, :timeout, _ws} ->
        flunk(
          "timed out waiting for #{inspect(Map.take(result, ["class", "resource", "keyField", "key"]))}; " <>
            "last changes: #{inspect(Enum.take(Enum.reverse(skipped), -8))}"
        )

      other ->
        flunk(
          "unexpected WebSocket result while waiting for #{inspect(result)}: #{inspect(other)}"
        )
    end
  end

  defp direct_apply_action!(plan, phase, action) do
    request = Path.join(plan.base, phase <> "-matrix-request.json")
    response = Path.join(plan.base, phase <> "-matrix-response.json")
    File.rm(response)
    File.write!(request <> ".tmp", JSON.encode!(action))
    File.rename!(request <> ".tmp", request)
    wait_for_matrix_response!(response, System.monotonic_time(:millisecond) + 10_000)
  end

  defp wait_for_matrix_response!(response, deadline) do
    if File.regular?(response) do
      result = response |> File.read!() |> JSON.decode!()
      File.rm!(response)
      result
    else
      assert System.monotonic_time(:millisecond) < deadline,
             "direct-apply gateway action deadline"

      Process.sleep(10)
      wait_for_matrix_response!(response, deadline)
    end
  end
end
