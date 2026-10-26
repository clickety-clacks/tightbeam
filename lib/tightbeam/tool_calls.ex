defmodule Tightbeam.ToolCalls do
  @moduledoc """
  Durable tool-call records reported by an ACP adapter.

  Nonterminal updates are folded in the adapter process and reach this module
  only when a call starts or becomes terminal. The rows live beside transcript
  messages and are anchored to the last message in the same insert transaction.
  """

  require Logger

  alias Tightbeam.{DB, Projection, StateResources}
  alias Tightbeam.DB.Txn
  alias Tightbeam.Firehose.Publisher

  @field_limit 65_536
  @shape "tool-call-transition-v1-011"
  @terminal_statuses ["completed", "failed"]
  @truncation_order %{"rawInput" => 0, "rawOutput" => 1, "content" => 2}

  @tool_calls_ddl """
  CREATE TABLE tool_calls (
    seq               INTEGER PRIMARY KEY AUTOINCREMENT,
    id                TEXT NOT NULL UNIQUE,
    sessionKey        TEXT NOT NULL REFERENCES sessions(sessionKey),
    turnSeq           INTEGER NOT NULL REFERENCES turns(seq),
    afterMessageSeq   INTEGER NOT NULL CHECK (afterMessageSeq >= 0),
    harnessToolCallId TEXT NOT NULL CHECK (length(harnessToolCallId) > 0),
    title             TEXT NOT NULL,
    kind              TEXT NOT NULL,
    toolName          TEXT,
    status            TEXT NOT NULL CHECK (status IN ('pending','in_progress','completed','failed')),
    rawInput          TEXT CHECK (rawInput IS NULL OR json_valid(rawInput)),
    rawOutput         TEXT CHECK (rawOutput IS NULL OR json_valid(rawOutput)),
    content           TEXT CHECK (content IS NULL OR json_valid(content)),
    truncated         TEXT NOT NULL CHECK (json_valid(truncated)),
    startedAt         INTEGER NOT NULL CHECK (startedAt >= 0),
    endedAt           INTEGER,
    rowVersion        INTEGER NOT NULL CHECK (rowVersion > 0),
    UNIQUE (sessionKey, harnessToolCallId),
    CHECK (
      (status IN ('completed','failed') AND endedAt IS NOT NULL)
      OR
      (status IN ('pending','in_progress') AND endedAt IS NULL)
    )
  );
  CREATE INDEX tool_calls_session_seq ON tool_calls (sessionKey, seq);
  CREATE INDEX tool_calls_session_anchor ON tool_calls (sessionKey, afterMessageSeq);
  """

  @migration_stamp_ddl """
  CREATE TABLE tool_call_transition_migration (
    id        INTEGER PRIMARY KEY CHECK (id = 0),
    shape     TEXT NOT NULL CHECK (shape = '#{@shape}'),
    appliedAt INTEGER NOT NULL CHECK (appliedAt >= 0)
  )
  """

  @messages_new_ddl """
  CREATE TABLE messages_new (
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
      markerKind IS NULL OR markerKind IN ('harness-switch','model-retune','session-restart','context-compacted')
    ),
    markerFrom             TEXT,
    markerTo               TEXT,
    CHECK (
      (messageType IS 'marker' AND markerKind IS NOT NULL AND markerFrom IS NOT NULL AND markerTo IS NOT NULL)
      OR
      (messageType IS NOT 'marker' AND markerKind IS NULL AND markerFrom IS NULL AND markerTo IS NULL)
    )
  )
  """

  @doc "Apply the one-time tool-call and transition schema migration."
  @spec ensure_schema(DB.server()) :: :ok
  def ensure_schema(db \\ DB) do
    started_at = System.monotonic_time(:millisecond)
    :ok = DB.execute(db, "PRAGMA foreign_keys = OFF")

    result =
      try do
        DB.migration_transaction(db, :tool_call_transition_records, [], [], &migrate_in_txn/1)
      after
        :ok = DB.execute(db, "PRAGMA foreign_keys = ON")
      end

    case result do
      {:ok, :applied} ->
        Logger.info(
          "database migration tool_call_transition_records committed duration_ms=#{System.monotonic_time(:millisecond) - started_at}"
        )

        :ok

      {:ok, :already_applied} ->
        :ok

      {:error, error} ->
        raise error
    end
  end

  defp migrate_in_txn(%Txn{} = txn) do
    case Txn.q(
           txn,
           "SELECT sql FROM sqlite_master WHERE type='table' AND name='tool_call_transition_migration'"
         ) do
      [] ->
        :ok = Txn.exec(txn, @migration_stamp_ddl)
        migrate_unstamped_in_txn(txn)

      [[sql]] ->
        unless normalize_schema_sql(sql) == normalize_schema_sql(@migration_stamp_ddl) do
          raise Tightbeam.Schema.ShapeError,
            message: "incompatible_tool_call_transition_migration_ddl: #{inspect(sql)}"
        end

        case Txn.q(txn, "SELECT id, shape, appliedAt FROM tool_call_transition_migration") do
          [[0, @shape, applied_at]] when is_integer(applied_at) and applied_at >= 0 ->
            validate_applied_shape!(txn)
            :already_applied

          rows ->
            raise Tightbeam.Schema.ShapeError,
              message: "incompatible_tool_call_transition_migration_stamp: #{inspect(rows)}"
        end

      rows ->
        raise Tightbeam.Schema.ShapeError,
          message: "incompatible_tool_call_transition_migration_table: #{inspect(rows)}"
    end
  end

  defp normalize_schema_sql(sql),
    do:
      sql
      |> String.replace("\"", "")
      |> String.replace(~r/\s+/, " ")
      |> String.trim()
      |> String.trim_trailing(";")

  defp validate_applied_shape!(txn) do
    expected = [
      {"table", "tool_calls", first_statement(@tool_calls_ddl)},
      {"index", "tool_calls_session_seq",
       "CREATE INDEX tool_calls_session_seq ON tool_calls (sessionKey, seq)"},
      {"index", "tool_calls_session_anchor",
       "CREATE INDEX tool_calls_session_anchor ON tool_calls (sessionKey, afterMessageSeq)"},
      {"table", "messages",
       String.replace(@messages_new_ddl, "messages_new", "messages", global: false)},
      {"index", "messages_session",
       "CREATE INDEX messages_session ON messages (sessionKey, seq)"},
      {"index", "messages_client_dedupe",
       "CREATE UNIQUE INDEX messages_client_dedupe ON messages (sessionKey, deviceId, clientMessageId) WHERE clientMessageId IS NOT NULL AND deviceId IS NOT NULL"}
    ]

    Enum.each(expected, fn {type, name, expected_sql} ->
      case Txn.q(
             txn,
             "SELECT sql FROM sqlite_master WHERE type = ?1 AND name = ?2",
             [type, name]
           ) do
        [[sql]] ->
          unless normalize_schema_sql(sql) == normalize_schema_sql(expected_sql) do
            raise Tightbeam.Schema.ShapeError,
              message:
                "incompatible_tool_call_transition_schema_object: #{inspect({type, name, sql})}"
          end

        rows ->
          raise Tightbeam.Schema.ShapeError,
            message:
              "incompatible_tool_call_transition_schema_object: #{inspect({type, name, rows})}"
      end
    end)
  end

  defp first_statement(sql), do: sql |> String.split(";", parts: 2) |> hd()

  defp migrate_unstamped_in_txn(txn) do
    case Txn.q(txn, "SELECT shape FROM schema_stamp") do
      [["launch-preparation-boot-v1-0110"]] ->
        :ok

      rows ->
        raise Tightbeam.Schema.ShapeError,
          message: "incompatible_tool_call_transition_predecessor: #{inspect(rows)}"
    end

    prior_fk_violations = Tightbeam.Schema.migration_foreign_keys_in_txn(txn, ["artifacts"])
    rebuild_messages_in_txn(txn)
    :ok = Txn.exec(txn, @tool_calls_ddl)

    Txn.q(
      txn,
      "INSERT INTO tool_call_transition_migration (id, shape, appliedAt) VALUES (0, ?1, ?2)",
      [@shape, System.system_time(:millisecond)]
    )

    if Txn.changes(txn) != 1 do
      raise Tightbeam.Schema.ShapeError,
        message: "tool-call transition migration lost its exact stamp transition"
    end

    case Tightbeam.Schema.migration_foreign_keys_in_txn(txn, ["artifacts", "tool_calls"]) --
           prior_fk_violations do
      [] ->
        :applied

      rows ->
        raise Tightbeam.Schema.ShapeError,
          message: "tool-call transition migration left invalid foreign keys: #{inspect(rows)}"
    end
  end

  defp rebuild_messages_in_txn(txn) do
    [[message_count]] = Txn.q(txn, "SELECT COUNT(*) FROM messages")

    [[sequence_high_water]] =
      Txn.q(txn, "SELECT COALESCE((SELECT seq FROM sqlite_sequence WHERE name='messages'), 0)")

    :ok = Txn.exec(txn, @messages_new_ddl)

    Txn.q(txn, """
    INSERT INTO messages_new (
      seq, id, sessionKey, role, content, timestamp, sender, deviceId,
      clientMessageId, replyToMessageId, replyToClientMessageId,
      llmVisibleMessageId, attachments, attentionTier,
      messageType, markerKind, markerFrom, markerTo
    )
    SELECT
      seq, id, sessionKey, role, content, timestamp, sender, deviceId,
      clientMessageId, replyToMessageId, replyToClientMessageId,
      llmVisibleMessageId, attachments, attentionTier,
      messageType, markerKind, markerFrom, markerTo
    FROM messages
    """)

    if Txn.changes(txn) != message_count do
      raise Tightbeam.Schema.ShapeError,
        message:
          "tool-call transition migration copied #{Txn.changes(txn)} of #{message_count} messages"
    end

    [[^message_count]] = Txn.q(txn, "SELECT COUNT(*) FROM messages_new")

    :ok =
      Txn.exec(txn, """
      DROP INDEX messages_session;
      DROP INDEX messages_client_dedupe;
      DROP TABLE messages;
      ALTER TABLE messages_new RENAME TO messages;
      CREATE INDEX messages_session ON messages (sessionKey, seq);
      CREATE UNIQUE INDEX messages_client_dedupe
        ON messages (sessionKey, deviceId, clientMessageId)
        WHERE clientMessageId IS NOT NULL AND deviceId IS NOT NULL;
      """)

    preserve_message_sequence_in_txn(txn, sequence_high_water)
  end

  defp preserve_message_sequence_in_txn(txn, high_water) do
    case Txn.q(txn, "SELECT seq FROM sqlite_sequence WHERE name='messages'") do
      [[current]] when current < high_water ->
        Txn.q(txn, "UPDATE sqlite_sequence SET seq = ?1 WHERE name = 'messages'", [high_water])
        :ok

      [] when high_water > 0 ->
        Txn.q(txn, "INSERT INTO sqlite_sequence (name, seq) VALUES ('messages', ?1)", [high_water])

        :ok

      [] ->
        :ok

      [[_current]] ->
        :ok

      rows ->
        raise Tightbeam.Schema.ShapeError,
          message:
            "invalid messages sequence state during tool-call transition migration: #{inspect(rows)}"
    end
  end

  @doc false
  def normalize_notification(update) when is_map(update) do
    %{}
    |> maybe_put_string(update, "title", :title)
    |> maybe_put_string(update, "kind", :kind)
    |> maybe_put_string(update, "status", :status)
    |> maybe_put_meta_tool_name(update)
    |> maybe_put_json(update, "rawInput", :raw_input)
    |> maybe_put_json(update, "rawOutput", :raw_output)
    |> maybe_put_json(update, "content", :content)
  end

  def normalize_notification(_update), do: %{}

  @doc false
  def merge_pending(pending, current) when is_map(pending) and is_map(current),
    do: Map.merge(pending, current)

  @doc false
  def terminal_status?(status), do: status in @terminal_statuses

  @doc false
  def status(update), do: update["status"]

  @doc false
  def context_compaction?(%{"_meta" => meta}) when is_map(meta),
    do: contains_context_compaction?(meta)

  def context_compaction?(_update), do: false

  @doc "Observe one ACP tool notification, persisting only start and terminal commits."
  @spec observe(DB.server(), String.t(), integer(), String.t(), map(), map(), String.t() | nil) ::
          {:ok, :buffered | :started | :ended | :unchanged} | {:error, term()}
  def observe(db, session_key, turn_seq, harness_tool_call_id, fields, pending, compaction_from)
      when is_binary(session_key) and is_integer(turn_seq) and is_binary(harness_tool_call_id) and
             is_map(fields) and is_map(pending) do
    case DB.transaction(db, fn txn ->
           case find_by_harness_id_in_txn(txn, session_key, harness_tool_call_id) do
             nil ->
               attributes = fields
               insert_in_txn(txn, session_key, turn_seq, harness_tool_call_id, attributes)

               row = fetch_by_harness_id_in_txn(txn, session_key, harness_tool_call_id)
               terminal? = terminal_status?(row.status)
               publish_tool_call_in_txn(txn, row, terminal?)

               if terminal? and row.status == "completed" and is_binary(compaction_from) do
                 append_compaction_marker_in_txn(txn, session_key, compaction_from)
               end

               if terminal?, do: :ended, else: :started

             %{status: status} when status in @terminal_statuses ->
               :unchanged

             row ->
               attributes = merge_pending(pending, fields)

               if terminal_status?(Map.get(attributes, :status)) do
                 update_terminal_in_txn(txn, row, attributes)
                 updated = fetch_by_harness_id_in_txn(txn, session_key, harness_tool_call_id)
                 publish_tool_call_in_txn(txn, updated, true)

                 if updated.status == "completed" and is_binary(compaction_from) do
                   append_compaction_marker_in_txn(txn, session_key, compaction_from)
                 end

                 :ended
               else
                 :buffered
               end
           end
         end) do
      {:ok, result} -> {:ok, result}
      {:error, reason} -> {:error, reason}
    end
  rescue
    error -> {:error, error}
  end

  def observe(_db, _session_key, _turn_seq, _harness_tool_call_id, _fields, _pending, _from),
    do: {:error, :invalid_tool_call_context}

  @doc false
  def query_by_id(db, id) do
    case DB.query(db, select_sql() <> " WHERE tc.id = ?1", [id]) do
      {:ok, [row]} ->
        decode_row(row)

      {:ok, []} ->
        nil

      {:ok, rows} ->
        raise ArgumentError, "tool-call detail returned multiple rows: #{inspect(rows)}"

      {:error, error} ->
        raise error
    end
  end

  @doc false
  def query_by_id(db, session_key, id) do
    case DB.query(db, select_sql() <> " WHERE tc.sessionKey = ?1 AND tc.id = ?2", [
           session_key,
           id
         ]) do
      {:ok, [row]} ->
        decode_row(row)

      {:ok, []} ->
        nil

      {:ok, rows} ->
        raise ArgumentError, "tool-call detail returned multiple rows: #{inspect(rows)}"

      {:error, error} ->
        raise error
    end
  end

  @doc false
  def query_by_id_in_txn(txn, session_key, id) do
    case Txn.q(txn, select_sql() <> " WHERE tc.sessionKey = ?1 AND tc.id = ?2", [session_key, id]) do
      [row] -> decode_row(row)
      [] -> nil
      rows -> raise ArgumentError, "tool-call detail returned multiple rows: #{inspect(rows)}"
    end
  end

  @doc false
  def query_for_rebuild(db, id) do
    case DB.query(
           db,
           select_sql() <> " WHERE tc.id = ?1",
           [id]
         ) do
      {:ok, [row]} ->
        decode_row(row)

      {:ok, []} ->
        nil

      {:ok, rows} ->
        raise ArgumentError, "tool-call rebuild returned multiple rows: #{inspect(rows)}"

      {:error, error} ->
        raise error
    end
  end

  @doc false
  def page_for_session(db, session_key, boundary, limit, from_inclusive, to_exclusive) do
    with_read_transaction(db, fn txn ->
      base = ["tc.sessionKey = ?"]
      params = [session_key]

      {base, params} =
        if is_integer(from_inclusive),
          do: {base ++ ["tc.afterMessageSeq >= ?"], params ++ [from_inclusive]},
          else: {base, params}

      {base, params} =
        if is_integer(to_exclusive),
          do: {base ++ ["tc.afterMessageSeq < ?"], params ++ [to_exclusive]},
          else: {base, params}

      where = Enum.join(base, " AND ")
      query = fn sql, values -> Txn.q(txn, sql, values) end

      page =
        Tightbeam.Keyset.page(
          query,
          select_sql(),
          "tool_calls AS tc",
          where,
          params,
          ["tc.seq", "tc.id"],
          boundary,
          limit,
          fn [seq, id | _rest] -> [seq, id] end
        )

      %{rows: Enum.map(page.rows, &decode_row/1), flags: page}
    end)
  end

  defp insert_in_txn(txn, session_key, turn_seq, harness_tool_call_id, fields) do
    [[after_message_seq]] =
      Txn.q(txn, "SELECT COALESCE(MAX(seq), 0) FROM messages WHERE sessionKey = ?1", [session_key])

    status = Map.get(fields, :status, "pending")
    terminal? = terminal_status?(status)
    now = System.system_time(:millisecond)

    values = %{
      title: Map.get(fields, :title, ""),
      kind: Map.get(fields, :kind, "other"),
      tool_name: Map.get(fields, :tool_name),
      raw_input: Map.get(fields, :raw_input),
      raw_output: Map.get(fields, :raw_output),
      content: Map.get(fields, :content)
    }

    truncated = truncations(values)

    Txn.q(
      txn,
      """
      INSERT INTO tool_calls (
        id, sessionKey, turnSeq, afterMessageSeq, harnessToolCallId,
        title, kind, toolName, status, rawInput, rawOutput, content,
        truncated, startedAt, endedAt, rowVersion
      ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15, 1)
      """,
      [
        "tc_" <> Tightbeam.Id.uuid4(),
        session_key,
        turn_seq,
        after_message_seq,
        harness_tool_call_id,
        values.title,
        values.kind,
        values.tool_name,
        status,
        stored_json(values.raw_input),
        stored_json(values.raw_output),
        stored_json(values.content),
        JSON.encode!(truncated),
        now,
        if(terminal?, do: now, else: nil)
      ]
    )

    :ok
  end

  defp update_terminal_in_txn(txn, existing, attributes) do
    values = %{
      title: Map.get(attributes, :title, existing.title),
      kind: Map.get(attributes, :kind, existing.kind),
      tool_name: Map.get(attributes, :tool_name, existing.tool_name),
      raw_input: update_bounded(attributes, :raw_input, existing.raw_input),
      raw_output: update_bounded(attributes, :raw_output, existing.raw_output),
      content: update_bounded(attributes, :content, existing.content),
      status: Map.fetch!(attributes, :status)
    }

    truncated =
      (Enum.reject(existing.truncated, &Map.has_key?(attributes, truncation_atom(&1["field"]))) ++
         truncations(values, Map.take(attributes, [:raw_input, :raw_output, :content])))
      |> Enum.sort_by(&Map.fetch!(@truncation_order, &1["field"]))

    Txn.q(
      txn,
      """
      UPDATE tool_calls
      SET title=?1, kind=?2, toolName=?3, status=?4, rawInput=?5, rawOutput=?6,
          content=?7, truncated=?8, endedAt=?9, rowVersion=rowVersion+1
      WHERE id=?10 AND status IN ('pending','in_progress')
      """,
      [
        values.title,
        values.kind,
        values.tool_name,
        values.status,
        StateResources.encode_json_value(values.raw_input),
        StateResources.encode_json_value(values.raw_output),
        StateResources.encode_json_value(values.content),
        JSON.encode!(truncated),
        System.system_time(:millisecond),
        existing.id
      ]
    )

    if Txn.changes(txn) != 1 do
      raise ArgumentError, "tool-call terminal update lost its nonterminal row"
    end
  end

  defp update_bounded(attributes, field, current) do
    case Map.fetch(attributes, field) do
      {:ok, %{encoded: encoded}} -> JSON.decode!(encoded)
      :error -> current
    end
  end

  defp truncations(values, bounded_fields \\ nil) do
    fields = bounded_fields || Map.take(values, [:raw_input, :raw_output, :content])

    fields
    |> Enum.flat_map(fn
      {_field, %{truncated: truncation}} -> if truncation, do: [truncation], else: []
      _unbounded_or_absent -> []
    end)
    |> Enum.sort_by(&Map.fetch!(@truncation_order, &1["field"]))
  end

  defp publish_tool_call_in_txn(txn, row, terminal?) do
    assignment_id =
      case Txn.q(txn, "SELECT assignmentId FROM turns WHERE seq = ?1 AND sessionKey = ?2", [
             row.turn_seq,
             row.session_key
           ]) do
        [[assignment_id]] -> assignment_id
        [] -> nil
      end

    refs = %{
      "toolCallId" => row.id,
      "sessionKey" => row.session_key,
      "turnSeq" => row.turn_seq
    }

    refs =
      if is_binary(assignment_id),
        do: Map.put(refs, "assignmentId", assignment_id),
        else: refs

    Publisher.committed_in_txn(
      txn,
      if(terminal?, do: "tool_call.ended", else: "tool_call.started"),
      row,
      refs
    )
  end

  defp append_compaction_marker_in_txn(txn, session_key, from) do
    {:appended, message} =
      Projection.append_marker_in_txn(txn, session_key, %{
        kind: "context-compacted",
        from: from,
        to: "compacted"
      })

    Publisher.message_in_txn(txn, session_key, message)
    :ok
  end

  defp find_by_harness_id_in_txn(txn, session_key, harness_tool_call_id) do
    case Txn.q(
           txn,
           select_sql() <>
             " WHERE tc.sessionKey = ?1 AND tc.harnessToolCallId = ?2",
           [session_key, harness_tool_call_id]
         ) do
      [row] -> decode_row(row)
      [] -> nil
      rows -> raise ArgumentError, "tool-call key returned multiple rows: #{inspect(rows)}"
    end
  end

  defp fetch_by_harness_id_in_txn(txn, session_key, harness_tool_call_id) do
    find_by_harness_id_in_txn(txn, session_key, harness_tool_call_id) ||
      raise ArgumentError, "tool-call insert is missing from its transaction"
  end

  defp select_sql do
    """
    SELECT tc.seq, tc.id, tc.sessionKey, tc.turnSeq, tc.afterMessageSeq,
           tc.harnessToolCallId, tc.title, tc.kind, tc.toolName, tc.status,
           tc.rawInput, tc.rawOutput, tc.content, tc.truncated,
           tc.startedAt, tc.endedAt, tc.rowVersion
    FROM tool_calls AS tc
    """
  end

  defp decode_row([
         seq,
         id,
         session_key,
         turn_seq,
         after_message_seq,
         harness_tool_call_id,
         title,
         kind,
         tool_name,
         status,
         raw_input,
         raw_output,
         content,
         truncated,
         started_at,
         ended_at,
         row_version
       ]) do
    %{
      seq: seq,
      id: id,
      session_key: session_key,
      turn_seq: turn_seq,
      after_message_seq: after_message_seq,
      harness_tool_call_id: harness_tool_call_id,
      title: title,
      kind: kind,
      tool_name: tool_name,
      status: status,
      raw_input: decode_json(raw_input),
      raw_output: decode_json(raw_output),
      content: decode_json(content),
      truncated: JSON.decode!(truncated),
      started_at: started_at,
      ended_at: ended_at,
      row_version: row_version
    }
  end

  defp decode_json(nil), do: nil
  defp decode_json(value), do: JSON.decode!(value)

  defp stored_json(nil), do: nil
  defp stored_json(%{encoded: encoded}), do: encoded

  defp truncation_atom("rawInput"), do: :raw_input
  defp truncation_atom("rawOutput"), do: :raw_output
  defp truncation_atom("content"), do: :content

  defp maybe_put_string(fields, update, source, target) do
    case Map.fetch(update, source) do
      {:ok, value} when is_binary(value) -> Map.put(fields, target, value)
      {:ok, nil} when target == :status -> fields
      {:ok, _value} -> fields
      :error -> fields
    end
  end

  defp maybe_put_meta_tool_name(fields, update) do
    case get_in(update, ["_meta", "claudeCode", "toolName"]) do
      value when is_binary(value) -> Map.put(fields, :tool_name, value)
      _ -> fields
    end
  end

  defp maybe_put_json(fields, update, source, target) do
    case Map.fetch(update, source) do
      # ACP v1 treats null like omission for optional tool-call update fields.
      {:ok, nil} ->
        fields

      {:ok, value} ->
        encoded = StateResources.encode_json_value(value)

        if byte_size(encoded) <= @field_limit do
          Map.put(fields, target, %{encoded: encoded, truncated: nil})
        else
          prefix = utf8_prefix(encoded, @field_limit)

          field =
            Map.fetch!(
              %{raw_input: "rawInput", raw_output: "rawOutput", content: "content"},
              target
            )

          Map.put(fields, target, %{
            encoded: JSON.encode!(prefix),
            truncated: %{"field" => field, "originalBytes" => byte_size(encoded)}
          })
        end

      :error ->
        fields
    end
  end

  defp utf8_prefix(value, limit) do
    prefix = binary_part(value, 0, min(byte_size(value), limit))
    trim_utf8_tail(prefix)
  end

  defp trim_utf8_tail(value) do
    if String.valid?(value),
      do: value,
      else: trim_utf8_tail(binary_part(value, 0, byte_size(value) - 1))
  end

  defp contains_context_compaction?(map) when is_map(map) do
    Enum.any?(map, fn
      {"contextCompaction", value} when is_map(value) -> true
      {_key, value} when is_map(value) -> contains_context_compaction?(value)
      {_key, value} when is_list(value) -> Enum.any?(value, &contains_context_compaction?/1)
      _ -> false
    end)
  end

  defp contains_context_compaction?(list) when is_list(list),
    do: Enum.any?(list, &contains_context_compaction?/1)

  defp contains_context_compaction?(_value), do: false

  defp with_read_transaction(%Txn{} = txn, fun), do: fun.(txn)

  defp with_read_transaction(db, fun) do
    case DB.transaction(db, fun) do
      {:ok, result} -> result
      {:error, error} -> raise error
    end
  end
end
