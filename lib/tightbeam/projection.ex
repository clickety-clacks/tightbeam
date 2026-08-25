defmodule Tightbeam.Projection do
  @moduledoc """
  The messages projection store: a one-way cache of finalized harness truth
  for wire replay and display.

  `attentionTier` widened its VALUE domain (it now also carries -1, `:low`)
  without changing its column type, so `Tightbeam.Schema`'s shape stamp is
  unbumped on purpose: the stamp refuses a database this build cannot READ,
  and every row an older build wrote is still read correctly here. Nothing
  older ever wrote a -1, and nothing older reads this table.
  """

  alias Tightbeam.DB
  alias Tightbeam.DB.Txn
  alias Tightbeam.Origin

  @type db :: GenServer.server()

  @typedoc """
  The attention an author elects for a message. ONE vocabulary, shared by the
  agent's `attend` election over its own reply and by the substrate's notices
  (`Tightbeam.EventLog.notice/5`) — same tier names, same `attentionTier`
  payload key, same client consumer. `:low` extends the original normal|high
  pair DOWNWARD for ambient substrate information a client hides by default.

  Elevation is a NEW higher-attention message referencing the event, never a
  mutation of one already sent: these are records.
  """
  @type attention :: :low | :normal | :high

  @attention_tiers %{low: -1, normal: 0, high: 1}

  @typedoc """
  A stored message. `seq` is the per-store commit order — replay pages by it,
  the wire carries it on every frame, and the client settles order and
  identity with it; `llm_visible_message_id` is the id the harness saw.
  """
  @type message :: %{
          seq: integer(),
          id: String.t(),
          session_key: String.t(),
          role: String.t(),
          content: String.t(),
          timestamp: integer(),
          sender: String.t() | nil,
          device_id: String.t() | nil,
          client_message_id: String.t() | nil,
          reply_to_message_id: String.t() | nil,
          reply_to_client_message_id: String.t() | nil,
          llm_visible_message_id: String.t(),
          attachments: list(),
          attention_tier: integer(),
          message_type: String.t() | nil,
          marker: %{kind: String.t(), from: String.t(), to: String.t()} | nil
        }

  @marker_kinds ["harness-switch", "model-retune", "session-restart"]

  @ddl """
  CREATE TABLE IF NOT EXISTS messages (
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
  CREATE INDEX IF NOT EXISTS messages_session ON messages (sessionKey, seq);
  CREATE UNIQUE INDEX IF NOT EXISTS messages_client_dedupe
    ON messages (sessionKey, deviceId, clientMessageId)
    WHERE clientMessageId IS NOT NULL AND deviceId IS NOT NULL;
  CREATE TABLE IF NOT EXISTS read_states (
    userId            TEXT NOT NULL,
    sessionKey        TEXT NOT NULL,
    lastReadMessageId TEXT NOT NULL,
    PRIMARY KEY (userId, sessionKey)
  );
  """

  @spec ensure_schema(db()) :: :ok | {:error, term()}
  def ensure_schema(db \\ Tightbeam.DB), do: DB.execute(db, @ddl)

  @doc """
  Append a message, idempotently per client send. Dedupe scope is
  `(session_key, device_id, client_message_id)` — when both ids are present
  and a row already exists: same content → `{:duplicate, msg}` (safe client
  retry), different content → `{:conflict, msg}` (id reuse; caller rejects).
  Otherwise inserts and returns `{:appended, msg}`. Runs in one transaction so
  the check and insert are atomic.
  """
  @spec append(db(), map()) ::
          {:appended, message()} | {:duplicate, message()} | {:conflict, message()}
  def append(db \\ Tightbeam.DB, input) do
    transaction!(db, &append_in_txn(&1, input))
  end

  @doc "Append inside an existing DB transaction so a turn can commit with its echo."
  @spec append_in_txn(Txn.t(), map()) ::
          {:appended, message()} | {:duplicate, message()} | {:conflict, message()}
  def append_in_txn(%Txn{} = txn, input) do
    existing =
      case {Map.get(input, :client_message_id), Map.get(input, :device_id)} do
        {client_message_id, device_id}
        when is_binary(client_message_id) and is_binary(device_id) ->
          Txn.q(
            txn,
            """
              SELECT seq, id, sessionKey, role, content, timestamp, sender, deviceId,
                     clientMessageId, replyToMessageId, replyToClientMessageId,
                     llmVisibleMessageId, attachments, attentionTier,
                     messageType, markerKind, markerFrom, markerTo
              FROM messages
              WHERE sessionKey = ?1 AND deviceId = ?2 AND clientMessageId = ?3
            """,
            [Map.fetch!(input, :session_key), device_id, client_message_id]
          )

        _ ->
          []
      end

    case existing do
      [row] ->
        message = to_message(row)

        if message.content == Map.fetch!(input, :content) and
             message.reply_to_message_id == Map.get(input, :reply_to_message_id) and
             message.reply_to_client_message_id == Map.get(input, :reply_to_client_message_id),
           do: {:duplicate, message},
           else: {:conflict, message}

      [] ->
        id = "s_" <> Tightbeam.Id.uuid4()
        client_message_id = Map.get(input, :client_message_id)
        message_type = message_type(input)

        {marker_kind, marker_from, marker_to} =
          marker_columns(Map.get(input, :marker), message_type)

        Txn.q(
          txn,
          """
            INSERT INTO messages (id, sessionKey, role, content, timestamp, sender, deviceId,
              clientMessageId, replyToMessageId, replyToClientMessageId, llmVisibleMessageId, attachments,
              attentionTier, messageType, markerKind, markerFrom, markerTo)
            VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15, ?16, ?17)
          """,
          [
            id,
            Map.fetch!(input, :session_key),
            Map.fetch!(input, :role),
            Map.fetch!(input, :content),
            Map.get(input, :timestamp, System.system_time(:millisecond)),
            Map.get(input, :sender),
            Map.get(input, :device_id),
            client_message_id,
            Map.get(input, :reply_to_message_id),
            Map.get(input, :reply_to_client_message_id),
            Map.get(input, :llm_visible_message_id) || client_message_id || id,
            JSON.encode!(Map.get(input, :attachments, [])),
            Map.get(input, :attention_tier, 0),
            message_type,
            marker_kind,
            marker_from,
            marker_to
          ]
        )

        [row] = select_by_id(txn, id)
        {:appended, to_message(row)}
    end
  end

  @doc """
  Append a Tightbeam-authored substrate notice inside an existing transaction.
  Notices are records, not structural boundaries. Their readable content is
  caller-authored, while their class comes from the process origin.
  """
  @spec append_substrate_in_txn(Txn.t(), String.t(), String.t(), attention()) ::
          {:appended, message()}
  def append_substrate_in_txn(%Txn{} = txn, session_key, content, attention \\ :normal) do
    append_in_txn(txn, %{
      session_key: session_key,
      role: "assistant",
      content: content,
      sender: "process:tightbeam",
      message_type: "substrate",
      attention_tier: attention_tier(attention)
    })
  end

  @doc """
  Append one structural transcript boundary. Callers supply facts only;
  Tightbeam owns the readable label template, so a marker can never smuggle
  arbitrary prose into the structural payload.
  """
  @spec append_marker_in_txn(
          Txn.t(),
          String.t(),
          %{kind: String.t(), from: String.t(), to: String.t()},
          attention()
        ) :: {:appended, message()}
  def append_marker_in_txn(txn, session_key, marker, attention \\ :normal)

  def append_marker_in_txn(
        %Txn{} = txn,
        session_key,
        %{kind: kind, from: from, to: to} = marker,
        attention
      )
      when kind in @marker_kinds and is_binary(from) and is_binary(to) do
    append_in_txn(txn, %{
      session_key: session_key,
      role: "assistant",
      content: marker_content(kind, from, to),
      sender: "process:tightbeam",
      message_type: "marker",
      marker: marker,
      attention_tier: attention_tier(attention)
    })
  end

  def append_marker_in_txn(%Txn{}, _session_key, marker, _attention) do
    raise ArgumentError,
          "marker must be %{kind: kind, from: from, to: to}; kind must be one of #{inspect(@marker_kinds)}, got: #{inspect(marker)}"
  end

  @doc "Append a structural boundary outside an existing transaction."
  @spec append_marker(db(), String.t(), map(), attention()) :: {:appended, message()}
  def append_marker(db, session_key, marker, attention \\ :normal) do
    transaction!(db, &append_marker_in_txn(&1, session_key, marker, attention))
  end

  @doc "The stored tier for an elected attention name."
  @spec attention_tier(attention()) :: integer()
  def attention_tier(attention) when is_map_key(@attention_tiers, attention),
    do: Map.fetch!(@attention_tiers, attention)

  @doc """
  The elected attention a stored tier means. Total over what this store
  writes; anything else is a database in a shape nobody wrote, so it raises
  rather than guessing a name.
  """
  @spec attention_name(integer()) :: String.t()
  def attention_name(-1), do: "low"
  def attention_name(0), do: "normal"
  def attention_name(1), do: "high"

  @doc "Fetch one message by store id, or nil."
  @spec get(db(), String.t()) :: message() | nil
  def get(db \\ Tightbeam.DB, id) do
    {:ok, rows} =
      DB.query(
        db,
        """
          SELECT seq, id, sessionKey, role, content, timestamp, sender, deviceId,
                 clientMessageId, replyToMessageId, replyToClientMessageId,
                 llmVisibleMessageId, attachments, attentionTier,
                 messageType, markerKind, markerFrom, markerTo
          FROM messages WHERE id = ?1
        """,
        [id]
      )

    case rows do
      [row] -> to_message(row)
      [] -> nil
    end
  end

  @doc """
  Messages after `after_message_id` (nil or unknown id → from the start), in
  seq order — the replay feed. `limit` bounds the page. `min_seq` is the
  session's history barrier (clearedThroughSeq): rows at or below it exist
  but are never served — cleared history is retained, not presented.
  """
  @spec list_after(db(), String.t(), String.t() | nil, pos_integer(), integer()) :: [message()]
  def list_after(db \\ Tightbeam.DB, session_key, after_message_id, limit, min_seq \\ 0) do
    after_seq =
      max(
        min_seq,
        case after_message_id && get(db, after_message_id) do
          %{seq: seq} -> seq
          _ -> 0
        end
      )

    {:ok, rows} =
      DB.query(
        db,
        """
          SELECT seq, id, sessionKey, role, content, timestamp, sender, deviceId,
                 clientMessageId, replyToMessageId, replyToClientMessageId,
                 llmVisibleMessageId, attachments, attentionTier,
                 messageType, markerKind, markerFrom, markerTo
          FROM messages WHERE sessionKey = ?1 AND seq > ?2 ORDER BY seq ASC LIMIT ?3
        """,
        [session_key, after_seq, limit]
      )

    Enum.map(rows, &to_message/1)
  end

  @doc "Latest message's id + role for a session (catalog preview), or nil if empty."
  @spec tail(db(), String.t()) ::
          %{last_message_id: String.t(), last_message_role: String.t()} | nil
  def tail(db \\ Tightbeam.DB, session_key) do
    {:ok, rows} =
      DB.query(
        db,
        "SELECT id, role FROM messages WHERE sessionKey = ?1 ORDER BY seq DESC LIMIT 1",
        [session_key]
      )

    case rows do
      [[id, role]] -> %{last_message_id: id, last_message_role: role}
      [] -> nil
    end
  end

  @doc "Upsert a user's last-read pointer for a session (client display state only)."
  @spec set_read_state(db(), String.t(), String.t(), String.t()) :: :ok
  def set_read_state(db \\ Tightbeam.DB, user_id, session_key, last_read_message_id) do
    transaction!(db, fn txn ->
      Txn.q(
        txn,
        """
          INSERT INTO read_states (userId, sessionKey, lastReadMessageId) VALUES (?1, ?2, ?3)
          ON CONFLICT (userId, sessionKey) DO UPDATE
            SET lastReadMessageId = excluded.lastReadMessageId
        """,
        [user_id, session_key, last_read_message_id]
      )

      :ok
    end)
  end

  @doc "All of a user's read pointers, as `%{session_key => last_read_message_id}`."
  @spec read_states(db(), String.t()) :: %{optional(String.t()) => String.t()}
  def read_states(db \\ Tightbeam.DB, user_id) do
    {:ok, rows} =
      DB.query(db, "SELECT sessionKey, lastReadMessageId FROM read_states WHERE userId = ?1", [
        user_id
      ])

    Map.new(rows, fn [session_key, last_read_message_id] ->
      {session_key, last_read_message_id}
    end)
  end

  defp select_by_id(txn, id) do
    Txn.q(
      txn,
      """
        SELECT seq, id, sessionKey, role, content, timestamp, sender, deviceId,
               clientMessageId, replyToMessageId, replyToClientMessageId,
               llmVisibleMessageId, attachments, attentionTier,
               messageType, markerKind, markerFrom, markerTo
        FROM messages WHERE id = ?1
      """,
      [id]
    )
  end

  defp to_message([
         seq,
         id,
         session_key,
         role,
         content,
         timestamp,
         sender,
         device_id,
         client_message_id,
         reply_to_message_id,
         reply_to_client_message_id,
         llm_visible_message_id,
         attachments,
         attention_tier,
         message_type,
         marker_kind,
         marker_from,
         marker_to
       ]) do
    %{
      seq: seq,
      id: id,
      session_key: session_key,
      role: role,
      content: content,
      timestamp: timestamp,
      sender: sender,
      device_id: device_id,
      client_message_id: client_message_id,
      reply_to_message_id: reply_to_message_id,
      reply_to_client_message_id: reply_to_client_message_id,
      llm_visible_message_id: llm_visible_message_id,
      attachments: JSON.decode!(attachments),
      attention_tier: attention_tier,
      message_type: message_type,
      marker: marker(marker_kind, marker_from, marker_to)
    }
  end

  defp message_type(input) do
    case Map.fetch(input, :message_type) do
      {:ok, value} when is_binary(value) or is_nil(value) ->
        value

      {:ok, value} ->
        raise ArgumentError, "message_type must be a string or nil, got: #{inspect(value)}"

      :error ->
        inferred_message_type(Map.get(input, :sender))
    end
  end

  defp inferred_message_type("tightbeam"), do: "assistant"

  defp inferred_message_type(sender) do
    case Origin.parse(sender) do
      {:agent, _} -> "agent"
      {:process, _} -> "substrate"
      {:remedy, _} -> "substrate"
      _ -> nil
    end
  end

  defp marker_columns(nil, message_type) when message_type != "marker", do: {nil, nil, nil}

  defp marker_columns(%{kind: kind, from: from, to: to}, "marker")
       when kind in @marker_kinds and is_binary(from) and is_binary(to),
       do: {kind, from, to}

  defp marker_columns(marker, message_type) do
    raise ArgumentError,
          "message_type=marker requires %{kind: kind, from: string, to: string}; " <>
            "other message types must omit marker, got: #{inspect({message_type, marker})}"
  end

  defp marker(nil, _from, _to), do: nil
  defp marker(kind, from, to), do: %{kind: kind, from: from, to: to}

  defp marker_content("harness-switch", from, to) do
    "[engine swap]\n\n" <>
      "This session's engine changed from #{marker_endpoint(from)} to #{marker_endpoint(to)}.\n\n" <>
      "Earlier messages are RETAINED and are not deleted, but they are no longer " <>
      "shown here: a new engine cannot load the previous engine's session, so the " <>
      "visible transcript starts fresh from this point. This is expected after a " <>
      "harness swap, not a fault."
  end

  defp marker_content("model-retune", from, to) do
    "[model retune]\n\nThis session's model changed from #{marker_endpoint(from)} " <>
      "to #{marker_endpoint(to)}."
  end

  defp marker_content("session-restart", from, to) do
    "[context reset]\n\nThe agent's working memory was reset from #{marker_endpoint(from)} " <>
      "to #{marker_endpoint(to)} while handling the message above. Earlier messages stay " <>
      "visible here, but the agent no longer remembers them."
  end

  defp marker_endpoint(value), do: value

  defp transaction!(db, fun) do
    case DB.transaction(db, fun) do
      {:ok, result} -> result
      {:error, error} -> raise error
    end
  end
end
