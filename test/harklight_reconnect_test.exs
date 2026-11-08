defmodule Tightbeam.HarklightReconnectTest do
  use Tightbeam.TestCase, async: false

  alias Tightbeam.{DB, HarklightReconnect, HarklightWakes, Model, Org, Placement}

  @handle "2f8f0a82-8e0e-4d95-b383-ef98cdf5e5ce"
  @send_op "40c8a3e1-7ccf-48f1-aab2-499fb9bf3d53"
  @payload ~s({"type":"send","message":{"sender_id":"sender","message_id":"request"}})
  @result ~s({"kind":"sent","session":"2f8f0a82-8e0e-4d95-b383-ef98cdf5e5ce","sender_id":"sender","request":"request"})

  setup do
    db = :"harklight_reconnect_#{System.unique_integer([:positive])}"
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

    origin =
      Org.create(db, %{
        session_key: "agent:origin:reconnect-test",
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

    send_call = %{
      session_key: origin.session_key,
      transport_session_key: origin.session_key,
      principal: {:session, origin.session_key},
      params: %{
        harklight_handle: @handle,
        harklight_sender_id: "sender",
        harklight_message_id: "request"
      }
    }

    assert %{code: "harklight_send_pending"} = HarklightWakes.register(db, send_call)
    assert %{state: "pending"} = HarklightWakes.prepare_send(db, send_call, @send_op, @payload)

    assert %{state: "registered"} =
             HarklightWakes.bind_send(
               db,
               send_call,
               @send_op,
               @payload,
               @result,
               @handle,
               "sender",
               "request"
             )

    assert {:ok, _} =
             DB.query(
               db,
               "UPDATE harklight_wake_handles SET state='unavailable' WHERE handle=?1",
               [@handle]
             )

    call = %{
      session_key: origin.session_key,
      principal: {:session, origin.session_key},
      params: %{message_id: "request"}
    }

    %{db: db, call: call, origin: origin}
  end

  test "an owner explicitly reconnects the original unanswered message and handle", %{
    db: db,
    call: call
  } do
    parent = self()

    runner = fn
      ["status", "--session", @handle] -> {JSON.encode!(status(open_chats: 1)), 0}
      _args -> {"", 0}
    end

    reconnector = fn handle, caller ->
      send(parent, {:reconnect, handle, caller})
      {:ok, %{feed_cursor: 17}}
    end

    result =
      HarklightReconnect.reconnect(db, call,
        agent_runner: runner,
        reconnector: reconnector
      )

    assert result == %{
             command: "harklight-reconnect",
             outcome: "committed",
             message_id: "request",
             handle: @handle,
             sender_id: "sender",
             reason_code: nil,
             reason: nil,
             feed_cursor: 17
           }

    assert_receive {:reconnect, @handle, "agent:origin:reconnect-test"}
    refute_receive {:reconnect, _, _}
  end

  test "an open message follower can reconnect the same original handle", %{db: db} do
    follower_key = "agent:follower:reconnect-test"

    Org.create(db, %{
      session_key: follower_key,
      display_name: "Follower",
      owner_user_id: "owner",
      origin: "user:owner",
      spawned_by: Org.personal_session_key("owner"),
      archetype: "default",
      host: Placement.local_host_name(),
      harness: "codex",
      provider: "openai",
      model: Model.new("fable")
    })

    assert {:ok, _} =
             DB.query(
               db,
               "INSERT INTO harklight_wake_follows(followId,sessionKey,kind,handle,senderId,messageId,state,createdAt) VALUES('follow-one',?1,'message',?2,'sender','request','open',1)",
               [follower_key, @handle]
             )

    parent = self()

    call = %{
      session_key: follower_key,
      principal: {:session, follower_key},
      params: %{message_id: "request"}
    }

    result =
      HarklightReconnect.reconnect(db, call,
        agent_runner: status_runner(@handle, status(open_chats: 1)),
        reconnector: fn handle, caller ->
          send(parent, {:reconnect, handle, caller})
          {:ok, %{feed_cursor: 3}}
        end
      )

    assert result.outcome == "committed"
    assert_receive {:reconnect, @handle, ^follower_key}
  end

  test "an unrelated caller cannot reconnect a message", %{db: db, call: call} do
    parent = self()

    result =
      HarklightReconnect.reconnect(
        db,
        %{call | session_key: "agent:other", principal: {:session, "agent:other"}},
        agent_runner: fn _args -> flunk("status must not run for an unauthorized caller") end,
        reconnector: fn _handle, _caller -> send(parent, :reconnect_called) end
      )

    assert result.outcome == "refused"
    assert result.reason_code == "harklight_reconnect_unauthorized"
    refute_receive :reconnect_called
  end

  test "Answer terminal results remain closed", %{db: db, call: call} do
    end_message(db, :subscription)
    assert_closed_without_reconnect(db, call)
  end

  test "NoComment terminal results remain closed", %{db: db, call: call} do
    end_message(db, :terminal_follow)
    assert_closed_without_reconnect(db, call)
  end

  test "pending receipts can be reconciled even when no chat remains open", %{db: db, call: call} do
    parent = self()

    result =
      HarklightReconnect.reconnect(db, call,
        agent_runner: status_runner(@handle, status(open_chats: 0, pending_undelivered: 1)),
        reconnector: fn handle, caller ->
          send(parent, {:reconnect, handle, caller})
          {:ok, %{feed_cursor: 19}}
        end
      )

    assert result.outcome == "committed"
    assert_receive {:reconnect, @handle, "agent:origin:reconnect-test"}
  end

  test "reconnect capture imports journal events once through the existing deduplicating writer",
       %{
         db: db
       } do
    test_pid = self()

    assert {:ok, _} =
             DB.query(db, "UPDATE harklight_wake_handles SET state='complete' WHERE handle=?1", [
               @handle
             ])

    start_supervised!({HarklightWakes, db: db})
    :sys.get_state(HarklightWakes)

    assert {:ok, _} =
             DB.query(
               db,
               "UPDATE harklight_wake_handles SET state='unavailable' WHERE handle=?1",
               [
                 @handle
               ]
             )

    event = %{
      "kind" => "event",
      "session_handle" => @handle,
      "event_id" => "1",
      "feed_cursor" => 1,
      "request_revision" => 1,
      "request" => %{"sender_id" => "sender", "message_id" => "request"},
      "entry" => %{"kind" => "discussion", "author" => "person", "body" => "New answer"}
    }

    line = JSON.encode!(event)

    worker =
      spawn(fn ->
        receive do
          :capture ->
            first = GenServer.call(HarklightWakes, {:capture_reconnect, @handle, line})
            second = GenServer.call(HarklightWakes, {:capture_reconnect, @handle, line})
            send(test_pid, {:capture_results, first, second})
        end
      end)

    :sys.replace_state(HarklightWakes, fn state ->
      %{state | workers: Map.put(state.workers, @handle, worker)}
    end)

    send(worker, :capture)
    assert_receive {:capture_results, :ok, :ok}

    assert {:ok, [[1, 1, "active"]]} =
             DB.query(
               db,
               "SELECT (SELECT count(*) FROM harklight_wake_entries WHERE handle=?1 AND eventId='1'),lastCursor,state FROM harklight_wake_handles WHERE handle=?1",
               [@handle]
             )

    assert {:ok, [[1]]} =
             DB.query(
               db,
               "SELECT count(*) FROM wakes WHERE wakeId LIKE ?1",
               ["w_harklight_" <> @handle <> "_%"]
             )

    :sys.replace_state(HarklightWakes, fn state ->
      %{state | workers: Map.delete(state.workers, @handle)}
    end)
  end

  @tag :requires_wid247_child_wrapper
  test "fresh reconnect returns on handshake and captures streamed entries before child exit", %{
    db: db,
    call: call
  } do
    root =
      Path.join(System.tmp_dir!(), "harklight-reconnect-#{System.unique_integer([:positive])}")

    File.mkdir_p!(root)

    helper = Path.join(root, "tightbeam-child")
    agent = Path.join(root, "harklight-agent")
    connected_marker = Path.join(root, "connected")
    idle_marker = Path.join(root, "idle")
    events_gate = Path.join(root, "events-gate")
    events_marker = Path.join(root, "events-emitted")

    event_line =
      JSON.encode!(%{
        "kind" => "event",
        "session_handle" => @handle,
        "event_id" => "1",
        "feed_cursor" => 1,
        "request_revision" => 1,
        "request" => %{"sender_id" => "sender", "message_id" => "request"},
        "entry" => %{"kind" => "discussion", "author" => "person", "body" => "New answer"}
      })

    connected_line =
      JSON.encode!(%{"kind" => "reconnected", "session_handle" => @handle, "feed_cursor" => 1})

    File.write!(helper, """
    #!/bin/sh
    printf 'TIGHTBEAM_CHILD_READY\\n'
    IFS= read -r command
    [ "$command" = continue ] || exit 31
    shift 4
    exec "$@"
    """)

    File.write!(agent, """
    #!/bin/sh
    case "$1" in
      reconnect)
        printf '%s\\n' '#{connected_line}'
        touch '#{connected_marker}'
        printf '%s\\n' '{"kind":"idle","session_handle":"#{@handle}","open_requests":0}'
        touch '#{idle_marker}'
        while [ ! -f '#{events_gate}' ]; do sleep 0.01; done
        printf '%s\\n' '#{event_line}' '#{event_line}'
        touch '#{events_marker}'
        while IFS= read -r command; do
          [ "$command" = stop ] && exit 0
        done
        exit 0
        ;;
      *) exit 2 ;;
    esac
    """)

    File.chmod!(helper, 0o755)
    File.chmod!(agent, 0o755)

    old_path = System.get_env("PATH") || ""
    old_child_opts = Application.get_env(:tightbeam, :harklight_child_opts)
    System.put_env("PATH", root <> ":" <> old_path)

    Application.put_env(:tightbeam, :harklight_child_opts,
      base_dir: root,
      cli_path: helper
    )

    on_exit(fn ->
      System.put_env("PATH", old_path)

      if is_nil(old_child_opts),
        do: Application.delete_env(:tightbeam, :harklight_child_opts),
        else: Application.put_env(:tightbeam, :harklight_child_opts, old_child_opts)

      File.rm_rf!(root)
    end)

    assert {:ok, _} =
             DB.query(db, "UPDATE harklight_wake_handles SET state='complete' WHERE handle=?1", [
               @handle
             ])

    runner = fn
      ["status", "--session", @handle] -> {JSON.encode!(status(open_chats: 1)), 0}
      _args -> {"", 0}
    end

    manager = start_supervised!({HarklightWakes, db: db, send_runner: runner})

    assert eventually(fn -> map_size(:sys.get_state(manager).workers) == 0 end)

    assert {:ok, _} =
             DB.query(
               db,
               "UPDATE harklight_wake_handles SET state='unavailable' WHERE handle=?1",
               [
                 @handle
               ]
             )

    result_task =
      Task.async(fn ->
        HarklightReconnect.reconnect(db, call, agent_runner: runner)
      end)

    assert %{outcome: "committed", feed_cursor: 1} = Task.await(result_task, 5_000)
    assert eventually(fn -> :sys.get_state(manager).reconnect_waiters == %{} end)
    assert File.exists?(connected_marker)
    assert eventually(fn -> File.exists?(idle_marker) end)
    refute File.exists?(events_marker)

    File.touch!(events_gate)

    assert eventually(fn ->
             DB.query(
               db,
               "SELECT count(*) FROM harklight_wake_entries WHERE handle=?1 AND eventId='1'",
               [@handle]
             ) == {:ok, [[1]]}
           end)

    assert File.exists?(events_marker)

    assert {:ok, [[1, 1]]} =
             DB.query(
               db,
               "SELECT count(*),lastCursor FROM harklight_wake_entries JOIN harklight_wake_handles USING(handle) WHERE handle=?1 AND eventId='1'",
               [@handle]
             )

    assert :ok = stop_supervised(HarklightWakes)
  end

  @tag :requires_wid247_child_wrapper
  test "worker death before reconnect handshake replies once and fences stale results", %{
    db: db,
    call: call
  } do
    root =
      Path.join(
        System.tmp_dir!(),
        "harklight-reconnect-worker-death-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(root)

    helper = Path.join(root, "tightbeam-child")
    agent = Path.join(root, "harklight-agent")
    started_marker = Path.join(root, "started")

    File.write!(helper, """
    #!/bin/sh
    printf 'TIGHTBEAM_CHILD_READY\\n'
    IFS= read -r command
    [ "$command" = continue ] || exit 31
    shift 4
    exec "$@"
    """)

    File.write!(agent, """
    #!/bin/sh
    case "$1" in
      reconnect)
        touch '#{started_marker}'
        while :; do sleep 1; done
        ;;
      *) exit 2 ;;
    esac
    """)

    File.chmod!(helper, 0o755)
    File.chmod!(agent, 0o755)

    old_path = System.get_env("PATH") || ""
    old_child_opts = Application.get_env(:tightbeam, :harklight_child_opts)
    System.put_env("PATH", root <> ":" <> old_path)

    Application.put_env(:tightbeam, :harklight_child_opts,
      base_dir: root,
      cli_path: helper
    )

    on_exit(fn ->
      System.put_env("PATH", old_path)

      if is_nil(old_child_opts),
        do: Application.delete_env(:tightbeam, :harklight_child_opts),
        else: Application.put_env(:tightbeam, :harklight_child_opts, old_child_opts)

      File.rm_rf!(root)
    end)

    assert {:ok, _} =
             DB.query(db, "UPDATE harklight_wake_handles SET state='complete' WHERE handle=?1", [
               @handle
             ])

    runner = fn
      ["status", "--session", @handle] -> {JSON.encode!(status(open_chats: 1)), 0}
      _args -> {"", 0}
    end

    manager =
      start_supervised!({HarklightWakes, db: db, send_runner: runner, retry_delays: [60_000]})

    assert eventually(fn -> map_size(:sys.get_state(manager).workers) == 0 end)

    assert {:ok, _} =
             DB.query(
               db,
               "UPDATE harklight_wake_handles SET state='unavailable' WHERE handle=?1",
               [@handle]
             )

    result_task =
      Task.async(fn ->
        HarklightReconnect.reconnect(db, call, agent_runner: runner)
      end)

    assert eventually(fn -> File.exists?(started_marker) end)

    state = :sys.get_state(manager)
    [{ref, _waiter}] = Map.to_list(state.reconnect_waiters)
    assert state.refs[ref] == @handle
    worker = state.workers[@handle]

    Process.exit(worker, :kill)

    assert %{
             outcome: "failed",
             reason_code: "harklight_reconnect_worker_failed",
             reason: "The reconnect worker exited before confirming the connection."
           } = Task.await(result_task, 5_000)

    assert eventually(fn ->
             settled = :sys.get_state(manager)

             not Map.has_key?(settled.reconnect_waiters, ref) and
               not Map.has_key?(settled.refs, ref)
           end)

    assert {:error, :listener_fenced} =
             GenServer.call(manager, {:reconnect_result, ref, {:ok, %{feed_cursor: 99}}})

    assert :sys.get_state(manager).reconnect_waiters == %{}

    assert :ok = stop_supervised(HarklightWakes)
  end

  @tag :requires_wid247_child_wrapper
  test "Agent reconnect refusal returns its sanitized reason and writes one DISCONNECT wake", %{
    db: db,
    call: call
  } do
    root =
      Path.join(
        System.tmp_dir!(),
        "harklight-reconnect-refusal-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(root)

    helper = Path.join(root, "tightbeam-child")
    agent = Path.join(root, "harklight-agent")

    refusal_line =
      JSON.encode!(%{
        "kind" => "refused",
        "session_handle" => @handle,
        "reason_code" => "transport_error",
        "reason" => "Agent refused the stream: token=reconnect-stream-secret"
      })

    File.write!(helper, """
    #!/bin/sh
    printf 'TIGHTBEAM_CHILD_READY\\n'
    IFS= read -r command
    [ "$command" = continue ] || exit 31
    shift 4
    exec "$@"
    """)

    File.write!(agent, """
    #!/bin/sh
    case "$1" in
      reconnect)
        printf '%s\\n' '#{refusal_line}'
        exit 5
        ;;
      *) exit 2 ;;
    esac
    """)

    File.chmod!(helper, 0o755)
    File.chmod!(agent, 0o755)

    old_path = System.get_env("PATH") || ""
    old_child_opts = Application.get_env(:tightbeam, :harklight_child_opts)
    System.put_env("PATH", root <> ":" <> old_path)

    Application.put_env(:tightbeam, :harklight_child_opts,
      base_dir: root,
      cli_path: helper
    )

    on_exit(fn ->
      System.put_env("PATH", old_path)

      if is_nil(old_child_opts),
        do: Application.delete_env(:tightbeam, :harklight_child_opts),
        else: Application.put_env(:tightbeam, :harklight_child_opts, old_child_opts)

      File.rm_rf!(root)
    end)

    assert {:ok, _} =
             DB.query(db, "UPDATE harklight_wake_handles SET state='complete' WHERE handle=?1", [
               @handle
             ])

    runner = fn
      ["status", "--session", @handle] -> {JSON.encode!(status(open_chats: 1)), 0}
      _args -> {"", 0}
    end

    manager =
      start_supervised!({HarklightWakes, db: db, send_runner: runner, retry_delays: [60_000]})

    assert eventually(fn -> map_size(:sys.get_state(manager).workers) == 0 end)

    assert {:ok, _} =
             DB.query(
               db,
               "UPDATE harklight_wake_handles SET state='unavailable' WHERE handle=?1",
               [
                 @handle
               ]
             )

    result =
      HarklightReconnect.reconnect(db, call, agent_runner: runner)

    assert result.outcome == "refused"
    assert result.reason_code == "transport_error"
    assert result.reason =~ "Agent refused the stream"
    assert result.reason =~ "[REDACTED:secret_field]"
    refute result.reason =~ "reconnect-stream-secret"

    assert {:ok, [[prompt]]} =
             DB.query(
               db,
               "SELECT prompt FROM wakes WHERE wakeId=?1",
               ["w_harklight_notice_recovery_" <> @handle]
             )

    assert String.starts_with?(prompt, "DISCONNECT: ")
    assert prompt =~ "message request"
    assert prompt =~ "thread #{@handle}"
    assert prompt =~ "RECONNECT failure: Agent refused the stream"
    assert prompt =~ "[REDACTED:secret_field]"
    refute prompt =~ "reconnect-stream-secret"

    assert {:ok, [[1]]} =
             DB.query(
               db,
               "SELECT count(*) FROM wakes WHERE wakeId=?1",
               ["w_harklight_notice_recovery_" <> @handle]
             )

    assert eventually(fn -> Map.has_key?(:sys.get_state(manager).retry_timers, @handle) end)

    assert :ok = stop_supervised(HarklightWakes)
  end

  test "fully idle Agent status refuses reconnect", %{db: db, call: call} do
    result =
      HarklightReconnect.reconnect(db, call,
        agent_runner: status_runner(@handle, status(open_chats: 0)),
        reconnector: fn _handle, _caller -> flunk("closed chat must not reconnect") end
      )

    assert result.outcome == "refused"
    assert result.reason_code == "harklight_chat_closed"
  end

  test "a reconnect refusal produces one sanitized DISCONNECT wake with its reason", %{db: db} do
    parent = self()
    runner = status_runner(@handle, status(open_chats: 1))

    listener = fn manager, handle, _vendor_id ->
      :ok = GenServer.call(manager, {:attached, handle})

      refusal =
        {:harklight_failure, {"harklight_reconnect_failed", "transport_error"}, "reconnect",
         "Agent refused the stream: token=reconnect-secret-canary"}

      :ok = GenServer.call(manager, {:finished, handle, refusal})
      send(parent, :reconnect_refusal_recorded)

      receive do
        :stop -> :ok
      end
    end

    start_supervised!(
      {HarklightWakes, db: db, listener: listener, send_runner: runner, retry_delays: []}
    )

    assert_receive :reconnect_refusal_recorded

    assert {:ok, [[prompt]]} =
             DB.query(
               db,
               "SELECT prompt FROM wakes WHERE wakeId=?1",
               ["w_harklight_notice_recovery_" <> @handle]
             )

    assert String.starts_with?(prompt, "DISCONNECT: ")
    assert prompt =~ "message request"
    assert prompt =~ "thread #{@handle}"
    assert prompt =~ "RECONNECT failure:"
    assert prompt =~ "Agent refused the stream"
    assert prompt =~ "[REDACTED:secret_field]"
    refute prompt =~ "reconnect-secret-canary"

    assert {:ok, [[1]]} =
             DB.query(
               db,
               "SELECT count(*) FROM wakes WHERE wakeId=?1",
               ["w_harklight_notice_recovery_" <> @handle]
             )
  end

  test "Agent reconnect stream lines confirm the same handle before delivering journal entries",
       %{} do
    connected = ~s({"kind":"reconnected","session_handle":"#{@handle}","feed_cursor":8})
    event = ~s({"kind":"event","session_handle":"#{@handle}","event_id":"8"})
    foreign = ~s({"kind":"event","session_handle":"different-handle","event_id":"8"})
    idle = ~s({"kind":"idle","session_handle":"#{@handle}","open_requests":0})
    foreign_idle = ~s({"kind":"idle","session_handle":"different-handle","open_requests":0})

    assert {:connected, 8} = HarklightReconnect.parse_agent_line(connected, @handle)
    assert {:event, ^event} = HarklightReconnect.parse_agent_line(event, @handle)
    assert :idle = HarklightReconnect.parse_agent_line(idle, @handle)

    assert {:error, :connection_error, "harklight_reconnect_unconfirmed", reason, nil} =
             HarklightReconnect.parse_agent_line(foreign, @handle)

    assert reason =~ "different Harklight handle"

    assert {:error, :connection_error, "harklight_reconnect_unconfirmed", idle_reason, nil} =
             HarklightReconnect.parse_agent_line(foreign_idle, @handle)

    assert idle_reason =~ "different Harklight handle"
  end

  test "Agent reconnect stream refusal keeps its sanitized reason and retry uncertainty", %{} do
    refusal =
      ~s({"kind":"refused","session_handle":"#{@handle}","reason_code":"transport_error","reason":"refused token=stream-secret-canary"})

    unknown =
      ~s({"kind":"outcome_unknown","session_handle":"#{@handle}","reason_code":"transport_error","reason":"reconnect reply uncertain","op_id":"op-stream"})

    assert {:error, :refused, "transport_error", reason, nil} =
             HarklightReconnect.parse_agent_line(refusal, @handle)

    assert reason =~ "[REDACTED:secret_field]"
    refute reason =~ "stream-secret-canary"

    assert {:error, :outcome_unknown, "transport_error", "reconnect reply uncertain", "op-stream"} =
             HarklightReconnect.parse_agent_line(unknown, @handle)
  end

  defp assert_closed_without_reconnect(db, call) do
    result =
      HarklightReconnect.reconnect(db, call,
        agent_runner: status_runner(@handle, status(open_chats: 1)),
        reconnector: fn _handle, _caller -> flunk("terminal chat must not reconnect") end
      )

    assert result.outcome == "refused"
    assert result.reason_code == "harklight_chat_closed"
  end

  defp end_message(db, :subscription) do
    DB.query(
      db,
      "INSERT INTO harklight_subscription_ends(senderId,messageId,handle,opId,replacementId,state,acknowledgment) VALUES('sender','request',?1,'terminal:answer',NULL,'ended','not_needed')",
      [@handle]
    )
  end

  defp end_message(db, :terminal_follow) do
    DB.query(
      db,
      "INSERT INTO harklight_follow_message_ends(senderId,messageId,handle,opId,replacementId,endedBySessionKey,endKind) VALUES('sender','request',?1,'terminal:no-comment',NULL,NULL,'terminal')",
      [@handle]
    )
  end

  defp status_runner(handle, value) do
    fn
      ["status", "--session", ^handle] -> {JSON.encode!(value), 0}
      args -> flunk("unexpected Agent command: #{inspect(args)}")
    end
  end

  defp status(handle, opts) do
    %{
      "session_handle" => handle,
      "open_requests" => Keyword.get(opts, :open_requests, 1),
      "open_chats" => Keyword.get(opts, :open_chats, 1),
      "pending_undelivered" => Keyword.get(opts, :pending_undelivered, 0),
      "pending_delivered_unacted" => Keyword.get(opts, :pending_delivered_unacted, 0)
    }
  end
end
