defmodule Tightbeam.HarnessHealthTest do
  use Tightbeam.TestCase, async: false

  alias Tightbeam.{ConditionFacts, DB, EventLog, HarnessHealth, Ledger, Model, Org, Projection}

  setup do
    db = :"harness_health_#{System.unique_integer([:positive])}"
    start_supervised!({DB, path: ":memory:", name: db})
    :ok = Tightbeam.Schema.ensure_all(db)

    sessions =
      for index <- 1..3 do
        session_key = "agent:harness-health:#{index}"

        Org.create(db, %{
          session_key: session_key,
          display_name: "Harness health #{index}",
          owner_user_id: "flynn",
          origin: "user:flynn",
          archetype: "coder",
          host: "gibson",
          harness: "claude",
          provider: "anthropic",
          model: Model.new("claude-fable-5")
        })

        assignment_id = "asg_health_#{index}"

        assert {:ok, []} =
                 DB.query(
                   db,
                   """
                   INSERT INTO assignments
                     (id,subject,holderKey,openedBySession,openedAt,state,holderHarness,holderProvider)
                   VALUES (?1,?2,?3,?3,?4,'open','claude','anthropic')
                   """,
                   [assignment_id, "health assignment #{index}", session_key, index]
                 )

        %{session: session_key, assignment: assignment_id}
      end

    outside_session = "agent:harness-health:outside"

    Org.create(db, %{
      session_key: outside_session,
      display_name: "Healthy harness member",
      owner_user_id: "flynn",
      origin: "user:flynn",
      archetype: "coder",
      host: "eezo",
      harness: "claude",
      provider: "anthropic",
      model: Model.new("claude-fable-5")
    })

    assert {:ok, []} =
             DB.query(
               db,
               """
               INSERT INTO assignments
                 (id,subject,holderKey,openedBySession,openedAt,state,holderHarness,holderProvider)
               VALUES ('asg_health_outside','healthy work',?1,?1,4,'open','claude','anthropic')
               """,
               [outside_session]
             )

    %{db: db, sessions: sessions, outside_session: outside_session}
  end

  test "inference needs two distinct sessions in the bounded window", ctx do
    [first, second, third] = ctx.sessions

    assert {:pending, %{distinctSessions: 1, requiredSessions: 2}} =
             HarnessHealth.observe(ctx.db, failure(first, "auth-dead", 1_000, "failure-1"))

    assert {:duplicate, %{distinctSessions: 1}} =
             HarnessHealth.observe(ctx.db, failure(first, "auth-dead", 1_000, "failure-1"))

    assert HarnessHealth.active(ctx.db) == []
    refute ConditionFacts.harness_unavailable?(ctx.db, "claude", "gibson")

    assert {:pending, %{distinctSessions: 1}} =
             HarnessHealth.observe(
               ctx.db,
               failure(
                 second,
                 "auth-dead",
                 1_000 + HarnessHealth.evidence_window_ms() + 1,
                 "late"
               )
             )

    assert {:opened, opened} =
             HarnessHealth.observe(
               ctx.db,
               failure(
                 third,
                 "auth-dead",
                 1_000 + HarnessHealth.evidence_window_ms() + 2,
                 "failure-3"
               )
             )

    assert opened.failureClass == "auth-dead"
    assert ConditionFacts.harness_failure_standing?(ctx.db, "claude", "gibson", "auth-dead")

    incident = HarnessHealth.get(ctx.db, opened.id)
    assert incident.affectedSessions == Enum.sort(Enum.map(ctx.sessions, & &1.session))
    assert incident.affectedAssignments == Enum.sort(Enum.map(ctx.sessions, & &1.assignment))
    refute ctx.outside_session in incident.affectedSessions
    refute "asg_health_outside" in incident.affectedAssignments
    assert Enum.map(incident.observations, & &1.correlation_id) == ["late", "failure-3"]
  end

  test "authoritative evidence opens at one and the two classes never collapse", ctx do
    [first, second | _] = ctx.sessions

    assert {:opened, auth} =
             HarnessHealth.observe(
               ctx.db,
               authoritative(first, "auth-dead", 10, "provider-auth")
             )

    assert {:opened, rate} =
             HarnessHealth.observe(
               ctx.db,
               authoritative(second, "rate-limit-dead", 11, "provider-rate")
             )

    assert auth.id != rate.id

    assert Enum.map(HarnessHealth.active(ctx.db), & &1.failureClass) ==
             ["auth-dead", "rate-limit-dead"]

    assert ConditionFacts.harness_failure_standing?(ctx.db, "claude", "gibson", "auth-dead")

    assert ConditionFacts.harness_failure_standing?(
             ctx.db,
             "claude",
             "gibson",
             "rate-limit-dead"
           )
  end

  test "terminal error classification preserves auth, rate-limit, and unrelated classes" do
    assert HarnessHealth.classify_turn_failure(%{
             "message" => "Internal error",
             "data" => %{"details" => "auth expired"}
           }) == "auth-dead"

    assert HarnessHealth.classify_turn_failure(%{
             "status" => 429,
             "message" => "too many requests"
           }) ==
             "rate-limit-dead"

    assert HarnessHealth.classify_turn_failure({:acp_exit, 137}) == nil
    assert HarnessHealth.classify_turn_failure(%{"message" => "model not found"}) == nil
  end

  test "provider invalidation emits one auth blocker while rate limiting emits none", ctx do
    main_key = Org.personal_session_key("flynn")

    Org.create(ctx.db, %{
      session_key: main_key,
      display_name: "Main",
      owner_user_id: "flynn",
      origin: "user:flynn",
      archetype: "default",
      host: "gibson",
      harness: "codex",
      provider: "openai",
      model: Model.new("gpt-5")
    })

    assert {:opened, auth} =
             HarnessHealth.observe_provider_invalidation(
               ctx.db,
               "claude",
               "gibson",
               %{"authMode" => nil, "planType" => nil},
               conn_registry: :missing_harness_health_registry
             )

    assert {:attached, attached} =
             HarnessHealth.observe_provider_invalidation(
               ctx.db,
               "claude",
               "gibson",
               %{"authMode" => nil, "planType" => nil},
               conn_registry: :missing_harness_health_registry
             )

    assert attached.id == auth.id
    assert [marker] = Projection.list_after(ctx.db, main_key, nil, 10)
    assert marker.attention_tier == 1
    assert marker.content =~ auth.id
    assert marker.content =~ "A human must restore this credential"

    assert Enum.count(
             EventLog.lifecycle_events(ctx.db),
             &(&1.kind == "harness_health_auth_blocker")
           ) ==
             1

    assert {:opened, _rate} =
             HarnessHealth.observe(
               ctx.db,
               authoritative(hd(ctx.sessions), "rate-limit-dead", 20, "provider-rate-only")
             )

    assert [_marker] = Projection.list_after(ctx.db, main_key, nil, 10)

    assert Enum.count(
             EventLog.lifecycle_events(ctx.db),
             &(&1.kind == "harness_health_auth_blocker")
           ) ==
             1
  end

  test "failed-turn evidence and normal-turn recovery share their terminal CAS", ctx do
    [first, second, third] = ctx.sessions

    for {ref, message_id} <- [{first, "failed-1"}, {second, "failed-2"}] do
      {:ok, _seq} =
        Ledger.enqueue(ctx.db, %{
          session_key: ref.session,
          message_id: message_id,
          origin: "agent:test",
          prompt: "run",
          assignment_id: ref.assignment
        })

      {:ok, turn} = Ledger.claim_next(ctx.db, ref.session, "test-lane")
      turn = Map.put(turn, :session_key, ref.session)
      session = Org.get(ctx.db, ref.session)

      assert {:ok, post_commit} =
               DB.transaction(ctx.db, fn txn ->
                 assert Ledger.finish_in_txn(txn, turn.seq, "failed", "auth expired")

                 HarnessHealth.observe_turn_failure_in_txn(
                   txn,
                   session,
                   turn,
                   :prompt,
                   %{"data" => %{"details" => "auth expired"}}
                 )
               end)

      if is_function(post_commit, 0), do: post_commit.()
    end

    assert [incident] = HarnessHealth.active(ctx.db)
    assert incident.failureClass == "auth-dead"
    evidence = HarnessHealth.get(ctx.db, incident.id).observations

    assert evidence |> Enum.map(& &1.assignment_id) |> MapSet.new() ==
             MapSet.new([first.assignment, second.assignment])

    {:ok, _seq} =
      Ledger.enqueue(ctx.db, %{
        session_key: third.session,
        message_id: "healthy-turn",
        origin: "agent:test",
        prompt: "run",
        assignment_id: third.assignment
      })

    {:ok, turn} = Ledger.claim_next(ctx.db, third.session, "test-lane")
    turn = Map.put(turn, :session_key, third.session)
    session = Org.get(ctx.db, third.session)

    assert {:ok, :ok} =
             DB.transaction(ctx.db, fn txn ->
               assert Ledger.finish_in_txn(txn, turn.seq, "delivered", nil)
               HarnessHealth.resolve_normal_turn_in_txn(txn, session, turn)
             end)

    assert HarnessHealth.active(ctx.db) == []
    assert HarnessHealth.get(ctx.db, incident.id).state == "resolved"
    refute HarnessHealth.unavailable?(ctx.db, "claude", "gibson")
  end

  test "one open incident absorbs later evidence and preserves its first evidence", ctx do
    [first, second, third] = ctx.sessions

    assert {:pending, _} =
             HarnessHealth.observe(ctx.db, failure(first, "rate-limit-dead", 100, "rate-1"))

    assert {:opened, opened} =
             HarnessHealth.observe(ctx.db, failure(second, "rate-limit-dead", 101, "rate-2"))

    assert {:attached, attached} =
             HarnessHealth.observe(ctx.db, failure(third, "rate-limit-dead", 500_000, "rate-3"))

    assert attached.id == opened.id
    assert [active] = HarnessHealth.active(ctx.db)
    assert active.id == opened.id

    incident = HarnessHealth.get(ctx.db, opened.id)
    assert length(incident.observations) == 3
    assert incident.openObservationId == opened.observationId
    assert incident.affectedSessions == Enum.sort(Enum.map(ctx.sessions, & &1.session))
  end

  test "successful normal-turn evidence resolves without deleting history", ctx do
    [first | _] = ctx.sessions

    assert {:opened, opened} =
             HarnessHealth.observe(ctx.db, authoritative(first, "auth-dead", 10, "auth-open"))

    resolution = %{
      harness: "claude",
      host: "gibson",
      failure_class: "auth-dead",
      session_key: first.session,
      assignment_id: first.assignment,
      observed_at: 20,
      correlation_id: "normal-turn-20",
      cause: "normal turn delivered",
      principal: "process:tightbeam"
    }

    assert {:resolved, resolved} = HarnessHealth.resolve(ctx.db, resolution)
    assert resolved.id == opened.id
    assert resolved.state == "resolved"
    refute ConditionFacts.harness_failure_standing?(ctx.db, "claude", "gibson", "auth-dead")

    assert {:duplicate, duplicate} = HarnessHealth.resolve(ctx.db, resolution)
    assert duplicate.id == opened.id
    assert HarnessHealth.active(ctx.db) == []

    incident = HarnessHealth.get(ctx.db, opened.id)
    assert incident.state == "resolved"

    assert Enum.map(incident.observations, & &1.evidence_kind) ==
             ["authoritative-provider", "normal-turn-success"]

    assert {:error, %DB.Error{message: message}} =
             DB.query(ctx.db, "DELETE FROM harness_health_incidents WHERE id=?1", [opened.id])

    assert message =~ "incident history is immutable"
    assert HarnessHealth.get(ctx.db, opened.id).state == "resolved"

    assert {:error, %DB.Error{message: message}} =
             DB.query(
               ctx.db,
               "UPDATE harness_health_incidents SET resolvedAt=resolvedAt+1 WHERE id=?1",
               [opened.id]
             )

    assert message =~ "may resolve exactly once"
  end

  test "correlation idempotency refuses a different event", ctx do
    [first | _] = ctx.sessions
    input = authoritative(first, "auth-dead", 10, "same-correlation")

    assert {:opened, opened} = HarnessHealth.observe(ctx.db, input)
    assert {:duplicate, duplicate} = HarnessHealth.observe(ctx.db, input)
    assert duplicate.id == opened.id

    error =
      assert_raise ArgumentError, fn ->
        HarnessHealth.observe(ctx.db, %{input | cause: "different evidence"})
      end

    assert error.message =~ "already used for different evidence"
    assert [active] = HarnessHealth.active(ctx.db)
    assert active.id == opened.id
  end

  test "evidence cannot claim a different shared harness membership", ctx do
    input = %{
      harness: "claude",
      host: "gibson",
      failure_class: "auth-dead",
      evidence_kind: "terminal-failure",
      session_key: ctx.outside_session,
      assignment_id: "asg_health_outside",
      observed_at: 10,
      correlation_id: "wrong-membership",
      cause: "terminal recovery-chain failure",
      principal: "process:tightbeam"
    }

    assert_raise ArgumentError,
                 "harness health evidence session must use the affected harness",
                 fn ->
                   HarnessHealth.observe(ctx.db, input)
                 end

    assert {:ok, [[0]]} = DB.query(ctx.db, "SELECT COUNT(*) FROM harness_health_observations")
  end

  test "an interrupted caller transaction leaves no partial observation or fact", ctx do
    [first | _] = ctx.sessions
    input = authoritative(first, "auth-dead", 10, "crash-before-commit")

    assert {:error, %RuntimeError{message: "forced interruption"}} =
             DB.transaction(ctx.db, fn txn ->
               assert {:opened, _} = HarnessHealth.observe_in_txn(txn, input)
               raise "forced interruption"
             end)

    assert {:ok, [[0]]} = DB.query(ctx.db, "SELECT COUNT(*) FROM harness_health_observations")
    assert {:ok, [[0]]} = DB.query(ctx.db, "SELECT COUNT(*) FROM harness_health_incidents")

    refute ConditionFacts.harness_failure_standing?(ctx.db, "claude", "gibson", "auth-dead")

    refute Enum.any?(EventLog.lifecycle_events(ctx.db), fn event ->
             event.kind == "harness_health_incident_opened"
           end)
  end

  test "serialized concurrent observations open exactly one incident", ctx do
    [first, second | _] = ctx.sessions

    tasks = [
      Task.async(fn ->
        HarnessHealth.observe(ctx.db, failure(first, "rate-limit-dead", 100, "concurrent-1"))
      end),
      Task.async(fn ->
        HarnessHealth.observe(ctx.db, failure(second, "rate-limit-dead", 100, "concurrent-2"))
      end)
    ]

    results = Enum.map(tasks, &Task.await/1)
    assert Enum.count(results, &match?({:opened, _}, &1)) == 1
    assert Enum.count(results, &match?({:pending, _}, &1)) == 1
    assert length(HarnessHealth.active(ctx.db)) == 1

    assert {:ok, [[1]]} =
             DB.query(
               ctx.db,
               "SELECT COUNT(*) FROM condition_facts WHERE kind='harness-rate-limit-dead'"
             )
  end

  defp failure(ref, failure_class, observed_at, correlation_id) do
    %{
      harness: "claude",
      host: "gibson",
      failure_class: failure_class,
      evidence_kind: "terminal-failure",
      session_key: ref.session,
      assignment_id: ref.assignment,
      observed_at: observed_at,
      correlation_id: correlation_id,
      cause: "terminal recovery-chain failure",
      principal: "process:tightbeam"
    }
  end

  defp authoritative(ref, failure_class, observed_at, correlation_id) do
    ref
    |> failure(failure_class, observed_at, correlation_id)
    |> Map.put(:evidence_kind, "authoritative-provider")
  end
end
