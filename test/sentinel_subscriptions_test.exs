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
      first = subscribe(ctx, session, ["channel=!a:x"])
      second = subscribe(ctx, session, ["who=@mike:x"])
      posted = post(ctx, "retire-#{session}", "!a:x", "@mike:x")
      wake = wake_for(ctx.db, posted.event.fact_id, session)

      retire.(ctx.db)

      assert Tightbeam.Wakes.get(ctx.db, wake.wake_id).state == "canceled"

      assert count(ctx.db, "sentinel_subscriptions", "sessionKey=?1 AND endedAt IS NULL", [
               session
             ]) == 0

      assert count(ctx.db, "sentinel_subscriptions", "sessionKey=?1 AND endedAt IS NOT NULL", [
               session
             ]) == 2

      assert Tightbeam.Wakes.get(ctx.db, wake.wake_id).session_key == session
      assert wake_sessions(ctx.db, posted.event.fact_id) == [session]
      refute_delivered(ctx.db, wake.wake_id)

      after_retire = post(ctx, "after-retire-#{session}", "!a:x", "@mike:x")
      assert wake_sessions(ctx.db, after_retire.event.fact_id) == []
      assert first.id != second.id
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

  defp subscribe(ctx, session, where) do
    ctx.handlers["sentinel-subscribe"].(%{
      origin: "session:" <> session,
      principal: {:session, session},
      session_key: session,
      params: %{event: @event, where: where}
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
