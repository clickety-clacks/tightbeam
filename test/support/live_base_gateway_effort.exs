import ExUnit.Assertions
alias Tightbeam.{DB, Gateway, Model, Org, Wakes}

defmodule GuardEffortDoorbell do
  use GenServer
  def init(parent), do: {:ok, parent}

  def handle_call({:ensure_lane, key}, _from, parent) do
    send(parent, {:ensure_lane, key})
    {:reply, :ok, parent}
  end
end

Tightbeam.GuardGatewayFixture.run!(fn %{db: db, config: config} ->
  {:ok, lane} = GenServer.start_link(GuardEffortDoorbell, self())

  config =
    config
    |> Map.put(:lane_manager, lane)
    |> Map.put(:effort_checkin_horizon_ms, 1)
    |> Map.put(:sh, fn _ -> {"B\tobserved\t0\n/w\n", 0} end)

  {Wakes, opts} = Gateway.children(config) |> Enum.find(&match?({Wakes, _}, &1))
  {:ok, scheduler} = Wakes.start_link(Keyword.put(opts, :name, :guard_effort_scheduler))

  for key <- ["k1", "effort-parent"] do
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
    :ok =
      DB.execute(db, "UPDATE sessions SET spawnedBy='effort-parent' WHERE sessionKey='k1'")

    assignment =
      Gateway.handlers(config)["dispatch"].(%{
        verb: "dispatch",
        origin: "agent:effort-parent",
        principal: {:session, "effort-parent"},
        session_key: "k1",
        target_role: nil,
        role_fallback: false,
        params: %{subject: "scheduler seam", brief: "exercise the real effort wake route"}
      })

    {:ok, [[wake_id]]} =
      DB.query(
        db,
        "SELECT wakeId FROM effort_checkin_generations WHERE assignmentId=?1 AND state='armed'",
        [assignment.id]
      )

    assert %{consumer: "effort_probe", state: "pending"} = Wakes.get(db, wake_id)
    {:ok, _} = DB.query(db, "UPDATE wakes SET dueAt=0 WHERE wakeId=?1", [wake_id])

    # Rung one prods the HOLDER and re-arms; the owner's request is rung two.
    assert :ok = Wakes.fire_due(scheduler)

    {:ok, [[rearmed_wake_id]]} =
      DB.query(
        db,
        "SELECT wakeId FROM effort_checkin_generations WHERE assignmentId=?1 AND state='armed'",
        [assignment.id]
      )

    {:ok, _} = DB.query(db, "UPDATE wakes SET dueAt=0 WHERE wakeId=?1", [rearmed_wake_id])
    assert :ok = Wakes.fire_due(scheduler)

    assert {:ok, [[request_id]]} =
             DB.query(
               db,
               "SELECT id FROM decision_requests WHERE kind='effort' AND assignmentId=?1",
               [assignment.id]
             )

    assert is_binary(request_id)
    assert Wakes.get(db, wake_id).state == "fired"

    # The expecter notification is a durable ungated wake armed with the request,
    # still pending: the same tick that opened the request delivers nothing.
    assert {:ok, [[notify_id]]} =
             DB.query(
               db,
               "SELECT wakeId FROM wakes WHERE targetGate = 0 AND state = 'pending'"
             )

    assert %{consumer: "prompt", session_key: expecter} = Wakes.get(db, notify_id)

    # The next ordinary tick delivers it through the gateway's own configured
    # prompt closure — real ConnRegistry, real lane nudge, one turn.
    assert :ok = Wakes.fire_due(scheduler)
    assert Wakes.get(db, notify_id).state == "fired"

    assert {:ok, [[1]]} =
             DB.query(db, "SELECT COUNT(*) FROM turns WHERE wakeId = ?1", [notify_id])

    assert_receive {:ensure_lane, ^expecter}, 1_000

    assert {:ok, [[1]]} =
             DB.query(
               db,
               "SELECT COUNT(*) FROM decision_requests WHERE kind='effort' AND assignmentId=?1",
               [assignment.id]
             )
  after
    GenServer.stop(scheduler)
    GenServer.stop(lane)
  end
end)

IO.puts("guarded-gateway-effort: ok")
