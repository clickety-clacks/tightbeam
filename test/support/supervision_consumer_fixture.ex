defmodule Tightbeam.SupervisionConsumerFixture do
  @moduledoc false
  import ExUnit.Assertions
  alias Tightbeam.Model

  alias Tightbeam.{
    Assignments,
    ConditionFacts,
    ConnRegistry,
    DB,
    EventLog,
    Gateway,
    HarnessHealth,
    HarnessProcess,
    Ledger,
    NoticeBatcher,
    Org,
    Projection,
    RailRemedy,
    Roles,
    Rules,
    Schema,
    Supervision,
    Wakes
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

  def run!(id, authority) do
    tmp = Path.join(System.tmp_dir!(), "supervision-cold-#{System.unique_integer([:positive])}")
    prepared = Tightbeam.GuardRuntimeFixture.prepare!(tmp, "supervision_consumer_runtime.exs")

    {output, status} =
      System.cmd(prepared.executable, prepared.args ++ [to_string(id), to_string(authority)],
        env: prepared.env,
        stderr_to_stdout: true
      )

    File.write!(Path.join(tmp, "runtime.log"), output)
    assert status == 0, output
    assert output =~ "supervision-cold: ok", output
  end

  def run_case!(id, authority, base, locks) do
    {:ok, sup} = Supervisor.start_link([], strategy: :one_for_one)
    Process.put({__MODULE__, :supervisor}, sup)
    Process.put(:fixture_locks, locks)
    db = DB

    start_supervised!(
      {DB, path: Path.join(base, "state.db"), name: db, guard_inputs: [lock_dir: locks]}
    )

    :ok = Schema.ensure_all(db)
    :ok = DB.assert_base_admitted!(db, base)
    bin = Path.join(base, "fixture-bin")
    File.mkdir_p!(bin)
    tripwire = Path.join(base, "forbidden-execution.log")
    System.put_env("GUARD_TRIPWIRE", tripwire)

    for name <- ["claude", "codex", "fixture"] do
      path = Path.join(bin, name)

      File.write!(
        path,
        "#!/bin/sh\nif [ \"#{name}\" = codex ] && [ \"$#\" = 2 ] && [ \"$1\" = --dangerously-bypass-hook-trust ] && [ \"$2\" = --version ]; then echo fixture-only; exit 0; fi\nif [ \"$#\" = 1 ] && [ \"$1\" = --version ]; then echo fixture-only; exit 0; fi\necho forbidden >> \"$GUARD_TRIPWIRE\"\nexit 64\n"
      )

      File.chmod!(path, 0o755)
    end

    for name <- ["npm", "ssh"] do
      path = Path.join(bin, name)
      File.write!(path, "#!/bin/sh\necho forbidden >> \"$GUARD_TRIPWIRE\"\nexit 64\n")
      File.chmod!(path, 0o755)
    end

    System.put_env("PATH", bin <> ":" <> System.fetch_env!("PATH"))

    for name <- ["claude", "codex", "fixture", "npm", "ssh"],
        do: assert(System.find_executable(name) == Path.join(bin, name))

    {:ok, _} = DB.query(db, "INSERT INTO users(userId,isAdmin,createdAt) VALUES ('flynn',1,1)")
    main = session(db, Org.personal_session_key("flynn"), nil, true)
    supervisor = session(db, "supervisor", main.session_key)
    holder = session(db, "holder", supervisor.session_key)
    assignment(db, "asg_1", holder.session_key, "ship it", 1)
    handlers = Gateway.handlers(%{db: db, wake_tick_ms: 60_000})
    Rules.load!(base, Map.keys(handlers))

    ctx = %{
      db: db,
      handlers: handlers,
      main: main,
      supervisor: supervisor,
      holder: holder,
      base: base
    }

    try do
      proof!(id, ctx, authority)
      refute File.exists?(System.fetch_env!("GUARD_TRIPWIRE"))
    after
      Supervisor.stop(sup)
      await_lock!(base, locks)
    end
  end

  defp proof!(1, ctx, authority) do
    insert_entitlement!(ctx.db, "asg_1", generation: 1, due_at: 0)
    consume = real_consumer_fixture!(ctx, expire_gap: false)
    assert {:ok, _} = DB.query(ctx.db, "UPDATE users SET isAdmin=0 WHERE userId='flynn'")

    assert {:ok, _} =
             DB.query(
               ctx.db,
               "INSERT INTO users(userId,isAdmin,createdAt) VALUES ('repair-admin',1,1)"
             )

    assert {:prodded, 1} =
             Supervision.evaluate(
               ctx.db,
               ctx.handlers,
               2,
               "holder",
               terminal!(ctx.db, "holder")
             )

    [wake] = Wakes.list_pending(ctx.db)
    assert :appended = admit_supervision_wake!(ctx.db, wake)
    assert {:ok, source} = Ledger.claim_next(ctx.db, "holder", "interrupted-notice")

    assert :ok =
             Ledger.finish(ctx.db, source.seq, "failed_unknown", "interrupted: outcome unknown")

    assert {:ok, [[initial_json]]} =
             DB.query(ctx.db, "SELECT reminderState FROM assignments WHERE id='asg_1'")

    initial = JSON.decode!(initial_json)
    lane = :"repair_acceptance_#{System.unique_integer([:positive])}"
    start_supervised!({LaneDoorbell, lane})
    user = if authority == :opener, do: "flynn", else: "repair-admin"

    call = %{
      verb: "repair-assignment",
      origin: "user:#{user}",
      principal: {:user, user},
      session_key: nil,
      lane_manager: lane,
      params: %{
        assignment_id: "asg_1",
        action: "rerun",
        turn_seq: source.seq,
        idempotency_key: "repair-accepted",
        outcome: "not-completed"
      }
    }

    dispatch = fn request -> Tightbeam.Dispatch.dispatch(ctx.db, ctx.handlers, request) end

    assert {:error, %{code: "not_authorized"}} =
             dispatch.(%{
               call
               | origin: "agent:holder",
                 principal: {:session, "holder"},
                 session_key: "holder"
             })

    assert {:error, %{code: "no_open_incident"}} =
             dispatch.(put_in(call, [:params, :idempotency_key], "without-incident"))

    session = Org.get(ctx.db, "holder")

    assert {:opened, incident} =
             HarnessHealth.observe(ctx.db, %{
               correlation_id: "repair-acceptance-interrupted",
               harness: session.harness,
               host: session.host,
               failure_class: "interrupted-outcome-unknown",
               evidence_kind: "authoritative-provider",
               session_key: "holder",
               assignment_id: "asg_1",
               observed_at: System.system_time(:millisecond),
               cause: "isolated interrupted notice",
               principal: "process:tightbeam"
             })

    wrong = %{call | params: %{call.params | action: "resume", idempotency_key: "wrong-action"}}
    assert {:error, %{code: "wrong_repair"}} = dispatch.(wrong)

    unreconciled = %{
      call
      | params: Map.delete(Map.put(call.params, :idempotency_key, "unknown-effects"), :outcome)
    }

    assert {:error, %{code: "outcome_reconciliation_required"}} = dispatch.(unreconciled)

    assert {:ok, [[^initial_json]]} =
             DB.query(ctx.db, "SELECT reminderState FROM assignments WHERE id='asg_1'")

    assert {:ok, [[0]]} =
             DB.query(
               ctx.db,
               "SELECT count(*) FROM turns WHERE sessionKey='holder' AND status='queued'"
             )

    assert {:ok, repaired} = dispatch.(call)
    assert repaired.ok
    assert repaired.incidentId == incident.id
    assert repaired.sourceTurnSeq == source.seq
    assert repaired.assignmentId == "asg_1"
    assert {:ok, ^repaired} = dispatch.(call)

    assert {:ok, [[pending_json]]} =
             DB.query(ctx.db, "SELECT reminderState FROM assignments WHERE id='asg_1'")

    pending = JSON.decode!(pending_json)
    assert pending["pending"]["consumer"] == %{"turn" => repaired.attemptTurnSeq}
    assert pending["pending"]["intent"] == initial["pending"]["intent"]
    assert pending["pending"]["snapshot"] == initial["pending"]["snapshot"]
    assert pending["claimEpoch"] == initial["claimEpoch"] + 1

    assert {:ok, :no_claim} =
             DB.transaction(
               ctx.db,
               &Tightbeam.ReminderDelivery.delivered_in_txn(&1, source.seq)
             )

    assert {:ok, [[^pending_json]]} =
             DB.query(ctx.db, "SELECT reminderState FROM assignments WHERE id='asg_1'")

    assert %{seq: delivered_seq, wake_id: nil} = consume.("holder")
    assert delivered_seq == repaired.attemptTurnSeq

    assert {:ok, [[delivered_json]]} =
             DB.query(ctx.db, "SELECT reminderState FROM assignments WHERE id='asg_1'")

    delivered = JSON.decode!(delivered_json)
    assert delivered["pending"] == nil
    assert delivered["lastConsumer"] == %{"turn" => delivered_seq}
    assert delivered["lastIntent"] == initial["pending"]["intent"]
    assert delivered["lastSnapshot"] == initial["pending"]["snapshot"]
    assert delivered["nextEligibleAt"] > System.system_time(:millisecond)
    assert {:ok, ^repaired} = dispatch.(call)

    assert {:ok, :no_claim} =
             DB.transaction(
               ctx.db,
               &Tightbeam.ReminderDelivery.delivered_in_txn(&1, delivered_seq)
             )

    assert {:ok, [[^delivered_json]]} =
             DB.query(ctx.db, "SELECT reminderState FROM assignments WHERE id='asg_1'")

    assert {:ok, [["failed_unknown"]]} =
             DB.query(ctx.db, "SELECT status FROM turns WHERE seq=?1", [source.seq])

    assert {:ok, [[0]]} =
             DB.query(
               ctx.db,
               "SELECT count(*) FROM turns WHERE sessionKey='holder' AND status IN ('queued','running')"
             )
  end

  defp proof!(2, ctx, authority) do
    consume = real_consumer_fixture!(ctx, expire_gap: false)

    scheduler =
      start_supervised!(
        {Wakes,
         db: ctx.db,
         name: :r1_api_scheduler,
         tick_ms: 60_000,
         deliver: fn _wake -> flunk("condition admission must not deliver an unrelated wake") end}
      )

    ctx = %{
      ctx
      | handlers: Gateway.handlers(%{db: ctx.db, wake_scheduler: scheduler, wake_tick_ms: 60_000})
    }

    Roles.create!(ctx.db, "r1-api-holder", "flynn", "holder")

    assert %{attest: %{id: evidence}} =
             Assignments.__handle__(ctx.db, "attest", %{
               verb: "attest",
               origin: "agent:r1-api-holder",
               principal: {:session, "holder"},
               session_key: "holder",
               params: %{
                 assignment_id: "asg_1",
                 kind: "progress",
                 note: "Typed consequence evidence"
               }
             })

    payload = %{
      "assignmentId" => "asg_1",
      "consequenceKey" => "release",
      "revision" => "one",
      "attentionRequestId" => "request-one",
      "evidenceAttestId" => evidence,
      "explicitAttention" => true
    }

    call = %{
      verb: "condition",
      origin: "agent:r1-api-holder",
      principal: {:session, "holder"},
      session_key: "holder",
      params: %{kind: "obligation-consequence-changed", scope: "asg_1", payload: payload}
    }

    assert %{fact_id: fact_id} = ctx.handlers["condition"].(call)
    assert %{fact_id: ^fact_id} = ctx.handlers["condition"].(call)

    assert %{code: "conflict"} =
             ctx.handlers["condition"].(%{
               call
               | params: %{call.params | payload: Map.put(payload, "revision", "conflict")}
             })

    assert %{code: "not_authorized"} =
             ctx.handlers["condition"].(%{call | principal: {:session, "supervisor"}})

    assert {:ok, _} =
             DB.query(
               ctx.db,
               "UPDATE supervision_entitlements SET dueAt=0 WHERE assignmentId='asg_1'"
             )

    assert :rebased =
             Supervision.evaluate(ctx.db, ctx.handlers, 2, "holder", terminal!(ctx.db, "holder"))

    # The attributed fact is a real receipt. Advance the test's next assessment
    # deadline after proving that receipt reset, not by bypassing recognition.
    assert {:ok, _} =
             DB.query(
               ctx.db,
               "UPDATE supervision_entitlements SET dueAt=0 WHERE assignmentId='asg_1'"
             )

    assert {:prodded, 1} =
             Supervision.evaluate(ctx.db, ctx.handlers, 2, "holder", terminal!(ctx.db, "holder"))

    assert [%{wake_id: wake_id}] = Wakes.list_pending(ctx.db)

    newer = %{payload | "revision" => "two", "attentionRequestId" => "request-two"}

    assert %{fact_id: newer_id} =
             ctx.handlers["condition"].(%{call | params: %{call.params | payload: newer}})

    refute newer_id == fact_id

    assert {:ok, [[pending_json]]} =
             DB.query(ctx.db, "SELECT reminderState FROM assignments WHERE id='asg_1'")

    assert JSON.decode!(pending_json)["pending"]["snapshot"]["consequence"] == payload
    assert :appended = admit_supervision_wake!(ctx.db, Wakes.get(ctx.db, wake_id))
    %{seq: seq} = consume.("holder")

    assert {:ok, [[delivered_json]]} =
             DB.query(ctx.db, "SELECT reminderState FROM assignments WHERE id='asg_1'")

    delivered = JSON.decode!(delivered_json)
    assert delivered["currentConsequence"] == newer
    assert delivered["lastSnapshot"]["consequence"] == payload
    assert delivered["lastConsumer"] == %{"wake" => wake_id}

    assert {:ok, :no_claim} =
             DB.transaction(ctx.db, &Tightbeam.ReminderDelivery.delivered_in_txn(&1, seq))

    assert {:ok, [[^delivered_json]]} =
             DB.query(ctx.db, "SELECT reminderState FROM assignments WHERE id='asg_1'")

    # The old notification succeeded, but its newer consequence still merits
    # attention before the old successful-delivery gap expires.
    assert delivered["nextEligibleAt"] > System.system_time(:millisecond)

    assert :not_due =
             Supervision.evaluate(ctx.db, ctx.handlers, 2, "holder", terminal!(ctx.db, "holder"))

    assert {:ok, _} =
             DB.query(
               ctx.db,
               "UPDATE supervision_entitlements SET dueAt=0 WHERE assignmentId='asg_1'"
             )

    assert {:prodded, 2} =
             Supervision.evaluate(ctx.db, ctx.handlers, 2, "holder", terminal!(ctx.db, "holder"))

    assert {:ok, [[new_pending_json]]} =
             DB.query(ctx.db, "SELECT reminderState FROM assignments WHERE id='asg_1'")

    new_pending = JSON.decode!(new_pending_json)
    assert new_pending["nextEligibleAt"] == delivered["nextEligibleAt"]
    assert new_pending["nextEligibleAt"] > System.system_time(:millisecond)
    assert new_pending["lastSnapshot"] == delivered["lastSnapshot"]
    assert new_pending["lastConsumer"] == delivered["lastConsumer"]
    assert new_pending["pending"]["snapshot"]["consequence"] == newer
    assert %{"wake" => next_wake} = new_pending["pending"]["consumer"]
    refute next_wake == wake_id

    assert %{assignment_id: "asg_1", session_key: "holder", state: "pending"} =
             Wakes.get(ctx.db, next_wake)
  end

  defp proof!(3, ctx, authority) do
    terminal!(ctx.db, "holder")
    insert_entitlement!(ctx.db, "asg_1", generation: 4, due_at: 0, interval: 60_000)
    first = start_liveness!(ctx, sweep_ms: 60_000)
    assert [%{assignment_id: "asg_1"} = charged] = Wakes.list_pending(ctx.db)
    assert :appended = admit_supervision_wake!(ctx.db, charged)
    assert {:ok, turn} = Ledger.claim_next(ctx.db, "holder", "composed-controller")
    assert :ok = Ledger.finish(ctx.db, turn.seq, "delivered")
    sweep_liveness!(first)

    assert {:ok, [["settled"]]} =
             DB.query(
               ctx.db,
               "SELECT controllerState FROM supervision_liveness_sidecar WHERE wakeId=?1",
               [charged.wake_id]
             )

    assert %{attest: %{id: receipt_id}} =
             Assignments.__handle__(ctx.db, "attest", %{
               principal: {:session, "holder"},
               origin: "session:holder",
               params: %{
                 assignment_id: "asg_1",
                 kind: "verdict",
                 verdict_kind: "tests-passed",
                 note: "composed fixture verification receipt"
               }
             })

    sweep_liveness!(first)
    reset = Supervision.prod_state(ctx.db, "asg_1")
    assert reset.supervisionBasisKind == "liveness_receipt"
    assert reset.prodCount == 0
    assert reset.attemptCount == 0

    assert {:ok, [[^receipt_id]]} =
             DB.query(
               ctx.db,
               "SELECT sourceId FROM supervision_liveness_receipts WHERE sourceKind='verdict' AND sourceId=?1",
               [receipt_id]
             )

    session(ctx.db, "r1-resolver", ctx.main.session_key)
    session(ctx.db, "r1-verifier", ctx.main.session_key)
    assignment(ctx.db, "asg_r1_resolver", "r1-resolver", "resolve prerequisite", 1)
    assignment(ctx.db, "asg_r1_verifier", "r1-verifier", "verify prerequisite", 1)

    write_rules(ctx, """
    [[policy]]
    name = "composed-verification"
    purpose = "wait-verification-admission"
    when = [{fact="verifier.open",op="eq",value=true},{fact="verifier.holder_is_other",op="eq",value=true}]
    verification = {trigger="registration",terminal="bound-verdict-or-obligation-terminal",fallback="wake-due-at"}
    [[policy]]
    name = "composed-coverage"
    purpose = "wait-prod-coverage"
    when = [{fact="wait.coverage_valid",op="eq",value=true}]
    """)

    Rules.load!(ctx.base, Map.keys(ctx.handlers))

    predicate = %{
      "conditions" => [%{"fact" => "assignment.outcome", "op" => "eq", "value" => "completed"}],
      "bindings" => %{"assignmentId" => "asg_r1_resolver"},
      "resolverRef" => %{"kind" => "assignment", "id" => "asg_r1_resolver"},
      "verificationRef" => %{"kind" => "assignment", "id" => "asg_r1_verifier"},
      "necessity" =>
        "The resolver must provide the prerequisite before this assignment continues."
    }

    Roles.create!(ctx.db, "r1-holder-role", "flynn", "holder")

    assert %{wake_id: wait_id} =
             ctx.handlers["wake"].(%{
               origin: "agent:r1-holder-role",
               principal: {:session, "holder"},
               session_key: "holder",
               params: %{
                 assignment_id: "asg_1",
                 predicate: predicate,
                 prompt: "Continue after verified prerequisite",
                 after_ms: 600_000,
                 nudge: false
               }
             })

    assert Wakes.get(ctx.db, wait_id).obligation_ref == "asg_1"
    assert {:ok, true} = DB.transaction(ctx.db, &Wakes.covering_continuation_in_txn?(&1, "asg_1"))
    assert :ok = stop_supervised(Supervision)
    # Make the settled receipt deadline due: suppression must come from the
    # authorized wait, not from a future timer. This is fixture clock setup.
    {:ok, _} =
      DB.query(ctx.db, "UPDATE supervision_entitlements SET dueAt=0 WHERE assignmentId='asg_1'")

    before =
      DB.query(
        ctx.db,
        "SELECT count(*) FROM wakes WHERE assignmentId='asg_1' AND origin='process:tightbeam'"
      )

    path = Path.join(ctx.base, "state.db")
    :ok = stop_supervised!(DB)
    await_lock!(ctx.base, Process.get(:fixture_locks))
    reopened = :"r1_reopened_#{System.unique_integer([:positive])}"

    start_supervised!(
      {DB, name: reopened, path: path, guard_inputs: [lock_dir: Process.get(:fixture_locks)]},
      id: reopened
    )

    assert :ok = Schema.ensure_all(reopened)
    handlers = Gateway.handlers(%{db: reopened, wake_tick_ms: 60_000})
    second = start_liveness!(%{ctx | db: reopened, handlers: handlers}, sweep_ms: 60_000)
    sweep_liveness!(second)

    assert {:ok, true} =
             DB.transaction(reopened, &Wakes.covering_continuation_in_txn?(&1, "asg_1"))

    assert DB.query(
             reopened,
             "SELECT count(*) FROM wakes WHERE assignmentId='asg_1' AND origin='process:tightbeam'"
           ) == before

    assert Supervision.prod_state(reopened, "asg_1").prodCount == 0
    assert Supervision.prod_state(reopened, "asg_1").attemptCount == 0
    assert Wakes.get(reopened, wait_id).state == "pending"

    assert {:ok, [["settled"]]} =
             DB.query(
               reopened,
               "SELECT controllerState FROM supervision_liveness_sidecar WHERE wakeId=?1",
               [charged.wake_id]
             )
  end

  defp proof!(4, ctx, authority) do
    first_terminal_seq = terminal!(ctx.db, "holder")
    insert_entitlement!(ctx.db, "asg_1", generation: 1, due_at: 0)
    consume = real_consumer_fixture!(ctx)

    assert {:escalated, 1, "supervisor"} =
             Supervision.evaluate(ctx.db, ctx.handlers, 0, "holder", first_terminal_seq)

    assert [first_wake] = Wakes.list_pending(ctx.db)
    assert :appended = admit_supervision_wake!(ctx.db, first_wake)
    consume.(first_wake.session_key)

    second_terminal_seq = terminal!(ctx.db, "holder")
    insert_entitlement!(ctx.db, "asg_1", generation: 2, due_at: 0)

    assert {:escalated, 2, main_session_key} =
             Supervision.evaluate(ctx.db, ctx.handlers, 0, "holder", second_terminal_seq)

    assert main_session_key == ctx.main.session_key

    assert [second_wake] = Wakes.list_pending(ctx.db)
    assert :appended = admit_supervision_wake!(ctx.db, second_wake)

    name = start_liveness!(ctx, sweep_ms: 60_000)

    assert is_pid(Process.whereis(name))

    assert %{
             supervisionState: "parent_elevated",
             supervisionTransferWakeId: transfer_wake,
             supervisionTransferSessionKey: ^main_session_key
           } = Supervision.prod_state(ctx.db, "asg_1")

    assert transfer_wake == second_wake.wake_id
    refute transfer_wake == first_wake.wake_id
  end

  defp proof!(5, ctx, authority) do
    insert_entitlement!(ctx.db, "asg_1", generation: 1, due_at: 0)
    consume = real_consumer_fixture!(ctx)
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
            turn = consume.("holder")
            assert turn.wake_id == originating.wake_id

            {:ok, _} =
              DB.query(
                ctx.db,
                "UPDATE supervision_entitlements SET dueAt=0 WHERE assignmentId='asg_1' AND state='armed'"
              )

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

  defp proof!(6, ctx, authority) do
    n = 12
    assignment(ctx.db, "asg_main", ctx.main.session_key, "main work", 2)
    insert_entitlement!(ctx.db, "asg_main", generation: 1, due_at: 0)
    consume = real_consumer_fixture!(ctx)
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
            turn = consume.(session_key)
            state_at_nudge = Wakes.get(ctx.db, turn.wake_id).state

            {:ok, _} =
              DB.query(
                ctx.db,
                "UPDATE supervision_entitlements SET dueAt=0 WHERE assignmentId='asg_main' AND state='armed'"
              )

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

  defp proof!(7, ctx, authority) do
    {:ok, _} =
      DB.query(ctx.db, "UPDATE sessions SET spawnedBy='holder' WHERE sessionKey='supervisor'")

    assignment(ctx.db, "asg_2", "supervisor", "second", 2)
    insert_entitlement!(ctx.db, "asg_1", generation: 1, due_at: 0)
    insert_entitlement!(ctx.db, "asg_2", generation: 1, due_at: 0)
    consume = real_consumer_fixture!(ctx)

    h1 = terminal!(ctx.db, "holder")

    assert {:escalated, 1, "supervisor"} =
             Supervision.evaluate(ctx.db, ctx.handlers, 0, "holder", h1)

    fire_all_pending(ctx.db, consume)
    s1 = terminal!(ctx.db, "supervisor")

    assert {:escalated, 1, "holder"} =
             Supervision.evaluate(ctx.db, ctx.handlers, 0, "supervisor", s1)

    fire_all_pending(ctx.db, consume)
    insert_entitlement!(ctx.db, "asg_1", generation: 2, due_at: 0)
    h2 = terminal!(ctx.db, "holder")

    assert {:escalated, 2, main} =
             Supervision.evaluate(ctx.db, ctx.handlers, 0, "holder", h2)

    assert main == ctx.main.session_key
    assert Supervision.prod_state(ctx.db, "asg_1").prodCount == 2
    assert Supervision.prod_state(ctx.db, "asg_1").prodCount > 0 + 1

    fire_all_pending(ctx.db, consume)
    main_terminal = terminal!(ctx.db, ctx.main.session_key)

    assert :idle =
             Supervision.evaluate(ctx.db, ctx.handlers, 0, ctx.main.session_key, main_terminal)

    assert Wakes.list_pending(ctx.db) == []
  end

  defp proof!(8, ctx, authority) do
    {:ok, _} = DB.query(ctx.db, "UPDATE sessions SET spawnedBy=NULL WHERE sessionKey='holder'")
    insert_entitlement!(ctx.db, "asg_1", generation: 1, due_at: 0)
    consume = real_consumer_fixture!(ctx)

    first = terminal!(ctx.db, "holder")

    assert {:escalated, 1, main} =
             Supervision.evaluate(ctx.db, ctx.handlers, 0, "holder", first)

    assert main == ctx.main.session_key
    assert :duplicate = Supervision.evaluate(ctx.db, ctx.handlers, 0, "holder", first)
    assert length(Wakes.list_pending(ctx.db)) == 1

    fire_all_pending(ctx.db, consume)
    insert_entitlement!(ctx.db, "asg_1", generation: 2, due_at: 0)
    second = terminal!(ctx.db, "holder")

    assert {:escalated, 2, ^main} =
             Supervision.evaluate(ctx.db, ctx.handlers, 0, "holder", second)

    assert length(Wakes.list_pending(ctx.db)) == 1
  end

  defp real_consumer_fixture!(ctx, opts \\ []) do
    alias Tightbeam.GatewayTurnFixture.{AdapterStub, CoordinatorStub}

    unless Process.whereis(Tightbeam.LaneRegistry),
      do: start_supervised!({Registry, keys: :unique, name: Tightbeam.LaneRegistry})

    unless Process.whereis(Tightbeam.ConnRegistry),
      do:
        start_supervised!(
          Supervisor.child_spec({ConnRegistry, name: Tightbeam.ConnRegistry},
            id: :r1_consumer_registry
          )
        )

    task_sup = start_supervised!({Task.Supervisor, []})

    {:ok, responder} =
      Task.Supervisor.start_child(task_sup, fn ->
        loop = fn loop ->
          receive do
            {:prompt_started, adapter} ->
              send(adapter, :continue_prompt)
              loop.(loop)

            _ ->
              loop.(loop)
          end
        end

        loop.(loop)
      end)

    assert {:ok, _} =
             DB.query(ctx.db, "UPDATE sessions SET host=?1", [
               Tightbeam.Placement.local_host_name()
             ])

    adapter = start_supervised!({AdapterStub, {:unique_sessions, responder}})
    start_supervised!({CoordinatorStub, adapter})

    config = %{
      base_dir: ctx.base,
      cwd: ctx.base,
      port: 0,
      db: ctx.db,
      default_harness: :claude,
      default_model: Model.new("claude-fable-5"),
      max_live_sessions_per_user: 50,
      wake_tick_ms: 60_000,
      onboarding_lease_ms: 1_800_000
    }

    {Tightbeam.LaneManager, options} =
      Enum.find(Gateway.children(config), &match?({Tightbeam.LaneManager, _}, &1))

    runner = Keyword.fetch!(options, :runner)

    fn key ->
      assert {:ok, [[seq, wake_id, assignment_id]]} =
               DB.query(
                 ctx.db,
                 "SELECT seq,wakeId,assignmentId FROM turns WHERE sessionKey=?1 AND status='queued' ORDER BY seq",
                 [key]
               )

      receiver = self()

      {:ok, lane} =
        Tightbeam.SessionLane.start_link(
          session_key: key,
          db: ctx.db,
          task_sup: task_sup,
          runner: runner,
          on_terminal: fn _key, terminal_seq ->
            send(receiver, {:consumer_terminal, terminal_seq})
          end
        )

      try do
        assert_receive {:consumer_terminal, ^seq}, 60_000

        assert {:ok, [["delivered"]]} =
                 DB.query(ctx.db, "SELECT status FROM turns WHERE seq=?1", [seq])

        assert {:ok, [[encoded]]} =
                 DB.query(ctx.db, "SELECT reminderState FROM assignments WHERE id=?1", [
                   assignment_id
                 ])

        state = JSON.decode!(encoded)
        assert state["pending"] == nil
        expected_consumer = if is_nil(wake_id), do: %{"turn" => seq}, else: %{"wake" => wake_id}
        assert state["lastConsumer"] == expected_consumer

        assert (state["nextEligibleAt"] - state["lastDeliveredAt"]) in [
                 300_000,
                 900_000,
                 1_800_000
               ]

        # Explicit ladder-test clock setup, only AFTER actual successful terminal
        # delivery and its selected gap are proved. Do not fabricate success.
        if Keyword.get(opts, :expire_gap, true) do
          assert {:ok, _} =
                   DB.query(ctx.db, "UPDATE assignments SET reminderState=?2 WHERE id=?1", [
                     assignment_id,
                     JSON.encode!(Map.put(state, "nextEligibleAt", 0))
                   ])
        end

        %{seq: seq, wake_id: wake_id}
      after
        if Process.alive?(lane), do: GenServer.stop(lane)
      end
    end
  end

  # Model a committed terminal row before its downstream reconciliation. Keep the
  # real audit and generation constraints; using the full revoke handler here
  # would consume the callback race that these three tests exercise.
  defp persist_terminal_race!(db, assignment_id, at) do
    revocation_id = "rev_race_#{System.unique_integer([:positive])}"

    assert {:ok, :ok} =
             DB.transaction(db, fn txn ->
               DB.Txn.q(
                 txn,
                 """
                 INSERT INTO assignment_revocations
                   (id, assignmentId, revokedAt, revokedByUser, reason)
                 VALUES (?1, ?2, ?3, 'flynn', 'synthetic terminal race')
                 """,
                 [revocation_id, assignment_id, at]
               )

               DB.Txn.q(
                 txn,
                 """
                 INSERT INTO assignment_revocation_generations
                   (revocationId, assignmentId, reopeningId)
                 VALUES (?1, ?2, NULL)
                 """,
                 [revocation_id, assignment_id]
               )

               DB.Txn.q(
                 txn,
                 """
                 UPDATE assignments SET state='closed', outcome='revoked',
                   closedAt=?2, closedByUser='flynn'
                 WHERE id=?1 AND state='open'
                 """,
                 [assignment_id, at]
               )

               assert DB.Txn.changes(txn) == 1
               :ok
             end)

    :ok
  end

  defp cancel_wake!(db, wake) do
    {requester, principal, session_key} = cancellation_requester(wake.origin)

    assert {:ok, {:accepted_in_txn, event_id, %{canceled: true}}} =
             DB.transaction(db, fn txn ->
               trigger = ensure_cancellation_trigger_in_txn(txn, wake)

               outcome =
                 case trigger do
                   {:ok, liveness_trigger} ->
                     %{kind: "no_replacement", liveness_trigger: liveness_trigger}

                   :none ->
                     %{kind: "no_replacement"}
                 end

               Wakes.cancel_in_txn(txn, %{
                 wake_id: wake.wake_id,
                 expected_origin: wake.origin,
                 requester: requester,
                 reason_kind: "requester_withdrew",
                 causal_source: %{
                   kind: "verb_call",
                   accepted_event: %{
                     origin: wake.origin,
                     session_key: session_key,
                     principal: principal
                   }
                 },
                 outcome: outcome
               })
             end)

    assert event_id > 0

    :ok
  end

  defp ensure_cancellation_trigger_in_txn(txn, %{assignment_id: assignment_id})
       when is_binary(assignment_id) do
    case DB.Txn.q(
           txn,
           """
           SELECT a.state, a.openedAt, e.assignmentId
           FROM assignments a
           LEFT JOIN supervision_entitlements e ON e.assignmentId=a.id
           WHERE a.id=?1
           """,
           [assignment_id]
         ) do
      [["open", opened_at, nil]] ->
        Supervision.transition_in_txn(txn, %{
          kind: "assignment_open",
          assignment_id: assignment_id,
          opened_at: opened_at,
          supervision_interval_ms: 60_000,
          principal: "process:tightbeam"
        })

      _ ->
        :ok
    end

    Supervision.liveness_trigger_in_txn(txn, {:assignment, assignment_id})
  end

  defp ensure_cancellation_trigger_in_txn(txn, %{work_item_id: work_item_id})
       when is_binary(work_item_id) do
    Supervision.liveness_trigger_in_txn(txn, {:work_item, work_item_id})
  end

  defp ensure_cancellation_trigger_in_txn(_txn, _wake), do: :none

  defp cancellation_requester("user:" <> id), do: {%{kind: "user", id: id}, {:user, id}, nil}

  defp cancellation_requester("session:" <> id),
    do: {%{kind: "session", id: id}, {:session, id}, id}

  defp cancellation_requester("process:" <> id),
    do: {%{kind: "process", id: id}, {:process, id}, nil}

  defp start_liveness!(ctx, opts) do
    name = Keyword.get(opts, :name, :immutable_liveness_supervision)

    start_supervised!(
      {Supervision,
       db: ctx.db,
       handlers: ctx.handlers,
       prod_limit: Keyword.get(opts, :prod_limit, 2),
       sweep_ms: Keyword.fetch!(opts, :sweep_ms),
       name: name}
    )

    :sys.get_state(name)
    name
  end

  defp sweep_liveness!(name) do
    Supervision.request_sweep(name)
    :sys.get_state(name)
    :ok
  end

  defp insert_entitlement!(db, assignment_id, opts) do
    generation = Keyword.fetch!(opts, :generation)
    due_at = Keyword.fetch!(opts, :due_at)
    interval = Keyword.get(opts, :interval, 60_000)
    basis_kind = Keyword.get(opts, :basis_kind, "assignment_open")
    basis_id = Keyword.get(opts, :basis_id, assignment_id)
    cause = Keyword.get(opts, :cause, "assignment_open")

    {:ok, _} =
      DB.query(
        db,
        """
        INSERT INTO supervision_entitlements
          (assignmentId, generation, dueAt, state, lastAttemptGeneration, claimClock,
           basisKind, basisId, terminusAt, cause, principal, supervisionIntervalMs)
        VALUES (?1, ?2, ?3, 'armed', NULL, NULL, ?4, ?5, NULL, ?6,
                'process:tightbeam', ?7)
        """,
        [assignment_id, generation, due_at, basis_kind, basis_id, cause, interval]
      )

    {:ok, _} =
      DB.query(
        db,
        """
        INSERT OR IGNORE INTO supervision_liveness_receipt_state
          (assignmentId, artifactCursor, attestCursor, workItemEventCursor, wakeCursor,
           baselineCause, baselinePrincipal)
        VALUES (?1,
                (SELECT COALESCE(MAX(rowid), 0) FROM artifacts),
                (SELECT COALESCE(MAX(rowid), 0) FROM attests),
                (SELECT COALESCE(MAX(id), 0) FROM work_item_events),
                (SELECT COALESCE(MAX(rowid), 0) FROM wakes),
                'assignment_open', 'process:tightbeam')
        """,
        [assignment_id]
      )

    :ok
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

  defp schedule_checkpoint_via_gateway!(ctx, prompt, after_ms) do
    message_id = "checkpoint-turn-#{System.unique_integer([:positive])}"

    assert {:ok, seq} =
             Ledger.enqueue(ctx.db, %{
               session_key: "holder",
               message_id: message_id,
               origin: "user:flynn",
               prompt: "checkpoint source turn",
               assignment_id: "asg_1",
               job_ref: "wi_checkpoint"
             })

    assert {:ok, %{seq: ^seq}} = Ledger.claim_next(ctx.db, "holder", "checkpoint-writer")

    assert %{wake_id: wake_id, state: "pending"} =
             ctx.handlers["wake"].(%{
               origin: "user:flynn",
               principal: {:session, "holder"},
               session_key: "holder",
               params: %{
                 prompt: prompt,
                 after_ms: after_ms,
                 nudge: false
               }
             })

    wake = Wakes.get(ctx.db, wake_id)
    assert wake.assignment_id == nil
    assert wake.creator_session_key == "holder"

    assert {:ok, [["asg_1", "holder", ^seq, "process:tightbeam"]]} =
             DB.query(
               ctx.db,
               "SELECT assignmentId,holderSessionKey,sourceTurnSeq,principal FROM supervision_liveness_checkpoint_bindings WHERE wakeId=?1",
               [wake_id]
             )

    assert :ok = Ledger.finish(ctx.db, seq, "delivered")
    {wake, seq}
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
    :ok = Tightbeam.Schema.ensure_all(ctx.db)

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

  # Agent origin on purpose: work-blocked is an agent-only kind, and
  # ConditionFacts refuses it from process:tightbeam — the substrate never
  # decides a session is blocked (spec production-machine-v1 §Standing facts).
  defp file_fact(db, kind, scope) do
    {:ok, %{fact_id: _}} =
      DB.transaction(
        db,
        &ConditionFacts.file_in_txn(&1, %{kind: kind, scope: scope, origin: "session:supervisor"})
      )

    :ok
  end

  defp open_rate_limit_incident!(ctx) do
    first = %{
      harness: "claude",
      host: "eezo",
      failure_class: "rate-limit-dead",
      evidence_kind: "terminal-failure",
      session_key: ctx.holder.session_key,
      assignment_id: "asg_1",
      observed_at: 100,
      correlation_id: "supervision-rate-limit-holder",
      cause: "terminal recovery-chain failure",
      principal: "process:tightbeam"
    }

    second = %{
      first
      | session_key: ctx.supervisor.session_key,
        assignment_id: nil,
        observed_at: 101,
        correlation_id: "supervision-rate-limit-supervisor"
    }

    assert {:pending, _} = HarnessHealth.observe(ctx.db, first)
    assert {:opened, _} = HarnessHealth.observe(ctx.db, second)
    :ok
  end

  defp resolve_rate_limit_incident!(ctx, terminal_seq) do
    :ok = HarnessProcess.complete_park(ctx.db, {:claude, "shared", "eezo"})

    assert {:resolved, _} =
             HarnessHealth.resolve(ctx.db, %{
               harness: "claude",
               host: "eezo",
               failure_class: "rate-limit-dead",
               session_key: ctx.holder.session_key,
               assignment_id: "asg_1",
               observed_at: 200,
               correlation_id: "supervision-normal-turn-#{terminal_seq}",
               cause: "normal turn delivered",
               principal: "process:tightbeam"
             })

    :ok
  end

  defp open_authoritative_harness_incident!(ctx, failure_class, index) do
    assert {:opened, _} =
             HarnessHealth.observe(ctx.db, %{
               harness: "claude",
               host: "eezo",
               failure_class: failure_class,
               evidence_kind: "authoritative-provider",
               session_key: ctx.holder.session_key,
               assignment_id: "asg_1",
               observed_at: 1_000 + index,
               correlation_id: "supervision-all-class-#{failure_class}-#{index}",
               cause: "typed harness failure #{failure_class}",
               principal: "process:tightbeam"
             })

    :ok
  end

  defp resolve_harness_incident!(ctx, failure_class, index) do
    if failure_class == "rate-limit-dead" do
      :ok = HarnessProcess.complete_park(ctx.db, {:claude, "shared", "eezo"})
    end

    assert {:resolved, _} =
             HarnessHealth.resolve(ctx.db, %{
               harness: "claude",
               host: "eezo",
               failure_class: failure_class,
               session_key: ctx.holder.session_key,
               assignment_id: "asg_1",
               observed_at: 2_000 + index,
               correlation_id: "supervision-all-class-resolved-#{failure_class}-#{index}",
               cause: "typed harness recovered #{failure_class}",
               principal: "process:tightbeam"
             })

    :ok
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

  defp attach_work_item!(db, assignment_id, work_item_id) do
    ensure_work_item!(db, work_item_id)

    {:ok, _} =
      DB.query(db, "UPDATE assignments SET workItemId=?2 WHERE id=?1", [
        assignment_id,
        work_item_id
      ])

    :ok
  end

  defp ensure_work_item!(db, work_item_id) do
    {:ok, _} =
      DB.query(
        db,
        """
        INSERT OR IGNORE INTO work_items
          (id,title,ownerUserId,state,createdByUser,createdAt)
        VALUES (?1,?1,'flynn','open','flynn',1)
        """,
        [work_item_id]
      )

    :ok
  end

  defp insert_artifact!(db, artifact_id, session_key, work_item_id, created_at) do
    ensure_work_item!(db, work_item_id)

    {:ok, _} =
      DB.query(
        db,
        """
        INSERT INTO artifacts
          (artifactId,kind,title,createdBySession,workItemId,originPath,
           recordedTurnEvidence,state,createdAt,updatedAt)
        VALUES (?1,'report',?1,?2,?3,?1,'none','in-workspace',?4,?4)
        """,
        [artifact_id, session_key, work_item_id, created_at]
      )

    :ok
  end

  defp retire!(db, session_key) do
    {:ok, retired} =
      DB.transaction(db, fn txn ->
        Assignments.interrupt_for_retire_in_txn(
          txn,
          session_key,
          "flynn",
          "user:flynn"
        )

        Org.retire_in_txn(txn, session_key, "user:flynn", 1_000)
      end)

    retired
  end

  defp session(db, key, spawned_by, built_in \\ false) do
    Org.create(db, %{
      session_key: key,
      display_name: key,
      owner_user_id: "flynn",
      origin: "user:flynn",
      spawned_by: spawned_by,
      kind: if(built_in, do: "main", else: "custom"),
      is_built_in: built_in,
      archetype: "default",
      harness: "claude",
      provider: "anthropic",
      model: Model.new("fable"),
      host: "eezo"
    })
  end

  defp fire_all_pending(db, consume \\ nil) do
    for wake <- Wakes.list_pending(db) do
      case DB.query(
             db,
             "SELECT 1 FROM supervision_liveness_sidecar WHERE wakeId=?1 AND controllerState='pending'",
             [wake.wake_id]
           ) do
        {:ok, [[1]]} ->
          assert :appended = admit_supervision_wake!(db, wake)

          if consume do
            consume.(wake.session_key)
          else
            assert {:ok, %{seq: seq}} = Ledger.claim_next(db, wake.session_key, "test-controller")
            assert :ok = Ledger.finish(db, seq, "delivered")
          end

        {:ok, []} ->
          {:ok, _} =
            DB.query(
              db,
              "UPDATE wakes SET state='fired', firedAt=?2 WHERE wakeId=?1 AND state='pending'",
              [wake.wake_id, System.system_time(:millisecond)]
            )
      end
    end

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

  defp admit_supervision_wake!(db, wake) do
    assert {:ok, delivery} =
             DB.transaction(db, fn txn ->
               Gateway.deliver_prompt_in_txn(
                 txn,
                 wake.session_key,
                 wake.origin,
                 wake.prompt,
                 wake_id: wake.wake_id,
                 sender: wake.origin,
                 target_gate: wake,
                 fire_wake_in_txn: true,
                 assignment_id: wake.assignment_id
               )
             end)

    case delivery do
      {:appended, _target, _message, _opts} -> :appended
      other -> other
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

  defp stop_supervised(id) do
    stop_supervised!(id)
  end
end
