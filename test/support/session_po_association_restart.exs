[payload, base] = System.argv()
true = Path.expand(payload) == Path.expand(Application.app_dir(:tightbeam))
false = File.exists?(base)
{:ok, _} = Application.ensure_all_started(:exqlite)
{:ok, _} = Application.ensure_all_started(:crypto)
Application.put_env(:tightbeam, :autostart, false)
Application.put_env(:tightbeam, :base_dir, base)
import ExUnit.Assertions
alias Tightbeam.{DB, Gateway, Model, Org, Roles, Schema, SessionPoAssociations, Wakes}

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
script = self()

try do
  :ok = Schema.ensure_all(reopened)
  assert SessionPoAssociations.get(reopened, "orchestrator") == result["association"]
  assert %{wake_id: ^wake_id, state: "pending"} = Wakes.get(reopened, wake_id)

  deliver_before_ack = fn wake ->
    {:ok, delivery} =
      DB.transaction(reopened, fn txn ->
        Gateway.deliver_prompt_in_txn(
          txn,
          wake.session_key,
          wake.origin,
          wake.prompt,
          wake_id: wake.wake_id,
          sender: wake.origin,
          target_gate: wake
        )
      end)

    send(script, {:delivered_before_ack, wake.wake_id, delivery})
    raise "simulated crash after delivery commit and before wake acknowledgement"
  end

  {:ok, first_scheduler} =
    Wakes.start_link(
      db: reopened,
      name: :session_po_restart_wakes,
      tick_ms: 60_000,
      deliver: deliver_before_ack
    )

  :ok = Wakes.fire_due(:session_po_restart_wakes)

  receive do
    {:delivered_before_ack, ^wake_id, {:appended, "orchestrator", _, _}} -> :ok
  after
    1_000 -> flunk("delivery-before-ack cut was not reached")
  end

  assert %{wake_id: ^wake_id, state: "pending"} = Wakes.get(reopened, wake_id)

  assert {:ok, [[1]]} =
           DB.query(reopened, "SELECT COUNT(*) FROM turns WHERE wakeId=?1", [wake_id])

  GenServer.stop(first_scheduler)
after
  GenServer.stop(reopened)
end

{:ok, retried} = DB.start_link(opts)

try do
  retry_delivery = fn wake ->
    {:ok, delivery} =
      DB.transaction(retried, fn txn ->
        Gateway.deliver_prompt_in_txn(
          txn,
          wake.session_key,
          wake.origin,
          wake.prompt,
          wake_id: wake.wake_id,
          sender: wake.origin,
          target_gate: wake
        )
      end)

    send(script, {:retried_delivery, wake.wake_id, delivery})
    delivery
  end

  {:ok, second_scheduler} =
    Wakes.start_link(
      db: retried,
      name: :session_po_restart_wakes,
      tick_ms: 60_000,
      deliver: retry_delivery
    )

  :ok = Wakes.fire_due(:session_po_restart_wakes)

  receive do
    {:retried_delivery, ^wake_id, {:duplicate, _}} -> :ok
  after
    1_000 -> flunk("restart retry did not reuse the logical wake delivery")
  end

  assert %{wake_id: ^wake_id, state: "fired"} = Wakes.get(retried, wake_id)
  assert {:ok, [[1]]} = DB.query(retried, "SELECT COUNT(*) FROM turns WHERE wakeId=?1", [wake_id])
  GenServer.stop(second_scheduler)
  IO.puts("session-po-association-restart: ok")
after
  GenServer.stop(retried)
end
