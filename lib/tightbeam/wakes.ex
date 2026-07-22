defmodule Tightbeam.Wakes do
  @moduledoc """
  Persistent wake store + scheduler (TS reference: src/core/wakes.ts — its
  test file is the acceptance oracle). A wake is a fact-shaped, durable
  "deliver this prompt to this session at dueAt" row; delivery goes through
  the SAME turn pipeline as a user post (T8: coordination is fact-shaped).

  Process shape: ONE GenServer (`Tightbeam.WakeScheduler` in the tree) owning
  a tick timer. Every tick (and on explicit `fire_due/1`) it reads due
  pending wakes. Legacy timed wakes DELIVER and then mark fired — wakes.ts
  order, load-bearing:
  - deliver raises → wake stays pending, retried next tick (at-least-once;
    a poison wake retries visibly rather than vanishing).
  - crash between deliver and mark → redelivered after restart, deduped by
    the turns table's `wakeId` UNIQUE (enqueue is exactly-once).
  Marking fired BEFORE delivering would silently lose the wake on a crash in
  between — never reorder this legacy path. Condition/fallback wakes instead
  use a single CAS-gated transaction that atomically marks and enqueues.

  States: pending → fired | canceled. Cancel requires the CALLER's origin to
  match the wake's origin (you cancel your own wakes only).
  """

  use GenServer
  alias Tightbeam.{DB, EventLog, Gateway}
  alias Tightbeam.DB.Txn

  @type db :: GenServer.server()

  @type wake :: %{
          wake_id: String.t(),
          session_key: String.t(),
          target_role: String.t() | nil,
          origin: String.t(),
          prompt: String.t(),
          due_at: integer(),
          state: String.t(),
          created_at: integer(),
          fired_at: integer() | nil,
          condition_kind: String.t() | nil,
          condition_scope: String.t() | nil,
          condition_after_id: integer() | nil,
          fired_by: String.t() | nil,
          creator_session_key: String.t() | nil,
          reresolve: String.t() | nil,
          reresolve_seed: String.t() | nil,
          reresolve_rung: integer() | nil
        }

  @typedoc "Delivery fun injected by the composition root: fires the prompt into the turn pipeline."
  @type deliver :: (wake() -> any())

  @ddl """
  CREATE TABLE IF NOT EXISTS wakes (
    wakeId     TEXT PRIMARY KEY,
    sessionKey TEXT NOT NULL,
    targetRole TEXT,
    origin     TEXT NOT NULL,
    prompt     TEXT NOT NULL,
    dueAt      INTEGER NOT NULL,
    state      TEXT NOT NULL DEFAULT 'pending' CHECK (state IN ('pending','fired','canceled')),
    createdAt  INTEGER NOT NULL,
    firedAt    INTEGER,
    reresolve  TEXT NULL CHECK (reresolve IN ('lineage')),
    reresolveSeed TEXT NULL,
    reresolveRung INTEGER NULL,
    conditionKind TEXT NULL,
    conditionScope TEXT NULL,
    conditionAfterId INTEGER NULL,
    firedBy TEXT NULL CHECK (firedBy IN ('condition','fallback')),
    creatorSessionKey TEXT NULL
  );
  CREATE INDEX IF NOT EXISTS wakes_due ON wakes (state, dueAt);
  CREATE TABLE IF NOT EXISTS scheduler_state (
    id INTEGER PRIMARY KEY CHECK (id = 0),
    afterFact INTEGER NOT NULL DEFAULT 0
  );
  INSERT OR IGNORE INTO scheduler_state (id, afterFact) VALUES (0, 0);
  """

  @spec ensure_schema(db()) :: :ok | {:error, term()}
  def ensure_schema(db \\ Tightbeam.DB) do
    result = DB.execute(db, @ddl)

    for ddl <- [
          "ALTER TABLE wakes ADD COLUMN targetRole TEXT",
          "ALTER TABLE wakes ADD COLUMN reresolve TEXT NULL CHECK (reresolve IN ('lineage'))",
          "ALTER TABLE wakes ADD COLUMN reresolveSeed TEXT NULL",
          "ALTER TABLE wakes ADD COLUMN reresolveRung INTEGER NULL",
          "ALTER TABLE wakes ADD COLUMN conditionKind TEXT NULL",
          "ALTER TABLE wakes ADD COLUMN conditionScope TEXT NULL",
          "ALTER TABLE wakes ADD COLUMN conditionAfterId INTEGER NULL",
          "ALTER TABLE wakes ADD COLUMN firedBy TEXT NULL CHECK (firedBy IN ('condition','fallback'))",
          "ALTER TABLE wakes ADD COLUMN creatorSessionKey TEXT NULL"
        ] do
      case DB.query(db, ddl) do
        {:ok, _} -> :ok
        {:error, e} -> if inspect(e) =~ "duplicate column", do: :ok, else: raise(e)
      end
    end

    :ok =
      DB.execute(
        db,
        "CREATE INDEX IF NOT EXISTS wakes_condition ON wakes (state, conditionKind, conditionScope);"
      )

    result
  end

  ## Store (pure DB ops — callable without the scheduler process, e.g. by inspect)

  @doc "Persist a pending wake (id minted here, prefix `w_`). Returns the row."
  @spec schedule(db(), %{
          session_key: String.t(),
          target_role: String.t() | nil,
          origin: String.t(),
          prompt: String.t(),
          due_at: integer()
        }) :: wake()
  def schedule(db \\ Tightbeam.DB, input) do
    transaction!(db, &schedule_in_txn(&1, input))
  end

  @doc "Persist a pending wake inside an existing DB transaction."
  @spec schedule_in_txn(Txn.t(), map()) :: wake()
  def schedule_in_txn(%Txn{} = txn, input) do
    condition_kind = Map.get(input, :condition_kind)

    condition_after_id =
      if is_binary(condition_kind) do
        [[cursor]] = Txn.q(txn, "SELECT COALESCE(MAX(id), 0) FROM condition_facts")
        cursor
      end

    wake = %{
      wake_id: "w_" <> Tightbeam.Id.uuid4(),
      session_key: Map.fetch!(input, :session_key),
      target_role: Map.get(input, :target_role),
      origin: Map.fetch!(input, :origin),
      prompt: Map.fetch!(input, :prompt),
      due_at: Map.fetch!(input, :due_at),
      state: "pending",
      created_at: now(),
      fired_at: nil,
      condition_kind: condition_kind,
      condition_scope: Map.get(input, :condition_scope),
      condition_after_id: condition_after_id,
      fired_by: nil,
      creator_session_key: Map.get(input, :creator_session_key),
      reresolve: Map.get(input, :reresolve),
      reresolve_seed: Map.get(input, :reresolve_seed),
      reresolve_rung: Map.get(input, :reresolve_rung)
    }

    Txn.q(
      txn,
      """
        INSERT INTO wakes
          (wakeId, sessionKey, targetRole, origin, prompt, dueAt, state, createdAt, firedAt,
           reresolve, reresolveSeed, reresolveRung, conditionKind, conditionScope,
           conditionAfterId, firedBy, creatorSessionKey)
        VALUES (?1, ?2, ?3, ?4, ?5, ?6, 'pending', ?7, NULL, ?8, ?9, ?10,
                ?11, ?12, ?13, NULL, ?14)
      """,
      [
        wake.wake_id,
        wake.session_key,
        wake.target_role,
        wake.origin,
        wake.prompt,
        wake.due_at,
        wake.created_at,
        wake.reresolve,
        wake.reresolve_seed,
        wake.reresolve_rung,
        wake.condition_kind,
        wake.condition_scope,
        wake.condition_after_id,
        wake.creator_session_key
      ]
    )

    if is_binary(condition_kind) do
      EventLog.lifecycle_in_txn(
        txn,
        "wake_condition_scheduled",
        wake.wake_id,
        "kind=#{condition_kind} scope=#{wake.condition_scope || "nil"} fallbackAt=#{wake.due_at} origin=#{wake.origin}"
      )
    end

    wake
  end

  @doc "Cancel a pending wake IF `origin` scheduled it. True if a row transitioned."
  @spec cancel(db(), String.t(), String.t()) :: boolean()
  def cancel(db \\ Tightbeam.DB, wake_id, origin) do
    transaction!(db, fn txn ->
      Txn.q(
        txn,
        """
          UPDATE wakes SET state = 'canceled'
          WHERE wakeId = ?1 AND origin = ?2 AND state = 'pending'
        """,
        [wake_id, origin]
      )

      canceled = Txn.changes(txn) == 1

      if canceled do
        case Txn.q(txn, "SELECT conditionKind FROM wakes WHERE wakeId = ?1", [wake_id]) do
          [[kind]] when is_binary(kind) ->
            EventLog.lifecycle_in_txn(
              txn,
              "wake_condition_canceled",
              wake_id,
              "by=#{origin}"
            )

          _ ->
            :ok
        end
      end

      canceled
    end)
  end

  @spec get(db(), String.t()) :: wake() | nil
  def get(db \\ Tightbeam.DB, wake_id) do
    {:ok, rows} = DB.query(db, select_wake_sql() <> " WHERE wakeId = ?1", [wake_id])

    case rows do
      [row] -> to_wake(row)
      [] -> nil
    end
  end

  @doc "All pending wakes, soonest first (inspect filters to owned sessions)."
  @spec list_pending(db()) :: [wake()]
  def list_pending(db \\ Tightbeam.DB) do
    {:ok, rows} =
      DB.query(db, select_wake_sql() <> " WHERE state = 'pending' ORDER BY dueAt ASC")

    Enum.map(rows, &to_wake/1)
  end

  @doc "Count pending wakes resolved to a session key."
  @spec pending_count(db(), String.t()) :: non_neg_integer()
  def pending_count(db \\ Tightbeam.DB, session_key) do
    {:ok, [[count]]} =
      DB.query(db, "SELECT count(*) FROM wakes WHERE state = 'pending' AND sessionKey = ?1", [
        session_key
      ])

    count
  end

  ## Scheduler process

  @doc """
  Start the scheduler. Opts: `:deliver` (required — see `t:deliver/0`),
  `:db`, `:tick_ms` (default 1000), `:name` (default `Tightbeam.WakeScheduler`
  — the registered name the wake verb handler calls).
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts,
      name: Keyword.get(opts, :name, Tightbeam.WakeScheduler)
    )
  end

  @doc """
  Claim + deliver every due pending wake NOW (synchronous). The wake verb
  calls this after scheduling an immediate DM so delivery never waits a tick.
  """
  @spec fire_due(GenServer.server()) :: :ok
  def fire_due(server \\ Tightbeam.WakeScheduler) do
    GenServer.call(server, :fire_due)
  end

  @doc "Eagerly evaluate condition wakes after a fact commits."
  @spec fire_matching(GenServer.server()) :: :ok
  def fire_matching(server \\ Tightbeam.WakeScheduler) do
    GenServer.call(server, :fire_matching)
  end

  @impl true
  def init(opts) do
    state = %{
      deliver: Keyword.fetch!(opts, :deliver),
      db: Keyword.get(opts, :db, Tightbeam.DB),
      tick_ms: Keyword.get(opts, :tick_ms, 1_000),
      batch: Keyword.get(opts, :batch, 100)
    }

    schedule_tick(state.tick_ms)
    {:ok, state}
  end

  @impl true
  def handle_call(:fire_due, _from, state) do
    deliver_due(state)
    {:reply, :ok, state}
  end

  def handle_call(:fire_matching, _from, state) do
    evaluate_conditions(state, :eager)
    {:reply, :ok, state}
  end

  @impl true
  def handle_info(:tick, state) do
    deliver_due(state)
    schedule_tick(state.tick_ms)
    {:noreply, state}
  end

  def handle_info(:fire_matching, state) do
    evaluate_conditions(state, :tick)
    {:noreply, state}
  end

  # Deliver-then-mark (see moduledoc — never reorder): a raising deliver
  # leaves its wake pending for the next tick; a crash between deliver and
  # mark redelivers, deduped by turns.wakeId.
  defp deliver_due(%{db: db, deliver: deliver} = state) do
    {:ok, rows} =
      DB.query(
        db,
        select_wake_sql() <>
          " WHERE state = 'pending' AND dueAt <= ?1 AND conditionKind IS NULL ORDER BY dueAt ASC",
        [now()]
      )

    for row <- rows do
      wake = to_wake(row)

      delivered =
        try do
          deliver.(wake)
          true
        rescue
          _ -> false
        end

      if delivered do
        transaction!(db, fn txn ->
          Txn.q(
            txn,
            "UPDATE wakes SET state = 'fired', firedAt = ?2 WHERE wakeId = ?1 AND state = 'pending'",
            [wake.wake_id, now()]
          )

          :ok
        end)
      end
    end

    evaluate_conditions(state, :tick)
    :ok
  end

  defp evaluate_conditions(%{db: db, batch: batch}, mode) do
    {rows, watermark} = select_candidates(db, batch, mode)

    rows
    |> Enum.sort_by(fn
      [branch, _wake_id, fact_id, _scope, rid] when branch in ["C1", "C2"] ->
        {0, fact_id, rid}

      [_branch, _wake_id, _fact_id, _scope, rid] ->
        {1, rid, rid}
    end)
    |> Enum.each(fn [_branch, wake_id, _fact_id, _scope, _rid] ->
      fire_candidate(db, wake_id)
    end)

    if mode == :tick do
      advance_watermark(db, rows, batch, watermark)
    end

    if Enum.any?(~w(C1 C2 F), fn branch ->
         Enum.count(rows, &(hd(&1) == branch)) == batch
       end) do
      send(self(), :fire_matching)
    end

    :ok
  end

  defp select_candidates(db, batch, :tick) do
    transaction!(db, fn txn ->
      [[after_fact]] = Txn.q(txn, "SELECT afterFact FROM scheduler_state WHERE id = 0")
      [[ceil]] = Txn.q(txn, "SELECT COALESCE(MAX(id), 0) FROM condition_facts")
      rows = Txn.q(txn, candidate_sql(:tick), [after_fact, ceil, batch, now()])
      {rows, {after_fact, ceil}}
    end)
  end

  defp select_candidates(db, batch, :eager) do
    transaction!(db, fn txn ->
      [[fact_id]] = Txn.q(txn, "SELECT COALESCE(MAX(id), 0) FROM condition_facts")
      {Txn.q(txn, candidate_sql(:eager), [fact_id, batch, now()]), nil}
    end)
  end

  defp candidate_sql(:tick) do
    """
    SELECT * FROM (
      SELECT 'C1' AS branch, w.wakeId AS wakeId, f.id AS matchedFactId,
             f.scope AS matchedScope, w.rowid AS rid
      FROM condition_facts f CROSS JOIN wakes w INDEXED BY wakes_condition
      WHERE f.id > ?1 AND f.id <= ?2
        AND w.state = 'pending' AND w.conditionKind = f.kind
        AND w.conditionScope = f.scope AND f.id > w.conditionAfterId
      ORDER BY f.id ASC, w.rowid ASC LIMIT ?3
    )
    UNION ALL
    SELECT * FROM (
      SELECT 'C2' AS branch, w.wakeId AS wakeId, f.id AS matchedFactId,
             f.scope AS matchedScope, w.rowid AS rid
      FROM condition_facts f CROSS JOIN wakes w INDEXED BY wakes_condition
      WHERE f.id > ?1 AND f.id <= ?2
        AND w.state = 'pending' AND w.conditionKind = f.kind
        AND w.conditionScope IS NULL AND f.id > w.conditionAfterId
      ORDER BY f.id ASC, w.rowid ASC LIMIT ?3
    )
    UNION ALL
    SELECT * FROM (
      SELECT 'F' AS branch, w.wakeId AS wakeId, NULL AS matchedFactId,
             NULL AS matchedScope, w.rowid AS rid
      FROM wakes w INDEXED BY wakes_due
      WHERE w.state = 'pending' AND w.dueAt <= ?4 AND w.conditionKind IS NOT NULL
      ORDER BY w.rowid ASC LIMIT ?3
    )
    """
  end

  defp candidate_sql(:eager) do
    """
    SELECT * FROM (
      SELECT 'C1' AS branch, w.wakeId AS wakeId, f.id AS matchedFactId,
             f.scope AS matchedScope, w.rowid AS rid
      FROM condition_facts f CROSS JOIN wakes w INDEXED BY wakes_condition
      WHERE f.id = ?1
        AND w.state = 'pending' AND w.conditionKind = f.kind
        AND w.conditionScope = f.scope AND f.id > w.conditionAfterId
      ORDER BY f.id ASC, w.rowid ASC LIMIT ?2
    )
    UNION ALL
    SELECT * FROM (
      SELECT 'C2' AS branch, w.wakeId AS wakeId, f.id AS matchedFactId,
             f.scope AS matchedScope, w.rowid AS rid
      FROM condition_facts f CROSS JOIN wakes w INDEXED BY wakes_condition
      WHERE f.id = ?1
        AND w.state = 'pending' AND w.conditionKind = f.kind
        AND w.conditionScope IS NULL AND f.id > w.conditionAfterId
      ORDER BY f.id ASC, w.rowid ASC LIMIT ?2
    )
    UNION ALL
    SELECT * FROM (
      SELECT 'F' AS branch, w.wakeId AS wakeId, NULL AS matchedFactId,
             NULL AS matchedScope, w.rowid AS rid
      FROM wakes w INDEXED BY wakes_due
      WHERE w.state = 'pending' AND w.dueAt <= ?3 AND w.conditionKind IS NOT NULL
      ORDER BY w.rowid ASC LIMIT ?2
    )
    """
  end

  defp advance_watermark(db, rows, batch, {after_fact, ceil}) do
    boundaries =
      Enum.map(~w(C1 C2), fn branch ->
        branch_rows = Enum.filter(rows, &(hd(&1) == branch))

        if length(branch_rows) < batch do
          ceil
        else
          branch_rows
          |> Enum.map(&Enum.at(&1, 2))
          |> Enum.max()
          |> Kernel.-(1)
        end
      end)

    after_fact_new = max(after_fact, Enum.min(boundaries))

    {:ok, _} =
      DB.query(db, "UPDATE scheduler_state SET afterFact = ?1 WHERE id = 0", [after_fact_new])

    :ok
  end

  defp fire_candidate(db, wake_id) do
    result =
      DB.transaction(db, fn txn ->
        case Txn.q(txn, select_wake_sql() <> " WHERE wakeId = ?1", [wake_id]) do
          [row] -> fire_in_txn(txn, to_wake(row))
          [] -> :noop
        end
      end)

    case result do
      {:ok, {:fired, delivery}} -> Gateway.complete_delivery(db, delivery)
      {:ok, _} -> :ok
      {:error, error} -> raise error
    end
  end

  defp fire_in_txn(txn, %{state: "pending", condition_kind: kind} = wake)
       when is_binary(kind) do
    {match_sql, params} =
      if is_nil(wake.condition_scope) do
        {"SELECT id, scope FROM condition_facts WHERE id > ?1 AND kind = ?2 ORDER BY id ASC LIMIT 1",
         [wake.condition_after_id, kind]}
      else
        {"SELECT id, scope FROM condition_facts INDEXED BY condition_facts_match WHERE id > ?1 AND kind = ?2 AND scope = ?3 ORDER BY id ASC LIMIT 1",
         [wake.condition_after_id, kind, wake.condition_scope]}
      end

    match =
      case Txn.q(txn, match_sql, params) do
        [[id, scope]] -> %{id: id, scope: scope}
        [] -> nil
      end

    cause =
      cond do
        match -> "condition"
        wake.due_at <= now() -> "fallback"
        true -> nil
      end

    if cause do
      fired_at = now()

      Txn.q(
        txn,
        "UPDATE wakes SET state = 'fired', firedAt = ?2, firedBy = ?3 WHERE wakeId = ?1 AND state = 'pending'",
        [wake.wake_id, fired_at, cause]
      )

      if Txn.changes(txn) == 1 do
        stamp =
          if cause == "condition",
            do: "[woke: fact #{kind}/#{match.scope || "nil"}]",
            else: "[woke: fallback deadline]"

        delivery =
          Gateway.deliver_prompt_in_txn(
            txn,
            wake.session_key,
            wake.origin,
            stamp <> "\n\n" <> wake.prompt,
            wake_id: wake.wake_id,
            sender: wake.origin,
            target_gate: wake,
            role_ref: wake.target_role
          )

        lifecycle_for_fire(txn, wake, cause, match, delivery)
        {:fired, delivery}
      else
        :noop
      end
    else
      :noop
    end
  end

  defp fire_in_txn(_txn, _wake), do: :noop

  defp lifecycle_for_fire(txn, wake, cause, match, :skipped) do
    matched =
      if match,
        do: " matchedFactId=#{match.id} scope=#{match.scope || "nil"}",
        else: ""

    target = wake.target_role || wake.session_key

    EventLog.lifecycle_in_txn(
      txn,
      "wake_unresolved",
      wake.wake_id,
      "firedBy=#{cause}#{matched} target=#{target} reason=unresolvable"
    )
  end

  defp lifecycle_for_fire(txn, wake, "condition", match, _delivery) do
    EventLog.lifecycle_in_txn(
      txn,
      "wake_condition_fired",
      wake.wake_id,
      "firedBy=condition matchedFactId=#{match.id} kind=#{wake.condition_kind} scope=#{match.scope || "nil"}"
    )
  end

  defp lifecycle_for_fire(txn, wake, "fallback", _match, _delivery) do
    EventLog.lifecycle_in_txn(
      txn,
      "wake_fallback_fired",
      wake.wake_id,
      "firedBy=fallback fallbackAt=#{wake.due_at}"
    )
  end

  defp select_wake_sql do
    "SELECT wakeId, sessionKey, targetRole, origin, prompt, dueAt, state, createdAt, firedAt, reresolve, reresolveSeed, reresolveRung, conditionKind, conditionScope, conditionAfterId, firedBy, creatorSessionKey FROM wakes"
  end

  defp to_wake([
         wake_id,
         session_key,
         target_role,
         origin,
         prompt,
         due_at,
         state,
         created_at,
         fired_at,
         reresolve,
         reresolve_seed,
         reresolve_rung,
         condition_kind,
         condition_scope,
         condition_after_id,
         fired_by,
         creator_session_key
       ]) do
    %{
      wake_id: wake_id,
      session_key: session_key,
      target_role: target_role,
      origin: origin,
      prompt: prompt,
      due_at: due_at,
      state: state,
      created_at: created_at,
      fired_at: fired_at,
      reresolve: reresolve,
      reresolve_seed: reresolve_seed,
      reresolve_rung: reresolve_rung,
      condition_kind: condition_kind,
      condition_scope: condition_scope,
      condition_after_id: condition_after_id,
      fired_by: fired_by,
      creator_session_key: creator_session_key
    }
  end

  defp schedule_tick(tick_ms), do: Process.send_after(self(), :tick, tick_ms)

  defp transaction!(db, fun) do
    case DB.transaction(db, fun) do
      {:ok, result} -> result
      {:error, error} -> raise error
    end
  end

  defp now, do: System.system_time(:millisecond)
end
