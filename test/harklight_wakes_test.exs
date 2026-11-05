defmodule Tightbeam.HarklightWakesTest do
  use Tightbeam.TestCase, async: false

  alias Tightbeam.{DB, HarklightSend, HarklightWakes, Model, Org, Placement, Wakes}

  @handle "7d737f62-bbd7-4c51-978d-f6ff5b4d8146"
  @send_op "0bdb87a0-3a09-4f61-bff4-9a4a704324c8"
  @payload ~s({"type":"send","message":{"sender_id":"sender","message_id":"request"}})
  @result ~s({"kind":"sent","session":"7d737f62-bbd7-4c51-978d-f6ff5b4d8146","sender_id":"sender","request":"request"})

  setup do
    db = :"harklight_wakes_#{System.unique_integer([:positive])}"
    start_supervised!({DB, path: ":memory:", name: db})
    :ok = ensure_all_schemas(db)

    {:ok, _} =
      DB.query(
        db,
        "INSERT INTO users(userId,isAdmin,creationKind,createdAt) VALUES('owner',0,'admin_add',1)"
      )

    main =
      Org.create(db, %{
        session_key: Org.personal_session_key("owner"),
        display_name: "Main",
        kind: "main",
        owner_user_id: "owner",
        origin: "user:owner",
        archetype: "default",
        host: Placement.local_host_name(),
        harness: "codex",
        provider: "openai",
        model: Model.new("fable")
      })

    session =
      Org.create(db, %{
        session_key: "agent:origin:one",
        display_name: "Origin",
        owner_user_id: "owner",
        origin: "user:owner",
        spawned_by: main.session_key,
        archetype: "default",
        host: Placement.local_host_name(),
        harness: "codex",
        provider: "openai",
        model: Model.new("fable")
      })

    call = %{
      session_key: session.session_key,
      principal: {:session, session.session_key},
      transport_session_key: session.session_key,
      params: %{
        harklight_handle: @handle,
        harklight_sender_id: "sender",
        harklight_message_id: "request"
      }
    }

    assert %{code: "harklight_send_pending"} = HarklightWakes.register(db, call)
    assert %{state: "pending"} = HarklightWakes.prepare_send(db, call, @send_op, @payload)

    assert %{state: "registered"} =
             HarklightWakes.bind_send(
               db,
               call,
               @send_op,
               @payload,
               @result,
               @handle,
               "sender",
               "request"
             )

    %{db: db, call: call, session: session, main: main}
  end

  test "a prepared send cannot bind through a different payload or origin", %{db: db, call: call} do
    assert %{code: "harklight_send_mismatch"} =
             HarklightWakes.prepare_send(db, call, @send_op, @payload <> " ")

    assert %{code: "harklight_origin_unavailable"} =
             HarklightWakes.bind_send(
               db,
               %{call | transport_session_key: "other"},
               @send_op,
               @payload,
               @result,
               @handle,
               "sender",
               "request"
             )

    assert %{code: "harklight_send_pending"} =
             HarklightWakes.register(db, put_in(call.params.harklight_message_id, "unbound"))

    assert %{state: "registered", op_id: @send_op} =
             HarklightWakes.bind_send(
               db,
               call,
               @send_op,
               @payload,
               @result,
               @handle,
               "sender",
               "request"
             )

    assert %{code: "harklight_send_mismatch"} =
             HarklightWakes.bind_send(
               db,
               call,
               @send_op,
               @payload,
               @result <> " ",
               @handle,
               "sender",
               "request"
             )
  end

  test "authenticated send persists the prepared request before execute and binds its original result",
       %{
         db: db,
         call: call
       } do
    handle = "a1424ed8-763c-4b13-9a0d-55a70cd65b17"
    request_id = "request-new"
    hash = String.duplicate("a", 64)

    send_call = %{
      call
      | params: %{
          harklight_session: "new",
          sender_id: "sender",
          title: "Question",
          files: ["/tmp/request.txt"]
        }
    }

    runner = fn args ->
      op_id = if "--prepare" in args, do: Enum.at(args, 3), else: List.last(args)

      cond do
        Enum.take(args, 2) == ["send", "--prepare"] ->
          assert "--controller" in args
          assert Enum.take(args, -2) == ["--file", "/tmp/request.txt"]

          assert {:ok, [[0]]} =
                   DB.query(db, "SELECT count(*) FROM harklight_send_operations WHERE opId=?1", [
                     op_id
                   ])

          frame = %{
            kind: "prepared",
            op_id: op_id,
            request: %{
              type: "send",
              op_id: op_id,
              session_handle: handle,
              route: "other",
              message: %{sender_id: "sender", message_id: request_id, title: "Question"},
              files: [%{name: "request.txt", upload_pending: true, size: 4, sha256: hash}]
            },
            files: [%{name: "request.txt", size_bytes: 4, sha256: hash}]
          }

          {JSON.encode!(frame) <> "\n", 0}

        Enum.take(args, 2) == ["send", "--execute"] ->
          assert {:ok, [[session, payload, attempted_at]]} =
                   DB.query(
                     db,
                     "SELECT sessionKey,payload,attemptedAt FROM harklight_send_operations WHERE opId=?1",
                     [op_id]
                   )

          assert session == call.session_key
          assert is_integer(attempted_at)
          assert JSON.decode!(payload)["request"]["message"]["message_id"] == request_id

          assert JSON.decode!(payload)["request"]["files"] == [
                   %{
                     "name" => "request.txt",
                     "upload_pending" => true,
                     "size" => 4,
                     "sha256" => hash
                   }
                 ]

          assert JSON.decode!(payload)["files"] == [
                   %{"name" => "request.txt", "size_bytes" => 4, "sha256" => hash}
                 ]

          {JSON.encode!(%{
             kind: "committed",
             operation: "send",
             op_id: op_id,
             response: %{session_handle: handle, revision: 1}
           }) <> "\n", 0}
      end
    end

    assert %{state: "registered", session_key: session, op_id: op_id} =
             HarklightSend.send_request(db, send_call, runner: runner)

    assert session == call.session_key

    assert {:ok, [[^op_id, ^session, ^handle, "sender", ^request_id, "bound"]]} =
             DB.query(
               db,
               "SELECT opId,sessionKey,handle,senderId,messageId,state FROM harklight_send_operations WHERE opId=?1",
               [op_id]
             )
  end

  test "uncertain result stays unregistered and same-operation retry can bind it", %{
    db: db,
    call: call
  } do
    handle = "ca16c43c-e3b5-4ae8-b9cd-6a8829749697"

    send_call = %{
      call
      | params: %{harklight_session: "new", sender_id: "sender", title: "Question"}
    }

    parent = self()

    runner = fn args ->
      op_id = if "--prepare" in args, do: Enum.at(args, 3), else: List.last(args)

      case Enum.take(args, 2) do
        ["send", "--prepare"] ->
          {JSON.encode!(%{
             kind: "prepared",
             op_id: op_id,
             files: [],
             request: %{
               type: "send",
               op_id: op_id,
               session_handle: handle,
               route: "other",
               message: %{sender_id: "sender", message_id: "new-request", title: "Question"}
             }
           }) <> "\n", 0}

        ["send", "--execute"] ->
          send(parent, {:attempted, op_id})
          {JSON.encode!(%{kind: "outcome_unknown", op_id: op_id}) <> "\n", 3}

        ["retry", "--op-id"] ->
          send(parent, {:retried, op_id})

          {JSON.encode!(%{
             kind: "committed",
             operation: "retry",
             op_id: op_id,
             response: %{session_handle: handle, revision: 1}
           }) <> "\n", 0}
      end
    end

    assert %{code: "harklight_outcome_unknown", op_id: op_id} =
             HarklightSend.send_request(db, send_call, runner: runner)

    assert_received {:attempted, ^op_id}

    assert {:ok, [["pending"]]} =
             DB.query(db, "SELECT state FROM harklight_send_operations WHERE opId=?1", [op_id])

    assert {:ok, [[0]]} =
             DB.query(
               db,
               "SELECT count(*) FROM harklight_wake_requests WHERE messageId='new-request'"
             )

    assert :ok = HarklightSend.recover_pending(db, runner: runner)
    assert_received {:retried, ^op_id}

    assert {:ok, [["bound"]]} =
             DB.query(db, "SELECT state FROM harklight_send_operations WHERE opId=?1", [op_id])

    assert {:ok, [[1]]} =
             DB.query(
               db,
               "SELECT count(*) FROM harklight_wake_requests WHERE messageId='new-request'"
             )

    refute_receive {:retried, _}
    assert :ok = HarklightSend.recover_pending(db, runner: runner)
    refute_receive {:retried, _}

    assert %{code: "harklight_origin_unavailable"} =
             HarklightSend.send_request(db, %{send_call | transport_session_key: nil},
               runner: fn _ -> flunk("sent") end
             )
  end

  test "recovery binds an operation committed before the local result was saved", %{
    db: db,
    call: call
  } do
    handle = "88d24275-358a-4c5d-b44f-a55dc8c03db9"
    request_id = "committed-request"

    send_call = %{
      call
      | params: %{harklight_session: "new", sender_id: "sender", title: "Question"}
    }

    parent = self()

    runner = fn args ->
      op_id = if "--prepare" in args, do: Enum.at(args, 3), else: List.last(args)

      case Enum.take(args, 2) do
        ["send", "--prepare"] ->
          {JSON.encode!(%{
             kind: "prepared",
             op_id: op_id,
             files: [],
             request: %{
               type: "send",
               op_id: op_id,
               session_handle: handle,
               route: "other",
               message: %{sender_id: "sender", message_id: request_id, title: "Question"}
             }
           }) <> "\n", 0}

        ["send", "--execute"] ->
          send(parent, {:executed, op_id})
          {"", 1}

        ["retry", "--op-id"] ->
          send(parent, {:retried, op_id})

          {JSON.encode!(%{
             kind: "committed",
             operation: "send",
             op_id: op_id,
             response: %{session_handle: handle, revision: 1}
           }) <> "\n", 0}
      end
    end

    assert %{code: "harklight_result_unconfirmed", op_id: op_id} =
             HarklightSend.send_request(db, send_call, runner: runner)

    assert_received {:executed, ^op_id}

    assert {:ok, [["pending", session]]} =
             DB.query(
               db,
               "SELECT state,sessionKey FROM harklight_send_operations WHERE opId=?1",
               [op_id]
             )

    assert session == call.session_key

    assert :ok = HarklightSend.recover_pending(db, runner: runner)
    assert_received {:retried, ^op_id}

    assert {:ok, [["bound", ^handle, "sender", ^request_id]]} =
             DB.query(
               db,
               "SELECT state,handle,senderId,messageId FROM harklight_send_operations WHERE opId=?1",
               [op_id]
             )

    assert {:ok, [[1]]} =
             DB.query(db, "SELECT count(*) FROM harklight_wake_requests WHERE messageId=?1", [
               request_id
             ])

    assert :ok = HarklightSend.recover_pending(db, runner: runner)
    refute_receive {:retried, _}
  end

  test "caller origin fields and an already registered minted handle cannot establish a send", %{
    db: db,
    call: call
  } do
    send_call = %{
      call
      | params: %{harklight_session: "new", sender_id: "sender", title: "Question"}
    }

    claimed_origin = %{
      send_call
      | params: Map.put(send_call.params, :session_key, "agent:origin:one")
    }

    assert %{code: "invalid_harklight_send"} =
             HarklightSend.send_request(db, claimed_origin, runner: fn _ -> flunk("prepared") end)

    runner = fn args ->
      assert Enum.take(args, 2) == ["send", "--prepare"]
      op_id = Enum.at(args, 3)

      {JSON.encode!(%{
         kind: "prepared",
         op_id: op_id,
         files: [],
         request: %{
           type: "send",
           op_id: op_id,
           session_handle: @handle,
           route: "other",
           message: %{sender_id: "sender", message_id: "new-request", title: "Question"}
         }
       }) <> "\n", 0}
    end

    assert %{code: "harklight_origin_mismatch"} =
             HarklightSend.send_request(db, send_call, runner: runner)
  end

  test "registration stays with the exact authenticated local origin", %{db: db, call: call} do
    assert %{state: "registered"} = HarklightWakes.register(db, call)
    assert %{state: "registered"} = HarklightWakes.register(db, call)

    assert %{code: "harklight_origin_unavailable"} =
             HarklightWakes.register(db, %{call | transport_session_key: "agent:other"})

    assert {:ok, [["agent:origin:one", host]]} =
             DB.query(db, "SELECT sessionKey,host FROM harklight_wake_handles WHERE handle=?1", [
               @handle
             ])

    assert host == Placement.local_host_name()
    assert {:ok, [[1]]} = DB.query(db, "SELECT count(*) FROM harklight_wake_requests")
  end

  test "source order, request identity and captured wakes survive replay and completion", %{
    db: db,
    call: call
  } do
    assert %{state: "registered"} = HarklightWakes.register(db, call)
    first = event(41, "discussion", "First words")
    second = event(42, "discussion", "Second words")
    final = event(43, "terminal", "Seen")

    assert :ok = HarklightWakes.capture_line(db, @handle, first)
    assert :ok = HarklightWakes.capture_line(db, @handle, second)
    assert :ok = HarklightWakes.capture_line(db, @handle, final)

    replay = first |> JSON.decode!() |> Map.put("delivered", true) |> JSON.encode!()
    assert :ok = HarklightWakes.capture_line(db, @handle, replay)

    assert {:ok, rows} =
             DB.query(
               db,
               "SELECT eventId,rawLine FROM harklight_wake_entries ORDER BY feedCursor"
             )

    assert rows == [["41", first], ["42", second], ["43", final]]

    assert {:ok, wakes} =
             DB.query(
               db,
               "SELECT wakeId,sessionKey,prompt FROM wakes WHERE wakeId LIKE 'w_harklight_%' ORDER BY createdAt,wakeId"
             )

    assert Enum.map(wakes, fn [id, _, _] -> String.split(id, "_") |> List.last() end) ==
             ["00000000000000000041", "00000000000000000042", "00000000000000000043"]

    assert Enum.all?(wakes, fn [_, session_key, prompt] ->
             session_key == call.session_key and
               String.contains?(prompt, "ack --session #{@handle}")
           end)

    assert Enum.at(wakes, 0) |> Enum.at(2) |> String.starts_with?(first)
    assert Enum.at(wakes, 2) |> Enum.at(2) |> String.starts_with?(final)

    assert Enum.at(wakes, 0)
           |> Enum.at(2)
           |> String.contains?("--request request --in-reply-to 41")

    assert Enum.at(wakes, 2)
           |> Enum.at(2)
           |> String.contains?("--request request --in-reply-to 43 --status applied|refused")
  end

  test "other requests on the same handle reach the same origin in feed order", %{
    db: db,
    call: call
  } do
    assert %{state: "registered"} = HarklightWakes.register(db, call)

    assert {:error, "harklight_send_pending"} =
             HarklightWakes.capture_line(db, @handle, event(1, "discussion", "other", "other"))

    other_op = "212f4c59-2ad2-4786-a18c-d4be86d53eb8"
    other_payload = ~s({"type":"send","message":{"sender_id":"sender","message_id":"other"}})

    other_result =
      ~s({"kind":"sent","session":"#{@handle}","sender_id":"sender","request":"other"})

    assert %{state: "pending"} = HarklightWakes.prepare_send(db, call, other_op, other_payload)

    assert %{state: "registered"} =
             HarklightWakes.bind_send(
               db,
               call,
               other_op,
               other_payload,
               other_result,
               @handle,
               "sender",
               "other"
             )

    assert :ok =
             HarklightWakes.capture_line(db, @handle, event(1, "discussion", "other", "other"))

    assert :ok = HarklightWakes.capture_line(db, @handle, event(3, "discussion", "current"))

    assert {:ok, [[2]]} = DB.query(db, "SELECT count(*) FROM harklight_wake_requests")
    assert {:ok, [[2]]} = DB.query(db, "SELECT count(*) FROM harklight_wake_entries")

    assert {:error, "event_order_invalid"} =
             HarklightWakes.capture_line(db, @handle, event(2, "discussion", "late"))

    changed = event(3, "discussion", "current", "wrong-request")
    assert {:error, "event_identity_mismatch"} = HarklightWakes.capture_line(db, @handle, changed)

    assert {:ok, [[2]]} = DB.query(db, "SELECT count(*) FROM harklight_wake_entries")
  end

  test "a completed request retry does not restart listening", %{db: db, call: call} do
    assert %{state: "registered"} = HarklightWakes.register(db, call)
    test_pid = self()

    listener = fn manager, handle, _vendor_id ->
      send(test_pid, :listener_started)
      :ok = GenServer.call(manager, {:attached, handle})
      :ok = GenServer.call(manager, {:finished, handle, :complete})
      send(test_pid, :listener_completed)
    end

    start_supervised!({HarklightWakes, db: db, listener: listener})
    assert_receive :listener_started
    assert_receive :listener_completed
    assert %{state: "complete"} = HarklightWakes.register(db, call)
    refute_receive :listener_started, 100

    assert {:ok, [["complete"]]} =
             DB.query(db, "SELECT state FROM harklight_wake_handles WHERE handle=?1", [@handle])
  end

  test "server expiry and supersession reach the origin once and allow idle completion", %{
    db: db,
    call: call
  } do
    assert %{state: "registered"} = HarklightWakes.register(db, call)

    second_op = "0bdb87a0-3a09-4f61-bff4-9a4a704324c9"
    second_payload = String.replace(@payload, "request", "request2")
    second_result = String.replace(@result, "request", "request2")
    assert %{state: "pending"} = HarklightWakes.prepare_send(db, call, second_op, second_payload)

    assert %{state: "registered"} =
             HarklightWakes.bind_send(
               db,
               call,
               second_op,
               second_payload,
               second_result,
               @handle,
               "sender",
               "request2"
             )

    for {id, state, request} <- [{51, "expired", "request"}, {52, "superseded", "request2"}] do
      line =
        event(id, "terminal", state, request)
        |> JSON.decode!()
        |> put_in(["entry", "author"], "server")
        |> put_in(["entry", "terminal_state"], state)
        |> JSON.encode!()

      assert :ok = HarklightWakes.capture_line(db, @handle, line)
      assert :ok = HarklightWakes.capture_line(db, @handle, line)
    end

    origin_line =
      event(53, "terminal", "not an inbound terminal")
      |> JSON.decode!()
      |> put_in(["entry", "author"], "origin")
      |> JSON.encode!()

    assert {:error, "event_identity_invalid"} =
             HarklightWakes.capture_line(db, @handle, origin_line)

    assert {:ok, [[2]]} = DB.query(db, "SELECT count(*) FROM harklight_wake_entries")

    assert {:ok, [[2]]} =
             DB.query(db, "SELECT count(*) FROM wakes WHERE wakeId LIKE 'w_harklight_%'")

    test_pid = self()

    listener = fn manager, handle, _vendor_id ->
      :ok = GenServer.call(manager, {:attached, handle})
      :ok = GenServer.call(manager, {:finished, handle, :complete})
      send(test_pid, :listener_completed)
    end

    start_supervised!({HarklightWakes, db: db, listener: listener})
    assert_receive :listener_completed
    assert %{state: "complete"} = HarklightWakes.register(db, call)

    assert {:ok, [["complete"]]} =
             DB.query(db, "SELECT state FROM harklight_wake_handles WHERE handle=?1", [@handle])
  end

  test "a stopped listener leaves the handle durable and notifies its owner", %{
    db: db,
    call: call,
    session: session
  } do
    assert %{state: "registered"} = HarklightWakes.register(db, call)
    test_pid = self()

    listener = fn manager, handle, _vendor_id ->
      :ok = GenServer.call(manager, {:attached, handle})
      :ok = GenServer.call(manager, {:finished, handle, "listener_stopped"})
      send(test_pid, :listener_failed)
    end

    start_supervised!({HarklightWakes, db: db, listener: listener})
    assert_receive :listener_failed
    origin_key = session.session_key

    assert {:ok, [["unavailable", "listener_stopped"]]} =
             DB.query(db, "SELECT state,lastError FROM harklight_wake_handles WHERE handle=?1", [
               @handle
             ])

    assert {:ok, [[^origin_key, prompt]]} =
             DB.query(
               db,
               "SELECT sessionKey,prompt FROM wakes WHERE prompt LIKE 'Harklight listening%'"
             )

    assert String.contains?(prompt, @handle)
  end

  for saved_error <- ["listener_stopped", "attachment_refused"] do
    @saved_error saved_error
    test "restart restores an existing #{@saved_error} handle without changing captured state", %{
      db: db,
      session: session
    } do
      lines =
        for {cursor, delivered, acted} <- [{1, false, false}, {2, true, false}, {3, true, true}] do
          event(cursor, "discussion", "retained")
          |> JSON.decode!()
          |> Map.merge(%{"delivered" => delivered, "acted" => acted})
          |> JSON.encode!()
        end

      for line <- lines, do: assert(:ok = HarklightWakes.capture_line(db, @handle, line))
      {:ok, before_entries} = DB.query(db, "SELECT * FROM harklight_wake_entries")
      {:ok, before_requests} = DB.query(db, "SELECT * FROM harklight_wake_requests")
      {:ok, before_wakes} = DB.query(db, "SELECT * FROM wakes WHERE wakeId LIKE 'w_harklight_%'")
      {:ok, before_results} = DB.query(db, "SELECT * FROM harklight_command_results")
      {:ok, before_sends} = DB.query(db, "SELECT * FROM harklight_send_operations")

      {:ok, _} =
        DB.query(db, "UPDATE harklight_wake_handles SET state='unavailable',lastError=?1", [
          @saved_error
        ])

      parent = self()

      listener = fn manager, handle, vendor ->
        :ok = GenServer.call(manager, {:attached, handle})
        for line <- lines, do: :ok = GenServer.call(manager, {:capture, handle, line})
        send(parent, {:restored, self(), handle, vendor})

        receive do
          :never -> :ok
        end
      end

      start_supervised!({HarklightWakes, db: db, listener: listener})
      assert_receive {:restored, worker, @handle, nil}
      ref = Process.monitor(worker)
      :ok = stop_supervised(HarklightWakes)
      assert_receive {:DOWN, ^ref, :process, ^worker, :shutdown}
      start_supervised!({HarklightWakes, db: db, listener: listener})
      assert_receive {:restored, next, @handle, nil}
      refute next == worker
      assert {:ok, ^before_entries} = DB.query(db, "SELECT * FROM harklight_wake_entries")
      assert {:ok, ^before_requests} = DB.query(db, "SELECT * FROM harklight_wake_requests")

      assert {:ok, ^before_wakes} =
               DB.query(db, "SELECT * FROM wakes WHERE wakeId LIKE 'w_harklight_%'")

      assert {:ok, ^before_results} = DB.query(db, "SELECT * FROM harklight_command_results")
      assert {:ok, ^before_sends} = DB.query(db, "SELECT * FROM harklight_send_operations")
      origin = session.session_key

      assert {:ok, [[^origin, "active", nil, 3]]} =
               DB.query(
                 db,
                 "SELECT sessionKey,state,lastError,lastCursor FROM harklight_wake_handles"
               )

      assert {:ok, [[3]]} =
               DB.query(db, "SELECT count(*) FROM wakes WHERE wakeId LIKE 'w_harklight_%'")
    end
  end

  test "a delivered chat after an answered request may finish after the other request is answered",
       %{db: db, session: session} do
    answer = completion_event(@handle, 1, "request", "terminal", "person")
    chat = completion_event(@handle, 2, "request", "discussion", "person", "chat")
    assert :ok = HarklightWakes.capture_line(db, @handle, JSON.encode!(answer))
    assert :ok = HarklightWakes.capture_line(db, @handle, JSON.encode!(chat))

    assert {:ok, _} =
             DB.query(
               db,
               "INSERT INTO harklight_wake_requests(senderId,messageId,handle) VALUES('sender','request-b',?1)",
               [@handle]
             )

    mark_completion_wakes_delivered(db, @handle)

    status = %{
      "session_handle" => @handle,
      "open_requests" => 1,
      "open_chats" => 1,
      "pending_undelivered" => 1,
      "pending_delivered_unacted" => 0
    }

    {:ok, responses} =
      Agent.start_link(fn -> %{status: status, events: %{@handle => [chat]}, commands: []} end)

    Process.unlink(responses)
    on_exit(fn -> Agent.stop(responses) end)
    parent = self()
    runner = completion_runner(responses, parent)

    manager =
      start_supervised!(
        {HarklightWakes, db: db, listener: notifying_listener(parent), send_runner: runner}
      )

    assert_receive {:restored, @handle, nil}
    assert_receive {:harklight_command, ["status", "--session", @handle]}
    assert Map.has_key?(:sys.get_state(manager).workers, @handle)

    assert {:ok, [["active"]]} =
             DB.query(db, "SELECT state FROM harklight_wake_handles WHERE handle=?1", [@handle])

    Agent.update(responses, fn current ->
      put_in(current, [:status, "open_requests"], 0)
    end)

    answer_b = completion_event(@handle, 3, "request-b", "terminal", "person")
    assert :ok = HarklightWakes.capture_line(db, @handle, JSON.encode!(answer_b))
    mark_completion_wakes_delivered(db, @handle)

    assert :active = Tightbeam.HarklightLifecycle.complete_answered(db, @handle, runner: runner)

    Agent.update(responses, fn current ->
      put_in(current, [:status, "pending_undelivered"], 0)
      |> put_in([:status, "pending_delivered_unacted"], 1)
      |> put_in([:events, @handle, Access.at(0), "delivered"], true)
    end)

    HarklightWakes.origin_turn_ended(session.session_key)

    assert eventually(fn ->
             DB.query(db, "SELECT state FROM harklight_wake_handles WHERE handle=?1", [@handle]) ==
               {:ok, [["complete"]]}
           end)

    assert {:ok, [["complete"]]} =
             DB.query(db, "SELECT state FROM harklight_wake_handles WHERE handle=?1", [@handle])

    assert {:ok, [[3]]} =
             DB.query(db, "SELECT count(*) FROM harklight_wake_entries WHERE handle=?1", [@handle])

    assert_receive {:harklight_command, ["read", "--session", @handle]}
    assert_receive {:harklight_command, ["status", "--session", @handle]}

    refute Enum.any?(Agent.get(responses, & &1.commands), fn [command | _] ->
             command in ["ack", "reply", "result"]
           end)
  end

  test "the answer stays pending until its ACK and result are both recorded", %{db: db} do
    answer = completion_event(@handle, 1, "request", "terminal", "person")
    assert :ok = HarklightWakes.capture_line(db, @handle, JSON.encode!(answer))
    mark_completion_wakes_delivered(db, @handle)

    status = %{
      "session_handle" => @handle,
      "open_requests" => 0,
      "pending_undelivered" => 1,
      "pending_delivered_unacted" => 1
    }

    {:ok, responses} =
      Agent.start_link(fn -> %{status: status, events: %{@handle => [answer]}, commands: []} end)

    Process.unlink(responses)
    on_exit(fn -> Agent.stop(responses) end)
    runner = completion_runner(responses, self())
    assert :active = Tightbeam.HarklightLifecycle.complete_answered(db, @handle, runner: runner)

    Agent.update(responses, fn current ->
      put_in(current, [:status, "pending_undelivered"], 0)
      |> put_in([:status, "pending_delivered_unacted"], 1)
      |> put_in([:events, @handle, Access.at(0), "delivered"], true)
    end)

    assert :active = Tightbeam.HarklightLifecycle.complete_answered(db, @handle, runner: runner)

    assert {:ok, [["active"]]} =
             DB.query(db, "SELECT state FROM harklight_wake_handles WHERE handle=?1", [@handle])

    Agent.update(responses, fn current ->
      put_in(current, [:status, "pending_delivered_unacted"], 0)
      |> put_in([:events, @handle], [])
    end)

    assert :completed =
             Tightbeam.HarklightLifecycle.complete_answered(db, @handle, runner: runner)

    assert {:ok, [["complete"]]} =
             DB.query(db, "SELECT state FROM harklight_wake_handles WHERE handle=?1", [@handle])
  end

  test "missing, refused, or unparsable Agent reads keep an answered handle active", %{db: db} do
    answer = completion_event(@handle, 1, "request", "terminal", "person")
    assert :ok = HarklightWakes.capture_line(db, @handle, JSON.encode!(answer))
    mark_completion_wakes_delivered(db, @handle)

    failures = [
      fn _args -> {"harklight-agent executable not found", 127} end,
      fn _args -> {"origin refused the request", 2} end,
      fn _args -> {"not-json", 0} end
    ]

    for runner <- failures do
      assert :active = Tightbeam.HarklightLifecycle.complete_answered(db, @handle, runner: runner)

      assert {:ok, [["active"]]} =
               DB.query(db, "SELECT state FROM harklight_wake_handles WHERE handle=?1", [@handle])
    end

    status_failure = fn
      ["read", "--session", _handle] -> {"", 0}
      ["status", "--session", _handle] -> {"not-json", 0}
    end

    assert :active =
             Tightbeam.HarklightLifecycle.complete_answered(db, @handle, runner: status_failure)

    assert {:ok, [["active"]]} =
             DB.query(db, "SELECT state FROM harklight_wake_handles WHERE handle=?1", [@handle])
  end

  @tag :restart_count
  test "restart completes only eligible answered conversations and restores the remainder", %{
    db: db,
    call: call,
    session: session
  } do
    completed_handles = [@handle, Tightbeam.Id.uuid4(), Tightbeam.Id.uuid4()]
    open_request_handle = Tightbeam.Id.uuid4()
    pending_answer_handle = Tightbeam.Id.uuid4()

    for {handle, index} <-
          Enum.with_index(completed_handles ++ [open_request_handle, pending_answer_handle]) do
      message_id = if handle == @handle, do: "request", else: "request-#{index}"

      if handle != @handle,
        do: seed_completion_handle(db, session.session_key, handle, message_id)

      answer = completion_event(handle, 1, message_id, "terminal", "person")
      assert :ok = HarklightWakes.capture_line(db, handle, JSON.encode!(answer))
      mark_completion_wakes_delivered(db, handle)
    end

    # Previously unavailable answered handles must also skip attachment.
    assert {:ok, _} =
             DB.query(
               db,
               "UPDATE harklight_wake_handles SET state='unavailable' WHERE handle=?1",
               [
                 hd(completed_handles)
               ]
             )

    eligible_status = fn handle ->
      %{
        "session_handle" => handle,
        "open_requests" => 0,
        "open_chats" => 1,
        "pending_undelivered" => 0,
        "pending_delivered_unacted" => 0
      }
    end

    statuses =
      Map.new(completed_handles, &{&1, eligible_status.(&1)})
      |> Map.put(open_request_handle, %{
        "session_handle" => open_request_handle,
        "open_requests" => 1,
        "pending_undelivered" => 0,
        "pending_delivered_unacted" => 0
      })
      |> Map.put(pending_answer_handle, %{
        "session_handle" => pending_answer_handle,
        "open_requests" => 0,
        "pending_undelivered" => 1,
        "pending_delivered_unacted" => 0
      })

    pending_answer = completion_event(pending_answer_handle, 1, "request-4", "terminal", "person")

    initial = %{
      status: statuses,
      events: %{
        @handle => [],
        open_request_handle => [],
        pending_answer_handle => [pending_answer]
      },
      commands: []
    }

    {:ok, responses} = Agent.start_link(fn -> initial end)
    Process.unlink(responses)
    on_exit(fn -> Agent.stop(responses) end)
    parent = self()
    runner = completion_runner(responses, parent)
    listener = notifying_listener(parent)

    {:ok, [[5]]} =
      DB.query(
        db,
        "SELECT count(*) FROM harklight_wake_handles WHERE state IN ('active','unavailable')"
      )

    first_manager =
      start_supervised!({HarklightWakes, db: db, listener: listener, send_runner: runner})

    restored_at_startup =
      for _ <- 1..2 do
        assert_receive {:restored, handle, nil}
        handle
      end

    assert MapSet.new(restored_at_startup) ==
             MapSet.new([open_request_handle, pending_answer_handle])

    refute_receive {:restored, _, _}

    assert eventually(fn ->
             DB.query(db, "SELECT count(*) FROM harklight_wake_handles WHERE state='complete'") ==
               {:ok, [[3]]} and map_size(:sys.get_state(first_manager).workers) == 2
           end)

    first_state = :sys.get_state(first_manager)
    assert length(Map.keys(first_state.workers)) == 2

    assert {:ok, [[3]]} =
             DB.query(db, "SELECT count(*) FROM harklight_wake_handles WHERE state='complete'")

    assert {:ok, [[2]]} =
             DB.query(
               db,
               "SELECT count(*) FROM harklight_wake_handles WHERE state IN ('active','unavailable')"
             )

    :ok = stop_supervised(HarklightWakes)

    second_manager =
      start_supervised!({HarklightWakes, db: db, listener: listener, send_runner: runner})

    restored_after_restart =
      for _ <- 1..2 do
        assert_receive {:restored, handle, nil}
        handle
      end

    second_state = :sys.get_state(second_manager)

    assert MapSet.new(restored_after_restart) ==
             MapSet.new([open_request_handle, pending_answer_handle])

    assert length(Map.keys(second_state.workers)) == 2

    assert {:ok, [[3]]} =
             DB.query(db, "SELECT count(*) FROM harklight_wake_handles WHERE state='complete'")

    assert call.session_key == session.session_key
  end

  for evidence_failure <- [:read_failed, :status_failed, :local_pending] do
    @evidence_failure evidence_failure
    test "startup preserves a conversation with #{@evidence_failure}", %{db: db} do
      answer = completion_event(@handle, 1, "request", "terminal", "person")
      assert :ok = HarklightWakes.capture_line(db, @handle, JSON.encode!(answer))
      if @evidence_failure != :local_pending, do: mark_completion_wakes_delivered(db, @handle)

      eligible_runner = idle_runner()

      runner = fn args ->
        case {args, @evidence_failure} do
          {["read" | _], :read_failed} -> {"unavailable", 1}
          {["status" | _], :status_failed} -> {"unavailable", 1}
          _ -> eligible_runner.(args)
        end
      end

      manager =
        start_supervised!(
          {HarklightWakes, db: db, listener: notifying_listener(self()), send_runner: runner}
        )

      assert_receive {:restored, @handle, nil}
      assert Map.has_key?(:sys.get_state(manager).workers, @handle)

      assert {:ok, [["active"]]} =
               DB.query(db, "SELECT state FROM harklight_wake_handles WHERE handle=?1", [@handle])
    end
  end

  test "an agent-authored answer alone does not complete a handle", %{db: db} do
    answer = completion_event(@handle, 1, "request", "terminal", "agent")
    assert :ok = HarklightWakes.capture_line(db, @handle, JSON.encode!(answer))
    mark_completion_wakes_delivered(db, @handle)

    status = %{
      "session_handle" => @handle,
      "open_requests" => 0,
      "pending_undelivered" => 0,
      "pending_delivered_unacted" => 0
    }

    runner = fn
      ["read", "--session", @handle] -> {"", 0}
      ["status", "--session", @handle] -> {JSON.encode!(status), 0}
    end

    assert :active = Tightbeam.HarklightLifecycle.complete_answered(db, @handle, runner: runner)

    assert {:ok, [["active"]]} =
             DB.query(db, "SELECT state FROM harklight_wake_handles WHERE handle=?1", [@handle])
  end

  test "Mike's no-comment terminal qualifies as an answer", %{db: db} do
    no_comment =
      completion_event(@handle, 1, "request", "terminal", "person")
      |> put_in(["entry", "terminal_kind"], "no_comment")

    assert :ok = HarklightWakes.capture_line(db, @handle, JSON.encode!(no_comment))
    mark_completion_wakes_delivered(db, @handle)

    status = %{
      "session_handle" => @handle,
      "open_requests" => 0,
      "pending_undelivered" => 0,
      "pending_delivered_unacted" => 0
    }

    runner = fn
      ["read", "--session", @handle] -> {"", 0}
      ["status", "--session", @handle] -> {JSON.encode!(status), 0}
    end

    assert :completed =
             Tightbeam.HarklightLifecycle.complete_answered(db, @handle, runner: runner)
  end

  test "a failed delivery alone does not complete a handle", %{db: db, session: session} do
    answer = completion_event(@handle, 1, "request", "terminal", "person")
    assert :ok = HarklightWakes.capture_line(db, @handle, JSON.encode!(answer))
    wake_id = completion_wake(db, @handle)

    completion_turn(db, session.session_key, wake_id, "failed", "unauthorized")

    assert :active =
             Tightbeam.HarklightLifecycle.complete_answered(db, @handle, runner: idle_runner())

    assert {:ok, [["active"]]} =
             DB.query(db, "SELECT state FROM harklight_wake_handles WHERE handle=?1", [@handle])
  end

  test "completion follows a failed delivery to its same-recipient retry", %{
    db: db,
    session: session
  } do
    answer = completion_event(@handle, 1, "request", "terminal", "person")
    assert :ok = HarklightWakes.capture_line(db, @handle, JSON.encode!(answer))
    wake_id = completion_wake(db, @handle)

    failed_seq =
      completion_turn(db, session.session_key, wake_id, "failed", "provider rate limit")

    assert {:ok, {:retry, retry_wake_id}} =
             DB.transaction(db, &Wakes.preserve_failed_intent_for_terminal_in_txn(&1, failed_seq))

    assert :active =
             Tightbeam.HarklightLifecycle.complete_answered(db, @handle, runner: idle_runner())

    completion_turn(db, session.session_key, retry_wake_id, "delivered", nil)

    assert :completed =
             Tightbeam.HarklightLifecycle.complete_answered(db, @handle, runner: idle_runner())
  end

  test "completion follows a failed delivery to its health redelivery", %{
    db: db,
    session: session
  } do
    answer = completion_event(@handle, 1, "request", "terminal", "person")
    assert :ok = HarklightWakes.capture_line(db, @handle, JSON.encode!(answer))
    wake_id = completion_wake(db, @handle)

    failed_seq = completion_turn(db, session.session_key, wake_id, "failed", "unauthorized")

    assert :active =
             Tightbeam.HarklightLifecycle.complete_answered(db, @handle, runner: idle_runner())

    assert {:ok, :ok} =
             DB.transaction(
               db,
               &Wakes.record_health_redelivery_source_in_txn(&1, failed_seq, "auth-dead")
             )

    now = System.system_time(:millisecond)

    assert {:ok, _} =
             DB.query(
               db,
               "INSERT INTO turns(sessionKey,messageId,origin,prompt,status,createdAt,endedAt) VALUES(?1,?2,'process:test','restoration',?3,?4,?4)",
               [session.session_key, Tightbeam.Id.uuid4(), "delivered", now]
             )

    assert {:ok, [[restoration_seq]]} = DB.query(db, "SELECT MAX(seq) FROM turns")

    assert {:ok, 1} =
             DB.transaction(
               db,
               &Wakes.redeliver_pending_health_intents_in_txn(&1, session, %{seq: restoration_seq})
             )

    assert {:ok, [[redelivery_seq, nil, "queued"]]} =
             DB.query(
               db,
               "SELECT t.seq,t.wakeId,t.status FROM health_redelivery_attempts a JOIN turns t ON t.seq=a.redeliveryTurnSeq WHERE a.sourceTurnSeq=?1",
               [failed_seq]
             )

    assert :active =
             Tightbeam.HarklightLifecycle.complete_answered(db, @handle, runner: idle_runner())

    assert {:ok, _} =
             DB.query(db, "UPDATE turns SET status='delivered',endedAt=?2 WHERE seq=?1", [
               redelivery_seq,
               now
             ])

    assert :completed =
             Tightbeam.HarklightLifecycle.complete_answered(db, @handle, runner: idle_runner())
  end

  test "failed restoration refreshes the actual reason and notifies the origin once", %{
    db: db,
    session: session
  } do
    {:ok, _} =
      DB.query(
        db,
        "UPDATE harklight_wake_handles SET state='unavailable',lastError='listener_stopped'"
      )

    parent = self()

    listener = fn manager, handle, _ ->
      :ok =
        GenServer.call(
          manager,
          {:finished, handle,
           {:harklight_failure, "attachment_refused", "attach",
            "The existing local listener lock is held; no replacement was attempted."}}
        )

      send(parent, :refused)
    end

    start_supervised!({HarklightWakes, db: db, listener: listener})
    assert_receive :refused
    :ok = stop_supervised(HarklightWakes)
    start_supervised!({HarklightWakes, db: db, listener: listener})
    assert_receive :refused

    assert {:ok, [["unavailable", reason]]} =
             DB.query(db, "SELECT state,lastError FROM harklight_wake_handles")

    assert reason =~ "attachment_refused"
    assert reason =~ "listener lock is held"
    origin = session.session_key

    assert {:ok, [[^origin, prompt]]} =
             DB.query(
               db,
               "SELECT sessionKey,prompt FROM wakes WHERE wakeId LIKE 'w_harklight_notice_%'"
             )

    assert prompt =~ "listener lock is held"
    assert prompt =~ "Replies on this thread will not reach"
  end

  test "startup records an ineligible origin without launching a listener", %{
    db: db,
    session: session
  } do
    Org.set_host(db, session.session_key, "other-host")
    parent = self()
    listener = fn _, _, _ -> send(parent, :unexpected_listener) end
    start_supervised!({HarklightWakes, db: db, listener: listener})
    :sys.get_state(HarklightWakes)

    assert {:ok, [["unavailable", "origin_unavailable"]]} =
             DB.query(db, "SELECT state,lastError FROM harklight_wake_handles")

    refute_receive :unexpected_listener
  end

  for {label, responses, expected_calls, recovered} <- [
        {"transport refusal recovers",
         [
           {2,
            ~s({"kind":"refused","reason_source":"agent","reason_code":"transport_error","reason":"The origin transport request failed."})},
           {0, ~s({"kind":"attached","ready_for_listen":true})}
         ], ["attach", "attach"], true},
        {"unknown transport preserves same-operation recovery first",
         [
           {7,
            ~s({"kind":"outcome_unknown","op_id":"saved-op","reason_source":"agent","reason_code":"transport_error"})},
           {7,
            ~s({"kind":"outcome_unknown","op_id":"saved-op"}) <>
              "\norigin request failed: synthetic connection failure"},
           {0, ~s({"kind":"attached","ready_for_listen":true})}
         ], ["attach", "retry --op-id saved-op", "attach"], true},
        {"real refusal stays unavailable",
         [
           {2,
            ~s({"kind":"refused","reason_source":"server","reason_code":"forbidden","reason":"The server refused this origin's access."})}
         ], ["attach"], false},
        {"unknown nontransport does not gain retries",
         [
           {7,
            ~s({"kind":"outcome_unknown","op_id":"saved-op","reason_source":"agent","reason_code":"invalid_response"})},
           {7,
            ~s({"kind":"outcome_unknown","op_id":"saved-op"}) <>
              "\norigin response was not a valid v1 JSON envelope: synthetic"}
         ], ["attach", "retry --op-id saved-op"], false},
        {"transport retry exhausts its finite budget",
         List.duplicate(
           {2,
            ~s({"kind":"connection_error","reason_source":"agent","reason_code":"timeout","reason":"The origin request timed out."})},
           3
         ), ["attach", "attach", "attach"], false}
      ] do
    @retry_responses responses
    @retry_calls expected_calls
    @retry_recovered recovered
    test "bounded attachment retry: #{label}", %{db: db, session: session} do
      calls = attachment_sequence(@retry_responses)
      start_supervised!({HarklightWakes, db: db, attach_retry_delays: [20, 40]})

      if @retry_recovered do
        await_listener_port()

        assert {:ok, [["active", nil]]} =
                 DB.query(db, "SELECT state,lastError FROM harklight_wake_handles")

        assert {:ok, []} =
                 DB.query(db, "SELECT wakeId FROM wakes WHERE wakeId LIKE 'w_harklight_notice_%'")
      else
        await_handle_error(db, "attachment_")
        origin = session.session_key

        assert {:ok, [[^origin, prompt]]} =
                 DB.query(
                   db,
                   "SELECT sessionKey,prompt FROM wakes WHERE wakeId LIKE 'w_harklight_notice_%'"
                 )

        assert prompt =~ "Replies on this thread will not reach"
      end

      assert File.read!(calls) |> String.split("\n", trim: true) == @retry_calls
      # Beyond both configured delays, a terminal refusal cannot restart itself.
      Process.sleep(100)
      assert File.read!(calls) |> String.split("\n", trim: true) == @retry_calls
    end
  end

  test "retry window does not schedule an attempt beyond its deadline", %{db: db} do
    calls =
      attachment_sequence([
        {2, ~s({"kind":"refused","reason_source":"agent","reason_code":"transport_error"})}
      ])

    start_supervised!(
      {HarklightWakes, db: db, attach_retry_delays: [100], attach_retry_window_ms: 10}
    )

    await_handle_error(db, "attachment_refused")
    Process.sleep(120)
    assert File.read!(calls) == "attach\n"
  end

  test "controller shutdown cancels a pending transport retry", %{db: db} do
    calls =
      attachment_sequence([
        {2, ~s({"kind":"refused","reason_source":"agent","reason_code":"transport_error"})}
      ])

    start_supervised!({HarklightWakes, db: db, attach_retry_delays: [500]})
    await_attachment_calls(calls)
    :ok = stop_supervised(HarklightWakes)
    Process.sleep(550)
    assert File.read!(calls) == "attach\n"
  end

  test "restore caps concurrent attachment attempts and attaches every handle", %{
    db: db,
    session: session
  } do
    handles = for i <- 1..5, do: "00000000-0000-4000-8000-00000000000#{i}"

    for handle <- handles do
      {:ok, _} =
        DB.query(
          db,
          "INSERT INTO harklight_wake_handles(handle,sessionKey,host,vendorSessionId,state,createdAt,updatedAt) VALUES(?1,?2,?3,'vendor','active',2,2)",
          [handle, session.session_key, Placement.local_host_name()]
        )
    end

    root = Path.join(System.tmp_dir!(), "attach-cap-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    events = Path.join(root, "events")
    File.write!(events, "")

    File.write!(Path.join(root, "harklight-agent"), """
    #!/bin/sh
    if [ "$1" = listen ]; then exec sleep 300; fi
    printf 'start\\n' >> '#{events}'
    sleep 0.2
    printf 'end\\n' >> '#{events}'
    printf '%s\\n' '{"kind":"attached","ready_for_listen":true}'
    """)

    File.chmod!(Path.join(root, "harklight-agent"), 0o700)
    old_path = System.fetch_env!("PATH")
    System.put_env("PATH", root <> ":" <> old_path)

    on_exit(fn ->
      System.put_env("PATH", old_path)
      File.rm_rf!(root)
    end)

    start_supervised!({HarklightWakes, db: db, attach_concurrency: 2})
    await_listener_ports(6)

    overlap =
      File.read!(events)
      |> String.split("\n", trim: true)
      |> Enum.scan(0, fn
        "start", n -> n + 1
        "end", n -> n - 1
      end)

    assert Enum.max(overlap) == 2
    assert length(overlap) == 12

    assert {:ok, [["active", 6]]} =
             DB.query(db, "SELECT state,count(*) FROM harklight_wake_handles GROUP BY state")
  end

  defp await_listener_ports(count, attempts \\ 300)
  defp await_listener_ports(_count, 0), do: flunk("listener ports did not start")

  defp await_listener_ports(count, attempts) do
    if map_size(:sys.get_state(HarklightWakes).ports) < count do
      Process.sleep(10)
      await_listener_ports(count, attempts - 1)
    end
  end

  defp attachment_sequence(responses) do
    root = Path.join(System.tmp_dir!(), "attach-sequence-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    calls = Path.join(root, "calls")
    File.write!(calls, "")

    Enum.with_index(responses, 1)
    |> Enum.each(fn {{status, output}, i} ->
      File.write!(Path.join(root, "response-#{i}"), output <> "\n")
      File.write!(Path.join(root, "status-#{i}"), Integer.to_string(status))
    end)

    File.write!(Path.join(root, "harklight-agent"), """
    #!/bin/sh
    root='#{root}'
    if [ "$1" = listen ]; then exec sleep 300; fi
    if [ "$1" = retry ]; then
      printf '%s\n' "$*" >> "$root/calls"
    else
      printf '%s\n' "$1" >> "$root/calls"
    fi
    n=$(wc -l < "$root/calls" | tr -d ' ')
    cat "$root/response-$n"
    exit "$(cat "$root/status-$n")"
    """)

    File.chmod!(Path.join(root, "harklight-agent"), 0o700)
    old_path = System.fetch_env!("PATH")
    System.put_env("PATH", root <> ":" <> old_path)

    on_exit(fn ->
      System.put_env("PATH", old_path)
      File.rm_rf!(root)
    end)

    calls
  end

  defp await_attachment_calls(path, attempts \\ 100)
  defp await_attachment_calls(_path, 0), do: flunk("attachment did not run")

  defp await_attachment_calls(path, attempts) do
    if File.read!(path) == "" do
      Process.sleep(10)
      await_attachment_calls(path, attempts - 1)
    end
  end

  test "controller shutdown releases its own idle subprocess before restoring", %{db: db} do
    root = Path.join(System.tmp_dir!(), "harklight-child-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    script = Path.join(root, "harklight-agent")

    File.write!(script, """
    #!/bin/sh
    if [ "$1" = attach ]; then
      printf '%s\n' '{"kind":"attached","ready_for_listen":true}'
    else
      exec sleep 300
    fi
    """)

    File.chmod!(script, 0o700)
    old_path = System.fetch_env!("PATH")
    System.put_env("PATH", root <> ":" <> old_path)

    on_exit(fn ->
      System.put_env("PATH", old_path)
      File.rm_rf!(root)
    end)

    start_supervised!({HarklightWakes, db: db})
    port = await_listener_port()
    {:os_pid, pid} = Port.info(port, :os_pid)

    assert {_, 0} =
             System.cmd("/bin/kill", ["-0", Integer.to_string(pid)], stderr_to_stdout: true)

    :ok = stop_supervised(HarklightWakes)

    assert {_, status} =
             System.cmd("/bin/kill", ["-0", Integer.to_string(pid)], stderr_to_stdout: true)

    assert status != 0
    start_supervised!({HarklightWakes, db: db})
    new_port = await_listener_port()
    refute new_port == port
  end

  defp await_listener_port(attempts \\ 100)
  defp await_listener_port(0), do: flunk("listener port did not start")

  defp await_listener_port(attempts) do
    case :sys.get_state(HarklightWakes).ports do
      %{@handle => port} ->
        port

      _ ->
        Process.sleep(10)
        await_listener_port(attempts - 1)
    end
  end

  if System.get_env("HARKLIGHT_ACCEPTANCE_BINARY") do
    test "published Agent reports missing configuration as an attach failure", %{db: db} do
      # The isolated gate supplies the hash-verified published binary. Ordinary
      # runs use the existing source-level controller tests.
      binary = System.fetch_env!("HARKLIGHT_ACCEPTANCE_BINARY")

      root =
        Path.join(System.tmp_dir!(), "harklight-restart-#{System.unique_integer([:positive])}")

      File.mkdir_p!(root)
      script = Path.join(root, "harklight-agent")

      File.write!(
        script,
        "#!/bin/sh\nexec '" <>
          binary <>
          "' --identity-dir '" <> root <> "/missing' --state-dir '" <> root <> "/state' \"$@\"\n"
      )

      File.chmod!(script, 0o700)
      old_path = System.fetch_env!("PATH")
      System.put_env("PATH", root <> ":" <> old_path)

      on_exit(fn ->
        System.put_env("PATH", old_path)
        File.rm_rf!(root)
      end)

      start_supervised!({HarklightWakes, db: db})
      await_handle_error(db, "configuration")

      assert {:ok, [["unavailable", error]]} =
               DB.query(db, "SELECT state,lastError FROM harklight_wake_handles")

      assert error =~ "attachment_refused"
      assert error =~ "configuration"
    end
  end

  defp await_handle_error(db, text, attempts \\ 100)
  defp await_handle_error(_db, _text, 0), do: flunk("controller did not record the failure")

  defp await_handle_error(db, text, attempts) do
    case DB.query(db, "SELECT lastError FROM harklight_wake_handles") do
      {:ok, [[error]]} when is_binary(error) ->
        if String.contains?(error, text),
          do: :ok,
          else: await_handle_error(db, text, attempts - 1)

      _ ->
        Process.sleep(10)
        await_handle_error(db, text, attempts - 1)
    end
  end

  test "retirement and host movement fence new captures without losing old wakes", %{
    db: db,
    call: call,
    session: session
  } do
    assert %{state: "registered"} = HarklightWakes.register(db, call)
    assert :ok = HarklightWakes.capture_line(db, @handle, event(1, "discussion", "first"))

    Org.set_host(db, session.session_key, "another-host")

    assert {:error, "harklight_origin_unavailable"} =
             HarklightWakes.capture_line(db, @handle, event(2, "discussion", "later"))

    Org.set_host(db, session.session_key, Placement.local_host_name())
    Org.retire(db, session.session_key, "user:owner", 60_000)
    session_key = session.session_key

    assert {:error, "harklight_origin_unavailable"} =
             HarklightWakes.capture_line(db, @handle, event(2, "discussion", "later"))

    assert {:ok, [[1]]} = DB.query(db, "SELECT count(*) FROM harklight_wake_entries")

    assert {:ok, [[^session_key, "pending"]]} =
             DB.query(db, "SELECT sessionKey,state FROM wakes WHERE wakeId LIKE ?1", [
               "w_harklight_" <> @handle <> "_%"
             ])
  end

  test "moving the origin stops its running controller", %{db: db, call: call, session: session} do
    assert %{state: "registered"} = HarklightWakes.register(db, call)
    test_pid = self()

    listener = fn manager, handle, _vendor_id ->
      :ok = GenServer.call(manager, {:attached, handle})
      send(test_pid, {:listener_running, self()})

      receive do
        :never -> :ok
      end
    end

    start_supervised!({HarklightWakes, db: db, listener: listener})
    assert_receive {:listener_running, worker}
    ref = Process.monitor(worker)

    Org.set_host(db, session.session_key, "another-host")
    assert_receive {:DOWN, ^ref, :process, ^worker, :shutdown}

    assert {:ok, [["unavailable", "origin_unavailable"]]} =
             DB.query(db, "SELECT state,lastError FROM harklight_wake_handles WHERE handle=?1", [
               @handle
             ])
  end

  test "a new harness pointer reattaches one controller with its current vendor ID", %{
    db: db,
    call: call,
    session: session
  } do
    assert %{state: "registered"} = HarklightWakes.register(db, call)
    test_pid = self()

    listener = fn manager, handle, vendor_id ->
      :ok = GenServer.call(manager, {:attached, handle})
      send(test_pid, {:listener_running, self(), vendor_id})

      receive do
        :never -> :ok
      end
    end

    start_supervised!({HarklightWakes, db: db, listener: listener})
    assert_receive {:listener_running, old_worker, nil}
    ref = Process.monitor(old_worker)

    Org.append_pointer(db, session.session_key, "vendor-next", "loaded")
    assert_receive {:DOWN, ^ref, :process, ^old_worker, :shutdown}
    assert_receive {:listener_running, new_worker, "vendor-next"}
    refute old_worker == new_worker
  end

  test "completed captured wakes stay with the retired origin and notify its owner", %{
    db: db,
    call: call,
    session: session,
    main: main
  } do
    assert %{state: "registered"} = HarklightWakes.register(db, call)
    assert :ok = HarklightWakes.capture_line(db, @handle, event(1, "terminal", "final"))
    test_pid = self()

    listener = fn manager, handle, _vendor_id ->
      :ok = GenServer.call(manager, {:attached, handle})
      :ok = GenServer.call(manager, {:finished, handle, :complete})
      send(test_pid, :listener_completed)
    end

    start_supervised!({HarklightWakes, db: db, listener: listener})
    assert_receive :listener_completed
    Org.retire(db, session.session_key, "user:owner", 60_000)
    :sys.get_state(HarklightWakes)
    session_key = session.session_key
    main_key = main.session_key

    assert {:ok, [[^session_key, "pending"]]} =
             DB.query(db, "SELECT sessionKey,state FROM wakes WHERE wakeId LIKE ?1", [
               "w_harklight_" <> @handle <> "_%"
             ])

    assert {:ok, [[^main_key]]} =
             DB.query(
               db,
               "SELECT sessionKey FROM wakes WHERE wakeId=?1",
               ["w_harklight_notice_recovery_" <> @handle]
             )
  end

  test "retract preserves a queued reply with context and cancels only later captures", %{
    db: db,
    call: call
  } do
    alias Tightbeam.{Ledger, HarklightLifecycle}

    assert :ok =
             HarklightWakes.capture_line(db, @handle, event(1, "discussion", "keep this reply"))

    {:ok, [[wake, prompt]]} =
      DB.query(db, "SELECT wakeId,prompt FROM wakes WHERE wakeId LIKE 'w_harklight_%'")

    Ledger.enqueue(db, %{
      session_key: call.session_key,
      message_id: "queued-reply",
      wake_id: wake,
      origin: "process:tightbeam",
      prompt: prompt
    })

    runner = fn ["retract", "--session", @handle, "--request", "request", "--op-id", op] ->
      frame(%{kind: "committed", operation: "withdraw", op_id: op, response: %{}})
    end

    assert %{outcome: "committed", wake_effect: "ended", pending_delivery: [%{event_id: "1"}]} =
             HarklightSend.change_request(
               db,
               %{call | params: %{message_id: "request"}},
               "retract",
               runner: runner
             )

    assert :ok = HarklightWakes.capture_line(db, @handle, event(2, "discussion", "too late"))

    assert :ok =
             HarklightWakes.capture_line(db, @handle, event(1, "discussion", "keep this reply"))

    assert {:ok, turn} = Ledger.claim_next(db, call.session_key, "test")
    assert turn.prompt =~ "keep this reply"
    assert turn.prompt =~ "received before message request was retracted"
    refute turn.prompt =~ "too late"
    assert {:ok, [[1]]} = DB.query(db, "SELECT count(*) FROM harklight_wake_entries")
    assert HarklightLifecycle.lookup(db, "request").state == "committed"

    assert {:ok, [["ended", "not_needed"]]} =
             DB.query(db, "SELECT state,acknowledgment FROM harklight_subscription_ends")
  end

  test "plural supersede holds early own terminals, acknowledges once and preserves replies", %{
    db: db,
    call: call
  } do
    bind_extra(db, call, "second")
    bind_extra(db, call, "closed")
    assert :ok = HarklightWakes.capture_line(db, @handle, event(1, "discussion", "earlier reply"))

    runner =
      lifecycle_runner(db,
        before_commit: fn ->
          assert :ok = HarklightWakes.capture_line(db, @handle, terminal(2, "request"))
          assert :ok = HarklightWakes.capture_line(db, @handle, terminal(3, "second"))
          assert {:ok, [[1]]} = DB.query(db, "SELECT count(*) FROM harklight_wake_entries")
        end,
        warnings: [%{message_id: "closed", reason: "closed"}]
      )

    send_call = %{
      call
      | params: %{
          harklight_session: @handle,
          sender_id: "sender",
          title: "Replacement",
          supersedes: ["request", "second", "request", "closed", "unknown"]
        }
    }

    result = HarklightSend.send_request(db, send_call, runner: runner)

    assert %{
             outcome: "committed",
             message_id: "replacement",
             wake_effect: "subscribed",
             pending_delivery: [%{event_id: "1"}]
           } = result

    assert Enum.map(result.supersedes, &{&1.message_id, &1.effect}) == [
             {"request", "ended"},
             {"second", "ended"},
             {"closed", "unchanged"},
             {"unknown", "no_subscription"}
           ]

    assert Enum.take(result.supersedes, 2) |> Enum.all?(&(&1.acknowledgment == "acknowledged"))
    assert_receive {:acked, "2"}
    assert_receive {:acked, "3"}
    Tightbeam.HarklightLifecycle.process_terminals(db, runner: runner)
    refute_receive {:acked, _}

    assert :ok =
             HarklightWakes.capture_line(
               db,
               @handle,
               event(4, "discussion", "new reply", "replacement")
             )

    assert {:ok, [[2]]} = DB.query(db, "SELECT count(*) FROM harklight_wake_entries")
    assert {:ok, [[statement]]} = DB.query(db, "SELECT statement FROM harklight_entry_context")
    assert statement =~ "superseded by replacement"
  end

  test "failed own terminal acknowledgment stays open and is never retried", %{db: db, call: call} do
    runner =
      lifecycle_runner(db,
        before_commit: fn ->
          HarklightWakes.capture_line(db, @handle, terminal(1, "request"))
        end,
        ack_failure: true
      )

    result =
      HarklightSend.send_request(
        db,
        %{
          call
          | params: %{
              harklight_session: @handle,
              sender_id: "sender",
              title: "Replacement",
              supersedes: ["request"]
            }
        },
        runner: runner
      )

    assert [%{acknowledgment: "failed", subscription_state: "open", reason: reason}] =
             result.supersedes

    assert reason =~ "still open"
    assert_receive {:acked, "1"}
    Tightbeam.HarklightLifecycle.process_terminals(db, runner: runner)
    refute_receive {:acked, _}
    assert {:ok, [[0]]} = DB.query(db, "SELECT count(*) FROM harklight_wake_entries")
  end

  test "an uncertain supersede can be settled once with the same operation and inputs", %{
    db: db,
    call: call
  } do
    runner = lifecycle_runner(db, unknown: true)

    send_call = %{
      call
      | params: %{
          harklight_session: @handle,
          sender_id: "sender",
          title: "Replacement",
          supersedes: ["request"]
        }
    }

    assert %{
             outcome: "outcome_unknown",
             message_id: "replacement",
             op_id: op,
             wake_effect: "none"
           } = HarklightSend.send_request(db, send_call, runner: runner)

    record = Tightbeam.HarklightLifecycle.lookup(db, "replacement")
    no_op = fn _ -> flunk("unresolved lifecycle command ran Harklight") end

    assert %{outcome: "refused", reason: reason} =
             HarklightSend.change_request(
               db,
               %{call | params: %{message_id: "replacement"}},
               "retract",
               runner: no_op
             )

    assert reason =~ "harklight-settle"

    assert %{outcome: "refused"} =
             HarklightSend.send_request(
               db,
               %{send_call | params: %{send_call.params | supersedes: ["replacement"]}},
               runner: no_op
             )

    settled =
      HarklightSend.settle(db, %{call | params: %{message_id: "replacement"}},
        runner: lifecycle_runner(db)
      )

    assert %{command: "settle", outcome: "committed", op_id: ^op, wake_effect: "subscribed"} =
             settled

    assert record.payload == Tightbeam.HarklightLifecycle.lookup(db, "replacement").payload

    assert %{outcome: "refused", reason: reason} =
             HarklightSend.settle(db, %{call | params: %{message_id: "replacement"}},
               runner: no_op
             )

    assert reason =~ "already settled as committed"
    assert :ok = HarklightSend.recover_pending(db, runner: no_op)
  end

  test "refused send keeps its minted ID and is not recovered again", %{db: db, call: call} do
    runner = lifecycle_runner(db, refused: true)

    result =
      HarklightSend.send_request(
        db,
        %{
          call
          | params: %{harklight_session: @handle, sender_id: "sender", title: "Replacement"}
        },
        runner: runner
      )

    assert %{outcome: "refused", message_id: "replacement", wake_effect: "none", reason: reason} =
             result

    assert reason =~ "not sent"

    assert :ok =
             HarklightSend.recover_pending(db, runner: fn _ -> flunk("refused send retried") end)

    assert %{outcome: "refused", reason: reason} =
             HarklightSend.settle(db, %{call | params: %{message_id: "replacement"}})

    assert reason =~ "already settled as refused"
  end

  test "cross-session retract is allowed and an uncertain command may be reissued", %{
    db: db,
    call: call,
    main: main
  } do
    caller = %{
      call
      | session_key: main.session_key,
        principal: {:session, main.session_key},
        transport_session_key: main.session_key,
        params: %{message_id: "request"}
    }

    runner = fn ["retract", "--session", @handle, "--request", "request", "--op-id", op] ->
      send(self(), {:operation, op})
      {JSON.encode!(%{kind: "outcome_unknown", op_id: op}), 7}
    end

    assert %{outcome: "outcome_unknown", wake_effect: "none"} =
             HarklightSend.change_request(db, caller, "retract", runner: runner)

    assert_receive {:operation, first}

    assert %{outcome: "outcome_unknown"} =
             HarklightSend.change_request(db, caller, "retract", runner: runner)

    assert_receive {:operation, second}
    refute first == second
    assert {:ok, [[0]]} = DB.query(db, "SELECT count(*) FROM harklight_subscription_ends")

    committed = fn args ->
      frame(%{kind: "committed", operation: "withdraw", op_id: List.last(args), response: %{}})
    end

    assert %{outcome: "committed", wake_effect: "ended"} =
             HarklightSend.change_request(db, caller, "retract", runner: committed)
  end

  test "revise passes its base revision and keeps the reply subscription", %{db: db, call: call} do
    runner = fn args ->
      assert Enum.take(args, 9) == [
               "revise",
               "--session",
               @handle,
               "--request",
               "request",
               "--base-revision",
               "1",
               "--title",
               "Updated"
             ]

      assert "--clear-choices" in args

      frame(%{
        kind: "committed",
        operation: "revise",
        op_id: List.last(args),
        response: %{revision: 2}
      })
    end

    revised = %{
      call
      | params: %{message_id: "request", base_revision: 1, title: "Updated", clear_choices: true}
    }

    assert %{outcome: "committed", message_id: "request", revision: 2, wake_effect: "kept"} =
             HarklightSend.change_request(db, revised, "revise", runner: runner)

    assert :ok =
             HarklightWakes.capture_line(db, @handle, event(1, "discussion", "after revision"))

    assert %{outcome: "refused", reason: "request is at revision 2"} =
             HarklightSend.change_request(db, revised, "revise",
               runner: fn _ -> {"request is at revision 2", 2} end
             )
  end

  test "a sealed batch gets the pre-retract statement at claim without another wake", %{
    db: db,
    call: call
  } do
    start_supervised!({Tightbeam.ConnRegistry, name: Tightbeam.ConnRegistry})
    start_supervised!({Tightbeam.NoticeBatcherFixture.LaneStub, Tightbeam.LaneManager})
    assert :ok = HarklightWakes.capture_line(db, @handle, event(1, "discussion", "sealed reply"))
    [carrier] = Tightbeam.NoticeBatcher.recover(db, System.system_time(:millisecond) + 1000)

    assert {:ok, [["queued"]]} =
             DB.query(db, "SELECT status FROM turns WHERE wakeId=?1", [carrier])

    runner = fn args ->
      frame(%{kind: "committed", operation: "withdraw", op_id: List.last(args), response: %{}})
    end

    assert %{pending_delivery: [%{event_id: "1"}]} =
             HarklightSend.change_request(
               db,
               %{call | params: %{message_id: "request"}},
               "retract",
               runner: runner
             )

    assert {:ok, turn} = Tightbeam.Ledger.claim_next(db, call.session_key, "sealed-test")
    assert turn.prompt =~ "sealed reply"
    assert turn.prompt =~ "received before message request was retracted"
    assert :ok = HarklightWakes.capture_line(db, @handle, event(1, "discussion", "sealed reply"))
    assert [] = Tightbeam.NoticeBatcher.recover(db, System.system_time(:millisecond) + 1000)
    assert {:ok, [[1]]} = DB.query(db, "SELECT count(*) FROM turns")
  end

  test "an unresolved terminal cannot be overtaken and refusal releases it in feed order", %{
    db: db,
    call: call
  } do
    start_supervised!({Tightbeam.ConnRegistry, name: Tightbeam.ConnRegistry})
    start_supervised!({Tightbeam.NoticeBatcherFixture.LaneStub, Tightbeam.LaneManager})
    bind_extra(db, call, "second")

    runner =
      lifecycle_runner(db,
        unknown: true,
        before_commit: fn ->
          assert :ok = HarklightWakes.capture_line(db, @handle, terminal(1, "request"))

          assert :ok =
                   HarklightWakes.capture_line(
                     db,
                     @handle,
                     event(2, "discussion", "second entry", "second")
                   )
        end
      )

    assert %{outcome: "outcome_unknown"} =
             HarklightSend.send_request(
               db,
               %{
                 call
                 | params: %{
                     harklight_session: @handle,
                     sender_id: "sender",
                     title: "Replacement",
                     supersedes: ["request"]
                   }
               },
               runner: runner
             )

    assert [] = Tightbeam.NoticeBatcher.recover(db, System.system_time(:millisecond) + 1000)

    assert %{outcome: "refused"} =
             HarklightSend.settle(db, %{call | params: %{message_id: "replacement"}},
               runner: lifecycle_runner(db, refused: true)
             )

    [_carrier] = Tightbeam.NoticeBatcher.recover(db, System.system_time(:millisecond) + 1000)
    assert {:ok, turn} = Tightbeam.Ledger.claim_next(db, call.session_key, "ordered-test")
    assert [before, _after] = String.split(turn.prompt, "second entry")
    assert before =~ "superseded"
    refute_receive {:acked, _}
  end

  test "startup completes a pending self-terminal acknowledgment without a wake", %{
    db: db,
    call: call
  } do
    op = Tightbeam.Id.uuid4()

    request = %{
      session_handle: @handle,
      message: %{sender_id: "sender", message_id: "replacement", supersedes: ["request"]}
    }

    payload = JSON.encode!(%{request: request, files: []})
    HarklightWakes.prepare_send(db, call, op, payload)
    assert :ok = HarklightWakes.capture_line(db, @handle, terminal(1, "request"))
    HarklightWakes.bind_send(db, call, op, payload, "{}", @handle, "sender", "replacement")
    parent = self()

    runner = fn ["ack", "--session", @handle, "--event", "1"] ->
      send(parent, :recovered_ack)
      frame(%{kind: "acknowledged", event_id: "1", status: "already_delivered"})
    end

    listener = fn manager, _, _ ->
      ref = Process.monitor(manager)

      receive do
        {:DOWN, ^ref, :process, ^manager, _} -> :ok
      end
    end

    start_supervised!({HarklightWakes, db: db, listener: listener, send_runner: runner})
    assert_receive :recovered_ack, 2000
    stop_supervised(HarklightWakes)
    start_supervised!({HarklightWakes, db: db, listener: listener, send_runner: runner})
    refute_receive :recovered_ack

    assert {:ok, [["acknowledged", "ended"]]} =
             DB.query(db, "SELECT acknowledgment,state FROM harklight_subscription_ends")

    assert {:ok, [[0]]} = DB.query(db, "SELECT count(*) FROM harklight_wake_entries")
  end

  test "superseding another session leaves its terminal wake and never acknowledges it", %{
    db: db,
    call: call,
    main: main
  } do
    other_handle = "e0205d95-f840-460f-951e-2a0f995be13d"

    other_call = %{
      call
      | session_key: main.session_key,
        principal: {:session, main.session_key},
        transport_session_key: main.session_key
    }

    op = Tightbeam.Id.uuid4()

    payload =
      JSON.encode!(%{
        request: %{
          session_handle: other_handle,
          message: %{sender_id: "sender", message_id: "foreign"}
        }
      })

    HarklightWakes.prepare_send(db, other_call, op, payload)

    assert %{state: "registered"} =
             HarklightWakes.bind_send(
               db,
               other_call,
               op,
               payload,
               "{}",
               other_handle,
               "sender",
               "foreign"
             )

    terminal =
      terminal(1, "foreign")
      |> JSON.decode!()
      |> Map.put("session_handle", other_handle)
      |> JSON.encode!()

    runner =
      lifecycle_runner(db,
        before_commit: fn ->
          assert :ok = HarklightWakes.capture_line(db, other_handle, terminal)
        end
      )

    assert %{supersedes: [%{effect: "other_session"}]} =
             HarklightSend.send_request(
               db,
               %{
                 call
                 | params: %{
                     harklight_session: @handle,
                     sender_id: "sender",
                     title: "Replacement",
                     supersedes: ["foreign"]
                   }
               },
               runner: runner
             )

    refute_receive {:acked, _}

    assert {:ok, [[recipient, prompt]]} =
             DB.query(db, "SELECT sessionKey,prompt FROM wakes WHERE wakeId LIKE 'w_harklight_%'")

    assert recipient == main.session_key
    assert prompt =~ "superseded"
  end

  test "a prepare failure has no invented message ID and shows unchanged supersede effects", %{
    db: db,
    call: call
  } do
    result =
      HarklightSend.send_request(
        db,
        %{
          call
          | params: %{
              harklight_session: @handle,
              sender_id: "sender",
              title: "Replacement",
              supersedes: ["request", "request"]
            }
        },
        runner: fn _ -> raise "executable unavailable" end
      )

    assert %{
             outcome: "failed",
             wake_effect: "none",
             supersedes: [%{message_id: "request", effect: "unchanged"}],
             reason: reason
           } = result

    refute Map.has_key?(result, :message_id)
    assert reason =~ "could not complete"
    assert reason =~ "not sent"
    assert result.sender_id == "sender"
  end

  test "completion before terminal capture needs no acknowledgment, including after restart", %{
    db: db,
    call: call
  } do
    ack_count = :atomics.new(1, [])
    base_runner = lifecycle_runner(db)

    runner = fn args ->
      if hd(args) == "ack", do: :atomics.add_get(ack_count, 1, 1)
      base_runner.(args)
    end

    result =
      HarklightSend.send_request(
        db,
        %{
          call
          | params: %{
              harklight_session: @handle,
              sender_id: "sender",
              title: "Replacement",
              supersedes: ["request"]
            }
        },
        runner: runner
      )

    assert %{outcome: "committed", supersedes: [%{effect: "ended", acknowledgment: "pending"}]} =
             result

    parent = self()

    listener = fn manager, handle, _ ->
      assert :ok = GenServer.call(manager, {:finished, handle, :complete})
      send(parent, :conversation_finished_before_terminal)
    end

    # Observe the return of the actual asynchronous startup recovery task.
    # A manager call alone cannot fence that task, and elapsed silence cannot
    # establish that it has finished considering acknowledgments.
    recovery = {Tightbeam.HarklightLifecycle, :process_terminals, 2}
    :erlang.trace_pattern(recovery, [{:_, [], [{:return_trace}]}], [:local])
    :erlang.trace(self(), true, [:call, :set_on_spawn])

    try do
      for iteration <- 1..2 do
        {:ok, manager} =
          HarklightWakes.start_link(db: db, listener: listener, send_runner: runner)

        assert_receive {:trace, task, :call,
                        {Tightbeam.HarklightLifecycle, :process_terminals, [^db, _]}},
                       2000

        assert_receive {:trace, ^task, :return_from, ^recovery, :ok}, 2000

        if iteration == 1, do: assert_receive(:conversation_finished_before_terminal, 2000)

        assert {:ok, [["not_needed", "ended", nil, nil]]} =
                 DB.query(
                   db,
                   "SELECT acknowledgment,state,reason,ackEventId FROM harklight_subscription_ends WHERE messageId='request'"
                 )

        assert %{
                 supersedes: [
                   %{acknowledgment: "not_needed", subscription_state: "ended", reason: nil}
                 ]
               } =
                 Tightbeam.HarklightLifecycle.refresh_acknowledgments(db, result)

        assert :atomics.get(ack_count, 1) == 0
        assert {:ok, [[0]]} = DB.query(db, "SELECT count(*) FROM harklight_held_terminals")
        assert {:ok, [[0]]} = DB.query(db, "SELECT count(*) FROM harklight_wake_entries")

        assert {:ok, [[0]]} =
                 DB.query(db, "SELECT count(*) FROM wakes WHERE sessionKey=?1", [call.session_key])

        GenServer.stop(manager)
      end
    after
      if manager = Process.whereis(HarklightWakes), do: GenServer.stop(manager)
      :erlang.trace(self(), false, [:call, :set_on_spawn])
      :erlang.trace_pattern(recovery, false, [:local])
    end
  end

  test "conversation completion ends a failed-ack subscription without retrying it", %{
    db: db,
    call: call
  } do
    runner =
      lifecycle_runner(db,
        ack_failure: true,
        before_commit: fn ->
          HarklightWakes.capture_line(db, @handle, terminal(1, "request"))
        end
      )

    assert %{outcome: "committed"} =
             HarklightSend.send_request(
               db,
               %{
                 call
                 | params: %{
                     harklight_session: @handle,
                     sender_id: "sender",
                     title: "Replacement",
                     supersedes: ["request"]
                   }
               },
               runner: runner
             )

    assert_receive {:acked, "1"}
    parent = self()

    listener = fn manager, handle, _ ->
      assert :ok = GenServer.call(manager, {:finished, handle, :complete})
      send(parent, :conversation_finished)
    end

    start_supervised!({HarklightWakes, db: db, listener: listener, send_runner: runner})
    assert_receive :conversation_finished, 2000

    assert {:ok, [["ended", "failed"]]} =
             DB.query(db, "SELECT state,acknowledgment FROM harklight_subscription_ends")

    refute_receive {:acked, _}
  end

  defp frame(value), do: {JSON.encode!(value) <> "\n", 0}

  defp bind_extra(db, call, message) do
    op = Tightbeam.Id.uuid4()

    payload =
      JSON.encode!(%{
        request: %{session_handle: @handle, message: %{sender_id: "sender", message_id: message}}
      })

    HarklightWakes.prepare_send(db, call, op, payload)
    HarklightWakes.bind_send(db, call, op, payload, "{}", @handle, "sender", message)
  end

  defp terminal(cursor, message) do
    event(cursor, "terminal", "", message)
    |> JSON.decode!()
    |> Map.put("entry", %{
      "kind" => "terminal",
      "author" => "server",
      "terminal_state" => "superseded"
    })
    |> JSON.encode!()
  end

  defp completion_event(handle, cursor, message_id, kind, author, channel \\ nil) do
    entry = %{"kind" => kind, "author" => author}

    entry =
      if kind == "terminal",
        do: Map.merge(entry, %{"terminal_state" => "answered", "terminal_kind" => "answer"}),
        else: Map.put(entry, "content", "message")

    event = %{
      "kind" => "event",
      "session_handle" => handle,
      "event_id" => Integer.to_string(cursor),
      "feed_cursor" => cursor,
      "request" => %{"sender_id" => "sender", "message_id" => message_id},
      "request_revision" => 1,
      "delivered" => false,
      "acted" => false,
      "entry" => entry
    }

    if channel, do: Map.put(event, "channel", channel), else: event
  end

  defp seed_completion_handle(db, session_key, handle, message_id) do
    now = System.system_time(:millisecond)

    assert {:ok, _} =
             DB.query(
               db,
               "INSERT INTO harklight_wake_handles(handle,sessionKey,host,state,createdAt,updatedAt) VALUES(?1,?2,?3,'active',?4,?4)",
               [handle, session_key, Placement.local_host_name(), now]
             )

    assert {:ok, _} =
             DB.query(
               db,
               "INSERT INTO harklight_wake_requests(senderId,messageId,handle) VALUES('sender',?1,?2)",
               [message_id, handle]
             )
  end

  defp completion_wake(db, handle) do
    assert {:ok, [[wake_id]]} =
             DB.query(db, "SELECT wakeId FROM harklight_wake_entries WHERE handle=?1", [handle])

    wake_id
  end

  defp completion_turn(db, session_key, wake_id, status, error) do
    now = System.system_time(:millisecond)

    assert {:ok, _} =
             DB.query(
               db,
               "INSERT INTO turns(sessionKey,messageId,wakeId,origin,prompt,status,error,createdAt,endedAt) VALUES(?1,?2,?3,'process:test','completion source wake',?4,?5,?6,?6)",
               [session_key, Tightbeam.Id.uuid4(), wake_id, status, error, now]
             )

    assert {:ok, [[turn_seq]]} = DB.query(db, "SELECT seq FROM turns WHERE wakeId=?1", [wake_id])

    assert {:ok, _} =
             DB.query(
               db,
               "UPDATE wakes SET state='fired',firedAt=?3,deliveredTurnSeq=?2 WHERE wakeId=?1",
               [wake_id, turn_seq, now]
             )

    turn_seq
  end

  defp idle_runner do
    status = %{
      "session_handle" => @handle,
      "open_requests" => 0,
      "pending_undelivered" => 0,
      "pending_delivered_unacted" => 0
    }

    fn
      ["read", "--session", @handle] -> {"", 0}
      ["status", "--session", @handle] -> {JSON.encode!(status), 0}
    end
  end

  defp mark_completion_wakes_delivered(db, handle) do
    assert {:ok, rows} =
             DB.query(
               db,
               "SELECT wakeId,sessionKey FROM harklight_wake_entries e JOIN harklight_wake_handles h ON h.handle=e.handle WHERE e.handle=?1 ORDER BY e.eventId",
               [handle]
             )

    for [wake_id, session_key] <- Enum.uniq_by(rows, &hd/1) do
      assert {:ok, _} =
               DB.query(
                 db,
                 "INSERT INTO turns(sessionKey,messageId,wakeId,origin,prompt,status,createdAt) VALUES(?1,?2,?3,'process:test','delivered source wake','delivered',?4) ON CONFLICT(wakeId) DO UPDATE SET status='delivered'",
                 [session_key, Tightbeam.Id.uuid4(), wake_id, System.system_time(:millisecond)]
               )

      assert {:ok, [[turn_seq]]} =
               DB.query(db, "SELECT seq FROM turns WHERE wakeId=?1", [wake_id])

      assert {:ok, _} =
               DB.query(
                 db,
                 "UPDATE wakes SET state='fired',firedAt=?3,deliveredTurnSeq=?2 WHERE wakeId=?1",
                 [wake_id, turn_seq, System.system_time(:millisecond)]
               )
    end
  end

  defp completion_runner(responses, parent) do
    fn
      ["read", "--session", handle] = args ->
        Agent.update(responses, fn current -> Map.update!(current, :commands, &[args | &1]) end)

        events =
          Agent.get(responses, fn current ->
            case current.events do
              events when is_map(events) -> Map.get(events, handle, [])
              events when is_list(events) -> events
            end
          end)

        output = Enum.map_join(events, "\n", &JSON.encode!/1)
        send(parent, {:harklight_command, args})
        if events == [], do: {"", 0}, else: {output <> "\n", 0}

      ["status", "--session", handle] = args ->
        Agent.update(responses, fn current -> Map.update!(current, :commands, &[args | &1]) end)

        status =
          Agent.get(responses, fn current ->
            case current.status do
              %{"session_handle" => _} = status -> status
              statuses when is_map(statuses) -> Map.fetch!(statuses, handle)
            end
          end)

        send(parent, {:harklight_command, args})
        {JSON.encode!(status) <> "\n", 0}

      _args ->
        {"unexpected Harklight Agent command", 2}
    end
  end

  defp notifying_listener(parent) do
    fn manager, handle, vendor ->
      :ok = GenServer.call(manager, {:attached, handle})
      send(parent, {:restored, handle, vendor})

      receive do
        :never -> :ok
      end
    end
  end

  defp eventually(fun, attempts \\ 200)
  defp eventually(fun, 0), do: fun.()

  defp eventually(fun, attempts) do
    if fun.() do
      true
    else
      Process.sleep(10)
      eventually(fun, attempts - 1)
    end
  end

  # These frames exercise local custody and operation handling, not claims
  # about a deployed Harklight service. Their shape follows the CLI interface.
  defp lifecycle_runner(db, opts \\ []) do
    fn args ->
      cond do
        Enum.take(args, 2) == ["send", "--prepare"] ->
          value = fn flag -> Enum.at(args, Enum.find_index(args, &(&1 == flag)) + 1) end

          supersedes =
            Enum.chunk_every(args, 2, 1, :discard)
            |> Enum.flat_map(fn
              ["--supersedes", id] -> [id]
              _ -> []
            end)

          op = value.("--op-id")

          frame(%{
            kind: "prepared",
            op_id: op,
            files: [],
            request: %{
              type: "send",
              op_id: op,
              session_handle: @handle,
              message: %{
                sender_id: "sender",
                message_id: "replacement",
                title: "Replacement",
                supersedes: supersedes
              }
            }
          })

        hd(args) == "ack" ->
          event = List.last(args)
          send(self(), {:acked, event})

          if opts[:ack_failure],
            do: {"ack refused", 2},
            else: frame(%{kind: "acknowledged", event_id: event, status: "delivered"})

        true ->
          op = List.last(args)

          assert {:ok, [[_payload]]} =
                   DB.query(db, "SELECT payload FROM harklight_send_operations WHERE opId=?1", [
                     op
                   ])

          if callback = opts[:before_commit], do: callback.()

          cond do
            opts[:unknown] ->
              {JSON.encode!(%{kind: "outcome_unknown", op_id: op}), 7}

            opts[:refused] ->
              {JSON.encode!(%{kind: "refused", op_id: op, reason: "not accepted"}), 2}

            true ->
              frame(%{
                kind: "committed",
                operation: "send",
                op_id: op,
                response: %{session_handle: @handle, supersedes_warnings: opts[:warnings] || []}
              })
          end
      end
    end
  end

  defp event(id, kind, content, message_id \\ "request") do
    JSON.encode!(%{
      "kind" => "event",
      "session_handle" => @handle,
      "event_id" => Integer.to_string(id),
      "feed_cursor" => id,
      "request" => %{"sender_id" => "sender", "message_id" => message_id},
      "request_revision" => 1,
      "delivered" => false,
      "acted" => false,
      "entry" => %{"kind" => kind, "author" => "person", "content" => content}
    })
  end
end
