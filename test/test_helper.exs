ExUnit.start()

suite_tmp = Application.fetch_env!(:tightbeam, :test_suite_tmp)

# Remove the suite scratch root when the VM exits, NOT after each suite run:
# `--repeat-until-failure` reruns the whole suite inside one BEAM and fires
# `ExUnit.after_suite/1` every time. Deleting the root between iterations leaves
# TMPDIR dangling, so `System.tmp_dir!/0` silently falls back to the shared /tmp
# and per-test scratch names collide across concurrent `mix test` processes.
System.at_exit(fn _status -> File.rm_rf!(suite_tmp) end)
