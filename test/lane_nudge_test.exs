defmodule Tightbeam.LaneNudgeTest do
  use Tightbeam.TestCase, async: false

  alias Tightbeam.{ConnRegistry, DB, Gateway, LaneManager, Org, Projection}

  setup do
    nonce = System.unique_integer([:positive])
    db = :"lane_nudge_db_#{nonce}"
    start_supervised!({DB, path: ":memory:", name: db})
    :ok = Tightbeam.Schema.ensure_all(db)

    :ok =
      DB.execute(db, """
      INSERT INTO users (userId,isAdmin,createdAt) VALUES ('mike',1,1);
      INSERT INTO sessions
        (sessionKey,displayName,ownerUserId,origin,spawnedBy,archetype,
         harness,provider,model,thinkingLevel,host,createdAt,updatedAt)
      VALUES
        ('k1','K1','mike','user:mike','k1','default','claude','anthropic',
         'claude-sonnet-5','medium','testhost',1,1),
        ('k2','K2','mike','user:mike','k1','default','claude','anthropic',
         'claude-sonnet-5','medium','testhost',2,2);
      """)

    Org.append_pointer(db, "k1", "hs-1", "created")
    Org.append_pointer(db, "k2", "hs-2", "created")

    start_supervised!({Registry, keys: :unique, name: Tightbeam.LaneRegistry})
    task_sup = :"lane_nudge_task_sup_#{nonce}"
    lane_sup = :"lane_nudge_lane_sup_#{nonce}"
    start_supervised!({Task.Supervisor, name: task_sup})
    start_supervised!({DynamicSupervisor, strategy: :one_for_one, name: lane_sup})
    owner = self()

    manager_opts = [
      db: db,
      lane_sup: lane_sup,
      task_sup: task_sup,
      runner: fn turn ->
        send(owner, {:runner_started, turn.seq, self()})

        if turn.prompt == "hold live" do
          receive do
            :release_runner -> {:ok, %{text: turn.prompt}}
          end
        else
          {:ok, %{text: turn.prompt}}
        end
      end,
      interval: 60_000,
      name: Tightbeam.LaneManager
    ]

    start_supervised!({LaneManager, manager_opts})
    %{db: db, manager_opts: manager_opts}
  end

  test "a lane manager that has just crashed does not fail a committed delivery", ctx do
    registry = :"lane_nudge_registry_#{System.unique_integer([:positive])}"
    start_supervised!({ConnRegistry, name: registry})

    dead = spawn(fn -> :ok end)
    ref = Process.monitor(dead)
    assert_receive {:DOWN, ^ref, :process, ^dead, _}

    {:appended, message} =
      Projection.append(ctx.db, %{
        session_key: "k1",
        role: "user",
        content: "committed before the manager restarts",
        sender: "test:lane-nudge"
      })

    {result, log} =
      ExUnit.CaptureLog.with_log(fn ->
        Gateway.complete_delivery(
          ctx.db,
          {:appended, "k1", message, [conn_registry: registry, lane_manager: dead]}
        )
      end)

    assert result == :appended
    assert log =~ "lane nudge after a committed delivery to k1 did not complete"
    assert log =~ "noproc"
  end

  test "a busy lane manager does not fail a committed delivery", ctx do
    registry = :"lane_nudge_registry_#{System.unique_integer([:positive])}"
    start_supervised!({ConnRegistry, name: registry})
    test_pid = self()

    busy =
      spawn_link(fn ->
        send(test_pid, :busy_ready)

        receive do
          :stop -> :ok
        end
      end)

    assert_receive :busy_ready
    on_exit(fn -> send(busy, :stop) end)

    {:appended, message} =
      Projection.append(ctx.db, %{
        session_key: "k1",
        role: "user",
        content: "committed before the lane nudge",
        sender: "test:lane-nudge"
      })

    {result, log} =
      ExUnit.CaptureLog.with_log(fn ->
        Gateway.complete_delivery(
          ctx.db,
          {:appended, "k1", message, [conn_registry: registry, lane_manager: busy]}
        )
      end)

    assert result == :appended
    assert log =~ "lane nudge after a committed delivery to k1 did not complete"
  end
end
