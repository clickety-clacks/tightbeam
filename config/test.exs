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
config :tightbeam, :coordinator_hold_alerts_enabled, false
config :tightbeam, :local_host_name, "testhost"
config :tightbeam, :fixture_harness, true
config :tightbeam, :test_suite_tmp, suite_tmp
config :tightbeam, :port, 0

# Shipped bundles plus the agentic-engineering bundle that 0.1.16 and earlier
# shipped. It is no longer packaged, but organizations that learned it keep it,
# so tests still learn it from this fixture root.
config :tightbeam,
       :kungfu_bundle_root_dir,
       Path.expand("../test/support/fixtures/kungfu", __DIR__)

# The child lifetime wrapper must be the CLI from this same checkout.
config :tightbeam, :harklight_child_opts,
  base_dir: Path.join(suite_tmp, "harklight"),
  cli_path: Path.expand("../cli/target/release/tightbeam", __DIR__)
