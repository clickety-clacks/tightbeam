defmodule Tightbeam.Org do
  @moduledoc """
  Session registry for wire identity, organization identity, model provenance,
  and append-only harness-session pointer chains.
  """

  alias Tightbeam.{DB, Supervision, Wakes}
  alias Tightbeam.DB.Txn
  alias Tightbeam.Model

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
          identity_revision: String.t() | nil,
          cli_token: String.t() | nil,
          harness: String.t(),
          provider: String.t(),
          model: Model.t() | nil,
          host: String.t(),
          cleared_through_seq: integer(),
          state: String.t(),
          created_at: integer(),
          updated_at: integer()
        }

  @typedoc "One link in a session's append-only harness-session pointer chain."
  @type pointer :: %{
          session_key: String.t(),
          harness_session_id: String.t(),
          source_session_ref: String.t(),
          harness: String.t(),
          machine: String.t(),
          reason: String.t(),
          created_at: integer()
        }

  @provider_values "'anthropic','openai','opencode_go'" <>
                     if(Application.compile_env(:tightbeam, :fixture_harness, false),
                       do: ",'fixture_provider'",
                       else: ""
                     )

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
    identityRevision TEXT,
    cliToken      TEXT,
    harness       TEXT NOT NULL CHECK (harness IN (__TIGHTBEAM_HARNESSES__)),
    provider      TEXT NOT NULL CHECK (provider IN (__TIGHTBEAM_PROVIDERS__)),
    model         TEXT NOT NULL,
    thinkingLevel TEXT,
    modelContext  TEXT,
    host          TEXT NOT NULL DEFAULT 'local',
    clearedThroughSeq INTEGER NOT NULL DEFAULT 0,
    state         TEXT NOT NULL DEFAULT 'active' CHECK (state IN ('active','retired')),
    createdAt     INTEGER NOT NULL,
    updatedAt     INTEGER NOT NULL
  );
  CREATE INDEX IF NOT EXISTS sessions_owner ON sessions (ownerUserId, state);
  CREATE TABLE IF NOT EXISTS harness_pointers (
    id               INTEGER PRIMARY KEY AUTOINCREMENT,
    sessionKey       TEXT NOT NULL REFERENCES sessions(sessionKey),
    harnessSessionId TEXT NOT NULL,
    sourceSessionRef TEXT NOT NULL,
    harness          TEXT NOT NULL,
    machine          TEXT NOT NULL,
    reason           TEXT NOT NULL CHECK (reason IN ('created','loaded','fallback')),
    createdAt        INTEGER NOT NULL
  );
  CREATE INDEX IF NOT EXISTS pointers_session ON harness_pointers (sessionKey, id);
  CREATE TABLE IF NOT EXISTS org_settings (
    key       TEXT PRIMARY KEY,
    value     TEXT NOT NULL,
    updatedAt INTEGER NOT NULL
  );
  """

  @spec ensure_schema(db()) :: :ok | {:error, term()}
  def ensure_schema(db \\ Tightbeam.DB) do
    harnesses = Enum.map_join(Tightbeam.Harness.all(), ",", &"'#{&1.wire_name()}'")

    ddl =
      @ddl
      |> String.replace("__TIGHTBEAM_HARNESSES__", harnesses)
      |> String.replace("__TIGHTBEAM_PROVIDERS__", @provider_values)

    result = DB.execute(db, ddl)

    {:ok, _} =
      DB.query(db, "CREATE UNIQUE INDEX IF NOT EXISTS sessions_cli_token ON sessions(cliToken)")

    :ok =
      DB.execute(
        db,
        """
        CREATE INDEX IF NOT EXISTS pointers_source ON harness_pointers (sourceSessionRef, id);
        CREATE TRIGGER IF NOT EXISTS harness_pointer_reverse_unique
        BEFORE INSERT ON harness_pointers
        WHEN EXISTS (
          SELECT 1 FROM harness_pointers
          WHERE sourceSessionRef = NEW.sourceSessionRef
            AND sessionKey != NEW.sessionKey
        )
        BEGIN
          SELECT RAISE(ABORT, 'harness source session already belongs to another parent');
        END;
        """
      )

    result
  end

  @doc "Read an organization setting, or nil when it is unset."
  @spec get_setting(db(), String.t()) :: String.t() | nil
  def get_setting(db \\ Tightbeam.DB, key) do
    {:ok, rows} = DB.query(db, "SELECT value FROM org_settings WHERE key = ?1", [key])

    case rows do
      [[value]] -> value
      [] -> nil
    end
  end

  @doc "Write an organization setting."
  @spec put_setting(db(), String.t(), String.t()) :: :ok
  def put_setting(db \\ Tightbeam.DB, key, value) do
    transaction!(db, fn txn -> put_setting_in_txn(txn, key, value) end)
  end

  @doc false
  @spec put_setting_in_txn(Txn.t(), String.t(), String.t()) :: :ok
  def put_setting_in_txn(%Txn{} = txn, key, value) do
    Txn.q(
      txn,
      """
      INSERT INTO org_settings (key, value, updatedAt) VALUES (?1, ?2, ?3)
      ON CONFLICT(key) DO UPDATE SET value = excluded.value, updatedAt = excluded.updatedAt
      """,
      [key, value, now()]
    )

    :ok
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
    %Model{} = model = Map.fetch!(input, :model)

    Txn.q(
      txn,
      """
        INSERT INTO sessions (sessionKey, displayName, kind, orderIndex, isBuiltIn, adopted,
          ownerUserId, origin, spawnedBy, handle, archetype, overrides, identityName,
          identityRevision, cliToken,
          harness, provider, model, thinkingLevel, modelContext, host, state, createdAt, updatedAt)
        VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14,
          ?15, ?16, ?17, ?18, ?19, ?20, ?21, 'active', ?22, ?22)
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
        Map.get(input, :identity_revision),
        cli_token,
        Map.fetch!(input, :harness),
        Map.fetch!(input, :provider),
        model.family,
        model.effort,
        model.context,
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
  Set a session's adoption — the client-side view-membership flag (the `tune`
  adopt write). Agent- and substrate-started sessions exist and are addressable
  whether or not they are adopted; adoption only decides whether the chat client
  lists the session by default. Returns the updated session.
  """
  @spec set_adopted(db(), String.t(), boolean()) :: session()
  def set_adopted(db \\ Tightbeam.DB, session_key, adopted) do
    update(db, session_key, "adopted = ?2", [if(adopted, do: 1, else: 0)])
  end

  @doc """
  Retune a session's engine wholesale — harness+provider+model (the `tune`
  set_harness write). Same identity, different engine: the next turn's
  adapter checkout targets the new harness; the old harness session can't
  load there, so the existing fallback pointer path starts a fresh model
  context. Chat history is substrate-side and unaffected. Returns the
  updated session.
  """
  @spec set_harness(db(), String.t(), String.t(), String.t(), Model.t()) :: session()
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
  @spec set_model(db(), String.t(), Model.t(), String.t()) :: session()
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
          {Model.t() | nil, String.t()},
          {Model.t(), String.t(), String.t()}
        ) :: {:ok, session()} | {:duplicate, session()} | :stale
  def swap_model_in_txn(
        %Txn{} = txn,
        session_key,
        {expected_model, expected_harness},
        {%Model{} = model, harness, provider}
      ) do
    current = must_get(txn, session_key)

    if current.model == model and current.harness == harness do
      {:duplicate, current}
    else
      expected = expected_model || %Model{family: nil}

      Txn.q(
        txn,
        """
        UPDATE sessions SET model=?4, thinkingLevel=?8, modelContext=?9, harness=?5,
          provider=?6, updatedAt=?7
        WHERE sessionKey=?1 AND model IS ?2 AND thinkingLevel IS ?10
          AND modelContext IS ?11 AND harness=?3
        """,
        [
          session_key,
          expected.family,
          expected_harness,
          model.family,
          harness,
          provider,
          now(),
          model.effort,
          model.context,
          expected.effort,
          expected.context
        ]
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

  @doc "Transaction-owned host recorder for workspace-motion compositions."
  @spec set_host_in_txn(Txn.t(), String.t(), String.t()) :: session()
  def set_host_in_txn(%Txn{} = txn, session_key, host) do
    Txn.q(
      txn,
      "UPDATE sessions SET host = ?2, updatedAt = ?3 WHERE sessionKey = ?1",
      [session_key, host, now()]
    )

    must_get(txn, session_key)
  end

  @doc "Replace the normalized overrides and their derived identity name together."
  @spec set_identity(db(), String.t(), map() | nil, String.t()) :: session()
  def set_identity(db \\ Tightbeam.DB, session_key, overrides, identity_name) do
    update(db, session_key, "overrides = ?2, identityName = ?3", [
      encode_overrides(overrides),
      identity_name
    ])
  end

  @doc "Stamp the single immutable identity revision provisioned into a session."
  @spec set_identity_revision(db(), String.t(), String.t()) :: session()
  def set_identity_revision(db \\ Tightbeam.DB, session_key, revision) do
    update(db, session_key, "identityRevision = ?2", [revision])
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

  @doc false
  @spec set_cleared_through_in_txn(Txn.t(), String.t(), integer()) :: session()
  def set_cleared_through_in_txn(%Txn{} = txn, session_key, seq) do
    must_get(txn, session_key)

    Txn.q(
      txn,
      "UPDATE sessions SET clearedThroughSeq = ?2, updatedAt = ?3 WHERE sessionKey = ?1",
      [session_key, seq, now()]
    )

    must_get(txn, session_key)
  end

  @doc """
  Retire a session — soft state flip, never a delete: history, provenance, and
  the pointer chain remain queryable. Returns the updated session.
  """
  @spec retire(db(), String.t(), String.t(), pos_integer()) :: session()
  def retire(db \\ Tightbeam.DB, session_key, principal, supervision_interval_ms) do
    transaction!(db, fn txn ->
      retire_in_txn(txn, session_key, principal, supervision_interval_ms)
    end)
  end

  @doc false
  @spec retire_in_txn(Txn.t(), String.t(), String.t(), pos_integer()) :: session()
  def retire_in_txn(%Txn{} = txn, session_key, principal, supervision_interval_ms)
      when is_binary(principal) and principal != "" and is_integer(supervision_interval_ms) and
             supervision_interval_ms > 0 do
    case must_get(txn, session_key) do
      %{state: "retired"} = session ->
        session

      %{state: "active"} ->
        retire_active_in_txn(
          txn,
          session_key,
          principal,
          supervision_interval_ms
        )
    end
  end

  def retire_in_txn(%Txn{}, _session_key, _principal, _supervision_interval_ms) do
    raise ArgumentError,
          "retirement requires a non-empty principal and positive supervision interval"
  end

  defp retire_active_in_txn(txn, session_key, principal, supervision_interval_ms) do
    retirement_epoch = now()

    case Supervision.transition_in_txn(txn, %{
           kind: "parent_target_retired",
           session_key: session_key,
           retirement_epoch: retirement_epoch,
           principal: principal,
           supervision_interval_ms: supervision_interval_ms
         }) do
      outcome when outcome in [:armed, :parent_elevated, :duplicate] -> :ok
      {:error, reason} -> raise "parent-target retirement refused: #{inspect(reason)}"
      other -> raise "invalid parent-target retirement result: #{inspect(other)}"
    end

    Txn.q(
      txn,
      "UPDATE sessions SET state = 'retired', updatedAt = ?2 WHERE sessionKey = ?1 AND state = 'active'",
      [session_key, retirement_epoch]
    )

    if Txn.changes(txn) != 1, do: raise("retirement state changed before commit")

    cancel_retirement_wakes_in_txn(txn, session_key)

    must_get(txn, session_key)
  end

  defp cancel_retirement_wakes_in_txn(txn, session_key) do
    Txn.q(
      txn,
      """
      SELECT w.wakeId, w.sessionKey, w.targetRole, w.reresolve, w.reresolveSeed,
             w.reresolveRung, w.work_item_id, w.assignmentId
      FROM wakes w
      LEFT JOIN roles r ON r.name=w.targetRole
      WHERE w.state='pending' AND w.targetGate=1
        AND (w.sessionKey=?1 OR r.boundSessionKey=?1)
      ORDER BY w.createdAt, w.wakeId
      """,
      [session_key]
    )
    |> Enum.each(fn row -> cancel_retirement_wake_in_txn!(txn, session_key, row) end)

    :ok
  end

  defp cancel_retirement_wake_in_txn!(
         txn,
         session_key,
         [
           wake_id,
           _recorded_session_key,
           target_role,
           reresolve,
           reresolve_seed,
           reresolve_rung,
           work_item_id,
           assignment_id
         ]
       ) do
    command =
      if retirement_assignment_disposition?(txn, assignment_id, session_key) do
        assignment_disposition_command(
          txn,
          assignment_id,
          work_item_id
        )
      else
        target_retirement_command(
          txn,
          session_key,
          wake_id,
          target_role,
          reresolve,
          reresolve_seed,
          reresolve_rung,
          work_item_id,
          assignment_id
        )
      end

    if not Wakes.cancel_in_txn(txn, Map.put(command, :wake_id, wake_id)) do
      raise "typed retirement cancellation refused for #{wake_id}"
    end
  end

  defp retirement_assignment_disposition?(_txn, nil, _session_key), do: false

  defp retirement_assignment_disposition?(txn, assignment_id, session_key) do
    Txn.q(
      txn,
      """
      SELECT 1
      FROM assignments a
      JOIN assignment_interruptions i ON i.assignmentId=a.id
      WHERE a.id=?1 AND a.state='closed' AND a.outcome='revoked'
        AND i.sessionKey=?2 AND i.reason='interrupted-by-retire'
      """,
      [assignment_id, session_key]
    ) == [[1]]
  end

  defp assignment_disposition_command(txn, assignment_id, direct_work_item_id) do
    outcome = %{
      kind: "disposition",
      disposition_kind: "assignment_transition",
      disposition_id: assignment_id
    }

    %{
      requester: %{kind: "process", id: "tightbeam:retirement"},
      reason_kind: "obligation_disposed",
      causal_source: %{kind: "assignment_transition", id: assignment_id},
      outcome:
        put_liveness_trigger(
          outcome,
          liveness_trigger_in_txn!(txn, direct_work_item_id, assignment_id)
        )
    }
  end

  defp target_retirement_command(
         txn,
         session_key,
         wake_id,
         target_role,
         reresolve,
         reresolve_seed,
         reresolve_rung,
         work_item_id,
         assignment_id
       ) do
    outcome =
      case retirement_replacement_target(
             txn,
             target_role,
             reresolve,
             reresolve_seed,
             reresolve_rung
           ) do
        nil ->
          put_liveness_trigger(
            %{kind: "no_replacement"},
            liveness_trigger_in_txn!(txn, work_item_id, assignment_id)
          )

        replacement_target ->
          case Wakes.retarget_in_txn(txn, wake_id, replacement_target) do
            %{wake_id: replacement_wake_id} ->
              %{kind: "replacement", replacement_wake_id: replacement_wake_id}

            :error ->
              raise "retirement replacement refused for #{wake_id}"
          end
      end

    %{
      requester: %{kind: "process", id: "tightbeam:retirement"},
      reason_kind: "target_retired",
      causal_source: %{kind: "session_transition", id: session_key},
      outcome: outcome
    }
  end

  defp retirement_replacement_target(txn, target_role, _reresolve, _seed, _rung)
       when is_binary(target_role) do
    case Txn.q(
           txn,
           "SELECT boundSessionKey, ownerUserId FROM roles WHERE name=?1",
           [target_role]
         ) do
      [[bound_session_key, owner_user_id]] ->
        active_session_or_main(txn, bound_session_key, owner_user_id)

      [] ->
        nil
    end
  end

  defp retirement_replacement_target(txn, _role, "lineage", seed, rung)
       when is_binary(seed) and is_integer(rung) and rung > 0 do
    Supervision.ladder_target(txn, seed, rung)
  end

  defp retirement_replacement_target(_txn, _role, _reresolve, _seed, _rung), do: nil

  defp active_session_or_main(txn, bound_session_key, owner_user_id) do
    cond do
      active_session?(txn, bound_session_key) ->
        bound_session_key

      active_session?(txn, personal_session_key(owner_user_id)) ->
        personal_session_key(owner_user_id)

      true ->
        nil
    end
  end

  defp active_session?(_txn, nil), do: false

  defp active_session?(txn, session_key) do
    Txn.q(txn, "SELECT 1 FROM sessions WHERE sessionKey=?1 AND state='active'", [session_key]) ==
      [
        [1]
      ]
  end

  defp liveness_trigger_in_txn!(txn, direct_work_item_id, assignment_id) do
    case primary_liveness_ref(txn, direct_work_item_id, assignment_id) do
      nil ->
        nil

      primary ->
        case Supervision.liveness_trigger_in_txn(txn, primary) do
          {:ok, trigger} when is_map(trigger) -> trigger
          :none -> raise "#{inspect(primary)} has no liveness trigger"
          {:error, reason} -> raise "invalid liveness trigger: #{inspect(reason)}"
        end
    end
  end

  defp primary_liveness_ref(txn, direct_work_item_id, assignment_id)
       when is_binary(assignment_id) do
    case Txn.q(txn, "SELECT state, workItemId FROM assignments WHERE id=?1", [assignment_id]) do
      [["open", _work_item_id]] ->
        {:assignment, assignment_id}

      [[_state, assignment_work_item_id]] ->
        open_work_item_ref(txn, assignment_work_item_id || direct_work_item_id)

      [] ->
        nil
    end
  end

  defp primary_liveness_ref(txn, direct_work_item_id, nil),
    do: open_work_item_ref(txn, direct_work_item_id)

  defp open_work_item_ref(_txn, nil), do: nil

  defp open_work_item_ref(txn, work_item_id) do
    if Txn.q(txn, "SELECT 1 FROM work_items WHERE id=?1 AND state='open'", [work_item_id]) == [
         [1]
       ],
       do: {:work_item, work_item_id},
       else: nil
  end

  defp put_liveness_trigger(outcome, trigger) when is_map(trigger),
    do: Map.put(outcome, :liveness_trigger, trigger)

  defp put_liveness_trigger(outcome, nil), do: outcome

  @doc "Repoint a retired session to another archetype and its base identity."
  @spec repoint_retired_archetype(db(), String.t(), String.t()) ::
          {:ok, session()} | {:error, :not_found | :not_retired}
  def repoint_retired_archetype(db \\ Tightbeam.DB, session_key, archetype) do
    case transaction!(db, fn txn ->
           repoint_archetype_in_txn(txn, session_key, archetype, false)
         end) do
      {:error, :not_repointable} -> {:error, :not_retired}
      result -> result
    end
  end

  @doc false
  @spec repoint_archetype_in_txn(Txn.t(), String.t(), String.t()) ::
          {:ok, session()} | {:error, :not_found | :not_repointable}
  def repoint_archetype_in_txn(%Txn{} = txn, session_key, archetype) do
    repoint_archetype_in_txn(txn, session_key, archetype, true)
  end

  defp repoint_archetype_in_txn(txn, session_key, archetype, allow_permanent?) do
    case Txn.q(txn, select_session_sql() <> " WHERE sessionKey = ?1", [session_key]) do
      [] ->
        {:error, :not_found}

      [row] ->
        session = to_session(row)

        if session.state == "retired" or
             (allow_permanent? and (session.kind == "main" or session.is_built_in)) do
          Txn.q(
            txn,
            """
            UPDATE sessions
            SET archetype = ?2, overrides = NULL, identityName = ?2,
                identityRevision = NULL, updatedAt = ?3
            WHERE sessionKey = ?1
            """,
            [session_key, archetype, now()]
          )

          {:ok, must_get(txn, session_key)}
        else
          {:error, :not_repointable}
        end
    end
  end

  @doc """
  Serialize release of a set of archetype names with every durable reference.

  Each enumerated reference carries the supported command sequence that clears
  it. The enumeration and its remedies therefore cannot acquire separate case
  lists. `release` runs inside the DB owner's transaction when no references
  remain, fencing every session and setting writer behind the publication.
  """
  @spec release_archetypes(db(), [String.t()], (-> result)) ::
          {:referenced, [map()]} | {:released, result}
        when result: term()
  def release_archetypes(db \\ Tightbeam.DB, archetypes, release) when is_function(release, 0) do
    transaction!(db, fn txn ->
      case archetype_references_in_txn(txn, archetypes) do
        [] -> {:released, release.()}
        references -> {:referenced, references}
      end
    end)
  end

  defp archetype_references_in_txn(txn, archetypes) do
    placeholders = Enum.map_join(archetypes, ",", fn _ -> "?" end)

    sessions =
      if archetypes == [] do
        []
      else
        txn
        |> Txn.q(
          select_session_sql() <>
            " WHERE archetype IN (#{placeholders}) ORDER BY createdAt, sessionKey",
          archetypes
        )
        |> Enum.map(&session_archetype_reference/1)
      end

    setting =
      case Txn.q(txn, "SELECT value FROM org_settings WHERE key = 'default-archetype'") do
        [[archetype]] ->
          if archetype in archetypes do
            [
              %{
                kind: "setting",
                setting: "default-archetype",
                archetype: archetype,
                clear_commands: [
                  %{
                    verb: "config",
                    params: %{action: "set", setting: "default-archetype", value: "default"}
                  }
                ]
              }
            ]
          else
            []
          end

        _ ->
          []
      end

    sessions ++ setting
  end

  defp session_archetype_reference(row) do
    session = to_session(row)

    repoint = %{
      verb: "identity-repoint",
      session_key: session.session_key,
      params: %{archetype: "default"}
    }

    clear_commands =
      if session.state == "active" and session.kind != "main" and not session.is_built_in do
        [%{verb: "retire", session_key: session.session_key, params: %{}}, repoint]
      else
        [repoint]
      end

    %{
      kind: "session",
      session_key: session.session_key,
      state: session.state,
      archetype: session.archetype,
      clear_commands: clear_commands
    }
  end

  @doc """
  Append a harness-session pointer (`reason`: created | loaded | fallback).
  The chain is append-only — repointing never erases where the session used to
  live. Raises if the session is unknown.
  """
  @spec append_pointer(db(), String.t(), String.t(), String.t()) :: pointer()
  def append_pointer(db \\ Tightbeam.DB, session_key, harness_session_id, reason) do
    transaction!(db, fn txn ->
      append_pointer_in_txn(txn, session_key, harness_session_id, reason)
    end)
  end

  @doc false
  @spec append_pointer_in_txn(Txn.t(), String.t(), String.t(), String.t()) :: pointer()
  def append_pointer_in_txn(txn, session_key, harness_session_id, reason) do
    session = must_get(txn, session_key)
    created_at = now()

    source_session_ref =
      source_session_ref(session.harness, session.host, harness_session_id)

    Txn.q(
      txn,
      """
        INSERT INTO harness_pointers
          (sessionKey, harnessSessionId, sourceSessionRef, harness, machine, reason, createdAt)
        VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)
      """,
      [
        session_key,
        harness_session_id,
        source_session_ref,
        session.harness,
        session.host,
        reason,
        created_at
      ]
    )

    %{
      session_key: session_key,
      harness_session_id: harness_session_id,
      source_session_ref: source_session_ref,
      harness: session.harness,
      machine: session.host,
      reason: reason,
      created_at: created_at
    }
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
          SELECT sessionKey, harnessSessionId, sourceSessionRef, harness, machine, reason, createdAt
          FROM harness_pointers WHERE sessionKey = ?1 ORDER BY id ASC
        """,
        [session_key]
      )

    Enum.map(rows, fn [
                        key,
                        harness_session_id,
                        source_session_ref,
                        harness,
                        machine,
                        reason,
                        created_at
                      ] ->
      %{
        session_key: key,
        harness_session_id: harness_session_id,
        source_session_ref: source_session_ref,
        harness: harness,
        machine: machine,
        reason: reason,
        created_at: created_at
      }
    end)
  end

  @doc "Canonical adapter-source reference for one harness session."
  @spec source_session_ref(atom() | String.t(), String.t(), String.t()) :: String.t()
  def source_session_ref(harness, machine, harness_session_id) do
    encoded =
      [to_string(harness), machine, harness_session_id]
      |> JSON.encode!()
      |> Base.url_encode64(padding: false)

    "acp:" <> encoded
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
           ownerUserId, origin, spawnedBy, handle, archetype, overrides, identityName,
           identityRevision, cliToken, harness, provider,
           model, thinkingLevel, modelContext, host, clearedThroughSeq, state, createdAt, updatedAt
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
         identity_revision,
         cli_token,
         harness,
         provider,
         model,
         thinking_level,
         model_context,
         host,
         cleared_through_seq,
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
      identity_revision: identity_revision,
      cli_token: cli_token,
      harness: harness,
      provider: provider,
      model: model && %Model{family: model, effort: thinking_level, context: model_context},
      host: host,
      cleared_through_seq: cleared_through_seq,
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
