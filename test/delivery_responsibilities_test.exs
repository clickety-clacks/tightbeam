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
    SessionPoAssociations,
    WorkItems
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

    for {key, owner, archetype} <- [
          {"pdo-a", "owner", "pdo"},
          {"pdo-b", "owner", "pdo"},
          {"successor-a", "owner", "coder"},
          {"lane-a", "owner", "coder"},
          {"lane-b", "owner", "coder"},
          {"worker-a", "owner", "coder"},
          {"peer", "owner", "coder"},
          {"consult-po", "owner", "product-owner"},
          {"intake-pdo", "owner", "pdo"},
          {"reviewer", "owner", "reviewer"},
          {"foreign-pdo", "other", "pdo"},
          {"foreign-worker", "other", "coder"}
        ] do
      session(db, key, owner, archetype: archetype)
    end

    for {id, owner} <- [
          {"wi_a1", "owner"},
          {"wi_a2", "owner"},
          {"wi_b1", "owner"},
          {"wi_foreign", "other"}
        ] do
      item(db, id, owner)
    end

    Roles.create!(db, "product-owner:a", "owner", "pdo-a")
    Roles.create!(db, "product-owner:b", "owner", "pdo-b")

    %{db: db}
  end

  test "one explicit link belongs to the exact item and may be reused", %{db: db} do
    assert %{deliveryOwnerSessionKey: "pdo-a"} = set_owner(db, {:user, "owner"}, "wi_a1", "pdo-a")
    assert %{deliveryOwnerSessionKey: "pdo-a"} = set_owner(db, {:user, "owner"}, "wi_a2", "pdo-a")

    for work_item_id <- ["wi_a1", "wi_a2"] do
      assert %{
               "workItemId" => ^work_item_id,
               "ownerUserId" => "owner",
               "accountableSessionKey" => "pdo-a",
               "deliveryState" => "current"
             } = DeliveryResponsibilities.current_owner(db, work_item_id)

      item =
        WorkItems.__handle__(db, "work-item-get", work_item_call({:user, "owner"}, work_item_id))

      assert item.workItem.deliveryOwnerSessionKey == "pdo-a"
    end

    refute DeliveryResponsibilities.current_owner(db, "wi_b1")
  end

  test "role names, shared human ownership, and ancestry do not elect an owner", %{db: db} do
    assert %{code: "delivery_owner_missing", message: missing} =
             assign(db, {:session, "pdo-a"}, "worker-a", "wi_a1")

    assert missing =~ "no recorded delivery owner"
    assert missing =~ "work-item-update --delivery-owner"

    set_owner(db, {:user, "owner"}, "wi_a1", "pdo-a")
    {:ok, _} = DB.query(db, "UPDATE sessions SET spawnedBy='pdo-a' WHERE sessionKey='peer'")

    for caller <- ["peer", "foreign-worker"] do
      assert %{code: "delivery_owner_required", message: message} =
               assign(db, {:session, caller}, "worker-a", "wi_a1")

      assert message =~ "session:pdo-a"
      assert message =~ "active holder of an open assignment on this exact item"
    end
  end

  test "published delivery facts describe the direct owner and exact-item custody", %{db: db} do
    set_owner(db, {:user, "owner"}, "wi_a1", "pdo-a")
    assign(db, {:session, "pdo-a"}, "lane-a", "wi_a1")

    call = production_call("assign", {:session, "lane-a"}, "lane-a", "wi_a1")

    assert %{
             matched: true,
             facts: [
               {"work_item.has_delivery_owner", true},
               {"caller.delivery_responsibility", "delegated"},
               {"target.delivery_responsibility", "delegated"},
               {"assign.delegates_delivery", false}
             ]
           } =
             Rules.condition_evidence(
               db,
               call,
               [
                 %{fact: "work_item.has_delivery_owner", op: "eq", value: true},
                 %{fact: "caller.delivery_responsibility", op: "eq", value: "delegated"},
                 %{fact: "target.delivery_responsibility", op: "eq", value: "delegated"},
                 %{fact: "assign.delegates_delivery", op: "eq", value: false}
               ]
             )

    unowned_call = production_call("assign", {:session, "peer"}, "peer", "wi_a2")

    assert %{
             matched: true,
             facts: [
               {"work_item.has_delivery_owner", false},
               {"caller.delivery_responsibility", "none"},
               {"target.delivery_responsibility", "none"}
             ]
           } =
             Rules.condition_evidence(
               db,
               unowned_call,
               [
                 %{fact: "work_item.has_delivery_owner", op: "eq", value: false},
                 %{fact: "caller.delivery_responsibility", op: "eq", value: "none"},
                 %{fact: "target.delivery_responsibility", op: "eq", value: "none"}
               ]
             )
  end

  test "owner may hold a lawful assignment while human control remains itemless", %{db: db} do
    set_owner(db, {:user, "owner"}, "wi_a1", "pdo-a")

    assert %{holderKey: "pdo-a", workItemId: "wi_a1"} =
             assign(db, {:session, "pdo-a"}, "pdo-a", "wi_a1")

    before = count(db, "assignments")

    assert %{holderKey: "worker-a", workItemId: "wi_a1"} =
             assign(db, {:user, "owner"}, "worker-a", "wi_a1")

    assert count(db, "assignments") == before + 1

    assert %{holderKey: "worker-a", workItemId: nil} =
             assign(db, {:user, "owner"}, "worker-a", nil)

    after_success = count(db, "assignments")

    assert %{code: "delivery_owner_missing"} =
             assign(db, {:user, "owner"}, "worker-a", "wi_a2")

    assert count(db, "assignments") == after_success
  end

  test "missing references, unavailable owners, and mismatched owner refs are named", %{db: db} do
    assert %{code: "work_item_required"} = assign(db, {:session, "pdo-a"}, "worker-a", nil)

    assert %{code: "unknown_work_item", message: message} =
             assign(db, {:session, "pdo-a"}, "worker-a", "wi_missing")

    assert message =~ "wi_missing"
    assert message =~ "correct the item reference"

    set_owner(db, {:user, "owner"}, "wi_a1", "pdo-a")

    assert %{code: "delivery_owner_mismatch", message: mismatch} =
             assign(db, {:session, "pdo-a"}, "worker-a", "wi_a1",
               delivery_owner_ref: "session:successor-a"
             )

    assert mismatch =~ "records delivery owner session:pdo-a"
    assert mismatch =~ "session:successor-a"

    {:ok, _} = DB.query(db, "UPDATE sessions SET state='retired' WHERE sessionKey='pdo-a'")

    assert %{code: "delivery_owner_unavailable", message: unavailable} =
             assign(db, {:session, "peer"}, "worker-a", "wi_a1")

    assert unavailable =~ "session:pdo-a"
    assert unavailable =~ "replace the link with work-item-update --delivery-owner"
  end

  test "an echoed owner reference is not authority and denial creates no assignment", %{db: db} do
    set_owner(db, {:user, "owner"}, "wi_a1", "pdo-a")
    before = count(db, "assignments")

    assert %{code: "delivery_owner_required"} =
             assign(db, {:session, "peer"}, "worker-a", "wi_a1",
               delivery_owner_ref: "session:pdo-a"
             )

    assert count(db, "assignments") == before

    assert %{holderKey: "worker-a"} = assign(db, {:session, "pdo-a"}, "worker-a", "wi_a1")
  end

  test "only an active open exact-item holder carries staffing responsibility", %{db: db} do
    set_owner(db, {:user, "owner"}, "wi_a1", "pdo-a")
    set_owner(db, {:user, "owner"}, "wi_b1", "pdo-b")

    lane = assign(db, {:session, "pdo-a"}, "lane-a", "wi_a1")
    assert DeliveryResponsibilities.responsibility(db, "lane-a", "wi_a1") == "delegated"
    assert DeliveryResponsibilities.responsibility(db, "lane-a", "wi_b1") == "none"

    assert %{code: "delivery_owner_required"} =
             assign(db, {:session, "lane-a"}, "worker-a", "wi_b1")

    child = assign(db, {:session, "lane-a"}, "worker-a", "wi_a1")
    assert DeliveryResponsibilities.responsibility(db, "worker-a", "wi_a1") == "delegated"

    assert %{code: "delivery_delegation_retired"} =
             assign(db, {:session, "pdo-a"}, "lane-b", "wi_a1", delegates_delivery: true)

    close_assignment(db, lane.id, "pdo-a")

    assert DeliveryResponsibilities.responsibility(db, "lane-a", "wi_a1") == "none"

    assert %{code: "delivery_owner_required"} =
             assign(db, {:session, "lane-a"}, "lane-b", "wi_a1")

    assert %{holderKey: "peer"} = assign(db, {:session, "worker-a"}, "peer", "wi_a1")
    assert DeliveryResponsibilities.responsibility(db, "worker-a", "wi_a1") == "delegated"

    assert {:ok, [["open"]]} =
             DB.query(db, "SELECT state FROM assignments WHERE id=?1", [child.id])
  end

  test "completed and revoked assignments stop carrying responsibility", %{db: db} do
    set_owner(db, {:user, "owner"}, "wi_a1", "pdo-a")

    completed =
      assign(db, {:session, "pdo-a"}, "lane-a", "wi_a1", effect_kind: "coordination")

    assert %{assignment: %{state: "closed", outcome: "completed"}} =
             Assignments.__handle__(db, "attest", %{
               verb: "attest",
               origin: "agent:lane-a",
               principal: {:session, "lane-a"},
               session_key: nil,
               params: %{
                 assignment_id: completed.id,
                 kind: "completion"
               }
             })

    assert DeliveryResponsibilities.responsibility(db, "lane-a", "wi_a1") == "none"

    revoked = assign(db, {:session, "pdo-a"}, "lane-b", "wi_a1")
    close_assignment(db, revoked.id, "pdo-a")
    assert DeliveryResponsibilities.responsibility(db, "lane-b", "wi_a1") == "none"

    for holder <- ["lane-a", "lane-b"] do
      assert %{code: "delivery_owner_required"} =
               assign(db, {:session, holder}, "worker-a", "wi_a1")
    end
  end

  test "owner replacement preserves active lanes and never rewrites attribution", %{db: db} do
    set_owner(db, {:user, "owner"}, "wi_a1", "pdo-a")
    lane = assign(db, {:session, "pdo-a"}, "lane-a", "wi_a1")

    assert %{deliveryOwnerSessionKey: "successor-a"} =
             set_owner(db, {:user, "owner"}, "wi_a1", "successor-a")

    assert DeliveryResponsibilities.current_owner(db, "wi_a1")["accountableSessionKey"] ==
             "successor-a"

    assert DeliveryResponsibilities.responsibility(db, "lane-a", "wi_a1") == "delegated"

    assert %{assignment: %{state: "open"}} =
             Assignments.__handle__(db, "attest", %{
               verb: "attest",
               origin: "agent:lane-a",
               principal: {:session, "lane-a"},
               session_key: nil,
               params: %{assignment_id: lane.id, kind: "progress", note: "Owner link replaced."}
             })

    assert %{holderKey: "worker-a"} = assign(db, {:session, "lane-a"}, "worker-a", "wi_a1")

    assert %{code: "delivery_owner_required"} =
             assign(db, {:session, "pdo-a"}, "peer", "wi_a1")

    assert {:ok, [["pdo-a", "lane-a"]]} =
             DB.query(db, "SELECT openedBySession,holderKey FROM assignments WHERE id=?1", [
               lane.id
             ])
  end

  test "PO association edits cannot stale or move a direct item owner", %{db: db} do
    set_owner(db, {:user, "owner"}, "wi_a1", "pdo-a")

    assert %{"association" => %{"revision" => 1}} =
             associate(db, {:user, "owner"}, "pdo-a", "product-owner:a", "association-a")

    assert %{"association" => %{"revision" => 2}} =
             associate(db, {:user, "owner"}, "pdo-a", "product-owner:b", "association-b")

    assert DeliveryResponsibilities.current_owner(db, "wi_a1")["deliveryState"] == "current"

    assert DeliveryResponsibilities.current_owner(db, "wi_a1")["accountableSessionKey"] ==
             "pdo-a"
  end

  test "assignment and dispatch share admission while intake and linked review stay reachable", %{
    db: db
  } do
    tmp = Path.join(System.tmp_dir!(), "delivery-rules-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(tmp) end)
    load_delivery_rules!(tmp)
    set_owner(db, {:user, "owner"}, "wi_a1", "pdo-a")

    topology = assign(db, {:session, "pdo-a"}, "lane-a", "wi_a1")

    assert %{attest: %{verdictKind: "topology-decided"}} =
             attest_verdict(db, "lane-a", topology.id, "topology-decided")

    handlers = assignment_handlers(db)
    before = count(db, "assignments")
    wakes_before = count(db, "wakes")

    for caller <- ["peer", "foreign-worker"] do
      assert {:error, %{code: "delivery_owner_required", message: message}} =
               Dispatch.dispatch(
                 db,
                 handlers,
                 production_call("assign", {:session, caller}, "worker-a", "wi_a1")
               )

      assert message =~ "session:pdo-a"
      assert count(db, "assignments") == before
      assert count(db, "wakes") == wakes_before
    end

    set_owner(db, {:user, "owner"}, "wi_a2", "pdo-b")
    {:ok, _} = DB.query(db, "UPDATE sessions SET state='retired' WHERE sessionKey='pdo-b'")

    for {verb, work_item_id, owner_ref, expected_code, expected_message} <- [
          {"assign", "wi_b1", nil, "delivery_owner_missing", "work-item-update --delivery-owner"},
          {"dispatch", "wi_b1", nil, "delivery_owner_missing",
           "work-item-update --delivery-owner"},
          {"assign", "wi_a1", "session:successor-a", "delivery_owner_mismatch", "session:pdo-a"},
          {"dispatch", "wi_a1", "session:successor-a", "delivery_owner_mismatch",
           "session:pdo-a"},
          {"assign", "wi_a2", nil, "delivery_owner_unavailable", "session:pdo-b"},
          {"dispatch", "wi_a2", nil, "delivery_owner_unavailable", "session:pdo-b"}
        ] do
      call = production_call(verb, {:session, "peer"}, "worker-a", work_item_id)
      call = if owner_ref, do: put_in(call, [:params, :delivery_owner_ref], owner_ref), else: call

      assert {:error, %{code: ^expected_code, message: message}} =
               Dispatch.dispatch(db, handlers, call)

      assert message =~ expected_message
      assert message =~ work_item_id
      assert count(db, "assignments") == before
      assert count(db, "wakes") == wakes_before
    end

    assert {:ok, %{holderKey: "worker-a"}} =
             Dispatch.dispatch(
               db,
               handlers,
               production_call("assign", {:session, "pdo-a"}, "worker-a", "wi_a1")
             )

    owner_dispatch = production_call("dispatch", {:session, "pdo-a"}, "peer", "wi_a1")

    assert {:ok, %{rumination_required: true}} =
             Dispatch.dispatch(db, handlers, owner_dispatch)

    delegated_dispatch = production_call("dispatch", {:session, "lane-a"}, "worker-a", "wi_a1")

    assert {:ok, %{rumination_required: true}} =
             Dispatch.dispatch(db, handlers, delegated_dispatch)

    set_owner(db, {:user, "owner"}, "wi_b1", "peer")

    intake = production_call("dispatch", {:session, "peer"}, "intake-pdo", "wi_b1")
    intake = put_in(intake, [:params, :effect_kind], "coordination")

    assert {:ok, %{rumination_required: true}} = Dispatch.dispatch(db, handlers, intake)

    consultation = production_call("dispatch", {:session, "peer"}, "consult-po", "wi_b1")
    consultation = put_in(consultation, [:params, :effect_kind], "coordination")

    assert {:ok, %{rumination_required: true}} = Dispatch.dispatch(db, handlers, consultation)

    producer = assign(db, {:session, "pdo-a"}, "worker-a", "wi_a1")
    producer_id = producer.id

    assert %{holderKey: "reviewer", reviewsAssignmentId: ^producer_id, effectKind: "review"} =
             assign(db, {:session, "peer"}, "reviewer", "wi_a1",
               reviews_assignment_id: producer_id,
               effect_kind: "review"
             )
  end

  test "only the exact internal spawn remedy admits itemless spawn and still checks item refs", %{
    db: db
  } do
    set_owner(db, {:user, "owner"}, "wi_a1", "pdo-a")

    assert {:ok, {:ok, :ok, mismatch, itemless_ref, spoofed}} =
             DB.transaction(db, fn txn ->
               remedy = %{
                 verb: "spawn",
                 origin: "remedy:review-before-merge",
                 session_key: nil,
                 principal: {:remedy, %{action: "spawn", owner: "owner"}},
                 params: %{}
               }

               linked = %{
                 remedy
                 | params: %{
                     work_item_id: "wi_a1",
                     delivery_owner_ref: "session:pdo-a"
                   }
               }

               wrong_link = put_in(linked, [:params, :delivery_owner_ref], "session:lane-a")

               reference_without_item = %{
                 remedy
                 | params: %{delivery_owner_ref: "session:pdo-a"}
               }

               public_origin_only = %{
                 remedy
                 | origin: "remedy:review-before-merge",
                   principal: {:session, "peer"}
               }

               {
                 DeliveryResponsibilities.check_staffing_owner_in_txn(
                   txn,
                   remedy,
                   owner_user_id: "owner"
                 ),
                 DeliveryResponsibilities.check_staffing_owner_in_txn(
                   txn,
                   linked,
                   owner_user_id: "owner"
                 ),
                 DeliveryResponsibilities.check_staffing_owner_in_txn(
                   txn,
                   wrong_link,
                   owner_user_id: "owner"
                 ),
                 DeliveryResponsibilities.check_staffing_owner_in_txn(
                   txn,
                   reference_without_item,
                   owner_user_id: "owner"
                 ),
                 DeliveryResponsibilities.check_staffing_owner_in_txn(
                   txn,
                   public_origin_only,
                   owner_user_id: "owner"
                 )
               }
             end)

    assert %{code: "delivery_owner_mismatch"} = mismatch
    assert %{code: "delivery_owner_reference_requires_work_item"} = itemless_ref
    assert %{code: "work_item_required"} = spoofed
  end

  test "retired verbs refuse clearly and new stores do not create a second ledger", %{db: db} do
    for verb <- [
          "work-item-delivery-scope-set",
          "delivery-scope-owner-set",
          "delivery-responsibility-get"
        ] do
      assert %{code: "delivery_operation_retired", message: message} =
               DeliveryResponsibilities.handle(db, %{verb: verb})

      assert message =~ "work-item-update --delivery-owner"
    end

    assert {:ok, nil} =
             DB.transaction(db, fn txn ->
               DeliveryResponsibilities.current_accountable_recipient_in_txn(
                 txn,
                 "wi_a1",
                 "owner"
               )
             end)

    assert {:ok, []} =
             DB.query(
               db,
               "SELECT name FROM sqlite_master WHERE type='table' AND name IN ('assignment_delivery_delegations','delivery_scope_owner_events','work_item_delivery_scope_events')"
             )
  end

  defp set_owner(db, principal, work_item_id, session_key) do
    WorkItems.__handle__(db, "work-item-update", %{
      verb: "work-item-update",
      origin: origin(principal),
      principal: principal,
      session_key: nil,
      params: %{work_item_id: work_item_id, delivery_owner_session_key: session_key}
    })
  end

  defp assign(db, principal, target, work_item_id, options \\ []) do
    verb = Keyword.get(options, :verb, "assign")

    params = %{
      subject: "delivery test #{System.unique_integer([:positive])}",
      idempotency_key: nil,
      work_item_id: work_item_id,
      reviews_assignment_id: Keyword.get(options, :reviews_assignment_id),
      effect_kind: Keyword.get(options, :effect_kind, "code"),
      files: nil
    }

    params =
      Enum.reduce(
        [:delivery_owner_ref, :delivery_owner_session_key, :delegates_delivery],
        params,
        fn key, acc ->
          if Keyword.has_key?(options, key),
            do: Map.put(acc, key, Keyword.fetch!(options, key)),
            else: acc
        end
      )

    Assignments.__handle__(db, verb, %{
      verb: verb,
      origin: origin(principal),
      principal: principal,
      session_key: target,
      target_role: nil,
      role_fallback: false,
      supervision_interval_ms: 1_000,
      params: Map.put(params, :brief, "Do the exact-item work.")
    })
  end

  defp production_call(verb, principal, target, work_item_id) do
    %{
      verb: verb,
      origin: origin(principal),
      principal: principal,
      session_key: target,
      target_role: nil,
      role_fallback: false,
      supervision_interval_ms: 1_000,
      params: %{
        subject: "production #{System.unique_integer([:positive])}",
        brief: "Do the exact-item work.",
        idempotency_key: nil,
        work_item_id: work_item_id,
        reviews_assignment_id: nil,
        effect_kind: "code",
        files: nil
      }
    }
  end

  defp assignment_handlers(db) do
    %{
      "assign" => fn call -> Assignments.__handle__(db, "assign", call) end,
      "dispatch" => fn call -> Assignments.__handle__(db, "dispatch", call) end
    }
  end

  defp attest_verdict(db, holder, assignment_id, verdict_kind) do
    Assignments.__handle__(db, "attest", %{
      verb: "attest",
      origin: "agent:" <> holder,
      principal: {:session, holder},
      session_key: nil,
      params: %{
        assignment_id: assignment_id,
        kind: "verdict",
        verdict_kind: verdict_kind
      }
    })
  end

  defp close_assignment(db, assignment_id, opener) do
    Assignments.__handle__(db, "revoke-assignment", %{
      verb: "revoke-assignment",
      origin: "agent:" <> opener,
      principal: {:session, opener},
      session_key: nil,
      params: %{assignment_id: assignment_id, reason: "withdraw exact-item lane"}
    })
  end

  defp load_delivery_rules!(tmp) do
    rules_dir = Path.join([tmp, "identity", "rules"])
    File.mkdir_p!(rules_dir)

    File.cp!(
      Path.expand("../priv/kungfu/agentic-engineering/rules/delivery.toml", __DIR__),
      Path.join(rules_dir, "delivery.toml")
    )

    Rules.load!(tmp, ["spawn", "assign", "dispatch"])
  end

  defp work_item_call(principal, work_item_id) do
    %{
      verb: "work-item-get",
      origin: origin(principal),
      principal: principal,
      session_key: nil,
      params: %{work_item_id: work_item_id}
    }
  end

  defp count(db, table) do
    {:ok, [[count]]} = DB.query(db, "SELECT COUNT(*) FROM #{table}")
    count
  end

  defp associate(db, principal, session_key, po_role, key) do
    SessionPoAssociations.handle(db, %{
      principal: principal,
      params: %{
        session_key: session_key,
        po_role: po_role,
        idempotency_key: key
      }
    })
  end

  defp origin({:user, user_id}), do: "user:" <> user_id
  defp origin({:session, session_key}), do: "agent:" <> session_key

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

    id
  end
end
