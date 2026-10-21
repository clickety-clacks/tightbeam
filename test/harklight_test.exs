defmodule Tightbeam.HarklightTest do
  use Tightbeam.TestCase, async: false

  alias Tightbeam.{DB, EventLog, Gateway, Harklight, Model, Org, Projection, Wakes}
  alias Tightbeam.Wire.Router

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

  test "registration accepts CLI JSON params after router atomization", ctx do
    cli_request = %{
      "verb" => "harklight-register",
      "params" => %{
        "sessionHandle" => "handle-from-cli",
        "senderId" => "sender-from-cli",
        "messageId" => "message-from-cli"
      }
    }

    registration =
      Harklight.register(
        ctx.db,
        %{
          principal: {:session, ctx.recipient},
          params:
            Router.atomize_params_for_test(cli_request["verb"], cli_request["params"])
        },
        start_listener: false
      )

    assert %{
             handle: "handle-from-cli",
             recipient_session_key: recipient,
             listener: "not_started",
             existing: false
           } = registration

    assert recipient == ctx.recipient
  end

  test "capture preserves the printed entry and an r16 re-offer does not create another wake",
       ctx do
    register(ctx.db, ctx.recipient, "handle-1", "sender-1", "message-1")

    raw = event_line("41", "ship it, but skip docs")

    assert {:captured, wake_id} = Harklight.accept_line(ctx.db, "handle-1", raw)
    wake = Wakes.get(ctx.db, wake_id)

    assert wake.session_key == ctx.recipient
    assert is_nil(wake.target_role)
    assert wake.prompt =~ raw

    assert wake.prompt =~
             "sender_id=sender-1, message_id=message-1, handle=handle-1, event_id=41"

    assert wake.prompt =~ "harklight-agent ack --event 41"

    assert wake.prompt =~
             "harklight-agent reply --request message-1 --in-reply-to 41 --body"

    assert wake.prompt =~ "Do not run `harklight-agent listen`"

    reoffered = String.replace(raw, "\"delivered\":false", "\"delivered\":true")
    assert {:duplicate, ^wake_id} = Harklight.accept_line(ctx.db, "handle-1", reoffered)
    assert Wakes.get(ctx.db, wake_id).prompt == wake.prompt
    assert {:ok, [[1]]} = DB.query(ctx.db, "SELECT COUNT(*) FROM harklight_entries")
  end

  test "sequential feed entries receive strictly ordered wake times", ctx do
    register(ctx.db, ctx.recipient, "handle-1", "sender-1", "message-1")

    first = event_line("41")
    second = event_line("42")

    assert {:captured, _} = Harklight.accept_line(ctx.db, "handle-1", first)
    assert {:captured, _} = Harklight.accept_line(ctx.db, "handle-1", second)

    assert {:ok, [["41", first_due], ["42", second_due]]} =
             DB.query(
               ctx.db,
               "SELECT e.eventId,w.dueAt FROM harklight_entries e JOIN wakes w ON w.wakeId=e.wakeId WHERE e.sessionHandle='handle-1' ORDER BY w.dueAt"
             )

    assert second_due > first_due
  end

  test "delivery preparation never substitutes another session", ctx do
    register(ctx.db, ctx.recipient, "handle-1", "sender-1", "message-1")
    assert {:captured, wake_id} = Harklight.accept_line(ctx.db, "handle-1", event_line("45"))

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
      event_line("43", "approve",
        kind: "terminal",
        terminal_state: "answered",
        author: "agent",
        delivered: true
      )

    assert {:captured, answered_wake_id} = Harklight.accept_line(ctx.db, "handle-1", answered)
    answered_prompt = Wakes.get(ctx.db, answered_wake_id).prompt
    ack_at = elem(:binary.match(answered_prompt, "harklight-agent ack --event 43"), 0)
    check_at = elem(:binary.match(answered_prompt, "check whether earlier work"), 0)
    author_at = elem(:binary.match(answered_prompt, "do not treat it as Mike's choice"), 0)

    apply_at =
      elem(
        :binary.match(answered_prompt, "Apply the answer carried by event 43 at most once"),
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
      event_line("44", "stop", kind: "terminal", terminal_state: "cleared")

    assert {:captured, cleared_wake_id} = Harklight.accept_line(ctx.db, "handle-1", cleared)
    cleared_prompt = Wakes.get(ctx.db, cleared_wake_id).prompt
    assert cleared_prompt =~ "Stop work on this request"
    refute cleared_prompt =~ "harklight-agent reply"
    refute cleared_prompt =~ "harklight-agent result"
  end

  test "accepts the Harklight CLI event-line shape for discussion, answered, and cleared entries",
       ctx do
    handle = "d0e4dced-75ed-4eeb-a320-0cd95b851e11"
    register(ctx.db, ctx.recipient, handle, "sender-1", "message-1")

    discussion =
      ~s({"acted":false,"delivered":false,"entry":{"author":"person","event_id":"17","kind":"discussion","message":"ship it, but skip docs","message_id":"message-1","request_revision":1,"sender_id":"sender-1","session_handle":"d0e4dced-75ed-4eeb-a320-0cd95b851e11"},"event_id":"17","feed_cursor":17,"kind":"event","pending_remaining":2,"request":{"message_id":"message-1","sender_id":"sender-1"},"request_revision":1,"session_handle":"d0e4dced-75ed-4eeb-a320-0cd95b851e11"})

    answered =
      ~s({"acted":false,"delivered":true,"entry":{"author":"agent","event_id":"18","kind":"terminal","message":"approve","message_id":"message-1","request_revision":2,"sender_id":"sender-1","session_handle":"d0e4dced-75ed-4eeb-a320-0cd95b851e11","terminal_state":"answered"},"event_id":"18","feed_cursor":18,"kind":"event","pending_remaining":1,"request":{"message_id":"message-1","sender_id":"sender-1"},"request_revision":2,"session_handle":"d0e4dced-75ed-4eeb-a320-0cd95b851e11"})

    cleared =
      ~s({"acted":false,"delivered":false,"entry":{"author":"person","event_id":"19","kind":"terminal","message":"stop","message_id":"message-1","request_revision":3,"sender_id":"sender-1","session_handle":"d0e4dced-75ed-4eeb-a320-0cd95b851e11","terminal_state":"cleared"},"event_id":"19","feed_cursor":19,"kind":"event","pending_remaining":0,"request":{"message_id":"message-1","sender_id":"sender-1"},"request_revision":3,"session_handle":"d0e4dced-75ed-4eeb-a320-0cd95b851e11"})

    assert {:captured, discussion_wake_id} = Harklight.accept_line(ctx.db, handle, discussion)
    assert Wakes.get(ctx.db, discussion_wake_id).prompt =~ discussion

    assert Wakes.get(ctx.db, discussion_wake_id).prompt =~
             "Entry kind: discussion; author: person"

    assert {:captured, answered_wake_id} = Harklight.accept_line(ctx.db, handle, answered)
    answered_prompt = Wakes.get(ctx.db, answered_wake_id).prompt
    assert answered_prompt =~ "Entry kind: terminal; author: agent; request revision: 2"
    assert answered_prompt =~ "This answer was authored by an agent"
    assert answered_prompt =~ "Apply the answer carried by event 18 at most once"

    assert {:captured, cleared_wake_id} = Harklight.accept_line(ctx.db, handle, cleared)
    assert Wakes.get(ctx.db, cleared_wake_id).prompt =~ "Stop work on this request"

    assert {:error, :invalid_entry} =
             Harklight.accept_line(
               ctx.db,
               handle,
               ~s({"sender_id":"sender-1","message_id":"message-1","event_id":"20","kind":"discussion","author":"person","request_revision":1,"delivered":false,"acted":false})
             )
  end

  test "retirement and listener completion retain the exact-session wake and notify its owner once",
       ctx do
    register(ctx.db, ctx.recipient, "handle-1", "sender-1", "message-1")
    raw = event_line("46", "private user words")
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

    assert {:ok, {:harklight_held, []}} =
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

    assert {:captured, source_wake_id} =
             Harklight.accept_line(ctx.db, "handle-1", event_line("47"))

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

  defp event_line(event_id, message \\ "ship it", opts \\ []) do
    handle = Keyword.get(opts, :handle, "handle-1")
    kind = Keyword.get(opts, :kind, "discussion")
    author = Keyword.get(opts, :author, "person")
    revision = Keyword.get(opts, :revision, 1)
    delivered = Keyword.get(opts, :delivered, false)
    acted = Keyword.get(opts, :acted, false)

    entry = %{
      "author" => author,
      "event_id" => event_id,
      "kind" => kind,
      "message" => message,
      "message_id" => "message-1",
      "request_revision" => revision,
      "sender_id" => "sender-1",
      "session_handle" => handle
    }

    entry =
      case Keyword.get(opts, :terminal_state) do
        nil -> entry
        terminal_state -> Map.put(entry, "terminal_state", terminal_state)
      end

    JSON.encode!(%{
      "acted" => acted,
      "delivered" => delivered,
      "entry" => entry,
      "event_id" => event_id,
      "feed_cursor" => String.to_integer(event_id),
      "kind" => "event",
      "pending_remaining" => 0,
      "request" => %{"message_id" => "message-1", "sender_id" => "sender-1"},
      "request_revision" => revision,
      "session_handle" => handle
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
