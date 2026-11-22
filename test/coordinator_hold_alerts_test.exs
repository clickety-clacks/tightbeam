defmodule Tightbeam.CoordinatorHoldAlertsTest do
  use Tightbeam.TestCase, async: false
  @moduletag :tmp_dir

  alias Tightbeam.{
    Archetypes,
    CoordinatorHoldAlerts,
    DB,
    Devices,
    HarnessHealth,
    HarnessProcess,
    Ledger,
    Model,
    Org
  }

  alias Tightbeam.HarnessHealth.ModelRateLimit
  alias Tightbeam.DB.Txn

  @at 1_795_313_600_000
  @interval :timer.minutes(5)
  @main Org.personal_session_key("fixture-owner")
  @exec "agent:fixture:exec"
  @deliverator "agent:fixture:deliverator"
  @worker "agent:fixture:worker"
  @remote_worker "agent:fixture:remote-worker"
  @handle "317c35c2-76f1-4ff0-b659-3c616e20e210"
  @park {:claude, "shared", "build-host"}
  @model "claude-opus-5-5"
  @other_model "claude-sonnet-5-5"

  setup %{tmp_dir: base_dir} do
    previous = :persistent_term.get(Archetypes, :missing)

    on_exit(fn ->
      case previous do
        :missing -> :persistent_term.erase(Archetypes)
        value -> :persistent_term.put(Archetypes, value)
      end
    end)

    bundle = Path.join(base_dir, "identity/kungfu/uncle-enzo")
    File.mkdir_p!(Path.join(bundle, "archetypes"))

    manifests =
      for role <- ~w(exec deliverator exec-assistant) do
        File.write!(Path.join(bundle, "archetypes/#{role}.toml"), "name = \"#{role}\"\n")
        "kungfu/uncle-enzo/archetypes/#{role}.toml"
      end

    File.write!(Path.join(bundle, "installed.toml"), """
    name = "uncle-enzo"
    paths = #{JSON.encode!(manifests)}
    """)

    assert %{"uncle-enzo.exec" => %{manifest_name: "exec"}} = Archetypes.load!(base_dir)

    db = start_supervised!({DB, path: ":memory:", name: nil})
    :ok = Tightbeam.Schema.ensure_all(db)
    Devices.add_user(db, "fixture-owner", true)
    %{db: db, runner: runner(self())}
  end

  test "a mix of park and model holds alerts once when the last coordinator is held", ctx do
    session(ctx.db, @main, "generic", "claude", "build-host", @model)
    session(ctx.db, @exec, "uncle-enzo.exec", "claude", "second-host", @model)
    session(ctx.db, @deliverator, "uncle-enzo.deliverator", "claude", "build-host", @other_model)
    session(ctx.db, @worker, "uncle-enzo.exec-assistant", "claude", "third-host", @model)
    session(ctx.db, @remote_worker, "missing.exec", "claude", "third-host", @model)
    assert {:ok, :no_launch} = HarnessProcess.begin_park(ctx.db, @park)
    assert reconcile(ctx) == nil
    refute_received {:sent, _, _, _}

    model_hold(ctx.db, @exec, "second-host", @model)
    assert reconcile(ctx) == nil

    assert_received {:sent, first, "Tightbeam coordinators are held", body}
    assert body =~ "All 3 coordinators are held."
    assert body =~ "claude at build-host has 2 held sessions."
    assert body =~ "claude at second-host has 1 held session"
    refute body =~ @model
    assert body =~ "Tightbeam will resume work"
    refute body =~ @exec
    refute body =~ "third-host"
    assert reconcile(ctx, @at + 1) == nil
    refute_received {:sent, _, _, _}

    assert {:ok, :no_launch} =
             HarnessProcess.begin_park(ctx.db, {:claude, "shared", "second-host"})

    assert reconcile(ctx, @at + 1) == nil
    refute_received {:sent, _, _, _}

    assert :ok = HarnessProcess.complete_park(ctx.db, @park)
    assert reconcile(ctx, @at + 2) == nil
    assert_received {:sent, recovery, "A Tightbeam coordinator is available", recovery_body}
    assert first != recovery
    assert recovery_body =~ "Main can take turns again on claude at build-host."
    assert recovery_body =~ "One other session"
    assert reconcile(ctx, @at + 3) == nil
    refute_received {:sent, _, _, _}
    assert_no_agent_side_effects(ctx.db, 1)
  end

  test "a model-only outage releases on a normal answer on the same route", ctx do
    session(ctx.db, @main, "generic", "claude", "build-host", @model)
    session(ctx.db, @worker, "worker", "claude", "build-host", @other_model)
    session(ctx.db, @remote_worker, "worker", "claude", "second-host", @model)
    session(ctx.db, @exec, "uncle-enzo.exec", "claude", "second-host", @model)

    assert :ok =
             DB.execute(
               ctx.db,
               "UPDATE sessions SET state='retired' WHERE archetype='uncle-enzo.exec'"
             )

    model_hold(ctx.db, @main, "build-host", @model)
    refute HarnessProcess.parked?(ctx.db, @park)
    assert reconcile(ctx) == nil
    assert_received {:sent, _, "Tightbeam coordinators are held", _}

    success(ctx.db, @worker)
    success(ctx.db, @remote_worker)
    assert reconcile(ctx, @at + 1) == nil
    refute_received {:sent, _, _, _}
    assert [_held] = ModelRateLimit.held(ctx.db, "claude", "build-host")

    success(ctx.db, @main)
    assert reconcile(ctx, @at + 2) == nil
    assert_received {:sent, _, "A Tightbeam coordinator is available", _}
    assert [] = ModelRateLimit.held(ctx.db, "claude", "build-host")
  end

  test "a held worker with no active coordinator cannot start an episode", ctx do
    session(ctx.db, @worker, "worker", "claude", "build-host", @model)
    assert {:ok, :no_launch} = HarnessProcess.begin_park(ctx.db, @park)
    assert reconcile(ctx) == nil
    refute_received {:sent, _, _, _}
    assert {:ok, []} = DB.query(ctx.db, "SELECT id FROM coordinator_hold_episodes")
  end

  test "a brief second outage is suppressed and a lasting one observes the persisted floor",
       ctx do
    session(ctx.db, @main, "generic", "claude", "build-host", @model)
    assert {:ok, :no_launch} = HarnessProcess.begin_park(ctx.db, @park)
    assert reconcile(ctx) == nil
    assert_received {:sent, _, "Tightbeam coordinators are held", _}

    assert :ok = HarnessProcess.complete_park(ctx.db, @park)
    assert reconcile(ctx, @at + 1) == nil
    assert_received {:sent, _, "A Tightbeam coordinator is available", _}

    assert {:ok, :no_launch} = HarnessProcess.begin_park(ctx.db, @park)
    assert reconcile(ctx, @at + 2) == @at + @interval
    assert :ok = HarnessProcess.complete_park(ctx.db, @park)
    assert reconcile(ctx, @at + 3) == nil
    refute_received {:sent, _, _, _}

    assert {:ok, :no_launch} = HarnessProcess.begin_park(ctx.db, @park)
    assert reconcile(ctx, @at + 4) == @at + @interval
    refute_received {:sent, _, _, _}
    assert reconcile(ctx, @at + @interval) == nil
    assert_received {:sent, _, "Tightbeam coordinators are held", _}
    assert {:ok, [[3]]} = DB.query(ctx.db, "SELECT COUNT(*) FROM coordinator_hold_sends")
  end

  test "boot and a coordinator move drive outage and recovery across a worker restart", ctx do
    session(ctx.db, @main, "generic", "claude", "build-host", @model)
    session(ctx.db, @exec, "uncle-enzo.exec", "claude", "build-host", @model)
    Org.rename(ctx.db, @exec, "Private fixture token=sample-secret s_private")
    assert {:ok, :no_launch} = HarnessProcess.begin_park(ctx.db, @park)

    opts = [db: ctx.db, runner: ctx.runner]
    server = start_supervised!({CoordinatorHoldAlerts, opts})
    assert_receive {:sent, _, "Tightbeam coordinators are held", _}, 1_000
    :sys.get_state(server)
    stop_supervised!(CoordinatorHoldAlerts)

    server = start_supervised!({CoordinatorHoldAlerts, opts})
    :sys.get_state(server)
    refute_received {:sent, _, _, _}
    assert %{host: "second-host"} = Org.set_host(ctx.db, @exec, "second-host")
    assert_receive {:sent, _, "A Tightbeam coordinator is available", recovery}, 1_000
    assert recovery =~ "Exec can take turns again on claude at second-host."
    refute recovery =~ "sample-secret"
    refute recovery =~ "s_private"
    assert HarnessProcess.parked?(ctx.db, @park)
    :sys.get_state(server)
    assert {:ok, [[2]]} = DB.query(ctx.db, "SELECT COUNT(*) FROM coordinator_hold_sends")
  end

  test "a committed route recovery after reservation prevents the new outage send", ctx do
    session(ctx.db, @main, "generic", "claude", "build-host", @model)
    assert {:ok, :no_launch} = HarnessProcess.begin_park(ctx.db, @park)

    {previous, runner} =
      pending_recovery(ctx, fn ->
        # The earlier send runs after the new outage was reserved and before it is claimed.
        assert {:ok, [[nil]]} =
                 DB.query(ctx.db, """
                 SELECT s.attemptedAt FROM coordinator_hold_sends s
                 JOIN coordinator_hold_episodes e ON e.id=s.episodeId
                 WHERE e.closedAt IS NULL AND s.phase='outage'
                 """)

        assert :ok = HarnessProcess.complete_park(ctx.db, @park)
      end)

    assert reconcile(%{ctx | runner: runner}) == nil
    assert_received {:sent, ^previous, "A Tightbeam coordinator is available", _}
    refute_received {:sent, _, _, _}

    assert {:ok, [[@at, nil]]} =
             DB.query(
               ctx.db,
               """
               SELECT e.closedAt,s.attemptedAt FROM coordinator_hold_sends s
               JOIN coordinator_hold_episodes e ON e.id=s.episodeId
               WHERE e.openedAt=?1 AND s.phase='outage'
               """,
               [@at]
             )
  end

  test "a delayed recovery cannot backdate the next outage or shorten the floor after restart",
       ctx do
    session(ctx.db, @main, "generic", "claude", "build-host", @model)
    assert {:ok, :no_launch} = HarnessProcess.begin_park(ctx.db, @park)
    clock_cell = :atomics.new(1, [])
    :atomics.put(clock_cell, 1, @at)
    clock = fn -> :atomics.get(clock_cell, 1) end
    delay = :timer.minutes(1)

    {previous, runner} =
      pending_recovery(ctx, fn -> :atomics.add(clock_cell, 1, delay) end)

    opts = [db: ctx.db, runner: runner, clock: clock]
    server = start_supervised!({CoordinatorHoldAlerts, opts})
    assert_receive {:sent, ^previous, "A Tightbeam coordinator is available", _}, 1_000
    assert_receive {:sent, first, "Tightbeam coordinators are held", _}, 1_000
    :sys.get_state(server)
    attempted_at = @at + delay

    assert {:ok, [[^attempted_at]]} =
             DB.query(
               ctx.db,
               "SELECT attemptedAt FROM coordinator_hold_sends WHERE operationId=?1",
               [first]
             )

    assert :ok = HarnessProcess.complete_park(ctx.db, @park)
    assert_receive {:sent, _, "A Tightbeam coordinator is available", _}, 1_000
    :sys.get_state(server)
    stop_supervised!(CoordinatorHoldAlerts)

    assert {:ok, :no_launch} = HarnessProcess.begin_park(ctx.db, @park)
    :atomics.put(clock_cell, 1, @at + @interval)
    server = start_supervised!({CoordinatorHoldAlerts, opts})
    :sys.get_state(server)
    refute_received {:sent, _, _, _}

    :atomics.put(clock_cell, 1, attempted_at + @interval)
    CoordinatorHoldAlerts.changed()
    assert_receive {:sent, next, "Tightbeam coordinators are held", _}, 1_000
    assert next != first
  end

  test "a refused send is terminal and an uncertain send is never attempted again", ctx do
    session(ctx.db, @main, "generic", "claude", "build-host", @model)
    assert {:ok, :no_launch} = HarnessProcess.begin_park(ctx.db, @park)

    assert reconcile(%{ctx | runner: runner(self(), :refused)}) == nil
    assert_received {:sent, _, "Tightbeam coordinators are held", _}
    assert {:ok, [["failed"]]} = DB.query(ctx.db, "SELECT outcome FROM coordinator_hold_sends")
    assert :ok = HarnessProcess.complete_park(ctx.db, @park)
    assert reconcile(ctx, @at + 1) == nil
    refute_received {:sent, _, _, _}

    assert {:ok, :no_launch} = HarnessProcess.begin_park(ctx.db, @park)
    at = @at + @interval
    assert reconcile(%{ctx | runner: runner(self(), :unknown)}, at) == nil
    assert_received {:sent, _, "Tightbeam coordinators are held", _}

    assert {:ok, [["outcome_unknown"]]} =
             DB.query(ctx.db, "SELECT outcome FROM coordinator_hold_sends WHERE attemptedAt=?1", [
               at
             ])

    assert reconcile(ctx, at + 1) == nil
    refute_received {:sent, _, _, _}
    assert :ok = HarnessProcess.complete_park(ctx.db, @park)
    assert reconcile(ctx, at + 2) == nil
    assert_received {:sent, _, "A Tightbeam coordinator is available", _}
  end

  test "an operation reserved before restart is attempted once with its original ID", ctx do
    session(ctx.db, @main, "generic", "claude", "build-host", @model)
    assert {:ok, :no_launch} = HarnessProcess.begin_park(ctx.db, @park)
    operation = Tightbeam.Id.uuid4()

    assert :ok =
             DB.execute(ctx.db, """
             INSERT INTO coordinator_hold_episodes(id,ownerUserId,openedAt,holdSources)
             VALUES ('episode','fixture-owner',#{@at},'[]');
             INSERT INTO coordinator_hold_sends(episodeId,phase,operationId,body)
             VALUES ('episode','outage','#{operation}','Reserved alert');
             """)

    assert reconcile(ctx) == nil
    assert_received {:sent, ^operation, "Tightbeam coordinators are held", body}
    assert body =~ "The only active coordinator is held."
    assert reconcile(ctx, @at + 1) == nil
    refute_received {:sent, _, _, _}
  end

  test "a committed prepare response completes the episode without executing again", ctx do
    session(ctx.db, @main, "generic", "claude", "build-host", @model)
    assert {:ok, :no_launch} = HarnessProcess.begin_park(ctx.db, @park)

    assert reconcile(%{ctx | runner: runner(self(), :already_committed)}) == nil
    assert_received {:already_committed, operation}
    refute_received {:sent, _, _, _}

    assert {:ok, [["committed"]]} =
             DB.query(ctx.db, "SELECT outcome FROM coordinator_hold_sends WHERE operationId=?1", [
               operation
             ])

    assert_no_agent_side_effects(ctx.db, 0)
  end

  test "an internal error logs the original operation and stays uncertain across restart", ctx do
    session(ctx.db, @main, "generic", "claude", "build-host", @model)
    assert {:ok, :no_launch} = HarnessProcess.begin_park(ctx.db, @park)
    runner = runner(self(), :internal_error)

    diagnostic =
      ExUnit.CaptureLog.capture_log(fn ->
        assert reconcile(%{ctx | runner: runner}) == nil
      end)

    assert_received {:sent, operation, "Tightbeam coordinators are held", _}
    assert diagnostic =~ "Harklight internal_error. Operation send. Request-Id req-hold-500."
    assert diagnostic =~ "Operation ID #{operation}"

    opts = [db: ctx.db, runner: runner, clock: fn -> @at + 1 end]
    server = start_supervised!({CoordinatorHoldAlerts, opts})
    :sys.get_state(server)
    refute_received {:sent, _, _, _}

    assert {:ok, [[^operation, "outcome_unknown"]]} =
             DB.query(ctx.db, "SELECT operationId,outcome FROM coordinator_hold_sends")

    assert_no_agent_side_effects(ctx.db, 0)
  end

  test "a held carrier includes owned window timing without copying private titles", ctx do
    session(ctx.db, @main, "generic", "claude", "build-host", @model)
    seq = enqueue(ctx.db, @main)
    deadline = @at + :timer.hours(1)

    assert {:ok, :ok} =
             DB.transaction(ctx.db, fn txn ->
               Txn.q(
                 txn,
                 """
                 INSERT INTO work_items(id,title,ownerUserId,createdByUser,createdAt)
                 VALUES ('window','Approved install window','fixture-owner','fixture-owner',?1),
                        ('private-window','Private token=sample-secret asg_private','fixture-owner','fixture-owner',?1),
                        ('private-id','Review wi_private','fixture-owner','fixture-owner',?1),
                        ('private-key','Do not share key=example-value','fixture-owner','fixture-owner',?1),
                        ('private-uuid','Review 317c35c2-76f1-4ff0-b659-3c616e20e210','fixture-owner','fixture-owner',?1),
                        ('private-hex','Review 0123456789abcdef','fixture-owner','fixture-owner',?1),
                        ('private-token','Review abcdefgXYZ12_token123456789','fixture-owner','fixture-owner',?1),
                        ('private-session',?2,'fixture-owner','fixture-owner',?1),
                        ('foreign-window','Serve window','another-owner','another-owner',?1)
                 """,
                 [@at, "Move #{@main} to Codex"]
               )

               Txn.q(
                 txn,
                 """
                 INSERT INTO assignments(id,subject,holderKey,openedByUser,openedAt)
                 VALUES ('fixture-assignment','Assignment subject stays private',?1,'fixture-owner',?2)
                 """,
                 [@main, @at]
               )

               Txn.q(
                 txn,
                 """
                 INSERT INTO wakes(wakeId,sessionKey,origin,prompt,dueAt,createdAt,state,work_item_id,deliveredTurnSeq)
                 VALUES ('member',?1,'process:tightbeam','install',?2,?3,'fired','window',?4),
                        ('private-member',?1,'process:tightbeam','install',?2,?3,'fired','private-window',?4),
                        ('id-member',?1,'process:tightbeam','install',?2,?3,'fired','private-id',?4),
                        ('key-member',?1,'process:tightbeam','install',?2,?3,'fired','private-key',?4),
                        ('uuid-member',?1,'process:tightbeam','install',?2,?3,'fired','private-uuid',?4),
                        ('hex-member',?1,'process:tightbeam','install',?2,?3,'fired','private-hex',?4),
                        ('token-member',?1,'process:tightbeam','install',?2,?3,'fired','private-token',?4),
                        ('session-member',?1,'process:tightbeam','install',?2,?3,'fired','private-session',?4),
                        ('foreign-member',?1,'process:tightbeam','serve',?2-1,?3,'fired','foreign-window',?4),
                        ('ordinary',?1,'process:tightbeam','ordinary work',?3,?3,'fired',NULL,?4)
                 """,
                 [@main, deadline, @at, seq]
               )

               Txn.q(
                 txn,
                 """
                 INSERT INTO wakes(wakeId,sessionKey,origin,prompt,dueAt,createdAt,assignmentId)
                 VALUES ('assignment-source',?1,'process:tightbeam','timed work',?2,?3,'fixture-assignment')
                 """,
                 [@main, deadline - 2, @at]
               )

               :ok
             end)

    reason = %{
      "data" => %{"errorKind" => "rate_limit"},
      "message" => "You've hit your weekly limit · resets 11:00am UTC"
    }

    observed = DateTime.to_unix(~U[2026-11-22 09:00:00Z], :millisecond)

    result =
      HarnessHealth.observe(ctx.db, %{
        correlation_id: "fixture-limit",
        harness: "claude",
        host: "build-host",
        failure_class: "rate-limit-dead",
        evidence_kind: "authoritative-provider",
        observed_at: observed,
        cause: "Fixture account limit",
        principal: "process:tightbeam"
      })

    assert {_, %{observationId: _}} = result

    assert {:ok, :ok} =
             DB.transaction(ctx.db, fn txn ->
               Tightbeam.RateLimitReset.schedule_in_txn(
                 txn,
                 %{session_key: @main, harness: "claude", host: "build-host"},
                 result,
                 reason,
                 observed
               )
             end)

    assert reconcile(ctx) == nil
    assert_received {:sent, _, "Tightbeam coordinators are held", body}
    assert body =~ "Approved install window due"
    assert body =~ "8 held items with deadlines. Earliest due"
    assert body =~ "Provider reset Nov 22 11:00 UTC."
    refute body =~ "sample-secret"
    refute body =~ "asg_private"
    refute body =~ "wi_private"
    refute body =~ "example-value"
    refute body =~ @handle
    refute body =~ "0123456789abcdef"
    refute body =~ "abcdefgXYZ12_token123456789"
    refute body =~ @main
    refute body =~ "Assignment subject stays private"
    refute body =~ "Serve window"
    refute body =~ "Scheduled work"

    # Admission can reopen while the health incident still awaits a success.
    assert :ok = HarnessProcess.complete_park(ctx.db, @park)
    assert HarnessHealth.unavailable?(ctx.db, "claude", "build-host")
    assert reconcile(ctx, @at + 1) == nil
    assert_received {:sent, _, "A Tightbeam coordinator is available", _}
  end

  defp reconcile(ctx, at \\ @at),
    do: CoordinatorHoldAlerts.reconcile(ctx.db, fn -> at end, ctx.runner)

  defp pending_recovery(ctx, before_execute) do
    operation = Tightbeam.Id.uuid4()

    assert {:ok, :ok} =
             DB.transaction(ctx.db, fn txn ->
               Txn.q(
                 txn,
                 """
                 INSERT INTO coordinator_hold_episodes(id,ownerUserId,openedAt,closedAt,holdSources)
                 VALUES ('previous','fixture-owner',?1,?2,'[]')
                 """,
                 [@at - @interval, @at - 1]
               )

               Txn.q(
                 txn,
                 """
                 INSERT INTO coordinator_hold_sends(episodeId,phase,operationId,body,attemptedAt,outcome)
                 VALUES ('previous','outage',?1,'Previous outage',?2,'committed')
                 """,
                 [Tightbeam.Id.uuid4(), @at - @interval]
               )

               Txn.q(
                 txn,
                 """
                 INSERT INTO coordinator_hold_sends(episodeId,phase,operationId,body)
                 VALUES ('previous','recovery',?1,'Previous recovery')
                 """,
                 [operation]
               )

               :ok
             end)

    runner = fn args ->
      if args == ["send", "--execute", "--op-id", operation], do: before_execute.()
      ctx.runner.(args)
    end

    {operation, runner}
  end

  defp session(db, key, archetype, harness, host, model) do
    Org.create(db, %{
      session_key: key,
      display_name: key,
      owner_user_id: "fixture-owner",
      archetype: archetype,
      origin: "test",
      kind: if(key == @main, do: "main", else: "custom"),
      harness: harness,
      provider: "anthropic",
      host: host,
      model: Model.new(model)
    })
  end

  defp model_hold(db, session, host, model) do
    seq = enqueue(db, session)

    assert {:ok, :ok} =
             DB.transaction(db, fn txn ->
               Txn.q(txn, "UPDATE turns SET status='failed' WHERE seq=?1", [seq])

               ModelRateLimit.record_in_txn(txn, %{
                 harness: "claude",
                 host: host,
                 model: model,
                 session_key: session,
                 assignment_id: nil,
                 turn_seq: seq,
                 observed_at: @at,
                 cause: "fixture 429",
                 principal: "process:tightbeam"
               })
             end)
  end

  defp enqueue(db, session) do
    {:ok, {:ok, seq}} =
      DB.transaction(db, fn txn ->
        Ledger.enqueue_in_txn(txn, %{
          session_key: session,
          message_id: Tightbeam.Id.uuid4(),
          origin: "fixture",
          prompt: "fixture"
        })
      end)

    seq
  end

  defp success(db, session) do
    seq = enqueue(db, session)

    assert {:ok, :ok} =
             DB.transaction(db, fn txn ->
               Txn.q(txn, "UPDATE turns SET status='delivered' WHERE seq=?1", [seq])

               HarnessHealth.resolve_normal_turn_in_txn(txn, Org.get_in_txn(txn, session), %{
                 seq: seq,
                 session_key: session,
                 origin: "fixture"
               })
             end)
  end

  defp assert_no_agent_side_effects(db, turns) do
    for table <- ~w(harklight_wake_handles harklight_send_operations wakes) do
      assert {:ok, [[0]]} = DB.query(db, "SELECT count(*) FROM #{table}")
    end

    assert {:ok, [[^turns]]} = DB.query(db, "SELECT count(*) FROM turns")
  end

  defp runner(test, mode \\ :committed) do
    fn
      ["journal-id"] ->
        frame(%{kind: "journal", journal_id: "fixture-journal"})

      ["send", "--prepare" | args] ->
        op = arg(args, "--op-id")
        assert arg(args, "--type") == "fyi"
        assert arg(args, "--session") == "new"
        assert arg(args, "--sender-id") == "tightbeam"
        refute Enum.any?(~w(--route --reply --file --supersedes), &(&1 in args))
        title = arg(args, "--title")
        body = arg(args, "--body")

        prepared = %{
          sender: "tightbeam",
          session: @handle,
          files: [],
          supersedes: [],
          supersedes_local: [],
          message: %{title: title, body: body, message_type: "fyi"}
        }

        if mode == :already_committed do
          send(test, {:already_committed, op})
          committed(op, prepared)
        else
          Process.put({__MODULE__, op}, prepared)

          frame(%{
            kind: "prepared",
            operation: "send",
            op_id: op,
            request_id: op,
            session_handle: @handle,
            prepared: prepared
          })
        end

      ["send", "--execute", "--op-id", op] ->
        %{message: %{title: title, body: body}} = prepared = Process.delete({__MODULE__, op})
        send(test, {:sent, op, title, body})

        case mode do
          :committed ->
            committed(op, prepared)

          :refused ->
            frame(
              %{kind: "refused", operation: "send", op_id: op, status: 403, error: "forbidden"},
              2
            )

          :unknown ->
            frame(
              %{
                kind: "outcome_unknown",
                operation: "send",
                op_id: op,
                status: 503,
                error: "storage_unavailable"
              },
              7
            )

          :internal_error ->
            frame(
              %{
                kind: "outcome_unknown",
                operation: "send",
                op_id: op,
                status: 500,
                error: "internal_error",
                retryable: false,
                request_id: "req-hold-500"
              },
              7
            )
        end
    end
  end

  defp committed(op, prepared) do
    item = "fixture-item-#{op}"

    frame(%{
      kind: "committed",
      operation: "send",
      op_id: op,
      request_id: op,
      session_handle: @handle,
      item_id: item,
      prepared: prepared,
      response: %{message: %{item_id: item, session: @handle, sender: "tightbeam"}}
    })
  end

  defp arg(args, flag), do: Enum.at(args, Enum.find_index(args, &(&1 == flag)) + 1)
  defp frame(map, status \\ 0), do: {JSON.encode!(map), status}
end
