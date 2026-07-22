defmodule Tightbeam.Adjudication do
  @moduledoc """
  Durable model-adjudication episodes and their guarded transition seams.

  The substrate classifies and routes; it never chooses a replacement model.
  Every episode transition is one guarded SQL statement, and stale correlation
  keys therefore have no effect.
  """

  alias Tightbeam.{DB, EventLog, Idempotency, Supervision, Wakes}
  alias Tightbeam.DB.Txn

  @conditions ~w(auth_failed model_unavailable boot_failed quota_exhausted other)

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
    PRIMARY KEY (sessionKey, condition)
  );
  CREATE INDEX IF NOT EXISTS adjudication_open_deadline
    ON adjudication_episodes (status, deadlineAt);
  """

  def ensure_schema(db \\ DB), do: DB.execute(db, @ddl)

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

    Txn.q(
      txn,
      """
      INSERT INTO adjudication_episodes
        (sessionKey, condition, status, correlationKey, reresolveSeed,
         reresolveRung, deadlineAt, openedAt)
      VALUES (?1, ?2, 'claimed', ?3, ?4, ?5, ?6, ?7)
      ON CONFLICT(sessionKey, condition) DO NOTHING
      """,
      [session_key, condition, correlation_key, seed, rung, now + claim_window, now]
    )

    if Txn.changes(txn) == 1, do: get_in_txn(txn, session_key, condition), else: nil
  end

  @doc "Guarded reopen of a resolved episode."
  def reopen_in_txn(%Txn{} = txn, session_key, condition, opts) do
    now = Keyword.get(opts, :now, now())
    correlation_key = Keyword.get(opts, :correlation_key, correlation_key())

    Txn.q(
      txn,
      """
      UPDATE adjudication_episodes
      SET status='claimed', correlationKey=?3, ownerTarget=NULL, ownerWakeId=NULL,
          recoveryWakeId=NULL, reresolveSeed=?4, reresolveRung=?5,
          deadlineAt=?6, openedAt=?7, resolvedAt=NULL
      WHERE sessionKey=?1 AND condition=?2 AND status='resolved'
      """,
      [
        session_key,
        condition,
        correlation_key,
        Keyword.get(opts, :reresolve_seed, session_key),
        Keyword.get(opts, :reresolve_rung, 1),
        now + Keyword.fetch!(opts, :claim_window_ms),
        now
      ]
    )

    if Txn.changes(txn) == 1, do: get_in_txn(txn, session_key, condition), else: nil
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
                  [[prompt]] -> prompt
                  [] -> "Model adjudication remains unanswered for #{session_key} (#{condition})."
                end

              next = %{
                episode
                | correlation_key: correlation_key(),
                  reresolve_rung: episode.reresolve_rung + 1
              }

              target = Supervision.ladder_target(txn, next.reresolve_seed, next.reresolve_rung)
              wake_id = deterministic_wake_in_txn(txn, next, "owner", target, old_prompt)

              Txn.q(
                txn,
                "UPDATE wakes SET state='canceled' WHERE wakeId=?1 AND state='pending'",
                [episode.owner_wake_id]
              )

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

              Txn.changes(txn) == 1
            end

          _ ->
            false
        end
      end)
    end)

    :ok
  end

  def deterministic_wake_in_txn(%Txn{} = txn, episode, purpose, target, prompt)
      when purpose in ~w(owner recovery) do
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
            reresolve: if(purpose == "owner", do: "lineage"),
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
    "SELECT sessionKey, condition, status, correlationKey, ownerTarget, ownerWakeId, recoveryWakeId, reresolveSeed, reresolveRung, deadlineAt, openedAt, resolvedAt FROM adjudication_episodes"
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
         resolved
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
      resolved_at: resolved
    }
  end

  defp correlation_key, do: "adj_" <> Tightbeam.Id.uuid4()
  defp now, do: System.system_time(:millisecond)
end
