defmodule Tightbeam.DeliveryResponsibilitiesTest do
  use Tightbeam.TestCase, async: false

  alias Tightbeam.{
    Assignments,
    DB,
    DeliveryResponsibilities,
    Dispatch,
    Model,
    Org,
    Roles,
    Rules,
    Schema,
    SessionPoAssociations
  }

  setup do
    db = start_supervised!({DB, path: ":memory:", name: nil})
    :ok = Schema.ensure_all(db)

    {:ok, _} =
      DB.query(
        db,
        "INSERT INTO users(userId,isAdmin,createdAt) VALUES('owner',0,1),('other',0,1),('admin',1,1)"
      )

    session(db, Org.personal_session_key("owner"), "owner", kind: "main")
    session(db, Org.personal_session_key("other"), "other", kind: "main")

    for key <- ~w(po-a po-b pdo-a successor-a lane-a worker-a peer pdo-b lane-b) do
      session(db, key, "owner")
    end

    for key <- ~w(po-foreign foreign-pdo foreign-worker) do
      session(db, key, "other")
    end

    Roles.create!(db, "product-owner:a", "owner", "po-a")
    Roles.create!(db, "product-owner:b", "owner", "po-b")
    Roles.create!(db, "product-owner:foreign", "other", "po-foreign")

    for key <- ~w(pdo-a successor-a lane-a worker-a) do
      associate(db, {:user, "owner"}, key, "product-owner:a", "associate-a-#{key}")
    end

    for key <- ~w(pdo-b lane-b) do
      associate(db, {:user, "owner"}, key, "product-owner:b", "associate-b-#{key}")
    end

    for key <- ~w(foreign-pdo foreign-worker) do
      associate(
        db,
        {:user, "other"},
        key,
        "product-owner:foreign",
        "associate-foreign-#{key}"
      )
    end

    item(db, "wi_a1", "owner")
    item(db, "wi_a2", "owner")
    item(db, "wi_b1", "owner")
    item(db, "wi_foreign", "other")

    %{db: db}
  end

  test "two items in one explicit PO scope resolve one accountable owner", %{db: db} do
    first = set_owner(db, {:user, "owner"}, "pdo-a", 1, nil, 0, "owner-a")
    bind_scope(db, {:user, "owner"}, "wi_a1", "pdo-a", 1, 0, "bind-a1")
    bind_scope(db, {:user, "owner"}, "wi_a2", "lane-a", 1, 0, "bind-a2")

    for item <- ~w(wi_a1 wi_a2) do
      assert %{
               "ownerUserId" => "owner",
               "poRole" => "product-owner:a",
               "ownerRevision" => 1,
               "accountableSessionKey" => "pdo-a",
               "deliveryState" => "current"
             } = DeliveryResponsibilities.current_owner(db, item)
    end

    assert first == set_owner(db, {:user, "owner"}, "pdo-a", 1, nil, 0, "owner-a")

    assert %{code: "idempotency_conflict"} =
             set_owner(db, {:user, "owner"}, "pdo-a", 1, nil, 0, "owner-a", target: "successor-a")

    assert %{code: "stale_owner_revision", message: message} =
             set_owner(db, {:user, "owner"}, "successor-a", 1, nil, 0, "second-owner")

    assert message =~ "current accountable owner is session:pdo-a"

    inspected = get(db, {:session, "lane-a"}, "wi_a2")
    assert inspected["scope"]["associationSessionKey"] == "lane-a"
    assert inspected["accountable"]["eventId"] == first["accountable"]["eventId"]
    assert length(inspected["ownerHistory"]) == 1

    assert :ok = Roles.bind(db, "product-owner:a", "peer")

    assert DeliveryResponsibilities.current_owner(db, "wi_a1")["accountableSessionKey"] ==
             "pdo-a"

    assert DeliveryResponsibilities.current_scope(db, "wi_a2")["poRole"] ==
             "product-owner:a"
  end

  test "same human, different PO offices remain distinct scopes", %{db: db} do
    set_owner(db, {:user, "owner"}, "pdo-a", 1, nil, 0, "owner-a")
    set_owner(db, {:user, "owner"}, "pdo-b", 1, nil, 0, "owner-b")
    bind_scope(db, {:user, "owner"}, "wi_a1", "pdo-a", 1, 0, "bind-a1")
    bind_scope(db, {:user, "owner"}, "wi_b1", "pdo-b", 1, 0, "bind-b1")

    assert DeliveryResponsibilities.responsibility(db, "pdo-a", "wi_a1") == "accountable"
    assert DeliveryResponsibilities.responsibility(db, "pdo-a", "wi_b1") == "none"
    assert DeliveryResponsibilities.responsibility(db, "pdo-b", "wi_b1") == "accountable"

    assert %{code: "cross_scope_session"} =
             assign(db, {:session, "pdo-a"}, "lane-a", "wi_b1", true)

    # A target in the item's actual scope must not mask that the claimant owns
    # a different PO office for the same human.
    assert %{code: "not_authorized"} =
             assign(db, {:session, "pdo-a"}, "lane-b", "wi_b1", true)

    assert %{code: "cross_owner_scope"} =
             bind_scope(
               db,
               {:user, "owner"},
               "wi_foreign",
               "pdo-a",
               1,
               0,
               "cross-owner-bind"
             )

    assert %{code: "not_authorized"} = get(db, {:session, "foreign-pdo"}, "wi_a1")
  end

  test "self association, ordinary same-user sessions, and labels grant no owner authority", %{
    db: db
  } do
    result =
      associate(
        db,
        {:session, "peer"},
        "peer",
        "product-owner:a",
        "peer-self-association"
      )

    assert result["association"]["revision"] == 1

    assert %{code: "not_authorized"} =
             set_owner(db, {:session, "peer"}, "peer", 1, nil, 0, "self-owner")

    assert %{code: "not_authorized"} =
             bind_scope(db, {:session, "peer"}, "wi_a1", "peer", 1, 0, "self-bind")

    # The actual Main is a stored session kind, not a name/archetype inference.
    main = Org.personal_session_key("owner")

    assert %{"changed" => true} =
             set_owner(db, {:session, main}, "pdo-a", 1, nil, 0, "main-owner")

    assert %{"changed" => true} =
             bind_scope(db, {:session, main}, "wi_a1", "pdo-a", 1, 0, "main-bind")

    # Once initialized, the current owner can adopt an incoming item into only
    # its own exact scope without another human approval.
    assert %{"changed" => true} =
             bind_scope(db, {:session, "pdo-a"}, "wi_a2", "lane-a", 1, 0, "owner-bind")

    assert %{"changed" => true} =
             set_owner(db, {:user, "admin"}, "foreign-pdo", 1, nil, 0, "admin-foreign-owner")

    assert %{"changed" => true} =
             bind_scope(
               db,
               {:user, "admin"},
               "wi_foreign",
               "foreign-pdo",
               1,
               0,
               "admin-foreign-bind"
             )
  end

  test "assignment grants are exact, nested, reusable, and expire", %{db: db} do
    bootstrap_a(db)

    lane_assignment = assign(db, {:session, "pdo-a"}, "lane-a", "wi_a1", true)
    assert DeliveryResponsibilities.responsibility(db, "lane-a", "wi_a1") == "delegated"
    assert DeliveryResponsibilities.responsibility(db, "lane-a", "wi_a2") == "none"

    child_assignment = assign(db, {:session, "lane-a"}, "worker-a", "wi_a1", true)
    assert DeliveryResponsibilities.responsibility(db, "worker-a", "wi_a1") == "delegated"

    plain = assign(db, {:session, "lane-a"}, "successor-a", "wi_a1", false)
    assert DeliveryResponsibilities.responsibility(db, "successor-a", "wi_a1") == "none"

    assert %{code: "delivery_delegation_requires_work_item"} =
             assign(db, {:session, "pdo-a"}, "worker-a", nil, true)

    assert %{code: "not_authorized"} =
             assign(db, {:session, "successor-a"}, "worker-a", "wi_a1", true)

    close_assignment(db, child_assignment.id, "lane-a")
    assert DeliveryResponsibilities.responsibility(db, "worker-a", "wi_a1") == "none"

    close_assignment(db, lane_assignment.id, "pdo-a")
    assert DeliveryResponsibilities.responsibility(db, "lane-a", "wi_a1") == "none"

    inspected = get(db, {:user, "owner"}, "wi_a1")
    delegations = Map.new(inspected["delegations"], &{&1["assignmentId"], &1})
    refute delegations[lane_assignment.id]["active"]
    refute delegations[child_assignment.id]["active"]
    refute Map.has_key?(delegations, plain.id)
  end

  test "an accepted child delegation survives parent revocation without extending the parent", %{
    db: db
  } do
    bootstrap_a(db)

    parent = assign(db, {:session, "pdo-a"}, "lane-a", "wi_a1", true)
    child = assign(db, {:session, "lane-a"}, "worker-a", "wi_a1", true)

    grants = Map.new(get(db, {:user, "owner"}, "wi_a1")["delegations"], &{&1["assignmentId"], &1})
    assert grants[parent.id]["grantorAssignmentId"] == nil
    assert grants[child.id]["grantorAssignmentId"] == parent.id

    close_assignment(db, parent.id, "pdo-a")

    assert DeliveryResponsibilities.responsibility(db, "lane-a", "wi_a1") == "none"
    assert DeliveryResponsibilities.responsibility(db, "worker-a", "wi_a1") == "delegated"

    assert %{code: "not_authorized"} =
             assign(db, {:session, "lane-a"}, "successor-a", "wi_a1", true)

    assert assignment = assign(db, {:session, "worker-a"}, "successor-a", "wi_a1", true)
    assert assignment.holderKey == "successor-a"

    grants = Map.new(get(db, {:user, "owner"}, "wi_a1")["delegations"], &{&1["assignmentId"], &1})
    assert grants[assignment.id]["grantorAssignmentId"] == child.id

    close_assignment(db, child.id, "lane-a")
    assert DeliveryResponsibilities.responsibility(db, "worker-a", "wi_a1") == "none"
    assert DeliveryResponsibilities.responsibility(db, "successor-a", "wi_a1") == "delegated"
  end

  test "succession is expected-revision atomic and withdraws old commissioning grants", %{
    db: db
  } do
    bootstrap_a(db)
    bind_scope(db, {:session, "pdo-a"}, "wi_a2", "lane-a", 1, 0, "bind-a2")
    lane_assignment = assign(db, {:session, "pdo-a"}, "lane-a", "wi_a1", true)
    worker_assignment = assign(db, {:session, "lane-a"}, "worker-a", "wi_a1", true)

    transfer =
      set_owner(
        db,
        {:session, "pdo-a"},
        "successor-a",
        1,
        "pdo-a",
        1,
        "transfer-a"
      )

    assert transfer["accountable"]["cause"] == "transfer"
    assert transfer["accountable"]["ownerRevision"] == 2

    for item <- ~w(wi_a1 wi_a2) do
      assert DeliveryResponsibilities.current_owner(db, item)["accountableSessionKey"] ==
               "successor-a"
    end

    assert DeliveryResponsibilities.responsibility(db, "pdo-a", "wi_a1") == "none"
    assert DeliveryResponsibilities.responsibility(db, "lane-a", "wi_a1") == "stale"
    assert DeliveryResponsibilities.responsibility(db, "worker-a", "wi_a1") == "stale"

    assert %{code: "not_authorized"} = assign(db, {:session, "pdo-a"}, "worker-a", "wi_a1", true)

    # Withdrawal affects future commissioning only. Existing obligations retain
    # their original holder/opener and can still reach a terminal outcome.
    close_assignment(db, worker_assignment.id, "lane-a")
    close_assignment(db, lane_assignment.id, "pdo-a")

    replacement = assign(db, {:session, "successor-a"}, "lane-a", "wi_a1", true)
    assert DeliveryResponsibilities.responsibility(db, "lane-a", "wi_a1") == "delegated"
    assert replacement.holderKey == "lane-a"

    grants = Map.new(get(db, {:user, "owner"}, "wi_a1")["delegations"], &{&1["assignmentId"], &1})
    refute grants[lane_assignment.id]["active"]
    assert grants[replacement.id]["active"]

    assert %{code: "stale_owner_revision"} =
             set_owner(
               db,
               {:user, "owner"},
               "pdo-a",
               1,
               "pdo-a",
               1,
               "losing-race"
             )
  end

  test "association replacement requires recovery and old replay cannot resurrect", %{db: db} do
    initial = bootstrap_a(db)

    reassociated =
      associate(
        db,
        {:user, "owner"},
        "pdo-a",
        "product-owner:b",
        "pdo-moves-office"
      )

    assert reassociated["association"]["revision"] == 2
    assert DeliveryResponsibilities.current_owner(db, "wi_a1")["deliveryState"] == "stale"
    assert DeliveryResponsibilities.responsibility(db, "pdo-a", "wi_a1") == "stale"

    assert %{code: "delivery_owner_reconciliation_required"} =
             assign(db, {:session, "pdo-a"}, "lane-a", "wi_a1", true)

    recovery =
      set_owner(
        db,
        {:session, Org.personal_session_key("owner")},
        "successor-a",
        1,
        "pdo-a",
        1,
        "recover-a"
      )

    assert recovery["accountable"]["cause"] == "recovery"
    assert recovery["accountable"]["associationSessionKey"] == "successor-a"
    assert recovery["accountable"]["associationRevision"] == 1

    {:ok, _} = DB.query(db, "UPDATE sessions SET state='retired' WHERE sessionKey='successor-a'")
    assert DeliveryResponsibilities.current_owner(db, "wi_a1")["deliveryState"] == "unavailable"

    unavailable_recovery =
      set_owner(
        db,
        {:session, Org.personal_session_key("owner")},
        "lane-a",
        1,
        "successor-a",
        2,
        "recover-unavailable-a"
      )

    assert unavailable_recovery["accountable"]["cause"] == "recovery"

    # The old successful request replays its recorded response even though its
    # association is now stale, but it does not mutate current custody.
    assert set_owner(db, {:user, "owner"}, "pdo-a", 1, nil, 0, "bootstrap-owner-a") ==
             initial

    assert DeliveryResponsibilities.current_owner(db, "wi_a1")["accountableSessionKey"] ==
             "lane-a"

    assert %{code: "idempotency_conflict"} =
             set_owner(
               db,
               {:user, "owner"},
               "successor-a",
               1,
               "pdo-a",
               1,
               "bootstrap-owner-a"
             )
  end

  test "scope reassignment preserves open obligations and appends history", %{db: db} do
    bootstrap_a(db)
    assignment = assign(db, {:session, "pdo-a"}, "lane-a", "wi_a1", true)

    assert %{code: "scope_reassignment_has_open_obligations"} =
             bind_scope(db, {:user, "owner"}, "wi_a1", "pdo-b", 1, 1, "move-open")

    close_assignment(db, assignment.id, "pdo-a")
    set_owner(db, {:user, "owner"}, "pdo-b", 1, nil, 0, "owner-b")

    moved = bind_scope(db, {:user, "owner"}, "wi_a1", "pdo-b", 1, 1, "move-closed")
    assert moved["scope"]["bindingRevision"] == 2
    assert moved["scope"]["previousPoRole"] == "product-owner:a"
    assert DeliveryResponsibilities.current_owner(db, "wi_a1")["accountableSessionKey"] == "pdo-b"

    inspected = get(db, {:user, "owner"}, "wi_a1")

    assert Enum.map(inspected["scopeHistory"], & &1["poRole"]) ==
             ["product-owner:a", "product-owner:b"]

    replayed =
      bind_scope(
        db,
        {:user, "owner"},
        "wi_a1",
        "pdo-a",
        1,
        0,
        "bootstrap-bind-a1"
      )

    assert replayed["scope"]["poRole"] == "product-owner:a"

    assert DeliveryResponsibilities.current_scope(db, "wi_a1")["poRole"] ==
             "product-owner:b"
  end

  @tag :tmp_dir
  test "rule facts distinguish missing, scoped ownership, delegated and direct targets", %{
    db: db,
    tmp_dir: tmp
  } do
    rules_dir = Path.join([tmp, "identity", "rules"])
    File.mkdir_p!(rules_dir)

    File.write!(Path.join(rules_dir, "delivery.toml"), """
    [[rule]]
    name = "spawn-needs-work-item"
    verb = "spawn"
    deny_when = [{ fact = "work_item.reference_state", op = "eq", value = "missing" }]
    text = "spawn requires an exact work item"

    [[rule]]
    name = "spawn-needs-known-work-item"
    verb = "spawn"
    deny_when = [{ fact = "work_item.reference_state", op = "eq", value = "unknown" }]
    text = "spawn requires a known work item"

    [[rule]]
    name = "spawn-needs-responsibility"
    verb = "spawn"
    deny_when = [{ fact = "caller.delivery_responsibility", op = "eq", value = "none" }]
    text = "spawn requires explicit responsibility"

    [[rule]]
    name = "do-not-assign-production-to-delivery-owner"
    verb = "assign"
    deny_when = [{ fact = "target.delivery_responsibility", op = "in", value = ["accountable", "delegated"] }]
    text = "delivery owner remains accountable"

    [[rule]]
    name = "delegation-carrier-observed"
    verb = "dispatch"
    deny_when = [{ fact = "assign.delegates_delivery", op = "eq", value = true }]
    text = "test observes the explicit carrier"
    """)

    Rules.load!(tmp, ["spawn", "assign", "dispatch"])

    assert {{:deny, %{rule: "spawn-needs-work-item"}}, [], []} =
             Rules.decide(db, rule_call("spawn", "peer", nil, nil))

    assert {{:deny, %{rule: "spawn-needs-known-work-item"}}, [], []} =
             Rules.decide(db, rule_call("spawn", "peer", nil, "wi_missing"))

    assert {{:deny, %{rule: "spawn-needs-responsibility"}}, [], []} =
             Rules.decide(db, rule_call("spawn", "peer", nil, "wi_a1"))

    bootstrap_a(db)
    assert {:allow, [], []} = Rules.decide(db, rule_call("spawn", "pdo-a", nil, "wi_a1"))

    for caller <- [Org.personal_session_key("owner"), "po-a"] do
      assert {{:deny, %{rule: "spawn-needs-responsibility"}}, [], []} =
               Rules.decide(db, rule_call("spawn", caller, nil, "wi_a1"))
    end

    assert {{:deny, %{rule: "do-not-assign-production-to-delivery-owner"}}, [], []} =
             Rules.decide(db, rule_call("assign", "lane-a", "pdo-a", "wi_a1"))

    assert {:allow, [], []} = Rules.decide(db, rule_call("assign", "lane-a", "worker-a", "wi_a1"))

    assert {{:deny, %{rule: "delegation-carrier-observed"}}, [], []} =
             Rules.decide(
               db,
               rule_call("dispatch", "pdo-a", "lane-a", "wi_a1", delegates_delivery: true)
             )
  end

  @tag :tmp_dir
  test "engineering rules admit only exact-item production staffing through Dispatch", %{
    db: db,
    tmp_dir: tmp
  } do
    rules_dir = Path.join([tmp, "identity", "rules"])
    File.mkdir_p!(rules_dir)

    File.cp!(
      Path.expand("../priv/kungfu/agentic-engineering/rules/delivery.toml", __DIR__),
      Path.join(rules_dir, "delivery.toml")
    )

    Rules.load!(tmp, ["spawn", "assign", "dispatch"])
    session(db, "consult-po", "owner", archetype: "product-owner")
    session(db, "intake-pdo", "owner", archetype: "pdo")

    assignment_handlers = %{
      "assign" => fn call -> Assignments.__handle__(db, "assign", call) end,
      "dispatch" => fn call -> Assignments.__handle__(db, "dispatch", call) end
    }

    for caller <- [Org.personal_session_key("owner"), "po-a"] do
      assert {:error,
              %{
                rule: "engineering-assign-production-needs-delivery-owner",
                message: message
              }} =
               Dispatch.dispatch(
                 db,
                 assignment_handlers,
                 production_call("assign", caller, "worker-a", "wi_a1")
               )

      assert message =~ "No accountable delivery owner is recorded"
      assert message =~ "Establish the work item's delivery scope and accountable owner"
      refute message =~ "Route the request through that owner"
    end

    assert {:error,
            %{
              rule: "engineering-dispatch-production-needs-delivery-owner",
              message: dispatch_message
            }} =
             Dispatch.dispatch(
               db,
               assignment_handlers,
               production_call(
                 "dispatch",
                 Org.personal_session_key("owner"),
                 "worker-a",
                 "wi_a1"
               )
             )

    assert dispatch_message =~ "No accountable delivery owner is recorded"
    assert dispatch_message =~ "Establish the work item's delivery scope and accountable owner"

    assert {:error,
            %{
              rule: "engineering-dispatch-labeled-coordination-needs-delivery-owner",
              message: labeled_dispatch_message
            }} =
             Dispatch.dispatch(
               db,
               assignment_handlers,
               production_call(
                 "dispatch",
                 Org.personal_session_key("owner"),
                 "worker-a",
                 "wi_a1",
                 effect_kind: "coordination"
               )
             )

    assert labeled_dispatch_message =~ "No accountable delivery owner is recorded"

    assert {:error, %{rule: "engineering-assign-staffing-needs-work-item"}} =
             Dispatch.dispatch(
               db,
               assignment_handlers,
               production_call("assign", "pdo-a", "worker-a", nil)
             )

    assert {:error, %{rule: "engineering-assign-staffing-needs-work-item"}} =
             Dispatch.dispatch(
               db,
               assignment_handlers,
               production_call("assign", "pdo-a", "worker-a", "wi_missing")
             )

    assert {:ok, %{holderKey: "intake-pdo", effectKind: "coordination"}} =
             Dispatch.dispatch(
               db,
               assignment_handlers,
               production_call(
                 "assign",
                 {:user, "owner"},
                 "intake-pdo",
                 "wi_a1",
                 effect_kind: "coordination"
               )
             )

    assert {:ok, %{holderKey: "consult-po", effectKind: "coordination"}} =
             Dispatch.dispatch(
               db,
               assignment_handlers,
               production_call(
                 "assign",
                 Org.personal_session_key("owner"),
                 "consult-po",
                 "wi_a1",
                 effect_kind: "coordination"
               )
             )

    for target <- ["consult-po", "intake-pdo"] do
      assert {:error, %{rule: "engineering-assign-production-office-target-refused"}} =
               Dispatch.dispatch(
                 db,
                 assignment_handlers,
                 production_call("assign", {:user, "owner"}, target, "wi_a1")
               )
    end

    producer = assign(db, {:session, "pdo-a"}, "worker-a", "wi_a1", false)

    assert {:ok, %{holderKey: "peer", effectKind: "review"}} =
             Dispatch.dispatch(
               db,
               assignment_handlers,
               production_call("assign", {:user, "owner"}, "peer", "wi_a1",
                 reviews_assignment_id: producer.id
               )
             )

    for {misleading_effect, rule} <- [
          {"coordination", "engineering-assign-labeled-coordination-needs-delivery-owner"},
          {"review", "engineering-assign-production-needs-delivery-owner"}
        ] do
      assert {:error, %{rule: ^rule}} =
               Dispatch.dispatch(
                 db,
                 assignment_handlers,
                 production_call(
                   "assign",
                   Org.personal_session_key("owner"),
                   "worker-a",
                   "wi_a1",
                   effect_kind: misleading_effect
                 )
               )
    end

    spawn_handlers = %{"spawn" => fn call -> %{archetype: call.params[:archetype]} end}

    assert {:error, %{rule: "engineering-spawn-staffing-needs-work-item"}} =
             Dispatch.dispatch(
               db,
               spawn_handlers,
               spawn_call(Org.personal_session_key("owner"), nil, nil)
             )

    assert {:error, %{rule: "engineering-spawn-staffing-needs-work-item"}} =
             Dispatch.dispatch(
               db,
               spawn_handlers,
               spawn_call(Org.personal_session_key("owner"), "coder", "wi_missing")
             )

    assert {:error, %{rule: "engineering-spawn-referenced-work-item-must-exist"}} =
             Dispatch.dispatch(
               db,
               spawn_handlers,
               spawn_call(Org.personal_session_key("owner"), "orchestrator", "wi_missing")
             )

    assert {:error,
            %{rule: "engineering-spawn-staffing-needs-delivery-owner", message: spawn_message}} =
             Dispatch.dispatch(
               db,
               spawn_handlers,
               spawn_call(Org.personal_session_key("owner"), nil, "wi_a1")
             )

    assert spawn_message =~ "No accountable delivery owner is recorded"
    assert spawn_message =~ "Establish the work item's delivery scope and accountable owner"

    assert {:ok, %{archetype: "product-owner"}} =
             Dispatch.dispatch(
               db,
               spawn_handlers,
               spawn_call(Org.personal_session_key("owner"), "product-owner", nil)
             )

    assert {:ok, %{archetype: "pdo"}} =
             Dispatch.dispatch(
               db,
               spawn_handlers,
               spawn_call(Org.personal_session_key("owner"), "pdo", nil)
             )

    bootstrap_a(db)

    assert {:ok, %{holderKey: "pdo-a", effectKind: "coordination"}} =
             Dispatch.dispatch(
               db,
               assignment_handlers,
               production_call(
                 "assign",
                 Org.personal_session_key("owner"),
                 "pdo-a",
                 "wi_a1",
                 effect_kind: "coordination"
               )
             )

    for archetype <- [nil, "coder", "orchestrator"] do
      assert {:error,
              %{
                rule: "engineering-spawn-staffing-needs-topology",
                message: message
              }} = Dispatch.dispatch(db, spawn_handlers, spawn_call("pdo-a", archetype, "wi_a1"))

      assert message =~ "Current accountable owner: session:pdo-a"
      assert message =~ "Record topology-decided"
    end

    assert {:error,
            %{
              rule: "engineering-assign-production-needs-topology",
              message: message
            }} =
             Dispatch.dispatch(
               db,
               assignment_handlers,
               production_call("assign", "pdo-a", "worker-a", "wi_a1")
             )

    assert message =~ "Current accountable owner: session:pdo-a"
    assert message =~ "Record topology-decided"

    for {misleading_effect, rule} <- [
          {"coordination", "engineering-assign-labeled-coordination-needs-topology"},
          {"review", "engineering-assign-production-needs-topology"}
        ] do
      assert {:error, %{rule: ^rule}} =
               Dispatch.dispatch(
                 db,
                 assignment_handlers,
                 production_call("assign", "pdo-a", "worker-a", "wi_a1",
                   effect_kind: misleading_effect
                 )
               )
    end

    topology = assign(db, {:session, "pdo-a"}, "lane-a", "wi_a1", false)

    assert %{attest: %{verdictKind: "topology-decided"}} =
             attest_verdict(db, "lane-a", topology.id, "topology-decided")

    assert {:ok, _} =
             DB.query(db, "UPDATE sessions SET archetype='orchestrator' WHERE sessionKey='pdo-a'")

    assert {:ok, %{holderKey: "pdo-a", effectKind: "coordination"}} =
             Dispatch.dispatch(
               db,
               assignment_handlers,
               production_call(
                 "assign",
                 Org.personal_session_key("owner"),
                 "pdo-a",
                 "wi_a1",
                 effect_kind: "coordination"
               )
             )

    for {caller, target, effect_kind, rule} <- [
          {Org.personal_session_key("owner"), "consult-po", "policy",
           "engineering-assign-production-office-target-refused"},
          {"po-a", "intake-pdo", "code", "engineering-assign-production-office-target-refused"},
          {"pdo-a", "intake-pdo", "code", "engineering-assign-production-office-target-refused"},
          {"pdo-a", "pdo-a", "code",
           "engineering-assign-production-accountable-owner-target-refused"}
        ] do
      assert {:error, %{rule: ^rule}} =
               Dispatch.dispatch(
                 db,
                 assignment_handlers,
                 production_call("assign", caller, target, "wi_a1", effect_kind: effect_kind)
               )
    end

    assert {:ok, %{holderKey: "lane-a", effectKind: "code"}} =
             Dispatch.dispatch(
               db,
               assignment_handlers,
               production_call("assign", "pdo-a", "lane-a", "wi_a1", delegates_delivery: true)
             )

    assert {:ok, %{holderKey: "worker-a", effectKind: "code"}} =
             Dispatch.dispatch(
               db,
               assignment_handlers,
               production_call("assign", "lane-a", "worker-a", "wi_a1", delegates_delivery: true)
             )

    assert {:ok, %{archetype: "coder"}} =
             Dispatch.dispatch(db, spawn_handlers, spawn_call("lane-a", "coder", "wi_a1"))
  end

  test "schema is additive and every authority history is immutable", %{db: db} do
    assert {:ok,
            [
              ["assignment_delivery_delegations"],
              ["delivery_scope_owner_events"],
              ["work_item_delivery_scope_events"]
            ]} =
             DB.query(
               db,
               "SELECT name FROM sqlite_master WHERE type='table' AND name IN ('assignment_delivery_delegations','delivery_scope_owner_events','work_item_delivery_scope_events') ORDER BY name"
             )

    bootstrap_a(db)
    assign(db, {:session, "pdo-a"}, "lane-a", "wi_a1", true)

    for {table, message} <- [
          {"work_item_delivery_scope_events", "append-only"},
          {"delivery_scope_owner_events", "append-only"},
          {"assignment_delivery_delegations", "immutable"}
        ] do
      assert {:error, %DB.Error{message: error}} =
               DB.query(db, "UPDATE #{table} SET createdAt=createdAt+1")

      assert error =~ message
    end

    assert :ok = Schema.ensure_all(db)
    assert {:ok, []} = DB.query(db, "PRAGMA foreign_key_check")
  end

  defp bootstrap_a(db) do
    owner = set_owner(db, {:user, "owner"}, "pdo-a", 1, nil, 0, "bootstrap-owner-a")
    bind_scope(db, {:user, "owner"}, "wi_a1", "pdo-a", 1, 0, "bootstrap-bind-a1")
    owner
  end

  defp set_owner(db, principal, target, association_revision, expected, revision, key, opts \\ []) do
    DeliveryResponsibilities.handle(db, %{
      verb: "delivery-scope-owner-set",
      origin: origin(principal),
      principal: principal,
      params: %{
        session_key: opts[:target] || target,
        association_revision: association_revision,
        expected_owner_session_key: expected,
        expected_owner_revision: revision,
        idempotency_key: key
      }
    })
  end

  defp bind_scope(db, principal, item, source, association_revision, expected_revision, key) do
    DeliveryResponsibilities.handle(db, %{
      verb: "work-item-delivery-scope-set",
      origin: origin(principal),
      principal: principal,
      params: %{
        work_item_id: item,
        association_session_key: source,
        association_revision: association_revision,
        expected_binding_revision: expected_revision,
        idempotency_key: key
      }
    })
  end

  defp get(db, principal, work_item_id) do
    DeliveryResponsibilities.handle(db, %{
      verb: "delivery-responsibility-get",
      origin: origin(principal),
      principal: principal,
      params: %{work_item_id: work_item_id}
    })
  end

  defp associate(db, principal, target, po_role, key) do
    SessionPoAssociations.handle(db, %{
      principal: principal,
      params: %{
        session_key: target,
        po_role: po_role,
        idempotency_key: key
      }
    })
  end

  defp assign(db, principal, target, work_item_id, delegates_delivery) do
    Assignments.__handle__(db, "assign", %{
      verb: "assign",
      origin: origin(principal),
      principal: principal,
      session_key: target,
      target_role: nil,
      role_fallback: false,
      supervision_interval_ms: 1_000,
      params: %{
        subject: "delivery test #{System.unique_integer([:positive])}",
        idempotency_key: nil,
        work_item_id: work_item_id,
        reviews_assignment_id: nil,
        effect_kind: "coordination",
        files: nil,
        delegates_delivery: delegates_delivery
      }
    })
  end

  defp close_assignment(db, assignment_id, opener) do
    assert %{state: "closed", outcome: "revoked"} =
             Assignments.__handle__(db, "revoke-assignment", %{
               verb: "revoke-assignment",
               origin: "agent:" <> opener,
               principal: {:session, opener},
               params: %{assignment_id: assignment_id, reason: "test delegation expiry"}
             })
  end

  defp attest_verdict(db, holder, assignment_id, verdict_kind) do
    Assignments.__handle__(db, "attest", %{
      verb: "attest",
      origin: "agent:" <> holder,
      principal: {:session, holder},
      params: %{
        assignment_id: assignment_id,
        kind: "verdict",
        verdict_kind: verdict_kind
      }
    })
  end

  defp rule_call(verb, caller, target, work_item_id, options \\ []) do
    params =
      %{work_item_id: work_item_id}
      |> Map.merge(Map.new(options))

    %{
      verb: verb,
      origin: "agent:#{caller}",
      principal: {:session, caller},
      session_key: target,
      params: params
    }
  end

  defp production_call(verb, caller, target, work_item_id, options \\ []) do
    principal = if is_tuple(caller), do: caller, else: {:session, caller}

    params = %{
      subject: "production #{System.unique_integer([:positive])}",
      idempotency_key: nil,
      work_item_id: work_item_id,
      reviews_assignment_id: options[:reviews_assignment_id],
      effect_kind: options[:effect_kind],
      files: nil,
      delegates_delivery: options[:delegates_delivery] || false
    }

    %{
      verb: verb,
      origin: origin(principal),
      principal: principal,
      session_key: target,
      target_role: nil,
      role_fallback: false,
      supervision_interval_ms: 1_000,
      params: params
    }
  end

  defp spawn_call(caller, archetype, work_item_id) do
    params =
      %{work_item_id: work_item_id}
      |> then(fn params ->
        if archetype, do: Map.put(params, :archetype, archetype), else: params
      end)

    %{
      verb: "spawn",
      origin: "agent:#{caller}",
      principal: {:session, caller},
      session_key: nil,
      params: params
    }
  end

  defp origin({:user, owner}), do: "user:" <> owner
  defp origin({:session, session}), do: "agent:" <> session

  defp session(db, key, owner, options \\ []) do
    Org.create(db, %{
      session_key: key,
      display_name: key,
      owner_user_id: owner,
      origin: "user:" <> owner,
      kind: options[:kind] || "custom",
      archetype: options[:archetype] || "default",
      harness: "fixture",
      provider: "fixture_provider",
      model: Model.new("fixture"),
      host: "synthetic-host"
    })
  end

  defp item(db, id, owner) do
    {:ok, _} =
      DB.query(
        db,
        """
        INSERT INTO work_items
          (id,title,ownerUserId,state,createdByUser,createdContextKnown,createdAt)
        VALUES (?1,?1,?2,'open',?2,0,1)
        """,
        [id, owner]
      )
  end
end
