defmodule Tightbeam.Escalation do
  @moduledoc """
  Durable decision requests and raiser-scoped escalation waivers.

  `resolve/3` is an effect-free gate read. `escalate/4` owns request opening,
  while `consume/2` is the per-ruling verb-edge CAS. A caller consuming a
  batch must fail closed if any CAS loses; earlier winners stay consumed.
  """

  alias Tightbeam.{Adjudication, ConditionFacts, DB, EventLog, Org, Roles, Wakes}
  alias Tightbeam.DB.Txn

  @default_decision_deadline_ms 86_400_000

  # Marks an `actionKey` as naming a CONDITION rather than one caller's action. Reserved
  # here because `digest/1` is a hex SHA-256 and can never collide with it.
  @episode_prefix "episode:"

  @ddl """
  CREATE TABLE IF NOT EXISTS decision_requests (
    id                TEXT PRIMARY KEY,
    kind              TEXT NOT NULL DEFAULT 'statute' CHECK (kind IN ('statute','effort')),
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
       AND (decision IS NULL OR decision IN ('allow','deny','waived')))
      OR
      (kind = 'effort' AND raiserId = 'process:tightbeam'
       AND raiserSessionKey IS NULL
       AND statuteName IS NULL AND actionKey IS NULL AND assignmentId IS NOT NULL
       AND ((expecterSessionKey IS NOT NULL) != (expecterUserId IS NOT NULL))
       AND lineageRung IS NOT NULL AND effortGeneration IS NOT NULL AND deadlineWakeId IS NOT NULL
       AND (decision IS NULL OR decision IN ('continue','dismiss')))
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

  @rebuild_ddl String.replace(
                 @ddl
                 |> String.split("CREATE INDEX IF NOT EXISTS decision_requests_owner")
                 |> hd(),
                 "IF NOT EXISTS decision_requests",
                 "decision_requests_new"
               )

  @request_columns """
  id, kind, raiserId, raiserSessionKey, ownerUserId, assignmentId,
  expecterSessionKey, expecterUserId, lineageRung, effortGeneration, deadlineWakeId,
  raisedAt, deadlineAt,
  statuteName, actionKey, question, options, context, status, decision, rationale,
  ruledBy, ruledAt, rulingFactId, consumedAt, parkWakeId, withdrawnBy,
  withdrawnReason, withdrawnAt
  """

  @spec ensure_schema(DB.server()) :: :ok | {:error, term()}
  def ensure_schema(db \\ DB) do
    {:ok, [[exists]]} =
      DB.query(
        db,
        "SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name = 'decision_requests'"
      )

    if exists == 0 do
      DB.execute(db, @ddl)
    else
      ensure_request_shape(db)
      :ok = DB.execute(db, indexes_ddl())
      DB.execute(db, waivers_ddl())
    end
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

            request
          end)

        {:decision_pending, request.id}
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
  @spec summon(DB.server(), map(), map(), map()) :: :ok
  def summon(db, call, statute, ctx) do
    {:decision_pending, _id} = escalate(db, call, statute, ctx)
    :ok
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

    :ok
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  @doc "Spend one ruled authorization. Batch rollback is deliberately not provided."
  @spec consume(DB.server(), String.t()) :: boolean()
  def consume(db, ruling_id) do
    {:ok, consumed?} =
      DB.transaction(db, fn txn ->
        Txn.q(
          txn,
          "UPDATE decision_requests SET status = 'consumed', consumedAt = ?2 WHERE id = ?1 AND status = 'ruled'",
          [ruling_id, now()]
        )

        Txn.changes(txn) == 1
      end)

    consumed?
  end

  @doc "Rule one open request. `:authorized` is supplied by Gateway's admin axis."
  @spec rule(DB.server(), map(), keyword()) :: map()
  def rule(db, call, opts \\ []) do
    request_id = param(call, :request_id) || param(call, :request)
    request = get_raw(db, request_id)

    if request && request.kind == "effort" do
      error("invalid", "effort requests use effort-rule")
    else
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
      DB.transaction(db, fn txn ->
        rows =
          Txn.q(
            txn,
            "SELECT id FROM decision_requests WHERE raiserSessionKey = ?1 AND status = 'open'",
            [session_key]
          )

        Enum.each(rows, fn [id] ->
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
  Effect-free: the newest open episode this statute has, as an ordering watermark.

  Returns the `rowid` of the newest open episode-keyed request, or `nil` when the statute
  has none. The caller hands this back to `close_episodes/3` so recovery withdraws the
  episodes the EVALUATION observed rather than whatever happens to be open by the time
  the actor runs — see that function for the interleaving this exists to stop.

  `rowid` is the ordering because it is assigned monotonically on insert and this table
  never deletes rows. (`ensure_request_shape/1` rebuilds and renumbers, but that is a
  boot-time migration inside one transaction, with no evaluation in flight across it.)
  """
  @spec episode_watermark(DB.server(), String.t()) :: integer() | nil
  def episode_watermark(db, statute_name) do
    {:ok, [[watermark]]} =
      DB.query(
        db,
        "SELECT MAX(rowid) FROM decision_requests WHERE statuteName = ?1 AND raiserId = 'process:tightbeam' AND actionKey LIKE ?2 AND status = 'open'",
        [statute_name, @episode_prefix <> "%"]
      )

    watermark
  end

  @doc """
  Close the open episodes this statute had AT `watermark` — the sensor answered again.

  Dark-factory recovery: the malfunction episode exists because a check stopped
  rendering verdicts, so an observed verdict IS the repair, and demanding an operator
  verb to acknowledge a sensor that already healed is the stall the episode was meant to
  prevent. Withdrawal, not a ruling: nothing was decided, the question simply expired.

  The watermark is what makes recovery ordered by EVALUATION rather than by whenever the
  actor got around to running. `decide` is effect-free, so an unbounded interval sits
  between the read that observed the episode and this withdrawal; a statute-wide "close
  everything open" would sweep away an episode opened inside that interval and silence a
  malfunction that had not been repaired at all — exactly the state §A3 forbids. Rows
  newer than the watermark were never observed as recovered, so they survive.
  """
  @spec close_episodes(DB.server(), String.t(), integer()) :: :ok
  def close_episodes(db, statute_name, watermark) when is_integer(watermark) do
    {:ok, :ok} =
      DB.transaction(db, fn txn ->
        txn
        |> Txn.q(
          "SELECT id FROM decision_requests WHERE statuteName = ?1 AND raiserId = 'process:tightbeam' AND actionKey LIKE ?2 AND status = 'open' AND rowid <= ?3",
          [statute_name, @episode_prefix <> "%", watermark]
        )
        |> Enum.each(fn [id] ->
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
  @spec recover_retired(DB.server()) :: :ok
  def recover_retired(db \\ DB) do
    {:ok, [[sessions_table]]} =
      DB.query(
        db,
        "SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name = 'sessions'"
      )

    if sessions_table == 1 do
      {:ok, rows} =
        DB.query(
          db,
          "SELECT s.sessionKey FROM sessions s WHERE s.state = 'retired' AND (EXISTS (SELECT 1 FROM decision_requests dr WHERE dr.raiserSessionKey = s.sessionKey AND dr.status = 'open') OR EXISTS (SELECT 1 FROM escalation_waivers ew WHERE ew.raiserId = 'session:' || s.sessionKey AND ew.revokedAt IS NULL))"
        )

      Enum.each(rows, fn [key] -> withdraw_for_retired(db, key) end)
    end

    :ok
  end

  @doc """
  List visible decision requests. Owner/admin and raiser visibility are disjoint
  filters.

  The listing also carries ADJUDICATION HOLDS, as a read-time union over
  adjudication episodes (spec s4-operability-v1 §2.3 — dark ≠ opaque). The
  decision_requests table is untouched: a hold is never a row there, its kind
  CHECK stays locked, and kind-filtering consumers see only a new kind value.
  """
  @spec list(DB.server(), map(), String.t() | nil, keyword()) :: [map()]
  def list(db, call, status \\ "open", opts \\ []) do
    {where, params} = visibility(call, Keyword.get(opts, :owner_user_id))
    status_clause = if is_binary(status), do: " AND status = ?#{length(params) + 1}", else: ""
    params = if is_binary(status), do: params ++ [status], else: params

    {:ok, rows} =
      DB.query(
        db,
        "SELECT #{@request_columns} FROM decision_requests WHERE (#{where})#{status_clause} ORDER BY rowid DESC",
        params
      )

    requests = Enum.map(rows, &(request_from_row(&1) |> list_projection()))

    if status in [nil, "open"] do
      merge_holds(requests, hold_rows(db, opts))
    else
      requests
    end
  end

  # Holds interleave by raisedAt into the EXISTING order. This walks the request
  # list and INSERTS holds into it rather than sorting the union: the existing
  # sequence is emitted in the order the query returned it, so it cannot be
  # permuted by a clock rollback or a migrated row whose timestamp does not track
  # its rowid (cross-review F7 — a global sort could reorder existing rows, and
  # the spec pins that existing results are NOT reordered).
  defp merge_holds(requests, []), do: requests

  defp merge_holds([], holds), do: Enum.sort_by(holds, &(-&1.raised_at))

  defp merge_holds([request | rest], holds) do
    {earlier, later} = Enum.split_with(holds, &(&1.raised_at > request.raised_at))
    Enum.sort_by(earlier, &(-&1.raised_at)) ++ [request | merge_holds(rest, later)]
  end

  @doc """
  Fetch one visible decision request including its halted-call context. A
  `"hold:"<episodeId>` id resolves to the synthetic hold row, read-only, under
  the same visibility rule as the listing.
  """
  @spec get(DB.server(), map(), String.t(), keyword()) :: map() | nil
  def get(db, call, id, opts \\ [])

  def get(db, _call, "hold:" <> episode_id, opts) do
    Enum.find(hold_rows(db, opts), &(&1.id == "hold:" <> episode_id))
  end

  def get(db, call, id, opts) do
    {where, params} = visibility(call, Keyword.get(opts, :owner_user_id))

    {:ok, rows} =
      DB.query(
        db,
        "SELECT #{@request_columns} FROM decision_requests WHERE id = ?1 AND (#{shift_params(where)})",
        [id | params]
      )

    case rows do
      [row] -> request_from_row(row)
      [] -> nil
    end
  end

  # A session's hold is OPEN whether it is wide ('*') or narrowed to an in-flight
  # heal probe — a probe-in-flight hold is still a hold, so the resolved episode
  # behind it is listed too. Admin visibility applies HERE ONLY; it never
  # broadens the decision_requests rows above.
  defp hold_rows(db, opts) do
    owner_user_id = Keyword.get(opts, :owner_user_id)
    admin? = Keyword.get(opts, :admin, false)

    if holds_available?(db) and (admin? or is_binary(owner_user_id)) do
      {:ok, rows} =
        DB.query(
          db,
          """
          SELECT e.episodeId, e.sessionKey, e.cause, e.openedAt
          FROM adjudication_episodes AS e
          JOIN sessions AS s ON s.sessionKey = e.sessionKey
          WHERE s.adjudicationHold IS NOT NULL
            AND e.episodeId IS NOT NULL
            AND (e.status IN ('claimed','notified')
                 OR (e.status = 'resolved' AND e.recoveryWakeId = s.adjudicationHold))
            AND (?1 = 1 OR s.ownerUserId = ?2)
          ORDER BY e.openedAt DESC
          """,
          [if(admin?, do: 1, else: 0), owner_user_id]
        )

      Enum.map(rows, fn [episode_id, session_key, cause, opened_at] ->
        %{
          kind: "adjudication_hold",
          id: "hold:" <> episode_id,
          status: "open",
          cause: cause,
          disposition:
            if(Adjudication.adapter_fault?(cause),
              do: "auto_on_adapter_heal",
              else: "awaits_ruling"
            ),
          session_key: session_key,
          raised_at: opened_at
        }
      end)
    else
      []
    end
  end

  defp holds_available?(db) do
    {:ok, [[count]]} =
      DB.query(
        db,
        "SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name IN ('adjudication_episodes', 'sessions')"
      )

    count == 2
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

          {request_in_txn(txn, request.id), fact_id}
        else
          current = request_in_txn(txn, request.id)

          # A concurrent-ruler loser filed nothing: it must not nudge (F13 —
          # one post-commit nudge per filed fact, owned by the filer).
          if current.status == "ruled" and current.decision == decision,
            do: {current, nil},
            else: {error("not_open", "decision request is not open"), nil}
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
                "SELECT id FROM decision_requests WHERE raiserId = ?1 AND statuteName = ?2 AND status = 'open' ORDER BY rowid",
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

          request_in_txn(txn, request.id)
        else
          error("not_open", "decision request is not open")
        end
      end)

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

  defp request_in_txn(txn, id) do
    [row] = Txn.q(txn, "SELECT #{@request_columns} FROM decision_requests WHERE id = ?1", [id])
    request_from_row(row)
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
      options: decode_optional(options),
      context: JSON.decode!(context),
      status: status,
      decision: decision,
      rationale: rationale,
      ruled_by: ruled_by,
      ruled_at: ruled_at,
      ruling_fact_id: ruling_fact_id,
      consumed_at: consumed_at,
      park_wake_id: park_wake_id,
      withdrawn_by: withdrawn_by,
      withdrawn_reason: withdrawn_reason,
      withdrawn_at: withdrawn_at
    }
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
    params = statute_params ++ effort_params

    numbered =
      "(kind = 'statute' AND #{statute_sql}) OR (kind = 'effort' AND #{effort_sql})"
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
  defp decode_optional(value), do: JSON.decode!(value)

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

  defp ensure_request_shape(db) do
    {:ok, [[sql]]} =
      DB.query(
        db,
        "SELECT sql FROM sqlite_master WHERE type = 'table' AND name = 'decision_requests'"
      )

    unless String.contains?(sql, "kind") and String.contains?(sql, "superseded") and
             String.contains?(sql, "effortGeneration") do
      {:ok, columns} = DB.query(db, "PRAGMA table_info(decision_requests)")
      names = Enum.map(columns, &Enum.at(&1, 1))

      copied =
        ~w(id raiserId raiserSessionKey ownerUserId assignmentId raisedAt deadlineAt statuteName actionKey question options context status decision rationale ruledBy ruledAt rulingFactId consumedAt parkWakeId withdrawnBy withdrawnReason withdrawnAt)
        |> Enum.filter(&(&1 in names))

      case DB.transaction(db, fn txn ->
             Txn.exec(txn, @rebuild_ddl)
             columns_sql = Enum.join(copied, ", ")

             Txn.exec(
               txn,
               "INSERT INTO decision_requests_new (#{columns_sql}, kind) SELECT #{columns_sql}, 'statute' FROM decision_requests"
             )

             Txn.exec(txn, "DROP TABLE decision_requests")
             Txn.exec(txn, "ALTER TABLE decision_requests_new RENAME TO decision_requests")
           end) do
        {:ok, _} -> :ok
        {:error, error} -> raise error
      end
    end

    :ok
  end

  defp indexes_ddl do
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
    """
  end

  defp waivers_ddl do
    """
    CREATE TABLE IF NOT EXISTS escalation_waivers (
      id TEXT PRIMARY KEY,
      raiserId TEXT NOT NULL,
      statuteName TEXT NOT NULL,
      grantedBy TEXT NOT NULL,
      grantedAt INTEGER NOT NULL,
      reason TEXT,
      revokedBy TEXT,
      revokedAt INTEGER
    );
    CREATE INDEX IF NOT EXISTS escalation_waivers_lookup
      ON escalation_waivers (raiserId, statuteName, revokedAt);
    """
  end
end
