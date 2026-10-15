defmodule Tightbeam.SchedulerMissesTest do
  use Tightbeam.TestCase, async: false

  @tag timeout: 180_000
  test "doctor passes at clean gateway start and warns after an actual recorded miss" do
    cli_dir = Path.expand("../cli", __DIR__)

    {output, status} =
      System.cmd("cargo", ["build", "--release"], cd: cli_dir, stderr_to_stdout: true)

    assert status == 0, output
    binary = Path.join(cli_dir, "target/release/tightbeam")
    base = Path.join(System.tmp_dir!(), "event-path-doctor-#{System.unique_integer([:positive])}")
    File.mkdir_p!(base)
    on_exit(fn -> File.rm_rf!(base) end)

    # A separate VM proves startup zeros without resetting another test's counters.
    script = ~S'''
    [binary, base] = System.argv()
    import ExUnit.Assertions
    {:ok, _} = Application.ensure_all_started(:bandit)
    :ok = Tightbeam.SchedulerMisses.init()
    assert Tightbeam.SchedulerMisses.health() == %{count: 0, by_loop: %{wake: 0, recognition: 0, bubble: 0, lanes: 0, supervision: 0}, recent: []}
    {:ok, server} = Bandit.start_link(plug: {Tightbeam.Wire.Router, [cli_token: "test"]}, port: 0, ip: {127, 0, 0, 1}, startup_log: false)
    {:ok, {_, port}} = ThousandIsland.listener_info(server)
    File.write!(Path.join(base, "gateway.json"), JSON.encode!(%{port: port, cliToken: "test"}))
    doctor = fn json ->
      args = ["doctor", "--base-dir", base] ++ if(json, do: ["--json"], else: [])
      {text, _status} = System.cmd(binary, args, cd: base, stderr_to_stdout: false)
      text
    end
    assert doctor.(false) =~ "[PASS] event paths: no missed events since start"
    assert JSON.decode!(doctor.(true))["event_paths"]["level"] == "pass"
    :ok = Tightbeam.SchedulerMisses.record(:wake, "missed-wake", 65_000)
    text = doctor.(false)
    assert text =~ "[WARN] event paths: 1 missed events since start"
    assert text =~ "wake scheduler=1, recognition retry=0, bubble=0, lanes=0"
    assert text =~ "missed-wake"
    assert text =~ "65000 ms late"
    health = JSON.decode!(doctor.(true))["event_paths"]
    assert health["level"] == "warning"
    assert health["count"] == 1
    assert [%{"recordId" => "missed-wake", "lateMs" => 65_000, "at" => at}] = health["recent"]
    assert is_integer(at)
    Tightbeam.SchedulerMisses.record(:recognition, "retry", 70_000)
    Tightbeam.SchedulerMisses.record(:bubble, 42, 80_000)
    Tightbeam.SchedulerMisses.record(:lane_terminal, 43, 90_000)
    Tightbeam.SchedulerMisses.record(:lane, "lane")
    Tightbeam.SchedulerMisses.record(:supervision, "terminal session=recipient", 70_000)
    health = JSON.decode!(doctor.(true))["event_paths"]
    assert health["byLoop"] == %{"wake" => 1, "recognition" => 1, "bubble" => 1, "lanes" => 2, "supervision" => 1}
    assert health["count"] == 6
    assert doctor.(false) =~ "terminal session=recipient"
    IO.puts("event-path-doctor: ok")
    '''

    paths = Enum.flat_map(:code.get_path(), fn path -> ["-pa", to_string(path)] end)

    {output, status} =
      System.cmd(System.find_executable("elixir"), paths ++ ["-e", script, binary, base],
        stderr_to_stdout: true
      )

    assert status == 0, output
    assert output =~ "event-path-doctor: ok"
  end
end
