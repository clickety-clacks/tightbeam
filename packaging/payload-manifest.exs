Code.require_file("../lib/tightbeam/live_base_guard.ex", __DIR__)
Code.require_file("../lib/tightbeam/live_base_payload.ex", __DIR__)
{:ok, _} = Application.ensure_all_started(:crypto)

case System.argv() do
  ["generate", root] -> IO.puts(Tightbeam.LiveBasePayload.generate!(root))
  ["verify", root] -> IO.puts(Tightbeam.LiveBasePayload.verify!(root))
  _ -> raise "usage: payload-manifest.exs generate|verify <assembled-root>"
end
