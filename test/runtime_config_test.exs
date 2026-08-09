defmodule Tightbeam.RuntimeConfigTest do
  use Tightbeam.TestCase, async: false

  @runtime_env %{
    "TIGHTBEAM_BASE_DIR" => "/tmp/tightbeam-runtime-poison",
    "TIGHTBEAM_PORT" => "4321",
    "TIGHTBEAM_CWD" => "/tmp/tightbeam-runtime-cwd",
    "TIGHTBEAM_DEFAULT_HARNESS" => "claude",
    "TIGHTBEAM_DEFAULT_MODEL" => "claude-sonnet-5",
    "TIGHTBEAM_DEFAULT_EFFORT" => "high",
    "TIGHTBEAM_DEFAULT_CONTEXT" => "large",
    "TIGHTBEAM_WAKE_TICK_MS" => "101",
    "TIGHTBEAM_PROD_LIMIT" => "7",
    "TIGHTBEAM_ESCALATION_DECISION_DEADLINE_MS" => "202",
    "TIGHTBEAM_EFFORT_CHECKIN_HORIZON_MS" => "303",
    "TIGHTBEAM_WORK_ITEM_TRIAGE_DEADLINE_MS" => "404",
    "TIGHTBEAM_ADVERTISED_URL" => "ws://runtime-poison:9999",
    "TIGHTBEAM_DRAIN_TIMEOUT_MS" => "505",
    "TIGHTBEAM_LOCAL_HOST_NAME" => "runtime-poison-host"
  }

  setup do
    previous = Map.take(System.get_env(), Map.keys(@runtime_env))
    System.put_env(@runtime_env)

    on_exit(fn ->
      Enum.each(Map.keys(@runtime_env), &System.delete_env/1)
      System.put_env(previous)
    end)
  end

  test "test config is immune to exported runtime config variables" do
    assert Config.Reader.read!("config/runtime.exs", env: :test) == []

    assert Application.fetch_env!(:tightbeam, :local_host_name) == "testhost"
    refute Application.fetch_env!(:tightbeam, :base_dir) == @runtime_env["TIGHTBEAM_BASE_DIR"]

    refute Application.get_env(:tightbeam, :advertised_url) ==
             @runtime_env["TIGHTBEAM_ADVERTISED_URL"]
  end

  test "development and production still read every runtime config variable" do
    expected = [
      tightbeam: [
        base_dir: "/tmp/tightbeam-runtime-poison",
        port: 4321,
        cwd: "/tmp/tightbeam-runtime-cwd",
        default_harness: :claude,
        default_model: %Tightbeam.Model{
          family: "claude-sonnet-5",
          effort: "high",
          context: "large"
        },
        wake_tick_ms: 101,
        prod_limit: 7,
        escalation_decision_deadline_ms: 202,
        effort_checkin_horizon_ms: 303,
        work_item_triage_deadline_ms: 404,
        advertised_url: "ws://runtime-poison:9999",
        drain_timeout_ms: 505,
        local_host_name: "runtime-poison-host"
      ]
    ]

    assert Config.Reader.read!("config/runtime.exs", env: :dev) == expected
    assert Config.Reader.read!("config/runtime.exs", env: :prod) == expected
  end
end
