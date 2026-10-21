defmodule Tightbeam.HarklightTest do
  use Tightbeam.TestCase, async: false

  alias Tightbeam.{DB, EventLog, Gateway, Harklight, Model, Org, Projection, Wakes}

  setup do
    db = String.to_atom("harklight_db_#{System.unique_integer([:positive])}")
    start_supervised!({DB, path: ":memory:", name: db})
    :ok = ensure_all_schemas(db)

    :ok =
      DB.execute(
        db,
        "INSERT INTO users (userId,isAdmin,creationKind,createdAt) VALUES ('flynn',0,'admin_add',1)"
      )

    create_session(db, Org.personal_session_key("flynn"), "Main", "main")
    create_session(db, "harklight-origin", "Origin", "custom")
    create_session(db, "other-origin", "Other origin", "custom")

    %{
      db: db,
      recipient: "harklight-origin",
      other: "other-origin",
      main: Org.personal_session_key("flynn")
    }
  end

  test "registration is durable, idempotent, and bound to the registering session", ctx do
    first = register(ctx.db, ctx.recipient, "handle-1", "sender-1", "message-1")

    assert first.handle == "handle-1"
    assert first.recipient_session_key == ctx.recipient
    assert first.listener == "not_started"
    refute first.existing

    repeated = register(ctx.db, ctx.recipient, "handle-1", "sender-1", "message-1")
    assert repeated.existing

    conflict = register(ctx.db, ctx.other, "handle-1", "sender-1", "message-1")
    assert conflict.code == "recipient_conflict"

    recipient = ctx.recipient

    assert {:ok, [[^recipient, "listening"]]} =
             DB.query(
               ctx.db,
               "SELECT recipientSessionKey,state FROM harklight_handles WHERE sessionHandle='handle-1'"
             )
  end

  test "capture preserves the printed entry and an r16 re-offer does not create another wake",
       ctx do
    register(ctx.db, ctx.recipient, "handle-1", "sender-1", "message-1")

    raw =
      ~s({"sender_id":"sender-1","message_id":"message-1","event_id":"turn-1","kind":"turn","author":"person","request_revision":1,"delivered":false,"acted":false,"message":"ship it, but skip docs"})

    assert {:captured, wake_id} = Harklight.accept_line(ctx.db, "handle-1", raw)
    wake = Wakes.get(ctx.db, wake_id)

    assert wake.session_key == ctx.recipient
    assert is_nil(wake.target_role)
    assert wake.prompt =~ raw

    assert wake.prompt =~
             "sender_id=sender-1, message_id=message-1, handle=handle-1, event_id=turn-1"

    assert wake.prompt =~ "harklight-agent ack --event turn-1"

    assert wake.prompt =~
             "harklight-agent reply --request message-1 --in-reply-to turn-1 --body"

    assert wake.prompt =~ "Do not run `harklight-agent listen`"

    reoffered = String.replace(raw, "\"delivered\":false", "\"delivered\":true")
    assert {:duplicate, ^wake_id} = Harklight.accept_line(ctx.db, "handle-1", reoffered)
    assert Wakes.get(ctx.db, wake_id).prompt == wake.prompt
    assert {:ok, [[1]]} = DB.query(ctx.db, "SELECT COUNT(*) FROM harklight_entries")
  end

  test "sequential feed entries receive strictly ordered wake times", ctx do
    register(ctx.db, ctx.recipient, "handle-1", "sender-1", "message-1")

    first = event_line("turn-1")
    second = event_line("turn-2")

    assert {:captured, _} = Harklight.accept_line(ctx.db, "handle-1", first)
    assert {:captured, _} = Harklight.accept_line(ctx.db, "handle-1", second)

    assert {:ok, [["turn-1", first_due], ["turn-2", second_due]]} =
             DB.query(
               ctx.db,
               "SELECT e.eventId,w.dueAt FROM harklight_entries e JOIN wakes w ON w.wakeId=e.wakeId WHERE e.sessionHandle='handle-1' ORDER BY w.dueAt"
             )

    assert second_due > first_due
  end

  test "delivery preparation never substitutes another session", ctx do
    register(ctx.db, ctx.recipient, "handle-1", "sender-1", "message-1")
    assert {:captured, wake_id} = Harklight.accept_line(ctx.db, "handle-1", event_line("turn-1"))

    assert {:ok, :deliver} =
             DB.transaction(ctx.db, fn txn ->
               Harklight.prepare_delivery_in_txn(txn, wake_id, ctx.recipient)
             end)

    assert {:ok, :rejected} =
             DB.transaction(ctx.db, fn txn ->
               assert_raise ArgumentError, ~r/targets other-origin/, fn ->
                 Harklight.prepare_delivery_in_txn(txn, wake_id, ctx.other)
               end

               :rejected
             end)

    assert Wakes.get(ctx.db, wake_id).session_key == ctx.recipient
    assert Wakes.get(ctx.db, wake_id).state == "pending"
  end

  test "handling text covers terminal outcomes and checks delivered work before acting", ctx do
    register(ctx.db, ctx.recipient, "handle-1", "sender-1", "message-1")

    answered =
      ~s({"sender_id":"sender-1","message_id":"message-1","event_id":"answer-1","kind":"terminal","terminal_state":"answered","author":"agent","request_revision":1,"delivered":true,"acted":false,"message":"approve"})

    assert {:captured, answered_wake_id} = Harklight.accept_line(ctx.db, "handle-1", answered)
    answered_prompt = Wakes.get(ctx.db, answered_wake_id).prompt
    ack_at = elem(:binary.match(answered_prompt, "harklight-agent ack --event answer-1"), 0)
    check_at = elem(:binary.match(answered_prompt, "check whether earlier work"), 0)
    author_at = elem(:binary.match(answered_prompt, "do not treat it as Mike's choice"), 0)

    apply_at =
      elem(
        :binary.match(answered_prompt, "Apply the answer carried by event answer-1 at most once"),
        0
      )

    assert ack_at < check_at
    assert check_at < author_at
    assert author_at < apply_at

    assert answered_prompt =~
             "harklight-agent result --request message-1 --status applied"

    assert answered_prompt =~
             "harklight-agent result --request message-1 --status refused"

    assert answered_prompt =~
             "harklight-agent result --request message-1 --status received"

    assert answered_prompt =~ "If you cannot tell, do not apply it again"

    cleared =
      ~s({"sender_id":"sender-1","message_id":"message-1","event_id":"clear-1","kind":"terminal","terminal_state":"cleared","author":"person","request_revision":1,"delivered":false,"acted":false,"message":"stop"})

    assert {:captured, cleared_wake_id} = Harklight.accept_line(ctx.db, "handle-1", cleared)
    cleared_prompt = Wakes.get(ctx.db, cleared_wake_id).prompt
    assert cleared_prompt =~ "Stop work on this request"
    refute cleared_prompt =~ "harklight-agent reply"
    refute cleared_prompt =~ "harklight-agent result"
  end

  test "retirement and listener completion retain the exact-session wake and notify its owner once",
       ctx do
    register(ctx.db, ctx.recipient, "handle-1", "sender-1", "message-1")
    raw = event_line("turn-1", "private user words")
    assert {:captured, wake_id} = Harklight.accept_line(ctx.db, "handle-1", raw)
    wake = Wakes.get(ctx.db, wake_id)

    Org.retire(ctx.db, ctx.recipient, "user:flynn", 1_000)
    assert Wakes.get(ctx.db, wake_id).state == "pending"

    assert :complete =
             Harklight.accept_line(ctx.db, "handle-1", ~s({"kind":"idle","open_requests":0}))

    assert Harklight.registered_handles(ctx.db) == []
    assert Wakes.get(ctx.db, wake_id).state == "pending"

    assert {:ok, {:harklight_held, notice}} =
             DB.transaction(ctx.db, fn txn ->
               Gateway.deliver_prompt_in_txn(
                 txn,
                 ctx.recipient,
                 "process:tightbeam",
                 wake.prompt,
                 db: ctx.db,
                 wake_id: wake_id,
                 fire_wake_in_txn: true
               )
             end)

    assert is_list(notice)

    assert Gateway.complete_delivery(ctx.db, {:harklight_held, notice}) ==
             {:retry, :harklight_recipient_unavailable}

    assert Wakes.get(ctx.db, wake_id).state == "pending"

    assert {:ok, {:harklight_held, nil}} =
             DB.transaction(ctx.db, fn txn ->
               Gateway.deliver_prompt_in_txn(
                 txn,
                 ctx.recipient,
                 "process:tightbeam",
                 wake.prompt,
                 db: ctx.db,
                 wake_id: wake_id,
                 fire_wake_in_txn: true
               )
             end)

    assert Enum.count(
             EventLog.lifecycle_events(ctx.db),
             &(&1.kind == "harklight_recipient_unavailable")
           ) == 1

    assert [notice] =
             Projection.list_after(ctx.db, ctx.main, nil, 10)
             |> Enum.filter(
               &String.contains?(&1.content, "Harklight entry for Tightbeam session")
             )

    assert notice.content =~ "held for that same session"
    refute notice.content =~ "private user words"
    assert Wakes.get(ctx.db, wake_id).session_key == ctx.recipient
  end

  test "notice batching holds a retired Harklight recipient on its registered session", ctx do
    register(ctx.db, ctx.recipient, "handle-1", "sender-1", "message-1")
    assert {:captured, source_wake_id} = Harklight.accept_line(ctx.db, "handle-1", event_line("turn-1"))

    Org.retire(ctx.db, ctx.recipient, "user:flynn", 1_000)

    assert [carrier_wake_id] =
             Tightbeam.NoticeBatcher.recover(
               ctx.db,
               System.system_time(:millisecond),
               [],
               ctx.recipient
             )

    assert %{state: "pending", session_key: recipient} = Wakes.get(ctx.db, source_wake_id)
    assert recipient == ctx.recipient
    assert %{state: "pending", session_key: ^recipient, digest: true} =
             Wakes.get(ctx.db, carrier_wake_id)

    assert {:ok, [["delivery_pending"]]} =
             DB.query(
               ctx.db,
               "SELECT state FROM notice_batches WHERE deliveryWakeId=?1",
               [carrier_wake_id]
             )

    assert Enum.count(
             EventLog.lifecycle_events(ctx.db),
             &(&1.kind == "harklight_recipient_unavailable")
           ) == 1
  end

  defp register(db, recipient, handle, sender_id, message_id) do
    Harklight.register(
      db,
      %{
        principal: {:session, recipient},
        params: %{session_handle: handle, sender_id: sender_id, message_id: message_id}
      },
      start_listener: false
    )
  end

  defp event_line(event_id, message \\ "ship it") do
    JSON.encode!(%{
      "sender_id" => "sender-1",
      "message_id" => "message-1",
      "event_id" => event_id,
      "kind" => "turn",
      "author" => "person",
      "request_revision" => 1,
      "delivered" => false,
      "acted" => false,
      "message" => message
    })
  end

  defp create_session(db, session_key, display_name, kind) do
    Org.create(db, %{
      session_key: session_key,
      display_name: display_name,
      kind: kind,
      is_built_in: kind == "main",
      owner_user_id: "flynn",
      origin: "user:flynn",
      archetype: "default",
      host: "testhost",
      harness: "claude",
      provider: "anthropic",
      model: Model.new("fable")
    })
  end
end
