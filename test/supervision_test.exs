defmodule Tightbeam.SupervisionTest do
  use Tightbeam.TestCase, async: false

  alias Tightbeam.{
    Adjudication,
    Assignments,
    ConnRegistry,
    ConditionFacts,
    DB,
    Devices,
    Escalation,
    EventLog,
    Gateway,
    Idempotency,
    Ledger,
    Org,
    Placement,
    Projection,
    RailRemedy,
    Roles,
    Rules,
    Supervision,
    Wakes,
    WorkItems,
    WorkState
  }

  defmodule LaneDoorbell do
    use GenServer
    def start_link(name), do: GenServer.start_link(__MODULE__, :ok, name: name)
    def init(state), do: {:ok, state}
    def handle_call({:ensure_lane, _key}, _from, state), do: {:reply, :ok, state}
  end

  defmodule RaceLane do
    use GenServer
    def start_link({name, callback}), do: GenServer.start_link(__MODULE__, callback, name: name)
    def init(callback), do: {:ok, callback}

    def handle_call({:ensure_lane, key}, _from, callback) do
      callback.(key)
      {:reply, :ok, callback}
    end
  end

  defmodule ParkRaceDB do
    use GenServer

    def start_link({name, db, parent, transition}),
      do: GenServer.start_link(__MODULE__, {db, parent, transition}, name: name)

    def init({db, parent, transition}),
      do: {:ok, %{db: db, parent: parent, transition: transition, request_reads: 0}}

    def handle_call({:query, sql, _params} = request, _from, state) do
      result = GenServer.call(state.db, request)

      if current_request_query?(sql) do
        request_reads = state.request_reads + 1
        {:ok, [[id | _]]} = result

        if request_reads == 1 do
          transition_request(state.db, id, state.transition)
          send(state.parent, {:request_changed_before_park, state.transition, id})
        else
          send(state.parent, {:request_rechecked, state.transition, request_reads})
        end

        {:reply, result, %{state | request_reads: request_reads}}
      else
        {:reply, result, state}
      end
    end

    def handle_call(request, _from, state),
      do: {:reply, GenServer.call(state.db, request), state}

    defp current_request_query?(sql) do
      String.contains?(sql, "FROM decision_requests WHERE raiserId") and
        String.contains?(sql, "ORDER BY rowid DESC LIMIT 1")
    end

    defp transition_request(db, id, :rule_allow) do
      {:ok, _} =
        DB.query(
          db,
          "UPDATE decision_requests SET status = 'ruled', decision = 'allow', ruledAt = 1 WHERE id = ?1 AND status = 'open'",
          [id]
        )
    end

    defp transition_request(db, id, :withdraw) do
      {:ok, _} =
        DB.query(
          db,
          "UPDATE decision_requests SET status = 'withdrawn', withdrawnBy = 'session:holder', withdrawnReason = 'race', withdrawnAt = 1 WHERE id = ?1 AND status = 'open'",
          [id]
        )
    end
  end

  setup do
    db = :"supervision_db_#{System.unique_integer([:positive])}"
    start_supervised!({DB, path: ":memory:", name: db})

    for module <- [
          Tightbeam.CausalEvents,
          Devices,
          EventLog,
          Idempotency,
          Projection,
          Org,
          Roles,
          WorkItems,
          Assignments,
          Ledger,
          ConditionFacts,
          Wakes,
          Escalation,
          Supervision,
          WorkState,
          Adjudication,
          RailRemedy
        ] do
      :ok = module.ensure_schema(db)
    end

    {:ok, _} =
      DB.query(db, "INSERT INTO users (userId, isAdmin, createdAt) VALUES ('flynn', 1, 1)")

    main = session(db, Org.personal_session_key("flynn"), nil, true)
    supervisor = session(db, "supervisor", main.session_key)
    holder = session(db, "holder", supervisor.session_key)
    assignment(db, "asg_1", holder.session_key, "ship it", 1)

    # Resolved, not just joined: containment refuses a write root with a symlink component,
    # and macOS's tmp dir is one (`/var` → `/private/var`). A script-tier statute under an
    # unresolved base never reaches its check.
    {tmp, 0} = System.cmd("/bin/realpath", [System.tmp_dir!()])

    base =
      Path.join(String.trim(tmp), "tb-supervision-rules-#{System.unique_integer([:positive])}")

    File.mkdir_p!(base)
    handlers = Gateway.handlers(%{db: db})
    Rules.load!(base, Map.keys(handlers))
    on_exit(fn -> File.rm_rf!(base) end)

    %{
      db: db,
      handlers: handlers,
      main: main,
      supervisor: supervisor,
      holder: holder,
      base: base
    }
  end

  test "schema and neutral row APIs expose the exact durable state", ctx do
    assert Assignments.oldest_open(ctx.db, "holder").id == "asg_1"
    assert Assignments.attest_count(ctx.db, "asg_1") == 0
    assert Ledger.pending_count(ctx.db, "holder") == 0
    assert Ledger.last_terminal_seq(ctx.db, "holder") == nil
    assert Wakes.pending_count(ctx.db, "holder") == 0
    assert Supervision.prod_state(ctx.db, "asg_1") == nil
    assert Supervision.watermark(ctx.db, "holder") == nil

    assert {:ok, columns} = DB.query(ctx.db, "PRAGMA table_info(supervision_watermarks)")
    names = Enum.map(columns, &Enum.at(&1, 1))

    assert names ==
             ~w(sessionKey lastEvaluatedTerminal pendingBranch pendingAssignment pendingK pendingN)

    refute "pendingTarget" in names
  end

  test "prod claims once, counts delivery once, and freezes its outbox numbers", ctx do
    seq = terminal!(ctx.db, "holder")

    assert {:prodded, 1} = Supervision.evaluate(ctx.db, ctx.handlers, 3, "holder", seq)
    assert :duplicate = Supervision.evaluate(ctx.db, ctx.handlers, 99, "holder", seq)

    assert %{attemptCount: 1, prodCount: 1, deniedStreak: 0} =
             Supervision.prod_state(ctx.db, "asg_1")

    assert %{
             lastEvaluatedTerminal: ^seq,
             pendingBranch: nil,
             pendingAssignment: nil,
             pendingK: nil,
             pendingN: nil
           } = Supervision.watermark(ctx.db, "holder")

    assert [wake] = Wakes.list_pending(ctx.db)
    assert wake.session_key == "holder"
    assert wake.origin == "process:tightbeam"
    assert wake.prompt =~ "prod 1 of 3"
    assert wake.reresolve == nil

    assert [%{"decision" => "none", "ref" => "asg_1", "statute" => nil}] =
             rail_sweep_details(ctx.db, "holder")
  end

  test "an internal effort wake does not suppress the no-filing prod", ctx do
    Wakes.schedule(ctx.db, %{
      session_key: "holder",
      origin: "process:tightbeam",
      consumer: "effort_probe",
      due_at: System.system_time(:millisecond) + 60_000
    })

    assert Wakes.pending_count(ctx.db, "holder") == 0
    seq = terminal!(ctx.db, "holder")
    assert {:prodded, 1} = Supervision.evaluate(ctx.db, ctx.handlers, 3, "holder", seq)
  end

  test "progress resets delivered and attempted counters before the next claim", ctx do
    seq1 = terminal!(ctx.db, "holder")
    assert {:prodded, 1} = Supervision.evaluate(ctx.db, ctx.handlers, 2, "holder", seq1)
    [wake] = Wakes.list_pending(ctx.db)
    assert Wakes.cancel(ctx.db, wake.wake_id, wake.origin)

    {:ok, _} =
      DB.query(
        ctx.db,
        "INSERT INTO attests (id, assignmentId, kind, bySession, ts) VALUES ('att_1','asg_1','progress','holder',2)"
      )

    seq2 = terminal!(ctx.db, "holder")
    assert {:prodded, 1} = Supervision.evaluate(ctx.db, ctx.handlers, 2, "holder", seq2)

    assert %{attemptCount: 1, prodCount: 1, attestCount: 1, stalledAt: nil} =
             Supervision.prod_state(ctx.db, "asg_1")
  end

  test "n zero escalates, retired rungs are skipped, and the holder-seeded cycle sinks at Main",
       ctx do
    seq = terminal!(ctx.db, "holder")

    assert {:escalated, 1, "supervisor"} =
             Supervision.evaluate(ctx.db, ctx.handlers, 0, "holder", seq)

    assert [wake] = Wakes.list_pending(ctx.db)
    assert wake.reresolve == "lineage"
    assert wake.reresolve_seed == "holder"
    assert wake.reresolve_rung == 1

    {:ok, _} =
      DB.query(ctx.db, "UPDATE sessions SET spawnedBy = 'holder' WHERE sessionKey = 'supervisor'")

    assert Supervision.ladder_target(ctx.db, "holder", 1) == "supervisor"
    assert Supervision.ladder_target(ctx.db, "holder", 2) == ctx.main.session_key

    Org.retire(ctx.db, "supervisor")
    assert Supervision.ladder_target(ctx.db, "holder", 1) == ctx.main.session_key
  end

  test "a retired holder with a pending wake is stranded before continuation", ctx do
    existing =
      Wakes.schedule(ctx.db, %{
        session_key: "holder",
        target_role: nil,
        origin: "user:flynn",
        prompt: "later",
        due_at: System.system_time(:millisecond) + 60_000
      })

    seq = terminal!(ctx.db, "holder")
    Org.retire(ctx.db, "holder")

    assert :stranded = Supervision.evaluate(ctx.db, ctx.handlers, 3, "holder", seq)

    assert %{lastEvaluatedTerminal: ^seq} = Supervision.watermark(ctx.db, "holder")
    assert [%{wake_id: wake_id}] = Wakes.list_pending(ctx.db)
    assert wake_id == existing.wake_id

    stranded =
      Assignments.list(ctx.db, %{holder_key: "holder", state: "open"})
      |> Enum.filter(fn assignment ->
        Org.get(ctx.db, assignment.holderKey).state == "retired"
      end)

    assert Enum.map(stranded, & &1.id) == ["asg_1"]
  end

  test "an open model adjudication episode holds before rails and prod", ctx do
    seq = terminal!(ctx.db, "holder")
    now = System.system_time(:millisecond)

    {:ok, _} =
      DB.query(
        ctx.db,
        """
        INSERT INTO adjudication_episodes
          (sessionKey, condition, status, correlationKey, deadlineAt, openedAt)
        VALUES ('holder', 'quota_exhausted', 'claimed', 'adj_hold', ?1, ?2)
        """,
        [now + 60_000, now]
      )

    assert {:held, :adjudication_hold} =
             Supervision.evaluate(ctx.db, ctx.handlers, 3, "holder", seq)

    assert %{lastEvaluatedTerminal: ^seq} = Supervision.watermark(ctx.db, "holder")
    assert Wakes.list_pending(ctx.db) == []
    assert rail_sweep_details(ctx.db, "holder") == []
  end

  test "turn-end remedy acts once through the episode claim and records run-remedy", ctx do
    prepare_review_gate(ctx)
    seq = terminal!(ctx.db, "holder")

    assert {:acted, :rail_remedy} =
             Supervision.evaluate(ctx.db, ctx.handlers, 3, "holder", seq)

    assert :duplicate = Supervision.evaluate(ctx.db, ctx.handlers, 3, "holder", seq)

    assert %{status: "live", occurrence: 1, producer_key: producer_key} =
             RailRemedy.episode(ctx.db, "completion-needs-review", "asg_1")

    assert is_binary(producer_key)

    assert {:ok, [[1]]} =
             DB.query(
               ctx.db,
               "SELECT COUNT(*) FROM assignments WHERE reviewsAssignmentId = 'asg_1'"
             )

    assert [
             %{
               "decision" => "run-remedy",
               "ref" => "asg_1",
               "statute" => "completion-needs-review"
             }
           ] = rail_sweep_details(ctx.db, "holder")

    assert Supervision.prod_state(ctx.db, "asg_1") == nil
  end

  test "turn-end escalation still opens and parks the same decision request", ctx do
    write_rules(
      ctx,
      """
      [[rule]]
      name = "completion-needs-owner"
      verb = "attest"
      text = "owner approval required"
      edges = ["verb", "turn-end"]
      effect = "escalate"
      deny_when = [
        { fact = "attest.kind", op = "eq", value = "completion" }
      ]
      """
    )

    seq = terminal!(ctx.db, "holder")

    assert {:acted, :rail_escalate} =
             Supervision.evaluate(ctx.db, ctx.handlers, 3, "holder", seq)

    assert {:ok, [[id, "open", park_wake_id]]} =
             DB.query(
               ctx.db,
               "SELECT id, status, parkWakeId FROM decision_requests WHERE statuteName = 'completion-needs-owner'"
             )

    assert is_binary(id)
    assert is_binary(park_wake_id)

    assert %{condition_kind: "escalation-ruled", condition_scope: ^id} =
             Wakes.get(ctx.db, park_wake_id)

    assert [
             %{
               "decision" => "escalate-park",
               "ref" => "asg_1",
               "statute" => "completion-needs-owner"
             }
           ] = rail_sweep_details(ctx.db, "holder")
  end

  test "a permanently skipped park does not re-evaluate inline or starve the server", ctx do
    write_rules(
      ctx,
      """
      [[rule]]
      name = "completion-needs-owner"
      verb = "attest"
      text = "owner approval required"
      edges = ["verb", "turn-end"]
      effect = "escalate"
      deny_when = [
        { fact = "attest.kind", op = "eq", value = "completion" }
      ]
      """
    )

    assert {:acted, :rail_escalate} =
             Supervision.evaluate(ctx.db, ctx.handlers, 3, "holder", terminal!(ctx.db, "holder"))

    {:ok, [[id, park_wake_id]]} =
      DB.query(ctx.db, "SELECT id, parkWakeId FROM decision_requests")

    proxy = :"park_rule_race_db_#{System.unique_integer([:positive])}"
    start_supervised!({ParkRaceDB, {proxy, ctx.db, self(), :rule_allow}})
    name = :"park_no_spin_supervision_#{System.unique_integer([:positive])}"

    start_supervised!(
      {Supervision,
       db: proxy, handlers: ctx.handlers, prod_limit: 3, sweep_ms: 60_000, name: name}
    )

    :sys.get_state(name)
    assert Wakes.cancel(ctx.db, park_wake_id, "process:tightbeam")

    {:ok, _} =
      DB.query(ctx.db, "UPDATE decision_requests SET parkWakeId = NULL WHERE id = ?1", [id])

    retry_seq = terminal!(ctx.db, "holder")
    Supervision.notify_terminal(name, "holder", retry_seq)

    assert_receive {:request_changed_before_park, :rule_allow, ^id}

    # The first barrier proves the terminal handler returned. If that handler self-cast a
    # retry, the cast may sit just behind this already-queued call; the second barrier is
    # necessarily behind it and therefore proves that no inline retry was left to run.
    :sys.get_state(name)
    :sys.get_state(name)
    refute_receive {:request_rechecked, :rule_allow, _}

    assert {:ok, [["ruled", nil]]} =
             DB.query(ctx.db, "SELECT status, parkWakeId FROM decision_requests WHERE id = ?1", [
               id
             ])

    refute match?(
             %{lastEvaluatedTerminal: ^retry_seq},
             Supervision.watermark(ctx.db, "holder")
           )
  end

  test "the production sweep re-drives a permanent skip and parks a still-live obligation",
       ctx do
    write_rules(
      ctx,
      """
      [[rule]]
      name = "completion-needs-owner"
      verb = "attest"
      text = "owner approval required"
      edges = ["verb", "turn-end"]
      effect = "escalate"
      deny_when = [
        { fact = "attest.kind", op = "eq", value = "completion" }
      ]
      """
    )

    assert {:acted, :rail_escalate} =
             Supervision.evaluate(ctx.db, ctx.handlers, 3, "holder", terminal!(ctx.db, "holder"))

    {:ok, [[stale_id, park_wake_id]]} =
      DB.query(ctx.db, "SELECT id, parkWakeId FROM decision_requests")

    proxy = :"park_withdraw_race_db_#{System.unique_integer([:positive])}"
    start_supervised!({ParkRaceDB, {proxy, ctx.db, self(), :withdraw}})
    name = :"park_sweep_supervision_#{System.unique_integer([:positive])}"

    start_supervised!(
      {Supervision, db: proxy, handlers: ctx.handlers, prod_limit: 3, sweep_ms: 10, name: name}
    )

    :sys.get_state(name)
    assert Wakes.cancel(ctx.db, park_wake_id, "process:tightbeam")

    {:ok, _} =
      DB.query(ctx.db, "UPDATE decision_requests SET parkWakeId = NULL WHERE id = ?1", [stale_id])

    retry_seq = terminal!(ctx.db, "holder")
    Supervision.notify_terminal(name, "holder", retry_seq)

    assert_receive {:request_changed_before_park, :withdraw, ^stale_id}
    assert_receive {:request_rechecked, :withdraw, 2}

    assert eventually(fn ->
             match?(
               {:ok, [[^stale_id, "withdrawn", nil], [new_id, "open", park_wake_id]]}
               when new_id != stale_id and is_binary(park_wake_id),
               DB.query(
                 ctx.db,
                 "SELECT id, status, parkWakeId FROM decision_requests ORDER BY rowid"
               )
             )
           end),
           "the scheduled supervision sweep never parked the replacement request"

    assert %{lastEvaluatedTerminal: ^retry_seq} = Supervision.watermark(ctx.db, "holder")
  end

  test "only a durable self-created continuation suppresses the turn-end remedy", ctx do
    prepare_review_gate(ctx)

    self_wake =
      Wakes.schedule(ctx.db, %{
        session_key: "holder",
        target_role: nil,
        origin: "user:flynn",
        prompt: "self continuation",
        due_at: System.system_time(:millisecond) + 60_000,
        creator_session_key: "holder"
      })

    assert Wakes.self_pending_count(ctx.db, "holder") == 1
    seq = terminal!(ctx.db, "holder")
    assert :continuation = Supervision.evaluate(ctx.db, ctx.handlers, 3, "holder", seq)
    assert RailRemedy.episode(ctx.db, "completion-needs-review", "asg_1") == nil
    assert Supervision.prod_state(ctx.db, "asg_1") == nil

    assert Wakes.cancel(ctx.db, self_wake.wake_id, self_wake.origin)

    reminder =
      Wakes.schedule(ctx.db, %{
        session_key: "holder",
        target_role: nil,
        origin: "user:flynn",
        prompt: "user reminder",
        due_at: System.system_time(:millisecond) + 60_000,
        creator_session_key: nil
      })

    assert Wakes.pending_count(ctx.db, "holder") == 1
    assert Wakes.self_pending_count(ctx.db, "holder") == 0

    assert {:acted, :rail_remedy} =
             Supervision.evaluate(ctx.db, ctx.handlers, 3, "holder", seq)

    assert %{status: "live"} =
             RailRemedy.episode(ctx.db, "completion-needs-review", "asg_1")

    assert Wakes.get(ctx.db, reminder.wake_id).state == "pending"
    assert Supervision.prod_state(ctx.db, "asg_1") == nil
  end

  test "turn-end denial without a remedy records re-obligate and uses the normal prod", ctx do
    load_turn_end_deny(ctx)
    seq = terminal!(ctx.db, "holder")

    assert {:prodded, 1} = Supervision.evaluate(ctx.db, ctx.handlers, 3, "holder", seq)

    assert [
             %{
               "decision" => "re-obligate",
               "ref" => "asg_1",
               "statute" => "completion-still-owed"
             }
           ] = rail_sweep_details(ctx.db, "holder")
  end

  # The sweep is the second actor, so the ruling of 2026-07-29 (rails-mechanism §A3) has
  # to reach it too: a rail-check timeout summons a mind here as well. What it must NOT do
  # is park the session — parking is the escalate EFFECT's consequence, and the ruling
  # changed what a timeout additionally does, not what it decides. So the sweep outcome
  # stays the pure deny's: re-obligate, then the normal prod.
  test "a turn-end timeout summons a mind and still re-obligates without parking", ctx do
    stage_rail_wrapper(ctx, "rail-timeout")

    write_rules(ctx, """
    [[rule]]
    name = "completion-check-times-out"
    verb = "attest"
    text = "completion is gated on a check"
    edges = ["turn-end"]
    [rule.check]
    script = "rail-timeout"
    returns = ["pass"]
    [rule.check.effects]
    pass = "allow"
    """)

    seq = terminal!(ctx.db, "holder")

    assert {:prodded, 1} = Supervision.evaluate(ctx.db, ctx.handlers, 3, "holder", seq)

    assert [
             %{
               "decision" => "re-obligate",
               "ref" => "asg_1",
               "statute" => "completion-check-times-out"
             }
           ] = rail_sweep_details(ctx.db, "holder")

    assert {:ok, [["completion-check-times-out", "open", nil]]} =
             DB.query(ctx.db, "SELECT statuteName, status, parkWakeId FROM decision_requests")
  end

  # Recovery through the SWEEP, driven by the real `Supervision.evaluate/5` wiring rather
  # than by calling `Rules.decide` and the close by hand — the point is that the sweep
  # actually runs its `to_close`, which hand-calling the pieces would assume rather than
  # prove. The sensor heals between two turn-ends and the episode closes with no operator
  # verb anywhere in the loop.
  test "the turn-end sweep recovers an episode once the check answers again", ctx do
    stage_rail_wrapper(ctx, "rail-timeout")

    gate = fn script ->
      write_rules(ctx, """
      [[rule]]
      name = "completion-check-times-out"
      verb = "attest"
      text = "completion is gated on a check"
      edges = ["turn-end"]
      [rule.check]
      script = "#{script}"
      returns = ["pass"]
      [rule.check.effects]
      pass = "allow"
      """)
    end

    gate.("rail-timeout")

    assert {:prodded, 1} =
             Supervision.evaluate(ctx.db, ctx.handlers, 3, "holder", terminal!(ctx.db, "holder"))

    assert {:ok, [[id, "open"]]} =
             DB.query(ctx.db, "SELECT id, status FROM decision_requests")

    # A pending prod wake suppresses the next sweep, so clear it the way the prod-counter
    # tests do — the turn under test is the one AFTER the sensor heals.
    for wake <- Wakes.list_pending(ctx.db), do: Wakes.cancel(ctx.db, wake.wake_id, wake.origin)

    # The check recovers. The next sweep renders an observed verdict and the episode goes
    # with it — through the sweep's own actor path.
    stage_rail_script(ctx, "rail-pass", "#!/bin/sh\nprintf pass\n")
    gate.("rail-pass")

    assert {:prodded, _} =
             Supervision.evaluate(ctx.db, ctx.handlers, 3, "holder", terminal!(ctx.db, "holder"))

    assert {:ok, [["withdrawn", "process:tightbeam", "sensor-recovered"]]} =
             DB.query(
               ctx.db,
               "SELECT status, withdrawnBy, withdrawnReason FROM decision_requests WHERE id = ?1",
               [id]
             )
  end

  test "atomic target gate skips plain dead targets and re-runs the ladder for escalation", ctx do
    registry = start_supervised!({ConnRegistry, name: :supervision_conn_registry})
    lane = start_supervised!({LaneDoorbell, :supervision_lane_manager})
    Org.retire(ctx.db, "supervisor")

    plain =
      Wakes.schedule(ctx.db, %{
        session_key: "supervisor",
        target_role: nil,
        origin: "process:tightbeam",
        prompt: "plain",
        due_at: 0
      })

    assert :skipped =
             Gateway.deliver_prompt("supervisor", "process:tightbeam", "plain",
               db: ctx.db,
               wake_id: plain.wake_id,
               sender: "process:tightbeam",
               target_gate: plain,
               fire_wake_in_txn: true,
               conn_registry: registry,
               lane_manager: lane
             )

    assert Ledger.pending_count(ctx.db, "supervisor") == 0
    assert Wakes.get(ctx.db, plain.wake_id).state == "pending"
    assert Wakes.cancel(ctx.db, plain.wake_id, plain.origin)

    gate = %{reresolve: "lineage", reresolve_seed: "holder", reresolve_rung: 1}

    assert :appended =
             Gateway.deliver_prompt("supervisor", "process:tightbeam", "escalate",
               db: ctx.db,
               wake_id: "w_lineage",
               sender: "process:tightbeam",
               target_gate: gate,
               conn_registry: registry,
               lane_manager: lane
             )

    assert Ledger.pending_count(ctx.db, ctx.main.session_key) == 1
    assert Ledger.pending_count(ctx.db, "holder") == 0
  end

  test "supervision wake is fired in the enqueue transaction before its provoked terminal", ctx do
    seq = terminal!(ctx.db, "holder")
    assert {:prodded, 1} = Supervision.evaluate(ctx.db, ctx.handlers, 2, "holder", seq)
    [originating] = Wakes.list_pending(ctx.db)

    parent = self()
    registry = start_supervised!({ConnRegistry, name: :atomic_fire_registry})

    lane =
      start_supervised!(
        {RaceLane,
         {:atomic_fire_lane,
          fn "holder" ->
            state_at_nudge = Wakes.get(ctx.db, originating.wake_id).state
            assert {:ok, turn} = Ledger.claim_next(ctx.db, "holder", "atomic-fire-race")
            assert turn.wake_id == originating.wake_id
            assert :ok = Ledger.finish(ctx.db, turn.seq, "delivered")
            result = Supervision.evaluate(ctx.db, ctx.handlers, 2, "holder", turn.seq)
            send(parent, {:race_result, state_at_nudge, result})
          end}}
      )

    scheduler =
      start_supervised!(
        {Wakes,
         db: ctx.db,
         deliver: delivery_fun(ctx.db, registry, lane),
         tick_ms: 60_000,
         name: :atomic_fire_scheduler}
      )

    assert :ok = Wakes.fire_due(scheduler)
    assert_receive {:race_result, "fired", {:prodded, 2}}
    assert Wakes.get(ctx.db, originating.wake_id).state == "fired"
    assert [%{prompt: next_prompt}] = Wakes.list_pending(ctx.db)
    assert next_prompt =~ "prod 2 of 2"
  end

  test "external direct wake keeps deliver-then-mark ordering", ctx do
    external =
      Wakes.schedule(ctx.db, %{
        session_key: "holder",
        target_role: nil,
        origin: "process:ci",
        prompt: "external",
        due_at: 0
      })

    parent = self()
    registry = start_supervised!({ConnRegistry, name: :external_order_registry})

    lane =
      start_supervised!(
        {RaceLane,
         {:external_order_lane,
          fn "holder" ->
            send(parent, {:external_state_at_nudge, Wakes.get(ctx.db, external.wake_id).state})
          end}}
      )

    scheduler =
      start_supervised!(
        {Wakes,
         db: ctx.db,
         deliver: delivery_fun(ctx.db, registry, lane),
         tick_ms: 60_000,
         name: :external_order_scheduler}
      )

    assert :ok = Wakes.fire_due(scheduler)
    assert_receive {:external_state_at_nudge, "pending"}
    assert Wakes.get(ctx.db, external.wake_id).state == "fired"
  end

  test "repeated synchronous delivery racer advances every prod and quiesces only at Main terminus",
       ctx do
    n = 12
    assignment(ctx.db, "asg_main", ctx.main.session_key, "main work", 2)
    seq = terminal!(ctx.db, ctx.main.session_key)

    assert {:prodded, 1} =
             Supervision.evaluate(ctx.db, ctx.handlers, n, ctx.main.session_key, seq)

    parent = self()
    registry = start_supervised!({ConnRegistry, name: :repeated_race_registry})

    lane =
      start_supervised!(
        {RaceLane,
         {:repeated_race_lane,
          fn session_key ->
            assert {:ok, turn} = Ledger.claim_next(ctx.db, session_key, "repeated-race")
            state_at_nudge = Wakes.get(ctx.db, turn.wake_id).state
            assert :ok = Ledger.finish(ctx.db, turn.seq, "delivered")
            result = Supervision.evaluate(ctx.db, ctx.handlers, n, session_key, turn.seq)
            send(parent, {:iteration_result, turn.wake_id, state_at_nudge, result})
          end}}
      )

    scheduler =
      start_supervised!(
        {Wakes,
         db: ctx.db,
         deliver: delivery_fun(ctx.db, registry, lane),
         tick_ms: 60_000,
         name: :repeated_race_scheduler}
      )

    for iteration <- 1..n do
      assert :ok = Wakes.fire_due(scheduler)
      assert_receive {:iteration_result, wake_id, "fired", result}
      assert Wakes.get(ctx.db, wake_id).state == "fired"

      if iteration < n do
        assert result == {:prodded, iteration + 1}
      else
        assert result == :terminus
      end
    end

    assert Wakes.pending_count(ctx.db, ctx.main.session_key) == 0
    assert Ledger.pending_count(ctx.db, ctx.main.session_key) == 0
    assert %{pendingBranch: nil} = Supervision.watermark(ctx.db, ctx.main.session_key)

    assert Enum.count(EventLog.lifecycle_events(ctx.db), &(&1.kind == "supervision_terminus")) ==
             1
  end

  test "delivered prod and escalation prompts match the stamped templates byte for byte", ctx do
    registry = start_supervised!({ConnRegistry, name: :template_registry})
    lane = start_supervised!({LaneDoorbell, :template_lane})

    prod_seq = terminal!(ctx.db, "holder")
    assert {:prodded, 1} = Supervision.evaluate(ctx.db, ctx.handlers, 3, "holder", prod_seq)
    [prod] = Wakes.list_pending(ctx.db)

    assert :appended =
             Gateway.deliver_prompt(prod.session_key, prod.origin, prod.prompt,
               db: ctx.db,
               wake_id: prod.wake_id,
               sender: prod.origin,
               target_gate: prod,
               fire_wake_in_txn: true,
               conn_registry: registry,
               lane_manager: lane
             )

    expected_prod =
      "[from process:tightbeam]\n\n" <>
        "Your turn ended with no filing and no continuation scheduled for assignment asg_1 — \"ship it\". " <>
        "File completion, schedule your continuation, or file surrender. This is prod 1 of 3; " <>
        "a reply without a row escalates to your spawner."

    assert {:ok, [[^expected_prod]]} =
             DB.query(ctx.db, "SELECT prompt FROM turns WHERE wakeId = ?1", [prod.wake_id])

    # v1 excluded prod turns from attribution for want of a durable carrier;
    # job-forensics-v2 gives the wake one, so the delivered turn now inherits it.
    # jobRef stays NULL here because this assignment belongs to no work item.
    assert prod.assignment_id == "asg_1"

    assert {:ok, [["asg_1", nil]]} =
             DB.query(
               ctx.db,
               "SELECT assignmentId, jobRef FROM turns WHERE wakeId = ?1",
               [prod.wake_id]
             )

    session(ctx.db, "escalating-holder", ctx.supervisor.session_key)
    assignment(ctx.db, "asg_escalation", "escalating-holder", "investigate", 3)
    escalation_seq = terminal!(ctx.db, "escalating-holder")

    assert {:escalated, 1, "supervisor"} =
             Supervision.evaluate(ctx.db, ctx.handlers, 0, "escalating-holder", escalation_seq)

    [escalation] = Wakes.list_pending(ctx.db)

    assert :appended =
             Gateway.deliver_prompt(escalation.session_key, escalation.origin, escalation.prompt,
               db: ctx.db,
               wake_id: escalation.wake_id,
               sender: escalation.origin,
               target_gate: escalation,
               fire_wake_in_txn: true,
               conn_registry: registry,
               lane_manager: lane
             )

    expected_escalation =
      "[from process:tightbeam]\n\n" <>
        "Assignment asg_escalation — \"investigate\" — held by escalating-holder is stalled: " <>
        "0 prods produced no filing and no continuation. This is escalation 1 for this assignment. " <>
        "Why, and what happens next, is your judgment — the substrate only reports the rows."

    assert {:ok, [[^expected_escalation]]} =
             DB.query(ctx.db, "SELECT prompt FROM turns WHERE wakeId = ?1", [escalation.wake_id])
  end

  test "wake validation requires the complete re-resolution triple and nudge false leaves due work pending",
       ctx do
    wake = ctx.handlers["wake"]

    invalid = %{
      origin: "process:tightbeam",
      session_key: "holder",
      params: %{prompt: "x", reresolve: "lineage"}
    }

    assert %{code: "invalid"} = wake.(invalid)

    valid = %{
      origin: "process:tightbeam",
      session_key: "supervisor",
      params: %{
        prompt: "x",
        after_ms: 0,
        nudge: false,
        reresolve: "lineage",
        reresolve_seed: "holder",
        reresolve_rung: 1
      }
    }

    assert %{state: "pending"} = wake.(valid)
    assert [%{reresolve: "lineage"}] = Wakes.list_pending(ctx.db)
  end

  test "transient refusal preserves the outbox and a later edge drains without recounting", ctx do
    transient = Map.put(ctx.handlers, "wake", fn _ -> %{code: "server_error"} end)
    seq1 = terminal!(ctx.db, "holder")

    assert {:refused, "server_error"} =
             Supervision.evaluate(ctx.db, transient, 3, "holder", seq1)

    assert %{attemptCount: 1, prodCount: 0} = Supervision.prod_state(ctx.db, "asg_1")

    assert %{pendingBranch: "prod", pendingK: 1, pendingN: 3} =
             Supervision.watermark(ctx.db, "holder")

    seq2 = terminal!(ctx.db, "holder")
    assert :continuation = Supervision.evaluate(ctx.db, ctx.handlers, 3, "holder", seq2)
    assert %{attemptCount: 1, prodCount: 1} = Supervision.prod_state(ctx.db, "asg_1")

    assert %{lastEvaluatedTerminal: ^seq1, pendingBranch: nil} =
             Supervision.watermark(ctx.db, "holder")

    assert Enum.count(
             EventLog.lifecycle_events(ctx.db),
             &(&1.kind == "supervision_dispatch_failed")
           ) == 1
  end

  test "statute-tier denials clear atomically, count attempts only, and block at the threshold",
       ctx do
    denied = Map.put(ctx.handlers, "wake", fn _ -> %{code: "rule_denied"} end)
    seq1 = terminal!(ctx.db, "holder")
    seq2 = terminal!(ctx.db, "holder")

    assert {:refused, "rule_denied"} = Supervision.evaluate(ctx.db, denied, 2, "holder", seq1)
    assert {:refused, "rule_denied"} = Supervision.evaluate(ctx.db, denied, 2, "holder", seq2)

    assert %{attemptCount: 2, prodCount: 0, deniedStreak: 2, lastProdAt: nil} =
             Supervision.prod_state(ctx.db, "asg_1")

    assert %{pendingBranch: nil, lastEvaluatedTerminal: ^seq2} =
             Supervision.watermark(ctx.db, "holder")

    lifecycle = EventLog.lifecycle_events(ctx.db)
    assert Enum.count(lifecycle, &(&1.kind == "supervision_prod_denied")) == 2
    assert Enum.count(lifecycle, &(&1.kind == "supervision_blocked")) == 1
    assert Wakes.list_pending(ctx.db) == []
  end

  test "drain precedes idle and dedupe for a stale closed-assignment promise", ctx do
    transient = Map.put(ctx.handlers, "wake", fn _ -> %{code: "server_error"} end)
    seq = terminal!(ctx.db, "holder")
    assert {:refused, "server_error"} = Supervision.evaluate(ctx.db, transient, 3, "holder", seq)

    {:ok, _} =
      DB.query(
        ctx.db,
        "UPDATE assignments SET state='closed', outcome='revoked', closedAt=2, closedByUser='flynn' WHERE id='asg_1'"
      )

    assert :idle = Supervision.evaluate(ctx.db, ctx.handlers, 3, "holder", seq)

    assert %{pendingBranch: nil, lastEvaluatedTerminal: ^seq} =
             Supervision.watermark(ctx.db, "holder")

    assert %{attemptCount: 1, prodCount: 0} = Supervision.prod_state(ctx.db, "asg_1")
    assert Wakes.list_pending(ctx.db) == []
  end

  test "Main self-target takes the no-wake terminus exactly once", ctx do
    assignment(ctx.db, "asg_main", ctx.main.session_key, "main work", 2)
    seq = terminal!(ctx.db, ctx.main.session_key)

    assert :terminus =
             Supervision.evaluate(ctx.db, ctx.handlers, 0, ctx.main.session_key, seq)

    assert :duplicate =
             Supervision.evaluate(ctx.db, ctx.handlers, 0, ctx.main.session_key, seq)

    assert %{attemptCount: 1, prodCount: 0, stalledAt: stalled} =
             Supervision.prod_state(ctx.db, "asg_main")

    assert is_integer(stalled)
    assert Wakes.list_pending(ctx.db) == []

    assert Enum.count(EventLog.lifecycle_events(ctx.db), &(&1.kind == "supervision_terminus")) ==
             1
  end

  test "request sweep reclaims one suppressed terminal and never reclaims it twice", ctx do
    continuation =
      Wakes.schedule(ctx.db, %{
        session_key: "holder",
        target_role: nil,
        origin: "user:flynn",
        prompt: "later",
        due_at: System.system_time(:millisecond) + 60_000
      })

    seq = terminal!(ctx.db, "holder")
    assert :continuation = Supervision.evaluate(ctx.db, ctx.handlers, 3, "holder", seq)
    assert Wakes.cancel(ctx.db, continuation.wake_id, continuation.origin)

    name = :"supervision_#{System.unique_integer([:positive])}"

    start_supervised!(
      {Supervision, db: ctx.db, handlers: ctx.handlers, prod_limit: 3, name: name}
    )

    Supervision.request_sweep(name)

    # BOTH sweeps are casts, and :sys.get_state is answered in mailbox order, so
    # each has RUN when its barrier returns. The FIRST barrier is the one that
    # made this test flaky: polling prod_state instead let first_count be read
    # before the sweep had written its wake, and the test then compared a
    # post-sweep count against a pre-sweep one — measured red in 2 of 3 combined
    # runs on an idle 16-core mac, both as `1 == 0`. The second sleep(20) was a
    # false pass in the other direction: a still-queued cast read as "did not
    # reclaim twice", the one thing this test exists to prove.
    :sys.get_state(name)

    assert Supervision.prod_state(ctx.db, "asg_1") != nil,
           "the first sweep never reclaimed the suppressed terminal"

    first_count = length(Wakes.list_pending(ctx.db))
    Supervision.request_sweep(name)
    :sys.get_state(name)
    assert length(Wakes.list_pending(ctx.db)) == first_count
    assert first_count == 1
  end

  test "total catch contains exits and records evaluation failure without losing the claim",
       ctx do
    exiting = Map.put(ctx.handlers, "wake", fn _ -> exit(:handler_exit) end)
    seq = terminal!(ctx.db, "holder")
    name = :"supervision_exit_#{System.unique_integer([:positive])}"

    pid =
      start_supervised!({Supervision, db: ctx.db, handlers: exiting, prod_limit: 3, name: name})

    Supervision.notify_terminal(name, "holder", seq)

    assert eventually(fn ->
             Enum.any?(
               EventLog.lifecycle_events(ctx.db),
               &(&1.kind == "supervision_evaluate_failed")
             )
           end),
           "the contained exit was never recorded as an evaluation failure"

    assert Process.alive?(pid)
    assert %{attemptCount: 1, prodCount: 0} = Supervision.prod_state(ctx.db, "asg_1")
    assert %{pendingBranch: "prod"} = Supervision.watermark(ctx.db, "holder")
  end

  test "retirement handling is total-caught before the server continues", ctx do
    name = :"supervision_retired_#{System.unique_integer([:positive])}"

    pid =
      start_supervised!(
        {Supervision, db: ctx.db, handlers: ctx.handlers, prod_limit: 3, name: name}
      )

    :ok = DB.execute(ctx.db, "DROP TABLE decision_requests")
    Supervision.notify_retired(name, "holder")

    assert eventually(fn ->
             Enum.any?(EventLog.lifecycle_events(ctx.db), fn event ->
               event.kind == "supervision_evaluate_failed" and event.subject == "holder"
             end)
           end),
           "the caught retirement failure was never recorded for holder"

    assert Process.alive?(pid)
    Supervision.request_sweep(name)

    # Same cast barrier: alive? proves nothing about a sweep still sitting in the
    # mailbox, and alive? was this test's only other assertion.
    :sys.get_state(name)
    assert Process.alive?(pid)
  end

  test "retiring a holder with open assignments delivers one notice to its first living ancestor",
       ctx do
    name = start_retirement_supervision(ctx)

    Org.retire(ctx.db, "holder")
    Supervision.notify_retired(name, "holder")
    :sys.get_state(name)

    assert [notice] = Projection.list_after(ctx.db, "supervisor", nil, 10)
    assert notice.sender == "process:tightbeam"
    assert notice.content =~ "Session holder retired with 1 open assignment row."
    assert notice.content =~ "The work is stranded and requires your attention."
    assert Ledger.pending_count(ctx.db, "supervisor") == 1
    assert Projection.list_after(ctx.db, ctx.main.session_key, nil, 10) == []

    Supervision.notify_retired(name, "holder")
    :sys.get_state(name)

    assert [_notice] = Projection.list_after(ctx.db, "supervisor", nil, 10)
    assert Ledger.pending_count(ctx.db, "supervisor") == 1
  end

  test "dead ancestors are skipped and an open-assignment strand reaches the org owner root",
       ctx do
    name = start_retirement_supervision(ctx)

    Org.retire(ctx.db, "supervisor")
    Org.retire(ctx.db, "holder")
    Supervision.notify_retired(name, "holder")
    :sys.get_state(name)

    assert Projection.list_after(ctx.db, "supervisor", nil, 10) == []
    assert [notice] = Projection.list_after(ctx.db, ctx.main.session_key, nil, 10)
    assert notice.content =~ "Session holder retired with 1 open assignment row."
    assert Ledger.pending_count(ctx.db, ctx.main.session_key) == 1
  end

  test "retiring a holder without open assignments delivers no strand notice", ctx do
    idle = session(ctx.db, "idle-holder", ctx.supervisor.session_key)
    name = start_retirement_supervision(ctx)

    Org.retire(ctx.db, idle.session_key)
    Supervision.notify_retired(name, idle.session_key)
    :sys.get_state(name)

    assert Projection.list_after(ctx.db, ctx.supervisor.session_key, nil, 10) == []
    assert Projection.list_after(ctx.db, ctx.main.session_key, nil, 10) == []
    assert Ledger.pending_count(ctx.db, ctx.supervisor.session_key) == 0
    assert Ledger.pending_count(ctx.db, ctx.main.session_key) == 0
  end

  test "N=0 cross-assignment re-entry exceeds N+1 and then quiesces at Main", ctx do
    {:ok, _} =
      DB.query(ctx.db, "UPDATE sessions SET spawnedBy='holder' WHERE sessionKey='supervisor'")

    assignment(ctx.db, "asg_2", "supervisor", "second", 2)

    h1 = terminal!(ctx.db, "holder")

    assert {:escalated, 1, "supervisor"} =
             Supervision.evaluate(ctx.db, ctx.handlers, 0, "holder", h1)

    fire_all_pending(ctx.db)
    s1 = terminal!(ctx.db, "supervisor")

    assert {:escalated, 1, "holder"} =
             Supervision.evaluate(ctx.db, ctx.handlers, 0, "supervisor", s1)

    fire_all_pending(ctx.db)
    h2 = terminal!(ctx.db, "holder")

    assert {:escalated, 2, main} =
             Supervision.evaluate(ctx.db, ctx.handlers, 0, "holder", h2)

    assert main == ctx.main.session_key
    assert Supervision.prod_state(ctx.db, "asg_1").prodCount == 2
    assert Supervision.prod_state(ctx.db, "asg_1").prodCount > 0 + 1

    fire_all_pending(ctx.db)
    main_terminal = terminal!(ctx.db, ctx.main.session_key)

    assert :idle =
             Supervision.evaluate(ctx.db, ctx.handlers, 0, ctx.main.session_key, main_terminal)

    assert Wakes.list_pending(ctx.db) == []
  end

  test "past-sink open assignment emits one escalation per external terminal and duplicate re-entry is inert",
       ctx do
    {:ok, _} = DB.query(ctx.db, "UPDATE sessions SET spawnedBy=NULL WHERE sessionKey='holder'")

    first = terminal!(ctx.db, "holder")

    assert {:escalated, 1, main} =
             Supervision.evaluate(ctx.db, ctx.handlers, 0, "holder", first)

    assert main == ctx.main.session_key
    assert :duplicate = Supervision.evaluate(ctx.db, ctx.handlers, 0, "holder", first)
    assert length(Wakes.list_pending(ctx.db)) == 1

    fire_all_pending(ctx.db)
    second = terminal!(ctx.db, "holder")

    assert {:escalated, 2, ^main} =
             Supervision.evaluate(ctx.db, ctx.handlers, 0, "holder", second)

    assert length(Wakes.list_pending(ctx.db)) == 1
  end

  test "atomic delivery concurrent-retirement race has only before-or-after outcomes", ctx do
    registry = start_supervised!({ConnRegistry, name: :race_conn_registry})
    lane = start_supervised!({LaneDoorbell, :race_lane_manager})

    for iteration <- 1..20 do
      target = "race_target_#{iteration}"
      session(ctx.db, target, ctx.main.session_key)

      {:ok, _} =
        DB.query(ctx.db, "UPDATE sessions SET spawnedBy=?1 WHERE sessionKey='holder'", [target])

      gate = %{reresolve: "lineage", reresolve_seed: "holder", reresolve_rung: 1}

      delivery =
        Task.async(fn ->
          Gateway.deliver_prompt(target, "process:tightbeam", "race",
            db: ctx.db,
            wake_id: "w_race_#{iteration}",
            sender: "process:tightbeam",
            target_gate: gate,
            conn_registry: registry,
            lane_manager: lane
          )
        end)

      retirement = Task.async(fn -> Org.retire(ctx.db, target) end)
      assert :appended = Task.await(delivery)
      Task.await(retirement)

      {:ok, rows} =
        DB.query(ctx.db, "SELECT sessionKey FROM turns WHERE wakeId=?1", ["w_race_#{iteration}"])

      assert [[recipient]] = rows
      assert recipient in [target, ctx.main.session_key]
      refute recipient == "holder"
    end
  end

  defp terminal!(db, session_key) do
    message_id = "m_#{System.unique_integer([:positive])}"

    {:ok, seq} =
      Ledger.enqueue(db, %{
        session_key: session_key,
        message_id: message_id,
        origin: "user:flynn",
        prompt: "external"
      })

    assert {:ok, %{seq: ^seq}} = Ledger.claim_next(db, session_key, "test")
    assert :ok = Ledger.finish(db, seq, "delivered")
    seq
  end

  defp prepare_review_gate(ctx) do
    reviewer = session(ctx.db, "reviewer", ctx.main.session_key)
    {:ok, _} = DB.query(ctx.db, "UPDATE sessions SET harness='codex' WHERE sessionKey='reviewer'")
    Roles.create!(ctx.db, "reviewer", "flynn", reviewer.session_key)

    write_rules(
      ctx,
      """
      [[rule]]
      name = "completion-needs-review"
      verb = "attest"
      text = "completion requires review"
      edges = ["verb", "turn-end"]
      effect = "remedy"
      deny_when = [
        { fact = "attest.kind", op = "eq", value = "completion" },
        { fact = "assignment.verdicts", op = "not_in", value = ["reviewed-clean"] }
      ]
      [rule.remedy]
      action = "assign"
      produces = "reviewed-clean"
      target_role = "reviewer"
      [rule.remedy.params]
      subject = "review of assignment {assignment_id}"
      reviews = "{assignment_id}"
      """
    )
  end

  defp load_turn_end_deny(ctx) do
    write_rules(
      ctx,
      """
      [[rule]]
      name = "completion-still-owed"
      verb = "attest"
      text = "completion remains owed"
      edges = ["turn-end"]
      deny_when = [
        { fact = "attest.kind", op = "eq", value = "completion" }
      ]
      """
    )
  end

  # A script-tier statute needs the wrapper, the script, and a holder the rail will accept
  # as local — `invocation_context` refuses a non-local holder before anything is spawned,
  # which would class as `script_error` and never reach the timeout under test.
  defp stage_rail_wrapper(ctx, script) do
    # The rail resolves the holder's workdir through the host registry, so the table has
    # to exist; without it the resolution fails and the deny classes `script_error`.
    :ok = Placement.ensure_schema(ctx.db)

    {:ok, _} =
      DB.query(ctx.db, "UPDATE sessions SET host = 'testhost' WHERE sessionKey = ?1", [
        "holder"
      ])

    scripts = Path.join([ctx.base, "identity", "rails", "scripts"])
    bin = Path.join(ctx.base, "bin")
    File.mkdir_p!(scripts)
    File.mkdir_p!(bin)

    stage_rail_script(ctx, script, "#!/bin/sh\nexit 0\n")

    wrapper = Path.join(bin, "tightbeam")
    File.cp!(Path.expand("fixtures/rail_exec/tightbeam", __DIR__), wrapper)
    File.chmod!(wrapper, 0o755)
  end

  defp stage_rail_script(ctx, name, body) do
    path = Path.join([ctx.base, "identity", "rails", "scripts", name])
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, body)
    File.chmod!(path, 0o755)
  end

  defp write_rules(ctx, contents) do
    rules_dir = Path.join(ctx.base, "identity/rules")
    File.mkdir_p!(rules_dir)
    File.write!(Path.join(rules_dir, "turn-end.toml"), contents)
    Rules.load!(ctx.base, Map.keys(ctx.handlers))
  end

  defp rail_sweep_details(db, session_key) do
    db
    |> EventLog.lifecycle_events()
    |> Enum.filter(&(&1.kind == "rail_sweep" and &1.subject == session_key))
    |> Enum.map(&JSON.decode!(&1.detail))
  end

  defp assignment(db, id, holder, subject, opened_at) do
    {:ok, _} =
      DB.query(
        db,
        "INSERT INTO assignments (id, subject, holderKey, openedByUser, openedAt) VALUES (?1, ?2, ?3, 'flynn', ?4)",
        [id, subject, holder, opened_at]
      )
  end

  defp session(db, key, spawned_by, built_in \\ false) do
    Org.create(db, %{
      session_key: key,
      display_name: key,
      owner_user_id: "flynn",
      origin: "user:flynn",
      spawned_by: spawned_by,
      is_built_in: built_in,
      archetype: "default",
      harness: "claude",
      provider: "anthropic",
      model: "fable",
      host: "eezo"
    })
  end

  defp fire_all_pending(db) do
    {:ok, _} =
      DB.query(db, "UPDATE wakes SET state='fired', firedAt=?1 WHERE state='pending'", [
        System.system_time(:millisecond)
      ])

    :ok
  end

  defp delivery_fun(db, registry, lane) do
    fn wake ->
      Gateway.deliver_prompt(wake.session_key, wake.origin, wake.prompt,
        db: db,
        wake_id: wake.wake_id,
        sender: wake.origin,
        target_gate: wake,
        fire_wake_in_txn: wake.origin == "process:tightbeam",
        conn_registry: registry,
        lane_manager: lane
      )
    end
  end

  defp start_retirement_supervision(ctx) do
    suffix = System.unique_integer([:positive])
    registry = :"retirement_conn_registry_#{suffix}"
    lane = :"retirement_lane_manager_#{suffix}"
    name = :"retirement_supervision_#{suffix}"

    start_supervised!({ConnRegistry, name: registry})
    start_supervised!({LaneDoorbell, lane})

    start_supervised!(
      {Supervision,
       db: ctx.db,
       handlers: ctx.handlers,
       prod_limit: 3,
       conn_registry: registry,
       lane_manager: lane,
       name: name}
    )

    name
  end

  defp eventually(fun, tries \\ 100) do
    cond do
      fun.() ->
        true

      tries == 0 ->
        flunk("condition did not become true")

      true ->
        Process.sleep(10)
        eventually(fun, tries - 1)
    end
  end

  # ── THE ORDER PIN (supervision-impl r21) ──────────────────────────────────
  # This assertion is the executable lease on the turn-end shift: the
  # schedule in Supervision.@turn_end_schedule may only change together with
  # (1) this literal, (2) the termination argument in supervision-impl-v1
  # §r21, and (3) a semantic justification for the new position — order is
  # meaning here (hold freezes enforcement; statutes outrank the ladder; a
  # pending wake silences everything downstream). If this test surprised you
  # red, you changed the shift without signing the lease — go read the
  # schedule comment in supervision.ex.
  test "the turn-end schedule is exactly the r21 shift, in order" do
    assert Tightbeam.Supervision.turn_end_schedule() == [
             :adjudication_hold,
             :rail_enforcement,
             :pending_wake_gate,
             :prod_ladder
           ]
  end
end
