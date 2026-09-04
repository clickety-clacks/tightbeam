defmodule Tightbeam.Stall410Test do
  use Tightbeam.TestCase, async: false

  alias Tightbeam.{DB, Model, Org, Schema, Wakes, WorkItems}

  setup do
    db = :stall_410_db
    start_supervised!({DB, path: ":memory:", name: db})
    :ok = Tightbeam.Schema.ensure_all(db)

    {:ok, _} =
      DB.query(
        db,
        "INSERT INTO users (userId,isAdmin,creationKind,createdAt) VALUES ('mike',0,'admin_add',1),('other',0,'admin_add',1)"
      )

    mike_session = session(db, Org.personal_session_key("mike"), "mike")
    _other_session = session(db, Org.personal_session_key("other"), "other")
    %{db: db, mike_session: mike_session}
  end

  test "direct and relayed Mike provenance qualify; another user's item does not", ctx do
    direct = create(ctx.db, {:user, "mike"}, "direct")
    relayed = create(ctx.db, {:session, ctx.mike_session.session_key}, "relayed")
    other = create(ctx.db, {:user, "other"}, "other")
    behind = create(ctx.db, {:user, "mike"}, "behind")

    assert %{mode: "notice"} = deprioritize(ctx.db, {:user, "mike"}, direct.id, behind.id, "d1")
    assert %{mode: "notice"} = deprioritize(ctx.db, {:user, "mike"}, relayed.id, behind.id, "d2")

    assert %{code: "not_mike_sourced"} =
             deprioritize(ctx.db, {:user, "other"}, other.id, other.id, "o1")

    assert {:ok, [[4]]} = DB.query(ctx.db, "SELECT count(*) FROM work_item_sources")
  end

  test "notice is exactly once on keyed replay and wrong owner cannot file it", ctx do
    item = create(ctx.db, {:user, "mike"}, "item")
    behind = create(ctx.db, {:user, "mike"}, "behind")

    first = deprioritize(ctx.db, {:user, "mike"}, item.id, behind.id, "same")
    assert %{mode: "notice"} = first

    assert %{replayed: true, mode: "notice"} =
             deprioritize(ctx.db, {:user, "mike"}, item.id, behind.id, "same")

    assert {:ok, [[1]]} =
             DB.query(
               ctx.db,
               "SELECT count(*) FROM lifecycle_events WHERE kind='work_item_deprioritized' AND subject=?1",
               [item.id]
             )

    assert %{code: "not_authorized"} =
             deprioritize(ctx.db, {:user, "other"}, item.id, behind.id, "wrong")
  end

  test "owner session can ask which named priority wins", ctx do
    item = create(ctx.db, {:user, "mike"}, "item")
    behind = create(ctx.db, {:user, "mike"}, "behind")

    assert %{mode: "decision_request", decisionRequest: %{kind: "operator"} = request} =
             WorkItems.__handle__(
               ctx.db,
               "work-item-deprioritize",
               call({:session, ctx.mike_session.session_key}, %{
                 work_item_id: item.id,
                 behind_work_item_id: behind.id,
                 mode: :ask,
                 idempotency_key: "ask"
               })
             )

    assert request.question == "Which priority wins: #{item.id} or #{behind.id}?"
    request_id = request.id

    assert %{replayed: true, rowId: ^request_id} =
             WorkItems.__handle__(
               ctx.db,
               "work-item-deprioritize",
               call({:session, ctx.mike_session.session_key}, %{
                 work_item_id: item.id,
                 behind_work_item_id: behind.id,
                 mode: :ask,
                 idempotency_key: "ask"
               })
             )
  end

  test "moving a boundary rearms it and only the current generation escalates", ctx do
    item = create(ctx.db, {:user, "mike"}, "goal")
    first = boundary(ctx.db, item.id, "design ready", 1000, "b1")
    second = boundary(ctx.db, item.id, "implementation ready", 1000, "b2")
    assert second.generation == first.generation + 1

    assert %{code: "boundary_not_moved"} =
             boundary(ctx.db, item.id, "implementation ready", 1000, "b3")

    {:ok, :ok} =
      DB.transaction(ctx.db, fn txn ->
        WorkItems.rearm_on_fire_in_txn(txn, first.wakeId, %{work_item_id: item.id})
        WorkItems.rearm_on_fire_in_txn(txn, second.wakeId, %{work_item_id: item.id})
      end)

    assert {:ok, [["escalated", 1]]} =
             DB.query(
               ctx.db,
               "SELECT state, count(*) FROM work_item_horizons WHERE workItemId=?1 GROUP BY state",
               [item.id]
             )

    assert {:ok, [[1]]} =
             DB.query(
               ctx.db,
               "SELECT count(*) FROM lifecycle_events WHERE kind='work_item_horizon_escalated' AND subject=?1",
               [item.id]
             )
  end

  test "every terminal disposition cancels its armed horizon and pending wake", ctx do
    for {verb, target, params} <- [
          {"work-item-close", "closed", %{}},
          {"work-item-icebox", "iceboxed", %{}},
          {"work-item-fail", "failed", %{reason: "no longer viable"}}
        ] do
      item = create(ctx.db, {:user, "mike"}, "#{target} goal")
      horizon = boundary(ctx.db, item.id, "#{target} boundary", 1_000, "#{target}-horizon")

      assert %{ok: true, workItem: %{state: ^target}} =
               WorkItems.__handle__(
                 ctx.db,
                 verb,
                 call({:user, "mike"}, Map.put(params, :work_item_id, item.id))
               )

      assert {:ok, [["canceled", nil]]} =
               DB.query(
                 ctx.db,
                 "SELECT state,escalatedAt FROM work_item_horizons WHERE workItemId=?1",
                 [item.id]
               )

      assert Wakes.get(ctx.db, horizon.wakeId).state == "canceled"

      assert {:ok,
              [["tightbeam:work-items", "routing_bracket_satisfied", "work_item_transition"]]} =
               DB.query(
                 ctx.db,
                 "SELECT requesterId,reasonKind,causalSourceKind FROM wake_cancellations WHERE wakeId=?1",
                 [horizon.wakeId]
               )

      {:ok, :ok} =
        DB.transaction(ctx.db, fn txn ->
          WorkItems.rearm_on_fire_in_txn(txn, horizon.wakeId, %{work_item_id: item.id})
        end)

      assert {:ok, [["canceled"]]} =
               DB.query(ctx.db, "SELECT state FROM work_item_horizons WHERE workItemId=?1", [
                 item.id
               ])

      assert {:ok, [[0]]} =
               DB.query(
                 ctx.db,
                 "SELECT count(*) FROM lifecycle_events WHERE kind='work_item_horizon_escalated' AND subject=?1",
                 [item.id]
               )
    end
  end

  test "terminal delivery race orders preserve true prior escalation and reject late replay",
       ctx do
    delivered_first = create(ctx.db, {:user, "mike"}, "delivered first")
    first_horizon = boundary(ctx.db, delivered_first.id, "first", 1_000, "race-first")

    {:ok, :ok} =
      DB.transaction(ctx.db, fn txn ->
        WorkItems.rearm_on_fire_in_txn(txn, first_horizon.wakeId, %{
          work_item_id: delivered_first.id
        })
      end)

    assert %{ok: true} =
             WorkItems.__handle__(
               ctx.db,
               "work-item-close",
               call({:user, "mike"}, %{work_item_id: delivered_first.id})
             )

    assert {:ok, [["escalated"]]} =
             DB.query(
               ctx.db,
               "SELECT state FROM work_item_horizons WHERE workItemId=?1",
               [delivered_first.id]
             )

    assert {:ok, [[1]]} =
             DB.query(
               ctx.db,
               "SELECT count(*) FROM lifecycle_events WHERE kind='work_item_horizon_escalated' AND subject=?1",
               [delivered_first.id]
             )

    terminal_first = create(ctx.db, {:user, "mike"}, "terminal first")
    second_horizon = boundary(ctx.db, terminal_first.id, "second", 1_000, "race-second")

    assert %{ok: true} =
             WorkItems.__handle__(
               ctx.db,
               "work-item-close",
               call({:user, "mike"}, %{work_item_id: terminal_first.id})
             )

    for _ <- 1..2 do
      {:ok, :ok} =
        DB.transaction(ctx.db, fn txn ->
          WorkItems.rearm_on_fire_in_txn(txn, second_horizon.wakeId, %{
            work_item_id: terminal_first.id
          })
        end)
    end

    assert {:ok, [["canceled"]]} =
             DB.query(
               ctx.db,
               "SELECT state FROM work_item_horizons WHERE workItemId=?1",
               [terminal_first.id]
             )

    assert {:ok, [[0]]} =
             DB.query(
               ctx.db,
               "SELECT count(*) FROM lifecycle_events WHERE kind='work_item_horizon_escalated' AND subject=?1",
               [terminal_first.id]
             )
  end

  test "v16 horizon migration keeps declared history and enables terminal cancellation", ctx do
    item = create(ctx.db, {:user, "mike"}, "migrated goal")
    horizon = boundary(ctx.db, item.id, "legacy boundary", 1_000, "legacy-horizon")

    :ok = DB.execute(ctx.db, "ALTER TABLE work_item_horizons RENAME TO work_item_horizons_v17")

    :ok =
      DB.execute(
        ctx.db,
        """
        CREATE TABLE work_item_horizons (
          workItemId TEXT PRIMARY KEY REFERENCES work_items(id),
          generation INTEGER NOT NULL CHECK(generation > 0),
          boundary TEXT NOT NULL CHECK(length(trim(boundary)) BETWEEN 1 AND 2000),
          dueAt INTEGER NOT NULL,
          wakeId TEXT NOT NULL UNIQUE REFERENCES wakes(wakeId),
          state TEXT NOT NULL CHECK(state IN ('armed','moved','escalated')),
          declaredAt INTEGER NOT NULL,
          escalatedAt INTEGER NULL,
          CHECK((state = 'escalated' AND escalatedAt IS NOT NULL) OR
                (state IN ('armed','moved') AND escalatedAt IS NULL))
        )
        """
      )

    :ok =
      DB.execute(
        ctx.db,
        """
        INSERT INTO work_item_horizons
          (workItemId,generation,boundary,dueAt,wakeId,state,declaredAt,escalatedAt)
        SELECT workItemId,generation,boundary,dueAt,wakeId,state,declaredAt,escalatedAt
        FROM work_item_horizons_v17
        """
      )

    :ok = DB.execute(ctx.db, "DROP TABLE work_item_horizons_v17")

    :ok =
      DB.execute(
        ctx.db,
        "UPDATE schema_stamp SET shape='coordination-fabric-v1-phase1-v16'"
      )

    :ok = Schema.upgrade_terminal_horizon_cancellation_v1(ctx.db)

    assert {:ok, [["coordination-fabric-v1-phase1-v17"]]} =
             DB.query(ctx.db, "SELECT shape FROM schema_stamp")

    assert {:ok, [[1, "legacy boundary", horizon_wake, "armed"]]} =
             DB.query(
               ctx.db,
               "SELECT generation,boundary,wakeId,state FROM work_item_horizons WHERE workItemId=?1",
               [item.id]
             )

    assert horizon_wake == horizon.wakeId

    assert %{ok: true} =
             WorkItems.__handle__(
               ctx.db,
               "work-item-fail",
               call({:user, "mike"}, %{work_item_id: item.id, reason: "migrated terminal"})
             )

    assert {:ok, [["canceled"]]} =
             DB.query(ctx.db, "SELECT state FROM work_item_horizons WHERE workItemId=?1", [
               item.id
             ])
  end

  defp create(db, principal, title),
    do: WorkItems.__handle__(db, "work-item-create", call(principal, %{title: title}))

  defp deprioritize(db, principal, item, behind, key),
    do:
      WorkItems.__handle__(
        db,
        "work-item-deprioritize",
        call(principal, %{
          work_item_id: item,
          behind_work_item_id: behind,
          mode: :notice,
          pickup_horizon_ms: 1_000,
          idempotency_key: key
        })
      )

  defp boundary(db, item, boundary, horizon, key),
    do:
      WorkItems.__handle__(
        db,
        "work-item-boundary",
        call({:user, "mike"}, %{
          work_item_id: item,
          boundary: boundary,
          horizon_ms: horizon,
          idempotency_key: key
        })
      )

  defp call(principal, params),
    do: %{verb: "work-item-duty", origin: "agent:duty", principal: principal, params: params}

  defp session(db, key, owner) do
    Org.create(db, %{
      session_key: key,
      display_name: key,
      owner_user_id: owner,
      origin: "user:#{owner}",
      archetype: "default",
      harness: "claude",
      provider: "anthropic",
      model: Model.new("fable"),
      host: "eezo"
    })
  end
end
