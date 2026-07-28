defmodule Tightbeam.Adjudication do
  @moduledoc """
  Durable model-adjudication episodes and their guarded transition seams.

  The substrate classifies and routes; it never chooses a replacement model.
  Every episode transition is one guarded SQL statement, and stale correlation
  keys therefore have no effect.
  """

  alias Tightbeam.{
    AdapterCoordinator,
    CausalEvents,
    DB,
    EventLog,
    Idempotency,
    Supervision,
    Wakes
  }

  alias Tightbeam.DB.Txn

  @conditions ~w(auth_failed model_unavailable boot_failed quota_exhausted other)

  @adapter_fault_prefix "adapter_fault:"

  @ddl """
  CREATE TABLE IF NOT EXISTS adjudication_episodes (
    sessionKey TEXT NOT NULL,
    condition TEXT NOT NULL CHECK (condition IN ('auth_failed','model_unavailable','boot_failed','quota_exhausted','other')),
    status TEXT NOT NULL CHECK (status IN ('claimed','notified','resolved')),
    correlationKey TEXT NOT NULL,
    ownerTarget TEXT,
    ownerWakeId TEXT,
    recoveryWakeId TEXT,
    reresolveSeed TEXT,
    reresolveRung INTEGER,
    deadlineAt INTEGER NOT NULL,
    openedAt INTEGER NOT NULL,
    resolvedAt INTEGER,
    episodeId TEXT,
    cause TEXT,
    healToken TEXT,
    assignmentId TEXT,
    jobRef TEXT,
    PRIMARY KEY (sessionKey, condition)
  );
  CREATE INDEX IF NOT EXISTS adjudication_open_deadline
    ON adjudication_episodes (status, deadlineAt);
  """

  def ensure_schema(db \\ DB) do
    result = DB.execute(db, @ddl)

    # Additive, nullable, never backfilled by the migration: a NULL cause is a
    # LEGACY (or unclassified) hold and is never swept by an adapter heal.
    for ddl <- [
          "ALTER TABLE adjudication_episodes ADD COLUMN episodeId TEXT",
          "ALTER TABLE adjudication_episodes ADD COLUMN cause TEXT",
          "ALTER TABLE adjudication_episodes ADD COLUMN healToken TEXT",
          "ALTER TABLE adjudication_episodes ADD COLUMN assignmentId TEXT",
          "ALTER TABLE adjudication_episodes ADD COLUMN jobRef TEXT"
        ] do
      case DB.query(db, ddl) do
        {:ok, _} -> :ok
        {:error, e} -> if inspect(e) =~ "duplicate column", do: :ok, else: raise(e)
      end
    end

    :ok =
      DB.execute(
        db,
        "CREATE INDEX IF NOT EXISTS adjudication_episode_id ON adjudication_episodes (episodeId);"
      )

    result
  end

  @doc "The pinned cause encoding for an adapter fault on `key`."
  @spec adapter_fault_cause(AdapterCoordinator.adapter_key()) :: String.t()
  def adapter_fault_cause(key), do: adapter_fault_cause_for_name(AdapterCoordinator.key_name(key))

  @doc "Same encoding, from an already-rendered key string (what the ready event carries)."
  @spec adapter_fault_cause_for_name(String.t()) :: String.t()
  def adapter_fault_cause_for_name(key_name), do: @adapter_fault_prefix <> key_name

  @doc "Whether a cause is auto-releasable by an adapter heal (NULL/model_decision are not)."
  @spec adapter_fault?(String.t() | nil) :: boolean()
  def adapter_fault?(cause),
    do: is_binary(cause) and String.starts_with?(cause, @adapter_fault_prefix)

  @doc "Pluggable runtime classifier. The initial engine deliberately defaults to `other`."
  @spec classify(term()) :: String.t()
  def classify(_error), do: "other"

  @doc "Record the raw error envelope required by the fail-loud `other` floor."
  def record_unclassified_in_txn(%Txn{} = txn, session_key, raw_error) do
    detail =
      try do
        JSON.encode!(raw_error)
      rescue
        _ -> JSON.encode!(%{term: inspect(raw_error)})
      end

    EventLog.lifecycle_in_txn(txn, "unclassified_harness_error", session_key, detail)
  end

  @doc "Atomic first claim. Returns the episode only to the winner."
  def claim_in_txn(%Txn{} = txn, session_key, condition, opts \\ [])
      when condition in @conditions do
    now = Keyword.get(opts, :now, now())
    correlation_key = Keyword.get(opts, :correlation_key, correlation_key())
    claim_window = Keyword.fetch!(opts, :claim_window_ms)
    seed = Keyword.get(opts, :reresolve_seed, session_key)
    rung = Keyword.get(opts, :reresolve_rung, 1)

    {assignment_id, job_ref} = failing_turn_attribution(txn, opts)

    Txn.q(
      txn,
      """
      INSERT INTO adjudication_episodes
        (sessionKey, condition, status, correlationKey, reresolveSeed,
         reresolveRung, deadlineAt, openedAt, episodeId, cause, assignmentId, jobRef)
      VALUES (?1, ?2, 'claimed', ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11)
      ON CONFLICT(sessionKey, condition) DO NOTHING
      """,
      [
        session_key,
        condition,
        correlation_key,
        seed,
        rung,
        now + claim_window,
        now,
        Tightbeam.Id.ulid(),
        Keyword.get(opts, :cause),
        assignment_id,
        job_ref
      ]
    )

    if Txn.changes(txn) == 1, do: get_in_txn(txn, session_key, condition), else: nil
  end

  @doc "Guarded reopen of a resolved episode."
  def reopen_in_txn(%Txn{} = txn, session_key, condition, opts) do
    now = Keyword.get(opts, :now, now())
    correlation_key = Keyword.get(opts, :correlation_key, correlation_key())
    {assignment_id, job_ref} = failing_turn_attribution(txn, opts)
    prior = get_in_txn(txn, session_key, condition)
    rung = Keyword.get(opts, :reresolve_rung, 1)

    Txn.q(
      txn,
      """
      UPDATE adjudication_episodes
      SET status='claimed', correlationKey=?3, ownerTarget=NULL, ownerWakeId=NULL,
          recoveryWakeId=NULL, reresolveSeed=?4, reresolveRung=?5,
          deadlineAt=?6, openedAt=?7, resolvedAt=NULL,
          episodeId=COALESCE(episodeId, ?8), cause=?9,
          healToken=CASE WHEN ?10 IS NOT NULL AND recoveryWakeId = ?10
                         THEN healToken ELSE NULL END,
          assignmentId=?11, jobRef=?12
      WHERE sessionKey=?1 AND condition=?2 AND status='resolved'
      """,
      [
        session_key,
        condition,
        correlation_key,
        Keyword.get(opts, :reresolve_seed, session_key),
        rung,
        now + Keyword.fetch!(opts, :claim_window_ms),
        now,
        Tightbeam.Id.ulid(),
        Keyword.get(opts, :cause),
        # The FAILING turn's wake. When it is this episode's own probe wake the
        # reopen is a probe failure: keep healToken so the re-held session waits
        # for a STRICTLY NEWER token instead of re-probing the same one forever.
        # Any other reopen is a genuinely new fault and starts token-eligible.
        Keyword.get(opts, :failing_wake_id),
        assignment_id,
        job_ref
      ]
    )

    if Txn.changes(txn) == 1 do
      episode = get_in_txn(txn, session_key, condition)

      CausalEvents.append_in_txn(txn, %{
        kind: "adjudication_reopen",
        at: now,
        assignment_id: episode.assignment_id,
        job_ref: episode.job_ref,
        session_key: session_key,
        detail: %{
          episodeId: episode.episode_id,
          fromState: prior.status,
          toState: episode.status,
          toRung: rung,
          toTarget: episode.owner_target
        }
      })

      episode
    else
      nil
    end
  end

  # The claim carries only the failing turn's seq; the attribution is whatever
  # that TURN durably records. NULL stamps NULL — never the session's "active"
  # assignment, which a session can hold several of (spec job-forensics-v2 §1).
  defp failing_turn_attribution(%Txn{} = txn, opts) do
    with seq when is_integer(seq) <- Keyword.get(opts, :failing_seq),
         [[assignment_id, job_ref]] <-
           Txn.q(txn, "SELECT assignmentId, jobRef FROM turns WHERE seq = ?1", [seq]) do
      {assignment_id, job_ref}
    else
      _ -> {nil, nil}
    end
  end

  @doc "Schedule the deterministic owner wake and perform claimed→notified in the same txn."
  def notify_in_txn(%Txn{} = txn, episode, prompt, response_window_ms) do
    target =
      Supervision.ladder_target(txn, episode.reresolve_seed, episode.reresolve_rung)

    wake_id =
      deterministic_wake_in_txn(
        txn,
        episode,
        "owner",
        target,
        prompt <> "\nepisode=" <> episode.correlation_key
      )

    Txn.q(
      txn,
      """
      UPDATE adjudication_episodes
      SET status='notified', ownerWakeId=?4, ownerTarget=?3, deadlineAt=?5
      WHERE sessionKey=?1 AND condition=?2 AND status='claimed' AND correlationKey=?6
      """,
      [
        episode.session_key,
        episode.condition,
        target,
        wake_id,
        now() + response_window_ms,
        episode.correlation_key
      ]
    )

    if Txn.changes(txn) == 1, do: {:ok, wake_id, target}, else: :stale
  end

  @doc "Guarded notified→resolved. Resolution never releases the session hold."
  def resolve_in_txn(%Txn{} = txn, episode, recovery_wake_id \\ nil) do
    Txn.q(
      txn,
      """
      UPDATE adjudication_episodes
      SET status='resolved', recoveryWakeId=?4, resolvedAt=?5
      WHERE sessionKey=?1 AND condition=?2 AND status='notified' AND correlationKey=?3
      """,
      [episode.session_key, episode.condition, episode.correlation_key, recovery_wake_id, now()]
    )

    Txn.changes(txn) == 1
  end

  def get(db \\ DB, session_key, condition) do
    {:ok, rows} =
      DB.query(db, select_sql() <> " WHERE sessionKey=?1 AND condition=?2", [
        session_key,
        condition
      ])

    one(rows)
  end

  def get_by_correlation(db \\ DB, correlation_key) do
    {:ok, rows} = DB.query(db, select_sql() <> " WHERE correlationKey=?1", [correlation_key])
    one(rows)
  end

  def get_in_txn(%Txn{} = txn, session_key, condition) do
    txn
    |> Txn.q(select_sql() <> " WHERE sessionKey=?1 AND condition=?2", [session_key, condition])
    |> one()
  end

  def get_by_correlation_in_txn(%Txn{} = txn, correlation_key) do
    txn |> Txn.q(select_sql() <> " WHERE correlationKey=?1", [correlation_key]) |> one()
  end

  def open_for_session?(db, session_key) do
    case DB.query(
           db,
           "SELECT count(*) FROM adjudication_episodes WHERE sessionKey=?1 AND status IN ('claimed','notified')",
           [session_key]
         ) do
      {:ok, [[count]]} -> count > 0
      {:error, _} -> false
    end
  end

  @doc "Boot reconciliation verifies durable episode/wake/filter facts; it never arms a filter."
  def reconcile(db \\ DB) do
    {:ok, _} =
      DB.transaction(db, fn txn ->
        Txn.q(
          txn,
          """
          UPDATE adjudication_episodes AS e
          SET status='notified'
          WHERE status='claimed' AND ownerWakeId IS NOT NULL
            AND EXISTS (SELECT 1 FROM wakes WHERE wakeId=e.ownerWakeId)
          """
        )

        # episodeId is the STABLE READ HANDLE the listing exposes; rows that
        # predate the column are backfilled on this first touch. No other
        # retroactive repair happens here — cause stays NULL, so a legacy hold
        # is never swept.
        for [session_key, condition] <-
              Txn.q(
                txn,
                "SELECT sessionKey, condition FROM adjudication_episodes WHERE episodeId IS NULL"
              ) do
          Txn.q(
            txn,
            "UPDATE adjudication_episodes SET episodeId=?3 WHERE sessionKey=?1 AND condition=?2",
            [session_key, condition, Tightbeam.Id.ulid()]
          )
        end

        # PROBE-TERMINAL TOTALITY, boot half: a hold narrowed to a probe wake
        # whose turn never reached a terminal must RE-HOLD, not clear — clearing
        # would free the session onto the same unhealed adapter. Every other
        # narrowed hold clears exactly as before.
        reheld =
          Txn.q(
            txn,
            """
            SELECT e.sessionKey, e.condition
            FROM sessions AS s
            JOIN adjudication_episodes AS e
              ON e.sessionKey=s.sessionKey AND e.recoveryWakeId=s.adjudicationHold
            WHERE s.adjudicationHold IS NOT NULL AND s.adjudicationHold != '*'
              AND NOT EXISTS (
                SELECT 1 FROM turns AS t
                WHERE t.sessionKey=s.sessionKey AND t.wakeId=s.adjudicationHold
                  AND t.status IN ('queued','running')
              )
              AND e.healToken IS NOT NULL AND e.cause LIKE '#{@adapter_fault_prefix}%'
            """
          )

        Txn.q(
          txn,
          """
          UPDATE sessions AS s SET adjudicationHold='*', updatedAt=?1
          WHERE adjudicationHold IS NOT NULL AND adjudicationHold != '*'
            AND NOT EXISTS (
              SELECT 1 FROM turns AS t
              WHERE t.sessionKey=s.sessionKey AND t.wakeId=s.adjudicationHold
                AND t.status IN ('queued','running')
            )
            AND EXISTS (
              SELECT 1 FROM adjudication_episodes AS e
              WHERE e.sessionKey=s.sessionKey AND e.recoveryWakeId=s.adjudicationHold
                AND e.healToken IS NOT NULL AND e.cause LIKE '#{@adapter_fault_prefix}%'
            )
          """,
          [now()]
        )

        # The vanished probe re-holds like any other non-delivered probe
        # terminal, so it arms the same retry (idempotent per failed probe).
        for [session_key, condition] <- reheld,
            episode = get_in_txn(txn, session_key, condition),
            do: schedule_probe_retry_in_txn(txn, episode)

        Txn.q(
          txn,
          """
          UPDATE sessions AS s SET adjudicationHold=NULL, updatedAt=?1
          WHERE adjudicationHold IS NOT NULL AND adjudicationHold != '*'
            AND NOT EXISTS (
              SELECT 1 FROM turns AS t
              WHERE t.sessionKey=s.sessionKey AND t.wakeId=s.adjudicationHold
                AND t.status IN ('queued','running')
            )
          """,
          [now()]
        )

        :ok
      end)

    :ok
  end

  @doc "Escalate each overdue open episode exactly one ladder rung."
  def escalate_due(db \\ DB, response_window_ms) do
    rows =
      case DB.query(
             db,
             "SELECT sessionKey, condition FROM adjudication_episodes WHERE status IN ('claimed','notified') AND deadlineAt <= ?1 ORDER BY deadlineAt",
             [now()]
           ) do
        {:ok, rows} -> rows
        {:error, _} -> []
      end

    Enum.each(rows, fn [session_key, condition] ->
      DB.transaction(db, fn txn ->
        case get_in_txn(txn, session_key, condition) do
          %{status: status, deadline_at: deadline} = episode
          when status in ["claimed", "notified"] ->
            if deadline > now() do
              false
            else
              old_prompt =
                case Txn.q(txn, "SELECT prompt FROM wakes WHERE wakeId=?1", [
                       episode.owner_wake_id
                     ]) do
                  [[prompt]] ->
                    prompt

                  [] ->
                    # The original brief's wake is gone; this fallback still owes
                    # the reader the precise cause the episode carries, not just
                    # the coarse condition it is keyed on.
                    "Model adjudication remains unanswered for #{session_key} " <>
                      "(condition=#{condition} cause=#{episode.cause || "unclassified"})."
                end

              next = %{
                episode
                | correlation_key: correlation_key(),
                  reresolve_rung: episode.reresolve_rung + 1
              }

              target = Supervision.ladder_target(txn, next.reresolve_seed, next.reresolve_rung)
              wake_id = deterministic_wake_in_txn(txn, next, "owner", target, old_prompt)

              Wakes.cancel_pending_in_txn(txn, episode.owner_wake_id)

              Txn.q(
                txn,
                """
                UPDATE adjudication_episodes
                SET status='notified', correlationKey=?4, ownerTarget=?5, ownerWakeId=?6,
                    reresolveRung=?7, deadlineAt=?8
                WHERE sessionKey=?1 AND condition=?2 AND status=?3 AND correlationKey=?9
                """,
                [
                  session_key,
                  condition,
                  status,
                  next.correlation_key,
                  target,
                  wake_id,
                  next.reresolve_rung,
                  now() + response_window_ms,
                  episode.correlation_key
                ]
              )

              if Txn.changes(txn) == 1 do
                CausalEvents.append_in_txn(txn, %{
                  kind: "adjudication_escalate",
                  assignment_id: episode.assignment_id,
                  job_ref: episode.job_ref,
                  session_key: session_key,
                  detail: %{
                    episodeId: episode.episode_id,
                    fromState: status,
                    toState: "notified",
                    toRung: next.reresolve_rung,
                    toTarget: target
                  }
                })

                true
              else
                false
              end
            end

          _ ->
            false
        end
      end)
    end)

    :ok
  end

  ## Adapter-heal auto-release (spec s4-operability-v1 §2)

  @probe_prompt "[adapter recovered]\n\nThe adapter fault that halted this session has cleared. Re-derive your state from the durable facts and continue."

  @doc """
  Held sessions this ready token should probe: hold is still `'*'` (a hold
  narrowed to a probe wake already has one in flight), the episode's cause names
  THIS adapter key, and the token is strictly newer than the one that last
  probed it — so replaying a token produces nothing and a post-restart ready
  (new epoch) always qualifies. Returns `{session_key, condition}` pairs.
  """
  @spec heal_candidates(DB.server(), String.t(), AdapterCoordinator.heal_token(), keyword()) ::
          [{String.t(), String.t()}]
  def heal_candidates(db \\ DB, cause, token, opts \\ []) do
    # `include_equal` is reserved for the probe RETRY (spec §2): a re-hold is a
    # new hold and its one probe may re-use the token that already probed the
    # previous hold. The ready-event sweeps never pass it — an equal token there
    # is a replayed event and stays a no-op.
    include_equal = Keyword.get(opts, :include_equal, false)

    {:ok, rows} =
      DB.query(
        db,
        """
        SELECT e.sessionKey, e.condition, e.healToken
        FROM adjudication_episodes AS e
        JOIN sessions AS s ON s.sessionKey = e.sessionKey
        WHERE s.adjudicationHold = '*' AND s.state = 'active' AND e.cause = ?1
        ORDER BY e.openedAt, e.condition
        """,
        [cause]
      )

    for [session_key, condition, heal_token] <- rows,
        probe_worthy?(token, AdapterCoordinator.decode_token(heal_token), include_equal),
        do: {session_key, condition}
  end

  defp probe_worthy?(token, prior, include_equal),
    do: AdapterCoordinator.newer_token?(token, prior) or (include_equal and token == prior)

  @doc """
  The probe wake for one (episode, token) — deterministic, so an at-least-once
  sweep enqueues EXACTLY ONE probe turn per token even if it runs twice. The
  token is part of the idempotency key, and so is the PREDECESSOR probe when one
  exists (`recoveryWakeId` at probe time — the probe whose failure re-held the
  session): a retry probing the SAME token on an un-reopened episode is a new
  attempt, not a replay, and must mint a new wake the ledger's UNIQUE wakeId
  admits.
  """
  @spec probe_wake_in_txn(Txn.t(), map(), String.t()) :: String.t()
  def probe_wake_in_txn(%Txn{} = txn, episode, encoded_token) do
    attempt =
      case episode.recovery_wake_id do
        prior when is_binary(prior) -> ":after:" <> prior
        _ -> ""
      end

    idempotent_wake_in_txn(
      txn,
      episode,
      "probe:" <> encoded_token <> attempt,
      episode.session_key,
      @probe_prompt,
      nil
    )
  end

  @doc "The prompt a probe turn carries (also the text the session sees in history)."
  @spec probe_prompt() :: String.t()
  def probe_prompt, do: @probe_prompt

  @probe_retry_consumer "adjudication_heal_retry"

  @doc "The wake consumer name the composition root registers for probe retries."
  @spec probe_retry_consumer() :: String.t()
  def probe_retry_consumer, do: @probe_retry_consumer

  @doc """
  Arm a re-held session's probe retry (spec s4-operability-v1 §2): a re-hold is
  a NEW hold, and this wake delivers its one probe. Time, not a ready edge,
  carries the wake-up — the failed probe's adapter may already be ready and will
  then never emit another edge (the task #103 wedge). Idempotent per failed
  probe (`recoveryWakeId` at re-hold time), so the terminal writer and boot
  reconciliation arm at most one retry for the same failure.
  """
  @spec schedule_probe_retry_in_txn(Txn.t(), map()) :: :ok
  def schedule_probe_retry_in_txn(%Txn{} = txn, episode) do
    wakes_exist? =
      Txn.q(txn, "SELECT 1 FROM sqlite_master WHERE type='table' AND name='wakes'") == [[1]]

    if wakes_exist? and is_binary(episode.recovery_wake_id) do
      key =
        Enum.join(
          [
            "adjudication",
            episode.session_key,
            episode.condition,
            "heal_retry",
            episode.recovery_wake_id
          ],
          ":"
        )

      unless Idempotency.get_in_txn(txn, episode.session_key, "wake", key) do
        wake =
          Wakes.schedule_in_txn(txn, %{
            session_key: episode.session_key,
            origin: "process:tightbeam",
            consumer: @probe_retry_consumer,
            due_at: now() + probe_retry_ms()
          })

        Idempotency.put_in_txn(txn, %{
          owner_user_id: episode.session_key,
          operation: "wake",
          idempotency_key: key,
          session_key: wake.wake_id
        })
      end
    end

    :ok
  end

  defp probe_retry_ms,
    do: Application.get_env(:tightbeam, :adjudication_probe_retry_ms, 30_000)

  @doc """
  Whether an episode is in a state a heal may take. This is the episode-state
  half of the heal-vs-ruling CAS, and it is NOT the same question as "is the
  session held":

  - `claimed`/`notified` — open, no ruling has landed, the heal may take it.
  - `resolved` WITH a healToken — a previous probe resolved it and its terminal
    re-held the session; the heal may take it again on a newer token.
  - `resolved` WITHOUT a healToken — a HUMAN RULING resolved it, and the heal must
    keep its hands off. A delayed `park` is exactly this shape: it resolves the
    episode but leaves the hold wide until its condition wake fires, so a
    hold-only guard would let a later heal overwrite the winning ruling
    (cross-review F3).
  """
  @spec heal_eligible?(map()) :: boolean()
  def heal_eligible?(%{status: status}) when status in ["claimed", "notified"], do: true
  def heal_eligible?(%{status: "resolved", heal_token: token}), do: not is_nil(token)
  def heal_eligible?(_episode), do: false

  @doc """
  Resolve an episode as HEALED and stamp the token that probed it, CAS'd on the
  episode still being heal-eligible per `heal_eligible?/1`. Returns true only
  when this transition won; a false return means a human ruling got there first
  and the caller must not proceed.
  """
  @spec heal_resolve_in_txn(Txn.t(), map(), String.t(), String.t()) :: boolean()
  def heal_resolve_in_txn(%Txn{} = txn, episode, probe_wake_id, encoded_token) do
    Txn.q(
      txn,
      """
      UPDATE adjudication_episodes
      SET status='resolved', recoveryWakeId=?3, resolvedAt=?4, healToken=?5
      WHERE sessionKey=?1 AND condition=?2
        AND (status IN ('claimed','notified') OR healToken IS NOT NULL)
      """,
      [episode.session_key, episode.condition, probe_wake_id, now(), encoded_token]
    )

    Txn.changes(txn) == 1
  end

  @doc """
  Dispose the owner-adjudication wake at heal time. A PENDING wake is canceled;
  a FIRED one is left alone — its owner turn is already queued or running and
  its eventual ruling lands on a resolved episode, where it is an acknowledged
  no-op. Returns `:canceled` or `:left_fired`.
  """
  @spec dispose_owner_wake_in_txn(Txn.t(), map()) :: :canceled | :left_fired
  def dispose_owner_wake_in_txn(%Txn{}, %{owner_wake_id: nil}), do: :left_fired

  def dispose_owner_wake_in_txn(%Txn{} = txn, episode) do
    if Wakes.cancel_pending_in_txn(txn, episode.owner_wake_id),
      do: :canceled,
      else: :left_fired
  end

  @doc """
  The episode whose in-flight PROBE is the given wake, or nil. `healToken IS NOT
  NULL` is what separates a probe from a human ruling's recovery wake — only the
  heal sweep ever stamps it — so probe-terminal handling can never disturb the
  human path.
  """
  @spec probe_episode_for_wake_in_txn(Txn.t(), String.t()) :: map() | nil
  def probe_episode_for_wake_in_txn(%Txn{} = txn, wake_id) do
    txn
    |> Txn.q(
      select_sql() <>
        " WHERE recoveryWakeId=?1 AND healToken IS NOT NULL AND cause LIKE '#{@adapter_fault_prefix}%'",
      [wake_id]
    )
    |> one()
  end

  def deterministic_wake_in_txn(%Txn{} = txn, episode, purpose, target, prompt)
      when purpose in ~w(owner recovery) do
    idempotent_wake_in_txn(
      txn,
      episode,
      purpose,
      target,
      prompt,
      if(purpose == "owner", do: "lineage")
    )
  end

  defp idempotent_wake_in_txn(%Txn{} = txn, episode, purpose, target, prompt, reresolve) do
    key =
      Enum.join(
        [
          "adjudication",
          episode.session_key,
          episode.condition,
          episode.correlation_key,
          purpose
        ],
        ":"
      )

    case Idempotency.get_in_txn(txn, episode.session_key, "wake", key) do
      %{session_key: wake_id} ->
        wake_id

      nil ->
        wake =
          Wakes.schedule_in_txn(txn, %{
            session_key: target,
            origin: "process:tightbeam",
            prompt: prompt,
            due_at: now(),
            reresolve: reresolve,
            reresolve_seed: episode.reresolve_seed,
            reresolve_rung: episode.reresolve_rung
          })

        Idempotency.put_in_txn(txn, %{
          owner_user_id: episode.session_key,
          operation: "wake",
          idempotency_key: key,
          session_key: wake.wake_id
        })

        wake.wake_id
    end
  end

  defp select_sql do
    "SELECT sessionKey, condition, status, correlationKey, ownerTarget, ownerWakeId, recoveryWakeId, reresolveSeed, reresolveRung, deadlineAt, openedAt, resolvedAt, episodeId, cause, healToken, assignmentId, jobRef FROM adjudication_episodes"
  end

  defp one([row]), do: row(row)
  defp one([]), do: nil

  defp row([
         session,
         condition,
         status,
         correlation,
         owner,
         owner_wake,
         recovery_wake,
         seed,
         rung,
         deadline,
         opened,
         resolved,
         episode_id,
         cause,
         heal_token,
         assignment_id,
         job_ref
       ]) do
    %{
      session_key: session,
      condition: condition,
      status: status,
      correlation_key: correlation,
      owner_target: owner,
      owner_wake_id: owner_wake,
      recovery_wake_id: recovery_wake,
      reresolve_seed: seed,
      reresolve_rung: rung,
      deadline_at: deadline,
      opened_at: opened,
      resolved_at: resolved,
      episode_id: episode_id,
      cause: cause,
      heal_token: heal_token,
      assignment_id: assignment_id,
      job_ref: job_ref
    }
  end

  defp correlation_key, do: "adj_" <> Tightbeam.Id.uuid4()
  defp now, do: System.system_time(:millisecond)
end
