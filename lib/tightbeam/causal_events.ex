defmodule Tightbeam.CausalEvents do
  @moduledoc """
  Append-only record of the transitions an in-place overwrite destroys
  (spec job-forensics-v2 §2).

  Law 0: every row here is a substrate side effect. No agent authors one.

  NECESSITY RULE (binding — this table is not a log): a kind is admitted ONLY if
  its fact is destroyed by an overwrite or has no timestamped home. The
  per-kind audit that admitted each kind below:
  - `effort_rung_advance` — `EffortCheckin.deadline_in_txn/3` overwrites
    expecterSessionKey, expecterUserId and lineageRung on the request row. The
    replacement deadline wake carries no rung (it is scheduled without
    `reresolve_rung`), so the prior rung has no other home.
  - `prod_fired` — `assignment_prods.prodCount` is a mutable aggregate that
    resets on a typed liveness receipt, and the tier that fired lives only in
    `supervision_watermarks.pendingK`, overwritten each evaluation. The
    delivered turn is durable but carries no tier.
  - `prod_answered` — a legacy kind retained for existing rows. New writers do
    not emit it: `supervision_liveness_receipts` now records the exact typed
    source that reset a prod, and progress prose is not an answer.
  - `disposition_transition` — `work_items.state` is overwritten and
    `failReason` is nulled on reopen. `work_item_events` is a bare DOORBELL
    (kind is only 'metadata' or 'composition'); it says something changed, never
    from what to what.

  Deliberately EXCLUDED, per v1's audited list: wake schedule/fire (durable on
  the wake row) and bracket nags (durable as wake-backed turns).

  Every append rides IN the transaction of the write it records — they commit
  together or not at all.
  """

  alias Tightbeam.DB
  alias Tightbeam.DB.Txn

  @kinds ~w(effort_rung_advance prod_fired prod_answered disposition_transition)

  # The v2-EPOCH CUTOFF: when causal_events first came into existence. Attests
  # filed before it are pre-v2 history that this table was never going to record,
  # and the spec forbids retroactively emitting events for them (cross-review F5).
  # One row, written only at first creation, so it is stable across every later boot.
  @epoch_ddl """
  CREATE TABLE IF NOT EXISTS causal_events_epoch (
    id INTEGER PRIMARY KEY CHECK (id = 0),
    at INTEGER NOT NULL
  );
  """

  @ddl """
  CREATE TABLE IF NOT EXISTS causal_events (
    seq          INTEGER PRIMARY KEY AUTOINCREMENT,
    at           INTEGER NOT NULL,
    jobRef       TEXT,
    assignmentId TEXT,
    sessionKey   TEXT,
    kind         TEXT NOT NULL CHECK (kind IN
      ('effort_rung_advance','prod_fired','prod_answered',
       'disposition_transition')),
    detail       TEXT NOT NULL
  );
  CREATE INDEX IF NOT EXISTS causal_events_job ON causal_events (jobRef, seq);
  CREATE INDEX IF NOT EXISTS causal_events_assignment
    ON causal_events (assignmentId, seq);
  """

  @spec ensure_schema(DB.server()) :: :ok | {:error, term()}
  def ensure_schema(db \\ DB) do
    :ok = DB.execute(db, @ddl)
    :ok = DB.execute(db, @epoch_ddl)

    # INSERT OR IGNORE, so the cutoff is stamped once — at the migration that
    # created the table — and never moved by a later boot.
    {:ok, _} =
      DB.query(db, "INSERT OR IGNORE INTO causal_events_epoch (id, at) VALUES (0, ?1)", [
        System.system_time(:millisecond)
      ])

    :ok
  end

  @doc "When causal_events came into existence; attests older than this are pre-v2."
  @spec epoch(DB.server()) :: integer()
  def epoch(db \\ DB) do
    {:ok, [[at]]} = DB.query(db, "SELECT at FROM causal_events_epoch WHERE id = 0")
    at
  end

  @doc "The admitted kinds, in the order the spec lists them."
  @spec kinds() :: [String.t()]
  def kinds, do: @kinds

  @doc """
  Append one transition inside the caller's transaction. `attrs` needs `:kind`
  and `:detail`; `:job_ref`, `:assignment_id` and `:session_key` are the
  attribution columns and are nullable (NULL = genuinely unattributed).
  """
  @spec append_in_txn(Txn.t(), map()) :: :ok
  def append_in_txn(%Txn{} = txn, attrs) do
    kind = Map.fetch!(attrs, :kind)
    true = kind in @kinds

    Txn.q(
      txn,
      """
      INSERT INTO causal_events (at, jobRef, assignmentId, sessionKey, kind, detail)
      VALUES (?1, ?2, ?3, ?4, ?5, ?6)
      """,
      [
        Map.get(attrs, :at) || System.system_time(:millisecond),
        Map.get(attrs, :job_ref),
        Map.get(attrs, :assignment_id),
        Map.get(attrs, :session_key),
        kind,
        JSON.encode!(Map.fetch!(attrs, :detail))
      ]
    )

    :ok
  end

  @doc """
  Legacy resolver for attest ids recorded by the retired `prod_answered` writer.

  BOUNDED to attests filed at/after the v2-epoch cutoff — the moment
  causal_events was created. Scanning an assignment's whole attest history would
  make the FIRST post-migration attest retroactively emit an event for every
  historical one, which the spec forbids outright (cross-review F5). A hard
  timestamp floor is the bound rather than "how many arrived since the last
  evaluation", because `attestCount` is a mutable aggregate and cannot be trusted
  to fence pre-v2 rows.

  Within the window, ids already named by a `prod_answered` event are dropped, so
  several attests arriving between two evaluations each get exactly one event and
  a re-run of the same evaluation adds nothing.
  """
  @spec unseen_attest_ids_in_txn(Txn.t(), String.t()) :: [String.t()]
  def unseen_attest_ids_in_txn(%Txn{} = txn, assignment_id) do
    [[cutoff]] = Txn.q(txn, "SELECT at FROM causal_events_epoch WHERE id = 0")

    txn
    |> Txn.q(
      """
      SELECT a.id FROM attests AS a
      WHERE a.assignmentId = ?1
        AND a.ts >= ?2
        AND NOT EXISTS (
          SELECT 1 FROM causal_events AS c
          WHERE c.kind = 'prod_answered' AND c.assignmentId = ?1
            AND json_extract(c.detail, '$.byAttestId') = a.id
        )
      ORDER BY a.id ASC
      """,
      [assignment_id, cutoff]
    )
    |> Enum.map(&hd/1)
  end

  @doc "Every event for a job, oldest first — the trace verb's feed."
  @spec for_job(DB.server(), String.t(), [String.t()]) :: [map()]
  def for_job(db \\ DB, job_ref, assignment_ids) do
    {clause, params} =
      assignment_ids
      |> Enum.with_index(2)
      |> Enum.map_reduce([], fn {id, index}, acc -> {"?#{index}", acc ++ [id]} end)

    assignment_clause =
      case clause do
        [] -> ""
        placeholders -> " OR assignmentId IN (#{Enum.join(placeholders, ", ")})"
      end

    {:ok, rows} =
      DB.query(
        db,
        """
        SELECT seq, at, jobRef, assignmentId, sessionKey, kind, detail
        FROM causal_events
        WHERE jobRef = ?1#{assignment_clause}
        ORDER BY seq ASC
        """,
        [job_ref | params]
      )

    Enum.map(rows, fn [seq, at, job_ref, assignment_id, session_key, kind, detail] ->
      %{
        seq: seq,
        at: at,
        job_ref: job_ref,
        assignment_id: assignment_id,
        session_key: session_key,
        kind: kind,
        detail: JSON.decode!(detail)
      }
    end)
  end
end
