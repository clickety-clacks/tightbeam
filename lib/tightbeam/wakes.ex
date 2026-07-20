defmodule Tightbeam.Wakes do
  @moduledoc """
  Persistent wake store + scheduler (TS reference: src/core/wakes.ts — its
  test file is the acceptance oracle). A wake is a fact-shaped, durable
  "deliver this prompt to this session at dueAt" row; delivery goes through
  the SAME turn pipeline as a user post (T8: coordination is fact-shaped).

  Process shape: ONE GenServer (`Tightbeam.WakeScheduler` in the tree) owning
  a tick timer. Every tick (and on explicit `fire_due/1`) it reads due
  pending wakes, DELIVERS each, and marks a wake fired (CAS pending→fired)
  only AFTER its delivery returns — wakes.ts order, load-bearing:
  - deliver raises → wake stays pending, retried next tick (at-least-once;
    a poison wake retries visibly rather than vanishing).
  - crash between deliver and mark → redelivered after restart, deduped by
    the turns table's `wakeId` UNIQUE (enqueue is exactly-once).
  Marking fired BEFORE delivering would silently lose the wake on a crash in
  between — never reorder this.

  States: pending → fired | canceled. Cancel requires the CALLER's origin to
  match the wake's origin (you cancel your own wakes only).
  """

  use GenServer
  alias Tightbeam.DB
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
    reresolveRung INTEGER NULL
  );
  CREATE INDEX IF NOT EXISTS wakes_due ON wakes (state, dueAt);
  """

  @spec ensure_schema(db()) :: :ok | {:error, term()}
  def ensure_schema(db \\ Tightbeam.DB) do
    result = DB.execute(db, @ddl)

    for ddl <- [
          "ALTER TABLE wakes ADD COLUMN targetRole TEXT",
          "ALTER TABLE wakes ADD COLUMN reresolve TEXT NULL CHECK (reresolve IN ('lineage'))",
          "ALTER TABLE wakes ADD COLUMN reresolveSeed TEXT NULL",
          "ALTER TABLE wakes ADD COLUMN reresolveRung INTEGER NULL"
        ] do
      case DB.query(db, ddl) do
        {:ok, _} -> :ok
        {:error, e} -> if inspect(e) =~ "duplicate column", do: :ok, else: raise(e)
      end
    end

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
      reresolve: Map.get(input, :reresolve),
      reresolve_seed: Map.get(input, :reresolve_seed),
      reresolve_rung: Map.get(input, :reresolve_rung)
    }

    transaction!(db, fn txn ->
      Txn.q(
        txn,
        """
          INSERT INTO wakes
            (wakeId, sessionKey, targetRole, origin, prompt, dueAt, state, createdAt, firedAt,
             reresolve, reresolveSeed, reresolveRung)
          VALUES (?1, ?2, ?3, ?4, ?5, ?6, 'pending', ?7, NULL, ?8, ?9, ?10)
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
          wake.reresolve_rung
        ]
      )

      wake
    end)
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

      Txn.changes(txn) == 1
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

  @impl true
  def init(opts) do
    state = %{
      deliver: Keyword.fetch!(opts, :deliver),
      db: Keyword.get(opts, :db, Tightbeam.DB),
      tick_ms: Keyword.get(opts, :tick_ms, 1_000)
    }

    schedule_tick(state.tick_ms)
    {:ok, state}
  end

  @impl true
  def handle_call(:fire_due, _from, state) do
    deliver_due(state)
    {:reply, :ok, state}
  end

  @impl true
  def handle_info(:tick, state) do
    deliver_due(state)
    schedule_tick(state.tick_ms)
    {:noreply, state}
  end

  # Deliver-then-mark (see moduledoc — never reorder): a raising deliver
  # leaves its wake pending for the next tick; a crash between deliver and
  # mark redelivers, deduped by turns.wakeId.
  defp deliver_due(%{db: db, deliver: deliver}) do
    {:ok, rows} =
      DB.query(
        db,
        select_wake_sql() <> " WHERE state = 'pending' AND dueAt <= ?1 ORDER BY dueAt ASC",
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

    :ok
  end

  defp select_wake_sql do
    "SELECT wakeId, sessionKey, targetRole, origin, prompt, dueAt, state, createdAt, firedAt, reresolve, reresolveSeed, reresolveRung FROM wakes"
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
         reresolve_rung
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
      reresolve_rung: reresolve_rung
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
