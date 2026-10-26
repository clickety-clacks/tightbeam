defmodule Tightbeam.ToolCallsTest do
  use Tightbeam.TestCase, async: false

  import Plug.Conn
  import Plug.Test

  alias Tightbeam.{Archetypes, DB, Devices, Identity, Ledger, Org, Projection, StateResources}
  alias Tightbeam.Firehose.{Hub, Publisher}
  alias Tightbeam.ToolCalls
  alias Tightbeam.Wire.Router

  setup do
    base_dir =
      Path.join(System.tmp_dir!(), "tightbeam-tool-calls-#{System.unique_integer([:positive])}")

    File.mkdir_p!(base_dir)
    :initialized = Identity.init!(base_dir)
    Archetypes.load!(base_dir)

    db = String.to_atom("tool_calls_db_#{System.unique_integer([:positive])}")
    start_supervised!({DB, path: ":memory:", name: db})
    start_supervised!({Hub, name: Hub})
    :ok = ensure_all_schemas(db)

    {:paired, device} =
      Devices.pair(db, %{
        device_id: "tool-calls-device",
        claimed_name: "Flynn",
        platform: nil,
        model: nil
      })

    session = ensure_main_session(db, "flynn")

    {:appended, prompt_message} =
      Projection.append(db, %{
        session_key: session.session_key,
        role: "user",
        content: "Record the prompt before the tool call."
      })

    {:ok, turn_seq} =
      Ledger.enqueue(db, %{
        session_key: session.session_key,
        message_id: prompt_message.id,
        origin: "user:flynn",
        prompt: prompt_message.content
      })

    opts = [
      db: db,
      base_dir: base_dir,
      handlers: %{},
      cli_token: "tool-calls-cli",
      firehose_hub: Hub,
      model_catalog: %{},
      session_status: fn _session_key -> nil end
    ]

    :ok =
      Hub.register(Hub, self(), %{mode: :subscribed, db: db, user_id: "flynn", is_admin: false})

    on_exit(fn -> File.rm_rf!(base_dir) end)

    %{
      db: db,
      opts: opts,
      token: device.token,
      session_key: session.session_key,
      turn_seq: turn_seq,
      anchor: prompt_message.seq,
      prompt_message_id: prompt_message.id
    }
  end

  test "persists the start and terminal update and shares exact REST and Firehose item bytes",
       ctx do
    :ok = subscribe(ctx, "tool-call-records", ["tool_call.", "transition.recorded"])

    start =
      ToolCalls.normalize_notification(%{
        "title" => "Read source",
        "kind" => "read",
        "status" => "in_progress",
        "rawInput" => %{"path" => "lib/tightbeam/gateway.ex"},
        "_meta" => %{"claudeCode" => %{"toolName" => "Read"}}
      })

    assert {:ok, :started} =
             ToolCalls.observe(
               ctx.db,
               ctx.session_key,
               ctx.turn_seq,
               "call-read-1",
               start,
               %{},
               nil
             )

    started = receive_notice("tool_call.started")
    assert started["refs"]["sessionKey"] == ctx.session_key
    assert started["refs"]["turnSeq"] == ctx.turn_seq
    refute Map.has_key?(started["refs"], "assignmentId")

    intermediate =
      ToolCalls.normalize_notification(%{
        "status" => "in_progress",
        "rawOutput" => %{"partial" => true}
      })

    assert {:ok, :buffered} =
             ToolCalls.observe(
               ctx.db,
               ctx.session_key,
               ctx.turn_seq,
               "call-read-1",
               intermediate,
               %{},
               nil
             )

    assert %{row_version: 1} = raw_row(ctx.db, ctx.session_key, "call-read-1")

    terminal =
      ToolCalls.normalize_notification(%{
        "status" => "completed",
        "rawOutput" => %{"lines" => ["module Tightbeam.Gateway"]},
        "content" => [%{"type" => "content", "content" => %{"type" => "text", "text" => "done"}}]
      })

    assert {:ok, :ended} =
             ToolCalls.observe(
               ctx.db,
               ctx.session_key,
               ctx.turn_seq,
               "call-read-1",
               terminal,
               intermediate,
               nil
             )

    ended = receive_notice("tool_call.ended")
    row = raw_row(ctx.db, ctx.session_key, "call-read-1")
    item = StateResources.tool_call(row)

    assert item["status"] == "completed"
    assert item["rowVersion"] == 2
    assert item["afterMessageSeq"] == ctx.anchor
    assert item["rawInput"] == %{"path" => "lib/tightbeam/gateway.ex"}
    assert item["rawOutput"] == %{"lines" => ["module Tightbeam.Gateway"]}
    terminal_content = terminal[:content] |> Map.fetch!(:encoded) |> JSON.decode!()
    assert item["content"] == terminal_content
    assert ended["payload"] == item

    item_bytes = StateResources.encode_item("tool calls", item)
    assert String.contains?(Publisher.encode_wire_notice(ended), "\"payload\":" <> item_bytes)

    detail = get(ctx, "/api/sessions/#{ctx.session_key}/tool-calls/#{row.id}")
    assert detail.status == 200, detail.resp_body
    assert JSON.decode!(detail.resp_body)["item"] == item
    assert String.contains?(detail.resp_body, "\"item\":" <> item_bytes)

    collection =
      get(
        ctx,
        "/api/sessions/#{ctx.session_key}/tool-calls?afterMessageSeqFromInclusive=#{ctx.anchor}&afterMessageSeqToExclusive=#{ctx.anchor + 1}"
      )

    assert collection.status == 200, collection.resp_body
    assert JSON.decode!(collection.resp_body)["items"] == [item]
    assert String.contains?(collection.resp_body, "\"items\":[" <> item_bytes <> "]")

    outside_slice =
      get(
        ctx,
        "/api/sessions/#{ctx.session_key}/tool-calls?afterMessageSeqToExclusive=#{ctx.anchor}"
      )

    assert JSON.decode!(outside_slice.resp_body)["items"] == []

    compaction =
      ToolCalls.normalize_notification(%{
        "title" => "Compact conversation",
        "kind" => "think",
        "status" => "completed",
        "_meta" => %{"contextCompaction" => %{}}
      })

    assert {:ok, :ended} =
             ToolCalls.observe(
               ctx.db,
               ctx.session_key,
               ctx.turn_seq,
               "compaction-call",
               compaction,
               %{},
               "151200/200000 tokens"
             )

    _ = receive_notice("tool_call.ended")
    transition = receive_notice("transition.recorded")

    assert transition["payload"]["marker"] == %{
             "kind" => "context-compacted",
             "from" => "151200/200000 tokens",
             "to" => "compacted"
           }

    assert String.starts_with?(transition["payload"]["content"], "[context compacted]")
  end

  test "bounds each canonical JSON field and reports the original byte lengths", ctx do
    input = %{"v" => String.duplicate("🙂", 17_000)}
    output = %{"result" => String.duplicate("x", 70_000)}

    content = [
      %{
        "type" => "content",
        "content" => %{"type" => "text", "text" => String.duplicate("y", 70_000)}
      }
    ]

    fields =
      ToolCalls.normalize_notification(%{
        "title" => "Large result",
        "kind" => "execute",
        "status" => "completed",
        "rawInput" => input,
        "rawOutput" => output,
        "content" => content
      })

    assert {:ok, :ended} =
             ToolCalls.observe(
               ctx.db,
               ctx.session_key,
               ctx.turn_seq,
               "large-call",
               fields,
               %{},
               nil
             )

    row = raw_row(ctx.db, ctx.session_key, "large-call")
    item = StateResources.tool_call(row)
    canonical_input = StateResources.encode_json_value(input)
    expected_input_prefix = utf8_prefix(canonical_input, 65_536)

    assert item["rawInput"] == expected_input_prefix
    assert byte_size(item["rawInput"]) <= 65_536
    assert String.valid?(item["rawInput"])

    assert Enum.map(item["truncated"], & &1["field"]) == ["rawInput", "rawOutput", "content"]
    assert Enum.at(item["truncated"], 0)["originalBytes"] == byte_size(canonical_input)

    for {field, value} <- [
          {"rawOutput", output},
          {"content", content}
        ] do
      entry = Enum.find(item["truncated"], &(&1["field"] == field))
      assert entry["originalBytes"] == byte_size(StateResources.encode_json_value(value))
      assert is_binary(item[field])
      assert byte_size(item[field]) <= 65_536
    end

    assert JSON.decode!(StateResources.encode_item("tool calls", item))["truncated"] ==
             item["truncated"]
  end

  test "keeps late tool records visible and announces terminal updates after a history reset",
       ctx do
    :ok = subscribe(ctx, "hidden-tool-call", ["tool_call."])

    start = ToolCalls.normalize_notification(%{"status" => "in_progress", "title" => "Run"})

    assert {:ok, :started} =
             ToolCalls.observe(
               ctx.db,
               ctx.session_key,
               ctx.turn_seq,
               "late-call",
               start,
               %{},
               nil
             )

    _ = receive_notice("tool_call.started")
    row = raw_row(ctx.db, ctx.session_key, "late-call")

    assert {:ok, :ok} =
             DB.transaction(ctx.db, fn txn ->
               Tightbeam.DB.Txn.q(
                 txn,
                 "UPDATE sessions SET clearedThroughSeq=?1 WHERE sessionKey=?2",
                 [row.after_message_seq, ctx.session_key]
               )

               :ok
             end)

    terminal =
      ToolCalls.normalize_notification(%{"status" => "completed", "rawOutput" => "finished"})

    assert {:ok, :ended} =
             ToolCalls.observe(
               ctx.db,
               ctx.session_key,
               ctx.turn_seq,
               "late-call",
               terminal,
               %{},
               nil
             )

    ended = receive_notice("tool_call.ended")
    late_row = raw_row(ctx.db, ctx.session_key, "late-call")
    late_item = StateResources.tool_call(late_row)
    item_bytes = StateResources.encode_item("tool calls", late_item)

    assert ended["payload"] == late_item

    rebuilt_item =
      ctx.db
      |> StateResources.query_tool_call_for_rebuild(late_row.id)
      |> StateResources.tool_call()

    assert rebuilt_item == late_item

    collection = get(ctx, "/api/sessions/#{ctx.session_key}/tool-calls")
    assert collection.status == 200
    assert JSON.decode!(collection.resp_body)["items"] == [late_item]
    assert String.contains?(collection.resp_body, "\"items\":[" <> item_bytes <> "]")

    detail = get(ctx, "/api/sessions/#{ctx.session_key}/tool-calls/#{late_row.id}")
    assert detail.status == 200
    assert JSON.decode!(detail.resp_body)["item"] == late_item
    assert String.contains?(detail.resp_body, "\"item\":" <> item_bytes)
    assert String.contains?(Publisher.encode_wire_notice(ended), "\"payload\":" <> item_bytes)

    {:appended, later_message} =
      Projection.append(ctx.db, %{
        session_key: ctx.session_key,
        role: "user",
        content: "Continue after the reset boundary."
      })

    assert later_message.seq > late_row.after_message_seq

    later_start =
      ToolCalls.normalize_notification(%{"status" => "in_progress", "title" => "Later"})

    assert {:ok, :started} =
             ToolCalls.observe(
               ctx.db,
               ctx.session_key,
               ctx.turn_seq,
               "later-call",
               later_start,
               %{},
               nil
             )

    _ = receive_notice("tool_call.started")
    later_row = raw_row(ctx.db, ctx.session_key, "later-call")
    later_item = StateResources.tool_call(later_row)

    latest = get(ctx, "/api/sessions/#{ctx.session_key}/tool-calls?limit=1")
    assert latest.status == 200
    latest_page = JSON.decode!(latest.resp_body)
    assert latest_page["items"] == [later_item]
    assert latest_page["page"]["hasMoreBefore"] == true
    assert latest_page["page"]["hasMoreAfter"] == false

    before =
      get(
        ctx,
        "/api/sessions/#{ctx.session_key}/tool-calls?limit=1&before=" <>
          URI.encode_www_form(latest_page["page"]["oldestCursor"])
      )

    assert before.status == 200
    before_page = JSON.decode!(before.resp_body)
    assert before_page["items"] == [late_item]
    assert before_page["page"]["hasMoreBefore"] == false
    assert before_page["page"]["hasMoreAfter"] == true
    assert String.contains?(before.resp_body, "\"items\":[" <> item_bytes <> "]")

    following =
      get(
        ctx,
        "/api/sessions/#{ctx.session_key}/tool-calls?limit=1&after=" <>
          URI.encode_www_form(before_page["page"]["newestCursor"])
      )

    assert following.status == 200
    assert JSON.decode!(following.resp_body)["items"] == [later_item]
  end

  test "fresh setup applies the feature-local migration without changing the root stamp", ctx do
    {:ok, [[root_shape]]} = DB.query(ctx.db, "SELECT shape FROM schema_stamp", [])
    assert root_shape == "launch-preparation-boot-v1-0110"

    {:ok, [[0, "tool-call-transition-v1-011"]]} =
      DB.query(ctx.db, "SELECT id, shape FROM tool_call_transition_migration", [])

    {:ok, [[message_sql]]} =
      DB.query(
        ctx.db,
        "SELECT sql FROM sqlite_master WHERE type='table' AND name='messages'",
        []
      )

    assert message_sql =~ "context-compacted"

    {:ok, [[1]]} =
      DB.query(
        ctx.db,
        "SELECT COUNT(*) FROM sqlite_master WHERE type='index' AND name='tool_calls_session_seq'",
        []
      )

    {:ok, [[1]]} =
      DB.query(
        ctx.db,
        "SELECT COUNT(*) FROM sqlite_master WHERE type='index' AND name='tool_calls_session_anchor'",
        []
      )
  end

  test "upgrades the named migration while preserving message rows and sequence high water",
       ctx do
    {:ok, :ok} =
      DB.transaction(ctx.db, fn txn ->
        Tightbeam.DB.Txn.q(
          txn,
          """
          UPDATE messages
          SET sender='user:flynn', deviceId='migration-device', clientMessageId='migration-client',
              replyToMessageId='reply-message', replyToClientMessageId='reply-client',
              llmVisibleMessageId='visible-migration-message',
              attachments='[{\"name\":\"preserved.txt\"}]', attentionTier=1
          WHERE id=?1
          """,
          [ctx.prompt_message_id]
        )

        :ok
      end)

    {:appended, marker} =
      Projection.append_marker(ctx.db, ctx.session_key, %{
        kind: "model-retune",
        from: "claude-sonnet-4-6",
        to: "claude-opus-5-5"
      })

    message_columns = ~w(
      seq id sessionKey role content timestamp sender deviceId clientMessageId
      replyToMessageId replyToClientMessageId llmVisibleMessageId attachments
      attentionTier messageType markerKind markerFrom markerTo
    )

    message_rows_sql = "SELECT " <> Enum.join(message_columns, ", ") <> " FROM messages ORDER BY seq"
    {:ok, message_rows_before} = DB.query(ctx.db, message_rows_sql, [])

    {:ok, [[root_shape_before]]} = DB.query(ctx.db, "SELECT shape FROM schema_stamp", [])

    {:ok, [[message_high_water]]} =
      DB.query(ctx.db, "SELECT seq FROM sqlite_sequence WHERE name = 'messages'", [])

    preserved_high_water = message_high_water + 100

    :ok =
      DB.execute(
        ctx.db,
        "UPDATE sqlite_sequence SET seq = #{preserved_high_water} WHERE name = 'messages'"
      )

    rewind_messages_to_predecessor(ctx.db)

    assert :ok = ToolCalls.ensure_schema(ctx.db)
    assert :ok = ToolCalls.ensure_schema(ctx.db)

    {:ok, message_rows_after} = DB.query(ctx.db, message_rows_sql, [])
    assert message_rows_after == message_rows_before

    {:ok, columns_after} = DB.query(ctx.db, "PRAGMA table_info(messages)", [])
    assert Enum.map(columns_after, fn [_cid, name | _rest] -> name end) == message_columns

    {:ok, index_names} =
      DB.query(
        ctx.db,
        "SELECT name FROM sqlite_master WHERE type='index' AND tbl_name='messages' AND name NOT LIKE 'sqlite_%' ORDER BY name",
        []
      )

    assert index_names == [["messages_client_dedupe"], ["messages_session"]]

    {:ok, session_index_columns} = DB.query(ctx.db, "PRAGMA index_info(messages_session)", [])
    assert Enum.map(session_index_columns, fn [_seq, _cid, name] -> name end) == ["sessionKey", "seq"]

    {:ok, dedupe_index_columns} =
      DB.query(ctx.db, "PRAGMA index_info(messages_client_dedupe)", [])

    assert Enum.map(dedupe_index_columns, fn [_seq, _cid, name] -> name end) ==
             ["sessionKey", "deviceId", "clientMessageId"]

    {:ok, [[root_shape_after]]} = DB.query(ctx.db, "SELECT shape FROM schema_stamp", [])
    assert root_shape_after == root_shape_before

    {:ok, [[0, "tool-call-transition-v1-011"]]} =
             DB.query(ctx.db, "SELECT id, shape FROM tool_call_transition_migration", [])

    {:ok, [[message_sql]]} =
      DB.query(
        ctx.db,
        "SELECT sql FROM sqlite_master WHERE type='table' AND name='messages'",
        []
      )

    assert message_sql =~ "context-compacted"

    migrated = StateResources.query_message(ctx.db, marker.id)
    assert migrated.marker_kind == "model-retune"
    assert :ok = foreign_key_check(ctx.db)

    {:appended, compacted} =
      Projection.append_marker(ctx.db, ctx.session_key, %{
        kind: "context-compacted",
        from: "unknown",
        to: "compacted"
      })

    assert compacted.seq > preserved_high_water

    assert StateResources.message(StateResources.query_message(ctx.db, compacted.id))["marker"][
             "kind"
           ] ==
             "context-compacted"

    :ok = DB.execute(ctx.db, "DROP INDEX tool_calls_session_anchor")

    assert_raise Tightbeam.Schema.ShapeError, fn ->
      ToolCalls.ensure_schema(ctx.db)
    end
  end

  defp raw_row(db, session_key, harness_tool_call_id) do
    {:ok, [[id]]} =
      DB.query(
        db,
        "SELECT id FROM tool_calls WHERE sessionKey=?1 AND harnessToolCallId=?2",
        [session_key, harness_tool_call_id]
      )

    ToolCalls.query_by_id(db, id)
  end

  defp subscribe(ctx, id, classes) do
    Hub.subscribe(Hub, self(), id, %{"classes" => classes, "sessionKey" => ctx.session_key})
  end

  defp receive_notice(class) do
    assert_receive {:firehose_notice, %{"class" => ^class} = notice}
    :ok = Hub.delivered(Hub, self())
    :sys.get_state(Hub)
    notice
  end

  defp get(ctx, path) do
    conn(:get, path)
    |> put_req_header("authorization", "Bearer #{ctx.token}")
    |> Router.call(Router.init(ctx.opts))
  end

  defp utf8_prefix(value, limit) do
    value
    |> binary_part(0, min(byte_size(value), limit))
    |> trim_utf8_tail()
  end

  defp rewind_messages_to_predecessor(db) do
    :ok = DB.execute(db, "PRAGMA foreign_keys = OFF")

    {:ok, :ok} =
      DB.transaction(db, fn txn ->
        Tightbeam.DB.Txn.exec(txn, """
        DROP INDEX messages_session;
        DROP INDEX messages_client_dedupe;
        CREATE TABLE messages_legacy (
          seq                    INTEGER PRIMARY KEY AUTOINCREMENT,
          id                     TEXT NOT NULL UNIQUE,
          sessionKey             TEXT NOT NULL,
          role                   TEXT NOT NULL CHECK (role IN ('user','assistant')),
          content                TEXT NOT NULL,
          timestamp              INTEGER NOT NULL,
          sender                 TEXT,
          deviceId               TEXT,
          clientMessageId        TEXT,
          replyToMessageId       TEXT,
          replyToClientMessageId TEXT,
          llmVisibleMessageId    TEXT NOT NULL,
          attachments            TEXT NOT NULL DEFAULT '[]',
          attentionTier          INTEGER NOT NULL DEFAULT 0,
          messageType            TEXT,
          markerKind             TEXT CHECK (
            markerKind IS NULL OR markerKind IN ('harness-switch','model-retune','session-restart')
          ),
          markerFrom             TEXT,
          markerTo               TEXT,
          CHECK (
            (messageType IS 'marker' AND markerKind IS NOT NULL AND markerFrom IS NOT NULL AND markerTo IS NOT NULL)
            OR
            (messageType IS NOT 'marker' AND markerKind IS NULL AND markerFrom IS NULL AND markerTo IS NULL)
          )
        );
        INSERT INTO messages_legacy (
          seq, id, sessionKey, role, content, timestamp, sender, deviceId,
          clientMessageId, replyToMessageId, replyToClientMessageId,
          llmVisibleMessageId, attachments, attentionTier, messageType,
          markerKind, markerFrom, markerTo
        )
        SELECT seq, id, sessionKey, role, content, timestamp, sender, deviceId,
          clientMessageId, replyToMessageId, replyToClientMessageId,
          llmVisibleMessageId, attachments, attentionTier, messageType,
          markerKind, markerFrom, markerTo
        FROM messages;
        DROP TABLE messages;
        ALTER TABLE messages_legacy RENAME TO messages;
        CREATE INDEX messages_session ON messages (sessionKey, seq);
        CREATE UNIQUE INDEX messages_client_dedupe
          ON messages (sessionKey, deviceId, clientMessageId)
          WHERE clientMessageId IS NOT NULL AND deviceId IS NOT NULL;
        DROP TABLE tool_calls;
        DROP TABLE tool_call_transition_migration;
        """)
      end)

    :ok = DB.execute(db, "PRAGMA foreign_keys = ON")

    {:ok, [[high_water]]} =
      DB.query(db, "SELECT seq FROM sqlite_sequence WHERE name = 'messages'", [])

    {:ok, [[preserved_high_water]]} =
      DB.query(
        db,
        "SELECT COALESCE((SELECT seq FROM sqlite_sequence WHERE name = 'messages'), 0) + 100",
        []
      )

    :ok =
      DB.execute(
        db,
        "UPDATE sqlite_sequence SET seq = #{max(high_water, preserved_high_water)} WHERE name = 'messages'"
      )
  end

  defp foreign_key_check(db) do
    case DB.query(db, "PRAGMA foreign_key_check", []) do
      {:ok, []} -> :ok
      other -> flunk("foreign key check failed: #{inspect(other)}")
    end
  end

  defp trim_utf8_tail(value) do
    if String.valid?(value),
      do: value,
      else: trim_utf8_tail(binary_part(value, 0, byte_size(value) - 1))
  end
end
