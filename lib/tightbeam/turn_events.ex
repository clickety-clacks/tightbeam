defmodule Tightbeam.TurnEvents do
  @moduledoc """
  Immutable, ordered reply-segment and tool-lifecycle events for a turn.

  Events are appended at the ACP receive seam. Tool lifecycle events are written
  in the same transaction as the current tool-call projection they describe.
  """

  alias Tightbeam.{DB, Keyset, StateResources}
  alias Tightbeam.DB.Txn
  alias Tightbeam.Firehose.Publisher

  @shape "turn-event-order-v1"

  @ddl """
  CREATE TABLE turn_events (
    id            TEXT PRIMARY KEY CHECK (length(id) = 39),
    sessionKey    TEXT NOT NULL REFERENCES sessions(sessionKey),
    turnSeq       INTEGER NOT NULL REFERENCES turns(seq),
    turnEventSeq  INTEGER NOT NULL CHECK (turnEventSeq > 0),
    kind          TEXT NOT NULL CHECK (kind IN ('assistant.segment','tool.started','tool.ended')),
    messageId     TEXT,
    toolCallId    TEXT REFERENCES tool_calls(id),
    content       TEXT CHECK (content IS NULL OR json_valid(content)),
    toolCall      TEXT CHECK (toolCall IS NULL OR json_valid(toolCall)),
    rowVersion    INTEGER NOT NULL CHECK (rowVersion = 1),
    UNIQUE (sessionKey, turnSeq, turnEventSeq),
    CHECK (
      (kind='assistant.segment' AND messageId IS NOT NULL AND length(messageId)>0
        AND toolCallId IS NULL AND content IS NOT NULL AND toolCall IS NULL)
      OR
      (kind IN ('tool.started','tool.ended') AND messageId IS NULL
        AND toolCallId IS NOT NULL AND content IS NULL AND toolCall IS NOT NULL
        AND json_extract(toolCall,'$.id')=toolCallId
        AND json_extract(toolCall,'$.sessionKey')=sessionKey
        AND json_extract(toolCall,'$.turnSeq')=turnSeq)
    )
  );
  CREATE INDEX turn_events_session_order
    ON turn_events (sessionKey, turnSeq, turnEventSeq, id);
  CREATE TRIGGER turn_events_no_update
    BEFORE UPDATE ON turn_events BEGIN SELECT RAISE(ABORT, 'turn events are immutable'); END;
  CREATE TRIGGER turn_events_no_delete
    BEFORE DELETE ON turn_events BEGIN SELECT RAISE(ABORT, 'turn events are immutable'); END;
  """

  @stamp_ddl """
  CREATE TABLE turn_event_migration (
    id        INTEGER PRIMARY KEY CHECK (id = 0),
    shape     TEXT NOT NULL CHECK (shape = '#{@shape}'),
    appliedAt INTEGER NOT NULL CHECK (appliedAt >= 0)
  )
  """

  @select_sql """
  SELECT te.id, te.sessionKey, te.turnSeq, te.turnEventSeq, te.kind,
         te.messageId, te.toolCallId, te.content, te.toolCall, te.rowVersion,
         (SELECT t.assignmentId FROM turns AS t
          WHERE t.seq=te.turnSeq AND t.sessionKey=te.sessionKey)
  FROM turn_events AS te
  """

  @doc "Apply the append-only turn-event schema after tool-call records exist."
  @spec ensure_schema(DB.server()) :: :ok
  def ensure_schema(db \\ DB) do
    case DB.migration_transaction(db, :turn_event_records, [], [], &migrate_in_txn/1) do
      {:ok, _result} -> :ok
      {:error, error} -> raise error
    end
  end

  defp migrate_in_txn(%Txn{} = txn) do
    case Txn.q(
           txn,
           "SELECT sql FROM sqlite_master WHERE type='table' AND name='turn_event_migration'"
         ) do
      [] ->
        assert_tool_call_predecessor!(txn)
        :ok = Txn.exec(txn, @stamp_ddl)
        :ok = Txn.exec(txn, @ddl)

        Txn.q(
          txn,
          "INSERT INTO turn_event_migration (id, shape, appliedAt) VALUES (0, ?1, ?2)",
          [@shape, System.system_time(:millisecond)]
        )

        if Txn.changes(txn) != 1 do
          raise Tightbeam.Schema.ShapeError,
            message: "turn-event migration lost its exact stamp transition"
        end

        :applied

      [[sql]] ->
        unless normalize_schema_sql(sql) == normalize_schema_sql(@stamp_ddl) do
          raise Tightbeam.Schema.ShapeError,
            message: "incompatible_turn_event_migration_ddl: #{inspect(sql)}"
        end

        case Txn.q(txn, "SELECT id, shape, appliedAt FROM turn_event_migration") do
          [[0, @shape, applied_at]] when is_integer(applied_at) and applied_at >= 0 ->
            assert_tool_call_predecessor!(txn)
            validate_applied_shape!(txn)
            :already_applied

          rows ->
            raise Tightbeam.Schema.ShapeError,
              message: "incompatible_turn_event_migration_stamp: #{inspect(rows)}"
        end

      rows ->
        raise Tightbeam.Schema.ShapeError,
          message: "incompatible_turn_event_migration_table: #{inspect(rows)}"
    end
  end

  defp assert_tool_call_predecessor!(txn) do
    case Txn.q(txn, "SELECT id, shape FROM tool_call_transition_migration") do
      [[0, "tool-call-transition-v1-011"]] ->
        :ok

      rows ->
        raise Tightbeam.Schema.ShapeError,
          message: "incompatible_turn_event_predecessor: #{inspect(rows)}"
    end
  end

  defp validate_applied_shape!(txn) do
    expected = [
      {"table", "turn_events", first_statement(@ddl)},
      {"index", "turn_events_session_order",
       "CREATE INDEX turn_events_session_order ON turn_events (sessionKey, turnSeq, turnEventSeq, id)"},
      {"trigger", "turn_events_no_update",
       "CREATE TRIGGER turn_events_no_update BEFORE UPDATE ON turn_events BEGIN SELECT RAISE(ABORT, 'turn events are immutable'); END"},
      {"trigger", "turn_events_no_delete",
       "CREATE TRIGGER turn_events_no_delete BEFORE DELETE ON turn_events BEGIN SELECT RAISE(ABORT, 'turn events are immutable'); END"}
    ]

    Enum.each(expected, fn {type, name, expected_sql} ->
      case Txn.q(txn, "SELECT sql FROM sqlite_master WHERE type=?1 AND name=?2", [type, name]) do
        [[sql]] ->
          unless normalize_schema_sql(sql) == normalize_schema_sql(expected_sql) do
            raise Tightbeam.Schema.ShapeError,
              message: "incompatible_turn_event_schema_object: #{inspect({type, name, sql})}"
          end

        rows ->
          raise Tightbeam.Schema.ShapeError,
            message: "incompatible_turn_event_schema_object: #{inspect({type, name, rows})}"
      end
    end)
  end

  defp normalize_schema_sql(sql),
    do:
      sql
      |> String.replace("\"", "")
      |> String.replace(~r/\s+/, " ")
      |> String.trim()
      |> String.trim_trailing(";")

  defp first_statement(sql), do: sql |> String.split(";", parts: 2) |> hd()

  @doc "Commit one received assistant content chunk as an immutable turn event."
  @spec append_assistant_segment(DB.server(), String.t(), pos_integer(), String.t(), map()) ::
          {:ok, map()} | {:error, term()}
  def append_assistant_segment(db, session_key, turn_seq, message_id, content)
      when is_binary(session_key) and is_integer(turn_seq) and turn_seq > 0 and
             is_binary(message_id) and byte_size(message_id) > 0 and is_map(content) do
    case DB.transaction(db, fn txn ->
           event =
             insert_in_txn(txn, %{
               session_key: session_key,
               turn_seq: turn_seq,
               kind: "assistant.segment",
               message_id: message_id,
               content: content
             })

           publish_in_txn(txn, event)
           event
         end) do
      {:ok, event} -> {:ok, event}
      {:error, reason} -> {:error, reason}
    end
  rescue
    error -> {:error, error}
  end

  def append_assistant_segment(_db, _session_key, _turn_seq, _message_id, _content),
    do: {:error, :invalid_turn_event_context}

  @doc false
  def record_tool_event_in_txn(%Txn{} = txn, kind, tool_call)
      when kind in ["tool.started", "tool.ended"] and is_map(tool_call) do
    event =
      insert_in_txn(txn, %{
        session_key: tool_call.session_key,
        turn_seq: tool_call.turn_seq,
        kind: kind,
        tool_call_id: tool_call.id,
        tool_call: StateResources.tool_call(tool_call)
      })

    publish_in_txn(txn, event)
    event
  end

  @doc false
  def query_by_id(db, id) when is_binary(id) do
    case DB.query(db, @select_sql <> " WHERE te.id=?1", [id]) do
      {:ok, [row]} ->
        decode_row(row)

      {:ok, []} ->
        nil

      {:ok, rows} ->
        raise ArgumentError, "turn-event detail returned multiple rows: #{inspect(rows)}"

      {:error, error} ->
        raise error
    end
  end

  @doc false
  def query_by_id(db, session_key, id) do
    case DB.query(db, @select_sql <> " WHERE te.sessionKey=?1 AND te.id=?2", [session_key, id]) do
      {:ok, [row]} ->
        decode_row(row)

      {:ok, []} ->
        nil

      {:ok, rows} ->
        raise ArgumentError, "turn-event detail returned multiple rows: #{inspect(rows)}"

      {:error, error} ->
        raise error
    end
  end

  @doc false
  def query_by_id_in_txn(%Txn{} = txn, session_key, id) do
    case Txn.q(txn, @select_sql <> " WHERE te.sessionKey=?1 AND te.id=?2", [session_key, id]) do
      [row] -> decode_row(row)
      [] -> nil
      rows -> raise ArgumentError, "turn-event detail returned multiple rows: #{inspect(rows)}"
    end
  end

  @doc false
  def query_for_rebuild(db, id) do
    case DB.query(db, @select_sql <> " WHERE te.id=?1", [id]) do
      {:ok, [row]} ->
        decode_row(row)

      {:ok, []} ->
        nil

      {:ok, rows} ->
        raise ArgumentError, "turn-event rebuild returned multiple rows: #{inspect(rows)}"

      {:error, error} ->
        raise error
    end
  end

  @doc false
  def page_for_session(db, session_key, boundary, limit, turn_seq_filter) do
    with_read_transaction(db, fn txn ->
      base = ["te.sessionKey=?"]
      params = [session_key]

      {base, params} =
        if is_integer(turn_seq_filter),
          do: {base ++ ["te.turnSeq=?"], params ++ [turn_seq_filter]},
          else: {base, params}

      where = Enum.join(base, " AND ")
      query = fn sql, values -> Txn.q(txn, sql, values) end

      page =
        Keyset.page(
          query,
          @select_sql,
          "turn_events AS te",
          where,
          params,
          ["te.turnSeq", "te.turnEventSeq", "te.id"],
          boundary,
          limit,
          fn [id, _session_key, turn_seq, turn_event_seq | _] ->
            [turn_seq, turn_event_seq, id]
          end
        )

      %{rows: Enum.map(page.rows, &decode_row/1), flags: page}
    end)
  end

  defp insert_in_txn(txn, attrs) do
    [[next_seq]] =
      Txn.q(
        txn,
        "SELECT COALESCE(MAX(turnEventSeq), 0) + 1 FROM turn_events WHERE sessionKey=?1 AND turnSeq=?2",
        [attrs.session_key, attrs.turn_seq]
      )

    id = "te_" <> Tightbeam.Id.uuid4()
    content = Map.get(attrs, :content)
    tool_call = Map.get(attrs, :tool_call)

    Txn.q(
      txn,
      """
      INSERT INTO turn_events (
        id, sessionKey, turnSeq, turnEventSeq, kind, messageId, toolCallId,
        content, toolCall, rowVersion
      ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, 1)
      """,
      [
        id,
        attrs.session_key,
        attrs.turn_seq,
        next_seq,
        attrs.kind,
        Map.get(attrs, :message_id),
        Map.get(attrs, :tool_call_id),
        encode_json(content),
        encode_json(tool_call)
      ]
    )

    if Txn.changes(txn) != 1 do
      raise ArgumentError, "turn-event insert did not append exactly one row"
    end

    query_by_id_in_txn(txn, attrs.session_key, id) ||
      raise ArgumentError, "turn-event insert is missing from its transaction"
  end

  defp publish_in_txn(txn, event) do
    assignment_id =
      case Txn.q(txn, "SELECT assignmentId FROM turns WHERE seq=?1 AND sessionKey=?2", [
             event.turn_seq,
             event.session_key
           ]) do
        [[assignment_id]] -> assignment_id
        [] -> nil
      end

    refs = %{
      "turnEventId" => event.id,
      "sessionKey" => event.session_key,
      "turnSeq" => event.turn_seq
    }

    refs =
      cond do
        is_binary(event.message_id) -> Map.put(refs, "messageId", event.message_id)
        is_binary(event.tool_call_id) -> Map.put(refs, "toolCallId", event.tool_call_id)
        true -> refs
      end

    refs =
      if is_binary(assignment_id), do: Map.put(refs, "assignmentId", assignment_id), else: refs

    class =
      case event.kind do
        "assistant.segment" -> "message.segment_recorded"
        "tool.started" -> "tool_call.event_recorded"
        "tool.ended" -> "tool_call.event_recorded"
      end

    Publisher.committed_in_txn(txn, class, event, refs)
    :ok
  end

  defp decode_row([
         id,
         session_key,
         turn_seq,
         turn_event_seq,
         kind,
         message_id,
         tool_call_id,
         content,
         tool_call,
         row_version,
         assignment_id
       ]) do
    %{
      id: id,
      session_key: session_key,
      turn_seq: turn_seq,
      turn_event_seq: turn_event_seq,
      kind: kind,
      message_id: message_id,
      tool_call_id: tool_call_id,
      content: decode_json(content),
      tool_call: decode_json(tool_call),
      row_version: row_version,
      assignment_id: assignment_id
    }
  end

  defp encode_json(nil), do: nil
  defp encode_json(value), do: JSON.encode!(value)
  defp decode_json(nil), do: nil
  defp decode_json(value), do: JSON.decode!(value)

  defp with_read_transaction(%Txn{} = txn, fun), do: fun.(txn)

  defp with_read_transaction(db, fun) do
    case DB.transaction(db, fun) do
      {:ok, result} -> result
      {:error, error} -> raise error
    end
  end
end
