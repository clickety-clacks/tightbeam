defmodule Tightbeam.RailRemedyTest do
  use Tightbeam.TestCase, async: false
  alias Tightbeam.Model

  alias Tightbeam.{
    Archetypes,
    Assignments,
    ConnRegistry,
    DB,
    Dispatch,
    EventLog,
    Gateway,
    Idempotency,
    ModelCatalog,
    Org,
    RailRemedy,
    Roles,
    Rules,
    Wakes
  }

  setup do
    db = :"rail_remedy_db_#{System.unique_integer([:positive])}"
    start_supervised!({DB, path: ":memory:", name: db})

    :ok = Tightbeam.Schema.ensure_all(db)

    {:ok, _} =
      DB.query(
        db,
        "INSERT INTO users (userId, isAdmin, createdAt) VALUES ('flynn', 0, 1)"
      )

    holder = session(db, "holder", "flynn", "claude", "coder")
    reviewer = session(db, "reviewer-session", "flynn", "claude", "reviewer")
    Roles.create!(db, "reviewer", "flynn", reviewer.session_key)

    # Canonicalize the tmp base: Darwin's System.tmp_dir!/0 sits under the /var
    # symlink (/var -> /private/var), and Containment.rail_profile/1 (the rail scratch
    # write-root) refuses uncanonical components, which fails the contained script
    # launch (error:1) instead of letting it return a clean deny.
    tmp_base = to_string(:string.trim(:os.cmd(~c(realpath #{System.tmp_dir!()}))))

    base_dir =
      Path.join(tmp_base, "tightbeam-remedy-#{System.unique_integer([:positive])}")

    File.mkdir_p!(Path.join(base_dir, "identity/rules"))

    # Spawn readiness checks for an adapter under this base_dir. It used to resolve
    # to a sibling checkout that happened to exist on the developer's machine (#46),
    # so these spawn-remedy tests passed without ever staging one.
    for bin <- ["claude-agent-acp", "codex-acp"] do
      adapter = Path.join([base_dir, "adapters", "node_modules", ".bin", bin])
      File.mkdir_p!(Path.dirname(adapter))
      File.write!(adapter, "#!/bin/sh\nexit 0\n")
      File.chmod!(adapter, 0o755)
    end

    handlers =
      Gateway.handlers(%{
        db: db,
        wake_tick_ms: 1_000,
        credential_status: fn _provider -> :onboarded end,
        credential_kind: fn _provider -> :subscription end,
        patch_adapter: fn _harness, _path -> :ok end
      })

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

  test "replaying a first occurrence close leaves the second occurrence live", ctx do
    assignment = assignment(ctx, "reentered")
    [rule] = load_review_gate(ctx)
    completion = completion_call(assignment.id)

    assert {:error, %{producer: review_id}} =
             Dispatch.dispatch(ctx.db, ctx.handlers, completion)

    verdict(ctx, review_id, "reviewed-clean")

    assert {:allow, [{"completion-needs-review", subject, occurrence}], []} =
             Rules.decide(ctx.db, completion)

    assert subject == assignment.id
    assert occurrence == 1
    assert RailRemedy.close(ctx.db, "completion-needs-review", subject, occurrence)

    assert %{outcome: "reopened-dispatched"} =
             RailRemedy.fire(ctx.db, ctx.handlers, rule, subject, completion)

    assert %{status: "live", occurrence: 2} =
             RailRemedy.episode(ctx.db, "completion-needs-review", subject)

    refute RailRemedy.close(ctx.db, "completion-needs-review", subject, occurrence)

    assert %{status: "live", occurrence: 2} =
             RailRemedy.episode(ctx.db, "completion-needs-review", subject)
  end

  test "remedy producer assign traverses dispatch and is denied by a script statute", ctx do
    assignment = assignment(ctx, "script-gated-producer")
    install_script_assign_gate!(ctx)
    put_rules(ctx, review_gate() <> script_assign_gate())
    Rules.load!(ctx.base_dir, Map.keys(ctx.handlers))

    assert {:error,
            %{
              reason: "remedy_fired",
              producer: nil,
              rule: "completion-needs-review"
            }} =
             Dispatch.dispatch(ctx.db, ctx.handlers, completion_call(assignment.id))

    assert RailRemedy.episode(ctx.db, "completion-needs-review", assignment.id) == nil

    assert {:ok, [[0]]} =
             DB.query(
               ctx.db,
               "SELECT COUNT(*) FROM assignments WHERE reviewsAssignmentId = ?1",
               [assignment.id]
             )

    assert %{
             rule: "script-block-remedy-assign",
             edge: "verb",
             reason: "rule_denied",
             script_exit_class: "returned",
             origin: "remedy:completion-needs-review",
             principal: "remedy:assign:completion-needs-review"
           } =
             Enum.find(
               EventLog.rail_denials(ctx.db, 0, 10),
               &(&1.rule == "script-block-remedy-assign")
             )

    assert %{
             "verb" => "assign",
             "origin" => "remedy:completion-needs-review",
             "return" => "block",
             "exit_class" => "returned"
           } =
             ctx.db
             |> EventLog.lifecycle_events()
             |> Enum.find(
               &(&1.kind == "rail_script" and &1.subject == "script-block-remedy-assign")
             )
             |> Map.fetch!(:detail)
             |> JSON.decode!()

    assert [%{"outcome" => "blocked", "producer_id" => nil}] = remedy_events(ctx.db)
  end

  test "surface policy returns a differently named nested rule denial without a producer", ctx do
    assignment = assignment(ctx, "surfaced-producer")
    put_rules(ctx, surfaced_review_gate() <> conditional_blocker())
    Rules.load!(ctx.base_dir, Map.keys(ctx.handlers))

    assert {:error,
            %{
              reason: "remedy_blocked",
              producer: nil,
              rule: "conditional-remedy-blocker",
              ref: producer_id,
              message: message
            }} = Dispatch.dispatch(ctx.db, ctx.handlers, completion_call(assignment.id))

    assert producer_id == assignment.id
    assert message == "conditional-remedy-blocker: runtime quota"
    assert RailRemedy.episode(ctx.db, "completion-needs-review", assignment.id) == nil
    assert [%{"outcome" => "blocked", "producer_id" => nil}] = remedy_events(ctx.db)
  end

  test "TTL reclaim racing a live original dispatch produces exactly one external effect", ctx do
    assignment = assignment(ctx, "ttl")
    load_review_gate(ctx)
    parent = self()
    assign = ctx.handlers["assign"]

    {:ok, counter} = Agent.start_link(fn -> 0 end)

    handlers =
      Map.put(ctx.handlers, "assign", fn call ->
        first? = Agent.get_and_update(counter, &{&1 == 0, &1 + 1})

        if first? do
          send(parent, {:original_dispatch_running, self()})
          receive do: (:release_original_dispatch -> :ok)
        end

        assign.(call)
      end)

    original =
      Task.async(fn ->
        Dispatch.dispatch(ctx.db, handlers, completion_call(assignment.id))
      end)

    # The handler only reaches this send after the remedy fires and dispatch has
    # written the episode, so the wait spans real DB work. Measured over 732 runs
    # on 12 concurrent BEAMs at `+S 2:2`: p50 3ms, p99 82ms, max 191ms -- the
    # 100ms assert_receive default sits inside that spread, which is why it flaked.
    assert_receive {:original_dispatch_running, original_pid}, 5_000

    stale = System.system_time(:millisecond) - 60_001

    {:ok, _} =
      DB.query(
        ctx.db,
        """
        UPDATE rail_remedy_episodes
        SET openedAt = ?2
        WHERE statute = 'completion-needs-review' AND subject = ?1 AND status = 'dispatched'
        """,
        [assignment.id, stale]
      )

    reclaimed =
      Task.async(fn ->
        Dispatch.dispatch(ctx.db, handlers, completion_call(assignment.id))
      end)

    assert {:error, %{producer: producer}} = Task.await(reclaimed)
    send(original_pid, :release_original_dispatch)
    assert {:error, %{producer: nil}} = Task.await(original)

    assert %{occurrence: 1, producer_key: ^producer, status: "live"} =
             RailRemedy.episode(ctx.db, "completion-needs-review", assignment.id)

    assert {:ok, [[1]]} =
             DB.query(
               ctx.db,
               "SELECT COUNT(*) FROM assignments WHERE reviewsAssignmentId = ?1",
               [assignment.id]
             )
  end

  test "spawn remedy TTL replay restores the original producer session", ctx do
    assignment = assignment(ctx, "spawn-replay")
    put_rules(ctx, spawn_remedy())
    handlers = spawn_handlers(ctx)
    Rules.load!(ctx.base_dir, Map.keys(handlers))

    assert {:error, %{producer: producer}} =
             Dispatch.dispatch(ctx.db, handlers, completion_call(assignment.id))

    stale = System.system_time(:millisecond) - 60_001

    {:ok, _} =
      DB.query(
        ctx.db,
        """
        UPDATE rail_remedy_episodes
        SET status = 'dispatched', producerKey = NULL, claimToken = 'crashed', openedAt = ?2
        WHERE statute = 'spawn-remedy' AND subject = ?1
        """,
        [assignment.id, stale]
      )

    assert {:error, %{producer: ^producer}} =
             Dispatch.dispatch(ctx.db, handlers, completion_call(assignment.id))

    assert %{status: "live", producer_key: ^producer, occurrence: 1} =
             RailRemedy.episode(ctx.db, "spawn-remedy", assignment.id)

    assert {:ok, [[1]]} =
             DB.query(ctx.db, "SELECT COUNT(*) FROM sessions WHERE handle = 'reviewer-new'", [])

    assert %{session_key: ^producer} =
             Idempotency.get(
               ctx.db,
               "flynn",
               "spawn",
               "rail-dispatch:spawn-remedy:#{assignment.id}:1"
             )
  end

  test "spawn reserve-then-act collapses racing remedy calls without handle uniqueness", ctx do
    handlers = spawn_handlers(ctx)
    spawn = handlers["spawn"]
    key = "rail-dispatch:spawn-race:subject:1"

    calls =
      for _ <- 1..8 do
        Task.async(fn ->
          spawn.(%{
            verb: "spawn",
            origin: "remedy:spawn-race",
            principal: {:remedy, %{statute: "spawn-race", action: "spawn", owner: "flynn"}},
            session_key: nil,
            params: %{
              display_name: "Unconstrained Racer",
              harness: "codex",
              model: "test",
              idempotency_key: key
            }
          })
        end)
      end

    session_keys = calls |> Enum.map(&Task.await(&1, 5_000).session_key) |> Enum.uniq()
    assert [_session_key] = session_keys

    assert {:ok, [[1]]} =
             DB.query(
               ctx.db,
               "SELECT COUNT(*) FROM sessions WHERE displayName = 'Unconstrained Racer'",
               []
             )
  end

  test "wake remedy reclaims a retired target through its wake ledger row", ctx do
    assignment = assignment(ctx, "wake-reclaim")
    put_rules(ctx, wake_gate())
    Rules.load!(ctx.base_dir, Map.keys(ctx.handlers))

    assert {:error, %{producer: producer}} =
             Dispatch.dispatch(ctx.db, ctx.handlers, completion_call(assignment.id))

    assert producer == ctx.reviewer.session_key
    first_key = "rail-dispatch:wake-remedy:#{assignment.id}:1"

    assert %{session_key: first_wake_id} =
             Idempotency.get(ctx.db, "remedy:wake-remedy", "wake", first_key)

    assert %{session_key: ^producer} = Wakes.get(ctx.db, first_wake_id)

    Org.retire(ctx.db, producer, "user:flynn", 1_000)

    assert {:error, %{producer: ^producer}} =
             Dispatch.dispatch(ctx.db, ctx.handlers, completion_call(assignment.id))

    assert %{status: "live", producer_key: ^producer, occurrence: 2} =
             RailRemedy.episode(ctx.db, "wake-remedy", assignment.id)

    second_key = "rail-dispatch:wake-remedy:#{assignment.id}:2"

    assert %{session_key: second_wake_id} =
             Idempotency.get(ctx.db, "remedy:wake-remedy", "wake", second_key)

    refute second_wake_id == first_wake_id
    assert %{session_key: ^producer} = Wakes.get(ctx.db, second_wake_id)
  end

  test "closed reopen and dead-live replacement bump occurrence and wire key", ctx do
    assignment = assignment(ctx, "terminal")
    load_review_gate(ctx)

    assert {:error, %{producer: first}} =
             Dispatch.dispatch(ctx.db, ctx.handlers, completion_call(assignment.id))

    assert RailRemedy.close(ctx.db, "completion-needs-review", assignment.id, 1)

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

    assert {:ok, 0} =
             DB.transaction(ctx.db, fn txn ->
               DB.Txn.q(
                 txn,
                 """
                 UPDATE rail_remedy_episodes SET status = 'dispatched'
                 WHERE statute = 'completion-needs-review' AND subject = ?1
                   AND status = 'claimed' AND claimToken = 'superseded'
                 """,
                 [assignment.id]
               )

               DB.Txn.changes(txn)
             end)

    assert {:ok, [[1]]} =
             DB.query(
               ctx.db,
               "SELECT COUNT(*) FROM assignments WHERE reviewsAssignmentId = ?1 AND id = ?2",
               [assignment.id, producer]
             )
  end

  test "post-dispatch CAS loser returns quietly without reporting its producer", ctx do
    assignment = assignment(ctx, "post-dispatch-cas-loser")
    [rule] = load_review_gate(ctx)
    winner = "winner-producer"

    handlers =
      Map.put(ctx.handlers, "assign", fn _call ->
        assert {:ok, 1} =
                 DB.transaction(ctx.db, fn txn ->
                   DB.Txn.q(
                     txn,
                     """
                     UPDATE rail_remedy_episodes
                     SET status = 'live', producerKey = ?3
                     WHERE statute = ?1 AND subject = ?2 AND status = 'dispatched'
                     """,
                     [rule.name, assignment.id, winner]
                   )

                   DB.Txn.changes(txn)
                 end)

        %{id: "losing-producer"}
      end)

    assert %{outcome: "claimed-dispatched", producer_id: nil} =
             RailRemedy.fire(
               ctx.db,
               handlers,
               rule,
               assignment.id,
               completion_call(assignment.id)
             )

    assert %{status: "live", producer_key: ^winner, occurrence: 1} =
             RailRemedy.episode(ctx.db, rule.name, assignment.id)
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
    Rules.load!(ctx.base_dir, Map.keys(ctx.handlers))

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

  test "foreign linked verdict keeps the re-wake on the pending review holder", ctx do
    assignment = assignment(ctx, "foreign verdict")
    load_review_gate(ctx)

    assert {:error, %{producer: review_id}} =
             Dispatch.dispatch(ctx.db, ctx.handlers, completion_call(assignment.id))

    verdict_from(ctx, ctx.holder.session_key, review_id, "reviewed-clean")

    assert {:error, %{producer: ^review_id}} =
             Dispatch.dispatch(ctx.db, ctx.handlers, completion_call(assignment.id))

    assert latest_rewake_target(ctx, assignment.id) == ctx.reviewer.session_key
  end

  test "clean verdict on the latest linked card satisfies a stale review episode", ctx do
    assignment = assignment(ctx, "extra linked card")
    load_review_gate(ctx)

    assert {:error, %{producer: _review_id}} =
             Dispatch.dispatch(ctx.db, ctx.handlers, completion_call(assignment.id))

    extra_review = linked_review(ctx, assignment.id, "extra review")
    verdict(ctx, extra_review.id, "reviewed-clean")

    assert {:ok, %{assignment: %{state: "closed", outcome: "completed"}}} =
             Dispatch.dispatch(ctx.db, ctx.handlers, completion_call(assignment.id))
  end

  test "sole linked card holder verdict redirects the re-wake to the producer holder", ctx do
    assignment = assignment(ctx, "holder verdict")
    load_review_gate(ctx)

    assert {:error, %{producer: review_id}} =
             Dispatch.dispatch(ctx.db, ctx.handlers, completion_call(assignment.id))

    verdict(ctx, review_id, "changes-requested")

    assert {:error, %{producer: ^review_id}} =
             Dispatch.dispatch(ctx.db, ctx.handlers, completion_call(assignment.id))

    assert latest_rewake_target(ctx, assignment.id) == ctx.holder.session_key
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

    Rules.load!(ctx.base_dir, Map.keys(ctx.handlers))

    assert {:error, %{reason: "remedy_fired", producer: nil}} =
             Dispatch.dispatch(ctx.db, ctx.handlers, completion_call(assignment.id))

    assert List.last(remedy_events(ctx.db))["outcome"] == "unbound"
  end

  test "assign remedy principal is rejected by every non-assign assignment verb", ctx do
    principal =
      {:remedy, %{statute: "completion-needs-review", action: "assign", owner: "flynn"}}

    expected = %{
      code: "process_denied",
      message: "process principals cannot use assignment verbs"
    }

    calls = [
      {"attest", %{principal: principal, params: %{assignment_id: "missing"}}},
      {"revoke-assignment", %{principal: principal, params: %{assignment_id: "missing"}}},
      {"assignments", %{principal: principal, session_key: ctx.holder.session_key, params: %{}}},
      {"assignment-get", %{principal: principal, params: %{assignment_id: "missing"}}},
      {"attests", %{principal: principal, params: %{assignment_id: "missing"}}}
    ]

    Enum.each(calls, fn {verb, call} ->
      assert Assignments.__handle__(ctx.db, verb, call) == expected
    end)
  end

  test "remedy grammar and F1/F2 reject dead rail sets while conditional blockers load", ctx do
    put_rules(
      ctx,
      String.replace(review_gate(), ~s(produces = "reviewed-clean"), ~s(produces = "other"))
    )

    error =
      assert_raise ArgumentError, fn -> Rules.load!(ctx.base_dir, Map.keys(ctx.handlers)) end

    assert error.message =~ "completion-needs-review"
    assert error.message =~ "does not require"

    # D2: an artifact-gated remedy loads WITHOUT produces — the requirement is
    # statically satisfiable (artifact-record is constitutional) — and escapes
    # the F2 chain walk even where a verdict-gated shape would cycle.
    put_rules(ctx, artifact_gate())
    assert [_] = Rules.load!(ctx.base_dir, Map.keys(ctx.handlers))

    # produces stays verdict-only: an artifact-only gate must omit it.
    put_rules(
      ctx,
      String.replace(
        artifact_gate(),
        "action = \"wake\"",
        ~s(action = "wake"\nproduces = "verified")
      )
    )

    error =
      assert_raise ArgumentError, fn -> Rules.load!(ctx.base_dir, Map.keys(ctx.handlers)) end

    assert error.message =~ "valid only on a verdict-fact gate"

    # A verdict-gated remedy still requires produces.
    put_rules(
      ctx,
      String.replace(review_gate(), ~s(produces = "reviewed-clean"\n), "")
    )

    error =
      assert_raise ArgumentError, fn -> Rules.load!(ctx.base_dir, Map.keys(ctx.handlers)) end

    assert error.message =~ "must be a verdictKind required by the gate"

    put_rules(ctx, external_missing_gate())

    error =
      assert_raise ArgumentError, fn -> Rules.load!(ctx.base_dir, Map.keys(ctx.handlers)) end

    assert error.message =~ "F1"
    assert error.message =~ "missing-producer"

    put_rules(ctx, review_gate())
    error = assert_raise ArgumentError, fn -> Rules.load!(ctx.base_dir, ["attest"]) end
    assert error.message =~ "F2"
    assert error.message =~ "completion-needs-review"
    assert error.message =~ "assign"

    put_rules(ctx, review_gate() <> pure_blocker())

    error =
      assert_raise ArgumentError, fn -> Rules.load!(ctx.base_dir, Map.keys(ctx.handlers)) end

    assert error.message =~ "completion-needs-review"
    assert error.message =~ "block-remedy-assign"

    put_rules(ctx, cycle_rules())

    error =
      assert_raise ArgumentError, fn -> Rules.load!(ctx.base_dir, Map.keys(ctx.handlers)) end

    assert error.message =~ "F2 producer cycle"
    assert error.message =~ "cycle-assign"
    assert error.message =~ "cycle-wake"

    put_rules(ctx, review_gate() <> conditional_blocker())
    assert [_gate, _blocker] = Rules.load!(ctx.base_dir, Map.keys(ctx.handlers))

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
      {String.replace(
         review_gate(),
         ~s(action = "assign"),
         ~s(action = "assign"\non_rule_denied = "retry")
       ), "on_rule_denied must be block or surface"},
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
          Rules.load!(ctx.base_dir, Map.keys(ctx.handlers))
        end

      assert error.message =~ message
    end)
  end

  test "remedy rule-denial policy defaults to block and accepts explicit block", ctx do
    put_rules(ctx, review_gate())

    assert [%{remedy: %{on_rule_denied: "block"}}] =
             Rules.load!(ctx.base_dir, Map.keys(ctx.handlers))

    put_rules(ctx, explicit_block_review_gate())

    assert [%{remedy: %{on_rule_denied: "block"}}] =
             Rules.load!(ctx.base_dir, Map.keys(ctx.handlers))
  end

  defp load_review_gate(ctx) do
    put_rules(ctx, review_gate())
    Rules.load!(ctx.base_dir, Map.keys(ctx.handlers))
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
      { fact = "assignment.effect_kind", op = "in", value = ["code", "policy", "release", "live_mutation"] },
      { fact = "assignment.qualifying_review_verdict_kinds", op = "not_in", value = ["reviewed-clean"] }
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

  defp explicit_block_review_gate do
    String.replace(
      review_gate(),
      ~s(action = "assign"),
      ~s(action = "assign"\non_rule_denied = "block")
    )
  end

  defp surfaced_review_gate do
    String.replace(
      review_gate(),
      ~s(action = "assign"),
      ~s(action = "assign"\non_rule_denied = "surface")
    )
  end

  defp script_assign_gate do
    """

    [[rule]]
    name = "script-block-remedy-assign"
    verb = "assign"
    text = "script blocks remedy assignment"
    [rule.check]
    script = "block-remedy-assign"
    returns = ["block"]
    [rule.check.effects]
    block = "deny"
    """
  end

  defp install_script_assign_gate!(ctx) do
    scripts = Path.join([ctx.base_dir, "identity", "rails", "scripts"])
    bin = Path.join(ctx.base_dir, "bin")
    File.mkdir_p!(scripts)
    File.mkdir_p!(bin)

    script = Path.join(scripts, "block-remedy-assign")

    File.write!(
      script,
      """
      #!/bin/sh
      IFS= read -r input
      case "$input" in
        *'"verb":"assign"'*) ;;
        *) exit 7 ;;
      esac
      case "$input" in
        *'"origin":"remedy:completion-needs-review"'*) ;;
        *) exit 8 ;;
      esac
      case "$input" in
        *'"principal":"remedy:assign:completion-needs-review"'*) printf block ;;
        *) exit 9 ;;
      esac
      """
    )

    File.chmod!(script, 0o755)

    wrapper = Path.join(bin, "tightbeam")
    File.cp!(Path.expand("fixtures/rail_exec/tightbeam", __DIR__), wrapper)
    File.chmod!(wrapper, 0o755)
  end

  defp artifact_gate do
    # verb "wake" with action "wake" would self-cycle in the F2 walk if the
    # artifact requirement did not make the statute escaping.
    """
    [[rule]]
    name = "artifact-gate"
    verb = "wake"
    text = "a results artifact is required"
    effect = "remedy"
    deny_when = [
      { fact = "assignment.artifact_kinds", op = "not_in", value = ["report"] }
    ]
    [rule.remedy]
    action = "wake"
    target_session = "{holder_key}"
    [rule.remedy.params]
    prompt = "record the results artifact for {assignment_id}"
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

  defp wake_gate do
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
    target_session = "reviewer-session"
    [rule.remedy.params]
    prompt = "review {assignment_id}"
    after = 60000
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
      supervision_interval_ms: 1_000,
      params: %{subject: subject, idempotency_key: nil}
    })
  end

  defp linked_review(ctx, assignment_id, subject) do
    Assignments.__handle__(ctx.db, "assign", %{
      verb: "assign",
      origin: "user:flynn",
      principal: {:user, "flynn"},
      session_key: ctx.reviewer.session_key,
      target_role: nil,
      role_fallback: false,
      supervision_interval_ms: 1_000,
      params: %{
        subject: subject,
        reviews_assignment_id: assignment_id,
        idempotency_key: nil
      }
    })
  end

  defp verdict(ctx, assignment_id, kind) do
    verdict_from(ctx, ctx.reviewer.session_key, assignment_id, kind)
  end

  defp verdict_from(ctx, session_key, assignment_id, kind) do
    Assignments.__handle__(ctx.db, "attest", %{
      verb: "attest",
      origin: "agent:#{session_key}",
      principal: {:session, session_key},
      session_key: nil,
      params: %{assignment_id: assignment_id, kind: "verdict", verdict_kind: kind}
    })
  end

  defp latest_rewake_target(ctx, assignment_id) do
    {:ok, [[session_key]]} =
      DB.query(
        ctx.db,
        """
        SELECT w.sessionKey
        FROM wire_idempotency i
        JOIN wakes w ON w.wakeId = i.sessionKey
        WHERE i.operation = 'wake'
          AND i.idempotencyKey LIKE ?1
        ORDER BY w.createdAt DESC, w.wakeId DESC
        LIMIT 1
        """,
        ["rail-rewake:completion-needs-review:#{assignment_id}:%"]
      )

    session_key
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

  defp spawn_handlers(ctx) do
    auth_dir = Path.join([ctx.base_dir, "auth", "codex"])
    File.mkdir_p!(auth_dir)
    File.write!(Path.join(auth_dir, "auth.json"), "{}")
    Archetypes.load!(ctx.base_dir)
    start_model_catalog(ctx)
    start_conn_registry()

    Gateway.handlers(%{
      base_dir: ctx.base_dir,
      cwd: "/tmp",
      port: 0,
      default_harness: :codex,
      default_model: Model.new("test"),
      max_live_sessions_per_user: 50,
      wake_tick_ms: 1_000,
      onboarding_lease_ms: 1_800_000,
      db: ctx.db,
      credential_status: fn _provider -> :onboarded end,
      credential_kind: fn _provider -> :subscription end,
      patch_adapter: fn _harness, _path -> :ok end
    })
  end

  defp start_conn_registry do
    if is_nil(Process.whereis(ConnRegistry)) do
      start_supervised!({ConnRegistry, name: ConnRegistry})
    end
  end

  defp start_model_catalog(ctx) do
    case Process.whereis(ModelCatalog) do
      nil ->
        start_supervised!(
          {ModelCatalog,
           base_dir: ctx.base_dir,
           db: ctx.db,
           credential_status: fn _provider -> :onboarded end,
           credential_kind: fn _provider -> :subscription end,
           credential_kind: fn _provider -> :subscription end,
           credential_kind: fn _provider -> :subscription end,
           claude_fetch: fn _, _ -> {:error, :unused} end,
           sh: fn _command ->
             catalog_reply(
               JSON.encode!(%{
                 models: [
                   %{
                     slug: "test",
                     display_name: "Test",
                     supported_reasoning_levels: []
                   }
                 ]
               })
             )
           end}
        )

        await_catalog()

      _pid ->
        :ok
    end
  end

  defp await_catalog(tries \\ 100)

  defp await_catalog(tries) when tries > 0 do
    case ModelCatalog.get(Tightbeam.Placement.local_host_name(), "codex", ModelCatalog) do
      {_, :fresh} -> :ok
      _ -> Process.sleep(5) && await_catalog(tries - 1)
    end
  end

  defp await_catalog(0), do: flunk("model catalog did not become fresh")

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
      host: Tightbeam.Placement.local_host_name(),
      harness: harness,
      provider: if(harness == "codex", do: "openai", else: "anthropic"),
      model: Model.new("test")
    })
  end
end
