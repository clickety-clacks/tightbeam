# 2026-09-01, end to end. A build admitted to ONE base must refuse to start on
# another, before anything reads or writes it — including creating it. Both
# startup paths are covered: Tightbeam.Boot and the gateway's composition root.
[payload, base] = System.argv()
true = Path.expand(Application.app_dir(:tightbeam)) == Path.expand(payload)
{:ok, _} = Application.ensure_all_started(:exqlite)
{:ok, _} = Application.ensure_all_started(:crypto)
Application.put_env(:tightbeam, :base_dir, base)
Application.put_env(:tightbeam, :live_base_guard, [])
alias Tightbeam.DB
import ExUnit.Assertions

{:ok, db} =
  DB.start_link(path: Path.join(base, "state.db"), name: Tightbeam.DB, guard_inputs: [])

foreign = Path.join(Path.dirname(base), "foreign-base")
refute File.exists?(foreign)

for start <- [
      fn -> Tightbeam.Boot.start_link(foreign) end,
      fn -> Tightbeam.Gateway.children_after_preflight(%{base_dir: foreign, db: db}) end
    ] do
  error = assert_raise ArgumentError, start
  assert error.message =~ "persistent DB admission"
  # Refusing after the directory exists is not refusing.
  refute File.exists?(foreign)
  assert Process.alive?(db)
end

# The base this build WAS admitted to still boots.
:ignore = Tightbeam.Boot.start_link(base)
assert File.regular?(Path.join(base, "build-owner.json"))
assert File.regular?(Path.join(base, "harnesses.json"))
assert is_integer(Application.get_env(:tightbeam, :boot_epoch))
assert :ok = DB.assert_base_admitted!(db, base)
:ok = GenServer.stop(db)

IO.puts("boot-admission-ordering: ok")
