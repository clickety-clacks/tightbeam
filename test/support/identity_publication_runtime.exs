[payload, base] = System.argv()
Tightbeam.IdentityPublicationFixture.Diagnostics.record(:child_started)
true = Path.expand(payload) == Path.expand(Application.app_dir(:tightbeam))
false = File.exists?(base)
{:ok, _} = Application.ensure_all_started(:exqlite)
{:ok, _} = Application.ensure_all_started(:crypto)
{:ok, _} = Application.ensure_all_started(:plug)
Application.put_env(:ex_unit, :assert_receive_timeout, 1_000)
Application.put_env(:tightbeam, :autostart, false)
Application.put_env(:tightbeam, :fixture_harness, true)
Application.put_env(:tightbeam, :local_host_name, "testhost")
Application.put_env(:tightbeam, :base_dir, base)
Tightbeam.IdentityPublicationFixture.Diagnostics.record(:runtime_ready)

if System.get_env("DD36_IDENTITY_PUBLICATION_CONTROLLED_STALL") == "1" do
  Tightbeam.IdentityPublicationFixture.Diagnostics.record(:controlled_child_stalled)
  IO.puts("identity-publication-child: waiting for release")

  case IO.gets(:stdio, "") do
    "release\n" ->
      Tightbeam.IdentityPublicationFixture.Diagnostics.record(:controlled_child_released)
      IO.puts("identity-publication-child: released")

    other ->
      raise "controlled identity publication child lost its release barrier: #{inspect(other)}"
  end
else
  Tightbeam.IdentityPublicationFixture.run_case!(
    String.to_integer(System.fetch_env!("DD36_SCENARIO")),
    base
  )
end
