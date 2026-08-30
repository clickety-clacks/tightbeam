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

  alias Tightbeam.{DB, HarnessHealth, Org, TurnLifecycle}
  alias Tightbeam.DB.Txn
  alias Tightbeam.Firehose.Publisher

  require Logger

  @typedoc "A queued/claimed turn as returned by claim_next/3."
  @type turn :: %{
          seq: integer(),
          message_id: String.t(),
          origin: String.t(),
          prompt: String.t(),
          wake_id: String.t() | nil,
          owner_lease: String.t()
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
    thinkingLevel TEXT,
    modelContext  TEXT,
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
  CREATE INDEX IF NOT EXISTS turns_job_ref ON turns (jobRef);
  CREATE INDEX IF NOT EXISTS turns_assignment_id ON turns (assignmentId);

  CREATE TABLE IF NOT EXISTS turn_repair_attempts (
    id            TEXT PRIMARY KEY,
    repairKey     TEXT NOT NULL,
    sourceSeq     INTEGER NOT NULL REFERENCES turns(seq),
    attemptSeq    INTEGER NOT NULL UNIQUE REFERENCES turns(seq),
    assignmentId TEXT NOT NULL REFERENCES assignments(id),
    principal     TEXT NOT NULL CHECK(length(trim(principal)) > 0),
    createdAt     INTEGER NOT NULL CHECK(createdAt >= 0),
    UNIQUE (assignmentId, repairKey)
  );
  CREATE INDEX IF NOT EXISTS turn_repair_source
    ON turn_repair_attempts (sourceSeq, createdAt, id);

  CREATE TABLE IF NOT EXISTS assignment_repair_attempts (
    id                 TEXT PRIMARY KEY,
    assignmentId       TEXT NOT NULL REFERENCES assignments(id),
    repairKey          TEXT NOT NULL,
    requestFingerprint TEXT NOT NULL CHECK(length(trim(requestFingerprint)) > 0),
    action             TEXT NOT NULL CHECK(action IN
                       ('tune','restart','rerun','resume','relaunch')),
    principal          TEXT NOT NULL CHECK(length(trim(principal)) > 0),
    state              TEXT NOT NULL CHECK(state IN ('claimed','succeeded','failed')),
    resultJson         TEXT,
    createdAt          INTEGER NOT NULL CHECK(createdAt >= 0),
    completedAt        INTEGER,
    UNIQUE (assignmentId, repairKey),
    CHECK(
      (state = 'claimed' AND resultJson IS NULL AND completedAt IS NULL)
      OR
      (state IN ('succeeded','failed') AND resultJson IS NOT NULL AND completedAt >= createdAt)
    )
  );
  CREATE INDEX IF NOT EXISTS assignment_repair_history
    ON assignment_repair_attempts (assignmentId, createdAt, id);
  """

  @spec ensure_schema(db()) :: :ok | {:error, term()}
  def ensure_schema(db \\ Tightbeam.DB) do
    with :ok <- DB.execute(db, @ddl), do: TurnLifecycle.ensure_schema(db)
  end

  @doc """
  Transactionally enqueue a turn (call inside the same DB.transaction that
  persists the message row, so message+turn commit together).

  Refuses, as a VALUE, a turn addressed to a sessionKey with NO ROW. Such a key
  is composed, never read — `Org.personal_session_key/1` builds one from a user
  id — and a turn addressed to one is work nobody can ever claim: the prompt is
  lost while the ledger reports it pending. The refusal is a value and not a
  raise deliberately: the caller's transaction carries other committed effects
  (a wake's `fired` mark, an episode transition), and rolling those back would
  re-deliver the same undeliverable notice forever.

  Existence, deliberately, and not `state = 'active'`: a `targetGate = 0`
  decision notice delivers to a HELD OR RETIRED target by design and an
  active-session gate here is forbidden (spec escalation-delivery-v1). A retired
  target's turn is still unclaimable, and `claim_next/3` names it rather than
  this write refusing routing that a live spec requires.

  Raises on wakeId conflict (caller treats as already-enqueued).
  """
  @spec enqueue_in_txn(Txn.t(), map()) :: {:ok, integer()} | {:error, :no_session}
  def enqueue_in_txn(%Txn{} = txn, attrs) do
    now = System.system_time(:millisecond)
    session_key = Map.fetch!(attrs, :session_key)

    if session_exists_in_txn?(txn, session_key) do
      Txn.q(
        txn,
        """
          INSERT INTO turns
            (sessionKey, messageId, wakeId, origin, prompt, roleRef, roleFallback,
             assignmentId, jobRef, requestRef, createdAt)
          VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11)
        """,
        [
          session_key,
          Map.fetch!(attrs, :message_id),
          Map.get(attrs, :wake_id),
          Map.fetch!(attrs, :origin),
          Map.fetch!(attrs, :prompt),
          Map.get(attrs, :role_ref),
          if(Map.get(attrs, :role_fallback, false), do: 1, else: 0),
          Map.get(attrs, :assignment_id),
          Map.get(attrs, :job_ref),
          Map.get(attrs, :request_ref),
          now
        ]
      )

      [[seq]] = Txn.q(txn, "SELECT last_insert_rowid()")
      principal = TurnLifecycle.principal(Map.get(attrs, :principal, Map.fetch!(attrs, :origin)))

      detail =
        %{
          v: 1,
          origin: Map.fetch!(attrs, :origin),
          wakeId: Map.get(attrs, :wake_id),
          clientMessageId: Map.get(attrs, :client_message_id),
          authenticatedCaller: principal
        }
        |> Enum.reject(fn {_key, value} -> is_nil(value) end)
        |> Map.new()

      TurnLifecycle.append_in_txn(txn, seq, %{
        event_key: "accepted",
        producer_event_id: "ledger:accepted",
        kind: "accepted",
        cause:
          if(Map.get(attrs, :wake_id),
            do: "wake:#{Map.fetch!(attrs, :wake_id)}",
            else:
              "client-message:#{Map.get(attrs, :client_message_id, Map.fetch!(attrs, :message_id))}"
          ),
        principal: principal,
        detail: detail,
        at: now
      })

      Org.sync_mechanical_status_in_txn(txn, session_key)

      {:ok, seq}
    else
      {:error, :no_session}
    end
  end

  @doc """
  Would `enqueue_in_txn/2` accept a turn for this key? The SAME question the
  guard asks, so a caller with work to do BEFORE the enqueue (the projection
  echo, which commits in the same transaction and cannot be taken back) can
  decline without duplicating the rule or provoking a rollback.
  """
  @spec enqueueable_in_txn?(Txn.t(), String.t()) :: boolean()
  def enqueueable_in_txn?(%Txn{} = txn, session_key),
    do: session_exists_in_txn?(txn, session_key)

  defp session_exists_in_txn?(%Txn{} = txn, session_key) do
    Txn.q(txn, "SELECT 1 FROM sessions WHERE sessionKey = ?1", [session_key]) != []
  end

  @doc "Convenience: enqueue outside an existing transaction."
  @spec enqueue(db(), map()) ::
          {:ok, integer()} | {:error, :duplicate_wake | :no_session | term()}
  def enqueue(db \\ Tightbeam.DB, attrs) do
    case DB.transaction(db, fn txn -> enqueue_in_txn(txn, attrs) end) do
      {:ok, {:ok, seq}} ->
        {:ok, seq}

      {:ok, {:error, reason}} ->
        {:error, reason}

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
  Claim one assignment repair before any external side effect.

  The assignment scopes the caller key. An exact replay returns the persisted
  terminal result; a conflicting request is refused, and an interrupted claim
  remains claimed so recovery never repeats an outcome-unknown side effect.
  """
  @spec begin_assignment_repair(
          db(),
          String.t(),
          String.t(),
          String.t(),
          String.t(),
          String.t()
        ) ::
          {:ok, {:claimed, String.t()} | {:replay, map()} | {:in_progress, String.t()}}
          | {:error, :repair_key_conflict | term()}
  def begin_assignment_repair(
        db \\ Tightbeam.DB,
        assignment_id,
        repair_key,
        request_fingerprint,
        action,
        principal
      ) do
    case DB.transaction(db, fn txn ->
           case Txn.q(
                  txn,
                  """
                  SELECT id,requestFingerprint,state,resultJson
                  FROM assignment_repair_attempts
                  WHERE assignmentId=?1 AND repairKey=?2
                  """,
                  [assignment_id, repair_key]
                ) do
             [[id, ^request_fingerprint, "claimed", nil]] ->
               {:in_progress, id}

             [[_id, ^request_fingerprint, state, result_json]]
             when state in ["succeeded", "failed"] and is_binary(result_json) ->
               {:replay, decode_repair_result(result_json)}

             [[_id, _other_fingerprint, _state, _result_json]] ->
               {:error, :repair_key_conflict}

             [] ->
               id = "ara_" <> Tightbeam.Id.uuid4()

               Txn.q(
                 txn,
                 """
                 INSERT INTO assignment_repair_attempts
                   (id,assignmentId,repairKey,requestFingerprint,action,principal,state,createdAt)
                 VALUES (?1,?2,?3,?4,?5,?6,'claimed',?7)
                 """,
                 [
                   id,
                   assignment_id,
                   repair_key,
                   request_fingerprint,
                   action,
                   principal,
                   System.system_time(:millisecond)
                 ]
               )

               {:claimed, id}
           end
         end) do
      {:ok, {:error, reason}} -> {:error, reason}
      {:ok, result} -> {:ok, result}
      {:error, error} -> {:error, error}
    end
  end

  @doc "Persist the terminal repair result that every exact replay returns."
  @spec finish_assignment_repair(db(), String.t(), map()) :: :ok | {:error, term()}
  def finish_assignment_repair(db \\ Tightbeam.DB, attempt_id, result) when is_map(result) do
    state = if result[:ok] == true, do: "succeeded", else: "failed"
    result_json = JSON.encode!(result)

    case DB.transaction(db, fn txn ->
           Txn.q(
             txn,
             """
             UPDATE assignment_repair_attempts
             SET state=?2,resultJson=?3,completedAt=?4
             WHERE id=?1 AND state='claimed'
             """,
             [attempt_id, state, result_json, System.system_time(:millisecond)]
           )

           if Txn.changes(txn) == 1, do: :ok, else: {:error, :repair_attempt_not_claimed}
         end) do
      {:ok, :ok} -> :ok
      {:ok, {:error, reason}} -> {:error, reason}
      {:error, error} -> {:error, error}
    end
  end

  defp decode_repair_result(result_json) do
    result_json
    |> JSON.decode!()
    |> Map.new(fn {key, value} -> {String.to_existing_atom(key), value} end)
  end

  @doc """
  Append one explicit retry attempt for a terminal failed turn.

  The terminal source row remains immutable. The new queued row carries the
  same prompt, assignment, work-item reference, and visible message identity;
  `turn_repair_attempts` gives the attempt its own durable identity and makes a
  caller-supplied repair key replay-safe.
  """
  @spec repair_terminal(db(), integer(), String.t(), String.t(), String.t()) ::
          {:ok, {:appended | :duplicate, integer(), String.t()}} | {:error, atom() | term()}
  def repair_terminal(db \\ Tightbeam.DB, source_seq, assignment_id, repair_key, principal) do
    case DB.transaction(db, fn txn ->
           case Txn.q(
                  txn,
                  """
                  SELECT attemptSeq,id FROM turn_repair_attempts
                  WHERE assignmentId=?1 AND repairKey=?2
                  """,
                  [assignment_id, repair_key]
                ) do
             [[attempt_seq, attempt_id]] ->
               {:duplicate, attempt_seq, attempt_id}

             [] ->
               append_repair_attempt(txn, source_seq, assignment_id, repair_key, principal)
           end
         end) do
      {:ok, {:error, reason}} -> {:error, reason}
      {:ok, result} -> {:ok, result}
      {:error, error} -> {:error, error}
    end
  end

  defp append_repair_attempt(txn, source_seq, assignment_id, repair_key, principal) do
    case Txn.q(
           txn,
           """
           SELECT sessionKey,messageId,origin,prompt,roleRef,roleFallback,assignmentId,jobRef
           FROM turns
           WHERE seq=?1 AND assignmentId=?2 AND status IN ('failed','failed_unknown')
           """,
           [source_seq, assignment_id]
         ) do
      [
        [
          session_key,
          message_id,
          origin,
          prompt,
          role_ref,
          role_fallback,
          ^assignment_id,
          job_ref
        ]
      ] ->
        {:ok, attempt_seq} =
          enqueue_in_txn(txn, %{
            session_key: session_key,
            message_id: message_id,
            origin: origin,
            prompt: prompt,
            role_ref: role_ref,
            role_fallback: role_fallback == 1,
            assignment_id: assignment_id,
            job_ref: job_ref,
            request_ref: repair_key,
            principal: principal
          })

        attempt_id = "tra_" <> Tightbeam.Id.uuid4()

        Txn.q(
          txn,
          """
          INSERT INTO turn_repair_attempts
            (id,repairKey,sourceSeq,attemptSeq,assignmentId,principal,createdAt)
          VALUES (?1,?2,?3,?4,?5,?6,?7)
          """,
          [
            attempt_id,
            repair_key,
            source_seq,
            attempt_seq,
            assignment_id,
            principal,
            System.system_time(:millisecond)
          ]
        )

        {:appended, attempt_seq, attempt_id}

      [] ->
        {:error, :terminal_turn_not_found}
    end
  end

  @typedoc """
  Why queued work exists that no claim can ever reach.
  """
  @type unclaimable :: :no_session | :session_retired

  @doc """
  Claim the next queued turn for a session — refuses if one is running
  (one-turn-per-session in SQL). Returns {:ok, %{seq:, prompt:, ...}}, :busy,
  :none, or {:unclaimable, reason}.

  `:none` is the EMPTY answer only. "Queued work that no claim can ever reach"
  is a different fact and gets its own answer: while the two shared `:none`, six
  orphaned turns were indistinguishable from an idle queue for hours.
  """
  @spec claim_next(db(), String.t(), String.t()) ::
          {:ok, turn()} | :busy | :none | {:unclaimable, unclaimable()}
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
            selected_mind =
              case Txn.q(
                     txn,
                     """
                     SELECT model, thinkingLevel, modelContext, harness
                     FROM sessions WHERE sessionKey = ?1
                     """,
                     [session_key]
                   ) do
                [[model, effort, context, harness]] -> {model, effort, context, harness}
                [] -> {nil, nil, nil, nil}
              end

            Txn.q(
              txn,
              """
                UPDATE turns
                SET status = 'running', owner = ?2, startedAt = ?3,
                    model = ?4, harness = ?5, thinkingLevel = ?6, modelContext = ?7
                WHERE seq = (SELECT t.seq FROM turns AS t
                             WHERE t.sessionKey = ?1 AND t.status = 'queued'
                               AND EXISTS (
                                 SELECT 1 FROM sessions AS s
                                 WHERE s.sessionKey = t.sessionKey AND s.state = 'active'
                               )
                             ORDER BY seq LIMIT 1)
                  AND status = 'queued'
              """,
              [
                session_key,
                owner,
                now,
                elem(selected_mind, 0),
                elem(selected_mind, 3),
                elem(selected_mind, 1),
                elem(selected_mind, 2)
              ]
            )

            if Txn.changes(txn) == 1 do
              owner_lease = owner_lease()

              [[seq, message_id, origin, prompt, wake_id]] =
                Txn.q(
                  txn,
                  """
                    SELECT seq, messageId, origin, prompt, wakeId FROM turns
                    WHERE sessionKey = ?1 AND status = 'running'
                  """,
                  [session_key]
                )

              TurnLifecycle.append_in_txn(txn, seq, %{
                event_key: "claimed",
                producer_event_id: "ledger:claimed",
                kind: "claimed",
                cause: "session-lane:claim",
                principal: "process:tightbeam",
                owner_lease: owner_lease,
                detail: %{v: 1, owner: owner},
                at: now
              })

              Publisher.turn_in_txn(txn, "turn.started", seq)
              Org.sync_mechanical_status_in_txn(txn, session_key)

              {:ok,
               %{
                 seq: seq,
                 message_id: message_id,
                 origin: origin,
                 prompt: prompt,
                 wake_id: wake_id,
                 owner_lease: owner_lease
               }}
            else
              no_claim(txn, session_key)
            end
        end
      end)

    result
  end

  # Nothing moved. Either the queue is empty, or it holds work whose session
  # cannot host a turn — the same read the claim UPDATE's EXISTS clause makes,
  # asked as a question instead of collapsed into a nil result.
  defp no_claim(%Txn{} = txn, session_key) do
    queued? =
      Txn.q(txn, "SELECT 1 FROM turns WHERE sessionKey = ?1 AND status = 'queued' LIMIT 1", [
        session_key
      ]) != []

    if queued? do
      case Txn.q(txn, "SELECT state FROM sessions WHERE sessionKey = ?1", [session_key]) do
        [] ->
          {:unclaimable, :no_session}

        [["retired"]] ->
          {:unclaimable, :session_retired}

        # UNREACHABLE BY CONSTRUCTION since adjudication was deleted. The claim
        # UPDATE's only session predicate is `state = 'active'`, so an active
        # session with queued work and no running row must have matched it in
        # this same transaction. The hold used to make this arm ordinary
        # ("designed waiting, healed by the ruling"); nothing does now.
        #
        # It stays `:none` rather than raising because a lane must not crash on
        # a queue read, but it must not be SILENT either: reaching here means
        # the claim UPDATE and this read disagree inside one transaction, and
        # reporting that as a plain empty queue is the same collapse the
        # `:unclaimable` split above exists to prevent.
        [[state]] ->
          Logger.error(
            "claim_next: #{session_key} is #{state} with queued work that the claim " <>
              "UPDATE did not match, in one transaction — reporting :none, but this " <>
              "is an invariant violation, not an idle queue"
          )

          :none
      end
    else
      :none
    end
  end

  @doc """
  Age a session's queued turns into `failed` under a named cause — the backstop
  for work no claim can ever reach. Returns the seqs transitioned; they carry
  `endedAt` with no `publishedAt`, so the reconciler's existing
  `unpublished_terminals/1` feed publishes them like any other terminal.

  The CAUSE is a predicate of the UPDATE, not a fact sampled beforehand. The
  diagnosis in `claim_next/3` and the failure here are separate transactions, so
  a session created in between would otherwise see its now-claimable turn forced
  to `failed` on the strength of a reading that had already expired. Deciding
  and acting in one statement is what makes that window unrepresentable.

  The seqs come from `RETURNING` for the same reason. Re-reading them afterwards
  identifies rows by the error string this function itself wrote, so a session
  aged twice reports its first batch again as newly aged — the statement that
  did the work is the only thing that knows what it did.
  """
  @spec fail_unclaimable(db(), String.t(), unclaimable()) :: [integer()]
  def fail_unclaimable(db \\ Tightbeam.DB, session_key, reason) do
    {:ok, seqs} =
      DB.transaction(db, fn txn ->
        seqs =
          txn
          |> Txn.q(
            """
            UPDATE turns SET status = 'failed', endedAt = ?2, error = ?3
            WHERE sessionKey = ?1 AND status = 'queued'
              AND NOT EXISTS (
                SELECT 1 FROM sessions AS s
                WHERE s.sessionKey = ?1 AND s.state = 'active'
              )
            RETURNING seq
            """,
            [session_key, System.system_time(:millisecond), unclaimable_error(reason)]
          )
          |> Enum.map(&hd/1)
          |> Enum.sort()

        Enum.each(seqs, fn seq ->
          TurnLifecycle.append_in_txn(
            txn,
            seq,
            terminal_event(seq, "failed", %{
              cause: "unclaimable:#{reason}",
              principal: "process:tightbeam"
            })
          )
        end)

        Enum.each(seqs, &Publisher.turn_in_txn(txn, "turn.ended", &1))
        if seqs != [], do: Org.sync_mechanical_status_in_txn(txn, session_key)
        seqs
      end)

    seqs
  end

  defp unclaimable_error(:no_session),
    do: "unclaimable: no session row exists for this turn's sessionKey"

  defp unclaimable_error(:session_retired),
    do: "unclaimable: the session retired before this turn was claimed"

  @doc """
  Exactly-one durable terminal transition (CAS). Returns :ok if this caller
  won the transition, :already_terminal otherwise.
  """
  @spec finish(db(), integer(), terminal(), String.t() | nil, keyword()) ::
          :ok
          | :already_terminal
          | {:error, {:turn_lifecycle_write_rejected, atom()}}
  def finish(db \\ Tightbeam.DB, seq, terminal, error \\ nil, opts \\ [])
      when terminal in ~w(delivered canceled failed failed_unknown) do
    case DB.transaction(db, fn txn ->
           finish_in_txn(txn, seq, terminal, error, opts)
         end) do
      {:ok, true} ->
        :ok

      {:ok, false} ->
        :already_terminal

      {:error, %TurnLifecycle.WriteError{code: code}} ->
        {:error, {:turn_lifecycle_write_rejected, code}}
    end
  end

  @doc "Terminal transition inside the caller's transaction."
  @spec finish_in_txn(Txn.t(), integer(), terminal(), String.t() | nil, keyword()) :: boolean()
  def finish_in_txn(%Txn{} = txn, seq, terminal, error \\ nil, opts \\ [])
      when terminal in ~w(delivered canceled failed failed_unknown) do
    now = System.system_time(:millisecond)
    opts = Map.new(opts)

    Txn.q(
      txn,
      "UPDATE turns SET status = ?2, endedAt = ?3, error = ?4 WHERE seq = ?1 AND status = 'running'",
      [seq, terminal, now, error]
    )

    won = Txn.changes(txn) == 1

    if won do
      TurnLifecycle.append_in_txn(
        txn,
        seq,
        terminal_event(seq, terminal, opts) |> Map.put(:at, now)
      )

      Publisher.turn_in_txn(txn, "turn.ended", seq)

      [[session_key]] = Txn.q(txn, "SELECT sessionKey FROM turns WHERE seq = ?1", [seq])
      Org.sync_mechanical_status_in_txn(txn, session_key)
    end

    won
  end

  @doc """
  Cancel every queued turn when a session retires, inside the retire transaction.

  Invariant (newly minted): a retired session can never execute, so its queued
  turns are canceled, not failed; this is the single drain point for every retire.
  Setting endedAt routes each row through the existing terminal publication sweep.
  """
  @spec drain_queued_for_retire_in_txn(Txn.t(), String.t(), String.t(), keyword()) :: [integer()]
  def drain_queued_for_retire_in_txn(%Txn{} = txn, session_key, reason, opts \\ []) do
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

    seqs = Enum.map(rows, &hd/1)

    Enum.each(seqs, fn seq ->
      TurnLifecycle.append_in_txn(
        txn,
        seq,
        terminal_event(seq, "canceled", Map.new(opts))
      )
    end)

    Enum.each(seqs, &Publisher.turn_in_txn(txn, "turn.ended", &1))
    seqs
  end

  @doc """
  Boot/periodic recovery: every running turn has UNKNOWN outcome → terminal
  failed_unknown (never auto-retried; tools may have executed). Returns the
  seqs transitioned, for exactly-one terminal publication by the caller.
  """
  @spec recover_running(db()) :: [integer()]
  def recover_running(db \\ Tightbeam.DB) do
    now = System.system_time(:millisecond)

    {:ok, {seqs, publications}} =
      DB.transaction(db, fn txn ->
        rows = Txn.q(txn, "SELECT seq, sessionKey FROM turns WHERE status = 'running'")
        seqs = Enum.map(rows, fn [seq, _session_key] -> seq end)

        Txn.q(
          txn,
          """
            UPDATE turns SET status = 'failed_unknown', endedAt = ?1,
                             error = COALESCE(error, 'interrupted: outcome unknown')
            WHERE status = 'running'
          """,
          [now]
        )

        Enum.each(seqs, fn seq ->
          TurnLifecycle.append_in_txn(
            txn,
            seq,
            terminal_event(seq, "failed_unknown", %{
              cause: "boot-recovery",
              principal: "process:tightbeam"
            })
          )
        end)

        publications =
          Enum.map(seqs, fn seq ->
            HarnessHealth.observe_terminal_in_txn(
              txn,
              seq,
              "interrupted-outcome-unknown",
              "boot recovery interrupted the running turn; outcome unknown",
              "process:tightbeam"
            )
          end)

        Enum.each(seqs, &Publisher.turn_in_txn(txn, "turn.ended", &1))

        rows
        |> Enum.map(fn [_seq, session_key] -> session_key end)
        |> Enum.uniq()
        |> Enum.each(&Org.sync_mechanical_status_in_txn(txn, &1))

        {seqs, publications}
      end)

    Enum.each(publications, fn publication ->
      if is_function(publication, 0), do: publication.()
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
  `pending_count/2`, inside the caller's own transaction.

  The in-txn form matters, not just the query: `DB` is single-writer and
  serializes one `DB.transaction/2` call at a time, so a count taken as its
  OWN transaction (as `pending_count/2` does) can never rule out a prompt
  committing in the gap before the caller's next transaction opens. A count
  read inside the SAME transaction that goes on to perform the swap+barrier
  closes that gap: no other write (`deliver_prompt`'s echo+enqueue included)
  can land between this read and the writes that follow it, because none can
  run until this transaction commits (Sol xhigh review, live-switch finding 1).
  """
  @spec pending_count_in_txn(Txn.t(), String.t()) :: non_neg_integer()
  def pending_count_in_txn(%Txn{} = txn, session_key) do
    [[count]] =
      Txn.q(
        txn,
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

    {:ok, _} =
      DB.transaction(db, fn txn ->
        Txn.q(
          txn,
          "UPDATE turns SET publishedAt = ?2 WHERE seq = ?1 AND publishedAt IS NULL",
          [seq, now]
        )

        if Txn.changes(txn) == 1 do
          [[status]] = Txn.q(txn, "SELECT status FROM turns WHERE seq = ?1", [seq])

          TurnLifecycle.append_in_txn(txn, seq, %{
            event_key: "terminal:published",
            producer_event_id: "ledger:terminal:published",
            kind: "terminal_published",
            outcome: status,
            cause: "terminal-publisher",
            principal: "process:tightbeam",
            detail: %{v: 1, status: status},
            at: now
          })
        end
      end)

    :ok
  end

  @doc "Stamp the adapter generation selected for a running turn."
  @spec stamp_adapter(db(), integer(), non_neg_integer()) :: :ok
  def stamp_adapter(db, seq, generation) do
    {:ok, [[owner_lease]]} =
      DB.query(
        db,
        "SELECT ownerLease FROM turn_lifecycle_events WHERE turnSeq=?1 AND kind='claimed'",
        [seq]
      )

    stamp_adapter(db, seq, generation, owner_lease)
  end

  @spec stamp_adapter(db(), integer(), non_neg_integer(), String.t()) :: :ok
  def stamp_adapter(db, seq, generation, owner_lease) do
    {:ok, _} =
      DB.transaction(db, fn txn ->
        Txn.q(txn, "UPDATE turns SET adapterGen = ?2 WHERE seq = ?1 AND status = 'running'", [
          seq,
          generation
        ])

        if Txn.changes(txn) == 1 do
          TurnLifecycle.append_in_txn(txn, seq, %{
            event_key: "checkout:succeeded",
            producer_event_id: "gateway:checkout:succeeded",
            kind: "stage_succeeded",
            stage: "checkout",
            outcome: "succeeded",
            cause: "adapter-coordinator:checkout",
            principal: "process:tightbeam",
            owner_lease: owner_lease,
            adapter_gen: generation,
            detail: %{v: 1}
          })
        end
      end)

    :ok
  end

  defp terminal_event(seq, terminal, opts) do
    %{
      event_key: "terminal:committed",
      producer_event_id: "ledger:terminal:committed",
      kind: "terminal_committed",
      outcome: terminal,
      cause: Map.get(opts, :cause, "turn:#{seq}"),
      principal: Map.get(opts, :principal, "process:tightbeam"),
      owner_lease: Map.get(opts, :owner_lease),
      detail: %{v: 1, status: terminal}
    }
  end

  defp owner_lease do
    "ol_" <> (:crypto.strong_rand_bytes(24) |> Base.url_encode64(padding: false))
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
