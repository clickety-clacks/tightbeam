defmodule Tightbeam.HarnessHealth.ModelRateLimit do
  @moduledoc """
  Rate limits that belong to one model, not to the whole harness.

  A provider can refuse one model with a request-rate 429 while every other
  model on the same account keeps answering. Harness health keys its incidents
  and its adapter park fence on harness and host, so feeding such a limit into
  it would stop the working models too. A model-scoped limit is recorded here
  instead, against harness, host and model, and never counts toward a harness
  incident.

  Plan and usage limits ("You've hit your weekly limit", usage limits, quota)
  stay account-wide and keep the harness path. So does a limit on a turn with
  no known model. A request-rate limit that reaches a second, different model
  on the same harness and host inside the evidence window is not model-specific
  either: the caller escalates it to the harness path.

  A held record is released by the next normal turn on the same harness, host
  and model, or by escalation. The record adds no admission gate: the failed
  turn, its automatic retry and the opener's failed-turn notice are unchanged.
  """

  alias Tightbeam.DB
  alias Tightbeam.DB.Txn

  @ddl """
  CREATE TABLE IF NOT EXISTS harness_model_rate_limits (
    id            TEXT PRIMARY KEY,
    harness       TEXT NOT NULL CHECK(length(trim(harness)) > 0),
    host          TEXT NOT NULL CHECK(length(trim(host)) > 0),
    model         TEXT NOT NULL CHECK(length(trim(model)) > 0),
    sessionKey    TEXT NOT NULL,
    assignmentId  TEXT,
    turnSeq       INTEGER NOT NULL UNIQUE,
    observedAt    INTEGER NOT NULL,
    cause         TEXT NOT NULL,
    principal     TEXT NOT NULL,
    releasedAt    INTEGER,
    releaseCause  TEXT CHECK(releaseCause IN ('normal-turn','escalated')),
    releaseTurnSeq INTEGER,
    CHECK((releasedAt IS NULL AND releaseCause IS NULL) OR
          (releasedAt IS NOT NULL AND releaseCause IS NOT NULL))
  );
  CREATE INDEX IF NOT EXISTS harness_model_rate_limits_held
    ON harness_model_rate_limits(harness,host,model,releasedAt);
  """

  # Wording of plan, usage and quota limits. These are account-wide even when a
  # typed provider error carries them with the same kind as a request-rate 429.
  @account_wide_markers [
    "you've hit your",
    "you have hit your",
    "you’ve hit your",
    "usage limit",
    "usagelimitexceeded",
    "session limit",
    "hour limit",
    "daily limit",
    "weekly limit",
    "monthly limit",
    "quota exceeded",
    "quota_exceeded",
    "insufficient_quota",
    "extra usage",
    "limit reached"
  ]

  # A stated reset time ("resets 6:30pm (UTC)") belongs to a plan window.
  @plan_reset ~r/\bresets\s+(?:[a-z]{3}\s+\d|\d)/

  @doc false
  @spec ensure_schema(DB.server()) :: :ok | {:error, term()}
  def ensure_schema(db \\ DB), do: DB.execute(db, @ddl)

  @doc """
  The scope of a `rate-limit-dead` failure on a turn that ran on `model`.

  Returns `{:model, model}` for a request-rate limit, or for any limit whose
  text names the turn's model or model family; `:account` otherwise.
  """
  @spec scope(String.t(), String.t() | nil) :: {:model, String.t()} | :account
  def scope(_evidence, model) when not is_binary(model) or model == "", do: :account

  def scope(evidence, model) when is_binary(evidence) do
    text = String.downcase(evidence)

    cond do
      names_model?(text, model) -> {:model, model}
      Enum.any?(@account_wide_markers, &String.contains?(text, &1)) -> :account
      Regex.match?(@plan_reset, text) -> :account
      true -> {:model, model}
    end
  end

  def scope(_evidence, _model), do: :account

  defp names_model?(text, model) do
    model = String.downcase(model)

    family =
      case String.split(model, ["-", "_", "."], trim: true) do
        [vendor, family | _] when vendor in ["claude", "gemini"] -> family
        _ -> nil
      end

    String.contains?(text, model) or
      (is_binary(family) and String.length(family) >= 4 and
         Regex.match?(~r/\b#{Regex.escape(family)}\b/, text))
  end

  @doc """
  Record one model-scoped limit and return the held records of OTHER models on
  the same harness and host inside the window ending at `observed_at`.
  A non-empty result means the limit is not model-specific.
  """
  @spec record_in_txn(Txn.t(), map(), non_neg_integer()) :: [map()]
  def record_in_txn(%Txn{} = txn, input, window_ms) do
    Txn.q(
      txn,
      """
      INSERT OR IGNORE INTO harness_model_rate_limits
        (id,harness,host,model,sessionKey,assignmentId,turnSeq,observedAt,cause,principal)
      VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10)
      """,
      [
        "hmrl_" <> Tightbeam.Id.uuid4(),
        input.harness,
        input.host,
        input.model,
        input.session_key,
        input.assignment_id,
        input.turn_seq,
        input.observed_at,
        input.cause,
        input.principal
      ]
    )

    Txn.q(
      txn,
      select_sql() <>
        """
         WHERE harness=?1 AND host=?2 AND model!=?3 AND releasedAt IS NULL
           AND observedAt BETWEEN ?4 AND ?5
         ORDER BY observedAt,turnSeq
        """,
      [
        input.harness,
        input.host,
        input.model,
        max(0, input.observed_at - window_ms),
        input.observed_at
      ]
    )
    |> Enum.map(&row/1)
  end

  @doc "Release the records an escalation moved onto the harness path."
  @spec escalate_in_txn(Txn.t(), [String.t()], integer()) :: :ok
  def escalate_in_txn(%Txn{} = txn, ids, at) do
    Enum.each(ids, fn id ->
      Txn.q(
        txn,
        """
        UPDATE harness_model_rate_limits SET releasedAt=?2,releaseCause='escalated'
        WHERE id=?1 AND releasedAt IS NULL
        """,
        [id, at]
      )
    end)
  end

  @doc "Release every held record for the model a normal turn just answered on."
  @spec release_in_txn(Txn.t(), String.t(), String.t(), integer()) :: non_neg_integer()
  def release_in_txn(%Txn{} = txn, harness, host, turn_seq) do
    case Txn.q(
           txn,
           """
           SELECT COALESCE(t.model,s.model) FROM turns t
           JOIN sessions s ON s.sessionKey=t.sessionKey WHERE t.seq=?1
           """,
           [turn_seq]
         ) do
      [[model]] when is_binary(model) ->
        Txn.q(
          txn,
          """
          UPDATE harness_model_rate_limits
          SET releasedAt=?4,releaseCause='normal-turn',releaseTurnSeq=?5
          WHERE harness=?1 AND host=?2 AND model=?3 AND releasedAt IS NULL
          """,
          [harness, host, model, System.system_time(:millisecond), turn_seq]
        )

        Txn.changes(txn)

      _ ->
        0
    end
  end

  @doc "Held (unreleased) model-scoped records on one harness and host."
  @spec held(DB.server(), String.t(), String.t()) :: [map()]
  def held(db \\ DB, harness, host) do
    {:ok, rows} =
      DB.query(
        db,
        select_sql() <>
          " WHERE harness=?1 AND host=?2 AND releasedAt IS NULL ORDER BY observedAt,turnSeq",
        [harness, host]
      )

    Enum.map(rows, &row/1)
  end

  @doc "Every model-scoped record for one turn, held or released."
  @spec for_turn(DB.server(), integer()) :: map() | nil
  def for_turn(db \\ DB, turn_seq) do
    case DB.query(db, select_sql() <> " WHERE turnSeq=?1", [turn_seq]) do
      {:ok, [row]} -> row(row)
      {:ok, []} -> nil
    end
  end

  defp select_sql do
    """
    SELECT id,harness,host,model,sessionKey,assignmentId,turnSeq,observedAt,cause,principal,
           releasedAt,releaseCause,releaseTurnSeq
    FROM harness_model_rate_limits
    """
  end

  defp row([
         id,
         harness,
         host,
         model,
         session_key,
         assignment_id,
         turn_seq,
         observed_at,
         cause,
         principal,
         released_at,
         release_cause,
         release_turn_seq
       ]) do
    %{
      id: id,
      harness: harness,
      host: host,
      model: model,
      session_key: session_key,
      assignment_id: assignment_id,
      turn_seq: turn_seq,
      observed_at: observed_at,
      cause: cause,
      principal: principal,
      released_at: released_at,
      release_cause: release_cause,
      release_turn_seq: release_turn_seq
    }
  end
end
