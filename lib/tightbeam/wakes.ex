defmodule Tightbeam.Wakes do
  @moduledoc """
  Persistent wake store + scheduler (TS reference: src/core/wakes.ts — its
  test file is the acceptance oracle). A wake is a fact-shaped, durable
  "deliver this prompt to this session at dueAt" row; delivery goes through
  the SAME turn pipeline as a user post (T8: coordination is fact-shaped).

  Process shape: ONE GenServer (`Tightbeam.WakeScheduler` in the tree) owning
  a tick timer. Every tick (and on explicit `fire_due/1`) it claims due
  pending wakes IN THE DB (CAS pending→fired inside a transaction, exactly
  like Ledger.finish) and hands each to the injected `deliver` fun. Crash
  between claim and delivery is covered by the turns table's `wakeId` UNIQUE
  dedupe: delivery is at-least-once, enqueue is exactly-once (kill-matrix
  case: WakeScheduler killed before delivery / after enqueue-before-mark must
  neither lose nor duplicate — turns.wakeId proves it).

  States: pending → fired | canceled. Cancel requires the CALLER's origin to
  match the wake's origin (you cancel your own wakes only).
  """

  use GenServer
  alias Tightbeam.DB

  @type db :: GenServer.server()

  @type wake :: %{
          wake_id: String.t(),
          session_key: String.t(),
          origin: String.t(),
          prompt: String.t(),
          due_at: integer(),
          state: String.t(),
          created_at: integer()
        }

  @typedoc "Delivery fun injected by the composition root: fires the prompt into the turn pipeline."
  @type deliver :: (wake() -> any())

  @ddl """
  CREATE TABLE IF NOT EXISTS wakes (
    wakeId     TEXT PRIMARY KEY,
    sessionKey TEXT NOT NULL,
    origin     TEXT NOT NULL,
    prompt     TEXT NOT NULL,
    dueAt      INTEGER NOT NULL,
    state      TEXT NOT NULL DEFAULT 'pending' CHECK (state IN ('pending','fired','canceled')),
    createdAt  INTEGER NOT NULL
  );
  CREATE INDEX IF NOT EXISTS wakes_due ON wakes (state, dueAt) WHERE state = 'pending';
  """

  @spec ensure_schema(db()) :: :ok | {:error, term()}
  def ensure_schema(db \\ Tightbeam.DB), do: DB.execute(db, @ddl)

  ## Store (pure DB ops — callable without the scheduler process, e.g. by inspect)

  @doc "Persist a pending wake (id minted here, prefix `w_`). Returns the row."
  @spec schedule(db(), %{
          session_key: String.t(),
          origin: String.t(),
          prompt: String.t(),
          due_at: integer()
        }) :: wake()
  def schedule(db \\ Tightbeam.DB, input) do
    raise "TODO(sol): #{inspect({db, input})}"
  end

  @doc "Cancel a pending wake IF `origin` scheduled it. True if a row transitioned."
  @spec cancel(db(), String.t(), String.t()) :: boolean()
  def cancel(db \\ Tightbeam.DB, wake_id, origin) do
    raise "TODO(sol): #{inspect({db, wake_id, origin})}"
  end

  @spec get(db(), String.t()) :: wake() | nil
  def get(db \\ Tightbeam.DB, wake_id) do
    raise "TODO(sol): #{inspect({db, wake_id})}"
  end

  @doc "All pending wakes, soonest first (inspect filters to owned sessions)."
  @spec list_pending(db()) :: [wake()]
  def list_pending(db \\ Tightbeam.DB) do
    raise "TODO(sol): #{inspect(db)}"
  end

  ## Scheduler process

  @doc """
  Start the scheduler. Opts: `:deliver` (required — see `t:deliver/0`),
  `:db`, `:tick_ms` (default 1000), `:name` (default `Tightbeam.WakeScheduler`
  — the registered name the wake verb handler calls).
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, Tightbeam.WakeScheduler))
  end

  @doc """
  Claim + deliver every due pending wake NOW (synchronous). The wake verb
  calls this after scheduling an immediate DM so delivery never waits a tick.
  """
  @spec fire_due(GenServer.server()) :: :ok
  def fire_due(server \\ Tightbeam.WakeScheduler) do
    raise "TODO(sol): #{inspect(server)}"
  end

  @impl true
  def init(opts) do
    raise "TODO(sol): stash deliver/db/tick_ms, schedule first tick — #{inspect(opts)}"
  end
end
