import ExUnit.Assertions
alias Tightbeam.{DB, EventLog, Gateway, Model, Org, Roles, Wakes}
# Same inert post-commit doorbell boundary as GatewayTest.LaneDoorbell.
defmodule GuardRoleDoorbell do
  use GenServer
  def init(parent), do: {:ok, parent}

  def handle_call({:ensure_lane, key}, _from, parent) do
    send(parent, {:ensure_lane, key})
    {:reply, :ok, parent}
  end
end

Tightbeam.GuardGatewayFixture.run!(fn %{db: db, config: config} ->
  {:ok, lane} = GenServer.start_link(GuardRoleDoorbell, self())
  config = Map.put(config, :lane_manager, lane)
  {Wakes, opts} = Gateway.children(config) |> Enum.find(&match?({Wakes, _}, &1))
  {:ok, scheduler} = Wakes.start_link(Keyword.put(opts, :name, :guard_role_scheduler))

  create_session = fn key ->
    Org.create(db, %{
      session_key: key,
      display_name: key,
      owner_user_id: "flynn",
      origin: "user:flynn",
      spawned_by: nil,
      archetype: "default",
      host: "testhost",
      harness: "claude",
      provider: "anthropic",
      model: Model.new("fable")
    })
  end

  try do
    old = create_session.("agent:old")
    new = create_session.("agent:new")
    Roles.create!(db, "reviewer", "flynn", old.session_key)
    wake_handler = Gateway.handlers(Map.put(config, :wake_scheduler, scheduler))["wake"]
    future = System.system_time(:millisecond) + 60_000

    scheduled =
      wake_handler.(%{
        origin: "user:flynn",
        session_key: old.session_key,
        target_role: "reviewer",
        role_fallback: false,
        params: %{prompt: "review this", at: future}
      })

    assert Wakes.get(db, scheduled.wake_id).target_role == "reviewer"
    assert :ok = Roles.bind(db, "reviewer", new.session_key)

    {:ok, _} =
      DB.query(db, "UPDATE wakes SET dueAt = 0 WHERE wakeId = ?1", [scheduled.wake_id])

    assert :ok = Wakes.fire_due(scheduler)

    assert {:ok, [["agent:new", "reviewer", 0]]} =
             DB.query(
               db,
               "SELECT sessionKey, roleRef, roleFallback FROM turns WHERE wakeId = ?1",
               [scheduled.wake_id]
             )

    deleted =
      wake_handler.(%{
        origin: "user:flynn",
        session_key: new.session_key,
        target_role: "reviewer",
        role_fallback: false,
        params: %{prompt: "will disappear", at: future}
      })

    assert :ok = Roles.rm(db, "reviewer")
    {:ok, _} = DB.query(db, "UPDATE wakes SET dueAt = 0 WHERE wakeId = ?1", [deleted.wake_id])
    assert :ok = Wakes.fire_due(scheduler)
    assert Wakes.get(db, deleted.wake_id).state == "fired"

    assert {:ok, [[0]]} =
             DB.query(db, "SELECT COUNT(*) FROM turns WHERE wakeId = ?1", [deleted.wake_id])

    assert Enum.any?(EventLog.lifecycle_events(db), fn event ->
             event.kind == "wake_unresolved" and event.subject == deleted.wake_id and
               event.detail == "role reviewer no longer exists"
           end)

    assert_receive {:ensure_lane, "agent:new"}, 1_000
  after
    GenServer.stop(scheduler)
    GenServer.stop(lane)
  end
end)

IO.puts("guarded-gateway-role-binding: ok")
