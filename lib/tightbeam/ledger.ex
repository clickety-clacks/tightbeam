defmodule Tightbeam.Ledger do
  @moduledoc """
  The durable turn ledger — the keystone (spec: The keystone). One row per
  accepted prompt; a closed one-way state machine
  `queued → running → (delivered | canceled | failed | failed_unknown)`.

  Invariants enforced HERE, in SQL, not in callers:
  - Ordering: `seq` (AUTOINCREMENT, assigned in-transaction) is THE execution
    order; process message ordering is irrelevant.
  - One turn per session: `claim_next/2` refuses while a running row exists.
  - Exactly-one durable terminal transition: guarded UPDATE (CAS on status).
  - Wake dedupe: `wakeId` UNIQUE — at-least-once delivery attempts yield
    exactly-once enqueue.
  - Conservation: every accepted prompt reaches exactly one terminal state;
    `non_terminal_older_than/1` must return [] in steady state (audited by
    tests and the soak).
  - No automatic retries: `failed_unknown` is terminal; nothing here re-sends.
  """

  alias Tightbeam.DB
  alias Tightbeam.DB.Txn

  @typedoc "A queued/claimed turn as returned by claim_next/3."
  @type turn :: %{
          seq: integer(),
          message_id: String.t(),
          origin: String.t(),
          prompt: String.t(),
          wake_id: String.t() | nil
        }

  @typedoc "Terminal states — one-way; no transition leaves them."
  @type terminal :: String.t()

  @type db :: GenServer.server()

  @ddl """
  CREATE TABLE IF NOT EXISTS turns (
    seq        INTEGER PRIMARY KEY AUTOINCREMENT,
    sessionKey TEXT NOT NULL,
    messageId  TEXT NOT NULL,
    wakeId     TEXT UNIQUE,
    origin     TEXT NOT NULL,
    prompt     TEXT NOT NULL,
    status     TEXT NOT NULL DEFAULT 'queued'
               CHECK (status IN ('queued','running','delivered','canceled',
                                 'failed','failed_unknown')),
    owner      TEXT,
    adapterGen INTEGER,
    requestRef TEXT,
    error      TEXT,
    createdAt  INTEGER NOT NULL,
    startedAt  INTEGER,
    endedAt    INTEGER,
    publishedAt INTEGER
  );
  CREATE INDEX IF NOT EXISTS turns_pending
    ON turns (status, sessionKey, seq)
    WHERE status IN ('queued','running');
  CREATE INDEX IF NOT EXISTS turns_session ON turns (sessionKey, seq);
  CREATE INDEX IF NOT EXISTS turns_unpublished
    ON turns (endedAt) WHERE endedAt IS NOT NULL AND publishedAt IS NULL;
  """

  @spec ensure_schema(db()) :: :ok | {:error, term()}
  def ensure_schema(db \\ Tightbeam.DB), do: DB.execute(db, @ddl)

  @doc """
  Transactionally enqueue a turn (call inside the same DB.transaction that
  persists the message row, so message+turn commit together). Returns seq.
  Raises on wakeId conflict (caller treats as already-enqueued).
  """
  @spec enqueue_in_txn(Txn.t(), map()) :: integer()
  def enqueue_in_txn(%Txn{} = txn, attrs) do
    now = System.system_time(:millisecond)

    Txn.q(txn, """
      INSERT INTO turns (sessionKey, messageId, wakeId, origin, prompt, createdAt)
      VALUES (?1, ?2, ?3, ?4, ?5, ?6)
    """, [
      Map.fetch!(attrs, :session_key),
      Map.fetch!(attrs, :message_id),
      Map.get(attrs, :wake_id),
      Map.fetch!(attrs, :origin),
      Map.fetch!(attrs, :prompt),
      now
    ])

    [[seq]] = Txn.q(txn, "SELECT last_insert_rowid()")
    seq
  end

  @doc "Convenience: enqueue outside an existing transaction."
  @spec enqueue(db(), map()) :: {:ok, integer()} | {:error, :duplicate_wake | term()}
  def enqueue(db \\ Tightbeam.DB, attrs) do
    case DB.transaction(db, fn txn -> enqueue_in_txn(txn, attrs) end) do
      {:ok, seq} -> {:ok, seq}
      {:error, %{message: msg} = e} ->
        if is_binary(msg) and String.contains?(msg, "UNIQUE") do
          {:error, :duplicate_wake}
        else
          {:error, e}
        end
      {:error, e} -> {:error, e}
    end
  end

  @doc """
  Claim the next queued turn for a session — refuses if one is running
  (one-turn-per-session in SQL). Returns {:ok, %{seq:, prompt:, ...}} or
  :none or :busy.
  """
  @spec claim_next(db(), String.t(), String.t()) :: {:ok, turn()} | :busy | :none
  def claim_next(db \\ Tightbeam.DB, session_key, owner) do
    now = System.system_time(:millisecond)

    {:ok, result} =
      DB.transaction(db, fn txn ->
        running =
          Txn.q(txn, "SELECT seq FROM turns WHERE sessionKey = ?1 AND status = 'running' LIMIT 1", [session_key])

        case running do
          [_ | _] ->
            :busy

          [] ->
            Txn.q(txn, """
              UPDATE turns SET status = 'running', owner = ?2, startedAt = ?3
              WHERE seq = (SELECT seq FROM turns
                           WHERE sessionKey = ?1 AND status = 'queued'
                           ORDER BY seq LIMIT 1)
                AND status = 'queued'
            """, [session_key, owner, now])

            if Txn.changes(txn) == 1 do
              [[seq, message_id, origin, prompt, wake_id]] =
                Txn.q(txn, """
                  SELECT seq, messageId, origin, prompt, wakeId FROM turns
                  WHERE sessionKey = ?1 AND status = 'running'
                """, [session_key])

              {:ok, %{seq: seq, message_id: message_id, origin: origin, prompt: prompt, wake_id: wake_id}}
            else
              :none
            end
        end
      end)

    result
  end

  @doc """
  Exactly-one durable terminal transition (CAS). Returns :ok if this caller
  won the transition, :already_terminal otherwise.
  """
  @spec finish(db(), integer(), terminal(), String.t() | nil) :: :ok | :already_terminal
  def finish(db \\ Tightbeam.DB, seq, terminal, error \\ nil)
      when terminal in ~w(delivered canceled failed failed_unknown) do
    now = System.system_time(:millisecond)

    {:ok, won} =
      DB.transaction(db, fn txn ->
        Txn.q(txn, """
          UPDATE turns SET status = ?2, endedAt = ?3, error = ?4
          WHERE seq = ?1 AND status = 'running'
        """, [seq, terminal, now, error])

        Txn.changes(txn) == 1
      end)

    if won, do: :ok, else: :already_terminal
  end

  @doc """
  Boot/periodic recovery: every running turn has UNKNOWN outcome → terminal
  failed_unknown (never auto-retried; tools may have executed). Returns the
  seqs transitioned, for exactly-one terminal publication by the caller.
  """
  @spec recover_running(db()) :: [integer()]
  def recover_running(db \\ Tightbeam.DB) do
    now = System.system_time(:millisecond)

    {:ok, seqs} =
      DB.transaction(db, fn txn ->
        rows = Txn.q(txn, "SELECT seq FROM turns WHERE status = 'running'")

        Txn.q(txn, """
          UPDATE turns SET status = 'failed_unknown', endedAt = ?1,
                           error = COALESCE(error, 'interrupted: outcome unknown')
          WHERE status = 'running'
        """, [now])

        Enum.map(rows, fn [seq] -> seq end)
      end)

    seqs
  end

  @doc "Sessions with pending work — the Reconciler's feed (liveness scan)."
  @spec pending_sessions(db()) :: [String.t()]
  def pending_sessions(db \\ Tightbeam.DB) do
    {:ok, rows} =
      DB.query(db, "SELECT DISTINCT sessionKey FROM turns WHERE status IN ('queued','running')")

    Enum.map(rows, fn [k] -> k end)
  end

  @doc "Terminal rows not yet published (at-least-once publication feed)."
  @spec unpublished_terminals(db()) :: [map()]
  def unpublished_terminals(db \\ Tightbeam.DB) do
    {:ok, rows} =
      DB.query(db, """
        SELECT seq, sessionKey, messageId, status FROM turns
        WHERE endedAt IS NOT NULL AND publishedAt IS NULL ORDER BY seq
      """)

    Enum.map(rows, fn [seq, sk, mid, status] ->
      %{seq: seq, session_key: sk, message_id: mid, status: status}
    end)
  end

  @spec mark_published(db(), integer()) :: :ok
  def mark_published(db \\ Tightbeam.DB, seq) do
    now = System.system_time(:millisecond)
    {:ok, _} = DB.query(db, "UPDATE turns SET publishedAt = ?2 WHERE seq = ?1", [seq, now])
    :ok
  end

  @doc "Stamp the adapter generation selected for a running turn."
  @spec stamp_adapter(db(), integer(), non_neg_integer()) :: :ok
  def stamp_adapter(db \\ Tightbeam.DB, seq, generation) do
    {:ok, _} = DB.query(db, "UPDATE turns SET adapterGen = ?2 WHERE seq = ?1 AND status = 'running'", [seq, generation])
    :ok
  end

  @doc "Newest adapter generation stamped by an earlier turn in the session, or nil."
  @spec prior_adapter_generation(db(), String.t(), integer()) :: non_neg_integer() | nil
  def prior_adapter_generation(db \\ Tightbeam.DB, session_key, before_seq) do
    {:ok, rows} =
      DB.query(db, """
        SELECT adapterGen FROM turns
        WHERE sessionKey = ?1 AND seq < ?2 AND adapterGen IS NOT NULL
        ORDER BY seq DESC LIMIT 1
      """, [session_key, before_seq])

    case rows do
      [[generation]] -> generation
      [] -> nil
    end
  end

  @doc "Conservation audit: non-terminal rows older than max_age_ms. Must be []."
  @spec non_terminal_older_than(db(), integer()) :: [integer()]
  def non_terminal_older_than(db \\ Tightbeam.DB, max_age_ms) do
    cutoff = System.system_time(:millisecond) - max_age_ms

    {:ok, rows} =
      DB.query(db, """
        SELECT seq FROM turns
        WHERE status IN ('queued','running') AND createdAt < ?1
      """, [cutoff])

    Enum.map(rows, fn [seq] -> seq end)
  end
end
