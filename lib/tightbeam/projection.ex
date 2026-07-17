defmodule Tightbeam.Projection do
  @moduledoc """
  The messages projection store: a one-way cache of finalized harness truth
  for wire replay and display.
  """

  alias Tightbeam.DB
  alias Tightbeam.DB.Txn

  @type db :: GenServer.server()
  @typedoc "A finalized message as stored for replay and display."
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
          attachments: [term()]
        }
  @typedoc "Fields accepted when appending a finalized message."
  @type message_input :: %{
          required(:session_key) => String.t(),
          required(:role) => String.t(),
          required(:content) => String.t(),
          optional(:timestamp) => integer(),
          optional(:sender) => String.t() | nil,
          optional(:device_id) => String.t() | nil,
          optional(:client_message_id) => String.t() | nil,
          optional(:reply_to_message_id) => String.t() | nil,
          optional(:reply_to_client_message_id) => String.t() | nil,
          optional(:llm_visible_message_id) => String.t() | nil,
          optional(:attachments) => [term()]
        }
  @type tail :: %{last_message_id: String.t(), last_message_role: String.t()}

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
    attachments            TEXT NOT NULL DEFAULT '[]'
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

  @doc "Ensure the additive messages projection schema exists."
  @spec ensure_schema(db()) :: :ok | {:error, term()}
  def ensure_schema(db \\ Tightbeam.DB), do: DB.execute(db, @ddl)

  @doc "Append one finalized message, preserving per-device client-message deduplication."
  @spec append(db(), message_input()) ::
          {:appended, message()} | {:duplicate, message()} | {:conflict, message()}
  def append(db \\ Tightbeam.DB, input) do
    transaction!(db, fn txn ->
      existing =
        case {Map.get(input, :client_message_id), Map.get(input, :device_id)} do
          {client_message_id, device_id}
          when is_binary(client_message_id) and is_binary(device_id) ->
            Txn.q(
              txn,
              """
                SELECT seq, id, sessionKey, role, content, timestamp, sender, deviceId,
                       clientMessageId, replyToMessageId, replyToClientMessageId,
                       llmVisibleMessageId, attachments
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

          if message.content == Map.fetch!(input, :content) do
            {:duplicate, message}
          else
            {:conflict, message}
          end

        [] ->
          id = "s_" <> Tightbeam.Id.uuid4()
          client_message_id = Map.get(input, :client_message_id)

          Txn.q(
            txn,
            """
              INSERT INTO messages (id, sessionKey, role, content, timestamp, sender, deviceId,
                clientMessageId, replyToMessageId, replyToClientMessageId, llmVisibleMessageId, attachments)
              VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12)
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
              JSON.encode!(Map.get(input, :attachments, []))
            ]
          )

          [row] = select_by_id(txn, id)
          {:appended, to_message(row)}
      end
    end)
  end

  @doc "Return one projected message by id, or nil when it is absent."
  @spec get(db(), String.t()) :: message() | nil
  def get(db \\ Tightbeam.DB, id) do
    {:ok, rows} =
      DB.query(
        db,
        """
          SELECT seq, id, sessionKey, role, content, timestamp, sender, deviceId,
                 clientMessageId, replyToMessageId, replyToClientMessageId,
                 llmVisibleMessageId, attachments
          FROM messages WHERE id = ?1
        """,
        [id]
      )

    case rows do
      [row] -> to_message(row)
      [] -> nil
    end
  end

  @doc "List a session's messages after a cursor in durable sequence order."
  @spec list_after(db(), String.t(), String.t() | nil, pos_integer()) :: [message()]
  def list_after(db \\ Tightbeam.DB, session_key, after_message_id, limit) do
    after_seq =
      case after_message_id && get(db, after_message_id) do
        %{seq: seq} -> seq
        _ -> 0
      end

    {:ok, rows} =
      DB.query(
        db,
        """
          SELECT seq, id, sessionKey, role, content, timestamp, sender, deviceId,
                 clientMessageId, replyToMessageId, replyToClientMessageId,
                 llmVisibleMessageId, attachments
          FROM messages WHERE sessionKey = ?1 AND seq > ?2 ORDER BY seq ASC LIMIT ?3
        """,
        [session_key, after_seq, limit]
      )

    Enum.map(rows, &to_message/1)
  end

  @doc "Return a session's latest message identity and role, or nil when empty."
  @spec tail(db(), String.t()) :: tail() | nil
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

  @doc "Upsert a user's last-read message for one session."
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

  @doc "Return a user's last-read message ids keyed by session."
  @spec read_states(db(), String.t()) :: %{String.t() => String.t()}
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
               llmVisibleMessageId, attachments
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
         attachments
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
      attachments: JSON.decode!(attachments)
    }
  end

  defp transaction!(db, fun) do
    case DB.transaction(db, fun) do
      {:ok, result} -> result
      {:error, error} -> raise error
    end
  end
end
