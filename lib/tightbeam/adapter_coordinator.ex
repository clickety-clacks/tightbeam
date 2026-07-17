defmodule Tightbeam.AdapterCoordinator do
  @moduledoc """
  Owner of adapter lifecycle (port spec §Adapter lifecycle — this module IS
  that section; no TS equivalent, the TS gateway restarted nothing).

  One `Tightbeam.Acp.Adapter` per adapter key `{harness, archetype}`, started
  lazily under a DynamicSupervisor with restart: :temporary — the coordinator
  owns ALL restarts, so `normal` exits and crashes take the same path (no
  supervisor auto-restart racing the coordinator's bookkeeping).

  Invariants (binding):
  - GENERATION: a monotonic integer per adapter key, bumped on every adapter
    death/restart. Lanes stamp the generation they ran a turn against; a lane
    seeing a stale generation at next turn start performs session/load LAZILY
    (parent-spec rule: no eager mass re-adoption).
  - Backoff: restart with exponential backoff 1s → 60s cap. After 5
    consecutive failures the circuit OPENS: the key is marked degraded,
    `adapter_for/2` returns {:error, :degraded} so affected turns fail fast
    with a clear reason, /version|/health reflects it, the gateway stays up.
    A successful restart closes the circuit and resets the count.
  - Re-adoption semaphore: at most 3 concurrent session/load calls per
    coordinator (no thundering herd after an adapter bounce). session/load
    failure → that session degraded + turn failed with reason.
  - Planned idle-reap is a coordinator action and its lifecycle event is
    flagged as planned — distinguishable from crashes in lifecycle_events.
  - The coordinator MONITORS adapters (never links); adapter death emits a
    lifecycle event with the exit reason and bumps the generation.
  """

  use GenServer

  @type adapter_key :: {atom(), String.t()}

  @typedoc "What a lane needs to run a turn: the adapter pid and the generation it belongs to."
  @type checkout :: {:ok, pid(), generation :: pos_integer()} | {:error, :degraded}

  @doc """
  Start the coordinator. Opts: `:adapter_sup` (the DynamicSupervisor),
  `:adapter_opts` fun (`adapter_key -> keyword` — cmd/home/cwd/env assembled
  by the composition root, incl. TIGHTBEAM_HOME + PATH with the CLI bin),
  `:db`, `:name`.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc """
  The adapter for a key, starting it lazily on first use. Returns the pid AND
  the current generation (the lane stamps it against the turn). Degraded key →
  {:error, :degraded} — fail the turn fast, never queue behind a dead adapter.
  """
  @spec adapter_for(GenServer.server(), adapter_key()) :: checkout()
  def adapter_for(server \\ __MODULE__, key) do
    raise "TODO(sol): #{inspect({server, key})}"
  end

  @doc "Current generation for a key (0 if never started) — the lane's staleness probe."
  @spec generation(GenServer.server(), adapter_key()) :: non_neg_integer()
  def generation(server \\ __MODULE__, key) do
    raise "TODO(sol): #{inspect({server, key})}"
  end

  @doc """
  Run `fun` under the re-adoption semaphore (max 3 concurrent). Used by lanes
  performing lazy session/load after a generation bump.
  """
  @spec with_load_slot(GenServer.server(), (-> result)) :: result when result: term()
  def with_load_slot(server \\ __MODULE__, fun) do
    raise "TODO(sol): #{inspect({server, fun})}"
  end

  @doc "Health projection for /version: per-key %{generation, circuit, consecutive_failures}."
  @spec health(GenServer.server()) :: %{optional(String.t()) => map()}
  def health(server \\ __MODULE__) do
    raise "TODO(sol): #{inspect(server)}"
  end

  @impl true
  def init(opts) do
    raise "TODO(sol): #{inspect(opts)}"
  end
end
