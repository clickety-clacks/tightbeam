defmodule Tightbeam.FirehoseRestartSmokeTest do
  use Tightbeam.TestCase, async: false

  alias Tightbeam.ClientE2E.{LegGateway, WS}
  alias Tightbeam.FirehoseAcceptanceFixture, as: Fixture

  @moduledoc """
  Firehose acceptance map: A5 gateway-kill 1012/reconnect/rebuild and A7's real
  external-client restart journey are automated here in the ordinary Linux and
  macOS Mix gate. Card 1's A5 slow-consumer 4008 journey remains in
  `Tightbeam.FirehoseSmokeTest` and runs in the same gate.
  """

  test "a real client observes exact gateway death, reconnects, rebuilds, and converges" do
    Fixture.with_subprocess!(fn fixture ->
      gateway = Fixture.active_subprocess(fixture)
      assert LegGateway.ours?(gateway)
      assert gateway.port == fixture.port
      assert gateway.base_dir == fixture.base_dir
      assert File.exists?(fixture.db_path)

      ws = Fixture.connect(fixture)
      assert Fixture.snapshot(fixture) == %{}

      first = Fixture.create_item(fixture, "Before gateway restart")
      {first_notice, ws} = Fixture.recv_change(ws)
      assert first_notice["refs"]["workItemId"] == first

      model = %{first => first_notice["payload"]}
      assert model == Fixture.snapshot(fixture)

      kill = Task.async(fn -> Fixture.kill_subprocess!(fixture) end)
      close_result = Fixture.recv_close(ws, 30_000)
      killed = Task.await(kill, 60_000)

      assert killed.os_pid == gateway.os_pid
      refute LegGateway.ours?(killed)
      assert Fixture.port_closed?(fixture.port)
      assert {:ok, {:closed, 1012}, closed_ws} = close_result
      assert :ok = WS.close(closed_ws)

      restarted = Fixture.restart_subprocess!(fixture)
      assert restarted.os_pid != killed.os_pid
      assert restarted.port == killed.port
      assert restarted.base_dir == killed.base_dir
      assert LegGateway.ours?(restarted)
      assert File.exists?(fixture.db_path)

      ws = Fixture.connect(fixture)
      rebuilt = Fixture.snapshot(fixture)
      assert rebuilt == model

      second = Fixture.create_item(fixture, "After gateway restart")
      {second_notice, ws} = Fixture.recv_change(ws)
      assert second_notice["refs"]["workItemId"] == second

      rebuilt = Map.put(rebuilt, second, second_notice["payload"])
      assert rebuilt == Fixture.snapshot(fixture)
      assert :ok = WS.close(ws)
    end)
  end

  test "registered test child refuses startup when its deterministic executable is absent" do
    output =
      ExUnit.CaptureIO.capture_io(:stderr, fn ->
        assert_raise RuntimeError, ~r/gateway did not boot: :child_exited/, fn ->
          Fixture.start_subprocess!(fixture_cli: false)
        end
      end)

    assert output =~ "no registered harness CLI is installed"
    assert output =~ "process_present?: false"
    assert output =~ "ready?: false"
  end

  test "parallel subprocess fixtures isolate state and a failing journey leaks nothing" do
    test_process = self()

    Fixture.with_subprocess!(fn survivor ->
      survivor_gateway = Fixture.active_subprocess(survivor)
      survivor_ws = Fixture.connect(survivor)

      assert_raise RuntimeError, "forced journey failure", fn ->
        Fixture.with_subprocess!(fn doomed ->
          doomed_gateway = Fixture.active_subprocess(doomed)
          _doomed_ws = Fixture.connect(doomed)

          assert survivor.base_dir != doomed.base_dir
          assert survivor.db_path != doomed.db_path
          assert survivor.port != doomed.port
          assert survivor_gateway.os_pid != doomed_gateway.os_pid
          assert survivor.process_tracker != doomed.process_tracker
          assert survivor.socket_tracker != doomed.socket_tracker

          survivor_create = Task.async(fn -> Fixture.create_item(survivor, "Survivor only") end)
          doomed_create = Task.async(fn -> Fixture.create_item(doomed, "Doomed only") end)
          survivor_id = Task.await(survivor_create)
          doomed_id = Task.await(doomed_create)

          {notice, survivor_ws} = Fixture.recv_change(survivor_ws)
          assert notice["refs"]["workItemId"] == survivor_id
          assert Map.keys(Fixture.snapshot(survivor)) == [survivor_id]
          assert Map.keys(Fixture.snapshot(doomed)) == [doomed_id]
          assert :ok = WS.close(survivor_ws)

          capture = Fixture.capture_subprocess(doomed)
          assert capture.sockets != []
          assert capture.processes != []
          send(test_process, {:doomed_capture, capture})

          raise "forced journey failure"
        end)
      end

      assert_receive {:doomed_capture, capture}
      assert Fixture.subprocess_released?(capture)
      assert LegGateway.ours?(Fixture.active_subprocess(survivor))
      assert File.exists?(survivor.db_path)

      ws = Fixture.connect(survivor)
      [survivor_id] = Map.keys(Fixture.snapshot(survivor))
      after_failure = Fixture.create_item(survivor, "After peer teardown")
      {notice, ws} = Fixture.recv_change(ws)
      assert notice["refs"]["workItemId"] == after_failure

      assert Enum.sort(Map.keys(Fixture.snapshot(survivor))) ==
               Enum.sort([survivor_id, after_failure])

      assert :ok = WS.close(ws)
    end)
  end
end
