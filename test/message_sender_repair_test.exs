defmodule Tightbeam.MessageSenderRepairTest do
  use Tightbeam.TestCase, async: false

  alias Tightbeam.{DB, Projection}

  setup do
    name = :"sender_repair_#{System.unique_integer([:positive])}"
    start_supervised!({DB, path: ":memory:", name: name})
    :ok = Projection.ensure_schema(name)

    :ok =
      DB.execute(name, """
      CREATE TABLE sessions (sessionKey TEXT PRIMARY KEY, ownerUserId TEXT);
      CREATE TABLE turns (
        seq INTEGER PRIMARY KEY AUTOINCREMENT,
        sessionKey TEXT NOT NULL,
        messageId TEXT NOT NULL,
        origin TEXT NOT NULL
      );
      CREATE TABLE wakes (
        wakeId TEXT PRIMARY KEY,
        origin TEXT NOT NULL,
        sourceClientIdentity TEXT
      );
      CREATE UNIQUE INDEX notice_source_client_identity ON wakes (
        json_extract(sourceClientIdentity,'$.targetSessionKey'),
        json_extract(sourceClientIdentity,'$.deviceId'),
        json_extract(sourceClientIdentity,'$.clientMessageId')
      ) WHERE sourceClientIdentity IS NOT NULL;
      """)

    %{db: name}
  end

  test "repair uses recorded turn, source wake, then owner and leaves unresolved rows null", %{
    db: db
  } do
    for session_key <- ["turn-session", "wake-session", "owner-session"] do
      assert {:ok, []} =
               DB.query(db, "INSERT INTO sessions(sessionKey,ownerUserId) VALUES(?1,'owner')", [
                 session_key
               ])
    end

    turn_message = human_message!(db, "turn-session", "turn-device", "turn-client")
    wake_message = human_message!(db, "wake-session", "wake-device", "wake-client")
    _owner_message = human_message!(db, "owner-session", nil, nil)
    unresolved_message = human_message!(db, "no-session", nil, nil)
    ambiguous_message = human_message!(db, "no-session", nil, nil)

    assert {:ok, []} =
      DB.query(db, "INSERT INTO turns(sessionKey,messageId,origin) VALUES(?1,?2,?3)", [
        "turn-session",
        turn_message.id,
        "user:turn"
      ])

    for origin <- ["user:first", "user:second"] do
      assert {:ok, []} =
               DB.query(db, "INSERT INTO turns(sessionKey,messageId,origin) VALUES(?1,?2,?3)", [
                 "no-session",
                 ambiguous_message.id,
                 origin
               ])
    end

    add_source_wake!(db, "turn-source", "turn-session", "turn-device", "turn-client", "user:wake")
    add_source_wake!(db, "wake-source", "wake-session", "wake-device", "wake-client", "user:wake")

    assert %{turn: 1, wake: 1, owner: 1, left_null: 2} =
             Projection.repair_missing_human_senders(db)

    assert {:ok,
            [
              ["turn-client", "user:turn"],
              ["wake-client", "user:wake"],
              [nil, "user:owner"],
              [nil, nil],
              [nil, nil]
            ]} =
             DB.query(
               db,
               "SELECT clientMessageId,sender FROM messages ORDER BY seq"
             )

    assert %{turn: 0, wake: 0, owner: 0, left_null: 2} =
             Projection.repair_missing_human_senders(db)

    assert {:ok, [[nil]]} =
             DB.query(db, "SELECT sender FROM messages WHERE id=?1", [unresolved_message.id])
  end

  test "schema startup repairs stored senders without advancing the root or effort epoch" do
    name = :"sender_repair_schema_#{System.unique_integer([:positive])}"
    start_supervised!({DB, path: ":memory:", name: name})
    :ok = ensure_all_schemas(name)

    {:appended, message} =
      Projection.append(name, %{
        session_key: "historical-session",
        role: "user",
        content: "historical human post",
        device_id: "historical-device",
        client_message_id: "historical-client"
      })

    {:ok, _turn_seq} =
      Tightbeam.Ledger.enqueue(name, %{
        session_key: "historical-session",
        message_id: message.id,
        origin: "user:recorded-turn",
        prompt: "historical human post"
      })

    {:ok, root_before} = DB.query(name, "SELECT shape,stampedAt FROM schema_stamp")
    {:ok, effort_before} = DB.query(name, "SELECT * FROM effort_holder_activity_cancellation_epoch")

    :ok = ensure_all_schemas(name)

    assert {:ok, [["user:recorded-turn"]]} =
             DB.query(name, "SELECT sender FROM messages WHERE id=?1", [message.id])

    assert {:ok, ^root_before} = DB.query(name, "SELECT shape,stampedAt FROM schema_stamp")

    assert {:ok, ^effort_before} =
             DB.query(name, "SELECT * FROM effort_holder_activity_cancellation_epoch")
  end

  defp human_message!(db, session_key, device_id, client_message_id) do
    attrs = %{
      session_key: session_key,
      role: "user",
      content: "historical human post"
    }

    attrs =
      attrs
      |> maybe_put(:device_id, device_id)
      |> maybe_put(:client_message_id, client_message_id)

    {:appended, message} = Projection.append(db, attrs)
    message
  end

  defp add_source_wake!(db, wake_id, session_key, device_id, client_message_id, origin) do
    identity =
      Tightbeam.JSON.encode!(%{
        "targetSessionKey" => session_key,
        "deviceId" => device_id,
        "clientMessageId" => client_message_id,
        "sourceWakeId" => wake_id,
        "payloadSha256" => String.duplicate("a", 64),
        "createdAt" => 1
      })

    assert {:ok, []} =
      DB.query(db, "INSERT INTO wakes(wakeId,origin,sourceClientIdentity) VALUES(?1,?2,?3)", [
        wake_id,
        origin,
        identity
      ])
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
