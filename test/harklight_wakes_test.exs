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
