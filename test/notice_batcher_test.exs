defmodule Tightbeam.NoticeBatcherTest do
  use Tightbeam.TestCase, async: false

  alias Tightbeam.{AdminProjection, DB, EventLog, Gateway, NoticeBatcher, Org, Roles, Wakes}

  setup do
    id = System.unique_integer([:positive])
    path = Path.expand("tmp/notice-batching/#{id}.sqlite3")
    File.mkdir_p!(Path.dirname(path))
    name = :"notice_batch_db_#{id}"
    start_supervised!({DB, path: path, name: name}, id: name)
    :ok = ensure_all_schemas(name)
    on_exit(fn -> File.rm(path) end)
    %{db: name, path: path}
  end

  test "acceptance 1: routine envelope preserves two sources and commits one recipient turn",
       %{db: db} do
    first = eligible(db, prompt: "alpha")
    second = eligible(db, prompt: "beta")
    [carrier_id] = Wakes.materialize_digests(db, second.due_at)
    carrier = Wakes.get(db, carrier_id)

    assert carrier.prompt =~ first.wake_id
    assert carrier.prompt =~ second.wake_id
    assert carrier.prompt =~ "alpha"
    assert carrier.prompt =~ "beta"
    assert source_ids(db, carrier_id) == [first.wake_id, second.wake_id]

    {:ok, _} = DB.query(db, "UPDATE wakes SET dueAt=0 WHERE wakeId=?1", [carrier_id])
    scheduler = start_scheduler(db, fn wake -> commit_turn(db, wake) end)
    assert :ok = Wakes.fire_due(scheduler)
    assert count(db, "turns", "wakeId=?1", [carrier_id]) == 1
  end

  test "acceptance 2: user-authored fyi bypasses membership and keeps the ordinary path",
       %{db: db} do
    _open = eligible(db, prompt: "routine")

    user =
      Wakes.schedule(db, %{
        session_key: "agent:recipient",
        origin: "user:mike",
        prompt: "human message",
        due_at: 0,
        class: "fyi"
      })

    assert NoticeBatcher.source_refs(db, user.wake_id) == []
    scheduler = start_scheduler(db, fn _wake -> true end)
    assert :ok = Wakes.fire_due(scheduler)
    assert Wakes.get(db, user.wake_id).state == "fired"
  end

  test "acceptance 3: urgent classes bypass while agent-authored fyi joins the selected lane",
       %{db: db} do
    routine = eligible(db)

    for class <- ~w(input-needed blocker algedonic) do
      wake = ordinary(db, class, "urgent #{class}")
      assert NoticeBatcher.source_refs(db, wake.wake_id) == []
    end

    agent_fyi = ordinary(db, "fyi", "pre-v2 agent message")
    assert [%{batch_id: agent_batch}] = NoticeBatcher.source_refs(db, agent_fyi.wake_id)
    assert agent_batch == batch_id(db, routine)

    assert NoticeBatcher.batch(db, batch_id(db, routine)).member_count == 2
  end

  test "acceptance 4: blocker publication leaves the fyi batch unchanged", %{db: db} do
    routine = eligible(db)
    before = NoticeBatcher.batch(db, batch_id(db, routine))
    blocker = ordinary(db, "blocker", "stop")
    after_batch = NoticeBatcher.batch(db, before.batch_id)

    assert NoticeBatcher.source_refs(db, blocker.wake_id) == []

    assert {after_batch.member_count, after_batch.rendered_bytes, after_batch.due_at} ==
             {before.member_count, before.rendered_bytes, before.due_at}
  end

  test "acceptance 5: rows-only status query creates no batch state", %{db: db} do
    status =
      Wakes.schedule(db, %{
        session_key: "agent:recipient",
        origin: "process:tightbeam",
        consumer: "internal",
        prompt: "rows answer",
        due_at: 0,
        class: "status-query"
      })

    assert NoticeBatcher.source_refs(db, status.wake_id) == []
    assert count(db, "notice_batch_members") == 0
    assert count(db, "notice_batches") == 0
  end

  test "acceptance 6: ceiling seals then arms without a decision or desk dependency", %{db: db} do
    source = eligible(db)
    assert Wakes.materialize_digests(db, source.due_at - 1) == []
    [carrier_id] = Wakes.materialize_digests(db, source.due_at)
    batch = NoticeBatcher.batch(db, batch_id(db, source))

    assert batch.state == "delivery_pending"
    assert batch.release_cause == "ceiling"
    assert batch.delivery_wake_id == carrier_id
    assert count(db, "decision_requests") == 0
  end

  test "acceptance 7: a terminal turn boundary releases before the ceiling", %{db: db} do
    source = eligible(db)
    boundary = source.created_at + 5
    terminal_turn(db, source.session_key, boundary)
    [carrier_id] = Wakes.materialize_digests(db, boundary + 1)

    assert Wakes.get(db, carrier_id).due_at == boundary + 1
    assert NoticeBatcher.batch(db, batch_id(db, source)).release_cause == "turn-boundary"
    assert boundary + 1 < source.due_at
  end

  test "acceptance 8: boundary and insertion race assigns the later source exactly once",
       %{db: db} do
    first = eligible(db, prompt: "first")
    terminal_turn(db, first.session_key, first.created_at + 1)

    insert = Task.async(fn -> eligible(db, prompt: "racing") end)
    seal = Task.async(fn -> Wakes.materialize_digests(db, first.created_at + 2) end)
    later = Task.await(insert)
    _ = Task.await(seal)
    _ = Wakes.materialize_digests(db, later.due_at)

    assert count(db, "notice_batch_members", "sourceWakeId=?1", [later.wake_id]) == 1
    assert length(NoticeBatcher.source_refs(db, later.wake_id)) == 1
  end

  test "acceptance 9: equal source timestamps retain publication sequence order", %{db: db} do
    sources = for payload <- ~w(one two three), do: eligible(db, prompt: payload)
    stamp = hd(sources).created_at

    for source <- sources do
      {:ok, _} =
        DB.query(db, "UPDATE wakes SET createdAt=?2 WHERE wakeId=?1", [source.wake_id, stamp])
    end

    [carrier_id] = Wakes.materialize_digests(db, List.last(sources).due_at)
    assert source_ids(db, carrier_id) == Enum.map(sources, & &1.wake_id)
  end

  test "acceptance 10: the 51st member starts the next ordered batch", %{db: db} do
    sources = for n <- 1..51, do: eligible(db, prompt: "notice #{n}")
    first_batch = batch_id(db, hd(sources))
    second_batch = batch_id(db, List.last(sources))

    assert first_batch != second_batch
    assert NoticeBatcher.batch(db, first_batch).member_count == 50

    assert NoticeBatcher.members(db, first_batch) |> Enum.map(& &1.source_wake_id) ==
             Enum.take(Enum.map(sources, & &1.wake_id), 50)

    assert NoticeBatcher.members(db, second_batch) |> Enum.map(& &1.source_wake_id) ==
             [List.last(sources).wake_id]

    sealed = NoticeBatcher.batch(db, first_batch)
    assert sealed.state == "sealed"
    assert sealed.release_cause == "overflow"
    assert sealed.delivery_wake_id == nil

    assert {:ok, :noop} =
             DB.transaction(db, fn txn ->
               NoticeBatcher.enqueue_or_recover_in_txn(txn, {:arm, first_batch})
             end)

    assert NoticeBatcher.recover(db, sealed.due_at - 1) == []
    assert NoticeBatcher.batch(db, first_batch).delivery_wake_id == nil

    carrier_ids = NoticeBatcher.recover(db, sealed.due_at)
    armed = NoticeBatcher.batch(db, first_batch)
    assert armed.delivery_wake_id in carrier_ids
    assert Wakes.get(db, armed.delivery_wake_id).due_at == sealed.due_at
  end

  test "acceptance 11: the payload limit seals a prefix and never truncates the candidate",
       %{db: db} do
    first = eligible(db, prompt: String.duplicate("a", 1_000))
    payload = String.duplicate("b", 65_000)
    candidate = eligible(db, prompt: payload)

    assert batch_id(db, first) != batch_id(db, candidate)
    assert [%{payload: ^payload}] = NoticeBatcher.members(db, batch_id(db, candidate))
    sealed = NoticeBatcher.batch(db, batch_id(db, first))
    assert sealed.state == "sealed"
    assert sealed.release_cause == "overflow"
    assert NoticeBatcher.recover(db, sealed.due_at - 1) == []
    assert NoticeBatcher.batch(db, sealed.batch_id).delivery_wake_id == nil
  end

  test "an overflow-sealed prefix arms at the recipient boundary before its ceiling", %{db: db} do
    sources = for n <- 1..51, do: eligible(db, prompt: "boundary notice #{n}")
    first_batch_id = batch_id(db, hd(sources))
    sealed = NoticeBatcher.batch(db, first_batch_id)
    boundary = sealed.opened_at + 1

    assert sealed.release_cause == "overflow"
    assert boundary < sealed.due_at
    terminal_turn(db, sealed.session_key, boundary)

    carrier_ids = NoticeBatcher.recover(db, boundary)
    armed = NoticeBatcher.batch(db, first_batch_id)

    assert armed.delivery_wake_id in carrier_ids
    assert Wakes.get(db, armed.delivery_wake_id).due_at == boundary

    assert Enum.any?(EventLog.lifecycle_events(db), fn event ->
             event.kind == "wake_digest_materialized" and
               event.subject == armed.delivery_wake_id and
               event.detail =~ "trigger=turn-boundary"
           end)
  end

  test "acceptance 12: replay returns one member and one batch", %{db: db} do
    source = eligible(db)
    ref = NoticeBatcher.policy_ref(source.wake_id)
    first = NoticeBatcher.enqueue_or_recover(db, source.wake_id, ref)
    second = NoticeBatcher.enqueue_or_recover(db, source.wake_id, ref)

    assert first == second
    assert count(db, "notice_batch_members", "sourceWakeId=?1", [source.wake_id]) == 1
  end

  test "acceptance 13: a reopened file arms one wake from an already sealed batch",
       %{db: db, path: path} do
    source = eligible(db)
    batch_id = batch_id(db, source)

    assert {:ok, :sealed} =
             DB.transaction(db, fn txn ->
               NoticeBatcher.enqueue_or_recover_in_txn(
                 txn,
                 {:seal_if_due, batch_id, source.due_at}
               )
             end)

    assert count(db, "wakes", "digest=1") == 0
    reopened = :"reopened_#{System.unique_integer([:positive])}"
    start_supervised!({DB, path: path, name: reopened}, id: reopened)
    [carrier_id] = NoticeBatcher.recover(reopened, source.due_at)
    batch = NoticeBatcher.batch(reopened, batch_id)

    assert count(reopened, "wakes", "wakeId=?1", [carrier_id]) == 1
    assert source_ids(reopened, carrier_id) == [source.wake_id]

    assert %{wake_id: ^carrier_id} =
             NoticeBatcher.deliver_batch(reopened, batch_id, batch.delivery_token)
  end

  test "acceptance 14: transient failure retries while unresolved delivery terminates", %{db: db} do
    source = eligible(db)
    [carrier_id] = Wakes.materialize_digests(db, source.due_at)
    {:ok, _} = DB.query(db, "UPDATE wakes SET dueAt=0 WHERE wakeId=?1", [carrier_id])

    failed = start_scheduler(db, fn _ -> raise "transient delivery failure" end)
    assert :ok = Wakes.fire_due(failed)
    GenServer.stop(failed)
    assert NoticeBatcher.batch(db, batch_id(db, source)).retry_count == 1

    succeeded = start_scheduler(db, fn wake -> commit_turn(db, wake) end)
    assert :ok = Wakes.fire_due(succeeded)
    batch = NoticeBatcher.batch(db, batch_id(db, source))
    assert batch.delivery_wake_id == carrier_id
    assert batch.state == "delivered"
    assert count(db, "turns", "wakeId=?1", [carrier_id]) == 1

    unresolved = eligible(db, session: "agent:unresolved")
    [unresolved_carrier] = Wakes.materialize_digests(db, unresolved.due_at)
    {:ok, _} = DB.query(db, "UPDATE wakes SET dueAt=0 WHERE wakeId=?1", [unresolved_carrier])

    terminal =
      start_scheduler(db, fn wake ->
        Gateway.deliver_prompt(wake.session_key, wake.origin, wake.prompt,
          db: db,
          wake_id: wake.wake_id,
          sender: wake.origin,
          target_gate: if(wake.target_gate == 0, do: nil, else: wake),
          fire_wake_in_txn: true
        )
      end)

    assert :ok = Wakes.fire_due(terminal)
    failed_batch = NoticeBatcher.batch(db, batch_id(db, unresolved))
    assert failed_batch.state == "delivery_failed"
    assert failed_batch.terminal_cause == ":skipped"
    assert failed_batch.terminal_principal == "process:tightbeam:wake-scheduler"
    assert failed_batch.retry_count == 0
    assert Wakes.get(db, unresolved_carrier).state == "fired"

    assert :ok = Wakes.fire_due(terminal)
    assert NoticeBatcher.batch(db, failed_batch.batch_id).retry_count == 0
  end

  test "acceptance 15: post-commit recovery marks terminal without a second edge", %{db: db} do
    source = eligible(db)
    [carrier_id] = Wakes.materialize_digests(db, source.due_at)
    commit_turn(db, Wakes.get(db, carrier_id))

    assert NoticeBatcher.recover(db, source.due_at + 1) == []
    assert NoticeBatcher.batch(db, batch_id(db, source)).state == "delivered"
    assert count(db, "wakes", "wakeId=?1", [carrier_id]) == 1
    assert count(db, "turns", "wakeId=?1", [carrier_id]) == 1
  end

  test "acceptance 16: a late arrival cannot change a sealed envelope", %{db: db} do
    source = eligible(db, prompt: "sealed")
    [carrier_id] = Wakes.materialize_digests(db, source.due_at)
    before = Wakes.get(db, carrier_id).prompt
    later = eligible(db, prompt: "later")

    assert Wakes.get(db, carrier_id).prompt == before
    assert batch_id(db, later) != batch_id(db, source)

    assert NoticeBatcher.members(db, batch_id(db, later)) |> Enum.map(& &1.source_wake_id) ==
             [later.wake_id]
  end

  test "acceptance 17: cancellation before seal excludes; cancellation after seal preserves",
       %{db: db} do
    early = eligible(db, session: "agent:cancel-before", prompt: "exclude")
    early_batch = batch_id(db, early)

    assert {:ok, :ok} =
             DB.transaction(db, fn txn ->
               NoticeBatcher.enqueue_or_recover_in_txn(txn, {:cancel, early.wake_id, "cancel:1"})
             end)

    assert NoticeBatcher.batch(db, early_batch).state == "canceled"

    assert [%{state: "canceled", cancellation_ref: "cancel:1"}] =
             NoticeBatcher.members(db, early_batch)

    sealed = eligible(db, session: "agent:cancel-after", prompt: "immutable")
    [carrier_id] = Wakes.materialize_digests(db, sealed.due_at)
    envelope = Wakes.get(db, carrier_id).prompt

    assert {:ok, :ok} =
             DB.transaction(db, fn txn ->
               NoticeBatcher.enqueue_or_recover_in_txn(txn, {:cancel, sealed.wake_id, "cancel:2"})
             end)

    assert Wakes.get(db, carrier_id).prompt == envelope
    assert [%{state: "included"}] = NoticeBatcher.members(db, batch_id(db, sealed))
  end

  test "authorized user, session, and process principals can read a complete batch", %{db: db} do
    seed_session(db, "agent:scope-a", "owner-a")

    first =
      manual_member(db, "role:shared:scope-a",
        target_role: "shared",
        session: "agent:scope-a",
        origin: "process:scheduler"
      )

    assert NoticeBatcher.read_batch(db, first.batch_id, {:user, "owner-a"}).member_count == 1

    assert NoticeBatcher.read_batch(db, first.batch_id, {:session, "agent:scope-a"}).member_count ==
             1

    assert NoticeBatcher.read_batch(db, first.batch_id, {:process, "scheduler"}).member_count == 1
  end

  test "acceptance 18: a principal cannot read a batch from another visibility scope", %{db: db} do
    seed_session(db, "agent:scope-a", "owner-a")
    seed_session(db, "agent:scope-b", "owner-b")

    first =
      manual_member(db, "role:shared:scope-a", target_role: "shared", session: "agent:scope-a")

    second =
      manual_member(db, "role:shared:scope-b", target_role: "shared", session: "agent:scope-b")

    assert first.batch_id != second.batch_id
    assert NoticeBatcher.read_batch(db, first.batch_id, {:user, "owner-a"}).member_count == 1
    assert NoticeBatcher.read_batch(db, second.batch_id, {:user, "owner-a"}) == nil
    assert NoticeBatcher.read_batch(db, second.batch_id, {:session, "agent:scope-a"}) == nil
  end

  test "a batch read is denied when any member is outside the principal's visibility", %{db: db} do
    seed_session(db, "agent:scope-a", "owner-a")
    seed_session(db, "agent:scope-b", "owner-b")

    first =
      manual_member(db, "role:shared:scope-a",
        target_role: "shared",
        session: "agent:scope-a",
        origin: "process:scheduler"
      )

    second =
      manual_member(db, "role:shared:scope-a",
        target_role: "shared",
        session: "agent:scope-a",
        origin: "process:scheduler"
      )

    assert first.batch_id == second.batch_id

    {:ok, _} =
      DB.query(db, "UPDATE wakes SET sessionKey=?2, origin='process:other' WHERE wakeId=?1", [
        second.source_wake_id,
        "agent:scope-b"
      ])

    assert NoticeBatcher.read_batch(db, first.batch_id, {:user, "owner-a"}) == nil
    assert NoticeBatcher.read_batch(db, first.batch_id, {:session, "agent:scope-a"}) == nil
    assert NoticeBatcher.read_batch(db, first.batch_id, {:process, "scheduler"}) == nil
  end

  test "a caller cannot forge authorization with the stored visibility scope", %{db: db} do
    seed_session(db, "agent:scope-a", "owner-a")

    first =
      manual_member(db, "role:shared:scope-a", target_role: "shared", session: "agent:scope-a")

    assert NoticeBatcher.read_batch(db, first.batch_id, "role:shared:scope-a") == nil
  end

  test "acceptance 19: an exec-desk role receives the ordinary carrier without desk state",
       %{db: db} do
    seed_session(db, "agent:desk", "owner")
    Roles.create!(db, "exec-desk", "owner", "agent:desk")
    source = eligible(db, target_role: "exec-desk", session: "agent:desk")
    [carrier_id] = Wakes.materialize_digests(db, source.due_at)
    {:ok, _} = DB.query(db, "UPDATE wakes SET dueAt=0 WHERE wakeId=?1", [carrier_id])
    parent = self()

    scheduler =
      start_scheduler(db, fn wake ->
        send(parent, {:desk_inbound, wake.target_role, wake.prompt})
        true
      end)

    assert :ok = Wakes.fire_due(scheduler)
    assert_receive {:desk_inbound, "exec-desk", envelope}
    assert envelope =~ source.wake_id
  end

  test "acceptance 20: recurrence and prod state remain outside batching", %{db: db} do
    {:ok, tables} =
      DB.query(
        db,
        "SELECT name FROM sqlite_schema WHERE type='table' AND (name LIKE 'recurrence_%' OR name LIKE 'production_%' OR name='turns') ORDER BY name"
      )

    before = Map.new(tables, fn [table] -> {table, count(db, table)} end)
    assert NoticeBatcher.recover(db, System.system_time(:millisecond)) == []
    after_counts = Map.new(tables, fn [table] -> {table, count(db, table)} end)

    assert after_counts == before
    assert count(db, "notice_batch_members") == 0
  end

  test "acceptance 21: default-off selection and rollback preserve the ordinary path", %{
    db: db
  } do
    lane = [session: "agent:rollback"]
    unselected = fyi(db, lane)
    assert unselected.delivery_rule == "turn-boundary-digest r1"
    assert NoticeBatcher.source_refs(db, unselected.wake_id) == []

    selected = set_lane_policy(db, lane, true)

    assert selected.enabled
    assert selected.policy_revision == NoticeBatcher.policy_revision()
    assert selected.selected_by == "agent:test-policy"
    assert selected.cause == "acceptance-fixture"
    assert selected.policy_ref =~ "notice-batching-test-policy:"

    assert AdminProjection.version(
             db,
             "notice batching lane policies",
             [selected.recipient_address, selected.visibility_scope]
           ) == 1

    assert {:ok,
            [[1, revision, policy_ref, "agent:test-policy", "acceptance-fixture", selected_at]]} =
             DB.query(
               db,
               """
               SELECT enabled, policyRevision, policyRef, selectedBy, cause, selectedAt
               FROM notice_batching_lane_policies
               WHERE recipientAddress=?1 AND visibilityScope=?2
               """,
               [selected.recipient_address, selected.visibility_scope]
             )

    assert revision == NoticeBatcher.policy_revision()
    assert policy_ref == selected.policy_ref
    assert selected_at == selected.selected_at

    active = fyi(db, lane)
    assert active.delivery_rule == NoticeBatcher.rule()
    assert [%{batch_id: _}] = NoticeBatcher.source_refs(db, active.wake_id)
    _carrier_ids = Wakes.materialize_digests(db, active.due_at)
    carrier_id = NoticeBatcher.batch(db, batch_id(db, active)).delivery_wake_id

    disabled_policy = set_lane_policy(db, lane, false)
    assert disabled_policy.row_version == 2
    disabled = fyi(db, Keyword.put(lane, :prompt, "after rollback"))

    assert disabled.delivery_rule == "turn-boundary-digest r1"
    assert NoticeBatcher.source_refs(db, disabled.wake_id) == []
    NoticeBatcher.delivery_delivered(db, carrier_id)
    assert NoticeBatcher.batch(db, batch_id(db, active)).state == "delivered"
    assert count(db, "notice_batch_members", "sourceWakeId=?1", [unselected.wake_id]) == 0
    assert count(db, "notice_batch_members", "sourceWakeId=?1", [disabled.wake_id]) == 0
  end

  test "default-off digest preserves the legacy rule through suppression and provenance", %{
    db: db
  } do
    source =
      Wakes.schedule(db, %{
        session_key: "agent:legacy-recipient",
        origin: "process:tightbeam",
        creator_session_key: "agent:legacy-recipient",
        prompt: "default-off legacy payload",
        due_at: 0,
        class: "fyi"
      })

    assert source.delivery_rule == "turn-boundary-digest r1"
    assert NoticeBatcher.source_refs(db, source.wake_id) == []
    assert Wakes.self_pending_count(db, source.session_key) == 0

    [carrier_id] = Wakes.materialize_digests(db, source.due_at)
    carrier = Wakes.get(db, carrier_id)

    assert carrier.delivery_rule == "turn-boundary-digest r1"
    assert carrier.prompt =~ "coalesced by turn-boundary-digest r1"
    refute carrier.prompt =~ "coalesced by notice-batching-v1 r1"

    assert Enum.any?(EventLog.lifecycle_events(db), fn event ->
             event.kind == "wake_digest_materialized" and event.subject == carrier_id and
               event.detail =~ "rule=turn-boundary-digest r1"
           end)
  end

  test "acceptance 22: a later earlier deadline atomically shortens the lane", %{db: db} do
    first = manual_member(db, "deadline-scope", due_at: 9_000)
    second = manual_member(db, "deadline-scope", due_at: 4_000)
    batch = NoticeBatcher.batch(db, first.batch_id)

    assert second.batch_id == first.batch_id
    assert batch.due_at == 4_000
    [carrier_id] = NoticeBatcher.recover(db, 4_000)
    assert Wakes.get(db, carrier_id).due_at == 4_000
  end

  test "a selected 65,536-byte source stays durable on the ordinary fallback lane", %{db: db} do
    lane = [session: "agent:payload-floor"]
    set_lane_policy(db, lane, true)

    source =
      fyi(
        db,
        Keyword.merge(lane,
          wake_id: "w_payload_floor",
          prompt: String.duplicate("x", 65_536)
        )
      )

    assert byte_size(source.prompt) == 65_536
    assert source.delivery_rule == "turn-boundary-digest r1"
    assert Wakes.get(db, source.wake_id).state == "pending"
    assert NoticeBatcher.source_refs(db, source.wake_id) == []

    assert {:ok, [[0]]} =
             DB.query(
               db,
               "SELECT enabled FROM notice_delivery_policies WHERE sourceWakeId=?1",
               [source.wake_id]
             )

    assert {:ok, [[1]]} =
             DB.query(
               db,
               "SELECT enabled FROM notice_batching_lane_policies WHERE recipientAddress=?1",
               ["session:agent:payload-floor"]
             )

    later = fyi(db, Keyword.put(lane, :prompt, "fits after fallback"))
    assert later.delivery_rule == NoticeBatcher.rule()
    assert [%{member_state: "active"}] = NoticeBatcher.source_refs(db, later.wake_id)
  end

  test "the rendered V1 member boundary admits 65,536 bytes and bypasses the next byte", %{
    db: db
  } do
    fitting_id = "w_rendered_boundary_fit"
    overflow_id = "w_rendered_boundary_over"
    fitting_header = rendered_member_header(fitting_id)
    overflow_header = rendered_member_header(overflow_id)

    fitting =
      eligible(db,
        session: "agent:rendered-fit",
        wake_id: fitting_id,
        prompt: String.duplicate("a", 65_536 - byte_size(fitting_header))
      )

    assert [%{member_state: "active", batch_id: fitting_batch_id}] =
             NoticeBatcher.source_refs(db, fitting.wake_id)

    assert [%{rendered_bytes: 65_536}] = NoticeBatcher.members(db, fitting_batch_id)

    overflow =
      eligible(db,
        session: "agent:rendered-over",
        wake_id: overflow_id,
        prompt: String.duplicate("b", 65_537 - byte_size(overflow_header))
      )

    assert overflow.delivery_rule == "turn-boundary-digest r1"
    assert Wakes.get(db, overflow.wake_id).state == "pending"
    assert NoticeBatcher.source_refs(db, overflow.wake_id) == []
  end

  test "the delivery envelope preserves trailing source payload bytes", %{db: db} do
    payload = "line one\nline two\n \t"
    source = eligible(db, wake_id: "w_trailing_payload", prompt: payload)
    [carrier_id] = Wakes.materialize_digests(db, source.due_at)
    envelope = Wakes.get(db, carrier_id).prompt

    assert envelope =~ rendered_member_header(source.wake_id) <> payload <> "\n\n"
  end

  defp eligible(db, opts \\ []) do
    set_lane_policy(db, opts, true)
    fyi(db, opts)
  end

  defp fyi(db, opts) do
    input = %{
      session_key: Keyword.get(opts, :session, "agent:recipient"),
      target_role: Keyword.get(opts, :target_role),
      origin: Keyword.get(opts, :origin, "process:tightbeam"),
      creator_session_key: "agent:sender",
      prompt: Keyword.get(opts, :prompt, "routine"),
      due_at: Keyword.get(opts, :due_at, 0),
      class: "fyi"
    }

    input =
      case Keyword.fetch(opts, :wake_id) do
        {:ok, wake_id} -> Map.put(input, :wake_id, wake_id)
        :error -> input
      end

    Wakes.schedule(db, input)
  end

  defp rendered_member_header(wake_id) do
    "[1] source=#{wake_id} sender=process:tightbeam cause=wake class=fyi\n"
  end

  defp set_lane_policy(db, opts, enabled) do
    lane = %{
      session_key: Keyword.get(opts, :session, "agent:recipient"),
      target_role: Keyword.get(opts, :target_role)
    }

    seq = System.unique_integer([:positive, :monotonic])

    {:ok, policy} =
      DB.transaction(db, fn txn ->
        Org.apply_notice_batching_lane_policy_in_txn(
          txn,
          lane,
          enabled,
          "notice-batching-test-policy:#{seq}",
          "agent:test-policy",
          "acceptance-fixture",
          seq
        )
      end)

    policy
  end

  defp ordinary(db, class, prompt) do
    Wakes.schedule(db, %{
      session_key: "agent:recipient",
      origin: "agent:sender",
      creator_session_key: "agent:sender",
      prompt: prompt,
      due_at: 0,
      class: class
    })
  end

  defp manual_member(db, scope, opts) do
    wake =
      Wakes.schedule(db, %{
        session_key: Keyword.get(opts, :session, "agent:recipient"),
        target_role: Keyword.get(opts, :target_role),
        origin: Keyword.get(opts, :origin, "process:tightbeam"),
        creator_session_key: "agent:sender",
        prompt: Keyword.get(opts, :prompt, "manual"),
        due_at: Keyword.get(opts, :due_at, 10_000),
        sender_scheduled: true,
        class: "fyi"
      })

    enabled = Keyword.get(opts, :enabled, true)

    {:ok, result} =
      DB.transaction(db, fn txn ->
        ref =
          NoticeBatcher.record_policy_in_txn(txn, wake,
            visibility_scope: scope,
            enabled: enabled
          )

        NoticeBatcher.enqueue_or_recover_in_txn(txn, wake.wake_id, ref)
      end)

    if Keyword.get(opts, :expect_error, false),
      do: elem(result, 1),
      else: Map.put(result, :source_wake_id, wake.wake_id)
  end

  defp batch_id(db, source) do
    [%{batch_id: batch_id}] = NoticeBatcher.source_refs(db, source.wake_id)
    batch_id
  end

  defp source_ids(db, carrier_id),
    do: Enum.map(Wakes.digest_members(db, carrier_id), & &1.wake_id)

  defp terminal_turn(db, session_key, ended_at) do
    seq = System.unique_integer([:positive, :monotonic])

    {:ok, _} =
      DB.query(
        db,
        "INSERT INTO turns (seq, sessionKey, messageId, origin, prompt, status, createdAt, endedAt) VALUES (?1, ?2, ?3, 'agent:sender', 'done', 'delivered', ?4, ?5)",
        [seq, session_key, "m_#{seq}", ended_at - 1, ended_at]
      )

    seq
  end

  defp commit_turn(db, wake) do
    seq = System.unique_integer([:positive, :monotonic])

    {:ok, _} =
      DB.query(
        db,
        "INSERT INTO turns (seq, sessionKey, messageId, wakeId, origin, prompt, status, createdAt, endedAt) VALUES (?1, ?2, ?3, ?4, 'process:tightbeam', ?5, 'delivered', ?6, ?6)",
        [
          seq,
          wake.session_key,
          "m_#{seq}",
          wake.wake_id,
          wake.prompt,
          System.system_time(:millisecond)
        ]
      )

    true
  end

  defp start_scheduler(db, deliver) do
    name = :"notice_scheduler_#{System.unique_integer([:positive])}"
    {:ok, pid} = Wakes.start_link(db: db, name: name, tick_ms: 60_000, deliver: deliver)
    pid
  end

  defp count(db, table, where \\ nil, params \\ []) do
    clause = if where, do: " WHERE " <> where, else: ""
    {:ok, [[value]]} = DB.query(db, "SELECT COUNT(*) FROM #{table}#{clause}", params)
    value
  end

  defp seed_session(db, session_key, owner) do
    {:ok, _} =
      DB.query(
        db,
        "INSERT OR IGNORE INTO users (userId, isAdmin, creationKind, createdAt) VALUES (?1, 0, 'admin_add', 1)",
        [owner]
      )

    ensure_main_session(db, owner)

    Tightbeam.Org.create(db, %{
      session_key: session_key,
      display_name: session_key,
      owner_user_id: owner,
      origin: "user:#{owner}",
      archetype: "coder",
      harness: "claude",
      provider: "anthropic",
      model: Tightbeam.Model.new("fable"),
      host: Tightbeam.Placement.local_host_name()
    })

    :ok
  end
end
