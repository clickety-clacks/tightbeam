ExUnit.start()

suite_tmp = Application.fetch_env!(:tightbeam, :test_suite_tmp)

ExUnit.after_suite(fn _result ->
  File.rm_rf!(suite_tmp)
end)
