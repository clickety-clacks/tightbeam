defmodule Tightbeam.AssignmentsTest do
  use ExUnit.Case, async: false

  alias Tightbeam.{
    Assignments,
    DB,
    Devices,
    Dispatch,
    EventLog,
    Gateway,
    Idempotency,
    Org,
    Roles,
    Rules,
    WorkItems,
    WorkState
  }

  setup do
    db = :"assignments_db_#{System.unique_integer([:positive])}"
    start_supervised!({DB, path: ":memory:", name: db})

    for module <- [Devices, Idempotency, Org, Roles, WorkItems, Assignments, WorkState, EventLog] do
      :ok = module.ensure_schema(db)
    end

    {:ok, _} =
      DB.query(
        db,
        "INSERT INTO users (userId, isAdmin, createdAt) VALUES ('admin', 1, 1), ('flynn', 0, 1), ('other', 0, 1)"
      )

    holder = session(db, "holder", "flynn")
    other = session(db, "other-session", "other")
    Rules.load!(System.tmp_dir!(), Map.keys(Gateway.handlers(%{db: db})))
    %{db: db, holder: holder, other: other, handlers: Gateway.handlers(%{db: db})}
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

  test "assignment text limits use application config", ctx do
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

    assert %{code: "invalid_subject"} =
             handle(ctx, "assign", assign_call({:user, "flynn"}, "four"))

    assert %{code: "invalid_idempotency_key"} =
             handle(ctx, "assign", assign_call({:user, "flynn"}, "ok", "four"))

    assignment = handle(ctx, "assign", assign_call({:user, "flynn"}, "ok"))

    assert %{code: "invalid_note"} =
             ctx
             |> handle(
               "attest",
               put_in(
                 attest_call({:session, "holder"}, assignment.id, "progress"),
                 [:params, :note],
                 "four"
               )
             )

    assert %{code: "invalid_verdict_kind"} =
             ctx
             |> handle(
               "attest",
               put_in(
                 attest_call({:user, "flynn"}, assignment.id, "verdict"),
                 [:params, :verdict_kind],
                 "four"
               )
             )
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

    user_opened = handle(ctx, "assign", assign_call({:user, "flynn"}, "user work"))
    assert user_opened.openedByUser == "flynn"
    assert user_opened.openedBySession == nil
    assert user_opened.workItemId == nil

    session_opened = handle(ctx, "assign", assign_call({:session, "holder"}, "session work"))
    assert session_opened.openedBySession == "holder"
    assert session_opened.openedByUser == nil

    role_call =
      assign_call({:user, "flynn"}, "role work")
      |> Map.merge(%{target_role: "builder", role_fallback: true})

    role_opened = handle(ctx, "assign", role_call)
    assert role_opened.holderRole == "builder"
    assert role_opened.holderFallback

    Org.retire(ctx.db, "other-session")

    assert %{code: "session_retired"} =
             handle(ctx, "assign", %{assign_call({:user, "flynn"}) | session_key: "other-session"})

    call = assign_call({:user, "flynn"}, "once", "same-key")
    tasks = for _ <- 1..2, do: Task.async(fn -> handle(ctx, "assign", call) end)
    [one, two] = Task.await_many(tasks)
    assert one.id == two.id

    assert {:ok, [[1]]} =
             DB.query(ctx.db, "SELECT count(*) FROM assignments WHERE subject = 'once'")
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

  test "attest-era database gains nullable workItemId additively and idempotently" do
    db = :"assignment_migration_db_#{System.unique_integer([:positive])}"

    start_supervised!(%{
      id: db,
      start: {DB, :start_link, [[path: ":memory:", name: db]]}
    })

    :ok = WorkItems.ensure_schema(db)

    :ok =
      DB.execute(db, """
      CREATE TABLE assignments (
        id TEXT PRIMARY KEY, subject TEXT NOT NULL, holderKey TEXT NOT NULL,
        holderRole TEXT NULL, holderFallback INTEGER NOT NULL DEFAULT 0,
        openedByUser TEXT NULL, openedBySession TEXT NULL, openedAt INTEGER NOT NULL,
        state TEXT NOT NULL DEFAULT 'open', outcome TEXT NULL, closedAt INTEGER NULL,
        closedByUser TEXT NULL, closedBySession TEXT NULL, closingAttestId TEXT NULL
      )
      """)

    {:ok, _} =
      DB.query(
        db,
        "INSERT INTO assignments (id, subject, holderKey, openedByUser, openedAt) VALUES ('asg_old', 'old', 'holder', 'flynn', 1)"
      )

    :ok = Assignments.ensure_schema(db)
    :ok = Assignments.ensure_schema(db)
    assert [%{id: "asg_old", workItemId: nil}] = Assignments.list(db, %{state: "all"})
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

  test "accepted handler commit survives event append failure", ctx do
    {:ok, _} = DB.query(ctx.db, "DROP TABLE events")

    assert_raise MatchError, fn ->
      Dispatch.dispatch(ctx.db, ctx.handlers, assign_call({:session, "holder"}, "committed"))
    end

    assert {:ok, [[1]]} =
             DB.query(ctx.db, "SELECT count(*) FROM assignments WHERE subject = 'committed'")
  end

  defp handle(ctx, verb, call)
       when verb in ["assign", "attest", "revoke-assignment", "assignments"],
       do: Assignments.__handle__(ctx.db, verb, %{call | verb: verb})

  defp handle(ctx, verb, call), do: WorkItems.__handle__(ctx.db, verb, %{call | verb: verb})

  defp dispatch!(ctx, call) do
    assert {:ok, result} = Dispatch.dispatch(ctx.db, ctx.handlers, call)
    result
  end

  defp assign_call(principal, subject \\ "work", key \\ nil, work_item_id \\ nil) do
    call("assign", principal, "holder", %{
      subject: subject,
      idempotency_key: key,
      work_item_id: work_item_id
    })
    |> Map.merge(%{target_role: nil, role_fallback: false})
  end

  defp work_item_call(verb, principal, params), do: call(verb, principal, nil, params)

  defp attest_call(principal, id, kind),
    do: call("attest", principal, nil, %{assignment_id: id, kind: kind})

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

  defp session(db, key, owner) do
    Org.create(db, %{
      session_key: key,
      display_name: key,
      owner_user_id: owner,
      origin: "user:#{owner}",
      archetype: "default",
      harness: "claude",
      provider: "anthropic",
      model: "fable",
      host: "eezo"
    })
  end
end
