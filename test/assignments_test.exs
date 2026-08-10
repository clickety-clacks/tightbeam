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

    Enum.each(invalid, fn values ->
      assert {:error, %DB.Error{message: message}} = DB.query(db, base <> values)
      assert message =~ "CHECK constraint"
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

  test "same-assignment public cancellation and progress re-drive a forced due entitlement",
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

    first = handle(ctx, "attest", attest_call({:session, "holder"}, assignment.id, "progress"))
    first_attest_id = first.attest.id
    sweep_liveness!(liveness)

    assert %{
             supervisionGeneration: 2,
             supervisionBasisKind: "progress",
             supervisionBasisId: ^first_attest_id
           } = Supervision.prod_state(ctx.db, assignment.id)

    second = handle(ctx, "attest", attest_call({:session, "holder"}, assignment.id, "progress"))
    second_attest_id = second.attest.id
    sweep_liveness!(liveness)

    assert %{
             supervisionGeneration: 3,
             supervisionBasisKind: "progress",
             supervisionBasisId: ^second_attest_id
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

  test "assignment-get returns the full assignment row or not_found", ctx do
    assignment = handle(ctx, "assign", assign_call({:user, "flynn"}, "fetch me"))

    assert handle(
             ctx,
             "assignment-get",
             assignment_get_call({:session, "other-session"}, assignment.id)
           ) ==
             assignment

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

  test "declared files dedupe silently and overlap is transactionally serialized", ctx do
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
      assign_call({:user, "flynn"}, "overlap")
      |> put_in([:params, :files], ["lib/a.ex"])

    assert %{code: "files_overlap", message: message} = handle(ctx, "assign", overlapping)
    assert message =~ first.id

    assert {:ok, [[0]]} =
             DB.query(ctx.db, "SELECT count(*) FROM assignments WHERE subject = 'overlap'")

    malformed =
      assign_call({:user, "flynn"}, "malformed")
      |> put_in([:params, :files], ["ok", " "])

    assert %{code: "invalid_files"} = handle(ctx, "assign", malformed)

    assert {:ok, [[0]]} =
             DB.query(ctx.db, "SELECT count(*) FROM assignments WHERE subject = 'malformed'")

    no_files = handle(ctx, "assign", assign_call({:user, "flynn"}, "no files"))
    assert Assignments.declared_files(ctx.db, no_files.id) == []

    disjoint =
      for {subject, path} <- [{"disjoint one", "one"}, {"disjoint two", "two"}] do
        assign_call({:user, "flynn"}, subject)
        |> put_in([:params, :files], [path])
        |> then(&handle(ctx, "assign", &1))
      end

    assert Enum.all?(disjoint, &is_binary(&1.id))

    concurrent =
      for subject <- ["race one", "race two"] do
        Task.async(fn ->
          assign_call({:user, "flynn"}, subject)
          |> put_in([:params, :files], ["same-race-path"])
          |> then(&handle(ctx, "assign", &1))
        end)
      end
      |> Task.await_many()

    assert Enum.count(concurrent, &(&1[:code] == "files_overlap")) == 1
    assert Enum.count(concurrent, &is_binary(&1[:id])) == 1

    _closed = handle(ctx, "attest", attest_call({:session, "holder"}, first.id, "completion"))

    after_close =
      assign_call({:user, "flynn"}, "after close")
      |> put_in([:params, :files], ["lib/a.ex"])
      |> then(&handle(ctx, "assign", &1))

    assert is_binary(after_close.id)
  end

  test "verdict attests freeze provenance and project inert producer history columns", ctx do
    assignment = handle(ctx, "assign", assign_call({:user, "flynn"}, "verdict stamps"))

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

    _ = handle(ctx, "attest", third_party)

    user =
      attest_call({:user, "flynn"}, valid_review.id, "verdict")
      |> put_in([:params, :verdict_kind], "user-verdict")

    _ = handle(ctx, "attest", user)

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

  test "qualifying review verdict requires exactly one independent card and its latest holder verdict",
       ctx do
    producer = handle(ctx, "assign", assign_call({:user, "flynn"}, "qualifying producer"))

    review =
      assign_call({:user, "flynn"}, "qualifying review")
      |> Map.put(:session_key, "other-session")
      |> put_in([:params, :reviews_assignment_id], producer.id)
      |> then(&handle(ctx, "assign", &1))

    assert Assignments.qualifying_review_verdict_kinds(ctx.db, producer.id, "holder") == []

    _ =
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

    assert Assignments.qualifying_review_verdict_kinds(ctx.db, producer.id, "holder") == []

    _ =
      attest_call({:session, "other-session"}, review.id, "verdict")
      |> put_in([:params, :verdict_kind], "reviewed-clean")
      |> then(&handle(ctx, "attest", &1))

    assert Assignments.qualifying_review_verdict_kinds(ctx.db, producer.id, "holder") == []
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
    assignment = handle(ctx, "assign", assign_call({:session, "holder"}, "work"))

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

    race = handle(ctx, "assign", assign_call({:session, "holder"}, "race"))

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
    completed = handle(ctx, "assign", assign_call({:user, "flynn"}, "completed markers"))

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
    a = handle(ctx, "assign", assign_call({:user, "flynn"}, "a"))
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

  test "zero rules allow completion without verdicts and verdict emits one verb event", ctx do
    completion_assignment = dispatch!(ctx, assign_call({:session, "holder"}, "completion"))

    assert {:ok, %{assignment: closed, attest: completion}} =
             Dispatch.dispatch(
               ctx.db,
               ctx.handlers,
               attest_call({:session, "holder"}, completion_assignment.id, "completion")
             )

    assert closed.state == "closed"
    assert completion.verdictKind == nil
    assert completion.byUser == nil

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
              "assignments"
            ],
       do:
         Assignments.__handle__(
           ctx.db,
           verb,
           call
           |> Map.put(:verb, verb)
           |> then(fn routed ->
             if verb in ["assign", "dispatch"],
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
    do: call("revoke-assignment", principal, nil, %{assignment_id: id})

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
