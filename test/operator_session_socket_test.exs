defmodule Tightbeam.Wire.OperatorSessionSocketTest do
  use Tightbeam.TestCase, async: false

  alias Tightbeam.{ConnRegistry, DB, Devices, Gateway, Model, Org, Rules}
  alias Tightbeam.ClientE2E.WS
  alias Tightbeam.Firehose.Hub
  alias Tightbeam.Wire.Router

  defmodule LaneDoorbell do
    use GenServer

    def start_link(parent),
      do: GenServer.start_link(__MODULE__, parent, name: Tightbeam.LaneManager)

    def init(parent), do: {:ok, parent}

    def handle_call({:ensure_lane, key}, _from, parent) do
      send(parent, {:ensure_lane, key})
      {:reply, :ok, parent}
    end
  end

  setup do
    db = :"operator_socket_db_#{System.unique_integer([:positive])}"
    hub = Hub
    start_supervised!({DB, path: ":memory:", name: db})
    start_supervised!({Hub, name: hub})
    start_supervised!({ConnRegistry, name: Tightbeam.ConnRegistry})
    start_supervised!({LaneDoorbell, self()})
    :ok = Tightbeam.Schema.ensure_all(db)
    Devices.add_user(db, "reader", false)
    Devices.set_user_admin(db, "reader", false)
    Devices.add_user(db, "other", false)

    selected = session(db, "selected", "reader")
    sibling = session(db, "sibling", "reader")
    foreign = session(db, "foreign", "other")
    base = Path.join(System.tmp_dir!(), "operator-socket-#{System.unique_integer([:positive])}")
    handlers = Gateway.handlers(%{db: db, base_dir: base, port: 0})
    Rules.load!(base, Map.keys(handlers))

    on_exit(fn ->
      File.rm_rf!(base)
      Rules.load!(base, [])
    end)

    opts =
      Router.init(
        db: db,
        base_dir: base,
        handlers: handlers,
        cli_token: "operator-fixture",
        firehose_hub: hub,
        model_catalog: %{},
        conn_registry: Tightbeam.ConnRegistry,
        ping_interval_ms: 60_000,
        pong_timeout_ms: 60_000
      )

    server =
      start_supervised!(
        {Bandit, plug: {Router, opts}, port: 0, ip: {127, 0, 0, 1}, startup_log: false}
      )

    {:ok, {_, port}} = ThousandIsland.listener_info(server)

    %{
      db: db,
      hub: hub,
      port: port,
      selected: selected,
      sibling: sibling,
      foreign: foreign,
      base: base,
      handlers: handlers
    }
  end

  test "operator service gets scoped Firehose and real human post ack with stable retry identity",
       ctx do
    changes = connect(ctx, "/ws/changes?protocolVersion=2")
    send_frame(changes, auth())
    {reply, changes} = recv_frame(changes)

    assert %{
             "type" => "auth_result",
             "success" => true,
             "userId" => "reader",
             "isAdmin" => false,
             "sessionKey" => "selected"
           } = reply

    for filters <- [
          %{},
          %{"sessionKey" => "sibling"},
          %{"archetype" => "product-owner"}
        ] do
      send_frame(changes, %{type: "subscribe", subscriptionId: "bad", filters: filters})
      {reply, _} = recv_frame(changes)
      assert reply["code"] == "invalid_request"
    end

    send_frame(changes, %{
      type: "subscribe",
      protocolVersion: 2,
      subscriptionId: "selected",
      filters: %{sessionKey: "selected", classes: ["message."]}
    })

    {ready, changes} = recv_frame(changes)
    assert ready == %{"type" => "subscription_ready", "subscriptionId" => "selected"}

    chat = connect(ctx, "/ws")

    send_frame(
      chat,
      Map.merge(auth(), %{deviceId: "browser-continuity", subscriptions: ["chat"]})
    )

    {ready, chat} = recv_frame(chat)
    assert ready["success"] == true
    assert ready["sessionKeys"] == ["selected"]
    assert ready["replayCount"] == 0
    {sync, chat} = recv_frame(chat)
    assert sync == %{"type" => "sync_complete"}
    assert {:ok, [[0]]} = DB.query(ctx.db, "SELECT COUNT(*) FROM devices")

    {:appended, _} =
      Tightbeam.Projection.append(ctx.db, %{
        session_key: "sibling",
        role: "assistant",
        content: "another conversation"
      })

    post = %{type: "message", id: "c_once", sessionKey: "selected", content: "hello exactly"}
    send_frame(chat, post)
    {ack, chat} = recv_frame(chat)
    assert ack == %{"type" => "ack", "id" => "c_once"}
    assert_receive {:ensure_lane, "selected"}

    assert {:ok, [[message_id, "browser-continuity", "c_once", "hello exactly"]]} =
             DB.query(
               ctx.db,
               "SELECT id,deviceId,clientMessageId,content FROM messages WHERE sessionKey='selected'"
             )

    assert {:ok, [["user:reader"]]} =
             DB.query(ctx.db, "SELECT origin FROM turns WHERE messageId=?1", [message_id])

    assert {:ok, [["user:reader"]]} =
             DB.query(
               ctx.db,
               "SELECT principal FROM events WHERE verb='post' AND kind='verb'"
             )

    {notice, _changes} = recv_frame(changes)
    assert notice["class"] == "message.created"
    assert notice["refs"]["sessionKey"] == "selected"
    assert notice["refs"]["messageId"] == message_id

    WS.close(chat)
    retry = connect(ctx, "/ws")
    send_frame(retry, Map.put(auth(), :deviceId, "browser-continuity"))
    {_auth, retry} = recv_frame(retry)
    {_sync, retry} = recv_frame(retry)
    send_frame(retry, post)
    {ack, retry} = recv_frame(retry)
    assert ack == %{"type" => "ack", "id" => "c_once"}
    send_frame(retry, %{post | content: "changed"})
    {conflict, retry} = recv_frame(retry)
    assert %{"code" => "invalid_message", "messageId" => "c_once"} = conflict

    for key <- ["sibling", "foreign"] do
      send_frame(retry, %{post | sessionKey: key, id: "c_wrong"})
      {error, _} = recv_frame(retry)
      assert %{"code" => "not_found", "messageId" => "c_wrong"} = error
    end

    send_frame(retry, %{post | id: "invalid"})
    {error, retry} = recv_frame(retry)
    assert error["code"] == "invalid_message"
    send_frame(retry, %{type: "stream_read", sessionKey: "sibling", lastReadMessageId: "other"})
    {error, _} = recv_frame(retry)
    assert error["code"] == "invalid_message"

    assert {:ok, [[1]]} =
             DB.query(ctx.db, "SELECT COUNT(*) FROM messages WHERE sessionKey='selected'")

    assert {:ok, [[1]]} = DB.query(ctx.db, "SELECT COUNT(*) FROM turns")
  end

  test "accepts and delivers a human prompt above 64 KiB without changing it", ctx do
    changes = connect(ctx, "/ws/changes?protocolVersion=2")
    send_frame(changes, auth())
    {_auth_reply, changes} = recv_frame(changes)

    send_frame(changes, %{
      type: "subscribe",
      protocolVersion: 2,
      subscriptionId: "large-prompt",
      filters: %{sessionKey: "selected", classes: ["message."]}
    })

    {ready, changes} = recv_frame(changes)
    assert ready == %{"type" => "subscription_ready", "subscriptionId" => "large-prompt"}

    chat = connect(ctx, "/ws")
    send_frame(chat, Map.put(auth(), :deviceId, "browser-large-prompt"))
    {auth_reply, chat} = recv_frame(chat)
    assert auth_reply["success"] == true
    {_sync, chat} = recv_frame(chat)

    content = String.duplicate("x", 65_537)
    bytes = byte_size(content)
    assert bytes > 64 * 1024

    message = %{
      type: "message",
      id: "c_multi_mib",
      sessionKey: "selected",
      content: content
    }

    frame = JSON.encode!(message)
    assert byte_size(frame) < 2 * 1024 * 1024
    assert :ok = WS.send_text(chat, frame)

    {ack, chat} = recv_frame(chat)
    assert ack == %{"type" => "ack", "id" => "c_multi_mib"}
    assert_receive {:ensure_lane, "selected"}

    assert {:ok, [[message_id, stored, stored_bytes]]} =
             DB.query(
               ctx.db,
               "SELECT id,content,length(CAST(content AS BLOB)) FROM messages WHERE clientMessageId=?1",
               ["c_multi_mib"]
             )

    assert stored == content
    assert stored_bytes == bytes

    assert {:ok, [["user:reader"]]} =
             DB.query(ctx.db, "SELECT origin FROM turns WHERE messageId=?1", [message_id])

    {notice, _changes} = recv_frame(changes)
    assert notice["class"] == "message.created"
    assert notice["refs"]["sessionKey"] == "selected"
    assert notice["refs"]["messageId"] == message_id
  end

  test "missing user identity and unauthorized selected sessions cannot authenticate", ctx do
    for path <- ["/ws", "/ws/changes?protocolVersion=2"],
        overrides <- [
          %{asUser: nil},
          %{asUser: "missing"},
          %{sessionKey: nil},
          %{sessionKey: "foreign"},
          %{token: "bad"},
          %{token: ctx.selected.cli_token, asUser: "other"}
        ] do
      # A session token retains its pre-existing Firehose identity and never
      # becomes the named user just because asUser was supplied.
      socket = connect(ctx, path)
      send_frame(socket, auth() |> Map.put(:deviceId, "browser") |> Map.merge(overrides))

      if path == "/ws/changes?protocolVersion=2" and overrides[:token] == "bad" do
        send_frame(socket, %{
          type: "subscribe",
          protocolVersion: 2,
          subscriptionId: "observer",
          filters: %{classes: ["session."]}
        })

        {ready, socket} = recv_frame(socket)
        assert ready == %{"type" => "subscription_ready", "subscriptionId" => "observer"}

        Hub.publish(ctx.hub, %{
          "class" => "session.updated",
          "refs" => %{"sessionKey" => "foreign"},
          "payload" => %{"sessionKey" => "foreign", "rowVersion" => 1}
        })

        {change, socket} = recv_frame(socket)
        assert change["type"] == "change"
        assert change["subscriptionId"] == "observer"
        assert change["class"] == "session.updated"
        assert change["refs"]["sessionKey"] == "foreign"
      else
        {reply, socket} = recv_frame(socket)
        org_wide_identity? = Map.has_key?(overrides, :sessionKey) and is_nil(overrides.sessionKey)

        if path == "/ws/changes?protocolVersion=2" and
             (overrides[:token] == ctx.selected.cli_token or org_wide_identity?) do
          assert reply["success"] == true
          assert reply["userId"] == "reader"

          if overrides[:token] == ctx.selected.cli_token do
            assert reply["sessionKey"] == "selected"
          else
            refute Map.has_key?(reply, "sessionKey")
          end
        else
          assert reply["success"] == false
        end
      end

      WS.close(socket)
    end

    assert {:ok, [[0]]} = DB.query(ctx.db, "SELECT COUNT(*) FROM messages")
    assert {:ok, [[0]]} = DB.query(ctx.db, "SELECT COUNT(*) FROM devices")
  end

  test "organization bearer without asUser uses the default org read principal", ctx do
    changes = connect(ctx, "/ws/changes?protocolVersion=2")
    send_frame(changes, %{type: "auth", token: "operator-fixture"})
    {auth_result, changes} = recv_frame(changes)

    assert %{
             "type" => "auth_result",
             "success" => true,
             "userId" => "org",
             "isAdmin" => true
           } = auth_result

    send_frame(changes, %{
      type: "subscribe",
      protocolVersion: 2,
      subscriptionId: "all",
      filters: %{classes: ["session."]}
    })

    {ready, changes} = recv_frame(changes)
    assert ready == %{"type" => "subscription_ready", "subscriptionId" => "all"}

    Hub.publish(ctx.hub, %{
      "class" => "session.updated",
      "refs" => %{"sessionKey" => "foreign"},
      "payload" => %{"sessionKey" => "foreign", "rowVersion" => 1}
    })

    {change, _changes} = recv_frame(changes)
    assert change["type"] == "change"
    assert change["refs"]["sessionKey"] == "foreign"
  end

  test "organization bearer without asUser selects the default admin user", ctx do
    Devices.set_user_admin(ctx.db, "reader", true)
    changes = connect(ctx, "/ws/changes?protocolVersion=2")
    send_frame(changes, %{type: "auth", token: "operator-fixture"})
    {auth_result, _changes} = recv_frame(changes)

    assert %{
             "type" => "auth_result",
             "success" => true,
             "userId" => "reader",
             "isAdmin" => true
           } = auth_result
  end

  test "organization bearer receives matching events for each subscribed filter", ctx do
    changes = connect(ctx, "/ws/changes?protocolVersion=2")
    send_frame(changes, %{type: "auth", token: "operator-fixture", asUser: "reader"})
    {auth_result, changes} = recv_frame(changes)

    assert %{
             "type" => "auth_result",
             "success" => true,
             "userId" => "reader",
             "isAdmin" => false
           } = auth_result

    refute Map.has_key?(auth_result, "sessionKey")

    send_frame(changes, %{
      type: "subscribe",
      protocolVersion: 2,
      subscriptionId: "all",
      filters: %{classes: ["session."]}
    })

    {ready, changes} = recv_frame(changes)
    assert ready == %{"type" => "subscription_ready", "subscriptionId" => "all"}

    send_frame(changes, %{
      type: "subscribe",
      protocolVersion: 2,
      subscriptionId: "sibling",
      filters: %{sessionKey: "sibling", classes: ["session."]}
    })

    {ready, changes} = recv_frame(changes)
    assert ready == %{"type" => "subscription_ready", "subscriptionId" => "sibling"}

    Hub.publish(ctx.hub, %{
      "class" => "session.updated",
      "refs" => %{"sessionKey" => "foreign"},
      "payload" => %{"sessionKey" => "foreign", "rowVersion" => 1}
    })

    Hub.publish(ctx.hub, %{
      "class" => "session.updated",
      "refs" => %{"sessionKey" => "sibling"},
      "payload" => %{"sessionKey" => "sibling", "rowVersion" => 1}
    })

    {foreign_change, changes} = recv_frame(changes)
    assert foreign_change["type"] == "change"
    assert foreign_change["subscriptionId"] == "all"
    assert foreign_change["refs"]["sessionKey"] == "foreign"

    {all_change, changes} = recv_frame(changes)
    assert all_change["type"] == "change"
    assert all_change["subscriptionId"] == "all"
    assert all_change["refs"]["sessionKey"] == "sibling"

    {session_change, changes} = recv_frame(changes)
    assert session_change["type"] == "change"
    assert session_change["subscriptionId"] == "sibling"
    assert session_change["refs"]["sessionKey"] == "sibling"

    assert {:error, :timeout, _changes} = WS.recv(changes, 100)
  end

  test "ordinary post rule refusal is correlated and creates no message or ack", ctx do
    rules_dir = Path.join(ctx.base, "identity/rules")
    File.mkdir_p!(rules_dir)

    File.write!(Path.join(rules_dir, "post.toml"), """
    [[rule]]
    archetypes = ["*"]
    name = "post-disabled"
    verb = "post"
    deny_when = [{ fact = "caller.origin_class", op = "eq", value = "user" }]
    text = "chat paused"
    """)

    Rules.load!(ctx.base, Map.keys(ctx.handlers))

    chat = connect(ctx, "/ws")
    send_frame(chat, Map.put(auth(), :deviceId, "browser"))
    {_auth, chat} = recv_frame(chat)
    {_sync, chat} = recv_frame(chat)
    send_frame(chat, %{type: "message", id: "c_denied", sessionKey: "selected", content: "no"})
    {error, _} = recv_frame(chat)
    assert %{"type" => "error", "code" => "rule_denied", "messageId" => "c_denied"} = error
    assert {:ok, [[0]]} = DB.query(ctx.db, "SELECT COUNT(*) FROM messages")
  end

  test "ordinary post escalation returns a correlated pending decision without an ack", ctx do
    rules_dir = Path.join(ctx.base, "identity/rules")
    File.mkdir_p!(rules_dir)

    File.write!(Path.join(rules_dir, "post.toml"), """
    [[rule]]
    archetypes = ["*"]
    name = "post-decision"
    verb = "post"
    effect = "escalate"
    deny_when = [{ fact = "caller.origin_class", op = "eq", value = "user" }]
    text = "chat needs a decision"
    """)

    Rules.load!(ctx.base, Map.keys(ctx.handlers))
    chat = connect(ctx, "/ws")
    send_frame(chat, Map.put(auth(), :deviceId, "browser"))
    {_auth, chat} = recv_frame(chat)
    {_sync, chat} = recv_frame(chat)
    send_frame(chat, %{type: "message", id: "c_pending", sessionKey: "selected", content: "no"})
    {reply, _} = recv_frame(chat)
    assert %{"type" => "error", "code" => "decision_pending", "messageId" => "c_pending"} = reply

    assert {:ok, [[0]]} =
             DB.query(ctx.db, "SELECT COUNT(*) FROM messages WHERE sessionKey='selected'")

    assert {:ok, [[1]]} =
             DB.query(
               ctx.db,
               "SELECT COUNT(*) FROM decision_requests WHERE statuteName='post-decision'"
             )
  end

  test "service Firehose heartbeat retains the selected user principal", ctx do
    alias Tightbeam.Wire.ChangeSocket

    {:ok, initial} =
      ChangeSocket.init(%{
        db: ctx.db,
        firehose_hub: ctx.hub,
        cli_token: "operator-fixture",
        firehose_heartbeat_ms: 60_000
      })

    {:push, _, live} = ChangeSocket.handle_in({JSON.encode!(auth()), opcode: :text}, initial)

    {:push, [{:text, bytes}, {:ping, <<>>}], live} =
      ChangeSocket.handle_info(:firehose_heartbeat, live)

    assert JSON.decode!(bytes)["type"] == "heartbeat"

    :ok =
      DB.execute(ctx.db, "UPDATE sessions SET ownerUserId='other' WHERE sessionKey='selected'")

    assert {:stop, :normal, 1008, _} = ChangeSocket.handle_info(:firehose_heartbeat, live)
    ChangeSocket.terminate(:normal, live)
  end

  test "unavailable selected session does not acknowledge an unaccepted post", ctx do
    chat = connect(ctx, "/ws")
    send_frame(chat, Map.put(auth(), :deviceId, "browser"))
    {_auth, chat} = recv_frame(chat)
    {_sync, chat} = recv_frame(chat)
    :ok = DB.execute(ctx.db, "DELETE FROM sessions WHERE sessionKey='selected'")
    send_frame(chat, %{type: "message", id: "c_missing", sessionKey: "selected", content: "no"})
    {error, _} = recv_frame(chat)
    assert %{"type" => "error", "code" => "not_found", "messageId" => "c_missing"} = error

    assert {:ok, [[0]]} =
             DB.query(ctx.db, "SELECT COUNT(*) FROM messages WHERE sessionKey='selected'")
  end

  test "REST accepts escaped unicode and control text above the former content cap", ctx do
    content = String.duplicate("é\"\n\u0001", 20_000)

    body =
      JSON.encode!(%{
        verb: "post",
        asUser: "reader",
        sessionKey: "selected",
        params: %{
          clientMessageId: "c_escaped_unicode",
          deviceId: "browser-escaped",
          content: content
        }
      })
      |> String.replace("é", "\\u00e9")

    assert byte_size(content) > 65_536
    assert byte_size(body) > byte_size(content)
    {200, accepted} = http_post(ctx.port, body)
    assert accepted["result"]["outcome"] == "recorded"
    assert {:ok, [[stored]]} = DB.query(ctx.db, "SELECT content FROM messages")
    assert stored == content
    {200, duplicate} = http_post(ctx.port, body)

    assert duplicate["result"] ==
             accepted["result"]
             |> Map.delete("ack")
             |> Map.merge(%{"outcome" => "duplicate", "dedupe" => "duplicate"})
  end

  test "REST body boundary refuses before recording and keeps the send identity reusable", ctx do
    body = %{
      verb: "post",
      asUser: "reader",
      sessionKey: "selected",
      params: %{clientMessageId: "c_body_boundary", deviceId: "browser-body", content: ""}
    }

    overhead = byte_size(JSON.encode!(body))
    oversized = put_in(body, [:params, :content], String.duplicate("x", 8_000_001 - overhead))
    {status, refused} = http_post(ctx.port, JSON.encode!(oversized))
    assert status == 413
    assert refused["error"]["code"] == "invalid_message"
    assert refused["error"]["message"] == "request body too large"

    for table <- ["messages", "turns", "wakes"] do
      assert {:ok, [[0]]} = DB.query(ctx.db, "SELECT COUNT(*) FROM #{table}")
    end

    # Same identity after a refusal, with the body shortened to the transport boundary.
    permitted = put_in(body, [:params, :content], String.duplicate("x", 8_000_000 - overhead))
    {status, accepted} = http_post(ctx.port, JSON.encode!(permitted))
    assert status == 200
    assert accepted["result"]["outcome"] == "recorded"
    assert {:ok, [[stored]]} = DB.query(ctx.db, "SELECT content FROM messages")
    assert stored == permitted.params.content
    assert_receive {:ensure_lane, "selected"}
    {200, duplicate} = http_post(ctx.port, JSON.encode!(permitted))

    assert duplicate["result"] ==
             accepted["result"]
             |> Map.delete("ack")
             |> Map.merge(%{"outcome" => "duplicate", "dedupe" => "duplicate"})

    assert {:ok, [[1]]} = DB.query(ctx.db, "SELECT COUNT(*) FROM messages")
    assert {:ok, [[1]]} = DB.query(ctx.db, "SELECT COUNT(*) FROM turns")

    under = put_in(body, [:params, :clientMessageId], "c_body_under___")
    overhead = byte_size(JSON.encode!(under))

    under =
      put_in(under, [:params, :content], String.duplicate("é", div(7_999_999 - overhead, 2)))

    {200, accepted_under} = http_post(ctx.port, JSON.encode!(under))
    assert accepted_under["result"]["outcome"] == "recorded"

    assert {:ok, [[stored_under]]} =
             DB.query(ctx.db, "SELECT content FROM messages WHERE clientMessageId=?1", [
               under.params.clientMessageId
             ])

    assert stored_under == under.params.content
  end

  defp http_post(port, body) do
    {:ok, socket} = :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false])

    request = [
      "POST /agent/dispatch HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n",
      "Authorization: Bearer operator-fixture\r\n",
      "x-tightbeam-cli-version: ",
      Tightbeam.CliCompatibility.required_version(),
      "\r\n",
      "Content-Type: application/json\r\nContent-Length: ",
      Integer.to_string(byte_size(body)),
      "\r\n\r\n",
      body
    ]

    :ok = :gen_tcp.send(socket, request)
    response = read_http(socket, [])
    :gen_tcp.close(socket)
    [headers, payload] = String.split(response, "\r\n\r\n", parts: 2)
    [_, status | _] = String.split(headers, " ", parts: 3)
    assert payload != "", "HTTP response has no JSON: #{headers}"
    {String.to_integer(status), JSON.decode!(payload)}
  end

  defp read_http(socket, chunks) do
    case :gen_tcp.recv(socket, 0, 30_000) do
      {:ok, chunk} ->
        read_http(socket, [chunks, chunk])

      {:error, :closed} ->
        IO.iodata_to_binary(chunks)

      {:error, :econnreset} ->
        response = IO.iodata_to_binary(chunks)

        assert String.starts_with?(response, "HTTP/1.1 413 "),
               "HTTP connection reset before a 413 response was received"

        response

      other ->
        flunk("HTTP response read failed: #{inspect(other)}")
    end
  end

  defp auth,
    do: %{type: "auth", token: "operator-fixture", asUser: "reader", sessionKey: "selected"}

  defp connect(ctx, path) do
    {:ok, socket} = WS.connect("127.0.0.1", ctx.port, path)
    on_exit(fn -> WS.close(socket) end)
    socket
  end

  defp send_frame(socket, message), do: WS.send_text(socket, JSON.encode!(message))

  defp recv_frame(socket) do
    {:ok, {:text, bytes}, socket} = WS.recv(socket, 2_000)
    {JSON.decode!(bytes), socket}
  end

  defp session(db, key, owner) do
    Org.create(db, %{
      session_key: key,
      display_name: key,
      owner_user_id: owner,
      origin: "user:#{owner}",
      archetype: "default",
      host: "testhost",
      harness: "claude",
      provider: "anthropic",
      model: Model.new("fable")
    })
  end
end
