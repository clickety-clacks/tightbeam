import Config

suite_nonce =
  12
  |> :crypto.strong_rand_bytes()
  |> Base.url_encode64(padding: false)

suite_tmp =
  Path.join(
    System.tmp_dir!(),
    "tightbeam-test-#{System.pid()}-#{suite_nonce}"
  )

File.mkdir_p!(suite_tmp)
System.put_env("TMPDIR", suite_tmp)

# Keep the auto-started app off the real ~/.tightbeam during tests.
config :tightbeam,
       :base_dir,
       Path.join(suite_tmp, "app")

config :tightbeam, :autostart, false
config :tightbeam, :local_host_name, "testhost"
config :tightbeam, :fixture_harness, true
config :tightbeam, :test_suite_tmp, suite_tmp
config :tightbeam, :port, 0

# The child lifetime wrapper must be the CLI from this same checkout.
config :tightbeam, :harklight_child_opts,
  base_dir: Path.join(suite_tmp, "harklight"),
  cli_path: Path.expand("../cli/target/release/tightbeam", __DIR__)

# Most lifecycle tests exercise ordering rather than wall-clock retry policy.
# Pacing regressions supply production intervals with a virtual clock.
config :tightbeam, :harklight_recovery_options,
  attach_spacing_ms: 0,
  slow_attach_spacing_ms: 0,
  outage_notice_delay_ms: 0,
  cooldown_base_ms: 1,
  cooldown_max_ms: 2
