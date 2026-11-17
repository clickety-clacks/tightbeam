defmodule Tightbeam.HarklightBriefingsTest do
  use Tightbeam.TestCase, async: false

  alias Tightbeam.{
    DB,
    Devices,
    Escalation,
    Gateway,
    HarklightBriefings,
    HarklightFollows,
    HarklightWakes,
    Model,
    Org,
    Placement,
    Rules
  }

  @owner "briefing-test-owner"

  setup do
    db = :"harklight_briefings_#{System.unique_integer([:positive])}"
    start_supervised!({DB, path: ":memory:", name: db})
    :ok = ensure_all_schemas(db)
    Devices.add_user(db, @owner, true)

    main = create_session(db, Org.personal_session_key(@owner), "Main")
    compiler = create_session(db, "briefing-compiler", "Compiler", main.session_key)
    consumer = create_session(db, "briefing-consumer", "Consumer", main.session_key)

    base_dir =
      Path.join(System.tmp_dir!(), "harklight-briefings-#{System.unique_integer([:positive])}")

    File.mkdir_p!(Path.join(base_dir, "identity/rules"))
    Rules.load!(Path.join(System.tmp_dir!(), "missing-harklight-briefings"), [])

    on_exit(fn ->
      File.rm_rf!(base_dir)
      Rules.load!(System.tmp_dir!() <> "/missing-harklight-briefings-reset", [])
    end)

    %{
      db: db,
      base_dir: base_dir,
      main: main,
      compiler: compiler,
      consumer: consumer,
      call: session_call(compiler.session_key)
    }
  end

  test "catchup stages every open request and admits only the requested number once", ctx do
    requests = Enum.map(1..3, fn n -> open_request(ctx, "Question #{n}?") end)
    load_briefing_rule(ctx, ctx.consumer.session_key)

    assert %{ok: true, listed: 3, admitted: 1, staged: 2, requests: first} =
             catchup(ctx, 1)

    assert MapSet.new(Enum.map(first, & &1.request_id)) == MapSet.new(Enum.map(requests, & &1.id))
    assert briefing_wake_count(ctx.db) == 1

    assert %{ok: true, listed: 3, admitted: 2, staged: 1, requests: second} =
             catchup(ctx, 1)

    assert Enum.count(second, &(&1.state == "admitted")) == 2
    assert briefing_wake_count(ctx.db) == 2

    assert %{ok: true, listed: 3, admitted: 3, staged: 0, requests: third} =
             catchup(ctx, 10)

    assert Enum.count(third, &(&1.state == "admitted")) == 3
    assert briefing_wake_count(ctx.db) == 3
    assert %{ok: true, listed: 3, admitted: 3} = catchup(ctx, 10)
    assert briefing_wake_count(ctx.db) == 3
  end

  test "a filed request wake is reused and its compiler reserves one durable send identity",
       ctx do
    load_briefing_rule(ctx, ctx.consumer.session_key)
    request = open_request(ctx, "Choose one route?")

    assert briefing_wake_count(ctx.db) == 1

    assert %{ok: true, listed: 1, admitted: 1, requests: [%{request_id: id, state: "admitted"}]} =
             catchup(ctx, 1)

    assert id == request.id

    assert briefing_wake_count(ctx.db) == 1

    send_call = %{
      session_call(ctx.consumer.session_key)
      | params: %{
          harklight_session: "new",
          sender_id: "briefing-sender",
          title: "Decision briefing"
        }
    }

    assert {:ok, %{action: :start, op_id: first_op}} =
             HarklightBriefings.reserve_send(ctx.db, send_call, request.id)

    assert {:ok, %{action: :start, op_id: ^first_op}} =
             HarklightBriefings.reserve_send(ctx.db, send_call, request.id)

    assert {:ok, [["reserved", ^first_op, session_key]]} =
             DB.query(
               ctx.db,
               "SELECT state,sendOpId,sessionKey FROM harklight_decision_briefings WHERE requestId=?1",
               [request.id]
             )

    assert session_key == ctx.consumer.session_key

    assert {:error, "harklight_briefing_origin_mismatch", _} =
             HarklightBriefings.reserve_send(ctx.db, ctx.call, request.id)

    handle = "a1424ed8-763c-4b13-9a0d-55a70cd65b17"
    message_id = "decision-briefing-thread"

    payload =
      Elixir.JSON.encode!(%{
        "request" => %{
          "message" => %{
            "sender_id" => "briefing-sender",
            "message_id" => message_id,
            "title" => "Decision briefing",
            "supersedes" => []
          }
        },
        "files" => [],
        "decision_request_id" => request.id
      })

    assert %{state: "pending"} =
             HarklightWakes.prepare_send(ctx.db, send_call, first_op, payload)

    result =
      JSON.encode!(%{
        "kind" => "committed",
        "operation" => "send",
        "op_id" => first_op,
        "response" => %{"session_handle" => handle, "revision" => 1}
      })

    assert %{state: "registered"} =
             HarklightWakes.bind_send(
               ctx.db,
               send_call,
               first_op,
               payload,
               result,
               handle,
               "briefing-sender",
               message_id
             )

    assert {:ok, %{action: :existing, op_id: ^first_op, message_id: ^message_id}} =
             HarklightBriefings.reserve_send(ctx.db, send_call, request.id)

    assert %{ok: true, reused: 1, requests: [%{state: "reused", session_key: session_key}]} =
             catchup(ctx, 10)

    assert session_key == ctx.consumer.session_key
    assert briefing_wake_count(ctx.db) == 1

    follow_call = %{
      session_call(ctx.main.session_key)
      | verb: "harklight-follow",
        params: %{handle: handle}
    }

    status_runner = fn ["status", "--session", session_handle] ->
      {JSON.encode!(%{
         "session_handle" => session_handle,
         "open_requests" => 1,
         "open_chats" => 1,
         "pending_undelivered" => 0,
         "pending_delivered_unacted" => 0
       }), 0}
    end

    assert %{outcome: "committed"} =
             HarklightFollows.follow(ctx.db, follow_call,
               runner: status_runner,
               activate: false
             )

    chat_entry =
      JSON.encode!(%{
        "kind" => "event",
        "session_handle" => handle,
        "event_id" => "1",
        "feed_cursor" => 1,
        "request" => %{"sender_id" => "briefing-sender", "message_id" => message_id},
        "request_revision" => 1,
        "delivered" => false,
        "acted" => false,
        "entry" => %{
          "kind" => "discussion",
          "author" => "person",
          "content" => "I choose accept."
        }
      })

    assert :ok = HarklightWakes.capture_line(ctx.db, handle, chat_entry)

    chat_wake_id = "w_harklight_#{handle}_" <> String.pad_leading("1", 20, "0")

    assert {:ok, [[prompt, ^session_key]]} =
             DB.query(ctx.db, "SELECT prompt,sessionKey FROM wakes WHERE wakeId=?1", [
               chat_wake_id
             ])

    assert prompt =~ request.id
    assert prompt =~ "same session and thread"
    assert prompt =~ "quote the exact choice"

    assert {:ok, [[prior_follower_wake, prior_follower_prompt]]} =
             DB.query(
               ctx.db,
               "SELECT w.wakeId,w.prompt FROM harklight_wake_deliveries d JOIN wakes w ON w.wakeId=d.wakeId WHERE d.sessionKey=?1",
               [ctx.main.session_key]
             )

    assert prior_follower_prompt =~ request.id
    assert prior_follower_prompt =~ "same session and thread"
    assert %{state: "retired"} = Org.retire(ctx.db, session_key, "user:#{@owner}", 60_000)

    assert {:ok, [[new_follower_wake, handoff_prompt]]} =
             DB.query(
               ctx.db,
               "SELECT w.wakeId,w.prompt FROM harklight_wake_deliveries d JOIN wakes w ON w.wakeId=d.wakeId WHERE d.sessionKey=?1",
               [ctx.main.session_key]
             )

    refute new_follower_wake == prior_follower_wake
    assert handoff_prompt =~ "has retired"
    assert handoff_prompt =~ request.id
    assert handoff_prompt =~ "same session and thread"

    assert {:ok, [[^prior_follower_prompt]]} =
             DB.query(ctx.db, "SELECT prompt FROM wakes WHERE wakeId=?1", [prior_follower_wake])
  end

  test "catchup excludes resolved requests and reports all remaining requests", ctx do
    open = open_request(ctx, "Still open?")
    resolved = open_request(ctx, "Already settled?")
    open_id = open.id
    resolved_id = resolved.id

    rule_call = %{
      verb: "operator-rule",
      origin: "user:#{@owner}",
      principal: {:user, @owner},
      params: %{request_id: resolved_id, decision: "accept", rationale: "Prior decision"}
    }

    assert %{status: "ruled", decision: "accept"} =
             Escalation.operator_rule(ctx.db, rule_call, authorized: true)

    load_briefing_rule(ctx, ctx.consumer.session_key)

    assert %{ok: true, listed: 2, admitted: 1, excluded: 1, requests: entries} = catchup(ctx, 5)

    assert %{state: "admitted", request_id: ^open_id} =
             Enum.find(entries, &(&1.request_id == open_id))

    assert %{state: "excluded", request_id: ^resolved_id} =
             Enum.find(entries, &(&1.request_id == resolved_id))

    assert briefing_wake_count(ctx.db) == 1
  end

  test "catchup refuses callers without the gateway admin authorization", ctx do
    assert %{ok: false, code: "not_owner"} =
             HarklightBriefings.catchup(ctx.db, ctx.call, authorized: false)

    assert {:ok, [[0]]} =
             DB.query(ctx.db, "SELECT COUNT(*) FROM harklight_decision_briefings")
  end

  defp catchup(ctx, limit) do
    HarklightBriefings.catchup(ctx.db, Map.put(ctx.call, :params, %{limit: limit}),
      authorized: true
    )
  end

  defp open_request(ctx, question) do
    Escalation.operator_ask(ctx.db, %{
      ctx.call
      | verb: "operator-ask",
        params: %{question: question}
    })
  end

  defp load_briefing_rule(ctx, target) do
    rules_dir = Path.join(ctx.base_dir, "identity/rules")

    File.write!(
      Path.join(rules_dir, "briefings.toml"),
      """
      [[rule]]
      name = "harklight-decision-request-briefing"
      verb = "condition"
      edges = ["row-commit"]
      effect = "notice"
      text = "route a filed decision request"
      deny_when = [
        { fact = "condition_fact.kind", op = "eq", value = "decision-request-filed" },
        { fact = "decision_request.addressed_principal", op = "eq", value = "user:#{@owner}" },
        { fact = "condition_fact.matches", op = "eq", value = true }
      ]

      [rule.notice]
      target_session = #{inspect(target)}
      prompt = "Investigate {decision_request_id}"
      """
    )

    handlers = Gateway.handlers(%{db: ctx.db, wake_tick_ms: 1_000})
    Rules.load!(ctx.base_dir, Map.keys(handlers))
  end

  defp briefing_wake_count(db) do
    assert {:ok, [[count]]} =
             DB.query(
               db,
               "SELECT COUNT(*) FROM wakes WHERE origin='remedy:harklight-decision-request-briefing'"
             )

    count
  end

  defp session_call(session_key) do
    %{
      verb: "harklight-briefings-catchup",
      origin: "agent:#{session_key}",
      principal: {:session, session_key},
      session_key: session_key,
      transport_session_key: session_key,
      params: %{}
    }
  end

  defp create_session(db, session_key, display_name, parent \\ nil) do
    Org.create(db, %{
      session_key: session_key,
      display_name: display_name,
      kind: if(session_key == Org.personal_session_key(@owner), do: "main", else: "custom"),
      owner_user_id: @owner,
      origin: "user:#{@owner}",
      spawned_by: parent,
      archetype: "default",
      host: Placement.local_host_name(),
      harness: "codex",
      provider: "openai",
      model: Model.new("fable")
    })
  end
end
