defmodule Tightbeam.CredentialPresentWaitTest do
  # A sign-in must succeed even when something is waiting on its
  # credential-present fact: the hook files the fact after the credential is
  # already committed, so no delivery problem may raise into finish_onboard.
  use Tightbeam.TestCase, async: false

  alias Tightbeam.{ConnRegistry, Credentials, DB, Gateway, Model, Org, Rules, Wakes}

  @host "lab1"

  defmodule LaneDoorbell do
    use GenServer

    def start_link(parent),
      do: GenServer.start_link(__MODULE__, parent, name: Tightbeam.LaneManager)

    def init(parent), do: {:ok, parent}

    def handle_call({:ensure_lane, _session_key}, _from, parent), do: {:reply, :ok, parent}
  end

  setup do
    db = :"credential_wait_db_#{System.unique_integer([:positive])}"
    start_supervised!({DB, path: ":memory:", name: db})
    :ok = Tightbeam.Schema.ensure_all(db)

    {:ok, _} =
      DB.query(db, "INSERT INTO users (userId, isAdmin, createdAt) VALUES ('flynn', 0, 1)")

    Rules.load!(
      Path.join(System.tmp_dir!(), "credential-wait-rules-#{System.unique_integer([:positive])}"),
      []
    )

    session =
      Org.create(db, %{
        session_key: "agent:waiter:app",
        display_name: "Waiter",
        owner_user_id: "flynn",
        origin: "user:flynn",
        archetype: "default",
        host: "testhost",
        harness: "claude",
        provider: "anthropic",
        model: Model.new("fable")
      })

    start_supervised!({ConnRegistry, name: Tightbeam.ConnRegistry})
    start_supervised!({LaneDoorbell, self()})

    # The hook nudges the registered scheduler, as production does.
    scheduler = Tightbeam.WakeScheduler

    deliver = fn wake ->
      Gateway.deliver_prompt(wake.session_key, wake.origin, wake.prompt,
        db: db,
        wake_id: wake.wake_id,
        sender: wake.origin,
        target_gate: if(wake.target_gate == 0, do: nil, else: wake),
        fire_wake_in_txn: wake.origin == "process:tightbeam",
        conn_registry: ConnRegistry,
        lane_manager: Tightbeam.LaneManager,
        wake_scheduler: scheduler
      )
    end

    start_supervised!(
      {Wakes, db: db, name: scheduler, tick_ms: 60_000, batch: 2, deliver: deliver}
    )

    base = Path.join(System.tmp_dir!(), "tb-credwait-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(base) end)

    %{db: db, session: session, base: base}
  end

  defp wait_on_credential(ctx, provider \\ "openai") do
    Wakes.schedule(ctx.db, %{
      session_key: ctx.session.session_key,
      origin: "agent:owner",
      prompt: "signed in",
      due_at: System.system_time(:millisecond) + 60_000,
      condition_kind: "credential-present",
      condition_scope: "#{@host}:#{provider}",
      creator_session_key: "agent:owner:app"
    })
  end

  defp catalog_spy do
    owner = self()

    spawn_link(fn ->
      receive_loop = fn loop ->
        receive do
          {:"$gen_cast", {:credential_transition, host, provider, fact_id}} ->
            send(owner, {:rederived, host, provider, fact_id})
        end

        loop.(loop)
      end

      receive_loop.(receive_loop)
    end)
  end

  defp delivery_turn_count(db, wake_id) do
    {:ok, [[count]]} =
      DB.query(
        db,
        """
        SELECT COUNT(*) FROM turns t
        WHERE t.wakeId=?1 OR t.wakeId IN (
          SELECT b.deliveryWakeId
          FROM notice_batch_members m
          JOIN notice_batches b ON b.batchId=m.batchId
          WHERE m.sourceWakeId=?1 AND b.deliveryWakeId IS NOT NULL
        )
        """,
        [wake_id]
      )

    count
  end

  test "the hook with a pending matching wait returns, delivers it once and re-derives", ctx do
    wake = wait_on_credential(ctx)
    hook = Gateway.credential_present_hook(ctx.db, @host, catalog_spy())

    assert hook.(:openai) == :ok
    assert_receive {:rederived, @host, :openai, fact_id}
    assert is_integer(fact_id)

    assert :ok = Wakes.fire_due(Tightbeam.WakeScheduler)
    assert Wakes.get(ctx.db, wake.wake_id).state == "fired"
    assert delivery_turn_count(ctx.db, wake.wake_id) == 1
  end

  test "an absent scheduler never raises into the sign-in and the catalog is still re-derived",
       ctx do
    wait_on_credential(ctx)
    # No scheduler is running: the hook
    # still answers :ok and the catalog is still poked.
    stop_supervised!(Wakes)
    hook = Gateway.credential_present_hook(ctx.db, @host, catalog_spy())

    assert hook.(:openai) == :ok
    assert_receive {:rederived, @host, :openai, _fact_id}
  end

  test "finish_onboard succeeds with a pending wait, and another provider's begin is unaffected",
       ctx do
    wake = wait_on_credential(ctx)
    spy = catalog_spy()

    {:ok, server} =
      Credentials.start_link(
        name: nil,
        base_dir: ctx.base,
        machine: @host,
        start: fn :openai, :subscription -> :ok end,
        on_credential_present: Gateway.credential_present_hook(ctx.db, @host, spy),
        capture_sessions: fn :openai -> [] end,
        resume: fn :openai -> :ok end,
        publish_sessions: fn _, _ -> :ok end
      )

    assert {:ok, staging, lease_id} = Credentials.begin_onboard(:openai, server)
    File.write!(Path.join(staging, "auth.json"), ~S({"token":"candidate"}))

    assert :ok = Credentials.finish_onboard(:openai, :subscription, lease_id, server)
    assert_receive {:rederived, @host, :openai, _fact_id}

    assert :ok = Wakes.fire_due(Tightbeam.WakeScheduler)
    assert delivery_turn_count(ctx.db, wake.wake_id) == 1

    assert {:ok, _staging, _lease} = Credentials.begin_onboard(:anthropic, server)
    assert Process.alive?(server)
  end

  test "an API-key finish_onboard succeeds with a pending wait", ctx do
    wake = wait_on_credential(ctx, "anthropic")

    {:ok, server} =
      Credentials.start_link(
        name: nil,
        base_dir: ctx.base,
        machine: @host,
        sh: fn _argv -> {"", 0} end,
        start: fn :anthropic, _kind -> :ok end,
        on_credential_present: Gateway.credential_present_hook(ctx.db, @host, catalog_spy()),
        capture_sessions: fn :anthropic -> [] end,
        resume: fn :anthropic -> :ok end,
        publish_sessions: fn _, _ -> :ok end
      )

    assert {:ok, staging, lease_id} = Credentials.begin_onboard(:anthropic, server)
    File.write!(Path.join(staging, ".credentials.json"), "sk-ant-api03-staged")

    assert :ok = Credentials.finish_onboard(:anthropic, :api_key, lease_id, server)
    assert_receive {:rederived, @host, :anthropic, _fact_id}
    assert :ok = Wakes.fire_due(Tightbeam.WakeScheduler)
    assert delivery_turn_count(ctx.db, wake.wake_id) == 1
  end

  test "the direct onboard path succeeds with a pending wait", ctx do
    wake = wait_on_credential(ctx)

    {:ok, server} =
      Credentials.start_link(
        name: nil,
        base_dir: ctx.base,
        machine: @host,
        sh: fn _argv -> {"", 0} end,
        onboarders: %{
          openai: fn _state -> {:ok, %{bytes: ~S({"token":"new"}), expires_at: nil}} end
        },
        gate: fn _ -> :ok end,
        stop: fn _ -> :ok end,
        start: fn _, _ -> :ok end,
        on_credential_present: Gateway.credential_present_hook(ctx.db, @host, catalog_spy()),
        capture_sessions: fn _ -> [] end,
        resume: fn _ -> :ok end,
        publish_sessions: fn _, _ -> :ok end
      )

    assert :ok = Credentials.onboard(:openai, server)
    assert_receive {:rederived, @host, :openai, _fact_id}
    assert :ok = Wakes.fire_due(Tightbeam.WakeScheduler)
    assert delivery_turn_count(ctx.db, wake.wake_id) == 1
  end
end
