defmodule Tightbeam.WorkItemTraceRestTest do
  use Tightbeam.TestCase, async: false

  import Plug.Conn
  import Plug.Test

  alias Tightbeam.{
    Archetypes,
    DB,
    Devices,
    ExecutionMap,
    Identity,
    Ledger,
    Schema,
    StateResources,
    WorkItems
  }

  alias Tightbeam.Firehose.Hub
  alias Tightbeam.Wire.Router

  setup do
    base_dir =
      Path.join(
        System.tmp_dir!(),
        "tightbeam-work-item-trace-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(base_dir)
    :initialized = Identity.init!(base_dir)
    Archetypes.load!(base_dir)

    db = String.to_atom("work_item_trace_db_#{System.unique_integer([:positive])}")
    start_supervised!({DB, path: ":memory:", name: db})
    :ok = Schema.ensure_all(db)
    start_supervised!({Hub, name: Hub})

    Devices.add_user(db, "admin", true)
    Devices.add_user(db, "owner", false)
    Devices.add_user(db, "other", false)

    owner_device = approved_device(db, "work-item-trace-owner", "Owner", "owner")
    owner_session = ensure_main_session(db, "owner")
    other_session = ensure_main_session(db, "other")

    opts = [
      db: db,
      base_dir: base_dir,
      handlers: %{},
      cli_token: "tbc_work_item_trace_rest",
      firehose_hub: Hub,
      session_status: fn _ -> nil end
    ]

    on_exit(fn -> File.rm_rf!(base_dir) end)

    %{
      db: db,
      opts: opts,
      token: owner_device.token,
      owner_session: owner_session,
      other_session: other_session
    }
  end

  test "returns canonical R7 rows, transitive assignment membership, direct children and T-C6 bytes",
       ctx do
    parent = insert_work_item!(ctx.db, "wi_trace_parent", "owner", 10_000)
    other_parent = insert_work_item!(ctx.db, "wi_trace_other_parent", "owner", 15_000)
    root = insert_work_item!(ctx.db, "wi_trace_root", "owner", 20_000, context_known: true)
    child = insert_work_item!(ctx.db, "wi_trace_child_job", "owner", 30_000, context_known: true)

    review_child =
      insert_work_item!(ctx.db, "wi_trace_child_review", "owner", 40_000, context_known: true)

    other_child =
      insert_work_item!(ctx.db, "wi_trace_child_other", "owner", 45_000, context_known: true)

    root_turn = insert_turn!(ctx, "trace-root-turn", job_ref: parent)
    child_turn = insert_turn!(ctx, "trace-child-job-turn", job_ref: root)
    other_turn = insert_turn!(ctx, "trace-child-other-turn", job_ref: other_parent)
    set_creation_turn!(ctx.db, root, root_turn)
    set_creation_turn!(ctx.db, child, child_turn)
    set_creation_turn!(ctx.db, other_child, other_turn)

    base_assignment =
      insert_assignment!(ctx.db, "asg_trace_base",
        holder: ctx.owner_session.session_key,
        opener_user: "owner",
        work_item_id: root,
        opened_at: 100
      )

    review_assignment =
      insert_assignment!(ctx.db, "asg_trace_review",
        holder: ctx.owner_session.session_key,
        opener_user: "owner",
        reviews_assignment_id: base_assignment,
        opened_at: 200
      )

    second_review =
      insert_assignment!(ctx.db, "asg_trace_second_review",
        holder: ctx.owner_session.session_key,
        opener_user: "owner",
        reviews_assignment_id: review_assignment,
        opened_at: 300
      )

    review_turn = insert_turn!(ctx, "trace-child-review-turn", assignment_id: second_review)
    set_creation_turn!(ctx.db, review_child, review_turn)

    response = get(ctx, "/api/work-items/#{root}/trace")
    trace = decode_trace!(response)
    assert_trace_parent_matches_execution_map!(ctx, root, trace)

    assert get_resp_header(response, "cache-control") == ["no-store"]
    assert trace["workItem"]["id"] == root

    assert Enum.map(trace["assignments"], & &1["id"]) == [
             base_assignment,
             review_assignment,
             second_review
           ]

    assert trace["causalChildren"] == [child, review_child]

    assert trace["attribution"] == %{
             "provenanceStatus" => "linked",
             "reasonKind" => "concurrent_turn",
             "primaryWorkKind" => "work_item",
             "primaryWorkId" => parent
           }

    assert trace["dependencyVersion"] ==
             expected_dependency_version([
               ["work items", root, item_version(ctx.db, root)],
               ["work items", child, item_version(ctx.db, child)],
               ["work items", review_child, item_version(ctx.db, review_child)],
               ["work items", parent, item_version(ctx.db, parent)],
               ["assignments", base_assignment, assignment_version(ctx.db, base_assignment)],
               ["assignments", review_assignment, assignment_version(ctx.db, review_assignment)],
               ["assignments", second_review, assignment_version(ctx.db, second_review)],
               ["turns", root_turn, turn_version(ctx.db, root_turn)],
               ["turns", child_turn, turn_version(ctx.db, child_turn)],
               ["turns", review_turn, turn_version(ctx.db, review_turn)]
             ])

    root_row = StateResources.query_work_item(ctx.db, root, rest_call())
    encoded_root = StateResources.encode_item("work items", StateResources.work_item(root_row))
    assert response.resp_body =~ "\"workItem\":#{encoded_root}"

    for assignment_id <- [base_assignment, review_assignment, second_review] do
      assignment_row =
        StateResources.query_assignment(ctx.db, assignment_id, rest_call())
        |> StateResources.assignment()

      encoded_assignment = StateResources.encode_item("assignments", assignment_row)
      assert response.resp_body =~ encoded_assignment
    end

    hidden_child =
      insert_work_item!(ctx.db, "wi_trace_hidden_child", "other", 50_000, context_known: true)

    hidden_turn =
      insert_turn_for_session!(
        ctx,
        ctx.other_session.session_key,
        "trace-hidden-child-turn",
        root
      )

    set_creation_turn!(ctx.db, hidden_child, hidden_turn)
    assert get(ctx, "/api/work-items/#{root}/trace").resp_body == response.resp_body

    assert ordered_keys?(response.resp_body, [
             "workItem",
             "assignments",
             "causalChildren",
             "attribution",
             "dependencyVersion"
           ])

    unrelated_assignment =
      insert_assignment!(ctx.db, "asg_trace_unrelated_invariant",
        holder: ctx.owner_session.session_key,
        opener_user: "owner",
        work_item_id: other_parent,
        opened_at: 60_000
      )

    insert_attest!(
      ctx.db,
      "att_trace_invariant",
      unrelated_assignment,
      ctx.owner_session.session_key,
      60_000
    )

    insert_pending_wake!(
      ctx.db,
      "wake_trace_invariant",
      ctx.owner_session.session_key,
      second_review,
      60_000
    )

    invariant_response = get(ctx, "/api/work-items/#{root}/trace")
    assert invariant_response.resp_body == response.resp_body
    assert decode_trace!(invariant_response)["dependencyVersion"] == trace["dependencyVersion"]

    assert {:ok, _rows} =
             DB.query(
               ctx.db,
               "UPDATE work_items SET ownerUserId='other' WHERE id=?1",
               [parent]
             )

    hidden_parent_response = get(ctx, "/api/work-items/#{root}/trace")
    hidden_parent_trace = decode_trace!(hidden_parent_response)
    assert hidden_parent_trace["attribution"]["provenanceStatus"] == "from_turn"
    assert hidden_parent_trace["attribution"]["primaryWorkId"] == nil
    assert_trace_parent_matches_execution_map!(ctx, root, hidden_parent_trace)
    refute hidden_parent_response.resp_body =~ parent

    assert hidden_parent_trace["dependencyVersion"] ==
             expected_dependency_version([
               ["work items", root, item_version(ctx.db, root)],
               ["work items", child, item_version(ctx.db, child)],
               ["work items", review_child, item_version(ctx.db, review_child)],
               ["assignments", base_assignment, assignment_version(ctx.db, base_assignment)],
               ["assignments", review_assignment, assignment_version(ctx.db, review_assignment)],
               ["assignments", second_review, assignment_version(ctx.db, second_review)],
               ["turns", child_turn, turn_version(ctx.db, child_turn)],
               ["turns", review_turn, turn_version(ctx.db, review_turn)]
             ])
  end

  test "case 12 grants work-item trace to an admin user and its session",
       ctx do
    admin_device = approved_device(ctx.db, "work-item-trace-case12-admin", "Admin", "admin")
    admin_session = ensure_main_session(ctx.db, "admin")
    item = insert_work_item!(ctx.db, "wi_trace_case12_admin", "owner", 45_001)

    admin_response = get(ctx, "/api/work-items/#{item}/trace", admin_device.token)
    admin_trace = decode_trace!(admin_response)

    assert get_resp_header(admin_response, "cache-control") == ["no-store"]
    assert admin_trace["workItem"]["id"] == item

    admin_session_response = get(ctx, "/api/work-items/#{item}/trace", admin_session.cli_token)

    assert admin_session_response.status == 200
    assert decode_trace!(admin_session_response)["workItem"] == admin_trace["workItem"]
  end

  test "session work-item traces include rows from other sessions", ctx do
    root =
      insert_work_item!(ctx.db, "wi_trace_twin_root", "owner", 40_000,
        context_known: true,
        created_by_session: ctx.owner_session.session_key,
        created_in_turn_seq: 777
      )

    child =
      insert_work_item!(ctx.db, "wi_trace_twin_child", "owner", 40_100,
        context_known: true,
        created_by_session: ctx.owner_session.session_key,
        created_in_turn_seq: 778
      )

    assert {:ok, _rows} = DB.query(ctx.db, "PRAGMA foreign_keys=OFF")

    insert_assignment!(ctx.db, "asg_trace_twin_review",
      holder: ctx.owner_session.session_key,
      opener_session: ctx.owner_session.session_key,
      reviews_assignment_id: "asg_trace_twin_hidden_base",
      opened_at: 300
    )

    assert {:ok, _rows} = DB.query(ctx.db, "PRAGMA foreign_keys=ON")

    before = get(ctx, "/api/work-items/#{root}/trace", ctx.owner_session.cli_token)
    before_trace = decode_trace!(before)
    assert before_trace["assignments"] == []
    assert before_trace["causalChildren"] == []
    assert before_trace["attribution"]["provenanceStatus"] == "from_turn"
    child_before = get(ctx, "/api/work-items/#{child}/trace", ctx.owner_session.cli_token)
    child_before_trace = decode_trace!(child_before)
    assert child_before_trace["attribution"]["provenanceStatus"] == "from_turn"

    assert_trace_parent_matches_execution_map!(
      ctx,
      root,
      before_trace,
      ctx.owner_session.cli_token
    )

    assert_trace_parent_matches_execution_map!(
      ctx,
      child,
      child_before_trace,
      ctx.owner_session.cli_token
    )

    hidden_parent = insert_work_item!(ctx.db, "wi_trace_twin_hidden_parent", "other", 41_000)

    insert_assignment!(ctx.db, "asg_trace_twin_hidden_base",
      holder: ctx.other_session.session_key,
      opener_session: ctx.other_session.session_key,
      work_item_id: root,
      opened_at: 301
    )

    insert_hidden_turn!(ctx.db, 777, ctx.other_session.session_key, hidden_parent)
    insert_hidden_turn!(ctx.db, 778, ctx.other_session.session_key, root)

    after_response = get(ctx, "/api/work-items/#{root}/trace", ctx.owner_session.cli_token)
    after_trace = decode_trace!(after_response)
    refute after_response.resp_body == before.resp_body
    assert after_response.resp_body =~ "asg_trace_twin_hidden_base"
    assert after_response.resp_body =~ "asg_trace_twin_review"
    assert after_response.resp_body =~ "wi_trace_twin_hidden_parent"

    child_after = get(ctx, "/api/work-items/#{child}/trace", ctx.owner_session.cli_token)
    refute child_after.resp_body == child_before.resp_body

    assert_trace_parent_matches_execution_map!(
      ctx,
      child,
      decode_trace!(child_after),
      ctx.owner_session.cli_token
    )

    refute after_trace["dependencyVersion"] == before_trace["dependencyVersion"]
  end

  test "cycle-closing edges are demoted and every visible cycle member contributes to T-C6",
       ctx do
    root = insert_work_item!(ctx.db, "wi_trace_cycle_root", "owner", 10_000, context_known: true)

    middle =
      insert_work_item!(ctx.db, "wi_trace_cycle_middle", "owner", 20_000, context_known: true)

    tail = insert_work_item!(ctx.db, "wi_trace_cycle_tail", "owner", 30_000, context_known: true)

    root_turn = insert_turn!(ctx, "trace-cycle-root", job_ref: middle)
    middle_turn = insert_turn!(ctx, "trace-cycle-middle", job_ref: tail)
    tail_turn = insert_turn!(ctx, "trace-cycle-tail", job_ref: root)
    set_creation_turn!(ctx.db, root, root_turn)
    set_creation_turn!(ctx.db, middle, middle_turn)
    set_creation_turn!(ctx.db, tail, tail_turn)

    before = get(ctx, "/api/work-items/#{root}/trace") |> decode_trace!()
    assert before["causalChildren"] == []
    assert before["attribution"]["provenanceStatus"] == "linked"
    assert before["attribution"]["primaryWorkId"] == middle
    assert_trace_parent_matches_execution_map!(ctx, root, before)

    assert before["dependencyVersion"] ==
             expected_dependency_version([
               ["work items", root, item_version(ctx.db, root)],
               ["work items", middle, item_version(ctx.db, middle)],
               ["work items", tail, item_version(ctx.db, tail)],
               ["turns", root_turn, turn_version(ctx.db, root_turn)],
               ["turns", middle_turn, turn_version(ctx.db, middle_turn)],
               ["turns", tail_turn, turn_version(ctx.db, tail_turn)]
             ])

    tail_trace = get(ctx, "/api/work-items/#{tail}/trace") |> decode_trace!()
    assert tail_trace["attribution"]["provenanceStatus"] == "from_turn"
    assert tail_trace["dependencyVersion"] == before["dependencyVersion"]
    assert_trace_parent_matches_execution_map!(ctx, tail, tail_trace)

    for cycle_member <- [middle, tail] do
      assert {:ok, _rows} =
               DB.query(
                 ctx.db,
                 "INSERT INTO work_item_versions (workItemId, rowVersion) VALUES (?1, 99999)",
                 [cycle_member]
               )

      changed_trace = get(ctx, "/api/work-items/#{root}/trace") |> decode_trace!()
      refute changed_trace["dependencyVersion"] == before["dependencyVersion"]

      assert {:ok, _rows} =
               DB.query(
                 ctx.db,
                 "DELETE FROM work_item_versions WHERE workItemId=?1",
                 [cycle_member]
               )
    end
  end

  test "unrecorded and no-turn-observed creation contexts stay distinct", ctx do
    unrecorded = insert_work_item!(ctx.db, "wi_trace_unrecorded", "owner", 50_000)

    no_turn =
      insert_work_item!(ctx.db, "wi_trace_no_turn", "owner", 51_000, context_known: true)

    from_turn =
      insert_work_item!(ctx.db, "wi_trace_no_parent_turn", "owner", 52_000,
        context_known: true,
        created_in_turn_seq: 999_999
      )

    unrecorded_trace = get(ctx, "/api/work-items/#{unrecorded}/trace") |> decode_trace!()
    no_turn_trace = get(ctx, "/api/work-items/#{no_turn}/trace") |> decode_trace!()
    from_turn_response = get(ctx, "/api/work-items/#{from_turn}/trace")
    from_turn_trace = decode_trace!(from_turn_response)

    assert unrecorded_trace["attribution"] == %{
             "provenanceStatus" => "unrecorded",
             "reasonKind" => nil,
             "primaryWorkKind" => nil,
             "primaryWorkId" => nil
           }

    assert no_turn_trace["attribution"] == %{
             "provenanceStatus" => "no_turn_observed",
             "reasonKind" => nil,
             "primaryWorkKind" => nil,
             "primaryWorkId" => nil
           }

    assert from_turn_trace["attribution"] == %{
             "provenanceStatus" => "from_turn",
             "reasonKind" => "concurrent_turn",
             "primaryWorkKind" => nil,
             "primaryWorkId" => nil
           }

    assert_trace_parent_matches_execution_map!(ctx, unrecorded, unrecorded_trace)
    assert_trace_parent_matches_execution_map!(ctx, no_turn, no_turn_trace)
    assert_trace_parent_matches_execution_map!(ctx, from_turn, from_turn_trace)

    assert from_turn_trace["dependencyVersion"] ==
             expected_dependency_version([
               ["work items", from_turn, item_version(ctx.db, from_turn)]
             ])

    assert {:ok, _rows} = DB.query(ctx.db, "PRAGMA foreign_keys=OFF")

    excluded_chain =
      insert_assignment!(ctx.db, "asg_trace_excluded_turn_chain",
        holder: ctx.owner_session.session_key,
        opener_user: "owner",
        reviews_assignment_id: "asg_trace_excluded_turn_missing",
        opened_at: 530
      )

    assert {:ok, _rows} =
             DB.query(
               ctx.db,
               """
               INSERT INTO turns (seq, sessionKey, messageId, origin, prompt, status, createdAt,
                                  assignmentId)
               VALUES (999999, ?1, 'trace-excluded-turn', ?2, 'No visible item link', 'queued',
                       53_000, ?3)
               """,
               [
                 ctx.owner_session.session_key,
                 "session:#{ctx.owner_session.session_key}",
                 excluded_chain
               ]
             )

    assert {:ok, _rows} = DB.query(ctx.db, "PRAGMA foreign_keys=ON")

    excluded_turn_response = get(ctx, "/api/work-items/#{from_turn}/trace")
    assert excluded_turn_response.resp_body == from_turn_response.resp_body

    assert {:ok, _rows} = DB.query(ctx.db, "DELETE FROM turns WHERE seq=999999")

    assert {:ok, _rows} =
             DB.query(ctx.db, "DELETE FROM assignments WHERE id=?1", [excluded_chain])

    absent_turn_response = get(ctx, "/api/work-items/#{from_turn}/trace")
    assert absent_turn_response.resp_body == from_turn_response.resp_body
  end

  test "a hidden middle assignment hop and an absent hop produce identical traces", ctx do
    root = insert_work_item!(ctx.db, "wi_trace_hidden_middle_root", "owner", 53_000)
    child = insert_work_item!(ctx.db, "wi_trace_hidden_middle_child", "owner", 54_000)

    base =
      insert_assignment!(ctx.db, "asg_trace_hidden_middle_base",
        holder: ctx.owner_session.session_key,
        opener_user: "owner",
        work_item_id: root,
        opened_at: 400
      )

    assert {:ok, _rows} = DB.query(ctx.db, "PRAGMA foreign_keys=OFF")

    second_hop =
      insert_assignment!(ctx.db, "asg_trace_hidden_middle_second",
        holder: ctx.owner_session.session_key,
        opener_user: "owner",
        reviews_assignment_id: "asg_trace_hidden_middle_hidden",
        opened_at: 500
      )

    assert {:ok, _rows} = DB.query(ctx.db, "PRAGMA foreign_keys=ON")

    child_turn = insert_turn!(ctx, "trace-hidden-middle-child", assignment_id: second_hop)
    set_creation_turn!(ctx.db, child, child_turn)

    before = get(ctx, "/api/work-items/#{root}/trace")
    before_trace = decode_trace!(before)
    assert Enum.map(before_trace["assignments"], & &1["id"]) == [base]
    assert before_trace["causalChildren"] == []

    child_before = get(ctx, "/api/work-items/#{child}/trace")
    child_before_trace = decode_trace!(child_before)
    assert child_before_trace["attribution"]["provenanceStatus"] == "from_turn"
    assert_trace_parent_matches_execution_map!(ctx, child, child_before_trace)

    insert_assignment!(ctx.db, "asg_trace_hidden_middle_hidden",
      holder: ctx.other_session.session_key,
      opener_user: "other",
      reviews_assignment_id: base,
      opened_at: 450
    )

    after_response = get(ctx, "/api/work-items/#{root}/trace")
    child_after = get(ctx, "/api/work-items/#{child}/trace")
    assert after_response.resp_body == before.resp_body
    assert child_after.resp_body == child_before.resp_body
    assert_trace_parent_matches_execution_map!(ctx, child, decode_trace!(child_after))
    refute after_response.resp_body =~ "asg_trace_hidden_middle_hidden"
    refute after_response.resp_body =~ "asg_trace_hidden_middle_second"
  end

  test "rejects paging and gives hidden and unknown roots the same not-found response", ctx do
    hidden = insert_work_item!(ctx.db, "wi_trace_hidden", "other", 60_000)

    paged = get(ctx, "/api/work-items/#{hidden}/trace?limit=1")
    assert_error(paged, 400, "invalid_filter")

    hidden_response = get(ctx, "/api/work-items/#{hidden}/trace")
    missing_response = get(ctx, "/api/work-items/wi_trace_missing/trace")
    assert_error(hidden_response, 404, "not_found")
    assert hidden_response.resp_body == missing_response.resp_body

    assert_error(get(ctx, "/api/work-items/#{hidden}/trace", "invalid-token"), 401, "auth_failed")
  end

  defp approved_device(db, device_id, name, user_id) do
    {:pending, _device} =
      Devices.pair(db, %{device_id: device_id, claimed_name: name, platform: nil, model: nil})

    Devices.approve(db, device_id, user_id)
  end

  defp assert_trace_parent_matches_execution_map!(ctx, work_item_id, trace, bearer \\ nil) do
    principal =
      if bearer == ctx.owner_session.cli_token do
        %{kind: "session", id: ctx.owner_session.session_key, is_admin: false}
      else
        %{kind: "user", id: "owner", is_admin: false}
      end

    # Compare with the node from the same query the REST route encodes; the
    # parent is independent of unrelated telemetry projection fields.
    execution_map =
      ExecutionMap.list_execution_map(ctx.db, %{
        filters: %{},
        principal: principal,
        boundary: :latest,
        limit: 500,
        work_item_id: nil,
        assignment_ids: []
      })

    node = Enum.find(execution_map.items, &(&1.id == work_item_id))
    refute is_nil(node)
    assert trace["attribution"]["provenanceStatus"] == node.parent.status
    assert trace["attribution"]["primaryWorkId"] == node.parent.item
  end

  defp insert_attest!(db, id, assignment_id, by_session, ts) do
    assert {:ok, _rows} =
             DB.query(
               db,
               "INSERT INTO attests (id, assignmentId, kind, bySession, ts) VALUES (?1, ?2, 'progress', ?3, ?4)",
               [id, assignment_id, by_session, ts]
             )
  end

  defp insert_pending_wake!(db, id, session_key, assignment_id, created_at) do
    assert {:ok, _rows} =
             DB.query(
               db,
               """
               INSERT INTO wakes
                 (wakeId, sessionKey, origin, prompt, consumer, dueAt, state, createdAt,
                  creatorSessionKey, assignmentId, class, classElection)
               VALUES (?1, ?2, ?3, 'pending trace invariance fixture', 'prompt', ?4,
                       'pending', ?5, ?2, ?6, 'fyi', 'sender')
               """,
               [
                 id,
                 session_key,
                 "session:#{session_key}",
                 created_at + 1_000,
                 created_at,
                 assignment_id
               ]
             )
  end

  defp insert_work_item!(db, id, owner, created_at, opts \\ []) do
    created_by_session = Keyword.get(opts, :created_by_session)
    created_by_user = if is_nil(created_by_session), do: owner, else: nil
    created_context_known = Keyword.get(opts, :context_known, false)
    created_in_turn_seq = Keyword.get(opts, :created_in_turn_seq)

    assert {:ok, _rows} =
             DB.query(
               db,
               """
               INSERT INTO work_items
                 (id, title, isBug, ownerUserId, state, createdByUser, createdBySession,
                  createdInTurnSeq, createdContextKnown, createdAt)
               VALUES (?1, ?2, 0, ?3, 'open', ?4, ?5, ?6, ?7, ?8)
               """,
               [
                 id,
                 "Trace #{id}",
                 owner,
                 created_by_user,
                 created_by_session,
                 created_in_turn_seq,
                 if(created_context_known, do: 1, else: 0),
                 created_at
               ]
             )

    id
  end

  defp insert_assignment!(db, id, opts) do
    opener_user = Keyword.get(opts, :opener_user)
    opener_session = Keyword.get(opts, :opener_session)

    assert {:ok, _rows} =
             DB.query(
               db,
               """
               INSERT INTO assignments
                 (id, subject, holderKey, openedByUser, openedBySession, openedAt, state,
                  workItemId, reviewsAssignmentId)
               VALUES (?1, ?2, ?3, ?4, ?5, ?6, 'open', ?7, ?8)
               """,
               [
                 id,
                 "Assignment #{id}",
                 Keyword.fetch!(opts, :holder),
                 opener_user,
                 opener_session,
                 Keyword.fetch!(opts, :opened_at),
                 Keyword.get(opts, :work_item_id),
                 Keyword.get(opts, :reviews_assignment_id)
               ]
             )

    id
  end

  defp insert_turn!(ctx, message_id, opts) do
    insert_turn_for_session!(
      ctx,
      ctx.owner_session.session_key,
      message_id,
      Keyword.get(opts, :job_ref),
      Keyword.get(opts, :assignment_id)
    )
  end

  defp insert_turn_for_session!(ctx, session_key, message_id, job_ref, assignment_id \\ nil) do
    {:ok, seq} =
      Ledger.enqueue(ctx.db, %{
        session_key: session_key,
        message_id: message_id,
        origin: "session:#{session_key}",
        prompt: "Work item trace fixture",
        assignment_id: assignment_id,
        job_ref: job_ref
      })

    seq
  end

  defp insert_hidden_turn!(db, seq, session_key, job_ref) do
    assert {:ok, _rows} =
             DB.query(
               db,
               """
               INSERT INTO turns (seq, sessionKey, messageId, origin, prompt, status, createdAt, jobRef)
               VALUES (?1, ?2, ?3, ?4, ?5, 'queued', ?6, ?7)
               """,
               [
                 seq,
                 session_key,
                 "hidden-turn-#{seq}",
                 "session:#{session_key}",
                 "Hidden",
                 70_000,
                 job_ref
               ]
             )
  end

  defp set_creation_turn!(db, id, seq) do
    assert {:ok, _rows} =
             DB.query(
               db,
               "UPDATE work_items SET createdInTurnSeq=?2, createdContextKnown=1 WHERE id=?1",
               [id, seq]
             )
  end

  defp item_version(db, id) do
    db
    |> StateResources.query_work_item(id, rest_call())
    |> Map.fetch!(:row_version)
  end

  defp assignment_version(db, id) do
    db
    |> StateResources.query_assignment(id, rest_call())
    |> StateResources.assignment()
    |> Map.fetch!("rowVersion")
  end

  defp turn_version(db, seq) do
    db
    |> StateResources.query_turn_by_seq(seq)
    |> StateResources.turn()
    |> Map.fetch!("rowVersion")
  end

  defp rest_call, do: %{rest_principal: %{kind: "user", id: "owner", is_admin: false}}

  defp expected_dependency_version(entries) do
    entries
    |> Enum.sort_by(fn [resource, key, _version] -> {resource, JSON.encode!(key)} end)
    |> JSON.encode!()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp get(ctx, path, bearer \\ nil) do
    conn(:get, path)
    |> put_req_header("authorization", "Bearer #{bearer || ctx.token}")
    |> Router.call(Router.init(ctx.opts))
  end

  defp decode_trace!(response) do
    assert response.status == 200
    assert get_resp_header(response, "content-type") == ["application/json; charset=utf-8"]
    decoded = JSON.decode!(response.resp_body)
    assert decoded["schemaVersion"] == 1
    assert decoded["resource"] == "work-item trace"
    decoded["item"]
  end

  defp assert_error(response, status, code) do
    assert response.status == status
    assert get_resp_header(response, "cache-control") == ["no-store"]
    decoded = JSON.decode!(response.resp_body)
    assert decoded["resource"] == "work-item trace"
    assert decoded["error"]["code"] == code
  end

  defp ordered_keys?(body, keys) do
    positions = Enum.map(keys, &:binary.match(body, "\"#{&1}\":"))

    Enum.all?(positions, &match?({position, _length} when is_integer(position), &1)) and
      Enum.map(positions, &elem(&1, 0)) == Enum.sort(Enum.map(positions, &elem(&1, 0)))
  end
end
