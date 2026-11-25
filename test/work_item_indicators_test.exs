defmodule Tightbeam.WorkItemIndicatorsTest do
  use Tightbeam.TestCase, async: false
  import Plug.Conn
  import Plug.Test

  alias Tightbeam.{Assignments, DB, Devices, Ledger, Model, Org, Schema, Wakes}
  alias Tightbeam.{StateVisibility, WorkItems}
  alias Tightbeam.Firehose.Hub
  alias Tightbeam.Wire.Router

  setup do
    previous = Application.get_env(:tightbeam, :wait_links_enabled)
    Application.put_env(:tightbeam, :wait_links_enabled, true)

    on_exit(fn ->
      if is_nil(previous),
        do: Application.delete_env(:tightbeam, :wait_links_enabled),
        else: Application.put_env(:tightbeam, :wait_links_enabled, previous)
    end)

    db = :"indicators_db_#{System.unique_integer([:positive])}"
    start_supervised!({DB, path: ":memory:", name: db})
    start_supervised!({Hub, name: Hub})
    :ok = Schema.ensure_all(db)

    {:paired, device} =
      Devices.pair(db, %{device_id: "admin", claimed_name: "Flynn", platform: nil, model: nil})

    holder = session(db, "flynn", "holder")
    other = session(db, "flynn", "other")
    item = work_item(db, "First item")

    opts = [
      db: db,
      base_dir: System.tmp_dir!(),
      handlers: %{},
      cli_token: "tbc_indicators",
      firehose_hub: Hub,
      model_catalog: %{},
      session_status: fn _ -> nil end
    ]

    %{
      db: db,
      opts: opts,
      token: device.token,
      holder: holder,
      other: other,
      item: item,
      card: open_card(db, holder, item.id)
    }
  end

  defp session(db, owner, key) do
    Org.create(db, %{
      session_key: key,
      display_name: key,
      owner_user_id: owner,
      origin: "user:" <> owner,
      archetype: "default",
      host: "testhost",
      harness: "claude",
      provider: "anthropic",
      model: Model.new("fable")
    })

    key
  end

  defp work_item(db, title) do
    WorkItems.__handle__(db, "work-item-create", %{
      verb: "work-item-create",
      origin: "user:flynn",
      principal: {:user, "flynn"},
      session_key: nil,
      params: %{title: title}
    })
  end

  defp open_card(db, holder, item_id) do
    Assignments.__handle__(db, "assign", %{
      verb: "assign",
      origin: "user:flynn",
      principal: {:user, "flynn"},
      session_key: holder,
      target_role: nil,
      role_fallback: false,
      supervision_interval_ms: 60_000,
      params: %{
        subject: "Indicator assignment",
        idempotency_key: nil,
        reviews_assignment_id: nil,
        work_item_id: item_id,
        files: []
      }
    })
  end

  defp wake(ctx, params) do
    Wakes.schedule(
      ctx.db,
      Map.merge(
        %{
          session_key: ctx.holder,
          creator_session_key: ctx.holder,
          origin: "user:flynn",
          prompt: "Continue",
          due_at: System.system_time(:millisecond) + 60_000
        },
        params
      )
    )
  end

  defp question(ctx, id, card_id) do
    {:ok, _} =
      DB.query(
        ctx.db,
        """
        INSERT INTO decision_requests(id,kind,raiserId,raiserSessionKey,ownerUserId,assignmentId,
          raisedAt,actionKey,question,options,context,status)
        VALUES (?1,'operator',?2,?3,'flynn',?4,5,?1,'SECRET QUESTION TEXT','[{"label":"yes"}]','{}','open')
        """,
        [id, "session:" <> ctx.holder, ctx.holder, card_id]
      )
  end

  defp get(ctx, query, bearer \\ nil) do
    conn(:get, "/api/work-item-indicators?" <> query)
    |> put_req_header("authorization", "Bearer #{bearer || ctx.token}")
    |> Router.call(Router.init(ctx.opts))
  end

  defp read(ctx, query, bearer \\ nil) do
    response = get(ctx, query, bearer)
    assert response.status == 200, response.resp_body
    JSON.decode!(response.resp_body)
  end

  defp one(ctx, id \\ nil),
    do: read(ctx, "workItemIds=#{id || ctx.item.id}")["items"] |> hd()

  defp detail(ctx) do
    conn(:get, "/api/work-items/" <> ctx.item.id)
    |> put_req_header("authorization", "Bearer " <> ctx.token)
    |> Router.call(Router.init(ctx.opts))
    |> then(&JSON.decode!(&1.resp_body)["item"])
  end

  test "wait-link fields follow the wait-links flag", ctx do
    question(ctx, "dr_flag", ctx.card.id)
    Application.put_env(:tightbeam, :wait_links_enabled, false)
    item = one(ctx)

    for field <- ~w(waiting running waits waitsTruncated questions),
        do: refute(Map.has_key?(item, field), field)

    assert %{"state" => "open", "held" => true, "runningCards" => []} = item
    assert Map.keys(item) -- Map.keys(detail(ctx)) == ["held", "runningCards"]
    Application.put_env(:tightbeam, :wait_links_enabled, true)
    assert %{"questions" => %{"count" => 1}, "waiting" => %{}} = one(ctx)
  end

  test "items and cards resolve in one read; unknown ids do not fail the page", ctx do
    bare = work_item(ctx.db, "Never started")
    second = work_item(ctx.db, "Second item")
    card = open_card(ctx.db, ctx.other, second.id)
    loose = open_card(ctx.db, ctx.other, nil)

    page =
      read(
        ctx,
        "workItemIds=#{ctx.item.id},#{bare.id},wi_missing&assignmentIds=#{card.id},#{loose.id},asg_missing&asUser=flynn",
        "tbc_indicators"
      )

    assert Enum.map(page["items"], & &1["id"]) == [ctx.item.id, bare.id, second.id]

    assert [first, started, _] = page["items"]

    assert %{"title" => "First item", "state" => "open", "started" => true, "held" => true} =
             first

    assert first["holders"] == [ctx.holder]
    assert %{"started" => false, "held" => false, "holders" => [], "waits" => []} = started
    refute Map.has_key?(first, "attestCounts")

    assert page["assignments"] == [
             %{"id" => card.id, "workItemId" => second.id, "state" => "open"},
             %{"id" => loose.id, "workItemId" => nil, "state" => "open"}
           ]

    assert page["notFound"] == %{
             "workItemIds" => ["wi_missing"],
             "assignmentIds" => ["asg_missing"]
           }
  end

  test "a closed card leaves an item started and not held", ctx do
    close(ctx)
    assert %{"started" => true, "held" => false} = one(ctx)
  end

  defp close(ctx) do
    {:ok, _} =
      DB.query(
        ctx.db,
        "INSERT INTO attests(id,assignmentId,kind,bySession,ts) VALUES('att_x',?1,'completion',?2,1)",
        [ctx.card.id, ctx.holder]
      )

    DB.query(
      ctx.db,
      "UPDATE assignments SET state='closed',outcome='completed',closedAt=1,closedByUser='flynn',closingAttestId='att_x' WHERE id=?1",
      [ctx.card.id]
    )
  end

  test "waits split by agent, event and time and agree with the item detail", ctx do
    target = open_card(ctx.db, ctx.other, work_item(ctx.db, "Target").id)
    due = System.system_time(:millisecond) + 120_000

    timed =
      wake(ctx, %{assignment_id: ctx.card.id, due_at: due, wait_reason: "Waiting for the build"})

    event =
      wake(ctx, %{
        work_item_id: ctx.item.id,
        condition_kind: "build-finished",
        condition_scope: "nightly"
      })

    agent =
      wake(ctx, %{
        assignment_id: ctx.card.id,
        condition_kind: "assignment-landed",
        condition_scope: target.id
      })

    # A fired wake, a delivery retry and an immediate message are not waits.
    wake(ctx, %{assignment_id: ctx.card.id, wake_id: "wr_retry"})
    fired = wake(ctx, %{assignment_id: ctx.card.id})

    {:ok, _} =
      DB.query(ctx.db, "UPDATE wakes SET state='fired',firedAt=1 WHERE wakeId=?1", [fired.wake_id])

    item = one(ctx)

    assert item["waiting"] == %{"agent" => true, "time" => true, "event" => true, "userIds" => []}
    assert item["waiting"] == detail(ctx)["waiting"]
    assert item["running"] == detail(ctx)["running"]
    assert item["rowVersion"] == detail(ctx)["rowVersion"]
    waits = Map.new(item["waits"], &{&1["wakeId"], &1})

    assert Map.keys(waits) |> Enum.sort() ==
             Enum.sort([timed.wake_id, event.wake_id, agent.wake_id])

    assert %{
             "by" => "time",
             "kind" => "timed",
             "dueAt" => ^due,
             "fallbackAt" => nil,
             "waitReason" => "Waiting for the build"
           } = waits[timed.wake_id]

    assert waits[timed.wake_id]["assignmentId"] == ctx.card.id

    assert %{"by" => "event", "dueAt" => nil, "waitReason" => nil, "waitOn" => [fact | _]} =
             waits[event.wake_id]

    assert %{"factKind" => "build-finished", "scope" => "nightly"} = fact
    assert is_integer(waits[event.wake_id]["fallbackAt"])
    assert %{"by" => "agent", "waitOn" => [on | _]} = waits[agent.wake_id]
    assert %{"kind" => "assignment", "id" => id, "holder" => %{"id" => "other"}} = on
    assert id == target.id
  end

  test "routing and slate reminders are not waits", ctx do
    reminder = wake(ctx, %{work_item_id: ctx.item.id})

    {:ok, _} =
      DB.query(ctx.db, "UPDATE work_items SET routingWakeId=?1 WHERE id=?2", [
        reminder.wake_id,
        ctx.item.id
      ])

    assert %{"waits" => [], "waiting" => %{"time" => false}} = one(ctx)
  end

  test "open questions to a user carry ids and a count, never text", ctx do
    question(ctx, "dr_one", ctx.card.id)
    question(ctx, "dr_two", ctx.card.id)

    {:ok, _} =
      DB.query(ctx.db, "UPDATE decision_requests SET status='withdrawn' WHERE id='dr_two'", [])

    response = get(ctx, "workItemIds=" <> ctx.item.id)
    refute response.resp_body =~ "SECRET"
    item = JSON.decode!(response.resp_body)["items"] |> hd()
    assert item["waiting"]["userIds"] == ["flynn"]

    assert item["questions"] == %{
             "count" => 1,
             "truncated" => false,
             "items" => [
               %{
                 "id" => "dr_one",
                 "kind" => "operator",
                 "userId" => "flynn",
                 "assignmentId" => ctx.card.id,
                 "raisedAt" => 5
               }
             ]
           }

    assert item["waits"] == []
  end

  test "a question to an agent is a wait on that agent", ctx do
    {:ok, _} =
      DB.query(
        ctx.db,
        """
        INSERT INTO decision_requests(id,kind,raiserId,raiserSessionKey,ownerUserId,assignmentId,
          expecterSessionKey,expecterUserId,raisedAt,question,context,status)
        VALUES ('dr_agent','agent',?1,?2,'flynn',?3,?4,'flynn',5,'Q','{}','open')
        """,
        ["session:" <> ctx.holder, ctx.holder, ctx.card.id, ctx.other]
      )

    item = one(ctx)
    assert %{"count" => 0, "items" => []} = item["questions"]
    assert [%{"by" => "agent", "kind" => "agent-question", "wakeId" => nil}] = item["waits"]
    assert item["waiting"]["agent"]
  end

  test "a dependency on a question to a user waits on the user", ctx do
    question(ctx, "dr_dep", nil)
    now = System.system_time(:millisecond)

    {:ok, _} =
      DB.query(
        ctx.db,
        """
        INSERT INTO wakes(wakeId,sessionKey,origin,prompt,consumer,dueAt,state,createdAt,assignmentId,
          waitMode,predicate,resolverKind,resolverId,creatorSessionKey)
        VALUES ('w_dep',?1,'user:flynn','x','prompt',?2,'pending',?3,?4,'dependency',?5,'decision_request','dr_dep',?1)
        """,
        [
          ctx.holder,
          now + 60_000,
          now,
          ctx.card.id,
          JSON.encode!(%{bindings: %{decisionRequestId: "dr_dep"}, conditions: []})
        ]
      )

    item = one(ctx)
    assert [%{"wakeId" => "w_dep", "by" => "user", "kind" => "dependency"}] = item["waits"]
    assert %{"count" => 1, "items" => [%{"id" => "dr_dep"}]} = item["questions"]
    assert item["waiting"] == detail(ctx)["waiting"]
  end

  test "running names the open cards whose holder is in a turn and the turn's recorded work",
       ctx do
    assert %{"running" => false, "runningCards" => []} = one(ctx)

    {:ok, _} =
      Ledger.enqueue(ctx.db, %{
        session_key: ctx.holder,
        message_id: "untied",
        origin: "user:flynn",
        prompt: "Work"
      })

    {:ok, turn} = Ledger.claim_next(ctx.db, ctx.holder, "test")

    assert %{"running" => false, "runningCards" => [card]} = one(ctx)
    assert card["assignmentId"] == ctx.card.id
    assert card["holderKey"] == ctx.holder
    assert %{"assignmentId" => nil, "workItemId" => nil, "seq" => seq} = card["turn"]
    assert is_integer(seq)
    assert turn

    {:ok, _} =
      DB.query(ctx.db, "UPDATE turns SET assignmentId=?1 WHERE seq=?2", [ctx.card.id, seq])

    assert %{"running" => true, "runningCards" => [%{"turn" => %{"assignmentId" => tied}}]} =
             one(ctx)

    assert tied == ctx.card.id
  end

  test "another user reads nothing it could not already read", ctx do
    Devices.add_user(ctx.db, "outsider", false)

    {:pending, _} =
      Devices.pair(ctx.db, %{
        device_id: "outsider",
        claimed_name: "Out",
        platform: nil,
        model: nil
      })

    %{token: token} = Devices.approve(ctx.db, "outsider", "outsider")
    page = read(ctx, "workItemIds=#{ctx.item.id}&assignmentIds=#{ctx.card.id}", token)
    assert page["items"] == [] and page["assignments"] == []

    assert page["notFound"] == %{
             "workItemIds" => [ctx.item.id],
             "assignmentIds" => [ctx.card.id]
           }

    # An owner that is not an admin: the item is theirs; the other owner's wake and turn stay hidden.
    {:ok, _} =
      DB.query(ctx.db, "UPDATE work_items SET ownerUserId='outsider' WHERE id=?1", [ctx.item.id])

    wake(ctx, %{assignment_id: ctx.card.id, condition_kind: "x", condition_scope: "y"})

    {:ok, _} =
      DB.query(ctx.db, "UPDATE sessions SET ownerUserId='flynn' WHERE sessionKey=?1", [ctx.holder])

    principal = %{kind: "user", id: "outsider", is_admin: false}

    refute StateVisibility.core_detail_visible?(
             ctx.db,
             "turns",
             %{session_key: ctx.holder},
             principal
           )

    {:ok, _} =
      Ledger.enqueue(ctx.db, %{
        session_key: ctx.holder,
        message_id: "hidden",
        origin: "user:flynn",
        prompt: "Work"
      })

    {:ok, _} = Ledger.claim_next(ctx.db, ctx.holder, "test")
    item = read(ctx, "workItemIds=" <> ctx.item.id, token)["items"] |> hd()
    assert item["runningCards"] == []
    assert item["waiting"]["event"]

    # The wake names this owner's card, which the existing notice grant already shows.
    assert [%{"by" => "event"}] = item["waits"]
  end

  test "the batch is capped and a bad query is refused by name", ctx do
    ids = fn prefix, n -> Enum.map_join(1..n, ",", &"#{prefix}_#{&1}") end
    assert read(ctx, "workItemIds=" <> ids.("wi", 50))["items"] == []
    assert read(ctx, "workItemIds=#{ids.("wi", 50)}&assignmentIds=#{ids.("asg", 50)}")

    for query <- ["workItemIds=" <> ids.("wi", 51), "assignmentIds=" <> ids.("asg", 51)] do
      response = get(ctx, query)
      assert response.status == 400

      assert %{"code" => "too_many_ids", "message" => "Name at most 50 workItemIds" <> _} =
               JSON.decode!(response.resp_body)["error"]
    end

    for query <- ["", "workItemIds=", "workItemIds=a,,b", "workItemIds=a&workItemIds=b", "x=1"] do
      response = get(ctx, query)
      assert response.status == 400

      assert JSON.decode!(response.resp_body)["error"]["code"] in [
               "invalid_indicators_query",
               "malformed_query"
             ]
    end

    assert get(ctx, "workItemIds=a", "wrong").status == 401
  end

  test "links per item are bounded and say so", ctx do
    for i <- 1..21,
        do:
          wake(ctx, %{assignment_id: ctx.card.id, condition_kind: "k#{i}", condition_scope: "s"})

    item = one(ctx)
    assert length(item["waits"]) == 20
    assert item["waitsTruncated"]
  end

  test "a waited-on holder's running state ignores its finished turns", ctx do
    target = open_card(ctx.db, ctx.other, work_item(ctx.db, "Target").id)

    wake(ctx, %{
      assignment_id: ctx.card.id,
      condition_kind: "assignment-landed",
      condition_scope: target.id
    })

    {:ok, _} =
      DB.query(
        ctx.db,
        """
        INSERT INTO turns(sessionKey,messageId,origin,prompt,status,createdAt,startedAt,endedAt)
        SELECT ?1,'done_'||value,'user:flynn','x','delivered',1,1,2 FROM json_each(?2)
        """,
        [ctx.other, JSON.encode!(Enum.to_list(1..2000))]
      )

    holder = fn -> one(ctx)["waits"] |> hd() |> get_in(["waitOn", Access.at(0), "holder"]) end
    assert %{"running" => false, "runningSince" => nil} = holder.()

    {:ok, _} =
      Ledger.enqueue(ctx.db, %{
        session_key: ctx.other,
        message_id: "now",
        origin: "user:flynn",
        prompt: "Work"
      })

    assert %{"running" => false} = holder.()
    {:ok, _} = Ledger.claim_next(ctx.db, ctx.other, "test")
    assert %{"running" => true, "runningSince" => at} = holder.()
    assert is_integer(at)
  end

  test "every statement seeks the named records", ctx do
    wake(ctx, %{assignment_id: ctx.card.id, condition_kind: "k", condition_scope: "s"})
    question(ctx, "dr_plan", ctx.card.id)
    # A wait on another agent's card also reads that holder, idle or in a turn.
    target = open_card(ctx.db, ctx.other, work_item(ctx.db, "Target").id)

    wake(ctx, %{
      assignment_id: ctx.card.id,
      condition_kind: "assignment-landed",
      condition_scope: target.id
    })

    observer = self()
    trace = fn event -> send(observer, event) end
    ctx = %{ctx | opts: Keyword.put(ctx.opts, :core_detail_trace, trace)}
    read(ctx, "workItemIds=#{ctx.item.id}&assignmentIds=#{ctx.card.id}")
    statements = flush([])
    assert length(statements) >= 5

    plans =
      for {sql, params} <- statements do
        {:ok, plan} = DB.query(ctx.db, "EXPLAIN QUERY PLAN " <> sql, params)
        plan = Enum.map_join(plan, "\n", &List.last/1)
        # Walking a whole index prints its name too, so a name alone proves nothing.
        refute plan =~ ~r/SCAN \w+ USING/, sql <> "\n" <> plan
        # A session's turn history is not bounded by the named records.
        refute plan =~ "USING INDEX turns_session", sql <> "\n" <> plan
        plan
      end
      |> Enum.join("\n")

    for seek <- [
          "SEARCH w USING INDEX wakes_wait_links_item",
          "SEARCH w USING INDEX wakes_assignment",
          "SEARCH d USING INDEX decision_requests_rest_assignment_order",
          "SEARCH d USING INDEX decision_requests_wait_item",
          "SEARCH r USING INDEX row_reaction_output",
          "SEARCH cp USING INDEX cannot_proceed_wait_assignment",
          "SEARCH t USING COVERING INDEX turns_wait_item",
          "SEARCH t USING COVERING INDEX turns_wait_assignment",
          "SEARCH t USING INDEX turns_pending",
          "SEARCH turns USING INDEX turns_pending"
        ] do
      assert plans =~ seek, seek <> "\n" <> plans
    end
  end

  defp flush(acc) do
    receive do
      {:sql_query, sql, params} -> flush([{sql, params} | acc])
      _ -> flush(acc)
    after
      0 -> Enum.reverse(acc)
    end
  end
end
