defmodule Tightbeam.OAuthRecoveryWakeTest do
  use Tightbeam.TestCase, async: false

  alias Tightbeam.{ConnRegistry, Credentials, DB, Devices, Gateway, Model, Org, Projection, Wakes}

  @host "testhost"
  @owner "oauth-operator"
  @main Org.personal_session_key(@owner)
  @prompt "The OAuth token for anthropic on testhost was refreshed. " <>
            "Read the manifests for every installed or learned Kung Fu. " <>
            "Read each manifest's declared main archetype. " <>
            "Find live agents with those archetypes. " <>
            "Notify each that the OAuth token was refreshed, and require each to inspect and " <>
            "resume any stalled agent graph."

  defmodule NoopScheduler do
    use GenServer

    def start_link(name), do: GenServer.start_link(__MODULE__, nil, name: name)
    def init(nil), do: {:ok, nil}
    def handle_call(:fire_due, _from, state), do: {:reply, :ok, state}
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

    base = Path.join(System.tmp_dir!(), "oauth-main-wake-#{System.unique_integer([:positive])}")
    db = :"oauth_main_wake_db_#{System.unique_integer([:positive])}"
    registry = :"oauth_main_wake_registry_#{System.unique_integer([:positive])}"
    lane = :"oauth_main_wake_lane_#{System.unique_integer([:positive])}"

    start_supervised!({DB, path: ":memory:", name: db})
    :ok = Tightbeam.Schema.ensure_all(db)

    register_hosts(db, [
      {@host, %{ssh: nil, base_dir: base, cli_bin: nil}}
    ])

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

  test "subscription finish inserts and delivers one complete native Main wake", ctx do
    assert %{user_id: "other-owner"} = Devices.add_user(ctx.db, "other-owner", false)
    create_session(ctx.db, "agent:product-a", @owner, "product-a")
    create_session(ctx.db, "agent:product-b", @owner, "product-b")
    create_session(ctx.db, Org.personal_session_key("other-owner"), "other-owner", "default")
    create_session(ctx.db, "agent:unrelated", "other-owner", "unrelated")

    start_credentials!(ctx)
    scheduler = start_real_scheduler!(ctx)
    onboard = onboard_handler(ctx, scheduler)
    lease_id = begin_and_stage!(onboard, "subscription")

    assert %{provider: :anthropic, credential_kind: "subscription", status: "onboarded"} =
             finish(onboard, lease_id, "subscription")

    assert {:ok, [[wake_id]]} = DB.query(ctx.db, "SELECT wakeId FROM wakes")

    assert %{
             session_key: @main,
             target_role: nil,
             origin: "process:tightbeam",
             prompt: @prompt,
             consumer: "prompt",
             state: "fired",
             condition_kind: nil,
             work_item_id: nil,
             assignment_id: nil,
             target_gate: 1,
             reresolve: nil
           } = Wakes.get(ctx.db, wake_id)

    delivered = "[from process:tightbeam]\n\n" <> @prompt

    assert [%{session_key: @main, sender: "process:tightbeam", content: ^delivered}] =
             Projection.list_after(ctx.db, @main, nil, 10)

    assert {:ok, [[@main, ^delivered, ^wake_id, "queued"]]} =
             DB.query(
               ctx.db,
               "SELECT sessionKey, prompt, wakeId, status FROM turns WHERE wakeId=?1",
               [wake_id]
             )

    assert_received {:lane_started, @main}

    assert {:ok, [[0]]} =
             DB.query(
               ctx.db,
               "SELECT COUNT(*) FROM wakes WHERE sessionKey IN ('agent:product-a','agent:product-b','agent:unrelated')"
             )
  end

  test "API-key completion does not trigger the OAuth recovery wake", ctx do
    start_credentials!(ctx)
    scheduler = start_noop_scheduler!()
    onboard = onboard_handler(ctx, scheduler)
    lease_id = begin_and_stage!(onboard, "apiKey")

    assert %{provider: :anthropic, credential_kind: "apiKey", status: "onboarded"} =
             finish(onboard, lease_id, "apiKey")

    assert_wake_count(ctx.db, 0)
  end

  test "retiring Main before delivery suppresses the turn without fallback", ctx do
    start_credentials!(ctx)
    noop = start_noop_scheduler!()
    onboard = onboard_handler(ctx, noop)
    lease_id = begin_and_stage!(onboard, "subscription")

    assert %{status: "onboarded"} = finish(onboard, lease_id, "subscription")
    assert {:ok, [[wake_id]]} = DB.query(ctx.db, "SELECT wakeId FROM wakes")
    assert %{state: "pending", target_gate: 1} = Wakes.get(ctx.db, wake_id)

    assert %{state: "retired"} = Org.retire(ctx.db, @main, "user:#{@owner}", 1_000)
    scheduler = start_real_scheduler!(ctx)
    assert :ok = Wakes.fire_due(scheduler)

    assert %{state: "canceled", target_role: nil, reresolve: nil} = Wakes.get(ctx.db, wake_id)

    assert {:ok, [[0]]} =
             DB.query(ctx.db, "SELECT COUNT(*) FROM turns WHERE wakeId=?1", [wake_id])

    refute_received {:lane_started, @main}
  end

  test "failed finish creates no Main wake", ctx do
    start_credentials!(ctx)
    scheduler = start_noop_scheduler!()
    onboard = onboard_handler(ctx, scheduler)
    _lease_id = begin_and_stage!(onboard, "subscription")

    assert %{code: "needs_onboarding", message: message} =
             finish(onboard, "wrong-lease", "subscription")

    assert message =~ "onboarding_lease_superseded"
    assert_wake_count(ctx.db, 0)
  end

  test "failed provider start creates no Main wake", ctx do
    parent = self()

    start_credentials!(ctx,
      start: fn :anthropic, :subscription ->
        send(parent, :start_attempted)
        {:error, :forced_start_failure}
      end
    )

    scheduler = start_noop_scheduler!()
    onboard = onboard_handler(ctx, scheduler)
    lease_id = begin_and_stage!(onboard, "subscription")

    assert %{code: "needs_onboarding", message: message} =
             finish(onboard, lease_id, "subscription")

    assert message =~ "forced_start_failure"
    assert_received :start_attempted
    assert_wake_count(ctx.db, 0)
  end

  test "failed provider resume creates no Main wake", ctx do
    parent = self()

    start_credentials!(ctx,
      resume: fn :anthropic ->
        send(parent, :resume_attempted)
        {:error, :forced_resume_failure}
      end
    )

    scheduler = start_noop_scheduler!()
    onboard = onboard_handler(ctx, scheduler)
    lease_id = begin_and_stage!(onboard, "subscription")

    assert %{code: "needs_onboarding", message: message} =
             finish(onboard, lease_id, "subscription")

    assert message =~ "forced_resume_failure"
    assert_received :resume_attempted
    assert_wake_count(ctx.db, 0)
  end

  test "wake transaction failure returns typed credential-recovered partial success", ctx do
    start_credentials!(ctx)
    scheduler = start_noop_scheduler!()
    onboard = onboard_handler(ctx, scheduler)
    lease_id = begin_and_stage!(onboard, "subscription")

    :ok =
      DB.execute(
        ctx.db,
        """
        CREATE TRIGGER force_oauth_main_wake_failure
        BEFORE INSERT ON wakes
        BEGIN
          SELECT RAISE(ABORT, 'forced OAuth Main wake failure');
        END;
        """
      )

    assert %{
             code: "credential_recovered_wake_failed",
             provider: :anthropic,
             host: @host,
             credential_recovered: true,
             wake_scheduled: false,
             message: message
           } = finish(onboard, lease_id, "subscription")

    assert message =~ "subscription credential on testhost recovered"
    assert message =~ "forced OAuth Main wake failure"
    assert Credentials.status(:anthropic, Credentials.server(@host)) == :onboarded
    assert_wake_count(ctx.db, 0)
  end

  defp start_credentials!(ctx, opts \\ []) do
    start_supervised!(
      {Credentials,
       Keyword.merge(
         [
           name: Credentials.server(@host),
           base_dir: ctx.base,
           machine: @host,
           start: fn _provider, _kind -> :ok end,
           on_credential_present: fn _provider -> :ok end,
           resume: fn _provider -> :ok end
         ],
         opts
       )}
    )
  end

  defp start_noop_scheduler! do
    name = :"oauth_noop_scheduler_#{System.unique_integer([:positive])}"
    start_supervised!(%{id: name, start: {NoopScheduler, :start_link, [name]}})
    name
  end

  defp start_real_scheduler!(ctx) do
    name = :"oauth_real_scheduler_#{System.unique_integer([:positive])}"

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
        {Wakes, :start_link, [[name: name, db: ctx.db, deliver: deliver, tick_ms: 86_400_000]]}
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

  defp begin_and_stage!(onboard, kind) do
    assert %{status: "ready", staging_path: staging, lease_id: lease_id} =
             onboard.(call(%{phase: "begin", kind: kind}))

    bytes =
      if kind == "subscription" do
        ~s({"claudeAiOauth":{"accessToken":"fixture-oauth-token"}})
      else
        "sk-ant-api03-fixture"
      end

    File.write!(Path.join(staging, ".credentials.json"), bytes)
    lease_id
  end

  defp finish(onboard, lease_id, kind),
    do: onboard.(call(%{phase: "finish", kind: kind, lease_id: lease_id}))

  defp call(params) do
    %{
      origin: "user:#{@owner}",
      principal: {:user, @owner},
      session_key: @main,
      params: Map.put(params, :provider, "anthropic")
    }
  end

  defp create_session(db, session_key, owner, archetype) do
    Org.create(db, %{
      session_key: session_key,
      display_name: session_key,
      owner_user_id: owner,
      origin: "user:#{owner}",
      archetype: archetype,
      host: @host,
      harness: "claude",
      provider: "anthropic",
      model: Model.new("fable")
    })
  end

  defp assert_wake_count(db, expected) do
    assert {:ok, [[^expected]]} = DB.query(db, "SELECT COUNT(*) FROM wakes")
  end
end
