# A fresh install: nothing on disk, no marker, no base directory. The guard
# must ADMIT, the base must be created, and the application must start. A guard
# that bricks first run fails harder than the defect it was built to prevent.
[payload, base] = System.argv()
true = Path.expand(Application.app_dir(:tightbeam)) == Path.expand(payload)
{:ok, _} = Application.ensure_all_started(:exqlite)
{:ok, _} = Application.ensure_all_started(:crypto)
Application.put_env(:tightbeam, :base_dir, base)
Application.put_env(:tightbeam, :live_base_guard, [])
alias Tightbeam.DB
import ExUnit.Assertions

# Nothing exists yet: not the base, not the marker, not the database.
refute File.exists?(base)

{:ok, sup} = Supervisor.start_link(Tightbeam.Application.children(), strategy: :rest_for_one)

try do
  assert is_pid(Process.whereis(DB))
  assert is_pid(Process.whereis(Tightbeam.LaneRegistry))
  assert is_pid(Process.whereis(Tightbeam.LaneSupervisor))

  # The base was created by the admitted build, after admission, not before it.
  assert File.dir?(base)
  assert {:ok, [[0]]} = DB.query(DB, "SELECT COUNT(*) FROM turns")
  assert {:ok, [[n]]} = DB.query(DB, "SELECT COUNT(*) FROM boot_epochs")
  assert n >= 1
  assert {:ok, [[1]]} = DB.query(DB, "PRAGMA foreign_keys")
  assert is_integer(Application.get_env(:tightbeam, :boot_epoch))

  assert {:ok, [[1]]} =
           DB.query(
             DB,
             "SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name = 'sessions'"
           )

  # Migration reached the current target, so this build published its ownership.
  assert {:ok, [[stamp]]} = DB.query(DB, "SELECT shape FROM schema_stamp")
  assert stamp == hd(Tightbeam.Schema.guard_compatible_stamps())
  assert File.regular?(Path.join(base, "build-owner.json"))
  assert :ok = DB.assert_base_admitted!(DB, base)

  expected = "[" <> Enum.map_join(Tightbeam.Harness.all(), ",", & &1.wire_projection()) <> "]"
  assert File.read!(Path.join(base, "harnesses.json")) == expected
after
  :ok = Supervisor.stop(sup)
end

IO.puts("guarded-fresh-application: ok")
