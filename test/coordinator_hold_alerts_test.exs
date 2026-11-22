defmodule Tightbeam.CoordinatorHoldAlertsTest do
  use Tightbeam.TestCase, async: false

  alias Tightbeam.{
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

  setup do
    db = start_supervised!({DB, path: ":memory:", name: nil})
    :ok = Tightbeam.Schema.ensure_all(db)
    Devices.add_user(db, "fixture-owner", true)
    %{db: db, runner: runner(self())}
  end

  test "a mix of park and model holds alerts once when the last coordinator is held", ctx do
    session(ctx.db, @main, "generic", "claude", "build-host", @model)
    session(ctx.db, @exec, "uncle-enzo.exec", "claude", "second-host", @model)
    session(ctx.db, @deliverator, "uncle-enzo.deliverator", "claude", "build-host", @other_model)
    session(ctx.db, @worker, "worker", "claude", "third-host", @model)
    assert {:ok, :no_launch} = HarnessProcess.begin_park(ctx.db, @park)
    assert reconcile(ctx) == nil
    refute_received {:sent, _, _, _}

    model_hold(ctx.db, @exec, "second-host", @model)
    assert reconcile(ctx) == nil

    assert_received {:sent, first, "Tightbeam coordinators are held", body}
    assert body =~ "All 3 coordinators are held."
    assert body =~ "claude at build-host has 2 held sessions."
    assert body =~ "claude (#{@model}) at second-host has 1 held session"
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
    assert_no_agent_side_effects(ctx.db)
  end

  test "a model-only outage releases on a normal answer on the same route", ctx do
    session(ctx.db, @main, "generic", "claude", "build-host", @model)
    session(ctx.db, @worker, "worker", "claude", "build-host", @other_model)
    session(ctx.db, @remote_worker, "worker", "claude", "second-host", @model)
    session(ctx.db, @exec, "exec", "claude", "second-host", @model)
    assert :ok = DB.execute(ctx.db, "UPDATE sessions SET state='retired' WHERE archetype='exec'")

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
    assert {:ok, :no_launch} = HarnessProcess.begin_park(ctx.db, @park)

    opts = [db: ctx.db, runner: ctx.runner]
    server = start_supervised!({CoordinatorHoldAlerts, opts})
    assert_receive {:sent, _, "Tightbeam coordinators are held", _}, 1_000
    :sys.get_state(server)
    stop_supervised!(CoordinatorHoldAlerts)

    server = start_supervised!({CoordinatorHoldAlerts, opts})
    :sys.get_state(server)
    refute_received {:sent, _, _, _}
    assert %{host: "second-host"} = Org.set_host(ctx.db, @main, "second-host")
    assert_receive {:sent, _, "A Tightbeam coordinator is available", recovery}, 1_000
    assert recovery =~ "Main can take turns again on claude at second-host."
    assert HarnessProcess.parked?(ctx.db, @park)
    :sys.get_state(server)
    assert {:ok, [[2]]} = DB.query(ctx.db, "SELECT COUNT(*) FROM coordinator_hold_sends")
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
    assert_received {:sent, ^operation, "Tightbeam coordinators are held", "Reserved alert"}
    assert reconcile(ctx, @at + 1) == nil
    refute_received {:sent, _, _, _}
  end

  test "a source wake in a held carrier supplies a named install window and reset timing", ctx do
    session(ctx.db, @main, "generic", "claude", "build-host", @model)
    seq = enqueue(ctx.db, @main)
    deadline = @at + :timer.hours(1)

    assert {:ok, :ok} =
             DB.transaction(ctx.db, fn txn ->
               Txn.q(
                 txn,
                 """
                 INSERT INTO work_items(id,title,ownerUserId,createdByUser,createdAt)
                 VALUES ('window','Approved install window','fixture-owner','fixture-owner',?1)
                 """,
                 [@at]
               )

               Txn.q(
                 txn,
                 """
                 INSERT INTO wakes(wakeId,sessionKey,origin,prompt,dueAt,createdAt,state,work_item_id,deliveredTurnSeq)
                 VALUES ('member',?1,'process:tightbeam','install',?2,?3,'fired','window',?4),
                        ('ordinary',?1,'process:tightbeam','ordinary work',?3,?3,'fired',NULL,?4)
                 """,
                 [@main, deadline, @at, seq]
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
    assert body =~ "Provider reset Nov 22 11:00 UTC."
    refute body =~ "Scheduled work"

    # Admission can reopen while the health incident still awaits a success.
    assert :ok = HarnessProcess.complete_park(ctx.db, @park)
    assert HarnessHealth.unavailable?(ctx.db, "claude", "build-host")
    assert reconcile(ctx, @at + 1) == nil
    assert_received {:sent, _, "A Tightbeam coordinator is available", _}
  end

  defp reconcile(ctx, at \\ @at), do: CoordinatorHoldAlerts.reconcile(ctx.db, at, ctx.runner)

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

  defp assert_no_agent_side_effects(db) do
    for table <- ~w(harklight_wake_handles wakes) do
      assert {:ok, [[0]]} = DB.query(db, "SELECT count(*) FROM #{table}")
    end

    assert {:ok, [[1]]} = DB.query(db, "SELECT count(*) FROM turns")
  end

  defp runner(test, mode \\ :committed) do
    fn
      ["send", "--prepare" | args] ->
        op = arg(args, "--op-id")
        assert arg(args, "--type") == "fyi"
        assert arg(args, "--session") == "new"
        assert arg(args, "--route") == "other"
        refute "--reply" in args
        title = arg(args, "--title")
        body = arg(args, "--body")
        Process.put({__MODULE__, op}, {title, body})

        frame(%{
          kind: "prepared",
          op_id: op,
          files: [],
          request: %{
            type: "send",
            op_id: op,
            route: "other",
            session_handle: @handle,
            message: %{sender_id: "tightbeam", title: title, body: body, message_id: op}
          }
        })

      ["send", "--execute", "--op-id", op] ->
        {title, body} = Process.delete({__MODULE__, op})
        send(test, {:sent, op, title, body})

        case mode do
          :committed ->
            frame(%{
              kind: "committed",
              operation: "send",
              op_id: op,
              response: %{session_handle: @handle, sender_id: "tightbeam", message_id: op}
            })

          :refused ->
            {"refused", 2}

          :unknown ->
            {"transport closed", 1}
        end
    end
  end

  defp arg(args, flag), do: Enum.at(args, Enum.find_index(args, &(&1 == flag)) + 1)
  defp frame(map), do: {JSON.encode!(map), 0}
end
