defmodule Tightbeam.SentinelSubscriptionsTest do
  use Tightbeam.TestCase, async: false

  alias Tightbeam.{DB, Ephemeral, Gateway, Identity, Model, Org, Schema, SentinelSubscriptions}

  @event "demo/demo/ping"

  setup do
    disable_git_auto_maintenance!()

    root =
      Path.join(System.tmp_dir!(), "tb-event-subscriptions-#{System.unique_integer([:positive])}")

    bundles = Path.join(root, "kungfu")
    base = Path.join(root, "runtime")
    write_bundle!(bundles, "demo")

    previous = Application.get_env(:tightbeam, :kungfu_bundle_root_dir)
    Application.put_env(:tightbeam, :kungfu_bundle_root_dir, bundles)

    db = start_supervised!({DB, path: ":memory:", name: :sentinel_subscriptions_test})

    missing_scheduler =
      String.to_atom("sentinel_subscriptions_scheduler_#{System.unique_integer([:positive])}")

    :ok = Schema.ensure_all(db)
    :ok = DB.execute(db, "INSERT INTO users(userId,isAdmin,createdAt) VALUES('owner',0,1)")
    Identity.init!(base)
    learn!(base, "demo")

    for session <-
          ~w(sub-a sub-b sub-any sub-bob sub-late sub-normal sub-ephemeral observer parent) do
      create_session!(db, session)
    end

    on_exit(fn ->
      if is_nil(previous),
        do: Application.delete_env(:tightbeam, :kungfu_bundle_root_dir),
        else: Application.put_env(:tightbeam, :kungfu_bundle_root_dir, previous)

      File.rm_rf!(root)
    end)

    %{
      root: root,
      base: base,
      bundles: bundles,
      db: db,
      handlers: Gateway.handlers(%{db: db, base_dir: base, wake_scheduler: missing_scheduler})
    }
  end

  test "event listing includes detail descriptions and malformed declarations leave identity unchanged",
       ctx do
    listed = ctx.handlers["sentinel-events"].(%{origin: "process:fixture", params: %{}})

    assert [event] = listed.events
    assert event.qualified == @event
    assert event.description == "A generic ping with two string details."

    assert Enum.map(event.details, &{&1.name, &1.description}) == [
             {"channel", "A generic channel name."},
             {"who", "A generic participant name."}
           ]

    bad = Path.join(ctx.bundles, "invalid")
    File.mkdir_p!(Path.join(bad, "sentinels"))
    File.write!(Path.join(bad, "sentinels/demo"), "#!/bin/sh\nexit 0\n")

    File.write!(Path.join(bad, "manifest.toml"), """
    purpose = "A malformed test bundle."
    root_archetype = "default"

    [[sentinels]]
    name = "demo"
    command = "sentinels/demo"
    requires = []

    [[sentinels.events]]
    name = "ping"
    description = "A malformed ping."
    details = [
      { name = "channel", description = "First channel field." },
      { name = "channel", description = "Duplicate channel field." },
    ]
    """)

    identity_dir = Path.join(ctx.base, "identity")
    refs_before = identity_refs!(identity_dir)

    assert_raise ArgumentError, ~r/invalid\/demo\/ping.*duplicate detail channel/, fn ->
      Identity.learn!(ctx.base, "invalid", "test")
    end

    assert identity_refs!(identity_dir) == refs_before
    assert {:ok, []} = DB.query(ctx.db, "PRAGMA foreign_key_check")
  end

  test "ordinary scripts share the catalog and duplicate global kinds refuse atomically", ctx do
    path = Path.join([ctx.bundles, "script", "manifest.toml"])
    File.mkdir_p!(Path.dirname(path))

    File.write!(path, """
    purpose = "A script producer without a supervised process."
    root_archetype = "default"

    [[events]]
    name = "sample.done"
    description = "An object finished processing."
    details = [{ name = "object", description = "The completed object." }]
    """)

    learn!(ctx.base, "script")
    events = ctx.handlers["sentinel-events"].(%{params: %{}}).events
    assert Enum.map(events, & &1.qualified) == [@event, "sample.done"]

    assert Enum.find(events, &(&1.qualified == "sample.done")).details == [
             %{name: "object", description: "The completed object."}
           ]

    duplicate = Path.join([ctx.bundles, "duplicate", "manifest.toml"])
    File.mkdir_p!(Path.dirname(duplicate))
    File.cp!(path, duplicate)
    before = identity_refs!(Path.join(ctx.base, "identity"))

    assert_raise ArgumentError, ~r/duplicate event sample.done/, fn ->
      Identity.learn!(ctx.base, "duplicate", "test")
    end

    assert identity_refs!(Path.join(ctx.base, "identity")) == before
    assert ctx.handlers["sentinel-events"].(%{params: %{}}).events == events
  end

  test "filters match exact values, empty filters match all, and event keys deduplicate posts",
       ctx do
    first = subscribe(ctx, "sub-a", ["channel=!a:x", "channel=!b:x", "who=@mike:x"])
    same_set = subscribe(ctx, "sub-a", ["who=@mike:x", "channel=!b:x", "channel=!a:x"])
    second = subscribe(ctx, "sub-b", ["channel=!b:x", "channel=!a:x", "who=@mike:x"])
    any = subscribe(ctx, "sub-any", [])
    bob = subscribe(ctx, "sub-bob", ["channel=!a:x", "who=@bob:x"])

    assert first.id == same_set.id
    assert first.filter == %{"channel" => ["!a:x", "!b:x"], "who" => ["@mike:x"]}
    assert any.filter == %{}

    listed =
      ctx.handlers["sentinel-subscriptions"].(%{
        principal: {:session, "sub-a"}
      })

    assert [listed_first] = listed.subscriptions
    assert listed_first.id == first.id
    assert listed_first.filter == first.filter

    event_before_subscribe = post(ctx, "before-subscribe", "!a:x", "@mike:x")
    late = subscribe(ctx, "sub-late", ["channel=!a:x"])
    assert late.id
    assert wakes_for(ctx.db, event_before_subscribe.event.fact_id, "sub-late") == []

    first_post = post(ctx, "event-one", "!a:x", "@mike:x")
    duplicate = post(ctx, "event-one", "!a:x", "@mike:x")
    assert first_post.event.fact_id == duplicate.event.fact_id

    assert Enum.sort(wake_sessions(ctx.db, first_post.event.fact_id)) ==
             Enum.sort(["sub-a", "sub-b", "sub-any", "sub-late"])

    assert {:ok, [[encoded_payload]]} =
             DB.query(ctx.db, "SELECT payload FROM condition_facts WHERE id=?1", [
               first_post.event.fact_id
             ])

    assert JSON.decode!(encoded_payload) == %{
             "channel" => "!a:x",
             "who" => "@mike:x"
           }

    prompt = wake_for(ctx.db, first_post.event.fact_id, "sub-a").prompt
    assert prompt =~ @event
    assert prompt =~ first.id
    assert prompt =~ "tightbeam sentinel unsubscribe #{first.id}"
    assert prompt =~ "channel:\n!a:x"
    assert prompt =~ "who:\n@mike:x"

    bob_post = post(ctx, "event-bob", "!a:x", "@bob:x")

    assert Enum.sort(wake_sessions(ctx.db, bob_post.event.fact_id)) ==
             Enum.sort(["sub-any", "sub-bob", "sub-late"])

    other_channel = post(ctx, "event-other", "!c:x", "@mike:x")
    assert wake_sessions(ctx.db, other_channel.event.fact_id) == ["sub-any"]

    case_channel = post(ctx, "event-case", "!A:x", "@mike:x")
    assert wake_sessions(ctx.db, case_channel.event.fact_id) == ["sub-any"]

    assert count(ctx.db, "condition_facts", "kind=?1", [SentinelSubscriptions.event_kind(@event)]) ==
             5

    assert count(ctx.db, "wakes", "conditionKind=?1", [SentinelSubscriptions.event_kind(@event)]) ==
             12

    unsubscribed = unsubscribe(ctx, "sub-a", first.id)
    assert unsubscribed.unsubscribed == first.id

    assert ctx.handlers["sentinel-subscriptions"].(%{principal: {:session, "sub-a"}}).subscriptions ==
             []

    assert %{ended: true, subscription: id} = unsubscribe(ctx, "sub-a", first.id)
    assert id == first.id
  end

  test "invalid event posts and filters create no facts or subscriptions", ctx do
    _any = subscribe(ctx, "sub-a", [])

    assert %{code: "invalid", message: missing} =
             post_values(ctx, "missing-detail", ["channel=!a:x"])

    assert missing =~ "who"

    assert %{code: "invalid", message: unknown_detail} =
             post_values(ctx, "unknown-detail", ["channel=!a:x", "who=@mike:x", "body=hi"])

    assert unknown_detail =~ "body"

    assert %{code: "invalid", message: repeated_detail} =
             post_values(ctx, "repeated-detail", ["channel=!a:x", "channel=!b:x", "who=@mike:x"])

    assert repeated_detail =~ "channel"

    assert %{code: "unknown_sentinel_event"} =
             ctx.handlers["sentinel-post"].(%{
               origin: "process:sentinel:demo/demo",
               principal: {:process, "sentinel:demo/demo"},
               params: %{event: "missing/demo/unknown", key: "unknown-event", detail: []}
             })

    assert %{code: "not_authorized"} =
             ctx.handlers["sentinel-subscribe"].(%{
               principal: {:user, "owner"},
               params: %{event: @event, where: []}
             })

    assert %{code: "invalid", message: filter_error} =
             ctx.handlers["sentinel-subscribe"].(%{
               principal: {:session, "sub-b"},
               session_key: "sub-b",
               params: %{event: @event, where: ["body=hi"]}
             })

    assert filter_error =~ "body"

    assert count(ctx.db, "condition_facts", "kind=?1", [SentinelSubscriptions.event_kind(@event)]) ==
             0

    assert count(ctx.db, "wakes", "conditionKind=?1", [SentinelSubscriptions.event_kind(@event)]) ==
             0

    assert count(ctx.db, "sentinel_subscriptions", "sessionKey=?1", ["sub-b"]) == 0
  end

  test "overlapping subscriptions keep one wake until the last original match ends", ctx do
    channel_sub = subscribe(ctx, "sub-a", ["channel=!a:x"])
    person_sub = subscribe(ctx, "sub-a", ["who=@mike:x"])
    posted = post(ctx, "overlap-event", "!a:x", "@mike:x")
    wake = wake_for(ctx.db, posted.event.fact_id, "sub-a")

    assert count(ctx.db, "sentinel_subscription_wake_matches", "wakeId=?1", [wake.wake_id]) == 2

    assert %{unsubscribed: id} = unsubscribe(ctx, "sub-a", channel_sub.id)
    assert id == channel_sub.id
    assert Tightbeam.Wakes.get(ctx.db, wake.wake_id).state == "pending"

    assert %{unsubscribed: id} = unsubscribe(ctx, "sub-a", person_sub.id)
    assert id == person_sub.id
    assert Tightbeam.Wakes.get(ctx.db, wake.wake_id).state == "canceled"

    refute_delivered(ctx.db, wake.wake_id)
    after_cancel = post(ctx, "after-overlap", "!a:x", "@mike:x")
    assert wake_sessions(ctx.db, after_cancel.event.fact_id) == []
  end

  test "a later subscription does not keep an earlier wake alive", ctx do
    earlier = subscribe(ctx, "sub-late", ["channel=!a:x"])
    posted = post(ctx, "before-late-sub", "!a:x", "@mike:x")
    wake = wake_for(ctx.db, posted.event.fact_id, "sub-late")
    later = subscribe(ctx, "sub-late", ["who=@mike:x"])

    assert later.id != earlier.id
    earlier_id = earlier.id
    assert %{unsubscribed: ^earlier_id} = unsubscribe(ctx, "sub-late", earlier.id)
    assert Tightbeam.Wakes.get(ctx.db, wake.wake_id).state == "canceled"
    refute_delivered(ctx.db, wake.wake_id)

    after_cancel = post(ctx, "after-late-sub", "!a:x", "@mike:x")
    assert wake_sessions(ctx.db, after_cancel.event.fact_id) == ["sub-late"]

    assert {:ok, [[matched]]} =
             DB.query(
               ctx.db,
               "SELECT subscriptionId FROM sentinel_subscription_wake_matches WHERE wakeId=?1",
               [wake_for(ctx.db, after_cancel.event.fact_id, "sub-late").wake_id]
             )

    assert matched == later.id
  end

  test "ordinary and ephemeral retirement end subscriptions and retract their wakes", ctx do
    for {session, retire} <- [
          {"sub-normal", fn db -> Org.retire(db, "sub-normal", "user:owner", :off) end},
          {"sub-ephemeral",
           fn db ->
             {:ok, :ok} =
               DB.transaction(db, fn txn ->
                 Ephemeral.stamp_in_txn(txn, "sub-ephemeral", "parent")
                 Ephemeral.retire_in_txn(txn, "sub-ephemeral")
               end)
           end}
        ] do
      first = subscribe(ctx, session, ["channel=!a:x"], %{mode: "once", fallback_ms: 60_000})
      second = subscribe(ctx, session, ["who=@mike:x"])
      pending = subscribe(ctx, session, ["channel=other"], %{mode: "once", fallback_ms: 60_000})
      posted = post(ctx, "retire-#{session}", "!a:x", "@mike:x")
      wake = wake_for(ctx.db, posted.event.fact_id, session)

      retire.(ctx.db)

      assert Tightbeam.Wakes.get(ctx.db, wake.wake_id).state == "canceled"

      assert count(ctx.db, "sentinel_subscriptions", "sessionKey=?1 AND endedAt IS NULL", [
               session
             ]) == 0

      assert count(ctx.db, "sentinel_subscriptions", "sessionKey=?1 AND endedAt IS NOT NULL", [
               session
             ]) == 3

      assert Tightbeam.Wakes.get(ctx.db, wake.wake_id).session_key == session
      assert wake_sessions(ctx.db, posted.event.fact_id) == [session]
      refute_delivered(ctx.db, wake.wake_id)

      after_retire = post(ctx, "after-retire-#{session}", "!a:x", "@mike:x")
      assert wake_sessions(ctx.db, after_retire.event.fact_id) == []
      assert first.id != second.id

      assert {:ok, :ok} =
               DB.transaction(
                 ctx.db,
                 &SentinelSubscriptions.fulfill_due_in_txn(&1, pending.fallback_at)
               )

      assert count(ctx.db, "sentinel_subscription_wake_matches", "subscriptionId=?1", [pending.id]) ==
               0
    end
  end

  test "declared event details are stored and delivered without a size cutoff", ctx do
    sub = subscribe(ctx, "sub-a", [])
    body = "first=a\nsecond\n" <> String.duplicate("x", 60_000)
    posted = post(ctx, "large-event", "!a:x", body)
    wake = wake_for(ctx.db, posted.event.fact_id, "sub-a")

    assert wake.prompt =~ body

    assert count(
             ctx.db,
             "sentinel_subscription_wake_matches",
             "wakeId=?1 AND subscriptionId=?2",
             [wake.wake_id, sub.id]
           ) == 1
  end

  test "once and standing share a delivery, consume demand, and retain queued justification",
       ctx do
    once = subscribe(ctx, "sub-a", [], %{mode: "once", fallback_ms: 60_000})
    standing = subscribe(ctx, "sub-a", ["channel=a"])
    :ok = SentinelSubscriptions.ensure_schema(ctx.db)
    assert subscribe(ctx, "sub-a", [], %{mode: "once", fallback_ms: 60_000}) == once
    assert %{code: "invalid"} = subscribe(ctx, "sub-a", [], %{fallback_ms: 60_000})

    assert %{code: "invalid"} =
             subscribe(ctx, "sub-a", [], %{mode: "standing", fallback_ms: 60_000})

    assert length(SentinelSubscriptions.demand(ctx.db).demand) == 2

    first = post(ctx, "once-first", "a", "x")
    wake = wake_for(ctx.db, first.event.fact_id, "sub-a")
    assert wake.prompt =~ once.id
    assert wake.prompt =~ standing.id
    assert [%{filter: %{"channel" => ["a"]}}] = SentinelSubscriptions.demand(ctx.db).demand

    assert [%{id: id}] =
             ctx.handlers["sentinel-subscriptions"].(%{principal: {:session, "sub-a"}}).subscriptions

    assert id == standing.id
    unsubscribe(ctx, "sub-a", standing.id)
    assert Tightbeam.Wakes.get(ctx.db, wake.wake_id).state == "pending"
    assert %{ended: true} = unsubscribe(ctx, "sub-a", once.id)
    assert Tightbeam.Wakes.get(ctx.db, wake.wake_id).state == "canceled"
    assert %{ended: true} = unsubscribe(ctx, "sub-a", once.id)
    second = post(ctx, "once-second", "a", "x")
    assert wakes_for(ctx.db, second.event.fact_id, "sub-a") == []
  end

  test "once fallback fires only once and cancellation withdraws its deadline", ctx do
    once = subscribe(ctx, "sub-a", [], %{mode: "once", fallback_ms: 60_000})
    cancelled = subscribe(ctx, "sub-b", [], %{mode: "once", fallback_ms: 60_000})
    unsubscribe(ctx, "sub-b", cancelled.id)

    assert {:ok, :ok} =
             DB.transaction(
               ctx.db,
               &SentinelSubscriptions.fulfill_due_in_txn(&1, once.fallback_at)
             )

    assert SentinelSubscriptions.demand(ctx.db).demand == []

    assert {:ok, [[wake_id, prompt]]} =
             DB.query(
               ctx.db,
               "SELECT w.wakeId,w.prompt FROM wakes w JOIN sentinel_subscription_wake_matches m ON w.wakeId=m.wakeId WHERE m.subscriptionId=?1",
               [once.id]
             )

    assert prompt =~ "Cause: fallback"
    assert prompt =~ "Deadline: #{once.fallback_at}"

    assert {:ok, :ok} =
             DB.transaction(
               ctx.db,
               &SentinelSubscriptions.fulfill_due_in_txn(&1, once.fallback_at + 1)
             )

    assert count(ctx.db, "sentinel_subscription_wake_matches", "subscriptionId=?1", [once.id]) ==
             1

    event = post(ctx, "after-fallback", "a", "x")
    assert wakes_for(ctx.db, event.event.fact_id, "sub-a") == []
    unsubscribe(ctx, "sub-a", once.id)
    assert Tightbeam.Wakes.get(ctx.db, wake_id).state == "canceled"
  end

  test "the wake scheduler processes the subscription deadline without polling", ctx do
    Tightbeam.Rules.load!(ctx.base, Map.keys(ctx.handlers))
    parent = self()
    once = subscribe(ctx, "sub-a", [], %{mode: "once", fallback_ms: 50})

    start_supervised!(
      {Tightbeam.Wakes,
       db: ctx.db,
       name: Tightbeam.WakeScheduler,
       deliver: fn wake ->
         send(parent, {:timer_delivery, wake.prompt})
         :ok
       end}
    )

    assert_receive {:timer_delivery, prompt}, 2_000
    assert prompt =~ "Cause: fallback"
    assert prompt =~ once.id
    assert SentinelSubscriptions.demand(ctx.db).demand == []

    assert count(ctx.db, "sentinel_subscription_wake_matches", "subscriptionId=?1", [once.id]) ==
             1
  end

  test "retirement forwards legacy fact waits but ends new interests", ctx do
    successor = Org.personal_session_key("owner")

    {:ok, _} =
      DB.query(
        ctx.db,
        "INSERT INTO sessions(sessionKey,displayName,ownerUserId,origin,archetype,harness,provider,model,host,state,createdAt,updatedAt) VALUES (?1,'successor','owner','user:owner','default','claude','anthropic','fable','testhost','active',1,1)",
        [successor]
      )

    legacy =
      Tightbeam.Wakes.schedule(ctx.db, %{
        session_key: "sub-normal",
        origin: "session:sub-normal",
        prompt: "original legacy prompt",
        condition_kind: "sample.finished",
        condition_scope: "object",
        due_at: System.system_time(:millisecond) + 60_000
      })

    subscribe(ctx, "sub-normal", [], %{mode: "once", fallback_ms: 60_000})
    Org.retire(ctx.db, "sub-normal", "user:owner", :off)
    forwarded = Tightbeam.Wakes.get(ctx.db, legacy.wake_id)
    assert forwarded.session_key == successor
    assert forwarded.prompt == legacy.prompt
    assert forwarded.due_at == legacy.due_at
    assert forwarded.condition_after_id == legacy.condition_after_id

    assert [%{kind: "sample.finished", filter: %{"scope" => ["object"]}}] =
             SentinelSubscriptions.demand(ctx.db).demand

    Tightbeam.ConditionFacts.file(ctx.db, :missing_subscription_scheduler, %{
      kind: "sample.finished",
      scope: "object",
      origin: "process:fixture"
    })

    assert Tightbeam.Wakes.get(ctx.db, legacy.wake_id).fired_by == "condition"
    assert SentinelSubscriptions.demand(ctx.db).demand == []
  end

  test "both candidate watchers traverse the real CLI and gateway subscription routes", ctx do
    for {bundle, watcher} <- [{"sentinels", "matrix"}, {"agentic-engineering", "landing-watch"}] do
      shipped = Path.expand("../priv/kungfu/#{bundle}", __DIR__)
      destination = Path.join(ctx.bundles, bundle)
      File.mkdir_p!(Path.join(destination, "sentinels"))

      manifest =
        File.read!(Path.join(shipped, "manifest.toml"))
        |> String.replace("root_archetype = \"orchestrator\"", "root_archetype = \"default\"")

      File.write!(Path.join(destination, "manifest.toml"), manifest)

      File.cp!(
        Path.join(shipped, "sentinels/#{watcher}"),
        Path.join(destination, "sentinels/#{watcher}")
      )

      learn!(ctx.base, bundle)
    end

    Tightbeam.Rules.load!(ctx.base, Map.keys(ctx.handlers))

    router =
      Tightbeam.Wire.Router.init(
        db: ctx.db,
        base_dir: ctx.base,
        handlers: ctx.handlers,
        cli_token: "route-fixture-token",
        session_status: fn _ -> nil end
      )

    server =
      start_supervised!(
        {Bandit,
         plug: {Tightbeam.Wire.Router, router}, port: 0, ip: {127, 0, 0, 1}, startup_log: false}
      )

    {:ok, {_, port}} = ThousandIsland.listener_info(server)
    binary = Path.expand("../cli/target/release/tightbeam", __DIR__)
    {:ok, [[token]]} = DB.query(ctx.db, "SELECT cliToken FROM sessions WHERE sessionKey='sub-a'")

    File.write!(
      Path.join(ctx.root, ".tightbeam-session"),
      JSON.encode!(%{
        url: "http://127.0.0.1:#{port}",
        token: token,
        sessionKey: "sub-a"
      })
    )

    env = [
      {"TIGHTBEAM_URL", "http://127.0.0.1:#{port}"},
      {"TIGHTBEAM_TOKEN", token},
      {"TIGHTBEAM_BASE_DIR", ctx.base},
      {"TIGHTBEAM_AS_PROCESS", nil}
    ]

    cli = fn args ->
      {output, status} = System.cmd(binary, args, cd: ctx.root, env: env)
      assert status == 0, output
      JSON.decode!(output)
    end

    once =
      cli.(["sentinel", "subscribe", "--event", "sentinels/matrix/message", "--mode", "once"])

    standing = cli.(["sentinel", "subscribe", "--event", "sentinels/matrix/message"])
    assert once["id"] != standing["id"]

    cli.([
      "sentinel",
      "subscribe",
      "--event",
      "landing.settled",
      "--mode",
      "once",
      "--where",
      "scope=example/repo#7"
    ])

    legacy =
      for prompt <- ["legacy first", "legacy second"] do
        cli.([
          "wake",
          "--session",
          "sub-a",
          "--when-fact",
          "landing.settled",
          "--when-scope",
          "example/repo#7",
          "--fallback-after",
          "1h",
          "--prompt",
          prompt
        ])["wakeId"]
      end

    bin = Path.join(ctx.root, "bin")
    File.mkdir_p!(bin)
    File.ln_s!(binary, Path.join(bin, "tightbeam"))
    sample = Path.expand("fixtures/matrix-commander-message.jsonl", __DIR__)
    File.write!(Path.join(bin, "matrix-commander"), "#!/bin/sh\ncat \"$MATRIX_SAMPLE\"\n")
    File.chmod!(Path.join(bin, "matrix-commander"), 0o755)
    # Only the outside service response is a fixture; watcher, CLI, HTTP router,
    # condition store, subscription matching and wake creation are real.
    File.write!(Path.join(bin, "gh"), """
    #!/usr/bin/env python3
    import json, sys
    if sys.argv[1:3] == ['api', 'user']:
        print('route-fixture')
        sys.exit(0)
    print(json.dumps({'data': {'repository': {'pullRequest': {
      'number': 7, 'state': 'CLOSED', 'merged': False, 'mergeCommit': None,
      'headRefOid': 'a' * 40, 'baseRefName': 'main', 'autoMergeRequest': None,
      'mergeQueueEntry': None, 'timelineItems': {
        'pageInfo': {'hasNextPage': False, 'endCursor': None},
        'nodes': [{'__typename': 'ClosedEvent', 'id': 'closed-seven', 'createdAt': '2026-01-01T00:00:00Z'}]
      }}}}}))
    """)

    File.chmod!(Path.join(bin, "gh"), 0o755)

    producer_env =
      env ++
        [
          {"TIGHTBEAM_TOKEN", "route-fixture-token"},
          {"TIGHTBEAM_AS_PROCESS", "route-fixture"},
          {"PATH", bin <> ":" <> System.get_env("PATH")},
          {"MATRIX_SAMPLE", sample},
          {"MATRIX_COMMANDER_CREDENTIALS", Path.join(ctx.root, "unused-login")},
          {"MATRIX_COMMANDER_STORE", Path.join(ctx.root, "unused-store")},
          {"GH_CONFIG_DIR", ctx.root},
          {"LANDING_REPOS", ""}
        ]

    cli.([
      "sentinel",
      "subscribe",
      "--event",
      "landing.settled",
      "--mode",
      "once",
      "--where",
      "scope=example/repo#8"
    ])

    {legacy_output, legacy_status} =
      System.cmd(
        binary,
        [
          "condition",
          "--kind",
          "landing.settled",
          "--scope",
          "example/repo#8",
          "--key",
          "legacy-condition"
        ],
        cd: Path.dirname(ctx.root),
        env: producer_env,
        stderr_to_stdout: true
      )

    assert legacy_status == 0, legacy_output

    assert {:ok, [[1]]} =
             DB.query(ctx.db, "SELECT count(*) FROM sentinel_subscription_wake_matches")

    matrix = Path.expand("../priv/kungfu/sentinels/sentinels/matrix", __DIR__)

    {output, code} =
      System.cmd("python3", [matrix],
        cd: Path.dirname(ctx.root),
        env: producer_env,
        stderr_to_stdout: true
      )

    assert code != 0
    assert output =~ "matrix-commander exited"

    assert {:ok, [[payload]]} =
             DB.query(
               ctx.db,
               "SELECT payload FROM condition_facts WHERE kind='sentinels/matrix/message'"
             )

    assert JSON.decode!(payload)["text"] == "first line\na=b\nsecond line"

    assert {:ok, [[3]]} =
             DB.query(ctx.db, "SELECT count(*) FROM sentinel_subscription_wake_matches")

    landing = Path.expand("../priv/kungfu/agentic-engineering/sentinels/landing-watch", __DIR__)

    {output, code} =
      System.cmd("python3", [landing, "--once"],
        cd: Path.dirname(ctx.root),
        env: producer_env,
        stderr_to_stdout: true
      )

    assert code == 0, output

    assert {:ok, [["example/repo#7"], ["example/repo#8"]]} =
             DB.query(
               ctx.db,
               "SELECT scope FROM condition_facts WHERE kind='landing.settled' ORDER BY scope"
             )

    for {id, prompt} <- Enum.zip(legacy, ["legacy first", "legacy second"]) do
      wake = Tightbeam.Wakes.get(ctx.db, id)
      assert wake.prompt == prompt
      assert wake.fired_by == "condition"
    end

    assert %{"demand" => [%{"kind" => "sentinels/matrix/message"}]} = cli.(["sentinel", "demand"])
    assert %{"subscriptions" => [%{"mode" => "standing"}]} = cli.(["sentinel", "subscriptions"])
    cli.(["sentinel", "unsubscribe", standing["id"]])
    cli.(["sentinel", "unsubscribe", once["id"]])
    assert %{"demand" => []} = cli.(["sentinel", "demand"])
  end

  defp subscribe(ctx, session, where, options \\ %{}) do
    ctx.handlers["sentinel-subscribe"].(%{
      origin: "session:" <> session,
      principal: {:session, session},
      session_key: session,
      params: Map.merge(%{event: @event, where: where}, options)
    })
  end

  defp unsubscribe(ctx, session, id) do
    ctx.handlers["sentinel-unsubscribe"].(%{
      origin: "session:" <> session,
      principal: {:session, session},
      session_key: session,
      params: %{subscription_id: id}
    })
  end

  defp post(ctx, key, channel, who) do
    post_values(ctx, key, ["channel=" <> channel, "who=" <> who])
  end

  defp post_values(ctx, key, details) do
    ctx.handlers["sentinel-post"].(%{
      origin: "process:sentinel:demo/demo",
      principal: {:process, "sentinel:demo/demo"},
      params: %{
        event: @event,
        key: key,
        detail: details
      }
    })
  end

  defp wake_sessions(db, fact_id) do
    kind = SentinelSubscriptions.event_kind(@event)
    before_id = condition_cursor_before(db, fact_id)

    {:ok, rows} =
      DB.query(
        db,
        "SELECT sessionKey FROM wakes WHERE conditionKind=?1 AND conditionAfterId=?2 ORDER BY sessionKey",
        [kind, before_id]
      )

    Enum.map(rows, &hd/1)
  end

  defp wakes_for(db, fact_id, session) do
    kind = SentinelSubscriptions.event_kind(@event)
    before_id = condition_cursor_before(db, fact_id)

    {:ok, rows} =
      DB.query(
        db,
        "SELECT wakeId FROM wakes WHERE conditionKind=?1 AND sessionKey=?2 AND conditionAfterId=?3 ORDER BY wakeId",
        [kind, session, before_id]
      )

    Enum.map(rows, &hd/1)
  end

  defp condition_cursor_before(db, fact_id) do
    {:ok, [[cursor]]} =
      DB.query(db, "SELECT COALESCE(MAX(id),0) FROM condition_facts WHERE id<?1", [fact_id])

    cursor
  end

  defp wake_for(db, fact_id, session) do
    [wake_id] = wakes_for(db, fact_id, session)
    Tightbeam.Wakes.get(db, wake_id)
  end

  defp refute_delivered(db, wake_id) do
    assert count(db, "turns", "wakeId=?1", [wake_id]) == 0
    assert count(db, "notice_batch_members", "sourceWakeId=?1", [wake_id]) == 0
  end

  defp count(db, table, where, params) do
    {:ok, [[count]]} = DB.query(db, "SELECT COUNT(*) FROM #{table} WHERE #{where}", params)
    count
  end

  defp create_session!(db, key) do
    Org.create(db, %{
      session_key: key,
      display_name: key,
      owner_user_id: "owner",
      origin: "user:owner",
      archetype: "default",
      host: "testhost",
      harness: "claude",
      provider: "anthropic",
      model: Model.new("fable")
    })
  end

  defp write_bundle!(root, name) do
    dir = Path.join(root, name)
    File.mkdir_p!(Path.join(dir, "sentinels"))
    File.write!(Path.join(dir, "sentinels/demo"), "#!/bin/sh\nexec sleep 60\n")

    File.write!(Path.join(dir, "manifest.toml"), """
    purpose = "A generic event test bundle."
    root_archetype = "default"

    [[sentinels]]
    name = "demo"
    command = "sentinels/demo"
    requires = []

    [[sentinels.events]]
    name = "ping"
    description = "A generic ping with two string details."
    details = [
      { name = "channel", description = "A generic channel name." },
      { name = "who", description = "A generic participant name." },
    ]
    """)
  end

  defp learn!(base, name) do
    {:ok, candidate} = Identity.learn!(base, name, "test")
    {:ok, _revision} = Identity.publish_live!(base, candidate)
  end

  defp identity_refs!(identity_dir) do
    Enum.map(["main", "tightbeam/live", "tightbeam/upstream"], fn ref ->
      {revision, 0} = System.cmd("git", ["-C", identity_dir, "rev-parse", ref])
      {ref, String.trim(revision)}
    end)
  end

  defp disable_git_auto_maintenance! do
    index = String.to_integer(System.get_env("GIT_CONFIG_COUNT", "0"))
    System.put_env("GIT_CONFIG_COUNT", Integer.to_string(index + 1))
    System.put_env("GIT_CONFIG_KEY_#{index}", "maintenance.auto")
    System.put_env("GIT_CONFIG_VALUE_#{index}", "false")
  end
end
