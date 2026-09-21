[payload, base] = System.argv()
true = Path.expand(Application.app_dir(:tightbeam)) == Path.expand(payload)
{:ok, _} = Application.ensure_all_started(:exqlite)
{:ok, _} = Application.ensure_all_started(:crypto)
Application.put_env(:tightbeam, :base_dir, base)
Application.put_env(:tightbeam, :autostart, false)
alias Tightbeam.{Boot, DB}
opts = [path: Path.join(base, "state.db"), name: DB, guard_inputs: []]
{:ok, seed} = DB.start_link(opts)
:ignore = Boot.start_link(%{base_dir: base})

snapshot = fn db ->
  Map.new(~w(turns events boot_epochs decision_requests wakes), fn table ->
    {:ok, rows} = DB.query(db, "SELECT * FROM #{table} ORDER BY rowid", [])
    {table, rows}
  end)
end

before = snapshot.(seed)
marker = File.read!(Path.join(base, "build-owner.json"))
projection = File.read!(Path.join(base, "harnesses.json"))
:ok = GenServer.stop(seed)

{_, 0} =
  System.cmd("git", ["update-ref", "-d", "refs/heads/tightbeam/live"],
    cd: Path.join(base, "identity")
  )

bin = Path.join(base, "working-cli")
File.mkdir_p!(bin)

for name <- ["claude", "codex"] do
  path = Path.join(bin, name)

  File.write!(
    path,
    "#!/bin/sh\nif [ \"$1\" = --version ]; then echo fixture-only; exit 0; fi\nexit 64\n"
  )

  File.chmod!(path, 0o755)
end

System.put_env("PATH", bin <> ":" <> System.fetch_env!("PATH"))
Application.put_env(:tightbeam, :fixture_harness, false)
Application.put_env(:tightbeam, :autostart, true)
Process.flag(:trap_exit, true)

{:error, {:shutdown, {:failed_to_start_child, Boot, failure}}} =
  Tightbeam.Application.start(:normal, [])

true = inspect(failure) =~ "missing required refs: tightbeam/live"
{:ok, verify} = DB.start_link(opts)
^before = snapshot.(verify)
^marker = File.read!(Path.join(base, "build-owner.json"))
^projection = File.read!(Path.join(base, "harnesses.json"))
false = File.exists?(Path.join(base, "gateway.json"))
:ok = GenServer.stop(verify)
IO.puts("guarded-identity-refusal: ok")
