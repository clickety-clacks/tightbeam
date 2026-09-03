defmodule Tightbeam.DeliverableContractTest do
  use Tightbeam.TestCase, async: false

  alias Tightbeam.{Assignments, DB, DeliverableContract, Model, Org, WorkItems}

  setup do
    db = :"deliverable_contract_#{System.unique_integer([:positive])}"
    start_supervised!({DB, path: ":memory:", name: db})
    :ok = Tightbeam.Schema.ensure_all(db)

    {:ok, _} =
      DB.query(
        db,
        "INSERT INTO users (userId,isAdmin,creationKind,createdAt) VALUES ('flynn',0,'admin_add',1),('other',0,'admin_add',1)"
      )

    Enum.each(~w(flynn other), &ensure_main_session(db, &1))
    session(db, "product-owner", "flynn", %{archetype: "product-owner"})
    session(db, "holder", "flynn", %{spawned_by: "product-owner"})
    session(db, "other-holder", "other")

    %{db: db}
  end

  test "TBCD1 bytes and all normative golden hashes are exact" do
    bytes =
      DeliverableContract.tbcd1([
        "completion-attest-card-deliverable-v1",
        "work_item",
        "wi_example"
      ])

    assert Base.encode16(bytes, case: :lower) ==
             "5442434431020000000000000003010000000000000025636f6d706c6574696f6e2d6174746573742d636172642d64656c6976657261626c652d7631010000000000000009776f726b5f6974656d01000000000000000a77695f6578616d706c65"

    assert DeliverableContract.fingerprint([
             "completion-attest-card-deliverable-v1",
             "work_item",
             "wi_example"
           ]) == "e913ecd5b5031094cd75c65f30690aa321c539fd2651ba9b8f0f0b054d204295"

    assert DeliverableContract.completion_fingerprint("asg_example", nil, []) ==
             "46cfdeffcfbd58706efd31e8c18c7e30e397b6a462009d17ece7c9a175bff524"

    assert DeliverableContract.close_fingerprint("wi_example", "att_example", "because") ==
             "1286084e2da28c5728aee9e31687131b32fba61b2a54101eb0f3556e72865e7a"

    refute DeliverableContract.fingerprint(nil) == DeliverableContract.fingerprint("")
    refute DeliverableContract.fingerprint(nil) == DeliverableContract.fingerprint([])
    refute DeliverableContract.fingerprint("e") == DeliverableContract.fingerprint("é")
  end

  test "a stamped v10 database refuses a missing contract object", ctx do
    :ok = DB.execute(ctx.db, "DROP TABLE deliverable_contract_idempotency")

    assert_raise DeliverableContract.Inconsistent,
                 ~r/missing contract object deliverable_contract_idempotency/,
                 fn -> DeliverableContract.ensure_schema(ctx.db) end
  end

  test "whole-card completion copies the immutable card identity and closes exactly", ctx do
    card = create_card(ctx, "Implement the whole outcome")
    original = card.deliverable

    updated =
      WorkItems.__handle__(
        ctx.db,
        "work-item-update",
        call("work-item-update", {:user, "flynn"}, nil, %{
          work_item_id: card.id,
          title: "Display title only"
        })
      )

    assert updated.title == "Display title only"
    assert updated.deliverable == original

    assignment = assign(ctx, card.id, "One implementation obligation", true)
    assert assignment.deliverable.id == original.id
    assert assignment.deliverable.sourceKind == "work_item"

    completion = complete(ctx, assignment.id, "completed the spec only")
    assert completion.attest.note == "completed the spec only"
    assert completion.attest.deliverableClaim.id == original.id

    assert %{code: "not_authorized"} =
             close(ctx, {:session, "other-holder"}, card.id, completion.attest.id)

    assert %{ok: true, workItem: closed} =
             close(ctx, {:session, "product-owner"}, card.id, completion.attest.id)

    assert closed.state == "closed"
    assert closed.closure.basis == "exact"
    assert closed.closure.cardDeliverable == original
    assert closed.closure.acceptedDeliverable == original
  end

  test "subordinate completion and partial prose cannot silently close the card", ctx do
    card = create_card(ctx, "Implement product and remove the legacy path")
    assignment = assign(ctx, card.id, "Write the specification only", false)
    completion = complete(ctx, assignment.id, "Delivered the whole card")

    refute completion.attest.deliverableClaim.id == card.deliverable.id
    assert completion.attest.deliverableClaim.name == "Write the specification only"

    assert %{code: "completion_deliverable_mismatch"} =
             close(ctx, {:user, "flynn"}, card.id, completion.attest.id)

    assert %{code: "owner_ruling_forbidden"} =
             close(ctx, {:user, "flynn"}, card.id, completion.attest.id, "Accept spec only")

    assert %{ok: true, workItem: closed} =
             close(
               ctx,
               {:session, "product-owner"},
               card.id,
               completion.attest.id,
               "Explicitly narrow this card to the reviewed specification"
             )

    assert closed.closure.basis == "owner_narrowing"
    assert closed.closure.ownerRulingProductOwnerSessionKey == "product-owner"
    assert closed.closure.closedBySession == "product-owner"
  end

  test "wrong holder and missing binding commit no completion rows", ctx do
    card = create_card(ctx, "Atomic completion")
    assignment = assign(ctx, card.id, "Atomic implementation", true)

    assert %{code: "not_holder"} =
             Assignments.__handle__(
               ctx.db,
               "attest",
               attest_call({:session, "other-holder"}, assignment.id, nil, nil)
             )

    assert {:ok, [[0, 0]]} = completion_counts(ctx.db, assignment.id)

    {:ok, _} =
      DB.query(ctx.db, "DELETE FROM assignment_deliverables WHERE assignmentId=?1", [
        assignment.id
      ])

    assert %{code: "assignment_deliverable_missing"} = complete(ctx, assignment.id, nil)
    assert {:ok, [[0, 0]]} = completion_counts(ctx.db, assignment.id)

    assert {:ok, [["open", nil]]} =
             DB.query(ctx.db, "SELECT state,closingAttestId FROM assignments WHERE id=?1", [
               assignment.id
             ])
  end

  test "keyed completion replays once and conflicts before a second completion", ctx do
    card = create_card(ctx, "Keyed exact completion")
    assignment = assign(ctx, card.id, "Keyed implementation", true)

    first = complete(ctx, assignment.id, "done", "completion-key")
    replay = complete(ctx, assignment.id, "done", "completion-key")

    assert replay.assignment == first.assignment
    assert replay.attest == first.attest

    assert %{code: "idempotency_conflict"} =
             complete(ctx, assignment.id, "different", "completion-key")

    assert %{code: "assignment_closed"} = complete(ctx, assignment.id, "done", "another-key")
    assert {:ok, [[1, 1]]} = completion_counts(ctx.db, assignment.id)
  end

  test "close selection preserves typed-id, same-card, open-slate, and ruling precedence", ctx do
    first_card = create_card(ctx, "First card")
    second_card = create_card(ctx, "Second card")
    first = assign(ctx, first_card.id, "First whole result", true)
    second = assign(ctx, second_card.id, "Second whole result", true)
    first_completion = complete(ctx, first.id, nil)
    second_completion = complete(ctx, second.id, nil)

    assert %{code: "completion_claim_wrong_card"} =
             close(ctx, {:user, "flynn"}, first_card.id, second_completion.attest.id)

    short_id = String.slice(first_completion.attest.id, 0, 16)

    assert %{ok: true, workItem: %{state: "closed"}} =
             close(ctx, {:user, "flynn"}, first_card.id, short_id)

    subordinate_card = create_card(ctx, "Slate ordering")
    subordinate = assign(ctx, subordinate_card.id, "One partial result", false)
    partial_completion = complete(ctx, subordinate.id, nil)
    _still_open = assign(ctx, subordinate_card.id, "Another open result", false)

    assert %{code: "assignments_open"} =
             close(ctx, {:user, "flynn"}, subordinate_card.id, partial_completion.attest.id)

    exact_reason_card = create_card(ctx, "Exact reason refusal")
    exact = assign(ctx, exact_reason_card.id, "Exact", true)
    exact_completion = complete(ctx, exact.id, nil)

    assert %{code: "owner_ruling_not_applicable"} =
             close(
               ctx,
               {:user, "flynn"},
               exact_reason_card.id,
               exact_completion.attest.id,
               "not applicable"
             )
  end

  test "ambiguous completion prefixes write nothing", ctx do
    card = create_card(ctx, "Ambiguous completion selection")
    assignment = assign(ctx, card.id, "Whole card", true)
    completion = complete(ctx, assignment.id, nil)

    {:ok, _} =
      DB.query(
        ctx.db,
        "INSERT INTO attests (id,assignmentId,kind,bySession,ts) VALUES ('att_collision_a',?1,'progress','holder',3),('att_collision_b',?1,'progress','holder',4)",
        [assignment.id]
      )

    assert %{code: "ambiguous_id", candidates: ["att_collision_a", "att_collision_b"]} =
             close(ctx, {:user, "flynn"}, card.id, "att_collision")

    assert %{ok: true, workItem: %{state: "closed"}} =
             close(ctx, {:user, "flynn"}, card.id, completion.attest.id)
  end

  test "owner narrowing uses frozen nearest common lineage and fails closed", ctx do
    session(ctx.db, "child-owner", "flynn", %{
      archetype: "product-owner",
      spawned_by: "product-owner"
    })

    session(ctx.db, "child-holder", "flynn", %{spawned_by: "child-owner"})
    session(ctx.db, "sibling-holder", "flynn", %{spawned_by: "product-owner"})

    card = create_card(ctx, "Common owner card")
    child = assign_to(ctx, card.id, "Child partial", false, "child-holder")
    sibling = assign_to(ctx, card.id, "Sibling partial", false, "sibling-holder")
    child_completion = complete_as(ctx, child.id, nil, nil, "child-holder")
    _sibling_completion = complete_as(ctx, sibling.id, nil, nil, "sibling-holder")

    assert %{code: "owner_ruling_forbidden"} =
             close(
               ctx,
               {:session, "child-owner"},
               card.id,
               child_completion.attest.id,
               "child decision"
             )

    {:ok, _} =
      DB.query(ctx.db, "UPDATE sessions SET archetype='default' WHERE sessionKey='product-owner'")

    assert %{ok: true, workItem: closed} =
             close(
               ctx,
               {:session, "product-owner"},
               card.id,
               child_completion.attest.id,
               "The common product owner accepts the narrower result"
             )

    assert closed.closure.ownerRulingProductOwnerSessionKey == "product-owner"

    unavailable_card = create_card(ctx, "Retired owner card")
    partial = assign(ctx, unavailable_card.id, "Partial", false)
    partial_completion = complete(ctx, partial.id, nil)

    {:ok, _} =
      DB.query(ctx.db, "UPDATE sessions SET state='retired' WHERE sessionKey='product-owner'")

    assert %{code: "product_owner_unavailable"} =
             close(
               ctx,
               {:user, "flynn"},
               unavailable_card.id,
               partial_completion.attest.id,
               "cannot transfer authority"
             )
  end

  test "reopen keeps the old claim stale and creates one new completion episode", ctx do
    card = create_card(ctx, "Reopen completion")
    assignment = assign(ctx, card.id, "Whole card", true)
    first = complete(ctx, assignment.id, "first")

    reopened =
      Assignments.__handle__(
        ctx.db,
        "reopen-assignment",
        call("reopen-assignment", {:user, "flynn"}, nil, %{
          assignment_id: assignment.id,
          reason: "the first episode needs repair"
        })
        |> Map.put(:supervision_interval_ms, 1_000)
      )

    assert reopened.state == "open"

    assert %{code: "completion_claim_stale"} =
             close(ctx, {:user, "flynn"}, card.id, first.attest.id)

    second = complete(ctx, assignment.id, "second")
    refute second.attest.id == first.attest.id

    assert %{ok: true, workItem: %{state: "closed"}} =
             close(ctx, {:user, "flynn"}, card.id, second.attest.id)

    assert {:ok, [[2, 2]]} = completion_counts(ctx.db, assignment.id)
  end

  test "close replay and scoped keys preserve one immutable closure", ctx do
    card = create_card(ctx, "Close retry")
    assignment = assign(ctx, card.id, "Whole card", true)
    completion = complete(ctx, assignment.id, nil)

    first = close(ctx, {:user, "flynn"}, card.id, completion.attest.id, nil, "close-key")
    replay = close(ctx, {:user, "flynn"}, card.id, completion.attest.id, nil, "other-key")

    assert replay.workItem.closure == first.workItem.closure

    assert %{code: "work_item_closed"} =
             close(ctx, {:user, "flynn"}, card.id, completion.attest.id, "changed")

    assert {:ok, [[1, 1]]} =
             DB.query(
               ctx.db,
               "SELECT (SELECT count(*) FROM work_item_closures WHERE workItemId=?1),(SELECT count(*) FROM deliverable_contract_idempotency WHERE operation='work-item-close' AND workItemId=?1)",
               [card.id]
             )
  end

  test "wi_113442f5 shape cannot recur without an explicit ruling", ctx do
    card =
      create_card(ctx, "REST read plane D3 — CLI direct-GET migration and legacy read removal")

    assignment =
      assign(
        ctx,
        card.id,
        "Author the REST read-plane D3 specification",
        false
      )

    completion = complete(ctx, assignment.id, "Completed D3 spec authoring and push only.")

    assert %{code: "completion_deliverable_mismatch"} =
             close(ctx, {:user, "flynn"}, card.id, completion.attest.id)

    assert %{workItem: %{state: "open", closure: nil}} =
             WorkItems.__handle__(
               ctx.db,
               "work-item-get",
               call("work-item-get", {:user, "flynn"}, nil, %{work_item_id: card.id})
             )
  end

  test "the exact v9-to-v10 upgrade is atomic, deterministic, and validates restart", ctx do
    card = create_card(ctx, "Migrated card")
    assignment = assign(ctx, card.id, "Migrated open assignment", false)
    strip_contract_to_v9!(ctx.db)

    for fault <- [
          :after_table_creation,
          :after_card_backfill,
          :after_assignment_backfill,
          :after_product_lineage_capture,
          :after_validation,
          :before_stamp_update
        ] do
      assert_raise DeliverableContract.Inconsistent, fn ->
        DeliverableContract.upgrade_v1(
          ctx.db,
          "coordination-fabric-v1-phase1-v9",
          "coordination-fabric-v1-phase1-v10",
          fail_at: fault
        )
      end

      assert {:ok, [["coordination-fabric-v1-phase1-v9"]]} =
               DB.query(ctx.db, "SELECT shape FROM schema_stamp")

      assert {:ok, []} =
               DB.query(
                 ctx.db,
                 "SELECT name FROM sqlite_master WHERE type='table' AND name='deliverables'"
               )
    end

    :ok = DB.execute(ctx.db, "CREATE TABLE deliverables (partial TEXT)")

    assert_raise DeliverableContract.Inconsistent, ~r/partial contract object deliverables/, fn ->
      DeliverableContract.upgrade_v1(
        ctx.db,
        "coordination-fabric-v1-phase1-v9",
        "coordination-fabric-v1-phase1-v10"
      )
    end

    assert {:ok, [["coordination-fabric-v1-phase1-v9"]]} =
             DB.query(ctx.db, "SELECT shape FROM schema_stamp")

    :ok = DB.execute(ctx.db, "DROP TABLE deliverables")

    assert :ok =
             DeliverableContract.upgrade_v1(
               ctx.db,
               "coordination-fabric-v1-phase1-v9",
               "coordination-fabric-v1-phase1-v10"
             )

    card_hash =
      DeliverableContract.fingerprint([
        "completion-attest-card-deliverable-v1",
        "work_item",
        card.id
      ])

    assignment_hash =
      DeliverableContract.fingerprint([
        "completion-attest-card-deliverable-v1",
        "assignment",
        assignment.id
      ])

    assert {:ok, [["dlv_" <> ^card_hash, "Migrated card"]]} =
             DB.query(
               ctx.db,
               "SELECT d.id,d.name FROM deliverables d JOIN work_item_deliverables w ON w.deliverableId=d.id WHERE w.workItemId=?1",
               [card.id]
             )

    assert {:ok, [["dlv_" <> ^assignment_hash, "Migrated open assignment"]]} =
             DB.query(
               ctx.db,
               "SELECT d.id,d.name FROM deliverables d JOIN assignment_deliverables a ON a.deliverableId=d.id WHERE a.assignmentId=?1",
               [assignment.id]
             )

    assert :ok = DeliverableContract.ensure_schema(ctx.db)

    {:ok, _} =
      DB.query(ctx.db, "UPDATE deliverables SET sha256=?2 WHERE id=?1", [
        "dlv_" <> card_hash,
        String.duplicate("0", 64)
      ])

    assert_raise DeliverableContract.Inconsistent, fn ->
      DeliverableContract.ensure_schema(ctx.db)
    end
  end

  defp create_card(ctx, title) do
    WorkItems.__handle__(
      ctx.db,
      "work-item-create",
      call("work-item-create", {:user, "flynn"}, nil, %{title: title})
    )
  end

  defp assign(ctx, work_item_id, subject, delivers_work_item),
    do: assign_to(ctx, work_item_id, subject, delivers_work_item, "holder")

  defp assign_to(ctx, work_item_id, subject, delivers_work_item, holder) do
    Assignments.__handle__(
      ctx.db,
      "assign",
      call("assign", {:user, "flynn"}, holder, %{
        subject: subject,
        work_item_id: work_item_id,
        delivers_work_item: delivers_work_item
      })
      |> Map.merge(%{target_role: nil, role_fallback: false, supervision_interval_ms: 1_000})
    )
  end

  defp complete(ctx, assignment_id, note, key \\ nil),
    do: complete_as(ctx, assignment_id, note, key, "holder")

  defp complete_as(ctx, assignment_id, note, key, holder) do
    Assignments.__handle__(
      ctx.db,
      "attest",
      attest_call({:session, holder}, assignment_id, note, key)
    )
  end

  defp attest_call(principal, assignment_id, note, key) do
    call("attest", principal, nil, %{
      assignment_id: assignment_id,
      kind: "completion",
      note: note,
      idempotency_key: key
    })
  end

  defp close(ctx, principal, work_item_id, attest_id, reason \\ nil, key \\ nil) do
    WorkItems.__handle__(
      ctx.db,
      "work-item-close",
      call("work-item-close", principal, nil, %{
        work_item_id: work_item_id,
        completion_attest_id: attest_id,
        owner_ruling_reason: reason,
        idempotency_key: key
      })
    )
  end

  defp completion_counts(db, assignment_id) do
    DB.query(
      db,
      """
      SELECT
        (SELECT count(*) FROM attests WHERE assignmentId=?1 AND kind='completion'),
        (SELECT count(*) FROM completion_claims WHERE assignmentId=?1)
      """,
      [assignment_id]
    )
  end

  defp strip_contract_to_v9!(db) do
    for table <- [
          "deliverable_contract_idempotency",
          "work_item_closures",
          "completion_claims",
          "assignment_product_owner_ancestry",
          "assignment_product_lineage_captures",
          "assignment_deliverables",
          "work_item_deliverables",
          "deliverables"
        ] do
      :ok = DB.execute(db, "DROP TABLE #{table}")
    end

    {:ok, _} =
      DB.query(
        db,
        "UPDATE schema_stamp SET shape='coordination-fabric-v1-phase1-v9'"
      )

    :ok
  end

  defp call(verb, principal, session_key, params) do
    %{
      verb: verb,
      origin: origin(principal),
      principal: principal,
      session_key: session_key,
      params: params
    }
  end

  defp origin({:session, key}), do: "agent:#{key}"
  defp origin({:user, key}), do: "user:#{key}"

  defp session(db, key, owner, overrides \\ %{}) do
    Org.create(
      db,
      Map.merge(
        %{
          session_key: key,
          display_name: key,
          owner_user_id: owner,
          origin: "user:#{owner}",
          archetype: "default",
          harness: "claude",
          provider: "anthropic",
          model: Model.new("fable"),
          host: "testhost"
        },
        overrides
      )
    )
  end
end
