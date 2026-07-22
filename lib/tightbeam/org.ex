defmodule Tightbeam.Org do
  @moduledoc """
  Session registry for wire identity, organization identity, model provenance,
  and append-only harness-session pointer chains.
  """

  alias Tightbeam.DB
  alias Tightbeam.DB.Txn

  @type db :: GenServer.server()

  @typedoc """
  A session row. Identity-is-data: `origin`/`spawned_by` record WHO created it
  (provenance is append-only fact, not judgment); `handle` is the vestigial
  spawn-time name record; `archetype`/`harness`/`provider`/`model` are the current
  tuning.
  """
  @type session :: %{
          session_key: String.t(),
          display_name: String.t(),
          kind: String.t(),
          order_index: integer(),
          is_built_in: boolean(),
          adopted: boolean(),
          owner_user_id: String.t(),
          origin: String.t(),
          spawned_by: String.t() | nil,
          handle: String.t() | nil,
          archetype: String.t(),
          overrides: map() | nil,
          identity_name: String.t(),
          cli_token: String.t() | nil,
          harness: String.t(),
          provider: String.t(),
          model: String.t(),
          thinking_level: String.t() | nil,
          host: String.t(),
          cleared_through_seq: integer(),
          adjudication_hold: String.t() | nil,
          state: String.t(),
          created_at: integer(),
          updated_at: integer()
        }

  @typedoc "One link in a session's append-only harness-session pointer chain."
  @type pointer :: %{
          session_key: String.t(),
          harness_session_id: String.t(),
          reason: String.t(),
          created_at: integer()
        }

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
    overrides     TEXT,
    identityName  TEXT,
    cliToken      TEXT,
    harness       TEXT NOT NULL CHECK (harness IN ('claude','codex')),
    provider      TEXT NOT NULL CHECK (provider IN ('anthropic','openai')),
    model         TEXT NOT NULL,
    thinkingLevel TEXT,
    host          TEXT NOT NULL DEFAULT 'local',
    clearedThroughSeq INTEGER NOT NULL DEFAULT 0,
    adjudicationHold TEXT,
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

  @spec ensure_schema(db()) :: :ok | {:error, term()}
  def ensure_schema(db \\ Tightbeam.DB) do
    result = DB.execute(db, @ddl)
    # Additive migration for pre-placement databases (incl. TS-created ones,
    # adopt-in-place): a DEFAULT'd column is invisible to writers that name
    # their columns. Duplicate-column error means already migrated.
    for ddl <- [
          "ALTER TABLE sessions ADD COLUMN host TEXT NOT NULL DEFAULT 'local'",
          "ALTER TABLE sessions ADD COLUMN clearedThroughSeq INTEGER NOT NULL DEFAULT 0",
          "ALTER TABLE sessions ADD COLUMN overrides TEXT",
          "ALTER TABLE sessions ADD COLUMN identityName TEXT",
          "ALTER TABLE sessions ADD COLUMN cliToken TEXT",
          "ALTER TABLE sessions ADD COLUMN adjudicationHold TEXT"
        ] do
      case DB.query(db, ddl) do
        {:ok, _} -> :ok
        {:error, e} -> if inspect(e) =~ "duplicate column", do: :ok, else: raise(e)
      end
    end

    {:ok, _} =
      DB.query(db, "CREATE UNIQUE INDEX IF NOT EXISTS sessions_cli_token ON sessions(cliToken)")

    {:ok, _} =
      DB.query(db, "UPDATE sessions SET identityName = archetype WHERE identityName IS NULL")

    result
  end

  @doc """
  Create a session. Required: `:display_name`, `:owner_user_id`, `:origin`,
  `:archetype`, `:harness`, `:provider`, `:model`. `:session_key` defaults to
  a fresh custom key. Raises on duplicate key/handle (UNIQUE) — spawn
  idempotency lives in the dispatch layer, not here.
  """
  @spec create(db(), map()) :: session()
  def create(db \\ Tightbeam.DB, input) do
    transaction!(db, fn txn -> create_in_txn(txn, input) end)
  end

  @doc false
  @spec create_in_txn(Txn.t(), map()) :: session()
  def create_in_txn(%Txn{} = txn, input) do
    session_key =
      Map.get(input, :session_key) || custom_session_key(Map.fetch!(input, :owner_user_id))

    now = now()
    cli_token = session_token()

    Txn.q(
      txn,
      """
        INSERT INTO sessions (sessionKey, displayName, kind, orderIndex, isBuiltIn, adopted,
          ownerUserId, origin, spawnedBy, handle, archetype, overrides, identityName, cliToken,
          harness, provider, model, thinkingLevel, host, state, createdAt, updatedAt)
        VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14,
          ?15, ?16, ?17, ?18, ?19, 'active', ?20, ?20)
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
        encode_overrides(Map.get(input, :overrides)),
        Map.get(input, :identity_name, Map.fetch!(input, :archetype)),
        cli_token,
        Map.fetch!(input, :harness),
        Map.fetch!(input, :provider),
        Map.fetch!(input, :model),
        Map.get(input, :thinking_level),
        Map.fetch!(input, :host),
        now
      ]
    )

    must_get(txn, session_key)
  end

  @doc "Fetch an active session by its CLI token, or nil."
  @spec by_cli_token(db(), String.t()) :: session() | nil
  def by_cli_token(db \\ Tightbeam.DB, token) do
    {:ok, rows} =
      DB.query(db, select_session_sql() <> " WHERE cliToken = ?1 AND state = 'active'", [token])

    case rows do
      [row] -> to_session(row)
      [] -> nil
    end
  end

  @doc "Fetch a session by key, or nil."
  @spec get(db(), String.t()) :: session() | nil
  def get(db \\ Tightbeam.DB, session_key) do
    {:ok, rows} = DB.query(db, select_session_sql() <> " WHERE sessionKey = ?1", [session_key])

    case rows do
      [row] -> to_session(row)
      [] -> nil
    end
  end

  @doc """
  Sessions for a user. `is_admin: true` returns ALL active sessions — a
  management capability. WIRE CALLERS MUST PASS `false`: chat catalogs,
  replay, and broadcast are owner-only for everyone, admin included (spec
  §Multi-user: admin is powers, not a merged feed).
  """
  @spec list_for_user(db(), String.t(), boolean()) :: [session()]
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

  @doc "Every session, including retired rows, in deterministic creation order."
  @spec list_all(db()) :: [session()]
  def list_all(db \\ Tightbeam.DB) do
    {:ok, rows} = DB.query(db, select_session_sql() <> " ORDER BY createdAt, sessionKey")
    Enum.map(rows, &to_session/1)
  end

  @doc "An active session carrying an effective identity name, or nil."
  @spec active_by_identity_name(db(), String.t()) :: session() | nil
  def active_by_identity_name(db \\ Tightbeam.DB, identity_name) do
    case active_all_by_identity_name(db, identity_name) do
      [session | _] -> session
      [] -> nil
    end
  end

  @doc "All active sessions carrying an effective identity name."
  @spec active_all_by_identity_name(db(), String.t()) :: [session()]
  def active_all_by_identity_name(db \\ Tightbeam.DB, identity_name) do
    {:ok, rows} =
      DB.query(
        db,
        select_session_sql() <>
          " WHERE identityName = ?1 AND state = 'active' ORDER BY createdAt, sessionKey",
        [identity_name]
      )

    Enum.map(rows, &to_session/1)
  end

  @doc "Every session carrying an identity name, including retired rows."
  @spec all_by_identity_name(db(), String.t()) :: [session()]
  def all_by_identity_name(db \\ Tightbeam.DB, identity_name) do
    {:ok, rows} =
      DB.query(
        db,
        select_session_sql() <> " WHERE identityName = ?1 ORDER BY createdAt, sessionKey",
        [identity_name]
      )

    Enum.map(rows, &to_session/1)
  end

  @doc "Whether any session row still references an effective identity name."
  @spec identity_name_exists?(db(), String.t()) :: boolean()
  def identity_name_exists?(db \\ Tightbeam.DB, identity_name) do
    {:ok, [[count]]} =
      DB.query(db, "SELECT COUNT(*) FROM sessions WHERE identityName = ?1", [identity_name])

    count > 0
  end

  @doc "Rename a session (raises if unknown). Returns the updated session."
  @spec rename(db(), String.t(), String.t()) :: session()
  def rename(db \\ Tightbeam.DB, session_key, display_name) do
    update(db, session_key, "displayName = ?2", [display_name])
  end

  @doc """
  Retune a session's engine wholesale — harness+provider+model (the `tune`
  set_harness write). Same identity, different engine: the next turn's
  adapter checkout targets the new harness; the old harness session can't
  load there, so the existing fallback pointer path starts a fresh model
  context. Chat history is substrate-side and unaffected. Returns the
  updated session.
  """
  @spec set_harness(db(), String.t(), String.t(), String.t(), String.t()) :: session()
  def set_harness(db \\ Tightbeam.DB, session_key, harness, provider, model) do
    transaction!(db, fn txn ->
      current = must_get(txn, session_key)

      case swap_model_in_txn(
             txn,
             session_key,
             {current.model, current.harness},
             {model, harness, provider}
           ) do
        {:ok, session} -> session
        {:duplicate, session} -> session
        :stale -> raise "model mutation race"
      end
    end)
  end

  @doc "Retune a session's model+provider (the `tune` verb's write). Returns the updated session."
  @spec set_model(db(), String.t(), String.t(), String.t()) :: session()
  def set_model(db \\ Tightbeam.DB, session_key, model, provider) do
    transaction!(db, fn txn ->
      current = must_get(txn, session_key)

      case swap_model_in_txn(
             txn,
             session_key,
             {current.model, current.harness},
             {model, current.harness, provider}
           ) do
        {:ok, session} -> session
        {:duplicate, session} -> session
        :stale -> raise "model mutation race"
      end
    end)
  end

  @doc "Serialized expected-version mutation seam for every model/harness change."
  @spec swap_model_in_txn(
          Txn.t(),
          String.t(),
          {String.t(), String.t()},
          {String.t(), String.t(), String.t()}
        ) :: {:ok, session()} | {:duplicate, session()} | :stale
  def swap_model_in_txn(
        %Txn{} = txn,
        session_key,
        {expected_model, expected_harness},
        {model, harness, provider}
      ) do
    current = must_get(txn, session_key)

    if current.model == model and current.harness == harness do
      {:duplicate, current}
    else
      Txn.q(
        txn,
        """
        UPDATE sessions SET model=?4, harness=?5, provider=?6, updatedAt=?7
        WHERE sessionKey=?1 AND model=?2 AND harness=?3
        """,
        [session_key, expected_model, expected_harness, model, harness, provider, now()]
      )

      if Txn.changes(txn) == 1, do: {:ok, must_get(txn, session_key)}, else: :stale
    end
  end

  @doc """
  Re-home a session (the move half of `tune`). Records the new host only —
  the next turn's adapter checkout uses it; the old harness session's
  load-failure falls back to a fresh session by existing pointer machinery.
  Constitutional validation (host ∈ archetype.where) happens in Placement
  BEFORE this write; this is the dumb recorder. Returns the updated session.
  """
  @spec set_host(db(), String.t(), String.t()) :: session()
  def set_host(db \\ Tightbeam.DB, session_key, host) do
    update(db, session_key, "host = ?2", [host])
  end

  @doc "Replace the normalized overrides and their derived identity name together."
  @spec set_identity(db(), String.t(), map() | nil, String.t()) :: session()
  def set_identity(db \\ Tightbeam.DB, session_key, overrides, identity_name) do
    update(db, session_key, "overrides = ?2, identityName = ?3", [
      encode_overrides(overrides),
      identity_name
    ])
  end

  @doc """
  Record the history barrier: replay serves only messages with seq > this.
  Rows are never deleted — the chat's past remains in the store (and in any
  export) but stops being presented. Set on harness switches (fresh engine,
  fresh visible slate) or any future explicit clear.
  """
  @spec set_cleared_through(db(), String.t(), integer()) :: session()
  def set_cleared_through(db \\ Tightbeam.DB, session_key, seq) do
    update(db, session_key, "clearedThroughSeq = ?2", [seq])
  end

  @doc """
  Retire a session — soft state flip, never a delete: history, provenance, and
  the pointer chain remain queryable. Returns the updated session.
  """
  @spec retire(db(), String.t()) :: session()
  def retire(db \\ Tightbeam.DB, session_key) do
    update(db, session_key, "state = 'retired'", [])
  end

  @doc false
  @spec retire_in_txn(Txn.t(), String.t()) :: session()
  def retire_in_txn(%Txn{} = txn, session_key) do
    must_get(txn, session_key)

    Txn.q(txn, "UPDATE sessions SET state = 'retired', updatedAt = ?2 WHERE sessionKey = ?1", [
      session_key,
      now()
    ])

    must_get(txn, session_key)
  end

  @doc """
  Append a harness-session pointer (`reason`: created | loaded | fallback).
  The chain is append-only — repointing never erases where the session used to
  live. Raises if the session is unknown.
  """
  @spec append_pointer(db(), String.t(), String.t(), String.t()) :: pointer()
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

  @doc "The newest pointer for a session (where it currently lives), or nil."
  @spec current_pointer(db(), String.t()) :: pointer() | nil
  def current_pointer(db \\ Tightbeam.DB, session_key) do
    case Enum.reverse(pointer_chain(db, session_key)) do
      [pointer | _] -> pointer
      [] -> nil
    end
  end

  @doc "The full pointer chain, oldest first — the session's harness-residence history."
  @spec pointer_chain(db(), String.t()) :: [pointer()]
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

  @doc """
  The canonical personal-session key for a user (Clawline wire format).

      iex> Tightbeam.Org.personal_session_key("flynn")
      "agent:main:clawline:flynn:main"
  """
  @spec personal_session_key(String.t()) :: String.t()
  def personal_session_key(user_id), do: "agent:main:clawline:#{user_id}:main"

  @doc "A fresh custom-session key for a user (personal key + random suffix)."
  @spec custom_session_key(String.t()) :: String.t()
  def custom_session_key(user_id) do
    "agent:main:clawline:#{user_id}:main s_#{String.slice(Tightbeam.Id.uuid4(), 0, 8)}"
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
           ownerUserId, origin, spawnedBy, handle, archetype, overrides, identityName, cliToken, harness, provider,
           model, thinkingLevel, host, clearedThroughSeq, adjudicationHold, state, createdAt, updatedAt
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
         overrides,
         identity_name,
         cli_token,
         harness,
         provider,
         model,
         thinking_level,
         host,
         cleared_through_seq,
         adjudication_hold,
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
      overrides: decode_overrides(overrides),
      identity_name: identity_name || archetype,
      cli_token: cli_token,
      harness: harness,
      provider: provider,
      model: model,
      thinking_level: thinking_level,
      host: host,
      cleared_through_seq: cleared_through_seq,
      adjudication_hold: adjudication_hold,
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

  defp session_token do
    "tbs_" <> Base.url_encode64(:crypto.strong_rand_bytes(24), padding: false)
  end

  defp encode_overrides(nil), do: nil
  defp encode_overrides(overrides), do: JSON.encode!(overrides)

  defp decode_overrides(nil), do: nil
  defp decode_overrides(overrides), do: JSON.decode!(overrides)
end
