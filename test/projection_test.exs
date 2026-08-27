defmodule Tightbeam.ProjectionTest do
  use Tightbeam.TestCase, async: false

  alias Tightbeam.{DB, Projection, StateResources}

  setup do
    name = :"db_#{System.unique_integer([:positive])}"
    start_supervised!({DB, path: ":memory:", name: name})
    :ok = Projection.ensure_schema(name)
    %{db: name}
  end

  test "append persists load-bearing fields, JSON attachments, and provider-visible id", %{db: db} do
    assert {:appended, message} =
             Projection.append(db, %{
               session_key: "k1",
               role: "user",
               content: "hi",
               timestamp: 5000,
               device_id: "dev-1",
               client_message_id: "c_abc",
               attachments: [%{"type" => "image", "name" => "pic.png"}]
             })

    assert message.id =~ ~r/^s_[0-9a-f-]{36}$/
    assert message.llm_visible_message_id == "c_abc"
    assert message.attachments == [%{"type" => "image", "name" => "pic.png"}]

    {:ok, rows} =
      DB.query(
        db,
        "SELECT deviceId, clientMessageId, llmVisibleMessageId, attachments FROM messages WHERE id = ?1",
        [
          message.id
        ]
      )

    assert [["dev-1", "c_abc", "c_abc", encoded]] = rows
    assert JSON.decode!(encoded) == message.attachments
  end

  test "client dedupe is idempotent for same content and conflicts for different content", %{
    db: db
  } do
    input = %{
      session_key: "k1",
      role: "user",
      content: "hi",
      device_id: "d",
      client_message_id: "c_1"
    }

    assert {:appended, first} = Projection.append(db, input)
    assert {:duplicate, duplicate} = Projection.append(db, input)
    assert duplicate.id == first.id

    assert {:conflict, existing} = Projection.append(db, %{input | content: "DIFFERENT"})
    assert existing.id == first.id

    {:ok, [[count]]} = DB.query(db, "SELECT COUNT(*) FROM messages")
    assert count == 1
  end

  test "assistant reply correlation defaults llm-visible id to its own id", %{db: db} do
    {:appended, user} =
      Projection.append(db, %{
        session_key: "k1",
        role: "user",
        content: "q",
        device_id: "d",
        client_message_id: "c_1"
      })

    {:appended, assistant} =
      Projection.append(db, %{
        session_key: "k1",
        role: "assistant",
        content: "a",
        sender: "tightbeam",
        reply_to_message_id: user.id,
        reply_to_client_message_id: "c_1"
      })

    assert assistant.reply_to_message_id == user.id
    assert assistant.reply_to_client_message_id == "c_1"
    assert assistant.llm_visible_message_id == assistant.id
    assert Projection.get(db, assistant.id) == assistant
  end

  test "transaction markers use the ordinary anti-forgery transcript row shape", %{db: db} do
    assert {:ok, {:appended, marker}} =
             DB.transaction(db, fn txn ->
               Projection.append_marker_in_txn(txn, "k1", "[context reset]")
             end)

    assert marker.session_key == "k1"
    assert marker.role == "assistant"
    assert marker.content == "[context reset]"
    assert marker.sender == "process:tightbeam"
    assert marker.llm_visible_message_id == marker.id
    assert marker.attachments == []
    assert marker.device_id == nil
    assert marker.client_message_id == nil
    assert marker.reply_to_message_id == nil
    assert marker.reply_to_client_message_id == nil
    assert marker.message_type == "marker"
  end

  test "the write seam assigns every current discriminator without reading content", %{db: db} do
    fixtures = [
      {"assistant", "assistant", "tightbeam", "assistant"},
      {"agent", "user", "agent:sender", "agent"},
      {"process", "assistant", "process:scheduler", "substrate"},
      {"remedy", "assistant", "remedy:retry-statute", "substrate"},
      {"human", "user", "user:flynn", nil},
      {"historical", "assistant", nil, nil}
    ]

    Enum.each(fixtures, fn {label, role, sender, expected_type} ->
      input = %{
        session_key: "types",
        role: role,
        sender: sender,
        content: "identical content"
      }

      assert {:appended, message} = Projection.append(db, input)
      assert message.message_type == expected_type, label
      assert message.role == role, label
      assert message.sender == sender, label
      assert message.content == "identical content", label
    end)

    assert {:ok, {:appended, substrate}} =
             DB.transaction(db, fn txn ->
               Projection.append_substrate_in_txn(txn, "types", "identical content")
             end)

    assert substrate.message_type == "substrate"
    assert substrate.role == "assistant"
  end

  test "the shared public serializer omits null and preserves open stored strings", %{db: db} do
    base = %{
      session_key: "same",
      role: "assistant",
      sender: "process:tightbeam",
      content: "same content"
    }

    assert {:appended, marker} = Projection.append(db, Map.put(base, :message_type, "marker"))

    assert {:appended, future} =
             Projection.append(db, Map.put(base, :message_type, "future-kind"))

    assert {:appended, historical} =
             Projection.append(db, %{base | sender: nil})

    marker_item = StateResources.message(marker)
    future_item = StateResources.message(future)
    historical_item = StateResources.message(historical)

    assert marker_item["messageType"] == "marker"
    assert future_item["messageType"] == "future-kind"
    refute Map.has_key?(historical_item, "messageType")
    refute JSON.encode!(historical_item) =~ "messageType"

    assert marker_item["role"] == future_item["role"]
    assert future_item["role"] == historical_item["role"]
    assert marker_item["content"] == future_item["content"]
    assert future_item["content"] == historical_item["content"]

    assert presented_message_type(future_item) == "assistant"
    assert presented_message_type(historical_item) == "assistant"
  end

  test "after replays in order and an unknown cursor replays from the start", %{db: db} do
    messages =
      Enum.map(["one", "two", "three"], fn content ->
        {:appended, message} =
          Projection.append(db, %{session_key: "k1", role: "assistant", content: content})

        message
      end)

    {:appended, _} =
      Projection.append(db, %{session_key: "OTHER", role: "assistant", content: "noise"})

    assert Enum.map(Projection.list_after(db, "k1", nil, 10), & &1.content) == [
             "one",
             "two",
             "three"
           ]

    assert Enum.map(Projection.list_after(db, "k1", hd(messages).id, 10), & &1.content) == [
             "two",
             "three"
           ]

    assert length(Projection.list_after(db, "k1", "s_unknown", 10)) == 3
    assert Projection.list_after(db, "k1", List.last(messages).id, 10) == []
  end

  test "tail reports the latest row per session", %{db: db} do
    {:appended, _} = Projection.append(db, %{session_key: "k1", role: "user", content: "q"})

    {:appended, assistant} =
      Projection.append(db, %{session_key: "k1", role: "assistant", content: "a"})

    assert Projection.tail(db, "k1") == %{
             last_message_id: assistant.id,
             last_message_role: "assistant"
           }

    assert Projection.tail(db, "empty") == nil
  end

  test "read state upserts per user and session", %{db: db} do
    :ok = Projection.set_read_state(db, "flynn", "k1", "s_a")
    :ok = Projection.set_read_state(db, "flynn", "k1", "s_b")
    :ok = Projection.set_read_state(db, "flynn", "k2", "s_c")

    assert Projection.read_states(db, "flynn") == %{"k1" => "s_b", "k2" => "s_c"}
    assert Projection.read_states(db, "sam") == %{}

    {:ok, rows} =
      DB.query(
        db,
        "SELECT userId, sessionKey, lastReadMessageId FROM read_states ORDER BY sessionKey"
      )

    assert rows == [["flynn", "k1", "s_b"], ["flynn", "k2", "s_c"]]
  end

  test "role and client dedupe invariants live in SQL", %{db: db} do
    assert_raise Tightbeam.DB.Error, ~r/CHECK constraint/, fn ->
      Projection.append(db, %{session_key: "k1", role: "system", content: "nope"})
    end

    {:appended, _} =
      Projection.append(db, %{
        session_key: "k1",
        role: "user",
        content: "one",
        device_id: "d",
        client_message_id: "c_1"
      })

    assert {:error, %Tightbeam.DB.Error{message: message}} =
             DB.query(db, """
               INSERT INTO messages
                 (id, sessionKey, role, content, timestamp, deviceId, clientMessageId, llmVisibleMessageId)
               VALUES ('s_manual', 'k1', 'user', 'two', 1, 'd', 'c_1', 's_manual')
             """)

    assert message =~ "UNIQUE constraint"
  end

  defp presented_message_type(%{"messageType" => type})
       when type in ~w(assistant substrate marker agent),
       do: type

  defp presented_message_type(_item), do: "assistant"
end
