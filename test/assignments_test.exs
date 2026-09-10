defmodule Tightbeam.AssignmentsTest do
  use Tightbeam.TestCase, async: false
  alias Tightbeam.Model

  alias Tightbeam.{
    Assignments,
    DB,
    Dispatch,
    Gateway,
    Ledger,
    Org,
    Projection,
    Rules,
    Supervision,
    Wakes,
    WorkItems,
    WorkState
  }

  setup do
    db = :"assignments_db_#{System.unique_integer([:positive])}"
    start_supervised!({DB, path: ":memory:", name: db})

    :ok = Tightbeam.Schema.ensure_all(db)

    register_hosts(db, %{
      "eezo" => %{
        ssh: nil,
        base_dir: Application.fetch_env!(:tightbeam, :base_dir),
        cli_bin: nil
      }
    })

    {:ok, _} =
      DB.query(
        db,
        "INSERT INTO users (userId, isAdmin, createdAt) VALUES ('admin', 1, 1), ('flynn', 0, 1), ('other', 0, 1)"
      )

    holder = session(db, "holder", "flynn")
    other = session(db, "other-session", "other")
    gateway_config = %{db: db, wake_tick_ms: 1_000}
    handlers = Gateway.handlers(gateway_config)
    Rules.load!(System.tmp_dir!(), Map.keys(handlers))
    %{db: db, holder: holder, other: other, handlers: handlers}
  end

  for {actor, expected} <- [
        {"user:flynn", {"flynn", nil, nil}},
        {"session:holder", {nil, "holder", nil}},
        {"process:tightbeam", {nil, nil, "process:tightbeam"}}
      ] do
    @retirement_actor actor
    @retirement_expected expected
    test "Firehose retirement retains exactly one actor generation for #{@retirement_actor}",
         ctx do
      assignment = handle(ctx, "assign", assign_call({:user, "flynn"}, "retirement provenance"))

      progress =
        handle(ctx, "attest", attest_call({:session, "holder"}, assignment.id, "progress"))

      assert progress.attest.kind == "progress"

      {:ok, attest_before} =
        DB.query(ctx.db, "SELECT * FROM attests WHERE assignmentId=?1", [assignment.id])

      assert [_] = retirement_callback(ctx.db, @retirement_actor)
      closed = handle(ctx, "assignment-get", assignment_get_call({:user, "flynn"}, assignment.id))
      assert closed.state == "closed"
      assert closed.outcome == "revoked"

      assert {closed.closedByUser, closed.closedBySession, closed.closedByProcess} ==
               @retirement_expected

      assert closed.revocationReason == "holder session retired"

      assert {:ok, [[closed_at, by_user, by_session, by_process, "holder session retired"]]} =
               DB.query(
                 ctx.db,
                 "SELECT revokedAt,revokedByUser,revokedBySession,revokedByProcess,reason FROM assignment_revocations WHERE assignmentId=?1",
                 [assignment.id]
               )

      assert closed_at == closed.closedAt
      assert {by_user, by_session, by_process} == @retirement_expected

      assert {:ok, [[1]]} =
               DB.query(
                 ctx.db,
                 "SELECT COUNT(*) FROM assignment_revocation_generations WHERE assignmentId=?1 AND reopeningId IS NULL",
                 [assignment.id]
               )

      assert {:ok, [[1]]} =
               DB.query(
                 ctx.db,
                 "SELECT COUNT(*) FROM assignment_interruptions WHERE assignmentId=?1",
                 [assignment.id]
               )

      assert {:ok, ^attest_before} =
               DB.query(ctx.db, "SELECT * FROM attests WHERE assignmentId=?1", [assignment.id])

      assert [] = retirement_callback(ctx.db, @retirement_actor)

      assert handle(ctx, "assignment-get", assignment_get_call({:user, "flynn"}, assignment.id)) ==
               closed

      assert {:ok, [[1]]} =
               DB.query(
                 ctx.db,
                 "SELECT COUNT(*) FROM assignment_revocations WHERE assignmentId=?1",
                 [assignment.id]
               )

      assert {:ok, []} = DB.query(ctx.db, "PRAGMA foreign_key_check")
    end
  end

  test "WorkState revocation reason follows the current reopening generation", ctx do
    assignment = handle(ctx, "assign", assign_call({:user, "flynn"}, "work-state provenance"))

    revoke =
      put_in(revoke_call({:user, "flynn"}, assignment.id), [:params, :reason], "first generation")

    assert %{outcome: "revoked"} = handle(ctx, "revoke-assignment", revoke)
    first = WorkState.detail(ctx.db, assignment.id).assignment
    assert first.revocationReason == "first generation"
    assert first.closedByUser == "flynn"
    assert first.closedByProcess == nil

    assert %{state: "open"} =
             handle(
               ctx,
               "reopen-assignment",
               reopen_call({:user, "flynn"}, assignment.id, "new generation")
             )

    reopened = WorkState.detail(ctx.db, assignment.id).assignment
    assert reopened.revocationReason == nil
    assert reopened.closedByUser == nil
    assert reopened.closedByProcess == nil

    assert %{outcome: "revoked"} =
             handle(
               ctx,
               "revoke-assignment",
               put_in(revoke, [:params, :reason], "second generation")
             )

    second = WorkState.detail(ctx.db, assignment.id).assignment
    assert second.revocationReason == "second generation"
    assert second.closedByUser == "flynn"

    assert {:ok, [[2]]} =
             DB.query(
               ctx.db,
               "SELECT COUNT(*) FROM assignment_revocations WHERE assignmentId=?1",
               [assignment.id]
             )
  end

  test "Firehose revocation preserves provenance and emits its committed state only once", ctx do
    alias Tightbeam.Firehose.Hub
    hub = start_supervised!({Hub, name: nil})
    :ok = Hub.register(hub, self(), %{mode: :all, db: ctx.db, user_id: "flynn", is_admin: false})
    assignment = handle(ctx, "assign", assign_call({:user, "flynn"}, "explicit revocation"))
    parent = self()

    call =
      revoke_call({:user, "flynn"}, assignment.id)
      |> put_in([:params, :reason], "Owner selected a different successor — 修復")
      |> Map.merge(%{
        firehose_in_txn: true,
        firehose_hub: hub,
        on_assignment_change: fn id, from -> send(parent, {:changed, id, from}) end
      })

    revoked = handle(ctx, "revoke-assignment", call)
    assert revoked.outcome == "revoked"
    assert revoked.revocationReason == call.params.reason
    assert revoked.closedByUser == "flynn"
    assert revoked.closedBySession == nil
    assert revoked.closedByProcess == nil
    assert_receive {:changed, id, _}
    assert id == assignment.id
    assert_receive {:firehose_notice, %{"class" => "verb.accepted"}}
    Hub.delivered(hub, self())
    assert_receive {:firehose_notice, %{"class" => "assignment.closed", "payload" => payload}}
    assert payload["id"] == assignment.id
    assert payload["revocationReason"] == call.params.reason
    Hub.delivered(hub, self())

    assert handle(ctx, "revoke-assignment", call) == revoked
    refute_receive {:changed, _, _}
    refute_receive {:firehose_notice, _}

    assert %{code: "assignment_closed"} =
             handle(
               ctx,
               "revoke-assignment",
               put_in(call, [:params, :reason], "different reason")
             )

    assert {:ok, [[1]]} =
             DB.query(
               ctx.db,
               "SELECT COUNT(*) FROM assignment_revocations WHERE assignmentId=?1",
               [assignment.id]
             )

    assert {:ok, [[1]]} =
             DB.query(
               ctx.db,
               "SELECT COUNT(*) FROM assignment_revocation_generations WHERE assignmentId=?1",
               [assignment.id]
             )

    assert {:ok, [[0]]} =
             DB.query(ctx.db, "SELECT COUNT(*) FROM attests WHERE assignmentId=?1", [
               assignment.id
             ])

    assert {:ok, []} = DB.query(ctx.db, "PRAGMA foreign_key_check")
  end

  test "Firehose revocation validates reason after authority and keeps rejected rows open", ctx do
    assignment = handle(ctx, "assign", assign_call({:user, "flynn"}, "reason boundary"))
    missing = call("revoke-assignment", {:user, "flynn"}, nil, %{assignment_id: assignment.id})
    assert %{code: "missing_reason"} = handle(ctx, "revoke-assignment", missing)

    for reason <- ["", "   ", 42, String.duplicate("x", 2001)] do
      assert %{code: "invalid_reason"} =
               handle(ctx, "revoke-assignment", put_in(missing, [:params, :reason], reason))
    end

    unauthorized = %{missing | principal: {:user, "other"}, origin: "user:other"}
    assert %{code: "not_authorized"} = handle(ctx, "revoke-assignment", unauthorized)

    assert handle(ctx, "assignment-get", assignment_get_call({:user, "flynn"}, assignment.id)).state ==
             "open"

    assert {:ok, [[0]]} =
             DB.query(
               ctx.db,
               "SELECT COUNT(*) FROM assignment_revocations WHERE assignmentId=?1",
               [assignment.id]
             )
  end

  test "reopen restores custody, records the close, and rearms every existing monitor", ctx do
    item = create_work_item(ctx, "reopen lifecycle")

    assignment =
      reopen_fixture_call({:user, "flynn"}, "reopen me", nil, item.id)
      |> put_in([:params, :files], ["lib/tightbeam/assignments.ex"])
      |> then(&handle(ctx, "assign", &1))

    closed = handle(ctx, "attest", attest_call({:session, "holder"}, assignment.id, "completion"))
    assert closed.assignment.state == "closed"

    assert {:ok, [[slate_wake_id]]} =
             DB.query(ctx.db, "SELECT slateWakeId FROM work_items WHERE id=?1", [item.id])

    assert is_binary(slate_wake_id)
    assert Wakes.get(ctx.db, slate_wake_id).state == "pending"

    reopened =
      handle(
        ctx,
        "reopen-assignment",
        reopen_call({:user, "flynn"}, assignment.id, "the assignment carries work again")
      )

    assert %{
             state: "open",
             outcome: nil,
             closedAt: nil,
             closedByUser: nil,
             closedBySession: nil,
             closingAttestId: nil
           } = reopened

    assert {:ok,
            [
              [
                "completed",
                prior_closed_at,
                nil,
                "holder",
                prior_attest_id,
                "flynn",
                nil,
                "the assignment carries work again"
              ]
            ]} =
             DB.query(
               ctx.db,
               """
               SELECT priorOutcome, priorClosedAt, priorClosedByUser, priorClosedBySession,
                      priorClosingAttestId, reopenedByUser, reopenedBySession, reason
               FROM assignment_reopenings WHERE assignmentId=?1
               """,
               [assignment.id]
             )

    assert prior_closed_at == closed.assignment.closedAt
    assert prior_attest_id == closed.assignment.closingAttestId

    assert {:ok, [["armed", "assignment_open"]]} =
             DB.query(
               ctx.db,
               "SELECT state,cause FROM supervision_entitlements WHERE assignmentId=?1",
               [assignment.id]
             )

    assert {:ok, [[1, "canceled"], [2, "armed"]]} =
             DB.query(
               ctx.db,
               "SELECT generation,state FROM effort_checkin_generations WHERE assignmentId=?1 ORDER BY generation",
               [assignment.id]
             )

    assert {:ok, [[nil]]} =
             DB.query(ctx.db, "SELECT slateWakeId FROM work_items WHERE id=?1", [item.id])

    assert Wakes.get(ctx.db, slate_wake_id).state == "canceled"
    assert Assignments.declared_files(ctx.db, assignment.id) == ["lib/tightbeam/assignments.ex"]

    assert marker_contents(ctx.db, "holder")
           |> Enum.member?(
             "[assignment reopened: #{assignment.id} by user:flynn — the assignment carries work again]"
           )

    fetched = handle(ctx, "assignment-get", assignment_get_call({:user, "flynn"}, assignment.id))
    assert [history] = fetched.reopenings
    assert history.assignmentId == assignment.id
    assert history.priorOutcome == "completed"
    assert history.priorClosedAt == prior_closed_at
    assert history.priorClosingAttestId == prior_attest_id
    assert history.reopenedByUser == "flynn"
    assert history.reopenedBySession == nil

    assert %{assignment: %{state: "closed", outcome: "completed"}} =
             handle(ctx, "attest", attest_call({:session, "holder"}, assignment.id, "completion"))
  end

  test "reopen authorization and refusals preserve every durable surface", ctx do
    assignment = handle(ctx, "assign", reopen_fixture_call({:user, "flynn"}, "authorization"))

    assert_reopen_refused!(ctx, {:user, "flynn"}, assignment.id, "why", "assignment_open")

    _ = handle(ctx, "attest", attest_call({:session, "holder"}, assignment.id, "completion"))

    assert_reopen_refused!(ctx, {:user, "flynn"}, assignment.id, nil, "missing_reason")
    assert_reopen_refused!(ctx, {:user, "flynn"}, assignment.id, "   ", "invalid_reason")
    assert_reopen_refused!(ctx, {:process, "cron"}, assignment.id, "why", "process_denied")
    assert_reopen_refused!(ctx, {:user, "other"}, assignment.id, "why", "not_authorized")

    assert %{state: "open"} =
             handle(
               ctx,
               "reopen-assignment",
               reopen_call({:session, "holder"}, assignment.id, "holder repair")
             )

    _ = handle(ctx, "attest", attest_call({:session, "holder"}, assignment.id, "completion"))

    assert %{state: "open"} =
             handle(
               ctx,
               "reopen-assignment",
               reopen_call({:user, "admin"}, assignment.id, "admin repair")
             )

    assert %{code: "unknown_assignment"} =
             handle(ctx, "reopen-assignment", reopen_call({:user, "flynn"}, "asg_missing", "why"))

    retired = handle(ctx, "assign", reopen_fixture_call({:user, "flynn"}, "retired holder"))
    _ = handle(ctx, "attest", attest_call({:session, "holder"}, retired.id, "completion"))
    {:ok, _} = DB.query(ctx.db, "UPDATE sessions SET state='retired' WHERE sessionKey='holder'")
    assert_reopen_refused!(ctx, {:user, "flynn"}, retired.id, "why", "session_retired")
    {:ok, _} = DB.query(ctx.db, "UPDATE sessions SET state='active' WHERE sessionKey='holder'")

    item = create_work_item(ctx, "terminal item")

    carded =
      handle(ctx, "assign", reopen_fixture_call({:user, "flynn"}, "item card", nil, item.id))

    _ = handle(ctx, "attest", attest_call({:session, "holder"}, carded.id, "completion"))

    _ =
      handle(
        ctx,
        "work-item-close",
        work_item_call("work-item-close", {:user, "flynn"}, %{work_item_id: item.id})
      )

    assert_reopen_refused!(ctx, {:user, "flynn"}, carded.id, "why", "work_item_not_open")
  end

  defp reopen_fixture_call(principal, subject, key \\ nil, work_item_id \\ nil) do
    assign_call(principal, subject, key, work_item_id)
    |> put_in([:params, :effect_kind], "coordination")
  end

  test "Firehose reopening crosses real Dispatch and Gateway with committed notice and refusal",
       ctx do
    alias Tightbeam.Firehose.Hub
    assignment = handle(ctx, "assign", reopen_fixture_call({:user, "flynn"}, "routed reopen"))
    closed = handle(ctx, "attest", attest_call({:session, "holder"}, assignment.id, "completion"))
    assert closed.assignment.state == "closed"
    hub = start_supervised!({Hub, name: nil})
    :ok = Hub.register(hub, self(), %{mode: :all, db: ctx.db, user_id: "flynn", is_admin: false})

    handlers =
      Gateway.handlers(%{
        db: ctx.db,
        base_dir: System.tmp_dir!(),
        wake_tick_ms: 1000,
        supervision_interval_ms: 3000
      })

    assert Map.has_key?(handlers, "reopen-assignment")

    call =
      reopen_call({:user, "flynn"}, assignment.id, "routed repair") |> Map.put(:firehose_hub, hub)

    assert {:ok, reopened} = Dispatch.dispatch(ctx.db, handlers, call)
    assert reopened.state == "open"
    assert_receive {:firehose_notice, %{"class" => "verb.accepted"}}
    Hub.delivered(hub, self())
    assert_receive {:firehose_notice, %{"class" => "assignment.reopened", "payload" => payload}}
    assert payload["id"] == assignment.id
    assert payload["state"] == "open"
    assert payload["outcome"] == nil
    Hub.delivered(hub, self())

    assert {:ok, [[3000]]} =
             DB.query(
               ctx.db,
               "SELECT supervisionIntervalMs FROM supervision_entitlements WHERE assignmentId=?1",
               [assignment.id]
             )

    assert {:ok, [[1]]} =
             DB.query(
               ctx.db,
               "SELECT COUNT(*) FROM assignment_reopenings WHERE assignmentId=?1",
               [assignment.id]
             )

    assert {:ok, [[1]]} =
             DB.query(
               ctx.db,
               "SELECT COUNT(*) FROM events WHERE verb='reopen-assignment' AND kind='verb'"
             )

    before = reopen_mutation_snapshot(ctx.db, assignment.id)
    assert {:error, %{code: "assignment_open"}} = Dispatch.dispatch(ctx.db, handlers, call)
    assert reopen_mutation_snapshot(ctx.db, assignment.id) == before
    assert_receive {:firehose_notice, %{"class" => "verb.denied"}}
    Hub.delivered(hub, self())
    refute_receive {:firehose_notice, _}

    assert {:ok, [[1]]} =
             DB.query(
               ctx.db,
               "SELECT COUNT(*) FROM events WHERE verb='reopen-assignment' AND kind='denied'"
             )
  end

  test "Firehose audit handoff rolls back with its event", ctx do
    parent = self()

    assert_raise MatchError, fn ->
      Tightbeam.EventLog.append_event_with_handoff(
        ctx.db,
        "verb",
        "synthetic-audit",
        "user:flynn",
        nil,
        %{},
        {:user, "flynn"},
        fn txn ->
          DB.Txn.handoff(txn, parent, :must_rollback)
          raise "synthetic rollback"
        end
      )
    end

    assert {:ok, [[0]]} =
             DB.query(ctx.db, "SELECT COUNT(*) FROM events WHERE verb='synthetic-audit'")

    refute_receive {:"$gen_cast", :must_rollback}
  end

  test "Firehose reopening preserves an owned pending R1 reminder without false delivery", ctx do
    alias Tightbeam.ReminderDelivery

    assignment =
      handle(ctx, "assign", reopen_fixture_call({:user, "flynn"}, "pending remains owned"))

    assert {:ok, wake} =
             DB.transaction(ctx.db, fn txn ->
               ReminderDelivery.schedule_in_txn(txn, assignment.id, "prod", "holder", fn ->
                 Wakes.schedule_in_txn(txn, %{
                   session_key: "holder",
                   origin: "process:tightbeam",
                   prompt: "Synthetic pending reminder",
                   due_at: 9_000_000_000_000,
                   assignment_id: assignment.id
                 })
               end)
             end)

    assert {:ok, [[claim]]} =
             DB.query(ctx.db, "SELECT reminderState FROM assignments WHERE id=?1", [assignment.id])

    state = JSON.decode!(claim)
    assert state["pending"]["consumer"] == %{"wake" => wake.wake_id}
    assert state["claimEpoch"] == 1

    assert %{assignment: %{state: "closed"}} =
             handle(ctx, "attest", attest_call({:session, "holder"}, assignment.id, "completion"))

    assert {:ok, [[^claim]]} =
             DB.query(ctx.db, "SELECT reminderState FROM assignments WHERE id=?1", [assignment.id])

    assert %{state: "open"} =
             handle(
               ctx,
               "reopen-assignment",
               reopen_call({:user, "flynn"}, assignment.id, "resume without replay")
             )

    assert {:ok, [[^claim]]} =
             DB.query(ctx.db, "SELECT reminderState FROM assignments WHERE id=?1", [assignment.id])

    assert Wakes.get(ctx.db, wake.wake_id).state == "pending"
    assert {:ok, []} = DB.query(ctx.db, "SELECT seq FROM turns WHERE wakeId=?1", [wake.wake_id])

    assert {:ok, %{code: "reminder_pending"}} =
             DB.transaction(ctx.db, fn txn ->
               ReminderDelivery.schedule_in_txn(txn, assignment.id, "prod", "holder", fn ->
                 flunk("reopening must not create a duplicate ordinary reminder")
               end)
             end)

    assert {:ok, :no_claim} = DB.transaction(ctx.db, &ReminderDelivery.delivered_in_txn(&1, -1))

    assert {:ok, [[^claim]]} =
             DB.query(ctx.db, "SELECT reminderState FROM assignments WHERE id=?1", [assignment.id])

    refute Map.has_key?(state, "lastDeliveredAt")
    refute Map.has_key?(state, "nextEligibleAt")
  end

  test "Firehose reopening rejects a stale effort arm and rolls back its transaction", ctx do
    alias Tightbeam.EffortCheckin
    assignment = handle(ctx, "assign", reopen_fixture_call({:user, "flynn"}, "generation fence"))

    assert %{assignment: %{state: "closed"}} =
             handle(ctx, "attest", attest_call({:session, "holder"}, assignment.id, "completion"))

    config = %{db: ctx.db, base_dir: System.tmp_dir!(), effort_checkin_horizon_ms: 14_400_000}
    prepared = EffortCheckin.prepare_reopen_arm(ctx.db, config, assignment.id)
    assert prepared.prior_generation == 1

    reopened =
      handle(
        ctx,
        "reopen-assignment",
        reopen_call({:user, "flynn"}, assignment.id, "fresh generation")
      )

    assert reopened.state == "open"
    before = reopen_mutation_snapshot(ctx.db, assignment.id)

    assert {:ok, effort_before} =
             DB.query(
               ctx.db,
               "SELECT * FROM effort_checkin_generations WHERE assignmentId=?1 ORDER BY generation",
               [assignment.id]
             )

    assert {:ok, wakes_before} = DB.query(ctx.db, "SELECT * FROM wakes ORDER BY wakeId")

    assert {:error, %RuntimeError{message: "effort generation changed before reopen commit"}} =
             DB.transaction(ctx.db, fn txn ->
               DB.Txn.q(txn, "UPDATE assignments SET subject='must roll back' WHERE id=?1", [
                 assignment.id
               ])

               EffortCheckin.arm_reopened_in_txn(txn, config, reopened, prepared)
             end)

    assert reopen_mutation_snapshot(ctx.db, assignment.id) == before

    assert {:ok, ^effort_before} =
             DB.query(
               ctx.db,
               "SELECT * FROM effort_checkin_generations WHERE assignmentId=?1 ORDER BY generation",
               [assignment.id]
             )

    assert {:ok, ^wakes_before} = DB.query(ctx.db, "SELECT * FROM wakes ORDER BY wakeId")

    assert {:ok, [[subject]]} =
             DB.query(ctx.db, "SELECT subject FROM assignments WHERE id=?1", [assignment.id])

    assert subject == assignment.subject
    assert {:ok, []} = DB.query(ctx.db, "PRAGMA foreign_key_check")
  end

  test "Firehose opening publishes once and keyed Dispatch replay emits observation only", ctx do
    alias Tightbeam.Firehose.Hub
    hub = start_supervised!({Hub, name: nil})
    :ok = Hub.register(hub, self(), %{mode: :all, db: ctx.db, user_id: "flynn", is_admin: false})

    call =
      reopen_fixture_call({:user, "flynn"}, "published assignment", "publish-key")
      |> Map.put(:firehose_hub, hub)

    assert {:ok, assignment} = Dispatch.dispatch(ctx.db, ctx.handlers, call)
    assert assignment.state == "open"
    assert_receive {:firehose_notice, %{"class" => "verb.accepted"}}
    Hub.delivered(hub, self())
    assert_receive {:firehose_notice, %{"class" => "assignment.opened", "payload" => payload}}
    assert payload["id"] == assignment.id
    assert payload["state"] == "open"
    Hub.delivered(hub, self())
    assert {:ok, ^assignment} = Dispatch.dispatch(ctx.db, ctx.handlers, call)
    assert_receive {:firehose_notice, %{"class" => "verb.accepted"}}
    Hub.delivered(hub, self())
    refute_receive {:firehose_notice, _}

    assert {:ok, [[1]]} =
             DB.query(ctx.db, "SELECT COUNT(*) FROM assignments WHERE id=?1", [assignment.id])

    assert {:ok, [[2]]} =
             DB.query(ctx.db, "SELECT COUNT(*) FROM events WHERE verb='assign' AND kind='verb'")

    assert {:ok, [[1]]} =
             DB.query(
               ctx.db,
               "SELECT COUNT(*) FROM effort_checkin_generations WHERE assignmentId=?1",
               [assignment.id]
             )
  end

  test "Firehose terminal attest keeps sixteen-field replay and publishes no duplicate close",
       ctx do
    alias Tightbeam.Firehose.Hub

    assignment =
      handle(ctx, "assign", reopen_fixture_call({:user, "flynn"}, "terminal publication"))

    hub = start_supervised!({Hub, name: nil})
    :ok = Hub.register(hub, self(), %{mode: :all, db: ctx.db, user_id: "flynn", is_admin: false})

    call =
      attest_call({:session, "holder"}, assignment.id, "surrender")
      |> Map.merge(%{terminal_surrender: true, firehose_hub: hub})

    assert {:ok, result} = Dispatch.dispatch(ctx.db, ctx.handlers, call)
    assert result.assignment.outcome == "surrendered"
    assert result.attest.kind == "surrender"

    for key <- [:artifactId, :contentSha256, :waitId] do
      assert Map.has_key?(result.attest, key)
      assert result.attest[key] == nil
    end

    assert_receive {:firehose_notice, %{"class" => "verb.accepted"}}
    Hub.delivered(hub, self())
    assert_receive {:firehose_notice, %{"class" => "attest.filed", "payload" => attest}}
    assert attest["id"] == result.attest.id
    Hub.delivered(hub, self())
    assert_receive {:firehose_notice, %{"class" => "assignment.closed", "payload" => closed}}
    assert closed["id"] == assignment.id
    assert closed["outcome"] == "surrendered"
    Hub.delivered(hub, self())

    assert {:ok, replay} = Dispatch.dispatch(ctx.db, ctx.handlers, call)
    assert replay.replayed
    assert replay.attest == result.attest
    assert replay.assignment == result.assignment
    assert_receive {:firehose_notice, %{"class" => "verb.accepted"}}
    Hub.delivered(hub, self())
    refute_receive {:firehose_notice, _}

    # The same closed-read branch is reached when the precheck loses a race.
    raced = handle(ctx, "attest", Map.put(call, :firehose_in_txn, true))
    assert raced.replayed
    assert raced.attest == result.attest
    assert_receive {:firehose_notice, %{"class" => "verb.accepted"}}
    Hub.delivered(hub, self())
    refute_receive {:firehose_notice, _}

    assert {:ok, [[1]]} =
             DB.query(ctx.db, "SELECT COUNT(*) FROM attests WHERE assignmentId=?1", [
               assignment.id
             ])

    assert {:ok, []} = DB.query(ctx.db, "PRAGMA foreign_key_check")
  end

  # Exercise the assignment callback and its real second-transaction row
  # recognition. Org.retire alone does not run Gateway's assignment cascade.
  defp retirement_callback(db, actor) do
    {:ok, retired} =
      DB.transaction_then(
        db,
        fn txn ->
          retired = Assignments.interrupt_for_retire_in_txn(txn, "holder", "flynn", actor)
          {retired, DB.take_row_commits(txn)}
        end,
        fn txn, {retired, transitions} ->
          assert length(transitions) == length(retired)
          Wakes.row_commit_in_txn(txn, transitions)
          retired
        end
      )

    retired
  end

  @tag assignment_delta: true
  test "reopen accepts all lawful close outcomes and keeps file declarations advisory", ctx do
    surrendered = handle(ctx, "assign", reopen_fixture_call({:user, "flynn"}, "surrender repair"))
    _ = handle(ctx, "attest", attest_call({:session, "holder"}, surrendered.id, "surrender"))

    assert %{state: "open"} =
             handle(
               ctx,
               "reopen-assignment",
               reopen_call({:session, "holder"}, surrendered.id, "the surrender was premature")
             )

    revoked = handle(ctx, "assign", reopen_fixture_call({:user, "flynn"}, "revocation repair"))
    _ = handle(ctx, "revoke-assignment", revoke_call({:user, "flynn"}, revoked.id))

    assert %{state: "open"} =
             handle(
               ctx,
               "reopen-assignment",
               reopen_call({:user, "flynn"}, revoked.id, "the revocation was mistaken")
             )

    assert {:ok, [["surrendered"], ["revoked"]]} =
             DB.query(
               ctx.db,
               "SELECT priorOutcome FROM assignment_reopenings WHERE assignmentId IN (?1,?2) ORDER BY id",
               [surrendered.id, revoked.id]
             )

    first =
      reopen_fixture_call({:user, "flynn"}, "first file card")
      |> put_in([:params, :files], ["lib/tightbeam/assignments.ex"])
      |> then(&handle(ctx, "assign", &1))

    _ = handle(ctx, "attest", attest_call({:session, "holder"}, first.id, "completion"))

    second =
      reopen_fixture_call({:user, "flynn"}, "second file card")
      |> put_in([:params, :files], ["lib/tightbeam/assignments.ex"])
      |> then(&handle(ctx, "assign", &1))

    assert %{state: "open"} =
             handle(
               ctx,
               "reopen-assignment",
               reopen_call({:user, "flynn"}, first.id, "resume both lanes")
             )

    assert Assignments.open_assignments_touching(ctx.db, ["lib/tightbeam/assignments.ex"]) ==
             Enum.sort([first.id, second.id])
  end

  @tag assignment_delta: true
  test "reopen validates close shape and rolls back a post-audit failure", ctx do
    malformed = handle(ctx, "assign", reopen_fixture_call({:user, "flynn"}, "malformed close"))
    _ = handle(ctx, "attest", attest_call({:session, "holder"}, malformed.id, "completion"))

    assert :ok = DB.execute(ctx.db, "PRAGMA ignore_check_constraints=ON")

    assert {:ok, _} =
             DB.query(ctx.db, "UPDATE assignments SET closedAt=NULL WHERE id=?1", [malformed.id])

    assert :ok = DB.execute(ctx.db, "PRAGMA ignore_check_constraints=OFF")

    assert_reopen_refused!(
      ctx,
      {:user, "flynn"},
      malformed.id,
      "do not infer the close",
      "unexpected_assignment_shape"
    )

    rollback =
      handle(ctx, "assign", reopen_fixture_call({:user, "flynn"}, "transaction rollback"))

    _ = handle(ctx, "attest", attest_call({:session, "holder"}, rollback.id, "completion"))

    {:ok, _} =
      DB.query(
        ctx.db,
        """
        INSERT INTO supervision_entitlements
          (assignmentId,generation,dueAt,state,basisKind,basisId,cause,principal,
           supervisionIntervalMs)
        VALUES (?1,1,0,'armed','assignment_open',?1,'assignment_open','process:test',1000)
        """,
        [rollback.id]
      )

    before = reopen_mutation_snapshot(ctx.db, rollback.id)

    assert_raise RuntimeError, ~r/invalid supervision transition result/, fn ->
      handle(
        ctx,
        "reopen-assignment",
        reopen_call({:user, "flynn"}, rollback.id, "force a later transactional failure")
      )
    end

    assert reopen_mutation_snapshot(ctx.db, rollback.id) == before
  end

  @tag assignment_delta: true
  test "public revoke cannot claim the internal recovery process", ctx do
    assignment = handle(ctx, "assign", assign_call({:user, "flynn"}, "process spoof"))

    assert %{code: "process_denied"} =
             handle(ctx, "revoke-assignment", revoke_call({:process, "tightbeam"}, assignment.id))

    assert {:ok, [["open", nil, nil, nil]]} =
             DB.query(
               ctx.db,
               "SELECT state,closedByUser,closedBySession,closedByProcess FROM assignments WHERE id=?1",
               [assignment.id]
             )

    assert {:ok, [[0]]} =
             DB.query(
               ctx.db,
               "SELECT count(*) FROM assignment_revocations WHERE assignmentId=?1",
               [assignment.id]
             )
  end

  @tag assignment_delta: true
  test "revocation requires one durable bounded reason and projects its provenance", ctx do
    assignment = handle(ctx, "assign", assign_call({:user, "flynn"}, "reason required"))

    for params <- [
          %{assignment_id: assignment.id},
          %{assignment_id: assignment.id, reason: "   "},
          %{assignment_id: assignment.id, reason: "\t"},
          %{assignment_id: assignment.id, reason: "\u00A0"},
          %{assignment_id: assignment.id, reason: "\u3000"},
          %{assignment_id: assignment.id, reason: String.duplicate("x", 2001)},
          %{assignment_id: assignment.id, reason: 7}
        ] do
      assert %{code: code} =
               handle(
                 ctx,
                 "revoke-assignment",
                 call("revoke-assignment", {:user, "flynn"}, nil, params)
               )

      assert code in ["missing_reason", "invalid_reason"]
    end

    assert %{state: "open", revocationReason: nil} =
             handle(ctx, "assignment-get", assignment_get_call({:user, "flynn"}, assignment.id))

    assert {:ok, [[0]]} =
             DB.query(
               ctx.db,
               "SELECT count(*) FROM assignment_revocations WHERE assignmentId = ?1",
               [
                 assignment.id
               ]
             )

    for {reason, suffix} <- [{"\t", "tab"}, {"\u00A0", "nbsp"}, {"\u3000", "ideographic"}] do
      assert {:error, _} =
               DB.query(
                 ctx.db,
                 """
                 INSERT INTO assignment_revocations
                   (id, assignmentId, revokedAt, revokedByUser, revokedBySession, reason)
                 VALUES (?1, ?2, 1, 'flynn', NULL, ?3)
                 """,
                 ["revocation-whitespace-#{suffix}", assignment.id, reason]
               )
    end

    revoked =
      handle(
        ctx,
        "revoke-assignment",
        call("revoke-assignment", {:user, "flynn"}, nil, %{
          assignment_id: assignment.id,
          reason: "the work moved to its replacement"
        })
      )

    assert revoked.revocationReason == "the work moved to its replacement"
    assert revoked.closedByUser == "flynn"

    assert %{revocationReason: "the work moved to its replacement"} =
             handle(ctx, "assignment-get", assignment_get_call({:user, "flynn"}, assignment.id))

    assert %{
             "class" => "assignment.closed",
             "payload" => %{"revocationReason" => "the work moved to its replacement"}
           } =
             Tightbeam.Firehose.Publisher.state_notice(
               ctx.db,
               call("revoke-assignment", {:user, "flynn"}, nil, %{assignment_id: assignment.id}),
               revoked
             )

    assert {:ok, [["flynn", nil, closed_at, "the work moved to its replacement"]]} =
             DB.query(
               ctx.db,
               "SELECT revokedByUser, revokedBySession, revokedAt, reason FROM assignment_revocations WHERE assignmentId = ?1",
               [assignment.id]
             )

    assert closed_at == revoked.closedAt

    replayed =
      handle(
        ctx,
        "revoke-assignment",
        call("revoke-assignment", {:user, "flynn"}, nil, %{
          assignment_id: assignment.id,
          reason: "the work moved to its replacement"
        })
      )

    assert replayed.id == assignment.id
    assert replayed.revocationReason == "the work moved to its replacement"

    admin_revoked = handle(ctx, "assign", assign_call({:user, "flynn"}, "admin revocation"))

    assert %{closedByUser: "admin"} =
             handle(
               ctx,
               "revoke-assignment",
               revoke_call({:user, "admin"}, admin_revoked.id)
             )

    assert %{code: "assignment_closed"} =
             handle(
               ctx,
               "revoke-assignment",
               revoke_call({:user, "flynn"}, admin_revoked.id)
             )

    assert %{code: "assignment_closed"} =
             handle(
               ctx,
               "revoke-assignment",
               call("revoke-assignment", {:user, "flynn"}, nil, %{
                 assignment_id: assignment.id,
                 reason: "a conflicting reason"
               })
             )

    assert {:ok, [[1]]} =
             DB.query(
               ctx.db,
               "SELECT count(*) FROM assignment_revocations WHERE assignmentId = ?1",
               [
                 assignment.id
               ]
             )
  end

  @tag assignment_delta: true
  test "revocation reason binds the current reopening and refuses immutable edits", ctx do
    assignment = handle(ctx, "assign", assign_call({:user, "flynn"}, "generation reason"))

    first_call =
      put_in(revoke_call({:user, "flynn"}, assignment.id), [:params, :reason], "first close")

    first = handle(ctx, "revoke-assignment", first_call)
    assert first.revocationReason == "first close"
    assert handle(ctx, "revoke-assignment", first_call) == first

    assert %{code: "assignment_closed"} =
             handle(ctx, "revoke-assignment", put_in(first_call, [:params, :reason], "conflict"))

    reopened =
      handle(
        ctx,
        "reopen-assignment",
        reopen_call({:user, "flynn"}, assignment.id, "new generation")
      )

    assert reopened.revocationReason == nil

    second =
      handle(ctx, "revoke-assignment", put_in(first_call, [:params, :reason], "second close"))

    assert second.revocationReason == "second close"

    assert {:ok, [["first close", nil], ["second close", reopening_id]]} =
             DB.query(
               ctx.db,
               "SELECT r.reason, g.reopeningId FROM assignment_revocations r JOIN assignment_revocation_generations g ON g.revocationId=r.id WHERE r.assignmentId=?1 ORDER BY g.reopeningId",
               [assignment.id]
             )

    assert is_integer(reopening_id)

    assert {:error, _} =
             DB.query(
               ctx.db,
               "UPDATE assignment_revocations SET reason='changed' WHERE assignmentId=?1",
               [assignment.id]
             )

    assert {:error, _} =
             DB.query(
               ctx.db,
               "DELETE FROM assignment_revocation_generations WHERE assignmentId=?1",
               [assignment.id]
             )

    assert handle(ctx, "assignment-get", assignment_get_call({:user, "flynn"}, assignment.id)).revocationReason ==
             "second close"
  end

  @tag assignment_delta: true
  test "retirement records its actual actor and rolls back provenance with the close", ctx do
    assignment = handle(ctx, "assign", assign_call({:user, "flynn"}, "retirement provenance"))

    retire = fn txn ->
      Assignments.interrupt_for_retire_in_txn(txn, "holder", "flynn", "user:flynn")
      Org.retire_in_txn(txn, "holder", "user:flynn", 1_000)
    end

    assert {:error, %RuntimeError{message: "retirement rollback"}} =
             DB.transaction(ctx.db, fn txn ->
               retire.(txn)
               raise "retirement rollback"
             end)

    assert %{state: "open", revocationReason: nil} =
             handle(ctx, "assignment-get", assignment_get_call({:user, "flynn"}, assignment.id))

    assert {:ok, [[0]]} = DB.query(ctx.db, "SELECT count(*) FROM assignment_revocations")

    assert {:ok, [[0]]} =
             DB.query(ctx.db, "SELECT count(*) FROM assignment_revocation_generations")

    assert {:ok, %{state: "retired"}} = DB.transaction(ctx.db, retire)
    closed = handle(ctx, "assignment-get", assignment_get_call({:user, "flynn"}, assignment.id))
    assert closed.outcome == "revoked"
    assert closed.revocationReason == "holder session retired"
    assert closed.closedByUser == "flynn"
    assert closed.closedBySession == nil
    assert {:ok, %{state: "retired"}} = DB.transaction(ctx.db, retire)

    assert handle(ctx, "assignment-get", assignment_get_call({:user, "flynn"}, assignment.id)) ==
             closed

    assert {:ok, [[1]]} = DB.query(ctx.db, "SELECT count(*) FROM assignment_revocations")

    assert {:ok, [[1]]} =
             DB.query(ctx.db, "SELECT count(*) FROM assignment_revocation_generations")
  end

  @tag assignment_delta: true
  test "internal process close rolls back and survives reopening without actor substitution",
       ctx do
    assignment = handle(ctx, "assign", assign_call({:user, "flynn"}, "process generation"))

    close = fn txn ->
      Assignments.interrupt_for_retire_in_txn(txn, "holder", "flynn", "process:tightbeam")
    end

    assert {:error, %RuntimeError{message: "process rollback"}} =
             DB.transaction(ctx.db, fn txn ->
               close.(txn)
               raise "process rollback"
             end)

    assert %{state: "open", closedByProcess: nil} =
             handle(ctx, "assignment-get", assignment_get_call({:user, "flynn"}, assignment.id))

    assert {:ok, [[0]]} = DB.query(ctx.db, "SELECT count(*) FROM assignment_revocations")

    assert {:ok, [[0]]} =
             DB.query(ctx.db, "SELECT count(*) FROM assignment_revocation_generations")

    assert {:ok, [[0]]} = DB.query(ctx.db, "SELECT count(*) FROM assignment_interruptions")

    assert {:ok, [_]} = DB.transaction(ctx.db, close)
    closed = handle(ctx, "assignment-get", assignment_get_call({:user, "flynn"}, assignment.id))
    assert closed.closedByUser == nil
    assert closed.closedBySession == nil
    assert closed.closedByProcess == "process:tightbeam"
    assert {:ok, []} = DB.transaction(ctx.db, close)

    assert %{state: "open", closedByProcess: nil, revocationReason: nil} =
             handle(
               ctx,
               "reopen-assignment",
               reopen_call({:user, "flynn"}, assignment.id, "resume")
             )

    reopened = handle(ctx, "assignment-get", assignment_get_call({:user, "flynn"}, assignment.id))
    assert [audit] = reopened.reopenings
    assert audit.priorClosedByProcess == "process:tightbeam"
    assert audit.priorClosedByUser == nil
    assert audit.priorClosedBySession == nil
    assert audit.priorClosedAt == closed.closedAt

    # The old process receipt cannot authorize a close in the new generation.
    assert {:error, %DB.Error{}} =
             DB.query(
               ctx.db,
               "UPDATE assignments SET state='closed',outcome='revoked',closedAt=?2,closedByProcess='process:tightbeam' WHERE id=?1",
               [assignment.id, closed.closedAt]
             )

    next = handle(ctx, "revoke-assignment", revoke_call({:user, "flynn"}, assignment.id))
    assert next.closedByUser == "flynn"
    assert next.closedByProcess == nil

    assert {:ok, [[nil, "process:tightbeam"], ["flynn", nil]]} =
             DB.query(
               ctx.db,
               "SELECT r.revokedByUser,r.revokedByProcess FROM assignment_revocations r JOIN assignment_revocation_generations g ON g.revocationId=r.id WHERE r.assignmentId=?1 ORDER BY g.reopeningId",
               [assignment.id]
             )
  end

  @tag assignment_delta: true
  test "schema pins every assignment consistency CHECK", %{db: db} do
    base =
      "INSERT INTO assignments (id, subject, holderKey, holderRole, holderFallback, openedByUser, openedBySession, openedAt, state, outcome, closedAt, closedByUser, closedBySession, closingAttestId) VALUES "

    invalid = [
      "('a1','x','holder',NULL,1,'flynn',NULL,1,'open',NULL,NULL,NULL,NULL,NULL)",
      "('a2','x','holder',NULL,0,NULL,NULL,1,'open',NULL,NULL,NULL,NULL,NULL)",
      "('a3','x','holder',NULL,0,'flynn','holder',1,'open',NULL,NULL,NULL,NULL,NULL)",
      "('a4','x','holder',NULL,0,'flynn',NULL,1,'open','revoked',NULL,NULL,NULL,NULL)",
      "('a5','x','holder',NULL,0,'flynn',NULL,1,'closed',NULL,2,'flynn',NULL,NULL)",
      "('a6','x','holder',NULL,0,'flynn',NULL,1,'closed','revoked',NULL,'flynn',NULL,NULL)",
      "('a7','x','holder',NULL,0,'flynn',NULL,1,'closed','revoked',2,NULL,NULL,NULL)",
      "('a8','x','holder',NULL,0,'flynn',NULL,1,'closed','revoked',2,'flynn','holder',NULL)",
      "('a9','x','holder',NULL,0,'flynn',NULL,1,'closed','completed',2,'flynn',NULL,NULL)"
    ]

    assert {:ok, [[assignment_ddl]]} =
             DB.query(
               db,
               "SELECT sql FROM sqlite_master WHERE type='table' AND name='assignments'"
             )

    # Exercise the installed table's CHECKs independently of BEFORE triggers.
    # The real assignments table and every production guard remain untouched.
    check_ddl =
      String.replace(
        assignment_ddl,
        "CREATE TABLE assignments",
        "CREATE TABLE assignment_check_probe",
        global: false
      )

    assert check_ddl != assignment_ddl
    assert :ok = DB.execute(db, check_ddl)

    check_base =
      String.replace(base, "INSERT INTO assignments", "INSERT INTO assignment_check_probe",
        global: false
      )

    Enum.each(invalid, fn values ->
      assert {:error, %DB.Error{message: message}} = DB.query(db, base <> values)

      if String.contains?(values, "'closed','revoked'"),
        do: assert(message == "revoked assignment requires revocation provenance"),
        else: assert(message =~ "CHECK constraint")

      assert {:error, %DB.Error{message: check_message}} = DB.query(db, check_base <> values)
      assert check_message =~ "CHECK constraint"
    end)

    assert {:error, %DB.Error{}} =
             DB.query(
               db,
               "INSERT INTO attests (id, assignmentId, kind, note, bySession, ts) VALUES ('bad','missing','verdict',NULL,'holder',1)"
             )
  end

  test "assignment text limits are fixed by the specs, not application config", ctx do
    old_values =
      for key <- [:max_subject_len, :max_note_len, :max_verdict_kind_len, :max_idem_key_len],
          into: %{} do
        {key, Application.get_env(:tightbeam, key)}
      end

    on_exit(fn ->
      Enum.each(old_values, fn
        {key, nil} -> Application.delete_env(:tightbeam, key)
        {key, value} -> Application.put_env(:tightbeam, key, value)
      end)
    end)

    Application.put_env(:tightbeam, :max_subject_len, 3)
    Application.put_env(:tightbeam, :max_note_len, 3)
    Application.put_env(:tightbeam, :max_verdict_kind_len, 3)
    Application.put_env(:tightbeam, :max_idem_key_len, 3)

    assignment = handle(ctx, "assign", assign_call({:user, "flynn"}, "four", "four"))
    assert assignment.subject == "four"

    progress =
      attest_call({:session, "holder"}, assignment.id, "progress")
      |> put_in([:params, :note], "four")
      |> then(&handle(ctx, "attest", &1))

    assert progress.attest.note == "four"

    verdict =
      attest_call({:user, "flynn"}, assignment.id, "verdict")
      |> put_in([:params, :verdict_kind], "four")
      |> then(&handle(ctx, "attest", &1))

    assert verdict.attest.verdictKind == "four"

    assert %{code: "invalid_subject"} =
             handle(
               ctx,
               "assign",
               assign_call({:user, "flynn"}, String.duplicate(" ", 2000) <> "x")
             )

    assert %{code: "invalid_note"} =
             attest_call({:session, "holder"}, assignment.id, "progress")
             |> put_in([:params, :note], String.duplicate("x", 2001))
             |> then(&handle(ctx, "attest", &1))

    assert %{code: "invalid_verdict_kind"} =
             attest_call({:user, "flynn"}, assignment.id, "verdict")
             |> put_in([:params, :verdict_kind], String.duplicate("x", 65))
             |> then(&handle(ctx, "attest", &1))
  end

  test "assign validates principals, input, liveness, opener typing, and idempotent races", ctx do
    assert %{code: "process_denied"} = handle(ctx, "assign", assign_call({:process, "cron"}))
    assert %{code: "principal_required"} = handle(ctx, "assign", assign_call(nil))
    assert %{code: "invalid_subject"} = handle(ctx, "assign", assign_call({:user, "flynn"}, " "))

    assert %{code: "invalid_subject"} =
             handle(ctx, "assign", assign_call({:user, "flynn"}, String.duplicate("x", 2001)))

    assert %{code: "invalid_idempotency_key"} =
             handle(ctx, "assign", assign_call({:user, "flynn"}, "x", " "))

    assert %{code: "invalid_idempotency_key"} =
             handle(
               ctx,
               "assign",
               assign_call({:user, "flynn"}, "x", String.duplicate("k", 201))
             )

    baseline = assignment_count(ctx.db)

    for interval <- [nil, 0, -1] do
      call =
        Map.put(assign_call({:user, "flynn"}, "no interval"), :supervision_interval_ms, interval)

      assert %{code: "invalid_supervision_interval"} =
               Assignments.__handle__(ctx.db, "assign", call)
    end

    assert assignment_count(ctx.db) == baseline

    user_opened = handle(ctx, "assign", assign_call({:user, "flynn"}, "user work"))
    assert user_opened.openedByUser == "flynn"
    assert user_opened.openedBySession == nil
    assert user_opened.workItemId == nil

    assert {:ok,
            [
              [
                1,
                due_at,
                "armed",
                "assignment_open",
                user_assignment_id,
                "assignment_open",
                "user:flynn",
                1_000
              ]
            ]} =
             DB.query(
               ctx.db,
               "SELECT generation,dueAt,state,basisKind,basisId,cause,principal,supervisionIntervalMs FROM supervision_entitlements WHERE assignmentId=?1",
               [user_opened.id]
             )

    assert user_assignment_id == user_opened.id
    assert due_at == user_opened.openedAt + 1_000

    session_opened = handle(ctx, "assign", assign_call({:session, "holder"}, "session work"))
    assert session_opened.openedBySession == "holder"
    assert session_opened.openedByUser == nil

    role_call =
      assign_call({:user, "flynn"}, "role work")
      |> Map.merge(%{target_role: "builder", role_fallback: true})

    role_opened = handle(ctx, "assign", role_call)
    assert role_opened.holderRole == "builder"
    assert role_opened.holderFallback

    Org.retire(ctx.db, "other-session", "user:other", 1_000)

    assert %{code: "session_retired"} =
             handle(ctx, "assign", %{assign_call({:user, "flynn"}) | session_key: "other-session"})

    call = assign_call({:user, "flynn"}, "once", "same-key")
    tasks = for _ <- 1..2, do: Task.async(fn -> handle(ctx, "assign", call) end)
    [one, two] = Task.await_many(tasks)
    assert one.id == two.id

    assert {:ok, [[1]]} =
             DB.query(ctx.db, "SELECT count(*) FROM assignments WHERE subject = 'once'")
  end

  test "raw dispatch precheck leaves supervision interval validation to the mutation seam", ctx do
    baseline = assignment_count(ctx.db)

    raw_call =
      assign_call({:user, "flynn"}, "Gateway will attach interval")
      |> Map.delete(:supervision_interval_ms)

    assert :proceed = Assignments.dispatch_precheck(ctx.db, raw_call)

    for invalid <- [nil, 0, -1, "1000"] do
      assert :proceed =
               Assignments.dispatch_precheck(
                 ctx.db,
                 Map.put(raw_call, :supervision_interval_ms, invalid)
               )
    end

    assert assignment_count(ctx.db) == baseline

    assert %{code: "invalid_supervision_interval"} =
             Assignments.__handle__(ctx.db, "assign", raw_call)
  end

  test "same-assignment public cancellation and progress do not re-drive a forced due entitlement",
       ctx do
    assignment = handle(ctx, "assign", assign_call({:user, "flynn"}, "liveness re-drive"))

    canceled =
      Wakes.schedule(ctx.db, %{
        session_key: "holder",
        origin: "agent:holder",
        prompt: "withdraw this reminder",
        due_at: 9_000_000_000_000,
        assignment_id: assignment.id
      })

    assert {:ok, {:accepted_in_txn, event_id, %{canceled: true}}} =
             DB.transaction(ctx.db, fn txn ->
               Wakes.cancel_in_txn(txn, %{
                 wake_id: canceled.wake_id,
                 expected_origin: "agent:holder",
                 requester: %{kind: "session", id: "holder"},
                 reason_kind: "requester_withdrew",
                 causal_source: %{
                   kind: "verb_call",
                   accepted_event: %{
                     origin: "agent:holder",
                     session_key: "holder",
                     principal: {:session, "holder"}
                   }
                 },
                 outcome: %{
                   kind: "no_replacement",
                   liveness_trigger: %{
                     kind: "supervision_entitlement",
                     id: "#{assignment.id}#1"
                   }
                 }
               })
             end)

    assert is_integer(event_id)
    assert Wakes.get(ctx.db, canceled.wake_id).state == "canceled"

    {:ok, turn_seq} =
      Ledger.enqueue(ctx.db, %{
        session_key: "holder",
        message_id: "m_liveness_re_drive",
        origin: "user:flynn",
        prompt: "finish the assignment",
        assignment_id: assignment.id
      })

    assert {:ok, %{seq: ^turn_seq}} = Ledger.claim_next(ctx.db, "holder", "test")
    assert :ok = Ledger.finish(ctx.db, turn_seq, "delivered")

    liveness = start_liveness!(ctx)

    _first = handle(ctx, "attest", attest_call({:session, "holder"}, assignment.id, "progress"))
    sweep_liveness!(liveness)

    assert %{
             supervisionGeneration: 1,
             supervisionBasisKind: "assignment_open",
             supervisionBasisId: assignment_id
           } = Supervision.prod_state(ctx.db, assignment.id)

    assert assignment_id == assignment.id

    _second = handle(ctx, "attest", attest_call({:session, "holder"}, assignment.id, "progress"))
    sweep_liveness!(liveness)

    assert %{
             supervisionGeneration: 1,
             supervisionBasisKind: "assignment_open",
             supervisionBasisId: ^assignment_id
           } = Supervision.prod_state(ctx.db, assignment.id)

    assert {:ok, _} =
             DB.query(
               ctx.db,
               "UPDATE supervision_entitlements SET dueAt=0 WHERE assignmentId=?1",
               [assignment.id]
             )

    sweep_liveness!(liveness)

    assert [%{assignment_id: assignment_id, origin: "process:tightbeam", state: "pending"}] =
             Wakes.list_pending(ctx.db)

    assert assignment_id == assignment.id
  end

  test "dispatch atomically opens an assignment and enqueues its brief with the card id", ctx do
    work_item =
      handle(
        ctx,
        "work-item-create",
        work_item_call("work-item-create", {:user, "flynn"}, %{title: "Dispatch trace"})
      )

    assignment =
      handle(
        ctx,
        "dispatch",
        dispatch_call({:user, "flynn"}, "ship it", "Please ship it.", nil, work_item.id)
      )

    assert assignment.subject == "ship it"
    assert assignment.holderKey == "holder"

    assert {:ok, [[prompt, assignment_id, job_ref]]} =
             DB.query(
               ctx.db,
               "SELECT prompt, assignmentId, jobRef FROM turns WHERE sessionKey = 'holder'"
             )

    assert prompt =~ assignment.id
    assert prompt =~ "Please ship it."
    assert assignment_id == assignment.id
    assert job_ref == work_item.id

    assert {:ok, [[1]]} =
             DB.query(ctx.db, "SELECT count(*) FROM assignments WHERE id = ?1", [assignment.id])
  end

  test "linked dispatch ruminates first, then atomically assigns and wakes, linking the work item",
       ctx do
    work_item =
      handle(
        ctx,
        "work-item-create",
        work_item_call("work-item-create", {:user, "flynn"}, %{title: "Rumination rail"})
      )

    call =
      dispatch_call(
        {:session, "other-session"},
        "ship the rail",
        "Implement the ratified behavior",
        nil,
        work_item.id
      )

    assert {:ok,
            %{
              rumination_required: true,
              work_item_id: work_item_id,
              message: message
            }} = Dispatch.dispatch(ctx.db, ctx.handlers, call)

    assert work_item_id == work_item.id

    assert message ==
             "Sent you to ruminate on #{work_item.id} first — re-dispatch when you're done thinking."

    assert {:ok, [[0]]} =
             DB.query(ctx.db, "SELECT count(*) FROM assignments WHERE subject = 'ship the rail'")

    # Two wakes are pending: the bracket-1 routing nag armed at create (on the
    # owner's personal session) and the rumination wake on the dispatcher.
    pending = Wakes.list_pending(ctx.db)
    wake = Enum.find(pending, & &1.rumination)
    assert wake

    assert Enum.any?(pending, fn w ->
             not w.rumination and w.work_item_id == work_item.id and
               w.session_key == Org.personal_session_key("flynn")
           end)

    assert wake.session_key == "other-session"
    assert wake.creator_session_key == "other-session"
    assert wake.origin == "agent:other-session"
    assert wake.rumination
    assert wake.work_item_id == work_item.id

    assert wake.prompt ==
             "digest: Ruminate on work-item #{work_item.id} against the whole spec and its spirit before you fan out. Intent you were about to dispatch: subject=ship the rail brief=Implement the ratified behavior. When you've thought it through, re-issue the dispatch."

    scheduler = :"rumination_wake_#{System.unique_integer([:positive])}"
    test_pid = self()

    start_supervised!(
      {Wakes,
       db: ctx.db,
       name: scheduler,
       tick_ms: 60_000,
       deliver: fn delivered -> send(test_pid, {:rumination_delivered, delivered}) end}
    )

    assert :ok = Wakes.fire_due(scheduler)
    assert_receive {:rumination_delivered, %{wake_id: wake_id}}
    assert wake_id == wake.wake_id
    assert Wakes.rumination_exists?(ctx.db, work_item.id, "other-session")

    # F7 amendment: the re-dispatch persists workItemId exactly as assign does.
    assert {:ok, assignment} = Dispatch.dispatch(ctx.db, ctx.handlers, call)
    assert assignment.workItemId == work_item.id
    assert assignment.openedBySession == "other-session"

    assert {:ok, [[1]]} =
             DB.query(
               ctx.db,
               "SELECT count(*) FROM assignments WHERE id = ?1 AND workItemId = ?2",
               [assignment.id, work_item.id]
             )

    assert {:ok, [[prompt]]} =
             DB.query(ctx.db, "SELECT prompt FROM turns WHERE sessionKey = 'holder'")

    assert prompt =~ assignment.id
    assert prompt =~ "Implement the ratified behavior"

    user_dispatch =
      handle(
        ctx,
        "dispatch",
        dispatch_call(
          {:user, "flynn"},
          "user dispatch",
          "Dispatch immediately.",
          nil,
          work_item.id
        )
      )

    assert user_dispatch.workItemId == work_item.id

    assert {:ok, [[1]]} =
             DB.query(
               ctx.db,
               "SELECT count(*) FROM assignments WHERE id = ?1 AND workItemId = ?2",
               [user_dispatch.id, work_item.id]
             )

    unlinked =
      handle(
        ctx,
        "dispatch",
        dispatch_call({:session, "other-session"}, "unlinked", "Dispatch immediately.")
      )

    assert unlinked.subject == "unlinked"

    assigned =
      handle(
        ctx,
        "assign",
        assign_call({:session, "other-session"}, "bookkeeping", nil, work_item.id)
      )

    assert assigned.workItemId == work_item.id

    assert {:ok, [[1]]} =
             DB.query(
               ctx.db,
               "SELECT count(*) FROM assignments WHERE id = ?1 AND workItemId = ?2",
               [assigned.id, work_item.id]
             )
  end

  test "review and file declarations are assign-only inputs", ctx do
    reviewed = handle(ctx, "assign", assign_call({:user, "flynn"}, "reviewed"))

    call =
      dispatch_call({:user, "flynn"}, "dispatch", "Do the work.")
      |> put_in([:params, :reviews_assignment_id], reviewed.id)
      |> put_in([:params, :files], ["lib/ignored.ex"])
      |> Map.put(:on_work_item_change, fn _, _ -> send(self(), :work_item_change) end)

    dispatched = handle(ctx, "dispatch", call)
    assert dispatched.reviewsAssignmentId == nil
    assert Assignments.declared_files(ctx.db, dispatched.id) == []
    refute_received :work_item_change
  end

  test "dispatch rolls back the assignment when prompt enqueue fails", ctx do
    assert {:ok, _} = DB.query(ctx.db, "DROP TABLE turns")

    assert {:error, %{code: "server_error", message: message}} =
             Dispatch.dispatch(
               ctx.db,
               ctx.handlers,
               dispatch_call({:user, "flynn"}, "rollback", "Wake now.")
             )

    assert message =~ "no such table: turns"

    assert {:ok, [[0]]} =
             DB.query(ctx.db, "SELECT count(*) FROM assignments WHERE subject = 'rollback'")

    assert {:ok, [[0]]} =
             DB.query(ctx.db, "SELECT count(*) FROM messages WHERE content LIKE '%Wake now.%'")
  end

  test "dispatch rejects disallowed principals exactly as assign does", ctx do
    for principal <- [{:process, "cron"}, nil] do
      assign_error = handle(ctx, "assign", assign_call(principal, "work"))
      dispatch_error = handle(ctx, "dispatch", dispatch_call(principal, "work", "Do work."))
      assert dispatch_error == assign_error
    end
  end

  @tag assignment_delta: true
  test "assignment-get returns the full assignment row plus reopening history or not_found",
       ctx do
    assignment = handle(ctx, "assign", assign_call({:user, "flynn"}, "fetch me"))

    assert handle(
             ctx,
             "assignment-get",
             assignment_get_call({:session, "other-session"}, assignment.id)
           ) ==
             Map.put(assignment, :reopenings, [])

    assert handle(
             ctx,
             "assignment-get",
             assignment_get_call({:session, "other-session"}, "asg_missing")
           ) == %{code: "not_found", message: "unknown assignment: asg_missing"}
  end

  test "work-item links validate on create but idempotent replay returns the original link",
       ctx do
    first =
      handle(
        ctx,
        "work-item-create",
        work_item_call("work-item-create", {:user, "flynn"}, %{title: "First"})
      )

    second =
      handle(
        ctx,
        "work-item-create",
        work_item_call("work-item-create", {:user, "flynn"}, %{title: "Second"})
      )

    linked =
      handle(ctx, "assign", assign_call({:user, "flynn"}, "linked", "work-key", first.id))

    assert linked.workItemId == first.id

    for work_item_id <- [second.id, nil, "wi_missing"] do
      replay =
        handle(ctx, "assign", assign_call({:user, "flynn"}, "ignored", "work-key", work_item_id))

      assert replay.id == linked.id
      assert replay.workItemId == first.id
    end

    assert %{code: "unknown_work_item"} =
             handle(
               ctx,
               "assign",
               assign_call({:user, "flynn"}, "not inserted", nil, "wi_missing")
             )

    assert {:ok, [[0]]} =
             DB.query(ctx.db, "SELECT count(*) FROM assignments WHERE subject = 'not inserted'")
  end

  test "assign captures review links and immutable holder family stamps", ctx do
    reviewed = handle(ctx, "assign", assign_call({:user, "flynn"}, "producer"))

    assert reviewed.reviewsAssignmentId == nil
    assert reviewed.effectKind == "code"
    assert reviewed.holderHarness == "claude"
    assert reviewed.holderProvider == "anthropic"

    {:ok, _} =
      DB.query(
        ctx.db,
        "UPDATE sessions SET harness = 'codex', provider = 'openai' WHERE sessionKey = 'holder'"
      )

    assert %{holderHarness: "claude", holderProvider: "anthropic"} =
             Assignments.list(ctx.db, %{state: "all"})
             |> Enum.find(&(&1.id == reviewed.id))

    review_call =
      assign_call({:user, "flynn"}, "review")
      |> put_in([:params, :reviews_assignment_id], reviewed.id)
      |> put_in([:params, :effect_kind], "policy")
      |> Map.put(:session_key, "other-session")

    review = handle(ctx, "assign", review_call)
    assert review.reviewsAssignmentId == reviewed.id
    assert review.effectKind == "review"
    assert review.holderHarness == "claude"
    assert review.holderProvider == "anthropic"

    unknown =
      assign_call({:user, "flynn"}, "unknown review")
      |> put_in([:params, :reviews_assignment_id], "asg_missing")

    assert %{code: "unknown_review_target"} = handle(ctx, "assign", unknown)

    assert {:ok, [[0]]} =
             DB.query(ctx.db, "SELECT count(*) FROM assignments WHERE subject = 'unknown review'")
  end

  test "assign and dispatch stamp valid effects while legacy rows resolve conservatively", ctx do
    effects =
      for kind <- ~w(code policy release live_mutation evidence review coordination), into: %{} do
        assignment =
          assign_call({:user, "flynn"}, "#{kind} effect")
          |> put_in([:params, :effect_kind], kind)
          |> then(&handle(ctx, "assign", &1))

        assert assignment.effectKind == kind
        {kind, assignment}
      end

    evidence = effects["evidence"]

    release_call =
      dispatch_call({:user, "flynn"}, "release", "ship it")
      |> put_in([:params, :effect_kind], "release")

    release = handle(ctx, "dispatch", release_call)
    assert release.effectKind == "release"

    before = assignment_count(ctx.db)

    invalid =
      assign_call({:user, "flynn"}, "invalid")
      |> put_in([:params, :effect_kind], "source")

    assert %{code: "invalid_effect_kind"} = handle(ctx, "assign", invalid)
    assert assignment_count(ctx.db) == before

    review =
      assign_call({:user, "flynn"}, "legacy review")
      |> put_in([:params, :reviews_assignment_id], evidence.id)
      |> Map.put(:session_key, "other-session")
      |> then(&handle(ctx, "assign", &1))

    {:ok, _} =
      DB.query(ctx.db, "DELETE FROM assignment_effects WHERE assignmentId IN (?1, ?2)", [
        evidence.id,
        review.id
      ])

    legacy = Assignments.list(ctx.db, %{state: "all"})
    assert Enum.find(legacy, &(&1.id == evidence.id)).effectKind == "code"
    assert Enum.find(legacy, &(&1.id == review.id)).effectKind == "review"
  end

  test "Proof 1: a conflicting review-assignment create is refused with review_item_conflict",
       ctx do
    first_item = create_work_item(ctx, "Reviewed item")
    second_item = create_work_item(ctx, "Conflicting item")

    reviewed =
      handle(ctx, "assign", assign_call({:user, "flynn"}, "reviewed", nil, first_item.id))

    conflict =
      assign_call({:user, "flynn"}, "conflicting review", nil, second_item.id)
      |> put_in([:params, :reviews_assignment_id], reviewed.id)

    assert %{
             code: "review_item_conflict",
             message: "a review assignment must belong to the item it reviews"
           } = handle(ctx, "assign", conflict)

    assert {:ok, [[0]]} =
             DB.query(
               ctx.db,
               "SELECT count(*) FROM assignments WHERE subject = 'conflicting review'"
             )
  end

  test "Proof 2: a review assignment cannot itself be reviewed",
       ctx do
    item = create_work_item(ctx, "Review boundary")
    reviewed = handle(ctx, "assign", assign_call({:user, "flynn"}, "base", nil, item.id))

    first_review =
      assign_call({:user, "flynn"}, "first review")
      |> put_in([:params, :reviews_assignment_id], reviewed.id)
      |> then(&handle(ctx, "assign", &1))

    nested_review =
      assign_call({:user, "flynn"}, "second review")
      |> put_in([:params, :reviews_assignment_id], first_review.id)
      |> then(&handle(ctx, "assign", &1))

    assert first_review.workItemId == nil
    assert Assignments.resolved_work_item_id(ctx.db, first_review.id) == item.id

    assert %{
             code: "review_of_review",
             message: "a review assignment cannot itself be reviewed"
           } = nested_review

    assert {:ok, [[0]]} =
             DB.query(ctx.db, "SELECT count(*) FROM assignments WHERE subject = 'second review'")

    trace =
      Tightbeam.WorkItems.__handle__(ctx.db, "work-item-trace", %{
        verb: "work-item-trace",
        principal: {:user, "flynn"},
        origin: "user:flynn",
        session_key: nil,
        params: %{work_item_id: item.id}
      })

    traced_ids = Enum.map(trace.assignments, & &1.id)

    assert Enum.count(traced_ids, &(&1 == first_review.id)) == 1
    assert Enum.sort(traced_ids) == Enum.sort([reviewed.id, first_review.id])
  end

  test "Proof 3: an assignment with neither key resolves to NONE", ctx do
    assignment = handle(ctx, "assign", assign_call({:user, "flynn"}, "unlinked"))

    assert assignment.workItemId == nil
    assert assignment.reviewsAssignmentId == nil
    assert Assignments.resolved_work_item_id(ctx.db, assignment.id) == nil
  end

  test "Proof 4: DIRECT consumers stay unchanged: revoke-loop membership is direct and client snapshots are byte-identical",
       ctx do
    item = create_work_item(ctx, "Direct lifecycle")
    reviewed = handle(ctx, "assign", assign_call({:user, "flynn"}, "owned", nil, item.id))

    before_get =
      handle(
        ctx,
        "work-item-get",
        work_item_call("work-item-get", {:user, "flynn"}, %{work_item_id: item.id})
      )

    before_snapshot = ctx.db |> WorkState.item_detail(item.id) |> JSON.encode!()

    review =
      assign_call({:user, "flynn"}, "story-only review")
      |> put_in([:params, :reviews_assignment_id], reviewed.id)
      |> then(&handle(ctx, "assign", &1))

    after_get =
      handle(
        ctx,
        "work-item-get",
        work_item_call("work-item-get", {:user, "flynn"}, %{work_item_id: item.id})
      )

    assert Enum.map(after_get.assignments, & &1.id) == [reviewed.id]
    refute Enum.any?(after_get.assignments, &(&1.id == review.id))
    assert after_get == before_get
    assert ctx.db |> WorkState.item_detail(item.id) |> JSON.encode!() == before_snapshot
  end

  test "declared files stay visible and overlapping assignments all open", ctx do
    paths = ["lib/a.ex", "lib/b.ex", "lib/a.ex", "../kept", "/absolute/kept"]

    first =
      assign_call({:user, "flynn"}, "files")
      |> put_in([:params, :files], paths)
      |> then(&handle(ctx, "assign", &1))

    assert Assignments.declared_files(ctx.db, first.id) ==
             Enum.sort(["lib/a.ex", "lib/b.ex", "../kept", "/absolute/kept"])

    assert Assignments.open_assignments_touching(ctx.db, ["lib/a.ex"]) == [first.id]
    assert Assignments.open_assignments_touching(ctx.db, ["lib/a.ex"], first.id) == []
    assert Assignments.open_assignments_touching(ctx.db, ["not-declared"]) == []
    assert Assignments.open_assignments_touching(ctx.db, []) == []

    overlapping =
      for {subject, declared} <- [
            {"overlap a", ["lib/a.ex"]},
            {"overlap b", ["lib/b.ex"]},
            {"overlap both", ["lib/a.ex", "lib/b.ex"]}
          ] do
        assign_call({:user, "flynn"}, subject)
        |> put_in([:params, :files], declared)
        |> then(&handle(ctx, "assign", &1))
      end

    assert Enum.all?(overlapping, &is_binary(&1.id))

    assert Enum.map(overlapping, &Assignments.declared_files(ctx.db, &1.id)) == [
             ["lib/a.ex"],
             ["lib/b.ex"],
             ["lib/a.ex", "lib/b.ex"]
           ]

    touching_a = Assignments.open_assignments_touching(ctx.db, ["lib/a.ex"])

    assert Enum.sort([first.id, Enum.at(overlapping, 0).id, Enum.at(overlapping, 2).id]) ==
             touching_a

    malformed =
      assign_call({:user, "flynn"}, "malformed")
      |> put_in([:params, :files], ["ok", " "])

    assert %{code: "invalid_files"} = handle(ctx, "assign", malformed)

    assert {:ok, [[0]]} =
             DB.query(ctx.db, "SELECT count(*) FROM assignments WHERE subject = 'malformed'")

    empty_files =
      assign_call({:user, "flynn"}, "empty files")
      |> put_in([:params, :files], [])
      |> then(&handle(ctx, "assign", &1))

    no_files = handle(ctx, "assign", assign_call({:user, "flynn"}, "no files"))
    assert Assignments.declared_files(ctx.db, empty_files.id) == []
    assert Assignments.declared_files(ctx.db, no_files.id) == []

    concurrent =
      for subject <- ["race one", "race two"] do
        Task.async(fn ->
          assign_call({:user, "flynn"}, subject)
          |> put_in([:params, :files], ["same-race-path"])
          |> then(&handle(ctx, "assign", &1))
        end)
      end
      |> Task.await_many()

    assert Enum.all?(concurrent, &is_binary(&1.id))

    assert Enum.map(concurrent, &Assignments.declared_files(ctx.db, &1.id)) == [
             ["same-race-path"],
             ["same-race-path"]
           ]

    assert Enum.sort(Enum.map(concurrent, & &1.id)) ==
             Assignments.open_assignments_touching(ctx.db, ["same-race-path"])

    opened = marker_contents(ctx.db, "holder")

    for assignment <- [first | overlapping] ++ [empty_files, no_files | concurrent] do
      assert "[assignment opened: #{assignment.id}]" in opened
    end

    assert {:ok, [[0]]} = DB.query(ctx.db, "SELECT count(*) FROM events WHERE kind = 'denied'")
    assert {:ok, [[0]]} = DB.query(ctx.db, "SELECT count(*) FROM rail_remedy_episodes")

    completion_target =
      assign_call({:user, "flynn"}, "outside-list completion")
      |> put_in([:params, :files], ["lib/a.ex"])
      |> put_in([:params, :effect_kind], "coordination")
      |> then(&handle(ctx, "assign", &1))

    completion_call =
      attest_call({:session, "holder"}, completion_target.id, "completion")
      |> put_in([:params, :files], ["lib/b.ex"])

    completion = handle(ctx, "attest", completion_call)
    assert completion.assignment.state == "closed"
    assert completion.assignment.outcome == "completed"

    markers = marker_contents(ctx.db, "holder")
    assert "[completion filed on #{completion_target.id}]" in markers
    assert "[assignment closed: #{completion_target.id} — completed]" in markers
    refute Enum.any?(markers, &String.contains?(&1, "path denied"))
  end

  test "assignment readback and work-item trace project the same ordered declared files", ctx do
    paths = [
      "test/job_trace_test.exs",
      "lib/tightbeam/assignments.ex",
      "test/assignments_test.exs"
    ]

    expected = Enum.sort(paths)
    item = create_work_item(ctx, "Assignment file projection")

    assignment =
      assign_call({:user, "flynn"}, "project files", nil, item.id)
      |> put_in([:params, :files], paths)
      |> then(&handle(ctx, "assign", &1))

    %{assignments: assignments} =
      handle(ctx, "assignments", query_call({:user, "flynn"}, "open", "holder"))

    readback = Enum.find(assignments, &(&1.id == assignment.id))

    trace =
      Tightbeam.WorkItems.__handle__(ctx.db, "work-item-trace", %{
        verb: "work-item-trace",
        principal: {:user, "flynn"},
        origin: "user:flynn",
        session_key: nil,
        params: %{work_item_id: item.id}
      })

    traced = Enum.find(trace.assignments, &(&1.id == assignment.id))

    assert readback.files == expected
    assert Assignments.declared_files(ctx.db, assignment.id) == expected
    assert traced.files == expected
  end

  test "verdict attests freeze provenance and project inert producer history columns", ctx do
    assignment =
      assign_call({:user, "flynn"}, "verdict stamps")
      |> put_in([:params, :effect_kind], "coordination")
      |> then(&handle(ctx, "assign", &1))

    ordinary =
      handle(ctx, "attest", %{
        attest_call({:session, "holder"}, assignment.id, "verdict")
        | params: %{assignment_id: assignment.id, kind: "verdict", verdict_kind: "reviewed-clean"}
      })

    assert ordinary.attest.byHarness == "claude"
    assert ordinary.attest.byProvider == "anthropic"
    # The producer columns are read-only history: nothing writes them anymore,
    # and the projection keeps carrying them as nil on every new row.
    assert ordinary.attest.producer == nil
    assert ordinary.attest.producerCommand == nil

    user_verdict =
      handle(ctx, "attest", %{
        attest_call({:user, "flynn"}, assignment.id, "verdict")
        | params: %{assignment_id: assignment.id, kind: "verdict", verdict_kind: "user-ruling"}
      })

    assert user_verdict.attest.byHarness == nil
    assert user_verdict.attest.byProvider == nil

    rows = Assignments.list_attests(ctx.db, assignment.id)
    assert Enum.find(rows, &(&1.id == ordinary.attest.id)).byHarness == "claude"
    assert Enum.all?(rows, &(&1.producer == nil and &1.producerCommand == nil))

    closed = handle(ctx, "attest", attest_call({:session, "holder"}, assignment.id, "completion"))
    assert closed.assignment.state == "closed"
  end

  test "commissioned review authors enforce the full review-link predicate", ctx do
    third = session(ctx.db, "third-session", "other", %{harness: "codex", provider: "openai"})
    producer = handle(ctx, "assign", assign_call({:user, "flynn"}, "producer assignment"))

    valid_review =
      assign_call({:user, "flynn"}, "valid review")
      |> Map.put(:session_key, third.session_key)
      |> put_in([:params, :reviews_assignment_id], producer.id)
      |> then(&handle(ctx, "assign", &1))

    valid =
      attest_call({:session, third.session_key}, valid_review.id, "verdict")
      |> put_in([:params, :verdict_kind], "reviewed-clean")
      |> then(&handle(ctx, "attest", &1))

    wrong_producer = handle(ctx, "assign", assign_call({:user, "flynn"}, "other producer"))

    wrong_review =
      assign_call({:user, "flynn"}, "wrong-link review")
      |> Map.put(:session_key, third.session_key)
      |> put_in([:params, :reviews_assignment_id], wrong_producer.id)
      |> then(&handle(ctx, "assign", &1))

    _wrong_link_verdict =
      attest_call({:session, third.session_key}, wrong_review.id, "verdict")
      |> put_in([:params, :verdict_kind], "wrong-link")
      |> then(&handle(ctx, "attest", &1))

    direct =
      attest_call({:session, third.session_key}, producer.id, "verdict")
      |> put_in([:params, :verdict_kind], "direct-does-not-count")

    _ = handle(ctx, "attest", direct)

    third_party =
      attest_call({:session, "other-session"}, valid_review.id, "verdict")
      |> put_in([:params, :verdict_kind], "third-party")

    assert %{code: "not_holder"} = handle(ctx, "attest", third_party)

    user =
      attest_call({:user, "flynn"}, valid_review.id, "verdict")
      |> put_in([:params, :verdict_kind], "user-verdict")

    assert %{code: "not_holder"} = handle(ctx, "attest", user)

    self_commissioned =
      assign_call({:session, "holder"}, "self commissioned")
      |> Map.put(:session_key, "other-session")
      |> put_in([:params, :reviews_assignment_id], producer.id)
      |> then(&handle(ctx, "assign", &1))

    self_verdict =
      attest_call({:session, "other-session"}, self_commissioned.id, "verdict")
      |> put_in([:params, :verdict_kind], "self-commissioned")

    _ = handle(ctx, "attest", self_verdict)

    assert Assignments.commissioned_review_authors(ctx.db, producer.id, "holder") == [
             %{
               verdict_kind: valid.attest.verdictKind,
               by_harness: "codex",
               by_provider: "openai"
             },
             %{
               verdict_kind: "self-commissioned",
               by_harness: "claude",
               by_provider: "anthropic"
             }
           ]
  end

  test "linked review verdicts require the holder before syntax validation", ctx do
    producer = handle(ctx, "assign", assign_call({:user, "flynn"}, "guard producer"))

    review =
      assign_call({:user, "flynn"}, "guard review")
      |> Map.put(:session_key, "other-session")
      |> put_in([:params, :reviews_assignment_id], producer.id)
      |> then(&handle(ctx, "assign", &1))

    for verdict_kind <- ["reviewed-clean", "changes-requested"] do
      result =
        attest_call({:session, "other-session"}, review.id, "verdict")
        |> put_in([:params, :verdict_kind], verdict_kind)
        |> then(&handle(ctx, "attest", &1))

      assert result.attest.verdictKind == verdict_kind
      assert result.attest.bySession == "other-session"
      assert result.attest.byUser == nil
    end

    for {principal, verdict_kind} <- [
          {{:session, "holder"}, "reviewed-clean"},
          {{:session, "holder"}, "changes-requested"},
          {{:user, "flynn"}, "reviewed-clean"},
          {{:user, "flynn"}, "Bad"}
        ] do
      denied =
        attest_call(principal, review.id, "verdict")
        |> put_in([:params, :verdict_kind], verdict_kind)

      assert %{code: "not_holder"} = handle(ctx, "attest", denied)
    end

    assert review.id
           |> then(&Assignments.list_attests(ctx.db, &1))
           |> Enum.map(& &1.verdictKind)
           |> Enum.sort() == ["changes-requested", "reviewed-clean"]

    malformed =
      attest_call({:session, "other-session"}, review.id, "verdict")
      |> put_in([:params, :verdict_kind], "Bad")

    assert %{code: "invalid_verdict_kind"} = handle(ctx, "attest", malformed)

    _ =
      attest_call({:session, "other-session"}, review.id, "completion")
      |> then(&handle(ctx, "attest", &1))

    assert %{code: "assignment_closed"} = handle(ctx, "attest", malformed)
  end

  test "qualifying review verdict follows the latest independent round across terminal state",
       ctx do
    producer = handle(ctx, "assign", assign_call({:user, "flynn"}, "qualifying producer"))

    review =
      assign_call({:user, "flynn"}, "qualifying review")
      |> Map.put(:session_key, "other-session")
      |> put_in([:params, :reviews_assignment_id], producer.id)
      |> then(&handle(ctx, "assign", &1))

    assert Assignments.qualifying_review_verdict_kinds(ctx.db, producer.id, "holder") == []

    assert %{code: "not_holder"} =
             attest_call({:session, "holder"}, review.id, "verdict")
             |> put_in([:params, :verdict_kind], "third-party")
             |> then(&handle(ctx, "attest", &1))

    assert Assignments.qualifying_review_verdict_kinds(ctx.db, producer.id, "holder") == []

    _ =
      attest_call({:session, "other-session"}, review.id, "verdict")
      |> put_in([:params, :verdict_kind], "reviewed-clean")
      |> then(&handle(ctx, "attest", &1))

    assert Assignments.qualifying_review_verdict_kinds(ctx.db, producer.id, "holder") == [
             "reviewed-clean"
           ]

    _ =
      attest_call({:session, "other-session"}, review.id, "verdict")
      |> put_in([:params, :verdict_kind], "reviewed-clean")
      |> then(&handle(ctx, "attest", &1))

    assert Assignments.qualifying_review_verdict_kinds(ctx.db, producer.id, "holder") == [
             "reviewed-clean"
           ]

    _ =
      attest_call({:session, "other-session"}, review.id, "verdict")
      |> put_in([:params, :verdict_kind], "changes-requested")
      |> then(&handle(ctx, "attest", &1))

    assert Assignments.qualifying_review_verdict_kinds(ctx.db, producer.id, "holder") == []

    second_review =
      assign_call({:user, "flynn"}, "second qualifying review")
      |> Map.put(:session_key, "other-session")
      |> put_in([:params, :reviews_assignment_id], producer.id)
      |> then(&handle(ctx, "assign", &1))

    _ =
      attest_call({:session, "other-session"}, second_review.id, "verdict")
      |> put_in([:params, :verdict_kind], "reviewed-clean")
      |> then(&handle(ctx, "attest", &1))

    assert Assignments.qualifying_review_verdict_kinds(ctx.db, producer.id, "holder") == [
             "reviewed-clean"
           ]

    _ =
      attest_call({:session, "other-session"}, review.id, "verdict")
      |> put_in([:params, :verdict_kind], "reviewed-clean")
      |> then(&handle(ctx, "attest", &1))

    assert Assignments.qualifying_review_verdict_kinds(ctx.db, producer.id, "holder") == [
             "reviewed-clean"
           ]

    _ =
      attest_call({:session, "other-session"}, second_review.id, "completion")
      |> then(&handle(ctx, "attest", &1))

    assert Assignments.qualifying_review_verdict_kinds(ctx.db, producer.id, "holder") == [
             "reviewed-clean"
           ]

    revoked_review =
      assign_call({:user, "flynn"}, "revoked qualifying review")
      |> Map.put(:session_key, "other-session")
      |> put_in([:params, :reviews_assignment_id], producer.id)
      |> then(&handle(ctx, "assign", &1))

    _ =
      attest_call({:session, "other-session"}, revoked_review.id, "verdict")
      |> put_in([:params, :verdict_kind], "reviewed-clean")
      |> then(&handle(ctx, "attest", &1))

    _ = handle(ctx, "revoke-assignment", revoke_call({:user, "flynn"}, revoked_review.id))

    assert Assignments.qualifying_review_verdict_kinds(ctx.db, producer.id, "holder") == [
             "reviewed-clean"
           ]

    blocking_review =
      assign_call({:user, "flynn"}, "blocking latest review")
      |> Map.put(:session_key, "other-session")
      |> put_in([:params, :reviews_assignment_id], producer.id)
      |> then(&handle(ctx, "assign", &1))

    _ =
      attest_call({:session, "other-session"}, blocking_review.id, "verdict")
      |> put_in([:params, :verdict_kind], "changes-requested")
      |> then(&handle(ctx, "attest", &1))

    assert Assignments.qualifying_review_verdict_kinds(ctx.db, producer.id, "holder") == []
  end

  test "qualifying review verdict uses creation order when review rounds share a timestamp",
       ctx do
    producer = handle(ctx, "assign", assign_call({:user, "flynn"}, "tied review producer"))

    assert {:ok, _} =
             DB.query(
               ctx.db,
               """
               INSERT INTO assignments
                 (id, subject, holderKey, holderFallback, openedByUser, openedAt,
                  reviewsAssignmentId, holderHarness, holderProvider)
               VALUES
                 ('zzzz_older_review', 'older review', 'other-session', 0, 'flynn', 42,
                  ?1, 'claude', 'anthropic'),
                 ('aaaa_newer_review', 'newer review', 'other-session', 0, 'flynn', 42,
                  ?1, 'claude', 'anthropic')
               """,
               [producer.id]
             )

    assert {:ok, _} =
             DB.query(
               ctx.db,
               """
               INSERT INTO attests
                 (id, assignmentId, kind, verdictKind, bySession, byHarness, byProvider, ts)
               VALUES
                 ('older_clean', 'zzzz_older_review', 'verdict', 'reviewed-clean',
                  'other-session', 'claude', 'anthropic', 42),
                 ('newer_changes', 'aaaa_newer_review', 'verdict', 'changes-requested',
                  'other-session', 'claude', 'anthropic', 42)
               """
             )

    assert Assignments.qualifying_review_verdict_kinds(ctx.db, producer.id, "holder") == []
  end

  test "a later revoked verdictless review cannot displace holder-reviewed-clean", ctx do
    producer =
      assign_call({:user, "flynn"}, "Surf Ace producer")
      |> put_in([:params, :effect_kind], "policy")
      |> then(&handle(ctx, "assign", &1))

    clean_review =
      assign_call({:user, "flynn"}, "independent clean review")
      |> Map.put(:session_key, "other-session")
      |> put_in([:params, :reviews_assignment_id], producer.id)
      |> then(&handle(ctx, "assign", &1))

    _ =
      attest_call({:session, "other-session"}, clean_review.id, "verdict")
      |> put_in([:params, :verdict_kind], "reviewed-clean")
      |> then(&handle(ctx, "attest", &1))

    _ =
      handle(
        ctx,
        "attest",
        attest_call({:session, "other-session"}, clean_review.id, "completion")
      )

    verdictless_review =
      assign_call({:user, "flynn"}, "later verdictless review")
      |> Map.put(:session_key, "other-session")
      |> put_in([:params, :reviews_assignment_id], producer.id)
      |> then(&handle(ctx, "assign", &1))

    _ =
      handle(
        ctx,
        "revoke-assignment",
        revoke_call({:user, "flynn"}, verdictless_review.id)
      )

    assert Assignments.qualifying_review_verdict_kinds(ctx.db, producer.id, "holder") == [
             "reviewed-clean"
           ]

    completed =
      handle(ctx, "attest", attest_call({:session, "holder"}, producer.id, "completion"))

    assert completed.assignment.state == "closed"
    assert completed.assignment.outcome == "completed"
  end

  test "the exact newest holder verdict row still controls review and independence", ctx do
    producer = handle(ctx, "assign", assign_call({:user, "flynn"}, "verdict ordering"))

    older =
      assign_call({:user, "flynn"}, "older review")
      |> Map.put(:session_key, "other-session")
      |> put_in([:params, :reviews_assignment_id], producer.id)
      |> then(&handle(ctx, "assign", &1))

    newer =
      assign_call({:user, "flynn"}, "newer self-held review")
      |> put_in([:params, :reviews_assignment_id], producer.id)
      |> then(&handle(ctx, "assign", &1))

    _ =
      attest_call({:session, "other-session"}, older.id, "verdict")
      |> put_in([:params, :verdict_kind], "reviewed-clean")
      |> then(&handle(ctx, "attest", &1))

    _ =
      attest_call({:session, "holder"}, newer.id, "verdict")
      |> put_in([:params, :verdict_kind], "reviewed-clean")
      |> then(&handle(ctx, "attest", &1))

    assert Assignments.qualifying_review_verdict_kinds(ctx.db, producer.id, "holder") == []

    _ =
      attest_call({:session, "other-session"}, older.id, "verdict")
      |> put_in([:params, :verdict_kind], "changes-requested")
      |> then(&handle(ctx, "attest", &1))

    assert Assignments.qualifying_review_verdict_kinds(ctx.db, producer.id, "holder") == []

    _ =
      attest_call({:session, "other-session"}, older.id, "verdict")
      |> put_in([:params, :verdict_kind], "reviewed-clean")
      |> then(&handle(ctx, "attest", &1))

    assert Assignments.qualifying_review_verdict_kinds(ctx.db, producer.id, "holder") == [
             "reviewed-clean"
           ]
  end

  test "prefixed idempotency scopes disjoint equal user and session strings", ctx do
    user = handle(ctx, "assign", assign_call({:user, "holder"}, "user", "collision"))
    session = handle(ctx, "assign", assign_call({:session, "holder"}, "session", "collision"))
    refute user.id == session.id

    assert {:ok, [["session:holder"], ["user:holder"]]} =
             DB.query(
               ctx.db,
               "SELECT ownerUserId FROM wire_idempotency WHERE operation = 'assign' ORDER BY ownerUserId"
             )
  end

  test "attest lifecycle, authorization precedence, and terminal race are atomic", ctx do
    assignment =
      assign_call({:session, "holder"}, "work")
      |> put_in([:params, :effect_kind], "coordination")
      |> then(&handle(ctx, "assign", &1))

    assert %{code: "process_denied"} =
             handle(ctx, "attest", attest_call({:process, "cron"}, assignment.id, "progress"))

    assert %{code: "principal_required"} =
             handle(ctx, "attest", attest_call(nil, assignment.id, "progress"))

    assert %{code: "not_holder"} =
             handle(
               ctx,
               "attest",
               attest_call({:session, "other-session"}, assignment.id, "progress")
             )

    assert %{code: "not_holder"} =
             handle(
               ctx,
               "attest",
               attest_call({:session, "other-session"}, assignment.id, "bogus")
             )

    assert %{code: "missing_verdict_kind"} =
             handle(
               ctx,
               "attest",
               attest_call({:session, "other-session"}, assignment.id, "verdict")
             )

    assert %{code: "not_holder"} =
             handle(ctx, "attest", attest_call({:user, "flynn"}, assignment.id, "progress"))

    assert %{code: "invalid_kind"} =
             handle(ctx, "attest", attest_call({:session, "holder"}, assignment.id, "bogus"))

    assert %{code: "missing_verdict_kind"} =
             handle(ctx, "attest", attest_call({:session, "holder"}, assignment.id, "verdict"))

    assert %{code: "invalid_note"} =
             handle(ctx, "attest", %{
               attest_call({:session, "holder"}, assignment.id, "progress")
               | params: %{assignment_id: assignment.id, kind: "progress", note: " "}
             })

    assert %{code: "unknown_assignment"} =
             handle(ctx, "attest", attest_call({:session, "holder"}, "missing", "progress"))

    progress = handle(ctx, "attest", attest_call({:session, "holder"}, assignment.id, "progress"))
    assert progress.assignment.state == "open"
    assert progress.attest.kind == "progress"

    completed =
      handle(ctx, "attest", attest_call({:session, "holder"}, assignment.id, "completion"))

    assert completed.assignment.state == "closed"
    assert completed.assignment.outcome == "completed"
    assert completed.assignment.closingAttestId == completed.attest.id

    race =
      assign_call({:session, "holder"}, "race")
      |> put_in([:params, :effect_kind], "coordination")
      |> then(&handle(ctx, "assign", &1))

    complete =
      Task.async(fn ->
        handle(ctx, "attest", attest_call({:session, "holder"}, race.id, "completion"))
      end)

    revoke =
      Task.async(fn ->
        handle(ctx, "revoke-assignment", revoke_call({:session, "holder"}, race.id))
      end)

    results = Task.await_many([complete, revoke])
    assert Enum.count(results, &(&1[:code] == "assignment_closed")) == 1
    winner = Enum.find(results, &(&1[:code] != "assignment_closed"))
    assert winner

    assert {:ok, [[count]]} =
             DB.query(
               ctx.db,
               "SELECT count(*) FROM attests WHERE assignmentId = ?1 AND kind = 'completion'",
               [race.id]
             )

    assert count in [0, 1]
    assert (winner[:attest] && count == 1) || (!winner[:attest] && count == 0)

    terminal = handle(ctx, "assign", assign_call({:session, "holder"}, "terminal"))
    closed = handle(ctx, "attest", attest_call({:session, "holder"}, terminal.id, "surrender"))
    assert closed.assignment.outcome == "surrendered"
    assert closed.assignment.closingAttestId == closed.attest.id

    assert %{code: "assignment_closed"} =
             handle(ctx, "attest", attest_call({:session, "holder"}, terminal.id, "progress"))

    assert %{code: "assignment_closed"} =
             handle(ctx, "attest", attest_call({:session, "holder"}, terminal.id, "verdict"))
  end

  test "work lifecycle markers land in the actor transcript with exact event text", ctx do
    completed =
      assign_call({:user, "flynn"}, "completed markers")
      |> put_in([:params, :effect_kind], "coordination")
      |> then(&handle(ctx, "assign", &1))

    progress =
      handle(ctx, "attest", attest_call({:session, "holder"}, completed.id, "progress"))

    verdict_call =
      attest_call({:session, "holder"}, completed.id, "verdict")
      |> put_in([:params, :verdict_kind], "reviewed-clean")

    verdict = handle(ctx, "attest", verdict_call)

    marker_count_before_user_verdict = length(marker_contents(ctx.db, "holder"))

    user_verdict_call =
      attest_call({:user, "flynn"}, completed.id, "verdict")
      |> put_in([:params, :verdict_kind], "user-ruling")

    user_verdict = handle(ctx, "attest", user_verdict_call)

    assert length(marker_contents(ctx.db, "holder")) == marker_count_before_user_verdict

    completion =
      handle(ctx, "attest", attest_call({:session, "holder"}, completed.id, "completion"))

    surrendered = handle(ctx, "assign", assign_call({:user, "flynn"}, "surrender markers"))

    surrender =
      handle(ctx, "attest", attest_call({:session, "holder"}, surrendered.id, "surrender"))

    revoked = handle(ctx, "assign", assign_call({:user, "flynn"}, "revoke markers"))
    revocation = handle(ctx, "revoke-assignment", revoke_call({:user, "flynn"}, revoked.id))

    assert marker_contents(ctx.db, "holder") == [
             "[assignment opened: #{completed.id}]",
             "[progress filed on #{completed.id}]",
             "[verdict filed: reviewed-clean on #{completed.id}]",
             "[completion filed on #{completed.id}]",
             "[assignment closed: #{completed.id} — completed]",
             "[assignment opened: #{surrendered.id}]",
             "[surrendered #{surrendered.id} — needs user input]",
             "[assignment closed: #{surrendered.id} — surrendered]",
             "[assignment opened: #{revoked.id}]",
             "[assignment revoked: #{revoked.id}]"
           ]

    assert progress.attest.kind == "progress"
    assert verdict.attest.verdictKind == "reviewed-clean"
    assert user_verdict.attest.byUser == "flynn"
    assert completion.assignment.outcome == "completed"
    assert completion.assignment.closingAttestId == completion.attest.id
    assert surrender.assignment.outcome == "surrendered"
    assert surrender.assignment.closingAttestId == surrender.attest.id
    assert revocation.outcome == "revoked"
    assert revocation.closingAttestId == nil

    assert Enum.all?(Projection.list_after(ctx.db, "holder", nil, 100), fn marker ->
             marker.role == "assistant" and marker.sender == "process:tightbeam"
           end)
  end

  test "a marker insert failure does not fail the underlying attest", ctx do
    assignment = handle(ctx, "assign", assign_call({:user, "flynn"}, "marker failure"))
    :ok = DB.execute(ctx.db, "DROP TABLE messages")

    result =
      handle(ctx, "attest", attest_call({:session, "holder"}, assignment.id, "progress"))

    assert result.assignment.id == assignment.id
    assert result.attest.kind == "progress"
    assert Assignments.attest_count(ctx.db, assignment.id) == 1
  end

  test "revoke permits admin and typed openers, denies others, and creates no attest", ctx do
    for {principal, opener} <- [
          {{:user, "admin"}, {:user, "flynn"}},
          {{:user, "flynn"}, {:user, "flynn"}},
          {{:session, "holder"}, {:session, "holder"}}
        ] do
      assignment = handle(ctx, "assign", assign_call(opener, inspect(principal)))
      revoked = handle(ctx, "revoke-assignment", revoke_call(principal, assignment.id))
      assert revoked.outcome == "revoked"
      assert revoked.closingAttestId == nil
    end

    assignment = handle(ctx, "assign", assign_call({:user, "flynn"}, "deny"))

    assert %{code: "not_authorized"} =
             handle(ctx, "revoke-assignment", revoke_call({:user, "other"}, assignment.id))

    assert %{code: "process_denied"} =
             handle(ctx, "revoke-assignment", revoke_call({:process, "x"}, assignment.id))

    assert %{code: "principal_required"} =
             handle(ctx, "revoke-assignment", revoke_call(nil, assignment.id))

    assert {:ok, [[0]]} = DB.query(ctx.db, "SELECT count(*) FROM attests")
  end

  test "query filters, deterministic ordering, role-resolved holder input, and open_count", ctx do
    a =
      assign_call({:user, "flynn"}, "a")
      |> put_in([:params, :effect_kind], "coordination")
      |> then(&handle(ctx, "assign", &1))

    b = handle(ctx, "assign", assign_call({:user, "flynn"}, "b"))
    _ = handle(ctx, "attest", attest_call({:session, "holder"}, a.id, "completion"))
    {:ok, _} = DB.query(ctx.db, "UPDATE assignments SET openedAt = 99")

    assert Assignments.open_count(ctx.db, "holder") == 1

    assert Enum.map(Assignments.list(ctx.db, %{state: "all"}), & &1.id) ==
             Enum.sort([a.id, b.id], :desc)

    assert Enum.map(Assignments.list(ctx.db, %{state: "open", holder_key: "holder"}), & &1.id) ==
             [b.id]

    assert %{assignments: [_]} =
             handle(ctx, "assignments", query_call({:user, "flynn"}, "open", "holder"))

    assert %{code: "invalid_state_filter"} =
             handle(ctx, "assignments", query_call({:user, "flynn"}, "bad", nil))

    assert %{code: "process_denied"} =
             handle(ctx, "assignments", query_call({:process, "x"}, "bad", nil))

    assert %{code: "principal_required"} =
             handle(ctx, "assignments", query_call(nil, "open", nil))
  end

  test "each accepted verb emits one event and a real statute denies assign", ctx do
    assignment = dispatch!(ctx, assign_call({:session, "holder"}, "events"))
    dispatch!(ctx, attest_call({:session, "holder"}, assignment.id, "progress"))
    dispatch!(ctx, query_call({:session, "holder"}, "open", nil))
    dispatch!(ctx, revoke_call({:session, "holder"}, assignment.id))

    assert {:ok, [[4]]} =
             DB.query(
               ctx.db,
               "SELECT count(*) FROM events WHERE kind = 'verb' AND verb IN ('assign','attest','assignments','revoke-assignment')"
             )

    base = Path.join(System.tmp_dir!(), "assignment-rules-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(base, "identity/rules"))

    File.write!(Path.join(base, "identity/rules/deny.toml"), """
    [[rule]]
    name = "deny-assign"
    verb = "assign"
    text = "assign denied"
    [[rule.deny_when]]
    fact = "caller.origin_class"
    op = "eq"
    value = "agent"
    """)

    on_exit(fn -> File.rm_rf!(base) end)
    Rules.load!(base, Map.keys(ctx.handlers))

    assert {:error, %{code: "rule_denied"}} =
             Dispatch.dispatch(ctx.db, ctx.handlers, assign_call({:session, "holder"}, "denied"))
  end

  test "zero rules cannot bypass code completion evidence and verdict emits one verb event",
       ctx do
    completion_assignment = dispatch!(ctx, assign_call({:session, "holder"}, "completion"))

    assert {:error, %{code: "inapplicable_code_evidence"}} =
             Dispatch.dispatch(
               ctx.db,
               ctx.handlers,
               attest_call({:session, "holder"}, completion_assignment.id, "completion")
             )

    assert %{state: "open", closingAttestId: nil} =
             handle(
               ctx,
               "assignment-get",
               assignment_get_call({:session, "holder"}, completion_assignment.id)
             )

    assert {:ok, [[0]]} =
             DB.query(
               ctx.db,
               "SELECT count(*) FROM attests WHERE assignmentId=?1 AND kind='completion'",
               [completion_assignment.id]
             )

    assert {:ok, [[before_verdict]]} =
             DB.query(
               ctx.db,
               "SELECT count(*) FROM events WHERE kind = 'verb' AND verb = 'attest'"
             )

    verdict_assignment = dispatch!(ctx, assign_call({:session, "holder"}, "verdict event"))

    verdict_call =
      attest_call({:user, "flynn"}, verdict_assignment.id, "verdict")
      |> put_in([:params, :verdict_kind], "tests-passed")

    assert {:ok, %{attest: verdict}} =
             Dispatch.dispatch(ctx.db, ctx.handlers, verdict_call)

    assert verdict.verdictKind == "tests-passed"

    assert {:ok, [[after_verdict]]} =
             DB.query(
               ctx.db,
               "SELECT count(*) FROM events WHERE kind = 'verb' AND verb = 'attest'"
             )

    assert after_verdict == before_verdict + 1
  end

  test "a review retraction committed after applicability precheck defeats code completion",
       ctx do
    previous_runner = Application.get_env(:tightbeam, :commit_ref_command)

    on_exit(fn ->
      if previous_runner,
        do: Application.put_env(:tightbeam, :commit_ref_command, previous_runner),
        else: Application.delete_env(:tightbeam, :commit_ref_command)
    end)

    Application.put_env(:tightbeam, :commit_ref_command, fn _executable, _args, _opts ->
      {"", 0}
    end)

    refs = [
      %{
        "repo" => "eezo:/tmp/o2-result",
        "commit" => String.duplicate("a", 40)
      }
    ]

    producer = handle(ctx, "assign", assign_call({:user, "flynn"}, "retraction producer"))

    review =
      assign_call({:user, "flynn"}, "retraction review")
      |> Map.put(:session_key, "other-session")
      |> put_in([:params, :reviews_assignment_id], producer.id)
      |> then(&handle(ctx, "assign", &1))

    assert %{attest: %{verdictKind: "reviewed-clean"}} =
             attest_call({:session, "other-session"}, review.id, "verdict")
             |> put_in([:params, :verdict_kind], "reviewed-clean")
             |> put_in([:params, :commit_refs], refs)
             |> then(&handle(ctx, "attest", &1))

    assert %{attest: %{verdictKind: "verified"}} =
             attest_call({:session, "holder"}, producer.id, "verdict")
             |> put_in([:params, :verdict_kind], "verified")
             |> put_in([:params, :commit_refs], refs)
             |> then(&handle(ctx, "attest", &1))

    assert Assignments.qualifying_review_verdict_kinds(
             ctx.db,
             producer.id,
             "holder",
             refs
           ) == ["reviewed-clean"]

    assert Assignments.qualifying_verification_verdict_kinds(
             ctx.db,
             producer.id,
             "holder",
             refs
           ) == ["verified"]

    Application.put_env(:tightbeam, :commit_ref_command, fn _executable, _args, _opts ->
      assert {:ok, _} =
               DB.query(
                 ctx.db,
                 """
                 INSERT INTO attests
                   (id,assignmentId,kind,verdictKind,note,bySession,byHarness,byProvider,commitRefs,ts)
                 VALUES
                   ('att_concurrent_retraction',?1,'verdict','changes-requested','retracted',
                    'other-session','claude','anthropic',?2,?3)
                 """,
                 [review.id, JSON.encode!(refs), System.system_time(:millisecond) + 1_000]
               )

      {"", 0}
    end)

    completion =
      attest_call({:session, "holder"}, producer.id, "completion")
      |> put_in([:params, :commit_refs], refs)

    assert %{code: "inapplicable_code_evidence"} = handle(ctx, "attest", completion)

    assert %{state: "open", closingAttestId: nil} =
             handle(
               ctx,
               "assignment-get",
               assignment_get_call({:session, "holder"}, producer.id)
             )

    assert {:ok, [[0]]} =
             DB.query(
               ctx.db,
               "SELECT count(*) FROM attests WHERE assignmentId=?1 AND kind='completion'",
               [producer.id]
             )
  end

  test "attests returns every kind in timestamp and id order", ctx do
    assignment = handle(ctx, "assign", assign_call({:user, "flynn"}, "all attests"))

    {:ok, _} =
      DB.query(
        ctx.db,
        """
        INSERT INTO attests
          (id, assignmentId, kind, verdictKind, note, bySession, byUser, ts)
        VALUES
          ('att_progress', ?1, 'progress', NULL, NULL, 'holder', NULL, 30),
          ('att_completion', ?1, 'completion', NULL, NULL, 'holder', NULL, 20),
          ('att_surrender', ?1, 'surrender', NULL, NULL, 'holder', NULL, 20),
          ('att_verdict', ?1, 'verdict', 'reviewed-clean', NULL, NULL, 'flynn', 10)
        """,
        [assignment.id]
      )

    assert %{attests: attests} =
             handle(
               ctx,
               "attests",
               call("attests", {:user, "flynn"}, nil, %{assignment_id: assignment.id})
             )

    assert Enum.map(attests, &{&1.kind, &1.ts, &1.id}) == [
             {"verdict", 10, "att_verdict"},
             {"completion", 20, "att_completion"},
             {"surrender", 20, "att_surrender"},
             {"progress", 30, "att_progress"}
           ]
  end

  test "accepted handler rolls back when its event append fails", ctx do
    {:ok, _} = DB.query(ctx.db, "DROP TABLE events")

    assert_raise MatchError, fn ->
      Dispatch.dispatch(
        ctx.db,
        ctx.handlers,
        Map.put(assign_call({:session, "holder"}, "committed"), :supervision_interval_ms, 1_000)
      )
    end

    assert {:ok, [[0]]} =
             DB.query(ctx.db, "SELECT count(*) FROM assignments WHERE subject = 'committed'")
  end

  defp handle(ctx, verb, call)
       when verb in [
              "assign",
              "dispatch",
              "assignment-get",
              "attest",
              "attests",
              "revoke-assignment",
              "reopen-assignment",
              "assignments"
            ],
       do:
         Assignments.__handle__(
           ctx.db,
           verb,
           call
           |> Map.put(:verb, verb)
           |> then(fn routed ->
             if verb in ["assign", "dispatch", "reopen-assignment"],
               do: Map.put_new(routed, :supervision_interval_ms, 1_000),
               else: routed
           end)
         )

  defp handle(ctx, verb, call), do: WorkItems.__handle__(ctx.db, verb, %{call | verb: verb})

  defp create_work_item(ctx, title) do
    handle(
      ctx,
      "work-item-create",
      work_item_call("work-item-create", {:user, "flynn"}, %{title: title})
    )
  end

  defp dispatch!(ctx, call) do
    assert {:ok, result} =
             Dispatch.dispatch(
               ctx.db,
               ctx.handlers,
               Map.put_new(call, :supervision_interval_ms, 1_000)
             )

    result
  end

  defp marker_contents(db, session_key) do
    db
    |> Projection.list_after(session_key, nil, 100)
    |> Enum.map(& &1.content)
  end

  defp reopen_mutation_snapshot(db, assignment_id) do
    {:ok, [assignment]} =
      DB.query(
        db,
        "SELECT state,outcome,closedAt,closedByUser,closedBySession,closedByProcess,closingAttestId,reminderState " <>
          "FROM assignments WHERE id=?1",
        [assignment_id]
      )

    {:ok, [[reopening_count]]} =
      DB.query(db, "SELECT count(*) FROM assignment_reopenings WHERE assignmentId=?1", [
        assignment_id
      ])

    {:ok, supervision} =
      DB.query(
        db,
        "SELECT generation,state,cause FROM supervision_entitlements WHERE assignmentId=?1",
        [assignment_id]
      )

    {:ok, effort} =
      DB.query(
        db,
        "SELECT generation,state,wakeId FROM effort_checkin_generations WHERE assignmentId=?1 ORDER BY generation",
        [assignment_id]
      )

    %{
      assignment: assignment,
      reopeningCount: reopening_count,
      supervision: supervision,
      effort: effort
    }
  end

  defp assert_reopen_refused!(ctx, principal, assignment_id, reason, expected_code) do
    before = reopen_mutation_snapshot(ctx.db, assignment_id)

    assert %{code: ^expected_code} =
             handle(ctx, "reopen-assignment", reopen_call(principal, assignment_id, reason))

    assert reopen_mutation_snapshot(ctx.db, assignment_id) == before
  end

  defp reopen_call(principal, id, reason),
    do: call("reopen-assignment", principal, nil, %{assignment_id: id, reason: reason})

  defp assignment_count(db) do
    {:ok, [[count]]} = DB.query(db, "SELECT count(*) FROM assignments")
    count
  end

  defp assign_call(principal, subject \\ "work", key \\ nil, work_item_id \\ nil) do
    call("assign", principal, "holder", %{
      subject: subject,
      idempotency_key: key,
      work_item_id: work_item_id
    })
    |> Map.merge(%{target_role: nil, role_fallback: false})
  end

  defp dispatch_call(principal, subject, brief, key \\ nil, work_item_id \\ nil) do
    call("dispatch", principal, "holder", %{
      subject: subject,
      brief: brief,
      idempotency_key: key,
      work_item_id: work_item_id
    })
    |> Map.merge(%{target_role: nil, role_fallback: false, supervision_interval_ms: 1_000})
  end

  defp work_item_call(verb, principal, params), do: call(verb, principal, nil, params)

  defp attest_call(principal, id, kind),
    do: call("attest", principal, nil, %{assignment_id: id, kind: kind})

  defp assignment_get_call(principal, id),
    do: call("assignment-get", principal, nil, %{assignment_id: id})

  defp revoke_call(principal, id),
    do:
      call("revoke-assignment", principal, nil, %{
        assignment_id: id,
        reason: "test authorized disposition"
      })

  defp query_call(principal, state, holder),
    do: call("assignments", principal, holder, %{state: state})

  defp call(verb, principal, target, params) do
    %{
      verb: verb,
      origin: origin(principal),
      principal: principal,
      session_key: target,
      params: params
    }
  end

  defp origin({:session, key}), do: "agent:#{key}"
  defp origin({:user, user}), do: "user:#{user}"
  defp origin({:process, process}), do: "process:#{process}"
  defp origin(nil), do: "agent:declared"

  defp start_liveness!(ctx) do
    name = :"assignments_liveness_#{System.unique_integer([:positive])}"

    start_supervised!(
      {Supervision,
       db: ctx.db, handlers: ctx.handlers, prod_limit: 2, sweep_ms: 1_000, name: name}
    )

    :sys.get_state(name)
    name
  end

  defp sweep_liveness!(name) do
    Supervision.request_sweep(name)
    :sys.get_state(name)
    :ok
  end

  defp session(db, key, owner, overrides \\ %{}) do
    input = %{
      session_key: key,
      display_name: key,
      owner_user_id: owner,
      origin: "user:#{owner}",
      archetype: "default",
      harness: "claude",
      provider: "anthropic",
      model: Model.new("fable"),
      host: "eezo"
    }

    Org.create(db, Map.merge(input, overrides))
  end
end
