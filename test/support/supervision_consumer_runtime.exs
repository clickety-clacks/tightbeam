[payload, base, locks, id, authority] = System.argv()
true = Path.expand(payload) == Path.expand(Application.app_dir(:tightbeam))
false = File.exists?(base)
{:ok, _} = Application.ensure_all_started(:exqlite)
{:ok, _} = Application.ensure_all_started(:crypto)
Application.put_env(:ex_unit, :assert_receive_timeout, 1_000)
Application.put_env(:tightbeam, :autostart, false)
Application.put_env(:tightbeam, :fixture_harness, true)
Application.put_env(:tightbeam, :local_host_name, "testhost")
Application.put_env(:tightbeam, :base_dir, base)

authority =
  case authority do
    "opener" -> :opener
    "admin" -> :admin
    "" -> nil
  end

Tightbeam.SupervisionConsumerFixture.run_case!(String.to_integer(id), authority, base, locks)
IO.puts("supervision-cold: ok")
