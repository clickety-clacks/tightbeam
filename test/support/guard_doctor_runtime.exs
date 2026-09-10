[payload, base, locks] = System.argv()
true = Path.expand(payload) == Path.expand(Application.app_dir(:tightbeam))
false = File.exists?(base)
{:ok, _} = Application.ensure_all_started(:exqlite)
{:ok, _} = Application.ensure_all_started(:crypto)
Application.put_env(:tightbeam, :autostart, false)
Application.put_env(:tightbeam, :base_dir, base)
Application.put_env(:ex_unit, :assert_receive_timeout, 1_000)
import ExUnit.Assertions
alias Tightbeam.{DB, Schema}
path = Path.join(base, "state.db")
{:ok, db} = DB.start_link(path: path, name: nil, guard_inputs: [lock_dir: locks])

try do
  :ok = Schema.ensure_all(db)
  :ok = DB.assert_base_admitted!(db, base)
  marker = File.read!(Path.join(base, "build-owner.json"))

  {:ok, _entry} =
    Tightbeam.Placement.register_host(db, "worker", %{
      ssh: "tb@worker",
      base_dir: "/srv/tb",
      cli_bin: "/srv/tb/bin"
    })

  {:ok, before} = DB.query(db, "SELECT * FROM hosts ORDER BY name")
  hosts = Mix.Tasks.Tightbeam.Doctor.org_hosts(base)
  assert hosts["worker"] == %{ssh: "tb@worker", base_dir: "/srv/tb", cli_bin: "/srv/tb/bin"}
  assert hosts[Tightbeam.Placement.local_host_name()].ssh == nil
  assert {:ok, ^before} = DB.query(db, "SELECT * FROM hosts ORDER BY name")
  assert File.read!(Path.join(base, "build-owner.json")) == marker
after
  if Process.alive?(db), do: GenServer.stop(db)
end

IO.puts("guarded-doctor-readonly: ok")
