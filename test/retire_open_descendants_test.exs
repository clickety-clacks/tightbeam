defmodule Tightbeam.RetireOpenDescendantsTest do
  use Tightbeam.TestCase, async: false

  alias Tightbeam.{DB, Gateway, Ledger, Model, Org, Projection, Roles, Rules, Wakes}

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
    assert retirement_snapshot(db, tree) == before

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

  test "the kept-session parent follows the declared order", %{db: db} do
    rules_base =
      Path.join(System.tmp_dir!(), "retirement-order-#{System.unique_integer([:positive])}")

    rules_dir = Path.join(rules_base, "identity/rules")
    File.mkdir_p!(rules_dir)
    on_exit(fn -> File.rm_rf!(rules_base) end)

    seed = File.read!(Path.expand("../priv/seed/rules/substrate.toml", __DIR__))

    seed =
      String.replace(
        seed,
        "kept_parent_order = [\"active_ancestor\", \"owner_personal_session\"]",
        "kept_parent_order = [\"owner_personal_session\", \"active_ancestor\"]"
      )

    File.write!(Path.join(rules_dir, "substrate.toml"), seed)
    Rules.load!(rules_base, Map.keys(Gateway.handlers(%{db: db})))

    tree = protected_tree(db)
    result = retire(db, tree.target, %{keep_open_descendants: true})

    assert [%{parent_session_key: @main}] = result.kept_descendants
  end

  test "a kept-parent order without the owner personal session is unavailable", %{db: db} do
    rules_base =
      Path.join(
        System.tmp_dir!(),
        "retirement-invalid-parent-order-#{System.unique_integer([:positive])}"
      )

    rules_dir = Path.join(rules_base, "identity/rules")
    File.mkdir_p!(rules_dir)
    on_exit(fn -> File.rm_rf!(rules_base) end)

    seed = File.read!(Path.expand("../priv/seed/rules/substrate.toml", __DIR__))

    seed =
      String.replace(
        seed,
        "kept_parent_order = [\"active_ancestor\", \"owner_personal_session\"]",
        "kept_parent_order = [\"active_ancestor\"]"
      )

    File.write!(Path.join(rules_dir, "substrate.toml"), seed)
    Rules.load!(rules_base, Map.keys(Gateway.handlers(%{db: db})))

    tree = protected_tree(db)

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        result = retire(db, tree.target, %{keep_open_descendants: true})

        assert Enum.sort(result.retired_session_keys) ==
                 Enum.sort([
                   tree.target,
                   tree.intermediary,
                   tree.role_holder,
                   tree.assignment_holder
                 ])

        refute Map.has_key?(result, :kept_descendants)
      end)

    assert log =~ "session-retirement is invalid"
  end

  test "without the settings family, protected descendants do not block retirement", %{db: db} do
    rules_base =
      Path.join(System.tmp_dir!(), "retirement-no-policy-#{System.unique_integer([:positive])}")

    File.mkdir_p!(Path.join(rules_base, "identity/rules"))
    on_exit(fn -> File.rm_rf!(rules_base) end)
    Rules.load!(rules_base, Map.keys(Gateway.handlers(%{db: db})))

    tree = protected_tree(db)
    result = retire(db, tree.target, %{})

    assert Enum.sort(result.retired_session_keys) ==
             Enum.sort([
               tree.target,
               tree.intermediary,
               tree.role_holder,
               tree.assignment_holder
             ])
  end

  test "a valid non-refusing policy cascades protected descendants without a keep flag", %{
    db: db
  } do
    rules_base =
      Path.join(System.tmp_dir!(), "retirement-no-refusal-#{System.unique_integer([:positive])}")

    rules_dir = Path.join(rules_base, "identity/rules")
    File.mkdir_p!(rules_dir)
    on_exit(fn -> File.rm_rf!(rules_base) end)

    seed = File.read!(Path.expand("../priv/seed/rules/substrate.toml", __DIR__))
    seed = String.replace(seed, "refuse_by_default = true", "refuse_by_default = false")
    File.write!(Path.join(rules_dir, "substrate.toml"), seed)
    Rules.load!(rules_base, Map.keys(Gateway.handlers(%{db: db})))

    tree = protected_tree(db)
    parents_before =
      current_parents(db, tree)
      |> Map.new(fn {session_key, _state, parent_session_key} ->
        {session_key, parent_session_key}
      end)

    result = retire(db, tree.target, %{})

    assert result.deleted_session_key == tree.target
    assert Enum.sort(result.retired_session_keys) ==
             Enum.sort([
               tree.target,
               tree.intermediary,
               tree.role_holder,
               tree.assignment_holder
             ])

    assert result.deferred == []
    refute Map.has_key?(result, :kept_descendants)

    assert Enum.all?(result.retired_session_keys, &(Org.get(db, &1).state == "retired"))

    parents_after =
      current_parents(db, tree)
      |> Map.new(fn {session_key, _state, parent_session_key} ->
        {session_key, parent_session_key}
      end)

    assert parents_after == parents_before
  end

  test "non-refusing cascade does not resolve a missing owner Main", %{db: db} do
    owner = "virtual-cascade-owner"
    insert_user(db, owner)
    root = create_session(db, "virtual-cascade-root", nil, "Root", owner)

    child =
      create_session(
        db,
        "virtual-cascade-child",
        root.session_key,
        "Protected child",
        owner
      )

    Roles.create!(db, "virtual-cascade-role", owner, child.session_key)

    rules_base =
      Path.join(
        System.tmp_dir!(),
        "retirement-virtual-cascade-#{System.unique_integer([:positive])}"
      )

    rules_dir = Path.join(rules_base, "identity/rules")
    File.mkdir_p!(rules_dir)
    on_exit(fn -> File.rm_rf!(rules_base) end)

    seed = File.read!(Path.expand("../priv/seed/rules/substrate.toml", __DIR__))
    seed = String.replace(seed, "refuse_by_default = true", "refuse_by_default = false")
    File.write!(Path.join(rules_dir, "substrate.toml"), seed)
    Rules.load!(rules_base, Map.keys(Gateway.handlers(%{db: db})))

    result = retire(db, root.session_key, %{}, owner)

    assert Enum.sort(result.retired_session_keys) ==
             Enum.sort([root.session_key, child.session_key])

    assert Org.get(db, root.session_key).state == "retired"
    assert Org.get(db, child.session_key).state == "retired"

    assert {:ok, [[0]]} =
             DB.query(
               db,
               "SELECT COUNT(*) FROM session_retirement_parent_moves WHERE retiredTargetSessionKey=?1",
               [root.session_key]
             )
  end

  test "kept frontier uses an active ancestor when the owner has no Main", %{db: db} do
    owner = "virtual-parent-owner"
    insert_user(db, owner)
    parent = create_session(db, "virtual-active-parent", nil, "Active ancestor", owner)

    root =
      create_session(db, "virtual-keep-root", parent.session_key, "Retiring session", owner)

    child = create_session(db, "virtual-keep-child", root.session_key, "Protected child", owner)
    Roles.create!(db, "virtual-keep-role", owner, child.session_key)

    result = retire(db, root.session_key, %{keep_open_descendants: true}, owner)

    assert result.retired_session_keys == [root.session_key]
    assert [%{session_key: child_key, parent_session_key: parent_key}] = result.kept_descendants
    assert child_key == child.session_key
    assert parent_key == parent.session_key
    assert Org.get(db, child.session_key).state == "active"
    assert Org.current_parent(db, child.session_key) == parent.session_key
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

  defp create_session(db, session_key, parent_key, display_name, owner \\ @owner) do
    Org.create(db, %{
      session_key: session_key,
      display_name: display_name,
      kind: "custom",
      owner_user_id: owner,
      origin: "user:#{owner}",
      spawned_by: parent_key,
      archetype: "default",
      host: "testhost",
      harness: "claude",
      provider: "anthropic",
      model: Model.new("fable")
    })
  end

  defp insert_user(db, owner) do
    assert {:ok, []} =
             DB.query(db, "INSERT INTO users(userId,isAdmin,createdAt) VALUES(?1,0,?2)", [
               owner,
               System.system_time(:millisecond)
             ])
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

  defp retire(db, session_key, params, owner \\ @owner) do
    Gateway.handlers(%{db: db})["retire"].(%{
      origin: "user:#{owner}",
      principal: {:user, owner},
      session_key: session_key,
      params: params
    })
  end
end
