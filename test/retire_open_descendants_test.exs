defmodule Tightbeam.RetireOpenDescendantsTest do
  use Tightbeam.TestCase, async: false

  alias Tightbeam.{DB, Gateway, Ledger, Model, Org, Projection, Roles, Wakes}

  @owner "retire-owner"
  @main Org.personal_session_key(@owner)

  setup do
    name = String.to_atom("retire_descendants_#{System.unique_integer([:positive])}")
    start_supervised!({DB, path: ":memory:", name: name})
    :ok = ensure_all_schemas(name)

    assert {:ok, []} =
             DB.query(name, "INSERT INTO users(userId,isAdmin,createdAt) VALUES(?1,0,?2)", [
               @owner,
               System.system_time(:millisecond)
             ])

    ensure_main_session(name, @owner)
    %{db: name}
  end

  test "refuses before effects and lists protected work, the retired set, and its accountable parent",
       %{db: db} do
    tree = protected_tree(db)
    {wake, turn_seq} = add_pending_work(db, tree.assignment_holder)
    before = retirement_snapshot(db, tree)

    refusal = retire(db, tree.target, %{idempotency_key: "retry-after-refusal"})

    assert refusal.code == "open_descendants"
    assert refusal.message =~ "no sessions or descendant work were changed"

    assert Enum.sort(Enum.map(refusal.retired_sessions, & &1.session_key)) ==
             Enum.sort([tree.target, tree.intermediary])

    assert refusal.accountable_parent == %{
             session_key: tree.accountable_parent,
             display_name: "Coordinator"
           }

    protected = Map.new(refusal.protected_descendants, &{&1.session_key, &1})
    assert protected[tree.role_holder].roles == ["conversation-owner"]
    assert protected[tree.role_holder].assignments == []
    assert protected[tree.assignment_holder].roles == []

    assert protected[tree.assignment_holder].assignments == [
             %{assignment_id: "assignment-open-descendant", subject: "Ship sync"}
           ]

    diagnostic = Tightbeam.ErrorDiagnostic.for_error(refusal)
    assert diagnostic["details"]["protected_descendants"]
    assert diagnostic["details"]["retired_sessions"]
    assert diagnostic["details"]["accountable_parent"]
    after_refusal = retirement_snapshot(db, tree)
    assert Map.drop(after_refusal, [:wakes]) == Map.drop(before, [:wakes])
    assert after_refusal.wakes -- before.wakes == [
      [record(db, refusal.unfinished_retirement.id).wake, tree.coordinator, "pending",
       Wakes.get(db, record(db, refusal.unfinished_retirement.id).wake).prompt]
    ]
    assert before.wakes -- after_refusal.wakes == []

    assert Enum.any?(
             Wakes.list_for_session(db, tree.assignment_holder),
             &(&1.wake_id == wake.wake_id)
           )

    assert {:ok, [["queued"]]} =
             DB.query(db, "SELECT status FROM turns WHERE seq=?1", [turn_seq])

    assert {:ok, [[0]]} =
             DB.query(
               db,
               "SELECT COUNT(*) FROM wire_idempotency WHERE operation='retire' AND idempotencyKey=?1",
               ["retry-after-refusal"]
             )

    assert {:ok, [[0]]} =
             DB.query(
               db,
               "SELECT COUNT(*) FROM assignment_interruptions WHERE assignmentId='assignment-open-descendant'"
             )

    assert {:ok, [[0]]} =
             DB.query(
               db,
               "SELECT COUNT(*) FROM assignment_revocations WHERE assignmentId='assignment-open-descendant'"
             )
  end

  test "the keep disposition atomically retires around protected work and replays its frontier",
       %{db: db} do
    tree = protected_tree(db)
    {wake, turn_seq} = add_pending_work(db, tree.assignment_holder)

    refusal = retire(db, tree.target, %{idempotency_key: "same-retire-key"})
    assert refusal.code == "open_descendants"

    result =
      retire(db, tree.target, %{
        idempotency_key: "same-retire-key",
        keep_open_descendants: true
      })

    assert result.retired_session_keys == [tree.intermediary, tree.target]
    assert result.deferred == []

    assert result.kept_descendants == [
             %{
               session_key: tree.role_holder,
               display_name: "Role holder",
               parent_session_key: tree.accountable_parent,
               parent_display_name: "Coordinator"
             }
           ]

    assert Org.get(db, tree.target).state == "retired"
    assert Org.get(db, tree.intermediary).state == "retired"
    assert Org.get(db, tree.role_holder).state == "active"
    assert Org.get(db, tree.assignment_holder).state == "active"
    assert Org.current_parent(db, tree.role_holder) == tree.accountable_parent
    assert Org.current_parent(db, tree.assignment_holder) == tree.role_holder
    assert {:ok, tree.role_holder, false} == Roles.resolve(db, "conversation-owner")

    role_holder = tree.role_holder
    assignment_holder = tree.assignment_holder
    accountable_parent = tree.accountable_parent
    target = tree.target
    intermediary = tree.intermediary

    assert {:ok, [["open", ^assignment_holder, ^accountable_parent]]} =
             DB.query(
               db,
               "SELECT state,holderKey,openedBySession FROM assignments WHERE id='assignment-open-descendant'"
             )

    wake_id = wake.wake_id

    assert {:ok, [["pending", ^wake_id]]} =
             DB.query(
               db,
               "SELECT state,wakeId FROM wakes WHERE wakeId=?1",
               [wake_id]
             )

    assert {:ok, [[^assignment_holder, "queued"]]} =
             DB.query(db, "SELECT sessionKey,status FROM turns WHERE seq=?1", [turn_seq])

    assert {:ok,
            [
              [
                ^role_holder,
                ^target,
                ^intermediary,
                ^accountable_parent,
                principal_ref,
                "same-retire-key",
                request_id
              ]
            ]} =
             DB.query(
               db,
               """
               SELECT childSessionKey,retiredTargetSessionKey,previousCurrentParentSessionKey,
                      newCurrentParentSessionKey,principalRef,idempotencyKey,retirementRequestId
               FROM session_retirement_parent_moves
               WHERE childSessionKey=?1
               """,
               [tree.role_holder]
             )

    assert principal_ref == "user:" <> @owner
    assert is_binary(request_id) and byte_size(request_id) > 4

    replay = retire(db, tree.target, %{idempotency_key: "same-retire-key"})
    assert replay.retired_session_keys == result.retired_session_keys
    assert replay.kept_descendants == result.kept_descendants

    # The new parent relation is used by later subtree retirement and notices.
    later_refusal = retire(db, tree.accountable_parent, %{})
    assert later_refusal.code == "open_descendants"

    assert Enum.sort(Enum.map(later_refusal.protected_descendants, & &1.session_key)) ==
             Enum.sort([tree.role_holder, tree.assignment_holder])

    notify_parent_of_interruption(db, tree.role_holder)

    assert {:ok, [[parent, prompt]]} =
             DB.query(
               db,
               "SELECT sessionKey,prompt FROM wakes WHERE origin='health-redelivery-parent'"
             )

    assert parent == tree.accountable_parent
    assert prompt =~ "interrupted-outcome-unknown"
  end

  test "a named descendant may be retired and an empty remainder still cascades easily", %{db: db} do
    tree = protected_tree(db)

    assert %{retired_session_keys: [key]} = retire(db, tree.assignment_holder, %{})
    assert key == tree.assignment_holder

    assert {:ok, [["closed", "revoked", closed_by_user]]} =
             DB.query(
               db,
               "SELECT state,outcome,closedByUser FROM assignments WHERE id='assignment-open-descendant'"
             )

    assert closed_by_user == @owner

    assert retire(db, tree.target, %{}).code == "open_descendants"

    role_holder = tree.role_holder
    intermediary = tree.intermediary
    target = tree.target
    assert %{retired_session_keys: [^role_holder]} = retire(db, role_holder, %{})
    assert %{retired_session_keys: [^intermediary, ^target]} = retire(db, target, %{})
  end

  test "critical leases defer only a member of the retired set", %{db: db} do
    kept_tree = protected_tree(db, "kept")
    lease(db, kept_tree.assignment_holder)

    kept = retire(db, kept_tree.target, %{keep_open_descendants: true})
    assert kept.retired_session_keys == [kept_tree.intermediary, kept_tree.target]
    assert kept.deferred == []

    leased_tree = protected_tree(db, "leased")
    lease(db, leased_tree.intermediary)
    before_parents = current_parents(db, leased_tree)

    deferred = retire(db, leased_tree.target, %{keep_open_descendants: true})
    assert deferred.retired_session_keys == []

    assert Enum.map(deferred.deferred, & &1.session_key) ==
             [leased_tree.intermediary, leased_tree.target]

    refute Map.has_key?(deferred, :kept_descendants)
    assert current_parents(db, leased_tree) == before_parents
    assert Org.get(db, leased_tree.target).state == "active"
    assert Org.get(db, leased_tree.intermediary).state == "active"

    assert {:ok, [[0]]} =
             DB.query(
               db,
               "SELECT COUNT(*) FROM session_retirement_parent_moves WHERE retiredTargetSessionKey=?1",
               [leased_tree.target]
             )
  end

  test "stopped requests supersede only the same target and owner and withdraw with a reason", %{db: db} do
    tree = protected_tree(db)
    create_session(db, "requester", @main, "Requester")
    first = retire(db, tree.target, %{}).unfinished_retirement
    assert first.owner.session_key == tree.coordinator
    other = retire_as(db, tree.target, "requester").unfinished_retirement
    second = retire(db, tree.target, %{}).unfinished_retirement
    assert first.id != second.id
    assert record(db, first.id).state == "superseded"
    assert Wakes.get(db, record(db, first.id).wake).state == "canceled"
    assert record(db, other.id).state == "open"
    assert record(db, second.id).state == "open"
    for reason <- [nil, "", "  "] do
      assert withdraw(db, tree.target, tree.coordinator, reason).code == "invalid"
      assert record(db, second.id).state == "open"
    end
    assert withdraw(db, tree.target, @main, "not mine").code == "not_found"
    assert withdraw(db, tree.target, tree.coordinator, "still needed").state == "withdrawn"
    assert record(db, second.id).reason == "still needed"
    assert record(db, second.id).withdrawer == "session:" <> tree.coordinator
    close_work(db, tree)
    assert :ok = Roles.rm(db, "conversation-owner")
    assert Wakes.get(db, record(db, second.id).wake).state == "canceled"
    assert Wakes.get(db, record(db, other.id).wake).due_at <= System.system_time(:millisecond)
  end

  test "recorded work and role must both clear before one real retry wake; a retry evaluates new work", %{db: db} do
    tree = protected_tree(db)
    scheduler = scheduler(db)
    first = retire(db, tree.target, %{}).unfinished_retirement
    wake = record(db, first.id).wake
    assert :ok = Wakes.fire_due(scheduler)
    assert Wakes.get(db, wake).state == "pending"
    close_work(db, tree)
    assert :ok = Wakes.fire_due(scheduler)
    assert Wakes.get(db, wake).state == "pending"
    assert :ok = Roles.bind(db, "conversation-owner", @main)
    assert :ok = Wakes.fire_due(scheduler)
    assert Wakes.get(db, wake).state == "fired"
    assert Wakes.get(db, wake).prompt =~ tree.target
    assert Wakes.get(db, wake).prompt =~ "no keep disposition"
    assert Org.get(db, tree.target).state == "active"
    assert Org.get(db, tree.assignment_holder).state == "active"
    before = DB.query(db, "SELECT * FROM turns ORDER BY seq")
    assert :ok = Wakes.fire_due(scheduler)
    assert DB.query(db, "SELECT * FROM turns ORDER BY seq") == before

    insert_assignment(db, "new-work", tree.assignment_holder, tree.coordinator)
    second = retire_as(db, tree.target, tree.coordinator).unfinished_retirement
    assert record(db, first.id).state == "superseded"
    assert {:ok, [["assignment", "new-work"]]} = DB.query(db,
      "SELECT kind,reference FROM retirement_blockers WHERE retirementId=?1", [second.id])
    close_assignment(db, "new-work")
    finish_turns(db, tree.coordinator)
    assert :ok = Wakes.fire_due(scheduler)
    assert Wakes.get(db, record(db, second.id).wake).state == "fired"
    result = retire_as(db, tree.target, tree.coordinator)
    assert Enum.sort(result.retired_session_keys) == Enum.sort([
      tree.target, tree.intermediary, tree.role_holder, tree.assignment_holder])
    assert record(db, second.id).state == "retired"
  end

  test "actual retirement cancels every owner's continuation including a keep retry", %{db: db} do
    tree = protected_tree(db)
    create_session(db, "requester", @main, "Requester")
    one = retire(db, tree.target, %{}).unfinished_retirement
    two = retire_as(db, tree.target, "requester").unfinished_retirement
    result = retire(db, tree.target, %{keep_open_descendants: true})
    assert result.retired_session_keys == [tree.intermediary, tree.target]
    for id <- [one.id, two.id] do
      assert record(db, id).state == "retired"
      assert Wakes.get(db, record(db, id).wake).state == "canceled"
    end
    assert Org.get(db, tree.assignment_holder).state == "active"
  end

  test "pending ownership passes beyond the entire retiring set and merges with the receiving record", %{db: db} do
    tree = protected_tree(db)
    create_session(db, "outer-owner", @main, "Outer owner")
    create_session(db, "requester", "outer-owner", "Requester")
    intent = retire_as(db, tree.target, "requester").unfinished_retirement
    wake = record(db, intent.id).wake
    assert retire(db, "outer-owner", %{}).retired_session_keys == ["requester", "outer-owner"]
    assert record(db, intent.id).owner == @main
    assert Wakes.get(db, wake).session_key == @main
    assert Wakes.get(db, wake).state == "pending"
    assert withdraw(db, tree.target, @main, "keeping target").state == "withdrawn"

    create_session(db, "second-requester", tree.coordinator, "Second requester")
    existing = retire_as(db, tree.target, tree.coordinator).unfinished_retirement
    merging = retire_as(db, tree.target, "second-requester").unfinished_retirement
    assert retire(db, "second-requester", %{}).retired_session_keys == ["second-requester"]
    assert record(db, merging.id).state == "superseded"
    assert record(db, existing.id).state == "open"
    assert Wakes.get(db, record(db, merging.id).wake).state == "canceled"
    assert {:ok, [[0]]} = DB.query(db, "SELECT COUNT(*) FROM retirement_owner_transfers WHERE handoffWakeId IS NOT NULL")
  end

  test "a delivered continuation hands off once and a new refusal replaces the transferred duty", %{db: db} do
    tree = protected_tree(db)
    create_session(db, "requester", tree.coordinator, "Requester")
    intent = retire_as(db, tree.target, "requester").unfinished_retirement
    close_work(db, tree)
    Roles.rm(db, "conversation-owner")
    scheduler = scheduler(db)
    Wakes.fire_due(scheduler)
    assert Wakes.get(db, record(db, intent.id).wake).state == "fired"
    retire(db, "requester", %{})
    transferred = record(db, intent.id)
    assert transferred.owner == tree.coordinator
    handoff = Wakes.get(db, transferred.wake)
    assert handoff.session_key == tree.coordinator
    assert handoff.prompt =~ "Former owner: Requester (requester)"
    assert {:ok, [["requester", owner, handoff_id]]} = DB.query(db,
      "SELECT formerOwnerSessionKey,newOwnerSessionKey,handoffWakeId FROM retirement_owner_transfers WHERE retirementId=?1", [intent.id])
    assert owner == tree.coordinator
    assert handoff_id == handoff.wake_id
    insert_assignment(db, "new-work", tree.assignment_holder, tree.coordinator)
    fresh = retire_as(db, tree.target, tree.coordinator).unfinished_retirement
    assert record(db, intent.id).state == "superseded"
    assert record(db, fresh.id).owner == tree.coordinator
    assert Wakes.get(db, handoff.wake_id).state == "canceled"
    assert withdraw(db, tree.target, tree.coordinator, "keeping target").state == "withdrawn"
  end

  test "a delivered incoming record hands off even when merged into a still-blocked owner record", %{db: db} do
    tree = protected_tree(db)
    create_session(db, "requester", tree.coordinator, "Requester")
    incoming = retire_as(db, tree.target, "requester").unfinished_retirement
    close_work(db, tree)
    Roles.rm(db, "conversation-owner")
    scheduler = scheduler(db)
    Wakes.fire_due(scheduler)
    assert Wakes.get(db, record(db, incoming.id).wake).state == "fired"
    insert_assignment(db, "new-work", tree.assignment_holder, tree.coordinator)
    existing = retire_as(db, tree.target, tree.coordinator).unfinished_retirement
    original_wake = record(db, existing.id).wake
    retire(db, "requester", %{})
    assert record(db, incoming.id).state == "superseded"
    assert record(db, existing.id).wake == original_wake
    assert Wakes.get(db, original_wake).due_at == 253_402_300_799_000
    assert {:ok, [[handoff_id]]} = DB.query(db,
      "SELECT handoffWakeId FROM retirement_owner_transfers WHERE retirementId=?1", [incoming.id])
    handoff = Wakes.get(db, handoff_id)
    assert handoff.session_key == tree.coordinator
    assert handoff.prompt =~ "Former owner: Requester"
    assert handoff.due_at <= System.system_time(:millisecond)
    fresh = retire_as(db, tree.target, tree.coordinator).unfinished_retirement
    assert fresh.id != existing.id
    assert Wakes.get(db, original_wake).state == "canceled"
    assert Wakes.get(db, handoff_id).state == "canceled"
  end

  test "lease deadline wakes the owner once for a fresh keep retry and uses truthful wording", %{db: db} do
    tree = protected_tree(db)
    scheduler = scheduler(db)
    lease = Tightbeam.CriticalLeases.declare(db, tree.intermediary, 1_000, "finish write", 1_000)
    deferred = retire(db, tree.target, %{keep_open_descendants: true})
    intent = deferred.unfinished_retirement
    wake = Wakes.get(db, record(db, intent.id).wake)
    assert wake.due_at == lease.hard_deadline
    assert wake.prompt =~ "--keep-open-descendants"
    assert Wakes.fire_due(scheduler) == :ok
    assert Wakes.get(db, wake.wake_id).state == "pending"
    assert Org.get(db, tree.target).state == "active"
    leased_wake = Enum.find(Wakes.list_pending(db), &(&1.session_key == tree.intermediary))
    assert leased_wake.prompt =~ "finish write"
    assert leased_wake.prompt =~ to_string(lease.hard_deadline)
    assert leased_wake.prompt =~ tree.coordinator
    refute leased_wake.prompt =~ "retirement is deferred only until"
    # Wait for the declared deadline itself, then observe the scheduler barrier.
    Process.send_after(self(), :hard_deadline, max(0, lease.hard_deadline - System.system_time(:millisecond)))
    assert_receive :hard_deadline, 2_000
    assert Wakes.fire_due(scheduler) == :ok
    assert Wakes.get(db, wake.wake_id).state == "fired"
    assert Org.get(db, tree.target).state == "active"
    result = retire_as(db, tree.target, tree.coordinator, %{keep_open_descendants: true})
    assert result.retired_session_keys == [tree.intermediary, tree.target]
    assert Org.get(db, tree.role_holder).state == "active"
    assert Org.current_parent(db, tree.role_holder) == tree.coordinator
    assert record(db, intent.id).state == "retired"
    assert {:ok, [[1]]} = DB.query(db, "SELECT COUNT(*) FROM unfinished_retirements")
  end

  test "reopening the schema preserves a stopped retirement and its pending continuation", %{db: db} do
    tree = protected_tree(db)
    intent = retire(db, tree.target, %{}).unfinished_retirement
    before = record(db, intent.id)
    wake = Wakes.get(db, before.wake)
    assert :ok = Tightbeam.Schema.ensure_all(db)
    assert record(db, intent.id) == before
    assert Wakes.get(db, before.wake) == wake
    close_work(db, tree)
    Roles.rm(db, "conversation-owner")
    assert Wakes.get(db, before.wake).due_at <= System.system_time(:millisecond)
  end

  defp retire_as(db, target, caller, params \\ %{}) do
    Gateway.handlers(%{db: db})["retire"].(%{
      origin: "session:" <> caller, principal: {:session, caller}, session_key: target, params: params})
  end

  defp withdraw(db, target, caller, reason) do
    Gateway.handlers(%{db: db})["retire-withdraw"].(%{
      origin: "session:" <> caller, principal: {:session, caller}, session_key: target, params: %{reason: reason}})
  end

  defp record(db, id) do
    {:ok, [[state, owner, wake, reason, withdrawer]]} = DB.query(db,
      "SELECT state,ownerSessionKey,wakeId,withdrawalReason,withdrawnBy FROM unfinished_retirements WHERE id=?1", [id])
    %{state: state, owner: owner, wake: wake, reason: reason, withdrawer: withdrawer}
  end

  defp close_work(db, tree), do: close_assignment(db, tree.assignment_id)
  defp close_assignment(db, id) do
    result = Gateway.handlers(%{db: db})["revoke-assignment"].(%{
      verb: "revoke-assignment", origin: "user:" <> @owner, principal: {:user, @owner},
      session_key: nil, params: %{assignment_id: id, reason: "work no longer needed"}})
    assert result.outcome == "revoked"
  end

  defp insert_assignment(db, id, holder, opener) do
    assert {:ok, []} = DB.query(db,
      "INSERT INTO assignments(id,subject,holderKey,openedBySession,openedAt) VALUES(?1,'New work',?2,?3,1)", [id, holder, opener])
  end

  defp finish_turns(db, owner) do
    assert {:ok, []} = DB.query(db,
      "UPDATE turns SET status='delivered',endedAt=?2 WHERE sessionKey=?1 AND status='queued'", [owner, System.system_time(:millisecond)])
  end

  defp scheduler(db) do
    suffix = System.unique_integer([:positive])
    registry = String.to_atom("retirement_registry_#{suffix}")
    lane = String.to_atom("retirement_lane_#{suffix}")
    name = String.to_atom("retirement_scheduler_#{suffix}")
    start_supervised!({Tightbeam.ConnRegistry, name: registry})
    start_supervised!({Tightbeam.NoticeBatcherFixture.LaneStub, lane})
    start_supervised!({Wakes, db: db, name: name, tick_ms: 60_000,
      delivery_opts: [conn_registry: registry, lane_manager: lane], deliver: fn _ -> :ok end})
    name
  end

  defp protected_tree(db, prefix \\ "") do
    key = fn name -> if prefix == "", do: name, else: prefix <> "-" <> name end
    main = Org.get(db, @main)
    assert main.state == "active"
    coordinator = key.("session:coordinator")
    target = key.("session:target")
    intermediary = key.("session:intermediary")
    role_holder = key.("session:role-holder")
    assignment_holder = key.("session:assignment-holder")

    create_session(db, coordinator, @main, "Coordinator")
    create_session(db, target, coordinator, "Retiring session")
    create_session(db, intermediary, target, "Unprotected intermediary")
    create_session(db, role_holder, intermediary, "Role holder")
    create_session(db, assignment_holder, role_holder, "Assignment holder")

    role_name = if prefix == "", do: "conversation-owner", else: "conversation-owner-#{prefix}"
    Roles.create!(db, role_name, @owner, nil)
    :ok = Roles.bind(db, role_name, role_holder)

    assignment_id =
      if prefix == "",
        do: "assignment-open-descendant",
        else: "assignment-open-descendant-#{prefix}"

    {:ok, []} =
      DB.query(
        db,
        """
        INSERT INTO assignments(id,subject,holderKey,openedBySession,openedAt)
        VALUES (?1,'Ship sync',?2,?3,1)
        """,
        [assignment_id, assignment_holder, coordinator]
      )

    %{
      coordinator: coordinator,
      accountable_parent: coordinator,
      target: target,
      intermediary: intermediary,
      role_holder: role_holder,
      assignment_holder: assignment_holder,
      assignment_id: assignment_id
    }
  end

  defp create_session(db, session_key, parent_key, display_name) do
    Org.create(db, %{
      session_key: session_key,
      display_name: display_name,
      kind: "custom",
      owner_user_id: @owner,
      origin: "user:#{@owner}",
      spawned_by: parent_key,
      archetype: "default",
      host: "testhost",
      harness: "claude",
      provider: "anthropic",
      model: Model.new("fable")
    })
  end

  defp add_pending_work(db, session_key) do
    wake =
      Wakes.schedule(db, %{
        session_key: session_key,
        target_role: nil,
        origin: "user:#{@owner}",
        prompt: "Pending follow-up",
        due_at: System.system_time(:millisecond) + 60_000
      })

    {:appended, message} =
      Projection.append(db, %{
        session_key: session_key,
        role: "user",
        content: "Queued follow-up",
        sender: "user:#{@owner}"
      })

    {:ok, turn_seq} =
      Ledger.enqueue(db, %{
        session_key: session_key,
        message_id: message.id,
        origin: "user:#{@owner}",
        prompt: message.content
      })

    {wake, turn_seq}
  end

  defp notify_parent_of_interruption(db, session_key) do
    {:appended, message} =
      Projection.append(db, %{
        session_key: session_key,
        role: "user",
        content: "Interrupted work",
        sender: "user:#{@owner}"
      })

    {:ok, turn_seq} =
      Ledger.enqueue(db, %{
        session_key: session_key,
        message_id: message.id,
        origin: "user:#{@owner}",
        prompt: message.content
      })

    {:ok, []} =
      DB.query(
        db,
        "UPDATE turns SET status='failed_unknown',error='interrupted: outcome unknown',endedAt=?2 WHERE seq=?1",
        [turn_seq, System.system_time(:millisecond)]
      )

    {:ok, :ok} =
      DB.transaction(db, fn txn ->
        Wakes.record_health_redelivery_source_in_txn(
          txn,
          turn_seq,
          "interrupted-outcome-unknown"
        )
      end)
  end

  defp retirement_snapshot(db, tree) do
    keys = [
      @main,
      tree.coordinator,
      tree.target,
      tree.intermediary,
      tree.role_holder,
      tree.assignment_holder
    ]

    sessions = Enum.map(keys, &{&1, Org.get(db, &1).state, Org.current_parent(db, &1)})

    {:ok, assignments} =
      DB.query(
        db,
        "SELECT id,holderKey,openedByUser,openedBySession,state,outcome FROM assignments ORDER BY id"
      )

    {:ok, roles} = DB.query(db, "SELECT name,boundSessionKey FROM roles ORDER BY name")

    {:ok, wakes} =
      DB.query(db, "SELECT wakeId,sessionKey,state,prompt FROM wakes ORDER BY wakeId")

    {:ok, turns} = DB.query(db, "SELECT seq,sessionKey,status,messageId FROM turns ORDER BY seq")

    %{sessions: sessions, assignments: assignments, roles: roles, wakes: wakes, turns: turns}
  end

  defp current_parents(db, tree) do
    [
      @main,
      tree.coordinator,
      tree.target,
      tree.intermediary,
      tree.role_holder,
      tree.assignment_holder
    ]
    |> Enum.map(&{&1, Org.get(db, &1).state, Org.current_parent(db, &1)})
  end

  defp lease(db, session_key) do
    Gateway.handlers(%{db: db})["critical"].(%{
      principal: {:session, session_key},
      params: %{for_ms: 30_000, reason: "finish current work"}
    })
  end

  defp retire(db, session_key, params) do
    Gateway.handlers(%{db: db})["retire"].(%{
      origin: "user:#{@owner}",
      principal: {:user, @owner},
      session_key: session_key,
      params: params
    })
  end
end
