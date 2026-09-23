defmodule Tightbeam.LaneTest do
  use Tightbeam.TestCase, async: false

  alias Tightbeam.{
    ConnRegistry,
    DB,
    EventLog,
    Gateway,
    HarnessHealth,
    LaneManager,
    Ledger,
    Placement,
    Projection,
    Schema,
    SessionLane
  }

  setup do
    db = :"db_#{System.unique_integer([:positive])}"
    start_supervised!({DB, path: ":memory:", name: db})
    :ok = Schema.ensure_all(db)

    :ok =
      DB.execute(db, """
      INSERT INTO sessions
        (sessionKey,displayName,ownerUserId,origin,spawnedBy,archetype,
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

  defp ensure_global_registry do
    case ConnRegistry.start_link(name: Tightbeam.ConnRegistry) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
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

  test "a real lane terminal settles the current rung and publishes the next rung", ctx do
    parent = self()
    at = System.system_time(:millisecond)

    assert {:opened, opened} =
             HarnessHealth.observe_other(ctx.db, %{
               harness: "claude",
               host: "testhost",
               source_session_key: "k2",
               principal: {:session, "k2"},
               description: "lane route settlement",
               evidence_mode: "exact_error",
               observed_state: "provider route failed",
               exact_observed_error: "lane route reset",
               exact_probe: "provider health probe",
               recovery_condition: "a normal provider turn completes",
               not_known_class_reason: "not one of the named classes",
               observed_at: at,
               accepted_at: at,
               valid_until: at + 5_000,
               world_status: "UNKNOWN",
               redaction_confirmed: true,
               idempotency_key: "lane-route-settlement"
             })

    assert {:ok, [[first_wake, route_turn]]} =
             DB.query(
               ctx.db,
               "SELECT noticeWakeId,turnSeq FROM harness_health_other_routes WHERE incidentId=?1 AND ordinal=0",
               [opened.id]
             )

    assert is_binary(first_wake)
    assert is_integer(route_turn)

    runner = fn _turn ->
      {:error,
       %{
         reason: "route delivery failed",
         terminal_publish: fn terminal -> send(parent, {:route_terminal, terminal}) end,
         record_in_txn: fn _txn -> nil end
       }}
    end

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
    assert_receive {:route_terminal, "failed"}
    assert eventually(fn -> Ledger.pending_sessions(ctx.db) == [] end)

    assert {:ok, [["non_delivered", "failed"]]} =
             DB.query(
               ctx.db,
               "SELECT state,closedReason FROM harness_health_other_routes WHERE incidentId=?1 AND ordinal=0",
               [opened.id]
             )

    assert {:ok, [["skipped", "inactive"]]} =
             DB.query(
               ctx.db,
               "SELECT state,closedReason FROM harness_health_other_routes WHERE incidentId=?1 AND ordinal=1",
               [opened.id]
             )

    assert {:ok, [["skipped", "cycle", nil, nil]]} =
             DB.query(
               ctx.db,
               "SELECT state,closedReason,noticeWakeId,turnSeq FROM harness_health_other_routes WHERE incidentId=?1 AND ordinal=2",
               [opened.id]
             )

    assert {:ok, [["alerted", "no_active_main", nil, nil]]} =
             DB.query(
               ctx.db,
               "SELECT state,closedReason,noticeWakeId,turnSeq FROM harness_health_other_routes WHERE incidentId=?1 AND ordinal=3",
               [opened.id]
             )

    assert route_turn > 0
  end

  test "public route cancellation settles the real turn and advances to the owner terminus",
       ctx do
    parent = self()
    at = System.system_time(:millisecond)

    assert {:opened, opened} =
             HarnessHealth.observe_other(ctx.db, %{
               harness: "claude",
               host: "testhost",
               source_session_key: "k2",
               principal: {:session, "k2"},
               description: "lane route cancellation",
               evidence_mode: "exact_error",
               observed_state: "provider route failed",
               exact_observed_error: "lane cancel reset",
               exact_probe: "provider health probe",
               recovery_condition: "a normal provider turn completes",
               not_known_class_reason: "not one of the named classes",
               observed_at: at,
               accepted_at: at,
               valid_until: at + 5_000,
               world_status: "UNKNOWN",
               redaction_confirmed: true,
               idempotency_key: "lane-route-cancel"
             })

    assert {:ok, [[route_turn]]} =
             DB.query(
               ctx.db,
               "SELECT turnSeq FROM harness_health_other_routes WHERE incidentId=?1 AND ordinal=0",
               [opened.id]
             )

    runner = fn turn ->
      send(parent, {:cancel_started, turn.seq})
      receive do: (:never -> :ok)
    end

    {:ok, mgr} =
      LaneManager.start_link(
        db: ctx.db,
        lane_sup: ctx.lane_sup,
        task_sup: ctx.task_sup,
        runner: runner,
        interval: 60_000,
        on_terminal: fn session_key, seq -> send(parent, {:cancel_terminal, session_key, seq}) end,
        name: :"mgr_#{System.unique_integer([:positive])}"
      )

    :ok = LaneManager.reconcile(mgr)
    assert_receive {:cancel_started, ^route_turn}
    assert {:ok, %{seq: ^route_turn}} = SessionLane.cancel_current("k1")
    assert_receive {:cancel_terminal, "k1", ^route_turn}
    assert eventually(fn -> Ledger.pending_sessions(ctx.db) == [] end)

    assert {:ok, [["non_delivered", "canceled"]]} =
             DB.query(
               ctx.db,
               "SELECT state,closedReason FROM harness_health_other_routes WHERE incidentId=?1 AND ordinal=0",
               [opened.id]
             )

    assert {:ok, [["alerted", "no_active_main"]]} =
             DB.query(
               ctx.db,
               "SELECT state,closedReason FROM harness_health_other_routes WHERE incidentId=?1 AND ordinal=3",
               [opened.id]
             )
  end

  test "public route crash recovery settles the running turn once and advances", ctx do
    at = System.system_time(:millisecond)

    assert {:opened, opened} =
             HarnessHealth.observe_other(ctx.db, %{
               harness: "claude",
               host: "testhost",
               source_session_key: "k2",
               principal: {:session, "k2"},
               description: "lane route crash recovery",
               evidence_mode: "exact_error",
               observed_state: "provider route failed",
               exact_observed_error: "lane crash reset",
               exact_probe: "provider health probe",
               recovery_condition: "a normal provider turn completes",
               not_known_class_reason: "not one of the named classes",
               observed_at: at,
               accepted_at: at,
               valid_until: at + 5_000,
               world_status: "UNKNOWN",
               redaction_confirmed: true,
               idempotency_key: "lane-route-crash-recovery"
             })

    assert {:ok, [[route_turn]]} =
             DB.query(
               ctx.db,
               "SELECT turnSeq FROM harness_health_other_routes WHERE incidentId=?1 AND ordinal=0",
               [opened.id]
             )

    assert {:ok, %{seq: ^route_turn}} = Ledger.claim_next(ctx.db, "k1", "crash-recovery")
    assert [^route_turn] = Ledger.recover_running(ctx.db)
    assert Ledger.recover_running(ctx.db) == []

    assert {:ok, [["non_delivered", "failed_unknown"]]} =
             DB.query(
               ctx.db,
               "SELECT state,closedReason FROM harness_health_other_routes WHERE incidentId=?1 AND ordinal=0",
               [opened.id]
             )

    assert {:ok, [["alerted", "no_active_main"]]} =
             DB.query(
               ctx.db,
               "SELECT state,closedReason FROM harness_health_other_routes WHERE incidentId=?1 AND ordinal=3",
               [opened.id]
             )
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

  test "provider error with a foreign-held assignment cannot strand the lane", ctx do
    parent = self()

    :ok =
      DB.execute(ctx.db, """
      INSERT INTO assignments
        (id,subject,holderKey,openedBySession,openedAt,state,holderHarness,holderProvider)
      VALUES ('asg_foreign','foreign assignment','k2','k2',1,'open','claude','anthropic')
      """)

    {:ok, seq} =
      Ledger.enqueue(ctx.db, %{
        session_key: "k1",
        message_id: "m_foreign_provider",
        origin: "user:t",
        prompt: "provider error",
        assignment_id: "asg_foreign"
      })

    session = Tightbeam.Org.get(ctx.db, "k1")

    runner = fn turn ->
      if turn.seq == seq do
        {:error,
         %{
           reason: %{"data" => %{"codexErrorInfo" => "usageLimitExceeded"}},
           terminal_publish: fn terminal -> send(parent, {:provider_terminal, terminal}) end,
           record_in_txn: fn txn ->
             HarnessHealth.observe_turn_failure_in_txn(
               txn,
               session,
               %{seq: seq, session_key: "k1", origin: "user:t"},
               "provider",
               %{"data" => %{"codexErrorInfo" => "usageLimitExceeded"}}
             )

             raise "simulated finalize bookkeeping crash"
           end
         }}
      else
        send(parent, :provider_survivor_ran)
        {:ok, %{text: "survivor"}}
      end
    end

    enqueue!(ctx.db, "k1", "survivor")

    {:ok, mgr} =
      LaneManager.start_link(
        db: ctx.db,
        lane_sup: ctx.lane_sup,
        task_sup: ctx.task_sup,
        runner: runner,
        interval: 60_000,
        name: :lane_finalize_recurrence_mgr
      )

    :ok = LaneManager.reconcile(mgr)
    assert_receive :provider_survivor_ran
    assert_receive {:provider_terminal, "failed"}
    assert eventually(fn -> Ledger.pending_sessions(ctx.db) == [] end)

    assert {:ok, [["failed", error]]} =
             DB.query(ctx.db, "SELECT status,error FROM turns WHERE seq=?1", [seq])

    assert error =~ "usageLimitExceeded"

    assert {:ok, []} =
             DB.query(
               ctx.db,
               "SELECT assignmentId FROM harness_health_observations WHERE correlationId=?1",
               ["harness-turn:#{seq}:rate-limit-dead"]
             )
  end

  test "finalize preparation failures remain eligible for abandoned-owner recovery", ctx do
    parent = self()
    {:ok, runs} = Agent.start_link(fn -> [] end)
    first = enqueue!(ctx.db, "k1", "normal finalize failure")
    second = enqueue!(ctx.db, "k1", "crash finalize failure")
    later = enqueue!(ctx.db, "k1", "later eligible")

    runner = fn turn ->
      Agent.update(runs, &[turn.seq | &1])

      case turn.prompt do
        "normal finalize failure" ->
          send(parent, {:finalize_ready, turn.seq, self()})
          receive do: (:release_finalize -> {:ok, %{text: "normal"}})

        "crash finalize failure" ->
          send(parent, {:finalize_ready, turn.seq, self()})
          receive do: (:release_finalize -> raise "simulated task crash")

        "later eligible" ->
          send(parent, {:later_ready, turn.seq, self()})

          receive do
            :release_later ->
              send(parent, {:later_ran, turn.seq})
              {:ok, %{text: "later"}}
          end
      end
    end

    {:ok, mgr} =
      LaneManager.start_link(
        db: ctx.db,
        lane_sup: ctx.lane_sup,
        task_sup: ctx.task_sup,
        runner: runner,
        interval: 60_000,
        terminal_publisher: fn row ->
          send(parent, {:recovery_published, Map.get(row, :seq), row.status, row.error})
        end,
        name: :lane_finalize_preparation_recovery_mgr
      )

    assert_receive {:finalize_ready, ^first, first_pid}
    first_trigger = "block_finalize_#{first}"

    :ok =
      DB.execute(ctx.db, """
      CREATE TRIGGER #{first_trigger}
      BEFORE UPDATE OF status ON turns
      WHEN OLD.seq = #{first} AND OLD.status = 'running' AND NEW.status != 'running'
      BEGIN
        SELECT RAISE(ABORT, 'simulated finalize preparation failure');
      END;
      """)

    send(first_pid, :release_finalize)

    assert eventually(fn ->
             finalize_events =
               EventLog.lifecycle_events(ctx.db)
               |> Enum.filter(&(&1.subject == "k1:#{first}"))
               |> Enum.map(& &1.kind)
               |> Enum.sort()

             finalize_events == [
               "turn_finalize_fallback_failed",
               "turn_finalize_transaction_failed"
             ]
           end)

    assert {:ok, [["running", first_owner]]} =
             DB.query(ctx.db, "SELECT status,owner FROM turns WHERE seq=?1", [first])

    :ok = DB.execute(ctx.db, "DROP TRIGGER #{first_trigger}")
    :ok = LaneManager.reconcile(mgr)
    assert_receive {:finalize_ready, ^second, second_pid}

    second_trigger = "block_finalize_#{second}"

    :ok =
      DB.execute(ctx.db, """
      CREATE TRIGGER #{second_trigger}
      BEFORE UPDATE OF status ON turns
      WHEN OLD.seq = #{second} AND OLD.status = 'running' AND NEW.status != 'running'
      BEGIN
        SELECT RAISE(ABORT, 'simulated finalize preparation failure');
      END;
      """)

    :ok = LaneManager.reconcile(mgr)
    assert_receive {:recovery_published, ^first, "failed_unknown", first_error}
    assert first_error == "interrupted: outcome unknown"

    send(second_pid, :release_finalize)

    assert eventually(fn ->
             finalize_events =
               EventLog.lifecycle_events(ctx.db)
               |> Enum.filter(&(&1.subject == "k1:#{second}"))
               |> Enum.map(& &1.kind)
               |> Enum.sort()

             finalize_events == [
               "turn_finalize_fallback_failed",
               "turn_finalize_transaction_failed"
             ]
           end)

    assert {:ok, [["running", second_owner]]} =
             DB.query(ctx.db, "SELECT status,owner FROM turns WHERE seq=?1", [second])

    :ok = DB.execute(ctx.db, "DROP TRIGGER #{second_trigger}")
    :ok = LaneManager.reconcile(mgr)
    assert_receive {:later_ready, ^later, later_pid}
    :ok = LaneManager.reconcile(mgr)
    assert_receive {:recovery_published, ^second, "failed_unknown", second_error}
    assert second_error == "interrupted: outcome unknown"

    send(later_pid, :release_later)
    assert_receive {:later_ran, ^later}
    :ok = LaneManager.reconcile(mgr)
    assert_receive {:recovery_published, nil, "delivered", nil}
    assert eventually(fn -> Ledger.pending_sessions(ctx.db) == [] end)

    assert {:ok, [["failed_unknown", ^first_owner]]} =
             DB.query(ctx.db, "SELECT status,owner FROM turns WHERE seq=?1", [first])

    assert {:ok, [["failed_unknown", ^second_owner]]} =
             DB.query(ctx.db, "SELECT status,owner FROM turns WHERE seq=?1", [second])

    assert Agent.get(runs, &Enum.sort/1) == Enum.sort([first, second, later])
  end

  test "operator clear uses the real Gateway terminal publication and acknowledges once", ctx do
    parent = self()
    ensure_global_registry()

    {:ok, _ref, nil} =
      ConnRegistry.register(Tightbeam.ConnRegistry, %{
        pid: self(),
        user_id: "t",
        device_id: "lane-clear-#{System.unique_integer([:positive])}",
        is_admin: false,
        subscriptions: MapSet.new(["chat"])
      })

    seq = enqueue!(ctx.db, "k1", "gateway clear")
    assert {:ok, %{seq: ^seq}} = Ledger.claim_next(ctx.db, "k1", "dead-owner")

    {:ok, lane_pid} =
      SessionLane.start_link(
        session_key: "k1",
        db: ctx.db,
        task_sup: ctx.task_sup,
        runner: fn _ -> flunk("cleared turns must not invoke the provider runner") end,
        terminal_publisher: Gateway.terminal_publisher_for_test(ctx.db),
        on_terminal: fn session_key, terminal_seq ->
          send(parent, {:clear_terminal, session_key, terminal_seq})
        end
      )

    on_exit(fn -> if Process.alive?(lane_pid), do: GenServer.stop(lane_pid) end)

    assert {:ok, %{seq: ^seq, replayed: false, error: error}} =
             SessionLane.clear_stranded(
               "k1",
               seq,
               "provider outcome unknown",
               "gateway-clear",
               "user:t"
             )

    assert error == "operator cleared stranded turn: provider outcome unknown"

    assert_receive {:push,
                    %{
                      "event" => "prompt_turn_state",
                      "payload" => %{
                        "state" => "failed",
                        "terminalState" => true,
                        "error" => ^error
                      }
                    }}

    assert_receive {:push,
                    %{
                      "type" => "agent_progress",
                      "state" => "failed"
                    }}

    assert_receive {:clear_terminal, "k1", ^seq}

    assert {:ok, [[published_at]]} =
             DB.query(ctx.db, "SELECT publishedAt FROM turns WHERE seq=?1", [seq])

    assert is_integer(published_at)

    assert Enum.any?(
             Projection.list_after(ctx.db, "k1", nil, 100),
             &(&1.content =~ "side effects are UNKNOWN")
           )

    assert {:ok, %{seq: ^seq, replayed: true}} =
             SessionLane.clear_stranded(
               "k1",
               seq,
               "provider outcome unknown",
               "gateway-clear",
               "user:t"
             )

    refute_receive {:clear_terminal, "k1", ^seq}, 100
  end

  test "periodic reconciliation replaces an abandoned generation and fences late finalize", ctx do
    parent = self()
    {:ok, agent} = Agent.start_link(fn -> [] end)

    {:ok, _mgr} =
      LaneManager.start_link(
        db: ctx.db,
        lane_sup: ctx.lane_sup,
        task_sup: ctx.task_sup,
        runner: recording_runner(agent),
        interval: 20,
        terminal_publisher: fn row ->
          send(parent, {:periodic_terminal, row.status, row.message_id})
        end,
        name: :"lane_periodic_replacement_#{System.unique_integer([:positive])}"
      )

    first = enqueue!(ctx.db, "k1", "abandoned periodic")

    {:ok, [[first_message_id]]} =
      DB.query(ctx.db, "SELECT messageId FROM turns WHERE seq=?1", [first])

    assert {:ok, %{seq: ^first}} = Ledger.claim_next(ctx.db, "k1", "dead-generation")
    second = enqueue!(ctx.db, "k1", "replacement periodic")

    {:ok, [[second_message_id]]} =
      DB.query(ctx.db, "SELECT messageId FROM turns WHERE seq=?1", [second])

    assert eventually(fn -> Agent.get(agent, &Enum.reverse(&1)) == ["replacement periodic"] end)
    assert_receive {:periodic_terminal, "delivered", ^second_message_id}, 5_000
    assert_receive {:periodic_terminal, "failed_unknown", ^first_message_id}, 5_000

    assert {:ok, [["failed_unknown", "dead-generation"]]} =
             DB.query(ctx.db, "SELECT status,owner FROM turns WHERE seq=?1", [first])

    assert {:ok, [["delivered", replacement_owner]]} =
             DB.query(ctx.db, "SELECT status,owner FROM turns WHERE seq=?1", [second])

    assert replacement_owner =~ "lane:"
    refute replacement_owner == "dead-generation"
    assert :already_terminal = Ledger.finish(ctx.db, first, "delivered")
    refute_receive {:periodic_terminal, "failed_unknown", ^first_message_id}, 100
    assert eventually(fn -> Ledger.pending_sessions(ctx.db) == [] end)
  end

  test "reconciliation reaps an abandoned owner and makes the next turn eligible", ctx do
    first = enqueue!(ctx.db, "k1", "abandoned")
    assert {:ok, %{seq: ^first}} = Ledger.claim_next(ctx.db, "k1", "dead-owner")
    second = enqueue!(ctx.db, "k1", "replacement")
    {:ok, agent} = Agent.start_link(fn -> [] end)

    {:ok, mgr} =
      LaneManager.start_link(
        db: ctx.db,
        lane_sup: ctx.lane_sup,
        task_sup: ctx.task_sup,
        runner: recording_runner(agent),
        interval: 60_000,
        name: :lane_reaper_mgr
      )

    :ok = LaneManager.reconcile(mgr)
    assert eventually(fn -> Ledger.pending_sessions(ctx.db) == [] end)
    assert Agent.get(agent, &Enum.reverse(&1)) == ["replacement"]

    assert {:ok, [["failed_unknown"]]} =
             DB.query(ctx.db, "SELECT status FROM turns WHERE seq=?1", [first])

    assert {:ok, [["delivered"]]} =
             DB.query(ctx.db, "SELECT status FROM turns WHERE seq=?1", [second])
  end

  test "committed clear replay precedes active successor refusal", ctx do
    first = enqueue!(ctx.db, "k1", "already cleared")
    assert {:ok, %{seq: ^first}} = Ledger.claim_next(ctx.db, "k1", "dead-owner")

    assert {:ok, %{seq: ^first, replayed: false}} =
             Ledger.clear_stranded(
               ctx.db,
               "k1",
               first,
               "provider outcome lost",
               "clear-replay",
               "user:t"
             )

    parent = self()
    second = enqueue!(ctx.db, "k1", "active successor")

    runner = fn _turn ->
      send(parent, {:successor_active, self()})

      receive do
        :release_successor -> {:ok, %{text: "successor"}}
      end
    end

    {:ok, mgr} =
      LaneManager.start_link(
        db: ctx.db,
        lane_sup: ctx.lane_sup,
        task_sup: ctx.task_sup,
        runner: runner,
        interval: 60_000,
        name: :lane_clear_replay_mgr
      )

    :ok = LaneManager.reconcile(mgr)
    assert_receive {:successor_active, successor_pid}

    assert {:ok, %{seq: ^first, replayed: true}} =
             SessionLane.clear_stranded(
               "k1",
               first,
               "provider outcome lost",
               "clear-replay",
               "user:t"
             )

    assert {:error, %{code: "idempotency_key_conflict"}} =
             SessionLane.clear_stranded("k1", first, "different reason", "clear-replay", "user:t")

    assert {:error, %{code: "turn_active"}} =
             SessionLane.clear_stranded(
               "k1",
               first,
               "provider outcome lost",
               "clear-new",
               "user:t"
             )

    assert {:ok, [["running"]]} =
             DB.query(ctx.db, "SELECT status FROM turns WHERE seq=?1", [second])

    send(successor_pid, :release_successor)
    assert eventually(fn -> Ledger.pending_sessions(ctx.db) == [] end)

    assert {:ok, [["delivered"]]} =
             DB.query(ctx.db, "SELECT status FROM turns WHERE seq=?1", [second])
  end

  test "operator clear refuses an active owner", ctx do
    parent = self()
    seq = enqueue!(ctx.db, "k1", "active")

    runner = fn _turn ->
      send(parent, {:active_turn_started, self()})

      receive do
        :release_active -> {:ok, %{text: "released"}}
      end
    end

    {:ok, mgr} =
      LaneManager.start_link(
        db: ctx.db,
        lane_sup: ctx.lane_sup,
        task_sup: ctx.task_sup,
        runner: runner,
        interval: 60_000,
        name: :lane_active_refusal_mgr
      )

    :ok = LaneManager.reconcile(mgr)
    assert_receive {:active_turn_started, task_pid}

    assert {:error, %{code: "turn_active"}} =
             SessionLane.clear_stranded("k1", seq, "operator check", "active-clear", "user:t")

    assert {:ok, [["running"]]} = DB.query(ctx.db, "SELECT status FROM turns WHERE seq=?1", [seq])

    send(task_pid, :release_active)
  end
end
