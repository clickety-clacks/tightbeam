defmodule Tightbeam.DeliverableContractTest do
  use Tightbeam.TestCase, async: false

  alias Tightbeam.{Artifacts, Assignments, DB, DeliverableContract, Model, Org, WorkItems}

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

  test "a stamped v10 database refuses every wholly absent contract object" do
    objects = [
      {:table, "deliverables"},
      {:table, "work_item_deliverables"},
      {:table, "assignment_deliverables"},
      {:index, "assignment_own_deliverable"},
      {:table, "assignment_product_lineage_captures"},
      {:table, "assignment_product_owner_ancestry"},
      {:table, "completion_claims"},
      {:table, "work_item_closures"},
      {:table, "deliverable_contract_idempotency"}
    ]

    Enum.each(objects, fn {type, object} ->
      db = :"missing_contract_object_#{object}_#{System.unique_integer([:positive])}"

      start_supervised!(%{
        id: db,
        start: {DB, :start_link, [[path: ":memory:", name: db]]}
      })

      :ok = Tightbeam.Schema.ensure_all(db)
      :ok = DB.execute(db, "DROP #{String.upcase(to_string(type))} #{object}")

      assert_raise DeliverableContract.Inconsistent,
                   ~r/missing contract object #{object}/,
                   fn -> DeliverableContract.ensure_schema(db) end
    end)
  end

  test "boot refuses ancestry that promotes an ordinary ancestor to product owner", ctx do
    main = Org.personal_session_key("flynn")
    session(ctx.db, "ordinary-ancestor", "flynn", %{spawned_by: main})
    session(ctx.db, "ordinary-child", "flynn", %{spawned_by: "ordinary-ancestor"})

    card = create_card(ctx, "Ordinary ancestry must not confer authority")
    assignment = assign_to(ctx, card.id, "Subordinate result", false, "ordinary-child")

    assert {:ok, _} =
             DB.query(
               ctx.db,
               "INSERT INTO assignment_product_owner_ancestry (assignmentId,productOwnerSessionKey,distance) VALUES (?1,'ordinary-ancestor',1)",
               [assignment.id]
             )

    assert_raise DeliverableContract.Inconsistent,
                 ~r/assignment_product_owner_ancestry #{assignment.id}/,
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

  test "a real spec artifact cannot change a subordinate deliverable into the card", ctx do
    card = create_card(ctx, "Implement the product and remove the legacy path")
    assignment = assign(ctx, card.id, "Write the product specification", false)

    artifact =
      Artifacts.record(ctx.db, %{
        principal: {:session, "holder"},
        session_key: "holder",
        params: %{
          kind: "spec",
          title: "Reviewed product specification",
          description: "The partial deliverable",
          origin_path: "spec/product.md",
          content_sha256: String.duplicate("a", 64),
          work_item_id: card.id
        }
      })

    assert %{
             artifact_id: "art_" <> _,
             kind: "spec",
             title: "Reviewed product specification",
             work_item_id: card_id,
             created_by_session: "holder"
           } = artifact

    assert card_id == card.id

    completion = complete(ctx, assignment.id, "The specification artifact is complete")
    assert Enum.map(completion.referents, & &1.artifactId) == [artifact.artifact_id]
    assert completion.attest.deliverableClaim.id == assignment.deliverable.id

    assert %{code: "completion_deliverable_mismatch"} =
             close(ctx, {:user, "flynn"}, card.id, completion.attest.id)

    assert %{workItem: %{state: "open", closure: nil}} =
             WorkItems.__handle__(
               ctx.db,
               "work-item-get",
               call("work-item-get", {:user, "flynn"}, nil, %{work_item_id: card.id})
             )
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

  test "completion write failures roll back every authoritative row and marker failures do not",
       ctx do
    card = create_card(ctx, "Atomic completion write matrix")
    assignment = assign(ctx, card.id, "Atomic implementation", true)

    probes = [
      {"completion_attest", "BEFORE INSERT ON attests WHEN NEW.kind='completion'"},
      {"completion_claim", "BEFORE INSERT ON completion_claims"},
      {"assignment_close", "BEFORE UPDATE ON assignments WHEN NEW.outcome='completed'"},
      {"slate_wake", "BEFORE INSERT ON wakes WHEN NEW.prompt LIKE 'slate clear on %'"},
      {"supervision_transition", "BEFORE DELETE ON supervision_entitlements"},
      {"completion_receipt",
       "BEFORE INSERT ON deliverable_contract_idempotency WHEN NEW.operation='attest-completion'"}
    ]

    Enum.each(probes, fn {name, event} ->
      trigger = "completion_probe_#{name}"
      before = completion_snapshot(ctx.db, assignment.id, card.id)

      :ok =
        DB.execute(
          ctx.db,
          "CREATE TRIGGER #{trigger} #{event} BEGIN SELECT RAISE(ABORT, '#{name}'); END"
        )

      assert_raise Tightbeam.DB.Error, ~r/#{name}/, fn ->
        complete(ctx, assignment.id, "complete atomically", "completion-key")
      end

      assert completion_snapshot(ctx.db, assignment.id, card.id) == before
      :ok = DB.execute(ctx.db, "DROP TRIGGER #{trigger}")
    end)

    :ok = DB.execute(ctx.db, "DROP TABLE messages")

    committed = complete(ctx, assignment.id, "complete atomically", "completion-key")
    replay = complete(ctx, assignment.id, "complete atomically", "completion-key")

    assert committed.attest.id == replay.attest.id
    assert committed.assignment.state == "closed"

    assert {:ok, [[1, 1, 1]]} =
             DB.query(
               ctx.db,
               "SELECT (SELECT count(*) FROM attests WHERE assignmentId=?1 AND kind='completion'),(SELECT count(*) FROM completion_claims WHERE assignmentId=?1),(SELECT count(*) FROM deliverable_contract_idempotency WHERE completionAttestId=?2)",
               [assignment.id, committed.attest.id]
             )
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

  test "owner-narrowing close write failures preserve the open card byte for byte", ctx do
    card = create_card(ctx, "Narrowing transaction")
    assignment = assign(ctx, card.id, "Reviewed subordinate result", false)
    completion = complete(ctx, assignment.id, nil)
    reason = "The card product owner accepts this narrower result"

    probes = [
      {"card_state", "BEFORE UPDATE ON work_items WHEN NEW.state='closed'"},
      {"closure_row", "BEFORE INSERT ON work_item_closures"},
      {"close_receipt",
       "BEFORE INSERT ON deliverable_contract_idempotency WHEN NEW.operation='work-item-close'"}
    ]

    Enum.each(probes, fn {name, event} ->
      trigger = "close_probe_#{name}"
      before = close_snapshot(ctx.db, card.id)

      :ok =
        DB.execute(
          ctx.db,
          "CREATE TRIGGER #{trigger} #{event} BEGIN SELECT RAISE(ABORT, '#{name}'); END"
        )

      assert_raise Tightbeam.DB.Error, ~r/#{name}/, fn ->
        close(
          ctx,
          {:session, "product-owner"},
          card.id,
          completion.attest.id,
          reason,
          "close-key"
        )
      end

      assert close_snapshot(ctx.db, card.id) == before
      :ok = DB.execute(ctx.db, "DROP TRIGGER #{trigger}")
    end)

    assert %{ok: true, workItem: %{state: "closed", closure: %{basis: "owner_narrowing"}}} =
             close(
               ctx,
               {:session, "product-owner"},
               card.id,
               completion.attest.id,
               reason,
               "close-key"
             )
  end

  test "real completion, revocation, and competing close races preserve one history", ctx do
    terminal_card = create_card(ctx, "One terminal assignment outcome")
    terminal_assignment = assign(ctx, terminal_card.id, "Whole result", true)

    racers = [
      Task.async(fn -> complete(ctx, terminal_assignment.id, "race completion") end),
      Task.async(fn -> revoke(ctx, {:user, "flynn"}, terminal_assignment.id) end)
    ]

    terminal_results = Task.await_many(racers)
    assert Enum.count(terminal_results, &(&1[:code] == "assignment_closed")) == 1

    assert {:ok, [[completion_count, claim_count]]} =
             completion_counts(ctx.db, terminal_assignment.id)

    assert completion_count == claim_count
    assert completion_count in [0, 1]

    close_card = create_card(ctx, "Exactly one card closure")
    first = assign(ctx, close_card.id, "First whole-card result", true)
    second = assign(ctx, close_card.id, "Second whole-card result", true)
    first_completion = complete(ctx, first.id, nil)
    second_completion = complete(ctx, second.id, nil)

    close_results =
      [first_completion.attest.id, second_completion.attest.id]
      |> Enum.map(fn attest_id ->
        Task.async(fn -> close(ctx, {:user, "flynn"}, close_card.id, attest_id) end)
      end)
      |> Task.await_many()

    assert Enum.count(close_results, &match?(%{ok: true}, &1)) == 1
    assert Enum.count(close_results, &match?(%{code: "work_item_closed"}, &1)) == 1

    assert {:ok, [[1]]} =
             DB.query(ctx.db, "SELECT count(*) FROM work_item_closures WHERE workItemId=?1", [
               close_card.id
             ])
  end

  test "completion and narrowing race has one serialized legal order", ctx do
    card = create_card(ctx, "Race whole work against an explicit narrowing")
    partial = assign(ctx, card.id, "Partial result", false)
    partial_completion = complete(ctx, partial.id, nil)
    whole = assign(ctx, card.id, "Whole result", true)
    reason = "Accept the reviewed partial result"

    completion_task = Task.async(fn -> complete(ctx, whole.id, nil) end)

    close_task =
      Task.async(fn ->
        close(
          ctx,
          {:session, "product-owner"},
          card.id,
          partial_completion.attest.id,
          reason
        )
      end)

    [whole_completion, close_result] = Task.await_many([completion_task, close_task])
    assert whole_completion.assignment.state == "closed"

    final_close =
      case close_result do
        %{ok: true} = closed ->
          closed

        %{code: "assignments_open"} ->
          close(
            ctx,
            {:session, "product-owner"},
            card.id,
            partial_completion.attest.id,
            reason
          )
      end

    assert %{ok: true, workItem: %{state: "closed"}} = final_close

    assert {:ok, [[1]]} =
             DB.query(ctx.db, "SELECT count(*) FROM work_item_closures WHERE workItemId=?1", [
               card.id
             ])
  end

  test "captured wi_113442f5 rows and real artifact cannot recur without explicit ruling", ctx do
    fixture = %{
      work_item_id: "wi_113442f5-22ae-457b-a971-1b620069d490",
      title: "REST read plane D3 — CLI direct-GET migration and legacy read removal",
      assignment_id: "asg_29aeed02-f3bc-421a-99ca-c2bce6f80ec0",
      subject:
        "SPEC D3 — author the CLI direct-REST read migration and legacy-read removal build specification.",
      completion_attest_id: "att_1ab4c74f-d4a3-4af2-8c61-c467062367e4",
      note:
        "Completed D3 spec authoring and push only. Exact successor commit 85ae5ecb126d54cf7759b4ce37d9459fd7bd0f0f, artifact art_b6dbcd51, file SHA-256 3f097d9e18ab51cfc24f39599113baad98a562a736a28e88c8aebd7a68f1942f.",
      commit_ref: %{
        repo: "testhost:/home/mike/.tightbeam/work/b5b78731256f/completion-contract-specs",
        commit: "85ae5ecb126d54cf7759b4ce37d9459fd7bd0f0f"
      }
    }

    assert fixture.work_item_id == "wi_113442f5-22ae-457b-a971-1b620069d490"
    assert fixture.assignment_id == "asg_29aeed02-f3bc-421a-99ca-c2bce6f80ec0"
    assert fixture.completion_attest_id == "att_1ab4c74f-d4a3-4af2-8c61-c467062367e4"

    register_hosts(ctx.db, %{
      "testhost" => %{ssh: nil, base_dir: System.tmp_dir!(), cli_bin: nil}
    })

    card =
      create_card(ctx, fixture.title)

    assignment =
      assign(
        ctx,
        card.id,
        fixture.subject,
        false
      )

    artifact =
      Artifacts.record(ctx.db, %{
        principal: {:session, "holder"},
        session_key: "holder",
        params: %{
          kind: "spec",
          title: "D3 CLI direct-REST migration specification",
          origin_path: "cli-direct-rest-read-migration-v1.md",
          content_sha256: "3f097d9e18ab51cfc24f39599113baad98a562a736a28e88c8aebd7a68f1942f",
          work_item_id: card.id
        }
      })

    assert %{artifact_id: "art_" <> _, kind: "spec", work_item_id: card_id} = artifact
    assert card_id == card.id

    completion =
      complete_with_refs(ctx, assignment.id, fixture.note, [fixture.commit_ref])

    assert completion.attest.commitRefs == [
             %{"repo" => fixture.commit_ref.repo, "commit" => fixture.commit_ref.commit}
           ]

    assert completion.attest.note == fixture.note
    assert completion.attest.deliverableClaim.name == fixture.subject

    assert %{code: "completion_deliverable_mismatch"} =
             close(ctx, {:user, "flynn"}, card.id, completion.attest.id)

    assert %{workItem: %{state: "open", closure: nil}} =
             WorkItems.__handle__(
               ctx.db,
               "work-item-get",
               call("work-item-get", {:user, "flynn"}, nil, %{work_item_id: card.id})
             )
  end

  test "upgrade preserves historical domain bytes and creates no historical claims", ctx do
    closed_card = create_card(ctx, "Historical closed card")
    closed_assignment = assign(ctx, closed_card.id, "Historical whole result", true)
    closed_completion = complete(ctx, closed_assignment.id, "historical completion")
    assert %{ok: true} = close(ctx, {:user, "flynn"}, closed_card.id, closed_completion.attest.id)

    failed_card = create_card(ctx, "Historical failed card")

    assert %{ok: true} =
             WorkItems.__handle__(
               ctx.db,
               "work-item-fail",
               call("work-item-fail", {:user, "flynn"}, nil, %{
                 work_item_id: failed_card.id,
                 reason: "historical failure"
               })
             )

    active_card = create_card(ctx, "Historical assignment states")
    surrendered = assign(ctx, active_card.id, "Historical surrender", false)

    assert %{assignment: %{outcome: "surrendered"}} =
             Assignments.__handle__(
               ctx.db,
               "attest",
               call("attest", {:session, "holder"}, nil, %{
                 assignment_id: surrendered.id,
                 kind: "surrender"
               })
             )

    revoked = assign(ctx, active_card.id, "Historical revocation", false)
    assert %{outcome: "revoked"} = revoke(ctx, {:user, "flynn"}, revoked.id)

    reopened = assign(ctx, active_card.id, "Historical reopened completion", false)
    old_completion = complete(ctx, reopened.id, "old completion")

    assert %{state: "open"} =
             Assignments.__handle__(
               ctx.db,
               "reopen-assignment",
               call("reopen-assignment", {:user, "flynn"}, nil, %{
                 assignment_id: reopened.id,
                 reason: "continue after activation"
               })
               |> Map.put(:supervision_interval_ms, 1_000)
             )

    before = historical_snapshot(ctx.db)
    strip_contract_to_v9!(ctx.db)

    assert :ok =
             DeliverableContract.upgrade_v1(
               ctx.db,
               "coordination-fabric-v1-phase1-v9",
               "coordination-fabric-v1-phase1-v10"
             )

    assert historical_snapshot(ctx.db) == before
    assert {:ok, [[0]]} = DB.query(ctx.db, "SELECT count(*) FROM completion_claims")
    assert {:ok, [[0]]} = DB.query(ctx.db, "SELECT count(*) FROM work_item_closures")

    assert %{deliverableClaim: nil} =
             Assignments.list_attests(ctx.db, reopened.id)
             |> Enum.find(&(&1.id == old_completion.attest.id))

    assert %{deliverableContract: "v1", deliverable: %{name: "Historical reopened completion"}} =
             DeliverableContract.assignment_projection(ctx.db, reopened.id)
  end

  test "keyed creation replay preserves original card and assignment bindings", ctx do
    first_card_call =
      call("work-item-create", {:user, "flynn"}, nil, %{
        title: "Original card title",
        idempotency_key: "card-create-key"
      })

    first_card = WorkItems.__handle__(ctx.db, "work-item-create", first_card_call)

    replayed_card =
      WorkItems.__handle__(
        ctx.db,
        "work-item-create",
        put_in(first_card_call, [:params, :title], "Changed valid title")
      )

    assert replayed_card == first_card

    other_card = create_card(ctx, "Different card")

    first_assignment_call =
      call("assign", {:user, "flynn"}, "holder", %{
        subject: "Original subordinate scope",
        work_item_id: first_card.id,
        idempotency_key: "assignment-create-key",
        delivers_work_item: false
      })
      |> Map.merge(%{target_role: nil, role_fallback: false, supervision_interval_ms: 1_000})

    first_assignment = Assignments.__handle__(ctx.db, "assign", first_assignment_call)

    replayed_assignment =
      first_assignment_call
      |> put_in([:params, :subject], "Changed valid scope")
      |> put_in([:params, :work_item_id], other_card.id)
      |> put_in([:params, :delivers_work_item], true)
      |> then(&Assignments.__handle__(ctx.db, "assign", &1))

    assert replayed_assignment.id == first_assignment.id
    assert replayed_assignment.workItemId == first_card.id
    assert replayed_assignment.deliverable == first_assignment.deliverable
    assert replayed_assignment.deliverable.sourceKind == "assignment"

    assert %{code: "invalid_delivers_work_item"} =
             first_assignment_call
             |> put_in([:params, :delivers_work_item], "true")
             |> then(&Assignments.__handle__(ctx.db, "assign", &1))

    assert {:ok, [[2, 2, 1, 1]]} =
             DB.query(
               ctx.db,
               "SELECT (SELECT count(*) FROM work_items WHERE id IN (?1,?2)),(SELECT count(*) FROM work_item_deliverables WHERE workItemId IN (?1,?2)),(SELECT count(*) FROM assignments WHERE id=?3),(SELECT count(*) FROM assignment_deliverables WHERE assignmentId=?3)",
               [first_card.id, other_card.id, first_assignment.id]
             )

    path =
      Path.join(
        System.tmp_dir!(),
        "deliverable-creation-replay-#{System.unique_integer([:positive])}.sqlite3"
      )

    first_db = :"creation_replay_first_#{System.unique_integer([:positive])}"
    start_supervised!({DB, path: path, name: first_db}, id: first_db)
    seed_creation_replay_world!(first_db)

    durable_card_call =
      call("work-item-create", {:user, "flynn"}, nil, %{
        title: "Durable original card",
        idempotency_key: "durable-card-create"
      })

    durable_card = WorkItems.__handle__(first_db, "work-item-create", durable_card_call)

    durable_assignment_call =
      call("assign", {:user, "flynn"}, "holder", %{
        subject: "Durable original assignment",
        work_item_id: durable_card.id,
        idempotency_key: "durable-assignment-create",
        delivers_work_item: true
      })
      |> Map.merge(%{target_role: nil, role_fallback: false, supervision_interval_ms: 1_000})

    durable_assignment = Assignments.__handle__(first_db, "assign", durable_assignment_call)
    stop_supervised!(first_db)

    restarted_db = :"creation_replay_restarted_#{System.unique_integer([:positive])}"
    start_supervised!({DB, path: path, name: restarted_db}, id: restarted_db)

    replayed_durable_card =
      WorkItems.__handle__(
        restarted_db,
        "work-item-create",
        put_in(durable_card_call, [:params, :title], "Changed after restart")
      )

    replayed_durable_assignment =
      durable_assignment_call
      |> put_in([:params, :subject], "Changed after restart")
      |> put_in([:params, :delivers_work_item], false)
      |> then(&Assignments.__handle__(restarted_db, "assign", &1))

    assert replayed_durable_card.id == durable_card.id
    assert replayed_durable_card.title == durable_card.title
    assert replayed_durable_card.deliverable == durable_card.deliverable
    assert replayed_durable_assignment.id == durable_assignment.id
    assert replayed_durable_assignment.deliverable == durable_assignment.deliverable

    assert {:ok, [[1, 1, 1, 1]]} =
             DB.query(
               restarted_db,
               "SELECT (SELECT count(*) FROM work_items WHERE id=?1),(SELECT count(*) FROM work_item_deliverables WHERE workItemId=?1),(SELECT count(*) FROM assignments WHERE id=?2),(SELECT count(*) FROM assignment_deliverables WHERE assignmentId=?2)",
               [durable_card.id, durable_assignment.id]
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

  defp complete_with_refs(ctx, assignment_id, note, refs) do
    Assignments.__handle__(
      ctx.db,
      "attest",
      call("attest", {:session, "holder"}, nil, %{
        assignment_id: assignment_id,
        kind: "completion",
        note: note,
        commit_refs: refs,
        idempotency_key: nil
      })
    )
  end

  defp revoke(ctx, principal, assignment_id) do
    Assignments.__handle__(
      ctx.db,
      "revoke-assignment",
      call("revoke-assignment", principal, nil, %{assignment_id: assignment_id})
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

  defp completion_snapshot(db, assignment_id, work_item_id) do
    %{
      assignment:
        rows!(
          db,
          "SELECT state,outcome,closedAt,closedByUser,closedBySession,closingAttestId FROM assignments WHERE id=?1",
          [assignment_id]
        ),
      attests:
        rows!(db, "SELECT * FROM attests WHERE assignmentId=?1 ORDER BY rowid", [assignment_id]),
      claims:
        rows!(db, "SELECT * FROM completion_claims WHERE assignmentId=?1 ORDER BY attestId", [
          assignment_id
        ]),
      receipts:
        rows!(
          db,
          "SELECT * FROM deliverable_contract_idempotency WHERE completionAttestId IN (SELECT attestId FROM completion_claims WHERE assignmentId=?1) ORDER BY actorKind,actorRef,operation,idempotencyKey",
          [assignment_id]
        ),
      supervision:
        rows!(db, "SELECT * FROM supervision_entitlements WHERE assignmentId=?1", [assignment_id]),
      work_item:
        rows!(db, "SELECT state,routingWakeId,slateWakeId FROM work_items WHERE id=?1", [
          work_item_id
        ]),
      wakes:
        rows!(db, "SELECT * FROM wakes WHERE work_item_id=?1 ORDER BY wakeId", [work_item_id])
    }
  end

  defp close_snapshot(db, work_item_id) do
    %{
      work_item:
        rows!(
          db,
          "SELECT state,failReason,routingWakeId,slateWakeId FROM work_items WHERE id=?1",
          [
            work_item_id
          ]
        ),
      closure: rows!(db, "SELECT * FROM work_item_closures WHERE workItemId=?1", [work_item_id]),
      receipts:
        rows!(
          db,
          "SELECT * FROM deliverable_contract_idempotency WHERE workItemId=?1 ORDER BY actorKind,actorRef,operation,idempotencyKey",
          [work_item_id]
        ),
      wakes:
        rows!(db, "SELECT * FROM wakes WHERE work_item_id=?1 ORDER BY wakeId", [work_item_id])
    }
  end

  defp historical_snapshot(db) do
    %{
      work_items: rows!(db, "SELECT * FROM work_items ORDER BY id"),
      assignments: rows!(db, "SELECT * FROM assignments ORDER BY id"),
      attests: rows!(db, "SELECT * FROM attests ORDER BY id")
    }
  end

  defp seed_creation_replay_world!(db) do
    :ok = Tightbeam.Schema.ensure_all(db)

    assert {:ok, _} =
             DB.query(
               db,
               "INSERT INTO users (userId,isAdmin,creationKind,createdAt) VALUES ('flynn',0,'admin_add',1)"
             )

    ensure_main_session(db, "flynn")
    session(db, "product-owner", "flynn", %{archetype: "product-owner"})
    session(db, "holder", "flynn", %{spawned_by: "product-owner"})
  end

  defp rows!(db, sql, params \\ []) do
    {:ok, rows} = DB.query(db, sql, params)
    rows
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
