defmodule Tightbeam.OAuthRecoveryWakeTest do
  use Tightbeam.TestCase, async: false

  alias Tightbeam.{ConnRegistry, CredentialRecovery, Credentials, DB, Devices, Gateway}
  alias Tightbeam.{Ledger, Model, Org, Wakes}

  @host "testhost"
  @owner "recovery-operator"
  @main Org.personal_session_key(@owner)

  defmodule NoopScheduler do
    use GenServer
    def start_link(name), do: GenServer.start_link(__MODULE__, nil, name: name)
    def init(nil), do: {:ok, nil}
    def handle_call(:fire_due, _from, state), do: {:reply, :ok, state}
    def handle_cast(:fire_due, state), do: {:noreply, state}
  end

  defmodule LaneProbe do
    use GenServer
    def start_link({name, parent}), do: GenServer.start_link(__MODULE__, parent, name: name)
    def init(parent), do: {:ok, parent}

    def handle_call({:ensure_lane, session_key}, _from, parent) do
      send(parent, {:lane_started, session_key})
      {:reply, :ok, parent}
    end
  end

  setup do
    previous_host = Application.get_env(:tightbeam, :local_host_name)
    Application.put_env(:tightbeam, :local_host_name, @host)

    base =
      Path.join(System.tmp_dir!(), "credential-recovery-#{System.unique_integer([:positive])}")

    db = :"credential_recovery_db_#{System.unique_integer([:positive])}"
    registry = :"credential_recovery_registry_#{System.unique_integer([:positive])}"
    lane = :"credential_recovery_lane_#{System.unique_integer([:positive])}"

    start_supervised!({DB, path: ":memory:", name: db})
    :ok = Tightbeam.Schema.ensure_all(db)
    register_hosts(db, [{@host, %{ssh: nil, base_dir: base, cli_bin: nil}}])
    start_supervised!({ConnRegistry, name: registry})
    start_supervised!({LaneProbe, {lane, self()}})

    assert %{user_id: @owner} = Devices.add_user(db, @owner, true)
    create_session(db, @main, @owner, "default")

    on_exit(fn ->
      File.rm_rf!(base)

      case previous_host do
        nil -> Application.delete_env(:tightbeam, :local_host_name)
        host -> Application.put_env(:tightbeam, :local_host_name, host)
      end
    end)

    %{base: base, db: db, registry: registry, lane: lane}
  end

  test "successful activation wakes every and only affected active session", ctx do
    assert %{user_id: "other-owner"} = Devices.add_user(ctx.db, "other-owner", false)
    create_session(ctx.db, "agent:product-a", @owner, "product-a")
    create_session(ctx.db, "agent:product-b", @owner, "product-b")
    create_session(ctx.db, Org.personal_session_key("other-owner"), "other-owner", "default")

    create_session(ctx.db, "agent:unrelated", "other-owner", "unrelated",
      harness: "codex",
      provider: "openai"
    )

    existing =
      DB.transaction(ctx.db, fn txn ->
        Wakes.schedule_in_txn(txn, %{
          session_key: @main,
          origin: "session:existing",
          prompt: "preserve me",
          due_at: System.system_time(:millisecond) + 86_400_000,
          sender_scheduled: true
        })
      end)

    assert {:ok, %{wake_id: existing_wake_id}} = existing

    start_credentials!(ctx)
    scheduler = start_real_scheduler!(ctx)
    response = finish_fresh(onboard_handler(ctx, scheduler), "subscription")

    assert %{
             code: "credential_recovery_in_progress",
             status: "onboarded",
             credential_recovered: true,
             adapters_ready: true,
             recovery: %{target_count: 4, activation_id: activation_id}
           } = response

    assert {:ok, [[4]]} =
             DB.query(
               ctx.db,
               "SELECT COUNT(*) FROM credential_recovery_memberships WHERE activationId=?1",
               [activation_id]
             )

    assert {:ok, sessions} =
             DB.query(
               ctx.db,
               "SELECT sessionKey FROM credential_recovery_memberships WHERE activationId=?1 ORDER BY sessionKey",
               [activation_id]
             )

    assert Enum.map(sessions, &hd/1) ==
             Enum.sort([
               @main,
               "agent:product-a",
               "agent:product-b",
               Org.personal_session_key("other-owner")
             ])

    assert {:ok, [[4]]} =
             DB.query(
               ctx.db,
               "SELECT COUNT(*) FROM turns WHERE wakeId IN (SELECT wakeId FROM credential_recovery_targets)"
             )

    assert %{state: "pending", prompt: "preserve me"} = Wakes.get(ctx.db, existing_wake_id)

    assert {:ok, [[0]]} =
             DB.query(
               ctx.db,
               "SELECT COUNT(*) FROM credential_recovery_memberships WHERE sessionKey='agent:unrelated'"
             )

    for session <- Enum.map(sessions, &hd/1), do: assert_received({:lane_started, ^session})
  end

  test "API-key activation uses the same per-session recovery mechanism", ctx do
    start_credentials!(ctx)
    response = finish_fresh(onboard_handler(ctx, start_noop_scheduler!()), "apiKey")

    assert %{
             code: "credential_recovery_in_progress",
             credential_kind: "apiKey",
             recovery: %{target_count: 1}
           } = response

    assert_wake_count(ctx.db, 1)

    assert {:ok, [[carrier_prompt, "pending"]]} =
             DB.query(
               ctx.db,
               "SELECT prompt,state FROM wakes WHERE consumer='prompt'"
             )

    assert carrier_prompt =~ "host #{@host}"
    assert carrier_prompt =~ "later activation can coalesce"
  end

  test "a later activation joins the existing target cycle without another carrier", ctx do
    start_credentials!(ctx)
    handler = onboard_handler(ctx, start_noop_scheduler!())

    first = finish_fresh(handler, "subscription")
    second = finish_fresh(handler, "subscription")

    assert first.recovery.activation_id != second.recovery.activation_id
    assert_wake_count(ctx.db, 1)

    assert {:ok, [[2, 2, 2, 0]]} =
             DB.query(
               ctx.db,
               "SELECT COUNT(*),MAX(generation),MAX(requiredGeneration),MIN(attempt) FROM credential_recovery_memberships JOIN credential_recovery_targets USING(targetId)"
             )
  end

  test "a prior-generation running turn is terminalized and cannot keep the carrier dark", ctx do
    start_credentials!(ctx)

    assert :appended =
             Gateway.deliver_prompt(@main, "session:test", "old work",
               db: ctx.db,
               conn_registry: ctx.registry,
               lane_manager: ctx.lane
             )

    assert {:ok, %{seq: old_seq}} = Ledger.claim_next(ctx.db, @main, "old-owner")

    response = finish_fresh(onboard_handler(ctx, start_real_scheduler!(ctx)), "subscription")
    activation_id = response.recovery.activation_id
    assert response.code == "credential_recovery_in_progress"

    assert {:ok, [["failed"]]} =
             DB.query(ctx.db, "SELECT status FROM turns WHERE seq=?1", [old_seq])

    assert {:ok, [["could_not_run", ^old_seq]]} =
             DB.query(
               ctx.db,
               "SELECT reconciliationState,reconciliationTurnSeq FROM credential_recovery_memberships WHERE activationId=?1",
               [activation_id]
             )

    assert {:ok, [["admitted", 1]]} =
             DB.query(
               ctx.db,
               "SELECT state,COUNT(*) FROM credential_recovery_targets JOIN turns ON turns.wakeId=credential_recovery_targets.wakeId WHERE turns.status='queued' GROUP BY state"
             )
  end

  test "reconciliation failure keeps attempt zero, schedules a bounded retry, then recovers",
       ctx do
    start_credentials!(ctx)

    assert :appended =
             Gateway.deliver_prompt(@main, "session:test", "old work",
               db: ctx.db,
               conn_registry: ctx.registry,
               lane_manager: ctx.lane
             )

    assert {:ok, %{seq: old_seq}} = Ledger.claim_next(ctx.db, @main, "old-owner")

    :ok =
      DB.execute(
        ctx.db,
        """
        CREATE TRIGGER force_reconciliation_failure
        BEFORE INSERT ON turn_lifecycle_events
        WHEN NEW.kind='terminal_committed'
        BEGIN
          SELECT RAISE(ABORT, 'forced reconciliation failure');
        END;
        """
      )

    scheduler = start_noop_scheduler!()
    response = finish_fresh(onboard_handler(ctx, scheduler), "subscription")
    activation_id = response.recovery.activation_id

    assert %{code: "credential_recovery_reconciliation_retrying", recovery: %{attempt: 1}} =
             response

    assert %{targets: [%{state: "retry_wait", attempt: 0, reconciliation_attempt: 1}]} =
             CredentialRecovery.readback(ctx.db, activation_id)

    assert_wake_count(ctx.db, 2)
    :ok = DB.execute(ctx.db, "DROP TRIGGER force_reconciliation_failure")

    assert {:ok, [[target_id, retry_wake_id]]} =
             DB.query(
               ctx.db,
               "SELECT credential_recovery_targets.targetId,wakes.wakeId FROM credential_recovery_targets JOIN wakes ON wakes.prompt=credential_recovery_targets.targetId WHERE wakes.consumer='credential_recovery_retry'"
             )

    assert {:ok, []} =
             DB.query(
               ctx.db,
               "UPDATE credential_recovery_targets SET dueAt=0 WHERE targetId=?1",
               [
                 target_id
               ]
             )

    assert {:ok, :ok} =
             CredentialRecovery.retry_due(ctx.db, %{
               condition_scope: target_id,
               prompt: target_id,
               wake_id: retry_wake_id
             })

    assert {:ok, [["failed"]]} =
             DB.query(ctx.db, "SELECT status FROM turns WHERE seq=?1", [old_seq])

    assert %{targets: [%{state: "pending", attempt: 0, reconciliation: "could_not_run"}]} =
             CredentialRecovery.readback(ctx.db, activation_id)
  end

  test "carrier terminal covers joined generations and completes both activations", ctx do
    start_credentials!(ctx)
    handler = onboard_handler(ctx, start_real_scheduler!(ctx))
    first = finish_fresh(handler, "subscription")
    second = finish_fresh(handler, "subscription")

    assert {:ok, %{seq: seq, owner_lease: owner_lease}} =
             Ledger.claim_next(ctx.db, @main, "carrier-owner")

    assert :ok = Ledger.finish(ctx.db, seq, "delivered", nil, owner_lease: owner_lease)
    assert {:ok, %{state: "handled"}} = CredentialRecovery.turn_terminal(ctx.db, seq)

    for activation_id <- [first.recovery.activation_id, second.recovery.activation_id] do
      assert %{state: "complete", targets: [%{resolution: "handled"}]} =
               CredentialRecovery.readback(ctx.db, activation_id)
    end
  end

  test "could-not-run carriers retry three times and then surface undeliverable", ctx do
    start_credentials!(ctx)
    scheduler = start_real_scheduler!(ctx)
    response = finish_fresh(onboard_handler(ctx, scheduler), "subscription")
    activation_id = response.recovery.activation_id

    Enum.each(0..3, fn attempt ->
      assert {:ok, %{seq: seq, owner_lease: owner_lease}} =
               Ledger.claim_next(ctx.db, @main, "carrier-owner-#{attempt}")

      assert :ok =
               Ledger.finish(ctx.db, seq, "failed", "pre-inference refusal",
                 owner_lease: owner_lease
               )

      assert {:ok, settled} = CredentialRecovery.turn_terminal(ctx.db, seq)

      if attempt < 3 do
        assert settled.state == "retry_wait"

        assert {:ok, [[target_id, timer_wake_id]]} =
                 DB.query(
                   ctx.db,
                   "SELECT credential_recovery_targets.targetId,wakes.wakeId FROM wakes JOIN credential_recovery_targets ON wakes.prompt=credential_recovery_targets.targetId WHERE wakes.consumer='credential_recovery_retry' AND wakes.state='pending' ORDER BY wakes.createdAt DESC LIMIT 1"
                 )

        assert {:ok, []} =
                 DB.query(
                   ctx.db,
                   "UPDATE credential_recovery_targets SET dueAt=0 WHERE targetId=?1",
                   [target_id]
                 )

        assert {:ok, :ok} =
                 CredentialRecovery.retry_due(ctx.db, %{
                   condition_scope: target_id,
                   prompt: target_id,
                   wake_id: timer_wake_id
                 })

        assert :ok = Wakes.fire_due(scheduler)
      else
        assert settled.state == "undeliverable"
      end
    end)

    assert %{state: "complete", targets: [%{resolution: "undeliverable", attempt: 3}]} =
             CredentialRecovery.readback(ctx.db, activation_id)
  end

  test "boot replay terminalizes an interrupted claimed carrier without rerunning inference",
       ctx do
    start_credentials!(ctx)
    response = finish_fresh(onboard_handler(ctx, start_real_scheduler!(ctx)), "subscription")
    activation_id = response.recovery.activation_id

    assert {:ok, %{seq: seq}} = Ledger.claim_next(ctx.db, @main, "crashed-carrier-owner")
    assert :ok = CredentialRecovery.recover(ctx.db)

    assert {:ok, [["failed_unknown"]]} =
             DB.query(ctx.db, "SELECT status FROM turns WHERE seq=?1", [seq])

    assert %{state: "complete", targets: [%{resolution: "undeliverable", state: "undeliverable"}]} =
             CredentialRecovery.readback(ctx.db, activation_id)
  end

  test "retirement before delivery durably dispositions the exact target", ctx do
    start_credentials!(ctx)
    noop = start_noop_scheduler!()
    response = finish_fresh(onboard_handler(ctx, noop), "subscription")
    activation_id = response.recovery.activation_id

    assert %{state: "retired"} = Org.retire(ctx.db, @main, "user:#{@owner}", 1_000)
    assert {:ok, :ok} = CredentialRecovery.session_retired(ctx.db, @main)
    scheduler = start_real_scheduler!(ctx)
    assert :ok = Wakes.fire_due(scheduler)

    assert %{state: "complete", targets: [%{resolution: "retired", state: "retired"}]} =
             CredentialRecovery.readback(ctx.db, activation_id)

    assert {:ok, [[0]]} =
             DB.query(
               ctx.db,
               "SELECT COUNT(*) FROM turns WHERE wakeId IN (SELECT wakeId FROM credential_recovery_targets)"
             )
  end

  test "scope change before admission dispositions the target without inference", ctx do
    start_credentials!(ctx)
    response = finish_fresh(onboard_handler(ctx, start_noop_scheduler!()), "subscription")
    activation_id = response.recovery.activation_id

    assert {:ok, []} =
             DB.query(
               ctx.db,
               "UPDATE sessions SET harness='codex',provider='openai' WHERE sessionKey=?1",
               [@main]
             )

    assert {:ok, [["codex", "openai"]]} =
             DB.query(ctx.db, "SELECT harness,provider FROM sessions WHERE sessionKey=?1", [@main])

    assert {:ok, [[wake_id]]} =
             DB.query(ctx.db, "SELECT wakeId FROM credential_recovery_targets")

    wake = Wakes.get(ctx.db, wake_id)
    assert %{state: "pending"} = wake

    assert :skipped =
             Gateway.deliver_prompt(wake.session_key, wake.origin, wake.prompt,
               db: ctx.db,
               wake_id: wake.wake_id,
               sender: wake.origin,
               target_gate: wake,
               fire_wake_in_txn: true,
               conn_registry: ctx.registry,
               lane_manager: ctx.lane
             )

    assert %{state: "canceled"} = Wakes.get(ctx.db, wake_id)

    assert %{state: "complete", targets: [%{resolution: "no_longer_affected"}]} =
             CredentialRecovery.readback(ctx.db, activation_id)

    assert {:ok, [[0]]} = DB.query(ctx.db, "SELECT COUNT(*) FROM turns")
  end

  test "failed activation edges create no recovery obligation", ctx do
    parent = self()

    start_credentials!(ctx,
      start: fn :anthropic, :subscription ->
        send(parent, :start_attempted)
        {:error, :forced_start_failure}
      end
    )

    response = finish_fresh(onboard_handler(ctx, start_noop_scheduler!()), "subscription")

    assert %{code: "credential_activation_failed", credential_recovered: false} = response
    assert response.message =~ "forced_start_failure"
    assert_received :start_attempted
    assert_wake_count(ctx.db, 0)

    assert {:ok, [["failed"]]} =
             DB.query(ctx.db, "SELECT state FROM credential_recovery_activations")

    assert {:ok, [[0]]} = DB.query(ctx.db, "SELECT COUNT(*) FROM credential_recovery_memberships")
  end

  test "target-plan failure returns typed credential success without hiding the durable failure",
       ctx do
    start_credentials!(ctx)
    handler = onboard_handler(ctx, start_noop_scheduler!())
    %{lease_id: lease_id} = begin_and_stage!(handler, "subscription")

    :ok =
      DB.execute(
        ctx.db,
        """
        CREATE TRIGGER force_recovery_carrier_failure
        BEFORE INSERT ON wakes
        BEGIN
          SELECT RAISE(ABORT, 'forced recovery carrier failure');
        END;
        """
      )

    assert %{
             code: "credential_recovered_recovery_plan_failed",
             credential_recovered: true,
             adapters_ready: true,
             recovery_started: false,
             message: message
           } = finish(handler, lease_id, "subscription")

    assert message =~ "forced recovery carrier failure"
    assert Credentials.status(:anthropic, Credentials.server(@host)) == :onboarded
    assert_wake_count(ctx.db, 0)

    assert {:ok, [["activation_ready"]]} =
             DB.query(ctx.db, "SELECT state FROM credential_recovery_activations")

    :ok = DB.execute(ctx.db, "DROP TRIGGER force_recovery_carrier_failure")
    assert :ok = CredentialRecovery.recover(ctx.db)
    assert_wake_count(ctx.db, 1)

    assert {:ok, [["recovering"]]} =
             DB.query(ctx.db, "SELECT state FROM credential_recovery_activations")
  end

  test "target and admin can read recovery while an unrelated session is denied", ctx do
    assert %{user_id: "other-owner"} = Devices.add_user(ctx.db, "other-owner", false)
    create_session(ctx.db, Org.personal_session_key("other-owner"), "other-owner", "default")

    create_session(ctx.db, "agent:unrelated", "other-owner", "unrelated",
      harness: "codex",
      provider: "openai"
    )

    start_credentials!(ctx)
    response = finish_fresh(onboard_handler(ctx, start_noop_scheduler!()), "subscription")
    activation_id = response.recovery.activation_id
    handler = Gateway.handlers(%{base_dir: ctx.base, db: ctx.db})["credential-recovery"]

    assert %{recovery: %{activation_id: ^activation_id}} =
             handler.(call(%{activation_id: activation_id}, {:session, @main}, @main))

    assert %{recovery: %{activation_id: ^activation_id}} =
             handler.(call(%{activation_id: activation_id}, {:user, @owner}, @main))

    assert %{code: "forbidden"} =
             handler.(
               call(
                 %{activation_id: activation_id},
                 {:session, "agent:unrelated"},
                 "agent:unrelated"
               )
             )
  end

  defp start_credentials!(ctx, opts \\ []) do
    start_supervised!(
      {Credentials,
       Keyword.merge(
         [
           name: Credentials.server(@host),
           base_dir: ctx.base,
           machine: @host,
           start: fn _provider, _kind -> {:ok, %{"claude" => 2}} end,
           on_credential_present: fn _provider -> :ok end,
           resume: fn _provider -> :ok end
         ],
         opts
       )}
    )
  end

  defp start_noop_scheduler! do
    name = :"credential_recovery_noop_#{System.unique_integer([:positive])}"
    start_supervised!(%{id: name, start: {NoopScheduler, :start_link, [name]}})
    name
  end

  defp start_real_scheduler!(ctx) do
    name = :"credential_recovery_scheduler_#{System.unique_integer([:positive])}"

    deliver = fn wake ->
      Gateway.deliver_prompt(wake.session_key, wake.origin, wake.prompt,
        db: ctx.db,
        wake_id: wake.wake_id,
        sender: wake.origin,
        target_gate: wake,
        fire_wake_in_txn: true,
        conn_registry: ctx.registry,
        lane_manager: ctx.lane
      )
    end

    start_supervised!(%{
      id: name,
      start:
        {Wakes, :start_link,
         [
           [
             name: name,
             db: ctx.db,
             deliver: deliver,
             internal_consumers: %{
               "credential_recovery_retry" => &CredentialRecovery.retry_due(ctx.db, &1)
             },
             tick_ms: 86_400_000
           ]
         ]}
    })

    name
  end

  defp onboard_handler(ctx, scheduler) do
    Gateway.handlers(%{
      base_dir: ctx.base,
      db: ctx.db,
      onboarding_lease_ms: 1_800_000,
      wake_scheduler: scheduler
    })["onboard"]
  end

  defp finish_fresh(handler, kind) do
    %{lease_id: lease_id} = begin_and_stage!(handler, kind)
    finish(handler, lease_id, kind)
  end

  defp begin_and_stage!(handler, kind) do
    assert %{status: "ready", staging_path: staging, lease_id: lease_id} =
             handler.(call(%{phase: "begin", kind: kind}))

    bytes =
      if kind == "subscription" do
        ~s({"claudeAiOauth":{"accessToken":"fixture-oauth-token"}})
      else
        "sk-ant-api03-fixture"
      end

    File.write!(Path.join(staging, ".credentials.json"), bytes)
    %{lease_id: lease_id, staging: staging}
  end

  defp finish(handler, lease_id, kind),
    do: handler.(call(%{phase: "finish", kind: kind, lease_id: lease_id}))

  defp call(params, principal \\ {:user, @owner}, session_key \\ @main) do
    %{
      origin: principal_origin(principal),
      principal: principal,
      session_key: session_key,
      params: Map.put_new(params, :provider, "anthropic")
    }
  end

  defp principal_origin({:user, id}), do: "user:#{id}"
  defp principal_origin({:session, id}), do: "session:#{id}"

  defp create_session(db, session_key, owner, archetype, opts \\ []) do
    harness = Keyword.get(opts, :harness, "claude")

    Org.create(db, %{
      session_key: session_key,
      display_name: session_key,
      owner_user_id: owner,
      origin: "user:#{owner}",
      archetype: archetype,
      host: Keyword.get(opts, :host, @host),
      harness: harness,
      provider:
        Keyword.get(opts, :provider, if(harness == "claude", do: "anthropic", else: "openai")),
      model: Model.new(if(harness == "claude", do: "fable", else: "sol"))
    })
  end

  defp assert_wake_count(db, expected) do
    assert {:ok, [[^expected]]} = DB.query(db, "SELECT COUNT(*) FROM wakes")
  end
end
