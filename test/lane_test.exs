defmodule Tightbeam.LaneTest do
  use Tightbeam.TestCase, async: false

  alias Tightbeam.{DB, Ledger, EventLog, LaneManager, Placement, SessionLane}

  setup do
    db = :"db_#{System.unique_integer([:positive])}"
    start_supervised!({DB, path: ":memory:", name: db})
    :ok = Ledger.ensure_schema(db)
    :ok = EventLog.ensure_schema(db)

    :ok =
      DB.execute(db, """
      CREATE TABLE sessions (
        sessionKey TEXT PRIMARY KEY,
        model TEXT NOT NULL,
        thinkingLevel TEXT,
        modelContext TEXT,
        harness TEXT NOT NULL,
        state TEXT NOT NULL DEFAULT 'active',
        adjudicationHold TEXT,
        updatedAt INTEGER NOT NULL DEFAULT 0
      );
      INSERT INTO sessions (sessionKey, model, thinkingLevel, harness)
      VALUES
        ('k1', 'claude-sonnet-5', 'medium', 'claude'),
        ('k2', 'claude-sonnet-5', 'medium', 'claude');
      """)

    reg = start_supervised!({Registry, keys: :unique, name: Tightbeam.LaneRegistry})

    task_sup =
      start_supervised!({Task.Supervisor, name: :"tsup_#{System.unique_integer([:positive])}"})

    lane_sup =
      start_supervised!(
        {DynamicSupervisor,
         strategy: :one_for_one, name: :"lsup_#{System.unique_integer([:positive])}"}
      )

    %{db: db, reg: reg, task_sup: task_sup, lane_sup: lane_sup}
  end

  defp enqueue!(db, sk, prompt) do
    {:ok, seq} =
      Ledger.enqueue(db, %{
        session_key: sk,
        message_id: "m_#{System.unique_integer([:positive])}",
        origin: "user:t",
        prompt: prompt
      })

    seq
  end

  # runner that records execution order into an Agent and echoes uppercased
  defp recording_runner(agent) do
    fn turn ->
      Agent.update(agent, &[turn.prompt | &1])
      {:ok, %{text: String.upcase(turn.prompt)}}
    end
  end

  test "lane drains queued turns in seq order, one at a time, marking terminals", ctx do
    {:ok, agent} = Agent.start_link(fn -> [] end)
    enqueue!(ctx.db, "k1", "first")
    enqueue!(ctx.db, "k1", "second")

    {:ok, mgr} =
      LaneManager.start_link(
        db: ctx.db,
        lane_sup: ctx.lane_sup,
        task_sup: ctx.task_sup,
        runner: recording_runner(agent),
        interval: 60_000,
        name: :"mgr_#{System.unique_integer([:positive])}"
      )

    :ok = LaneManager.reconcile(mgr)
    assert eventually(fn -> Ledger.pending_sessions(ctx.db) == [] end)
    assert Agent.get(agent, &Enum.reverse(&1)) == ["first", "second"]
  end

  test "reconciler starts a lane for committed work with NO doorbell (liveness)", ctx do
    {:ok, agent} = Agent.start_link(fn -> [] end)
    # commit work, then start the manager — no nudge was ever sent
    enqueue!(ctx.db, "k1", "orphaned-commit")

    {:ok, _mgr} =
      LaneManager.start_link(
        db: ctx.db,
        lane_sup: ctx.lane_sup,
        task_sup: ctx.task_sup,
        runner: recording_runner(agent),
        interval: 60_000,
        name: :"mgr_#{System.unique_integer([:positive])}"
      )

    # init runs one reconcile pass; the committed turn must be picked up
    assert eventually(fn -> Ledger.pending_sessions(ctx.db) == [] end)
    assert Agent.get(agent, & &1) == ["orphaned-commit"]
  end

  test "a crashing runner marks the turn failed and the lane drains on", ctx do
    {:ok, agent} = Agent.start_link(fn -> [] end)

    runner = fn turn ->
      if turn.prompt == "boom", do: raise("kaboom")
      Agent.update(agent, &[turn.prompt | &1])
      {:ok, %{text: turn.prompt}}
    end

    enqueue!(ctx.db, "k1", "boom")
    enqueue!(ctx.db, "k1", "survivor")

    {:ok, mgr} =
      LaneManager.start_link(
        db: ctx.db,
        lane_sup: ctx.lane_sup,
        task_sup: ctx.task_sup,
        runner: runner,
        interval: 60_000,
        name: :"mgr_#{System.unique_integer([:positive])}"
      )

    :ok = LaneManager.reconcile(mgr)
    assert eventually(fn -> Ledger.pending_sessions(ctx.db) == [] end)
    # survivor ran; boom is terminal-failed, never retried
    assert Agent.get(agent, & &1) == ["survivor"]

    {:ok, [[n]]} =
      {:ok, DB.query(ctx.db, "SELECT COUNT(*) FROM turns WHERE status='failed'") |> elem(1)}

    assert n == 1
  end

  test "a placement refusal reaches the turn publisher by name, not as task_crash", ctx do
    parent = self()
    seq = enqueue!(ctx.db, "k1", "vanished host")

    {:ok, _mgr} =
      LaneManager.start_link(
        db: ctx.db,
        lane_sup: ctx.lane_sup,
        task_sup: ctx.task_sup,
        runner: fn _turn ->
          raise Placement.Refusal,
            code: "unknown_host",
            host: "eurisko",
            harness: "codex",
            message:
              "host eurisko is not configured for codex; run tightbeam assimilate <ssh-dest> --name eurisko --as-user <adminUserId>"
        end,
        interval: 60_000,
        terminal_publisher: fn payload -> send(parent, {:turn_payload, payload}) end,
        name: :placement_refusal_lane_manager
      )

    :ok = LaneManager.ensure_lane(:placement_refusal_lane_manager, "k1")

    assert_receive {:turn_payload,
                    %{
                      status: "failed",
                      error: error,
                      session_key: "k1"
                    }}

    assert error =~ "host eurisko is not configured for codex"
    assert error =~ "tightbeam assimilate <ssh-dest> --name eurisko"
    refute error =~ "task_crash"

    {:ok, [[status, stored_error]]} =
      DB.query(ctx.db, "SELECT status, error FROM turns WHERE seq=?1", [seq])

    assert status == "failed"
    assert stored_error == error
  end

  defp eventually(fun, tries \\ 60) do
    cond do
      fun.() ->
        true

      tries == 0 ->
        false

      true ->
        Process.sleep(25)
        eventually(fun, tries - 1)
    end
  end

  test "cancel_current CAS-cancels the running turn, kills the task, drains on", ctx do
    test_pid = self()

    runner = fn turn ->
      send(test_pid, {:started, turn.prompt})

      if turn.prompt == "hang" do
        receive do: (:never -> :ok)
      else
        {:ok, %{}}
      end
    end

    mgr_name = :"mgr_#{System.unique_integer([:positive])}"

    {:ok, _mgr} =
      LaneManager.start_link(
        db: ctx.db,
        lane_sup: ctx.lane_sup,
        task_sup: ctx.task_sup,
        runner: runner,
        interval: 60_000,
        name: mgr_name,
        on_terminal: fn session_key, seq -> send(test_pid, {:terminal, session_key, seq}) end
      )

    {:ok, seq1} =
      Ledger.enqueue(ctx.db, %{
        session_key: "k1",
        message_id: "m_hang",
        origin: "user:u",
        prompt: "hang"
      })

    {:ok, _} =
      Ledger.enqueue(ctx.db, %{
        session_key: "k1",
        message_id: "m_next",
        origin: "user:u",
        prompt: "next"
      })

    :ok = LaneManager.ensure_lane(mgr_name, "k1")
    assert_receive {:started, "hang"}

    assert {:ok, %{seq: ^seq1, message_id: "m_hang"}} = SessionLane.cancel_current("k1")
    assert_receive {:terminal, "k1", ^seq1}

    # canceled is terminal and the lane drains to the next queued turn
    # IMMEDIATELY (a second cancel in that window legitimately targets it).
    assert_receive {:started, "next"}
    assert eventually(fn -> Ledger.pending_sessions(ctx.db) == [] end)
    assert SessionLane.cancel_current("k1") == :not_running
    {:ok, [[status]]} = DB.query(ctx.db, "SELECT status FROM turns WHERE seq = ?1", [seq1])
    assert status == "canceled"
  end

  test "reconcile republishes recovered terminals through the same on_terminal closure", ctx do
    parent = self()
    seq = enqueue!(ctx.db, "k1", "interrupted")
    assert {:ok, %{seq: ^seq}} = Ledger.claim_next(ctx.db, "k1", "dead-owner")

    {:ok, _mgr} =
      LaneManager.start_link(
        db: ctx.db,
        lane_sup: ctx.lane_sup,
        task_sup: ctx.task_sup,
        runner: fn _ -> {:ok, %{}} end,
        interval: 60_000,
        terminal_publisher: fn _ -> :ok end,
        on_terminal: fn session_key, terminal_seq ->
          send(parent, {:recovered_terminal, session_key, terminal_seq})
        end,
        name: :"mgr_#{System.unique_integer([:positive])}"
      )

    assert_receive {:recovered_terminal, "k1", ^seq}
    {:ok, [[status]]} = DB.query(ctx.db, "SELECT status FROM turns WHERE seq=?1", [seq])
    assert status == "failed_unknown"
  end
end
