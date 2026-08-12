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
    "TIGHTBEAM_LOCAL_HOST_NAME" => "runtime-poison-host",
    "TIGHTBEAM_MAX_LIVE_SESSIONS_PER_USER" => "606"
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
        local_host_name: "runtime-poison-host",
        max_live_sessions_per_user: 606
      ]
    ]

    assert Config.Reader.read!("config/runtime.exs", env: :dev) == expected
    assert Config.Reader.read!("config/runtime.exs", env: :prod) == expected
  end

  test "an absent live-session cap leaves the runtime setting unset" do
    System.delete_env("TIGHTBEAM_MAX_LIVE_SESSIONS_PER_USER")

    runtime_config = Config.Reader.read!("config/runtime.exs", env: :prod)

    refute Keyword.has_key?(runtime_config[:tightbeam], :max_live_sessions_per_user)
  end

  test "a live-session cap accepts the entire positive ASCII base-10 form" do
    value = "99999999999999999999999999999999999999999999999999"
    System.put_env("TIGHTBEAM_MAX_LIVE_SESSIONS_PER_USER", value)

    runtime_config = Config.Reader.read!("config/runtime.exs", env: :prod)

    assert runtime_config[:tightbeam][:max_live_sessions_per_user] == String.to_integer(value)
  end

  test "an invalid live-session cap fails with a safe variable-specific error" do
    invalid_values = [
      "",
      "0",
      "+1",
      "-1",
      " 1",
      "1 ",
      "\t1",
      "1\n",
      "1_000",
      "1,000",
      "١",
      "one"
    ]

    for value <- invalid_values do
      System.put_env("TIGHTBEAM_MAX_LIVE_SESSIONS_PER_USER", value)

      error =
        assert_raise RuntimeError, fn ->
          Config.Reader.read!("config/runtime.exs", env: :prod)
        end

      assert error.message ==
               "TIGHTBEAM_MAX_LIVE_SESSIONS_PER_USER must be a positive base-10 integer"
    end
  end
end
