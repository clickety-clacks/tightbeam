defmodule Tightbeam.WorkItemBracketsTest do
  @moduledoc """
  The work-item-brackets-v1 required proofs (fail-on-revert). Each test names
  the proof number it discharges; see the spec §Required proofs.
  """
  use Tightbeam.TestCase, async: false
  alias Tightbeam.Model

  alias Tightbeam.{
    Assignments,
    ConnRegistry,
    DB,
    Dispatch,
    Gateway,
    Ledger,
    NoticeBatcher,
    Org,
    Projection,
    RailRemedy,
    Rules,
    Wakes,
    WorkItems,
    WorkState
  }

  alias Tightbeam.DB.Txn

  # Records the doorbells one subscriber actually received, drained by a call.
  #
  # The drain is what makes the assertions timing-free. `ConnRegistry` delivers
  # with a bare `send` from inside its own `handle_call`, so a doorbell is in
  # this process's mailbox before the publishing verb returns to the test; the
  # `drain/1` call the test issues next is therefore enqueued behind it, and a
  # GenServer serves its mailbox in order. Whatever was published has been
  # recorded by the time `drain/1` answers.
  #
  # This replaced a `spawn`ed process that forwarded each push onward to the
  # test. That hop was unsynchronized: a verb returning proved only that the
  # doorbell had reached the relay, never that the relay had been scheduled to
  # pass it on, so every `refute_receive` across it could pass on a loaded
  # machine simply because the relay had not run yet — a false PASS on the
  # assertions that exist to catch a doorbell being emitted when it must not be.
  defmodule Observer do
    use GenServer

    def start_link(_opts), do: GenServer.start_link(__MODULE__, [])

    @doc "Every payload received since the last drain, oldest first."
    def drain(observer), do: GenServer.call(observer, :drain)

    @impl true
    def init(received), do: {:ok, received}

    @impl true
    def handle_call(:drain, _from, received), do: {:reply, Enum.reverse(received), []}

    @impl true
    def handle_info({:push, payload}, received), do: {:noreply, [payload | received]}
  end

  setup do
    previous_item_wait_flag = Application.get_env(:tightbeam, :work_item_waits_enabled)
    Application.put_env(:tightbeam, :work_item_waits_enabled, true)
    on_exit(fn ->
      if is_nil(previous_item_wait_flag),
        do: Application.delete_env(:tightbeam, :work_item_waits_enabled),
        else: Application.put_env(:tightbeam, :work_item_waits_enabled, previous_item_wait_flag)
    end)
    db = :"brackets_db_#{System.unique_integer([:positive])}"
    start_supervised!({DB, path: ":memory:", name: db})
    start_supervised!({ConnRegistry, name: ConnRegistry})
    start_supervised!({Tightbeam.NoticeBatcherFixture.LaneStub, Tightbeam.LaneManager})

    :ok = Tightbeam.Schema.ensure_all(db)

    register_hosts(db, %{
      "lab1" => %{
        ssh: nil,
        base_dir: Application.fetch_env!(:tightbeam, :base_dir),
        cli_bin: nil
      }
    })

    {:ok, _} =
      DB.query(
        db,
        "INSERT INTO users (userId, isAdmin, createdAt) VALUES ('flynn', 1, 1), ('dana', 0, 1), ('eve', 0, 1)"
      )

    # Owners are always users; bracket wakes target the owner's personal session.
    flynn_main = session(db, Org.personal_session_key("flynn"), "flynn")
    _dana_main = session(db, Org.personal_session_key("dana"), "dana")
    holder = session(db, "holder", "flynn")
    dsession = session(db, "dsession", "dana")

    base = Path.join(System.tmp_dir!(), "tb-brackets-#{System.unique_integer([:positive])}")
    File.mkdir_p!(base)
    handlers = Gateway.handlers(%{db: db, wake_tick_ms: 1_000})
    Tightbeam.TerminalReactionFixture.load_work_items!(base, Map.keys(handlers))
    on_exit(fn -> File.rm_rf!(base) end)

    %{
      db: db,
      law_base: base,
      handlers: handlers,
      flynn_main: flynn_main,
      holder: holder,
      dsession: dsession
    }
  end

  test "item waits default off refuses commands without storing wakes or links", ctx do
    Application.delete_env(:tightbeam, :work_item_waits_enabled)
    refute Tightbeam.WorkItemWaits.enabled?()
    item = create(ctx, {:user, "flynn"}, %{title: "Flag off"})
    before = DB.query(ctx.db, "SELECT COUNT(*) FROM wakes", [])
    for verb <- ["work-item-wait", "work-item-wait-withdraw"] do
      assert %{code: "feature_disabled"} =
        ctx.handlers[verb].(work_item_call(verb, {:user, "flynn"}, %{work_item_id: item.id}))
    end
    assert DB.query(ctx.db, "SELECT COUNT(*) FROM wakes", []) == before
    assert {:ok, [[0]]} = DB.query(ctx.db, "SELECT COUNT(*) FROM work_item_waits", [])
    result = ctx.handlers["work-item-get"].(work_item_call("work-item-get", {:user, "flynn"}, %{work_item_id: item.id}))
    refute Map.has_key?(result, :wait)
  end

  test "custody transfer keeps assigned and bare item ownership after source retirement", ctx do
    alias Tightbeam.Firehose.Hub
    owner = ctx.holder.owner_user_id
    source = ctx.holder.session_key
    session(ctx.db, "successor", owner)
    hub = start_supervised!({Hub, name: nil})
    item = create(ctx, {:user, owner}, %{title: "Transferred assignment"})
    bare = create(ctx, {:user, owner}, %{title: "Transferred bare item"})
    for id <- [item.id, bare.id], do: update(ctx, id, %{delivery_owner_session_key: source})
    {:ok, assignment} = disp_assign(ctx, {:user, owner}, source, "continuing work", item.id)
    before = Map.new([item.id, bare.id], &{&1, get(ctx, &1).workItem})
    routing = routing_wake_id(ctx.db, bare.id)
    :ok = Hub.register(hub, self(), %{mode: :all, db: ctx.db, user_id: owner, is_admin: false})

    call = %{
      principal: {:user, owner},
      firehose_hub: hub,
      params: %{
        from_session_key: source,
        to_session_key: "successor",
        idempotency_key: "transfer-items"
      }
    }

    result = ctx.handlers["session-custody-transfer"].(call)
    assert is_binary(result["eventId"])

    assert Enum.sort(Enum.map(result["after"]["workItems"], & &1["id"])) ==
             Enum.sort([item.id, bare.id])

    for _ <- [item.id, bare.id] do
      assert_receive {:firehose_notice, %{"class" => "work_item.updated", "payload" => payload}}
      Hub.delivered(hub, self())
      id = payload["id"]
      current = get(ctx, id).workItem
      assert current.deliveryOwnerSessionKey == "successor"
      assert current.rowVersion > before[id].rowVersion
      assert current.createdByUser == before[id].createdByUser
      assert current.createdBySession == before[id].createdBySession
      assert payload["rowVersion"] == current.rowVersion
      assert payload["holders"] == current.holders
    end

    assert routing_wake_id(ctx.db, bare.id) == routing
    assert Wakes.get(ctx.db, routing).session_key == Org.personal_session_key(owner)
    assert ctx.handlers["session-custody-transfer"].(call) == result
    refute_receive {:firehose_notice, %{"class" => "work_item.updated"}}

    retired =
      ctx.handlers["retire"].(%{
        verb: "retire",
        origin: "user:" <> owner,
        principal: {:user, owner},
        session_key: source,
        params: %{}
      })

    assert source in retired.retired_session_keys

    assert {:ok, [["open", "successor"]]} =
             DB.query(ctx.db, "SELECT state,holderKey FROM assignments WHERE id=?1", [
               assignment.id
             ])

    for id <- [item.id, bare.id],
        do: assert(get(ctx, id).workItem.deliveryOwnerSessionKey == "successor")
  end

  test "item-only custody transfer preserves routing and readdresses and rearms saved slate",
       ctx do
    owner = ctx.holder.owner_user_id
    source = Org.personal_session_key(owner)
    session(ctx.db, "successor", owner)
    bare = create(ctx, {:user, owner}, %{title: "Routing remains personal"})
    drained = create(ctx, {:user, owner}, %{title: "Slate follows delivery owner"})
    for id <- [bare.id, drained.id], do: update(ctx, id, %{delivery_owner_session_key: source})

    {:ok, assignment} =
      disp_assign(ctx, {:user, owner}, ctx.holder.session_key, "finish", drained.id)

    complete(ctx, ctx.holder.session_key, assignment.id)
    routing = routing_wake_id(ctx.db, bare.id)
    slate = slate_wake_id(ctx.db, drained.id)
    assert Wakes.get(ctx.db, slate).session_key == source

    call = %{
      principal: {:user, owner},
      params: %{
        from_session_key: source,
        to_session_key: "successor",
        idempotency_key: "item-only"
      }
    }

    result = ctx.handlers["session-custody-transfer"].(call)
    assert is_binary(result["eventId"])
    assert result["after"]["assignments"] == []
    assert routing_wake_id(ctx.db, bare.id) == routing
    assert Wakes.get(ctx.db, routing).session_key == source
    assert slate_wake_id(ctx.db, drained.id) == slate
    assert Wakes.get(ctx.db, slate).session_key == "successor"
    assert item_wake_count(ctx.db, bare.id) == 1
    assert item_wake_count(ctx.db, drained.id) == 1
    assert ctx.handlers["session-custody-transfer"].(call) == result
    deliver_bracket_wake(ctx.db, Wakes.get(ctx.db, slate))
    rearmed = Wakes.get(ctx.db, slate_wake_id(ctx.db, drained.id))
    assert rearmed.wake_id != slate
    assert rearmed.session_key == "successor"
  end

  test "absent work-item rails preserve create, assignment and close results without reminders",
       ctx do
    Rules.load!(Path.join(ctx.law_base, "absent"), Map.keys(ctx.handlers))
    item = create(ctx, {:user, "flynn"}, %{title: "No automatic reminders"})
    assert item.state == "open"
    assert routing_wake_id(ctx.db, item.id) == nil
    {:ok, assignment} = disp_assign(ctx, {:user, "flynn"}, "holder", "No reminder work", item.id)
    assert assignment.id
    result = attest(ctx, "holder", assignment.id, "completion")
    refute Map.has_key?(result, :code)
    assert slate_wake_id(ctx.db, item.id) == nil
    assert item_wake_count(ctx.db, item.id) == 0
  end

  test "changing a rail revises its pending wake in place and removing it cancels only the reaction",
       ctx do
    item = create(ctx, {:user, "flynn"}, %{title: "Revise the reminder"})
    id = routing_wake_id(ctx.db, item.id)
    original = Wakes.get(ctx.db, id)
    path = Path.join(ctx.law_base, "identity/rules/row-reaction-work-items.toml")
    bytes = File.read!(path)
    File.write!(path, String.replace(bytes, "86400000", "7000"))
    Rules.load!(ctx.law_base, Map.keys(ctx.handlers))
    :ok = Tightbeam.RowReactions.recover(ctx.db)
    revised = Wakes.get(ctx.db, id)
    assert routing_wake_id(ctx.db, item.id) == id
    assert revised.due_at == original.due_at - 86_400_000 + 7000
    File.rm!(path)
    Rules.load!(ctx.law_base, Map.keys(ctx.handlers))
    :ok = Tightbeam.RowReactions.recover(ctx.db)
    assert Wakes.get(ctx.db, id).state == "canceled"
    assert routing_wake_id(ctx.db, item.id) == nil
    assert WorkItems.state_for(ctx.db, item.id) == "open"
    File.write!(path, bytes)
    Rules.load!(ctx.law_base, Map.keys(ctx.handlers))
    :ok = Tightbeam.RowReactions.recover(ctx.db)
    assert routing_wake_id(ctx.db, item.id) == nil
    assert Wakes.get(ctx.db, id).state == "canceled"
  end

  test "pending legacy pointer adoption preserves the wake identity across recovery", ctx do
    item = create(ctx, {:user, "flynn"}, %{title: "Adopt pending reminder"})
    id = routing_wake_id(ctx.db, item.id)
    wake = Wakes.get(ctx.db, id)
    forget_reaction_pointer_ledger(ctx.db, item.id)
    :ok = Tightbeam.RowReactions.recover(ctx.db)
    assert routing_wake_id(ctx.db, item.id) == id
    assert Wakes.get(ctx.db, id).due_at == wake.due_at
    assert item_wake_count(ctx.db, item.id) == 1
    :ok = Tightbeam.RowReactions.recover(ctx.db)
    assert routing_wake_id(ctx.db, item.id) == id
    assert item_wake_count(ctx.db, item.id) == 1

    assert {:ok, [["pending"]]} =
             DB.query(
               ctx.db,
               "SELECT status FROM row_reaction_actions WHERE json_extract(result,'$.wake_id')=?1",
               [id]
             )
  end

  test "legacy reminders adopted before their rails load are held, then resume once", ctx do
    routed = create(ctx, {:user, "flynn"}, %{title: "Adopt before rails"})
    id = routing_wake_id(ctx.db, routed.id)
    wake = Wakes.get(ctx.db, id)
    forget_reaction_pointer_ledger(ctx.db, routed.id)

    action_state = fn ->
      DB.query(
        ctx.db,
        "SELECT status,lastError FROM row_reaction_actions WHERE json_extract(result,'$.wake_id')=?1",
        [id]
      )
    end

    # First boot of the new release: the identity holds no work-item rails yet.
    Rules.load!(Path.join(ctx.law_base, "absent"), Map.keys(ctx.handlers))

    for _ <- 1..2 do
      :ok = Tightbeam.RowReactions.recover(ctx.db)

      assert {:ok, [["held", "rail-not-loaded:" <> _]]} = action_state.()
      assert routing_wake_id(ctx.db, routed.id) == id
      assert Wakes.get(ctx.db, id).state == "pending"
      assert item_wake_count(ctx.db, routed.id) == 1
    end

    # Relearn publishes the rails; the next law load resumes the same wake once.
    Rules.load!(ctx.law_base, Map.keys(ctx.handlers))

    for _ <- 1..2 do
      :ok = Tightbeam.RowReactions.recover(ctx.db)

      assert {:ok, [["pending", nil]]} = action_state.()
      assert routing_wake_id(ctx.db, routed.id) == id
      assert Wakes.get(ctx.db, id).due_at == wake.due_at
      assert Wakes.get(ctx.db, id).state == "pending"
      assert item_wake_count(ctx.db, routed.id) == 1
    end
  end

  test "a held legacy reminder is withdrawn, not resumed, if its item was assigned meanwhile",
       ctx do
    kept = create(ctx, {:user, "flynn"}, %{title: "Still unrouted"})
    routed = create(ctx, {:user, "flynn"}, %{title: "Assigned while rails absent"})
    kept_id = routing_wake_id(ctx.db, kept.id)
    routed_id = routing_wake_id(ctx.db, routed.id)
    forget_reaction_pointer_ledger(ctx.db, kept.id)
    forget_reaction_pointer_ledger(ctx.db, routed.id)

    Rules.load!(Path.join(ctx.law_base, "absent"), Map.keys(ctx.handlers))
    :ok = Tightbeam.RowReactions.recover(ctx.db)

    assert {:ok, _} = disp_assign(ctx, {:user, "flynn"}, "holder", "Work while absent", routed.id)

    Rules.load!(ctx.law_base, Map.keys(ctx.handlers))

    for _ <- 1..2 do
      :ok = Tightbeam.RowReactions.recover(ctx.db)

      # The untouched item keeps its single owed reminder.
      assert routing_wake_id(ctx.db, kept.id) == kept_id
      assert Wakes.get(ctx.db, kept_id).state == "pending"
      assert item_wake_count(ctx.db, kept.id) == 1

      # The assigned item is routed: no reminder fires or repeats for it.
      assert routing_wake_id(ctx.db, routed.id) == nil
      assert Wakes.get(ctx.db, routed_id).state == "canceled"
      assert item_wake_count(ctx.db, routed.id) == 0

      assert {:ok, [["canceled"]]} =
               DB.query(
                 ctx.db,
                 "SELECT status FROM row_reaction_actions WHERE json_extract(result,'$.wake_id')=?1",
                 [routed_id]
               )
    end
  end

  test "canceled and missing legacy references are never replaced during adoption", ctx do
    for status <- ["canceled", "missing"] do
      item = create(ctx, {:user, "flynn"}, %{title: "Adopt #{status} reminder"})
      id = routing_wake_id(ctx.db, item.id)
      forget_reaction_pointer_ledger(ctx.db, item.id)

      if status == "missing" do
        assert {:ok, _} = DB.query(ctx.db, "DELETE FROM wakes WHERE wakeId=?1", [id])
      else
        assert {:ok, true} =
                 DB.transaction(ctx.db, fn txn ->
                   command = %{
                     wake_id: id,
                     requester: %{kind: "process", id: "tightbeam:row-reactions"},
                     reason_kind: "superseded",
                     causal_source: %{kind: "wake", id: id}
                   }

                   {:ok, outcome} = Wakes.public_cancellation_outcome_in_txn(txn, command)
                   Wakes.cancel_in_txn(txn, Map.put(command, :outcome, outcome))
                 end)
      end

      :ok = Tightbeam.RowReactions.recover(ctx.db)
      assert routing_wake_id(ctx.db, item.id) == id

      assert {:ok, [[actual]]} =
               DB.query(
                 ctx.db,
                 "SELECT status FROM row_reaction_actions WHERE json_extract(result,'$.wake_id')=?1",
                 [id]
               )

      assert actual == if(status == "missing", do: "held", else: "canceled")
      assert item_wake_count(ctx.db, item.id) == 0
    end
  end

  test "a pending current pointer and an unrelated delivery cannot rearm a reminder", ctx do
    item = create(ctx, {:user, "flynn"}, %{title: "Require actual delivery"})
    id = routing_wake_id(ctx.db, item.id)

    assert {:ok, :ok} =
             DB.transaction(ctx.db, fn txn ->
               WorkItems.rearm_on_fire_in_txn(txn, id, %{work_item_id: item.id})
             end)

    assert routing_wake_id(ctx.db, item.id) == id
    assert item_wake_count(ctx.db, item.id) == 1
    other = create(ctx, {:user, "flynn"}, %{title: "Other pointer"})
    other_id = routing_wake_id(ctx.db, other.id)
    deliver_bracket_wake(ctx.db, Wakes.get(ctx.db, other_id))

    assert {:ok, :ok} =
             DB.transaction(ctx.db, fn txn ->
               WorkItems.rearm_on_fire_in_txn(txn, other_id, %{work_item_id: item.id})
             end)

    assert routing_wake_id(ctx.db, item.id) == id
    assert item_wake_count(ctx.db, item.id) == 1
  end

  defp forget_reaction_pointer_ledger(db, item_id) do
    {:ok, _} =
      DB.query(
        db,
        "DELETE FROM row_reaction_actions WHERE eventId IN (SELECT eventId FROM row_reaction_events WHERE json_extract(event,'$.workItemId')=?1)",
        [item_id]
      )

    {:ok, _} =
      DB.query(
        db,
        "DELETE FROM row_reaction_events WHERE json_extract(event,'$.workItemId')=?1",
        [item_id]
      )

    {:ok, _} =
      DB.query(db, "DELETE FROM row_reaction_cutovers WHERE source='work-item-references/v1'")
  end

  test "unaltered declarations cancel mixed-archetype slate references atomically", ctx do
    Tightbeam.TerminalReactionFixture.load_work_items!(
      ctx.law_base,
      Map.keys(ctx.handlers),
      false
    )

    assert {:ok, _} =
             DB.query(
               ctx.db,
               "UPDATE sessions SET archetype='agentic-engineering.pdo' WHERE sessionKey='dsession'"
             )

    for action <- ["assign", "close", "missing", "refused"] do
      item = create(ctx, {:user, "flynn"}, %{title: "Mixed audience #{action}"})
      update(ctx, item.id, %{delivery_owner_session_key: "dsession"})
      {:ok, assignment} = disp_assign(ctx, {:user, "flynn"}, "holder", "work", item.id)
      complete(ctx, "holder", assignment.id)
      slate = slate_wake_id(ctx.db, item.id)
      assert Wakes.get(ctx.db, slate).session_key == "dsession"

      case action do
        "assign" ->
          assert {:ok, _} = disp_assign(ctx, {:user, "flynn"}, "holder", "next", item.id)
          assert slate_wake_id(ctx.db, item.id) == nil
          assert Wakes.get(ctx.db, slate).state == "canceled"

        "close" ->
          assert %{ok: true} = dispose(ctx, "work-item-close", {:user, "flynn"}, item.id)
          assert slate_wake_id(ctx.db, item.id) == nil
          assert Wakes.get(ctx.db, slate).state == "canceled"

        "missing" ->
          assert {:ok, _} = DB.query(ctx.db, "DELETE FROM wakes WHERE wakeId=?1", [slate])
          assert {:error, _} = disp_assign(ctx, {:user, "flynn"}, "holder", "refuse", item.id)
          assert slate_wake_id(ctx.db, item.id) == slate

          assert {:ok, [[0]]} =
                   DB.query(
                     ctx.db,
                     "SELECT COUNT(*) FROM assignments WHERE workItemId=?1 AND state='open'",
                     [item.id]
                   )

        "refused" ->
          assert {:error, %WorkItems.CancellationRefused{}} =
                   DB.transaction(ctx.db, fn txn ->
                     Txn.q(txn, "UPDATE work_items SET title='Must roll back' WHERE id=?1", [
                       item.id
                     ])

                     WorkItems.cancel_brackets_in_txn(txn, item.id, %{
                       causal_source: %{kind: "session_transition", id: "missing-session"},
                       outcome: %{kind: "no_replacement"}
                     })
                   end)

          assert get(ctx, item.id).workItem.title == item.title
          assert slate_wake_id(ctx.db, item.id) == slate
          assert Wakes.get(ctx.db, slate).state == "pending"
      end
    end
  end

  test "observations retain user/session principals, source times and overwritten states", ctx do
    user_item = create(ctx, {:user, "flynn"}, %{title: "User source"})
    session_item = create(ctx, {:session, "holder"}, %{title: "Session source"})
    user_event = item_observation(ctx.db, user_item.id, "created")
    assert user_event["principal"] == %{"kind" => "user", "id" => "flynn"}
    assert user_event["before"]["sourceRow"] == nil
    assert user_event["sourceAfter"]["id"] == user_item.id
    assert user_event["at"] == user_event["sourceAfter"]["createdAt"]

    assert item_observation(ctx.db, session_item.id, "created")["principal"] == %{
             "kind" => "session",
             "id" => "holder"
           }

    assert %{ok: true} =
             dispose(ctx, "work-item-icebox", {:user, "flynn"}, user_item.id, %{reason: "later"})

    closed = item_observation(ctx.db, user_item.id, "transition")
    assert closed["before"]["sourceRow"]["state"] == "open"
    assert closed["sourceAfter"]["state"] == "iceboxed"
    assert closed["principal"] == %{"kind" => "user", "id" => "flynn"}
    assert %{ok: true} = dispose(ctx, "work-item-reopen", {:session, "holder"}, user_item.id)
    reopened = item_observation(ctx.db, user_item.id, "reopened")
    assert reopened["before"]["sourceRow"]["state"] == "iceboxed"
    assert reopened["sourceAfter"]["state"] == "open"
    assert reopened["principal"] == %{"kind" => "session", "id" => "holder"}

    {:ok, assignment} =
      disp_assign(ctx, {:session, "holder"}, "holder", "actual source", user_item.id)

    assigned = item_observation(ctx.db, user_item.id, "transition")
    assert assigned["before"]["sourceRow"] == nil
    assert assigned["sourceAfter"]["id"] == assignment.id
    assert assigned["principal"] == %{"kind" => "session", "id" => "holder"}
    complete(ctx, "holder", assignment.id)
    finished = item_observation(ctx.db, user_item.id, "assignment_closed")
    assert finished["before"]["sourceRow"]["state"] == "open"
    assert finished["sourceAfter"]["state"] == "closed"
    assert finished["principal"] == %{"kind" => "session", "id" => "holder"}
  end

  defp item_observation(db, id, operation) do
    {:ok, [[event]]} =
      DB.query(
        db,
        "SELECT event FROM row_reaction_events WHERE json_extract(event,'$.workItemId')=?1 AND json_extract(event,'$.operation')=?2 ORDER BY rowid DESC LIMIT 1",
        [id, operation]
      )

    JSON.decode!(event)
  end

  test "changed rail sees source before and after facts identically at admission and recovery",
       ctx do
    path = Path.join(ctx.law_base, "identity/rules/row-reaction-work-items.toml")
    contents = File.read!(path)

    condition =
      ~s(when = { op = "and", args = [{ op = "eq", args = [{ ref = "event.operation" }, "reopened"] }, { op = "eq", args = [{ ref = "event.before.sourceRow.state" }, "iceboxed"] }, { op = "eq", args = [{ ref = "event.sourceAfter.state" }, "open"] }] })

    File.write!(path, Regex.replace(~r/^when = .*$/m, contents, condition, global: false))
    Rules.load!(ctx.law_base, Map.keys(ctx.handlers))
    item = create(ctx, {:user, "flynn"}, %{title: "Initial source facts"})
    assert routing_wake_id(ctx.db, item.id) == nil

    assert %{ok: true} =
             dispose(ctx, "work-item-icebox", {:user, "flynn"}, item.id, %{reason: "later"})

    assert %{ok: true} = dispose(ctx, "work-item-reopen", {:user, "flynn"}, item.id)
    id = routing_wake_id(ctx.db, item.id)
    assert is_binary(id)
    assert item_wake_count(ctx.db, item.id) == 1
    :ok = Tightbeam.RowReactions.recover(ctx.db)
    assert routing_wake_id(ctx.db, item.id) == id
    assert item_wake_count(ctx.db, item.id) == 1
    assert Wakes.get(ctx.db, id).state == "pending"
  end

  test "changed withdrawal preserves explicit icebox and reopen for routing and slate populations",
       ctx do
    for population <- ["routing", "slate"] do
      Tightbeam.TerminalReactionFixture.load_work_items!(
        ctx.law_base,
        Map.keys(ctx.handlers),
        false
      )

      item = create(ctx, {:user, "flynn"}, %{title: "Changed withdrawal #{population}"})

      if population == "slate" do
        {:ok, assignment} = disp_assign(ctx, {:user, "flynn"}, "holder", "work", item.id)
        complete(ctx, "holder", assignment.id)
      end

      delivered_id =
        if population == "routing",
          do: routing_wake_id(ctx.db, item.id),
          else: slate_wake_id(ctx.db, item.id)

      deliver_bracket_wake(ctx.db, Wakes.get(ctx.db, delivered_id))

      old_id =
        if population == "routing",
          do: routing_wake_id(ctx.db, item.id),
          else: slate_wake_id(ctx.db, item.id)

      refute old_id == delivered_id
      disable_work_item_withdrawals(ctx)
      :ok = Tightbeam.RowReactions.recover(ctx.db)
      assert Wakes.get(ctx.db, old_id).state == "pending"

      assert %{ok: true} =
               dispose(ctx, "work-item-icebox", {:user, "flynn"}, item.id, %{reason: "later"})

      assert Wakes.get(ctx.db, old_id).state == "pending"
      assert %{ok: true} = dispose(ctx, "work-item-reopen", {:user, "flynn"}, item.id)
      replacement = routing_wake_id(ctx.db, item.id)
      assert is_binary(replacement)
      refute replacement == old_id
      :ok = Tightbeam.RowReactions.recover(ctx.db)
      assert routing_wake_id(ctx.db, item.id) == replacement
      assert Wakes.get(ctx.db, replacement).state == "pending"

      assert {:ok, :ok} =
               DB.transaction(ctx.db, fn txn ->
                 WorkItems.rearm_on_fire_in_txn(txn, delivered_id, %{work_item_id: item.id})
               end)

      assert routing_wake_id(ctx.db, item.id) == replacement
      :ok = Tightbeam.RowReactions.recover(ctx.db)
      assert routing_wake_id(ctx.db, item.id) == replacement

      if population == "routing" do
        assert Wakes.get(ctx.db, old_id).state == "canceled"
        assert item_wake_count(ctx.db, item.id) == 1
      else
        # Changing withdrawal intentionally retains this independently elected
        # slate action and its identity; reopen does not fabricate cancellation.
        assert slate_wake_id(ctx.db, item.id) == old_id
        assert Wakes.get(ctx.db, old_id).state == "pending"
        assert item_wake_count(ctx.db, item.id) == 2
      end
    end
  end

  test "absent rails leave explicit disposition and reopen available with saved references",
       ctx do
    for population <- ["routing", "slate"] do
      Tightbeam.TerminalReactionFixture.load_work_items!(
        ctx.law_base,
        Map.keys(ctx.handlers),
        false
      )

      item = create(ctx, {:user, "flynn"}, %{title: "No policy on #{population} reopen"})

      if population == "slate" do
        {:ok, assignment} = disp_assign(ctx, {:user, "flynn"}, "holder", "work", item.id)
        complete(ctx, "holder", assignment.id)
      end

      pointer = if population == "routing", do: "routingWakeId", else: "slateWakeId"
      old_id = column(ctx.db, item.id, pointer)
      Rules.load!(Path.join(ctx.law_base, "absent"), Map.keys(ctx.handlers))

      assert %{ok: true} =
               dispose(ctx, "work-item-icebox", {:user, "flynn"}, item.id, %{reason: "later"})

      assert column(ctx.db, item.id, pointer) == old_id
      assert %{ok: true} = dispose(ctx, "work-item-reopen", {:user, "flynn"}, item.id)
      assert column(ctx.db, item.id, pointer) == old_id
      :ok = Tightbeam.RowReactions.recover(ctx.db)
      assert column(ctx.db, item.id, pointer) == nil
      assert Wakes.get(ctx.db, old_id).state == "canceled"
      assert WorkItems.state_for(ctx.db, item.id) == "open"
    end
  end

  test "an elected reopen replacement still refuses missing saved wake history", ctx do
    item = create(ctx, {:user, "flynn"}, %{title: "Unknown retained history"})
    old_id = routing_wake_id(ctx.db, item.id)
    disable_work_item_withdrawals(ctx)

    assert %{ok: true} =
             dispose(ctx, "work-item-icebox", {:user, "flynn"}, item.id, %{reason: "later"})

    assert {:ok, _} = DB.query(ctx.db, "DELETE FROM wakes WHERE wakeId=?1", [old_id])

    assert {:error, %{message: message}} =
             Dispatch.dispatch(
               ctx.db,
               ctx.handlers,
               work_item_call("work-item-reopen", {:user, "flynn"}, %{work_item_id: item.id})
             )

    assert message =~ "missing wake"
    assert WorkItems.state_for(ctx.db, item.id) == "iceboxed"
    assert routing_wake_id(ctx.db, item.id) == old_id
    assert item_wake_count(ctx.db, item.id) == 0
  end

  defp disable_work_item_withdrawals(ctx) do
    path = Path.join(ctx.law_base, "identity/rules/row-reaction-work-items.toml")

    contents =
      File.read!(path)
      |> String.split("[[reaction]]")
      |> Enum.map_join("[[reaction]]", fn block ->
        if String.contains?(block, "-withdraw\""),
          do:
            String.replace(
              block,
              ~s(events = ["work_item_observation"]),
              ~s(events = ["disabled_observation"])
            ),
          else: block
      end)

    File.write!(path, contents)
    Rules.load!(ctx.law_base, Map.keys(ctx.handlers))
  end

  test "changed rail controls terminal-state delivery eligibility without a compiled open-item filter",
       ctx do
    item = create(ctx, {:user, "flynn"}, %{title: "Changed terminal eligibility"})
    old_id = routing_wake_id(ctx.db, item.id)
    disable_work_item_withdrawals(ctx)

    assert %{ok: true} =
             dispose(ctx, "work-item-icebox", {:user, "flynn"}, item.id, %{reason: "later"})

    path = Path.join(ctx.law_base, "identity/rules/row-reaction-work-items.toml")
    bytes = File.read!(path)

    bytes =
      String.replace(
        bytes,
        ~s({ ref = "facts.work_item.state" }, "open"),
        ~s({ ref = "facts.work_item.state" }, "iceboxed"),
        global: false
      )

    File.write!(path, bytes)
    Rules.load!(ctx.law_base, Map.keys(ctx.handlers))
    :ok = Tightbeam.RowReactions.recover(ctx.db)
    assert Wakes.get(ctx.db, old_id).state == "pending"
    deliver_bracket_wake(ctx.db, Wakes.get(ctx.db, old_id))
    replacement = routing_wake_id(ctx.db, item.id)
    assert is_binary(replacement)
    refute replacement == old_id
    assert Wakes.get(ctx.db, replacement).state == "pending"
    assert item_wake_count(ctx.db, item.id) == 1
    assert WorkItems.state_for(ctx.db, item.id) == "iceboxed"
  end

  ## Proof 1 — create arms bracket 1; keyed replay returns the original, arms nothing.

  test "Proof 1: create (keyed and keyless) arms bracket 1; keyed replay is inert", ctx do
    item = create(ctx, {:user, "flynn"}, %{title: "Route me"})
    assert item.state == "open"
    assert item.ownerUserId == "flynn"

    routing = routing_wake_id(ctx.db, item.id)
    assert is_binary(routing)
    wake = Wakes.get(ctx.db, routing)
    assert wake.consumer == "prompt"
    assert wake.session_key == Org.personal_session_key("flynn")
    assert wake.work_item_id == item.id
    assert wake.prompt =~ "route it or icebox it"
    assert item_wake_count(ctx.db, item.id) == 1

    keyed = create(ctx, {:user, "flynn"}, %{title: "Keyed", idempotency_key: "kc"})
    original_routing = routing_wake_id(ctx.db, keyed.id)
    assert is_binary(original_routing)

    replay = create(ctx, {:user, "flynn"}, %{title: "Different title", idempotency_key: "kc"})
    assert replay.id == keyed.id
    # Replay arms NOTHING new: same routing wake, still exactly one pending wake.
    assert routing_wake_id(ctx.db, keyed.id) == original_routing
    assert item_wake_count(ctx.db, keyed.id) == 1
    assert work_item_count(ctx.db) == 2
  end

  ## Proof 2 — first assign AND first dispatch cancel bracket 1; both persist workItemId.

  test "Proof 2: first assign and first dispatch each cancel bracket 1 and persist workItemId",
       ctx do
    a_item = create(ctx, {:user, "flynn"}, %{title: "Assign path"})
    a_routing = routing_wake_id(ctx.db, a_item.id)
    {:ok, assignment} = disp_assign(ctx, {:user, "flynn"}, "holder", "work", a_item.id)
    assert assignment.workItemId == a_item.id
    assert routing_wake_id(ctx.db, a_item.id) == nil
    assert Wakes.get(ctx.db, a_routing).state == "canceled"

    assert [
             "tightbeam:work-items",
             "routing_bracket_satisfied",
             "assignment_transition",
             source_assignment_id,
             "disposition",
             "assignment_transition",
             disposition_assignment_id,
             "work_item",
             assignment_work_item,
             "linked_work_open",
             "routing_bracket",
             bracket_id,
             1
           ] = cancellation(ctx.db, a_routing)

    assert source_assignment_id == assignment.id
    assert disposition_assignment_id == assignment.id
    assert assignment_work_item == a_item.id
    assert bracket_id == a_item.id

    d_item = create(ctx, {:user, "flynn"}, %{title: "Dispatch path"})
    d_routing = routing_wake_id(ctx.db, d_item.id)
    {:ok, dispatched} = disp_dispatch(ctx, {:user, "flynn"}, "holder", "work", d_item.id)
    assert dispatched.workItemId == d_item.id
    assert routing_wake_id(ctx.db, d_item.id) == nil
    assert Wakes.get(ctx.db, d_routing).state == "canceled"
    assert Enum.at(cancellation(ctx.db, d_routing), 0) == "tightbeam:work-items"
  end

  test "typed bracket refusal rolls back the caller transaction", ctx do
    item = create(ctx, {:user, "flynn"}, %{title: "Refused bracket"})
    routing = routing_wake_id(ctx.db, item.id)

    assert {:error, %WorkItems.CancellationRefused{wake_id: ^routing}} =
             DB.transaction(ctx.db, fn txn ->
               WorkItems.cancel_brackets_in_txn(txn, item.id, %{
                 causal_source: %{kind: "session_transition", id: "missing-session"},
                 outcome: %{kind: "no_replacement"}
               })
             end)

    assert routing_wake_id(ctx.db, item.id) == routing
    assert Wakes.get(ctx.db, routing).state == "pending"

    assert {:ok, []} =
             DB.query(ctx.db, "SELECT wakeId FROM wake_cancellations WHERE wakeId=?1", [routing])
  end

  test "linked assign and dispatch roll back the complete accepted bundle", ctx do
    for {verb, dispatch_fun} <- [
          {"assign", &disp_assign(&1, {:user, "flynn"}, "holder", &2, &3)},
          {"dispatch", &disp_dispatch(&1, {:user, "flynn"}, "holder", &2, &3)}
        ] do
      subject = "forced #{verb} rollback"
      item = create(ctx, {:user, "flynn"}, %{title: subject})
      routing = routing_wake_id(ctx.db, item.id)

      :ok =
        DB.execute(
          ctx.db,
          """
          CREATE TRIGGER force_#{verb}_bracket_rollback
          BEFORE UPDATE OF state ON wakes
          WHEN OLD.wakeId='#{routing}' AND NEW.state='canceled'
          BEGIN
            SELECT RAISE(ABORT, 'forced #{verb} bracket rollback');
          END;
          """
        )

      assert {:error, %{code: "server_error", message: message}} =
               dispatch_fun.(ctx, subject, item.id)

      assert message =~ "forced #{verb} bracket rollback"
      assert routing_wake_id(ctx.db, item.id) == routing
      assert Wakes.get(ctx.db, routing).state == "pending"

      assert {:ok, [[0, 0, 0, 0, 0, 0]]} =
               DB.query(
                 ctx.db,
                 """
                 SELECT
                   (SELECT count(*) FROM assignments WHERE subject=?1),
                   (SELECT count(*) FROM wakes w JOIN assignments a ON a.id=w.assignmentId
                      WHERE a.subject=?1 AND w.consumer LIKE 'assignment_inactivity_%'),
                   (SELECT count(*) FROM effort_checkin_generations g
                      JOIN assignments a ON a.id=g.assignmentId WHERE a.subject=?1),
                   (SELECT count(*) FROM wake_cancellations WHERE wakeId=?2),
                   (SELECT count(*) FROM events
                      WHERE verb=?3 AND payload LIKE '%' || ?1 || '%'),
                   (SELECT count(*) FROM turns WHERE prompt LIKE '%' || ?1 || '%')
                 """,
                 [subject, routing, verb]
               )
    end
  end

  test "linked assign and dispatch roll back the complete bundle when event append fails", ctx do
    for {verb, dispatch_fun} <- [
          {"assign", &disp_assign(&1, {:user, "flynn"}, "holder", &2, &3)},
          {"dispatch", &disp_dispatch(&1, {:user, "flynn"}, "holder", &2, &3)}
        ] do
      subject = "forced #{verb} event rollback"
      item = create(ctx, {:user, "flynn"}, %{title: subject})
      routing = routing_wake_id(ctx.db, item.id)

      :ok =
        DB.execute(
          ctx.db,
          """
          CREATE TRIGGER force_#{verb}_event_rollback
          BEFORE INSERT ON events
          WHEN NEW.verb='#{verb}' AND NEW.payload LIKE '%#{subject}%'
          BEGIN
            SELECT RAISE(ABORT, 'forced #{verb} event rollback');
          END;
          """
        )

      # The event append is part of the handler's own transaction now, so its
      # failure rolls the bundle back and comes back as the handler's error.
      assert {:error, %{code: "server_error", message: message}} =
               dispatch_fun.(ctx, subject, item.id)

      assert message =~ "forced #{verb} event rollback"
      assert routing_wake_id(ctx.db, item.id) == routing
      assert Wakes.get(ctx.db, routing).state == "pending"

      assert {:ok, [[0, 0, 0, 0, 0, 0]]} =
               DB.query(
                 ctx.db,
                 """
                 SELECT
                   (SELECT count(*) FROM assignments WHERE subject=?1),
                   (SELECT count(*) FROM wakes w JOIN assignments a ON a.id=w.assignmentId
                      WHERE a.subject=?1 AND w.consumer LIKE 'assignment_inactivity_%'),
                   (SELECT count(*) FROM effort_checkin_generations g
                      JOIN assignments a ON a.id=g.assignmentId WHERE a.subject=?1),
                   (SELECT count(*) FROM wake_cancellations WHERE wakeId=?2),
                   (SELECT count(*) FROM events
                      WHERE verb=?3 AND payload LIKE '%' || ?1 || '%'),
                   (SELECT count(*) FROM turns WHERE prompt LIKE '%' || ?1 || '%')
                 """,
                 [subject, routing, verb]
               )
    end
  end

  ## Proof 3 — bracket-1 fire re-arms; icebox cancels and stops the nag.

  test "Proof 3: an ignored bracket-1 wake re-arms on fire; icebox stops the nag", ctx do
    item = create(ctx, {:user, "flynn"}, %{title: "Nagged"})
    old = routing_wake_id(ctx.db, item.id)

    deliver_bracket_wake(ctx.db, Wakes.get(ctx.db, old))

    assert Wakes.get(ctx.db, old).state == "fired"
    new = routing_wake_id(ctx.db, item.id)
    assert new != old
    assert Wakes.get(ctx.db, new).state == "pending"

    # One nag turn was delivered to the owner's personal session.
    assert Enum.any?(
             Projection.list_after(ctx.db, Org.personal_session_key("flynn"), nil, 10),
             &(&1.content =~ "route it or icebox it")
           )

    assert %{ok: true, workItem: %{state: "iceboxed"}} =
             dispose(ctx, "work-item-icebox", {:user, ctx.holder.owner_user_id}, item.id, %{
               reason: "waiting for the next review"
             })

    assert routing_wake_id(ctx.db, item.id) == nil
    assert Wakes.get(ctx.db, new).state == "canceled"

    assert [
             "tightbeam:work-items",
             "routing_bracket_satisfied",
             "work_item_transition",
             _source_id,
             "disposition",
             "work_item_transition",
             _disposition_id,
             "work_item",
             item_id,
             "linked_work_not_open",
             nil,
             nil,
             0
           ] = cancellation(ctx.db, new)

    assert item_id == item.id
  end

  ## Proof 4 — last-close of a non-terminal item arms the slate wake in the close txn;
  ## cannot-proceed alone stays open; next assign cancels; re-arms on the next last-close.

  test "Proof 4: every close path arms bracket 2 while cannot-proceed stays open", ctx do
    # Completion path + the full assign/cancel/re-arm cycle.
    item = create(ctx, {:user, "flynn"}, %{title: "Slate"})
    {:ok, a} = disp_assign(ctx, {:user, "flynn"}, "holder", "w", item.id)
    complete(ctx, "holder", a.id)

    slate = slate_wake_id(ctx.db, item.id)
    assert is_binary(slate)
    wake = Wakes.get(ctx.db, slate)
    # Durable row (survives a crash between commit and any delivery — no callback).
    assert wake.state == "pending"
    assert wake.session_key == Org.personal_session_key("flynn")
    assert wake.prompt =~ "slate clear"

    {:ok, a2} = disp_assign(ctx, {:user, "flynn"}, "holder", "w2", item.id)
    assert a2.workItemId == item.id
    assert slate_wake_id(ctx.db, item.id) == nil
    assert Wakes.get(ctx.db, slate).state == "canceled"

    complete(ctx, "holder", a2.id)
    slate2 = slate_wake_id(ctx.db, item.id)
    assert is_binary(slate2)
    assert slate2 != slate

    # Cannot-proceed keeps the assignment and item open; disposer revocation then closes it.
    paused_item = create(ctx, {:user, "flynn"}, %{title: "Paused"})
    {:ok, paused} = disp_assign(ctx, {:user, "flynn"}, "holder", "paused", paused_item.id)
    cannot_proceed(ctx, "holder", paused.id)
    assert slate_wake_id(ctx.db, paused_item.id) == nil
    revoke(ctx, paused.id)
    assert is_binary(slate_wake_id(ctx.db, paused_item.id))

    # Revoke path.
    revoke_item = create(ctx, {:user, "flynn"}, %{title: "Revoked"})
    {:ok, ra} = disp_assign(ctx, {:user, "flynn"}, "holder", "rw", revoke_item.id)
    revoke(ctx, ra.id)
    assert is_binary(slate_wake_id(ctx.db, revoke_item.id))

    # Retire-strand path (interrupt_for_retire closes the strand's open assignments).
    strand_holder = session(ctx.db, "strand-holder", "flynn")
    retire_item = create(ctx, {:user, "flynn"}, %{title: "Stranded"})
    {:ok, _ta} = disp_assign(ctx, {:user, "flynn"}, "strand-holder", "tw", retire_item.id)

    {:ok, _} =
      DB.transaction(ctx.db, fn txn ->
        Assignments.interrupt_for_retire_in_txn(
          txn,
          strand_holder.session_key,
          "flynn",
          "user:flynn"
        )
      end)

    assert is_binary(slate_wake_id(ctx.db, retire_item.id))
  end

  ## Proof 5 — terminal dispositions transition, cancel both brackets, refuse work, no-op, reopen.

  test "Proof 5: dispositions transition, cancel both brackets, refuse work, no-op, reopen",
       ctx do
    item = create(ctx, {:user, "flynn"}, %{title: "Disposed"})
    {:ok, a} = disp_assign(ctx, {:user, "flynn"}, "holder", "w", item.id)
    complete(ctx, "holder", a.id)
    slate = slate_wake_id(ctx.db, item.id)
    assert is_binary(slate)

    assert %{ok: true, workItem: %{state: "iceboxed"}} =
             dispose(ctx, "work-item-icebox", {:user, ctx.holder.owner_user_id}, item.id, %{
               reason: "waiting for the next review"
             })

    # Cancels BOTH brackets (slate wake canceled, both ids cleared).
    assert Wakes.get(ctx.db, slate).state == "canceled"
    assert routing_wake_id(ctx.db, item.id) == nil
    assert slate_wake_id(ctx.db, item.id) == nil

    # Refuses assign/dispatch afterward (terminal guard).
    assert {:error, %{code: "work_item_not_open"}} =
             disp_assign(ctx, {:user, "flynn"}, "holder", "again", item.id)

    # Same-state disposition is a no-op success.
    assert %{ok: true, workItem: %{state: "iceboxed"}} =
             dispose(ctx, "work-item-icebox", {:user, ctx.holder.owner_user_id}, item.id, %{
               reason: "waiting for the next review"
             })

    # Reopen re-arms bracket 1.
    assert %{ok: true, workItem: %{state: "open"}} =
             dispose(ctx, "work-item-reopen", {:user, "flynn"}, item.id)

    reopened_routing = routing_wake_id(ctx.db, item.id)
    assert is_binary(reopened_routing)
    assert Wakes.get(ctx.db, reopened_routing).state == "pending"

    # close and fail transition and refuse too.
    close_item = create(ctx, {:user, "flynn"}, %{title: "Closeable"})

    assert %{ok: true, workItem: %{state: "closed"}} =
             dispose(ctx, "work-item-close", {:user, "flynn"}, close_item.id)

    assert {:error, %{code: "work_item_not_open"}} =
             disp_assign(ctx, {:user, "flynn"}, "holder", "x", close_item.id)

    fail_item = create(ctx, {:user, "flynn"}, %{title: "Failable"})

    assert %{ok: true, workItem: %{state: "failed"}} =
             dispose(ctx, "work-item-fail", {:user, "flynn"}, fail_item.id)

    assert {:error, %{code: "work_item_not_open"}} =
             disp_assign(ctx, {:user, "flynn"}, "holder", "x", fail_item.id)
  end

  ## Disposition authority — owner-or-admin, resolved through the session's user.

  test "disposition authority: an admin session disposes a foreign item; a non-admin cannot",
       ctx do
    eves_item = create(ctx, {:user, "eve"}, %{title: "Eve's item"})

    # A non-admin session (dana) cannot dispose another user's item.
    assert %{code: "not_authorized"} =
             dispose(ctx, "work-item-close", {:session, "dsession"}, eves_item.id)

    # "holder" is owned by flynn, who is admin — an admin session (not the owner)
    # disposes it. Before the fix this was wrongly refused (session != owner).
    assert %{ok: true, workItem: %{state: "closed"}} =
             dispose(ctx, "work-item-close", {:session, "holder"}, eves_item.id)

    # A non-admin session still disposes its OWN owner's item.
    danas_item = create(ctx, {:user, "dana"}, %{title: "Dana's item"})

    assert %{ok: true, workItem: %{state: "iceboxed"}} =
             dispose(ctx, "work-item-icebox", {:session, "dsession"}, danas_item.id, %{
               reason: "waiting for the next review"
             })
  end

  ## Proof 6 — owner resolution: session-created items anchor to the session's owning user.

  test "Proof 6: a session-created item is owned by its session's user; bracket targets the main",
       ctx do
    item = create(ctx, {:session, "dsession"}, %{title: "Session filed"})
    assert item.ownerUserId == "dana"
    assert item.createdBySession == "dsession"

    wake = Wakes.get(ctx.db, routing_wake_id(ctx.db, item.id))
    # The bracket wake reaches the durable personal session, never the creator session.
    assert wake.session_key == Org.personal_session_key("dana")
    refute wake.session_key == "dsession"
  end

  ## Proof 7 — assignment close still arms the work-item slate without retired check-ins.

  test "Proof 7: a dispatched assignment closes and arms the slate without effort check-ins",
       ctx do
    item = create(ctx, {:user, "flynn"}, %{title: "Coexist"})
    {:ok, d} = disp_dispatch(ctx, {:user, "flynn"}, "holder", "w", item.id)

    assert effort_state(ctx.db, d.id) == nil

    complete(ctx, "holder", d.id)

    # Ordinary assignment closure and the work-item slate still proceed.
    assert effort_state(ctx.db, d.id) == nil
    assert is_binary(slate_wake_id(ctx.db, item.id))
    assert assignment_state(ctx.db, d.id) == "closed"
  end

  ## Proof 8 — feature_smoke journey.

  test "Proof 9: create -> nag -> dispatch cancels -> revoke arms slate -> fail disposes", ctx do
    item = create(ctx, {:user, "flynn"}, %{title: "Journey"})

    # Idle past the triage horizon: the routing wake fires and re-nags.
    deliver_bracket_wake(ctx.db, Wakes.get(ctx.db, routing_wake_id(ctx.db, item.id)))

    assert Enum.any?(
             Projection.list_after(ctx.db, Org.personal_session_key("flynn"), nil, 10),
             &(&1.content =~ "route it or icebox it")
           )

    # Dispatch cancels bracket 1.
    {:ok, d} = disp_dispatch(ctx, {:user, "flynn"}, "holder", "ship", item.id)
    assert routing_wake_id(ctx.db, item.id) == nil

    # Revoke (last close) arms the slate wake, which then arrives.
    revoke(ctx, d.id)
    slate = slate_wake_id(ctx.db, item.id)
    assert is_binary(slate)
    deliver_bracket_wake(ctx.db, Wakes.get(ctx.db, slate))

    assert Enum.any?(
             Projection.list_after(ctx.db, Org.personal_session_key("flynn"), nil, 10),
             &(&1.content =~ "slate clear")
           )

    # work-item-fail disposes and cancels bracket 2.
    assert %{ok: true, workItem: %{state: "failed", failReason: "shipped elsewhere"}} =
             dispose(ctx, "work-item-fail", {:user, "flynn"}, item.id, %{
               reason: "shipped elsewhere"
             })

    assert slate_wake_id(ctx.db, item.id) == nil
  end

  ## Proof 10 — dispatch replay bypasses rumination and the terminal guard.

  test "Proof 10: a keyed dispatch replay returns the original across any workItemId, even disposed",
       ctx do
    item = create(ctx, {:user, "flynn"}, %{title: "Replay"})
    other = create(ctx, {:user, "flynn"}, %{title: "Other"})

    {:ok, orig} = disp_dispatch(ctx, {:user, "flynn"}, "holder", "ship", item.id, key: "dk")
    assert orig.workItemId == item.id

    # Dispose the item since — the replay must still succeed (no terminal-guard eval).
    revoke(ctx, orig.id)
    dispose(ctx, "work-item-fail", {:user, "flynn"}, item.id)

    for work_item_id <- [item.id, other.id, nil, "wi_unknown"] do
      assert {:ok, replay} =
               disp_dispatch(ctx, {:user, "flynn"}, "holder", "ship", work_item_id, key: "dk")

      assert replay.id == orig.id
      assert replay.workItemId == item.id
    end

    # ZERO rumination wakes were created by the replays.
    assert rumination_wake_count(ctx.db) == 0
  end

  test "Proof 10 (added): a keyed assign replay through Dispatch is statute-inert", ctx do
    item = create(ctx, {:user, "flynn"}, %{title: "Assign replay"})
    {:ok, orig} = disp_assign(ctx, {:user, "flynn"}, "holder", "seed", item.id, key: "ak")
    assert orig.workItemId == item.id

    # Install a statute that Rules.decide WOULD deny a user-origin assign under.
    load_rules(ctx, """
    [[rule]]
    name = "deny-assign"
    verb = "assign"
    archetypes = ["*"]
    text = "assign denied"
    [[rule.deny_when]]
    fact = "caller.origin_class"
    op = "eq"
    value = "user"
    """)

    # The statute is live: a fresh (non-replay) assign is denied by the rail.
    assert {:error, %{code: "rule_denied"}} =
             disp_assign(ctx, {:user, "flynn"}, "holder", "fresh", item.id)

    # The keyed replay short-circuits ABOVE the rail: the original assignment
    # returns untouched and no remedy episode is filed (statute inertness).
    assert {:ok, replay} =
             disp_assign(ctx, {:user, "flynn"}, "holder", "ignored", item.id, key: "ak")

    assert replay.id == orig.id
    assert replay.workItemId == item.id
    assert RailRemedy.episode(ctx.db, "deny-assign", item.id) == nil
  end

  ## Proof 11 — disposition-while-open is refused with a legible error.

  test "Proof 11: icebox/close/fail are refused while any assignment is open", ctx do
    item = create(ctx, {:user, "flynn"}, %{title: "Busy"})
    {:ok, _a} = disp_assign(ctx, {:user, "flynn"}, "holder", "w", item.id)

    for verb <- ["work-item-icebox", "work-item-close", "work-item-fail"] do
      extra = if verb == "work-item-icebox", do: %{reason: "waiting for review"}, else: %{}

      assert %{code: "assignments_open"} =
               dispose(ctx, verb, {:user, ctx.holder.owner_user_id}, item.id, extra)
    end
  end

  ## Proof 13 — fail and icebox reasons share the persisted failReason field.

  test "Proof 13: work-item-fail and work-item-icebox reasons persist and surface", ctx do
    owner = ctx.holder.owner_user_id
    iceboxed = create(ctx, {:user, owner}, %{title: "Iceboxed with reason"})

    assert %{code: "missing_reason"} =
             dispose(ctx, "work-item-icebox", {:user, owner}, iceboxed.id)

    assert %{code: "missing_reason"} =
             dispose(ctx, "work-item-icebox", {:user, owner}, iceboxed.id, %{reason: " \t "})

    assert %{workItem: %{state: "open", failReason: nil}} = get(ctx, iceboxed.id)

    assert %{workItem: %{state: "iceboxed", failReason: "waiting for a decision"}} =
             dispose(ctx, "work-item-icebox", {:user, owner}, iceboxed.id, %{
               reason: "waiting for a decision"
             })

    assert get(ctx, iceboxed.id).workItem.failReason == "waiting for a decision"

    assert Enum.find(list(ctx).workItems, &(&1.id == iceboxed.id)).failReason ==
             "waiting for a decision"

    assert WorkState.item_detail(ctx.db, iceboxed.id).workItem.failReason ==
             "waiting for a decision"

    item = create(ctx, {:user, owner}, %{title: "Failed with reason"})

    assert %{workItem: %{failReason: "cannot repro"}} =
             dispose(ctx, "work-item-fail", {:user, owner}, item.id, %{reason: "cannot repro"})

    assert get(ctx, item.id).workItem.failReason == "cannot repro"
    assert Enum.find(list(ctx).workItems, &(&1.id == item.id)).failReason == "cannot repro"
    assert WorkState.item_detail(ctx.db, item.id).workItem.failReason == "cannot repro"

    closed = create(ctx, {:user, owner}, %{title: "Closed"})

    assert %{workItem: %{failReason: nil}} =
             dispose(ctx, "work-item-close", {:user, owner}, closed.id)
  end

  ## Proof 14 — response shapes carry owner/state/failReason; never wake ids.

  test "Proof 14: every response object exposes owner/state/failReason and hides wake ids", ctx do
    item = create(ctx, {:user, "flynn"}, %{title: "Shaped"})

    objects = [
      item,
      get(ctx, item.id).workItem,
      Enum.find(list(ctx).workItems, &(&1.id == item.id)),
      update(ctx, item.id, %{title: "Reshaped"}),
      WorkState.item_detail(ctx.db, item.id).workItem,
      Enum.find(WorkState.list_items(ctx.db, %{}).items, &(&1.workItem.id == item.id)).workItem
    ]

    for object <- objects do
      assert Map.has_key?(object, :ownerUserId)
      assert Map.has_key?(object, :state)
      assert Map.has_key?(object, :failReason)
      refute Map.has_key?(object, :routingWakeId)
      refute Map.has_key?(object, :slateWakeId)
    end

    disposition = dispose(ctx, "work-item-close", {:user, "flynn"}, item.id)
    assert %{ok: true, workItem: work_item} = disposition
    assert map_size(disposition) == 2
    refute Map.has_key?(disposition.workItem, :routingWakeId)
    refute Map.has_key?(work_item, :assignments)

    # A same-state no-op returns the same ok envelope and changes nothing.
    assert %{ok: true, workItem: %{state: "closed"}} =
             dispose(ctx, "work-item-close", {:user, "flynn"}, item.id)
  end

  ## Proof 15 — create doorbell: one on a real create, zero on a keyed replay.

  test "Proof 15: an actual create publishes to the owner's board (unassigned); replay is silent",
       ctx do
    flynn = observe("flynn")
    eve = observe("eve")

    # An UNASSIGNED item has no holders: the doorbell must still reach its owner.
    item = create(ctx, {:user, "flynn"}, %{title: "Doorbell", idempotency_key: "dk"})
    assert doorbell_count(ctx.db, item.id) == 1
    assert [%{"type" => "work_item_event", "kind" => "metadata"}] = Observer.drain(flynn)
    assert Observer.drain(eve) == []

    replay = create(ctx, {:user, "flynn"}, %{title: "Doorbell", idempotency_key: "dk"})
    assert replay.id == item.id
    assert doorbell_count(ctx.db, item.id) == 1
    assert Observer.drain(flynn) == []

    assert item.id in item_ids(WorkState.list_items(ctx.db, %{owner_user_id: "flynn"}))
    refute item.id in item_ids(WorkState.list_items(ctx.db, %{owner_user_id: "eve"}))
  end

  ## Proof 16 — the in-txn state='open' interlock aborts an insert racing a disposition.

  test "Proof 16: through Dispatch, a disposition landing between the guards aborts the insert",
       ctx do
    item = create(ctx, {:user, "flynn"}, %{title: "Raced"})

    # The pre-statute guard (Dispatch precheck) will read this open state and proceed.
    assert WorkItems.state_for(ctx.db, item.id) == "open"

    call =
      assign_call({:user, "flynn"}, "holder", "w", item.id)
      |> Map.put(:on_work_item_interlock, fn txn ->
        # A genuine disposition (close) commits AFTER the pre-statute guard read
        # but BEFORE the insert — the same mechanics work-item-close applies
        # (cancel both brackets, set state). The substrate is one BEGIN IMMEDIATE
        # connection, so this txn seam is how a committed disposition interleaves;
        # a literal second connection would serialize behind this transaction.
        Txn.q(txn, "UPDATE work_items SET state = 'closed' WHERE id = ?1", [item.id])

        Tightbeam.CausalEvents.append_in_txn(txn, %{
          kind: "disposition_transition",
          job_ref: item.id,
          assignment_id: nil,
          session_key: nil,
          detail: %{workItemId: item.id, fromState: "open", toState: "closed"}
        })

        [[transition_id]] = Txn.q(txn, "SELECT last_insert_rowid()")

        WorkItems.cancel_brackets_in_txn(txn, item.id, %{
          causal_source: %{kind: "work_item_transition", id: to_string(transition_id)},
          outcome: %{
            kind: "disposition",
            disposition_kind: "work_item_transition",
            disposition_id: to_string(transition_id)
          }
        })
      end)

    # Driven through the chokepoint: precheck saw open, only the in-txn interlock
    # catches the disposition and aborts the insert.
    assert {:error, %{code: "work_item_not_open"}} = Dispatch.dispatch(ctx.db, ctx.handlers, call)

    # The now-terminal item never acquired an assignment.
    assert {:ok, [[0]]} =
             DB.query(ctx.db, "SELECT count(*) FROM assignments WHERE workItemId = ?1", [item.id])

    assert WorkItems.state_for(ctx.db, item.id) == "closed"
  end

  ## Proof 17 — bracket-2 slate re-arm on fire.

  test "Proof 17: an ignored slate wake re-arms itself at the next horizon", ctx do
    item = create(ctx, {:user, "flynn"}, %{title: "Slate re-arm"})
    {:ok, a} = disp_assign(ctx, {:user, "flynn"}, "holder", "w", item.id)
    complete(ctx, "holder", a.id)

    slate = slate_wake_id(ctx.db, item.id)
    deliver_bracket_wake(ctx.db, Wakes.get(ctx.db, slate))

    assert Wakes.get(ctx.db, slate).state == "fired"
    new = slate_wake_id(ctx.db, item.id)
    assert new != slate
    assert Wakes.get(ctx.db, new).state == "pending"

    assert Tightbeam.WaitLinks.summaries(ctx.db, [item.id])[item.id].waiting == %{
             agent: false,
             time: false,
             event: false,
             userIds: []
           }

    principal = %{kind: "user", id: "flynn", is_admin: true}

    for kind <- ["work-item", "session"], ended <- ["true", "false"] do
      id = if kind == "work-item", do: item.id, else: Wakes.get(ctx.db, new).session_key
      {:ok, request} = Tightbeam.WaitLinks.request(%{"includeEnded" => ended}, kind, id)
      {:ok, page} = Tightbeam.WaitLinks.page(ctx.db, kind, id, principal, request)
      refute Enum.any?(page.items, &(&1[:id] in ["wake:" <> slate, "wake:" <> new]))
    end

    for wake_id <- [slate, new] do
      assert Tightbeam.StateResources.wake(Tightbeam.StateResources.query_wake(ctx.db, wake_id))[
               "waitOn"
             ] == []
    end
  end

  test "slate notices use the recorded delivery owner when scheduled and re-armed", ctx do
    delivery_owner = ctx.dsession.session_key
    item = create(ctx, {:user, ctx.holder.owner_user_id}, %{title: "Slate delivery owner"})

    assert %{deliveryOwnerSessionKey: ^delivery_owner} =
             update(ctx, item.id, %{delivery_owner_session_key: delivery_owner})

    {:ok, assignment} =
      disp_assign(ctx, {:user, ctx.holder.owner_user_id}, "holder", "w", item.id)

    complete(ctx, "holder", assignment.id)

    slate = Wakes.get(ctx.db, slate_wake_id(ctx.db, item.id))
    assert slate.session_key == delivery_owner

    deliver_bracket_wake(ctx.db, slate)

    rearmed = Wakes.get(ctx.db, slate_wake_id(ctx.db, item.id))
    refute rearmed.wake_id == slate.wake_id
    assert rearmed.session_key == delivery_owner
  end

  test "slate notices fall back to the owner personal session when no delivery owner is recorded",
       ctx do
    owner_session = Org.personal_session_key(ctx.holder.owner_user_id)
    item = create(ctx, {:user, ctx.holder.owner_user_id}, %{title: "Slate owner fallback"})

    {:ok, assignment} =
      disp_assign(ctx, {:user, ctx.holder.owner_user_id}, "holder", "w", item.id)

    complete(ctx, "holder", assignment.id)

    slate = Wakes.get(ctx.db, slate_wake_id(ctx.db, item.id))
    assert slate.session_key == owner_session

    deliver_bracket_wake(ctx.db, slate)

    rearmed = Wakes.get(ctx.db, slate_wake_id(ctx.db, item.id))
    refute rearmed.wake_id == slate.wake_id
    assert rearmed.session_key == owner_session
  end

  for retirement_time <- [:before_arm, :before_rearm] do
    @retirement_time retirement_time
    test "slate notices fall back after delivery owner retirement #{@retirement_time}", ctx do
      delivery_owner = ctx.dsession.session_key
      owner_session = Org.personal_session_key(ctx.holder.owner_user_id)
      item = create(ctx, {:user, ctx.holder.owner_user_id}, %{title: "Retired delivery owner"})
      update(ctx, item.id, %{delivery_owner_session_key: delivery_owner})

      {:ok, assignment} =
        disp_assign(ctx, {:user, ctx.holder.owner_user_id}, "holder", "w", item.id)

      if @retirement_time == :before_arm do
        assert %{state: "retired"} = Org.retire(ctx.db, delivery_owner, "test:retirement")
      end

      complete(ctx, "holder", assignment.id)
      slate = Wakes.get(ctx.db, slate_wake_id(ctx.db, item.id))

      if @retirement_time == :before_arm do
        assert slate.session_key == owner_session
      else
        assert slate.session_key == delivery_owner
        assert %{state: "retired"} = Org.retire(ctx.db, delivery_owner, "test:retirement")
      end

      assert get(ctx, item.id).workItem.deliveryOwnerSessionKey == delivery_owner
      deliver_bracket_wake(ctx.db, Wakes.get(ctx.db, slate.wake_id))

      rearmed = Wakes.get(ctx.db, slate_wake_id(ctx.db, item.id))
      refute rearmed.wake_id == slate.wake_id
      assert rearmed.session_key == owner_session
    end
  end

  ## Proof 18 — a non-admin owner sees its own UNASSIGNED item through the owner path.

  test "Proof 18: a non-admin owner lists and details its own unassigned item", ctx do
    item = create(ctx, {:user, "dana"}, %{title: "Dana's item"})

    listed = item_ids(WorkState.list_items(ctx.db, %{owner_user_id: "dana"}))
    assert item.id in listed

    detail = WorkState.item_detail(ctx.db, item.id)
    assert detail.workItem.ownerUserId == "dana"
    assert detail.assignments == []

    # A different non-admin, non-owner does not see it (owner path, not admin bypass).
    refute item.id in item_ids(WorkState.list_items(ctx.db, %{owner_user_id: "eve"}))
  end

  ## Proof 19 — disposition doorbells fire on real transitions, stay silent on no-ops.

  test "Proof 19: each real disposition emits a doorbell; a same-state no-op emits none", ctx do
    owner = ctx.holder.owner_user_id
    item = create(ctx, {:user, owner}, %{title: "Doorbells"})
    base = doorbell_count(ctx.db, item.id)

    # A disposition on an UNASSIGNED item still reaches the owner's board.
    observer = observe(owner)
    dispose(ctx, "work-item-icebox", {:user, owner}, item.id, %{reason: "waiting for review"})
    assert doorbell_count(ctx.db, item.id) == base + 1
    assert [%{"type" => "work_item_event", "kind" => "metadata"}] = Observer.drain(observer)

    # Same-state no-op: no doorbell, no publish.
    dispose(ctx, "work-item-icebox", {:user, owner}, item.id, %{reason: "same-state retry"})
    assert doorbell_count(ctx.db, item.id) == base + 1
    assert Observer.drain(observer) == []

    dispose(ctx, "work-item-reopen", {:user, "flynn"}, item.id)
    assert doorbell_count(ctx.db, item.id) == base + 2

    dispose(ctx, "work-item-close", {:user, "flynn"}, item.id)
    assert doorbell_count(ctx.db, item.id) == base + 3

    fail_item = create(ctx, {:user, "flynn"}, %{title: "Failing"})
    fail_base = doorbell_count(ctx.db, fail_item.id)
    dispose(ctx, "work-item-fail", {:user, "flynn"}, fail_item.id)
    assert doorbell_count(ctx.db, fail_item.id) == fail_base + 1
  end

  test "recorded wait quiets routing only and completion resumes reminders once", ctx do
    item = create(ctx, {:user, "flynn"}, %{title: "Await upstream"})
    upstream = create(ctx, {:user, "flynn"}, %{title: "Upstream"})
    {:ok, resolver} = disp_assign(ctx, {:user, "flynn"}, "holder", "Upstream", upstream.id)
    routing = routing_wake_id(ctx.db, item.id)
    %{wait: wait} = record_item_wait(ctx, item.id, %{assignment_id: resolver.id})
    assert wait.active
    assert Wakes.get(ctx.db, routing).state == "canceled"
    assert routing_wake_id(ctx.db, item.id) == nil
    assert slate_wake_id(ctx.db, item.id) == nil
    # Idempotent retry preserves both identity and the original safety deadline.
    assert %{wait: ^wait} = record_item_wait(ctx, item.id, %{assignment_id: resolver.id})
    assert %{assignment: %{outcome: "completed"}} = complete(ctx, "holder", resolver.id)
    wake = Wakes.get(ctx.db, wait.wakeId)
    assert wake.recognition_path == "success"
    refute get(ctx, item.id).wait.active
    reminder = Wakes.get(ctx.db, routing_wake_id(ctx.db, item.id))
    assert reminder.due_at >= wake.recognition_at + 86_400_000
    assert reminder.wake_id != routing

    assert {:ok, _} =
             DB.transaction(ctx.db, fn txn ->
               Tightbeam.WorkItemWaits.release_in_txn(txn, wait.wakeId)
             end)

    assert routing_wake_id(ctx.db, item.id) == reminder.wake_id
  end

  test "assignment activity during an item wait keeps assignment notices but quiets slate", ctx do
    item = create(ctx, {:user, "flynn"}, %{title: "Waiting item"})
    upstream = create(ctx, {:user, "flynn"}, %{title: "Dependency"})
    {:ok, resolver} = disp_assign(ctx, {:user, "flynn"}, "holder", "Dependency", upstream.id)
    %{wait: wait} = record_item_wait(ctx, item.id, %{assignment_id: resolver.id})
    {:ok, assignment} = disp_assign(ctx, {:user, "flynn"}, "holder", "Related work", item.id)
    assert get(ctx, item.id).wait.active
    assert %{assignment: _} = complete(ctx, "holder", assignment.id)
    assert slate_wake_id(ctx.db, item.id) == nil
    assert get(ctx, item.id).wait.active
    assert %{outcome: "revoked"} = revoke(ctx, resolver.id)
    assert Wakes.get(ctx.db, wait.wakeId).recognition_path == "reconsideration"
    assert get(ctx, item.id).wait.recognitionDisposition == "revoked"
    assert is_binary(slate_wake_id(ctx.db, item.id))
    assert routing_wake_id(ctx.db, item.id) == nil
  end

  test "replacing and withdrawing waits leaves no stale continuation", ctx do
    item = create(ctx, {:user, "flynn"}, %{title: "Change dependency"})
    upstream = create(ctx, {:user, "flynn"}, %{title: "Dependency"})
    {:ok, first} = disp_assign(ctx, {:user, "flynn"}, "holder", "First", upstream.id)
    {:ok, second} = disp_assign(ctx, {:user, "flynn"}, "holder", "Second", upstream.id)
    %{wait: old} = record_item_wait(ctx, item.id, %{assignment_id: first.id})
    %{wait: next} = record_item_wait(ctx, item.id, %{assignment_id: second.id})
    assert old.wakeId != next.wakeId
    assert Wakes.get(ctx.db, old.wakeId).state == "canceled"
    complete(ctx, "holder", first.id)
    assert get(ctx, item.id).wait.active

    assert %{wait: %{active: false}} =
             ctx.handlers["work-item-wait-withdraw"].(
               work_item_call("work-item-wait-withdraw", {:user, "flynn"}, %{
                 work_item_id: item.id
               })
             )

    assert Wakes.get(ctx.db, next.wakeId).state == "canceled"
    reminder = routing_wake_id(ctx.db, item.id)
    assert is_binary(reminder)
    complete(ctx, "holder", second.id)
    assert routing_wake_id(ctx.db, item.id) == reminder
  end

  test "terminal and reopened items do not resurrect waits", ctx do
    item = create(ctx, {:user, "flynn"}, %{title: "Park waiting work"})
    upstream = create(ctx, {:user, "flynn"}, %{title: "Dependency"})
    {:ok, resolver} = disp_assign(ctx, {:user, "flynn"}, "holder", "Dependency", upstream.id)
    %{wait: wait} = record_item_wait(ctx, item.id, %{assignment_id: resolver.id})

    assert %{ok: true} =
             dispose(ctx, "work-item-icebox", {:user, "flynn"}, item.id, %{reason: "Paused"})

    assert Wakes.get(ctx.db, wait.wakeId).state == "canceled"
    assert %{ok: true} = dispose(ctx, "work-item-reopen", {:user, "flynn"}, item.id)
    refute get(ctx, item.id).wait.active
    assert is_binary(routing_wake_id(ctx.db, item.id))
    complete(ctx, "holder", resolver.id)
    assert Wakes.get(ctx.db, wait.wakeId).recognition_path == nil
  end

  test "wait resolution addresses current delivery owner and retirement fallback", ctx do
    for retire? <- [false, true] do
      item = create(ctx, {:user, "flynn"}, %{title: "Owner changes"})
      upstream = create(ctx, {:user, "flynn"}, %{title: "Dependency"})
      {:ok, resolver} = disp_assign(ctx, {:user, "flynn"}, "holder", "Dependency", upstream.id)
      %{wait: wait} = record_item_wait(ctx, item.id, %{assignment_id: resolver.id})
      owner = "wait-owner-#{retire?}"
      session(ctx.db, owner, "flynn")
      update(ctx, item.id, %{delivery_owner_session_key: owner})
      assert Wakes.get(ctx.db, wait.wakeId).session_key == owner
      if retire?, do: Org.retire(ctx.db, owner, "test:retirement")
      revoke(ctx, resolver.id)
      expected = if retire?, do: Org.personal_session_key("flynn"), else: owner
      assert Wakes.get(ctx.db, wait.wakeId).session_key == expected
      assert Wakes.get(ctx.db, wait.wakeId).recognition_path == "reconsideration"
    end
  end

  test "item owner and delivery owner can record waits; open assignments retain their own waits",
       ctx do
    item = create(ctx, {:user, "flynn"}, %{title: "Wait authority"})

    params = %{
      work_item_id: item.id,
      condition_kind: "assignment-landed",
      condition_scope: item.id,
      after_ms: 60_000,
      wait_reason: "Waiting for landing"
    }

    handler = ctx.handlers["work-item-wait"]

    assert %{code: "not_authorized"} =
             handler.(work_item_call("work-item-wait", {:session, "dsession"}, params))

    update(ctx, item.id, %{delivery_owner_session_key: "dsession"})

    assert %{wait: %{active: true}} =
             handler.(work_item_call("work-item-wait", {:session, "dsession"}, params))

    {:ok, _assignment} = disp_assign(ctx, {:user, "flynn"}, "holder", "Active work", item.id)

    assert %{code: "assignments_open"} =
             handler.(work_item_call("work-item-wait", {:user, "flynn"}, params))

    assert get(ctx, item.id).wait.active
  end

  test "invalid declarations refuse without quieting the current reminder", ctx do
    item = create(ctx, {:user, "flynn"}, %{title: "Keep reminder"})
    original = routing_wake_id(ctx.db, item.id)

    assert %{code: "invalid_resolver"} =
             record_item_wait(ctx, item.id, %{assignment_id: "missing"})

    assert %{code: "invalid_wait_target"} =
             record_item_wait(ctx, item.id, %{
               condition_kind: " ",
               condition_scope: "scope"
             })

    assert %{code: "missing_reason"} =
             record_item_wait(ctx, item.id, %{assignment_id: "missing", wait_reason: " "})

    assert %{code: "invalid_fallback"} =
             record_item_wait(ctx, item.id, %{assignment_id: "missing", after_ms: 0})

    assert routing_wake_id(ctx.db, item.id) == original
    assert Wakes.get(ctx.db, original).state == "pending"
    assert get(ctx, item.id).wait == nil
  end

  test "already completed dependency resumes reminders immediately", ctx do
    item = create(ctx, {:user, "flynn"}, %{title: "Already ready"})
    upstream = create(ctx, {:user, "flynn"}, %{title: "Dependency"})
    {:ok, resolver} = disp_assign(ctx, {:user, "flynn"}, "holder", "Dependency", upstream.id)
    complete(ctx, "holder", resolver.id)

    assert %{wait: %{active: false, recognitionPath: "success"}} =
             record_item_wait(ctx, item.id, %{assignment_id: resolver.id})

    assert is_binary(routing_wake_id(ctx.db, item.id))
  end

  defp record_item_wait(ctx, id, target) do
    ctx.handlers["work-item-wait"].(
      work_item_call(
        "work-item-wait",
        {:user, "flynn"},
        Map.merge(
          %{
            work_item_id: id,
            after_ms: if(target[:condition_kind], do: 10_800_000),
            wait_reason: "Waiting for upstream work"
          },
          target
        )
      )
    )
  end

  test "unannounced events are accepted with the ordinary producer warning and require a fallback",
       ctx do
    item = create(ctx, {:user, "flynn"}, %{title: "Agent event"})

    assert %{code: "invalid_fallback"} =
             record_item_wait(ctx, item.id, %{
               condition_kind: "release-live",
               condition_scope: "next-release",
               after_ms: nil
             })

    assert %{wait: %{active: true}, warnings: [%{code: "no-live-producer", kind: "release-live"}]} =
             record_item_wait(ctx, item.id, %{
               condition_kind: "release-live",
               condition_scope: "next-release"
             })
  end

  test "record targets have no deadline and refuse fallback durations", ctx do
    item = create(ctx, {:user, "flynn"}, %{title: "Record lifetime"})
    upstream = create(ctx, {:user, "flynn"}, %{title: "Dependency"})
    {:ok, resolver} = disp_assign(ctx, {:user, "flynn"}, "holder", "Dependency", upstream.id)
    %{wait: wait} = record_item_wait(ctx, item.id, %{assignment_id: resolver.id, after_ms: nil})
    assert wait.dueAt == nil
    assert wait.active

    for target <- [%{assignment_id: resolver.id}, %{decision_request_id: "dr_unused"}] do
      assert %{
               code: "invalid_fallback",
               message: "--fallback-after is only supported for event waits"
             } =
               record_item_wait(ctx, item.id, Map.put(target, :after_ms, 1))

      assert get(ctx, item.id).wait.wakeId == wait.wakeId
    end

    scheduler = item_wait_scheduler(ctx)
    assert :ok = Wakes.fire_due(scheduler)
    assert get(ctx, item.id).wait.active
    assert Wakes.get(ctx.db, wait.wakeId).recognition_path == nil
    complete(ctx, "holder", resolver.id)
    refute get(ctx, item.id).wait.active
  end

  test "ordinary existing schema gains item waits without rewriting elected rules", ctx do
    item = create(ctx, {:user, "flynn"}, %{title: "Existing item"})
    reminder = routing_wake_id(ctx.db, item.id)
    rule_path = Path.join(ctx.law_base, "identity/rules/row-reaction-work-items.toml")
    rules = File.read!(rule_path)
    # This additive link table is the only new schema object. Preserve existing
    # work, wake and reaction rows while bootstrapping its predecessor shape.
    assert {:ok, _} = DB.query(ctx.db, "DROP TABLE work_item_waits")
    assert :ok = Tightbeam.Schema.ensure_all(ctx.db)
    assert File.read!(rule_path) == rules
    assert routing_wake_id(ctx.db, item.id) == reminder

    assert %{wait: %{active: true}} =
             record_item_wait(ctx, item.id, %{
               condition_kind: "agreed-event",
               condition_scope: "upstream"
             })

    assert Wakes.get(ctx.db, reminder).state == "canceled"
    assert File.read!(rule_path) == rules
  end

  test "unchanged customized reminder rules respect item waits and resume their interval", ctx do
    rule_path = Path.join(ctx.law_base, "identity/rules/row-reaction-work-items.toml")
    File.write!(rule_path, File.read!(rule_path) |> String.replace("86400000", "7000"))
    Rules.load!(ctx.law_base, Map.keys(ctx.handlers))
    item = create(ctx, {:user, "flynn"}, %{title: "Custom reminder"})
    upstream = create(ctx, {:user, "flynn"}, %{title: "Dependency"})
    {:ok, resolver} = disp_assign(ctx, {:user, "flynn"}, "holder", "Dependency", upstream.id)
    %{wait: wait} = record_item_wait(ctx, item.id, %{assignment_id: resolver.id, after_ms: nil})
    {:ok, assignment} = disp_assign(ctx, {:user, "flynn"}, "holder", "Local work", item.id)
    complete(ctx, "holder", assignment.id)
    assert slate_wake_id(ctx.db, item.id) == nil
    assert :ok = Tightbeam.RowReactions.recover(ctx.db)
    assert slate_wake_id(ctx.db, item.id) == nil
    complete(ctx, "holder", resolver.id)
    wake = Wakes.get(ctx.db, wait.wakeId)
    reminder = Wakes.get(ctx.db, slate_wake_id(ctx.db, item.id))
    assert reminder.due_at >= wake.recognition_at + 7000
    assert reminder.due_at < wake.recognition_at + 20_000
  end

  test "fact wait recognizes an existing occurrence and a future matching fact", ctx do
    scheduler = item_wait_scheduler(ctx)

    for historical? <- [true, false] do
      item = create(ctx, {:user, "flynn"}, %{title: "Event dependency"})
      scope = item.id

      if historical?,
        do:
          Tightbeam.ConditionFacts.file(ctx.db, scheduler, %{
            kind: "assignment-landed",
            scope: scope,
            origin: "process:tightbeam"
          })

      %{wait: wait} =
        record_item_wait(ctx, item.id, %{
          condition_kind: "assignment-landed",
          condition_scope: scope
        })

      if historical? do
        refute wait.active
      else
        assert wait.active

        Tightbeam.ConditionFacts.file(ctx.db, scheduler, %{
          kind: "assignment-landed",
          scope: "other",
          origin: "process:tightbeam"
        })

        assert get(ctx, item.id).wait.active

        Tightbeam.ConditionFacts.file(ctx.db, scheduler, %{
          kind: "assignment-landed",
          scope: scope,
          origin: "process:tightbeam"
        })
      end

      assert get(ctx, item.id).wait.recognitionPath == "success"
      refute get(ctx, item.id).wait.active
    end
  end

  test "fallback survives scheduler restart and emits one continuation then normal reminder",
       ctx do
    item = create(ctx, {:user, "flynn"}, %{title: "Missing event"})

    %{wait: wait} =
      record_item_wait(ctx, item.id, %{
        condition_kind: "assignment-landed",
        condition_scope: item.id
      })

    assert :ok = Tightbeam.Schema.ensure_all(ctx.db)
    assert get(ctx, item.id).wait.active
    scheduler = item_wait_scheduler(ctx)
    DB.query(ctx.db, "UPDATE wakes SET dueAt=1 WHERE wakeId=?1", [wait.wakeId])
    assert :ok = Wakes.fire_due(scheduler)
    assert :ok = Wakes.fire_due(scheduler)
    assert Wakes.get(ctx.db, wait.wakeId).recognition_path == "fallback"
    assert get(ctx, item.id).wait.recognitionPath == "fallback"
    assert is_map(get(ctx, item.id).wait.recognitionEvidence)
    refute get(ctx, item.id).wait.active
    reminder = routing_wake_id(ctx.db, item.id)
    assert is_binary(reminder)
    assert Wakes.get(ctx.db, reminder).state == "pending"
    # A restart replays neither recognition nor delivery.
    stop_supervised!(scheduler)
    scheduler = item_wait_scheduler(ctx)
    assert :ok = Wakes.fire_due(scheduler)
    assert routing_wake_id(ctx.db, item.id) == reminder

    assert {:ok, [[1]]} =
             DB.query(
               ctx.db,
               """
               SELECT COUNT(*) FROM turns t WHERE t.wakeId=?1 OR t.wakeId IN (
                 SELECT b.deliveryWakeId FROM notice_batch_members m JOIN notice_batches b ON b.batchId=m.batchId
                 WHERE m.sourceWakeId=?1 AND b.state='delivered')
               """,
               [wait.wakeId]
             )

    deliver_bracket_wake(ctx.db, Wakes.get(ctx.db, reminder))
    next_reminder = routing_wake_id(ctx.db, item.id)
    assert next_reminder != reminder
    assert Wakes.get(ctx.db, next_reminder).state == "pending"
  end

  test "decision withdrawal and supersession wake for reconsideration", ctx do
    for terminal <- [:withdrawn, :superseded] do
      item = create(ctx, {:user, "flynn"}, %{title: "Decision dependency"})

      request =
        Tightbeam.Escalation.operator_ask(ctx.db, %{
          principal: {:session, "holder"},
          session_key: "holder",
          origin: "agent:holder",
          params:
            Tightbeam.TestSupport.OperatorAskFixture.link(ctx.db, "holder", %{
              question: "Choose an outcome",
              options: [%{label: "proceed"}, %{label: "stop"}]
            })
        })

      %{wait: wait} = record_item_wait(ctx, item.id, %{decision_request_id: request.id})

      if terminal == :withdrawn do
        Tightbeam.Escalation.operator_withdraw(ctx.db, %{
          principal: {:session, "holder"},
          origin: "agent:holder",
          params: %{request: request.id, reason: "Question no longer applies"}
        })
      else
        Tightbeam.Escalation.operator_ask(ctx.db, %{
          principal: {:session, "holder"},
          session_key: "holder",
          origin: "agent:holder",
          params:
            Tightbeam.TestSupport.OperatorAskFixture.link(ctx.db, "holder", %{
              question: "Replacement question",
              options: [%{label: "proceed"}, %{label: "stop"}],
              supersedes: request.id
            })
        })
      end

      assert Wakes.get(ctx.db, wait.wakeId).recognition_path == "reconsideration"
      refute get(ctx, item.id).wait.active
    end
  end

  for terminal <- [:answer, :return] do
    @terminal terminal
    test "agent decision #{@terminal} releases one item continuation and restores reminders",
         ctx do
      item = create(ctx, {:user, "flynn"}, %{title: "Decision wait"})

      request =
        Tightbeam.Escalation.ask(ctx.db, %{
          verb: "ask",
          principal: {:session, "holder"},
          origin: "agent:holder",
          session_key: Org.personal_session_key("flynn"),
          params: %{question: "Which result?"}
        })

      %{wait: wait} = record_item_wait(ctx, item.id, %{decision_request_id: request.id})

      call = %{
        verb: to_string(@terminal),
        principal: {:session, "holder"},
        origin: "agent:holder",
        params: %{request: request.id, reason: "Needs context", answer: "Proceed"}
      }

      result = ctx.handlers[to_string(@terminal)].(call)
      expected = if @terminal == :answer, do: "success", else: "reconsideration"
      assert result.status == if(@terminal == :answer, do: "answered", else: "returned")
      # Recognition is caused by the write, before any scheduler/deadline pass.
      assert Wakes.get(ctx.db, wait.wakeId).recognition_path == expected
      assert get(ctx, item.id).wait.recognitionDisposition == result.status
      refute get(ctx, item.id).wait.active
      reminder = routing_wake_id(ctx.db, item.id)
      assert is_binary(reminder)
      recognized_at = Wakes.get(ctx.db, wait.wakeId).recognition_at
      assert ctx.handlers[to_string(@terminal)].(call).status == result.status
      assert Wakes.get(ctx.db, wait.wakeId).recognition_at == recognized_at
      scheduler = item_wait_scheduler(ctx)
      assert :ok = Wakes.fire_due(scheduler)
      stop_supervised!(scheduler)
      scheduler = item_wait_scheduler(ctx)
      assert :ok = Wakes.fire_due(scheduler)
      assert routing_wake_id(ctx.db, item.id) == reminder

      assert {:ok, [[1]]} =
               DB.query(
                 ctx.db,
                 """
                 SELECT COUNT(*) FROM turns t WHERE t.wakeId=?1 OR t.wakeId IN (
                   SELECT b.deliveryWakeId FROM notice_batch_members m JOIN notice_batches b ON b.batchId=m.batchId
                   WHERE m.sourceWakeId=?1 AND b.state='delivered')
                 """,
                 [wait.wakeId]
               )

      deliver_bracket_wake(ctx.db, Wakes.get(ctx.db, reminder))
      next_reminder = routing_wake_id(ctx.db, item.id)
      assert next_reminder != reminder
      assert Wakes.get(ctx.db, next_reminder).state == "pending"
    end
  end

  test "agent withdrawal and retirement withdrawal both recognize item waits", ctx do
    for terminal <- [:withdraw, :retirement] do
      item = create(ctx, {:user, "flynn"}, %{title: "Decision withdrawal"})

      request =
        Tightbeam.Escalation.ask(ctx.db, %{
          verb: "ask",
          principal: {:session, "holder"},
          origin: "agent:holder",
          session_key: Org.personal_session_key("flynn"),
          params: %{question: "Which result?"}
        })

      %{wait: wait} = record_item_wait(ctx, item.id, %{decision_request_id: request.id})

      if terminal == :withdraw do
        assert %{status: "withdrawn"} =
                 Tightbeam.Escalation.withdraw(ctx.db, %{
                   principal: {:session, "holder"},
                   origin: "agent:holder",
                   params: %{request: request.id, reason: "No longer needed"}
                 })
      else
        assert :ok = Tightbeam.Escalation.withdraw_for_retired(ctx.db, "holder")
      end

      assert Wakes.get(ctx.db, wait.wakeId).recognition_path == "reconsideration"
      assert get(ctx, item.id).wait.recognitionDisposition == "withdrawn"
      refute get(ctx, item.id).wait.active
      assert is_binary(routing_wake_id(ctx.db, item.id))
    end
  end

  test "retirement and boot recovery recognize revoked assignment item waits", ctx do
    for recovery? <- [false, true] do
      holder = "retiring-resolver-#{recovery?}"
      session(ctx.db, holder, "flynn")
      item = create(ctx, {:user, "flynn"}, %{title: "Wait for retiring resolver"})
      upstream = create(ctx, {:user, "flynn"}, %{title: "Dependency"})
      {:ok, resolver} = disp_assign(ctx, {:user, "flynn"}, holder, "Dependency", upstream.id)
      %{wait: wait} = record_item_wait(ctx, item.id, %{assignment_id: resolver.id})

      if recovery? do
        Org.retire(ctx.db, holder, "user:flynn")
        assert :ok = Tightbeam.Supervision.close_retired_holder_assignments(ctx.db)
      else
        result =
          ctx.handlers["retire"].(%{
            origin: "user:flynn",
            principal: {:user, "flynn"},
            session_key: holder,
            params: %{}
          })

        assert holder in result.retired_session_keys
      end

      assert get(ctx, item.id).wait.recognitionDisposition == "revoked"
      assert Wakes.get(ctx.db, wait.wakeId).recognition_path == "reconsideration"
      refute get(ctx, item.id).wait.active
      assert is_binary(routing_wake_id(ctx.db, item.id))
    end
  end

  test "statute ruling waiver consumption and withdrawal paths recognize item waits", ctx do
    for terminal <- [:rule, :consume_inline, :waive, :withdraw, :recovery] do
      item = create(ctx, {:user, "flynn"}, %{title: "Statute dependency"})

      call = %{
        verb: "attest",
        origin: "agent:holder",
        principal: {:session, "holder"},
        session_key: nil,
        params: %{assignment_id: "dependency-#{terminal}", kind: "completion"}
      }

      statute = %{name: "wait-review-#{terminal}", text: "Owner review"}

      assert {:decision_pending, id} =
               Tightbeam.Escalation.escalate(ctx.db, call, statute, %{
                 question: "Allow the action?",
                 options: nil
               })

      %{wait: wait} = record_item_wait(ctx, item.id, %{decision_request_id: id})

      case terminal do
        kind when kind in [:rule, :consume_inline] ->
          Tightbeam.Escalation.rule(
            ctx.db,
            %{
              origin: "user:flynn",
              principal: {:user, "flynn"},
              params: %{request_id: id, decision: "allow"}
            },
            authorized: true
          )

        :waive ->
          Tightbeam.Escalation.waive(
            ctx.db,
            %{origin: "user:flynn", principal: {:user, "flynn"}, params: %{request_id: id}},
            authorized: true
          )

        :withdraw ->
          Tightbeam.Escalation.withdraw(ctx.db, %{
            origin: "user:flynn",
            principal: {:user, "flynn"},
            params: %{request_id: id, reason: "No longer needed"}
          })

        :recovery ->
          Tightbeam.Escalation.withdraw_episodes(ctx.db, [id], statute.name)
      end

      expected =
        if terminal in [:rule, :consume_inline, :waive], do: "success", else: "reconsideration"

      assert Wakes.get(ctx.db, wait.wakeId).recognition_path == expected,
             "terminal path #{terminal}"

      refute get(ctx, item.id).wait.active
      assert is_binary(routing_wake_id(ctx.db, item.id))

      if terminal in [:rule, :consume_inline] do
        if terminal == :consume_inline do
          assert {:ok, true} =
                   DB.transaction(ctx.db, fn txn ->
                     Tightbeam.Escalation.consume_in_txn(txn, id, "memento-set", "user:flynn")
                   end)
        else
          assert Tightbeam.Escalation.consume(ctx.db, id)
        end

        # Consumption follows ruling: suppression has already ended before either path.
        refute get(ctx, item.id).wait.active
        %{wait: consumed} = record_item_wait(ctx, item.id, %{decision_request_id: id})
        assert consumed.recognitionPath == "success"
        assert consumed.recognitionDisposition == "consumed"
        refute consumed.active
      end
    end
  end

  test "operator ruling and historical surrendered assignment are recognized", ctx do
    item = create(ctx, {:user, "flynn"}, %{title: "Operator dependency"})

    request =
      Tightbeam.Escalation.operator_ask(ctx.db, %{
        principal: {:session, "holder"},
        session_key: "holder",
        origin: "agent:holder",
        params:
          Tightbeam.TestSupport.OperatorAskFixture.link(ctx.db, "holder", %{
            question: "Choose",
            options: [%{label: "proceed"}, %{label: "stop"}]
          })
      })

    %{wait: wait} = record_item_wait(ctx, item.id, %{decision_request_id: request.id})

    assert %{status: "ruled"} =
             Tightbeam.Escalation.operator_rule(ctx.db, %{
               principal: {:user, "flynn"},
               origin: "user:flynn",
               params: %{request: request.id, decision: "proceed"}
             })

    assert get(ctx, item.id).wait.recognitionDisposition == "ruled"
    assert Wakes.get(ctx.db, wait.wakeId).recognition_path == "success"
    refute get(ctx, item.id).wait.active

    upstream = create(ctx, {:user, "flynn"}, %{title: "Legacy dependency"})
    {:ok, resolver} = disp_assign(ctx, {:user, "flynn"}, "holder", "Legacy", upstream.id)
    complete(ctx, "holder", resolver.id)
    # Current writers never create surrendered; retain admission for stored history.
    assert {:ok, _} =
             DB.query(ctx.db, "UPDATE assignments SET outcome='surrendered' WHERE id=?1", [
               resolver.id
             ])

    %{wait: historical} = record_item_wait(ctx, item.id, %{assignment_id: resolver.id})
    assert historical.recognitionPath == "reconsideration"
    assert historical.recognitionDisposition == "surrendered"
    refute historical.active
  end

  defp item_wait_scheduler(ctx) do
    name = :"item_wait_scheduler_#{System.unique_integer([:positive])}"

    start_supervised!(
      Supervisor.child_spec(
        {Wakes,
         name: name,
         db: ctx.db,
         tick_ms: 60_000,
         deliver: fn wake ->
           Gateway.deliver_prompt(wake.session_key, wake.origin, wake.prompt,
             db: ctx.db,
             wake_id: wake.wake_id,
             sender: wake.origin,
             target_gate: wake,
             conn_registry: ConnRegistry,
             lane_manager: Tightbeam.LaneManager
           )
         end,
         delivery_opts: [conn_registry: ConnRegistry, lane_manager: Tightbeam.LaneManager]},
        id: name
      )
    )

    name
  end

  ## Helpers ----------------------------------------------------------------

  defp create(ctx, principal, params) do
    ctx.handlers["work-item-create"].(work_item_call("work-item-create", principal, params))
  end

  defp dispose(ctx, verb, principal, id, extra \\ %{}) do
    params = Map.put(extra, :work_item_id, id)
    ctx.handlers[verb].(work_item_call(verb, principal, params))
  end

  defp get(ctx, id),
    do:
      ctx.handlers["work-item-get"].(
        work_item_call("work-item-get", {:user, "flynn"}, %{work_item_id: id})
      )

  defp list(ctx),
    do: ctx.handlers["work-item-list"].(work_item_call("work-item-list", {:user, "flynn"}, %{}))

  defp update(ctx, id, patch),
    do:
      ctx.handlers["work-item-update"].(
        work_item_call("work-item-update", {:user, "flynn"}, Map.put(patch, :work_item_id, id))
      )

  defp work_item_call(verb, principal, params) do
    %{
      verb: verb,
      origin: origin(principal),
      principal: principal,
      session_key: nil,
      params: params
    }
  end

  defp disp_assign(ctx, principal, holder, subject, work_item_id, opts \\ []) do
    Dispatch.dispatch(
      ctx.db,
      ctx.handlers,
      assign_call(principal, holder, subject, work_item_id, opts)
    )
  end

  defp assign_call(principal, holder, subject, work_item_id, opts \\ []) do
    params =
      %{subject: subject, work_item_id: work_item_id, effect_kind: "coordination"}
      |> maybe_put(:idempotency_key, opts[:key])

    %{
      verb: "assign",
      origin: origin(principal),
      principal: principal,
      session_key: holder,
      target_role: nil,
      role_fallback: false,
      supervision_interval_ms: 1_000,
      params: params
    }
  end

  defp disp_dispatch(ctx, principal, holder, subject, work_item_id, opts \\ []) do
    params =
      %{
        subject: subject,
        brief: "Implement #{subject}.",
        work_item_id: work_item_id,
        effect_kind: "coordination"
      }
      |> maybe_put(:idempotency_key, opts[:key])

    call = %{
      verb: "dispatch",
      origin: origin(principal),
      principal: principal,
      session_key: holder,
      target_role: nil,
      role_fallback: false,
      supervision_interval_ms: 1_000,
      params: params
    }

    Dispatch.dispatch(ctx.db, ctx.handlers, call)
  end

  defp complete(ctx, holder, assignment_id), do: attest(ctx, holder, assignment_id, "completion")

  defp cannot_proceed(ctx, holder, assignment_id) do
    Assignments.__handle__(ctx.db, "attest", %{
      verb: "attest",
      origin: "agent:#{holder}",
      principal: {:session, holder},
      session_key: nil,
      params: %{
        assignment_id: assignment_id,
        kind: "cannot-proceed",
        note: "fixture requires opener disposition"
      }
    })
  end

  defp attest(ctx, holder, assignment_id, kind) do
    Assignments.__handle__(ctx.db, "attest", %{
      verb: "attest",
      origin: "agent:#{holder}",
      principal: {:session, holder},
      session_key: nil,
      params: %{assignment_id: assignment_id, kind: kind}
    })
  end

  defp revoke(ctx, assignment_id) do
    Assignments.__handle__(ctx.db, "revoke-assignment", %{
      verb: "revoke-assignment",
      origin: "user:flynn",
      principal: {:user, "flynn"},
      session_key: nil,
      params: %{assignment_id: assignment_id, reason: "test disposition"}
    })
  end

  defp deliver_bracket_wake(db, wake) do
    {:ok, result} =
      DB.transaction(db, fn txn ->
        Gateway.deliver_prompt_in_txn(txn, wake.session_key, wake.origin, wake.prompt,
          wake_id: wake.wake_id,
          sender: wake.origin,
          target_gate: wake,
          fire_wake_in_txn: true
        )
      end)

    case result do
      {:staged, %{wake_id: source_wake_id}} ->
        finish_delivery_queue(db, wake.session_key)
        _ = NoticeBatcher.recover(db, System.system_time(:millisecond) + 60_000)
        [%{delivery_wake_id: carrier_wake_id}] = NoticeBatcher.source_refs(db, source_wake_id)
        carrier = Wakes.get(db, carrier_wake_id)

        # Recovery has already committed the actual carrier turn. Replaying
        # that carrier must return its existing turn, never append again.
        assert {:ok, {:duplicate, %{wake_id: ^carrier_wake_id, turn_seq: turn_seq}}} =
                 DB.transaction(db, fn txn ->
                   Gateway.deliver_prompt_in_txn(
                     txn,
                     carrier.session_key,
                     carrier.origin,
                     carrier.prompt,
                     wake_id: carrier.wake_id,
                     sender: carrier.origin,
                     target_gate: carrier,
                     fire_wake_in_txn: true
                   )
                 end)

        assert {:ok, [[^turn_seq]]} =
                 DB.query(db, "SELECT seq FROM turns WHERE wakeId=?1", [carrier_wake_id])

        assert source_wake_id in Enum.map(Wakes.digest_members(db, carrier_wake_id), & &1.wake_id)
        assert Wakes.get(db, source_wake_id).state == "fired"
        assert Wakes.get(db, carrier_wake_id).state == "fired"
        finish_delivery_queue(db, carrier.session_key)
        :ok = Wakes.reconcile_delivered_sources(db, carrier.session_key, carrier_wake_id)
        :ok = WorkItems.reconcile_delivered_brackets(db, carrier.session_key, carrier_wake_id)

      {:appended, _, _, _} ->
        finish_delivery_queue(db, wake.session_key)
        :ok = Wakes.reconcile_delivered_sources(db, wake.session_key, wake.wake_id)
        :ok = WorkItems.reconcile_delivered_brackets(db, wake.session_key, wake.wake_id)

      other ->
        flunk("expected bracket wake delivery, got: #{inspect(other)}")
    end
  end

  defp finish_delivery_queue(db, session_key) do
    case Ledger.claim_next(db, session_key, "work-item-bracket-fixture") do
      {:ok, turn} ->
        assert :ok =
                 Ledger.finish(db, turn.seq, "delivered", nil, owner_lease: turn.owner_lease)

        finish_delivery_queue(db, session_key)

      :none ->
        :ok

      other ->
        flunk("expected an idle bracket delivery queue, got: #{inspect(other)}")
    end
  end

  defp routing_wake_id(db, id), do: column(db, id, "routingWakeId")
  defp slate_wake_id(db, id), do: column(db, id, "slateWakeId")

  defp column(db, id, name) do
    {:ok, [[value]]} = DB.query(db, "SELECT #{name} FROM work_items WHERE id = ?1", [id])
    value
  end

  defp item_wake_count(db, work_item_id) do
    {:ok, [[count]]} =
      DB.query(
        db,
        "SELECT count(*) FROM wakes WHERE work_item_id = ?1 AND state = 'pending'",
        [work_item_id]
      )

    count
  end

  defp cancellation(db, wake_id) do
    {:ok, [row]} =
      DB.query(
        db,
        """
        SELECT requesterId,reasonKind,causalSourceKind,causalSourceId,
               outcomeKind,dispositionKind,dispositionId,primaryWorkKind,
               primaryWorkId,workImpactKind,livenessTriggerKind,
               livenessTriggerId,actionNeeded
        FROM wake_cancellations WHERE wakeId=?1
        """,
        [wake_id]
      )

    row
  end

  defp rumination_wake_count(db) do
    {:ok, [[count]]} = DB.query(db, "SELECT count(*) FROM wakes WHERE rumination = 1")
    count
  end

  defp work_item_count(db) do
    {:ok, [[count]]} = DB.query(db, "SELECT count(*) FROM work_items")
    count
  end

  defp doorbell_count(db, work_item_id) do
    {:ok, [[count]]} =
      DB.query(
        db,
        "SELECT count(*) FROM work_item_events WHERE workItemId = ?1 AND kind = 'metadata'",
        [work_item_id]
      )

    count
  end

  defp assignment_state(db, id) do
    {:ok, [[state]]} = DB.query(db, "SELECT state FROM assignments WHERE id = ?1", [id])
    state
  end

  defp effort_state(db, assignment_id) do
    {:ok, rows} =
      DB.query(
        db,
        "SELECT state FROM effort_checkin_generations WHERE assignmentId = ?1 ORDER BY generation DESC LIMIT 1",
        [assignment_id]
      )

    case rows do
      [[state]] -> state
      [] -> nil
    end
  end

  defp item_ids(%{items: items}), do: Enum.map(items, & &1.workItem.id)

  # Register a work-state subscriber for a user. Each subscriber is its own
  # process because attribution is the subject here — which user's board a
  # doorbell reached — and `ConnRegistry` addresses a subscriber only by pid.
  defp observe(user_id) do
    observer = start_supervised!({Observer, []}, id: {:observer, user_id})

    {:ok, _, _} =
      Tightbeam.ConnRegistry.register(Tightbeam.ConnRegistry, %{
        pid: observer,
        user_id: user_id,
        device_id: "obs-#{user_id}",
        is_admin: false,
        subscriptions: MapSet.new(["work_state"])
      })

    observer
  end

  defp load_rules(ctx, toml) do
    base = Path.join(System.tmp_dir!(), "tb-brackets-rules-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(base, "identity/rules"))
    File.write!(Path.join(base, "identity/rules/statute.toml"), toml)
    Tightbeam.TerminalReactionFixture.load_work_items!(base, Map.keys(ctx.handlers))
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp origin({:user, user}), do: "user:#{user}"
  defp origin({:session, session}), do: "agent:#{session}"

  defp session(db, key, owner) do
    Org.create(db, %{
      session_key: key,
      display_name: key,
      kind: if(key == Org.personal_session_key(owner), do: "main", else: "custom"),
      owner_user_id: owner,
      origin: "user:#{owner}",
      archetype: "default",
      harness: "claude",
      provider: "anthropic",
      model: Model.new("fable"),
      host: "lab1"
    })
  end
end
