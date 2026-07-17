defmodule Tightbeam.Org do
  @moduledoc """
  Session registry for wire identity, organization identity, model provenance,
  and append-only harness-session pointer chains.
  """

  alias Tightbeam.DB
  alias Tightbeam.DB.Txn

  @ddl """
  CREATE TABLE IF NOT EXISTS sessions (
    sessionKey    TEXT PRIMARY KEY,
    displayName   TEXT NOT NULL,
    kind          TEXT NOT NULL DEFAULT 'custom' CHECK (kind IN ('main','dm','custom')),
    orderIndex    INTEGER NOT NULL DEFAULT 0,
    isBuiltIn     INTEGER NOT NULL DEFAULT 0,
    adopted       INTEGER NOT NULL DEFAULT 0,
    ownerUserId   TEXT NOT NULL,
    origin        TEXT NOT NULL,
    spawnedBy     TEXT,
    handle        TEXT UNIQUE,
    archetype     TEXT NOT NULL,
    harness       TEXT NOT NULL CHECK (harness IN ('claude','codex')),
    provider      TEXT NOT NULL CHECK (provider IN ('anthropic','openai')),
    model         TEXT NOT NULL,
    thinkingLevel TEXT,
    state         TEXT NOT NULL DEFAULT 'active' CHECK (state IN ('active','retired')),
    createdAt     INTEGER NOT NULL,
    updatedAt     INTEGER NOT NULL
  );
  CREATE INDEX IF NOT EXISTS sessions_owner ON sessions (ownerUserId, state);
  CREATE TABLE IF NOT EXISTS harness_pointers (
    id               INTEGER PRIMARY KEY AUTOINCREMENT,
    sessionKey       TEXT NOT NULL REFERENCES sessions(sessionKey),
    harnessSessionId TEXT NOT NULL,
    reason           TEXT NOT NULL CHECK (reason IN ('created','loaded','fallback')),
    createdAt        INTEGER NOT NULL
  );
  CREATE INDEX IF NOT EXISTS pointers_session ON harness_pointers (sessionKey, id);
  """

  def ensure_schema(db \\ Tightbeam.DB), do: DB.execute(db, @ddl)

  def create(db \\ Tightbeam.DB, input) do
    transaction!(db, fn txn ->
      session_key =
        Map.get(input, :session_key) || custom_session_key(Map.fetch!(input, :owner_user_id))

      now = now()

      Txn.q(
        txn,
        """
          INSERT INTO sessions (sessionKey, displayName, kind, orderIndex, isBuiltIn, adopted,
            ownerUserId, origin, spawnedBy, handle, archetype, harness, provider, model,
            thinkingLevel, state, createdAt, updatedAt)
          VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14,
            ?15, 'active', ?16, ?16)
        """,
        [
          session_key,
          Map.fetch!(input, :display_name),
          Map.get(input, :kind, "custom"),
          Map.get(input, :order_index, 0),
          if(Map.get(input, :is_built_in, false), do: 1, else: 0),
          if(Map.get(input, :adopted, false), do: 1, else: 0),
          Map.fetch!(input, :owner_user_id),
          Map.fetch!(input, :origin),
          Map.get(input, :spawned_by),
          Map.get(input, :handle),
          Map.fetch!(input, :archetype),
          Map.fetch!(input, :harness),
          Map.fetch!(input, :provider),
          Map.fetch!(input, :model),
          Map.get(input, :thinking_level),
          now
        ]
      )

      must_get(txn, session_key)
    end)
  end

  def get(db \\ Tightbeam.DB, session_key) do
    {:ok, rows} = DB.query(db, select_session_sql() <> " WHERE sessionKey = ?1", [session_key])

    case rows do
      [row] -> to_session(row)
      [] -> nil
    end
  end

  def get_by_handle(db \\ Tightbeam.DB, handle) do
    {:ok, rows} = DB.query(db, select_session_sql() <> " WHERE handle = ?1", [handle])

    case rows do
      [row] -> to_session(row)
      [] -> nil
    end
  end

  def list_for_user(db \\ Tightbeam.DB, user_id, is_admin) do
    {where, params, order} =
      if is_admin do
        {"state = 'active'", [], "ownerUserId, orderIndex, createdAt"}
      else
        {"ownerUserId = ?1 AND state = 'active'", [user_id], "orderIndex, createdAt"}
      end

    {:ok, rows} =
      DB.query(db, select_session_sql() <> " WHERE #{where} ORDER BY #{order}", params)

    Enum.map(rows, &to_session/1)
  end

  def rename(db \\ Tightbeam.DB, session_key, display_name) do
    update(db, session_key, "displayName = ?2", [display_name])
  end

  def set_model(db \\ Tightbeam.DB, session_key, model, provider) do
    update(db, session_key, "model = ?2, provider = ?3", [model, provider])
  end

  def retire(db \\ Tightbeam.DB, session_key) do
    update(db, session_key, "state = 'retired'", [])
  end

  def append_pointer(db \\ Tightbeam.DB, session_key, harness_session_id, reason) do
    transaction!(db, fn txn ->
      must_get(txn, session_key)
      created_at = now()

      Txn.q(
        txn,
        """
          INSERT INTO harness_pointers (sessionKey, harnessSessionId, reason, createdAt)
          VALUES (?1, ?2, ?3, ?4)
        """,
        [session_key, harness_session_id, reason, created_at]
      )

      %{
        session_key: session_key,
        harness_session_id: harness_session_id,
        reason: reason,
        created_at: created_at
      }
    end)
  end

  def current_pointer(db \\ Tightbeam.DB, session_key) do
    case Enum.reverse(pointer_chain(db, session_key)) do
      [pointer | _] -> pointer
      [] -> nil
    end
  end

  def pointer_chain(db \\ Tightbeam.DB, session_key) do
    {:ok, rows} =
      DB.query(
        db,
        """
          SELECT sessionKey, harnessSessionId, reason, createdAt
          FROM harness_pointers WHERE sessionKey = ?1 ORDER BY id ASC
        """,
        [session_key]
      )

    Enum.map(rows, fn [key, harness_session_id, reason, created_at] ->
      %{
        session_key: key,
        harness_session_id: harness_session_id,
        reason: reason,
        created_at: created_at
      }
    end)
  end

  def personal_session_key(user_id), do: "agent:main:clawline:#{user_id}:main"

  def custom_session_key(user_id) do
    "agent:main:clawline:#{user_id}:main s_#{String.slice(uuid4(), 0, 8)}"
  end

  defp update(db, session_key, sets, values) do
    transaction!(db, fn txn ->
      must_get(txn, session_key)

      params = [session_key | values] ++ [now()]
      updated_at_index = length(params)

      Txn.q(
        txn,
        "UPDATE sessions SET #{sets}, updatedAt = ?#{updated_at_index} WHERE sessionKey = ?1",
        params
      )

      must_get(txn, session_key)
    end)
  end

  defp must_get(txn, session_key) do
    case Txn.q(txn, select_session_sql() <> " WHERE sessionKey = ?1", [session_key]) do
      [row] -> to_session(row)
      [] -> raise ArgumentError, "unknown session: #{session_key}"
    end
  end

  defp select_session_sql do
    """
    SELECT sessionKey, displayName, kind, orderIndex, isBuiltIn, adopted,
           ownerUserId, origin, spawnedBy, handle, archetype, harness, provider,
           model, thinkingLevel, state, createdAt, updatedAt
    FROM sessions
    """
  end

  defp to_session([
         session_key,
         display_name,
         kind,
         order_index,
         is_built_in,
         adopted,
         owner_user_id,
         origin,
         spawned_by,
         handle,
         archetype,
         harness,
         provider,
         model,
         thinking_level,
         state,
         created_at,
         updated_at
       ]) do
    %{
      session_key: session_key,
      display_name: display_name,
      kind: kind,
      order_index: order_index,
      is_built_in: is_built_in == 1,
      adopted: adopted == 1,
      owner_user_id: owner_user_id,
      origin: origin,
      spawned_by: spawned_by,
      handle: handle,
      archetype: archetype,
      harness: harness,
      provider: provider,
      model: model,
      thinking_level: thinking_level,
      state: state,
      created_at: created_at,
      updated_at: updated_at
    }
  end

  defp transaction!(db, fun) do
    case DB.transaction(db, fun) do
      {:ok, result} -> result
      {:error, error} -> raise error
    end
  end

  defp now, do: System.system_time(:millisecond)

  defp uuid4 do
    <<a::48, _::4, b::12, _::2, c::62>> = :crypto.strong_rand_bytes(16)
    hex = Base.encode16(<<a::48, 4::4, b::12, 2::2, c::62>>, case: :lower)

    Enum.join(
      [
        binary_part(hex, 0, 8),
        binary_part(hex, 8, 4),
        binary_part(hex, 12, 4),
        binary_part(hex, 16, 4),
        binary_part(hex, 20, 12)
      ],
      "-"
    )
  end
end
