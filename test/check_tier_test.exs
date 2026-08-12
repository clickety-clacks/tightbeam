defmodule Tightbeam.CheckTierTest do
  use Tightbeam.TestCase, async: false
  alias Tightbeam.Model

  alias Tightbeam.{
    Assignments,
    DB,
    Dispatch,
    Gateway,
    Org,
    Rules
  }

  setup do
    db = :"check_tier_db_#{System.unique_integer([:positive])}"
    start_supervised!({DB, path: ":memory:", name: db})

    :ok = Tightbeam.Schema.ensure_all(db)

    {:ok, _} =
      DB.query(
        db,
        "INSERT INTO users (userId, isAdmin, createdAt) VALUES ('flynn', 1, 1), ('other', 0, 1)"
      )

    holder = session(db, "holder", "flynn", "coder")
    reviewer = session(db, "reviewer", "other", "reviewer")
    base_dir = Path.join(System.tmp_dir!(), "check-tier-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(base_dir, "identity/rules"))
    on_exit(fn -> File.rm_rf!(base_dir) end)

    handlers = Gateway.handlers(%{db: db})
    Rules.load!(base_dir, Map.keys(handlers))
    %{db: db, holder: holder, reviewer: reviewer, base_dir: base_dir, handlers: handlers}
  end

  test "fresh schema enforces verdict and lifecycle row consistency", ctx do
    assignment = assign(ctx)

    invalid = [
      ["bad1", assignment.id, "verdict", nil, nil, "reviewer", nil, 1],
      ["bad2", assignment.id, "verdict", "tests-passed", nil, nil, nil, 1],
      ["bad3", assignment.id, "verdict", "tests-passed", nil, "reviewer", "other", 1],
      ["bad4", assignment.id, "progress", "tests-passed", nil, "holder", nil, 1],
      ["bad5", assignment.id, "progress", nil, nil, nil, "flynn", 1]
    ]

    Enum.each(invalid, fn params ->
      assert {:error, %DB.Error{message: message}} =
               DB.query(
                 ctx.db,
                 "INSERT INTO attests (id, assignmentId, kind, verdictKind, note, bySession, byUser, ts) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)",
                 params
               )

      assert message =~ "CHECK constraint"
    end)

    progress = attest(ctx, {:session, "holder"}, assignment.id, "progress")
    assert progress.attest.verdictKind == nil
    assert progress.attest.byUser == nil
    assert progress.attest.bySession == "holder"
  end

  test "producer-card verdict path accepts sessions and users, validates last, and never closes",
       ctx do
    assignment = assign(ctx)

    for principal <- [{:session, "reviewer"}, {:session, "holder"}, {:user, "flynn"}] do
      result = verdict(ctx, principal, assignment.id, "tests-passed")
      assert result.assignment.state == "open"
      assert result.attest.verdictKind == "tests-passed"

      case principal do
        {:session, key} ->
          assert result.attest.bySession == key
          assert result.attest.byUser == nil

        {:user, user} ->
          assert result.attest.bySession == nil
          assert result.attest.byUser == user
      end
    end

    assert length(Assignments.list_attests(ctx.db, assignment.id)) == 3
    assert Assignments.verdict_kinds(ctx.db, assignment.id) == ["tests-passed"]
    assert %{code: "process_denied"} = verdict(ctx, {:process, "cron"}, assignment.id, "reviewed")
    assert %{code: "principal_required"} = verdict(ctx, nil, assignment.id, "reviewed")

    assert %{code: "unknown_assignment"} =
             attest(ctx, {:session, "reviewer"}, "missing", "verdict", %{})

    assert %{code: "missing_verdict_kind"} =
             attest(ctx, {:session, "reviewer"}, assignment.id, "verdict", %{})

    for malformed <- ["Bad", "-bad", "bad_thing", String.duplicate("a", 65), 1] do
      assert %{code: "invalid_verdict_kind"} =
               attest(ctx, {:session, "reviewer"}, assignment.id, "verdict", %{
                 verdict_kind: malformed
               })
    end

    assert %{code: "invalid_note"} =
             attest(ctx, {:session, "reviewer"}, assignment.id, "verdict", %{
               verdict_kind: "reviewed",
               note: " "
             })

    assert %{code: "not_holder"} =
             attest(ctx, {:session, "reviewer"}, assignment.id, "progress", %{
               verdict_kind: "reviewed"
             })

    assert %{code: "invalid_verdict_kind"} =
             attest(ctx, {:session, "holder"}, assignment.id, "progress", %{
               verdict_kind: "reviewed"
             })

    closed = assign(ctx, "closed precedence")
    attest(ctx, {:session, "holder"}, closed.id, "completion")

    assert %{code: "assignment_closed"} =
             attest(ctx, {:session, "reviewer"}, closed.id, "verdict", %{
               verdict_kind: "Bad"
             })

    assert %{code: "assignment_closed"} =
             attest(ctx, {:session, "holder"}, closed.id, "progress", %{
               verdict_kind: "reviewed"
             })
  end

  test "verdict and revoke serialized orderings preserve the no-post-closure invariant", ctx do
    revoked_first = assign(ctx, "revoked first")
    assert %{outcome: "revoked"} = revoke(ctx, revoked_first.id)

    assert %{code: "assignment_closed"} =
             verdict(ctx, {:session, "reviewer"}, revoked_first.id, "reviewed")

    assert Assignments.verdict_kinds(ctx.db, revoked_first.id) == []

    verdict_first = assign(ctx, "verdict first")

    assert %{attest: %{kind: "verdict"}} =
             verdict(ctx, {:session, "reviewer"}, verdict_first.id, "reviewed")

    assert %{outcome: "revoked"} = revoke(ctx, verdict_first.id)
    assert Assignments.verdict_kinds(ctx.db, verdict_first.id) == ["reviewed"]
  end

  test "attests query authorizes principals and orders every kind by ts then id", ctx do
    assignment = assign(ctx)
    first = attest(ctx, {:session, "holder"}, assignment.id, "progress")
    second = verdict(ctx, {:user, "flynn"}, assignment.id, "reviewed")

    {:ok, _} =
      DB.query(ctx.db, "UPDATE attests SET ts = 7 WHERE assignmentId = ?1", [assignment.id])

    expected = Enum.sort([first.attest.id, second.attest.id])
    assert %{attests: rows} = query_attests(ctx, {:session, "reviewer"}, assignment.id)
    assert Enum.map(rows, & &1.id) == expected
    assert Enum.all?(rows, &Map.has_key?(&1, :verdictKind))
    assert %{attests: [_ | _]} = query_attests(ctx, {:user, "flynn"}, assignment.id)
    assert %{code: "process_denied"} = query_attests(ctx, {:process, "cron"}, assignment.id)
    assert %{code: "principal_required"} = query_attests(ctx, nil, assignment.id)
    assert %{code: "unknown_assignment"} = query_attests(ctx, {:user, "flynn"}, "missing")
  end

  test "assignment facts distinguish unknown from empty and gate completion end to end", ctx do
    assignment = assign(ctx)

    put_rules(ctx, """
    [[rule]]
    name = "needs-tests"
    verb = "attest"
    text = "completion requires tests"
    external_producer = true
    deny_when = [
      { fact = "attest.kind", op = "eq", value = "completion" },
      { fact = "assignment.holder_archetype", op = "eq", value = "coder" },
      { fact = "assignment.verdicts", op = "not_in", value = ["tests-passed"] }
    ]
    """)

    Rules.load!(ctx.base_dir, Map.keys(ctx.handlers))

    assert {:error, %{code: "rule_denied", rule: "needs-tests"}} =
             Dispatch.dispatch(
               ctx.db,
               ctx.handlers,
               call("attest", {:session, "holder"}, %{
                 assignment_id: assignment.id,
                 kind: "completion"
               })
             )

    assert Assignments.open_count(ctx.db, "holder") == 1
    assert Assignments.list_attests(ctx.db, assignment.id) == []
    assert {:ok, [[1]]} = DB.query(ctx.db, "SELECT count(*) FROM events WHERE kind='denied'")

    assert {:error, %{code: "unknown_assignment"}} =
             Dispatch.dispatch(
               ctx.db,
               ctx.handlers,
               call("attest", {:session, "holder"}, %{
                 assignment_id: "missing",
                 kind: "completion"
               })
             )

    assert {:ok, %{attest: %{kind: "verdict"}}} =
             Dispatch.dispatch(
               ctx.db,
               ctx.handlers,
               call("attest", {:user, "flynn"}, %{
                 assignment_id: assignment.id,
                 kind: "verdict",
                 verdict_kind: "tests-passed"
               })
             )

    assert {:ok, %{assignment: %{state: "closed"}}} =
             Dispatch.dispatch(
               ctx.db,
               ctx.handlers,
               call("attest", {:session, "holder"}, %{
                 assignment_id: assignment.id,
                 kind: "completion"
               })
             )
  end

  test "attest and assignment caller facts obey raw, nil, and principal matrices", ctx do
    assignment = assign(ctx)

    assertions = [
      {"attest.kind", "eq", "garbage", call("attest", {:session, "holder"}, %{kind: "garbage"}),
       true},
      {"attest.kind", "eq", "garbage",
       call("revoke-assignment", {:session, "holder"}, %{kind: "garbage"}), false},
      {"assignment.holder_archetype", "eq", "coder",
       call("attest", {:session, "holder"}, %{assignment_id: assignment.id}), true},
      {"assignment.holder_archetype", "eq", "coder",
       call("attest", {:session, "holder"}, %{assignment_id: "missing"}), false},
      {"assignment.holder_archetype", "eq", "coder",
       call("attest", {:session, "holder"}, %{assignment_id: 1}), false},
      {"assignment.caller_is_holder", "eq", true,
       call("attest", {:session, "holder"}, %{assignment_id: assignment.id}), true},
      {"assignment.caller_is_holder", "eq", false,
       call("attest", {:session, "reviewer"}, %{assignment_id: assignment.id}), true},
      {"assignment.caller_is_holder", "eq", false,
       call("attest", {:user, "flynn"}, %{assignment_id: assignment.id}), true},
      {"assignment.caller_is_holder", "eq", false,
       call("attest", {:process, "cron"}, %{assignment_id: assignment.id}), true},
      {"assignment.caller_is_holder", "eq", false,
       call("attest", nil, %{assignment_id: assignment.id}), false}
    ]

    for {fact, op, value, dispatch_call, fires?} <- assertions do
      put_rules(ctx, rule("matrix", fact, op, value, dispatch_call.verb))
      Rules.load!(ctx.base_dir, [dispatch_call.verb])
      assert match?({:deny, _}, Rules.evaluate(ctx.db, dispatch_call)) == fires?
    end

    without_principal =
      Map.delete(call("attest", nil, %{assignment_id: assignment.id}), :principal)

    put_rules(ctx, rule("missing-principal", "assignment.caller_is_holder", "eq", false))
    Rules.load!(ctx.base_dir, ["attest"])
    assert :ok = Rules.evaluate(ctx.db, without_principal)

    verdict(ctx, {:session, "reviewer"}, assignment.id, "reviewed")
    verdict(ctx, {:user, "flynn"}, assignment.id, "reviewed")
    assert Assignments.verdict_kinds(ctx.db, assignment.id) == ["reviewed"]
  end

  test "new fact types validate at load and demanded database failures deny", ctx do
    put_rules(ctx, rule("bad-list-op", "assignment.verdicts", "eq", ["reviewed"]))

    assert_raise ArgumentError, ~r/invalid for a list fact/, fn ->
      Rules.load!(ctx.base_dir, ["attest"])
    end

    put_rules(ctx, rule("bad-list-value", "assignment.verdicts", "in", [1]))

    assert_raise ArgumentError, ~r/non-empty flat list/, fn ->
      Rules.load!(ctx.base_dir, ["attest"])
    end

    put_rules(ctx, rule("bad-bool", "assignment.caller_is_holder", "eq", "true"))

    assert_raise ArgumentError, ~r/does not match bool/, fn ->
      Rules.load!(ctx.base_dir, ["attest"])
    end

    assignment = assign(ctx)
    put_rules(ctx, rule("fact-error", "assignment.verdicts", "not_in", ["reviewed"]))
    Rules.load!(ctx.base_dir, ["attest"])

    lazy_call =
      call("attest", {:session, "holder"}, %{
        assignment_id: assignment.id,
        kind: "progress"
      })

    put_rules(ctx, """
    [[rule]]
    name = "lazy"
    verb = "attest"
    text = "denied"
    external_producer = true
    deny_when = [
      { fact = "attest.kind", op = "eq", value = "completion" },
      { fact = "assignment.verdicts", op = "not_in", value = ["reviewed"] }
    ]
    """)

    Rules.load!(ctx.base_dir, ["attest"])
    assert :ok = Rules.evaluate(:missing_db, lazy_call)

    put_rules(ctx, rule("fact-error", "assignment.verdicts", "not_in", ["reviewed"]))
    Rules.load!(ctx.base_dir, ["attest"])

    assert {:deny, %{code: "rule_error", fact: "assignment.verdicts"}} =
             Rules.evaluate(
               :missing_db,
               call("attest", {:session, "holder"}, %{assignment_id: assignment.id})
             )
  end

  test "no-self-verdict statute blocks holder while user verdict succeeds", ctx do
    assignment = assign(ctx)
    put_rules(ctx, rule("no-self-verdicts", "assignment.caller_is_holder", "eq", true))
    Rules.load!(ctx.base_dir, Map.keys(ctx.handlers))

    assert {:error, %{code: "rule_denied"}} =
             Dispatch.dispatch(
               ctx.db,
               ctx.handlers,
               call("attest", {:session, "holder"}, %{
                 assignment_id: assignment.id,
                 kind: "verdict",
                 verdict_kind: "reviewed"
               })
             )

    assert {:ok, %{attest: %{byUser: "flynn"}}} =
             Dispatch.dispatch(
               ctx.db,
               ctx.handlers,
               call("attest", {:user, "flynn"}, %{
                 assignment_id: assignment.id,
                 kind: "verdict",
                 verdict_kind: "reviewed"
               })
             )
  end

  test "archetype-scoped completion gate is inert for other archetypes", ctx do
    session(ctx.db, "writer", "flynn", "writer")

    assignment =
      Assignments.__handle__(
        ctx.db,
        "assign",
        call("assign", {:user, "flynn"}, %{subject: "writing", idempotency_key: nil})
        |> Map.merge(%{session_key: "writer", target_role: nil, role_fallback: false})
      )

    put_rules(ctx, """
    [[rule]]
    name = "coder-needs-tests"
    verb = "attest"
    text = "coder completion requires tests"
    external_producer = true
    deny_when = [
      { fact = "attest.kind", op = "eq", value = "completion" },
      { fact = "assignment.holder_archetype", op = "eq", value = "coder" },
      { fact = "assignment.verdicts", op = "not_in", value = ["tests-passed"] }
    ]
    """)

    Rules.load!(ctx.base_dir, Map.keys(ctx.handlers))

    assert {:ok, %{assignment: %{state: "closed"}}} =
             Dispatch.dispatch(
               ctx.db,
               ctx.handlers,
               call("attest", {:session, "writer"}, %{
                 assignment_id: assignment.id,
                 kind: "completion"
               })
             )
  end

  test "verdict filing advances the supervision attest-count input", ctx do
    assignment = assign(ctx)
    assert Assignments.attest_count(ctx.db, assignment.id) == 0
    assert Assignments.open_count(ctx.db, "holder") == 1

    assert %{attest: %{kind: "verdict"}} =
             verdict(ctx, {:session, "reviewer"}, assignment.id, "reviewed")

    assert Assignments.attest_count(ctx.db, assignment.id) == 1
    assert Assignments.open_count(ctx.db, "holder") == 1
  end

  defp assign(ctx, subject \\ "work") do
    Assignments.__handle__(
      ctx.db,
      "assign",
      call("assign", {:user, "flynn"}, %{subject: subject, idempotency_key: nil})
      |> Map.merge(%{session_key: "holder", target_role: nil, role_fallback: false})
    )
  end

  defp attest(ctx, principal, assignment_id, kind, extra \\ %{}) do
    Assignments.__handle__(
      ctx.db,
      "attest",
      call("attest", principal, Map.merge(%{assignment_id: assignment_id, kind: kind}, extra))
    )
  end

  defp verdict(ctx, principal, assignment_id, kind) do
    attest(ctx, principal, assignment_id, "verdict", %{verdict_kind: kind})
  end

  defp revoke(ctx, assignment_id) do
    Assignments.__handle__(
      ctx.db,
      "revoke-assignment",
      call("revoke-assignment", {:user, "flynn"}, %{assignment_id: assignment_id})
    )
  end

  defp query_attests(ctx, principal, assignment_id) do
    Assignments.__handle__(
      ctx.db,
      "attests",
      call("attests", principal, %{assignment_id: assignment_id})
    )
  end

  defp call(verb, principal, params) do
    %{
      verb: verb,
      origin: origin(principal),
      principal: principal,
      session_key: nil,
      supervision_interval_ms: 1_000,
      params: params
    }
  end

  defp origin({:session, key}), do: "agent:#{key}"
  defp origin({:user, user}), do: "user:#{user}"
  defp origin({:process, process}), do: "process:#{process}"
  defp origin(nil), do: "agent:declared"

  defp session(db, key, owner, archetype) do
    Org.create(db, %{
      session_key: key,
      display_name: key,
      owner_user_id: owner,
      origin: "user:#{owner}",
      archetype: archetype,
      harness: "claude",
      provider: "anthropic",
      model: Model.new("fable"),
      host: "eezo"
    })
  end

  defp put_rules(ctx, contents) do
    File.write!(Path.join(ctx.base_dir, "identity/rules/check.toml"), contents)
  end

  defp rule(name, fact, op, value, verb \\ "attest") do
    value = if is_binary(value), do: inspect(value), else: inspect(value)

    external =
      if op == "not_in" and String.starts_with?(fact, "assignment.") and
           String.ends_with?(fact, "verdicts") do
        "external_producer = true"
      else
        ""
      end

    """
    [[rule]]
    name = "#{name}"
    verb = "#{verb}"
    text = "denied"
    #{external}
    deny_when = [{ fact = "#{fact}", op = "#{op}", value = #{value} }]
    """
  end
end
