defmodule Tightbeam.Escalation do
  @moduledoc """
  Durable decision requests and raiser-scoped escalation waivers.

  `resolve/3` is an effect-free gate read. `escalate/4` owns request opening,
  while `consume/2` is the per-ruling verb-edge CAS. A caller consuming a
  batch must fail closed if any CAS loses; earlier winners stay consumed.
  """

  alias Tightbeam.{ConditionFacts, DB, EventLog, IdPrefix, Org, Roles, Wakes}
  alias Tightbeam.DB.Txn
  alias Tightbeam.Firehose.Publisher

  @default_decision_deadline_ms 86_400_000

  # The `status` values a decision request row can hold — the schema CHECK's own set
  # (see @ddl). `list/4` accepts these plus the sentinel "all" (no status filter); any
  # other value is refused by `list_status/1` so a typo names the legal set instead of
  # silently filtering on a status that can never exist.
  @request_statuses ~w(open ruled consumed withdrawn superseded returned)
  @list_status_filters @request_statuses ++ ["all"]

  # Marks an `actionKey` as naming a CONDITION rather than one caller's action. Reserved
  # here because `digest/1` is a hex SHA-256 and can never collide with it.
  @episode_prefix "episode:"

  # WRITE-ONLY observability: one row per summons, including the attaches that write no
  # `decision_requests` row and would otherwise leave no trace at all. NOTHING READS THIS
  # TO DECIDE ANYTHING. An earlier version ordered recovery against these ids, which put a
  # decision input in the observability plane and violated §E3; ordering now lives in
  # `Tightbeam.RailEpisodes`, the single writer. Keep the row for legibility, and keep it
  # unread — if a closure ever needs to consult it, the closure is in the wrong place.
  @summon_kind "episode_summoned"

  @decision_request_ddl """
  CREATE TABLE IF NOT EXISTS decision_requests (
    id                TEXT PRIMARY KEY,
    kind              TEXT NOT NULL DEFAULT 'statute' CHECK (kind IN ('statute','effort','agent','operator')),
    raiserId          TEXT NOT NULL,
    raiserSessionKey  TEXT,
    ownerUserId       TEXT NOT NULL,
    assignmentId      TEXT,
    expecterSessionKey TEXT,
    expecterUserId    TEXT,
    lineageRung       INTEGER,
    effortGeneration  INTEGER,
    deadlineWakeId    TEXT,
    raisedAt          INTEGER NOT NULL,
    -- Nullable at the column: only the statute/effort arms carry sweep/deadline
    -- semantics and require it below. The agent arm pins it NULL, right beside
    -- every other adjudication column it refuses to borrow — a question has no
    -- deadline for the same reason it has no `decision` (Sol xhigh review,
    -- finding 1: a non-null `deadlineAt` on every row made an agent question
    -- indistinguishable from a statute/effort row to any generic
    -- `status = 'open' AND deadlineAt <= ?` sweep).
    deadlineAt        INTEGER,
    statuteName       TEXT,
    actionKey         TEXT,
    question          TEXT NOT NULL,
    options           TEXT,
    context           TEXT NOT NULL,
    status            TEXT NOT NULL CHECK (status IN ('open','ruled','consumed','withdrawn','superseded','answered','returned')),
    decision          TEXT,
    rationale         TEXT,
    ruledBy           TEXT,
    ruledViaSessionKey TEXT,
    ruledViaPrincipal TEXT,
    ruledViaSessionState TEXT CHECK (ruledViaSessionState IN ('known','none')),
    ruledAt           INTEGER,
    rulingFactId      INTEGER,
    consumedAt        INTEGER,
    parkWakeId        TEXT,
    withdrawnBy       TEXT,
    withdrawnReason   TEXT,
    withdrawnAt       INTEGER,
    -- THE AGENT ARM's own columns (coordination-fabric-v1 §7 `input-needed`
    -- carrier, GitHub #11). None of them is reachable from the other kinds
    -- — the fence is the standalone CHECK below, not a promise in a comment.
    askedOfRole       TEXT,
    answer            TEXT,
    answeredBy        TEXT,
    answeredAt        INTEGER,
    returnedBy        TEXT,
    returnReason      TEXT,
    returnedAt        INTEGER,
    CHECK (
      (kind = 'statute' AND statuteName IS NOT NULL AND actionKey IS NOT NULL
       AND expecterSessionKey IS NULL AND expecterUserId IS NULL
       AND lineageRung IS NULL AND effortGeneration IS NULL AND deadlineWakeId IS NULL
       AND deadlineAt IS NOT NULL
       AND ruledViaSessionKey IS NULL AND ruledViaPrincipal IS NULL
       AND ruledViaSessionState IS NULL
       AND (decision IS NULL OR decision IN ('allow','deny','waived')))
      OR
      (kind = 'effort' AND raiserId = 'process:tightbeam'
       AND raiserSessionKey IS NULL
       AND statuteName IS NULL AND actionKey IS NULL AND assignmentId IS NOT NULL
       AND ((expecterSessionKey IS NOT NULL) != (expecterUserId IS NOT NULL))
       AND lineageRung IS NOT NULL AND effortGeneration IS NOT NULL AND deadlineWakeId IS NOT NULL
       AND deadlineAt IS NOT NULL
       AND ruledViaSessionKey IS NULL AND ruledViaPrincipal IS NULL
       AND ruledViaSessionState IS NULL
       AND (decision IS NULL OR decision IN ('continue','dismiss')))
      OR
      -- THE THIRD ARM: one agent's question, filed at a named principal.
      --
      -- It borrows NONE of the statute arm's adjudication vocabulary, and that
      -- is the point rather than tidiness. `statuteName`/`actionKey` would make
      -- the row a rulable authorization; `decision` would make an answer a
      -- verdict of allow/deny/waived; `rulingFactId` would arm the condition-fact
      -- fan-out that unparks a halted call; `parkWakeId` would give the substrate
      -- a place to hang a wait. A question is none of those. The columns are
      -- pinned NULL here so no future code path can quietly start using one.
      --
      -- `consumedAt` NULL for the same reason: nothing SPENDS an answer. The
      -- asker reads it and decides for itself (adjudication-deletion amendment:
      -- the row is data its asker chooses to honor).
      --
      -- `deadlineAt` NULL too (Sol xhigh review, finding 1): a deadline is
      -- sweep/statute-arm vocabulary — something the substrate wakes up to act
      -- on unilaterally. A question has no such semantics; the asker holds its
      -- own obligation for as long as it likes (gate Q3's three exits are all
      -- the asker's own choice, never a clock's).
      (kind = 'agent'
       AND raiserSessionKey IS NOT NULL AND raiserId = 'session:' || raiserSessionKey
       -- Both stamped at file time, never inferred later: the asked SESSION and
       -- the accountable owner it resolved to (report-dirt law — if a shape must
       -- be known, stamp it at write time).
       AND expecterSessionKey IS NOT NULL AND expecterUserId IS NOT NULL
       AND statuteName IS NULL AND actionKey IS NULL
       AND decision IS NULL AND rationale IS NULL
       AND ruledBy IS NULL AND ruledViaSessionKey IS NULL
       AND ruledViaPrincipal IS NULL AND ruledViaSessionState IS NULL
       AND ruledAt IS NULL AND rulingFactId IS NULL
       AND consumedAt IS NULL AND parkWakeId IS NULL
       AND lineageRung IS NULL AND effortGeneration IS NULL AND deadlineWakeId IS NULL
       AND deadlineAt IS NULL
       -- `options` stays NULL here: the shared column's shape is a list of
       -- {label, allow|deny} — adjudication vocabulary again. A question's
       -- choices live in its text until they have a shape of their own.
       AND options IS NULL
       -- Its own three-word status vocabulary. `ruled`, `consumed` and
       -- `superseded` are the other arms' words and are unreachable here.
       AND status IN ('open','answered','withdrawn','returned')
       AND (status = 'answered') = (answer IS NOT NULL)
       AND (answer IS NULL) = (answeredBy IS NULL)
       AND (answer IS NULL) = (answeredAt IS NULL)
       AND (status = 'returned') = (returnReason IS NOT NULL)
       AND (returnReason IS NULL OR length(trim(returnReason)) > 0)
       AND (returnReason IS NULL) = (returnedBy IS NULL)
       AND (returnReason IS NULL) = (returnedAt IS NULL))
      OR
      (kind = 'operator'
       AND raiserSessionKey IS NOT NULL
       AND statuteName IS NULL AND actionKey IS NOT NULL
       AND expecterSessionKey IS NULL AND expecterUserId IS NULL
       AND lineageRung IS NULL AND effortGeneration IS NULL
       AND deadlineWakeId IS NULL AND deadlineAt IS NOT NULL
       AND options IS NOT NULL
       AND parkWakeId IS NULL
       AND status IN ('open','ruled','consumed','withdrawn','superseded')
       AND askedOfRole IS NULL AND answer IS NULL AND answeredBy IS NULL
       AND answeredAt IS NULL AND returnedBy IS NULL AND returnReason IS NULL
       AND returnedAt IS NULL
       AND (
         -- Terminal dirt must remain representable so migration and admitted
         -- reads can record evidence and refuse it without rewriting history.
         -- The future-write triggers below fence new ruled attribution.
         (status IN ('ruled','consumed'))
         OR
         (status NOT IN ('ruled','consumed')
          AND decision IS NULL AND rationale IS NULL
          AND ruledBy IS NULL AND ruledViaSessionKey IS NULL
          AND ruledViaPrincipal IS NULL AND ruledViaSessionState IS NULL
          AND ruledAt IS NULL AND rulingFactId IS NULL AND consumedAt IS NULL)
       ))
    ),
    -- The fence, stated once: the agent arm's columns and its terminal word do
    -- not exist for the other kinds. Without this a `statute` row could be
    -- marked `answered` and every kind-scoped reader above would miss it.
    CHECK (kind = 'agent' OR (askedOfRole IS NULL AND answer IS NULL AND
                              answeredBy IS NULL AND answeredAt IS NULL AND
                              returnedBy IS NULL AND returnReason IS NULL AND
                              returnedAt IS NULL AND
                              status NOT IN ('answered','returned'))),
    -- A ruled row IS the durable ruling. Do not let a partial transition turn
    -- a visible status into an assertion whose decision, ruler, or time is
    -- absent. The CAS writers set these three columns with `status` in their
    -- one UPDATE; a legacy row that cannot meet this shape is refused by the
    -- stamped rebuild below rather than repaired with invented history.
    CHECK (
      status <> 'ruled' OR
        (typeof(decision) = 'text' AND
           length(trim(decision, char(9) || char(10) || char(13) || ' ')) > 0
         AND typeof(ruledBy) = 'text' AND
           length(trim(ruledBy, char(9) || char(10) || char(13) || ' ')) > 0
         AND typeof(ruledAt) = 'integer')
    )
  );
  """

  @ddl @decision_request_ddl <>
         """
         CREATE INDEX IF NOT EXISTS decision_requests_owner
           ON decision_requests (ownerUserId, status);
         CREATE INDEX IF NOT EXISTS decision_requests_key
           ON decision_requests (raiserId, statuteName, actionKey);
         CREATE UNIQUE INDEX IF NOT EXISTS decision_requests_one_open
           ON decision_requests (raiserId, statuteName, actionKey)
           WHERE kind = 'statute' AND status = 'open';
         CREATE UNIQUE INDEX IF NOT EXISTS decision_requests_effort_generation
           ON decision_requests (assignmentId, effortGeneration) WHERE kind = 'effort';
         -- NOT unique: an agent may hold two questions at the same principal at once.
         -- Deduplicating them would be the substrate deciding two questions are one.
         CREATE INDEX IF NOT EXISTS decision_requests_asked
           ON decision_requests (expecterSessionKey, status) WHERE kind = 'agent';
         CREATE UNIQUE INDEX IF NOT EXISTS decision_requests_operator_open
           ON decision_requests (ownerUserId, raiserId, actionKey)
           WHERE kind = 'operator' AND status = 'open';

         CREATE TABLE IF NOT EXISTS decision_request_terminal_epoch (
           id INTEGER PRIMARY KEY CHECK (id = 0),
           schemaVersion TEXT NOT NULL,
           legacyRulingFactMaxId INTEGER NOT NULL,
           activatedAt INTEGER NOT NULL,
           cause TEXT NOT NULL,
           principal TEXT NOT NULL
         );

         CREATE TABLE IF NOT EXISTS decision_request_integrity_evidence (
           requestId TEXT NOT NULL,
           shapeDigest TEXT NOT NULL,
           schemaVersion TEXT NOT NULL,
           causeCode TEXT NOT NULL,
           failingFields TEXT NOT NULL,
           firstSurface TEXT NOT NULL,
           firstObservedAt INTEGER NOT NULL,
           observerPrincipal TEXT NOT NULL,
           PRIMARY KEY (requestId, shapeDigest)
         );
         CREATE TRIGGER IF NOT EXISTS decision_request_operator_terminal_insert
         BEFORE INSERT ON decision_requests
         WHEN NEW.kind = 'operator' AND NEW.status = 'ruled' AND
              (NEW.ruledViaPrincipal IS NULL OR
               NEW.ruledViaSessionState IS NULL OR
               NEW.ruledViaSessionState NOT IN ('known','none') OR
               (NEW.ruledViaSessionState = 'known' AND NEW.ruledViaSessionKey IS NULL) OR
               (NEW.ruledViaSessionState = 'none' AND NEW.ruledViaSessionKey IS NOT NULL))
         BEGIN
           SELECT RAISE(ABORT, 'decision_request_integrity_invalid');
         END;

         CREATE TRIGGER IF NOT EXISTS decision_request_operator_terminal_update
         BEFORE UPDATE OF status ON decision_requests
         WHEN NEW.kind = 'operator' AND NEW.status = 'ruled' AND OLD.status <> 'ruled' AND
              (NEW.ruledViaPrincipal IS NULL OR
               NEW.ruledViaSessionState IS NULL OR
               NEW.ruledViaSessionState NOT IN ('known','none') OR
               (NEW.ruledViaSessionState = 'known' AND NEW.ruledViaSessionKey IS NULL) OR
               (NEW.ruledViaSessionState = 'none' AND NEW.ruledViaSessionKey IS NOT NULL))
         BEGIN
           SELECT RAISE(ABORT, 'decision_request_integrity_invalid');
         END;

         CREATE TABLE IF NOT EXISTS escalation_waivers (
           id                TEXT PRIMARY KEY,
           raiserId          TEXT NOT NULL,
           statuteName       TEXT NOT NULL,
           grantedBy         TEXT NOT NULL,
           grantedAt         INTEGER NOT NULL,
           reason            TEXT,
           revokedBy         TEXT,
           revokedAt         INTEGER
         );
         CREATE INDEX IF NOT EXISTS escalation_waivers_lookup
           ON escalation_waivers (raiserId, statuteName, revokedAt);
         """

  @request_columns """
  id, kind, raiserId, raiserSessionKey, ownerUserId, assignmentId,
  expecterSessionKey, expecterUserId, lineageRung, effortGeneration, deadlineWakeId,
  raisedAt, deadlineAt,
  statuteName, actionKey, question, options, context, status, decision, rationale,
  ruledBy, ruledViaSessionKey, ruledViaPrincipal, ruledViaSessionState,
  ruledAt, rulingFactId, consumedAt, parkWakeId, withdrawnBy,
  withdrawnReason, withdrawnAt, askedOfRole, answer, answeredBy, answeredAt,
  returnedBy, returnReason, returnedAt
  """

  @legacy_request_columns """
  id, kind, raiserId, raiserSessionKey, ownerUserId, assignmentId,
  expecterSessionKey, expecterUserId, lineageRung, effortGeneration, deadlineWakeId,
  raisedAt, deadlineAt,
  statuteName, actionKey, question, options, context, status, decision, rationale,
  ruledBy, ruledAt, rulingFactId, consumedAt, parkWakeId, withdrawnBy,
  withdrawnReason, withdrawnAt, askedOfRole, answer, answeredBy, answeredAt,
  returnedBy, returnReason, returnedAt
  """

  @terminal_request_ddl String.replace(
                          @decision_request_ddl,
                          "decision_requests",
                          "decision_requests_terminal_v1",
                          global: false
                        )

  @ruled_decision_integrity_request_ddl String.replace(
                                          @decision_request_ddl,
                                          "decision_requests",
                                          "decision_requests_ruled_integrity_v1",
                                          global: false
                                        )

  @terminal_metadata_ddl """
  CREATE TABLE IF NOT EXISTS decision_request_terminal_epoch (
    id INTEGER PRIMARY KEY CHECK (id = 0),
    schemaVersion TEXT NOT NULL,
    legacyRulingFactMaxId INTEGER NOT NULL,
    activatedAt INTEGER NOT NULL,
    cause TEXT NOT NULL,
    principal TEXT NOT NULL
  );
  CREATE TABLE IF NOT EXISTS decision_request_integrity_evidence (
    requestId TEXT NOT NULL,
    shapeDigest TEXT NOT NULL,
    schemaVersion TEXT NOT NULL,
    causeCode TEXT NOT NULL,
    failingFields TEXT NOT NULL,
    firstSurface TEXT NOT NULL,
    firstObservedAt INTEGER NOT NULL,
    observerPrincipal TEXT NOT NULL,
    PRIMARY KEY (requestId, shapeDigest)
  );
  """

  @spec ensure_schema(DB.server()) :: :ok | {:error, term()}
  def ensure_schema(db \\ DB), do: DB.execute(db, @ddl)

  @doc false
  @spec ensure_terminal_epoch(DB.server()) :: :ok
  def ensure_terminal_epoch(db) do
    {:ok, :ok} =
      DB.transaction(db, fn txn ->
        ensure_terminal_epoch_in_txn(txn)
      end)

    :ok
  end

  @doc false
  @spec migrate_terminal_operator_decision_v1_in_txn(Txn.t()) :: :ok
  def migrate_terminal_operator_decision_v1_in_txn(txn) do
    :ok = Txn.exec(txn, @terminal_metadata_ddl)
    [[legacy_fact_max_id]] = Txn.q(txn, "SELECT COALESCE(MAX(id), 0) FROM condition_facts")
    :ok = preflight_terminal_operator_rows_in_txn(txn, legacy_fact_max_id)
    :ok = Txn.exec(txn, @terminal_request_ddl)

    Txn.q(
      txn,
      """
      INSERT INTO decision_requests_terminal_v1
        (#{@legacy_request_columns}, ruledViaSessionKey, ruledViaPrincipal, ruledViaSessionState)
      SELECT #{@legacy_request_columns}, NULL, NULL, NULL
      FROM decision_requests
      """
    )

    :ok = Txn.exec(txn, "DROP TABLE decision_requests")
    :ok = Txn.exec(txn, "ALTER TABLE decision_requests_terminal_v1 RENAME TO decision_requests")
    :ok = Txn.exec(txn, @ddl)
    :ok = insert_terminal_epoch_in_txn(txn, legacy_fact_max_id)
    :ok
  end

  @doc false
  @spec migrate_ruled_decision_integrity_v1_in_txn(Txn.t()) :: :ok
  def migrate_ruled_decision_integrity_v1_in_txn(txn) do
    :ok = preflight_ruled_decision_integrity_in_txn(txn)
    :ok = Txn.exec(txn, @ruled_decision_integrity_request_ddl)

    Txn.q(
      txn,
      """
      INSERT INTO decision_requests_ruled_integrity_v1 (#{@request_columns})
      SELECT #{@request_columns} FROM decision_requests
      """
    )

    :ok = Txn.exec(txn, "DROP TABLE decision_requests")

    :ok =
      Txn.exec(
        txn,
        "ALTER TABLE decision_requests_ruled_integrity_v1 RENAME TO decision_requests"
      )

    :ok = Txn.exec(txn, @ddl)
    :ok
  end

  @doc false
  @spec migrate_effort_deadline_ownership_v1_in_txn(Txn.t()) :: :ok
  # EGR-9 backfill for the effort_checkin_generator_retirement (v17->v18)
  # migration: one ownership row per effort decision request's deadline wake,
  # by exact foreign-key equality on the referenced wake id. Kept here beside
  # the other decision_requests readers because §10 admits the literal only in
  # this module; the probe half of the backfill reads effort_checkin_generations
  # alone and stays inline in schema.ex. Nothing is inferred from prompt text.
  def migrate_effort_deadline_ownership_v1_in_txn(txn) do
    :ok =
      Txn.exec(txn, """
      INSERT INTO effort_checkin_wake_ownership (wakeId, assignmentId, generation, role)
      SELECT deadlineWakeId, assignmentId, effortGeneration, 'decision_deadline'
      FROM decision_requests
      WHERE kind = 'effort' AND deadlineWakeId IS NOT NULL
      """)

    :ok
  end

  defp preflight_terminal_operator_rows_in_txn(txn, legacy_fact_max_id) do
    txn
    |> Txn.q("SELECT #{@legacy_request_columns} FROM decision_requests WHERE kind = 'operator'")
    |> Enum.each(fn row ->
      request = legacy_request_from_row(row)

      if request.status in ["ruled", "consumed"] do
        case validate_operator_terminal_with_cutoff_in_txn(
               txn,
               request,
               legacy_fact_max_id,
               "migration-preflight",
               "process:tightbeam"
             ) do
          :ok -> :ok
          {:error, %{code: "decision_request_integrity_invalid"}} -> :ok
        end
      end
    end)

    :ok
  end

  defp preflight_ruled_decision_integrity_in_txn(txn) do
    txn
    |> Txn.q("SELECT #{@request_columns} FROM decision_requests WHERE status = 'ruled'")
    |> Enum.each(fn row ->
      request = request_from_row(row)

      unless ruled_decision_complete?(request) do
        raise DB.Error,
          message:
            "incompatible_ruled_decision_integrity_v1: repair ruled request #{inspect(request.id)} with nonblank decision, ruledBy, and integer ruledAt before upgrade"
      end
    end)

    :ok
  end

  defp ensure_terminal_epoch_in_txn(txn) do
    [[legacy_fact_max_id]] = Txn.q(txn, "SELECT COALESCE(MAX(id), 0) FROM condition_facts")
    insert_terminal_epoch_in_txn(txn, legacy_fact_max_id)
  end

  defp insert_terminal_epoch_in_txn(txn, legacy_fact_max_id) do
    Txn.q(
      txn,
      """
      INSERT OR IGNORE INTO decision_request_terminal_epoch
        (id, schemaVersion, legacyRulingFactMaxId, activatedAt, cause, principal)
      VALUES (0, 'terminal-operator-decision-parity-v1', ?1, ?2,
              'terminal-operator-decision-parity-v1', 'process:tightbeam')
      """,
      [legacy_fact_max_id, now()]
    )

    :ok
  end

  @doc "Effect-free consultation of waiver and current decision request."
  @spec resolve(DB.server(), map(), map()) ::
          :allow | {:allow, String.t()} | {:deny, map()} | {:needs_request, String.t() | nil}
  def resolve(db, call, statute) do
    raiser_id = raiser_id(call)
    statute_name = statute_name(statute)

    if live_waiver?(db, raiser_id, statute_name) do
      :allow
    else
      case current_request(db, raiser_id, statute_name, digest(call)) do
        %{status: "ruled"} = request ->
          if ruled_decision_complete?(request) do
            case request.decision do
              "allow" -> {:allow, request.id}
              "deny" -> {:deny, deny_error(statute)}
              "waived" -> {:needs_request, nil}
              _ -> {:needs_request, nil}
            end
          else
            {:deny, integrity_error(request.id)}
          end

        %{status: "open", id: id} ->
          {:needs_request, id}

        _ ->
          {:needs_request, nil}
      end
    end
  end

  @doc "Open or re-return the one current open request for this action."
  @spec escalate(DB.server(), map(), map(), map()) :: {:decision_pending, String.t()}
  def escalate(db, call, statute, ctx) do
    case Map.get(ctx, :dr_id) || Map.get(ctx, "dr_id") do
      id when is_binary(id) ->
        {:decision_pending, id}

      nil ->
        now = now()
        episode_key = Map.get(ctx, :episode_key) || Map.get(ctx, "episode_key")
        {raiser_id, raiser_session_key} = raiser(call, episode_key)
        owner_user_id = owner_user_id!(db, call)
        statute_name = statute_name(statute)
        action_key = action_key(call, episode_key)
        assignment_id = assignment_id(call)
        request_id = "dr_" <> Tightbeam.Id.uuid4()
        question = fetch_string!(ctx, :question)

        options =
          ctx
          |> then(&(Map.get(&1, :options) || Map.get(&1, "options")))
          |> validate_options!()
          |> encode_optional()

        context =
          JSON.encode!(%{verb: Map.fetch!(call, :verb), params: Map.fetch!(call, :params)})

        deadline_at = now + decision_deadline_ms()

        {:ok, request} =
          DB.transaction(db, fn txn ->
            Txn.q(
              txn,
              """
              INSERT INTO decision_requests
                (id, raiserId, raiserSessionKey, ownerUserId, assignmentId, raisedAt,
                 deadlineAt, statuteName, actionKey, question, options, context, status)
              VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, 'open')
              ON CONFLICT DO NOTHING
              """,
              [
                request_id,
                raiser_id,
                raiser_session_key,
                owner_user_id,
                assignment_id,
                now,
                deadline_at,
                statute_name,
                action_key,
                question,
                options,
                context
              ]
            )

            inserted? = Txn.changes(txn) == 1

            [row] =
              Txn.q(
                txn,
                "SELECT #{@request_columns} FROM decision_requests WHERE kind = 'statute' AND raiserId = ?1 AND statuteName = ?2 AND actionKey = ?3 AND status = 'open' ORDER BY rowid DESC LIMIT 1",
                [raiser_id, statute_name, action_key]
              )

            request = request_from_row(row)

            if inserted? do
              EventLog.lifecycle_in_txn(
                txn,
                "decision_request_opened",
                request.id,
                "raiser=#{raiser_id} statute=#{statute_name} owner=#{owner_user_id} assignment=#{assignment_id || "nil"}"
              )

              # Transactional outbox: the owner notification is a durable wake
              # armed with the request itself. Only the winning insert arms one;
              # a conflict or replay arms none.
              Wakes.schedule_in_txn(txn, %{
                session_key: Org.personal_session_key(request.owner_user_id),
                origin: "process:tightbeam",
                prompt: owner_notification(request),
                due_at: now,
                target_gate: 0
              })
            end

            # Observability only (see @summon_kind). Ordering does not depend on this
            # row landing, or on its position — the single writer stamped its own
            # sequence before this transaction was opened. It stays inside the
            # transaction so the record matches what actually happened, not because
            # anything reads it back.
            if is_binary(episode_key) do
              EventLog.lifecycle_in_txn(
                txn,
                @summon_kind,
                request.id,
                "statute=#{statute_name} class=#{episode_key} opened=#{inserted?}"
              )
            end

            request
          end)

        {:decision_pending, request.id}
    end
  end

  @doc "Open or re-return one owner-scoped operator decision request."
  @spec operator_ask(DB.server(), map()) :: map()
  def operator_ask(db, call) do
    case Map.get(call, :principal) do
      {:session, session_key} ->
        with %{owner_user_id: owner_user_id} <- Org.get(db, session_key),
             {:ok, ask} <- normalize_operator_ask(call) do
          {:ok, result} =
            DB.transaction(db, fn txn ->
              result = operator_ask_in_txn(txn, call, session_key, owner_user_id, ask)

              unless Map.has_key?(result, :code),
                do: Publisher.maybe_accepted_in_txn(txn, call, result)

              result
            end)

          result
        else
          {:error, reason} -> reason
          _ -> error("invalid", "operator-ask requires a session principal")
        end

      _ ->
        error("invalid", "operator-ask requires a session principal")
    end
  end

  @doc "Resolve one operator request as its owner with authenticated performer provenance."
  @spec operator_rule(DB.server(), map(), keyword()) :: map()
  def operator_rule(db, call, opts \\ []) do
    request_id = param(call, :request_id) || param(call, :request)

    with {:ok, answer} <- normalize_operator_answer(call) do
      case DB.transaction(db, fn txn ->
             operator_rule_in_txn(txn, call, request_id, answer, opts)
           end) do
        {:ok, {result, fact_id}} ->
          if fact_id, do: nudge(opts, [fact_id])

          case result do
            %{kind: "operator", status: "ruled"} -> terminal_operator_projection(result)
            other -> other
          end

        {:error, error} ->
          integrity_transaction_error!(error)
      end
    else
      {:error, reason} -> reason
    end
  end

  @doc "Withdraw one operator request as its owner or same-owner raiser."
  @spec operator_withdraw(DB.server(), map()) :: map()
  def operator_withdraw(db, call) do
    request_id = param(call, :request_id) || param(call, :request)

    with {:ok, reason} <-
           normalized_required(param(call, :reason), "withdrawal reason is required") do
      {:ok, result} =
        DB.transaction(db, fn txn ->
          result = operator_withdraw_in_txn(txn, call, request_id, reason)

          unless Map.has_key?(result, :code),
            do: Publisher.maybe_accepted_in_txn(txn, call, result)

          result
        end)

      result
    else
      {:error, reason} -> reason
    end
  end

  @doc """
  The SUBORDINATE summons: `escalate/4` that can never raise into the call path (§B3).

  A malfunction's denial is already decided before the summons is attempted, and it
  must return byte-identical whether or not a mind can actually be reached — so a
  hand-off that cannot complete (no accountable owner resolves for the caller's
  principal or origin, the store is unavailable) is RECORDED and swallowed, never
  propagated. That is the difference between an unreachable mind and a call that
  crashes: one is a legible gap, the other is the silent stall §A3 exists to prevent.

  The recording is itself best-effort, for the same reason the deny cannot depend on
  the summons: an observability row that will not land must not become an outage.
  """
  @spec summon(DB.server(), map(), map(), map()) :: {:ok, String.t()} | :error
  def summon(db, call, statute, ctx) do
    {:decision_pending, id} = escalate(db, call, statute, ctx)
    {:ok, id}
  rescue
    error -> summons_failed(db, statute, Exception.message(error))
  catch
    kind, value -> summons_failed(db, statute, "#{kind}: #{inspect(value)}")
  end

  defp summons_failed(db, statute, reason) do
    _ =
      EventLog.lifecycle(
        db,
        "decision_request_failed",
        statute_name(statute),
        String.slice("summons failed: #{reason}", 0, 512)
      )

    :error
  rescue
    _ -> :error
  catch
    _, _ -> :error
  end

  ## The agent create-path (fabric §7 `input-needed` carrier; GitHub #11)
  #
  # THE MAXIM: an agent files a question, and keeps its obligation while it
  # waits — the row is data its asker chooses to honor, never a condition the
  # substrate enforces (adjudication-deletion amendment, 2026-08-12).
  #
  # WHAT THIS IS NOT, stated where the code is so a future reader trips over it:
  # nothing in the tree may READ an open `kind = 'agent'` row and act on its
  # existence. Not a completion check, not a turn-end sweep, not an assignment
  # close, not a wake gate. The moment one does, adjudication has been rebuilt
  # with a friendlier face (fabric §10) and this seam is void. Two things hold
  # that down mechanically rather than by promise: the arm above pins every
  # column a gate would need (`parkWakeId`, `rulingFactId`, `decision`) to NULL,
  # and `coordination_fabric_test.exs` scans production for readers of this kind.
  #
  # THE ASKER'S EXITS, all three reachable by the asker alone and none of them
  # anyone else's decision (gate Q3): read the answer when one lands, `withdraw`
  # the question, or simply carry on — the request holds nothing. If the asker
  # sits idle instead, the effort-without-effect rail notices, which is the
  # system working as designed.

  @doc """
  File one agent's question at a named principal. Returns the request row.

  The asked party is `call.session_key` — a session the wire router already
  resolved from `--session`/`--role`/`--user`, so a role's binding and its
  fallback are decided once, at the door, by the machinery `wake` uses.

  ONE COMMIT: the row and the notification that carries it land together or not
  at all (the transactional outbox every other request site owes). The
  notification is elected `input-needed` — the asker said so by asking — so the
  Phase 1 delivery policy batches it to the target's next turn boundary or the
  prodder floor, whichever comes first (§7).
  """
  @spec ask(DB.server(), map()) :: map()
  def ask(db, call) do
    asked_session_key = Map.get(call, :session_key)
    question = param(call, :question)

    with {:ok, asker_session_key} <- asking_session(call),
         {:ok, asked} <- asked_principal(db, asked_session_key, asker_session_key),
         {:ok, text} <- asked_question(question) do
      file_agent_request(db, %{
        asker_session_key: asker_session_key,
        owner_user_id: owner_user_id!(db, call),
        asked: asked,
        asked_of_role: Map.get(call, :target_role),
        role_fallback: Map.get(call, :role_fallback, false) == true,
        question: text,
        assignment_id: assignment_id(call),
        firehose_call: call
      })
    else
      {:error, error} -> error
    end
  end

  @doc """
  Answer one open agent question.

  An ANSWER, not a ruling: it authorizes nothing, spends nothing, unparks
  nothing, and fires no condition fact. It writes the text, names who wrote it,
  and wakes the asker — which is the whole of what the substrate owes here.

  Any authenticated agent session may answer when it holds the request's exact
  id. The asked session remains the preferred responder, not an authorization
  gate. A user principal keeps the existing asked-owner boundary.

  A typed cannot-proceed request is not an ordinary question. Prose cannot
  settle that durable decision obligation, so answer refuses it unchanged.

  Kind and principal standing are checked before a non-agent row is revealed.
  A nonexistent id, a non-agent id, and an agent question outside a user's
  existing expecter boundary are one identical refusal. An authenticated agent
  session holding the complete agent-request id has response standing.
  """
  @spec answer(DB.server(), map()) :: map()
  def answer(db, call) do
    request_id = param(call, :request_id) || param(call, :request)
    text = param(call, :answer)

    case get_raw(db, request_id) do
      %{kind: "agent"} = request ->
        if decision_reader?(call, request) do
          cond do
            cannot_proceed_request?(request) ->
              cannot_proceed_decision_error()

            not (is_binary(text) and String.trim(text) != "") ->
              error("invalid", "an answer requires text")

            request.status == "answered" and request.answered_by == principal_id(call) and
                request.answer == String.trim(text) ->
              {:ok, request} =
                DB.transaction(db, fn txn ->
                  Publisher.maybe_observed_accepted_in_txn(txn, call)
                  request
                end)

              request

            request.status != "open" ->
              error("not_open", "decision request is not open")

            true ->
              answer_open(
                db,
                Map.put(request, :firehose_call, call),
                String.trim(text),
                principal_id(call)
              )
          end
        else
          error("not_found", "decision request not found")
        end

      _ ->
        error("not_found", "decision request not found")
    end
  end

  @doc """
  Return one open agent question because the reader lacks enough information.

  A return is a terminal, reasoned disposition of the exact immutable request,
  not an answer or ruling. The same principal boundary as `answer/2` applies.
  Typed cannot-proceed requests refuse this generic terminal path unchanged.
  """
  @spec return_request(DB.server(), map()) :: map()
  def return_request(db, call) do
    request_id = param(call, :request_id) || param(call, :request)
    reason = param(call, :reason)

    case get_raw(db, request_id) do
      %{kind: "agent"} = request ->
        if decision_reader?(call, request) do
          if cannot_proceed_request?(request) do
            cannot_proceed_decision_error()
          else
            by = principal_id(call)

            case trimmed_reason(reason) do
              {:ok, text} ->
                cond do
                  request.status == "open" ->
                    return_open(db, Map.put(request, :firehose_call, call), text, by)

                  request.status == "returned" and request.returned_by == by and
                      request.return_reason == text ->
                    {:ok, request} =
                      DB.transaction(db, fn txn ->
                        Publisher.maybe_observed_accepted_in_txn(txn, call)
                        request
                      end)

                    request

                  true ->
                    error("not_open", "decision request is not open")
                end

              {:error, error} ->
                error
            end
          end
        else
          error("not_found", "decision request not found")
        end

      _ ->
        error("not_found", "decision request not found")
    end
  end

  # THE ONLY `decision_requests` INSERT that is not the substrate's own doing.
  # It arms its owner notification inside the same transaction, exactly as
  # `escalate/4` and the effort rail do (escalation-delivery-v1 proof 10).
  defp file_agent_request(db, input) do
    case DB.transaction(db, fn txn ->
           case file_agent_request_in_txn(txn, input) do
             %{request: request} = filed ->
               Publisher.maybe_accepted_in_txn(txn, input.firehose_call, request)
               filed

             error ->
               error
           end
         end) do
      {:ok, %{request: request}} -> request
      {:ok, error} -> error
      {:error, reason} -> raise "agent request transaction failed: #{inspect(reason)}"
    end
  end

  @doc false
  def file_agent_request_in_txn(txn, input) do
    raised_at = now()
    request_id = "dr_" <> Tightbeam.Id.uuid4()

    context =
      JSON.encode!(%{
        "verb" => Map.get(input, :verb, "ask"),
        "askedOfSessionKey" => input.asked.session_key,
        "askedOfRole" => input.asked_of_role,
        "roleFallback" => input.role_fallback
      })

    with {:ok, about} <-
           asked_about_in_txn(txn, input.assignment_id, input.asker_session_key) do
      resolved_input = Map.put(input, :assignment_id, about)

      Txn.q(
        txn,
        """
        INSERT INTO decision_requests
          (id, kind, raiserId, raiserSessionKey, ownerUserId, assignmentId,
           expecterSessionKey, expecterUserId, raisedAt, deadlineAt,
           question, context, status, askedOfRole)
        VALUES (?1, 'agent', ?2, ?3, ?4, ?5, ?6, ?7, ?8, NULL, ?9, ?10, 'open', ?11)
        """,
        [
          request_id,
          "session:" <> resolved_input.asker_session_key,
          resolved_input.asker_session_key,
          resolved_input.owner_user_id,
          resolved_input.assignment_id,
          resolved_input.asked.session_key,
          resolved_input.asked.owner_user_id,
          raised_at,
          resolved_input.question,
          context,
          resolved_input.asked_of_role
        ]
      )

      EventLog.lifecycle_in_txn(
        txn,
        "decision_request_asked",
        request_id,
        "asker=session:#{resolved_input.asker_session_key} askedOf=#{resolved_input.asked.session_key} " <>
          "role=#{resolved_input.asked_of_role || "nil"} assignment=#{resolved_input.assignment_id || "nil"}"
      )

      wake =
        if Map.get(input, :verb) == "cannot-proceed" do
          Wakes.schedule_in_txn(txn, %{
            session_key: resolved_input.asked.session_key,
            origin: "session:" <> resolved_input.asker_session_key,
            prompt: ask_notification(request_id, resolved_input),
            due_at: raised_at,
            target_gate: 0,
            class: "input-needed",
            assignment_id: resolved_input.assignment_id
          })
        else
          Wakes.schedule_in_txn(txn, %{
            session_key: resolved_input.asked.session_key,
            origin: "session:" <> resolved_input.asker_session_key,
            prompt: ask_notification(request_id, resolved_input),
            due_at: raised_at,
            target_gate: 0,
            class: "input-needed"
          })
        end

      %{request: request_in_txn(txn, request_id), wake: wake}
    else
      {:error, error} -> error
    end
  end

  @doc false
  def settle_agent_request_in_txn(txn, request_id, by, reason) do
    settled_at = now()

    Txn.q(
      txn,
      """
      UPDATE decision_requests
      SET status='withdrawn', withdrawnBy=?2, withdrawnReason=?3, withdrawnAt=?4
      WHERE id=?1 AND kind='agent' AND status='open'
      """,
      [request_id, by, reason, settled_at]
    )

    if Txn.changes(txn) == 1 do
      EventLog.lifecycle_in_txn(
        txn,
        "decision_request_withdrawn",
        request_id,
        "by=#{by} reason=#{reason}"
      )
    end

    :ok
  end

  defp answer_open(db, request, text, answered_by) do
    answered_at = now()

    {:ok, result} =
      DB.transaction(db, fn txn ->
        Txn.q(
          txn,
          """
          UPDATE decision_requests
          SET status = 'answered', answer = ?2, answeredBy = ?3, answeredAt = ?4
          WHERE id = ?1 AND kind = 'agent' AND status = 'open'
          """,
          [request.id, text, answered_by, answered_at]
        )

        if Txn.changes(txn) == 1 do
          EventLog.lifecycle_in_txn(
            txn,
            "decision_request_answered",
            request.id,
            "by=#{answered_by} askedOf=#{request.expecter_session_key}"
          )

          # The asker asked to be told, so this carries NO class: it is delivered
          # the way every wake was before Phase 1. Classing it would be the
          # substrate electing a coordination tier over somebody else's traffic
          # — the one thing §7 says only a sender may do.
          Wakes.schedule_in_txn(txn, %{
            session_key: request.raiser_session_key,
            origin: "process:tightbeam",
            prompt: answer_notification(request, text, answered_by),
            due_at: answered_at,
            target_gate: 0
          })

          answered = request_in_txn(txn, request.id)
          Publisher.maybe_accepted_in_txn(txn, request.firehose_call, answered)
          answered
        else
          current = request_in_txn(txn, request.id)

          if current.status == "answered" and current.answered_by == answered_by and
               current.answer == text do
            Publisher.maybe_observed_accepted_in_txn(txn, request.firehose_call)
            current
          else
            error("not_open", "decision request is not open")
          end
        end
      end)

    result
  end

  defp return_open(db, request, reason, returned_by) do
    returned_at = now()

    {:ok, result} =
      DB.transaction(db, fn txn ->
        Txn.q(
          txn,
          """
          UPDATE decision_requests
          SET status = 'returned', returnedBy = ?2, returnReason = ?3, returnedAt = ?4
          WHERE id = ?1 AND kind = 'agent' AND status = 'open'
          """,
          [request.id, returned_by, reason, returned_at]
        )

        if Txn.changes(txn) == 1 do
          EventLog.lifecycle_in_txn(
            txn,
            "decision_request_returned",
            request.id,
            "by=#{returned_by} askedOf=#{request.expecter_session_key}"
          )

          Wakes.schedule_in_txn(txn, %{
            session_key: request.raiser_session_key,
            origin: "process:tightbeam",
            prompt: return_notification(request, reason, returned_by),
            due_at: returned_at,
            target_gate: 0
          })

          returned = request_in_txn(txn, request.id)
          Publisher.maybe_accepted_in_txn(txn, request.firehose_call, returned)
          returned
        else
          current = request_in_txn(txn, request.id)

          if current.status == "returned" and current.returned_by == returned_by and
               current.return_reason == reason do
            Publisher.maybe_observed_accepted_in_txn(txn, request.firehose_call)
            current
          else
            error("not_open", "decision request is not open")
          end
        end
      end)

    result
  end

  defp trimmed_reason(reason) when is_binary(reason) do
    case String.trim(reason) do
      "" -> {:error, error("invalid", "a return reason is required")}
      text -> {:ok, text}
    end
  end

  defp trimmed_reason(_reason),
    do: {:error, error("invalid", "a return reason is required")}

  defp asking_session(%{principal: {:session, key}}), do: {:ok, key}

  defp asking_session(_call),
    do: {:error, error("not_session", "ask is filed by a session; a user wakes directly")}

  defp asked_principal(_db, key, key),
    do: {:error, error("invalid", "an agent cannot ask itself")}

  defp asked_principal(db, key, _asker) when is_binary(key) do
    case Org.get(db, key) do
      %{owner_user_id: owner} when is_binary(owner) ->
        {:ok, %{session_key: key, owner_user_id: owner}}

      _ ->
        {:error, error("not_found", "unknown target session: #{key}")}
    end
  end

  defp asked_principal(_db, _key, _asker),
    do: {:error, error("missing_target", "ask requires a session, role or user target")}

  defp asked_question(text) when is_binary(text) do
    case String.trim(text) do
      "" -> {:error, error("invalid", "a question requires text")}
      trimmed -> {:ok, trimmed}
    end
  end

  defp asked_question(_text), do: {:error, error("invalid", "a question requires text")}

  # `--about` is a REFERENCE the asker chose to attach, and an unknown one is a
  # refusal rather than a silently dropped column (report dirt, never accommodate
  # it). It attributes the question in the execution map's telemetry; it gates
  # nothing there either.
  #
  # A bare existence check let an outsider name ANY assignment id, filing a
  # question that associates it with private work it has no standing to
  # reference — and an existing-but-invisible id filed successfully while a
  # nonexistent one refused, which is an existence oracle on top (Sol xhigh
  # review, finding 5). There is no general assignment-visibility predicate in
  # this codebase to reuse (`assignment-get` itself is unscoped), so this is
  # the minimal one: the asker must hold the assignment, have opened it, or be
  # the one it reviews. Both an invisible id and a nonexistent one refuse
  # identically.
  defp asked_about_in_txn(txn, supplied, asker_session_key) do
    case supplied do
      nil ->
        {:ok, nil}

      id when is_binary(id) ->
        visible? = &askable_assignment_in_txn?(txn, &1, asker_session_key)

        case IdPrefix.resolve_in_txn(txn, :assignment, id, visible?) do
          {:ok, canonical} ->
            if askable_assignment_in_txn?(txn, canonical, asker_session_key),
              do: {:ok, canonical},
              else: {:error, error("not_found", "unknown assignment: #{id}")}

          :unknown ->
            {:error, error("not_found", "unknown assignment: #{id}")}

          {:ambiguous, error} ->
            {:error, error}
        end

      _ ->
        {:error, error("invalid", "--about takes an assignment id")}
    end
  end

  defp askable_assignment_in_txn?(txn, assignment_id, asker_session_key) do
    case Txn.q(
           txn,
           "SELECT holderKey, openedBySession, reviewsAssignmentId FROM assignments WHERE id = ?1",
           [assignment_id]
         ) do
      [[holder_key, opened_by_session, reviews_id]] ->
        holder_key == asker_session_key or
          opened_by_session == asker_session_key or
          (is_binary(reviews_id) and reviewed_holder_in_txn?(txn, reviews_id, asker_session_key))

      [] ->
        false
    end
  end

  # The assignment named by `--about` reviews another one: the session being
  # reviewed is legitimately referenced by that review even though it holds
  # neither the review assignment nor opened it.
  defp reviewed_holder_in_txn?(txn, reviewed_assignment_id, asker_session_key) do
    case Txn.q(txn, "SELECT holderKey FROM assignments WHERE id = ?1", [reviewed_assignment_id]) do
      [[holder_key]] -> holder_key == asker_session_key
      [] -> false
    end
  end

  defp decision_reader?(%{principal: {:session, _key}}, _request), do: true

  defp decision_reader?(%{principal: {:user, user_id}}, request),
    do: user_id == request.expecter_user_id

  defp decision_reader?(_call, _request), do: false

  @doc "Canonical authenticated responder id for decision-request audit fields."
  @spec principal_id(map() | {:session, String.t()} | {:user, String.t()}) :: String.t() | nil
  def principal_id(%{principal: principal}), do: principal_id(principal)
  def principal_id({:session, key}), do: "session:" <> key
  def principal_id({:user, user_id}), do: "user:" <> user_id
  def principal_id(_principal), do: nil

  defp ask_notification(request_id, input) do
    about = if input.assignment_id, do: "\nAbout: #{input.assignment_id}", else: ""

    "Question #{request_id} from session:#{input.asker_session_key}.\n" <>
      input.question <>
      about <>
      "\nAnswer with: tightbeam answer --request #{request_id} --answer \"<text>\""
  end

  defp answer_notification(request, text, answered_by) do
    "Question #{request.id} was answered by #{answered_by}.\n" <>
      "You asked: #{request.question}\n" <>
      "Answer: #{text}"
  end

  defp return_notification(request, reason, returned_by) do
    "Question #{request.id} was returned by #{returned_by} for insufficient information.\n" <>
      "You asked: #{request.question}\n" <>
      "Reason: #{reason}\n" <>
      "Revise or replace it by filing a new tightbeam ask; this request remains returned."
  end

  @doc "Spend one ruled authorization. Batch rollback is deliberately not provided."
  @spec consume(DB.server(), String.t()) :: boolean() | map()
  def consume(db, ruling_id) do
    DB.transaction(db, fn txn ->
      case request_in_txn_optional(txn, ruling_id) do
        %{kind: "operator", status: status} = request when status in ["ruled", "consumed"] ->
          case validate_operator_terminal_in_txn(
                 txn,
                 request,
                 "consume",
                 "process:tightbeam"
               ) do
            :ok -> false
            {:error, refusal} -> refusal
          end

        _request ->
          Txn.q(
            txn,
            "UPDATE decision_requests SET status = 'consumed', consumedAt = ?2 WHERE id = ?1 AND kind = 'statute' AND status = 'ruled'",
            [ruling_id, now()]
          )

          Txn.changes(txn) == 1
      end
    end)
    |> unwrap_integrity_transaction()
  end

  @doc "Rule one open request. `:authorized` is supplied by Gateway's admin axis."
  @spec rule(DB.server(), map(), keyword()) :: map()
  def rule(db, call, opts \\ []) do
    request_id = param(call, :request_id) || param(call, :request)
    request = get_raw(db, request_id)

    cond do
      request && request.kind == "effort" ->
        error("invalid", "effort requests use effort-rule")

      request && request.kind == "operator" && Keyword.get(opts, :authorized, false) ->
        error("invalid", "operator requests use operator-rule")

      # THE TRIPWIRE, refused at the verb edge (fabric §10). An agent's question
      # has no allow/deny/waived to hand out, and letting `rule` reach one would
      # turn a question into an authorization the substrate then owns.
      #
      # Gated on `:authorized` too (Sol xhigh review, finding 4): without it, an
      # unauthorized caller learned a request exists AND is an agent's question
      # before ever being told it lacks standing to rule anything. Falling
      # through to `rule_statute/4` for an unauthorized+agent-kind call gives it
      # the exact same `not_owner` an unauthorized caller gets for a nonexistent
      # id — only an AUTHORIZED caller ever reaches the kind-specific refusal.
      request && request.kind == "agent" && Keyword.get(opts, :authorized, false) ->
        error("invalid", "agent questions are answered, not ruled")

      true ->
        rule_statute(db, call, request, opts)
    end
  end

  defp rule_statute(db, call, request, opts) do
    with true <- Keyword.get(opts, :authorized, false),
         request when not is_nil(request) <- request,
         false <- raiser_id(call) == request.raiser_id,
         {:ok, decision} <- resolve_decision(request, param(call, :decision)) do
      case request.status do
        status when status in ["ruled", "consumed"] and request.decision == decision ->
          publish_request_replay(db, call, request)

        "open" ->
          rule_open(
            db,
            request,
            decision,
            param(call, :rationale),
            call.origin,
            Keyword.put(opts, :firehose_call, call)
          )

        _ ->
          error("not_open", "decision request is not open")
      end
    else
      false -> error("not_owner", "admin owner required")
      true -> error("not_owner", "raiser cannot rule its own request")
      nil -> error("not_found", "decision request not found")
      {:error, error} -> error
    end
  end

  @doc "Grant a request-driven or pre-emptive raiser-scoped waiver."
  @spec waive(DB.server(), map(), keyword()) :: map()
  def waive(db, call, opts \\ []) do
    if Keyword.get(opts, :authorized, false) do
      request_id = param(call, :request_id) || param(call, :request)

      case request_id && get_raw(db, request_id) do
        nil ->
          session_key = param(call, :session_key) || param(call, :session)
          statute_name = param(call, :statute_name) || param(call, :statute)
          target_raiser_id = if is_binary(session_key), do: "session:" <> session_key

          cond do
            not (is_binary(session_key) and is_binary(statute_name)) ->
              error("invalid", "waive requires --request or --session with --statute")

            raiser_id(call) == target_raiser_id ->
              error("not_owner", "raiser cannot waive its own statute")

            true ->
              grant_waiver(db, target_raiser_id, statute_name, call, "preemptive", opts)
          end

        %{kind: "effort"} ->
          error("invalid", "effort requests cannot be waived")

        # A waiver grants standing permission against a STATUTE. An agent's
        # question names none, so there is nothing here to waive — and inventing
        # one would hand the substrate a way to answer for the mind that was asked.
        %{kind: "agent"} ->
          error("invalid", "agent questions are answered, not waived")

        %{kind: "operator"} ->
          error("invalid", "operator requests cannot be waived")

        request ->
          if raiser_id(call) == request.raiser_id,
            do: error("not_owner", "raiser cannot waive its own statute"),
            else: grant_waiver(db, request.raiser_id, request.statute_name, call, "request", opts)
      end
    else
      error("not_owner", "admin owner required")
    end
  end

  @doc "Prospectively revoke one waiver."
  @spec revoke_waiver(DB.server(), map(), keyword()) :: map()
  def revoke_waiver(db, call, opts \\ []) do
    if Keyword.get(opts, :authorized, false) do
      waiver_id = param(call, :waiver_id) || param(call, :waiver)
      revoked_at = now()

      {:ok, rows} =
        DB.query(db, "SELECT raiserId FROM escalation_waivers WHERE id = ?1", [waiver_id])

      if rows == [[raiser_id(call)]] do
        error("not_owner", "raiser cannot revoke its own waiver")
      else
        revoke_waiver_as_owner(db, waiver_id, call.origin, revoked_at)
      end
    else
      error("not_owner", "admin owner required")
    end
  end

  defp revoke_waiver_as_owner(db, waiver_id, origin, revoked_at) do
    {:ok, result} =
      DB.transaction(db, fn txn ->
        Txn.q(
          txn,
          "UPDATE escalation_waivers SET revokedBy = ?2, revokedAt = ?3 WHERE id = ?1 AND revokedAt IS NULL",
          [waiver_id, origin, revoked_at]
        )

        if Txn.changes(txn) == 1 do
          EventLog.lifecycle_in_txn(txn, "waiver_revoked", waiver_id, "by=#{origin}")
          waiver_in_txn(txn, waiver_id)
        else
          error("not_open", "waiver is not live")
        end
      end)

    result
  end

  @doc """
  Withdraw an open request as its canonical raiser.

  This is ALSO the agent question's lawful agent-reachable exit (gate Q3): the
  asker that filed a `kind = 'agent'` row takes it back with the same verb and
  no other principal's cooperation. `raiserId = 'session:' || raiserSessionKey`
  in the agent arm is what makes the existing raiser check land on the asker.
  Typed cannot-proceed requests are the exception: their decision obligation
  remains until exact assignment disposition or an exact release fact.
  """
  @spec withdraw(DB.server(), map()) :: map()
  def withdraw(db, call) do
    request_id = param(call, :request_id) || param(call, :request)
    reason = param(call, :reason)

    cond do
      not (is_binary(reason) and reason != "") ->
        error("invalid", "withdrawal reason is required")

      true ->
        caller_raiser_id = raiser_id(call)

        case get_raw(db, request_id) do
          nil ->
            error("not_found", "decision request not found")

          %{kind: "effort"} ->
            error("invalid", "effort requests require effort-rule")

          %{kind: "operator"} ->
            error("invalid", "operator requests require operator-withdraw")

          request when request.raiser_id != caller_raiser_id ->
            error("not_raiser", "raiser required")

          request ->
            if cannot_proceed_request?(request),
              do: cannot_proceed_decision_error(),
              else: withdraw_open(db, Map.put(request, :firehose_call, call), call.origin, reason)
        end
    end
  end

  defp cannot_proceed_request?(%{context: %{"verb" => "cannot-proceed"}}), do: true
  defp cannot_proceed_request?(_request), do: false

  defp cannot_proceed_decision_error do
    error(
      "cannot_proceed_standing",
      "cannot-proceed decisions settle only through exact assignment disposition or release fact"
    )
  end

  @doc "Withdraw open requests and revoke live waivers for one retired session raiser."
  # KIND-AGNOSTIC BY DESIGN, not an oversight the tripwire's enumeration should
  # flag (Sol xhigh review, finding 2): withdrawal is the one verb every arm
  # answers to as its own lawful, judgment-free exit (gate Q3 for the agent
  # arm's own doc above). Retirement withdraws ALL of a session's open rows —
  # statute, effort, agent alike — on that session's behalf, exactly as if the
  # session had called `withdraw` on each itself. Typed cannot-proceed requests
  # remain open because retirement is neither an exact assignment disposition
  # nor an exact release fact.
  @spec withdraw_for_retired(DB.server(), String.t()) :: :ok
  def withdraw_for_retired(db, session_key) do
    raiser_id = "session:" <> session_key
    at = now()

    {:ok, :ok} =
      DB.transaction(db, fn txn ->
        rows =
          Txn.q(
            txn,
            "SELECT id,context FROM decision_requests WHERE raiserSessionKey = ?1 AND kind != 'operator' AND status = 'open'",
            [session_key]
          )
          |> Enum.reject(fn [_id, context] ->
            decode_required(context)["verb"] == "cannot-proceed"
          end)

        Enum.each(rows, fn [id, _context] ->
          Txn.q(
            txn,
            "UPDATE decision_requests SET status = 'withdrawn', withdrawnBy = 'process:tightbeam', withdrawnReason = 'raiser-retired', withdrawnAt = ?2 WHERE id = ?1 AND status = 'open'",
            [id, at]
          )

          if Txn.changes(txn) == 1 do
            EventLog.lifecycle_in_txn(
              txn,
              "decision_request_withdrawn",
              id,
              "by=process:tightbeam reason=raiser-retired"
            )
          end
        end)

        waivers =
          Txn.q(
            txn,
            "SELECT id FROM escalation_waivers WHERE raiserId = ?1 AND revokedAt IS NULL",
            [raiser_id]
          )

        Enum.each(waivers, fn [id] ->
          Txn.q(
            txn,
            "UPDATE escalation_waivers SET revokedBy = 'process:tightbeam', revokedAt = ?2 WHERE id = ?1 AND revokedAt IS NULL",
            [id, at]
          )

          if Txn.changes(txn) == 1 do
            EventLog.lifecycle_in_txn(txn, "waiver_revoked", id, "by=process:tightbeam")
          end
        end)

        :ok
      end)

    :ok
  end

  @doc """
  Effect-free: the ids of this statute's currently open episodes.

  A read only — the ordering decision over these ids belongs to `Tightbeam.RailEpisodes`,
  the single writer, which is the only caller. Nothing here compares positions or decides
  what is stale; that is exactly the logic that must not live in SQL.
  """
  @spec open_episodes(DB.server(), String.t()) :: [String.t()]
  def open_episodes(db, statute_name) do
    {:ok, rows} =
      DB.query(
        db,
        "SELECT id FROM decision_requests WHERE kind = 'statute' AND statuteName = ?1 AND raiserId = 'process:tightbeam' AND actionKey LIKE ?2 AND status = 'open'",
        [statute_name, @episode_prefix <> "%"]
      )

    Enum.map(rows, fn [id] -> id end)
  end

  @doc """
  Withdraw the named episodes as `sensor-recovered`. Called ONLY by the single writer.

  Dark-factory recovery: the episode exists because a check stopped rendering verdicts, so
  an observed verdict IS the repair, and demanding an operator verb to acknowledge a
  sensor that already healed is the stall the episode was meant to prevent. Withdrawal,
  not a ruling: nothing was decided, the question expired.

  WHICH episodes is not decided here. The writer has already chosen them by comparing each
  episode's newest summons against a position minted before the check ran; this call only
  enacts that choice. `status = 'open'` still guards the UPDATE, so a ruling that landed
  first wins and is not overwritten.

  THE MIRROR CASE IS RULED ACCEPTED — do not "fix" it. A summons evaluated before a
  healthy close but landing after it opens an episode for a sensor that has already
  recovered. That is ACCEPTED BOUNDED STALENESS, not a defect (§A3/§B, ruled 2026-07-29):
  the malfunction genuinely occurred and genuinely denied a call, so the summons is
  truthful, and the next healthy evaluation closes it.
  """
  @spec withdraw_episodes(DB.server(), [String.t()], String.t()) :: :ok
  def withdraw_episodes(_db, [], _statute_name), do: :ok

  def withdraw_episodes(db, ids, statute_name) do
    {:ok, :ok} =
      DB.transaction(db, fn txn ->
        Enum.each(ids, fn id ->
          Txn.q(
            txn,
            "UPDATE decision_requests SET status = 'withdrawn', withdrawnBy = 'process:tightbeam', withdrawnReason = 'sensor-recovered', withdrawnAt = ?2 WHERE id = ?1 AND status = 'open'",
            [id, now()]
          )

          if Txn.changes(txn) == 1 do
            EventLog.lifecycle_in_txn(
              txn,
              "decision_request_withdrawn",
              id,
              "by=process:tightbeam reason=sensor-recovered statute=#{statute_name}"
            )
          end
        end)

        :ok
      end)

    :ok
  end

  @doc "Boot backstop for retirement casts lost across a crash."
  # Same kind-agnostic exemption as `withdraw_for_retired/2` immediately above,
  # which this only locates candidates for and then calls unchanged.
  @spec recover_retired(DB.server()) :: :ok
  def recover_retired(db \\ DB) do
    {:ok, rows} =
      DB.query(
        db,
        "SELECT s.sessionKey FROM sessions s WHERE s.state = 'retired' AND (EXISTS (SELECT 1 FROM decision_requests dr WHERE dr.raiserSessionKey = s.sessionKey AND dr.kind != 'operator' AND dr.status = 'open') OR EXISTS (SELECT 1 FROM escalation_waivers ew WHERE ew.raiserId = 'session:' || s.sessionKey AND ew.revokedAt IS NULL))"
      )

    Enum.each(rows, fn [key] -> withdraw_for_retired(db, key) end)

    :ok
  end

  @doc """
  Validate a `--status` filter for `list/4` at the verb edge. `nil` (absent) defaults
  to "open"; a legal status or the "all" sentinel passes through; anything else refuses
  and names the legal set, so a typo cannot silently return an empty list.
  """
  @spec list_status(String.t() | nil) :: {:ok, String.t()} | map()
  def list_status(nil), do: {:ok, "open"}
  def list_status(status) when status in @list_status_filters, do: {:ok, status}

  def list_status(status),
    do:
      error(
        "invalid",
        "unknown status #{inspect(status)}; legal: #{Enum.join(@list_status_filters, ", ")}"
      )

  @doc """
  List visible decision requests. Owner/admin and raiser visibility are disjoint
  filters.
  """
  @spec list(DB.server(), map(), String.t() | nil, keyword()) :: [map()] | map()
  def list(db, call, status \\ "open", opts \\ []) do
    {where, params} = visibility(call, Keyword.get(opts, :owner_user_id))

    # nil and the "all" sentinel both mean "no status filter". A concrete status filters
    # to that one value; "all" as a literal never matches a row, so it must not reach SQL.
    {status_clause, params} =
      if is_binary(status) and status != "all" do
        {" AND status = ?#{length(params) + 1}", params ++ [status]}
      else
        {"", params}
      end

    observer = principal_id(call) || "process:tightbeam"

    DB.transaction(db, fn txn ->
      rows =
        Txn.q(
          txn,
          "SELECT #{@request_columns} FROM decision_requests WHERE (#{where})#{status_clause} ORDER BY rowid DESC",
          params
        )

      requests = Enum.map(rows, &request_from_row/1)

      case Enum.find(requests, fn request ->
             request.kind != "operator" and request.status == "ruled" and
               not ruled_decision_complete?(request)
           end) do
        %{id: request_id} ->
          integrity_error(request_id)

        nil ->
          invalid_ids =
            requests
            |> Enum.filter(&(&1.kind == "operator" and &1.status in ["ruled", "consumed"]))
            |> Enum.flat_map(fn request ->
              case validate_operator_terminal_in_txn(txn, request, "list", observer) do
                :ok -> []
                {:error, _refusal} -> [request.id]
              end
            end)

          case Enum.sort(invalid_ids) do
            [request_id | _] -> integrity_error(request_id)
            [] -> Enum.map(requests, &list_projection/1)
          end
      end
    end)
    |> unwrap_integrity_transaction()
  end

  @doc """
  Fetch one visible decision request including its halted-call context.
  """
  @spec get(DB.server(), map(), String.t(), keyword()) :: map() | nil
  def get(db, call, id, opts \\ [])

  def get(db, call, id, opts) do
    {where, params} = visibility(call, Keyword.get(opts, :owner_user_id))

    observer = principal_id(call) || "process:tightbeam"

    DB.transaction(db, fn txn ->
      rows =
        Txn.q(
          txn,
          "SELECT #{@request_columns} FROM decision_requests WHERE id = ?1 AND (#{shift_params(where)})",
          [id | params]
        )

      case rows do
        [row] ->
          request = request_from_row(row)

          cond do
            request.kind == "operator" and request.status in ["ruled", "consumed"] ->
              case validate_operator_terminal_in_txn(txn, request, "detail", observer) do
                :ok -> terminal_operator_projection(request)
                {:error, refusal} -> refusal
              end

            request.status == "ruled" and not ruled_decision_complete?(request) ->
              integrity_error(request.id)

            true ->
              request
          end

        [] ->
          nil
      end
    end)
    |> unwrap_integrity_transaction()
  end

  @doc "Canonical SHA-256 action fingerprint."
  @spec digest(map()) :: String.t()
  def digest(call) do
    params =
      call
      |> Map.fetch!(:params)
      |> normalize_map()
      |> Map.drop([
        "assignment_id",
        "assignmentId",
        "idempotency_key",
        "idempotencyKey",
        "key",
        "note"
      ])

    canonical = %{
      "assignmentId" => assignment_id(call),
      "params" => params,
      "verb" => Map.fetch!(call, :verb)
    }

    :crypto.hash(:sha256, canonical_json(canonical)) |> Base.encode16(case: :lower)
  end

  ## EXTERNAL READERS (Sol xhigh review round 2, finding 1).
  #
  # Every production module outside this file that touches `decision_requests`
  # calls ONE of the functions below — never SQL of its own. That is now the
  # WHOLE of the tripwire's structural half: `coordination_fabric_test.exs`
  # asserts (a) no `decision_requests` literal exists anywhere else in `lib/`,
  # which a text scan can prove exhaustively once there is nowhere else for one
  # to hide, and (b) the function names below, paired with the kind each is
  # scoped to, equal a pinned inventory — so a new helper, or a scope that
  # silently widens, fails the test until it is reviewed and the inventory
  # updated by hand.
  #
  # A prior version of this tripwire DECLARED this inventory by hand and
  # scanned production source for the raw SQL outside it. Sol xhigh review
  # round 3 named four bypasses that survives: a new reader added INSIDE this
  # file with no map entry; a helper removed with its entry left stale; a
  # helper's SQL widened past its declared scope with no textual signal; and
  # a new external caller of an "any"-scoped helper, which has no literal for
  # any scan to catch. `coordination_fabric_test.exs`'s tripwire now closes
  # all four by DERIVING this map from source rather than trusting it:
  #
  #   (a) every function in this file is enumerated, its OWN text extracted
  #       by true `end`-boundary (not "until the next `def`", which bleeds a
  #       neighbor's `@doc` in) with comments stripped, and the set of ones
  #       whose text names `decision_requests` — closed transitively over
  #       LOCAL calls, so a delegate with no SQL of its own (`answer/2`
  #       calling `get_raw/2`) still counts — is asserted equal to this map's
  #       keys.
  #   (b) every entry scoped to one kind (or a named pair) must contain ITS
  #       OWN predicate in its own text.
  #   (c) every "any"-scoped, non-verb helper's external call sites are
  #       pinned by {file, enclosing function}.
  #
  # So this map is now a CHECKED CLAIM, not a fact anyone has to remember to
  # keep current — the derivation is the enumeration, not an approximation of
  # it. It include this module's PRIVATE plumbing too (`get_raw/2`,
  # `current_request/4`, `rule_open/6`, ...): they can never be called from
  # outside (Elixir enforces that), but they are still part of what "every
  # reader lives in escalation.ex" has to mean.
  @helper_kind_inventory %{
    # DIRECT: own SQL literal, single-kind or named-pair scope (round-2 (b)
    # verifies each contains its own predicate).
    escalate: "statute",
    open_episodes: "statute",
    statute_park_candidate_in_txn: "statute",
    grant_waiver: "statute",
    current_request: "statute",
    file_agent_request: "agent",
    file_agent_request_in_txn: "agent",
    settle_agent_request_in_txn: "agent",
    answer_open: "agent",
    return_open: "agent",
    effort_open_by_deadline_wake_in_txn: "effort",
    effort_terminal_in_txn: "effort",
    effort_insert_in_txn: "effort",
    effort_id_by_generation_in_txn: "effort",
    effort_supersede_open_in_txn: "effort",
    effort_update_generation_in_txn: "effort",
    migrate_effort_deadline_ownership_v1_in_txn: "effort",
    insert_operator_request_in_txn: "operator",
    operator_open_in_txn: "operator",
    preflight_terminal_operator_rows_in_txn: "operator",
    rule_operator_request_in_txn: "operator",
    operator_withdraw_in_txn: "operator",
    open_counts_by_assignment: "statute,effort",
    # DIRECT: own SQL literal, unscoped by kind (id-scoped internal plumbing,
    # a genuinely cross-kind read, or a documented kind-agnostic exit).
    consume: "any",
    withdraw_for_retired: "any",
    withdraw_episodes: "any",
    recover_retired: "any",
    list: "any",
    get: "any",
    effort_rule_in_txn: "any",
    claim_park_wake_in_txn: "any",
    decision_trace_rows: "any",
    wake_link_fragment: "any",
    raw_exists_in_txn?: "any",
    statute_name_for_ruling: "any",
    rule_open: "any",
    withdraw_open: "any",
    get_raw: "any",
    request_in_txn: "any",
    request_in_txn_optional: "any",
    migrate_terminal_operator_decision_v1_in_txn: "any",
    migrate_ruled_decision_integrity_v1_in_txn: "any",
    preflight_ruled_decision_integrity_in_txn: "any",
    # DELEGATE: no SQL literal of its own — reaches one of the entries above
    # by a local call. `answer/2`/`return_request/2`/`ask/2`/`rule/3`/`waive/3`/`withdraw/2`/
    # `resolve/3`/`summon/4` are this module's PUBLIC VERB SURFACE, reached
    # exclusively through Dispatch/Gateway's own routing tables and proved
    # there by other tests — not "helpers" another module reaches on its own
    # initiative, so (c)'s pinned-caller treatment does not apply to them.
    answer: "agent",
    return_request: "agent",
    operator_ask: "operator",
    operator_ask_in_txn: "operator",
    operator_rule: "operator",
    operator_rule_in_txn: "operator",
    operator_withdraw: "operator",
    superseded_request_in_txn: "operator",
    ask: "agent",
    raw_by_id: "any",
    raw_by_id_in_txn: "any",
    raw_by_id_in_txn!: "any",
    resolve: "statute",
    rule: "any",
    rule_statute: "any",
    summon: "statute",
    waive: "any",
    withdraw: "any"
  }

  @doc false
  @spec helper_kind_inventory() :: %{atom() => String.t()}
  def helper_kind_inventory, do: @helper_kind_inventory

  @doc """
  ANY KIND, by id alone. The caller is responsible for checking `.kind` before
  treating the row as one arm's data — the same "fetch first, branch on kind"
  shape `answer/2`, `rule/4` and `withdraw/2` already use internally, exposed
  here for the one external caller (`EffortCheckin`) that needs a row before it
  knows which arm it belongs to.
  """
  @spec raw_by_id(DB.server(), String.t() | nil) :: map() | nil
  def raw_by_id(db, id), do: get_raw(db, id)

  @doc """
  ANY KIND, by id alone, inside a transaction — RAISES if the row is not
  there. Only for a caller that just wrote or just re-read the row and treats
  its absence as a bug, never a possibility: the same contract this module's
  own internal `request_in_txn/2` already carries.
  """
  @spec raw_by_id_in_txn!(Txn.t(), String.t()) :: map()
  def raw_by_id_in_txn!(txn, id), do: request_in_txn(txn, id)

  @doc false
  @spec raw_by_id_in_txn(Txn.t(), String.t() | nil) :: map() | nil
  def raw_by_id_in_txn(txn, id) do
    case Txn.q(txn, "SELECT #{@request_columns} FROM decision_requests WHERE id = ?1", [id]) do
      [row] -> request_from_row(row)
      [] -> nil
    end
  end

  @doc "EFFORT ONLY: the open effort request currently carrying this deadline wake."
  @spec effort_open_by_deadline_wake_in_txn(Txn.t(), String.t()) :: map() | nil
  def effort_open_by_deadline_wake_in_txn(txn, wake_id) do
    case Txn.q(
           txn,
           "SELECT #{@request_columns} FROM decision_requests WHERE kind = 'effort' AND status = 'open' AND deadlineWakeId = ?1",
           [wake_id]
         ) do
      [row] -> request_from_row(row)
      [] -> nil
    end
  end

  @doc "EFFORT ONLY: the durable terminal request for an exact id, if present."
  @spec effort_terminal_in_txn(Txn.t(), String.t()) :: map() | nil
  def effort_terminal_in_txn(txn, request_id) do
    case Txn.q(
           txn,
           "SELECT #{@request_columns} FROM decision_requests WHERE kind = 'effort' AND id = ?1 AND status = 'ruled' AND decision IN ('continue', 'dismiss')",
           [request_id]
         ) do
      [row] -> request_from_row(row)
      [] -> nil
    end
  end

  @doc """
  EFFORT ONLY: file one generation's request AND arm its check-in prompt, in
  one commit — the same transactional-outbox shape `escalate/4` and
  `file_agent_request/2` above already use for their own kinds (escalation-
  delivery-v1 proof 10: the row and the notification that carries it land
  together or not at all). `ON CONFLICT DO NOTHING` against
  `decision_requests_effort_generation` — the caller reads the winner back
  with `effort_id_by_generation_in_txn/3` on a loss, and arms nothing itself.
  """
  @spec effort_insert_in_txn(Txn.t(), map()) :: {:inserted, map()} | :conflict
  def effort_insert_in_txn(txn, attrs) do
    Txn.q(
      txn,
      """
      INSERT INTO decision_requests
        (id, kind, raiserId, ownerUserId, assignmentId, expecterSessionKey,
         expecterUserId, lineageRung, effortGeneration, deadlineWakeId,
         raisedAt, deadlineAt, statuteName, actionKey, question, options,
         context, status)
      VALUES
        (?1, 'effort', 'process:tightbeam', ?2, ?3, ?4, ?5, ?6, ?7, ?8,
         ?9, ?10, NULL, NULL, ?11, ?12, ?13, 'open')
      ON CONFLICT DO NOTHING
      """,
      [
        attrs.id,
        attrs.owner_user_id,
        attrs.assignment_id,
        attrs.expecter_session_key,
        attrs.expecter_user_id,
        attrs.lineage_rung,
        attrs.generation,
        attrs.deadline_wake_id,
        attrs.raised_at,
        attrs.deadline_at,
        attrs.question,
        attrs.options_json,
        attrs.context_json
      ]
    )

    if Txn.changes(txn) == 1 do
      request = request_in_txn(txn, attrs.id)
      effort_notification_in_txn(txn, request)
      {:inserted, request}
    else
      :conflict
    end
  end

  @doc "EFFORT ONLY: this generation's request id, if one was already filed."
  @spec effort_id_by_generation_in_txn(Txn.t(), String.t(), integer()) :: String.t() | nil
  def effort_id_by_generation_in_txn(txn, assignment_id, generation) do
    case Txn.q(
           txn,
           "SELECT id FROM decision_requests WHERE kind = 'effort' AND assignmentId = ?1 AND effortGeneration = ?2",
           [assignment_id, generation]
         ) do
      [[id]] -> id
      [] -> nil
    end
  end

  @doc """
  EFFORT ONLY: supersede every open request for this assignment. Returns the
  deadline wake ids it superseded, so the caller can cancel each in turn — the
  read and the write are one function because every caller does both together
  and neither ever wants one without the other.
  """
  @spec effort_supersede_open_in_txn(Txn.t(), String.t()) :: [String.t()]
  def effort_supersede_open_in_txn(txn, assignment_id) do
    wake_ids =
      Txn.q(
        txn,
        "SELECT deadlineWakeId FROM decision_requests WHERE kind = 'effort' AND assignmentId = ?1 AND status = 'open'",
        [assignment_id]
      )
      |> List.flatten()

    Txn.q(
      txn,
      "UPDATE decision_requests SET status = 'superseded' WHERE kind = 'effort' AND assignmentId = ?1 AND status = 'open'",
      [assignment_id]
    )

    wake_ids
  end

  @doc """
  EFFORT ONLY: advance one open request's rung and deadline in place, AND
  re-arm its check-in prompt on the new expecter — one commit, same shape as
  `effort_insert_in_txn/2` above (escalation-delivery-v1 proof 10).
  `deadlineWakeId = ?9` (the last param) is a CAS against the wake this update
  is racing to replace — a concurrent winner already moved it, and this call
  loses cleanly rather than double-advancing or arming a stale prompt.
  """
  @spec effort_update_generation_in_txn(Txn.t(), String.t(), String.t(), map()) ::
          {:advanced, map()} | :lost
  def effort_update_generation_in_txn(txn, id, prior_deadline_wake_id, attrs) do
    Txn.q(
      txn,
      """
      UPDATE decision_requests
      SET expecterSessionKey = ?2, expecterUserId = ?3, lineageRung = ?4,
          deadlineAt = ?5, deadlineWakeId = ?6, options = ?7, context = ?8
      WHERE id = ?1 AND kind = 'effort' AND status = 'open' AND deadlineWakeId = ?9
      """,
      [
        id,
        attrs.expecter_session_key,
        attrs.expecter_user_id,
        attrs.lineage_rung,
        attrs.deadline_at,
        attrs.deadline_wake_id,
        attrs.options_json,
        attrs.context_json,
        prior_deadline_wake_id
      ]
    )

    if Txn.changes(txn) == 1 do
      advanced = request_in_txn(txn, id)
      effort_notification_in_txn(txn, advanced)
      {:advanced, advanced}
    else
      :lost
    end
  end

  # Transactional outbox for the effort arm's own check-in prompt — the same
  # shared shape `owner_notification/1` (statute) and `ask_notification/2`
  # (agent) each feed their own `Wakes.schedule_in_txn/2` call with, kept here
  # rather than in `EffortCheckin` so the row write and its notification are
  # provably one commit in the same file (Sol xhigh review round 2: proof 10's
  # same-file call-graph traversal cannot see across a module boundary).
  defp effort_notification_in_txn(txn, request) do
    prompt =
      "Effort check-in #{request.id} for assignment #{request.assignment_id}.\n" <>
        request.question <>
        "\nActions: #{Enum.join(request.options || [], ", ")}"

    wake =
      Wakes.schedule_in_txn(txn, %{
        session_key:
          request.expecter_session_key || Org.personal_session_key(request.expecter_user_id),
        origin: "process:tightbeam",
        prompt: prompt,
        due_at: now(),
        assignment_id: request.assignment_id,
        target_gate: 0
      })

    Tightbeam.EffortCheckin.own_effort_wake_in_txn(
      txn,
      wake.wake_id,
      request.assignment_id,
      request.effort_generation,
      "decision_notification"
    )

    wake
  end

  @doc """
  EFFORT'S OWN RULING — not the statute `rule/4` above, which refuses an
  effort-kind id by name. `EffortCheckin.rule/3` fetches the row and checks
  `.kind == "effort"` itself before ever calling this, so it is id-scoped
  rather than kind-scoped in its own WHERE clause, same as `rule_open/6`'s
  statute update just above it in this file.
  """
  @spec effort_rule_in_txn(Txn.t(), String.t(), String.t(), String.t(), integer()) :: boolean()
  def effort_rule_in_txn(txn, id, decision, ruled_by, ruled_at) do
    Txn.q(
      txn,
      "UPDATE decision_requests SET status = 'ruled', decision = ?2, ruledBy = ?3, ruledAt = ?4 WHERE id = ?1 AND status = 'open'",
      [id, decision, ruled_by, ruled_at]
    )

    Txn.changes(txn) == 1
  end

  @doc """
  STATUTE ONLY: the park sweep's read (`Supervision.park_escalation/3`) — an
  open statute request by id, the same `kind = 'statute'` scoping
  `current_request/4` (the gate read) uses, restated here because a park sweep
  is exactly the kind of reader that must never be able to reach an agent row,
  even by construction accident.
  """
  @spec statute_park_candidate_in_txn(Txn.t(), String.t()) ::
          {:ok, integer(), String.t() | nil, String.t() | nil} | :not_found
  def statute_park_candidate_in_txn(txn, request_id) do
    case Txn.q(
           txn,
           "SELECT deadlineAt, parkWakeId, assignmentId FROM decision_requests WHERE id = ?1 AND status = 'open' AND kind = 'statute'",
           [request_id]
         ) do
      [[deadline_at, park_wake_id, assignment_id]] ->
        {:ok, deadline_at, park_wake_id, assignment_id}

      [] ->
        :not_found
    end
  end

  @doc """
  Claim the park wake id for one request — id-scoped, so its own WHERE names
  no kind, but its only caller only ever hands it an id
  `statute_park_candidate_in_txn/2` just named as an open statute request.
  """
  @spec claim_park_wake_in_txn(Txn.t(), String.t(), String.t()) :: :ok
  def claim_park_wake_in_txn(txn, request_id, wake_id) do
    Txn.q(
      txn,
      "UPDATE decision_requests SET parkWakeId = ?2 WHERE id = ?1 AND parkWakeId IS NULL",
      [request_id, wake_id]
    )

    :ok
  end

  @doc """
  STATUTE+EFFORT telemetry for the execution map: open request counts per
  assignment. Agent questions gate nothing (fabric §10) and are not tallied
  here — counting them would be exactly the kind of silent, generic read the
  tripwire enumeration exists to catch, and once did (this function predates
  the agent arm and had no kind predicate at all until this review).
  """
  @spec open_counts_by_assignment(DB.server()) :: %{String.t() => non_neg_integer()}
  def open_counts_by_assignment(db) do
    {:ok, rows} =
      DB.query(db, """
      SELECT assignmentId, COUNT(*) FROM decision_requests
      WHERE status = 'open' AND assignmentId IS NOT NULL AND kind IN ('statute', 'effort')
      GROUP BY assignmentId
      """)

    Map.new(rows, fn [assignment_id, count] -> {assignment_id, count} end)
  end

  @doc """
  ANY KIND, forensic dump for `JobTrace`: every request tied to these
  assignments. Diagnostics, not a gate (`job-trace observability v1`) — every
  kind belongs in a trace built to answer "what happened here", so this is
  deliberately unfiltered by kind, the same way `raw_by_id/2` is deliberately
  unfiltered because its callers decide.
  """
  @spec decision_trace_rows(DB.server(), [String.t()]) :: [[term()]]
  def decision_trace_rows(_db, []), do: []

  def decision_trace_rows(db, assignment_ids) do
    {clause, params} = trace_in_clause(assignment_ids)

    {:ok, rows} =
      DB.query(
        db,
        "SELECT id, assignmentId, status, decision, raisedAt FROM decision_requests WHERE assignmentId IN (#{clause})",
        params
      )

    rows
  end

  @doc """
  ANY KIND: SQL TEXT ONLY, no query runs here. `JobTrace.wake_entries/3` joins
  wake ids from THREE tables (`effort_checkin_generations`, `decision_requests`,
  `wakes`) in one `UNION` CTE so a wake tied to any of them resolves through a
  single downstream join; this hands back this table's clause of that union,
  built against the SAME already-numbered placeholder text the caller built
  for its other two clauses, so all three share one parameter list.
  """
  @spec wake_link_fragment(String.t()) :: String.t()
  def wake_link_fragment(in_clause) do
    "SELECT deadlineWakeId, assignmentId FROM decision_requests WHERE assignmentId IN (#{in_clause})"
  end

  defp trace_in_clause(values) do
    placeholders =
      values
      |> Enum.with_index(1)
      |> Enum.map_join(", ", fn {_value, index} -> "?#{index}" end)

    {placeholders, values}
  end

  @doc """
  ANY KIND: does a request with this id exist at all? `Wakes`' provenance
  validation uses this for a `decision_request` source/disposition exactly
  the same way it validates against `assignments`, `work_items` and
  `sessions` — an existence check, not a decision about what the row means.
  """
  @spec raw_exists_in_txn?(Txn.t(), String.t()) :: boolean()
  def raw_exists_in_txn?(txn, id) do
    match?([[1]], Txn.q(txn, "SELECT 1 FROM decision_requests WHERE id = ?1", [id]))
  end

  @doc """
  ANY KIND, by id: the statute name a ruling denial names in its error
  context. `Dispatch.ruling_statute/2`'s only caller always holds a ruling
  id, which only a statute row produces, so this is unfiltered by kind for
  the same reason `raw_by_id/2` is — the id already came from a statute-only
  path. `:not_found` is distinct from `{:ok, nil}` (a found row whose
  `statuteName` is null) so the caller's own fallback applies to exactly the
  case it always did.
  """
  @spec statute_name_for_ruling(DB.server(), String.t()) :: {:ok, String.t() | nil} | :not_found
  def statute_name_for_ruling(db, ruling_id) do
    case DB.query(db, "SELECT statuteName FROM decision_requests WHERE id = ?1", [ruling_id]) do
      {:ok, [[statute]]} -> {:ok, statute}
      _ -> :not_found
    end
  end

  defp rule_open(db, request, decision, rationale, origin, opts) do
    ruled_at = now()

    {:ok, {result, filed_fact_id}} =
      DB.transaction(db, fn txn ->
        Txn.q(
          txn,
          "UPDATE decision_requests SET status = 'ruled', decision = ?2, rationale = ?3, ruledBy = ?4, ruledAt = ?5 WHERE id = ?1 AND status = 'open'",
          [request.id, decision, rationale, origin, ruled_at]
        )

        if Txn.changes(txn) == 1 do
          %{fact_id: fact_id} =
            ConditionFacts.file_in_txn(txn, %{
              kind: "escalation-ruled",
              scope: request.id,
              origin: "process:tightbeam"
            })

          Txn.q(txn, "UPDATE decision_requests SET rulingFactId = ?2 WHERE id = ?1", [
            request.id,
            fact_id
          ])

          EventLog.lifecycle_in_txn(
            txn,
            "decision_request_ruled",
            request.id,
            "by=#{origin} decision=#{decision} factId=#{fact_id}"
          )

          ruled = request_in_txn(txn, request.id)
          Publisher.maybe_accepted_in_txn(txn, opts[:firehose_call], ruled)
          {ruled, fact_id}
        else
          current = request_in_txn(txn, request.id)

          # A concurrent-ruler loser filed nothing: it must not nudge (F13 —
          # one post-commit nudge per filed fact, owned by the filer).
          if current.status == "ruled" and current.decision == decision do
            Publisher.maybe_accepted_in_txn(txn, opts[:firehose_call], current)
            {current, nil}
          else
            {error("not_open", "decision request is not open"), nil}
          end
        end
      end)

    if filed_fact_id, do: nudge(opts, [filed_fact_id])
    result
  end

  defp grant_waiver(db, raiser_id, statute_name, call, path, opts) do
    waiver_id = "ew_" <> Tightbeam.Id.uuid4()
    granted_at = now()
    reason = param(call, :reason)

    {:ok, {waiver, fact_ids}} =
      DB.transaction(db, fn txn ->
        Txn.q(
          txn,
          "INSERT INTO escalation_waivers (id, raiserId, statuteName, grantedBy, grantedAt, reason) VALUES (?1, ?2, ?3, ?4, ?5, ?6)",
          [waiver_id, raiser_id, statute_name, call.origin, granted_at, reason]
        )

        EventLog.lifecycle_in_txn(
          txn,
          "waiver_granted",
          waiver_id,
          "raiser=#{raiser_id} statute=#{statute_name} by=#{call.origin} path=#{path}"
        )

        fact_ids =
          if path == "request" do
            open_ids =
              Txn.q(
                txn,
                "SELECT id FROM decision_requests WHERE kind = 'statute' AND raiserId = ?1 AND statuteName = ?2 AND status = 'open' ORDER BY rowid",
                [raiser_id, statute_name]
              )

            Enum.flat_map(open_ids, fn [id] ->
              Txn.q(
                txn,
                "UPDATE decision_requests SET status = 'ruled', decision = 'waived', rationale = ?2, ruledBy = ?3, ruledAt = ?4 WHERE id = ?1 AND status = 'open'",
                [id, reason, call.origin, granted_at]
              )

              if Txn.changes(txn) == 1 do
                %{fact_id: fact_id} =
                  ConditionFacts.file_in_txn(txn, %{
                    kind: "escalation-ruled",
                    scope: id,
                    origin: "process:tightbeam"
                  })

                Txn.q(txn, "UPDATE decision_requests SET rulingFactId = ?2 WHERE id = ?1", [
                  id,
                  fact_id
                ])

                EventLog.lifecycle_in_txn(
                  txn,
                  "decision_request_ruled",
                  id,
                  "by=#{call.origin} decision=waived factId=#{fact_id}"
                )

                [fact_id]
              else
                []
              end
            end)
          else
            []
          end

        {waiver_in_txn(txn, waiver_id), fact_ids}
      end)

    if fact_ids != [], do: nudge(opts, fact_ids)
    waiver
  end

  defp withdraw_open(db, request, by, reason) do
    withdrawn_at = now()

    {:ok, result} =
      DB.transaction(db, fn txn ->
        Txn.q(
          txn,
          "UPDATE decision_requests SET status = 'withdrawn', withdrawnBy = ?2, withdrawnReason = ?3, withdrawnAt = ?4 WHERE id = ?1 AND status = 'open'",
          [request.id, by, reason, withdrawn_at]
        )

        if Txn.changes(txn) == 1 do
          EventLog.lifecycle_in_txn(
            txn,
            "decision_request_withdrawn",
            request.id,
            "by=#{by} reason=#{reason}"
          )

          withdrawn = request_in_txn(txn, request.id)
          Publisher.maybe_accepted_in_txn(txn, request.firehose_call, withdrawn)
          withdrawn
        else
          error("not_open", "decision request is not open")
        end
      end)

    result
  end

  defp publish_request_replay(db, call, request) do
    {:ok, :ok} =
      DB.transaction(db, fn txn ->
        Publisher.maybe_accepted_in_txn(txn, call, request)
      end)

    request
  end

  defp resolve_decision(_request, decision) when decision in ["allow", "deny"],
    do: {:ok, decision}

  defp resolve_decision(request, label) when is_binary(label) do
    request.options
    |> List.wrap()
    |> Enum.find_value(fn option ->
      if option["label"] == label and option["effect"] in ["allow", "deny"],
        do: {:ok, option["effect"]}
    end)
    |> case do
      nil ->
        {:error, error("invalid_decision", "decision must be allow, deny, or an option label")}

      result ->
        result
    end
  end

  defp resolve_decision(_request, _decision),
    do: {:error, error("invalid_decision", "decision must be allow, deny, or an option label")}

  defp live_waiver?(db, raiser_id, statute_name) do
    {:ok, [[count]]} =
      DB.query(
        db,
        "SELECT COUNT(*) FROM escalation_waivers WHERE raiserId = ?1 AND statuteName = ?2 AND revokedAt IS NULL",
        [raiser_id, statute_name]
      )

    count > 0 and active_raiser?(db, raiser_id)
  end

  defp active_raiser?(db, "session:" <> session_key) do
    DB.query(db, "SELECT state FROM sessions WHERE sessionKey = ?1", [session_key]) ==
      {:ok, [["active"]]}
  end

  defp active_raiser?(_db, _raiser_id), do: true

  # THE GATE READ, and the one query in the tree whose result can halt a call.
  # `kind = 'statute'` is stated rather than left to SQL's NULL semantics: it is
  # already true that no other kind carries a `statuteName` to match, but the
  # clause that keeps a question out of a gate should be readable at the gate
  # rather than inferable from a CHECK three hundred lines up (fabric §10).
  defp current_request(db, raiser_id, statute_name, action_key) do
    {:ok, rows} =
      DB.query(
        db,
        "SELECT #{@request_columns} FROM decision_requests WHERE kind = 'statute' AND raiserId = ?1 AND statuteName = ?2 AND actionKey = ?3 ORDER BY rowid DESC LIMIT 1",
        [raiser_id, statute_name, action_key]
      )

    case rows do
      [row] -> request_from_row(row)
      [] -> nil
    end
  end

  @doc false
  def operator_ask_in_txn(txn, call, session_key, owner_user_id, ask) do
    raiser_id = Map.fetch!(call, :origin)
    action_key = operator_action_key(ask)

    case operator_open_in_txn(txn, owner_user_id, raiser_id, action_key) do
      nil ->
        with :ok <- filing_session_owner_in_txn(txn, session_key, owner_user_id),
             :ok <- linked_assignment_in_txn(txn, ask.assignment_id, owner_user_id),
             :ok <- superseded_request_in_txn(txn, ask.supersedes, owner_user_id, raiser_id) do
          insert_operator_request_in_txn(
            txn,
            session_key,
            owner_user_id,
            raiser_id,
            action_key,
            ask
          )
        else
          reason -> reason
        end

      request ->
        request
    end
  end

  defp insert_operator_request_in_txn(
         txn,
         session_key,
         owner_user_id,
         raiser_id,
         action_key,
         ask
       ) do
    request_id = "dr_" <> Tightbeam.Id.uuid4()
    raised_at = now()
    deadline_at = raised_at + ask.deadline_ms

    if ask.supersedes do
      Txn.q(
        txn,
        "UPDATE decision_requests SET status = 'superseded' WHERE id = ?1 AND kind = 'operator' AND status = 'open'",
        [ask.supersedes]
      )

      if Txn.changes(txn) != 1,
        do: raise(DB.Error, message: "operator supersede lost its open-row CAS")
    end

    Txn.q(
      txn,
      """
      INSERT INTO decision_requests
        (id, kind, raiserId, raiserSessionKey, ownerUserId, assignmentId,
         raisedAt, deadlineAt, actionKey, question, options, context, status)
      VALUES (?1, 'operator', ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, 'open')
      """,
      [
        request_id,
        raiser_id,
        session_key,
        owner_user_id,
        ask.assignment_id,
        raised_at,
        deadline_at,
        action_key,
        ask.question,
        JSON.encode!(ask.options),
        JSON.encode!(%{"note" => ask.note, "supersedes" => ask.supersedes})
      ]
    )

    request = request_in_txn(txn, request_id)

    EventLog.lifecycle_in_txn(
      txn,
      "decision_request_opened",
      request.id,
      "raiser=#{raiser_id} kind=operator owner=#{owner_user_id} assignment=#{ask.assignment_id || "nil"}"
    )

    if ask.supersedes do
      EventLog.lifecycle_in_txn(
        txn,
        "decision_request_superseded",
        ask.supersedes,
        "old=#{ask.supersedes} new=#{request.id} by=#{raiser_id}"
      )
    end

    Wakes.schedule_in_txn(txn, %{
      session_key: Org.personal_session_key(owner_user_id),
      origin: "process:tightbeam",
      prompt: operator_notification(request),
      due_at: raised_at,
      target_gate: 0
    })

    request
  end

  defp operator_rule_in_txn(txn, call, request_id, answer, opts) do
    case request_in_txn_optional(txn, request_id) do
      nil ->
        {error("not_found", "decision request not found"), nil}

      %{kind: "statute"} ->
        {error("invalid", "statute requests use rule"), nil}

      %{kind: "effort"} ->
        {error("invalid", "effort requests use effort-rule"), nil}

      %{kind: "agent"} ->
        {error("invalid", "agent requests use answer or return"), nil}

      request ->
        with :ok <- operator_owner_authorized(call, request) do
          case request.status do
            "ruled" ->
              replay_operator_ruling_in_txn(txn, call, request, answer)

            "consumed" ->
              case validate_operator_terminal_in_txn(txn, request, "detail", principal_id(call)) do
                :ok -> {error("not_open", "decision request is not open"), nil}
                {:error, refusal} -> {refusal, nil}
              end

            "open" ->
              with {:ok, decision} <- operator_decision(request, answer) do
                rule_operator_request_in_txn(txn, call, request, decision, answer, opts)
              else
                {:error, reason} -> {reason, nil}
              end

            _terminal_or_closed ->
              {error("not_open", "decision request is not open"), nil}
          end
        else
          {:error, reason} -> {reason, nil}
        end
    end
  end

  defp replay_operator_ruling_in_txn(txn, call, request, answer) do
    performer = principal_id(call)

    case validate_operator_terminal_in_txn(txn, request, "detail", performer) do
      :ok ->
        ruled_by = "user:" <> request.owner_user_id

        with {:ok, decision} <- operator_decision(request, answer) do
          if request.decision == decision and request.rationale == answer.rationale and
               request.ruled_by == ruled_by do
            {request, nil}
          else
            {error("not_open", "decision request is not open"), nil}
          end
        else
          {:error, reason} -> {reason, nil}
        end

      {:error, refusal} ->
        {refusal, nil}
    end
  end

  defp rule_operator_request_in_txn(txn, call, request, decision, answer, opts) do
    ruled_by = "user:" <> request.owner_user_id
    via_session = Map.get(call, :transport_session_key)
    performer = principal_id(call)
    via_state = if is_binary(via_session), do: "known", else: "none"

    if request.status == "open" do
      ruled_at = now()

      Wakes.schedule_in_txn(txn, %{
        session_key: request.raiser_session_key,
        origin: "process:tightbeam",
        prompt: operator_ruling_notification(request.id),
        due_at: ruled_at + operator_decision_duration(request),
        condition_kind: "escalation-ruled",
        condition_scope: request.id,
        creator_session_key: via_session,
        target_gate: 0
      })

      %{fact_id: fact_id} =
        ConditionFacts.file_in_txn(txn, %{
          kind: "escalation-ruled",
          scope: request.id,
          origin: "process:tightbeam"
        })

      Txn.q(
        txn,
        "UPDATE decision_requests SET status = 'ruled', decision = ?2, rationale = ?3, ruledBy = ?4, ruledViaSessionKey = ?5, ruledViaPrincipal = ?6, ruledViaSessionState = ?7, ruledAt = ?8, rulingFactId = ?9 WHERE id = ?1 AND kind = 'operator' AND status = 'open'",
        [
          request.id,
          decision,
          answer.rationale,
          ruled_by,
          via_session,
          performer,
          via_state,
          ruled_at,
          fact_id
        ]
      )

      if Txn.changes(txn) != 1,
        do: raise(DB.Error, message: "operator ruling lost its open-row CAS")

      EventLog.lifecycle_in_txn(
        txn,
        "decision_request_ruled",
        request.id,
        "by=#{ruled_by} decision=#{decision} factId=#{fact_id}"
      )

      ruled = request_in_txn(txn, request.id)

      case validate_operator_terminal_in_txn(txn, ruled, "detail", performer) do
        :ok ->
          Publisher.maybe_accepted_in_txn(txn, opts[:firehose_call], ruled)
          {ruled, fact_id}

        {:error, refusal} ->
          raise DB.Error, message: refusal.code
      end
    else
      {error("not_open", "decision request is not open"), nil}
    end
  end

  defp operator_withdraw_in_txn(txn, call, request_id, reason) do
    case request_in_txn_optional(txn, request_id) do
      nil ->
        error("not_found", "decision request not found")

      %{kind: "statute"} ->
        error("invalid", "statute requests use withdraw")

      %{kind: "effort"} ->
        error("invalid", "effort requests use effort-rule")

      %{kind: "agent"} ->
        error("invalid", "agent requests use return")

      request ->
        with {:ok, by} <- operator_withdrawer_in_txn(txn, call, request) do
          cond do
            request.status == "withdrawn" and request.withdrawn_by == by and
                request.withdrawn_reason == reason ->
              request

            request.status != "open" ->
              error("not_open", "decision request is not open")

            true ->
              Txn.q(
                txn,
                "UPDATE decision_requests SET status = 'withdrawn', withdrawnBy = ?2, withdrawnReason = ?3, withdrawnAt = ?4 WHERE id = ?1 AND kind = 'operator' AND status = 'open'",
                [request.id, by, reason, now()]
              )

              if Txn.changes(txn) != 1,
                do: raise(DB.Error, message: "operator withdrawal lost its open-row CAS")

              EventLog.lifecycle_in_txn(
                txn,
                "decision_request_withdrawn",
                request.id,
                "by=#{by} reason=#{reason}"
              )

              request_in_txn(txn, request.id)
          end
        else
          {:error, reason} -> reason
        end
    end
  end

  @terminal_schema_version "terminal-operator-decision-parity-v1"
  @terminal_shape_fields ~w(
    requestIdentity ownerOnBehalfOf options decision rationale ruledAt
    rulingFactId performerPrincipal performerSession lifecycleConsumption
    rulingLifecycleEvent raiserNotificationWake
  )

  defp validate_operator_terminal_in_txn(txn, request, surface, observer) do
    [[legacy_fact_max_id]] =
      Txn.q(
        txn,
        "SELECT legacyRulingFactMaxId FROM decision_request_terminal_epoch WHERE id = 0"
      )

    validate_operator_terminal_with_cutoff_in_txn(
      txn,
      request,
      legacy_fact_max_id,
      surface,
      observer
    )
  end

  defp validate_operator_terminal_with_cutoff_in_txn(
         txn,
         request,
         legacy_fact_max_id,
         surface,
         observer
       ) do
    fact_epoch =
      cond do
        not is_integer(request.ruling_fact_id) -> :unknown
        request.ruling_fact_id > legacy_fact_max_id -> :post_activation
        true -> :legacy
      end

    fact_shape = ruling_fact_shape_in_txn(txn, request)

    [[event_count]] =
      Txn.q(
        txn,
        "SELECT COUNT(*) FROM lifecycle_events WHERE kind = 'decision_request_ruled' AND subject = ?1",
        [request.id]
      )

    notification_count =
      if fact_epoch == :post_activation,
        do: operator_notification_count_in_txn(txn, request),
        else: 0

    request_identity_valid =
      canonical_request_id?(request.id) and request.kind == "operator" and
        nonblank?(request.raiser_id) and nonblank?(request.owner_user_id) and
        nonblank?(request.raiser_session_key) and nonblank?(request.action_key) and
        nonblank?(request.question) and is_integer(request.raised_at) and
        is_integer(request.deadline_at) and request.deadline_at > request.raised_at and
        (is_nil(request.assignment_id) or nonblank?(request.assignment_id)) and
        is_map(request.context)

    owner_valid =
      nonblank?(request.owner_user_id) and nonblank?(request.raiser_session_key) and
        request.ruled_by == "user:" <> request.owner_user_id

    options_valid = operator_options_valid?(request.options)
    decision_valid = normalized_text?(request.decision)
    rationale_valid = is_nil(request.rationale) or normalized_text?(request.rationale)
    ruled_at_valid = is_integer(request.ruled_at)

    fact_valid =
      is_integer(request.ruling_fact_id) and
        fact_shape["canonicalCardinality"] == "one"

    principal_valid = performer_principal_valid?(request, fact_epoch)
    session_valid = performer_session_valid?(request, fact_epoch)
    lifecycle_valid = request.status == "ruled" and is_nil(request.consumed_at)
    event_valid = event_count == 1
    notification_valid = fact_epoch != :post_activation or notification_count == 1

    checks = %{
      "requestIdentity" =>
        structural_check(request_identity_valid, %{
          "idType" => terminal_type_class(request.id),
          "idCanonical" => canonical_request_id?(request.id),
          "kindState" => terminal_kind_state(request.kind),
          "raiserIdType" => terminal_type_class(request.raiser_id),
          "ownerUserIdType" => terminal_type_class(request.owner_user_id),
          "raiserSessionKeyType" => terminal_type_class(request.raiser_session_key),
          "actionKeyType" => terminal_type_class(request.action_key),
          "questionType" => terminal_type_class(request.question),
          "raisedAtType" => terminal_type_class(request.raised_at),
          "deadlineAtType" => terminal_type_class(request.deadline_at),
          "deadlineOrder" => terminal_deadline_order(request.raised_at, request.deadline_at),
          "assignmentIdType" => terminal_optional_nonblank_class(request.assignment_id),
          "contextType" => terminal_type_class(request.context)
        }),
      "ownerOnBehalfOf" =>
        structural_check(owner_valid, %{
          "ownerUserIdType" => terminal_type_class(request.owner_user_id),
          "raiserSessionKeyType" => terminal_type_class(request.raiser_session_key),
          "ruledByType" => terminal_type_class(request.ruled_by),
          "ruledByMatchesOwner" => owner_valid
        }),
      "options" => structural_check(options_valid, operator_options_shape(request.options)),
      "decision" =>
        structural_check(decision_valid, %{
          "type" => terminal_type_class(request.decision),
          "normalizedNonblank" => decision_valid
        }),
      "rationale" =>
        structural_check(rationale_valid, %{
          "type" => terminal_type_class(request.rationale),
          "contractAccepted" => rationale_valid
        }),
      "ruledAt" =>
        structural_check(ruled_at_valid, %{"type" => terminal_type_class(request.ruled_at)}),
      "rulingFactId" =>
        structural_check(
          fact_valid,
          Map.put(fact_shape, "idType", terminal_type_class(request.ruling_fact_id))
        ),
      "performerPrincipal" =>
        structural_check(principal_valid, %{
          "epochState" => terminal_epoch_state(fact_epoch),
          "type" => terminal_type_class(request.ruled_via_principal),
          "canonical" => canonical_principal?(request.ruled_via_principal)
        }),
      "performerSession" =>
        structural_check(session_valid, %{
          "epochState" => terminal_epoch_state(fact_epoch),
          "stateClass" => terminal_session_state_class(request.ruled_via_session_state),
          "keyType" => terminal_type_class(request.ruled_via_session_key),
          "stateKeyConsistent" => terminal_session_state_key_consistent?(request)
        }),
      "lifecycleConsumption" =>
        structural_check(lifecycle_valid, %{
          "statusState" => terminal_status_state(request.status),
          "consumedAtType" => terminal_type_class(request.consumed_at)
        }),
      "rulingLifecycleEvent" =>
        structural_check(event_valid, %{
          "canonicalCardinality" => terminal_cardinality(event_count)
        }),
      "raiserNotificationWake" =>
        structural_check(notification_valid, %{
          "requirementState" => terminal_wake_requirement_state(fact_epoch),
          "canonicalCardinality" => terminal_cardinality(notification_count)
        })
    }

    failing_fields =
      @terminal_shape_fields
      |> Enum.reject(&get_in(checks, [&1, "valid"]))

    case failing_fields do
      [] ->
        :ok

      fields ->
        :ok = record_integrity_evidence_in_txn(txn, request.id, fields, checks, surface, observer)
        {:error, integrity_error(request.id)}
    end
  end

  defp structural_check(valid, shape), do: Map.put(shape, "valid", valid)

  defp ruling_fact_shape_in_txn(txn, request) do
    rows =
      Txn.q(
        txn,
        "SELECT kind, scope FROM condition_facts WHERE id = ?1",
        [request.ruling_fact_id]
      )

    case rows do
      [] ->
        %{
          "idCardinality" => "zero",
          "kindRelation" => "absent",
          "scopeRelation" => "absent",
          "canonicalCardinality" => "zero"
        }

      [[kind, scope]] ->
        kind_match = kind == "escalation-ruled"
        scope_match = scope == request.id

        %{
          "idCardinality" => "one",
          "kindRelation" => terminal_relation_state(kind_match),
          "scopeRelation" => terminal_relation_state(scope_match),
          "canonicalCardinality" => if(kind_match and scope_match, do: "one", else: "zero")
        }

      _rows ->
        %{
          "idCardinality" => "many",
          "kindRelation" => "ambiguous",
          "scopeRelation" => "ambiguous",
          "canonicalCardinality" => "many"
        }
    end
  end

  defp operator_options_shape(options) do
    nonempty = is_list(options) and options != []

    objects =
      is_list(options) and
        Enum.all?(options, &is_map/1)

    sole_label_key =
      objects and
        Enum.all?(options, fn option -> Map.keys(option) == ["label"] end)

    labels =
      if sole_label_key,
        do: Enum.map(options, &Map.fetch!(&1, "label")),
        else: []

    labels_nonblank =
      sole_label_key and Enum.all?(labels, &nonblank?/1)

    labels_normalized =
      labels_nonblank and Enum.all?(labels, &(String.trim(&1) == &1))

    labels_distinct =
      labels_normalized and Enum.uniq(labels) == labels

    %{
      "type" => terminal_type_class(options),
      "nonempty" => nonempty,
      "membersAreObjects" => objects,
      "soleLabelKey" => sole_label_key,
      "labelsNonblankStrings" => labels_nonblank,
      "labelsNormalized" => labels_normalized,
      "labelsDistinct" => labels_distinct
    }
  end

  defp terminal_type_class(nil), do: "null"
  defp terminal_type_class(value) when is_binary(value) and value == "", do: "string-empty"

  defp terminal_type_class(value) when is_binary(value) do
    if String.trim(value) == "", do: "string-blank", else: "string-nonblank"
  end

  defp terminal_type_class(value) when is_integer(value), do: "integer"
  defp terminal_type_class(value) when is_float(value), do: "number"
  defp terminal_type_class(value) when is_boolean(value), do: "boolean"
  defp terminal_type_class(value) when is_list(value), do: "array"
  defp terminal_type_class(value) when is_map(value), do: "object"
  defp terminal_type_class(_value), do: "other"

  defp terminal_optional_nonblank_class(nil), do: "null"
  defp terminal_optional_nonblank_class(value), do: terminal_type_class(value)

  defp terminal_deadline_order(raised_at, deadline_at)
       when is_integer(raised_at) and is_integer(deadline_at) do
    if deadline_at > raised_at, do: "after", else: "not-after"
  end

  defp terminal_deadline_order(_raised_at, _deadline_at), do: "not-comparable"

  defp terminal_kind_state("operator"), do: "operator"
  defp terminal_kind_state(_kind), do: "other"

  defp terminal_epoch_state(:post_activation), do: "post-activation"
  defp terminal_epoch_state(:legacy), do: "legacy"
  defp terminal_epoch_state(:unknown), do: "unknown"

  defp terminal_session_state_class("known"), do: "known"
  defp terminal_session_state_class("none"), do: "none"
  defp terminal_session_state_class(nil), do: "null"
  defp terminal_session_state_class(_state), do: "other"

  defp terminal_session_state_key_consistent?(request) do
    (request.ruled_via_session_state == "known" and
       nonblank?(request.ruled_via_session_key)) or
      (request.ruled_via_session_state == "none" and
         is_nil(request.ruled_via_session_key)) or
      (is_nil(request.ruled_via_session_state) and
         (is_nil(request.ruled_via_session_key) or nonblank?(request.ruled_via_session_key)))
  end

  defp terminal_status_state("ruled"), do: "ruled"
  defp terminal_status_state("consumed"), do: "consumed"
  defp terminal_status_state(_status), do: "other"

  defp terminal_wake_requirement_state(:post_activation), do: "required"
  defp terminal_wake_requirement_state(:legacy), do: "not-required-legacy"
  defp terminal_wake_requirement_state(:unknown), do: "unknown"

  defp terminal_relation_state(true), do: "match"
  defp terminal_relation_state(false), do: "mismatch"

  defp terminal_cardinality(0), do: "zero"
  defp terminal_cardinality(1), do: "one"
  defp terminal_cardinality(count) when is_integer(count) and count > 1, do: "many"
  defp terminal_cardinality(_count), do: "unknown"

  defp operator_notification_count_in_txn(txn, request) do
    prompt = operator_ruling_notification(request.id)
    expected_creator = request.ruled_via_session_key

    expected_due_at =
      if is_integer(request.ruled_at),
        do: request.ruled_at + operator_decision_duration(request),
        else: nil

    [[count]] =
      Txn.q(
        txn,
        """
        SELECT COUNT(*) FROM wakes
        WHERE sessionKey = ?1 AND targetRole IS NULL AND origin = 'process:tightbeam'
          AND prompt = ?2 AND consumer = 'prompt'
          AND conditionKind = 'escalation-ruled' AND conditionScope = ?3
          AND conditionAfterId < ?4 AND dueAt = ?5 AND targetGate = 0
          AND reresolve IS NULL AND reresolveSeed IS NULL AND reresolveRung IS NULL
          AND ((?6 IS NULL AND creatorSessionKey IS NULL) OR creatorSessionKey = ?6)
          AND ((state = 'pending' AND firedAt IS NULL AND firedBy IS NULL)
               OR (state = 'fired' AND firedAt IS NOT NULL AND firedBy = 'condition'))
        """,
        [
          request.raiser_session_key,
          prompt,
          request.id,
          request.ruling_fact_id,
          expected_due_at,
          expected_creator
        ]
      )

    count
  end

  defp performer_principal_valid?(request, :post_activation),
    do: canonical_principal?(request.ruled_via_principal)

  defp performer_principal_valid?(request, :legacy),
    do: is_nil(request.ruled_via_principal)

  defp performer_principal_valid?(request, :unknown),
    do: is_nil(request.ruled_via_principal) or canonical_principal?(request.ruled_via_principal)

  defp performer_session_valid?(request, :post_activation) do
    (request.ruled_via_session_state == "known" and
       nonblank?(request.ruled_via_session_key)) or
      (request.ruled_via_session_state == "none" and
         is_nil(request.ruled_via_session_key))
  end

  defp performer_session_valid?(request, :legacy),
    do: is_nil(request.ruled_via_session_state)

  defp performer_session_valid?(request, :unknown),
    do:
      performer_session_valid?(request, :post_activation) or
        performer_session_valid?(request, :legacy)

  defp record_integrity_evidence_in_txn(txn, request_id, fields, checks, surface, observer) do
    fields = Enum.sort(fields)
    cause_code = "terminal-shape-invalid"

    descriptor = %{
      "schemaVersion" => @terminal_schema_version,
      "causeCode" => cause_code,
      "checks" => checks,
      "failingFields" => fields
    }

    digest =
      :crypto.hash(:sha256, canonical_json(descriptor))
      |> Base.encode16(case: :lower)

    failing_fields = JSON.encode!(fields)

    try do
      Txn.q(
        txn,
        """
        INSERT OR IGNORE INTO decision_request_integrity_evidence
          (requestId, shapeDigest, schemaVersion, causeCode, failingFields,
           firstSurface, firstObservedAt, observerPrincipal)
        VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)
        """,
        [
          request_id,
          digest,
          @terminal_schema_version,
          cause_code,
          failing_fields,
          surface,
          now(),
          observer
        ]
      )
    rescue
      _error in DB.Error ->
        raise DB.Error, message: "decision_request_integrity_evidence_unavailable"
    end

    existing =
      try do
        Txn.q(
          txn,
          "SELECT schemaVersion,causeCode,failingFields FROM decision_request_integrity_evidence WHERE requestId = ?1 AND shapeDigest = ?2",
          [request_id, digest]
        )
      rescue
        _error in DB.Error ->
          raise DB.Error, message: "decision_request_integrity_evidence_unavailable"
      end

    case existing do
      [[@terminal_schema_version, ^cause_code, ^failing_fields]] ->
        :ok

      [[]] ->
        raise DB.Error, message: "decision_request_integrity_evidence_unavailable"

      [] ->
        raise DB.Error, message: "decision_request_integrity_evidence_unavailable"

      [_different] ->
        raise DB.Error, message: "decision_request_integrity_evidence_conflict"
    end
  end

  @doc false
  @spec terminal_operator_projection(map()) :: map()
  def terminal_operator_projection(request) do
    %{
      id: request.id,
      kind: request.kind,
      status: request.status,
      question: request.question,
      options: request.options,
      raiser_id: request.raiser_id,
      raiser_session_key: request.raiser_session_key,
      owner_user_id: request.owner_user_id,
      assignment_id: request.assignment_id,
      raised_at: request.raised_at,
      deadline_at: request.deadline_at,
      decision: request.decision,
      rationale: request.rationale,
      ruled_by: request.ruled_by,
      ruled_via_session_key: request.ruled_via_session_key,
      ruled_at: request.ruled_at,
      ruling_fact_id: request.ruling_fact_id,
      consumed_at: request.consumed_at,
      ruling_attribution: operator_ruling_attribution(request)
    }
  end

  defp operator_ruling_attribution(request) do
    %{
      on_behalf_of: request.ruled_by,
      performer: %{
        principal: performer_principal_projection(request),
        session: performer_session_projection(request)
      }
    }
  end

  defp performer_principal_projection(%{ruled_via_principal: principal})
       when is_binary(principal),
       do: %{state: "known", value: principal}

  defp performer_principal_projection(_request), do: %{state: "legacy-unknown"}

  defp performer_session_projection(%{
         ruled_via_session_state: "known",
         ruled_via_session_key: session_key
       }),
       do: %{state: "known", key: session_key}

  defp performer_session_projection(%{ruled_via_session_state: "none"}),
    do: %{state: "none"}

  defp performer_session_projection(%{ruled_via_session_key: session_key})
       when is_binary(session_key),
       do: %{state: "known", key: session_key}

  defp performer_session_projection(_request), do: %{state: "legacy-unknown"}

  defp integrity_error(request_id),
    do: %{
      code: "decision_request_integrity_invalid",
      message: "decision request integrity check failed",
      request_id: request_id
    }

  defp integrity_evidence_error(code),
    do: %{
      code: code,
      message: "decision request integrity evidence could not be recorded"
    }

  defp unwrap_integrity_transaction({:ok, result}), do: result

  defp unwrap_integrity_transaction({:error, error}),
    do: integrity_transaction_error!(error)

  defp integrity_transaction_error!(%DB.Error{message: code})
       when code in [
              "decision_request_integrity_evidence_conflict",
              "decision_request_integrity_evidence_unavailable"
            ],
       do: integrity_evidence_error(code)

  defp integrity_transaction_error!(error), do: raise(error)

  defp canonical_request_id?(id) when is_binary(id),
    do:
      Regex.match?(
        ~r/\Adr_[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\z/,
        id
      )

  defp canonical_request_id?(_id), do: false

  defp canonical_principal?("user:" <> suffix), do: nonblank?(suffix)
  defp canonical_principal?("session:" <> suffix), do: nonblank?(suffix)
  defp canonical_principal?(_principal), do: false

  defp nonblank?(value) when is_binary(value), do: String.trim(value) != ""
  defp nonblank?(_value), do: false

  # Every read that treats `ruled` as a fact uses this same base invariant.
  # Operator rulings additionally pass through their attribution/fact audit.
  defp ruled_decision_complete?(request),
    do:
      normalized_text?(request.decision) and normalized_text?(request.ruled_by) and
        is_integer(request.ruled_at)

  defp normalized_text?(value) when is_binary(value),
    do: value != "" and String.trim(value) == value

  defp normalized_text?(_value), do: false

  defp operator_options_valid?(options) when is_list(options) and options != [] do
    labels =
      Enum.map(options, fn
        %{"label" => label} = option when map_size(option) == 1 -> label
        _option -> nil
      end)

    Enum.all?(labels, &nonblank?/1) and Enum.uniq(Enum.map(labels, &String.trim/1)) == labels
  end

  defp operator_options_valid?(_options), do: false

  defp operator_decision_duration(request)
       when is_integer(request.deadline_at) and is_integer(request.raised_at) and
              request.deadline_at > request.raised_at,
       do: request.deadline_at - request.raised_at

  defp operator_decision_duration(_request), do: decision_deadline_ms()

  defp get_raw(_db, nil), do: nil

  defp get_raw(db, id) do
    {:ok, rows} =
      DB.query(db, "SELECT #{@request_columns} FROM decision_requests WHERE id = ?1", [id])

    case rows do
      [row] -> request_from_row(row)
      [] -> nil
    end
  end

  defp request_in_txn(txn, id) do
    [row] = Txn.q(txn, "SELECT #{@request_columns} FROM decision_requests WHERE id = ?1", [id])
    request_from_row(row)
  end

  defp request_in_txn_optional(_txn, nil), do: nil

  defp request_in_txn_optional(txn, id) do
    case Txn.q(txn, "SELECT #{@request_columns} FROM decision_requests WHERE id = ?1", [id]) do
      [row] -> request_from_row(row)
      [] -> nil
    end
  end

  defp legacy_request_from_row(row) do
    {through_ruled_by, from_ruled_at} = Enum.split(row, 22)
    request_from_row(through_ruled_by ++ [nil, nil, nil] ++ from_ruled_at)
  end

  defp request_from_row([
         id,
         kind,
         raiser_id,
         raiser_session_key,
         owner_user_id,
         assignment_id,
         expecter_session_key,
         expecter_user_id,
         lineage_rung,
         effort_generation,
         deadline_wake_id,
         raised_at,
         deadline_at,
         statute_name,
         action_key,
         question,
         options,
         context,
         status,
         decision,
         rationale,
         ruled_by,
         ruled_via_session_key,
         ruled_via_principal,
         ruled_via_session_state,
         ruled_at,
         ruling_fact_id,
         consumed_at,
         park_wake_id,
         withdrawn_by,
         withdrawn_reason,
         withdrawn_at,
         asked_of_role,
         answer,
         answered_by,
         answered_at,
         returned_by,
         return_reason,
         returned_at
       ]) do
    %{
      id: id,
      kind: kind,
      raiser_id: raiser_id,
      raiser_session_key: raiser_session_key,
      owner_user_id: owner_user_id,
      assignment_id: assignment_id,
      expecter_session_key: expecter_session_key,
      expecter_user_id: expecter_user_id,
      lineage_rung: lineage_rung,
      effort_generation: effort_generation,
      deadline_wake_id: deadline_wake_id,
      raised_at: raised_at,
      deadline_at: deadline_at,
      statute_name: statute_name,
      action_key: action_key,
      question: question,
      options: decode_optional(options),
      context: decode_required(context),
      status: status,
      decision: decision,
      rationale: rationale,
      ruled_by: ruled_by,
      ruled_via_session_key: ruled_via_session_key,
      ruled_via_principal: ruled_via_principal,
      ruled_via_session_state: ruled_via_session_state,
      ruled_at: ruled_at,
      ruling_fact_id: ruling_fact_id,
      consumed_at: consumed_at,
      park_wake_id: park_wake_id,
      withdrawn_by: withdrawn_by,
      withdrawn_reason: withdrawn_reason,
      withdrawn_at: withdrawn_at,
      asked_of_role: asked_of_role,
      answer: answer,
      answered_by: answered_by,
      answered_at: answered_at,
      returned_by: returned_by,
      return_reason: return_reason,
      returned_at: returned_at
    }
  end

  defp list_projection(%{kind: "operator", status: "ruled"} = request),
    do: terminal_operator_projection(request)

  defp list_projection(%{kind: "operator"} = request),
    do:
      Map.take(request, [
        :id,
        :kind,
        :status,
        :question,
        :options,
        :raiser_id,
        :raiser_session_key,
        :owner_user_id,
        :assignment_id,
        :raised_at,
        :deadline_at
      ])

  defp list_projection(request),
    do:
      Map.drop(request, [
        :context,
        :action_key,
        :owner_user_id,
        :ruling_fact_id,
        :consumed_at,
        :park_wake_id,
        :withdrawn_by
      ])

  defp waiver_in_txn(txn, id) do
    [[id, raiser_id, statute_name, granted_by, granted_at, reason, revoked_by, revoked_at]] =
      Txn.q(
        txn,
        "SELECT id, raiserId, statuteName, grantedBy, grantedAt, reason, revokedBy, revokedAt FROM escalation_waivers WHERE id = ?1",
        [id]
      )

    %{
      id: id,
      raiser_id: raiser_id,
      statute_name: statute_name,
      granted_by: granted_by,
      granted_at: granted_at,
      reason: reason,
      revoked_by: revoked_by,
      revoked_at: revoked_at
    }
  end

  defp visibility(call, owner_user_id) do
    raiser = raiser_id(call)

    effort =
      case call.principal do
        {:session, key} -> {"expecterSessionKey = ?", key}
        {:user, user} -> {"expecterUserId = ?", user}
        _ -> {"0", nil}
      end

    statute =
      if is_binary(owner_user_id),
        do: {"(ownerUserId = ? OR raiserId = ?)", [owner_user_id, raiser]},
        else: {"raiserId = ?", [raiser]}

    {effort_sql, effort_params} =
      case effort do
        {"0", nil} -> {"0", []}
        {sql, value} -> {sql, [value]}
      end

    {statute_sql, statute_params} = statute
    {agent_sql, agent_params} = agent_visibility(call, raiser, owner_user_id)
    {operator_sql, operator_params} = operator_visibility(call, raiser, owner_user_id)
    params = statute_params ++ effort_params ++ agent_params ++ operator_params

    numbered =
      ("(kind = 'statute' AND #{statute_sql}) OR (kind = 'effort' AND #{effort_sql})" <>
         " OR (kind = 'agent' AND #{agent_sql})" <>
         " OR (kind = 'operator' AND #{operator_sql})")
      |> number_placeholders()

    {numbered, params}
  end

  # THREE principals can see an agent question and no fourth: the asker, the
  # principal it was asked of, and the owner accountable for the asker. Both
  # asked-side columns are stamped at file time, so this is a column comparison
  # rather than a join that could disagree with the row.
  #
  # The `ownerUserId` branch is that THIRD principal — the owner, acting AS
  # itself — and it must fire only when the caller's own principal IS that
  # user, never merely because `owner_user_id` (resolved upstream from the
  # caller's session) happens to equal the row's owner. Every session an owner
  # runs shares that same resolved owner id, so gating on the value alone let
  # one of the owner's UNRELATED sessions see a question it was never asker,
  # asked, nor acting-as-owner for (Sol xhigh review, finding 3: Alice's
  # `reviewer` session could see `coder`'s question to Bob through Alice's
  # owner id, despite being a fourth, uninvolved principal).
  defp agent_visibility(call, raiser, owner_user_id) do
    {asked_sql, asked_params} =
      case call.principal do
        {:session, key} -> {"expecterSessionKey = ?", [key]}
        {:user, user} -> {"expecterUserId = ?", [user]}
        _ -> {"0", []}
      end

    case call.principal do
      {:user, ^owner_user_id} when is_binary(owner_user_id) ->
        {"(raiserId = ? OR ownerUserId = ? OR #{asked_sql})",
         [raiser, owner_user_id] ++ asked_params}

      _ ->
        {"(raiserId = ? OR #{asked_sql})", [raiser] ++ asked_params}
    end
  end

  defp operator_visibility(%{principal: {:user, user_id}}, _raiser, _owner_user_id),
    do: {"ownerUserId = ?", [user_id]}

  defp operator_visibility(%{principal: {:session, key}}, _raiser, _owner_user_id),
    do: {"raiserSessionKey = ?", [key]}

  defp operator_visibility(_call, _raiser, _owner_user_id), do: {"0", []}

  defp normalize_operator_ask(call) do
    with {:ok, question} <- normalized_required(param(call, :question), "question is required"),
         {:ok, note} <- normalized_optional(param(call, :note)),
         {:ok, options} <- normalize_operator_options(param(call, :options)),
         {:ok, assignment_id} <- normalized_optional(operator_assignment_id(call)),
         {:ok, supersedes} <- normalized_optional(param(call, :supersedes)),
         {:ok, deadline_ms} <- normalize_operator_deadline(param(call, :deadline)) do
      {:ok,
       %{
         question: question,
         note: note,
         options: options,
         assignment_id: assignment_id,
         supersedes: supersedes,
         deadline_ms: deadline_ms
       }}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp normalize_operator_answer(call) do
    decision = param(call, :decision)
    response = param(call, :response)

    with {:ok, rationale} <- normalized_optional(param(call, :rationale)) do
      case {decision, response} do
        {decision, nil} when is_binary(decision) ->
          with {:ok, value} <- normalized_required(decision, "decision must be non-blank"),
               do: {:ok, %{mode: "label", value: value, rationale: rationale}}

        {nil, response} when is_binary(response) ->
          with {:ok, value} <- normalized_required(response, "response must be non-blank"),
               do: {:ok, %{mode: "text", value: value, rationale: rationale}}

        _ ->
          {:error, error("invalid", "operator-rule requires exactly one of decision or response")}
      end
    end
  end

  defp normalize_operator_options(nil),
    do: {:ok, [%{"label" => "accept"}, %{"label" => "dismiss"}]}

  defp normalize_operator_options(options) when is_list(options) and options != [] do
    labels =
      Enum.map(options, fn option ->
        if operator_option_shape?(option), do: Map.get(option, :label) || Map.get(option, "label")
      end)

    if Enum.all?(labels, &nonblank?/1) do
      normalized = Enum.map(labels, &String.trim/1)

      if Enum.uniq(normalized) == normalized,
        do: {:ok, Enum.map(normalized, &%{"label" => &1})},
        else: {:error, error("invalid", "option labels must be unique")}
    else
      {:error, error("invalid", "options require non-blank labels")}
    end
  end

  defp normalize_operator_options(_),
    do: {:error, error("invalid", "options require a non-empty label array")}

  defp operator_option_shape?(option) when is_map(option),
    do: option |> Map.keys() |> Enum.map(&to_string/1) |> Enum.sort() == ["label"]

  defp operator_option_shape?(_option), do: false

  defp normalize_operator_deadline(nil), do: {:ok, decision_deadline_ms()}
  defp normalize_operator_deadline(value) when is_integer(value) and value > 0, do: {:ok, value}

  defp normalize_operator_deadline(_),
    do: {:error, error("invalid", "deadline must be a positive duration")}

  defp normalized_required(value, message) when is_binary(value) do
    case String.trim(value) do
      "" -> {:error, error("invalid", message)}
      normalized -> {:ok, normalized}
    end
  end

  defp normalized_required(_value, message), do: {:error, error("invalid", message)}
  defp normalized_optional(nil), do: {:ok, nil}

  defp normalized_optional(value) when is_binary(value) do
    case String.trim(value) do
      "" -> {:ok, nil}
      normalized -> {:ok, normalized}
    end
  end

  defp normalized_optional(_), do: {:error, error("invalid", "text values must be strings")}

  defp operator_action_key(ask) do
    canonical = %{
      "normalizedQuestion" => ask.question,
      "normalizedOptions" => ask.options,
      "normalizedNote" => ask.note,
      "assignmentId" => ask.assignment_id,
      "supersedes" => ask.supersedes
    }

    :crypto.hash(:sha256, canonical_json(canonical)) |> Base.encode16(case: :lower)
  end

  defp operator_assignment_id(call),
    do: param(call, :assignment_id) || param(call, :assignment)

  defp filing_session_owner_in_txn(txn, session_key, owner_user_id) do
    case Txn.q(txn, "SELECT ownerUserId FROM sessions WHERE sessionKey = ?1", [session_key]) do
      [[^owner_user_id]] -> :ok
      _ -> error("not_owner", "filing session has no accountable owner")
    end
  end

  defp linked_assignment_in_txn(_txn, nil, _owner_user_id), do: :ok

  defp linked_assignment_in_txn(txn, assignment_id, owner_user_id) do
    case Txn.q(
           txn,
           "SELECT a.state, s.ownerUserId FROM assignments a JOIN sessions s ON s.sessionKey = a.holderKey WHERE a.id = ?1",
           [assignment_id]
         ) do
      [] -> error("not_found", "linked assignment not found")
      [[state, _owner]] when state != "open" -> error("not_open", "linked assignment is not open")
      [["open", ^owner_user_id]] -> :ok
      [["open", _owner]] -> error("not_owner", "linked assignment belongs to another owner")
    end
  end

  defp superseded_request_in_txn(_txn, nil, _owner_user_id, _raiser_id), do: :ok

  defp superseded_request_in_txn(txn, request_id, owner_user_id, raiser_id) do
    case request_in_txn_optional(txn, request_id) do
      nil ->
        error("not_found", "superseded request not found")

      %{kind: kind} when kind != "operator" ->
        error("invalid", "only operator requests can be superseded")

      %{owner_user_id: owner} when owner != owner_user_id ->
        error("not_owner", "superseded request belongs to another owner")

      %{raiser_id: raiser} when raiser != raiser_id ->
        error("not_owner", "only the same raiser can supersede a request")

      %{status: "open"} ->
        :ok

      _ ->
        error("not_open", "superseded request is not open")
    end
  end

  defp operator_open_in_txn(txn, owner_user_id, raiser_id, action_key) do
    case Txn.q(
           txn,
           "SELECT #{@request_columns} FROM decision_requests WHERE kind = 'operator' AND ownerUserId = ?1 AND raiserId = ?2 AND actionKey = ?3 AND status = 'open' ORDER BY rowid DESC LIMIT 1",
           [owner_user_id, raiser_id, action_key]
         ) do
      [row] -> request_from_row(row)
      [] -> nil
    end
  end

  defp operator_owner_authorized(call, request) do
    case Map.get(call, :principal) do
      {:user, owner_user_id} when owner_user_id == request.owner_user_id ->
        if Map.get(call, :transport_session_key) == Org.personal_session_key(owner_user_id),
          do:
            {:error,
             error("proxy_only", "Main may proxy operator requests but never resolves them")},
          else: :ok

      _ ->
        {:error, error("not_owner", "only the operator resolves an operator request")}
    end
  end

  defp operator_decision(request, %{mode: "label", value: value}) do
    labels = Enum.map(request.options, &Map.fetch!(&1, "label"))

    if value in labels,
      do: {:ok, value},
      else:
        {:error, error("invalid_decision", "decision must be one of: #{Enum.join(labels, ", ")}")}
  end

  defp operator_decision(_request, %{mode: "text", value: value}), do: {:ok, value}

  defp operator_withdrawer_in_txn(txn, call, request) do
    case Map.get(call, :principal) do
      {:user, owner_user_id} when owner_user_id == request.owner_user_id ->
        {:ok, "user:" <> owner_user_id}

      {:session, session_key} ->
        case Txn.q(txn, "SELECT ownerUserId FROM sessions WHERE sessionKey = ?1", [session_key]) do
          [[owner_user_id]]
          when owner_user_id == request.owner_user_id and call.origin == request.raiser_id ->
            {:ok, call.origin}

          _ ->
            {:error, error("not_owner", "operator or same-owner raiser required")}
        end

      _ ->
        {:error, error("not_owner", "operator or same-owner raiser required")}
    end
  end

  defp shift_params(where) do
    Regex.replace(~r/\?(\d+)/, where, fn _, number ->
      "?" <> Integer.to_string(String.to_integer(number) + 1)
    end)
  end

  defp number_placeholders(sql) do
    {parts, _} =
      String.split(sql, "?")
      |> Enum.map_reduce(0, fn
        part, 0 -> {part, 1}
        part, index -> {"#{index}" <> part, index + 1}
      end)

    Enum.join(parts, "?")
  end

  # An ordinary request is keyed by the exact action its raiser attempted. An EPISODE is
  # keyed by the condition instead, so every caller tripping the same condition on the
  # same statute lands on one request: `decision_requests_one_open` then does the dedup
  # that already exists, with no second mechanism to keep in step.
  defp action_key(_call, episode_key) when is_binary(episode_key),
    do: @episode_prefix <> episode_key

  defp action_key(call, nil), do: digest(call)

  # An episode-keyed request is raised by the substrate, not by whoever happened to trip
  # it: the dedup key is (statute, episode_key) alone, so binding it to a session would
  # both fragment the episode per caller and let `withdraw_for_retired/2` retire an
  # episode that outlives any one session. The owner still comes from the real call, so
  # the notification lands with an accountable person. Same shape the effort requests use.
  defp raiser(_call, episode_key) when is_binary(episode_key), do: {"process:tightbeam", nil}
  defp raiser(call, nil), do: {raiser_id(call), raiser_session_key(call)}

  defp raiser_id(%{principal: {:session, key}}), do: "session:" <> key
  defp raiser_id(call), do: Map.fetch!(call, :origin)

  defp raiser_session_key(%{principal: {:session, key}}), do: key
  defp raiser_session_key(_call), do: nil

  defp owner_user_id!(db, %{principal: {:session, key}}) do
    case Org.get(db, key) do
      %{owner_user_id: owner} -> owner
      _ -> raise ArgumentError, "unknown raiser session: #{key}"
    end
  end

  defp owner_user_id!(_db, %{principal: {:user, user_id}}), do: user_id

  defp owner_user_id!(_db, %{origin: "user:" <> user_id}), do: user_id

  defp owner_user_id!(db, %{origin: "agent:" <> role}) do
    with {:ok, session_key, _fallback} <- Roles.resolve(db, role),
         %{owner_user_id: owner} <- Org.get(db, session_key) do
      owner
    else
      _ -> raise ArgumentError, "unknown raiser origin: agent:#{role}"
    end
  end

  defp owner_user_id!(_db, call),
    do: raise(ArgumentError, "raiser has no accountable owner: #{call.origin}")

  defp statute_name(statute), do: Map.get(statute, :name) || Map.fetch!(statute, "name")

  defp deny_error(statute) do
    %{
      code: "escalation_denied",
      message: Map.get(statute, :text) || Map.get(statute, "text") || "owner denied the action"
    }
  end

  defp assignment_id(call) do
    params = Map.fetch!(call, :params)

    Map.get(params, :assignment_id) || Map.get(params, "assignment_id") ||
      Map.get(params, "assignmentId")
  end

  defp param(call, key),
    do: Map.get(call.params, key) || Map.get(call.params, Atom.to_string(key))

  defp decision_deadline_ms,
    do:
      Application.get_env(
        :tightbeam,
        :escalation_decision_deadline_ms,
        @default_decision_deadline_ms
      )

  defp fetch_string!(map, key) do
    value = Map.get(map, key) || Map.get(map, Atom.to_string(key))
    if is_binary(value), do: value, else: raise(ArgumentError, "#{key} is required")
  end

  defp owner_notification(request) do
    options = if request.options, do: "\nOptions: #{JSON.encode!(request.options)}", else: ""

    "Decision #{request.id} pending on #{request.statute_name}.\n" <>
      request.question <>
      options <>
      "\nContext: #{JSON.encode!(request.context)}"
  end

  defp operator_notification(request) do
    "Decision #{request.id}: #{request.question}\nOptions: #{JSON.encode!(request.options)}"
  end

  defp operator_ruling_notification(request_id) do
    "Decision request #{request_id} was ruled. Read it with tightbeam decision-request --request #{request_id}."
  end

  defp nudge(opts, fact_ids) do
    case Keyword.get(opts, :scheduler) do
      nil ->
        :ok

      scheduler ->
        # One ordered call: the scheduler serves fact_ids strictly in filing
        # order (a later fact's fan-out never overtakes an earlier fact's).
        Wakes.fire_matching(scheduler, fact_ids)
    end
  end

  defp normalize_map(map) do
    Map.new(map, fn {key, value} -> {to_string(key), normalize_value(value)} end)
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp normalize_value(value) when is_map(value), do: normalize_map(value)
  defp normalize_value(value) when is_list(value), do: Enum.map(value, &normalize_value/1)
  defp normalize_value(value), do: value

  defp canonical_json(value) when is_map(value) do
    members =
      value
      |> Enum.reject(fn {_key, item} -> is_nil(item) end)
      |> Enum.map(fn {key, item} -> {to_string(key), item} end)
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.map(fn {key, item} -> [JSON.encode!(key), ?:, canonical_json(item)] end)
      |> Enum.intersperse(?,)

    IO.iodata_to_binary([?{, members, ?}])
  end

  defp canonical_json(value) when is_list(value) do
    items = value |> Enum.map(&canonical_json/1) |> Enum.intersperse(?,)
    IO.iodata_to_binary([?[, items, ?]])
  end

  defp canonical_json(value), do: JSON.encode!(value)

  defp encode_optional(nil), do: nil
  defp encode_optional(value), do: JSON.encode!(value)
  defp decode_optional(nil), do: nil
  defp decode_optional(value), do: decode_required(value)

  defp decode_required(value) do
    JSON.decode!(value)
  rescue
    _error -> :invalid_json
  end

  defp validate_options!(nil), do: nil

  defp validate_options!(options) when is_list(options) do
    Enum.map(options, fn option ->
      label = Map.get(option, :label) || Map.get(option, "label")
      effect = Map.get(option, :effect) || Map.get(option, "effect")

      if is_binary(label) and effect in ["allow", "deny"] do
        %{"label" => label, "effect" => effect}
      else
        raise ArgumentError, "options must contain label and allow|deny effect"
      end
    end)
  end

  defp validate_options!(_options),
    do: raise(ArgumentError, "options must contain label and allow|deny effect")

  defp error(code, message), do: %{code: code, message: message}
  defp now, do: System.system_time(:millisecond)
end
