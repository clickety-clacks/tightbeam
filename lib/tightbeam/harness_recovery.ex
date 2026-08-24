defmodule Tightbeam.HarnessRecovery do
  @moduledoc """
  Durable, use-confirmed harness recovery episodes.

  An unavailable turn opens one episode for its `{owner, harness}`. The first
  later delivered turn on that scope closes the episode and schedules one
  immediate prompt to the owner's existing Main. Main owns the judgment about
  which live agents and stalled graphs are relevant; this module never fans out
  to product agents.

  The episode transition and wake row share the turn's terminal transaction.
  A crash can therefore leave both pending or neither, never a closed episode
  with a lost wake. Adapter startup is deliberately not a recovery signal: a
  delivered turn is the first observation that proves the harness can answer.
  """

  alias Tightbeam.DB.Txn
  alias Tightbeam.{EventLog, Org, Wakes}

  @origin "process:tightbeam"
  @unavailable_codes ~w(adapter_unavailable harness_unavailable model_unavailable usageLimitExceeded)

  @ddl """
  CREATE TABLE IF NOT EXISTS harness_recovery_episodes (
    ownerUserId       TEXT NOT NULL,
    harness           TEXT NOT NULL,
    state             TEXT NOT NULL CHECK (state IN ('open','closed')),
    generation        INTEGER NOT NULL CHECK (generation > 0),
    openedAt          INTEGER NOT NULL,
    openedBySession   TEXT NOT NULL,
    openedByTurn      INTEGER NOT NULL,
    lastFailureAt     INTEGER NOT NULL,
    lastFailureSession TEXT NOT NULL,
    lastFailureTurn   INTEGER NOT NULL,
    lastError         TEXT NOT NULL,
    closedAt          INTEGER,
    recoverySession   TEXT,
    recoveryTurn      INTEGER,
    recoveryWakeId    TEXT,
    PRIMARY KEY (ownerUserId, harness),
    CHECK (
      (state = 'open' AND closedAt IS NULL AND recoverySession IS NULL AND
       recoveryTurn IS NULL AND recoveryWakeId IS NULL)
      OR
      (state = 'closed' AND closedAt IS NOT NULL AND recoverySession IS NOT NULL AND
       recoveryTurn IS NOT NULL AND recoveryWakeId IS NOT NULL)
    )
  );
  """

  @spec ensure_schema(GenServer.server()) :: :ok | {:error, term()}
  def ensure_schema(db \\ Tightbeam.DB), do: Tightbeam.DB.execute(db, @ddl)

  @doc "Does this turn failure mean the selected harness could not answer?"
  @spec unavailable?(term()) :: boolean()
  def unavailable?(reason)

  def unavailable?(reason)
      when reason in [:adapter_unavailable, :harness_unavailable, :model_unavailable],
      do: true

  def unavailable?({kind, _detail}) when kind in [:adapter_unavailable, :harness_unavailable],
    do: true

  def unavailable?({:model_apply_failed, reason}), do: unavailable?(reason)
  def unavailable?({:error, reason}), do: unavailable?(reason)

  def unavailable?(%{} = reason) do
    reason
    |> Map.take([
      :code,
      "code",
      :codexErrorInfo,
      "codexErrorInfo",
      :data,
      "data",
      :error,
      "error"
    ])
    |> Map.values()
    |> Enum.any?(&unavailable?/1)
  end

  def unavailable?(reason) when is_binary(reason),
    do: reason in @unavailable_codes or String.trim_leading(reason, ":") in @unavailable_codes

  def unavailable?(_reason), do: false

  @doc "Open or extend one owner+harness outage episode for a classified failed turn."
  @spec observe_failure_in_txn(Txn.t(), map()) :: :opened | :ignored
  def observe_failure_in_txn(%Txn{} = txn, observation) do
    reason = Map.fetch!(observation, :reason)

    if unavailable?(reason) do
      owner = Map.fetch!(observation, :owner_user_id)
      harness = Map.fetch!(observation, :harness)
      session = Map.fetch!(observation, :session_key)
      turn = Map.fetch!(observation, :turn_seq)
      at = Map.get(observation, :at, now())
      error = inspect(reason, limit: 20, printable_limit: 500)

      Txn.q(
        txn,
        """
        INSERT INTO harness_recovery_episodes
          (ownerUserId, harness, state, generation, openedAt, openedBySession,
           openedByTurn, lastFailureAt, lastFailureSession, lastFailureTurn, lastError)
        VALUES (?1, ?2, 'open', 1, ?3, ?4, ?5, ?3, ?4, ?5, ?6)
        ON CONFLICT(ownerUserId, harness) DO UPDATE SET
          state='open',
          generation=CASE
            WHEN harness_recovery_episodes.state='closed'
            THEN harness_recovery_episodes.generation + 1
            ELSE harness_recovery_episodes.generation
          END,
          openedAt=CASE
            WHEN harness_recovery_episodes.state='closed' THEN excluded.openedAt
            ELSE harness_recovery_episodes.openedAt
          END,
          openedBySession=CASE
            WHEN harness_recovery_episodes.state='closed' THEN excluded.openedBySession
            ELSE harness_recovery_episodes.openedBySession
          END,
          openedByTurn=CASE
            WHEN harness_recovery_episodes.state='closed' THEN excluded.openedByTurn
            ELSE harness_recovery_episodes.openedByTurn
          END,
          lastFailureAt=excluded.lastFailureAt,
          lastFailureSession=excluded.lastFailureSession,
          lastFailureTurn=excluded.lastFailureTurn,
          lastError=excluded.lastError,
          closedAt=NULL,
          recoverySession=NULL,
          recoveryTurn=NULL,
          recoveryWakeId=NULL
        """,
        [owner, harness, at, session, turn, error]
      )

      EventLog.lifecycle_in_txn(
        txn,
        "harness_unavailable",
        "#{owner}/#{harness}",
        "turn=#{turn} session=#{session} reason=#{error} principal=#{@origin}"
      )

      :opened
    else
      :ignored
    end
  end

  @doc "Close an open episode on a delivered turn and schedule its sole Main wake."
  @spec observe_success_in_txn(Txn.t(), map()) :: {:woke, String.t()} | :no_episode | :no_main
  def observe_success_in_txn(%Txn{} = txn, observation) do
    owner = Map.fetch!(observation, :owner_user_id)
    harness = Map.fetch!(observation, :harness)
    session = Map.fetch!(observation, :session_key)
    turn = Map.fetch!(observation, :turn_seq)
    at = Map.get(observation, :at, now())
    main = Org.personal_session_key(owner)

    case Txn.q(
           txn,
           "SELECT generation, openedByTurn, lastFailureTurn FROM harness_recovery_episodes WHERE ownerUserId=?1 AND harness=?2 AND state='open'",
           [owner, harness]
         ) do
      [] ->
        :no_episode

      [[generation, opened_by_turn, last_failure_turn]] ->
        if active_main?(txn, main) do
          wake =
            Wakes.schedule_in_txn(txn, %{
              session_key: main,
              origin: @origin,
              prompt:
                recovery_prompt(harness, generation, opened_by_turn, last_failure_turn, turn),
              due_at: at,
              class: "blocker"
            })

          Txn.q(
            txn,
            """
            UPDATE harness_recovery_episodes
            SET state='closed', closedAt=?3, recoverySession=?4, recoveryTurn=?5,
                recoveryWakeId=?6
            WHERE ownerUserId=?1 AND harness=?2 AND state='open'
            """,
            [owner, harness, at, session, turn, wake.wake_id]
          )

          if Txn.changes(txn) != 1 do
            raise "harness recovery episode changed while its wake was scheduled"
          end

          EventLog.lifecycle_in_txn(
            txn,
            "harness_recovered",
            "#{owner}/#{harness}",
            "turn=#{turn} session=#{session} wake=#{wake.wake_id} target=#{main} principal=#{@origin}"
          )

          {:woke, wake.wake_id}
        else
          EventLog.lifecycle_in_txn(
            txn,
            "harness_recovery_wake_undeliverable",
            "#{owner}/#{harness}",
            "turn=#{turn} target=#{main} reason=no_active_main principal=#{@origin}"
          )

          :no_main
        end
    end
  end

  defp active_main?(txn, main) do
    Txn.q(txn, "SELECT 1 FROM sessions WHERE sessionKey=?1 AND state='active'", [main]) == [[1]]
  end

  defp recovery_prompt(harness, generation, opened_by_turn, last_failure_turn, recovery_turn) do
    """
    [harness recovered]

    The #{harness} harness completed turn #{recovery_turn} after unavailable-turn episode #{generation} (failure turns #{opened_by_turn}..#{last_failure_turn}).

    Inspect this owner's relevant live agents using your installed or learned Kung Fu Main archetypes. Tell only affected agents that #{harness} is available. Inspect their stalled graphs and resume work whose blocker was this harness. Do not wake unrelated agents, and do not treat this notice as substrate-selected product ownership.
    """
    |> String.trim()
  end

  defp now, do: System.system_time(:millisecond)
end
