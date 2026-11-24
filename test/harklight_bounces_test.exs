defmodule Tightbeam.HarklightBouncesTest do
  use Tightbeam.TestCase, async: false

  alias Tightbeam.{DB, HarklightBounces, HarklightWakes, Model, Org, Placement}

  @handle "7d737f62-bbd7-4c51-978d-f6ff5b4d8146"
  @other_handle "0a2a4b2e-6a52-4c2b-9d52-2f5cc1a0f4aa"
  @host Placement.local_host_name()

  setup do
    db = :"harklight_bounces_#{System.unique_integer([:positive])}"
    start_supervised!({DB, path: ":memory:", name: db})
    :ok = ensure_all_schemas(db)
    custody = Path.join(System.tmp_dir!(), "#{db}-feed-custody")
    old = Application.get_env(:tightbeam, :harklight_recovery_options, [])

    Application.put_env(
      :tightbeam,
      :harklight_recovery_options,
      Keyword.put(old, :feed_custody_dir, custody)
    )

    on_exit(fn ->
      Application.put_env(:tightbeam, :harklight_recovery_options, old)
      File.rm_rf(custody)
    end)

    {:ok, _} =
      DB.query(
        db,
        "INSERT INTO users(userId,isAdmin,creationKind,createdAt) VALUES('owner',0,'admin_add',1)"
      )

    main =
      Org.create(db, %{
        session_key: Org.personal_session_key("owner"),
        display_name: "Main",
        kind: "main",
        owner_user_id: "owner",
        origin: "user:owner",
        archetype: "default",
        host: @host,
        harness: "codex",
        provider: "openai",
        model: Model.new("fable")
      })

    %{db: db, main: main.session_key}
  end

  ## The kind decision is one function

  test "kind decides full, soft and ignored notices in one place" do
    for type <- ["unseen_interval_elapsed", "full_bounce"],
        do: assert(HarklightBounces.kind(%{"advisory_type" => type}) == :full)

    assert HarklightBounces.kind(%{"advisory_type" => "soft_bounce"}) == :soft

    for type <- ["possible_contradictions", "opened_interval_elapsed", "mystery", ""],
        do: assert(HarklightBounces.kind(%{"advisory_type" => type}) == :ignore)

    assert HarklightBounces.kind(%{}) == :ignore
  end

  ## One wake per advisory, whichever way it is heard

  test "the feed and the read path together wake once per advisory ID", ctx do
    %{db: db, main: main} = ctx
    worker = agent(db, "worker", main)
    conversation(db, @handle, worker)
    sent(db, @handle, "item-1")

    frame = advisory_frame(5, "item-1", "adv-1")
    item = item("item-1", @handle)

    assert :ok = capture(db, 5, [frame], item)
    assert [[^worker, prompt]] = wake_rows(db, "SELECT sessionKey,prompt FROM wakes")
    assert prompt =~ "This message had not been opened when it bounced."

    # The same advisory heard again: by a replayed feed revision, by a later
    # baseline carrying it, and by the read path. Nobody is woken again.
    assert :ok = capture(db, 5, [frame], item)

    assert :ok =
             HarklightWakes.capture_feed(
               db,
               @handle,
               9,
               [
                 message_frame(8, item),
                 Map.put(advisory_frame(9, "item-1", "adv-1"), "item", item)
               ],
               :baseline
             )

    assert {:ok, summary} = read(db, [%{item | "advisories" => [advisory("adv-1")]}])
    assert summary.woken == []
    assert [[1]] = wake_rows(db, "SELECT count(*) FROM wakes")
    assert [[1]] = wake_rows(db, "SELECT count(*) FROM harklight_bounces")
    assert [[9]] = wake_rows(db, "SELECT rev FROM harklight_feed_checkpoints")
    assert [["feed", "woken"]] = wake_rows(db, "SELECT source,outcome FROM harklight_bounces")
  end

  test "the capture, its wake and the checkpoint commit together", ctx do
    %{db: db, main: main} = ctx
    worker = agent(db, "worker", main)
    conversation(db, @handle, worker)
    sent(db, @handle, "item-1")

    assert :ok = capture(db, 7, [advisory_frame(7, "item-1", "adv-1")], item("item-1", @handle))

    assert [[7]] = wake_rows(db, "SELECT rev FROM harklight_feed_checkpoints")
    assert [["adv-1", wake]] = wake_rows(db, "SELECT advisoryId,wakeId FROM harklight_bounces")
    assert [[1]] = wake_rows(db, "SELECT count(*) FROM wakes WHERE wakeId=?1", [wake])
  end

  test "a feed baseline of advisories wakes once and takes openness from the same batch", ctx do
    %{db: db, main: main} = ctx
    worker = agent(db, "worker", main)
    conversation(db, @handle, worker)
    sent(db, @handle, "open")
    sent(db, @handle, "answered")

    open = item("open", @handle)
    answered = item("answered", @handle, terminal: %{"state" => "answered", "at_ms" => 5})

    frames = [
      message_frame(1, open),
      advisory_frame(2, "open", "adv-open"),
      message_frame(3, answered),
      advisory_frame(4, "answered", "adv-answered")
    ]

    assert :ok = HarklightWakes.capture_feed(db, @handle, 4, frames, :baseline)

    assert [["adv-answered", "closed"], ["adv-open", "woken"]] =
             wake_rows(db, "SELECT advisoryId,outcome FROM harklight_bounces ORDER BY advisoryId")

    assert [[1]] =
             wake_rows(db, "SELECT count(*) FROM wakes WHERE wakeId LIKE 'w_harklight_bounce_%'")
  end

  test "a bounce skipped by a checkpoint or baseline is heard by the read path", ctx do
    %{db: db, main: main} = ctx
    worker = agent(db, "worker", main)
    conversation(db, @handle, worker)
    sent(db, @handle, "item-1")

    # The feed moved past the advisory without it: only the checkpoint remains.
    assert :ok = HarklightWakes.capture_feed(db, @handle, 12, [], :live)
    assert [[0]] = wake_rows(db, "SELECT count(*) FROM wakes")

    assert {:ok, %{woken: ["adv-1"]}} =
             read(db, [item("item-1", @handle, advisories: [advisory("adv-1")])])

    assert [[1]] = wake_rows(db, "SELECT count(*) FROM wakes")
    assert [["read"]] = wake_rows(db, "SELECT source FROM harklight_bounces")
  end

  test "an advisory already marked delivered is not woken", ctx do
    %{db: db, main: main} = ctx
    worker = agent(db, "worker", main)
    conversation(db, @handle, worker)
    sent(db, @handle, "item-1")

    assert {:ok, %{woken: [], closed: []}} =
             read(db, [item("item-1", @handle, advisories: [advisory("adv-1", delivered: true)])])

    assert [[0]] = wake_rows(db, "SELECT count(*) FROM harklight_bounces")
  end

  test "a live feed advisory is heard through the listener and survives a replay", ctx do
    %{db: db, main: main} = ctx
    worker = agent(db, "worker", main)
    conversation(db, @handle, worker)
    sent(db, @handle, "item-1")

    {:ok, _} =
      DB.query(db, "INSERT INTO harklight_feed_checkpoints(handle,rev) VALUES(?1,3)", [@handle])

    frame = JSON.encode!(advisory_frame(5, "item-1", "adv-1"))
    lookup = JSON.encode!(%{"rev" => 5, "message" => item("item-1", @handle)})

    fake_agent!("""
    case "$*" in
      'listen --follow --session #{@handle} --after 3')
        printf '%s\\n' '#{frame}' '#{frame}' '{"kind":"caught_up","rev":5}'
        exec sleep 30
        ;;
      'message-get --item-id item-1')
        printf '%s\\n' '#{lookup}'
        ;;
      *) exit 2 ;;
    esac
    """)

    start_supervised!({HarklightWakes, db: db, retry_delays: [20, 40]})

    assert eventually(fn ->
             DB.query(db, "SELECT rev FROM harklight_feed_checkpoints") == {:ok, [[5]]}
           end)

    assert [[1]] = wake_rows(db, "SELECT count(*) FROM harklight_bounces")
    assert [[1]] = wake_rows(db, "SELECT count(*) FROM wakes")
  end

  test "a feed baseline through the listener needs no message lookup", ctx do
    %{db: db, main: main} = ctx
    worker = agent(db, "worker", main)
    conversation(db, @handle, worker)
    sent(db, @handle, "item-1")

    message = JSON.encode!(message_frame(2, item("item-1", @handle)))
    advisory = JSON.encode!(advisory_frame(3, "item-1", "adv-1"))

    # Any message lookup would exit 2 and stop the feed: the baseline carries
    # the message the advisory concerns.
    fake_agent!("""
    case "$*" in
      'listen --follow --session #{@handle} --snapshot')
        printf '%s\\n' '{"kind":"baseline","rev":3}' '#{message}' '#{advisory}' '{"kind":"baseline_complete","rev":3}' '{"kind":"caught_up","rev":3}'
        exec sleep 30
        ;;
      *) exit 2 ;;
    esac
    """)

    start_supervised!({HarklightWakes, db: db, retry_delays: [20, 40]})

    assert eventually(fn ->
             DB.query(db, "SELECT rev FROM harklight_feed_checkpoints") == {:ok, [[3]]}
           end)

    assert [["adv-1", "woken"]] =
             wake_rows(db, "SELECT advisoryId,outcome FROM harklight_bounces")
  end

  test "a failed message lookup leaves the advisory for the read path", ctx do
    %{db: db, main: main} = ctx
    worker = agent(db, "worker", main)
    conversation(db, @handle, worker)
    sent(db, @handle, "item-1")

    frame = advisory_frame(5, "item-1", "adv-1")
    failing = fn _messages, _id -> {:error, "harklight_message_lookup_failed"} end

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert ^frame = HarklightBounces.enrich(frame, %{}, failing)
      end)

    assert log =~ "adv-1"
    assert :ok = HarklightWakes.capture_feed(db, @handle, 5, [frame], :live)
    assert [[0]] = wake_rows(db, "SELECT count(*) FROM harklight_bounces")
    assert [[5]] = wake_rows(db, "SELECT rev FROM harklight_feed_checkpoints")

    assert {:ok, %{woken: ["adv-1"]}} =
             read(db, [item("item-1", @handle, advisories: [advisory("adv-1")])])
  end

  test "enrichment attaches the message and skips notices that are not bounces" do
    frame = advisory_frame(5, "item-1", "adv-1")
    fetch = fn %{}, "item-1" -> {:ok, item("item-1", @handle)} end

    assert %{"item" => %{"item_id" => "item-1"}} = HarklightBounces.enrich(frame, %{}, fetch)

    contradiction =
      put_in(frame, ["data", "advisory", "advisory_type"], "possible_contradictions")

    refute_called = fn _, _ -> flunk("no lookup for an ignored notice") end
    assert ^contradiction = HarklightBounces.enrich(contradiction, %{}, refute_called)
  end

  ## Items that are not open, not ours, or not bounces

  for state <- ["answered", "cleared", "expired", "superseded", "retracted"] do
    test "an item #{state} before capture closes without a wake and is acknowledged", ctx do
      %{db: db, main: main} = ctx
      worker = agent(db, "worker", main)
      conversation(db, @handle, worker)
      sent(db, @handle, "item-1")

      closed = item("item-1", @handle, terminal: %{"state" => unquote(state), "at_ms" => 9})

      assert {:ok, %{closed: ["adv-1"], woken: []}} =
               read(db, [%{closed | "advisories" => [advisory("adv-1")]}])

      assert [[0]] = wake_rows(db, "SELECT count(*) FROM wakes")

      assert [["closed", nil, nil]] =
               wake_rows(db, "SELECT outcome,recipient,wakeId FROM harklight_bounces")

      # The same closure on the feed path.
      assert :ok = capture(db, 9, [advisory_frame(9, "item-1", "adv-2")], closed)
      assert [[0]] = wake_rows(db, "SELECT count(*) FROM wakes")

      assert [[2]] =
               wake_rows(db, "SELECT count(*) FROM harklight_bounces WHERE outcome='closed'")

      %{calls: calls, runner: runner} = ack_runner()
      assert {:ok, false} = HarklightBounces.ack_owed(db, runner: runner)

      acked =
        for ["advisory-ack", "--item-id", "item-1", "--advisory-id", id, "--op-id", _] <-
              Agent.get(calls, & &1),
            do: id

      assert Enum.sort(acked) == ["adv-1", "adv-2"]
    end
  end

  test "items another tool sent under the same identity are left alone and not acknowledged",
       ctx do
    %{db: db, main: main} = ctx
    worker = agent(db, "worker", main)
    conversation(db, @handle, worker)
    sent(db, @handle, "ours")

    foreign = item("foreign", @handle, advisories: [advisory("adv-foreign")])
    other_session = item("ours", @other_handle, advisories: [advisory("adv-other")])
    ours = item("ours", @handle, advisories: [advisory("adv-ours")])

    assert {:ok, %{woken: ["adv-ours"]}} = read(db, [foreign, other_session, ours])
    assert [["adv-ours"]] = wake_rows(db, "SELECT advisoryId FROM harklight_bounces")

    assert :ok = capture(db, 4, [advisory_frame(4, "foreign", "adv-f2")], foreign)
    assert [[1]] = wake_rows(db, "SELECT count(*) FROM harklight_bounces")

    %{calls: calls, runner: runner} = ack_runner()
    assert {:ok, false} = HarklightBounces.ack_owed(db, runner: runner)

    assert [["adv-ours"]] =
             for(
               ["advisory-ack", _, _, "--advisory-id", id | _] <- Agent.get(calls, & &1),
               do: [id]
             )
  end

  test "an item migrated from before 0.2 is ours by its sender and legacy message ID", ctx do
    %{db: db, main: main} = ctx
    worker = agent(db, "worker", main)
    conversation(db, @handle, worker)

    {:ok, _} =
      DB.query(
        db,
        "INSERT INTO harklight_wake_requests(senderId,messageId,handle) VALUES('sender','legacy-9',?1)",
        [@handle]
      )

    migrated =
      item("server-item", @handle,
        advisories: [advisory("adv-1")],
        extra: %{"legacy_message_id" => "legacy-9"}
      )

    assert {:ok, %{woken: ["adv-1"]}} = read(db, [migrated])
    assert [["legacy-9"]] = wake_rows(db, "SELECT messageId FROM harklight_bounces")
  end

  test "possible_contradictions notices are ignored and never acknowledged", ctx do
    %{db: db, main: main} = ctx
    worker = agent(db, "worker", main)
    conversation(db, @handle, worker)
    sent(db, @handle, "item-1")

    notice = %{
      "advisory_id" => "adv-c",
      "advisory_type" => "possible_contradictions",
      "request_revision" => 1,
      "status" => "checked",
      "delivered" => false
    }

    message = item("item-1", @handle, advisories: [notice])

    assert {:ok, %{woken: [], closed: []}} = read(db, [message])

    frame = %{
      "kind" => "advisory",
      "rev" => 3,
      "data" => %{"item_id" => "item-1", "advisory" => notice}
    }

    assert :ok = capture(db, 3, [frame], message)

    assert [[0]] = wake_rows(db, "SELECT count(*) FROM harklight_bounces")
    assert [[0]] = wake_rows(db, "SELECT count(*) FROM wakes")
  end

  ## Who is woken

  test "an active receiver is woken, even when it is not the sender", ctx do
    %{db: db, main: main} = ctx
    sender = agent(db, "sender", main)
    receiver = agent(db, "receiver", main)
    conversation(db, @handle, sender, receiver: receiver)
    sent(db, @handle, "item-1")

    assert {:ok, %{woken: ["adv-1"]}} =
             read(db, [item("item-1", @handle, advisories: [advisory("adv-1")])])

    assert [[^receiver, prompt]] = wake_rows(db, "SELECT sessionKey,prompt FROM wakes")
    refute prompt =~ "nearest active session"
  end

  test "a transferred conversation wakes its current receiver", ctx do
    %{db: db, main: main} = ctx
    sender = agent(db, "sender", main)
    heir = agent(db, "heir", main)
    conversation(db, @handle, sender)
    sent(db, @handle, "item-1")

    {:ok, _} =
      DB.query(
        db,
        "UPDATE harklight_wake_handles SET currentReceiverSessionKey=?2 WHERE handle=?1",
        [@handle, heir]
      )

    assert {:ok, %{woken: ["adv-1"]}} =
             read(db, [item("item-1", @handle, advisories: [advisory("adv-1")])])

    assert [[^heir]] = wake_rows(db, "SELECT sessionKey FROM wakes")
  end

  test "the sender is woken when no receiver is recorded", ctx do
    %{db: db, main: main} = ctx
    sender = agent(db, "sender", main)
    conversation(db, @handle, sender)
    sent(db, @handle, "item-1")

    assert {:ok, _} = read(db, [item("item-1", @handle, advisories: [advisory("adv-1")])])
    assert [[^sender]] = wake_rows(db, "SELECT sessionKey FROM wakes")
  end

  test "a retired target with a living parent wakes the parent, and the text says why", ctx do
    %{db: db, main: main} = ctx
    po = agent(db, "po", main)
    worker = agent(db, "worker", po)
    conversation(db, @handle, worker)
    sent(db, @handle, "item-1")
    retire!(db, worker)

    assert {:ok, %{woken: ["adv-1"]}} =
             read(db, [item("item-1", @handle, advisories: [advisory("adv-1")])])

    assert [[^po, prompt]] = wake_rows(db, "SELECT sessionKey,prompt FROM wakes")

    assert prompt =~
             "The conversation's receiver worker (#{worker}) is retired, so this reaches you as the nearest active session above it, or Main when none is nearer."
  end

  test "a bounce goes to the parent even where retirement gave the chat to another session",
       ctx do
    %{db: db, main: main} = ctx
    po = agent(db, "po", main)
    worker = agent(db, "worker", po)
    heir = agent(db, "heir", main)
    conversation(db, @handle, worker)
    sent(db, @handle, "item-1")
    retire!(db, worker)

    # What retirement does for chat: the heir follows the conversation.
    {:ok, _} =
      DB.query(
        db,
        """
        INSERT INTO harklight_wake_follows(followId,sessionKey,kind,handle,senderId,messageId,state,createdAt)
        VALUES('follow-1',?1,'conversation',?2,NULL,'','open',1)
        """,
        [heir, @handle]
      )

    assert {:ok, _} = read(db, [item("item-1", @handle, advisories: [advisory("adv-1")])])
    assert [[^po]] = wake_rows(db, "SELECT sessionKey FROM wakes")
  end

  test "a retired parent chain walks up to the nearest living ancestor", ctx do
    %{db: db, main: main} = ctx
    po = agent(db, "po", main)
    middle = agent(db, "middle", po)
    worker = agent(db, "worker", middle)
    conversation(db, @handle, worker)
    sent(db, @handle, "item-1")
    for key <- [worker, middle], do: retire!(db, key)

    assert {:ok, _} = read(db, [item("item-1", @handle, advisories: [advisory("adv-1")])])
    assert [[^po]] = wake_rows(db, "SELECT sessionKey FROM wakes")
  end

  test "a retired PO with no parent goes to Main", ctx do
    %{db: db, main: main} = ctx
    po = agent(db, "po", nil)
    conversation(db, @handle, po)
    sent(db, @handle, "item-1")
    retire!(db, po)

    assert {:ok, _} = read(db, [item("item-1", @handle, advisories: [advisory("adv-1")])])
    assert [[^main]] = wake_rows(db, "SELECT sessionKey FROM wakes")
  end

  test "a receiver with no session record goes to the owner's Main", ctx do
    %{db: db, main: main} = ctx
    sender = agent(db, "sender", main)
    ghost = agent(db, "ghost", main)
    conversation(db, @handle, sender, receiver: ghost)
    sent(db, @handle, "item-1")
    remove_session_record!(db, ghost)

    assert {:ok, %{woken: ["adv-1"]}} =
             read(db, [item("item-1", @handle, advisories: [advisory("adv-1")])])

    assert [[^main, prompt]] = wake_rows(db, "SELECT sessionKey,prompt FROM wakes")

    assert prompt =~
             "The conversation's receiver #{ghost} has no session record, so this reaches you"
  end

  test "a parent loop of retired sessions ends at Main", ctx do
    %{db: db, main: main} = ctx
    a = agent(db, "loop-a", main)
    b = agent(db, "loop-b", a)
    {:ok, _} = DB.query(db, "UPDATE sessions SET spawnedBy=?2 WHERE sessionKey=?1", [a, b])
    conversation(db, @handle, a)
    sent(db, @handle, "item-1")
    for key <- [a, b], do: retire!(db, key)

    assert {:ok, _} = read(db, [item("item-1", @handle, advisories: [advisory("adv-1")])])
    assert [[^main]] = wake_rows(db, "SELECT sessionKey FROM wakes")
  end

  test "a living parent on another host is woken", ctx do
    %{db: db, main: main} = ctx
    po = agent(db, "po", main, host: "elsewhere")
    worker = agent(db, "worker", po)
    conversation(db, @handle, worker)
    sent(db, @handle, "item-1")
    retire!(db, worker)

    assert {:ok, %{woken: ["adv-1"]}} =
             read(db, [item("item-1", @handle, advisories: [advisory("adv-1")])])

    assert [[^po]] = wake_rows(db, "SELECT sessionKey FROM wakes")
  end

  test "a conversation of another host is not heard here", ctx do
    %{db: db, main: main} = ctx
    worker = agent(db, "worker", main)
    conversation(db, @handle, worker, host: "elsewhere")
    sent(db, @handle, "item-1")

    assert {:ok, %{woken: []}} =
             read(db, [item("item-1", @handle, advisories: [advisory("adv-1")])])

    assert [[0]] = wake_rows(db, "SELECT count(*) FROM harklight_bounces")
  end

  test "with no active session to wake the bounce stays unrecorded and unacknowledged", ctx do
    %{db: db, main: main} = ctx
    po = agent(db, "po", nil)
    conversation(db, @handle, po)
    sent(db, @handle, "item-1")
    retire!(db, po)
    retire!(db, main)

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert {:ok, %{unroutable: ["adv-1"], woken: []}} =
                 read(db, [item("item-1", @handle, advisories: [advisory("adv-1")])])
      end)

    assert log =~ "adv-1"
    assert [[0]] = wake_rows(db, "SELECT count(*) FROM harklight_bounces")
  end

  ## Many at once

  test "30 overdue bounces for one agent arrive as one wake", ctx do
    %{db: db, main: main} = ctx
    worker = agent(db, "worker", main)
    conversation(db, @handle, worker)

    messages =
      for n <- 1..30 do
        sent(db, @handle, "item-#{n}")
        item("item-#{n}", @handle, advisories: [advisory("adv-#{n}")], title: "Request #{n}")
      end

    assert {:ok, %{woken: woken}} = read(db, messages)
    assert length(woken) == 30
    assert [[^worker, prompt]] = wake_rows(db, "SELECT sessionKey,prompt FROM wakes")
    assert length(String.split(prompt, "\n- ")) - 1 == 30
    assert prompt =~ "Each of these 30 messages had not been opened when it bounced."
  end

  test "30 overdue bounces for retired targets arrive at their parent as one wake", ctx do
    %{db: db, main: main} = ctx
    po = agent(db, "po", main)

    messages =
      for {handle, name} <- [{@handle, "w1"}, {@other_handle, "w2"}], reduce: [] do
        acc ->
          worker = agent(db, name, po)
          conversation(db, handle, worker)
          retire!(db, worker)

          acc ++
            for n <- 1..15 do
              sent(db, handle, "#{name}-item-#{n}")
              item("#{name}-item-#{n}", handle, advisories: [advisory("#{name}-adv-#{n}")])
            end
      end

    assert {:ok, %{woken: woken}} = read(db, messages)
    assert length(woken) == 30
    assert [[^po, prompt]] = wake_rows(db, "SELECT sessionKey,prompt FROM wakes")
    assert length(String.split(prompt, "\n- ")) - 1 == 30
  end

  test "a feed baseline of 30 overdue bounces is one wake", ctx do
    %{db: db, main: main} = ctx
    worker = agent(db, "worker", main)
    conversation(db, @handle, worker)

    frames =
      for n <- 1..30,
          frame <- [
            message_frame(2 * n - 1, item("item-#{n}", @handle)),
            advisory_frame(2 * n, "item-#{n}", "adv-#{n}")
          ] do
        if match?(%{"kind" => "message"}, frame), do: sent(db, @handle, "item-#{n}")
        frame
      end

    assert :ok = HarklightWakes.capture_feed(db, @handle, 60, frames, :baseline)
    assert [[1]] = wake_rows(db, "SELECT count(*) FROM wakes")
    assert [[30]] = wake_rows(db, "SELECT count(*) FROM harklight_bounces")
  end

  test "more than a page of bounces are split into wakes due together", ctx do
    %{db: db, main: main} = ctx
    worker = agent(db, "worker", main)
    conversation(db, @handle, worker)

    messages =
      for n <- 1..85 do
        sent(db, @handle, "item-#{n}")
        item("item-#{n}", @handle, advisories: [advisory("adv-#{n}")])
      end

    assert {:ok, _} = read(db, messages)
    assert [[3]] = wake_rows(db, "SELECT count(*) FROM wakes")
    assert [[1]] = wake_rows(db, "SELECT count(DISTINCT deliveryRule) FROM wakes")
    assert [["notice-batching-v1 r2"]] = wake_rows(db, "SELECT DISTINCT deliveryRule FROM wakes")
  end

  ## What the wake says

  test "the full bounce wake says only what was true when it bounced and resends nothing", ctx do
    %{db: db, main: main} = ctx
    worker = agent(db, "worker", main)
    conversation(db, @handle, worker)
    sent(db, @handle, "item-1")

    advisory =
      advisory("adv-1",
        extra: %{
          "evaluated_at_ms" => 1_700_000_000_000,
          "bounce_after_days" => 3,
          "level_name" => "Important"
        }
      )

    assert {:ok, _} =
             read(db, [item("item-1", @handle, advisories: [advisory], title: "Deploy approval")])

    assert [[prompt]] = wake_rows(db, "SELECT prompt FROM wakes")

    assert prompt ==
             "Harklight bounce. This message had not been opened when it bounced.\n" <>
               "- \"Deploy approval\" (message item-1, conversation #{@handle}, started by #{worker}): " <>
               "it bounced at 2023-11-14T22:13:20.000Z (bounce interval 3 days, level Important).\n" <>
               "Decide whether it is still valid and worth resending, and whether its importance warrants a higher priority. " <>
               "To send it again use `tightbeam harklight-send`; to withdraw it use `tightbeam harklight-retract --message <message id>`. " <>
               "Tightbeam has not resent anything and will not."

    refute prompt =~ "never saw"
    refute prompt =~ "inbox"

    assert [["input-needed", "process:tightbeam"]] =
             wake_rows(db, "SELECT class,origin FROM wakes")
  end

  test "a soft bounce says it was opened but not acted on, as of when it bounced", ctx do
    %{db: db, main: main} = ctx
    worker = agent(db, "worker", main)
    conversation(db, @handle, worker)
    sent(db, @handle, "item-1")

    soft =
      advisory("adv-1", type: "soft_bounce", extra: %{"evaluated_at_ms" => 1_700_000_000_000})

    assert {:ok, %{woken: ["adv-1"]}} =
             read(db, [item("item-1", @handle, advisories: [soft], title: "Plan")])

    assert [[prompt]] = wake_rows(db, "SELECT prompt FROM wakes")

    assert prompt ==
             "Harklight soft bounce. This message had been opened but not acted on when it bounced.\n" <>
               "- \"Plan\" (message item-1, conversation #{@handle}, started by #{worker}): " <>
               "it bounced at 2023-11-14T22:13:20.000Z (bounce interval 2 days, level Normal).\n" <>
               "Decide whether it is still valid and worth resending, and whether its importance warrants a higher priority. " <>
               "To send it again use `tightbeam harklight-send`; to withdraw it use `tightbeam harklight-retract --message <message id>`. " <>
               "Tightbeam has not resent anything and will not."

    assert [["soft"]] = wake_rows(db, "SELECT kind FROM harklight_bounces")
  end

  test "the later full_bounce type is handled as a full bounce", ctx do
    %{db: db, main: main} = ctx
    worker = agent(db, "worker", main)
    conversation(db, @handle, worker)
    sent(db, @handle, "item-1")

    assert {:ok, %{woken: ["adv-1"]}} =
             read(db, [
               item("item-1", @handle, advisories: [advisory("adv-1", type: "full_bounce")])
             ])

    assert [["full"]] = wake_rows(db, "SELECT kind FROM harklight_bounces")
  end

  test "any other notice type is ignored: no wake, no record, no acknowledgment", ctx do
    %{db: db, main: main} = ctx
    worker = agent(db, "worker", main)
    conversation(db, @handle, worker)
    sent(db, @handle, "item-1")

    other = advisory("adv-1", type: "opened_interval_elapsed")
    message = item("item-1", @handle, advisories: [other])

    assert {:ok, %{woken: [], closed: []}} = read(db, [message])

    frame = %{
      "kind" => "advisory",
      "rev" => 3,
      "data" => %{"item_id" => "item-1", "advisory" => other}
    }

    assert :ok = capture(db, 3, [frame], message)
    assert [[0]] = wake_rows(db, "SELECT count(*) FROM harklight_bounces")
    assert [[0]] = wake_rows(db, "SELECT count(*) FROM wakes")
  end

  test "full and soft bounces for one agent are one wake in two sections", ctx do
    %{db: db, main: main} = ctx
    worker = agent(db, "worker", main)
    conversation(db, @handle, worker)
    sent(db, @handle, "a")
    sent(db, @handle, "b")

    assert {:ok, _} =
             read(db, [
               item("a", @handle, advisories: [advisory("adv-a")]),
               item("b", @handle, advisories: [advisory("adv-b", type: "soft_bounce")])
             ])

    assert [[prompt]] = wake_rows(db, "SELECT prompt FROM wakes")
    [full, soft] = String.split(prompt, "\n\n")
    assert full =~ "had not been opened when it bounced"
    refute full =~ "acted on"
    assert soft =~ "had been opened but not acted on when it bounced"
    refute soft =~ "had not been opened"
  end

  test "a moot advisory closes without a wake and is acknowledged, whatever the item says", ctx do
    %{db: db, main: main} = ctx
    worker = agent(db, "worker", main)
    conversation(db, @handle, worker)
    sent(db, @handle, "item-1")
    moot = advisory("adv-1", extra: %{"moot" => true})

    assert {:ok, %{closed: ["adv-1"], woken: []}} =
             read(db, [item("item-1", @handle, advisories: [moot])])

    assert [[0]] = wake_rows(db, "SELECT count(*) FROM wakes")
    assert [["closed"]] = wake_rows(db, "SELECT outcome FROM harklight_bounces")
    %{calls: calls, runner: runner} = ack_runner()
    assert {:ok, false} = HarklightBounces.ack_owed(db, runner: runner)
    assert [_] = for(["advisory-ack" | _] = call <- Agent.get(calls, & &1), do: call)
  end

  test "a bounced item with no terminal is woken even if Harklight closed it in the inbox", ctx do
    %{db: db, main: main} = ctx
    worker = agent(db, "worker", main)
    conversation(db, @handle, worker)
    sent(db, @handle, "item-1")
    # Inbox closure is not a terminal: the agent row keeps terminal null.
    message =
      item("item-1", @handle, advisories: [advisory("adv-1")], extra: %{"inbox" => "closed"})

    assert {:ok, %{woken: ["adv-1"]}} = read(db, [message])
  end

  test "a bounce neither ends the conversation nor stops later chat", ctx do
    %{db: db, main: main} = ctx
    worker = agent(db, "worker", main)
    conversation(db, @handle, worker)
    sent(db, @handle, "request")

    assert :ok = capture(db, 5, [advisory_frame(5, "request", "adv-1")], item("request", @handle))
    assert [["active"]] = wake_rows(db, "SELECT state FROM harklight_wake_handles")

    chat = %{
      "kind" => "entry",
      "rev" => 6,
      "data" => %{
        "item_id" => "request",
        "entry_id" => "chat-1",
        "request_revision" => 1,
        "kind" => "reply",
        "author" => "person",
        "text" => "Reply"
      }
    }

    assert :ok = HarklightWakes.capture_feed(db, @handle, 6, [chat], :live)

    assert [[^worker]] =
             wake_rows(
               db,
               "SELECT sessionKey FROM harklight_wake_deliveries WHERE eventId LIKE 'v2_%'"
             )

    assert [["active"]] = wake_rows(db, "SELECT state FROM harklight_wake_handles")

    assert [[0]] =
             wake_rows(db, "SELECT count(*) FROM harklight_wake_follows WHERE state='ended'")
  end

  test "open bounces on messages Tightbeam did not send are counted and left alone", ctx do
    %{db: db, main: main} = ctx
    worker = agent(db, "worker", main)
    conversation(db, @handle, worker)
    sent(db, @handle, "ours")

    messages = [
      item("ours", @handle, advisories: [advisory("adv-ours")]),
      item("foreign-1", @handle, advisories: [advisory("adv-f1")]),
      item("foreign-2", @other_handle, advisories: [advisory("adv-f2", type: "soft_bounce")]),
      item("foreign-3", @handle,
        advisories: [advisory("adv-f3")],
        terminal: %{"state" => "answered", "at_ms" => 1}
      ),
      item("foreign-4", @handle, advisories: [advisory("adv-f4", extra: %{"moot" => true})])
    ]

    assert {:ok, %{woken: ["adv-ours"], left_alone_open: left}} = read(db, messages)
    assert Enum.sort(left) == ["adv-f1", "adv-f2"]
    assert [["adv-ours"]] = wake_rows(db, "SELECT advisoryId FROM harklight_bounces")
  end

  test "a title cannot break the wake text", ctx do
    %{db: db, main: main} = ctx
    worker = agent(db, "worker", main)
    conversation(db, @handle, worker)
    sent(db, @handle, "item-1")
    title = "Line one\nLine \"two\"" <> String.duplicate("x", 300)

    assert {:ok, _} =
             read(db, [item("item-1", @handle, advisories: [advisory("adv-1")], title: title)])

    assert [[prompt]] = wake_rows(db, "SELECT prompt FROM wakes")
    assert prompt =~ ~s("Line one Line 'two'xxx)
    assert prompt |> String.split("\n") |> Enum.count(&String.starts_with?(&1, "- ")) == 1
  end

  ## Acknowledgment

  test "the read pass marks nothing delivered and sends nothing", ctx do
    %{db: db, main: main} = ctx
    worker = agent(db, "worker", main)
    conversation(db, @handle, worker)
    sent(db, @handle, "item-1")

    %{calls: calls, runner: runner} =
      ack_runner(
        pages: %{
          nil => {[item("item-1", @handle, advisories: [advisory("adv-1")])], "p2"},
          "p2" => {[], nil}
        }
      )

    assert {:ok, %{woken: ["adv-1"]}} = HarklightBounces.read_pass(db, runner: runner)
    assert [["messages"], ["messages", "--page", "p2"]] = Agent.get(calls, & &1)
    assert [[nil]] = wake_rows(db, "SELECT ackCompletedAt FROM harklight_bounces")
  end

  test "a crash between the wake and the acknowledgment acknowledges later and wakes no more",
       ctx do
    %{db: db, main: main} = ctx
    worker = agent(db, "worker", main)
    conversation(db, @handle, worker)
    sent(db, @handle, "item-1")
    assert {:ok, _} = read(db, [item("item-1", @handle, advisories: [advisory("adv-1")])])

    # Nothing acknowledged yet: the gateway went down here. A new one finds the
    # owed row, acknowledges it and leaves the wake alone.
    %{calls: calls, runner: runner} = ack_runner()
    start_supervised!({HarklightBounces, db: db, runner: runner, read_interval_ms: 3_600_000})

    assert eventually(fn ->
             DB.query(db, "SELECT ackOutcome FROM harklight_bounces") == {:ok, [["acknowledged"]]}
           end)

    assert {:ok, %{woken: []}} =
             read(db, [item("item-1", @handle, advisories: [advisory("adv-1")])])

    assert [[1]] = wake_rows(db, "SELECT count(*) FROM wakes")

    assert [{"advisory-ack", "adv-1"}] =
             for(
               ["advisory-ack", _, _, "--advisory-id", id | _] <- Agent.get(calls, & &1),
               do: {"advisory-ack", id}
             )
  end

  test "a restart changes nothing: no second wake, no second acknowledgment", ctx do
    %{db: db, main: main} = ctx
    worker = agent(db, "worker", main)
    conversation(db, @handle, worker)
    sent(db, @handle, "item-1")
    messages = [item("item-1", @handle, advisories: [advisory("adv-1")])]

    %{calls: calls, runner: runner} = ack_runner(pages: %{nil => {messages, nil}})
    opts = [db: db, runner: runner, read_interval_ms: 3_600_000, read_spacing_ms: 1]

    start_supervised!({HarklightBounces, opts})

    assert eventually(fn ->
             DB.query(db, "SELECT ackOutcome FROM harklight_bounces") == {:ok, [["acknowledged"]]}
           end)

    assert :ok = stop_supervised(HarklightBounces)
    start_supervised!({HarklightBounces, opts})
    assert eventually(fn -> Enum.count(Agent.get(calls, & &1), &(&1 == ["messages"])) == 2 end)
    Process.sleep(100)

    assert [[1]] = wake_rows(db, "SELECT count(*) FROM wakes")
    assert [[1]] = wake_rows(db, "SELECT count(*) FROM harklight_bounces")
    assert 1 == Enum.count(Agent.get(calls, & &1), &match?(["advisory-ack" | _], &1))
  end

  test "a lost acknowledgment reply is retried with the same operation and wakes no more", ctx do
    %{db: db, main: main} = ctx
    worker = agent(db, "worker", main)
    conversation(db, @handle, worker)
    sent(db, @handle, "item-1")
    assert {:ok, _} = read(db, [item("item-1", @handle, advisories: [advisory("adv-1")])])

    %{calls: calls, runner: runner} = ack_runner(ack: :lose_first_reply)
    assert {:ok, true} = HarklightBounces.ack_owed(db, runner: runner)
    assert [[nil]] = wake_rows(db, "SELECT ackCompletedAt FROM harklight_bounces")
    assert {:ok, false} = HarklightBounces.ack_owed(db, runner: runner)
    assert [["acknowledged"]] = wake_rows(db, "SELECT ackOutcome FROM harklight_bounces")

    ops = for ["advisory-ack", _, _, _, _, "--op-id", op] <- Agent.get(calls, & &1), do: op
    retried = for ["retry", "--op-id", op, "--journal-id", _] <- Agent.get(calls, & &1), do: op
    assert [op] = ops
    assert op in retried
    assert [[1]] = wake_rows(db, "SELECT count(*) FROM wakes")
  end

  test "an acknowledgment is retried by the worker until Harklight confirms it", ctx do
    %{db: db, main: main} = ctx
    worker = agent(db, "worker", main)
    conversation(db, @handle, worker)
    sent(db, @handle, "item-1")
    assert {:ok, _} = read(db, [item("item-1", @handle, advisories: [advisory("adv-1")])])

    %{runner: runner} = ack_runner(ack: {:unknown_times, 2})

    start_supervised!(
      {HarklightBounces, db: db, runner: runner, ack_delays: [10], read_interval_ms: 3_600_000}
    )

    assert eventually(fn ->
             DB.query(db, "SELECT ackOutcome FROM harklight_bounces") == {:ok, [["acknowledged"]]}
           end)
  end

  test "a definite refusal takes a new key and a vanished advisory is let go", ctx do
    %{db: db, main: main} = ctx
    worker = agent(db, "worker", main)
    conversation(db, @handle, worker)
    sent(db, @handle, "a")
    sent(db, @handle, "b")

    assert {:ok, _} =
             read(db, [
               item("a", @handle, advisories: [advisory("adv-a")]),
               item("b", @handle, advisories: [advisory("adv-b")])
             ])

    [[first_op]] = wake_rows(db, "SELECT ackOpId FROM harklight_bounces WHERE advisoryId='adv-a'")
    %{runner: runner} = ack_runner(ack: %{"adv-a" => :refused, "adv-b" => :not_found})
    assert {:ok, true} = HarklightBounces.ack_owed(db, runner: runner)

    assert [[second_op, nil, nil]] =
             wake_rows(
               db,
               "SELECT ackOpId,ackJournalId,ackCompletedAt FROM harklight_bounces WHERE advisoryId='adv-a'"
             )

    refute second_op == first_op

    assert [["gone"]] =
             wake_rows(db, "SELECT ackOutcome FROM harklight_bounces WHERE advisoryId='adv-b'")
  end

  test "no resend: only reads and acknowledgments ever reach the Agent", ctx do
    %{db: db, main: main} = ctx
    worker = agent(db, "worker", main)
    conversation(db, @handle, worker)
    sent(db, @handle, "item-1")

    %{calls: calls, runner: runner} =
      ack_runner(
        pages: %{nil => {[item("item-1", @handle, advisories: [advisory("adv-1")])], nil}}
      )

    assert {:ok, _} = HarklightBounces.read_pass(db, runner: runner)
    assert {:ok, false} = HarklightBounces.ack_owed(db, runner: runner)

    commands = for [command | _] <- Agent.get(calls, & &1), do: command
    assert Enum.all?(commands, &(&1 in ["messages", "journal-id", "retry", "advisory-ack"]))
    refute Enum.any?(commands, &(&1 in ["send", "revise", "retract", "reply"]))
  end

  ## The read pass and its worker

  test "the read pass does nothing when Tightbeam has sent nothing", ctx do
    %{db: db} = ctx
    %{calls: calls, runner: runner} = ack_runner()
    assert {:ok, :idle} = HarklightBounces.read_pass(db, runner: runner)
    assert [] = Agent.get(calls, & &1)
  end

  test "a read refuses a page loop and an unreadable answer", ctx do
    %{db: db, main: main} = ctx
    worker = agent(db, "worker", main)
    conversation(db, @handle, worker)
    sent(db, @handle, "item-1")

    %{runner: looping} = ack_runner(pages: %{nil => {[], "p"}, "p" => {[], "p"}})

    assert {:error, "harklight_messages_paging_invalid"} =
             HarklightBounces.read_pass(db, runner: looping)

    failing = fn _ -> {"boom", 1} end

    assert {:error, "harklight_messages_unavailable"} =
             HarklightBounces.read_pass(db, runner: failing)

    assert [[0]] = wake_rows(db, "SELECT count(*) FROM harklight_bounces")
  end

  test "the worker reads at start, once for a burst of baselines, and acknowledges", ctx do
    %{db: db, main: main} = ctx
    worker = agent(db, "worker", main)
    conversation(db, @handle, worker)
    sent(db, @handle, "item-1")

    %{calls: calls, runner: runner} =
      ack_runner(
        pages: %{nil => {[item("item-1", @handle, advisories: [advisory("adv-1")])], nil}}
      )

    start_supervised!(
      {HarklightBounces,
       db: db, runner: runner, read_interval_ms: 3_600_000, read_spacing_ms: 150}
    )

    assert eventually(fn ->
             DB.query(db, "SELECT ackOutcome FROM harklight_bounces") == {:ok, [["acknowledged"]]}
           end)

    reads = fn -> Enum.count(Agent.get(calls, & &1), &(&1 == ["messages"])) end
    assert reads.() == 1

    for _ <- 1..10, do: HarklightBounces.captured(:baseline, [])
    assert eventually(fn -> reads.() == 2 end)
    Process.sleep(300)
    assert reads.() == 2
    assert [[1]] = wake_rows(db, "SELECT count(*) FROM wakes")
  end

  ## Support

  defp agent(db, name, parent, opts \\ []) do
    key = "agent:test:#{name}"

    Org.create(db, %{
      session_key: key,
      display_name: name,
      owner_user_id: "owner",
      origin: "user:owner",
      spawned_by: parent,
      archetype: "default",
      host: Keyword.get(opts, :host, @host),
      harness: "codex",
      provider: "openai",
      model: Model.new("fable")
    })

    key
  end

  defp retire!(db, key) do
    {:ok, _} = DB.query(db, "UPDATE sessions SET state='retired' WHERE sessionKey=?1", [key])
  end

  # A session the org has no record of: the conversation's recorded receiver
  # has no row.
  defp remove_session_record!(db, key) do
    :ok = DB.execute(db, "PRAGMA foreign_keys=OFF")

    try do
      {:ok, _} =
        DB.transaction(db, fn txn ->
          Tightbeam.DB.Txn.q(txn, "DELETE FROM sessions WHERE sessionKey=?1", [key])
        end)
    after
      :ok = DB.execute(db, "PRAGMA foreign_keys=ON")
    end
  end

  defp conversation(db, handle, origin, opts \\ []) do
    {:ok, _} =
      DB.query(
        db,
        """
        INSERT INTO harklight_wake_handles(handle,sessionKey,host,state,createdAt,updatedAt,currentReceiverSessionKey)
        VALUES(?1,?2,?3,'active',1,1,?4)
        """,
        [handle, origin, Keyword.get(opts, :host, @host), opts[:receiver]]
      )
  end

  defp sent(db, handle, id) do
    {:ok, _} =
      DB.query(
        db,
        "INSERT INTO harklight_wake_requests(senderId,messageId,handle) VALUES('sender',?1,?2)",
        [id, handle]
      )
  end

  defp item(id, handle, opts \\ []) do
    base = %{
      "item_id" => id,
      "rev" => 1,
      "sender" => "sender",
      "session" => handle,
      "revision" => 1,
      "message" => %{
        "title" => Keyword.get(opts, :title, "Request #{id}"),
        "message_type" => "request"
      },
      "files" => [],
      "seen" => false,
      "advisories" => Keyword.get(opts, :advisories, [])
    }

    base = if t = opts[:terminal], do: Map.put(base, "terminal", t), else: base
    Map.merge(base, Keyword.get(opts, :extra, %{}))
  end

  defp advisory(id, opts \\ []) do
    %{
      "advisory_id" => id,
      "advisory_type" => Keyword.get(opts, :type, "unseen_interval_elapsed"),
      "delivered" => Keyword.get(opts, :delivered, false),
      "request_revision" => 1,
      "text" => "Harklight has no record that you saw this message.",
      "accepted_at_ms" => 1_699_000_000_000,
      "due_at_ms" => 1_699_500_000_000,
      "evaluated_at_ms" => 1_699_600_000_000,
      "level_name" => "Normal",
      "bounce_after_days" => 2,
      "decided_at_rev" => 4
    }
    |> Map.merge(Keyword.get(opts, :extra, %{}))
  end

  defp advisory_frame(rev, item_id, advisory_id, opts \\ []) do
    %{
      "kind" => "advisory",
      "rev" => rev,
      "data" => %{"item_id" => item_id, "advisory" => advisory(advisory_id, opts)}
    }
  end

  defp message_frame(rev, item),
    do: %{"kind" => "message", "rev" => rev, "data" => Map.put(item, "rev", rev)}

  # A live feed batch as the listener submits it: advisory frames carry the
  # message they concern.
  defp capture(db, rev, frames, item) do
    frames =
      Enum.map(frames, fn
        %{"kind" => "advisory"} = frame -> Map.put(frame, "item", item)
        frame -> frame
      end)

    HarklightWakes.capture_feed(db, @handle, rev, frames, :live)
  end

  defp read(db, messages) do
    candidates =
      for message <- messages, advisory <- message["advisories"] do
        %{advisory: advisory, item: message, item_id: message["item_id"], handle: nil}
      end

    DB.transaction(db, fn txn -> HarklightBounces.process_in_txn(txn, candidates, :read) end)
  end

  defp wake_rows(db, sql, params \\ []) do
    {:ok, rows} = DB.query(db, sql, params)
    rows
  end

  # A scripted `harklight-agent`. `pages` serves the messages read; `ack`
  # scripts acknowledgment outcomes.
  defp ack_runner(opts \\ []) do
    {:ok, calls} = Agent.start_link(fn -> [] end)
    {:ok, state} = Agent.start_link(fn -> %{sent: MapSet.new(), unknowns: 0} end)
    pages = Keyword.get(opts, :pages, %{nil => {[], nil}})
    ack = Keyword.get(opts, :ack, :ok)

    runner = fn argv ->
      Agent.update(calls, &(&1 ++ [argv]))

      case argv do
        ["messages"] ->
          page(pages, nil)

        ["messages", "--page", token] ->
          page(pages, token)

        ["journal-id"] ->
          frame(%{kind: "journal", journal_id: "j1"})

        ["retry", "--op-id", op, "--journal-id", "j1"] ->
          retry(state, op)

        ["advisory-ack", "--item-id", item, "--advisory-id", id, "--op-id", op] ->
          acknowledge(state, ack, item, id, op)
      end
    end

    %{calls: calls, runner: runner}
  end

  defp page(pages, token) do
    {messages, next} = Map.fetch!(pages, token)
    body = %{"rev" => 9, "messages" => messages}
    body = if next, do: Map.put(body, "next_page", next), else: body
    {JSON.encode!(body) <> "\n", 0}
  end

  defp retry(state, op) do
    if MapSet.member?(Agent.get(state, & &1.sent), op),
      do: committed(op, Agent.get(state, & &1.sent_advisories)[op]),
      else: frame(%{kind: "operation_absent", op_id: op, journal_id: "j1"}, 1)
  end

  defp acknowledge(state, ack, _item, id, op) do
    Agent.update(state, fn s ->
      s
      |> Map.update(:sent_advisories, %{op => id}, &Map.put(&1, op, id))
      |> Map.update!(:sent, &MapSet.put(&1, op))
    end)

    case behavior(state, ack, id) do
      :ok ->
        committed(op, id)

      :lose ->
        frame(%{kind: "outcome_unknown", operation: "advisory-ack", op_id: op, status: 503}, 7)

      :refused ->
        frame(
          %{
            kind: "refused",
            operation: "advisory-ack",
            op_id: op,
            status: 409,
            error: "conflict"
          },
          2
        )

      :not_found ->
        frame(
          %{
            kind: "refused",
            operation: "advisory-ack",
            op_id: op,
            status: 404,
            error: "not_found"
          },
          2
        )
    end
  end

  defp behavior(_state, :ok, _id), do: :ok
  defp behavior(_state, %{} = per_advisory, id), do: Map.get(per_advisory, id, :ok)

  defp behavior(state, :lose_first_reply, _id) do
    if Agent.get_and_update(state, fn s -> {s.unknowns, %{s | unknowns: s.unknowns + 1}} end) == 0,
      do: :lose,
      else: :ok
  end

  defp behavior(state, {:unknown_times, n}, _id) do
    if Agent.get_and_update(state, fn s -> {s.unknowns, %{s | unknowns: s.unknowns + 1}} end) < n,
      do: :lose,
      else: :ok
  end

  defp committed(op, id) do
    frame(%{
      kind: "committed",
      operation: "advisory-ack",
      op_id: op,
      response: %{advisory_id: id, delivered: true, already_delivered: false}
    })
  end

  defp frame(value, status \\ 0), do: {JSON.encode!(value) <> "\n", status}

  defp fake_agent!(body) do
    directory =
      Path.join(System.tmp_dir!(), "harklight-bounce-agent-#{System.unique_integer([:positive])}")

    File.mkdir_p!(directory)
    executable = Path.join(directory, "harklight-agent")
    File.write!(executable, "#!/bin/sh\n" <> body)
    File.chmod!(executable, 0o755)
    previous = System.get_env("PATH")
    System.put_env("PATH", Enum.join([directory, previous] |> Enum.reject(&is_nil/1), ":"))

    on_exit(fn ->
      if previous, do: System.put_env("PATH", previous), else: System.delete_env("PATH")
      File.rm_rf!(directory)
    end)
  end

  defp eventually(fun, attempts \\ 300) do
    cond do
      fun.() -> true
      attempts == 0 -> false
      true -> Process.sleep(20) && eventually(fun, attempts - 1)
    end
  end
end
