defmodule Tightbeam.AssignmentHoldsTest do
  use Tightbeam.TestCase, async: false

  alias Tightbeam.{Assignments, ConditionFacts, DB, Gateway, Model, Org, Supervision, Wakes}

  setup do
    db = String.to_atom("assignment_holds_#{System.unique_integer([:positive])}")
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

  test "hold is durable, visible and withdraws only assignment inactivity sources", ctx do
    open_deadline(ctx.db, 1, 1_000)

    explicit =
      Wakes.schedule(ctx.db, %{
        session_key: ctx.holder.session_key,
        origin: "user:flynn",
        prompt: "explicit work notice",
        assignment_id: "asg_hold",
        due_at: 9_999_999_999_999
      })

    hold = hold(ctx, {:session, ctx.holder.session_key}, "held", "hold-key")
    assert String.starts_with?(hold.id, "hold_")
    assert hold.assignmentId == "asg_hold"
    assert hold.imposedByRef == "session:#{ctx.holder.session_key}"
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

  test "schema upgrade is stamped and idempotent", ctx do
    assert :ok = Tightbeam.Schema.ensure_all(ctx.db)
    assert :ok = Tightbeam.Schema.ensure_all(ctx.db)

    assert {:ok, [["assignment-hold-v1-015"]]} =
             DB.query(ctx.db, "SELECT shape FROM schema_stamp")

    assert {:ok, [[0]]} = DB.query(ctx.db, "SELECT COUNT(*) FROM assignment_holds")
  end

  defp hold(ctx, principal, kind, key, extra \\ %{}) do
    ctx.handlers["assignment-hold"].(%{
      principal: principal,
      origin: origin(principal),
      params:
        Map.merge(
          %{
            assignment_id: "asg_hold",
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
    assert {:ok, :ok} =
             DB.transaction(db, fn txn ->
               Supervision.assignment_opened_in_txn(txn, "asg_hold", opened_at, interval)
             end)
  end

  defp deadline(db) do
    {:ok, [[id]]} =
      DB.query(
        db,
        "SELECT wakeId FROM wakes WHERE assignmentId='asg_hold' AND consumer='assignment_inactivity_deadline' AND state='pending' ORDER BY createdAt DESC LIMIT 1"
      )

    Wakes.get(db, id)
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
end
