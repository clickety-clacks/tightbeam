defmodule Tightbeam.RowWaitReliefFixture do
  import ExUnit.Assertions
  import Tightbeam.TestCase, only: [ensure_all_schemas: 1]

  alias Tightbeam.{
    Artifacts,
    Assignments,
    ConditionFacts,
    ConnRegistry,
    DB,
    EffortCheckin,
    Escalation,
    Gateway,
    Ledger,
    Model,
    Org,
    Roles,
    Rules,
    Supervision,
    Wakes,
    WorkItems
  }

  defmodule LaneStub do
    use GenServer
    def start_link(name), do: GenServer.start_link(__MODULE__, :ok, name: name)
    def init(:ok), do: {:ok, :ok}
    def handle_call({:ensure_lane, _key}, _from, state), do: {:reply, :ok, state}
  end

  def run!(base, locks) do
    {:ok, fixtures} = Supervisor.start_link([], strategy: :one_for_one)
    Process.put({__MODULE__, :supervisor}, fixtures)

    try do
      ctx = setup!(base, locks)
      :ok = DB.assert_base_admitted!(ctx.db, base)
      marker = File.read!(Path.join(base, "build-owner.json"))
      prove(ctx)
      assert File.read!(Path.join(base, "build-owner.json")) == marker
    after
      if Process.alive?(fixtures), do: Supervisor.stop(fixtures)
    end

    await_lock!(base, locks)
  end

  defp setup!(base, locks) do
    db = :"row_wait_db_#{System.unique_integer([:positive])}"
    scheduler = :"row_wait_scheduler_#{System.unique_integer([:positive])}"
    registry = :"row_wait_registry_#{System.unique_integer([:positive])}"
    lane = :"row_wait_lane_#{System.unique_integer([:positive])}"

    start_supervised!(
      {DB, path: Path.join(base, "state.db"), name: db, guard_inputs: [lock_dir: locks]}
    )

    :ok = ensure_all_schemas(db)
    start_supervised!({ConnRegistry, name: registry})
    start_supervised!({Tightbeam.RowWaitReliefFixture.LaneStub, lane})

    start_supervised!(
      {Wakes,
       name: scheduler,
       db: db,
       tick_ms: 60_000,
       deliver: fn _wake -> :ok end,
       delivery_opts: [conn_registry: registry, lane_manager: lane]}
    )

    :ok =
      DB.execute(
        db,
        "INSERT INTO users(userId,isAdmin,createdAt) VALUES ('owner-a',0,1),('owner-b',0,1)"
      )

    for {key, owner} <- [
          {"holder", "owner-a"},
          {"resolver", "owner-a"},
          {"verifier", "owner-a"},
          {"intruder", "owner-b"}
        ] do
      session(db, key, owner)
    end

    work_item(db, "wi-verification")
    assignment(db, "A", "holder")
    assignment(db, "R", "resolver")
    assignment(db, "V", "verifier", "wi-verification")

    assert %{name: "holder-role"} = Roles.create!(db, "holder-role", "owner-a", "holder")

    File.mkdir_p!(Path.join(base, "identity/rules"))

    File.write!(Path.join(base, "identity/rules/verification.toml"), """
    [[policy]]
    name = "accountable-dependency-verifier"
    purpose = "wait-verification-admission"
    when = [
      { fact = "verifier.open", op = "eq", value = true },
      { fact = "verifier.holder_is_other", op = "eq", value = true },
    ]
    verification = { trigger = "registration", terminal = "bound-verdict-or-obligation-terminal", fallback = "wake-due-at" }
    """)

    Rules.load!(base, ~w(wake attest))

    %{db: db, scheduler: scheduler, registry: registry, lane: lane, base: base, locks: locks}
  end

  defp prove(ctx) do
    qualification_policy(ctx)

    assert {:ok, generation} =
             DB.transaction(ctx.db, fn txn ->
               EffortCheckin.arm_in_txn(txn, %{base_dir: ctx.base}, %{
                 id: "A",
                 holderKey: "holder"
               })
             end)

    before = effort_snapshot(ctx.db)
    first = register_wait(ctx.db, due_after(), predicate("R"))
    second = register_wait(ctx.db, due_after(), predicate("R"))

    assert {:ok, [[started, 0]]} =
             DB.query(
               ctx.db,
               "SELECT reliefStartedAt,reliefExcludedMs FROM effort_checkin_generations WHERE assignmentId='A'"
             )

    assert started == first.created_at
    assert effort_snapshot(ctx.db) == before

    assert %{attest: %{verdictKind: "wait-verified"}} =
             attest(ctx.db, "V", "verifier", "verdict", "wait-verified", first.wake_id)

    assert effort_snapshot(ctx.db) == before
    # Close and reopen the admitted file under a fresh database owner.
    stop_supervised!(Wakes)
    stop_supervised!(DB)
    await_lock!(ctx.base, ctx.locks)

    start_supervised!(
      {DB,
       path: Path.join(ctx.base, "state.db"), name: ctx.db, guard_inputs: [lock_dir: ctx.locks]}
    )

    restarted = ctx.db
    :ok = DB.assert_base_admitted!(restarted, ctx.base)

    start_supervised!(
      {Wakes,
       name: ctx.scheduler,
       db: restarted,
       tick_ms: 60_000,
       deliver: fn _wake -> :ok end,
       delivery_opts: [conn_registry: ctx.registry, lane_manager: ctx.lane]}
    )

    :persistent_term.erase({Tightbeam.RuleRuntime, :wait_relief})
    assert :ok = Tightbeam.Schema.ensure_all(restarted)

    assert {:ok, :ok} =
             DB.transaction(restarted, fn txn ->
               EffortCheckin.reconcile_wait_relief_in_txn(txn, "A", started + 100)
             end)

    assert {:ok, [[^started, 0]]} =
             DB.query(
               restarted,
               "SELECT reliefStartedAt,reliefExcludedMs FROM effort_checkin_generations WHERE assignmentId='A'"
             )

    assert effort_snapshot(restarted) == before

    # Seed elapsed time, not a timeout guess, to prove that overlap is not summed.
    interval_start = started - 1_000

    assert {:ok, _} =
             DB.query(
               ctx.db,
               "UPDATE effort_checkin_generations SET reliefStartedAt=?1 WHERE assignmentId='A'",
               [interval_start]
             )

    assert %{attest: _} =
             attest(ctx.db, "V", "verifier", "verdict", "wait-challenged", first.wake_id)

    assert covered?(ctx.db, "A")

    assert {:ok, [[^interval_start, 0]]} =
             DB.query(
               ctx.db,
               "SELECT reliefStartedAt,reliefExcludedMs FROM effort_checkin_generations WHERE assignmentId='A'"
             )

    assert %{attest: _} =
             attest(ctx.db, "V", "verifier", "verdict", "wait-challenged", second.wake_id)

    refute covered?(ctx.db, "A")

    assert {:ok, [[nil, excluded]]} =
             DB.query(
               ctx.db,
               "SELECT reliefStartedAt,reliefExcludedMs FROM effort_checkin_generations WHERE assignmentId='A'"
             )

    assert excluded == Wakes.get(ctx.db, second.wake_id).recognition_at - interval_start
    assert effort_snapshot(ctx.db) == before

    assert Wakes.get(ctx.db, generation.wake_id).due_at ==
             generation.armed_at +
               generation.base_horizon_ms * generation.multiplier + excluded

    assert :ok = Wakes.fire_due(ctx.scheduler)
    refute covered?(ctx.db, "A")
  end

  defp qualification_policy(ctx, other \\ true) do
    File.write!(Path.join(ctx.base, "identity/rules/qualification.toml"), """
    [[policy]]
    name = "fixture-coverage"
    purpose = "wait-prod-coverage"
    when = [{fact="wait.coverage_valid",op="eq",value=true}]
    [[policy]]
    name = "fixture-relief"
    purpose = "wait-effort-relief"
    when = [{fact="resolver.owed_by_other",op="eq",value=#{other}}]
    """)

    Rules.load!(ctx.base, ~w(wake attest))
  end

  defp covered?(db, id) do
    assert {:ok, covered} = DB.transaction(db, &Wakes.covering_continuation_in_txn?(&1, id))
    covered
  end

  defp effort_snapshot(db) do
    {:ok, rows} =
      DB.query(db, """
      SELECT generation,state,baseHorizonMs,multiplier,armedAt,terminalSeqWatermark,
        wakeId,agentProdded,artifactWatermark,attestWatermark,workItemWatermark
      FROM effort_checkin_generations WHERE assignmentId='A'
      """)

    rows
  end

  defp register_wait(db, due_at, predicate) do
    assert {:ok, wake} =
             DB.transaction(db, fn txn ->
               Wakes.register_wait_in_txn(txn, %{
                 session_key: "holder",
                 origin: "agent:holder",
                 prompt: "Continue from durable state without rewriting this prompt.",
                 due_at: due_at,
                 assignment_id: "A",
                 predicate: predicate,
                 registrant_session_key: "holder",
                 owner_user_id: "owner-a"
               })
             end)

    wake
  end

  defp predicate(resolver_id, expected_state \\ nil, verifier_id \\ "V") do
    condition =
      if is_binary(expected_state) do
        %{"fact" => "assignment.state", "op" => "eq", "value" => expected_state}
      else
        %{"fact" => "assignment.outcome", "op" => "eq", "value" => "completed"}
      end

    %{
      "conditions" => [condition],
      "bindings" => %{"assignmentId" => resolver_id},
      "resolverRef" => %{"kind" => "assignment", "id" => resolver_id},
      "necessity" => "The named resolver owns the prerequisite output.",
      "verificationRef" => %{"kind" => "assignment", "id" => verifier_id}
    }
  end

  defp attest(db, assignment_id, session_key, kind, verdict_kind \\ nil, wait_id \\ nil) do
    Assignments.__handle__(db, "attest", %{
      principal: {:session, session_key},
      origin: "session:#{session_key}",
      params: %{
        assignment_id: assignment_id,
        kind: kind,
        verdict_kind: verdict_kind,
        wait_id: wait_id,
        note: "fixture evidence"
      }
    })
  end

  defp assignment(db, id, holder, work_item_id \\ nil, reviews_assignment_id \\ nil) do
    {:ok, _} =
      DB.query(
        db,
        "INSERT INTO assignments(id,subject,holderKey,openedByUser,openedAt,workItemId,reviewsAssignmentId) VALUES(?1,?2,?3,'owner-a',1,?4,?5)",
        [id, id, holder, work_item_id, reviews_assignment_id]
      )

    {:ok, _} =
      DB.query(
        db,
        "INSERT INTO assignment_effects(assignmentId,effectKind) VALUES(?1,'coordination')",
        [id]
      )
  end

  defp work_item(db, id) do
    {:ok, _} =
      DB.query(
        db,
        "INSERT INTO work_items(id,title,ownerUserId,state,createdByUser,createdAt) VALUES(?1,?1,'owner-a','open','owner-a',1)",
        [id]
      )
  end

  defp session(db, key, owner) do
    Org.create(db, %{
      session_key: key,
      display_name: key,
      owner_user_id: owner,
      origin: "user:#{owner}",
      archetype: "default",
      harness: "claude",
      provider: "anthropic",
      model: Model.new("fable"),
      host: "testhost"
    })
  end

  defp due_after, do: System.system_time(:millisecond) + 60_000

  defp start_supervised!(child, opts \\ []) do
    spec = Supervisor.child_spec(child, opts)
    {:ok, pid} = Supervisor.start_child(Process.get({__MODULE__, :supervisor}), spec)
    pid
  end

  defp stop_supervised!(id) do
    sup = Process.get({__MODULE__, :supervisor})
    :ok = Supervisor.terminate_child(sup, id)
    :ok = Supervisor.delete_child(sup, id)
  end

  defp await_lock!(base, locks, remaining \\ 100) do
    path = Path.join(locks, Base.encode16(:crypto.hash(:sha256, base), case: :lower) <> ".lock")

    case Tightbeam.LiveBaseLock.acquire(path) do
      {:ok, lock} ->
        :ok = Tightbeam.LiveBaseLock.release(lock)

      {:error, :lock_busy} when remaining > 0 ->
        Process.sleep(10)
        await_lock!(base, locks, remaining - 1)

      other ->
        raise "fixture lock did not release: #{inspect(other)}"
    end
  end
end
