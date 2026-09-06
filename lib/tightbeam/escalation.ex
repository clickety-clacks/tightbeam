defmodule Tightbeam.Escalation do
  @moduledoc """
  Durable decision requests and raiser-scoped escalation waivers.

  `resolve/3` is an effect-free gate read. `escalate/4` owns request opening,
  while `consume/2` is the per-ruling verb-edge CAS. A caller consuming a
  batch must fail closed if any CAS loses; earlier winners stay consumed.
  """

  alias Tightbeam.{ConditionFacts, DB, EventLog, Org, Roles, Wakes}
  alias Tightbeam.DB.Txn

  defmodule IntegrityEvidenceConflict do
    @moduledoc false
    defexception [:message]
  end

  defmodule IntegrityEvidenceUnavailable do
    @moduledoc false
    defexception [:message]
  end

  @default_decision_deadline_ms 86_400_000
  @terminal_schema_version "terminal-operator-decision-parity-v1"
  @terminal_condition_kind "escalation-ruled"
  @terminal_integrity_code "decision_request_integrity_invalid"
  @terminal_evidence_cause "terminal-shape-invalid"
  @terminal_failure_fields ~w(
    requestIdentity ownerOnBehalfOf options decision rationale ruledAt
    rulingFactId performerPrincipal performerSession lifecycleConsumption
    rulingLifecycleEvent raiserNotificationWake
  )

  # The `status` values a decision request row can hold — the schema CHECK's own set
  # (see @ddl). `list/4` accepts these plus the sentinel "all" (no status filter); any
  # other value is refused by `list_status/1` so a typo names the legal set instead of
  # silently filtering on a status that can never exist.
  @request_statuses ~w(open ruled consumed withdrawn superseded)
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

  @ddl """
  CREATE TABLE IF NOT EXISTS decision_requests (
    id                TEXT PRIMARY KEY,
    kind              TEXT NOT NULL DEFAULT 'statute' CHECK (kind IN ('statute','effort','operator')),
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
    deadlineAt        INTEGER NOT NULL,
    statuteName       TEXT,
    actionKey         TEXT,
    question          TEXT NOT NULL,
    options           TEXT,
    context           TEXT NOT NULL,
    status            TEXT NOT NULL CHECK (status IN ('open','ruled','consumed','withdrawn','superseded')),
    decision          TEXT,
    rationale         TEXT,
    ruledBy           TEXT,
    ruledViaPrincipal TEXT,
    ruledViaSessionKey TEXT,
    ruledViaSessionState TEXT CHECK (ruledViaSessionState IS NULL OR ruledViaSessionState IN ('known','none')),
    ruledAt           INTEGER,
    rulingFactId      INTEGER,
    consumedAt        INTEGER,
    parkWakeId        TEXT,
    withdrawnBy       TEXT,
    withdrawnReason   TEXT,
    withdrawnAt       INTEGER,
    CHECK (
      (kind = 'statute' AND statuteName IS NOT NULL AND actionKey IS NOT NULL
       AND expecterSessionKey IS NULL AND expecterUserId IS NULL
       AND lineageRung IS NULL AND effortGeneration IS NULL AND deadlineWakeId IS NULL
       AND ruledViaSessionKey IS NULL
       AND (decision IS NULL OR decision IN ('allow','deny','waived')))
      OR
      (kind = 'effort' AND raiserId = 'process:tightbeam'
       AND raiserSessionKey IS NULL
       AND statuteName IS NULL AND actionKey IS NULL AND assignmentId IS NOT NULL
       AND ((expecterSessionKey IS NOT NULL) != (expecterUserId IS NOT NULL))
       AND lineageRung IS NOT NULL AND effortGeneration IS NOT NULL AND deadlineWakeId IS NOT NULL
       AND ruledViaSessionKey IS NULL
       AND (decision IS NULL OR decision IN ('continue','dismiss')))
      OR
      (kind = 'operator'
       AND raiserSessionKey IS NOT NULL
       AND statuteName IS NULL AND actionKey IS NOT NULL
       AND expecterSessionKey IS NULL AND expecterUserId IS NULL
       AND lineageRung IS NULL AND effortGeneration IS NULL
       AND deadlineWakeId IS NULL
       AND options IS NOT NULL
       AND parkWakeId IS NULL AND consumedAt IS NULL
       AND status <> 'consumed'
       AND (
         (status = 'ruled'
          AND decision IS NOT NULL
          AND ruledBy = 'user:' || ownerUserId
          AND ruledAt IS NOT NULL AND rulingFactId IS NOT NULL)
         OR
         (status <> 'ruled'
          AND decision IS NULL AND rationale IS NULL
          AND ruledBy IS NULL AND ruledAt IS NULL AND rulingFactId IS NULL
          AND ruledViaSessionKey IS NULL)
       ))
    )
  );
  CREATE INDEX IF NOT EXISTS decision_requests_owner
    ON decision_requests (ownerUserId, status);
  CREATE INDEX IF NOT EXISTS decision_requests_key
    ON decision_requests (raiserId, statuteName, actionKey);
  CREATE UNIQUE INDEX IF NOT EXISTS decision_requests_one_open
    ON decision_requests (raiserId, statuteName, actionKey)
    WHERE kind = 'statute' AND status = 'open';
  CREATE UNIQUE INDEX IF NOT EXISTS decision_requests_effort_generation
    ON decision_requests (assignmentId, effortGeneration) WHERE kind = 'effort';
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
    firstSurface TEXT NOT NULL CHECK (firstSurface IN ('list','detail','consume','migration-preflight')),
    firstObservedAt INTEGER NOT NULL,
    observerPrincipal TEXT NOT NULL,
    PRIMARY KEY (requestId, shapeDigest)
  );
  CREATE TRIGGER IF NOT EXISTS decision_requests_terminal_insert_guard
  BEFORE INSERT ON decision_requests
  WHEN NEW.kind = 'operator' AND NEW.status = 'ruled' AND
    (NEW.ruledViaPrincipal IS NULL OR NEW.ruledViaSessionState NOT IN ('known','none') OR
     (NEW.ruledViaSessionState = 'known' AND NEW.ruledViaSessionKey IS NULL) OR
     (NEW.ruledViaSessionState = 'none' AND NEW.ruledViaSessionKey IS NOT NULL))
  BEGIN
    SELECT RAISE(ABORT, 'decision_request_integrity_invalid');
  END;
  CREATE TRIGGER IF NOT EXISTS decision_requests_terminal_update_guard
  BEFORE UPDATE OF status ON decision_requests
  WHEN OLD.kind = 'operator' AND OLD.status = 'open' AND NEW.status = 'ruled' AND
    (NEW.ruledViaPrincipal IS NULL OR NEW.ruledViaSessionState NOT IN ('known','none') OR
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
  ruledBy, ruledViaPrincipal, ruledViaSessionKey, ruledViaSessionState, ruledAt, rulingFactId, consumedAt, parkWakeId, withdrawnBy,
  withdrawnReason, withdrawnAt
  """

  @spec ensure_schema(DB.server()) :: :ok | {:error, term()}
  def ensure_schema(db \\ DB), do: DB.execute(db, @ddl)

  @doc false
  @spec ensure_terminal_parity_in_txn(Txn.t(), non_neg_integer()) :: :ok
  def ensure_terminal_parity_in_txn(%Txn{} = txn, activated_at) do
    :ok =
      Txn.exec(
        txn,
        """
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
          firstSurface TEXT NOT NULL CHECK (firstSurface IN ('list','detail','consume','migration-preflight')),
          firstObservedAt INTEGER NOT NULL,
          observerPrincipal TEXT NOT NULL,
          PRIMARY KEY (requestId, shapeDigest)
        );
        CREATE TRIGGER IF NOT EXISTS decision_requests_terminal_insert_guard
        BEFORE INSERT ON decision_requests
        WHEN NEW.kind = 'operator' AND NEW.status = 'ruled' AND
          (NEW.ruledViaPrincipal IS NULL OR NEW.ruledViaSessionState NOT IN ('known','none') OR
           (NEW.ruledViaSessionState = 'known' AND NEW.ruledViaSessionKey IS NULL) OR
           (NEW.ruledViaSessionState = 'none' AND NEW.ruledViaSessionKey IS NOT NULL))
        BEGIN
          SELECT RAISE(ABORT, 'decision_request_integrity_invalid');
        END;
        CREATE TRIGGER IF NOT EXISTS decision_requests_terminal_update_guard
        BEFORE UPDATE OF status ON decision_requests
        WHEN OLD.kind = 'operator' AND OLD.status = 'open' AND NEW.status = 'ruled' AND
          (NEW.ruledViaPrincipal IS NULL OR NEW.ruledViaSessionState NOT IN ('known','none') OR
           (NEW.ruledViaSessionState = 'known' AND NEW.ruledViaSessionKey IS NULL) OR
           (NEW.ruledViaSessionState = 'none' AND NEW.ruledViaSessionKey IS NOT NULL))
        BEGIN
          SELECT RAISE(ABORT, 'decision_request_integrity_invalid');
        END;
        """
      )

    case Txn.q(txn, "SELECT schemaVersion FROM decision_request_terminal_epoch WHERE id = 0") do
      [] ->
        [[cutoff]] = Txn.q(txn, "SELECT COALESCE(MAX(id), 0) FROM condition_facts")

        Txn.q(
          txn,
          """
          INSERT INTO decision_request_terminal_epoch
            (id, schemaVersion, legacyRulingFactMaxId, activatedAt, cause, principal)
          VALUES (0, ?1, ?2, ?3, ?1, 'process:tightbeam')
          """,
          [@terminal_schema_version, cutoff, activated_at]
        )

        rows =
          Txn.q(
            txn,
            "SELECT #{@request_columns} FROM decision_requests WHERE kind = 'operator' AND status IN ('ruled','consumed') ORDER BY id"
          )

        Enum.each(rows, fn row ->
          request = request_from_row(row)

          case validate_terminal_request_in_txn(txn, request) do
            %{failures: []} ->
              :ok

            validation ->
              record_integrity_evidence_in_txn(
                txn,
                request.id,
                validation,
                :"migration-preflight",
                "process:tightbeam"
              )
          end
        end)

      [[@terminal_schema_version]] ->
        :ok

      [[other]] ->
        raise DB.Error, message: "incompatible terminal decision epoch #{other}"
    end

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
        %{status: "ruled", decision: "allow", id: id} -> {:allow, id}
        %{status: "ruled", decision: "deny"} -> {:deny, deny_error(statute)}
        %{status: "ruled", decision: "waived"} -> {:needs_request, nil}
        %{status: "open", id: id} -> {:needs_request, id}
        _ -> {:needs_request, nil}
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
                "SELECT #{@request_columns} FROM decision_requests WHERE raiserId = ?1 AND statuteName = ?2 AND actionKey = ?3 AND status = 'open' ORDER BY rowid DESC LIMIT 1",
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
  @spec operator_ask(DB.server(), map(), keyword()) :: map()
  def operator_ask(db, call, opts \\ []) do
    case Map.get(call, :principal) do
      {:session, session_key} ->
        with %{owner_user_id: owner_user_id} <- Org.get(db, session_key),
             {:ok, ask} <- normalize_operator_ask(call) do
          {:ok, result} =
            DB.transaction_then(
              db,
              fn txn ->
                before =
                  if ask.supersedes, do: request_in_txn_optional(txn, ask.supersedes)

                result = operator_ask_in_txn(txn, call, session_key, owner_user_id, ask, opts)

                after_request =
                  if ask.supersedes, do: request_in_txn_optional(txn, ask.supersedes)

                transition =
                  changed_decision_transition(
                    before,
                    after_request,
                    call.origin,
                    "operator-ask"
                  )

                {result, List.wrap(transition)}
              end,
              fn txn, {result, transitions} ->
                Tightbeam.Wakes.row_commit_in_txn(txn, transitions)
                result
              end
            )

          result
        else
          {:error, reason} -> reason
          _ -> error("invalid", "operator-ask requires a session principal")
        end

      _ ->
        error("invalid", "operator-ask requires a session principal")
    end
  end

  @doc "Resolve one operator request as its owner, retaining authenticated transport provenance."
  @spec operator_rule(DB.server(), map(), keyword()) :: map()
  def operator_rule(db, call, opts \\ []) do
    request_id = param(call, :request_id) || param(call, :request)

    with {:ok, answer} <- normalize_operator_answer(call) do
      case DB.transaction_then(
             db,
             fn txn ->
               before = request_in_txn_optional(txn, request_id)
               {result, fact_id} = operator_rule_in_txn(txn, call, request_id, answer, opts)
               after_request = request_in_txn_optional(txn, request_id)

               transition =
                 changed_decision_transition(before, after_request, call.origin, "operator-rule")

               {result, fact_id, List.wrap(transition)}
             end,
             fn txn, {result, fact_id, transitions} ->
               Tightbeam.Wakes.row_commit_in_txn(txn, transitions)

               deliveries =
                 if is_integer(fact_id),
                   do: ConditionFacts.recognize_in_txn(txn, fact_id),
                   else: []

               {result, deliveries}
             end
           ) do
        {:ok, {result, deliveries}} ->
          ConditionFacts.complete_deliveries(db, deliveries)
          nudge(opts, result[:ruling_fact_id] && [result.ruling_fact_id])
          result

        {:error, error} ->
          raise error
      end
    else
      {:error, reason} -> reason
    end
  end

  @doc "Withdraw one operator request as its owner or same-owner raiser."
  @spec operator_withdraw(DB.server(), map(), keyword()) :: map()
  def operator_withdraw(db, call, opts \\ []) do
    request_id = param(call, :request_id) || param(call, :request)

    with {:ok, reason} <-
           normalized_required(param(call, :reason), "withdrawal reason is required") do
      {:ok, result} =
        DB.transaction_then(
          db,
          fn txn ->
            before = request_in_txn_optional(txn, request_id)
            result = operator_withdraw_in_txn(txn, call, request_id, reason, opts)
            after_request = request_in_txn_optional(txn, request_id)

            transition =
              changed_decision_transition(before, after_request, call.origin, "operator-withdraw")

            {result, List.wrap(transition)}
          end,
          fn txn, {result, transitions} ->
            Tightbeam.Wakes.row_commit_in_txn(txn, transitions)
            result
          end
        )

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

  @doc "Spend one ruled authorization. Batch rollback is deliberately not provided."
  @spec consume(DB.server(), String.t(), String.t(), String.t()) :: boolean()
  def consume(db, ruling_id, verb \\ "rule", principal \\ "process:tightbeam") do
    {:ok, consumed?} =
      DB.transaction_then(
        db,
        fn txn ->
          request = request_in_txn_optional(txn, ruling_id)

          Txn.q(
            txn,
            "UPDATE decision_requests SET status = 'consumed', consumedAt = ?2 WHERE id = ?1 AND kind = 'statute' AND status = 'ruled'",
            [ruling_id, now()]
          )

          consumed? = Txn.changes(txn) == 1

          transition =
            if consumed?, do: decision_transition(request, "ruled", "consumed", principal, verb)

          {consumed?, List.wrap(transition)}
        end,
        fn txn, {consumed?, transitions} ->
          Tightbeam.Wakes.row_commit_in_txn(txn, transitions)
          consumed?
        end
      )

    consumed?
  end

  @doc "Rule one open request. `:authorized` is supplied by Gateway's admin axis."
  @spec rule(DB.server(), map(), keyword()) :: map()
  def rule(db, call, opts \\ []) do
    request_id = param(call, :request_id) || param(call, :request)
    request = get_raw(db, request_id)

    case request && request.kind do
      "effort" ->
        error("invalid", "effort requests use effort-rule")

      "operator" ->
        error("invalid", "operator requests use operator-rule")

      _ ->
        with true <- Keyword.get(opts, :authorized, false),
             request when not is_nil(request) <- request,
             false <- raiser_id(call) == request.raiser_id,
             {:ok, decision} <- resolve_decision(request, param(call, :decision)) do
          case request.status do
            status when status in ["ruled", "consumed"] and request.decision == decision ->
              request

            "open" ->
              rule_open(db, request, decision, param(call, :rationale), call.origin, opts)

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

  @doc "Withdraw an open request as its canonical raiser."
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
            withdraw_open(db, request, call.origin, reason)
        end
    end
  end

  @doc "Withdraw open requests and revoke live waivers for one retired session raiser."
  @spec withdraw_for_retired(DB.server(), String.t()) :: :ok
  def withdraw_for_retired(db, session_key) do
    raiser_id = "session:" <> session_key
    at = now()

    {:ok, :ok} =
      DB.transaction_then(
        db,
        fn txn ->
          rows =
            Txn.q(
              txn,
              "SELECT id, ownerUserId FROM decision_requests WHERE raiserSessionKey = ?1 AND kind != 'operator' AND status = 'open'",
              [session_key]
            )

          Enum.each(rows, fn [id, _owner_user_id] ->
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

          Enum.map(rows, fn [id, owner_user_id] ->
            decision_transition(
              %{id: id, owner_user_id: owner_user_id},
              "open",
              "withdrawn",
              "process:tightbeam",
              "retire"
            )
          end)
        end,
        fn txn, transitions ->
          Tightbeam.Wakes.row_commit_in_txn(txn, transitions)
          :ok
        end
      )

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
        "SELECT id FROM decision_requests WHERE statuteName = ?1 AND raiserId = 'process:tightbeam' AND actionKey LIKE ?2 AND status = 'open'",
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
      DB.transaction_then(
        db,
        fn txn ->
          transitions =
            Enum.flat_map(ids, fn id ->
              request = request_in_txn_optional(txn, id)

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

                [decision_transition(request, "open", "withdrawn", "process:tightbeam", "attest")]
              else
                []
              end
            end)

          transitions
        end,
        fn txn, transitions ->
          Tightbeam.Wakes.row_commit_in_txn(txn, transitions)
          :ok
        end
      )

    :ok
  end

  @doc "Boot backstop for retirement casts lost across a crash."
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
    {where, params} = visibility(db, call, Keyword.get(opts, :owner_user_id))

    # nil and the "all" sentinel both mean "no status filter". A concrete status filters
    # to that one value; "all" as a literal never matches a row, so it must not reach SQL.
    {status_clause, params} =
      if is_binary(status) and status != "all" do
        {" AND status = ?#{length(params) + 1}", params ++ [status]}
      else
        {"", params}
      end

    case DB.transaction(db, fn txn ->
           rows =
             Txn.q(
               txn,
               "SELECT #{@request_columns} FROM decision_requests WHERE (#{where})#{status_clause} ORDER BY rowid DESC",
               params
             )

           terminal_project_rows_in_txn(txn, rows, :list, observer_principal(call))
         end) do
      {:ok, result} -> result
      {:error, %IntegrityEvidenceConflict{}} -> integrity_evidence_error("conflict")
      {:error, %IntegrityEvidenceUnavailable{}} -> integrity_evidence_error("unavailable")
      {:error, error} -> raise error
    end
  end

  @doc """
  Fetch one visible decision request including its halted-call context.
  """
  @spec get(DB.server(), map(), String.t(), keyword()) :: map() | nil
  def get(db, call, id, opts \\ [])

  def get(db, call, id, opts) do
    {where, params} = visibility(db, call, Keyword.get(opts, :owner_user_id))

    result =
      case DB.transaction(db, fn txn ->
             rows =
               Txn.q(
                 txn,
                 "SELECT #{@request_columns} FROM decision_requests WHERE id = ?1 AND (#{shift_params(where)})",
                 [id | params]
               )

             case rows do
               [row] ->
                 terminal_project_rows_in_txn(txn, [row], :detail, observer_principal(call))

               [] ->
                 nil
             end
           end) do
        {:ok, result} -> result
        {:error, %IntegrityEvidenceConflict{}} -> integrity_evidence_error("conflict")
        {:error, %IntegrityEvidenceUnavailable{}} -> integrity_evidence_error("unavailable")
        {:error, error} -> raise error
      end

    case result do
      [request] -> request
      other -> other
    end
  end

  @doc "Fetch one decision request by its complete id without changing visibility policy."
  @spec raw_by_id(DB.server(), String.t() | nil) :: map() | nil
  def raw_by_id(db, id), do: get_raw(db, id)

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

  defp operator_ask_in_txn(txn, call, session_key, owner_user_id, ask, opts) do
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
            ask,
            opts
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
         ask,
         opts
       ) do
    request_id = "dr_" <> Tightbeam.Id.uuid4()
    raised_at = now()
    deadline_at = raised_at + ask.deadline_ms

    if ask.supersedes do
      terminal_test_step(opts, :before_terminal_cas)

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

    # The existing outbox provides only the filing-time opportunity in this
    # bounded core. requestRef, reminder consumption, and terminal wake
    # cancellation land with their separately owned Wakes/Gateway integration.
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

      request ->
        with :ok <- operator_owner_authorized(call, request) do
          case request.status do
            "ruled" ->
              replay_operator_ruling_in_txn(txn, call, request, answer)

            "consumed" ->
              case validate_terminal_request_in_txn(txn, request) do
                %{failures: []} ->
                  {error("not_open", "decision request is not open"), nil}

                validation ->
                  {record_integrity_refusal_in_txn(
                     txn,
                     request.id,
                     validation,
                     :detail,
                     observer_principal(call)
                   ), nil}
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
    case validate_terminal_request_in_txn(txn, request) do
      %{failures: []} ->
        ruled_by = "user:" <> request.owner_user_id

        with {:ok, decision} <- operator_decision(request, answer) do
          if request.decision == decision and request.rationale == answer.rationale and
               request.ruled_by == ruled_by do
            {terminal_projection(request), nil}
          else
            {error("not_open", "decision request is not open"), nil}
          end
        else
          {:error, reason} -> {reason, nil}
        end

      validation ->
        {record_integrity_refusal_in_txn(
           txn,
           request.id,
           validation,
           :detail,
           observer_principal(call)
         ), nil}
    end
  end

  defp rule_operator_request_in_txn(txn, call, request, decision, answer, opts) do
    ruled_by = "user:" <> request.owner_user_id
    via = Map.get(call, :transport_session_key)
    via_principal = principal_id(Map.fetch!(call, :principal))
    via_state = if is_binary(via), do: "known", else: "none"

    cond do
      request.status == "ruled" and request.decision == decision and
          request.rationale == answer.rationale ->
        case validate_terminal_request_in_txn(txn, request) do
          %{failures: []} ->
            {terminal_projection(request), nil}

          validation ->
            {record_integrity_refusal_in_txn(
               txn,
               request.id,
               validation,
               :detail,
               observer_principal(call)
             ), nil}
        end

      request.status != "open" ->
        {error("not_open", "decision request is not open"), nil}

      true ->
        terminal_test_step(opts, :after_load)
        terminal_test_step(opts, :before_terminal_cas)
        ruled_at = now()

        Wakes.schedule_in_txn(txn, %{
          session_key: request.raiser_session_key,
          origin: "process:tightbeam",
          prompt: terminal_notification(request.id),
          due_at: ruled_at + (request.deadline_at - request.raised_at),
          target_gate: 0,
          creator_session_key: via,
          condition_kind: @terminal_condition_kind,
          condition_scope: request.id
        })

        terminal_test_step(opts, :after_schedule)

        %{fact_id: fact_id} =
          ConditionFacts.file_in_txn(txn, %{
            kind: @terminal_condition_kind,
            scope: request.id,
            origin: "process:tightbeam",
            owner_user_id: request.owner_user_id
          })

        terminal_test_step(opts, :after_fact)

        Txn.q(
          txn,
          "UPDATE decision_requests SET status = 'ruled', decision = ?2, rationale = ?3, ruledBy = ?4, ruledViaPrincipal = ?5, ruledViaSessionKey = ?6, ruledViaSessionState = ?7, ruledAt = ?8, rulingFactId = ?9 WHERE id = ?1 AND kind = 'operator' AND status = 'open'",
          [
            request.id,
            decision,
            answer.rationale,
            ruled_by,
            via_principal,
            via,
            via_state,
            ruled_at,
            fact_id
          ]
        )

        if Txn.changes(txn) != 1,
          do: raise(DB.Error, message: "operator ruling lost its open-row CAS")

        terminal_test_step(opts, :after_cas)

        EventLog.lifecycle_in_txn(
          txn,
          "decision_request_ruled",
          request.id,
          "by=#{ruled_by} decision=#{decision} factId=#{fact_id} mode=#{answer.mode} via=#{via || "direct"}"
        )

        terminal_test_step(opts, :after_event)

        ruled = request_in_txn(txn, request.id)

        case validate_terminal_request_in_txn(txn, ruled) do
          %{failures: []} ->
            terminal_test_step(opts, :after_validate)
            {terminal_projection(ruled), fact_id}

          %{failures: failures} ->
            raise DB.Error, message: Enum.join(failures, ",")
        end
    end
  end

  defp operator_withdraw_in_txn(txn, call, request_id, reason, opts) do
    case request_in_txn_optional(txn, request_id) do
      nil ->
        error("not_found", "decision request not found")

      %{kind: "statute"} ->
        error("invalid", "statute requests use withdraw")

      %{kind: "effort"} ->
        error("invalid", "effort requests use effort-rule")

      request ->
        with {:ok, by} <- operator_withdrawer_in_txn(txn, call, request) do
          cond do
            request.status == "withdrawn" and request.withdrawn_by == by and
                request.withdrawn_reason == reason ->
              request

            request.status != "open" ->
              error("not_open", "decision request is not open")

            true ->
              terminal_test_step(opts, :before_terminal_cas)

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
          case normalized_required(decision, "decision must be non-blank") do
            {:ok, value} -> {:ok, %{mode: "label", value: value, rationale: rationale}}
            {:error, reason} -> {:error, reason}
          end

        {nil, response} when is_binary(response) ->
          case normalized_required(response, "response must be non-blank") do
            {:ok, value} -> {:ok, %{mode: "text", value: value, rationale: rationale}}
            {:error, reason} -> {:error, reason}
          end

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

    cond do
      Enum.any?(labels, &(not is_binary(&1) or String.trim(&1) == "")) ->
        {:error, error("invalid", "options require non-blank labels")}

      true ->
        normalized = Enum.map(labels, &String.trim/1)

        if Enum.uniq(normalized) == normalized,
          do: {:ok, Enum.map(normalized, &%{"label" => &1})},
          else: {:error, error("invalid", "option labels must be unique")}
    end
  end

  defp normalize_operator_options(_),
    do: {:error, error("invalid", "options require a non-empty label array")}

  defp operator_option_shape?(option) when is_map(option) do
    option |> Map.keys() |> Enum.map(&to_string/1) |> Enum.sort() == ["label"]
  end

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

  defp rule_open(db, request, decision, rationale, origin, opts) do
    ruled_at = now()

    {:ok, {result, deliveries}} =
      DB.transaction_then(
        db,
        fn txn ->
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
                origin: "process:tightbeam",
                owner_user_id: request.owner_user_id
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

            {ruled, fact_id, decision_transition(request, "open", "ruled", origin, "rule")}
          else
            current = request_in_txn(txn, request.id)

            # A concurrent-ruler loser filed nothing: it must not nudge (F13 —
            # one post-commit nudge per filed fact, owned by the filer).
            if current.status == "ruled" and current.decision == decision,
              do: {current, nil, nil},
              else: {error("not_open", "decision request is not open"), nil, nil}
          end
        end,
        fn txn, {result, fact_id, transition} ->
          Tightbeam.Wakes.row_commit_in_txn(txn, List.wrap(transition))

          deliveries =
            if is_integer(fact_id), do: ConditionFacts.recognize_in_txn(txn, fact_id), else: []

          {result, deliveries}
        end
      )

    ConditionFacts.complete_deliveries(db, deliveries)
    nudge(opts, result[:ruling_fact_id] && [result.ruling_fact_id])
    result
  end

  defp grant_waiver(db, raiser_id, statute_name, call, path, opts) do
    waiver_id = "ew_" <> Tightbeam.Id.uuid4()
    granted_at = now()
    reason = param(call, :reason)

    {:ok, {waiver, deliveries, fact_ids}} =
      DB.transaction_then(
        db,
        fn txn ->
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

          recognized =
            if path == "request" do
              open_ids =
                Txn.q(
                  txn,
                  "SELECT id FROM decision_requests WHERE raiserId = ?1 AND statuteName = ?2 AND status = 'open' ORDER BY rowid",
                  [raiser_id, statute_name]
                )

              Enum.flat_map(open_ids, fn [id] ->
                request = request_in_txn(txn, id)

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
                      origin: "process:tightbeam",
                      owner_user_id: request.owner_user_id
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

                  [{fact_id, decision_transition(request, "open", "ruled", call.origin, "waive")}]
                else
                  []
                end
              end)
            else
              []
            end

          {waiver_in_txn(txn, waiver_id), recognized}
        end,
        fn txn, {waiver, recognized} ->
          Tightbeam.Wakes.row_commit_in_txn(txn, Enum.map(recognized, &elem(&1, 1)))

          deliveries =
            Enum.flat_map(recognized, fn {fact_id, _transition} ->
              ConditionFacts.recognize_in_txn(txn, fact_id)
            end)

          {waiver, deliveries, Enum.map(recognized, &elem(&1, 0))}
        end
      )

    ConditionFacts.complete_deliveries(db, deliveries)
    nudge(opts, fact_ids)
    waiver
  end

  defp withdraw_open(db, request, by, reason) do
    withdrawn_at = now()

    {:ok, result} =
      DB.transaction_then(
        db,
        fn txn ->
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

            {request_in_txn(txn, request.id),
             decision_transition(request, "open", "withdrawn", by, "withdraw")}
          else
            {error("not_open", "decision request is not open"), nil}
          end
        end,
        fn txn, {result, transition} ->
          Tightbeam.Wakes.row_commit_in_txn(txn, List.wrap(transition))
          result
        end
      )

    result
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

  defp current_request(db, raiser_id, statute_name, action_key) do
    {:ok, rows} =
      DB.query(
        db,
        "SELECT #{@request_columns} FROM decision_requests WHERE raiserId = ?1 AND statuteName = ?2 AND actionKey = ?3 ORDER BY rowid DESC LIMIT 1",
        [raiser_id, statute_name, action_key]
      )

    case rows do
      [row] -> request_from_row(row)
      [] -> nil
    end
  end

  defp get_raw(_db, nil), do: nil

  defp get_raw(db, id) do
    {:ok, rows} =
      DB.query(db, "SELECT #{@request_columns} FROM decision_requests WHERE id = ?1", [id])

    case rows do
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
         ruled_via_principal,
         ruled_via_session_key,
         ruled_via_session_state,
         ruled_at,
         ruling_fact_id,
         consumed_at,
         park_wake_id,
         withdrawn_by,
         withdrawn_reason,
         withdrawn_at
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
      options: decode_optional_safe(options),
      context: decode_json_safe(context),
      status: status,
      decision: decision,
      rationale: rationale,
      ruled_by: ruled_by,
      ruled_via_principal: ruled_via_principal,
      ruled_via_session_key: ruled_via_session_key,
      ruled_via_session_state: ruled_via_session_state,
      ruled_at: ruled_at,
      ruling_fact_id: ruling_fact_id,
      consumed_at: consumed_at,
      park_wake_id: park_wake_id,
      withdrawn_by: withdrawn_by,
      withdrawn_reason: withdrawn_reason,
      withdrawn_at: withdrawn_at
    }
  end

  defp list_projection(%{kind: "operator"} = request) do
    operator_projection(request, :list)
  end

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

  defp terminal_project_rows_in_txn(txn, rows, surface, observer_principal) do
    parsed = Enum.map(rows, &request_from_row/1)

    invalid =
      parsed
      |> Enum.filter(&(&1.kind == "operator" and &1.status in ["ruled", "consumed"]))
      |> Enum.map(fn request -> {request, validate_terminal_request_in_txn(txn, request)} end)
      |> Enum.reject(fn {_request, validation} -> validation.failures == [] end)

    case invalid do
      [] ->
        Enum.map(parsed, fn
          %{kind: "operator"} = request -> operator_projection(request, surface)
          request -> if(surface == :list, do: list_projection(request), else: request)
        end)

      invalid ->
        Enum.each(invalid, fn {request, validation} ->
          record_integrity_evidence_in_txn(
            txn,
            request.id,
            validation,
            surface,
            observer_principal
          )
        end)

        {request, _failures} = Enum.min_by(invalid, fn {request, _} -> request.id end)
        integrity_error(request.id)
    end
  end

  defp operator_projection(request, surface) do
    if request.status == "ruled" do
      base =
        request
        |> Map.take([
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
          :deadline_at,
          :decision,
          :rationale,
          :ruled_by,
          :ruled_via_session_key,
          :ruled_at,
          :ruling_fact_id,
          :consumed_at
        ])
        |> Map.put(:ruling_attribution, ruling_attribution(request))

      if surface == :detail do
        base |> Map.put(:context, request.context) |> Map.put(:action_key, request.action_key)
      else
        base
      end
    else
      if surface == :list do
        Map.take(request, [
          :id,
          :kind,
          :status,
          :question,
          :options,
          :context,
          :raised_at,
          :deadline_at,
          :raiser_id,
          :assignment_id
        ])
      else
        Map.drop(request, [:ruled_via_principal, :ruled_via_session_state])
      end
    end
  end

  defp terminal_projection(request), do: operator_projection(request, :detail)

  defp ruling_attribution(%{ruled_via_principal: principal} = request)
       when is_binary(principal) do
    session =
      case request.ruled_via_session_state do
        "known" -> %{state: "known", key: request.ruled_via_session_key}
        "none" -> %{state: "none"}
      end

    %{
      on_behalf_of: request.ruled_by,
      performer: %{principal: %{state: "known", value: principal}, session: session}
    }
  end

  defp ruling_attribution(request) do
    session =
      if is_binary(request.ruled_via_session_key) do
        %{state: "known", key: request.ruled_via_session_key}
      else
        %{state: "legacy-unknown"}
      end

    %{
      on_behalf_of: request.ruled_by,
      performer: %{principal: %{state: "legacy-unknown"}, session: session}
    }
  end

  defp validate_terminal_request_in_txn(txn, request) do
    [[cutoff]] =
      Txn.q(
        txn,
        "SELECT legacyRulingFactMaxId FROM decision_request_terminal_epoch WHERE id = 0"
      )

    epoch = terminal_epoch(request.ruling_fact_id, cutoff)
    fact_shape = terminal_fact_shape_in_txn(txn, request)

    [[event_count]] =
      Txn.q(
        txn,
        "SELECT COUNT(*) FROM lifecycle_events WHERE kind = 'decision_request_ruled' AND subject = ?1",
        [request.id]
      )

    notification_count =
      if epoch == :post_activation,
        do: terminal_notification_count_in_txn(txn, request),
        else: 0

    request_identity_valid =
      canonical_request_id?(request.id) and request.kind == "operator" and
        non_blank?(request.raiser_id) and non_blank?(request.owner_user_id) and
        non_blank?(request.raiser_session_key) and non_blank?(request.action_key) and
        non_blank?(request.question) and is_integer(request.raised_at) and
        is_integer(request.deadline_at) and request.deadline_at > request.raised_at and
        (is_nil(request.assignment_id) or non_blank?(request.assignment_id)) and
        is_map(request.context)

    owner_valid =
      non_blank?(request.owner_user_id) and non_blank?(request.raiser_session_key) and
        request.ruled_by == "user:" <> request.owner_user_id

    options_valid = valid_operator_options?(request.options)
    decision_valid = normalized_text?(request.decision)
    rationale_valid = is_nil(request.rationale) or normalized_text?(request.rationale)
    ruled_at_valid = is_integer(request.ruled_at)

    fact_valid =
      is_integer(request.ruling_fact_id) and fact_shape["canonicalCardinality"] == "one"

    principal_valid = terminal_performer_principal_valid?(request, epoch)
    session_valid = terminal_performer_session_valid?(request, epoch)
    lifecycle_valid = request.status == "ruled" and is_nil(request.consumed_at)
    event_valid = event_count == 1
    notification_valid = epoch != :post_activation or notification_count == 1

    checks = %{
      "requestIdentity" =>
        terminal_structural_check(request_identity_valid, %{
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
          "assignmentIdType" => terminal_type_class(request.assignment_id),
          "contextType" => terminal_type_class(request.context)
        }),
      "ownerOnBehalfOf" =>
        terminal_structural_check(owner_valid, %{
          "ownerUserIdType" => terminal_type_class(request.owner_user_id),
          "raiserSessionKeyType" => terminal_type_class(request.raiser_session_key),
          "ruledByType" => terminal_type_class(request.ruled_by),
          "ruledByMatchesOwner" => owner_valid
        }),
      "options" =>
        terminal_structural_check(options_valid, terminal_operator_options_shape(request.options)),
      "decision" =>
        terminal_structural_check(decision_valid, %{
          "type" => terminal_type_class(request.decision),
          "normalizedNonblank" => decision_valid
        }),
      "rationale" =>
        terminal_structural_check(rationale_valid, %{
          "type" => terminal_type_class(request.rationale),
          "contractAccepted" => rationale_valid
        }),
      "ruledAt" =>
        terminal_structural_check(ruled_at_valid, %{
          "type" => terminal_type_class(request.ruled_at)
        }),
      "rulingFactId" =>
        terminal_structural_check(
          fact_valid,
          Map.put(fact_shape, "idType", terminal_type_class(request.ruling_fact_id))
        ),
      "performerPrincipal" =>
        terminal_structural_check(principal_valid, %{
          "epochState" => terminal_epoch_state(epoch),
          "type" => terminal_type_class(request.ruled_via_principal),
          "canonical" => canonical_principal?(request.ruled_via_principal)
        }),
      "performerSession" =>
        terminal_structural_check(session_valid, %{
          "epochState" => terminal_epoch_state(epoch),
          "stateClass" => terminal_session_state_class(request.ruled_via_session_state),
          "keyType" => terminal_type_class(request.ruled_via_session_key),
          "stateKeyConsistent" => terminal_session_state_key_consistent?(request)
        }),
      "lifecycleConsumption" =>
        terminal_structural_check(lifecycle_valid, %{
          "statusState" => terminal_status_state(request.status),
          "consumedAtType" => terminal_type_class(request.consumed_at)
        }),
      "rulingLifecycleEvent" =>
        terminal_structural_check(event_valid, %{
          "canonicalCardinality" => terminal_cardinality(event_count)
        }),
      "raiserNotificationWake" =>
        terminal_structural_check(notification_valid, %{
          "requirementState" => terminal_wake_requirement_state(epoch),
          "canonicalCardinality" => terminal_cardinality(notification_count)
        })
    }

    failures =
      @terminal_failure_fields
      |> Enum.reject(&get_in(checks, [&1, "valid"]))
      |> Enum.sort()

    %{
      failures: failures,
      descriptor: %{
        "schemaVersion" => @terminal_schema_version,
        "causeCode" => @terminal_evidence_cause,
        "checks" => checks,
        "failingFields" => failures
      }
    }
  end

  defp terminal_structural_check(valid, shape), do: Map.put(shape, "valid", valid)

  defp terminal_epoch(ruling_fact_id, cutoff) do
    cond do
      not is_integer(ruling_fact_id) -> :unknown
      ruling_fact_id > cutoff -> :post_activation
      true -> :legacy
    end
  end

  defp terminal_fact_shape_in_txn(txn, request) do
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
        kind_match = kind == @terminal_condition_kind
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

  defp terminal_operator_options_shape(options) do
    nonempty = is_list(options) and options != []
    members_are_objects = is_list(options) and Enum.all?(options, &is_map/1)

    sole_label_key =
      members_are_objects and Enum.all?(options, fn option -> Map.keys(option) == ["label"] end)

    labels = if sole_label_key, do: Enum.map(options, &Map.fetch!(&1, "label")), else: []
    labels_nonblank = sole_label_key and Enum.all?(labels, &non_blank?/1)
    labels_normalized = labels_nonblank and Enum.all?(labels, &(String.trim(&1) == &1))
    labels_distinct = labels_normalized and Enum.uniq(labels) == labels

    %{
      "type" => terminal_type_class(options),
      "nonempty" => nonempty,
      "membersAreObjects" => members_are_objects,
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
       non_blank?(request.ruled_via_session_key)) or
      (request.ruled_via_session_state == "none" and
         is_nil(request.ruled_via_session_key)) or
      (is_nil(request.ruled_via_session_state) and
         (is_nil(request.ruled_via_session_key) or non_blank?(request.ruled_via_session_key)))
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

  defp terminal_notification_count_in_txn(txn, request) do
    expected_due_at =
      if Enum.all?([request.ruled_at, request.deadline_at, request.raised_at], &is_integer/1),
        do: request.ruled_at + (request.deadline_at - request.raised_at),
        else: nil

    [[count]] =
      Txn.q(
        txn,
        """
        SELECT COUNT(*) FROM wakes
        WHERE sessionKey = ?1 AND targetRole IS NULL AND origin = 'process:tightbeam'
          AND prompt = ?2 AND consumer = 'prompt' AND conditionKind = ?3
          AND conditionScope = ?4 AND conditionAfterId < ?5
          AND dueAt = ?6 AND targetGate = 0
          AND reresolve IS NULL AND reresolveSeed IS NULL AND reresolveRung IS NULL
          AND ((?7 IS NULL AND creatorSessionKey IS NULL) OR creatorSessionKey = ?7)
          AND ((state = 'pending' AND firedAt IS NULL AND firedBy IS NULL) OR
               (state = 'fired' AND firedAt IS NOT NULL AND firedBy = 'condition'))
        """,
        [
          request.raiser_session_key,
          terminal_notification(request.id),
          @terminal_condition_kind,
          request.id,
          request.ruling_fact_id,
          expected_due_at,
          request.ruled_via_session_key
        ]
      )

    count
  end

  defp terminal_performer_principal_valid?(request, :post_activation),
    do: canonical_principal?(request.ruled_via_principal)

  defp terminal_performer_principal_valid?(request, :legacy),
    do: is_nil(request.ruled_via_principal)

  defp terminal_performer_principal_valid?(request, :unknown),
    do: is_nil(request.ruled_via_principal) or canonical_principal?(request.ruled_via_principal)

  defp terminal_performer_session_valid?(request, :post_activation) do
    (request.ruled_via_session_state == "known" and
       non_blank?(request.ruled_via_session_key)) or
      (request.ruled_via_session_state == "none" and is_nil(request.ruled_via_session_key))
  end

  defp terminal_performer_session_valid?(request, :legacy),
    do: is_nil(request.ruled_via_session_state)

  defp terminal_performer_session_valid?(request, :unknown),
    do:
      terminal_performer_session_valid?(request, :post_activation) or
        terminal_performer_session_valid?(request, :legacy)

  defp record_integrity_refusal_in_txn(
         txn,
         request_id,
         validation,
         surface,
         observer_principal
       ) do
    record_integrity_evidence_in_txn(
      txn,
      request_id,
      validation,
      surface,
      observer_principal
    )

    integrity_error(request_id)
  end

  defp record_integrity_evidence_in_txn(
         txn,
         request_id,
         validation,
         surface,
         observer_principal
       ) do
    failures = validation.failures
    fields = failures |> Enum.sort() |> JSON.encode!()
    descriptor = canonical_json(validation.descriptor)

    digest = :crypto.hash(:sha256, descriptor) |> Base.encode16(case: :lower)

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
          @terminal_evidence_cause,
          fields,
          to_string(surface),
          now(),
          observer_principal
        ]
      )

      case Txn.q(
             txn,
             "SELECT schemaVersion, causeCode, failingFields FROM decision_request_integrity_evidence WHERE requestId=?1 AND shapeDigest=?2",
             [request_id, digest]
           ) do
        [[@terminal_schema_version, @terminal_evidence_cause, ^fields]] ->
          :ok

        [_other] ->
          raise IntegrityEvidenceConflict,
            message: "integrity evidence immutable payload conflict"

        [] ->
          raise IntegrityEvidenceUnavailable,
            message: "integrity evidence insert was not durable"
      end
    rescue
      error in [IntegrityEvidenceConflict, IntegrityEvidenceUnavailable] ->
        reraise error, __STACKTRACE__

      error ->
        raise IntegrityEvidenceUnavailable,
          message: "integrity evidence unavailable: #{Exception.message(error)}"
    end
  end

  defp integrity_error(request_id),
    do: %{
      code: @terminal_integrity_code,
      message: "decision request integrity check failed",
      request_id: request_id
    }

  defp integrity_evidence_error(suffix),
    do: %{
      code: "decision_request_integrity_evidence_#{suffix}",
      message: "decision request integrity evidence #{suffix}"
    }

  defp canonical_request_id?(id) when is_binary(id),
    do:
      Regex.match?(
        ~r/\Adr_[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\z/,
        id
      )

  defp canonical_request_id?(_id), do: false

  defp non_blank?(value), do: is_binary(value) and String.trim(value) != ""
  defp normalized_text?(value), do: non_blank?(value) and String.trim(value) == value

  defp terminal_test_step(opts, step) do
    case Keyword.get(opts, :transaction_step_hook) do
      {:raise, ^step, message} when is_binary(message) ->
        raise message

      {:block, ^step, observer, ready_tag, release_message} when is_pid(observer) ->
        send(observer, {ready_tag, self()})

        receive do
          ^release_message -> :ok
        end

      _other ->
        :ok
    end
  end

  defp canonical_principal?("user:" <> suffix), do: non_blank?(suffix)
  defp canonical_principal?("session:" <> suffix), do: non_blank?(suffix)
  defp canonical_principal?(_value), do: false

  defp valid_operator_options?(options) when is_list(options) and options != [] do
    labels =
      Enum.map(options, fn
        %{"label" => label} = option when map_size(option) == 1 -> label
        _ -> nil
      end)

    Enum.all?(labels, &normalized_text?/1) and Enum.uniq(labels) == labels
  end

  defp valid_operator_options?(_options), do: false

  defp terminal_notification(request_id) do
    "Decision request #{request_id} was ruled. Read it with tightbeam decision-request --request #{request_id}."
  end

  defp principal_id({kind, value}) when kind in [:user, :session, :process],
    do: "#{kind}:#{value}"

  defp observer_principal(call), do: call |> Map.fetch!(:principal) |> principal_id()

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

  defp visibility(_db, call, owner_user_id) do
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

    operator =
      case call.principal do
        {:user, user_id} -> {"ownerUserId = ?", [user_id]}
        {:session, session_key} -> {"raiserSessionKey = ?", [session_key]}
        _ -> {"0", []}
      end

    {effort_sql, effort_params} =
      case effort do
        {"0", nil} -> {"0", []}
        {sql, value} -> {sql, [value]}
      end

    {statute_sql, statute_params} = statute
    {operator_sql, operator_params} = operator
    params = statute_params ++ effort_params ++ operator_params

    numbered =
      "(kind = 'statute' AND #{statute_sql}) OR (kind = 'effort' AND #{effort_sql}) OR (kind = 'operator' AND #{operator_sql})"
      |> number_placeholders()

    {numbered, params}
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

  defp changed_decision_transition(
         %{id: id, status: old_status} = before,
         %{id: id, status: new_status},
         principal,
         verb
       )
       when old_status != new_status do
    decision_transition(before, old_status, new_status, principal, verb)
  end

  defp changed_decision_transition(_before, _after, _principal, _verb), do: nil

  defp decision_transition(request, old_status, new_status, principal, verb) do
    %{
      verb: verb,
      domain: "decision_request",
      row_id: request.id,
      owner_user_id: request.owner_user_id,
      principal: principal,
      bindings: %{decision_request_id: request.id},
      field: %{name: "status", old: old_status, new: new_status}
    }
  end

  defp nudge(_opts, nil), do: :ok
  defp nudge(_opts, []), do: :ok

  defp nudge(opts, fact_ids) do
    if Keyword.has_key?(opts, :scheduler) do
      Wakes.fire_matching(Keyword.fetch!(opts, :scheduler), fact_ids)
    else
      :ok
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
  defp decode_optional_safe(nil), do: nil
  defp decode_optional_safe(value), do: decode_json_safe(value)

  defp decode_json_safe(value) do
    case JSON.decode(value) do
      {:ok, decoded} -> decoded
      {:error, _error} -> :invalid_json
    end
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
