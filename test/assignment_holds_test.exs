defmodule Tightbeam.AssignmentHoldsTest do
  use Tightbeam.TestCase, async: false

  alias Tightbeam.{
    Assignments,
    ConditionFacts,
    DB,
    Escalation,
    Gateway,
    Model,
    Org,
    Supervision,
    Wakes
  }

  setup do
    db = String.to_atom("assignment_hold_#{System.unique_integer([:positive])}")
    start_supervised!({DB, path: ":memory:", name: db})
    ensure_all_schemas(db)

    {:ok, _} =
      DB.query(
        db,
        "INSERT INTO users(userId,isAdmin,createdAt) VALUES ('flynn',1,1),('other',0,1)"
      )

    main = ensure_main_session(db, "flynn")
    holder = session(db, "holder", "flynn")
    opener = session(db, "opener", "flynn")
    sibling = session(db, "sibling", "other")

    {:ok, _} =
      DB.query(
        db,
        "INSERT INTO assignments(id,subject,holderKey,openedBySession,openedAt,state) VALUES ('asg_hold','held work',?1,?2,1,'open')",
        [holder.session_key, opener.session_key]
      )

    handlers = Gateway.handlers(%{db: db, wake_tick_ms: 1_000})
    %{db: db, main: main, holder: holder, opener: opener, sibling: sibling, handlers: handlers}
  end

  test "T1/T5 hold is durable and visible and suppresses only inactivity for ten periods",
       ctx do
    open_deadline(ctx.db, 1, 1_000)

    explicit =
      Wakes.schedule(ctx.db, %{
        session_key: ctx.holder.session_key,
        origin: "user:flynn",
        prompt: "explicit work notice",
        assignment_id: "asg_hold",
        due_at: 9_999_999_999_999
      })

    [holder_reminder, climb_copy] =
      for {session_key, prompt} <- [
            {ctx.holder.session_key, "inactivity holder reminder"},
            {ctx.opener.session_key, "inactivity climb copy"}
          ] do
        Wakes.schedule(ctx.db, %{
          session_key: session_key,
          origin: "process:tightbeam",
          prompt: prompt,
          assignment_id: "asg_hold",
          obligation_ref: "assignment-inactivity-episode-v1:fixture",
          due_at: 9_999_999_999_999
        })
      end

    hold = hold(ctx, {:session, ctx.holder.session_key}, "held", "hold-key")
    assert String.starts_with?(hold.id, "hold_")
    assert hold.assignmentId == "asg_hold"
    assert hold.kind == "held"
    assert hold.reason == "intentional pause"
    assert hold.releaseCondition == "owner resumes the duty"
    assert hold.releaseFactKind == nil
    assert hold.releaseFactScope == nil
    assert hold.releaseFactPrincipalRef == nil
    assert hold.imposedByRef == "session:#{ctx.holder.session_key}"
    assert is_integer(hold.imposedAt)
    assert hold.releasedAt == nil
    assert hold.releasedByRef == nil
    assert hold.releaseKind == nil
    assert hold.heldForMs >= 0

    assert hold(ctx, {:session, ctx.holder.session_key}, "held", "hold-key").id == hold.id
    assert %{code: "hold_active"} = hold(ctx, {:user, "flynn"}, "held", nil)

    read = get(ctx)
    assert read.hold.id == hold.id
    assert [history] = read.holds
    assert history.id == hold.id
    assert [%{id: "asg_hold", hold: %{id: hold_id}}] = list(ctx, true)
    assert hold_id == hold.id

    assert {:ok, [[0]]} =
             DB.query(
               ctx.db,
               "SELECT COUNT(*) FROM wakes WHERE assignmentId='asg_hold' AND state='pending' AND consumer IN ('assignment_inactivity_deadline','assignment_inactivity_climb')"
             )

    assert Wakes.get(ctx.db, explicit.wake_id).state == "pending"
    assert Wakes.get(ctx.db, holder_reminder.wake_id).state == "canceled"
    assert Wakes.get(ctx.db, climb_copy.wake_id).state == "canceled"

    wake_count = assignment_wake_count(ctx.db, "asg_hold")
    for _ <- 1..10, do: assert(:ok == Supervision.migrate_open_assignments(ctx.db, 1_000))
    assert assignment_wake_count(ctx.db, "asg_hold") == wake_count
    assert pending_count(ctx.db, "asg_hold", "assignment_inactivity_deadline") == 0
    assert pending_count(ctx.db, "asg_hold", "assignment_inactivity_climb") == 0

    assert {:ok, [[marker]]} =
             DB.query(
               ctx.db,
               "SELECT content FROM messages WHERE sessionKey=?1 AND content LIKE '[assignment held:%'",
               [ctx.holder.session_key]
             )

    assert marker ==
             "[assignment held: asg_hold #{hold.id} held by session:#{ctx.holder.session_key}]"

    assert {:ok, [[1]]} =
             DB.query(
               ctx.db,
               "SELECT COUNT(*) FROM lifecycle_events WHERE kind='assignment_hold_imposed' AND subject=?1",
               [hold.id]
             )
  end

  test "authorization, validation and closed assignment refusals are explicit", ctx do
    assert %{code: "hold_not_authorized"} =
             hold(ctx, {:session, ctx.sibling.session_key}, "held", nil)

    assert %{code: "hold_not_authorized"} = hold(ctx, {:process, "fixture"}, "held", nil)

    assert %{code: "invalid_hold", message: message} =
             hold(ctx, {:user, "flynn"}, "standing", nil, %{
               release_fact_kind: "ready",
               release_fact_scope: "scope",
               release_fact_principal_ref: "user:flynn"
             })

    assert message =~ "standing"

    assert %{code: "invalid_hold"} =
             hold(ctx, {:user, "flynn"}, "held", nil, %{release_fact_kind: "ready"})

    assert %{code: "no_active_hold", message: no_hold_message} =
             release(ctx, {:user, "flynn"}, "nothing to release", nil)

    assert no_hold_message =~ "assignment-get"

    reason = String.duplicate("x", 2_000)
    assert %{reason: ^reason} = hold(ctx, {:user, "flynn"}, "held", nil, %{reason: " #{reason} "})

    assert %{state: "closed"} =
             Assignments.__handle__(ctx.db, "revoke-assignment", %{
               principal: {:session, ctx.holder.session_key},
               origin: "agent:#{ctx.holder.session_key}",
               params: %{assignment_id: "asg_hold", reason: "scope withdrawn"}
             })

    assert %{code: "assignment_not_open"} = hold(ctx, {:user, "flynn"}, "held", nil)
  end

  test "explicit and fact releases rearm a fresh episode and closure never restores a hold",
       ctx do
    held = hold(ctx, {:session, ctx.opener.session_key}, "held", nil)
    before_release = System.system_time(:millisecond)

    assert %{code: "hold_not_authorized"} =
             release(ctx, {:session, ctx.sibling.session_key}, "not mine", nil)

    assert %{code: "hold_not_authorized"} =
             release(ctx, {:process, "fixture"}, "not a judgment principal", nil)

    released =
      release(ctx, {:session, ctx.opener.session_key}, "condition cleared", "release-key")

    assert released.id == held.id
    assert released.releaseKind == "released"
    assert released.releasedByRef == "session:#{ctx.opener.session_key}"
    assert released.releaseNote == "condition cleared"

    assert List.last(release_markers(ctx)) ==
             "[assignment hold released: asg_hold #{held.id} released by session:#{ctx.opener.session_key}]"

    assert release(ctx, {:session, ctx.opener.session_key}, "condition cleared", "release-key").id ==
             released.id

    assert get(ctx).hold == nil
    assert deadline(ctx.db).due_at >= before_release + 1_800_000

    fact_hold =
      hold(ctx, {:user, "flynn"}, "held", nil, %{
        release_fact_kind: "ready",
        release_fact_scope: "lane",
        release_fact_principal_ref: "user:flynn"
      })

    ConditionFacts.file(ctx.db, :missing_assignment_hold_scheduler, %{
      kind: "ready",
      scope: "lane",
      origin: "user:other"
    })

    assert get(ctx).hold.id == fact_hold.id

    fact =
      ConditionFacts.file(ctx.db, :missing_assignment_hold_scheduler, %{
        kind: "ready",
        scope: "lane",
        origin: "user:flynn"
      })

    assert get(ctx).hold == nil
    [fact_history | _] = get(ctx).holds
    assert fact_history.releaseKind == "release-fact"
    assert fact_history.releaseFactId == fact.fact_id

    assert List.last(release_markers(ctx)) ==
             "[assignment hold released: asg_hold #{fact_hold.id} release-fact by user:flynn fact #{fact.fact_id}]"

    closing = hold(ctx, {:user, "flynn"}, "standing", nil)

    assert %{state: "closed"} =
             Assignments.__handle__(ctx.db, "revoke-assignment", %{
               principal: {:session, ctx.holder.session_key},
               origin: "agent:#{ctx.holder.session_key}",
               params: %{assignment_id: "asg_hold", reason: "retire standing duty"}
             })

    [closed_history | _] = get(ctx).holds
    assert closed_history.id == closing.id
    assert closed_history.releaseKind == "assignment-closed"
    assert closed_history.releasedByRef == "process:tightbeam"

    assert List.last(release_markers(ctx)) ==
             "[assignment hold released: asg_hold #{closing.id} assignment-closed by process:tightbeam]"

    assert %{state: "open"} =
             Assignments.__handle__(ctx.db, "reopen-assignment", %{
               principal: {:session, ctx.holder.session_key},
               origin: "agent:#{ctx.holder.session_key}",
               supervision_interval_ms: 1_000,
               params: %{assignment_id: "asg_hold", reason: "new duty"}
             })

    assert get(ctx).hold == nil
  end

  test "T2 rejects standing fact tuples, partial tuples, and blank required text without rows",
       ctx do
    invalid = [
      %{
        kind: "standing",
        release_fact_kind: "ready",
        release_fact_scope: "lane",
        release_fact_principal_ref: "user:flynn"
      },
      %{kind: "held", release_fact_kind: "ready"},
      %{kind: "held", release_fact_kind: "ready", release_fact_scope: "lane"},
      %{kind: "held", reason: "   "},
      %{kind: "held", release: "\t"}
    ]

    Enum.each(invalid, fn params ->
      kind = Map.fetch!(params, :kind)
      extra = Map.delete(params, :kind)
      assert %{code: "invalid_hold"} = hold(ctx, {:user, "flynn"}, kind, nil, extra)
    end)

    assert {:ok, [[0]]} = DB.query(ctx.db, "SELECT COUNT(*) FROM assignment_hold")
  end

  test "T4 permits holder, opener session, opener user and org users but denies other principals",
       ctx do
    permitted = [
      {:session, ctx.holder.session_key},
      {:session, ctx.opener.session_key},
      {:user, "flynn"},
      {:user, "other"}
    ]

    Enum.with_index(permitted, fn principal, index ->
      imposed = hold(ctx, principal, "held", "t4-impose-#{index}")
      assert imposed.imposedByRef == principal_ref(principal)
      released = release(ctx, principal, "authorized release", "t4-release-#{index}")
      assert released.releasedByRef == principal_ref(principal)
    end)

    for principal <- [{:session, ctx.sibling.session_key}, {:process, "fixture"}] do
      assert %{code: "hold_not_authorized"} = hold(ctx, principal, "held", nil)
      hold(ctx, {:user, "flynn"}, "held", nil)
      assert %{code: "hold_not_authorized"} = release(ctx, principal, "denied", nil)
      release(ctx, {:user, "flynn"}, "cleanup", nil)
    end
  end

  test "T6 hold wins over a deadline already due in the imposition window", ctx do
    open_deadline(ctx.db, 1, 1_000)
    due = deadline(ctx.db)
    assert {:ok, _} = DB.query(ctx.db, "UPDATE wakes SET dueAt=0 WHERE wakeId=?1", [due.wake_id])

    hold(ctx, {:session, ctx.holder.session_key}, "held", nil)
    assert {:ok, :ok} = Supervision.deadline(ctx.db, Wakes.get(ctx.db, due.wake_id))

    assert prompt_count(ctx.db, "asg_hold") == 0
    assert pending_count(ctx.db, "asg_hold", "assignment_inactivity_deadline") == 0
  end

  test "T7 release starts a fresh quiet period and fresh reminder ladder", ctx do
    old = System.system_time(:millisecond) - 10_800_000
    open_deadline(ctx.db, old, 1_000)

    # Create pre-hold history and leave its first climb pending. Imposition must
    # cancel both without allowing the old reminder to consume the new episode's limit.
    fire_next(ctx.db, "asg_hold", "assignment_inactivity_deadline")
    assert prompt_count(ctx.db, "asg_hold") == 1
    assert pending_count(ctx.db, "asg_hold", "assignment_inactivity_climb") == 1

    hold(ctx, {:user, "flynn"}, "held", nil)
    released = release(ctx, {:user, "flynn"}, "resume", nil)
    fresh_deadline = deadline(ctx.db)
    period = fresh_deadline.due_at - released.releasedAt
    assert period > 0

    assert {:ok, _} =
             DB.query(ctx.db, "UPDATE wakes SET dueAt=?2 WHERE wakeId=?1", [
               fresh_deadline.wake_id,
               System.system_time(:millisecond) + period
             ])

    assert {:ok, {:deferred, :deadline_moved}} =
             Supervision.deadline(ctx.db, Wakes.get(ctx.db, fresh_deadline.wake_id))

    assert prompt_count(ctx.db, "asg_hold") == 1

    elapsed_release = System.system_time(:millisecond) - period - 1

    assert {:ok, _} =
             DB.query(ctx.db, "UPDATE assignment_hold SET releasedAt=?2 WHERE id=?1", [
               released.id,
               elapsed_release
             ])

    assert {:ok, _} =
             DB.query(
               ctx.db,
               "UPDATE wakes SET createdAt=?2 WHERE assignmentId='asg_hold' AND wakeId!=?1 AND consumer IN ('prompt','assignment_inactivity_climb')",
               [fresh_deadline.wake_id, elapsed_release - 2 * period]
             )

    assert {:ok, _} =
             DB.query(
               ctx.db,
               "UPDATE wakes SET prompt=json_set(prompt,'$.activityAt',?2) WHERE wakeId=?1",
               [fresh_deadline.wake_id, elapsed_release]
             )

    fire_next(ctx.db, "asg_hold", "assignment_inactivity_deadline")
    assert prompt_count(ctx.db, "asg_hold") == 2
    assert pending_count(ctx.db, "asg_hold", "assignment_inactivity_climb") == 1

    # The first fresh climb advances normally instead of stopping at the old limit.
    fire_next(ctx.db, "asg_hold", "assignment_inactivity_climb")
    assert pending_count(ctx.db, "asg_hold", "assignment_inactivity_climb") == 1
  end

  test "T9 completion and revocation release holds in the closing transaction and reopen is clear",
       ctx do
    hold(ctx, {:user, "flynn"}, "held", nil)

    assert {:ok, _} =
             DB.query(
               ctx.db,
               "INSERT INTO assignment_effects(assignmentId,effectKind) VALUES ('asg_hold','coordination')"
             )

    completed =
      ctx.handlers["attest"].(%{
        principal: {:session, ctx.holder.session_key},
        origin: "agent:#{ctx.holder.session_key}",
        params: %{assignment_id: "asg_hold", kind: "completion"}
      })

    assert completed.assignment.state == "closed"
    assert completed.assignment.outcome == "completed"
    assert [history | _] = get(ctx).holds
    assert history.releaseKind == "assignment-closed"

    assert %{state: "open"} =
             Assignments.__handle__(ctx.db, "reopen-assignment", %{
               principal: {:session, ctx.holder.session_key},
               origin: "agent:#{ctx.holder.session_key}",
               supervision_interval_ms: 1_000,
               params: %{assignment_id: "asg_hold", reason: "new episode"}
             })

    assert get(ctx).hold == nil

    hold(ctx, {:user, "flynn"}, "held", nil)

    assert %{state: "closed"} =
             Assignments.__handle__(ctx.db, "revoke-assignment", %{
               principal: {:session, ctx.holder.session_key},
               origin: "agent:#{ctx.holder.session_key}",
               params: %{assignment_id: "asg_hold", reason: "withdrawn"}
             })

    assert [revoked | _] = get(ctx).holds
    assert revoked.releaseKind == "assignment-closed"
  end

  test "T10 hold preserves decision, terminal-action, dependency and explicit wakes row for row",
       ctx do
    insert_assignment(ctx, "asg_control", "control")

    kinds = [
      {"decision", "cannot-proceed decision", "decision-request:fixture"},
      {"terminal", "completion handoff", "completion-handoff:fixture"},
      {"dependency", "dependency ready", "dependency-wait:fixture"},
      {"explicit", "explicit assignment wake", nil}
    ]

    for assignment_id <- ["asg_hold", "asg_control"],
        {kind, prompt, obligation_ref} <- kinds do
      Wakes.schedule(ctx.db, %{
        session_key: ctx.holder.session_key,
        origin: "process:tightbeam",
        prompt: prompt,
        class: if(kind == "decision", do: "input-needed", else: "fyi"),
        assignment_id: assignment_id,
        obligation_ref: obligation_ref,
        due_at: 9_999_999_999_999
      })
    end

    hold(ctx, {:user, "flynn"}, "held", nil)

    assert non_inactivity_wakes(ctx.db, "asg_hold") ==
             non_inactivity_wakes(ctx.db, "asg_control")

    # Later child/result, decision settlement, cannot-proceed settlement and
    # handoff-discharge traffic remains ordinary traffic on both cards.
    for {suffix, prompt} <- [
          {"child", "child completed"},
          {"answer", "decision answered"},
          {"fact", "cannot-proceed released"},
          {"handoff", "completion-handoff-action accepted"}
        ],
        assignment_id <- ["asg_hold", "asg_control"] do
      Wakes.schedule(ctx.db, %{
        session_key: ctx.holder.session_key,
        origin: "process:tightbeam",
        prompt: prompt,
        class: "fyi",
        assignment_id: assignment_id,
        obligation_ref: "fixture:#{suffix}",
        due_at: 9_999_999_999_999
      })
    end

    assert non_inactivity_wakes(ctx.db, "asg_hold") ==
             non_inactivity_wakes(ctx.db, "asg_control")
  end

  test "T11 answered cannot-proceed can be held while an unheld control resumes", ctx do
    insert_assignment(ctx, "asg_control", "control")
    open_deadline_for(ctx.db, "asg_hold", 1, 1_000)
    open_deadline_for(ctx.db, "asg_control", 1, 1_000)

    blocked = file_cannot_proceed(ctx, "asg_hold", "answer clears subject")
    control = file_cannot_proceed(ctx, "asg_control", "answer clears control")
    answer(ctx, blocked.decisionRequest.id)
    answer(ctx, control.decisionRequest.id)

    hold(ctx, {:user, "flynn"}, "held", nil)
    assert get(ctx).hold.kind == "held"

    assert pending_count(ctx.db, "asg_hold", "assignment_inactivity_deadline") == 0
    assert prompt_count(ctx.db, "asg_hold") == 0

    assert {:ok, [[settled_at, due_at, prompt]]} =
             DB.query(
               ctx.db,
               """
               SELECT cp.settledAt,w.dueAt,w.prompt
               FROM assignment_cannot_proceed cp
               JOIN wakes w ON w.assignmentId=cp.assignmentId
               WHERE cp.assignmentId='asg_control'
                 AND w.consumer='assignment_inactivity_deadline' AND w.state='pending'
               ORDER BY w.createdAt DESC LIMIT 1
               """
             )

    assert due_at > settled_at
    assert JSON.decode!(prompt)["activityAt"] >= settled_at
  end

  test "T12 standing cannot-proceed alone suppresses ten periods of reminders and climbs", ctx do
    blocked = file_cannot_proceed(ctx, "asg_hold", "standing dependency")
    assert blocked.cannotProceed.state == "standing"

    for _ <- 1..10 do
      case pending_count(ctx.db, "asg_hold", "assignment_inactivity_deadline") do
        0 -> :ok
        _ -> fire_next(ctx.db, "asg_hold", "assignment_inactivity_deadline")
      end
    end

    assert get(ctx).hold == nil
    assert prompt_count(ctx.db, "asg_hold") == 0
    assert pending_count(ctx.db, "asg_hold", "assignment_inactivity_climb") == 0
  end

  test "T13 standing holds preserve repeated child-result notices and suppress inactivity", ctx do
    hold(ctx, {:user, "flynn"}, "standing", nil)

    notices =
      for n <- 1..3 do
        Wakes.schedule(ctx.db, %{
          session_key: ctx.holder.session_key,
          origin: "agent:child-#{n}",
          prompt: "child result #{n}",
          assignment_id: "asg_hold",
          due_at: 0
        })
      end

    assert Enum.all?(notices, &(Wakes.get(ctx.db, &1.wake_id).state == "pending"))
    assert get(ctx).hold.kind == "standing"
    assert prompt_count(ctx.db, "asg_hold", "assignment-inactivity-episode-v1:%") == 0
    assert pending_count(ctx.db, "asg_hold", "assignment_inactivity_deadline") == 0
  end

  test "T14 held listing returns held, standing and cannot-proceed cards only", ctx do
    insert_assignment(ctx, "asg_standing", "standing")
    insert_assignment(ctx, "asg_blocked", "blocked")
    insert_assignment(ctx, "asg_unheld", "unheld")

    held = hold(ctx, {:user, "flynn"}, "held", nil)
    standing = hold_for(ctx, "asg_standing", {:user, "flynn"}, "standing")
    blocked = file_cannot_proceed(ctx, "asg_blocked", "waiting")

    rows = list(ctx, true)
    assert Enum.map(rows, & &1.id) |> Enum.sort() == ~w(asg_blocked asg_hold asg_standing)

    by_id = Map.new(rows, &{&1.id, &1})
    assert by_id["asg_hold"].hold.id == held.id
    assert by_id["asg_standing"].hold.id == standing.id
    assert by_id["asg_blocked"].hold == nil
    assert by_id["asg_blocked"].cannotProceed.id == blocked.cannotProceed.id
    assert by_id["asg_hold"].hold.heldForMs >= 0
    assert by_id["asg_standing"].hold.heldForMs >= 0
  end

  test "T15 boot reconciliation cancels stale climbs for active holds and restores no controller",
       ctx do
    stale =
      Wakes.schedule(ctx.db, %{
        session_key: ctx.holder.session_key,
        origin: "process:tightbeam",
        consumer: "assignment_inactivity_climb",
        prompt: ~s({"version":1}),
        assignment_id: "asg_hold",
        obligation_ref: "assignment-inactivity-episode-v1:stale",
        due_at: 0
      })

    hold(ctx, {:user, "flynn"}, "held", nil)
    assert :ok = Supervision.migrate_open_assignments(ctx.db, 1_000)
    assert Wakes.get(ctx.db, stale.wake_id).state == "canceled"
    assert pending_count(ctx.db, "asg_hold", "assignment_inactivity_deadline") == 0
    assert pending_count(ctx.db, "asg_hold", "assignment_inactivity_climb") == 0

    assert {:ok, [["assignment_hold"]]} =
             DB.query(
               ctx.db,
               "SELECT name FROM sqlite_master WHERE type='table' AND name='assignment_hold'"
             )
  end

  test "T16 thirty mocked days of an active hold create no hold-originated wakes", ctx do
    imposed = hold(ctx, {:user, "flynn"}, "held", nil)
    thirty_days = 30 * 24 * 60 * 60 * 1_000

    assert {:ok, _} =
             DB.query(ctx.db, "UPDATE assignment_hold SET imposedAt=imposedAt-?1", [thirty_days])

    assert get(ctx).hold.heldForMs >= thirty_days

    assert :ok = Supervision.migrate_open_assignments(ctx.db, 1_000)

    assert assignment_wake_count(ctx.db, "asg_hold") == 0

    assert get(ctx).hold.id == imposed.id
  end

  test "schema upgrade is stamped and idempotent", ctx do
    assert :ok = Tightbeam.Schema.ensure_all(ctx.db)
    assert :ok = Tightbeam.Schema.ensure_all(ctx.db)

    assert {:ok, [["assignment-hold-v1-015"]]} =
             DB.query(ctx.db, "SELECT shape FROM schema_stamp")

    assert {:ok, [[0]]} = DB.query(ctx.db, "SELECT COUNT(*) FROM assignment_hold")
  end

  test "a damaged current hold shape refuses instead of recreating storage", ctx do
    assert :ok = DB.execute(ctx.db, "DROP TABLE assignment_hold")

    assert_raise Tightbeam.Schema.ShapeError, ~r/assignment hold migration rolled back/, fn ->
      Tightbeam.Schema.ensure_all(ctx.db)
    end

    assert {:ok, []} =
             DB.query(
               ctx.db,
               "SELECT name FROM sqlite_master WHERE type='table' AND name='assignment_hold'"
             )
  end

  test "a stamped hold table with altered constraints is refused", ctx do
    assert {:ok, [[sql]]} =
             DB.query(
               ctx.db,
               "SELECT sql FROM sqlite_master WHERE type='table' AND name='assignment_hold'"
             )

    altered =
      String.replace(
        sql,
        "kind IN ('held','standing')",
        "kind IN ('held','standing','unknown')"
      )

    assert altered != sql

    assert {:ok, :ok} =
             DB.migration_transaction(
               ctx.db,
               :damage_assignment_hold_shape,
               [],
               ["PRAGMA writable_schema=OFF"],
               fn txn ->
                 [[version]] = Tightbeam.DB.Txn.q(txn, "PRAGMA schema_version")
                 :ok = Tightbeam.DB.Txn.exec(txn, "PRAGMA writable_schema=ON")

                 Tightbeam.DB.Txn.q(
                   txn,
                   "UPDATE sqlite_master SET sql=?1 WHERE type='table' AND name='assignment_hold'",
                   [altered]
                 )

                 :ok = Tightbeam.DB.Txn.exec(txn, "PRAGMA schema_version=#{version + 1}")
                 :ok = Tightbeam.DB.Txn.exec(txn, "PRAGMA writable_schema=RESET")
               end
             )

    assert_raise Tightbeam.Schema.ShapeError, ~r/assignment hold migration rolled back/, fn ->
      Tightbeam.Schema.ensure_all(ctx.db)
    end
  end

  defp hold(ctx, principal, kind, key, extra \\ %{}) do
    hold_for(ctx, "asg_hold", principal, kind, key, extra)
  end

  defp hold_for(ctx, assignment_id, principal, kind, key \\ nil, extra \\ %{}) do
    ctx.handlers["assignment-hold"].(%{
      principal: principal,
      origin: origin(principal),
      params:
        Map.merge(
          %{
            assignment_id: assignment_id,
            kind: kind,
            reason: "intentional pause",
            release: "owner resumes the duty",
            release_fact_kind: nil,
            release_fact_scope: nil,
            release_fact_principal_ref: nil,
            idempotency_key: key
          },
          extra
        )
    })
  end

  defp release(ctx, principal, reason, key) do
    ctx.handlers["assignment-release-hold"].(%{
      principal: principal,
      origin: origin(principal),
      params: %{assignment_id: "asg_hold", reason: reason, idempotency_key: key}
    })
  end

  defp get(ctx) do
    ctx.handlers["assignment-get"].(%{
      principal: {:user, "flynn"},
      params: %{assignment_id: "asg_hold", fact_id: nil}
    })
  end

  defp list(ctx, held) do
    ctx.handlers["assignments"].(%{
      principal: {:user, "flynn"},
      session_key: nil,
      params: %{state: "open", held: held}
    }).assignments
  end

  defp open_deadline(db, opened_at, interval) do
    open_deadline_for(db, "asg_hold", opened_at, interval)
  end

  defp open_deadline_for(db, assignment_id, opened_at, interval) do
    assert {:ok, :ok} =
             DB.transaction(db, fn txn ->
               Supervision.assignment_opened_in_txn(txn, assignment_id, opened_at, interval)
             end)
  end

  defp insert_assignment(ctx, id, subject) do
    assert {:ok, _} =
             DB.query(
               ctx.db,
               "INSERT INTO assignments(id,subject,holderKey,openedBySession,openedAt,state) VALUES (?1,?2,?3,?4,1,'open')",
               [id, subject, ctx.holder.session_key, ctx.opener.session_key]
             )
  end

  defp file_cannot_proceed(ctx, assignment_id, note) do
    ctx.handlers["attest"].(%{
      principal: {:session, ctx.holder.session_key},
      origin: "agent:#{ctx.holder.session_key}",
      params: %{assignment_id: assignment_id, kind: "cannot-proceed", note: note}
    })
  end

  defp answer(ctx, request_id) do
    assert %{status: "answered"} =
             Escalation.answer(ctx.db, %{
               verb: "answer",
               principal: {:user, "flynn"},
               origin: "user:flynn",
               params: %{request: request_id, answer: "Resume the work"}
             })
  end

  defp non_inactivity_wakes(db, assignment_id) do
    {:ok, rows} =
      DB.query(
        db,
        """
        SELECT sessionKey,origin,prompt,consumer,state,class,obligationRef,dueAt
        FROM wakes WHERE assignmentId=?1
          AND consumer NOT IN ('assignment_inactivity_deadline','assignment_inactivity_climb')
          AND COALESCE(obligationRef,'') NOT LIKE 'assignment-inactivity-episode-v1:%'
        ORDER BY prompt,consumer,sessionKey
        """,
        [assignment_id]
      )

    rows
  end

  defp deadline(db) do
    {:ok, [[id]]} =
      DB.query(
        db,
        "SELECT wakeId FROM wakes WHERE assignmentId='asg_hold' AND consumer='assignment_inactivity_deadline' AND state='pending' ORDER BY createdAt DESC LIMIT 1"
      )

    Wakes.get(db, id)
  end

  defp fire_next(db, assignment_id, consumer) do
    {:ok, [[wake_id]]} =
      DB.query(
        db,
        "SELECT wakeId FROM wakes WHERE assignmentId=?1 AND consumer=?2 AND state='pending' ORDER BY dueAt,wakeId LIMIT 1",
        [assignment_id, consumer]
      )

    assert {:ok, _} = DB.query(db, "UPDATE wakes SET dueAt=0 WHERE wakeId=?1", [wake_id])
    wake = Wakes.get(db, wake_id)

    assert {:ok, _} =
             if(consumer == "assignment_inactivity_deadline",
               do: Supervision.deadline(db, wake),
               else: Supervision.climb(db, wake)
             )
  end

  defp pending_count(db, assignment_id, consumer) do
    {:ok, [[count]]} =
      DB.query(
        db,
        "SELECT COUNT(*) FROM wakes WHERE assignmentId=?1 AND consumer=?2 AND state='pending'",
        [assignment_id, consumer]
      )

    count
  end

  defp assignment_wake_count(db, assignment_id) do
    {:ok, [[count]]} =
      DB.query(db, "SELECT COUNT(*) FROM wakes WHERE assignmentId=?1", [assignment_id])

    count
  end

  defp prompt_count(db, assignment_id, pattern \\ "assignment-inactivity-episode-v1:%") do
    {:ok, [[count]]} =
      DB.query(
        db,
        "SELECT COUNT(*) FROM wakes WHERE assignmentId=?1 AND consumer='prompt' AND obligationRef LIKE ?2",
        [assignment_id, pattern]
      )

    count
  end

  defp release_markers(ctx) do
    {:ok, rows} =
      DB.query(
        ctx.db,
        "SELECT content FROM messages WHERE sessionKey=?1 AND content LIKE '[assignment hold released:%' ORDER BY timestamp,id",
        [ctx.holder.session_key]
      )

    List.flatten(rows)
  end

  defp session(db, key, owner) do
    Org.create(db, %{
      session_key: key,
      display_name: key,
      kind: "custom",
      owner_user_id: owner,
      origin: "user:#{owner}",
      archetype: "default",
      harness: "claude",
      provider: "anthropic",
      model: Model.new("fable"),
      host: "testhost"
    })
  end

  defp origin({:session, key}), do: "agent:#{key}"
  defp origin({:user, id}), do: "user:#{id}"
  defp origin({:process, id}), do: "process:#{id}"

  defp principal_ref({:session, key}), do: "session:#{key}"
  defp principal_ref({:user, id}), do: "user:#{id}"
end
