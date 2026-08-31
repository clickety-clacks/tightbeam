import Config

# The Firehose restart acceptance fixture boots the real application in a child
# test VM. That VM must use the test registry because CI deliberately provides
# only the in-repo Fixture harness CLI. Ordinary test VMs keep autostart off.
firehose_acceptance_gateway? =
  System.get_env("TIGHTBEAM_FIREHOSE_ACCEPTANCE_GATEWAY") == "1"

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
       if(firehose_acceptance_gateway?,
         do: System.fetch_env!("TIGHTBEAM_BASE_DIR"),
         else: Path.join(suite_tmp, "app")
       )

config :tightbeam, :autostart, firehose_acceptance_gateway?
config :tightbeam, :local_host_name, "testhost"
config :tightbeam, :fixture_harness, true
config :tightbeam, :test_suite_tmp, suite_tmp

config :tightbeam,
       :port,
       if(firehose_acceptance_gateway?,
         do: System.fetch_env!("TIGHTBEAM_PORT") |> String.to_integer(),
         else: 0
       )
