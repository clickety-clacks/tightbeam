[payload, base] = System.argv()
true = Path.expand(payload) == Path.expand(Application.app_dir(:tightbeam))
false = File.exists?(base)
{:ok, _} = Application.ensure_all_started(:exqlite)
{:ok, _} = Application.ensure_all_started(:crypto)
Application.put_env(:tightbeam, :autostart, false)
Application.put_env(:tightbeam, :base_dir, base)
import ExUnit.Assertions

alias Tightbeam.{
  DB,
  Gateway,
  Model,
  NoticeBatcher,
  Org,
  Roles,
  Schema,
  SessionPoAssociations,
  Wakes
}

opts = [path: Path.join(base, "state.db"), name: nil, guard_inputs: []]
{:ok, db} = DB.start_link(opts)
:ok = Schema.ensure_all(db)
{:ok, _} = DB.query(db, "INSERT INTO users(userId,isAdmin,createdAt) VALUES('owner',0,1)")

for {key, kind} <- [
      {Org.personal_session_key("owner"), "main"},
      {"orchestrator", "custom"},
      {"po", "custom"}
    ] do
  Org.create(db, %{
    session_key: key,
    display_name: key,
    owner_user_id: "owner",
    origin: "user:owner",
    kind: kind,
    archetype: "default",
    harness: "fixture",
    provider: "fixture_provider",
    model: Model.new("fixture"),
    host: "synthetic-host"
  })
end

Roles.create!(db, "product-owner:one", "owner", "po")

set = Gateway.handlers(%{db: db})["session-po-set"]

result =
  set.(%{
    verb: "session-po-set",
    origin: "user:owner",
    principal: {:user, "owner"},
    session_key: nil,
    params: %{
      session_key: "orchestrator",
      po_role: "product-owner:one",
      idempotency_key: "restart"
    }
  })

wake_id = result["association"]["noticeWakeId"]
:ok = GenServer.stop(db)
{:ok, reopened} = DB.start_link(opts)
defmodule Tightbeam.SessionPoRestartDoorbell do
  use GenServer
  def start_link({parent, name}), do: GenServer.start_link(__MODULE__, parent, name: name)
  def init(parent), do: {:ok, parent}
  def handle_call({:ensure_lane, target}, _from, parent) do
    send(parent, {:postcommit_doorbell, target})
    raise "simulated crash after atomic delivery commit and before lane execution"
  end
end

# Publication and source acknowledgment now commit atomically. Crash at the
# real postcommit doorbell instead of inventing an unacknowledged source gap.
{:ok, registry} = Tightbeam.ConnRegistry.start_link(name: :session_po_restart_registry)
{:ok, lane} = Tightbeam.SessionPoRestartDoorbell.start_link({self(), :session_po_restart_lane})
old_trap = Process.flag(:trap_exit, true)

committed =
try do
  :ok = Schema.ensure_all(reopened)
  assert SessionPoAssociations.get(reopened, "orchestrator") == result["association"]
  assert %{wake_id: ^wake_id, state: "pending"} = Wakes.get(reopened, wake_id)

  {:ok, first_scheduler} =
    Wakes.start_link(
      db: reopened,
      name: :session_po_restart_wakes,
      tick_ms: 60_000,
      delivery_opts: [conn_registry: registry, lane_manager: lane],
      deliver: fn _ -> flunk("normal association used legacy callback") end
    )

  assert catch_exit(Wakes.fire_due(:session_po_restart_wakes))
  assert_receive {:postcommit_doorbell, "orchestrator"}
  assert [%{delivery_wake_id: carrier_id, member_state: "included", batch_state: "delivered"}] =
           NoticeBatcher.source_refs(reopened, wake_id)
  assert %{state: "fired"} = Wakes.get(reopened, carrier_id)
  assert {:ok, [["orchestrator", "queued", content]]} =
           DB.query(reopened, "SELECT t.sessionKey,t.status,m.content FROM turns t JOIN messages m ON m.id=t.messageId WHERE t.wakeId=?1", [carrier_id])
  assert content =~ wake_id
  assert content =~ "product-owner:one"
  assert content =~ "association revision `1`"
  assert %{wake_id: ^wake_id, state: "fired"} = Wakes.get(reopened, wake_id)

  assert [%{delivery_wake_id: ^carrier_id, batch_state: "delivered"}] =
           NoticeBatcher.source_refs(reopened, wake_id)

  assert {:ok, [[0]]} =
           DB.query(reopened, "SELECT COUNT(*) FROM turns WHERE wakeId=?1", [wake_id])

  assert {:ok, [[1]]} =
           DB.query(reopened, "SELECT COUNT(*) FROM turns WHERE wakeId=?1", [carrier_id])

  Process.unlink(first_scheduler)
  if Process.alive?(first_scheduler), do: GenServer.stop(first_scheduler)
  assert {:ok, turns} = DB.query(reopened, "SELECT * FROM turns ORDER BY seq")
  assert {:ok, messages} = DB.query(reopened, "SELECT * FROM messages ORDER BY id")
  assert {:ok, wakes} = DB.query(reopened, "SELECT * FROM wakes ORDER BY wakeId")
  {carrier_id, turns, messages, wakes}
after
  GenServer.stop(reopened)
end
Process.unlink(lane)
if Process.alive?(lane), do: GenServer.stop(lane)
Process.flag(:trap_exit, old_trap)
{carrier_id, committed_turns, committed_messages, committed_wakes} = committed
{:ok, healthy_lane} = Tightbeam.NoticeBatcherFixture.LaneStub.start_link(:session_po_restart_healthy_lane)

{:ok, retried} = DB.start_link(opts)

try do
  :ok = Schema.ensure_all(retried)
  assert SessionPoAssociations.get(retried, "orchestrator") == result["association"]
  {:ok, second_scheduler} =
    Wakes.start_link(
      db: retried,
      name: :session_po_restart_wakes,
      tick_ms: 60_000,
      delivery_opts: [conn_registry: registry, lane_manager: healthy_lane],
      deliver: fn _ -> flunk("restart manufactured a second legacy delivery") end
    )

  :ok = Wakes.fire_due(:session_po_restart_wakes)
  assert [%{delivery_wake_id: ^carrier_id, member_state: "included", batch_state: "delivered"}] =
           NoticeBatcher.source_refs(retried, wake_id)
  retry_carrier_id = carrier_id
  assert {:ok, ^committed_turns} = DB.query(retried, "SELECT * FROM turns ORDER BY seq")
  assert {:ok, ^committed_messages} = DB.query(retried, "SELECT * FROM messages ORDER BY id")
  assert {:ok, ^committed_wakes} = DB.query(retried, "SELECT * FROM wakes ORDER BY wakeId")
  assert %{wake_id: ^wake_id, state: "fired"} = Wakes.get(retried, wake_id)

  assert [%{batch_state: "delivered", delivery_wake_id: ^retry_carrier_id}] =
           NoticeBatcher.source_refs(retried, wake_id)

  assert {:ok, [[0]]} = DB.query(retried, "SELECT COUNT(*) FROM turns WHERE wakeId=?1", [wake_id])

  assert {:ok, [[1]]} =
           DB.query(retried, "SELECT COUNT(*) FROM turns WHERE wakeId=?1", [retry_carrier_id])

  GenServer.stop(second_scheduler)
  IO.puts("session-po-association-restart: ok")
after
  GenServer.stop(retried)
  if Process.alive?(healthy_lane), do: GenServer.stop(healthy_lane)
  if Process.alive?(registry), do: GenServer.stop(registry)
end
