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

    for filters <- [%{}, %{"sessionKey" => "sibling"}] do
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

    send_frame(retry, %{post | id: "c_big", content: String.duplicate("x", 65_537)})
    {error, retry} = recv_frame(retry)
    assert error["code"] == "payload_too_large"
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

  test "missing operation identity and unauthorized selected sessions cannot authenticate", ctx do
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
      {reply, socket} = recv_frame(socket)

      if path == "/ws/changes?protocolVersion=2" and overrides[:token] == ctx.selected.cli_token do
        assert reply["success"] == true
        assert reply["userId"] == "reader"
        assert reply["sessionKey"] == "selected"
      else
        assert reply["success"] == false
      end

      WS.close(socket)
    end

    assert {:ok, [[0]]} = DB.query(ctx.db, "SELECT COUNT(*) FROM messages")
    assert {:ok, [[0]]} = DB.query(ctx.db, "SELECT COUNT(*) FROM devices")
  end

  test "ordinary post rule refusal is correlated and creates no message or ack", ctx do
    rules_dir = Path.join(ctx.base, "identity/rules")
    File.mkdir_p!(rules_dir)

    File.write!(Path.join(rules_dir, "post.toml"), """
    [[rule]]
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
    {:push, {:text, bytes}, live} = ChangeSocket.handle_info(:firehose_heartbeat, live)
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
