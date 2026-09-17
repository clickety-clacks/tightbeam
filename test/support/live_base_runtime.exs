[payload, base] = System.argv()
payload = Path.expand(payload)
^payload = Application.app_dir(:tightbeam) |> Path.expand()
false = File.exists?(base)
{:ok, _} = Application.ensure_all_started(:exqlite)
{:ok, _} = Application.ensure_all_started(:crypto)
Application.put_env(:tightbeam, :autostart, false)
Application.put_env(:tightbeam, :base_dir, base)
alias Tightbeam.{DB, Schema}

{:ok, db} =
  DB.start_link(path: Path.join(base, "state.db"), name: nil, guard_inputs: [])

false = File.exists?(Path.join(base, "build-owner.json"))
:ok = Schema.ensure_all(db)
:ok = DB.assert_base_admitted!(db, base)
{:ok, [[stamp]]} = DB.query(db, "SELECT shape FROM schema_stamp", [])
true = stamp == hd(Schema.guard_compatible_stamps())
marker = File.read!(Path.join(base, "build-owner.json"))
:ok = Schema.ensure_all(db)
^marker = File.read!(Path.join(base, "build-owner.json"))
:ok = GenServer.stop(db)

{:ok, second} =
  DB.start_link(path: Path.join(base, "state.db"), name: nil, guard_inputs: [])

:ok = Schema.ensure_all(second)
:ok = DB.assert_base_admitted!(second, base)
^marker = File.read!(Path.join(base, "build-owner.json"))
:ok = GenServer.stop(second)
IO.puts("persistent-owner-refresh-reopen: ok")
