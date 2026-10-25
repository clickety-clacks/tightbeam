defmodule Tightbeam.HarklightWakesTest do
  use Tightbeam.TestCase, async: false

  alias Tightbeam.{DB, HarklightSend, HarklightWakes, Model, Org, Placement}

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
    main: main
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
    main_key = main.session_key

    assert {:ok, [["unavailable", "listener_stopped"]]} =
             DB.query(db, "SELECT state,lastError FROM harklight_wake_handles WHERE handle=?1", [
               @handle
             ])

    assert {:ok, [[^main_key, prompt]]} =
             DB.query(
               db,
               "SELECT sessionKey,prompt FROM wakes WHERE prompt LIKE 'Harklight listening%'"
             )

    assert String.contains?(prompt, @handle)
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
               ["w_harklight_notice_origin_unavailable_" <> @handle]
             )
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
