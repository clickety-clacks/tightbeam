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
  no known model. Several distinct model limits do not imply an account limit.

  A held record is released by the next normal turn on the same harness, host
  and model. The record adds no admission gate: the failed
  turn, its automatic retry and the opener's failed-turn notice are unchanged.
  """

  alias Tightbeam.DB
  alias Tightbeam.DB.Txn
  alias Tightbeam.Model

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

  A request-rate limit or a limit explicitly scoped to the turn's model
  returns `{:model, model}`. Plan and usage evidence returns `:account`.
  """
  @spec scope(String.t(), String.t() | nil) :: {:model, String.t()} | :account
  def scope(evidence, model), do: scope(evidence, evidence, model)

  @doc false
  def scope(_evidence, _message, model) when not is_binary(model) or model == "", do: :account

  def scope(evidence, message, model) when is_binary(evidence) and is_binary(message) do
    text = String.downcase(evidence)

    cond do
      names_model?(String.downcase(message), model) -> {:model, model}
      Enum.any?(@account_wide_markers, &String.contains?(text, &1)) -> :account
      Regex.match?(@plan_reset, text) -> :account
      true -> {:model, model}
    end
  end

  def scope(_evidence, _message, _model), do: :account

  defp names_model?(text, model) do
    model = String.downcase(model)

    [model, family_token(model)]
    |> Enum.filter(&(is_binary(&1) and String.length(&1) >= 4))
    |> Enum.any?(&limit_names?(text, &1, "\\b", "\\b"))
  end

  defp family_token(model) do
    # The family is a word inside the model id after its leading vendor word,
    # for example "opus" in an "<vendor>-opus-5-5" id.
    case String.split(model, ["-", "_", "."], trim: true) do
      [_vendor | rest] -> Enum.find(rest, &Regex.match?(~r/\A[a-z]+\z/, &1))
      _ -> nil
    end
  end

  defp limit_names?(text, name, left, right) do
    qualifier = left <> Regex.escape(name) <> right

    Regex.match?(
      ~r/#{qualifier}(?:['’]s)?\s+(?:(?:model|session|hourly|daily|weekly|monthly|usage|rate|request)\s+)*(?:limit|quota)\b|\b(?:limit|quota)(?:\s+(?:reached|exceeded))?\s+(?:for|on)\s+(?:the\s+)?#{qualifier}/u,
      text
    )
  end

  @doc "True only when provider wording explicitly names the attempted model or its family."
  @spec model_named?(String.t(), Model.t()) :: boolean()
  def model_named?(message, %Model{} = model) when is_binary(message) do
    text = String.downcase(message)
    family = String.downcase(model.family)
    ref = model |> Model.to_ref() |> String.downcase()

    # A word boundary alone would also accept the prefix of a longer model ID.
    # A final period is punctuation unless another identifier segment follows.
    [ref, family, family_token(family)]
    |> Enum.filter(&(is_binary(&1) and &1 != ""))
    |> Enum.uniq()
    |> Enum.any?(&limit_names?(text, &1, "(?<![\\w./-])", "(?![\\w/\\[-]|\\.\\w)"))
  end

  def model_named?(_message, _model), do: false

  @doc "Record one model-scoped limit."
  @spec record_in_txn(Txn.t(), map()) :: :ok | :recorded | :duplicate
  def record_in_txn(%Txn{} = txn, input) do
    case Map.fetch(input, :compaction_attempt_key) do
      {:ok, attempt_key} ->
        Txn.q(
          txn,
          """
          INSERT INTO harness_model_rate_limits
            (id,harness,host,model,modelContext,sessionKey,assignmentId,turnSeq,
             compactionAttemptKey,observedAt,cause,principal)
          VALUES (?1,?2,?3,?4,?5,NULL,NULL,NULL,?6,?7,?8,?9)
          ON CONFLICT(compactionAttemptKey) WHERE compactionAttemptKey IS NOT NULL DO NOTHING
          """,
          [
            "hmrl_" <> Tightbeam.Id.uuid4(),
            input.harness,
            input.host,
            input.model,
            Map.get(input, :model_context),
            attempt_key,
            input.observed_at,
            input.cause,
            input.principal
          ]
        )

        if Txn.changes(txn) == 1, do: :recorded, else: :duplicate

      :error ->
        Txn.q(
          txn,
          """
          INSERT INTO harness_model_rate_limits
            (id,harness,host,model,sessionKey,assignmentId,turnSeq,compactionAttemptKey,
             observedAt,cause,principal)
          VALUES (?1,?2,?3,?4,?5,?6,?7,NULL,?8,?9,?10)
          ON CONFLICT(turnSeq) WHERE turnSeq IS NOT NULL DO NOTHING
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

        :ok
    end
  end

  @doc "Record a positively model-named compactor limit with its attempt identity."
  def record_compactor_attempt(db \\ DB, input) do
    {:ok, status} =
      DB.transaction(db, fn txn ->
        record_in_txn(txn, input)
      end)

    %{status: Atom.to_string(status), attempt_key: input.compaction_attempt_key}
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
