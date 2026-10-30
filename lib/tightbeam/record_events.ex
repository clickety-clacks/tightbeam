defmodule Tightbeam.RecordEvents.ShapeError do
  @moduledoc false
  defexception [:message]
end

defmodule Tightbeam.RecordEvents do
  @moduledoc false

  alias Tightbeam.DB
  alias Tightbeam.DB.Txn
  alias Tightbeam.RecordEvents.ShapeError

  @activation_keys %{
    "work_item.filed" => "record-event-feed-activation:work_item.filed",
    "assignment.opened" => "record-event-feed-activation:assignment.opened"
  }

  @role_order %{"creator" => 0, "holder" => 1, "opener" => 2}

  @work_item_events_query """
  SELECT
    'work_item.filed:' || wi.id AS event_id,
    'work_item.filed' AS kind,
    wi.createdAt AS event_at,
    'work-item' AS record_type,
    wi.id AS record_id,
    wi.id AS work_item_id,
    '/api/work-items/' || wi.id AS detail,
    wi.createdBySession AS actor_session_key,
    CASE WHEN wi.createdContextKnown = 1 THEN wi.createdInTurnSeq END AS cause_turn_seq,
    'creator' AS tied_as
  FROM work_items AS wi
  WHERE wi.createdBySession = ?1
    AND wi.createdAt >= (
      SELECT CAST(value AS INTEGER)
      FROM org_settings
      WHERE key = 'record-event-feed-activation:work_item.filed'
    )
  ORDER BY wi.createdAt, wi.id
  """

  @assignment_holder_events_query """
  SELECT
    'assignment.opened:' || a.id AS event_id,
    'assignment.opened' AS kind,
    a.openedAt AS event_at,
    'assignment' AS record_type,
    a.id AS record_id,
    a.workItemId AS work_item_id,
    '/api/assignments/' || a.id AS detail,
    a.openedBySession AS actor_session_key,
    NULL AS cause_turn_seq,
    CASE WHEN a.openedBySession = ?1 THEN 'holder,opener' ELSE 'holder' END AS tied_as
  FROM assignments AS a
  WHERE a.holderKey = ?1
    AND a.openedAt >= (
      SELECT CAST(value AS INTEGER)
      FROM org_settings
      WHERE key = 'record-event-feed-activation:assignment.opened'
    )
  ORDER BY a.openedAt, a.id
  """

  @assignment_opener_events_query """
  SELECT
    'assignment.opened:' || a.id AS event_id,
    'assignment.opened' AS kind,
    a.openedAt AS event_at,
    'assignment' AS record_type,
    a.id AS record_id,
    a.workItemId AS work_item_id,
    '/api/assignments/' || a.id AS detail,
    a.openedBySession AS actor_session_key,
    NULL AS cause_turn_seq,
    'opener' AS tied_as
  FROM assignments AS a
  WHERE a.openedBySession = ?1
    AND a.holderKey <> ?1
    AND a.openedAt >= (
      SELECT CAST(value AS INTEGER)
      FROM org_settings
      WHERE key = 'record-event-feed-activation:assignment.opened'
    )

  ORDER BY a.openedAt, a.id
  """

  @event_sources [
    {@work_item_events_query, "work_items_rest_created_session_order"},
    {@assignment_holder_events_query, "assignments_record_event_holder_order"},
    {@assignment_opener_events_query, "assignments_record_event_opener_order"}
  ]

  @query_indexes [
    {"assignments_record_event_holder_order",
     "CREATE INDEX IF NOT EXISTS assignments_record_event_holder_order " <>
       "ON assignments(holderKey, openedAt, id)"},
    {"assignments_record_event_opener_order",
     "CREATE INDEX IF NOT EXISTS assignments_record_event_opener_order " <>
       "ON assignments(openedBySession, openedAt, id)"},
    {"messages_record_event_ids",
     "CREATE INDEX IF NOT EXISTS messages_record_event_ids " <>
       "ON messages(recordEventIds, sessionKey, seq, id) WHERE recordEventIds IS NOT NULL"},
    {"messages_record_event_reply",
     "CREATE INDEX IF NOT EXISTS messages_record_event_reply " <>
       "ON messages(replyToMessageId, sessionKey, seq, id) WHERE replyToMessageId IS NOT NULL"},
    {"wakes_record_event_ids",
     "CREATE INDEX IF NOT EXISTS wakes_record_event_ids " <>
       "ON wakes(recordEventIds, wakeId, deliveredTurnSeq) WHERE recordEventIds IS NOT NULL"}
  ]

  @work_item_event_by_id_query """
  SELECT
    'work_item.filed:' || wi.id AS event_id,
    'work_item.filed' AS kind,
    wi.createdAt AS event_at,
    'work-item' AS record_type,
    wi.id AS record_id,
    wi.id AS work_item_id,
    '/api/work-items/' || wi.id AS detail,
    wi.createdBySession AS actor_session_key,
    CASE WHEN wi.createdContextKnown = 1 THEN wi.createdInTurnSeq END AS cause_turn_seq,
    'creator' AS tied_as
  FROM work_items AS wi
  WHERE wi.id = ?2
    AND wi.createdBySession = ?1
    AND wi.createdAt >= (
      SELECT CAST(value AS INTEGER)
      FROM org_settings
      WHERE key = 'record-event-feed-activation:work_item.filed'
    )
  """

  @assignment_event_by_id_query """
  SELECT
    'assignment.opened:' || a.id AS event_id,
    'assignment.opened' AS kind,
    a.openedAt AS event_at,
    'assignment' AS record_type,
    a.id AS record_id,
    a.workItemId AS work_item_id,
    '/api/assignments/' || a.id AS detail,
    a.openedBySession AS actor_session_key,
    NULL AS cause_turn_seq,
    CASE
      WHEN a.holderKey = ?1 AND a.openedBySession = ?1 THEN 'holder,opener'
      WHEN a.holderKey = ?1 THEN 'holder'
      ELSE 'opener'
    END AS tied_as
  FROM assignments AS a
  WHERE a.id = ?2
    AND (a.holderKey = ?1 OR a.openedBySession = ?1)
    AND a.openedAt >= (
      SELECT CAST(value AS INTEGER)
      FROM org_settings
      WHERE key = 'record-event-feed-activation:assignment.opened'
    )
  """

  @notice_message_ids_query """
  WITH event_turns(seq) AS (
    -- Start from the event stamp, then follow its delivered turn. Digest
    -- members follow the cancellation's primary-key wake link to the carrier.
    SELECT direct_turn.seq
    FROM wakes AS direct_wake INDEXED BY wakes_record_event_ids
    JOIN turns AS direct_turn ON direct_turn.seq = direct_wake.deliveredTurnSeq
    WHERE direct_wake.recordEventIds = json_array(?1)
      AND direct_turn.sessionKey = ?2
      AND NOT EXISTS (
        SELECT 1 FROM turn_repair_attempts AS repair
        WHERE repair.attemptSeq = direct_turn.seq
      )

    UNION

    SELECT replacement_turn.seq
    FROM wakes AS member_wake INDEXED BY wakes_record_event_ids
    JOIN wake_cancellations AS cancellation ON cancellation.wakeId = member_wake.wakeId
    JOIN turns AS replacement_turn ON replacement_turn.wakeId = cancellation.replacementWakeId
    WHERE member_wake.recordEventIds = json_array(?1)
      AND cancellation.replacementWakeId IS NOT NULL
      AND replacement_turn.sessionKey = ?2
      AND NOT EXISTS (
        SELECT 1 FROM turn_repair_attempts AS repair
        WHERE repair.attemptSeq = replacement_turn.seq
      )
  ),
  notice_messages(message_id, message_seq) AS (
    -- A stored stamp names the one event written with that row. Digest member
    -- stamps are resolved separately through their replacement carrier turn.
    SELECT direct.id, direct.seq
    FROM messages AS direct INDEXED BY messages_record_event_ids
    WHERE direct.recordEventIds = json_array(?1)
      AND direct.sessionKey = ?2

    UNION

    SELECT notice.id, notice.seq
    FROM event_turns
    JOIN turns AS notice_turn ON notice_turn.seq = event_turns.seq
    JOIN messages AS notice ON notice.id = notice_turn.messageId
    WHERE notice.sessionKey = ?2
      AND notice.role = 'user'

    UNION

    SELECT notice.id, notice.seq
    FROM event_turns
    JOIN turns AS notice_turn ON notice_turn.seq = event_turns.seq
    JOIN messages AS notice INDEXED BY messages_record_event_reply
      ON notice.replyToMessageId = notice_turn.messageId
     AND notice.sessionKey = ?2
     AND notice.role = 'assistant'

    UNION

    SELECT source_message.id, source_message.seq
    FROM event_turns
    JOIN wakes AS source INDEXED BY wakes_delivered_turn
      ON source.deliveredTurnSeq = event_turns.seq
    JOIN messages AS source_message INDEXED BY messages_client_dedupe
      ON source_message.sessionKey = json_extract(source.sourceClientIdentity, '$.targetSessionKey')
     AND source_message.deviceId = json_extract(source.sourceClientIdentity, '$.deviceId')
     AND source_message.clientMessageId = json_extract(source.sourceClientIdentity, '$.clientMessageId')
    WHERE source.sourceClientIdentity IS NOT NULL
      AND source_message.sessionKey = ?2
      AND source_message.role = 'user'
      AND source_message.deviceId IS NOT NULL
      AND source_message.clientMessageId IS NOT NULL
  )
  SELECT COALESCE(json_group_array(message_id), '[]')
  FROM (
    SELECT message_id
    FROM notice_messages
    ORDER BY message_seq
  )
  """

  @doc "Add the stage-one notice columns and per-kind activation rows."
  @spec ensure_schema(DB.server()) :: :ok
  def ensure_schema(db \\ DB) do
    case DB.migration_transaction(
           db,
           :record_event_feed_stage_one,
           [],
           [],
           &ensure_schema_in_txn/1
         ) do
      {:ok, :activated} ->
        :ok

      {:ok, :already_active} ->
        :ok

      {:error, error} ->
        raise error
    end

    ensure_query_indexes(db)
  end

  @doc false
  def keyset_plan_queries(session_key) do
    Enum.map(@event_sources, fn {sql, index} -> {sql, [session_key], index} end)
  end

  @doc false
  def single_event_plan_queries(session_key, work_item_id, assignment_id) do
    [
      {@work_item_event_by_id_query, [session_key, work_item_id],
       "work_items_id_owner"},
      {@assignment_event_by_id_query, [session_key, assignment_id],
       "sqlite_autoindex_assignments_1"}
    ]
  end

  @doc false
  def notice_message_ids_plan_query(event_id, session_key),
    do: {@notice_message_ids_query, [event_id, session_key]}

  defp ensure_query_indexes(db) do
    case DB.migration_transaction(db, :record_event_feed_query_indexes, [], [], fn txn ->
           Enum.each(@query_indexes, fn {_name, sql} -> :ok = Txn.exec(txn, sql) end)
           :ok
         end) do
      {:ok, :ok} ->
        :ok

      {:error, error} ->
        raise error
    end
  end

  defp ensure_schema_in_txn(%Txn{} = txn) do
    activation_rows =
      Txn.q(
        txn,
        "SELECT key, value, updatedAt FROM org_settings WHERE key IN (?1, ?2) ORDER BY key",
        Map.values(@activation_keys)
      )

    messages_column = record_event_ids_column(txn, "messages")
    wakes_column = record_event_ids_column(txn, "wakes")

    case {activation_rows, messages_column, wakes_column} do
      {[], :absent, :absent} ->
        activate_stage_one_in_txn(txn)

      {rows, :valid, :valid} when length(rows) == map_size(@activation_keys) ->
        validate_activation_rows!(rows)
        :already_active

      state ->
        raise ShapeError,
          message: "incompatible record-event feed stage-one shape: #{inspect(state)}"
    end
  end

  defp activate_stage_one_in_txn(txn) do
    activated_at = System.system_time(:millisecond)

    :ok = Txn.exec(txn, "ALTER TABLE messages ADD COLUMN recordEventIds TEXT")
    :ok = Txn.exec(txn, "ALTER TABLE wakes ADD COLUMN recordEventIds TEXT")

    Enum.each(Map.values(@activation_keys), fn key ->
      Txn.q(
        txn,
        "INSERT OR IGNORE INTO org_settings (key, value, updatedAt) VALUES (?1, ?2, ?3)",
        [key, Integer.to_string(activated_at), activated_at]
      )

      if Txn.changes(txn) != 1 do
        raise ShapeError,
          message: "record-event feed activation key already exists: #{key}"
      end
    end)

    :activated
  end

  defp validate_activation_rows!(rows) do
    expected = MapSet.new(Map.values(@activation_keys))

    valid? =
      Enum.all?(rows, fn
        [key, value, updated_at] ->
          if key in Map.values(@activation_keys) and is_binary(value) and
               is_integer(updated_at) do
            case Integer.parse(value) do
              {activated_at, ""} -> activated_at >= 0 and updated_at == activated_at
              _ -> false
            end
          else
            false
          end

        _ ->
          false
      end) and MapSet.new(Enum.map(rows, &hd/1)) == expected

    unless valid? do
      raise ShapeError,
        message: "incompatible record-event feed stage-one activation rows: #{inspect(rows)}"
    end

    :ok
  end

  defp record_event_ids_column(txn, table) do
    case Enum.find(Txn.q(txn, "PRAGMA table_info(#{table})", []), fn
           [_cid, "recordEventIds" | _rest] -> true
           _ -> false
         end) do
      nil ->
        :absent

      [_cid, "recordEventIds", "TEXT", 0, nil, 0] ->
        :valid

      definition ->
        {:invalid, definition}
    end
  end

  @doc "Return one bounded page of the session's active record events."
  def query_for_session_page(source, session_key, boundary, limit) do
    with_read_transaction(source, fn txn ->
      page =
        txn
        |> query_session_event_rows(session_key)
        |> page_session_events(boundary, limit)

      rows =
        Enum.map(page.rows, fn row ->
          event_id = hd(row)
          notice_ids = notice_message_ids_in_txn(txn, event_id, session_key)
          wire_item(row, notice_ids)
        end)

      %{rows: rows, flags: page}
    end)
  end

  defp query_session_event_rows(txn, session_key) do
    @event_sources
    |> Enum.flat_map(fn {sql, _index} -> Txn.q(txn, sql, [session_key]) end)
    |> Enum.sort_by(&event_cursor/1)
  end

  defp page_session_events(rows, :latest, limit) do
    page = Enum.take(rows, -limit)

    %{
      rows: page,
      has_more_before: length(rows) > limit,
      has_more_after: false,
      candidate_count: min(length(rows), limit + 1)
    }
  end

  defp page_session_events(rows, :earliest, limit) do
    page = Enum.take(rows, limit)

    %{
      rows: page,
      has_more_before: false,
      has_more_after: length(rows) > limit,
      candidate_count: min(length(rows), limit + 1)
    }
  end

  defp page_session_events(rows, {:before, cursor}, limit) do
    eligible = Enum.filter(rows, &(event_cursor(&1) < cursor))
    page = Enum.take(eligible, -limit)
    newest = if page == [], do: cursor, else: event_cursor(List.last(page))

    %{
      rows: page,
      has_more_before: length(eligible) > limit,
      has_more_after: Enum.any?(rows, &(event_cursor(&1) > newest)),
      candidate_count: min(length(eligible), limit + 1)
    }
  end

  defp page_session_events(rows, {:after, cursor}, limit) do
    eligible = Enum.filter(rows, &(event_cursor(&1) > cursor))
    page = Enum.take(eligible, limit)
    oldest = if page == [], do: cursor, else: event_cursor(hd(page))

    %{
      rows: page,
      has_more_before: Enum.any?(rows, &(event_cursor(&1) < oldest)),
      has_more_after: length(eligible) > limit,
      candidate_count: min(length(eligible), limit + 1)
    }
  end

  defp event_cursor(row), do: [Enum.at(row, 2), hd(row)]

  @doc false
  def work_item_filed_in_txn(%Txn{} = txn, work_item_id) do
    case Txn.q(txn, "SELECT createdBySession FROM work_items WHERE id = ?1", [work_item_id]) do
      [[session_key]] when is_binary(session_key) ->
        case event_for_session_in_txn(txn, "work_item.filed:" <> work_item_id, session_key) do
          nil -> nil
          item -> {session_key, item}
        end

      [[nil]] ->
        nil

      [] ->
        raise ArgumentError, "new work item is missing from its creation transaction"
    end
  end

  @doc false
  def assignment_opened_in_txn(%Txn{} = txn, assignment_id) do
    case Txn.q(
           txn,
           "SELECT holderKey, openedBySession FROM assignments WHERE id = ?1",
           [assignment_id]
         ) do
      [[holder_key, opener_session]] ->
        [holder_key, opener_session]
        |> Enum.reject(&is_nil/1)
        |> Enum.uniq()
        |> Enum.flat_map(fn session_key ->
          case event_for_session_in_txn(
                 txn,
                 "assignment.opened:" <> assignment_id,
                 session_key
               ) do
            nil -> []
            item -> [{session_key, item}]
          end
        end)

      [] ->
        raise ArgumentError, "new assignment is missing from its opening transaction"
    end
  end

  defp event_for_session_in_txn(txn, event_id, session_key) do
    case query_event_in_txn(txn, session_key, event_id) do
      nil -> nil
      item -> item
    end
  end

  defp query_event_in_txn(txn, session_key, event_id) do
    case event_rows_by_id(txn, session_key, event_id) do
      [row] ->
        wire_item(row, notice_message_ids_in_txn(txn, event_id, session_key))

      [] ->
        nil
    end
  end

  defp event_rows_by_id(txn, session_key, event_id) do
    case String.split(event_id, ":", parts: 2) do
      ["work_item.filed", work_item_id] ->
        Txn.q(txn, @work_item_event_by_id_query, [session_key, work_item_id])

      ["assignment.opened", assignment_id] ->
        Txn.q(txn, @assignment_event_by_id_query, [session_key, assignment_id])

      _ ->
        []
    end
  end

  defp notice_message_ids_in_txn(txn, event_id, session_key) do
    case Txn.q(txn, @notice_message_ids_query, [event_id, session_key]) do
      [[encoded_ids]] when is_binary(encoded_ids) ->
        encoded_ids |> JSON.decode!() |> Enum.uniq()

      _ ->
        []
    end
  end

  defp wire_item(
         [
           event_id,
           kind,
           event_at,
           record_type,
           record_id,
           work_item_id,
           detail,
           actor_session_key,
           cause_turn_seq,
           tied_as_roles
         ],
         notice_message_ids
       ) do
    %{
      "eventId" => event_id,
      "kind" => kind,
      "at" => event_at,
      "record" => %{
        "type" => record_type,
        "id" => record_id,
        "workItemId" => work_item_id,
        "detail" => detail
      },
      "actorSessionKey" => actor_session_key,
      "tiedAs" => tied_as_roles(tied_as_roles),
      "cause" =>
        if(is_integer(cause_turn_seq), do: %{"turnSeq" => cause_turn_seq, "messageId" => nil}),
      "noticeMessageIds" => notice_message_ids
    }
  end

  defp tied_as_roles(roles) do
    roles
    |> String.split(",", trim: true)
    |> Enum.uniq()
    |> Enum.sort_by(&Map.fetch!(@role_order, &1))
  end

  defp with_read_transaction(%Txn{} = txn, fun), do: fun.(txn)

  defp with_read_transaction(db, fun) do
    case DB.read_transaction(db, fun) do
      {:ok, result} -> result
      {:error, error} -> raise error
    end
  end
end
