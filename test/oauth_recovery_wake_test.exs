defmodule Tightbeam.OAuthRecoveryWakeTest do
  use Tightbeam.TestCase, async: false

  alias Tightbeam.{
    ConnRegistry,
    Credentials,
    DB,
    Devices,
    Gateway,
    Model,
    NoticeBatcher,
    Org,
    Projection,
    Roles,
    Wakes
  }

  @host "oauth-testhost"
  @owner "oauth-operator"
  @main Org.personal_session_key(@owner)
  @prompt_prefix "The OAuth token for "

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
    db = String.to_atom("oauth_main_wake_db_#{System.unique_integer([:positive])}")
    registry = String.to_atom("oauth_main_wake_registry_#{System.unique_integer([:positive])}")
    lane = String.to_atom("oauth_main_wake_lane_#{System.unique_integer([:positive])}")

    start_supervised!({DB, path: ":memory:", name: db})
    :ok = Tightbeam.Schema.ensure_all(db)

    register_hosts(db, [{@host, %{ssh: nil, base_dir: base, cli_bin: nil}}])
    start_supervised!({ConnRegistry, name: registry})
    start_supervised!({LaneProbe, {lane, self()}})

    assert %{user_id: @owner} = Devices.add_user(db, @owner, true)
    create_session(db, @main, @owner)

    on_exit(fn ->
      File.rm_rf!(base)

      case previous_host do
        nil -> Application.delete_env(:tightbeam, :local_host_name)
        host -> Application.put_env(:tightbeam, :local_host_name, host)
      end
    end)

    %{base: base, db: db, registry: registry, lane: lane}
  end

  test "Anthropic subscription finish delivers one immediate native wake to only its Main", ctx do
    assert %{user_id: "other-owner"} = Devices.add_user(ctx.db, "other-owner", false)
    create_session(ctx.db, "agent:product-a", @owner)
    create_session(ctx.db, "agent:product-b", @owner)
    create_session(ctx.db, Org.personal_session_key("other-owner"), "other-owner")
    create_session(ctx.db, "agent:unrelated", "other-owner")

    start_credentials!(ctx)
    scheduler = start_real_scheduler!(ctx)
    onboard = onboard_handler(ctx, scheduler)
    lease_id = begin_and_stage!(onboard, "anthropic", "subscription")

    assert %{provider: :anthropic, credential_kind: "subscription", status: "onboarded"} =
             finish(onboard, "anthropic", lease_id, "subscription")

    assert {:ok, [[wake_id]]} = DB.query(ctx.db, "SELECT wakeId FROM wakes WHERE digest=0")
    carrier_id = assert_main_wake!(ctx, wake_id, "anthropic")

    assert [%{session_key: @main, sender: "process:tightbeam", content: content}] =
             Projection.list_after(ctx.db, @main, nil, 10)

    assert content =~ recovery_prompt("anthropic")

    assert {:ok, [[@main, carrier_content, ^carrier_id, "queued"]]} =
             DB.query(
               ctx.db,
               "SELECT sessionKey, prompt, wakeId, status FROM turns WHERE wakeId=?1",
               [carrier_id]
             )

    assert carrier_content =~ recovery_prompt("anthropic")

    assert_received {:lane_started, @main}

    assert {:ok, [[0]]} =
             DB.query(
               ctx.db,
               "SELECT COUNT(*) FROM wakes WHERE sessionKey IN ('agent:product-a','agent:product-b','agent:unrelated')"
             )
  end

  test "OpenAI subscription finish targets the authenticated session owner's canonical Main",
       ctx do
    assert %{user_id: "other-owner"} = Devices.add_user(ctx.db, "other-owner", false)
    other_main = Org.personal_session_key("other-owner")
    operator_session = "agent:operator-session"
    create_session(ctx.db, operator_session, @owner)
    create_session(ctx.db, other_main, "other-owner")
    Roles.create!(ctx.db, "oauth-operator", @owner, operator_session)

    start_credentials!(ctx)
    scheduler = start_real_scheduler!(ctx)
    onboard = onboard_handler(ctx, scheduler)
    lease_id = begin_and_stage!(onboard, "openai", "subscription")

    call = %{
      origin: "agent:oauth-operator",
      principal: {:session, operator_session},
      session_key: operator_session,
      params: %{provider: "openai", phase: "finish", kind: "subscription", lease_id: lease_id}
    }

    assert %{provider: :openai, credential_kind: "subscription", status: "onboarded"} =
             onboard.(call)

    assert {:ok, [[wake_id]]} = DB.query(ctx.db, "SELECT wakeId FROM wakes WHERE digest=0")
    _carrier_id = assert_main_wake!(ctx, wake_id, "openai", operator_session)
    assert_received {:lane_started, @main}
    refute_received {:lane_started, ^other_main}
  end

  test "API-key completion for both OAuth providers does not schedule recovery wakes", ctx do
    start_credentials!(ctx)
    scheduler = start_noop_scheduler!()
    onboard = onboard_handler(ctx, scheduler)

    for provider <- ["openai", "anthropic"] do
      lease_id = begin_and_stage!(onboard, provider, "apiKey")

      assert %{provider: provider_atom, credential_kind: "apiKey", status: "onboarded"} =
               finish(onboard, provider, lease_id, "apiKey")

      assert provider_atom == %{"openai" => :openai, "anthropic" => :anthropic}[provider]
      assert_wake_count(ctx.db, 0)
    end
  end

  test "failed finish and process principals never schedule from an untrusted origin", ctx do
    start_credentials!(ctx)
    scheduler = start_noop_scheduler!()
    onboard = onboard_handler(ctx, scheduler)
    lease_id = begin_and_stage!(onboard, "anthropic", "subscription")

    assert %{code: "needs_onboarding", message: message} =
             finish(onboard, "anthropic", "wrong-lease", "subscription")

    assert message =~ "onboarding_lease_superseded"
    assert_wake_count(ctx.db, 0)

    result =
      onboard.(%{
        origin: "user:other-owner",
        principal: {:process, "scheduler"},
        session_key: nil,
        params: %{
          provider: "anthropic",
          phase: "finish",
          kind: "subscription",
          lease_id: lease_id
        }
      })

    assert %{code: "forbidden", message: "admin required"} = result
    assert_wake_count(ctx.db, 0)
    refute_received {:lane_started, _}
  end

  test "provider startup failure does not emit a recovery wake", ctx do
    start_credentials!(ctx, start: fn _provider, _kind -> {:error, :forced_start_failure} end)
    scheduler = start_noop_scheduler!()
    onboard = onboard_handler(ctx, scheduler)
    lease_id = begin_and_stage!(onboard, "anthropic", "subscription")

    assert %{code: "needs_onboarding", message: message} =
             finish(onboard, "anthropic", lease_id, "subscription")

    assert message =~ "forced_start_failure"
    assert_wake_count(ctx.db, 0)
  end

  test "provider resume failure does not emit a recovery wake", ctx do
    start_credentials!(ctx,
      resume: fn _provider -> {:error, :forced_resume_failure} end
    )

    scheduler = start_noop_scheduler!()
    onboard = onboard_handler(ctx, scheduler)
    lease_id = begin_and_stage!(onboard, "anthropic", "subscription")

    assert %{code: "needs_onboarding", message: message} =
             finish(onboard, "anthropic", lease_id, "subscription")

    assert message =~ "forced_resume_failure"
    assert_wake_count(ctx.db, 0)
  end

  test "wake transaction failure reports credential-recovered partial success", ctx do
    start_credentials!(ctx)
    scheduler = start_noop_scheduler!()
    onboard = onboard_handler(ctx, scheduler)
    lease_id = begin_and_stage!(onboard, "anthropic", "subscription")

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
           } = finish(onboard, "anthropic", lease_id, "subscription")

    assert message =~ "subscription credential on #{@host} recovered"
    assert message =~ "forced OAuth Main wake failure"
    assert Credentials.status(:anthropic, Credentials.server(@host)) == :onboarded
    assert_wake_count(ctx.db, 0)
  end

  test "retiring Main before delivery suppresses the turn without fallback", ctx do
    create_session(ctx.db, "agent:other-main-candidate", @owner)
    start_credentials!(ctx)
    noop = start_noop_scheduler!()
    onboard = onboard_handler(ctx, noop)
    lease_id = begin_and_stage!(onboard, "anthropic", "subscription")

    assert %{status: "onboarded"} = finish(onboard, "anthropic", lease_id, "subscription")
    assert {:ok, [[wake_id]]} = DB.query(ctx.db, "SELECT wakeId FROM wakes")

    assert %{state: "pending", target_gate: 1, target_role: nil, reresolve: nil} =
             Wakes.get(ctx.db, wake_id)

    assert %{state: "retired"} = Org.retire(ctx.db, @main, "user:#{@owner}", 1_000)
    scheduler = start_real_scheduler!(ctx)
    assert :ok = Wakes.fire_due(scheduler)

    assert %{state: "canceled", target_role: nil, reresolve: nil} = Wakes.get(ctx.db, wake_id)

    assert {:ok, [[0]]} =
             DB.query(ctx.db, "SELECT COUNT(*) FROM turns WHERE wakeId=?1", [wake_id])

    assert {:ok, [[0]]} =
             DB.query(
               ctx.db,
               "SELECT COUNT(*) FROM wakes WHERE sessionKey='agent:other-main-candidate'"
             )

    refute_received {:lane_started, _}
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
    name = String.to_atom("oauth_noop_scheduler_#{System.unique_integer([:positive])}")
    start_supervised!(%{id: name, start: {NoopScheduler, :start_link, [name]}})
    name
  end

  defp start_real_scheduler!(ctx) do
    name = String.to_atom("oauth_real_scheduler_#{System.unique_integer([:positive])}")

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
             tick_ms: 86_400_000,
             delivery_opts: [conn_registry: ctx.registry, lane_manager: ctx.lane]
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

  defp begin_and_stage!(onboard, provider, kind) do
    assert %{status: "ready", staging_path: staging, lease_id: lease_id} =
             onboard.(call(provider, %{phase: "begin", kind: kind}))

    {filename, bytes} = staged_credential(provider, kind)
    File.write!(Path.join(staging, filename), bytes)
    lease_id
  end

  defp staged_credential("openai", "subscription"),
    do: {"auth.json", ~s({"tokens":{"access_token":"fixture-oauth-token"}})}

  defp staged_credential("anthropic", "subscription"),
    do: {".credentials.json", ~s({"claudeAiOauth":{"accessToken":"fixture-oauth-token"}})}

  defp staged_credential("openai", "apiKey"),
    do: {"auth.json", ~s({"OPENAI_API_KEY":"sk-proj-fixture"})}

  defp staged_credential("anthropic", "apiKey"),
    do: {".credentials.json", "sk-ant-api03-fixture"}

  defp finish(onboard, provider, lease_id, kind),
    do: onboard.(call(provider, %{phase: "finish", kind: kind, lease_id: lease_id}))

  defp call(provider, params) do
    %{
      origin: "user:#{@owner}",
      principal: {:user, @owner},
      session_key: @main,
      params: Map.put(params, :provider, provider)
    }
  end

  defp assert_main_wake!(ctx, wake_id, provider, creator_session_key \\ nil) do
    assert %{
             session_key: @main,
             target_role: nil,
             origin: "process:tightbeam",
             creator_session_key: ^creator_session_key,
             prompt: prompt,
             consumer: "prompt",
             state: "fired",
             condition_kind: nil,
             work_item_id: nil,
             assignment_id: nil,
             target_gate: 1,
             reresolve: nil,
             class: "fyi",
             class_election: "classifier",
             delivery_rule: "notice-batching-v1 r2"
           } = Wakes.get(ctx.db, wake_id)

    assert prompt == recovery_prompt(provider)
    assert prompt =~ @prompt_prefix

    assert [%{delivery_wake_id: carrier_id, batch_state: "delivered"}] =
             NoticeBatcher.source_refs(ctx.db, wake_id)

    assert Wakes.get(ctx.db, carrier_id).state == "fired"
    carrier_id
  end

  defp recovery_prompt(provider) do
    "The OAuth token for #{provider} on #{@host} was refreshed. " <>
      "Read the manifests for every installed or learned Kung Fu. " <>
      "Read each manifest's declared main archetype. " <>
      "Find live agents with those archetypes. " <>
      "Notify each that the OAuth token was refreshed, and require each to inspect and " <>
      "resume any stalled agent graph."
  end

  defp create_session(db, session_key, owner) do
    Org.create(db, %{
      session_key: session_key,
      display_name: session_key,
      owner_user_id: owner,
      kind: if(session_key == Org.personal_session_key(owner), do: "main", else: "custom"),
      origin: "user:#{owner}",
      archetype: "default",
      host: @host,
      harness: "claude",
      provider: "anthropic",
      model: Model.new("claude-sonnet-5", effort: "medium")
    })
  end

  defp assert_wake_count(db, expected) do
    assert {:ok, [[^expected]]} = DB.query(db, "SELECT COUNT(*) FROM wakes")
  end
end
