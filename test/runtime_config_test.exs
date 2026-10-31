defmodule Tightbeam.RuntimeConfigTest do
  use Tightbeam.TestCase, async: false

  @runtime_env %{
    "TIGHTBEAM_BASE_DIR" => "/tmp/tightbeam-runtime-poison",
    "TIGHTBEAM_LIVE_BASE_TRANSITION" =>
      ~s({"base":"/tmp/tightbeam-runtime-poison","expectedSchema":"legacy018","source":"unmarked","target":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}),
    "TIGHTBEAM_PORT" => "4321",
    "TIGHTBEAM_CWD" => "/tmp/tightbeam-runtime-cwd",
    "TIGHTBEAM_DEFAULT_HARNESS" => "claude",
    "TIGHTBEAM_DEFAULT_MODEL" => "claude-sonnet-5",
    "TIGHTBEAM_DEFAULT_EFFORT" => "high",
    "TIGHTBEAM_DEFAULT_CONTEXT" => "large",
    "TIGHTBEAM_WAKE_TICK_MS" => "101",
    "TIGHTBEAM_SUPERVISION_INTERVAL_MS" => "off",
    "TIGHTBEAM_PROD_LIMIT" => "7",
    "TIGHTBEAM_ESCALATION_DECISION_DEADLINE_MS" => "202",
    "TIGHTBEAM_EFFORT_CHECKIN_HORIZON_MS" => "not-a-duration",
    "TIGHTBEAM_WORK_ITEM_TRIAGE_DEADLINE_MS" => "404",
    "TIGHTBEAM_ADVERTISED_URL" => "ws://runtime-poison:9999",
    "TIGHTBEAM_DRAIN_TIMEOUT_MS" => "505",
    "TIGHTBEAM_DB_CALL_TIMEOUT_MS" => "606",
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

  test "development and production ignore the retired effort horizon setting" do
    expected = [
      tightbeam: [
        base_dir: "/tmp/tightbeam-runtime-poison",
        live_base_guard: [
          transition:
            ~s({"base":"/tmp/tightbeam-runtime-poison","expectedSchema":"legacy018","source":"unmarked","target":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"})
        ],
        port: 4321,
        cwd: "/tmp/tightbeam-runtime-cwd",
        default_harness: :claude,
        default_model: %Tightbeam.Model{
          family: "claude-sonnet-5",
          effort: "high",
          context: "large"
        },
        wake_tick_ms: 101,
        supervision_interval_ms: :off,
        prod_limit: 7,
        escalation_decision_deadline_ms: 202,
        work_item_triage_deadline_ms: 404,
        advertised_url: "ws://runtime-poison:9999",
        drain_timeout_ms: 505,
        db_call_timeout_ms: 606,
        local_host_name: "runtime-poison-host"
      ]
    ]

    development = Config.Reader.read!("config/runtime.exs", env: :dev)
    production = Config.Reader.read!("config/runtime.exs", env: :prod)

    assert development == expected
    assert production == expected
    refute Keyword.has_key?(Keyword.fetch!(development, :tightbeam), :effort_checkin_horizon_ms)
    refute Keyword.has_key?(Keyword.fetch!(production, :tightbeam), :effort_checkin_horizon_ms)
  end

  test "production supervision period comes from the elected inactivity rail, not the wake tick" do
    previous_interval = Application.get_env(:tightbeam, :supervision_interval_ms)
    previous_tick = Application.get_env(:tightbeam, :wake_tick_ms)
    Application.delete_env(:tightbeam, :supervision_interval_ms)
    Application.put_env(:tightbeam, :wake_tick_ms, 101)

    on_exit(fn ->
      if is_nil(previous_interval),
        do: Application.delete_env(:tightbeam, :supervision_interval_ms),
        else: Application.put_env(:tightbeam, :supervision_interval_ms, previous_interval)

      if is_nil(previous_tick),
        do: Application.delete_env(:tightbeam, :wake_tick_ms),
        else: Application.put_env(:tightbeam, :wake_tick_ms, previous_tick)
    end)

    {Tightbeam.Boot, config} =
      Enum.find(Tightbeam.Application.children(), &match?({Tightbeam.Boot, _}, &1))

    assert is_nil(Map.fetch!(config, :supervision_interval_ms))
    assert Tightbeam.Supervision.policy_default_interval_ms() == 1_800_000
  end
end
