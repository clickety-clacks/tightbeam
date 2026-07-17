import Config
# Keep the auto-started app off the real ~/.tightbeam during tests.
config :tightbeam, :base_dir, Path.join(System.tmp_dir!(), "tightbeam_test_#{:erlang.unique_integer([:positive])}")
config :tightbeam, :autostart, false
