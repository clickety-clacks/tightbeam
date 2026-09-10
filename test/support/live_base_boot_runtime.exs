[payload, base, locks] = System.argv()
payload = Path.expand(payload)
^payload = Application.app_dir(:tightbeam) |> Path.expand()
false = File.exists?(base)
{:ok, _} = Application.ensure_all_started(:exqlite)
{:ok, _} = Application.ensure_all_started(:crypto)
Application.put_env(:tightbeam, :autostart, false)
Application.put_env(:tightbeam, :base_dir, base)
alias Tightbeam.{Boot, DB, Gateway, Schema}

{:ok, db} =
  DB.start_link(path: Path.join(base, "state.db"), name: DB, guard_inputs: [lock_dir: locks])

false = File.exists?(Path.join(base, "identity"))
false = File.exists?(Path.join(base, "build-owner.json"))
foreign = base <> "-foreign"

for start <- [
      fn -> Boot.start_link(%{base_dir: foreign}) end,
      fn -> Gateway.children_after_preflight(%{base_dir: foreign, db: db}) end
    ] do
  refused =
    try do
      start.()
      false
    rescue
      error in ArgumentError ->
        String.contains?(Exception.message(error), "persistent DB admission")
    end

  true = refused
  false = File.exists?(foreign)
  true = Process.alive?(db)
end

false = File.exists?(Path.join(base, "identity"))
false = File.exists?(Path.join(base, "build-owner.json"))
:ignore = Boot.start_link(%{base_dir: base})
true = File.dir?(Path.join(base, "identity/.git"))
true = File.regular?(Path.join(base, "build-owner.json"))
true = File.regular?(Path.join(base, "harnesses.json"))
epoch = Application.fetch_env!(:tightbeam, :boot_epoch)
true = is_integer(epoch) and epoch > 0

{:ok, [[^epoch, nil]]} =
  DB.query(db, "SELECT epoch, cleanShutdownAt FROM boot_epochs", [])

{:ok, [[stamp]]} = DB.query(db, "SELECT shape FROM schema_stamp", [])
true = stamp == hd(Schema.guard_compatible_stamps())
:ok = DB.assert_base_admitted!(db, base)
:ok = GenServer.stop(db)
IO.puts("boot-admission-ordering: ok")
