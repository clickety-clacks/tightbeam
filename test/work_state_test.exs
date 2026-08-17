defmodule Tightbeam.WorkStateTest do
  use Tightbeam.TestCase, async: false
  alias Tightbeam.Model

  alias Tightbeam.{
    Assignments,
    ConnRegistry,
    DB,
    Gateway,
    Org,
    WorkItems,
    WorkState
  }

  setup do
    db = :"work_state_db_#{System.unique_integer([:positive])}"
    start_supervised!({DB, path: ":memory:", name: db})
    start_supervised!({ConnRegistry, name: ConnRegistry})

    :ok = Tightbeam.Schema.ensure_all(db)

    {:ok, _} =
      DB.query(
        db,
        "INSERT INTO users (userId, isAdmin, createdAt) VALUES ('flynn', 0, 1), ('other', 0, 1)"
      )

    session(db, "holder", "flynn")
    session(db, "retiring", "flynn")
    session(db, "other-holder", "other")

    assignment_change = fn id, from -> WorkState.emit(db, id, from) end
    item_change = fn id, kind -> WorkState.emit_item(db, id, kind) end

    %{db: db, assignment_change: assignment_change, item_change: item_change}
  end

  test "status is total across all six precedence branches and verified is string-exact", ctx do
    open = assign(ctx, "holder", "open")

    active = assign(ctx, "holder", "active")
    attest(ctx, active.id, "progress")

    claims = assign(ctx, "holder", "claims")
    attest(ctx, claims.id, "verdict", "tests-passed")
    attest(ctx, claims.id, "completion")

    verified = assign(ctx, "holder", "verified")
    attest(ctx, verified.id, "verdict", "verified")
    attest(ctx, verified.id, "completion")

    abandoned = assign(ctx, "holder", "abandoned")
    revoke(ctx, abandoned.id)

    stranded = assign(ctx, "retiring", "stranded")
    Org.retire(ctx.db, "retiring", "user:flynn", 1_000)

    assert WorkState.status(ctx.db, open.id) == "open"
    assert WorkState.status(ctx.db, active.id) == "active"
    assert WorkState.status(ctx.db, claims.id) == "claims-done"
    assert WorkState.status(ctx.db, verified.id) == "verified"
    assert WorkState.status(ctx.db, abandoned.id) == "abandoned"
    assert WorkState.status(ctx.db, stranded.id) == "stranded"
    assert WorkState.status(ctx.db, "missing") == nil

    assert {:ok, _} =
             DB.query(
               ctx.db,
               "UPDATE sessions SET state = 'retired' WHERE sessionKey = 'holder'"
             )

    assert WorkState.status(ctx.db, claims.id) == "claims-done"
    assert WorkState.status(ctx.db, abandoned.id) == "abandoned"
  end

  test "both grains are random-access and event tables never feed non-cursor truth", ctx do
    item = create_item(ctx, "Feature")
    linked = assign(ctx, "holder", "linked", item.id)
    unlinked = assign(ctx, "holder", "unlinked")
    attest(ctx, linked.id, "progress")

    assignment_snapshot = WorkState.list(ctx.db, %{state: "all"})
    assignment_detail = WorkState.detail(ctx.db, linked.id)
    item_snapshot = WorkState.list_items(ctx.db, %{})
    item_detail = WorkState.item_detail(ctx.db, item.id)

    assert Enum.find(assignment_snapshot.work, &(&1.id == linked.id)).workItemId == item.id
    assert Enum.find(assignment_snapshot.work, &(&1.id == unlinked.id)).workItemId == nil
    assert assignment_detail.assignment.status == "active"
    assert [%{workItem: ^item, assignments: [%{id: id, status: "active"}]}] = item_snapshot.items
    assert id == linked.id
    refute Map.has_key?(hd(item_snapshot.items), :status)
    refute Map.has_key?(item_detail, :status)

    assert {:ok, _} = DB.query(ctx.db, "DELETE FROM work_state_events")
    assert {:ok, _} = DB.query(ctx.db, "DELETE FROM work_item_events")

    after_assignment = WorkState.list(ctx.db, %{state: "all"})
    after_assignment_detail = WorkState.detail(ctx.db, linked.id)
    after_items = WorkState.list_items(ctx.db, %{})
    after_item_detail = WorkState.item_detail(ctx.db, item.id)

    assert Map.delete(after_assignment, :cursor) == Map.delete(assignment_snapshot, :cursor)
    assert Map.delete(after_assignment_detail, :cursor) == Map.delete(assignment_detail, :cursor)
    assert Map.delete(after_items, :cursor) == Map.delete(item_snapshot, :cursor)
    assert Map.delete(after_item_detail, :cursor) == Map.delete(item_detail, :cursor)
    assert after_assignment.cursor == 0
    assert after_assignment_detail.cursor == 0
    assert after_items.cursor == %{assignment: 0, workItem: 0}
    assert after_item_detail.cursor == %{assignment: 0, workItem: 0}
    assert WorkState.status(ctx.db, linked.id) == "active"
  end

  test "emit halves return inserted maps, suppress unchanged edges, and keep cursors independent",
       ctx do
    assignment = assign(ctx, "holder", "edge")

    assert {:ok, [[1]]} = DB.query(ctx.db, "SELECT count(*) FROM work_state_events")
    assert WorkState.emit(ctx.db, assignment.id, "open") == nil

    item = create_item(ctx, "Item")
    first = WorkState.emit_item(ctx.db, item.id, "metadata")
    second = WorkState.emit_item(ctx.db, item.id, "composition")

    assert first.kind == "metadata"
    assert second.kind == "composition"
    assert second.cursor > first.cursor
    assert assignment_cursor(ctx.db) == 1
    assert item_cursor(ctx.db) == second.cursor
  end

  test "emit gates and reads its payload in the transaction that inserts the edge", ctx do
    assignment = assign(ctx, "holder", "atomic edge")
    db = Process.whereis(ctx.db)
    :sys.suspend(ctx.db)
    :erlang.trace(db, true, [:receive])
    on_exit(fn -> if Process.alive?(db), do: :erlang.trace(db, false, [:receive]) end)

    task = Task.async(fn -> WorkState.emit(ctx.db, assignment.id, nil) end)
    :sys.resume(ctx.db)

    assert %{assignmentId: id, sessionKey: "holder", toState: "open"} = Task.await(task)
    assert id == assignment.id

    delivered = :erlang.trace_delivered(db)
    assert_receive {:trace_delivered, ^db, ^delivered}

    requests = received_db_requests(db, [])
    assert [{:transaction, transaction}] = requests
    assert is_function(transaction, 1)
  end

  test "filters, ordering, item composition, and detail shapes are mechanical", ctx do
    item = create_item(ctx, "Concurrent")
    one = assign(ctx, "holder", "one", item.id)
    two = assign(ctx, "other-holder", "two", item.id)
    attest(ctx, two.id, "progress")

    expected =
      [one, two]
      |> Enum.sort_by(&{&1.openedAt, &1.id}, :desc)
      |> Enum.map(& &1.id)

    assert Enum.map(WorkState.list(ctx.db, %{state: "all"}).work, & &1.id) == expected

    assert Enum.map(WorkState.list(ctx.db, %{state: "all", status: ["active"]}).work, & &1.id) ==
             [two.id]

    assert Enum.map(WorkState.list(ctx.db, %{state: "all", session_key: "holder"}).work, & &1.id) ==
             [one.id]

    assert WorkState.list(ctx.db, %{state: "all", session_key: "missing"}).work == []

    [%{assignments: assignments}] = WorkState.list_items(ctx.db, %{}).items
    assert Enum.map(assignments, & &1.id) == expected
    assert WorkState.list_items(ctx.db, %{session_key: "missing"}).items == []

    detail = WorkState.detail(ctx.db, two.id)

    assert detail.holder == %{
             sessionKey: "other-holder",
             state: "active",
             displayName: "other-holder"
           }

    assert detail.supervision == nil
    assert [%{kind: "progress", verdictKind: nil}] = detail.attests
    assert WorkState.detail(ctx.db, "missing") == nil
    assert WorkState.item_detail(ctx.db, "missing") == nil
  end

  test "gateway mutation sites emit exact doorbells and suppress replays, no-ops, and equal states",
       ctx do
    {:ok, _, _} =
      ConnRegistry.register(ConnRegistry, %{
        pid: self(),
        user_id: "flynn",
        device_id: "observer",
        is_admin: false,
        subscriptions: MapSet.new(["work_state"])
      })

    handlers = Gateway.handlers(%{db: ctx.db, wake_tick_ms: 1_000})
    item = create_item(ctx, "Emitted")

    call =
      assign_call("holder", "linked", item.id)
      |> put_in([:params, :idempotency_key], "same")

    assignment = handlers["assign"].(call)

    assert_receive {:push, %{"type" => "work_state_event", "from" => nil, "to" => "open"}}
    assert_receive {:push, %{"type" => "work_item_event", "kind" => "composition"}}

    assert handlers["assign"].(call).id == assignment.id
    refute_receive {:push, _}

    handlers["attest"].(attest_call(assignment.id, "progress", "holder"))
    assert_receive {:push, %{"type" => "work_state_event", "from" => "open", "to" => "active"}}

    handlers["attest"].(attest_call(assignment.id, "progress", "holder"))
    refute_receive {:push, _}

    update = %{
      principal: {:user, "flynn"},
      params: %{work_item_id: item.id, title: "Changed"}
    }

    handlers["work-item-update"].(update)
    assert_receive {:push, %{"type" => "work_item_event", "kind" => "metadata"}}
    handlers["work-item-update"].(update)
    refute_receive {:push, _}

    assert {:ok, [[2]]} = DB.query(ctx.db, "SELECT count(*) FROM work_state_events")
    assert {:ok, [[2]]} = DB.query(ctx.db, "SELECT count(*) FROM work_item_events")
  end

  test "denied gateway verbs emit neither event rows nor frames", ctx do
    {:ok, _, _} =
      ConnRegistry.register(ConnRegistry, %{
        pid: self(),
        user_id: "flynn",
        device_id: "denied-observer",
        is_admin: false,
        subscriptions: MapSet.new(["work_state"])
      })

    handlers = Gateway.handlers(%{db: ctx.db, wake_tick_ms: 1_000})
    assignment = handlers["assign"].(assign_call("holder", "closed"))
    handlers["attest"].(attest_call(assignment.id, "completion", "holder"))
    flush_pushes()

    assignment_count = event_count(ctx.db, "work_state_events")
    item_count = event_count(ctx.db, "work_item_events")

    assert %{code: "assignment_closed"} =
             handlers["attest"].(attest_call(assignment.id, "progress", "holder"))

    assert event_count(ctx.db, "work_state_events") == assignment_count
    assert event_count(ctx.db, "work_item_events") == item_count
    refute_receive {:push, _}
  end

  test "emission failures preserve verb results and domain rows on both grains", ctx do
    item = create_item(ctx, "Before")
    assignment = assign(ctx, "holder", "failure", item.id)
    assert :ok = stop_supervised(ConnRegistry)

    handlers = Gateway.handlers(%{db: ctx.db, wake_tick_ms: 1_000})

    assert %{assignment: %{id: assignment_id}, attest: %{kind: "progress"}} =
             handlers["attest"].(attest_call(assignment.id, "progress", "holder"))

    assert assignment_id == assignment.id
    assert WorkState.status(ctx.db, assignment.id) == "active"

    update = %{
      principal: {:user, "flynn"},
      params: %{work_item_id: item.id, title: "After"}
    }

    assert %{id: item_id, title: "After"} = handlers["work-item-update"].(update)
    assert item_id == item.id
    assert WorkState.item_detail(ctx.db, item.id).workItem.title == "After"
    assert event_count(ctx.db, "work_state_events") == 2
    assert event_count(ctx.db, "work_item_events") == 2
  end

  test "client contract converges after duplicate and reordered delivery and heals explicit drops",
       ctx do
    {:ok, _, _} =
      ConnRegistry.register(ConnRegistry, %{
        pid: self(),
        user_id: "flynn",
        device_id: "client-observer",
        is_admin: false,
        subscriptions: MapSet.new(["work_state"])
      })

    handlers = Gateway.handlers(%{db: ctx.db, wake_tick_ms: 1_000})
    item = create_item(ctx, "Original")
    assignment_snapshot = WorkState.list(ctx.db, %{state: "all"})
    item_snapshot = WorkState.item_detail(ctx.db, item.id)

    assignment = handlers["assign"].(assign_call("holder", "client", item.id))
    handlers["attest"].(attest_call(assignment.id, "progress", "holder"))

    handlers["work-item-update"].(%{
      principal: {:user, "flynn"},
      params: %{work_item_id: item.id, title: "Current"}
    })

    handlers["attest"].(attest_call(assignment.id, "completion", "holder"))
    frames = receive_pushes(5)
    assignment_frames = Enum.filter(frames, &(&1["type"] == "work_state_event"))
    item_frames = Enum.filter(frames, &(&1["type"] == "work_item_event"))

    assignment_truth = assignment_truth(ctx.db)
    item_truth = item_truth(ctx.db, item.id)

    for schedule <- [
          Enum.flat_map(assignment_frames, &[&1, &1]),
          Enum.reverse(assignment_frames) ++ Enum.reverse(assignment_frames)
        ] do
      client =
        Enum.reduce(schedule, assignment_client(assignment_snapshot), fn frame, client ->
          consume_assignment(client, frame, ctx.db)
        end)

      assert client.view == assignment_truth
    end

    for schedule <- [
          Enum.flat_map(item_frames, &[&1, &1]),
          Enum.reverse(item_frames) ++ Enum.reverse(item_frames)
        ] do
      client =
        Enum.reduce(schedule, item_client(item_snapshot), fn frame, client ->
          consume_item(client, frame, ctx.db)
        end)

      assert client.view == item_truth
    end

    dropped_item = create_item(ctx, "Dropped composition")
    stale_item_client = item_client(WorkState.item_detail(ctx.db, dropped_item.id))
    dropped_assignment = handlers["assign"].(assign_call("holder", "dropped", dropped_item.id))

    # Exact shapes, not blind binds: a `_frame` match cannot fail for its
    # stated reason — it would swallow any frame at all. (Salvaged from the
    # observability worktree's uncommitted delta, 2026-08-04.)
    [
      %{"type" => "work_state_event", "from" => nil, "to" => "open"},
      %{"type" => "work_item_event", "kind" => "composition"}
    ] = receive_pushes(2)

    handlers["attest"].(attest_call(dropped_assignment.id, "progress", "holder"))
    [%{"type" => "work_state_event", "from" => "open", "to" => "active"}] = receive_pushes(1)
    stale_assignment_client = assignment_client(WorkState.list(ctx.db, %{state: "all"}))
    handlers["attest"].(attest_call(dropped_assignment.id, "completion", "holder"))

    [%{"type" => "work_state_event", "from" => "active", "to" => "claims-done"}] =
      receive_pushes(1)

    refute stale_assignment_client.view == assignment_truth(ctx.db)
    refute stale_item_client.view == item_truth(ctx.db, dropped_item.id)

    healed_assignment = refetch_assignment(stale_assignment_client, dropped_assignment.id, ctx.db)
    healed_item = refetch_item(stale_item_client, dropped_item.id, ctx.db)

    assert healed_assignment.view == assignment_truth(ctx.db)
    assert healed_item.view == item_truth(ctx.db, dropped_item.id)
  end

  test "retire captures every open assignment pre-state before terminal interruption",
       ctx do
    {:ok, _, _} =
      ConnRegistry.register(ConnRegistry, %{
        pid: self(),
        user_id: "flynn",
        device_id: "retire-observer",
        is_admin: false,
        subscriptions: MapSet.new(["work_state"])
      })

    parent = self()

    handlers =
      Gateway.handlers(%{
        db: ctx.db,
        wake_tick_ms: 1_000,
        on_retired: fn key -> send(parent, {:retired, key}) end
      })

    open = handlers["assign"].(assign_call("retiring", "open"))
    active = handlers["assign"].(assign_call("retiring", "active"))
    handlers["attest"].(attest_call(active.id, "progress", "retiring"))

    flush_pushes()
    {:ok, _} = DB.query(ctx.db, "DELETE FROM work_state_events")

    result =
      handlers["retire"].(%{
        origin: "user:flynn",
        session_key: "retiring",
        params: %{}
      })

    assert result == %{
             deleted_session_key: "retiring",
             retired_session_keys: ["retiring"],
             deferred: []
           }

    assert_receive {:retired, "retiring"}
    assert_receive {:push, first}
    assert_receive {:push, second}

    observed = MapSet.new(Enum.map([first, second], &{&1["ref"], &1["from"], &1["to"]}))

    assert observed ==
             MapSet.new([
               {open.id, "open", "abandoned"},
               {active.id, "active", "abandoned"}
             ])

    assert {:ok, rows} = DB.query(ctx.db, "SELECT fromState, toState FROM work_state_events")
    assert MapSet.new(rows) == MapSet.new([["open", "abandoned"], ["active", "abandoned"]])
  end

  defp create_item(ctx, title) do
    WorkItems.__handle__(ctx.db, "work-item-create", %{
      verb: "work-item-create",
      origin: "user:flynn",
      principal: {:user, "flynn"},
      session_key: nil,
      params: %{title: title}
    })
  end

  defp assign(ctx, holder, subject, work_item_id \\ nil) do
    Assignments.__handle__(ctx.db, "assign", %{
      verb: "assign",
      origin: "user:flynn",
      principal: {:user, "flynn"},
      session_key: holder,
      target_role: nil,
      role_fallback: false,
      supervision_interval_ms: 1_000,
      params: %{subject: subject, work_item_id: work_item_id, effect_kind: "coordination"},
      on_assignment_change: ctx.assignment_change,
      on_work_item_change: ctx.item_change
    })
  end

  defp assign_call(holder, subject, work_item_id \\ nil) do
    %{
      origin: "user:flynn",
      principal: {:user, "flynn"},
      session_key: holder,
      target_role: nil,
      role_fallback: false,
      supervision_interval_ms: 1_000,
      params: %{subject: subject, work_item_id: work_item_id, effect_kind: "coordination"}
    }
  end

  defp attest_call(assignment_id, kind, holder) do
    %{
      origin: "agent:#{holder}",
      principal: {:session, holder},
      session_key: holder,
      params: %{assignment_id: assignment_id, kind: kind}
    }
  end

  defp attest(ctx, assignment_id, kind, verdict_kind \\ nil) do
    {:ok, [[holder]]} =
      DB.query(ctx.db, "SELECT holderKey FROM assignments WHERE id = ?1", [assignment_id])

    Assignments.__handle__(ctx.db, "attest", %{
      verb: "attest",
      origin: "agent:#{holder}",
      principal: {:session, holder},
      session_key: holder,
      params: %{assignment_id: assignment_id, kind: kind, verdict_kind: verdict_kind},
      on_assignment_change: ctx.assignment_change
    })
  end

  defp revoke(ctx, assignment_id) do
    Assignments.__handle__(ctx.db, "revoke-assignment", %{
      verb: "revoke-assignment",
      origin: "user:flynn",
      principal: {:user, "flynn"},
      session_key: nil,
      params: %{assignment_id: assignment_id},
      on_assignment_change: ctx.assignment_change
    })
  end

  defp session(db, key, owner) do
    Org.create(db, %{
      session_key: key,
      display_name: key,
      owner_user_id: owner,
      origin: "user:#{owner}",
      archetype: "default",
      host: "testhost",
      harness: "claude",
      provider: "anthropic",
      model: Model.new("fable")
    })
  end

  defp assignment_cursor(db) do
    {:ok, [[cursor]]} = DB.query(db, "SELECT COALESCE(MAX(id), 0) FROM work_state_events")
    cursor
  end

  defp item_cursor(db) do
    {:ok, [[cursor]]} = DB.query(db, "SELECT COALESCE(MAX(id), 0) FROM work_item_events")
    cursor
  end

  defp received_db_requests(db, acc) do
    receive do
      {:trace, ^db, :receive, {:"$gen_call", _from, request}} ->
        received_db_requests(db, [request | acc])

      {:trace, ^db, :receive, _message} ->
        received_db_requests(db, acc)
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp event_count(db, table) do
    {:ok, [[count]]} = DB.query(db, "SELECT count(*) FROM #{table}")
    count
  end

  defp receive_pushes(count) do
    for _ <- 1..count do
      assert_receive {:push, frame}
      frame
    end
  end

  defp assignment_client(snapshot) do
    %{view: Map.new(snapshot.work, &{&1.id, &1.status}), cursor: snapshot.cursor}
  end

  defp consume_assignment(client, frame, db) do
    cond do
      frame["cursor"] <= client.cursor ->
        client

      Map.get(client.view, frame["ref"]) == frame["from"] ->
        %{client | view: Map.put(client.view, frame["ref"], frame["to"]), cursor: frame["cursor"]}

      true ->
        refetch_assignment(client, frame["ref"], db)
    end
  end

  defp refetch_assignment(client, assignment_id, db) do
    detail = WorkState.detail(db, assignment_id)

    %{
      client
      | view: Map.put(client.view, assignment_id, detail.assignment.status),
        cursor: detail.cursor
    }
  end

  defp assignment_truth(db) do
    snapshot = WorkState.list(db, %{state: "all"})
    Map.new(snapshot.work, &{&1.id, &1.status})
  end

  defp item_client(snapshot) do
    %{view: Map.delete(snapshot, :cursor), cursor: snapshot.cursor.workItem}
  end

  defp consume_item(client, frame, db) do
    if frame["cursor"] <= client.cursor,
      do: client,
      else: refetch_item(client, frame["ref"], db)
  end

  defp refetch_item(client, work_item_id, db) do
    detail = WorkState.item_detail(db, work_item_id)
    %{client | view: Map.delete(detail, :cursor), cursor: detail.cursor.workItem}
  end

  defp item_truth(db, work_item_id) do
    db
    |> WorkState.item_detail(work_item_id)
    |> Map.delete(:cursor)
  end

  defp flush_pushes do
    receive do
      {:push, _} -> flush_pushes()
    after
      0 -> :ok
    end
  end
end
