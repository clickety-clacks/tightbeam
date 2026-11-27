[payload, base | options] = System.argv()
payload = Path.expand(payload)
^payload = Application.app_dir(:tightbeam) |> Path.expand()
false = File.exists?(base)
{:ok, _} = Application.ensure_all_started(:exqlite)
{:ok, _} = Application.ensure_all_started(:crypto)
Application.put_env(:tightbeam, :autostart, false)
Application.put_env(:tightbeam, :base_dir, base)
alias Tightbeam.{Boot, DB, Gateway, Identity, Schema}

{:ok, db} =
  DB.start_link(path: Path.join(base, "state.db"), name: DB, guard_inputs: [])

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
if options == ["tour-guide"] do
  :initialized = Identity.init_after_admission!(base, db, :tour_guide)
  :noop = Identity.init_after_admission!(base, db, :tour_guide)
end

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

tour_path = Path.join(base, "identity/archetypes/tour-guide.toml")
main = Identity.snapshot!(base, "default", :codex)

if options == ["tour-guide"] do
  true = File.regular?(tour_path)
  [] = main.archetype.skills
  true = String.contains?(main.guidance, "Harklight over email")
  true = String.contains?(main.guidance, "send authority separately from the preference")
  true = String.contains?(main.guidance, "shipped `tightbeam-onboarding` skill")

  tour = Identity.snapshot!(base, "tour-guide", :codex)
  ["tightbeam-onboarding"] = tour.archetype.skills
  true = String.contains?(tour.guidance, "Main remains their root contact")
  true = String.contains?(tour.guidance, "tightbeam doctor")

  {:ok, candidate} = Identity.relearn!(base, "operator")
  {:ok, _revision} = Identity.publish_live!(base, candidate)
  true = File.regular?(tour_path)
  true = String.contains?(Identity.snapshot!(base, "default", :codex).guidance, "Harklight over email")
  IO.puts("tour-guide-seed-relearn: ok")
else
  false = File.exists?(tour_path)
  ["tightbeam-onboarding"] = main.archetype.skills
  :noop = Identity.init_after_admission!(base, db, :tour_guide)
  false = File.exists?(tour_path)
end

:ok = GenServer.stop(db)
IO.puts("boot-admission-ordering: ok")
