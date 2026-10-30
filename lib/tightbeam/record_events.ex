defmodule Tightbeam.RecordEvents.ShapeError do
  @moduledoc false
  defexception [:message]
end

defmodule Tightbeam.RecordEvents do
  @moduledoc false

  alias Tightbeam.DB
  alias Tightbeam.DB.Txn
  alias Tightbeam.Keyset
  alias Tightbeam.RecordEvents.ShapeError

  @activation_keys %{
    "work_item.filed" => "record-event-feed-activation:work_item.filed",
    "assignment.opened" => "record-event-feed-activation:assignment.opened"
  }

  @role_order %{"creator" => 0, "holder" => 1, "opener" => 2}

  @event_rows """
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
    wi.createdBySession AS session_key,
    'creator' AS tied_as
  FROM work_items AS wi
  JOIN org_settings AS activation
    ON activation.key = 'record-event-feed-activation:work_item.filed'
  WHERE wi.createdBySession IS NOT NULL
    AND wi.createdAt >= CAST(activation.value AS INTEGER)

  UNION ALL

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
    a.holderKey AS session_key,
    'holder' AS tied_as
  FROM assignments AS a
  JOIN org_settings AS activation
    ON activation.key = 'record-event-feed-activation:assignment.opened'
  WHERE a.holderKey IS NOT NULL
    AND a.openedAt >= CAST(activation.value AS INTEGER)

  UNION ALL

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
    a.openedBySession AS session_key,
    'opener' AS tied_as
  FROM assignments AS a
  JOIN org_settings AS activation
    ON activation.key = 'record-event-feed-activation:assignment.opened'
  WHERE a.openedBySession IS NOT NULL
    AND a.openedAt >= CAST(activation.value AS INTEGER)
  """

  @event_page_from """
  (
    SELECT
      event_id,
      kind,
      event_at,
      record_type,
      record_id,
      work_item_id,
      detail,
      actor_session_key,
      cause_turn_seq,
      session_key,
      GROUP_CONCAT(tied_as) AS tied_as_roles,
      (
        SELECT COALESCE(json_group_array(notice_message_id), '[]')
        FROM (
          SELECT m.id AS notice_message_id
          FROM messages AS m
          WHERE m.sessionKey = event_rows.session_key
            AND (
              EXISTS (
                SELECT 1
                FROM json_each(COALESCE(m.recordEventIds, '[]')) AS ids
                WHERE ids.value = event_rows.event_id
              )
              OR EXISTS (
                SELECT 1
                FROM turns AS notice_turn
                JOIN wakes AS notice_wake ON notice_wake.wakeId = notice_turn.wakeId
                CROSS JOIN json_each(COALESCE(notice_wake.recordEventIds, '[]')) AS ids
                WHERE notice_turn.seq IN (
                  SELECT direct.seq
                  FROM turns AS direct
                  WHERE direct.messageId = CASE m.role WHEN 'user' THEN m.id ELSE m.replyToMessageId END
                  UNION
                  SELECT source.deliveredTurnSeq
                  FROM wakes AS source INDEXED BY notice_source_client_identity
                  WHERE m.role='user' AND m.deviceId IS NOT NULL AND m.clientMessageId IS NOT NULL
                    AND source.sourceClientIdentity IS NOT NULL
                    AND json_extract(source.sourceClientIdentity,'$.targetSessionKey')=+m.sessionKey
                    AND json_extract(source.sourceClientIdentity,'$.deviceId')=+m.deviceId
                    AND json_extract(source.sourceClientIdentity,'$.clientMessageId')=+m.clientMessageId
                    AND source.deliveredTurnSeq IS NOT NULL
                )
                  AND NOT EXISTS (
                    SELECT 1 FROM turn_repair_attempts AS repair
                    WHERE repair.attemptSeq = notice_turn.seq
                  )
                  AND ids.value = event_rows.event_id
              )
              OR EXISTS (
                SELECT 1
                FROM turns AS notice_turn
                JOIN wake_cancellations AS cancellation
                  ON cancellation.replacementWakeId = notice_turn.wakeId
                JOIN wakes AS member_wake ON member_wake.wakeId = cancellation.wakeId
                CROSS JOIN json_each(COALESCE(member_wake.recordEventIds, '[]')) AS ids
                WHERE notice_turn.seq IN (
                  SELECT direct.seq
                  FROM turns AS direct
                  WHERE direct.messageId = CASE m.role WHEN 'user' THEN m.id ELSE m.replyToMessageId END
                  UNION
                  SELECT source.deliveredTurnSeq
                  FROM wakes AS source INDEXED BY notice_source_client_identity
                  WHERE m.role='user' AND m.deviceId IS NOT NULL AND m.clientMessageId IS NOT NULL
                    AND source.sourceClientIdentity IS NOT NULL
                    AND json_extract(source.sourceClientIdentity,'$.targetSessionKey')=+m.sessionKey
                    AND json_extract(source.sourceClientIdentity,'$.deviceId')=+m.deviceId
                    AND json_extract(source.sourceClientIdentity,'$.clientMessageId')=+m.clientMessageId
                    AND source.deliveredTurnSeq IS NOT NULL
                )
                  AND NOT EXISTS (
                    SELECT 1 FROM turn_repair_attempts AS repair
                    WHERE repair.attemptSeq = notice_turn.seq
                  )
                  AND ids.value = event_rows.event_id
              )
            )
          ORDER BY m.seq
        )
      ) AS notice_message_ids
    FROM (
      #{@event_rows}
    ) AS event_rows
    GROUP BY event_id, session_key
  ) AS record_events
  """

  @event_select """
  SELECT event_id, kind, event_at, record_type, record_id, work_item_id, detail,
         actor_session_key, cause_turn_seq, tied_as_roles, notice_message_ids
  FROM #{@event_page_from}
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
      query = fn sql, params -> Txn.q(txn, sql, params) end

      Keyset.page(
        query,
        @event_select,
        @event_page_from,
        "session_key = ?",
        [session_key],
        ["event_at", "event_id"],
        boundary,
        limit,
        fn row -> [Enum.at(row, 2), hd(row)] end
      )
    end)
    |> then(fn page -> %{rows: Enum.map(page.rows, &wire_item/1), flags: page} end)
  end

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
    case Txn.q(
           txn,
           @event_select <> " WHERE session_key = ?1 AND event_id = ?2",
           [session_key, event_id]
         ) do
      [row] -> wire_item(row)
      [] -> nil
    end
  end

  defp wire_item([
         event_id,
         kind,
         event_at,
         record_type,
         record_id,
         work_item_id,
         detail,
         actor_session_key,
         cause_turn_seq,
         tied_as_roles,
         notice_message_ids
       ]) do
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
      "noticeMessageIds" => notice_message_ids |> JSON.decode!() |> Enum.uniq()
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
