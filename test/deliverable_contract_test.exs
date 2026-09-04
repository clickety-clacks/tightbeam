defmodule Tightbeam.DeliverableContractTest do
  use Tightbeam.TestCase, async: false

  alias Tightbeam.{Artifacts, Assignments, DB, DeliverableContract, Model, Org, Wakes, WorkItems}

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

  test "A5 source and integration target prove the installed completion producer set", ctx do
    archive =
      Path.join(__DIR__, "fixtures/deliverable_contract/phase1_v9_lib.tar.gz")
      |> File.read!()

    assert :sha256 |> :crypto.hash(archive) |> Base.encode16(case: :lower) ==
             "282fa3bb92c0eb6795a26722c14092ba3b4a4edbbdca80d26d7a3fb9faaacc64"

    assert {:ok, entries} = :erl_tar.extract({:binary, archive}, [:memory, :compressed])

    fixed_base_sources =
      Map.new(entries, fn {path, bytes} -> {List.to_string(path), bytes} end)

    # This archive is produced from the complete lib/ tree at exact base
    # 724e5c96f9513b37e937dc52eb014ba1ef2d1b5e (tree
    # 41da8ae7ddee96e01c42ac482052862fba7041e9). Inspecting every production
    # source file makes an empty optional-rail set an exact-source result, not
    # an inference from a test that happened not to configure one.
    exact_source =
      fixed_base_sources
      |> Enum.sort()
      |> Enum.map_join("\n", fn {path, bytes} -> path <> "\n" <> bytes end)

    refute exact_source =~ "CompletionEscalation"
    refute exact_source =~ "completion_escalation"

    assert fixed_base_sources
           |> Map.keys()
           |> Enum.filter(&String.starts_with?(&1, "lib/tightbeam/productions/"))
           |> Enum.sort() == [
             "lib/tightbeam/productions/bubble.ex",
             "lib/tightbeam/productions/bubble_sweeper.ex",
             "lib/tightbeam/productions/catalog_rederive.ex"
           ]

    assignments = Map.fetch!(fixed_base_sources, "lib/tightbeam/assignments.ex")
    work_items = Map.fetch!(fixed_base_sources, "lib/tightbeam/work_items.ex")
    supervision = Map.fetch!(fixed_base_sources, "lib/tightbeam/supervision.ex")
    effort = Map.fetch!(fixed_base_sources, "lib/tightbeam/effort_checkin.ex")
    schema = Map.fetch!(fixed_base_sources, "lib/tightbeam/schema.ex")

    contract =
      File.read!(Path.join([__DIR__, "..", "lib", "tightbeam", "deliverable_contract.ex"]))

    integrated_assignments =
      File.read!(Path.join([__DIR__, "..", "lib", "tightbeam", "assignments.ex"]))

    # Each entry records the real module/handler seam for the authoritative
    # writes exercised by the rollback matrices below. The first four contract
    # writes are added by this candidate. Every remaining producer is reached
    # by the fixed base's ordinary Assignments attest entry point.
    producer_seams = [
      {"completion_attest", "Tightbeam.Assignments.lifecycle_attest_in_txn/2"},
      {"completion_claim", "Tightbeam.DeliverableContract.record_completion_claim_in_txn/3"},
      {"assignment_close", "Tightbeam.Assignments.lifecycle_attest_in_txn/2"},
      {"completion_receipt", "Tightbeam.DeliverableContract.store_completion_receipt_in_txn/5"},
      {"completion_escalation", "CompletionEscalation.open_in_txn/3"},
      {"slate_wake", "Tightbeam.WorkItems.arm_slate_in_txn/2"},
      {"slate_pointer", "Tightbeam.WorkItems.arm_slate_in_txn/2"},
      {"supervision_transition", "Tightbeam.Supervision.transition_in_txn/2"},
      {"supervision_lifecycle", "Tightbeam.Supervision.transition_in_txn/2"},
      {"effort_wake_cancel", "Tightbeam.EffortCheckin.cancel_in_txn/3"},
      {"effort_cancellation_receipt", "Tightbeam.EffortCheckin.cancel_in_txn/3"},
      {"effort_generation_cancel", "Tightbeam.EffortCheckin.cancel_in_txn/3"},
      {"effort_request_supersede", "Tightbeam.EffortCheckin.cancel_in_txn/3"},
      {"effort_deadline_wake_cancel", "Tightbeam.EffortCheckin.cancel_in_txn/3"},
      {"effort_deadline_cancellation_receipt", "Tightbeam.EffortCheckin.cancel_in_txn/3"}
    ]

    assert Enum.map(producer_seams, &elem(&1, 0)) == [
             "completion_attest",
             "completion_claim",
             "assignment_close",
             "completion_receipt",
             "completion_escalation",
             "slate_wake",
             "slate_pointer",
             "supervision_transition",
             "supervision_lifecycle",
             "effort_wake_cancel",
             "effort_cancellation_receipt",
             "effort_generation_cancel",
             "effort_request_supersede",
             "effort_deadline_wake_cancel",
             "effort_deadline_cancellation_receipt"
           ]

    assert assignments =~ "defp lifecycle_attest_in_txn(txn, call)"
    assert assignments =~ "attest = insert_attest(txn, call, assignment_id)"
    assert assignments =~ "UPDATE assignments SET state = 'closed'"

    assert assignments =~
             "Tightbeam.WorkItems.arm_slate_in_txn(txn, closed_assignment.workItemId)"

    assert assignments =~ "supervision_transition!(txn, :terminal_disposition"
    assert assignments =~ "EffortCheckin.cancel_in_txn("
    assert work_items =~ "def arm_slate_in_txn(%Txn{} = txn, work_item_id)"
    assert work_items =~ "wake =\n            Wakes.schedule_in_txn"
    assert work_items =~ "UPDATE work_items SET slateWakeId = ?2"
    assert supervision =~ "def transition_in_txn(%Txn{} = txn"
    assert effort =~ "def cancel_in_txn(%Txn{} = txn, assignment_id, command)"
    assert effort =~ "UPDATE effort_checkin_generations SET state = 'canceled'"
    assert effort =~ "dispose_requests_in_txn(txn, assignment_id, command)"
    assert schema =~ ~s(@shape "coordination-fabric-v1-phase1-v9")
    assert contract =~ "def record_completion_claim_in_txn(txn, assignment_id, attest)"

    assert contract =~
             "def store_completion_receipt_in_txn(txn, principal, key, fingerprint, response)"

    assert integrated_assignments =~
             ~s|CompletionEscalation.open_terminal_in_txn(txn, closed_assignment, "attest", attest)|

    # The integration target installs the reviewed completion-escalation rail.
    # Its own rollback matrix exercises the real producer in the same completion
    # transaction as the deliverable claim.
    assert rows!(
             ctx.db,
             "SELECT name FROM sqlite_master WHERE type='table' AND name IN ('completion_escalations','completion_escalation_wakes') ORDER BY name"
           ) == [["completion_escalation_wakes"], ["completion_escalations"]]

    assert Enum.any?(rows!(ctx.db, "PRAGMA table_info(assignments)"), fn row ->
             Enum.at(row, 1) == "completionReportToSessionKey"
           end)
  end

  test "boot refuses captured product-owner ancestry outside the frozen spawn chain", ctx do
    main = Org.personal_session_key("flynn")
    session(ctx.db, "ordinary-ancestor", "flynn", %{spawned_by: main})
    session(ctx.db, "ordinary-child", "flynn", %{spawned_by: "ordinary-ancestor"})

    card = create_card(ctx, "Ordinary ancestry must not confer authority")
    assignment = assign_to(ctx, card.id, "Subordinate result", false, "ordinary-child")

    assert {:ok, _} =
             DB.query(
               ctx.db,
               "INSERT INTO assignment_product_owner_ancestry (assignmentId,productOwnerSessionKey,distance) VALUES (?1,'other-holder',1)",
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
      {"slate_pointer", "BEFORE UPDATE ON work_items WHEN NEW.slateWakeId IS NOT NULL"},
      {"supervision_transition", "BEFORE DELETE ON supervision_entitlements"},
      {"supervision_lifecycle",
       "BEFORE INSERT ON lifecycle_events WHEN NEW.kind='supervision_entitlement_cleared'"},
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

  test "dispatched completion rolls back every effort cancellation write", ctx do
    register_hosts(ctx.db, %{
      "testhost" => %{ssh: nil, base_dir: System.tmp_dir!(), cli_bin: nil}
    })

    card = create_card(ctx, "Atomic dispatched completion")
    assignment = dispatch_to(ctx, card.id, "Dispatched whole-card work", true, "holder")

    assert {:ok, [[effort_wake_id]]} =
             DB.query(
               ctx.db,
               "SELECT wakeId FROM effort_checkin_generations WHERE assignmentId=?1 AND state='armed'",
               [assignment.id]
             )

    request_id = open_effort_request!(ctx.db, assignment.id, "product-owner")

    assert [[deadline_wake_id]] =
             rows!(ctx.db, "SELECT deadlineWakeId FROM decision_requests WHERE id=?1", [
               request_id
             ])

    probes = [
      {"effort_wake_cancel",
       "BEFORE UPDATE ON wakes WHEN OLD.wakeId='#{effort_wake_id}' AND NEW.state='canceled'"},
      {"effort_cancellation_receipt",
       "BEFORE INSERT ON wake_cancellations WHEN NEW.wakeId='#{effort_wake_id}'"},
      {"effort_generation_cancel",
       "BEFORE UPDATE ON effort_checkin_generations WHEN NEW.state='canceled'"},
      {"effort_request_supersede",
       "BEFORE UPDATE ON decision_requests WHEN OLD.id='#{request_id}' AND NEW.status='superseded'"},
      {"effort_deadline_wake_cancel",
       "BEFORE UPDATE ON wakes WHEN OLD.wakeId='#{deadline_wake_id}' AND NEW.state='canceled'"},
      {"effort_deadline_cancellation_receipt",
       "BEFORE INSERT ON wake_cancellations WHEN NEW.wakeId='#{deadline_wake_id}'"}
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
        complete(ctx, assignment.id, "complete dispatched work", "dispatch-completion-key")
      end

      assert completion_snapshot(ctx.db, assignment.id, card.id) == before
      :ok = DB.execute(ctx.db, "DROP TRIGGER #{trigger}")
    end)

    assert %{assignment: %{state: "closed"}} =
             complete(ctx, assignment.id, "complete dispatched work", "dispatch-completion-key")

    assert [["superseded"]] =
             rows!(ctx.db, "SELECT status FROM decision_requests WHERE id=?1", [request_id])

    assert [["canceled"]] =
             rows!(ctx.db, "SELECT state FROM wakes WHERE wakeId=?1", [deadline_wake_id])
  end

  test "parent-unavailable completion rollback creates no excluded route", ctx do
    register_hosts(ctx.db, %{
      "testhost" => %{ssh: nil, base_dir: System.tmp_dir!(), cli_bin: nil}
    })

    session(ctx.db, "retired-parent", "flynn", %{spawned_by: "product-owner"})
    Org.set_operational_parent(ctx.db, "holder", "retired-parent")

    :ok =
      DB.execute(ctx.db, "UPDATE sessions SET state='retired' WHERE sessionKey='retired-parent'")

    card = create_card(ctx, "Parent unavailable completion")

    assignment =
      dispatch_to(ctx, card.id, "Complete without a live direct parent", true, "holder")

    request_id = open_effort_request!(ctx.db, assignment.id, "product-owner")

    for {name, event} <- [
          {"parent_unavailable_request",
           "BEFORE UPDATE ON decision_requests WHEN OLD.id='#{request_id}' AND NEW.status='superseded'"},
          {"parent_unavailable_lifecycle",
           "BEFORE INSERT ON lifecycle_events WHEN NEW.kind='supervision_entitlement_cleared'"}
        ] do
      before = completion_snapshot(ctx.db, assignment.id, card.id)
      trigger = "completion_probe_#{name}"

      :ok =
        DB.execute(
          ctx.db,
          "CREATE TRIGGER #{trigger} #{event} BEGIN SELECT RAISE(ABORT, '#{name}'); END"
        )

      assert_raise Tightbeam.DB.Error, ~r/#{name}/, fn ->
        complete(ctx, assignment.id, "complete with retired direct parent", name)
      end

      assert completion_snapshot(ctx.db, assignment.id, card.id) == before
      :ok = DB.execute(ctx.db, "DROP TRIGGER #{trigger}")
    end

    assert [] ==
             rows!(
               ctx.db,
               "SELECT wakeId FROM wakes WHERE assignmentId=?1 AND consumer NOT IN ('effort_probe','effort_deadline') ORDER BY wakeId",
               [assignment.id]
             )
  end

  test "each post-commit completion marker may fail without changing authoritative reads", ctx do
    for {name, predicate} <- [
          {"completion_marker", "NEW.content LIKE '[completion filed on %'"},
          {"assignment_marker", "NEW.content LIKE '[assignment closed: %'"}
        ] do
      card = create_card(ctx, "Marker callback #{name}")
      assignment = assign(ctx, card.id, "Marker callback whole work #{name}", true)
      trigger = "completion_callback_#{name}"

      :ok =
        DB.execute(
          ctx.db,
          "CREATE TRIGGER #{trigger} BEFORE INSERT ON messages WHEN #{predicate} BEGIN SELECT RAISE(ABORT, '#{name}'); END"
        )

      committed = complete(ctx, assignment.id, "marker failure is non-authoritative", name)
      replay = complete(ctx, assignment.id, "marker failure is non-authoritative", name)

      assert committed.attest.id == replay.attest.id
      assert committed.assignment.state == "closed"
      assert {:ok, [[1, 1]]} = completion_counts(ctx.db, assignment.id)

      assert %{state: "closed", closingAttestId: closing_id} =
               Assignments.list(ctx.db, %{state: "all"})
               |> Enum.find(&(&1.id == assignment.id))

      assert closing_id == committed.attest.id
      :ok = DB.execute(ctx.db, "DROP TRIGGER #{trigger}")
    end
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

    assert :ok = DeliverableContract.ensure_schema(ctx.db)

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

  test "legacy terminal reopen reuses activation lineage and captures it only when missing",
       ctx do
    card = create_card(ctx, "Legacy terminal reopen lineage")
    captured = assign(ctx, card.id, "Captured during activation", false)
    missing = assign(ctx, card.id, "Missing during activation", false)

    _ = complete(ctx, captured.id, "terminal before activation")
    _ = complete(ctx, missing.id, "terminal before activation")

    strip_contract_to_v9!(ctx.db)

    assert :ok =
             DeliverableContract.upgrade_v1(
               ctx.db,
               "coordination-fabric-v1-phase1-v9",
               "coordination-fabric-v1-phase1-v10"
             )

    captured_lineage =
      rows!(
        ctx.db,
        "SELECT assignmentId,workItemId,holderSessionKey,captureKind FROM assignment_product_lineage_captures WHERE assignmentId=?1",
        [captured.id]
      )

    captured_ancestry =
      rows!(
        ctx.db,
        "SELECT productOwnerSessionKey,distance FROM assignment_product_owner_ancestry WHERE assignmentId=?1 ORDER BY distance",
        [captured.id]
      )

    assert captured_lineage == [[captured.id, card.id, "holder", "activation"]]
    assert captured_ancestry != []

    assert {:ok, _} =
             DB.query(
               ctx.db,
               "DELETE FROM assignment_product_owner_ancestry WHERE assignmentId=?1",
               [missing.id]
             )

    assert {:ok, _} =
             DB.query(
               ctx.db,
               "DELETE FROM assignment_product_lineage_captures WHERE assignmentId=?1",
               [missing.id]
             )

    reopen = fn assignment, reason ->
      Assignments.__handle__(
        ctx.db,
        "reopen-assignment",
        call("reopen-assignment", {:user, "flynn"}, nil, %{
          assignment_id: assignment.id,
          reason: reason
        })
        |> Map.put(:supervision_interval_ms, 1_000)
      )
    end

    assert %{state: "open"} = reopen.(captured, "reuse the activation lineage")

    assert captured_lineage ==
             rows!(
               ctx.db,
               "SELECT assignmentId,workItemId,holderSessionKey,captureKind FROM assignment_product_lineage_captures WHERE assignmentId=?1",
               [captured.id]
             )

    assert captured_ancestry ==
             rows!(
               ctx.db,
               "SELECT productOwnerSessionKey,distance FROM assignment_product_owner_ancestry WHERE assignmentId=?1 ORDER BY distance",
               [captured.id]
             )

    assert %{state: "open"} = reopen.(missing, "replace the absent activation lineage")

    assert [[missing.id, card.id, "holder", "assignment_open"]] ==
             rows!(
               ctx.db,
               "SELECT assignmentId,workItemId,holderSessionKey,captureKind FROM assignment_product_lineage_captures WHERE assignmentId=?1",
               [missing.id]
             )

    assert rows!(
             ctx.db,
             "SELECT productOwnerSessionKey,distance FROM assignment_product_owner_ancestry WHERE assignmentId=?1 ORDER BY distance",
             [missing.id]
           ) != []

    expected_bindings =
      [captured.id, missing.id]
      |> Enum.sort()
      |> Enum.map(&[&1, "assignment"])

    assert expected_bindings ==
             rows!(
               ctx.db,
               "SELECT assignmentId,sourceKind FROM assignment_deliverables WHERE assignmentId IN (?1,?2) ORDER BY assignmentId",
               Enum.sort([captured.id, missing.id])
             )

    assert :ok = DeliverableContract.ensure_schema(ctx.db)
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

  test "completion and close serialization is deterministic in both orders", ctx do
    close_first_card = create_card(ctx, "Close probe before completion")
    close_first_assignment = assign(ctx, close_first_card.id, "Whole close-first result", true)

    assert %{code: "completion_claim_not_found"} =
             close(ctx, {:user, "flynn"}, close_first_card.id, "att_future_completion")

    assert close_snapshot(ctx.db, close_first_card.id).closure == []
    close_first_completion = complete(ctx, close_first_assignment.id, nil)

    assert %{ok: true, workItem: %{state: "closed"}} =
             close(ctx, {:user, "flynn"}, close_first_card.id, close_first_completion.attest.id)

    completion_first_card = create_card(ctx, "Completion probe before close")

    completion_first_assignment =
      assign(ctx, completion_first_card.id, "Whole completion-first result", true)

    completion_first = complete(ctx, completion_first_assignment.id, nil)

    assert %{ok: true, workItem: %{state: "closed"}} =
             close(ctx, {:user, "flynn"}, completion_first_card.id, completion_first.attest.id)

    for card_id <- [close_first_card.id, completion_first_card.id] do
      assert {:ok, [[1, 1]]} =
               DB.query(
                 ctx.db,
                 "SELECT (SELECT count(*) FROM work_item_closures WHERE workItemId=?1),(SELECT count(*) FROM completion_claims c JOIN assignments a ON a.id=c.assignmentId WHERE a.workItemId=?1)",
                 [card_id]
               )
    end
  end

  test "completion against revocation preserves one terminal history in both orders", ctx do
    completion_before_revoke =
      assign(ctx, create_card(ctx, "Completion before revoke").id, "C then R", true)

    assert %{assignment: %{outcome: "completed"}} =
             complete(ctx, completion_before_revoke.id, nil)

    assert %{code: "assignment_closed"} =
             revoke(ctx, {:user, "flynn"}, completion_before_revoke.id)

    assert {:ok, [[1, 1]]} = completion_counts(ctx.db, completion_before_revoke.id)

    revoke_before_completion =
      assign(ctx, create_card(ctx, "Revoke before completion").id, "R then C", true)

    assert %{outcome: "revoked"} = revoke(ctx, {:user, "flynn"}, revoke_before_completion.id)
    assert %{code: "assignment_closed"} = complete(ctx, revoke_before_completion.id, nil)
    assert {:ok, [[0, 0]]} = completion_counts(ctx.db, revoke_before_completion.id)
  end

  test "identical, exact, and narrowing close requests keep one closure in both orders", ctx do
    identical_card = create_card(ctx, "Identical close requests")
    identical_assignment = assign(ctx, identical_card.id, "Identical whole result", true)
    identical_completion = complete(ctx, identical_assignment.id, nil)
    first = close(ctx, {:user, "flynn"}, identical_card.id, identical_completion.attest.id)
    replay = close(ctx, {:user, "flynn"}, identical_card.id, identical_completion.attest.id)
    assert replay.workItem.closure == first.workItem.closure

    for first_kind <- [:exact, :narrow] do
      card = create_card(ctx, "Competing #{first_kind} closure")
      partial = assign(ctx, card.id, "Reviewed partial", false)
      exact = assign(ctx, card.id, "Whole card", true)
      partial_completion = complete(ctx, partial.id, nil)
      exact_completion = complete(ctx, exact.id, nil)
      reason = "The product owner accepts the reviewed partial"

      {winner, loser} =
        case first_kind do
          :exact ->
            {
              close(ctx, {:user, "flynn"}, card.id, exact_completion.attest.id),
              close(
                ctx,
                {:session, "product-owner"},
                card.id,
                partial_completion.attest.id,
                reason
              )
            }

          :narrow ->
            {
              close(
                ctx,
                {:session, "product-owner"},
                card.id,
                partial_completion.attest.id,
                reason
              ),
              close(ctx, {:user, "flynn"}, card.id, exact_completion.attest.id)
            }
        end

      assert %{ok: true} = winner
      assert %{code: "work_item_closed"} = loser

      assert {:ok, [[1]]} =
               DB.query(ctx.db, "SELECT count(*) FROM work_item_closures WHERE workItemId=?1", [
                 card.id
               ])
    end
  end

  test "a sibling-tree assignment changes narrowing authority only in the legal order", ctx do
    session(ctx.db, "child-owner", "flynn", %{
      archetype: "product-owner",
      spawned_by: "product-owner"
    })

    session(ctx.db, "child-holder", "flynn", %{spawned_by: "child-owner"})
    session(ctx.db, "sibling-holder", "flynn", %{spawned_by: "product-owner"})

    close_first_card = create_card(ctx, "Child closes before sibling assignment")
    child = assign_to(ctx, close_first_card.id, "Child result", false, "child-holder")
    child_completion = complete_as(ctx, child.id, nil, nil, "child-holder")

    assert %{ok: true, workItem: %{closure: %{ownerRulingProductOwnerSessionKey: "child-owner"}}} =
             close(
               ctx,
               {:session, "child-owner"},
               close_first_card.id,
               child_completion.attest.id,
               "Child product owner accepts its product result"
             )

    assert %{code: "work_item_not_open"} =
             assign_to(ctx, close_first_card.id, "Late sibling", false, "sibling-holder")

    assignment_first_card = create_card(ctx, "Sibling assignment changes common owner")
    child = assign_to(ctx, assignment_first_card.id, "Child result", false, "child-holder")
    child_completion = complete_as(ctx, child.id, nil, nil, "child-holder")
    sibling = assign_to(ctx, assignment_first_card.id, "Sibling result", false, "sibling-holder")

    assert %{code: "assignments_open"} =
             close(
               ctx,
               {:session, "child-owner"},
               assignment_first_card.id,
               child_completion.attest.id,
               "Too early"
             )

    _sibling_completion = complete_as(ctx, sibling.id, nil, nil, "sibling-holder")

    assert %{code: "owner_ruling_forbidden"} =
             close(
               ctx,
               {:session, "child-owner"},
               assignment_first_card.id,
               child_completion.attest.id,
               "No longer the common owner"
             )

    assert %{
             ok: true,
             workItem: %{closure: %{ownerRulingProductOwnerSessionKey: "product-owner"}}
           } =
             close(
               ctx,
               {:session, "product-owner"},
               assignment_first_card.id,
               child_completion.attest.id,
               "The common parent product owner accepts the child result"
             )
  end

  test "captured wi_113442f5 rows and real artifact cannot recur without explicit ruling", ctx do
    captured = captured_wi_113442f5_fixture!()
    captured_assignments = captured["assignments"]
    captured_attests = captured["attests"]

    spec_row =
      Enum.find(captured_assignments, &(&1["id"] == "asg_29aeed02-f3bc-421a-99ca-c2bce6f80ec0"))

    completion_row =
      Enum.find(captured_attests, &(&1["id"] == "att_1ab4c74f-d4a3-4af2-8c61-c467062367e4"))

    fixture = %{
      work_item_id: captured["workItem"]["id"],
      title: captured["workItem"]["title"],
      assignment_id: spec_row["id"],
      subject: spec_row["subject"],
      completion_attest_id: completion_row["id"],
      note: completion_row["note"],
      commit_ref: %{
        repo: nil,
        commit: hd(completion_row["commitRefs"])["commit"]
      }
    }

    assert fixture.work_item_id == "wi_113442f5-22ae-457b-a971-1b620069d490"
    assert fixture.assignment_id == "asg_29aeed02-f3bc-421a-99ca-c2bce6f80ec0"
    assert fixture.completion_attest_id == "att_1ab4c74f-d4a3-4af2-8c61-c467062367e4"

    assert Enum.map(captured_assignments, & &1["effectKind"]) |> Enum.sort() ==
             ~w(evidence policy review review)

    refute Enum.any?(captured_assignments, &(&1["effectKind"] == "code"))

    assert Enum.sort(Enum.map(captured["trace"]["assignments"], & &1["id"])) ==
             Enum.sort(Enum.map(captured_assignments, & &1["id"]))

    assert Enum.map(captured["trace"]["terminalTimeline"], & &1["verdict"])
           |> Enum.reject(&is_nil/1) ==
             ["spirit-approved", "changes-requested", "reviewed-clean"]

    assert List.last(captured["trace"]["terminalTimeline"])["kind"] ==
             "disposition_transition"

    repo = exact_wi_113442f5_commit_repo!()
    fixture = put_in(fixture, [:commit_ref, :repo], "testhost:#{repo}")

    register_hosts(ctx.db, %{
      "testhost" => %{ssh: nil, base_dir: System.tmp_dir!(), cli_bin: nil}
    })

    card =
      create_card(ctx, fixture.title)

    session(ctx.db, "reviewer", "other")

    spirit =
      assign_to(
        ctx,
        card.id,
        "Review REST D3 CLI direct-GET migration and legacy read removal for product spirit",
        false,
        "reviewer",
        effect_kind: "evidence"
      )

    assert %{attest: %{verdictKind: "spirit-approved"}} =
             Assignments.__handle__(
               ctx.db,
               "attest",
               call("attest", {:session, "reviewer"}, nil, %{
                 assignment_id: spirit.id,
                 kind: "verdict",
                 verdict_kind: "spirit-approved"
               })
             )

    assert %{assignment: %{state: "closed"}} =
             complete_as(ctx, spirit.id, "spirit review complete", nil, "reviewer")

    assignment =
      assign(
        ctx,
        card.id,
        fixture.subject,
        false
      )

    first_review =
      assign_to(ctx, nil, "Review the first exact D3 specification", false, "reviewer",
        reviews_assignment_id: assignment.id,
        effect_kind: "review"
      )

    assert %{attest: %{verdictKind: "changes-requested"}} =
             Assignments.__handle__(
               ctx.db,
               "attest",
               call("attest", {:session, "reviewer"}, nil, %{
                 assignment_id: first_review.id,
                 kind: "verdict",
                 verdict_kind: "changes-requested"
               })
             )

    assert %{assignment: %{state: "closed"}} =
             complete_as(ctx, first_review.id, nil, nil, "reviewer")

    clean_review =
      assign_to(ctx, nil, "Review the exact D3 successor", false, "reviewer",
        reviews_assignment_id: assignment.id,
        effect_kind: "review"
      )

    assert %{attest: %{verdictKind: "reviewed-clean"}} =
             Assignments.__handle__(
               ctx.db,
               "attest",
               call("attest", {:session, "reviewer"}, nil, %{
                 assignment_id: clean_review.id,
                 kind: "verdict",
                 verdict_kind: "reviewed-clean"
               })
             )

    assert %{assignment: %{state: "closed"}} =
             complete_as(ctx, clean_review.id, nil, nil, "reviewer")

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

    trace =
      WorkItems.__handle__(
        ctx.db,
        "work-item-trace",
        call("work-item-trace", {:user, "flynn"}, nil, %{work_item_id: card.id})
      )

    assert Enum.sort(Enum.map(trace.assignments, & &1.id)) ==
             Enum.sort([spirit.id, assignment.id, first_review.id, clean_review.id])

    refute Enum.any?(trace.assignments, &String.starts_with?(&1.deliverable.name, "Implement "))

    assert %{code: "completion_deliverable_mismatch"} =
             close(ctx, {:user, "flynn"}, card.id, completion.attest.id)

    assert %{workItem: %{state: "open", closure: nil}} =
             WorkItems.__handle__(
               ctx.db,
               "work-item-get",
               call("work-item-get", {:user, "flynn"}, nil, %{work_item_id: card.id})
             )

    implementation =
      assign(ctx, card.id, "Implement the D3 product and remove legacy reads", true)

    implementation_completion = complete(ctx, implementation.id, "Implemented the whole card")

    assert %{ok: true, workItem: %{state: "closed", closure: %{basis: "exact"}}} =
             close(ctx, {:user, "flynn"}, card.id, implementation_completion.attest.id)

    narrowing_card = create_card(ctx, fixture.title)
    narrowing_assignment = assign(ctx, narrowing_card.id, fixture.subject, false)
    narrowing_completion = complete(ctx, narrowing_assignment.id, fixture.note)

    assert %{ok: true, workItem: narrowed} =
             close(
               ctx,
               {:session, "product-owner"},
               narrowing_card.id,
               narrowing_completion.attest.id,
               "The exact product owner explicitly accepts the reviewed D3 specification only"
             )

    assert narrowed.closure.basis == "owner_narrowing"
    assert narrowed.closure.acceptedDeliverable.id == narrowing_assignment.deliverable.id
  end

  test "captured phase1-v9 history upgrades byte-exactly and its binary refuses v10" do
    db = :"captured_phase1_v9_history_#{System.unique_integer([:positive])}"

    start_supervised!(%{
      id: db,
      start: {DB, :start_link, [[path: ":memory:", name: db]]}
    })

    v9_schema = captured_v9_schema_module!()
    assert :ok = apply(v9_schema, :ensure_all, [db])

    assert [["coordination-fabric-v1-phase1-v9"]] = rows!(db, "SELECT shape FROM schema_stamp")

    # The capture is schema.ex ONLY, so the module's @schema_modules list still
    # names the CURRENT Tightbeam.Assignments — ensure_all/1 above therefore
    # installs main's post-v9 revocation write-guards into a v9-stamped
    # database. Build 724e5c96, which this fixture was dumped from, had no such
    # trigger, so its genuine revoked row carries no provenance. A real v9
    # database never trips them either: they are BEFORE INSERT/UPDATE guards on
    # new writes, and its rows are already stored. Only this DML replay does.
    # Drop them for the load exactly as migrate_revocation_reason_constraint/1
    # does around its own bulk swap.
    :ok = DB.execute(db, "DROP TRIGGER IF EXISTS assignments_revocation_reason_required")
    :ok = DB.execute(db, "DROP TRIGGER IF EXISTS assignments_revocation_reason_required_insert")

    fixture =
      Path.expand("fixtures/deliverable_contract/phase1_v9_history.sql", __DIR__)
      |> File.read!()

    assert :ok = DB.execute(db, fixture)

    before = historical_snapshot(db)
    predecessor_counts = historical_counts(db)

    assert :ok =
             DeliverableContract.upgrade_v1(
               db,
               "coordination-fabric-v1-phase1-v9",
               "coordination-fabric-v1-phase1-v10"
             )

    assert historical_snapshot(db) == before
    assert historical_counts(db) == predecessor_counts
    assert [[0]] = rows!(db, "SELECT count(*) FROM completion_claims")
    assert [[0]] = rows!(db, "SELECT count(*) FROM work_item_closures")

    assert [[1, 1, 3, 3]] =
             rows!(
               db,
               "SELECT (SELECT count(*) FROM work_item_deliverables),(SELECT count(*) FROM assignment_deliverables),(SELECT count(*) FROM assignment_product_lineage_captures),(SELECT count(*) FROM assignment_product_owner_ancestry)"
             )

    assert %{deliverableClaim: nil} =
             Assignments.list_attests(db, "asg_v9_reopened")
             |> Enum.find(&(&1.id == "att_v9_reopened_old"))

    assert %{deliverableContract: "v1", deliverable: %{name: "Captured reopened result"}} =
             DeliverableContract.assignment_projection(db, "asg_v9_reopened")

    for legacy <- ~w(asg_v9_completed asg_v9_surrendered asg_v9_revoked) do
      assert %{deliverableContract: "legacy", deliverable: nil} =
               DeliverableContract.assignment_projection(db, legacy)
    end

    assert %{workItem: %{deliverableContract: "legacy", deliverable: nil, closure: nil}} =
             WorkItems.__handle__(
               db,
               "work-item-get",
               call("work-item-get", {:user, "flynn"}, nil, %{work_item_id: "wi_v9_closed"})
             )

    assert %{workItem: %{deliverableContract: "legacy", deliverable: nil, state: "failed"}} =
             WorkItems.__handle__(
               db,
               "work-item-get",
               call("work-item-get", {:user, "flynn"}, nil, %{work_item_id: "wi_v9_failed"})
             )

    assert %{
             workItem: %{
               deliverableContract: "v1",
               deliverable: %{name: "Captured active card"}
             }
           } =
             WorkItems.__handle__(
               db,
               "work-item-get",
               call("work-item-get", {:user, "flynn"}, nil, %{work_item_id: "wi_v9_active"})
             )

    for {assignment_id, attest_id} <- [
          {"asg_v9_completed", "att_v9_completed"},
          {"asg_v9_reopened", "att_v9_reopened_old"}
        ] do
      assert %{deliverableClaim: nil} =
               Assignments.list_attests(db, assignment_id)
               |> Enum.find(&(&1.id == attest_id))
    end

    try do
      apply(v9_schema, :ensure_all, [db])
      flunk("the exact phase1-v9 schema binary accepted a phase1-v10 stamp")
    rescue
      error ->
        assert error.__struct__ == Module.concat(v9_schema, ShapeError)
        assert Exception.message(error) =~ "stamped: coordination-fabric-v1-phase1-v10"
        assert Exception.message(error) =~ "this build: coordination-fabric-v1-phase1-v9"
    end
  end

  test "keyed creation replay preserves original card and assignment bindings", ctx do
    first_card_call =
      call("work-item-create", {:user, "flynn"}, nil, %{
        title: "Original card title",
        spec_ref_name: "original-spec.md",
        spec_ref_sha256: String.duplicate("a", 64),
        is_bug: false,
        idempotency_key: "card-create-key"
      })

    first_card = WorkItems.__handle__(ctx.db, "work-item-create", first_card_call)

    replayed_card_call =
      first_card_call
      |> put_in([:params, :title], "Changed valid title")
      |> put_in([:params, :spec_ref_name], "changed-spec.md")
      |> put_in([:params, :spec_ref_sha256], String.duplicate("b", 64))
      |> put_in([:params, :is_bug], true)

    replayed_card = WorkItems.__handle__(ctx.db, "work-item-create", replayed_card_call)

    assert replayed_card == first_card

    card_snapshot = creation_binding_snapshot(ctx.db)

    for {field, value, code} <- [
          {:title, " ", "invalid_title"},
          {:spec_ref_name, nil, "invalid_spec_ref"},
          {:spec_ref_sha256, "bad", "invalid_spec_ref"},
          {:is_bug, "false", "invalid_is_bug"},
          {:idempotency_key, 123, "invalid_idempotency_key"}
        ] do
      assert %{code: ^code} =
               first_card_call
               |> put_in([:params, field], value)
               |> then(&WorkItems.__handle__(ctx.db, "work-item-create", &1))

      assert creation_binding_snapshot(ctx.db) == card_snapshot
    end

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

    assignment_snapshot = creation_binding_snapshot(ctx.db)

    for {field, value, code} <- [
          {:subject, " ", "invalid_subject"},
          {:idempotency_key, 123, "invalid_idempotency_key"},
          {:effect_kind, "source", "invalid_effect_kind"},
          {:delivers_work_item, "true", "invalid_delivers_work_item"},
          {:files, "lib/not-a-list.ex", "invalid_files"}
        ] do
      assert %{code: ^code} =
               first_assignment_call
               |> put_in([:params, field], value)
               |> then(&Assignments.__handle__(ctx.db, "assign", &1))

      assert creation_binding_snapshot(ctx.db) == assignment_snapshot
    end

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

    durable_dispatch_call =
      assignment_creation_call(
        "dispatch",
        "holder",
        durable_card.id,
        "Durable original dispatch",
        false,
        "durable-dispatch-create"
      )

    durable_dispatch = request_assignment(first_db, durable_dispatch_call)
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

    replayed_durable_dispatch =
      durable_dispatch_call
      |> put_in([:params, :subject], "Changed dispatch after restart")
      |> put_in([:params, :delivers_work_item], true)
      |> then(&request_assignment(restarted_db, &1))

    assert replayed_durable_card.id == durable_card.id
    assert replayed_durable_card.title == durable_card.title
    assert replayed_durable_card.deliverable == durable_card.deliverable
    assert replayed_durable_assignment.id == durable_assignment.id
    assert replayed_durable_assignment.deliverable == durable_assignment.deliverable
    assert replayed_durable_dispatch.id == durable_dispatch.id
    assert replayed_durable_dispatch.deliverable == durable_dispatch.deliverable

    assert {:ok, [[1, 1, 2, 2, 2, 2]]} =
             DB.query(
               restarted_db,
               "SELECT (SELECT count(*) FROM work_items WHERE id=?1),(SELECT count(*) FROM work_item_deliverables WHERE workItemId=?1),(SELECT count(*) FROM assignments WHERE id IN (?2,?3)),(SELECT count(*) FROM assignment_deliverables WHERE assignmentId IN (?2,?3)),(SELECT count(*) FROM assignment_product_lineage_captures WHERE assignmentId IN (?2,?3)),(SELECT count(*) FROM wire_idempotency WHERE operation IN ('assign','dispatch') AND sessionKey IN (?2,?3))",
               [durable_card.id, durable_assignment.id, durable_dispatch.id]
             )
  end

  test "assign and dispatch creation replay preserve both binding directions through terminal cards",
       ctx do
    register_hosts(ctx.db, %{
      "testhost" => %{ssh: nil, base_dir: System.tmp_dir!(), cli_bin: nil}
    })

    session(ctx.db, "alternate-holder", "flynn", %{spawned_by: "product-owner"})

    for {verb, first_binding} <- [
          {"assign", false},
          {"assign", true},
          {"dispatch", false},
          {"dispatch", true}
        ] do
      original_card = create_card(ctx, "#{verb} #{first_binding} original card")
      other_card = create_card(ctx, "#{verb} #{first_binding} other card")
      key = "#{verb}-#{first_binding}-replay"

      original =
        assignment_creation_call(
          verb,
          "holder",
          original_card.id,
          "Original #{verb} scope #{first_binding}",
          first_binding,
          key
        )

      created = request_assignment(ctx.db, original)
      before = creation_binding_snapshot(ctx.db)

      replay_call =
        original
        |> Map.put(:session_key, "alternate-holder")
        |> put_in([:params, :subject], "Changed valid #{verb} scope")
        |> put_in([:params, :work_item_id], other_card.id)
        |> put_in([:params, :effect_kind], "policy")
        |> put_in([:params, :delivers_work_item], not first_binding)
        |> put_in([:params, :files], ["changed/path.ex"])

      replayed = request_assignment(ctx.db, replay_call)
      assert replayed.id == created.id
      assert replayed.workItemId == original_card.id
      assert replayed.holderKey == "holder"
      assert replayed.deliverable == created.deliverable
      assert creation_binding_snapshot(ctx.db) == before

      for {field, value, code} <- [
            {:subject, " ", "invalid_subject"},
            {:idempotency_key, 123, "invalid_idempotency_key"},
            {:effect_kind, "source", "invalid_effect_kind"},
            {:delivers_work_item, "yes", "invalid_delivers_work_item"}
          ] do
        assert %{code: ^code} =
                 original
                 |> put_in([:params, field], value)
                 |> then(&request_assignment(ctx.db, &1))

        assert creation_binding_snapshot(ctx.db) == before
      end

      if verb == "assign" do
        assert %{code: "invalid_files"} =
                 original
                 |> put_in([:params, :files], "not-an-array")
                 |> then(&request_assignment(ctx.db, &1))

        assert creation_binding_snapshot(ctx.db) == before
      end

      completion = complete(ctx, created.id, "terminal replay proof")

      if first_binding do
        assert %{ok: true} =
                 close(ctx, {:user, "flynn"}, original_card.id, completion.attest.id)
      else
        assert %{ok: true} =
                 WorkItems.__handle__(
                   ctx.db,
                   "work-item-fail",
                   call("work-item-fail", {:user, "flynn"}, nil, %{
                     work_item_id: original_card.id,
                     reason: "terminal replay fixture"
                   })
                 )
      end

      terminal_before = creation_binding_snapshot(ctx.db)
      terminal_replay = request_assignment(ctx.db, replay_call)
      assert terminal_replay.id == created.id
      assert terminal_replay.deliverable == created.deliverable
      assert creation_binding_snapshot(ctx.db) == terminal_before

      assert %{code: "work_item_not_open"} =
               replay_call
               |> put_in([:params, :idempotency_key], "#{key}-different")
               |> put_in([:params, :work_item_id], original_card.id)
               |> then(&request_assignment(ctx.db, &1))

      assert creation_binding_snapshot(ctx.db) == terminal_before
    end
  end

  test "the exact v15-to-v16 upgrade is atomic, deterministic, and validates restart", ctx do
    card = create_card(ctx, "Migrated card")
    assignment = assign(ctx, card.id, "Migrated open assignment", false)
    strip_contract!(ctx.db, "coordination-fabric-v1-phase1-v15")

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
          "coordination-fabric-v1-phase1-v15",
          "coordination-fabric-v1-phase1-v16",
          fail_at: fault
        )
      end

      assert {:ok, [["coordination-fabric-v1-phase1-v15"]]} =
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
        "coordination-fabric-v1-phase1-v15",
        "coordination-fabric-v1-phase1-v16"
      )
    end

    assert {:ok, [["coordination-fabric-v1-phase1-v15"]]} =
             DB.query(ctx.db, "SELECT shape FROM schema_stamp")

    :ok = DB.execute(ctx.db, "DROP TABLE deliverables")

    assert :ok =
             DeliverableContract.upgrade_v1(
               ctx.db,
               "coordination-fabric-v1-phase1-v15",
               "coordination-fabric-v1-phase1-v16"
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

  defp assign_to(ctx, work_item_id, subject, delivers_work_item, holder, opts \\ []) do
    params =
      %{
        subject: subject,
        work_item_id: work_item_id,
        delivers_work_item: delivers_work_item
      }
      |> Map.merge(Map.new(opts))

    Assignments.__handle__(
      ctx.db,
      "assign",
      call("assign", {:user, "flynn"}, holder, params)
      |> Map.merge(%{target_role: nil, role_fallback: false, supervision_interval_ms: 1_000})
    )
  end

  defp dispatch_to(ctx, work_item_id, subject, delivers_work_item, holder) do
    Assignments.__handle__(
      ctx.db,
      "dispatch",
      call("dispatch", {:user, "flynn"}, holder, %{
        subject: subject,
        brief: "Perform the exact dispatched obligation",
        work_item_id: work_item_id,
        workdir_root: nil,
        effect_kind: "code",
        delivers_work_item: delivers_work_item
      })
      |> Map.merge(%{target_role: nil, role_fallback: false, supervision_interval_ms: 1_000})
    )
  end

  defp assignment_creation_call(verb, holder, work_item_id, subject, binding, key) do
    params = %{
      subject: subject,
      brief: "Perform the exact keyed dispatch",
      work_item_id: work_item_id,
      workdir_root: nil,
      effect_kind: "code",
      files: ["original/path.ex"],
      delivers_work_item: binding,
      idempotency_key: key
    }

    call(verb, {:user, "flynn"}, holder, params)
    |> Map.merge(%{target_role: nil, role_fallback: false, supervision_interval_ms: 1_000})
  end

  defp request_assignment(db, call) do
    case Assignments.dispatch_precheck(db, call) do
      {:replay, assignment} -> assignment
      {:refuse, error} -> error
      :proceed -> Assignments.__handle__(db, call.verb, call)
    end
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
      call("revoke-assignment", principal, nil, %{
        assignment_id: assignment_id,
        reason: "deliverable contract test revocation"
      })
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
      supervision_receipt:
        rows!(db, "SELECT * FROM supervision_liveness_receipt_state WHERE assignmentId=?1", [
          assignment_id
        ]),
      supervision_sidecar:
        rows!(db, "SELECT * FROM supervision_liveness_sidecar WHERE assignmentId=?1", [
          assignment_id
        ]),
      effort:
        rows!(db, "SELECT * FROM effort_checkin_generations WHERE assignmentId=?1", [
          assignment_id
        ]),
      decisions:
        rows!(db, "SELECT * FROM decision_requests WHERE assignmentId=?1", [assignment_id]),
      work_item:
        rows!(db, "SELECT state,routingWakeId,slateWakeId FROM work_items WHERE id=?1", [
          work_item_id
        ]),
      wakes:
        rows!(
          db,
          "SELECT * FROM wakes WHERE work_item_id=?1 OR assignmentId=?2 ORDER BY wakeId",
          [work_item_id, assignment_id]
        ),
      wake_cancellations:
        rows!(
          db,
          "SELECT * FROM wake_cancellations WHERE wakeId IN (SELECT wakeId FROM wakes WHERE work_item_id=?1 OR assignmentId=?2) ORDER BY wakeId",
          [work_item_id, assignment_id]
        ),
      lifecycle:
        rows!(
          db,
          "SELECT * FROM lifecycle_events WHERE subject=?1 ORDER BY id",
          [assignment_id]
        )
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

  defp historical_counts(db) do
    rows!(
      db,
      "SELECT (SELECT count(*) FROM work_items),(SELECT count(*) FROM assignments),(SELECT count(*) FROM attests),(SELECT count(*) FROM work_item_events),(SELECT count(*) FROM assignment_reopenings),(SELECT count(*) FROM wakes),(SELECT count(*) FROM wake_cancellations),(SELECT count(*) FROM lifecycle_events)"
    )
  end

  defp creation_binding_snapshot(db) do
    for table <- [
          "work_items",
          "deliverables",
          "work_item_deliverables",
          "assignments",
          "assignment_effects",
          "assignment_files",
          "assignment_deliverables",
          "assignment_product_lineage_captures",
          "assignment_product_owner_ancestry",
          "wire_idempotency",
          "wakes",
          "messages",
          "supervision_entitlements",
          "supervision_liveness_receipt_state",
          "effort_checkin_generations"
        ],
        into: %{} do
      {table, rows!(db, "SELECT * FROM #{table} ORDER BY rowid")}
    end
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

    register_hosts(db, %{
      "testhost" => %{ssh: nil, base_dir: System.tmp_dir!(), cli_bin: nil}
    })
  end

  defp open_effort_request!(db, assignment_id, expecter_session_key) do
    [[generation]] =
      rows!(
        db,
        "SELECT MAX(generation) FROM effort_checkin_generations WHERE assignmentId=?1",
        [assignment_id]
      )

    now = System.system_time(:millisecond)

    deadline =
      Wakes.schedule(db, %{
        session_key: expecter_session_key,
        origin: "process:tightbeam",
        consumer: "effort_deadline",
        due_at: now + 60_000,
        assignment_id: assignment_id
      })

    request_id = "dr_completion_effort_#{System.unique_integer([:positive])}"

    assert {:ok, _} =
             DB.query(
               db,
               """
               INSERT INTO decision_requests
                 (id,kind,raiserId,ownerUserId,assignmentId,expecterSessionKey,lineageRung,
                  effortGeneration,deadlineWakeId,raisedAt,deadlineAt,question,options,context,status)
               VALUES (?1,'effort','process:tightbeam','flynn',?2,?3,1,?4,?5,?6,?7,
                       'Continue or dismiss?','["continue","dismiss"]',
                       '{"actions":["continue","dismiss"]}','open')
               """,
               [
                 request_id,
                 assignment_id,
                 expecter_session_key,
                 generation,
                 deadline.wake_id,
                 now,
                 now + 60_000
               ]
             )

    request_id
  end

  defp captured_v9_schema_module! do
    module = Tightbeam.CapturedPhase1V9Schema

    unless Code.ensure_loaded?(module) do
      archive =
        Path.join(__DIR__, "fixtures/deliverable_contract/phase1_v9_lib.tar.gz")
        |> File.read!()

      assert {:ok, entries} = :erl_tar.extract({:binary, archive}, [:memory, :compressed])

      source =
        Enum.find_value(entries, fn
          {~c"lib/tightbeam/schema.ex", bytes} -> bytes
          _ -> nil
        end)

      assert is_binary(source)

      assert :crypto.hash(:sha256, source) |> Base.encode16(case: :lower) ==
               "cbaa8a3f2aabde64e20cb372be343f8d583d08219a6e95d92d73ad7e93de008a"

      renamed =
        String.replace(
          source,
          "defmodule Tightbeam.Schema do",
          "defmodule Tightbeam.CapturedPhase1V9Schema do",
          global: false
        )

      assert Enum.any?(Code.compile_string(renamed, "captured-phase1-v9/schema.ex"), fn
               {^module, _bytecode} -> true
               _ -> false
             end)
    end

    module
  end

  defp captured_wi_113442f5_fixture! do
    path = Path.expand("fixtures/deliverable_contract/wi_113442f5.json", __DIR__)
    bytes = File.read!(path)

    assert :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower) ==
             "29d5caad12b7eb9f1d8f8046e8a7acbdd1b36f9c3c5c2e00cd41fb100323df39"

    JSON.decode!(bytes)
  end

  defp exact_wi_113442f5_commit_repo! do
    repo =
      Path.join(
        System.tmp_dir!(),
        "wi-113442f5-commit-#{System.unique_integer([:positive])}"
      )

    git_dir = Path.join(repo, ".git")
    object_dir = Path.join([git_dir, "objects", "85"])
    File.mkdir_p!(object_dir)
    File.mkdir_p!(Path.join(git_dir, "refs"))
    File.write!(Path.join(git_dir, "HEAD"), "ref: refs/heads/main\n")

    body =
      "tree 9d6c4696af016c2159465beeef5c95c6bd12a091\n" <>
        "parent 64408a93190c31ca992af22c28a6726c8687c65f\n" <>
        "author Mike Manzano <mike@clicketyclacks.co> 1787643229 +0000\n" <>
        "committer Mike Manzano <mike@clicketyclacks.co> 1787643229 +0000\n\n" <>
        "spec: address D3 review findings\n"

    object = "commit #{byte_size(body)}\0" <> body

    assert :crypto.hash(:sha, object) |> Base.encode16(case: :lower) ==
             "85ae5ecb126d54cf7759b4ce37d9459fd7bd0f0f"

    File.write!(
      Path.join(object_dir, "ae5ecb126d54cf7759b4ce37d9459fd7bd0f0f"),
      :zlib.compress(object)
    )

    repo
  end

  defp rows!(db, sql, params \\ []) do
    {:ok, rows} = DB.query(db, sql, params)
    rows
  end

  defp strip_contract_to_v9!(db), do: strip_contract!(db, "coordination-fabric-v1-phase1-v9")

  defp strip_contract!(db, shape) do
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
      DB.query(db, "UPDATE schema_stamp SET shape=?1", [shape])

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
