defmodule Tightbeam.CausalEvents do
  @moduledoc """
  Append-only record of the transitions an in-place overwrite destroys
  (spec job-forensics-v2 §2).

  Law 0: every row here is a substrate side effect. No agent authors one.

  NECESSITY RULE (binding — this table is not a log): a kind is admitted ONLY if
  its fact is destroyed by an overwrite or has no timestamped home. The
  per-kind audit that admitted the six below:

  - `adjudication_reopen` — `Adjudication.reopen_in_txn/4` overwrites status,
    correlationKey, openedAt and resolvedAt in place. Nothing else records that
    a resolved episode reopened.
  - `adjudication_escalate` — `escalate_due/2` overwrites status, ownerTarget,
    ownerWakeId, reresolveRung and deadlineAt in place. The rung/target
    progression is PARTIALLY recoverable (each owner wake row carries
    reresolveRung, its target sessionKey and createdAt, joinable via the
    idempotency row), but the STATE transition and its binding to the episode
    are not — so the kind stays, and the wake rows corroborate it.
  - `effort_rung_advance` — `EffortCheckin.deadline_in_txn/3` overwrites
    expecterSessionKey, expecterUserId and lineageRung on the request row. The
    replacement deadline wake carries no rung (it is scheduled without
    `reresolve_rung`), so the prior rung has no other home.
  - `prod_fired` — `assignment_prods.prodCount` is a mutable aggregate that
    RESETS on attest, and the tier that fired lives only in
    `supervision_watermarks.pendingK`, overwritten each evaluation. The
    delivered turn is durable but carries no tier.
  - `prod_answered` — `assignment_prods.attestCount` is a bare COUNT, so which
    attest answered the prods is unrecoverable. There is no id watermark
    anywhere; this table is therefore its own watermark (see
    `unseen_attest_ids_in_txn/2`).
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

  @kinds ~w(adjudication_reopen adjudication_escalate effort_rung_advance
            prod_fired prod_answered disposition_transition)

  @ddl """
  CREATE TABLE IF NOT EXISTS causal_events (
    seq          INTEGER PRIMARY KEY AUTOINCREMENT,
    at           INTEGER NOT NULL,
    jobRef       TEXT,
    assignmentId TEXT,
    sessionKey   TEXT,
    kind         TEXT NOT NULL CHECK (kind IN
      ('adjudication_reopen','adjudication_escalate','effort_rung_advance',
       'prod_fired','prod_answered','disposition_transition')),
    detail       TEXT NOT NULL
  );
  CREATE INDEX IF NOT EXISTS causal_events_job ON causal_events (jobRef, seq);
  CREATE INDEX IF NOT EXISTS causal_events_assignment
    ON causal_events (assignmentId, seq);
  """

  @spec ensure_schema(DB.server()) :: :ok | {:error, term()}
  def ensure_schema(db \\ DB), do: DB.execute(db, @ddl)

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
  The attest ids that answered a prod round, ordered by attest id.

  `arrived` is how many attests appeared since the last evaluation
  (`attestCount` is a bare count — the only watermark the schema carries). Only
  that many are considered, taken NEWEST-first by rowid, because attests are
  append-only: the newest `arrived` rows ARE the new ones. Bounding the window
  this way is what keeps pre-v2 history out — scanning the whole attest history
  would give every historical attest an event the first time a new one landed
  after migration, which the spec forbids outright (cross-review F5).

  Within the window, ids already named by a `prod_answered` event are dropped, so
  a re-run of the same evaluation adds nothing.
  """
  @spec unseen_attest_ids_in_txn(Txn.t(), String.t(), non_neg_integer()) :: [String.t()]
  def unseen_attest_ids_in_txn(_txn, _assignment_id, arrived) when arrived <= 0, do: []

  def unseen_attest_ids_in_txn(%Txn{} = txn, assignment_id, arrived) do
    txn
    |> Txn.q(
      """
      SELECT a.id FROM (
        SELECT id, rowid FROM attests
        WHERE assignmentId = ?1
        ORDER BY rowid DESC
        LIMIT ?2
      ) AS a
      WHERE NOT EXISTS (
        SELECT 1 FROM causal_events AS c
        WHERE c.kind = 'prod_answered' AND c.assignmentId = ?1
          AND json_extract(c.detail, '$.byAttestId') = a.id
      )
      ORDER BY a.id ASC
      """,
      [assignment_id, arrived]
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
