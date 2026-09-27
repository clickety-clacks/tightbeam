[payload, base, proof] = System.argv()
true = Path.expand(payload) == Path.expand(Application.app_dir(:tightbeam))
false = File.exists?(base)
{:ok, _} = Application.ensure_all_started(:exqlite)
{:ok, _} = Application.ensure_all_started(:crypto)
Application.put_env(:tightbeam, :autostart, false)
Application.put_env(:tightbeam, :base_dir, base)

alias Tightbeam.{DB, Schema, TerminalCredentialFailure}

{:ok, hub} = Tightbeam.Firehose.Hub.start_link(name: Tightbeam.Firehose.Hub)
{:ok, db} = DB.start_link(path: Path.join(base, "state.db"), name: nil, guard_inputs: [])

try do
  :ok = Schema.ensure_all(db)
  :ok = TerminalCredentialFailure.ensure_schema(db)
  Tightbeam.TerminalCredentialCoreFixture.proof!(proof, db, base)
after
  if Process.alive?(db), do: GenServer.stop(db)
  if Process.alive?(hub), do: GenServer.stop(hub)
end

IO.puts("terminal-credential-core: #{proof}: ok")
