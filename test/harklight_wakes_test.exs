defmodule Tightbeam.HarklightWakesTest do
  use Tightbeam.TestCase, async: false

  alias Tightbeam.{
    DB,
    Ephemeral,
    HarklightFollows,
    HarklightLifecycle,
    HarklightSend,
    HarklightWakes,
    Ledger,
    Model,
    Org,
    Placement,
    TurnLifecycle,
    Wakes
  }

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

  @tag :origin_consumer
  test "an unavailable handle does not stop the shared receiver or lose its offer",
       %{db: db, session: session} do
    assert {:ok, :started} =
             Tightbeam.HarklightOrigin.begin_move(db, @handle, session.session_key)

    assert {:ok, _} = Tightbeam.HarklightOrigin.confirmed(db, @handle, true)
    assert {:ok, _} = DB.query(db, "UPDATE harklight_wake_handles SET state='complete'")
    parent = self()

    manager =
      start_supervised!(
        {Tightbeam.HarklightOriginListener,
         db: db,
         recover_moves: false,
         runner: fn _ -> {"", 1} end,
         listener: fn manager ->
           send(parent, {:origin_started, self()})
           origin_test_loop(manager, parent)
         end}
      )

    assert_receive {:origin_started, worker}
    send(worker, {:offer, event(1, "discussion", "Retained until available")})
    assert_receive {:offered, :captured}
    assert Process.alive?(worker)
    assert {:ok, [[0]]} = DB.query(db, "SELECT COUNT(*) FROM wakes")
    assert {:ok, [[1]]} = DB.query(db, "SELECT COUNT(*) FROM harklight_origin_offers")
    assert {:ok, _} = DB.query(db, "UPDATE harklight_wake_handles SET state='active'")
    Tightbeam.HarklightOriginListener.resume_handle(@handle)
    :sys.get_state(manager)
    assert {:ok, [[1]]} = DB.query(db, "SELECT COUNT(*) FROM wakes")
    assert {:ok, [[0]]} = DB.query(db, "SELECT COUNT(*) FROM harklight_origin_offers")
  end

  @tag :origin_consumer
  test "explicit cover waits for the real legacy child before its final declaration",
       %{db: db, call: call} do
    root = Path.join(System.tmp_dir!(), "origin-handover-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    executable = Path.join(root, "harklight-agent")
    pid_file = Path.join(root, "legacy-pid")
    count_file = Path.join(root, "covers")

    File.write!(executable, """
    #!/bin/sh
    case "$1" in
      attach) echo '{"kind":"attached","ready_for_listen":true}' ;;
      listen)
        if [ "$2" != "--origin" ]; then echo $$ > '#{pid_file}'; fi
        exec sleep 60 ;;
      status) echo '{"session_handle":"#{@handle}","open_requests":1,"pending_undelivered":0,"pending_delivered_unacted":0}' ;;
      cover)
        if [ -f '#{count_file}' ]; then
          if kill -0 "$(cat '#{pid_file}')" 2>/dev/null; then exit 19; fi
          echo 2 > '#{count_file}'
        else
          kill -0 "$(cat '#{pid_file}')" || exit 18
          echo 1 > '#{count_file}'
        fi
        echo '{"kind":"covered","session_handle":"#{@handle}","listening_support":{"origin_listener":true}}' ;;
      *) exit 2 ;;
    esac
    """)

    File.chmod!(executable, 0o755)
    previous = System.fetch_env!("PATH")
    System.put_env("PATH", root <> ":" <> previous)

    on_exit(fn ->
      System.put_env("PATH", previous)
      File.rm_rf!(root)
    end)

    runner = fn args -> System.cmd(executable, args, stderr_to_stdout: true) end
    legacy = start_supervised!({HarklightWakes, db: db, send_runner: runner})
    assert eventually(fn -> File.exists?(pid_file) end)
    origin = start_supervised!({Tightbeam.HarklightOriginListener, db: db, runner: runner})

    assert %{outcome: "covered", handle: @handle} =
             Tightbeam.HarklightOriginListener.cover(%{call | params: %{handle: @handle}}, origin)

    assert String.trim(File.read!(count_file)) == "2"

    assert {:ok, [["covered", 1]]} =
             DB.query(db, "SELECT state,confirmed FROM harklight_origin_moves")

    assert eventually(fn -> map_size(:sys.get_state(legacy).workers) == 0 end)
    stop_supervised!(Tightbeam.HarklightOriginListener)
    stop_supervised!(HarklightWakes)

    assert :ok =
             Tightbeam.HarklightChild.await_stopped(
               :origin,
               Application.fetch_env!(:tightbeam, :harklight_child_opts)
             )
  end

  @tag :origin_consumer
  test "moving and covered handles do not restore or reactivate a legacy listener",
       %{db: db, session: session} do
    assert {:ok, :started} =
             Tightbeam.HarklightOrigin.begin_move(db, @handle, session.session_key)

    parent = self()

    manager =
      start_supervised!(
        {HarklightWakes,
         db: db,
         listener: fn _, _, _ -> send(parent, :legacy_started) end,
         send_runner: fn _ -> {"", 1} end}
      )

    assert %{} = :sys.get_state(manager).workers

    for complete? <- [false, true] do
      if complete?, do: Tightbeam.HarklightOrigin.confirmed(db, @handle, true)
      GenServer.cast(manager, {:activate, @handle, true})
      GenServer.cast(manager, {:activate, @handle, false})
      GenServer.cast(manager, {:pointer_changed, session.session_key})
      GenServer.cast(manager, {:origin_ready, session.session_key})
      assert map_size(:sys.get_state(manager).workers) == 0
      refute_receive :legacy_started
    end
  end

  @tag :origin_consumer
  test "marking a move keeps the current legacy reader alive until the handover stop",
       %{db: db, session: session} do
    parent = self()

    manager =
      start_supervised!(
        {HarklightWakes,
         db: db,
         listener: fn manager, handle, _ ->
           :ok = GenServer.call(manager, {:attached, handle})
           send(parent, {:legacy_reader, self()})

           receive do
             {:capture, line} ->
               send(parent, {:legacy_captured, GenServer.call(manager, {:capture, handle, line})})
           end

           receive do
             :finish -> :ok
           end
         end,
         send_runner: fn _ -> {"", 1} end}
      )

    assert_receive {:legacy_reader, reader}

    assert {:ok, :started} =
             HarklightWakes.begin_origin_move(@handle, session.session_key, manager)

    GenServer.cast(manager, {:activate, @handle, true})
    GenServer.cast(manager, {:pointer_changed, session.session_key})
    assert :sys.get_state(manager).workers[@handle] == reader
    assert Process.alive?(reader)
    send(reader, {:capture, event(1, "discussion", "During move")})
    assert_receive {:legacy_captured, :ok}
    assert {:ok, [[1]]} = DB.query(db, "SELECT COUNT(*) FROM wakes")
  end

  @tag :origin_consumer
  test "M2 covers on both sides of the observed legacy exit", %{db: db, session: session} do
    assert {:ok, :started} =
             Tightbeam.HarklightOrigin.begin_move(db, @handle, session.session_key)

    {:ok, sequence} = Agent.start_link(fn -> [] end)

    covered =
      JSON.encode!(%{
        "kind" => "covered",
        "session_handle" => @handle,
        "listening_support" => %{"origin_listener" => true}
      })

    runner = fn ["cover", "--session", @handle] ->
      Agent.update(sequence, &(&1 ++ [:cover]))
      {covered, 0}
    end

    stop = fn @handle ->
      assert {:ok, [["moving", 1]]} =
               DB.query(db, "SELECT state,confirmed FROM harklight_origin_moves")

      Agent.update(sequence, &(&1 ++ [:exited]))
      :ok
    end

    assert :ok = Tightbeam.HarklightOrigin.migrate(db, @handle, runner: runner, stop: stop)
    assert [:cover, :exited, :cover] = Agent.get(sequence, & &1)

    assert {:ok, [["covered", 1]]} =
             DB.query(db, "SELECT state,confirmed FROM harklight_origin_moves")

    Agent.stop(sequence)
  end

  @tag :origin_consumer
  test "restart requires legacy exit proof before cover, and missing proof leaves the move pending",
       %{db: db, session: session} do
    assert {:ok, :started} =
             Tightbeam.HarklightOrigin.begin_move(db, @handle, session.session_key)

    assert {:error, :exit_unconfirmed} =
             Tightbeam.HarklightOrigin.migrate(db, @handle,
               restore: true,
               stop: fn _ -> {:error, :exit_unconfirmed} end,
               runner: fn _ -> flunk("cover must wait for exit proof") end
             )

    assert {:ok, [["moving", 0]]} =
             DB.query(db, "SELECT state,confirmed FROM harklight_origin_moves")

    {:ok, sequence} = Agent.start_link(fn -> [] end)

    assert :ok =
             Tightbeam.HarklightOrigin.migrate(db, @handle,
               restore: true,
               stop: fn _ -> Agent.update(sequence, &(&1 ++ [:exited])) end,
               runner: fn ["cover", "--session", @handle] ->
                 Agent.update(sequence, &(&1 ++ [:cover]))

                 {JSON.encode!(%{
                    "kind" => "covered",
                    "session_handle" => @handle,
                    "listening_support" => %{"origin_listener" => true}
                  }), 0}
               end
             )

    assert [:exited, :cover] = Agent.get(sequence, & &1)
    Agent.stop(sequence)
  end

  @tag :origin_consumer
  test "one origin receiver ignores foreign offers without triggering pending actions",
       %{db: db, session: session} do
    assert {:ok, :started} =
             Tightbeam.HarklightOrigin.begin_move(db, @handle, session.session_key)

    assert {:ok, _} =
             DB.query(
               db,
               """
               INSERT INTO harklight_subscription_ends(senderId,messageId,handle,opId,state,acknowledgment,ackEventId)
               VALUES('pending-sender','pending-message',?1,'pending-op','open','pending','99')
               """,
               [@handle]
             )

    parent = self()

    listener = fn manager ->
      send(parent, {:origin_started, self()})
      origin_test_loop(manager, parent)
    end

    runner = fn args ->
      send(parent, {:origin_action, args})
      {JSON.encode!(%{"kind" => "acknowledged", "event_id" => "99", "status" => "delivered"}), 0}
    end

    manager =
      start_supervised!(
        {Tightbeam.HarklightOriginListener,
         db: db, listener: listener, runner: runner, recover_moves: false}
      )

    assert_receive {:origin_started, worker}
    assert :ok = Tightbeam.HarklightOriginListener.ensure_started(manager)
    assert :ok = Tightbeam.HarklightOriginListener.ensure_started(manager)
    refute_receive {:origin_started, _}

    send(worker, {:offer, JSON.encode!(%{"kind" => "event", "session_handle" => "foreign"})})
    assert_receive {:offered, :ignored}
    refute_receive {:origin_action, _}
    send(worker, {:offer, event(1, "discussion", "Before receipt")})
    assert_receive {:offered, :captured}
    refute_receive {:origin_action, _}
    assert {:ok, [[0]]} = DB.query(db, "SELECT COUNT(*) FROM wakes")

    assert :ok = Tightbeam.HarklightOriginListener.confirm(@handle, false, manager)
    assert_receive {:origin_action, ["ack", "--session", @handle, "--event", "99"]}
    assert {:ok, [[1]]} = DB.query(db, "SELECT COUNT(*) FROM wakes")
    send(worker, {:offer, event(1, "discussion", "Before receipt")})
    assert_receive {:offered, :ok}
    assert {:ok, [[1]]} = DB.query(db, "SELECT COUNT(*) FROM wakes")
  end

  defp origin_test_loop(manager, parent) do
    receive do
      {:offer, line} ->
        send(parent, {:offered, GenServer.call(manager, {:line, line})})
        origin_test_loop(manager, parent)
    end
  end

  @tag :origin_consumer
  test "settling cover retries the unresolved support key before declaring coverage" do
    op_id = "df31cb41-662b-4235-a5c1-a6d9c4aec477"

    covered =
      JSON.encode!(%{
        "kind" => "covered",
        "session_handle" => @handle,
        "listening_support" => %{"origin_listener" => true}
      })

    for {receipt, status} <- [{"committed", 0}, {"refused", 2}] do
      {:ok, calls} = Agent.start_link(fn -> [] end)

      runner = fn args ->
        prior = Agent.get_and_update(calls, fn history -> {history, history ++ [args]} end)

        case {args, length(prior)} do
          {["cover", "--session", @handle], 0} ->
            {"support operation #{op_id} is unresolved; retry that exact operation before changing its fields\n",
             7}

          {["retry", "--op-id", ^op_id], 1} ->
            {JSON.encode!(%{"kind" => receipt, "op_id" => op_id, "operation" => "support"}),
             status}

          {["cover", "--session", @handle], 2} ->
            {covered, 0}
        end
      end

      assert :ok = Tightbeam.HarklightOrigin.settle_cover(runner, @handle)
      assert length(Agent.get(calls, & &1)) == 3
      Agent.stop(calls)
    end
  end

  @tag :origin_consumer
  test "an unknown retry or missing coverage receipt never completes a move" do
    op_id = "df31cb41-662b-4235-a5c1-a6d9c4aec477"

    runner = fn
      ["cover", "--session", @handle] ->
        {JSON.encode!(%{"kind" => "outcome_unknown", "operation" => "support", "op_id" => op_id}),
         7}

      ["retry", "--op-id", ^op_id] ->
        {"still unknown", 7}
    end

    assert {:pending, ^op_id} = Tightbeam.HarklightOrigin.settle_cover(runner, @handle)

    assert {:error, "coverage_unconfirmed"} =
             Tightbeam.HarklightOrigin.settle_cover(
               fn _ ->
                 {JSON.encode!(%{
                    "kind" => "covered",
                    "session_handle" => @handle,
                    "listening_support" => %{}
                  }), 0}
               end,
               @handle
             )
  end

  @tag :origin_consumer
  test "origin entries for foreign and noncovered handles have no effect", %{db: db} do
    for handle <- [@handle, "nonmatching-handle"] do
      line = JSON.encode!(%{"kind" => "event", "session_handle" => handle})
      assert :ignored = HarklightWakes.capture_origin_line(db, line)
    end

    for table <- [
          "harklight_origin_moves",
          "harklight_origin_offers",
          "harklight_wake_entries",
          "harklight_wake_deliveries",
          "wakes"
        ] do
      assert {:ok, [[0]]} = DB.query(db, "SELECT COUNT(*) FROM " <> table)
    end
  end

  @tag :origin_consumer
  test "a moving handle captures early offers and releases them only after a cover receipt",
       %{db: db, session: session} do
    assert {:ok, :started} =
             Tightbeam.HarklightOrigin.begin_move(db, @handle, session.session_key)

    line = event(1, "discussion", "Early reply")

    for _ <- 1..2, do: assert(:captured == HarklightWakes.capture_origin_line(db, line))
    assert {:ok, [[1]]} = DB.query(db, "SELECT COUNT(*) FROM harklight_origin_offers")
    assert {:ok, [[0]]} = DB.query(db, "SELECT COUNT(*) FROM wakes")

    # Re-entering after restart retains both the move and the captured offer.
    assert {:ok, :moving} = Tightbeam.HarklightOrigin.begin_move(db, @handle, session.session_key)
    assert {:ok, _} = Tightbeam.HarklightOrigin.confirmed(db, @handle)
    assert :ok = Tightbeam.HarklightOrigin.drain(db, @handle)
    assert :ok = Tightbeam.HarklightOrigin.drain(db, @handle)
    assert {:ok, [[0]]} = DB.query(db, "SELECT COUNT(*) FROM harklight_origin_offers")
    assert {:ok, [[1]]} = DB.query(db, "SELECT COUNT(*) FROM harklight_wake_entries")
    assert {:ok, [[1]]} = DB.query(db, "SELECT COUNT(*) FROM wakes")

    assert {:ok, [["moving", 1]]} =
             DB.query(db, "SELECT state,confirmed FROM harklight_origin_moves")

    assert {:ok, _} = Tightbeam.HarklightOrigin.confirmed(db, @handle, true)

    assert {:ok, [["covered", 1]]} =
             DB.query(db, "SELECT state,confirmed FROM harklight_origin_moves")
  end

  @tag :origin_consumer
  test "overlapping listeners and replay share one durable wake", %{db: db, session: session} do
    assert {:ok, :started} =
             Tightbeam.HarklightOrigin.begin_move(db, @handle, session.session_key)

    line = event(1, "discussion", "Reply")
    assert :captured = HarklightWakes.capture_origin_line(db, line)
    assert :ok = HarklightWakes.capture_line(db, @handle, line)
    assert {:ok, _} = Tightbeam.HarklightOrigin.confirmed(db, @handle)
    assert :ok = Tightbeam.HarklightOrigin.drain(db, @handle)
    assert :ok = HarklightWakes.capture_origin_line(db, line)
    assert :ok = HarklightWakes.capture_line(db, @handle, line)
    assert {:ok, [[1]]} = DB.query(db, "SELECT COUNT(*) FROM wakes")
    assert {:ok, [[1]]} = DB.query(db, "SELECT COUNT(*) FROM harklight_wake_deliveries")
  end

  @tag :origin_consumer
  test "buffered origin offers survive a later legacy capture advancing the cursor",
       %{db: db, session: session} do
    assert {:ok, :started} =
             Tightbeam.HarklightOrigin.begin_move(db, @handle, session.session_key)

    assert :captured = HarklightWakes.capture_origin_line(db, event(1, "discussion", "Earlier"))
    assert :ok = HarklightWakes.capture_line(db, @handle, event(2, "discussion", "Later"))
    assert {:ok, _} = Tightbeam.HarklightOrigin.confirmed(db, @handle)
    assert :ok = Tightbeam.HarklightOrigin.drain(db, @handle)

    assert {:ok, [["1"], ["2"]]} =
             DB.query(db, "SELECT eventId FROM harklight_wake_entries ORDER BY feedCursor")

    assert {:ok, [[2]]} = DB.query(db, "SELECT lastCursor FROM harklight_wake_handles")
    assert {:ok, [[2]]} = DB.query(db, "SELECT COUNT(*) FROM wakes")
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
          message_type: "request",
          message_kind: "blocker",
          importance: "high",
          stake: "A one-week delay",
          by_when: "2026-11-02T17:00:00Z",
          reply: true,
          sender_id: "sender",
          title: "Question",
          choices: ["Approve", "Defer"],
          files: ["/tmp/request.txt"]
        }
    }

    runner = fn args ->
      op_id = if "--prepare" in args, do: Enum.at(args, 3), else: List.last(args)

      cond do
        Enum.take(args, 2) == ["send", "--prepare"] ->
          assert "--controller" in args
          assert "--reply" in args

          for pair <- [
                ["--type", "request"],
                ["--kind", "blocker"],
                ["--importance", "high"],
                ["--stake", "A one-week delay"],
                ["--by-when", "2026-11-02T17:00:00Z"],
                ["--choice", "Approve"],
                ["--choice", "Defer"]
              ] do
            assert pair in Enum.chunk_every(args, 2, 1, :discard)
          end

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

    assert %{
             state: "registered",
             session_key: session,
             op_id: op_id,
             message_type: "request",
             message_type_label: "Request"
           } =
             HarklightSend.send_request(db, send_call, runner: runner)

    assert session == call.session_key

    assert {:ok, [[^op_id, ^session, ^handle, "sender", ^request_id, "bound"]]} =
             DB.query(
               db,
               "SELECT opId,sessionKey,handle,senderId,messageId,state FROM harklight_send_operations WHERE opId=?1",
               [op_id]
             )
  end

  test "typed send refusals explain a fix before preparing an operation", %{db: db, call: call} do
    assert {:ok, [[existing_operations]]} =
             DB.query(db, "SELECT count(*) FROM harklight_send_operations")

    valid = %{
      harklight_session: "new",
      sender_id: "sender",
      title: "Question",
      message_type: "request",
      reply: true
    }

    cases = [
      {Map.delete(valid, :message_type), "harklight_type_required", "--type is required"},
      {Map.put(valid, :message_type, "notice"), "harklight_type_invalid", "fyi or request"},
      {
        Map.merge(valid, %{message_type: "fyi", reply: false, choices: ["Ship"]}),
        "harklight_fyi_has_answer_controls",
        "remove --choices-json and --reply"
      },
      {
        Map.merge(valid, %{message_type: "fyi", reply: true}),
        "harklight_fyi_has_answer_controls",
        "remove --choices-json and --reply"
      },
      {Map.put(valid, :reply, false), "harklight_request_needs_answer_controls", "--reply"},
      {Map.put(valid, :message_kind, "update"), "harklight_kind_invalid", "blocker or success"},
      {
        Map.put(valid, :importance, "urgent"),
        "harklight_importance_invalid",
        "low, normal, high, now"
      },
      {Map.put(valid, :stake, "  "), "harklight_stake_invalid", "non-empty text"},
      {Map.put(valid, :by_when, "tomorrow"), "harklight_by_when_invalid", "RFC 3339"}
    ]

    for {params, code, fix} <- cases do
      result =
        HarklightSend.send_request(db, %{call | params: params},
          runner: fn _args -> flunk("invalid message reached the Agent CLI") end
        )

      assert %{outcome: "failed", code: ^code, reason: reason} = result
      assert reason =~ fix
    end

    assert {:ok, [[^existing_operations]]} =
             DB.query(db, "SELECT count(*) FROM harklight_send_operations")
  end

  test "FYI send forwards Seen-only type through the authenticated origin route", %{
    db: db,
    call: call
  } do
    handle = "b6a87513-b91d-4314-849a-cb8d80225864"
    message_id = "seen-notice"

    send_call = %{
      call
      | params: %{
          harklight_session: "new",
          message_type: "fyi",
          reply: false,
          sender_id: "sender",
          title: "Build finished",
          body: "The export is ready."
        }
    }

    runner = fn args ->
      op_id = if "--prepare" in args, do: Enum.at(args, 3), else: List.last(args)

      case Enum.take(args, 2) do
        ["send", "--prepare"] ->
          assert ["--type", "fyi"] in Enum.chunk_every(args, 2, 1, :discard)
          refute "--reply" in args
          refute "--choice" in args
          assert "--controller" in args

          {JSON.encode!(%{
             kind: "prepared",
             op_id: op_id,
             files: [],
             request: %{
               type: "send",
               op_id: op_id,
               session_handle: handle,
               route: "other",
               message: %{
                 sender_id: "sender",
                 message_id: message_id,
                 title: "Build finished",
                 body: "The export is ready."
               }
             }
           }) <> "\n", 0}

        ["send", "--execute"] ->
          assert {:ok, [[session, payload]]} =
                   DB.query(
                     db,
                     "SELECT sessionKey,payload FROM harklight_send_operations WHERE opId=?1",
                     [op_id]
                   )

          assert session == call.session_key
          assert JSON.decode!(payload)["request"]["session_handle"] == handle
          assert JSON.decode!(payload)["request"]["message"]["message_id"] == message_id

          {JSON.encode!(%{
             kind: "committed",
             operation: "send",
             op_id: op_id,
             response: %{
               session_handle: handle,
               sender_id: "sender",
               message_id: message_id,
               revision: 1
             }
           }) <> "\n", 0}
      end
    end

    assert %{
             state: "registered",
             session_key: session,
             handle: ^handle,
             message_id: ^message_id,
             message_type: "fyi",
             message_type_label: "FYI"
           } = HarklightSend.send_request(db, send_call, runner: runner)

    assert session == call.session_key
  end

  test "uncertain result stays unregistered and same-operation retry can bind it", %{
    db: db,
    call: call
  } do
    handle = "ca16c43c-e3b5-4ae8-b9cd-6a8829749697"

    send_call = %{
      call
      | params: %{
          harklight_session: "new",
          message_type: "request",
          reply: true,
          sender_id: "sender",
          title: "Question"
        }
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
      | params: %{
          harklight_session: "new",
          message_type: "request",
          reply: true,
          sender_id: "sender",
          title: "Question"
        }
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
      | params: %{
          harklight_session: "new",
          message_type: "request",
          reply: true,
          sender_id: "sender",
          title: "Question"
        }
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

  for terminal <- ~w(failed failed_unknown canceled), dispatched <- [false, true] do
    @delivery_terminal terminal
    @delivery_dispatched dispatched
    test "discussion #{@delivery_terminal} dispatched=#{@delivery_dispatched} retries unchanged to the same session",
         %{db: db, session: session} do
      line = event(1, "discussion", "keep this exact discussion")
      assert :ok = HarklightWakes.capture_line(db, @handle, line)
      assert {:ok, [[root, prompt]]} = DB.query(db, "SELECT wakeId,prompt FROM wakes")
      assert {:ok, entries} = DB.query(db, "SELECT * FROM harklight_wake_entries")
      assert {:ok, command_results} = DB.query(db, "SELECT * FROM harklight_command_results")
      turn = deliver_discussion_turn!(db, root, session.session_key)

      if @delivery_dispatched do
        {:ok, _} = DB.query(db, "UPDATE turns SET adapterGen=1 WHERE seq=?1", [turn.seq])

        assert :ok =
                 Tightbeam.TurnLifecycle.append(db, turn.seq, %{
                   event_key: "prompt:dispatched",
                   producer_event_id: "request:1",
                   kind: "prompt_dispatched",
                   stage: "prompt",
                   outcome: "dispatched",
                   cause: "acp:port-write",
                   principal: "process:tightbeam",
                   owner_lease: turn.owner_lease,
                   adapter_gen: 1,
                   acp_request_id: 1,
                   detail: %{v: 1}
                 })
      end

      assert :ok =
               Tightbeam.Ledger.finish(db, turn.seq, @delivery_terminal, nil,
                 owner_lease: turn.owner_lease
               )

      assert :already_terminal =
               Tightbeam.Ledger.finish(db, turn.seq, @delivery_terminal, nil,
                 owner_lease: turn.owner_lease
               )

      key = session.session_key

      assert {:ok, [[retry, ^key, ^prompt, "pending", due, ended]]} =
               DB.query(
                 db,
                 """
                 SELECT w.wakeId,w.sessionKey,w.prompt,w.state,w.dueAt,t.endedAt
                 FROM wake_retry_attempts r JOIN wakes w ON w.wakeId=r.retryWakeId
                 JOIN turns t ON t.seq=r.sourceTurnSeq WHERE r.wakeId=?1
                 """,
                 [root]
               )

      assert due >= ended + 30_000

      assert {:ok, source_scope} =
               DB.query(
                 db,
                 "SELECT ownerUserId,sourceVisibilityScope,sourceAddress FROM wakes WHERE wakeId=?1",
                 [root]
               )

      assert {:ok, ^source_scope} =
               DB.query(
                 db,
                 "SELECT ownerUserId,sourceVisibilityScope,sourceAddress FROM wakes WHERE wakeId=?1",
                 [retry]
               )

      refute retry == root
      assert {:ok, ^entries} = DB.query(db, "SELECT * FROM harklight_wake_entries")
      assert {:ok, ^command_results} = DB.query(db, "SELECT * FROM harklight_command_results")
      assert {:ok, [["active"]]} = DB.query(db, "SELECT state FROM harklight_wake_handles")

      recovered = deliver_discussion_turn!(db, retry, key)
      assert recovered.prompt == turn.prompt

      assert :ok =
               Tightbeam.Ledger.finish(db, recovered.seq, "delivered", nil,
                 owner_lease: recovered.owner_lease
               )

      assert {:ok, [["acted", nil]]} =
               DB.query(
                 db,
                 "SELECT outcome,retryWakeId FROM wake_retry_attempts WHERE wakeId=?1",
                 [retry]
               )

      assert {:ok, [["delivered"]]} =
               DB.query(
                 db,
                 "SELECT t.status FROM wakes w JOIN turns t ON t.seq=w.deliveredTurnSeq WHERE w.wakeId=?1",
                 [retry]
               )

      # Normal turn completion is custody receipt, not an ACK on the agent's behalf.
      assert {:ok, ^command_results} = DB.query(db, "SELECT * FROM harklight_command_results")
      assert {:ok, ^entries} = DB.query(db, "SELECT * FROM harklight_wake_entries")
    end
  end

  test "repeated discussion failure keeps backoff and never marks an active session gone", %{
    db: db,
    session: session
  } do
    assert {:ok, command_results} = DB.query(db, "SELECT * FROM harklight_command_results")
    assert :ok = HarklightWakes.capture_line(db, @handle, event(1, "discussion", "pending"))
    assert {:ok, [[root]]} = DB.query(db, "SELECT wakeId FROM wakes")

    Enum.reduce(1..8, root, fn attempt, wake ->
      turn = deliver_discussion_turn!(db, wake, session.session_key)

      assert :ok =
               Tightbeam.Ledger.finish(db, turn.seq, "failed_unknown", nil,
                 owner_lease: turn.owner_lease
               )

      assert {:ok, [[next, ^attempt, "pending", due, ended]]} =
               DB.query(
                 db,
                 """
                 SELECT w.wakeId,r.attempt,w.state,w.dueAt,t.endedAt
                 FROM wake_retry_attempts p JOIN wake_retry_attempts r ON r.wakeId=p.retryWakeId
                 JOIN wakes w ON w.wakeId=r.wakeId JOIN turns t ON t.seq=p.sourceTurnSeq
                 WHERE p.wakeId=?1
                 """,
                 [wake]
               )

      assert due > ended

      assert {:ok, [["active", nil]]} =
               DB.query(db, "SELECT state,lastError FROM harklight_wake_handles")

      next
    end)

    assert {:ok, ^command_results} = DB.query(db, "SELECT * FROM harklight_command_results")
  end

  test "a failed mixed carrier retries only its discussion without losing other health custody",
       %{db: db, session: session} do
    alias Tightbeam.{Gateway, Ledger, NoticeBatcher, Wakes}
    start_supervised!({Tightbeam.ConnRegistry, name: Tightbeam.ConnRegistry})
    start_supervised!({Tightbeam.NoticeBatcherFixture.LaneStub, Tightbeam.LaneManager})

    assert :ok =
             HarklightWakes.capture_line(
               db,
               @handle,
               event(1, "discussion", "retained discussion")
             )

    assert :ok =
             HarklightWakes.capture_line(
               db,
               @handle,
               event(2, "discussion", "second retained discussion")
             )

    assert {:ok, original_sources} =
             DB.query(db, "SELECT wakeId,prompt FROM wakes ORDER BY wakeId")

    Wakes.schedule(db, %{
      session_key: session.session_key,
      origin: "agent:peer",
      prompt: "unrelated notice",
      due_at: 1,
      class: "fyi"
    })

    assert [carrier] = NoticeBatcher.recover(db, System.system_time(:millisecond) + 1)
    assert {:ok, turn} = Ledger.claim_next(db, session.session_key, "discussion-test")
    assert turn.wake_id == carrier
    assert turn.prompt =~ "unrelated notice"
    assert :ok = Ledger.finish(db, turn.seq, "failed", nil, owner_lease: turn.owner_lease)
    expected = Enum.map(original_sources, fn [root, prompt] -> [root, prompt, "pending"] end)

    assert {:ok, ^expected} =
             DB.query(db, """
             SELECT r.rootWakeId,w.prompt,w.state FROM wake_retry_attempts r
             JOIN wakes w ON w.wakeId=r.wakeId WHERE r.attempt=1 ORDER BY r.rootWakeId
             """)

    assert {:ok, :ok} =
             DB.transaction(db, fn txn ->
               Wakes.record_health_redelivery_source_in_txn(txn, turn.seq, "unclassified")
             end)

    # An unrelated successful turn remains the existing health recovery signal.
    assert {:ok, {:appended, _, _, _}} =
             DB.transaction(db, fn txn ->
               Gateway.deliver_prompt_in_txn(
                 txn,
                 session.session_key,
                 "user:owner",
                 "healthy turn"
               )
             end)

    assert {:ok, healthy} = Ledger.claim_next(db, session.session_key, "discussion-test")

    assert :ok =
             Ledger.finish(db, healthy.seq, "delivered", nil, owner_lease: healthy.owner_lease)

    assert {:ok, 1} =
             DB.transaction(db, fn txn ->
               Wakes.redeliver_pending_health_intents_in_txn(txn, session, healthy)
             end)

    assert {:ok, [[prompt]]} =
             DB.query(db, "SELECT prompt FROM turns WHERE sessionKey=?1 AND status='queued'", [
               session.session_key
             ])

    assert prompt == turn.prompt
  end

  test "discussion retry shares the existing prewrite successor and retains its authority", %{
    db: db,
    session: session
  } do
    alias Tightbeam.{Ledger, NoticeAuthority, NoticeSubmission}

    assert :ok =
             HarklightWakes.capture_line(db, @handle, event(1, "discussion", "prewrite retry"))

    assert {:ok, [[root]]} = DB.query(db, "SELECT wakeId FROM harklight_wake_deliveries")
    turn = deliver_discussion_turn!(db, root, session.session_key)

    evidence =
      NoticeSubmission.prewrite_evidence(
        :prompt,
        {:acp_request_not_dispatched, {:transport_capacity_exceeded, 101, 100}}
      )

    assert {:ok, [retry]} =
             DB.transaction(db, fn txn ->
               assert Ledger.finish_in_txn(txn, turn.seq, "failed", nil,
                        owner_lease: turn.owner_lease,
                        prewrite_evidence: evidence
                      )

               NoticeSubmission.restore_in_txn(txn, turn, evidence)
             end)

    seq = turn.seq
    assert %{root_wake_id: ^root, root_turn_seq: ^seq} = NoticeAuthority.resolve!(db, retry)

    assert {:ok, [[1]]} =
             DB.query(db, "SELECT count(*) FROM wakes WHERE wakeId=?1 AND state='pending'", [
               retry
             ])
  end

  test "retirement ends a discussion pending after turn failure through the existing gone path",
       %{db: db, session: session} do
    assert {:ok, command_results} = DB.query(db, "SELECT * FROM harklight_command_results")
    calls = fake_harklight_session_end_agent!()

    listener = fn manager, handle, _ ->
      GenServer.call(manager, {:attached, handle})

      receive do
        :never -> :ok
      end
    end

    start_supervised!({HarklightWakes, db: db, listener: listener})

    assert :ok =
             HarklightWakes.capture_line(
               db,
               @handle,
               event(1, "discussion", "pending retirement")
             )

    assert {:ok, [[root]]} = DB.query(db, "SELECT wakeId FROM harklight_wake_deliveries")
    turn = deliver_discussion_turn!(db, root, session.session_key)

    assert :ok =
             Tightbeam.Ledger.finish(db, turn.seq, "failed_unknown", nil,
               owner_lease: turn.owner_lease
             )

    assert %{state: "retired"} = Org.retire(db, session.session_key, "user:owner", 60_000)

    assert eventually(fn ->
             File.exists?(calls) and
               File.read!(calls) =~ "session end --session #{@handle} --gone"
           end)

    assert {:ok, ^command_results} = DB.query(db, "SELECT * FROM harklight_command_results")
    assert {:ok, [[1]]} = DB.query(db, "SELECT count(*) FROM harklight_wake_entries")
  end

  defp deliver_discussion_turn!(db, wake_id, session_key) do
    assert {:ok, {:appended, ^session_key, _, _}} =
             DB.transaction(db, fn txn ->
               wake = Tightbeam.Wakes.get_in_txn(txn, wake_id)

               Tightbeam.Gateway.deliver_prompt_in_txn(txn, session_key, wake.origin, wake.prompt,
                 wake_id: wake_id,
                 sender: wake.origin,
                 fire_wake_in_txn: true
               )
             end)

    assert {:ok, turn} = Tightbeam.Ledger.claim_next(db, session_key, "discussion-test")
    turn
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
               "SELECT sessionKey,prompt FROM wakes WHERE prompt LIKE 'DISCONNECT: Harklight message%'"
             )

    assert prompt =~ "message request"
    assert prompt =~ "thread #{@handle}"
    assert String.starts_with?(prompt, "DISCONNECT: ")
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

    assert prompt =~ "DISCONNECT:"
    assert prompt =~ "listener lock is held"
    assert prompt =~ "Replies on this thread will not reach"

    assert {:ok, [[1]]} =
             DB.query(db, "SELECT count(*) FROM wakes WHERE wakeId=?1", [
               "w_harklight_notice_recovery_" <> @handle
             ])
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

    assert eventually(fn ->
             DB.query(db, "SELECT state,lastError FROM harklight_wake_handles") ==
               {:ok, [["unavailable", "origin_unavailable"]]}
           end)

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
        {"real refusal gains no transport retry",
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
      # No listener retry, so a failed worker goes straight to gone and only
      # the attachment window is exercised.
      start_supervised!({HarklightWakes, db: db, attach_retry_delays: [20, 40], retry_delays: []})

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

      expected = if @retry_recovered, do: @retry_calls, else: @retry_calls ++ ["session"]
      assert eventually(fn -> File.read!(calls) |> String.split("\n", trim: true) == expected end)
      # Beyond both configured delays, a terminal refusal cannot restart itself.
      Process.sleep(100)
      assert File.read!(calls) |> String.split("\n", trim: true) == expected
    end
  end

  test "an exhausted attachment window is one failure toward the listener budget", %{db: db} do
    calls =
      attachment_sequence(
        List.duplicate(
          {2, ~s({"kind":"refused","reason_source":"agent","reason_code":"transport_error"})},
          4
        )
      )

    start_supervised!({HarklightWakes, db: db, attach_retry_delays: [1], retry_delays: [1]})

    # Two workers, each spending its own window, then gone. Nothing follows.
    expected = ["attach", "attach", "attach", "attach", "session"]
    assert eventually(fn -> File.read!(calls) |> String.split("\n", trim: true) == expected end)
    Process.sleep(100)
    assert File.read!(calls) |> String.split("\n", trim: true) == expected
  end

  test "retry window does not schedule an attempt beyond its deadline", %{db: db} do
    calls =
      attachment_sequence([
        {2, ~s({"kind":"refused","reason_source":"agent","reason_code":"transport_error"})}
      ])

    start_supervised!(
      {HarklightWakes,
       db: db, attach_retry_delays: [100], attach_retry_window_ms: 10, retry_delays: [60_000]}
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
    if [ "$1" = status ]; then exit 1; fi
    if [ "$1" = listen ]; then printf 'listen\\n' >> '#{events}'; exec sleep 300; fi
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
    await_listener_starts(events, 6)

    overlap =
      File.read!(events)
      |> String.split("\n", trim: true)
      |> Enum.reject(&(&1 == "listen"))
      |> Enum.scan(0, fn
        "start", n -> n + 1
        "end", n -> n - 1
      end)

    assert Enum.max(overlap) == 2
    assert length(overlap) == 12

    assert {:ok, [["active", 6]]} =
             DB.query(db, "SELECT state,count(*) FROM harklight_wake_handles GROUP BY state")
  end

  # The manager tracks short attach children as well as standing listeners.
  # Observe the fixture's actual listen start before assessing all attachments.
  defp await_listener_starts(events, count, attempts \\ 300)
  defp await_listener_starts(_events, _count, 0), do: flunk("listeners did not start")

  defp await_listener_starts(events, count, attempts) do
    started =
      File.read!(events) |> String.split("\n", trim: true) |> Enum.count(&(&1 == "listen"))

    if started < count do
      Process.sleep(10)
      await_listener_starts(events, count, attempts - 1)
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
    if [ "$1" = status ]; then exit 1; fi
    root='#{root}'
    if [ "$1" = listen ]; then exec sleep 300; fi
    if [ "$1" = session ]; then printf 'session\n' >> "$root/calls"; exit 0; fi
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
    if [ "$1" = status ]; then exit 1; fi
    printf '%s\\n' "$*" >> "$0.calls"
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

    listen_call = "listen --follow --controller --session #{@handle} --ack2"

    assert eventually(fn ->
             case File.read(script <> ".calls") do
               {:ok, calls} -> calls =~ listen_call
               {:error, :enoent} -> false
               {:error, reason} -> flunk("could not read attachment calls: #{inspect(reason)}")
             end
           end)

    calls = File.read!(script <> ".calls")
    assert calls =~ "attach --session #{@handle}"
    assert calls =~ "--controller --ack2"
    assert calls =~ listen_call

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

  defp handle_failed_with?(db, label) do
    case DB.query(db, "SELECT state,lastError FROM harklight_wake_handles WHERE handle=?1", [
           @handle
         ]) do
      {:ok, [["unavailable", error]]} when is_binary(error) ->
        error == label or String.starts_with?(error, label <> ": ")

      _ ->
        false
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

  test "an attach refusal is sanitized and readable in the owner wake", %{db: db, call: call} do
    fake_harklight_agent!("""
    if [ "$1" = "attach" ]; then
      printf '%s\\n' 'origin refused attachment: token=attach-secret-canary' >&2
      exit 7
    fi
    exit 0
    """)

    assert %{state: "registered"} = HarklightWakes.register(db, call)
    start_supervised!({HarklightWakes, db: db})

    assert eventually(fn ->
             handle_failed_with?(db, "attachment_refused")
           end)

    assert {:ok, [[prompt]]} =
             DB.query(
               db,
               "SELECT prompt FROM wakes WHERE wakeId=?1",
               ["w_harklight_notice_recovery_" <> @handle]
             )

    assert String.starts_with?(prompt, "DISCONNECT: ")
    assert prompt =~ "failure:"
    assert prompt =~ "ATTACH failure:"
    assert prompt =~ "ATTACH initial attempt; exit status: 7"
    assert prompt =~ "origin refused attachment"
    assert prompt =~ "[REDACTED:secret_field]"
    refute prompt =~ "attach-secret-canary"
  end

  test "an exact-operation retry refusal reports each observed stage and status", %{
    db: db,
    call: call
  } do
    fake_harklight_agent!("""
    case "$1" in
      attach)
        printf '%s\\n' '{"kind":"outcome_unknown","op_id":"same-op-canary"}' >&2
        exit 7
        ;;
      retry)
        if [ "$2" != "--op-id" ] || [ "$3" != "same-op-canary" ]; then
          printf '%s\\n' 'unexpected operation id' >&2
          exit 99
        fi
        printf '%s\\n' 'same operation retry refused: token=retry-secret-canary' >&2
        exit 8
        ;;
    esac
    exit 0
    """)

    assert %{state: "registered"} = HarklightWakes.register(db, call)
    start_supervised!({HarklightWakes, db: db})

    assert eventually(fn ->
             handle_failed_with?(db, "attachment_outcome_unknown")
           end)

    assert {:ok, [[prompt]]} =
             DB.query(
               db,
               "SELECT prompt FROM wakes WHERE wakeId=?1",
               ["w_harklight_notice_recovery_" <> @handle]
             )

    assert String.starts_with?(prompt, "DISCONNECT: ")
    assert prompt =~ "message request"
    assert prompt =~ "thread #{@handle}"
    assert prompt =~ "ATTACH initial attempt; exit status: 7"
    assert prompt =~ "ATTACH existing same-operation retry; exit status: 8"
    assert prompt =~ "same operation retry refused"
    assert prompt =~ "[REDACTED:secret_field]"
    refute prompt =~ "retry-secret-canary"
    refute prompt =~ "same-op-canary"
  end

  test "a successful same-operation retry and failed re-attach retain all stage output", %{
    db: db,
    call: call
  } do
    fake_harklight_agent!("""
    case "$1" in
      attach)
        count_file="$0.attach-count"
        if [ -f "$count_file" ]; then
          printf '%s\\n' 'reattach refused: token=reattach-secret-canary' >&2
          exit 12
        fi
        touch "$count_file"
        printf '%s\\n' '{"kind":"outcome_unknown","op_id":"same-op-retained-canary"}' >&2
        printf '%s\\n' 'initial attachment response: token=initial-secret-canary' >&2
        exit 7
        ;;
      retry)
        if [ "$2" != "--op-id" ] || [ "$3" != "same-op-retained-canary" ]; then
          exit 99
        fi
        printf '%s\\n' 'same-operation retry completed: token=retry-secret-canary' >&2
        exit 0
        ;;
    esac
    exit 0
    """)

    assert %{state: "registered"} = HarklightWakes.register(db, call)
    start_supervised!({HarklightWakes, db: db})

    assert eventually(fn ->
             handle_failed_with?(db, "attachment_refused")
           end)

    assert {:ok, [[prompt]]} =
             DB.query(
               db,
               "SELECT prompt FROM wakes WHERE wakeId=?1",
               ["w_harklight_notice_recovery_" <> @handle]
             )

    assert prompt =~ "ATTACH initial attempt; exit status: 7"
    assert prompt =~ "initial attachment response"
    assert prompt =~ "ATTACH existing same-operation retry; exit status: 0"
    assert prompt =~ "same-operation retry completed"
    assert prompt =~ "ATTACH after same-operation retry; exit status: 12"
    assert prompt =~ "reattach refused"
    assert prompt =~ "[REDACTED:secret_field]"
    refute prompt =~ "initial-secret-canary"
    refute prompt =~ "retry-secret-canary"
    refute prompt =~ "reattach-secret-canary"
    refute prompt =~ "same-op-retained-canary"
  end

  test "an unavailable retry subprocess reports an unobserved exit status", %{db: db, call: call} do
    fake_harklight_agent!("""
    if [ "$1" = "attach" ]; then
      printf '%s\\n' '{"kind":"outcome_unknown","op_id":"missing-retry-canary"}' >&2
      rm "$0"
      exit 7
    fi
    exit 0
    """)

    assert %{state: "registered"} = HarklightWakes.register(db, call)
    start_supervised!({HarklightWakes, db: db})

    assert eventually(fn ->
             handle_failed_with?(db, "attachment_cli_failed")
           end)

    assert {:ok, [[prompt]]} =
             DB.query(
               db,
               "SELECT prompt FROM wakes WHERE wakeId=?1",
               ["w_harklight_notice_recovery_" <> @handle]
             )

    assert prompt =~ "ATTACH existing same-operation retry; exit status: unknown (not observed)"
  end

  test "structured refusal output keeps only its safe reason field" do
    refusal =
      JSON.encode!(%{
        kind: "unsupported",
        reason: "route unavailable token=structured-secret-canary",
        payload: "structured-payload-canary"
      })

    assert "route unavailable token=[REDACTED:secret_field]" ==
             HarklightWakes.sanitize_refusal_output(refusal)

    assert is_nil(
             HarklightWakes.sanitize_refusal_output(
               JSON.encode!(%{kind: "event", entry: %{content: "event-payload-canary"}})
             )
           )
  end

  test "invalid bytes in refusal output do not change its failure classification", %{
    db: db,
    call: call
  } do
    attached = JSON.encode!(%{kind: "attached", ready_for_listen: true})

    fake_harklight_agent!("""
    if [ "$1" = "attach" ]; then
      printf '%s\\n' '#{attached}'
      exit 0
    fi

    if [ "$1" = "listen" ]; then
      printf 'origin refused \\377 token=invalid-byte-secret-canary\\n' >&2
      exit 17
    fi
    exit 0
    """)

    assert %{state: "registered"} = HarklightWakes.register(db, call)
    start_supervised!({HarklightWakes, db: db})

    assert eventually(fn ->
             handle_failed_with?(db, "listener_stopped")
           end)

    assert {:ok, [[prompt]]} =
             DB.query(
               db,
               "SELECT prompt FROM wakes WHERE wakeId=?1",
               ["w_harklight_notice_recovery_" <> @handle]
             )

    assert String.valid?(prompt)
    assert prompt =~ "LISTEN attempt; exit status: 17"
    assert prompt =~ "origin refused"
    assert prompt =~ "[REDACTED:secret_field]"
    refute prompt =~ "invalid-byte-secret-canary"
  end

  test "listen stderr is reported without exposing captured event payloads", %{db: db, call: call} do
    attached = JSON.encode!(%{kind: "attached", ready_for_listen: true})
    event_line = event(1, "discussion", "listen-payload-canary")

    fake_harklight_agent!("""
    if [ "$1" = "attach" ]; then
      printf '%s\\n' '#{attached}'
      exit 0
    fi

    if [ "$1" = "listen" ]; then
      printf '%s\\n' 'origin stream refused: token=listen-secret-canary' >&2
      printf '%s\\n' '#{event_line}'
      exit 9
    fi
    exit 0
    """)

    assert %{state: "registered"} = HarklightWakes.register(db, call)
    start_supervised!({HarklightWakes, db: db})

    assert eventually(fn ->
             handle_failed_with?(db, "listener_stopped")
           end)

    assert {:ok, [[prompt]]} =
             DB.query(
               db,
               "SELECT prompt FROM wakes WHERE wakeId=?1",
               ["w_harklight_notice_recovery_" <> @handle]
             )

    assert {:ok, [[1]]} =
             DB.query(db, "SELECT count(*) FROM harklight_wake_entries WHERE handle=?1", [
               @handle
             ])

    assert prompt =~ "failure:"
    assert prompt =~ "LISTEN failure:"
    assert prompt =~ "LISTEN attempt; exit status: 9"
    assert prompt =~ "origin stream refused"
    assert prompt =~ "[REDACTED:secret_field]"
    refute prompt =~ "listen-secret-canary"
    refute prompt =~ "listen-payload-canary"
  end

  test "a final unterminated listen refusal remains in the failure details", %{
    db: db,
    call: call
  } do
    attached = JSON.encode!(%{kind: "attached", ready_for_listen: true})

    fake_harklight_agent!("""
    if [ "$1" = "attach" ]; then
      printf '%s\\n' '#{attached}'
      exit 0
    fi

    if [ "$1" = "listen" ]; then
      printf '%s\\n' 'https://diagnostic.example/path Harklight origin stream unavailable; retrying after disconnect: prior cursor was accepted but no next event followed because the origin stream remained closed' >&2
      printf '%s\\n' 'Harklight origin stream unavailable; retrying after disconnect: message=the original event remains unavailable while the source continues trying to reconnect' >&2
      printf '%s' 'final refusal token=unterminated-secret-canary' >&2
      exit 19
    fi
    exit 0
    """)

    assert %{state: "registered"} = HarklightWakes.register(db, call)

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        start_supervised!({HarklightWakes, db: db})

        assert eventually(fn ->
                 handle_failed_with?(db, "listener_stopped")
               end)
      end)

    assert {:ok, [[prompt]]} =
             DB.query(
               db,
               "SELECT prompt FROM wakes WHERE wakeId=?1",
               ["w_harklight_notice_recovery_" <> @handle]
             )

    assert prompt =~ "LISTEN attempt; exit status: 19"
    assert prompt =~ "Harklight origin stream unavailable; retrying after disconnect"
    assert prompt =~ "[REDACTED:url]"
    assert prompt =~ "message=[REDACTED:content]"
    assert prompt =~ "final refusal"
    assert prompt =~ "[REDACTED:secret_field]"
    refute prompt =~ "unterminated-secret-canary"
    assert log =~ "final refusal"
    assert log =~ "[REDACTED:url]"
    assert log =~ "message=[REDACTED:content]"
    refute log =~ "unterminated-secret-canary"
  end

  test "invalid bytes in a structured event preserve the listener parse failure", %{
    db: db,
    call: call
  } do
    attached = JSON.encode!(%{kind: "attached", ready_for_listen: true})
    event_line = event(1, "discussion", "invalid-byte-event-canary")

    event_line =
      :binary.replace(
        event_line,
        "invalid-byte-event-canary",
        "bad" <> <<255>> <> "event-payload"
      )

    printf_format =
      event_line
      |> :binary.bin_to_list()
      |> Enum.map_join(fn byte -> "\\" <> Integer.to_string(byte, 8) end)

    fake_harklight_agent!("""
    if [ "$1" = "attach" ]; then
      printf '%s\\n' '#{attached}'
      exit 0
    fi

    if [ "$1" = "listen" ]; then
      printf '#{printf_format}\\n'
      exit 0
    fi
    exit 0
    """)

    assert %{state: "registered"} = HarklightWakes.register(db, call)
    start_supervised!({HarklightWakes, db: db})

    assert eventually(fn ->
             handle_failed_with?(db, "invalid_listener_line")
           end)

    assert {:ok, [[0]]} =
             DB.query(db, "SELECT count(*) FROM harklight_wake_entries WHERE handle=?1", [
               @handle
             ])

    assert {:ok, [[prompt]]} =
             DB.query(
               db,
               "SELECT prompt FROM wakes WHERE wakeId=?1",
               ["w_harklight_notice_recovery_" <> @handle]
             )

    refute prompt =~ "invalid-byte-event-canary"
    refute prompt =~ "event-payload"
  end

  test "a failed attempt on an unavailable handle is logged without another owner wake", %{
    db: db,
    call: call
  } do
    assert %{state: "registered"} = HarklightWakes.register(db, call)
    test_pid = self()

    initial_listener = fn manager, handle, _vendor_id ->
      :ok = GenServer.call(manager, {:attached, handle})
      :ok = GenServer.call(manager, {:finished, handle, "listener_stopped"})
      send(test_pid, :initial_failure_recorded)
    end

    start_supervised!({HarklightWakes, db: db, listener: initial_listener})
    assert_receive :initial_failure_recorded

    assert {:ok, [[1]]} =
             DB.query(
               db,
               "SELECT count(*) FROM wakes WHERE wakeId=?1",
               ["w_harklight_notice_recovery_" <> @handle]
             )

    stop_supervised!(HarklightWakes)

    retry_listener = fn manager, handle, _vendor_id ->
      :ok =
        GenServer.call(
          manager,
          {
            :finished,
            handle,
            {:harklight_failure, "listener_stopped", "listen",
             "LISTEN restore attempt; exit status: 23; sanitized output: retry refused token=repeat-secret-canary"}
          },
          :infinity
        )

      send(test_pid, :restored_failure_recorded)
    end

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        start_supervised!({HarklightWakes, db: db, listener: retry_listener})
        assert_receive :restored_failure_recorded, 2_000
        Process.sleep(20)
      end)

    assert log =~ "Harklight listener failure"
    assert log =~ "LISTEN restore attempt; exit status: 23"
    assert log =~ "retry refused"
    assert log =~ "[REDACTED:secret_field]"
    refute log =~ "repeat-secret-canary"

    assert {:ok, [["unavailable", error]]} =
             DB.query(db, "SELECT state,lastError FROM harklight_wake_handles WHERE handle=?1", [
               @handle
             ])

    assert error =~ "listener_stopped: LISTEN restore attempt; exit status: 23"
    assert error =~ "retry refused"
    refute error =~ "repeat-secret-canary"

    assert {:ok, [[1]]} =
             DB.query(
               db,
               "SELECT count(*) FROM wakes WHERE wakeId=?1",
               ["w_harklight_notice_recovery_" <> @handle]
             )
  end

  test "an unavailable listen Port reports an unobserved exit status", %{db: db, call: call} do
    attached = JSON.encode!(%{kind: "attached", ready_for_listen: true})

    fake_harklight_agent!("""
    if [ "$1" = "attach" ]; then
      printf '%s\\n' '#{attached}'
      rm "$0"
      exit 0
    fi
    exit 0
    """)

    assert %{state: "registered"} = HarklightWakes.register(db, call)
    start_supervised!({HarklightWakes, db: db})

    assert eventually(fn ->
             handle_failed_with?(db, "listener_failed")
           end)

    assert {:ok, [[prompt]]} =
             DB.query(
               db,
               "SELECT prompt FROM wakes WHERE wakeId=?1",
               ["w_harklight_notice_recovery_" <> @handle]
             )

    assert prompt =~
             "LISTEN attempt (Port unavailable or receive failed); exit status: unknown (not observed)"
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

  test "deliberate retirement marks a handle gone when no receiver remains", %{
    db: db,
    session: session
  } do
    calls = fake_harklight_session_end_agent!()
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

    retired = Org.retire(db, session.session_key, "user:owner", 60_000)
    assert retired.state == "retired"
    :sys.get_state(HarklightWakes)

    assert eventually(fn ->
             File.read(calls) == {:ok, "session end --session #{@handle} --gone\n"}
           end)

    assert {:ok, [["unavailable", "origin_unavailable"]]} =
             DB.query(db, "SELECT state,lastError FROM harklight_wake_handles WHERE handle=?1", [
               @handle
             ])

    refute Process.alive?(worker)
  end

  test "an ephemeral last actual follow receiver retires after the origin", %{
    db: db,
    call: call,
    main: main,
    session: session
  } do
    calls = fake_harklight_session_end_agent!()
    follower = follower_session(db, main, "agent:follower:retirement")

    assert {:ok, _} =
             DB.transaction(
               db,
               &Ephemeral.stamp_in_txn(&1, follower.session_key, main.session_key)
             )

    assert %{outcome: "committed"} =
             follow_for_test(
               db,
               follow_call(call, follower, %{message_id: "request"}),
               runner: lifecycle_runner(db)
             )

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

    retired = Org.retire(db, session.session_key, "user:owner", 60_000)
    assert retired.state == "retired"
    :sys.get_state(HarklightWakes)

    assert Process.alive?(worker)

    assert :ok =
             HarklightWakes.capture_line(db, @handle, event(1, "discussion", "After retirement"))

    assert {:ok, [[1]]} =
             DB.query(db, "SELECT count(*) FROM wakes WHERE sessionKey=?1", [follower.session_key])

    refute File.exists?(calls)

    assert {:ok, :ok} =
             DB.transaction(db, &Ephemeral.retire_in_txn(&1, follower.session_key))

    assert Org.get(db, follower.session_key).state == "retired"

    assert {:ok, [["retired", "open"]]} =
             DB.query(
               db,
               """
               SELECT s.state,f.state
               FROM sessions s JOIN harklight_wake_follows f ON f.sessionKey=s.sessionKey
               WHERE f.handle=?1 AND f.sessionKey=?2
               """,
               [@handle, follower.session_key]
             )

    :sys.get_state(HarklightWakes)

    assert eventually(fn ->
             File.read(calls) == {:ok, "session end --session #{@handle} --gone\n"}
           end)

    assert {:ok, [["unavailable", "origin_unavailable"]]} =
             DB.query(db, "SELECT state,lastError FROM harklight_wake_handles WHERE handle=?1", [
               @handle
             ])

    assert eventually(fn -> not Process.alive?(worker) end)
  end

  test "queued retirement handoffs mark gone once for the last actual receiver", %{
    db: db,
    call: call,
    main: main,
    session: session
  } do
    calls = fake_harklight_session_end_agent!()
    follower = follower_session(db, main, "agent:follower:queued-retirement")

    assert %{outcome: "committed"} =
             follow_for_test(
               db,
               follow_call(call, follower, %{message_id: "request"}),
               runner: lifecycle_runner(db)
             )

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

    :sys.suspend(HarklightWakes)

    try do
      assert %{state: "retired"} = Org.retire(db, session.session_key, "user:owner", 60_000)
      assert %{state: "retired"} = Org.retire(db, follower.session_key, "user:owner", 60_000)
    after
      :sys.resume(HarklightWakes)
    end

    :sys.get_state(HarklightWakes)

    assert {:ok, [["retired", "open"]]} =
             DB.query(
               db,
               """
               SELECT s.state,f.state
               FROM sessions s JOIN harklight_wake_follows f ON f.sessionKey=s.sessionKey
               WHERE f.handle=?1 AND f.sessionKey=?2
               """,
               [@handle, follower.session_key]
             )

    assert eventually(fn ->
             File.read(calls) == {:ok, "session end --session #{@handle} --gone\n"}
           end)

    Process.sleep(50)
    assert File.read(calls) == {:ok, "session end --session #{@handle} --gone\n"}
    assert eventually(fn -> not Process.alive?(worker) end)
  end

  test "a live origin remains eligible after its follower retires", %{
    db: db,
    call: call,
    main: main,
    session: session
  } do
    calls = fake_harklight_session_end_agent!()
    follower = follower_session(db, main, "agent:follower:origin-live")

    assert %{outcome: "committed"} =
             follow_for_test(
               db,
               follow_call(call, follower, %{message_id: "request"}),
               runner: lifecycle_runner(db)
             )

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

    retired_follower = Org.retire(db, follower.session_key, "user:owner", 60_000)
    assert retired_follower.state == "retired"
    :sys.get_state(HarklightWakes)

    assert Process.alive?(worker)

    assert {:ok, [["active", "retired", "open"]]} =
             DB.query(
               db,
               """
               SELECT h.state,s.state,f.state
               FROM harklight_wake_handles h
               JOIN harklight_wake_follows f ON f.handle=h.handle
               JOIN sessions s ON s.sessionKey=f.sessionKey
               WHERE h.handle=?1 AND f.sessionKey=?2
               """,
               [@handle, follower.session_key]
             )

    refute File.exists?(calls)

    retired_origin = Org.retire(db, session.session_key, "user:owner", 60_000)
    assert retired_origin.state == "retired"
    :sys.get_state(HarklightWakes)

    assert eventually(fn ->
             File.read(calls) == {:ok, "session end --session #{@handle} --gone\n"}
           end)

    assert eventually(fn -> not Process.alive?(worker) end)
  end

  test "another active follow receiver keeps a retired origin not-gone", %{
    db: db,
    call: call,
    main: main,
    session: session
  } do
    calls = fake_harklight_session_end_agent!()
    first_follower = follower_session(db, main, "agent:follower:first")
    last_follower = follower_session(db, main, "agent:follower:last")

    for follower <- [first_follower, last_follower] do
      assert %{outcome: "committed"} =
               follow_for_test(
                 db,
                 follow_call(call, follower, %{message_id: "request"}),
                 runner: lifecycle_runner(db)
               )
    end

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

    retired_origin = Org.retire(db, session.session_key, "user:owner", 60_000)
    assert retired_origin.state == "retired"
    :sys.get_state(HarklightWakes)
    assert Process.alive?(worker)
    refute File.exists?(calls)

    retired_first = Org.retire(db, first_follower.session_key, "user:owner", 60_000)
    assert retired_first.state == "retired"
    :sys.get_state(HarklightWakes)
    assert Process.alive?(worker)

    assert {:ok, [["retired", "open"], ["active", "open"]]} =
             DB.query(
               db,
               """
               SELECT s.state,f.state
               FROM sessions s JOIN harklight_wake_follows f ON f.sessionKey=s.sessionKey
               WHERE f.handle=?1 ORDER BY f.sessionKey
               """,
               [@handle]
             )

    refute File.exists?(calls)

    retired_last = Org.retire(db, last_follower.session_key, "user:owner", 60_000)
    assert retired_last.state == "retired"
    :sys.get_state(HarklightWakes)

    assert eventually(fn ->
             File.read(calls) == {:ok, "session end --session #{@handle} --gone\n"}
           end)

    assert eventually(fn -> not Process.alive?(worker) end)
  end

  test "a first transient attach failure waits for recovery before marking gone", %{db: db} do
    calls = fake_harklight_session_end_agent!()
    start_supervised!({HarklightWakes, db: db})

    assert eventually(fn ->
             match?(
               {:ok, [["unavailable", _]]},
               DB.query(
                 db,
                 "SELECT state,lastError FROM harklight_wake_handles WHERE handle=?1",
                 [
                   @handle
                 ]
               )
             )
           end)

    output = File.read!(calls)
    assert output =~ "attach --session #{@handle}"
    refute output =~ "session end"
  end

  # Controller-side classification coverage. These are synthetic responses;
  # released Agent path reproduction and Server behavior require separate evidence.
  for {codes, attempts} <- [
        {~w(missing_journal unproven_handle invalid_handle invalid_attachment
          invalid_attachment_receipt support_mismatch configuration_error not_found
          forbidden operation_conflict invalid_field unsupported_version feed_gap feed_conflict
          invalid_notice invalid_response), 1},
        {~w(listener_active already_listening journal_error local_io timeout transport_error
          stream_ended stream_io storage_unavailable unknown), 2}
      ],
      code <- codes do
    @refusal_code code
    @refusal_attempts attempts
    test "observed #{@refusal_code} reaches gone after #{@refusal_attempts} bounded attempts", %{
      db: db
    } do
      path = Path.join(System.tmp_dir!(), "refusal-calls-#{System.unique_integer([:positive])}")
      File.write!(path, "")
      on_exit(fn -> File.rm(path) end)

      frame =
        JSON.encode!(%{
          kind: "refused",
          reason_code: @refusal_code,
          reason: "synthetic classified refusal",
          stage: "journal",
          reason_source: "agent"
        })

      fake_harklight_agent!("""
      printf '%s\n' "$*" >> '#{path}'
      if [ "$1" = attach ]; then
        printf '%s\n' '#{frame}'
        exit 2
      fi
      exit 0
      """)

      # This measures the listener budget alone; transport codes would also
      # spend the attachment retry window first.
      start_supervised!({HarklightWakes, db: db, retry_delays: [1], attach_retry_delays: []})
      assert eventually(fn -> File.read!(path) =~ "session end --session #{@handle} --gone" end)
      calls = File.read!(path) |> String.split("\n", trim: true)
      assert Enum.count(calls, &String.starts_with?(&1, "attach ")) == @refusal_attempts

      assert Enum.all?(
               calls,
               &(String.starts_with?(&1, "attach ") or
                   &1 == "session end --session #{@handle} --gone")
             )

      assert {:ok, [[error]]} = DB.query(db, "SELECT lastError FROM harklight_wake_handles")
      assert error =~ "reason_code=#{@refusal_code}"
    end
  end

  test "successful quiet reattachments reset the consecutive failure budget", %{db: db} do
    calls = fake_harklight_session_end_agent!()
    test_pid = self()

    listener = fn manager, handle, _vendor_id ->
      send(test_pid, {:listener_started, self()})

      receive do
        :attach ->
          :ok = GenServer.call(manager, {:attached, handle})
          send(test_pid, {:listener_attached, self()})
          receive do: (:drop -> :ok)

        :fail ->
          :ok = GenServer.call(manager, {:finished, handle, "listener_terminated"})
      end
    end

    start_supervised!({HarklightWakes, db: db, listener: listener, retry_delays: [1, 1]})

    for _ <- 1..7 do
      assert_receive {:listener_started, worker}, 1_000
      send(worker, :attach)
      assert_receive {:listener_attached, ^worker}, 1_000
      refute File.exists?(calls)
      send(worker, :drop)
    end

    # No captured event replenished the budget. After the final drop, its
    # recovery attempt and one further retry can fail before reaching gone.
    assert {:ok, [[0]]} = DB.query(db, "SELECT count(*) FROM harklight_wake_entries")

    for _ <- 1..2 do
      assert_receive {:listener_started, worker}, 1_000
      send(worker, :fail)
    end

    assert eventually(fn ->
             File.read(calls) == {:ok, "session end --session #{@handle} --gone\n"}
           end)
  end

  test "a releasing listener lock retries once then completes without gone", %{db: db} do
    path = Path.join(System.tmp_dir!(), "releasing-lock-#{System.unique_integer([:positive])}")
    File.write!(path, "")

    on_exit(fn ->
      File.rm(path)
      File.rm(path <> ".attempted")
    end)

    fake_harklight_agent!("""
    printf '%s\n' "$*" >> '#{path}'
    if [ "$1" = attach ]; then
      if [ ! -e '#{path}.attempted' ]; then
        touch '#{path}.attempted'
        printf '%s\n' '{"kind":"connection_error","reason_code":"listener_active","reason":"The existing local listener lock is held."}'
        exit 1
      fi
      printf '%s\n' '{"kind":"attached","ready_for_listen":true}'
    elif [ "$1" = listen ]; then
      printf '%s\n' '{"kind":"idle","open_requests":0}'
    fi
    """)

    start_supervised!({HarklightWakes, db: db, retry_delays: [1]})

    assert eventually(fn ->
             DB.query(db, "SELECT state FROM harklight_wake_handles") == {:ok, [["complete"]]}
           end)

    calls = File.read!(path) |> String.split("\n", trim: true)
    assert Enum.count(calls, &String.starts_with?(&1, "attach ")) == 2
    assert Enum.count(calls, &String.starts_with?(&1, "listen ")) == 1
    refute Enum.any?(calls, &String.starts_with?(&1, "session end"))
  end

  test "an ineligible local origin is gone and later eligibility can attach again", %{
    db: db,
    session: session
  } do
    calls = fake_harklight_session_end_agent!()
    Org.set_host(db, session.session_key, "other-host")
    parent = self()

    listener = fn manager, handle, _ ->
      :ok = GenServer.call(manager, {:attached, handle})
      send(parent, :reattached)

      receive do
        :never -> :ok
      end
    end

    start_supervised!({HarklightWakes, db: db, listener: listener})

    assert eventually(fn ->
             File.exists?(calls) and
               File.read!(calls) =~ "session end --session #{@handle} --gone"
           end)

    refute_receive :reattached, 30
    Org.set_host(db, session.session_key, Placement.local_host_name())
    assert_receive :reattached

    assert {:ok, [["active", nil]]} =
             DB.query(db, "SELECT state,lastError FROM harklight_wake_handles")
  end

  test "recovery retry skips a now-closed handle without a gone command", %{db: db} do
    calls = fake_harklight_session_end_agent!()
    parent = self()
    {:ok, closed} = Agent.start_link(fn -> false end)

    runner = fn ["status", "--session", @handle] ->
      is_closed = Agent.get(closed, & &1)
      send(parent, {:checked_closed, is_closed})

      {JSON.encode!(%{
         "session_handle" => @handle,
         "open_requests" => if(is_closed, do: 0, else: 1),
         "pending_undelivered" => 0
       }), 0}
    end

    listener = fn manager, handle, _ ->
      :ok = GenServer.call(manager, {:attached, handle})
      Agent.update(closed, fn _ -> true end)
      :ok = GenServer.call(manager, {:finished, handle, "listener_stopped"})
      send(parent, :first_failed)
    end

    manager =
      start_supervised!(
        {HarklightWakes, db: db, listener: listener, send_runner: runner, retry_delays: [1]}
      )

    assert_receive :first_failed
    assert_receive {:checked_closed, true}
    assert eventually(fn -> :sys.get_state(manager).workers == %{} end)
    state = :sys.get_state(manager)
    assert state.workers == %{}
    assert state.retry_timers == %{}
    assert state.gone_tasks == %{}

    assert {:ok, [["unavailable", "listener_stopped"]]} =
             DB.query(db, "SELECT state,lastError FROM harklight_wake_handles WHERE handle=?1", [
               @handle
             ])

    refute File.exists?(calls)
  end

  test "deferred existing starts skip while deferred new-request starts remain ungated", %{
    db: db,
    session: session
  } do
    calls = fake_harklight_session_end_agent!(0, wait_for_session_end: true)
    parent = self()
    {:ok, closed} = Agent.start_link(fn -> false end)

    runner = fn ["status", "--session", @handle] ->
      is_closed = Agent.get(closed, & &1)

      {JSON.encode!(%{
         "session_handle" => @handle,
         "open_requests" => if(is_closed, do: 0, else: 1),
         "pending_undelivered" => 0
       }), 0}
    end

    listener = fn manager, handle, _ ->
      send(parent, :started_deferred_test)
      :ok = GenServer.call(manager, {:finished, handle, "invalid_listener_line"})
    end

    manager =
      start_supervised!(
        {HarklightWakes, db: db, listener: listener, send_runner: runner, retry_delays: []}
      )

    assert_receive :started_deferred_test
    assert eventually(fn -> File.exists?(calls) end)
    Agent.update(closed, fn _ -> true end)
    HarklightWakes.origin_ready(session.session_key)
    assert MapSet.member?(:sys.get_state(manager).deferred, @handle)
    File.write!(calls <> ".release", "continue")
    assert eventually(fn -> :sys.get_state(manager).gone_tasks == %{} end)
    refute_receive :started_deferred_test

    # Trigger a fresh failure/gone cycle, then activate during its outstanding gone.
    File.rm!(calls <> ".release")
    HarklightWakes.activate(@handle)
    assert_receive :started_deferred_test
    assert eventually(fn -> map_size(:sys.get_state(manager).gone_tasks) == 1 end)
    HarklightWakes.activate(@handle)
    assert MapSet.member?(:sys.get_state(manager).deferred, @handle)
    File.write!(calls <> ".release", "continue")
    assert_receive :started_deferred_test
  end

  test "ordinary worker death restores the same handle after DOWN", %{db: db} do
    test_pid = self()

    listener = fn manager, handle, vendor ->
      :ok = GenServer.call(manager, {:attached, handle})
      send(test_pid, {:started, self(), handle, vendor})

      receive do
        :fail -> :ok
      end
    end

    start_supervised!({HarklightWakes, db: db, listener: listener, retry_delays: [1]})
    assert_receive {:started, old, @handle, vendor}
    ref = Process.monitor(old)
    send(old, :fail)
    assert_receive {:DOWN, ^ref, :process, ^old, :normal}
    assert_receive {:started, new, @handle, ^vendor}
    refute new == old

    assert {:ok, [["active", nil]]} =
             DB.query(db, "SELECT state,lastError FROM harklight_wake_handles WHERE handle=?1", [
               @handle
             ])
  end

  test "retry exhaustion marks gone and serializes later activation", %{db: db} do
    calls = fake_harklight_session_end_agent!(0, wait_for_session_end: true)
    test_pid = self()

    listener = fn manager, handle, _vendor ->
      send(test_pid, :attempt)
      GenServer.call(manager, {:finished, handle, "listener_stopped"})
    end

    start_supervised!({HarklightWakes, db: db, listener: listener, retry_delays: [1]})
    assert_receive :attempt
    assert_receive :attempt

    assert eventually(fn ->
             File.exists?(calls) and
               File.read!(calls) =~ "session end --session #{@handle} --gone"
           end)

    HarklightWakes.activate(@handle)
    refute_receive :attempt, 30
    File.write!(calls <> ".release", "continue")
    assert_receive :attempt
  end

  test "an irrecoverable structured refusal marks gone without another listener", %{db: db} do
    calls = fake_harklight_session_end_agent!()
    test_pid = self()

    listener = fn manager, handle, _vendor ->
      send(test_pid, :attempt)

      GenServer.call(
        manager,
        {:finished, handle,
         {:harklight_failure, {"attachment_refused", "missing_journal"}, "attach",
          "missing journal"}}
      )
    end

    start_supervised!({HarklightWakes, db: db, listener: listener, retry_delays: [1]})
    assert_receive :attempt

    assert eventually(fn ->
             File.exists?(calls) and
               File.read!(calls) =~ "session end --session #{@handle} --gone"
           end)

    refute_receive :attempt, 30

    assert {:ok, [[error]]} =
             DB.query(db, "SELECT lastError FROM harklight_wake_handles WHERE handle=?1", [
               @handle
             ])

    assert error =~ "reason_code=missing_journal"
  end

  test "a failed gone command leaves retirement nonblocking", %{db: db, session: session} do
    calls = fake_harklight_session_end_agent!(17, wait_for_session_end: true)
    test_pid = self()

    listener = fn manager, handle, _vendor_id ->
      :ok = GenServer.call(manager, {:attached, handle})
      send(test_pid, {:listener_running, self()})

      receive do
        :never -> :ok
      end
    end

    start_supervised!({HarklightWakes, db: db, listener: listener})
    assert_receive {:listener_running, _worker}

    retired = Org.retire(db, session.session_key, "user:owner", 60_000)
    assert retired.state == "retired"
    :sys.get_state(HarklightWakes)

    assert eventually(fn ->
             File.read(calls) == {:ok, "session end --session #{@handle} --gone\n"}
           end)

    assert {:ok, [["unavailable"]]} =
             DB.query(db, "SELECT state FROM harklight_wake_handles WHERE handle=?1", [@handle])

    File.write!(calls <> ".release", "continue")

    assert eventually(fn -> File.read(calls <> ".exit-status") == {:ok, "17\n"} end)
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
          message_type: "request",
          reply: true,
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

  test "committed sends pass contradiction matches through with camelCase member names", %{
    db: db,
    call: call
  } do
    warning =
      "these possibly contradictory messages are still active, please talk to its poster to reconcile them"

    contradictions = %{
      "status" => "complete",
      "unchecked" => 0,
      "warning" => warning,
      "messages" => [
        %{
          "sender_id" => "sender-a",
          "sender_name" => "Agent A",
          "message_id" => "open-a",
          "title" => "First open request"
        },
        %{
          "sender_id" => "sender-b",
          "sender_name" => "Agent B",
          "message_id" => "open-b",
          "title" => "Second open request"
        }
      ]
    }

    send_call = %{
      call
      | params: %{
          harklight_session: @handle,
          message_type: "request",
          reply: true,
          sender_id: "sender",
          title: "Replacement"
        }
    }

    result =
      HarklightSend.send_request(db, send_call,
        runner: lifecycle_runner(db, possible_contradictions: contradictions)
      )

    assert result.outcome == "committed"
    assert result.wake_effect == "subscribed"

    assert result.possible_contradictions == %{
             "status" => "complete",
             "unchecked" => 0,
             "warning" => warning,
             "messages" => [
               %{
                 "senderId" => "sender-a",
                 "senderName" => "Agent A",
                 "messageId" => "open-a",
                 "title" => "First open request"
               },
               %{
                 "senderId" => "sender-b",
                 "senderName" => "Agent B",
                 "messageId" => "open-b",
                 "title" => "Second open request"
               }
             ]
           }
  end

  test "committed incomplete result is carried without warning or messages", %{db: db, call: call} do
    contradictions = %{
      "status" => "incomplete",
      "reason" => "unavailable",
      "unchecked" => 3
    }

    send_call = %{
      call
      | params: %{
          harklight_session: @handle,
          message_type: "request",
          reply: true,
          sender_id: "sender",
          title: "Replacement"
        }
    }

    result =
      HarklightSend.send_request(db, send_call,
        runner: lifecycle_runner(db, possible_contradictions: contradictions)
      )

    assert result.outcome == "committed"
    assert result.wake_effect == "subscribed"
    assert result.possible_contradictions == contradictions
  end

  test "send without the server field retains the ordinary committed result", %{
    db: db,
    call: call
  } do
    send_call = %{
      call
      | params: %{
          harklight_session: @handle,
          message_type: "request",
          reply: true,
          sender_id: "sender",
          title: "Replacement"
        }
    }

    result = HarklightSend.send_request(db, send_call, runner: lifecycle_runner(db))

    assert result.outcome == "committed"
    assert result.wake_effect == "subscribed"
    refute Map.has_key?(result, :possible_contradictions)
  end

  test "superseding sends carry the contradiction field without changing supersede results", %{
    db: db,
    call: call
  } do
    contradictions = %{
      "status" => "incomplete",
      "reason" => "unavailable",
      "unchecked" => 1
    }

    send_call = %{
      call
      | params: %{
          harklight_session: @handle,
          message_type: "request",
          reply: true,
          sender_id: "sender",
          title: "Replacement",
          supersedes: ["request"]
        }
    }

    result =
      HarklightSend.send_request(db, send_call,
        runner: lifecycle_runner(db, possible_contradictions: contradictions)
      )

    assert result.outcome == "committed"
    assert result.wake_effect == "subscribed"
    assert result.possible_contradictions == contradictions
    assert [%{message_id: "request", effect: "ended"}] = result.supersedes
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
              message_type: "request",
              reply: true,
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
          message_type: "request",
          reply: true,
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
          | params: %{
              harklight_session: @handle,
              message_type: "request",
              reply: true,
              sender_id: "sender",
              title: "Replacement"
            }
        },
        runner: runner
      )

    assert %{outcome: "refused", message_id: "replacement", wake_effect: "none", reason: reason} =
             result

    assert reason == "not accepted"

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
                     message_type: "request",
                     reply: true,
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

  test "due scan preserves legacy owner and follower eligibility", %{
    db: db,
    call: call,
    main: main
  } do
    follower = follower_session(db, main, "agent:follower:due")

    assert %{outcome: "committed"} =
             follow_for_test(
               db,
               follow_call(call, follower, %{message_id: "request"}),
               runner: lifecycle_runner(db)
             )

    for cursor <- 1..2 do
      assert :ok =
               HarklightWakes.capture_line(db, @handle, event(cursor, "discussion", "captured"))
    end

    # Include both a historical owner wake without a delivery row and the
    # current owner/follower form in the same production due query.
    assert {:ok, _} =
             DB.query(
               db,
               "DELETE FROM harklight_wake_deliveries WHERE handle=?1 AND eventId='1' AND sessionKey=?2",
               [@handle, call.session_key]
             )

    assert {:ok, _} =
             DB.query(
               db,
               "UPDATE wakes SET dueAt=0,deliveryRule='turn-boundary-digest r1'"
             )

    assert {:ok, captured} = DB.query(db, "SELECT wakeId,sessionKey FROM wakes")
    assert length(captured) == 4
    host = Placement.local_host_name()

    for {owner_state, owner_host, follower_state, follower_host, owner_ok, follower_ok} <- [
          {"active", host, "active", host, true, true},
          {"active", "another-host", "active", host, false, true},
          {"retired", host, "active", host, false, true},
          {"active", host, "retired", host, true, false},
          {"retired", host, "retired", host, false, false},
          {"active", host, "active", "another-host", true, true}
        ] do
      assert {:ok, _} =
               DB.query(db, "UPDATE sessions SET state=?2,host=?3 WHERE sessionKey=?1", [
                 call.session_key,
                 owner_state,
                 owner_host
               ])

      assert {:ok, _} =
               DB.query(db, "UPDATE sessions SET state=?2,host=?3 WHERE sessionKey=?1", [
                 follower.session_key,
                 follower_state,
                 follower_host
               ])

      expected =
        for [id, session] <- captured,
            (session == call.session_key and owner_ok) or
              (session == follower.session_key and follower_ok),
            into: MapSet.new(),
            do: id

      assert {:ok, rows} = DB.query(db, Tightbeam.Wakes.due_scan_sql(), [1])
      assert MapSet.new(rows, &hd/1) == expected
    end
  end

  test "production due scan searches indexed candidates as captured history grows", %{
    db: db,
    call: call
  } do
    assert {:ok, _} =
             DB.query(
               db,
               """
               WITH RECURSIVE due(n) AS (SELECT 1 UNION ALL SELECT n+1 FROM due WHERE n<3000)
               INSERT INTO wakes(wakeId,sessionKey,origin,consumer,dueAt,state,createdAt,ownerUserId)
               SELECT 'ordinary-due-'||n,?1,'test','test',0,'pending',1,'owner' FROM due
               """,
               [call.session_key]
             )

    for {first, last} <- [{1, 100}, {101, 3000}] do
      assert {:ok, _} =
               DB.query(
                 db,
                 """
                 WITH RECURSIVE history(n) AS (SELECT ?2 UNION ALL SELECT n+1 FROM history WHERE n<?3)
                 INSERT INTO wakes(wakeId,sessionKey,origin,consumer,dueAt,state,createdAt,ownerUserId)
                 SELECT 'captured-history-'||n,?1,'test','test',0,'fired',1,'owner' FROM history
                 """,
                 [call.session_key, first, last]
               )

      assert {:ok, _} =
               DB.query(
                 db,
                 """
                 WITH RECURSIVE history(n) AS (SELECT ?2 UNION ALL SELECT n+1 FROM history WHERE n<?3)
                 INSERT INTO harklight_wake_entries
                   (handle,eventId,feedCursor,senderId,messageId,entryKind,entryAuthor,rawLine,wakeId,capturedAt)
                 SELECT ?1,'history-'||n,n,'sender','request','discussion','person','{}',
                   'captured-history-'||n,1 FROM history
                 """,
                 [@handle, first, last]
               )

      assert {:ok, _} =
               DB.query(
                 db,
                 """
                 INSERT INTO harklight_wake_deliveries(handle,eventId,sessionKey,wakeId)
                 SELECT handle,eventId,?2,wakeId FROM harklight_wake_entries
                 WHERE handle=?1 AND feedCursor BETWEEN ?3 AND ?4
                 """,
                 [@handle, call.session_key, first, last]
               )

      assert {:ok, [[^last]]} = DB.query(db, "SELECT count(*) FROM harklight_wake_entries")

      for analyzed <- [false, true] do
        if analyzed, do: assert({:ok, _} = DB.query(db, "ANALYZE"))
        sql = Tightbeam.Wakes.due_scan_sql()
        assert {:ok, [[3000]]} = DB.query(db, "SELECT count(*) FROM (" <> sql <> ")", [1])
        assert {:ok, plan} = DB.query(db, "EXPLAIN QUERY PLAN " <> sql, [1])
        details = Enum.map(plan, &List.last/1)
        refute Enum.any?(details, &Regex.match?(~r/SCAN (e|d)\b/, &1)), inspect(details)

        for table <- ["e", "d"] do
          assert Enum.any?(
                   details,
                   &(String.contains?(&1, "SEARCH " <> table <> " USING") and
                       String.contains?(&1, "wakeId=?"))
                 ),
                 inspect(details)
        end
      end
    end
  end

  test "superseded-terminal lookup uses the sender and target index", %{db: db} do
    assert {:ok, rows} =
             DB.query(
               db,
               "EXPLAIN QUERY PLAN SELECT 1 FROM harklight_pending_supersedes WHERE senderId=?1 AND messageId=?2 LIMIT 1",
               ["sender", "request"]
             )

    assert Enum.any?(rows, fn row ->
             List.last(row) =~
               "SEARCH harklight_pending_supersedes USING COVERING INDEX harklight_pending_supersedes_target"
           end)
  end

  test "schema backfills preexisting pending supersede targets and deduplicates them", %{
    db: db,
    call: call
  } do
    op = Tightbeam.Id.uuid4()

    payload =
      JSON.encode!(%{
        request: %{
          message: %{
            sender_id: "sender",
            message_id: "replacement",
            supersedes: ["request", "request"]
          }
        }
      })

    assert %{state: "pending"} = HarklightWakes.prepare_send(db, call, op, payload)

    assert :ok = DB.execute(db, "DROP INDEX harklight_pending_supersedes_target")

    assert :ok = DB.execute(db, "DROP TABLE harklight_pending_supersedes")
    assert :ok = DB.execute(db, "DROP TABLE harklight_pending_supersedes_migration")
    assert :ok = HarklightWakes.ensure_schema(db)

    assert {:ok, [[1]]} =
             DB.query(db, "SELECT count(*) FROM harklight_pending_supersedes WHERE opId=?1", [op])

    assert {:ok, _} = DB.query(db, "DELETE FROM harklight_pending_supersedes WHERE opId=?1", [op])

    assert {:ok, _} = DB.query(db, "DELETE FROM harklight_pending_supersedes_migration")

    assert :ok =
             DB.execute(db, """
             CREATE TRIGGER fail_harklight_pending_supersedes_marker
             BEFORE INSERT ON harklight_pending_supersedes_migration
             BEGIN
               SELECT RAISE(ABORT, 'simulated interrupted migration');
             END;
             """)

    assert {:error, _} = HarklightWakes.ensure_schema(db)

    assert {:ok, [[0]]} =
             DB.query(db, "SELECT count(*) FROM harklight_pending_supersedes WHERE opId=?1", [op])

    assert {:ok, [[0]]} =
             DB.query(db, "SELECT count(*) FROM harklight_pending_supersedes_migration")

    assert :ok = DB.execute(db, "DROP TRIGGER fail_harklight_pending_supersedes_marker")

    assert :ok = HarklightWakes.ensure_schema(db)
    assert :ok = HarklightWakes.ensure_schema(db)

    assert {:ok, [[^op, "sender", "request"]]} =
             DB.query(
               db,
               "SELECT opId,senderId,messageId FROM harklight_pending_supersedes WHERE opId=?1",
               [op]
             )

    assert {:ok, [[1]]} =
             DB.query(db, "SELECT count(*) FROM harklight_pending_supersedes WHERE opId=?1", [op])

    assert :ok = HarklightWakes.capture_line(db, @handle, terminal(1, "request"))

    assert {:ok, [[1]]} =
             DB.query(db, "SELECT count(*) FROM harklight_held_terminals WHERE eventId='1'")
  end

  test "preparing a settled pending send does not restore supersede targets", %{
    db: db,
    call: call
  } do
    op = Tightbeam.Id.uuid4()

    payload =
      JSON.encode!(%{
        request: %{
          message: %{sender_id: "sender", message_id: "replacement", supersedes: ["request"]}
        }
      })

    assert %{state: "pending"} = HarklightWakes.prepare_send(db, call, op, payload)

    assert {:ok, [[1]]} =
             DB.query(db, "SELECT count(*) FROM harklight_pending_supersedes WHERE opId=?1", [op])

    assert {:ok, %{wake_effect: "none"}} = HarklightLifecycle.record_refused(db, op)
    assert %{state: "pending"} = HarklightWakes.prepare_send(db, call, op, payload)

    assert {:ok, [[0]]} =
             DB.query(db, "SELECT count(*) FROM harklight_pending_supersedes WHERE opId=?1", [op])
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
                     message_type: "request",
                     reply: true,
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
              message_type: "request",
              reply: true,
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
              message_type: "request",
              reply: true,
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
                     message_type: "request",
                     reply: true,
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

  test "message and conversation follows overlap once per session and entry", %{
    db: db,
    call: call,
    main: main
  } do
    follower = follower_session(db, main, "agent:follower:one")
    second_follower = follower_session(db, main, "agent:follower:two")
    message_call = follow_call(call, follower, %{message_id: "request"})
    conversation_call = follow_call(call, follower, %{handle: @handle})
    runner = lifecycle_runner(db)

    assert %{
             command: "follow",
             following: "message",
             outcome: "committed",
             wake_effect: "subscribed",
             message_id: "request",
             handle: @handle,
             sender_id: "sender"
           } = follow_for_test(db, message_call, runner: runner)

    assert %{outcome: "committed", following: "conversation", wake_effect: "subscribed"} =
             follow_for_test(db, conversation_call, runner: runner)

    assert %{outcome: "committed", wake_effect: "kept"} =
             follow_for_test(db, message_call, runner: runner)

    assert %{outcome: "committed", wake_effect: "subscribed"} =
             follow_for_test(
               db,
               follow_call(call, second_follower, %{message_id: "request"}),
               runner: runner
             )

    assert %{outcome: "committed", wake_effect: "kept"} =
             follow_for_test(db, follow_call(call, call, %{message_id: "request"}),
               runner: runner
             )

    assert {:ok, [[0]]} =
             DB.query(
               db,
               "SELECT count(*) FROM harklight_wake_follows WHERE sessionKey=?1 AND kind='message'",
               [call.session_key]
             )

    assert :ok = HarklightWakes.capture_line(db, @handle, event(1, "discussion", "Reply"))

    assert {:ok, [[1]]} =
             DB.query(
               db,
               "SELECT count(*) FROM harklight_wake_deliveries WHERE handle=?1 AND eventId='1' AND sessionKey=?2",
               [@handle, follower.session_key]
             )

    assert {:ok, [[1]]} =
             DB.query(
               db,
               "SELECT count(*) FROM harklight_wake_deliveries WHERE handle=?1 AND eventId='1' AND sessionKey=?2",
               [@handle, second_follower.session_key]
             )

    assert {:ok, [[owner_prompt]]} =
             DB.query(db, "SELECT prompt FROM wakes WHERE sessionKey=?1", [call.session_key])

    assert {:ok, [[follower_prompt]]} =
             DB.query(db, "SELECT prompt FROM wakes WHERE sessionKey=?1", [follower.session_key])

    assert follower_prompt == owner_prompt

    assert Enum.count(
             follow_for_test(db, conversation_call, runner: runner).subscriptions,
             &(&1.follower == follower.session_key and &1.kind == "conversation" and
                 &1.state == "open")
           ) == 1
  end

  test "a follow starts at its transaction and does not gain earlier captured entries", %{
    db: db,
    call: call,
    main: main
  } do
    follower = follower_session(db, main, "agent:follower:coverage")
    runner = lifecycle_runner(db)
    entry = event(1, "discussion", "Already captured")

    assert :ok = HarklightWakes.capture_line(db, @handle, entry)

    assert %{outcome: "committed"} =
             follow_for_test(db, follow_call(call, follower, %{message_id: "request"}),
               runner: runner
             )

    assert :ok = HarklightWakes.capture_line(db, @handle, entry)

    assert {:ok, [[0]]} =
             DB.query(db, "SELECT count(*) FROM wakes WHERE sessionKey=?1", [follower.session_key])

    assert :ok = HarklightWakes.capture_line(db, @handle, event(2, "discussion", "New reply"))

    assert {:ok, [[1]]} =
             DB.query(db, "SELECT count(*) FROM wakes WHERE sessionKey=?1", [follower.session_key])
  end

  test "unknown and unresolved messages refuse without recording a follow", %{
    db: db,
    call: call,
    main: main
  } do
    follower = follower_session(db, main, "agent:follower:unknown")
    runner = lifecycle_runner(db)

    assert %{outcome: "refused", wake_effect: "none", reason: message_reason} =
             follow_for_test(db, follow_call(call, follower, %{message_id: "raw-message"}),
               runner: runner
             )

    assert message_reason =~
             "only messages and conversations sent through tightbeam harklight-send"

    assert %{outcome: "refused", wake_effect: "none", reason: handle_reason} =
             follow_for_test(db, follow_call(call, follower, %{handle: "raw-handle"}),
               runner: runner
             )

    assert handle_reason =~
             "only messages and conversations sent through tightbeam harklight-send"

    pending_op = Tightbeam.Id.uuid4()

    pending_payload =
      JSON.encode!(%{
        request: %{
          session_handle: @handle,
          message: %{sender_id: "sender", message_id: "pending-message"}
        }
      })

    assert %{state: "pending"} =
             HarklightWakes.prepare_send(db, call, pending_op, pending_payload)

    assert %{
             outcome: "refused",
             wake_effect: "none",
             message_id: "pending-message",
             reason: unresolved_reason
           } =
             follow_for_test(
               db,
               follow_call(call, follower, %{message_id: "pending-message"}),
               runner: runner
             )

    assert unresolved_reason =~ "is unresolved"
    assert unresolved_reason =~ "tightbeam harklight-settle --message pending-message"

    assert {:ok, [[0]]} =
             DB.query(db, "SELECT count(*) FROM harklight_wake_follows WHERE sessionKey=?1", [
               follower.session_key
             ])
  end

  test "status decides whether a follow can be recorded", %{db: db, call: call, main: main} do
    follower = follower_session(db, main, "agent:follower:status")
    follow_call = follow_call(call, follower, %{handle: @handle})

    assert %{outcome: "refused", wake_effect: "none", reason: finished_reason} =
             follow_for_test(db, follow_call,
               runner:
                 lifecycle_runner(db,
                   status: %{
                     open_requests: 0,
                     open_chats: 0,
                     pending_undelivered: 0,
                     pending_delivered_unacted: 0
                   }
                 )
             )

    assert finished_reason =~ "already finished"

    assert %{outcome: "failed", wake_effect: "none", reason: status_reason} =
             follow_for_test(db, follow_call, runner: lifecycle_runner(db, status_failure: true))

    assert status_reason =~ "status could not be read"

    assert {:ok, [[0]]} =
             DB.query(db, "SELECT count(*) FROM harklight_wake_follows WHERE sessionKey=?1", [
               follower.session_key
             ])
  end

  test "following requires the existing conversation origin host rule", %{
    db: db,
    call: call,
    main: main
  } do
    follower = follower_session(db, main, "agent:follower:remote-origin")

    assert {:ok, _} =
             DB.query(
               db,
               "UPDATE harklight_wake_handles SET host='other-host' WHERE handle=?1",
               [@handle]
             )

    result =
      follow_for_test(
        db,
        follow_call(call, follower, %{message_id: "request"}),
        runner: fn _ -> flunk("status must not run outside the conversation origin host") end
      )

    assert %{
             command: "follow",
             following: "message",
             outcome: "failed",
             wake_effect: "none",
             message_id: "request",
             handle: @handle,
             sender_id: "sender",
             code: "harklight_origin_unavailable"
           } = result

    assert {:ok, [[0]]} =
             DB.query(db, "SELECT count(*) FROM harklight_wake_follows WHERE sessionKey=?1", [
               follower.session_key
             ])
  end

  test "self supersede files follower terminals before acknowledgment and keeps conversation follows open",
       %{db: db, call: call, main: main} do
    message_follower = follower_session(db, main, "agent:follower:message")
    conversation_follower = follower_session(db, main, "agent:follower:conversation")
    runner = lifecycle_runner(db)

    assert %{outcome: "committed"} =
             follow_for_test(
               db,
               follow_call(call, message_follower, %{message_id: "request"}),
               runner: runner
             )

    assert %{outcome: "committed"} =
             follow_for_test(
               db,
               follow_call(call, conversation_follower, %{handle: @handle}),
               runner: runner
             )

    supersede_call = %{
      call
      | params: %{
          harklight_session: @handle,
          message_type: "request",
          reply: true,
          sender_id: "sender",
          title: "Replacement",
          supersedes: ["request"]
        }
    }

    assert %{outcome: "committed", supersedes: [%{effect: "ended"}]} =
             HarklightSend.send_request(db, supersede_call, runner: runner)

    assert :ok = HarklightWakes.capture_line(db, @handle, terminal(1, "request"))

    assert {:ok, [[1]]} =
             DB.query(db, "SELECT count(*) FROM wakes WHERE sessionKey=?1", [
               message_follower.session_key
             ])

    assert {:ok, [[1]]} =
             DB.query(db, "SELECT count(*) FROM wakes WHERE sessionKey=?1", [
               conversation_follower.session_key
             ])

    assert {:ok, [[0]]} =
             DB.query(db, "SELECT count(*) FROM wakes WHERE sessionKey=?1", [call.session_key])

    assert {:ok, [["ended"]]} =
             DB.query(
               db,
               "SELECT state FROM harklight_wake_follows WHERE sessionKey=?1 AND kind='message'",
               [message_follower.session_key]
             )

    assert {:ok, [["open"]]} =
             DB.query(
               db,
               "SELECT state FROM harklight_wake_follows WHERE sessionKey=?1 AND kind='conversation'",
               [conversation_follower.session_key]
             )

    HarklightLifecycle.process_terminals(db, runner: runner)
    assert_receive {:acked, "1"}

    assert :ok =
             HarklightSend.ack(@handle, "1",
               runner: lifecycle_runner(db, ack_status: "already_delivered")
             )

    assert :ok =
             HarklightWakes.capture_line(
               db,
               @handle,
               event(2, "discussion", "Old conversation entry")
             )

    assert {:ok, [[0]]} =
             DB.query(db, "SELECT count(*) FROM wakes WHERE sessionKey=?1", [call.session_key])

    assert {:ok, [[1]]} =
             DB.query(db, "SELECT count(*) FROM wakes WHERE sessionKey=?1", [
               message_follower.session_key
             ])

    assert {:ok, [[2]]} =
             DB.query(
               db,
               "SELECT count(*) FROM wakes WHERE sessionKey=?1",
               [conversation_follower.session_key]
             )

    assert :ok =
             HarklightWakes.capture_line(
               db,
               @handle,
               event(3, "discussion", "Replacement reply", "replacement")
             )

    assert {:ok, [[1]]} =
             DB.query(db, "SELECT count(*) FROM wakes WHERE sessionKey=?1", [
               message_follower.session_key
             ])

    assert {:ok, [[3]]} =
             DB.query(db, "SELECT count(*) FROM wakes WHERE sessionKey=?1", [
               conversation_follower.session_key
             ])
  end

  test "a failed supersede acknowledgment follows terminal delivery and does not retry",
       %{db: db, call: call, main: main} do
    follower = follower_session(db, main, "agent:follower:ack-failure")

    assert %{outcome: "committed"} =
             follow_for_test(
               db,
               follow_call(call, follower, %{message_id: "request"}),
               runner: lifecycle_runner(db)
             )

    runner =
      lifecycle_runner(db,
        ack_failure: true,
        before_commit: fn -> HarklightWakes.capture_line(db, @handle, terminal(1, "request")) end
      )

    assert %{
             outcome: "committed",
             supersedes: [
               %{effect: "ended", acknowledgment: "failed", subscription_state: "open"}
             ]
           } =
             HarklightSend.send_request(
               db,
               %{
                 call
                 | params: %{
                     harklight_session: @handle,
                     message_type: "request",
                     reply: true,
                     sender_id: "sender",
                     title: "Replacement",
                     supersedes: ["request"]
                   }
               },
               runner: runner
             )

    assert_receive {:acked, "1"}

    assert {:ok, [[1]]} =
             DB.query(db, "SELECT count(*) FROM wakes WHERE sessionKey=?1", [follower.session_key])

    assert :ok = HarklightSend.ack(@handle, "1", runner: lifecycle_runner(db))
    assert_receive {:acked, "1"}
    HarklightLifecycle.process_terminals(db, runner: lifecycle_runner(db))
    refute_receive {:acked, _}
  end

  test "another-session supersede wakes the sender and message followers but excludes the caller",
       %{db: db, call: call, main: main} do
    message_follower = follower_session(db, main, "agent:follower:other-message")
    caller = follower_session(db, main, "agent:follower:other-caller")
    runner = lifecycle_runner(db)

    assert %{outcome: "committed"} =
             follow_for_test(
               db,
               follow_call(call, message_follower, %{message_id: "request"}),
               runner: runner
             )

    assert %{outcome: "committed"} =
             follow_for_test(
               db,
               follow_call(call, caller, %{handle: @handle}),
               runner: runner
             )

    payload =
      JSON.encode!(%{
        request: %{
          message: %{
            sender_id: "sender",
            message_id: "replacement-other",
            supersedes: ["request"]
          }
        }
      })

    assert {:ok, effects} =
             DB.transaction(db, fn txn ->
               HarklightLifecycle.send_committed_in_txn(
                 txn,
                 caller.session_key,
                 "cross-session-operation",
                 payload,
                 JSON.encode!(%{supersedes_warnings: []})
               )
             end)

    assert [%{effect: "other_session"}] = effects.supersedes
    assert :ok = HarklightWakes.capture_line(db, @handle, terminal(1, "request"))

    assert {:ok, [[1]]} =
             DB.query(db, "SELECT count(*) FROM wakes WHERE sessionKey=?1", [call.session_key])

    assert {:ok, [[1]]} =
             DB.query(db, "SELECT count(*) FROM wakes WHERE sessionKey=?1", [
               message_follower.session_key
             ])

    assert {:ok, [[0]]} =
             DB.query(db, "SELECT count(*) FROM wakes WHERE sessionKey=?1", [caller.session_key])

    assert {:ok, [[0]]} =
             DB.query(
               db,
               "SELECT count(*) FROM harklight_subscription_ends WHERE senderId='sender' AND messageId='request'"
             )

    assert :ok =
             HarklightWakes.capture_line(
               db,
               @handle,
               event(2, "discussion", "Still open to sender")
             )

    assert {:ok, [[2]]} =
             DB.query(db, "SELECT count(*) FROM wakes WHERE sessionKey=?1", [call.session_key])

    assert {:ok, [[1]]} =
             DB.query(db, "SELECT count(*) FROM wakes WHERE sessionKey=?1", [
               message_follower.session_key
             ])

    assert {:ok, [[1]]} =
             DB.query(db, "SELECT count(*) FROM wakes WHERE sessionKey=?1", [caller.session_key])
  end

  test "retract ends message follows and preserves pending deliveries for each recipient", %{
    db: db,
    call: call,
    main: main
  } do
    follower = follower_session(db, main, "agent:follower:retract")
    conversation_follower = follower_session(db, main, "agent:follower:retract-conversation")

    assert %{outcome: "committed"} =
             follow_for_test(db, follow_call(call, follower, %{message_id: "request"}),
               runner: lifecycle_runner(db)
             )

    assert %{outcome: "committed"} =
             follow_for_test(
               db,
               follow_call(call, conversation_follower, %{handle: @handle}),
               runner: lifecycle_runner(db)
             )

    assert :ok = HarklightWakes.capture_line(db, @handle, event(1, "discussion", "Pending reply"))
    record = HarklightLifecycle.lookup(db, "request")
    effects = HarklightLifecycle.retract_committed(db, record, "retract-operation")

    assert effects.wake_effect == "ended"

    assert Enum.map(effects.pending_delivery, & &1.session_key) |> Enum.sort() ==
             Enum.sort([
               call.session_key,
               follower.session_key,
               conversation_follower.session_key
             ])

    assert {:ok, [["ended"]]} =
             DB.query(
               db,
               "SELECT state FROM harklight_wake_follows WHERE sessionKey=?1 AND kind='message'",
               [follower.session_key]
             )

    assert {:ok, [["open"]]} =
             DB.query(
               db,
               "SELECT state FROM harklight_wake_follows WHERE sessionKey=?1 AND kind='conversation'",
               [conversation_follower.session_key]
             )

    assert %{state: "registered"} = bind_extra(db, call, "next-request")

    assert :ok =
             HarklightWakes.capture_line(
               db,
               @handle,
               event(2, "discussion", "After retract", "next-request")
             )

    assert {:ok, [[2]]} = DB.query(db, "SELECT count(*) FROM harklight_wake_entries")

    assert {:ok, [[1]]} =
             DB.query(db, "SELECT count(*) FROM wakes WHERE sessionKey=?1", [follower.session_key])

    assert {:ok, [[2]]} =
             DB.query(db, "SELECT count(*) FROM wakes WHERE sessionKey=?1", [
               conversation_follower.session_key
             ])
  end

  test "an open follow restores listening after restart when its sender session is retired", %{
    db: db,
    call: call,
    main: main
  } do
    follower = follower_session(db, main, "agent:follower:restart")

    assert %{outcome: "committed"} =
             follow_for_test(
               db,
               follow_call(call, follower, %{message_id: "request"}),
               runner: lifecycle_runner(db)
             )

    assert {:ok, _} =
             DB.query(
               db,
               "UPDATE harklight_wake_handles SET vendorSessionId='saved-vendor' WHERE handle=?1",
               [@handle]
             )

    assert {:ok, _} =
             DB.query(db, "UPDATE sessions SET state='retired' WHERE sessionKey=?1", [
               call.session_key
             ])

    test_pid = self()

    listener = fn manager, handle, vendor_id ->
      send(test_pid, {:listener_started, handle, vendor_id})
      :ok = GenServer.call(manager, {:attached, handle})

      receive do
        :stop -> :ok
      end
    end

    start_supervised!({HarklightWakes, db: db, listener: listener})

    assert_receive {:listener_started, @handle, "saved-vendor"}
    assert :ok = HarklightWakes.capture_line(db, @handle, event(1, "discussion", "After restart"))

    assert {:ok, [[1]]} =
             DB.query(db, "SELECT count(*) FROM wakes WHERE sessionKey=?1", [follower.session_key])
  end

  test "ACK2 follows prompt dispatch for each person entry on the delivered turn", %{
    db: db,
    main: main,
    session: session
  } do
    follower = follower_session(db, main, "agent:follower:ack2")
    owner_turn = running_ack2_turn!(db, session.session_key)
    follower_turn = running_ack2_turn!(db, follower.session_key)

    ack2_fixture_entry!(
      db,
      @handle,
      "101",
      session.session_key,
      owner_turn.seq,
      "discussion",
      "person"
    )

    ack2_fixture_entry!(
      db,
      @handle,
      "102",
      session.session_key,
      owner_turn.seq,
      "terminal",
      "person"
    )

    ack2_fixture_entry!(
      db,
      @handle,
      "103",
      session.session_key,
      owner_turn.seq,
      "terminal",
      "server"
    )

    ack2_fixture_entry!(db, @handle, "104", session.session_key, nil, "discussion", "person")

    ack2_fixture_entry!(
      db,
      @handle,
      "105",
      follower.session_key,
      follower_turn.seq,
      "discussion",
      "person"
    )

    ack2_fixture_entry!(
      db,
      @handle,
      "106",
      session.session_key,
      owner_turn.seq,
      "discussion",
      "agent"
    )

    test_pid = self()

    runner = fn args ->
      send(test_pid, {:ack2, args})
      {"", 0}
    end

    assert :ok =
             HarklightWakes.ack2_for_dispatched_turn(
               db,
               owner_turn.seq,
               session.session_key,
               session.display_name,
               runner: runner
             )

    refute_receive {:ack2, _args}

    record_prompt_dispatched!(db, owner_turn)

    assert :ok =
             HarklightWakes.ack2_for_dispatched_turn(
               db,
               owner_turn.seq,
               session.session_key,
               session.display_name,
               runner: runner
             )

    assert_receive {:ack2, ["ack2", "--session", @handle, "--event", "101", "--agent", "Origin"]}

    assert_receive {:ack2, ["ack2", "--session", @handle, "--event", "102", "--agent", "Origin"]}

    refute_receive {:ack2, _args}

    record_prompt_dispatched!(db, follower_turn)

    assert :ok =
             HarklightWakes.ack2_for_dispatched_turn(
               db,
               follower_turn.seq,
               follower.session_key,
               follower.display_name,
               runner: runner
             )

    assert_receive {:ack2,
                    [
                      "ack2",
                      "--session",
                      @handle,
                      "--event",
                      "105",
                      "--agent",
                      "Follower",
                      "--rerouted"
                    ]}

    refute_receive {:ack2, _args}
  end

  test "ACK2 follows discussion retry lineage without treating dispatch as custody receipt", %{
    db: db,
    session: session
  } do
    assert :ok = HarklightWakes.capture_line(db, @handle, event(1, "discussion", "redeliver"))
    assert {:ok, [[root]]} = DB.query(db, "SELECT wakeId FROM harklight_wake_deliveries")
    first = deliver_discussion_turn!(db, root, session.session_key)
    assert :ok = Ledger.finish(db, first.seq, "failed", nil, owner_lease: first.owner_lease)
    test_pid = self()

    runner = fn args ->
      send(test_pid, {:retry_ack2, args})
      {"", 0}
    end

    Enum.reduce(1..2, root, fn attempt, source ->
      assert {:ok, [[retry]]} =
               DB.query(db, "SELECT retryWakeId FROM wake_retry_attempts WHERE wakeId=?1", [
                 source
               ])

      turn = deliver_discussion_turn!(db, retry, session.session_key)
      assert :ok = Ledger.stamp_adapter(db, turn.seq, 1)

      assert :ok =
               HarklightWakes.ack2_for_dispatched_turn(
                 db,
                 turn.seq,
                 session.session_key,
                 session.display_name,
                 runner: runner
               )

      refute_receive {:retry_ack2, _}
      record_prompt_dispatched!(db, turn)

      assert :ok =
               HarklightWakes.ack2_for_dispatched_turn(db, turn.seq, "agent:unrelated", "Other",
                 runner: runner
               )

      refute_receive {:retry_ack2, _}

      assert :ok =
               HarklightWakes.ack2_for_dispatched_turn(
                 db,
                 turn.seq,
                 session.session_key,
                 session.display_name,
                 runner: runner
               )

      assert_receive {:retry_ack2,
                      ["ack2", "--session", @handle, "--event", "1", "--agent", "Origin"]}

      refute_receive {:retry_ack2, _}

      terminal = if attempt == 1, do: "failed_unknown", else: "delivered"
      assert :ok = Ledger.finish(db, turn.seq, terminal, nil, owner_lease: turn.owner_lease)

      if attempt == 1 do
        assert {:ok, [[next]]} =
                 DB.query(db, "SELECT retryWakeId FROM wake_retry_attempts WHERE wakeId=?1", [
                   retry
                 ])

        assert is_binary(next)
      else
        assert {:ok, [["acted", nil]]} =
                 DB.query(
                   db,
                   "SELECT outcome,retryWakeId FROM wake_retry_attempts WHERE wakeId=?1",
                   [retry]
                 )
      end

      retry
    end)
  end

  test "Harklight wake instructions leave ACK2 to the receiving system", %{db: db} do
    assert :ok = HarklightWakes.capture_line(db, @handle, event(1, "discussion", "Person prompt"))

    wake_id = "w_harklight_#{@handle}_" <> String.pad_leading("1", 20, "0")

    assert {:ok, [[prompt]]} = DB.query(db, "SELECT prompt FROM wakes WHERE wakeId=?1", [wake_id])
    refute prompt =~ "ack2"
  end

  defp follow_for_test(db, call, opts),
    do: HarklightFollows.follow(db, call, Keyword.put(opts, :activate, false))

  defp running_ack2_turn!(db, session_key) do
    message_id = "ack2-test-#{System.unique_integer([:positive])}"

    assert {:ok, seq} =
             Ledger.enqueue(db, %{
               session_key: session_key,
               message_id: message_id,
               origin: "process:tightbeam",
               prompt: "ACK2 fixture turn"
             })

    assert {:ok, %{seq: ^seq, owner_lease: _lease} = turn} =
             Ledger.claim_next(db, session_key, "ack2-test")

    assert :ok = Ledger.stamp_adapter(db, seq, 1)
    turn
  end

  defp record_prompt_dispatched!(db, turn) do
    assert :ok =
             TurnLifecycle.append(db, turn.seq, %{
               event_key: "prompt:dispatched",
               producer_event_id: "fixture:ack2:#{turn.seq}",
               kind: "prompt_dispatched",
               stage: "prompt",
               outcome: "dispatched",
               cause: "acp:port-write",
               principal: "process:tightbeam",
               owner_lease: turn.owner_lease,
               adapter_gen: 1,
               acp_request_id: turn.seq,
               detail: %{v: 1}
             })
  end

  defp ack2_fixture_entry!(db, handle, event_id, session_key, turn_seq, kind, author) do
    wake_id = "ack2_fixture_#{event_id}_#{System.unique_integer([:positive])}"

    assert %{wake_id: ^wake_id} =
             Wakes.schedule(db, %{
               wake_id: wake_id,
               session_key: session_key,
               origin: "process:tightbeam",
               prompt: "ACK2 fixture entry",
               due_at: System.system_time(:millisecond)
             })

    if is_integer(turn_seq) do
      assert {:ok, _} =
               DB.query(db, "UPDATE wakes SET deliveredTurnSeq=?2 WHERE wakeId=?1", [
                 wake_id,
                 turn_seq
               ])
    end

    cursor = String.to_integer(event_id)

    assert {:ok, _} =
             DB.query(
               db,
               """
               INSERT INTO harklight_wake_entries
                 (handle,eventId,feedCursor,senderId,messageId,requestRevision,entryKind,entryAuthor,rawLine,wakeId,capturedAt)
               VALUES(?1,?2,?3,'sender','request',1,?4,?5,'{}',?6,?7)
               """,
               [handle, event_id, cursor, kind, author, wake_id, System.system_time(:millisecond)]
             )

    assert {:ok, _} =
             DB.query(
               db,
               "INSERT INTO harklight_wake_deliveries(handle,eventId,sessionKey,wakeId) VALUES(?1,?2,?3,?4)",
               [handle, event_id, session_key, wake_id]
             )

    :ok
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
        hd(args) == "status" ->
          if opts[:status_failure] do
            {"status unavailable", 2}
          else
            status =
              Map.merge(
                %{
                  session_handle: List.last(args),
                  open_requests: 1,
                  open_chats: 1,
                  pending_undelivered: 0,
                  pending_delivered_unacted: 0
                },
                opts[:status] || %{}
              )

            frame(status)
          end

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
            else:
              frame(%{
                kind: "acknowledged",
                event_id: event,
                status: opts[:ack_status] || "delivered"
              })

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
              response = %{
                session_handle: @handle,
                supersedes_warnings: opts[:warnings] || []
              }

              response =
                if Keyword.has_key?(opts, :possible_contradictions),
                  do: Map.put(response, :possible_contradictions, opts[:possible_contradictions]),
                  else: response

              frame(%{
                kind: "committed",
                operation: "send",
                op_id: op,
                response: response
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

  defp follower_session(db, main, key) do
    Org.create(db, %{
      session_key: key,
      display_name: "Follower",
      owner_user_id: "owner",
      origin: "user:owner",
      spawned_by: main.session_key,
      archetype: "default",
      host: Placement.local_host_name(),
      harness: "codex",
      provider: "openai",
      model: Model.new("fable")
    })
  end

  defp follow_call(call, session, params) do
    %{
      call
      | session_key: session.session_key,
        principal: {:session, session.session_key},
        transport_session_key: session.session_key,
        params: params
    }
  end

  defp fake_harklight_agent!(body) do
    directory =
      Path.join(System.tmp_dir!(), "harklight-agent-test-#{System.unique_integer([:positive])}")

    File.mkdir_p!(directory)
    executable = Path.join(directory, "harklight-agent")
    File.write!(executable, "#!/bin/sh\nif [ \"$1\" = status ]; then exit 1; fi\n" <> body)
    File.chmod!(executable, 0o755)

    previous_path = System.get_env("PATH")
    System.put_env("PATH", Enum.join([directory, previous_path] |> Enum.reject(&is_nil/1), ":"))

    on_exit(fn ->
      if is_nil(previous_path),
        do: System.delete_env("PATH"),
        else: System.put_env("PATH", previous_path)

      File.rm_rf!(directory)
    end)
  end

  defp fake_harklight_session_end_agent!(exit_status \\ 0, opts \\ []) do
    directory =
      Path.join(
        System.tmp_dir!(),
        "harklight-session-end-test-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(directory)
    executable = Path.join(directory, "harklight-agent")
    calls = Path.join(directory, "calls.log")

    wait_for_session_end =
      if Keyword.get(opts, :wait_for_session_end, false) do
        "if [ \"$1\" = \"session\" ]; then\n" <>
          "  while [ ! -e \"#{calls}.release\" ]; do sleep 0.01; done\n" <>
          "fi\n"
      else
        ""
      end

    File.write!(
      executable,
      "#!/bin/sh\nif [ \"$1\" = status ]; then exit 1; fi\nprintf '%s\\n' \"$*\" >> \"#{calls}\"\n" <>
        "if [ \"$1\" = \"attach\" ]; then exit 1; fi\n" <>
        wait_for_session_end <>
        "if [ \"$1\" = \"session\" ]; then printf '%s\\n' '#{exit_status}' > \"#{calls}.exit-status\"; fi\n" <>
        "exit #{exit_status}\n"
    )

    File.chmod!(executable, 0o755)

    previous_path = System.get_env("PATH")
    System.put_env("PATH", Enum.join([directory, previous_path] |> Enum.reject(&is_nil/1), ":"))

    on_exit(fn ->
      File.write!(calls <> ".release", "continue")

      if is_nil(previous_path),
        do: System.delete_env("PATH"),
        else: System.put_env("PATH", previous_path)

      File.rm_rf!(directory)
    end)

    calls
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
        {HarklightWakes,
         db: db, listener: completion_notifying_listener(parent), send_runner: runner}
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

    assert :active = HarklightLifecycle.complete_answered(db, @handle, runner: runner)

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
    assert :active = HarklightLifecycle.complete_answered(db, @handle, runner: runner)

    Agent.update(responses, fn current ->
      put_in(current, [:status, "pending_undelivered"], 0)
      |> put_in([:status, "pending_delivered_unacted"], 1)
      |> put_in([:events, @handle, Access.at(0), "delivered"], true)
    end)

    assert :active = HarklightLifecycle.complete_answered(db, @handle, runner: runner)

    assert {:ok, [["active"]]} =
             DB.query(db, "SELECT state FROM harklight_wake_handles WHERE handle=?1", [@handle])

    Agent.update(responses, fn current ->
      put_in(current, [:status, "pending_delivered_unacted"], 0)
      |> put_in([:events, @handle], [])
    end)

    assert :completed = HarklightLifecycle.complete_answered(db, @handle, runner: runner)

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
      assert :active = HarklightLifecycle.complete_answered(db, @handle, runner: runner)

      assert {:ok, [["active"]]} =
               DB.query(db, "SELECT state FROM harklight_wake_handles WHERE handle=?1", [@handle])
    end

    status_failure = fn
      ["read", "--session", _handle] -> {"", 0}
      ["status", "--session", _handle] -> {"not-json", 0}
    end

    assert :active = HarklightLifecycle.complete_answered(db, @handle, runner: status_failure)

    assert {:ok, [["active"]]} =
             DB.query(db, "SELECT state FROM harklight_wake_handles WHERE handle=?1", [@handle])
  end

  test "194 pending status reads leave the manager responsive and new requests ungated", %{
    db: db,
    session: session,
    call: call
  } do
    handles = [@handle | Enum.map(1..193, fn _ -> Tightbeam.Id.uuid4() end)]

    for {handle, index} <- Enum.with_index(tl(handles)),
        do: seed_completion_handle(db, session.session_key, handle, "scale-#{index}")

    parent = self()
    {:ok, phase} = Agent.start_link(fn -> nil end)
    started_at = System.monotonic_time(:millisecond)

    runner = fn ["status", "--session", handle] ->
      open = Agent.get(phase, & &1)

      if is_nil(open) do
        send(parent, {:status_waiting, handle, self()})
        receive do: (:release -> :ok)
      end

      {JSON.encode!(%{
         "session_handle" => handle,
         "open_requests" => if(open && MapSet.member?(open, handle), do: 1, else: 0),
         "pending_undelivered" => 0
       }), 0}
    end

    manager =
      start_supervised!(
        {HarklightWakes,
         db: db,
         listener: fn manager, handle, vendor ->
           ref = make_ref()
           GenServer.cast(manager, {:attach_slot, self(), ref})
           send(parent, {:attachment_waiting, handle})
           receive do: ({:attach_slot, ^ref} -> :ok)
           GenServer.cast(manager, {:attach_slot_released, self()})
           completion_notifying_listener(parent).(manager, handle, vendor)
         end,
         send_runner: runner}
      )

    readers =
      Map.new(
        for _ <- 1..4 do
          assert_receive {:status_waiting, handle, pid}, 5_000
          {handle, pid}
        end
      )

    probe_at = System.monotonic_time(:microsecond)
    state = :sys.get_state(manager, 1_000)
    response_us = System.monotonic_time(:microsecond) - probe_at
    assert map_size(state.workers) == 194
    assert MapSet.size(state.attach_slots) == 4
    assert eventually(fn -> :queue.len(:sys.get_state(manager).attach_waiting) == 190 end)
    # An actual new registration interrupts its handle's outstanding decision.
    [target, hung, release_first, _] = Map.keys(readers)
    old_reader = readers[target]
    monitor = Process.monitor(old_reader)
    request_at = System.monotonic_time(:microsecond)
    op = Tightbeam.Id.uuid4()
    payload = String.replace(@payload, "request", "scale-new-request")

    result =
      @result |> String.replace("request", "scale-new-request") |> String.replace(@handle, target)

    assert %{state: "pending"} = HarklightWakes.prepare_send(db, call, op, payload)

    assert %{state: "registered"} =
             HarklightWakes.bind_send(
               db,
               call,
               op,
               payload,
               result,
               target,
               "sender",
               "scale-new-request"
             )

    assert_receive {:DOWN, ^monitor, :process, ^old_reader, _}, 1_000
    assert_receive {:attachment_waiting, ^target}, 1_000
    :sys.get_state(manager)
    send(readers[release_first], :release)
    assert_receive {:restored, ^target, nil}, 1_000
    request_us = System.monotonic_time(:microsecond) - request_at
    # One read never returns; its deadline must preserve attachment. All other
    # slow closed responses skip, rather than attaching before their decision.
    for {handle, pid} <- readers,
        handle not in [target, hung, release_first],
        do: send(pid, :release)

    for _ <- 1..190 do
      assert_receive {:status_waiting, _handle, pid}, 1_000
      send(pid, :release)
    end

    assert_receive {:restored, ^hung, nil}, 6_000

    assert eventually(fn ->
             Map.keys(:sys.get_state(manager).workers) |> MapSet.new() ==
               MapSet.new([target, hung])
           end)

    refute_receive {:restored, _, _}

    assert {:ok, [[0]]} =
             DB.query(db, "SELECT count(*) FROM harklight_wake_handles WHERE state!='active'")

    first_ms = System.monotonic_time(:millisecond) - started_at
    # A timed-out command cannot return later and undo its fallback.
    refute Process.alive?(readers[hung])
    send(readers[hung], :release)
    assert Map.has_key?(:sys.get_state(manager).workers, hung)

    :ok = stop_supervised(HarklightWakes)
    Agent.update(phase, fn _ -> MapSet.new([target, hung]) end)
    restore_at = System.monotonic_time(:microsecond)

    second =
      start_supervised!(
        {HarklightWakes,
         db: db, listener: completion_notifying_listener(parent), send_runner: runner}
      )

    restored =
      for _ <- 1..2 do
        assert_receive {:restored, handle, nil}, 1_000
        handle
      end

    assert MapSet.new(restored) == MapSet.new([target, hung])
    assert eventually(fn -> map_size(:sys.get_state(second).workers) == 2 end)
    restore_us = System.monotonic_time(:microsecond) - restore_at
    refute_receive {:restored, _, _}

    later = Enum.find(handles, &(&1 not in [target, hung]))
    later_at = System.monotonic_time(:microsecond)
    later_op = Tightbeam.Id.uuid4()
    later_payload = String.replace(@payload, "request", "after-restore-request")

    later_result =
      @result
      |> String.replace("request", "after-restore-request")
      |> String.replace(@handle, later)

    assert %{state: "pending"} = HarklightWakes.prepare_send(db, call, later_op, later_payload)

    assert %{state: "registered"} =
             HarklightWakes.bind_send(
               db,
               call,
               later_op,
               later_payload,
               later_result,
               later,
               "sender",
               "after-restore-request"
             )

    assert_receive {:restored, ^later, nil}, 1_000
    later_us = System.monotonic_time(:microsecond) - later_at

    IO.puts(
      "R6_POPULATION_METRICS " <>
        JSON.encode!(%{
          handles: 194,
          manager_response_us: response_us,
          new_request_us: request_us,
          first_restore_ms: first_ms,
          second_restore_us: restore_us,
          after_restore_request_us: later_us
        })
    )
  end

  test "a nonreturning status subprocess is terminated before timeout falls back to attach", %{
    db: db,
    session: session
  } do
    closed = Tightbeam.Id.uuid4()
    seed_completion_handle(db, session.session_key, closed, "closed-subprocess")
    root = Path.join(System.tmp_dir!(), "status-timeout-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    executable = Path.join(root, "harklight-agent")
    pid_file = Path.join(root, "pid")

    status =
      JSON.encode!(%{
        "session_handle" => closed,
        "open_requests" => 0,
        "pending_undelivered" => 0
      })

    File.write!(
      executable,
      "#!/bin/sh\nif [ \"$3\" = '#{closed}' ]; then printf '%s\\n' '#{status}'; exit 0; fi\necho $$ > '#{pid_file}'\nexec sleep 300\n"
    )

    File.chmod!(executable, 0o755)
    previous = System.get_env("PATH")
    System.put_env("PATH", root <> ":" <> previous)

    on_exit(fn ->
      System.put_env("PATH", previous)
      File.rm_rf!(root)
    end)

    manager =
      start_supervised!({HarklightWakes, db: db, listener: completion_notifying_listener(self())})

    assert eventually(fn -> File.exists?(pid_file) end)
    pid = File.read!(pid_file) |> String.trim()
    assert eventually(fn -> map_size(:sys.get_state(manager, 1_000).workers) == 1 end)
    assert_receive {:restored, @handle, nil}, 6_000

    assert eventually(fn ->
             match?(
               {_, status} when status != 0,
               System.cmd("/bin/kill", ["-0", pid], stderr_to_stdout: true)
             )
           end)

    refute_receive {:restored, ^closed, _}

    assert {:ok, [[2]]} =
             DB.query(db, "SELECT count(*) FROM harklight_wake_handles WHERE state='active'")
  end

  test "known R with a nonreturning A8 read skips without completing or late mutation", %{db: db} do
    answer = completion_event(@handle, 1, "request", "terminal", "person")
    assert :ok = HarklightWakes.capture_line(db, @handle, JSON.encode!(answer))
    mark_completion_wakes_delivered(db, @handle)
    parent = self()

    runner = fn
      ["status", "--session", @handle] ->
        {JSON.encode!(%{
           "session_handle" => @handle,
           "open_requests" => 0,
           "pending_undelivered" => 0,
           "pending_delivered_unacted" => 0
         }), 0}

      ["read", "--session", @handle] ->
        send(parent, {:a8_waiting, self()})
        receive do: (:late_success -> {"", 0})
    end

    row = DB.query(db, "SELECT * FROM harklight_wake_handles")

    manager =
      start_supervised!(
        {HarklightWakes,
         db: db, listener: completion_notifying_listener(parent), send_runner: runner}
      )

    assert_receive {:a8_waiting, reader}, 1_000
    monitor = Process.monitor(reader)
    started = System.monotonic_time(:millisecond)
    assert map_size(:sys.get_state(manager, 1_000).workers) == 1
    assert_receive {:DOWN, ^monitor, :process, ^reader, _}, 6_000
    assert eventually(fn -> :sys.get_state(manager).workers == %{} end)
    refute_receive {:restored, _, _}
    assert DB.query(db, "SELECT * FROM harklight_wake_handles") == row
    send(reader, :late_success)
    refute Process.alive?(reader)
    assert DB.query(db, "SELECT * FROM harklight_wake_handles") == row
    IO.puts("R6_A8_TIMEOUT_MS=#{System.monotonic_time(:millisecond) - started}")
  end

  @tag :restart_count
  test "r6 startup skips closed conversations and preserves unfinished work", %{
    db: db,
    session: session
  } do
    [p1, p2, p3, k1, k2, k3, n1, n2] =
      handles = [@handle | Enum.map(1..7, fn _ -> Tightbeam.Id.uuid4() end)]

    for {handle, index} <- Enum.with_index(handles) do
      message = if handle == @handle, do: "request", else: "request-#{index}"
      if handle != @handle, do: seed_completion_handle(db, session.session_key, handle, message)

      if handle != n1 do
        author = if handle == k3, do: "agent", else: "person"
        event = completion_event(handle, 1, message, "terminal", author)

        event =
          if handle == k2,
            do: put_in(event, ["entry", "terminal_state"], "retracted"),
            else: event

        assert :ok = HarklightWakes.capture_line(db, handle, JSON.encode!(event))
        mark_completion_wakes_delivered(db, handle)
      end

      if handle in [p2, k1, k2, n1] do
        assert {:ok, _} =
                 DB.query(
                   db,
                   "UPDATE harklight_wake_handles SET state='unavailable',lastError='saved' WHERE handle=?1",
                   [handle]
                 )
      end
    end

    assert {:ok, _} =
             DB.query(
               db,
               "INSERT INTO harklight_send_operations(opId,sessionKey,host,payload,state,createdAt,updatedAt) VALUES('pending-r6',?1,?2,?3,'pending',1,1)",
               [
                 session.session_key,
                 Placement.local_host_name(),
                 JSON.encode!(%{"request" => %{"session_handle" => p3}})
               ]
             )

    status =
      Map.new(handles, fn handle ->
        {handle,
         %{
           "session_handle" => handle,
           "open_requests" => if(handle == n1, do: 1, else: 0),
           "pending_undelivered" => if(handle == n2, do: 1, else: 0),
           "pending_delivered_unacted" => if(handle == k1, do: 1, else: 0)
         }}
      end)

    {:ok, responses} = Agent.start_link(fn -> %{status: status, events: [], commands: []} end)
    parent = self()
    runner = completion_runner(responses, parent)
    listener = completion_notifying_listener(parent)

    unchanged =
      Map.new([p2, k1, k2, k3], fn h ->
        {h, DB.query(db, "SELECT * FROM harklight_wake_handles WHERE handle=?1", [h])}
      end)

    for _startup <- 1..2 do
      manager =
        start_supervised!({HarklightWakes, db: db, listener: listener, send_runner: runner})

      restored =
        for _ <- 1..3 do
          assert_receive {:restored, handle, nil}
          handle
        end

      assert MapSet.new(restored) == MapSet.new([p3, n1, n2])
      assert eventually(fn -> map_size(:sys.get_state(manager).workers) == 3 end)
      refute_receive {:restored, _, _}

      assert {:ok, [["complete"]]} =
               DB.query(db, "SELECT state FROM harklight_wake_handles WHERE handle=?1", [p1])

      for {handle, row} <- unchanged,
          do:
            assert(
              DB.query(db, "SELECT * FROM harklight_wake_handles WHERE handle=?1", [handle]) ==
                row
            )

      for handle <- [p3, n1, n2],
          do:
            assert(
              DB.query(db, "SELECT state FROM harklight_wake_handles WHERE handle=?1", [handle]) ==
                {:ok, [["active"]]}
            )

      :ok = stop_supervised(HarklightWakes)
    end

    assert :active = Tightbeam.HarklightLifecycle.complete_answered(db, p2, runner: runner)

    assert DB.query(db, "SELECT * FROM harklight_wake_handles WHERE handle=?1", [p2]) ==
             unchanged[p2]
  end

  test "closed skips survive ready and origin changes, but a new request starts", %{
    db: db,
    call: call,
    session: session
  } do
    parent = self()

    manager =
      start_supervised!(
        {HarklightWakes,
         db: db,
         listener: completion_notifying_listener(parent),
         send_runner: completion_idle_runner()}
      )

    assert eventually(fn -> :sys.get_state(manager).workers == %{} end)
    GenServer.cast(manager, {:origin_ready, session.session_key})
    GenServer.cast(manager, {:pointer_changed, session.session_key})
    GenServer.cast(manager, {:origin_changed, session.session_key})
    assert eventually(fn -> :sys.get_state(manager).workers == %{} end)
    refute_receive {:restored, _, _}

    op = Tightbeam.Id.uuid4()
    payload = String.replace(@payload, "request", "new-request")
    result = String.replace(@result, "request", "new-request")
    assert %{state: "pending"} = HarklightWakes.prepare_send(db, call, op, payload)

    assert %{state: "registered"} =
             HarklightWakes.bind_send(
               db,
               call,
               op,
               payload,
               result,
               @handle,
               "sender",
               "new-request"
             )

    assert_receive {:restored, @handle, nil}
    # A pointer replacement stops the current process, but skips a closed replacement
    # without writing a failure or ending the handle.
    row = DB.query(db, "SELECT * FROM harklight_wake_handles WHERE handle=?1", [@handle])
    GenServer.cast(manager, {:pointer_changed, session.session_key})
    assert eventually(fn -> :sys.get_state(manager).workers == %{} end)
    refute_receive {:restored, _, _}
    assert DB.query(db, "SELECT * FROM harklight_wake_handles WHERE handle=?1", [@handle]) == row

    assert {:ok, [[0]]} =
             DB.query(
               db,
               "SELECT count(*) FROM wakes WHERE wakeId LIKE 'w_harklight_notice_recovery_%'"
             )
  end

  test "R ignores delivered-unacted counts but preserves absent requests and held terminals", %{
    db: db
  } do
    runner = fn ["status", "--session", @handle] ->
      {JSON.encode!(%{
         "session_handle" => @handle,
         "open_requests" => 0,
         "pending_undelivered" => 0
       }), 0}
    end

    assert Tightbeam.HarklightLifecycle.closed_for_start?(db, @handle, runner: runner)
    raw = event(91, "terminal", "held")

    assert {:ok, _} =
             DB.query(
               db,
               "INSERT INTO harklight_held_terminals(handle,eventId,senderId,messageId,rawLine) VALUES(?1,'held','sender','request',?2)",
               [@handle, raw]
             )

    refute Tightbeam.HarklightLifecycle.closed_for_start?(db, @handle, runner: runner)
    assert {:ok, _} = DB.query(db, "DELETE FROM harklight_held_terminals")
    assert {:ok, _} = DB.query(db, "DELETE FROM harklight_wake_requests")
    refute Tightbeam.HarklightLifecycle.closed_for_start?(db, @handle, runner: runner)
  end

  for evidence_failure <- [
        :read_failed,
        :status_failed,
        :status_malformed,
        :status_missing,
        :local_pending
      ] do
    @evidence_failure evidence_failure
    test "startup preserves a conversation with #{@evidence_failure}", %{db: db} do
      answer = completion_event(@handle, 1, "request", "terminal", "person")
      assert :ok = HarklightWakes.capture_line(db, @handle, JSON.encode!(answer))
      if @evidence_failure != :local_pending, do: mark_completion_wakes_delivered(db, @handle)

      eligible_runner = completion_idle_runner()

      runner = fn args ->
        case {args, @evidence_failure} do
          {["read" | _], :read_failed} ->
            {"unavailable", 1}

          {["status" | _], :status_failed} ->
            {"unavailable", 1}

          {["status" | _], :status_malformed} ->
            {"not json", 0}

          {["status" | _], :status_missing} ->
            {JSON.encode!(%{"session_handle" => @handle, "open_requests" => 0}), 0}

          _ ->
            eligible_runner.(args)
        end
      end

      manager =
        start_supervised!(
          {HarklightWakes,
           db: db, listener: completion_notifying_listener(self()), send_runner: runner}
        )

      if @evidence_failure == :read_failed do
        assert eventually(fn -> :sys.get_state(manager).workers == %{} end)
        refute_receive {:restored, _, _}
      else
        assert_receive {:restored, @handle, nil}
        assert Map.has_key?(:sys.get_state(manager).workers, @handle)
      end

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

    assert :active = HarklightLifecycle.complete_answered(db, @handle, runner: runner)

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

    assert :completed = HarklightLifecycle.complete_answered(db, @handle, runner: runner)
  end

  test "completion waits for every WI7b follow wake delivery", %{db: db, session: session} do
    follower_key = "agent:origin:completion-follower"

    _follower =
      Org.create(db, %{
        session_key: follower_key,
        display_name: "Completion follower",
        owner_user_id: "owner",
        origin: "user:owner",
        spawned_by: session.session_key,
        archetype: "default",
        host: Placement.local_host_name(),
        harness: "codex",
        provider: "openai",
        model: Model.new("fable")
      })

    assert {:ok, _} =
             DB.query(
               db,
               "INSERT INTO harklight_wake_follows(followId,sessionKey,kind,handle,senderId,messageId,state,createdAt) VALUES(?1,?2,'conversation',?3,NULL,'','open',?4)",
               [Tightbeam.Id.uuid4(), follower_key, @handle, System.system_time(:millisecond)]
             )

    answer = completion_event(@handle, 1, "request", "terminal", "person")
    assert :ok = HarklightWakes.capture_line(db, @handle, JSON.encode!(answer))

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

    assert {:ok, [[2]]} =
             DB.query(
               db,
               "SELECT count(*) FROM harklight_wake_deliveries WHERE handle=?1 AND eventId='1'",
               [@handle]
             )

    mark_completion_wakes_delivered(db, @handle, [follower_key])
    assert :active = HarklightLifecycle.complete_answered(db, @handle, runner: runner)

    mark_completion_wakes_delivered(db, @handle)
    assert :completed = HarklightLifecycle.complete_answered(db, @handle, runner: runner)

    assert {:ok, [["ended"]]} =
             DB.query(
               db,
               "SELECT state FROM harklight_wake_follows WHERE sessionKey=?1 AND handle=?2",
               [follower_key, @handle]
             )
  end

  test "completion follows a failed delivery to its same-recipient retry", %{
    db: db,
    session: session
  } do
    answer = completion_event(@handle, 1, "request", "terminal", "person")
    assert :ok = HarklightWakes.capture_line(db, @handle, JSON.encode!(answer))

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

    assert {:ok, [[wake_id, origin_key]]} =
             DB.query(
               db,
               "SELECT wakeId,sessionKey FROM harklight_wake_deliveries WHERE handle=?1 AND eventId='1'",
               [@handle]
             )

    assert origin_key == session.session_key

    failed_seq = completion_turn(db, origin_key, wake_id, "failed", "provider rate limit")

    assert {:ok, {:retry, retry_wake_id}} =
             DB.transaction(db, &Wakes.preserve_failed_intent_for_terminal_in_txn(&1, failed_seq))

    assert :active = HarklightLifecycle.complete_answered(db, @handle, runner: runner)

    completion_turn(db, origin_key, retry_wake_id, "delivered", nil)
    assert :completed = HarklightLifecycle.complete_answered(db, @handle, runner: runner)
  end

  test "completion follows a failed delivery to its health redelivery", %{
    db: db,
    session: session
  } do
    answer = completion_event(@handle, 1, "request", "terminal", "person")
    assert :ok = HarklightWakes.capture_line(db, @handle, JSON.encode!(answer))

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

    assert {:ok, [[wake_id]]} =
             DB.query(
               db,
               "SELECT wakeId FROM harklight_wake_deliveries WHERE handle=?1 AND eventId='1' AND sessionKey=?2",
               [@handle, session.session_key]
             )

    failed_seq = completion_turn(db, session.session_key, wake_id, "failed", "unauthorized")
    assert :active = HarklightLifecycle.complete_answered(db, @handle, runner: runner)

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

    assert :active = HarklightLifecycle.complete_answered(db, @handle, runner: runner)

    assert {:ok, _} =
             DB.query(db, "UPDATE turns SET status='delivered',endedAt=?2 WHERE seq=?1", [
               redelivery_seq,
               now
             ])

    assert :completed = HarklightLifecycle.complete_answered(db, @handle, runner: runner)
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

  defp mark_completion_wakes_delivered(db, handle, excluded_sessions \\ []) do
    assert {:ok, rows} =
             DB.query(
               db,
               "SELECT wakeId,sessionKey FROM harklight_wake_deliveries WHERE handle=?1 ORDER BY eventId,sessionKey",
               [handle]
             )

    for [wake_id, session_key] <- Enum.uniq_by(rows, &hd/1),
        session_key not in excluded_sessions do
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

  defp completion_idle_runner do
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

  defp completion_notifying_listener(parent) do
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
end
