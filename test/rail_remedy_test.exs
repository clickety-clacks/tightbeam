defmodule Tightbeam.RailRemedyTest do
  use ExUnit.Case, async: false

  alias Tightbeam.{
    Assignments,
    ConditionFacts,
    DB,
    Devices,
    Dispatch,
    EventLog,
    Gateway,
    Idempotency,
    Org,
    RailRemedy,
    Roles,
    Rules,
    Wakes,
    WorkItems,
    WorkState
  }

  setup do
    db = :"rail_remedy_db_#{System.unique_integer([:positive])}"
    start_supervised!({DB, path: ":memory:", name: db})

    for module <- [
          Devices,
          Idempotency,
          ConditionFacts,
          Wakes,
          Org,
          Roles,
          WorkItems,
          Assignments,
          WorkState,
          EventLog,
          RailRemedy
        ] do
      :ok = module.ensure_schema(db)
    end

    {:ok, _} =
      DB.query(
        db,
        "INSERT INTO users (userId, isAdmin, createdAt) VALUES ('flynn', 0, 1)"
      )

    holder = session(db, "holder", "flynn", "claude", "coder")
    reviewer = session(db, "reviewer-session", "flynn", "codex", "reviewer")
    Roles.create!(db, "reviewer", "flynn", reviewer.session_key)

    base_dir =
      Path.join(System.tmp_dir!(), "tightbeam-remedy-#{System.unique_integer([:positive])}")

    File.mkdir_p!(Path.join(base_dir, "identity/rules"))
    handlers = Gateway.handlers(%{db: db})

    on_exit(fn ->
      File.rm_rf!(base_dir)
      :persistent_term.erase(Rules)
    end)

    %{db: db, base_dir: base_dir, handlers: handlers, holder: holder, reviewer: reviewer}
  end

  test "absent fact assigns under the remedy principal and actor closes after linked review",
       ctx do
    assignment = assignment(ctx, "original")
    load_review_gate(ctx)
    completion = completion_call(assignment.id)

    assert {:error,
            %{
              reason: "remedy_fired",
              producer: review_id,
              rule: "completion-needs-review"
            }} = Dispatch.dispatch(ctx.db, ctx.handlers, completion)

    assert %{
             status: "live",
             producer_key: ^review_id,
             occurrence: 1,
             rewake_count: 0
           } = RailRemedy.episode(ctx.db, "completion-needs-review", assignment.id)

    review = assignment_row(ctx.db, review_id)
    assert review.reviewsAssignmentId == assignment.id
    assert review.openedByUser == "flynn"
    assert review.openedBySession == nil

    assert {:ok, [[principal]]} =
             DB.query(
               ctx.db,
               "SELECT principal FROM events WHERE verb = 'assign' AND kind = 'verb' ORDER BY id DESC LIMIT 1"
             )

    assert principal == "remedy:assign:completion-needs-review"

    verdict(ctx, review_id, "reviewed-clean")

    assert {:ok, %{assignment: %{state: "closed"}}} =
             Dispatch.dispatch(ctx.db, ctx.handlers, completion)

    assert %{status: "closed"} =
             RailRemedy.episode(ctx.db, "completion-needs-review", assignment.id)
  end

  test "TTL reclaim preserves occurrence and reuses exactly one external producer", ctx do
    assignment = assignment(ctx, "ttl")
    load_review_gate(ctx)
    key = "rail-dispatch:completion-needs-review:#{assignment.id}:1"

    existing =
      Assignments.__handle__(ctx.db, "assign", %{
        verb: "assign",
        origin: "remedy:completion-needs-review",
        principal:
          {:remedy, %{statute: "completion-needs-review", action: "assign", owner: "flynn"}},
        session_key: ctx.reviewer.session_key,
        target_role: "reviewer",
        role_fallback: false,
        params: %{
          subject: "review #{assignment.id}",
          reviews_assignment_id: assignment.id,
          idempotency_key: key
        }
      })

    stale = System.system_time(:millisecond) - 60_001

    {:ok, _} =
      DB.query(
        ctx.db,
        """
        INSERT INTO rail_remedy_episodes
          (statute, subject, status, occurrence, rewakeCount, claimToken, openedAt)
        VALUES ('completion-needs-review', ?1, 'dispatched', 1, 0, 'old', ?2)
        """,
        [assignment.id, stale]
      )

    assert {:error, %{producer: producer}} =
             Dispatch.dispatch(ctx.db, ctx.handlers, completion_call(assignment.id))

    assert producer == existing.id

    assert %{occurrence: 1, producer_key: producer_key, status: "live"} =
             RailRemedy.episode(ctx.db, "completion-needs-review", assignment.id)

    assert producer_key == existing.id

    assert {:ok, [[1]]} =
             DB.query(
               ctx.db,
               "SELECT COUNT(*) FROM assignments WHERE reviewsAssignmentId = ?1",
               [assignment.id]
             )
  end

  test "closed reopen and dead-live replacement bump occurrence and wire key", ctx do
    assignment = assignment(ctx, "terminal")
    load_review_gate(ctx)

    assert {:error, %{producer: first}} =
             Dispatch.dispatch(ctx.db, ctx.handlers, completion_call(assignment.id))

    assert RailRemedy.close(ctx.db, "completion-needs-review", assignment.id)

    assert {:error, %{producer: second}} =
             Dispatch.dispatch(ctx.db, ctx.handlers, completion_call(assignment.id))

    refute second == first

    assert %{occurrence: 2} =
             RailRemedy.episode(ctx.db, "completion-needs-review", assignment.id)

    revoke(ctx, second)

    assert {:error, %{producer: third}} =
             Dispatch.dispatch(ctx.db, ctx.handlers, completion_call(assignment.id))

    refute third in [first, second]

    assert %{occurrence: 3} =
             RailRemedy.episode(ctx.db, "completion-needs-review", assignment.id)

    assert {:ok, [[3]]} =
             DB.query(
               ctx.db,
               "SELECT COUNT(*) FROM wire_idempotency WHERE operation = 'assign' AND idempotencyKey LIKE 'rail-dispatch:completion-needs-review:%'",
               []
             )
  end

  test "superseded claimant loses its fenced lease and does not add a producer", ctx do
    assignment = assignment(ctx, "fenced")
    load_review_gate(ctx)
    stale = System.system_time(:millisecond) - 60_001

    {:ok, _} =
      DB.query(
        ctx.db,
        """
        INSERT INTO rail_remedy_episodes
          (statute, subject, status, occurrence, rewakeCount, claimToken, openedAt)
        VALUES ('completion-needs-review', ?1, 'claimed', 1, 0, 'superseded', ?2)
        """,
        [assignment.id, stale]
      )

    assert {:error, %{producer: producer}} =
             Dispatch.dispatch(ctx.db, ctx.handlers, completion_call(assignment.id))

    {:ok, _} =
      DB.query(
        ctx.db,
        """
        UPDATE rail_remedy_episodes SET status = 'dispatched'
        WHERE statute = 'completion-needs-review' AND subject = ?1
          AND status = 'claimed' AND claimToken = 'superseded'
        """,
        [assignment.id]
      )

    assert DB.changes(ctx.db) == 0

    assert {:ok, [[1]]} =
             DB.query(
               ctx.db,
               "SELECT COUNT(*) FROM assignments WHERE reviewsAssignmentId = ?1 AND id = ?2",
               [assignment.id, producer]
             )
  end

  test "denied producer dispatch releases the lease and the next edge retries", ctx do
    assignment = assignment(ctx, "retry")
    load_review_gate(ctx)
    parent = self()

    denied_handlers =
      Map.put(ctx.handlers, "assign", fn call ->
        send(parent, {:assign_attempt, call.params.idempotency_key})
        %{code: "runtime_blocker"}
      end)

    assert {:error, %{reason: "remedy_fired"}} =
             Dispatch.dispatch(ctx.db, denied_handlers, completion_call(assignment.id))

    assert RailRemedy.episode(ctx.db, "completion-needs-review", assignment.id) == nil
    assert_received {:assign_attempt, _}

    assert {:error, %{reason: "remedy_fired"}} =
             Dispatch.dispatch(ctx.db, denied_handlers, completion_call(assignment.id))

    assert_received {:assign_attempt, _}

    assert Enum.count(remedy_events(ctx.db), &(&1["outcome"] == "blocked")) == 2
  end

  test "multi-statute actor closure closes only the statute that passed", ctx do
    assignment = assignment(ctx, "multi")
    put_rules(ctx, two_external_gates())
    Rules.load!(ctx.base_dir, Map.keys(ctx.handlers), %{})

    now = System.system_time(:millisecond)

    for statute <- ["s1", "s2"] do
      {:ok, _} =
        DB.query(
          ctx.db,
          """
          INSERT INTO rail_remedy_episodes
            (statute, subject, status, producerKey, occurrence, rewakeCount, claimToken, openedAt)
          VALUES (?1, ?2, 'live', 'reviewer-session', 1, 0, ?1, ?3)
          """,
          [statute, assignment.id, now]
        )
    end

    assert %{attest: %{verdictKind: "s1-clean"}} = verdict(ctx, assignment.id, "s1-clean")
    assert {"s1-clean"} = {hd(Assignments.verdict_kinds(ctx.db, assignment.id))}

    assert {:error, %{rule: "s2"}} =
             Dispatch.dispatch(ctx.db, ctx.handlers, completion_call(assignment.id))

    assert %{status: "closed"} = RailRemedy.episode(ctx.db, "s1", assignment.id)
    assert %{status: "live"} = RailRemedy.episode(ctx.db, "s2", assignment.id)
  end

  test "live episode re-wakes with a fresh occurrence-plus-counter key", ctx do
    assignment = assignment(ctx, "rewake")
    load_review_gate(ctx)
    reviewer_key = ctx.reviewer.session_key

    assert {:error, %{producer: producer}} =
             Dispatch.dispatch(ctx.db, ctx.handlers, completion_call(assignment.id))

    assert {:error, %{producer: ^producer}} =
             Dispatch.dispatch(ctx.db, ctx.handlers, completion_call(assignment.id))

    assert {:error, %{producer: ^producer}} =
             Dispatch.dispatch(ctx.db, ctx.handlers, completion_call(assignment.id))

    assert %{producer_key: ^producer, rewake_count: 2} =
             RailRemedy.episode(ctx.db, "completion-needs-review", assignment.id)

    assert {:ok, [[2]]} =
             DB.query(
               ctx.db,
               "SELECT COUNT(*) FROM wire_idempotency WHERE operation = 'wake' AND idempotencyKey LIKE 'rail-rewake:completion-needs-review:%'",
               []
             )

    assert {:ok, [[^reviewer_key]]} =
             DB.query(
               ctx.db,
               """
               SELECT DISTINCT w.sessionKey
               FROM wire_idempotency i
               JOIN wakes w ON w.wakeId = i.sessionKey
               WHERE i.operation = 'wake'
                 AND i.idempotencyKey LIKE 'rail-rewake:completion-needs-review:%'
               """,
               []
             )
  end

  test "unbound role and token fail closed without dispatch", ctx do
    assignment = assignment(ctx, "unbound")
    :ok = Roles.rm(ctx.db, "reviewer")
    load_review_gate(ctx)

    assert {:error, %{reason: "remedy_fired", producer: nil}} =
             Dispatch.dispatch(ctx.db, ctx.handlers, completion_call(assignment.id))

    assert RailRemedy.episode(ctx.db, "completion-needs-review", assignment.id) == nil
    assert List.last(remedy_events(ctx.db))["outcome"] == "unbound"

    put_rules(
      ctx,
      String.replace(review_gate(), "review {assignment_id}", "review {work_item_id}")
    )

    Rules.load!(ctx.base_dir, Map.keys(ctx.handlers), %{})

    assert {:error, %{reason: "remedy_fired", producer: nil}} =
             Dispatch.dispatch(ctx.db, ctx.handlers, completion_call(assignment.id))

    assert List.last(remedy_events(ctx.db))["outcome"] == "unbound"
  end

  test "remedy grammar and F1/F2 reject dead rail sets while conditional blockers load", ctx do
    put_rules(
      ctx,
      String.replace(review_gate(), ~s(produces = "reviewed-clean"), ~s(produces = "other"))
    )

    error =
      assert_raise ArgumentError, fn -> Rules.load!(ctx.base_dir, Map.keys(ctx.handlers), %{}) end

    assert error.message =~ "completion-needs-review"
    assert error.message =~ "does not require"

    put_rules(ctx, produced_gate())

    error =
      assert_raise ArgumentError, fn -> Rules.load!(ctx.base_dir, Map.keys(ctx.handlers), %{}) end

    assert error.message =~ "F1"
    assert error.message =~ "produced-gate"
    assert error.message =~ "tests-passed"

    assert [_] =
             Rules.load!(ctx.base_dir, Map.keys(ctx.handlers), %{tests: "mix test"})

    put_rules(ctx, external_missing_gate())

    error =
      assert_raise ArgumentError, fn -> Rules.load!(ctx.base_dir, Map.keys(ctx.handlers), %{}) end

    assert error.message =~ "F1"
    assert error.message =~ "missing-producer"

    put_rules(ctx, review_gate())
    error = assert_raise ArgumentError, fn -> Rules.load!(ctx.base_dir, ["attest"], %{}) end
    assert error.message =~ "F2"
    assert error.message =~ "completion-needs-review"
    assert error.message =~ "assign"

    put_rules(ctx, review_gate() <> pure_blocker())

    error =
      assert_raise ArgumentError, fn -> Rules.load!(ctx.base_dir, Map.keys(ctx.handlers), %{}) end

    assert error.message =~ "completion-needs-review"
    assert error.message =~ "block-remedy-assign"

    put_rules(ctx, cycle_rules())

    error =
      assert_raise ArgumentError, fn -> Rules.load!(ctx.base_dir, Map.keys(ctx.handlers), %{}) end

    assert error.message =~ "F2 producer cycle"
    assert error.message =~ "cycle-assign"
    assert error.message =~ "cycle-wake"

    put_rules(ctx, review_gate() <> conditional_blocker())
    assert [_gate, _blocker] = Rules.load!(ctx.base_dir, Map.keys(ctx.handlers), %{})

    assignment = assignment(ctx, "conditional")

    assert {:error, %{reason: "remedy_fired"}} =
             Dispatch.dispatch(ctx.db, ctx.handlers, completion_call(assignment.id))

    assert List.last(remedy_events(ctx.db))["outcome"] == "blocked"
  end

  test "per-action remedy schema and interpolation typing fail at load", ctx do
    cases = [
      {String.replace(review_gate(), ~s(subject = "review {assignment_id}"\n), ""),
       "params are missing subject"},
      {wake_remedy(), "exactly one of target_role or target_session"},
      {String.replace(spawn_remedy(), ~s(model = "test"\n), ""), "missing model"},
      {String.replace(
         review_gate(),
         ~s(reviews = "{assignment_id}"),
         ~s(reviews = "review-{assignment_id}")
       ), "whole token or literal"},
      {String.replace(
         review_gate(),
         ~s(subject = "review {assignment_id}"),
         ~s(subject = "review {unknown}")
       ), "unknown binding token"},
      {"""
       [[rule]]
       name = "bad-external"
       verb = "attest"
       text = "bad"
       external_producer = true
       deny_when = [{ fact = "attest.kind", op = "eq", value = "completion" }]
       """, "valid only on a verdict-fact gate"}
    ]

    Enum.each(cases, fn {law, message} ->
      put_rules(ctx, law)

      error =
        assert_raise ArgumentError, fn ->
          Rules.load!(ctx.base_dir, Map.keys(ctx.handlers), %{})
        end

      assert error.message =~ message
    end)
  end

  defp load_review_gate(ctx) do
    put_rules(ctx, review_gate())
    Rules.load!(ctx.base_dir, Map.keys(ctx.handlers), %{})
  end

  defp put_rules(ctx, contents) do
    File.write!(Path.join(ctx.base_dir, "identity/rules/remedy.toml"), contents)
  end

  defp review_gate do
    """
    [[rule]]
    name = "completion-needs-review"
    verb = "attest"
    text = "completion requires review"
    effect = "remedy"
    deny_when = [
      { fact = "attest.kind", op = "eq", value = "completion" },
      { fact = "assignment.cross_harness_verdict_kinds", op = "not_in", value = ["reviewed-clean"] }
    ]
    [rule.remedy]
    action = "assign"
    produces = "reviewed-clean"
    target_role = "reviewer"
    [rule.remedy.params]
    subject = "review {assignment_id}"
    reviews = "{assignment_id}"
    """
  end

  defp produced_gate do
    """
    [[rule]]
    name = "produced-gate"
    verb = "attest"
    text = "tests required"
    deny_when = [
      { fact = "assignment.produced_verdict_kinds", op = "not_in", value = ["tests-passed"] }
    ]
    """
  end

  defp external_missing_gate do
    """
    [[rule]]
    name = "missing-producer"
    verb = "attest"
    text = "review required"
    deny_when = [
      { fact = "assignment.verdicts", op = "not_in", value = ["reviewed-clean"] }
    ]
    """
  end

  defp pure_blocker do
    """
    [[rule]]
    name = "block-remedy-assign"
    verb = "assign"
    text = "no remedies"
    deny_when = [
      { fact = "caller.origin_class", op = "eq", value = "remedy" }
    ]
    """
  end

  defp conditional_blocker do
    """
    [[rule]]
    name = "conditional-remedy-blocker"
    verb = "assign"
    text = "runtime quota"
    deny_when = [
      { fact = "caller.origin_class", op = "eq", value = "remedy" },
      { fact = "caller.verb_count_24h", op = "gte", value = 0 }
    ]
    """
  end

  defp cycle_rules do
    """
    [[rule]]
    name = "cycle-assign"
    verb = "assign"
    text = "assign gate"
    effect = "remedy"
    deny_when = [
      { fact = "assignment.verdicts", op = "not_in", value = ["reviewed-clean"] }
    ]
    [rule.remedy]
    action = "wake"
    produces = "reviewed-clean"
    target_session = "holder"
    [rule.remedy.params]
    prompt = "review"
    after = 1

    [[rule]]
    name = "cycle-wake"
    verb = "wake"
    text = "wake gate"
    effect = "remedy"
    deny_when = [
      { fact = "assignment.verdicts", op = "not_in", value = ["reviewed-clean"] }
    ]
    [rule.remedy]
    action = "assign"
    produces = "reviewed-clean"
    target_role = "reviewer"
    [rule.remedy.params]
    subject = "review"
    """
  end

  defp wake_remedy do
    """
    [[rule]]
    name = "wake-remedy"
    verb = "attest"
    text = "wake"
    effect = "remedy"
    deny_when = [
      { fact = "assignment.verdicts", op = "not_in", value = ["reviewed-clean"] }
    ]
    [rule.remedy]
    action = "wake"
    produces = "reviewed-clean"
    target_role = "reviewer"
    target_session = "holder"
    [rule.remedy.params]
    prompt = "review {assignment_id}"
    """
  end

  defp spawn_remedy do
    """
    [[rule]]
    name = "spawn-remedy"
    verb = "attest"
    text = "spawn"
    deny_when = [
      { fact = "assignment.verdicts", op = "not_in", value = ["reviewed-clean"] }
    ]
    effect = "remedy"
    [rule.remedy]
    action = "spawn"
    produces = "reviewed-clean"
    name = "reviewer-new"
    harness = "codex"
    model = "test"
    [rule.remedy.params]
    display = "Reviewer {assignment_id}"
    """
  end

  defp two_external_gates do
    """
    [[rule]]
    name = "s1"
    verb = "attest"
    text = "s1"
    effect = "remedy"
    deny_when = [
      { fact = "assignment.verdicts", op = "not_in", value = ["s1-clean"] }
    ]
    [rule.remedy]
    action = "assign"
    produces = "s1-clean"
    target_role = "reviewer"
    [rule.remedy.params]
    subject = "s1 review"

    [[rule]]
    name = "s2"
    verb = "attest"
    text = "s2"
    effect = "remedy"
    deny_when = [
      { fact = "assignment.verdicts", op = "not_in", value = ["s2-clean"] }
    ]
    [rule.remedy]
    action = "assign"
    produces = "s2-clean"
    target_role = "reviewer"
    [rule.remedy.params]
    subject = "s2 review"
    """
  end

  defp assignment(ctx, subject) do
    Assignments.__handle__(ctx.db, "assign", %{
      verb: "assign",
      origin: "user:flynn",
      principal: {:user, "flynn"},
      session_key: ctx.holder.session_key,
      target_role: nil,
      role_fallback: false,
      params: %{subject: subject, idempotency_key: nil}
    })
  end

  defp verdict(ctx, assignment_id, kind) do
    Assignments.__handle__(ctx.db, "attest", %{
      verb: "attest",
      origin: "agent:reviewer",
      principal: {:session, ctx.reviewer.session_key},
      session_key: nil,
      params: %{assignment_id: assignment_id, kind: "verdict", verdict_kind: kind}
    })
  end

  defp revoke(ctx, assignment_id) do
    Assignments.__handle__(ctx.db, "revoke-assignment", %{
      verb: "revoke-assignment",
      origin: "user:flynn",
      principal: {:user, "flynn"},
      session_key: nil,
      params: %{assignment_id: assignment_id}
    })
  end

  defp completion_call(assignment_id) do
    %{
      verb: "attest",
      origin: "agent:holder",
      principal: {:session, "holder"},
      session_key: nil,
      params: %{assignment_id: assignment_id, kind: "completion"}
    }
  end

  defp assignment_row(db, id) do
    Assignments.__handle__(db, "assignment-get", %{
      principal: {:user, "flynn"},
      params: %{assignment_id: id}
    })
  end

  defp remedy_events(db) do
    EventLog.lifecycle_events(db)
    |> Enum.filter(&(&1.kind == "rail_remedy"))
    |> Enum.map(&JSON.decode!(&1.detail))
  end

  defp session(db, key, owner, harness, archetype) do
    Org.create(db, %{
      session_key: key,
      display_name: key,
      kind: "custom",
      owner_user_id: owner,
      origin: "user:#{owner}",
      archetype: archetype,
      host: "eezo",
      harness: harness,
      provider: if(harness == "codex", do: "openai", else: "anthropic"),
      model: "test"
    })
  end
end
