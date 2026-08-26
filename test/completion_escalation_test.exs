defmodule Tightbeam.CompletionEscalationTest do
  use Tightbeam.TestCase, async: false

  alias Tightbeam.{Assignments, ConnRegistry, DB, Gateway, Model, Org, Wakes, WorkItems}
  alias Tightbeam.Productions.CompletionEscalation

  setup do
    db = :"completion_escalation_db_#{System.unique_integer([:positive])}"
    start_supervised!({DB, path: ":memory:", name: db})
    start_supervised!({ConnRegistry, name: Tightbeam.ConnRegistry})
    :ok = Tightbeam.Schema.ensure_all(db)

    {:ok, _} =
      DB.query(
        db,
        "INSERT INTO users (userId,isAdmin,createdAt) VALUES ('owner',0,1),('other',0,1),('admin',1,1)"
      )

    main = ensure_main_session(db, "owner")
    ensure_main_session(db, "other")
    ensure_main_session(db, "admin")
    parent = session(db, "parent", "owner", main.session_key)
    child = session(db, "child", "owner", parent.session_key)
    report = session(db, "report", "owner", main.session_key)
    sibling = session(db, "sibling", "owner", main.session_key)
    foreign = session(db, "foreign", "other", Org.personal_session_key("other"))

    config = %{
      db: db,
      wake_tick_ms: 1_000,
      critical_lease_hard_cap_ms: 60_000
    }

    %{
      db: db,
      config: config,
      handlers: Gateway.handlers(config),
      main: main,
      parent: parent,
      child: child,
      report: report,
      sibling: sibling,
      foreign: foreign
    }
  end

  test "close atomically records exact parent, explicit report-to, and deadline", ctx do
    assignment = assign(ctx, report_to: ctx.report.session_key)
    complete(ctx, assignment.id)
    record = only_notice(ctx, {:user, "owner"})

    assert record.assignmentId == assignment.id
    assert record.childSessionKey == ctx.child.session_key
    assert record.cause.principal == "session:#{ctx.child.session_key}"
    assert record.routing.parent.sessionKey == ctx.parent.session_key
    assert record.routing.parent.routeStatus == "scheduled"
    assert record.routing.parent.receipt == %{state: "pending", turnSeq: nil}
    assert record.routing.reportTo.sessionKey == ctx.report.session_key
    assert record.routing.reportTo.routeStatus == "scheduled"
    assert record.routing.reportTo.sharesParentNotice == false
    assert record.request.status == "open"
    assert is_integer(record.request.deadlineAt)

    assert wake_for(ctx.db, record.id, "parent-notice").wake_id ==
             "completion:#{record.closingAttestId}:parent-notice:0"

    assert wake_for(ctx.db, record.id, "report-to-notice").wake_id ==
             "completion:#{record.closingAttestId}:report-to-notice"

    assert wake_for(ctx.db, record.id, "deadline").wake_id ==
             "completion:#{record.closingAttestId}:deadline:0"

    expected_parent_prompt =
      """
      Child completion recorded.
      completionId=#{record.id}
      assignmentId=#{assignment.id}
      workItemId=none
      childSessionKey=#{ctx.child.session_key}
      closingAttestId=#{record.closingAttestId}
      outcome=completed
      causePrincipal=session:#{ctx.child.session_key}
      immediateParentSessionKey=#{ctx.parent.session_key}
      parentRoute=spawnedBy
      reportToSessionKey=#{ctx.report.session_key}
      remainingOpenAssignments=0
      actionNeeded=true
      Choose retain, park, or retire with `tightbeam completion-disposition #{record.id} --decision <retain|park|retire>`. Tightbeam will not choose or auto-retire.
      """
      |> String.trim_trailing()

    assert wake_for(ctx.db, record.id, "parent-notice").prompt == expected_parent_prompt

    expected_report_prompt =
      """
      Child completion copied by explicit report-to.
      completionId=#{record.id}
      assignmentId=#{assignment.id}
      workItemId=none
      childSessionKey=#{ctx.child.session_key}
      closingAttestId=#{record.closingAttestId}
      outcome=completed
      causePrincipal=session:#{ctx.child.session_key}
      immediateParentSessionKey=#{ctx.parent.session_key}
      parentRoute=spawnedBy
      reportToSessionKey=#{ctx.report.session_key}
      remainingOpenAssignments=0
      actionNeeded=true
      This report is informational. Only the exact completion parent target or owner user can choose a disposition.
      """
      |> String.trim_trailing()

    assert wake_for(ctx.db, record.id, "report-to-notice").prompt == expected_report_prompt

    assert {:ok, [[3]]} =
             DB.query(ctx.db, "SELECT count(*) FROM completion_escalation_wakes")

    assert {:ok, [[1]]} =
             DB.query(
               ctx.db,
               "SELECT count(*) FROM lifecycle_events WHERE kind='completion_escalation_opened' AND subject=?1",
               [record.id]
             )
  end

  test "notice and membership failures roll back the whole close transaction", ctx do
    failures = [
      {"wakes", "NEW.wakeId LIKE '%:parent-notice:0'"},
      {"wakes", "NEW.wakeId LIKE '%:report-to-notice'"},
      {"completion_escalation_wakes", "NEW.kind = 'parent-notice'"},
      {"completion_escalation_wakes", "NEW.kind = 'report-to-notice'"}
    ]

    failures
    |> Enum.with_index()
    |> Enum.each(fn {{table, condition}, index} ->
      child = session(ctx.db, "rollback-child-#{index}", "owner", ctx.parent.session_key)

      assignment =
        assign(ctx,
          holder: child.session_key,
          report_to: ctx.report.session_key
        )

      before = rollback_snapshot(ctx.db, assignment.id)

      :ok =
        DB.execute(
          ctx.db,
          "CREATE TRIGGER abort_completion_fixture BEFORE INSERT ON #{table} WHEN #{condition} BEGIN SELECT RAISE(ABORT, 'forced completion rollback'); END"
        )

      assert_raise DB.Error, ~r/forced completion rollback/, fn ->
        complete(ctx, assignment.id, child.session_key)
      end

      assert rollback_snapshot(ctx.db, assignment.id) == before
      :ok = DB.execute(ctx.db, "DROP TRIGGER abort_completion_fixture")

      assert %{assignment: %{state: "closed"}} =
               complete(ctx, assignment.id, child.session_key)

      assert {:ok, [[1]]} =
               DB.query(
                 ctx.db,
                 "SELECT count(*) FROM completion_escalations WHERE assignmentId=?1",
                 [assignment.id]
               )
    end)
  end

  test "concurrent completion admits one close and one exact wake set", ctx do
    assignment = assign(ctx, report_to: ctx.report.session_key)

    results =
      1..2
      |> Enum.map(fn _ -> Task.async(fn -> complete(ctx, assignment.id) end) end)
      |> Task.await_many()

    assert Enum.count(results, &match?(%{assignment: %{state: "closed"}}, &1)) == 1
    assert Enum.count(results, &match?(%{code: "assignment_closed"}, &1)) == 1

    assert {:ok, [[1, 1]]} =
             DB.query(
               ctx.db,
               "SELECT count(*),count(DISTINCT closingAttestId) FROM completion_escalations WHERE assignmentId=?1",
               [assignment.id]
             )

    assert {:ok, [[3, 3]]} =
             DB.query(
               ctx.db,
               "SELECT count(*),count(DISTINCT cew.wakeId) FROM completion_escalation_wakes cew JOIN completion_escalations ce ON ce.id=cew.completionId WHERE ce.assignmentId=?1",
               [assignment.id]
             )
  end

  test "report-to validation is exact, immutable, and grants no disposition authority", ctx do
    for key <- ["missing", ctx.foreign.session_key] do
      before = assignment_count(ctx.db)
      assert %{code: "invalid_report_to", reportToSessionKey: ^key} = assign(ctx, report_to: key)
      assert assignment_count(ctx.db) == before
    end

    retired_report = session(ctx.db, "retired-report", "owner", ctx.main.session_key)
    Org.retire(ctx.db, retired_report.session_key, "user:owner", 1_000)
    assert %{code: "invalid_report_to"} = assign(ctx, report_to: retired_report.session_key)

    assignment = assign(ctx, report_to: ctx.report.session_key, key: "immutable")
    assert assign(ctx, report_to: ctx.sibling.session_key, key: "immutable") == assignment
    complete(ctx, assignment.id)
    record = only_notice(ctx, {:session, ctx.report.session_key})

    assert %{code: "not_authorized"} =
             disposition(ctx, record.id, "retain", {:session, ctx.report.session_key})

    assert only_notice(ctx, {:user, "owner"}).request.status == "open"
  end

  test "no declaration infers no opener or commission notice", ctx do
    assignment = assign(ctx)
    complete(ctx, assignment.id)
    record = only_notice(ctx, {:user, "owner"})

    assert record.routing.reportTo == nil

    assert {:ok, [[0]]} =
             DB.query(
               ctx.db,
               "SELECT count(*) FROM completion_escalation_wakes WHERE kind='report-to-notice'"
             )
  end

  test "exact parent delivery creates one real message and turn", ctx do
    assignment = assign(ctx)
    complete(ctx, assignment.id)
    record = only_notice(ctx, {:user, "owner"})
    wake = wake_for(ctx.db, record.id, "parent-notice")

    assert :appended = deliver(ctx.db, wake)
    assert :skipped = deliver(ctx.db, wake)

    delivered = only_notice(ctx, {:user, "owner"})
    assert delivered.routing.parent.receipt.state == "queued"
    assert is_integer(delivered.routing.parent.receipt.turnSeq)

    assert {:ok, [[1]]} =
             DB.query(ctx.db, "SELECT count(*) FROM turns WHERE wakeId=?1", [wake.wake_id])

    assert {:ok, [[1]]} =
             DB.query(ctx.db, "SELECT count(*) FROM messages WHERE sessionKey=?1", [
               ctx.parent.session_key
             ])
  end

  test "retired exact target is canceled in the delivery transaction without rerouting", ctx do
    assignment = assign(ctx)
    complete(ctx, assignment.id)
    record = only_notice(ctx, {:user, "owner"})
    wake = wake_for(ctx.db, record.id, "parent-notice")
    Org.retire(ctx.db, ctx.parent.session_key, "user:owner", 1_000)

    assert :skipped = deliver(ctx.db, wake)

    assert {:ok, [["canceled", "target_unresolvable", "scheduler_delivery", source]]} =
             DB.query(
               ctx.db,
               """
               SELECT w.state,c.reasonKind,c.causalSourceKind,c.causalSourceId
               FROM wakes w JOIN wake_cancellations c ON c.wakeId=w.wakeId
               WHERE w.wakeId=?1
               """,
               [wake.wake_id]
             )

    assert source == wake.wake_id

    assert {:ok, [[0]]} =
             DB.query(ctx.db, "SELECT count(*) FROM turns WHERE wakeId=?1", [wake.wake_id])

    assert {:ok, [[0]]} =
             DB.query(ctx.db, "SELECT count(*) FROM messages WHERE sessionKey=?1", [
               ctx.main.session_key
             ])
  end

  test "an inactive exact parent is recorded without climbing", ctx do
    Org.retire(ctx.db, ctx.parent.session_key, "user:owner", 1_000)
    assignment = assign(ctx)
    complete(ctx, assignment.id)
    record = only_notice(ctx, {:user, "owner"})

    assert record.routing.parent.sessionKey == ctx.parent.session_key
    assert record.routing.parent.routeStatus == "unavailable"
    assert record.routing.parent.receipt == %{state: "not-created", turnSeq: nil}
    assert record.request.status == "open"

    assert {:ok, [[detail]]} =
             DB.query(
               ctx.db,
               "SELECT detail FROM lifecycle_events WHERE kind='completion_escalation_undeliverable' AND subject=?1",
               [record.id]
             )

    assert detail ==
             "channel=parent resolution=parent-unavailable reason=parent-inactive generation=0 principal=process:tightbeam:completion-escalation"

    assert {:ok, [[0]]} =
             DB.query(
               ctx.db,
               "SELECT count(*) FROM completion_escalation_wakes WHERE completionId=?1 AND kind='parent-notice'",
               [record.id]
             )
  end

  test "retain is explicit, authorized, terminal, and replayable", ctx do
    assignment = assign(ctx, report_to: ctx.report.session_key)
    complete(ctx, assignment.id)
    record = only_notice(ctx, {:user, "owner"})

    assert %{request: %{status: "acknowledged", decision: "retain"}} =
             disposition(ctx, record.id, "retain", {:session, ctx.parent.session_key})

    assert %{request: %{status: "acknowledged", decision: "retain"}} =
             disposition(ctx, record.id, "retain", {:session, ctx.parent.session_key})

    assert %{code: "request_not_open"} = disposition(ctx, record.id, "retain", {:user, "owner"})

    assert {:ok, [[3]]} =
             DB.query(
               ctx.db,
               "SELECT count(*) FROM wake_cancellations WHERE dispositionKind='completion_transition' AND dispositionId=?1",
               [record.id]
             )
  end

  test "park remains the separately gated unavailable dependency", ctx do
    assignment = assign(ctx)
    complete(ctx, assignment.id)
    record = only_notice(ctx, {:user, "owner"})

    assert %{
             code: "park_dependency_unavailable",
             completionId: record.id,
             requestStatus: "open"
           } == disposition(ctx, record.id, "park", {:user, "owner"})

    assert only_notice(ctx, {:user, "owner"}).request.status == "open"
  end

  test "reopen supersedes history and later completion appends a new row", ctx do
    assignment = assign(ctx)
    first_attest = complete(ctx, assignment.id)
    first = only_notice(ctx, {:user, "owner"})

    reopened =
      Assignments.__handle__(ctx.db, "reopen-assignment", %{
        verb: "reopen-assignment",
        origin: "user:owner",
        principal: {:user, "owner"},
        session_key: nil,
        supervision_interval_ms: 1_000,
        params: %{assignment_id: assignment.id, reason: "recheck"}
      })

    assert reopened.state == "open"
    assert CompletionEscalation.get(ctx.db, first.id).request.status == "superseded"
    second_attest = complete(ctx, assignment.id)

    records =
      CompletionEscalation.notices(ctx.db, notice_call({:user, "owner"}, "all")).completionNotices

    assert length(records) == 2
    assert Enum.map(records, & &1.assignmentId) == [assignment.id, assignment.id]

    assert Enum.map(records, & &1.closingAttestId) == [
             first_attest.attest.id,
             second_attest.attest.id
           ]

    assert Enum.map(records, & &1.request.status) == ["superseded", "open"]
  end

  test "root Main receives a retain-only self request", ctx do
    assignment = assign(ctx, holder: ctx.main.session_key)
    complete(ctx, assignment.id, ctx.main.session_key)
    record = only_notice(ctx, {:user, "owner"})

    assert record.rootMainHolder

    assert record.routing.parent == %{
             sessionKey: ctx.main.session_key,
             routeStatus: "root-self",
             receipt: %{state: "pending", turnSeq: nil}
           }

    root_prompt = wake_for(ctx.db, record.id, "parent-notice").prompt
    assert root_prompt =~ "parentRoute=root-self"

    assert String.ends_with?(
             root_prompt,
             "Choose retain with `tightbeam completion-disposition #{record.id} --decision retain`. Tightbeam will not choose or auto-retain."
           )

    refute root_prompt =~ "park or retire"

    assert %{code: "root_lifecycle_unsupported", decision: "retire"} =
             disposition(ctx, record.id, "retire", {:session, ctx.main.session_key})

    assert %{request: %{status: "retained_root", decision: "retain"}} =
             disposition(ctx, record.id, "retain", {:session, ctx.main.session_key})
  end

  test "work remaining creates a queryable notice-only record without a deadline", ctx do
    first = assign(ctx)
    _second = assign(ctx)
    complete(ctx, first.id)
    record = only_notice(ctx, {:user, "owner"})

    assert record.remainingOpenAssignments == 1
    assert record.request.status == "notice-only"
    assert record.request.deadlineAt == nil

    assert %{code: "action_not_required"} =
             disposition(ctx, record.id, "retain", {:session, ctx.parent.session_key})

    assert {:ok, [[0]]} =
             DB.query(
               ctx.db,
               "SELECT count(*) FROM completion_escalation_wakes WHERE completionId=?1 AND kind='deadline'",
               [record.id]
             )
  end

  test "deadline reissues the same exact-parent request and replaces only its parent notice",
       ctx do
    assignment = assign(ctx, report_to: ctx.report.session_key)
    complete(ctx, assignment.id)
    first = only_notice(ctx, {:user, "owner"})
    first_parent = wake_for(ctx.db, first.id, "parent-notice")
    report_wake = wake_for(ctx.db, first.id, "report-to-notice")
    deadline = wake_for(ctx.db, first.id, "deadline")

    assert {:ok, :ok} =
             DB.transaction(ctx.db, fn txn ->
               CompletionEscalation.reissue_in_txn(txn, deadline.wake_id)
             end)

    second = only_notice(ctx, {:user, "owner"})
    assert second.request.generation == 1
    assert second.routing.parent.receipt.state == "pending"
    assert Wakes.get(ctx.db, first_parent.wake_id).state == "canceled"
    assert Wakes.get(ctx.db, report_wake.wake_id).state == "pending"
    assert Wakes.get(ctx.db, deadline.wake_id).state == "fired"

    assert {:ok, [["superseded", replacement]]} =
             DB.query(
               ctx.db,
               "SELECT reasonKind,replacementWakeId FROM wake_cancellations WHERE wakeId=?1",
               [first_parent.wake_id]
             )

    assert is_binary(replacement)
  end

  test "new assignment supersedes the request atomically", ctx do
    assignment = assign(ctx)
    complete(ctx, assignment.id)
    first = only_notice(ctx, {:user, "owner"})
    new_assignment = assign(ctx)
    superseded = CompletionEscalation.get(ctx.db, first.id)

    assert superseded.request.status == "superseded"
    assert superseded.request.supersededReason == "new-assignment"
    assert superseded.request.supersededByAssignmentId == new_assignment.id
  end

  test "owner-selected retire acknowledges and retires in one transaction", ctx do
    assignment = assign(ctx)
    complete(ctx, assignment.id)
    record = only_notice(ctx, {:user, "owner"})

    assert %{request: %{status: "acknowledged", decision: "retire"}} =
             disposition(ctx, record.id, "retire", {:user, "owner"})

    assert Org.get(ctx.db, ctx.child.session_key).state == "retired"
  end

  test "completion retire defers without scheduling a generic intent wake", ctx do
    assignment = assign(ctx)
    complete(ctx, assignment.id)
    record = only_notice(ctx, {:user, "owner"})

    assert %{expires_at: _} =
             ctx.handlers["critical"].(%{
               principal: {:session, ctx.child.session_key},
               params: %{for_ms: 30_000, reason: "finish critical section"}
             })

    assert %{code: "retire_deferred", requestStatus: "open", deferred: deferred} =
             disposition(ctx, record.id, "retire", {:user, "owner"})

    assert deferred != []
    assert Org.get(ctx.db, ctx.child.session_key).state == "active"
    assert CompletionEscalation.get(ctx.db, record.id).request.status == "open"

    assert {:ok, [[0]]} =
             DB.query(ctx.db, "SELECT count(*) FROM wakes WHERE wakeId LIKE 'w_retire_%'")
  end

  test "pending generic-retire intent defers every completion decision", ctx do
    assignment = assign(ctx)
    complete(ctx, assignment.id)
    record = only_notice(ctx, {:user, "owner"})

    ctx.handlers["critical"].(%{
      principal: {:session, ctx.child.session_key},
      params: %{for_ms: 30_000, reason: "finish critical section"}
    })

    assert %{retired_session_keys: [], deferred: [_ | _]} =
             ctx.handlers["retire"].(%{
               origin: "user:owner",
               principal: {:user, "owner"},
               session_key: ctx.child.session_key,
               params: %{}
             })

    for decision <- ~w(retain park retire) do
      assert %{code: "retire_deferred", requestStatus: "open"} =
               disposition(ctx, record.id, decision, {:user, "owner"})
    end

    assert CompletionEscalation.get(ctx.db, record.id).request.status == "open"
  end

  test "read visibility and disposition authority remain separate", ctx do
    assignment = assign(ctx, report_to: ctx.report.session_key)
    complete(ctx, assignment.id)
    record = only_notice(ctx, {:user, "owner"})

    for principal <- [
          {:user, "admin"},
          {:session, ctx.child.session_key},
          {:session, ctx.parent.session_key},
          {:session, ctx.report.session_key}
        ] do
      assert %{completionNotices: [%{id: id}]} =
               CompletionEscalation.notices(ctx.db, notice_call(principal, "all"))

      assert id == record.id
    end

    assert %{completionNotices: []} =
             CompletionEscalation.notices(
               ctx.db,
               notice_call({:session, ctx.sibling.session_key}, "all")
             )

    assert %{code: "not_authorized"} =
             disposition(ctx, record.id, "retain", {:session, ctx.sibling.session_key})

    assert %{code: "principal_not_allowed"} =
             disposition(ctx, record.id, "retain", {:process, "tightbeam"})
  end

  test "cross-owner spawnedBy fails closed and remains diagnostic", ctx do
    {:ok, _} =
      DB.query(ctx.db, "UPDATE sessions SET spawnedBy=?2 WHERE sessionKey=?1", [
        ctx.child.session_key,
        ctx.foreign.session_key
      ])

    assignment = assign(ctx)
    complete(ctx, assignment.id)
    record = only_notice(ctx, {:user, "owner"})

    assert record.routing.parent.sessionKey == ctx.foreign.session_key
    assert record.routing.parent.routeStatus == "unavailable"

    assert %{completionNotices: []} =
             CompletionEscalation.notices(ctx.db, notice_call({:user, "other"}, "all"))

    assert %{completionNotices: []} =
             CompletionEscalation.notices(
               ctx.db,
               notice_call({:session, ctx.foreign.session_key}, "all")
             )

    assert {:ok, [[detail]]} =
             DB.query(
               ctx.db,
               "SELECT detail FROM lifecycle_events WHERE kind='completion_escalation_cross_owner_lineage' AND subject=?1",
               [record.id]
             )

    assert detail ==
             "parentSessionKey=#{ctx.foreign.session_key} principal=process:tightbeam:completion-escalation"

    assert {:ok, [[0]]} =
             DB.query(
               ctx.db,
               "SELECT count(*) FROM completion_escalation_wakes WHERE completionId=?1 AND kind='parent-notice'",
               [record.id]
             )
  end

  test "completion table mutation remains behind one production seam" do
    root = Path.expand("../lib", __DIR__)
    owner = Path.join(root, "tightbeam/productions/completion_escalation.ex")
    production = File.read!(owner)
    assignments = File.read!(Path.join(root, "tightbeam/assignments.ex"))
    gateway = File.read!(Path.join(root, "tightbeam/gateway.ex"))
    router = File.read!(Path.join(root, "tightbeam/wire/router.ex"))

    offenders =
      root
      |> Path.join("**/*.ex")
      |> Path.wildcard()
      |> Enum.reject(&(&1 == owner))
      |> Enum.filter(fn path ->
        File.read!(path) =~
          ~r/(INSERT\s+INTO|UPDATE)\s+completion_escalations|INSERT\s+INTO\s+completion_escalation_wakes/i
      end)

    assert offenders == []

    assert length(Regex.scan(~r/CompletionEscalation\.open_in_txn/, assignments)) == 1

    assert length(
             Regex.scan(
               ~r/CompletionEscalation\.supersede_open_for_assignment_in_txn/,
               assignments
             )
           ) == 2

    assert production =~ "Wakes.cancel_in_txn"
    assert production =~ "Wakes.fire_internal_in_txn"
    refute production =~ ~r/UPDATE\s+wakes\s+SET\s+state/i

    assert Regex.scan(~r/reason_kind:\s+"([^"]+)"/, production, capture: :all_but_first)
           |> List.flatten()
           |> Enum.uniq()
           |> Enum.sort() == ~w(obligation_disposed superseded target_unresolvable)

    refute production =~ "lifecycle_event"
    refute production =~ "openedBySession"
    refute production =~ "openedByUser"
    assert gateway =~ "\"completion_disposition_deadline\" => &CompletionEscalation.reissue"
    assert gateway =~ "CompletionEscalation.acknowledge_retire_in_txn"
    assert router =~ "principal: {:user, device.user_id}"
  end

  test "work-item trace includes completion history, lifecycle, and member wakes", ctx do
    item =
      WorkItems.__handle__(ctx.db, "work-item-create", %{
        verb: "work-item-create",
        origin: "user:owner",
        principal: {:user, "owner"},
        session_key: nil,
        params: %{title: "trace completion"}
      })

    assignment =
      assign(ctx,
        work_item: item.id,
        report_to: ctx.report.session_key
      )

    complete(ctx, assignment.id)
    record = only_notice(ctx, {:user, "owner"})

    assert %{request: %{status: "acknowledged", decision: "retain"}} =
             disposition(ctx, record.id, "retain", {:session, ctx.parent.session_key})

    trace =
      WorkItems.__handle__(ctx.db, "work-item-trace", %{
        verb: "work-item-trace",
        origin: "user:owner",
        principal: {:user, "owner"},
        session_key: nil,
        params: %{work_item_id: item.id}
      })

    completion_entries = Enum.filter(trace.timeline, &(&1.type == "completion_escalation"))
    assert Enum.map(completion_entries, & &1.phase) == ["opened", "acknowledged"]

    lifecycle_entries =
      Enum.filter(trace.timeline, &(&1.type == "completion_escalation_event"))

    assert Enum.map(lifecycle_entries, & &1.kind) == [
             "completion_escalation_opened",
             "completion_escalation_acknowledged"
           ]

    member_wake_ids =
      for kind <- ~w(parent-notice report-to-notice deadline),
          do: wake_for(ctx.db, record.id, kind).wake_id

    assert trace.timeline
           |> Enum.filter(&(&1.type == "wake_canceled" and &1.id in member_wake_ids))
           |> Enum.map(& &1.id)
           |> Enum.sort() == Enum.sort(member_wake_ids)
  end

  defp assign(ctx, opts \\ []) do
    holder = Keyword.get(opts, :holder, ctx.child.session_key)

    params = %{
      subject: "completion work",
      idempotency_key: Keyword.get(opts, :key),
      work_item_id: Keyword.get(opts, :work_item),
      report_to_session_key: Keyword.get(opts, :report_to)
    }

    Assignments.__handle__(ctx.db, "assign", %{
      verb: "assign",
      origin: "user:owner",
      principal: {:user, "owner"},
      session_key: holder,
      target_role: nil,
      role_fallback: false,
      supervision_interval_ms: 1_000,
      params: params
    })
  end

  defp complete(ctx, assignment_id, session_key \\ nil) do
    session_key = session_key || ctx.child.session_key

    Assignments.__handle__(ctx.db, "attest", %{
      verb: "attest",
      origin: "agent:holder",
      principal: {:session, session_key},
      session_key: nil,
      params: %{assignment_id: assignment_id, kind: "completion"}
    })
  end

  defp disposition(ctx, completion_id, decision, principal) do
    ctx.handlers["completion-disposition"].(%{
      verb: "completion-disposition",
      origin: origin(principal),
      principal: principal,
      session_key: nil,
      params: %{completion_id: completion_id, decision: decision}
    })
  end

  defp only_notice(ctx, principal) do
    assert %{completionNotices: [record]} =
             CompletionEscalation.notices(ctx.db, notice_call(principal, "all"))

    record
  end

  defp notice_call(principal, status) do
    %{
      verb: "completion-notices",
      origin: origin(principal),
      principal: principal,
      session_key: nil,
      params: %{status: status}
    }
  end

  defp wake_for(db, completion_id, kind) do
    {:ok, [[wake_id]]} =
      DB.query(
        db,
        "SELECT wakeId FROM completion_escalation_wakes WHERE completionId=?1 AND kind=?2",
        [completion_id, kind]
      )

    Wakes.get(db, wake_id)
  end

  defp deliver(db, wake) do
    {:ok, result} =
      DB.transaction(db, fn txn ->
        Gateway.deliver_prompt_in_txn(txn, wake.session_key, wake.origin, wake.prompt,
          db: db,
          wake_id: wake.wake_id,
          sender: wake.origin,
          principal: {:process, "tightbeam"},
          target_gate: wake,
          fire_wake_in_txn: true
        )
      end)

    case result do
      {:appended, _owner, _message, _opts} -> :appended
      {:duplicate, _message} -> :duplicate
      other -> other
    end
  end

  defp assignment_count(db) do
    {:ok, [[count]]} = DB.query(db, "SELECT count(*) FROM assignments")
    count
  end

  defp rollback_snapshot(db, assignment_id) do
    {:ok, [assignment]} =
      DB.query(
        db,
        "SELECT state,outcome,closedAt,closingAttestId FROM assignments WHERE id=?1",
        [assignment_id]
      )

    {:ok, [[attests]]} =
      DB.query(db, "SELECT count(*) FROM attests WHERE assignmentId=?1", [assignment_id])

    {:ok, [[completions]]} =
      DB.query(db, "SELECT count(*) FROM completion_escalations WHERE assignmentId=?1", [
        assignment_id
      ])

    {:ok, [[completion_wakes]]} =
      DB.query(
        db,
        "SELECT count(*) FROM completion_escalation_wakes cew JOIN completion_escalations ce ON ce.id=cew.completionId WHERE ce.assignmentId=?1",
        [assignment_id]
      )

    {assignment, attests, completions, completion_wakes}
  end

  defp session(db, key, owner, spawned_by) do
    Org.create(db, %{
      session_key: key,
      display_name: key,
      owner_user_id: owner,
      origin: "user:#{owner}",
      spawned_by: spawned_by,
      archetype: "default",
      harness: "claude",
      provider: "anthropic",
      model: Model.new("fable"),
      host: "gibson"
    })
  end

  defp origin({:session, key}), do: "agent:#{key}"
  defp origin({:user, user}), do: "user:#{user}"
  defp origin({:process, process}), do: "process:#{process}"
end
