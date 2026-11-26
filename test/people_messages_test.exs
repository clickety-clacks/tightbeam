defmodule Tightbeam.PeopleMessagesTest do
  use Tightbeam.TestCase, async: false

  alias Tightbeam.{DB, Devices, Escalation, Model, Org, PeopleMessages}

  @sender "agent:people:sender"
  @relay "agent:people:relay"
  @work "wi-people"
  @owner "fixture-owner"
  @parent "agent:people:parent"

  setup tags do
    db = :people_messages_test_db
    start_supervised!({DB, path: ":memory:", name: db})
    :ok = Tightbeam.Schema.ensure_all(db)

    Devices.pair(db, %{
      device_id: "people-device",
      claimed_name: @owner,
      platform: nil,
      model: nil
    })

    parent = if tags[:with_parent], do: @parent
    if parent, do: create_session(db, parent, "other-test-host", nil)
    create_session(db, @sender, "test-host", parent)

    {:ok, []} =
      DB.query(
        db,
        """
        INSERT INTO work_items (id,title,ownerUserId,createdByUser,createdAt)
        VALUES (?1,'Fixture work',?2,?2,1)
        """,
        [@work, @owner]
      )

    %{db: db}
  end

  test "the owner default remains visible while queued and a whole refusal is durable", %{db: db} do
    params = %{"title" => "Progress", "body" => "Done", "work_item_id" => @work, "key" => "one"}

    assert %{"relay_configured" => false, "record" => sent} =
             call(db, @sender, "send", params, nil)

    assert sent["addresses"] == ["user:" <> @owner]
    assert sent["delivery_state"] == "waiting_undelivered"
    assert %{"record" => ^sent} = call(db, @sender, "send", params)
    assert %{code: "forbidden"} = call(db, @sender, "collect", %{})
    assert %{records: [^sent]} = call(db, @relay, "collect", %{})

    report = %{
      "id" => sent["id"],
      "outcomes" => [],
      "refusal" => %{
        "code" => "recipient_refused",
        "message" => "Recipient is outside the organization"
      }
    }

    assert %{accepted: true, duplicate: false} = call(db, @relay, "report", report)
    assert %{accepted: true, duplicate: true} = call(db, @relay, "report", report)
    assert %{records: []} = call(db, @relay, "collect", %{})

    assert %{"operations" => [%{"report" => ^report, "delivery_state" => "reported"}]} =
             call(db, @sender, "status", %{"conversation_id" => sent["id"]})
  end

  test "availability failure preserves named outcomes and consumes dependent operations", %{
    db: db
  } do
    id = send_request(db, %{"addresses" => ["user:" <> @owner, "user:another-person"]})

    assert %{"record" => %{"id" => reply_id}} =
             call(db, @sender, "reply", %{"conversation_id" => id, "body" => "Early reply"})

    report = %{
      "id" => id,
      "outcomes" => [
        %{"address" => "user:" <> @owner, "status" => "not_reachable"},
        %{"address" => "user:another-person", "status" => "refused", "reason" => "not_delivered"}
      ],
      "refusal" => %{"code" => "decider_unreachable", "message" => "The decider is unavailable"}
    }

    assert %{accepted: true} = call(db, @relay, "report", report)
    assert %{records: []} = call(db, @relay, "collect", %{})

    assert %{
             "state" => "undelivered",
             "operations" => [
               %{"report" => ^report},
               %{
                 "id" => ^reply_id,
                 "report" => %{"refusal" => %{"code" => "initial_send_undelivered"}}
               }
             ]
           } = call(db, @sender, "status", %{"conversation_id" => id})
  end

  test "a repeated attributed event commits one wake and chat and answers have distinct IDs", %{
    db: db
  } do
    id = send_request(db, %{"answer_rule" => %{"kind" => "first"}})
    bind_remote(db, id)

    answer = event("answer", "shared-id", %{"answer" => "yes"})
    chat = event("chat", "shared-id", %{"body" => "Follow-up"})
    assert %{accepted: true, duplicate: false} = call(db, @relay, "event", answer)
    assert %{accepted: true, duplicate: true} = call(db, @relay, "event", answer)
    assert %{accepted: true, duplicate: false} = call(db, @relay, "event", chat)

    assert {:ok, [["answer", answer_prompt], ["chat", chat_prompt]]} =
             DB.query(
               db,
               """
               SELECT e.kind,w.prompt FROM people_events e JOIN wakes w ON w.wakeId=e.wakeId
               WHERE w.sessionKey=?1 ORDER BY e.kind
               """,
               [@sender]
             )

    assert answer_prompt =~ "Fixture Person"
    assert answer_prompt =~ ~s("answer_disposition":"settled")
    assert chat_prompt =~ "Follow-up"
  end

  test "decision advice leaves the request open until its named decider answers", %{db: db} do
    request =
      Escalation.operator_ask(db, %{
        verb: "operator-ask",
        origin: "agent:people",
        principal: {:session, @sender},
        transport_session_key: @sender,
        params: %{question: "Proceed?", project: "Fixture", work_item_id: @work}
      })

    id =
      send_request(db, %{
        "answer_rule" => %{"kind" => "named", "address" => "user:" <> @owner},
        "decision_request_id" => request.id,
        "choices" => [%{"id" => "yes", "label" => "accept"}]
      })

    bind_remote(db, id)

    advice = event("answer", "advice", %{"answer" => "yes"})
    assert %{accepted: true} = call(db, @relay, "event", advice)

    assert {:ok, [["open"]]} =
             DB.query(db, "SELECT status FROM decision_requests WHERE id=?1", [request.id])

    answer = event("answer", "ruling", %{"answer" => "yes"})
    answer = put_in(answer, ["speaker", "address"], "user:" <> @owner)
    assert %{accepted: true} = call(db, @relay, "event", answer)
    assert %{accepted: true, duplicate: true} = call(db, @relay, "event", answer)

    assert {:ok, [["ruled", "user:" <> @owner, "accept"]]} =
             DB.query(db, "SELECT status,ruledBy,decision FROM decision_requests WHERE id=?1", [
               request.id
             ])
  end

  @tag with_parent: true
  test "a retired origin hands its pending events to its cross-host parent", %{db: db} do
    parent = @parent
    id = send_request(db, %{})
    bind_remote(db, id)

    assert %{accepted: true} =
             call(db, @relay, "event", event("chat", "before", %{"body" => "Pending"}))

    Org.retire(db, @sender, "process:tightbeam")

    assert {:ok, [[^parent]]} =
             DB.query(db, """
             SELECT w.sessionKey FROM people_events e JOIN wakes w ON w.wakeId=e.wakeId
             WHERE e.event='before'
             """)

    assert %{accepted: true} =
             call(db, @relay, "event", event("chat", "after", %{"body" => "Next"}))

    assert %{"record" => %{"kind" => "reply", "sender_session" => @sender}} =
             call(db, parent, "reply", %{"conversation_id" => id, "body" => "Understood"})

    assert %{code: _} = call(db, parent, "withdraw", %{"conversation_id" => id})
  end

  test "retirement without a successor queues one closing line", %{db: db} do
    id = send_request(db, %{})
    bind_remote(db, id)
    Org.retire(db, @sender, "process:tightbeam")

    assert %{
             records: [
               %{
                 "kind" => "close",
                 "conversation_id" => ^id,
                 "body" => body,
                 "server_id" => "service",
                 "remote_conversation_id" => "thread"
               }
             ]
           } =
             call(db, @relay, "collect", %{})

    assert body =~ "no agent inherited it"
  end

  defp call(db, session, command, params, relay \\ @relay) do
    PeopleMessages.dispatch(
      db,
      %{
        verb: "people-" <> command,
        principal: {:session, session},
        transport_session_key: session,
        params: params
      },
      relay
    )
  end

  defp send_request(db, params) do
    fields = %{"title" => "Fixture", "body" => "Message", "work_item_id" => @work}
    assert %{"record" => %{"id" => id}} = call(db, @sender, "send", Map.merge(fields, params))
    id
  end

  defp bind_remote(db, id) do
    assert %{accepted: true} =
             call(db, @relay, "report", %{
               "id" => id,
               "server_id" => "service",
               "remote_conversation_id" => "thread",
               "outcomes" => [%{"address" => "user:" <> @owner, "status" => "reached"}]
             })
  end

  defp event(kind, id, content) do
    %{
      "kind" => kind,
      "event_id" => id,
      "server_id" => "service",
      "remote_conversation_id" => "thread",
      "revision" => 1,
      "content" => content,
      "speaker" => %{"address" => "user:another-person", "display_name" => "Fixture Person"}
    }
  end

  defp create_session(db, key, host, parent) do
    Org.create(db, %{
      session_key: key,
      display_name: key,
      owner_user_id: @owner,
      origin: "user:" <> @owner,
      archetype: "default",
      host: host,
      spawned_by: parent,
      harness: "claude",
      provider: "anthropic",
      model: Model.new("fable")
    })
  end
end
