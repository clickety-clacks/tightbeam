defmodule Tightbeam.RowDrivenWaitsTest.LaneStub do
  use GenServer

  def start_link(name), do: GenServer.start_link(__MODULE__, :ok, name: name)
  @impl true
  def init(:ok), do: {:ok, :ok}
  @impl true
  def handle_call({:ensure_lane, _session_key}, _from, state), do: {:reply, :ok, state}
end

defmodule Tightbeam.RowDrivenWaitsTest do
  use Tightbeam.TestCase, async: false

  alias Tightbeam.{
    Assignments,
    ConditionFacts,
    ConnRegistry,
    DB,
    Gateway,
    Ledger,
    Model,
    Org,
    Roles,
    Rules,
    Wakes
  }

  setup do
    db = :"row_wait_db_#{System.unique_integer([:positive])}"
    scheduler = :"row_wait_scheduler_#{System.unique_integer([:positive])}"
    registry = :"row_wait_registry_#{System.unique_integer([:positive])}"
    lane = :"row_wait_lane_#{System.unique_integer([:positive])}"
    base = Path.join(System.tmp_dir!(), "row-wait-rules-#{System.unique_integer([:positive])}")

    start_supervised!({DB, path: ":memory:", name: db})
    :ok = ensure_all_schemas(db)
    start_supervised!({ConnRegistry, name: registry})
    start_supervised!({Tightbeam.RowDrivenWaitsTest.LaneStub, lane})

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

    on_exit(fn ->
      File.rm_rf!(base)
      Rules.load!(System.tmp_dir!() <> "/missing-row-wait-rules", [])
    end)

    %{db: db, scheduler: scheduler, registry: registry, lane: lane, base: base}
  end

  test "verifier notice is ordinary blocked-holder mail attributed only to V", ctx do
    dependency = register_wait(ctx.db, due_after(), predicate("R"))
    notice = Wakes.get(ctx.db, dependency.verification_notice_wake_id)

    assert notice.session_key == "verifier"
    assert notice.assignment_id == "V"
    assert notice.obligation_ref == "V"
    assert notice.owner_user_id == "owner-a"

    assert {:ok, []} =
             DB.query(
               ctx.db,
               "SELECT 1 FROM supervision_liveness_sidecar WHERE wakeId=?1",
               [notice.wake_id]
             )

    assert {:ok, %{fact_id: _}} =
             DB.transaction(ctx.db, fn txn ->
               ConditionFacts.file_in_txn(txn, %{
                 kind: "work-blocked",
                 scope: "verifier",
                 origin: "session:holder"
               })
             end)

    before = supervision_counts(ctx.db, "V")

    assert :ok = stop_supervised(Wakes)

    start_supervised!(
      {Wakes,
       name: ctx.scheduler,
       db: ctx.db,
       tick_ms: 60_000,
       deliver: delivery_fun(ctx.db, ctx.registry, ctx.lane),
       delivery_opts: [conn_registry: ctx.registry, lane_manager: ctx.lane]}
    )

    assert :ok = Wakes.fire_due(ctx.scheduler)
    assert Wakes.get(ctx.db, notice.wake_id).state == "fired"

    assert {:ok, [["verifier", "V", "wi-verification", "queued"]]} =
             DB.query(
               ctx.db,
               "SELECT sessionKey,assignmentId,jobRef,status FROM turns WHERE wakeId=?1",
               [notice.wake_id]
             )

    assert supervision_counts(ctx.db, "V") == before
  end

  test "unresolved registration is coherent, terminal recognition latches, and T gates one delivery",
       ctx do
    turn = running_turn(ctx.db, "holder")
    wake = register_wait(ctx.db, due_after(), predicate("R"))

    assert wake.wait_mode == "dependency"
    assert wake.assignment_id == "A"
    assert wake.obligation_ref == "A"
    assert wake.owner_user_id == "owner-a"
    assert wake.originating_turn_seq == turn.seq
    assert wake.recognition_path == nil
    assert wake.selected_policy_name == "accountable-dependency-verifier"
    assert wake.verification_state == "provisional"
    assert wake.verification_assignment_id == "V"
    assert wake.verification_holder_key == "verifier"
    assert is_binary(wake.verification_notice_wake_id)

    assert {:ok, [[2]]} = DB.query(ctx.db, "SELECT COUNT(*) FROM wakes")

    assert %{assignment: %{outcome: "surrendered"}} =
             attest(ctx.db, "R", "resolver", "surrender")

    recognized = Wakes.get(ctx.db, wake.wake_id)
    assert recognized.recognition_path == "reconsideration"
    assert recognized.recognition_reason == "resolver-terminal"
    assert recognized.recognition_disposition == "surrendered"

    challenged =
      attest(ctx.db, "V", "verifier", "verdict", "wait-challenged", wake.wake_id)

    assert challenged.attest.waitId == wake.wake_id
    assert Wakes.get(ctx.db, wake.wake_id).recognition_reason == "resolver-terminal"

    assert :ok = Wakes.fire_due(ctx.scheduler)
    assert turn_count(ctx.db, wake.wake_id) == 0

    assert :ok = Ledger.finish(ctx.db, turn.seq, "failed", "fixture failure")
    assert :ok = Wakes.fire_due(ctx.scheduler)
    assert :ok = Wakes.fire_due(ctx.scheduler)
    assert turn_count(ctx.db, wake.wake_id) == 1

    assert {:ok, [[prompt]]} =
             DB.query(ctx.db, "SELECT prompt FROM turns WHERE wakeId=?1", [wake.wake_id])

    assert prompt =~ "[woke: wait #{wake.wake_id}; assignment A; path reconsideration;"
    assert prompt =~ "assignment:R"
    assert prompt =~ "outcome"
    assert prompt =~ "surrendered"
    assert prompt =~ "disposition surrendered"
    assert prompt =~ "predicate {"
    assert String.ends_with?(prompt, "Continue from durable state without rewriting this prompt.")
  end

  test "registration evaluates success and terminal resolver paths before returning", ctx do
    assert %{assignment: %{outcome: "surrendered"}} =
             attest(ctx.db, "R", "resolver", "surrender")

    terminal = register_wait(ctx.db, due_after(), predicate("R"))
    assert terminal.recognition_path == "reconsideration"
    assert terminal.recognition_reason == "resolver-terminal"
    assert terminal.recognition_transition.label == "registration-snapshot"
    assert terminal.originating_turn_seq == nil

    assignment(ctx.db, "R2", "resolver")
    assert %{assignment: %{outcome: "completed"}} = attest(ctx.db, "R2", "resolver", "completion")
    turn = running_turn(ctx.db, "holder")

    success = register_wait(ctx.db, due_after(), predicate("R2", "closed"))
    assert success.recognition_path == "success"
    assert success.recognition_disposition == "completed"
    assert success.verification_notice_wake_id == nil

    assert :ok = Wakes.fire_due(ctx.scheduler)
    assert turn_count(ctx.db, terminal.wake_id) == 1
    assert turn_count(ctx.db, success.wake_id) == 0

    assert :ok = Ledger.finish(ctx.db, turn.seq, "delivered")
    assert :ok = Wakes.fire_due(ctx.scheduler)
    assert turn_count(ctx.db, success.wake_id) == 1
  end

  test "after-turn captures the running turn and becomes eligible on every terminal outcome",
       ctx do
    before = wake_count(ctx.db)

    assert {:ok, {:error, %{code: "no_running_turn"}}} =
             DB.transaction(ctx.db, fn txn ->
               Wakes.register_wait_in_txn(txn, %{
                 session_key: "holder",
                 origin: "agent:holder",
                 prompt: "Act after this turn.",
                 due_at: System.system_time(:millisecond),
                 assignment_id: "A",
                 after_turn: true,
                 registrant_session_key: "holder",
                 owner_user_id: "owner-a"
               })
             end)

    assert wake_count(ctx.db) == before
    turn = running_turn(ctx.db, "holder")

    assert {:ok, wake} =
             DB.transaction(ctx.db, fn txn ->
               Wakes.register_wait_in_txn(txn, %{
                 session_key: "holder",
                 origin: "agent:holder",
                 prompt: "Act after this turn.",
                 due_at: System.system_time(:millisecond),
                 assignment_id: "A",
                 after_turn: true,
                 registrant_session_key: "holder",
                 owner_user_id: "owner-a"
               })
             end)

    assert wake.wait_mode == "after-turn"
    assert wake.recognition_path == "after-turn"
    assert wake.originating_turn_seq == turn.seq
    assert wake.recognition_transition.observed.status == "running"
    refute Map.has_key?(wake.recognition_transition, :field)
    assert :ok = Wakes.fire_due(ctx.scheduler)
    assert turn_count(ctx.db, wake.wake_id) == 0

    assert :ok = Ledger.finish(ctx.db, turn.seq, "canceled")
    assert :ok = Wakes.fire_due(ctx.scheduler)
    assert turn_count(ctx.db, wake.wake_id) == 1
  end

  test "gateway registration derives ownership and cancellation wins before eligible delivery",
       ctx do
    turn = running_turn(ctx.db, "holder")
    handler = Gateway.handlers(%{db: ctx.db, wake_scheduler: ctx.scheduler})["wake"]

    call = %{
      origin: "agent:holder-role",
      principal: {:session, "holder"},
      session_key: "holder",
      params: %{
        prompt: "Continue only if still useful.",
        after_ms: 60_000,
        assignment_id: "A",
        predicate: predicate("R"),
        nudge: false
      }
    }

    response = handler.(call)
    assert response.recognition_path == nil
    refute response.eligible
    assert Wakes.get(ctx.db, response.wake_id).owner_user_id == "owner-a"

    assert %{assignment: %{outcome: "surrendered"}} = attest(ctx.db, "R", "resolver", "surrender")
    assert %{assignment: %{outcome: "completed"}} = attest(ctx.db, "A", "holder", "completion")

    assert {:accepted_in_txn, _event_id, %{canceled: true}} =
             handler.(%{
               call
               | params: %{cancel_wake_id: response.wake_id, reason_kind: "requester_withdrew"}
             })

    assert :ok = Ledger.finish(ctx.db, turn.seq, "delivered")
    assert :ok = Wakes.fire_due(ctx.scheduler)
    assert turn_count(ctx.db, response.wake_id) == 0
  end

  test "verification verdicts are holder-and-wait-bound and challenge recognizes once", ctx do
    wake = register_wait(ctx.db, due_after(), predicate("R"))

    wrong_holder = attest(ctx.db, "V", "intruder", "verdict", "wait-verified", wake.wake_id)
    assert wrong_holder.code == "invalid_wait_verdict"
    assert attest_count(ctx.db, "V") == 0

    unknown_wait = attest(ctx.db, "V", "verifier", "verdict", "wait-verified", "w_missing")
    assert unknown_wait.code == "invalid_wait_verdict"
    assert attest_count(ctx.db, "V") == 0

    verified = attest(ctx.db, "V", "verifier", "verdict", "wait-verified", wake.wake_id)
    assert verified.attest.waitId == wake.wake_id
    confirmed = Wakes.get(ctx.db, wake.wake_id)
    assert confirmed.verification_state == "confirmed"
    assert confirmed.verification_attest_id == verified.attest.id

    challenged =
      attest(ctx.db, "V", "verifier", "verdict", "wait-challenged", wake.wake_id)

    reconsidered = Wakes.get(ctx.db, wake.wake_id)
    assert reconsidered.verification_state == "challenged"
    assert reconsidered.verification_attest_id == challenged.attest.id
    assert reconsidered.recognition_path == "reconsideration"
    assert reconsidered.recognition_reason == "verification-challenged"
    assert reconsidered.recognition_transition["row_id"] == challenged.attest.id

    duplicate =
      attest(ctx.db, "V", "verifier", "verdict", "wait-challenged", wake.wake_id)

    assert duplicate.code == "invalid_wait_verdict"
    assert attest_count(ctx.db, "V") == 2
  end

  test "terminal verifier and fallback end provisional waiting without inventing confirmation",
       ctx do
    verifier_terminal = register_wait(ctx.db, due_after(), predicate("R"))
    assert %{assignment: %{outcome: "surrendered"}} = attest(ctx.db, "V", "verifier", "surrender")

    terminal = Wakes.get(ctx.db, verifier_terminal.wake_id)
    assert terminal.recognition_path == "reconsideration"
    assert terminal.recognition_reason == "verification-terminal"
    assert terminal.verification_state == "provisional"

    assignment(ctx.db, "V2", "verifier")

    fallback =
      register_wait(ctx.db, System.system_time(:millisecond) - 1, predicate("R", nil, "V2"))

    assert fallback.recognition_path == nil
    assert :ok = Wakes.fire_due(ctx.scheduler)

    fired = Wakes.get(ctx.db, fallback.wake_id)
    assert fired.recognition_path == "fallback"
    assert fired.recognition_reason == nil
    assert fired.verification_state == "provisional"
    assert fired.recognition_transition["label"] == "fallback-silence"
    assert turn_count(ctx.db, fallback.wake_id) == 1

    assert %{assignment: %{outcome: "surrendered"}} =
             attest(ctx.db, "R", "resolver", "surrender")

    assert Wakes.get(ctx.db, fallback.wake_id).recognition_path == "fallback"
    assert turn_count(ctx.db, fallback.wake_id) == 1
  end

  test "cross-owner or incomplete registration refuses without any wake row", ctx do
    assignment(ctx.db, "B", "intruder")
    before = wake_count(ctx.db)

    assert {:ok, {:error, %{code: "invalid_wait"}}} =
             DB.transaction(ctx.db, fn txn ->
               Wakes.register_wait_in_txn(txn, %{
                 session_key: "holder",
                 origin: "agent:holder",
                 prompt: "do not persist",
                 assignment_id: "A",
                 predicate: predicate("R"),
                 registrant_session_key: "holder",
                 owner_user_id: "owner-a"
               })
             end)

    assert wake_count(ctx.db) == before

    assert {:ok, {:error, %{code: "unknown_assignment"}}} =
             DB.transaction(ctx.db, fn txn ->
               Wakes.register_wait_in_txn(txn, %{
                 session_key: "holder",
                 origin: "agent:holder",
                 prompt: "do not persist",
                 due_at: due_after(),
                 assignment_id: "B",
                 predicate: predicate("R"),
                 registrant_session_key: "holder",
                 owner_user_id: "owner-a"
               })
             end)

    assert wake_count(ctx.db) == before

    invalid = put_in(predicate("R"), ["verificationRef", "id"], "missing")

    assert {:ok, {:error, %{code: "invalid_verifier"}}} =
             DB.transaction(ctx.db, fn txn ->
               Wakes.register_wait_in_txn(txn, %{
                 session_key: "holder",
                 origin: "agent:holder",
                 prompt: "do not persist",
                 due_at: due_after(),
                 assignment_id: "A",
                 predicate: invalid,
                 registrant_session_key: "holder",
                 owner_user_id: "owner-a"
               })
             end)

    assert wake_count(ctx.db) == before

    invalid_resolver =
      put_in(predicate("R"), ["resolverRef"], %{"kind" => "work_item", "id" => "R"})

    assert {:ok, {:error, %{code: "invalid_predicate"}}} =
             DB.transaction(ctx.db, fn txn ->
               Wakes.register_wait_in_txn(txn, %{
                 session_key: "holder",
                 origin: "agent:holder",
                 prompt: "do not persist",
                 due_at: due_after(),
                 assignment_id: "A",
                 predicate: invalid_resolver,
                 registrant_session_key: "holder",
                 owner_user_id: "owner-a"
               })
             end)

    assert wake_count(ctx.db) == before
  end

  test "verification admission selects bytewise name and never rewrites the stored choice", ctx do
    rules_dir = Path.join(ctx.base, "identity/rules")
    File.rm!(Path.join(rules_dir, "verification.toml"))
    File.write!(Path.join(rules_dir, "z.toml"), policy("z-verifier"))
    File.write!(Path.join(rules_dir, "a.toml"), policy("a-verifier"))
    Rules.load!(ctx.base, ~w(wake attest))

    first = register_wait(ctx.db, due_after(), predicate("R"))
    assert first.selected_policy_name == "a-verifier"
    assert is_binary(first.verification_notice_wake_id)

    File.rm!(Path.join(rules_dir, "a.toml"))
    File.rm!(Path.join(rules_dir, "z.toml"))

    File.write!(
      Path.join(rules_dir, "reversed.toml"),
      policy("z-verifier") <> policy("a-verifier")
    )

    Rules.load!(ctx.base, ~w(wake attest))

    reversed = register_wait(ctx.db, due_after(), predicate("R"))
    assert reversed.selected_policy_name == "a-verifier"
    assert is_binary(reversed.verification_notice_wake_id)
    refute reversed.verification_notice_wake_id == first.verification_notice_wake_id

    File.rm!(Path.join(rules_dir, "reversed.toml"))
    File.write!(Path.join(rules_dir, "z.toml"), policy("z-verifier"))
    Rules.load!(ctx.base, ~w(wake attest))
    assert Wakes.get(ctx.db, first.wake_id).selected_policy_name == "a-verifier"

    second = register_wait(ctx.db, due_after(), predicate("R"))
    assert second.selected_policy_name == "z-verifier"

    File.rm!(Path.join(rules_dir, "z.toml"))
    Rules.load!(ctx.base, ~w(wake attest))
    before = wake_count(ctx.db)

    assert {:ok, {:error, %{code: "verification_not_admitted"}}} =
             DB.transaction(ctx.db, fn txn ->
               Wakes.register_wait_in_txn(txn, %{
                 session_key: "holder",
                 origin: "agent:holder",
                 prompt: "refuse without a policy",
                 due_at: due_after(),
                 assignment_id: "A",
                 predicate: predicate("R"),
                 registrant_session_key: "holder",
                 owner_user_id: "owner-a"
               })
             end)

    assert wake_count(ctx.db) == before
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

  defp policy(name) do
    """
    [[policy]]
    name = "#{name}"
    purpose = "wait-verification-admission"
    when = [
      { fact = "verifier.open", op = "eq", value = true },
      { fact = "verifier.holder_is_other", op = "eq", value = true },
    ]
    verification = { trigger = "registration", terminal = "bound-verdict-or-obligation-terminal", fallback = "wake-due-at" }
    """
  end

  defp running_turn(db, session_key) do
    {:ok, _seq} =
      Ledger.enqueue(db, %{
        session_key: session_key,
        message_id: "msg-#{System.unique_integer([:positive])}",
        origin: "agent:fixture",
        prompt: "originating turn"
      })

    {:ok, turn} = Ledger.claim_next(db, session_key, "fixture")
    turn
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

  defp assignment(db, id, holder, work_item_id \\ nil) do
    {:ok, _} =
      DB.query(
        db,
        "INSERT INTO assignments(id,subject,holderKey,openedByUser,openedAt,workItemId) VALUES(?1,?2,?3,'owner-a',1,?4)",
        [id, id, holder, work_item_id]
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

  defp delivery_fun(db, registry, lane) do
    fn wake ->
      Gateway.deliver_prompt(wake.session_key, wake.origin, wake.prompt,
        db: db,
        wake_id: wake.wake_id,
        sender: wake.origin,
        target_gate: if(wake.target_gate == 0, do: nil, else: wake),
        fire_wake_in_txn: wake.origin == "process:tightbeam",
        conn_registry: registry,
        lane_manager: lane
      )
    end
  end

  defp supervision_counts(db, assignment_id) do
    {:ok, [[prods, entitlements, sidecars]]} =
      DB.query(
        db,
        """
        SELECT
          (SELECT COUNT(*) FROM assignment_prods WHERE assignmentId=?1),
          (SELECT COUNT(*) FROM supervision_entitlements WHERE assignmentId=?1),
          (SELECT COUNT(*) FROM supervision_liveness_sidecar WHERE assignmentId=?1)
        """,
        [assignment_id]
      )

    {prods, entitlements, sidecars}
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

  defp wake_count(db) do
    {:ok, [[count]]} = DB.query(db, "SELECT COUNT(*) FROM wakes")
    count
  end

  defp attest_count(db, assignment_id) do
    {:ok, [[count]]} =
      DB.query(db, "SELECT COUNT(*) FROM attests WHERE assignmentId=?1", [assignment_id])

    count
  end

  defp turn_count(db, wake_id) do
    {:ok, [[count]]} = DB.query(db, "SELECT COUNT(*) FROM turns WHERE wakeId=?1", [wake_id])
    count
  end

  defp due_after, do: System.system_time(:millisecond) + 60_000
end
