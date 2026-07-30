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
    roleRef    TEXT,
    roleFallback INTEGER NOT NULL DEFAULT 0,
    assignmentId TEXT,
    jobRef     TEXT,
    model      TEXT,
    harness    TEXT,
    replyAttention INTEGER NOT NULL DEFAULT 0,
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
  def ensure_schema(db \\ Tightbeam.DB) do
    result = DB.execute(db, @ddl)

    for ddl <- [
          "ALTER TABLE turns ADD COLUMN roleRef TEXT",
          "ALTER TABLE turns ADD COLUMN roleFallback INTEGER NOT NULL DEFAULT 0",
          "ALTER TABLE turns ADD COLUMN assignmentId TEXT",
          "ALTER TABLE turns ADD COLUMN jobRef TEXT",
          "ALTER TABLE turns ADD COLUMN model TEXT",
          "ALTER TABLE turns ADD COLUMN harness TEXT",
          "ALTER TABLE turns ADD COLUMN replyAttention INTEGER NOT NULL DEFAULT 0"
        ] do
      case DB.query(db, ddl) do
        {:ok, _} -> :ok
        {:error, e} -> if inspect(e) =~ "duplicate column", do: :ok, else: raise(e)
      end
    end

    :ok =
      DB.execute(
        db,
        """
        CREATE INDEX IF NOT EXISTS turns_job_ref ON turns (jobRef);
        CREATE INDEX IF NOT EXISTS turns_assignment_id ON turns (assignmentId);
        """
      )

    result
  end

  @doc """
  Transactionally enqueue a turn (call inside the same DB.transaction that
  persists the message row, so message+turn commit together). Returns seq.
  Raises on wakeId conflict (caller treats as already-enqueued).
  """
  @spec enqueue_in_txn(Txn.t(), map()) :: integer()
  def enqueue_in_txn(%Txn{} = txn, attrs) do
    now = System.system_time(:millisecond)

    Txn.q(
      txn,
      """
        INSERT INTO turns
          (sessionKey, messageId, wakeId, origin, prompt, roleRef, roleFallback,
           assignmentId, jobRef, createdAt)
        VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10)
      """,
      [
        Map.fetch!(attrs, :session_key),
        Map.fetch!(attrs, :message_id),
        Map.get(attrs, :wake_id),
        Map.fetch!(attrs, :origin),
        Map.fetch!(attrs, :prompt),
        Map.get(attrs, :role_ref),
        if(Map.get(attrs, :role_fallback, false), do: 1, else: 0),
        Map.get(attrs, :assignment_id),
        Map.get(attrs, :job_ref),
        now
      ]
    )

    [[seq]] = Txn.q(txn, "SELECT last_insert_rowid()")
    seq
  end

  @doc "Convenience: enqueue outside an existing transaction."
  @spec enqueue(db(), map()) :: {:ok, integer()} | {:error, :duplicate_wake | term()}
  def enqueue(db \\ Tightbeam.DB, attrs) do
    case DB.transaction(db, fn txn -> enqueue_in_txn(txn, attrs) end) do
      {:ok, seq} ->
        {:ok, seq}

      {:error, %{message: msg} = e} ->
        if is_binary(msg) and String.contains?(msg, "UNIQUE") do
          {:error, :duplicate_wake}
        else
          {:error, e}
        end

      {:error, e} ->
        {:error, e}
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
          Txn.q(
            txn,
            "SELECT seq FROM turns WHERE sessionKey = ?1 AND status = 'running' LIMIT 1",
            [session_key]
          )

        case running do
          [_ | _] ->
            :busy

          [] ->
            {session_filter, selected_mind} =
              case Txn.q(
                     txn,
                     "SELECT 1 FROM sqlite_master WHERE type='table' AND name='sessions'"
                   ) do
                [[1]] ->
                  mind =
                    case Txn.q(
                           txn,
                           "SELECT model, harness FROM sessions WHERE sessionKey = ?1",
                           [session_key]
                         ) do
                      [[model, harness]] -> {model, harness}
                      [] -> {nil, nil}
                    end

                  filter = """
                  AND EXISTS (
                    SELECT 1 FROM sessions AS s
                    WHERE s.sessionKey = t.sessionKey AND s.state = 'active'
                      AND (s.adjudicationHold IS NULL OR
                           (s.adjudicationHold != '*' AND t.wakeId = s.adjudicationHold))
                  )
                  """

                  {filter, mind}

                [] ->
                  {"", {nil, nil}}
              end

            Txn.q(
              txn,
              """
                UPDATE turns
                SET status = 'running', owner = ?2, startedAt = ?3,
                    model = ?4, harness = ?5
                WHERE seq = (SELECT t.seq FROM turns AS t
                             WHERE t.sessionKey = ?1 AND t.status = 'queued'
                               #{session_filter}
                             ORDER BY seq LIMIT 1)
                  AND status = 'queued'
              """,
              [session_key, owner, now, elem(selected_mind, 0), elem(selected_mind, 1)]
            )

            if Txn.changes(txn) == 1 do
              [[seq, message_id, origin, prompt, wake_id]] =
                Txn.q(
                  txn,
                  """
                    SELECT seq, messageId, origin, prompt, wakeId FROM turns
                    WHERE sessionKey = ?1 AND status = 'running'
                  """,
                  [session_key]
                )

              {:ok,
               %{
                 seq: seq,
                 message_id: message_id,
                 origin: origin,
                 prompt: prompt,
                 wake_id: wake_id
               }}
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
    {:ok, won} =
      DB.transaction(db, fn txn ->
        finish_in_txn(txn, seq, terminal, error)
      end)

    if won, do: :ok, else: :already_terminal
  end

  @doc "Terminal transition inside the caller's transaction; recovery completion releases its hold."
  @spec finish_in_txn(Txn.t(), integer(), terminal(), String.t() | nil) :: boolean()
  def finish_in_txn(%Txn{} = txn, seq, terminal, error \\ nil)
      when terminal in ~w(delivered canceled failed failed_unknown) do
    now = System.system_time(:millisecond)

    Txn.q(
      txn,
      "UPDATE turns SET status = ?2, endedAt = ?3, error = ?4 WHERE seq = ?1 AND status = 'running'",
      [seq, terminal, now, error]
    )

    won = Txn.changes(txn) == 1

    sessions_exist? =
      Txn.q(txn, "SELECT 1 FROM sqlite_master WHERE type='table' AND name='sessions'") == [[1]]

    if won and sessions_exist? do
      episode = if terminal == "delivered", do: nil, else: probe_episode(txn, seq)

      if is_nil(episode) do
        Txn.q(
          txn,
          """
          UPDATE sessions SET adjudicationHold = NULL, updatedAt = ?2
          WHERE sessionKey = (SELECT sessionKey FROM turns WHERE seq = ?1)
            AND adjudicationHold = (SELECT wakeId FROM turns WHERE seq = ?1)
          """,
          [seq, now]
        )
      else
        # PROBE-TERMINAL TOTALITY (spec s4-operability-v1 §2): a heal probe
        # clears the hold only by SUCCEEDING. failed / canceled / task-crash all
        # land here and re-hold, so the adapter fault has to actually heal before
        # the session runs real work. The human recovery path is untouched — only
        # the heal sweep stamps the healToken this predicate requires.
        rehold_probe(txn, seq, now, episode)
      end
    end

    won
  end

  @doc """
  Re-hold the session of a probe turn identified by `seq`, wide (`'*'`), and arm
  the re-hold's probe retry (spec s4-operability-v1 §2: a re-hold is a NEW hold
  and owes its own probe — the failed probe's adapter may already be ready and
  will then never emit another heal edge). `episode` is the probe episode the
  caller already resolved for this turn's wake. Shared by the terminal writers;
  idempotent, including the retry (one per failed probe wake).
  """
  @spec rehold_probe(Txn.t(), integer(), integer(), map()) :: :ok
  def rehold_probe(%Txn{} = txn, seq, now, episode) do
    Txn.q(
      txn,
      """
      UPDATE sessions SET adjudicationHold = '*', updatedAt = ?2
      WHERE sessionKey = (SELECT sessionKey FROM turns WHERE seq = ?1)
        AND adjudicationHold = (SELECT wakeId FROM turns WHERE seq = ?1)
      """,
      [seq, now]
    )

    if Txn.changes(txn) == 1 do
      Tightbeam.Adjudication.schedule_probe_retry_in_txn(txn, episode)
    end

    :ok
  end

  defp probe_episode(%Txn{} = txn, seq) do
    episodes_exist? =
      Txn.q(
        txn,
        "SELECT 1 FROM sqlite_master WHERE type='table' AND name='adjudication_episodes'"
      ) ==
        [[1]]

    with true <- episodes_exist?,
         [[wake_id]] when is_binary(wake_id) <-
           Txn.q(txn, "SELECT wakeId FROM turns WHERE seq = ?1", [seq]) do
      Tightbeam.Adjudication.probe_episode_for_wake_in_txn(txn, wake_id)
    else
      _ -> nil
    end
  end

  @doc """
  Cancel every queued turn when a session retires, inside the retire transaction.

  Invariant (newly minted): a retired session can never execute, so its queued
  turns are canceled, not failed; this is the single drain point for every retire.
  Setting endedAt routes each row through the existing terminal publication sweep.
  """
  @spec drain_queued_for_retire_in_txn(Txn.t(), String.t(), String.t()) :: [integer()]
  def drain_queued_for_retire_in_txn(%Txn{} = txn, session_key, reason) do
    turns_exist? =
      Txn.q(txn, "SELECT 1 FROM sqlite_master WHERE type='table' AND name='turns'") == [[1]]

    if turns_exist? do
      rows =
        Txn.q(
          txn,
          "SELECT seq FROM turns WHERE sessionKey = ?1 AND status = 'queued' ORDER BY seq",
          [session_key]
        )

      Txn.q(
        txn,
        """
        UPDATE turns SET status = 'canceled', endedAt = ?2, error = ?3
        WHERE sessionKey = ?1 AND status = 'queued'
        """,
        [session_key, System.system_time(:millisecond), reason]
      )

      Enum.map(rows, &hd/1)
    else
      []
    end
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
        seqs = Enum.map(rows, fn [seq] -> seq end)

        # A probe in flight across a restart is a NON-DELIVERED probe terminal:
        # its hold must survive as a wide hold rather than be freed by the
        # boot-reconciliation sweep (spec s4-operability-v1 §2, totality).
        # Read before the UPDATE only for the seqs; the re-hold is keyed by seq
        # and so is order-independent.
        sessions_exist? =
          Txn.q(txn, "SELECT 1 FROM sqlite_master WHERE type='table' AND name='sessions'") == [
            [1]
          ]

        Txn.q(
          txn,
          """
            UPDATE turns SET status = 'failed_unknown', endedAt = ?1,
                             error = COALESCE(error, 'interrupted: outcome unknown')
            WHERE status = 'running'
          """,
          [now]
        )

        if sessions_exist? do
          for seq <- seqs,
              episode = probe_episode(txn, seq),
              do: rehold_probe(txn, seq, now, episode)
        end

        seqs
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

  @doc "Count queued or running turns for a session."
  @spec pending_count(db(), String.t()) :: non_neg_integer()
  def pending_count(db \\ Tightbeam.DB, session_key) do
    {:ok, [[count]]} =
      DB.query(
        db,
        "SELECT count(*) FROM turns WHERE sessionKey = ?1 AND status IN ('queued','running')",
        [session_key]
      )

    count
  end

  @doc """
  Is a turn RUNNING for this session — started and not yet terminal?

  `claim_next/3` sets `status = 'running'` and `startedAt` in one UPDATE, so this
  single predicate IS that conjunction, and it is the same line the smoke's
  isolation check reads (`Tightbeam.ClientE2E.Substrate.running_by_session/1`).
  Deliberately not `pending_count/2`, which counts queued turns too.
  """
  @spec running?(db(), String.t()) :: boolean()
  def running?(db \\ Tightbeam.DB, session_key) do
    {:ok, [[count]]} =
      DB.query(
        db,
        "SELECT count(*) FROM turns WHERE sessionKey = ?1 AND status = 'running'",
        [session_key]
      )

    count > 0
  end

  @doc "Newest terminal turn sequence for a session, or nil."
  @spec last_terminal_seq(db(), String.t()) :: integer() | nil
  def last_terminal_seq(db \\ Tightbeam.DB, session_key) do
    {:ok, [[seq]]} =
      DB.query(
        db,
        "SELECT max(seq) FROM turns WHERE sessionKey = ?1 AND status IN ('delivered','canceled','failed','failed_unknown')",
        [session_key]
      )

    seq
  end

  @doc """
  The `messages.id` of a session's running turn, or nil when none is running.

  The lane serializes a session to at most one running turn, so there is never a
  choice to make here. What this is NOT is proof that the running turn fired the
  caller: the request carries no turn identity, so this is CONCURRENCY in exactly
  the sense core-causality-fixes-v1 §C1 names — a separate request on the same
  session token while a turn runs reads that turn, and a request arriving after a
  cancel (which terminalizes before the kill) reads none. Callers record the
  answer under a label that says so.
  """
  @spec running_turn_message_id(db(), String.t()) :: String.t() | nil
  def running_turn_message_id(db \\ Tightbeam.DB, session_key) do
    {:ok, rows} =
      DB.query(
        db,
        "SELECT messageId FROM turns WHERE sessionKey = ?1 AND status = 'running' LIMIT 1",
        [session_key]
      )

    case rows do
      [[message_id]] -> message_id
      [] -> nil
    end
  end

  @doc "Terminal rows not yet published (at-least-once publication feed)."
  @spec unpublished_terminals(db()) :: [map()]
  def unpublished_terminals(db \\ Tightbeam.DB) do
    {:ok, rows} =
      DB.query(db, """
        SELECT seq, sessionKey, messageId, status, error FROM turns
        WHERE endedAt IS NOT NULL AND publishedAt IS NULL ORDER BY seq
      """)

    Enum.map(rows, fn [seq, sk, mid, status, error] ->
      %{seq: seq, session_key: sk, message_id: mid, status: status, error: error}
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
    {:ok, _} =
      DB.query(db, "UPDATE turns SET adapterGen = ?2 WHERE seq = ?1 AND status = 'running'", [
        seq,
        generation
      ])

    :ok
  end

  @doc "Newest adapter generation stamped by an earlier turn in the session, or nil."
  @spec prior_adapter_generation(db(), String.t(), integer()) :: non_neg_integer() | nil
  def prior_adapter_generation(db \\ Tightbeam.DB, session_key, before_seq) do
    {:ok, rows} =
      DB.query(
        db,
        """
          SELECT adapterGen FROM turns
          WHERE sessionKey = ?1 AND seq < ?2 AND adapterGen IS NOT NULL
          ORDER BY seq DESC LIMIT 1
        """,
        [session_key, before_seq]
      )

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
      DB.query(
        db,
        """
          SELECT seq FROM turns
          WHERE status IN ('queued','running') AND createdAt < ?1
        """,
        [cutoff]
      )

    Enum.map(rows, fn [seq] -> seq end)
  end
end
