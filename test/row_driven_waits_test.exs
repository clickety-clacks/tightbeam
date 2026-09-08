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
    assert recognized.recognition_transition["domain"] == "assignment"
    assert recognized.recognition_transition["row_id"] == "R"

    assert recognized.recognition_transition["fields"] == %{
             "outcome" => %{"new" => "surrendered", "old" => nil},
             "state" => %{"new" => "closed", "old" => "open"}
           }

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

  test "artifact and exact-revision review waits preserve producer and revision identity", ctx do
    work_item(ctx.db, "wi-output")
    assignment(ctx.db, "P", "resolver", "wi-output")
    assignment(ctx.db, "Q", "resolver", "wi-output")
    assignment(ctx.db, "P-review", "verifier", "wi-output", "P")
    h1 = String.duplicate("1", 64)
    h2 = String.duplicate("2", 64)

    existing_artifact = record_artifact(ctx.db, "P", h1)

    assert %{attest: %{verdictKind: "reviewed-clean"}} =
             review_verdict(ctx.db, "P-review", existing_artifact, "reviewed-clean")

    turn = running_turn(ctx.db, "holder")

    existing =
      register_wait(ctx.db, due_after(), artifact_predicate("P", h1, true))

    assert existing.recognition_path == "success"
    assert existing.recognition_transition.label == "registration-snapshot"
    assert turn_count(ctx.db, existing.wake_id) == 0
    assert :ok = Ledger.finish(ctx.db, turn.seq, "delivered")
    assert :ok = Wakes.fire_due(ctx.scheduler)
    assert :ok = Wakes.fire_due(ctx.scheduler)
    assert turn_count(ctx.db, existing.wake_id) == 1

    assignment(ctx.db, "P2", "resolver", "wi-output")

    producer_bound =
      register_wait(ctx.db, due_after(), artifact_predicate("P2", h2, false))

    assert producer_bound.recognition_path == nil
    _wrong_artifact = record_artifact(ctx.db, "Q", h2)
    assert Wakes.get(ctx.db, producer_bound.wake_id).recognition_path == nil

    exact_artifact = record_artifact(ctx.db, "P2", h2)
    exact = Wakes.get(ctx.db, producer_bound.wake_id)
    assert exact.recognition_path == "success"
    assert exact.recognition_transition["domain"] == "artifact"
    assert exact.recognition_transition["row_id"] == exact_artifact.artifact_id

    assignment(ctx.db, "P3", "resolver", "wi-output")
    assignment(ctx.db, "P3-review", "verifier", "wi-output", "P3")

    unknown_revision =
      register_wait(ctx.db, due_after(), artifact_predicate("P3", nil, true))

    candidate = record_artifact(ctx.db, "P3", h1)
    assert Wakes.get(ctx.db, unknown_revision.wake_id).recognition_path == nil

    assert %{attest: %{artifactId: nil, contentSha256: nil}} =
             attest(ctx.db, "P3-review", "verifier", "verdict", "reviewed-clean")

    assert Wakes.get(ctx.db, unknown_revision.wake_id).recognition_path == nil

    bound_clean = review_verdict(ctx.db, "P3-review", candidate, "reviewed-clean")
    no_hash = Wakes.get(ctx.db, unknown_revision.wake_id)
    assert no_hash.recognition_path == "success"
    assert no_hash.recognition_transition["domain"] == "attest"
    assert no_hash.recognition_transition["row_id"] == bound_clean.attest.id

    assert no_hash.recognition_evidence["artifact_revision"] == %{
             "hash" => h1,
             "id" => candidate.artifact_id,
             "producer" => "P3"
           }

    assignment(ctx.db, "P4", "resolver", "wi-output")
    assignment(ctx.db, "P4-review", "verifier", "wi-output", "P4")
    assignment(ctx.db, "R4-end", "resolver")
    stale = record_artifact(ctx.db, "P4", h1)

    assert %{attest: %{verdictKind: "reviewed-clean"}} =
             review_verdict(ctx.db, "P4-review", stale, "reviewed-clean")

    current = record_artifact(ctx.db, "P4", h2)

    assert %{attest: %{verdictKind: "reviewed-clean"}} =
             review_verdict(ctx.db, "P4-review", current, "reviewed-clean")

    assert %{attest: %{verdictKind: "changes-requested"}} =
             review_verdict(ctx.db, "P4-review", current, "changes-requested")

    blocked =
      register_wait(ctx.db, due_after(), artifact_predicate("P4", h2, true, "R4-end"))

    assert blocked.recognition_path == nil

    assert %{outcome: "revoked"} = revoke(ctx.db, "R4-end")
    reconsidered = Wakes.get(ctx.db, blocked.wake_id)
    assert reconsidered.recognition_path == "reconsideration"
    assert reconsidered.recognition_disposition == "revoked"
    assert reconsidered.recognition_transition["domain"] == "assignment"
    assert reconsidered.recognition_transition["row_id"] == "R4-end"
  end

  test "condition-fact dependency captures its cursor and stamps the exact future fact", ctx do
    historical =
      ConditionFacts.file(ctx.db, ctx.scheduler, %{
        kind: "structured-ready",
        scope: "production",
        origin: "user:owner-a"
      })

    turn = running_turn(ctx.db, "holder")

    wake =
      register_wait(
        ctx.db,
        due_after(),
        condition_fact_predicate("structured-ready", "production", 0)
      )

    assert wake.recognition_path == nil

    assert Wakes.get(ctx.db, wake.wake_id).predicate["bindings"]["conditionAfterId"] ==
             historical.fact_id

    ConditionFacts.file(ctx.db, ctx.scheduler, %{
      kind: "structured-ready",
      scope: "staging",
      origin: "user:owner-a"
    })

    ConditionFacts.file(ctx.db, ctx.scheduler, %{
      kind: "structured-ready",
      scope: "production",
      origin: "user:owner-b"
    })

    assert Wakes.get(ctx.db, wake.wake_id).recognition_path == nil

    matching =
      ConditionFacts.file(ctx.db, ctx.scheduler, %{
        kind: "structured-ready",
        scope: "production",
        origin: "user:owner-a"
      })

    matching_id = matching.fact_id
    recognized = Wakes.get(ctx.db, wake.wake_id)
    assert recognized.recognition_path == "success"

    assert %{
             "domain" => "condition_fact",
             "row_id" => ^matching_id,
             "field" => %{"name" => "id", "old" => nil, "new" => ^matching_id}
           } = recognized.recognition_transition

    assert recognized.recognition_evidence["label"] == "row-transition"

    assert recognized.recognition_evidence["condition_match"] == %{
             "id" => matching_id,
             "scope" => "production"
           }

    assert turn_count(ctx.db, wake.wake_id) == 0
    assert :ok = Ledger.finish(ctx.db, turn.seq, "delivered")
    assert :ok = Wakes.fire_due(ctx.scheduler)
    assert turn_count(ctx.db, wake.wake_id) == 1
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

  test "terminal assignment, decision and work-item dispositions use the two firing paths", ctx do
    assignment(ctx.db, "R-revoked", "resolver")
    revoked_wait = register_wait(ctx.db, due_after(), predicate("R-revoked"))
    assert %{outcome: "revoked"} = revoke(ctx.db, "R-revoked")
    revoked = Wakes.get(ctx.db, revoked_wait.wake_id)
    assert revoked.recognition_path == "reconsideration"
    assert revoked.recognition_disposition == "revoked"

    withdrawn_request = operator_ask(ctx.db, "withdraw this request")

    withdrawn_wait =
      register_wait(
        ctx.db,
        due_after(),
        decision_predicate(withdrawn_request.id, "ruled")
      )

    assert %{status: "withdrawn"} = operator_withdraw(ctx.db, withdrawn_request.id)
    withdrawn = Wakes.get(ctx.db, withdrawn_wait.wake_id)
    assert withdrawn.recognition_path == "reconsideration"
    assert withdrawn.recognition_disposition == "withdrawn"
    assert withdrawn.recognition_transition["domain"] == "decision_request"
    assert withdrawn.recognition_transition["row_id"] == withdrawn_request.id

    default_request = operator_ask(ctx.db, "withdraw successfully")

    default_decision =
      register_wait(ctx.db, due_after(), default_decision_predicate(default_request.id))

    assert %{status: "withdrawn"} = operator_withdraw(ctx.db, default_request.id)
    decision_success = Wakes.get(ctx.db, default_decision.wake_id)
    assert decision_success.recognition_path == "success"
    assert decision_success.recognition_disposition == "withdrawn"

    superseded_request = operator_ask(ctx.db, "supersede this request")

    superseded_wait =
      register_wait(
        ctx.db,
        due_after(),
        decision_predicate(superseded_request.id, "ruled")
      )

    assert %{id: replacement_id} =
             operator_ask(ctx.db, "replacement request", superseded_request.id)

    refute replacement_id == superseded_request.id
    superseded = Wakes.get(ctx.db, superseded_wait.wake_id)
    assert superseded.recognition_path == "reconsideration"
    assert superseded.recognition_disposition == "superseded"

    assignment(ctx.db, "R-work", "resolver")

    for {work_item_id, verb, disposition} <- [
          {"wi-iceboxed", "work-item-icebox", "iceboxed"},
          {"wi-failed", "work-item-fail", "failed"}
        ] do
      work_item(ctx.db, work_item_id)

      wait =
        register_wait(ctx.db, due_after(), default_work_item_predicate(work_item_id, "R-work"))

      assert %{ok: true, workItem: %{state: ^disposition}} =
               dispose_work_item(ctx.db, verb, work_item_id)

      recognized = Wakes.get(ctx.db, wait.wake_id)
      assert recognized.recognition_path == "success"
      assert recognized.recognition_disposition == disposition
      assert recognized.recognition_transition["domain"] == "work_item"
      assert recognized.recognition_transition["row_id"] == work_item_id
    end

    work_item(ctx.db, "wi-narrow")
    assignment(ctx.db, "R-narrow", "resolver")

    narrow =
      register_wait(ctx.db, due_after(), work_item_predicate("wi-narrow", "closed", "R-narrow"))

    assert %{ok: true, workItem: %{state: "iceboxed"}} =
             dispose_work_item(ctx.db, "work-item-icebox", "wi-narrow")

    assert Wakes.get(ctx.db, narrow.wake_id).recognition_path == nil
    assert %{outcome: "revoked"} = revoke(ctx.db, "R-narrow")
    assert Wakes.get(ctx.db, narrow.wake_id).recognition_path == "reconsideration"
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

  test "latched recognition and serialized winners survive scheduler restarts without duplicates",
       ctx do
    work_item(ctx.db, "wi-latched")
    assignment(ctx.db, "R-latched", "resolver")
    turn = running_turn(ctx.db, "holder")

    latched =
      register_wait(
        ctx.db,
        due_after(),
        default_work_item_predicate("wi-latched", "R-latched")
      )

    assert %{ok: true, workItem: %{state: "iceboxed"}} =
             dispose_work_item(ctx.db, "work-item-icebox", "wi-latched")

    recognized = Wakes.get(ctx.db, latched.wake_id)
    assert recognized.recognition_path == "success"
    assert recognized.recognition_disposition == "iceboxed"
    assert turn_count(ctx.db, latched.wake_id) == 0

    assert %{ok: true, workItem: %{state: "open"}} =
             dispose_work_item(ctx.db, "work-item-reopen", "wi-latched")

    assert :ok = stop_supervised(Wakes)

    start_supervised!(
      {Wakes,
       name: ctx.scheduler,
       db: ctx.db,
       tick_ms: 60_000,
       deliver: delivery_fun(ctx.db, ctx.registry, ctx.lane),
       delivery_opts: [conn_registry: ctx.registry, lane_manager: ctx.lane]}
    )

    assert :ok = Ledger.finish(ctx.db, turn.seq, "failed")
    assert :ok = Wakes.fire_due(ctx.scheduler)
    assert turn_count(ctx.db, latched.wake_id) == 1

    assert {:ok, [[prompt]]} =
             DB.query(ctx.db, "SELECT prompt FROM turns WHERE wakeId=?1", [latched.wake_id])

    assert prompt =~ "work_item:wi-latched"
    assert prompt =~ ~s(state "open"→"iceboxed")
    assert prompt =~ "disposition iceboxed"
    assert current_work_item_state(ctx.db, "wi-latched") == "open"

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
    assert turn_count(ctx.db, latched.wake_id) == 1

    assignment(ctx.db, "R-both", "resolver")
    both = register_wait(ctx.db, due_after(), predicate("R-both", "closed"))

    assert %{assignment: %{outcome: "completed"}} =
             attest(ctx.db, "R-both", "resolver", "completion")

    both_winner = Wakes.get(ctx.db, both.wake_id)
    assert both_winner.recognition_path == "success"
    assert both_winner.recognition_disposition == "completed"

    assignment(ctx.db, "R-before-fallback", "resolver")

    resolver_first =
      register_wait(
        ctx.db,
        System.system_time(:millisecond) - 1,
        predicate("R-before-fallback")
      )

    assert %{outcome: "revoked"} = revoke(ctx.db, "R-before-fallback")
    assert :ok = Wakes.fire_due(ctx.scheduler)
    assert Wakes.get(ctx.db, resolver_first.wake_id).recognition_path == "reconsideration"
    assert turn_count(ctx.db, resolver_first.wake_id) == 1

    assignment(ctx.db, "R-after-fallback", "resolver")

    fallback_first =
      register_wait(
        ctx.db,
        System.system_time(:millisecond) - 1,
        predicate("R-after-fallback")
      )

    assert :ok = Wakes.fire_due(ctx.scheduler)
    assert Wakes.get(ctx.db, fallback_first.wake_id).recognition_path == "fallback"
    assert %{outcome: "revoked"} = revoke(ctx.db, "R-after-fallback")
    assert Wakes.get(ctx.db, fallback_first.wake_id).recognition_path == "fallback"
    assert :ok = Wakes.fire_due(ctx.scheduler)
    assert turn_count(ctx.db, fallback_first.wake_id) == 1
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

  test "Rules-only facts refuse dependency registration without wake or sidecar", ctx do
    conditions = [
      %{"fact" => "assignment.state", "op" => "eq", "value" => "open"},
      %{"fact" => "assignment.artifact_kinds", "op" => "in", "value" => ["report"]}
    ]

    declaration =
      predicate("R")
      |> Map.put("conditions", conditions)
      |> Map.put("bindings", %{"assignmentId" => "R"})

    assert {:ok, {:ok, _}} =
             DB.transaction(ctx.db, fn txn ->
               Rules.evaluate_predicate_in_txn(txn, %{
                 owner_user_id: "owner-a",
                 conditions: conditions,
                 bindings: declaration["bindings"]
               })
             end)

    before = wake_count(ctx.db)
    sidecars_before = DB.query(ctx.db, "SELECT COUNT(*) FROM supervision_liveness_sidecar")

    assert {:ok, {:error, %{code: "invalid_predicate", message: message}}} =
             DB.transaction(ctx.db, fn txn ->
               Wakes.register_wait_in_txn(txn, %{
                 session_key: "holder",
                 origin: "agent:holder",
                 prompt: "do not persist",
                 due_at: due_after(),
                 assignment_id: "A",
                 predicate: declaration,
                 registrant_session_key: "holder",
                 owner_user_id: "owner-a"
               })
             end)

    assert message == ~s(unsupported ad hoc wait fact: "assignment.artifact_kinds")
    assert wake_count(ctx.db) == before

    assert DB.query(ctx.db, "SELECT COUNT(*) FROM supervision_liveness_sidecar") ==
             sidecars_before
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

  test "C1-C4: coverage follows only the admitted obligation through pending, queued and running",
       ctx do
    qualification_policy(ctx)
    assignment(ctx.db, "B", "holder")
    turn = running_turn(ctx.db, "holder")
    wake = register_wait(ctx.db, due_after(), predicate("R"))
    refute covered?(ctx.db, "A")
    assert :ok = Ledger.finish(ctx.db, turn.seq, "delivered")
    assert covered?(ctx.db, "A")
    refute covered?(ctx.db, "B")
    assert {:match, %{id: "B"}} = Supervision.prod_production_matches?(ctx.db, "holder", turn.seq)

    assert {:ok, [["holder_continuation", nil, nil, "pending"]]} =
             DB.query(
               ctx.db,
               "SELECT controllerOrigin,wakeKind,chargedGeneration,controllerState FROM supervision_liveness_sidecar WHERE wakeId=?1",
               [wake.wake_id]
             )

    assert %{assignment: %{outcome: "completed"}} = attest(ctx.db, "R", "resolver", "completion")
    assert :ok = Wakes.fire_due(ctx.scheduler)
    assert covered?(ctx.db, "A")
    assert {:ok, continuation} = Ledger.claim_next(ctx.db, "holder", "fixture")
    assert covered?(ctx.db, "A")
    refute covered?(ctx.db, "B")
    assert :ok = Ledger.finish(ctx.db, continuation.seq, "delivered")
    refute covered?(ctx.db, "A")

    assert {:match, %{id: "A"}} =
             Supervision.prod_production_matches?(ctx.db, "holder", continuation.seq)

    # The executive specimen named its assignments only in prose: no typed join.
    Wakes.schedule(ctx.db, %{
      session_key: "holder",
      origin: "agent:holder",
      prompt: "Continue A and B",
      due_at: due_after()
    })

    refute covered?(ctx.db, "A")
    refute covered?(ctx.db, "B")
  end

  test "C2-C3: one covered card cannot suppress another card's actual prod or watermark", ctx do
    qualification_policy(ctx)
    assignment(ctx.db, "B", "holder")
    assignment(ctx.db, "C", "holder")

    for id <- ~w(A B C) do
      assert {:ok, :armed} =
               DB.transaction(ctx.db, fn txn ->
                 Supervision.transition_in_txn(txn, %{
                   kind: "assignment_open",
                   assignment_id: id,
                   opened_at: 0,
                   principal: "user:owner-a",
                   supervision_interval_ms: 1
                 })
               end)
    end

    turn = running_turn(ctx.db, "holder")
    assert :ok = Ledger.finish(ctx.db, turn.seq, "delivered")
    register_wait(ctx.db, due_after(), predicate("R"))
    handlers = Gateway.handlers(%{db: ctx.db, wake_tick_ms: 60_000})
    assert {:prodded, 1} = Supervision.evaluate(ctx.db, handlers, 3, "holder", turn.seq)
    assert %{prodCount: 1} = Supervision.prod_state(ctx.db, "B")
    assert {:prodded, 1} = Supervision.evaluate(ctx.db, handlers, 3, "holder", turn.seq)
    assert %{prodCount: 1} = Supervision.prod_state(ctx.db, "C")
    assert {:ok, []} = DB.query(ctx.db, "SELECT 1 FROM assignment_prods WHERE assignmentId='A'")

    assert {:ok, [["B"], ["C"]]} =
             DB.query(
               ctx.db,
               "SELECT assignmentId FROM supervision_watermarks WHERE lastEvaluatedTerminal=?1 ORDER BY assignmentId",
               [turn.seq]
             )
  end

  test "ancestor admission preserves the true creator and rechecks revoked lineage", ctx do
    session(ctx.db, "supervisor", "owner-a")

    shipped =
      File.read!(
        Path.expand("../priv/kungfu/agentic-engineering/rules/verification.toml", __DIR__)
      )

    File.write!(Path.join(ctx.base, "identity/rules/verification.toml"), shipped)
    Rules.load!(ctx.base, ~w(wake attest))
    turn = running_turn(ctx.db, "supervisor")

    assert {:ok, _} =
             DB.query(
               ctx.db,
               "UPDATE sessions SET spawnedBy='supervisor' WHERE sessionKey='holder'"
             )

    input = %{
      session_key: "holder",
      origin: "agent:supervisor",
      prompt: "Resume assigned work.",
      due_at: due_after(),
      assignment_id: "A",
      predicate: predicate("R"),
      registrant_session_key: "supervisor",
      owner_user_id: "owner-a"
    }

    assert {:ok, wake} = DB.transaction(ctx.db, &Wakes.register_wait_in_txn(&1, input))
    assert wake.creator_session_key == "supervisor"
    assert wake.session_key == "holder"
    assert wake.obligation_ref == "A"
    assert wake.originating_turn_seq == turn.seq
    refute covered?(ctx.db, "A")
    assert :ok = Ledger.finish(ctx.db, turn.seq, "delivered")
    assert covered?(ctx.db, "A")

    # A rule installed after an earlier allowed decision must still be checked
    # inside registration. Evaluation must not execute notice/remedy effects.
    File.write!(Path.join(ctx.base, "identity/rules/pause.toml"), """
    [[rule]]
    name = "pause-ancestor-admission"
    verb = "wake"
    text = "Admission paused."
    effect = "deny"
    deny_when = [{ fact = "wake.registrant_is_ancestor", op = "eq", value = true }]
    """)

    Rules.load!(ctx.base, ~w(wake attest))
    assert {:ok, [[before_count]]} = DB.query(ctx.db, "SELECT COUNT(*) FROM wakes")

    assert {:ok, {:error, %{code: "rule_denied"}}} =
             DB.transaction(ctx.db, &Wakes.register_wait_in_txn(&1, input))

    assert {:ok, [[^before_count]]} = DB.query(ctx.db, "SELECT COUNT(*) FROM wakes")

    assert {:ok, _} =
             DB.query(ctx.db, "UPDATE sessions SET spawnedBy=NULL WHERE sessionKey='holder'")

    assert {:ok, {:error, %{code: "not_holder"}}} =
             DB.transaction(ctx.db, &Wakes.register_wait_in_txn(&1, input))

    assert {:ok, _} =
             DB.query(
               ctx.db,
               "UPDATE sessions SET spawnedBy='supervisor' WHERE sessionKey='holder'"
             )

    assert {:ok, _} =
             DB.query(
               ctx.db,
               "UPDATE sessions SET ownerUserId='owner-b' WHERE sessionKey='supervisor'"
             )

    assert {:ok, {:error, %{code: "not_holder"}}} =
             DB.transaction(ctx.db, &Wakes.register_wait_in_txn(&1, input))
  end

  test "missing relief runtime rolls back admission and schema initialization reinstalls it",
       ctx do
    qualification_policy(ctx)

    assert {:ok, _} =
             DB.transaction(ctx.db, fn txn ->
               EffortCheckin.arm_in_txn(txn, %{base_dir: ctx.base}, %{
                 id: "A",
                 holderKey: "holder"
               })
             end)

    before = effort_snapshot(ctx.db)
    {:ok, wake_count} = DB.query(ctx.db, "SELECT COUNT(*) FROM wakes")
    {:ok, sidecar_count} = DB.query(ctx.db, "SELECT COUNT(*) FROM supervision_liveness_sidecar")
    key = {Tightbeam.RuleRuntime, :wait_relief}
    installed = :persistent_term.get(key)

    try do
      :persistent_term.erase(key)

      assert {:error, %RuntimeError{message: "wait relief accounting runtime is not installed"}} =
               DB.transaction(ctx.db, fn txn ->
                 Wakes.register_wait_in_txn(txn, %{
                   session_key: "holder",
                   origin: "agent:holder",
                   prompt: "Continue after resolution.",
                   due_at: due_after(),
                   assignment_id: "A",
                   predicate: predicate("R"),
                   registrant_session_key: "holder",
                   owner_user_id: "owner-a"
                 })
               end)

      assert {:ok, ^wake_count} = DB.query(ctx.db, "SELECT COUNT(*) FROM wakes")

      assert {:ok, ^sidecar_count} =
               DB.query(ctx.db, "SELECT COUNT(*) FROM supervision_liveness_sidecar")

      assert effort_snapshot(ctx.db) == before
      assert :ok = Tightbeam.Schema.ensure_all(ctx.db)
      wake = register_wait(ctx.db, due_after(), predicate("R"))

      assert {:ok, [[started]]} =
               DB.query(
                 ctx.db,
                 "SELECT reliefStartedAt FROM effort_checkin_generations WHERE assignmentId='A'"
               )

      assert started == wake.created_at
    after
      :persistent_term.put(key, installed)
    end
  end

  test "C5-C7,V1-V2: overlapping provisional waits pause one generation and challenge resumes its remainder",
       ctx do
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
    # Reopen a real SQLite snapshot under a fresh database owner.
    path = Path.join(ctx.base, "relief-restart.db")
    assert :ok = DB.execute(ctx.db, "VACUUM INTO '#{path}'")
    restarted = :"relief_restart_#{System.unique_integer([:positive])}"
    start_supervised!({DB, path: path, name: restarted}, id: restarted)
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

  test "C5: ready-now uses normal effort and self-owed relief requires a policy election", ctx do
    qualification_policy(ctx)

    assert {:ok, _} =
             DB.transaction(ctx.db, fn txn ->
               EffortCheckin.arm_in_txn(txn, %{base_dir: ctx.base}, %{
                 id: "A",
                 holderKey: "holder"
               })
             end)

    register_wait(ctx.db, due_after(), predicate("R", "open"))
    assert covered?(ctx.db, "A")

    assert {:ok, [[nil, 0]]} =
             DB.query(
               ctx.db,
               "SELECT reliefStartedAt,reliefExcludedMs FROM effort_checkin_generations WHERE assignmentId='A'"
             )

    assignment(ctx.db, "self-R", "holder")
    register_wait(ctx.db, due_after(), predicate("self-R"))

    assert {:ok, [[nil, 0]]} =
             DB.query(
               ctx.db,
               "SELECT reliefStartedAt,reliefExcludedMs FROM effort_checkin_generations WHERE assignmentId='A'"
             )

    qualification_policy(ctx, false)
    elected = register_wait(ctx.db, due_after(), predicate("self-R"))

    assert {:ok, [[started, 0]]} =
             DB.query(
               ctx.db,
               "SELECT reliefStartedAt,reliefExcludedMs FROM effort_checkin_generations WHERE assignmentId='A'"
             )

    assert started == elected.created_at
  end

  test "C6-C7: success, resolver termination, fallback and cancellation each end relief once",
       ctx do
    qualification_policy(ctx)

    assert {:ok, _} =
             DB.transaction(ctx.db, fn txn ->
               Supervision.transition_in_txn(txn, %{
                 kind: "assignment_open",
                 assignment_id: "A",
                 opened_at: 0,
                 principal: "user:owner-a",
                 supervision_interval_ms: 60_000
               })

               EffortCheckin.arm_in_txn(txn, %{base_dir: ctx.base}, %{
                 id: "A",
                 holderKey: "holder"
               })
             end)

    before = effort_snapshot(ctx.db)

    for ending <- ~w(success terminal fallback cancel) do
      resolver = "R-#{ending}"
      assignment(ctx.db, resolver, "resolver")
      due = if ending == "fallback", do: System.system_time(:millisecond) - 1, else: due_after()
      wake = register_wait(ctx.db, due, predicate(resolver))

      assert {:ok, [[started, prior]]} =
               DB.query(
                 ctx.db,
                 "SELECT reliefStartedAt,reliefExcludedMs FROM effort_checkin_generations WHERE assignmentId='A'"
               )

      interval_start = started - 1_000

      assert {:ok, _} =
               DB.query(
                 ctx.db,
                 "UPDATE effort_checkin_generations SET reliefStartedAt=?1 WHERE assignmentId='A'",
                 [interval_start]
               )

      case ending do
        "success" ->
          assert %{assignment: _} = attest(ctx.db, resolver, "resolver", "completion")

        "terminal" ->
          assert %{assignment: _} = attest(ctx.db, resolver, "resolver", "surrender")

        "fallback" ->
          assert :ok = Wakes.fire_due(ctx.scheduler)

        "cancel" ->
          assert {:ok, {:accepted_in_txn, _, %{canceled: true}}} =
                   DB.transaction(ctx.db, fn txn ->
                     {:ok, trigger} = Supervision.liveness_trigger_in_txn(txn, {:assignment, "A"})

                     Wakes.cancel_in_txn(txn, %{
                       wake_id: wake.wake_id,
                       expected_origin: wake.origin,
                       requester: %{kind: "session", id: "holder"},
                       reason_kind: "requester_withdrew",
                       causal_source: %{
                         kind: "verb_call",
                         accepted_event: %{
                           origin: wake.origin,
                           session_key: "holder",
                           principal: {:session, "holder"}
                         }
                       },
                       outcome: %{kind: "no_replacement", liveness_trigger: trigger}
                     })
                   end)
      end

      ended = Wakes.get(ctx.db, wake.wake_id)
      endpoint = ended.canceled_at || ended.recognition_at
      expected = prior + endpoint - interval_start

      assert {:ok, [[nil, ^expected]]} =
               DB.query(
                 ctx.db,
                 "SELECT reliefStartedAt,reliefExcludedMs FROM effort_checkin_generations WHERE assignmentId='A'"
               )

      assert {:ok, :ok} =
               DB.transaction(
                 ctx.db,
                 &EffortCheckin.reconcile_wait_relief_in_txn(&1, "A", endpoint + 100)
               )

      assert {:ok, [[nil, ^expected]]} =
               DB.query(
                 ctx.db,
                 "SELECT reliefStartedAt,reliefExcludedMs FROM effort_checkin_generations WHERE assignmentId='A'"
               )

      assert effort_snapshot(ctx.db) == before
    end
  end

  test "C8: failed and unknown continuation outcomes end coverage without answering work", ctx do
    qualification_policy(ctx)

    for status <- ~w(failed failed_unknown) do
      wake = register_wait(ctx.db, due_after(), predicate("R", "open"))
      assert :ok = Wakes.fire_due(ctx.scheduler)
      assert {:ok, turn} = Ledger.claim_next(ctx.db, "holder", "fixture")
      assert covered?(ctx.db, "A")
      before = {attest_count(ctx.db, "A"), supervision_counts(ctx.db, "A")}
      assert :ok = Ledger.finish(ctx.db, turn.seq, status, "model capacity")
      refute covered?(ctx.db, "A")
      assert {attest_count(ctx.db, "A"), supervision_counts(ctx.db, "A")} == before

      assert {:ok, [["open", nil]]} =
               DB.query(ctx.db, "SELECT state,outcome FROM assignments WHERE id='A'")

      assert turn.wake_id == wake.wake_id
    end
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

  defp assignment(db, id, holder, work_item_id \\ nil, reviews_assignment_id \\ nil) do
    {:ok, _} =
      DB.query(
        db,
        "INSERT INTO assignments(id,subject,holderKey,openedByUser,openedAt,workItemId,reviewsAssignmentId) VALUES(?1,?2,?3,'owner-a',1,?4,?5)",
        [id, id, holder, work_item_id, reviews_assignment_id]
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

  defp artifact_predicate(producer_id, expected_hash, reviewed?, resolver_id \\ nil) do
    resolver_id = resolver_id || producer_id

    artifact_binding =
      %{"producedByAssignmentId" => producer_id}
      |> then(fn binding ->
        if is_binary(expected_hash),
          do: Map.put(binding, "contentSha256", expected_hash),
          else: binding
      end)

    conditions =
      [%{"fact" => "artifact.present", "op" => "eq", "value" => true}]
      |> then(fn conditions ->
        if is_binary(expected_hash) do
          conditions ++
            [%{"fact" => "artifact.content_sha256", "op" => "eq", "value" => expected_hash}]
        else
          conditions
        end
      end)
      |> then(fn conditions ->
        if reviewed? do
          conditions ++
            [
              %{
                "fact" => "review.qualifying_verdict_kinds",
                "op" => "in",
                "value" => ["reviewed-clean"]
              }
            ]
        else
          conditions
        end
      end)

    %{
      "conditions" => conditions,
      "bindings" => %{"artifact" => artifact_binding},
      "resolverRef" => %{"kind" => "assignment", "id" => resolver_id},
      "necessity" => "The producer and its exact reviewed revision are required.",
      "verificationRef" => %{"kind" => "assignment", "id" => "V"}
    }
  end

  defp decision_predicate(request_id, expected_status) do
    %{
      "conditions" => [
        %{"fact" => "decision_request.status", "op" => "eq", "value" => expected_status}
      ],
      "bindings" => %{"decisionRequestId" => request_id},
      "resolverRef" => %{"kind" => "decision_request", "id" => request_id},
      "necessity" => "The named decision must reach the requested disposition.",
      "verificationRef" => %{"kind" => "assignment", "id" => "V"}
    }
  end

  defp condition_fact_predicate(kind, scope, asserted_cursor) do
    %{
      "conditions" => [
        %{"fact" => "condition_fact.matches", "op" => "eq", "value" => true}
      ],
      "bindings" => %{
        "conditionKind" => kind,
        "conditionScope" => scope,
        "conditionAfterId" => asserted_cursor
      },
      "resolverRef" => %{"kind" => "assignment", "id" => "R"},
      "necessity" => "Only a new owner-scoped condition fact satisfies this dependency.",
      "verificationRef" => %{"kind" => "assignment", "id" => "V"}
    }
  end

  defp default_decision_predicate(request_id) do
    predicate = decision_predicate(request_id, "ruled")

    put_in(predicate, ["conditions"], [
      %{
        "fact" => "decision_request.status",
        "op" => "in",
        "value" => ~w(ruled consumed withdrawn superseded)
      }
    ])
  end

  defp work_item_predicate(work_item_id, expected_state, resolver_id) do
    %{
      "conditions" => [
        %{"fact" => "work_item.state", "op" => "eq", "value" => expected_state}
      ],
      "bindings" => %{"workItemId" => work_item_id},
      "resolverRef" => %{"kind" => "assignment", "id" => resolver_id},
      "necessity" => "The work item disposition decides the continuation.",
      "verificationRef" => %{"kind" => "assignment", "id" => "V"}
    }
  end

  defp default_work_item_predicate(work_item_id, resolver_id) do
    predicate = work_item_predicate(work_item_id, "closed", resolver_id)

    put_in(predicate, ["conditions"], [
      %{
        "fact" => "work_item.state",
        "op" => "in",
        "value" => ~w(closed failed iceboxed)
      }
    ])
  end

  defp record_artifact(db, producer_id, hash) do
    Artifacts.record(db, %{
      principal: {:session, "resolver"},
      session_key: "resolver",
      params: %{
        kind: "report",
        title: "candidate #{producer_id}",
        origin_path: "/tmp/#{producer_id}",
        work_item_id: "wi-output",
        produced_by_assignment_id: producer_id,
        content_sha256: hash
      }
    })
  end

  defp review_verdict(db, review_id, artifact, verdict_kind) do
    Assignments.__handle__(db, "attest", %{
      principal: {:session, "verifier"},
      origin: "session:verifier",
      params: %{
        assignment_id: review_id,
        kind: "verdict",
        verdict_kind: verdict_kind,
        artifact_id: artifact.artifact_id,
        content_sha256: artifact.content_sha256,
        note: "revision verdict"
      }
    })
  end

  defp revoke(db, assignment_id) do
    Assignments.__handle__(db, "revoke-assignment", %{
      verb: "revoke-assignment",
      principal: {:user, "owner-a"},
      origin: "user:owner-a",
      params: %{assignment_id: assignment_id}
    })
  end

  defp operator_ask(db, question, supersedes \\ nil) do
    Escalation.operator_ask(db, %{
      principal: {:session, "holder"},
      session_key: "holder",
      origin: "agent:holder-role",
      params: %{
        question: question,
        options: [%{label: "continue"}, %{label: "stop"}],
        supersedes: supersedes
      }
    })
  end

  defp operator_withdraw(db, request_id) do
    Escalation.operator_withdraw(db, %{
      principal: {:session, "holder"},
      session_key: "holder",
      origin: "agent:holder-role",
      params: %{request: request_id, reason: "fixture withdrawal"}
    })
  end

  defp dispose_work_item(db, verb, work_item_id) do
    WorkItems.__handle__(db, verb, %{
      verb: verb,
      principal: {:user, "owner-a"},
      origin: "user:owner-a",
      params: %{work_item_id: work_item_id, reason: "fixture disposition"}
    })
  end

  defp current_work_item_state(db, work_item_id) do
    {:ok, [[state]]} = DB.query(db, "SELECT state FROM work_items WHERE id=?1", [work_item_id])
    state
  end

  defp due_after, do: System.system_time(:millisecond) + 60_000
end
