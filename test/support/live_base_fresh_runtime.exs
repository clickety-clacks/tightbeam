[payload, base, locks] = System.argv()
true = Path.expand(Application.app_dir(:tightbeam)) == Path.expand(payload)
{:ok, _} = Application.ensure_all_started(:exqlite)
{:ok, _} = Application.ensure_all_started(:crypto)
Application.put_env(:tightbeam, :base_dir, base)
Application.put_env(:tightbeam, :autostart, false)
alias Tightbeam.{DB, Escalation, EventLog, Ledger}
import ExUnit.Assertions
:persistent_term.erase(Tightbeam.RuleRuntime)

{:ok, sup} =
  Supervisor.start_link(
    Tightbeam.Application.children(%{base_dir: base, guard_inputs: [lock_dir: locks]}),
    strategy: :rest_for_one
  )

try do
  assert Process.whereis(DB) |> is_pid()
  assert Process.whereis(Tightbeam.LaneRegistry) |> is_pid()
  assert Process.whereis(Tightbeam.LaneSupervisor) |> is_pid()

  assert {:ok, [[0]]} = DB.query(DB, "SELECT COUNT(*) FROM turns")
  assert {:ok, [[n]]} = DB.query(DB, "SELECT COUNT(*) FROM boot_epochs")
  assert n >= 1
  assert {:ok, [[1]]} = DB.query(DB, "PRAGMA foreign_keys")
  assert is_integer(Application.get_env(:tightbeam, :boot_epoch))
  assert Ledger.pending_sessions(DB) == []
  assert Escalation.recover_retired(DB) == :ok
  assert EventLog.events_after(DB, 0, 10) == []

  assert {:ok, [[1]]} =
           DB.query(
             DB,
             "SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name = 'sessions'"
           )

  assert {:ok, [[1]]} =
           DB.query(
             DB,
             "SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name = 'harness_processes'"
           )

  expected =
    "[" <> Enum.map_join(Tightbeam.Harness.all(), ",", & &1.wire_projection()) <> "]"

  assert File.read!(Path.join(Application.fetch_env!(:tightbeam, :base_dir), "harnesses.json")) ==
           expected

  assert File.regular?(Path.join(base, "build-owner.json"))
  assert :ok = DB.assert_base_admitted!(DB, base)
after
  :ok = Supervisor.stop(sup)
end

IO.puts("guarded-fresh-application: ok")
