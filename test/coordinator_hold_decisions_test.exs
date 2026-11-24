defmodule Tightbeam.CoordinatorHoldDecisionsTest do
  use Tightbeam.TestCase, async: false
  @moduletag :tmp_dir

  alias Tightbeam.{
    Archetypes,
    CoordinatorHoldDecisions,
    DB,
    Devices,
    Escalation,
    Gateway,
    HarnessHealth,
    HarnessProcess,
    Ledger,
    Model,
    Org,
    Rules,
    Wakes
  }

  alias Tightbeam.DB.Txn
  alias Tightbeam.HarnessHealth.{ModelRateLimit, RecoveryCheck, RecoverySchedule}
  alias Tightbeam.RowReactions.Snapshot

  @owner "fixture-owner"
  @main Org.personal_session_key(@owner)
  @exec "agent:fixture:exec"
  @worker "agent:fixture:worker"
  @at 1_795_313_600_000
  @interval :timer.minutes(5)
  @park {:claude, "shared", "build-host"}
  @model "claude-opus-5-5"
  @wait %{"label" => "Wait"}
  @retry %{"label" => "Capacity is restored, retry now"}

  setup %{tmp_dir: base_dir} do
    previous_archetypes = :persistent_term.get(Archetypes, %{})
    rules_dir = Path.join(base_dir, "identity/rules")
    bundle = Path.join(base_dir, "identity/kungfu/fixture")

    File.mkdir_p!(Path.join(bundle, "archetypes"))
    File.mkdir_p!(rules_dir)

    paths =
      for role <- ~w(exec deliverator exec-assistant) do
        File.write!(Path.join(bundle, "archetypes/#{role}.toml"), ~s(name = "#{role}"))
        "kungfu/fixture/archetypes/#{role}.toml"
      end

    File.write!(Path.join(bundle, "installed.toml"), """
    name = "fixture"
    paths = #{JSON.encode!(paths)}
    """)

    assert %{"fixture.exec" => %{manifest_name: "exec"}} = Archetypes.load!(base_dir)

    on_exit(fn ->
      :persistent_term.put(Archetypes, previous_archetypes)
      Rules.load!(Path.join(base_dir, "absent"), [])
    end)

    Rules.load!(base_dir, [])
    db = start_supervised!({DB, path: ":memory:", name: nil})
    :ok = Tightbeam.Schema.ensure_all(db)
    :ok = Wakes.activate_wait_recognition(db)
    Devices.add_user(db, @owner, true)

    for host <- ~w(build-host second-host third-host) do
      {:ok, []} =
        DB.query(db, "INSERT INTO hosts (name,baseDir) VALUES (?1,?2)", [host, base_dir])
    end

    test = self()

    runner = fn args ->
      send(test, {:harklight_called, args})
      {"unexpected send", 2}
    end

    start_supervised!({Tightbeam.HarklightWakes, db: db, send_runner: runner})
    %{db: db, base_dir: base_dir, rules_dir: rules_dir}
  end

  test "only served coordinator roles count and recovery withdraws the one open request", ctx do
    session(ctx.db, @main, "generic", "build-host")
    session(ctx.db, @exec, "fixture.exec", "second-host")
    session(ctx.db, @worker, "fixture.exec-assistant", "third-host")
    session(ctx.db, "fixture-deliverator", "fixture.deliverator", "build-host")
    assert {:ok, :no_launch} = HarnessProcess.begin_park(ctx.db, @park)

    assert reconcile(ctx) == nil
    assert requests(ctx) == []
    model_hold(ctx.db, @exec, "second-host")
    assert reconcile(ctx) == nil

    assert [%{status: "open", deadline_at: nil, options: [@wait]} = request] = requests(ctx)
    assert request.question =~ "Main, Exec, Deliverator"
    assert request.question =~ "claude on second-host"
    assert request.question =~ "These holds cannot be retried here."
    assert request.question =~ "harness-health-retry <incidentId>"
    refute request.question =~ "third-host"
    refute request.question =~ @exec
    refute request.question =~ @model

    assert_filing_fact(ctx, request.id)
    assert reconcile(ctx, @at + 1) == nil
    assert [^request] = requests(ctx)

    assert :ok = HarnessProcess.complete_park(ctx.db, @park)
    assert reconcile(ctx, @at + 2) == nil
    assert requests(ctx) == []
    assert [%{status: "withdrawn", withdrawn_reason: reason}] = requests(ctx, "all")
    assert reason =~ "can act again"
    assert_no_notifications(ctx)
  end

  test "the persistent floor defers a new episode and restart files it once", ctx do
    session(ctx.db, @main, "generic", "build-host")
    assert {:ok, :no_launch} = HarnessProcess.begin_park(ctx.db, @park)
    assert reconcile(ctx) == nil
    assert [%{id: first}] = requests(ctx)
    assert :ok = HarnessProcess.complete_park(ctx.db, @park)
    assert reconcile(ctx, @at + 1) == nil
    assert {:ok, :no_launch} = HarnessProcess.begin_park(ctx.db, @park)

    due = @at + @interval
    assert reconcile(ctx, due - 1) == due

    assert {:ok, [[nil, nil]]} =
             DB.query(
               ctx.db,
               "SELECT requestId,filedAt FROM coordinator_outage_decisions WHERE closedAt IS NULL"
             )

    assert :ok = HarnessProcess.complete_park(ctx.db, @park)
    assert reconcile(ctx, due - 1) == nil
    assert [%{status: "withdrawn"}] = requests(ctx, "all")
    assert {:ok, :no_launch} = HarnessProcess.begin_park(ctx.db, @park)
    assert reconcile(ctx, due - 1) == due

    opts = [db: ctx.db, clock: fn -> due end]
    server = start_supervised!({CoordinatorHoldDecisions, opts})
    :sys.get_state(server)
    assert [%{id: second}] = requests(ctx)
    assert second != first
    stop_supervised!(CoordinatorHoldDecisions)

    server = start_supervised!({CoordinatorHoldDecisions, opts})
    :sys.get_state(server)
    assert [%{id: ^second}] = requests(ctx)
    assert_filing_fact(ctx, second)
    assert_no_notifications(ctx)
  end

  test "a failure after native filing rolls back the request and its claim together", ctx do
    session(ctx.db, @main, "generic", "build-host")
    assert {:ok, :no_launch} = HarnessProcess.begin_park(ctx.db, @park)

    assert :ok =
             DB.execute(ctx.db, """
             CREATE TEMP TRIGGER fail_claim BEFORE UPDATE OF requestId ON coordinator_outage_decisions
             BEGIN
               SELECT RAISE(ABORT, 'fixture interrupted claim');
             END
             """)

    assert_raise DB.Error, fn -> reconcile(ctx) end
    assert requests(ctx, "all") == []

    assert {:ok, [[0]]} =
             DB.query(
               ctx.db,
               "SELECT COUNT(*) FROM condition_facts WHERE kind='decision-request-filed'"
             )

    assert {:ok, [[0]]} = DB.query(ctx.db, "SELECT COUNT(*) FROM coordinator_outage_decisions")
    assert :ok = DB.execute(ctx.db, "DROP TRIGGER fail_claim")

    server = start_supervised!({CoordinatorHoldDecisions, db: ctx.db, clock: fn -> @at end})
    :sys.get_state(server)
    assert [%{id: id}] = requests(ctx, "all")
    assert_filing_fact(ctx, id)
    assert_no_notifications(ctx)
  end

  test "Wait rules the request without a session or a probe and recovery leaves it ruled", ctx do
    session(ctx.db, @main, "generic", "build-host")
    assert {:ok, :no_launch} = HarnessProcess.begin_park(ctx.db, @park)
    assert reconcile(ctx) == nil
    assert [%{id: request_id}] = requests(ctx)

    assert %{
             status: "ruled",
             decision: "Wait",
             ruling_attribution: %{performer: %{session: %{state: "none"}}}
           } =
             rule(ctx, request_id, "Wait")

    assert HarnessProcess.parked?(ctx.db, @park)
    assert {:ok, [[0]]} = DB.query(ctx.db, "SELECT COUNT(*) FROM coordinator_outage_retries")
    assert :ok = HarnessProcess.complete_park(ctx.db, @park)
    assert reconcile(ctx, @at + 1) == nil
    assert [%{id: ^request_id, status: "ruled", decision: "Wait"}] = requests(ctx, "all")
    assert_no_notifications(ctx)
  end

  test "retry rules the held routes in place and a failed check is readable on the same request",
       ctx do
    load_recovery_policy(ctx)
    session(ctx.db, @main, "generic", "build-host")
    session(ctx.db, @exec, "fixture.exec", "second-host")
    model_hold(ctx.db, @exec, "second-host")
    incident = account_hold(ctx)
    assert HarnessProcess.parked?(ctx.db, @park)
    assert reconcile(ctx) == nil

    assert [%{id: id, options: [@wait, @retry]} = request] = requests(ctx)
    assert request.question =~ "build-host has 1 held"
    assert request.question =~ "Retry now can check these holds."
    assert request.question =~ "second-host has 1 held"
    assert request.question =~ "These holds cannot be retried here."

    assert %{status: "ruled", context: %{"retryStatus" => summary}} =
             rule(ctx, id, @retry["label"])

    assert summary =~ "harness-health-retry <incidentId>"

    assert {:ok, [[cycle_id, due_at, source]]} =
             DB.query(
               ctx.db,
               "SELECT cycleId,dueAt,sourceEventId FROM harness_health_recovery_schedules WHERE holdId=?1",
               [incident]
             )

    refute source =~ "operator-retry:"
    assert [%{"cycle_id" => ^cycle_id}] = RecoverySchedule.fire_due(ctx.db, due_at)
    provider_answer = "The provider still reports a usage limit."
    record_failed_check(ctx, incident, cycle_id, due_at, provider_answer)
    assert HarnessProcess.parked?(ctx.db, @park)
    assert reconcile(ctx, @at + 1) == nil

    assert [%{id: ^id, status: "ruled", context: %{"retryResults" => [result]}}] =
             requests(ctx, "all")

    assert result == %{
             "harness" => "claude",
             "host" => "build-host",
             "outcome" => "failed",
             "providerResponse" => provider_answer
           }

    assert_no_notifications(ctx)
  end

  test "one ruling covers each held incident and joins a check already running", ctx do
    load_recovery_policy(ctx)
    session(ctx.db, @main, "generic", "build-host")
    session(ctx.db, @exec, "fixture.exec", "second-host")
    first = account_hold(ctx)
    now = System.system_time(:millisecond)

    assert [%{"cycle_id" => first_cycle}] = RecoverySchedule.fire_due(ctx.db, now)
    second = account_hold(ctx, @exec, "second-host")
    assert reconcile(ctx) == nil
    assert [%{id: id, options: [@wait, @retry]}] = requests(ctx)
    assert %{status: "ruled"} = rule(ctx, id, @retry["label"])

    assert {:ok, rows} =
             DB.query(
               ctx.db,
               """
               SELECT r.holdId,r.cycleId,s.status
               FROM coordinator_outage_retries r JOIN harness_health_recovery_schedules s
               ON s.holdId=r.holdId AND s.cycleId=r.cycleId
               WHERE r.requestId=?1
               """,
               [id]
             )

    assert [^first, ^first_cycle, "due"] = Enum.find(rows, &(hd(&1) == first))
    assert [^second, second_cycle, "pending"] = Enum.find(rows, &(hd(&1) == second))
    assert is_binary(second_cycle)
    assert length(rows) == 2
    assert_no_notifications(ctx)
  end

  test "the supported retry ruling succeeds if the route recovered after filing", ctx do
    load_recovery_policy(ctx)
    session(ctx.db, @main, "generic", "build-host")
    _incident = account_hold(ctx)
    assert reconcile(ctx) == nil
    assert [%{id: id, options: [@wait, @retry]}] = requests(ctx)
    assert :ok = HarnessProcess.complete_park(ctx.db, @park)

    assert %{status: "ruled", context: %{"retryStatus" => summary}} =
             rule(ctx, id, @retry["label"])

    assert summary =~ "No supported usage-limit hold remains"
    assert reconcile(ctx, @at + 1) == nil
    assert [%{id: ^id, status: "ruled"}] = requests(ctx, "all")
    assert_no_notifications(ctx)
  end

  test "a filing rule can address a held session or refuse an invalid target after the request commits",
       ctx do
    session(ctx.db, @main, "generic", "build-host")
    assert {:ok, :no_launch} = HarnessProcess.begin_park(ctx.db, @park)

    for {name, target} <- [{"held-target", @main}, {"missing-target", "absent-fixture-session"}] do
      File.write!(Path.join(ctx.rules_dir, name <> ".toml"), """
      [[rule]]
      name = "#{name}"
      archetypes = ["*"]
      verb = "condition"
      edges = ["row-commit"]
      effect = "notice"
      text = "An elected rule can observe a filed request"
      deny_when = [
        { fact = "condition_fact.kind", op = "eq", value = "decision-request-filed" },
        { fact = "condition_fact.matches", op = "eq", value = true }
      ]
      [rule.notice]
      target_session = #{inspect(target)}
      prompt = "An operator request was filed"
      """)
    end

    handlers = Gateway.handlers(%{db: ctx.db, wake_tick_ms: 1_000})
    Rules.load!(ctx.base_dir, Map.keys(handlers))
    assert reconcile(ctx) == nil
    assert [%{id: id, status: "open"}] = requests(ctx)
    assert_filing_fact(ctx, id)
    assert HarnessProcess.parked?(ctx.db, @park)

    assert {:ok, [[@main]]} =
             DB.query(ctx.db, "SELECT sessionKey FROM wakes WHERE origin='remedy:held-target'")

    assert {:ok, [[0]]} =
             DB.query(ctx.db, "SELECT COUNT(*) FROM wakes WHERE origin='remedy:missing-target'")

    assert reconcile(ctx, @at + 1) == nil
    assert [%{id: ^id}] = requests(ctx)
    refute_received {:harklight_called, _}
  end

  test "only safe owner work titles and explicit deadlines enter the request", ctx do
    session(ctx.db, @main, "generic", "build-host")
    Org.rename(ctx.db, @main, "Display secret=private-display")
    deadline = @at + 60_000

    for {suffix, title} <- [
          {"safe", "Approved install window"},
          {"secret", "Check token=private-token"},
          {"record", "Investigate asg_private"},
          {"session", "Move #{@main} to a different model"},
          {"uuid", "Investigate 317c35c2-76f1-4ff0-b659-3c616e20e210"}
        ] do
      {:ok, []} =
        DB.query(
          ctx.db,
          """
          INSERT INTO work_items(id,title,ownerUserId,createdByUser,createdAt)
          VALUES (?1,?2,?3,?3,?4)
          """,
          [suffix, title, @owner, @at]
        )

      {:ok, []} =
        DB.query(
          ctx.db,
          """
          INSERT INTO wakes(wakeId,sessionKey,origin,prompt,dueAt,createdAt,state,work_item_id)
          VALUES (?1,?2,'process:tightbeam','Private wake body',?3,?4,'pending',?1)
          """,
          [suffix, @main, deadline, @at]
        )
    end

    assert {:ok, :no_launch} = HarnessProcess.begin_park(ctx.db, @park)
    assert reconcile(ctx) == nil
    assert [%{question: question}] = requests(ctx)
    assert question =~ "Approved install window due"
    assert question =~ "4 held items with deadlines. Earliest due"

    for private <- [
          @main,
          "private-display",
          "private-token",
          "asg_private",
          "317c35c2",
          "Private wake body"
        ] do
      refute question =~ private
    end

    refute_received {:harklight_called, _}
  end

  defp reconcile(ctx, at \\ @at), do: CoordinatorHoldDecisions.reconcile(ctx.db, fn -> at end)

  defp requests(ctx, status \\ "open") do
    handler = Gateway.handlers(%{db: ctx.db, wake_tick_ms: 1_000})["decision-requests"]
    assert %{decision_requests: requests} = handler.(user_call(%{status: status}))
    requests
  end

  defp rule(ctx, id, decision) do
    Escalation.operator_rule(ctx.db, user_call(%{request_id: id, decision: decision}))
  end

  defp user_call(params),
    do: %{origin: "user:" <> @owner, principal: {:user, @owner}, params: params}

  defp session(db, key, archetype, host) do
    Org.create(db, %{
      session_key: key,
      display_name: key,
      owner_user_id: @owner,
      kind: if(key == @main, do: "main", else: "custom"),
      origin: "test",
      archetype: archetype,
      harness: "claude",
      provider: "anthropic",
      host: host,
      model: Model.new(@model)
    })
  end

  defp model_hold(db, key, host) do
    assert {:ok, :recorded} =
             DB.transaction(db, fn txn ->
               ModelRateLimit.record_in_txn(txn, %{
                 harness: "claude",
                 host: host,
                 model: @model,
                 compaction_attempt_key: key <> "/fixture-attempt",
                 observed_at: @at,
                 cause: "fixture 429",
                 principal: "process:tightbeam"
               })
             end)
  end

  defp load_recovery_policy(ctx) do
    seed = Path.join(:code.priv_dir(:tightbeam), "seed/rules/harness-health-recovery.toml")
    File.cp!(seed, Path.join(ctx.rules_dir, Path.basename(seed)))
    Rules.load!(ctx.base_dir, [])
  end

  defp account_hold(ctx, session_key \\ @main, host \\ "build-host") do
    {:ok, {:ok, seq}} =
      DB.transaction(ctx.db, fn txn ->
        {:ok, seq} =
          Ledger.enqueue_in_txn(txn, %{
            session_key: session_key,
            message_id: Tightbeam.Id.uuid4(),
            origin: "fixture",
            prompt: "fixture"
          })

        Txn.q(txn, "UPDATE turns SET status='failed',model=?2 WHERE seq=?1", [seq, @model])
        {:ok, seq}
      end)

    assert {:opened, %{id: incident_id}} =
             HarnessHealth.observe(ctx.db, %{
               correlation_id: "harness-turn:#{seq}:rate-limit-dead",
               session_key: session_key,
               harness: "claude",
               host: host,
               failure_class: "rate-limit-dead",
               evidence_kind: "authoritative-provider",
               observed_at: @at,
               cause: "Fixture account limit",
               principal: "process:tightbeam"
             })

    incident_id
  end

  defp record_failed_check(ctx, incident, cycle, at, excerpt) do
    assert {:ok, :ok} =
             DB.transaction(ctx.db, fn txn ->
               %{"routes" => [route]} = Snapshot.harness_health_hold(txn, incident)
               key = RecoveryCheck.route_key(route)

               Txn.q(
                 txn,
                 """
                 INSERT INTO harness_health_recovery_checks
                   (holdId,cycleId,routeKey,routeJson,harness,host,sharedAccount,model,startedAt,outcome,eventId,org)
                 VALUES (?1,?2,?3,?4,'claude','build-host','shared',?5,?6,'running','fixture-check',?7)
                 """,
                 [incident, cycle, key, JSON.encode!(route), @model, at, @owner]
               )

               RecoveryCheck.record_result_in_txn(
                 txn,
                 incident,
                 cycle,
                 key,
                 "failed",
                 excerpt,
                 at + 1
               )
             end)
  end

  defp assert_filing_fact(ctx, id) do
    assert {:ok, [["process:tightbeam/coordinator-hold", "user:" <> @owner]]} =
             DB.query(
               ctx.db,
               """
               SELECT json_extract(payload,'$.raiserPrincipal'),json_extract(payload,'$.addressedPrincipal')
               FROM condition_facts WHERE kind='decision-request-filed' AND scope=?1
               """,
               [id]
             )
  end

  defp assert_no_notifications(ctx) do
    assert {:ok, [[0]]} = DB.query(ctx.db, "SELECT COUNT(*) FROM wakes WHERE consumer='prompt'")
    refute_received {:harklight_called, _}
  end
end
