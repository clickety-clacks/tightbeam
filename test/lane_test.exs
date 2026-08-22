defmodule Tightbeam.LaneTest do
  use Tightbeam.TestCase, async: false

  alias Tightbeam.{DB, Ledger, EventLog, LaneManager, Placement, Schema, SessionLane}

  setup do
    db = :"db_#{System.unique_integer([:positive])}"
    start_supervised!({DB, path: ":memory:", name: db})
    :ok = Schema.ensure_all(db)

    :ok =
      DB.execute(db, """
      INSERT INTO sessions
        (sessionKey,displayName,ownerUserId,origin,operationalParent,archetype,
         harness,provider,model,thinkingLevel,host,createdAt,updatedAt)
      VALUES
        ('k1','K1','t','user:t','k1','default','claude','anthropic',
         'claude-sonnet-5','medium','testhost',1,1),
        ('k2','K2','t','user:t','k1','default','claude','anthropic',
         'claude-sonnet-5','medium','testhost',2,2);
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

  test "a delivered runner mutation commits with the terminal CAS and publishes afterward", ctx do
    parent = self()
    seq = enqueue!(ctx.db, "k1", "recover")

    runner = fn _turn ->
      {:ok,
       %{
         terminal_publish: fn terminal -> send(parent, {:wire_terminal, terminal}) end,
         record_in_txn: fn txn ->
           EventLog.lifecycle_in_txn(txn, "lane_success_record", "k1", "seq=#{seq}")
           fn -> send(parent, :post_commit) end
         end
       }}
    end

    {:ok, _mgr} =
      LaneManager.start_link(
        db: ctx.db,
        lane_sup: ctx.lane_sup,
        task_sup: ctx.task_sup,
        runner: runner,
        interval: 60_000,
        name: :"mgr_#{System.unique_integer([:positive])}"
      )

    assert_receive :post_commit
    assert_receive {:wire_terminal, "delivered"}

    assert {:ok, [["delivered"]]} =
             DB.query(ctx.db, "SELECT status FROM turns WHERE seq=?1", [seq])

    assert Enum.any?(EventLog.lifecycle_events(ctx.db), fn event ->
             event.kind == "lane_success_record" and event.subject == "k1"
           end)
  end

  test "a coded refusal crosses the lane as stable JSON instead of inspected Elixir", ctx do
    enqueue!(ctx.db, "k1", "refuse")

    refusal = %{
      code: "DIV-CURSOR-API-KEY-ONLY",
      message: "Cursor requires a banked API key"
    }

    {:ok, _mgr} =
      LaneManager.start_link(
        db: ctx.db,
        lane_sup: ctx.lane_sup,
        task_sup: ctx.task_sup,
        runner: fn _turn -> {:error, refusal} end,
        interval: 60_000,
        name: :coded_refusal_lane_manager
      )

    assert eventually(fn -> Ledger.pending_sessions(ctx.db) == [] end)
    assert {:ok, [["failed", encoded]]} = DB.query(ctx.db, "SELECT status,error FROM turns")

    assert JSON.decode!(encoded) == %{
             "code" => "DIV-CURSOR-API-KEY-ONLY",
             "message" => "Cursor requires a banked API key"
           }

    refute encoded =~ "%{"
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

    assert {:ok, [["failed", "turn-task-crash", "process:tightbeam"]]} =
             DB.query(
               ctx.db,
               """
               SELECT outcome, cause, principal FROM turn_lifecycle_events
               WHERE eventKey='terminal:committed'
                 AND turnSeq=(SELECT seq FROM turns WHERE prompt='boom')
               """
             )
  end

  test "a placement refusal reaches the turn publisher by name, not as task_crash", ctx do
    parent = self()
    seq = enqueue!(ctx.db, "k1", "vanished host")

    expected =
      "host eurisko is not configured for codex; run tightbeam assimilate <ssh-dest> " <>
        "--name eurisko --as-user <adminUserId>"

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
            message: expected
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

    assert error == expected

    {:ok, [[status, stored_error]]} =
      DB.query(ctx.db, "SELECT status, error FROM turns WHERE seq=?1", [seq])

    assert status == "failed"
    assert stored_error == expected
  end

  test "a transaction record is delivered to its after-commit callback only after commit", ctx do
    parent = self()
    seq = enqueue!(ctx.db, "k1", "known failure")

    runner = fn _turn ->
      {:error,
       %{
         reason: "failed",
         record_in_txn: fn txn ->
           EventLog.lifecycle_in_txn(txn, "recorded_failure", "k1", nil)
           :durable_record
         end,
         after_commit: fn :durable_record ->
           {:ok, [[count]]} =
             DB.query(
               ctx.db,
               "SELECT COUNT(*) FROM lifecycle_events WHERE kind='recorded_failure'"
             )

           send(parent, {:after_commit, count})
         end,
         terminal_publish: fn terminal -> send(parent, {:published, terminal}) end
       }}
    end

    {:ok, _mgr} =
      LaneManager.start_link(
        db: ctx.db,
        lane_sup: ctx.lane_sup,
        task_sup: ctx.task_sup,
        runner: runner,
        interval: 60_000,
        name: :after_commit_lane_manager
      )

    :ok = LaneManager.ensure_lane(:after_commit_lane_manager, "k1")

    assert_receive {:after_commit, 1}
    assert_receive {:published, "failed"}
    {:ok, [["failed"]]} = DB.query(ctx.db, "SELECT status FROM turns WHERE seq=?1", [seq])
  end

  test "a losing terminal CAS records and delivers no process-failure notice", ctx do
    parent = self()
    seq = enqueue!(ctx.db, "k1", "known process failure")

    :ok =
      DB.execute(ctx.db, """
      CREATE TABLE owner_markers (
        id INTEGER PRIMARY KEY,
        content TEXT NOT NULL
      )
      """)

    runner = fn turn ->
      assert :ok =
               Ledger.finish(ctx.db, turn.seq, "failed", "preempted winner",
                 owner_lease: turn.owner_lease
               )

      {:error,
       %{
         reason: "known process failure",
         record_in_txn: fn txn ->
           EventLog.lifecycle_in_txn(txn, "assignment_process_failure", "asg_loser", nil)

           :ok =
             DB.Txn.exec(
               txn,
               "INSERT INTO owner_markers (id, content) VALUES (1, 'action needed')"
             )

           :process_failure_notice
         end,
         after_commit: fn :process_failure_notice -> send(parent, :process_failure_delivered) end,
         terminal_publish: fn terminal -> send(parent, {:published, terminal}) end
       }}
    end

    {:ok, mgr} =
      LaneManager.start_link(
        db: ctx.db,
        lane_sup: ctx.lane_sup,
        task_sup: ctx.task_sup,
        runner: runner,
        interval: 60_000,
        name: :losing_process_failure_lane_manager
      )

    :ok = LaneManager.reconcile(mgr)
    assert eventually(fn -> Ledger.pending_sessions(ctx.db) == [] end)

    assert {:ok, [["failed", "preempted winner"]]} =
             DB.query(ctx.db, "SELECT status, error FROM turns WHERE seq=?1", [seq])

    refute Enum.any?(EventLog.lifecycle_events(ctx.db), fn event ->
             event.kind == "assignment_process_failure" and event.subject == "asg_loser"
           end)

    assert {:ok, [[0]]} = DB.query(ctx.db, "SELECT COUNT(*) FROM owner_markers")
    refute_receive :process_failure_delivered, 100
    refute_receive {:published, _terminal}, 100
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

    assert {:ok, %{seq: ^seq1, message_id: "m_hang"}} =
             SessionLane.cancel_current("k1",
               cause: "cancel-request",
               principal: "user:flynn"
             )

    assert_receive {:terminal, "k1", ^seq1}

    # canceled is terminal and the lane drains to the next queued turn
    # IMMEDIATELY (a second cancel in that window legitimately targets it).
    assert_receive {:started, "next"}
    assert eventually(fn -> Ledger.pending_sessions(ctx.db) == [] end)
    assert SessionLane.cancel_current("k1") == :not_running
    {:ok, [[status]]} = DB.query(ctx.db, "SELECT status FROM turns WHERE seq = ?1", [seq1])
    assert status == "canceled"

    assert {:ok, [["canceled", "cancel-request", "user:flynn"]]} =
             DB.query(
               ctx.db,
               """
               SELECT outcome, cause, principal FROM turn_lifecycle_events
               WHERE turnSeq=?1 AND eventKey='terminal:committed'
               """,
               [seq1]
             )

    assert {:ok, [["accepted"], ["claimed"], ["terminal:committed"]]} =
             DB.query(
               ctx.db,
               "SELECT eventKey FROM turn_lifecycle_events WHERE turnSeq=?1 ORDER BY ordinal",
               [seq1]
             )
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

    assert {:ok, [["failed_unknown", "boot-recovery", "process:tightbeam"]]} =
             DB.query(
               ctx.db,
               """
               SELECT outcome, cause, principal FROM turn_lifecycle_events
               WHERE turnSeq=?1 AND eventKey='terminal:committed'
               """,
               [seq]
             )
  end

  # The backstop, driven by the reconciler exactly as a real orphan is: the scan
  # feeds a session whose queued work no claim can reach, the lane names the
  # cause instead of nudging forever, and the named terminal rides the SAME
  # at-least-once publication every other terminal rides. Nothing here should
  # fire once `enqueue_in_txn/2`'s guard is in place — this proves the rows
  # ALREADY in a database written before it are resolved rather than swept.
  test "the reconciler resolves a queued turn nobody can claim instead of nudging it forever",
       ctx do
    parent = self()

    :ok =
      DB.execute(ctx.db, """
        INSERT INTO turns (sessionKey, messageId, origin, prompt, createdAt)
        VALUES ('agent:main:clawline:flynn:main', 'm_orphan', 'process:tightbeam',
                'an orphan prompt', 1)
      """)

    {:ok, [[seq]]} = DB.query(ctx.db, "SELECT seq FROM turns WHERE messageId = 'm_orphan'")

    {:ok, mgr} =
      LaneManager.start_link(
        db: ctx.db,
        lane_sup: ctx.lane_sup,
        task_sup: ctx.task_sup,
        runner: fn _ -> {:ok, %{}} end,
        interval: 60_000,
        terminal_publisher: fn row ->
          send(parent, {:published, row.seq, row.status, row.error})
        end,
        on_terminal: fn _key, _seq -> :ok end,
        name: :"mgr_#{System.unique_integer([:positive])}"
      )

    :ok = LaneManager.reconcile(mgr)
    assert eventually(fn -> Ledger.pending_sessions(ctx.db) == [] end)
    :ok = LaneManager.reconcile(mgr)

    assert_receive {:published, ^seq, "failed", error}
    assert error =~ "no session row"
    assert Ledger.non_terminal_older_than(ctx.db, -1) == []
  end
end
