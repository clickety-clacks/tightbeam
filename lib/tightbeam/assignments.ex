defmodule Tightbeam.Assignments do
  @moduledoc "Assignments and their attests."

  require Logger

  alias Tightbeam.DB
  alias Tightbeam.DB.Txn
  alias Tightbeam.Firehose.Publisher
  alias Tightbeam.Harness.Support

  alias Tightbeam.{
    EffortCheckin,
    EventLog,
    IdPrefix,
    Org,
    Placement,
    Projection,
    Supervision,
    Wakes
  }

  @effect_kinds ~w(code policy release live_mutation evidence review coordination)
  @effect_kind_sql Enum.map_join(@effect_kinds, ", ", &"'#{&1}'")

  defmodule TransitionRace do
    @moduledoc false
    defexception message: "assignment closed"
  end

  defmodule UnknownWorkItem do
    @moduledoc false
    defexception [:work_item_id]

    @impl true
    def message(%__MODULE__{work_item_id: id}), do: "unknown work item: #{id}"
  end

  defmodule UnknownReviewTarget do
    @moduledoc false
    defexception [:assignment_id]

    @impl true
    def message(%__MODULE__{assignment_id: id}), do: "unknown review target: #{id}"
  end

  @assignments_ddl """
  CREATE TABLE IF NOT EXISTS assignments (
    id TEXT PRIMARY KEY,
    subject TEXT NOT NULL CHECK(length(subject) BETWEEN 1 AND 2000 AND length(trim(subject)) >= 1),
    holderKey TEXT NOT NULL REFERENCES sessions(sessionKey),
    holderRole TEXT NULL,
    holderFallback INTEGER NOT NULL DEFAULT 0 CHECK(holderFallback IN (0, 1)),
    openedByUser TEXT NULL,
    openedBySession TEXT NULL,
    openedAt INTEGER NOT NULL,
    state TEXT NOT NULL DEFAULT 'open' CHECK(state IN ('open', 'closed')),
    outcome TEXT NULL CHECK(outcome IN ('completed', 'surrendered', 'revoked')),
    closedAt INTEGER NULL,
    closedByUser TEXT NULL,
    closedBySession TEXT NULL,
    closingAttestId TEXT NULL REFERENCES attests(id),
    workItemId TEXT NULL REFERENCES work_items(id),
    reviewsAssignmentId TEXT NULL REFERENCES assignments(id),
    holderHarness TEXT NULL,
    holderProvider TEXT NULL,
    CHECK(holderRole IS NOT NULL OR holderFallback = 0),
    CHECK((openedByUser IS NOT NULL) != (openedBySession IS NOT NULL)),
    CHECK(
      (state = 'open' AND outcome IS NULL AND closedAt IS NULL AND
       closedByUser IS NULL AND closedBySession IS NULL AND closingAttestId IS NULL)
      OR
      (state = 'closed' AND outcome IS NOT NULL AND closedAt IS NOT NULL AND
       ((closedByUser IS NOT NULL) != (closedBySession IS NOT NULL)))
    ),
    CHECK(outcome NOT IN ('completed', 'surrendered') OR closingAttestId IS NOT NULL),
    CHECK(outcome != 'revoked' OR closingAttestId IS NULL)
  )
  """

  @attests_ddl """
  CREATE TABLE IF NOT EXISTS attests (
    id TEXT PRIMARY KEY,
    assignmentId TEXT NOT NULL REFERENCES assignments(id),
    kind TEXT NOT NULL CHECK(kind IN ('progress', 'completion', 'surrender', 'verdict')),
    verdictKind TEXT NULL,
    note TEXT NULL CHECK(note IS NULL OR length(trim(note)) BETWEEN 1 AND 2000),
    bySession TEXT NULL REFERENCES sessions(sessionKey),
    byUser TEXT NULL REFERENCES users(userId),
    producer TEXT NULL,
    producerCommand TEXT NULL,
    byHarness TEXT NULL,
    byProvider TEXT NULL,
    commitRefs TEXT NULL,
    ts INTEGER NOT NULL,
    CHECK(
      (kind IN ('progress', 'completion', 'surrender') AND bySession IS NOT NULL AND
       byUser IS NULL AND verdictKind IS NULL)
      OR
      (kind = 'verdict' AND verdictKind IS NOT NULL AND
       ((bySession IS NOT NULL) != (byUser IS NOT NULL)))
    ),
    CHECK(producer IS NULL OR kind = 'verdict'),
    CHECK(producerCommand IS NULL OR producer IS NOT NULL),
    CHECK(byHarness IS NULL OR kind = 'verdict'),
    CHECK(byProvider IS NULL OR kind = 'verdict')
  )
  """

  @assignment_files_ddl """
  CREATE TABLE IF NOT EXISTS assignment_files (
    assignmentId TEXT NOT NULL REFERENCES assignments(id),
    path TEXT NOT NULL,
    PRIMARY KEY (assignmentId, path)
  );
  CREATE INDEX IF NOT EXISTS assignment_files_path ON assignment_files(path)
  """

  @assignment_effects_ddl """
  CREATE TABLE IF NOT EXISTS assignment_effects (
    assignmentId TEXT PRIMARY KEY REFERENCES assignments(id),
    effectKind TEXT NOT NULL CHECK(effectKind IN (#{@effect_kind_sql}))
  )
  """

  @assignment_priorities_ddl """
  CREATE TABLE IF NOT EXISTS assignment_priorities (
    assignmentId TEXT PRIMARY KEY REFERENCES assignments(id),
    priority INTEGER NOT NULL
  )
  """

  @interruptions_ddl """
  CREATE TABLE IF NOT EXISTS assignment_interruptions (
    assignmentId TEXT PRIMARY KEY REFERENCES assignments(id),
    sessionKey   TEXT NOT NULL REFERENCES sessions(sessionKey),
    reason       TEXT NOT NULL CHECK(reason = 'interrupted-by-retire'),
    ts           INTEGER NOT NULL
  );
  """

  # A revocation is a terminal fact, not an attest: the revoker is not the
  # holder and does not owe a verdict. Keep its provenance in its own
  # append-only row so reopening does not erase an earlier revocation.
  @revocations_ddl """
  CREATE TABLE IF NOT EXISTS assignment_revocations (
    id TEXT PRIMARY KEY,
    assignmentId TEXT NOT NULL REFERENCES assignments(id),
    revokedAt INTEGER NOT NULL,
    revokedByUser TEXT NULL REFERENCES users(userId),
    revokedBySession TEXT NULL REFERENCES sessions(sessionKey),
    reason TEXT NOT NULL CHECK(length(reason) BETWEEN 1 AND 2000 AND length(trim(reason)) >= 1),
    CHECK((revokedByUser IS NOT NULL) != (revokedBySession IS NOT NULL))
  );
  CREATE INDEX IF NOT EXISTS assignment_revocations_assignment
    ON assignment_revocations (assignmentId, revokedAt, id);
  """

  # The assignments row remains the terminal-state authority. This trigger
  # makes a revoked close impossible unless the same transaction first wrote a
  # provenance row with the exact closer and timestamp it is about to publish.
  @revocation_trigger_ddl """
  CREATE TRIGGER IF NOT EXISTS assignments_revocation_reason_required
  BEFORE UPDATE OF state, outcome, closedAt, closedByUser, closedBySession ON assignments
  WHEN NEW.state = 'closed' AND NEW.outcome = 'revoked'
    AND NOT EXISTS (
      SELECT 1 FROM assignment_revocations r
      WHERE r.assignmentId = NEW.id
        AND r.revokedAt = NEW.closedAt
        AND r.revokedByUser IS NEW.closedByUser
        AND r.revokedBySession IS NEW.closedBySession
    )
  BEGIN
    SELECT RAISE(ABORT, 'revoked assignment requires revocation provenance');
  END;
  """

  # The `reopen-assignment` papertrail. The assignments CHECK forces an OPEN row
  # to carry NULL outcome/closedAt/closer/closingAttest, so reopening necessarily
  # clears those columns — and a repair that CLEARS a recorded fact without
  # writing it down somewhere is a repair that loses rows. This append-only table
  # is where the cleared close goes, alongside the agent's named reason. Nothing
  # about a reopened assignment is inferred later: it is read from these rows.
  @reopenings_ddl """
  CREATE TABLE IF NOT EXISTS assignment_reopenings (
    id                   INTEGER PRIMARY KEY AUTOINCREMENT,
    assignmentId         TEXT    NOT NULL REFERENCES assignments(id),
    ts                   INTEGER NOT NULL,
    reopenedByUser       TEXT    NULL REFERENCES users(userId),
    reopenedBySession    TEXT    NULL REFERENCES sessions(sessionKey),
    reason               TEXT    NOT NULL
      CHECK(length(trim(reason)) BETWEEN 1 AND 2000),
    priorOutcome         TEXT    NOT NULL
      CHECK(priorOutcome IN ('completed', 'surrendered', 'revoked')),
    priorClosedAt        INTEGER NOT NULL,
    priorClosedByUser    TEXT    NULL,
    priorClosedBySession TEXT    NULL,
    priorClosingAttestId TEXT    NULL REFERENCES attests(id),
    CHECK((reopenedByUser IS NOT NULL) != (reopenedBySession IS NOT NULL))
  );
  CREATE INDEX IF NOT EXISTS assignment_reopenings_assignment
    ON assignment_reopenings (assignmentId, id);
  """

  @doc "Create the assignment/attest schema."
  @spec ensure_schema(DB.server()) :: :ok
  def ensure_schema(db \\ Tightbeam.DB) do
    # The circular terminal reference requires creating assignments first;
    # SQLite permits the referenced table to arrive in the following DDL.
    :ok = DB.execute(db, @assignments_ddl)
    :ok = DB.execute(db, @attests_ddl)
    :ok = DB.execute(db, @assignment_files_ddl)
    :ok = DB.execute(db, @assignment_effects_ddl)
    :ok = DB.execute(db, @assignment_priorities_ddl)
    :ok = DB.execute(db, @interruptions_ddl)
    :ok = DB.execute(db, @reopenings_ddl)
    :ok = DB.execute(db, @revocations_ddl)
    :ok = DB.execute(db, @revocation_trigger_ddl)
    migrate_legacy_revocations(db)
    Tightbeam.EffortCheckin.ensure_schema(db)
  end

  # Historical revoked rows predate a required reason. The explicit sentinel
  # records that absence without manufacturing a motive, and INSERT OR IGNORE
  # makes boot/replay idempotent.
  defp migrate_legacy_revocations(db) do
    :ok =
      DB.execute(
        db,
        """
        INSERT OR IGNORE INTO assignment_revocations
          (id, assignmentId, revokedAt, revokedByUser, revokedBySession, reason)
        SELECT 'legacy:' || id || ':' || closedAt, id, closedAt, closedByUser,
          closedBySession, 'legacy_unknown'
        FROM assignments
        WHERE state = 'closed' AND outcome = 'revoked'
        """
      )
  end

  @doc "Close every open assignment held by a retiring session and record why."
  @spec interrupt_for_retire_in_txn(Txn.t(), String.t(), String.t(), String.t()) :: [map()]
  def interrupt_for_retire_in_txn(%Txn{} = txn, session_key, owner_user_id, principal)
      when is_binary(principal) and principal != "" do
    assignments =
      Txn.q(
        txn,
        """
        SELECT a.id, EXISTS(SELECT 1 FROM attests f WHERE f.assignmentId=a.id), a.workItemId
        FROM assignments a
        WHERE a.holderKey=?1 AND a.state='open'
        ORDER BY a.openedAt, a.id
        """,
        [session_key]
      )
      |> Enum.map(fn [id, has_attests, work_item_id] ->
        %{
          assignment_id: id,
          from_state: if(has_attests == 1, do: "active", else: "open"),
          work_item_id: work_item_id
        }
      end)

    Enum.each(assignments, fn %{assignment_id: assignment_id, work_item_id: work_item_id} ->
      ts = now()

      Txn.q(
        txn,
        """
        INSERT INTO assignment_revocations
          (id, assignmentId, revokedAt, revokedByUser, revokedBySession, reason)
        VALUES (?1, ?2, ?3, ?4, NULL, 'holder session retired')
        """,
        [id("rev_"), assignment_id, ts, owner_user_id]
      )

      Txn.q(
        txn,
        """
        UPDATE assignments SET state='closed', outcome='revoked', closedAt=?2,
          closedByUser=?3
        WHERE id=?1 AND state='open'
        """,
        [assignment_id, ts, owner_user_id]
      )

      if Txn.changes(txn) != 1, do: raise(TransitionRace)

      Txn.q(
        txn,
        "INSERT INTO assignment_interruptions (assignmentId, sessionKey, reason, ts) VALUES (?1, ?2, 'interrupted-by-retire', ?3)",
        [assignment_id, session_key, ts]
      )

      append_notice(txn, session_key, "[assignment interrupted by retire: #{assignment_id}]")
      Tightbeam.WorkItems.arm_slate_in_txn(txn, work_item_id)

      liveness_trigger = disposition_liveness_trigger!(txn, work_item_id)

      supervision_transition!(txn, :terminal_disposition, %{
        kind: "terminal_disposition",
        assignment_id: assignment_id,
        cause: "holder_retired",
        principal: principal,
        requester_id: "tightbeam:retirement"
      })

      EffortCheckin.cancel_in_txn(
        txn,
        assignment_id,
        assignment_disposition_command(
          assignment_id,
          "tightbeam:retirement",
          liveness_trigger
        )
      )
    end)

    assignments
  end

  def interrupt_for_retire_in_txn(%Txn{}, _session_key, _owner_user_id, _principal) do
    raise ArgumentError, "retirement interruption requires a durable principal"
  end

  @doc "Count open assignments pinned to a holder session."
  @spec open_count(DB.server(), String.t()) :: non_neg_integer()
  def open_count(db, session_key) do
    {:ok, [[count]]} =
      DB.query(db, "SELECT count(*) FROM assignments WHERE holderKey = ?1 AND state = 'open'", [
        session_key
      ])

    count
  end

  @doc "Return the oldest open assignment held by a session."
  @spec oldest_open(DB.server(), String.t()) :: map() | nil
  def oldest_open(db, session_key) do
    {:ok, rows} =
      DB.query(
        db,
        "SELECT #{columns()} FROM assignments WHERE holderKey = ?1 AND state = 'open' ORDER BY openedAt ASC, id ASC LIMIT 1",
        [session_key]
      )

    case rows do
      [row] -> assignment(row)
      [] -> nil
    end
  end

  @doc "Count attest rows for an assignment."
  @spec attest_count(DB.server(), String.t()) :: non_neg_integer()
  def attest_count(db, assignment_id) do
    {:ok, [[count]]} =
      DB.query(db, "SELECT count(*) FROM attests WHERE assignmentId = ?1", [assignment_id])

    count
  end

  @doc "List assignments using optional holder_key and state filters."
  @spec list(DB.server(), map()) :: [map()]
  def list(db, filters) do
    state = Map.get(filters, :state, "open")
    holder = Map.get(filters, :holder_key)

    {clauses, params} =
      [{state != "all", "state", state}, {not is_nil(holder), "holderKey", holder}]
      |> Enum.filter(&elem(&1, 0))
      |> Enum.with_index(1)
      |> Enum.map_reduce([], fn {{_present, column, value}, index}, values ->
        {"#{column} = ?#{index}", values ++ [value]}
      end)

    where = if clauses == [], do: "1 = 1", else: Enum.join(clauses, " AND ")

    {:ok, rows} =
      DB.query(
        db,
        "SELECT #{columns()} FROM assignments WHERE #{where} ORDER BY openedAt DESC, id DESC",
        params
      )

    Enum.map(rows, fn row ->
      assignment = assignment(row)
      Map.put(assignment, :files, declared_files(db, assignment.id))
    end)
  end

  @doc "Return distinct verdict kinds filed against an assignment."
  @spec verdict_kinds(DB.server(), String.t()) :: [String.t()]
  def verdict_kinds(db, assignment_id) do
    {:ok, rows} =
      DB.query(
        db,
        "SELECT DISTINCT verdictKind FROM attests WHERE assignmentId = ?1 AND kind = 'verdict' ORDER BY verdictKind",
        [assignment_id]
      )

    Enum.map(rows, &hd/1)
  end

  @doc "Return commissioned independent review verdict authors for an assignment."
  @spec commissioned_review_authors(DB.server(), String.t(), String.t()) :: [map()]
  def commissioned_review_authors(db, assignment_id, a_holder_key) do
    {:ok, rows} =
      DB.query(
        db,
        """
        SELECT v.verdictKind, v.byHarness, v.byProvider
        FROM attests AS v
        JOIN assignments AS r ON r.id = v.assignmentId
        WHERE r.reviewsAssignmentId = ?1
          AND v.kind = 'verdict'
          AND v.bySession = r.holderKey
          AND v.bySession != ?2
        ORDER BY v.ts ASC, v.id ASC
        """,
        [assignment_id, a_holder_key]
      )

    Enum.map(rows, fn [verdict_kind, by_harness, by_provider] ->
      %{verdict_kind: verdict_kind, by_harness: by_harness, by_provider: by_provider}
    end)
  end

  @doc """
  Return the latest linked review round holder's qualifying verdict kind.

  HOLDER-VERDICT-WINS (fabric §13 Phase 0, wi_1b0237fe wedge class): the round
  is selected among the linked review cards THAT CARRY A HOLDER-FILED VERDICT,
  never by assignment-lifecycle recency alone. A review card holding no verdict
  by its own holder carries no judgment, so it may not displace the standing
  judgment of an earlier round — and a card CLOSED without one never can carry
  one (`attest` refuses a verdict on a closed assignment), which is exactly the
  state that wedged with no lawful exit. Verdict rows beat lifecycle rows.

  The tiebreak is the RECENCY OF THE LATEST HOLDER-FILED VERDICT itself (verdict
  row `ts` DESC, then verdict row `rowid` DESC) — never `r.openedAt`. Ordering by
  when the round was OPENED, rather than when its verdict was FILED, is exactly
  the lifecycle-recency mistake this function exists to refuse: `reopen-assignment`
  lets an OLDER round receive a fresh verdict after a chronologically YOUNGER
  round already closed, and a card that reopens to file the newest judgment must
  win the selection even though it opened first (Sol xhigh review, finding 1).

  What this deliberately does NOT relax: once the selected round is the latest
  VERDICT-CARRYING one, the pre-existing independence guard still applies to it
  verbatim — a self-held latest round still disqualifies, so a holder cannot
  launder its own verdict past an earlier independent one.

  SINGLE SOURCE OF TRUTH FOR THE WINNING VERDICT (Sol xhigh review round 2):
  reopening lets ONE card carry more than one verdict over its life — file
  reviewed-clean, close, reopen, file changes-requested — so "which round"
  and "which verdict on that round" cannot be two independently-computed
  answers; a query that picks the round by its latest verdict and then
  RE-DERIVES a kind by scanning that round's verdicts again is a second
  computation that has to agree with the first by construction rather than by
  identity. Each candidate round is joined to the exact `attests` ROW its
  ordering was computed from (`latestVerdictRowid`), and `latestVerdictKind`
  is read off that same row — not recomputed. A round with no holder verdict
  fails the join (the correlated subquery returns NULL, which no rowid
  equals) exactly where the old `EXISTS` clause excluded it.
  """
  @spec qualifying_review_verdict_kinds(DB.server(), String.t(), String.t()) :: [String.t()]
  def qualifying_review_verdict_kinds(db, assignment_id, assignment_holder_key) do
    {:ok, rows} =
      DB.query(
        db,
        """
        WITH latest_review AS (
          SELECT
            r.id,
            r.holderKey,
            lv.ts AS latestVerdictTs,
            lv.rowid AS latestVerdictRowid,
            lv.verdictKind AS latestVerdictKind
          FROM assignments AS r
          JOIN attests AS lv
            ON lv.rowid = (
              SELECT v.rowid
              FROM attests AS v
              WHERE v.assignmentId = r.id
                AND v.kind = 'verdict'
                AND v.bySession = r.holderKey
              ORDER BY v.ts DESC, v.rowid DESC
              LIMIT 1
            )
          WHERE r.reviewsAssignmentId = ?1
          ORDER BY latestVerdictTs DESC, latestVerdictRowid DESC
          LIMIT 1
        )
        SELECT latestVerdictKind
        FROM latest_review AS r
        WHERE r.holderKey != ?2
          AND latestVerdictKind = 'reviewed-clean'
        """,
        [assignment_id, assignment_holder_key]
      )

    case rows do
      [[verdict_kind]] when is_binary(verdict_kind) -> [verdict_kind]
      _ -> []
    end
  end

  @doc "Return the declared file paths for an assignment."
  @spec declared_files(DB.server(), String.t()) :: [String.t()]
  def declared_files(db, assignment_id) do
    {:ok, rows} =
      DB.query(
        db,
        "SELECT path FROM assignment_files WHERE assignmentId = ?1 ORDER BY path",
        [assignment_id]
      )

    Enum.map(rows, &hd/1)
  end

  @doc "Return open assignment ids declaring any of the given paths."
  @spec open_assignments_touching(DB.server(), [String.t()], String.t() | nil) :: [String.t()]
  def open_assignments_touching(db, paths, exclude_id \\ nil)
  def open_assignments_touching(_db, [], _exclude_id), do: []

  def open_assignments_touching(db, paths, exclude_id) do
    {sql, params} = open_assignments_touching_query(paths, exclude_id)
    {:ok, rows} = DB.query(db, sql, params)
    Enum.map(rows, &hd/1)
  end

  @doc "List every attest filed against an assignment in deterministic order."
  @spec list_attests(DB.server(), String.t()) :: [map()]
  def list_attests(db, assignment_id), do: list_attests(db, assignment_id, nil, nil)

  @doc """
  The same list, paged by a `(ts, id)` KEYSET (fabric §13 Phase 1 seam ④,
  GitHub #13).

  `after_id` names an attest ON THIS ASSIGNMENT and the page begins strictly
  after its `(ts, id)` — the same pair `ORDER BY ts ASC, id ASC` already sorts
  on, and both components are immutable once written, so a page boundary is
  stable no matter what lands next. `ts` alone would not do: it is a wall-clock
  millisecond and two attests filed in the same millisecond would either repeat
  or vanish, which is precisely the bug an OFFSET pager ships with.

  `limit` may be nil, and NIL IS THE DEFAULT everywhere it is reachable: this
  list is a per-assignment audit trail, and a default page size would silently
  shorten every existing caller's answer (Law 2 — an optimization that loses
  rows is wrong). One extra row is read to answer `has_more_after` honestly.
  """
  @spec list_attests(
          DB.server(),
          String.t(),
          {integer(), String.t()} | nil,
          pos_integer() | nil
        ) :: [map()]
  def list_attests(db, assignment_id, cursor, limit) do
    {range_sql, range_params} = attest_keyset(cursor)
    next = length(range_params) + 2

    {limit_sql, limit_params} =
      if limit, do: {" LIMIT ?#{next}", [limit]}, else: {"", []}

    {:ok, rows} =
      DB.query(
        db,
        "SELECT id, assignmentId, kind, verdictKind, note, bySession, byUser, producer, producerCommand, byHarness, byProvider, commitRefs, ts FROM attests WHERE assignmentId = ?1#{range_sql} ORDER BY ts ASC, id ASC#{limit_sql}",
        [assignment_id | range_params] ++ limit_params
      )

    Enum.map(rows, &attest/1)
  end

  # Row-value comparison written out longhand rather than `(ts, id) > (?, ?)`:
  # the expanded form is what every SQLite build in the fleet supports, and it
  # is the same predicate.
  defp attest_keyset(nil), do: {"", []}

  defp attest_keyset({ts, id}),
    do: {" AND (ts > ?2 OR (ts = ?2 AND id > ?3))", [ts, id]}

  @doc """
  Resolve an attest cursor to its `(ts, id)` order key, scoped to one assignment.

  `:error` for an id that does not exist AND for an id belonging to a different
  assignment — one answer, so the cursor cannot be used to probe for attests on
  assignments the caller did not name.
  """
  @spec attest_cursor(DB.server(), String.t(), String.t()) :: {integer(), String.t()} | :error
  def attest_cursor(db, assignment_id, after_id) do
    case DB.query(db, "SELECT ts, assignmentId FROM attests WHERE id = ?1", [after_id]) do
      {:ok, [[ts, ^assignment_id]]} -> {ts, after_id}
      _ -> :error
    end
  end

  @doc """
  List every `reopen-assignment` papertrail row for an assignment in
  deterministic order (Sol xhigh review, finding 6). The reason the assignment
  is open again — actor, reason, time, and the close it cleared — is durable
  the moment `reopen-assignment` commits; this is the read that surfaces it
  rather than leaving it inferable only from a direct query.
  """
  @spec list_reopenings(DB.server(), String.t()) :: [map()]
  def list_reopenings(db, assignment_id) do
    {:ok, rows} =
      DB.query(
        db,
        """
        SELECT id, assignmentId, ts, reopenedByUser, reopenedBySession, reason,
          priorOutcome, priorClosedAt, priorClosedByUser, priorClosedBySession,
          priorClosingAttestId
        FROM assignment_reopenings
        WHERE assignmentId = ?1
        ORDER BY ts ASC, id ASC
        """,
        [assignment_id]
      )

    Enum.map(rows, &reopening/1)
  end

  @doc false
  def __for_work_item__(db, work_item_id) do
    {:ok, rows} =
      DB.query(
        db,
        "SELECT #{columns()} FROM assignments WHERE workItemId = ?1 ORDER BY openedAt DESC, id DESC",
        [work_item_id]
      )

    Enum.map(rows, &assignment/1)
  end

  @doc "Resolve an assignment's story membership without changing direct ownership readers."
  @spec resolved_work_item_id(DB.server(), String.t()) :: String.t() | nil
  def resolved_work_item_id(db, assignment_id) do
    {:ok, work_item_id} =
      DB.transaction(db, fn txn ->
        resolve_work_item_id_in_txn(txn, assignment_id, MapSet.new())
      end)

    work_item_id
  end

  @doc "Log legacy review/item conflicts without mutating assignment rows."
  @spec audit_review_item_conflicts(DB.server()) :: :ok
  def audit_review_item_conflicts(db) do
    {:ok, conflicts} =
      DB.transaction(db, fn txn ->
        Txn.q(
          txn,
          """
          SELECT id, workItemId, reviewsAssignmentId
          FROM assignments
          WHERE reviewsAssignmentId IS NOT NULL
          ORDER BY id
          """
        )
        |> Enum.reduce([], fn [id, work_item_id, reviews_assignment_id], conflicts ->
          reviewed_item_id =
            resolve_work_item_id_in_txn(txn, reviews_assignment_id, MapSet.new())

          if not is_nil(work_item_id) and work_item_id != reviewed_item_id do
            [{id, work_item_id, reviews_assignment_id, reviewed_item_id} | conflicts]
          else
            conflicts
          end
        end)
        |> Enum.reverse()
      end)

    Enum.each(conflicts, fn {id, work_item_id, reviews_assignment_id, reviewed_item_id} ->
      Logger.warning(
        "review_item_conflict legacy assignment=#{id} workItemId=#{work_item_id} " <>
          "reviewsAssignmentId=#{reviews_assignment_id} reviewedWorkItemId=#{inspect(reviewed_item_id)}"
      )
    end)

    :ok
  end

  @doc false
  def __handle__(db, "assign", call), do: assign_result(db, call)
  def __handle__(db, "dispatch", call), do: dispatch_result(db, call)
  def __handle__(db, "attest", call), do: attest_result(db, call)
  def __handle__(db, "attests", call), do: attests_result(db, call)
  def __handle__(db, "assignment-get", call), do: assignment_get_result(db, call)
  def __handle__(db, "revoke-assignment", call), do: revoke_result(db, call)
  def __handle__(db, "reopen-assignment", call), do: reopen_result(db, call)
  def __handle__(db, "assignments", call), do: assignments_result(db, call)

  defp assign_result(db, call) do
    config = effort_config(db, call)

    open_assignment_result(
      db,
      call,
      fn txn, assignment ->
        EffortCheckin.arm_in_txn(txn, config, assignment)
        {:created, assignment, nil}
      end,
      fn -> :ok end,
      "assign"
    )
  end

  @doc """
  The dispatch-chokepoint precheck (work-item-brackets §Mechanism total order):
  hoisted ABOVE `Rules.decide` so both the terminal guard and the rail see the
  replay outcome first. For a keyed assign/dispatch, an idempotency hit returns
  the ORIGINAL assignment and bypasses work-item state, statutes, the terminal
  guard, and rumination. On a miss, a workItemId pointing at a non-open item is
  refused BEFORE any statute or remedy episode can fire. Assign's pre-lookup
  validations (authority, subject, key-format, files) run verbatim first.
  """
  @spec dispatch_precheck(DB.server(), map()) ::
          :proceed | {:replay, map()} | {:refuse, map()}
  def dispatch_precheck(db, call) do
    verb = Map.fetch!(call, :verb)

    with :ok <- principal_allowed(call.principal, verb),
         :ok <- valid_subject(call.params[:subject]),
         :ok <- valid_idempotency_key(call.params[:idempotency_key]),
         :ok <- valid_effect_kind(call.params[:effect_kind]),
         {:ok, _files} <- assignment_files(verb, call.params) do
      key = call.params[:idempotency_key]
      replay = if is_binary(key), do: replayed_assignment(db, call), else: nil

      case replay do
        %{} = assignment ->
          {:replay, assignment}

        nil ->
          case call.params[:work_item_id] do
            nil ->
              :proceed

            supplied ->
              case IdPrefix.resolve(db, :work_item, supplied) do
                {:ok, work_item_id} ->
                  case Tightbeam.WorkItems.state_for(db, work_item_id) do
                    state when state in [nil, "open"] -> :proceed
                    _terminal -> {:refuse, work_item_not_open(work_item_id)}
                  end

                :unknown ->
                  :proceed

                {:ambiguous, error} ->
                  {:refuse, error}
              end
          end
      end
    else
      %{code: _} = error -> {:refuse, error}
    end
  end

  defp work_item_not_open(work_item_id),
    do: error("work_item_not_open", "work item #{work_item_id} is not open")

  defp dispatch_result(db, call) do
    outcome =
      transaction(db, fn txn ->
        supplied = call.params[:work_item_id]

        case resolve_optional_in_txn(txn, :work_item, supplied) do
          {:ok, work_item_id} ->
            if work_item_id, do: id_resolved(call, txn, :work_item, work_item_id)
            resolved_call = put_in(call, [:params, :work_item_id], work_item_id)

            case {work_item_id, call.principal} do
              {id, {:session, caller_session}} when not is_nil(id) ->
                if Wakes.rumination_exists_in_txn?(txn, id, caller_session) do
                  {:open, resolved_call}
                else
                  wake =
                    Wakes.schedule_in_txn(txn, %{
                      session_key: caller_session,
                      origin: call.origin,
                      creator_session_key: caller_session,
                      prompt:
                        "digest: Ruminate on work-item #{id} against the whole spec and its spirit before you fan out. Intent you were about to dispatch: subject=#{call.params[:subject]} brief=#{call.params[:brief]}. When you've thought it through, re-issue the dispatch.",
                      due_at: now(),
                      rumination: true,
                      work_item_id: id
                    })

                  Publisher.maybe_observed_accepted_in_txn(txn, call)
                  Wakes.publish_change_in_txn(txn, "wake.scheduled", wake.wake_id)

                  %{
                    rumination_required: true,
                    work_item_id: id,
                    message:
                      "Sent you to ruminate on #{id} first — re-dispatch when you're done thinking."
                  }
                end

              _ ->
                {:open, resolved_call}
            end

          :unknown ->
            error("unknown_work_item", "unknown work item: #{supplied}")

          {:ambiguous, error} ->
            error
        end
      end)

    case outcome do
      {:open, resolved_call} -> open_dispatch_result(db, resolved_call)
      other -> other
    end
  end

  defp open_dispatch_result(db, call) do
    with :ok <- principal_allowed(call.principal, "dispatch"),
         :ok <- valid_subject(call.params[:subject]),
         :ok <- valid_idempotency_key(call.params[:idempotency_key]),
         {:ok, _files} <- assignment_files("dispatch", call.params),
         :ok <- valid_brief(call.params[:brief]),
         :ok <- normalize_root_validation(call.params[:workdir_root]) do
      case replayed_assignment(db, call) do
        nil ->
          case Org.get(db, call.session_key) do
            %{state: "active"} = holder ->
              config = effort_config(db, call)
              prepared = EffortCheckin.prepare_arm(config, holder, call.params[:workdir_root])

              open_assignment_result(
                db,
                call,
                fn txn, assignment ->
                  EffortCheckin.arm_in_txn(txn, config, assignment, prepared)

                  prompt = "[assignment: #{assignment.id}]\n\n" <> call.params.brief

                  delivery =
                    Tightbeam.Gateway.deliver_prompt_in_txn(
                      txn,
                      assignment.holderKey,
                      call.origin,
                      prompt,
                      sender: call.origin,
                      role_ref: assignment.holderRole,
                      role_fallback: assignment.holderFallback,
                      assignment_id: assignment.id,
                      job_ref: assignment.workItemId
                    )

                  {:created, assignment, delivery}
                end,
                fn -> :ok end,
                "dispatch"
              )

            nil ->
              error("not_found", "unknown holder session")

            %{state: "retired"} ->
              error("session_retired", "assignments require an active holder session")
          end

        assignment ->
          assignment
      end
    else
      error -> error
    end
  end

  defp open_assignment_result(
         db,
         call,
         after_create,
         extra_validation,
         verb
       ) do
    with :ok <- principal_allowed(call.principal, verb),
         :ok <- valid_subject(call.params[:subject]),
         :ok <- valid_supervision_interval(call[:supervision_interval_ms]),
         :ok <- valid_idempotency_key(call.params[:idempotency_key]),
         :ok <- valid_effect_kind(call.params[:effect_kind]),
         {:ok, files} <- assignment_files(verb, call.params),
         :ok <- extra_validation.() do
      owner = principal_id(call.principal)
      key = call.params[:idempotency_key]

      result =
        transaction(db, fn txn ->
          result =
            case open_assignment_in_txn(txn, call, owner, key, files, verb) do
              {:created, assignment} ->
                created = after_create.(txn, assignment)
                accept_assignment_in_txn(created, txn, call)

              other ->
                other
            end

          case result do
            {:accepted_in_txn, _event_id, {:created, assignment, _delivery}} ->
              Publisher.maybe_accepted_in_txn(txn, call, assignment)

            {:created, assignment, _delivery} ->
              Publisher.maybe_accepted_in_txn(txn, call, assignment)

            {:replayed, assignment} ->
              Publisher.maybe_accepted_in_txn(txn, call, assignment)

            _ ->
              :ok
          end

          result
        end)

      case result do
        {:accepted_in_txn, event_id, {:created, assignment, delivery}} ->
          assignment = finalize_created_assignment(call, assignment, delivery)
          {:accepted_in_txn, event_id, %{assignment: assignment}}

        {:created, assignment, delivery} ->
          finalize_created_assignment(call, assignment, delivery)

        {:replayed, assignment} ->
          assignment

        error ->
          error
      end
    end
  rescue
    error in UnknownWorkItem -> error("unknown_work_item", Exception.message(error))
    error in UnknownReviewTarget -> error("unknown_review_target", Exception.message(error))
  end

  defp finalize_created_assignment(call, assignment, delivery) do
    best_effort(fn -> notify(call, :on_assignment_change, assignment.id, nil) end)

    if assignment.workItemId do
      best_effort(fn ->
        notify(call, :on_work_item_change, assignment.workItemId, "composition")
      end)
    end

    if delivery, do: best_effort(fn -> notify(call, :on_dispatch_delivery, delivery, nil) end)
    assignment
  end

  defp accept_assignment_in_txn({:created, assignment, _delivery} = result, txn, call) do
    if call[:accepted_event_in_txn] do
      event_id =
        EventLog.append_event_in_txn(
          txn,
          "verb",
          call.verb,
          call.origin,
          call.session_key,
          assignment,
          call.principal,
          now()
        )

      {:accepted_in_txn, event_id, result}
    else
      result
    end
  end

  defp open_assignment_in_txn(txn, call, owner, key, files, verb) do
    case key && idempotency_assignment(txn, owner, key) do
      nil ->
        case create_assignment(txn, call, owner, key, files, verb) do
          %{code: _} = error -> error
          assignment -> {:created, assignment}
        end

      id ->
        {:replayed, fetch_assignment!(txn, id)}
    end
  end

  defp attest_result(db, call) do
    with :ok <- principal_allowed(call.principal, "attest"),
         :ok <- commit_ref_filing_allowed(db, call),
         :ok <- valid_commit_refs(db, call.params[:kind], call.params[:commit_refs]) do
      supplied = call.params[:assignment_id]

      from =
        case IdPrefix.resolve(db, :assignment, supplied) do
          {:ok, id} -> {id, best_effort_value(fn -> Tightbeam.WorkState.status(db, id) end)}
          _ -> {supplied, :error}
        end

      # The referent cursor is read BEFORE the claim is filed: what a claim points
      # at is what had been recorded when it was made, never an artifact that
      # appeared while the check was running. Reading it outside the attest's
      # transaction is deliberate — a registry this cannot read is reported as
      # such, and a failed CHECK never rejects the claim (§Design 5).
      artifact_cursor = artifact_cursor(db)

      result =
        transaction(db, fn txn ->
          result =
            case IdPrefix.resolve_in_txn(txn, :assignment, supplied) do
              {:ok, id} ->
                id_resolved(call, txn, :assignment, id)
                resolved_call = put_in(call, [:params, :assignment_id], id)

                with :ok <- commit_ref_filing_allowed_in_txn(txn, resolved_call) do
                  attest_in_txn(txn, resolved_call)
                end

              :unknown ->
                error("unknown_assignment", "unknown assignment: #{supplied}")

              {:ambiguous, error} ->
                error
            end

          if is_map(result) and not Map.has_key?(result, :code) and
               not Map.get(result, :revocation_replayed, false),
             do: Publisher.maybe_accepted_in_txn(txn, call, result)

          result
        end)

      if not Map.has_key?(result, :code) and match?({_id, {:ok, _}}, from) do
        {assignment_id, {:ok, prior_state}} = from
        best_effort(fn -> notify(call, :on_assignment_change, assignment_id, prior_state) end)
      end

      # The claim is filed; now check what it pointed at. Verification runs
      # AFTER the transaction and never changes it: a referent that cannot be
      # checked is a fact about the check, not a verdict on the attest.
      case result do
        %{assignment: assignment} ->
          Map.put(result, :referents, referents(db, call, assignment, artifact_cursor))

        _ ->
          result
      end
    end
  rescue
    TransitionRace -> assignment_closed()
  end

  # Per effort-checkin-v2 §Design 5 and the provenance it cites verbatim —
  # "Artifacts are the referents" — an attest's referents are the artifacts the
  # HOLDER recorded, not a separate list it declares, and not a subset chosen
  # here. Every one of them is verified by write-detection of its originPath on
  # the host that holds it.
  #
  # The one row this cannot check is an ARCHIVED one: archival moved those bytes
  # into `home` itself, so originPath is knowingly stale and stat-ing it would
  # manufacture an "absent" the substrate caused. A released row is still checked
  # — external work lives exactly where it says it does.
  defp referents(_db, _call, _assignment, {:error, reason}), do: [unreadable_registry(reason)]

  defp referents(db, call, assignment, {:ok, artifact_cursor}) do
    config = effort_config(db, call)
    holder = Org.get(db, assignment.holderKey)

    case DB.query(
           db,
           """
           SELECT artifactId, originPath FROM artifacts
           WHERE createdBySession = ?1 AND rowid <= ?2 AND state <> 'archived'
           ORDER BY createdAt, artifactId
           """,
           [assignment.holderKey, artifact_cursor]
         ) do
      {:ok, rows} -> verified_referents(config, holder, rows)
      {:error, reason} -> [unreadable_registry(reason)]
    end
  rescue
    error -> [unreadable_registry(error)]
  end

  defp artifact_cursor(db) do
    case DB.query(db, "SELECT COALESCE(MAX(rowid), 0) FROM artifacts") do
      {:ok, [[cursor]]} -> {:ok, cursor}
      {:error, reason} -> {:error, reason}
    end
  rescue
    error -> {:error, error}
  end

  defp unreadable_registry(reason) do
    %{
      artifactId: nil,
      originPath: nil,
      host: nil,
      path: nil,
      mtime: nil,
      status: "unverifiable",
      reason: "the artifact registry could not be read: #{inspect(reason)}"
    }
  end

  defp verified_referents(_config, _holder, []), do: []

  # No holder session means no host to resolve a path against. That is reported
  # per artifact, not swallowed into an empty list that reads like "checked, all
  # fine".
  defp verified_referents(_config, nil, rows) do
    Enum.map(rows, fn [id, origin] ->
      %{
        artifactId: id,
        originPath: origin,
        host: nil,
        path: nil,
        mtime: nil,
        status: "unverifiable",
        reason: "the holder session is unavailable, so its host could not be resolved"
      }
    end)
  end

  defp verified_referents(config, holder, rows) do
    resolved = Enum.map(rows, fn [id, origin] -> resolve_origin(config, holder, id, origin) end)

    checks =
      resolved
      |> Enum.filter(& &1.host)
      |> Enum.group_by(& &1.host, & &1.path)
      |> Enum.map(fn {host, paths} ->
        {host, Placement.check_origins(config, host, Enum.uniq(paths))}
      end)
      |> Map.new()

    Enum.map(resolved, fn referent ->
      status =
        if referent.reason,
          do: {:error, referent.reason},
          else: checks[referent.host][referent.path]

      %{
        artifactId: referent.artifact_id,
        originPath: referent.origin,
        host: referent.host,
        path: referent.path,
        mtime: referent_mtime(status),
        status: referent_status(status),
        reason: referent_reason(status)
      }
    end)
  end

  # `host:/absolute/path` names a machine, exactly as commitRefs' repo does.
  # Anything else belongs to the holder's own host: absolute as written, relative
  # to the workdir the holder works in.
  defp resolve_origin(config, holder, artifact_id, origin) do
    base = %{artifact_id: artifact_id, origin: origin, host: nil, path: nil, reason: nil}

    case String.split(origin, ":", parts: 2) do
      [name, path] when path != "" ->
        cond do
          Path.type(path) != :absolute ->
            %{base | host: holder.host, path: local_origin_path(config, holder, origin)}

          Map.has_key?(Placement.hosts(config.base_dir, config.db), name) ->
            %{base | host: name, path: path}

          true ->
            %{base | reason: "origin names host #{name}, which is not a registered host"}
        end

      _ ->
        %{base | host: holder.host, path: local_origin_path(config, holder, origin)}
    end
  end

  defp local_origin_path(config, holder, origin) do
    if Path.type(origin) == :absolute,
      do: origin,
      else: Path.join(Placement.workdir_path(config, holder), origin)
  end

  defp referent_status({:present, _mtime}), do: "present"
  defp referent_status(:absent), do: "absent"
  defp referent_status(_), do: "unverifiable"

  defp referent_mtime({:present, mtime}), do: mtime
  defp referent_mtime(_), do: nil

  defp referent_reason({:error, reason}), do: reason
  defp referent_reason(nil), do: "the check returned no answer for this path"
  defp referent_reason(_), do: nil

  defp revoke_result(db, call) do
    with :ok <- principal_allowed(call.principal, "revoke-assignment") do
      supplied = call.params[:assignment_id]

      from =
        case IdPrefix.resolve(db, :assignment, supplied) do
          {:ok, id} -> {id, best_effort_value(fn -> Tightbeam.WorkState.status(db, id) end)}
          _ -> {supplied, :error}
        end

      result =
        transaction(db, fn txn ->
          visible? = fn id ->
            case fetch_assignment(txn, id) do
              nil -> false
              assignment -> revoke_allowed?(txn, call.principal, assignment)
            end
          end

          result =
            case IdPrefix.resolve_in_txn(txn, :assignment, supplied, visible?) do
              {:ok, id} ->
                id_resolved(call, txn, :assignment, id)
                revoke_in_txn(txn, put_in(call, [:params, :assignment_id], id))

              :unknown ->
                error("unknown_assignment", "unknown assignment: #{supplied}")

              {:ambiguous, error} ->
                error
            end

          if is_map(result) and not Map.has_key?(result, :code),
            do: Publisher.maybe_accepted_in_txn(txn, call, result)

          result
        end)

      if not Map.has_key?(result, :code) and match?({_id, {:ok, _}}, from) do
        {assignment_id, {:ok, prior_state}} = from
        best_effort(fn -> notify(call, :on_assignment_change, assignment_id, prior_state) end)
      end

      Map.delete(result, :revocation_replayed)
    end
  rescue
    TransitionRace -> assignment_closed()
  end

  # `reopen-assignment` — the lawful agent-reachable exit from a closed-card
  # wedge (fabric §13 Phase 0; philosophy gate Law 3).
  #
  # A verdict may only be filed on an OPEN assignment, so a review card that
  # closed carrying the wrong judgment — or a producer card closed on a
  # disposition the org has since ruled against — used to be repairable only by
  # an admin at a database console. That is the shape Law 3 names incomplete.
  # This verb moves such a card back to `open` so the MIND that owes the
  # judgment can file it through the ordinary `attest` seam.
  #
  # The substrate judges nothing here: it does not decide which card deserves
  # reopening, does not pick a replacement verdict, and does not seize the card
  # from its holder. It records the agent's named reason, re-arms the same
  # supervision entitlement an `assign` would, and refuses — by name — every
  # application that would land the card in an unworkable state.
  defp reopen_result(db, call) do
    with :ok <- principal_allowed(call.principal, "reopen-assignment"),
         :ok <- valid_reopen_reason(call.params[:reason]) do
      supplied = call.params[:assignment_id]

      from =
        case IdPrefix.resolve(db, :assignment, supplied) do
          {:ok, id} -> {id, best_effort_value(fn -> Tightbeam.WorkState.status(db, id) end)}
          _ -> {supplied, :error}
        end

      effort_config = effort_config(db, call)

      prepared_effort_arm =
        case from do
          {assignment_id, {:ok, _}} ->
            may_prepare? =
              transaction(db, fn txn ->
                case fetch_assignment(txn, assignment_id) do
                  %{state: "closed"} = assignment ->
                    reopen_allowed?(txn, call.principal, assignment)

                  _ ->
                    false
                end
              end)

            if may_prepare?,
              do: EffortCheckin.prepare_reopen_arm(db, effort_config, assignment_id)

          _ ->
            nil
        end

      call =
        call
        |> Map.put(:effort_config, effort_config)
        |> Map.put(:prepared_effort_arm, prepared_effort_arm)

      result =
        transaction(db, fn txn ->
          visible? = fn id ->
            case fetch_assignment(txn, id) do
              nil -> false
              assignment -> reopen_allowed?(txn, call.principal, assignment)
            end
          end

          result =
            case IdPrefix.resolve_in_txn(txn, :assignment, supplied, visible?) do
              {:ok, id} ->
                id_resolved(call, txn, :assignment, id)
                reopen_in_txn(txn, put_in(call, [:params, :assignment_id], id))

              :unknown ->
                error("unknown_assignment", "unknown assignment: #{supplied}")

              {:ambiguous, error} ->
                error
            end

          if is_map(result) and not Map.has_key?(result, :code),
            do: Publisher.maybe_accepted_in_txn(txn, call, result)

          result
        end)

      if not Map.has_key?(result, :code) and match?({_id, {:ok, _}}, from) do
        {assignment_id, {:ok, prior_state}} = from
        best_effort(fn -> notify(call, :on_assignment_change, assignment_id, prior_state) end)
      end

      result
    end
  rescue
    TransitionRace ->
      error("transition_race", "assignment changed state during the reopen; read it and retry")
  end

  defp reopen_in_txn(txn, call) do
    assignment_id = call.params[:assignment_id]

    case fetch_assignment(txn, assignment_id) do
      nil ->
        error("unknown_assignment", "unknown assignment: #{assignment_id}")

      assignment ->
        cond do
          not reopen_allowed?(txn, call.principal, assignment) ->
            error("not_authorized", "assignment reopen requires its opener or an admin")

          assignment.state == "open" ->
            error("assignment_open", "assignment #{assignment_id} is already open")

          true ->
            with :ok <- lawful_closed_shape(assignment),
                 :ok <- reopen_holder_active(txn, assignment),
                 :ok <- reopen_work_item_open(txn, assignment) do
              apply_reopen(txn, call, assignment)
            end
        end
    end
  end

  defp apply_reopen(txn, call, assignment) do
    assignment_id = assignment.id
    now = now()
    {reopened_user, reopened_session} = opener(call.principal)

    # The close is written down BEFORE it is cleared. Order matters: a crash
    # between the two statements rolls the whole transaction back, so the row
    # and the state can never disagree.
    Txn.q(
      txn,
      """
      INSERT INTO assignment_reopenings
        (assignmentId, ts, reopenedByUser, reopenedBySession, reason, priorOutcome,
         priorClosedAt, priorClosedByUser, priorClosedBySession, priorClosingAttestId)
      VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10)
      """,
      [
        assignment_id,
        now,
        reopened_user,
        reopened_session,
        call.params[:reason],
        assignment.outcome,
        assignment.closedAt,
        assignment.closedByUser,
        assignment.closedBySession,
        assignment.closingAttestId
      ]
    )

    Txn.q(
      txn,
      """
      UPDATE assignments SET state = 'open', outcome = NULL, closedAt = NULL,
        closedByUser = NULL, closedBySession = NULL, closingAttestId = NULL
      WHERE id = ?1 AND state = 'closed'
      """,
      [assignment_id]
    )

    if Txn.changes(txn) != 1, do: raise(TransitionRace)
    reopened = fetch_assignment!(txn, assignment_id)

    EffortCheckin.arm_reopened_in_txn(
      txn,
      call.effort_config,
      reopened,
      call.prepared_effort_arm
    )

    # A terminal disposition DELETEs the entitlement row, so this arms a fresh
    # generation exactly as `assign` does — a reopened card is watched like any
    # other open card rather than living unsupervised.
    supervision_transition!(txn, :armed, %{
      kind: "assignment_open",
      assignment_id: assignment_id,
      opened_at: now,
      supervision_interval_ms: call.supervision_interval_ms,
      principal: principal_id(call.principal)
    })

    entitlement_trigger = liveness_trigger!(txn, {:assignment, assignment_id})

    # The item carries open work again, so a slate wake armed by the close is no
    # longer telling the truth.
    if reopened.workItemId do
      Tightbeam.WorkItems.cancel_brackets_in_txn(txn, reopened.workItemId, %{
        causal_source: %{kind: "assignment_transition", id: assignment_id},
        outcome: %{
          kind: "disposition",
          disposition_kind: "assignment_transition",
          disposition_id: assignment_id,
          liveness_trigger: entitlement_trigger
        }
      })
    end

    append_assignment_marker(
      txn,
      reopened,
      :reopened,
      principal_id(call.principal),
      call.params[:reason]
    )

    reopened
  end

  # Report dirt, never accommodate it. A closed row's shape is stamped by the
  # table's CHECK at write time; if what came back does not carry that stamp,
  # this refuses and names what it found instead of guessing a repair.
  defp lawful_closed_shape(%{
         outcome: outcome,
         closedAt: closed_at,
         closedByUser: closed_by_user,
         closedBySession: closed_by_session
       })
       when outcome in ["completed", "surrendered", "revoked"] and is_integer(closed_at) and
              ((is_binary(closed_by_user) and is_nil(closed_by_session)) or
                 (is_nil(closed_by_user) and is_binary(closed_by_session))),
       do: :ok

  defp lawful_closed_shape(assignment) do
    found =
      "state=#{inspect(assignment.state)} outcome=#{inspect(assignment.outcome)} " <>
        "closedAt=#{inspect(assignment.closedAt)} closedByUser=#{inspect(assignment.closedByUser)} " <>
        "closedBySession=#{inspect(assignment.closedBySession)}"

    Logger.error(
      "reopen refused: assignment #{assignment.id} is not a lawful closed row: #{found}"
    )

    error(
      "unexpected_assignment_shape",
      "assignment #{assignment.id} is not a lawful closed row (#{found}); this is a bug report, not a repair"
    )
  end

  defp reopen_holder_active(txn, assignment) do
    case Txn.q(txn, "SELECT state FROM sessions WHERE sessionKey = ?1", [assignment.holderKey]) do
      [["active"]] ->
        :ok

      _ ->
        error(
          "session_retired",
          "assignment #{assignment.id} is held by #{assignment.holderKey}, which is not active; " <>
            "reopening it would create an assignment no agent can work"
        )
    end
  end

  defp reopen_work_item_open(_txn, %{workItemId: nil}), do: :ok

  defp reopen_work_item_open(txn, assignment) do
    case Tightbeam.WorkItems.state_in_txn(txn, assignment.workItemId) do
      "open" ->
        :ok

      state ->
        error(
          "work_item_not_open",
          "work item #{assignment.workItemId} is #{state}; reopen the item before its assignment"
        )
    end
  end

  # Opener-or-admin (revoke's authority) is not enough here: the HOLDER is the
  # mind that owes the replacement verdict, and gating their only exit behind
  # someone else's opener/admin decision is exactly the shape Law 3 names
  # incomplete (Sol xhigh review, finding 3). Holder identity is checked the
  # same way `attest` checks it for a review verdict — the exact session
  # principal equals `assignment.holderKey` — never the session's owning user,
  # so a card cannot be reopened merely by whoever owns the holder session.
  defp reopen_allowed?(txn, {:session, session} = principal, assignment),
    do: revoke_allowed?(txn, principal, assignment) or session == assignment.holderKey

  defp reopen_allowed?(txn, principal, assignment),
    do: revoke_allowed?(txn, principal, assignment)

  defp valid_reopen_reason(reason) when is_binary(reason) do
    # Unicode CODE POINTS, matching the `assignment_reopenings` CHECK's
    # `length(trim(reason))` — SQLite's `length()` on TEXT counts code points,
    # not grapheme clusters. `String.length/1` counts graphemes, so a reason
    # built of multi-codepoint grapheme clusters (e.g. family-emoji ZWJ
    # sequences) could pass this guard while still tripping the table's CHECK,
    # turning a named `invalid_reason` refusal into a raw database error
    # (Sol xhigh review, finding 5).
    length_in_code_points = length(String.to_charlist(reason))

    if length_in_code_points in 1..2000 and String.trim(reason) != "",
      do: :ok,
      else:
        error("invalid_reason", "reason must be 1..2000 non-blank characters naming the repair")
  end

  defp valid_reopen_reason(nil),
    do: error("missing_reason", "reopen requires a reason naming why this card must reopen")

  defp valid_reopen_reason(_),
    do: error("invalid_reason", "reason must be text")

  defp valid_revocation_reason(reason) when is_binary(reason) do
    # SQLite counts Unicode code points for this CHECK, so the application
    # guard uses the same unit and always returns a named refusal first.
    length_in_code_points = length(String.to_charlist(reason))

    if length_in_code_points in 1..2000 and String.trim(reason) != "",
      do: :ok,
      else:
        error(
          "invalid_reason",
          "reason must be 1..2000 non-blank characters naming the revocation"
        )
  end

  defp valid_revocation_reason(nil),
    do: error("missing_reason", "revocation requires a reason naming why this card is revoked")

  defp valid_revocation_reason(_), do: error("invalid_reason", "reason must be text")

  defp assignments_result(db, call) do
    with :ok <- principal_allowed(call.principal, "assignments"),
         :ok <- valid_state(call.params[:state]) do
      %{
        assignments:
          list(db, %{holder_key: call.session_key, state: call.params[:state] || "open"})
      }
    end
  end

  defp assignment_get_result(db, call) do
    assignment_id = call.params[:assignment_id]

    with :ok <- principal_allowed(call.principal, "assignment-get") do
      case DB.query(db, "SELECT #{columns()} FROM assignments WHERE id = ?1", [assignment_id]) do
        {:ok, [row]} ->
          # `reopenings` (Sol xhigh review, finding 6): the read surface for an
          # assignment must be able to answer "why is this open again", not just
          # "database" — this is that answer, in the same list-of-rows shape
          # `attests` already reads via `list_attests/2`.
          Map.put(assignment(row), :reopenings, list_reopenings(db, assignment_id))

        {:ok, []} ->
          error("not_found", "unknown assignment: #{assignment_id}")
      end
    end
  end

  # The hard cap on one page. A larger request is CLAMPED, never refused, and the
  # clamp is observable in the returned count — `transcript`'s rule.
  @max_attest_page 500

  defp attests_result(db, call) do
    supplied = call.params[:assignment_id]

    with :ok <- principal_allowed(call.principal, "attests"),
         {:ok, limit} <- attest_limit(call.params[:limit]) do
      case IdPrefix.resolve(db, :assignment, supplied) do
        {:ok, assignment_id} ->
          with {:ok, cursor} <- attest_after(db, assignment_id, call.params[:after]) do
            attest_page(db, assignment_id, cursor, limit, paging?(call.params))
          else
            {:error, error} -> error
          end

        :unknown ->
          error("unknown_assignment", "unknown assignment: #{supplied}")

        {:ambiguous, error} ->
          error
      end
    else
      {:error, error} -> error
      other -> other
    end
  end

  defp paging?(params), do: not is_nil(params[:after]) or not is_nil(params[:limit])

  # No `--after`/`--limit` at all: the response carries ONLY the key it always
  # carried (Sol xhigh review, finding 8). `next_after`/`has_more_after` are
  # PAGING vocabulary — a pre-existing caller that never asked to page must see
  # zero payload change, the same byte-identical promise `toplines`' unpaged
  # read makes.
  defp attest_page(db, assignment_id, cursor, _limit, false) do
    %{attests: list_attests(db, assignment_id, cursor, nil)}
  end

  # One extra row decides `has_more_after` from the rows themselves rather than a
  # second COUNT that could disagree with the page it describes.
  defp attest_page(db, assignment_id, cursor, nil, true) do
    entries = list_attests(db, assignment_id, cursor, nil)
    %{attests: entries, next_after: last_attest_id(entries), has_more_after: false}
  end

  defp attest_page(db, assignment_id, cursor, limit, true) do
    fetched = list_attests(db, assignment_id, cursor, limit + 1)
    entries = Enum.take(fetched, limit)

    %{
      attests: entries,
      next_after: last_attest_id(entries),
      has_more_after: length(fetched) > limit
    }
  end

  defp last_attest_id([]), do: nil
  defp last_attest_id(entries), do: List.last(entries).id

  defp attest_limit(nil), do: {:ok, nil}
  defp attest_limit(n) when is_integer(n) and n > 0, do: {:ok, min(n, @max_attest_page)}
  defp attest_limit(_), do: {:error, error("invalid", "--limit takes a positive integer")}

  defp attest_after(_db, _assignment_id, nil), do: {:ok, nil}

  defp attest_after(db, assignment_id, after_id) when is_binary(after_id) and after_id != "" do
    case attest_cursor(db, assignment_id, after_id) do
      :error -> {:error, error("cursor_not_found", "unknown attest cursor: #{after_id}")}
      cursor -> {:ok, cursor}
    end
  end

  defp attest_after(_db, _assignment_id, _after_id),
    do: {:error, error("invalid", "--after takes an attest id")}

  defp create_assignment(txn, call, owner, key, files, verb) do
    case Txn.q(txn, "SELECT state, harness, provider FROM sessions WHERE sessionKey = ?1", [
           call.session_key
         ]) do
      [["retired", _harness, _provider]] ->
        error("session_retired", "assignments require an active holder session")

      [["active", harness, provider]] ->
        # F7 amendment: dispatch persists workItemId exactly as assign does.
        supplied_work_item_id = call.params[:work_item_id]

        work_item_id =
          case resolve_optional_in_txn(txn, :work_item, supplied_work_item_id) do
            {:ok, id} ->
              id_resolved(call, txn, :work_item, id)
              id

            :unknown ->
              raise UnknownWorkItem, work_item_id: supplied_work_item_id

            {:ambiguous, error} ->
              throw({:id_resolution, error})
          end

        case work_item_id do
          nil ->
            :ok

          work_item_id ->
            if Txn.q(txn, "SELECT 1 FROM work_items WHERE id = ?1", [work_item_id]) == [],
              do: raise(UnknownWorkItem, work_item_id: work_item_id)
        end

        supplied_review_id =
          if verb == "assign", do: call.params[:reviews_assignment_id], else: nil

        reviews_assignment_id =
          case resolve_optional_in_txn(txn, :assignment, supplied_review_id) do
            {:ok, id} ->
              id_resolved(call, txn, :assignment, id)
              id

            :unknown ->
              raise UnknownReviewTarget, assignment_id: supplied_review_id

            {:ambiguous, error} ->
              throw({:id_resolution, error})
          end

        if reviews_assignment_id do
          case Txn.q(
                 txn,
                 "SELECT reviewsAssignmentId FROM assignments WHERE id = ?1",
                 [reviews_assignment_id]
               ) do
            [] ->
              raise UnknownReviewTarget, assignment_id: reviews_assignment_id

            [[nil]] ->
              :ok

            [[_reviews_assignment_id]] ->
              throw(:review_of_review)
          end
        end

        if reviews_assignment_id do
          reviewed_item_id =
            resolve_work_item_id_in_txn(txn, reviews_assignment_id, MapSet.new())

          if not is_nil(work_item_id) and work_item_id != reviewed_item_id do
            throw(:review_item_conflict)
          end
        end

        # In-txn state='open' INTERLOCK (r4-F1): the pre-statute guard and this
        # insert are different transactions; a disposition committing between
        # them must not let a terminal item acquire an open assignment. The
        # optional probe seam drives a concurrent disposition between the checks.
        assert_work_item_open!(txn, call, work_item_id)

        id = id("asg_")
        now = now()
        {opened_user, opened_session} = opener(call.principal)

        Txn.q(
          txn,
          """
          INSERT INTO assignments
            (id, subject, holderKey, holderRole, holderFallback, openedByUser,
             openedBySession, openedAt, workItemId, reviewsAssignmentId,
             holderHarness, holderProvider)
          VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12)
          """,
          [
            id,
            call.params.subject,
            call.session_key,
            call.target_role,
            if(call.role_fallback, do: 1, else: 0),
            opened_user,
            opened_session,
            now,
            work_item_id,
            reviews_assignment_id,
            harness,
            provider
          ]
        )

        Txn.q(
          txn,
          "INSERT INTO assignment_effects (assignmentId, effectKind) VALUES (?1, ?2)",
          [id, effective_effect_kind(reviews_assignment_id, call.params[:effect_kind])]
        )

        Txn.q(
          txn,
          "INSERT INTO assignment_priorities (assignmentId, priority) VALUES (?1, ?2)",
          [id, inherited_priority_in_txn(txn, work_item_id)]
        )

        Enum.each(files, fn path ->
          Txn.q(
            txn,
            "INSERT INTO assignment_files (assignmentId, path) VALUES (?1, ?2)",
            [id, path]
          )
        end)

        supervision_transition!(txn, :armed, %{
          kind: "assignment_open",
          assignment_id: id,
          opened_at: now,
          supervision_interval_ms: call.supervision_interval_ms,
          principal: principal_id(call.principal)
        })

        entitlement_trigger = liveness_trigger!(txn, {:assignment, id})

        # This assign/dispatch routed the item: cancel bracket 1 (and bracket 2
        # if a prior last-close armed a slate wake — the slate is no longer clear).
        if work_item_id do
          Tightbeam.WorkItems.cancel_brackets_in_txn(txn, work_item_id, %{
            causal_source: %{kind: "assignment_transition", id: id},
            outcome: %{
              kind: "disposition",
              disposition_kind: "assignment_transition",
              disposition_id: id,
              liveness_trigger: entitlement_trigger
            }
          })
        end

        if key do
          # ownerUserId and sessionKey are historical column names: for assign
          # they store the prefixed principal id and assignment id respectively.
          Txn.q(
            txn,
            "INSERT INTO wire_idempotency (ownerUserId, operation, idempotencyKey, sessionKey) VALUES (?1, 'assign', ?2, ?3)",
            [owner, key, id]
          )
        end

        assignment = fetch_assignment!(txn, id)
        append_assignment_marker(txn, assignment, :opened)
        assignment

      [] ->
        error("not_found", "unknown sessionKey: #{call.session_key}")
    end
  catch
    {:id_resolution, error} ->
      error

    {:work_item_not_open, work_item_id} ->
      error("work_item_not_open", "work item #{work_item_id} is not open")

    :review_item_conflict ->
      error(
        "review_item_conflict",
        "a review assignment must belong to the item it reviews"
      )

    :review_of_review ->
      error("review_of_review", "a review assignment cannot itself be reviewed")
  end

  defp resolve_optional_in_txn(_txn, _type, nil), do: {:ok, nil}

  defp resolve_optional_in_txn(txn, type, supplied),
    do: IdPrefix.resolve_in_txn(txn, type, supplied)

  defp resolve_work_item_id_in_txn(txn, assignment_id, visited) do
    if MapSet.member?(visited, assignment_id) do
      nil
    else
      case Txn.q(
             txn,
             "SELECT workItemId, reviewsAssignmentId FROM assignments WHERE id = ?1",
             [assignment_id]
           ) do
        [[work_item_id, _reviews_assignment_id]] when not is_nil(work_item_id) ->
          work_item_id

        [[nil, nil]] ->
          nil

        [[nil, reviews_assignment_id]] ->
          resolve_work_item_id_in_txn(
            txn,
            reviews_assignment_id,
            MapSet.put(visited, assignment_id)
          )

        [] ->
          nil
      end
    end
  end

  defp assert_work_item_open!(_txn, _call, nil), do: :ok

  defp assert_work_item_open!(txn, call, work_item_id) do
    case Map.get(call, :on_work_item_interlock) do
      fun when is_function(fun, 1) -> fun.(txn)
      _ -> :ok
    end

    case Tightbeam.WorkItems.state_in_txn(txn, work_item_id) do
      "open" -> :ok
      _ -> throw({:work_item_not_open, work_item_id})
    end
  end

  defp attest_in_txn(txn, call) do
    if call.params[:kind] == "verdict",
      do: verdict_in_txn(txn, call),
      else: lifecycle_attest_in_txn(txn, call)
  end

  defp lifecycle_attest_in_txn(txn, call) do
    assignment_id = call.params[:assignment_id]

    case fetch_assignment(txn, assignment_id) do
      nil ->
        error("unknown_assignment", "unknown assignment: #{assignment_id}")

      %{holderKey: holder} = assignment ->
        cond do
          not match?({:session, ^holder}, call.principal) ->
            error("not_holder", "assignment is held by session #{holder}")

          assignment.state != "open" ->
            assignment_closed()

          true ->
            with :ok <- valid_kind(call.params[:kind]),
                 :ok <- valid_note(call.params[:note]),
                 :ok <- absent_verdict_kind(call.params[:verdict_kind]) do
              if Txn.q(txn, "SELECT 1 FROM assignments WHERE id = ?1 AND state = 'open'", [
                   assignment_id
                 ]) != [[1]],
                 do: raise(TransitionRace)

              attest = insert_attest(txn, call, assignment_id)

              if call.params.kind == "progress" do
                append_attest_marker(txn, attest)
                %{assignment: assignment, attest: attest}
              else
                outcome =
                  if call.params.kind == "completion", do: "completed", else: "surrendered"

                Txn.q(
                  txn,
                  """
                  UPDATE assignments SET state = 'closed', outcome = ?2, closedAt = ?3,
                    closedBySession = ?4, closingAttestId = ?5
                  WHERE id = ?1 AND state = 'open'
                  """,
                  [assignment_id, outcome, attest.ts, holder, attest.id]
                )

                if Txn.changes(txn) != 1, do: raise(TransitionRace)
                closed_assignment = fetch_assignment!(txn, assignment_id)
                Tightbeam.WorkItems.arm_slate_in_txn(txn, closed_assignment.workItemId)

                liveness_trigger =
                  disposition_liveness_trigger!(txn, closed_assignment.workItemId)

                supervision_transition!(txn, :terminal_disposition, %{
                  kind: "terminal_disposition",
                  assignment_id: assignment_id,
                  cause: "terminal_disposition",
                  principal: principal_id(call.principal),
                  requester_id: "tightbeam:assignments"
                })

                EffortCheckin.cancel_in_txn(
                  txn,
                  assignment_id,
                  assignment_disposition_command(
                    assignment_id,
                    "tightbeam:assignments",
                    liveness_trigger
                  )
                )

                append_attest_marker(txn, attest)
                append_assignment_marker(txn, closed_assignment, :closed)
                %{assignment: closed_assignment, attest: attest}
              end
            end
        end
    end
  end

  defp verdict_in_txn(txn, call) do
    assignment_id = call.params[:assignment_id]

    case fetch_assignment(txn, assignment_id) do
      nil ->
        error("unknown_assignment", "unknown assignment: #{assignment_id}")

      assignment ->
        cond do
          assignment.state != "open" ->
            assignment_closed()

          not is_nil(assignment.reviewsAssignmentId) and
              call.principal != {:session, assignment.holderKey} ->
            error("not_holder", "assignment is held by session #{assignment.holderKey}")

          true ->
            with :ok <- valid_verdict_kind(call.params[:verdict_kind]),
                 :ok <- valid_note(call.params[:note]) do
              if Txn.q(txn, "SELECT 1 FROM assignments WHERE id = ?1 AND state = 'open'", [
                   assignment_id
                 ]) != [[1]],
                 do: raise(TransitionRace)

              attest = insert_attest(txn, call, assignment_id)
              append_attest_marker(txn, attest)
              %{assignment: assignment, attest: attest}
            end
        end
    end
  end

  defp revoke_in_txn(txn, call) do
    assignment_id = call.params[:assignment_id]

    case fetch_assignment(txn, assignment_id) do
      nil ->
        error("unknown_assignment", "unknown assignment: #{assignment_id}")

      assignment ->
        cond do
          not revoke_allowed?(txn, call.principal, assignment) ->
            error("not_authorized", "assignment revocation requires its opener or an admin")

          assignment.state != "open" ->
            with :ok <- valid_revocation_reason(call.params[:reason]) do
              if assignment.outcome == "revoked" and
                   assignment.revocationReason == call.params[:reason] do
                Map.put(assignment, :revocation_replayed, true)
              else
                assignment_closed()
              end
            end

          true ->
            with :ok <- valid_revocation_reason(call.params[:reason]) do
              {closed_user, closed_session} = opener(call.principal)
              closed_at = now()

              Txn.q(
                txn,
                """
                INSERT INTO assignment_revocations
                  (id, assignmentId, revokedAt, revokedByUser, revokedBySession, reason)
                VALUES (?1, ?2, ?3, ?4, ?5, ?6)
                """,
                [
                  id("rev_"),
                  assignment_id,
                  closed_at,
                  closed_user,
                  closed_session,
                  call.params[:reason]
                ]
              )

              Txn.q(
                txn,
                """
                UPDATE assignments SET state = 'closed', outcome = 'revoked', closedAt = ?2,
                  closedByUser = ?3, closedBySession = ?4
                WHERE id = ?1 AND state = 'open'
                """,
                [assignment_id, closed_at, closed_user, closed_session]
              )

              if Txn.changes(txn) != 1, do: raise(TransitionRace)
              revoked_assignment = fetch_assignment!(txn, assignment_id)
              Tightbeam.WorkItems.arm_slate_in_txn(txn, revoked_assignment.workItemId)

              liveness_trigger =
                disposition_liveness_trigger!(txn, revoked_assignment.workItemId)

              supervision_transition!(txn, :terminal_disposition, %{
                kind: "terminal_disposition",
                assignment_id: assignment_id,
                cause: "terminal_disposition",
                principal: principal_id(call.principal),
                requester_id: "tightbeam:assignments"
              })

              EffortCheckin.cancel_in_txn(
                txn,
                assignment_id,
                assignment_disposition_command(
                  assignment_id,
                  "tightbeam:assignments",
                  liveness_trigger
                )
              )

              append_assignment_marker(txn, revoked_assignment, :revoked)
              revoked_assignment
            end
        end
    end
  end

  defp append_attest_marker(_txn, %{bySession: nil}), do: :ok

  defp append_attest_marker(txn, attest) do
    text =
      case attest.kind do
        "verdict" ->
          "[verdict filed: #{attest.verdictKind} on #{attest.assignmentId}]"

        "completion" ->
          "[completion filed on #{attest.assignmentId}]"

        "surrender" ->
          "[surrendered #{attest.assignmentId} — needs user input]"

        "progress" ->
          "[progress filed on #{attest.assignmentId}]"
      end

    append_notice(txn, attest.bySession, text)
  end

  defp append_assignment_marker(txn, assignment, :opened) do
    append_notice(txn, assignment.holderKey, "[assignment opened: #{assignment.id}]")
  end

  defp append_assignment_marker(txn, assignment, :closed) do
    append_notice(
      txn,
      assignment.holderKey,
      "[assignment closed: #{assignment.id} — #{assignment.outcome}]"
    )
  end

  defp append_assignment_marker(txn, assignment, :revoked) do
    append_notice(txn, assignment.holderKey, "[assignment revoked: #{assignment.id}]")
  end

  # Carries actor + reason (Sol xhigh review, finding 6) — the plain
  # `[assignment reopened: <id>]` marker the other lifecycle markers use leaves
  # an agent reading its own transcript unable to answer "who reopened this and
  # why" without a separate read, even though the database has both answers.
  defp append_assignment_marker(txn, assignment, :reopened, actor, reason) do
    append_notice(
      txn,
      assignment.holderKey,
      "[assignment reopened: #{assignment.id} by #{actor} — #{reason}]"
    )
  end

  defp append_notice(txn, session_key, text) do
    best_effort(fn -> Projection.append_substrate_in_txn(txn, session_key, text) end)
  end

  defp revoke_allowed?(txn, {:user, user}, assignment) do
    assignment.openedByUser == user or
      match?([[1]], Txn.q(txn, "SELECT isAdmin FROM users WHERE userId = ?1", [user]))
  end

  defp revoke_allowed?(_txn, {:session, session}, assignment),
    do: assignment.openedBySession == session

  defp insert_attest(txn, call, assignment_id) do
    {by_user, by_session} = opener(call.principal)
    {by_harness, by_provider} = verdict_author_family(txn, call.params.kind, by_session)

    insert_attest_row(txn, %{
      assignment_id: assignment_id,
      kind: call.params.kind,
      verdict_kind: call.params[:verdict_kind],
      note: call.params[:note],
      by_session: by_session,
      by_user: by_user,
      producer: nil,
      producer_command: nil,
      by_harness: by_harness,
      by_provider: by_provider,
      commit_refs: call.params[:commit_refs]
    })
  end

  defp insert_attest_row(txn, attrs) do
    id = id("att_")
    ts = now()

    Txn.q(
      txn,
      """
      INSERT INTO attests
        (id, assignmentId, kind, verdictKind, note, bySession, byUser, producer,
         producerCommand, byHarness, byProvider, commitRefs, ts)
      SELECT ?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13
      WHERE EXISTS (SELECT 1 FROM assignments WHERE id = ?2 AND state = 'open')
      """,
      [
        id,
        attrs.assignment_id,
        attrs.kind,
        attrs.verdict_kind,
        attrs.note,
        attrs.by_session,
        attrs.by_user,
        attrs.producer,
        attrs.producer_command,
        attrs.by_harness,
        attrs.by_provider,
        attrs[:commit_refs] && JSON.encode!(attrs.commit_refs),
        ts
      ]
    )

    if Txn.changes(txn) != 1, do: raise(TransitionRace)

    attest([
      id,
      attrs.assignment_id,
      attrs.kind,
      attrs.verdict_kind,
      attrs.note,
      attrs.by_session,
      attrs.by_user,
      attrs.producer,
      attrs.producer_command,
      attrs.by_harness,
      attrs.by_provider,
      attrs[:commit_refs] && JSON.encode!(attrs.commit_refs),
      ts
    ])
  end

  defp verdict_author_family(_txn, kind, _by_session) when kind != "verdict", do: {nil, nil}
  defp verdict_author_family(_txn, "verdict", nil), do: {nil, nil}

  defp verdict_author_family(txn, "verdict", by_session) do
    case Txn.q(txn, "SELECT harness, provider FROM sessions WHERE sessionKey = ?1", [by_session]) do
      [[harness, provider]] -> {harness, provider}
    end
  end

  defp idempotency_assignment(txn, owner, key) do
    case Txn.q(
           txn,
           "SELECT sessionKey FROM wire_idempotency WHERE ownerUserId = ?1 AND operation = 'assign' AND idempotencyKey = ?2",
           [owner, key]
         ) do
      [[assignment_id]] -> assignment_id
      [] -> nil
    end
  end

  defp replayed_assignment(_db, %{params: %{idempotency_key: nil}}), do: nil

  defp replayed_assignment(db, call) do
    {:ok, rows} =
      DB.query(
        db,
        """
        SELECT #{columns()} FROM assignments
        WHERE id=(
          SELECT sessionKey FROM wire_idempotency
          WHERE ownerUserId=?1 AND operation='assign' AND idempotencyKey=?2
        )
        """,
        [principal_id(call.principal), call.params[:idempotency_key]]
      )

    case rows do
      [row] -> assignment(row)
      [] -> nil
    end
  end

  defp fetch_assignment(txn, id) do
    case Txn.q(txn, "SELECT #{columns()} FROM assignments WHERE id = ?1", [id]) do
      [row] -> assignment(row)
      [] -> nil
    end
  end

  defp fetch_assignment!(txn, id), do: fetch_assignment(txn, id) || raise("missing assignment")

  defp principal_allowed({:process, _}, _verb),
    do: error("process_denied", "process principals cannot use assignment verbs")

  defp principal_allowed({:remedy, %{action: "assign"}}, "assign"), do: :ok

  defp principal_allowed({:remedy, _}, verb),
    do: principal_allowed({:process, "tightbeam"}, verb)

  defp principal_allowed(nil, _verb),
    do:
      error(
        "principal_required",
        "assignment verbs require a user credential or a session token"
      )

  defp principal_allowed({kind, _}, _verb) when kind in [:session, :user], do: :ok

  defp valid_subject(subject) when is_binary(subject) do
    if String.length(subject) in 1..2000 and String.trim(subject) != "",
      do: :ok,
      else: error("invalid_subject", "subject must be 1..2000 non-blank characters")
  end

  defp valid_subject(_),
    do: error("invalid_subject", "subject must be 1..2000 non-blank characters")

  defp valid_effect_kind(nil), do: :ok
  defp valid_effect_kind(kind) when kind in @effect_kinds, do: :ok

  defp valid_effect_kind(_),
    do:
      error("invalid_effect_kind", "effectKind must be one of #{Enum.join(@effect_kinds, ", ")}")

  defp effective_effect_kind(reviews_assignment_id, _requested)
       when not is_nil(reviews_assignment_id),
       do: "review"

  defp effective_effect_kind(nil, nil), do: "code"
  defp effective_effect_kind(nil, requested), do: requested

  defp valid_supervision_interval(interval) when is_integer(interval) and interval > 0,
    do: :ok

  defp valid_supervision_interval(_interval),
    do:
      error(
        "invalid_supervision_interval",
        "supervisionIntervalMs must be a positive integer"
      )

  defp valid_brief(brief) when is_binary(brief) and brief != "", do: :ok
  defp valid_brief(_), do: error("invalid", "a dispatch must carry a brief")

  defp normalize_root_validation(root) do
    case EffortCheckin.valid_workdir_root(root) do
      :ok -> :ok
      {:error, error} -> error
    end
  end

  defp effort_config(db, call) do
    defaults = %{
      base_dir: Application.get_env(:tightbeam, :base_dir, System.tmp_dir!()),
      db: db,
      port: Application.get_env(:tightbeam, :port, 11_373),
      effort_checkin_horizon_ms:
        Application.get_env(:tightbeam, :effort_checkin_horizon_ms, 14_400_000)
    }

    Map.merge(defaults, Map.get(call, :effort_config, %{}))
  end

  defp valid_note(nil), do: :ok

  defp valid_note(note) when is_binary(note) do
    if String.length(String.trim(note)) in 1..2000,
      do: :ok,
      else: error("invalid_note", "note must be 1..2000 non-blank characters")
  end

  defp valid_note(_), do: error("invalid_note", "note must be text")

  defp valid_commit_refs(_db, _kind, nil), do: :ok

  defp valid_commit_refs(db, kind, refs)
       when kind in ["completion", "verdict"] and is_list(refs) do
    Enum.reduce_while(refs, :ok, fn ref, :ok ->
      case validate_commit_ref(db, ref) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp valid_commit_refs(_db, kind, _refs) when kind in ["completion", "verdict"],
    do: error("invalid_commit_refs", "commitRefs must be an array")

  defp valid_commit_refs(_db, _kind, _refs),
    do:
      error(
        "invalid_commit_refs",
        "commitRefs are only valid on producing completion or review-link verdict attests"
      )

  defp commit_ref_filing_allowed(db, call) do
    case {call.params[:kind], call.params[:commit_refs]} do
      {_kind, nil} ->
        :ok

      {kind, _refs} when kind in ["completion", "verdict"] ->
        supplied = call.params[:assignment_id]

        case IdPrefix.resolve(db, :assignment, supplied) do
          {:ok, id} ->
            commit_ref_filing_allowed_for_assignment(
              db,
              put_in(call, [:params, :assignment_id], id),
              kind
            )

          :unknown ->
            error("unknown_assignment", "unknown assignment: #{supplied}")

          {:ambiguous, error} ->
            error
        end

      {_kind, _refs} ->
        :ok
    end
  end

  defp commit_ref_filing_allowed_for_assignment(db, call, kind) do
    assignment_id = call.params[:assignment_id]

    {:ok, rows} =
      DB.query(
        db,
        "SELECT holderKey, state, reviewsAssignmentId FROM assignments WHERE id = ?1",
        [assignment_id]
      )

    commit_ref_filing_allowed_for_rows(rows, call, kind, assignment_id)
  end

  defp commit_ref_filing_allowed_in_txn(txn, call) do
    case {call.params[:kind], call.params[:commit_refs]} do
      {_kind, nil} ->
        :ok

      {kind, _refs} when kind in ["completion", "verdict"] ->
        commit_ref_filing_allowed_for_assignment_in_txn(txn, call, kind)

      {_kind, _refs} ->
        :ok
    end
  end

  defp commit_ref_filing_allowed_for_assignment_in_txn(txn, call, kind) do
    assignment_id = call.params[:assignment_id]

    rows =
      Txn.q(
        txn,
        "SELECT holderKey, state, reviewsAssignmentId FROM assignments WHERE id = ?1",
        [assignment_id]
      )

    commit_ref_filing_allowed_for_rows(rows, call, kind, assignment_id)
  end

  defp commit_ref_filing_allowed_for_rows(rows, call, kind, assignment_id) do
    case rows do
      [] ->
        error("unknown_assignment", "unknown assignment: #{assignment_id}")

      [[holder, _state, _reviews_assignment_id]]
      when kind == "completion" and call.principal != {:session, holder} ->
        error("not_holder", "assignment is held by session #{holder}")

      [[_holder, state, _reviews_assignment_id]]
      when kind == "completion" and state != "open" ->
        assignment_closed()

      [[_holder, "open", reviews_assignment_id]]
      when kind == "completion" and not is_nil(reviews_assignment_id) ->
        error(
          "invalid_commit_refs",
          "commitRefs are not allowed on non-producing completion attests"
        )

      [[_holder, _state, nil]] when kind == "verdict" ->
        error(
          "invalid_commit_refs",
          "commitRefs on verdict attests require a review-linked assignment"
        )

      [[_holder, _state, _reviews_assignment_id]] ->
        :ok
    end
  end

  defp validate_commit_ref(db, ref) when is_map(ref) do
    normalized = Map.new(ref, fn {key, value} -> {to_string(key), value} end)

    with ["commit", "repo"] <- normalized |> Map.keys() |> Enum.sort(),
         repo when is_binary(repo) <- normalized["repo"],
         commit when is_binary(commit) <- normalized["commit"],
         [host, path] <- String.split(repo, ":", parts: 2),
         true <- host != "" and Path.type(path) == :absolute,
         {_output, 0} <- run_git_cat_file(db, host, path, commit) do
      :ok
    else
      _ -> error("unverifiable_commit_ref", "commitRefs contains an unverifiable commit")
    end
  end

  defp validate_commit_ref(_db, _ref),
    do: error("unverifiable_commit_ref", "commitRefs contains an unverifiable commit")

  defp run_git_cat_file(db, host, path, commit) do
    base_dir =
      Application.get_env(
        :tightbeam,
        :base_dir,
        Path.join(System.user_home!(), ".tightbeam")
      )

    case Placement.hosts(base_dir, db)[host] do
      %{ssh: nil} ->
        run_commit_ref_command(
          "git",
          ["-C", path, "cat-file", "-e", "#{commit}^{commit}"],
          stderr_to_stdout: true
        )

      %{ssh: destination} when is_binary(destination) ->
        command =
          ["git", "-C", path, "cat-file", "-e", "#{commit}^{commit}"]
          |> Enum.map_join(" ", &shell_quote/1)

        run_commit_ref_command(
          "ssh",
          Support.ssh_opts() ++ [destination, "sh", "-c", shell_quote(command)],
          stderr_to_stdout: true
        )

      nil ->
        {:error, :unknown_host}
    end
  rescue
    _ -> {:error, :verification_failed}
  catch
    :exit, _ -> {:error, :verification_failed}
  end

  defp run_commit_ref_command(executable, args, opts) do
    runner = Application.get_env(:tightbeam, :commit_ref_command, &System.cmd/3)
    runner.(executable, args, opts)
  end

  defp shell_quote(value), do: "'" <> String.replace(value, "'", "'\\''") <> "'"

  defp valid_kind(kind) when kind in ["progress", "completion", "surrender"], do: :ok
  defp valid_kind(_), do: error("invalid_kind", "kind must be progress, completion, or surrender")

  defp absent_verdict_kind(nil), do: :ok

  defp absent_verdict_kind(_),
    do: error("invalid_verdict_kind", "verdictKind is only valid when kind is verdict")

  defp valid_verdict_kind(nil),
    do: error("missing_verdict_kind", "verdictKind is required when kind is verdict")

  defp valid_verdict_kind(kind) when is_binary(kind) do
    if String.length(kind) in 1..64 and Regex.match?(~r/^[a-z0-9][a-z0-9-]*$/, kind),
      do: :ok,
      else:
        error(
          "invalid_verdict_kind",
          "verdictKind must be 1..64 lowercase letters, digits, or hyphens"
        )
  end

  defp valid_verdict_kind(_),
    do: error("invalid_verdict_kind", "verdictKind must be text")

  defp valid_state(nil), do: :ok
  defp valid_state(state) when state in ["open", "closed", "all"], do: :ok
  defp valid_state(_), do: error("invalid_state_filter", "state must be open, closed, or all")

  defp valid_idempotency_key(nil), do: :ok

  defp valid_idempotency_key(key) when is_binary(key) do
    if String.trim(key) == "" or String.length(key) > 200,
      do:
        error(
          "invalid_idempotency_key",
          "idempotencyKey must be non-blank and at most 200 characters"
        ),
      else: :ok
  end

  defp valid_idempotency_key(_),
    do: error("invalid_idempotency_key", "idempotencyKey must be text")

  defp valid_files(nil), do: {:ok, []}

  defp valid_files(files) when is_list(files) do
    if Enum.all?(files, fn
         path when is_binary(path) -> String.length(String.trim(path)) in 1..2000
         _ -> false
       end) do
      {:ok, Enum.uniq(files)}
    else
      error("invalid_files", "files must contain non-blank paths of at most 2000 characters")
    end
  end

  defp valid_files(_),
    do: error("invalid_files", "files must be an array of paths")

  defp assignment_files("assign", params), do: valid_files(params[:files])
  defp assignment_files(_verb, _params), do: {:ok, []}

  defp open_assignments_touching_query(paths, exclude_id) do
    placeholders =
      paths
      |> Enum.with_index(1)
      |> Enum.map_join(", ", fn {_path, index} -> "?#{index}" end)

    exclude_clause =
      if exclude_id do
        " AND a.id != ?#{length(paths) + 1}"
      else
        ""
      end

    params = if exclude_id, do: paths ++ [exclude_id], else: paths

    {
      "SELECT DISTINCT a.id FROM assignments AS a JOIN assignment_files AS f ON f.assignmentId = a.id WHERE a.state = 'open' AND f.path IN (#{placeholders})#{exclude_clause} ORDER BY a.id",
      params
    }
  end

  defp principal_id({:user, user}), do: "user:" <> user
  defp principal_id({:session, session}), do: "session:" <> session
  defp principal_id({:remedy, %{owner: owner}}), do: "user:" <> owner

  defp supervision_transition!(txn, expected, observation) do
    case Supervision.transition_in_txn(txn, observation) do
      ^expected -> expected
      {:error, reason} -> raise "supervision transition refused: #{inspect(reason)}"
      other -> raise "invalid supervision transition result: #{inspect(other)}"
    end
  end

  defp disposition_liveness_trigger!(_txn, nil), do: nil

  defp disposition_liveness_trigger!(txn, work_item_id) do
    case Supervision.liveness_trigger_in_txn(txn, {:work_item, work_item_id}) do
      {:ok, trigger} when is_map(trigger) -> trigger
      :none -> raise "open work item #{work_item_id} has no liveness trigger"
      {:error, reason} -> raise "invalid liveness trigger: #{inspect(reason)}"
    end
  end

  defp liveness_trigger!(txn, primary) do
    case Supervision.liveness_trigger_in_txn(txn, primary) do
      {:ok, trigger} when is_map(trigger) -> trigger
      :none -> raise "#{inspect(primary)} has no liveness trigger"
      {:error, reason} -> raise "invalid liveness trigger: #{inspect(reason)}"
    end
  end

  defp assignment_disposition_command(assignment_id, requester_id, liveness_trigger) do
    outcome = %{
      kind: "disposition",
      disposition_kind: "assignment_transition",
      disposition_id: assignment_id
    }

    %{
      requester: %{kind: "process", id: requester_id},
      reason_kind: "obligation_disposed",
      causal_source: %{kind: "assignment_transition", id: assignment_id},
      outcome:
        if(is_map(liveness_trigger),
          do: Map.put(outcome, :liveness_trigger, liveness_trigger),
          else: outcome
        )
    }
  end

  defp opener({:user, user}), do: {user, nil}
  defp opener({:session, session}), do: {nil, session}
  defp opener({:remedy, %{owner: owner}}), do: {owner, nil}

  defp assignment_closed, do: error("assignment_closed", "assignment is already closed")
  defp error(code, message), do: %{code: code, message: message}

  defp notify(call, key, first, second) do
    Map.get(call, key, fn _, _ -> :ok end).(first, second)
  end

  defp best_effort(fun) do
    try do
      fun.()
    rescue
      _ -> :ok
    catch
      _, _ -> :ok
    end
  end

  defp best_effort_value(fun) do
    try do
      {:ok, fun.()}
    rescue
      _ -> :error
    catch
      _, _ -> :error
    end
  end

  defp id_resolved(call, txn, type, id) do
    case Map.get(call, :on_id_resolved_in_txn) do
      fun when is_function(fun, 3) -> fun.(txn, type, id)
      _ -> :ok
    end
  end

  defp transaction(db, fun) do
    case DB.transaction(db, fun) do
      {:ok, result} -> result
      {:error, error} -> raise error
    end
  end

  defp id(prefix), do: prefix <> Tightbeam.Id.uuid4()

  defp now, do: System.system_time(:millisecond)

  defp columns do
    "id, subject, holderKey, holderRole, holderFallback, openedByUser, openedBySession, " <>
      "openedAt, state, outcome, closedAt, closedByUser, closedBySession, closingAttestId, " <>
      "(SELECT reason FROM assignment_revocations r WHERE r.assignmentId = assignments.id " <>
      "AND r.revokedAt IS assignments.closedAt AND r.revokedByUser IS assignments.closedByUser " <>
      "AND r.revokedBySession IS assignments.closedBySession ORDER BY r.id DESC LIMIT 1)" <>
      ", workItemId, reviewsAssignmentId, holderHarness, holderProvider, " <>
      "COALESCE((SELECT effectKind FROM assignment_effects WHERE assignmentId = assignments.id), " <>
      "CASE WHEN reviewsAssignmentId IS NULL THEN 'code' ELSE 'review' END), " <>
      "COALESCE((SELECT priority FROM assignment_priorities WHERE assignmentId=assignments.id), " <>
      "(SELECT priority FROM work_item_priorities WHERE workItemId=assignments.workItemId), " <>
      "CAST(COALESCE((SELECT value FROM org_settings WHERE key='default-priority'),'4') AS INTEGER))"
  end

  defp assignment([
         id,
         subject,
         holder_key,
         holder_role,
         holder_fallback,
         opened_by_user,
         opened_by_session,
         opened_at,
         state,
         outcome,
         closed_at,
         closed_by_user,
         closed_by_session,
         closing_attest_id,
         revocation_reason,
         work_item_id,
         reviews_assignment_id,
         holder_harness,
         holder_provider,
         effect_kind,
         priority
       ]) do
    %{
      id: id,
      subject: subject,
      holderKey: holder_key,
      holderRole: holder_role,
      holderFallback: holder_fallback == 1,
      openedByUser: opened_by_user,
      openedBySession: opened_by_session,
      openedAt: opened_at,
      state: state,
      outcome: outcome,
      closedAt: closed_at,
      closedByUser: closed_by_user,
      closedBySession: closed_by_session,
      closingAttestId: closing_attest_id,
      revocationReason: revocation_reason,
      workItemId: work_item_id,
      reviewsAssignmentId: reviews_assignment_id,
      holderHarness: holder_harness,
      holderProvider: holder_provider,
      effectKind: effect_kind,
      priority: priority
    }
  end

  defp inherited_priority_in_txn(txn, work_item_id) do
    case Txn.q(
           txn,
           """
           SELECT COALESCE(
             (SELECT priority FROM work_item_priorities WHERE workItemId=?1),
             CAST(COALESCE((SELECT value FROM org_settings WHERE key='default-priority'),'4') AS INTEGER)
           )
           """,
           [work_item_id]
         ) do
      [[priority]] -> priority
    end
  end

  defp attest([
         id,
         assignment_id,
         kind,
         verdict_kind,
         note,
         by_session,
         by_user,
         producer,
         producer_command,
         by_harness,
         by_provider,
         commit_refs,
         ts
       ]) do
    %{
      id: id,
      assignmentId: assignment_id,
      kind: kind,
      verdictKind: verdict_kind,
      note: note,
      bySession: by_session,
      byUser: by_user,
      producer: producer,
      producerCommand: producer_command,
      byHarness: by_harness,
      byProvider: by_provider,
      commitRefs: commit_refs && JSON.decode!(commit_refs),
      ts: ts
    }
  end

  defp reopening([
         id,
         assignment_id,
         ts,
         reopened_by_user,
         reopened_by_session,
         reason,
         prior_outcome,
         prior_closed_at,
         prior_closed_by_user,
         prior_closed_by_session,
         prior_closing_attest_id
       ]) do
    %{
      id: id,
      assignmentId: assignment_id,
      ts: ts,
      reopenedByUser: reopened_by_user,
      reopenedBySession: reopened_by_session,
      reason: reason,
      priorOutcome: prior_outcome,
      priorClosedAt: prior_closed_at,
      priorClosedByUser: prior_closed_by_user,
      priorClosedBySession: prior_closed_by_session,
      priorClosingAttestId: prior_closing_attest_id
    }
  end
end
