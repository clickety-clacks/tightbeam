defmodule Tightbeam.CompletionEscalationTest do
  use Tightbeam.TestCase, async: false

  import Plug.Conn
  import Plug.Test

  alias Tightbeam.{
    Assignments,
    ConnRegistry,
    DB,
    Gateway,
    Model,
    Org,
    Placement,
    Toplines,
    Wakes,
    WorkItems
  }

  alias Tightbeam.Productions.CompletionEscalation
  alias Tightbeam.Wire.Router

  setup do
    db = :"completion_escalation_db_#{System.unique_integer([:positive])}"
    start_supervised!({DB, path: ":memory:", name: db})
    start_supervised!({ConnRegistry, name: Tightbeam.ConnRegistry})
    :ok = Tightbeam.Schema.ensure_all(db)
    assert {:ok, _} = Placement.register_host(db, "gibson", %{ssh: "gibson", base_dir: "/tmp"})

    {:ok, _} =
      DB.query(
        db,
        "INSERT INTO users (userId,isAdmin,creationKind,createdAt) VALUES ('owner',0,'admin_add',1),('other',0,'admin_add',1),('admin',1,'admin_add',1)"
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
    assert record.request.currentRecipient == "session:#{ctx.parent.session_key}"
    assert record.request.recipientGeneration == 0
    assert record.request.recipientReissueCount == 0
    assert record.request.recipientReissueLimit == 3

    assert wake_for(ctx.db, record.id, "parent-notice").wake_id ==
             "completion:attest:#{record.closingAttestId}:parent-notice:0"

    assert wake_for(ctx.db, record.id, "report-to-notice").wake_id ==
             "completion:attest:#{record.closingAttestId}:report-to-notice"

    assert wake_for(ctx.db, record.id, "deadline").wake_id ==
             "completion:attest:#{record.closingAttestId}:deadline:0"

    expected_parent_prompt =
      """
      Child assignment slate became empty.
      completionId=#{record.id}
      assignmentId=#{assignment.id}
      workItemId=none
      childSessionKey=#{ctx.child.session_key}
      causeKind=attest
      causeId=#{record.closingAttestId}
      closingAttestId=#{record.closingAttestId}
      revocationId=none
      outcome=completed
      causePrincipal=session:#{ctx.child.session_key}
      immediateParentSessionKey=#{ctx.parent.session_key}
      parentResolutionSource=explicit
      parentRoute=effective-parent
      reportToSessionKey=#{ctx.report.session_key}
      remainingOpenAssignments=0
      actionNeeded=true
      recipientPrincipal=session:#{ctx.parent.session_key}
      recipientGeneration=0
      recipientReissueCount=0
      recipientReissueLimit=3
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
      parentResolutionSource=explicit
      parentRoute=effective-parent
      reportToSessionKey=#{ctx.report.session_key}
      remainingOpenAssignments=0
      actionNeeded=true
      This report is informational. It grants no disposition authority.
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

    assert {:ok, [[nil]]} =
             DB.query(
               ctx.db,
               "SELECT detail FROM lifecycle_events WHERE kind='completion_escalation_opened' AND subject=?1",
               [record.id]
             )
  end

  test "notice and membership failures roll back the whole close transaction", ctx do
    failures = [
      {"completion_escalations", "1"},
      {"wakes", "NEW.wakeId LIKE '%:parent-notice:0'"},
      {"wakes", "NEW.wakeId LIKE '%:report-to-notice'"},
      {"wakes", "NEW.wakeId LIKE '%:deadline:0'"},
      {"completion_escalation_wakes", "NEW.kind = 'parent-notice'"},
      {"completion_escalation_wakes", "NEW.kind = 'report-to-notice'"},
      {"completion_escalation_wakes", "NEW.kind = 'deadline'"},
      {"lifecycle_events", "NEW.kind = 'completion_escalation_opened'"}
    ]

    failures
    |> Enum.with_index()
    |> Enum.each(fn {{table, condition}, index} ->
      child = session(ctx.db, "rollback-child-#{index}", "owner", ctx.parent.session_key)

      item =
        WorkItems.__handle__(ctx.db, "work-item-create", %{
          verb: "work-item-create",
          origin: "user:owner",
          principal: {:user, "owner"},
          session_key: nil,
          params: %{title: "rollback fixture #{index}"}
        })

      assignment =
        assign(ctx,
          holder: child.session_key,
          work_item: item.id,
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

  test "partial unique index refuses a second open row for one child", ctx do
    first = assign(ctx)
    _spare = progress(ctx, first.id)
    complete(ctx, first.id)
    record = only_notice(ctx, {:user, "owner"})

    {:ok, columns} = DB.query(ctx.db, "PRAGMA table_info(completion_escalations)")
    names = Enum.map(columns, &Enum.at(&1, 1))

    projection =
      Enum.map_join(names, ",", fn
        "id" -> "'ce_corrupt_open'"
        "dedupeKey" -> "'terminal:attest:att_corrupt_open'"
        "causeId" -> "'att_corrupt_open'"
        "closingAttestId" -> "'att_corrupt_open'"
        name -> ~s("#{name}")
      end)

    # The corruption probe isolates the partial index from the two unrelated
    # foreign/closing-attest constraints. It restores FK enforcement before it
    # observes any product behavior.
    assert :ok = DB.execute(ctx.db, "PRAGMA foreign_keys=OFF")

    assert {:error, %DB.Error{message: message}} =
             DB.query(
               ctx.db,
               "INSERT INTO completion_escalations (#{Enum.map_join(names, ",", &~s("#{&1}"))}) SELECT #{projection} FROM completion_escalations WHERE id=?1",
               [record.id]
             )

    assert message =~ "completion_escalations.childSessionKey"
    assert :ok = DB.execute(ctx.db, "PRAGMA foreign_keys=ON")
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

  test "dispatch rejects missing, inactive, and foreign report-to without a card", ctx do
    retired = session(ctx.db, "dispatch-retired-report", "owner", ctx.main.session_key)
    Org.retire(ctx.db, retired.session_key, "user:owner", 1_000)

    for key <- ["dispatch-missing", retired.session_key, ctx.foreign.session_key] do
      before = assignment_count(ctx.db)
      assert %{code: "invalid_report_to", reportToSessionKey: ^key} = dispatch(ctx, key)
      assert assignment_count(ctx.db) == before
    end
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

  test "report-to equal to exact parent shares the parent wake", ctx do
    assignment = assign(ctx, report_to: ctx.parent.session_key)
    complete(ctx, assignment.id)
    record = only_notice(ctx, {:user, "owner"})

    assert record.routing.reportTo == %{
             sessionKey: ctx.parent.session_key,
             routeStatus: "shared-parent",
             sharesParentNotice: true,
             receipt: record.routing.parent.receipt
           }

    assert {:ok, [[1, 0]]} =
             DB.query(
               ctx.db,
               "SELECT sum(kind='parent-notice'),sum(kind='report-to-notice') FROM completion_escalation_wakes WHERE completionId=?1",
               [record.id]
             )
  end

  test "explicit commission leaves work parentage and Toplines byte-identical", ctx do
    item =
      WorkItems.__handle__(ctx.db, "work-item-create", %{
        verb: "work-item-create",
        origin: "user:owner",
        principal: {:user, "owner"},
        session_key: nil,
        params: %{title: "A7 topology fixture"}
      })

    topline =
      Toplines.create(ctx.db, %{
        verb: "topline-create",
        origin: "user:owner",
        principal: {:user, "owner"},
        session_key: nil,
        params: %{title: "A7 Topline", idempotency_key: "a7-topline"}
      })

    Toplines.link_work(ctx.db, %{
      verb: "topline-link-work",
      origin: "user:owner",
      principal: {:user, "owner"},
      session_key: nil,
      params: %{
        topline_id: topline.topline.id,
        work_item_id: item.id,
        reason: "A7 completion topology",
        idempotency_key: "a7-link"
      }
    })

    assignment =
      assign(ctx,
        work_item: item.id,
        report_to: ctx.report.session_key,
        principal: {:session, ctx.sibling.session_key}
      )

    topology_before = topology_snapshot(ctx.db, assignment.id)
    toplines_before = toplines_bytes(ctx.db)

    complete(ctx, assignment.id)
    record = only_notice(ctx, {:user, "owner"})

    assert record.routing.parent.sessionKey == ctx.parent.session_key
    assert record.routing.reportTo.sessionKey == ctx.report.session_key
    assert record.routing.reportTo.sharesParentNotice == false
    assert topology_snapshot(ctx.db, assignment.id) == topology_before
    assert toplines_bytes(ctx.db) == toplines_before
  end

  test "dangling exact parent commits diagnostics while foreign keys stay enabled", ctx do
    missing_parent = "missing-parent-a8"

    assert :ok = DB.execute(ctx.db, "PRAGMA foreign_keys=OFF")

    assert {:ok, _} =
             DB.query(
               ctx.db,
               "UPDATE sessions SET spawnedBy=?2,operationalParent=?2 WHERE sessionKey=?1",
               [ctx.child.session_key, missing_parent]
             )

    assert :ok = DB.execute(ctx.db, "PRAGMA foreign_keys=ON")
    assert {:ok, [[1]]} = DB.query(ctx.db, "PRAGMA foreign_keys")

    assignment = assign(ctx)
    complete(ctx, assignment.id)
    record = only_notice(ctx, {:user, "owner"})

    assert record.routing.parent.sessionKey == missing_parent
    assert record.routing.parent.routeStatus == "unavailable"
    assert record.routing.parent.receipt == %{state: "not-created", turnSeq: nil}
    assert record.request.status == "open"

    assert {:ok, [[^missing_parent, ^missing_parent]]} =
             DB.query(
               ctx.db,
               "SELECT immediateParentSessionKey,parentSessionKey FROM completion_escalations WHERE id=?1",
               [record.id]
             )

    assert {:ok, [[1]]} =
             DB.query(
               ctx.db,
               "SELECT count(*) FROM completion_escalation_wakes WHERE completionId=?1 AND kind='parent-notice'",
               [record.id]
             )

    assert {:ok, [[1]]} = DB.query(ctx.db, "PRAGMA foreign_keys")
  end

  test "authenticated device retirement propagates its typed user principal", ctx do
    token = "tbt_a14_completion_device_token"

    assert {:ok, _} =
             DB.query(
               ctx.db,
               "INSERT INTO devices (deviceId,userId,claimedName,status,token,createdAt) VALUES ('a14-device','owner','Owner','allowlisted',?1,1)",
               [token]
             )

    child = session(ctx.db, "a14-device-child", "owner", ctx.parent.session_key)
    descendant = session(ctx.db, "a14-device-descendant", "owner", child.session_key)
    completion_assignment = assign(ctx, holder: child.session_key)
    complete(ctx, completion_assignment.id, child.session_key)
    record = only_notice_for(ctx, {:user, "owner"}, completion_assignment.id)
    interrupted = assign(ctx, holder: descendant.session_key)

    real_retire = ctx.handlers["retire"]
    caller = self()

    handlers =
      Map.put(ctx.handlers, "retire", fn call ->
        send(caller, {:device_retire_call, call})
        real_retire.(call)
      end)

    opts =
      Router.init(
        db: ctx.db,
        handlers: handlers,
        cli_token: "unused",
        defaults: %{},
        session_status: fn _ -> nil end
      )

    response =
      conn(:delete, "/api/streams/#{child.session_key}", JSON.encode!(%{}))
      |> put_req_header("authorization", "Bearer #{token}")
      |> Router.call(opts)

    assert response.status == 200

    assert_receive {:device_retire_call,
                    %{
                      verb: "retire",
                      origin: "user:owner",
                      principal: {:user, "owner"},
                      session_key: key
                    }}

    assert key == child.session_key

    assert {:ok, [["acknowledged", "retire", "owner", nil]]} =
             DB.query(
               ctx.db,
               "SELECT status,decision,actedByUser,actedBySession FROM completion_escalations WHERE id=?1",
               [record.id]
             )

    assert {:ok, [[1]]} =
             DB.query(
               ctx.db,
               "SELECT count(*) FROM assignment_revocations WHERE assignmentId=?1",
               [interrupted.id]
             )

    assert {:ok, [["acknowledged", "retire", "owner", nil]]} =
             DB.query(
               ctx.db,
               "SELECT status,decision,actedByUser,actedBySession FROM completion_escalations WHERE assignmentId=?1",
               [interrupted.id]
             )

    assert {:ok, [["process", "tightbeam:completion-escalation"]]} =
             DB.query(
               ctx.db,
               "SELECT DISTINCT requesterKind,requesterId FROM wake_cancellations WHERE causalSourceKind='completion_transition' AND causalSourceId=?1",
               [record.id]
             )

    assert {:ok, [[detail]]} =
             DB.query(
               ctx.db,
               "SELECT detail FROM lifecycle_events WHERE kind='completion_escalation_acknowledged' AND subject=?1",
               [record.id]
             )

    assert detail == "decision=retire"

    assert Org.get(ctx.db, child.session_key).state == "retired"
    assert Org.get(ctx.db, descendant.session_key).state == "retired"

    spoofed = session(ctx.db, "a14-spoofed-origin", "owner", ctx.parent.session_key)
    spoofed_interrupted = assign(ctx, holder: spoofed.session_key)

    assert %{deleted_session_key: key} =
             real_retire.(%{
               verb: "retire",
               origin: "user:other",
               principal: {:user, "owner"},
               session_key: spoofed.session_key,
               params: %{}
             })

    assert key == spoofed.session_key

    assert {:ok, [["owner", "decision=retire"]]} =
             DB.query(
               ctx.db,
               "SELECT ce.actedByUser,le.detail FROM completion_escalations ce JOIN lifecycle_events le ON le.subject=ce.id AND le.kind='completion_escalation_acknowledged' WHERE ce.assignmentId=?1",
               [spoofed_interrupted.id]
             )

    assert {:ok, [["owner", nil, "owner", nil]]} =
             DB.query(
               ctx.db,
               """
               SELECT r.revokedByUser,r.revokedBySession,a.closedByUser,a.closedBySession
               FROM assignment_revocations r JOIN assignments a ON a.id=r.assignmentId
               WHERE r.assignmentId=?1
               """,
               [spoofed_interrupted.id]
             )

    refused = session(ctx.db, "a14-missing-principal", "owner", ctx.parent.session_key)
    refused_assignment = assign(ctx, holder: refused.session_key)
    complete(ctx, refused_assignment.id, refused.session_key)
    refused_record = only_notice_for(ctx, {:user, "owner"}, refused_assignment.id)
    before = generic_retire_snapshot(ctx.db, refused_record.id, refused_assignment.id)

    assert %{code: "not_found"} =
             real_retire.(%{
               verb: "retire",
               origin: "user:owner",
               principal: nil,
               session_key: refused.session_key,
               params: %{idempotency_key: "a14-refused"}
             })

    assert generic_retire_snapshot(ctx.db, refused_record.id, refused_assignment.id) == before
  end

  test "null parent selects owner Main and inactive report-to stays independent", ctx do
    assert {:ok, _} =
             DB.query(
               ctx.db,
               "UPDATE sessions SET spawnedBy=NULL,operationalParent=NULL WHERE sessionKey=?1",
               [
                 ctx.child.session_key
               ]
             )

    assignment = assign(ctx, report_to: ctx.report.session_key)
    Org.retire(ctx.db, ctx.report.session_key, "user:owner", 1_000)
    complete(ctx, assignment.id)
    record = only_notice(ctx, {:user, "owner"})

    assert record.routing.parent.sessionKey == ctx.main.session_key
    assert record.routing.parent.resolutionSource == "owner_main"
    assert record.routing.parent.routeStatus == "scheduled"
    assert record.routing.reportTo.routeStatus == "unavailable"
    assert record.routing.reportTo.receipt == %{state: "not-created", turnSeq: nil}
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

  test "notice-only receipt projects real turn terminals and fired-without-turn dirt", ctx do
    for status <- ~w(running delivered failed failed_unknown) do
      child = session(ctx.db, "receipt-#{status}", "owner", ctx.parent.session_key)
      first = assign(ctx, holder: child.session_key)
      _remaining = assign(ctx, holder: child.session_key)
      complete(ctx, first.id, child.session_key)
      record = only_notice_for(ctx, {:user, "owner"}, first.id)
      wake = wake_for(ctx.db, record.id, "parent-notice")
      assert :appended = deliver(ctx.db, wake)

      assert {:ok, _} =
               DB.query(
                 ctx.db,
                 "UPDATE turns SET status=?2,endedAt=CASE WHEN ?2='running' THEN NULL ELSE ?3 END WHERE wakeId=?1",
                 [wake.wake_id, status, System.system_time(:millisecond)]
               )

      assert CompletionEscalation.get(ctx.db, record.id).routing.parent.receipt.state == status
      assert CompletionEscalation.get(ctx.db, record.id).request.status == "notice-only"
    end

    child = session(ctx.db, "receipt-fired-dirt", "owner", ctx.parent.session_key)
    first = assign(ctx, holder: child.session_key)
    _remaining = assign(ctx, holder: child.session_key)
    complete(ctx, first.id, child.session_key)
    record = only_notice_for(ctx, {:user, "owner"}, first.id)
    wake = wake_for(ctx.db, record.id, "parent-notice")

    assert {:ok, _} =
             DB.query(ctx.db, "UPDATE wakes SET state='fired' WHERE wakeId=?1", [wake.wake_id])

    before = lifecycle_count(ctx.db, record.id)

    assert CompletionEscalation.get(ctx.db, record.id).routing.parent.receipt.state ==
             "inconsistent"

    assert CompletionEscalation.get(ctx.db, record.id).routing.parent.receipt.state ==
             "inconsistent"

    assert lifecycle_count(ctx.db, record.id) == before
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

  test "retired exact target never inspects or delivers to a foreign ancestor", ctx do
    assert {:ok, _} =
             DB.query(ctx.db, "UPDATE sessions SET spawnedBy=?2 WHERE sessionKey=?1", [
               ctx.parent.session_key,
               ctx.foreign.session_key
             ])

    assignment = assign(ctx)
    complete(ctx, assignment.id)
    record = only_notice(ctx, {:user, "owner"})
    wake = wake_for(ctx.db, record.id, "parent-notice")
    Org.retire(ctx.db, ctx.parent.session_key, "user:owner", 1_000)

    assert :skipped = deliver(ctx.db, wake)

    assert CompletionEscalation.get(ctx.db, record.id).routing.parent.sessionKey ==
             ctx.parent.session_key

    assert {:ok, [[0]]} =
             DB.query(ctx.db, "SELECT count(*) FROM messages WHERE sessionKey IN (?1,?2)", [
               ctx.foreign.session_key,
               ctx.main.session_key
             ])
  end

  test "an inactive exact parent is preserved while the request climbs", ctx do
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

    assert {:ok, [[1]]} =
             DB.query(
               ctx.db,
               "SELECT count(*) FROM completion_escalation_wakes WHERE completionId=?1 AND kind='parent-notice'",
               [record.id]
             )
  end

  test "file-backed restart boot tick delivers the durable parent notice" do
    suffix = System.unique_integer([:positive])
    db = String.to_atom("completion_restart_db_#{suffix}")
    scheduler = String.to_atom("completion_restart_wakes_#{suffix}")
    path = Path.join(System.tmp_dir!(), "tightbeam-completion-restart-#{suffix}.sqlite3")
    on_exit(fn -> File.rm(path) end)

    db_child = %{id: db, start: {DB, :start_link, [[path: path, name: db]]}}
    start_supervised!(db_child)
    :ok = Tightbeam.Schema.ensure_all(db)
    assert {:ok, _} = Placement.register_host(db, "gibson", %{ssh: "gibson", base_dir: "/tmp"})

    assert {:ok, _} =
             DB.query(
               db,
               "INSERT INTO users (userId,isAdmin,creationKind,createdAt) VALUES ('restart-owner',0,'admin_add',1)"
             )

    main = ensure_main_session(db, "restart-owner")
    parent = session(db, "restart-parent", "restart-owner", main.session_key)
    child = session(db, "restart-child", "restart-owner", parent.session_key)

    restart_ctx = %{
      db: db,
      child: child,
      handlers: Gateway.handlers(%{db: db, wake_tick_ms: 25, critical_lease_hard_cap_ms: 60_000})
    }

    assignment = assign(restart_ctx, holder: child.session_key)
    complete(restart_ctx, assignment.id, child.session_key)
    record = only_notice(restart_ctx, {:user, "restart-owner"})
    wake = wake_for(db, record.id, "parent-notice")
    assert Wakes.get(db, wake.wake_id).state == "pending"

    stop_supervised!(db)
    start_supervised!(db_child)

    deliver = fn due -> deliver(db, due) end

    start_supervised!(%{
      id: scheduler,
      start:
        {Wakes, :start_link,
         [[db: db, deliver: deliver, internal_consumers: %{}, tick_ms: 25, name: scheduler]]}
    })

    assert eventually(fn ->
             match?(
               {:ok, [["fired", 1]]},
               DB.query(
                 db,
                 "SELECT w.state,count(t.seq) FROM wakes w LEFT JOIN turns t ON t.wakeId=w.wakeId WHERE w.wakeId=?1 GROUP BY w.state",
                 [wake.wake_id]
               )
             )
           end)

    assert {:ok, [[1]]} =
             DB.query(db, "SELECT count(*) FROM completion_escalations WHERE id=?1", [record.id])
  end

  test "scheduler retries pre-acceptance failure and dedupes legacy pending residue", ctx do
    assignment = assign(ctx)
    complete(ctx, assignment.id)
    record = only_notice(ctx, {:user, "owner"})
    wake = wake_for(ctx.db, record.id, "parent-notice")
    suffix = System.unique_integer([:positive])
    gate = String.to_atom("completion_delivery_gate_#{suffix}")
    scheduler = String.to_atom("completion_retry_wakes_#{suffix}")
    start_supervised!(%{id: gate, start: {Agent, :start_link, [fn -> :closed end, [name: gate]]}})

    deliver = fn due ->
      if Agent.get(gate, & &1) == :closed, do: raise("delivery dependency unavailable")
      deliver(ctx.db, due)
    end

    start_supervised!(%{
      id: scheduler,
      start:
        {Wakes, :start_link,
         [
           [
             db: ctx.db,
             deliver: deliver,
             internal_consumers: %{},
             tick_ms: 60_000,
             name: scheduler
           ]
         ]}
    })

    :ok = Wakes.fire_due(scheduler)
    assert Wakes.get(ctx.db, wake.wake_id).state == "pending"

    assert {:ok, [[0]]} =
             DB.query(ctx.db, "SELECT count(*) FROM turns WHERE wakeId=?1", [wake.wake_id])

    Agent.update(gate, fn _ -> :open end)
    :ok = Wakes.fire_due(scheduler)
    assert Wakes.get(ctx.db, wake.wake_id).state == "fired"

    assert {:ok, [[1]]} =
             DB.query(ctx.db, "SELECT count(*) FROM turns WHERE wakeId=?1", [wake.wake_id])

    assert {:ok, _} =
             DB.query(ctx.db, "UPDATE wakes SET state='pending',firedAt=NULL WHERE wakeId=?1", [
               wake.wake_id
             ])

    :ok = Wakes.fire_due(scheduler)
    assert Wakes.get(ctx.db, wake.wake_id).state == "fired"

    assert {:ok, [[1]]} =
             DB.query(ctx.db, "SELECT count(*) FROM turns WHERE wakeId=?1", [wake.wake_id])
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

  test "new assignment supersedes history and later completion appends a new row", ctx do
    assignment = assign(ctx)
    first_attest = complete(ctx, assignment.id)
    first = only_notice(ctx, {:user, "owner"})

    successor = assign(ctx)

    assert successor.state == "open"
    assert CompletionEscalation.get(ctx.db, first.id).request.status == "superseded"
    second_attest = complete(ctx, successor.id)

    records =
      CompletionEscalation.notices(ctx.db, notice_call({:user, "owner"}, "all")).completionNotices

    assert length(records) == 2
    assert Enum.map(records, & &1.assignmentId) == [assignment.id, successor.id]

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
             resolutionSource: "owner_main",
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

    assert %{code: "root_lifecycle_unsupported", decision: "park"} =
             disposition(ctx, record.id, "park", {:session, ctx.main.session_key})

    assert %{request: %{status: "retained_root", decision: "retain"}} =
             disposition(ctx, record.id, "retain", {:session, ctx.main.session_key})

    retained = disposition_state(ctx.db, record.id)

    assert %{request: %{status: "retained_root", decision: "retain"}} =
             disposition(ctx, record.id, "retain", {:session, ctx.main.session_key})

    assert disposition_state(ctx.db, record.id) == retained
  end

  test "stale root Main snapshot cannot authorize self-retain", ctx do
    item =
      WorkItems.__handle__(ctx.db, "work-item-create", %{
        verb: "work-item-create",
        origin: "user:owner",
        principal: {:user, "owner"},
        session_key: nil,
        params: %{title: "stale root authority"}
      })

    assignment = assign(ctx, holder: ctx.main.session_key, work_item: item.id)
    complete(ctx, assignment.id, ctx.main.session_key)
    record = only_notice(ctx, {:user, "owner"})

    assert {:ok, _} =
             DB.query(
               ctx.db,
               "UPDATE sessions SET kind='custom' WHERE sessionKey=?1",
               [ctx.main.session_key]
             )

    before = disposition_state(ctx.db, record.id)

    assert %{code: "not_authorized"} =
             disposition(ctx, record.id, "retain", {:session, ctx.main.session_key})

    assert disposition_state(ctx.db, record.id) == before
  end

  test "ordinary child cannot self-disposition by retain, park, or retire", ctx do
    assignment = assign(ctx)
    complete(ctx, assignment.id)
    record = only_notice(ctx, {:user, "owner"})
    before = disposition_state(ctx.db, record.id)

    for decision <- ~w(retain park retire) do
      assert %{code: "not_authorized"} =
               disposition(ctx, record.id, decision, {:session, ctx.child.session_key})

      assert disposition_state(ctx.db, record.id) == before
    end
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
             disposition(ctx, record.id, "retain", {:user, "owner"})

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
    assert second.routing.parent.receipt.state == "canceled"
    assert second.request.receipt.state == "pending"
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

    before = completion_wake_state(ctx.db, first.id)

    assert {:ok, :ok} =
             DB.transaction(ctx.db, fn txn ->
               CompletionEscalation.reissue_in_txn(txn, deadline.wake_id)
             end)

    assert completion_wake_state(ctx.db, first.id) == before
  end

  test "deadline advances the recipient without rewriting exact-parent truth", ctx do
    assignment = assign(ctx, report_to: ctx.report.session_key)
    complete(ctx, assignment.id)
    first = only_notice(ctx, {:user, "owner"})
    old_parent = wake_for(ctx.db, first.id, "parent-notice")
    old_deadline = wake_for(ctx.db, first.id, "deadline")
    report = wake_for(ctx.db, first.id, "report-to-notice")
    Org.retire(ctx.db, ctx.parent.session_key, "user:owner", 1_000)

    assert {:ok, :ok} =
             DB.transaction(ctx.db, fn txn ->
               CompletionEscalation.reissue_in_txn(txn, old_deadline.wake_id)
             end)

    current = CompletionEscalation.get(ctx.db, first.id)
    assert current.request.generation == 1
    assert current.routing.parent.routeStatus == "scheduled"
    assert current.routing.parent.receipt.state == "canceled"
    assert Wakes.get(ctx.db, old_parent.wake_id).state == "canceled"
    assert Wakes.get(ctx.db, report.wake_id).state == "pending"
  end

  test "reissue stops at a current recipient that became foreign-owned", ctx do
    assignment = assign(ctx)
    complete(ctx, assignment.id)
    first = only_notice(ctx, {:user, "owner"})
    deadline = wake_for(ctx.db, first.id, "deadline")

    assert {:ok, _} =
             DB.query(ctx.db, "UPDATE sessions SET ownerUserId='other' WHERE sessionKey=?1", [
               ctx.parent.session_key
             ])

    assert {:ok, :ok} =
             DB.transaction(ctx.db, fn txn ->
               CompletionEscalation.reissue_in_txn(txn, deadline.wake_id)
             end)

    record = CompletionEscalation.get(ctx.db, first.id)
    assert record.request.currentRecipient == "user:owner"
    assert record.request.recipientGeneration == 1
    assert record.request.deadlineAt == nil

    assert {:ok, [[detail]]} =
             DB.query(
               ctx.db,
               "SELECT detail FROM lifecycle_events WHERE kind='completion_escalation_cross_owner_lineage' AND subject=?1 ORDER BY id DESC LIMIT 1",
               [record.id]
             )

    assert detail ==
             "recipientPathSessionKey=#{ctx.parent.session_key} principal=process:tightbeam:completion-escalation"
  end

  test "completion user columns retain database foreign-key enforcement", ctx do
    for {table, column} <- [
          {"completion_escalations", "causeByUser"},
          {"completion_escalations", "ownerUserId"},
          {"completion_escalations", "currentRecipientUserId"},
          {"completion_escalations", "actedByUser"},
          {"completion_escalation_wakes", "recipientUserId"}
        ] do
      assert {:ok, rows} = DB.query(ctx.db, "PRAGMA foreign_key_list(#{table})")

      assert Enum.any?(rows, fn row ->
               Enum.at(row, 3) == column and Enum.at(row, 2) == "users"
             end)
    end
  end

  test "revocation generation schema admits distinct reopened generation identities", ctx do
    assignment = assign(ctx)

    assert %{state: "closed"} = revoke(ctx, assignment.id, {:user, "owner"})

    assert %{state: "open"} =
             Assignments.__handle__(ctx.db, "reopen-assignment", %{
               verb: "reopen-assignment",
               origin: "user:owner",
               principal: {:user, "owner"},
               session_key: nil,
               supervision_interval_ms: 1_000,
               params: %{assignment_id: assignment.id, reason: "exercise reopened generation"}
             })

    assert %{state: "closed"} = revoke(ctx, assignment.id, {:user, "owner"})

    assert {:ok, [[2, 1]]} =
             DB.query(
               ctx.db,
               "SELECT count(*),count(reopeningId) FROM assignment_revocation_generations WHERE assignmentId=?1",
               [assignment.id]
             )
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

  test "supersede cancellation refusal rolls back the new assignment", ctx do
    assignment = assign(ctx)
    complete(ctx, assignment.id)
    record = only_notice(ctx, {:user, "owner"})
    before = {assignment_count(ctx.db), disposition_state(ctx.db, record.id)}

    :ok =
      DB.execute(ctx.db, """
      CREATE TRIGGER refuse_completion_cancel BEFORE INSERT ON wake_cancellations
      BEGIN SELECT RAISE(ABORT, 'refuse completion cancellation'); END;
      """)

    assert_raise DB.Error, ~r/refuse completion cancellation/, fn -> assign(ctx) end
    assert {assignment_count(ctx.db), disposition_state(ctx.db, record.id)} == before
    :ok = DB.execute(ctx.db, "DROP TRIGGER refuse_completion_cancel")
  end

  test "retain cancellation refusal rolls back acknowledgment and lifecycle", ctx do
    assignment = assign(ctx)
    complete(ctx, assignment.id)
    record = only_notice(ctx, {:user, "owner"})
    before = disposition_state(ctx.db, record.id)

    :ok =
      DB.execute(ctx.db, """
      CREATE TRIGGER refuse_completion_cancel BEFORE INSERT ON wake_cancellations
      BEGIN SELECT RAISE(ABORT, 'refuse completion cancellation'); END;
      """)

    assert_raise MatchError, fn ->
      disposition(ctx, record.id, "retain", {:session, ctx.parent.session_key})
    end

    assert disposition_state(ctx.db, record.id) == before
    :ok = DB.execute(ctx.db, "DROP TRIGGER refuse_completion_cancel")
  end

  test "owner-selected retire acknowledges and retires in one transaction", ctx do
    assignment = assign(ctx)
    complete(ctx, assignment.id)
    record = only_notice(ctx, {:user, "owner"})

    assert %{request: %{status: "acknowledged", decision: "retire"}} =
             disposition(ctx, record.id, "retire", {:user, "owner"})

    assert Org.get(ctx.db, ctx.child.session_key).state == "retired"
  end

  test "corrupt built-in ordinary child is denied before retirement mutation", ctx do
    assignment = assign(ctx)
    complete(ctx, assignment.id)
    record = only_notice(ctx, {:user, "owner"})

    assert {:ok, _} =
             DB.query(ctx.db, "UPDATE sessions SET isBuiltIn=1 WHERE sessionKey=?1", [
               ctx.child.session_key
             ])

    before = disposition_state(ctx.db, record.id)

    assert %{code: "denied"} = disposition(ctx, record.id, "retire", {:user, "owner"})
    assert disposition_state(ctx.db, record.id) == before
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

    before = disposition_state(ctx.db, record.id)

    for principal <- [
          {:session, ctx.main.session_key},
          {:session, ctx.child.session_key},
          {:session, ctx.report.session_key},
          {:session, ctx.sibling.session_key},
          {:session, ctx.foreign.session_key},
          {:user, "other"},
          {:user, "admin"}
        ] do
      assert %{code: "not_authorized"} = disposition(ctx, record.id, "retain", principal)
      assert disposition_state(ctx.db, record.id) == before
    end

    assert %{code: "principal_not_allowed"} =
             disposition(ctx, record.id, "retain", {:remedy, "manual"})
  end

  test "terminal replay stays bound to the current acting principal", ctx do
    parent_assignment = assign(ctx)
    complete(ctx, parent_assignment.id)
    parent_record = only_notice(ctx, {:user, "owner"})

    assert %{request: %{status: "acknowledged"}} =
             disposition(ctx, parent_record.id, "retain", {:session, ctx.parent.session_key})

    Org.retire(ctx.db, ctx.parent.session_key, "user:owner", 1_000)

    assert %{completionNotices: []} =
             CompletionEscalation.notices(
               ctx.db,
               notice_call({:session, ctx.parent.session_key}, "all")
             )

    assert %{code: "not_authorized"} =
             disposition(ctx, parent_record.id, "retain", {:session, ctx.parent.session_key})

    assert %{code: "request_not_open"} =
             disposition(ctx, parent_record.id, "retain", {:user, "owner"})

    replacement_parent = session(ctx.db, "replacement-parent", "owner", ctx.main.session_key)

    replacement_child =
      session(ctx.db, "replacement-child", "owner", replacement_parent.session_key)

    owner_assignment = assign(ctx, holder: replacement_child.session_key)
    complete(ctx, owner_assignment.id, replacement_child.session_key)
    owner_record = only_notice_for(ctx, {:user, "owner"}, owner_assignment.id)

    first = disposition(ctx, owner_record.id, "retain", {:user, "owner"})
    assert first.request.status == "acknowledged"
    assert disposition(ctx, owner_record.id, "retain", {:user, "owner"}) == first
  end

  test "cross-owner spawnedBy fails closed and remains diagnostic", ctx do
    {:ok, _} =
      DB.query(
        ctx.db,
        "UPDATE sessions SET spawnedBy=?2,operationalParent=?2 WHERE sessionKey=?1",
        [
          ctx.child.session_key,
          ctx.foreign.session_key
        ]
      )

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

    assert {:ok, [[1]]} =
             DB.query(
               ctx.db,
               "SELECT count(*) FROM completion_escalation_wakes WHERE completionId=?1 AND kind='parent-notice'",
               [record.id]
             )
  end

  test "completion closure law is structural across every production definition" do
    root = Path.expand("../lib", __DIR__)
    owner = Path.join(root, "tightbeam/productions/completion_escalation.ex")
    assignments = Path.join(root, "tightbeam/assignments.ex")
    gateway = Path.join(root, "tightbeam/gateway.ex")
    router = Path.join(root, "tightbeam/wire/router.ex")

    mutation_sites = completion_mutation_sites(root)
    assert mutation_sites != []
    assert mutation_sites |> Enum.map(&elem(&1, 0)) |> Enum.uniq() == [owner]

    assert remote_call_sites(assignments, :CompletionEscalation, :open_terminal_in_txn, 4)
           |> Enum.sort() == [
             "apply_lifecycle_attest/5",
             "interrupt_for_retire_in_txn/4",
             "revoke_open_assignment_in_txn/3"
           ]

    assert remote_call_sites(
             assignments,
             :CompletionEscalation,
             :supersede_open_for_assignment_in_txn,
             3
           )
           |> Enum.sort() == ["apply_reopen/3", "create_assignment/6"]

    assert remote_call_sites(gateway, :CompletionEscalation, :acknowledge_retire_in_txn, 3) == [
             "retire_session_in_txn/7"
           ]

    assert remote_call_sites(owner, :Org, :effective_parent_in_txn, 2) == [
             "open_terminal_in_txn/4"
           ]

    assert remote_call_sites(owner, :Wakes, :cancel_in_txn, 2) == ["cancel_wake!/3"]
    assert remote_call_sites(owner, :Wakes, :fire_internal_in_txn, 4) == ["fire_deadline!/2"]

    assert remote_call_sites(owner, :EventLog, :lifecycle_in_txn, 4) |> Enum.sort() ==
             ~w(acknowledge_in_txn/5 dispose_undeliverable_delivery_in_txn/2 open_admitted_terminal_in_txn/7 park_unavailable_in_txn/3 preflight_existing_in_txn/4 record_cross_owner_walk/3 record_owner_carrier_failure/5 record_parent_failure/4 record_parent_failure/4 record_recipient_failure/3 record_report_to_failure/4 reissue_open_in_txn/2 retire_deferred_in_txn/4 transition_superseded_in_txn/5)
             |> Enum.sort()

    assert local_call_sites(owner, :root_main_now?, 2) |> Enum.sort() ==
             ["authorized_in_txn?/3", "retain_in_txn/3"]

    root_literals = definition_literals(owner, "root_main_now?/2") |> Enum.join("\n")
    assert root_literals =~ "ownerUserId=?2"
    assert root_literals =~ "state='active'"
    assert root_literals =~ "isBuiltIn=1"
    assert root_literals =~ "kind='main'"

    producer_literals =
      owner |> definitions() |> Enum.flat_map(fn {_ref, body} -> literals(body) end)

    refute Enum.any?(producer_literals, &Regex.match?(~r/UPDATE\s+wakes\s+SET\s+state/i, &1))
    refute Enum.any?(producer_literals, &String.contains?(&1, "lifecycle_event"))
    refute Enum.any?(producer_literals, &String.contains?(&1, "openedBySession"))
    refute Enum.any?(producer_literals, &String.contains?(&1, "openedByUser"))

    assert map_string_values(owner, :reason_kind) |> Enum.uniq() |> Enum.sort() ==
             ~w(obligation_disposed superseded target_unresolvable)

    assert file_ast_contains?(router, :device_user_principal)
    assert definition_ast_contains?(gateway, "children_after_preflight/1", :deadline_consumer)
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

  test "work-item slate and completion request coexist and cancel through separate seams", ctx do
    item =
      WorkItems.__handle__(ctx.db, "work-item-create", %{
        verb: "work-item-create",
        origin: "user:owner",
        principal: {:user, "owner"},
        session_key: nil,
        params: %{title: "coexisting obligations"}
      })

    assignment = assign(ctx, work_item: item.id)
    complete(ctx, assignment.id)
    record = only_notice(ctx, {:user, "owner"})

    assert {:ok, [[slate_wake_id]]} =
             DB.query(ctx.db, "SELECT slateWakeId FROM work_items WHERE id=?1", [item.id])

    assert is_binary(slate_wake_id)
    assert Wakes.get(ctx.db, slate_wake_id).state == "pending"

    assert {:ok, [[2, 0, 0]]} =
             DB.query(
               ctx.db,
               "SELECT count(*),sum(w.assignmentId IS NOT NULL),sum(w.work_item_id IS NOT NULL) FROM completion_escalation_wakes cew JOIN wakes w ON w.wakeId=cew.wakeId WHERE cew.completionId=?1",
               [record.id]
             )

    replacement = assign(ctx, holder: ctx.child.session_key, work_item: item.id)

    assert CompletionEscalation.get(ctx.db, record.id).request.supersededByAssignmentId ==
             replacement.id

    assert Wakes.get(ctx.db, slate_wake_id).state == "canceled"

    assert {:ok, [["assignment_transition"], ["completion_transition"]]} =
             DB.query(
               ctx.db,
               "SELECT DISTINCT causalSourceKind FROM wake_cancellations WHERE wakeId=?1 OR causalSourceId=?2 ORDER BY causalSourceKind",
               [slate_wake_id, record.id]
             )
  end

  test "only the zero-producing revocation opens an empty epoch", ctx do
    first = assign(ctx)
    second = assign(ctx)

    assert %{outcome: "revoked"} = revoke(ctx, first.id, {:user, "owner"})

    assert {:ok, [[0]]} =
             DB.query(
               ctx.db,
               "SELECT count(*) FROM completion_escalations WHERE assignmentId=?1",
               [first.id]
             )

    assert %{outcome: "revoked"} = revoke(ctx, second.id, {:user, "owner"})
    record = only_notice(ctx, {:user, "owner"})

    assert record.assignmentId == second.id
    assert record.causeKind == "revocation"
    assert record.causeId == record.revocationId
    assert record.closingAttestId == nil
    assert record.outcome == "revoked"
    assert record.cause == %{bySession: nil, byUser: "owner", principal: "user:owner"}
    assert record.request.status == "open"
    assert record.request.currentRecipient == "session:#{ctx.parent.session_key}"

    assert wake_for(ctx.db, record.id, "parent-notice").wake_id ==
             "completion:revocation:#{record.revocationId}:parent-notice:0"

    assert wake_for(ctx.db, record.id, "deadline").wake_id ==
             "completion:revocation:#{record.revocationId}:deadline:0"
  end

  test "revocation request and outbox failures roll back the terminal mutation", ctx do
    failures = [
      {"completion_escalations", "1"},
      {"wakes", "NEW.wakeId LIKE '%:parent-notice:0'"},
      {"wakes", "NEW.wakeId LIKE '%:deadline:0'"},
      {"completion_escalation_wakes", "NEW.kind = 'parent-notice'"},
      {"completion_escalation_wakes", "NEW.kind = 'deadline'"}
    ]

    failures
    |> Enum.with_index()
    |> Enum.each(fn {{table, condition}, index} ->
      child = session(ctx.db, "revoke-rollback-child-#{index}", "owner", ctx.parent.session_key)
      assignment = assign(ctx, holder: child.session_key)
      before = revocation_rollback_snapshot(ctx.db, assignment.id)

      :ok =
        DB.execute(
          ctx.db,
          "CREATE TRIGGER abort_revocation_completion BEFORE INSERT ON #{table} WHEN #{condition} BEGIN SELECT RAISE(ABORT, 'forced revocation rollback'); END"
        )

      assert_raise DB.Error, ~r/forced revocation rollback/, fn ->
        revoke(ctx, assignment.id, {:user, "owner"})
      end

      assert revocation_rollback_snapshot(ctx.db, assignment.id) == before
      :ok = DB.execute(ctx.db, "DROP TRIGGER abort_revocation_completion")

      assert %{outcome: "revoked"} = revoke(ctx, assignment.id, {:user, "owner"})

      assert {:ok, [[1, 1, 1]]} =
               DB.query(
                 ctx.db,
                 "SELECT count(*),count(DISTINCT revocationId),count(DISTINCT causeId) FROM completion_escalations WHERE assignmentId=?1 AND causeKind='revocation'",
                 [assignment.id]
               )
    end)
  end

  test "bounded reissues climb same-owner ancestors and terminate at the owner user", ctx do
    previous = Application.get_env(:tightbeam, :prod_limit)
    Application.put_env(:tightbeam, :prod_limit, 0)

    on_exit(fn ->
      if is_nil(previous),
        do: Application.delete_env(:tightbeam, :prod_limit),
        else: Application.put_env(:tightbeam, :prod_limit, previous)
    end)

    assignment = assign(ctx)
    complete(ctx, assignment.id)
    first = only_notice(ctx, {:user, "owner"})
    first_deadline = wake_for(ctx.db, first.id, "deadline")

    assert {:ok, :ok} =
             DB.transaction(ctx.db, fn txn ->
               CompletionEscalation.reissue_in_txn(txn, first_deadline.wake_id)
             end)

    ancestor = CompletionEscalation.get(ctx.db, first.id)
    assert ancestor.request.currentRecipient == "session:#{ctx.main.session_key}"
    assert ancestor.request.recipientGeneration == 1
    assert ancestor.request.recipientReissueCount == 0
    assert ancestor.request.recipientReissueLimit == 0

    assert %{code: "not_authorized"} =
             disposition(ctx, ancestor.id, "retain", {:session, ctx.parent.session_key})

    ancestor_deadline = wake_for_generation(ctx.db, ancestor.id, "deadline", 1)

    assert {:ok, :ok} =
             DB.transaction(ctx.db, fn txn ->
               CompletionEscalation.reissue_in_txn(txn, ancestor_deadline.wake_id)
             end)

    root = CompletionEscalation.get(ctx.db, ancestor.id)
    assert root.request.currentRecipient == "user:owner"
    assert root.request.recipientGeneration == 2
    assert root.request.recipientReissueCount == 0
    assert root.request.deadlineAt == nil

    assert %{code: "not_authorized"} =
             disposition(ctx, root.id, "retain", {:session, ctx.main.session_key})

    assert %{request: %{status: "acknowledged", decision: "retain"}} =
             disposition(ctx, root.id, "retain", {:user, "owner"})
  end

  test "stored reissue limit survives later configuration changes", ctx do
    previous = Application.get_env(:tightbeam, :prod_limit)
    Application.put_env(:tightbeam, :prod_limit, 3)

    on_exit(fn ->
      if is_nil(previous),
        do: Application.delete_env(:tightbeam, :prod_limit),
        else: Application.put_env(:tightbeam, :prod_limit, previous)
    end)

    assignment = assign(ctx)
    complete(ctx, assignment.id)
    record = only_notice(ctx, {:user, "owner"})
    Application.put_env(:tightbeam, :prod_limit, 0)
    deadline = wake_for(ctx.db, record.id, "deadline")

    assert {:ok, :ok} =
             DB.transaction(ctx.db, fn txn ->
               CompletionEscalation.reissue_in_txn(txn, deadline.wake_id)
             end)

    reissued = CompletionEscalation.get(ctx.db, record.id)
    assert reissued.request.currentRecipient == "session:#{ctx.parent.session_key}"
    assert reissued.request.recipientGeneration == 0
    assert reissued.request.recipientReissueCount == 1
    assert reissued.request.recipientReissueLimit == 3
  end

  test "startup and reads do not invent an initial-zero epoch", ctx do
    assert %{completionNotices: []} =
             CompletionEscalation.notices(ctx.db, notice_call({:user, "owner"}, "all"))

    assert {:ok, [[0]]} = DB.query(ctx.db, "SELECT count(*) FROM completion_escalations")
    assert {:ok, [[0]]} = DB.query(ctx.db, "SELECT count(*) FROM completion_escalation_wakes")

    assert %{completionNotices: []} =
             CompletionEscalation.notices(
               ctx.db,
               notice_call({:session, ctx.child.session_key}, "all")
             )
  end

  defp assign(ctx, opts \\ []) do
    holder = Keyword.get(opts, :holder, ctx.child.session_key)
    principal = Keyword.get(opts, :principal, {:user, "owner"})

    params = %{
      subject: "completion work",
      idempotency_key: Keyword.get(opts, :key),
      work_item_id: Keyword.get(opts, :work_item),
      report_to_session_key: Keyword.get(opts, :report_to)
    }

    Assignments.__handle__(ctx.db, "assign", %{
      verb: "assign",
      origin: origin(principal),
      principal: principal,
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

  defp revoke(ctx, assignment_id, principal) do
    Assignments.__handle__(ctx.db, "revoke-assignment", %{
      verb: "revoke-assignment",
      origin: origin(principal),
      principal: principal,
      session_key: nil,
      params: %{assignment_id: assignment_id, reason: "completion escalation fixture"}
    })
  end

  defp progress(ctx, assignment_id, session_key \\ nil) do
    session_key = session_key || ctx.child.session_key

    Assignments.__handle__(ctx.db, "attest", %{
      verb: "attest",
      origin: "agent:holder",
      principal: {:session, session_key},
      session_key: nil,
      params: %{assignment_id: assignment_id, kind: "progress"}
    })
  end

  defp dispatch(ctx, report_to) do
    Assignments.__handle__(ctx.db, "dispatch", %{
      verb: "dispatch",
      origin: "user:owner",
      principal: {:user, "owner"},
      session_key: ctx.child.session_key,
      target_role: nil,
      role_fallback: false,
      supervision_interval_ms: 1_000,
      effort_config: %{db: ctx.db},
      params: %{
        subject: "completion dispatch",
        brief: "complete this work",
        work_item_id: nil,
        workdir_root: nil,
        idempotency_key: nil,
        effect_kind: nil,
        files: [],
        report_to_session_key: report_to
      }
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

  defp only_notice_for(ctx, principal, assignment_id) do
    assert %{completionNotices: records} =
             CompletionEscalation.notices(ctx.db, notice_call(principal, "all"))

    Enum.find(records, &(&1.assignmentId == assignment_id)) ||
      flunk("missing completion notice for #{assignment_id}")
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

  defp wake_for_generation(db, completion_id, kind, generation) do
    {:ok, [[wake_id]]} =
      DB.query(
        db,
        "SELECT wakeId FROM completion_escalation_wakes WHERE completionId=?1 AND kind=?2 AND generation=?3",
        [completion_id, kind, generation]
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

  defp lifecycle_count(db, completion_id) do
    {:ok, [[count]]} =
      DB.query(db, "SELECT count(*) FROM lifecycle_events WHERE subject=?1", [completion_id])

    count
  end

  defp completion_wake_state(db, completion_id) do
    {:ok, rows} =
      DB.query(
        db,
        "SELECT cew.generation,cew.kind,w.state FROM completion_escalation_wakes cew JOIN wakes w ON w.wakeId=cew.wakeId WHERE cew.completionId=?1 ORDER BY cew.generation,cew.kind",
        [completion_id]
      )

    rows
  end

  defp topology_snapshot(db, assignment_id) do
    {:ok, assignment_parentage} =
      DB.query(
        db,
        "SELECT id,workItemId,reviewsAssignmentId,openedByUser,openedBySession FROM assignments WHERE id=?1",
        [assignment_id]
      )

    {:ok, memberships} =
      DB.query(
        db,
        "SELECT id,toplineId,workItemId,linkedAt,unlinkedAt FROM topline_work_memberships ORDER BY id"
      )

    :erlang.term_to_binary({assignment_parentage, memberships})
  end

  defp toplines_bytes(db) do
    db
    |> Toplines.query_public(%{principal: {:user, "owner"}, state: nil})
    |> JSON.encode!()
  end

  defp generic_retire_snapshot(db, completion_id, assignment_id) do
    {:ok, completion} =
      DB.query(db, "SELECT * FROM completion_escalations WHERE id=?1", [completion_id])

    {:ok, assignment} = DB.query(db, "SELECT * FROM assignments WHERE id=?1", [assignment_id])

    {:ok, session} =
      DB.query(
        db,
        "SELECT sessionKey,state,updatedAt FROM sessions WHERE sessionKey=(SELECT childSessionKey FROM completion_escalations WHERE id=?1)",
        [completion_id]
      )

    {:ok, wakes} =
      DB.query(
        db,
        "SELECT w.* FROM wakes w JOIN completion_escalation_wakes cew ON cew.wakeId=w.wakeId WHERE cew.completionId=?1 ORDER BY w.wakeId",
        [completion_id]
      )

    {:ok, cancellations} =
      DB.query(
        db,
        "SELECT c.* FROM wake_cancellations c JOIN completion_escalation_wakes cew ON cew.wakeId=c.wakeId WHERE cew.completionId=?1 ORDER BY c.wakeId",
        [completion_id]
      )

    {:ok, lifecycle} =
      DB.query(db, "SELECT * FROM lifecycle_events WHERE subject=?1 ORDER BY id", [completion_id])

    {:ok, idempotency} =
      DB.query(
        db,
        "SELECT * FROM wire_idempotency WHERE operation='retire' ORDER BY idempotencyKey"
      )

    {completion, assignment, session, wakes, cancellations, lifecycle, idempotency}
  end

  defp eventually(check, remaining \\ 80) do
    cond do
      check.() -> true
      remaining == 0 -> false
      true -> Process.sleep(25) && eventually(check, remaining - 1)
    end
  end

  defp rollback_snapshot(db, assignment_id) do
    {:ok, [[work_item_id | _] = assignment]} =
      DB.query(
        db,
        "SELECT workItemId,state,outcome,closedAt,closingAttestId FROM assignments WHERE id=?1",
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

    {:ok, work_item} = DB.query(db, "SELECT * FROM work_items WHERE id=?1", [work_item_id])

    side_effect_counts =
      for table <-
            ~w(wakes wake_cancellations messages turns lifecycle_events supervision_entitlements supervision_liveness_sidecar effort_checkin_generations) do
        {:ok, [[count]]} = DB.query(db, "SELECT count(*) FROM #{table}")
        {table, count}
      end

    {assignment, work_item, attests, completions, completion_wakes, side_effect_counts}
  end

  defp revocation_rollback_snapshot(db, assignment_id) do
    {:ok, [[revocations]]} =
      DB.query(db, "SELECT count(*) FROM assignment_revocations WHERE assignmentId=?1", [
        assignment_id
      ])

    {:ok, [[generations]]} =
      DB.query(
        db,
        "SELECT count(*) FROM assignment_revocation_generations WHERE assignmentId=?1",
        [assignment_id]
      )

    {rollback_snapshot(db, assignment_id), revocations, generations}
  end

  defp disposition_state(db, completion_id) do
    {:ok, [completion]} =
      DB.query(
        db,
        "SELECT status,decision,actedByUser,actedBySession,actedAt FROM completion_escalations WHERE id=?1",
        [completion_id]
      )

    {:ok, [session]} =
      DB.query(
        db,
        "SELECT state,harness,kind,isBuiltIn FROM sessions WHERE sessionKey=(SELECT childSessionKey FROM completion_escalations WHERE id=?1)",
        [completion_id]
      )

    {:ok, wakes} =
      DB.query(
        db,
        "SELECT w.wakeId,w.state,w.canceledAt FROM wakes w JOIN completion_escalation_wakes cew ON cew.wakeId=w.wakeId WHERE cew.completionId=?1 ORDER BY w.wakeId",
        [completion_id]
      )

    {:ok, [[lifecycle_count]]} =
      DB.query(
        db,
        "SELECT count(*) FROM lifecycle_events WHERE subject=?1",
        [completion_id]
      )

    {:ok, [assignment]} =
      DB.query(
        db,
        "SELECT state,outcome,closedAt,closingAttestId FROM assignments WHERE id=(SELECT assignmentId FROM completion_escalations WHERE id=?1)",
        [completion_id]
      )

    {:ok, work_item} =
      DB.query(
        db,
        "SELECT * FROM work_items WHERE id=(SELECT workItemId FROM completion_escalations WHERE id=?1)",
        [completion_id]
      )

    {completion, session, wakes, lifecycle_count, assignment, work_item}
  end

  defp definitions(file) do
    file
    |> File.read!()
    |> Code.string_to_quoted!()
    |> then(fn ast ->
      {_, found} =
        Macro.prewalk(ast, [], fn
          {kind, _meta, [head, body]} = node, acc when kind in [:def, :defp] ->
            {node, [{definition_ref(head), body} | acc]}

          node, acc ->
            {node, acc}
        end)

      found
    end)
  end

  defp definition_ref({:when, _, [head | _]}), do: definition_ref(head)
  defp definition_ref({name, _, args}) when is_list(args), do: "#{name}/#{length(args)}"
  defp definition_ref({name, _, nil}), do: "#{name}/0"

  defp collect(ast, matcher) do
    {_, found} =
      Macro.prewalk(ast, [], fn node, acc ->
        case matcher.(node) do
          nil -> {node, acc}
          hit -> {node, [hit | acc]}
        end
      end)

    found
  end

  defp literals(ast),
    do:
      collect(ast, fn
        value when is_binary(value) -> value
        _ -> nil
      end)

  defp definition_literals(file, ref) do
    for {^ref, body} <- definitions(file), literal <- literals(body), do: literal
  end

  defp remote_call_sites(file, module, name, arity) do
    for {ref, body} <- definitions(file),
        _ <-
          collect(body, fn
            {{:., _, [{:__aliases__, _, aliases}, ^name]}, _, args}
            when length(args) == arity ->
              if List.last(aliases) == module, do: :call, else: nil

            _ ->
              nil
          end),
        do: ref
  end

  defp local_call_sites(file, name, arity) do
    for {ref, body} <- definitions(file),
        _ <-
          collect(body, fn
            {^name, _, args} when is_list(args) and length(args) == arity -> :call
            _ -> nil
          end),
        do: ref
  end

  defp completion_mutation_sites(root) do
    for file <- Path.wildcard(Path.join(root, "**/*.ex")),
        {ref, body} <- definitions(file),
        sql <- literals(body),
        Regex.match?(
          ~r/(INSERT\s+INTO|UPDATE)\s+["`\[]?completion_escalations\b|INSERT\s+INTO\s+["`\[]?completion_escalation_wakes\b/i,
          sql
        ),
        do: {file, ref}
  end

  defp map_string_values(file, key) do
    file
    |> File.read!()
    |> Code.string_to_quoted!()
    |> collect(fn
      {:%{}, _, pairs} ->
        case Keyword.get(pairs, key) do
          value when is_binary(value) -> value
          _ -> nil
        end

      _ ->
        nil
    end)
  end

  defp definition_ast_contains?(file, ref, token) do
    Enum.any?(definitions(file), fn
      {^ref, body} -> ast_contains?(body, token)
      _ -> false
    end)
  end

  defp file_ast_contains?(file, token) do
    file |> File.read!() |> Code.string_to_quoted!() |> ast_contains?(token)
  end

  defp ast_contains?(ast, :device_user_principal) do
    collect(ast, fn
      {{:., _, [_device, :user_id]}, _, []} -> :device_user
      {{:., _, [{:device, _, _}, :user_id]}, _, []} -> :device_user
      _ -> nil
    end) != [] and Macro.to_string(ast) =~ "principal: {:user, device.user_id}"
  end

  defp ast_contains?(ast, :deadline_consumer) do
    collect(ast, fn
      {:%{}, _, pairs} ->
        if Enum.any?(pairs, &match?({"completion_disposition_deadline", _}, &1)),
          do: :consumer,
          else: nil

      _ ->
        nil
    end) != [] and Macro.to_string(ast) =~ "CompletionEscalation.reissue"
  end

  defp session(db, key, owner, spawned_by) do
    Org.create(db, %{
      session_key: key,
      display_name: key,
      owner_user_id: owner,
      origin: "user:#{owner}",
      spawned_by: spawned_by,
      operational_parent: spawned_by,
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
  defp origin({:remedy, remedy}), do: "remedy:#{remedy}"
end
