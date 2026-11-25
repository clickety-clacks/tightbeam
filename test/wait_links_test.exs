defmodule Tightbeam.WaitLinksTest do
  use Tightbeam.TestCase, async: false
  import Plug.Conn
  import Plug.Test

  alias Tightbeam.{
    Archetypes,
    Artifacts,
    Assignments,
    DB,
    Devices,
    Escalation,
    Gateway,
    Identity,
    Ledger,
    Model,
    Org,
    ReadMarkers,
    Schema,
    StateResources,
    WaitLinks,
    Wakes,
    WorkItems
  }

  alias Tightbeam.Firehose.{Hub, Publisher}
  alias Tightbeam.Wire.Router

  setup do
    base_dir =
      Path.join(System.tmp_dir!(), "tightbeam-core-detail-#{System.unique_integer([:positive])}")

    File.mkdir_p!(base_dir)
    :initialized = Identity.init!(base_dir)
    Archetypes.load!(base_dir)

    db = :"core_detail_db_#{System.unique_integer([:positive])}"
    start_supervised!({DB, path: ":memory:", name: db})
    start_supervised!({Hub, name: Hub})
    :ok = Schema.ensure_all(db)

    {:paired, admin_device} =
      Devices.pair(db, %{
        device_id: "core-admin-device",
        claimed_name: "Flynn",
        platform: nil,
        model: nil
      })

    admin_session = ensure_main_session(db, "flynn")

    work_item =
      WorkItems.__handle__(db, "work-item-create", %{
        verb: "work-item-create",
        origin: "user:flynn",
        principal: {:user, "flynn"},
        session_key: nil,
        params: %{title: "Core detail fixture"}
      })

    assignment =
      Assignments.__handle__(db, "assign", %{
        verb: "assign",
        origin: "user:flynn",
        principal: {:user, "flynn"},
        session_key: admin_session.session_key,
        target_role: nil,
        role_fallback: false,
        supervision_interval_ms: 60_000,
        params: %{
          subject: "Core detail assignment",
          idempotency_key: nil,
          reviews_assignment_id: nil,
          work_item_id: work_item.id,
          files: ["lib/tightbeam/wire/router.ex"]
        }
      })

    wake =
      Wakes.schedule(db, %{
        session_key: admin_session.session_key,
        origin: "user:flynn",
        prompt: "Core detail wake",
        due_at: System.system_time(:millisecond) + 60_000,
        creator_session_key: admin_session.session_key,
        work_item_id: work_item.id,
        assignment_id: assignment.id
      })

    {:ok, turn_seq} =
      Ledger.enqueue(db, %{
        session_key: admin_session.session_key,
        message_id: "core-detail-message",
        origin: "user:flynn",
        prompt: "Core detail turn",
        assignment_id: assignment.id,
        job_ref: work_item.id
      })

    decision_request_id = "dr_core_detail"
    effort_decision_request_id = "dr_core_detail_effort"
    agent_decision_request_id = "dr_core_detail_agent"
    now = System.system_time(:millisecond)

    {:ok, _rows} =
      DB.query(
        db,
        """
        INSERT INTO decision_requests
          (id, kind, raiserId, ownerUserId, raisedAt, deadlineAt, statuteName,
           actionKey, question, context, status)
        VALUES (?1, 'statute', 'user:flynn', 'flynn', ?2, ?3, 'core-detail',
                'read', 'Allow the read?', '{}', 'open')
        """,
        [decision_request_id, now, now + 60_000]
      )

    {:ok, _rows} =
      DB.query(
        db,
        """
        INSERT INTO decision_requests
          (id, kind, raiserId, ownerUserId, assignmentId, expecterSessionKey,
           lineageRung, effortGeneration, deadlineWakeId, raisedAt, deadlineAt,
           question, context, status)
        VALUES (?1, 'effort', 'process:tightbeam', 'flynn', ?2, ?3,
                2, 1, ?4, ?5, ?6, 'Continue the effort?', '{}', 'open')
        """,
        [
          effort_decision_request_id,
          assignment.id,
          admin_session.session_key,
          wake.wake_id,
          now + 1,
          now + 60_001
        ]
      )

    {:ok, _rows} =
      DB.query(
        db,
        """
        INSERT INTO decision_requests
          (id, kind, raiserId, raiserSessionKey, ownerUserId,
           expecterSessionKey, expecterUserId, raisedAt, question, context,
           status, askedOfRole)
        VALUES (?1, 'agent', ?2, ?3, 'flynn', ?3, 'flynn', ?4,
                'Answer the agent?', '{}', 'open', 'coder:core-detail')
        """,
        [
          agent_decision_request_id,
          "session:#{admin_session.session_key}",
          admin_session.session_key,
          now + 2
        ]
      )

    artifact =
      Artifacts.record(db, %{
        principal: {:session, admin_session.session_key},
        session_key: admin_session.session_key,
        params: %{
          kind: "report",
          title: "Core detail report",
          origin_path: "reports/core-detail.md",
          work_item_id: work_item.id
        }
      })

    {:ok, true, %{marker: "cursor"}} =
      ReadMarkers.set(db, "flynn", "core-scope", "cursor")

    catalog = %{
      {"testhost", "claude"} => [
        %{family: "fable", context: nil, efforts: ["medium"], provider: :anthropic}
      ]
    }

    opts = [
      db: db,
      base_dir: base_dir,
      handlers: %{},
      cli_token: "tbc_core_detail",
      firehose_hub: Hub,
      model_catalog: catalog,
      session_status: fn _ -> nil end
    ]

    on_exit(fn -> File.rm_rf!(base_dir) end)

    %{
      db: db,
      opts: opts,
      token: admin_device.token,
      admin_device: admin_device,
      admin_session: admin_session,
      work_item: work_item,
      assignment: assignment,
      wake: wake,
      turn_seq: turn_seq,
      decision_request_id: decision_request_id,
      decision_request_ids: %{
        statute: decision_request_id,
        effort: effort_decision_request_id,
        agent: agent_decision_request_id
      },
      artifact: artifact,
      catalog: catalog
    }
  end

  defp links(ctx, kind, id, extra \\ "", bearer \\ nil) do
    r = get(ctx, "/api/#{kind}/#{URI.encode_www_form(id)}/wait-links?limit=50#{extra}", bearer)
    assert r.status == 200
    JSON.decode!(r.resp_body)
  end

  defp item(ctx),
    do: JSON.decode!(get(ctx, "/api/work-items/#{ctx.work_item.id}").resp_body)["item"]

  defp gw(ctx, target, params),
    do:
      Gateway.handlers(%{db: ctx.db})["wake"].(%{
        verb: "wake",
        origin: "session:" <> ctx.admin_session.session_key,
        principal: {:session, ctx.admin_session.session_key},
        session_key: target,
        params: Map.put(params, :prompt, "Continue work")
      })

  test "pending after-turn is active; recognized fact awaiting delivery is not", ctx do
    {:ok, _} = Ledger.claim_next(ctx.db, ctx.admin_session.session_key, "test")

    reply =
      gw(ctx, ctx.admin_session.session_key, %{
        after_turn: true,
        assignment_id: ctx.assignment.id,
        wait_reason: "Continue after this turn"
      })

    assert reply.wake_id
    page = links(ctx, "assignments", ctx.assignment.id)

    assert Enum.any?(
             page["items"],
             &(&1["wakeId"] == reply.wake_id && &1["kind"] == "after-turn")
           )

    assert item(ctx)["waiting"]["agent"]

    w =
      Wakes.schedule(ctx.db, %{
        session_key: ctx.admin_session.session_key,
        origin: "user:flynn",
        prompt: "x",
        due_at: System.system_time(:millisecond) + 600_000,
        condition_kind: "custom",
        condition_scope: "scope",
        assignment_id: ctx.assignment.id
      })

    {:ok, _} =
      DB.query(ctx.db, "UPDATE wakes SET firedAt=?2,firedBy='condition' WHERE wakeId=?1", [
        w.wake_id,
        System.system_time(:millisecond)
      ])

    refute Enum.any?(
             links(ctx, "assignments", ctx.assignment.id)["items"],
             &(&1["wakeId"] == w.wake_id)
           )

    assert Enum.any?(
             links(ctx, "assignments", ctx.assignment.id, "&includeEnded=true")["items"],
             &(&1["wakeId"] == w.wake_id)
           )
  end

  test "operator question follows the user and publishes indicator changes", ctx do
    before = item(ctx)
    key = ctx.admin_session.session_key

    r =
      Escalation.operator_ask(ctx.db, %{
        verb: "operator-ask",
        origin: "session:" <> key,
        principal: {:session, key},
        session_key: nil,
        params: %{
          question: "Which colour?",
          note: "Choose",
          project: "Fixture",
          options: [%{"label" => "red"}, %{"label" => "blue"}],
          assignment_id: ctx.assignment.id
        }
      })

    assert r.id
    after_open = item(ctx)
    assert after_open["waiting"]["userIds"] == ["flynn"]
    assert after_open["rowVersion"] > before["rowVersion"]

    edge =
      Enum.find(
        links(ctx, "assignments", ctx.assignment.id)["items"],
        &(&1["id"] == "decision:#{r.id}")
      )

    assert edge["kind"] == "operator-question"
    assert edge["to"]["visible"]
    assert hd(links(ctx, "decision-requests", r.id)["items"])["to"]["id"] == "flynn"

    withdrawn =
      Escalation.operator_withdraw(ctx.db, %{
        verb: "operator-withdraw",
        origin: "session:" <> key,
        principal: {:session, key},
        params: %{request_id: r.id, reason: "No longer needed"}
      })

    assert withdrawn.status == "withdrawn"
    assert item(ctx)["waiting"]["userIds"] == []
    assert item(ctx)["rowVersion"] > after_open["rowVersion"]
  end

  test "current decision custody is followed and effort requests keep their agent addressee",
       ctx do
    Org.create(ctx.db, %{
      session_key: "successor",
      display_name: "Successor",
      owner_user_id: "flynn",
      origin: "user:flynn",
      archetype: "default",
      host: "testhost",
      harness: "claude",
      provider: "anthropic",
      model: Model.new("fable")
    })

    {:ok, _} =
      DB.query(
        ctx.db,
        "UPDATE decision_requests SET currentExpecterSessionKey='successor',currentRaiserSessionKey='successor' WHERE id='dr_core_detail_agent'"
      )

    assert hd(links(ctx, "decision-requests", "dr_core_detail_agent")["items"])["to"]["id"] ==
             "successor"

    assert Enum.any?(
             links(ctx, "sessions", "successor")["items"],
             &(&1["id"] == "decision:dr_core_detail_agent")
           )

    e =
      Enum.find(
        links(ctx, "assignments", ctx.assignment.id)["items"],
        &(&1["id"] == "decision:dr_core_detail_effort")
      )

    assert e["kind"] == "agent-question"
  end

  test "hidden wakes and decisions retain placeholders without reason or target identifiers",
       ctx do
    %{token: tok} = outsider_device(ctx)

    {:ok, _} =
      DB.query(
        ctx.db,
        "UPDATE assignments SET openedByUser='outsider',openedBySession=NULL WHERE id=?1",
        [ctx.assignment.id]
      )

    w =
      Wakes.schedule(ctx.db, %{
        session_key: ctx.admin_session.session_key,
        origin: "user:flynn",
        prompt: "x",
        due_at: System.system_time(:millisecond) + 60_000,
        assignment_id: ctx.assignment.id,
        creator_session_key: ctx.admin_session.session_key,
        wait_reason: "Private reason"
      })

    assert get(ctx, "/api/wakes/#{w.wake_id}", tok).status == 404
    page = links(ctx, "assignments", ctx.assignment.id, "", tok)
    assert Enum.any?(page["items"], &(&1["kind"] == "wake" && &1["visible"] == false))
    encoded = JSON.encode!(page)
    refute encoded =~ w.wake_id
    refute encoded =~ "Private reason"
    refute encoded =~ "dr_core_detail_effort"
    refute encoded =~ "operator-question"
  end

  test "ordinary reads, publishes and turn claims do not require cron schema", ctx do
    :ok = DB.execute(ctx.db, "DROP TABLE cron_wake_schedules")

    w =
      Wakes.schedule(ctx.db, %{
        session_key: ctx.admin_session.session_key,
        origin: "user:flynn",
        prompt: "x",
        due_at: System.system_time(:millisecond) + 60_000,
        assignment_id: ctx.assignment.id
      })

    assert w.wake_id

    assert {:ok, _} =
             DB.transaction(
               ctx.db,
               &Wakes.publish_change_in_txn(&1, "wake.fired", ctx.wake.wake_id)
             )

    assert {:ok, _} = Ledger.claim_next(ctx.db, ctx.admin_session.session_key, "claim")
    assert get(ctx, "/api/work-items/#{ctx.work_item.id}").status == 200
    assert get(ctx, "/api/wakes/#{ctx.wake.wake_id}").status == 200
    assert links(ctx, "assignments", ctx.assignment.id)["items"] != []
  end

  test "optional blank reasons stay compatible but malformed supplied values refuse", ctx do
    other = "other-session"

    Org.create(ctx.db, %{
      session_key: other,
      display_name: "Other",
      owner_user_id: "flynn",
      origin: "user:flynn",
      archetype: "default",
      host: "testhost",
      harness: "claude",
      provider: "anthropic",
      model: Model.new("fable")
    })

    for params <- [
          %{wait_reason: nil},
          %{wait_reason: ""},
          %{cron: "0 * * * *", wait_reason: nil},
          %{after_ms: 60_000, wait_reason: "  "},
          %{after_ms: 60_000, wait_reason: "\n"}
        ] do
      reply = gw(ctx, other, params)
      assert reply.wake_id
    end

    assert gw(ctx, other, %{after_ms: 60_000, wait_reason: "a\nb"}).code == "invalid_wait_reason"
    long = gw(ctx, other, %{after_ms: 60_000, wait_reason: String.duplicate("x", 141)})
    assert long.code == "wait_reason_too_long"
    assert long.message =~ "140"
  end

  test "disposer transfers publish a new work-item summary", ctx do
    key = ctx.admin_session.session_key

    r =
      Assignments.__handle__(ctx.db, "attest", %{
        verb: "attest",
        origin: "session:" <> key,
        principal: {:session, key},
        session_key: nil,
        params: %{assignment_id: ctx.assignment.id, kind: "cannot-proceed", note: "Need a choice"}
      })

    assert r.attest

    {:ok, _} =
      DB.query(ctx.db, "UPDATE assignment_cannot_proceed SET disposerRef='session:'||?1", [key])

    before = item(ctx)

    {:ok, :ok} =
      DB.transaction(
        ctx.db,
        &Assignments.transfer_cannot_proceed_disposer_to_user_in_txn(
          &1,
          ctx.assignment.id,
          "flynn",
          1
        )
      )

    after_transfer = item(ctx)
    assert after_transfer["waiting"]["userIds"] == ["flynn"]
    assert after_transfer["rowVersion"] > before["rowVersion"]
  end

  test "summary and item page seek only linked wake and decision rows", ctx do
    observer = self()

    {:ok, :ok} =
      DB.transaction(ctx.db, fn txn ->
        traced =
          Tightbeam.DB.Txn.observe_queries(txn, fn event -> send(observer, {:query, event}) end)

        WaitLinks.summaries(traced, [ctx.work_item.id])
        :ok
      end)

    assert_receive {:query, {:sql_query, sql, _count}}

    {:ok, plan} =
      DB.query(ctx.db, "EXPLAIN QUERY PLAN " <> sql, [JSON.encode!([ctx.work_item.id])])

    details = Enum.map_join(plan, "\n", &List.last/1)
    assert details =~ "SEARCH w USING INDEX wakes_wait_links_item"
    assert details =~ "SEARCH w USING INDEX wakes_assignment"
    assert details =~ "SEARCH r USING INDEX row_reaction_output"
    assert details =~ "SEARCH d USING INDEX decision_requests_rest_assignment_order"
    assert details =~ "SEARCH d USING INDEX decision_requests_wait_item"
    assert details =~ ~r/SEARCH cp USING (?:COVERING )?INDEX cannot_proceed_wait_assignment/
    assert details =~ ~r/SEARCH a USING (?:COVERING )?INDEX \w+ \(workItemId=\?\)/
    assert details =~ ~r/SEARCH t USING (?:COVERING )?INDEX turns_wait_item/
    assert details =~ ~r/SEARCH t USING (?:COVERING )?INDEX turns_wait_assignment/
    # CTE scans are bounded by requested items. Base-table loops must seek.
    refute details =~ ~r/SCAN (a|w|d|cp|t|r) USING (?:COVERING )?INDEX/

    refute details =~
             ~r/SCAN (assignments|wakes|decision_requests|assignment_cannot_proceed|turns)\b/

    refute details =~ "wakes_wait_recognition"
    refute details =~ "decision_requests_rest_status_order"

    trace = fn
      {:sql_query, sql, _count} ->
        if String.starts_with?(sql, "SELECT at,key,type,id FROM"),
          do: send(observer, {:page_query, sql})

      _ ->
        :ok
    end

    principal = %{kind: "user", id: "flynn", is_admin: true, core_detail_trace: trace}
    {:ok, request} = WaitLinks.request(%{}, "work-item", ctx.work_item.id)
    assert {:ok, _} = WaitLinks.page(ctx.db, "work-item", ctx.work_item.id, principal, request)
    assert_receive {:page_query, page_sql}

    {:ok, page_plan} =
      DB.query(
        ctx.db,
        "EXPLAIN QUERY PLAN " <> page_sql,
        List.duplicate(ctx.work_item.id, 5) ++ [-1, "", 21]
      )

    page_details = Enum.map_join(page_plan, "\n", &List.last/1)
    assert page_details =~ "SEARCH w USING INDEX wakes_wait_links_item"
    assert page_details =~ "SEARCH w USING INDEX wakes_assignment"
    refute page_details =~ "wakes_wait_recognition"
    refute page_details =~ "decision_requests_rest_status_order"
  end

  test "wake detail and socket payload hide an unreadable target with the same shape", ctx do
    %{token: tok} = outsider_device(ctx)
    other = "outside-owner-session"

    Org.create(ctx.db, %{
      session_key: other,
      display_name: "Outside",
      owner_user_id: "outsider",
      origin: "user:outsider",
      archetype: "default",
      host: "testhost",
      harness: "claude",
      provider: "anthropic",
      model: Model.new("fable")
    })

    w =
      Wakes.schedule(ctx.db, %{
        session_key: other,
        origin: "user:outsider",
        prompt: "x",
        due_at: System.system_time(:millisecond) + 60_000,
        condition_kind: "assignment-landed",
        condition_scope: ctx.assignment.id
      })

    detail = get(ctx, "/api/wakes/#{w.wake_id}", tok)
    assert detail.status == 200
    targets = JSON.decode!(detail.resp_body)["item"]["waitOn"]
    assert hd(targets) == %{"kind" => "assignment", "id" => nil, "visible" => false}

    notice =
      Publisher.committed_notice(
        "wake.scheduled",
        StateResources.query_wake(ctx.db, w.wake_id),
        %{"wakeId" => w.wake_id}
      )

    state = %Tightbeam.Wire.ChangeSocket{
      phase: :live,
      user_id: "outsider",
      is_admin: false,
      deps: %{db: ctx.db, model_catalog: ctx.catalog}
    }

    assert {:push, {:text, wire}, _} =
             Tightbeam.Wire.ChangeSocket.handle_info({:firehose_notice, notice}, state)

    assert JSON.decode!(wire)["payload"]["waitOn"] == targets

    # Session credentials retain the same existing grant as their REST reads;
    # changing that projection does not widen the user's socket above.
    session_read = get(ctx, "/api/wakes/#{w.wake_id}", Org.get(ctx.db, other).cli_token)
    assert session_read.status == 200

    session_state = %{state | principal_kind: :session, principal_id: other}

    assert {:push, {:text, session_wire}, _} =
             Tightbeam.Wire.ChangeSocket.handle_info({:firehose_notice, notice}, session_state)

    session_targets = JSON.decode!(session_read.resp_body)["item"]["waitOn"]
    assert hd(session_targets)["id"] == ctx.assignment.id
    assert JSON.decode!(session_wire)["payload"]["waitOn"] == session_targets
  end

  test "operator requests linked directly to an item publish on ruling and replay stays unchanged",
       ctx do
    key = ctx.admin_session.session_key
    before = item(ctx)

    r =
      Escalation.operator_ask(ctx.db, %{
        verb: "operator-ask",
        origin: "session:" <> key,
        principal: {:session, key},
        session_key: nil,
        params: %{
          question: "Approve?",
          note: "Decision",
          project: "Fixture",
          work_item_id: ctx.work_item.id
        }
      })

    assert r.id
    opened = item(ctx)
    assert opened["waiting"]["userIds"] == ["flynn"]
    assert opened["rowVersion"] > before["rowVersion"]

    notice =
      Publisher.state_notice(
        ctx.db,
        %{verb: "operator-ask", principal: {:session, key}, params: %{}},
        r
      )

    assert notice["refs"]["workItemId"] == ctx.work_item.id

    assert Enum.any?(
             links(ctx, "work-items", ctx.work_item.id)["items"],
             &(&1["id"] == "decision:#{r.id}")
           )

    call = %{
      verb: "operator-rule",
      origin: "user:flynn",
      principal: {:user, "flynn"},
      transport_session_key: nil,
      params: %{request: r.id, decision: "accept"}
    }

    assert Escalation.operator_rule(ctx.db, call).status == "ruled"
    ended = item(ctx)
    assert ended["waiting"]["userIds"] == []
    assert ended["rowVersion"] > opened["rowVersion"]
    assert Escalation.operator_rule(ctx.db, call).status == "ruled"
    assert item(ctx)["rowVersion"] == ended["rowVersion"]
  end

  test "custom events have their own indicator and fallback is not an awaited time", ctx do
    # Use a bare item so unrelated fixture waits cannot supply a pill.
    item =
      WorkItems.__handle__(ctx.db, "work-item-create", %{
        verb: "work-item-create",
        origin: "user:flynn",
        principal: {:user, "flynn"},
        session_key: nil,
        params: %{title: "Event only"}
      })

    wake =
      Wakes.schedule(ctx.db, %{
        session_key: ctx.admin_session.session_key,
        origin: "user:flynn",
        prompt: "Continue",
        work_item_id: item.id,
        condition_kind: "build-published",
        condition_scope: "release",
        due_at: System.system_time(:millisecond) + 60_000
      })

    assert WaitLinks.summaries(ctx.db, [item.id])[item.id].waiting == %{
             agent: false,
             time: false,
             event: true,
             userIds: []
           }

    {:ok, _} =
      DB.query(ctx.db, "UPDATE wakes SET firedAt=?2,firedBy='condition' WHERE wakeId=?1", [
        wake.wake_id,
        System.system_time(:millisecond)
      ])

    assert WaitLinks.summaries(ctx.db, [item.id])[item.id].waiting == %{
             agent: false,
             time: false,
             event: false,
             userIds: []
           }

    Wakes.schedule(ctx.db, %{
      session_key: ctx.admin_session.session_key,
      origin: "user:flynn",
      prompt: "Continue",
      work_item_id: item.id,
      condition_kind: "assignment-landed",
      condition_scope: ctx.assignment.id,
      due_at: System.system_time(:millisecond) + 60_000
    })

    assert WaitLinks.summaries(ctx.db, [item.id])[item.id].waiting == %{
             agent: true,
             time: false,
             event: false,
             userIds: []
           }
  end

  @tag :wait_links_timing
  test "unrelated pending wakes do not enter item summaries", ctx do
    ids = for i <- 1..300, do: "wi_unrelated_timing_#{i}"

    {:ok, _} =
      DB.query(
        ctx.db,
        "INSERT INTO work_items(id,title,ownerUserId,state,createdByUser,createdAt) SELECT value,'Timing','flynn','open','flynn',1 FROM json_each(?1)",
        [JSON.encode!(ids)]
      )

    measure = fn selected ->
      # Same transaction seam as turn publication; time only the summary query.
      {:ok, samples} =
        DB.transaction(ctx.db, fn txn ->
          for _ <- 1..5, do: :timer.tc(fn -> WaitLinks.summaries(txn, selected) end)
        end)

      {Enum.min(Enum.map(samples, &elem(&1, 0))), elem(hd(samples), 1)}
    end

    {before_us, before_rows} = measure.(ids)

    {:ok, _} =
      DB.query(
        ctx.db,
        "INSERT INTO wakes(wakeId,sessionKey,origin,prompt,consumer,dueAt,state,createdAt) SELECT 'w_unrelated_timing_'||value,?1,'user:flynn','Unrelated','prompt',9999999999999,'pending',1 FROM json_each(?2)",
        [ctx.admin_session.session_key, JSON.encode!(Enum.to_list(1..3000))]
      )

    {after_us, after_rows} = measure.(ids)
    {single_us, _} = measure.([hd(ids)])
    assert before_rows == after_rows
    assert map_size(after_rows) == 300

    IO.puts(
      "WAIT_LINK_TIMING summary in transaction: 300 items before=#{before_us}us after_3000_unrelated=#{after_us}us one_item_after=#{single_us}us; minimum of five, same result"
    )
  end

  test "delivery retry due time does not declare a wait", ctx do
    before = item(ctx)

    wake =
      Wakes.schedule(ctx.db, %{
        wake_id: "wr_transport_attempt",
        session_key: ctx.admin_session.session_key,
        origin: "process:tightbeam",
        prompt: "Retry delivery",
        work_item_id: ctx.work_item.id,
        due_at: System.system_time(:millisecond) + 60_000
      })

    assert item(ctx)["waiting"] == before["waiting"]
    assert item(ctx)["rowVersion"] == before["rowVersion"]
    assert StateResources.wake(StateResources.query_wake(ctx.db, wake.wake_id))["waitOn"] == []

    for ended <- ["true", "false"] do
      {:ok, request} =
        WaitLinks.request(%{"includeEnded" => ended}, "work-item", ctx.work_item.id)

      {:ok, page} =
        WaitLinks.page(
          ctx.db,
          "work-item",
          ctx.work_item.id,
          %{kind: "user", id: "flynn", is_admin: true},
          request
        )

      refute Enum.any?(page.items, &(&1[:wakeId] == wake.wake_id))
    end
  end

  test "malformed stored decision context keeps its existing per-row refusal and does not block boot",
       ctx do
    assert {:ok, _} =
             DB.query(
               ctx.db,
               "INSERT INTO decision_requests(id,kind,raiserId,ownerUserId,raisedAt,deadlineAt,statuteName,actionKey,question,context,status) VALUES('dr_bad_context','statute','user:flynn','flynn',1,2,'test','bad','Question','{bad','open')"
             )

    # Rebuild the new index from retained malformed state, as on an upgrade.
    assert :ok = DB.execute(ctx.db, "DROP INDEX decision_requests_wait_item")
    assert :ok = Schema.ensure_all(ctx.db)

    assert {:ok, [["{bad"]]} =
             DB.query(ctx.db, "SELECT context FROM decision_requests WHERE id='dr_bad_context'")

    assert {:ok, :ok} =
             DB.transaction(ctx.db, fn txn ->
               request = Escalation.raw_by_id_in_txn(txn, "dr_bad_context")
               Escalation.publish_wait_source_in_txn(txn, request)
             end)

    assert is_map(WaitLinks.summaries(ctx.db, [ctx.work_item.id]))
    assert is_map(links(ctx, "work-items", ctx.work_item.id))
  end

  defp get(ctx, path, bearer \\ nil, headers \\ []) do
    Enum.reduce(headers, conn(:get, path), fn {name, value}, conn ->
      put_req_header(conn, name, value)
    end)
    |> put_req_header("authorization", "Bearer #{bearer || ctx.token}")
    |> Router.call(Router.init(ctx.opts))
  end

  defp outsider_device(ctx) do
    Devices.add_user(ctx.db, "outsider", false)

    {:pending, _device} =
      Devices.pair(ctx.db, %{
        device_id: "outsider-device",
        claimed_name: "Outsider",
        platform: nil,
        model: nil
      })

    Devices.approve(ctx.db, "outsider-device", "outsider")
  end
end
