defmodule Tightbeam.Gateway do
  @moduledoc """
  The composition root (TS reference: src/gateway.ts — every verb handler and
  the turn pipeline port from there, behavior-for-behavior). Everything below
  this module is independently tested and knows nothing about the whole; this
  module wires stores, pipeline, wire, and adapters together and NOTHING
  else — no logic of its own beyond assembly and the verb handlers.

  Composition strategy (the Elixir-shape decision — binding): there is no
  object graph. Cross-component references are REGISTERED NAMES
  (Tightbeam.DB, Tightbeam.ConnRegistry, Tightbeam.WakeScheduler,
  Tightbeam.AdapterCoordinator, Tightbeam.LaneManager), so there is no
  startup-order circularity: the verb handler table and the turn runner are
  plain funs built here that call names, and every named process is up before
  Bandit accepts a first connection (children order in `children/1`).

  Children appended to Tightbeam.Application's tree, in order:
  ConnRegistry → WakeScheduler → AdapterSupervisor (DynamicSupervisor) →
  AdapterCoordinator → LaneManager (with the runner built here) → Bandit
  (Wire.Router; port + WS upgrade). All under the SAME rest_for_one root —
  a DB restart still restarts everything that could hold stale state.

  The turn pipeline (runner passed to lanes; gateway.ts `runTurn` +
  fifo wiring, adapted to the Ledger):
  1. Lane claims a turn (Ledger). Turn start already broadcast
     accepted/queued by the post/wake handler; the lane's TurnTask broadcasts
     running + typing(on) + activity(on).
  2. Resolve the session (Org); checkout adapter (AdapterCoordinator) — if
     the session's pointer generation is stale, session/load under the load
     semaphore, appending pointer reason "loaded".
  3. No pointer yet → Adapter.new_session, append pointer "created".
  4. Adapter.prompt; on {:ok, %{text: _}} append the assistant message to
     Projection (sender "tightbeam", reply_to the echo) and publish via
     ConnRegistry (seq-ordered, from the commit path).
  5. Terminal: Ledger.finish CAS in the lane; broadcast terminal
     prompt_turn_state + typing(off) + activity(off). Golden frame order for
     the canonical turn: echo → accepted → running → typing(on) →
     activity(on) → ack → assistant → terminal state → typing(off) →
     activity(off).

  Delivery parity (gateway.ts `deliverPrompt`): a user post and a wake are
  the SAME mechanism — append echo to Projection + enqueue exactly one turn
  (Ledger, in ONE transaction: message+turn commit together), broadcast the
  echo, nudge the lane. Wake delivery passes wake_id so the Ledger's UNIQUE
  dedupes at-least-once firing.

  Verb handlers (all built by `handlers/1`, dispatched via Tightbeam.Dispatch;
  port each from gateway.ts's dispatcher.register blocks, including):
  - post (echo+enqueue; dedupe contract), wake (schedule/cancel/immediate
    fire; a wake MUST carry a prompt), spawn (idempotency, headcount cap,
    handle uniqueness, owner inherited from spawn tree), retire (idempotent,
    owner-only), tune (rename | set_model; live-session apply), cancel,
    inspect (owned sessions + owned pending wakes + admin: pending devices),
    approve-device/deny-device/revoke-device/promote-user (admin-gated via
    the origin's owning USER — user-scoped admin).
  - Caller resolution (gateway.ts `resolveCaller`): "user:x" → x;
    "agent:handle" → active session's owner; anything else → unknown_caller.
  """

  @typedoc "Gateway config (gateway.ts GatewayConfig)."
  @type config :: %{
          base_dir: String.t(),
          cwd: String.t(),
          port: non_neg_integer(),
          default_harness: atom(),
          default_model: String.t(),
          max_live_sessions_per_user: pos_integer(),
          wake_tick_ms: pos_integer()
        }

  @doc """
  The wire/adapter children to append after Tightbeam.Application's base
  children (see moduledoc order). Also: ensure schemas for Devices/
  Idempotency/Wakes/Projection/Org, mint + persist the cliToken and
  gateway.json (mode 0600) in base_dir, install the CLI bin.
  """
  @spec children(config()) :: [Supervisor.child_spec() | {module(), term()}]
  def children(config) do
    raise "TODO(sol): #{inspect(config)}"
  end

  @doc "The immutable verb-handler table (see moduledoc list) — built once, passed to Dispatch."
  @spec handlers(config()) :: Tightbeam.Dispatch.handlers()
  def handlers(config) do
    raise "TODO(sol): #{inspect(config)}"
  end

  @doc """
  Shared turn-bearing delivery (gateway.ts `deliverPrompt`): ONE transaction
  appends the echo (Projection) + enqueues the turn (Ledger.enqueue_in_txn),
  then broadcasts the echo and nudges the lane. Returns the dedupe outcome.
  """
  @spec deliver_prompt(String.t(), String.t(), String.t(), keyword()) ::
          :appended | :duplicate | :conflict
  def deliver_prompt(session_key, origin, prompt, opts \\ []) do
    raise "TODO(sol): #{inspect({session_key, origin, prompt, opts})}"
  end

  @doc """
  SessionStatusPayload projection for the status route (gateway.ts
  `sessionStatus`): registry provenance + ledger run state (queue depth from
  pending turns) + per-harness capability advertisement from the model
  catalog. Nil for unknown sessions.
  """
  @spec session_status(String.t()) :: map() | nil
  def session_status(session_key) do
    raise "TODO(sol): #{inspect(session_key)}"
  end
end
